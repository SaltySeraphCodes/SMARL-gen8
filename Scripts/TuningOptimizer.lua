-- TuningOptimizer.lua
-- Self-Tuning Module with Persistence Layer
dofile("globals.lua")
TuningOptimizer = class(nil)

local STABILITY_THRESHOLD = 0.5 -- Max allowed Path Error variance (meters)
local LEARNING_RATE = 0.05
local MIN_DATA_SAMPLES = 40    
local TUNING_FILE = TUNING_PROFILES 

function TuningOptimizer:init(driver)
    self.driver = driver
    self.history = {} 
    self.fingerprint = "CALCULATING" 
    
    -- [[ TUNABLE PHYSICS PARAMETERS ]]
    self.cornerLimit = 2.0      -- Speed Multiplier (Higher = Faster Corners)
    self.brakingFactor = 15.0   -- Braking Power (Higher = Brake Later)
    self.dampingFactor = 0.25   -- Yaw Resistance (Higher = Less Wobble, Slower Turn-in)
    self.lookaheadMult = 1.0    -- Lookahead Modifier (Lower = Aggressive, Higher = Smooth)
    
    -- Learning Metrics
    self.tickCount = 0
    self.yVarianceSum = 0       -- Accumulator for Path Error^2
    self.peakY = 0              -- Max Deviation from Path (Understeer detection)
    self.oscillations = 0       -- Count of rapid Left/Right switches
    self.crashDetected = false 
    self.lastSpeed = 0.0
    self.lastYSign = 0

    print("TuningOptimizer: Initialized (Gen 8 Physics Mode).")
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
    -- Map loaded JSON data to our new variables
    if profile.cornerLimit then self.cornerLimit = profile.cornerLimit end
    if profile.brakingFactor then self.brakingFactor = profile.brakingFactor end
    
    -- Legacy support: Map old Kd to new dampingFactor
    if profile.kd then self.dampingFactor = profile.kd * 0.5 end 
    if profile.dampingFactor then self.dampingFactor = profile.dampingFactor end
    
    if profile.lookaheadMult then self.lookaheadMult = profile.lookaheadMult end
end

function TuningOptimizer:saveProfile()
    local success, data = pcall(sm.json.open, TUNING_FILE)
    if not success or type(data) ~= "table" then data = {} end
    
    local typeKey = self.fingerprint or "GENERIC"
    if typeKey == "CALCULATING" then typeKey = "GENERIC" end

    data[typeKey] = {
        cornerLimit = self.cornerLimit,
        brakingFactor = self.brakingFactor,
        dampingFactor = self.dampingFactor,
        lookaheadMult = self.lookaheadMult,
        updated = os.time()
    }
    sm.json.save(data, TUNING_FILE)
end

function TuningOptimizer:reportUndersteer()
    self.understeerEvents = self.understeerEvents + 1
end

function TuningOptimizer:reportCrash()
    self.crashDetected = true
    -- Immediate Emergency Adjustment
    self.cornerLimit = math.max(1.0, self.cornerLimit * 0.8) -- Slow down 20% immediately
    self.dampingFactor = math.min(0.6, self.dampingFactor * 1.5) -- Stiffen steering
    print(self.driver.id, "CRASH DETECTED! Emergency Limits Applied.")
end

function TuningOptimizer:recordFrame(perceptionData)
    if self.fingerprint == "CALCULATING" then self:checkFingerprint(); return end
    if not self.driver.isRacing then return end
    
    local tel = perceptionData.Telemetry
    local currentSpeed = tel.speed
    
    -- 1. Crash Detection (Impact Velocity)
    local deltaSpeed = currentSpeed - self.lastSpeed
    if deltaSpeed < -12.0 then self:reportCrash() end
    self.lastSpeed = currentSpeed

    -- 2. Pure Pursuit Tracking Error (PP_Y)
    -- We read the debug value we added to DecisionModule
    local ppY = self.driver.Decision.dbg_PP_Y or 0
    
    -- 3. Oscillation Detection (Sign flipping)
    local ySign = getSign(ppY)
    if ySign ~= self.lastYSign and math.abs(ppY) > 0.2 then
        self.oscillations = self.oscillations + 1
        self.lastYSign = ySign
    end

    -- 4. Variance Calculation (How shaky is the line?)
    self.yVarianceSum = self.yVarianceSum + (ppY * ppY)
    
    -- 5. Peak Error (Did we miss a corner?)
    if math.abs(ppY) > self.peakY then self.peakY = math.abs(ppY) end

    self.tickCount = self.tickCount + 1
end

