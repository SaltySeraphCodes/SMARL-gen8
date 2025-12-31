-- ActionModule.lua
dofile("globals.lua")
ActionModule = class(nil)

local MAX_WHEEL_ANGLE_RAD = 0.8 
-- [FIX] Lowered drastically to match your stable "Old Code" values.
-- High values (12-15) cause physics glitches/explosions.
local MAX_ADJUSTMENT = 6.0   
local MIN_ADJUSTMENT = 3.0   
local ADJUSTMENT_SPEED_REF = 50.0

function ActionModule.server_init(self,driver)
    self.Driver = driver
    self.steeringOut = 0
    self.throttleOut = 0
    self.curGear = 1
    self.shiftTimer = 0.0 
end

function ActionModule.shiftGear(self,gear) 
    if self.Driver.engine == nil then return end
    if self.Driver.engine.engineStats == nil then return end
    self.curGear = gear
    self.Driver.engine:setGear(gear)
end

function ActionModule.updateGearing(self, dt)
    if self.Driver.engine == nil or self.Driver.engine.engineStats == nil then return end
    
    self.shiftTimer = math.max(0, self.shiftTimer - dt)
    if self.shiftTimer > 0 then return end 

    local engine = self.Driver.engine
    local vrpm = engine.curVRPM 
    local revLimit = engine.engineStats.REV_LIMIT
    local highestGear = #engine.engineStats.GEARING
    local ai_throttle = self.decisionData.throttle
    local ai_brake = self.decisionData.brake
    local telemetry = self.Driver.perceptionData.Telemetry
    local currentSpeed = telemetry.speed or 0.0
    local yawRate = math.abs(telemetry.angularVelocity:dot(telemetry.rotations.up))
    
    local nextGear = self.curGear
    
    if self.Driver.racing or self.Driver.isRacing then
        if ai_throttle > 0.5 and vrpm >= revLimit * 0.92 then 
            if self.curGear < highestGear then
                nextGear = self.curGear + 1 
            end
        end

        if yawRate < 1.5 then 
            if ai_brake > 0.5 and self.curGear > 1 then
                if vrpm < revLimit * 0.4 then
                    nextGear = self.curGear - 1
                end
            elseif currentSpeed < 5.0 and self.curGear > 1 then
                nextGear = 1 
            end
        end

        if currentSpeed < 1.0 and ai_brake > 0.8 and self.curGear >= 0 then
            nextGear = -1
        elseif self.curGear == -1 and ai_throttle > 0.5 then
            nextGear = 1
        end
    end

    if nextGear ~= self.curGear then
        self:shiftGear(nextGear)
        self.shiftTimer = 0.4 
    end
end

function ActionModule.setSteering(self, steerFactor, currentSpeed)
    local targetAngle = steerFactor * MAX_WHEEL_ANGLE_RAD
    
    local bearings = sm.interactable.getBearings(self.Driver.interactable)
    if #bearings > 0 then
        local currentAngle = bearings[1]:getAngle()
        -- If we are asking for Left, but wheel is stuck Right...
        local error = math.abs(targetAngle - currentAngle)
        
        -- [[ FIX: DO NOT RETURN. Just print warning if debugging. ]]
        -- If we return here, the car goes limp in a crash!
        if error > 0.5 then 
             -- Optional: self.Driver.Decision.stuckTimer = self.Driver.Decision.stuckTimer + 0.1
        end
    end

    -- Normal Operation (ALWAYS APPLY FORCE)
    self:applyBearingForce(targetAngle, 5)
    self.steeringOut = targetAngle
end

-- Helper to apply the force
function ActionModule:applyBearingForce(angle, speed)
    for k, v in pairs(sm.interactable.getBearings(self.Driver.interactable)) do
        sm.joint.setTargetAngle(v, angle, 2000, 2000)
    end
end

function ActionModule.outputThrotttle(self, throttleValue, brakeValue)
    local engineOutput = 0.0
    if throttleValue > 0.0 then
        engineOutput = throttleValue
    elseif brakeValue > 0.0 then
        engineOutput = -brakeValue 
    end
    self.Driver.interactable:setPower(engineOutput)
end

function ActionModule.applyControls(self, controls) 
    local currentSpeed = self.Driver.perceptionData.Telemetry.speed or 0.0
    self:setSteering(controls.steer, currentSpeed) 
    self:outputThrotttle(controls.throttle, controls.brake)
    if controls.resetCar then 
        self.Driver:resetCar() 
    end 
end

function ActionModule.server_onFixedUpdate(self,decisionData,dt)
    self.decisionData = decisionData
    self:updateGearing(dt) 
    self:applyControls(decisionData)
end