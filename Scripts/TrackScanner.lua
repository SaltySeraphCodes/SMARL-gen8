-- TrackScanner.lua: A robust, automated tool for generating racing lines.
-- Features: 3D Surface Tracking, Banking Detection, Jump Logic, Crossover Support, and JSON/World Saving.
dofile("globals.lua")

TrackScanner = class(nil)

-- Constants
local SCAN_STEP_SIZE = 4.0 
local SCAN_WIDTH_MAX = 50.0 
local WALL_SCAN_HEIGHT = 5.0 
local OPTIMIZATION_PASSES = 50 
local MARGIN_SAFETY = 4.0 
local LOOP_Z_TOLERANCE = 6.0 
local JUMP_SEARCH_LIMIT = 20 

-- Save Channels
local STORAGE_CHANNEL_TRACK = "SM_AutoRacers_TrackData"
local JSON_FILENAME = "$CONTENT_DATA/TrackData/track_export.json"

function TrackScanner.server_init(self)
    self.rawNodes = {}
    self.nodeChain = {} 
    self.isScanning = false
    self.debugEffects = {}
end

function TrackScanner.client_onCreate(self)
    self:client_init()
end

function TrackScanner.client_init(self)
    self.rawNodes = {}
    self.debugEffects = {}
    self.scanning = false
    self.debug = false
    
    self.useText = sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    self.leftClickText = sm.gui.getKeyBinding("Create",true)
    self.rightClickText = sm.gui.getKeyBinding("Attack",true)
end

-- --- PHASE 1: THE CRAWLER (Advanced 3D) ---
-- (Scanning logic omitted for brevity - same as previous version)
-- ... (Assume findFloorPoint, findWallPoint, scanTrackLoop exist here) ...

function TrackScanner.findFloorPoint(self, origin, upVector)
    local scanStart = origin + (upVector * 3.0)
    local scanEnd = origin - (upVector * 15.0)
    local hit, result = sm.physics.raycast(scanStart, scanEnd)
    if hit then return result.pointWorld, result.normalWorld end
    return nil, nil
end

function TrackScanner.findWallPoint(self, origin, direction, upVector)
    local scanStart = origin + (upVector * WALL_SCAN_HEIGHT)
    local scanEndDir = direction * SCAN_WIDTH_MAX
    local scanEnd = scanStart + scanEndDir
    local hit, result = sm.physics.raycast(scanStart, scanEnd)
    if hit then
        local wallPoint = result.pointWorld
        local downCheckStart = wallPoint + (upVector * 2.0)
        local downCheckEnd = wallPoint - (upVector * 10.0)
        local hitDown, resDown = sm.physics.raycast(downCheckStart, downCheckEnd)
        if hitDown then return resDown.pointWorld else return wallPoint end
    end
    return nil
end

