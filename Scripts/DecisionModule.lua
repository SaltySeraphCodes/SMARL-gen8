dofile("globals.lua") 
DecisionModule = class(nil)

-- [[ TUNING - PHYSICS ]]
local MAX_TILT_RAD = 1.047 
local STUCK_SPEED_THRESHOLD = 0.5 
local STUCK_TIME_LIMIT = 6.0
local BASE_MAX_SPEED = 1200 
local MIN_CORNER_SPEED = 20
local GRIP_FACTOR = 1.2            
local MIN_RADIUS_FOR_MAX_SPEED = 100 

-- [[ TUNING - STEERING PID ]]
local MAX_WHEEL_ANGLE_RAD = 0.65 
local DEFAULT_STEERING_Kp = 0.10 
local DEFAULT_STEERING_Kd = 0.40 -- Increase damping. Resist the swing  
local LATERAL_Kp = 1.0            
local Kp_MIN_FACTOR = 0.35     
local Kd_BOOST_FACTOR = 1.2    

local STEERING_SLEW_RATE = 15 -- radians per second allowed for wheel to turn

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
local SAFETY_WEIGHT = 6      -- WAS 10.0. Set to 0.0 to disable Wall Avoidance override.
local INTEREST_WEIGHT = 2.0    
local WALL_AVOID_DIST = 2.5    
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
    
    -- [[ NEW: ARTIFICIAL DOWNFORCE ]]
    -- Read from Telemetry (from Perception blocks)
    local telem = self.Driver.perceptionData and self.Driver.perceptionData.Telemetry
    if telem and telem.downforce then
        -- Assume 1 Power Level = 1% Grip Boost? Or more?
        -- Thrusters usually give Impulse. 
        -- Let's say max thruster power (1000?) gives +0.5 Grip.
        downforceBoost = downforceBoost + (telem.downforce / 2000.0)
    end
    
    baseGrip = baseGrip + downforceBoost

    -- 2. APPLY LEARNED PHYSICS
    -- If the optimizer found the car is naturally grippier (on fresh tires), use that.
    if self.Driver.Optimizer and self.Driver.Optimizer.learnedGrip then
        local learned = self.Driver.Optimizer.learnedGrip
        -- Trust the learned profile 60%, base physics 40%
        baseGrip = (baseGrip * 0.4) + (learned * 0.6)
    end

    -- 3. APPLY SIMULATED TIRE FACTORS (Type & Wear & Temp)
    local tireTypeData = TIRE_TYPES[car.Tire_Type] or { GRIP = 0.5 }
    local typeMultiplier = tireTypeData.GRIP
    
    -- Wear Penalty: 0% wear = 0 penalty. 100% wear = 0.2 penalty.
    local currentHealth = car.Tire_Health or 1.0
    local wearPenalty = (1.0 - currentHealth) * 0.2 
    
    -- [[ NEW: TEMP PENALTY ]]
    local temp = car.Tire_Temp or 20.0
    local tempPenalty = 0.0
    if temp < 50.0 then 
        -- Cold Tires: up to 10% loss
        tempPenalty = (50.0 - temp) * 0.002 
    elseif temp > 120.0 then
        -- Overheated: up to 20% loss
        tempPenalty = (temp - 120.0) * 0.004
    end
    
    -- Final Grip = Baseline * (Type - Wear - Temp)
    self.dynamicGripFactor = baseGrip * (typeMultiplier - wearPenalty - tempPenalty)
    
    -- 4. SPEED LIMITS & MASS
    local gearRatio = car.gear_length or 1.0 
    
    -- Fuel Mass Penalty (Acceleration is handled by Torque in Engine, but Max Speed might suffer due to drag/friction)
    local fuel = car.Fuel_Level or 1.0
    -- Heavier car = slightly lower top speed due to tire friction? 
    -- Let's apply a 5% speed penalty for full tank.
    local massPenalty = fuel * 0.05
    
    self.dynamicMaxSpeed = BASE_MAX_SPEED * gearRatio * 0.5 * (1.0 - massPenalty)
    
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
         self.cachedMinRadius, self.cachedDist, self.cachedApex, self.cachedTurnDir = self.Driver.Perception:scanTrackCurvature(SCAN_DISTANCE)
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
    
    -- [[ FIX: INSIDE LINE PENALTY ]]
    -- If we are entering on the "Inside", reduce effective radius.
    -- Inside = TurnDirection * TrackBias > 0.
    local turnDir = self.cachedTurnDir or 0
    local myBias = perceptionData.Navigation.trackPositionBias or 0
    local insideFactor = turnDir * myBias 
    
    if insideFactor > 0.1 then
        -- Penalty maxes at 30% reduction for hugs
        local penalty = math.min(insideFactor * 0.3, 0.4) 
        effectiveRadius = effectiveRadius * (1.0 - penalty)
    end

    -- 1. PHYSICS SETUP
    local friction = self.dynamicGripFactor or 0.8
    -- Conservative Factor: Treat the corner as 10% tighter than it looks
    local safetyRadius = math.max(effectiveRadius * 0.9, 10.0)

    -- 2. CALCULATE MAX CORNERING SPEED (v^2/r = u*g)
    local lateralGrip = 18.0 
    if self.Driver.Optimizer then
        -- Scale the optimizer's cornerLimit (usually 1.0-3.5) to G-force units
        -- [[ FIX: USE LEARNED GRIP WITH MARGIN ]]
        -- Use the lesser of our Safety Limit (cornerLimit) or our Actual Grip (learnedGrip)
        -- Apply 0.80 factor (Was 0.90) for significant margin.
        local effectiveGrip = math.min(self.Driver.Optimizer.cornerLimit, self.Driver.Optimizer.learnedGrip * 0.80)
        lateralGrip = effectiveGrip * 10.0 
    end
    -- note: friction is redundant if we assume learnedGrip accounts for surface, but we keep it for now.
    -- If using learnedGrip, friction should be 1.0 since learning includes surface.
    -- Let's dampen the impact of dynamicGripFactor if we trust learnedGrip.
    local friction = self.dynamicGripFactor or 1.0 
    
    local maxCornerSpeed = math.sqrt(safetyRadius * friction * lateralGrip)
    
    -- Clamp limits
    maxCornerSpeed = math.max(maxCornerSpeed, MIN_CORNER_SPEED)
    maxCornerSpeed = math.min(maxCornerSpeed, self.dynamicMaxSpeed)
    
    -- 3. BRAKING DISTANCE CALCULATION (Kinematics)
    local brakingForce = (self.Driver.Optimizer and self.Driver.Optimizer.brakingFactor) or self.brakingForceConstant
    
    -- [CRITICAL FIX] Reaction Time Buffer
    -- Subtract the distance we will cover while the brakes are physically engaging (approx 0.2s)
    -- If we are moving 40 m/s, we lose 8 meters here. This prevents overshoot.
    local latencyMeters = currentSpeed * 0.25 -- [FIX] Increased buffer to 0.25s (Human reaction time)
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
            local rawUrgency = 1.0 - (math.max(wall.marginLeft, 0) / avoidanceMargin)
            local urgency = rawUrgency * rawUrgency
             for i = 1, NUM_RAYS do
                 if rayAngles[i] < 0 then dangerMap[i] = math.max(dangerMap[i], urgency) end
             end
         end
         if wall.marginRight < avoidanceMargin then
            -- 50% distance = 25% urgency. 10% distance = 81% urgency.
            local rawUrgency = 1.0 - (math.max(wall.marginRight, 0) / avoidanceMargin) -- [FIX] Use RIGHT margin
            local urgency = rawUrgency * rawUrgency
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
        local score = (interestMap[i] * INTEREST_WEIGHT) - (dangerMap[i] * SAFETY_WEIGHT)
        
        if score > bestScore then
            bestScore = score
            bestIndex = i
        end
    end

    -- Return Bias (-1 to 1) and Debug Data
    local debugData = nil
    -- [[ CHANGED: Added TELEMETRY_DEBUG check ]]
    if VISUALIZE_RAYS or TELEMETRY_DEBUG then
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
    
    -- [[ NEW: TELEMETRY DEBUG MODE ]]
    -- Show Velocity Vector (Green) vs Facing Vector (Blue) to visualize Slip Angle
    if TELEMETRY_DEBUG then
         local velocity = tm.velocity or sm.vec3.new(0,0,0)
         local speed = velocity:length()
         if speed > 1.0 then
             local velDir = velocity:normalize()
             table.insert(lines, { s = centerPos + (up * 2), e = centerPos + (up * 2) + (velDir * 5), c = 3 }) -- Green Arrow (Velocity)
             table.insert(lines, { s = centerPos + (up * 2), e = centerPos + (up * 2) + (fwd * 5), c = 1 }) -- Blue Arrow (Heading)
         end
    end

    if VISUALIZE_RAYS then
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
    end
    return lines
