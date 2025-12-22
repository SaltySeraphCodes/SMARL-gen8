-- DecisionModule.lua
dofile("globals.lua") 
DecisionModule = class(nil)

-- [[ TUNING - PHYSICS ]]
local MAX_TILT_RAD = 1.047 
local STUCK_SPEED_THRESHOLD = 1.0 
local STUCK_TIME_LIMIT = 4.0 
local BASE_MAX_SPEED = 1000 
local MIN_CORNER_SPEED = 12
local GRIP_FACTOR = 0.9 
local MIN_RADIUS_FOR_MAX_SPEED = 130.0 

-- [[ TUNING - STEERING PID ]]
local MAX_WHEEL_ANGLE_RAD = 0.8 
local STEERING_Kp = 0.35 
local STEERING_Ki = 0.005 
local STEERING_Kd = 0.12 
local LATERAL_Kp = 0.6 

-- [[ TUNING - SPEED PID ]]
local SPEED_Kp = 0.1 
local SPEED_Ki = 0.01 
local SPEED_Kd = 0.08 
local MAX_I_TERM_SPEED = 10.0 
local STEER_FACTOR_REDUCE = 0.0001 

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
local CORNER_ENTRY_BIAS = 0.85         
local CORNER_APEX_BIAS = 0.35          
local CORNER_EXIT_BIAS = 0.60          
local CORNER_PHASE_DURATION = 0.3      

-- [[ CONTEXT STEERING ]]
local NUM_RAYS = 17            
local VIEW_ANGLE = 120         
local LOOKAHEAD_RANGE = 45.0   
local SAFETY_WEIGHT = 4.0      -- [TUNED] Lowered from 6.0 to 4.0 to stop panic steering
local INTEREST_WEIGHT = 1.5    -- [TUNED] Restored to 1.5 to keep forward focus
local WALL_AVOID_DIST = 4.0    -- [TUNED] Start reacting earlier but softer
local VISUALIZE_RAYS = true    



-- [[ BRAKING PHYSICS ]]
local BRAKING_POWER_FACTOR = 0.6 
local SCAN_DISTANCE = 80.0       

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
    
    self.smoothedRadius = 1000.0
    self.radiusHoldTimer = 0.0
    self.cachedDist = 0.0

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

-- Centralized Track State Update
function DecisionModule:updateTrackState(perceptionData)
    -- 1. Scan the track (Throttled)
    local tick = sm.game.getServerTick()
    if tick % 4 == 0 or not self.cachedMinRadius then
         self.cachedMinRadius, self.cachedDist = self.Driver.Perception:scanTrackCurvature(SCAN_DISTANCE)
    end
    
    local rawRadius = self.cachedMinRadius or 1000.0
    
    -- 2. Smooth the Radius (The "Memory" Logic)
    if rawRadius < self.smoothedRadius then
        -- Found a tighter corner? React immediately.
        self.smoothedRadius = rawRadius
        self.radiusHoldTimer = 1.0 -- Hold this thought for 1 second
    else
        -- Track opening up? Wait before believing it.
        if self.radiusHoldTimer > 0 then
            self.radiusHoldTimer = self.radiusHoldTimer - (1.0/40.0) 
        else
            -- Slowly release the memory (5 units per tick)
            self.smoothedRadius = self.smoothedRadius + 5.0 
        end
    end
    
    -- Cap it
    if self.smoothedRadius > rawRadius then self.smoothedRadius = rawRadius end
    if self.smoothedRadius > 1000.0 then self.smoothedRadius = 1000.0 end
    
    self.dbg_Radius = self.smoothedRadius
    self.dbg_Dist = self.cachedDist or 0.0
end

