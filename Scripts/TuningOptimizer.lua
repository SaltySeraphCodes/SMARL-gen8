-- TuningOptimizer.lua
-- Self-Tuning Module with Persistence Layer
dofile("globals.lua")
TuningOptimizer = class(nil)

local STABILITY_THRESHOLD = 0.5 -- Max allowed Path Error variance (meters)
local LEARNING_RATE = 0.05
local MIN_DATA_SAMPLES = 40    
local TUNING_FILE = TUNING_PROFILES 
local INIT_GRACE_PERIOD = 80 -- 2 Seconds (40 ticks/sec) to wait for Engine/Wheels

function TuningOptimizer:init(driver)
    self.driver = driver
    self.history = {} 
    self.fingerprint = "CALCULATING" 

    self.learningLocked = false
    self.initWaitTicks = 0 -- [FIX] Timer to allow Engine connection
    
    -- [[ TUNABLE PHYSICS PARAMETERS ]]
    self.cornerLimit = 2.0      
    self.brakingFactor = 15.0   
    self.dampingFactor = 0.15   
    self.lookaheadMult = 0.9    
    self.tractionConstant = 2.6
    
    -- [[ NEW: LEARNED PHYSICS PROFILE ]]
    self.learnedGrip = 1.0      -- 1.0 = Standard Grip (approx 1g). Will learn 0.5 - 2.0
    self.tcsConverged = false   -- Becomes true when tractionConstant stops fluctuating
    self.tcsVariance = 0.0      -- Tracker for TCS learning stability
    
    -- Learning Metrics
    self.tickCount = 0
    self.yVarianceSum = 0      
    self.peakY = 0             
    self.oscillations = 0       
    self.crashDetected = false 
    self.lastSpeed = 0.0
    self.lastYSign = 0
    
    -- Grip Learning Buffers
    self.peakLatAccel = 0.0
    self.slipEvents = 0

    self.lastSaveTime = 0

    print("TuningOptimizer: Initialized with Physics Profiling")
end

-- [[ PUBLIC API TO LOCK LEARNING ]]
function TuningOptimizer:setLearningLock(locked)
    self.learningLocked = locked
    local status = locked and "LOCKED (Race Mode)" or "UNLOCKED (Practice Mode)"
    print(string.format("Optimizer [%d]: Learning is now %s", self.driver.id, status))
end

function TuningOptimizer:checkFingerprint()
    if self.fingerprint ~= "CALCULATING" then return end
    
    local fp = self:generatePhysicsFingerprint(self.driver)
    if fp ~= "INIT_WAIT" then
        self.fingerprint = fp
        self:loadProfile() 
        print("TuningOptimizer: Car Fingerprint Identified: " .. self.fingerprint)
    end
end

function TuningOptimizer:loadProfile()
    local success, data = pcall(sm.json.open, TUNING_FILE)
    if not success or not data then return end
    
    if data[self.fingerprint] then
        self:applyProfile(data[self.fingerprint])
        print("Optimizer: Exact match loaded [" .. self.fingerprint .. "]")
        return
    end
    
    local searchKey = string.sub(self.fingerprint, 1, string.find(self.fingerprint, "_L") - 1)
    for key, profile in pairs(data) do
        if string.sub(key, 1, string.len(searchKey)) == searchKey then
            self:applyProfile(profile)
            print("Optimizer: Partial Match found (" .. key .. "). Inheriting Physics.")
            self:saveProfile(profile.kp, profile.kd)
            return
        end
    end
end

function TuningOptimizer:applyProfile(profile)
    if profile.cornerLimit then self.cornerLimit = profile.cornerLimit end
    if profile.brakingFactor then self.brakingFactor = profile.brakingFactor end
    if profile.dampingFactor then self.dampingFactor = profile.dampingFactor end
    if profile.lookaheadMult then self.lookaheadMult = profile.lookaheadMult end
    
    if profile.tractionConstant then 
        self.tractionConstant = profile.tractionConstant 
        -- If we loaded a profile, assume TCS is reasonably converged
        self.tcsConverged = true 
    end

    -- Load Grip Profile
    if profile.learnedGrip then 
        self.learnedGrip = profile.learnedGrip 
        print(string.format("Optimizer: Loaded Grip Profile: %.2f Gs", self.learnedGrip))
    end
end

