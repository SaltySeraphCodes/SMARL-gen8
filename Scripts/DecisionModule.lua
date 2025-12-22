-- DecisionModule.lua
dofile("globals.lua") 
DecisionModule = class(nil)

-- [[ TUNING - PHYSICS ]]
local MAX_TILT_RAD = 1.047 
local STUCK_SPEED_THRESHOLD = 1.0 
local STUCK_TIME_LIMIT = 4.0 
local BASE_MAX_SPEED = 1000 
local MIN_CORNER_SPEED = 12
local GRIP_FACTOR = 0.8            
local MIN_RADIUS_FOR_MAX_SPEED = 130.0 

-- [[ TUNING - STEERING PID ]]
local MAX_WHEEL_ANGLE_RAD = 0.8 
-- Base Gains
local STEERING_Kp_BASE = 0.18  -- Initial snap-to-target strength
local STEERING_Kd_BASE = 0.55  -- Initial damping (prevents overswing)
local LATERAL_Kp = 0.45        -- Sensitivity to distance from the line
-- Velocity Scaling Factors
-- These reduce the steering force as you go faster to stop physics-based jitter.
local Kp_MIN_FACTOR = 0.35     -- At max speed, Kp is reduced to 35% of base
local Kd_BOOST_FACTOR = 1.2    -- At max speed, Kd is boosted 120% to fight momentum

-- [[ TUNING - SPEED PID ]]
local SPEED_Kp = 0.1 
local SPEED_Ki = 0.01 
local SPEED_Kd = 0.08 
local MAX_I_TERM_SPEED = 10.0 

-- [[ RACING LOGIC ]]
local PASSING_DISTANCE_LIMIT = 10.0 
local PASSING_EXIT_DISTANCE = 15.0 
local MIN_CLOSING_SPEED = -1.0 
local DEFENSE_BIAS_FACTOR = 0.5 
local PASSING_BIAS = 0.75 
local DRAFT_BOOST = 1.1 
local PASSING_SPEED_ADVANTAGE = 1.05 
local YIELD_BIAS_OFFSET = 0.7 
local WALL_STEERING_BIAS = 0.9 
local CAR_WIDTH_BUFFER = 0.3 
local GAP_STICKINESS = 0.2 

-- [[ CORNERING STRATEGY ]]
local CORNER_RADIUS_THRESHOLD = 120.0  
local CORNER_ENTRY_BIAS = 0.60         
local CORNER_APEX_BIAS = 0.60          
local CORNER_EXIT_BIAS = 0.40          
local CORNER_PHASE_DURATION = 0.3      

-- [[ CONTEXT STEERING ]]
local NUM_RAYS = 17            
local VIEW_ANGLE = 120         
local LOOKAHEAD_RANGE = 45.0   
local SAFETY_WEIGHT = 5.0      
local INTEREST_WEIGHT = 1.0   
local WALL_AVOID_DIST = 4.0    
local VISUALIZE_RAYS = true    

-- [[ BRAKING PHYSICS ]]
local BRAKING_POWER_FACTOR = 0.9 
local SCAN_DISTANCE = 120.0       

function DecisionModule.server_init(self,driver)
    self.Driver = driver 
    self.decisionData = {}
    self.previousSpeedError = 0.0
    self.integralSpeedError = 0.0
    self.integralSteeringError = 0.0
    self.onLift = false
    self.stuckTimer = 0.0
    self.isStuck = false
    self.isFlipped = false
    self.currentMode = "RaceLine"
    self.targetBias = 0.0 
    self.lastOvertakeBias = nil 
    self.pitState = 0 
    
    self.isCornering = false
    self.cornerPhase = 0 
    self.cornerTimer = 0.0
    self.cornerDirection = 0

    self.speedUpdateTimer = 0 
    self.trackPositionBias = 0.0 -- or 1.0, depending on your logic
    self.smoothedRadius = 1000.0
    self.radiusHoldTimer = 0.0
    self.cachedDist = 0.0
    self.smoothedBias = 0.0 

    self:calculateCarPerformance()
end

