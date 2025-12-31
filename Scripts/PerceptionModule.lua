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
        local aabb_min, aabb_max = self.Driver.body:getWorldAabb()
        local dimensions = aabb_max - aabb_min
        self.carHalfWidth = math.max(dimensions.x, dimensions.y) / 2.0
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

function PerceptionModule.findClosestPointOnTrack(self, location, chain)
    local telemetry = self.perceptionData.Telemetry or {}
    local carLocation = location or telemetry.location or self.Driver.body:getWorldPosition()
    
    -- 1. Try Local Search first (Optimization)
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
    if fallbackNeeded then
        local globalNode = self:findClosestNodeFallback(chain, carLocation)
        if globalNode then
             self.currentNode = globalNode
             return self:findClosestPointOnTrack(location, chain) -- Recursion for precise fit
        end
    end
    
    -- 3. Update Memory
    if closestPoint and not location then
        self.currentNode = closestPoint.baseNode
        if self.Driver then self.Driver.lastPassedNode = closestPoint.baseNode end
    end
    
    return closestPoint
end


function PerceptionModule:getPointInDistance(baseNode, start_t, distance, chain)
    local remainingDistance = distance
    local currentNode = baseNode
    if not currentNode or distance <= 0 then return baseNode.location end
    local nextNode = getNextItem(chain, currentNode.id, 1)
    if nextNode then
        local segmentVector = nextNode.location - currentNode.location
        local segmentLength = segmentVector:length()
        local distanceToEndOfSegment = segmentLength * (1.0 - start_t)
        if distanceToEndOfSegment >= remainingDistance then
            local target_t = start_t + (remainingDistance / segmentLength)
            return currentNode.location + segmentVector * target_t
        else
            remainingDistance = remainingDistance - distanceToEndOfSegment
            currentNode = nextNode
        end
    end
    local nodeDitsTimeout = 0
    local timeoutLimit = 300 
    while remainingDistance > 0 and nodeDitsTimeout < timeoutLimit do
        nextNode = getNextItem(chain, currentNode.id, 1)
        if not nextNode then return currentNode.location end 
        local segmentVector = nextNode.location - currentNode.location
        local segmentLength = segmentVector:length()
        if segmentLength >= remainingDistance then
            local target_t = remainingDistance / segmentLength
            return currentNode.location + segmentVector * target_t
        else
            remainingDistance = remainingDistance - segmentLength
            currentNode = nextNode
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

        local effectiveRadius = math.max(radiusCurrent, radiusAhead)

        if effectiveRadius < minSustainedRadius then
            minSustainedRadius = effectiveRadius
            distToApex = currentDist
            apexLocation = pB
        end
        
        currentDist = currentDist + scanStep
    end
    
    return minSustainedRadius, distToApex, apexLocation
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



function PerceptionModule:getPointInDistance(baseNode, start_t, distance, chain)
    local remainingDistance = distance
    local currentNode = baseNode
    if not currentNode or distance <= 0 then return baseNode.location end
    
    local nodeDitsTimeout = 0
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
        
        -- NEW: Calculate High Precision Metrics
        local totalDist, lapProg = self:calculateRaceMetrics(nav.closestPointData)
        nav.totalRaceDistance = totalDist
        nav.lapProgress = lapProg
    else
        nav.roadCurvatureRadius = MAX_CURVATURE_RADIUS
        nav.totalRaceDistance = 0
        nav.lapProgress = 0
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
                local closingSpeed = (driver.perceptionData.Telemetry.velocity - self.perceptionData.Telemetry.velocity):dot(dirTo)
                
                table.insert(list, {
                    driver = driver,
                    location = opLoc,
                    distance = dist,
                    isAhead = dot > 0.1,
                    closingSpeed = closingSpeed,
                    timeToCollision = (closingSpeed < -0.1) and (dist / math.abs(closingSpeed)) or math.huge,
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
    
    for _, op in ipairs(list) do
        -- Simple collision prediction
        if op.timeToCollision < 1.0 then data.collisionRisk = op end
        
        -- Lane Clearance
        local opHalfWidth = 0.2 -- Normalized bias width
        local opLeft = op.opponentBias - opHalfWidth
        local opRight = op.opponentBias + opHalfWidth
        
        if opRight > -0.2 then data.isLeftLaneClear = false end
        if opLeft < 0.2 then data.isRightLaneClear = false end
    end
    
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

function PerceptionModule.calculateWallAvoidance(self)
    local nav = self.perceptionData.Navigation
    local bias = nav.trackPositionBias or 0
    local hw = (nav.closestPointData and nav.closestPointData.baseNode.width / 2) or 10
    
    local marginL = (1.0 + bias) * hw - self.carHalfWidth
    local marginR = (1.0 - bias) * hw - self.carHalfWidth
    
    return {
        marginLeft = marginL,
        marginRight = marginR,
        isLeftCritical = marginL <= CRITICAL_WALL_MARGIN,
        isRightCritical = marginR <= CRITICAL_WALL_MARGIN
    }
end