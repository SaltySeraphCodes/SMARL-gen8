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

    local centeringAngle = preferredBias * 55.0 

    for i = 1, NUM_RAYS do
        local angle = startAngle + (i - 1) * sectorStep
        rayAngles[i] = angle
        dangerMap[i] = 0.0
        
        local diff = math.abs(angle - centeringAngle)
        local sigma = 20.0 
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
                local carWidthDeg = math.deg(math.atan2(2.5, racer.distance)) * 2.5 
                
                for i = 1, NUM_RAYS do
                    local diff = math.abs(rayAngles[i] - oppAngle)
                    if diff < carWidthDeg then
                        local severity = 1.0 - (racer.distance / LOOKAHEAD_RANGE)
                        dangerMap[i] = math.max(dangerMap[i], severity * 1.5) 
                    end
                end
            end
        end
    end

    if wall then
        local avoidanceMargin = WALL_AVOID_DIST 
        
        local ignoreLeft = false
        local ignoreRight = false

        if self.isCornering then
            if self.cornerDirection == 1 then
                ignoreLeft = true 
            elseif self.cornerDirection == -1 then
                ignoreRight = true 
            end
        end

        if wall.marginLeft < avoidanceMargin and not ignoreLeft then
            local urgency = 1.0 - (math.max(wall.marginLeft, 0) / avoidanceMargin)
            local cutoff = -90.0 + (urgency * 105.0) 
            for i = 1, NUM_RAYS do
                if rayAngles[i] < cutoff then dangerMap[i] = math.max(dangerMap[i], urgency) end
            end
        end

        if wall.marginRight < avoidanceMargin and not ignoreRight then
            local urgency = 1.0 - (math.max(wall.marginRight, 0) / avoidanceMargin)
            local cutoff = 90.0 - (urgency * 105.0)
            for i = 1, NUM_RAYS do
                if rayAngles[i] > cutoff then dangerMap[i] = math.max(dangerMap[i], urgency) end
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
    local wall = perceptionData.WallAvoidance or {marginLeft=99, marginRight=99}
    local radius = self.smoothedRadius or 1000.0
    local curveDir = nav.longCurveDirection or 0 
    local carSpeed = perceptionData.Telemetry.speed or 0
    
    -- [NEW] Calculate Apex Position Logic
    local apexPos = self.cachedApex or nav.centerlineTarget
    local carPos = perceptionData.Telemetry.location
    local toApex = apexPos - carPos
    local distToApex = toApex:length()
    local carForward = perceptionData.Telemetry.rotations.at

    -- [[ TRIGGER LOGIC ]]
    -- We only enter complex cornering strategy if:
    -- 1. The turn is actually tight (Radius < 55, down from 75)
    -- 2. We are approaching it (Distance < 60)
    -- 3. We are going fast enough that we actually NEED to optimize (Speed > 15)
    if self.isCornering == false then
        if radius < 55.0 and distToApex < 60.0 and carSpeed > 15.0 then
             self.isCornering = true
             self.cornerDirection = curveDir 
             self.activeApexLocation = apexPos 
             self.cornerPhase = 1 -- Start at Entry
        end
    end
    
    if self.isCornering == true then
        self.currentMode = "Cornering" 
        
        -- Use the LOCKED apex if available to prevent jitter
        local targetApex = self.activeApexLocation or apexPos
        local toApexLocked = targetApex - carPos
        local distToApexLocked = toApexLocked:length()
        local isBehind = toApexLocked:dot(carForward) < -5.0 -- 5m margin behind car
        
        -- PHASE 1: ENTRY (Swing Out)
        if self.cornerPhase == 1 then
            local idealBias = self.cornerDirection * 0.7 -- 0.7 is safer than 0.85 (less wall hugging)
            
            -- Safety: If wall is close, cancel the swing out
            if self.cornerDirection == 1 and wall.marginRight < 2.5 then idealBias = 0.0 end
            if self.cornerDirection == -1 and wall.marginLeft < 2.5 then idealBias = 0.0 end
            self.targetBias = idealBias
            
            -- [FIX 1: DYNAMIC TURN-IN]
            -- Calculate when to turn based on speed.
            -- "I want to be at the apex in 1.5 seconds"
            -- At 10m/s, switch at 15m. At 40m/s, switch at 60m.
            local lookaheadSeconds = 1.2 
            local dynamicSwitchDist = math.max(15.0, carSpeed * lookaheadSeconds)
            
            if distToApexLocked < dynamicSwitchDist then 
                self.cornerPhase = 2
            end
            
        -- PHASE 2: APEX (Hit Racing Line)
        elseif self.cornerPhase == 2 then
            -- Cut deep into the corner (-1 * dir)
            self.targetBias = -self.cornerDirection * 0.90

            -- [TRANSITION]
            -- If we have physically passed the apex point, release to exit
            if isBehind then
                self.cornerPhase = 3 
            end
            
        -- PHASE 3: EXIT (Release)
        elseif self.cornerPhase == 3 then
            -- Gradually center the car
            local currentPos = nav.trackPositionBias or 0.0
            self.targetBias = currentPos * 0.95 -- Soft decay to center
            
            -- [TRANSITION] 
            -- Exit when track straightens OR we are far past the corner
            if radius >= 60.0 or distToApexLocked > 40.0 then
                self.isCornering = false
                self.cornerPhase = 0
                self.activeApexLocation = nil
                self.currentMode = "RaceLine" 
            end
        end
    end
    
    -- Failsafe: If data gets weird, abort
    if self.isCornering and radius > 150.0 then
        self.isCornering = false
        self.cornerPhase = 0
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

    local idealBias = nav.racingLineBias or 0.0    
    if self.isCornering then
        idealBias = self.targetBias
    elseif currentMode == "Drafting" then
        if opp.draftingTarget then
            idealBias = opp.draftingTarget.opponentBias
        end
    elseif currentMode == "Yield" then
        idealBias = self:getYieldBias(perceptionData)
    elseif currentMode == "DefendLine" then
        if nav.longCurveDirection ~= 0 then 
            idealBias = nav.longCurveDirection * DEFENSE_BIAS_FACTOR 
        else
            idealBias = DEFENSE_BIAS_FACTOR * self.Driver.carAggression * getSign(nav.trackPositionBias or 0.01)
        end
    end

    -- Wall Recovery
    local currentPosBias = nav.trackPositionBias or 0.0
    if math.abs(currentPosBias) > 0.95 then
        if currentPosBias > 0 then idealBias = 0.5 end 
        if currentPosBias < 0 then idealBias = -0.5 end 
    end

    local isWallDanger = (wall.isLeftCritical or wall.isRightCritical or wall.isForwardLeftCritical or wall.isForwardRightCritical)
    local isOpponentDanger = (opp.count > 0)
    
    local runContext = isWallDanger or isOpponentDanger or currentMode == "OvertakeDynamic"

    if runContext or VISUALIZE_RAYS then
        local safeBias, debugData = self:calculateContextBias(perceptionData, idealBias)
        self.latestDebugData = debugData
        
        if self.isCornering then
             if math.abs(safeBias - idealBias) > 0.1 then
                 return safeBias
             else
                 return idealBias
             end
        end

        if runContext then
            if not self.isCornering then self.currentMode = "Context" end
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