function DecisionModule.calculateCarPerformance(self)
    local dynamicMaxSpeed = BASE_MAX_SPEED
    local dynamicGripFactor = GRIP_FACTOR
    local car = self.Driver
    
    local tireGripMultiplier = TIRE_TYPES[car.tire_type] and TIRE_TYPES[car.tire_type].GRIP or 0.5
    local wearPenalty = (1.0 - (car.tire_wear or 1.0)) * 0.2 
    dynamicGripFactor = dynamicGripFactor * (tireGripMultiplier - wearPenalty)
    
    local spoilerAngle = car.spoiler_angle or 0.0 
    local downforceBoost = math.min(spoilerAngle / 80.0, 1.0) * 0.1 
    dynamicGripFactor = dynamicGripFactor + downforceBoost
    
    local gearRatio = car.gear_length or 1.0 
    dynamicMaxSpeed = BASE_MAX_SPEED * gearRatio * 0.5 
    
    if car.tireLimp then
        dynamicMaxSpeed = math.min(dynamicMaxSpeed, 40.0) 
        dynamicGripFactor = dynamicGripFactor * 0.5
    end

    if car.fuelLimp then
        dynamicMaxSpeed = math.min(dynamicMaxSpeed, 20.0) 
        dynamicGripFactor = dynamicGripFactor * 0.9 
    end

    self.dynamicGripFactor = dynamicGripFactor 
    self.dynamicMaxSpeed = dynamicMaxSpeed
end

function DecisionModule:updateTrackState(perceptionData)
    local tick = sm.game.getServerTick()
    if tick % 4 == 0 or not self.cachedMinRadius then
         self.cachedMinRadius, self.cachedDist = self.Driver.Perception:scanTrackCurvature(SCAN_DISTANCE)
    end
    
    local rawRadius = self.cachedMinRadius or 1000.0
    
    if rawRadius < self.smoothedRadius then
        self.smoothedRadius = rawRadius
        self.radiusHoldTimer = 1.0 
    else
        if self.radiusHoldTimer > 0 then
            self.radiusHoldTimer = self.radiusHoldTimer - (1.0/40.0) 
        else
            self.smoothedRadius = self.smoothedRadius + 5.0 
        end
    end
    
    if self.smoothedRadius > rawRadius then self.smoothedRadius = rawRadius end
    if self.smoothedRadius > 1000.0 then self.smoothedRadius = 1000.0 end
    
    self.dbg_Radius = self.smoothedRadius
    self.dbg_Dist = self.cachedDist or 0.0
end

function DecisionModule.getTargetSpeed(self, perceptionData, steerInput)
    local effectiveRadius = self.smoothedRadius
    local distToCorner = self.cachedDist or 0.0

    local friction = self.dynamicGripFactor or 0.9
    local maxCornerSpeed = math.sqrt(effectiveRadius * friction * 15.0) * 2.8
    
    maxCornerSpeed = math.max(maxCornerSpeed, MIN_CORNER_SPEED)
    maxCornerSpeed = math.min(maxCornerSpeed, self.dynamicMaxSpeed)
    
    local brakingForce = 25.0 * BRAKING_POWER_FACTOR
    local allowableSpeed = math.sqrt((maxCornerSpeed * maxCornerSpeed) + (2 * brakingForce * distToCorner))
    
    self.dbg_MaxCorner = maxCornerSpeed
    self.dbg_Allowable = allowableSpeed

    local targetSpeed = math.min(self.dynamicMaxSpeed, allowableSpeed)
    
    if self.currentMode == "Drafting" then targetSpeed = targetSpeed * 1.1 end
    if self.currentMode == "Caution" then targetSpeed = 15.0 end
    if self.pitState > 0 then targetSpeed = 15.0 end
    if self.pitState == 3 then targetSpeed = 5.0 end

    local steerFactor = math.abs(steerInput) * 0.1
    targetSpeed = targetSpeed * (1.0 - steerFactor)

    return targetSpeed
end

