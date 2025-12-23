-- TuningOptimizer.lua
-- Self-Tuning Module with Persistence Layer
dofile("globals.lua")
TuningOptimizer = class(nil)

local STABILITY_THRESHOLD = 0.8 
local LEARNING_RATE = 0.01      
local MIN_DATA_SAMPLES = 40    
local TUNING_FILE = TUNING_PROFILES -- located in globals.lua

function TuningOptimizer:init(driver)
    self.driver = driver
    self.history = {} 
    self.fingerprint = "CALCULATING" 
    self.retryTimer = 0

    -- [NEW] Physics Learning Params
    self.cornerLimit = 2.0 -- Start with default multiplier
    self.understeerEvents = 0
    
    self.tickCount = 0
    self.yawAccumulator = 0
    self.yawHistory = {}
    
    print("TuningOptimizer: Initialized.")
end

function TuningOptimizer:checkFingerprint()
    if self.fingerprint ~= "CALCULATING" then return end
    
    local fp = generatePhysicsFingerprint(self.driver)
    if fp ~= "INIT_WAIT" then
        self.fingerprint = fp
        self:loadProfile() -- Load the profile for this specific car setup
        print("TuningOptimizer: Car Fingerprint Identified: " .. self.fingerprint)
    end
end


function TuningOptimizer:loadProfile()
    local success, data = pcall(sm.json.open, TUNING_FILE)
    if not success or not data then return end
    
    -- 1. Try Exact Match (Best)
    if data[self.fingerprint] then
        self:applyProfile(data[self.fingerprint])
        print("Optimizer: Exact match loaded [" .. self.fingerprint .. "]")
        return
    end
    
    -- 2. Try Partial Match (Fuzzy Search)
    -- ID Format: "M1500_DF2000_L5.0_W3.0_sports"
    -- Search Key: "M1500_DF2000" (Match Mass and Downforce)
    local searchKey = string.sub(self.fingerprint, 1, string.find(self.fingerprint, "_L") - 1)
    
    print("Optimizer: Exact match not found. Searching for similar Mass/Aero [" .. searchKey .. "]...")
    
    for key, profile in pairs(data) do
        if string.sub(key, 1, string.len(searchKey)) == searchKey then
            self:applyProfile(profile)
            print("Optimizer: Partial Match found (" .. key .. "). Inheriting PID.")
            
            -- [OPTIONAL] Immediately save this as a new Exact Match entry 
            -- so this car starts refining its own specific profile immediately.
            self:saveProfile(profile.kp, profile.kd)
            return
        end
    end
    
    -- 3. Fallback to Engine Type Default
    local engineType = self.driver.engine.engineStats.TYPE
    if data[engineType] then
         self:applyProfile(data[engineType])
         print("Optimizer: Fallback to Engine Type default ("..engineType..").")
    end
end

function TuningOptimizer:applyProfile(profile)
    local decision = self.driver.Decision
    if profile.kp and profile.kd then
        decision.STEERING_Kp_BASE = profile.kp
        decision.STEERING_Kd_BASE = profile.kd
    end
    -- [NEW] Load learned cornering limit
    if profile.cornerLimit then
        self.cornerLimit = profile.cornerLimit
        print("Optimizer: Loaded Corner Limit: ", self.cornerLimit)
    end
end

function TuningOptimizer:saveProfile(kp, kd)
    -- Read current file first to preserve other car types
    local success, data = pcall(sm.json.open, TUNING_FILE)
    if not success or type(data) ~= "table" then data = {} end
    
    -- [FIX] Guard against nil fingerprint (Crash Fix)
    local typeKey = self.fingerprint or "GENERIC_SAFE_MODE"
    if typeKey == "CALCULATING" then typeKey = "GENERIC_SAFE_MODE" end

    data[typeKey] = {
        kp = kp,
        kd = kd,
        cornerLimit = self.cornerLimit,
        updated = os.time()
    }
    
    -- Write back to disk
    sm.json.save(data, TUNING_FILE)
    print("Optimizer: Saved improved profile for " .. typeKey)
end

function TuningOptimizer:reportUndersteer()
    -- Called by DecisionModule when the car slides wide
    self.understeerEvents = self.understeerEvents + 1