end

function DecisionModule:handleCorneringStrategy(perceptionData, dt)
    local nav = perceptionData.Navigation
    local speed = perceptionData.Telemetry.speed
    
    -- Reset default (No setup needed)
    self.cornerSetupBias = 0.0
    self.cornerSetupWeight = 0.0
    
    -- 1. ACTIVE CORNERING (Already in the turn)
    -- If we are in the turn, we shouldn't be "setting up". We should be hitting the apex.
    if nav.roadCurvatureRadius < 150.0 then
        -- We let the Pure Pursuit / Apex logic handle the turn itself.
        -- Just return, resetting the setup bias.
        return 
    end
    
    -- 2. SETUP PHASE (Approaching a turn)
    -- We use Time-To-Corner instead of Distance. 
    -- 4.0 seconds allows a smooth lane change at high speed.
    local lookaheadTime = 4.0 
    local triggerDist = math.max(40.0, speed * lookaheadTime)
    
    if nav.distToNextCorner < triggerDist and nav.nextCornerDir ~= 0 then
        
        -- A. DIRECTION LOGIC
        -- If Turn is RIGHT (1), we want to be LEFT (-1).
        local setupSide = -nav.nextCornerDir 
        
        -- B. SMOOTH URGENCY
        -- 0.0 = Just detected (Far away)
        -- 1.0 = At the braking zone (Close)
        local rawUrgency = 1.0 - (nav.distToNextCorner / triggerDist)
        
        -- Apply Ease-In Curve (Sine Wave) for smoothness
        -- This makes the car start the lane change gently, then commit.
        local smoothUrgency = math.sin(rawUrgency * (math.pi / 2))
        
        -- C. OUTPUT
        -- We don't want to hug the wall 100% (risk of clipping). Target 85% width.
        self.cornerSetupBias = setupSide * 0.85
        self.cornerSetupWeight = smoothUrgency
    end
