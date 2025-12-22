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

-- Fuel Constants
local FUEL_CONSUMPTION_RATE = 0.00005 
local DRAG_CONSUMPTION_FACTOR = 0.00002 

function DriverGen8.server_onCreate(self) self:server_init() end
function DriverGen8.client_onCreate(self) self:client_init() end
function DriverGen8.server_onRefresh(self) self:server_init() end
function DriverGen8.client_onRefresh(self) self:client_init() end
function DriverGen8.client_onDestroy(self) 
    if ALL_DRIVERS then 
        for k, v in pairs(ALL_DRIVERS) do 
            if v.id == self.id then table.remove(ALL_DRIVERS, k) end 
        end 
    end
    
    if self.effectPool then
        for _, effect in ipairs(self.effectPool) do
            if effect and sm.exists(effect) then
                effect:destroy()
            end
        end
        self.effectPool = {}
    end
end


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
    
    -- Car Attributes
    self.Tire_Type = 2
    self.Tire_Health = 1.0
    self.Fuel_Level = 1.0
    self.Gear_Length = 0.5
    self.Spoiler_Angle = 0.5
    self.carAggression = 0.75
    self.formationSide = 1 
    
    -- Race State
    self.currentLap = 0
    self.bestLap = 0
    self.lastLap = 0
    self.lapStarted = 0
    self.newLap = false 
    self.readyToLap = false 
    self.currentSector = 1
    self.lastSectorID = 0
    
    -- Pit State
    self.pitState = 0 -- 0:Race, 1:Req, 2:InLane, 3:ApprBox, 4:Stopped, 5:ExitBox, 6:ExitLane
    self.assignedBox = nil
    self.pitTotalTime = 0
    self.pitTimer = 0
    self.pitStrategy = {}
    
    -- Status Flags
    self.tireLimp = false
    self.fuelLimp = false

    self.metaData = self.storage:load() or {}
    self.twitchData = {}
    self.twitchCar = false 
    self.carDimensions = nil 
    self.cameraPoints = 0

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

    -- 1. PERCEPTION
    local perceptionData = nil
    if self.Perception then
        -- DYNAMIC CHAIN SELECTION
        -- Update the perception module to use the correct chain (Main or Pit)
        self.Perception.chain = self.activeChain or self.nodeChain
        
        perceptionData = self.Perception:server_onFixedUpdate(dt)
        self.perceptionData = perceptionData 
        if perceptionData.Telemetry and perceptionData.Telemetry.dimensions then
            self.carDimensions = perceptionData.Telemetry.dimensions
        end
    end

    -- 2. LOGIC (PIT & RACE)
    -- Handle Pit State Machine overrides
    if self.pitState > 0 then
        self:updatePitBehavior(dt)
    end

    -- 3. DECISION
    local decisionData = nil
    if self.Decision and perceptionData then
        -- Pass pit state to decision module for speed limits
        self.Decision.pitState = self.pitState
        decisionData = self.Decision:server_onFixedUpdate(perceptionData, dt)
        self.decisionData = decisionData

        -- [[ MISSING VISUALIZATION NETWORKING RESTORED HERE ]]
        if self.Decision.latestDebugData then
             -- Throttle: Send only every 3 ticks to save bandwidth
             local tick = sm.game.getServerTick()
             if tick % 4 == 0 then
                 self.network:sendToClients("cl_updateDebugRays", self.Decision.latestDebugData)
             end
        end
    end

    -- 4. ACTION
    if self.Action and decisionData then
        -- Override controls if stopped in pit
        if self.pitState == 4 then
            decisionData.throttle = 0
            decisionData.brake = 1.0
            decisionData.steer = 0
        end
        self.Action:server_onFixedUpdate(decisionData)
        if decisionData.resetCar then self:resetCar() end
    end

    self:checkSectorCross()
    self:checkLapCross()
    self:handleTireWear(dt)
    self:handleFuelUsage(dt)
end

