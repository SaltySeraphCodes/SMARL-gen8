dofile("globals.lua") 
DecisionModule = class(nil)

-- [[ TUNING - PHYSICS ]]
local MAX_TILT_RAD = 1.047 
local STUCK_SPEED_THRESHOLD = 0.5 
local STUCK_TIME_LIMIT = 6.0
local BASE_MAX_SPEED = 1000 
local MIN_CORNER_SPEED = 12
local GRIP_FACTOR = 0.8            
local MIN_RADIUS_FOR_MAX_SPEED = 130.0 

-- [[ TUNING - STEERING PID ]]
local MAX_WHEEL_ANGLE_RAD = 0.8 
local DEFAULT_STEERING_Kp = 0.12  
local DEFAULT_STEERING_Kd = 0.1 -- Increase damping. Resist the swing  
local LATERAL_Kp = 1.0            
local Kp_MIN_FACTOR = 0.35     
local Kd_BOOST_FACTOR = 1.2    
-- [NEW] Slew Rate Limit (Max steering change per second)
-- 4.0 means it takes 0.25s to go from center to full lock. 
-- Prevents instant snaps that break physics.
local STEERING_SLEW_RATE = 4.0 

-- [[ TUNING - SPEED PID ]]
local SPEED_Kp = 0.15             
local SPEED_Ki = 0.02             
local SPEED_Kd = 0.25             
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
local CORNER_RADIUS_THRESHOLD = 75.0  
local CORNER_ENTRY_BIAS = 0.60         
local CORNER_APEX_BIAS = 0.85          
local CORNER_EXIT_BIAS = 0.40          
local CORNER_PHASE_DURATION = 0.3      

-- [[ CONTEXT STEERING ]]
local NUM_RAYS = 17            
local VIEW_ANGLE = 120         
local LOOKAHEAD_RANGE = 45.0   
local SAFETY_WEIGHT = 10.0     
local INTEREST_WEIGHT = 2.0    
local WALL_AVOID_DIST = 1.5    
local VISUALIZE_RAYS = true    

-- [[ BRAKING PHYSICS ]]
local BRAKING_POWER_FACTOR = 0.9 
local SCAN_DISTANCE = 120.0      


-- [[ MODE SPEEDS ]]
FORMATION_SPEED = 25.0
FORMATION_DISTANCE = 8.0
FORMATION_BIAS_OUTSIDE = 0.5
FORMATION_BIAS_INSIDE = -0.5

CAUTION_SPEED = 35.0
CAUTION_DISTANCE = 15.0

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
    
    -- Optimizable Variables ---
    self.STEERING_Kp_BASE = DEFAULT_STEERING_Kp
    self.STEERING_Kd_BASE = DEFAULT_STEERING_Kd
    self.brakingForceConstant = 15.0

    self.trackPositionBias = 0.0 
    self.smoothedRadius = 1000.0
    self.radiusHoldTimer = 0.0
    self.cachedDist = 0.0
    self.smoothedBias = 0.0 
    
    self.lastSteerOut = 0.0 -- For Slew Rate Limiting

    self:calculateCarPerformance()
end
-- helpers:
function DecisionModule:getFutureCenterPoint(startNode, startT, dist, chain)
    local currentNode = startNode
    local distRemaining = dist
    
    -- Safety limit to prevent infinite loops (max 30 nodes ahead)
    for i = 1, 30 do
        -- Use global helper 'getNextItem' from globals.lua
        local nextNode = getNextItem(chain, currentNode.id, 1)
        if not nextNode then return currentNode.mid, currentNode end -- End of chain
        
        -- Measure distance between MID points (Centerline distance)
        local segmentVec = nextNode.mid - currentNode.mid
        local segmentDist = segmentVec:length()
        
        -- If we are currently ON this segment (first iteration)
        if i == 1 and startT > 0 then
            local distCovered = segmentDist * startT
            segmentDist = segmentDist - distCovered
            if segmentDist > distRemaining then
                local currentT = startT + (distRemaining / (nextNode.mid - currentNode.mid):length())
                local interpMid = currentNode.mid + (segmentVec:normalize() * (segmentVec:length() * currentT))
                return interpMid, currentNode
            end
        elseif segmentDist >= distRemaining then
            -- We found the segment! Interpolate.
            local t = distRemaining / segmentDist
            local interpMid = currentNode.mid + (segmentVec * t)
            return interpMid, currentNode
        end
        
        distRemaining = distRemaining - segmentDist
        currentNode = nextNode
    end
    
    return currentNode.mid, currentNode