end


function DecisionModule.getFinalTargetBias(self, perceptionData)
    local nav = perceptionData.Navigation
    local opp = perceptionData.Opponents
    local wall = perceptionData.WallAvoidance 
    
    -- Ensure Debug Table Exists (Preserve Optimizer Data)
    if not self.latestDebugData then self.latestDebugData = {} end

    -- --- LAYER 1: STRATEGIC INTENT ---
    local idealBias = nav.racingLineBias or 0.0    
    
    if self.currentMode == "Formation" or self.currentMode == "Caution" then
        local b, _ = self:getStructuredModeTargets(perceptionData, self.currentMode)
        idealBias = b
    elseif self.currentMode == "Drafting" and opp.draftingTarget then
        idealBias = opp.draftingTarget.opponentBias
    elseif self.currentMode == "Yield" then
        idealBias = self:getYieldBias(perceptionData)
    elseif self.currentMode == "DefendLine" then
         local mySide = getSign(nav.trackPositionBias or 0.0)
         idealBias = mySide * DEFENSE_BIAS_FACTOR 
    elseif self.currentMode == "OvertakeDynamic" and self.dynamicOvertakeBias then
         idealBias = self.dynamicOvertakeBias
    -- [[ NEW: APPLY CORNER SETUP ]]
    -- If we are in "RaceLine" mode and have a setup strategy active
    elseif self.currentMode == "RaceLine" and self.cornerSetupWeight and self.cornerSetupWeight > 0 then
        -- Blend the Racing Line (usually 0.0) with the Setup Line (e.g. -0.8)
        -- The closer we get to the corner, the more we listen to the Setup.
        idealBias = (idealBias * (1.0 - self.cornerSetupWeight)) + (self.cornerSetupBias * self.cornerSetupWeight)
    end

    -- --- LAYER 2: PHYSICS CONSTRAINTS ---
    if self.isCornering then
        if self.currentMode == "OvertakeDynamic" then
             idealBias = (self.targetBias * 0.8) + (idealBias * 0.2)
        else
             idealBias = self.targetBias 
        end
    end
    
    if self.pitState > 0 then idealBias = 0.0 end

    local wallDist = 1.5 -- Distance to start avoiding (matches WALL_AVOID_DIST)
    local wallCheck = false
    if wall and (wall.marginLeft < wallDist or wall.marginRight < wallDist) then
        wallCheck = true
    end
    local isOpponentDanger = (opp.count > 0 and opp.collisionRisk)
    -- Run calculation if Wall is nearby OR Opponent is risky OR Debug is on
    if wallCheck or isOpponentDanger or VISUALIZE_RAYS then
        local safeBias, debugData = self:calculateContextBias(perceptionData, idealBias)

        if debugData then 
            for k, v in pairs(debugData) do self.latestDebugData[k] = v end
        end

        -- [[ FIX: SMOOTH BLENDING ]]
        -- If wall avoidance disagrees with racing line, blend them instead of snapping.
        if math.abs(safeBias - idealBias) > 0.1 then
             -- If critical danger, assume 100% safe bias. If mild, blend 50%.
             local blend = 0.5
             if isWallDanger then blend = 0.8 end
             
             return (idealBias * (1.0 - blend)) + (safeBias * blend)
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
    
    -- AI Active Check: Don't check for "stuck" if the AI isn't even trying to race
    local isAIActive = self.Driver.active or self.Driver.isRacing or self.Driver.racing or self.Driver.caution or self.Driver.formation or (self.pitState > 0)
    if not isAIActive then
        self.stuckTimer = 0.0
        return false 
    end

    -- Stuck Logic
    local spd = telemetry.speed or 0
    -- Stuck if slow AND Throttle is high (trying to move)
    if spd < 1.0 and self.controls and math.abs(self.controls.throttle) > 0.5 and not self.onLift then 
        self.stuckTimer = self.stuckTimer + dt
    elseif self.isStuck and spd < 5.0 then -- Remain "Stuck" until we get some speed back (reversing)
        -- Keep timer high
        self.stuckTimer = math.max(self.stuckTimer, 2.5)
        
        -- If we have been reversing for 2 seconds (timer > 4.5), give up and reset
        self.stuckTimer = self.stuckTimer + dt
    else
        self.stuckTimer = 0.0 
    end
    
    if self.isStuck then self.Driver.resetPosTimeout = 11.0 end 
    
    if self.stuckTimer >= 2.5 then -- 2.5s threshold
        if not self.isStuck then print("stuck mode active") end
        self.isStuck = true 
    else 
        self.isStuck = false 
    end
    
    -- Hard Reset if stuck for too long (5s)
    if self.stuckTimer >= 6.0 then 
         print("hard reset")
         resetFlag = true 
    end

    if self.isFlipped then 
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
    
    -- [[ NEW: RECOVERY ]]
    if self.isStuck then
        self.currentMode = "Recovery"
        return
    end
    
    -- [[ FIX: RUN SETUP LOGIC ]]
    -- Calculate the corner setup bias every frame.
    -- We do this BEFORE Overtaking logic, because setting up for a corner 
    -- is usually more important than a risky pass unless we are dive-bombing.
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
        
        -- [[ NEW: TTA vs TTC LOGIC ]]
        -- TTA (Time To Avoid): Approx 0.8s to steer clear.
        local TTA_THRESHOLD = 0.8 
        
        if closestOpponent and closestOpponent.isAhead and closestOpponent.distance < 40 then
            
            -- 1. PANIC PREVENTION (TTC Check)
            if closestOpponent.timeToCollision < TTA_THRESHOLD then
                -- Impact is imminent and we can't steer fast enough.
                -- Hard Brake required.
                print(self.Driver.id, "PANIC BRAKE! TTC:", closestOpponent.timeToCollision)
                self.overrideBrake = 1.0
                self.overrideThrottle = 0.0
                return -- ABORT STRATEGY
            end
        
            -- 2. DRAFTING (Standard)
            -- Only if safe (TTC is large)
            if closestOpponent.distance < PASSING_DISTANCE_LIMIT and closestOpponent.distance > 5.0 
               and isStraight and aggressionFactor >= 0.3 and telemetry.speed > 30 
               and closestOpponent.timeToCollision > 2.0 then
                self.currentMode = "Drafting"
            
            -- 3. OVERTAKING
            elseif closestOpponent.distance < PASSING_DISTANCE_LIMIT then
                 -- Stick with the gap if we found one
                 if self.currentMode == "OvertakeDynamic" and closestOpponent.distance < PASSING_EXIT_DISTANCE then
                     local bestBias = self:findBestOvertakeGap(perceptionData)
                     self.dynamicOvertakeBias = bestBias
                 -- Calculate new gap if closing in
                 elseif closestOpponent.closingSpeed > 1.0 then -- Modified for new ClosingSpeed sign (Positive = Closing)
                    local bestBias = self:findBestOvertakeGap(perceptionData)
                    self.currentMode = "OvertakeDynamic"
                    self.dynamicOvertakeBias = bestBias
                 end
            end
        end
        
        -- A. DEFENSE (Behind us)
        if closestOpponent and not closestOpponent.isAhead and closestOpponent.distance < 15 then
             -- Closing speed was inverted in Perception. Now: Positive = closing.
             -- If they are closing on us (Positive Speed)
             if closestOpponent.closingSpeed > 1.0 or aggressionFactor > 0.6 then 
                self.currentMode = "DefendLine"
            end
        end
    end
