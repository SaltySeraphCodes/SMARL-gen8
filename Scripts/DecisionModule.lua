-- This is everything that has to do with Deciding what to do with the perception/input data
-- Returns an object of Desired commands for output
dofile("globalsGen8.lua")
DecisionModule = class(nil)

-- --- UTILITY & SPEED CONSTANTS ---
local MAX_TILT_RAD = 1.047        -- 60 degrees in radians (~1.047)
local STUCK_SPEED_THRESHOLD = 0.5 -- Meters per second (M/s)
local STUCK_TIME_LIMIT = 2.0      -- Seconds
local BASE_MAX_SPEED = 1000        -- Absolute fastest the car can go on a straight (M/s)
local MIN_CORNER_SPEED = 15       -- Minimum speed for the tightest corners
local GRIP_FACTOR = 0.9         -- Tuning constant representing grip/friction
local MIN_RADIUS_FOR_MAX_SPEED = 130.0 
local FORMATION_SPEED = 20.0       
local FORMATION_DISTANCE = 5.0     
local FORMATION_BIAS_OUTSIDE = 0.6 
local FORMATION_BIAS_INSIDE = -0.6 
local CAUTION_SPEED = 15.0       
local CAUTION_DISTANCE = 8.0     

-- --- PID GAINS ---
local MAX_WHEEL_ANGLE_RAD = 0.8 
local STEERING_Kp = 0.6    
local STEERING_Ki = 0.005 
local STEERING_Kd = 0.01 
local LATERAL_Kp = 0.6 

local SPEED_Kp = 0.1  
local SPEED_Ki = 0.01 
local SPEED_Kd = 0.08 
local MAX_I_TERM_SPEED = 10.0 
local STEER_FACTOR_REDUCE = 0.0001 

-- --- STRATEGY CONSTANTS ---
local PASSING_DISTANCE_LIMIT = 10.0 
local PASSING_EXIT_DISTANCE = 15.0 
local MIN_CLOSING_SPEED = -1.0 

local DEFENSE_BIAS_FACTOR = 0.5   
local PASSING_BIAS = 0.75         
local DRAFT_BOOST = 1.1           
local PASSING_SPEED_ADVANTAGE = 1.05 
local LANE_SLOT_WIDTH = 0.33 
local YIELD_BIAS_OFFSET = 0.7 -- NEW: How far off-line to go when yielding

-- Avoidance Constants --
local WALL_STEERING_BIAS = 0.9 
local CAR_WIDTH_BUFFER = 0.3   
local GAP_STICKINESS = 0.2     

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
    self.dynamicGripFactor = dynamicGripFactor 
    self.dynamicMaxSpeed = dynamicMaxSpeed
end

