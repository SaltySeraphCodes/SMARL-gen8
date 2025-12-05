-- SMARL CAR AI V4 (Gen 8) Driver
-- Orchestrates Perception, Decision, and Action modules.
-- Handles networking, tuning, and race state management.

dofile("PerceptionModule.lua")
dofile("DecisionModule.lua")
dofile("ActionModule.lua")
dofile("globalsGen8.lua")

Driver = class(nil)
Driver.maxChildCount = 64
Driver.maxParentCount = 64
Driver.connectionInput = sm.interactable.connectionType.seated + sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Driver.connectionOutput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic + sm.interactable.connectionType.bearing
Driver.colorNormal = sm.color.new(0x76034dff)
Driver.colorHighlight = sm.color.new(0x8f2268ff)

-- Constants
local TUNING_DATA_PATH = "$CONTENT_DATA/JsonData/tuningData.json"
-- Must match the channel used in TrackScanner.lua
local TRACK_DATA_CHANNEL = "SM_AutoRacers_TrackData" 

-- --- ENGINE EVENTS ---

function Driver.server_onCreate(self)
    self:server_init()
end

function Driver.client_onCreate(self)
    self:client_init()
end

function Driver.server_onRefresh(self)
    self:server_init()
end

function Driver.client_onRefresh(self)
    self:client_init()
end

function Driver.client_onDestroy(self)
    -- Remove self from global lists
    if ALL_DRIVERS then
        for k, v in pairs(ALL_DRIVERS) do
            if v.id == self.id then table.remove(ALL_DRIVERS, k) end
        end
    end
end

function Driver.server_onDestroy(self)
    if ALL_DRIVERS then
        for k, v in pairs(ALL_DRIVERS) do
            if v.id == self.id then table.remove(ALL_DRIVERS, k) end
        end
    end
end

-- --- INITIALIZATION ---

function Driver.server_init(self)
    print("Driver: Initializing Gen 8 AI System...")
    self.id = self.shape.id
    self.body = self.shape:getBody()
    self.interactable = self.shape:getInteractable()
    
    -- State Flags
    self.isRacing = false
    self.racing = false
    self.caution = false
    self.formation = false
    self.active = false
    self.onLift = false
    self.liftPlaced = false
    self.resetPosTimeout = 0.0
    self.trackLoaded = false
    
    -- Tuning Defaults
    self.Tire_Type = 2
    self.Tire_Health = 1.0
    self.Fuel_Level = 1.0
    self.Gear_Length = 0.5
    self.Spoiler_Angle = 0.5
    self.tireLimp = false
    self.carAggression = 0.75 -- Default Aggression
    self.formationSide = 1 -- 1 = Outside, -1 = Inside (Default)

    -- Timing And Lap Data
    self.currentLap = 0
    self.bestLap = 0
    self.lastLap = 0
    self.lapStarted = 0
    self.newLap = false
    self.currentSector = 1
    self.lastSectorID = 0

    -- Meta Data
    self.metaData = self.storage:load() or {}
    self.twitchData = {}
    self.twitchCar = false 
    self.carDimensions = nil -- Will be populated by Perception or defaults

    -- Initialize Modules
    -- We pass 'self' so modules can access body/shape/tuning
    self.Perception = PerceptionModule()
    self.Perception:server_init(self, nil) -- Chain loaded later

    self.Decision = DecisionModule()
    self.Decision:server_init(self)

    self.Action = ActionModule()
    self.Action:server_init(self)
    
    -- Load Track Data
    self:sv_loadTrackData()
    
    -- Register with Race Control
    self.raceControlError = true
    self:try_raceControl()
    self:sv_addRacer()
end

function Driver.client_init(self)
    if sm.isHost then
        self.player = sm.localPlayer.getPlayer()
        self.network:sendToServer("sv_setPlayer", self.player)
    end
end

function Driver.sv_setPlayer(self, player)
    self.player = player
end

-- --- MAIN UPDATE LOOP (40Hz) ---

