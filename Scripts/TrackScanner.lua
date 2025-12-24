-- TrackScanner.lua
dofile("globals.lua")

TrackScanner = class(nil)

-- Constants
local SCAN_STEP_SIZE = 4.0 
local SCAN_WIDTH_MAX = 50.0 
local WALL_SCAN_HEIGHT = 20.0 
local FLOOR_DROP_THRESHOLD = 1.5 
local SCAN_GRAIN = 0.5 
local MARGIN_SAFETY = 5 
local SCAN_MODE_RACE = 1
local SCAN_MODE_PIT = 2
local LOOP_Z_TOLERANCE = 6.0
local JUMP_SEARCH_LIMIT = 20
local BATCH_SIZE = 200 -- Sends 200 nodes per network packet (Safe limit)

function TrackScanner.server_onCreate(self) self:server_init() end
function TrackScanner.client_onCreate(self) self:client_init() end
function TrackScanner.server_onRefresh(self) self:server_init() end
function TrackScanner.client_onRefresh(self) self:client_init() end

function TrackScanner.client_onDestroy(self)
    for _, effect in ipairs(self.debugEffects) do 
        if effect and sm.exists(effect) then effect:destroy() end 
    end
    self.debugEffects = {}
end


function TrackScanner.server_init(self)
    self.rawNodes = {}
    self.nodeChain = {} 
    self.pitChain = {} 
    self.scanMode = SCAN_MODE_RACE 
    self.isScanning = false
    self.debugEffects = {}
    self.network:setClientData({ mode = self.scanMode })
end

function TrackScanner.client_init(self)
    self.rawNodes = {}
    self.debugEffects = {}
    self.scanning = false
    self.debug = false
end

-- --- CORE SCANNING UTILS ---

function TrackScanner.findFloorPoint(self, origin, upVector)
    -- Scan from a bit lower (5.0) to avoid hitting low ceilings as 'floor'
    local scanStart = origin + (upVector * 5.0)
    local scanEnd = origin - (upVector * 20.0)
    local hit, result = sm.physics.raycast(scanStart, scanEnd)
    if hit then return result.pointWorld, result.normalWorld end
    return nil, nil
end

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

-- ROBUST WALL SCANNING
function TrackScanner.findWallTopDown(self, origin, direction, upVector, floorZ)
    local perpLimit = SCAN_WIDTH_MAX
    local foundWall = nil
    
    -- Start slightly offset from center
    local startOffset = 2.0 

    for k = startOffset, perpLimit, SCAN_GRAIN do
        local scanPos = origin + (direction * k)
        local rayStart = scanPos + (upVector * WALL_SCAN_HEIGHT)
        local rayEnd = scanPos - (upVector * WALL_SCAN_HEIGHT) 
        
        local hit, result = sm.physics.raycast(rayStart, rayEnd)
        
        if hit then
            local hitHeight = result.pointWorld.z
            local heightDiff = math.abs(hitHeight - floorZ)
            
            -- If we hit something significantly different from the floor
            if heightDiff > FLOOR_DROP_THRESHOLD then
                
                -- VERIFY: Cast a horizontal ray at floor level to confirm it's a wall and not a ceiling
                local wallFaceSearchStart = origin + (direction * (k - SCAN_GRAIN))
                local wallFaceSearchEnd = origin + (direction * (k + SCAN_GRAIN))
                
                -- Adjust Z to be slightly above floor to hit the face
                wallFaceSearchStart = wallFaceSearchStart + (upVector * 0.5)
                wallFaceSearchEnd = wallFaceSearchEnd + (upVector * 0.5)

                local hitFace, resFace = sm.physics.raycast(wallFaceSearchStart, wallFaceSearchEnd)
                
                if hitFace then
                    -- Valid Wall Face Found
                    return resFace.pointWorld
                else
                    -- We detected a height change from above, but the floor-level ray didn't hit anything.
                    -- This usually means we hit a CEILING or OVERHANG (Tunnel).
                    -- Do NOT return a wall here. Return nil to trigger the Flat Scan fallback.
                    return nil
                end
            end
            
            -- Update floorZ reference if the ground is just sloping gently
            if heightDiff < 0.8 then
                floorZ = hitHeight 
            end
        else
            -- Raycast missed everything (Cliff edge / Void)
            -- Return the last known good position as the "Wall" limit
            local lastValidPos = origin + (direction * (k - SCAN_GRAIN))
            return lastValidPos
        end
    end
    
    return nil -- No wall found within limit
