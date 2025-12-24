-- SMARL CAR AI V4 (Gen 8) Engine
-- Handles engine simulation (RPM, Torque, Gearing) and audio effects.

dofile("globals.lua")

Engine = class(nil)
Engine.maxChildCount = 100
Engine.maxParentCount = 2
Engine.connectionInput = sm.interactable.connectionType.power
Engine.connectionOutput = sm.interactable.connectionType.bearing + sm.interactable.connectionType.logic
Engine.colorNormal = sm.color.new(0xe6a14dff)
Engine.colorHighlight = sm.color.new(0xF6a268ff)

local ENGINE_SPEED_LIMIT = 1000 -- Hard limit fallback
local TUNING_DATA_PATH = "$CONTENT_DATA/JsonData/tuningData.json"

-- --- ENGINE EVENTS ---

function Engine.server_onCreate(self)
    self:server_init()
end

function Engine.client_onCreate(self)
    self:client_init()
end

function Engine.client_onDestroy(self)
    if self.effect then
        self.effect:destroy()
        self.effect = nil
    end
end

function Engine.server_onDestroy(self)
    if self.driver and not self.noDriverError then
        self.driver:on_engineDestroyed(self)
    end
end

function Engine.client_onRefresh(self)
    self:client_onDestroy()
    self:client_init()
end

function Engine.server_onRefresh(self)
    self:server_onDestroy()
    self:server_init()
end

-- --- INITIALIZATION ---

function Engine.server_init(self)
    self.id = self.shape.id
    self.interactable = self.shape:getInteractable()
    
    -- State
    self.noDriverError = false
    self.noStatsError = false
    self.driver = nil
    self.loaded = false
    
    -- Physics State
    self.accelInput = 0.0 -- Received from Driver (-1.0 to 1.0)
    self.curRPM = 0.0
    self.curVRPM = 0.0
    self.curGear = 1
    
    -- Engine Definition (Default)
    self.engineColor = "673b00" 
    self.engineStats = {
        TYPE = "custom",
        COLOR = "aaaa2f",
        MAX_SPEED = 250,
        MAX_ACCEL = 1,
        MAX_BRAKE = 1,
        GEARING = {0.25, 0.35, 0.40, 0.25, 0.15},
        REV_LIMIT = 50 -- Calculated below
    }
    self.engineStats.REV_LIMIT = self.engineStats.MAX_SPEED / #self.engineStats.GEARING
    
    -- Performance Modifiers
    self.totalSpeedModifier = 0.0
    
    -- Timers
    self.longTimer = 0 -- Simple tick counter
    
    -- Initial Setup
    self:updateType() 
    self:parseParents()
end

function Engine.client_init(self)
    self.engineNoiseEnabled = true
    if self.engineNoiseEnabled then
        self.effect = sm.effect.createEffect("GasEngine - Level 3", self.interactable)
        if self.effect then
            self.effect:setParameter("gas", 0)
            self.effect:setParameter("rpm", 0)
            self.effect:setParameter("load", 0)
        end
    end
end


--- Helpers
local function getWheelRPM(bearing)
    -- getAngularVelocity returns a vec3 (radians/sec). 
    -- For bearings, the local X axis is usually the rotation axis.
    sm.joint.getAngularVelocity(bearing)
    local angVel = bearing:getAngularVelocity()
    print(bearing,angVel)
    
    local radsPerSec = angVel:dot(bearing:getXAxis()) -- Project onto rotation axis
    return (radsPerSec * 60) / (2 * math.pi) -- Convert rad/s to RPM
end

-- --- MAIN UPDATE LOOP (40Hz) ---

