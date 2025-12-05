-- SMARL CAR AI V4 (Gen 8) Driver
dofile("PerceptionModule.lua")
dofile("DecisionModule.lua")
dofile("ActionModule.lua")
dofile("globals.lua")

DriverGen8 = class(nil)
DriverGen8.maxChildCount = 64
DriverGen8.maxParentCount = 64
DriverGen8.connectionInput = sm.interactable.connectionType.seated + sm.interactable.connectionType.power + sm.interactable.connectionType.logic
DriverGen8.connectionOutput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic + sm.interactable.connectionType.bearing
DriverGen8.colorNormal = sm.color.new(0x76034dff)
DriverGen8.colorHighlight = sm.color.new(0x8f2268ff)

local TUNING_DATA_PATH = "$CONTENT_DATA/JsonData/tuningData.json"
local TRACK_DATA_CHANNEL = "SM_AutoRacers_TrackData" 

function DriverGen8.server_onCreate(self) self:server_init() end
function DriverGen8.client_onCreate(self) self:client_init() end
function DriverGen8.server_onRefresh(self) self:server_init() end
function DriverGen8.client_onRefresh(self) self:client_init() end
function DriverGen8.client_onDestroy(self) if ALL_DRIVERS then for k, v in pairs(ALL_DRIVERS) do if v.id == self.id then table.remove(ALL_DRIVERS, k) end end end end
function DriverGen8.server_onDestroy(self) if ALL_DRIVERS then for k, v in pairs(ALL_DRIVERS) do if v.id == self.id then table.remove(ALL_DRIVERS, k) end end end end

function DriverGen8.server_init(self)
    print("Driver: Initializing Gen 8 AI System...")
    self.id = self.shape.id
    self.body = self.shape:getBody()
    self.interactable = self.shape:getInteractable()
    self.isRacing = false
    self.racing = false
    self.caution = false
    self.formation = false
    self.active = false
    self.onLift = false
    self.liftPlaced = false
    self.resetPosTimeout = 0.0
    self.trackLoaded = false
    self.Tire_Type = 2
    self.Tire_Health = 1.0
    self.Fuel_Level = 1.0
    self.Gear_Length = 0.5
    self.Spoiler_Angle = 0.5
    self.tireLimp = false
    self.carAggression = 0.75
    self.formationSide = 1 
    self.currentLap = 0
    self.bestLap = 0
    self.lastLap = 0
    self.lapStarted = 0
    self.newLap = false
    self.currentSector = 1
    self.lastSectorID = 0
    self.metaData = self.storage:load() or {}
    self.twitchData = {}
    self.twitchCar = false 
    self.carDimensions = nil 

    self.Perception = PerceptionModule()
    self.Perception:server_init(self, nil) 
    self.Decision = DecisionModule()
    self.Decision:server_init(self)
    self.Action = ActionModule()
    self.Action:server_init(self)
    
    self:sv_loadTrackData()
    self.raceControlError = true
    self:try_raceControl()
    self:sv_addRacer()
end

function DriverGen8.client_init(self)
    if sm.isHost then
        self.player = sm.localPlayer.getPlayer()
        self.network:sendToServer("sv_setPlayer", self.player)
    end
end

function DriverGen8.sv_setPlayer(self, player) self.player = player end

function DriverGen8.server_onFixedUpdate(self, dt)
    self:validate_self()
    local raceActive = (self.isRacing or self.racing)
    if self.interactable.isActive ~= raceActive then self.interactable:setActive(raceActive) end

    local perceptionData = nil
    if self.Perception then
        perceptionData = self.Perception:server_onFixedUpdate(dt)
        self.perceptionData = perceptionData 
        if perceptionData.Telemetry and perceptionData.Telemetry.dimensions then
            self.carDimensions = perceptionData.Telemetry.dimensions
        end
    end

    local decisionData = nil
    if self.Decision and perceptionData then
        decisionData = self.Decision:server_onFixedUpdate(perceptionData, dt)
        self.decisionData = decisionData
    end

    if self.Action and decisionData then
        self.Action:server_onFixedUpdate(decisionData)
        if decisionData.resetCar then self:resetCar() end
    end

    self:checkSectorCross()
    self:checkLapCross()
    self:handleTireWear(dt)
end