end

function DecisionModule.calculateSteering(self, perceptionData, dt,isUnstable)
    if not perceptionData or not perceptionData.Navigation then return 0.0 end
    
    if not self.latestDebugData then self.latestDebugData = {} end

    local nav = perceptionData.Navigation
    local telemetry = perceptionData.Telemetry
    local speed = telemetry.speed
    local optim = self.Driver.Optimizer
    
    -- 1. GET GOAL
    local targetBias = self:getFinalTargetBias(perceptionData)
    
    -- 2. GET FUTURE GEOMETRY
    -- 2. GET FUTURE GEOMETRY
    local mult = (optim and optim.lookaheadMult) or 0.65 -- [FIX] Reduced Base (Was 0.8)
    -- [[ FIX: DYNAMIC LOOKAHEAD SCALING ]]
    -- If the turn is tight, shrink the lookahead.
    local radius = nav.roadCurvatureRadius or 1000.0
    local curveFactor = 1.0
    
    if radius < 90.0 then -- [FIX] Increased threshold (Was 60)
        -- Scale down: At 20m radius, use 40% lookahead.
        curveFactor = math.max(0.4, radius / 90.0) 
        mult = mult * curveFactor
    end 
    
    -- STABILITY OVERRIDE:
    if isUnstable then
        mult = mult * 1.5 -- reduced from 2.0 to prevent oscillation
    end
    
    -- Boost lookahead on straights
    local straightBoost = 1.0
    if nav.roadCurvatureRadius > 600.0 then straightBoost = 1.3 end -- Reduced boost
    
    -- [FIX] Lower Min Lookahead to prevent cutting low-speed corners
    local lookaheadDist = math.max(7.0, speed * mult * straightBoost)
    
    local centerPoint, futureNode = self:getFutureCenterPoint(
        nav.closestPointData.baseNode, 
        nav.closestPointData.tOnSegment, 
        lookaheadDist, 
        self.Driver.Perception.chain
    )

    -- 3. CLAMP BIAS (Using Future Width)
    local trackWidth = 20.0
    if futureNode then trackWidth = futureNode.width end
    local halfWidth = trackWidth / 2.0
    
    local safeZone = math.max(1.0, halfWidth - 3.5) 
    local maxBias = safeZone / halfWidth
    
    targetBias = math.max(math.min(targetBias, maxBias), -maxBias)
    
    -- Smooth
    -- Smooth
    local lerpRate = 0.10 -- [FIX] Slower smoothing to reduce target jitters (Was 0.15)
    self.smoothedBias = (self.smoothedBias or 0) * (1.0 - lerpRate) + targetBias * lerpRate
    local finalBias = self.smoothedBias
    
    -- [TELEMETRY] Store for Optimizer
    self.dbg_TargetBias = finalBias
    self.dbg_TrackHalfWidth = halfWidth
    self.dbg_TargetLatMeters = finalBias * halfWidth * -1 -- Convert to meters (Right is positive? Check coordinate system)

    -- 4. CALCULATE TARGET POINT
    local perpDir = nil
    if futureNode and futureNode.perp then
        perpDir = futureNode.perp
    elseif nav.closestPointData.baseNode.perp then
        perpDir = nav.closestPointData.baseNode.perp 
    else
        -- Fallback: Invert Right to get Left
        perpDir = self.Driver.shape:getRight() * -1 
    end
    
    -- [[ LOGIC: SUBTRACT LEFT ]]
    -- Center - (Left * NegativeBias) = Center + Left. Correct.
    local targetPoint = centerPoint - (perpDir * (finalBias * halfWidth))

    -- Debug Data
    self.latestDebugData.targetPoint = targetPoint
    self.latestDebugData.futureCenter = centerPoint
    self.latestDebugData.usedPerp = perpDir
    
    if not self.latestDebugData.statusColor then
        self.latestDebugData.statusColor = sm.color.new(0, 1, 0, 1) 
    end

    -- 5. PURE PURSUIT
    local carPos = telemetry.location
    local vecToTarget = targetPoint - carPos
    
    local localY = vecToTarget:dot(telemetry.rotations.right)
    self.dbg_PP_Y = localY
    local distSq = vecToTarget:length2()
    local curvature = (2.0 * localY) / distSq
    
    -- [[ FIX: ADD INTEGRAL TERM ]]
    -- Helps close small steady-state gaps ("Barely following")
    if not self.steerIntegral then self.steerIntegral = 0.0 end
    
    -- Accumulate error (localY is lateral error in meters)
    -- Only integrate if error is small (< 2m) to avoid windup during lane changes
    if math.abs(localY) < 2.0 then
        self.steerIntegral = self.steerIntegral + (localY * 0.05 * 0.025) -- Ki * dt (Assuming 40hz)
    else
        self.steerIntegral = self.steerIntegral * 0.95 -- Decay if error is large
    end
    -- Clamp I-term
    self.steerIntegral = math.max(math.min(self.steerIntegral, 0.15), -0.15)

    local steerOutput = (curvature * -3.5) - self.steerIntegral -- [FIX] Negative Gain for Stability
    
    -- CLAMP DAMPING: 
    -- Prevent Damping from ever exceeding 80% of the Steering Input.
    -- This ensures the car ALWAYS turns at least a little bit, even if rotating fast.
    local yawRate = 0
    if telemetry.angularVelocity then yawRate = telemetry.angularVelocity:dot(telemetry.rotations.up) end

    local currentKd = (optim and optim.dampingFactor or 0.15)
    local rawDamping = yawRate * currentKd
    -- Logic: If we are steering LEFT (-), and Damping is RIGHT (+), clamp the damping.
    if (steerOutput < 0 and rawDamping > 0) or (steerOutput > 0 and rawDamping < 0) then
        -- Allow STRONGER damping (1.2x) to catch fishtails
        local maxDamp = math.max(0.20, math.abs(steerOutput) * 1.2)        
        if rawDamping > maxDamp then rawDamping = maxDamp end
        if rawDamping < -maxDamp then rawDamping = -maxDamp end
    end

    local rawOutput = steerOutput - rawDamping
    local clampedOutput = math.max(math.min(rawOutput, 1.0), -1.0)

    -- [[ CHANGED: SAVE DEBUG VALUES ]]
    self.latestDebugData.rawP = steerOutput
    self.latestDebugData.rawD = rawDamping
    self.latestDebugData.latErr = nav.lateralMeters or 0
    -- [[ END CHANGE ]]

    --[[Slew Rate
    if self.lastSteerOut then
        -- 6.0 allows full lock in ~0.3 seconds. 
        -- Too low (< 3.0) makes it sluggish in chicanes. Too high (> 10.0) allows jitters.
        local maxChange = 6.0 * dt 
        
        local delta = clampedOutput - self.lastSteerOut
        if delta > maxChange then clampedOutput = self.lastSteerOut + maxChange
        elseif delta < -maxChange then clampedOutput = self.lastSteerOut - maxChange end
    end
    self.lastSteerOut = clampedOutput]]

    return clampedOutput