end

function DecisionModule.calculateCarPerformance(self)
    local car = self.Driver
    
    -- 1. BASELINE GRIP (The "Potential" of the car)
    -- Start with standard physics (0.8) plus Aero
    local baseGrip = GRIP_FACTOR
    local spoilerAngle = car.spoiler_angle or 0.0 
    local downforceBoost = math.min(spoilerAngle / 80.0, 1.0) * 0.1 
    baseGrip = baseGrip + downforceBoost

    -- 2. APPLY LEARNED PHYSICS
    -- If the optimizer found the car is naturally grippier (on fresh tires), use that.
    if self.Driver.Optimizer and self.Driver.Optimizer.learnedGrip then
        local learned = self.Driver.Optimizer.learnedGrip
        -- Trust the learned profile 60%, base physics 40%
        baseGrip = (baseGrip * 0.4) + (learned * 0.6)
    end

    -- 3. APPLY SIMULATED TIRE FACTORS (Type & Wear)
    -- Now we apply the penalty to the Baseline
    local tireTypeData = TIRE_TYPES[car.Tire_Type] or { GRIP = 0.5 }
    local typeMultiplier = tireTypeData.GRIP
    
    -- Wear Penalty: 0% wear = 0 penalty. 100% wear = 0.2 penalty.
    local currentHealth = car.Tire_Health or 1.0
    local wearPenalty = (1.0 - currentHealth) * 0.2 
    
    -- Final Grip = Baseline * (TireType - Wear)
    -- Example: 1.0 * (1.0 - 0.2) = 0.8 effective grip on dead tires
    self.dynamicGripFactor = baseGrip * (typeMultiplier - wearPenalty)
    
    -- 4. SPEED LIMITS (Limp Modes)
    local gearRatio = car.gear_length or 1.0 
    self.dynamicMaxSpeed = BASE_MAX_SPEED * gearRatio * 0.5 
    
    if car.tireLimp then
        self.dynamicMaxSpeed = math.min(self.dynamicMaxSpeed, 40.0) 
        self.dynamicGripFactor = self.dynamicGripFactor * 0.5
    end
    if car.fuelLimp then
        self.dynamicMaxSpeed = math.min(self.dynamicMaxSpeed, 20.0) 
        self.dynamicGripFactor = self.dynamicGripFactor * 0.9 
    end
end

function DecisionModule:updateTrackState(perceptionData)
    local tick = sm.game.getServerTick()
    
    -- [UPDATED] Update the scan every 4 ticks (0.1 seconds) to save CPU
    if tick % 4 == 0 or not self.cachedMinRadius then
         self.cachedMinRadius, self.cachedDist, self.cachedApex = self.Driver.Perception:scanTrackCurvature(SCAN_DISTANCE)
    end
    
    local rawRadius = self.cachedMinRadius or 1000.0
    
    -- [FIX] KINK REJECTION
    -- If the radius drops suddenly (e.g. from 1000 to 50), do not apply it instantly.
    -- Require it to persist for a few frames, or blend it slower.
    
    if rawRadius < self.smoothedRadius then
        -- Instead of snapping instantly, we interpolate down.
        -- This acts as a low-pass filter. 
        -- If it's a 1-frame kink, smoothedRadius won't drop all the way down before it clears.
        local dropRate = 0.2 -- 20% blend per update
        self.smoothedRadius = self.smoothedRadius + (rawRadius - self.smoothedRadius) * dropRate
        
        self.radiusHoldTimer = 1.0 
    else
        -- Recovering speed (track straightening out)
        if self.radiusHoldTimer > 0 then
            self.radiusHoldTimer = self.radiusHoldTimer - (1.0/40.0) 
        else
            self.smoothedRadius = self.smoothedRadius + 15.0 -- Recovery rate
        end
    end

    -- Clamp limits
    if self.smoothedRadius < rawRadius then self.smoothedRadius = rawRadius end -- Don't be "slower" than the actual turn
    if self.smoothedRadius > 1000.0 then self.smoothedRadius = 1000.0 end
    
    self.dbg_Radius = self.smoothedRadius
    self.dbg_Dist = self.cachedDist or 0.0