function TuningOptimizer:saveProfile(force)
    -- [[ LOCK CHECK ]]
    if self.learningLocked then return end

    -- [[ FIX: SAVE COOLDOWN ]]
    -- Only write to disk if forced (e.g. game closing) or 60s passed
    local now = os.time()
    if not force and (now - self.lastSaveTime < 60) then return end
    self.lastSaveTime = now

    local success, data = pcall(sm.json.open, TUNING_FILE)
    if not success or type(data) ~= "table" then data = {} end
    
    local typeKey = self.fingerprint or "GENERIC"
    if typeKey == "CALCULATING" then typeKey = "GENERIC" end

    data[typeKey] = {
        cornerLimit = self.cornerLimit,
        brakingFactor = self.brakingFactor,
        dampingFactor = self.dampingFactor,
        lookaheadMult = self.lookaheadMult,
        tractionConstant = self.tractionConstant,
        learnedGrip = self.learnedGrip, 
        updated = now
    }
    sm.json.save(data, TUNING_FILE)
end

function TuningOptimizer:reportUndersteer()
    self.understeerEvents = self.understeerEvents + 1
end

function TuningOptimizer:reportCrash()
    -- [[ LOCK CHECK ]]
    -- If locked, we ignore crash data. We assume the crash was due to 
    -- external factors (opponents), not bad tuning.
    if self.learningLocked then return end

    self.crashDetected = true
    -- Immediate Emergency Adjustment
    self.cornerLimit = math.max(1.0, self.cornerLimit * 0.8) -- Slow down 20% immediately
    self.dampingFactor = math.min(0.6, self.dampingFactor * 1.5) -- Stiffen steering
    print(self.driver.id, "CRASH DETECTED! Emergency Limits Applied.")
end

function TuningOptimizer:recordFrame(perceptionData)
    if self.fingerprint == "CALCULATING" then 
        self.initWaitTicks = self.initWaitTicks + 1 -- [FIX] Increment wait timer
        self:checkFingerprint()
        return 
    end
    
    if not self.driver.isRacing then return end
    
    local tel = perceptionData.Telemetry
    local currentSpeed = tel.speed
    
    -- 1. Crash Detection
    local deltaSpeed = currentSpeed - self.lastSpeed
    if deltaSpeed < -12.0 then self:reportCrash() end
    self.lastSpeed = currentSpeed

    -- 2. Pure Pursuit Error & Oscillation
    local ppY = self.driver.Decision.dbg_PP_Y or 0
    local ySign = getSign(ppY)
    if ySign ~= self.lastYSign and math.abs(ppY) > 0.2 then
        self.oscillations = self.oscillations + 1
        self.lastYSign = ySign
    end
    self.yVarianceSum = self.yVarianceSum + (ppY * ppY)
    if math.abs(ppY) > self.peakY then self.peakY = math.abs(ppY) end

    -- [[ NEW: GRIP LEARNING ]]
    -- Calculate Lateral Acceleration: a = v * omega (speed * yawRate)
    local yawRate = 0
    if tel.angularVelocity and tel.rotations then
        yawRate = math.abs(tel.angularVelocity:dot(tel.rotations.up))
    end
    
    local latAccel = currentSpeed * yawRate
    
    -- [[ REFINEMENT 1: SUSTAINED GRIP CHECK ]]
    -- Filter out collision spikes. Grip must be held for 0.25s (10 ticks) to count.
    if latAccel > 3.0 then -- Only care about high-G events
        self.highG_Timer = (self.highG_Timer or 0) + 1
    else
        self.highG_Timer = 0
    end

    -- Only record peak if we have held it for 10+ ticks AND we aren't oscillating
    if self.highG_Timer > 10 and latAccel > self.peakLatAccel and self.oscillations < 2 then
        self.peakLatAccel = latAccel
    end
    
   -- [[ FIX: CALCULATE REAL-TIME TCS VARIANCE (SLIP) ]]
    -- Calculate what the RPM *should* be at this speed
    -- Formula: ExpectedRPM = (Speed * 60) / Constant
    local currentSlip = 0.0
    
    if tel.avgWheelRPM and self.tractionConstant > 0 and currentSpeed > 5.0 then
        local expectedRPM = (currentSpeed * 60.0) / self.tractionConstant
        local actualRPM = tel.avgWheelRPM
        
        if expectedRPM > 50 then
            local ratio = actualRPM / expectedRPM
            -- If Ratio is 1.2, we have 20% slip. If 1.0, perfect grip.
            -- variance = abs(1.0 - 1.2) = 0.2
            currentSlip = math.abs(1.0 - ratio)
        end
    end
    
    -- Smooth the variance so the debug light doesn't flicker
    -- 20% new data, 80% history
    self.tcsVariance = (self.tcsVariance * 0.8) + (currentSlip * 0.2)
    
    -- 4. Visualize
    local ppError = self.driver.Decision.dbg_PP_Y or 0
    local instability = math.abs(ppError)
    self:updateDebugVisuals(instability, self.tcsVariance)

    self.tickCount = self.tickCount + 1
