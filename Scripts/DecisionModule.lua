-- DecisionModule.lua
dofile("globals.lua") 
DecisionModule = class(nil)

local MAX_TILT_RAD = 1.047 
local STUCK_SPEED_THRESHOLD = 0.5 
local STUCK_TIME_LIMIT = 2.0 
local BASE_MAX_SPEED = 1000 
local MIN_CORNER_SPEED = 15 
local GRIP_FACTOR = 0.9 
local MIN_RADIUS_FOR_MAX_SPEED = 130.0 
local FORMATION_SPEED = 20.0 
local FORMATION_DISTANCE = 5.0 
local FORMATION_BIAS_OUTSIDE = 0.6 
local FORMATION_BIAS_INSIDE = -0.6 
local CAUTION_SPEED = 15.0 
local CAUTION_DISTANCE = 8.0 
local PIT_SPEED_LIMIT = 15.0 

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
local BANKING_SPEED_BOOST = 1.2

-- NEW: Cornering Constants for Out-In-Out logic
local CORNER_RADIUS_THRESHOLD = 90.0   -- Increased threshold slightly to detect corners earlier
local CORNER_ENTRY_BIAS = 0.95         
local CORNER_APEX_BIAS = 0.15          
local CORNER_EXIT_BIAS = 0.60          
local CORNER_PHASE_DURATION = 0.3      


-- [[ CONTEXT STEERING CONFIG ]]
local NUM_RAYS = 17            -- Odd number so we have a dead-center ray
local VIEW_ANGLE = 120         -- Field of view in degrees
local LOOKAHEAD_RANGE = 45.0   -- How far we look for opponents
local SAFETY_WEIGHT = 4.0      -- HIGH = Timid (brakes for everything), LOW = Mad Max
local INTEREST_WEIGHT = 1.5    -- How much we stick to the race line
local WALL_DANGER_DIST = 0.8   -- Danger ramps up if wall margin is below this (meters)
local VISUALIZE_RAYS = true    -- Set to FALSE to save FPS when done debugging

-- VISUALIZATION CONFIG
local VIS_STEP_SIZE = 4.0      -- Distance between dots (Higher = better FPS, Lower = cleaner lines)
local VIS_RAY_HEIGHT = 0.5     -- Height above the car center to draw rays
local VIS_EFFECT = "paint_smoke" -- "paint_smoke" takes color well. Alternatives: "construct_welder"
local VIS_STEP = 3.0
local VIS_HEIGHT = 1.0

local BRAKING_POWER_FACTOR = 0.6 -- Safety margin for braking (Lower = Brake Earlier)
local SCAN_DISTANCE = 80.0       -- How far ahead to plan speed

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
    self.cornerPhase = 0 -- 0: Straight, 1: Entry, 2: Apex, 3: Exit
    self.cornerTimer = 0.0
    self.cornerDirection = 0

    self.speedUpdateTimer = 0 --
    
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

-- In DecisionModule.lua