function DecisionModule.determineStrategy(self,perceptionData, dt)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local telemetry = perceptionData.Telemetry
    local wall = perceptionData.WallAvoidance 
    local aggressionFactor = self.Driver.carAggression
    
    if self.isCornering then
        self:handleCorneringStrategy(perceptionData, dt)
        return
    end

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
    
    if opp.draftingTarget and telemetry.speed > 30 and isStraight and aggressionFactor >= 0.3 then 
        if opp.draftingTarget.distance > PASSING_DISTANCE_LIMIT then
            self.currentMode = "Drafting"
            return 
        end
    end

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


function DecisionModule.calculateSteering(self, perceptionData, dt)
    local nav = perceptionData.Navigation
    local telemetry = perceptionData.Telemetry

    -- 1. GET RAW BIAS
    local targetBias = self:getFinalTargetBias(perceptionData)
    targetBias = math.min(math.max(targetBias, -0.9), 0.9)

    -- [[ FIX 2: BIAS SMOOTHING ]]
    -- Instead of snapping instantly, move towards the target bias.
    -- This prevents the "Flash" when the logic switches from Straight -> Entry.
    if not self.smoothedBias then self.smoothedBias = targetBias end
    
    -- Speed of transition: 
    -- 5.0 * dt means we can move from Center (0) to Edge (1) in ~0.2 seconds.
    -- Fast enough to corner, slow enough to stop the flicker.
    local biasSpeed = 5.0 * dt
    local diff = targetBias - self.smoothedBias
    
    -- Move smoothedBias towards targetBias by biasSpeed
    if math.abs(diff) < biasSpeed then
        self.smoothedBias = targetBias
    elseif diff > 0 then
        self.smoothedBias = self.smoothedBias + biasSpeed
    else
        self.smoothedBias = self.smoothedBias - biasSpeed
    end

    -- USE THE SMOOTHED BIAS FOR CALCULATIONS
    local safeBias = self.smoothedBias
    safeBias = math.min(math.max(safeBias, -0.9), 0.9)
    self.smoothedBias = safeBias 

    -- 2. INITIAL TARGET (Close range fallback)
    local centerTarget = nav.centerlineTarget 
    if not centerTarget then return 0.0 end
    
    -- We reconstruct the "Ideal" point based on the bias
    local node = nav.closestPointData.baseNode
    local halfWidth = (node.width or 20.0) / 2.0
    local perp = node.perp or self.Driver.shape:getRight() 
    
    -- NOTE: In close range, we assume centerTarget is roughly correct or we use the bias offset
    -- But for stability, we rely mostly on the Lookahead below.
    local offsetVector = perp:normalize() * (safeBias * halfWidth * -1)
    local targetPoint = centerTarget + offsetVector

    -- 3. STABILIZED LOOKAHEAD (Corrected for Racing Line vs Center)
    local carPos = telemetry.location
    local vecToTarget = targetPoint - carPos
    local lookaheadDist = vecToTarget:length()
    
    -- Dynamic Stability Floor: 12m + (Speed * 0.4)
    -- Speed 50 = ~32m lookahead
    local minStabilityDist = 12.0 + (telemetry.speed * 0.4) 
    local futureCenter, futureNode, usePerp = nil, nil, nil
    if lookaheadDist < minStabilityDist then
        local pModule = self.Driver.Perception
        if pModule and nav.closestPointData then
            local startNode = nav.closestPointData.baseNode
            local startT = nav.closestPointData.tOnSegment
            
            -- [[ KEY FIX ]]
            -- We walk the chain using 'mid' to find the GEOMETRIC CENTER ahead.
            local futureCenter, futureNode = self:getFutureCenterPoint(startNode, startT, minStabilityDist, pModule.chain)
            
            local trackDir = futureNode.outVector -- Best case: Node knows its direction
            
            if not trackDir then
                -- Fallback: Look at the NEXT node to find the true track path
                -- Use global helper 'getNextItem'
                local nextNode = getNextItem(pModule.chain, futureNode.id, 1)
                if nextNode then
                    trackDir = (nextNode.mid - futureNode.mid):normalize()
                else
                    -- End of track? Use current node's incoming direction
                    trackDir = (futureNode.mid - startNode.mid):normalize() 
                end
            end
            
            -- Fallback: If node data is missing perp, assume Up is Z and Cross with OutVector
            local nodeUp = futureNode.upVector or sm.vec3.new(0,0,1)
            usePerp = trackDir:cross(nodeUp):normalize() * -1 -- Flip to match Left=-1 standard
            
            -- Fallback if the cross product failed (e.g. vertical track)
            if usePerp:length() < 0.1 then usePerp = sm.vec3.new(1,0,0) end
            
            -- Apply Bias at the future point
            local futureHalfWidth = (futureNode.width or 20.0) / 2.0
            local futureOffset = usePerp * (safeBias * futureHalfWidth * -1)
            
            targetPoint = futureCenter + futureOffset
            
            vecToTarget = targetPoint - carPos
            lookaheadDist = minStabilityDist
        end
    end

    -- [[ DEBUG EXPORT ]]
    self.latestDebugData = self.latestDebugData or {}
    self.latestDebugData.targetPoint = targetPoint 

    -- Capture the internal variables from the "Stabilized Lookahead" block
    -- Note: You need to make sure 'futureCenter' and 'usePerp' are defined in the scope 
    -- outside the 'if lookaheadDist < minStabilityDist' block, or capture them inside.
    
    -- (If we used the lookahead logic)
    if futureCenter then 
        self.latestDebugData.futureCenter = futureCenter
        self.latestDebugData.usedPerp = usePerp -- The vector we used to calculate offset
    else
        -- (If we used close logic)
        self.latestDebugData.futureCenter = centerTarget
        self.latestDebugData.usedPerp = perp
    end

    -- 4. PURE PURSUIT LOGIC
    local carRight = telemetry.rotations.right
    local localY = vecToTarget:dot(carRight)
    
    self.dbg_PP_Y = localY
    
    -- Curvature = 2 * y / L^2
    local curvature = (2.0 * localY) / (lookaheadDist * lookaheadDist)
    local wheelBase = 3.0 
    local targetSteerAngle = math.atan(curvature * wheelBase)
    
    -- Output & Damping
    local steerOutput = targetSteerAngle / MAX_WHEEL_ANGLE_RAD
    local yawRate = telemetry.angularVelocity:dot(telemetry.rotations.up)
    local damping = yawRate * (self.STEERING_Kd_BASE or 0.5)
    
    return math.max(math.min(steerOutput - damping, 1.0), -1.0)
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

