-- SMARL Race Control V2.0 (Refactored)
-- Orchestrates race management, scoring, UI, Pit Lane, Camera, and External API.

dofile("globalsGen8.lua")
dofile("RaceManager.lua")
dofile("Leaderboard.lua")
dofile("TwitchManager.lua")
dofile("PitManager.lua")
dofile("CameraManager.lua")
dofile("UIManager.lua")

RaceControl = class(nil)
RaceControl.maxChildCount = -1
RaceControl.maxParentCount = -11
RaceControl.connectionInput = sm.interactable.connectionType.logic
RaceControl.connectionOutput = sm.interactable.connectionType.logic
RaceControl.colorNormal = sm.color.new(0xffc0cbff)
RaceControl.colorHighlight = sm.color.new(0xffb6c1ff)

-- Constants for Data Output
local OUTPUT_DATA = "$CONTENT_DATA/SMARL_Manager/JsonData/RaceOutput/raceData.json"
local MAP_DATA_PATH = "$CONTENT_DATA/SMARL_Manager/JsonData/TrackData/current_map.json"
local TRACK_STORAGE_CHANNEL = "SM_AutoRacers_TrackData" 
local RACER_DATA_PATH = "$CONTENT_DATA/SMARL_Manager/JsonData/RacerData/"
local TWITCH_BLUEPRINTS_PATH = "$CONTENT_DATA/SMARL_Manager/TwitchPlays/Blueprints/"
local SPAWN_PADDING_NODES = 3 

function RaceControl.server_onCreate(self)
    self:server_init()
end

function RaceControl.client_onCreate(self)
    self:client_init()
end

function RaceControl.server_init(self)
    print("RaceControl: Initializing V2.0 System...")
    RACE_CONTROL = self 
    
    self.RaceManager = RaceManager()
    self.RaceManager:server_init(self)
    
    self.Leaderboard = Leaderboard()
    self.Leaderboard:server_init(self)
    
    self.TwitchManager = TwitchManager()
    self.TwitchManager:server_init(self)

    self.PitManager = PitManager()
    self.PitManager:server_init(self)
    
    self.tickTimer = 0
    self.dataOutputTimer = 0
    self.outputRealTime = true
    self.racerImportQueue = {}
    self.spawnTimer = 0
    
    self.trackName = "Unknown Track"
    self:sv_init_track_data()
    self:sv_export_map_for_overlay() 
end

function RaceControl.client_init(self)
    print("RaceControl: Client Init")
    RACE_CONTROL = self
    self.CameraManager = CameraManager()
    self.CameraManager:client_init(self)
    if self.PitManager == nil then self.PitManager = PitManager() end
    self.PitManager:client_init(self)
    self.UIManager = UIManager()
    self.UIManager:init(self)
end

-- --- MAIN LOOP ---

function RaceControl.server_onFixedUpdate(self, dt)
    if self.RaceManager then self.RaceManager:server_onFixedUpdate(dt) end
    if self.Leaderboard then self.Leaderboard:server_onFixedUpdate(dt) end
    if self.TwitchManager then self.TwitchManager:server_onFixedUpdate(dt) end
    if self.PitManager then self.PitManager:server_onFixedUpdate() end
    
    self:sv_process_import_queue(dt)
    
    self.dataOutputTimer = self.dataOutputTimer + dt
    if self.dataOutputTimer >= 0.1 and self.outputRealTime then 
        self:sv_output_data()
        self.dataOutputTimer = 0
    end
end

function RaceControl.client_onFixedUpdate(self, dt)
    if self.CameraManager then self.CameraManager:client_onFixedUpdate() end
    if self.UIManager then self.UIManager:onFixedUpdate() end
end

function RaceControl.client_onUpdate(self, dt)
    if self.CameraManager then self.CameraManager:client_onUpdate(dt) end
end

-- --- RACER IMPORT LOGIC ---

function RaceControl.checkForClearTrack(self, nodeID, chain)
    local clearFlag = true
    -- Safety check for chain existence
    if not chain or #chain == 0 then return true end
    
    for _, v in ipairs(getAllDrivers()) do
        if v.perceptionData and v.perceptionData.Navigation and v.perceptionData.Navigation.currentNode then
            local driverNode = v.perceptionData.Navigation.currentNode
            local diff = math.abs(driverNode.id - nodeID)
            if diff < 10 then clearFlag = false end
        end
    end
    return clearFlag
end