end


function DecisionModule.calculateSpeedControl(self, perceptionData, steerInput, isUnstable)
    local isAIActive = self.Driver.active or self.Driver.isRacing or self.Driver.racing or self.Driver.caution or self.Driver.formation or (self.pitState > 0)
    if not isAIActive then
        return 0.0, 1.0, 0.0 -- 0 Throttle, 1.0 Brake (Hold), 0 Target Speed
    end

    local currentSpeed = perceptionData.Telemetry.speed
    local targetSpeed = self:getTargetSpeed(perceptionData,steerInput) -- Recalculated here
    
    -- [[ FIX: WRONG WAY RECOVERY ]]
    -- User Request: Slow to stop/crawl if facing backwards or > 80 deg (dot < 0.17)
    local nav = perceptionData.Navigation
    local isWrongWay = false
    
    if nav and nav.closestPointData and nav.closestPointData.baseNode then
        -- Check alignment with path
        local carDir = self.Driver.shape:getAt()
        local pathDir = nav.closestPointData.baseNode.dir -- Assuming node has .dir
        -- Optimization: If node dir missing, use P2 - P1 
        if not pathDir and nav.closestPointData.nextNode then
             pathDir = (nav.closestPointData.nextNode.pos - nav.closestPointData.baseNode.pos):normalize()
        end
        
        if pathDir then
             local dot = carDir:dot(pathDir)
             if dot < 0.2 then -- Angle > 78 degrees
                 isWrongWay = true
                 targetSpeed = 0 -- Force stop
                 -- print(self.Driver.id, "WRONG WAY DETECTED (Spin)! Braking.")
             end
        end
    end
    
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
    else
        throttle = 0.0
        brake = math.min(math.abs(controlSignal), 1.0)
    end
    
    -- Absolute override for spin safety
    if isWrongWay then
        throttle = 0.0
        brake = 1.0
    end
    
    -- [[ NEW: FRICTION BUDGETER (Kamm Circle) ]]
    -- Share the tire's grip between Steering and Braking.
    -- If steering is high, limit the maximum allowed braking force.
    local steerUsage = math.abs(steerInput)
    -- Allow 100% braking if steering is < 20%. 
    -- At 100% steering, limit braking to 10% (trail braking only).
    local brakeLimit = 1.0
    if steerUsage > 0.2 then
        brakeLimit = 1.1 - steerUsage
        brakeLimit = math.max(0.1, math.min(1.0, brakeLimit))
    end
    
    if brake > brakeLimit then brake = brakeLimit end

    -- Corner Entry Braking Assist
    if self.isCornering and self.cornerPhase == 1 and currentSpeed > targetSpeed * 1.05 then
         brake = math.max(brake, self.Driver.carAggression * 0.4)
         -- Re-clamp in case Assist was too aggressive
         if brake > brakeLimit then brake = brakeLimit end
    end
    
    -- RETURN TARGET SPEED FOR LOGGING
    return throttle, brake, targetSpeed