function DecisionModule.server_onFixedUpdate_old2(self,perceptionData,dt)
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

    local tick = sm.game.getServerTick()
    if spd > 1.0 and tick % 4 == 0 then 
        
        -- 1. Get Physical Wheel Angle
        local actualWheelAngle = 0.0
        local bearings = sm.interactable.getBearings(self.Driver.interactable)
        if #bearings > 0 then
            -- Get angle in radians, convert to "Steer Factor" (-1 to 1)
            -- Assumes MAX_WHEEL_ANGLE_RAD is 0.8 as defined at top of DecisionModule
            actualWheelAngle = bearings[1]:getAngle() / 0.8 
        end

        local nav = perceptionData.Navigation
        local tm = perceptionData.Telemetry
        
        -- Lateral Position
        local latMeters = nav.lateralMeters or 0.0
        
        -- Aim Angle
        local ppY = self.dbg_PP_Y or 0
        local ppDist = self.dbg_PP_Dist or 1
        local aimAngle = math.deg(math.atan(ppY / ppDist))
        
        -- Format String
        -- Added "W": Actual Wheel Factor
        local logString = string.format(
            "Lat: %+.1f | Aim: %+.0f° | Steer: Cmd %+.2f vs Act %+.2f | Lag: %+.2f",
            latMeters,
            aimAngle,
            controls.steer,
            actualWheelAngle,
            controls.steer - actualWheelAngle
        )
        print(logString)
    end

    self.controls = controls
    return controls
