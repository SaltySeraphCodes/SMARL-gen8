-- SMARL Race Control V2.0 (Refactored)
-- Orchestrates race management, scoring, UI, Pit Lane, Camera, and External API.

dofile("globals.lua")
dofile("RaceManager.lua")
dofile("Leaderboard.lua")
dofile("TwitchManager.lua")
dofile("PitManager.lua")
dofile("CameraManager.lua")
dofile("UIManager.lua")
dofile("Timer.lua") -- Ensure timer is available

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
    
    -- [FIX] Reset Timer Initialization
    self.resetCarTimer = Timer()
    self.resetCarTimer:start(0)

    -- Race Settings Defaults
    self.handiCapMultiplier = 1.0
    self.draftStrength = 1.0
    self.entriesOpen = true
    
    self.tickTimer = 0
    self.dataOutputTimer = 0
    self.outputRealTime = true
    self.racerImportQueue = {}
    self.spawnTimer = 0
    
    self.trackName = "Unknown Track"
    self:sv_init_track_data()
    self:sv_export_map_for_overlay() 
    
    -- [NEW] Sync Flag
    self.needsSync = false

    -- Initial Sync
    self:sv_syncRaceData()
end

function RaceControl.client_init(self)
    print("RaceControl: Client Init")
    RACE_CONTROL = self
    
    -- [FIX] Added droneOffset initialization to prevent CameraManager crash
    self.droneOffset = sm.vec3.new(0, 0, 15) 

    self.CameraManager = CameraManager()
    self.CameraManager:client_init(self)
    if self.PitManager == nil then self.PitManager = PitManager() end
    self.PitManager:client_init(self)
    self.UIManager = UIManager()
    self.UIManager:init(self)
    
    -- Client State Defaults (will be overwritten by sync)
    self.targetLaps = 10
    self.currentLap = 0
    self.handiCapMultiplier = 1.0
    self.draftStrength = 1.0
    self.tireWearEnabled = false
    self.qualifying = false
    self.entriesOpen = true
end

-- --- MAIN LOOP ---

function RaceControl.server_onFixedUpdate(self, dt)
    if self.resetCarTimer then self.resetCarTimer:tick() end

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

    -- [NEW] Handle Deferred Network Syncs
    if self.needsSync then
        self:sv_syncRaceData()
        self.needsSync = false
    end
end

function RaceControl.client_onFixedUpdate(self, dt)
    if self.CameraManager then self.CameraManager:client_onFixedUpdate() end
    if self.UIManager then self.UIManager:onFixedUpdate() end
end

function RaceControl.client_onUpdate(self, dt)
    if self.CameraManager then self.CameraManager:client_onUpdate(dt) end
end

-- --- DATA SYNC (Server to Client) ---

function RaceControl.sv_syncRaceData(self)
    -- Gather all relevant data for the GUI
    local data = {
        status = self.RaceManager and self.RaceManager.state or 0,
        lapsTotal = self.RaceManager and self.RaceManager.targetLaps or 10,
        lapsCurrent = self.RaceManager and self.RaceManager.currentLap or 0,
        handicap = self.handiCapMultiplier or 1.0,
        draft = self.draftStrength or 1.0,
        tires = self.RaceManager and self.RaceManager.tireWearEnabled or false,
        qualifying = self.RaceManager and self.RaceManager.qualifying or false,
        entries = self.entriesOpen or false
    }
    self.network:setClientData(data)
end

function RaceControl.client_onClientDataUpdate(self, data)
    -- Receive sync and update local properties for UIManager to read
    self.raceMetaData = data
    
    self.targetLaps = data.lapsTotal
    self.currentLap = data.lapsCurrent
    self.handiCapMultiplier = data.handicap
    self.draftStrength = data.draft
    self.tireWearEnabled = data.tires
    self.qualifying = data.qualifying
    self.entriesOpen = data.entries
end

-- --- GUI SERVER CALLBACKS ---

function RaceControl.sv_set_race(self, state)
    if self.RaceManager then self.RaceManager:setState(state) end
    self:sv_syncRaceData()
end

function RaceControl.sv_reset_race(self)
    if self.RaceManager then self.RaceManager:resetRace() end
    self:sv_syncRaceData()
end

function RaceControl.sv_editLapCount(self, delta)
    if self.RaceManager then
        local newLaps = self.RaceManager.targetLaps + delta
        if newLaps < 1 then newLaps = 1 end
        self.RaceManager.targetLaps = newLaps
    end
    self:sv_syncRaceData()
end

function RaceControl.sv_editHandicap(self, delta)
    self.handiCapMultiplier = math.max(0, (self.handiCapMultiplier or 1.0) + delta)
    self:sv_syncRaceData()
end

function RaceControl.sv_editDraft(self, delta)
    self.draftStrength = math.max(0, (self.draftStrength or 1.0) + delta)
    self:sv_syncRaceData()
end

function RaceControl.sv_toggleTireWear(self)
    if self.RaceManager then
        self.RaceManager.tireWearEnabled = not self.RaceManager.tireWearEnabled
    end
    self:sv_syncRaceData()
end

function RaceControl.sv_toggleQualifying(self)
    if self.RaceManager then
        self.RaceManager.qualifying = not self.RaceManager.qualifying
    end
    self:sv_syncRaceData()
end

function RaceControl.sv_toggleEntries(self)
    self.entriesOpen = not self.entriesOpen
    self:sv_syncRaceData()
end

-- --- RACER IMPORT LOGIC ---

