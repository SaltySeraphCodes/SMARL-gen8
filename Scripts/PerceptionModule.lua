-- PerceptionModule.lua
dofile("globals.lua") 
PerceptionModule = class(nil)

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
local WALL_LOOKAHEAD_DIST = 10.0 

function PerceptionModule.server_init(self,driver)
    self.Driver = driver
    self.Driver.carDimensions = self:scanCarDimensions()

    local aabb_min, aabb_max = self.Driver.body:getWorldAabb()
    local dimensions = aabb_max - aabb_min
    self.carHalfWidth = math.max(dimensions.x, dimensions.y) / 2.0
    
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
    -- Generates the front/rear/left/right offsets using Global helpers
    local body = self.Driver.shape:getBody()
    local shapes = body:getCreationShapes()
    local origin = self.Driver.shape:getWorldPosition()
    
    local at = self.Driver.shape:getAt()
    local right = self.Driver.shape:getRight()
    
    -- Use globals.lua helper: getDirectionOffset(shapeList, direction, origin)
    local front = getDirectionOffset(shapes, at, origin)
    local rear = getDirectionOffset(shapes, at * -1, origin)
    local left = getDirectionOffset(shapes, right * -1, origin)
    local rightVec = getDirectionOffset(shapes, right, origin)
    
    -- Calculate Center (Midpoint logic)
    local frontLeft = origin + front + left
    local rearRight = origin + rightVec + rear
    local center = getMidpoint(frontLeft, rearRight) -- Global helper
    
    local centerOffset = center - origin
    
    -- Calculate center rotation/length relative to car
    local centerLen = centerOffset:length()
    local centerRot = sm.vec3.new(0,0,0)
    if centerLen > 0.001 then
        centerRot = sm.vec3.getRotation(at, centerOffset:normalize())
    end
    
    -- Returns the exact table structure CameraManager expects
    return {
        front = front,
        rear = rear,
        left = left,
        right = rightVec,
        center = { rotation = centerRot, length = centerLen }
    }
end

function PerceptionModule:findClosestNodeFallback(chain, carLocation)
    if not chain or #chain == 0 then return nil end
    local minDistanceSq = math.huge
    local closestNode = nil
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

function PerceptionModule:calculateCurvatureRadius(pA, pB, pC)
    local a = sm.vec3.new(pA.x, pA.y, 0)
    local b = sm.vec3.new(pB.x, pB.y, 0)
    local c = sm.vec3.new(pC.x, pC.y, 0)
    local v1 = b - a
    local v2 = c - b
    local length1 = v1:length()
    local length2 = v2:length()
    local length3 = (c - a):length()
    local crossZ = v1.x * v2.y - v1.y * v2.x
    -- If the points are collinear (cross product near 0), it's a straight line
    if math.abs(crossZ) < 0.001 then return MAX_CURVATURE_RADIUS end
    local s = (length1 + length2 + length3) / 2
    local area = math.sqrt(math.abs(s * (s - length1) * (s - length2) * (s - length3)))
    if area == 0 then return MAX_CURVATURE_RADIUS end
    local radius = (length1 * length2 * length3) / (4 * area)
    return math.min(radius, MAX_CURVATURE_RADIUS) 
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

function PerceptionModule:scanTrackCurvature(scanDistance)
    local nav = self.perceptionData.Navigation
    if not nav or not nav.closestPointData then 
        return MAX_CURVATURE_RADIUS, 0.0, nil 
    end

    local currentNode = nav.closestPointData.baseNode
    local currentT = nav.closestPointData.tOnSegment
    
    local minRadius = MAX_CURVATURE_RADIUS
    local distToMin = 0.0
    local apexLocation = nil -- [NEW] To store the physical point of the apex
    
    local scanStep = 5.0 
    local currentDist = 0.0
    local chordOffset = 15.0

    while currentDist < scanDistance do
        local pA = self:getPointInDistance(currentNode, currentT, currentDist, self.chain)
        local pB = self:getPointInDistance(currentNode, currentT, currentDist + chordOffset, self.chain)
        local pC = self:getPointInDistance(currentNode, currentT, currentDist + (chordOffset * 2), self.chain)
        
        local radius = self:calculateCurvatureRadius(pA, pB, pC)
        
        if radius < minRadius then
            minRadius = radius
            distToMin = currentDist
            apexLocation = pB -- [NEW] Capture the center of the curve
        end
        
        currentDist = currentDist + scanStep
    end
    
    -- Return Apex Location as the 3rd argument
    return minRadius, distToMin, apexLocation
