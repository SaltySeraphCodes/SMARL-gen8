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

function TrackScanner.findFloorPoint(self, origin, upVector)
    -- Scan from a bit lower (5.0) to avoid hitting low ceilings as 'floor'
    local scanStart = origin + (upVector * 5.0)
    local scanEnd = origin - (upVector * 20.0)
    local hit, result = sm.physics.raycast(scanStart, scanEnd)
    if hit then return result.pointWorld, result.normalWorld end
    return nil, nil
end

function TrackScanner.findWallTopDown(self, origin, direction, upVector, floorZ)
    local perpLimit = SCAN_WIDTH_MAX
    local startOffset = 2.0 
    for k = startOffset, perpLimit, SCAN_GRAIN do
        local scanPos = origin + (direction * k)
        local rayStart = scanPos + (upVector * WALL_SCAN_HEIGHT)
        local rayEnd = scanPos - (upVector * WALL_SCAN_HEIGHT) 
        local hit, result = sm.physics.raycast(rayStart, rayEnd)
        if hit then
            local hitHeight = result.pointWorld.z
            local heightDiff = math.abs(hitHeight - floorZ)
            if heightDiff > FLOOR_DROP_THRESHOLD then
                local wallFaceSearchStart = origin + (direction * (k - SCAN_GRAIN)) + (upVector * 0.5)
                local wallFaceSearchEnd = origin + (direction * (k + SCAN_GRAIN)) + (upVector * 0.5)
                local hitFace, resFace = sm.physics.raycast(wallFaceSearchStart, wallFaceSearchEnd)
                if hitFace then return resFace.pointWorld else return nil end
            end
            if heightDiff < 0.8 then floorZ = hitHeight end
        else
            return origin + (direction * (k - SCAN_GRAIN))
        end
    end
    return nil
end

function TrackScanner.findWallFlat(self, origin, direction, upVector)
    local scanStart = origin + (upVector * 1.5) 
    local scanEnd = origin + (direction * SCAN_WIDTH_MAX)
    local hit, result = sm.physics.raycast(scanStart, scanEnd)
    if hit then return result.pointWorld end
    return nil
end

function TrackScanner.findWallPoint(self, origin, direction, upVector)
    -- [[ FIX: WIDER CONE SEARCH ]]
    -- Increased angle to 35 degrees to catch walls in sharp hairpins
    local bestPoint = nil
    local minDst = 999.0
    
    -- Check 5 angles: Center, +/- 15, +/- 35
    local angles = { 0, 15, -15, 35, -35 } 
    
    for _, ang in ipairs(angles) do
        local rot = sm.quat.angleAxis(math.rad(ang), upVector)
        local scanDir = rot * direction
        
        -- 1. Try Top-Down (Best for barriers)
        local floorZ = origin.z
        local p = self:findWallTopDown(origin, scanDir, upVector, floorZ)
        
        -- 2. Fallback to Flat Raycast
        if not p then 
            p = self:findWallFlat(origin, scanDir, upVector) 
        end
        
        -- Keep the CLOSEST valid wall hit
        if p then
            local dst = (p - origin):length()
            if dst < minDst then
                minDst = dst
                bestPoint = p
            end
        end
    end
    
    return bestPoint
end