function TuningOptimizer:onSectorComplete(sectorID, sectorTime)
    if self.tickCount < MIN_DATA_SAMPLES then self:reset(); return end

    -- CALCULATE METRICS
    local rmsError = math.sqrt(self.yVarianceSum / self.tickCount) -- Root Mean Square Error
    local oscillationRate = self.oscillations / (self.tickCount / 40.0) -- Flips per second
    
    local debugMsg = ""
    local improved = false

    -- A. SAFETY LAYER (Crash/Understeer)
    if self.crashDetected then
        -- Already handled in reportCrash, just reset flag and save
        debugMsg = "Recovering from Crash"
        improved = true

    elseif self.peakY > 2.5 then
        -- Massive Understeer (Missed apex by > 2.5m)
        self.cornerLimit = math.max(1.2, self.cornerLimit - LEARNING_RATE) -- Slow down
        self.lookaheadMult = math.min(1.5, self.lookaheadMult + LEARNING_RATE) -- Look further ahead (smoother)
        debugMsg = "Understeer Fix (Speed Down, Lookahead Up)"
        improved = true

    -- B. STABILITY LAYER (Wobble)
    elseif oscillationRate > 1.5 or rmsError > STABILITY_THRESHOLD then
        -- Car is snaking/jittering
        self.dampingFactor = math.min(0.5, self.dampingFactor + LEARNING_RATE) -- More D-Term
        self.lookaheadMult = math.min(1.5, self.lookaheadMult + (LEARNING_RATE * 2)) -- Look further ahead
        debugMsg = string.format("Stabilizing (Osc: %.1f/s)", oscillationRate)
        improved = true

    -- C. PERFORMANCE LAYER (Pushing Limits)
    else
        local avgTime = self:getRollingAverage(sectorID, 5)
        if avgTime == 0 or sectorTime < avgTime then
            -- We are stable and fast. Push harder!
            self.cornerLimit = math.min(3.5, self.cornerLimit + (LEARNING_RATE * 0.5)) -- Faster corners
            self.brakingFactor = math.min(40.0, self.brakingFactor + LEARNING_RATE) -- Brake later
            
            -- If very stable, sharpen steering
            if oscillationRate < 0.5 then
                self.dampingFactor = math.max(0.15, self.dampingFactor - (LEARNING_RATE * 0.5))
            end
            
            debugMsg = "Setting PB! Pushing Limits."
            improved = true
        else
            -- Stable but slow? Maybe braking too early?
            self.brakingFactor = math.min(40.0, self.brakingFactor + (LEARNING_RATE * 2))
            debugMsg = "Slow. Braking Later."
            improved = true
        end
    end

    print(string.format("Opt [%d]: %s | Limit:%.2f Brk:%.1f Damp:%.2f Look:%.2f | Err:%.2fm", 
        self.driver.id, debugMsg, self.cornerLimit, self.brakingFactor, self.dampingFactor, self.lookaheadMult, rmsError))

    if improved then self:saveProfile() end
    
    -- Update History buffer logic (keep same as before)
    table.insert(self.history, { sid = sectorID, time = sectorTime })
    if #self.history > 50 then table.remove(self.history, 1) end
    
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
    self.crashDetected = false
end

function TuningOptimizer:generatePhysicsFingerprint(driver)
    if not driver.perceptionData or 
       not driver.perceptionData.Telemetry or 
       not driver.perceptionData.Telemetry.dimensions or
       driver.perceptionData.Telemetry.isOnLift then 
        return "INIT_WAIT" 
    end
    
    local tel = driver.perceptionData.Telemetry
    local rawMass = tel.mass or 1000
    local massBucket = math.floor((rawMass / 250) + 0.5) * 250
    
    local rawDownforce = tel.downforce or 0
    if driver.Spoiler_Angle then
        rawDownforce = rawDownforce + (driver.Spoiler_Angle * 20) 
    end
    local dfBucket = math.floor((rawDownforce / 500) + 0.5) * 500
    
    local dims = tel.dimensions
    local dimA = dims.x
    local dimB = dims.y
    
    local length = math.max(dimA, dimB)
    local width = math.min(dimA, dimB)
    
    local lengthBucket = math.floor((length / 0.5) + 0.5) * 0.5 
    local widthBucket = math.floor((width / 0.5) + 0.5) * 0.5
    
    local engineTag = "STD"
    if driver.engine and driver.engine.engineStats then
        local stats = driver.engine.engineStats
        if stats.TYPE == "custom" then
             local speedBucket = math.floor((stats.MAX_SPEED / 25) + 0.5) * 25
             engineTag = "C" .. speedBucket
        else
             engineTag = stats.TYPE or "STD"
        end
    end

    local fingerprint = string.format("M%d_DF%d_L%.1f_W%.1f_%s", 
        massBucket, dfBucket, lengthBucket, widthBucket, engineTag)
        
    return fingerprint
end