end


function PerceptionModule:scanTrackCurvature_old(scanDistance)
    local nav = self.perceptionData.Navigation
    if not nav or not nav.closestPointData then 
        return MAX_CURVATURE_RADIUS, 0.0 
    end

    local currentNode = nav.closestPointData.baseNode
    local currentT = nav.closestPointData.tOnSegment
    
    local minRadius = MAX_CURVATURE_RADIUS
    local distToMin = 0.0
    
    -- Check points at intervals ahead
    local scanStep = 5.0 -- Check every 5 meters
    local currentDist = 0.0
    
    while currentDist < scanDistance do
        -- Get three points centered around our scan distance
        -- P_Prev -- P_Center -- P_Next
        local pPrev = self:getPointInDistance(currentNode, currentT, currentDist - 3.0, self.chain)
        local pCenter = self:getPointInDistance(currentNode, currentT, currentDist, self.chain)
        local pNext = self:getPointInDistance(currentNode, currentT, currentDist + 3.0, self.chain)
        
        local radius = self:calculateCurvatureRadius(pPrev, pCenter, pNext)
        
        if radius < minRadius then
            minRadius = radius
            distToMin = currentDist
        end
        
        currentDist = currentDist + scanStep
    end
    
    return minRadius, distToMin
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

function PerceptionModule.build_telemetry_data(self)
    local driverBody = self.Driver.shape:getBody()
    local telemetryData = {} 
    telemetryData.carDimensions = self.Driver.carDimensions or self:scanCarDimensions()
    telemetryData.velocity = driverBody:getVelocity()
    telemetryData.angularVelocity = driverBody:getAngularVelocity()
    telemetryData.angularSpeed = telemetryData.angularVelocity:length() 
    telemetryData.speed = telemetryData.velocity:length() 
    telemetryData.mass = driverBody:getMass()
    local aabb_min, aabb_max = driverBody:getWorldAabb()
    telemetryData.worldAabb = { min = aabb_min, max = aabb_max } -- Store table if needed, or just keep internal
    local dims = aabb_max - aabb_min
    telemetryData.dimensions = dims
    telemetryData.carHalfWidth = self.carHalfWidth 
    telemetryData.location = self.Driver.body:getWorldPosition() 
    telemetryData.isOnLift = self.Driver.body:isStatic()
    telemetryData.rotations = self:get_world_rotations() 
    telemetryData.downforce = self:get_artificial_downforce() 
    telemetryData.avgWheelRPM = 0.0
    telemetryData.avgWheelRadS = 0.0
    return telemetryData
end

function PerceptionModule.findClosestPointOnTrack(self, location, chain)
    local telemetry_data = self.perceptionData.Telemetry or {}
    -- Default to current car position if no specific location is provided
    local carLocation = location or telemetry_data.location or self.Driver.body:getWorldPosition()
    
    -- Find a starting point for the search (optimization)
    local segmentStartNode = self.currentNode or self:findClosestNodeFallback(chain, carLocation) 
    if not segmentStartNode then return nil end
    
    local searchWindow = 10 
    local closestPoint = nil
    local bestDistanceSq = math.huge
    
    -- Search locally around the last known node
    for i = -5, searchWindow - 6 do 
        local node1 = getNextItem(chain, segmentStartNode.id, i)
        local node2 = getNextItem(chain, node1.id, 1) 
        if not node1 or not node2 then break end
        
        local segmentVector = node2.location - node1.location
        local carVector = carLocation - node1.location
        local segmentLengthSq = segmentVector:length2()
        
        -- Project car position onto the track segment line
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
                tOnSegment = clamped_t,
                distanceSq = distanceSq 
            }
        end
    end
    
    -- [UPDATED LOGIC]
    if closestPoint and not location then
        self.currentNode = closestPoint.baseNode
        
        -- MEMORY UPDATE:
        -- Update the Driver's memory of the last confirmed valid node.
        -- 'baseNode' is the start of the current segment (the node behind the car).
        -- We only update this if we are doing a real-time scan (not location is nil),
        -- ensuring we don't overwrite memory when doing hypothetical checks.
        if self.Driver then
            self.Driver.lastPassedNode = closestPoint.baseNode
        end
    end
    
    return closestPoint