end

function TuningOptimizer:onSectorComplete(sectorID, sectorTime)
    -- [[ LOCK CHECK ]]
    -- If locked, we simply reset the buffers so they don't overflow,
    -- but we DO NOT update any parameters or save data.
    if self.learningLocked then
        self:reset()
        return
    end
    
    if self.tickCount < MIN_DATA_SAMPLES then self:reset(); return end

    local rmsError = math.sqrt(self.yVarianceSum / self.tickCount)
    local oscillationRate = self.oscillations / (self.tickCount / 40.0)
    
    local debugMsg = ""
    local improved = false

    -- [[ UPDATED: GRIP PROFILE LOGIC ]]
    -- CRITICAL: Only learn Physical Grip Limits when tires are fresh (> 90%).
    -- This prevents the AI from mistaking "Simulated Wear" for "Permanent Physics".
    local tireHealth = self.driver.Tire_Health or 1.0
    
    if tireHealth > 0.90 and self.peakLatAccel > 5.0 then
        -- We are on fresh rubber, so any grip we see is the "True Potential" of the car
        local observedGrip = self.peakLatAccel / 15.0
        
        if observedGrip > self.learnedGrip then
            -- Car is grippier than we thought!
            self.learnedGrip = math.min(2.5, self.learnedGrip + 0.05)
            improved = true
        elseif self.peakY > 2.0 and observedGrip < self.learnedGrip then
            -- We are sliding on FRESH tires -> True grip loss
            self.learnedGrip = math.max(0.5, self.learnedGrip - 0.05)
            improved = true
        end
    end
    
    -- [[ EXISTING TUNING LOGIC ]]
    if self.crashDetected then
        debugMsg = "Recovering from Crash"
        improved = true
    elseif self.peakY > 2.5 then
        self.cornerLimit = math.max(1.2, self.cornerLimit - LEARNING_RATE)
        self.lookaheadMult = math.min(1.5, self.lookaheadMult + LEARNING_RATE)
        debugMsg = debugMsg .. " Understeer Fix"
        improved = true
    elseif oscillationRate > 1.5 or rmsError > STABILITY_THRESHOLD then
        self.dampingFactor = math.min(0.5, self.dampingFactor + LEARNING_RATE)
        self.lookaheadMult = math.min(1.1, self.lookaheadMult + (LEARNING_RATE * 2))
        
        debugMsg = debugMsg .. " Stabilizing"
        improved = true
    else
        local avgTime = self:getRollingAverage(sectorID, 5)
        if avgTime == 0 or sectorTime < avgTime then
            self.cornerLimit = math.min(3.5, self.cornerLimit + (LEARNING_RATE * 0.5))
            self.brakingFactor = math.min(40.0, self.brakingFactor + LEARNING_RATE)
            debugMsg = debugMsg .. " Pushing Limits"
            improved = true
        end
    end

    if improved then self:saveProfile() end
    
    table.insert(self.history, { sid = sectorID, time = sectorTime })
    if #self.history > 50 then table.remove(self.history, 1) end
    print(debugMsg)
    self:reset()
end

function TuningOptimizer:getRollingAverage(sectorID, samples)
    local total = 0
    local count = 0
    for i = #self.history, 1, -1 do
        if self.history[i].sid == sectorID then
            total = total + self.history[i].time
            count = count + 1
            if count >= samples then break end
        end
    end
    return count > 0 and (total / count) or 0
end

function TuningOptimizer:reset()
    self.tickCount = 0
    self.yVarianceSum = 0
    self.peakY = 0
    self.oscillations = 0
    self.peakLatAccel = 0 -- Reset peak Gs for next sector
    self.crashDetected = false
end

