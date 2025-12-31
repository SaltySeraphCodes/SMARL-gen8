dofile "Timer.lua" 
dofile "globals.lua"

-- Copyright (c) 2025 SaltySeraph --
-- raceLineLoader.lua 
-- V3.5: Visual Resampling (Optimized Effect Count)

Loader = class( nil )
Loader.maxChildCount = -1
Loader.maxParentCount = -1
Loader.connectionInput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Loader.connectionOutput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Loader.colorNormal = sm.color.new( 0xffc0cbff )
Loader.colorHighlight = sm.color.new( 0xffb6c1ff )

local TRACK_DATA_CHANNEL = "SM_AutoRacers_TrackData"

-- Local helper functions utilities
function round( value )
	return math.floor( value + 0.5 )
end

-- [[ FIXED DEEPCOPY ]]
-- A "Safe" deepcopy that ignores metatables to prevent Sandbox Errors.
local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
    else 
        copy = orig
    end
    return copy
end

function Loader.client_onCreate( self ) 
	self:client_init()
	print("Created Track Loader")
    -- Auto-Start: Ask server for data immediately
    self.network:sendToServer("sv_requestSync")
end

function Loader.client_onDestroy(self)
    self:stopVisualization()
end

function Loader.client_init( self ) 
    self.effectChain = {} 
    self.visualizing = false
    self.debug = true 

    self.trackName = "unnamed track" 
    self.scanError = false
    
    self.streamBuffer = { race = {}, pit = {} }

    self.useText =  sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    self.onHover = false
	print("Track Loader V3.5 Client Initialized")
end

function Loader.client_onRefresh( self )
	self:client_onDestroy()
	self:client_init()
    self.network:sendToServer("sv_requestSync")
end

function Loader.server_onCreate(self)
    self:server_init()
end

function Loader.server_init(self)
    self.trackName = "Unnamed"
    self.trackID = 123 
    self.location = sm.shape.getWorldPosition(self.shape)
    self.direction = self.shape:getAt()
    
    -- Saved Track data loading
    local storedTrack = self.storage:load() 
    if storedTrack == nil then 
        print("Loader: No track data in Block Storage")
    else 
        print("Loader: Loaded track '"..(storedTrack.N or "Unknown").."' from Block")
        self.trackData = storedTrack
        self:sv_loadTrack() -- Process and prepare 'trackContainer'
    end
end

-- --- STREAMING LOGIC ---

function Loader.sv_requestSync(self)
    if self.trackContainer then
        self:sv_streamTrackData()
    end
end

function Loader.sv_streamTrackData(self)
    if not self.trackContainer then return end
    print("Loader: Streaming Track Data to Clients...")
    
    self.network:sendToClients("cl_streamEvent", { type = "start" })
    
    local function sendList(list, chainType)
        if not list then return end
        local batch = {}
        local count = 0
        for _, node in ipairs(list) do
            table.insert(batch, node)
            count = count + 1
            if count >= 50 then 
                self.network:sendToClients("cl_streamEvent", { type = "batch", chain = chainType, nodes = batch })
                batch = {}
                count = 0
            end
        end
        if count > 0 then
            self.network:sendToClients("cl_streamEvent", { type = "batch", chain = chainType, nodes = batch })
        end
    end
    
    if self.trackContainer.raceChain then sendList(self.trackContainer.raceChain, "race") end
    if self.trackContainer.pitChain then sendList(self.trackContainer.pitChain, "pit") end
    
    self.network:sendToClients("cl_streamEvent", { type = "end" })
end

function Loader.cl_streamEvent(self, data)
    if data.type == "start" then
        self:stopVisualization()
        self.streamBuffer = { race = {}, pit = {} }
        
    elseif data.type == "batch" then
        if data.chain == "race" then
            for _, node in ipairs(data.nodes) do table.insert(self.streamBuffer.race, node) end
        elseif data.chain == "pit" then
            for _, node in ipairs(data.nodes) do table.insert(self.streamBuffer.pit, node) end
        end
        
    elseif data.type == "end" then
        self.effectChain = {} 
        
        -- [[ VISUALIZATION BUILDER ]]
        local function addChainToEffects(chain, color)
            if not chain then return end
            
            -- [[ RESAMPLING ]] 
            -- Skip every N nodes to prevent effect limit overflow
            local STEP = 2 
            
            for i = 1, #chain, STEP do
                local node = chain[i]
                local loc = node.location or node.pos 
                if type(loc) == "table" then loc = sm.vec3.new(loc.x, loc.y, loc.z) end
                
                if loc then
                    table.insert(self.effectChain, {effect = self:generateEffect(loc, color)})
                end
            end
        end
        
        addChainToEffects(self.streamBuffer.race, sm.color.new("00ff00")) -- Green
        addChainToEffects(self.streamBuffer.pit, sm.color.new("ff00ff"))  -- Magenta
        self:showVisualization()
    end
end

-- --- VISUALIZATION UTILS ---

function Loader.generateEffect(self, location, color) 
    local effect = sm.effect.createEffect("Loot - GlowItem")
    effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    effect:setScale(sm.vec3.new(0,0,0))
    local col = (color or sm.color.new("AFAFAFFF"))
    if location then
        effect:setPosition(location)
        effect:setParameter("Color", col)
    end
    return effect
end

function Loader.stopVisualization(self) 
    if self.effectChain then
        for _, v in ipairs(self.effectChain) do
            if v.effect then v.effect:stop() end
        end
    end
    self.effectChain = {}
    self.visualizing = false
end

