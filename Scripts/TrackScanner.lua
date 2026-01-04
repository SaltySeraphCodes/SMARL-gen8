-- TrackScanner.lua (Fixed & Merged)
dofile("globals.lua")

TrackScanner = class(nil)

-- [[ TUNING ]]
local SCAN_STEP_SIZE = 4.0
local SCAN_WIDTH_MAX = 80.0
local WALL_SCAN_HEIGHT = 30.0
local FLOOR_DROP_THRESHOLD = 1.5
local SCAN_GRAIN = 0.5
local MARGIN_SAFETY = 6
local JUMP_SEARCH_LIMIT = 20
local LOOP_Z_TOLERANCE = 6.0
SCAN_LIMIT = 1000 -- maximum nodes to search
-- [[ MODES ]]
local SCAN_MODE_RACE = 1
local MAX_SCAN_LENGTH = 1000


-- [[ CONFIGURATION ]]
local SCAN_STEP_DEFAULT = 4.0   -- Standard distance between nodes
local SCAN_STEP_TURN = 2.0      -- Distance between nodes in sharp turns
local SWEEP_GRAIN = 0.5         -- precision of the wall search (0.5 blocks)
local SWEEP_SEARCH_WIDTH = 10.0 -- How far to search relative to previous wall (optimization)
local MAX_TRACK_WIDTH = 40.0    -- Absolute max width to scan
local WALL_HEIGHT_THRESH = 0.5  -- Min height difference to count as a wall

function TrackScanner.server_onCreate(self) self:server_init() end

function TrackScanner.client_onCreate(self) self:client_init() end

function TrackScanner.server_onRefresh(self) self:server_init() end

function TrackScanner.client_onRefresh(self)
    self:clearDebugEffects()
    self:client_init()
end

function TrackScanner.client_onDestroy(self)
    self:clearDebugEffects()
end

function TrackScanner.server_init(self)
    self.rawNodes = {}
    self.nodeChain = {}
    self.pitChain = {}
    self.scanMode = SCAN_MODE_RACE
    self.isScanning = false
    self.debugEffects = {}
    -- Try to load existing data if available
    self:sv_loadFromStorage()
    self.network:setClientData({ mode = self.scanMode })
end

function TrackScanner.client_init(self)
    self.rawNodes = {}
    self.debugEffects = {}
    self.scanning = false
    self.debug = false
    -- VISUALIZATION MODES:
    -- 1 = Racing Line (Green)
    -- 2 = Center Line (Blue)
    -- 3 = Debug Skeleton (Red Walls + Blue Center)
    self.visMode = 1

    -- Saved data for redrawing without re-fetching
    self.clientTrackData = nil
end

function TrackScanner.getCurvature(self, p1, p2, p3)
    local r = self:getLocalRadius(p1, p2, p3)
    if r > 1000.0 then return 0.0001 end -- Treat almost straight as effectively 0 curvature
    return 1.0 / r
end

-- --- CORE SCANNING UTILS ---

-- [[ 1. FALLBACK A: "Fan Scan" (Angle Down/Up) - RELAXED ]]
function TrackScanner.findWallAngleDown(self, origin, direction, lastDist)
    local searchLimit = math.max(20.0, lastDist + 10.0)
    local zOffsetLimit = 5.0
    local zStep = 1.0
    local zOffsetStart = origin.z

    for k = zOffsetLimit, -zOffsetLimit, -zStep do
        local targetPos = origin + (direction * searchLimit)
        targetPos.z = zOffsetStart + k

        local hit, result = sm.physics.raycast(origin, targetPos)
        if hit and result.normalWorld.z < 0.8 then -- Relaxed normal check
            return result.pointWorld, (result.pointWorld - origin):length()
        end
    end
    return nil, nil
end

-- [[ 2. FALLBACK B: "Elevator Scan" (Flat then Up) - RELAXED ]]
function TrackScanner.findWallFlatUp(self, origin, direction, lastDist)
    local searchLimit = math.max(20.0, lastDist + 10.0)
    local zOffsetLimit = 5.0
    local zStep = 1.0

    for k = 0, zOffsetLimit, zStep do
        local targetPos = origin + (direction * searchLimit) + sm.vec3.new(0, 0, k)
        local hit, result = sm.physics.raycast(origin, targetPos)
        if hit and result.normalWorld.z < 0.8 then
            return result.pointWorld, (result.pointWorld - origin):length()
        end
    end
    return nil, nil
end

