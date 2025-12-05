
-- SMARL CAR AI V3 (Gen 7) Driver
-- july 12 2021
-- Created by Seraph -- Should be much faster and smarter than Gen 6
-- This is Gen7 SM AR (Scrap Mechanic Auto Racers) AI Driver class, All logic is performed here for both steering and engine, connect to gen7Engine and steering bearings
-- All setups can be changed in the globals.lua file, not much here
-- driver will send steering values of -1..1 which should be comverted between max angle as degrees and vice versa


-- TODO: Send raycast when stuck/offtrack to goal/currentnodes. if there is no obstruction, then keep on rejoin, else, continue to be "stuck"
-- TODO: on car scan, discover 1st 2nd and 3rd color count in creation blocks
-- Car still senses things below?
dofile "globals.lua"
dofile "Timer.lua"
Driver = class( nil )
Driver.maxChildCount = 64
Driver.maxParentCount = 64
Driver.connectionInput = sm.interactable.connectionType.seated + sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Driver.connectionOutput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic + sm.interactable.connectionType.bearing
Driver.colorNormal = sm.color.new( 0x76034dff )
Driver.colorHighlight = sm.color.new( 0x8f2268ff )
local clock = os.clock --global clock to benchmark various functional speeds ( for fun)

RACER_DATA = MOD_FOLDER .. "/JsonData/RacerData/"
TUNING_DATA = MOD_FOLDER .. "/JsonData/tuningData.json"

-- (Event) Called from Game
function Driver.server_loadWorldContent( self, data )
	sm.event.sendToGame( "server_onFinishedLoadContent" )
    self.loadingWorld = false
    print("Driver loaded world content")
end

function Driver.server_onCreate( self ) 
    --print("Creating gen7 Driver")
    self:server_init()
end

function Driver.client_onCreate( self ) 
    self:client_init()
end

function Driver.client_onDestroy(self)
    --print("Client destroy")
    for k, v in pairs(ALL_DRIVERS) do
		if v.id == self.id then
			table.remove(ALL_DRIVERS, k)
		end
    end
    -- possibly stop engine too
    self:hideVisuals()
end

function Driver.server_onDestroy(self)
    --print("server destroy")
    for k, v in pairs(ALL_DRIVERS) do
		if v.id == self.id then
			table.remove(ALL_DRIVERS, k)
		end
    end
    clearRunningBuffers(self)
    --self.nodeMap = nil
end

function Driver.client_onRefresh( self )
    --print("clientRefresh")
	self:client_onDestroy()
	--self.effect = sm.effect.createEffect("GasEngine - Level 3", self.interactable )
    --print("Client refresh")
    -- send to server refresh
    self:client_init()
end

function Driver.server_onRefresh( self )
    --print("server refresh")
	self:server_onDestroy()
	--self.effect = sm.effect.createEffect("GasEngine - Level 3", self.interactable )
    
    self:server_init()

    -- Export  creation data 
    --self:export_creation_data() TODO: Uncomment when ready

    -- Twitch export
    --self:export_twitch_data() --(Only EXport typea, typeb... templates with matching template colors)
    
    -- send to server refresh
end

function Driver.sv_add_metaData(self,metaData) -- Adds car specific metadata to self
    if metaData == nil then
        metaData = {   
            ['ID'] = 35,
            ['Car_Name'] = "PX Cadence",
            ['Car_Type'] = "Custom",
            ['Body_Style'] = "Custom",
            }
    end

    if self.carData['metaData'] == nil then
        print("Metadata Loading:",metaData)
    else
        print("metaData already loaded",self.carData['metaData'])
    end
   

    local carID = metaData['ID']
    local carName = metaData['Car_Name']
    local carType = metaData['Car_Type']
    local bodyStyle = metaData['Body_Style']
    -- Not sure what to do with all these, but they are there
    self.carData['metaData'] = nil -- metaData TODO: Add this back for SMARL metadata import
    self.storage:save(self.carData)
    local text = (self.carData['metaData'].Car_Name or 'Unnamed') -- This errors, need better
    self.tagText = (text or self.id)
end



-- Creation  Helpers
-- Export creation Data
function Driver.export_creation_data(self)
    local carID = nil
    if self.carData['metaData'] == nil then
        print('Car data not found')           
        return
    end
    carID = self.carData['metaData'].ID 
    if carID == nil then 
        print("Car ID not set")
        return
	end
    local savePath = RACER_DATA .. carID .. ".json"
    local creationData = sm.creation.exportToTable(self.body,false,true)
    sm.json.save(creationData, savePath)
end


function Driver.export_twitch_data(self)
    local carID = nil
    local savePath = TWITCH_BLUEPRINTS .. "typed" .. ".json"
    local creationData = sm.creation.exportToTable(self.body,false,true)
    sm.json.save(creationData, savePath)
end



function Driver.server_init( self )
    self.started = CLOCK()
    self.loaded = false
    -- conditional & error states
    self.trackLoaded = false
    self.trackLoadError = false
    self.nodeFindError = false
    self.noEngineError = false
    self.lostError = false
    self.raceControlError = false
    self.validError = false
    self.scanningError = false -- Set this to true to cause car to rescan (on lift)
    self.active = false

    self.behaviorSwitch = 1 -- 0 = original, 1 is new and 2 is others

	self.id = self.shape.id
    self.carData = {}
    self.carData = self.storage:load()  -- load car data from stored bp/storagedata possibly replace with self.data
    --print("loaded Car data",self.carData)
    -- Car Attributes
    --print("set body",self.shape.body,self.shape:getBody())
    self.body = self.shape:getBody()
    if self.body then
        self.mass = self.body.mass
    end
    self.downforceDetect = false
    self.downforce = 0 --This is stored in self.cardata['Downforce']
    self.dfTestVect = sm.vec3.new(0,0,0) -- Testing vector for downforce tes
    self.location  = self.shape.worldPosition -- location of center of body (may need to offset?)
    if self.carData == nil then -- no car data 
        self.carData = {} -- create empty table then save
        -- Load car data from json??
        -- Generate carDimensions
        print("Car Data not found")
        sm.log.info("Car data not found")
        self.carDimensions = self:generateCarDimensions()
        if self.carDimensions == nil then
            print("Error while scanning Car",self.carDimensions,"Car dimensions returned nil")
            if not self.scanningError then
                self:sv_sendAlert("Car scan failed")
            end
        else
            print("Scan Success")
            self:sv_sendAlert("Car scan successful")
            self.carData['carDimensions'] = self.carDimensions
            self.storage:save(self.carData)
            print(self.carData)
        end
        
        --self.carData = nil
     

    else -- if car data
        -- check for car/racer data, if nil, load from JSON?
        self.carDimensions = self.carData.carDimensions-- Make variable?
        if self.carDimensions == nil then
            self.carDimensions = self:generateCarDimensions()
            if self.carDimensions == nil then
                print("Error while generating car dimensions, Nil Car dimension return")
                if not self.scanningError then
                    self:sv_sendAlert("Car scan failed")
                end
            else
                print("Successfully scanned car")
                self:sv_sendAlert("Car scan successful")
            end
            self.carData['carDimensions'] = self.carDimensions
            self.storage:save(self.carData)
        else
            self.storage:save(self.carData)
        end
    end
    self.creationBodies = self.body:getCreationBodies()
    -- Collision avoidance Attributes (is rear padding necessary?)
    self.vPadding = 0.5
    self.hPadding = 0.16 -- or more

    self.frontColDist = 1
    self.rearColDist =  1
    self.leftColDist=  1
    self.rightColDist= 1 

    if self.carDimensions ~= nil then
        self.frontColDist = self.carDimensions['front']:length() + self.vPadding
        self.rearColDist = self.carDimensions['rear']:length() + self.vPadding 
        self.leftColDist= self.carDimensions['left']:length() + self.hPadding 
        self.rightColDist= self.carDimensions['right']:length() + self.hPadding 
    end
    self.distanceToNextNode = 0 -- Mainly to calculate Race Positions
     -- initialize local car radar (big values )
    if self.carRadar == nil or #self.carRadar <=0 then 
        self.carRadar = { 
            front = 100,
            rear = -100,
            right = 100,
            left = -100
        }
    end
    self.leftDetect = false
    self.rightDetect = false
    self.oppDict = {}
    self.carAlongSide = {left = 0, right = 0} -- triggers -1,1 if there is a car directly alongside somewhat closely
    self.opponentFlags = {} -- list of opponents and flags
    
    self.cameraPoints = 0 -- points for auto focusing camera
    
    --self.engine = nil -- gets loaded from engine

    -- Car Control attributes
    self.steering = 0 -- actual steering value
    self.throttle = 0 -- actual throttle value
    self.curGear = 0 
    
    self.colSteerAdjust = 0 
    self.colThrottleAdjust = 0 -- class adjustment for updateStrategic Throttle, passes through and gets set in collisison layer

    self.strategicSteering = 0
    self.strategicThrottle = 0

    -- Driving and character layer states
    self.seatConnected = false -- whether seat is conrol
    self.userControl = false -- If a driver seat is connected, user has control over strategic steering+throttle
    self.userPower = 0
    self.userSteer = 0
    self.userSeated = false -- self explanitory hopefully

    self.racing = false 
    
    self.caution = false
    self.cautionPos = 1 -- Position for caution
    self.formation = false
    self.formationPos = 1 -- position for formation
    self.formationAligned = false -- whether car is in proper formation or not
    self.safeMargin = false
    self.raceRestart = false

    self.upShiftThreshold = 0.1 -- Save per car? load from json?
    self.downShiftThreshold = 0.1

    -- Movement attributes
    self.velocity = sm.shape.getVelocity(self.shape)
    self.angularVelocity = self.body.angularVelocity
    self.speed =sm.vec3.length(self.velocity)
    self.angularSpeed = sm.vec3.length(self.angularVelocity)
    self.brakingDistance = 0 -- How long it takes for car to slow down

    --Movement States
    self.oversteer = false
    self.understeer = false
    self.rotationCorrect = false -- overrotation correction
    self.offTrack = 0 -- distance offtrack car is
    self.stuck = false

    self.stuckGraceCooldownTimer = 160 -- 200 ticks for stuck cooldowntimer
    --self.stuckGraceCooldownTimer:start(100)
    self.lost = false -- Only if super far offtrack to the point it cant find nearest node
    self.tilted = false
    self.rejoining = false
    self.goalOffsetCorrecting = false
    self.drafting = false
    self.passing = {isPassing=false, carID = nil} -- if car is passing other car
    self.passDistance = 20
    self.passCommit = 0 -- which direction is pass committing to
    self.speedControl = 0 -- approx speed to try to stay at
    self.verticalMovement = 0 -- rate Car is moving up/down -- could just take form self.velocity
    self.offline = false -- if the car is too far off the racing line
    self.nudging = false -- whether the car is flying to correct itself

    -- Race Meta
    self.racePosition =0
    self.distTraveled = 0
    self.totalNodes = 0
    self.currentLap = 0
    self.newLap = false -- ensure there is no double trigger
    self.handicap = 0 -- set by raceControl, how many nodes away from leader fraction

    -- Stats tracking/telemetry ---
    self.lapStarted = CLOCK() -- Time the current lap was started, for timeing
    self.leaderSplit = 0 -- Time between leader and checkpoints?
    self.raceSplit = 0
    self.lastLap = 0
    self.bestLap = 0
    self.lapAverage = 0
    self.topLapSpeed = 0 -- Top speed per lap
    self.avgLapSpeed = 0 -- average speed per lap
    self.lapSpeedAverageBuffer = nil
    self.sectorTimes = {0,0,0}
    self.currentSector = 1
    self.sectorStartTime = CLOCK()


    -- Sesssion Tracking

    self.isFocused = false
    self.raceFinished = false 
    self.finishTime = 0
    self.stuckCooldown = {true,self.location} -- if true, check current node, if curNode is nil, check self current

    -- Situational/goalstate
    self.pathGoal = "location"
    -- Track Data (copied?)
    self.nodeChain = nil
    self.totalSegments = nil
    self.ovalTrack = false

    self.goalNode = nil
    self.goalOffset = nil
    self.passGoalOffsetStrength = 0
    self.draftGoalOffsetStrength = 0
    self.biasGoalOffsetStrength = 0
    self.collGoalOffsetStrength = 0 -- anti collision adjustments

    self.goalDirection = nil
    self.goalDirectionOffset = nil
    self.followStrength = 1 -- range between 1 and 10?

    -- steering state priorities (0-1)
    self.nodeFollowPriority = 0
    self.draftFollowPriority = 0
    self.biasFollowPriority = 0
    self.passFollowPriority = 0
    self.collFollowPriority = 0

    self.trackPosBias = nil -- Angled to try and get the car to get to a certain track position
    self.draftPosBias = 0 -- also tp get car in a trackPos
    self.currentNode = nil
    self.currentSegment = nil

    self.futureLook =  {segID = 0, direction = 0, length = 0, distance = 0} 
    -- Tolerances and Thresholds
    self.overSteerTolerance = -1.9 -- The smaller (more negeative, the number, the bigger the tollerance) (custom? set by situation) (DEFAUL -1.5)
    self.underSteerTolerance = -0.4 -- Smaller (more negative [fractional]) the more tolerance to understeer-- USED TO BE:THe bigger (positive) more tolerance to understeer (will not slow down as early, DEFAULT -0.3)
    self.passAggression = -1 -- DEFAULT = -0.1 smaller (more negative[fractional]) the less aggresive car will try to fit in small spaces, Limit [-2, 0?]
    self.skillLevel = 5 -- Skill level = ammount breaking for turns (1 = slow, 10 = no braking pretty much)
    
    -- testing states
    self.maxSpeed = nil
    self.maxFriction = nil
    self.maxLatAcc = nil
    self.maxAngVel = nil
    self.maxFrontDif = nil
    self.sliding = false
    self.testFinished = false
    self.testStarted = 0
    self.liftPlaced = false
    self.onLift = false -- not sure where to start this
    self.resetNode = nil
    self.carResetsEnabled = true -- whether to teleport car or not
    self.debug = true

    -- TUNING States
    self.allowTuning = false -- remember to turn off in production TODO: move to race control?
    self.Tire_Type = 2 -- Medium (1 = soft, 2 = medium, 3 = hard)
    self.Tire_Health = 100
    self.Gear_Length = 5 -- = huge accel low ts, 10 = low accel, high ts
    self.Fuel_Level = 100 -- only gets set for initial state
    self.Spoiler_Angle = 5 -- 0 = no angle, 10 = full angle
    
    -- Pit Data and states
    self.pitChain = {} -- Not just the chain but general data like pit boxes

    self.assignedBox = nil -- pit box assigned to T

    self.pitIn = false
    self.pitOut = false
    self.inPitLane = false
    self.pitStopping = false -- Whether car iis/should be stopped for service
    self.pitState = 0 -- 0 = Race normal, 1: search for entry 2: on entry: 3 pit In: 4: pit stopped, 5: pit Out: 6: pit exit: -- 0 = race
    -- contain full strategy array??
    self.pit_strategy = {
        ['Tire_Change'] = 2, -- [0=None]
        ['Fuel_Fill'] = 0
    }
    self.pitTimer = Timer()
    self.pitTimer:start(0) -- TODO: fix timer class to handle not needing this on init
    --  degredation stat helpers
    self.lastTireHealth = 100
    self.lastFuelLevel = 100

    -- Realism Failure states:
    self.tireLimp = false
    self.fuelLimp = false

    -- errorTimeouts
    self.RCE_timeout = 0
    self.nodeFindTimeout = 0
    self.stuckTimeout = 0
    self.resetPosTimeout = 0

    -- Race results state
    self.displayResults = true -- Whether to actually send the chat messge
    self.resultsDisplayed = false -- Check if message already displayed

    -- Effects 
    self.goalNodeEffect = nil
    self.currentNodeEffect = nil -- Populated on client
    self.effectsList = {self.goalNodeEffect,self.currentNodeEffect}
    --print(self.shape.at)
    self.creationId = self.body:getCreationId()
    self.player = nil -- host player
    self.meta_id = 0 -- default 0
    self.twitchCar = false -- Whether car is from twitchplays plugin or not

    if self.carData['metaData'] and self.twitchCar == false then
        print("Loading Driver",self.id,self.tagText,self.carData['metaData'])
        if self.carData['metaData'].ID then
            self.meta_id = self.carData['metaData'].ID
        end
    end



    
     -- Insert into global allDrivers so everyone has access Possibly have a public/private section?
    
    -- PHYSICS EXPERIMENTs::
    self.experiment = false

    self:sv_load_tuning_data()
    self:sv_load_twitchData() -- Auto check if twitch Connection needed
    if self.twitchCar then -- Load in Attributes: (Further load in stuff if needed)

    end
end

