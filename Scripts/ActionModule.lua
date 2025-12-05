-- ActionModule.lua
dofile("../globals.lua")
ActionModule = class(nil)

local MAX_WHEEL_ANGLE_RAD = 0.8 
local MAX_ADJUSTMENT = 10.0 
local MIN_ADJUSTMENT = 3.0  
local ADJUSTMENT_SPEED_REF = 50.0 

function ActionModule.server_init(self,driver)
    self.Driver = driver 
    self.steeringOut = 0 
    self.throttleOut = 0
    self.curGear = 1 
end

function ActionModule.shiftGear(self,gear) 
    if self.Driver.engine == nil then return end
    if self.Driver.engine.engineStats == nil then return end
    self.curGear = gear
    self.Driver.engine:setGear(gear)
end

function ActionModule.updateGearing(self)
    if self.Driver.engine == nil or self.Driver.engine.engineStats == nil then return end

    local engine = self.Driver.engine
    local vrpm = engine.curVRPM 
    local revLimit = engine.engineStats.REV_LIMIT
    local highestGear = #engine.engineStats.GEARING
    local ai_throttle = self.decisionData.throttle
    local ai_brake = self.decisionData.brake
    local currentSpeed = self.Driver.perceptionData.Telemetry.speed or 0.0
    local nextGear = self.curGear
    
    if self.Driver.racing or self.Driver.isRacing then
        if ai_throttle > 0.3 then 
            if self.curGear <= 0 then 
                nextGear = 1 
            elseif vrpm >= revLimit * 0.95 then 
                if self.curGear < highestGear then
                    nextGear = self.curGear + 1 
                end
            end
        end

        if currentSpeed < 10.0 and self.curGear > 1 and vrpm < revLimit * 0.2 then
             nextGear = self.curGear - 1 
        elseif ai_brake > 0.4 and self.curGear > 1 and vrpm < revLimit * 0.35 then
             nextGear = self.curGear - 1
        end

        if currentSpeed < 1.0 and ai_brake > 0.8 and self.curGear >= 0 then
            nextGear = -1
        end
    end

    if nextGear ~= self.curGear then
        self:shiftGear(nextGear)
    end
end

function ActionModule.setSteering(self, steerFactor,currentSpeed)
    local targetAngle = steerFactor * MAX_WHEEL_ANGLE_RAD
    local speedRatio = math.min(currentSpeed / ADJUSTMENT_SPEED_REF, 1.0)
    local adjustmentRate = MAX_ADJUSTMENT + (MIN_ADJUSTMENT - MAX_ADJUSTMENT) * speedRatio
    
    for k, v in pairs(sm.interactable.getBearings(self.Driver.interactable)) do
        sm.joint.setTargetAngle( v, targetAngle, adjustmentRate, 1500)
    end
    self.steeringOut = targetAngle
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

function ActionModule.applyControls(self,controls) 
    local currentSpeed = self.Driver.perceptionData.Telemetry.speed or 0.0
    self:setSteering(controls.steer,currentSpeed)
    self:outputThrotttle(controls.throttle, controls.brake)
    if controls.resetCar then 
        self.Driver:resetCar() 
    end 
end

function ActionModule.server_onFixedUpdate(self,decisionData)
    self.decisionData = decisionData
    self:updateGearing() 
    self:applyControls(decisionData)
end