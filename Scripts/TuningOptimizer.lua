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
    self.cornerLimit = 1.8      
    self.brakingFactor = 15.0   
    self.dampingFactor = 0.35   -- [FIX] Increased for stability (Was 0.30)
    self.lookaheadMult = 0.65   -- [FIX] Reduced for tighter lines (Was 0.8)
    self.tractionConstant = 2.6

    -- [[ NEW: USER SETUP ]]
    self.setup = {
        gearRatio = 5,       -- 1 (Accel) to 10 (Speed)
        aeroAngle = 45,      -- degrees
        tireType = "Medium"  -- Soft, Medium, Hard
    }

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
    
    -- Calibration State
    self.microBrakeDone = false
    self.peakDecel = 0.0
    self.steeringTestDone = false 

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
    -- 1. Check for Setup Mismatch
    -- If the profile has a setup, and it differs from ours, we must INVALIDATE/SCALE the learned physics.
    local setupChanged = false
    
    if profile.setup then
        if profile.setup.gearRatio ~= self.setup.gearRatio then setupChanged = true end
        if profile.setup.aeroAngle ~= self.setup.aeroAngle then setupChanged = true end
        if profile.setup.tireType ~= self.setup.tireType then setupChanged = true end
    end

    if setupChanged then
        print("Optimizer: SETUP CHANGED! Resetting Learned Grip and TC.")
        -- Reset Learned Physics, but keep generic Tuning params
        self.learnedGrip = 1.0 
        self.tcsConverged = false
        -- We do NOT load 'tractionConstant' or 'learnedGrip' from the profile
    else
        -- Exact Match: Load everything
        if profile.tractionConstant then 
            self.tractionConstant = profile.tractionConstant 
            self.tcsConverged = true 
        end
        if profile.learnedGrip then 
            self.learnedGrip = profile.learnedGrip 
        end
    end

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
        -- If we have a saved grip value and setup matches, assume we don't need to re-calibrate
        self.microBrakeDone = true 
        self.steeringTestDone = true
        print(string.format("Optimizer: Loaded Grip Profile: %.2f Gs (Skipping Calibration)", self.learnedGrip))
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
        setup = self.setup, -- [[ NEW ]]
        updated = now
    }
    sm.json.save(data, TUNING_FILE)
end

function TuningOptimizer:reportUndersteer()
    self.understeerEvents = self.understeerEvents + 1
end

function TuningOptimizer:reportCrash()
    -- [[ LOCK CHECK ]]
    if self.learningLocked then return end

    -- 1. DATA GATHERING (Context)
    -- Was this a traction loss (spin) or just a bad line (clip)?
    local isSpin = (self.peakY and self.peakY > 2.0) or (self.oscillations > 2)
    
    self.crashDetected = true
    
    -- 2. SMART PENALTY
    if isSpin then
        -- IT WAS A SLIDE: We are too stiff or trusting grip too much.
        self.learnedGrip = math.max(0.8, self.learnedGrip - 0.05) -- Small grip reduction
        self.dampingFactor = math.min(0.5, self.dampingFactor + 0.05) -- Add damping
        print(self.driver.id, "CRASH (Spin): Increasing Damping, Reducing Grip confidence.")
    else
        -- IT WAS A CLIP: We just took a bad line. Don't ruin the physics!
        -- Just back off the corner speed slightly to be safe.
        self.cornerLimit = math.max(1.0, self.cornerLimit * 0.90) -- Reduce limit by 10% only
        print(self.driver.id, "CRASH (Clip): Softening Corner Limit by 10%.")
    end

    -- 3. COOLDOWN (The Fix for "Overcorrecting")
    -- Instead of resetting everything, we just PAUSE learning for 5 seconds.
    -- This stops the car from trying to "fix" the tuning while it's tumbling through the air.
    self.learningCoolDown = 200 -- 5 seconds (40 ticks/sec)
    
    -- Save this minor adjustment (not a full reset)
    self:saveProfile() 
end

