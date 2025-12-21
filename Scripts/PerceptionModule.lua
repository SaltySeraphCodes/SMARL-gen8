-- PerceptionModule.lua
dofile("globals.lua") 
PerceptionModule = class(nil)

local Z_TOLERANCE_SQ = 25        
-- UPDATED: Increased lookahead spread to better detect macro-curve geometry
-- Previous 4.0/9.0 was too narrow, causing "straight line" detection on polyline segments.
local LOOKAHEAD_DISTANCE_1 = 8.0 
local LOOKAHEAD_DISTANCE_2 = 18.0 
local MAX_CURVATURE_RADIUS = 1000.0 
local LONG_LOOKAHEAD_DISTANCE = 60.0 -- Increased slightly to see further down straights

local LANE_SLOT_WIDTH = 0.33 
local MIN_DRAFTING_DIST = 30.0 
local MAX_DRAFTING_ANGLE = 0.9 
local CAR_WIDTH_BIAS = 0.2 
local CRITICAL_WALL_MARGIN = 0.5 
local WALL_LOOKAHEAD_DIST = 10.0 

function PerceptionModule.server_init(self,driver)
    self.Driver = driver 
    
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
    telemetryData.velocity = driverBody:getVelocity()
    telemetryData.angularVelocity = self.Driver.body:getAngularVelocity()
    telemetryData.angularSpeed = telemetryData.angularVelocity:length() 
    telemetryData.speed = telemetryData.velocity:length() 
    telemetryData.mass = self.Driver.body:getMass()
    telemetryData.worldAabb = self.Driver.body:getWorldAabb()
    telemetryData.carHalfWidth = self.carHalfWidth 
    telemetryData.location = self.Driver.body:getWorldPosition() 
    telemetryData.isOnLift = self.Driver.body:isStatic()
    telemetryData.rotations = self:get_world_rotations() 
    telemetryData.downforce = self:get_artificial_downforce() 
    return telemetryData
end

function PerceptionModule.findClosestPointOnTrack(self,location,chain)
    local telemetry_data = self.perceptionData.Telemetry or {}
    local carLocation = location or telemetry_data.location or self.Driver.body:getWorldPosition() 
    local segmentStartNode = self.currentNode or self:findClosestNodeFallback(chain, carLocation) 
    if not segmentStartNode then return nil end
    local searchWindow = 10 
    local closestPoint = nil
    local bestDistanceSq = math.huge
    for i = -5, searchWindow - 6 do 
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
                tOnSegment = clamped_t,
                distanceSq = distanceSq 
            }
        end
    end
    if closestPoint and not location then
        self.currentNode = closestPoint.baseNode
    end
    return closestPoint
end

function PerceptionModule.calculateNavigationInputs(self,navigation_data)
    local telemetry_data = self.perceptionData.Telemetry or {}
    local nav = navigation_data or {}
    if not navigation_data.closestPointData then return nav end
    local closestPointData = navigation_data.closestPointData
    local baseLookahead = 5 
    local speedFactor = 0.6   
    local lookaheadDist = baseLookahead + telemetry_data.speed * speedFactor 
    local lookaheadTarget = self:getPointInDistance(
        closestPointData.baseNode, 
        closestPointData.tOnSegment, 
        lookaheadDist,
        self.chain 
    )
    nav.nodeGoalDirection = (lookaheadTarget - telemetry_data.location):normalize() 
    local node = navigation_data.closestPointData.baseNode
    if node.mid and node.perp and node.width then
        local offsetVector = closestPointData.point - node.mid 
        local halfWidth = node.width / 2
        local lateralOffset = offsetVector:dot(node.perp) 
        nav.trackPositionBias = math.min(math.max(lateralOffset / halfWidth, -1.0), 1.0)
    else
        nav.trackPositionBias = 0.0
    end
    local node = navigation_data.closestPointData.baseNode
    if node.perp and node.mid and node.width then
        local perpVector = node.perp:normalize() 
        local halfWidth = node.width / 2
        local desired_bias_left = -LANE_SLOT_WIDTH
        local desired_bias_right = LANE_SLOT_WIDTH
        nav.centerlineTarget = lookaheadTarget 
        local target_mid_loc = node.location + (lookaheadTarget - closestPointData.point) 
        nav.lookaheadTargetLeft = target_mid_loc + perpVector * (halfWidth * (desired_bias_left - CAR_WIDTH_BIAS))
        nav.lookaheadTargetRight = target_mid_loc + perpVector * (halfWidth * (desired_bias_right + CAR_WIDTH_BIAS))
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
    local trackWidth = node.width
    local trackBias = nav.trackPositionBias 
    local halfWidth = trackWidth / 2
    wallData.marginLeft = (1.0 + trackBias) * halfWidth - CAR_HALF_WIDTH_ACTUAL 
    wallData.marginRight = (1.0 - trackBias) * halfWidth - CAR_HALF_WIDTH_ACTUAL
    local forwardNodeLocation = self:getPointInDistance(
        node, 
        nav.closestPointData.tOnSegment, 
        WALL_LOOKAHEAD_DIST, 
        self.chain
    )
    local closestPointForward = self:findClosestPointOnTrack(forwardNodeLocation, self.chain)
    if closestPointForward and closestPointForward.baseNode then
        local forwardLookaheadNode = closestPointForward.baseNode
        local forwardHalfWidth = forwardLookaheadNode.width / 2
        local forwardMid = forwardLookaheadNode.mid
        local forwardPerp = forwardLookaheadNode.perp:normalize()
        local offsetVector = forwardNodeLocation - forwardMid
        local forwardLateralOffset = offsetVector:dot(forwardPerp)
        local forwardBias = math.min(math.max(forwardLateralOffset / forwardHalfWidth, -1.0), 1.0)
        wallData.forwardMarginLeft = (1.0 + forwardBias) * forwardHalfWidth - CAR_HALF_WIDTH_ACTUAL
        wallData.forwardMarginRight = (1.0 - forwardBias) * forwardHalfWidth - CAR_HALF_WIDTH_ACTUAL
    else
        wallData.forwardMarginLeft = wallData.marginLeft
        wallData.forwardMarginRight = wallData.marginRight
    end
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