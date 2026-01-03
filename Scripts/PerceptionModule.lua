-- PerceptionModule.lua (Refactored for Normalized Distance)
dofile("globals.lua") 

PerceptionModule = class(nil)

-- [[ TUNING CONSTANTS ]]
local Z_TOLERANCE_SQ = 25        
local LOOKAHEAD_DISTANCE_1 = 12.0 
local LOOKAHEAD_DISTANCE_2 = 45.0  
local MAX_CURVATURE_RADIUS = 1000.0 
local LONG_LOOKAHEAD_DISTANCE = 80.0
local LANE_SLOT_WIDTH = 0.33 
local MIN_DRAFTING_DIST = 30.0 
local MAX_DRAFTING_ANGLE = 0.9 
local CAR_WIDTH_BIAS = 0.2 
local CRITICAL_WALL_MARGIN = 0.5 

function PerceptionModule.server_init(self, driver)
    self.Driver = driver
    
    -- [OPTIMIZATION] Scan static dimensions once at startup
    if self.Driver.body then
        self.Driver.carDimensions = self:scanCarDimensions()
        
        -- NEW: Use the actual scanned distance to the side
        local leftDist = self.Driver.carDimensions.left:length()
        local rightDist = self.Driver.carDimensions.right:length()
        
        -- Use the wider side (in case of asymmetry) and add a small safety buffer
        self.carHalfWidth = math.max(leftDist, rightDist) + 0.2
        local aabb_min, aabb_max = self.Driver.body:getWorldAabb()
        local dimensions = aabb_max - aabb_min
        self.bbDimensions = dimensions
    else
        self.carHalfWidth = 1.5 
    end
    
    self.perceptionData = {
        ["Telemetry"] = nil, 
        ["Navigation"] = nil, 
        ["Opponents"] = nil,
        ["WallAvoidance"] = nil
    }
    self.chain = nil 
    self.currentNode = nil 
end

function PerceptionModule.scanCarDimensions(self)
    local body = self.Driver.shape:getBody()
    if not body then return nil end 

    local shapes = body:getCreationShapes()
    local origin = self.Driver.shape:getWorldPosition()
    local at = self.Driver.shape:getAt()
    local right = self.Driver.shape:getRight()
    
    return {
        front = getDirectionOffset(shapes, at, origin),
        rear = getDirectionOffset(shapes, at * -1, origin),
        left = getDirectionOffset(shapes, right * -1, origin),
        right = getDirectionOffset(shapes, right, origin)
    }
end

-- [[ CORE TRACKING ]]

function PerceptionModule:findClosestNodeFallback(chain, carLocation)
    if not chain or #chain == 0 then return nil end
    local minDistanceSq = math.huge
    local closestNode = nil
    
    -- Optimized Global Search with Height Check
    for i = 1, #chain do 
        local node = chain[i]
        local zDiffSq = (carLocation.z - node.location.z)^2
        if zDiffSq <= Z_TOLERANCE_SQ then
            local nDistanceSq = (carLocation - node.location):length2() 
            if nDistanceSq < minDistanceSq then
                closestNode = node
                minDistanceSq = nDistanceSq
            end
        end
    end
    return closestNode
end