function Engine.server_onFixedUpdate(self, dt)
    -- 1. Input Gathering
    self:parseParents() -- Get throttle input from Driver connection
    
    -- 2. Low-Frequency Updates (every ~1.5s)
    self.longTimer = self.longTimer + 1
    if self.longTimer > 60 then
        self:updateType()
        self.longTimer = 0
    end

    -- 3. Physics Simulation
    if not self.noDriverError and not self.noStatsError then
        self.curRPM = self:calculateRPM()
        self.curVRPM = self:calculateVRPM(self.curGear, self.curRPM)
    end

    -- 4. Safety Limiter
    local maxSafeRPM = (self.engineStats.MAX_SPEED or ENGINE_SPEED_LIMIT) + 15
    if self.curRPM >= maxSafeRPM then
        -- print(self.driver.id, "WARNING: Engine Overspeed", self.curRPM)
        self.curRPM = self.engineStats.MAX_SPEED * 0.8
    end

    -- 5. Output to Wheels
    self:setRPM(self.curRPM)
end

function Engine.client_onUpdate(self, dt)
    if self.engineNoiseEnabled then
        self:updateEffect()
    end
end

-- --- PHYSICS SIMULATION ---

function Engine.calculateRPM(self)
    if (not self.driver and not self.noDriverError) then 
        self:sv_setDriverError(true) 
        return 0 
    end
    
    if not self.driver or not self.engineStats then return 0 end

    -- Only run if race is active (or testing)
    if not self.driver.isRacing and not self.driver.active then -- check 'active' flag from driver
         self.curVRPM = 0
         return 0 
    end

    -- [NEW] TRACTION CONTROL LOGIC
    local slipDetected = false
    local telemetry = self.driver.perceptionData.Telemetry
    local carSpeed = telemetry.speed or 0
    -- Estimate "Road Speed" RPM (Speed / WheelCircumference * 60)
    -- 3 block wheel diameter approx 0.75m radius -> Circ ~4.7m
    local theoreticalRPM = (carSpeed * 60) / 4.7

    local maxSlipRatio = 0.0
    
    for _, bearing in pairs(sm.interactable.getBearings(self.interactable)) do
        local actualRPM = math.abs(getWheelRPM(bearing))
        local ratio = 0
        if theoreticalRPM > 50 then
            ratio = actualRPM / theoreticalRPM
        elseif actualRPM > 400 then 
            -- Car is stopped but wheels spinning fast -> Burnout
            print("burnout")
            ratio = 5.0 
        end
        
        if ratio > 1.5 then -- Wheel spinning 50% faster than road speed
            print("slipage")
            slipDetected = true
            maxSlipRatio = ratio
        end
    end

    if slipDetected then
         -- Physics Glitch Prevention: Cut throttle immediately
         -- This stops the "Infinite Energy" buildup that flips cars
         self.accelInput = self.accelInput * 0.1 
         self.curRPM = self.curRPM * 0.9 -- Drag down engine speed
         
         -- Optional: Visual Feedback
         if self.longTimer % 10 == 0 then
             print(self.driver.id, "TCS ACTIVE! Slip:", maxSlipRatio)
         end
    end

    -- 1. Base Increment based on input and gear
    local rpmIncrement = self:_calculateBaseRPMIncrement()
    
    -- 2. Modifiers (Drafting, Handicap)
    rpmIncrement = self:_applyPerformanceModifiers(rpmIncrement)
    
    -- 3. Apply Increment
    local nextRPM = self.curRPM + rpmIncrement
    
    -- 4. Gear & Rev Limits
    nextRPM = self:_applyGearLimits(nextRPM)
    nextRPM = self:_applyHardLimiter(nextRPM)
    
    return nextRPM
end

