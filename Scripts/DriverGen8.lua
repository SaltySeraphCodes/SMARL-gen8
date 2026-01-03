-- SMARL CAR AI V4 (Gen 8) Driver
dofile("PerceptionModule.lua")
dofile("DecisionModule.lua")
dofile("ActionModule.lua")
dofile("GuidanceModule.lua")
dofile("TuningOptimizer.lua")
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


function DriverGen8.server_onDestroy(self)
    -- Can force save profile here if we deem necessary
    if ALL_DRIVERS then for k, v in pairs(ALL_DRIVERS) do if v.id == self.id then table.remove(ALL_DRIVERS, k) 
    end end end 
end

function DriverGen8.server_init(self)
    print("Driver: Initializing Gen 8 AI System...")
    self.id = self.shape.id
    self.carType = "Generic"
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

    -- [Moved for safety]
    self.metaData = self.storage:load() or {}
    self.pitState = 0 -- 0:Race, 1:Req, 2:InLane, 3:ApprBox, 4:Stopped, 5:ExitBox, 6:ExitLane
    self.Tire_Health = 1.0
    self.Fuel_Level = 1.0
    self.Tire_Type = 2

    -- Car Attributes (Initialized at top)
    self.Gear_Length = 0.5
    self.Spoiler_Angle = 0.5
    self.formationSide = 1 
    
    -- [[ NEW: PERSONA SYSTEM ]]
    -- Defines the driver's personality and limits.
    -- Can be: "Aggressive", "Balanced", "Cautious"
    local personas = {
        ["Aggressive"] = { agg = 1.0,  mistake = 0.1,  patience = 0.5 },
        ["Balanced"]   = { agg = 0.75, mistake = 0.05, patience = 1.0 },
        ["Cautious"]   = { agg = 0.5,  mistake = 0.01, patience = 2.0 }
    }
    
    -- Pick Random if not loaded
    self.Persona = self.metaData.Persona or "Balanced" 
    local pStats = personas[self.Persona] or personas["Balanced"]
    
    self.carAggression = pStats.agg
    self.driverMistakeChance = pStats.mistake
    self.driverPatience = pStats.patience -- How long to wait behind a car before dive bombing?
    
    print("Driver:", self.id, "Persona:", self.Persona, "Aggression:", self.carAggression)
    self.currentLap = 0
    self.bestLap = 0
    self.lastLap = 0
    self.lapStarted = 0
    self.newLap = false 
    self.readyToLap = false 
    self.currentSector = 1

    -- Sector timing
    self.lastSectorID = 0
    self.sectorTimes = {0.0, 0.0, 0.0} -- [NEW] Storage for split times
    self.lastSectorTimestamp = 0.0 -- [NEW] To calculate duration
    
    
    -- (Moved to top)
    self.assignedBox = nil
    self.pitTotalTime = 0
    self.pitTimer = 0
    self.pitStrategy = {}
    
    -- Status Flags
    self.tireLimp = false
    self.fuelLimp = false

    -- (Loaded at top)
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
    self.Optimizer = TuningOptimizer()
    self.Optimizer:init(self)
    self.Guidance = GuidanceModule()
    self.Guidance:server_init(self)
    
    self:sv_loadTrackData()
    self.raceControlError = true
    self:try_raceControl()
    self:sv_addRacer()
end

function DriverGen8.client_init(self)
    if not ALL_DRIVERS then ALL_DRIVERS = {} end
    local alreadyExists = false
    for _, driver in ipairs(ALL_DRIVERS) do
        if driver == self then alreadyExists = true break end
    end
    
    if not alreadyExists then
        table.insert(ALL_DRIVERS, self)
    end
    -- 2. Generate Dimensions Locally (So CameraManager has offsets)
    -- We can reuse the global helpers since they are loaded on client too
    if self.shape and self.body then
         self.carDimensions = self:cl_scanDimensions()
    end

    if sm.isHost then
        self.player = sm.localPlayer.getPlayer()
        self.network:sendToServer("sv_setPlayer", self.player)
    end
end

function DriverGen8.sv_setPlayer(self, player) self.player = player end

function DriverGen8.cl_scanDimensions(self)
    local body = self.shape:getBody()
    if not body then return nil end
    local shapes = body:getCreationShapes()
    local origin = self.shape:getWorldPosition()
    local at = self.shape:getAt()
    local right = self.shape:getRight()

    -- Calculate Offsets using Global Helpers
    local front = getDirectionOffset(shapes, at, origin)
    local rear = getDirectionOffset(shapes, at * -1, origin)
    local left = getDirectionOffset(shapes, right * -1, origin)
    local rightVec = getDirectionOffset(shapes, right, origin)

    return {
        front = front,
        rear = rear, 
        left = left,
        right = rightVec
    }