function PerceptionModule.findClosestPointOnTrack(self, location, chain, allowFallback)
    -- Default to true if not provided
    if allowFallback == nil then allowFallback = true end
    
    local telemetry = self.perceptionData.Telemetry or {}
    local carLocation = location or telemetry.location or self.Driver.body:getWorldPosition()
    
    -- 1. Try Local Search first
    local segmentStartNode = self.currentNode
    local fallbackNeeded = (segmentStartNode == nil)
    local closestPoint = nil
    local bestDistanceSq = math.huge
    
    if not fallbackNeeded then
        -- Search -5 to +5 nodes relative to current memory
        for i = -5, 5 do 
            local node1 = getNextItem(chain, segmentStartNode.id, i)
            local node2 = getNextItem(chain, node1.id, 1) 
            if not node1 or not node2 then break end
            
            local segmentVector = node2.location - node1.location
            local carVector = carLocation - node1.location
            local segmentLengthSq = segmentVector:length2()
            
            local t = 0
            if segmentLengthSq > 0.001 then
                t = carVector:dot(segmentVector) / segmentLengthSq
            end
            local clamped_t = math.max(0, math.min(1, t))
            
            local pointOnSegment = node1.location + segmentVector * clamped_t
            local distanceSq = (carLocation - pointOnSegment):length2()
            
            if distanceSq < bestDistanceSq then
                bestDistanceSq = distanceSq
                closestPoint = {
                    point = pointOnSegment,
                    baseNode = node1, 
                    segmentID = node1.id, 
                    tOnSegment = clamped_t
                }
            end
        end
        
        -- Detect Tracking Loss (>25m error)
        if bestDistanceSq > 625.0 then fallbackNeeded = true end
    end
    
    -- 2. Global Fallback Search
    -- [[ FIX: Only run if allowFallback is TRUE ]]
    if fallbackNeeded and allowFallback then
        local globalNode = self:findClosestNodeFallback(chain, carLocation)
        if globalNode then
             self.currentNode = globalNode
             -- [[ FIX: RECURSE WITH FALLBACK DISABLED ]]
             return self:findClosestPointOnTrack(location, chain, false) 
        end
    end
    
    -- 3. Update Memory
    if closestPoint and not location then
        self.currentNode = closestPoint.baseNode
        if self.Driver then self.Driver.lastPassedNode = closestPoint.baseNode end
    end
    
    return closestPoint
end

-- [[ CLEANUP: Use this single version of getPointInDistance ]]
-- (You had two definitions in your file; delete the other one)
function PerceptionModule:getPointInDistance(baseNode, start_t, distance, chain)
    local remainingDistance = distance
    local currentNode = baseNode
    if not currentNode or distance <= 0 then return baseNode.location end
    
    local nodeDitsTimeout = 0
    -- Safety Limit
    while remainingDistance > 0 and nodeDitsTimeout < 100 do
        local nextNode = getNextItem(chain, currentNode.id, 1)
        if not nextNode then return currentNode.location end 
        
        local segmentVector = nextNode.location - currentNode.location
        local segmentLength = segmentVector:length()
        
        -- Adjust for start_t on first iteration
        local effectiveLength = segmentLength
        if nodeDitsTimeout == 0 then effectiveLength = segmentLength * (1.0 - start_t) end
        
        if effectiveLength >= remainingDistance then
            local target_t = (nodeDitsTimeout == 0) and (start_t + (remainingDistance / segmentLength)) or (remainingDistance / segmentLength)
            return currentNode.location + segmentVector * target_t
        else
            remainingDistance = remainingDistance - effectiveLength
            currentNode = nextNode
            start_t = 0 -- Reset t for subsequent nodes
            nodeDitsTimeout = nodeDitsTimeout + 1
        end
    end
    return currentNode.location 
end


function PerceptionModule.get_artificial_downforce(self) 
    local totalDownforce = 0 
    local parents = self.Driver.interactable:getParents() 
    if #parents > 0 then
        for k=1, #parents do local v=parents[k]
            if tostring(v:getShape():getShapeUuid()) == DOWNFORCE_BLOCK_UUID then 
                totalDownforce = v:getPower()
            end
        end 
    end
    return totalDownforce
end


function PerceptionModule:calculateCurvatureRadius(pA, pB, pC)
    local v1 = pB - pA
    local v2 = pC - pB
    local v3 = pC - pA
    
    local length1 = v1:length()
    local length2 = v2:length()
    local length3 = v3:length()
    
    local s = (length1 + length2 + length3) / 2
    local areaSq = s * (s - length1) * (s - length2) * (s - length3)
    
    if areaSq <= 0 then return MAX_CURVATURE_RADIUS end
    local area = math.sqrt(areaSq)
    local radius = (length1 * length2 * length3) / (4 * area)
    
    return math.min(radius, MAX_CURVATURE_RADIUS)
end