function DecisionModule.getTargetSpeed(self, perceptionData, steerInput)
    -- Use the smoothed radius calculated in updateTrackState
    local effectiveRadius = self.smoothedRadius
    local distToCorner = self.cachedDist or 0.0

    -- 3. CALCULATE SPEED LIMIT
    local friction = self.dynamicGripFactor or 0.9
    local maxCornerSpeed = math.sqrt(effectiveRadius * friction * 15.0) * 2.8
    
    maxCornerSpeed = math.max(maxCornerSpeed, MIN_CORNER_SPEED)
    maxCornerSpeed = math.min(maxCornerSpeed, self.dynamicMaxSpeed)
    
    local brakingForce = 25.0 * BRAKING_POWER_FACTOR
    local allowableSpeed = math.sqrt((maxCornerSpeed * maxCornerSpeed) + (2 * brakingForce * distToCorner))
    
    self.dbg_MaxCorner = maxCornerSpeed
    self.dbg_Allowable = allowableSpeed

    local targetSpeed = math.min(self.dynamicMaxSpeed, allowableSpeed)
    
    -- 4. CONTEXT MODIFIERS
    if self.currentMode == "Drafting" then targetSpeed = targetSpeed * 1.1 end
    if self.currentMode == "Caution" then targetSpeed = 15.0 end
    if self.pitState > 0 then targetSpeed = 15.0 end
    if self.pitState == 3 then targetSpeed = 5.0 end

    -- 5. STEERING DRAG
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
    -- [VISUAL] Point interest toward lane center
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
        -- SOFT WALL REPULSION
        -- Instead of blocking rays entirely, we apply a gradient penalty.
        local avoidanceMargin = WALL_AVOID_DIST 
        
        -- Left Wall
        if wall.marginLeft < avoidanceMargin then
            -- 0m = 1.0 urgency, 4m = 0.0 urgency
            local urgency = 1.0 - (math.max(wall.marginLeft, 0) / avoidanceMargin)
            -- Cubing the urgency makes it start gentle and get strong ONLY when very close
            urgency = urgency * urgency * urgency 
            
            local blockAngle = -5.0 + (urgency * -30.0) 
            for i = 1, NUM_RAYS do
                if rayAngles[i] < 5 and rayAngles[i] < blockAngle then
                    dangerMap[i] = math.max(dangerMap[i], urgency)
                end
            end
        end

        -- Right Wall
        if wall.marginRight < avoidanceMargin then
            local urgency = 1.0 - (math.max(wall.marginRight, 0) / avoidanceMargin)
            urgency = urgency * urgency * urgency -- Cubic curve for smoothness
            
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
    local targetBias = (chosenAngle / 45.0) 
    
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
    -- [FIX] Use the SMOOTHED radius so the state machine doesn't flicker
    local radius = self.smoothedRadius or MIN_RADIUS_FOR_MAX_SPEED 
    local curveDir = nav.longCurveDirection 

    if self.isCornering == false and radius < CORNER_RADIUS_THRESHOLD then
        self.isCornering = true
        self.cornerPhase = 1 
        self.cornerTimer = CORNER_PHASE_DURATION
        self.cornerDirection = curveDir 
        self.currentMode = "Cornering"
        self.targetBias = -self.cornerDirection * CORNER_ENTRY_BIAS 
        return
    end
    
    if self.isCornering == true then
        self.cornerTimer = self.cornerTimer - dt
        
        -- PHASE 1: ENTRY
        if self.cornerPhase == 1 and self.cornerTimer <= 0.0 then
            self.cornerPhase = 2 
            self.cornerTimer = CORNER_PHASE_DURATION
            self.targetBias = self.cornerDirection * CORNER_APEX_BIAS
            
        -- PHASE 2: APEX (With Latch)
        elseif self.cornerPhase == 2 and self.cornerTimer <= 0.0 then
            if radius < CORNER_RADIUS_THRESHOLD * 0.8 then
                self.cornerTimer = 0.1 -- Hold
            else
                self.cornerPhase = 3 
                self.cornerTimer = CORNER_PHASE_DURATION
                self.targetBias = -self.cornerDirection * CORNER_EXIT_BIAS
            end
            
        -- PHASE 3: EXIT
        elseif self.cornerPhase == 3 and (self.cornerTimer <= 0.0 or radius >= 2.0 * CORNER_RADIUS_THRESHOLD) then
            self.isCornering = false
            self.cornerPhase = 0
            self.currentMode = "RaceLine" 
            self.targetBias = (self.Driver.carAggression - 0.5) * 0.8 
        end
    end
    
    -- Safety Reset
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
    local useContextSteering = (currentMode == "OvertakeDynamic" or currentMode == "AvoidCollision" or (opp.count > 0) or isWallDanger)

    -- Force calculation for visualization
    if useContextSteering or VISUALIZE_RAYS then
        local bias, debugData = self:calculateContextBias(perceptionData)
        self.latestDebugData = debugData
        if useContextSteering then return bias end
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

function DecisionModule.calculateSteering(self,perceptionData)
    local telemetry = perceptionData.Telemetry
    local navigation = perceptionData.Navigation
    if not navigation.nodeGoalDirection or not telemetry.rotations then return 0.0 end
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

    -- [FIX] Centralized State Update
    self:updateTrackState(perceptionData)

    if controls.resetCar then
        print(self.Driver.id,"resetting car")
        controls.steer = 0.0
        controls.throttle = 0.0
        controls.brake = 0.0
    else
        self:determineStrategy(perceptionData, dt) 
        controls.steer = self:calculateSteering(perceptionData)
        controls.throttle, controls.brake = self:calculateSpeedControl(perceptionData, controls.steer)
    end

    local spd = perceptionData.Telemetry.speed or 0 
    local tick = sm.game.getServerTick()
    if spd > 10 and self.dbg_Radius and  tick % 3 == 0 then 
        -- [FIX] Enhanced Debug Print
        print(string.format(
            "[%s] SPD: %.0f/%.0f | RAD: %.0f (Dist: %.0f) | LIMIT: %.0f | ACT: T:%.1f B:%.1f | MODE: %s | DBG: B:%.2f S:%.2f P:%d",
            tostring(self.Driver.id % 100), 
            spd, self.dbg_Allowable or 0, self.dbg_Radius or 0, self.dbg_Dist or 0, self.dbg_MaxCorner or 0,
            controls.throttle, controls.brake, self.currentMode,
            self.targetBias, controls.steer, self.cornerPhase or 0))
    end

    self.controls = controls
    return controls
end

-- [Visualizations for Debugging (findBestOvertakeGap / getYieldBias) kept as is]
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