function TrackScanner.findWallStrict(self, origin, direction, upVector, floorZ)
    -- [[ CONFIG ]]
    local SCAN_LIMIT = 30.0     
    local SCAN_GRAIN = 0.5      -- 0.5 is precise enough (0.25 is overkill/slow)
    local currentFloorZ = floorZ
    
    local dist = 2.0 
    
    while dist < SCAN_LIMIT do
        local checkPos = origin + (direction * dist)
        
        -- Ray 1: Top-Down (The "Drone" View)
        -- We scan from high up to see what is below us
        local rayStart = checkPos + (upVector * 5.0) 
        local rayEnd = checkPos - (upVector * 5.0) -- Scan deep to find floor on down-slopes
        
        local hit, result = sm.physics.raycast(rayStart, rayEnd)
        
        if hit then
            -- [[ DEBUG PRINT: MICRO ]]
            -- We only print if we are close to the car (dist < 10) to reduce spam
            -- and only for the first few checks
            if dist < 10.0 then
                local type = (result.normalWorld.z > 0.6) and "FLOOR" or "WALL"
                local diff = result.pointWorld.z - currentFloorZ
                print(string.format("   -> Scan @ %.1f | HitZ: %.1f (FloorZ: %.1f) | Diff: %.1f | NormZ: %.2f | Type: %s", 
                    dist, result.pointWorld.z, currentFloorZ, diff, result.normalWorld.z, type))
            end
            -- [[ ANALYSIS ]]
            local hitHeight = result.pointWorld.z
            local normalZ = result.normalWorld.z
            
            -- Is this surface "Walkable"? (Pointing Up)
            if normalZ > 0.6 then
                -- IT IS FLOOR (Banked or Flat)
                -- We do NOT stop. We update our reference height and keep going.
                currentFloorZ = hitHeight
            else
                -- IT IS A WALL (Vertical-ish)
                -- Check: Is it actually higher than our current floor level?
                -- (Prevents detecting the edge of a divot as a wall)
                if hitHeight > (currentFloorZ + 0.25) then
                    return result.pointWorld
                end
            end
        else
            -- [[ VOID DETECTION ]]
            -- We hit nothing. We stepped off the edge of the world.
            -- For a race track, the "Edge" is the wall.
            -- return checkPos -- Uncomment to treat Void as Wall (good for floating tracks)
        end
        
        dist = dist + SCAN_GRAIN
    end

    -- STAGE 2: Safety Check (Flat Ray)
    -- Only runs if we found nothing above (e.g. Tunnel Ceiling blocked top-down)
    local flatStart = origin + (upVector * 1.0)
    local flatEnd = origin + (direction * SCAN_LIMIT)
    local hit, result = sm.physics.raycast(flatStart, flatEnd)
    if hit and result.normalWorld.z < 0.6 then
        return result.pointWorld
    end

    return nil
end