end

function TrackScanner.findWallFlat(self, origin, direction, upVector)
    -- Fallback for tunnels
    local scanStart = origin + (upVector * 1.5) -- Chest height
    local scanEnd = origin + (direction * SCAN_WIDTH_MAX)
    local hit, result = sm.physics.raycast(scanStart, scanEnd)
    if hit then return result.pointWorld end
    return nil
end

function TrackScanner.findWallPoint(self, origin, direction, upVector)
    -- 1. Try Robust Top-Down Scan first
    local floorZ = origin.z
    local wallPoint = self:findWallTopDown(origin, direction, upVector, floorZ)
    
    if wallPoint then return wallPoint end
    
    -- 2. Fallback to Flat Scan (Essential for Tunnels/Roofs)
    -- print("TrackScanner: Top-Down failed, trying Flat Scan...")
    wallPoint = self:findWallFlat(origin, direction, upVector)
    
    return wallPoint
end

-- --- RACK TRACK SCAN (LOOP) ---
function TrackScanner.scanTrackLoop(self, startPos, startDir)
    self.rawNodes = {}
    local currentPos = startPos
    local currentDir = startDir
    local currentUp = sm.vec3.new(0, 0, 1)
    local iterations = 0
    local maxIterations = 2000 
    local loopClosed = false
    local jumpCounter = 0

    print("TrackScanner: Starting Robust 3D Race Scan...")

    while not loopClosed and iterations < maxIterations do
        local floorPos, floorNormal = self:findFloorPoint(currentPos, currentUp)
        local isJump = false
        
        -- LOGIC SPLIT: If we have a floor, we scan walls. If not, we handle jump physics.
        if floorPos then
            -- === GROUNDED LOGIC ===
            currentPos = floorPos
            currentUp = sm.vec3.lerp(currentUp, floorNormal, 0.5):normalize()
            jumpCounter = 0

            -- Determine Left/Right Vectors
            -- Cross product: Dir x Up = Right. Multiply by -1 to get Left.
            local rightVec = currentDir:cross(currentUp):normalize() * -1 
            
            -- Scan Walls
            local leftWall = self:findWallPoint(currentPos, -rightVec, currentUp)  -- Scan Left
            local rightWall = self:findWallPoint(currentPos, rightVec, currentUp) -- Scan Right

            if not leftWall or not rightWall then 
                print("TrackScanner Error: Lost Walls at iter " .. iterations)
                break 
            end

            local trackWidth = (leftWall - rightWall):length()
            
            -- Calculate Midpoint but CLAMP Z to floor to prevent floating nodes
            local midPoint = (leftWall + rightWall) * 0.5
            midPoint.z = currentPos.z + 0.5 -- Keep it slightly above floor
            
            local wallSlopeVec = (rightWall - leftWall):normalize()
            local bankUp = wallSlopeVec:cross(currentDir):normalize()
            
            -- Bank calculation (approximate)
            local bankAngle = 0.0
            if (leftWall.z - rightWall.z) > 2.0 then bankAngle = 1.0 end -- Banked Left
            if (rightWall.z - leftWall.z) > 2.0 then bankAngle = -1.0 end -- Banked Right

            table.insert(self.rawNodes, {
                id = iterations + 1,
                location = midPoint, -- This will Move later during Optimization
                mid = midPoint,     -- STAYS as the Geometric Center reference 
                leftWall = leftWall,
                rightWall = rightWall,
                width = trackWidth,
                inVector = currentDir, 
                outVector = currentDir,
                upVector = bankUp, 
                bank = bankAngle,
                incline = currentDir.z,
                isJump = false,
                sectorID = 1 
            })

            if iterations > 0 and #self.rawNodes > 1 then
                local prevNode = self.rawNodes[#self.rawNodes-1]
                local newDir = (midPoint - prevNode.location):normalize()
                prevNode.outVector = newDir
                currentDir = newDir
            end

            currentPos = midPoint + (currentDir * SCAN_STEP_SIZE)
            iterations = iterations + 1

            -- Loop Closure Check (Only check this if we are grounded)
            local distToStart = (currentPos - startPos):length()
            local zDist = math.abs(currentPos.z - startPos.z)
            
            if iterations > 20 and distToStart < (SCAN_STEP_SIZE * 1.5) and zDist < LOOP_Z_TOLERANCE then
                print("TrackScanner: Loop Closed successfully.")
                loopClosed = true
                -- Link last to first
                local lastNode = self.rawNodes[#self.rawNodes]
                local firstNode = self.rawNodes[1]
                lastNode.outVector = (firstNode.location - lastNode.location):normalize()
            end

        else
            -- === JUMP LOGIC ===
            -- Logic that runs when floor is lost (replaces the 'goto' block)
            jumpCounter = jumpCounter + 1
            local jumpGravity = sm.vec3.new(0,0,-0.5) * (jumpCounter * 0.5)
            
            -- Move the scanner forward + gravity, but DO NOT add a node
            currentPos = currentPos + (currentDir * SCAN_STEP_SIZE) + jumpGravity
            
            if jumpCounter > JUMP_SEARCH_LIMIT then 
                print("TrackScanner: Lost floor for too long. Stopping.")
                break 
            end
            
            -- Just increment iterations and let the loop restart to try finding floor again
            iterations = iterations + 1
        end
    end
    return self.rawNodes
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

    if not isPit then
        print("TrackScanner: Optimizing Race Line...")
        
        -- 1. Horizontal Optimization (The Spring/Relaxation method)
        for iter = 1, iterations do
            for i = 1, count do
                local node = nodes[i]
                if not node.isJump then 
                    local prevIdx = (i - 2) % count + 1
                    local nextIdx = (i % count) + 1
                    local prevNode = nodes[prevIdx]
                    local nextNode = nodes[nextIdx]

                    local idealPos = (prevNode.location + nextNode.location) * 0.5
                    local wallVec = node.rightWall - node.leftWall
                    local trackWidth = wallVec:length()
                    local wallDir = wallVec:normalize()
                    
                    local relativePos = idealPos - node.leftWall
                    local projectionDist = relativePos:dot(wallDir)
                    local clampedDist = math.max(MARGIN_SAFETY, math.min(trackWidth - MARGIN_SAFETY, projectionDist))
                    
                    -- Only changing X and Y effectively here, Z becomes "stale"
                    node.location = node.leftWall + (wallDir * clampedDist)
                end
            end
        end
        
        -- 2. Resample (Delete clumped nodes)
        -- This ensures AI doesn't get confused by micro-segments
        nodes = self:resampleChain(nodes, 3.0) -- Enforce 3.0 block minimum spacing
        
        -- 3. Snap Z-Height
        -- Fixes the "floating/buried" issue caused by horizontal movement
        self:snapChainToFloor(nodes)
        
        self:assignSectors(nodes)
        self.nodeChain = nodes
    else
        -- Pit Chain Optimization
        for iter = 1, 5 do
            for i = 2, count - 1 do
                local node = nodes[i]
                if node.pointType == 0 then
                    local prevNode = nodes[i-1]
                    local nextNode = nodes[i+1]
                    node.location = (prevNode.location + nextNode.location) * 0.5
                end
            end
        end
        -- Also snap pits to floor
        self:snapChainToFloor(nodes)
        self.pitChain = nodes -- Update reference in case resample happened
    end
    
    -- Recalculate vectors (outVector, perp) now that positions are final
    self:recalculateNodeProperties(nodes)
end

function TrackScanner.assignSectors(self, nodes)
    local count = #nodes
    if count == 0 then return end
    local sectorSize = math.floor(count / 3)
    for i = 1, count do
        if i <= sectorSize then nodes[i].sectorID = 1
        elseif i <= sectorSize * 2 then nodes[i].sectorID = 2
        else nodes[i].sectorID = 3 end
    end
end

-- Force every node to find the ground directly below it
function TrackScanner.snapChainToFloor(self, nodes)
    print("TrackScanner: Snapping nodes to floor...")
    for i, node in ipairs(nodes) do
        -- Cast from slightly above the node, straight down
        local rayStart = node.location + sm.vec3.new(0, 0, 5.0)
        local rayEnd = node.location - sm.vec3.new(0, 0, 10.0)
        
        local hit, res = sm.physics.raycast(rayStart, rayEnd)
        if hit then
            -- Update Z to be exactly on floor + 0.5 clearance
            node.location = res.pointWorld + sm.vec3.new(0, 0, 0.5)
        end
    end
end

-- Removes nodes that are too close to their predecessor
function TrackScanner.resampleChain(self, nodes, minDistance)
    print("TrackScanner: Resampling nodes (Min Dist: "..minDistance..")...")
    if #nodes < 2 then return nodes end
    
    local cleanNodes = {}
    
    -- Always keep the first node
    table.insert(cleanNodes, nodes[1])
    local lastKeptNode = nodes[1]
    
    for i = 2, #nodes do
        local currentNode = nodes[i]
        local dist = (currentNode.location - lastKeptNode.location):length()
        
        -- Only keep node if it is far enough away OR if it's a special type (like a Pit Box)
        -- We usually want to preserve special points regardless of distance
        local isImportant = (currentNode.pointType and currentNode.pointType > 0)
        
        if dist >= minDistance or isImportant then
            table.insert(cleanNodes, currentNode)
            lastKeptNode = currentNode
        end
    end
    
    -- If loop logic requires specific count or linking, handled later by recalculateNodeProperties
    return cleanNodes
end

function TrackScanner.recalculateNodeProperties(self, nodes)
    local count = #nodes
    for i = 1, count do
        local node = nodes[i]
        local nextNode = nodes[(i % count) + 1]
        if i == count and nodes == self.pitChain then nextNode = nodes[i] end
        
        node.outVector = (nextNode.location - node.location):normalize()
        if node.outVector:length() == 0 then node.outVector = nodes[i-1].outVector end
        
        local nodeUp = node.upVector or sm.vec3.new(0,0,1)
        node.perp = node.outVector:cross(nodeUp):normalize() 
    end
end

-- --- SAVE ---

function TrackScanner.vecToTable(self, vec)
    if not vec then return {x=0, y=0, z=0} end
    return { x = vec.x, y = vec.y, z = vec.z }
end

function TrackScanner.serializeTrackData(self)
    local raceNodes = {}
    local pitNodes = {}
    
    local function serializeChain(chain, targetTable)
        for i, node in ipairs(chain) do
            local dataNode = {
                id = node.id,
                pos = self:vecToTable(node.location), -- The Racing Line
                mid = self:vecToTable(node.mid),      -- The Geometric Center
                width = node.width,
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

-- --- INTERACTION ---

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
        -- Tinker toggles the mode
        self.network:sendToServer("sv_toggleScanMode")
        sm.audio.play("PaintTool - ColorPick", self.shape:getWorldPosition())
    end
end

function TrackScanner.sv_toggleScanMode(self)
    if self.scanMode == SCAN_MODE_RACE then
        self.scanMode = SCAN_MODE_PIT
        self.network:sendToClients("cl_showAlert", "Mode: PIT LANE SCAN")
    else
        self.scanMode = SCAN_MODE_RACE
        self.network:sendToClients("cl_showAlert", "Mode: RACE TRACK SCAN")
    end
    -- [NEW] Sync state to client for GUI Text
    self.network:setClientData({ mode = self.scanMode })
end

function TrackScanner.client_onClientDataUpdate(self, data)
    self.clientScanMode = data.mode
end

function TrackScanner.sv_startScan(self)
    local startPos = sm.shape.getWorldPosition(self.shape)
    local startDir = sm.shape.getAt(self.shape)
    
    -- 1. Tell clients to clear old lines immediately
    self.network:sendToClients("cl_resetVisualization")

    -- 2. Perform Scanning Logic
    if self.scanMode == SCAN_MODE_RACE then
        self:scanTrackLoop(startPos, startDir)
        self:optimizeRacingLine(100, false)
    else
        self:scanPitLaneFromAnchors()
        self:optimizeRacingLine(5, true)
    end
    
    -- 3. Save full data to storage
    self:sv_saveToStorage()

    -- 4. Send Data in Chunks (Hybrid Approach: Compressed + Chunked)
    -- We pass "race" or "pit" so the client knows which base color to use
    self:sv_sendChunkedData(self.nodeChain, "race")
    self:sv_sendChunkedData(self.pitChain, "pit")
end

-- Clears old effects. Call this BEFORE sending new batches.
function TrackScanner.cl_resetVisualization(self)
    for _, effect in ipairs(self.debugEffects) do 
        if effect and sm.exists(effect) then effect:destroy() end 
    end
    self.debugEffects = {}
end

function TrackScanner.sv_sendChunkedData(self, chain, context)
    -- 1. Compress the data first (Location and Type only)
    local compressedData = self:getVizData(chain)
    local total = #compressedData
    
    -- 2. Loop through and send in chunks
    for i = 1, total, BATCH_SIZE do
        local chunk = {}
        -- Collect a slice of the table
        for j = i, math.min(i + BATCH_SIZE - 1, total) do
            table.insert(chunk, compressedData[j])
        end
        
        -- Send the chunk
        self.network:sendToClients("cl_receiveBatch", { 
            nodes = chunk, 
            context = context 
        })
    end
end

-- Receives a chunk of nodes and adds them to the existing list
function TrackScanner.cl_receiveBatch(self, data)
    local nodes = data.nodes
    local context = data.context -- "race" or "pit" to determine default color

    for _, nodeData in ipairs(nodes) do
        local effect = sm.effect.createEffect("Loot - GlowItem")
        effect:setScale(sm.vec3.new(0,0,0)) -- Makes the item invisible so only the glowing shows up
        effect:setPosition(nodeData.l)
        effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
        
        -- Color Logic
        local c = sm.color.new("00ff00") -- Default Green (Race)
        
        if context == "pit" then
            c = sm.color.new("ff00ff") -- Default Pink (Pit)
        end
        
        -- Specific Point Type Overrides (Pit Start/End, Boxes)
        if nodeData.t == 2 then c = sm.color.new("ffff00") -- Yellow
        elseif nodeData.t == 5 then c = sm.color.new("0000ff") end -- Blue
        
        effect:setParameter("Color", c)
        effect:start()
        table.insert(self.debugEffects, effect)
    end
end

function TrackScanner.cl_visualizeNodes(self, data)
    -- Clean up old effects
    for _, effect in ipairs(self.debugEffects) do 
        if effect and sm.exists(effect) then effect:destroy() end 
    end
    self.debugEffects = {}
    
    local function drawChain(chain, defaultColor)
        if not chain then return end
        for _, nodeData in ipairs(chain) do
            -- Read 'l' for location
            local effect = sm.effect.createEffect("Loot - GlowItem")
            effect:setScale(sm.vec3.new(0,0,0)) -- make the bearing item invisible
            effect:setPosition(nodeData.l) 
            effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
            
            -- Read 't' for type and determine color locally
            local c = defaultColor
            if nodeData.t == 2 then c = sm.color.new("ffff00") -- Yellow
            elseif nodeData.t == 5 then c = sm.color.new("0000ff") end -- Blue
            
            effect:setParameter("Color", c)
            effect:start()
            table.insert(self.debugEffects, effect)
        end
    end
    
    drawChain(data.race, sm.color.new("00ff00"))
    drawChain(data.pit, sm.color.new("ff00ff"))
end
function TrackScanner.cl_showAlert(self, msg)
    sm.gui.displayAlertText(msg, 3)
end