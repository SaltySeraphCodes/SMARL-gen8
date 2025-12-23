-- ActionModule.lua
-- Steering Values (Permanent):
---1 = full Left
--1 = full right
-- throttle values: 1 = full gas, 0 = coast, -1 = full brake
dofile("globals.lua")
ActionModule = class(nil)

local MAX_WHEEL_ANGLE_RAD = 0.8 
local MAX_ADJUSTMENT = 15.0  -- [TWEAK] Increased from 10.0 for faster low-speed response
local MIN_ADJUSTMENT = 8.0   -- [FIX] Increased from 3.0. 
                             -- Prevents steering lag at high speed which causes oscillation.
local ADJUSTMENT_SPEED_REF = 50.0

function ActionModule.server_init(self,driver)
    self.Driver = driver
    self.steeringOut = 0
    self.throttleOut = 0
    self.curGear = 1
    self.shiftTimer = 0.0 -- New: Prevents rapid shifting
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
    if self.shiftTimer > 0 then return end -- Wait for current gear to settle

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
        -- UPSHIFT LOGIC
        if ai_throttle > 0.5 and vrpm >= revLimit * 0.92 then 
            if self.curGear < highestGear then
                nextGear = self.curGear + 1 
            end
        end

        -- DOWNSHIFT LOGIC (Protected)
        -- Only downshift if we aren't mid-slide (yawRate check)
        if yawRate < 1.5 then 
            if ai_brake > 0.5 and self.curGear > 1 then
                -- Downshift earlier during heavy braking to use engine braking, 
                -- but only if VRPM is safe to avoid wheel lock.
                if vrpm < revLimit * 0.4 then
                    nextGear = self.curGear - 1
                end
            elseif currentSpeed < 5.0 and self.curGear > 1 then
                nextGear = 1 -- Reset to 1st when nearly stopped
            end
        end

        -- REVERSE LOGIC
        if currentSpeed < 1.0 and ai_brake > 0.8 and self.curGear >= 0 then
            nextGear = -1
        elseif self.curGear == -1 and ai_throttle > 0.5 then
            nextGear = 1
        end
    end

    if nextGear ~= self.curGear then
        self:shiftGear(nextGear)
        self.shiftTimer = 0.4 -- Lock shifting for 0.4s (adjust based on engine response)
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

function ActionModule.applyControls(self, controls) 
    local currentSpeed = self.Driver.perceptionData.Telemetry.speed or 0.0
    self:setSteering(controls.steer, currentSpeed) -- Pass the AI's steer value
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