function Engine._calculateBaseRPMIncrement(self)
    local increment = 0
    local input = self.accelInput
    local stats = self.engineStats
    
    if input > 0 then
        -- Accelerating Forward
        if self.curGear > 0 then
            local gearAccel = self:getGearAccel(self.curGear)
            -- Add handicap assist to acceleration?
            -- local assist = ((self.driver.handicap or 1) / 2000) 
            increment = ratioConversion(0, 1, gearAccel, 0, input)
            
        elseif self.curGear < 0 then
             -- Moving forward but in reverse gear (braking/reversing direction)
             if self.curRPM > 0 then
                 increment = -ratioConversion(0, 1, stats.MAX_ACCEL, 0, input)
             else
                 -- Reversing
                 local revAccel = self:getGearAccel(self.curGear)
                 increment = ratioConversion(0, 1, revAccel, 0, input)
             end
        end
        
    elseif input < 0 then
        -- Braking (Input is negative)
        local brakeForce = ratioConversion(0, -1, -stats.MAX_BRAKE, 0, input)
        
        if self.curRPM > 10 then
            increment = brakeForce -- Reduce positive RPM
             -- Hard brake near stop
            if self.curRPM < 50 then increment = increment * 1.5 end
        elseif self.curRPM < -10 then
            increment = -brakeForce -- Reduce negative RPM
        else
            increment = -self.curRPM -- Stop
        end
        
    else
        -- Coasting (Engine Brake)
        if math.abs(self.curRPM) > 5 then 
            increment = -self.curRPM / 500 -- Gentle coast
        else
            increment = -self.curRPM / 10 -- Stop
        end
    end
    
    return increment
end

function Engine._applyPerformanceModifiers(self, increment)
    if not self.driver then return increment end
    
    -- Drafting Bonus
    -- Access Decision Module's mode if available, or check driver flags
    local isDrafting = (self.driver.Decision and self.driver.Decision.currentMode == "Drafting")
    
    if isDrafting and self.accelInput >= 0.9 then
        increment = increment + 0.00016 
    end
    
    -- Handicap (Top Speed Logic) - Calculated for Limiter, but could affect accel
    -- Storing modifier for limiter use
    self.totalSpeedModifier = 0 -- Reset
    -- Add handicap logic here if needed
    
    return increment
end

function Engine._applyGearLimits(self, nextRPM)
    local nextVRPM = self:calculateVRPM(self.curGear, nextRPM)
    local limit = self:getGearRPMMax(self.curGear)
    
    -- Rev Limiter Bounce
    if nextVRPM > limit then
        nextRPM = self.curRPM - 5 
    end
    
    return nextRPM
end

function Engine._applyHardLimiter(self, nextRPM)
    local increment = nextRPM - self.curRPM
    local maxSpeed = (self.engineStats.MAX_SPEED or ENGINE_SPEED_LIMIT) + self.totalSpeedModifier
    
    -- Forward Speed Limit
    if nextRPM >= maxSpeed and increment > 0 then
        local reduction = 1.06
        -- Passing/Drafting allows slight overspeed
        if self.driver.Decision and (self.driver.Decision.currentMode == "Drafting" or self.driver.Decision.currentMode == "OvertakeDynamic") then
             reduction = 1.02
        end
        
        nextRPM = nextRPM - (increment * reduction)
    
    -- Reverse Speed Limit
    elseif nextRPM <= -40 and increment < 0 then
        nextRPM = -40
    end

    return nextRPM
end

function Engine.calculateVRPM(self, gear, rpm)
    if not self.engineStats then return 0 end
    gear = gear or 1
    rpm = rpm or 0
    
    local limit = self:getGearRPMMax(gear)
    local min = self:getGearRPMMin(gear)
    
    if rpm >= limit then return self.engineStats.REV_LIMIT end
    if rpm <= min then return 0 end
    
    -- Standard VRPM (Simulation of engine sound pitch based on gear range)
    -- This maps the RPM range of the current gear to 0..REV_LIMIT for sound
    -- Simple Modulo approach from original code:
    return rpm % self.engineStats.REV_LIMIT 
end

-- --- ACTUATION ---

function Engine.setRPM(self, value)
    if self.noDriverError then value = 0 end
    
    local strength = 500 -- Default torque
    
    -- Dynamic Torque based on mass (optional)
    if self.driver and self.driver.perceptionData and self.driver.perceptionData.Telemetry.mass then
         local mass = self.driver.perceptionData.Telemetry.mass
         -- Simple scale: 500 torque for 1000kg, up to 7000 torque
         strength = math.max(500, math.min(7000, mass * 0.5))
    end

    for _, bearing in pairs(sm.interactable.getBearings(self.interactable)) do
        sm.joint.setMotorVelocity(bearing, value, strength)
    end