function Driver.server_onFixedUpdate(self, dt)
    -- 1. Validation & Setup
    self:validate_self()
    
    -- Race Control Logic Output (Start/Stop signal)
    local raceActive = (self.isRacing or self.racing)
    if self.interactable.isActive ~= raceActive then
        self.interactable:setActive(raceActive)
    end

    -- 2. PERCEPTION: Gather Data
    local perceptionData = nil
    if self.Perception then
        -- Perception handles telemetry, track mapping, and opponents
        perceptionData = self.Perception:server_onFixedUpdate(dt)
        self.perceptionData = perceptionData 
        
        -- Update local cache of dimensions if available (calculated when static)
        if perceptionData.Telemetry and perceptionData.Telemetry.dimensions then
            self.carDimensions = perceptionData.Telemetry.dimensions
        end
    end

    -- 3. DECISION: Calculate Commands
    local decisionData = nil
    if self.Decision and perceptionData then
        -- Decision uses perception + internal state to choose mode/PID output
        decisionData = self.Decision:server_onFixedUpdate(perceptionData, dt)
        self.decisionData = decisionData
    end

    -- 4. ACTION: Execute Commands
    if self.Action and decisionData then
        -- Action applies force and steering based on Decision
        self.Action:server_onFixedUpdate(decisionData)
        
        -- Handle Utility Request (Reset Logic)
        if decisionData.resetCar then 
            self:resetCar() 
        end
        
    end

    -- 5. EVENT DETECTION (Laps & Sectors)
    self:checkSectorCross()
    self:checkLapCross()

    -- 6. SYSTEMS: Tire Wear
    self:handleTireWear(dt)
end

-- --- SAFETY & RESET LOGIC ---

function Driver.resetCar(self, force)
    -- Cooldown check
    local isOnLift = self.perceptionData and self.perceptionData.Telemetry and self.perceptionData.Telemetry.isOnLift
    if self.resetPosTimeout < 10 and not isOnLift and not force then
        self.resetPosTimeout = self.resetPosTimeout + 0.1
        return 
    end

    -- Race Control Reset Check
    if not self.raceControlError then
        local rc = getRaceControl()
        if rc and not rc:sv_checkReset() then return end -- Cooldown active
        if rc then rc:sv_resetCar() end
    end

    if isOnLift then return end

    -- Lift Placement Logic
    if not self.liftPlaced and (self.racing or force) then
        -- Use Perception to find a safe reset node, or fallback to start of chain
        local resetNode = self.Perception and self.Perception.currentNode 
        if not resetNode and self.nodeChain and #self.nodeChain > 4 then 
            resetNode = self.nodeChain[4] 
        end
        
        if resetNode and resetNode.outVector then
            local location = resetNode.mid or resetNode.location
            -- Simple conversion to block coordinates (x4? or just use as is depending on your scale)
            -- Assuming nodes are in World Position already.
            
            local rotation = getRotationIndexFromVector(resetNode.outVector, 0.75)
            if rotation == -1 then rotation = getRotationIndexFromVector(resetNode.outVector, 0.45) end
            
            local spawnPos = sm.vec3.new(math.floor(location.x + 0.5), math.floor(location.y + 0.5), math.floor(location.z + 4.5))
            
            local bodies = self.body:getCreationBodies()
            local ok, liftLevel = sm.tool.checkLiftCollision(bodies, spawnPos, rotation)
            
            if self.player then
                if ok then
                    sm.player.placeLift(self.player, bodies, spawnPos, liftLevel, rotation)
                    self.liftPlaced = true
                    self.resetPosTimeout = 0
                else
                    print(self.id, "Reset collision, forcing...")
                    spawnPos = (spawnPos + resetNode.outVector * 2.0) + sm.vec3.new(0,0,3)
                    sm.player.placeLift(self.player, bodies, spawnPos, liftLevel, rotation)
                    self.liftPlaced = true
                    self.resetPosTimeout = 0
                end
            end
        end
    elseif self.liftPlaced and self.player then
        sm.player.removeLift(self.player)
        self.liftPlaced = false
    end
end

-- --- SYSTEM SIMULATION ---