end

function PerceptionModule.calculateNavigationInputs(self, navigation_data)
    local telemetry_data = self.perceptionData.Telemetry or {}
    local nav = navigation_data or {}
    nav.trackPositionBias = 0.0 
    nav.racingLineBias = 0.0 
    nav.nodeGoalDirection = sm.vec3.new(0, 1, 0)
    nav.trackWidth = 20.0 -- Default width fallback [NEW]
    
    if not navigation_data.closestPointData then return nav end
    
    local closestPointData = navigation_data.closestPointData
    local baseNode = closestPointData.baseNode
    
    -- [NEW] Store Width explicitly for Debugging
    if baseNode.width then nav.trackWidth = baseNode.width end

    -- 1. Lookahead Logic
    local baseLookahead = 12.0 
    local speedFactor = 0.6   
    local lookaheadDist = baseLookahead + telemetry_data.speed * speedFactor
    local lookaheadTarget = self:getPointInDistance(
        baseNode, 
        closestPointData.tOnSegment, 
        lookaheadDist,
        self.chain 
    )
    nav.nodeGoalDirection = (lookaheadTarget - telemetry_data.location):normalize() 

    -- 2. Robust Track Position Bias Calculation
    local node1 = baseNode
    local node2 = getNextItem(self.chain, node1.id, 1)

    if node1 and node2 and node1.width then
        local segmentDir = (node2.location - node1.location):normalize()
        local segmentPerp = sm.vec3.new(-segmentDir.y, segmentDir.x, 0)
        local halfWidth = node1.width / 2

        -- Calculate Car Bias relative to MID
        local offsetVector = telemetry_data.location - node1.mid 
        local lateralOffset = offsetVector:dot(segmentPerp)
        
        -- [NEW] Store raw meters for debug before normalizing
        nav.lateralMeters = lateralOffset 

        nav.trackPositionBias = -math.min(math.max(lateralOffset / halfWidth, -1.0), 1.0)

        -- Calculate Racing Line Bias relative to MID
        local racingOffset = node1.location - node1.mid
        local racingLateral = racingOffset:dot(segmentPerp)
        nav.racingLineBias = -math.min(math.max(racingLateral / halfWidth, -1.0), 1.0)
    else
        nav.trackPositionBias = 0.0
        nav.racingLineBias = 0.0
        nav.lateralMeters = 0.0
    end

    -- 3. Visual/Navigation Targets
    if node1.perp and node1.width then
        local perpVector = node1.perp:normalize() 
        local halfWidth = node1.width / 2
        local lane_width = LANE_SLOT_WIDTH or 0.33
        local car_bias = CAR_WIDTH_BIAS or 0.2
        
        nav.centerlineTarget = lookaheadTarget 
        local target_mid_loc = node1.location + (lookaheadTarget - closestPointData.point) 
        
        nav.lookaheadTargetLeft = target_mid_loc + perpVector * (halfWidth * (-lane_width - car_bias))
        nav.lookaheadTargetRight = target_mid_loc + perpVector * (halfWidth * (lane_width + car_bias))
    else
        nav.centerlineTarget = lookaheadTarget
        nav.lookaheadTargetLeft = lookaheadTarget
        nav.lookaheadTargetRight = lookaheadTarget
    end

    return nav
end

function PerceptionModule.build_navigation_data(self) 
    local navigationData = {}
    navigationData.closestPointData = self:findClosestPointOnTrack(nil, self.chain) 
    if navigationData.closestPointData then
        local baseNode = navigationData.closestPointData.baseNode
        local tOnSegment = navigationData.closestPointData.tOnSegment
        local pA = navigationData.closestPointData.point 
        
        -- Use the updated, wider lookahead distances
        local pB = self:getPointInDistance(baseNode, tOnSegment, LOOKAHEAD_DISTANCE_1, self.chain) 
        local pC = self:getPointInDistance(baseNode, tOnSegment, LOOKAHEAD_DISTANCE_2, self.chain) 
        local pD = self:getPointInDistance(baseNode, tOnSegment, LONG_LOOKAHEAD_DISTANCE, self.chain) 
        
        local V_AC = pC - pA
        local V_CD = pD - pC
        local crossZ_long = V_AC.x * V_CD.y - V_AC.y * V_CD.x
        
        navigationData.roadBankAngle = baseNode.bank or 0.0 
        -- Long radius: Used for braking early
        navigationData.longCurvatureRadius = self:calculateCurvatureRadius(pA, pC, pD)
        -- Short radius: Used for immediate cornering state
        navigationData.roadCurvatureRadius = self:calculateCurvatureRadius(pA, pB, pC)
        navigationData.longCurveDirection = getSign(crossZ_long) 
        navigationData.continuousPositionScore = baseNode.id + tOnSegment
        
    else
        navigationData.roadCurvatureRadius = MAX_CURVATURE_RADIUS
        navigationData.longCurvatureRadius = MAX_CURVATURE_RADIUS
        navigationData.longCurveDirection = 0
        navigationData.continuousPositionScore = 0
    end
    
    local navInputData = self:calculateNavigationInputs(navigationData) 
    navigationData.nodeGoalDirection = navInputData.nodeGoalDirection
    navigationData.trackPositionBias = navInputData.trackPositionBias
    return navigationData