-- Helper: Calculates the required speed based on steering severity
function DecisionModule.getTargetSpeed(self,perceptionData, steerInput)
    local navigation = perceptionData.Navigation
    local opponents = perceptionData.Opponents
    local radius = navigation.roadCurvatureRadius or MIN_RADIUS_FOR_MAX_SPEED 
    local currentMode = self.currentMode
    local currentSpeed = perceptionData.Telemetry.speed

    local DYNAMIC_GRIP_FACTOR = self.dynamicGripFactor or GRIP_FACTOR
    local DYNAMIC_MAX_SPEED = self.dynamicMaxSpeed or BASE_MAX_SPEED

    local targetSpeed = 0.0

    -- 1. STRUCTURED MODE SPEED
    if currentMode == "Formation" or currentMode == "Caution" then
        local _, structuredSpeed = self:getStructuredModeTargets(perceptionData, currentMode)
        targetSpeed = structuredSpeed
    else
        -- 2. RACE SPEED CALCULATION
        local calculatedSpeed = math.sqrt(radius) * DYNAMIC_GRIP_FACTOR * 3.8 

        if radius > MIN_RADIUS_FOR_MAX_SPEED then
            calculatedSpeed = DYNAMIC_MAX_SPEED
        end

        targetSpeed = math.min(calculatedSpeed, DYNAMIC_MAX_SPEED)

        -- Aggression braking margin
        local safetyBrakeMargin = (1.0 - self.Driver.carAggression) * 0.1 
        targetSpeed = math.max(targetSpeed, MIN_CORNER_SPEED)
        local V_curve_aggressive = targetSpeed * (1.0 - safetyBrakeMargin)
        targetSpeed = math.min(targetSpeed, V_curve_aggressive)

        -- STRATEGIC OVERRIDES
        if currentMode == "Drafting" then
            targetSpeed = targetSpeed * DRAFT_BOOST
        elseif currentMode == "OvertakeDynamic" then
            targetSpeed = targetSpeed * PASSING_SPEED_ADVANTAGE
        elseif currentMode == "AvoidCollision" or currentMode == "AvoidWallLeft" or currentMode == "AvoidWallRight" then
            targetSpeed = MIN_CORNER_SPEED 
        elseif currentMode == "Yield" then
            targetSpeed = targetSpeed * 0.85 
        end
        
        -- NEW: TRAFFIC JAM / ROLLING START LOGIC
        -- "Move only when the person in front moves"
        -- FIX 1: Exclude Strategic Modes (Passing/Drafting)
        -- FIX 2: Speed Gate - Only apply if we are already slow (< 20 m/s) to prevent phantom braking on straights
        local isProximityMode = (currentMode == "Drafting" or currentMode == "OvertakeDynamic" or currentMode == "OvertakeLeft" or currentMode == "OvertakeRight")
        local isSlowMoving = currentSpeed < 20.0 

        if not isProximityMode and isSlowMoving and opponents and opponents.count > 0 then
            local carAhead = opponents.racers[1] -- Closest car
            
            -- FIX 3: Lane Check - Only brake if they are actually blocking our lane
            -- Use track position bias to check alignment
            local myBias = navigation.trackPositionBias or 0.0
            local carAheadBias = carAhead.opponentBias or 0.0
            local laneOverlap = math.abs(myBias - carAheadBias) < (CAR_WIDTH_BUFFER * 1.5)

            if carAhead and carAhead.isAhead and laneOverlap then
                -- If we are bumper-to-bumper (< 6m), limit speed to crawl
                if carAhead.distance < 6.0 then
                     -- Don't stop completely if we are in a race, but slow drastically
                     targetSpeed = math.min(targetSpeed, 5.0) 
                end
                
                -- If we are touching or extremely close (< 4m), STOP/MATCH SPEED
                if carAhead.distance < 4.0 then
                     -- If closing speed is negative (we are faster/closing in), kill throttle
                     if carAhead.closingSpeed < 0 then
                        targetSpeed = 0.0 
                     end
                end
            end
        end
    end

    -- 3. STEERING DAMPING
    local steerFactor = math.abs(steerInput) * STEER_FACTOR_REDUCE
    local steerDampedSpeed = DYNAMIC_MAX_SPEED - (DYNAMIC_MAX_SPEED - MIN_CORNER_SPEED) * steerFactor
    
    return math.min(targetSpeed, steerDampedSpeed)
end



-- NEW: Helper to determine yield side
function DecisionModule:getYieldBias(perceptionData)
    local nav = perceptionData.Navigation
    
    -- If we are in a turn, yield to the OUTSIDE (safest for faster cars taking the apex)
    if nav.longCurveDirection ~= 0 then
        -- If turning Left (-1), Yield Right (1.0)
        -- If turning Right (1), Yield Left (-1.0)
        return -nav.longCurveDirection * YIELD_BIAS_OFFSET
    end
    
    -- On a straight, yield to the right (standard etiquette)
    return YIELD_BIAS_OFFSET 
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

