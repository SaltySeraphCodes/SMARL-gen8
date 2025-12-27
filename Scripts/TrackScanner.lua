-- TrackScanner.lua (Fixed & Merged)
dofile("globals.lua")

TrackScanner = class(nil)

-- [[ TUNING ]]
local SCAN_STEP_SIZE = 4.0
local SCAN_WIDTH_MAX = 80.0 
local WALL_SCAN_HEIGHT = 30.0 
local FLOOR_DROP_THRESHOLD = 1.5 
local SCAN_GRAIN = 0.5 
local MARGIN_SAFETY = 7.0
local JUMP_SEARCH_LIMIT = 20
local LOOP_Z_TOLERANCE = 6.0
SCAN_LIMIT = 1000 -- maximum nodes to search
-- [[ MODES ]]
local SCAN_MODE_RACE = 1
local SCAN_MODE_PIT = 2


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

-- --- CORE SCANNING UTILS ---


-- [[ 1. FALLBACK A: "Fan Scan" (Angle Down/Up) ]]
-- Adapted from Generator.getWallAngleDown
function TrackScanner.findWallAngleDown(self, origin, direction, lastDist)
    local searchLimit = math.max(15.0, lastDist + 5.0) -- Look a bit past where we expect the wall
    local zOffsetLimit = 7.0 
    local zStep = 0.5 
    local zOffsetStart = origin.z

    -- Scan from Top (+7) to Bottom (-7) relative to car height
    for k = zOffsetLimit, -zOffsetLimit, -zStep do 
        local targetPos = origin + (direction * searchLimit)
        targetPos.z = zOffsetStart + k -- Adjust target Z
        
        local hit, result = sm.physics.raycast(origin, targetPos)
        
        if hit then
            -- We hit something! Check if it's a valid wall (not floor)
            if result.normalWorld.z < 0.7 then
                return result.pointWorld, (result.pointWorld - origin):length()
            end
        end
    end
    return nil, nil
end

-- [[ 2. FALLBACK B: "Elevator Scan" (Flat then Up) ]]
-- Adapted from Generator.getWallFlatUp
function TrackScanner.findWallFlatUp(self, origin, direction, lastDist)
    local searchLimit = math.max(15.0, lastDist + 5.0)
    local zOffsetLimit = 7.0
    local zStep = 0.5
    
    -- First: Try straight flat
    local targetPos = origin + (direction * searchLimit)
    local hit, result = sm.physics.raycast(origin, targetPos)
    
    if hit and result.normalWorld.z < 0.7 then
         return result.pointWorld, (result.pointWorld - origin):length()
    end
    
    -- If flat failed, try lifting the target Z up gradually
    -- (Good for walls that might be slightly above us in a tunnel)
    for k = zStep, zOffsetLimit, zStep do
        local elevatedTarget = targetPos + sm.vec3.new(0, 0, k)
        hit, result = sm.physics.raycast(origin, elevatedTarget)
        
        if hit and result.normalWorld.z < 0.7 then
            return result.pointWorld, (result.pointWorld - origin):length()
        end
    end
    
    return nil, nil
end