function TuningOptimizer:updateTractionConstant(val)
    -- [[ LOCK CHECK ]]
    if self.learningLocked then return end

    -- [[ NEW: SLIP REJECTION (THE CLAMP) ]]
    -- Once converged, we treat the calculated constant as the "True Gear Ratio".
    -- If 'val' drops lower, it means Wheel RPM > Speed, which is SLIP. We ignore it.
    if self.tcsConverged then
        -- 1. Reject drops (Slip)
        if val < self.tractionConstant then 
            return 
        end
        
        -- 2. Slowly accept higher values (Refinement)
        -- If we found a value slightly higher, it means we had better grip than we thought.
        if val > self.tractionConstant and (val - self.tractionConstant) < 0.5 then
             -- Weighted average: 90% old, 10% new
             local blended = (self.tractionConstant * 0.9) + (val * 0.1)
             self.tractionConstant = blended
             return -- Don't print spam, just silently refine
        end
    end

    -- [[ CONVERGENCE CHECK ]]
    local diff = math.abs(self.tractionConstant - val)
    
    if diff < 0.05 then
        if not self.tcsConverged then
            self.tcsConverged = true
            print("Optimizer: TCS Profile CONVERGED. Locking Physics Profile.")
            self:saveProfile()
        end
    elseif diff > 0.1 then
        -- Only allow large jumps if we aren't converged yet
        if not self.tcsConverged then
            self.tractionConstant = val
            self:saveProfile()
            print(string.format("Optimizer: Learned NEW Traction Constant: %.2f", val))
        end
    end
end

function TuningOptimizer:generatePhysicsFingerprint(driver)
    if not driver.perceptionData or 
       not driver.perceptionData.Telemetry or 
       not driver.perceptionData.Telemetry.bbDimensions or
       driver.perceptionData.Telemetry.isOnLift then 
        return "INIT_WAIT" 
    end
    
    -- [FIX] Wait for Engine Connection
    -- If engine is missing, wait up to 2 seconds (INIT_GRACE_PERIOD) for it to connect
    if not driver.engine and self.initWaitTicks < INIT_GRACE_PERIOD then
        return "INIT_WAIT"
    end

    local tel = driver.perceptionData.Telemetry
    
    -- 1. Mass Bucket
    local rawMass = tel.mass or 1000
    local massBucket = math.floor((rawMass / 250) + 0.5) * 250
    
    -- 2. Dimensions
    local dims = tel.bbDimensions
    local length = math.max(dims.x, dims.y)
    local width = math.min(dims.x, dims.y)
    local lengthBucket = math.floor((length / 0.5) + 0.5) * 0.5 
    local widthBucket = math.floor((width / 0.5) + 0.5) * 0.5
    
    -- 3. Engine/Wheel Tag
    local wheelTag = "NIL"
    if driver.engine then
        -- Ensure the engine has scanned (handle race conditions)
        if not driver.engine.wheelTypeTag or driver.engine.wheelTypeTag == "NONE" then 
            driver.engine:scanWheelType() 
        end
        
        -- [FIX] If tag is still NONE, wait longer (unless grace period expired)
        if (not driver.engine.wheelTypeTag or driver.engine.wheelTypeTag == "NONE") and self.initWaitTicks < INIT_GRACE_PERIOD then
             return "INIT_WAIT"
        end

        wheelTag = driver.engine.wheelTypeTag or "UNK"
    end
    
    -- 4. Downforce Bucket
    local rawDownforce = tel.downforce or 0
    if driver.Spoiler_Angle then
        rawDownforce = rawDownforce + (driver.Spoiler_Angle * 20) 
    end
    local dfBucket = math.floor((rawDownforce / 500) + 0.5) * 500

    -- NEW FORMAT: M[Mass]_L[Len]_W[Wid]_[WheelType]
    -- Example: M1500_L12.0_W7.0_LRG
    return string.format("M%d_L%.1f_W%.1f_%s", massBucket, lengthBucket, widthBucket, wheelTag)
end


function TuningOptimizer:updateDebugVisuals(instability, tcsVariance)
    if not self.driver or not self.driver.Decision or not self.driver.Decision.latestDebugData then return end
    
    local color = sm.color.new(0, 1, 0, 1) -- GREEN
    
    -- PRIORITY 1: SLIDING (Yellow)
    if tcsVariance > 0.05 then
        color = sm.color.new(1, 1, 0, 1) -- YELLOW
    end
    
    -- PRIORITY 2: OFF TRACK (Red)
    -- [[ FIX: CHECK LATERAL ERROR INSTEAD OF STEERING ERROR ]]
    local latErr = self.driver.Decision.latestDebugData.latErr or 0
    if math.abs(latErr) > 2.5 then
        color = sm.color.new(1, 0, 0, 1) -- RED
    end
    
    self.driver.Decision.latestDebugData.statusColor = color
end