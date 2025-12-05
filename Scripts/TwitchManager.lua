-- TwitchManager.lua: The API Connector.
-- Handles JSON I/O between Scrap Mechanic and the external Python bots.

TwitchManager = class(nil)

local API_INSTRUCTIONS = "$CONTENT_DATA/JsonData/commands_to_lua.json"
local ACK_FILE = "$CONTENT_DATA/JsonData/lua_ack.json"
local DECK_INSTRUCTIONS = "$CONTENT_DATA/JsonData/cameraInput.json" 

function TwitchManager.server_init(self, raceControl)
    self.RC = raceControl
    self.apiPollTimer = 0
    self.deckPollTimer = 0
end

function TwitchManager.server_onFixedUpdate(self, dt)
    -- 1. Poll Main API (10Hz)
    self.apiPollTimer = self.apiPollTimer + dt
    if self.apiPollTimer >= 0.1 then 
        self:readAPI()
        self.apiPollTimer = 0
    end

    -- 2. Poll Stream Deck (20Hz)
    self.deckPollTimer = self.deckPollTimer + dt
    if self.deckPollTimer >= 0.05 then 
        self:readStreamDeck()
        self.deckPollTimer = 0
    end
end

-- --- MAIN API HANDLER ---

function TwitchManager.readAPI(self)
    local success, instructions = pcall(sm.json.open, API_INSTRUCTIONS)
    
    if not success or type(instructions) ~= "table" then return end
    if #instructions == 0 then return end

    print("TwitchManager: Received " .. #instructions .. " commands.")
    for _, cmd in ipairs(instructions) do
        self:executeCommand(cmd)
    end
    
    pcall(sm.json.save, {}, API_INSTRUCTIONS) 
    self:updateAckStatus()
end

function TwitchManager.updateAckStatus(self)
    local success, ackData = pcall(sm.json.open, ACK_FILE)
    local status = (success and ackData and ackData.status) or 0
    pcall(sm.json.save, { status = status + 1 }, ACK_FILE)
end

-- --- COMMAND ROUTER ---

function TwitchManager.executeCommand(self, instruction)
    local cmd = instruction.cmd 
    local val = tonumber(instruction.val) 
    local rawVal = instruction.val -- For non-numeric data (like Twitch objects)

    -- RACE MANAGEMENT
    if cmd == "setRAC" then self.RC.RaceManager:setState(val)
    elseif cmd == "resRAC" then self.RC.RaceManager:resetRace()
    
    -- SETTINGS
    elseif cmd == "racLAP" then self.RC.RaceManager.targetLaps = val
    elseif cmd == "setTIR" then self.RC.RaceManager.tireWearEnabled = (val == 1)
    elseif cmd == "setFUE" then self.RC.RaceManager.fuelUsageEnabled = (val == 1)
        
    -- RACER MANAGEMENT
    elseif cmd == "delALL" then self.RC:sv_delete_all_racers()
    elseif cmd == "delMID" then self.RC:sv_delete_racer_by_meta(val)
    elseif cmd == "delBID" then self.RC:sv_delete_racer_by_body(val)
    
    -- SPAWNING (The Critical Link)
    -- impCAR sends an ID (int), genCAR sends a Table object. 
    -- Both go to sv_queue_racer_import, which handles the type check.
    elseif cmd == "impCAR" then self.RC:sv_queue_racer_import(val)
    elseif cmd == "genCAR" then self.RC:sv_queue_racer_import(rawVal) 
        
    -- LEAGUE IMPORT
    elseif cmd == "impLEG" then self.RC:sv_import_league(val)
    
    -- EVENTS
    elseif cmd == "pitCAR" then 
         -- self.RC.PitManager:forcePit(val) 
    end
end

-- --- STREAM DECK ---

function TwitchManager.readStreamDeck(self)
    local success, data = pcall(sm.json.open, DECK_INSTRUCTIONS)
    if not success or type(data) ~= "table" or not data.command then return end
    
    local cmd = data.command
    local val = tonumber(data.value)
    pcall(sm.json.save, {}, DECK_INSTRUCTIONS)
    
    if cmd == "cMode" and self.RC.CameraManager then
        self.RC.CameraManager:setCameraMode(val)
    elseif cmd == "raceMode" then
        self.RC.RaceManager:setState(val)
    elseif cmd == "camCycle" and self.RC.CameraManager then
         -- Legacy camera cycling logic, map if needed
         -- self.RC.CameraManager:cl_cycleCamera(val) 
    end
end