function TrackScanner.findWallSweep(self, origin, direction, upVector, lastDist, centerFloorZ, debugName)
    local PAD = 6
    local GRAIN = 0.2
    local STEP_THRESHOLD = 0.40
    local TUNNEL_THRESHOLD = 5.0 -- How much of a difference to flag a tunnel check.
    
    local startSearch = math.max(2.0, lastDist - PAD)
    local endSearch = math.min(40.0, lastDist + PAD)
    -- FORCE WIDE: If lastDist is huge (flagged by main loop), reset search
    if lastDist > 50.0 then 
        startSearch = 2.0 
        endSearch = 40.0
    end
    -- Override: If we lost the wall previously (lastDist is huge/default), scan everything
    if lastDist > 30.0 then startSearch = 2.0 end
   
    local runningFloorZ = centerFloorZ
    -- STAGE 1: TOP-DOWN SWEEP
    for dist = startSearch, endSearch, GRAIN do
        local checkPos = origin + (direction * dist)
        
        -- [[ REQUESTED RAYCAST: +30 to -5 ]]
        -- We cast from high up to catch top-of-hills, and go down to find dips.
        local rayStart = checkPos + (upVector * 30.0)
        local rayEnd   = checkPos - (upVector * 10.0) 
        
        local hit, result = sm.physics.raycast(rayStart, rayEnd)
        
        if hit then
            local hitZ = result.pointWorld.z
            local normZ = result.normalWorld.z
            local diff = hitZ - runningFloorZ 
            local absDiff = math.abs(diff)
            local bumpDif = math.abs(hitZ-runningFloorZ) -- check for up and down difference
            -- [[ ANALYSIS ]]
            
            -- [[ CHECK A: GROUND WALL (Curb/Step Up) ]]
            -- Must be facing UP (Norm > 0.7)
            -- Must be a STEP UP (diff > Threshold). Ignore Dips (diff < 0).
            if normZ > 0.7 and diff > STEP_THRESHOLD and diff < TUNNEL_THRESHOLD then
                print("Hit Ground Wall (Curb)", normZ, hitZ, runningFloorZ,iteration)
                return result.pointWorld, dist
            end

            -- [[ CHECK B: VERTICAL WALL ]]
            -- Must be facing SIDEWAYS (Norm <= 0.7)
            -- Must be higher than the floor (diff > Threshold)
            if normZ <= 0.7 and diff > STEP_THRESHOLD and diff < TUNNEL_THRESHOLD then
                print("Hit Vertical Wall", normZ, hitZ, runningFloorZ,iteration)
                return result.pointWorld, dist
            end
            
            -- [[ CHECK C: VALID FLOOR UPDATE ]]
            -- If it's not a wall, is it valid floor?
            -- It must not be a ceiling (diff < TUNNEL)
            -- We update running Z to handle slopes/dips
            if absDiff < TUNNEL_THRESHOLD then
                 -- If it's a massive drop, be careful, but generally update floor
                 -- Use a slight Lerp or hard set? Hard set is better for steps.
                 runningFloorZ = hitZ
            end
        else
            -- Hit Nothing (Void).
            -- If scanning -5.0 isn't deep enough for your hills, increase rayEnd to -10.0
        end
    end

    -- STAGE 2: FALLBACKS (If Top-Down failed to return)
    -- Try the "Fan Scan" (Center -> Out/Down)
    local p, d = self:findWallAngleDown(origin, direction, lastDist)
    if p then return p, d end

    -- Try the "Elevator Scan" (Center -> Out/Up)
    p, d = self:findWallFlatUp(origin, direction, lastDist)
    if p then return p, d end

    -- Total Failure
    print("Find wall failed",iteration)
    return nil, nil
end