function DecisionModule.getTargetSpeed(self, perceptionData, steerInput)
    local tm = perceptionData.Telemetry
    local currentSpeed = tm.speed
    
    -- 1. SCAN THE TRACK (Throttled)
    local tick = sm.game.getServerTick()
    if tick % 4 == 0 or not self.cachedMinRadius then
         self.cachedMinRadius, self.cachedDist = self.Driver.Perception:scanTrackCurvature(SCAN_DISTANCE)
    end
    
    local rawRadius = self.cachedMinRadius or MAX_CURVATURE_RADIUS
    local distToCorner = self.cachedDist or 0

    -- [[ FIX: RADIUS SMOOTHING ]]
    -- Initialize if nil
    if not self.smoothedRadius then self.smoothedRadius = rawRadius end

    if rawRadius < self.smoothedRadius then
        -- REACT FAST: If we see a sharper turn, accept it instantly
        self.smoothedRadius = rawRadius
    else
        -- RECOVER SLOW: If the track seems to open up, blend slowly
        -- This prevents the "Acceleration Spike" when data flickers
        self.smoothedRadius = self.smoothedRadius + (5.0) -- Increase radius by 5 units per frame max
        self.smoothedRadius = math.min(self.smoothedRadius, rawRadius)
    end
    
    local effectiveRadius = self.smoothedRadius
    
    -- [[ DEBUG VALUES ]]
    self.dbg_Radius = effectiveRadius -- Log the smoothed value
    self.dbg_Dist = distToCorner

    -- 2. CALCULATE MAX CORNER SPEED
    local friction = self.dynamicGripFactor or 0.9
    -- Use effectiveRadius instead of raw minRadius
    local maxCornerSpeed = math.sqrt(effectiveRadius * friction * 15.0) * 3.5
    
    -- Clamp limits
    maxCornerSpeed = math.max(maxCornerSpeed, MIN_CORNER_SPEED)
    maxCornerSpeed = math.min(maxCornerSpeed, self.dynamicMaxSpeed)
    
    -- 3. CALCULATE REQUIRED BRAKING
    local brakingForce = 25.0 * BRAKING_POWER_FACTOR
    local allowableSpeed = math.sqrt((maxCornerSpeed * maxCornerSpeed) + (2 * brakingForce * distToCorner))
    
    self.dbg_MaxCorner = maxCornerSpeed
    self.dbg_Allowable = allowableSpeed

    -- 4. DECISION
    local targetSpeed = math.min(self.dynamicMaxSpeed, allowableSpeed)
    
    -- 5. CONTEXT MODIFIERS
    if self.currentMode == "Drafting" then targetSpeed = targetSpeed * 1.1 end
    if self.currentMode == "Caution" then targetSpeed = 15.0 end
    if self.pitState > 0 then targetSpeed = 15.0 end
    if self.pitState == 3 then targetSpeed = 5.0 end

    -- 6. STEERING DRAG
    local steerFactor = math.abs(steerInput) * 0.1
    targetSpeed = targetSpeed * (1.0 - steerFactor)

    return targetSpeed
end

function DecisionModule.getTargetSpeed_old(self,perceptionData, steerInput)
    local navigation = perceptionData.Navigation
    local opponents = perceptionData.Opponents
    local currentMode = self.currentMode
    local currentSpeed = perceptionData.Telemetry.speed

    if self.pitState and self.pitState > 0 then
        if self.pitState == 3 then return 5.0 end 
        return PIT_SPEED_LIMIT 
    end

    local DYNAMIC_GRIP_FACTOR = self.dynamicGripFactor or GRIP_FACTOR
    local DYNAMIC_MAX_SPEED = self.dynamicMaxSpeed or BASE_MAX_SPEED

    local targetSpeed = 0.0

    if currentMode == "Formation" or currentMode == "Caution" then
        local _, structuredSpeed = self:getStructuredModeTargets(perceptionData, currentMode)
        targetSpeed = structuredSpeed
    else
        -- FIX: Use the MINIMUM of short-term radius and long-term radius
        -- This ensures we brake for a wall 50m away even if the road under us is straight.
        local immediateRadius = navigation.roadCurvatureRadius or MAX_CURVATURE_RADIUS
        local upcomingRadius = navigation.longCurvatureRadius or MAX_CURVATURE_RADIUS
        local effectiveRadius = math.min(immediateRadius, upcomingRadius)

        local calculatedSpeed = math.sqrt(effectiveRadius) * DYNAMIC_GRIP_FACTOR * 3.8 
        
        -- Banking Boost
        local bank = navigation.roadBankAngle or 0
        local turnDir = navigation.longCurveDirection or 0
        if (turnDir * bank) < -0.5 then
            calculatedSpeed = calculatedSpeed * BANKING_SPEED_BOOST
        end
        
        -- FIX: Use effectiveRadius for the MAX SPEED override check
        -- If effectiveRadius is small (approaching corner), we do NOT override to max speed.
        if effectiveRadius > MIN_RADIUS_FOR_MAX_SPEED and not self.isCornering then 
             calculatedSpeed = DYNAMIC_MAX_SPEED
        end
        
        -- Debug output updated to show effective radius
        -- print("isCornering", self.isCornering, "R:", math.floor(effectiveRadius), "Max:", MIN_RADIUS_FOR_MAX_SPEED, "CS:", math.floor(calculatedSpeed))
        
        targetSpeed = math.min(calculatedSpeed, DYNAMIC_MAX_SPEED)
        local safetyBrakeMargin = (1.0 - self.Driver.carAggression) * 0.1 
        targetSpeed = math.max(targetSpeed, MIN_CORNER_SPEED)
        local V_curve_aggressive = targetSpeed * (1.0 - safetyBrakeMargin)
        targetSpeed = math.min(targetSpeed, V_curve_aggressive)

        if currentMode == "Drafting" then
            targetSpeed = targetSpeed * DRAFT_BOOST
        elseif currentMode == "OvertakeDynamic" then
            targetSpeed = targetSpeed * PASSING_SPEED_ADVANTAGE
        elseif currentMode == "AvoidCollision" or currentMode == "AvoidWallLeft" or currentMode == "AvoidWallRight" then
            targetSpeed = MIN_CORNER_SPEED 
        elseif currentMode == "Yield" then
            targetSpeed = targetSpeed * 0.85 
        end
        
        local isProximityMode = (currentMode == "Drafting" or currentMode == "OvertakeDynamic" or currentMode == "OvertakeLeft" or currentMode == "OvertakeRight")
        local isSlowMoving = currentSpeed < 20.0 

        if not isProximityMode and isSlowMoving and opponents and opponents.count > 0 then
            local carAhead = opponents.racers[1] 
            local myBias = navigation.trackPositionBias or 0.0
            local carAheadBias = carAhead.opponentBias or 0.0
            local laneOverlap = math.abs(myBias - carAheadBias) < (CAR_WIDTH_BUFFER * 1.5)

            if carAhead and carAhead.isAhead and laneOverlap then
                if carAhead.distance < 6.0 then
                     targetSpeed = math.min(targetSpeed, 5.0) 
                end
                if carAhead.distance < 4.0 then
                     if carAhead.closingSpeed < 0 then
                        targetSpeed = 0.0 
                     end
                end
            end
        end
    end

    local steerFactor = math.abs(steerInput) * STEER_FACTOR_REDUCE
    local steerDampedSpeed = DYNAMIC_MAX_SPEED - (DYNAMIC_MAX_SPEED - MIN_CORNER_SPEED) * steerFactor
    
    return math.min(targetSpeed, steerDampedSpeed)
