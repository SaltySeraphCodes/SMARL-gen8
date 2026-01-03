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
local DRAFTING_SPEED_MULT = 1.15 -- 15% Top Speed Bonus
local DRAFTING_ACCEL_MULT = 1.10 -- 10% Acceleration Bonus

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
        MAX_SPEED = 50,
        MAX_ACCEL = 0.30,
        MAX_BRAKE = 0.80,
        GEARING = {0.25, 0.30, 0.27, 0.20, 0.15},
        REV_LIMIT = 50 -- Calculated below
    }
    self.engineStats.REV_LIMIT = self.engineStats.MAX_SPEED / #self.engineStats.GEARING
    
    -- Performance Modifiers
    self.totalSpeedModifier = 0.0
    
    -- Timers
    self.longTimer = 0 -- Simple tick counter

    self.wheelTypeTag = "NONE"

    -- learning
    self.learnSum = 0
    
    -- Initial Setup
    self:updateType() 
    self:parseParents()
    self:discoverChassis() -- [[ CHANGED ]]
    
    -- [[ NEW: Apply User Setup (Default) ]]
    self:applyUserSetup(5) -- Default Ratio 5
    
    -- [[ NEW: PHYSICS STATE ]]
    self.Fuel_Level = 1.0     -- 0.0 to 1.0 (100 Liters?)
    self.Tire_Health = 1.0    -- 0.0 to 1.0 (100%)
    self.Tire_Temp = 20.0     -- Degrees C. Optimal is 80-100.
    self.simulatedMass = 1000 -- Base Mass
    
    -- Sync these to Driver for Decision Module to see
    if self.driver then 
        self.driver.Fuel_Level = self.Fuel_Level
        self.driver.Tire_Health = self.Tire_Health
        self.driver.Tire_Temp = self.Tire_Temp
    end
end

function Engine.applyUserSetup(self, gearRatio)
    -- Map 1..10 to performance multipliers
    -- Ratio 1: High Accel (Short Gears), Low Top Speed
    -- Ratio 10: Low Accel (Tall Gears), High Top Speed
    
    local ratio = math.max(1, math.min(10, gearRatio))
    
    -- Speed Multiplier: 1 -> 0.6x, 5 -> 1.0x, 10 -> 1.8x
    local speedMult = 0.5 + (ratio * 0.13)
    
    -- Accel Multiplier: 1 -> 1.5x, 5 -> 1.0x, 10 -> 0.6x
    local accelMult = 1.6 - (ratio * 0.1)
    
    self.engineStats.REV_LIMIT = (self.engineStats.MAX_SPEED * speedMult) / #self.engineStats.GEARING
    
    -- We store this multiplier to apply it to torque calculation dynamically
    self.gearRatioTorqueMult = accelMult 
    
    print(string.format("Engine: Applied Gear Ratio %d. Top Speed Scale: %.2f, Accel Scale: %.2f", ratio, speedMult, accelMult))
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
    local val = bearing:getAngularVelocity()
    if type(val) ~= "number" then return 0 end
    return (math.abs(val) * 60) / (2 * math.pi)
end