-- [[ 3. MAIN SENSOR: Combined Sweep (FIXED) ]]
-- [[ 3. MAIN SENSOR: Combined Sweep (FIXED HEIGHT) ]]
function TrackScanner.findWallSweep(self, origin, direction, upVector, lastDist, debugName)
    local GRAIN = 0.2 -- Finer grain for precision
    local PAD = 10.0

    local startSearch = math.max(2.0, lastDist - PAD)
    local endSearch = math.min(MAX_TRACK_WIDTH, lastDist + PAD)

    if lastDist > (MAX_TRACK_WIDTH - 5) then
        startSearch = 2.0
        endSearch = MAX_TRACK_WIDTH
    end

    for dist = startSearch, endSearch, GRAIN do
        local checkPos    = origin + (direction * dist)

        -- Scan Segment
        local rayStart    = checkPos + (upVector * 10)
        local rayEnd      = checkPos - (upVector * 10)

        local hit, result = sm.physics.raycast(rayStart, rayEnd)

        if hit then
            local dot = result.normalWorld:dot(upVector)

            -- HIT CONDITION: Wall (Vertical) OR Curb (Step Up)
            local isWall = dot < 0.5
            local isCurb = false
            if not isWall then
                local heightDiff = (result.pointWorld - origin):dot(upVector)
                if heightDiff > 0.75 then isCurb = true end
            end

            if isWall or isCurb then
                -- [[ REFINEMENT STEP: FIND FLOOR HEIGHT ]]
                -- We hit the wall face. Now we want the Z-height of the ROAD at the base of this wall.
                -- Strategy: Move 0.75m away from the wall (back towards track) and raycast DOWN.

                local wallNormal = result.normalWorld
                -- If it's a curb (flat top), use the scan direction reversed
                if isCurb then wallNormal = -direction end

                -- Move slightly into the track
                local probePos   = result.pointWorld + (wallNormal * 0.35)

                -- Raycast relative DOWN
                local floorStart = probePos + (upVector * 2.0)
                local floorEnd   = probePos - (upVector * 4.0)
                local fHit, fRes = sm.physics.raycast(floorStart, floorEnd)

                local finalPoint = result.pointWorld

                if fHit then
                    -- Project the wall point onto the floor plane we just found
                    -- Logic: Keep X/Y of wall hit, but adopt Z (height) of the floor hit (relative to UpVector)

                    -- Calculate vertical distance between WallHit and FloorHit
                    local vDiff = (fRes.pointWorld - finalPoint):dot(upVector)

                    -- Shift WallHit to match Floor Height
                    finalPoint = finalPoint + (upVector * vDiff)
                end

                return finalPoint, dist
            end
        end
    end

    return nil, nil
end