function DecisionModule.getFinalTargetBias(self, perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local aggression = self.Driver.carAggression 
    local currentMode = self.currentMode 
    local targetBias = 0.0 
    local wall = perceptionData.WallAvoidance 

    if currentMode == "Formation" or currentMode == "Caution" then
        local structuredBias, _ = self:getStructuredModeTargets(perceptionData, currentMode)
        targetBias = structuredBias
    elseif currentMode == "AvoidWallLeft" then
        targetBias = WALL_STEERING_BIAS 
    elseif currentMode == "AvoidWallRight" then
        targetBias = -WALL_STEERING_BIAS
    elseif currentMode == "OvertakeDynamic" then
        if self.dynamicOvertakeBias then
            targetBias = self.dynamicOvertakeBias
        end
    elseif currentMode == "AvoidCollision" then
        local risk = opp.collisionRisk
        if risk then
            targetBias = -getSign(risk.opponentBias) * 1.0
        end
    elseif currentMode == "Drafting" then
        targetBias = 0.0
    elseif currentMode == "Yield" then -- NEW
        targetBias = self:getYieldBias(perceptionData)
    elseif currentMode == "DefendLine" then
        if nav.longCurveDirection ~= 0 then
            targetBias = nav.longCurveDirection * DEFENSE_BIAS_FACTOR
        else
            targetBias = DEFENSE_BIAS_FACTOR * aggression * getSign(nav.trackPositionBias or 0.01)
        end
    else 
        local aggressionBias = (aggression - 0.5) * 0.8 
        targetBias = aggressionBias 
        self.lastOvertakeBias = nil 
    end
    
    return mathClamp(-1.0, 1.0, targetBias)
end

function DecisionModule.getStructuredModeTargets(self, perceptionData, mode)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local telemetry = perceptionData.Telemetry
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

    if self.Driver.body:isStatic() then 
        self.onLift = true
    else
        self.onLift = false
    end
    
    local upDot = rotationData.up:dot(sm.vec3.new(0,0,1))
    local maxDot = math.cos(MAX_TILT_RAD) 
    
    if upDot < maxDot then
        self.isFlipped = true
    else
        self.isFlipped = false
    end

    if telemetry.speed < STUCK_SPEED_THRESHOLD and telemetry.isOnLift == false and self.Driver.isRacing then 
        self.stuckTimer = self.stuckTimer + dt
    else
        self.stuckTimer = 0.0 
    end

    if self.stuckTimer >= STUCK_TIME_LIMIT then
        self.isStuck = true
    else
        self.isStuck = false
    end

    if self.isFlipped or self.isStuck then
        resetFlag = true
    end
    
    return resetFlag
end

function DecisionModule.determineStrategy(self,perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local telemetry = perceptionData.Telemetry
    local wall = perceptionData.WallAvoidance 
    
    local aggressionFactor = self.Driver.carAggression
    self.currentMode = "RaceLine" 

    if self.Driver.formation then
        self.currentMode = "Formation"
        return
    elseif self.Driver.caution then
        self.currentMode = "Caution"
        return
    end

    if wall.isForwardLeftCritical then
        self.currentMode = "AvoidWallRight"
        return
    elseif wall.isForwardRightCritical then
        self.currentMode = "AvoidWallLeft"
        return
    end

    if opp.collisionRisk and opp.collisionRisk.timeToCollision < 0.5 then
        self.currentMode = "AvoidCollision"
        return
    end
    
    -- NEW: BLUE FLAG CHECK (High Priority)
    if opp.blueFlagActive then
        self.currentMode = "Yield"
        return
    end

    local isStraight = nav.roadCurvatureRadius >= 500
    if opp.draftingTarget and telemetry.speed > 30 and isStraight and aggressionFactor >= 0.3 then
        self.currentMode = "Drafting"
        return
    end
    
    if opp.count > 0 then
        local closestOpponent = opp.racers[1]
        if closestOpponent and not closestOpponent.isAhead and closestOpponent.distance < 15 then
            if closestOpponent.closingSpeed < -1.0 or aggressionFactor > 0.6 then
                self.currentMode = "DefendLine"
                print(self.Driver.id,self.currentMode,closestOpponent.distance)
                return
            end
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


function DecisionModule.calculateSteering(self,perceptionData)
    local telemetry = perceptionData.Telemetry
    local navigation = perceptionData.Navigation
    
    if not navigation.nodeGoalDirection or not telemetry.rotations then
        return 0.0
    end

    local goalDir = navigation.nodeGoalDirection
    local carDir = telemetry.rotations.at 
    local angularVel = telemetry.angularVelocity 

    local targetBias = self:getFinalTargetBias(perceptionData)
    local lateralError = targetBias - navigation.trackPositionBias
    local lateralPTerm = lateralError * LATERAL_Kp

    local carDir2D = sm.vec3.new(carDir.x, carDir.y, 0):normalize()
    local goalDir2D = sm.vec3.new(goalDir.x, goalDir.y, 0):normalize()
    local crossZ = carDir2D.x * goalDir2D.y - carDir2D.y * goalDir2D.x
    local alignment = carDir2D:dot(goalDir2D) 
    local angleErrorRad = math.atan2(crossZ, alignment)
    
    local directionalPTerm = angleErrorRad / MAX_WHEEL_ANGLE_RAD
    local pTerm = lateralPTerm + directionalPTerm

    local yawRate = angularVel:dot(telemetry.rotations.up) 
    local dTerm = -yawRate * STEERING_Kd 
    
    self.integralSteeringError = self.integralSteeringError + angleErrorRad 
    local MAX_I_TERM = 5.0
    self.integralSteeringError = math.min(math.max(self.integralSteeringError, -MAX_I_TERM), MAX_I_TERM)
    local iTerm = self.integralSteeringError * STEERING_Ki

    local steerInput = -(pTerm * STEERING_Kp) + iTerm + dTerm
    return math.min(math.max(steerInput, -1.0), 1.0)
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

    if controlSignal > 0 then
        throttle = math.min(controlSignal, 1.0)
        brake = 0.0
    elseif controlSignal < 0 then
        brake = math.min(math.abs(controlSignal), 1.0)
        throttle = 0.0
    else
        throttle = 0.1
        brake = 0.0
    end

    return throttle, brake
end

function DecisionModule.server_onFixedUpdate(self,perceptionData,dt)
    local controls = {}

    controls.resetCar = self:checkUtility(perceptionData,dt)

    if controls.resetCar then
        print(self.Driver.id,"resetting car")
        controls.steer = 0.0
        controls.throttle = 0.0
        controls.brake = 0.0
    else
        self:determineStrategy(perceptionData)
        controls.steer = self:calculateSteering(perceptionData)
        controls.throttle, controls.brake = self:calculateSpeedControl(perceptionData, controls.steer)
    end

    self.controls = controls
    return controls
end