end

function DecisionModule:getYieldBias(perceptionData)
    local nav = perceptionData.Navigation
    if nav.longCurveDirection ~= 0 then
        return -nav.longCurveDirection * YIELD_BIAS_OFFSET
    end
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


function DecisionModule:calculateContextBias(perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local wall = perceptionData.WallAvoidance
    local telemetry = perceptionData.Telemetry

    -- 1. SETUP MAPS
    local interestMap = {}
    local dangerMap = {}
    local rayAngles = {}
    
    local sectorStep = VIEW_ANGLE / (NUM_RAYS - 1)
    local startAngle = -(VIEW_ANGLE / 2)

    -- 2. BUILD INTEREST MAP
    local preferredBias = 0.0 
    if self.currentMode == "DefendLine" then preferredBias = self.targetBias end 
    local preferredAngle = preferredBias * 45.0 -- [FIX] Removed negative sign

    for i = 1, NUM_RAYS do
        local angle = startAngle + (i - 1) * sectorStep
        rayAngles[i] = angle
        dangerMap[i] = 0.0
        
        local diff = math.abs(angle - preferredAngle)
        local sigma = 30.0 
        interestMap[i] = math.exp(-(diff * diff) / (2 * sigma * sigma))
    end

    -- 3. BUILD DANGER MAP (Opponents)
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

    -- 4. BUILD DANGER MAP (Walls)
    if wall then
        local critMargin = 1.5
        -- Block Left Rays (Negative Angles)
        if wall.marginLeft < critMargin then
            local urgency = 1.0 - (math.max(wall.marginLeft, 0) / critMargin)
            local blockAngle = -10.0 * (1.0 - urgency)
            for i = 1, NUM_RAYS do
                if rayAngles[i] < -5 and rayAngles[i] < blockAngle then
                    dangerMap[i] = math.max(dangerMap[i], urgency)
                end
            end
        end
        -- Block Right Rays (Positive Angles)
        if wall.marginRight < critMargin then
            local urgency = 1.0 - (math.max(wall.marginRight, 0) / critMargin)
            local blockAngle = 10.0 * (1.0 - urgency)
            for i = 1, NUM_RAYS do
                if rayAngles[i] > 5 and rayAngles[i] > blockAngle then
                    dangerMap[i] = math.max(dangerMap[i], urgency)
                end
            end
        end
    end

    -- 5. SOLVE
    local bestScore = -math.huge
    local bestIndex = math.ceil(NUM_RAYS/2)

    for i = 1, NUM_RAYS do
        local score = (interestMap[i] * INTEREST_WEIGHT) - (dangerMap[i] * SAFETY_WEIGHT)
        if score > bestScore then
            bestScore = score
            bestIndex = i
        end
    end

    -- 6. PREPARE VISUALIZATION DATA (Server Side)
    -- We do NOT draw here. We package data to send to client.
    local debugData = nil
    if VISUALIZE_RAYS then
        debugData = self:getDebugLines(rayAngles, interestMap, dangerMap, bestIndex, NUM_RAYS)
    end

    -- 7. OUTPUT
    -- [FIX] Removed negative sign. 
    -- +Angle (Right) -> +Bias (Right Steering)
    local chosenAngle = rayAngles[bestIndex]
    local targetBias = (chosenAngle / 45.0) 
    
    return math.min(math.max(targetBias, -1.0), 1.0), debugData
end


function DecisionModule.handleCorneringStrategy(self, perceptionData, dt)
    local nav = perceptionData.Navigation
    local radius = nav.roadCurvatureRadius or MIN_RADIUS_FOR_MAX_SPEED 
    local curveDir = nav.longCurveDirection 

    -- 1. State Transition: Straight to Corner Entry (0 -> 1)
    if self.isCornering == false and radius < CORNER_RADIUS_THRESHOLD then
        self.isCornering = true
        self.cornerPhase = 1 -- Entry (Out)
        self.cornerTimer = CORNER_PHASE_DURATION
        self.cornerDirection = curveDir -- 1 for Right, -1 for Left
        self.currentMode = "Cornering"
        self.targetBias = -self.cornerDirection * CORNER_ENTRY_BIAS 
        return
    end
    
    if self.isCornering == true then
        self.cornerTimer = self.cornerTimer - dt

        -- 2. State Transition: Entry to Apex (1 -> 2)
        if self.cornerPhase == 1 and self.cornerTimer <= 0.0 then
            self.cornerPhase = 2 -- Apex (In)
            self.cornerTimer = CORNER_PHASE_DURATION
            self.targetBias = self.cornerDirection * CORNER_APEX_BIAS
        
        -- 3. State Transition: Apex to Exit (2 -> 3)
        elseif self.cornerPhase == 2 and self.cornerTimer <= 0.0 then
            self.cornerPhase = 3 -- Exit (Out)
            self.cornerTimer = CORNER_PHASE_DURATION
            self.targetBias = -self.cornerDirection * CORNER_EXIT_BIAS
        
        -- 4. State Transition: Exit to Straight (3 -> 0)
        elseif self.cornerPhase == 3 and (self.cornerTimer <= 0.0 or radius >= 2.0 * CORNER_RADIUS_THRESHOLD) then
            self.isCornering = false
            self.cornerPhase = 0
            self.cornerTimer = 0.0
            self.cornerDirection = 0
            self.currentMode = "RaceLine" 
            self.targetBias = (self.Driver.carAggression - 0.5) * 0.8 
        end
    end
    
    -- [[ FIX: INCREASED SAFETY THRESHOLD ]]
    -- Was: radius > 3 * CORNER_RADIUS_THRESHOLD
    -- Change to: radius > 5 * CORNER_RADIUS_THRESHOLD
    -- This prevents the car from abandoning the "Cornering" line just because
    -- it saw a brief glimpse of straight track while mid-corner.
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
    
    -- 1. CRITICAL OVERRIDES
    if self.pitState and self.pitState > 0 then return 0.0 end
    if self.isCornering then return self.targetBias end
    if currentMode == "Formation" or currentMode == "Caution" then
        local b, _ = self:getStructuredModeTargets(perceptionData, currentMode)
        return b
    end

    -- 2. HYBRID CONTEXT SYSTEM (Now handles Walls, Opponents, and Overtakes)
    -- We enable this if there is Traffic OR Wall Danger
    local isWallDanger = (wall.isLeftCritical or wall.isRightCritical or wall.isForwardLeftCritical or wall.isForwardRightCritical)
    
    if currentMode == "OvertakeDynamic" or 
       currentMode == "AvoidCollision" or 
       (opp.count > 0) or 
       isWallDanger then  -- <--- Added Wall Trigger
       
        local bias, debugData = self:calculateContextBias(perceptionData)
        self.latestDebugData = debugData 
        return bias
    end

    -- 3. STANDARD MODES
    if currentMode == "Drafting" then return 0.0 end
    if currentMode == "Yield" then return self:getYieldBias(perceptionData) end
    if currentMode == "DefendLine" then
        if nav.longCurveDirection ~= 0 then return nav.longCurveDirection * DEFENSE_BIAS_FACTOR end
        return DEFENSE_BIAS_FACTOR * self.Driver.carAggression * getSign(nav.trackPositionBias or 0.01)
    end
    
    -- Default Cruise
    return (self.Driver.carAggression - 0.5) * 0.8 
end


function DecisionModule.getFinalTargetBias_old(self, perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local aggression = self.Driver.carAggression 
    local currentMode = self.currentMode 
    local targetBias = 0.0 
    local wall = perceptionData.WallAvoidance 

    if self.pitState and self.pitState > 0 then
        return 0.0 
    end

    if self.isCornering then
        targetBias = self.targetBias
    elseif currentMode == "Formation" or currentMode == "Caution" then
        local structuredBias, _ = self:getStructuredModeTargets(perceptionData, currentMode)
        targetBias = structuredBias
    elseif currentMode == "AvoidWallLeft" then
        targetBias = WALL_STEERING_BIAS 
    elseif currentMode == "AvoidWallRight" then
        targetBias = -WALL_STEERING_BIAS
elseif self.currentMode == "OvertakeDynamic" or self.currentMode == "AvoidCollision" or (perceptionData.Opponents and perceptionData.Opponents.count > 0) then
        local bias, debugData = self:calculateContextBias(perceptionData)
        self.latestDebugData = debugData 
        return bias
    elseif currentMode == "Drafting" then
        targetBias = 0.0
    elseif currentMode == "Yield" then 
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

function DecisionModule.determineStrategy(self,perceptionData, dt)
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
    
    if opp.blueFlagActive then
        self.currentMode = "Yield"
        return
    end
    
    self:handleCorneringStrategy(perceptionData, dt)
    
    if self.isCornering then
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
                -- print(self.Driver.id,self.currentMode,closestOpponent.distance)
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
    
    if self.isCornering and self.cornerPhase == 1 and currentSpeed > targetSpeed * 1.05 then
         brake = math.max(brake, self.Driver.carAggression * 0.4)
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
        self:determineStrategy(perceptionData, dt) 
        controls.steer = self:calculateSteering(perceptionData)
        controls.throttle, controls.brake = self:calculateSpeedControl(perceptionData, controls.steer)
    end

    local spd = perceptionData.Telemetry.speed or 0 -- logging
    local tick = sm.game.getServerTick()
    if spd > 10 and self.dbg_Radius and  tick % 3 == 0 then -- Only log when moving and every 3 ticks
        print(string.format(
            "[%s] SPD: %.0f/%.0f | RAD: %.0f (Dist: %.0f) | LIMIT: %.0f | ACT: T:%.1f B:%.1f | MODE: %s",
            tostring(self.Driver.id % 100), -- Short ID
            spd,                            -- Current Speed
            self.dbg_Allowable or 0,        -- The speed the physics says is safe
            self.dbg_Radius or 0,           -- The tightest turn seen
            self.dbg_Dist or 0,             -- Distance to that turn
            self.dbg_MaxCorner or 0,        -- The max speed for that turn
            controls.throttle,              -- Throttle Output
            controls.brake,                 -- Brake Output
            self.currentMode                -- AI State
        ))
    end

    self.controls = controls
    return controls
end



function DecisionModule:getDebugLines(angles, interest, danger, bestIdx, count)
    if not self.Driver or not self.Driver.shape then return nil end
    local tm = self.Driver.perceptionData.Telemetry
    if not tm or not tm.location then return nil end
    
    -- [FIX] Use Geometric Center
    local min, max = self.Driver.body:getWorldAabb()
    local centerPos = (min + max) * 0.5
    
    local fwd = tm.rotations.at
    local right = tm.rotations.right
    local up = tm.rotations.up
    
    -- [FIX] Lowered Height: Changed (up * 0.5) to (up * -0.15)
    local startPos = centerPos + (fwd * 2.5) + (up * -0.15)
    
    local lines = {}
    
    for i=1, count do
        local isBest = (i == bestIdx)
        if isBest or danger[i] > 0.1 or (i == 1) or (i == count) or (i == math.ceil(count/2)) then
            local rad = math.rad(angles[i])
            local dir = (fwd * math.cos(rad)) + (right * math.sin(rad))
            
            local colorCode = 1 
            local len = 15
            
            if isBest then 
                colorCode = 4
                len = 25
            elseif danger[i] > 0.5 then
                colorCode = 3 
                len = 10
            elseif danger[i] > 0.0 then
                colorCode = 2 
            end
            
            table.insert(lines, {
                s = startPos, 
                e = startPos + (dir * len), 
                c = colorCode
            })
        end
    end
    return lines
end