function Driver.client_init(self)
    --print("Diver Client Init")
    -- Debug effects
    local colors = {
        front = sm.color.new("0721FFFF"), -- blue
        rear = sm.color.new("FF0707FF"), -- red
        right = sm.color.new("00FF1BFF"), -- Green
        left = sm.color.new("DCFF00FF"), -- yellow
        goal = sm.color.new("FF9106FF"), -- Orange 
        cur = sm.color.new("B706FFFF"), -- purple
        center = sm.color.new("06FFFBFF") -- #06FFFB cyan
    }

    -- item visualization
    --local effect = sm.effect.createEffect("ShapeRenderable")
    --effect:setParameter("uuid", uuid)
    --effect:setParameter("visualization", true)
    --effect:setScale(size)
    --effect:setPosition(pos)
    --effect:start()
    if sm.isHost then
        self.player = sm.localPlayer.getPlayer()
        --print("host player",self.player)
    end
    self.frontEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.frontEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.frontEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.frontEffect.effect:setParameter( "Color", colors.front )

    self.leftEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.leftEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.leftEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.leftEffect.effect:setParameter( "Color", colors.left )
    
    self.rightEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.rightEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.rightEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.rightEffect.effect:setParameter( "Color", colors.right )
    
    self.rearEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.rearEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.rearEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.rearEffect.effect:setParameter( "Color", colors.rear )
    
    self.goalNodeEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.goalNodeEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.goalNodeEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.goalNodeEffect.effect:setParameter( "Color", colors.goal )
    
    self.currentNodeEffect = {pos = nil, effect = sm.effect.createEffect("Loot - GlowItem")} 
    self.currentNodeEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.currentNodeEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.currentNodeEffect.effect:setParameter( "Color", colors.cur )
    
    self.calcCenterEffect = {pos = nil, effect = sm.effect.createEffect("Loot - GlowItem")} 
    self.calcCenterEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.calcCenterEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.calcCenterEffect.effect:setParameter( "Color", colors.center )

    
    self.fflEffect = {pos = self.location, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.fflEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.fflEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.fflEffect.effect:setParameter( "Color", colors.front )

    self.ffrEffect = {pos =  self.location, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.ffrEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.ffrEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.ffrEffect.effect:setParameter( "Color", colors.left )
    
    self.fblEffect = {pos =  self.location, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.fblEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.fblEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.fblEffect.effect:setParameter( "Color", colors.right )
    
    self.fbrEffect = {pos =  self.location, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.fbrEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.fbrEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.fbrEffect.effect:setParameter( "Color", colors.rear )

    
    self.effectsList = {self.goalNodeEffect,self.currentNodeEffect,self.frontEffect,self.leftEffect,
                        self.rightEffect,self.rearEffect,self.calcCenterEffect,
                        self.fflEffect, self.ffrEffect, self.fblEffect, self.fbrEffect
                    }
                    --print(self.effectsList)
    self.idTag = sm.gui.createNameTagGui()
    self.idTag:setHost(self.shape)
	self.idTag:setRequireLineOfSight( false )
	self.idTag:setMaxRenderDistance( 500 )

    self.onHover = false

    self.runEffects = false

    if self.carData['metaData'] ~= nil then
        local text = (self.carData['metaData'].Car_Name or '')
        self.tagText = (text or self.id)
    else
        self.tagText = self.id
    end
	self.idTag:setText( "Text", "#ff0000"..self.tagText)

    if self.carData['metaData'] then
        if self.carData['metaData'].ID then
            self.meta_id = self.carData['metaData'].ID
        end
    end

    self.userSeated = false
    if self.debug then
        self:showVisuals()
    end
    if not self.trackLoaded then
        --print("client load trackData")
        self:loadTrackData() -- Track data could contain racing lines and everything else (Should be server side, not client side)
    end
    self:cl_addRacer()
    if self.player ~= nil then 
        self.network:sendToServer("sv_addPlayer",self.player)
    else
        print("not host or player not found")
    end
    --print(#ALL_DRIVERS) -- dont give whole engine
end


-- Soft reset, resets most values except those important for the middle of a race
function Driver.sv_softReset(self)
    self.active = false
    self.nodeFindError = false
    self.noEngineError = false
    self.lostError = false
    self.raceControlError = false
    self.validError = false
    self.scanningError = false
    self.body = self.shape:getBody()
    if self.body then
        self.mass = self.body.mass
    end
    self.location  = self.shape.worldPosition -- location of center of body (may need to offset?)
    if self.carData == nil then -- no car data 
        print("Soft reset could not find car data")
    else -- if car data
    end
    self.creationBodies = self.body:getCreationBodies()
    -- Collision avoidance Attributes (is rear padding necessary?)
    
    -- Car Control attributes
    self.steering = 0
    self.throttle = 0
    self.curGear = 0 -- Move forward on soft resets? 

    self.colThrottleAdjust = 0
    self.strategicSteering = 0
    self.strategicThrottle = 0

    -- Movement attributes
    self.velocity = sm.shape.getVelocity(self.shape)
    self.angularVelocity = self.body.angularVelocity
    self.speed =sm.vec3.length(self.velocity)
    self.angularSpeed = sm.vec3.length(self.angularVelocity)
    self.brakingDistance = 0 -- How long it takes for car to slow down

    --Movement States
    self.oversteer = false
    self.understeer = false
    self.rotationCorrect = false -- overrotation correction
    self.offTrack = 0 -- distance offtrack car is
    self.stuck = false
    self.stuckGraceCooldownTimer = 160
    self.lost = false -- Only if super far offtrack to the point it cant find nearest node
    self.tilted = false
    self.rejoining = false
    self.goalOffsetCorrecting = false
    self.drafting = false
    self.passing = {isPassing=false, carID = nil} -- if car is passing other car
    self.passCommit = 0 -- which direction is pass committing to
    self.speedControl = 0 -- approx speed to try to stay at
    self.verticalMovement = 0 -- rate Car is moving up/down -- could just take form self.velocity
    self.offline = false -- if the car is too far off the racing line
    self.nudging = false -- whether the car is flying to correct itself
    -- Situational/goalstate
    self.pathGoal = "location"
    -- Track Data (copied?)
   
    self.cautionPos = 1 -- Position for caution
    
    self.formationPos = 1 -- position for formation



    self.futureLook =  {segID = 0, direction = 0, length = 0, distance = 0} 
    -- Tolerances and Thresholds
    self.isFocused = false

    -- errorTimeouts
    self.RCE_timeout = 0
    self.nodeFindTimeout = 0
    self.stuckTimeout = 0
    self.resetPosTimeout = 0
    
    --clearRunningBuffers(self)
    -- Effects 
   --print(self.tagText,"sv_soft reset")
end

function Driver.sv_hard_reset(self) -- resets everything including lap but not collision data
    self.loaded = false
    self.active = false
    -- conditional & error states
    self.trackLoaded = false
    self.trackLoadError = false
    self.nodeFindError = false
    self.noEngineError = false
    self.lostError = false
    self.raceControlError = false
    self.validError = false
    self.scanningError = false
    self.isFocused = false

     -- TUNING States
     self.Tire_Type = 2 -- Medium (1 = soft, 2 = medium, 3 = hard)
     self.Tire_Health = 100
     self.Gear_Length = 5 -- = huge accel low ts, 10 = low accel, high ts
     self.Fuel_Level = 100 -- only gets set for initial state
     self.Spoiler_Angle = 5 -- 0 = no angle, 10 = full angle
     
     -- Pit states
     self.pitIn = false
     self.pitOut = false
     self.inPitLane = false
     self.pitStopping = false
     self.pitState = 0 -- ??
     -- contain full strategy array??
     self.pit_strategy = {
        ['Tire_Change'] = 2, -- [0=None]
        ['Fuel_Fill'] = 0
    }
     self.assignedBox = nil
	--self.id = self.shape.id
    -- Car Attributes
    --print("set body",self.shape.body,self.shape:getBody())
    self.body = self.shape:getBody()
    self.creationBodies = self.body:getCreationBodies()
    if self.body then
        self.mass = self.body.mass
    end
    self.location  = self.shape.worldPosition -- location of center of body (may need to offset?)

    self.carData = self.storage:load()  -- load car data from stored bp/storagedata possibly replace with self.data
    --print("loaded Car data",self.carData)
    if self.carData == nil then
        print("ERROR: Car data not found (please re-scan/save the car)")
    else -- if car data
        -- check for car/racer data, if nil, load from JSON?
        self.carDimensions = self.carData.carDimensions-- Make variable?
        if self.carDimensions == nil then
            print("Hard Reset could not find car dimensions")
        else
            --print("Loaded car dimensions",self.carDimensions)
        end
    end
    
    -- Collision avoidance Attributes (is rear padding necessary?)
    self.vPadding = 0.5
    self.hPadding = 0.16 -- or more

    self.frontColDist = 1
    self.rearColDist =  1
    self.leftColDist=  1
    self.rightColDist= 1 
    self.leftDetect = false
    self.rightDetect = false

    if self.carDimensions ~= nil then
        self.frontColDist = self.carDimensions['front']:length() + self.vPadding
        self.rearColDist = self.carDimensions['rear']:length() + self.vPadding 
        self.leftColDist= self.carDimensions['left']:length() + self.hPadding 
        self.rightColDist= self.carDimensions['right']:length() + self.hPadding 
    end

 -- initialize local car radar (big values )
    if self.carRadar == nil or #self.carRadar <=0 then 
        self.carRadar = { 
            front = 100,
            rear = -100,
            right = 100,
            left = -100
        }
    end 
    self.oppDict = {}
    self.carAlongSide = {left = 0, right = 0} -- triggers -1,1 if there is a car directly alongside somewhat closely
    self.opponentFlags = {} -- list of opponents and flags
    --self.engine = nil -- gets loaded from engine

    -- Car Control attributes
    self.steering = 0
    self.throttle = 0
    self.curGear = 0 

    self.colThrottleAdjust = 0
    self.strategicSteering = 0
    self.strategicThrottle = 0

    -- Driving and character layer states
    self.seatConnected = false -- whether seat is conrol
    self.userControl = false -- If a driver seat is connected (and ai switch is off), user has control over strategic steering+throttle
    self.racing = false 
    self.pitting = false
    self.caution = false
    self.cautionPos = 1 -- Position for caution
    self.formation = false
    self.formationPos = 1 -- position for formation
    self.safeMargin = false
 
    -- Movement attributes
    self.velocity = sm.shape.getVelocity(self.shape)
    self.angularVelocity = self.body.angularVelocity
    self.speed =sm.vec3.length(self.velocity)
    self.angularSpeed = sm.vec3.length(self.angularVelocity)
    self.brakingDistance = 0 -- How long it takes for car to slow down

    --Movement States
    self.oversteer = false
    self.understeer = false
    self.rotationCorrect = false -- overrotation correction
    self.offTrack = 0 -- distance offtrack car is
    self.stuck = false
    self.lost = false -- Only if super far offtrack to the point it cant find nearest node
    self.tilted = false
    self.rejoining = false
    self.goalOffsetCorrecting = false
    self.drafting = false
    self.passing = {isPassing=false, carID = nil} -- if car is passing other car
    self.passCommit = 0 -- which direction is pass committing to
    self.speedControl = 0 -- approx speed to try to stay at
    self.verticalMovement = 0 -- rate Car is moving up/down -- could just take form self.velocity
    self.offline = false -- if the car is too far off the racing line

    -- Race Meta Will get reset on hard reset
    self.racePosition =0
    self.distTraveled = 0
    self.totalNodes = 0
    self.currentLap = 0
    self.newLap = false -- ensure there is no double trigger
    self.handicap = 0 -- set by raceControl, how many nodes away from leader fraction
    self.lapStarted = CLOCK() -- Time the current lap was started, for timeing
    self.leaderSplit = 0 -- Time between leader and checkpoints?
    self.raceSplit = 0
    self.lastLap = 0
    self.bestLap = 0
    self.lapAverage = 0
    self.raceFinished = false 
    
    -- Situational/goalstate
    self.pathGoal = "location"
    -- Track Data (copied?)
    self.nodeChain = nil
    self.totalSegments = nil
    self.ovalTrack = false

    
    self.goalNode = nil
    self.goalOffset = nil
    self.goalDirection = nil
    self.goalDirectionOffset = nil
    self.followStrength = 1 -- range between 1 and 10?
    self.draftPosBias = 0
    self.trackPosBias = nil -- Angled to try and get the car to get to a certain track position

    -- steering state priorities (0-1)
    self.nodeFollowPriority = 0
    self.draftFollowPriority = 0
    self.biasFollowPriority = 0
    self.passFollowPriority = 0
    
    self.currentNode = nil
    self.currentSegment = nil

    self.futureLook =  {segID = 0, direction = 0, length = 0, distance = 0} 
    
  -- errorTimeouts
    self.RCE_timeout = 0
    self.nodeFindTimeout = 0
    self.stuckTimeout = 0

    -- Race results state
    self.displayResults = false -- Whether to actually send the chat messge
    self.resultsDisplayed = false -- Check if message already displayed
	print("SMAR Driver Hard Reset",self.id)

    if self.carData['metaData'] then
        if self.carData['metaData'].ID then
            self.meta_id = self.carData['metaData'].ID
        end
    end
    clearRunningBuffers(self)
    self:sv_load_tuning_data()
end

function Driver.cl_hard_reset(self) -- resets client side objects
    --print("Diver Client Init")
    -- Debug effects
    local colors = {
        front = sm.color.new("0721FFFF"), -- blue
        rear = sm.color.new("FF0707FF"), -- red
        right = sm.color.new("00FF1BFF"), -- Green
        left = sm.color.new("DCFF00FF"), -- yellow
        goal = sm.color.new("FF9106FF"), -- Orange 
        cur = sm.color.new("B706FFFF"), -- purple
        center = sm.color.new("06FFFBFF") -- #06FFFB cyan
    }

    -- item visualization
    --local effect = sm.effect.createEffect("ShapeRenderable")
    --effect:setParameter("uuid", uuid)
    --effect:setParameter("visualization", true)
    --effect:setScale(size)
    --effect:setPosition(pos)
    --effect:start()

    self.frontEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.frontEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.frontEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.frontEffect.effect:setParameter( "Color", colors.front )

    self.leftEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.leftEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.leftEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.leftEffect.effect:setParameter( "Color", colors.left )
    
    self.rightEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.rightEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.rightEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.rightEffect.effect:setParameter( "Color", colors.right )
    
    self.rearEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.rearEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.rearEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.rearEffect.effect:setParameter( "Color", colors.rear )
    
    self.goalNodeEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.goalNodeEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.goalNodeEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.goalNodeEffect.effect:setParameter( "Color", colors.goal )
    
    self.currentNodeEffect = {pos = nil, effect = sm.effect.createEffect("Loot - GlowItem")} 
    self.currentNodeEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.currentNodeEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.currentNodeEffect.effect:setParameter( "Color", colors.cur )
    
    self.calcCenterEffect = {pos = nil, effect = sm.effect.createEffect("Loot - GlowItem")} 
    self.calcCenterEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.calcCenterEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.calcCenterEffect.effect:setParameter( "Color", colors.center )
    

    self.fflEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.fflEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.fflEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.fflEffect.effect:setParameter( "Color", colors.front )

    self.ffrEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.ffrEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.ffrEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.ffrEffect.effect:setParameter( "Color", colors.left )
    
    self.fblEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.fblEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.fblEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.fblEffect.effect:setParameter( "Color", colors.right )
    
    self.fbrEffect = {pos = nil, effect =sm.effect.createEffect("Loot - GlowItem")}
    self.fbrEffect.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.fbrEffect.effect:setScale(sm.vec3.new(0,0,0))
    self.fbrEffect.effect:setParameter( "Color", colors.rear )
    -- center?



    self.effectsList = {self.goalNodeEffect,self.currentNodeEffect,self.frontEffect,self.leftEffect,
                        self.rightEffect,self.rearEffect,self.calcCenterEffect,
                        self.fflEffect, self.ffrEffect, self.fblEffect, self.fbrEffect
                    }

    self.idTag = sm.gui.createNameTagGui()
    self.idTag:setHost(self.shape)
	self.idTag:setRequireLineOfSight( false )
	self.idTag:setMaxRenderDistance( 500 )
    if self.carData['metaData'] ~= nil then
        local text = (self.carData['metaData'].Car_Name or '')
        self.tagText = (text or self.id)
    else
        self.tagText = self.id
    end
	self.idTag:setText( "Text", "#ff0000"..self.tagText)


    if self.debug then
        self:showVisuals()
    end
    if not self.trackLoaded then
        print("client load trackData")
        self:loadTrackData() -- Track data could contain racing lines and everything else (Should be server side, not client side)
    end
    self:cl_addRacer()
    --print(#ALL_DRIVERS) -- dont give whole engine
end

-- Initializing
function Driver.generateEffect(self,location,color) -- Creates new effect at param location
    
    local effect = sm.effect.createEffect("Loot - GlowItem")
    effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    effect:setScale(sm.vec3.new(0,0,0))
    local color = (color or sm.color.new("AFAFAFFF"))
    
   -- local testUUID = sm.uuid.new("42c8e4fc-0c38-4aa8-80ea-1835dd982d7c")
    --effect:setParameter( "uuid", testUUID) -- Eventually trade out to calculate from force
    --effect:setParameter( "Color", color )
    if location == nil then
        effect:setPosition(sm.vec3.new(0,0,0)) -- remove too
        effect:setParameter( "Color", sm.color.new("ff3333FF") )
        return effect
    end
    effect:setPosition(location) -- remove too
    effect:setParameter( "Color", color )
    return effect
end

function Driver.cl_addRacer(self) -- declares itself to race control (grabs race status from RC) (Only working with client side ALL_DRIVERS?)
    --print("cl_adding racer?",self.id,self.tagText,self.sv_twitchData,#ALL_DRIVERS,getFieldValuesFromList(ALL_DRIVERS,'id'))
    table.insert(ALL_DRIVERS,self)
    self:sv_sendCommand({car = {self.id}, type = "add_racer", value = 1})
end


function Driver.sv_addRacer(self) -- declares itself to race control (grabs race status from RC) (Only working with client side ALL_DRIVERS?)
    --print("sv_adding racer",self.id,self.tagText,self.sv_twitchData,#ALL_DRIVERS)
    table.insert(ALL_DRIVERS,self)
    self:sv_sendCommand({car = {self.id}, type = "add_racer", value = 1})
end

function Driver.sv_addPlayer(self,player) -- sends player to server
    self.player = player
    --print("added player sv",self.player)
end

function Driver.loadTrackData(self) -- loads in any track data from the world
    --print('loadTrackData network send')
    self.network:sendToServer("sv_loadTrackData") -- Will be good
    self.network:sendToServer("sv_loadPitData")
end

function Driver.sv_loadTrackData(self)
    --print("svb_loadData")
    local data = sm.storage.load(TRACK_DATA)
    if data == nil then
        --print("Server did not find track data") 
        if self.trackLoadError then
        else
            print("Track Data not found")
            self.trackLoadError = true
        end
    else
        --print("Server found track data") 
        if self.trackLoadError then
            print("Track Loaded")
            self.trackLoadError = false
        else
            --print("Track Loaded, initial")
        end
    end
    self:on_trackLoaded(data) -- callback to confirm load
end


function Driver.sv_loadPitData(self)
    --print("svb_loadData")
    local data = sm.storage.load(PIT_DATA)
    if data == nil then
        --print("Server did not find track data") 
        if self.pitLoadError then
        else
            --print("Pit Data not found")
            self.pitLoadError = true
        end
    else
        --print("Server found track data") 
        if self.pitLoadError then
            --print("Pit Loaded")
            self.pitLoadError = false
        else
            --print("Track Loaded, initial")
        end
    end
    self:on_pitLoaded(data) -- callback to confirm load
end

function Driver.on_trackLoaded(self,data) -- Callback for when track data is actually loaded
    --print('on_trackLoaded')
    if data == nil then
        self.trackLoaded = false
    else
        self.trackLoaded = true
        --{["raceChain"] = self.simpNodeChain, ["pitChain"] = self.pitChain} 
        if data['raceChain'] ~= nil then
            self.nodeChain = data['raceChain']
        else
            self.nodeChain = data -- fall back for previous versions
        end
        
        if data['pitChain'] ~= nil then
            self.pitChain = data['pitChain']
        end
         
        --print(self.nodeChain[1])
        if self.nodeMap == nil then
            --print("generating NodeMap")
            self.nodeMap = generateNodeMap(self.nodeChain)
            
        end
        local lastNode = getNextItem(self.nodeChain,1,-1)
        self.totalSegments = lastNode.segID
        if self.totalSegments <= 5 then
            print("Oval Track??",self.totalSegments)
            self.ovalTrack = true
        end
        --print("total segments",self.totalSegments)
    end
end


function Driver.on_pitLoaded(self,data) -- Callback for when pit data is loaded
    --print('on pit load')
    if data == nil then
        self.pitLoaded = false
    else
        self.pitLoaded = true
        
        if data['pitChain'] ~= nil then
            self.pitChain = data['pitChain']
        end
    end
end

function Driver.sv_adjustColors(self,colors)
    local primaryTemplateColor = sm.color.new("#eeaf5cff")
    local secondaryTemplateColor = sm.color.new("#375000ff")
    local tertiaryTemplateColor = sm.color.new("#222222ff")
    local engineBlock_uuid = "42dd8836-3cbb-495c-86b4-44fb9c9916b3" -- Do not paint this

    local exempted_shapes = {engineBlock_uuid} -- and more?

    local splitColors = splitString(colors,",")
    local newPrimary = sm.color.new(splitColors[1])
    local newSecondary = sm.color.new(splitColors[2])
    local newTertiary = sm.color.new(splitColors[3])

    -- First we iterate over every shape in in creation
    -- If the shape is painted primary templateColor or secondary or tertiary and not engine block, we change
    -- Tertiary includes wheels rn (may change)

    local all_shapes = self.body:getCreationShapes()
    for j=1, #all_shapes do local shape = all_shapes[j]
        if findValue(exempted_shapes,tostring(shape:getShapeUuid())) then
        else
            local color = shape:getColor()
            if color == primaryTemplateColor then
                shape:setColor(newPrimary)
            elseif color == secondaryTemplateColor then
                shape:setColor(newSecondary)
            elseif color == tertiaryTemplateColor then
                shape:setColor(newTertiary)
            end
        end
    end

end

function Driver.sv_load_twitchData(self)
    local twitchData = getKeyValue(TWITCH_CONNECTIONS,'id',self.id)
    --print("Driver Got twitch data",twitchData)
    if twitchData then
        print("Loading Twitch Driver",twitchData)
        self.sv_twitchData = twitchData
        self.twitchCar = true
        self:sv_adjustColors(twitchData['colors'])
        self.network:sendToClients("cl_load_twitch_data",twitchData)
    else
        --print("no twitch connections")
    end
end

function Driver.cl_load_twitch_data(self,data)
    --print("cl loading twitchdata",data)
    self.cl_twichData = data
    self.twitchCar = true
    -- TODO: Update Name tagtext
    self.tagText = data['name']
end

function Driver.sv_load_tuning_data(self)
    if self.carData == nil or self.carData['metaData'] == nil or self.carData['metaData'].ID == nil or self.twitchCar == true then
        return
    end

    if getRaceControl() and getRaceControl().tuningEnabled == false then -- DisableTuning
        return 
    end

    local status, data =  pcall(sm.json.open,TUNING_DATA) -- Could pcall whole function
    if status == false then -- Error doing json open
        print("Got error Opening Tuning data",data)
        return nil
    else
        local carID = self.carData['metaData'].ID 
        local car_data = getKeyValue(data,'racer_id',carID)
        if car_data == nil or car_data == false then 
            print(self.tagText,carID,"no tuning data found")
            return
        end
        self.Tire_Type = tonumber(car_data.tire_type)
        self.Fuel_Level = tonumber(car_data.fuel_level)
        self.Gear_Length = tonumber(car_data.gear_length)
        self.Spoiler_Angle = tonumber(car_data.aero_angle)
        --print(self.tagText,"Got tune",car_data)
        if self.engine then
            --local defaultEngineStats = getEngineType(self.engine.engineColor)

            self.engine.engineStats = self.engine:generateNewEngine(getEngineType(self.engine.engineColor)) -- Kinda hacky but works
            -- Resets the engine to default type before re tuning to adjustments
            --print('setting engine Tune',self.engine.engineStats,ENGINE_TYPES[1])
            -- Spoiler angle Adjustments
            if self.Spoiler_Angle < 5 then -- increase top speed
                self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED + ((5 - self.Spoiler_Angle) * 1.4)
            elseif self.Spoiler_Angle > 5 then -- decrease top speed
                self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED - ((self.Spoiler_Angle - 5) * 1.7)
            else
                --self.engine.engineStats.MAX_SPEED = defaultEngineStats.MAX_SPEED
            end

            -- Tire Type Adjustments
            if self.Tire_Type == 1 then -- Increase accel and slightly increase TS
            elseif self.Tire_Type == 2 then -- set default
            elseif self.Tire_Type == 3 then -- decrease accel and decrease TS
            end

            -- Gear Length Adjustments
            if self.Gear_Length < 5 then -- Increase Accel and decrease TS -- Further decrease the more k increases?
                for k=1, #self.engine.engineStats.GEARING do
                    self.engine.engineStats.GEARING[k] = mathClamp(0.05,2,self.engine.engineStats.GEARING[k] + ((5/self.Gear_Length)/(10*k)))
                end
                self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED - ((5 - self.Gear_Length) * 0.5)
            elseif self.Gear_Length > 5 then -- decrease Accel, Increase TS
                for k=1, #self.engine.engineStats.GEARING do
                    self.engine.engineStats.GEARING[k] = mathClamp(0.05,2,self.engine.engineStats.GEARING[k] /(self.Gear_Length*0.16))
                end
                self.engine.engineStats.MAX_SPEED = self.engine.engineStats.MAX_SPEED + ((self.Gear_Length - 5) * 1.5)
            else
                --self.engine.engineStats.MAX_SPEED = defaultEngineStats.MAX_SPEED
                --self.engine.engineStats.GEARING = defaultEngineStats.GEARING
            end
            self.engine.engineStats.REV_LIMIT = self.engine.engineStats.MAX_SPEED/#self.engine.engineStats.GEARING
            --print('Set Driver Tune',self.engine.engineStats)
        end
       

    end

end


function Driver.on_engineLoaded(self,data) -- callback when engine is connected to driver
    if data == nil then print("ENgine Loaded nil",data) return end
    self.engine = data
    self.noEngineError = false
    self:sv_load_tuning_data()
end

function Driver.on_engineDestroyed(self,data)
    self.engine = nil
    self.noEngineError = true
    --print("engineDestroyed")
end

function Driver.generateCarDimensions(self) -- gets dimensions  of car (( only scan when placed on lift)) 
    if self.body:isDynamic() then -- Body is not on lift 
        self.scanningError = true
        print("Car must be on lift to be scanned propperly")
        self:sv_sendAlert("Car must be on lift to be scanned properly") -- send to
        self.scanningError = true
        return nil 
    end
    local frontOffset =  sm.vec3.new(0,0,0) -- Keeping vectors to have simplicity later on
    local rearOffset = sm.vec3.new(0,0,0)
    local leftOffset = sm.vec3.new(0,0,0)
    local rightOffset = sm.vec3.new(0,0,0) -- posibly change to {direction, length}
    local centerOffset = {rotation = sm.vec3.new(0,0,0), length = 1} -- multiply rot by at, add (len * rot) to worldPos

    local frontDir = self.shape.at
    local curLocation = self.shape.worldPosition
    local bodyShapes = self.body:getCreationShapes()

    -- GEt all directional offsets
    --print("front")
    frontOffset = getDirectionOffset(bodyShapes,frontDir,curLocation)
    --print("rear") 
    rearOffset = getDirectionOffset(bodyShapes,frontDir*-1,curLocation) 
    --print("right")
    rightOffset = getDirectionOffset(bodyShapes,self.shape.right*1,curLocation) 
    --print("left")
    leftOffset = getDirectionOffset(bodyShapes,self.shape.right*-1,curLocation)
    if not frontOffset or not rearOffset or not leftOffset or not rightOffset then
        print("Error Scanning Car",frontOffset,rearOffset,leftOffset,rightOffset)
        return nil 
    end
   
    local frontLeft = curLocation + frontOffset + leftOffset
    local rearRight = curLocation + rightOffset + rearOffset
    local center = getMidpoint(frontLeft,rearRight)
    local centerOffset = (center - curLocation)-- translate relative to self.shape.at and self.shape.right
    --print(centerOffset:length())
    local centerAt = centerOffset - self.shape.at
    local centerRight = centerOffset - self.shape.right
    --print(leftOffset.y,rightOffset.y,centerOffset)
    local v1 = self.shape:getAt()

    local v2,centerRotationVec,centerLen
    if centerOffset:length() == 0 then -- vector is 0
        v2 = sm.vec3.new(0,0,0)
        centerRotationVec = sm.vec3.new(0,0,0)
        centerLen = 0
    else
         v2 = centerOffset:normalize()
        centerRotationVec = sm.vec3.getRotation(v1, v2) -- Store this
        centerLen = centerOffset:length() -- Store this too
    end
    centerOffset = {rotation = centerRotationVec, length = centerLen}

    
    local newRot =  centerRotationVec * self.shape:getAt()
    local newCenter = self.shape.worldPosition + (newRot * centerLen)
    --print("worldCheck",centerOffset,newRot,centerRotationVec)
    --print(leftOffset.y,rightOffset.y)
    local carDimensions =  {
            front = frontOffset,
            rear = rearOffset,
            left = leftOffset,
            right = rightOffset,
            center = centerOffset
            }
    --print("Dimension offsets",carDimensions, "shape location",curLocation)
            
    return carDimensions
end

function Driver.cl_hard_reset_Racer(self) -- resets racer from client
    self.network:sendToServer("sv_hard_reset_Racer")
    print("resetting racer")
end

function Driver.sv_hard_reset_Racer(self) -- resets racers (used after races mostly)
    self:hard_reset() 
    self.network:sendToClients("cl_hard_reset")
end

-- helper for single car output
function Driver.debugOutput(self,id,data)
    if data == nil then return end
    if id == -1 or self.carData and self.carData.metaData then
        if id == -1 or self.carData.metaData.ID == id  then -- load different DF data
            local output = ""
            for _,data in ipairs(data) do
                output = output .. " " .. data
            end
            print(output)
        end
    end

end

-- Getters and setters
function Driver.set_trackPosBias(self,value)
    self.trackPosBias = value
    --print("setting trackPosBias",self.trackPosBias)
end


-- Control layer
function Driver.setSteering(self,value) --Just sets the bearings
   
    for k, v in pairs(sm.interactable.getBearings(self.interactable )) do
        local adj = 3
        --if self.speed > 0.11 then -- prevent twitching while in stand still
        --    local adj = 5 - (0.02*self.speed) -- reduce steer value? 
        --end
        if self.userControl then
            adj = 2
        end
        --self:debugOutput(1,{"steer",value})
        if type(value) ~= "number" or math.abs(value) == math.huge  or math.abs(tostring(value)) == tostring(0/0) or value ~= value then
            print(self.tagText,"Got nan value",value, value ~= value, value == value)
            value = 0 -- set 0 for now... TODO: Get last steering value and set it as that
        end
        sm.joint.setTargetAngle( v, value, adj, 1500)
    end
end

function Driver.outputThrotttle(self,value)
    if value == nil then 
        print(self.tagText,"niloutputpower",value)
        value = 1
    end
    if type(value) ~= "number" or math.abs(value) == math.huge or math.abs(tostring(value)) == tostring(0/0)  then
        print(self.tagText,"not num",value) -- TODO: Look into why this
        value = 0.5
    else
       
    end
    if value > 1 then
        print(self.tagText,"op",value,self.strategicThrottle,self.drafting, self.passing)
    end
    if self.pitState == 4 then -- stoped in pit 
        value = -1
    end
    value = mathClamp(-1,1,value) -- prevent overpower?
    --print("outputting Throttle",value)
    if value == nil then return end
    self.interactable:setPower(value)
end

function Driver.sv_setLogicOutput(self,value)
    self.active = value
	if self.interactable.isActive ~= self.active then
		self.interactable:setActive(self.active)
	end
end


function  Driver.shiftGear(self,gear) --sets the gear for engine
    if self.engine == nil then return end
    if self.engine.engineStats == nil then return end
    self.curGear = gear
    self.engine:setGear(gear)
end

function Driver.updateControlLayer(self) -- Min angle for F1 cars is 40
    if self.nodeMap ~= nil then --TODO: USe this to figue ouyt better way to findNearestNode
        --displayNodeMap(self.nodeMap,self.location)
    end
    --print(self.tagText,"steer",self.strategicSteering)
    if not self.userControl then 
        local angle = steeringToDegrees((self.strategicSteering or 0))-- In Degrees
        local steerLim = 55 -- TODO: "customizable steering limit" in storage and set in ui
        -- Slighlty reduce radians based on speed
        if self.carData and self.carData.metaData then
            if self.carData.metaData.Car_Type == "F1" then -- load different DF data
                steerLim = 40
            end
        end

        angle =mathClamp(-steerLim,steerLim,angle) 
        local speedThresh = 35
        if self.speed > speedThresh then
            --print('s',self.speed)
            local dif = (self.speed/speedThresh)
            --print("b",angle)
            angle = angle/dif
           -- print('p',angle)
            --print()
        end
        local radians = angleToRadians(angle) -- Can save performance by reducing # of conversions if necessary
        self.steering = angle -- Has steering in degrees (necessary to calculate oversteer n stuff)
        local acceleration = (self.strategicThrottle or 0)
        self.throttle = acceleration
        self:setSteering(radians)
        --print(self.tagText,"output Throttle",acceleration,self.strategicThrottle,self.throttle,self.colThrottleAdjust)
        self:outputThrotttle(acceleration)
    else -- user controls outputs
        local angle = -steeringToDegrees(self.userSteer)/2-- In Degrees 
        local radians = angleToRadians(angle) -- Can save performance by reducing # of conversions if necessary
        self.steering = angle -- Has steering in degrees (necessary to calculate oversteer n stuff)
        local acceleration = 0
        if self.userSeated then -- possibly stop car when user gets out of seat
            acceleration = (self.userPower or 0)
        end

        self.throttle = acceleration
        self:setSteering(radians)
        self:outputThrotttle(acceleration)
    end
    local endTime = os.clock()
    local timeDif = endTime - self.startClock
    --self:debugOutput(1,{"Ucon l",timeDif})
end

-- Car state /situational checking

function Driver.checkWide(self) -- checks if car is running too wide {Not necessary?}
    if not self:valididtyCheck() then return end
    -- Check direction wheels are turning
    -- check perpendicular to outside lateral speed
    -- if speed is > threshold, start tapering throttle
    local offline = self.currentNode.width/2.2
    local distFromLine = getDistance(self.currentNode.location,self.location)
    if distFromLine  >  offline then
        --print("wide?",distFromLine,offline)
        self.offline = true
    else
        self.offline = false
    end
    --print("wideCheck:",distFromLine,offline)

end

function Driver.checkTilt(self) -- checks if car is tilted improperly
    local offset = 0 
	local upDir = self.shape:getUp()
	local frontDir = self.shape:getAt()
	if getSign(frontDir.x) == -1 then 
		offset = getSign(upDir.x)
	else
		offset = getSign(upDir.y)
	end
	if math.abs(upDir.y) > 0.6 or math.abs(upDir.x) > 0.6  or upDir.z > -0.8 then  
		self.tilted = true
	end

	local onNose = -0.5
	--print(racer.shape.worldRotation.z)
    local upaxis = sm.vec3.closestAxis(self.shape:getUp())
    --print(self.id,upaxis.z,self.shape.worldRotation.y,upaxis.z)
	if math.abs(self.shape.worldRotation.y) > 0.45  or upaxis.z ~= 1 then 
		--print(self.id,"Tilted",offset)
		self.tilted = true
    else
	    self.tilted = false
    end
end

function Driver.valididtyCheck(self) -- Checks if there are any nils that exist and returns false
    if self.validFail then 
        if self.currentNode == nil then return false end
        if self.goalDirectionOffset == nil then return false end
        if self.engine == nil then return false end
        if self.engine.engineStats == nil then return false end
        if self.goalNode == nil then return false end-- print?
        if self.carDimensions == nil then return false end
        if self.trackPosition == nil then return false end
    else
        if self.currentNode == nil then print(self.tagText,"Current Node Validation Failed") self.validFail = true return false end
        if self.goalDirectionOffset == nil then print("Goal Direction Offset Failed") self.validFail = true return false end
        if self.engine == nil then  print("Engine Discovery Failed")  self.validFail = true return false end
        if self.engine.engineStats == nil then  print("Engine Stat Finding Failed")  self.validFail = true return false end
        if self.goalNode == nil then  print("Goal Node finding Failed") self.validFail = true return false end
        if self.carDimensions == nil then print("Car Dimensions are not loaded") self.validFail = true return false end
        if self.trackPosition == nil then print("Track position not set") self.validFail = true return false end
    end
    self.validFail = false
    return true
end

function Driver.checkOversteer(self) -- check if car is sliding based off of rotation speed alone,
    if self.steering == 0 or self.speed < 13 then -- not overSteering but could still be sliding
        self.oversteer = false
        return
    end
   
    local overSteerThreshold = (self.steering/self.speed)
    local overSteerMeasure = (self.steering * self.angularSpeed) /self.speed
    --print(overSteerMeasure - overSteerThreshold,self.overSteerTolerance)
    if overSteerMeasure - overSteerThreshold * getSign(self.steering) < self.overSteerTolerance  then
        self.oversteer = true
        --print("O",self.id, overSteerMeasure - overSteerThreshold * getSign(self.steering), self.overSteerTolerance,self.oversteer)
    else
        self.oversteer = false
    end
end

function Driver.checkUndersteer(self) -- check if car is sliding based off of rotation speed alone,
    if self.steering == 0 or self.speed <= 13 then
        self.understeer = false
        return
    end
    --print(self.steering,self.speed)
    local nominalMomentum = math.abs(self.steering)/(self.speed +.01) -- nonzero
    local understeerthresh = self.angularSpeed - nominalMomentum
    --print(string.format("understeerDif %.3f %.3f %.3f",nominalMomentum,self.angularSpeed,self.angularSpeed - nominalMomentum))
    if understeerthresh < self.underSteerTolerance then -- was just based on nominal momentum > 1
        self.understeer = true
        --print("U",self.id,understeerthresh,self.speed)
    else
        self.understeer = false
    end
end

function Driver.checkStuck(self) -- checks if car velocity is not matching car rpm

    if self.goalNode == nil then return end-- print?
    if self.engine == nil then return end
    if self.racing == false then return end
    if self.stuckGraceCooldownTimer > 0 then -- timed cooldown
        self.stuckGraceCooldownTimer = self.stuckGraceCooldownTimer - 1
        --print(self.tagText, "Grace period active:", self.stuckGraceCooldownTimer) -- Optional debug
        return 
    end
    if self.stuckCooldown[1] == true then -- location cooldown
        if self.stuckCooldown[2] == nil then -- check if location  is set
            if self.location == nil then -- both are nil
                print("stuck coolwon both nil")
                --print(self.tagText,"stuckcooldown")
                return
            else -- location exists
                self.stuckCooldown[1] = false
                print(self.tagText,"stuck[1] false")
                return
            end
        else -- location node exista
            local dist = getDistance(self.stuckCooldown[2],self.location) -- this is probably how
            
            if dist < 0.6 and self.speed < 0.6 then -- if car is still within small dist
                print(self.tagText,"cooldown stuck?",dist,self.engine.curRPM)
                if self.engine.curRPM > 10 and self.speed < 1 then
                    print("wall Stuck, reset")
                    self.stuckCooldown[1] = false
                end
                return 
            else
                self.stuckCooldown[1] = false
                print(self.tagText,"cooldown stuckfalse")
                return
            end
        end
    end



    local offset = posAngleDif3(self.location,self.shape.at,self.goalNode.location)
    --print(offset,self.goalDirectionOffset)
    --print("hah",self.engine.curRPM)
    --print(self.speed,toVelocity(self.engine.curRPM),self.curGear, offset) -- Get distance away from node? track Dif?
    --print("stuck?",offset,self.goalDirectionOffset)
    if math.abs(offset) >= 30 or math.abs(self.goalDirectionOffset) > math.pi then -- if positional angle
       -- print("Stuck?",offset,self.goalDirectionOffset,self.speed)
        if self.speed <= 2 and not self.userControl and self.stuckCooldown[1] == false then
            print(self.tagText,"offset stuck",offset,math.abs(self.goalDirectionOffset),self.speed,self.stuckCooldown[1])
            self.stuck = true
            return
        end
        
    end
    if  toVelocity(self.engine.curRPM) - self.speed > 2.5 then -- if attempted speed and current speed > 2
        --print(self.tagText,self.speed)
        if self.speed <= 2  and not self.userControl then
            print(self.tagText,"slow stuck",self.speed,self.engine.curRPM,toVelocity(self.engine.curRPM))
            self.stuck = true
            return
        end
    end
    if self.rejoining == false and self.stuck and self.offTrack == 0 and self.speed > 3 then -- check this
        print(self.tagText,"Stuck Off",self.offTrack,self.stuckTimeout,self.speed)
        self.stuck = false
        self.stuckTimeout = 0
    else
        if self.stuck == true then
            --print(self.tagText,"stuck findind stuck")
        end
    end

    if self.speed < 1 and getRaceControl() and self.engine.curRPM > 5  then
        if getRaceControl().raceStatus ~= 0 and self.stuckCooldown[1] == false then
            print(self.tagText,"Confused stuck",self.stuckTimeout,self.stuckCooldown,self.curGear,self.speed,self.engine.curRPM)
            if self.curGear == 0  then 
                self.curGear = 1
                self:shiftGear(self.curGear)
            else
                if self.stuckTimeout >8 then
                    self.stuck = true
                end
                self.stuckTimeout = self.stuckTimeout + 0.1
            end
        end
    end
    --print(self.tagText,self.stuck,self.speed,toVelocity(self.engine.curRPM),self.stuckTimeout,self.strategicThrottle)
end

function Driver.checkOffTrack(self) -- check if car is offtrack based on trackPosition
    if self.currentNode == nil or self.trackPosition == nil then self.offTrack = 0 return end
    if self.currentNode.width == nil then print("setting default width",self.currentNode) self.currentNode.width = 20 end -- Default width?
    local limit = self.currentNode.width/2
    local margin = 3 -- could be dynamic
    local status = math.abs(self.trackPosition) - limit
    if status > margin then
    else
    end

    -- Double checking
    local onTrack = self:checkLocationOnTrack(self.currentNode,self.location,0)
    --print(self.tagText,"Offtrack Check",chot,status > margin,self.offTrack)
    if status > margin and not onTrack then
        --print(self.tagText,"Definitely Off track")
        self.offTrack = status * getSign(self.trackPosition)
    else
        if self.offTrack ~= 0 then
            --print(self.tagText,"Back on track")
            self.offTrack = 0
        end
    end

    if self.offTrack < -5 then -- adjut limits
        self.offTrack = -5
    elseif self.offTrack > 5 then
        self.offTrack = 5
    end

end

function Driver.checkLocationOnTrack(self,currentNode,location, margin) -- checks if location is on track or not based on width of currentNode(needs update eventually)
    if currentNode.width == nil then return true end -- or set currentNode.width = 20
    local vhDist = getLocationVHDist(currentNode,location)
    local nodePos = vhDist.horizontal
    local limit = currentNode.width/2
    local margin = (margin or -3) -- smaller into negatives = more padding to wall
    local status = math.abs(nodePos) - limit
    --print("status",math.abs(nodePos),limit,status,margin)
    if status > margin then
        --print(self.tagText,"Node off track",status,nodePos,limit)
        --print(string.format("GoalNode Location %.2f %.2f %.2f",nodePos,limit,status))
        --print("------------------------\n")
        return false
    else
        return true
    end
end

function Driver.getCurrentSide(self) -- Gets the lane/trackPos of whichever side car is already on, based on node width
    if self.currentNode == nil then return 0 end -- failsafe
    if not self:valididtyCheck() then return 0 end
    local bias = 0
    
    bias = getSign(self.trackPosition) * self.currentNode.width/2.5
   
    return bias
end

-- Strategic Layer
--
function Driver.handleUpdateSector(self,newNode)
    if newNode and newNode.sectorID == nil then return end
    if newNode.sectorID ~= self.currentSector + 1 then
        --print(self.tagText,"bad secto changing",newNode.sectorID , self.currentSector )
        return
    end
    local now = CLOCK()
    if newNode.sectorID ~= self.currentSector and newNode.sectorID ~=1 then -- handle new sector but  only if not first sector
        local time = now - self.sectorStartTime 
        self.sectorTimes[self.currentSector] = time
        if newNode.sectorID == 2 then
            self.sectorTimes[2] = 0 -- sep funct?
            self.sectorTimes[3] = 0
        end
        self.sectorStartTime = now
        self.currentSector = self.currentNode.sectorID
        --if newNode.sectorID == 3 then
            --print(self.tagText,"3startTime")
            --self.sectorStartTime = now
        --end
    end

end



function Driver.updateCurrentNode(self,chain) -- Finds nearest node to car and sets it as so # Rename to setCurrentNode
    --print("udcN",#chain)

    if self.currentNode == nil then -- EItehr first load or node lost
        --print(self.tagText,"CurrentNode is nil")
        local nearestNode = nil
        if self.nodeFindTimeout < 9 and self.speed <= 2 and not self.onLift and not self.nudging then -- if at least mmoving
            --print(self.tagText,'gnn1')
            --nearestNode = getNearestNode(self.nodeMap,self.shape.worldPosition)
            --print(self.tagText,'fcn-1')
            nearestNode = findClosestNode(chain,self.location) -- This doesnt seam to be the most accurrate, Not finding the closest, possibly use the lastKnown Current as a
            -- Look into saving this?
        elseif self.speed > 2 and self.stuckTimeout < 7  and not self.onLift and not self.nudging and not self.userControl then -- dont search while nudging
            --print(self.tagText,'gnn2')
            --nearestNode = getNearestNode(self.nodeMap,self.shape.worldPosition)
            --print(self.tagText,'fcn0')
            nearestNode = findClosestNode(chain,self.location)

        end
        if nearestNode == nil then -- try again with new algo
            --print(self.tagText,'nearrest node is still nil???')
            nearestNode = findClosestNode(chain,self.location)
        end
        --print("nilCurrent",self.nodeFindTimeout,nearestNode == nil)
        if nearestNode == nil then -- IS actually lost
            if not self.onLift then
                self.nodeFindTimeout = self.nodeFindTimeout + 1
                print(self.tagText,"NFT",self.nodeFindTimeout)
                if self.nodeFindTimeout > 10 then
                    self.strategicThrottle = -1
                    if not self.userControl then 
                        print(self.tagText,"Cant find nearest node",self.location)
                        self.lost = true
                        return
                    end
                end
            end
            print(self.tagText,"Trailing return")
            return
        else
            if self.lost and nearestNode ~= nil then
                print(self.tagText, "Is no longer lost",nearestNode.id)
                self.lost = false
                self.nodeFindTimeout = 0
                self:setCurrentNode(nearestNode)
                self.resetNode = nearestNode
            elseif nearestNode ~= nil then
                --print(self.tagText,"Setting new current nodeode",nearestNode.id)
                self.nodeFindTimeout = 0
                self:setCurrentNode(nearestNode)
                self.resetNode = nearestNode
                
            end
        end
        
    end
    --local loc = self.nodeChain[1].mid
    --loc.z = 10
    
    --print("before next items",self.location.z)
    local lastNode = getNextItem(chain,self.currentNode.id,-1)
    local nextNode = getNextItem(chain,self.currentNode.id,1)
    local curNodeDist = getDistance(self.currentNode.location,self.location)
    local lastNodeDist = getDistance(lastNode.location,self.location) -- might have overlap/wrapping issues with pit chain
    local nextNodeDist = getDistance(nextNode.location,self.location)
    self.distanceToNextNode = nextNodeDist -- This might be an issue because what if one is more "inside"
    if lastNode ~= nil then 
        self.resetNode = lastNode
    end

    local distanceThreshold = 30 

    if curNodeDist > distanceThreshold and lastNodeDist > distanceThreshold and nextNodeDist > distanceThreshold then
        --print(self.tagText," car jumped nodes, searching",self.currentNode.id)
        local closestNode = self.currentNode
        if self.nodeFindTimeout < 6 and self.speed <= 1 and not self.onLift and not self.nudging  then -- if not really moving
            if closestNode == nil then
                print(self.tagText,'fcn3')
                closestNode = findClosestNode(chain,self.location)
            end
            --closestNode = getNearestNode(self.nodeMap,self.shape.worldPosition)

            self.nodeFindTimeout = self.nodeFindTimeout + 1
            --print("nonilstopped" ,self.nodeFindTimeout,self.speed, closestNode == nil)
        elseif self.speed > 2 and not self.nudging then
            if closestNode == nil then
                print(self.tagText,'fcn4')
                closestNode = findClosestNode(chain,self.location)
            else
                --print(self.tagText,'fcn5')
                closestNode = findClosestNode(chain,self.location)
            end
            --closestNode = getNearestNode(self.nodeMap,self.shape.worldPosition)
            self.nodeFindTimeout = self.nodeFindTimeout + 0.5
            --print("moving " ,self.nodeFindTimeout,self.speed, closestNode == nil)
        end

        if closestNode == nil and not self.onLift and self.racing == true and not self.userControl then 
            print("Node finding error",self.nodeFindTimeout) 
            self.nodeFindTimeout = self.nodeFindTimeout + 1
            if self.nodeFindTimeout > 8 then
                print(self.tagText,"am lost",closestNode == nil,lastNode == nil,nextNode == nil)
                if lastNode ~= nil then 
                    self.resetNode = lastNode
                end
                self.lost = true
                self.strategicThrottle = -1
            end
            return 
        else
            if self.lost then
               self.lost = false
               self.nodeFindTimeout = 0
               self.strategicThrottle = 1
               --print(self.tagText,"set throttle 1 0-")
            else
                --print(self.tagText,"found node",self.strategicThrottle,self.lost)
                self.nodeFindTimeout = 0
                self.strategicThrottle = 1
                --print("set throttle 1 1-")
            end
        end

        if closestNode == nil and not self.userControl then
            self.lost = true -- Do something with width of track too
            print(self.id,"Racer LOST")
            return
        else
            if self.lost then
                self.lost = false
            end
        end
        -- TODO: Fix this, when user control goes too far, closestNode is nil!
        local closestNodeDist = getDistance(closestNode.location,self.location)
        --print("CheckDist",closestNode.id,nextNode.id)
        if closestNode.id ~= nextNode.id then -- something strange
            if math.abs(closestNode.id - nextNode.id) > 10 then -- way too far of a jump
                --print(self.tagText,"car track jump prevention",closestNode.id,nextNode.id,self.speed)
                hit, data = sm.physics.raycast(self.location, closestNode.location)
                if hit then
                    htype = data.type
                    if htype == "terrainAsset" then
                        self.stuckTimeout = self.stuckTimeout + 5
                    end
                else
                    self:setCurrentNode(nextNode)
                    self:handleUpdateSector(nextNode)
                end
            else
                --print(self.tagText,"car increment",closestNode.id,nextNode.id)
                self:handleUpdateSector(nextNode)
                self:setCurrentNode(closestNode) -- used to be next node
            end
        end
        
    elseif nextNodeDist < curNodeDist then
        --print(self.tagText,"MoveForward?",self.currentNode.id,lastNode.id)
        self:setCurrentNode(nextNode) 
        -- do sector check here
        self:handleUpdateSector(nextNode)
        if self.racing and self.speedControl ~= 0 and self.raceFinished == false then
            --print("speed back")
            self.speedControl = 0
        end
    elseif lastNodeDist < curNodeDist then
        --print(self.tagText,"Movingbackwards?",self.currentNode.id,lastNode.id)
        self.setCurrentNode(lastNode)
        if self.racing then
            self.speedControl = 10
        end
    else
        --print("what?")
    end
end


function Driver.updateGoalNode2(self) -- new version of goal node checking
    if self.lost then return end
    if self.currentNode == nil then return end
    local lookAheadConst = 5 -- play around until perfect -- SHould be dynamic depending on downforce?
    local lookAheadHeur = 0.5 -- same? Dynamic on downforce, more downforce == less const/heuristic?
    
    if self.goalOffsetCorrecting or self.offTrack ~= 0 or self.rejoining then -- if goal offset correcting or off track, lookahead by a lot
        lookAheadConst = 13
        lookAheadHeur = 1
    end

    local lookaheadDist = lookAheadConst + self.speed*lookAheadHeur
    local goalNode = self:getNodeInDistance(lookaheadDist,self.nodeChain)
    --print(self.tagText,"GoalCurrent",goalNode.id,self.currentNode.id)
    self.goalNode = goalNode
end


function Driver.updateGoalNodeMid(self) -- Updates self.goalNode to mid node (overtyped duplicate of goalNode
    if self.lost then return end
    if self.currentNode == nil then return end
    local lookAheadConst = 4 -- play around until perfect -- SHould be dynamic depending on downforce?
    local lookAheadHeur = 0.3 -- same? Dynamic on downforce, more downforce == less const/heuristic?
    if self.rotationCorrect or self.offTrack ~= 0 then 
        --lookAheadConst = 15
        --lookAheadHeur = 2
    end
    
    local lookaheadDist = lookAheadConst + self.speed*lookAheadHeur
    local goalNode = self:getMidNodeInDistance(lookaheadDist)
    --print(self.tagText,goalNode.id,lookaheadDist,self.speed)
    self.goalNode = goalNode
end

function Driver.setCurrentNode(self,node)
    -- TODO: If stuck , run raycast between self and curnode, search until no wall in the way
    if node == nil then 
        --print("node missed")
        return
    else
        --print("set cur node",node.id)
    end
    if self.currentNode == nil or self.currentNode.id ~= node.id then -- or pitting to check...
        local nodeAdd = 0
        if self.currentNode == nil then
            nodeAdd = node.id - 0
        else
            nodeAdd = node.id - self.currentNode.id
        end
        if node.id == 1 and self.pitState > 0 then -- if start finish (grab node dif between curNode and lastnode, else 1)
            nodeAdd = 1
            --print("1 nodeAdd")
            if self.currentLap == 1 then -- if  on first lap of race, reset total nodes ? not needed  i dont think
                --self.totalNodes = 0
                --print("reseting current nodes")
            end
        end
        --print(nodeAdd)
        if nodeAdd < 0 then 
            --print (self.tagText,"Node Moving backwards?",nodeAdd)
        end
        self.totalNodes = self.totalNodes + nodeAdd
        
        --print("Setting current node",node.id)
        self.currentNode = node
        
        if not self.raceControlError and self.racePosition == 1 and self.pitState <= 1 then -- Need better pit lane adjustments
            --print(self.tagText,"adding",self.totalNodes)
            getRaceControl():sv_insertSplitNode(self.totalNodes,self.currentNode)
            self.raceSplit = 0
        elseif not self.raceControlError and self.pitState <= 1 then -- 
            local split = getRaceControl():sv_getNodeSplit(self.totalNodes)
            self.raceSplit = (split or self.raceSplit) -- Set to 0 or pit in when pit status is > 0?
            if self.racePosition == #ALL_DRIVERS then
                --print(self.tagText,"last place removing node",self.totalNodes)
                getRaceControl():sv_removeSplitNode(self.totalNodes) -- offset by one to prevent backwards confusion
            end
        end
        -- crossCheck curSpeed and node Vmax
        if node.segID ~= nil then
            self.currentSegment = node.segID
        end
        --print("Set new node",node.id)
        --print(self.totalNodes,#self.nodeChain)
    end
end
-- TODO: this seems to be acting up when rotation correct, seems to run while loop unecessarily
function Driver.getNodeInDistance(self,distance,chain) -- Searches for race node in distance of car (following path) that is [distance] away from car (forward or backwards)
    if self.currentNode == nil then return end
    local checkIndex = 1 * getSign(distance)
    local nodeDist = getDistance(self.currentNode.location,getNextItem(chain,self.currentNode.id,checkIndex).location)
    --print()
    local nodeDitsTimeout = 0
    local timeoutLimit = 300
    while nodeDist < math.abs(distance) do
        checkIndex = checkIndex + getSign(distance)
        nodeDist = getDistance(self.currentNode.location,getNextItem(chain,self.currentNode.id,checkIndex).location)
        nodeDitsTimeout = nodeDitsTimeout + 1
        if nodeDitsTimeout > timeoutLimit then
            print("Get node in distance timeout")
            break
        end
    end
    local distNode = getNextItem(chain,self.currentNode.id,checkIndex) -- Could possibly just update it in place (unnecessary GetNextItem)
    if self.stuck then 
        --print("found node right at",distNode,nodeDist,distance)
    end
    return distNode
end


function Driver.findPitInNode(self) -- Return distance from pit in Node
    if self.currentNode == nil then return end
    local pitInNode = self.pitChain[1] -- create findPitInNode with either pitChain1 and check the nodetype 1 = pitbegin
    local nodeDist = getDistance(self.currentNode.location,pitInNode.location)
    --print()
    local nodeDitsTimeout = 0
    local timeoutLimit = 300
    while nodeDist < math.abs(distance) do
        checkIndex = checkIndex + getSign(distance)
        nodeDist = getDistance(self.currentNode.location,getNextItem(self.nodeChain,self.currentNode.id,checkIndex).location)
        nodeDitsTimeout = nodeDitsTimeout + 1
        if nodeDitsTimeout > timeoutLimit then
            print("Get node in distance timeout")
            break
        end
    end
    local distNode = getNextItem(self.nodeChain,self.currentNode.id,checkIndex) -- Could possibly just update it in place (unnecessary GetNextItem)
    if self.stuck then 
        --print("found node right at",distNode,nodeDist,distance)
    end
    return distNode
end

function Driver.getPitNodeInDistance(self,distance) -- Searches for pit node in distance of car (following path) that is [distance] away from car (forward or backwards)
    if self.currentNode == nil then return end
    local checkIndex = 1 * getSign(distance)
    local nodeDist = getDistance(self.currentNode.location,getNextItem(self.nodeChain,self.currentNode.id,checkIndex).location)
    --print()
    local nodeDitsTimeout = 0
    local timeoutLimit = 300
    while nodeDist < math.abs(distance) do
        checkIndex = checkIndex + getSign(distance)
        nodeDist = getDistance(self.currentNode.location,getNextItem(self.nodeChain,self.currentNode.id,checkIndex).location)
        nodeDitsTimeout = nodeDitsTimeout + 1
        if nodeDitsTimeout > timeoutLimit then
            print("Get node in distance timeout")
            break
        end
    end
    local distNode = getNextItem(self.nodeChain,self.currentNode.id,checkIndex) -- Could possibly just update it in place (unnecessary GetNextItem)
    if self.stuck then 
        --print("found node right at",distNode,nodeDist,distance)
    end
    return distNode
end

function Driver.getMidNodeInDistance(self,distance) -- Searches for Middle node in distance of car (following path) that is [distance] away from car (forward or backwards)
    if self.currentNode == nil then return end
    local checkIndex = 1 * getSign(distance)
    local nodeDist = getDistance(self.currentNode.mid,getNextItem(self.nodeChain,self.currentNode.id,checkIndex).mid)
    --print()
    local nodeDitsTimeout = 0
    local timeoutLimit = 300
    while nodeDist < math.abs(distance) do
        checkIndex = checkIndex + getSign(distance)
        nodeDist = getDistance(self.currentNode.mid,getNextItem(self.nodeChain,self.currentNode.id,checkIndex).mid)
        nodeDitsTimeout = nodeDitsTimeout + 1
        if nodeDitsTimeout > timeoutLimit then
            print("Get node in distance timeout")
            break
        end
    end
    local distNode = getNextItem(self.nodeChain,self.currentNode.id,checkIndex) -- Could possibly just update it in place (unnecessary GetNextItem)
    if self.stuck then 
        --print("found node right at",distNode,nodeDist,distance)
    end
    return distNode
end

function Driver.checkForClearPit(self,distance) -- Checks for any cars within {distance} nodes on node chain
    local clearFlag = true
    local clearThreshold = distance -- make dynamic?
    local curNodeID = self.currentNode.id
    --local minNode = getNextItem(self.nodeChain,nodeID,-50)
    local maxNode = getNextItem(self.pitChain,curNodeID,2) -- only check 2 ahead
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
        if v.id ~= self.id then 
            --print("scanning",v.id,v.stuck,v.rejoining,v.currentNode.id)
            if not (v.stuck or v.rejoining) and not v.pitState == 0 then -- If its not stuck
                if v.currentNode ~= nil and v.speed > 2 then 
                    local node = v.currentNode.id
                    local nodeDist = getNodeDistBackward(#self.pitChain,maxNode.id,node)
                    if nodeDist < distance then
                        --print("not clear")
                        clearFlag = false
                    end
                end
            end
        end
    end
    return clearFlag
end


function Driver.checkForClearTrack(self,distance) -- Checks for any cars within {distance} nodes on node chain
    local clearFlag = true
    local clearThreshold = distance -- make dynamic?
    local curNodeID = self.currentNode.id
    --local minNode = getNextItem(self.nodeChain,nodeID,-50)
    local maxNode = getNextItem(self.nodeChain,curNodeID,1) -- only check 1 ahead
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
        if v.id ~= self.id then 
            --print("scanning",v.id,v.stuck,v.rejoining,v.currentNode.id)
            if not (v.stuck or v.rejoining) then -- If its not stuck
                if v.currentNode ~= nil and v.speed > 5 then 
                    local node = v.currentNode.id
                    local nodeDist = getNodeDistBackward(#self.nodeChain,maxNode.id,node)
                    if nodeDist < distance then
                        --print("not clear")
                        clearFlag = false
                    end
                end
            end
        end
    end
    return clearFlag
end

function Driver.updatePitBoxSteering(self) -- steers towards pit box
    if self.assignedBox == nil then print(self.tagText,"pboxSteering no pbox") return end
    --if self.goalNode == nil then return end
    
    local goalNodePos = self.assignedBox.location
    local goalOffset = (self:calculateGoalOffset() or sm.vec3.new(0,0,0)) -- needed?
   
    
    goalNodePos = self.assignedBox.location + goalOffset -- 
    local SteerAngle2 = (posAngleDif4(self.location,self.shape.at,goalNodePos) * 2)-- Other priorities are set in calculategoalOffset

    local stratSteer2 = radiansToSteering(SteerAngle2) 
    self.strategicSteering = stratSteer2
end


function Driver.updatePitLaneSteering(self) -- steers Thru pit lane (kinda same as strat steering)
    local SteerAngle
    
    local goalNodePos = self.goalNode.location
    local goalOffset = (self:calculateGoalOffset() or sm.vec3.new(0,0,0))
    local goalPerp = self.goalNode.perp
   
    goalNodePos = self.goalNode['location'] + goalOffset-- place goalnode offset here..
    local SteerAngle2 = (posAngleDif4(self.location,self.shape.at,goalNodePos) * 1)-- Other priorities are set in calculategoalOffset

    local stratSteer2 = radiansToSteering(SteerAngle2) 
    self.strategicSteering = stratSteer2
end

function Driver.updateStrategicSteering(self,pathType) -- updates broad steering goals based on path parameter [race,mid,pit]
    local SteerAngle
    if self.goalNode == nil then return end
    
    local goalNodePos = self.goalNode.location
    local goalOffset = (self:calculateGoalOffset() or sm.vec3.new(0,0,0))
    local goalPerp = self.goalNode.perp
   
    if pathType == "mid" then -- TODO: make ready for PIT and MID and OTHER?
        goalNodePos = self.goalNode[pathType] --+ goalOffset?
    end
    goalNodePos = self.goalNode[pathType] + goalOffset-- place goalnode offset here...
    
    -- check if goalNode pos is offTrack
    local onTrack = self:checkLocationOnTrack(self.goalNode,goalNodePos)
    if not onTrack and self.pitState == 0 then
        --print(self.tagText,"offtrack goal")
        if self.passing.isPassing then
            --self.strategicThrottle = self.strategicThrottle - 0.01
            self:cancelPass("strategic steer Not on track 1735")
        end
        -- todo:  set goal to be at edge of track
        goalNodePos = self.goalNode[pathType]
        self.goalOffset = sm.vec3.new(0,0,0) 
    end
    local followStren = self.followStrength
    local directionOffset = self.goalDirectionOffset
    if self.trackPosBias ~= nil and self.trackPosBias ~= nil then -- TODO: Remove in all strat steer functrs
        biasDif = (self.trackPosBias -self.trackPosition)
    end

    if self.speed < 1 then 
        directionOffset = 0
    end

    local goalAngleDif = self.goalDirection
    --rint(self.tagText,posAngleDif4(self.location,self.shape.at,goalNodePos))
    --local SteerAngle = (posAngleDif3(self.location,self.shape.at,goalNodePos)/7) + biasDif + directionOffset -- VErsion one 
    --local stratSteer1 = degreesToSteering(SteerAngle) -- */ speed?
    local SteerAngle2 = (posAngleDif4(self.location,self.shape.at,goalNodePos) * self.nodeFollowPriority)-- Other priorities are set in calculategoalOffset
    if self.currentNode and self.currentNode.bank ~= nil and self.currentNode.bank ~= 0 then
        local bankAdjust = 0
        local dampMult = 1.5

        if getSegTurn(self.currentNode.segType) <= -2 and SteerAngle2 < 0 then -- if turning left and steering is left
            dampMult = 1
        elseif getSegTurn(self.currentNode.segType) <= -2 and SteerAngle2 > 0 then -- if turning left but steering is right
            dampMult = 1.5
        elseif getSegTurn(self.currentNode.segType) >= 2 and SteerAngle2 > 0 then -- if turning right and steering is right
            dampMult = 1
        elseif getSegTurn(self.currentNode.segType) >= -2 and SteerAngle2 < 0 then -- if turning right but steering is left
            dampMult = 1.5
        end
        if getSign(self.currentNode.bank) == getSign(SteerAngle2) and self.currentNode.bank ~= 0 then -- if steering left while on left bank
            --print(self.tagText,"bank turn similarity",self.currentNode.bank,SteerAngle2)
            dampMult = 1.2
            bankAdjust = SteerAngle2 - (SteerAngle2 *(dampMult *math.abs(self.currentNode.bank)))
            SteerAngle2 = bankAdjust --add this in later
        else -- Still dampen turns but not as much
            dampMult = 0.8
            --print(self.tagText,"bank turn opp",self.currentNode.bank,SteerAngle2)
            bankAdjust = SteerAngle2 - (SteerAngle2 *(dampMult *math.abs(self.currentNode.bank)))
            SteerAngle2 = bankAdjust --add this in later
        end

        local alongSideAdjust = 0
        --if self.carAlongSide.left ~= 0 then 
        
        --end
        --if self.carAlongSide.right ~= 0 then
            --print()
        --end
         -- TODO: Normalize all values of inputs (car Radar, steer angle, etc)
         -- Eventually get normal of this
        if self.carAlongSide.left ~= 0 and self.carAlongSide.right ~= 0 then
            --local weight = self.carAlongSide.left + self.carAlongSide.right
            --print(self.tagText,SteerAngle2,weight)
            --alongSideAdjust = SteerAngle2 * -(weight*1.2)
            --SteerAngle2 = SteerAngle2 + alongSideAdjust 
            --print(self.tagText,SteerAngle2,alongSideAdjust)
        end

        
        --stratSteer2 = bankAdjust 
    end
    local stratSteer2 = radiansToSteering(SteerAngle2) 
    self.strategicSteering = stratSteer2
end

--TODO overhaul this
function Driver.updateCautionSteering(self,pathType) -- updates broad steering goals based on path parameter [race,mid,pit]
    local SteerAngle
    if self.goalNode == nil then return end
    
    local goalNodePos = self.goalNode.mid 
    local goalOffset = (self:calculateGoalOffset() or sm.vec3.new(0,0,0))
    goalNodePos = self.goalNode.mid + goalOffset-- place goalnode offset here...
    -- check if goalNode pos is offTrack
    local onTrack = self:checkLocationOnTrack(self.goalNode,goalNodePos)
    if not onTrack then
        --print("caution mid node not on track")
        if self.passing.isPassing then
            --print("offtrackStuff?")
            self.strategicThrottle = self.strategicThrottle - 0.01
        end
        goalNodePos = self.goalNode.mid
        if self.strategicThrottle > -1 then -- COrrect this foo by using offset too?
            self.strategicThrottle = self.strategicThrottle - 0.05
            --print("heading offtrack correction",self.strategicThrottle)
        end
    end
    local baseSpeed = 10 -- Base speed for caution
    local slowSpeed = 8 -- slow speed for caution
    local fastSpeed = 12 -- fast speed for caution
    self.speedControl = 10 -- use this to speed up or slow down
    self.trackPosBias = 0 -- can use this to let car pick side + = right - = left
    self.followStrength = 1 -- 1 is strong, 10 is weak ( use this when passing on certain sides along with trackPosBias)
    local biasMult = 1.1
   
    
    if #ALL_DRIVERS > 1 then -- check self position in relation to cautionPos
        if self.racePosition == self.cautionPos then -- if car is aligned in position
            -- Double check if car's rear is behind by 5?
            local dist = 0
            if self.cautionPos < #ALL_DRIVERS then -- if not in last
                local rearCar = getDriverByPos(self.racePosition + 1)
                dist = getDriverDistance(self,rearCar,#self.nodeChain)
                --print(dist)
            else --if in last
                local frontCar = getDriverByPos(self.racePosition - 1)
                dist = getDriverDistance(frontCar,self,#self.nodeChain) -- should be a negative distance, but seems to not always be the case
                --print(dist)
            end
            --local name = (self.carData['metaData'].Car_Name or 'Unnamed')
            --print(name,dist,self.cautionPos,self.racePosition)
            if dist < - 15 then -- if car behind is decent distance, do stuff
                if self.racePosition == 1 then -- if in first then set pace
                    if self.raceRestart then -- if the race is restarting
                        self.speedControl = 0
                        self.caution = false
                        self.formation = false
                        self.raceRestart = false
                        self.followStrength = 4
                        self.trackPosBias = 0
                    else
                        self.speedControl = baseSpeed
                        self.trackPosBias = 0
                        self.followStrength = 3
                    end
                else -- find distance from car in front and stay 5? away
                    local frontCar = getDriverByPos(self.cautionPos - 1)
                    local frontDist = self.carRadar.front
                    local carDist = frontDist
                    if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                        --print("invalid frontCar",self.racePosition,self.cautionPos,frontCar)
                    else
                        carDist = getDistance(self.location, frontCar.location)
                    end
                    
                    --print("2",name, carDist,self.speedControl)
                    if  carDist < 12 then -- if car too close, slow down
                        self.speedControl = slowSpeed
                    elseif carDist > 15 then -- if car too far, speed up
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = fastSpeed
                            if carDist > 20 then -- super fast speed
                                self.speedControl = fastSpeed + 5
                            end
                        end
                    else -- if car right in the money
                        self.speedControl = baseSpeed-- or whatever speed we decide
                    end
                end
            else -- if car behind is too close, speed up/ continue normal speed
                -- continue on path TODO: make these into separate function, lots of repetition
                if self.racePosition == 1 then -- if in first then set pace
                    if self.raceRestart then -- if the race is restarting
                        self.speedControl = 0
                        self.caution = false
                        self.formation = false
                        self.raceRestart = false
                        self.followStrength = 4
                        self.trackPosBias = 0
                    else
                        self.speedControl = baseSpeed
                        self.trackPosBias = 0
                        self.followStrength = 3
                    end
                else -- find distance from car in front and stay 5? away
                    local frontCar = getDriverByPos(self.cautionPos - 1)
                    local frontDist = self.carRadar.front
                    local carDist = frontDist
                    if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                        --print("invalid frontCar",self.racePosition,self.cautionPos,frontCar)
                    else
                        carDist = getDistance(self.location, frontCar.location)
                    end
                    
                    if  carDist < 12 then -- if car too close, slow down
                        self.speedControl = slowSpeed
                    
                    elseif carDist > 14 then -- if car too far, speed up
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = fastSpeed
                            if carDist > 20 then -- super fast speed
                                self.speedControl = fastSpeed + 5
                            end
                        end
                    else -- if car right in the money
                        self.speedControl = baseSpeed-- or whatever speed we decide
                    end
                end
            end

        elseif self.racePosition > self.cautionPos then --  if car is behind desired caution pos 
            self.trackPosBias = -13 -- put car on left side of track
            --print(self.tagText,"setting bias",self.trackPosBias)
            self.followStrength = 7 -- loosely follow left side ish
            -- will continue this until racePosition == caution Pos
            --print("")
            if self.raceRestart then -- if the race is restarting
                self.speedControl = 0
                self.caution = false
                self.formation = false
                self.raceRestart = false
                self.trackPosBias = 0
                self.followStrength = 4
            else
                self.speedControl = fastSpeed -- Add a distance measurement to next pplace and increase fast speed
            end
        elseif self.racePosition < self.cautionPos then -- if car is ahead of desired cautionpos 
            if self.cautionPos <= 1 then --This shouldnt happen
               --print(" invalid cautionPos",self.racePosition,self.cautionPos)
            else -- Keep distance away from head car (makes room for car inbetween)
                local frontCar = getDriverByPos(self.cautionPos - 1) -- car you want to follow
                local frontDist = self.carRadar.front
                local carDist = frontDist
                if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                   -- print("invalid frontCar",self.racePosition,self.cautionPos,frontCar)
                   --print("fail frontCar",carDist)
                else
                    carDist = getDistance(self.location, frontCar.location)
                    --print(" got frontCar",carDist)
                end


                --print("carDist",carDist)
                if carDist <  16 then -- make big gap
                    self.speedControl = slowSpeed - 1
                elseif carDist > 20 then -- if car too far, speed up
                    if self.raceRestart then -- if the race is restarting
                        self.speedControl = 0
                        self.caution = false
                        self.formation = false
                        self.raceRestart = false
                        self.followStrength = 4
                        self.trackPosBias = 0
                    else
                        self.speedControl = fastSpeed -- Add a distance measurement to next pplace and increase fast speed
                    end
                else -- if car right in the money
                    self.speedControl = baseSpeed -- or whatever speed we decide
                end
            end
        end
    else -- if only driver then just check for race restart
        if self.raceRestart then -- if the race is restarting
            self.speedControl = 0
            self.caution = false
            self.formation = false
            self.raceRestart = false
            self.followStrength = 4
            self.trackPosBias = 0
        end
    end

    local biasDif = 0
    local followStren = self.followStrength
    local directionOffset = self.goalDirectionOffset

    if self.trackPosBias ~= nil and self.trackPosBias ~= 0 then
        biasDif = (self.trackPosBias -self.trackPosition)
        --print(self.trackPosBias,self.trackPosition,biasDif)
        biasDif = biasDif* biasMult  
    end
    if biasDif ~= 0 and math.abs(self.offTrack) == 0 then -- makes a slower recovery?
        --followStren = 5
        directionOffset = directionOffset * 1.5
    end
    if self.speed < 2 then 
        directionOffset = 0
    end
    if math.abs(self.offTrack) > 1 then
        followStren = followStren * 0.2
    end
    if self.curGear <=0  then
        directionOffset = 0
    end
    --SteerAngle = (posAngleDif3(self.location,self.shape.at,goalNodePos)/followStren) --+ biasDif + directionOffset -- OLD way
    --print(self.tagText,goalOffset,biasDif,directionOffset)
    local SteerAngle2 = (posAngleDif4(self.location,self.shape.at,goalNodePos) * self.nodeFollowPriority) --+ biasDif + directionOffset -- Other priorities are set in calculategoalOffset
    local stratSteer2 = radiansToSteering(SteerAngle2) 
    self.strategicSteering = stratSteer2
end

-- TODO: get track width too
function posFromLane(lane)
    if lane == 0 then 
        return -9
    else 
        return 9
    end
end

function Driver.updateFormationSteering(self,pathType) -- updates broad steering goals based on path parameter [race,mid,pit]
    --print(self.tagText,"form",self.trackPosBias)

    local SteerAngle
    if self.goalNode == nil then return end
    local formationLane = self.formationPos %2
    local goalNodePos = self.goalNode.mid
    local goalOffset = (self:calculateGoalOffset() or sm.vec3.new(0,0,0))
    goalNodePos = self.goalNode.mid + goalOffset-- place goalnode offset here...
    -- check if goalNode pos is offTrack
    local onTrack = self:checkLocationOnTrack(self.goalNode,goalNodePos)
    if not onTrack then
        --print("formation node not on track")
        if self.passing.isPassing then
            --print("offtrackStuff?")
            self.strategicThrottle = self.strategicThrottle - 0.05
        end
        goalNodePos = self.goalNode.mid
        if self.strategicThrottle > -1 then -- COrrect this foo by using offset too?
            self.strategicThrottle = self.strategicThrottle - 0.05
            --print("heading offtrack correction",self.strategicThrottle)
        end
    end
    local baseSpeed = 11 -- Base speed for formation
    local slowSpeed = 8 -- slow speed for formation
    local fastSpeed = 12 -- fast speed for formation
    self.speedControl = baseSpeed -- use this to speed up or slow down
    
    self.trackPosBias = 0 -- can use this to let car pick side + = right - = left
    self.followStrength = 3 -- 1 is strong, 10 is weak ( use this when passing on certain sides along with trackPosBias)
    local biasMult = 1.1
   
    -- TODO: Have racecontrol constantly check if all cars are in good formation, 
    -- while cars are not in good formation, have them have a slight bias
    -- if cars are less than 80%? of track, continue in caution
    local trackDistance = #self.nodeChain
    local formationPoint = (trackDistance * 0.80) -- 80% of track distance
    --print(self.formationPos,formationLane,self.currentNode.id,formationPoint,trackDistance)
    --print(self.currentNode.id,formationPoint)
    --print(self.tagText,self.formationPos,self.currentNode.id,formationPoint)
    if self.currentNode.id < formationPoint then -- Perform normal caution logic when before formation point
        self.trackPosBias = 0 
        if #ALL_DRIVERS > 1 then -- check self position in relation to formationPos
            if self.racePosition == self.formationPos then -- if car is aligned in position
                -- Double check if car's rear is behind by 5?
                local dist = 0
                if self.formationPos < #ALL_DRIVERS then -- if not in last
                    local rearCar = getDriverByPos(self.racePosition + 1)
                    dist = getDriverDistance(self,rearCar,#self.nodeChain)
                    --print(dist)
                else --if in last
                    local frontCar = getDriverByPos(self.racePosition - 1)
                    dist = getDriverDistance(frontCar,self,#self.nodeChain) -- should be a negative distance, but seems to not always be the case
                    --print(dist)
                end
                --local name = (self.carData['metaData'].Car_Name or 'Unnamed')
                --print(name,dist,self.formationPos,self.racePosition)
                if dist < - 15 then -- if car behind is decent distance, do stuff
                    if self.racePosition == 1 then -- if in first then set pace
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = baseSpeed
                            self.trackPosBias = 0
                            self.followStrength = 3
                        end
                    else -- find distance from car in front and stay 5? away
                        local frontCar = getDriverByPos(self.formationPos - 1)
                        local frontDist = self.carRadar.front
                        local carDist = frontDist
                        if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                            --print("invalid frontCar",self.racePosition,self.formationPos,frontCar)
                        else
                            carDist = getDistance(self.location, frontCar.location)
                        end
                        
                        --print("2",name, carDist,self.speedControl)
                        if  carDist < 12 then -- if car too close, slow down
                            self.speedControl = slowSpeed
                        elseif carDist > 12.5 then -- if car too far, speed up
                            if self.raceRestart then -- if the race is restarting
                                self.speedControl = 0
                                self.caution = false
                                self.formation = false
                                self.raceRestart = false
                                self.followStrength = 4
                                self.trackPosBias = 0
                            else
                                self.speedControl = fastSpeed
                                if carDist > 20 then -- super fast speed
                                    self.speedControl = fastSpeed + 5
                                end
                            end
                        else -- if car right in the money
                            self.speedControl = baseSpeed-- or whatever speed we decide
                        end
                    end
                else -- if car behind is too close, speed up/ continue normal speed
                    -- continue on path TODO: make these into separate function, lots of repetition
                    if self.racePosition == 1 then -- if in first then set pace
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = baseSpeed
                            self.trackPosBias = 0
                            self.followStrength = 3
                        end
                    else -- find distance from car in front and stay 5? away
                        local frontCar = getDriverByPos(self.formationPos - 1)
                        local frontDist = self.carRadar.front
                        local carDist = frontDist
                        if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                            --print("invalid frontCar",self.racePosition,self.formationPos,frontCar)
                        else
                            carDist = getDistance(self.location, frontCar.location)
                        end
                        
                        if  carDist < 12 then -- if car too close, slow down
                            self.speedControl = slowSpeed
                        
                        elseif carDist > 14 then -- if car too far, speed up
                            if self.raceRestart then -- if the race is restarting
                                self.speedControl = 0
                                self.caution = false
                                self.formation = false
                                self.raceRestart = false
                                self.followStrength = 4
                                self.trackPosBias = 0
                            else
                                self.speedControl = fastSpeed
                                if carDist > 20 then -- super fast speed
                                    self.speedControl = fastSpeed + 20
                                end
                            end
                        else -- if car right in the money
                            self.speedControl = baseSpeed-- or whatever speed we decide
                        end
                    end
                end

            elseif self.racePosition > self.formationPos then --  if car is behind desired caution pos 
                self.trackPosBias = -13 -- put car on left side of track
                self.followStrength = 6 -- loosely follow left side ish
                -- will continue this until racePosition == caution Pos
                --print("")
                if self.raceRestart then -- if the race is restarting
                    self.speedControl = 0
                    self.caution = false
                    self.formation = false
                    self.raceRestart = false
                    self.trackPosBias = 0
                    self.followStrength = 4
                else
                    self.speedControl = fastSpeed + 10 -- Add a distance measurement to next pplace and increase fast speed
                end
            elseif self.racePosition < self.formationPos then -- if car is ahead of desired formationPos 
                if self.formationPos == 1 then -- yae this shouldnt happe
                --print(self.tagText," invalid formationPos",self.racePosition,self.formationPos)
                else -- Keep distance away from head car (makes room for car inbetween)
                    local frontCar = getDriverByPos(self.formationPos - 1) -- car you want to follow
                    local frontDist = self.carRadar.front
                    local carDist = frontDist
                    if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                    --print(self.tagText,"invalid frontCar",self.racePosition,self.formationPos,frontCar)
                    --print("fail frontCar",carDist)
                    else
                        carDist = getDriverHVDistances(self, frontCar).vertical
                        --print(self.tagText," got frontCar",carDist)
                    end
                    self.trackPosBias = 3 -- move slighlty to right

                    --print("carDist",carDist)
                    if carDist <  16 then -- make big gap
                        self.speedControl = slowSpeed - 2
                    elseif carDist > 20 then -- if car too far, speed up
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = fastSpeed -- Add a distance measurement to next pplace and increase fast speed
                        end
                    else -- if car right in the money
                        self.speedControl = baseSpeed -- or whatever speed we decide
                    end
                end
            end
        else
            if self.raceRestart then -- if the race is restarting
                self.speedControl = 0
                self.caution = false
                self.formation = false
                self.raceRestart = false
                self.followStrength = 4
                self.trackPosBias = 0
            end
        end
    else -- Perform new formation logic when after formation point TODO: pack these into separate functions and just call them here lots of redundancy
        if #ALL_DRIVERS > 1 then -- check self position in relation to formationPosition
            if self.racePosition == self.formationPos then -- if car is aligned in position
                -- Double check if car's rear is behind by 5?
                local dist = 0
                self.trackPosBias =  posFromLane(formationLane)
                biasMult =1.3 --
                self.followStrength = 7 -- loosen? or somehow get trackBias Strength tighened
                if self.formationPos < #ALL_DRIVERS - 1 then -- if not in last two spots
                    local rearCar = getDriverByPos(self.racePosition + 2) -- should be car set directly behind
                    dist = getDriverDistance(self,rearCar,#self.nodeChain)
                    --print(dist)
                else --if in last two spots
                    local frontCar = getDriverByPos(self.racePosition - 2)
                    dist = getDriverDistance(frontCar,self,#self.nodeChain) -- should be a negative distance, but seems to not always be the case
                    --print(dist)
                end
                
                --local name = (self.carData['metaData'].Car_Name or 'Unnamed')
                if dist < - 10 then -- if car behind is decent distance, do stuff
                    if self.racePosition == 1 then -- if in first then set pace
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = baseSpeed - 2 -- possibly switch to slow speed
                            self.formationAligned = true -- grab track Pos too?
                            self.trackPosBias =  posFromLane(formationLane)
                            self.followStrength = 7
                        end
                    elseif self.racePosition == 2 then -- second place slightly behind -- may need to change to formationPos
                        local frontCar = getDriverByPos(self.formationPos - 1) -- should be first place
                        local frontDist = self.carRadar.front
                        local carDist = frontDist
                        if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                            --print("invalid formation frontCar",self.racePosition,self.formationPos,frontCar)
                        else
                            carDist = getDriverHVDistances(self, frontCar).vertical
                        end
                        
                        --print("vhDist",self.tagText, carDist,self.speedControl)
                        if  carDist < 1 then -- if car too close, slow down
                            self.speedControl = slowSpeed - 1
                        elseif carDist >= 2 then -- if car too far, speed up
                            if self.raceRestart then -- if the race is starting. either ignore distance
                                self.speedControl = 0
                                self.caution = false
                                self.formation = false
                                self.raceRestart = false
                                self.followStrength = 4
                                self.trackPosBias = 0
                            else
                                self.speedControl = fastSpeed -2
                            end
                        else -- if car right in the money -- might need to turn this off on any other error
                            self.formationAligned = true
                            self.speedControl = baseSpeed - 2-- or whatever speed we decide
                        end
                
                    else -- find distance from car in front and stay 5? away
                        local frontCar = getDriverByPos(self.formationPos - 2)
                        local frontDist = self.carRadar.front
                        local carDist = frontDist
                        if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                            --print("invalid frontCar",self.racePosition,self.cautionPos,frontCar)
                        else
                            carDist = getDistance(self.location, frontCar.location)
                        end
                        
                        --print("nottop2",self.tagText, carDist)
                        if  carDist < 13 then -- if car too close, slow down
                            self.speedControl = slowSpeed - 2
                            --print("slowplz")
                        elseif carDist > 14 then -- if car too far, speed up
                            if self.raceRestart then -- if the race is restarting
                                self.speedControl = 0
                                self.caution = false
                                self.formation = false
                                self.raceRestart = false
                                self.followStrength = 4
                                self.trackPosBias = 0
                            else
                                self.speedControl = fastSpeed
                            end
                        else -- if car right in the money -- might need to turn this off on any other error
                            self.formationAligned = true
                            self.speedControl = baseSpeed - 2-- or whatever speed we decide
                        end
                    end
                else -- if car behind is too close, speed up/ continue normal speed
                    self.formationAligned = true
                    -- continue on path TODO: make these into separate function, lots of repetition
                    if self.racePosition <= 2 then -- if in first then set pace
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = baseSpeed - 2
                            
                        end
                    else -- if not top 2
                        local frontCar = getDriverByPos(self.formationPos - 2)
                        local frontDist = self.carRadar.front
                        local carDist = frontDist
                        if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                            --print("invalid frontCar",self.racePosition,self.formationPos,frontCar)
                        else
                            carDist = getDistance(self.location, frontCar.location)
                        end
                        
                        if  carDist < 12 then -- if car too close, slow down
                            self.speedControl = slowSpeed - 2
                        
                        elseif carDist > 13 then -- if car too far, speed up
                            if self.raceRestart then -- if the race is restarting
                                self.speedControl = 0
                                self.caution = false
                                self.formation = false
                                self.raceRestart = false
                                self.followStrength = 4
                                self.trackPosBias = 0
                            else
                                self.speedControl = fastSpeed - 2
                            end
                        else -- if car right in the money
                            self.speedControl = baseSpeed - 2-- or whatever speed we decide
                        end
                    end
                end

            elseif self.racePosition > self.formationPos then --  if car is behind desired caution pos 
                self.trackPosBias = posFromLane(formationLane) * 1.1 -- exxagerate pos slightly, maybe increase?
                self.followStrength = 7
                if self.raceRestart then -- if the race is restarting, just go
                    self.speedControl = 0
                    self.caution = false
                    self.formation = false
                    self.raceRestart = false
                    self.followStrength = 4
                    self.trackPosBias = 0
                else
                    self.speedControl = fastSpeed - 2 -- Add a distance measurement to next pplace and increase fast speed
                end
            elseif self.racePosition < self.formationPos then -- if car is ahead of desired cautionpos 
                self.trackPosBias = posFromLane(formationLane)
                if self.formationPos <= 1 then --This shouldnt happen
                --print(" invalid cautionPos",self.racePosition,self.cautionPos)
                elseif self.formationPos == 2 then -- second place looks ahead at first, can change this
                    self.trackPosBias = posFromLane(formationLane)
                    self.followStrength = 7
                    self.speedControl = slowSpeed -1

                else -- Keep distance away from head car (makes room for car inbetween)
                    local frontCar = getDriverByPos(self.formationPos -2) -- car you want to follow
                    local frontDist = self.carRadar.front
                    local carDist = frontDist
                    if frontCar == nil then -- If this fails, it will fallback into whatever they currently are set up as
                    -- print("invalid frontCar",self.racePosition,self.cautionPos,frontCar)
                    --print("fail frontCar",carDist)
                    else
                        carDist = getDistance(self.location, frontCar.location)
                        --print(" got frontCar",carDist)
                    end


                    --print("carDist",carDist)
                    if carDist <  16 then -- make big gap -- TODO: check if this is flip flopped, seems like it may speed up when car ahead is too far away, use vhdif instead?
                        self.speedControl = slowSpeed - 2
                    elseif carDist > 20 then -- if car too far, speed up
                        if self.raceRestart then -- if the race is restarting
                            self.speedControl = 0
                            self.caution = false
                            self.formation = false
                            self.raceRestart = false
                            self.followStrength = 4
                            self.trackPosBias = 0
                        else
                            self.speedControl = fastSpeed - 2-- Add a distance measurement to next pplace and increase fast speed
                        end
                    else -- if car right in the money
                        self.speedControl = baseSpeed - 2-- or whatever speed we decide
                    end
                end
            end
        else
            if self.raceRestart then -- if the race is restarting
                self.speedControl = 0
                self.caution = false
                self.formation = false
                self.raceRestart = false
                self.followStrength = 4
                self.trackPosBias = 0
            end
        end

    end
    

    local biasDif = 0
    local followStren = self.followStrength
    local directionOffset = self.goalDirectionOffset

    if self.trackPosBias ~= nil and self.trackPosBias ~= 0 then
        biasDif = (self.trackPosBias -self.trackPosition)
        --print(self.trackPosBias,self.trackPosition,biasDif)
        biasDif = biasDif* biasMult  
    end
    if biasDif ~= 0 and math.abs(self.offTrack) == 0 then -- makes a slower recovery?
        --followStren = 5
        directionOffset = directionOffset * 1.5
    end
    if self.speed < 2 then 
        directionOffset = 0
    end
    if math.abs(self.offTrack) > 1 then
        followStren = followStren * 0.2
    end
    if self.curGear <=0  then
        directionOffset = 0
    end
    --print(self.tagText,self.formationPos,self.trackPosition,self.trackPosBias,self.biasGoalOffsetStrength)

    --SteerAngle = (posAngleDif3(self.location,self.shape.at,goalNodePos)/followStren) + biasDif + directionOffset
    --print("ag",self.trackPosBias,self.trackPosition,biasDif,SteerAngle)
    --self.strategicSteering = degreesToSteering(SteerAngle) -- */ speed?
    local SteerAngle2 = (posAngleDif4(self.location,self.shape.at,goalNodePos) * self.nodeFollowPriority) --+ biasDif + directionOffset -- Other priorities are set in calculategoalOffset
    local stratSteer2 = radiansToSteering(SteerAngle2) 
    self.strategicSteering = stratSteer2
end


function Driver.sv_setup_pit(self,strategy) -- starts pit behvior for thi lap
    if self.pitState >= 1 then -- If get pit command while in stop or leaving, then dont do anything
        print(self.tagText,"Got too quick Pit request")
        return
    end
    -- If car is still going into pit lane or not in pit lane yet allow it to happens
    self.pitState  = 1 -- Sets car to be in pit state - 1: search for entry 2: on entry: 3 pit In: 4: pit stopped, 5: pit Out: 6: pit exit: -- 0 = race
    self.pit_strategy = strategy -- sets strategy

end

function Driver.updatePitNode(self) -- Checks for distance from pit node and crosschecks with node chain    
    if self.lost then return end
    if self.currentNode == nil then return end
    local lookaheadDist = 5
    -- pit node checking
    local pitEntryNode = self.pitChain[1] -- double check pit entry node type
    local pitEntryDist = getDistance(self.location,pitEntryNode.location)
    local goalNode = self:getNodeInDistance(lookaheadDist,self.nodeChain) -- uses node chain until pit chain
    if self.pitState == 1 then
        --print(self.tagText,"PitEntryDist",pitEntryDist,self.speed)
    end
    if pitEntryDist < 80  and pitEntryDist > 40 and self.pitState == 1 then
        self.speedControl = 25
        local lookAheadConst = 10 -- play around until perfect -- SHould be dynamic depending on downforce?
        local lookAheadHeur = 0.5 -- same? Dynamic on downforce, more downforce == less const/heuristic?
        lookaheadDist = lookAheadConst + self.speed*lookAheadHeur
    elseif pitEntryDist <= 40 and self.pitState == 1 then
        local lookAheadConst = 10 -- play around until perfect -- SHould be dynamic depending on downforce?
        local lookAheadHeur = 0.5 -- same? Dynamic on downforce, more downforce == less const/heuristic?
        lookaheadDist = lookAheadConst + self.speed*lookAheadHeur
        self.speedControl = 20
        self.currentNode = nil
        self.pitIn = true
        self.pitState = 2 -- start following pit chain
        goalNode = self:getNodeInDistance(lookaheadDist,self.pitChain)
    elseif self.pitState >= 2 then  -- WHen not in pit lane?
        goalNode = self:getNodeInDistance(lookaheadDist,self.pitChain)
    end

    if self.pitState >= 2 or self.pitState <= 6 then
        self.goalNode = goalNode
    end
    
end

function Driver.execute_pit_strategy(self) -- uses pit strategy to update tyier type and fuel level
    --print("Executing Pit",self.Fuel_Level,self.pit_strategy)
    self.Fuel_Level = mathClamp(0,100,self.Fuel_Level + self.pit_strategy.Fuel_Fill)
    if self.pit_strategy.Tire_Change ~= 0 then
        self.Tire_Type = self.pit_strategy.Tire_Change
        self.Tire_Health = 100 -- or whatever full is
    end
end

function Driver.placeCarInBox(self,location) -- lift seems unreliabble. might use physics force
    if self.currentNode == nil then print("rcib no cnode") return end
    --print("placing car in box",location,self.assignedBox.location)

    local locDif = (location - self.location):normalize()
    local rotDif = self.shape.up - self.currentNode.outVector -- normalize?
    
    local difDist = getDistance(self.location,location)

    if self.speed > 0.01 then
        self.engine:setRPM(0) -- kill engine
    end

    if difDist > 2 then
        sm.physics.applyImpulse( self.shape.body, locDif * 3800 ,true)
    else
        --print('rot',rotDif)
        local angleDif =angleDiff(self.shape.at,self.currentNode.outVector)
        local rotVec = sm.vec3.new(0,0,-angleDif)
        sm.physics.applyTorque(self.shape.body,rotVec * 3500,false)
        --sm.physics.applyTorque(self.shape.body,rotDif * 4000,false)
    end

    --[[ -- old way with lift
    
    local bodies = self.body:getCreationBodies()
    self.creationBodies = bodies
    
    local rotation = getRotationIndexFromVector(self.shape.at,0.75) -- do currentNode instead?
    if rotation == -1 then
        --print("Got bad rotation")
        rotation = getRotationIndexFromVector(self.currentNode.outVector, 0.45) -- less precice, more likely to go wrong or do a getNearest Axis and then rotate
    end
    local realPos = sm.vec3.new(math.floor( location.x + 0.5 ), math.floor( location.y + 0.5 ), math.floor(  location.z + 1 ))
    -- check if this will intersect with anything elselocal okPosition, liftLevel = sm.tool.checkLiftCollision( self.creationBodies, realPos, rotation )
    --print("QuieckCHeck",okPosition,liftLevel)
    if okPosition then
        sm.player.placeLift( self.player, self.creationBodies , realPos, liftLevel, rotation ) --Lift Level, rotation index
        if not self.liftPlaced then
            self.liftPlaced = true
        end
    end]]
end


function Driver.updatePitBehavior(self)
    --- first things first:
    --- indicate where car is on pit chain
    local pitSpeedLimit = 15
    local pitSpeedSlow = 12
    local pitSpeedFast = 17
    
    --- 
   
    if self.assignedBox == nil then -- break?
        print(self.tagText,"No Assigned Pit")
        -- keep asking for pit?

    else
        --print(self.assignedBox.location)
        --{<Vec3>, x = -77.8808, y = -233.345, z = 0.969536},
    end

    if self.pitState == 1 then -- searching for node
        self:updatePitNode() -- Searches for goal node unitl not needed
        --print(self.tagText,self.speedControl)
        --self:updateStrategicSteering(self.pathGoal)
    elseif self.pitState == 2 then -- in the pitlane
        --print(self.tagText,"Going to pit lane",self.currentNode.id,self.goalNode.id,self.goalNode.pointType,self.speed)
        --self:updatePitNode()
        self.speedControl = 20
        -- Find location of Entrance node, if goalNode is past it
        local entranceNode = getKeyValue(self.pitChain,"pointType",2)
        if entranceNode == nil or entranceNode == false then
            print("No pit entry defineed")
            sm.log.warning("No Pit entry defined")
        end
        if self.currentNode['pointType'] == 2 or self.goalNode.pointType == 2 or self.goalNode.id >= entranceNode.id or self.currentNode.id >= entranceNode.id then -- move towards things
            --print(self.tagText,"Reached pit entrance")
            self.pitState = 3 
        end
        self:updatePitLaneSteering()         -- Steer towards pit nodes  -- need high follow priority
    elseif self.pitState == 3 then  -- on pit road
        if self.carRadar and self.carRadar.front and self.carRadar.front < 6 then
            self.speedControl = pitSpeedSlow
        else
            self.speedControl = pitSpeedLimit 
        end
        self:updatePitNode()
        if self.assignedBox ~= nil then
            local distance = getDistance(self.location,self.assignedBox.location)
            --print(self.tagText,"In Pit Lane",distance)
            if distance < 19 then
                --print(self.tagText,"steering towards box",distance)
                self.speedControl = 5
                self:updatePitBoxSteering() -- not sure what to do here
                if distance <= 4 then -- Gotta be a better way for this
                    --print(self.tagText,"setting in pit box",self.assignedBox.location,distance)
                    self.pitState = 4
                    self:placeCarInBox(self.assignedBox.location)
                    self.pitTimer:start(self.assignedBox.remaining)
                end
            else
                self:updatePitLaneSteering()         -- Steer towards pit nodes  -- need high follow priority
            end
        else
            self:updatePitLaneSteering()  
        end
    elseif self.pitState == 4 then -- Stopped in box
        self:placeCarInBox(self.assignedBox.location)
        self.strategicSteering = 0
        self.strategicThrottle = 0
        --print(self.tagText,"PitRemain",self.pitTimer:remaining())
        --self.speedControl = -1 -- this
        --self.strategicThrottle = -2
        self.assignedBox.remaining = self.pitTimer:remaining()
        if self.pitTimer:done() then
            print(self.tagText,"finished pit")
            self.speedControl = pitSpeedLimit
            -- wait for clear track
            if self:checkForClearPit(10) then
                self.strategicThrottle = 1
                self.pitState = 5 --pit manager sets this ??
            end
            self:execute_pit_strategy()
        end
        -- Resets Tire Wear and Fuel to appropriate strategy levels

    elseif self.pitState == 5 then -- leaving pit box
        self.pitOut = true
        self.pitIn = false
        --print(self.tagText,"Leaving Pit lane")
        if self.carRadar and self.carRadar.front and self.carRadar.front < 6 then
            self.speedControl = pitSpeedSlow
        else
            self.speedControl = pitSpeedLimit 
        end
        self:updatePitNode()
        self:updatePitLaneSteering()
        self.strategicThrottle = 1 -- needs to check for clear track first before setting throttle to 1
        --print(self.strategicSteering,self.strategicThrottle)
        if self.currentNode['pointType'] == 3 then -- Pit exit found
            --print(self.tagText,"Reached pit exit",self.speedControl)
            self.pitState = 6
        end 
    elseif self.pitState == 6 then -- leaving pit road to exit
        --print(self.tagText,"Leaving Pits")
        -- Cross lap crross
        self:handleLapCross()
        self:updatePitNode()
        self:updatePitLaneSteering()
        self.speedControl = 35
        self.strategicThrottle = 1
        if self.currentNode['pointType'] == 4 then -- Pit exit found
            --print(self.tagText,"Reached pit end",self.speedControl)
            self.pitState = 7
            self.currentNode = findClosestNode(self.nodeChain,self.location)
            self.goalNode = self:getNodeInDistance(25,self.nodeChain)
            self.speedControl = 0
            self.pitState = 0 -- reset back to race state
        end 
       
    elseif self.pitState == 7 then -- leaving pit road to exit
        print(self.tagText,"Left Pit Line")
        -- SHOULD NOT GET HERE
        self.speedControl = 0
        
    end

end

function Driver.calculateGoalDirOffset(self) -- calculates the offset in which the driver is not facing the curNode's outDir
    if self.goalDirection == nil or self.velocity:length() <= 0.2 then return 0 end
    local velocity = self.velocity:safeNormalize(self.velocity) -- Is necessary?
	--local angleMultiplier = 8 -- What is this for??
	--local goalVector = self.goalDirection -- This is a vector, (rename to goalVector?)
	local turnAngle = 0 
	--local directionalOffset = sm.vec3.dot(goalVector,velocity)
	--local directionalCross = sm.vec3.cross(goalVector,velocity)
    local dirAngle = (vectorAngleDiff(velocity,self.goalDirection) or 0) 
    --turnAngle = (directionalCross.z) * angleMultiplier -- NOTE: will return wrong when moving oposite of goalDir
    return dirAngle
end

-- segment work
function Driver.getSegmentEnd(self,segID) -- TODO: Make more efficient (dont need to look through all nodes, hah BINARY SEARCH DUH)
    local segNodeIndex = searchNodeSegment(self.nodeChain,segID)-- Made Effficient with Binary search: 431 worst case to 72 on SC
    for i=segNodeIndex, #self.nodeChain do local node = self.nodeChain[i]
        if node ~= nil then
            local nextNode =  getNextItem(self.nodeChain,i,1)
            if nextNode.segID == getNextIndex(self.totalSegments,segID,1) then
                return node -- returns node so we dont go into the wrong seg
            end
        end
    end   
end

function Driver.getSegmentBegin(self,segID) -- parameratize by passing in nodeChain
    local segNodeIndex = searchNodeSegment(self.nodeChain,segID)-- random index with segmentID
    for i=segNodeIndex, 1,-1 do local node = self.nodeChain[i] -- iterate backwards until first node found (reversed segEnd)
        if node ~= nil then
            local prevNode =  getNextItem(self.nodeChain,i,-1)
            if prevNode.segID == getNextIndex(self.totalSegments,segID,-1) then
                return node
            end
        end
    end 
    print("segBegin found no node...",segID,self.totalSegments)
end

function Driver.getSegmentLength(self,segID) --Returns a list of nodes that are in a segment, (could be out of order) (altered binary search??)
    local node = self:getSegmentBegin(segID)
    local foundSegment = false
    local finding = false
    local count = 1
    local index = 1
    local segTimeout = 0
    local timeoutLimit = 250
    while foundSegment == false do
        if segTimeout >= timeoutLimit then
            print(self.tagText,"getSeglength timoeut",segID)
            break
        end
        segTimeout = segTimeout + 1
        if node == nil then
            print("error getting segLen",index,segID,node)
            return count 
        end
        if node.segID == segID then
            count = count + 1
            --print("counting",count,node.segID)
            if not finding then
                --print("beginCount",segID,node.segID)
                finding = true
            end
        else 
            if finding then
                --print("finished finding segment",count)
                finding = false
                foundSegment = true
            end
        end
        node = getNextItem(self.nodeChain,node.id,1)
    end
   
    return count
end

function Driver.getSegAvgValue(self,nodeStartID,nodeEndID,value) --Returns average value for {value} within a set of nodes 
    local foundEnd = false
    local total = 0
    local count = 1
    local index = nodeStartID
    local segTimeout = 0
    local timeoutLimit = 100
    while foundEnd == false do -- TODO
        local node = self.nodeChain[index]
        if segTimeout >= timeoutLimit then
            print(self.tagText,"GetSegAvg timoeut",count,value,nodeStartID)
            break
        end
        segTimeout = segTimeout + 1
        if node == nil then
            print("error getting segAvg",count,value,nodeStartID)
            return count 
        end
        if node.id >= nodeEndID then 
            foundEnd = true
        end
        if node[value] == nil then
            print("not node attribute",value)
            break
        end
        local val = node[value]
       --print(self.tagText,"gotval",val,node[value],value,total)
        total = total + val
        count = count + 1
        node = getNextItem(self.nodeChain,node.id,1)
    end
    return total/count -- returns average (TODO: also have max/min)
end


function Driver.getSegMinMaxValue(self,nodeStartID,nodeEndID,value) --Returns Min and max value for {value} within a set of nodes  keyy
    local foundEnd = false
    local max = 0
    local min = 0
    local index = nodeStartID
    local segTimeout = 0
    local timeoutLimit = 150
    while foundEnd == false do -- TODO
        local node = self.nodeChain[index]
        if segTimeout >= timeoutLimit then
            --print(self.tagText,"GetSegMax timoeut",max,value,nodeStartID)
            break
        end
        segTimeout = segTimeout + 1
        if node == nil then
            --print("error getting segMax Node",max,value,nodeStartID)
            break
        end
        if node.id >= nodeEndID then 
            foundEnd = true
        end
        if node[value] == nil then
            print("SegMax: not node attribute",value)
            break
        end
        local val = node[value]
        --print(self.tagText,"gotval",max,val)
        max = math.max(max,val)
        min = math.min(min,val)
        node = getNextItem(self.nodeChain,node.id,1)
    end
    return min, max
end



-- function getPotential speed at Distance(speed,acceleration,distance)

-- METHOD1: 
--      if self.vMax Searching: looking ahead at (BrakeDistance?) until we find a segment with a vMax < current Speed (and potential speed at that distance)
        -- Create attribute: self.vMaxGoal (which will be a node from nodeChain)
        --  Once segment is found, self.vmaxSearching = false, self.vmaxGoal = node 
        -- function self:maintainVmax() will also use characteristics for variablitity/skill
        --     Get distance away from vMaxNode and brakeDistance/potential acceleration
        --      once car is brakingdistance-distance (+-skill/situation) away from vmaxNode,
        --         set Throttle to (+- skill/sit) engineMax Brake
        -- Once Car has passed over vmaxNode (or near), self.searching = true
        -- I can forsee a lot of problems with this method

-- MEthod2: The following code:
function Driver.getAccel2(self) -- updated version
    if self.goalNode == nil then
        return 0
    end
    if self.engine== nil then return 0 end
    if self.engine.engineStats == nil then return 0 end

    local segID = self.goalNode.segID
    local vMax = self:getVmax(self.goalNode) -- uses attributes to calculate current Vmax
    --print(vMax)
    if self.speedControl > 0 then
        vMax = self.speedControl
        --print("SC",self.speed,vMax)
        if self.speed > vMax then
            --print((vMax - self.speed)/10)
            return (vMax - self.speed)/10
        else 
            return 1
        end
    end
    
    --print(self.tagText,toVelocity(self.engine.engineStats.MAX_SPEED),self.speed)

    if self.speed < toVelocity(self.engine.engineStats.MAX_SPEED) and self.speed < toVelocity(vMax) then -- Only doing if not at engine limit and if slower than vmax
        return 1
    elseif self.drafting then
        
        return 1 -- full speed drafte
    else
       return 1- math.abs(vMax/toEngineSpeed(self.speed))
    end
end

   

function Driver.getBraking2(self) -- Looks at current spot and slowest spot in future
    if self.engine == nil then return 1 end -- dont move
    if self.engine.engineStats == nil then return 0 end
    if self.currentNode == nil then return 0 end
    if not self:valididtyCheck() then return 1 end
    local lookAheadConst = 4 -- play around until perfect, possibly make dynamic for downforce/other factors?
    local lookAheadHeur = 1.8 -- same Can reduce this to reduce calculations
    local maxLookaheadDist = lookAheadConst + (self.speed)*lookAheadHeur
    local currentNode = self.currentNode
 
     
    local curVmax = self:getVmax(currentNode) -- REMOVED handicap speed boost due to issues.
    local futureNode,futureSpeed = self:getFutureVMax(maxLookaheadDist,currentNode) -- Finds node closest with speed < than current speed and determines max velocity
    --print("spd",self.speed)
    --print("cvm:",toVelocity(curVmax))
    --print('fvm:',toVelocity(futureSpeed))
    --print()
    -- Adjust for drafting and passing
    local draftAdjust = 0.5
    if self.drafting then
        draftAdjust = draftAdjust + 2
    end
    if self.passing.isPassing then
        draftAdjust = draftAdjust + 1.5
    end

    if futureNode == nil then end -- print("no future node found??")
    if futureSpeed == nil then end -- print("no future speed found?")
    if self.speed > toVelocity(curVmax) + draftAdjust then -- stay within currentParams
        --self:debugOutput(-1,{"Current Braking:",toVelocity(curVmax),self.speed})
        return 1
    end

    local distToNode = getDistance(self.location,futureNode.mid)
    local brakeDist = self:getBrakingDistance(futureSpeed + draftAdjust)
    --print(currentNode.id,futureNode.id,futureSpeed,brakeDist,distToNode)
    if brakeDist > distToNode then -- If needs to slow down for future refference:
        --self:debugOutput(-1,{"Future Braking:",toVelocity(futureSpeed),self.speed})
        return 1
    else
        return 0
    end
    return 0 -- nothing here to brake for?
        
end


function Driver.updateStrategicThrottle(self)
    if self.stuck then return end
    -- If self.drivingMode == 1 then -- use braking1, if 2 then use braking2
    -- Calculate Vmax here and pass through
    
    local accel = 0
    local braking = 0

    if self.behaviorSwitch == 0 then
        braking = self:getBraking() -- self:getCollissionBraking
    elseif self.behaviorSwitch == 1 then
        braking = self:getBraking2()
    end

    if braking == 0 then -- No braking needed, now check acceleration
        if self.behaviorSwitch == 0 then
            accel = self:getAccel()
        elseif self.behaviorSwitch == 1 then
            accel = self:getAccel2()
        end
    else
        accel = 0 -- IF braking, no acceleration desired
    end
    --print('ac',accel,braking,self.speed,self.drafting)
    self.strategicThrottle = accel - braking + self.colThrottleAdjust -- Adjusts to emergency collision throttle control too
    --print(self.tagText,"throt",self.strategicThrottle,self.throttle,accel,braking,self.engine.curRPM,self.speed)
end
 
-- Gearing
function Driver.updateGearing(self) -- try to calculate the best gear to choose at the time and shift as well
    if self.engine == nil then return 1 end
    if self.engine.engineStats == nil then return 1 end
    local rpm = self.engine.curRPM
    local vrpm = self.engine.VRPM
    local revLimit = self.engine.engineStats.REV_LIMIT
    local nextGear = self.curGear
    local highestGear = #self.engine.engineStats.GEARING
    --print("highest gear",highestGear)
    if not self.userControl then
        if self.engine == nil or self.stuck then 
            if self.rejoining and self.speed > 9 then -- Update gears while rejoining but not when not stuck?
                --print("hello")
            else
                --print("return nil")
                return 
            end
        end -- cant shift gears with no engine

        if self.speed ~= nil then
            if self.speed < 5 then
                if self.curGear >= 2 then
                    nextGear = 1
                end
            end
        end

        if self.racing or self.experiment then -- If race status is clear then go full speed
            if self.strategicThrottle >= 0.5 then -- If supposed to accelerate full speed/half?
                if self.curGear <= 0 then 
                    nextGear = 1 -- If you are neutral then at least go to first gear
                    -- Possibly have rejoin/race start flag trigger?
                else
                    if revLimit - vrpm < self.upShiftThreshold then 
                        if self.curGear < highestGear then -- Gearing limit, make variable?
                            nextGear = self.curGear + 1
                        end
                    end
                    if vrpm == 0 and self.curGear >1 then -- Downshift dude <= 0, negativeRPM?
                        nextGear = self.curGear -1
                    end
                end
            else -- If car is "coasting" or braking , check downshifting
                if vrpm < self.downShiftThreshold then -- How low vrpm should be before shifting down (fuel saving?)
                    if self.curGear > 1 then
                        nextGear = self.curGear - 1 
                    end
                end
            end
        end

        if nextGear ~= self.curGear then 
            self:shiftGear(nextGear)
        end

    else -- user is controling, TODO: Make manual option
        if self.speed ~= nil then
            if self.speed < 6 then
                if self.curGear >= 2 then
                    nextGear = 1
                end
            end
        end

        if self.userPower > 0 then -- If user on gas or coasting
            if self.curGear <= 0 then 
                nextGear = 1 -- If you are neutral then at least go to first gear
            else
                if revLimit - vrpm < self.upShiftThreshold then 
                    if self.curGear < highestGear then -- Gearing limit, make variable?
                        nextGear = self.curGear + 1
                    end
                end
                if vrpm == 0 and self.curGear >1 then -- Downshift dude <= 0, negativeRPM?
                    nextGear = self.curGear -1
                end
            end
        else -- If car is braking , check downshifting
            if vrpm < self.downShiftThreshold then -- How low vrpm should be before shifting down (fuel saving?)
                if self.curGear > 1 then
                    nextGear = self.curGear - 1 
                end
            end
            if self.speed < 2 and self.userPower == -1 then -- flip into reverse
                --print(self.tagText,"reverse",nextGear,self.curGear)
                nextGear = -1
            end
        end

        if nextGear ~= self.curGear then 
            self:shiftGear(nextGear)
        end
    end

end 

function getCollisionAvoidanceSteer(vhDif)
    local newSteer = 0
    if vhDif['vertical'] < 0 and vhDif['vertical'] > -10 then -- if intersection is behind midpoint of car
        if vhDif['horizontal'] > 0 then -- car is on right
            newSteer = ratioConversion(-6,2,-0.22,0,vhDif['horizontal'])--/(self.followStrength/1.5)   --TODO: figure out if getting passed/attack/defend?
        else -- brake
            --newSteer = ratioConversion(6,-2,0.22,0,vhDif['horizontal'])
        end
    else -- if intersection is in front possibly make it turn less hard?
        if vhDif['horizontal'] > 0 then -- car is on right
            newSteer = ratioConversion(-6,2,-0.12,0,vhDif['horizontal'])--/(self.followStrength/1.5)   --TODO: figure out if getting passed/attack/defend?
        else -- slowdown
            --newSteer = ratioConversion(6,-2,0.12,0,vhDif['horizontal'])
        end
    end
    return newSteer
end

function calculateCollisionMove(pointName,vhDif,opponent) -- move to global?
    local accel = 0
    local steer = 0
    -- if corner is frontleft 
    if pointName == "fl" then
        --print("fl",vhDif)
        if vhDif['vertical'] < 0 and vhDif['vertical'] > -10 then -- if point behind midpoint of car
            if vhDif['horizontal'] > 0 then -- car is on right side of midpoint
                newSteer = ratioConversion(0,5,0.2,0,vhDif['horizontal']) -- should turn sharper the closer to 0
                print("Steer avoidance right",vhDif['horizontal'],newSteer)
                --steer  = getCollisionAvoidanceSteer(vhDif)
            end
        end
        --print("Got steer FL",vhDif,steer)
    elseif pointName == "fr" then
        --print("fr",vhDif)
        if vhDif['vertical'] < 0 and vhDif['vertical'] > -10 then -- if point behind midpoint of car
            if vhDif['horizontal'] < 0 then -- car is on right side of midpoint
                newSteer = ratioConversion(-5,0,0,0.2,vhDif['horizontal']) -- should turn sharper the closer to 0
                print("Steer avoidance left",vhDif['horizontal'],newSteer)
                --steer  = getCollisionAvoidanceSteer(vhDif)
            end
        end

    elseif pointName == "bl" then -- dont need to do much
    elseif pointName == "br" then -- also not important
    end


    return accel,steer
end


function Driver.newUpdateCollisionLayer(self)-- -- New updated collision layer
    -- Not done yet
    if self.carData == nil then return end -- not scanned
    --print(self.carData.carDimensions)
    if self.carData.carDimensions == nil then return end -- not scanned
    if self.engine == nil then return end
    if self.engine.engineStats == nil then return end -- Do validattion instead?

    local colThrottle = self.strategicThrottle
    local colSteer = self.strategicSteering
    local passSteer = 0 -- add on to colSteer
    local oppInRange = {}--self.opponentFlags -- possibly attatch to self so no regeneration necessary?
    local selfWidth = self.leftColDist + self.rightColDist
    local hasDraft = false
    local carsInRange = getDriversInDistance(self,60) -- also accounts for draft may be too 
    
    local timeScaleMultiplier = 0.5 -- ~1 second lookahead (adjustable) (40 iterations per second)
    local collisionPadding = 2 -- additional space  multiplier given to radar/collision > 1 for grow, < 1 for shrink
    local futurePosition = self.location + (self.velocity * timeScaleMultiplier) -- get future location
    self.futureLocation = futurePosition
    --print("future",self.location,self.velocity,futurePosition)
    local selfCollisionBox = generateBounds(futurePosition,self.carDimensions,self.shape:getAt(),self.shape:getRight(),collisionPadding)
    -- make effect for debug
    --print(self.fflEffect)
    self.fflEffect.pos = selfCollisionBox[1].position
    self.ffrEffect.pos = selfCollisionBox[2].position
    self.fblEffect.pos = selfCollisionBox[3].position
    self.fbrEffect.pos = selfCollisionBox[4].position

    local centerLocation = getCarCenter(self) -- returns center of car

    if carsInRange == nil then -- No cars go home
        if self.passing.isPassing then
            self:cancelPass("no cars in range")
        end
        if self.drafting then
            self.drafting = false
        end
        return 
    end
    
    for k=1, #carsInRange do local opponent=carsInRange[k] -- May need to have deep copy of carsInrange or create new class
        if opponent.carDimensions == nil then
            --self:sv_sendAlert("Car ".. self.id .. " Not Scanned; Place on Lift")
            break
        end
        local opDir = opponent.shape:getAt()
        local opFuturePos = opponent.location + (opponent.velocity * timeScaleMultiplier)
        local opCollisionBox = generateBounds(opFuturePos,opponent.carDimensions,opDir,opponent.shape:getRight(),collisionPadding)
        local centerLocation = getCarCenter(self) -- returns center of car
        local collisionPotential = getCollisionPotential(selfCollisionBox,opCollisionBox)
        if collisionPotential == false then 
            break -- no collision potential
        else
            local intersectPoint = selfCollisionBox[collisionPotential]
            local intersectVH = getPointRelativeLoc(centerLocation,intersectPoint['position'],opDir)
            --print(self.id,collisionPotential,intersectPoint['name'],intersectVH)
            local accel,steer = calculateCollisionMove(intersectPoint['name'],intersectVH,opponent) -- dont need opponent
            --print(self.tagText,"Got",accel,steer, "to avoid car")
        end

    end
    --self.strategicThrottle = colThrottle
    --self.strategicSteering = self.strategicSteering + colSteer + passSteer
    
end


function Driver.processDrafting(self,oppDict)
  
    local canDraft = false
    local draftLane = 0
    if not self.raceControlError then
        if getRaceControl().draftingEnabled == false then
            return canDraft,draftLane 
        end
    end
    if self.pitState ~= 0 then
        return canDraft,draftLane
    end
    if (self.caution or self.formation) then -- deny draft due to caution and what not
        self.drafting = false
        canDraft = false
        return canDraft,draftLane
    end

    if self.goalNode == nil then return canDraft,draftLane end
    if self.currentNode == nil then return canDraft,draftLane end
    --print(self.tagText,"PD",self.carRadar)
    if self.carRadar.front and (self.carRadar.front < 70 and self.carRadar.front > 1) then
        if (self.carRadar.right and self.carRadar.right <0.1) or (self.carRadar.left and self.carRadar.left > -0.1) then 
            --print(self.tagText,"Radar has car in draft zone LR")
            canDraft = true --TODO: redo this to only set flag for drafting logic func
        else
            --print(self.tagText,"Radar has car no draft zone LR",self.carRadar)
            canDraft = false
        end
    else
        canDraft = false
        --return canDraft,draftLane
    end
    -- TODO: Determine draft lane if canDraft is false

    -- GEt all opponents in front of self
    -- Find opponent closest in front (within 10?) of drafting range and not moving too slow
    -- Get track position of closest opp
    -- If self is already within LR vhDist (overlap) then do nothing and return canDraft
    -- If not, get TrackPos (bias) of opp and return desired trackPos(bias) and false
    -- In Main, set TrackBias to draftLane
    -- set self.drafting to result
    local fastestOppSpeed = 0
    local fastestOppPos = 0
    local fastestOpp = nil

    --print(self.tagText,"oppd")
    for opponentID, opponentData in pairs(oppDict) do
        --print(self.tagText,"Pre Draft check",opponentData.vhDist)
        local oppFlags = opponentData.flags
        if opponentData == nil or opponentData.vhDist == nil or opponentData.data.speed == nil then
            --print("nil something",opponentData.data.speed)
            break 
        end-- TODO: instead of using vhDist, use segment/nodeDistance
        if opponentData.vhDist.vertical < 50 and opponentData.vhDist.vertical > 10 and math.abs(opponentData.vhDist.horizontal) < self.currentNode.width  then -- In draft range?
            --print(self.tagText,"Draft check",opponentData.vhDist)
            if opponentData.data.speed > fastestOppSpeed and opponentData.data.goalNode and --self.goalNode.segType == "Straight" and 
            opponentData.data.goalNode.segID == self.goalNode.segID then -- found faster opp
                fastestOppSpeed =  opponentData.data.speed
                fastestOppPos = opponentData.vhDist.horizontal
                fastestOpp = opponentID
                --print(self.tagText,"found op to follow",fastestOpp,fastestOppPos,opponentData.vhDist.horizontal)
            else
                fastestOpp = nil -- set nil
            end
            -- TODO: make margin based on car wdith
            if opponentData.vhDist.horizontal and (opponentData.vhDist.horizontal < 3 and opponentData.vhDist.horizontal > -3) and not self.raceFinished then -- If overlapping (a little margin)
                oppFlags.drafting = true
                canDraft = true
                --print(self.tagText,"hasDraft",opponentData.vhDist)
            else
                --print(self.tagText,"no draft",opponentData.vhDist)
                oppFlags.drafting = false
                canDraft = false
            end
                 
        end
    end

    if fastestOpp ~= nil then -- after fastest opponent found: try to follow
        --print(self.tagText,"FastestOppLane",fastestOppPos,self.trackPosition)
        draftLane = fastestOppPos
    else
        draftLane = 0
    end

    return canDraft, draftLane
end

function Driver.processOppFlags(self,opponent,oppDict,colDict,colSteer,colThrottle)  -- Returns steering angle and throttle based on flags
    local oppFlags = oppDict[opponent.id].flags
    local frontCol = colDict.frontCol
    local rearCol = colDict.rearCol
    local leftCol = colDict.leftCol
    local rightCol = colDict.rightCol
    local colSteerL = 0 -- Left colsteer
    local colSteerR = 0 -- Right colsteer
    -- TODO: Determine if to do draft offset? track bias offset? pass offset?
    if oppFlags.frontWatch and not oppFlags.pass then -- If car is in front but not too close, 
        if (self.speed - opponent.speed > 4 or opponent.speed < 10) and (not self.caution and not self.formation) then
            --print(self.tagText,"Approaching front fast",self.speed - opponent.speed)
            -- start moving over slightly for preemptive avoidance
            local passDir = self:checkPassingSpace(opponent)
            if passDir ~= 0 then -- Start moving in that direction
                if self.goalNode then 
                    local futureGoal = getNextItem(self.nodeChain,self.goalNode.id,4)
                    local goalVmax = self:getVmax(opponent.currentNode)
                    if toVelocity(goalVmax) > opponent.speed + 3 + ((self.handicap or 10)/50) then
                        self.trackPosBias = self.goalNode.width/3 * passDir -- Need to get passing position not just space
                        --print(self.tagText,"fronWatch move",opponent.tagText,self.speed,opponent.speed,toVelocity(goalVmax))
                    end
                end
            else
                if not self.caution and not self.formation then 
                    --print(self.tagText,"Early Warning emergency brake",colThrottle)
                    colThrottle = rampToGoal(-1,colThrottle,0.002)
                end
            end
        end
    else
        --self.trackPosBias = 0 -- turn it off??
    end
    
    if oppFlags.frontWarning and not oppFlags.pass then -- If car is in front and getting closer (and not already passing)
        if (self.speed - opponent.speed > 3 or opponent.speed < 12) and (not self.caution and not self.formation) then
            --print(self.tagText,"Warning front fast",self.speed - opponent.speed)
            -- start moving over slightly for preemptive avoidance
            local passDir = self:checkPassingSpace(opponent)
            if passDir ~= 0 then -- Start moving in that direction
                if self.goalNode then 
                    local futureGoal = getNextItem(self.nodeChain,self.goalNode.id,4)
                    local goalVmax = self:getVmax(opponent.currentNode)
                    if toVelocity(goalVmax) > opponent.speed + 3 + ((self.handicap or 10)/40) then
                        self.trackPosBias = self.goalNode.width/2.8 * passDir -- Need to get passing position not just space
                        --print(self.tagText,"fronWarning move",self.handicap,opponent.handicap,opponent.tagText,self.speed,opponent.speed,toVelocity(goalVmax))
                    end
                end
            else
                if not self.caution and not self.formation then 
                    --print(self.tagText,"Mid Warning emergency brake",colThrottle)
                    colThrottle = rampToGoal(-2,colThrottle,0.002 - self.skillLevel/1000)
                end
            end
        end
    else
        --self.trackPosBias = 0 -- turn it off??
    end

    if oppFlags.frontEmergency and not oppFlags.alongSide and not oppFlags.pass then -- If front emergency and opponent is not alongside and not already passing
        if self.caution or self.formation then 
            colThrottle = rampToGoal(-0.6,colThrottle,0.08)
        else
             --print("front emer while no pass")
             colThrottle = rampToGoal(-1,colThrottle,0.002)
        end
        --print(self.tagText,"Close  Emergency Brake!!!",opponent.tagText,colThrottle,self.strategicThrottle)
    elseif oppFlags.pass and oppFlags.frontEmergency then-- If passing 
        --print(self.tagText,"close emergency pass cancel",opponent.tagText)
        if self.caution or self.formation then 
            colThrottle = rampToGoal(1,colThrottle,0.001) 
        else
            colThrottle = rampToGoal(-1,colThrottle,0.005) 
        end
        -- OR TODO: Maybe determine aggressive ness to decide what to do?
        --self:cancelPass() -- TODO: Determine how useful this is
    end

    if oppFlags.leftWarning and leftCol ~= nil then -- If oponent is  on the left
        colSteer = colSteer + ratioConversion(-9,1,-0.19,0,leftCol) -- Adjust according to distance
        if self.carAlongSide.right ~= 0 then -- reduce adjustment if there is a car on the otherside
            colSteer = colSteer/2 -- TODO: use a ratio conversion for this too
        end
        colSteerL = colSteer
        --print(self.tagText,"leftWarn",opponent.tagText,leftCol,colSteer)

    end
    if oppFlags.rightWarning and rightCol ~= nil then -- if opponent is on the right
        colSteer = colSteer + ratioConversion(9,-1,0.19,0,rightCol) -- adjust according to distance
        if self.carAlongSide.left ~= 0 then
            colSteer = colSteer/2
        end
        colSteerR = colSteer
        --print(self.tagText,"rightwarn",opponent.tagText,rightCol,colSteer)

    end

    if oppFlags.leftEmergency then -- if opponent is too close
        colSteerL = colSteerL +ratioConversion(-2,1.5,-0.15,0,leftCol)
        --print(self.tagText,"leftE",opponent.tagText,colSteerL,leftCol)
    end
    if oppFlags.rightEmergency then -- if opponent is too close
        colSteerR = colSteerR +ratioConversion(2,-1.5,0.15,0,rightCol) -- Adjust according to distance
        --print(self.tagText,"rightE",opponent.tagText,colSteerR,rightCol)
    end
   

    --[[if self.passing.isPassing then TODO: Determine if this is necessary, passing reduces collisoin avoidance steering
        colSteer = colSteer/1.4 
    else
        colSteer = colSteer/1.1
    end]]
    if colSteerR ~= 0 or colSteerL ~= 0 then -- if any collision avoidance
        -- Goal here is to dampen collision avoidance when on banks
        -- TODO: Do this for turns too??
        local bankAdjust = 0
        local dampMult = 1.3 -- Higher the number, the less the cars adjust
        if self.currentNode and self.currentNode.bank ~= nil and self.currentNode.bank ~= 0 then 
            if getSign(self.currentNode.bank) == -1 and  colSteerR ~= 0 then -- If avoiding to left on left banked turn
                dampMult = 0.9
                colSteerR = colSteerR/(1+dampMult*math.abs(self.currentNode.bank))
            end
            
            if getSign(self.currentNode.bank) == 1 and  colSteerL ~= 0 then -- If avoiding to Right on right banked turn
                dampMult = 0.9
                colSteerL = colSteerL/(1+dampMult*math.abs(self.currentNode.bank))
            end

            if getSign(self.currentNode.bank) == 1 and  colSteerR ~= 0 then -- If avoiding to left on right banked turn
                dampMult = dampMult + 1 -- reduce reduction because traveling 'up'
                colSteerR = colSteerR/(1+(dampMult*math.abs(self.currentNode.bank)))
            end
            
            if getSign(self.currentNode.bank) == -1 and  colSteerL ~= 0 then -- If avoiding to Right on left banked turn
                dampMult = dampMult + 1
                colSteerL = colSteerL/(1+(dampMult*math.abs(self.currentNode.bank)))
            end
        else
            if self.currentNode and getSegTurn(self.currentNode.segType) ~= 0 then  -- on not banked tracks but regular turns
                local turnType = getSegTurn(self.currentNode.segType)
                dampMult = 0.01 -- slightly less pronounced
                if turnType <= -2 and  colSteerR ~= 0 then -- If avoiding to left on left turn (only medium and sharper, use -1 for fast left)
                    colSteerR = colSteerR/(1+dampMult)
                end
                
                if turnType >= 2 and  colSteerL ~= 0 then -- If avoiding to Right on right  turn
                    colSteerL = colSteerL/(1+dampMult)
                end

                if turnType >= 2 and  colSteerR ~= 0 then -- If avoiding to left on right  turn
                    dampMult = dampMult + 0.01 -- reduce reduction because traveling against turn
                    colSteerR = colSteerR/(1+(dampMult))
                end
                
                if turnType <= -2 and  colSteerL ~= 0 then -- If avoiding to Right on left  turn
                    dampMult =  dampMult + 0.01
                    colSteerL = colSteerL/(1+(dampMult))
                end
            else -- Do something about straights based on futur turn??

            end
        end

    end
    return colSteerL,colSteerR,colThrottle
end

function Driver.processPassingDetection(self,opponent,oppDict)
    -- Real Passing ALGo

    if self.caution or self.formation then
        if self.passing.isPassing then
            self:cancelPass()
        end
        return 
    end

    local oppData =  oppDict[opponent.id]
    local oppFlags = oppData.flags
    local vhDist = oppData.vhDist
    local catchDist = self.speed * vhDist['vertical']/(self.speed-opponent.speed) -- vertical dist *should* be positive and
    local brakeDist = getBrakingDistance(self.speed*2,self.mass,self.engine.engineStats.MAX_BRAKE/2,opponent.speed) -- dampening? make variable
    local oppSpeed = opponent.speed 
    local speedDif = self.speed - oppSpeed 
    local collisionDist = vhDist['vertical'] - (self.frontColDist + opponent.rearColDist) 
    self.passDistance = 17 +  (speedDif*1.8) -- increase multiplier to increase pass speed distance

    if self.passing.isPassing and self.passing.carID == opponent.id then -- only check if car matches
        if oppFlags ~= nil then
            --local passCarData = self.opponentFlags[self.passing.carID] -- data that the car 
            if collisionDist > self.passDistance or vhDist['vertical'] < 0 then -- If too far or already past
                if oppFlags.pass then
                    oppFlags.pass = false
                    self:cancelPass(" vhertical too close or far")
                else
                    self:cancelPass(" random cancel pass anyways no opp pass")
                end
            end
        else -- oppData is nil
            self:cancelPass("op data nil cancel??")
        end
    end
    -- Increase pass distance based on speed dif

    if collisionDist >=0  and collisionDist < self.passDistance then -- if opponent is somewhat close in front
        --print(self.tagText,"check pass?",self.speed-opponent.speed, self.carRadar.front,vhDist,math.abs(vhDist['horizontal']) <= self.goalNode.width )
        if speedDif > 0.2 then -- If self is approaching apponent
            if not oppFlags.pass and not self.passing.isPassing then  -- If not currently passing the opp
                if collisionDist <= self.carRadar.front and math.abs(vhDist['horizontal']) <= self.goalNode.width*1.8 then -- If this car is the closest front car according to local radar
                    --print(self.tagText,"determinen pass Location")
                    local passDirection = self:checkPassingSpace(opponent) -- Check for space to pass
                    if passDirection ~= 0 then -- If theres a direction to pass, assign self the pass and commit to it
                        --print(self.tagText,"canpass",passDirection)
                        self.passCommit = passDirection
                        self.passGoalOffsetStrength = self:calculatePassOffset(oppData,passDirection) -- Calculate lateral movement to pass 
                        if (self.carRadar.front - (collisionDist) ~= 0) then -- Uselsess double check TODO: DEPRECIATE/'REMOVE'
                            print(self.tagText,"not closest racer to pass",self.carRadar.front - (collisionDist))
                        end
                        -- TODO: Wrap this up into a beginPass(opponent.id,passDirection)
                        
                        --print(self.tagText,"starting pass",opponent.tagText,collisionDist,vhDist)
                        
                        self.passing.isPassing = true
                        self.passing.carID = opponent.id
                        oppFlags.pass = true -- Maybe make passing function?
                        --print(self.tagText,"SET Passing",opponent.tagText,self.passGoalOffsetStrength,self.passCommit,self.passFollowPriority)
                    else -- No space to pass, cancel pass (Could go wrong if another car comes in and forces complete cancel, maybe only partial?)
                        --print(self.tagText," no pass dir cancel")
                        oppFlags.pass = false
                        self:cancelPass("No pass dir cancel")
                    end
                end -- else: the car is not the closest
            else -- If already passing 
                local space = self:confirmPassingSpace(opponent,self.passCommit) -- Make sure Passing point is still viable
                --print(self.tagText,space,self.passCommit,oppFlags.pass,self.passing.isPassing)
                if collisionDist > self.passDistance or vhDist.vertical < 0 then -- Either too far or already passed?
                    if oppFlags.pass then -- This is the proper person to pass
                        --print("cancled pass due to ",collisionDist, "being greater than",self.passDistance)
                        oppFlags.pass = false
                        self:cancelPass(" alreadypassing vertical too far")
                    else
                        --print(self.tagText,"vhdist cancel",vhDist.vertical)
                        if self.passing.isPassing then -- If another person is ther
                            --print("alreadypassing")
                            --self:cancelPass()
                        end
                    end
                end
                if space ~= self.passCommit then -- If the optimal space has changed since initial pass
                    --print(self.tagText,"pass commit changed",vhDist)
                    if vhDist.vertical > 10 then -- If far enough away, cancel the pass
                        oppFlags.pass = false
                        --print(self.tagText,"PC change Too far cancel")
                        self:cancelPass("passcommit change while vertical too far")
                    else -- Too close to cancel?
                        --print(self.tagText,"too close to change?",vhDist.horizontal,vhDist.vertical) -- either keep going or slow down depending on next turn?
                        if vhDist.horizontal > -1 or vhDist.horizontal < 1 then -- If directly behind the car (blocked off)
                            if (self.carAlongSide.left ~= 0 and self.carAlongSide.right ~= 0) then -- If there are cars left and rightt
                                oppFlags.pass = false
                                self:cancelPass("cars alongside pass cancel while too close")
                                --print(self.tagText," car alongside cancel")
                            else -- Continue pass
                                --self:cancelPass()
                                --print(self.tagText,"cahrgeAhead")
                            end
                        end
                    end
                else -- If the space is the same; contineu to pass!
                    --print(self.tagText,'Continueing pass',self.passCommit,vhDist)
                    self.passGoalOffsetStrength = self:calculatePassOffset(oppData,self.passCommit)
                end
            end
        else -- If not actually approaching this opponent
            if oppFlags.pass and self.passing.isPassing and speedDif <= -0.12 then
                oppFlags.pass = false
                --self:cancelPass("losing ground")
            else -- Cancel pass anyways? TODO: can probably remove this
                --print(self.tagText,"cautious continue")
            end
        end
    else-- If car is somewhat further away Keep eye on car, check speed dif c
        local goalVmax = self:getVmax(opponent.currentNode)
        if toVelocity(goalVmax) > opponent.speed + 2 and collisionDist > -1 then --If approaching car rather quickly
            local passDirection = self:calculateClosestPassPoint(opponent)
            if self.racing then
                if passDirection ~= 0 then -- This is an emergency pass, execute if possible
                    self.passCommit = passDirection
                    self.passGoalOffsetStrength = self:calculatePassOffset(oppData,passDirection)
                    --print(self.tagText,"Emergency pass",opponent.tagText, self.passCommit,self.speed,opponent.speed,vhDist)
                    self.passing.isPassing = true
                    self.passing.carID = opponent.id
                    oppFlags.pass = true
                else -- If nowhere to go
                    --print(self.tagText," warning Uncertainty???")
                end
            end 
        end
    end
end

function Driver.setOppFlags(self,opponent,oppDict,colDict)
    -- Unpack Vars
    if opponent == nil or oppDict == nil or colDict == nil then 
        print("Bad Params",#opponent,#oppDict,#colDict)
        return oppDict
    end
    -- Unpack dicts
    local oppFlags = oppDict[opponent.id].flags
    local frontCol = colDict.frontCol
    local rearCol = colDict.rearCol
    local leftCol = colDict.leftCol
    local rightCol = colDict.rightCol
    local vhDist = oppDict[opponent.id].vhDist
    
    --print(self.tagText,frontCol,leftCol,rightCol,rearCol)

    --TODO: chagne to oponend width along with 5 padding?
    if frontCol and frontCol < 50 and frontCol > 20 then -- somewhat close
        if self.speed - opponent.speed  > 0.5 then -- moving 1 faster ?
            if (rightCol and rightCol <=6) or (leftCol and leftCol >= -6) then -- If overlapping
                oppFlags.frontWatch = true
            else
                oppFlags.frontWatch = false
            end
        else
            oppFlags.frontWatch = false -- good idea??
        end
    else
        oppFlags.frontWatch = false
    end
    --print(frontCol)

    if frontCol and frontCol <= 20 and frontCol > 3 then -- if close but not overlapping
        if self.speed - opponent.speed > 0 then -- if approaching 
            if (rightCol and rightCol <5) or (leftCol and leftCol > -5) then -- If overlapping, Makke separate flag?
                local catchTime = frontCol/(self.speed - opponent.speed) --TODO: FIgure this out a better way
                local brakeDist = self:getBrakingDistance(opponent.speed-3) -- dampening? make variable
                --print(self.tagText,"catchTime",self.speed - opponent.speed) --TODO: Check this??
                if self.speed - opponent.speed > 1 then -- and greater than 0?
                    oppFlags.frontWarning = true -- check for passing
                else
                    oppFlags.frontWarning = false
                end
            else
                oppFlags.frontWarning = false
            end
        else
            oppFlags.frontWarning = false
        end
    else
        oppFlags.frontWarning = false
    end
    
    if frontCol and (frontCol <= 3 and frontCol > -3)  then -- if car is slightly overlapping but not directly alongside
        if (rightCol and rightCol <0.1) or (leftCol and leftCol > -0.1) then -- If really close but not alongside
            if not oppFlags.frontEmergency then
                --print(self.tagText,"FrontEmerg",frontCol,leftCol,rightCol)
                oppFlags.frontEmergency = true
            end
        else
            if oppFlags.frontEmergency then -- toggle off
                --print(self.tagText,"Not intersecting Emergency cancel",frontCol,leftCol,rightCol)
                oppFlags.frontEmergency = false
            end
        end
    else
        if oppFlags.frontEmergency then -- toggle off
            --print(self.tagText,"Ahead/Behind emergency cancel",frontCol,leftCol,rightCol)
            oppFlags.frontEmergency = false
        end
    end

    if frontCol and frontCol < 0.5 then
        if (rightCol and rightCol <0.5) or (leftCol and leftCol > -0.5) then
            --print(self.tagText,"stop?",rightCol,leftCol,frontCol)
            -- Do raycast forwards
        end
    end

    if rearCol then
        local center = self.shape.worldPosition 
        local scanStartPos = center -  self.shape.at*self.carDimensions['rear']:length()
        local behindDist = self.rearColDist
        if (rightCol and rightCol <0.5) or (leftCol and leftCol > -0.5) then
            if rearCol > -0.5 then -- Double checks for cars close behind -- TODO: turn this into a flag
                local backCastTable = sm.physics.multicast(self:generateBackCastTable())
                if fullTableMatch(backCastTable,1,false) then
                else
                    if self.strategicThrottle < 0.9 then
                        self.strategicThrottle = 0.9
                        --print(self.tagText,"carbackCloseAdj")
                    end
                end            
            end
        end
        if rearCol < -2 then
            if oppFlags.pass then
                --print(self.tagText,"Pass complete")
                if self.passing.isPassing then
                    oppFlags.pass = false
                    --self:cancelPass(" RearCol finish ")
                else
                    --print("unmatched pass???")
                end
                oppFlags.pass = false
            end
        end
    end

    -- Side by side flags
    -- TODO: Check if on "wong side of desired pass car, cancel pass"
    if (frontCol and frontCol <= 1.6) or (rearCol and rearCol >=0.7) then -- if car really close
        --print(self.tagText,leftCol,rightCol,opponent.tagText)
        if (leftCol and leftCol <= 0.09) or (rightCol and rightCol >= -0.09) then
            oppFlags.alongSide = true
        else
            oppFlags.alongSide = false
        end

        if (leftCol and leftCol >= -9) then
            oppFlags.leftWarning = true
        else
            oppFlags.leftWarning = false
        end

        if (rightCol and rightCol <= 9) then
            oppFlags.rightWarning = true
        else
            oppFlags.rightWarning = false
        end

        if (leftCol and leftCol >=-2) then
            oppFlags.leftEmergency = true
         else
            oppFlags.leftEmergency = false
        end

        if (rightCol and rightCol <= 2) then
            oppFlags.rightEmergency = true
         else
            oppFlags.rightEmergency = false
         end
   


    else -- no warnings here
        oppFlags.rightWarning = false
        oppFlags.leftWarning = false
        oppFlags.rightEmergency = false
        oppFlags.leftEmergency = false
        oppFlags.alongSide = false -- ?
    end

    -- todo: finish this
    local center = self.shape.worldPosition -- off center really
    local centerLocation = getCarCenter(self)
    local centerStart = centerLocation + self.shape.at * (self.carDimensions['front']:length()*1.1)
    local centerEnd = centerStart -  self.shape.at * (self.carDimensions['rear']:length()*0.4)
    
    local leftStart = center -  self.shape.right*-self.carDimensions['left']:length()  +  self.shape.at * (self.carDimensions['front']:length()*1.1)
    local leftEnd = leftStart - self.shape.right * -(self.carDimensions['front']:length()*0.4)
    
    local leftStart = center -  self.shape.right*-self.carDimensions['left']:length()  +  self.shape.at * (self.carDimensions['front']:length()*1.1)
    local leftEnd = leftStart - self.shape.right * -(self.carDimensions['front']:length()*0.4)
    
    self.leftDetect = true
    self.rightDetect = true
   
    return oppDict 
end

function Driver.generateOpponent(self,opponent,oppDict)
    local vhDist = getDriverHVDistances(self,opponent)
    local oppWidth
    if opponent.leftColDist == nil or opponent.rightColDist == nil then
        oppWidth = selfWidth
    else 
        oppWidth = (opponent.leftColDist + opponent.rightColDist) or selfWidth -- in case oppwidth is broken
    end
    if vhDist['vertical'] < 70 and vhDist['vertical'] > -15 then -- TODO: Look at efficient params for determining if in range
        if oppDict[opponent.id] == nil then
            --print(self.tagText,"gen new opp in",opponent.tagText)
            oppDict[opponent.id] ={data = opponent, inRange = true,  vhDist = {}, oppWidth = oppWidth, flags = {frontWatch = false,frontWarning = false, frontEmergency = false,
                                        alongSide = false, leftWarning = false,rightWarning = false,leftEmergency = false,rightEmergency = false,
                                        pass = false, letPass = false, drafting = false}               
        }
        else
            oppDict[opponent.id].flags.inRange = true
        end
    else -- If opponent not in range at all ( DO we even add them to the dict?)
        if oppDict[opponent.id] == nil then
            --print(self.tagText,"gen new opp out",opponent.tagText)
            oppDict[opponent.id] ={data = opponent, inRange = false, vhDist = {},  oppWidth = oppWidth, flags = {frontWatch = false,frontWarning = false, frontEmergency = false,
            alongSide = false, leftWarning = false,rightWarning = false,leftEmergency = false,rightEmergency = false,
            pass = false, letPass = false, drafting = false}}
        else
            oppDict[opponent.id].flags.inRange = false -- Sets everything to false to reset
            --oppDict[opponent.id].flags =
            -- = {frontWatch = false,frontWarning = false, frontEmergency = false,
            --alongSide = false, leftWarning = false,rightWarning = false,leftEmergency = false,rightEmergency = false,
            --pass = false, letPass = false, drafting = false}
        end
    end
    --obsoleteVHDistances(self,opponent)
    if vhDist == nil then 
        return oppDict -- TODO: find what the heck this is for
    end -- send error?
    oppDict[opponent.id].vhDist = vhDist -- send to opp
    --print(self.tagText,"vvd",opponent.id,vhDist)
    return oppDict
end

function Driver.updateLocalRadar(self,opponent,oppDict)
    if opponent.carDimensions == nil then
        --self:sv_sendAlert("Car ".. opponent.tagText .. " Not Scanned; Place on Lift")
        print("opponent not scanned")
        return nil,nil
    end
    if opponent.rearColDist == nil or opponent.frontColDist == nil then
        print("oponent radar not updated?")
        return nil,nil --TODO: figure out what to return here
    end
    --local distance = getDriverDistance(self,opponent,#self.nodeChain) -- TODO: Remove cuz obsolete?
    local frontCol = nil
    local rearCol = nil
    local leftCol = nil
    local rightCol = nil
    local vhDist = oppDict[opponent.id].vhDist
    if vhDist['horizontal'] > 0 then -- opponent on right
        rightCol = vhDist['horizontal'] - (self.rightColDist + (opponent.leftColDist or self.leftColDist))
    elseif  vhDist['horizontal'] <= 0 then -- opponent on left
        leftCol = vhDist['horizontal'] + (self.leftColDist + (opponent.rightColDist or self.rightColDist)) -- Failsaif to its own width
    end

    if vhDist['vertical'] >= 0 then -- if opponent in front 
        frontCol = vhDist['vertical'] - (self.frontColDist + (opponent.rearColDist or self.rearColDist))
    elseif vhDist['vertical'] <0 then -- if opp behind 
        rearCol = vhDist['vertical'] + (self.rearColDist + (opponent.frontColDist or self.frontColDist))
    end
    -- update localRadar
    --print(self.tagText,"ulv",opponent.id,vhDist,frontCol,rearCol,leftCol,rightCol)

   if frontCol then
        if frontCol < self.carRadar.front then
            self.carRadar.front = frontCol
        end
   else
        self.carRadar.front = 100
   end
   
   if rearCol then
    if rearCol > self.carRadar.rear then
        self.carRadar.rear = rearCol
    end
    else
        self.carRadar.rear = -100 
    end

   if leftCol then
    if leftCol > self.carRadar.left then
        self.carRadar.left = leftCol
    end
    else
        self.carRadar.left = -100
        --oppFlags.leftWarning = false
    end

   if rightCol then
    if rightCol < self.carRadar.right then
        self.carRadar.right = rightCol
    end
    else
        self.carRadar.right = 100
        --oppFlags.rightWarning = false
    end
    local colDict = {["frontCol"] = frontCol, ["rearCol"]= rearCol, ["leftCol"] = leftCol, ['rightCol'] = rightCol}
    return colDict
end

-- Updating methods (layers and awhat not) -- Server

function Driver.updateCollisionLayer(self) -- Collision avoidance layer (Local radar update and pass determination)
    if self.carData == nil then return end -- not scanned
    --print(self.carData.carDimensions)
    if self.carData.carDimensions == nil then return end -- not scanned
    if self.engine == nil then return end
    if self.engine.engineStats == nil then return end -- Do validattion instead?
    --if self.speed < 5 then return end -- too slow
    local carsInRange = getDriversInDistance(self,70) -- gets list of all cars within certain distanvce
    if carsInRange == nil then -- No cars go home
        if self.passing.isPassing then
            self:cancelPass()
        end
        if self.drafting then
            self.drafting = false -- no cars to draft
        end
        return 
    end
    -- GEnerate Flag structure
    local colThrottleIncrement = self.colThrottleAdjust
    local throtAdjusted = false -- Flag to determine if throggle was adjusted at all
    local colSteerLArr = {}-- list of all left col avoidance (negative) (min)
    local colSteerRArr = {}-- list of all right col avoidance (positive) (max)
    local maxSteerAdj = 0 -- combination of left and right colAvoidance
    local passSteer = 0 -- add on to colSteer
    local oppDict = self.oppDict
    if self.oppDict == nil then  
        self.oppDict = {}-- setting as a calss var so it can carry over
        oppDict = self.oppDict
    else
        oppDict = self.oppDict
    end

    local selfWidth = self.leftColDist + self.rightColDist -- Init car width (uneccessary, should set in sv_init)
   
     -- Alongside stuff

    local alongSideLeft = -100
    local alongSideRight = 100 
    local draftEligible = false -- TODO: separate into drafting logic function
    -- Reset local radar per loop but not per opp
    self.carRadar = { 
        front = 100,
        rear = -100,
        right = 100,
        left = -100
    }
    for k=1, #carsInRange do local opponent=carsInRange[k] -- May need to have deep copy of carsInrange or create new class
        oppDict = self:generateOpponent(opponent,oppDict)
        local colDict = self:updateLocalRadar(opponent,oppDict) -- returns dic {frontCol,rearCol,leftCol,rightCol} which is really just carRadar... ()
        oppDict = self:setOppFlags(opponent,oppDict,colDict)

        -- Alongside set
        if (colDict.frontCol and colDict.frontCol <= 1.8) or (colDict.rearCol and colDict.rearCol >=0.4) then --car is vertially close
            if (colDict.leftCol and colDict.leftCol <= 0.05) or (colDict.rightCol and colDict.rightCol >= -0.05) then
                if colDict.leftCol and colDict.leftCol > -selfWidth then
                    if colDict.leftCol > alongSideLeft then
                        alongSideLeft = colDict.leftCol
                    end 
                end
                if colDict.rightCol and colDict.rightCol < selfWidth then
                    if colDict.rightCol < alongSideRight then
                        alongSideRight = colDict.rightCol
                    end
                end
            end
        end

        -- Check for collided Car (Lag Inducing)
        if (colDict.frontCol or 0) <= -0.6 or (colDict.rearCol or 0) >= 0.6  then -- if car abnormally close/overlapping?
            if (colDict.leftCol or 0) >= 0.7 or  (colDict.rightCol or 0) <= -0.7 then
                if self.speed < 5 then -- double check disparity between speed and desired speed
                    if self.shape.worldPosition.z > self.currentNode.mid.z + 2 or (self.stuck and self.stuckTimeout >= 5) then
                        if self.carResetsEnabled then
                            print(self.tagText,"resetting colided car")
                            --self.lost = true
                            self:resetPosition(true)
                        end
                    end
                end
            end
        end
        
        local colSteerL,colSteerR,colThrottleAdj = 0,0,0
        if self.pitState == 0 then
            self:processPassingDetection(opponent,oppDict) -- Determines whether to pass nearest opponent or not -- TODO: determine if maxSteer needs to even be passed thru
            colSteerL,colSteerR,colThrottleAdj = self:processOppFlags(opponent,oppDict,colDict,maxSteerAdj,colThrottleIncrement) -- Determines what to do with the rest of them 
        end
            -- Reasoning is because each opponent affected colSteer, but now that we are only taking biggest value, it doesnt need to be incremented
        -- There will most likely be a bug (especialy when both alongside) where the car will only veer away from closest car and ping pong as it changes
        -- FIX: actually have proper detection of alongside and not ALL of the nearby cars be affecting it
        table.insert(colSteerLArr,colSteerL)
        table.insert(colSteerRArr,colSteerR)
        
        if colThrottleAdj < self.colThrottleAdjust then -- TODO: See if we can do the same thing as steer (except minimum throttle)
            self.colThrottleAdjust = colThrottleAdj   -- sets increment to be lowest adjustment
            throtAdjusted = true
        else
            if colThrottleAdj == 0 then -- no slowing down adjusments found
            end
        end

        -- TODO: ADD YELLOW FLAGS Stopped cars will add global yellow flags with segID and trackPos/trackBias
     
    end

    -- correct posBias after avoidance instance?
    if self.trackPosBias and self.trackPosBias ~= 0 and (not self.caution and not self.formation)  then -- only do during race
        if self.carRadar and self.carRadar.front > 7 then
            --print(self.tagText,"resetting posBias")
            self.trackPosBias = 0
        end
    end

    -- Check Biggest steer
    local maxL = (getMin(colSteerLArr) or 0) -- combine maximum steering values from each side 
    local maxR = (getMax(colSteerRArr) or 0)
    maxSteerAdj = (maxL + maxR)/2 -- Old version with physical adjustments (made smaller to not have as much impact)
    self.collGoalOffsetStrength = (maxL + maxR) * -1 -- needed to be inverted cuz  yea

    --print(self.tagText,maxL,maxR,maxSteerAdj)
    
    local canDraft, draftLane = self:processDrafting(oppDict)
    self.drafting = canDraft
    --print(self.tagText,self.drafting)
    if not throtAdjusted and self.colThrottleAdjust < 0 then
        --print("stop throt adjust",self.colThrottleAdjust)
        self.colThrottleAdjust = 0
    end
    if canDraft then
            --print(self.tagText,self.drafting)
    end
    
    if draftLane ~= nil then -- TODO: Finish when new algo discovered
        --print(self.tagText,"Set draft lane?",draftLane,self.trackPosition)
        self.draftPosBias = draftLane--rampToGoal(draftLane,self.draftPosBias,0.001)
    else 
        self.draftPosBias = 0 --rampToGoal(0,self.draftPosBias,0.01)
    end

    -- set Alongside flags
    if alongSideLeft >-100 then
        self.carAlongSide.left = alongSideLeft
    else
        self.carAlongSide.left = 0
    end
    if alongSideRight < 100 then
        self.carAlongSide.right = alongSideRight
    else
        self.carAlongSide.right = 0
    end
    --self.strategicThrottle = colThrottle
    self.strategicSteering = self.strategicSteering + maxSteerAdj -- old version
    self.opponentFlags = oppDict

    local endTime = os.clock()
    local timeDif = endTime - self.startClock
    --print(self.id,"U col layer",timeDif)
end

-- Passing functionality
function Driver.cancelPass(self, reason) -- cancels passing
    --print(self.tagText,"canceling pass",reason)
    local passCarData = self.oppDict[self.passing.carID]
    if passCarData == nil then
        --print("no passcarData")
    else -- TODO: remove the external passcar data flag stuff
        passCarData.flags.pass = false
    end
    --print(self.tagText,"Cancel pass")
    self.passing.isPassing = false
    self.passing.carID = nil
    self.goalOffset = nil
    self.passCommit = 0 
    --self.passGoalOffsetStrength = 0
    self.passGoalOffsetStrength = rampToGoal(0,self.passGoalOffsetStrength,0.01)
end

function Driver.checkPassingSpace(self,opponent) -- calculates the best direction to pass -1 = left, 1 = right, 0 = nope.. bigger numbers will represent confidence level
    --if  (self.caution or self.formation) then return 0 end
    if not self.currentNode then return 0 end
    if not opponent then return 0 end
    if not opponent.currentNode then return 0 end -- Consolidate to validation function?
    if not self.futureLook or self.futureLook.direction == nil then return 0 end
    local passEligible = true
    local passDir = 0
    local oppDist = getDriverHVDistances(self,opponent)
    local oppDist = oppDist.vertical
    if oppDist <=4 then -- Maximum  margin will be at 1
        oppDist = 4
    end

   
    -- CHeckk if on straight/ going to turn depending on aggressive state
    if self.currentNode.segType == "Straight" then
        --print("onstraight",self.futureLook.distance)
        if self.futureLook.distance > 60 then
            --print(self.tagText,'Eigible pass?',self.futureLook.distance)
            passEligible = true
        else
            passEligible = false
        end
    end

    if self.safeMargin then -- prevent crazy passes?
        passeligible = false
    end

    local marginRatio = ratioConversion(18,5,4,0,oppDist) -- Convert x to a ratio from a,b to  c,d
    local turnDir = getSign(self.futureLook.direction)
    local oppTPos = opponent.trackPosition -- OOOR Just take the opponents distance from left/right wall
    local width = (opponent.currentNode.width or 20)
    local oppWidth = (opponent.leftColDist + opponent.rightColDist)
    local selfWidth = self.leftColDist + self.rightColDist
    local margin = self.passAggression + marginRatio --if distance is greater, aggression is smaller
    --print("margin",margin,((width/2) - oppTPos - oppWidth) + margin)
    if turnDir == 1 then -- turning right
        local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
        if spaceLeft < selfWidth then
            --print("No room on inside")
        else
            if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside and car in front?
                if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                    --print("Passing on inside")
                    passDir = 1
                else 
                    --print("car on your inside")
                end
            else
                --print("Car blocking inside") -- Could check for room past the car on inside?
                local laneWidth = width/3 
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('checking for three wide')
                    passDir = 1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= 1 then -- if a decision wasnt made check the other side for room
            spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        --print(self.tagText,"Passing on outise",turnDir,self.currentNode.segType)
                        passDir = -1
                    else
                        --print("car on your outside")
                    end
                else
                    local laneWidth = width/3 
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print(self.tagText,"Passing on outise 3wide",turnDir,self.currentNode.segType)
                        passDir = -1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    elseif turnDir == -1 then -- turning left
        local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
        if spaceLeft < selfWidth then
            --print("No room on inside (left)")
        else
            if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                    --print("Passing on inside")
                    passDir = -1
                else
                    --print("car on your inside")
                end
            else
                local laneWidth = width/3 
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('checking for three wide')
                    passDir = -1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= -1 then -- if a decision wasnt made check the other side for room
            spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside (right)")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                    --print("Passing on outside")
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        --print(self.tagText,"Passing on outiseR",turnDir,self.currentNode.segType)
                        passDir = 1
                    else
                        --print("car on your inside")
                    end
                else
                    local laneWidth = width/3 
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print(self.tagText,"Passing on outiseR 3wid",turnDir,self.currentNode.segType)
                        passDir = 1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    else
        passDir = self:calculateClosestPassPoint(opponent) -- default to left turn? maybe test oval
        --print("No Upcoming turns",passDir)
    end
    if passDir == 0 or passEligible == false then -- no decisions made
       passDir = 0
    end
    return passDir
end

function Driver.calculateClosestPassPoint(self,opponent) -- oppLoc = diver vh dist
    --if  (self.caution or self.formation) then return 0 end
    if not self.currentNode then return 0 end
    if not opponent then return 0 end
    if not opponent.currentNode then return 0 end    local oppTPos = opponent.trackPosition -- OOOR Just take the opponents distance from left/right wall
    local oppLoc
    if self.opponentFlags[opponent.id] ~= nil then
        oppLoc =  self.opponentFlags[opponent.id].vhDist
    else
        --print("could not find opp in flags")
        return 0 
    end
    local width = (opponent.currentNode.width or 20)
    local oppWidth = (opponent.leftColDist + opponent.rightColDist)
    local selfWidth = self.leftColDist + self.rightColDist + 0.1 -- small margin, TODO: Make adjustable with aggression
    local optimalDir = getSign(oppLoc.horizontal) -- easiest direction to move
    local mostSpace = -getSign(self.trackPosition) -- more space to move
    local margin = 0 -- decrease (into negatives) to reduce required space to attack, TODO: Make adjustable with aggression

    if optimalDir == mostSpace and optimalDir == 1 then -- the world aligns to the right
        local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
        if spaceLeft > selfWidth then
            if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside
                if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                    passDir = 1
                end
            end
        end
        if passDir ~= 1 then -- check other side
            spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  - 2 -- bigger margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        passDir = -1
                    end
                end
            end
        end
    elseif optimalDir == mostSpace and optimalDir == -1 then -- best to move left
        local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
        if spaceLeft > selfWidth then
            if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                    passDir = -1
                end
            end
        end
        -- check other side
        if passDir ~= -1 then -- if a decision wasnt made check the other side for room
            spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        passDir = 1
                    end
                end
            end
        end
    else
        -- DO next best execution
        if optimalDir == 1 then -- easiest to go to right
            local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        passDir = 1
                        --print(self.tagText,"Yeet Right")
                    end
                end
            end
            if passDir ~= 1 then -- check other side
                spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  - 2 -- bigger margin
                if spaceLeft > selfWidth then
                    if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                        if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                            passDir = -1
                            --print(self.tagText," Yolo left")
                        end
                    end
                end
            end
        elseif optimalDir == -1 then -- best to move left
            local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        passDir = -1
                        --print(self.tagText,"yeet left")
                    end
                end
            end
            if passDir ~= -1 then -- check other side
                spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
                if spaceLeft > selfWidth then
                    if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                        if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                            passDir = 1
                            --print(self.tagText," yolo right")
                        end
                    end
                end
            end
        end
    end
    if passDir == 0 then -- no room??
        --print("No yolo")
        if self.trackPosition > 0 then
            --print("Yolo Left")
            --passDir = -1
        else
            --print("yolo right")
           -- passDir = 1
        end
        --passDir = 0
    end

    if passDir == 0 then -- no decisions made
       --print("Stuck in middle Yolo",passDir)
    end  
    --print(self.tagText,"Closest patt",passDir) 
    return passDir
end

function Driver.confirmPassingSpace(self,opponent,dir) -- checks if the previus committed space is still availible
    --if  (self.caution or self.formation) then return 0 end
    if not self.currentNode then return 0 end
    if not opponent then return 0 end
    if not opponent.currentNode then return 0 end -- Consolidate to validation function?
    local passDir = 0
    local oppDist = getDriverHVDistances(self,opponent)
    local oppDist = oppDist.vertical
    if oppDist <=4 then -- Maximum  margin will be at 1
        oppDist = 4
    end
    local marginRatio = ratioConversion(15,1,2,0,oppDist) -- Convert x to a ratio from a,b to  c,d
    -- TODO: also check if currently on a turn
    local oppTPos = opponent.trackPosition -- OOOR Just take the opponents distance from left/right wall
    local width = (opponent.currentNode.width or 20)
    local oppWidth = (opponent.leftColDist + opponent.rightColDist)
    local selfWidth = self.leftColDist + self.rightColDist
    local margin = self.passAggression + marginRatio --if distance is greater, aggression is smaller
    local laneWidth = width/3 

    --print("margin",margin,((width/2) - oppTPos - oppWidth) + margin)
    if dir == 1 then -- turning right
        local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
        if spaceLeft < selfWidth then
            --print("No room on inside")
        else
            if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside
                if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                    --print("Passing on inside")
                    passDir = 1
                else
                    --print("car on your inside")
                end
            else
                --print("Car blocking inside") -- Could check for room past the car on inside?
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('confirming for three wide')
                    passDir = 1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= 1 then -- if a decision wasnt made check the other side for room
            spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        --print("Passing on outise")
                        passDir = -1
                    else
                        --print("car on your outside")
                    end
                else
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print('confirming for three wide')
                        passDir = -1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    elseif dir == -1 then -- turning left
        local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
        if spaceLeft < selfWidth then
            --print("No room on inside (left)")
        else
            if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                    --print("Passing on inside")
                    passDir = -1
                else
                    --print("car on your inside")
                end
            else
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('confirming for three wide')
                    passDir = -1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= -1 then -- if a decision wasnt made check the other side for room
            spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside (right)")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                    --print("Passing on outside")
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        --print("Passing on inside")
                        passDir = 1
                    else
                        --print("car on your inside")
                    end
                else
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print('confirming for three wide')
                        passDir = 1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    else
        --print("Pass dir confirming 0???") -- maybe add some othe optyion??
    end

    if passDir == 0 then -- no decisions made, cancel the pass
        --print("Stuck in middle",passDir)
    end  
    --print(self.tagText,"pass",passDir)  
    return passDir
end

function Driver.calculatePassOffset(self,opponentD,dir) -- calculates strenght of pass offset
    if self.goalNode == nil then return end
    if self.goalNode.width == nil then return end
    local opponent = opponentD.data
    local oppWidth = (opponent.leftColDist + opponent.rightColDist)
    local selfWidth = self.leftColDist + self.rightColDist
    local speedDif = self.speed - opponent.speed
    if speedDif < 0.2 then 
        speedDif = 0.2 -- Will almost always be less than 2 in a normal situation
    elseif speedDif > 12 then
        speedDif = 12
    end
    local goalTrackPos = getNodeVHDist(self.goalNode,self.goalNode).horizontal -- horizontal dif
    local desiredTrackPos = opponent.trackPosition + (dir * (oppWidth + selfWidth/1.4))

    local strength = 0 
    --print(self.tagText,"o[pp",opponentD.vhDist)
    local distFromOpp = opponentD.vhDist.vertical
    if distFromOpp < 2 then  -- cap it here
        distFromOpp = 2
    end
    if math.abs(desiredTrackPos) < self.goalNode.width/2.4 then -- As long as pass pos is within track width
        strength = speedDif + math.abs(goalTrackPos-desiredTrackPos)*(2.4/distFromOpp) -- convert by distance away from opp, smaller number = less ratio
        --print(self.tagText,"Pos on track",speedDif,math.abs(goalTrackPos-desiredTrackPos),distFromOpp)
    else
       --print(self.tagText,"offtrack Pass reduce",desiredTrackPos,strength)
        strength = speedDif + math.abs(goalTrackPos-desiredTrackPos)*(0.4/distFromOpp) -- Bi
        self:cancelPass("offtrack pass reduce 4366") -- remove flag?
    end

    local multiplier = 1
    -- TODO: have situational multiplier (banking, track width, speeddif, etc)
    if distFromOpp < 15 then 
        multiplier = 1.3
    elseif distFromOpp < 6 then
        multiplier = 1.7
    elseif distFromOpp < 2 then
        multiplier = 2.4
    end

    --print(self.tagText,"goal",distFromOpp,multiplier,strength)
    local passOffsetStrength = (dir * strength) * multiplier
    --print(self.tagText,"pass Stren",distFromOpp,dir,multiplier,passOffsetStrength)
    return passOffsetStrength
end

function Driver.calculateTrackPosBiasStrength(self)
    local biasDif = 0
    if self.trackPosition ~= nil then -- we have a location, 
        if self.trackPosBias == nil then -- we dont have a desired location
            self.trackPosBias = 0 
        end
        -- TODO: discover if lerp can go here to prevent rapid cutting??
    end
    if self.trackPosition ~= nil and self.trackPosBias ~= 0 then -- 0 is just node.mid, use that instead? or TODO: change setting of 0 to nil
        biasDif = (self.trackPosBias - self.trackPosition)
    end
    --print(self.tagText,"biasDIf?",self.trackPosBias,self.trackPosition,biasDif)
    self.biasGoalOffsetStrength = biasDif
end

function Driver.calculateDraftPosBiasStrength(self)
    local strength = 0

    if self.draftPosBias == nil then -- we dont have a desired location
        self.draftPosBias = 0 
    else
        -- TODO: discover if lerp can go here to prevent rapid cutting??
    end
    
    -- We need to inverse, dampen and normalize, 
    if self.draftPosBias ~= 0 then
        strength = (self.draftPosBias * 1)/4
    end

    self.draftGoalOffsetStrength = strength
    
    --print(self.tagText,"set draft biasDif",self.draftGoalOffsetStrength)
end

function Driver.calculateGoalOffset(self) -- calculates goal node offset ( combination of pass, trackpos, draft goal biases)
    if self.passing.isPassing == false and self.passGoalOffsetStrength > 0 then -- continue smooth rampt to zero
        -- TODO: Also do a smooth ramp up to strength? (priority calc should do that)
        self.passGoalOffsetStrength = rampToGoal(0,self.passGoalOffsetStrength,0.01)
        if self.passGoalOffsetStrength <= 0.02 then
            self.passGoalOffsetStrength = 0
        end
    end

    local totalOffset = (self.passGoalOffsetStrength * self.passFollowPriority) + (self.biasGoalOffsetStrength * self.biasFollowPriority) + (self.collGoalOffsetStrength * self.collFollowPriority) + (self.draftGoalOffsetStrength * self.draftFollowPriority)
    self.goalOffset = self.goalNode.perp * totalOffset
    --print(self.tagText,self.passGoalOffsetStrength * self.passFollowPriority,self.biasGoalOffsetStrength * self.biasFollowPriority,self.draftGoalOffsetStrength * self.draftFollowPriority,totalOffset)
    return self.goalOffset
end

function Driver.calculateFutureTurn(self) -- calculate future turns
    if self.currentNode == nil then return nil end
    if self.currentNode.segType == nil then return nil end
    local foundTurn = false 
    local curSeg = self.currentNode.segID
    local curSegType = self.currentNode.segType
    local nextTurnSeg = curSeg -- will get updated with next turn found
    local segNode = nil
    local timeout = 0
    local timeoutLimit = #self.nodeChain
    --print("Grabbing futureTurn totalsegments",self.totalSegments,curSeg)
    while not foundTurn do
        curSeg = getNextIndex(self.totalSegments,curSeg,1)
        segNode = self:getSegmentBegin(curSeg)
        if segNode == nil then return nil end
        
        if timeout >= timeoutLimit or self.ovalTrack == true then -- or self.ovalTrack
            self.ovalTrack = true
            --print("FutureTurn timout")
            nextTurnSeg = segNode -- just have last segment for now
            break
        end


        if segNode.segType ~= curSegType then
            if segNode.segType ~= "Straight" then
                foundTurn = true
                nextTurnSeg = segNode
            end
        end
        timeout = timeout + 1
        
    end
    local turnDir = getSegTurn(nextTurnSeg.segType)
    local distanceFromTurn = getDistance(segNode.location,self.location)
    local segID = segNode.segID
    
    local segLen = self:getSegmentLength(segID)
    if turnDir == 0 then 
        --print(segID,turnDir,segLen,distance)
    end
    if segLen == nil then
        print("nil Len",segID,segLen,distance)
    else
        --print("Len",segLen)
    end
    
    return {segID = segID, direction = turnDir, length = segLen, distance = distanceFromTurn} 
end


function Driver.handleTilted(self) -- TODO: update this properly
    if self.tilted== true then 
        --print(self.tagText,"correcting tilt")
        local offset = sm.vec3.new(0,0,0)
		--local angularVelocity = self.shape.body:getAngularVelocity()
		--local worldRotation = self.shape:getWorldRotation()
		local upDir = self.shape:getUp()
		--print(angularVelocity)
		--print(worldRotation)
		--print(upDir)
		-- Check if upside down,
		local stopDir = self.velocity * -1.1
        if sm.vec3.closestAxis(upDir).z == -1 then
            local weight =self.mass * DEFAULT_GRAVITY
		    stopDir.z = self.mass/2.5
        else
            stopDir.z = self.mass/11
        end
		offset = upDir * 4
		if self.shape:getWorldPosition().z >= self.currentNode.location.z + 3 then 
			stopDir.z = -450 -- maybe anti self.weight?
			--offset = 
		end
		sm.physics.applyImpulse( self.shape.body, stopDir,true,offset)
    end
end

function Driver.handleOverUnderSteer(self)
    if self.oversteer and self.goalNode then
        local offset = self.goalDirectionOffset
        self.rotationCorrect = true
       --print(self.id,"oversteer correct",offset,self.speed, self.strategicThrottle)
        --self.pathGoal = "mid"
        if self.strategicThrottle >= 0 then  
            --self.strategicThrottle = self.strategicThrottle - 0.1 -- begin coast
            -- reduce steering?
            --print("osset",offset)
            if math.abs(offset) > math.pi/8.5 then
                self.strategicThrottle = rampToGoal(0, self.strategicThrottle,0.01)
                --print("ovrsteer losing contol",offset,self.speed,self.strategicThrottle)

            elseif self.speed >= 20 then
                self.strategicThrottle = rampToGoal(0, self.strategicThrottle,0.02)
                --print("oversteer high speed adj",offset,self.speed,self.strategicThrottle)
            else
                self.strategicThrottle =self.strategicThrottle -0.05 -- coast

            end
        end
    end

    if self.understeer and self.goalNode and not self.oversteer then
        local offset = self.goalDirectionOffset
        self.rotationCorrect = true
        if self.strategicThrottle >= 0 then  -- Do this when not "braking"
            self.strategicThrottle = self.strategicThrottle - 0.1
            --print(self.id,"understeerCorrect",self.strategicThrottle)
            if math.abs(offset) > 13 or self.speed > 24 then
                self.strategicThrottle = ratioConversion(10,35,0,1,self.speed) -- Convert x to a ratio from a,b to  c,d
                if self.speed <= 10 then
                    self.strategicThrottle = 0.2
                    self.strategicSteering = self.strategicSteering/1.5
                end
            else
                self.strategicThrottle = self.strategicThrottle - 0.1 -- coast
                --self.strategicSteering = self.strategicSteering *0.95
            end
        else
            --print(self.id,"understeer braking",self.speed,offset,self.strategicThrottle)
            if self.speed > 17 then
                if offset > 14 then
                    self.strategicThrottle = self.strategicThrottle - 0.05
                end
            end
        end
    end

    if not self.understeer or not self.oversteer then -- Do same for oversteer? 
        if self.pathGoal ~= "location" then
            self.pathGoal = "location"
        end
    end
end

function Driver.handleOverRotation(self)
    if self.rotationCorrect then
        --print(self.id,"fix rotate",self.angularVelocity:length(),self.goalDirectionOffset, self.speed,self.strategicThrottle)
        if self.speed < 15 and  math.abs(self.goalDirectionOffset) > 3 and self.angularVelocity:length() > 0.7 then -- counter steer
            --self.strategicSteering = self.strategicSteering / -5
            --print(self.tagText,"counterSteer?")
        end
        
        if self.speed < 17 or self.angularVelocity:length() < 1 and math.abs(self.goalDirectionOffset) < 1 then
            self.rotationCorrect = false
            self.speedControl = 0
            --self.strategicThrottle = self.strategicThrottle - 0.01
            --print(self.tagText, "rotation fixed?") TODO: Figure this one out on when its truly fixed
        end
        if self.speed >20 then
           --print("over speed rotatin correct")
            --print("brake",self.speed)
            self.strategicThrottle = self.strategicThrottle - 0.1
        end
    end    
end

function Driver.getWallAdjust(self)
     -- Check walls
    local frontLength = (self.carDimensions or 1)
    if self.carDimensions ~= nil then 
        frontLength = self.carDimensions['front']:length()
    end
    local frontLoc = self.location + (self.shape.at*frontLength)
    local hitR,rData = sm.physics.raycast(frontLoc,frontLoc + self.shape.right *6,self.body) 
    local hitL,lData = sm.physics.raycast(frontLoc,frontLoc + self.shape.right *-6,self.body)

    local wallSteer = 0
    if hitR and rData.type == "terrainAsset" then
        local dist = getDistance(self.location,rData.pointWorld) 
        if dist <= 7 then
            wallSteer = ratioConversion(7,0,0.12,0,dist)  -- Convert x to a ratio from a,b to  c,d
            --print(self.tagText,"right",dist,wallSteer)
        end
    end

    if hitL and lData.type == "terrainAsset" then
        local dist = getDistance(self.location,lData.pointWorld) 
        --print(dist)
        if dist <= 7  then
            --print("left",dist)
            wallSteer = ratioConversion(7,0,0.12,0,dist) * -1  -- Convert x to a ratio from a,b to  c,d
            --print(self.tagText,"left",wallSteer)
        end
    end

    local frontPredictR = frontLoc + (self.shape.at *7 + self.shape.right *6)
    local frontPredictL = frontLoc + (self.shape.at *7 + self.shape.right *-6)

    local hitR,rData = sm.physics.raycast(frontLoc,frontPredictR,self.body) 
    local hitL,lData = sm.physics.raycast(frontLoc,frontPredictL,self.body)
    
    if hitR and rData.type == "terrainAsset" then
        local dist = getDistance(self.location,rData.pointWorld) 
        if dist <= 6 then
            wallSteer = wallSteer + ratioConversion(6,0,0.11,0,dist) *1  -- Convert x to a ratio from a,b to  c,d
            --print(self.tagText,"right2",dist,wallSteer)
        end
    end

    if hitL and lData.type == "terrainAsset" then
        local dist = getDistance(self.location,lData.pointWorld) 
        --print(dist)
        if dist <=6 then
            --print("left",dist)
            wallSteer = wallSteer +  ratioConversion(6,0,0.11,0,dist) * -1  -- Convert x to a ratio from a,b to  c,d
            --print(self.tagText,"left2",walStwallSteereer)
        end
    end

    if self.passing.isPassing then -- dampen track adjustment --TODO Also adjust fo car alongside?
        wallSteer = wallSteer * 0.8 
        --print(self.tagText,"Track lim test",trackAdj)
    end
    
    return wallSteer
end

function Driver.getTrackLimitAdjust(self)
    -- try to stay within tracklimits (exeption on overtake?)
    local wallLimit = self.currentNode.width or 50 -- in case width is messed up
    local sideLimit = wallLimit/2.1 -- get approximate left/right limits on the wall
    local trackAdj = 0
    --if self.trackPosition == nil then return end
    local tDist = sideLimit - math.abs(self.trackPosition)
    if tDist <=8 then -- TODO: racecontrol,LimitPadd
        if self.trackPosition > 0 then
            trackAdj = ratioConversion(8,0,0.14,0,tDist) *1  -- Convert x to a ratio from a,b to  c,d    
        else
            trackAdj = ratioConversion(8,0,0.14,0,tDist) *-1 -- Convert x to a ratio from a,b to  c,d 
        end
        --print(self.tagText, "track limit",trackAdj,tDist)

        if self.passing.isPassing then -- dampen track adjustment --TODO Also adjust fo car oalongside?
            trackAdj = trackAdj * 0.7 
            --print(self.tagText,"Track lim test",trackAdj)
        end
    end
    -- also check alongside?
    --print(self.trackPosition,sideLimit,tDist,trackAdj,wallSteer)
    return trackAdj
end

function Driver.getFrontDist(self) -- Returns front collision distance and offset from track
    local frontDir = self.shape.at
    local hit,data = sm.physics.raycast(self.shape:getWorldPosition() + frontDir *2,self.location + frontDir *20,self.body) -- TODO: instead of * 2 do frontSize
    local dist = 100
    if hit then
        dist = getDistance(self.location,data.pointWorld) 
    end
    return dist
end

function Driver.handleRejoinInitiation(self) -- handles reversing the car initially
    --print(self.tagText,"rejoin init2")
    -- check wall blocker and offtrack
    -- if self.offtrack ~= 0 then
    hit, data = sm.physics.raycast(self.location, self.currentNode.location)
    if hit then
        htype = data.type
        if htype == "terrainAsset" then
            --self.stuckTimeout = self.stuckTimeout + 5
        end
    else
    end


    if math.abs(self.shape.at.z) > 0.1 then
       -- print(self.tagText,"Car potentially tilted")
        self.stuckTimeout = self.stuckTimeout + 0.1
    end
    if self.engine.curRPM > 0 and self.curGear >0 then
        --print(self.tagText,"slowing to strt reverse",self.engine.curRPM,self.curGear)
        self.engine.curRPM = 0 -- Immediately stop
        --self.engine:setRPM(0) -- set to 0?
        self.strategicThrottle = -1
        self.curGear = 0 -- has to be a better way to do 
        self:shiftGear(self.curGear)
       -- print(self.tagText,"Set RPM to 0",self.engine.curRPM,self.curGear)
    else -- Check for clear entry point then reverse
        print(self.tagText,"Waiting for clear track")
        local distanceThreshold = -30 -- make dynamic?
        local clearFlag = self:checkForClearTrack(distanceThreshold)
        if clearFlag then
            local curentSide = self:getCurrentSide()
            --print(self.tagText,"reverse clear Rejoining",self.trackPosition,curentSide)
            self.trackPosBias = curentSide
            self.rejoining = true
            self.curGear = -1 -- sets it in reverse gear
            self:shiftGear(self.curGear)
            self.strategicThrottle = 1
            self.strategicSteering = self.strategicSteering * -1.1 -- Inverts steering but does it sty that way
        else -- stay stopped
            --print(self.tagText,"Wait rejoin init")
            self.strategicThrottle = -1
        end
    end

end

function Driver.handleRejoinReverse(self)
    --print(self.tagText,"CurReverse attemptReverse",toVelocity(self.engine.curRPM))
    if toVelocity(self.engine.curRPM) < -5  then -- If reversing hard enough to see some progress, check if stuck again
        if self.speed <= 1 then
            print(self.tagText,"reverse stuck")
            local distanceThreshold = -20 -- make dynamic?
            local clearFlag = self:checkForClearTrack(distanceThreshold)
            if clearFlag then -- Attempt to move forward
                --print("Clear shift 1")
                self.curGear = 1
                self:shiftGear(1)
                self.strategicThrottle = 1
                self.stuckTimeout = self.stuckTimeout + 1
            else
                --print(self.tagText,"Wait rejoin reverse")
                self.strategicThrottle = -1 -- brake
                self.stuckTimeout = self.stuckTimeout + 0.01
            end
        end
    end
    self.strategicSteering = self.strategicSteering * -1 -- Inverse steering while continuing to move backwards
    local offset = self.goalDirectionOffset
    local frontColDist = self:getFrontDist() -- returns distance raycast to front or 100 as furthest
    --print(self.tagText,"ReverseDIst",offset,frontColDist)
    if math.abs(self.shape.at.z) > 0.1 then
        print(self.tagText,"reverse tilted??")
        self.stuckTimeout = self.stuckTimeout + 0.5
    end
    if (math.abs(offset) < 0.8  and  frontColDist >= 7) or frontColDist >=20 then -- If facing right way and not too close to wall in front
        if self.speed > 1 then -- TEMPORARY FIX for leaning against wall, check tilt and rotation as well 
            self.curGear = 1
            self:shiftGear(1)
            self.strategicThrottle = 0.95
            --print(self.tagText,"aligned/Finish reverse",offset,frontColDist) -- starts moving forward
            return
        end
    else
        if self.speed < 1 then 
            print(self.tagText,"ForceUnstuck",frontColDist,self.stuckTimeout)
            self.strategicThrottle = 1
            self.stuckTimeout = self.stuckTimeout +0.5
        end
    end

    --[[if self.strategicThrottle ~= 1 then Probably not necessary
       -- print("RandomFlip",self.curGear,self.strategicThrottle)
       if not self.nudging then
            self.stuckTimeout = self.stuckTimeout + 1
       end
        self.strategicThrottle = 0.95
    end]]
end


function Driver.handleRejoinForward(self)
    local maxSpeed = self:getVmax(self.currentNode)
    --print(self.tagText,"gear > 0",self.strategicThrottle,toVelocity(self.engine.curRPM))
    -- First check if stuck
    if toVelocity(self.engine.curRPM) > 5 and self.speed <= math.abs(toVelocity(self.engine.curRPM)) -2 then -- Going forward but not quite there
        if self.speed <= 2 then -- if stuck for sure
            if math.abs(self.shape.at.z) > 0.1 then
                --print(self.tagText,"forward stuck tilted??")
                self.stuckTimeout = self.stuckTimeout + 0.5
            end
            --print(self.tagText,"rejoin forward stuck",toVelocity(self.engine.curRPM),self.speed)
            local distanceThreshold = -30 -- make dynamic?
            local clearFlag = self:checkForClearTrack(distanceThreshold)
            if clearFlag then
                self.stuckTimeout = self.stuckTimeout + 1
                self.curGear = -1
                self:shiftGear(-1)
                self.strategicThrottle = 1
                local curentSide = self:getCurrentSide()
                --print(self.tagText,"forward rejoin turned reverse",self.trackPosition,curentSide)
                self.trackPosBias = curentSide
            else -- wait for clear
                --print(self.tagText,"Wait rejoin forward")
                self.strategicThrottle = -1
            end
            return
        else
            self.strategicThrottle = 0.7
        end
    end
    -- if able to move forward, continue to do so
    self.strategicThrottle = 1 -- TODO: do a setter fro strategic Throttle? 
    
    --print(self.tagText," forward rejoin cmax?",self.speed,toVelocity(maxSpeed))
    if self.speed > 3 and  ( self.speed >= toVelocity(self.engine.curRPM)  and self.speed >= toVelocity(maxSpeed) - 5 and self.offTrack == 0) or (self.curGear >=3 and self.offTrack == 0) then
        self.rejoining = false
        self.stuck = false
        self.pathGoal = "location"
        self.trackPosBias = nil -- set 0?
        self.stuckTimeout = 0
        --print(self.tagText,"rejoin done",self.offTrack,self.stuckTimeout)
    else -- if stopped
        self.stuck = true
        self.rejoining = true
        self.strategicThrottle = 1
        --print(self.tagText,"attemtpt move forward")
    end

    if self.engine.curRPM < -5 then -- Transitioning from reverse to forward rejoin
        --print(self.tagText,"still going backwards",self.engine.curRPM,self.curGear)
        self.strategicSteering = self.strategicSteering * -0.2 -- Inverse steering
    end
end

function Driver.handleNudge(self)
    --print(self.tagText,"Nudge",getDistance(self.location,self.currentNode.mid),math.abs(self.shape:getWorldPosition().z - self.currentNode.mid.z))
    self.strategicThrottle = 0
    local nudgeDir = sm.vec3.new(0,0,0)
    if not self.nudging then
        if math.abs(self.shape:getWorldPosition().z - self.currentNode.mid.z) <= 5 then -- bring up then send over
            nudgeDir.z = self.mass/1.5
            --print(self.tagText,"pickup",getDistance(self.location,self.currentNode.mid))
            if self.carResetsEnabled then -- TODO: Add this to the GUI  
                sm.physics.applyImpulse( self.shape.body, nudgeDir,true)
            end
            return
        else
            self.nudging = true
        end
    end
    
    if self.nudging and getDistance(self.location,self.currentNode.mid) > 15  then --- Mid Nudge
        --print("moving",getDistance(self.location,self.currentNode.mid))
        nudgeDir = sm.vec3.normalize((self.currentNode.mid-self.location)) * 1250
        nudgeDir.z = self.mass/2.5
        if math.abs(self.shape:getWorldPosition().z - self.currentNode.mid.z) >= 7 then -- if too high
            nudgeDir.z = -self.mass/2.3
        elseif math.abs(self.shape:getWorldPosition().z - self.currentNode.mid.z) <= 5 then -- too low
            nudgeDir.z = self.mass/2
        end
        self.stuckTimeout = self.stuckTimeout + 0.01 -- move towards being reset anyways
    else -- Done Nudging 
        --print(self.tagText,"Done Nudge")
        if not self.stuck then
            self.stuckTimeout = 0
        else
            if not self.nudging then
                self.stuckTimeout = self.stuckTimeout + 0.2
            end
        end
        self.strategicThrottle = 0
    end
    --self.nudging = true ??
    if self.carResetsEnabled then -- TODO: Add this to the GUI  
        sm.physics.applyImpulse( self.shape.body, nudgeDir,true)
    end
    
end

function Driver.handleStuck(self) -- how the driver handles being stuck
    if self.stuck and self.racing then
        --print(self.tagText,"stuck")
        if math.abs(self.shape.at.z) > 0.3 then
            --print(self.tagText,"handle stuck stuck tilted??",self.shape.at.z)
            self.stuckTimeout = self.stuckTimeout + 0.02
        end
        if self.rejoining then -- Car is cleared to rejoin
            if self.curGear == -1 then -- If reversing
                --print(self.tagText,"beforerejoiunreversehandle")
                self:handleRejoinReverse()

            elseif self.curGear > 0 then -- If moving forward during rejoin
                --print(self.tagText,"rejoin forward")
                self:handleRejoinForward()
            else -- something wong
               print(self.tagText,"SOmething wrong",self.curGear)
               self:shiftGear(1)
               self.strategicThrottle = 1
               self.rejoining = true
               self.stuck = true
               self.trackPosBias = 0 -- reset bias...
               self.stuckTimeout = self.stuckTimeout + 5
            end
           
        else -- start rejoin process by backing up
            --print(self.tagText,"rejoin init")
            self:handleRejoinInitiation()
        end
    
        --print(self.tagText,'stuckTimeout',self.stuckTimeout,self.curGear,self.stuck,self.nudging)
        if self.stuckTimeout >= 7 and not self.onLift and self.speed < 3 and not self.userControl then
            print(self.tagText,"Is Now Lost",self.stuckTimeout)
            self.lost = true
            return
        end
        if self.stuckTimeout > 1 and self.stuckTimeout < 5 and not self.onLift and not self.nudging then -- Attempt to actually find the closest node?? 
            -- This should probably bet removed completely because we should try to get to our last known current
            --print(self.tagText,"stuck timeout wait")
            --[[if nearestNode == nil then -- try again with new algo
                --print(self.tagText,'fcn2')
                --nearestNode = findClosestNode(self.nodeChain,self.location)
            end
            --nearestNode = getNearestNode(self.nodeMap,self.shape.worldPosition)
                
            if nearestNode == nil then
                print("nilnewrest nnew node")
                self.nodeFindTimeout = self.nodeFindTimeout + 1
            else
                --print(self.tagText,"stuck Set new node",nearestNode.id)
                self:setCurrentNode(nearestNode)
            end
            ]]

        elseif self.stuckTimeout > 5 and not self.shape:getBody():isStatic() and self.currentNode ~= nil then
            self:handleNudge()
        --print("Getting next node in distance",distance,self.currentNode.location)
        end
    else
        if self.nudging then
            --print(self.tagText,"stoped nudge")
            self.nudging = false
        end
    end
    --print("Stuckfallthru")
end

function Driver.handleOfftrack(self)
    if self.offTrack ~= 0 and not self.userControl then
        --print(self.tagText,"offtrack",self.offTrack)
        if self.speed < 15 then -- speed rejoin
            --self.strategicSteering = self.strategicSteering --+ self.offTrack/90 --? when at high speeds adjust to future turn better?
            --print(self.tagText,"offtrack correction", print(self.id,"offtrack",self.goalDirectionOffset))
            self.strategicSteering = self.strategicSteering - (self.goalDirectionOffset/(math.abs(self.offTrack) +0.1))
            if self.speed < 1 then
                --print(self.tagText,"stuck offtrack?")
                --self.stuck = true
            end
        else -- just use nodefollow?
            self.strategicThrottle = 0.5 -- was -0.2, why?
            
        end
        --print(self.id,"offtrack",self.offTrack,self.strategicSteering)
    end
end


function Driver.handleOffCenter(self)
    local adjustmenDampener = 80 -- 
    if self.currentNode == nil or self.goalNode == nil then return end
    if self.currentNode.outVector == nil then return end
    if self.goalNode.outVector == nil then return end
    local raceLineOffset = vectorAngleDiff(self.shape.at,self.currentNode.outVector)

    if not self.rejoining and not self.stuck then
        --print(self.tagText,"Offc",raceLineOffset,self.goalDirectionOffset)
        if raceLineOffset ~= nil and math.abs(raceLineOffset) >0.4  then  -- If theres a large offset
            local turnAngle = vectorAngleDiff(self.shape.at,self.goalNode.outVector)
            local turnLineDif = math.abs(raceLineOffset) - math.abs(turnAngle)
            if self.speed > 18 then -- and turnLineDif > ?
                self.goalOffsetCorrecting = true
                --print(self.tagText,"WildOfftrackAdjustST",self.strategicSteering,self.goalDirectionOffset,raceLineOffset)
                    self.strategicThrottle = 0.5
                    if math.abs(self.trackPosition) < self.currentNode.width/3.5 then -- if somewhat in the middle, slow the adjustment
                        --print("Middle track Adjust",self.strategicSteering,-(raceLineOffset / adjustmenDampener))
                        self.strategicSteering = self.strategicSteering + -(raceLineOffset / adjustmenDampener)
                    else
                        --print(self.tagText,"outside Adjust",raceLineOffset,(raceLineOffset / adjustmenDampener))
                        self.strategicThrottle = -0.5
                        self.strategicSteering = self.strategicSteering - (raceLineOffset / adjustmenDampener)
                    end
            else -- if speed less than 20
                --print(self.tagText,"Turn Spinout??",self.goalDirectionOffset,self.strategicThrottle,self.speed,raceLineOffset)
                if self.speed < 7 and math.abs(raceLineOffset) > 0.7 then
                    --print(self.tagText,"Confirm Spinout")
                    self.strategicThrottle = 0
                    if self:checkForClearTrack(-30) then
                        --print("clear track")
                        self.strategicThrottle = 1
                    else
                        self.strategicThrottle = 0.5
                    end
                else
                    if self.goalOffsetCorrecting then 
                        self.goalOffsetCorrecting = false
                    end
                end
            end
        else
            if self.goalOffsetCorrecting then  -- crosscheck turn angle and raceline position
                self.goalOffsetCorrecting = false
            end
        end
    else
        if self.goalOffsetCorrecting then 
            self.goalOffsetCorrecting = false
        end
    end
end

function Driver.handleRejoin(self)
    if self.rejoining then -- what going on?
        --print(self.tagText, "Actually moving forward rejoining")
        if  self.curGear >= 3 then -- TODO: have a better metric than just gear...
            print(self.tagText,"rejoin complete")
            self.rejoining = false
            self.stuck = false
            self.pathGoal = "location"
            self.trackPosBias = 0
        end
    end
end


function Driver.updateErrorLayer2(self) -- New Method
    if self.engine == nil then return end
    if self.engine.engineStats == nil then return end
    if self.goalNode == nil or self.currentNode == nil then return end

    -- Process tilted
    self:handleTilted()
    -- process oversteer and understeer
    self:handleOverUnderSteer()
    -- handle over rotation
    self:handleOverRotation()
    -- handle wall and track limits
    local wallSteer = self:getWallAdjust()
    local trackAdj = self:getTrackLimitAdjust()
    self.strategicSteering = self.strategicSteering + wallSteer + trackAdj-- Maybe not desparate?
    -- check and handle stuck
    self:handleStuck()
    -- Check Offtrack TODO: figure this out, sometimes car thinks it is off track when it is not
    self:handleOfftrack()
    
    -- Check wildly offCenter I think these conflict with other things
    self:handleOffCenter()

    
    -- cautijon check
    if self.caution then
        self:checkCautionPos()
    end

    if self.formation then
        self:checkFormationPos()
    end
    --local endTime = os.clock()
    --local timeDif = endTime - self.startClock
    --self:debugOutput(1,{"UEL2",timeDif})
end



function Driver.resetPosition(self,force) -- attempts to place the driver on a lift
    --print(force,self.onLift,self.resetPosTimeout)
    if self.resetPosTimeout < 10 and not self.onLift and not force then
        self.resetPosTimeout = self.resetPosTimeout + 0.1
        --print("reset",self.resetPosTimeout)
        return 
    end
    if force then
        --print("Force reset")
    end
    if not self.raceControlError then
        if not getRaceControl():sv_checkReset() then
            --print("Wait for reset")
            return
        else
            --print("Can reset")
            getRaceControl():sv_resetCar()
        end
    else
        print("no race control")
    end

    if true then -- formerly if self.lost
        --print("fix lost?",self.onLift )
        if self.onLift then
            print("car on lift")
            return
        end
        if not self.liftPlaced and not self.onLift and self.racing == true then
            local bodies = self.body:getCreationBodies()
            self.creationBodies = bodies
            local locationNode = (self.resetNode or self.nodeChain[4])
            local location = locationNode.mid * 4
            --print(locationNode.location.z,locationNode.mid.z)
            if locationNode == nil or locationNode.outVector == nil then
                print(self.tagText,'Nil rotation or location node on reset')
                return
            end
            local rotation = getRotationIndexFromVector(locationNode.outVector,0.75)
            if rotation == -1 then
                --print("Got bad rotation")
                rotation = getRotationIndexFromVector(locationNode.outVector, 0.45) -- less precice, more likely to go wrong or do a getNearest Axis and then rotate
            end
            local realPos = sm.vec3.new(math.floor( location.x + 0.5 ), math.floor( location.y + 0.5 ), math.floor(  location.z + 6.5 ))
            -- check if this will intersect with anything else
            local okPosition, liftLevel = sm.tool.checkLiftCollision( self.creationBodies, realPos, rotation )
            --print("QuieckCHeck",okPosition,liftLevel)
            if okPosition then
                --print('Resetting Position:',realPos,rotation)
                sm.player.placeLift( self.player, self.creationBodies , realPos, liftLevel, rotation ) --Lift Level, rotation index
                if not self.liftPlaced then
                    self.liftPlaced = true
                    --print("placed Lift",self.shape:getWorldPosition())
                    self:sv_softReset()
                    self.resetPosTimeout = 0
                end
            else
                print(self.tagText,"Reset collision, Forcing",okPosition,liftLevel,location)
                self.nudging = true
                -- TODO: introduce timeout before force reset?
                realPos = realPos + rotation * 3 + sm.vec3.new(0,0,3)
                sm.player.placeLift( self.player, self.creationBodies , realPos, liftLevel, rotation ) --Lift Level, rotation index
            end
            return
        end
        if self.liftPlaced and not self.lost then
            print("Lift placed and not lost")
            sm.player.removeLift( self.player)
            self.liftPlaced = false
        else 
            if self.onLift then
                print("MadOn lift but still lost")
            else
                print("Not on lift, try again?")
                sm.player.removeLift(self.player)
                self.liftPlaced = false
            end
        end
    else
        print("non lost reset")
    end
end


function Driver.calculateTrackPos(self)
    if not self.currentNode then return 0 end
    local trackPos = 0 -- 0 is center
    --print("trackPos",self.currentNode)
    local vhDist = getNodeVHDist(self,self.currentNode)
    return vhDist.horizontal
end

function Driver.calculateRaceLinePos(self,node)
    if not self.currentNode then return 0 end
    local trackPos = 0 -- 0 is center
    --print("trackPos",self.currentNode)
    if node == nil then 
        node = self.currentNode
    end
    local vhDist = getRaceNodeVHDist(node,self.location)
    return vhDist.horizontal
end

function Driver.calculateGoalDirection(self) -- calculates general direciton car should try to go
    if self.currentNode == nil then
        return self.shape.at 
    end -- maybe instead of at, use goalNode?

    if self.goalNode then
        --print("goalNode")
        --self.goalNode.outVector
    end
    --print(self.goalNode)
    local goalDirection = self.currentNode.outVector -- TODO: Determine if curNode or goalNode is desireable
    return goalDirection
end

function Driver.getBrakingDistance(self,vmax) -- uses self to get approx braking distance 
    local speed = self.speed
    local vmax = toVelocity(vmax)
    local mass = self.mass
    local brakePower = self.engine.engineStats.MAX_BRAKE -- use custom settings like:
    local massAdjust = math.floor(mass/10000) 
    local adjRate = 0.03 -- how much to adjust brake power by
    brakePower = brakePower - (adjRate*massAdjust)
    
    -- Tire type -- soft decreases braking distance
    -- Fuel -- light decreases braking distance
    -- Tire wear -- worn incrases braking distance
    -- Downforce -- high increases braking distance
    -- Use SkillLevel to sliggtly increase/decrease Deceleration_rate by +-1
    if speed <= vmax then -- returns no braking distance because already there
        return 0 -- returjn nil instead?
    end
    -- Ignoring the effects of negative acceleration, calculate distance
    -- Calculate Braking distance based on mass of vehichle
    local top = vmax^2 - speed^2
    local bottom = 2*(brakePower * DECELERATION_RATE)
    local distance = top/bottom
    return distance
end


function Driver.getFutureVMax(self,searchDistance,curNode) -- gets slowest Vmax in set distance (uses self:getVmax)
    -- Look ahead at every node and getVmax until you find the minimum
    local nextNode = curNode
    local minVMax = nil 
    local minNode = curNode
    local timeout = 65 -- Putting cap at 60 nodes ahead to reduce processing
    local searchNode = 0 -- timout COunter
    local atMax = false -- while breaker, maxDistance searched
    while atMax == false and searchNode < timeout do
        nextNode = getNextItem(self.nodeChain,nextNode.id,searchNode) -- including 0 in case currently at slowest point?
        local dist = getDistance(self.location,nextNode.mid)
        local vmax = self:getVmax(nextNode)
        if minVMax == nil or vmax < minVMax then
            minVMax = vmax -- new slowest vmax
            minNode = nextNode
        end

        if dist >= searchDistance then -- at the end of searchDistance
            atMax = true
        end
        searchNode = searchNode + 1
        --print("FutureLook",toVelocity(minVMax))
        if self.speed > toVelocity(minVMax) then
            --print("Too fast")
            return minNode,minVMax
        end
    end
    --print("FutureLookBreakout",toVelocity(minVMax))
    return minNode,minVMax
end
---
--- Vmax mutation functios
function Driver.getVmaxFromDownForce(self,vmax,node)
    -- Higher Downforce increases Vmax on turns but decreases on straights
    -- Lower Downforce does the opposite
    local dfAdj = self.downforce/50 -- Lower the constant ratio to increase speeds
    vmax = vmax + dfAdj
    --TODO: make behavior custom for how much Downforce affects speed?
    return vmax
end

function Driver.getVmaxFromAero(self,vmax,angle)
    --print("1",angle,toVelocity(vmax),self.speed)
    if math.abs(angle) >= 0.2 then -- Corners
        if self.Spoiler_Angle < 5 then -- Decrease vmax on turns
            vmax = vmax - ((5 - self.Spoiler_Angle)*1.2)
        elseif self.Spoiler_Angle > 5 then -- Increase vmax on turns
            vmax = vmax + ((self.Spoiler_Angle - 5)*1.4)
        end

    end
    if angle <= 0.05 then -- Straights
        if self.Spoiler_Angle < 5 then -- increase vmax
            vmax = vmax + ((5 - self.Spoiler_Angle)*4)
        elseif self.Spoiler_Angle > 5 then -- decrease vmax
            vmax = vmax - ((self.Spoiler_Angle - 5 )*1.6)
        end
    end
    return vmax
end


function Driver.getVmaxFromRacingLine(self,vmax,firstNode,lastNode)
    -- The futher away from racing line, the slower it goes (by slightly)
    if self.trackPosition == nil then
        return vmax
    end
    local distFromMiddle = math.abs(self.trackPosition)/1.7  --- TODO: figure out racing line closeness/ trackPos  Adjust max velocity based on closeness to center of track
    local distFromLine = self:calculateRaceLinePos(firstNode) -- TOODO: Determine if this is more important/useful
   
    local reduction = linear_decrease(distFromMiddle,15,0,6)
    local reduction2 = linear_decrease(math.abs(distFromLine),firstNode.width/2,0,7)
    local turnType = getSign(vectorAngleDiff(firstNode.outVector,lastNode.outVector))
    local slowThreshold = firstNode.width/3.5 -- 
    if turnType == getSign(distFromLine) then  -- cars away from line brake more
        if math.abs(distFromLine) > slowThreshold then
            --print(self.tagText,"on inside",distFromLine)
            reduction2 = reduction2 * 1.4
        end
    else
        if math.abs(distFromLine) > slowThreshold then -- Can move this checker outside? of if?
            --print(self.tagText,"on outside",distFromLine)
            reduction2 = reduction2 * 1.3
        end
    end

    if self.offline then -- car offline
        vmax = vmax - 2
    end
    --print(distFromLine,turnType,reduction2)
    vmax = vmax - reduction2
    return vmax
end

function Driver.getVmaxFromBanking(self,vmax,firstNode,lastNode,maxSpeed)
    if firstNode.bank == nil then -- Old scans won't have bank
        return vmax
    end
    local angle = vectorAngleDiff(firstNode.outVector,lastNode.outVector)
    local maxBank = math.max(firstNode.bank,lastNode.bank)
    
    vmax = vmax + maxBank
    if getSign(angle) == getSign(maxBank) then
        vmax = vmax + (maxBank*40) + (maxSpeed/40)
    end
    --print(maxBank,angle,vmax)
    return vmax
end

function Driver.getVmaxFromTrackWidth(self,vmax,node)
    local width = node.width
    local normalizer = 23
    if width > normalizer then 
        width = normalizer
    end
    local normWidth = width/20  -- 25 is typical track width
    
    local newVmax = vmax * normWidth
    vmax = mathClamp(10 + self.Spoiler_Angle,vmax + self.Spoiler_Angle,newVmax) -- clamp it so it doesnt increase speed on wide tracks?
    return vmax
end

function Driver.getVmaxFromCurDif(self,vmax,angle)-- Go fast when at end of turn
    -- if the angle is pretty close then boosst

    if angle < 0.11 + (self.skillLevel/13) then 
        vmax = vmax + (self.skillLevel/2.5) + (self.Spoiler_Angle/10)
        --print("boost",angle,self.skillLevel/1.5)
        return vmax
    end
    return vmax
end

function Driver.getVmaxFromCarsAlongSide(self,vmax)
    if self.carAlongSide.left ~= 0 or self.carAlongSide.right ~= 0 then -- slow down when there is car alongside 
        vMax = vmax - 4
    else
        vMax = vmax + 1 -- speeds up if clear air
    end
    return vmax
end

function Driver.getVmaxFromPassing(self,vmax)
    -- DO more complex calculations like distance from passing opp & position and future turn
    if self.passing.isPassing then 
        vmax = vmax +0.5 -- TODO: Increase along with enginespeed?
    end
    return vmax
end

function Driver.getVmaxFromTireHealth(self,vmax)
    local totalDif = 10 -- maximum speed to reduce 
    local vmaxAdj = totalDif - (totalDif *(self.Tire_Health/100))
    vmax = vmax - vmaxAdj
    return vmax
end

function Driver.getVmaxFromTireType(self,vmax)
    if self.Tire_Type == nil then return end
    local grip = TIRE_TYPES[self.Tire_Type].GRIP
    vmax = vmax + grip
    
    return vmax
end

function Driver.getVmaxFromFuelLevel(self,vmax) 
    -- Decreases vmax based on fuel level
    local vmaxAdj = self.Fuel_Level/25 -- FUll fuel = decrease by 4
    vmax = vmax - vmaxAdj
    return vmax
end

function Driver.getVmaxFromTireTemp(self,vmax) -- Not used yet

end

function Driver.getVmax(self,node) -- Calculates max velocity based on given node
    local chain = self.nodeChain
    if self.pitState >1 and self.pitState <= 7 then
        chain = self.pitChain
        return 50 -- just flat vmax TODO: gety this properly dynamic
    end
    local vmax = 30
    -- First, Get minimimum based on curvature of last 2? 
    local curveDampen = 4 -- How many nodes to check for curve 
    local angleMult = 1
    local firstNode = getNextItem(chain,node.id,-1) -- TODO: Experiment with this to get what works
    local lastNode = getNextItem(chain,node.id,curveDampen)
    local angle = math.abs(vectorAngleDiff(firstNode.outVector,lastNode.outVector))
    local myAngle = math.abs(vectorAngleDiff(self.shape.at,lastNode.outVector))
    local maxSpeed = 130 --(self.engine.engineStats.MAX_SPEED or 80)-- Not necessarily good because bigger engines create bigger ones, needs to be a fixed Point
    local minSpeed = 10 -- arbitrary for now but based off of downforce/tires?
    local curRPM = self.engine.curRPM
    vmax = getVmax2(myAngle,minSpeed,maxSpeed) --gets initial vmax based off of capped speeds
    -- add (or reduce?) vmax based on downforce (artificial real downforce only)
    --vmax = self:getVmaxFromDownForce(vmax,lastNode)-- vmax + 0-- insert downforce ration conversion here
   

    -- add (or reduce) vmax based on self.mass
    vmax = vmax + 0 -- use self.massRatio, decreases (very slightly) based on higher mass, has cap

   
    -- reduce vmax the more inside a car is on racing line
    vmax = self:getVmaxFromRacingLine(vmax,firstNode,lastNode)
    --print(vmax)

    -- increase vmax based on banking
    vmax = self:getVmaxFromBanking(vmax,firstNode,lastNode,maxSpeed)
    --print(vmax)

    -- change vmax based on track width
    vmax = self:getVmaxFromTrackWidth(vmax,lastNode)
    --print("TWadj:",toVelocity(vmax))
    --print(vmax)



    -- change vmax based on output vector and self.curAt Diff
    vmax = self:getVmaxFromCurDif(vmax,myAngle)
    --print(vmax)

    -- change vmax based on the number of cars alongside and close
    vmax = self:getVmaxFromCarsAlongSide(vmax)

    -- change vmax based on If theres dangeroous jump/turn in future?

    -- change cmax based on error states like offtrack/ rejoining/stuck etc
    vmax = vmax + 0
    
    -- change vmax based on passing
    vmax = self:getVmaxFromPassing(vmax)


    -- Tuning based adjustemnts get priority
    -- add (or reduce) vmax based on fuel load
    vmax = self:getVmaxFromFuelLevel(vmax)

    -- get vmax based on spoiler angle -- Fake downforce that reduces on straights
    vmax = self:getVmaxFromAero(vmax,angle)

    -- get Vmax based on tire wear
    vmax = self:getVmaxFromTireHealth(vmax)

    -- get vmax based on tire type
    vmax = self:getVmaxFromTireType(vmax)


    --print('vm',vmax )
    -- Do any clamping for engine based params?
    vmax = mathClamp(minSpeed,maxSpeed,vmax)
    --print(self.tagText,"final",toVelocity(vmax),self.speed)
    return vmax 
end



-- TODO: Do ALL follow priority logic here TODO: Depreciate
function Driver.calculatePriorities_Deprceciating(self) -- calculates steering priorities for 
    if self.goalNode == nil then return 0 end
    if self.currentNode == nil then return 0 end 
    local lookaheadDist = 3 -- How many extra nodes to look ahead to determine priorities
    local checkNode = self.nodeChain[getNextIndex(#self.nodeChain,self.currentNode.id,lookaheadDist)]
    local segLen = self:getSegmentLength(checkNode.segID)
    --print(segLen)
    -- TODO: get RampStatus (z ><0.1?)
    -- TODO: break this up into situational functions. EG: "Straight to left, straight to right?>"
    --self.biasFollowPriority = rampToGoal(0.1,self.biasFollowPriority,0.01) This is mutated in processFlags
    --print(self.tagText,self.collGoalOffsetStrength* self.collFollowPriority)
    if self.racing == false then
        self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.1)
        self.biasFollowPriority = rampToGoal(0,self.biasFollowPriority,0.1)
        self.passFollowPriority = rampToGoal(0.,self.passFollowPriority,0.1)
        self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.1)

    elseif self.caution then
        if self.raceRestart then
            self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.001) -- set to 0??
            self.biasFollowPriority = rampToGoal(0.8,self.biasFollowPriority,0.001)
            self.passFollowPriority = rampToGoal(0.9,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        else
            self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.001)
            self.biasFollowPriority = rampToGoal(1,self.biasFollowPriority,0.01)
            self.passFollowPriority = rampToGoal(0.3,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        end
    elseif self.formation then
        if self.raceRestart then -- when turns green
            self.nodeFollowPriority = 0--rampToGoal(0,self.nodeFollowPriority,0.2) -- set to 0??
            self.biasFollowPriority = rampToGoal(0,self.biasFollowPriority,0.001)
            self.passFollowPriority = rampToGoal(0.7,self.passFollowPriority,0.001)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        else
            self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.01)    
            self.biasFollowPriority = rampToGoal(1,self.biasFollowPriority,0.01)
            self.passFollowPriority = rampToGoal(.7,self.passFollowPriority,0.01) -- THis might be unecessary
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        end

    else -- while racing
        if checkNode.segType == "Straight" or checkNode.segType == "Fast_Left" or checkNode.segType == "Fast_Right" or segLen > 20 then -- Racing and on straight
            if self.passing.isPassing then -- If passing
                if math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0 then -- if a car is alongside, TODO: go into depth of where exactly car is and what turn it is, EG: If turning left and a car on left, depengin on how close it is, loosen turn, if car on right, tighten turn?)
                    self.nodeFollowPriority = rampToGoal(0.25,self.nodeFollowPriority,0.01)
                    self.biasFollowPriority = rampToGoal(0.6,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.8,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.01) -- unsure what to do with this
                else
                    self.nodeFollowPriority = rampToGoal(0.3,self.nodeFollowPriority,0.01)
                    self.biasFollowPriority = rampToGoal(0.6,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.9,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.1) -- unsure what to do with this
                end

            else -- Not passing
                if math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0 then -- if a car is alongside,
                    self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.01)
                    self.biasFollowPriority = rampToGoal(0.6,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.1,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0.5,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.01) -- unsure what to do with this
                else -- No cars alongside
                    self.nodeFollowPriority = rampToGoal(0.3,self.nodeFollowPriority,0.01)
                    self.biasFollowPriority = rampToGoal(0.6,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.1,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0.8,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.1) -- unsure what to do with this
                end
            end
        else -- If turning: tighten node priority, loosen pass
            if self.passing.isPassing then -- Get looser while passing
                if  math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0  then -- if a car is alongside,
                    self.nodeFollowPriority = rampToGoal(1.1,self.nodeFollowPriority,0.004)
                    self.biasFollowPriority = rampToGoal(0.1,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.4,self.passFollowPriority,0.02) --?? what do here
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.001) -- unsure what to do with this
                else
                    self.nodeFollowPriority = rampToGoal(0.9,self.nodeFollowPriority,0.004) -- TODO: base it on track width too?
                    self.biasFollowPriority = rampToGoal(0.2,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.4,self.passFollowPriority,0.005)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.01) -- unsure what to do with this
                end
            else -- if not passing  while on a turn
                if math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0  then -- if a car is alongside, prioritize node follow left
                    self.nodeFollowPriority = rampToGoal(1.1,self.nodeFollowPriority,0.004)
                    self.biasFollowPriority = rampToGoal(0.1,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.2,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.001) -- unsure what to do with this
                else
                    self.nodeFollowPriority = rampToGoal(0.9,self.nodeFollowPriority,0.004)
                    self.biasFollowPriority = rampToGoal(0.1,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.2,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.001) -- unsure what to do with this
                end
            end
        end 

        if self.rotationCorrect then -- TODO: lessen rotationCorrect sensitivity
            --print(self.tagText,"rotation",self.nodeFollowPriority)
            --self.nodeFollowPriority = rampToGoal(0.5,self.nodeFollowPriority,0.01)
            --self.biasFollowPriority = rampToGoal(0.1,self.biasFollowPriority,0.01)
            --self.passFollowPriority = rampToGoal(0.01,self.passFollowPriority,0.01)
            --self.draftFollowPriority = rampToGoal(0.1,self.draftFollowPriority,0.01)
        end

        
        if self.goalOffsetCorrecting then -- TODO: lessen rotationCorrect sensitivity
            --print(self.tagText,"correcting goal Offset",self.nodeFollowPriority)
            self.nodeFollowPriority = rampToGoal(0.1,self.nodeFollowPriority,0.01)
            self.biasFollowPriority = rampToGoal(0.3,self.biasFollowPriority,0.01)
            self.passFollowPriority = rampToGoal(0.4,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0.1,self.draftFollowPriority,0.01)
        end

        if self.offtrack then
            print(self.tagText,"correcting offtrack",self.nodeFollowPriority)
            self.passFollowPriority = rampToGoal(0,self.passFollowPriority,0.01)
            self.biasFollowPriority = rampToGoal(0,self.biasFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
            -- TODO: measure how far off track
            self.nodeFollowPriority = rampToGoal(2,self.nodeFollowPriority,0.1)
        end

        if self.rejoining then 
            self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.1)
        end

        if self.raceFinished then -- at end of race
            self.nodeFollowPriority = rampToGoal(0.4,self.nodeFollowPriority,0.1)
            self.biasFollowPriority = rampToGoal(1,self.biasFollowPriority,0.1)
            self.passFollowPriority = rampToGoal(0.1,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
        end
    end
    -- testing
    --self.biasFollowPriority = rampToGoal(0,self.biasFollowPriority,0.01)
    --self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.001)
    --self.draftFollowPriority = 1 --rampToGoal(2,self.draftFollowPriority,0.01)
    --self.passFollowPriority = rampToGoal(0,self.nodeFollowPriority,0.01)

    -- Printing
    -- priorities
    --[[print(string.format("%26.26s",self.tagText) .. ": " .. "n: " .. string.format("%.3f",self.nodeFollowPriority).. " b: " .. string.format("%.3f",self.biasFollowPriority) .. " p: " .. string.format("%.3f",self.passFollowPriority) ..
    " d: " .. string.format("%.3f",self.draftFollowPriority) .. " c: " .. string.format("%.3f",self.collFollowPriority))
    -- values
    local totalOffset = (self.passGoalOffsetStrength * self.passFollowPriority) + (self.biasGoalOffsetStrength * self.biasFollowPriority) + (self.collGoalOffsetStrength * self.collFollowPriority) + (self.draftGoalOffsetStrength * self.draftFollowPriority)

    --print(string.format("%26.26s"," ") .. "  " .. " : " .. string.format("%.3f",self.strategicSteering).. "  : " .. string.format("%.3f",self.biasGoalOffsetStrength) .. "  : " .. string.format("%.3f",self.passGoalOffsetStrength) ..
    " d: " .. string.format("%.3f",self.draftGoalOffsetStrength) .. " : " .. string.format("%.3f",self.collGoalOffsetStrength))
    ]]
end



-- TODO: Do ALL follow priority logic here
function Driver.calculatePriorities2(self) -- New version for updated node 
    if self.goalNode == nil then return 0 end
    if self.currentNode == nil then return 0 end 
    local lookaheadDist = 3 -- How many extra nodes to look ahead to determine priorities
    local checkNode = self.nodeChain[getNextIndex(#self.nodeChain,self.currentNode.id,lookaheadDist)]
    local segLen = self:getSegmentLength(checkNode.segID)
    --print(segLen)
    -- TODO: get RampStatus (z ><0.1?)
    -- TODO: break this up into situational functions. EG: "Straight to left, straight to right?>"
    --self.biasFollowPriority = rampToGoal(0.1,self.biasFollowPriority,0.01) This is mutated in processFlags
    --print(self.tagText,self.collGoalOffsetStrength* self.collFollowPriority)
    if self.racing == false then
        self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.1)
        self.biasFollowPriority = rampToGoal(0,self.biasFollowPriority,0.1)
        self.passFollowPriority = rampToGoal(0.,self.passFollowPriority,0.1)
        self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.1)

    elseif self.caution then
        if self.raceRestart then
            self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.001) -- set to 0??
            self.biasFollowPriority = rampToGoal(0.8,self.biasFollowPriority,0.001)
            self.passFollowPriority = rampToGoal(0.9,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        else
            self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.001)
            self.biasFollowPriority = rampToGoal(1,self.biasFollowPriority,0.01)
            self.passFollowPriority = rampToGoal(0.3,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        end
    elseif self.formation then
        if self.raceRestart then -- when turns green
            self.nodeFollowPriority = 0--rampToGoal(0,self.nodeFollowPriority,0.2) -- set to 0??
            self.biasFollowPriority = rampToGoal(0,self.biasFollowPriority,0.001)
            self.passFollowPriority = rampToGoal(0.7,self.passFollowPriority,0.001)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        else
            self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.01)    
            self.biasFollowPriority = rampToGoal(1,self.biasFollowPriority,0.01)
            self.passFollowPriority = rampToGoal(.7,self.passFollowPriority,0.01) -- THis might be unecessary
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
        end

    else -- while racing
        -- TODO: Make this Speed based instead
        
        if checkNode.segType == "Straight" or checkNode.segType == "Fast_Left" or checkNode.segType == "Fast_Right" or segLen > 20 then -- Racing and on straight
            if self.passing.isPassing then -- If passing on a straight or shallow turn
                if math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0 then -- if a car is alongside, TODO: go into depth of where exactly car is and what turn it is, EG: If turning left and a car on left, depengin on how close it is, loosen turn, if car on right, tighten turn?)
                    self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.01)
                    self.biasFollowPriority = rampToGoal(0.4,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.6,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.01) -- unsure what to do with this
                else -- no cars alongside
                    self.nodeFollowPriority = rampToGoal(0.3,self.nodeFollowPriority,0.001)
                    self.biasFollowPriority = rampToGoal(0.7,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.7,self.passFollowPriority,0.005)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.1) -- unsure what to do with this
                end

            else -- Not passing
                if math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0 then -- if a car is alongside,
                    self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.01)
                    self.biasFollowPriority = rampToGoal(0.5,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.1,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0.5,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.01) -- unsure what to do with this
                else -- No cars alongside
                    self.nodeFollowPriority = rampToGoal(0.45,self.nodeFollowPriority,0.001)
                    self.biasFollowPriority = rampToGoal(0.6,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.1,self.passFollowPriority,0.005)
                    self.draftFollowPriority = rampToGoal(0.7,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.1) -- unsure what to do with this
                end
            end
        else -- If turning: tighten node priority, loosen pass
            if self.passing.isPassing then -- Get looser while passing
                if  math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0  then -- if a car is alongside,
                    self.nodeFollowPriority = rampToGoal(0.65,self.nodeFollowPriority,0.002)
                    self.biasFollowPriority = rampToGoal(0.4,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.6,self.passFollowPriority,0.001) --?? what do here
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.001)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.001) -- unsure what to do with this
                else
                    self.nodeFollowPriority = rampToGoal(0.75,self.nodeFollowPriority,0.005) -- TODO: base it on track width too?
                    self.biasFollowPriority = rampToGoal(0.4,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.65,self.passFollowPriority,0.005)
                    self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.01) -- unsure what to do with this
                end
            else -- if not passing  while on a turn
                if math.abs(self.carAlongSide.left) > 0 or math.abs(self.carAlongSide.right) > 0  then -- if a car is alongside, prioritize node follow left
                    self.nodeFollowPriority = rampToGoal(0.75,self.nodeFollowPriority,0.005)
                    self.biasFollowPriority = rampToGoal(0.50,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.1,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0.1,self.draftFollowPriority,0.001)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.001) -- unsure what to do with this
                else
                    self.nodeFollowPriority = rampToGoal(0.80,self.nodeFollowPriority,0.002)
                    self.biasFollowPriority = rampToGoal(0.5,self.biasFollowPriority,0.001)
                    self.passFollowPriority = rampToGoal(0.1,self.passFollowPriority,0.001)
                    self.draftFollowPriority = rampToGoal(0.3,self.draftFollowPriority,0.001)
                    self.collFollowPriority = rampToGoal(0,self.collFollowPriority,0.001) -- unsure what to do with this
                end
            end
        end 
        if checkNode.bank ~= nil and math.abs(checkNode.bank) >= 0.1 then -- takes priority
            self.nodeFollowPriority = rampToGoal(0.5,self.nodeFollowPriority,0.003)
        end
        
        if checkNode.incline ~= nil then
            self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.002)
        end

        if self.rotationCorrect then -- TODO: lessen rotationCorrect sensitivity
            --print(self.tagText,"rotation",self.nodeFollowPriority)
            --self.nodeFollowPriority = rampToGoal(0.5,self.nodeFollowPriority,0.01)
            --self.biasFollowPriority = rampToGoal(0.1,self.biasFollowPriority,0.01)
            --self.passFollowPriority = rampToGoal(0.01,self.passFollowPriority,0.01)
            --self.draftFollowPriority = rampToGoal(0.1,self.draftFollowPriority,0.01)
        end

        
        if self.goalOffsetCorrecting then -- TODO: lessen rotationCorrect sensitivity
            --print(self.tagText,"correcting goal Offset",self.nodeFollowPriority)
            self.nodeFollowPriority = rampToGoal(0.1,self.nodeFollowPriority,0.005)
            self.biasFollowPriority = rampToGoal(0.3,self.biasFollowPriority,0.01)
            self.passFollowPriority = rampToGoal(0.4,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0.1,self.draftFollowPriority,0.01)
        end

        if self.offtrack or self.offline then
           -- print(self.tagText,"correcting offtrack",self.nodeFollowPriority)
            self.passFollowPriority = rampToGoal(0.5,self.passFollowPriority,0.001)
            self.biasFollowPriority = rampToGoal(1,self.biasFollowPriority,0.001)
            self.draftFollowPriority = rampToGoal(0,self.draftFollowPriority,0.01)
            -- TODO: measure how far off track
            self.nodeFollowPriority = rampToGoal(0.4,self.nodeFollowPriority,0.005)
        end

        if self.rejoining then 
            self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.01)
        end

        if self.raceFinished then -- at end of race
            self.nodeFollowPriority = rampToGoal(0.2,self.nodeFollowPriority,0.01)
            self.biasFollowPriority = rampToGoal(1,self.biasFollowPriority,0.01)
            self.passFollowPriority = rampToGoal(0.01,self.passFollowPriority,0.01)
            self.draftFollowPriority = rampToGoal(0.1,self.draftFollowPriority,0.01)
        end
    end
    -- testing
    --self.biasFollowPriority = rampToGoal(0,self.biasFollowPriority,0.01)
    --self.nodeFollowPriority = rampToGoal(1,self.nodeFollowPriority,0.001)
    --self.draftFollowPriority = 1 --rampToGoal(2,self.draftFollowPriority,0.01)
    --self.passFollowPriority = rampToGoal(0,self.nodeFollowPriority,0.01)

    -- Printing
    -- priorities
    --[[print(string.format("%26.26s",self.tagText) .. ": " .. "n: " .. string.format("%.3f",self.nodeFollowPriority).. " b: " .. string.format("%.3f",self.biasFollowPriority) .. " p: " .. string.format("%.3f",self.passFollowPriority) ..
    " d: " .. string.format("%.3f",self.draftFollowPriority) .. " c: " .. string.format("%.3f",self.collFollowPriority))
    -- values
    local totalOffset = (self.passGoalOffsetStrength * self.passFollowPriority) + (self.biasGoalOffsetStrength * self.biasFollowPriority) + (self.collGoalOffsetStrength * self.collFollowPriority) + (self.draftGoalOffsetStrength * self.draftFollowPriority)

    --print(string.format("%26.26s"," ") .. "  " .. " : " .. string.format("%.3f",self.strategicSteering).. "  : " .. string.format("%.3f",self.biasGoalOffsetStrength) .. "  : " .. string.format("%.3f",self.passGoalOffsetStrength) ..
    " d: " .. string.format("%.3f",self.draftGoalOffsetStrength) .. " : " .. string.format("%.3f",self.collGoalOffsetStrength))
    ]]
end

function Driver.calculateTrackPosBiasTurn(self) --[Unused] tries to make more efficient apex for attacking/defending Uses steering
    if self.currentNode == nil or self.goalNode == nil then return end
    if self.currentNode.width == nil then self.currentNode.width = 20 end
    --print(self.futureLook)
    local nextTurnDir = getSign(self.futureLook.direction)
    local distFromTurn = self.futureLook.distance
    local segLen = self:getSegmentLength(self.currentNode.segID)-- TODO: reduce ammount of seglen calculation (future)
    local selfWidth = self.leftColDist + self.rightColDist
    local sideLane = (self.currentNode.width/2 - selfWidth) -- + margin?
    local offsetBias = 0 
    --print(distFromTurn,self.futureLook)   
    if not self.passing.isPassing or self.understeer or self.oversteer then -- have one specific for rejoins?
        if self.currentNode.segType == "Straight" and segLen > 30 then-- if on long straight
            if distFromTurn > 20 then -- and segLength > 50
                if nextTurnDir == 1 then-- if supposed to turn right
                    local leftOffset = sideLane + self.trackPosition
                    offsetBias = ratioConversion(0,self.currentNode.width,3,0,leftOffset)
                    --print("LeftOffset",self.trackPosition,sideLane,leftOffset,offsetBias)
                elseif nextTurnDir == -1 then-- if supposed to turn right
                    local rightOffset = sideLane - self.trackPosition
                    offsetBias = ratioConversion(0,self.currentNode.width,3,0,rightOffset)
                    --print("rightOffset",rightOffset,offsetBias)
                else -- if no future turns just stay in the middle -- SHOULD USE FOR FORMATION LAPS AND STUFF
                    local offset = 0 + self.trackPosition
                    offsetBias = ratioConversion(0,self.currentNode.width,0,0.15,offset)
                end
            end
        end
    end

    if offsetBias > 4 then
        if self.goalNode.segType == "Straight" and self.followStrength > 2 then
            offsetBias = offsetBias * 1.5
        else   
            offsetBias = 4
        end
        print("compensate",offsetBias)
    end
    -- TODO: CHeck for car behind, Go "defensive if radar is less than 20"
    return offsetBias * -nextTurnDir -- TODO: FIgure out solution for turnDir being 0
end

function Driver.calculateTrackPosBiasNode(self) -- tries to make more efficient apex for attacking/defending, Uses Node shifting TODO: Needs a lot of work
    if self.currentNode == nil or self.goalNode == nil then return end
    if self.currentNode.width == nil then self.currentNode.width = 20 end
    --print(self.futureLook)
    local nextTurnDir = getSign(self.futureLook.direction)
    local distFromTurn = self.futureLook.distance
    local selfWidth = self.leftColDist + self.rightColDist
    local sideLane = (self.currentNode.width/2 - selfWidth) -- + margin?
    local offsetBias = 0
    local shiftDir = nil -- will be a vector
    --print(distFromTurn)   
    if not self.passing.isPassing or self.understeer or self.oversteer then -- have one specific for rejoins?
        if self.currentNode.segType == "Straight" then-- if on straight
            if distFromTurn > 10 then -- and segLength > 50
                if nextTurnDir == 1 then-- if supposed to turn right
                    local leftOffset = sideLane + self.trackPosition
                    offsetBias = ratioConversion(0,self.currentNode.width,4,0,leftOffset)
                    shiftDir = self.goalNode.perp * (-nextTurnDir * offsetBias)
                    print("LeftOffset",self.trackPosition,sideLane,leftOffset,offsetBias)
                elseif nextTurnDir == -1 then-- if supposed to turn right
                    local rightOffset = sideLane - self.trackPosition
                    offsetBias = ratioConversion(0,self.currentNode.width,4,0,rightOffset)
                    shiftDir = self.goalNode.perp * (nextTurnDir * offsetBias)
                    --print("rightOffset",rightOffset,offsetBias)
                else -- if no future turns just stay in the middle -- SHOULD USE FOR FORMATION LAPS AND STUFF
                    local offset = 0 + self.trackPosition
                    offsetBias = ratioConversion(0,self.currentNode.width,0,0.15,offset)
                    shiftDir = self.goalNode.perp * (nextTurnDir * offsetBias)
                end
            end
        end
    end
    self.goalNode.location = self.goalNode.location +  (shiftDir or sm.vec3.new(0,0,0))
    return 
   
end


-- Networking
function Driver.sv_recieveCommand(self,command) -- recieves various commands from race control
    if command == nil then return end
    --print(self.id,"revieved command",command)
    if command.type == "raceStatus" then --TODO: make these send out individual commands instead of toggle here
        if command.value == 1 then -- start race
            self.stuckCooldown = {true, self.location}
            self.safeMargin = false -- just starting out race
            self.racing = true
            if self.caution or self.formation then -- if previously in caution or formation then
                self.raceRestart = true
                self.trackPosBias = 0 -- reset this
                self.followStrength = 4 -- reset followstrength too?
            else
                self.caution = false
                self.formation = false
            end
        elseif command.value == 0 then -- Stop race
            self.raceRestart = false
            self.racing = false
            self.caution = false
            self.formation = false
        elseif command.value == 3 then -- formation lap
            --self:determineRacePos()
            self.stuckCooldown = {true, self.location}
            self.racing = true -- ??
            self.formation = true 
            self.caution = false --??
            self.raceRestart = false
        elseif command.value == 2 then -- Caution flag
            self.stuckCooldown = {true, self.location}
            --self:determineRacePos()
            self.racing = true -- ??
            self.formation = false 
            self.caution = true --??
            self.raceRestart = false
            -- Confirm caution pos
            --print("Checking pos",self.racePosition)
            self.cautionPos = self.racePosition -- might need thing to tiebreak

        end
    elseif command.type == "handicap" then -- set car handicap (idk why i'm not setting directly...)
        self.handicap = command.value
    elseif command.type == "resetRace" then -- Reset Car
        self.handicap = self:sv_hard_reset()
    elseif command.type == "pit" then -- Reset Car
        local strategy = command.value
        self:sv_setup_pit(strategy)
    end
end

function Driver.sv_sendCommand(self,command) --sends command to race control
    local raceControl = getRaceControl()
    if raceControl == nil then
        if not self.raceControlError then
            print("No race Control")
            self.raceControlError = true
        end
        return
    end
    raceControl:sv_recieveCommand(command)
end


function Driver.sv_sendAlert(self,msg) -- sends alert message to all clients (individual clients not recognized yet)
    self.network:sendToClients("cl_showAlert",msg)
end

function Driver.cl_showAlert(self,msg) -- client recieves alert
    print("Displaying",msg)
    sm.gui.displayAlertText(msg,3)
end

function Driver.sv_sendChatMessage(self,msg) -- shows chat messgae on clients
    self.network:sendToClients("cl_showChatMessage",msg)
end

function Driver.cl_showChatMessage(self,msg)
    sm.gui.chatMessage(msg)
end

-- Car position checking and updating

function Driver.handleLapCross(self)
    if self.newLap == false then
        self.newLap = true
        self.currentLap = self.currentLap + 1 -- and then do other lap stuff here too TODO: Ensure it only crosses once
        --local lineOffset = offsetAlongVector(frontLocation,startLine,buffer) -- use outvector instead
        --local dif = frontLocation.y - startLine.location.y -- TODO: store this difference and use it to dispute photo finishes
        
        now = CLOCK()
        local lapTime = now - (self.lapStarted or 0)
        -- average time
        if self.currentLap > 1 then -- only start after full hotlap also can hijack if bestLappExists
            self.lapAverage = runningAverage(self,lapTime)
        end
        self.lapStarted = now
        local split = 0
        -- finish sector
        self.sectorTimes[3] =  now - self.sectorStartTime
        self.sectorStartTime = now
        self.currentSector = 1 -- reset sector
        -- reset pit in and out stuff
        if self.pitIn == true then self.pitIn = false end
        if self.pitOut == true then self.pitOut = false end
        -- check if first car to cross
        if not self.raceControlError then -- TODO: crosscheck with race control by lap and crossover time
            --print(self.currentLap,getRaceControl().currentLap,self.racePosition)
            if self.currentLap > getRaceControl().currentLap and self.racePosition > 1 then
                if getRaceControl().leaderID == nil then
                    print(self.id,"Confirmed leader nil lead",now)
                    self.racePosition = 1
                else
                    --print(self.id, "possibly first instead",self.racePosition)
                    if getDriverFromId(getRaceControl().leaderID).currentLap < self.currentLap then
                        print(self.id,"Confirmed leader over",getRaceControl().leaderID,now)
                        self.racePosition = 1
                    end
                end
            end

            if getRaceControl().leaderTime ~= nil then

                split = now - getRaceControl().leaderTime 
                -- Determine race positions based off of split
                
                if self.racePosition == 1 then 
                    split = 0
                end
            end
            if self.bestLap == 0 then
                --print("Initial best lap")
                if self.currentLap > 1 then -- Lap 1 doesnt count, warmup lap
                    self.bestLap = lapTime
                end
            elseif lapTime < self.bestLap  then
                --print("New best lap!",split)
                self.bestLap = lapTime
            end

            
            if self.currentLap < getRaceControl().currentLap then
                self:determineRacePosBySplit()
            else
                self.raceSplit = split
                self:determineRacePosBySplit()
            end
            
            self.lastLap = lapTime
            local tireDif = self.lastTireHealth - self.Tire_Health
            self.lastTireHealth = self.Tire_Health

            local fuelDif = self.lastFuelLevel - self.Fuel_Level
            self.lastFuelLevel = self.Fuel_Level

            self:sv_sendCommand({car = self.id, type = "lap_cross", value = now}) -- maybe calculate dif between laps? keep running avg?
            if self.racePosition == 1 then print() end -- separator
            local output = string.format("%26.26s",self.tagText) .. ": " .. "Pos: " .. string.format("%2.2s",self.racePosition).. " Lap: " .. self.currentLap .. " Split: " .. string.format("%6.3f",split) ..
                          " Last: " .. string.format("%.3f",lapTime) .. " Best: " .. string.format("%.3f",self.bestLap ) .. " Average: " .. string.format("%.3f",self.lapAverage) .. 
                          " | Tires: " .. string.format("%.2f",self.Tire_Health) .. " TDIF: " .. string.format("%.2f",tireDif) .. " Fuel: " .. string.format("%.2f",self.Fuel_Level) .. " FDIF: " .. string.format("%.2f",fuelDif) ..
                          " | S1: " .. string.format("%.3f",self.sectorTimes[1]) .. " S2: " .. string.format("%.3f",self.sectorTimes[2]) .. " S3: " .. string.format("%.3f",self.sectorTimes[3])
            --print(self.id,self.racePosition,self.handicap,lapTime,split)
            sm.log.info(output)

            self:clearLapTelemetry()
        end
    end
end




-- --- Optimized handleLapCross
function Driver.handleLapCross(self)
    -- Ensure the lap is processed only once
    if self.newLap then return end

    self.newLap = true
    self.currentLap = self.currentLap + 1 
    
    local now = CLOCK()
    local lapTime = now - (self.lapStarted or 0)
    
    -- 1. Timing and Sector Updates
    self:updateLapTiming(now, lapTime)
    
    -- 2. Leader and Position Management
    local raceControl = getRaceControl()
    local split = self:updateRacePosition(now, raceControl)

    -- 3. Best Lap Update
    self:updateBestLap(lapTime)
    
    -- 4. Final Position and Data Storage
    self.raceSplit = split
    
    -- Determine position based on the current split value
    -- The split is either 0 (leader), calculated against the leader, or based on the previous lap's position if we're catching up.
    self:determineRacePosBySplit() 
    
    -- 5. Data Logging and Telemetry
    self.lastLap = lapTime
    self:logAndSendCommand(now, lapTime, split)
    
    self:clearLapTelemetry()
end

function Driver.updateLapTiming(self, now, lapTime)
    -- Calculate and update running average time (only after first lap)
    if self.currentLap > 1 then
        self.lapAverage = runningAverage(self, lapTime)
    end
    self.lapStarted = now

    -- Finish sector 3, reset sector
    self.sectorTimes[3] = now - self.sectorStartTime
    self.sectorStartTime = now
    self.currentSector = 1 
    
    -- Reset pit status
    self.pitIn = false
    self.pitOut = false
end


function Driver.updateRacePosition(self, now, raceControl)
    local split = 0
    if not raceControl then return 0 end
    if not self.raceControlError then 
        --[[ TODO: Verify if this block is needed
        -- Check if the car should become the new leader (crossed before the old leader)
        if self.currentLap > raceControl.currentLap and self.racePosition > 1 then
            local leaderDriver = raceControl.leaderID and getDriverFromId(raceControl.leaderID)

            if not leaderDriver or leaderDriver.currentLap < self.currentLap then
                -- Confirmed new leader
                local reason = leaderDriver and "over" or "nil lead"
                print(self.id, "Confirmed leader", reason, raceControl.leaderID or "", now)
                self.racePosition = 1
            end
        end
        ]]

        -- Calculate split time relative to the current race leader
        if raceControl.leaderTime ~= nil then
            split = now - raceControl.leaderTime 
            
            -- If this car IS the leader, split is zero.
            if self.racePosition == 1 then 
                split = 0
            end
        end
    end
    
    return split
end

function Driver.updateBestLap(self, lapTime)
    local isWarmupLap = (self.currentLap <= 1)
    
    if isWarmupLap then return end -- Lap 1 doesn't count
    
    if self.bestLap == 0 or lapTime < self.bestLap then
        -- Optional: print("New best lap!", lapTime)
        self.bestLap = lapTime
    end
end

function Driver.logAndSendCommand(self, now, lapTime, split)
    -- Prepare data for logging
    local tireDif = self.lastTireHealth - self.Tire_Health
    self.lastTireHealth = self.Tire_Health

    local fuelDif = self.lastFuelLevel - self.Fuel_Level
    self.lastFuelLevel = self.Fuel_Level

    -- Send command to server (assuming sv_sendCommand is defined)
    self:sv_sendCommand({car = self.id, type = "lap_cross", value = now}) 

    if self.racePosition == 1 then print() end -- Leader separator

    -- Formatted log output
    local output = string.format(
        "%26.26s: Pos: %2.2s Lap: %d Split: %6.3f Last: %.3f Best: %.3f Average: %.3f | Tires: %.2f TDIF: %.2f Fuel: %.2f FDIF: %.2f | S1: %.3f S2: %.3f S3: %.3f",
        self.tagText, self.racePosition, self.currentLap, split, 
        lapTime, self.bestLap, self.lapAverage, 
        self.Tire_Health, tireDif, self.Fuel_Level, fuelDif,
        self.sectorTimes[1], self.sectorTimes[2], self.sectorTimes[3]
    )
    
    sm.log.info(output)
end

-----



function Driver.checkLapCross(self) -- also sets racePOS -- will need to get updated whenn pit chain gets added
    if self.nodeChain == nil then return end
    if self.location == nil then return end
    if self.currentNode == nil then return end
    if self.carDimensions == nil then return end
    if getRaceControl() == nil then return end
    local startLine = self.nodeChain[1]
    local sideWidth = startLine.width/1.8 -- Add a little padding to the sides
    if startLine == nil then
        print("cant find start line")
    end
    -- TODO Split this into separate functions 
    local axis = sm.vec3.closestAxis(startLine.perp) -- Doesnt necessarily   need to be axis, could just be perp
    local buffer = sm.vec3.closestAxis(startLine.outVector)*4 -- Multiply for faster cars or laggier races
    local wall1 = startLine.location + (axis * sideWidth)
    local wall2 = startLine.location + (axis * -sideWidth) -- TODO: store in nodeMap or self instead of calculating every time...
    local bound = {left = wall1, right = wall2, buffer = buffer}
    --local 
    local frontLocation = self.location + (self.shape:getAt() *  self.carDimensions['front']:length()) -- check for linecross of this loc
    local crossing = withinBound(frontLocation,bound)
    --print(self.newLap,crossing)
    local now
    
    if crossing then self:handleLapCross() end
    
    --[[
    if self.raceFinished and self.displayResults and not self.resultsDisplayed then
        local displayString = "#aa7777"..self.tagText .. "#FFFFFF: Position: #00aa00" ..self.racePosition .. " #ffffffSplit: #aaaa00".. string.format("%.3f",self.raceSplit) .. " #ffffffBest: #aaaa00" .. string.format("%.3f",self.bestLap)
        --print(displayString)
        self:sv_sendChatMessage(displayString) -- TODO: uncomment this before pushing to production
        self.resultsDisplayed = true
        -- Show Data on NameTag too?
    end
    ]]
    
    if self.currentNode.id < (#self.nodeChain/2) +1 and self.currentNode.id > (#self.nodeChain/2) -1 and self.newLap == true then -- TODO: find more dynamic sweet spot
        self.newLap = false
    end
    --print(self.id,self.racePosition)
end

function Driver.determineRacePos_old(self) -- constantly? checks car nodes, laps and positions to determine who is in the lead
    if self.raceFinished then return end-- dont update racePosition
    local leader = nil
    local leaderNodes = nil
    local racePos = 1  -- default to first
    drivers = getAllDrivers()
    if drivers == nil or #drivers == 0 then
        print("No drivers found")
    end
    for k=1, #ALL_DRIVERS do local racer=ALL_DRIVERS[k]
        if racer.id ~= self.id then -- if not self 
            --print(racer.id,racer.totalNodes,self.totalNodes,self.currentLap,racer.currentLap)
            if racer.totalNodes > self.totalNodes or racer.currentLap > self.currentLap then -- if competitor has hit more nodes than self
                racePos = racePos + 1
                
            elseif racer.totalNodes == self.totalNodes then
                if self.opponentFlags[racer.id] ~= nil then
                    local vhDif = self.opponentFlags[racer.id].vhDist -- Should probably do relative to track and not car direction
                    if vhDif.vertical > 0 then -- if opp is in front, stay down pos
                        racePos = racePos + 1
                        --print(self.id,"behind",vhDif.vertical,racePos)
                    end
                else
                    --print("opp not found")
                end
            end
        end
    end
    --print(self.id,self.racePosition)
    if self.racePosition ~= racePos then
        --print(self.id,racePos)
        self.racePosition = racePos
    end

    if self.racePosition == 1 then -- New leader
        if not self.raceControlError then 
            getRaceControl().leaderID = self.id
        end
    end
    if self.racePosition > #drivers then
        print("Race position not propelry set",self.racePosition,#drivers)
    end

end


function Driver.determineRacePosBySplit(self)
    -- Delegate the responsibility of sorting and ranking to the central race control
    local raceControl = getRaceControl()
    -- Assuming ALL_DRIVERS table is available to raceControl
    raceControl:recalculateAllRacePositions()
end

function Driver.checkCautionPos(self) -- goes through and makes sure theres no duplicates
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
        local curPos = self.cautionPos
        if v.id ~= self.id then -- not same
            if v.cautionPos == curPos then
                --print("caution collision")
                self:sv_sendCommand({car = {self.id}, type = "set_caution_pos", value = 1})
            end
        end
    end
    --print("Set caution Positions")
end

function Driver.checkFormationPos(self)
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
        local curPos = self.formationPos
        if v.id ~= self.id then -- not same
            if v.formationPos == curPos then
                print("Formation collision")
                self:sv_sendCommand({car = {self.id}, type = "set_formation_pos", value = 1})
            end
        end
    end
end


function Driver.handleFuelUsage(self) -- decreases fuel ammount based on RPM and spoiler angle? some ratio since increased angle creates more drag, requires more usage with lower gears
    if getRaceControl() == nil then return end
    if getRaceControl() and getRaceControl().fuelUsageEnabled == false then return end
    if self.engine == nil then return end
    local usageRate = getRaceControl().fuelUsageMultiplier
    -- Steeper spoiler angle = increased drag = more fuel used
    local dragCoeficient = 30 -- speed at which drag starts
    local dragMultiplier = 1
    if self.speed > dragCoeficient then 
        if self.drafting then -- decrease drag
            dragMultiplier = 1 + (self.speed - dragCoeficient)/10000 -- reduce to nothing lol
        else
            dragMultiplier = 1 + (self.speed - dragCoeficient)/1000
        end
    end
    local decreaseRate = (self.engine.curRPM/90000) + ((self.speed) * (ratioConversion(10,1,0.000001,0.0000010,self.Spoiler_Angle)* dragMultiplier)) * usageRate

    if self.speed < 15 then -- cut fuel use in half at slow speeds
        decreaseRate = decreaseRate / 2
    end

    self.Fuel_Level = self.Fuel_Level - (decreaseRate * usageRate)
    --print(self.tagText,self.engine.curRPM,self.speed,dragMultiplier,decreaseRate)
    if self.Fuel_Level < 0.5 then -- Go into limp mode
        if self.fuelLimp == false then
            print(self.tagText,"OUT OF FUEL")
            self.fuelLimp = true
        end
        self.Fuel_Level = 0.1
        self.speedControl = 12
        self:set_trackPosBias(-self.currentNode.width/2)
    else
        if self.fuelLimp == true then
            self.fuelLimp = false
        end
    end
        
end


function Driver.handleTireWear(self) -- decreases tire health based on angular velocity and spoiler angle
    if getRaceControl() == nil then return end
    if getRaceControl() and getRaceControl().tireWearEnabled == false then return end
    if self.Tire_Type then
    else
        return 
    end
    if self.speed <= 15 then -- dont degrade at slow speeds
        return 
    end
    local tireDecay = TIRE_TYPES[self.Tire_Type].DECAY
    local aggressionMultiplier = ratioConversion(10,1,0.1,0.13,self.Spoiler_Angle)
    --print(self.tagText,aggressionMultiplier)
    --aggressionMultiplier = mathClamp(0.1,0.1,aggressionMultiplier)
    --print(self.tagText,aggressionMultiplier)
    local decreaseRate = (self.speed * 1) * (self.angularSpeed * 1+aggressionMultiplier) / (7000-tireDecay)
    self.Tire_Health = self.Tire_Health - (decreaseRate  * getRaceControl().tireWearMultiplier)
    if self.Tire_Health < 1 then
        if self.tireLimp == false then
            print(self.tagText,"Tires DEAD")
            self.tireLimp = true
        end

        self.Tire_Health =  0.5 -- possibly have an oberload/blowout situation where they go limp mode
    else
        if self.tireLimp == true then
            self.tireLimp = false
        end
    end
    -- also reduce top speed?
    --self:debugOutput(24,{self.tagText,decreaseRate,self.Tire_Health})
end

function Driver.handleAutoPit(self) -- auto pits after low tires and fuel -- TODO: Smart pit to only change tires and fuel add when needed
    if getRaceControl() == nil then return end
    if getRaceControl().pitsEnabled == false then return end
    if (self.Tire_Health < 10  or self.Fuel_Level < 10) and self.pitState == 0 then
        if self.pitState ~= 0 then
        else
            print(self.tagText,"Auto pitting",self.Tire_Health,self.Fuel_Level,self.pitState)
            local pit_strategy = {['racer_id'] = self.meta_id,  ["Tire_Change"] = self.Tire_Type, ["Fuel_Fill"] = 100}
            -- Notify RC of pit:
            getRaceControl().PitManager:sv_pit_racer(pit_strategy)
            self:sv_setup_pit(pit_strategy)
        end
    end
end



-- In case car dimensions are nill
function Driver.updateLocation(self)
    self.body = self.shape:getBody() -- Update car dimensions if they arent there
    if self.carDimensions == nil then
        --print("location")
        self.location = self.shape:getWorldPosition() --self.body.worldPosition
    else
        if self.carDimensions['center'] then
            if self.carDimensions['center']['rotation'] and self.carDimensions['center']['length'] then
                local rotation  =  self.carDimensions['center']['rotation']
                local newRot =  rotation * self.shape:getAt()
                local newCenter = self.shape:getWorldPosition() + (newRot * self.carDimensions['center']['length'])
                self.location = newCenter
                --print("locatin",newCenter.z,self.shape.worldPosition.z)
            end
        end
    end
end

-- CamearaPoints functionality
function Driver.updateCameraPoints(self)
    self.cameraPoints = 0 -- Reset camera points 
    -- camerapointsFrom Race poistion
    if self.racePosition > 0 then
        self.cameraPoints = self.cameraPoints + 2.5/self.racePosition -- race position (default 1)
    end
    
    -- Cameara points from cars in range
    local carsInRange = getDriversInDistance(self,20)
    self.cameraPoints = self.cameraPoints + #carsInRange/1.7 -- cars in range (default 1?)
    if self.passing.isPassing then
        --print(self.tagText,"passing")-- get who?
        self.cameraPoints = self.cameraPoints + 1 -- Set points for passing attempt (default 1)
        local opp = getDriverFromId(self.passing.carID)
        if opp then
            self.cameraPoints = self.cameraPoints +  (1.5/opp.racePosition) -- More points for race positions (multiplier? 2)
        end
    end

    -- camera points from spin out
    if math.abs(self.speed - self.velocity:length()) > 2 then
        self.cameraPoints = self.cameraPoints +  0.2 -- might be too short lived to be seen
        --print(self.tagText,"crash detected",self.cameraPoints)
    end

    -- Camera points from being stuck
    if self.stuck then
        self.cameraPoints = self.cameraPoints + 0.5
    end

    -- cameara points from race finish
    if self.raceFinished then self.cameraPoints = 0 end -- stop looking if not there

end


function Driver.handleArtificialDownforce(self) -- does the handling for fake downforce (not aero angle)
    if self.speed > 2 and not self.noEngineError and not self.carData['Downforce'] then -- Standard downforce (Also specify for Stock cars only?)
        local maxForce = (-1100 - (500/(10/self.Spoiler_Angle) + (3*(100-self.Fuel_Level)))) 
        local minForce = (-900 - (2*(100-self.Fuel_Level)))
        
        local offset = 0.05 -- offset towards/from front to push down
        local bankAdjust = 0
        if self.goalNode and self.goalNode.bank ~= nil and math.abs(self.goalNode.bank) > 0 then
            bankAdjust = math.abs(self.goalNode.bank) * 3500
            --print("bank adjust",bankAdjust,self.goalNode.bank)
        end

        local speedAdj = -maxForce + 0.1*self.speed^2.3
        --local force = sm.vec3.new(0,0,1) * -(self.speed^1.7)  -- -- invert so slower has higher? TODO: Check for wedges/aero parts, tire warmth factor too
        local force = sm.vec3.new(0,0,1) * -speedAdj  -- -- invert so slower has higher? TODO: Check for wedges/aero parts, tire warmth factor too
        force.z = mathClamp(maxForce,minForce,force.z) - bankAdjust
        --print(self.tagText,self.Fuel_Level,(3*(100-self.Fuel_Level)),(500/(10/self.Spoiler_Angle)),maxForce)
        --print(self.speed,speedAdj,force.z)
       -- print("df:",force.z)

        if self.velocity.z < -0.55 and not self.tilted then -- TODO: Just do an math.abs and only apply downforce outside of range?
            --print(self.tagText,"down",self.velocity.z)
            --sm.physics.applyImpulse(self.shape.body,sm.vec3.new(0,0,100),true,self.shape.at*0.3) -- should not be negative, and 100
            
        elseif self.velocity.z > 0.55 then -- going up todo: add flags so what we know whats going on?
            --print(self.tagText,"up")
            --sm.physics.applyImpulse(self.shape.body,sm.vec3.new(0,0,100),true) -- really shouldnt be a thing
        else -- GOing flat, normal downforce
            --print(self.tagText,self.speed,force.z)
            --print(self.tagText,"flat")
            --print(self.shape.at*offset)
            
            sm.physics.applyImpulse(self.shape.body,force,true,self.shape.at*offset)--,--self.shape.at)
            -- todo: Investigate if DF is only pushing down on car and not at the proper bank angle
        end 
    end

end

-- Real downforce detection from non thrusters or non connected downforce blocks (experimental)
function Driver.handleDownforceDetection(self)
    if self.downforceDetect then
        local weight = self.mass/3.5 -- Aparently impulse doe s
        -- Apply anti grav by default
        local antiGravVec = sm.vec3.new(0,0,weight)
        sm.physics.applyImpulse(self.shape.body,antiGravVec+ self.dfTestVect,false)--,--self.shape.at)
        --if self.velocity.z > 0
        local velZAvg = angularAverage(self,self.velocity.z) -- TODO: Rename this
        --print(self.dfTestVect.z,velZAvg)
        if velZAvg < 0.05 then -- Dynamic value?
            self.dfTestVect.z = self.dfTestVect.z + 5 -- its okay to be overboard
        else -- car moving up
            --print("Approximate downforce",self.dfTestVect.z)
            local df = self.dfTestVect.z
            -- Save this to body
            self.carData['Downforce'] = df
            self.downforce = df -- needs to be some ratio
            self.storage:save(self.carData)
            self:sv_sendAlert("Downforce Detected: " .. tostring(self.carData['Downforce']))
            self.downforceDetect = false
            clearRunningBuffers(self) -- This could be bad...
        end

        if self.velocity.z > 1 then
            print("FAILSAFE")
            self.downforceDetect = false
        end
    end
end

function Driver.handleCarOnLift(self)
    if self.shape:getBody():isStatic() then -- car on lift
        self.onLift = true
        self.nodeFindTimeout =0 -- --TODO: I think this may cause issues if car has failed scan while on lift during race reset??
        self.stuckTimeout = 0
        self.lost = false
        self.strategicThrottle = 0
        if self.scanningError == true then
            self.carDimensions = nil -- reset car dimensions
            self.carDimensions = self:generateCarDimensions()

            if self.carDimensions then
                self:sv_sendAlert("Car scan Successful")
                self.scanningError = false
                self.frontColDist = self.carDimensions['front']:length() + self.vPadding
                self.rearColDist = self.carDimensions['rear']:length() + self.vPadding 
                self.leftColDist= self.carDimensions['left']:length() + self.hPadding 
                self.rightColDist= self.carDimensions['right']:length() + self.hPadding 
                print("Car Scan success, saving")
                self.carData['carDimensions'] = self.carDimensions
                self.storage:save(self.carData)
            else
                self:sv_sendAlert("Car scan failed,Er")
                self.scanningError = true
                
            end
        end
    else
        self.onLift = false -- TODO: only set once?
    end
end

-- telemetry updating
-- Lap speed average per lap
function Driver.calculateLapSpeedAverage(self)
    if self.lapSpeedAverageBuffer == nil then self.lapSpeedAverageBuffer = {} end
    table.insert(self.lapSpeedAverageBuffer,self.speed)
    
    local runningAverage = 0
    for k, v in pairs(self.lapSpeedAverageBuffer) do
      runningAverage = runningAverage + v
    end
    --if num < 1 then return 0 end
    self.avgLapSpeed = runningAverage / #self.lapSpeedAverageBuffer
end

function Driver.clearLSA(self)
    self.lapSpeedAverageBuffer = nil 
end

-- Top speed in lap
function Driver.calculateLapTopSpeed(self)
    if self.speed > self.topLapSpeed then
        self.topLapSpeed = self.speed
    end
end

function Driver.clearLTS(self)
    self.topLapSpeed = 0
end

function Driver.updateTelemetry(self)
    self:calculateLapSpeedAverage()
    self:calculateLapTopSpeed()
end

function Driver.clearLapTelemetry(self)
    self:clearLSA()
    self:clearLTS()
end


function Driver.updateCarData(self) -- Updates all metadata car may need (server)
    -- basic telemetry update
    self.velocity = sm.shape.getVelocity(self.shape)
    self.angularVelocity = self.body.angularVelocity -- Getangular velocity?
    self.angularSpeed = self.angularVelocity:length() -- Moving here so we only need to calculate once
    self.speed = self.velocity:length()
    self.mass = self.body.mass -- possibly not need


    -- Quick validation and error checking
    if self.engine == nil or self.engine.engineStats == nil then self.noEngineError = true end
    if getDriverFromId(self.id) == nil then
        print("SV driver Re adding to race")
        self:sv_addRacer()
    end
    local raceControl = getRaceControl()
    if raceControl == nil then
        if not self.raceControlError then
            print("No race Control")
            self.raceControlError = true
        end
    end

    self:handleCarOnLift()
    self:updateCameraPoints()
    self:handleArtificialDownforce()
    self:handleDownforceDetection()

    self:updateLocation()
    self:handleTireWear()
    self:handleFuelUsage()
    self:updateTelemetry()
    self:handleAutoPit()
    
    self.futureLook = self:calculateFutureTurn()
    self.trackPosition = self:calculateTrackPos()
    self.goalDirection = self:calculateGoalDirection()
    self.goalDirectionOffset = self:calculateGoalDirOffset()
    self:calculateTrackPosBiasStrength() -- sets self.biasGoalOffsetStrength
    self:calculateDraftPosBiasStrength() -- sets self.draftGoalOffsetStrength

    if self.behaviorSwitch == 0 then -- Old (pre1.8) behavior. Many are depreciating
        self:calculatePriorities()
    elseif self.behaviorSwitch == 1 then
        self:calculatePriorities2()
    end

    

    if self.racing then
        --self:determineRacePos()
        self:checkLapCross()
    end
    --local endTime = os.clock()
    --local timeDif = endTime - self.startClock
    --print("ucd",timeDif)
    --print(self.mass)
    -- update Current states
    --print(self.tagText,"End loop",self.cameraPoints)

end




function Driver.updateStrategicLayer(self) -- Runs the strategic layer  overhead (server)
    -- GEt cahraccteristic logic and race state and do stuff here
    if not self.trackLoaded then -- introduce timeout to prevent spamming
        print("strategic loading map")
        self:sv_loadTrackData() -- Track data could contain racing lines and everything else
        -- Etheir send to server/clients that track is loade or just generate map directly
        if self.nodeChain ~= nil then
            self.totalSegments = getNextItem(self.nodeChain,1,-1).segID
            if self.nodeMap == nil then -- possibly only do if necessary
                print("Generating node map")
                self.nodeMap = generateNodeMap(self.nodeChain)
            end
        end
    end

    -- Determine if green flag or not
    if self.racing and not self.caution and not self.formation then
        self:sv_setLogicOutput(true) -- Outputs true to any logic bits connected
    else
        self:sv_setLogicOutput(false) -- Outputs true to any logic bits connected
    end


    if self.raceFinished and self.racing then -- or caution flag?
        --print(self.speedControl)
        self.handicap = 0
        local adjust = 16 + (#getAllDrivers() - self.racePosition)
        if self.speedControl == 0 then 
            self.speedControl = adjust
        end
        if self.speedControl > 1 then
            self.speedControl = self.speedControl - 0.05
        else
            print(self.tagText,"Stopping racing")
            self.racing = false
            -- Remove self??
        end
        self:set_trackPosBias(self.currentNode.width)
    elseif self.racing and (self.caution or self.formation) then
        --self.speedControl = 0
        -- Passing off speedcontrol to strategic steering FCY and formation module
    else
        if (self.tireLimp or self.fuelLimp) and not self.raceFinished then 
            self.speedControl = 15
        else
            self.speedControl = 0
        end
    end

    if not self.lost then
       

        if self.lost then return end

        if self.pitState == 1 then -- Starting to look for pits (normal racing line
            self:updateCurrentNode(self.nodeChain)
            --self:updateGoalNode2()
            self:updatePitBehavior()
            self:updateStrategicSteering(self.pathGoal)
            self:updatePitNode()
       
        elseif self.pitState >1 and self.pitState <=6 then -- If within pit in and out
            self:updateCurrentNode(self.pitChain)
            self:updatePitNode()
            self:updatePitBehavior()
            --print(self.pitState,self.speedControl)
            --self:updateStrategicSteering(self.pathGoal)
        elseif self.caution then -- caution stuf
            self:updateCurrentNode(self.nodeChain)
            self:updateGoalNodeMid()
            if self.lost then return end
            self:updateCautionSteering(self.pathGoal)
        
        elseif self.formation then-- formation logic
            self:updateCurrentNode(self.nodeChain)
            self:updateGoalNodeMid()
            if self.lost then return end
            self:updateFormationSteering(self.pathGoal) -- Get goal from character layer (pit,mid,race)

        else -- Regular racing hopefully
            if self.currentNode ~= nil then 
                --print('rr',self.currentNode.id,self.strategicSteering)
            else
                --print('rra',self.currentNode,self.strategicSteering)
            end
            self:updateCurrentNode(self.nodeChain)
            if self.behaviorSwitch == 0 then
                self:updateGoalNode() -- use with old
            else
                self:updateGoalNode2()
            end

            if self.lost then return end
            if self.racing == true then
                self:updateStrategicSteering(self.pathGoal) --  Call this Race Behavior and separate file
            end
        --print(self.tagText,"USSA",self.strategicThrottle)
            
        end

        if not self.noEngineError and self.currentNode ~= nil then
            self:updateStrategicThrottle()
            
        end
        --print(self.tagText,"post UST",self.strategicThrottle)
    else
        print(self.tagText,"Is Lost")
        self:updateCurrentNode() -- TODO: Fix this to instant nudge??
        self.speedControl = 0
    end
    --local endTime = os.clock()
    --local timeDif = endTime - self.startClock
    --self:debugOutput(1,{"U s layer",timeDif})
end

function Driver.parseParents( self ) --  [server]TODO: have a client side toggle as well! or it at least update client side data too
    --print("Parsing Parents")
    --print(sm.isServerMode())
	local parents = self.interactable:getParents()
    if #parents == 0 then
        if self.seatConnected then
            print("driver seat disconnected")
            self.seatConnected = false
            self.userPower = 0
            self.userSteer = 0
            self.userSeated = false
            self.userControl = false
            self.network:setClientData({ ["userSeated"] = self.userSeated, ["userControl"] = self.userControl },1)
        else
            if userControl then
                print("removing user control",usercontrol)
                userControl = false
                self.network:setClientData({ ["userSeated"] = self.userSeated, ["userControl"] = self.userControl },1)
            end
           -- noop
        end
    elseif  #parents == 1 then 
        -- only seat connected?
    end
    local totalDownforce = 0
	for k=1, #parents do local v=parents[k]--for k, v in pairs(parents) do
		--print("parsparents",v:hasOutputType(sm.interactable.connectionType.seated))
		local parentColor =  tostring(sm.shape.getColor(v:getShape()))
        if v:hasOutputType(sm.interactable.connectionType.seated) then
            if not self.seatConnected then
                print("driver seat connected")
                self.seatConnected = true
            else
                local active = v:isActive() -- if someone in seat
                local power = v:getPower() -- accel/deceleration (-1,0,1)
                local steer = v:getSteeringAngle() -- steering (-1,0,1)
                self.userPower = power
                self.userSteer = steer
                self.userSeated = active
                self.network:setClientData({ ["userSeated"] = self.userSeated, ["userControl"] = self.userControl },1)
                if not active then
                    if self.userControl then
                        self.strategicThrottle = -1
                    end
                end
                -- reset userControl to false??
                --print("inputs",active,power,steer)
            end
        else
            if tostring(v:getShape():getShapeUuid()) == "ab524867-122b-4f98-990b-67ff6d2e9c5c"  then -- Downforce Adder
                totalDownforce = totalDownforce + v:getPower() -- just get downforce
            end
            --
        end
    end
    if self.downforce ~= totalDownforce then
        print(self.downforce,"Updating df",totalDownforce)
        self.downforce = totalDownforce
        self.carData['Downforce'] = totalDownforce
        self.storage:save(self.carData)
    end

	
end


function Driver.tickClock(self) -- Just ticks by secconds
    local floorCheck = math.floor(clock() - self.started) 
        --print(floorCheck,self.globalTimer)
    if self.globalTimer ~= floorCheck then
        self.gotTick = true
        self.pitTimer:tick()
        --self.stuckGraceCooldownTimer:tick()
        self.globalTimer = floorCheck
        --self.dataOutputTimer:tick()
    else
        self.gotTick = false
        self.globalTimer = floorCheck
    end  
end

function Driver.server_onFixedUpdate( self, timeStep ) -- SV ONLY, need client too!
    --print(self.tagText,timeStep)
    --print('rot',rotDif)



    self.startClock = os.clock()
    -- First check if driver has seat connectd
    --print(string.format("%26.26s",self.tagText),"hey")
    local startTime = CLOCK()
    self:tickClock()
    self:parseParents()
    if self.body ~= self.shape:getBody() then
        --print(self.id,"updating body?",self.body)
        self.body = self.shape:getBody()
    end
    if self.shape:getBody() == self.body then -- double check this
        self:updateCarData()
        if self.experiment then
            self:RunExperiment()
            self:updateGearing()
            self:updateControlLayer()
            return
        end
        if self.raceControlError and self.RCE_timeout < 20 then
            self:try_raceControl()
            self.RCE_timeout = self.RCE_timeout + 1
        else
            if self.RCE_timeout == 20 then
                print("Error: can not find race control",self.RCEtiem)
                self.RCE_timeout = self.RCE_timeout + 1
            end
            
        end
        
        -- update Car logic if car is loaded
        --print(self.tagText,self.liftPlaced,self.onLift)
        if self.lost and self.trackLoaded then
            if self.liftPlaced and self.onLift  then -- if progam placed lift and creation on it
                --print(self.id,"lost and on reset lift")
                sm.player.removeLift(self.player)
                self.liftPlaced = false
            elseif self.onLift then
                print(self.id,"on playerlift?")
            end
        end
        
        if self.liftPlaced and self.onLift then
            print(self.tagText,"on reset lift",self.lost,self.liftPlaced,self.location,self.curGear,self.strategicThrottle)
            sm.player.removeLift(self.player)
            if self.engine then
                --self.engine:server_onRefresh()
            end
            self.liftPlaced = false
        end

        if self.trackLoaded and not self.lost then -- Maybe have a full load check not just track
            if self.lostError then
                print(self.tagText,"Not lost anymore",self.onLift,self.liftPlaced)
                if self.onLift and self.liftPlaced then
                    sm.player.removeLift(self.player)
                    self.liftPlaced = false
                end
                self.lostError = false
            end
            self:updateStrategicLayer() -- intermitent?

            -- only run if everything valid?
            if self.racing == true then --TODO: find better way to prevent error steering while stopped
                if self.behaviorSwitch == 0 then
                    self:updateErrorLayer()
                elseif self.behaviorSwitch == 1 then
                    self:updateErrorLayer2()
                end
            end

            --print(self.tagText,"POST UEL",self.strategicThrottle)
            -- Read character layer here?
            --print(self.racing,self.curGear,self.strategicThrottle,self.curVRPM)
            if self.racing == false and not self.userControl then
                self.strategicThrottle = -1
                self:shiftGear(1)
                --print("heh")
                self:updateControlLayer()

            else
                if self.caution == true then end -- template just in case we need to change things here
                --- Check racemode?
                self:updateCollisionLayer()

                --self:newUpdateCollisionLayer() TODO: plan out and finish this, needs better location prediction 
                if not self.noEngineError and (self.racing or self.userControl) and not self.shape:getBody():isStatic() then
                   
                    self:checkOversteer()
                    self:checkUndersteer() -- TODO: Combine??
                    self:checkStuck()
                    self:checkOffTrack()
                    self:updateGearing()
                    self:checkTilt()
                    self:checkWide()
                    local endTime = os.clock()
                    local timeDif = endTime - self.startClock
                    --print("Check layer",timeDif)
                end
                --print("2 update race control")
                self:updateControlLayer()

            end

                -- Update error detection layer
           
        elseif self.lost and self.lostError == false then -- Do what you can to make way back?
            print(self.tagText,"is lost")
            self.strategicThrottle = -1
            self.lostError = true
        elseif self.lost and self.carResetsEnabled and self.racing == true then
            self:resetPosition(false)
        end

    else
        print(self.id,"body id mismatch")
    end
    local endTime = os.clock()
    local timeDif = endTime - self.startClock
    --print(self.id,"fullLoop",timeDif)
    --self:debugOutput(1,{""})


end

function Driver.client_onUpdate(self,timeStep) -- lag test
    if self.onHover then 
        sm.gui.setInteractionText( self.useText,"reset?", self.tinkerText,"start downforce detection","" )
    else
    end
    local dt = string.format("%.4f",timeStep)
    --print(timeStep,os.clock())
    --print("dr:",dt)
end

function Driver.client_onClientDataUpdate(self,data)
    print("clientrecievedData",data)
    self.userControl = data.userControl
    self.userSeated = data.userSeated
    --self:sv_sendUserControl
end

function generateRayCast(startPoint,endPoint,mask)
    return {['type']="ray",['startPoint']=startPoint,['endPoint']=endPoint,['radius']=1,['mask']=mask}
end
function Driver.generateBackCastTable(self) -- long way to do this but eh
    local backCastTable = {}
    local centerLocation = getCarCenter(self)
    local center = self.shape.worldPosition -- off center really
    local centerStart = centerLocation -  self.shape.at * (self.carDimensions['rear']:length()*1.1)
    local centerEnd = centerStart -  self.shape.at * (self.carDimensions['rear']:length()*0.4)
    
    local leftStart = center -  self.shape.right*self.carDimensions['left']:length()  -  self.shape.at * (self.carDimensions['rear']:length()*1.1)
    local leftEnd = leftStart - self.shape.at * (self.carDimensions['rear']:length()*0.4)
    
    local rightStart = center + self.shape.right*self.carDimensions['right']:length()  -  self.shape.at * (self.carDimensions['rear']:length()*1.1)
    local rightEnd = rightStart - self.shape.at * (self.carDimensions['rear']:length()*0.4)
    -- Only if testing clientside
    --[[if self.runEffects == false then
        self.runEffects = true
        local effect = self:generateEffect(centerStart)
        local effect2 =self:generateEffect(centerEnd ,sm.color.new("22ee44"))
        local effect3 = self:generateEffect(leftStart)
        local effect4 =self:generateEffect(leftEnd ,sm.color.new("22ee44"))
        local effect5 = self:generateEffect(rightStart)
        local effect6 =self:generateEffect(rightEnd ,sm.color.new("22ee44"))
        effect:start()
        effect2:start()
        effect3:start()
        effect4:start()
        effect5:start()
        effect6:start()
    end]]
    table.insert(backCastTable, generateRayCast(centerStart,centerEnd,sm.physics.filter.dynamicBody))
    table.insert(backCastTable, generateRayCast(leftStart,leftEnd,sm.physics.filter.dynamicBody))
    table.insert(backCastTable, generateRayCast(rightStart,rightEnd,sm.physics.filter.dynamicBody))
    return backCastTable
end



function Driver.client_onFixedUpdate(self,timeStep)

    if self.showingVisuals then
        self:updateVisuals()
    end
    if not self.trackLoaded and sm.isHost then -- introduce timeout to prevent spamming
        self:loadTrackData(TRACK_DATA) -- continuously load track data?
    end
    --local filter = sm.interactable.connectionType.seated + sm.interactable.connectionType.bearing + sm.interactable.connectionType.power
	--local currentConnectionCount = #self.interactable:getChildren( filter ) -- can connecto to lights and engine! without crazy loading thing
    --print(self.tagText,self.raceSplit)
end

function Driver.try_raceControl(self)
    local raceControl = getRaceControl()
    if raceControl == nil then
        --print("attempt rc try",self.RCE_timeout)
    else
        --print("found RC",self.RCE_timeout)
        self.raceControlError = false
        self.RCE_timeout = 0
        self:sv_sendCommand({car = {self.id}, type = "get_raceStatus", value = 1})
    end
end

function Driver.sv_toggleUserControl(self,toggle)
    if toggle then
        self.carResetsEnabled = false
    else
        self.carResetsEnabled = true
    end
    self.userControl = toggle
end

function Driver.cl_toggleUserControl(self) -- toggles user control
    if not self.userControl then
        self:cl_showChatMessage("#ffff55SMAR: #ffffffUser Control #55ff55Enabled")
        self:sv_toggleUserControl(true) -- I know there is a more efficient way to do this but readability is important too
    else
        self:cl_showChatMessage("#ffff55SMAR: #ffffffUser Control #ff5555Disabled")
        self:sv_toggleUserControl(false)
    end
end

-- Debug information and visuals

function Driver.client_canTinker( self, character )
    --print("canTinker")
	return true -- Any conditions when it cant? like on 
end

function Driver.client_onTinker( self, character, state )
    --print('onTinker')
	if state then
        self.network:sendToServer('sv_onInteract',{state=state, crouch = character:isCrouching()})
	end
end



function Driver.client_onInteract(self,character,state)
    -- if driver active, then toggle userControl
    --print("client onInteract")
    if state then
        if self.userSeated then
            print("client toggling user control",self.userSeated)
            self:cl_toggleUserControl()
            return
        end

        if character:isAiming() then -- if char is aiming then downforce detect
            self.network:sendToServer('sv_onInteract',{state=state, crouch = character:isCrouching()})
        elseif character:isCrouching() then
            self:cl_hard_reset()
            if self.carData == {} or self.carData == nil then
                print("No car data found, rescan?")
                if self.shape:getBody():isStatic() then
                    print("start scan")
                end
            end
            
            self.network:sendToServer("sv_add_metaData",metaData) --TODO: MAKE SURE THIS IS On/off appropriately
        else -- if character is not aiming and not crouching
            self.debug = not self.debug
            print("setting debug",self.debug)
            if self.debug then
                self:hardUpdateVisual()
            else
                self:hideVisuals()
            end
        end

       
           
   end
end

-- Downforce Detection and helpers
function Driver.sv_onInteract(self,params) -- so far for only for downforce detection
    --print(self.userSeated,self.userControl)
    local state = params.state
    local crouch = params.crouch
    if state and not self.userSeated then -- E pressed
        if self.downforceDetect == false then -- if not already detecting
            if self.speed <= 1 then -- maybe smaller?
                if self.onLift == false then
                    print("Detecting Downforce")
                    self:sv_sendAlert("Detecting Downforce...")
                    self.downforceDetect = true
                    self.dfTestVect.z = 0 -- reset test vec
                else
                    print("Car shjould not be onlift")
                end
            else
                print("Car should be still")
            end
        else
            print("already detecting downforce...",self.downforceDetect)
            self.downforceDetect = false
        end
    end
end


function Driver.RunExperiment(self) -- runs whaterver experiment
    self:testAcceleration(0)

end


function Driver.testAcceleration(self,timeStep) -- really testing braking
    if self.testFinished then
        if self.speed > 2 then
            self.strategicThrottle = 0
        elseif self.speed < 1 then
            self.strategicThrottle = 0
        end
        return
    end
    local testSpeed = 20
    local start = true
    local bDist = self:getBrakingDistance(0.01)
    --self.strategicThrottle = 1
    --print(self.speed,self.mass)
    if self.testStarted == 0 and start then
        print("starting test",self.mass)
        self.initSpeed = self.speed
        self.initTime = CLOCK()
        self.testStarted = 1
    elseif self.testStarted == 1 then -- acceleration
        --print(self.speed,self.mass)--self.carData['Downforce'])
        if self.speed >= testSpeed then
            local timeTaken = CLOCK() - self.initTime 
            local acceleration = (self.speed-self.initSpeed)/ timeTaken
            print("Starting Brake",self.speed,bDist) -- take note of distance traveld
            self.initSpeed = self.speed
            self.initSpot = self.location
            self.initTime = CLOCK()
            self.testStarted = -1
        else
            self.strategicThrottle = 1
        end
    elseif self.testStarted == -1 then
        if self.speed <= 0.01 then
            local timeTaken = CLOCK() - self.initTime 
            local acceleration = self.initSpeed/timeTaken
            local endLocation = self.location
            local dist = getDistance(self.initSpot,endLocation)
            print("Brake Finished",'t:',timeTaken,'a:',acceleration,'d:',dist)
            self.testFinished = true
        else
            self.strategicThrottle = -1
        end
    end

end

function Driver.updateVisuals(self) -- Client update of tag text and visuals
    if self.goalNode == nil then return end
    if self.effectsList == nil then return end
    if self.carDimensions == nil then return end
    if not self:valididtyCheck() then return end
    --print(self.carDimensions)
    local center = self.shape.worldPosition
    
    if self.goalNodeEffect ~= nil then 
        self.goalNodeEffect.pos = self.goalNode.location -- self.body:getCenterOfMassPosition() -- Separate out to race or not race
    end
    if self.currentNodeEffect ~= nil then
        self.currentNodeEffect.pos = self.goalNode.location + (self.goalOffset or sm.vec3.new(0,0,0))--+ self.body:getLocalAabb()\
    end
    if self.calcCenterEffect ~= nil then
        self.calcCenterEffect.pos = self.location
    end
    
    if self.frontEffect ~= nil and self.leftEffect~= nil and self.rightEffect ~= nil and self.rearEffect ~= nil then
        self.frontEffect.pos = center +  self.shape.at*self.carDimensions['front']:length()
        self.leftEffect.pos = center -  self.shape.right*self.carDimensions['left']:length()
        self.rightEffect.pos = center + self.shape.right*self.carDimensions['right']:length()
        self.rearEffect.pos = center -  self.shape.at*self.carDimensions['rear']:length()
    end
    local splitFormat = string.format("%.3f",self.raceSplit)
    local handicapFormat = string.format("%.3f",(self.handicap or 0))
    local rpmFormat = string.format("%.2f",self.engine.curRPM)
    local speedFormat = string.format("%.2f",self.speed)
    local thFormat = string.format("%.2f",self.Tire_Health)
    local fuelFormat = string.format("%.2f",self.Fuel_Level)
    local rpos = string.format("%d",self.racePosition)
    local fpos = string.format("%d",self.formationPos)
    local cpos = string.format("%d",self.cautionPos)
    local df = string.format("%d",(self.carData['Downforce'] or 0)) -- cl
    local draftStatus = tostring(self.drafting) -- cl
    local mass = string.format("%d",self.mass) -- cl
    -- This is debug DEBUG text
    if self.twitchCar == false then
        self.idTag:setText( "Text", " #ffffff"..rpos .. " #ff0000"..self.tagText .. " #00ff00"..speedFormat .. " #ffff00"..splitFormat .. " #faaf00"..fuelFormat .. " #22e100"..thFormat)
    else
        -- THis is production text
    self.idTag:setText( "Text", "#ff0000"..self.tagText)
    end

    --print(self.shape.worldPosition.z-self.location.z)
    --print(self.shape.right,)
    for j=0, #self.effectsList do local effectD = self.effectsList[j] -- separate out to movable/unmovable fx
        if effectD ~= nil and effectD.pos ~= nil then
            if effectD.effect:isPlaying() then
                --print(effectD)
                effectD.effect:setPosition(effectD.pos)
            end
        end
    end

    if self.assignedBox ~=nil then
        if self.assignedShown == nil then
            --local boxFX =self:generateEffect(self.assignedBox.location ,sm.color.new("22ee44"))
            --self.assignedShown = true
            --boxFX:start()
        end
    end
end

function Driver.showVisuals(self)
    --print("debug information",self.effectsList)
    self.idTag:open()
    for j=0, #self.effectsList do local effectD = self.effectsList[j]
        if effectD ~= nil then
            if not effectD.effect:isPlaying() then
                --print("starting")
                -- if dev debug == true
                --effectD.effect:start()
            end
        end
    end
    self.showingVisuals = true
end

function Driver.hideVisuals(self)
    --print("hiding debug visuals")
    self.idTag:close()
    for j=0, #self.effectsList do local effectD = self.effectsList[j]
        if effectD ~= nil then
            if effectD.effect:isPlaying() then
                effectD.effect:stop()
            end
        end
    end
    self.showingVisuals = false
end
    
function Driver.hardUpdateVisual(self)
    self:hideVisuals()
    self:showVisuals()
end

function getLocal(shape, vec)
    return sm.vec3.new(sm.shape.getRight(shape):dot(vec), sm.shape.getAt(shape):dot(vec), sm.shape.getUp(shape):dot(vec))
end




function Driver.determineFrictionCoefficient(self)
    --local force = self.shape.right* 1000
    print("pushing",force:length())
    sm.physics.applyImpulse(self.shape.body,force,true)
    if self.location ~= sm.shape.getWorldPosition(self.shape) then
        if not self.sliding then
            print("Car Start slide")
            self.slideStarted = CLOCK()
            self.slideStartLocation = self.location
            self.sliding = true
        else
            local distanceSlid = getDistance(self.slideStartLocation,self.location)
            --print("slid",distanceSlid)
            if distanceSlid >= 1 then
                local slideStopped = CLOCK()
                local timeTook = slideStopped - self.slideStarted
                local Fnet = (2 * self.mass * distanceSlid) / timeTook^2 
                local Fapplied = force:length()
                local normal = self.mass * DEFAULT_GRAVITY
                local frictionForce =  Fapplied - Fnet

                print("Finished measurment",distanceSlid, timeTook,Fnet,Fapplied,normal,frictionForce)
                self.sliding = false
            end
        end
    end
    --print(self.mass)
    local weight = self.mass * DEFAULT_GRAVITY
    local normal = weight
    local fricCo = 10
    local blockMass = 35.15
    local wheelMass = 138.05
end

function Driver.testFriction(self,timeStep) -- Runs test to see how friction works
    local turnRadius = 0
    local lockSteer = degreesToSteering(turnRadius)
    local speedLimit = 4
    local accel = 0.005
    local throttle = 0
    local steeringVector = degreesToVector(turnRadius)
    local speed = self.speed
    --local steerDif = angleDiff(self.velocity + steeringVector,self.velocity)
    local frontDif = 0
    local realDif = 0
    local lateralAccel = 0
    local angSpeed = self.angularSpeed
    local latDif = 0
    --print(sm.vec3.length(steeringVector),steeringVector)
    if sm.vec3.length2(self.velocity) ~= 0 then
        lateralAccel = speed/turnRadius --( or do vector divided by vector?)
        --testLateral = self.velocity/steeringVector
        realDif = sm.vec3.length(sm.vec3.normalize(self.shape.at)-sm.vec3.normalize(self.velocity))
        --print(realDif)
        frontDif = angleDiff(self.shape.at,sm.vec3.normalize(self.velocity))
        latDif = lateralAccel*14 * getSign(turnRadius) - angSpeed
    end
    local angLenAvg = angularAverage(self,angSpeed)
    local fricAvg = runningAverage(self,realDif) -- This is used for lap time
    local speedAvg = runningAverage2(self,speed)
    local fDiffAvg= runningAverage3(self,realDif)

    self.maxSpeed = checkMax(self.maxSpeed,speedAvg)
    self.maxFriction = checkMax(self.maxFriction,fricAvg)
    self.maxLatAcc = checkMax(self.maxLatAcc,lateralAccel)
    self.maxAngVel = checkMax(self.maxAngVel,angLenAvg)
    self.maxFrontDif = checkMax(self.maxFrontDif,fDiffAvg)


    --print(string.format("AVG: Speed: %.3f, Friction: %.3f, latAccel: %.3f, Angular Vel: %.3f, FrontDif: %.3f",speedAvg,fricAvg,lateralAccel,angLenAvg,fDiffAvg))
    --print(string.format("MAX: Speed: %.3f, Friction: %.3f, latAccel: %.3f, Angular Vel: %.3f, FrontDif: %.3f",self.maxSpeed,self.maxFriction,self.maxLatAcc,self.maxAngVel,self.maxFrontDif))
    if speed < speedLimit then
        throttle = accel
    end
    if speed > speedLimit then
        throttle = -accel
    end
    self:outputThrotttle(throttle)

end

function angularAverage(self,num)
    local runningAverageCount = 5
    if self.angularAverageBuffer == nil then self.angularAverageBuffer = {} end
    if self.nextAngularAverage == nil then self.nextAngularAverage = 0 end
    
    self.angularAverageBuffer[self.nextAngularAverage] = num 
    self.nextAngularAverage = self.nextAngularAverage + 1 
    if self.nextAngularAverage >= runningAverageCount then self.nextAngularAverage = 0 end
    
    local runningAverage = 0
    for k, v in pairs(self.angularAverageBuffer) do
      runningAverage = runningAverage + v
    end
    --if num < 1 then return 0 end
    return runningAverage / runningAverageCount;
end




function runningAverage(self, num)
    local runningAverage = 0
    if self.runningAverageBuffer == nil then self.runningAverageBuffer = {} end
    table.insert(self.runningAverageBuffer, num)
    local runningAverageCount = #self.runningAverageBuffer -- length
    for k, v in pairs(self.runningAverageBuffer) do
      runningAverage = runningAverage + v
    end
    return runningAverage / runningAverageCount;
end

function runningAverage2(self, num)
    local runningAverageCount = 1000
    if self.runningAverageBuffer2 == nil then self.runningAverageBuffer2 = {} end
    if self.nextRunningAverage2 == nil then self.nextRunningAverage2 = 0 end
    
    self.runningAverageBuffer2[self.nextRunningAverage] = num 
    self.nextRunningAverage2 = self.nextRunningAverage2 + 1 
    if self.nextRunningAverage2 >= runningAverageCount then self.nextRunningAverage2 = 0 end
    
    local runningAverage = 0
    for k, v in pairs(self.runningAverageBuffer2) do
      runningAverage = runningAverage + v
    end
    --if num < 1 then return 0 end
    return runningAverage / runningAverageCount;
end

function runningAverage3(self, num)
    local runningAverageCount = 100
    if self.runningAverageBuffer3 == nil then self.runningAverageBuffer3 = {} end
    if self.nextRunningAverage3 == nil then self.nextRunningAverage3 = 0 end
    
    self.runningAverageBuffer3[self.nextRunningAverage] = num 
    self.nextRunningAverage3 = self.nextRunningAverage3 + 1 
    if self.nextRunningAverage3 >= runningAverageCount then self.nextRunningAverage3 = 0 end
    
    local runningAverage = 0
    for k, v in pairs(self.runningAverageBuffer3) do
      runningAverage = runningAverage + v
    end
    --if num < 1 then return 0 end
    return runningAverage / runningAverageCount;
end

function clearRunningBuffers(self)
    -- angAvg
    self.angularAverageBuffer = nil
    self.nextAngularAverage = nil

    self.runningAverageBuffer = nil
    self.nextRunningAverage = nil

    self.runningAverageBuffer2 = nil
    self.nextRunningAverage2 = nil

    self.runningAverageBuffer3 = nil
    self.nextRunningAverage3 = nil
end