end

function Engine.setGear(self, gear)
    if not self.engineStats or not self.driver then return end
    if gear < -1 or gear > #self.engineStats.GEARING then return end
    
    self.curGear = gear
    -- self.driver.ActionModule will handle logic, Engine handles state
end

-- --- HELPERS ---

function Engine.getGearAccel(self, gear)
    if gear == 0 then return 0 end
    if gear < 0 then return 0.3 end -- Reverse acceleration
    if gear > #self.engineStats.GEARING then gear = #self.engineStats.GEARING end
    
    return self.engineStats.GEARING[gear] or 0.1
end

function Engine.getGearRPMMax(self, gear)
    if not self.engineStats then return 0 end
    if gear <= 0 then return self.engineStats.REV_LIMIT end
    return self.engineStats.REV_LIMIT * gear
end

function Engine.getGearRPMMin(self, gear)
    if gear <= 1 then return 0 end
    return self.engineStats.REV_LIMIT * (gear - 1)
end

-- --- DRIVER CONNECTION ---

function Engine.parseParents(self)
    local parents = self.interactable:getParents()
    local foundDriver = false
    
    for _, v in pairs(parents) do
        -- Check if parent is a Driver (Logic Input)
        local uuid = tostring(v:getShape():getShapeUuid())
        
        -- [FIX] Added check for DRIVER_GEN8_UUID so engine works with new drivers
        if uuid == DRIVER_UUID or uuid == DRIVER_GEN8_UUID then
             -- Store driver reference if we find one via global ID lookup
             local id = v:getShape():getId()
             local driver = getDriverFromId(id)
             if driver then
                 self.driver = driver
                 self.noDriverError = false
                 foundDriver = true
                 self.accelInput = v:getPower() -- Read throttle (-1 to 1)
             end
        end
    end
    
    if not foundDriver and self.noDriverError == false then
        self:sv_setDriverError(true)
        self.accelInput = 0
    else
        self:sv_setDriverError(false)
    end
end

function Engine.sv_setDriverError(self, state)
    self.noDriverError = state
    if state then self.driver = nil end
    self.network:sendToClients("cl_setNoDriver", state)
end

function Engine.cl_setNoDriver(self, state)
    self.noDriverError = state
end

-- --- AUDIO EFFECTS ---

function Engine.updateEffect(self)
    if not self.effect then return end
    if self.noDriverError then 
        self.effect:stop()
        return 
    end
    
    if not self.effect:isPlaying() then self.effect:start() end
    
    local revLimit = self.engineStats.REV_LIMIT
    local pitch = ratioConversion(0, revLimit, 0, 1.0, self.curVRPM)
    pitch = math.max(0.1, pitch)
    
    local load = math.abs(self.accelInput)
    
    self.effect:setParameter("rpm", pitch)
    self.effect:setParameter("load", load)
end

-- --- UTILS ---

function Engine.updateType(self)
    -- Check paint color to determine engine stats (Legacy feature)
    local color = tostring(self.shape.color)
    if color ~= self.engineColor then
        self.engineColor = color
        -- Reload stats based on color (Placeholder)
        -- self.engineStats = getEngineType(color) 
        
        -- Notify Driver to reload tuning
        if self.driver then self.driver:on_engineLoaded(self) end
    end
end

function Engine.generateNewEngine(self, baseStats)
    -- Helper to clone stats
    local new = {}
    for k,v in pairs(baseStats) do new[k] = v end
    -- Deep copy gearing
    if baseStats.GEARING then
        new.GEARING = {}
        for k,v in pairs(baseStats.GEARING) do new.GEARING[k] = v end
    end
    return new
end