function DriverGen8.resetCar(self, force)
    local isOnLift = self.perceptionData and self.perceptionData.Telemetry and self.perceptionData.Telemetry.isOnLift
    if self.resetPosTimeout < 10 and not isOnLift and not force then
        self.resetPosTimeout = self.resetPosTimeout + 0.1
        return 
    end
    if not self.raceControlError then
        local rc = getRaceControl()
        if rc and not rc:sv_checkReset() then return end 
        if rc then rc:sv_resetCar() end
    end
    if isOnLift then return end
    if not self.liftPlaced and (self.racing or force) then
        local resetNode = self.Perception and self.Perception.currentNode 
        if not resetNode and self.nodeChain and #self.nodeChain > 4 then 
            resetNode = self.nodeChain[4] 
        end
        if resetNode and resetNode.outVector then
            local location = resetNode.mid or resetNode.location
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

function DriverGen8.handleTireWear(self, dt)
    if getRaceControl() == nil or (getRaceControl() and getRaceControl().tireWearEnabled == false) then return end
    local telemetry = self.perceptionData and self.perceptionData.Telemetry
    local decision = self.decisionData
    if not self.Tire_Type or not telemetry or not decision or telemetry.speed <= 15 then return end
    local profile = TIRE_TYPES[self.Tire_Type] or {DECAY=0.2, MAX_SLIP_FACTOR=1.0}
    local tireDecayRate = profile.DECAY or 0.2
    local slipFactor = profile.MAX_SLIP_FACTOR or 1.0
    local speed = telemetry.speed
    local baseWear = tireDecayRate * dt * 0.0001
    local longWear = (math.abs(decision.throttle) + math.abs(decision.brake)) * (speed / 100) * 0.00005 
    local yawRate = 0
    if telemetry.angularVelocity and telemetry.rotations then
        yawRate = telemetry.angularVelocity:dot(telemetry.rotations.up)
    end
    local lateralWear = (yawRate * yawRate) * (speed / 50) * slipFactor * 0.00008 
    local totalDecreaseRate = (baseWear + longWear + lateralWear) * getRaceControl().tireWearMultiplier
    self.Tire_Health = self.Tire_Health - totalDecreaseRate
    if self.Tire_Health <= 0.05 then
        if not self.tireLimp then 
            print("Tires DEAD - LIMP MODE ACTIVATED")
            self.tireLimp = true
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

function DriverGen8.sv_load_tuning_data(self)
    if not self.metaData or not self.metaData.ID or self.twitchCar then return end
    if getRaceControl() and getRaceControl().tuningEnabled == false then return end
    local success, data = pcall(sm.json.open, TUNING_DATA_PATH)
    if not success then return end
    local car_data = getKeyValue(data, 'racer_id', self.metaData.ID)
    if not car_data then return end
    self.Tire_Type = tonumber(car_data.tire_type)
    self.Fuel_Level = tonumber(car_data.fuel_level)
    self.Gear_Length = tonumber(car_data.gear_length)
    self.Spoiler_Angle = tonumber(car_data.aero_angle)
    if self.engine and self.engine.engineStats then
        local baseStats = getEngineType(self.engine.engineColor)
        self.engine.engineStats = self.engine:generateNewEngine(baseStats) 
        if self.Spoiler_Angle < 5 then 
            self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED * 1.1
        end
    end
    if self.Decision then
        self.Decision:calculateCarPerformance()
    end
end

function DriverGen8.validate_self(self)
    if not sm.exists(self.shape) then return end
    if self.body ~= self.shape:getBody() then self.body = self.shape:getBody() end
    if getDriverFromId(self.id) == nil then self:sv_addRacer() end
    if self.raceControlError then self:try_raceControl() end
end

function DriverGen8.try_raceControl(self)
    local raceControl = getRaceControl()
    if raceControl then
        if self.raceControlError then self.raceControlError = false end
        self:sv_sendCommand({car = {self.id}, type = "get_raceStatus", value = 1})
    else
        self.raceControlError = true
    end
end

function DriverGen8.sv_addRacer(self)
    if not ALL_DRIVERS then ALL_DRIVERS = {} end
    table.insert(ALL_DRIVERS, self)
    self:sv_sendCommand({car = {self.id}, type = "add_racer", value = 1})
end

function DriverGen8.sv_sendCommand(self, command)
    local raceControl = getRaceControl()
    if raceControl then raceControl:sv_recieveCommand(command) end
end

function DriverGen8.sv_recieveCommand(self, command)
    if not command then return end
    if command.type == "raceStatus" then
        if command.value == 1 then 
            self.racing = true; self.isRacing = true; self.caution = false; self.formation = false
        elseif command.value == 0 then
            self.racing = false; self.isRacing = false
        elseif command.value == 2 then
            self.caution = true; self.racing = true; self.isRacing = true
        elseif command.value == 3 then
            self.formation = true; self.racing = true; self.isRacing = true
        end
    elseif command.type == "handicap" then
        -- Handle handicap
    elseif command.type == "pit" then
        -- Handle pit
    end