end

function DecisionModule.getTargetSpeed(self, perceptionData, steerInput)
    local effectiveRadius = self.smoothedRadius
    local distToApex = self.cachedDist or 0.0
    local currentSpeed = perceptionData.Telemetry.speed or 0.0

    -- 1. PHYSICS SETUP
    local friction = self.dynamicGripFactor or 0.8
    -- Conservative Factor: Treat the corner as 10% tighter than it looks
    local safetyRadius = math.max(effectiveRadius * 0.9, 10.0)

    -- 2. CALCULATE MAX CORNERING SPEED (v^2/r = u*g)
    local lateralGrip = 20.0 -- Was 15.0. 20.0 allows for 2.0g turns.
    if self.Driver.Optimizer then
        -- Scale the optimizer's cornerLimit (usually 1.0-3.5) to G-force units
        lateralGrip = self.Driver.Optimizer.cornerLimit * 10.0 
    end
    local friction = self.dynamicGripFactor or 0.8
    local maxCornerSpeed = math.sqrt(safetyRadius * friction * lateralGrip)
    
    -- Clamp limits
    maxCornerSpeed = math.max(maxCornerSpeed, MIN_CORNER_SPEED)
    maxCornerSpeed = math.min(maxCornerSpeed, self.dynamicMaxSpeed)
    
    -- 3. BRAKING DISTANCE CALCULATION (Kinematics)
    local brakingForce = (self.Driver.Optimizer and self.Driver.Optimizer.brakingFactor) or self.brakingForceConstant
    
    -- [CRITICAL FIX] Reaction Time Buffer
    -- Subtract the distance we will cover while the brakes are physically engaging (approx 0.2s)
    -- If we are moving 40 m/s, we lose 8 meters here. This prevents overshoot.
    local latencyMeters = currentSpeed * 0.2
    local effectiveBrakingDist = math.max(0.0, distToApex - latencyMeters)
    
    -- Formula: v_entry = sqrt( v_corner^2 + 2 * a * d )
    local allowableSpeed = math.sqrt((maxCornerSpeed^2) + (2 * brakingForce * effectiveBrakingDist))

    -- Debug values for your print log
    self.dbg_MaxCorner = maxCornerSpeed
    self.dbg_Allowable = allowableSpeed

    local targetSpeed = math.min(self.dynamicMaxSpeed, allowableSpeed)

    -- Context Overrides (Pit/Caution)
    if self.currentMode == "Caution" then targetSpeed = 15.0 end 
    if self.pitState > 0 then targetSpeed = 15.0 end
    if self.pitState == 3 then targetSpeed = 5.0 end

    return targetSpeed
end