function Driver.handleTireWear(self, dt)
    if getRaceControl() == nil or (getRaceControl() and getRaceControl().tireWearEnabled == false) then return end
    
    local telemetry = self.perceptionData and self.perceptionData.Telemetry
    local decision = self.decisionData
    
    if not self.Tire_Type or not telemetry or not decision or telemetry.speed <= 15 then return end

    local profile = TIRE_TYPES[self.Tire_Type] or {DECAY=0.2, MAX_SLIP_FACTOR=1.0}
    local tireDecayRate = profile.DECAY or 0.2
    local slipFactor = profile.MAX_SLIP_FACTOR or 1.0
    local speed = telemetry.speed
    
    -- Calculate Wear
    local baseWear = tireDecayRate * dt * 0.0001
    local longWear = (math.abs(decision.throttle) + math.abs(decision.brake)) * (speed / 100) * 0.00005 
    
    local yawRate = 0
    if telemetry.angularVelocity and telemetry.rotations then
        yawRate = telemetry.angularVelocity:dot(telemetry.rotations.up)
    end
    local lateralWear = (yawRate * yawRate) * (speed / 50) * slipFactor * 0.00008 

    local totalDecreaseRate = (baseWear + longWear + lateralWear) * getRaceControl().tireWearMultiplier
    
    self.Tire_Health = self.Tire_Health - totalDecreaseRate
    
    -- Update Limp Mode
    if self.Tire_Health <= 0.05 then
        if not self.tireLimp then 
            print("Tires DEAD - LIMP MODE ACTIVATED")
            self.tireLimp = true
            -- Update Decision Module Performance?
            self.Decision:calculateCarPerformance() 
        end
        self.Tire_Health = 0.05 
    else
        if self.tireLimp then
            self.tireLimp = false
            self.Decision:calculateCarPerformance() 
        end
    end
end

function Driver.sv_load_tuning_data(self)
    if not self.metaData or not self.metaData.ID or self.twitchCar then return end
    if getRaceControl() and getRaceControl().tuningEnabled == false then return end

    local success, data = pcall(sm.json.open, TUNING_DATA_PATH)
    if not success then return end

    local car_data = getKeyValue(data, 'racer_id', self.metaData.ID)
    if not car_data then return end

    -- Apply Tuning
    self.Tire_Type = tonumber(car_data.tire_type)
    self.Fuel_Level = tonumber(car_data.fuel_level)
    self.Gear_Length = tonumber(car_data.gear_length)
    self.Spoiler_Angle = tonumber(car_data.aero_angle)

    -- Engine Tuning Logic
    if self.engine and self.engine.engineStats then
        -- Reset to default before applying tune
        local baseStats = getEngineType(self.engine.engineColor)
        self.engine.engineStats = self.engine:generateNewEngine(baseStats) 

        -- Spoiler angle Adjustments
        if self.Spoiler_Angle < 5 then -- increase top speed
            self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED + ((5 - self.Spoiler_Angle) * 1.4)
        elseif self.Spoiler_Angle > 5 then -- decrease top speed
            self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED - ((self.Spoiler_Angle - 5) * 1.7)
        end
        
        -- Gear Length Adjustments
        if self.Gear_Length < 5 then 
            for k=1, #self.engine.engineStats.GEARING do
                self.engine.engineStats.GEARING[k] = mathClamp(0.05,2,self.engine.engineStats.GEARING[k] + ((5/self.Gear_Length)/(10*k)))
            end
            self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED - ((5 - self.Gear_Length) * 0.5)
        elseif self.Gear_Length > 5 then 
            for k=1, #self.engine.engineStats.GEARING do
                self.engine.engineStats.GEARING[k] = mathClamp(0.05,2,self.engine.engineStats.GEARING[k] /(self.Gear_Length*0.16))
            end
            self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED + ((self.Gear_Length - 5) * 1.5)
        end
        self.engine.engineStats.REV_LIMIT = self.engine.engineStats.MAX_SPEED/#self.engine.engineStats.GEARING
    end

    -- IMPORTANT: Notify DecisionModule to update performance constants (Grip, Max Speed)
    if self.Decision then
        self.Decision:calculateCarPerformance()
    end
end

-- --- HELPERS & VALIDATION ---

function Driver.validate_self(self)
    if not sm.exists(self.shape) then return end
    if self.body ~= self.shape:getBody() then self.body = self.shape:getBody() end
    
    -- Re-add to global list if missing
    if getDriverFromId(self.id) == nil then
        print("SV driver Re adding to race")
        self:sv_addRacer()
    end

    if self.raceControlError then self:try_raceControl() end
end