-- --- TRACK SCAN (LOOP) FIXED ---
function TrackScanner.scanTrackLoop(self, startPos, startDir)
    self.rawNodes = {}

    -- Initialize State
    local currentPos = startPos
    local currentDir = startDir:normalize()
    local currentUp = sm.vec3.new(0, 0, 1) -- Starts global, updates to terrain

    local iterations = 0
    local loopClosed = false

    -- Smart Memory
    local runningWidth = 20.0 -- Default guess
    local prevLeftDist = 10.0
    local prevRightDist = 10.0

    print("TrackScanner: Starting Surface-Aligned Scan...")

    while not loopClosed and iterations < SCAN_LIMIT do
        -- A. GROUND TRUTH (Orient to Floor)
        -- Raycast down relative to our CURRENT Up vector, not global Z.
        local floorRayStart = currentPos + (currentUp * 2.0)
        local floorRayEnd = currentPos - (currentUp * 5.0)

        local hitFloor, resFloor = sm.physics.raycast(floorRayStart, floorRayEnd)

        if hitFloor then
            -- 1. Snap Position to floor (No Lerp - eliminates height inconsistency)
            currentPos = resFloor.pointWorld + (resFloor.normalWorld * 0.5) -- Hover 0.5m

            -- 2. Update Orientation (Smoothly blend normal to handle loops/corks)
            -- We blend 50% to avoid jitter on bumpy terrain
            currentUp = sm.vec3.lerp(currentUp, resFloor.normalWorld, 0.5):normalize()
        else
            -- Gravity fallback: If we fly off a ramp, slowly rotate back to global Z
            currentUp = sm.vec3.lerp(currentUp, sm.vec3.new(0, 0, 1), 0.1):normalize()
        end

        -- B. CALCULATE VECTORS (Relative to Surface)
        local rightVec = currentDir:cross(currentUp):normalize()
        local leftVec = -rightVec

        -- [[ PASS 1: SCAN ]]
        local lPos, lDist = self:findWallSweep(currentPos, leftVec, currentUp, prevLeftDist, "L")
        local rPos, rDist = self:findWallSweep(currentPos, rightVec, currentUp, prevRightDist, "R")

        -- [[ PASS 2: CALCULATE CENTER (The Anti-Skew Fix) ]]
        local finalMid = currentPos
        local validWidth = false

        if lPos and rPos then
            -- BEST CASE: Both walls found.
            finalMid = (lPos + rPos) * 0.5
            runningWidth = (lPos - rPos):length() -- Update known width
            prevLeftDist = lDist
            prevRightDist = rDist
            validWidth = true
        elseif lPos and not rPos then
            -- LEFT ONLY: Project center using known width
            -- "If I see the left wall at 5m, and track is 20m wide, center is 5m + 10m to the right"
            finalMid = lPos + (rightVec * (runningWidth * 0.5))
            prevLeftDist = lDist
            -- Don't update runningWidth, use memory
        elseif rPos and not lPos then
            -- RIGHT ONLY
            finalMid = rPos + (leftVec * (runningWidth * 0.5))
            prevRightDist = rDist
        else
            -- BLIND: Maintain course
            finalMid = currentPos + (currentDir * SCAN_STEP_SIZE)
        end

        -- C. STEERING
        local nextDir = currentDir

        if iterations > 0 then
            local prevNode = self.rawNodes[#self.rawNodes]
            if prevNode then
                -- Calculate direction to new center
                local targetDir = (finalMid - prevNode.mid):normalize()

                -- Smoothing: Don't snap instantly, or one bad node creates a zigzag.
                -- Blend 50% current direction, 50% target.
                nextDir = sm.vec3.lerp(currentDir, targetDir, 0.5):normalize()

                -- Re-orthogonalize to ensure we don't drift into the ground
                -- (Make sure nextDir is perpendicular to Up)
                local side = nextDir:cross(currentUp)
                nextDir = currentUp:cross(side):normalize()

                prevNode.outVector = nextDir
            end
        end

        local truePerp = (rPos - lPos):normalize()

        -- D. SAVE NODE
        table.insert(self.rawNodes, {
            id = iterations + 1,
            mid = finalMid,
            location = finalMid,
            leftWall = lPos,
            rightWall = rPos,
            width = runningWidth,

            -- Vectors
            inVector = currentDir,
            outVector = nextDir,
            upVector = currentUp,
            perp = truePerp, -- [[ NEW: Saved instantly for reference ]]

            -- Debug
            debugLeft = leftVec,
            debugRight = rightVec,

            isJump = false
        })

        -- E. ADVANCE
        currentDir = nextDir
        currentPos = finalMid + (currentDir * SCAN_STEP_SIZE)
        iterations = iterations + 1

        -- Loop Closure Check
        local distToStart = (currentPos - startPos):length()
        if iterations > 30 and distToStart < 10.0 then
            print("TrackScanner: Loop Closed.")
            loopClosed = true
            -- Link last node to first
            self.rawNodes[#self.rawNodes].outVector = (self.rawNodes[1].mid - self.rawNodes[#self.rawNodes].mid)
            :normalize()
        end
    end

    self:calculateTrackDistances(self.rawNodes)
    return self.rawNodes
end

function TrackScanner.calculateTrackDistances(self, nodes)
    local totalDist = 0.0

    -- 1. First Pass: Calculate Distances
    for i, node in ipairs(nodes) do
        if i == 1 then
            node.distFromStart = 0.0
        else
            local prev = nodes[i - 1]
            -- Measure distance along the CENTER line (mid), not the racing line
            local segDist = (node.mid - prev.mid):length()
            totalDist = totalDist + segDist
            node.distFromStart = totalDist
        end
    end

    -- Store total length on the scanner for reference
    self.trackLength = totalDist
    print("TrackScanner: Calculated Track Length: " .. string.format("%.2f", totalDist) .. "m")

    -- 2. Second Pass: Normalize (0.0 - 1.0)
    for _, node in ipairs(nodes) do
        node.raceProgress = node.distFromStart / totalDist
    end
end

-- --- PIT LANE SCAN (ANCHOR BASED) ---

function TrackScanner.scanPitLaneFromAnchors(self)
    print("TrackScanner: Starting Anchor-Based Pit Scan...")

    if not PIT_ANCHORS.start or not PIT_ANCHORS.endPoint then
        print("Error: Missing Pit Start (Green) or Pit End (Red) anchors!")
        self.network:sendToClients("cl_showAlert", "Missing Start/End Anchors!")
        return
    end

    local nodes = {}

    -- 1. Gather Key Points in Order
    local keyPoints = {}
    table.insert(keyPoints, PIT_ANCHORS.start)
    if PIT_ANCHORS.entry then table.insert(keyPoints, PIT_ANCHORS.entry) end

    -- Sort Pit Boxes by distance from Start
    local startLoc = PIT_ANCHORS.start.shape:getWorldPosition()
    local sortedBoxes = {}
    for _, box in ipairs(PIT_ANCHORS.boxes) do table.insert(sortedBoxes, box) end
    table.sort(sortedBoxes, function(a, b)
        return (a.shape:getWorldPosition() - startLoc):length() < (b.shape:getWorldPosition() - startLoc):length()
    end)
    for _, box in ipairs(sortedBoxes) do table.insert(keyPoints, box) end

    if PIT_ANCHORS.exit then table.insert(keyPoints, PIT_ANCHORS.exit) end
    table.insert(keyPoints, PIT_ANCHORS.endPoint)

    -- 2. Scan Segments
    local nodeIdCounter = 1

    for i = 1, #keyPoints - 1 do
        local startObj = keyPoints[i]
        local endObj = keyPoints[i + 1]

        local startPos = startObj.shape:getWorldPosition()
        local endPos = endObj.shape:getWorldPosition()

        local segmentDir = (endPos - startPos):normalize()
        local segmentDist = (endPos - startPos):length()
        local steps = math.floor(segmentDist / SCAN_STEP_SIZE)

        -- Add Start Anchor Node
        self:addPitNode(nodes, nodeIdCounter, startPos, segmentDir, startObj)
        nodeIdCounter = nodeIdCounter + 1

        -- Add Intermediate Nodes
        for s = 1, steps do
            local currentPos = startPos + (segmentDir * (s * SCAN_STEP_SIZE))

            -- Raycast to stick to floor
            local hit, res = sm.physics.raycast(currentPos + sm.vec3.new(0, 0, 5), currentPos - sm.vec3.new(0, 0, 5))
            if hit then currentPos = res.pointWorld end

            self:addPitNode(nodes, nodeIdCounter, currentPos, segmentDir, nil)
            nodeIdCounter = nodeIdCounter + 1
        end
    end

    -- Add Final Node
    self:addPitNode(nodes, nodeIdCounter, PIT_ANCHORS.endPoint.shape:getWorldPosition(),
        PIT_ANCHORS.endPoint.shape:getAt(), PIT_ANCHORS.endPoint)

    self.pitChain = nodes

    -- [[ NEW: Auto-Link Pit Exit to Main Track ]]
    -- We assume the main track is already scanned in self.rawNodes or self.nodeChain
    local mainTrack = self.nodeChain
    if not mainTrack or #mainTrack == 0 then mainTrack = self.rawNodes end

    if mainTrack and #mainTrack > 0 then
        local pitEnd = nodes[#nodes]
        local bestNode = nil
        local minDst = math.huge

        -- Find the closest main track node to the pit exit anchor
        for _, mainNode in ipairs(mainTrack) do
            local dist = (mainNode.location - pitEnd.location):length()
            if dist < minDst then
                minDst = dist
                bestNode = mainNode
            end
        end

        if bestNode then
            -- Save the Main Node ID into the Pit Node
            pitEnd.mergeTargetIndex = bestNode.id
            print("TrackScanner: Auto-Linked Pit Exit to Main Node " .. bestNode.id)
        else
            print("TrackScanner: Warning - Could not link Pit Exit (Main track too far?)")
        end
    end

    print("TrackScanner: Pit Scan Complete. Nodes: " .. #nodes)
end

function TrackScanner.addPitNode(self, nodeList, id, pos, dir, sourceObj)
    local pType = 0
    if sourceObj then
        if sourceObj.pointType then pType = sourceObj.pointType end
        if sourceObj.boxDimensions then pType = 5 end -- PitBox
    end

    local node = {
        id = id,
        location = pos,
        mid = pos,
        width = 15.0,
        outVector = dir,
        perp = dir:cross(sm.vec3.new(0, 0, 1)):normalize(),
        bank = 0,
        incline = 0,
        sectorID = 4,
        pointType = pType
    }
    table.insert(nodeList, node)
end

-- --- OPTIMIZER ---
function TrackScanner.optimizeRacingLine(self, iterations, isPit)
    local nodes = isPit and self.pitChain or self.rawNodes
    local count = #nodes
    if count < 3 then return end

    local MARGIN = MARGIN_SAFETY or 7 -- Keep 3.0 blocks from the walls
    local TENSION = 0.5               -- How aggressive the "string" pulls tight (0.1 = loose/slow, 0.8 = snaps instantly)

    -- 1. Fill Gaps
    nodes = self:fillGaps(nodes, 6.0)
    count = #nodes

    -- [[ FIX: PRE-SMOOTH ]]
    -- User requested smoothing BEFORE optimization to prevent false curvature spikes
    self:smoothPositions(nodes, 2)

    print("TrackScanner: Optimizing (" .. iterations .. " passes) using Out-In-Out Logic...")

    local totalMovement = 0
    local TENSION = 0.4 -- [FIX] Reduced tension slightly

    -- 2. OPTIMIZATION LOOP
    for iter = 1, iterations do
        local iterMovement = 0

        for i = 1, count do
            local node = nodes[i]

            if not node.isJump and node.leftWall and node.rightWall then
                local prev = nodes[(i - 2) % count + 1]
                local next = nodes[(i % count) + 1]

                -- A. FIND THE "IDEAL" SPOT
                -- The shortest path is a straight line between Prev and Next.
                local idealPoint = (prev.location + next.location) * 0.5

                -- B. PROJECT ONTO TRACK WIDTH
                -- We only want to move the node Laterally (Left/Right), not forward/backward.
                -- We project the 'idealPoint' onto the line connecting LeftWall -> RightWall.
                local wallVec = node.rightWall - node.leftWall
                local wallLenSq = wallVec:length() * wallVec:length() -- Length Squared for projection math

                if wallLenSq > 0.1 then
                    local wallDir = wallVec:normalize()

                    -- Vector from Left Wall to the Ideal Point
                    local toIdeal = idealPoint - node.leftWall

                    -- Project to find "T" (0.0 = Left Wall, 1.0 = Right Wall)
                    local t = toIdeal:dot(wallVec) / wallLenSq

                    -- [[ FIX: OUT-IN-OUT LOGIC ]]
                    -- Calculate Curvature Direction
                    local dirIn = (node.location - prev.location):normalize()
                    local dirOut = (next.location - node.location):normalize()
                    local crossZ = dirIn:cross(dirOut).z -- +Left, -Right

                    local curveMag = math.abs(crossZ)

                    -- Heuristic:
                    -- High Curvature (> 0.10) = Apex -> Let it hug Inside (Shortest Path)
                    -- Low Curvature (< 0.10) = Entry/Exit -> Push Outside

                    if curveMag < 0.12 and curveMag > 0.001 then
                        -- Identify Outside Wall T
                        -- If Turning Left (+Z), Outside is Right (T=1.0)
                        -- If Turning Right (-Z), Outside is Left (T=0.0)
                        local t_outside = (crossZ > 0) and 1.0 or 0.0

                        -- Push Strength: Stronger on straighter sections (Entry), weaker near apex
                        local push = 0.15 * (1.0 - (curveMag / 0.12))

                        -- Blend 't' towards outside
                        t = t + (t_outside - t) * push
                    end

                    -- C. APPLY MARGINS (Clamp T)
                    -- Convert margin (e.g. 3.0) to a percentage of width
                    local marginPct = MARGIN / math.sqrt(wallLenSq)
                    if marginPct > 0.45 then marginPct = 0.45 end -- Safety if track is tiny

                    if t < marginPct then t = marginPct end
                    if t > (1.0 - marginPct) then t = 1.0 - marginPct end

                    -- D. MOVE THE NODE
                    -- Calculate the actual Target Position in world space
                    local targetPos = node.leftWall + (wallVec * t)

                    -- Move current location towards target based on Tension
                    local moveVec = (targetPos - node.location) * TENSION

                    -- Apply
                    node.location = node.location + moveVec
                    iterMovement = iterMovement + moveVec:length()
                end
            end
        end
        totalMovement = totalMovement + iterMovement

        -- Early Exit if the string is tight
        if iter > 5 and iterMovement < 1.0 then
            print("TrackScanner: Converged early at iteration " .. iter)
            break
        end
    end

    print("TrackScanner: Optimization Complete. Total Movement: " .. math.floor(totalMovement))

    -- 3. FINALIZE
    self:smoothPositions(nodes, 2)
    nodes = self:resampleChain(nodes, 3.0)
    self:calculateTrackDistances(nodes)
    self:snapChainToFloor(nodes)
    self:assignSectors(nodes)
    self:recalculateNodeProperties(nodes)

    if isPit then self.pitChain = nodes else self.nodeChain = nodes end
    self:sv_saveToStorage()
end

-- Update helper to accept 'passes' argument
function TrackScanner.smoothPositions(self, nodes, passes)
    passes = passes or 1
    local count = #nodes
    for pass = 1, passes do
        for i = 1, count do
            local prev = nodes[(i - 2) % count + 1]
            local curr = nodes[i]
            local next = nodes[(i % count) + 1]

            -- Simple average
            local avgPos = (prev.location + curr.location + next.location) / 3.0

            -- Blend: 70% Original, 30% Average (Preserve the sharp corners!)
            curr.location = sm.vec3.lerp(curr.location, avgPos, 0.3)
        end
    end
end

-- NEW: Function to fill gaps caused by scanner jumps
function TrackScanner.fillGaps(self, nodes, maxDistance)
    local filledNodes = {}
    local count = #nodes

    for i = 1, count do
        local curr = nodes[i]
        local next = nodes[(i % count) + 1]

        table.insert(filledNodes, curr)

        -- Don't fill gap if it's the loop closure warp
        if i == count and (curr.location - next.location):length() > 50 then
            -- Do nothing
        else
            local dist = (curr.location - next.location):length()
            if dist > maxDistance then
                local steps = math.ceil(dist / 4.0)
                for s = 1, steps - 1 do
                    local t = s / steps
                    -- Interpolate
                    local iLoc = sm.vec3.lerp(curr.location, next.location, t)
                    local iMid = sm.vec3.lerp(curr.mid, next.mid, t)
                    local iLeft = sm.vec3.lerp(curr.leftWall, next.leftWall, t)
                    local iRight = sm.vec3.lerp(curr.rightWall, next.rightWall, t)

                    local newNode = {
                        id = curr.id + (t * 0.1),
                        location = iLoc,
                        mid = iMid,
                        leftWall = iLeft,
                        rightWall = iRight,
                        width = (iLeft - iRight):length(),
                        isJump = curr.isJump,
                        sectorID = curr.sectorID,
                        outVector = curr.outVector,
                        upVector = curr.upVector,
                        bank = curr.bank,
                        incline = curr.incline
                    }
                    table.insert(filledNodes, newNode)
                end
            end
        end
    end
    print("TrackScanner: Filled Gaps. Count: " .. count .. " -> " .. #filledNodes)
    return filledNodes
end

function TrackScanner.getLocalRadius(self, p1, p2, p3)
    local v1 = p2 - p1
    local v2 = p3 - p2
    v1.z = 0; v2.z = 0
    local L1 = v1:length()
    local L2 = v2:length()
    local chord = (p3 - p1):length()
    local s = (L1 + L2 + chord) * 0.5
    local areaSq = s * (s - L1) * (s - L2) * (s - chord)
    if areaSq <= 0.001 then return 10000.0 end
    local area = math.sqrt(areaSq)
    return (L1 * L2 * chord) / (4.0 * area)
end

function TrackScanner.assignSectors(self, nodes)
    local count = #nodes
    local sectorSize = math.floor(count / 3)
    for i = 1, count do
        if i <= sectorSize then
            nodes[i].sectorID = 1
        elseif i <= sectorSize * 2 then
            nodes[i].sectorID = 2
        else
            nodes[i].sectorID = 3
        end
    end
end

function TrackScanner.snapChainToFloor(self, nodes)
    print("TrackScanner: Snapping all nodes to floor...")
    for i, node in ipairs(nodes) do
        -- 1. Snap the RACING LINE (location)
        local rayStart = node.location + sm.vec3.new(0, 0, 5.0)
        local rayEnd = node.location - sm.vec3.new(0, 0, 10.0)
        local hit, res = sm.physics.raycast(rayStart, rayEnd)

        if hit then
            -- Hover 0.25 above ground to prevent Z-fighting
            node.location = res.pointWorld + sm.vec3.new(0, 0, 0.25)

            -- Also align the banking (Up Vector) to this hit
            if node.upVector then
                node.upVector = sm.vec3.lerp(node.upVector, res.normalWorld, 0.5):normalize()
            end
        end

        -- 2. Snap the CENTER LINE (mid)
        -- We do a separate raycast because the center might be on a different slope/height
        local midStart = node.mid + sm.vec3.new(0, 0, 5.0)
        local midEnd = node.mid - sm.vec3.new(0, 0, 10.0)
        local hitMid, resMid = sm.physics.raycast(midStart, midEnd)

        if hitMid then
            node.mid = resMid.pointWorld + sm.vec3.new(0, 0, 0.25)
        else
            -- If raycast misses (e.g. center is over a hole), align Z with the racing line
            node.mid.z = node.location.z
        end
    end
end

function TrackScanner.resampleChain(self, nodes, minDistance)
    print("TrackScanner: Resampling nodes (Min Dist: " .. minDistance .. ")...")
    if #nodes < 2 then return nodes end
    local cleanNodes = {}
    table.insert(cleanNodes, nodes[1])
    local lastKeptNode = nodes[1]

    for i = 2, #nodes do
        local currentNode = nodes[i]
        local dist = (currentNode.location - lastKeptNode.location):length()
        -- Keep nodes that are far enough apart OR special nodes
        if dist >= minDistance then
            table.insert(cleanNodes, currentNode)
            lastKeptNode = currentNode
        end
    end
    print("TrackScanner: Resample complete. " .. #nodes .. " -> " .. #cleanNodes)
    return cleanNodes
end

function TrackScanner.recalculateNodeProperties(self, nodes)
    local count = #nodes
    -- Detect if this is a closed loop (Race) or open chain (Pit)
    local isLoop = (nodes[1].mid - nodes[count].mid):length() < 20.0

    for i = 1, count do
        local node = nodes[i]
        local nextNode = nil

        if i < count then
            nextNode = nodes[i + 1]
        elseif isLoop then
            nextNode = nodes[1] -- Wrap around for loops
        else
            -- Open Chain (Pit): Project forward
            local prev = nodes[i - 1] or nodes[1]
            local dir = (node.mid - prev.mid):normalize()
            nextNode = { mid = node.mid + (dir * 5.0), location = node.location + (dir * 5.0) }
        end

        -- 1. Racing Vector (Where the car should aim)
        -- This IS based on the racing line (location), because that's the path we want to drive.
        node.outVector = (nextNode.location - node.location):normalize()

        -- 2. Track Direction (For calculating the slice)
        -- This MUST be based on the center line (mid) to keep the slice consistent.
        local trackDir = (nextNode.mid - node.mid):normalize()
        local nodeUp = node.upVector or sm.vec3.new(0, 0, 1)

        -- 3. Perpendicular (Points to the side of the track)
        -- "Right" relative to the track center.
        node.perp = trackDir:cross(nodeUp):normalize()
    end
end

function TrackScanner.vecToTable(self, vec)
    if not vec then return { x = 0, y = 0, z = 0 } end
    return { x = vec.x, y = vec.y, z = vec.z }
end

function TrackScanner.tableToVec(self, t)
    if not t then return sm.vec3.new(0, 0, 0) end
    return sm.vec3.new(t.x, t.y, t.z)
end

function TrackScanner.serializeTrackData(self)
    local raceNodes = {}
    local pitNodes = {}

    local function serializeChain(chain, targetTable)
        for i, node in ipairs(chain) do
            table.insert(targetTable, {
                id = node.id,
                -- 1. GEOMETRY (Vectors as tables)
                pos = self:vecToTable(node.location),    -- Racing Line (Legacy name 'pos' for compatibility)
                mid = self:vecToTable(node.mid),         -- Center Line
                left = self:vecToTable(node.leftWall),   -- Left Wall Anchor
                right = self:vecToTable(node.rightWall), -- Right Wall Anchor

                -- 2. VECTORS (Critical for AI)
                perp = self:vecToTable(node.perp),     -- The "Rail" direction (Side-to-Side)
                out = self:vecToTable(node.outVector), -- The Forward direction

                -- 3. METADATA (From serializeTrackData_old)
                width = node.width,
                dist = node.distFromStart, -- Distance in meters
                prog = node.raceProgress,  -- Normalized 0.0-1.0
                bank = node.bank or 0.0,
                incline = node.incline or 0.0,
                isJump = node.isJump,
                sectorID = node.sectorID or 1,
                pointType = node.pointType or 0, -- 0=Normal, 2=PitEntry, 5=PitBox, etc.
                mergeIndex = node.mergeTargetIndex
            })
        end
    end

    serializeChain(self.nodeChain, raceNodes)
    serializeChain(self.pitChain, pitNodes)

    return {
        timestamp = os.time(),
        raceChain = raceNodes,
        pitChain = pitNodes
    }
end

function TrackScanner.deserializeChain(self, savedChain)
    if not savedChain then return {} end
    local restoredNodes = {}

    for _, data in ipairs(savedChain) do
        -- Restore Vectors
        local midVec   = self:tableToVec(data.mid)
        local locVec   = self:tableToVec(data.pos) -- Saved as 'pos', runtime uses 'location'
        local leftVec  = self:tableToVec(data.left)
        local rightVec = self:tableToVec(data.right)
        local outVec   = self:tableToVec(data.out)
        local perpVec  = self:tableToVec(data.perp)

        -- Rebuild Node
        local node     = {
            id = data.id,
            mid = midVec,
            location = locVec,
            leftWall = leftVec,
            rightWall = rightVec,

            -- Restore Vectors if they existed, else we'll recalc later
            outVector = outVec,
            perp = perpVec,
            upVector = sm.vec3.new(0, 0, 1), -- Default, will be fixed by snap

            -- Metadata
            width = data.width,
            distFromStart = data.dist,
            raceProgress = data.prog,
            bank = data.bank,
            incline = data.incline,
            isJump = data.isJump,
            sectorID = data.sectorID or 1,
            pointType = data.pointType or 0,
            mergeTargetIndex = data.mergeIndex
        }
        table.insert(restoredNodes, node)
    end

    return restoredNodes
end

function TrackScanner.sv_saveToStorage(self)
    print("TrackScanner: Saving to World Storage...")
    local data = self:serializeTrackData()
    sm.storage.save(TRACK_DATA_CHANNEL, data)
    self.network:sendToClients("cl_showAlert", "Track Saved!")
end

function TrackScanner.sv_loadFromStorage(self)
    local data = sm.storage.load(TRACK_DATA_CHANNEL)

    if data and data.raceChain then
        print("TrackScanner: Found saved track data (" .. #data.raceChain .. " nodes). Loading...")

        -- 1. Deserialize Chains
        self.nodeChain = self:deserializeChain(data.raceChain)
        self.pitChain = self:deserializeChain(data.pitChain)

        -- 2. Restore State to 'self.rawNodes'
        -- (The optimizer usually works on rawNodes, so we populate it with the loaded race chain)
        self.rawNodes = self.nodeChain

        -- 3. Recalculate Metadata
        -- This regenerates the outVectors, perps, and distances required for the AI
        self:recalculateNodeProperties(self.nodeChain)
        self:calculateTrackDistances(self.nodeChain)
        self:assignSectors(self.nodeChain)

        if self.pitChain and #self.pitChain > 0 then
            self:recalculateNodeProperties(self.pitChain)
            self:calculateTrackDistances(self.pitChain)
        end

        print("TrackScanner: Load Complete. Track Length: " .. string.format("%.1f", self.trackLength or 0))

        -- 4. Sync to Clients (Visualization)
        self:sv_sendVis()
    else
        print("TrackScanner: No saved track data found.")
    end
end

-- --- INTERACTION / CONTROLS ---


function TrackScanner.client_canInteract(self, character)
    -- Default to Race Mode if data hasn't synced yet
    local mode = self.clientScanMode or SCAN_MODE_RACE
    local modeText = (mode == SCAN_MODE_PIT) and "PIT LANE" or "RACE TRACK"

    -- Interaction: Start Scan
    sm.gui.setInteractionText("Start Scan:", sm.gui.getKeyBinding("Use", true), modeText)

    -- Tinker: Switch Mode
    sm.gui.setInteractionText("Switch Mode:", sm.gui.getKeyBinding("Tinker", true), "(Race / Pit)")

    return true
end

function TrackScanner.client_onInteract(self, character, state)
    if state then
        -- Simple "Press E to Scan". No crouching needed anymore.
        self.network:sendToServer("sv_startScan")
    end
end

function TrackScanner.client_canTinker(self, character)
    return true
end

function TrackScanner.client_onTinker(self, character, state)
    if state then
        if character:isCrouching() then
            -- Cycle Modes: 1 -> 2 -> 3 -> 1
            self.visMode = self.visMode + 1
            if self.visMode > 3 then self.visMode = 1 end

            local modeNames = { "RACING LINE", "CENTER LINE", "DEBUG SKELETON" }
            sm.gui.displayAlertText("View: " .. modeNames[self.visMode], 2)

            -- Trigger a redraw using the last known data
            if self.clientTrackData then
                self:redrawVisualization()
            end

            sm.audio.play("PaintTool - ColorPick", self.shape:getWorldPosition())
        else
            self.network:sendToServer("sv_switchMode")
            sm.audio.play("PaintTool - ColorPick", self.shape:getWorldPosition())
        end
    end
end

function TrackScanner.sv_startScan(self)
    if self.isScanning then
        self.isScanning = false
        print("Stopping Scan...")
    else
        self.isScanning = true
        local shape = self.shape
        local pos = shape:getWorldPosition()
        local dir = shape:getAt()

        if self.scanMode == SCAN_MODE_RACE then
            print("Starting Race Scan...")
            self:scanTrackLoop(pos, dir)
            self:optimizeRacingLine(1000, false)
            self:sv_sendVis()
        elseif self.scanMode == SCAN_MODE_PIT then
            print("Starting Pit Scan...")
            self:scanPitLaneFromAnchors()
            -- Optimize for 0 iterations.
            -- Why 0? Because Pit Nodes have no walls, so we skip the
            -- wall-bouncing physics but keep the gap-filling and math fixes.
            self:optimizeRacingLine(0, true)
            self:sv_sendVis()
        end
        self.isScanning = false
    end
end

function TrackScanner.sv_switchMode(self)
    if self.scanMode == SCAN_MODE_RACE then
        self.scanMode = SCAN_MODE_PIT
    else
        self.scanMode = SCAN_MODE_RACE
    end
    self.network:sendToClients("cl_showAlert", "Mode: " .. (self.scanMode == 1 and "RACE" or "PIT"))
end

function TrackScanner.sv_sendVis(self)
    local data = self:serializeTrackData()

    -- Helper to chunk and send data
    local function sendBatches(chain, chainType)
        if not chain then return end
        local batchSize = 50 -- Safe limit (approx 20kb per packet)

        -- 1. Send Start Signal (Clears old effects on client)
        self.network:sendToClients("cl_visEvent", { type = "start", chain = chainType })

        -- 2. Send Chunks
        local currentBatch = {}
        for i, node in ipairs(chain) do
            table.insert(currentBatch, node)
            if #currentBatch >= batchSize then
                self.network:sendToClients("cl_visEvent", { type = "batch", chain = chainType, nodes = currentBatch })
                currentBatch = {}
            end
        end

        -- 3. Send Remainder
        if #currentBatch > 0 then
            self.network:sendToClients("cl_visEvent", { type = "batch", chain = chainType, nodes = currentBatch })
        end
    end
    sendBatches(data.raceChain, "race")
    sendBatches(data.pitChain, "pit")
end

-- --- VISUALIZATION ---
function TrackScanner.getVizData(self, chain)
    local vizData = {}
    for _, node in ipairs(chain) do
        -- Create a minimal object: { l = location, t = type }
        -- This discards walls, vectors, width, banks, etc.
        table.insert(vizData, {
            l = node.location,
            t = node.pointType or 0
        })
    end
    return vizData
end

-- HELPER: centralized cleanup
function TrackScanner.clearDebugEffects(self)
    if self.debugEffects then
        for _, effect in ipairs(self.debugEffects) do
            if effect and sm.exists(effect) then effect:destroy() end
        end
    end
    self.debugEffects = {}
end

function TrackScanner.cl_visEvent(self, data)
    -- HELPER: Convert {x,y,z} table back to sm.vec3
    local function toVec3(t)
        if not t then return nil end
        return sm.vec3.new(t.x, t.y, t.z)
    end

    -- CASE 1: START
    if data.type == "start" then
        if data.chain == "race" then
            self.clientTrackData = {} -- Clear local cache
        end

        -- CASE 2: BATCH (Convert & Store)
    elseif data.type == "batch" then
        if not self.clientTrackData then self.clientTrackData = {} end

        for _, rawNode in ipairs(data.nodes) do
            local node = {
                id = rawNode.id,

                -- Convert all vectors needed for visualization
                mid = toVec3(rawNode.mid),
                pos = toVec3(rawNode.pos),     -- Racing Line
                left = toVec3(rawNode.left),   -- Left Wall
                right = toVec3(rawNode.right), -- Right Wall

                -- Debug Vectors (Only present during live scan, not save/load)
                -- We use 'perp' to reconstruct debug lines if debugLeft/Right are missing
                perp = toVec3(rawNode.perp),

                debugLeft = toVec3(rawNode.debugLeft),
                debugRight = toVec3(rawNode.debugRight)
            }

            -- Fallback: If live debug vectors are missing (loaded from file), create them from perp
            if not node.debugLeft and node.perp then
                node.debugLeft = node.perp * -1 -- Left is usually -Perp
                node.debugRight = node.perp     -- Right is +Perp
            end

            table.insert(self.clientTrackData, node)
        end

        -- Update viz
        self:redrawVisualization()
    end
end

function TrackScanner.redrawVisualization(self)
    self:clearDebugEffects() -- or clearDebugParts()
    if not self.clientTrackData then return end

    local STEP = 4 -- Skip nodes to save FPS

    for i = 1, #self.clientTrackData, STEP do
        local node = self.clientTrackData[i]

        if self.visMode == 3 then                                                                      -- Skeleton/Debug Mode
            -- 1. Center Dot
            self:spawnDot(node.mid, sm.color.new("00ffffff"))                                          -- light blue mid?
            -- 2. Wall Dots
            self:spawnDot(node.left, sm.color.new("ff0080ff"), "1f334b62-8955-4406-8848-91e03228c330") -- Red traffic cone for left
            self:spawnDot(node.right, sm.color.new("8000ffff"), "4f1c0036-389b-432e-81de-8261cb9f9d57") -- Blue  pipe corner for right

            -- 3. [[ DIRECTION VISUALIZATION ]]
            -- Draw a line 5 units long showing where the scanner was pointing
            if node.debugLeft and node.debugRight then
                local lStart = node.mid
                local lEnd   = node.mid + (node.debugLeft * 5)

                local rStart = node.mid
                local rEnd   = node.mid + (node.debugRight * 5)

                -- LEFT = RED LINE
                self:spawnLine(lStart, lEnd, sm.color.new("ff0000ff"), "add3acc6-a6fd-44e8-a384-a7a16ce13c81") -- sensor

                -- RIGHT = BLUE LINE
                self:spawnLine(rStart, rEnd, sm.color.new("000ffff"), "add3acc6-a6fd-44e8-a384-a7a16ce13c81") -- Sensor
            end
        else
            -- Normal Mode
            self:spawnDot(node.pos, sm.color.new("00ff00ff"))
        end
    end
end

function TrackScanner.spawnLine(self, startPos, endPos, color, uuid)
    if not startPos or not endPos then return end

    -- Draw 5 dots to simulate a line
    local dist = (startPos - endPos):length()
    local dir = (endPos - startPos):normalize()
    local steps = 3

    for i = 0, steps do
        local p = startPos + (dir * (dist * (i / steps)))
        self:spawnDot(p, color, uuid)
    end
end

function TrackScanner.spawnDot(self, pos, color, uuid)
    if not pos then return end -- Safety check

    local effect = sm.effect.createEffect("Loot - GlowItem")
    effect:setScale(sm.vec3.new(0.2, 0.2, 0.2))
    effect:setPosition(pos)

    -- Default to the "Blue Dot" UUID if none provided
    local effectUUID = uuid or "4a1b886b-913e-4aad-b5b6-6e41b0db23a6"
    effect:setParameter("uuid", sm.uuid.new(effectUUID))

    effect:setParameter("Color", color)
    effect:start()
    table.insert(self.debugEffects, effect)
end

function TrackScanner.cl_showAlert(self, msg)
    sm.gui.displayAlertText(msg, 3)
end