function DecisionModule:calculateContextBias(perceptionData, preferredBias)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local wall = perceptionData.WallAvoidance
    local telemetry = perceptionData.Telemetry

    local interestMap = {}
    local dangerMap = {}
    local rayAngles = {}
    
    local sectorStep = VIEW_ANGLE / (NUM_RAYS - 1)
    local startAngle = -(VIEW_ANGLE / 2)

    -- Map the preferred bias (-1 to 1) to an Angle (-55 to 55 degrees)
    -- We use 55 instead of 60 to keep the goal slightly within the view cone
    local centeringAngle = preferredBias * 55.0 

    for i = 1, NUM_RAYS do
        local angle = startAngle + (i - 1) * sectorStep
        rayAngles[i] = angle
        dangerMap[i] = 0.0
        
        -- Gaussian Distribution for Interest
        -- Highest interest at the 'centeringAngle'
        local diff = math.abs(angle - centeringAngle)
        local sigma = 20.0 
        interestMap[i] = math.exp(-(diff * diff) / (2 * sigma * sigma))
    end

    -- [Rest of your Obstacle Detection logic remains the same...]
    -- (Copy your existing obstacle/wall loop here)
    if opp and opp.racers then
        for _, racer in ipairs(opp.racers) do
            if racer.isAhead and racer.distance < LOOKAHEAD_RANGE then
                local toOp = racer.location - telemetry.location
                local fwd = telemetry.rotations.at
                local right = telemetry.rotations.right
                
                local dx = toOp:dot(right)
                local dy = toOp:dot(fwd)
                local oppAngle = math.deg(math.atan2(dx, dy))
                local carWidthDeg = math.deg(math.atan2(2.5, racer.distance)) * 2.5 
                
                for i = 1, NUM_RAYS do
                    local diff = math.abs(rayAngles[i] - oppAngle)
                    if diff < carWidthDeg then
                        local severity = 1.0 - (racer.distance / LOOKAHEAD_RANGE)
                        dangerMap[i] = math.max(dangerMap[i], severity * 2.0) -- Boosted weight
                    end
                end
            end
        end
    end

    if wall then
         -- (Keep your existing Wall Logic here)
         local avoidanceMargin = WALL_AVOID_DIST 
         if wall.marginLeft < avoidanceMargin then
             -- Left Wall Danger -> Block Left Rays (Negative Angles)
             local urgency = 1.0 - (math.max(wall.marginLeft, 0) / avoidanceMargin)
             for i = 1, NUM_RAYS do
                 if rayAngles[i] < 0 then dangerMap[i] = math.max(dangerMap[i], urgency) end
             end
         end
         if wall.marginRight < avoidanceMargin then
             -- Right Wall Danger -> Block Right Rays (Positive Angles)
             local urgency = 1.0 - (math.max(wall.marginRight, 0) / avoidanceMargin)
             for i = 1, NUM_RAYS do
                 if rayAngles[i] > 0 then dangerMap[i] = math.max(dangerMap[i], urgency) end
             end
         end
    end

    -- SELECT BEST RAY
    local bestScore = -math.huge
    local bestIndex = math.ceil(NUM_RAYS/2)

    for i = 1, NUM_RAYS do
        -- Weight: Safety is 5x more important than Interest
        local score = (interestMap[i] * 1.0) - (dangerMap[i] * 5.0)
        if score > bestScore then
            bestScore = score
            bestIndex = i
        end
    end

    -- Return Bias (-1 to 1) and Debug Data
    local debugData = nil
    if VISUALIZE_RAYS then
        debugData = self:getDebugLines(rayAngles, interestMap, dangerMap, bestIndex, NUM_RAYS)
    end

    local chosenAngle = rayAngles[bestIndex]
    local targetBias = chosenAngle / 55.0 
    
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
    
    -- 1. ACTIVE CORNERING (We are IN the turn)
    -- If the current radius is tight, we must hit the apex NOW.
    if nav.roadCurvatureRadius < 180.0 then
        -- Standard Apex Logic: Inside of the turn
        if nav.longCurveDirection == 1 then return 0.9 end -- Right Turn -> Hug Right
        if nav.longCurveDirection == -1 then return -0.9 end -- Left Turn -> Hug Left
    end
    
    -- 2. SETUP PHASE (Distance Based)
    -- We are on a straight, but a corner is coming.
    if nav.distToNextCorner < 200.0 and nav.nextCornerDir ~= 0 then
        -- Optimization: The closer we get, the wider we push.
        -- At 200m away -> Bias 0.2
        -- At 50m away  -> Bias 1.0
        
        -- SETUP LOGIC: Go OPPOSITE to the turn direction (Open the entry)
        -- If Next Turn is RIGHT (1), we want to be LEFT (-1).
        local setupSide = -nav.nextCornerDir 
        
        -- Ramp up the bias as we get closer
        local urgency = 1.0 - (math.max(0, nav.distToNextCorner - 20) / 180.0)
        -- urgency is 0.0 at 200m, 1.0 at 20m.
        
        return setupSide * urgency * 0.95 -- Target 95% width
    end

    -- 3. CRUISING (Straight and Clear)
    return 0.0
end