-- --- TRACK SCAN (LOOP) ---
function TrackScanner.scanTrackLoop(self, startPos, startDir)
    self.rawNodes = {}
    local currentPos = startPos
    local currentDir = startDir:normalize()
    
    local iterations = 0
    local loopClosed = false
    
    -- Memory
    local prevLeftDist = 10.0
    local prevRightDist = 10.0
    local GAP_TOLERANCE = 8.0 
    
    -- FORCE WIDE FLAGS: If we missed a wall, force the next scan to check everywhere
    local forceWideLeft = false
    local forceWideRight = false
    
    print("TrackScanner: Starting Safer Refined Scan...")

    while not loopClosed and iterations < 2000 do
        
        -- A. GROUND TRUTH (Snap First, Smooth Later)
        local floorZ = currentPos.z
        local groundHit, groundRes = sm.physics.raycast(currentPos + sm.vec3.new(0,0,30), currentPos - sm.vec3.new(0,0,10))
        if groundHit then
            if iterations == 0 then floorZ = groundRes.pointWorld.z -- Snap
            else floorZ = sm.util.lerp(currentPos.z, groundRes.pointWorld.z, 0.2) end -- Smooth
            currentPos = sm.vec3.new(currentPos.x, currentPos.y, floorZ + 0.1)
        end

        -- B. VECTORS
        local stableUp = sm.vec3.new(0,0,1)
        local rightVec = currentDir:cross(stableUp):normalize() * -1
        local leftVec = -rightVec

        -- [[ DEBUG: VISUALIZE VECTORS ]]
        -- Draw the direction we are about to scan (Only for the first few nodes to check orientation)
        if iterations < 5 then
            print("Drawing Debug Vectors for Node " .. iterations)
            -- LEFT = RED, RIGHT = BLUE
            self:spawnLine(currentPos, currentPos + (leftVec * 10), sm.color.new("ff0000")) 
            self:spawnLine(currentPos, currentPos + (rightVec * 10), sm.color.new("0000ff"))
        end

        -- [[ PASS 1: ROUGH SCAN ]]
        -- If forceWide is true, pass a huge 'lastDist' (999) to trigger the override in findWallSweep
        local searchL = forceWideLeft and 999.0 or prevLeftDist
        local searchR = forceWideRight and 999.0 or prevRightDist

        local lPos1, lDist1 = self:findWallSweep(currentPos, leftVec, stableUp, searchL, floorZ, "Pass1-L")
        local rPos1, rDist1 = self:findWallSweep(currentPos, rightVec, stableUp, searchR, floorZ, "Pass1-R")

        -- Handle Misses
        if lPos1 then forceWideLeft = false else 
            lPos1 = currentPos + (leftVec * prevLeftDist) -- Fake it
            forceWideLeft = true -- Missed! Next scan must be wide.
        end
        if rPos1 then forceWideRight = false else 
            rPos1 = currentPos + (rightVec * prevRightDist) -- Fake it
            forceWideRight = true -- Missed! Next scan must be wide.
        end

        -- [[ REFINEMENT DECISION ]]
        local finalMid, finalLeft, finalRight, finalWidth
        
        -- ONLY REFINE IF WE HIT BOTH WALLS
        -- If we missed one, refining will just center us between a Wall and a Fake Point (bad).
        if (not forceWideLeft) and (not forceWideRight) then
            -- 1. Calculate the 'Skew-Corrected' Geometry
            local tempMid = (lPos1 + rPos1) * 0.5
            local wallSpan = lPos1 - rPos1
            local refinedLeftVec = wallSpan:normalize()
            local refinedRightVec = -refinedLeftVec
            
            local hintDistL = (lPos1 - tempMid):length()
            local hintDistR = (rPos1 - tempMid):length()
            
            -- [[ PASS 2: REFINED SCAN ]]
            local lPos2, lDist2 = self:findWallSweep(tempMid, refinedLeftVec, stableUp, hintDistL, floorZ, "Refine-L")
            local rPos2, rDist2 = self:findWallSweep(tempMid, refinedRightVec, stableUp, hintDistR, floorZ, "Refine-R")
            
            -- Final Fallbacks (If Refine missed, revert to Pass 1 data)
            finalLeft = lPos2 or lPos1
            finalRight = rPos2 or rPos1
            
            if lPos2 and rPos2 then
                 finalMid = (lPos2 + rPos2) * 0.5
            else
                 finalMid = tempMid -- Refine failed, stick to calculated center
            end
        else
            -- SKIP REFINEMENT
            finalLeft = lPos1
            finalRight = rPos1
            finalMid = (lPos1 + rPos1) * 0.5
        end
        
        finalWidth = (finalLeft - finalRight):length()
        prevLeftDist = (finalLeft - finalMid):length()
        prevRightDist = (finalRight - finalMid):length()

        -- C. STEERING
        local nextDir = currentDir
        local stepSize = 4.0 
        
        if iterations > 0 then
            local prevNode = self.rawNodes[#self.rawNodes]
            if prevNode then
                local targetDir = (finalMid - prevNode.mid):normalize()
                local dot = currentDir:dot(targetDir)
                local turnAngle = math.deg(math.acos(math.max(-1, math.min(1, dot))))
                
                -- Dynamic Speed
                if turnAngle > 5.0 then stepSize = 2.0 end
                if turnAngle > 25.0 then stepSize = 1.5 end
                
                -- Steering Damping
                nextDir = sm.vec3.lerp(currentDir, targetDir, 0.3):normalize()
                if nextDir:dot(currentDir) < 0 then nextDir = currentDir end
                prevNode.outVector = nextDir
            end
        end

        -- D. SAVE
        table.insert(self.rawNodes, {
            id = iterations + 1, mid = finalMid, location = finalMid,
            leftWall = finalLeft, rightWall = finalRight, width = finalWidth,
            inVector = currentDir, outVector = nextDir, isJump = false
        })

        currentDir = nextDir
        currentPos = finalMid + (currentDir * stepSize)
        iterations = iterations + 1

        local distToStart = (currentPos - startPos):length()
        if iterations > 30 and distToStart < 15.0 then
            print("TrackScanner: Loop Closed.")
            loopClosed = true
            self.rawNodes[#self.rawNodes].outVector = (self.rawNodes[1].mid - self.rawNodes[#self.rawNodes].mid):normalize()
        end
    end
    self:calculateTrackDistances(self.rawNodes)
    return self.rawNodes
end
-- Two pass scan
function TrackScanner.scanTrackLoop_old(self, startPos, startDir)
    self.rawNodes = {}
    local currentPos = startPos
    local currentDir = startDir:normalize()
    local currentUp = sm.vec3.new(0, 0, 1) 
    
    local iterations = 0
    local loopClosed = false
    
    -- Memory
    local prevLeftDist = 10.0
    local prevRightDist = 10.0
    local GAP_TOLERANCE = 8.0 
    
    print("TrackScanner: Starting 2-Pass Refined Scan...")

    while not loopClosed and iterations < SCAN_LIMIT do
        
        -- A. GROUND TRUTH (Find Z)
        local floorZ = currentPos.z
        local groundHit, groundRes = sm.physics.raycast(currentPos + sm.vec3.new(0,0,5), currentPos - sm.vec3.new(0,0,5))
        if groundHit then
            local hitZ = groundRes.pointWorld.z
            
            if iterations == 0 then
                -- [[ CRITICAL FIX: SNAP START ]]
                -- On the very first node, ignore smoothing. Snap EXACTLY to the floor.
                -- This ensures our baseline 'centerFloorZ' is perfect for the first wall sweep.
                floorZ = hitZ
            else
                -- [[ SHOCK ABSORBER ]]
                -- For the rest of the track, smooth out bumps (20% correction)
                floorZ = sm.util.lerp(currentPos.z, hitZ, 0.2) -- Check this...
            end
            
            -- Update position (hover 0.1 above floor)
            currentPos = sm.vec3.new(currentPos.x, currentPos.y, floorZ + 0.1)
        else
            -- Scan Failed (Void?) - Maintain previous Z or Drop
            print("Center Floor Scan Missed!")
        end

        -- B. INITIAL VECTORS (Guess based on travel direction)
        local stableUp = sm.vec3.new(0,0,1)
        local rightVec = currentDir:cross(stableUp):normalize() * -1
        local leftVec = -rightVec

        -- [[ PASS 1: ROUGH SCAN ]]
        local lPos1, lDist1 = self:findWallSweep(currentPos, leftVec, stableUp, prevLeftDist, floorZ,iterations)
        local rPos1, rDist1 = self:findWallSweep(currentPos, rightVec, stableUp, prevRightDist, floorZ,iterations)

        -- Pass 1 Fallbacks (Crucial for vector math)
        if not lPos1 then lPos1 = currentPos + (leftVec * prevLeftDist) end
        if not rPos1 then rPos1 = currentPos + (rightVec * prevRightDist) end

        -- [[ REFINEMENT STEP ]]
        -- 1. Calculate the 'Skew-Corrected' Center
        local tempMid = (lPos1 + rPos1) * 0.5
        
        -- 2. Calculate the 'Skew-Corrected' Perpendicular Vectors
        -- The vector connecting RightWall -> LeftWall is the perfect width line.
        local wallSpan = lPos1 - rPos1
        local spanLen = wallSpan:length()
        
        -- Safety: If track is impossibly narrow (<1.0), skip refinement to avoid math errors
        local finalMid, finalLeft, finalRight, finalWidth
        
        if spanLen > 1.0 then
            local refinedLeftVec = wallSpan:normalize()
            local refinedRightVec = -refinedLeftVec
            
            -- [[ PASS 2: REFINED SCAN ]]
            -- Scan again from the NEW center, along the NEW perfect vectors.
            -- We use the distance from Pass 1 as the hint.
            local hintDistL = (lPos1 - tempMid):length()
            local hintDistR = (rPos1 - tempMid):length()
            
            local lPos2, lDist2 = self:findWallSweep(tempMid, refinedLeftVec, stableUp, hintDistL, floorZ,iterations)
            local rPos2, rDist2 = self:findWallSweep(tempMid, refinedRightVec, stableUp, hintDistR, floorZ,iterations)
            
            -- Pass 2 Fallbacks
            if not lPos2 then lPos2 = tempMid + (refinedLeftVec * hintDistL) end
            if not rPos2 then rPos2 = tempMid + (refinedRightVec * hintDistR) end
            
            -- Finalize Data
            finalLeft = lPos2
            finalRight = rPos2
            finalMid = (lPos2 + rPos2) * 0.5
            finalWidth = (lPos2 - rPos2):length()
            
            -- Update Distance Memory (using refined distances)
            prevLeftDist = (lPos2 - finalMid):length()
            prevRightDist = (rPos2 - finalMid):length()
        else
            -- Skip refinement if Pass 1 failed badly
            finalMid = tempMid
            finalLeft = lPos1
            finalRight = rPos1
            finalWidth = spanLen
            prevLeftDist = lDist1 or prevLeftDist
            prevRightDist = rDist1 or prevRightDist
        end

        -- C. STEERING & ADVANCE
        local nextDir = currentDir
        local stepSize = 5
        
        if iterations > 0 then
            local prevNode = self.rawNodes[#self.rawNodes] -- Get last saved node
            if prevNode then
                local targetDir = (finalMid - prevNode.mid):normalize()
                
                -- Turn Severity
                local dot = currentDir:dot(targetDir)
                local turnAngle = math.deg(math.acos(math.max(-1, math.min(1, dot))))
                -- Dynamic Speed
                if turnAngle > 5.0 then stepSize = 3 end
                if turnAngle > 25.0 then stepSize = 2 end
                print("TA",turnAngle,stepSize)

                nextDir = sm.vec3.lerp(currentDir, targetDir, 0.6):normalize()
                
                -- Anti-Reverse
                if nextDir:dot(currentDir) < 0 then nextDir = currentDir end
                
                prevNode.outVector = nextDir
            end
        end

        -- D. SAVE NODE
        table.insert(self.rawNodes, {
            id = iterations + 1,
            mid = finalMid,
            location = finalMid,
            leftWall = finalLeft,
            rightWall = finalRight,
            width = finalWidth,
            inVector = currentDir,
            outVector = nextDir,
            isJump = false,
            -- [[ ADD THESE FOR DEBUGGING ]]
            debugLeftVec = leftVec,   -- The direction we looked for the Left Wall
            debugRightVec = rightVec, -- The direction we looked for the Right Wall
        })

        -- E. ADVANCE
        currentDir = nextDir
        currentPos = finalMid + (currentDir * stepSize)
        iterations = iterations + 1

        -- F. LOOP CLOSURE
        local distToStart = (currentPos - startPos):length()
        if iterations > 30 and distToStart < stepSize + 5 then
            print("TrackScanner: Loop Closed.")
            loopClosed = true
            self.rawNodes[#self.rawNodes].outVector = (self.rawNodes[1].mid - self.rawNodes[#self.rawNodes].mid):normalize()
        end
    end
    if iterations >= SCAN_LIMIT then
        print("Somethihng went wrong or track too long")
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
            local prev = nodes[i-1]
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
    table.sort(sortedBoxes, function(a,b) 
        return (a.shape:getWorldPosition() - startLoc):length() < (b.shape:getWorldPosition() - startLoc):length() 
    end)
    for _, box in ipairs(sortedBoxes) do table.insert(keyPoints, box) end

    if PIT_ANCHORS.exit then table.insert(keyPoints, PIT_ANCHORS.exit) end
    table.insert(keyPoints, PIT_ANCHORS.endPoint)

    -- 2. Scan Segments
    local nodeIdCounter = 1

    for i = 1, #keyPoints - 1 do
        local startObj = keyPoints[i]
        local endObj = keyPoints[i+1]

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
            local hit, res = sm.physics.raycast(currentPos + sm.vec3.new(0,0,5), currentPos - sm.vec3.new(0,0,5))
            if hit then currentPos = res.pointWorld end

            self:addPitNode(nodes, nodeIdCounter, currentPos, segmentDir, nil)
            nodeIdCounter = nodeIdCounter + 1
        end
    end

    -- Add Final Node
    self:addPitNode(nodes, nodeIdCounter, PIT_ANCHORS.endPoint.shape:getWorldPosition(), PIT_ANCHORS.endPoint.shape:getAt(), PIT_ANCHORS.endPoint)

    self.pitChain = nodes
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
        perp = dir:cross(sm.vec3.new(0,0,1)):normalize(),
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
    if count < 3 then --or count >= SCAN_LIMIT then 
        print("Skipping Optimizations") return end

    local MARGIN = MARGIN_SAFETY or 6.0
    local STEP_SIZE = 0.7  -- Increased from 0.2 (Faster movement)
    
    -- [[ 1. FILL GAPS ]]
    nodes = self:fillGaps(nodes, 6.0)
    count = #nodes 

    print("TrackScanner: Optimizing ("..iterations.." passes) - AGGRESSIVE Mode...")

    local totalMovement = 0

    -- [[ 2. OPTIMIZATION LOOP ]]
    for iter = 1, iterations do
        local iterMovement = 0
        for i = 1, count do
            local node = nodes[i]
            
            if not node.isJump and node.leftWall and node.rightWall then 
                local prev = nodes[(i - 2) % count + 1]
                local next = nodes[(i % count) + 1]

                local wallVec = node.rightWall - node.leftWall
                local trackWidth = wallVec:length()
                local wallDir = wallVec:normalize()

                -- Current Position
                local currentDist = (node.location - node.leftWall):dot(wallDir)
                
                -- Test Candidates (Wider steps)
                local pCurrent = node.location
                local pLeft    = node.location - (wallDir * STEP_SIZE)
                local pRight   = node.location + (wallDir * STEP_SIZE)

                local rCurrent = self:getLocalRadius(prev.location, pCurrent, next.location)
                local rLeft    = self:getLocalRadius(prev.location, pLeft, next.location)
                local rRight   = self:getLocalRadius(prev.location, pRight, next.location)

                -- Move towards larger radius
                local move = 0.0
                if rLeft > rCurrent and rLeft > rRight then 
                    move = -STEP_SIZE
                elseif rRight > rCurrent and rRight > rLeft then 
                    move = STEP_SIZE
                end
                
                -- Apply Move
                if move ~= 0 then
                    local newDist = currentDist + move
                    -- Hard Clamp to Margin
                    if newDist < MARGIN then newDist = MARGIN end
                    if newDist > (trackWidth - MARGIN) then newDist = trackWidth - MARGIN end
                    
                    local newPos = node.leftWall + (wallDir * newDist)
                    
                    -- Track how much we actually moved for debugging
                    iterMovement = iterMovement + (newPos - node.location):length()
                    node.location = newPos
                end
            end
        end
        totalMovement = totalMovement + iterMovement
    end
    
    print("TrackScanner: Optimization Complete. Total Node Movement: " .. math.floor(totalMovement))

    -- [[ 3. LIGHT SMOOTHING ]]
    -- We only do 1 pass now. 5 passes was washing out the apex.
    self:smoothPositions(nodes, 1)

    -- [[ 4. FINALIZE ]]
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
        if i <= sectorSize then nodes[i].sectorID = 1
        elseif i <= sectorSize * 2 then nodes[i].sectorID = 2
        else nodes[i].sectorID = 3 end
    end
end

function TrackScanner.snapChainToFloor(self, nodes)
    for i, node in ipairs(nodes) do
        local rayStart = node.location + sm.vec3.new(0, 0, 5.0)
        local rayEnd = node.location - sm.vec3.new(0, 0, 10.0)
        local hit, res = sm.physics.raycast(rayStart, rayEnd)
        if hit then node.location = res.pointWorld + sm.vec3.new(0, 0, 0.5) end
    end
end

function TrackScanner.resampleChain(self, nodes, minDistance)
    print("TrackScanner: Resampling nodes (Min Dist: "..minDistance..")...")
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
    -- If Start and End are far apart (>20m), assume it's Open.
    local isLoop = (nodes[1].location - nodes[count].location):length() < 20.0

    for i = 1, count do
        local node = nodes[i]
        local nextNode = nil

        if i < count then
            nextNode = nodes[i + 1]
        elseif isLoop then
            nextNode = nodes[1] -- Wrap around for loops
        else
            -- Open Chain (Pit): Project forward based on previous direction
            local prev = nodes[i-1] or nodes[1]
            local dir = (node.location - prev.location):normalize()
            -- Create a fake target 5m ahead so the vector stays straight
            nextNode = { 
                location = node.location + (dir * 5.0), 
                mid = node.mid + (dir * 5.0) 
            }
        end
        
        -- 1. Racing Vector
        node.outVector = (nextNode.location - node.location):normalize()
        
        -- 2. Center Vector (for perpendiculars)
        local midDir = (nextNode.mid - node.mid):normalize()
        local nodeUp = node.upVector or sm.vec3.new(0,0,1)
        
        -- 3. Perpendicular (Points to the side of the track)
        node.perp = midDir:cross(nodeUp):normalize() 
    end
end

function TrackScanner.vecToTable(self, vec)
    if not vec then return {x=0, y=0, z=0} end
    return { x = vec.x, y = vec.y, z = vec.z }
end

function TrackScanner.tableToVec(self, t)
    if not t then return sm.vec3.new(0,0,0) end
    return sm.vec3.new(t.x, t.y, t.z)
end

function TrackScanner.serializeTrackData(self)
    local raceNodes = {}
    local pitNodes = {}
    
    local function serializeChain(chain, targetTable)
        for i, node in ipairs(chain) do
            table.insert(targetTable, {
                id = node.id,
                -- Send all three key positions
                pos = self:vecToTable(node.location), -- Racing Line
                mid = self:vecToTable(node.mid),      -- Center Line
                left = self:vecToTable(node.leftWall), -- Raw Wall Hit
                right = self:vecToTable(node.rightWall), -- Raw Wall Hit
                width = node.width,
                dist = node.distFromStart,
                bank = node.bank,
                isJump = node.isJump
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

function TrackScanner.serializeTrackData_old(self)
    local raceNodes = {}
    local pitNodes = {}
    
    local function serializeChain(chain, targetTable)
        for i, node in ipairs(chain) do
            local dataNode = {
                id = node.id,
                pos = self:vecToTable(node.location), -- THE OPTIMIZED LINE
                mid = self:vecToTable(node.mid),      -- THE CENTER LINE
                width = node.width,
                dist = node.distFromStart,   -- Distance in meters
                prog = node.raceProgress,    -- Normalized 0.0-1.0
                bank = node.bank,
                incline = node.incline,
                out = self:vecToTable(node.outVector),
                perp = self:vecToTable(node.perp),
                isJump = node.isJump,
                sectorID = node.sectorID,
                pointType = node.pointType 
            }
            table.insert(targetTable, dataNode)
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

function TrackScanner.sv_saveToStorage(self)
    print("TrackScanner: Saving to World Storage...")
    local data = self:serializeTrackData()
    sm.storage.save(TRACK_DATA_CHANNEL, data)
    self.network:sendToClients("cl_showAlert", "Track Saved!")
end

function TrackScanner.sv_loadFromStorage(self)
    local data = sm.storage.load(TRACK_DATA_CHANNEL)
    if data then
        print("TrackScanner: Loaded Map Data.")
        -- Deserialize logic if needed, but usually we just start fresh scans
        -- If you want to visualize immediately on load:
        self.nodeChain = {} -- (Reconstruct from data if needed)
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
    if self.scanMode == SCAN_MODE_RACE then self.scanMode = SCAN_MODE_PIT
    else self.scanMode = SCAN_MODE_RACE end
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
    -- CASE 1: START
    if data.type == "start" then
        if data.chain == "race" then
            self.clientTrackData = {} -- Clear local cache
        end

    -- CASE 2: BATCH (Store data, don't draw yet)
    elseif data.type == "batch" then
        if not self.clientTrackData then self.clientTrackData = {} end
        for _, node in ipairs(data.nodes) do
            table.insert(self.clientTrackData, node)
        end
        -- Update viz incrementally
        self:redrawVisualization() 
    end
end

function TrackScanner.redrawVisualization(self)
    self:clearDebugEffects() -- or clearDebugParts()
    if not self.clientTrackData then return end
    
    local STEP = 4 -- Skip nodes to save FPS
    
    for i = 1, #self.clientTrackData, STEP do
        local node = self.clientTrackData[i]
        
        if self.visMode == 3 then -- Skeleton/Debug Mode
            -- 1. Center Dot
            self:spawnDot(node.mid, sm.color.new("00ffffff"))
            
            -- 2. Wall Dots
            self:spawnDot(node.leftWall, sm.color.new("ff0000ff"),"1f334b62-8955-4406-8848-91e03228c330") -- Red traffic cone for left
            self:spawnDot(node.rightWall, sm.color.new("0000ffff"),"4f1c0036-389b-432e-81de-8261cb9f9d57") -- Blue  pipe corner for right
            
            -- 3. [[ DIRECTION VISUALIZATION ]]
            -- Draw a line 5 units long showing where the scanner was pointing
            if node.debugLeftVec and node.debugRightVec then
                local lStart = node.mid
                local lEnd   = node.mid + (node.debugLeftVec * 5.0)
                
                local rStart = node.mid
                local rEnd   = node.mid + (node.debugRightVec * 5.0)
                
                -- LEFT = RED LINE
                self:spawnLine(lStart, lEnd, sm.color.new("ff0000ff"),"add3acc6-a6fd-44e8-a384-a7a16ce13c81") -- idk
                
                -- RIGHT = BLUE LINE
                self:spawnLine(rStart, rEnd, sm.color.new("0000ffff"),"add3acc6-a6fd-44e8-a384-a7a16ce13c81") -- Sensor
            end
            
        else
            -- Normal Mode
            self:spawnDot(node.pos, sm.color.new("00ff00ff"))
        end
    end
end

-- NEW HELPER: Draw Lines
function TrackScanner.spawnLine(self, startPos, endPos, color, uuid)
    if not startPos or not endPos then return end
    
    -- SM doesn't have a native "Line" effect, so we simulate it with dots
    -- or use the "Shape - Pipe" effect if available, but dots are safer.
    local p1 = sm.vec3.new(startPos.x, startPos.y, startPos.z)
    local p2 = sm.vec3.new(endPos.x, endPos.y, endPos.z)
    local dist = (p1 - p2):length()
    local dir = (p2 - p1):normalize()
    
    -- Draw 5 dots along the line
    for d = 0, dist, (dist/5) do
        local p = p1 + (dir * d)
        local effect = sm.effect.createEffect("Loot - GlowItem")
        effect:setScale(sm.vec3.new(0.1, 0.1, 0.1)) -- Small dots for lines
        effect:setPosition(p)
        effect:setParameter("uuid", sm.uuid.new(uuid or "4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
        effect:setParameter("Color", color)
        effect:start()
        table.insert(self.debugEffects, effect)
    end
end

function TrackScanner.spawnDot(self, posTable, color,uuid)
    if not posTable then return end
    local effect = sm.effect.createEffect("Loot - GlowItem")
    effect:setScale(sm.vec3.new(0.2,0.2,0.2))
    effect:setPosition(sm.vec3.new(posTable.x, posTable.y, posTable.z))
    effect:setParameter("uuid", sm.uuid.new(uuid or "4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    effect:setParameter("Color", color)
    effect:start()
    table.insert(self.debugEffects, effect)
end

function TrackScanner.cl_visEvent_old(self, data)
    -- Initialize container if missing
    if not self.debugEffects then self.debugEffects = {} end
    
    -- CASE 1: START (Clear previous effects)
    if data.type == "start" then
        if data.chain == "race" then
            -- Clear everything when race scan starts to prevent ghosts
            for _, effect in ipairs(self.debugEffects) do 
                if effect and sm.exists(effect) then effect:destroy() end 
            end
            self.debugEffects = {}
        end
        
    -- CASE 2: BATCH (Add new effects)
    elseif data.type == "batch" then
        local color = sm.color.new("00ff00") -- Green (Race)
        if data.chain == "pit" then color = sm.color.new("ff00ff") end -- Pink (Pit)
        
        for _, nodeData in ipairs(data.nodes) do
            -- Create Effect
            local effect = sm.effect.createEffect("Loot - GlowItem")
            effect:setScale(sm.vec3.new(0,0,0)) 
            
            -- Handle key mismatch (pos vs location)
            local p = nodeData.pos or nodeData.location or {x=0,y=0,z=0}
            effect:setPosition(sm.vec3.new(p.x, p.y, p.z))
            
            effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
            effect:setParameter("Color", color)
            effect:start()
            
            table.insert(self.debugEffects, effect)
        end
    end
end

function TrackScanner.cl_showAlert(self, msg)
    sm.gui.displayAlertText(msg, 3)
end