-- [[ NEW: CHASSIS DISCOVERY ]]
function Engine.discoverChassis(self)
    if not self.driver or not self.driver.shape then 
        -- If no driver yet, just scan for wheel type vaguely
        self:scanWheelType()
        return 
    end
    
    local driverShape = self.driver.shape
    local driverPos = driverShape:getWorldPosition()
    
    -- Driver Orientation determines "Forward"
    local driverFwd = driverShape:getAt()
    local driverRight = driverShape:getRight()
    
    local bearings = sm.interactable.getBearings(self.interactable)
    if #bearings == 0 then 
        print("Engine: No Bearings Connected.")
        self.wheelTypeTag = "NONE"
        return 
    end
    
    local minX, maxX = 0, 0
    local minY, maxY = 0, 0
    local wheelCount = 0
    
    for _, bearing in ipairs(bearings) do
        local uuid = ""
        local shape = sm.joint.getShapeB(bearing)
        if shape then
            uuid = tostring(shape:getShapeUuid())
            
            -- Wheel Type Detection (Legacy Support)
            local code = getWheelCode(uuid)
            if code ~= "UNK" and self.wheelTypeTag == "NONE" then
                 self.wheelTypeTag = code
            end
        end
        
        -- Geometric Calculations
        local bearingPos = bearing:getWorldPosition()
        local relPos = bearingPos - driverPos
        
        -- Project onto Driver Axes
        -- X = Right/Left (Dot with Right)
        -- Y = Fwd/Back (Dot with Fwd)
        local latDist = relPos:dot(driverRight)
        local longDist = relPos:dot(driverFwd)
        
        if latDist < minX then minX = latDist end
        if latDist > maxX then maxX = latDist end
        if longDist < minY then minY = longDist end
        if longDist > maxY then maxY = longDist end
        
        wheelCount = wheelCount + 1
    end
    
    if self.wheelTypeTag == "NONE" and wheelCount > 0 then self.wheelTypeTag = "UNK" end
    
    -- Calculate Dimensions
    local trackWidth = maxX - minX
    local wheelbase = maxY - minY
    
    -- Check for "Bike" or "Trike" configs to avoid math errors
    if trackWidth < 0.5 then trackWidth = 1.0 end
    if wheelbase < 0.5 then wheelbase = 1.0 end
    
    -- Store Data in Driver for Guidance Module
    if self.driver.chassisData == nil then self.driver.chassisData = {} end
    self.driver.chassisData.wheelbase = wheelbase
    self.driver.chassisData.trackWidth = trackWidth
    
    -- [[ NEW: Store Bearing References for Torque Vectoring ]]
    self.driver.chassisData.wheels = { FL={}, FR={}, RL={}, RR={} }
    
    local centerLong = (minY + maxY) * 0.5
    local centerLat = (minX + maxX) * 0.5
    
    for _, bearing in ipairs(bearings) do
        local pos = bearing:getWorldPosition()
        local rel = pos - driverPos
        local lat = rel:dot(driverRight)
        local long = rel:dot(driverFwd)
        
        -- Using Center offsets to classify (Robust against odd CoM)
        local isFront = (long > centerLong)
        local isRight = (lat > centerLat) -- Assuming Right Vec points Right
        
        local category = ""
        if isFront then
            if isRight then category = "FR" else category = "FL" end
        else
            if isRight then category = "RR" else category = "RL" end
        end
        
        table.insert(self.driver.chassisData.wheels[category], bearing)
    end
    
    print(string.format("Engine: Chassis Discovered. WB: %.2f, TW: %.2f, Type: %s", wheelbase, trackWidth, self.wheelTypeTag))
end

-- Fallback for no-driver init
function Engine.scanWheelType(self)
    -- Iterate through all bearings connected to the engine
    local bearings = sm.interactable.getBearings(self.interactable)
    
    for _, bearing in ipairs(bearings) do
        local shape = sm.joint.getShapeB(bearing)
        if shape then
            local uuid = tostring(shape:getShapeUuid())
            local code = getWheelCode(uuid)
            if code ~= "UNK" then
                self.wheelTypeTag = code
                return
            end
        end
    end
    if self.wheelTypeTag == "NONE" then self.wheelTypeTag = "UNK" end
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
        
        -- [[ NEW: SIMULATION LOOP ]]
        self:updatePhysicsState(dt)
        self:setRPM(self.curRPM)
    end
end

function Engine.updatePhysicsState(self, dt)
    local throttle = math.abs(self.accelInput or 0)
    local speed = 0
    local slip = 0
    local downforce = 0
    
    if self.driver and self.driver.perceptionData and self.driver.perceptionData.Telemetry then
        local tm = self.driver.perceptionData.Telemetry
        speed = tm.speed or 0
        -- Approx Slip: Angular Vel * Speed? Or just Lateral G?
        -- Let's use GripUsage from Driver if available, else estimate.
        if self.driver.gripUsage then
             slip = self.driver.gripUsage
        else
             -- Estimate: Speed * Steer
             local steer = math.abs(self.driver.perceptionData.steer or 0)
             slip = math.min(1.0, (speed / 50.0) * steer)
        end
        downforce = tm.downforce or 0 -- Artificial Downforce Power
    end
    
    -- 1. FUEL BURN
    local rc = getRaceControl()
    local rm = rc and rc.RaceManager
    
    if rm and rm.fuelUsageEnabled then
        local burnRate = 0.00003 * (rm.fuelUsageMultiplier or 1.0)
        local fuelConsumed = burnRate * dt * (0.2 + (throttle * 0.8)) -- Idle burn 20%
        self.Fuel_Level = math.max(0, self.Fuel_Level - fuelConsumed)
    end
    
    -- 2. TIRE WEAR
    if rm and rm.tireWearEnabled then
        local wearRate = 0.00001 * dt * (rm.tireWearMultiplier or 1.0)
        -- Load Factor: 1.0 + Downforce/10 + Slip*5
        local loadFactor = 1.0 + (downforce / 100.0) + (slip * 5.0)
        local speedFactor = (speed / 50.0)
        
        local wear = wearRate * speedFactor * loadFactor
        self.Tire_Health = math.max(0, self.Tire_Health - wear)
    end
    
    -- 3. TIRE TEMP
    if rm and rm.tireHeatEnabled then
        -- Heating: Friction (Slip * Speed) + Braking
        -- Cooling: Airflow (Speed)
        local heating = (slip * speed * 2.0) * dt
        -- Braking Heat
        if self.accelInput and self.accelInput < 0 then heating = heating + (math.abs(self.accelInput) * 5.0 * dt) end
        
        local ambient = 20.0
        local cooling = 0.5 * dt * (1.0 + (speed / 10.0)) -- Airflow cooling
        
        self.Tire_Temp = self.Tire_Temp + heating - cooling
        -- Hysteresis towards ambient if stopped
        if speed < 1.0 then 
            self.Tire_Temp = self.Tire_Temp + (ambient - self.Tire_Temp) * 0.1 * dt
        end
    else
        -- Force Optimal Temp if Heat is Disabled
        self.Tire_Temp = 90.0
    end
    
    -- SYNC TO DRIVER
    if self.driver then
        self.driver.Fuel_Level = self.Fuel_Level
        self.driver.Tire_Health = self.Tire_Health
        self.driver.Tire_Temp = self.Tire_Temp
    end