function RaceControl.checkForClearTrack(self, nodeID, chain)
    local clearFlag = true
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
        
        targetNodeIndex = ((targetNodeIndex - 1) % #self.trackNodeChain) + 1

        local node = self.trackNodeChain[targetNodeIndex]
        if node then
            spawnLocation = node.location + sm.vec3.new(0,0,0.5)
            
            local isClear = self:checkForClearTrack(targetNodeIndex, self.trackNodeChain)
            if not isClear then
                print("RaceControl: Spawn zone blocked. Retrying later...")
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
        -- [FIX] Don't sync immediately (causes Sandbox Error). Defer it.
        self.needsSync = true 
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
            pitTimer = driver.pitTimer or 0, 
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
    local trackData = sm.storage.load(TRACK_DATA_CHANNEL)
    
    if trackData then
        -- Load Main Race Chain
        if trackData.raceChain then 
            self.trackNodeChain = trackData.raceChain
        elseif trackData.nodes then 
            self.trackNodeChain = trackData.nodes
        else 
            self.trackNodeChain = trackData 
        end
        
        -- Load Pit Chain and Send to PitManager
        -- [FIX] Disabled loading old manual PIT_DATA for now
        -- local manualPitData = sm.storage.load(PIT_DATA) or {} 
        -- local pitBoxes = manualPitData.pitBoxes or {} 
        local pitBoxes = nil -- Force nil to trigger anchor-based fallback in PitManager

        if self.PitManager then
            local pitChain = trackData.pitChain
            self.PitManager:sv_loadPitData(pitChain, pitBoxes)
        end
    else
        print("RaceControl: No Track Data Found!")
    end
end

function RaceControl.exportSimplifyChain(self, nodeChain)
    local simpChain = {}
    for k, v in ipairs(nodeChain) do
        local x, y, z
        local mx, my, mz
        if type(v.location) == "table" and v.location.x then
             x, y, z = v.location.x, v.location.y, v.location.z
        elseif type(v.location) == "userdata" then
             x, y, z = v.location.x, v.location.y, v.location.z
        elseif type(v.mid) == "userdata" then
             mx, my, mz = v.mid.x, v.mid.y, v.mid.z
        elseif type(v.mid) == "userdata" then
            mx, my, mz = v.mid.x, v.mid.y, v.mid.z
        else x, y, z = 0, 0, 0 end
        
        local newNode = {
            id = v.id, midX = mx, midY = my, midZ = mz,
            raceX = x, raceY = y, raceZ = z,
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

function RaceControl.client_canInteract(self, character) 
    if character:isCrouching() then
        sm.gui.setInteractionText("WARNING:", sm.gui.getKeyBinding("Tinker", true), "DELETE ALL RACERS")
    else
        -- Show standard open command with a hint about the hidden feature
        sm.gui.setInteractionText("Open Control", sm.gui.getKeyBinding("Use", true), "Crouch+Tinker to Clear")
    end
    return true 
end

function RaceControl.client_onInteract(self, character, state) 
    if state and self.UIManager then
        self.UIManager:open()
    end
end

function RaceControl.client_canTinker(self, character) return true end

function RaceControl.client_onTinker(self, character, state) 
    -- Only trigger on key press (state = true)
    if state then
        -- Check if the player is crouching
        if character:isCrouching() then
            -- Audio/Visual Feedback
            sm.audio.play("PaintTool - Erase", self.shape:getWorldPosition())
            sm.gui.displayAlertText("COMMAND: Clearing Grid...", 2.5)
            
            -- Send Command
            self.network:sendToServer("sv_delete_all_racers")
        else
            -- Helper text if they try to tinker while standing
            sm.gui.displayAlertText("Safety Lock: Hold CROUCH to Delete Racers", 2.0)
            sm.audio.play("Button off", self.shape:getWorldPosition())
        end
    end
end

-- --- GUI CALLBACK PROXIES ---
function RaceControl.cl_onBtnStart(self) self.UIManager:cl_onBtnStart() end
function RaceControl.cl_onBtnStop(self) self.UIManager:cl_onBtnStop() end
function RaceControl.cl_onBtnCaution(self) self.UIManager:cl_onBtnCaution() end
function RaceControl.cl_onBtnFormation(self) self.UIManager:cl_onBtnFormation() end
function RaceControl.cl_onBtnEntries(self) self.UIManager:cl_onBtnEntries() end
function RaceControl.cl_onBtnReset(self) self.UIManager:cl_onBtnReset() end
function RaceControl.cl_onSettingsChange(self, btn) self.UIManager:cl_onSettingsChange(btn) end
function RaceControl.cl_onToggleSetting(self, btn) self.UIManager:cl_onToggleSetting(btn) end
function RaceControl.cl_onPopUpResponse(self, btn) self.UIManager:cl_onPopUpResponse(btn) end
function RaceControl.cl_onClose(self) self.UIManager:cl_onClose() end

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

function RaceControl.sv_delete_racer_by_meta(self, metaID)
    local drivers = getAllDrivers()
    for _, driver in ipairs(drivers) do
        if (driver.metaData and tonumber(driver.metaData.ID) == tonumber(metaID)) or 
           (driver.twitchData and driver.twitchData.uid == tostring(metaID)) then
            self:sv_delete_driver_entity(driver)
            return
        end
    end
end

function RaceControl.sv_delete_racer_by_body(self, bodyID)
    local drivers = getAllDrivers()
    for _, driver in ipairs(drivers) do
        if driver.body and driver.body.id == bodyID then
            self:sv_delete_driver_entity(driver)
            return
        end
    end
end

-- [FIX] Missing Reset Functions
function RaceControl.sv_checkReset(self)
    return self.resetCarTimer:done()
end

function RaceControl.sv_resetCar(self)
    -- Sets timer for 80 ticks (2 seconds) to avoid spamming
    self.resetCarTimer:start(80)
end