function DriverGen8.sv_setup_pit(self, strategy)
    if self.pitState == 0 then
        print(self.id, "Pit Stop Requested")
        self.pitState = 1 -- Requesting Entry
        self.pitStrategy = strategy
    end
end

function DriverGen8.updatePitBehavior(self, dt)
    local nav = self.perceptionData and self.perceptionData.Navigation
    local currentNode = nav and nav.closestPointData and nav.closestPointData.baseNode
    
    if not currentNode then return end

    -- STATE 1: Requesting / Searching for Entry
    if self.pitState == 1 then
        -- CHECK 1: Local Flag (Legacy/Scanner support)
        local isEntry = currentNode.isPitEntry 
        
        -- CHECK 2: Global Manager (Robustness)
        if not isEntry then
            local rc = getRaceControl()
            if rc and rc.PitManager then
                isEntry = rc.PitManager:isPitEntryNode(currentNode.id)
            end
        end

        if isEntry then
            print(self.id, "ENTERING PIT LANE")
            self.activeChain = self.pitChain
            self.pitState = 2 -- In Lane
            -- Snap Perception to new chain immediately?
            self.Perception.chain = self.pitChain
            self.Perception.currentNode = self.pitChain[1]
        end
        
    -- STATE 2: In Pit Lane / Approach Box
    elseif self.pitState == 2 then
        if self.assignedBox then
            local dist = (self.perceptionData.Telemetry.location - self.assignedBox.location):length()
            if dist < 10.0 then
                self.pitState = 3 -- Final Approach
            end
        end
        
    -- STATE 3: Final Approach (Slow & Precision)
    elseif self.pitState == 3 then
        local dist = (self.perceptionData.Telemetry.location - self.assignedBox.location):length()
        if dist < 1.5 and self.perceptionData.Telemetry.speed < 2.0 then
            print(self.id, "STOPPED IN BOX")
            self.pitState = 4
            self.pitTimer = self.pitTotalTime or 5.0
        end
        
    -- STATE 4: Servicing
    elseif self.pitState == 4 then
        self.pitTimer = self.pitTimer - dt
        if self.pitTimer <= 0 then
            print(self.id, "SERVICE COMPLETE")
            -- Refuel / Tire Change
            if self.pitStrategy.Fuel_Fill then self.Fuel_Level = 100 end
            if self.pitStrategy.Tire_Change then self.Tire_Health = 100 end
            
            self.pitState = 5 -- Exit Box
        end
        
    -- STATE 5: Exiting Box / Merging
    elseif self.pitState == 5 then
        -- Check if we reached end of pit chain
        if currentNode.mergeTargetIndex then
            print(self.id, "MERGING TO TRACK")
            self.activeChain = self.nodeChain
            self.pitState = 0
            self.assignedBox = nil
            self.Perception.chain = self.nodeChain
            -- Snap to merge node
            local mergeNode = self.nodeChain[currentNode.mergeTargetIndex]
            if mergeNode then self.Perception.currentNode = mergeNode end
            
            -- FORCE LAP CHECK (If pit lane skipped start line)
            -- We assume pitting constitutes a lap if successful
            self:handleLapCross() 
        end
    end
end