function PerceptionModule:scanTrackCurvature(scanDistance)
    local nav = self.perceptionData.Navigation
    if not nav or not nav.closestPointData then 
        return MAX_CURVATURE_RADIUS, 0.0, nil 
    end

    local currentNode = nav.closestPointData.baseNode
    local currentT = nav.closestPointData.tOnSegment
    
    local minSustainedRadius = MAX_CURVATURE_RADIUS
    local distToApex = 0.0
    local apexLocation = nil 
    
    local currentDist = 5.0 
    local scanStep = 5.0 
    
    while currentDist < scanDistance do
        local pA = self:getPointInDistance(currentNode, currentT, currentDist - 5.0, self.chain)
        local pB = self:getPointInDistance(currentNode, currentT, currentDist, self.chain)
        local pC = self:getPointInDistance(currentNode, currentT, currentDist + 5.0, self.chain)
        local radiusCurrent = self:calculateCurvatureRadius(pA, pB, pC)

        local pD = self:getPointInDistance(currentNode, currentT, currentDist + 10.0, self.chain)
        local pE = self:getPointInDistance(currentNode, currentT, currentDist + 15.0, self.chain)
        local radiusAhead = self:calculateCurvatureRadius(pC, pD, pE)

        local effectiveRadius = math.min(radiusCurrent or 999.0, radiusAhead or 999.0)
        
        -- [[ FIX: CRITICAL POINT SEARCH ]]
        -- Instead of finding the absolute tightest radius (which might be 100m away),
        -- find the point that restricts speed the MOST (Considering we can brake).
        -- Metric: Minimize (Radius + 2.0 * Distance)
        -- Physics: R * LatG + 2 * BrkG * Dist = SpeedSquared. 
        -- Assuming BrkG approx equal to LatG, factor is ~2.0.
        
        local currentScore = effectiveRadius + (currentDist * 2.0)
        local minScore = minSustainedRadius + (distToApex * 2.0)
        
        if currentScore < minScore then
            minSustainedRadius = effectiveRadius
            distToApex = currentDist
            apexLocation = pB
            
            -- Determine Turn Direction (Z component of cross product)
            -- V1 (In), V2 (Out). Cross Z > 0 = Left, < 0 = Right (in SM usually? Verify standard).
            -- SM: X=Right, Y=Fwd, Z=Up? No.
            -- Using Perception standard: X/Y plane.
            local v1 = (pB - pA):normalize()
            local v2 = (pC - pB):normalize()
            local cross = v1:cross(v2).z
            self.detectedTurnDir = (cross > 0.001) and -1 or ((cross < -0.001) and 1 or 0) -- -1 Left, 1 Right
        end
        
        currentDist = currentDist + scanStep
    end
    
    return minSustainedRadius, distToApex, apexLocation, self.detectedTurnDir or 0
end

function PerceptionModule.get_world_rotations(self) 
    local rotationData = {}
    rotationData.at = self.Driver.shape:getAt()
    rotationData.up = self.Driver.shape:getUp()
    rotationData.right = self.Driver.shape:getRight()
    rotationData.back = rotationData.at * -1 
    rotationData.down = rotationData.up * -1
    rotationData.left = rotationData.right * -1 
    return rotationData
end 


-- [[ METRICS & CALCULATIONS ]]

function PerceptionModule:calculateCurvatureRadius(pA, pB, pC)
    local v1 = pB - pA; local v2 = pC - pB; local v3 = pC - pA
    local l1 = v1:length(); local l2 = v2:length(); local l3 = v3:length()
    local s = (l1 + l2 + l3) / 2
    local areaSq = s * (s - l1) * (s - l2) * (s - l3)
    if areaSq <= 0.001 then return MAX_CURVATURE_RADIUS end
    local radius = (l1 * l2 * l3) / (4 * math.sqrt(areaSq))
    return math.min(radius, MAX_CURVATURE_RADIUS)
end