end

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
        if perceptionData.Telemetry and perceptionData.Telemetry.carDimensions then
            self.carDimensions = perceptionData.Telemetry.carDimensions
        end
    end
    if perceptionData and self.Optimizer then
        self.Optimizer:recordFrame(perceptionData, dt)
    end

    self:calculatePrecisePosition()

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

    if self.Decision.latestDebugData then
             -- Debug data syncing logic can go here
    end
    end

    -- 3.5 GUIDANCE (TRAJECTORY LAYER) [[ NEW ]]
    -- Replaces raw output from Decision with refined trajectory
    local guidanceData = nil
    if self.Guidance and decisionData then
        guidanceData = self.Guidance:server_onFixedUpdate(dt, decisionData)
        
        -- Override decisionData with Guidance outputs
        if guidanceData then
            decisionData.steer = guidanceData.steer
            decisionData.targetSpeed = guidanceData.speed -- Action might use this for PID
            -- If Guidance returns explicit throttle/brake, use them. Otherwise let Action handle it.
            if guidanceData.throttle then decisionData.throttle = guidanceData.throttle end
            if guidanceData.brake then decisionData.brake = guidanceData.brake end
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
        self.Action:server_onFixedUpdate(decisionData,dt)
        if decisionData.resetCar then self:resetCar() end
    end

    self:checkSectorCross()
    self:checkLapCross()
    self:handleReset() -- Handles after car has been reset (Should only run when reset called?)
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
            if self.pitStrategy and self.pitStrategy.Fuel_Fill then self.Fuel_Level = 1.0 end
            if self.pitStrategy and self.pitStrategy.Tire_Change then self.Tire_Health = 1.0 end
            
            self.pitState = 5 -- Exit Box
        end
        
    -- STATE 5: Exiting Box / Merging
    elseif self.pitState == 5 then
        -- Check if we reached end of pit chain OR if we hit the merge node
        local isAtEnd = (nav.closestPointData.baseNode.id >= #self.pitChain)
        
        if currentNode.mergeTargetIndex or isAtEnd then
            print(self.id, "MERGING TO TRACK (Triggered)")
            
            self.activeChain = self.nodeChain
            self.pitState = 0
            self.assignedBox = nil
            self.Perception.chain = self.nodeChain
            
            -- If we used the fallback "End of Chain", we need to find where we are on the main track
            if currentNode.mergeTargetIndex then
                local mergeNode = self.nodeChain[currentNode.mergeTargetIndex]
                if mergeNode then self.Perception.currentNode = mergeNode end
            else
                -- Fallback: Force a global search on the main track next tick
                self.Perception.currentNode = nil 
            end
            
            self:handleLapCross() 
        end
    end
end

function DriverGen8.resetCar(self, force)
    local isOnLift = self.perceptionData and self.perceptionData.Telemetry and self.perceptionData.Telemetry.isOnLift
    print ("Driver:", self.id, "Reset Car Requested. On Lift:", tostring(isOnLift),self.liftPlaced, "Force:", tostring(force))
    -- 1. WAIT FOR TIMER
    -- Prevents code spamming. If waiting (timeout < 10) and not on lift, just tick up and exit.
    if self.resetPosTimeout < 10 and not isOnLift and not force then
        self.resetPosTimeout = self.resetPosTimeout + 0.5
        return 
    end

    -- 2. RACE CONTROL CHECK
    if not self.raceControlError then
        local rc = getRaceControl()
        -- If RC says "No Reset Allowed" (e.g. race hasn't started), abort.
        if rc and not rc:sv_checkReset() then return end 
        -- Tell RC we are resetting (so it can flag us/penalize us if needed)
        if rc then rc:sv_resetCar() end
    end
    
    -- Only return if on a lift AND we (the script) didn't put it there.
    -- This allows players to manually lift cars without the script fighting them,
    -- but allows the script to continue processing if IT placed the lift.
    if isOnLift and not self.liftPlaced then return end

    -- 3. EXECUTE RESET
    if not self.liftPlaced and (self.racing or force) then
        if self.Optimizer then self.Optimizer:reportCrash() end
        local bodies = self.body:getCreationBodies()
        
        -- PRIORITY TARGET: The last node we explicitly drove over.
        -- This is much safer than searching by distance, which can snap to the wrong track section.
        local bestNode = self.lastPassedNode or self.resetNode
        
        -- FALLBACK: If memory is empty (start of race?), search by proximity
        if not bestNode and self.nodeChain then
            local bestDistSq = math.huge
            local carPos = self.body:getWorldPosition()
            
            for _, node in ipairs(self.nodeChain) do
                -- We only check nodes in our current (or adjacent) sector to save CPU
                local diff = math.abs(node.sectorID - (self.currentSector or 1))
                if diff <= 1 or diff > 10 then 
                    -- Convert Grid to World for accurate distance check
                    local nodeWorldX = node.location.x * 4
                    local nodeWorldY = node.location.y * 4
                    local dx = carPos.x - nodeWorldX
                    local dy = carPos.y - nodeWorldY
                    local distSq = (dx*dx) + (dy*dy)
                    
                    if distSq < bestDistSq then
                        bestDistSq = distSq
                        bestNode = node
                    end
                end
            end
        end

        -- 4. ATTEMPT PLACEMENT
        if bestNode and bestNode.outVector then
            local spawnAttemptNode = bestNode
            local success = false
            
            -- LOOKAHEAD LOOP:
            -- If the best node is blocked (e.g., by another car or debris),
            -- try the next 10 nodes in the chain until we find a clear spot.
            for i = 0, 10 do
                if not spawnAttemptNode then break end
                
                -- Support both 'mid' (legacy) and 'location' keys
                local loc = spawnAttemptNode.mid or spawnAttemptNode.location
                
                -- Calculate Rotation
                local rot = getRotationIndexFromVector(spawnAttemptNode.outVector, 0.75)
                if rot == -1 then rot = getRotationIndexFromVector(spawnAttemptNode.outVector, 0.45) end
                if rot == -1 then rot = 0 end 
                
                -- [[ CRITICAL FIX ]]: COORDINATE SCALING
                -- The "Working" function multiplied by 4. The broken one didn't.
                -- We restore the multiplier here to convert Grid Units to World Meters.
                local worldX = loc.x * 4
                local worldY = loc.y * 4
                -- Lift the car 4.5 blocks up to clear terrain irregularities
                local worldZ = (loc.z * 4) + 4.5 

                local spawnPos = sm.vec3.new(worldX, worldY, worldZ)
                
                -- Check for collision before placing
                local valid, liftLevel = sm.tool.checkLiftCollision(bodies, spawnPos, rot)
                
                if valid and self.player then
                    print(self.id, "Resetting to Node:", spawnAttemptNode.id, "at", spawnPos)
                    sm.player.placeLift(self.player, bodies, spawnPos, liftLevel, rot)
                    
                    self.liftPlaced = true
                    self.resetPosTimeout = 0
                    
                    -- [[ FIX: Update Perception Immediately ]]
                    -- Tell perception exactly where we are so it doesn't search the whole map.
                    if self.Perception then
                        self.Perception.currentNode = spawnAttemptNode
                    end
                    
                    -- Reset decision module stuck flags
                    if self.Decision then
                        self.Decision.stuckTimer = 0
                        self.Decision.isStuck = false
                        self.Decision.smoothedRadius = 1000 
                    end
                    
                    success = true
                    break
                end
                
                -- If blocked, increment to the next node in the chain
                local nextIdx = (spawnAttemptNode.id % #self.nodeChain) + 1
                spawnAttemptNode = self.nodeChain[nextIdx]
            end
            
            if not success then 
                -- If all 10 nodes were blocked, wait 0.5s (5.0 / 0.1 tick rate) and try again
                self.resetPosTimeout = 5.0 
                print(self.id, "Reset Failed (Collision). Retrying...") 
            end
        else
            print(self.id, "Reset Failed: No valid node found.")
        end
    end
        
    -- 5. LIFT REMOVAL (fires immediately after, no need for delay)
    if isOnLift and self.liftPlaced and self.player then
        sm.player.removeLift(self.player)
        self.liftPlaced = false
        self.resetPosTimeout = 0 
    end
end

function DriverGen8.handleReset(self) -- CHecks if self.liftPlaced and isOnLift, if it is, remove lift and reset liftPlaced
    local isOnLift = self.perceptionData and self.perceptionData.Telemetry and self.perceptionData.Telemetry.isOnLift
    if isOnLift and self.liftPlaced and self.player then
        sm.player.removeLift(self.player)
        self.liftPlaced = false
        self.resetPosTimeout = 0 
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

    elseif command.type == "set_learning_lock" then
        if self.Optimizer then
            -- We respect the global command
            local lockState = command.value
            self.Optimizer:setLearningLock(lockState)
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


-- [[ UPDATED DESERIALIZER ]]
function DriverGen8.deserializeTrackNode(self, dataNode)
    local function toVec3(t) 
        if not t then return nil end 
        return sm.vec3.new(t.x, t.y, t.z) 
    end
    
    local pType = dataNode.pointType or 0
    local isEntry = (pType == 2) 
    
    -- 1. Load Vectors
    -- 'pos' = Optimized Racing Line
    -- 'mid' = Geometric Center Line
    -- 'perp' = Wall-to-Wall Vector (Banking)
    local loadedPerp = toVec3(dataNode.perp)
    local loadedOut = toVec3(dataNode.out)
    local loadedMid = toVec3(dataNode.mid)
    local loadedPos = toVec3(dataNode.pos) or toVec3(dataNode.location) -- Handle legacy

    -- 2. Safety Fallback: Mid defaults to Pos if missing
    if not loadedMid then loadedMid = loadedPos end

    -- 3. Safety Fallback: Perp defaults to Cross Product if missing
    if not loadedPerp and loadedOut then
         -- Guess "Right" by crossing Forward with Global Up
         loadedPerp = loadedOut:cross(sm.vec3.new(0,0,1)):normalize() * -1
    end

    return {
        id = dataNode.id, 
        location = loadedPos, 
        mid = loadedMid, -- Critical for lane offsets
        width = dataNode.width,
        distFromStart = dataNode.dist or 0.0,
        raceProgress = dataNode.prog or 0.0,
        bank = dataNode.bank, 
        incline = dataNode.incline,
        
        outVector = loadedOut, 
        perp = loadedPerp, -- Guaranteed valid vector
        
        isJump = dataNode.isJump, 
        sectorID = dataNode.sectorID or 1,
        pointType = pType,
        isPitEntry = isEntry, 
        mergeTargetIndex = dataNode.mergeIndex or dataNode.mergeTargetIndex
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

    if self.nodeChain and #self.nodeChain > 0 then
        -- The last node's distance is effectively the track length
        self.trackLength = self.nodeChain[#self.nodeChain].distFromStart
    else
        self.trackLength = 1000.0 -- Fallback to prevent divide by zero
    end
end

function DriverGen8.checkSectorCross(self)
    local currentNav = self.perceptionData and self.perceptionData.Navigation
    if not currentNav or not currentNav.closestPointData then return end
    
    local currentSector = currentNav.closestPointData.baseNode.sectorID
    
    -- Only act if we actually changed sectors
    if self.lastSectorID ~= currentSector then
        local now = sm.game.getServerTick() / 40.0 -- Current time in seconds
        local lastTime = self.lastSectorTimestamp or now
        local duration = now - lastTime
        
        -- 1. Record the time for the COMPLETED sector (the one we just left)
        -- If we just entered S2, we finished S1. If we entered S1, we finished S3.
        if self.lastSectorID and self.lastSectorID > 0 then
             -- Round to 3 decimal places for clean JSON
             self.sectorTimes[self.lastSectorID] = tonumber(string.format("%.3f", duration))
        end

        -- 2. Handle New Lap (Entering Sector 1)
        if currentSector == 1 then
             -- Reset sectors for the new lap 
             -- (Note: Sector 3 from previous lap is saved in 'lastLap' total time via checkLapCross)
             self.sectorTimes = {0.0, 0.0, 0.0}
        end
        
        -- 3. Trigger Optimizer (Existing)
        if self.Optimizer then
            self.Optimizer:onSectorComplete(self.lastSectorID, duration)
        end

        -- 4. Update State
        self.lastSectorTimestamp = now
        self.lastSectorID = currentSector
        self.currentSector = currentSector
        
        -- Optional: Send event to RaceControl if you want server-side sector logging
        -- self:sv_sendCommand({ car = self.id, type = "sector_cross", value = currentSector, time = duration })
    end
end

function DriverGen8.calculatePrecisePosition(self)
    -- Safety checks
    if not self.perceptionData or not self.perceptionData.Navigation then return 0 end
    local nav = self.perceptionData.Navigation
    if not nav.closestPointData or not nav.closestPointData.baseNode then return 0 end
    
    local node = nav.closestPointData.baseNode
    local carPos = self.perceptionData.Telemetry.location
    
    -- 1. Base distance of the node
    local baseDist = node.distFromStart or 0.0
    
    -- 2. Add fine-tuning (how far past the node are we?)
    -- Project the car's offset onto the node's forward vector
    local offset = carPos - node.mid
    local fineDist = offset:dot(node.outVector)
    
    -- 3. Calculate Total Linear Distance (Absolute Race Score)
    -- Lap 0 = 0m+, Lap 1 = 1000m+, etc.
    local lapOffset = (self.currentLap or 0) * (self.trackLength or 0)
    
    self.totalRaceDistance = lapOffset + baseDist + fineDist
    return self.totalRaceDistance
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


function DriverGen8.sv_toggleLearningLock(self)
    if self.Optimizer then
        local newState = not self.Optimizer.learningLocked
        self.Optimizer:setLearningLock(newState)
        
        -- Visual Feedback
        local status = newState and "LOCKED" or "UNLOCKED"
        local color = newState and sm.color.new(1,0,0,1) or sm.color.new(0,1,0,1)
        
        -- Play a sound or show an alert (using Interaction text as debug)
        sm.gui.displayAlertText("Physics Learning: " .. status)
        
        -- Optional: Save this preference to metadata so it persists?
        -- self.storage:save({ locked = newState }) 
    end
end


function DriverGen8.client_canInteract(self, character) return true end

function DriverGen8.client_onInteract(self, character, state) 
    if state then -- On Key Down
        self.network:sendToServer("sv_toggleLearningLock")
    end
end


function DriverGen8.client_canTinker(self, character) return true end
function DriverGen8.client_onTinker(self, character, state) end


function DriverGen8:drawDebugLine(startPos, endPos, color, poolName)
    if not self[poolName] then self[poolName] = {} end
    local pool = self[poolName]
    
    local diff = endPos - startPos
    local dist = diff:length()
    local step = 0.5 -- One dot every 0.5 meters
    local count = math.floor(dist / step)
    local dir = diff:normalize()

    -- 1. Update/Create active dots
    for i = 0, count do
        local pos = startPos + (dir * (i * step))
        local eff = pool[i+1]
        
        if not eff then
            eff = sm.effect.createEffect("Loot - GlowItem")
            eff:setScale(sm.vec3.new(0, 0, 0))
            eff:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
            table.insert(pool, eff)
        end
        
        if not eff:isPlaying() then eff:start() end
        eff:setPosition(pos)
        eff:setParameter("Color", color)
    end
    
    -- 2. Hide unused dots from previous frames
    for i = count + 2, #pool do
        if pool[i] then pool[i]:stop() end
    end
end

function DriverGen8.client_onUpdate(self, dt)

    -- Initialize Pool if missing
    if not self.effectPool then self.effectPool = {} end

    if self.shape then self.location = self.shape:getWorldPosition() end
    
    local activeDots = 0

    -- [[ FIX: READ FROM NETWORKED VARIABLE ]]
    -- Previously tried to read self.Decision.latestDebugData (which is nil on client)
    local dbg = self.clientDebugRays 

    if dbg then
        -- 1. MAGENTA: The Final Target
        if dbg.targetPoint then
            if not self.effTarget then 
                self.effTarget = sm.effect.createEffect("Loot - GlowItem")
                self.effTarget:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
                self.effTarget:setScale(sm.vec3.new(0, 0, 0))
                self.effTarget:start()
            end
            self.effTarget:setPosition(dbg.targetPoint)
            
            -- Use Optimizer Status Color
            local statusColor = dbg.statusColor or sm.color.new(1, 0, 1, 1) -- Default Magenta
            self.effTarget:setParameter("Color", statusColor)
        elseif self.effTarget then
            self.effTarget:stop() -- Hide if data is missing but dbg exists
        end

        -- 2. CYAN: The "Future Center" (The Anchor)
        if dbg.futureCenter then
            if not self.effCenter then 
                self.effCenter = sm.effect.createEffect("Loot - GlowItem")
                self.effCenter:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
                self.effCenter:setParameter("Color", sm.color.new(0, 1, 1, 1)) -- Cyan
                self.effCenter:setScale(sm.vec3.new(0, 0, 0))
                self.effCenter:start()
            end
            self.effCenter:setPosition(dbg.futureCenter)
        elseif self.effCenter then
            self.effCenter:stop()
        end
        
        ---- 3. YELLOW LINE: The "Perp" Vector
        --if dbg.futureCenter and dbg.usedPerp then
        --    local startP = dbg.futureCenter
        --    local endP = dbg.futureCenter + (dbg.usedPerp * 5.0) 
        --    self:drawDebugLine(startP, endP, sm.color.new(1,1,0,1), "perpLinePool")
        --end
    end

    -- Cleanup unused effects in the line pool
    for i = activeDots + 1, #self.effectPool do
        local effect = self.effectPool[i]
        if effect and effect:isPlaying() then effect:stop() end
    end
end

function DriverGen8.cl_updateDebugRays(self, data)
    self.clientDebugRays = data
end