end

function PerceptionModule.calculateWallAvoidance(self)
    local nav = self.perceptionData.Navigation or {}
    local wallData = {}
    local CAR_HALF_WIDTH_ACTUAL = self.carHalfWidth 
    
    if not nav.closestPointData then 
        wallData.marginLeft = math.huge
        wallData.marginRight = math.huge
        return wallData
    end
    
    local node = nav.closestPointData.baseNode
    local halfWidth = node.width / 2
    local trackBias = nav.trackPositionBias -- Uses the fixed -1 to 1 bias
    
    -- LATERAL CALCULATIONS (Current Position)
    -- If Bias is -1 (Left), marginLeft should be 0.
    -- If Bias is 1 (Right), marginRight should be 0.
    wallData.marginLeft = (1.0 + trackBias) * halfWidth - CAR_HALF_WIDTH_ACTUAL
    wallData.marginRight = (1.0 - trackBias) * halfWidth - CAR_HALF_WIDTH_ACTUAL
    
    -- LOOKAHEAD CALCULATIONS (Predictive)
    -- Optimized: Instead of a full search, we peek forward in the chain
    local forwardNode = getNextItem(self.chain, node.id, 3) -- Peak ~12m ahead
    if forwardNode then
        -- We estimate forward bias based on current trajectory to save CPU
        local forwardHalfWidth = forwardNode.width / 2
        wallData.forwardMarginLeft = (1.0 + trackBias) * forwardHalfWidth - CAR_HALF_WIDTH_ACTUAL
        wallData.forwardMarginRight = (1.0 - trackBias) * forwardHalfWidth - CAR_HALF_WIDTH_ACTUAL
    else
        wallData.forwardMarginLeft = wallData.marginLeft
        wallData.forwardMarginRight = wallData.marginRight
    end
    
    -- CRITICAL FLAGS
    wallData.isLeftCritical = wallData.marginLeft <= CRITICAL_WALL_MARGIN
    wallData.isRightCritical = wallData.marginRight <= CRITICAL_WALL_MARGIN
    wallData.isForwardLeftCritical = wallData.forwardMarginLeft <= CRITICAL_WALL_MARGIN
    wallData.isForwardRightCritical = wallData.forwardMarginRight <= CRITICAL_WALL_MARGIN
    
    return wallData
end

function PerceptionModule:checkBlueFlagCondition(opponentDriver, distance, closingSpeed)
    local myLap = self.Driver.currentLap
    local opLap = opponentDriver.currentLap
    if opLap > myLap and distance < 30.0 and closingSpeed > 2.0 then 
        return true
    end
    return false
end