function TuningOptimizer:recordFrame(perceptionData, dt)
    -- if self.learningLocked then return end -- MOVED DOWN to allow calibration
    if not perceptionData or not perceptionData.Telemetry then return end
    if self.learningCoolDown and self.learningCoolDown > 0 then
        self.learningCoolDown = self.learningCoolDown - 1
        return -- IGNORE ALL DATA while recovering
    end

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
    -- self.lastSpeed = currentSpeed -- MOVED TO END of function for correct dt calc

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
    
    -- [[ PHASE 2: MICRO-BRAKE TEST ]]
    -- Startup calibration to find base friction.
    -- FIX: Ensure we finish the test if started, even if speed drops below 8.0
    local brakeTestActive = (self.testState and self.testState > 0)
    if not self.microBrakeDone and ((currentSpeed > 8.0 and currentSpeed < 20.0) or brakeTestActive) then
        self:runMicroBrakeTest(tel, dt)
    local steerTestActive = (self.steerState and self.steerState > 0)
    elseif self.microBrakeDone and not self.steeringTestDone and (currentSpeed > 10.0 or steerTestActive) then
        self:runSteeringTest(tel, dt, perceptionData)
    end
    
    -- [[ PHASE 3: ADAPTIVE LEARNING (LOCKABLE) ]]
    if self.learningLocked then 
        self.lastSpeed = currentSpeed -- Update speed even if locked
        return 
    end
    
    -- [[ TELEMETRY LOGGING ]]
    if self.tickCount % 8 == 0 then -- Approx every 0.2s
         local mode = (self.driver.Decision and self.driver.Decision.currentMode) or "UNK"
         print(string.format("TELEMETRY: [%s] Spd:%.1f, Thr:%.2f, Brk:%.2f, Steer:%.2f, LatG:%.2f, Grip:%.2f", 
            mode,
            currentSpeed, 
            self.driver.Decision.throttle or 0, 
            self.driver.Decision.brake or 0, 
            self.driver.Decision.steer or 0, 
            latAccel / 10.0, 
            self.learnedGrip))
    end
    
    self.lastSpeed = currentSpeed -- Correct update point
end

function TuningOptimizer:runSteeringTest(tel, dt, perceptionData)
    if self.steerState == nil then self.steerState = 0 end
    
    -- STATE 0: WAIT FOR STABLE STRAIGHT AND SAFE TRACK
    if self.steerState == 0 then
        local yawRate = 0
        if tel.angularVelocity then yawRate = math.abs(tel.angularVelocity.z) end
        
        -- Safety Checks
        local isStraight = true
        if perceptionData and perceptionData.Navigation then
            -- Require a straight track (Radius > 150m or 0 means infinity)
             local rad = math.abs(perceptionData.Navigation.longCurveRadius or 0)
             if rad > 0 and rad < 150 then isStraight = false end
        end
        
        -- Also check Wall Margins if available
        local isSafeWidth = true
        if perceptionData and perceptionData.WallAvoidance then
             local wa = perceptionData.WallAvoidance
             -- Require at least 4m on both sides
             if wa.marginLeft < 4.0 or wa.marginRight < 4.0 then isSafeWidth = false end
        end

        if yawRate < 0.05 and isStraight and isSafeWidth then 
            self.steerState = 1 
            self.steerTimer = 0
        end
        
    -- STATE 1: IMPULSE LEFT (+0.3 for 0.15s)
    elseif self.steerState == 1 then
        self.driver.Decision.overrideSteer = 0.3
        self.steerTimer = self.steerTimer + dt
        if self.steerTimer > 0.15 then
            self.steerState = 2
            self.steerTimer = 0
            self.impulseTime = sm.game.getServerTick()
        end
        
    -- STATE 2: CENTER AND MEASURE RESPONSE
    elseif self.steerState == 2 then
        self.driver.Decision.overrideSteer = 0.0
        self.steerTimer = self.steerTimer + dt
        
        -- Detect Peak Yaw
        local yawRate = 0
        if tel.angularVelocity then yawRate = math.abs(tel.angularVelocity.z) end
        
        if yawRate > (self.peakYawTest or 0) then
            self.peakYawTest = yawRate
            self.peakYawTime = sm.game.getServerTick()
        end
        
        if self.steerTimer > 1.0 then -- Wait 1s for settling
             -- Calculate Lag
             local lagTicks = (self.peakYawTime or 0) - (self.impulseTime or 0)
             -- Ticks to seconds
             local lagSeconds = lagTicks / 40.0
             
             print(string.format("Optimizer: Steering Test Complete. Lag: %.3fs, Peak Yaw: %.2f", lagSeconds, self.peakYawTest or 0))
             
             -- Tuning Logic
             if lagSeconds < 0.15 then
                 self.lookaheadMult = 0.7 -- Agile
             elseif lagSeconds > 0.3 then
                 self.lookaheadMult = 1.0 -- Sluggish
             else
                 self.lookaheadMult = 0.8 -- Normal
             end
             
             self:saveProfile()
             self.steeringTestDone = true
             self.driver.Decision.overrideSteer = nil
        end
    end
end