end

function Engine.client_onUpdate(self, dt)
    if self.engineNoiseEnabled then
        self:updateEffect()
    end
end

-- --- PHYSICS SIMULATION ---

function Engine.calculateRPM(self)
    if (not self.driver and not self.noDriverError) then self:sv_setDriverError(true); return 0 end
    if not self.driver or not self.engineStats then return 0 end

    -- 1. FETCH TRACTION CONSTANT
    local tractionConst = 2.6
    local tcsConverged = false
    if self.driver.Optimizer then
        tractionConst = self.driver.Optimizer.tractionConstant or 2.6
        tcsConverged = self.driver.Optimizer.tcsConverged
    end

    -- 2. TRACTION CONTROL & CALIBRATION
    local slipDetected = false
    
    if self.driver.perceptionData and self.driver.perceptionData.Telemetry then
        local telemetry = self.driver.perceptionData.Telemetry
        local carSpeed = telemetry.speed or 0
        local theoreticalRPM = (carSpeed * 60) / tractionConst
        
        -- TCS SENSITIVITY
        -- If converged (Profile Learned), we use a tight 1.3x limit (high performance).
        -- If not converged, we use a loose 2.0x limit (safety only).
        local slipLimit = tcsConverged and 1.2 or 1.5
        
        local avgActualRPM = 0
        local wheelCount = 0

        -- [LEARNING CONDITION]
        -- We only learn when:
        -- 1. Going fast enough (> 5.0)
        -- 2. Accelerating gently OR We are desperate (Throttle is high but speed is low)
        -- 3. Not steering hard
        local isLearning = false
        local steerInput = math.abs(self.driver.perceptionData.steer or 0)
        local speed = self.driver.perceptionData.Telemetry.speed
        
        local yawRate = 0
        if self.driver.perceptionData.Telemetry.angularVelocity then
             local av = self.driver.perceptionData.Telemetry.angularVelocity
             local up = self.driver.perceptionData.Telemetry.rotations.up
             yawRate = math.abs(av:dot(up))
        end

        local isDesperate = (speed > 5.0 and speed < 35.0 and self.accelInput > 0.8)

        -- [[ CHANGED: ADD YAW CHECK ]]
        -- Only learn if steering is straight AND the car isn't spinning (Yaw < 0.5)
        if (isDesperate) and steerInput < 0.1 and yawRate < 0.5 then
            isLearning = true
        end

        local avgActualRPM = 0
        local wheelCount = 0
        
        for _, bearing in pairs(sm.interactable.getBearings(self.interactable)) do
            local actualRPM = getWheelRPM(bearing)
            
            if theoreticalRPM > 50 then
                local ratio = actualRPM / theoreticalRPM
                if ratio > slipLimit then 
                    slipDetected = true 
                end
            end
            
            -- Accumulate Data for Learning
            if isLearning then
                avgActualRPM = avgActualRPM + actualRPM
                wheelCount = wheelCount + 1
            end
        end


        -- [PERFORM CALIBRATION]
        -- If we have already converged (locked), DO NOT update unless we are absolutely sure.
        -- This stops the "fluctuation after corners" because we stop calculating during minor instability.
        if isLearning and wheelCount > 0 and not tcsConverged then
            avgActualRPM = avgActualRPM / wheelCount
            
            -- Solve for Constant: Const = (Speed * 60) / RPM
            if avgActualRPM > 50 then
                local calculatedConst = (carSpeed * 60) / avgActualRPM
                
                -- Sanity Filter: Ratio typically falls between 1.0 (Huge Wheels) and 6.0 (Tiny Wheels)
                if calculatedConst > 1.0 and calculatedConst < 8.0 then
                    self.learnSum = self.learnSum + calculatedConst
                    self.learnCount = self.learnCount + 1
                    
                    -- Commit data after ~60 ticks (1.5 seconds) of consistent driving
                    if self.learnCount > 60 then
                        local finalConst = self.learnSum / self.learnCount
                        
                        -- Send to Optimizer to Save
                        if self.driver.Optimizer then
                            self.driver.Optimizer:updateTractionConstant(finalConst)
                        end
                        
                        -- Reset buffers
                        self.learnSum = 0
                        self.learnCount = 0
                    end
                end
            end
        else
            -- If we stop meeting conditions (e.g. brake or corner) OR we are converged:
            self.learnCount = 0 
            self.learnSum = 0
        end
    end

    if slipDetected then
       -- Only reduce throttle by 20% (0.8) or 50% (0.5) if not converged
        local cutSeverity = tcsConverged and 0.5 or 0.4 
        self.accelInput = self.accelInput * cutSeverity 
        -- Don't cut RPM directly, let physics handle it
    end

    if not self.driver.isRacing and not self.driver.active then self.curVRPM = 0; return 0 end
    local rpmIncrement = self:_calculateBaseRPMIncrement()
    rpmIncrement = self:_applyPerformanceModifiers(rpmIncrement)
    local nextRPM = self.curRPM + rpmIncrement
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
    
    -- DRAFTING BONUS (ACCELERATION)
    local isDrafting = (self.driver.Decision and self.driver.Decision.currentMode == "Drafting")
    
    if isDrafting and self.accelInput >= 0.9 then
        -- Apply percentage boost instead of flat adder for better scaling
        increment = increment * DRAFTING_ACCEL_MULT
    end

    -- HANDICAP BONUS/REDUCTION (Acceleration) (TODO)
    
    self.totalSpeedModifier = 0 
    return increment
