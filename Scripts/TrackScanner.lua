-- TrackScanner.lua
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

local SCAN_MODE_RACE = 1
local SCAN_MODE_PIT = 2

function TrackScanner.server_init(self)
    print("server init")
    self.rawNodes = {}
    self.nodeChain = {} 
    self.pitChain = {} 
    self.scanMode = SCAN_MODE_RACE 
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
end

-- --- CORE SCANNING UTILS ---

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

    print("TrackScanner: Starting 3D Race Scan...")

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
            goto continue_scan -- SM lua does not support goto..
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

-- --- PIT LANE SCAN (ANCHOR BASED) ---

function TrackScanner.scanPitLaneFromAnchors(self)
    print("TrackScanner: Starting Anchor-Based Pit Scan...")
    
    if not PIT_ANCHORS.start or not PIT_ANCHORS.endPoint then
        print("Error: Missing Pit Start (Green) or Pit End (Red) anchors!")
        self.network:sendToClients("cl_showAlert", "Missing Start/End Anchors!")
        return
    end

    self.rawNodes = {}
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
        self:assignSectors(nodes)
        self.nodeChain = nodes
    else
        -- Pit Chain Optimization (Gentle Smoothing)
        -- We mostly trust the anchors, but smooth the intermediate nodes
        for iter = 1, 5 do
            for i = 2, count - 1 do
                local node = nodes[i]
                -- Only smooth if NOT an anchor point
                if node.pointType == 0 then
                    local prevNode = nodes[i-1]
                    local nextNode = nodes[i+1]
                    node.location = (prevNode.location + nextNode.location) * 0.5
                end
            end
        end
    end
    
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

function TrackScanner.recalculateNodeProperties(self, nodes)
    local count = #nodes
    for i = 1, count do
        local node = nodes[i]
        local nextNode = nodes[(i % count) + 1]
        -- Handle end of linear chain
        if i == count and nodes == self.pitChain then 
             nextNode = nodes[i] -- Point to self or handle merge vector
        end
        
        node.outVector = (nextNode.location - node.location):normalize()
        -- Fallback for last node in linear chain
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
                pos = self:vecToTable(node.location),
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

function TrackScanner.client_canInteract(self, character) return true end
function TrackScanner.client_onInteract(self, character, state)
    if state then
        if character:isCrouching() then
            self.network:sendToServer("sv_toggleScanMode")
        else
            self.network:sendToServer("sv_startScan")
        end
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
end

function TrackScanner.sv_startScan(self)
    local startPos = sm.shape.getWorldPosition(self.shape)
    local startDir = sm.shape.getAt(self.shape)
    
    if self.scanMode == SCAN_MODE_RACE then
        self:scanTrackLoop(startPos, startDir)
        self:optimizeRacingLine(50, false)
    else
        self:scanPitLaneFromAnchors()
        self:optimizeRacingLine(5, true)
    end
    
    self:visualizeNodes()
    self:sv_saveToStorage()
end

function TrackScanner.visualizeNodes(self)
    for _, effect in ipairs(self.debugEffects) do 
        if effect and sm.exists(effect) then effect:destroy() end 
    end
    self.debugEffects = {}
    
    local function drawChain(chain, color)
        for _, node in ipairs(chain) do
            local effect = sm.effect.createEffect("Loot - GlowItem")
            effect:setPosition(node.location)
            effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
            
            local c = color
            if node.pointType == 2 then c = sm.color.new("ffff00") -- Entry
            elseif node.pointType == 5 then c = sm.color.new("0000ff") -- Box
            end
            
            effect:setParameter("Color", c)
            effect:start()
            table.insert(self.debugEffects, effect)
        end
    end
    
    drawChain(self.nodeChain, sm.color.new("00ff00"))
    drawChain(self.pitChain, sm.color.new("ff00ff"))
end

function TrackScanner.cl_showAlert(self, msg)
    sm.gui.displayAlertText(msg, 3)
end