end

function DecisionModule.server_onFixedUpdate_old(self,perceptionData,dt)
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

    -- [[ NEW DEBUG LOGGING ]]
    local tick = sm.game.getServerTick()
    if spd > 1.0 and tick % 4 == 0 then 
        
        -- 1. Gather Data
        local nav = perceptionData.Navigation
        local tm = perceptionData.Telemetry
        
        -- Lateral Position (Center is 0)
        local latMeters = nav.lateralMeters or 0.0
        local trkWidth = nav.trackWidth or 20.0
        
        -- Heading Error (Angle between Car Forward and Track Forward)
        local errAngle = 0.0
        if nav.closestPointData and nav.closestPointData.baseNode then
            local trackFwd = nav.closestPointData.baseNode.outVector
            local carFwd = tm.rotations.at
            -- Get signed angle (roughly)
            local cross = carFwd:cross(trackFwd)
            local dot = carFwd:dot(trackFwd)
            local angleRad = math.atan2(cross.z, dot)
            errAngle = math.deg(angleRad) -- Positive means car is pointing LEFT of track
        end
        
        -- Aim Angle (Where the steering WANTS to go)
        local ppY = self.dbg_PP_Y or 0
        local ppDist = self.dbg_PP_Dist or 1
        local aimAngle = math.deg(math.atan(ppY / ppDist))
        
        -- 2. Format String
        -- [Mode] Segment | Spd: Curr/Tgt | Pos: Lat (Width) | Aim: Dist (Ang) | In: T/B/S | Err: HdgErr
        local logString = string.format(
            "[%s] %s | Spd: %02.0f/%02.0f | Lat: %+.1f (W:%.0f) | Aim: %.1fm (%+.0f°) | In: T%.1f B%.1f S%+.2f | Err: %+.0f°",
            self.currentMode or "Race",
            (self.isCornering and ("Corn"..self.cornerPhase)) or "Str",
            spd,
            targetSpeedForLog,
            latMeters,
            trkWidth,
            ppDist,
            aimAngle,
            controls.throttle,
            controls.brake,
            controls.steer,
            errAngle
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