end

function Engine._applyGearLimits(self, nextRPM)
    local nextVRPM = self:calculateVRPM(self.curGear, nextRPM)
    local limit = self:getGearRPMMax(self.curGear)
    
    -- Rev Limiter Bounce
    if nextVRPM > limit then
        --print("rev limit bounce")
        nextRPM = self.curRPM - 5 
    end
    
    return nextRPM
end

function Engine._applyHardLimiter(self, nextRPM)
    --print("HL",nextRPM,self.curRPM)
    local increment = nextRPM - self.curRPM
    
    local tractionConst = 2.6
    if self.driver and self.driver.Optimizer and self.driver.Optimizer.tractionConstant then
        tractionConst = self.driver.Optimizer.tractionConstant
    end

    -- DRAFTING BONUS (TOP SPEED)
    local baseSpeed = (self.engineStats.MAX_SPEED or 100) + self.totalSpeedModifier
    local isDrafting = (self.driver.Decision and self.driver.Decision.currentMode == "Drafting")
    
    if isDrafting then
        baseSpeed = baseSpeed * DRAFTING_SPEED_MULT
    end
    
    -- [[ FIX: UNIT CORRECTION ]]
    -- OLD (BROKEN): local calculatedLimit = (baseSpeed * 2 * math.pi) / tractionConst
    -- This confused Radians (2pi) with RPM (60). 
    -- Since tractionConst = (Speed * 60) / RPM, we must use 60 here to reverse it.
    
    local calculatedLimit = (baseSpeed * 60.0) / tractionConst
    
    -- Sanity Check: Don't let the limit crush the engine below idle
    if calculatedLimit < 500 then calculatedLimit = 500 end

    -- Apply Limit
    if nextRPM >= calculatedLimit and increment > 0 then
        -- Soft limiter: Reduce the acceleration increment
        --print("soft limit",nextRPM,calculatedLimit,increment)
        nextRPM = nextRPM - (increment * 1.05)
    elseif nextRPM <= -40 and increment < 0 then
        ---print("reverse?",nextRPM,increment)
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
    local count = 0
    local totalAngularVel = 0
    
    -- [[ NEW: TORQUE VECTORING (RPM Differential) ]]
    -- We need to know which bearings are Left/Right.
    -- We can use the chassisData if available, or calculate on the fly (less efficient).
    -- Let's use chassisData since we built it.
    
    local chassis = self.driver.chassisData
    local tvBias = 0.0 -- Positive = Bias to Right (Left Turn), Negative = Bias to Left (Right Turn)
    
    local escLeftCut = 0.0
    local escRightCut = 0.0
    
    if self.driver.perceptionData then
        local st = self.driver.perceptionData.steer or 0.0
        local sp = self.driver.perceptionData.Telemetry.speed or 0.0
        
        -- 1. TORQUE VECTORING
        if ENABLE_TORQUE_VECTORING and sp > 5.0 and math.abs(st) > 0.05 then
             local intensity = TV_INTENSITY or 1.0
             tvBias = st * (sp / 50.0) * intensity
             tvBias = math.max(-0.4, math.min(0.4, tvBias))
        end
        
        -- 2. STABILITY CONTROL (ESC)
        -- Logic: If sliding, brake the "Corner" that stops the spin.
        -- Oversteer Left (Spinning CCW): Brake Outer Front (Right Front).
        -- Oversteer Right (Spinning CW): Brake Outer Front (Left Front).
        if ENABLE_ESC and self.driver.Decision and self.driver.Decision.controls then
            local slide = self.driver.Decision.controls.slideSeverity or 0.0
            
            if slide > 0.2 then
                 -- Determine Direction of Slide vs Steer?
                 -- Decision doesn't give direction of slide directly, but we can infer from Yaw.
                 -- If Yaw is Left and Steer is Right -> Oversteer Left.
                 
                 -- Simply: Brake the side we are turning AWAY from? 
                 -- Actually, simpler: Brake the OUTER Front wheel relative to the SPIN.
                 -- If Yaw is Positive (Left), brake Right Front.
                 -- If Yaw is Negative (Right), brake Left Front.
                 
                 local yaw = 0
                 if self.driver.perceptionData.Telemetry.angularVelocity then
                     yaw = self.driver.perceptionData.Telemetry.angularVelocity.z -- Local Z or World Z? 
                     -- Telemetry.angularVelocity is World. Rotations.up is World Up.
                     -- Dot them.
                     yaw = self.driver.perceptionData.Telemetry.angularVelocity:dot(self.driver.perceptionData.Telemetry.rotations.up)
                 end
                 
                 local escForce = slide * (ESC_INTENSITY or 0.5)
                 if math.abs(yaw) > 0.2 then
                     if yaw > 0 then -- Spinning Left
                         escRightCut = escForce -- Brake Right
                     else -- Spinning Right
                         escLeftCut = escForce -- Brake Left
                     end
                 end
            end
        end
    end
    
    -- Apply to Bearings
    if chassis and chassis.wheels then
        local function apply(list, multiplier)
            for _, bearing in ipairs(list) do
                sm.joint.setMotorVelocity(bearing, value * multiplier, strength)
                local av = bearing:getAngularVelocity()
                totalAngularVel = totalAngularVel + math.abs(av)
                count = count + 1
            end
        end
        
        -- TV: Steer Left (st>0) -> tvBias > 0. Left Slower (-), Right Faster (+).
        -- ESC: Cut is strictly subtractive (Braking).
        
        local flMult = 1.0 - tvBias - escLeftCut
        local rlMult = 1.0 - tvBias -- ESC usually only brakes Front for stability? Or all? Let's keep Rear Grip pure for now.
        
        local frMult = 1.0 + tvBias - escRightCut
        local rrMult = 1.0 + tvBias
        
        -- Clamp to prevent reverse rotation during forward driving
        flMult = math.max(0.0, flMult)
        frMult = math.max(0.0, frMult)
        rlMult = math.max(0.0, rlMult)
        rrMult = math.max(0.0, rrMult)

        apply(chassis.wheels.FL, flMult)
        apply(chassis.wheels.RL, rlMult)
        apply(chassis.wheels.FR, frMult)
        apply(chassis.wheels.RR, rrMult)
        
    else
        -- Fallback (Legacy / No Chassis Data)
        for _, bearing in pairs(sm.interactable.getBearings(self.interactable)) do
            sm.joint.setMotorVelocity(bearing, value, strength)
            if self.driver and self.driver.perceptionData and self.driver.perceptionData.Telemetry then
                local av = bearing:getAngularVelocity()
                totalAngularVel = totalAngularVel + math.abs(av)
                count = count + 1
            end
        end 
    end
    
    -- Move this OUTSIDE the loop so it runs once after summing all wheels
    if count > 0 then
        local avgRadS = totalAngularVel / count
        -- Store on self so Perception can read it anytime
        self.avgWheelRPM = (avgRadS * 60) / (2 * math.pi)
    else
        self.avgWheelRPM = 0
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
        if self.driver then self.driver:on_engineLoaded(self) end
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