function DecisionModule.getFinalTargetBias(self, perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local wall = perceptionData.WallAvoidance 
    
    -- [[ CRITICAL FIX ]]
    -- START with the recorded line (Where we WANT to be)
    -- DO NOT use trackPositionBias here (Where we ARE)
    local idealBias = nav.racingLineBias or 0.0    
    
    -- --- LAYER 1: STRATEGIC OVERRIDES ---
    if self.currentMode == "Formation" or self.currentMode == "Caution" then
        local b, _ = self:getStructuredModeTargets(perceptionData, self.currentMode)
        idealBias = b
    elseif self.currentMode == "Drafting" and opp.draftingTarget then
        -- Follow the opponent's bias
        idealBias = opp.draftingTarget.opponentBias
    elseif self.currentMode == "Yield" then
        idealBias = self:getYieldBias(perceptionData)
    elseif self.currentMode == "DefendLine" then
         -- Block the side we are currently on (Use Current Pos to decide, but return Target)
         local mySide = getSign(nav.trackPositionBias or 0.0)
         idealBias = mySide * DEFENSE_BIAS_FACTOR 
    elseif self.currentMode == "OvertakeDynamic" and self.dynamicOvertakeBias then
         idealBias = self.dynamicOvertakeBias
    end

    -- --- LAYER 2: PHYSICS & SAFETY ---
    if self.isCornering then
        -- In a corner, strictly follow the geometric apex calculated by handleCorneringStrategy
        if self.currentMode == "OvertakeDynamic" then
             -- Blend: 80% Apex, 20% Overtake Line
             idealBias = (self.targetBias * 0.8) + (idealBias * 0.2)
        else
             idealBias = self.targetBias 
        end
    end
    
    if self.pitState > 0 then idealBias = 0.0 end

    -- --- LAYER 3: CONTEXT STEERING ---
    -- Context needs to know:
    -- 1. Where do we WANT to go? (idealBias)
    -- 2. Where are the dangers? (Telemetry)
    
    local isWallDanger = (wall.isLeftCritical or wall.isRightCritical)
    local isOpponentDanger = (opp.count > 0 and opp.collisionRisk)
    
    if isWallDanger or isOpponentDanger or VISUALIZE_RAYS then
        -- calculateContextBias internally uses nav.trackPositionBias (Current) 
        -- only to calculate the angles to walls/cars.
        local safeBias, debugData = self:calculateContextBias(perceptionData, idealBias)
        
        if debugData then self.latestDebugData = debugData end

        if math.abs(safeBias - idealBias) > 0.1 then
             return safeBias
        end
    end

    return idealBias
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
    if self.isStuck then self.Driver.resetPosTimeout = 11.0 end 
    if self.stuckTimer >= STUCK_TIME_LIMIT then 
        print("stuck")
        self.isStuck = true else self.isStuck = false end
    if self.isFlipped or self.isStuck then 
        print("flipped")
        resetFlag = true end
    return resetFlag
end

function DecisionModule.determineStrategy(self, perceptionData, dt)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local telemetry = perceptionData.Telemetry
    local aggressionFactor = self.Driver.carAggression
    
    -- DEFAULT MODE
    self.currentMode = "RaceLine" 

    -- 1. CRITICAL OVERRIDES (States that fundamentally change behavior)
    if self.Driver.formation then self.currentMode = "Formation"; return
    elseif self.Driver.caution then self.currentMode = "Caution"; return
    elseif self.pitState > 0 then self.currentMode = "Pit"; return end
    
    -- 2. CORNERING (Physics Logic)
    -- We calculate this every frame, but we don't return yet. 
    -- We want to know if we are cornering, but still run Overtake logic if possible.
    self:handleCorneringStrategy(perceptionData, dt)

    -- 3. INTERACTION STRATEGIES
    if opp.blueFlagActive then 
        self.currentMode = "Yield"
        return 
    end
    
    -- If we are actively cornering, we generally suppress complex overtaking 
    -- unless we are "OvertakeDynamic" (dive bombing).
    if self.isCornering and self.currentMode ~= "OvertakeDynamic" then 
        return 
    end

    local isStraight = nav.roadCurvatureRadius >= 500

    -- 4. OPPONENT INTERACTION
    if opp.count > 0 then
        local closestOpponent = opp.racers[1]
        
        -- A. DEFENSE (Behind us and close)
        if closestOpponent and not closestOpponent.isAhead and closestOpponent.distance < 15 then
            if closestOpponent.closingSpeed < -1.0 or aggressionFactor > 0.6 then 
                self.currentMode = "DefendLine"
            end
        end
        
        -- B. OFFENSE (Ahead of us)
        if closestOpponent and closestOpponent.isAhead then
            -- DRAFTING (Fast, Straight, Aggressive)
            if closestOpponent.distance < PASSING_DISTANCE_LIMIT and closestOpponent.distance > 5.0 
               and isStraight and aggressionFactor >= 0.3 and telemetry.speed > 30 then
                self.currentMode = "Drafting"
            
            -- OVERTAKING
            elseif closestOpponent.distance < PASSING_DISTANCE_LIMIT then
                 -- Stick with the gap if we found one
                 if self.currentMode == "OvertakeDynamic" and closestOpponent.distance < PASSING_EXIT_DISTANCE then
                     local bestBias = self:findBestOvertakeGap(perceptionData)
                     self.dynamicOvertakeBias = bestBias
                 -- Calculate new gap if closing in
                 elseif closestOpponent.closingSpeed < MIN_CLOSING_SPEED then 
                    local bestBias = self:findBestOvertakeGap(perceptionData)
                    self.currentMode = "OvertakeDynamic"
                    self.dynamicOvertakeBias = bestBias
                 end
            end
        end
    end
end


function DecisionModule.calculateSteering(self, perceptionData, dt)
    if not perceptionData or not perceptionData.Navigation then return 0.0 end
    if not self.latestDebugData then self.latestDebugData = {} end

    local nav = perceptionData.Navigation
    local telemetry = perceptionData.Telemetry
    local speed = telemetry.speed
    local optim = self.Driver.Optimizer
    
    -- [[ STEP 1: GET THE GOAL ]]
    -- Call our new strategy function. 
    -- This returns a value between -1.0 (Left Edge) and 1.0 (Right Edge)
    local targetBias = self:getFinalTargetBias(perceptionData)
    
    -- [[ STEP 2: CLAMP & SMOOTH ]]
    local trackWidth = 20.0
    if nav.closestPointData and nav.closestPointData.baseNode then
        trackWidth = nav.closestPointData.baseNode.width
    end
    local halfWidth = trackWidth / 2.0
    
    -- Safety Clamp (Don't drive off the map)
    local safeZone = math.max(1.0, halfWidth - 3.5) -- 3.5m padding from edge
    local maxBias = safeZone / halfWidth
    targetBias = math.max(math.min(targetBias, maxBias), -maxBias)
    
    -- Smooth the target movement (prevent twitching)
    local lerpRate = 0.15 
    self.smoothedBias = (self.smoothedBias or 0) * (1.0 - lerpRate) + targetBias * lerpRate
    local finalBias = self.smoothedBias

    -- [[ STEP 3: CALCULATE LOOKAHEAD POINT ]]
    local mult = (optim and optim.lookaheadMult) or 1.0 
    local lookaheadDist = math.max(12.0, speed * mult)
    
    -- Find the node ahead on the centerline
    local centerPoint, _ = self.Driver.Perception:getFutureCenterPoint(
        nav.closestPointData.baseNode, 
        nav.closestPointData.tOnSegment, 
        lookaheadDist, 
        self.Driver.Perception.chain
    )

    -- [[ STEP 4: APPLY BIAS TO GET TARGET POINT ]]
    -- Offset the center point by our Goal Bias
    -- This creates the "Red Dot" the car chases
    local perpDir = nav.closestPointData.baseNode.perp or self.Driver.shape:getRight()
    local targetPoint = centerPoint + (perpDir * (finalBias * halfWidth))

    -- Debug Data
    self.latestDebugData.targetPoint = targetPoint
    self.latestDebugData.futureCenter = centerPoint
    self.latestDebugData.usedPerp = perpDir

    -- [[ STEP 5: PURE PURSUIT (EXECUTION) ]]
    -- Calculate error between CAR (Current) and TARGET POINT (Goal)
    local carPos = telemetry.location
    local vecToTarget = targetPoint - carPos
    
    -- Transform to Local Space (How far left/right is the target relative to my nose?)
    local localY = vecToTarget:dot(telemetry.rotations.right)
    
    local distSq = vecToTarget:length2()
    local curvature = (2.0 * localY) / distSq
    
    local steerOutput = curvature * 3.5 -- Gain
    
    -- Damping/Slew Rate logic...
    local yawRate = 0
    if telemetry.angularVelocity then yawRate = telemetry.angularVelocity:dot(telemetry.rotations.up) end
    local damping = yawRate * ((optim and optim.dampingFactor) or 0.25)
    local rawOutput = steerOutput - damping
    
    return math.max(math.min(rawOutput, 1.0), -1.0)
end



function DecisionModule.calculateSpeedControl(self,perceptionData, steerInput)
    local currentSpeed = perceptionData.Telemetry.speed
    local targetSpeed = self:getTargetSpeed(perceptionData,steerInput) -- Recalculated here
    
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
        throttle = 0.0
        brake = 0.0 
    end
    
    -- Corner Entry Braking Assist
    if self.isCornering and self.cornerPhase == 1 and currentSpeed > targetSpeed * 1.05 then
         brake = math.max(brake, self.Driver.carAggression * 0.4)
    end
    
    -- RETURN TARGET SPEED FOR LOGGING
    return throttle, brake, targetSpeed
end

function DecisionModule.server_onFixedUpdate(self,perceptionData,dt)
    local controls = {}
    controls.resetCar = self:checkUtility(perceptionData,dt)

    self:updateTrackState(perceptionData)

    local targetSpeedForLog = 0.0

    if controls.resetCar then
        print(self.Driver.id,"resetting car")
        controls.steer = 0.0; controls.throttle = 0.0; controls.brake = 0.0
    else
        self:determineStrategy(perceptionData, dt) 
        controls.steer = self:calculateSteering(perceptionData, dt)
        -- Capture target speed from the updated function
        controls.throttle, controls.brake, targetSpeedForLog = self:calculateSpeedControl(perceptionData, controls.steer)
    end

    local spd = perceptionData.Telemetry.speed or 0 
    
    -- Crash Detection
    if self.lastSpeed then
        local delta = spd - self.lastSpeed
        if delta < -8.0 then 
            print(self.Driver.id, "WALL IMPACT DETECTED! Delta:", delta)
            if self.Driver.Optimizer then self.Driver.Optimizer:reportCrash() end
        end
    end
    self.lastSpeed = spd

    -- [[ TELEMETRY LOGGING ]]
    local tick = sm.game.getServerTick()
    -- Log every 4 ticks (0.1s) for readability, or every 1 tick if debugging a crash
    if spd > 1.0 and tick % 4 == 0 then 
        local nav = perceptionData.Navigation
        local tm = perceptionData.Telemetry
        
        -- 1. HEADING ERROR (Are we crab-walking?)
        -- Calculate the angle between Car Forward and Track Forward
        local hdgErr = 0.0
        if nav.closestPointData and nav.closestPointData.baseNode then
            local trackFwd = nav.closestPointData.baseNode.outVector
            local carFwd = tm.rotations.at
            -- Ignore Z for heading error
            local flatTrack = sm.vec3.new(trackFwd.x, trackFwd.y, 0):normalize()
            local flatCar = sm.vec3.new(carFwd.x, carFwd.y, 0):normalize()
            local cross = flatCar:cross(flatTrack) -- Z component tells us Left/Right error
            hdgErr = math.deg(math.asin(math.max(math.min(cross.z, 1), -1)))
        end

        -- 2. STEERING LAG (Are the wheels obeying?)
        local actualWheelAngle = 0.0
        local bearings = sm.interactable.getBearings(self.Driver.interactable)
        if #bearings > 0 then
            -- Convert Bearing Angle (Rad) to Steer Factor (-1 to 1)
            -- Assumes MAX_WHEEL_ANGLE_RAD is 0.8
            actualWheelAngle = bearings[1]:getAngle() / 0.8 
        end
        local steerLag = controls.steer - actualWheelAngle

        -- 3. LOOKAHEAD DISTANCE (Did stability logic push it out?)
        local lookaheadDist = 0.0
        if self.latestDebugData and self.latestDebugData.targetPoint then
             lookaheadDist = (self.latestDebugData.targetPoint - tm.location):length()
        end

        -- 4. FORMAT STRING
        -- [Mode] | Spd: Curr/Tgt | Steer: Cmd(Lag) | Err: Lat/Hdg | Aim: Dist
        local modeStr = self.currentMode or "Race"
        if self.isCornering then modeStr = "Corn" .. tostring(self.cornerPhase) end

        local logString = string.format(
            "[%-6s] Spd:%02.0f/%02.0f | Str:%+.2f(Lag%+.2f) | Err:Lat%+.1f/Hdg%+.0f | Aim:%02.1fm",
            modeStr,
            spd,
            targetSpeedForLog,
            controls.steer,
            steerLag,
            nav.trackPositionBias or 0.0, -- "Lat" is bias (-1 to 1) here
            hdgErr,
            lookaheadDist
        )
        print(logString)
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