function PerceptionModule:calculateRaceMetrics(closestPointData)
    -- NEW: High Precision Race Distance Calculation
    if not closestPointData then return 0, 0 end
    
    local node = closestPointData.baseNode
    local distBase = node.distFromStart or 0.0
    
    -- Project exact position onto centerline vector
    local offset = closestPointData.point - node.mid
    local fineDist = 0
    if node.outVector then
        fineDist = offset:dot(node.outVector)
    end
    
    -- Total Track Length (Grab from last node in chain)
    local trackLen = 1000.0
    if self.chain and #self.chain > 0 then
        trackLen = self.chain[#self.chain].distFromStart or 1000.0
    end
    
    -- Combine: Laps + Node Base + Fine Offset
    local lapOffset = (self.Driver.currentLap or 0) * trackLen
    local totalRaceDistance = lapOffset + distBase + fineDist
    
    -- Lap Progress (0.0 to 1.0)
    local progress = (distBase + fineDist) / trackLen
    
    return totalRaceDistance, math.max(0.0, math.min(1.0, progress))
end
function PerceptionModule.calculateNavigationInputs(self, navigation_data)
    local telemetry = self.perceptionData.Telemetry or {}
    local nav = navigation_data or {}
    nav.trackPositionBias = 0.0 
    nav.racingLineBias = 0.0 
    
    if not nav.closestPointData then return nav end
    
    local node = nav.closestPointData.baseNode
    local width = node.width or 20.0
    local halfWidth = width / 2
    
    -- 1. Calculate Lookahead
    local lookaheadDist = 12.0 + (telemetry.speed * 0.6)
    local targetPos = self:getPointInDistance(node, nav.closestPointData.tOnSegment, lookaheadDist, self.chain)
    nav.nodeGoalDirection = (targetPos - telemetry.location):normalize()
    nav.centerlineTarget = targetPos
    
    -- 2. Calculate Lateral Position (Track Bias)
    local nextNode = getNextItem(self.chain, node.id, 1)
    if nextNode then
        -- [[ FIX: USE SAVED 3D PERP VECTOR ]]
        -- Fallback to calculated 2D perp only if the node data is missing
        local segPerp = node.perp
        if not segPerp then
             local segDir = (nextNode.location - node.location):normalize()
             segPerp = sm.vec3.new(-segDir.y, segDir.x, 0) -- Legacy 2D fallback
        end
        
        -- Calculate distance from Center Line (mid)
        -- Note: We use 'mid' for lateral offset calculation to be consistent with the Scanner
        local carOffset = telemetry.location - node.mid
        local latDist = carOffset:dot(segPerp)
        
        nav.lateralMeters = latDist
        nav.trackPositionBias = -math.min(math.max(latDist / halfWidth, -1.0), 1.0)
        
        -- Racing Line Bias (Where is the green line relative to center?)
        local optimalOffset = (node.location - node.mid):dot(segPerp)
        nav.racingLineBias = -math.min(math.max(optimalOffset / halfWidth, -1.0), 1.0)
    end
    
    return nav
end

function PerceptionModule.calculateNavigationInputs_old(self, navigation_data)
    local telemetry = self.perceptionData.Telemetry or {}
    local nav = navigation_data or {}
    nav.trackPositionBias = 0.0 
    nav.racingLineBias = 0.0 
    
    if not nav.closestPointData then return nav end
    
    local node = nav.closestPointData.baseNode
    local width = node.width or 20.0
    local halfWidth = width / 2
    
    -- 1. Calculate Lookahead
    local lookaheadDist = 12.0 + (telemetry.speed * 0.6)
    local targetPos = self:getPointInDistance(node, nav.closestPointData.tOnSegment, lookaheadDist, self.chain)
    nav.nodeGoalDirection = (targetPos - telemetry.location):normalize()
    nav.centerlineTarget = targetPos
    
    -- 2. Calculate Lateral Position (Track Bias)
    local nextNode = getNextItem(self.chain, node.id, 1)
    if nextNode then
        local segDir = (nextNode.location - node.location):normalize()
        local segPerp = sm.vec3.new(-segDir.y, segDir.x, 0) -- 2D Perp
        
        local carOffset = telemetry.location - node.mid
        local latDist = carOffset:dot(segPerp)
        
        nav.lateralMeters = latDist
        nav.trackPositionBias = -math.min(math.max(latDist / halfWidth, -1.0), 1.0)
        
        -- Racing Line Bias (Where should I be vs where am I?)
        local optimalOffset = (node.location - node.mid):dot(segPerp)
        nav.racingLineBias = -math.min(math.max(optimalOffset / halfWidth, -1.0), 1.0)
    end
    
    return nav
end

function PerceptionModule.build_navigation_data(self) 
    local nav = {}
    nav.closestPointData = self:findClosestPointOnTrack(nil, self.chain) 
    
    if nav.closestPointData then
        local base = nav.closestPointData.baseNode
        local t = nav.closestPointData.tOnSegment
        local pA = nav.closestPointData.point
        
        -- Curvature Lookaheads
        local pB = self:getPointInDistance(base, t, LOOKAHEAD_DISTANCE_1, self.chain)
        local pC = self:getPointInDistance(base, t, LOOKAHEAD_DISTANCE_2, self.chain)
        local pD = self:getPointInDistance(base, t, LONG_LOOKAHEAD_DISTANCE, self.chain)
        
        nav.roadBankAngle = base.bank or 0.0 
        nav.roadCurvatureRadius = self:calculateCurvatureRadius(pA, pB, pC)
        nav.longCurvatureRadius = self:calculateCurvatureRadius(pA, pC, pD)
        
        -- [[ FIX: CALCULATE CURVE DIRECTION ]]
        -- Use the Cross Product Z-component to find direction.
        -- In SM: Forward x Right = Down (Negative Z). 
        -- So Right Turn = Negative Z, Left Turn = Positive Z.
        local vec1 = (pC - pA):normalize()
        local vec2 = (pD - pC):normalize()
        local crossZ = vec1:cross(vec2).z
        
        -- Threshold of 0.001 filters out noise on straight roads
        if crossZ < -0.001 then
            nav.longCurveDirection = 1 -- RIGHT
        elseif crossZ > 0.001 then
            nav.longCurveDirection = -1 -- LEFT
        else
            nav.longCurveDirection = 0 -- STRAIGHT
        end

        -- NEW: Calculate High Precision Metrics
        local totalDist, lapProg = self:calculateRaceMetrics(nav.closestPointData)
        nav.totalRaceDistance = totalDist
        nav.lapProgress = lapProg
    else
        nav.roadCurvatureRadius = MAX_CURVATURE_RADIUS
        nav.longCurveDirection = 0 -- [[ Safety Default ]]
        nav.totalRaceDistance = 0
        nav.lapProgress = 0
    end
    
    -- [[ NEW: SCAN FOR NEXT CORNER (Distance Based) ]]
    -- Look up to 200m ahead to find the first "Real" turn (Radius < 150m)
    nav.distToNextCorner = 999.0
    nav.nextCornerDir = 0 -- 0=None, 1=Right, -1=Left
    nav.nextCornerRadius = 999.0

    if nav.closestPointData then
        local scanDist = 0.0
        local scanNode = nav.closestPointData.baseNode
    
    local MAX_SCAN_DIST = 250.0
    local TURN_THRESH = 150.0 -- Radius below this counts as a "Corner"
    
    -- We will step forward 2 nodes at a time to save CPU
    while scanDist < MAX_SCAN_DIST and scanNode do
        local nextNode = getNextItem(self.chain, scanNode.id, 2) -- Jump 2 nodes
        if not nextNode then break end
        
        scanDist = scanDist + (nextNode.location - scanNode.location):length()
        scanNode = nextNode
        
        -- Calculate curvature at this future point
        -- We need 3 points: Prev, Curr, Next to get radius
        local pA = getNextItem(self.chain, scanNode.id, -2).location
        local pB = scanNode.location
        local pC = getNextItem(self.chain, scanNode.id, 2).location
        
        local r = self:calculateCurvatureRadius(pA, pB, pC)
        
        if r < TURN_THRESH then
            -- FOUND A TURN!
            nav.distToNextCorner = scanDist
            nav.nextCornerRadius = r
            --print('gr',r,scanDist)
            
            -- Calculate Direction
            local v1 = (pB - pA):normalize()
            local v2 = (pC - pB):normalize()
            local cross = v1:cross(v2).z
            if cross < -0.001 then nav.nextCornerDir = 1    -- Right
            elseif cross > 0.001 then nav.nextCornerDir = -1 -- Left
            end
            
            break -- Stop scanning, we found the next event
        end
    end
    end

    local inputs = self:calculateNavigationInputs(nav)
    nav.nodeGoalDirection = inputs.nodeGoalDirection
    nav.trackPositionBias = inputs.trackPositionBias
    return nav
end

-- [[ TELEMETRY & OPPONENTS ]]

function PerceptionModule.build_telemetry_data(self)
    local body = self.Driver.shape:getBody()
    if not body then return {} end

    local t = {} 
    t.velocity = body:getVelocity()
    t.speed = t.velocity:length()
    t.angularVelocity = body:getAngularVelocity()
    t.location = body:getWorldPosition()
    t.isOnLift = body:isStatic()
    
    -- Rotations
    local shape = self.Driver.shape
    t.rotations = { at = shape:getAt(), right = shape:getRight(), up = shape:getUp() }
    
    -- Dimensions
    t.carDimensions = self.Driver.carDimensions
    t.carHalfWidth = self.carHalfWidth
    t.bbDimensions = self.bbDimensions
    
    -- [[ FIX: READ RPM FROM ENGINE ]]
    t.avgWheelRPM = 0
    if self.Driver.engine and self.Driver.engine.avgWheelRPM then
        t.avgWheelRPM = self.Driver.engine.avgWheelRPM
    end

    -- Artificial Downforce (Read from linked logic blocks)
    t.downforce = 0
    for _, parent in ipairs(self.Driver.interactable:getParents()) do
        if tostring(parent:getShape():getShapeUuid()) == DOWNFORCE_BLOCK_UUID then 
            t.downforce = parent:getPower() 
        end
    end
    
    return t
end

function PerceptionModule.get_other_racers(self)
    local myLoc = self.perceptionData.Telemetry.location
    local myForward = self.perceptionData.Telemetry.rotations.at
    local list = {}
    
    for _, driver in ipairs(getAllDrivers()) do
        if driver.id ~= self.Driver.id and driver.perceptionData then 
            local opLoc = driver.perceptionData.Telemetry.location
            local dist = (opLoc - myLoc):length()

            if dist < 100.0 and dist > 0.01 then 
                local dirTo = (opLoc - myLoc):normalize()
                local dot = dirTo:dot(myForward)
                
                -- Closing Speed: Positive = Closing (They are slower/coming at us). Negative = Opening.
                -- Vector subtraction: (MyVel - OpVel) dot DirToTarget
                local relVel = self.perceptionData.Telemetry.velocity - driver.perceptionData.Telemetry.velocity
                local closingSpeed = relVel:dot(dirTo)
                
                table.insert(list, {
                    driver = driver,
                    location = opLoc,
                    distance = dist,
                    isAhead = dot > 0.1,
                    closingSpeed = closingSpeed,
                    -- TTC: Only relevant if we are closing (speed > 0)
                    timeToCollision = (closingSpeed > 0.1) and (dist / closingSpeed) or math.huge,
                    opponentBias = driver.perceptionData.Navigation and driver.perceptionData.Navigation.trackPositionBias or 0.0
                })
            end
        end
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    return list
end

function PerceptionModule.build_opponent_data(self)
    local list = self:get_other_racers()
    local data = { count = #list, racers = list, isLeftLaneClear = true, isRightLaneClear = true }
    local bestDraft = nil -- drafting target
    local bestDraftScore = -1
    for _, op in ipairs(list) do
        -- Simple collision prediction
        if op.timeToCollision < 1.0 then data.collisionRisk = op end
        -- Check for draft: Ahead, close enough, safe closing speed
        if op.isAhead and op.distance < 35.0 and op.distance > 5.0 then
            -- Are we lined up behind them? (Bias difference is small)
            local myBias = self.perceptionData.Navigation.trackPositionBias or 0
            if math.abs(op.opponentBias - myBias) < 0.3 then
                -- This is a candidate
                if op.distance > bestDraftScore then -- Pick the furthest one in range (cleaner air?) or closest?
                     bestDraft = op
                     bestDraftScore = op.distance
                end
            end
        end
        -- Lane Clearance
        local opHalfWidth = 0.2 -- Normalized bias width
        local opLeft = op.opponentBias - opHalfWidth
        local opRight = op.opponentBias + opHalfWidth
        
        if opRight > -0.2 then data.isLeftLaneClear = false end
        if opLeft < 0.2 then data.isRightLaneClear = false end
    end
    data.draftingTarget = bestDraft 
    data.isOvertakePossible = (not data.collisionRisk and data.count > 0 and (data.isLeftLaneClear or data.isRightLaneClear))
    return data
end

-- [[ MAIN LOOP ]]

function PerceptionModule.server_onFixedUpdate(self, dt)
    self.perceptionData.Telemetry = self:build_telemetry_data()
    self.perceptionData.Navigation = self:build_navigation_data()
    self.perceptionData.Opponents = self:build_opponent_data()
    -- Wall avoidance calculated last using updated nav
    self.perceptionData.WallAvoidance = self:calculateWallAvoidance() 
    return self.perceptionData 
end

function PerceptionModule.performRaycasts(self)
    -- Need physical car body for this
    if not self.Driver.body then return nil end
    
    local startPos = self.Driver.shape:getWorldPosition() + (self.Driver.shape:getUp() * 0.5) -- Lift scan up slightly
    local fwd = self.Driver.shape:getAt()
    local right = self.Driver.shape:getRight()
    
    local results = { left = 999.0, right = 999.0, center = 999.0 }
    
    -- RAY 1: LEFT ANGLE (15 deg)
    -- Direction: Fwd * cos(15) - Right * sin(15)
    local lDir = (fwd * 0.96) - (right * 0.25)
    local lEnd = startPos + (lDir * 15.0) -- 15m Scan Left
    local lValid, lRes = sm.physics.raycast(startPos, lEnd)
    if lValid and lRes.type ~= "Body" then -- Ignore specific bodies? No, walls are static usually.
         results.left = (lRes.pointWorld - startPos):length()
    end
    
    -- RAY 2: RIGHT ANGLE (15 deg)
    local rDir = (fwd * 0.96) + (right * 0.25)
    local rEnd = startPos + (rDir * 15.0)
    local rValid, rRes = sm.physics.raycast(startPos, rEnd)
    if rValid and rRes.type ~= "Body" then
         results.right = (rRes.pointWorld - startPos):length()
    end
    
    -- RAY 3: CENTER (Look further)
    local cEnd = startPos + (fwd * 30.0)
    local cValid, cRes = sm.physics.raycast(startPos, cEnd)
    if cValid and cRes.type ~= "Body" then
         results.center = (cRes.pointWorld - startPos):length()
    end
    
    return results
end

function PerceptionModule.calculateWallAvoidance(self)
    local nav = self.perceptionData.Navigation
    local bias = nav.trackPositionBias or 0
    local hw = (nav.closestPointData and nav.closestPointData.baseNode.width / 2) or 10
    
    -- 1. THEORETICAL MARGINS (Spline)
    local marginL = (1.0 + bias) * hw - self.carHalfWidth
    local marginR = (1.0 - bias) * hw - self.carHalfWidth
    
    -- 2. PHYSICAL MARGINS (Raycast)
    -- We only run raycasts periodically or every frame? Every frame is fine for 3 rays.
    local rays = self:performRaycasts()
    local rayL = 999.0
    local rayR = 999.0
    
    if rays then
        -- Map "Left Ray" distance roughly to "Left Margin"
        -- Ray distance is Hypotenuse. Perpendicular distance is less.
        -- cos(15) ~ 0.96.
        if rays.left < 999 then rayL = rays.left * 0.96 - self.carHalfWidth end
        if rays.right < 999 then rayR = rays.right * 0.96 - self.carHalfWidth end
        
        -- Center Ray: If blocked, it means a wall is dead ahead (T-Junction?)
        -- Treat as symmetric danger?
        if rays.center < 5.0 then
            rayL = math.min(rayL, rays.center * 0.5)
            rayR = math.min(rayR, rays.center * 0.5)
        end
    end
    
    -- 3. SENSOR FUSION (Take Minimum safe distance)
    -- We only trust Raycast if it's seeing something CLOSE (e.g. < 5m wider than spline margin)
    -- Actually, simple min() is safest. If Spline says 10m but Wall says 2m, we have 2m.
    -- If Spline says 2m but Wall says 10m (missing wall?), we assume 2m (track limits).
    local fusedL = math.min(marginL, rayL)
    local fusedR = math.min(marginR, rayR)
    
    return {
        marginLeft = fusedL,
        marginRight = fusedR,
        isForwardLeftCritical = fusedL <= CRITICAL_WALL_MARGIN,
        isForwardRightCritical = fusedR <= CRITICAL_WALL_MARGIN,
        raycastData = rays -- Debug info
    }
end