function Driver.try_raceControl(self)
    local raceControl = getRaceControl()
    if raceControl then
        if self.raceControlError then
             print("Connected to Race Control")
             self.raceControlError = false
        end
        self:sv_sendCommand({car = {self.id}, type = "get_raceStatus", value = 1})
    else
        self.raceControlError = true
    end
end

function Driver.sv_addRacer(self)
    if not ALL_DRIVERS then ALL_DRIVERS = {} end
    table.insert(ALL_DRIVERS, self)
    self:sv_sendCommand({car = {self.id}, type = "add_racer", value = 1})
end

function Driver.sv_sendCommand(self, command)
    local raceControl = getRaceControl()
    if raceControl then raceControl:sv_recieveCommand(command) end
end

function Driver.sv_recieveCommand(self, command)
    if not command then return end
    
    if command.type == "raceStatus" then
        if command.value == 1 then -- Start
            self.racing = true
            self.isRacing = true
            self.caution = false
            self.formation = false
        elseif command.value == 0 then -- Stop
            self.racing = false
            self.isRacing = false
        elseif command.value == 2 then -- Caution
            self.caution = true
            self.racing = true
            self.isRacing = true
        elseif command.value == 3 then -- Formation
            self.formation = true
            self.racing = true
            self.isRacing = true
        end
    elseif command.type == "handicap" then
        -- Handle handicap
    elseif command.type == "pit" then
        -- Handle pit
    end
end

-- --- TRACK DATA MANAGEMENT ---

function Driver.sv_loadTrackData(self)
    -- Load from world storage
    local data = sm.storage.load(TRACK_DATA_CHANNEL)
    if data then
        self:on_trackLoaded(data)
    else
        print("Driver: No track data found in storage.")
    end
end

-- Deserialize track data from JSON/Storage format back to usable objects
function Driver.deserializeTrackNode(self, dataNode)
    -- Convert table {x,y,z} back to sm.vec3
    local function toVec3(t)
        if not t then return nil end
        return sm.vec3.new(t.x, t.y, t.z)
    end

    return {
        id = dataNode.id,
        location = toVec3(dataNode.pos),
        mid = toVec3(dataNode.pos), -- Assuming 'pos' stored in scanner was the midline
        width = dataNode.width,
        bank = dataNode.bank,
        incline = dataNode.incline,
        outVector = toVec3(dataNode.out),
        perp = toVec3(dataNode.perp), -- Renamed from perpVector in scanner? Check scanner output.
        isJump = dataNode.isJump,
        sectorID = dataNode.sectorID or 1
    }
end

