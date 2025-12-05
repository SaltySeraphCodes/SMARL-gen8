-- This is everything that has to do with Outputting the right formatted data to the steering bearings and engine power
dofile("globalsGen8.lua") -- Assuming this file contains mathClamp and the class definition
ActionModule = class(nil)

-- Constant used to map the normalized steer factor (-1 to 1) to a physical angle.
local MAX_WHEEL_ANGLE_RAD = 0.8 -- This must match the constant in DecisionModule

-- Add a new constant for steering tuning:
local MAX_ADJUSTMENT = 10.0 -- Fast adjustment for low speed
local MIN_ADJUSTMENT = 3.0  -- Slow adjustment for high speed
local ADJUSTMENT_SPEED_REF = 50.0 -- Speed at which adjustment starts to dampen (m/s)

function ActionModule.server_init(self,driver)
    self.Driver = driver -- The main driver, contains body and shape information
    self.steeringOut = 0 
    self.throttleOut = 0
    self.curGear = 1 -- Start in first gear
end



-- Gearing ---
function ActionModule.shiftGear(self,gear) --sets the gear for engine (Possibly move to ActionModule?)
    if self.Driver.engine == nil then return end
    if self.Driver.engine.engineStats == nil then return end
    self.curGear = gear
    self.Driver.engine:setGear(gear)
end


function ActionModule.updateGearing_old(self)
    if self.Driver.engine == nil or self.decisionData == nil then return 1 end

    local rpm = self.Driver.engine.curRPM
    local vrpm = self.Driver.engine.curVRPM -- Use the Engine's calculated VRPM
    local revLimit = self.Driver.engine.engineStats.REV_LIMIT
    local nextGear = self.curGear
    local highestGear = #self.Driver.engine.engineStats.GEARING

    -- The AI's intent:
    local ai_throttle = self.decisionData.throttle
    local ai_brake = self.decisionData.brake
    
    if self.Driver.racing or self.Driver.isRacing or self.Driver.experiment then
        if ai_throttle > 0.3 then -- If the AI intends to accelerate
            if self.curGear <= 0 then -- Always go to first gear if neutral/reverse
                nextGear = 1
            elseif revLimit - vrpm < 0.1 then -- Upshift threshold based on VRPM proximity to limit
                if self.curGear < highestGear then
                    nextGear = self.curGear + 1
                end
            elseif vrpm <= 0.01 and self.curGear > 1 and rpm > 10 then -- Downshift if stalled in high gear
                nextGear = self.curGear - 1
            end
            
        elseif ai_brake > 0.1 or ai_throttle < 0.1 then -- If coasting or braking
            if vrpm < revLimit * 0.2 then -- Downshift Threshold (e.g., 20% of max VRPM)
                if self.curGear > 1 then
                    nextGear = self.curGear - 1 
                end
            end
            -- Check for reverse when stopped and braking hard (e.g., stuck)
            if self.Driver.engine.curRPM < 5 and ai_brake > 0.8 then
                nextGear = -1
            end
        end
    end

    if nextGear ~= self.curGear then
        self:shiftGear(nextGear)
    end
end

function ActionModule.updateGearing(self)
    -- Check if engine is available and has stats (tuning data loaded)
    if self.Driver.engine == nil or self.Driver.engine.engineStats == nil then return end

    local engine = self.Driver.engine
    local vrpm = engine.curVRPM 
    local rpm = engine.curRPM
    local revLimit = engine.engineStats.REV_LIMIT
    local highestGear = #engine.engineStats.GEARING

    local ai_throttle = self.decisionData.throttle
    local ai_brake = self.decisionData.brake
    local currentSpeed = self.Driver.perceptionData.Telemetry.speed or 0.0

    local nextGear = self.curGear
    
    -- Gearing is only active if the race status allows it
    if self.Driver.racing or self.Driver.isRacing then
        -- --- 1. UPSHIFT LOGIC ---
        if ai_throttle > 0.3 then -- If the AI is pressing the throttle
            if self.curGear <= 0 then 
                nextGear = 1 -- Always shift to first gear from neutral/reverse
            elseif vrpm >= revLimit * 0.95 then -- Near 95% of the VRPM limit
                if self.curGear < highestGear then
                    nextGear = self.curGear + 1 -- Upshift
                end
            end
        end

        -- --- 2. DOWNSHIFT LOGIC ---
        -- Threshold 1: Speed is low and RPM/VRPM are very low (e.g., car is stalling or coasting)
        if currentSpeed < 10.0 and self.curGear > 1 and vrpm < revLimit * 0.2 then
             nextGear = self.curGear - 1 

        -- Threshold 2: Braking aggressively
        elseif ai_brake > 0.4 and self.curGear > 1 and vrpm < revLimit * 0.35 then
            -- Downshift to provide engine braking and prepare for corner exit
             nextGear = self.curGear - 1
        end

        -- --- 3. REVERSE LOGIC ---
        -- Only shift to reverse when stopped and aggressively braking (e.g., trying to back up from a wall)
        if currentSpeed < 1.0 and ai_brake > 0.8 and self.curGear >= 0 then
            nextGear = -1
        end
    end

    -- --- 4. EXECUTE SHIFT ---
    if nextGear ~= self.curGear then
        self:shiftGear(nextGear)
    end
end


-- Converts normalized steer factor into a physical target angle for the bearings
function ActionModule.setSteering(self, steerFactor,currentSpeed)
    
    local targetAngle = steerFactor * MAX_WHEEL_ANGLE_RAD

    -- 1. Calculate Dynamic Adjustment Rate
    -- Interpolate between MAX_ADJUSTMENT (at speed 0) and MIN_ADJUSTMENT (at ADJUSTMENT_SPEED_REF)
    local speedRatio = math.min(currentSpeed / ADJUSTMENT_SPEED_REF, 1.0)
    local adjustmentRate = MAX_ADJUSTMENT + (MIN_ADJUSTMENT - MAX_ADJUSTMENT) * speedRatio
    
    -- 2. Apply the dynamic rate to all steering bearings
    for k, v in pairs(sm.interactable.getBearings(self.Driver.interactable)) do
        -- Use high strength (1500) for firm steering
        sm.joint.setTargetAngle( v, targetAngle, adjustmentRate, 1500)
    end
    self.steeringOut = targetAngle
end

-- Converts separate throttle/brake values into a single engine power value (-1.0 to 1.0)
function ActionModule.outputThrotttle(self, throttleValue, brakeValue)
    local engineOutput = 0.0

    if throttleValue > 0.0 then
        -- Accelerate (Positive Power)
        engineOutput = throttleValue
    elseif brakeValue > 0.0 then
        -- Brake/Reverse (Negative Power)
        engineOutput = -brakeValue 
    end
    self.Driver.interactable:setPower(engineOutput)
end

-- Applies Control data to the car
function ActionModule.applyControls(self,controls) 
    -- 1. Apply Steering
    local currentSpeed = self.Driver.perceptionData.Telemetry.speed or 0.0
    self:setSteering(controls.steer,currentSpeed)

    -- 2. Apply Throttle/Brake
    self:outputThrotttle(controls.throttle, controls.brake)

    -- 3. Handle Utility (Reset)
    if controls.resetCar then 
        self.Driver:resetCar() -- Assumes Driver class has a resetCar() method
    end 
    --print("S:",currentSpeed,"T:",controls.throttle,"B:",controls.brake)
end

-- Main module called every tick to process controls
function ActionModule.server_onFixedUpdate(self,decisionData)
    self.decisionData = decisionData
    self:updateGearing() -- Update the gear based on current conditions
    self:applyControls(decisionData)

end