function Loader.showVisualization(self) 
    for _, v in ipairs(self.effectChain) do
        if v.effect and not v.effect:isPlaying() then v.effect:start() end
    end
    self.visualizing = true
end

-- --- SERVER LOGIC ---

function Loader.sv_saveTrack(self) 
    -- 1. Load data from World (Generated by TrackScanner)
    local worldData = self:sv_loadWorldTrackData(TRACK_DATA_CHANNEL)
    
    if worldData == nil then
        self:sv_sendAlert("Error: No Track Data found in World!")
        return 
    end
    
    -- 2. Store it in the block
    self.trackData = {
        ["N"] = self.trackName,
        ["I"] = self.trackID,
        ["C"] = worldData, 
        ["O"] = self.location, 
        ["D"] = self.direction 
    }
    self.storage:save(self.trackData)
    print("Loader: Track Saved to Block Storage")
    self:sv_sendAlert("Track Saved to Block (Ready for Blueprint)")
    
    -- 3. Update Live State
    self:sv_loadTrack()
end

function Loader.sv_loadTrack(self) 
    if self.trackData == nil then return end
    
    if not self.trackData.C then 
        print("Loader Error: trackData.C is missing") 
        return 
    end

    -- Use the SAFE deepcopy here
    local tempContainer = deepcopy(self.trackData.C) 
    local offsetData = self:calculateOffsetData()
    
    -- Apply offsets
    if tempContainer.raceChain then self:offsetSingleChain(tempContainer.raceChain, offsetData) end
    if tempContainer.pitChain then self:offsetSingleChain(tempContainer.pitChain, offsetData) end

    -- Store as 'trackContainer'
    self.trackContainer = tempContainer 
    
    -- Refresh clients
    self:sv_streamTrackData()
end

function Loader.sv_saveWorldTrackData(self)
    if self.trackContainer then
        sm.storage.save(TRACK_DATA_CHANNEL, self.trackContainer)
        print("Loader: Track Loaded to World Channel")
        self:sv_sendAlert("Track Loaded to World! (AI Ready)")
    else
        self:sv_sendAlert("No Track loaded in Block!")
    end
end

function Loader.sv_loadWorldTrackData(self, channel) 
    return sm.storage.load(channel)
end

-- --- OFFSET CALCULATION ---

function Loader.calculateOffsetData(self)
    local originalOrigin = self.trackData.O or self.location
    local originalDirection = self.trackData.D or self.direction
    local currentOrigin = self.location      
    local currentDirection = self.direction  
    
    local originalAngle = math.atan2(originalDirection.y, originalDirection.x)
    local currentAngle = math.atan2(currentDirection.y, currentDirection.x)
    local radians = currentAngle - originalAngle
    
    return { orig = originalOrigin, curr = currentOrigin, rads = radians }
end

function Loader.ensureVec3(self, val)
    if not val then return nil end
    if type(val) == "userdata" then return val end 
    if type(val) == "table" then return sm.vec3.new(val.x, val.y, val.z) end
    return nil
end

function Loader.offsetSingleChain(self, chain, data)
    if not chain then return end
    for k, node in ipairs(chain) do
        -- 1. Ensure vectors are usable
        node.location = self:ensureVec3(node.location or node.pos)
        node.mid = self:ensureVec3(node.mid)
        node.leftWall = self:ensureVec3(node.leftWall or node.left)
        node.rightWall = self:ensureVec3(node.rightWall or node.right)
        node.perp = self:ensureVec3(node.perp)
        node.outVector = self:ensureVec3(node.outVector or node.out)
        
        -- 2. Apply Transforms (Positions)
        if node.location then node.location = ((node.location - data.orig):rotateZ(data.rads)) + data.curr end
        if node.mid then node.mid = ((node.mid - data.orig):rotateZ(data.rads)) + data.curr end
        if node.leftWall then node.leftWall = ((node.leftWall - data.orig):rotateZ(data.rads)) + data.curr end
        if node.rightWall then node.rightWall = ((node.rightWall - data.orig):rotateZ(data.rads)) + data.curr end

        -- 3. Apply Transforms (Directions)
        if node.perp then node.perp = node.perp:rotateZ(data.rads) end
        if node.outVector then node.outVector = node.outVector:rotateZ(data.rads) end
    end
end

-- --- INTERACTION ---

function Loader.sv_sendAlert(self, msg) self.network:sendToClients("cl_showAlert", msg) end
function Loader.cl_showAlert(self, msg) 
    sm.gui.displayAlertText(msg, 4)
    sm.audio.play("PaintTool - ColorPick", self.shape:getWorldPosition())
end

function Loader.server_onFixedUpdate(self, timeStep)
    local location = sm.shape.getWorldPosition(self.shape)
    local direction = self.shape:getAt()
    
    if self.trackData ~= nil then
        -- Check for movement to update preview
        if (location ~= self.location or direction ~= self.direction) then
            if sm.shape.getVelocity(self.shape):length() == 0 then
                self.location = location
                self.direction = direction
                self:sv_loadTrack() -- Re-calculate offsets based on new pos
            end
        end
    end
end

function Loader.client_canInteract(self, character)
    sm.gui.setInteractionText("Save World Track -> Block (Blueprint)", sm.gui.getKeyBinding("Use", true))
    sm.gui.setInteractionText( "Load Block Track -> World (Play)", sm.gui.getKeyBinding("Tinker", true))
    return true 
end


function Loader.client_canTinker( self, character ) return true end

function Loader.client_onTinker( self, character, state )
    if state then self.network:sendToServer('sv_saveWorldTrackData') end
end

function Loader.client_onInteract(self, character, state)
     if state then self.network:sendToServer("sv_saveTrack") end
end