function TrackScanner.findWallSweep(self, origin, direction, upVector, lastDist, floorZ)
    local SCAN_START = math.max(2.0, lastDist - 5.0) 
    local SCAN_LIMIT = 35.0
    local GRAIN = 0.5     
    
    -- [[ FIX: INCREASE THRESHOLD ]]
    -- A wall must be at least 0.75 blocks higher than the track center to count.
    -- This ignores small bumps, curbs, and cambers.
    local THRESHOLD = 0.75 
    
    local currentFloorZ = floorZ

    for dist = SCAN_START, SCAN_LIMIT, GRAIN do
        local checkPos = origin + (direction * dist)
        
        -- Raycast from SKY down to GROUND
        local rayStart = checkPos + (upVector * 5.0)
        local rayEnd = checkPos - (upVector * 5.0) 
        
        local hit, result = sm.physics.raycast(rayStart, rayEnd)
        
        if hit then
            local hitZ = result.pointWorld.z
            local normZ = result.normalWorld.z
            
            -- [[ FIX: STRICT FILTER ]]
            -- 1. Is it a Vertical Wall? (Normal is horizontal)
            -- 2. AND is it actually sticking up out of the ground?
            local isVertical = normZ < 0.5
            local isTallEnough = hitZ > (floorZ + THRESHOLD)

            if isVertical and isTallEnough then
                return result.pointWorld, dist
            end
            
            -- Case B: High Barrier / Fence (Non-vertical but high)
            if hitZ > (floorZ + 1.5) then
                return result.pointWorld, dist
            end
            
            -- If not a wall, assume it is floor and update Z for next step
            -- (But constrain it so it doesn't climb walls)
            if math.abs(hitZ - floorZ) < 1.0 then
                currentFloorZ = hitZ
            end
        end
    end

    -- STAGE 2: HORIZONTAL FALLBACK
    local flatStart = origin + (upVector * 1.0)
    local flatEnd = origin + (direction * SCAN_LIMIT)
    local hit, result = sm.physics.raycast(flatStart, flatEnd)
    
    -- Fix: Ensure fallback also ignores low obstacles
    if hit and result.normalWorld.z < 0.6 and result.pointWorld.z > (floorZ + 0.5) then
        return result.pointWorld, (result.pointWorld - origin):length()
    end

    return nil, nil
end

-- --- TRACK SCAN (LOOP) ---
function TrackScanner.scanTrackLoop(self, startPos, startDir)
    self.rawNodes = {}
    local currentPos = startPos
    local currentDir = startDir:normalize()
    local currentUp = sm.vec3.new(0, 0, 1) -- Visual Up only
    
    local iterations = 0
    local loopClosed = false
    
    -- Memory for Fallbacks
    local prevLeftDist = 10.0
    local prevRightDist = 10.0
    local GAP_TOLERANCE = 8.0 -- If scan is nil, how far to extend previous wall
    
    print("TrackScanner: Starting Logic-Match Scan...")

    while not loopClosed and iterations < 2000 do
        
        -- 1. FLOOR CHECK (Get ground truth)
        local floorZ = currentPos.z
        local groundHit, groundRes = sm.physics.raycast(currentPos + sm.vec3.new(0,0,5), currentPos - sm.vec3.new(0,0,5))
        if groundHit then
            floorZ = groundRes.pointWorld.z
            currentPos = groundRes.pointWorld + (groundRes.normalWorld * 0.1) -- Hover slightly
        end

        -- 2. SETUP VECTORS (Stabilized)
        local stableUp = sm.vec3.new(0,0,1)
        local rightVec = currentDir:cross(stableUp):normalize() * -1
        local leftVec = -rightVec

        -- 3. SCAN (Using new Sweep)
        local lPos, lDist = self:findWallSweep(currentPos, leftVec, stableUp, prevLeftDist, floorZ)
        local rPos, rDist = self:findWallSweep(currentPos, rightVec, stableUp, prevRightDist, floorZ)

        -- 4. FALLBACK LOGIC (Gap Handling)
        local leftWall = lPos
        if not leftWall then
            -- Fallback: Use previous distance (Assume straight wall)
            leftWall = currentPos + (leftVec * prevLeftDist)
            lDist = prevLeftDist
        else
            -- Check for massive spikes (impossible geometry)
            if math.abs(lDist - prevLeftDist) > GAP_TOLERANCE and iterations > 5 then
                 -- Smooth it out if it jumps too fast
                 lDist = (lDist + prevLeftDist) * 0.5 
                 leftWall = currentPos + (leftVec * lDist)
            end
        end

        local rightWall = rPos
        if not rightWall then
            rightWall = currentPos + (rightVec * prevRightDist)
            rDist = prevRightDist
        else
            if math.abs(rDist - prevRightDist) > GAP_TOLERANCE and iterations > 5 then
                 rDist = (rDist + prevRightDist) * 0.5
                 rightWall = currentPos + (rightVec * rDist)
            end
        end

        -- Update Memory
        prevLeftDist = lDist or prevLeftDist
        prevRightDist = rDist or prevLeftDist

        -- 5. CALCULATE MIDPOINT
        local midPoint = (leftWall + rightWall) * 0.5
        local width = (leftWall - rightWall):length()

        -- 6. STEERING & DYNAMIC STEP
        local nextDir = currentDir
        local stepSize = 4.0 -- Default Step
        
        if iterations > 0 then
            local prevNode = self.rawNodes[#self.rawNodes]
            local targetDir = (midPoint - prevNode.mid):normalize()
            
            -- Calculate Turn Severity
            local dot = currentDir:dot(targetDir)
            local turnAngle = math.deg(math.acos(math.max(-1, math.min(1, dot))))
            
            -- Dynamic Step: Slow down on turns
            if turnAngle > 5.0 then stepSize = 2.0 end
            if turnAngle > 25.0 then stepSize = 1.5 end -- Hairpins
            
            -- Apply Steering (0.6 Lerp = Responsive but smooth)
            nextDir = sm.vec3.lerp(currentDir, targetDir, 0.6):normalize()
            
            -- Prevent reversing
            if nextDir:dot(currentDir) < 0 then nextDir = currentDir end
            
            prevNode.outVector = nextDir
        end

        -- 7. SAVE NODE
        table.insert(self.rawNodes, {
            id = iterations + 1,
            mid = midPoint,       -- The computed center
            location = midPoint,  -- Racing line (initially center)
            leftWall = leftWall,
            rightWall = rightWall,
            width = width,
            inVector = currentDir,
            outVector = nextDir,
            isJump = false
        })

        -- 8. ADVANCE
        currentDir = nextDir
        currentPos = midPoint + (currentDir * stepSize)
        iterations = iterations + 1

        -- 9. LOOP CLOSURE
        local distToStart = (currentPos - startPos):length()
        if iterations > 30 and distToStart < 15.0 then
            print("TrackScanner: Loop Closed.")
            loopClosed = true
            -- Link End to Start
            self.rawNodes[#self.rawNodes].outVector = (self.rawNodes[1].mid - self.rawNodes[#self.rawNodes].mid):normalize()
        end
    end
    
    -- Cleanup and Prep for Save
    self:calculateTrackDistances(self.rawNodes)
    return self.rawNodes
end

function TrackScanner.scanTrackLoop_old(self, startPos, startDir)
    self.rawNodes = {}
    local currentPos = startPos
    local currentDir = startDir
    
    -- "currentUp" is for data recording only.
    local currentUp = sm.vec3.new(0, 0, 1) 
    
    local iterations = 0
    local maxIterations = 2000 
    local loopClosed = false
    
    local prevLeftDist = 10.0 
    local prevRightDist = 10.0
    local GAP_TOLERANCE = 12.0 
    
    local currentStepSize = SCAN_STEP_SIZE 

    print("TrackScanner: Starting Lifted 3D Race Scan (Height Check)...")

    while not loopClosed and iterations < maxIterations do
        local floorPos, floorNormal = self:findFloorPoint(currentPos, currentUp)
        
        if floorPos then
            currentPos = floorPos
            currentUp = sm.vec3.lerp(currentUp, floorNormal, 0.1):normalize()
            
            -- [[ FIX 1: LIFT THE EYES ]]
            -- Scan from 1.0 unit above the floor
            local scanOrigin = currentPos + (floorNormal * 1.0)

            -- [[ FIX 2: STABLE HORIZON ]]
            local stableUp = sm.vec3.new(0, 0, 1)
            local rightVec = currentDir:cross(stableUp):normalize() * -1 
            local leftVec = -rightVec
            
            -- GET CURRENT FLOOR HEIGHT for comparison
            local currentFloorZ = currentPos.z
            
            -- PASS 1-2-3 LOGIC
            local rawLeft = self:findWallStrict(currentPos, leftVec, stableUp, currentFloorZ) 
            local rawRight = self:findWallStrict(currentPos, rightVec, stableUp, currentFloorZ)
            
            -- [[ LOGIC: Left Wall ]]
            local leftWall = rawLeft
            local validLeft = false
            if rawLeft then
                local dist = (rawLeft - currentPos):length()
                if dist > 2.0 then 
                    if iterations == 0 or (dist < prevLeftDist + GAP_TOLERANCE) then
                        prevLeftDist = dist
                        validLeft = true
                    end
                end
            end
            if not validLeft then leftWall = currentPos + (leftVec * prevLeftDist) end

            -- [[ LOGIC: Right Wall ]]
            local rightWall = rawRight
            local validRight = false
            if rawRight then
                local dist = (rawRight - currentPos):length()
                if dist > 2.0 then 
                    if iterations == 0 or (dist < prevRightDist + GAP_TOLERANCE) then
                        prevRightDist = dist
                        validRight = true
                    end
                end
            end
            if not validRight then rightWall = currentPos + (rightVec * prevRightDist) end

            -- Calculate Midpoint
            local midPoint = (leftWall + rightWall) * 0.5
            midPoint.z = currentPos.z + 0.5 
            
            local trackWidth = (leftWall - rightWall):length()

            -- Bank Calculation
            local bankAngle = 0.0
            if (leftWall.z - rightWall.z) > 2.0 then bankAngle = 1.0 end 
            if (rightWall.z - leftWall.z) > 2.0 then bankAngle = -1.0 end 

            table.insert(self.rawNodes, {
                id = iterations + 1,
                location = midPoint, 
                mid = midPoint,     
                leftWall = leftWall,
                rightWall = rightWall,
                width = trackWidth,
                inVector = currentDir, 
                outVector = currentDir, 
                upVector = currentUp, 
                bank = bankAngle,
                incline = currentDir.z,
                isJump = false,
                sectorID = 1 
            })

            -- [[ Steering Logic ]]
            local turnAngle = 0
            if iterations > 0 then
                local prevNode = self.rawNodes[#self.rawNodes-1]
                local rawNewDir = (midPoint - prevNode.location):normalize()
                
                local dot = prevNode.inVector:dot(rawNewDir)
                turnAngle = math.deg(math.acos(math.max(-1, math.min(1, dot))))

                -- RESTRICTION 1: The Angle Clamp
                -- OLD: 20.0 degrees
                -- NEW: 45.0 degrees (Allows hairpin turns)
                if turnAngle > 50.0 then
                    print(prevNode.id,">50 turn angle",turnAngle)
                    local slerpFactor = 50.0 / turnAngle
                    rawNewDir = sm.vec3.lerp(prevNode.inVector, rawNewDir, slerpFactor):normalize()
                end

                -- Prevent reversing
                if rawNewDir:dot(prevNode.inVector) < 0.0 then rawNewDir = prevNode.inVector end
                prevNode.outVector = rawNewDir
                
                -- RESTRICTION 2: The "Lag" (Damping)
                -- OLD: 0.5 (50% lag)
                -- NEW: 0.9 (10% lag - nearly instant reaction)
                -- If you set this to 1.0, it might jitter on jagged walls. 0.9 is a safe sweet spot.
                currentDir = sm.vec3.lerp(currentDir, rawNewDir, 0.7):normalize()
            end
            
            local severity = math.min(turnAngle, 20.0) / 20.0 -- 0.0 to 1.0
            currentStepSize = sm.util.lerp(4.0, 1.5, severity)

            currentPos = midPoint + (currentDir * currentStepSize)
            -- [[ DEBUG PRINT: MACRO ]]
            -- Only print the first 60 nodes so we don't flood the console
            if iterations < 60 then 
                local lDist = (leftWall - currentPos):length()
                local rDist = (rightWall - currentPos):length()
                local width = (leftWall - rightWall):length()
                
                -- "Offset" tells us if the node is centered (should be near 0)
                -- If this is huge, the scanner is drifting.
                local centerOffset = (midPoint - currentPos):length()
                
                print(string.format("[Node %d] W:%.1f | L:%.1f R:%.1f | Turn:%.1f | Offset:%.1f", 
                    iterations, width, lDist, rDist, turnAngle, centerOffset))
            end
            iterations = iterations + 1

            -- Loop Closure
            local distToStart = (currentPos - startPos):length()
            local isAligned = currentDir:dot(startDir) > 0.8
            if iterations > 40 and distToStart < 25.0 and isAligned then
                print("TrackScanner: Loop Closed successfully.")
                loopClosed = true
                local lastNode = self.rawNodes[#self.rawNodes]
                local firstNode = self.rawNodes[1]
                lastNode.outVector = (firstNode.location - lastNode.location):normalize()
            end
        else
            -- Void Logic
            local jumpCounter = iterations - #self.rawNodes
            local jumpGravity = sm.vec3.new(0,0,-0.5) * (jumpCounter * 0.5)
            currentPos = currentPos + (currentDir * currentStepSize) + jumpGravity
            if jumpCounter > JUMP_SEARCH_LIMIT then break end
            iterations = iterations + 1
        end
    end
    
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
    if count < 3 then return end

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
    self:clearDebugEffects()
    if not self.clientTrackData then return end

    local step = 3

    for i = 1, #self.clientTrackData, step do
        local node = self.clientTrackData[i]
        
        -- VISUALIZE RAYS
        if self.visMode == 3 then -- Skeleton Mode
            -- Center Dot
            self:spawnDot(node.mid, sm.color.new("00ffff")) 
            
            -- Left Wall Ray
            local colorL = sm.color.new("00ff00") -- Green = Good
            -- If the distance is exactly the "default" gap (meaning we interpolated), make it RED
            -- (You'll need to check your logic, but usually interpolated walls are perfectly smooth)
            --self:spawnLine(node.mid, node.left, colorL)
            self:spawnDot(node.left, colorL,"17153a0e-8461-442f-b172-3a899c1ae99f") --,"62cc44fb-2a53-4bf4-9c0d-616a19f2d184") 

            -- Right Wall Ray
            local colorR = sm.color.new("00ff00")
            --self:spawnLine(node.mid, node.right, colorR)
            self:spawnDot(node.right, colorR,"17153a0e-8461-442f-b172-3a899c1ae99f")
        
        else
            -- Normal Dot logic
            local pos = (self.visMode == 1) and node.pos or node.mid
            local col = (self.visMode == 1) and sm.color.new("00ff00") or sm.color.new("00ffff")
            self:spawnDot(pos, col)
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
    effect:setScale(sm.vec3.new(0,0,0))
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