function TrackScanner.scanTrackLoop(self, startPos, startDir)
    self.rawNodes = {}
    local currentPos = startPos
    local currentDir = startDir
    local currentUp = sm.vec3.new(0, 0, 1)
    local iterations = 0
    local maxIterations = 2000 
    local loopClosed = false
    local jumpCounter = 0

    print("TrackScanner: Starting 3D Scan...")

    while not loopClosed and iterations < maxIterations do
        local floorPos, floorNormal = self:findFloorPoint(currentPos, currentUp)
        local isJump = false
        if floorPos then
            currentPos = floorPos
            currentUp = sm.vec3.lerp(currentUp, floorNormal, 0.5):normalize()
            jumpCounter = 0
        else
            jumpCounter = jumpCounter + 1
            isJump = true
            local jumpGravity = sm.vec3.new(0,0,-0.5) * (jumpCounter * 0.5)
            currentPos = currentPos + (currentDir * SCAN_STEP_SIZE) + jumpGravity
            if jumpCounter > JUMP_SEARCH_LIMIT then break end
            iterations = iterations + 1
            goto continue_scan 
        end

        local rightVec = currentDir:cross(currentUp):normalize() * -1 
        local leftWall = self:findWallPoint(currentPos, -rightVec, currentUp)
        local rightWall = self:findWallPoint(currentPos, rightVec, currentUp)

        if not leftWall or not rightWall then break end

        local trackWidth = (leftWall - rightWall):length()
        local midPoint = (leftWall + rightWall) * 0.5
        local wallSlopeVec = (rightWall - leftWall):normalize()
        local bankUp = wallSlopeVec:cross(currentDir):normalize()
        
        table.insert(self.rawNodes, {
            id = iterations + 1,
            location = midPoint, 
            leftWall = leftWall,
            rightWall = rightWall,
            width = trackWidth,
            inVector = currentDir, 
            outVector = currentDir,
            upVector = bankUp, 
            isJump = isJump,
            sectorID = 1 -- Default to 1
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
        local zDist = math.abs(currentPos.z - startPos.z)
        
        if iterations > 20 and distToStart < (SCAN_STEP_SIZE * 1.5) and zDist < LOOP_Z_TOLERANCE then
            print("TrackScanner: Loop Closed successfully.")
            loopClosed = true
            local lastNode = self.rawNodes[#self.rawNodes]
            local firstNode = self.rawNodes[1]
            lastNode.outVector = (firstNode.location - lastNode.location):normalize()
        end
        ::continue_scan::
    end
    return self.rawNodes
end

-- --- PHASE 2: OPTIMIZER & SECTOR ASSIGNMENT ---

function TrackScanner.optimizeRacingLine(self, iterations)
    local nodes = self.rawNodes
    local count = #nodes
    if count < 3 then return end

    print("TrackScanner: Optimizing Racing Line...")

    -- Optimization Loop
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
                
                node.location = node.leftWall + (wallDir * clampedDist)
            end
        end
    end
    
    self:recalculateNodeProperties(nodes)
    
    -- NEW: Assign Sectors
    self:assignSectors(nodes)
    
    self.nodeChain = nodes
end

function TrackScanner.assignSectors(self, nodes)
    local count = #nodes
    if count == 0 then return end
    
    -- Split track into 3 roughly equal segments
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
    print("TrackScanner: Sectors assigned (Split at " .. sectorSize .. " nodes)")
end

function TrackScanner.recalculateNodeProperties(self, nodes)
    local count = #nodes
    for i = 1, count do
        local node = nodes[i]
        local nextNode = nodes[(i % count) + 1]
        node.outVector = (nextNode.location - node.location):normalize()
        local nodeUp = node.upVector or sm.vec3.new(0,0,1)
        node.perp = node.outVector:cross(nodeUp):normalize() 
        local heightDiff = (node.leftWall - node.rightWall):dot(sm.vec3.new(0,0,1))
        node.bank = heightDiff / node.width 
        node.incline = node.outVector.z
    end
end

-- --- DATA SERIALIZATION ---

function TrackScanner.vecToTable(self, vec)
    if not vec then return {x=0, y=0, z=0} end
    return { x = vec.x, y = vec.y, z = vec.z }
end

function TrackScanner.serializeTrackData(self)
    local serializedNodes = {}
    for i, node in ipairs(self.nodeChain) do
        local dataNode = {
            id = node.id,
            pos = self:vecToTable(node.location),
            width = node.width,
            bank = node.bank,
            incline = node.incline,
            out = self:vecToTable(node.outVector),
            perp = self:vecToTable(node.perp),
            isJump = node.isJump,
            sectorID = node.sectorID -- Now included in save
        }
        table.insert(serializedNodes, dataNode)
    end
    return { timestamp = os.time(), nodeCount = #serializedNodes, nodes = serializedNodes }
end

function TrackScanner.sv_saveToStorage(self)
    if #self.nodeChain == 0 then return end
    print("TrackScanner: Saving to World Storage...")
    local data = self:serializeTrackData()
    sm.storage.save(STORAGE_CHANNEL_TRACK, data)
    self.network:sendToClients("cl_onSaveComplete", true)
end

function TrackScanner.sv_exportToJson(self)
    if #self.nodeChain == 0 then return end
    print("TrackScanner: Exporting to JSON...")
    local data = self:serializeTrackData()
    sm.json.save(data, JSON_FILENAME)
    self.network:sendToClients("cl_onSaveComplete", true)
end

-- --- INTERFACE ---

function TrackScanner.generateTrack(self)
    local startPos = sm.shape.getWorldPosition(self.shape)
    local startDir = sm.shape.getAt(self.shape)
    local rawNodes = self:scanTrackLoop(startPos, startDir)
    
    if #rawNodes > 0 then
        self:optimizeRacingLine(OPTIMIZATION_PASSES)
        self:visualizeNodes()
        self.network:sendToServer("sv_saveToStorage")
        self.network:sendToServer("sv_exportToJson")
        print("TrackScanner: Generation Complete.")
        self.scanning = false
    else
        print("TrackScanner: Generation Failed.")
        self.scanning = false
    end
end

function TrackScanner.visualizeNodes(self)
    for _, effect in ipairs(self.debugEffects) do 
        if effect and sm.exists(effect) then effect:destroy() end 
    end
    self.debugEffects = {}
    for _, node in ipairs(self.nodeChain) do
        local effect = sm.effect.createEffect("Loot - GlowItem")
        effect:setPosition(node.location)
        effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
        
        -- Color code by sector
        if node.sectorID == 1 then effect:setParameter("Color", sm.color.new("00ff00")) 
        elseif node.sectorID == 2 then effect:setParameter("Color", sm.color.new("ffff00")) 
        else effect:setParameter("Color", sm.color.new("ff0000")) end

        effect:start()
        table.insert(self.debugEffects, effect)
    end
end

function TrackScanner.cl_onSaveComplete(self, success)
    if success then sm.gui.displayAlertText("Track Saved & Exported!") end
end

-- Interaction
function TrackScanner.client_canInteract(self, character) return true end
function TrackScanner.client_onInteract(self, character, state)
    if state then
        if character:isCrouching() then
            self.debug = not self.debug
            if self.debug then self:visualizeNodes() end
        elseif not self.scanning then
            self.scanning = true
            sm.gui.displayAlertText("Scanning Started...")
            self:generateTrack()
        end
    end
end
function TrackScanner.client_canTinker(self) return true end
function TrackScanner.client_onTinker(self, character, state) end
function TrackScanner.sv_changeWallSensitivity(self, amount) end