-- TuningOptimizer.lua
-- Self-Tuning Module with Persistence Layer
dofile("globals.lua")
TuningOptimizer = class(nil)

local STABILITY_THRESHOLD = 0.8 
local LEARNING_RATE_PID = 0.02
local LEARNING_RATE_PHYSICS = 0.1
local MIN_DATA_SAMPLES = 40    
local TUNING_FILE = TUNING_PROFILES 

function TuningOptimizer:init(driver)
    self.driver = driver
    self.history = {} 
    self.fingerprint = "CALCULATING" 
    self.retryTimer = 0

    -- Physics Learning Params
    self.cornerLimit = 2.0 
    self.brakingFactor = 15.0
    
    -- Event Counters
    self.understeerEvents = 0
    self.crashDetected = false 
    self.lastSpeed = 0.0
    
    self.tickCount = 0
    self.yawAccumulator = 0
    self.yawHistory = {}
    
    print("TuningOptimizer: Initialized.")
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
    local decision = self.driver.Decision
    if profile.kp and profile.kd then
        decision.STEERING_Kp_BASE = profile.kp
        decision.STEERING_Kd_BASE = profile.kd
    end
    if profile.cornerLimit then
        self.cornerLimit = profile.cornerLimit
    end
    if profile.brakingFactor then
        self.brakingFactor = profile.brakingFactor
        decision.brakingForceConstant = self.brakingFactor 
    end
end

function TuningOptimizer:saveProfile(kp, kd)
    local success, data = pcall(sm.json.open, TUNING_FILE)
    if not success or type(data) ~= "table" then data = {} end
    
    local typeKey = self.fingerprint or "GENERIC_SAFE_MODE"
    if typeKey == "CALCULATING" then typeKey = "GENERIC_SAFE_MODE" end

    data[typeKey] = {
        kp = kp,
        kd = kd,
        cornerLimit = self.cornerLimit,
        brakingFactor = self.brakingFactor,
        updated = os.time()
    }
    
    sm.json.save(data, TUNING_FILE)
end

function TuningOptimizer:reportUndersteer()
    self.understeerEvents = self.understeerEvents + 1
end

function TuningOptimizer:reportCrash()
    self.crashDetected = true
    print("Optimizer: CRASH REPORTED. Preparing safety adjustments.")
end

function TuningOptimizer:recordFrame(perceptionData)
    if self.fingerprint == "CALCULATING" then
        self:checkFingerprint()
        return 
    end
    if not self.driver.isRacing then return end
    
    local tel = perceptionData.Telemetry
    local yawRate = math.abs(tel.angularVelocity:dot(tel.rotations.up))
    
    -- [NEW] Impact Detection (Sudden Velocity Loss)
    local currentSpeed = tel.speed
    local deltaSpeed = currentSpeed - self.lastSpeed
    -- If we lose more than 20 speed in 1 frame (0.025s), we hit something hard.
    if deltaSpeed < -10.0 then 
        print(self.driver.id, "IMPACT DETECTED! Delta:", deltaSpeed)
        self:reportCrash()
    end
    self.lastSpeed = currentSpeed

    self.tickCount = self.tickCount + 1
    self.yawAccumulator = self.yawAccumulator + yawRate
    table.insert(self.yawHistory, yawRate)
end

function TuningOptimizer:onSectorComplete(sectorID, sectorTime)
    if self.tickCount < MIN_DATA_SAMPLES then self:reset() return end

    local avgYaw = self.yawAccumulator / self.tickCount
    local varianceSum = 0
    for _, yaw in ipairs(self.yawHistory) do
        varianceSum = varianceSum + (yaw - avgYaw)^2
    end
    local stabilityIndex = math.sqrt(varianceSum / self.tickCount)
    local avgTime = self:getRollingAverage(sectorID, 5) 

    local decision = self.driver.Decision
    local currentKp = decision.STEERING_Kp_BASE
    local currentKd = decision.STEERING_Kd_BASE
    
    local newKp = currentKp
    local newKd = currentKd
    local improved = false
    local debugMsg = ""

    -- A. CRASH RECOVERY (Highest Priority)
    if self.crashDetected then
        -- Big boost to Damping (Stability)
        newKd = math.min(1.5, currentKd + (LEARNING_RATE_PID * 4)) 
        -- Massive reduction in corner speed
        self.cornerLimit = math.max(1.2, self.cornerLimit - (LEARNING_RATE_PHYSICS * 2)) 
        -- Brake earlier
        self.brakingFactor = math.max(5.0, self.brakingFactor - (LEARNING_RATE_PHYSICS * 5)) 
        
        improved = true
        debugMsg = "CRASH DETECTED. Applying Safety Mode."

    -- B. SAFETY LAYER (Understeer)
    elseif self.understeerEvents > 1 then
        self.brakingFactor = math.max(5.0, self.brakingFactor - (LEARNING_RATE_PHYSICS * 5))
        self.cornerLimit = math.max(1.2, self.cornerLimit - LEARNING_RATE_PHYSICS)
        
        improved = true
        debugMsg = "Understeer Fix (Brakes/Speed Reduced)"
        
    -- C. STABILITY LAYER
    elseif stabilityIndex > STABILITY_THRESHOLD then
        newKd = currentKd + (LEARNING_RATE_PID * 2)
        newKp = math.max(0.05, currentKp - LEARNING_RATE_PID)
        self.cornerLimit = math.max(1.2, self.cornerLimit - (LEARNING_RATE_PHYSICS * 0.5))
        
        improved = true
        debugMsg = string.format("Stabilizing (Unstable %.2f)", stabilityIndex)

    -- D. PERFORMANCE LAYER
    else
        if avgTime == 0 or sectorTime < avgTime then
            self.brakingFactor = math.min(40.0, self.brakingFactor + LEARNING_RATE_PHYSICS)
            self.cornerLimit = math.min(3.5, self.cornerLimit + (LEARNING_RATE_PHYSICS * 0.2))
            newKp = currentKp + LEARNING_RATE_PID
            
            improved = true
            debugMsg = "Faster! Pushing Limits."
        else
            newKd = math.max(0.1, currentKd - LEARNING_RATE_PID)
            debugMsg = "Slower. Reducing Damping (Kd) to aid rotation."
        end
    end

    newKp = mathClamp(0.05, 0.80, newKp)
    newKd = mathClamp(0.10, 1.50, newKd)
    
    decision.STEERING_Kp_BASE = newKp
    decision.STEERING_Kd_BASE = newKd
    decision.brakingForceConstant = self.brakingFactor

    print(string.format("Opt [%d]: %s | T:%.2f (Avg:%.2f) | Kp:%.2f Kd:%.2f | Brk:%.1f Limit:%.1f", 
        self.driver.id, debugMsg, sectorTime, avgTime, newKp, newKd, self.brakingFactor, self.cornerLimit))

    if improved then
        self:saveProfile(newKp, newKd)
    end

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
    self.yawAccumulator = 0
    self.yawHistory = {}
    self.understeerEvents = 0 
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