end

function DecisionModule.server_onFixedUpdate(self,perceptionData,dt)
    local controls = {}
    controls.resetCar = self:checkUtility(perceptionData,dt)
    
    if controls.resetCar then
        -- Clear PID State on Reset
        self.integralSpeedError = 0.0
        self.steerIntegral = 0.0
    end

    self:updateTrackState(perceptionData)

    -- [[ 1. STABILITY DETECTION ]]
    local tm = perceptionData.Telemetry
    local isUnstable = false
    local slideSeverity = 0.0
    
    if tm.velocity and tm.speed > 5.0 then
        local velDir = tm.velocity:normalize()
        local sideSlip = math.abs(velDir:dot(tm.rotations.right))
        
        -- [[ FIX 1: LOWER THRESHOLD ]]
        -- WAS: 0.25 (15 degrees). NEW: 0.12 (7 degrees)
        if sideSlip > 0.12 then 
            isUnstable = true 
            slideSeverity = sideSlip
        end
        
        -- [[ FIX 2: COUNTER-STEER DETECTOR ]]
        -- If we are Yawing Left but Steering Right hard, we are fighting a slide.
        -- This detects instability BEFORE the slip angle gets huge.
        local yawRate = 0
        if tm.angularVelocity then yawRate = tm.angularVelocity:dot(tm.rotations.up) end
        
        -- If Yaw and Steer are opposite signs and substantial
        local steerInput = (self.controls and self.controls.steer) or 0
        if (yawRate > 0.5 and steerInput < -0.3) or (yawRate < -0.5 and steerInput > 0.3) then
             isUnstable = true
             slideSeverity = math.max(slideSeverity, 0.5) -- Treat as medium severity
        end
    end

    -- [[ 2. STRATEGY & CONTROLS ]]
    local targetSpeedForLog = 0.0

    if controls.resetCar then
        print(self.Driver.id,"resetting car")
        controls.steer = 0.0; controls.throttle = 0.0; controls.brake = 0.0
    else
        self:determineStrategy(perceptionData, dt) 
        
        -- PASS UNSTABLE FLAG TO STEERING
        controls.steer = self:calculateSteering(perceptionData, dt, isUnstable)
        
        -- PASS UNSTABLE FLAG TO SPEED
        controls.throttle, controls.brake, targetSpeedForLog = self:calculateSpeedControl(perceptionData, controls.steer, isUnstable)
        
        -- [TELEMETRY] Store for Optimizer
        self.currentTargetSpeed = targetSpeedForLog
        
        -- [[ 3. STABILITY ASSIST OVERRIDES ]]
        if isUnstable then
            -- A. THROTTLE CUT: Reduce throttle based on severity
            -- If mild slide (0.25), cut 50%. If hard slide (0.5+), cut 100%.
            local cutFactor = math.max(0, 1.0 - (slideSeverity * 2.0))
            controls.throttle = controls.throttle * cutFactor
            
            -- B. DEBUG VISUALS: Turn RED
            if self.latestDebugData then
                self.latestDebugData.statusColor = sm.color.new(1, 0, 0, 1) -- RED
            end
        end

        -- [[ 3.5 EXTERNAL OVERRIDES (Testing/Calibration) ]]
        if self.overrideThrottle then controls.throttle = self.overrideThrottle end
        if self.overrideBrake then controls.brake = self.overrideBrake end
        if self.overrideSteer then controls.steer = self.overrideSteer end
    end

    -- [[ 4. LOGGING (Existing Code) ]]
    local spd = perceptionData.Telemetry.speed or 0 
    
    if self.lastSpeed then
        local delta = spd - self.lastSpeed
        if delta < -8.0 then 
            print(self.Driver.id, "WALL IMPACT DETECTED! Delta:", delta)
            if self.Driver.Optimizer then self.Driver.Optimizer:reportCrash() end
            
            -- [[ NEW: COLLISION RESET ]]
            -- Clear Integrals to prevent wind-up spin
            self.integralSpeedError = 0.0
            self.steerIntegral = 0.0 -- [FIX] Updated variable name
            self.stuckTimer = 0.0 -- Reset stuck timer to give player a chance
        end
    end
    self.lastSpeed = spd
    
    -- [[ RECOVERY CONTROL OVERRIDE ]]
    if self.currentMode == "Recovery" then
        controls.throttle = -0.8 -- Reverse
        controls.brake = 0.0
        
        -- Invert steering to back out
        -- If we were steering Left, steer Right to back train-style? 
        -- Or steer opposite to trailer-reverse?
        -- Simple: Steer OPPOSITE to where we want to go.
        -- If track is Left, steer Left means front goes Left. Reverse means rear goes Left.
        -- To back OUT of a wall on the left, we want Rear to go Right. Steer Left?
        -- Let's just try INVERTING the last known good steering.
        local nav = perceptionData.Navigation
        local bias = nav.trackPositionBias or 0
        
        -- If on Left side of track (Bias > 0), Steer Left to point tail to Center.
        controls.steer = bias * 1.0 
    end

    local tick = sm.game.getServerTick()
    if spd > 1.0 and tick % 4 == 0 then 
        local nav = perceptionData.Navigation
        local P_Term = (self.latestDebugData and self.latestDebugData.rawP) or 0
        local D_Term = (self.latestDebugData and self.latestDebugData.rawD) or 0
        local LookDist = (self.latestDebugData and self.latestDebugData.targetPoint and (self.latestDebugData.targetPoint - tm.location):length()) or 0

        -- Add "UNSTABLE" tag to log if active
        local modeStr = self.currentMode or "Race"
        if isUnstable then modeStr = "SLIDE" end

        local logString = string.format(
            "[%-6s] Spd:%02.0f | LatErr:%+.1fm | P(Turn):%+.2f | D(Damp):%+.2f | Final:%+.2f | Look:%02.0fm | Slip:%.2f",
            modeStr,
            spd,
            nav.lateralMeters or 0,
            P_Term,
            D_Term,
            controls.steer,
            LookDist,
            slideSeverity
        )
        --print(logString)
    end

    self.controls = controls
    
    -- [[ NEW: EXPOSE INTENT FOR GUIDANCE LAYER ]]
    controls.targetBias = self.smoothedBias or 0.0
    controls.currentMode = self.currentMode or "RaceLine"
    controls.targetSpeed = targetSpeedForLog
    controls.slideSeverity = slideSeverity
    
    -- [[ NEW: HUD METRICS ]]
    -- Mental Load: How "busy" the AI is. 0.0 to 1.0.
    local mentalLoad = 0.1 -- Base load
    
    -- Speed Stress (High speed = higher focus)
    local speedStress = math.min((perceptionData.Telemetry.speed or 0) / 100.0, 1.0) * 0.4
    
    -- Steering Stress (Cornering = higher focus)
    local steerStress = math.abs(controls.steer) * 0.2
    
    -- Opponent Stress (Close battle = higher focus)
    local opponentStress = 0.0
    if perceptionData.Opponents and perceptionData.Opponents.count > 0 then
        local nearest = perceptionData.Opponents.racers[1]
        if nearest and nearest.distance < 15.0 then
            opponentStress = 0.3 * (1.0 - (nearest.distance / 15.0))
        end
    end
    
    -- Slide Stress (Panic)
    local slideStress = slideSeverity * 0.5
    
    mentalLoad = mentalLoad + speedStress + steerStress + opponentStress + slideStress
    mentalLoad = math.min(mentalLoad, 1.0)
    
    -- Grip Usage: How much of the tire's potential is being used.
    -- Estimated Lateral G = Speed * YawRate.
    -- Max G is theoretically ~2.0 to 3.0 depending on tuning.
    local yawRate = 0
    if tm.angularVelocity then yawRate = math.abs(tm.angularVelocity:dot(tm.rotations.up)) end
    local currentLatG = (perceptionData.Telemetry.speed or 0) * yawRate
    local maxLatG = 25.0 -- Approximate limit (2.5G)
    
    local gripUsage = math.min(currentLatG / maxLatG, 1.0)
    
    -- Store on Driver for RaceControl
    if self.Driver then
        self.Driver.mentalLoad = mentalLoad
        self.Driver.gripUsage = gripUsage
    end

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