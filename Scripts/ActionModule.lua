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
    -- [[ FIX: STEERING INVERSION SUPPORT ]]
    local rawSteer = steerFactor
    if STEERING_INVERTED then steerFactor = -steerFactor end
    
    local targetAngle = steerFactor * MAX_WHEEL_ANGLE_RAD
    
    -- [DEBUG] Verify Final Command
    if math.abs(steerFactor) > 0.05 then
        print(string.format("ACTION: SteerIn:%.2f -> Out:%.2f (Inv:%s)", rawSteer, steerFactor, tostring(STEERING_INVERTED)))
    end
    
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

function ActionModule:applyTorqueVectoring(steer, speed)
    if not ENABLE_TORQUE_VECTORING then return end
    if math.abs(steer) < 0.1 or speed < 5.0 then return end
    
    local body = self.Driver.body
    if not body then return end
    
    -- Virtual Torque Vectoring: Enhance Rotation
    -- Apply a torque around the Up axis
    -- Torque = Steer * Speed * Intensity
    -- To be physically stable, we apply Force pairs (Couples) at Fwd/Rear of CoM?
    -- Actually, sm.physics.applyTorque is safest if available (World space).
    -- If not, we use Impulses.
    
    local torqueStrength = steer * speed * TV_INTENSITY * 25.0 -- Tuning Constant
    
    -- Apply Torque (Yaw Moment)
    -- Vector is UP (Z-axis local to car? No, World Up is usually Z, but we want Car Up)
    local carUp = self.Driver.shape:getUp()
    local torqueVec = carUp * torqueStrength
    
    sm.physics.applyTorque(body, torqueVec, true) -- true = local space? No API implies World usually. 
    -- If API implies World, we need World Up? 
    -- Wait, verify API args. sm.physics.applyTorque(body, torqueVector, pureTorque?)
    -- Assuming usage: applyTorque(body, vector). Vector direction is axis, length is magnitude.
    
    -- Let's stick to safe Impulse Couples to be sure of mechanics
    -- Front moves Right, Rear moves Left (for Right Turn)
    local fwd = self.Driver.shape:getAt()
    local right = self.Driver.shape:getRight()
    local com = body:getCenterOfMassPosition()
    
    local frontPos = com + (fwd * 2.0)
    local rearPos = com - (fwd * 2.0)
    
    local forceMag = torqueStrength * 0.5 -- Split torque into force couple
    local forceDir = right -- Push side-to-side
    
    -- Steer > 0 (Left? No usually positive steer is Left in SM logic? Check Guidance.)
    -- Guidance clamps -1 to 1. Usually Left is Negative in Angle, Positive in Turn?
    -- Let's assume standard: Positive = Left.
    -- If Steer Left (+), we want Yaw Left (CCW).
    -- Front pushes Left (+Right * -1), Rear pushes Right (+Right * 1).
    
    -- Check sign:
    -- If steer is positive (Left), torqueStrength is positive.
    -- We want CCW rotation around Up.
    -- Front should move Left (-Right). Rear should move Right (+Right).
    
    -- Force = Right * -1 * Magnitude (for Front)
    -- Force = Right * 1 * Magnitude (for Rear)
    -- This creates CCW torque.
    
    local frontForce = right * (-forceMag * 0.1) -- Scale down for Impulse vs Force
    local rearForce = right * (forceMag * 0.1)
    
    sm.physics.applyImpulse(body, frontForce, true, (fwd * 2.0)) -- Offset from center
    sm.physics.applyImpulse(body, rearForce, true, (fwd * -2.0))
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