end

function DriverGen8.sv_loadTrackData(self)
    local data = sm.storage.load(TRACK_DATA_CHANNEL)
    if data then self:on_trackLoaded(data) else print("Driver: No track data found.") end
end

function DriverGen8.deserializeTrackNode(self, dataNode)
    local function toVec3(t) if not t then return nil end return sm.vec3.new(t.x, t.y, t.z) end
    return {
        id = dataNode.id, location = toVec3(dataNode.pos), mid = toVec3(dataNode.pos),
        width = dataNode.width, bank = dataNode.bank, incline = dataNode.incline,
        outVector = toVec3(dataNode.out), perp = toVec3(dataNode.perp),
        isJump = dataNode.isJump, sectorID = dataNode.sectorID or 1
    }
end

function DriverGen8.on_trackLoaded(self, data)
    if not data then self.trackLoaded = false return end
    local rawNodes = nil
    if data['raceChain'] then rawNodes = data['raceChain']
    elseif data.nodes then rawNodes = data.nodes
    else rawNodes = data end
    if not rawNodes then return end
    self.nodeChain = {}
    for i, nodeData in ipairs(rawNodes) do
        if type(nodeData.location) == "userdata" then table.insert(self.nodeChain, nodeData)
        else table.insert(self.nodeChain, self:deserializeTrackNode(nodeData)) end
    end
    if data['pitChain'] then self.pitChain = data['pitChain'] end
    self.trackLoaded = true
    if self.Perception then
        self.Perception.chain = self.nodeChain
        if self.Perception.currentNode == nil then self.Perception:findClosestPointOnTrack(nil, self.nodeChain) end
    end
end

function DriverGen8.checkSectorCross(self)
    local currentNav = self.perceptionData and self.perceptionData.Navigation
    if currentNav and currentNav.closestPointData then
        local currentSector = currentNav.closestPointData.baseNode.sectorID
        if self.lastSectorID ~= currentSector then
             self.lastSectorID = currentSector
             self.currentSector = currentSector
             self:sv_sendCommand({ car = self.id, type = "sector_cross", value = currentSector, time = sm.game.getServerTick() / 40.0 })
        end
    end
end

function DriverGen8.checkLapCross(self)
    if not self.nodeChain or not self.location or not self.perceptionData then return end
    local currentNode = self.Perception and self.Perception.currentNode
    if not currentNode then return end
    local totalNodes = #self.nodeChain
    local cID = currentNode.id
    if cID > 5 and cID < (totalNodes - 5) then self.newLap = false return end
    local startLine = self.nodeChain[1]
    if not startLine then return end
    local sideWidth = startLine.width / 1.8 
    local axis = startLine.perp or sm.vec3.new(1,0,0) 
    local bufferDistance = 2.5 
    local forwardVec = startLine.outVector or sm.vec3.new(0,1,0)
    local checkLocation = self.location
    if self.carDimensions and self.carDimensions['front'] then
        local frontOffset = self.shape:getAt() * self.carDimensions['front']:length()
        checkLocation = self.location + frontOffset
    end
    local relativePos = checkLocation - startLine.location
    local forwardDist = relativePos:dot(forwardVec)
    local lateralDist = relativePos:dot(axis)       
    local crossed = (math.abs(forwardDist) < bufferDistance) and (math.abs(lateralDist) < sideWidth)
    if crossed and not self.newLap then self:handleLapCross() end
end

function DriverGen8.handleLapCross(self)
    if self.newLap then return end 
    self.newLap = true
    self.currentLap = self.currentLap + 1
    local now = CLOCK()
    local lapTime = now - (self.lapStarted or now)
    if self.currentLap > 1 then
        if self.bestLap == 0 or lapTime < self.bestLap then self.bestLap = lapTime end
        self.lastLap = lapTime
    end
    self.lapStarted = now
    self:sv_sendCommand({ car = self.id, type = "lap_cross", value = now, lapTime = lapTime })
    if self.pitIn then self.pitIn = false end
    if self.pitOut then self.pitOut = false end
end

function DriverGen8.on_engineLoaded(self, data)
    if not data then return end
    self.engine = data
    self:sv_load_tuning_data()
end
function DriverGen8.on_engineDestroyed(self, data) self.engine = nil end
function DriverGen8.client_canTinker(self, character) return true end
function DriverGen8.client_onTinker(self, character, state) end
function DriverGen8.client_onInteract(self, character, state) end