function DriverGen8.resetCar(self, force)
    local isOnLift = self.perceptionData and self.perceptionData.Telemetry and self.perceptionData.Telemetry.isOnLift
    
    -- 1. WAIT FOR TIMER (Prevents spamming the code while waiting)
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
        local bodies = self.body:getCreationBodies()
        
        -- 2. SECTOR-BASED SEARCH
        -- Only look for nodes that match our current race sector (or adjacent ones)
        -- This prevents snapping to a bridge above us or a hairpin next to us.
        local bestNode = nil
        local bestDistSq = math.huge
        local carPos = self.body:getWorldPosition()
        local mySector = self.currentSector or 1
        
        if self.nodeChain then
            for _, node in ipairs(self.nodeChain) do
                -- Filter: Allow Current Sector, Previous, or Next (Handle wrap around 1->End later)
                local diff = math.abs(node.sectorID - mySector)
                if diff <= 1 or diff > 10 then -- (>10 assumes large track wrap-around)
                    
                    -- Ignore Height (Z) for the search
                    local dx = carPos.x - node.location.x
                    local dy = carPos.y - node.location.y
                    local distSq = (dx*dx) + (dy*dy)
                    
                    if distSq < bestDistSq then
                        bestDistSq = distSq
                        bestNode = node
                    end
                end
            end
        end

        if bestNode and bestNode.outVector then
            local spawnAttemptNode = bestNode
            local success = false
            
            -- Try 10 nodes forward
            for i = 0, 10 do
                if not spawnAttemptNode then break end
                
                local loc = spawnAttemptNode.mid or spawnAttemptNode.location
                local rot = getRotationIndexFromVector(spawnAttemptNode.outVector, 0.75)
                if rot == -1 then rot = getRotationIndexFromVector(spawnAttemptNode.outVector, 0.45) end
                if rot == -1 then rot = 0 end 
                
                -- Spawn 3.0m up
                local spawnPos = sm.vec3.new(loc.x, loc.y, loc.z + 3.0)
                
                local valid, liftLevel = sm.tool.checkLiftCollision(bodies, spawnPos, rot)
                if valid and self.player then
                    sm.player.placeLift(self.player, bodies, spawnPos, liftLevel, rot)
                    self.liftPlaced = true
                    self.resetPosTimeout = 0
                    print(self.id, "Reset Success at Node:", spawnAttemptNode.id, "Sector:", spawnAttemptNode.sectorID)
                    
                    if self.Decision then
                        self.Decision.stuckTimer = 0
                        self.Decision.isStuck = false
                        self.Decision.smoothedRadius = 1000 
                    end
                    success = true
                    break
                end
                
                -- Next node
                local nextIdx = (spawnAttemptNode.id % #self.nodeChain) + 1
                spawnAttemptNode = self.nodeChain[nextIdx]
            end
            
            if not success then 
                -- Log failure to help debug
                print(self.id, "Reset Failed: Collision. Nearest Node:", bestNode.id) 
            end
        end
        
    elseif self.liftPlaced and self.player then
        sm.player.removeLift(self.player)
        self.liftPlaced = false
    end
end

function DriverGen8.handleTireWear(self, dt)
    local rc = getRaceControl()
    if rc == nil or (rc.RaceManager and rc.RaceManager.tireWearEnabled == false) then return end
    
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
    
    local multiplier = (rc.RaceManager and rc.RaceManager.tireWearMultiplier) or 1.0
    local totalDecreaseRate = (baseWear + longWear + lateralWear) * multiplier
    
    self.Tire_Health = self.Tire_Health - totalDecreaseRate
    
    if self.Tire_Health <= 0.05 then
        if not self.tireLimp then 
            print(self.id, "Tires DEAD - LIMP MODE ACTIVATED")
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

function DriverGen8.handleFuelUsage(self, dt) 
    local rc = getRaceControl()
    if rc == nil or (rc.RaceManager and rc.RaceManager.fuelUsageEnabled == false) then return end
    if self.engine == nil or self.perceptionData == nil then return end

    local telemetry = self.perceptionData.Telemetry
    if not telemetry or telemetry.speed < 5 then return end

    local multiplier = (rc.RaceManager and rc.RaceManager.fuelUsageMultiplier) or 1.0
    
    -- 1. Base Consumption (RPM based)
    local rpmFactor = math.abs(self.engine.curRPM) / 90000
    local baseConsumption = rpmFactor * FUEL_CONSUMPTION_RATE * dt

    -- 2. Drag Consumption (Speed & Spoiler based)
    local dragFactor = (telemetry.speed / 100.0) * (self.Spoiler_Angle / 50.0) 
    
    -- 3. Drafting Bonus
    if self.Decision and self.Decision.currentMode == "Drafting" then
        dragFactor = dragFactor * 0.5 
    end
    
    local dragConsumption = dragFactor * DRAG_CONSUMPTION_FACTOR * dt

    -- 4. Apply Consumption
    local totalConsumption = (baseConsumption + dragConsumption) * multiplier
    self.Fuel_Level = self.Fuel_Level - totalConsumption

    -- 5. Limp Mode Logic
    if self.Fuel_Level <= 0.0 then
        if not self.fuelLimp then
            print(self.id, "OUT OF FUEL - LIMP MODE ACTIVATED")
            self.fuelLimp = true
            self.Decision:calculateCarPerformance()
        end
        self.Fuel_Level = 0.0
    else
        if self.fuelLimp then
            self.fuelLimp = false
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
        self:sv_setup_pit(command.value)
    end
end

function DriverGen8.sv_loadTrackData(self)
    local data = sm.storage.load(TRACK_DATA_CHANNEL)
    if data then self:on_trackLoaded(data) else print("Driver: No track data found.") end
end

function DriverGen8.deserializeTrackNode(self, dataNode)
    local function toVec3(t) 
        if not t then return nil end 
        return sm.vec3.new(t.x, t.y, t.z) 
    end
    
    -- Map TrackScanner's "pointType" to Driver flags
    local pType = dataNode.pointType or 0
    local isEntry = (pType == 2) -- Type 2 is Pit Entry in Scanner
    
    return {
        id = dataNode.id, 
        location = toVec3(dataNode.pos), 
        mid = toVec3(dataNode.pos),
        width = dataNode.width, 
        bank = dataNode.bank, 
        incline = dataNode.incline,
        outVector = toVec3(dataNode.out), 
        perp = toVec3(dataNode.perp),
        isJump = dataNode.isJump, 
        sectorID = dataNode.sectorID or 1,
        pointType = pType,
        isPitEntry = isEntry, 
        mergeTargetIndex = nil 
    }
end

function DriverGen8.on_trackLoaded(self, data)
    if not data then self.trackLoaded = false return end
    
    -- Load Race Chain
    local rawNodes = nil
    if data['raceChain'] then rawNodes = data['raceChain']
    elseif data.nodes then rawNodes = data.nodes
    else rawNodes = data end
    
    if rawNodes then
        self.nodeChain = {}
        for i, nodeData in ipairs(rawNodes) do
            if type(nodeData.location) == "userdata" then table.insert(self.nodeChain, nodeData)
            else table.insert(self.nodeChain, self:deserializeTrackNode(nodeData)) end
        end
        self.activeChain = self.nodeChain -- Default to Race Chain
        
        -- Propagate flags created by PitManager (if driver loads AFTER RaceControl)
        -- Note: If driver loads first, it relies on re-sync or RaceControl to manage nodes globally
        -- In optimized version, Drivers should just read nodes passed by RaceControl to save memory
    end

    -- Load Pit Chain
    if data['pitChain'] then 
        self.pitChain = {}
        for i, nodeData in ipairs(data['pitChain']) do
            table.insert(self.pitChain, self:deserializeTrackNode(nodeData))
        end
    end
    
    self.trackLoaded = true
    if self.Perception then
        self.Perception.chain = self.activeChain
        if self.Perception.currentNode == nil then self.Perception:findClosestPointOnTrack(nil, self.activeChain) end
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
    -- Disable lap crossing while in pits to prevent double counting
    -- EXCEPT if we are manually forcing it in updatePitBehavior
    if self.pitState > 0 then return end

    if not self.nodeChain or #self.nodeChain == 0 or not self.perceptionData then return end
    local startNode = self.nodeChain[1]
    if not startNode or not startNode.outVector then return end

    local carPos = self.perceptionData.Telemetry.location
    if not carPos then return end

    local relPos = carPos - startNode.location
    local forwardDist = relPos:dot(startNode.outVector) 
    
    local CROSSING_WINDOW = 10.0 
    local RESET_WINDOW = 20.0    
    local TRACK_WIDTH_BUFFER = (startNode.width or 20.0) * 0.8 
    
    local proj = startNode.outVector * forwardDist
    local latVec = relPos - proj
    local lateralDist = latVec:length()
    
    if lateralDist > TRACK_WIDTH_BUFFER then
         return 
    end

    if forwardDist < -2.0 and forwardDist > -RESET_WINDOW then
        self.readyToLap = true
        self.newLap = false 
    elseif forwardDist >= 0.0 and forwardDist < CROSSING_WINDOW then
        if self.readyToLap and not self.newLap then
            self:handleLapCross()
            self.readyToLap = false 
            self.newLap = true 
        end
    elseif math.abs(forwardDist) > RESET_WINDOW then
        if forwardDist < -RESET_WINDOW then
            self.readyToLap = true 
        else
            self.readyToLap = false 
        end
    end
end

function DriverGen8.handleLapCross(self)
    self.currentLap = self.currentLap + 1
    local now = CLOCK()
    local lapTime = now - (self.lapStarted or now)
    
    if self.currentLap > 1 then
        if self.bestLap == 0 or lapTime < self.bestLap then self.bestLap = lapTime end
        self.lastLap = lapTime
    end
    self.lapStarted = now
    
    print(self.id, "Lap:", self.currentLap, "Time:", lapTime)
    self:sv_sendCommand({ car = self.id, type = "lap_cross", value = now, lapTime = lapTime })
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

function DriverGen8.client_onUpdate(self, dt)
    -- Initialize Pool if missing
    if not self.effectPool then self.effectPool = {} end

    if self.shape then self.location = self.shape:getWorldPosition() end

    -- [[ CoM VISUALIZER ]]
    if self.body and self.shape then -- todo add flag so only when enabled
        local comLocal = self.body:getLocalCenterOfMass()
        local comWorld = self.shape:transformLocalPoint(comLocal) -- changed to localPoint
        -- Draw a Blue Dot at CoM
        local effect = sm.effect.createEffect("Loot - GlowItem", nil)
        effect:setScale(sm.vec3.new(0,0,0))
        effect:setPosition(comWorld)
        effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
        effect:setParameter("Color", sm.color.new(0, 0, 1, 1))
        if not effect:isPlaying() then effect:start() end
        effect:setPosition(comWorld)
    end

    -- Active dot counter

    local activeDots = 0

    if self.clientDebugRays then
        for _, line in ipairs(self.clientDebugRays) do
            -- Color Logic
            local color = sm.color.new(0,1,0,1) 
            if line.c == 2 then color = sm.color.new(1,1,0,1) end 
            if line.c == 3 then color = sm.color.new(1,0,0,1) end 
            if line.c == 4 then color = sm.color.new(0,1,1,1) end 
            
            -- Ray Math
            local dir = (line.e - line.s)
            local length = dir:length()
            local step = 1.5 -- Density of dots
            local normDir = dir:normalize()
            
            for d = 0, length, step do
                activeDots = activeDots + 1
                local worldPos = line.s + (normDir * d)
                
                -- Manage Effect Pool
                local effect = self.effectPool[activeDots]
                if not effect then
                    -- [CHANGE] Host is nil (World Space)
                    effect = sm.effect.createEffect("Loot - GlowItem", nil)
                    effect:setScale(sm.vec3.new(0,0,0)) 
                    effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
                    effect:setParameter("Color", color)
                    
                    table.insert(self.effectPool, effect)
                end
                
                -- Update Effect
                if not effect:isPlaying() then effect:start() end
                
                -- [CHANGE] Set Position directly in World Space
                effect:setPosition(worldPos)
                effect:setParameter("Color", color)
            end
        end
    end

    -- Cleanup: Stop unused effects in the pool
    for i = activeDots + 1, #self.effectPool do
        local effect = self.effectPool[i]
        if effect:isPlaying() then effect:stop() end
    end
end


function DriverGen8.cl_updateDebugRays(self, data)
    self.clientDebugRays = data
end