end


function TuningOptimizer:recordFrame(perceptionData)
    if self.fingerprint == "CALCULATING" then
        self:checkFingerprint()
        return -- Don't record data until we know who we are
    end
    if not self.driver.isRacing then return end
    
    local tel = perceptionData.Telemetry
    local yawRate = math.abs(tel.angularVelocity:dot(tel.rotations.up))
    
    self.tickCount = self.tickCount + 1
    self.yawAccumulator = self.yawAccumulator + yawRate
    table.insert(self.yawHistory, yawRate)
end

function TuningOptimizer:onSectorComplete(sectorID, sectorTime)
    if self.tickCount < MIN_DATA_SAMPLES then self:reset() return end

    -- 1. Calculate Stability
    local avgYaw = self.yawAccumulator / self.tickCount
    local varianceSum = 0
    for _, yaw in ipairs(self.yawHistory) do
        varianceSum = varianceSum + (yaw - avgYaw)^2
    end
    local stabilityIndex = math.sqrt(varianceSum / self.tickCount)

    -- 2. Current Gains
    local decision = self.driver.Decision
    local currentKp = decision.STEERING_Kp_BASE
    local currentKd = decision.STEERING_Kd_BASE
    
    local newKp = currentKp
    local newKd = currentKd
    local improved = false

    -- 3. Optimization Logic

    -- [NEW] Corner Speed Optimization
    if self.understeerEvents > 5 then
        -- We crashed/slid too much. Slow down.
        self.cornerLimit = math.max(1.2, self.cornerLimit - 0.1)
        print("Optimizer: Too much understeer ("..self.understeerEvents.."). Lowering Corner Limit to:", self.cornerLimit)
        improved = true
    elseif self.understeerEvents == 0 then
        -- Perfect sector? Try pushing slightly harder.
        self.cornerLimit = math.min(3.5, self.cornerLimit + 0.02)
        print("Optimizer: Clean sector. Raising Corner Limit to:", self.cornerLimit)
        -- Don't save on every tiny increase, only big changes
    end

    if stabilityIndex > STABILITY_THRESHOLD then
        -- UNSTABLE: Emergency Damping
        newKd = currentKd + (LEARNING_RATE * 2)
        newKp = currentKp - LEARNING_RATE
        improved = true -- We consider "fixing instability" an improvement worthy of saving
        print(string.format("Optimizer [%d]: Unstable (%.2f). Damping increased.", self.driver.id, stabilityIndex))
    else
        -- STABLE: Check for speed improvement
        local avgTime = self:getAverageSectorTime(sectorID)
        
        if avgTime == 0 or sectorTime < avgTime then
            -- FASTER: Increase sensitivity
            newKp = currentKp + LEARNING_RATE
            improved = true 
            print(string.format("Optimizer [%d]: Stable & Fast. Sensitivity increased.", self.driver.id))
        else
            -- SLOWER: Revert/Adjust balance (Do not save yet)
            newKp = currentKp - LEARNING_RATE
            newKd = newKd + LEARNING_RATE
            improved = false
            print(string.format("Optimizer [%d]: Slower. Adjusting Balance.", self.driver.id))
        end
    end

    -- 4. Apply Clamps
    newKp = mathClamp(0.05, 0.45, newKp)
    newKd = mathClamp(0.20, 1.40, newKd)
    
    decision.STEERING_Kp_BASE = newKp
    decision.STEERING_Kd_BASE = newKd

    -- 5. Persistence: Save only if we found an improvement (Fast or Fixing Stability)
    if improved then
        self:saveProfile(newKp, newKd)
    end

    -- 6. History Tracking
    table.insert(self.history, { sid = sectorID, time = sectorTime })
    self:reset()
end

function TuningOptimizer:getAverageSectorTime(sectorID)
    local total = 0
    local count = 0
    for _, entry in ipairs(self.history) do
        if entry.sid == sectorID then
            total = total + entry.time
            count = count + 1
        end
    end
    return count > 0 and (total / count) or 0
end

function TuningOptimizer:reset()
    self.tickCount = 0
    self.yawAccumulator = 0
    self.yawHistory = {}
    self.understeerEvents = 0 -- Reset counter
end