function DecisionModule:calculateContextBias(perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local wall = perceptionData.WallAvoidance
    local telemetry = perceptionData.Telemetry

    local interestMap = {}
    local dangerMap = {}
    local rayAngles = {}
    
    local sectorStep = VIEW_ANGLE / (NUM_RAYS - 1)
    local startAngle = -(VIEW_ANGLE / 2)

    local preferredBias = 0.0 
    if self.currentMode == "DefendLine" then preferredBias = self.targetBias end 
    local currentPos = nav.trackPositionBias or 0.0
    local centeringAngle = currentPos * 25.0 
    if self.currentMode == "DefendLine" then centeringAngle = -(preferredBias * 45.0) end

    for i = 1, NUM_RAYS do
        local angle = startAngle + (i - 1) * sectorStep
        rayAngles[i] = angle
        dangerMap[i] = 0.0
        
        local diff = math.abs(angle - centeringAngle)
        local sigma = 30.0 
        interestMap[i] = math.exp(-(diff * diff) / (2 * sigma * sigma))
    end

    if opp and opp.racers then
        for _, racer in ipairs(opp.racers) do
            if racer.isAhead and racer.distance < LOOKAHEAD_RANGE then
                local toOp = racer.location - telemetry.location
                local fwd = telemetry.rotations.at
                local right = telemetry.rotations.right
                
                local dx = toOp:dot(right)
                local dy = toOp:dot(fwd)
                local oppAngle = math.deg(math.atan2(dx, dy))
                local carWidthDeg = math.deg(math.atan2(2.0, racer.distance)) * 2.0 
                
                for i = 1, NUM_RAYS do
                    local diff = math.abs(rayAngles[i] - oppAngle)
                    if diff < carWidthDeg then
                        local severity = 1.0 - (racer.distance / LOOKAHEAD_RANGE)
                        if racer.closingSpeed < -5.0 then severity = severity * 1.5 end
                        dangerMap[i] = math.max(dangerMap[i], severity)
                    end
                end
            end
        end
    end

    if wall then
        local avoidanceMargin = WALL_AVOID_DIST 
        
        if wall.marginLeft < avoidanceMargin then
            local urgency = 1.0 - (math.max(wall.marginLeft, 0) / avoidanceMargin)
            urgency = urgency * urgency * urgency 
            
            local blockAngle = -5.0 + (urgency * -30.0) 
            for i = 1, NUM_RAYS do
                if rayAngles[i] < 5 and rayAngles[i] < blockAngle then
                    dangerMap[i] = math.max(dangerMap[i], urgency)
                end
            end
        end

        if wall.marginRight < avoidanceMargin then
            local urgency = 1.0 - (math.max(wall.marginRight, 0) / avoidanceMargin)
            urgency = urgency * urgency * urgency 
            
            local blockAngle = 5.0 + (urgency * 30.0)
            for i = 1, NUM_RAYS do
                if rayAngles[i] > -5 and rayAngles[i] > blockAngle then
                    dangerMap[i] = math.max(dangerMap[i], urgency)
                end
            end
        end
    end

    local bestScore = -math.huge
    local bestIndex = math.ceil(NUM_RAYS/2)

    for i = 1, NUM_RAYS do
        local score = (interestMap[i] * INTEREST_WEIGHT) - (dangerMap[i] * SAFETY_WEIGHT)
        if score > bestScore then
            bestScore = score
            bestIndex = i
        end
    end

    local debugData = nil
    if VISUALIZE_RAYS then
        debugData = self:getDebugLines(rayAngles, interestMap, dangerMap, bestIndex, NUM_RAYS)
    end

    local chosenAngle = rayAngles[bestIndex]
    
    
    local targetBias = -(chosenAngle / 45.0) 
    
    return math.min(math.max(targetBias, -1.0), 1.0), debugData
end

function DecisionModule:getDebugLines(angles, interest, danger, bestIdx, count)
    if not self.Driver or not self.Driver.shape then return nil end
    local tm = self.Driver.perceptionData.Telemetry
    if not tm or not tm.location then return nil end
    local min, max = self.Driver.body:getWorldAabb()
    local centerPos = (min + max) * 0.5
    local fwd = tm.rotations.at
    local right = tm.rotations.right
    local up = tm.rotations.up
    local startPos = centerPos + (fwd * 2.5) + (up * -0.15)
    local lines = {}
    for i=1, count do
        local isBest = (i == bestIdx)
        if isBest or danger[i] > 0.1 or (i == 1) or (i == count) or (i == math.ceil(count/2)) then
            local rad = math.rad(angles[i])
            local dir = (fwd * math.cos(rad)) + (right * math.sin(rad))
            local colorCode = 1 
            if isBest then colorCode = 4 elseif danger[i] > 0.5 then colorCode = 3 elseif danger[i] > 0.0 then colorCode = 2 end
            table.insert(lines, { s = startPos, e = startPos + (dir * 15), c = colorCode })
        end
    end
    return lines
end

function DecisionModule.handleCorneringStrategy(self, perceptionData, dt)
    local nav = perceptionData.Navigation
    local radius = self.smoothedRadius or MIN_RADIUS_FOR_MAX_SPEED 
    local curveDir = nav.longCurveDirection 
    local distToApex = self.cachedDist or 0.0 

    if self.isCornering == false and radius < CORNER_RADIUS_THRESHOLD then
        self.isCornering = true
        self.cornerPhase = 1 
        self.cornerTimer = CORNER_PHASE_DURATION
        self.cornerDirection = curveDir 
        -- Entry = Opposite of Turn. Left Turn (+1) -> Right Bias (-1).
        self.targetBias = -self.cornerDirection * CORNER_ENTRY_BIAS 
    end
    
    if self.isCornering == true then
        self.currentMode = "Cornering" 
        
        -- PHASE 1: ENTRY (Setup)
        if self.cornerPhase == 1 then
            local entryIntensity = 1.0 - math.min(math.max((distToApex - 30.0) / 70.0, 0.0), 1.0)
            -- Target Right (Negative)
            self.targetBias = -self.cornerDirection * CORNER_ENTRY_BIAS * entryIntensity
            
            local currentSpeed = perceptionData.Telemetry.speed or 0
            local switchDist = 20.0 + (currentSpeed * 0.7) 
            
            if distToApex < switchDist then 
                self.cornerPhase = 2 
                self.cornerTimer = CORNER_PHASE_DURATION 
            end
            
        -- PHASE 2: APEX (Turn In)
        elseif self.cornerPhase == 2 then
            -- Target Left (Positive)
            self.targetBias = self.cornerDirection * CORNER_APEX_BIAS
            self.cornerTimer = self.cornerTimer - dt
            
            if self.cornerTimer <= 0.0 then
                if radius < CORNER_RADIUS_THRESHOLD * 0.8 then
                    self.cornerTimer = 0.1 
                else
                    self.cornerPhase = 3 
                    self.cornerTimer = CORNER_PHASE_DURATION
                end
            end
            
        -- PHASE 3: EXIT (Track Out)
        elseif self.cornerPhase == 3 then
            -- Target Right (Negative)
            self.targetBias = -self.cornerDirection * CORNER_EXIT_BIAS
            
            self.cornerTimer = self.cornerTimer - dt
            if self.cornerTimer <= 0.0 or radius >= 2.0 * CORNER_RADIUS_THRESHOLD then
                self.isCornering = false
                self.cornerPhase = 0
                self.currentMode = "RaceLine" 
                self.targetBias = (self.Driver.carAggression - 0.5) * 0.8 
            end
        end
    end
    
    if self.isCornering and radius > 5 * CORNER_RADIUS_THRESHOLD then
        self.isCornering = false
        self.cornerPhase = 0
        self.currentMode = "RaceLine"
        self.targetBias = (self.Driver.carAggression - 0.5) * 0.8
    end
end

function DecisionModule.getFinalTargetBias(self, perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local wall = perceptionData.WallAvoidance 
    local currentMode = self.currentMode 
    
    if self.pitState and self.pitState > 0 then return 0.0 end
    
    if currentMode == "Formation" or currentMode == "Caution" then
        local b, _ = self:getStructuredModeTargets(perceptionData, currentMode)
        return b
    end

    local isWallDanger = (wall.isLeftCritical or wall.isRightCritical or wall.isForwardLeftCritical or wall.isForwardRightCritical)
    local useContextSteering = (currentMode == "OvertakeDynamic" or 
                                currentMode == "AvoidCollision" or 
                                (opp.count > 0) or 
                                isWallDanger)

    if useContextSteering or VISUALIZE_RAYS then
        local bias, debugData = self:calculateContextBias(perceptionData)
        self.latestDebugData = debugData
        
        if useContextSteering then 
            self.currentMode = "Context" 
            return bias 
        end
    end

    if self.isCornering then return self.targetBias end

    if currentMode == "Drafting" then return 0.0 end
    if currentMode == "Yield" then return self:getYieldBias(perceptionData) end
    if currentMode == "DefendLine" then
        if nav.longCurveDirection ~= 0 then return nav.longCurveDirection * DEFENSE_BIAS_FACTOR end
        return DEFENSE_BIAS_FACTOR * self.Driver.carAggression * getSign(nav.trackPositionBias or 0.01)
    end
    
    return (self.Driver.carAggression - 0.5) * 0.8 
end

function DecisionModule.getStructuredModeTargets(self, perceptionData, mode)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local targetBias = 0.0
    local targetSpeed = FORMATION_SPEED 
    local targetDistance = FORMATION_DISTANCE
    if mode == "Formation" then
        local side = self.Driver.formationSide or 1 
        targetBias = side == 1 and FORMATION_BIAS_OUTSIDE or FORMATION_BIAS_INSIDE
    elseif mode == "Caution" then
        targetBias = 0.0 
        targetSpeed = CAUTION_SPEED 
        targetDistance = CAUTION_DISTANCE 
    end
    local carAhead = opp.racers[1] 
    if carAhead and carAhead.isAhead then
        local distanceError = carAhead.distance - targetDistance
        local speedAdjustment = distanceError * 0.5 
        targetSpeed = targetSpeed + speedAdjustment
        targetSpeed = math.min(targetSpeed, FORMATION_SPEED)
        targetSpeed = math.max(targetSpeed, MIN_CORNER_SPEED * 0.5) 
    end
    return targetBias, targetSpeed
end

function DecisionModule.checkUtility(self,perceptionData, dt)
    local telemetry = perceptionData.Telemetry
    local rotationData = telemetry.rotations
    local resetFlag = false
    if self.Driver.body:isStatic() then self.onLift = true else self.onLift = false end
    local upDot = rotationData.up:dot(sm.vec3.new(0,0,1))
    local maxDot = math.cos(MAX_TILT_RAD) 
    if upDot < maxDot then self.isFlipped = true else self.isFlipped = false end
    if telemetry.speed < STUCK_SPEED_THRESHOLD and telemetry.isOnLift == false and self.Driver.isRacing then 
        self.stuckTimer = self.stuckTimer + dt
    else
        self.stuckTimer = 0.0 
    end
    if self.stuckTimer >= STUCK_TIME_LIMIT then self.isStuck = true else self.isStuck = false end
    if self.isFlipped or self.isStuck then resetFlag = true end
    return resetFlag
end

function DecisionModule.determineStrategy(self,perceptionData, dt)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local telemetry = perceptionData.Telemetry
    local wall = perceptionData.WallAvoidance 
    local aggressionFactor = self.Driver.carAggression
    self.currentMode = "RaceLine" 
    if self.Driver.formation then self.currentMode = "Formation"; return
    elseif self.Driver.caution then self.currentMode = "Caution"; return end
    if wall.isForwardLeftCritical then self.currentMode = "AvoidWallRight"; return
    elseif wall.isForwardRightCritical then self.currentMode = "AvoidWallLeft"; return end
    if opp.collisionRisk and opp.collisionRisk.timeToCollision < 0.5 then self.currentMode = "AvoidCollision"; return end
    if opp.blueFlagActive then self.currentMode = "Yield"; return end
    self:handleCorneringStrategy(perceptionData, dt)
    if self.isCornering then return end
    local isStraight = nav.roadCurvatureRadius >= 500
    if opp.draftingTarget and telemetry.speed > 30 and isStraight and aggressionFactor >= 0.3 then self.currentMode = "Drafting"; return end
    if opp.count > 0 then
        local closestOpponent = opp.racers[1]
        if closestOpponent and not closestOpponent.isAhead and closestOpponent.distance < 15 then
            if closestOpponent.closingSpeed < -1.0 or aggressionFactor > 0.6 then self.currentMode = "DefendLine"; return end
        end
        if closestOpponent and closestOpponent.isAhead and aggressionFactor > 0.4 then
            if closestOpponent.distance < PASSING_DISTANCE_LIMIT then
                if closestOpponent.closingSpeed < MIN_CLOSING_SPEED then 
                    local bestBias = self:findBestOvertakeGap(perceptionData)
                    self.currentMode = "OvertakeDynamic"
                    self.dynamicOvertakeBias = bestBias
                    return
                end
            end
            if self.currentMode == "OvertakeDynamic" and closestOpponent.distance < PASSING_EXIT_DISTANCE then
                 local bestBias = self:findBestOvertakeGap(perceptionData)
                 self.dynamicOvertakeBias = bestBias
                 return
            end
        end
    end
end

function DecisionModule.calculateSteering(self, perceptionData)
    local telemetry = perceptionData.Telemetry
    local nav = perceptionData.Navigation
    local speed = telemetry.speed or 0
    
    -- 1. Dynamic Gain Scaling
    -- Reduces Kp as speed increases to prevent high-speed fishtailing
    local speedRatio = math.min(speed / self.dynamicMaxSpeed, 1.0)
    local dynamicKp = STEERING_Kp_BASE * (1.0 - (speedRatio * (1.0 - Kp_MIN_FACTOR)))
    local dynamicKd = STEERING_Kd_BASE * (1.0 + (speedRatio * (Kd_BOOST_FACTOR - 1.0)))

    -- 2. Bias Calculation
    local rawTargetBias = self:getFinalTargetBias(perceptionData)
    self.smoothedBias = self.smoothedBias or rawTargetBias
    self.smoothedBias = self.smoothedBias + (rawTargetBias - self.smoothedBias) * 0.15
    
    -- 3. Lateral Error (Target - Current)
    -- Car is Left (-0.5), Target is Center (0.0) -> Error = +0.5 (Steer Right)
    local lateralError = self.smoothedBias - nav.trackPositionBias
    self.lateralError = lateralError
    -- 4. Heading Error (Angle)
    local carDir = telemetry.rotations.at 
    local goalDir = nav.nodeGoalDirection
    local crossZ = carDir.x * goalDir.y - carDir.y * goalDir.x
    local angleErrorRad = math.atan2(crossZ, carDir:dot(goalDir))

    -- 5. PID Summation
    -- Damping (dTerm) uses Yaw Rate to actively counter the car's spin
    local yawRate = telemetry.angularVelocity:dot(telemetry.rotations.up)
    
    local pTerm = (lateralError * LATERAL_Kp) - (angleErrorRad / MAX_WHEEL_ANGLE_RAD)    
    local dTerm = -yawRate * dynamicKd
    
    local rawSteer = (pTerm * dynamicKp) + dTerm
    return math.min(math.max(rawSteer, -1.0), 1.0)
end

function DecisionModule.calculateSpeedControl(self,perceptionData, steerInput)
    local currentSpeed = perceptionData.Telemetry.speed
    local targetSpeed = self:getTargetSpeed(perceptionData,steerInput)
    local speedError = targetSpeed - currentSpeed
    local throttle = 0.0
    local brake = 0.0
    local dError = speedError - self.previousSpeedError 
    self.previousSpeedError = speedError
    local pTerm = speedError * SPEED_Kp
    local dTerm = dError * SPEED_Kd 
    self.integralSpeedError = self.integralSpeedError + speedError
    self.integralSpeedError = math.min(math.max(self.integralSpeedError, -MAX_I_TERM_SPEED), MAX_I_TERM_SPEED)
    local iTerm = self.integralSpeedError * SPEED_Ki
    local controlSignal = pTerm + iTerm + dTerm
    if controlSignal > 0 then throttle = math.min(controlSignal, 1.0); brake = 0.0
    elseif controlSignal < 0 then brake = math.min(math.abs(controlSignal), 1.0); throttle = 0.0
    else throttle = 0.1; brake = 0.0 end
    if self.isCornering and self.cornerPhase == 1 and currentSpeed > targetSpeed * 1.05 then
         brake = math.max(brake, self.Driver.carAggression * 0.4)
    end
    return throttle, brake
end

function DecisionModule.server_onFixedUpdate(self,perceptionData,dt)
    local controls = {}
    controls.resetCar = self:checkUtility(perceptionData,dt)

    self:updateTrackState(perceptionData)

    if controls.resetCar then
        print(self.Driver.id,"resetting car")
        controls.steer = 0.0; controls.throttle = 0.0; controls.brake = 0.0
    else
        self:determineStrategy(perceptionData, dt) 
        controls.steer = self:calculateSteering(perceptionData)
        controls.throttle, controls.brake = self:calculateSpeedControl(perceptionData, controls.steer)
    end

    local spd = perceptionData.Telemetry.speed or 0 
    local tick = sm.game.getServerTick()
    
    local nav = perceptionData.Navigation
    local trackInfo = "N:0|S:0"
    if nav and nav.closestPointData and nav.closestPointData.baseNode then
        trackInfo = string.format("N:%d|S:%d", nav.closestPointData.baseNode.id, nav.closestPointData.baseNode.sectorID)
    end
    
    local currentBias = nav and nav.trackPositionBias or 0.0

    local tel = perceptionData.Telemetry
    local velocity = tel.velocity
    local yawRate = tel.angularVelocity:dot(tel.rotations.up)
    
    if spd > 10 and self.dbg_Radius and tick % 4 == 0 then 
        print(string.format(
            "[%s] SPD:%03.0f/%03.0f | RAD:%03.0f | DIST:%03.0f | T:%.1f B:%.1f | STR:%+.2f | BIAS:%+.2f->%+.2f | %s | P:%d | YAW:%+.2f | ERR:%+.2f | V: (%.2f, %.2f, %.2f)",
            tostring(self.Driver.id % 100), 
            spd, 
            self.dbg_Allowable or 0, 
            self.dbg_Radius or 0, 
            self.cachedDist or 0, 
            controls.throttle,         
            controls.brake,            
            controls.steer,            
            currentBias,               
            self.targetBias or 0,      
            self.currentMode:sub(1,4), 
            self.cornerPhase or 0,
            yawRate,
            self.lateralError,
            velocity.x, velocity.y, velocity.z
        ))
        
    end

    self.controls = controls
    return controls
end

function DecisionModule.findBestOvertakeGap(self, perceptionData)
    local opp = perceptionData.Opponents
    local obstacles = {}
    for _, racer in ipairs(opp.racers) do
        if racer.isAhead and racer.distance < 30.0 then
            table.insert(obstacles, {bias = racer.opponentBias, width = CAR_WIDTH_BUFFER})
        end
    end
    table.sort(obstacles, function(a,b) return a.bias < b.bias end)
    local currentLeftEdge = -1.0
    local bestGapBias = 0.0
    local bestGapScore = -math.huge
    table.insert(obstacles, {bias = 1.0 + (CAR_WIDTH_BUFFER/2), width = 0.0}) 

    for _, obs in ipairs(obstacles) do
        local currentRightEdge = obs.bias - (obs.width / 2.0)
        local gapWidth = currentRightEdge - currentLeftEdge
        if gapWidth > CAR_WIDTH_BUFFER then 
            local gapCenter = (currentLeftEdge + currentRightEdge) / 2.0
            local score = gapWidth * 2.0 - math.abs(gapCenter)
            if self.lastOvertakeBias and math.abs(gapCenter - self.lastOvertakeBias) < 0.2 then
                score = score + GAP_STICKINESS
            end
            if score > bestGapScore then
                bestGapScore = score
                bestGapBias = gapCenter
            end
        end
        currentLeftEdge = obs.bias + (obs.width / 2.0)
    end
    if bestGapScore == -math.huge then return 0.0 end
    self.lastOvertakeBias = bestGapBias 
    return bestGapBias
end

function DecisionModule:getYieldBias(perceptionData)
    local nav = perceptionData.Navigation
    if nav.longCurveDirection ~= 0 then return -nav.longCurveDirection * YIELD_BIAS_OFFSET end
    return YIELD_BIAS_OFFSET 
end