function TuningOptimizer:runMicroBrakeTest(tel, dt)
    if self.testState == nil then self.testState = 0 end
    
    -- STATE 0: WAIT FOR STABLE SPEED
    if self.testState == 0 then
        -- Ensure we are accelerating (proving engine power) then coasting? 
        -- Actually just wait for a straight line.
        local yawRate = 0
        if tel.angularVelocity then yawRate = math.abs(tel.angularVelocity.z) end
        
        if yawRate < 0.1 then 
            self.testState = 1 
            self.testTimer = 0
        end
        
    -- STATE 1: APPLY BRAKE PULSE (0.3s)
    elseif self.testState == 1 then
        self.driver.Decision.overrideBrake = 1.0
        self.driver.Decision.overrideThrottle = 0.0
        
        self.testTimer = self.testTimer + dt
        
        -- Measure Decel
        local accel = (tel.speed - self.lastSpeed) / dt
        if accel < self.peakDecel then self.peakDecel = accel end -- decel is negative
        
        if self.testTimer > 0.3 then
            self.testState = 2
            -- Calculate Mu
            -- a = mu * g  ->  mu = a / g
            local g = 10 -- constant
            local observedMu = math.abs(self.peakDecel) / g
            
            print(string.format("Optimizer: Micro-Brake Test Complete. Peak Decel: %.2f, Est Mu: %.2f", self.peakDecel, observedMu))
            
            -- Apply to Learned Grip (Conservative 80%)
            self.learnedGrip = math.max(0.5, observedMu * 0.9)
            self:saveProfile()
            
            self.microBrakeDone = true
            self.driver.Decision.overrideBrake = nil
            self.driver.Decision.overrideThrottle = nil
        end
    end
end

function TuningOptimizer:onSectorComplete(sectorID, sectorTime)
    if self.learningLocked then self:reset(); return end
    if self.tickCount < MIN_DATA_SAMPLES then self:reset(); return end

    local rmsError = math.sqrt(self.yVarianceSum / self.tickCount)
    local oscillationRate = self.oscillations / (self.tickCount / 40.0)
    
    local debugMsg = ""
    local improved = false

    -- 1. GRIP LEARNING (Make it more aggressive)
    -- If we sustained high Gs, trust the car more.
    if self.peakLatAccel > 5.0 then
        local observedGrip = self.peakLatAccel / 10.0 -- Lower divisor = higher calculated grip
        
        if observedGrip > self.learnedGrip then
            -- Learn grip FAST (Confidence)
            self.learnedGrip = math.min(3.0, self.learnedGrip + 0.1)
            improved = true
        elseif self.peakY > 2.0 and observedGrip < (self.learnedGrip - 0.2) then
            -- Forget grip SLOW (Forgiveness)
            self.learnedGrip = math.max(0.8, self.learnedGrip - 0.02)
            improved = true
        end
    end
    
    -- 2. STABILITY TUNING (The Fix)
    if self.crashDetected then
        debugMsg = "Recovering from Crash"
        -- Don't reset completely, just back off slightly
        self.cornerLimit = math.max(1.0, self.cornerLimit - 0.1)
        improved = true
    elseif self.peakY > 2.0 then
        -- UNDERSTEER: We missed the line. Slow down entry, don't change steering.
        self.cornerLimit = math.max(1.0, self.cornerLimit - LEARNING_RATE)
        debugMsg = debugMsg .. " Understeer Fix"
        improved = true
    elseif oscillationRate > 1.0 or rmsError > STABILITY_THRESHOLD then
        -- OSCILLATION: Increase Damping FIRST. Only increase Lookahead if Damping is maxed.
        if self.dampingFactor < 0.40 then
            self.dampingFactor = self.dampingFactor + (LEARNING_RATE * 2)
            debugMsg = debugMsg .. " +Damping"
        else
            self.lookaheadMult = math.min(1.2, self.lookaheadMult + LEARNING_RATE)
            debugMsg = debugMsg .. " +Lookahead"
        end
        improved = true
    else
        -- STABLE: Speed it up!
        -- If we are stable, tighten the steering (lower lookahead) and brake later.
        local avgTime = self:getRollingAverage(sectorID, 5)
        
        if avgTime == 0 or sectorTime <= avgTime then
            self.cornerLimit = math.min(4.0, self.cornerLimit + (LEARNING_RATE * 0.5))
            self.brakingFactor = math.min(50.0, self.brakingFactor + (LEARNING_RATE * 2))
            
            -- Tighten steering for better apexing
            self.lookaheadMult = math.max(0.7, self.lookaheadMult - LEARNING_RATE)
            
            debugMsg = debugMsg .. " Pushing Limits"
            improved = true
        end
    end

    if improved then self:saveProfile() end
    
    table.insert(self.history, { sid = sectorID, time = sectorTime })
    if #self.history > 50 then table.remove(self.history, 1) end
    print(debugMsg .. string.format(" [Grip: %.2f | Damp: %.2f]", self.learnedGrip, self.dampingFactor))
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
            print("Optimizer: TCS Profile CONVERGED. Locking Traction Constraint.")
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