-- TwitchManager.lua
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
    self.apiPollTimer = self.apiPollTimer + dt
    if self.apiPollTimer >= 0.1 then 
        self:readAPI()
        self.apiPollTimer = 0
    end
    self.deckPollTimer = self.deckPollTimer + dt
    if self.deckPollTimer >= 0.05 then 
        self:readStreamDeck()
        self.deckPollTimer = 0
    end
end

function TwitchManager.readAPI(self)
    local success, instructions = pcall(sm.json.open, API_INSTRUCTIONS)
    if not success or type(instructions) ~= "table" then return end
    if #instructions == 0 then return end
    print("TwitchManager: Received " .. #instructions .. " commands.")
    for _, cmd in ipairs(instructions) do self:executeCommand(cmd) end
    pcall(sm.json.save, {}, API_INSTRUCTIONS) 
    self:updateAckStatus()
end

function TwitchManager.updateAckStatus(self)
    local success, ackData = pcall(sm.json.open, ACK_FILE)
    local status = (success and ackData and ackData.status) or 0
    pcall(sm.json.save, { status = status + 1 }, ACK_FILE)
end

function TwitchManager.executeCommand(self, instruction)
    local cmd = instruction.cmd 
    local val = tonumber(instruction.val) 
    local rawVal = instruction.val 

    if cmd == "setRAC" then self.RC.RaceManager:setState(val)
    elseif cmd == "resRAC" then self.RC.RaceManager:resetRace()
    elseif cmd == "racLAP" then self.RC.RaceManager.targetLaps = val
    elseif cmd == "setTIR" then self.RC.RaceManager.tireWearEnabled = (val == 1)
    elseif cmd == "setFUE" then self.RC.RaceManager.fuelUsageEnabled = (val == 1)
    elseif cmd == "delALL" then self.RC:sv_delete_all_racers()
    elseif cmd == "delMID" then self.RC:sv_delete_racer_by_meta(val)
    elseif cmd == "delBID" then self.RC:sv_delete_racer_by_body(val)
    elseif cmd == "impCAR" then self.RC:sv_queue_racer_import(val)
    elseif cmd == "genCAR" then self.RC:sv_queue_racer_import(rawVal) 
    elseif cmd == "impLEG" then self.RC:sv_import_league(val)
    elseif cmd == "pitCAR" then 
         -- self.RC.PitManager:forcePit(val) 
    end
end

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
         -- self.RC.CameraManager:cl_cycleCamera(val) 
    end
end