function RaceControl.sv_process_import_queue(self, dt)
    if #self.racerImportQueue > 0 then
        self.spawnTimer = self.spawnTimer + dt
        if self.spawnTimer > 0.5 then
            local request = table.remove(self.racerImportQueue, 1)
            self:sv_import_racer(request)
            self.spawnTimer = 0
        end
    end
end

function RaceControl.sv_queue_racer_import(self, racer_id_or_data)
    table.insert(self.racerImportQueue, racer_id_or_data)
end

function RaceControl.sv_import_racer(self, racer_id)
    local bp_filename = ""
    local is_twitch = (type(racer_id) == "table")
    
    if is_twitch then
        bp_filename = TWITCH_BLUEPRINTS_PATH .. racer_id.bp .. ".json"
    else
        bp_filename = RACER_DATA_PATH .. racer_id .. ".json"
    end

    local spawnLocation = sm.vec3.new(0,0,10)
    local spawnRotation = sm.quat.identity()
    
    if self.trackNodeChain and #self.trackNodeChain > 0 then
        local currentDriverCount = #getAllDrivers()
        local targetNodeIndex = 5 + (currentDriverCount * SPAWN_PADDING_NODES)
        
        -- Wrap index if track is full
        targetNodeIndex = ((targetNodeIndex - 1) % #self.trackNodeChain) + 1

        local node = self.trackNodeChain[targetNodeIndex]
        if node then
            spawnLocation = node.location + sm.vec3.new(0,0,0.5)
            
            local isClear = self:checkForClearTrack(targetNodeIndex, self.trackNodeChain)
            if not isClear then
                print("RaceControl: Spawn zone blocked. Retrying later...")
                -- In a robust system, we would re-queue here, but for now we force spawn to prevent lock
            end
            
            local forward = node.outVector or sm.vec3.new(1,0,0)
            local up = sm.vec3.new(0,0,1)
            spawnRotation = sm.quat.lookRotation(forward, up)
        end
    end
    
    if sm.json.fileExists(bp_filename) then
        print("RaceControl: Importing Racer", bp_filename)
        sm.creation.importFromFile(sm.world.getCurrentWorld(), bp_filename, spawnLocation, spawnRotation)
        return true
    else
        print("RaceControl: Racer Data file not found", bp_filename)
        return false
    end
end

function RaceControl.sv_import_racers(self, racer_list)
    for _, r in ipairs(racer_list) do self:sv_queue_racer_import(r) end
end

function RaceControl.sv_import_league(self, league_id)
    local a_league = {1,2,3,5,6,7,8,9,10,11,12,13,15,16,17,18}
    local b_league = {14,19,20,21,22,23,24,25,26,27,28,30,31,33}
    print("RaceControl: Importing League", league_id)
    if league_id == 1 then self:sv_import_racers(a_league)
    elseif league_id == 2 then self:sv_import_racers(b_league) end
end

-- --- COMMAND ROUTING ---

function RaceControl.sv_recieveCommand(self, command)
    if self.RaceManager then self.RaceManager:handleCommand(command) end
    if command.type == "lap_cross" and self.Leaderboard then
        self.Leaderboard:onLapCross(command.car, command.value, command.lapTime)
    end
end

function RaceControl.sv_sendCommand(self, command)
    if self.RaceManager then self.RaceManager:broadcastCommand(command) end
end

-- --- DATA OUPUT ---

function RaceControl.sv_output_data(self)
    local realtimeData = {}
    local drivers = getAllDrivers()
    table.sort(drivers, function(a, b) return (a.racePosition or 99) < (b.racePosition or 99) end)

    for i, driver in ipairs(drivers) do
        local meta = driver.metaData or {}
        local twitch = driver.twitchData or {}
        
        local gapToNext = 0.0
        if drivers[i + 1] then
             local mySplit = driver.raceSplit or 0.0
             local nextSplit = drivers[i + 1].raceSplit or 0.0
             gapToNext = math.abs(nextSplit - mySplit)
        end

        local data = {
            id = driver.id,
            owner = twitch.uid or meta.ID or driver.id, 
            place = driver.racePosition or 0,
            lapNum = driver.currentLap or 0,
            lastLap = driver.lastLap or 0.0,
            bestLap = driver.bestLap or 0.0,
            timeSplit = driver.raceSplit or 0.0,
            gapToLeader = driver.raceSplit or 0.0,
            gapToNext = gapToNext,
            locX = 0, locY = 0, speed = 0,
            pitState = driver.pitState or 0,
            th = driver.Tire_Health or 1.0,
            fl = driver.Fuel_Level or 1.0,
            tt = driver.Tire_Type or 2,     
            sa = driver.Spoiler_Angle or 0.5,
            gl = driver.Gear_Length or 0.5,  
            st = driver.sectorTimes or {0, 0, 0}
        }

        if driver.perceptionData and driver.perceptionData.Telemetry then
            local t = driver.perceptionData.Telemetry
            data.locX = t.location.x
            data.locY = t.location.y
            data.speed = t.speed 
        end
        table.insert(realtimeData, data)
    end

    local metaData = {
        status = self.RaceManager and self.RaceManager.state or 0,
        lapsLeft = self.RaceManager and (self.RaceManager.targetLaps - self.RaceManager.currentLap) or 0,
        -- FIX: Export actual Boolean for Python compatibility!
        qualifying = self.RaceManager and self.RaceManager.qualifying or false 
    }

    local outputData = {
        ["rt"] = realtimeData,
        ["md"] = metaData,
        ["fd"] = self.RaceManager and self.RaceManager.finishResults or {},
        ["qd"] = {} 
    }
    pcall(sm.json.save, outputData, OUTPUT_DATA)
end

-- --- EVENTS ---
function RaceControl.sv_trigger_event(self, eventType, targetID, strength)
    local driver = getDriverFromId(targetID)
    if not driver then return end
    if eventType == "boost" then
        self:sv_sendCommand({car={targetID}, type="apply_modifier", modifier="speed_boost", value=strength, duration=5.0})
    elseif eventType == "penalty" then
        self:sv_sendCommand({car={targetID}, type="apply_modifier", modifier="speed_limit", value=0.5, duration=3.0})
    end
end

-- --- MAP EXPORT & TRACK LOADING ---

function RaceControl.sv_init_track_data(self)
    local pitData = sm.storage.load(PIT_DATA)
    if pitData and self.PitManager then
        self.PitManager:sv_loadPitData(pitData['pitChain'], pitData['pitBoxes'])
    end
    
    local trackData = sm.storage.load(TRACK_STORAGE_CHANNEL)
    if trackData then
        if trackData['raceChain'] then self.trackNodeChain = trackData['raceChain']
        elseif trackData.nodes then self.trackNodeChain = trackData.nodes
        else self.trackNodeChain = trackData end
    end
end

function RaceControl.exportSimplifyChain(self, nodeChain)
    local simpChain = {}
    for k, v in ipairs(nodeChain) do
        local x, y, z
        if type(v.location) == "table" and v.location.x then
             x, y, z = v.location.x, v.location.y, v.location.z
        elseif type(v.location) == "userdata" then
             x, y, z = v.location.x, v.location.y, v.location.z
        else x, y, z = 0, 0, 0 end
        
        local newNode = {
            id = v.id, midX = x, midY = y, midZ = z, 
            width = v.width, sid = v.sectorID or 1
        }
        table.insert(simpChain, newNode)
    end
    return simpChain
end

function RaceControl.sv_export_map_for_overlay(self)
    local nodeChain = self.trackNodeChain
    if nodeChain then
        local exportableChain = self:exportSimplifyChain(nodeChain)
        sm.json.save(exportableChain, MAP_DATA_PATH)
    end
end

-- --- CLEANUP & INTERACTION ---

function RaceControl.server_onDestroy(self)
    RACE_CONTROL = nil
    if self.PitManager then self.PitManager:server_onDestroy() end
    self:sv_delete_all_racers() 
end

function RaceControl.client_onDestroy(self)
    if self.CameraManager then self.CameraManager:client_onDestroy() end
    if self.PitManager then self.PitManager:client_onDestroy() end
    if self.UIManager then self.UIManager:destroy() end
end

function RaceControl.client_canInteract(self, character) return true end
function RaceControl.client_onInteract(self, character, state) 
    if state and self.UIManager then
        self.UIManager:open()
    end
end

function RaceControl.sv_delete_driver_entity(self, driver)
    if driver and sm.exists(driver.shape) then
        for _, body in ipairs(driver.body:getCreationBodies()) do
            for _, shape in ipairs(body:getShapes()) do
                shape:destroyShape()
            end
        end
    end
end

function RaceControl.sv_delete_all_racers(self)
    local drivers = getAllDrivers()
    for i = #drivers, 1, -1 do
        self:sv_delete_driver_entity(drivers[i])
    end
end