function Driver.on_trackLoaded(self, data)
    if not data then 
        self.trackLoaded = false 
        return 
    end
    
    local rawNodes = nil
    
    -- Handle legacy vs new format
    if data['raceChain'] then
        rawNodes = data['raceChain']
    elseif data.nodes then -- New TrackScanner format
        rawNodes = data.nodes
    else
        rawNodes = data
    end
    
    if not rawNodes then return end

    -- Process nodes: If they are plain tables (from JSON/Storage), convert to Vec3
    self.nodeChain = {}
    for i, nodeData in ipairs(rawNodes) do
        if type(nodeData.location) == "userdata" then
             table.insert(self.nodeChain, nodeData)
        else
             table.insert(self.nodeChain, self:deserializeTrackNode(nodeData))
        end
    end

    if data['pitChain'] then self.pitChain = data['pitChain'] end
    
    self.trackLoaded = true
    print("Driver: Track Loaded with " .. #self.nodeChain .. " nodes.")
    
    -- Pass the loaded chain to the Perception Module
    if self.Perception then
        self.Perception.chain = self.nodeChain
        -- Re-run any init logic that depended on the chain
        if self.Perception.currentNode == nil then
             -- Force a find
             self.Perception:findClosestPointOnTrack(nil, self.nodeChain)
        end
    end
end

-- --- EVENT DETECTION (Laps & Sectors) ---

function Driver.checkSectorCross(self)
    -- Retrieve current navigation state from Perception module
    local currentNav = self.perceptionData and self.perceptionData.Navigation
    if currentNav and currentNav.closestPointData then
        -- The baseNode tells us roughly where we are along the track
        local currentSector = currentNav.closestPointData.baseNode.sectorID
        
        -- Detect change (Transition from sector X to Y)
        if self.lastSectorID ~= currentSector then
             -- Update local state
             self.lastSectorID = currentSector
             self.currentSector = currentSector
             
             -- Send event to RaceControl (which forwards to Leaderboard)
             self:sv_sendCommand({
                 car = self.id, 
                 type = "sector_cross", 
                 value = currentSector, 
                 time = sm.game.getServerTick() / 40.0 -- timestamp
             })
        end
    end
end

function Driver.checkLapCross(self)
    -- Guards: Cannot check laps if we don't know where the track or car is
    if not self.nodeChain or not self.location or not self.perceptionData then return end
    
    -- We rely on the currentNode from perception for "zone" check
    local currentNode = self.Perception and self.Perception.currentNode
    if not currentNode then return end
    
    local totalNodes = #self.nodeChain
    local cID = currentNode.id
    
    -- Optimization: Only run the expensive geometry check if we are near the start/finish (e.g., last 10% or first 10% of nodes)
    -- Checking "first 5 nodes" handles the actual crossing moment.
    -- Checking "last 5 nodes" prepares us to cross.
    -- If we are in the middle of the track, we just reset the flag and exit.
    if cID > 5 and cID < (totalNodes - 5) then 
        self.newLap = false -- Reset 'newLap' flag so we can trigger it again next time
        return 
    end

    -- Get Start Line Geometry (Node 1)
    local startLine = self.nodeChain[1]
    if not startLine then return end

    -- Calculate Bounds (Once per race would be better, but this is fine)
    local sideWidth = startLine.width / 1.8 -- Slightly wider than track to catch wide cars
    local axis = startLine.perp or sm.vec3.new(1,0,0) -- Perpendicular axis (sideways)
    local bufferDistance = 2.5 -- Forward/Backward thickness of the finish line trigger
    local forwardVec = startLine.outVector or sm.vec3.new(0,1,0)
    
    -- Determine the "Front" of the car for precision
    -- If carDimensions is not available (dynamic/not on lift), fall back to center location
    local checkLocation = self.location
    if self.carDimensions and self.carDimensions['front'] then
        -- If dimensions exist, use the front bumper position
        local frontOffset = self.shape:getAt() * self.carDimensions['front']:length()
        checkLocation = self.location + frontOffset
    end
    
    -- Project car position onto the track axes relative to the Start Line center
    local relativePos = checkLocation - startLine.location
    local forwardDist = relativePos:dot(forwardVec) -- Distance "ahead" or "behind" the line
    local lateralDist = relativePos:dot(axis)       -- Distance "left" or "right" of center
    
    -- Check Intersection:
    -- 1. Must be within the width of the track (lateralDist)
    -- 2. Must be within the thin buffer zone of the line (forwardDist)
    local crossed = (math.abs(forwardDist) < bufferDistance) and (math.abs(lateralDist) < sideWidth)
    
    if crossed and not self.newLap then
        self:handleLapCross()
    end
end

function Driver.handleLapCross(self)
    if self.newLap then return end -- Debounce
    self.newLap = true
    
    self.currentLap = self.currentLap + 1
    local now = CLOCK()
    local lapTime = now - (self.lapStarted or now)
    
    -- 1. Update Internal Stats
    if self.currentLap > 1 then
        if self.bestLap == 0 or lapTime < self.bestLap then
            self.bestLap = lapTime
        end
        self.lastLap = lapTime
    end
    
    self.lapStarted = now
    
    -- 2. Notify Race Control (The Authoritative Logic)
    self:sv_sendCommand({
        car = self.id, 
        type = "lap_cross", 
        value = now, -- Timestamp
        lapTime = lapTime -- Calculated Lap Time
    })
    
    -- 3. Reset Turn-based Logic (if any)
    if self.pitIn then self.pitIn = false end
    if self.pitOut then self.pitOut = false end
end

-- --- ENGINE CALLBACKS ---

function Driver.on_engineLoaded(self, data)
    if not data then return end
    self.engine = data
    self:sv_load_tuning_data()
end

function Driver.on_engineDestroyed(self, data)
    self.engine = nil
end

-- --- INTERACTION ---

function Driver.client_canTinker(self, character) return true end
function Driver.client_onTinker(self, character, state) end
function Driver.client_onInteract(self, character, state) end