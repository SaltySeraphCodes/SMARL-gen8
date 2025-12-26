-- TrackScanner.lua (Fixed & Merged)
dofile("globals.lua")

TrackScanner = class(nil)

-- [[ TUNING ]]
local SCAN_STEP_SIZE = 4.0 
local SCAN_WIDTH_MAX = 80.0 
local WALL_SCAN_HEIGHT = 30.0 
local FLOOR_DROP_THRESHOLD = 1.5 
local SCAN_GRAIN = 0.5 
local MARGIN_SAFETY = 6.0
local JUMP_SEARCH_LIMIT = 20
local LOOP_Z_TOLERANCE = 6.0

-- [[ MODES ]]
local SCAN_MODE_RACE = 1
local SCAN_MODE_PIT = 2

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
    -- Try to load existing data if available
    self:sv_loadFromStorage()
    self.network:setClientData({ mode = self.scanMode })
end

function TrackScanner.client_init(self)
    self.rawNodes = {}
    self.debugEffects = {}
    self.scanning = false
    self.debug = false
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
    local floorZ = origin.z
    local wallPoint = self:findWallTopDown(origin, direction, upVector, floorZ)
    if wallPoint then return wallPoint end
    wallPoint = self:findWallFlat(origin, direction, upVector)
    return wallPoint
end

-- --- TRACK SCAN (LOOP) ---
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
        
        if floorPos then
            currentPos = floorPos
            currentUp = sm.vec3.lerp(currentUp, floorNormal, 0.5):normalize()
            jumpCounter = 0
            local rightVec = currentDir:cross(currentUp):normalize() * -1 
            
            local leftWall = self:findWallPoint(currentPos, -rightVec, currentUp) 
            local rightWall = self:findWallPoint(currentPos, rightVec, currentUp) 

            if not leftWall or not rightWall then 
                print("TrackScanner Error: Lost Walls at iter " .. iterations)
                break 
            end

            local trackWidth = (leftWall - rightWall):length()
            local midPoint = (leftWall + rightWall) * 0.5
            midPoint.z = currentPos.z + 0.5 
            
            -- Filter Spikes
            if #self.rawNodes > 0 then
                local prevWidth = self.rawNodes[#self.rawNodes].width
                if math.abs(trackWidth - prevWidth) > 10.0 then trackWidth = prevWidth end
            end

            local wallSlopeVec = (rightWall - leftWall):normalize()
            local bankUp = wallSlopeVec:cross(currentDir):normalize()
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

            local distToStart = (currentPos - startPos):length()
            if iterations > 20 and distToStart < (SCAN_STEP_SIZE * 1.5) then
                print("TrackScanner: Loop Closed successfully.")
                loopClosed = true
                local lastNode = self.rawNodes[#self.rawNodes]
                local firstNode = self.rawNodes[1]
                lastNode.outVector = (firstNode.location - lastNode.location):normalize()
            end
        else
            jumpCounter = jumpCounter + 1
            local jumpGravity = sm.vec3.new(0,0,-0.5) * (jumpCounter * 0.5)
            currentPos = currentPos + (currentDir * SCAN_STEP_SIZE) + jumpGravity
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

-- --- OPTIMIZER (FIXED) ---

function TrackScanner.optimizeRacingLine(self, iterations, isPit)
    local nodes = isPit and self.pitChain or self.rawNodes
    local count = #nodes
    if count < 3 then return end

    local MARGIN = MARGIN_SAFETY or 6.0

    -- [[ FIX 1: FILL GAPS ]]
    nodes = self:fillGaps(nodes, 6.0)
    count = #nodes -- Update count after filling

    -- [[ FIX 2: OPTIMIZATION LOOP ]]
    for iter = 1, iterations do
        for i = 1, count do
            local node = nodes[i]
            if not node.isJump then 
                local prev = nodes[(i - 2) % count + 1]
                local next = nodes[(i % count) + 1]

                local wallVec = node.rightWall - node.leftWall
                local trackWidth = wallVec:length()
                local wallDir = wallVec:normalize()

                local currentRel = node.location - node.leftWall
                local currentDist = currentRel:dot(wallDir)

                -- Gradient Descent for Radius
                local step = 0.5
                local pCurrent = node.location
                local pLeft    = node.location - (wallDir * step)
                local pRight   = node.location + (wallDir * step)

                local rCurrent = self:getLocalRadius(prev.location, pCurrent, next.location)
                local rLeft    = self:getLocalRadius(prev.location, pLeft, next.location)
                local rRight   = self:getLocalRadius(prev.location, pRight, next.location)

                local move = 0.0
                if rLeft > rCurrent and rLeft > rRight then
                    move = -step
                elseif rRight > rCurrent and rRight > rLeft then
                    move = step
                else
                    -- Smoothing
                    local smoothPos = (prev.location + next.location) * 0.5
                    local smoothRel = smoothPos - node.leftWall
                    local smoothDist = smoothRel:dot(wallDir)
                    move = (smoothDist - currentDist) * 0.1 
                end
                
                local newDist = currentDist + move
                newDist = math.max(MARGIN, math.min(trackWidth - MARGIN, newDist))
                node.location = node.leftWall + (wallDir * newDist)
            end
        end
    end
    
    -- [[ FIX 3: RESAMPLE ASSIGNMENT ]]
    -- We must assign the result back to 'nodes'
    nodes = self:resampleChain(nodes, 3.0)

    self:calculateTrackDistances(nodes)

    -- Final Cleanup
    self:snapChainToFloor(nodes)
    self:assignSectors(nodes)
    self:recalculateNodeProperties(nodes)

    -- Save back to main memory
    if isPit then self.pitChain = nodes else self.nodeChain = nodes end
    
    -- Auto-Save
    self:sv_saveToStorage()
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
    for i = 1, count do
        local node = nodes[i]
        local nextNode = nodes[(i % count) + 1]
        
        -- 1. Keep outVector aligned with the RACING LINE (for AI/playback)
        node.outVector = (nextNode.location - node.location):normalize()
        
        -- 2. Calculate a temporary vector based on the CENTER LINE (mid)
        --    Use this specifically to find the true track perpendicular
        local midDir = (nextNode.mid - node.mid):normalize()
        local nodeUp = node.upVector or sm.vec3.new(0,0,1)
        
        -- 3. Generate perp from the MID path, not the optimized path
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
        -- Tinker toggles the mode
        self.network:sendToServer("sv_switchMode")
        sm.audio.play("PaintTool - ColorPick", self.shape:getWorldPosition())
    end
end

function TrackScanner.sv_startScan(self)
    if self.isScanning then -- Screen will be frozen anyway... any way to do this "in the background?"
        -- STOP SCAN
        self.isScanning = false
        print("Stopping Scan...")
    else
        -- START SCAN
        self.isScanning = true
        local shape = self.shape
        local pos = shape:getWorldPosition()
        local dir = shape:getAt()
        
        if self.scanMode == SCAN_MODE_RACE then
            print("Starting Race Scan...")
            self:scanTrackLoop(pos, dir)
            self:optimizeRacingLine(500, false) -- Auto-Optimize after scan
            self:sv_sendVis()
        elseif self.scanMode == SCAN_MODE_PIT then
            print("Starting Pit Scan...")
            -- (Add your pit scan call here if needed)
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

function TrackScanner.cl_visEvent(self, data)
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