function PerceptionModule.get_other_racers(self)
    local telemetry = self.perceptionData.Telemetry or {}
    local myLocation = telemetry.location
    local myForward = telemetry.rotations.at
    
    local opponentList = {}
    local blueFlagActive = false 

    local allRacers = getAllDrivers() or {} 
    
    for _, opponentDriver in ipairs(allRacers) do
        if opponentDriver.id ~= self.Driver.id and opponentDriver.perceptionData then 
            local opLocation = opponentDriver.perceptionData.Telemetry.location
            local opVelocity = opponentDriver.perceptionData.Telemetry.velocity

            local vectorToOp = opLocation - myLocation
            local distance = vectorToOp:length()

            if distance < 100.0 and distance > 0.01 then 
                
                local dirToOp = vectorToOp:normalize()
                local dotProduct = dirToOp:dot(myForward) 
                local relativeVelocity = opVelocity - telemetry.velocity
                local closingSpeed = relativeVelocity:dot(dirToOp)

                local opPerception = opponentDriver.perceptionData 
                local opNav = opPerception and opPerception.Navigation or {}
                local opBias = opNav.trackPositionBias or 0.0 
                
                local TTC = math.huge
                if closingSpeed < -0.1 then 
                    TTC = distance / math.abs(closingSpeed)
                end

                local opForward = opponentDriver.shape:getAt() 
                local isLappingMe = false
                if dotProduct < 0 and self:checkBlueFlagCondition(opponentDriver, distance, math.abs(closingSpeed)) then
                    isLappingMe = true
                    blueFlagActive = true
                end
                
                table.insert(opponentList, {
                    driver = opponentDriver,           
                    location = opLocation,             
                    distance = distance,               
                    isAhead = dotProduct > 0.1,        
                    dotProduct = dotProduct,           
                    closingSpeed = closingSpeed,
                    timeToCollision = TTC,             
                    opponentForward = opForward,        
                    opponentBias = opBias,             
                    isLappingMe = isLappingMe 
                })
            end
        end
    end
    
    table.sort(opponentList, function(a, b) return a.distance < b.distance end)
    self.blueFlagActive = blueFlagActive 
    return opponentList
end

function PerceptionModule.build_opponent_data(self)
    local opponentList = self:get_other_racers()
    local myBias = self.perceptionData.Navigation.trackPositionBias or 0.0

    local opponentData = {
        count = #opponentList,
        racers = opponentList,
        draftingTarget = nil, 
        collisionRisk = nil,   
        isLeftLaneClear = true, 
        isRightLaneClear = true,
        isOvertakePossible = false,
        blueFlagActive = self.blueFlagActive 
    }

    for _, opponent in ipairs(opponentList) do
        if opponent.isAhead and opponent.distance < MIN_DRAFTING_DIST and opponent.dotProduct > MAX_DRAFTING_ANGLE then
            if not opponentData.draftingTarget or opponent.distance < opponentData.draftingTarget.distance then 
                opponentData.draftingTarget = opponent
            end
        end

        if opponent.timeToCollision < 1.0 then 
            if not opponentData.collisionRisk or opponent.timeToCollision < opponentData.collisionRisk.timeToCollision then
                opponentData.collisionRisk = opponent
            end
        end

        local opBias = opponent.opponentBias
        local opHalfWidth = CAR_WIDTH_BIAS 
        
        local opLeftEdge = opBias - opHalfWidth 
        local opRightEdge = opBias + opHalfWidth 
        
        if opRightEdge > (0.0 - opHalfWidth) then opponentData.isLeftLaneClear = false end
        if opLeftEdge < (0.0 + opHalfWidth) then opponentData.isRightLaneClear = false end
        if math.abs(opBias) < opHalfWidth then 
            opponentData.isLeftLaneClear = false
            opponentData.isRightLaneClear = false
        end

        if opRightEdge > 0.0 and opLeftEdge < 0.0 then opponentData.isLeftLaneClear = false end
        if opLeftEdge < 0.0 and opRightEdge > 0.0 then opponentData.isRightLaneClear = false end
    end

    opponentData.isOvertakePossible = not opponentData.collisionRisk and 
                                     (opponentData.count > 0) and 
                                     (opponentData.isLeftLaneClear or opponentData.isRightLaneClear)
    
    return opponentData
end

function PerceptionModule.build_perception_data(self) 
    local newPerceptionData = {}
    local newTelemetryData = self:build_telemetry_data() 
    self.perceptionData.Telemetry = newTelemetryData
    local newNavData = self:build_navigation_data() 
    self.perceptionData.Navigation = newNavData
    local newWallData = self:calculateWallAvoidance()
    self.perceptionData.WallAvoidance = newWallData
    local newOpponentData = self:build_opponent_data()
    self.perceptionData.Opponents = newOpponentData
    
    newPerceptionData.Telemetry = newTelemetryData
    newPerceptionData.Navigation = newNavData
    newPerceptionData.Opponents = newOpponentData
    newPerceptionData.WallAvoidance = newWallData
    return newPerceptionData
end

function PerceptionModule.server_onFixedUpdate(self,dt)
    local newPerceptionData = self:build_perception_data()
    self.perceptionData = newPerceptionData 
    return newPerceptionData 
end