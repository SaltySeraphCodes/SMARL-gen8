-- This block scans the walls of a track and creates a virtual track for cars to understand and follow
--- This is just a non function draft to get the mnath down
-- TODO: IDEA, Possibly load nodes based off of scanned terrain tile UUID from preset stored nodes (prevents bad scans on user side)
    -- Have preset track nodes saved in folder, and open them if track scanner senes the tile uuid
-- TODO: Make Scanner more sensitive to corners/straights
-- TODO: Change names to Track Scanner and Scanner class
dofile "Timer.lua" 
dofile "SplineUtil.lua"
local nodePrev = {loc= sm.vec3.new(0,1,1), id = 1, pevious = nil, next = node, totalForce = 0, energy = 0}
local nodeNext = {loc= sm.vec3.new(0,1,1), id = 1, pevious = node, next = nil, totalForce = 0, energy = 0}

local node = {loc= sm.vec3.new(0,1,1), id = 1, pevious = nodePrev, next = nodeNext, totalForce = 0, energy = 0,inVector = sm.vec3.new(0,0,0),outVector = sm.vec3.new(0,0,0)}
-- SMARL Track Generator V2.0
-- Copyright (c) 2020 SaltySeraph --
--trackTracecr.lua 
--[[
	- This is experimental tech that follows along a race track and attempts to map it out into three different parts: Left Wall, Right Wall, & Center Line
    - V1.5 removes physical car following and learning, purely virtual scanning to perform scans much quicker and more accurate
    - V2.0 Changes scanning function to follow any race track with walls
]]
dofile "globals.lua"

Generator = class( nil )
Generator.maxChildCount = -1
Generator.maxParentCount = -1
Generator.connectionInput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Generator.connectionOutput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Generator.colorNormal = sm.color.new( 0xffc0cbff )
Generator.colorHighlight = sm.color.new( 0xffb6c1ff )
local clock = os.clock --global clock to benchmark various functional speeds ( for fun)



-- Local helper functions utilities
function round( value )
	return math.floor( value + 0.5 )
end

function Generator.client_onCreate( self ) 
	self:client_init()
	print("Created Track Generator")
end

function Generator.client_onDestroy(self)
    print("Generator destroyed")
    if self.effect:isPlaying() then
        self.effect:destroy()
    end
    self:eraseCurManPoints()

    self:stopVisualization()
end

function Generator.client_init( self )  -- Only do if server side???
	--dofile( "util.lua")
	self.id = self.shape.id
	-- Initial Data goes here (Started/stopped and what not)
    self.location = sm.shape.getWorldPosition(self.shape)
    self.dampening = 0.05 -- how little to move smoothing
    self.scanSpeed = 3 -- how small to move in vector direction during midline scan
	self.scanning = false
    self.smoothing = false
    self.scanLocation = self.location
    self.scanVector = self.shape.at
    self.trackStartDirection =self.shape.at
    self.nodeChain = {}
    self.pitChain = {}
    self.effectChain = {}
    self.debugEffects = {}
    self.effect = sm.effect.createEffect("Loot - GlowItem")
    self.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.effect:setPosition(self.location)
    self.visualizing = false
    self.useText =  sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    self.leftClickText = sm.gui.getKeyBinding("Create",true)
    self.rightClickText = sm.gui.getKeyBinding("Attack",true)

    -- Other key bindings: NextCreateRotation  LiftUp  LiftDown ForceBuild Use
    self.onHover = false
    self.showSpeeds = false
    self.showSegments = false
    self.showSectors = true
    self.started = 0
    self.globalTimer = 0
	self.gotTick = false
    self.scanClock = 0
    self.scanLength = 6000
   
    self.nodeIndex = 1 -- 1 is the first one
    self.totalDistance = 0
    self.totalForce = 0
    self.avgSpeed = 0
    self.maxSpeed = nil
    self.minSpeed = nil

    self.lastDif = 0
    self.smoothEqualCount = 0
    self.smoothAmmount = 25 -- how many smoothing iterations to do in preprocess

    self.segSearch = 0
    self.segSearchTimeout = 100

    -- Optimization phase control
    self.isOptimizing = false
    self.phase1Done = false
    self.phase1Running = true
    self.phase2Done = false
    self.phase2Running = false
    self.phase2Done = false
    self.phase3Running = false
    self.phase3Done = false
	self.phase4Running = false
    self.phase4Done = false
    self.phase5Running = false
    self.phase5Done = false

    self.optImportants = {} -- Only important nodes like first, apex, and last
    self.optiSpline = {} -- formatted for spline util.lua
    self.nodeSpline = {} -- Full Formatted spline
    self.p4ScanIndex = 1 -- which node index phase3 scan is on
    -- USER CONTROLABLE VARS:
    self.wallThreshold = 0.40
    self.wallPadding = WALL_PADDING -- = 5 US
    self.debug =false  -- Debug flag -- REMEMBER TO TURN THIS OFF
    self.saveTrack = true -- whether to save the track to world -- remembet to turn on
    self.instantScan = true
    self.instantOptimize = false -- Scans and optimizes in one loop
    self.optimizeStrength = 4
    self.racifyLineOpt = true -- Makes racing line more "racelike"
    self.asyncTimeout = 0 -- Scan speed [0 fast, 1 = 1per sec]   
    self.asyncTimeout2 = 0 -- optimization speed

    -- Editing auto checkpoints
    self.nodeHovered = nil -- which node is hovering
    self.editingNode = false -- whether editing node position or not
    self.customSelect = 0 -- Toggle between smooth start and smooth end
    self.customSmoothStart = nil
    self.customSmoothEnd = nil
    self.customSmoothLive = false

    -- Manual Checkpoint Vars
    self.manLineFX = {} -- Contains Vec3Nodes (important nodes) for spline
    self.manPosArr = {} -- Contains vec3Nodes for full spline positions
    self.manPointsFX = {} -- Contains Effect OBjs for visualizing manPosArr
    self.manualPoints = false
    self.debugMan = true
    self.finishedManScan = false
    -- error states
    self.scanError = false
    self.errorLocation = nil

    self.showWalls = false -- show wall effects (reduces total allowed effects)
    self.showVisuals = true -- whether to show visuals (just keep on)
   
    --- Pit stop Helpers
    self.pitPoints = false
    self.pitLineFX = {} -- Contains Vec3Nodes (important nodes) for spline
    self.pitPosArr = {} -- Contains vec3Nodes for full spline positions
    self.pitPointsFX = {} -- Contains Effect OBjs for visualizing manPosArr
    self.debugPit = true
    self.finishedPitScan = false
    self.pitNodeHovered = nil
    self.editingPitNode = false

	print("Track Generator V2.0 Initialized at ",self.location,self.shape.at)
end

function Generator.server_onCreate(self)
    self.spawnedBodies = {}

end


function Generator.client_onRefresh( self )
	self:client_onDestroy()
	self:client_init()
end

function sleep(n)  -- freezes game?
  local t0 = clock()
  while clock() - t0 <= n do end
end

function Generator.asyncSleep(self,func,timeout)
    --print("weait",self.globalTimer,self.gotTick,timeout)
    if timeout == 0 or (self.gotTick and self.globalTimer % timeout == 0 )then 
        --print("timeout",self.globalTimer,self.gotTick,timeout)
        local fin = func(self) -- run function
        return fin
    end
end

function getDirectionFromFront(self,precision) -- Precision fraction 0-1
	local front = self.shape.getAt(self.shape)
	--print(front)
	if front.y >precision then -- north?
		--print("north") 
		return 0
	end

	if front.x > precision then
		--print("east")
		return 1
	end
	
	if front.y < -precision then
		--print("south")
		return 2
	end

	if front.x < -precision then
		--print("west")
		return 3
	end
	return -1
end

function runningAverage(self, num)
	local runningAverageCount = 5
	if self.runningAverageBuffer == nil then self.runningAverageBuffer = {} end
	if self.nextRunningAverage == nil then self.nextRunningAverage = 0 end
	
	self.runningAverageBuffer[self.nextRunningAverage] = num 
	self.nextRunningAverage = self.nextRunningAverage + 1 
	if self.nextRunningAverage >= runningAverageCount then self.nextRunningAverage = 0 end
	
	local runningAverage = 0
	for k, v in pairs(self.runningAverageBuffer) do
	  runningAverage = runningAverage + v
	end
	--if num < 1 then return 0 end
	return runningAverage / runningAverageCount;
end

--visualization helpers
function Generator.stopVisualization(self) -- Stops all effects in node chain (specify in future?)
    --debugPrint(self.debug,'Stopionng visualizaition')
    for k=1, #self.nodeChain do local v=self.nodeChain[k]
        if v.sphereTrigger ~= nil then
            --print('deleting', v.sphereTrigger:getUserData())
            sm.areaTrigger.destroy(v.sphereTrigger)
            v.sphereTrigger = nil
        end
        if v.effect ~= nil then
            v.effect:stop()
        end
        if v.lEffect ~= nil then
            if v.lEffect:isPlaying() then
                v.lEffect:stop()
            end
        end
        if v.rEffect ~= nil then
            if v.rEffect:isPlaying() then
                v.rEffect:stop()
            end
        end
    

        if v.lEffect ~= nil then
            if v.lEffect:isPlaying() then
                v.lEffect:stop()
            end
        end
        if v.rEffect ~= nil then
            if v.rEffect:isPlaying() then
                v.rEffect:stop()
            end
        end
    end

    for k=1, #self.pitChain do local v=self.pitChain[k]
        if v.sphereTrigger ~= nil then
            --print('deleting', v.sphereTrigger:getUserData())
            sm.areaTrigger.destroy(v.sphereTrigger)
            v.sphereTrigger = nil
        end
        if v.effect ~= nil then
            v.effect:stop()
        end
        if v.lEffect ~= nil then
            if v.lEffect:isPlaying() then
                v.lEffect:stop()
            end
        end
        if v.rEffect ~= nil then
            if v.rEffect:isPlaying() then
                v.rEffect:stop()
            end
        end
    
        if v.lEffect ~= nil then
            if v.lEffect:isPlaying() then
                v.lEffect:stop()
            end
        end
        if v.rEffect ~= nil then
            if v.rEffect:isPlaying() then
                v.rEffect:stop()
            end
        end
    end

    
    for k=1, #self.debugEffects do local v=self.debugEffects[k]
        if v ~= nil then
            if v:isPlaying() then
                v:stop()
            end
        end
    end
    

    if self.errorNode then
        self.errorNode:stop()
    end
    self.visualizing = false
end

function Generator.showVisualization(self) --starts all effects
    --if self.isOptimizing and self.phase4Running then

        for k=1, #self.nodeChain do local v=self.nodeChain[k]
            if v.effect ~= nil then
                if not v.effect:isPlaying() then
                    --print("starting nodechain effect",k,v.pos)
                    v.effect:start()
                end
            end
            if self.showWalls then
                if v.lEffect ~= nil then
                    if not v.lEffect:isPlaying() then
                        v.lEffect:start()
                    end
                end
                if v.rEffect ~= nil then
                    if not v.rEffect:isPlaying() then
                        v.rEffect:start()
                    end
                end
            end
        end

        for k=1, #self.pitChain do local v=self.pitChain[k]
            if v.effect ~= nil then
                if not v.effect:isPlaying() then
                    --print("starting nodechain effect",k,v.pos)
                    v.effect:start()
                end
            end
            if self.showWalls then
                if v.lEffect ~= nil then
                    if not v.lEffect:isPlaying() then
                        v.lEffect:start()
                    end
                end
                if v.rEffect ~= nil then
                    if not v.rEffect:isPlaying() then
                        v.rEffect:start()
                    end
                end
            end
        end

        if self.debug then -- only show up on debug for now
            for k=1, #self.debugEffects do local v=self.debugEffects[k]
                if not v:isPlaying() then
                    v:start()
                end
            end
        end
        self.visualizing = true
    --end
end

function Generator.onEnter( self, trigger, results )
    --print("entered",trigger,results)
    local userData = trigger:getUserData()
    print("Entered Node",userData.node_id)
end


function Generator.updateSphereTriggerUserData(self,node,data) -- destroys and recreates sphere trigger with updated userdatea
    local newTrigger = nil
    if node and node.sphereTrigger then 
        --print("destroying old and making new")
        sm.areaTrigger.destroy(node.sphereTrigger)
        newTrigger = cl_generateSphereTrigger(node.id,data['node_type'],node.pos)
    end
    return newTrigger
end


function Generator.updateVisualization(self) -- moves/updates effects according to nodeChain
    for k=1, #self.nodeChain do local v=self.nodeChain[k]
        if v.effect == nil then
            print('no effect',k)
        end
        if v.effect ~= nil then
            if v.pos ~= nil then -- possibly only trigger on change
                v.effect:setPosition(v.pos)
                -- Attaching AreaTriggers to the node but only while visuals are true
                if v.sphereTrigger == nil then -- if non existent, generate new one
                    --print("316create")
                    v.sphereTrigger = cl_generateSphereTrigger(v.id,0,v.pos)
                    --v.sphereTrigger:bindOnEnter("onEnter") for debug purposes
                else
                    v.sphereTrigger:setWorldPosition(v.pos) -- updates trigger space
                    local triggerNodeId = v.sphereTrigger:getUserData().node_id
                    if triggerNodeId == nil or triggerNodeId ~= v.id then
                        --print("update ST",v.id,triggerNodeId)
                        local newTrigger = self:updateSphereTriggerUserData(v,{['node_id']=v.id, ['node_type']=0}) -- nodeType 0 = race 1 = pit
                        if newTrigger then
                            v.sphereTrigger = newTrigger
                            --print("settinge new trigger",v.id,'old:',triggerNodeId,'cur:',v.sphereTrigger:getUserData().node_id,newTrigger:getUserData().node_id)
                        else
                            print("no new trig?")
                        end
                    end
                end 
                if self.showSpeeds then
                    if v.vMax ~= nil then
                        local color = getSpeedColorScale(self.maxSpeed,self.minSpeed,v.vMax)
                        v.effect:setParameter( "Color", color )
                    end
                end
                if self.showSegments then
                    if v.segType ~= nil then
                        local color = sm.color.new(v.segType.COLOR)
                        v.effect:setParameter( "Color", color )
                    end
                    -- prioritize apex views
                    if v.apex ~= 0 then 
                        local color = sm.color.new(0xffffffff)
                        v.effect:setParameter( "Color", color )
                    end
                end

                if self.showSectors then
                    if v.sectorID and v.sectorID ~= 0 then
                        local colors = {sm.color.new("AAFF06FF"),sm.color.new("FF6622FF"),sm.color.new("5522FFFF")}
                        local color = colors[v.sectorID]
                        v.effect:setParameter( "Color", color )
                    end
                end


                if v.id == self.nodeHovered then -- turn hovered node white (until changed??)
                    if v.hovered == false then  -- only run once
                        v.hovered = true
                        local color = sm.color.new(0xffffffff)
                        v.effect:setParameter( "Color", color )
                        v.effect:start()
                    end 
                else
                    if v.hovered == true then  -- turn back to whatever
                        v.hovered = false
                        v.effect:stop()
                        if v.segType ~= nil then
                            local color = sm.color.new(v.segType.COLOR)
                            v.effect:setParameter( "Color", color )
                        end
                        --v.effect:start()
                    end 
                end

                if v.id == self.customSmoothStart then
                    local color = sm.color.new(0x7777ffff)
                    v.effect:setParameter( "Color", color )
                    if v.csStartHighlight == nil or v.csStartHighlight == false then
                        print("changing color start")
                        v.effect:stop()
                        v.effect:start()
                        v.csStartHighlight = true
                    end
                else
                    if v.csStartHighlight and v.csStartHighlight == true then
                        v.effect:stop()
                        v.csStartHighlight = false
                    end
                end

                if v.id == self.customSmoothEnd then
                    local color = sm.color.new(0xff7777ff)
                    v.effect:setParameter( "Color", color )
                    if v.csEndHighlight == nil or v.csEndHighlight == false then
                        print('changing colr end')
                        v.effect:stop()
                        v.effect:start()
                        v.csEndHighlight = true
                    end
                else
                    if v.csEndHighlight and v.csEndHighlight == true then
                        v.effect:stop()
                        v.csEndHighlight = false
                    end
                end

                    

                if self.visualizing then
                    if v.sphereTrigger == nil then
                        v.sphereTrigger = cl_generateSphereTrigger(v.id,0,v.pos) -- create new trigger , might have to send to network
                        v.sphereTrigger:bindOnEnter("onEnter")
                    end
                    if not v.effect:isPlaying() then
                        v.effect:start()
                    end
                else
                    if v.sphereTrigger ~= nil then
                        --print('deleting', v.sphereTrigger:getUserData())
                        sm.areaTrigger.destroy(v.sphereTrigger)
                        v.sphereTrigger = nil
                    end
                    v.effect:stop()
                end
                if self.showWalls then
                    if v.lEffect ~= nil then
                        if not v.lEffect:isPlaying() then
                            v.lEffect:start()
                        end
                    end
                    if v.rEffect ~= nil then
                        if not v.rEffect:isPlaying() then
                            v.rEffect:start()
                        end
                    end
                end
            end
        end
    end

    for k=1, #self.pitChain do local v=self.pitChain[k]
        if v.effect == nil then
            print('no effect',k)
        end
        if v.effect ~= nil then
            if v.pos ~= nil then -- possibly only trigger on change
                v.effect:setPosition(v.pos)
                -- Attaching AreaTriggers to the node but only while visuals are true
                if v.sphereTrigger == nil then -- if non existent, generate new one
                    --print("316create")
                    v.sphereTrigger = cl_generateSphereTrigger(v.id,1,v.pos)
                    --v.sphereTrigger:bindOnEnter("onEnter") for debug purposes
                else
                    v.sphereTrigger:setWorldPosition(v.pos) -- updates trigger space
                    local triggerNodeId = v.sphereTrigger:getUserData().node_id
                    if triggerNodeId == nil or triggerNodeId ~= v.id then
                        --print("update ST",v.id,triggerNodeId)
                        local newTrigger = self:updateSphereTriggerUserData(v,{['node_id']=v.id, ['nodeType']=0}) -- this might need something else
                        if newTrigger then
                            v.sphereTrigger = newTrigger
                            --print("settinge new trigger",v.id,'old:',triggerNodeId,'cur:',v.sphereTrigger:getUserData().node_id,newTrigger:getUserData().node_id)
                        else
                            print("no new trig?")
                        end
                    end
                end 

                if v.id == self.pitNodeHovered then -- turn hovered node white (until changed??)
                    if v.hovered == false then  -- only run once
                        v.hovered = true
                        local color = sm.color.new(0xffffffff)
                        v.effect:setParameter( "Color", color )
                        v.effect:start()
                    end 
                else
                    if v.hovered == true then  -- turn back to whatever
                        v.hovered = false
                        v.effect:stop()
                       
                    end 
                end

                if v.pointType ~= nil then -- set point type color
                    if v.typeChange == true then
                        --print(v.id,"setting point type",v.pointType,PIT_POINT_TYPES[v.pointType + 1])
                        local color = sm.color.new(PIT_POINT_TYPES[v.pointType + 1].COLOR)
                        v.effect:setParameter( "Color", color )
                        v.effect:stop()
                        v.effect:start()
                        v.typeChange = false
                    end
                end

                    

                if self.visualizing then
                    if v.sphereTrigger == nil then
                        v.sphereTrigger = cl_generateSphereTrigger(v.id,1,v.pos) -- create new trigger , might have to send to network
                        v.sphereTrigger:bindOnEnter("onEnter")
                    end
                    if not v.effect:isPlaying() then
                        v.effect:start()
                    end
                else
                    if v.sphereTrigger ~= nil then
                        --print('deleting', v.sphereTrigger:getUserData())
                        sm.areaTrigger.destroy(v.sphereTrigger)
                        v.sphereTrigger = nil
                    end
                    v.effect:stop()
                end
            end
        end
    end

    if self.errorNode then
        if not self.errorNode:isPlaying() then
            self.errorNode:start()
        end 
    end

    if self.visualizing then -- only show up on debug for now
        for k=1, #self.debugEffects do local effect=self.debugEffects[k]
            if not effect:isPlaying() then
                effect:start()
            end
        end
    end
end

function Generator.hardUpdateVisual(self) -- toggle visuals to gain color
    self:stopVisualization()
    self:showVisualization()
end

function Generator.sv_loadTrackData(self)
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

function Generator.on_trackLoaded(self,data) -- Callback for when track data is actually loaded
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
    end
end


function Generator.generateEffect(self,location,color) -- Creates new effect at param location
    
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
-----

function Generator.generateMidNode(self,index,previousNode,location,inVector,distance,width,leftWall,rightWall,bank,sector)
   -- print("making node",dirVector)
   -- TODO: upgrade to perpvector2
   -- TODO: remove righwallTop
   -- Hovered is when area trigger is hovered over
    if inVector == nil then
        print("node gen no inVector")
    end
    return {id = index, pos = location, outVector = nil, last = previousNode, inVector = inVector, force = nil, distance = distance, 
            perpVector = generatePerpVector(inVector), midPos = location, pitPos = nil, width = width, next = nil, effect = nil, 
            segType = nil, segID = nil, pinned = false, weight = 1, incline = 0, apex = 0, areaTrigger = nil, hovered = false,
            leftWall = leftWall,rightWall = rightWall,leftWallTop = leftWallTop, rightWallTop = rightWallTop ,bank = bank,
            sectorID = sector} -- move effect?
end


function Generator.getSegmentBegin(self,segID) -- parameratize by passing in nodeChain instead
    if self.nodeChain == nil then
        print("no node chain")
        return
    end
    for i=1, #self.nodeChain do local node = self.nodeChain[i]
        if node ~= nil then
            if node.segID == segID then
                --print("found begin node")
                return node
            end
        end
    end 
    print("segBegin found no node...",segID,self.totalSegments)
end


function Generator.findTypeLimits(self,segType,startNode) -- similar to get segment begin/end but returns both directions and moves across segments
    --returns two nodes startNode, endNode
    --print("finding type limits",segType,startNode.id)
    if segType == nil or startNode == nil then return startNode, startNode end
    if startNode.segType.TYPE ~= segType then print("immediatelimitfind mismatch",segType,startNode.segType.TYPE) return startNode, startNode end

    local firstNode = nil
    local lastNode = nil

    -- Going backwards first
    --print('looking back')
    local foundChange = false
    local timeout = 0
    local node = startNode.last -- get next node
    while not foundChange do
        if timeout > 1000 then
            print("last timeout")
            break 
        end
        timeout = timeout + 1
        if node.id == startNode.id then
            print("change not found backWard",node.id,startNode.id)
            break
        end

        if node.segType.TYPE ~= segType then
            --print("found seg dif bac",node.id,node.segType.TYPE,node.next.id,node.next.segType.TYPE,segType)
            firstNode = node.next -- Grabs next node (keep on prev seg)
            foundChange = true
        end
        node = node.last -- get previous node
    end

    -- going forwardNext
    --print("looking next")
    foundChange = false
    timeout = 0
    local node = startNode.next -- get next node
    while not foundChange do
        if timeout > 1000 then
            print("next timeout")
            break 
        end
        timeout = timeout + 1
        if node.id == startNode.id then
            print("change not found forward",node.id,startNode.id)
            break
        end
        if node.segType.TYPE ~= segType then
            --print("found seg dif for",node.id,node.segType.TYPE,node.last.id,node.last.segType.TYPE,segType)
            lastNode = node.last -- Grabs last node (keep on prev seg)
            foundChange = true
        end
        node = node.next -- get next node
    end
    if firstNode == nil and lastNode == nil then
        print("Track all straight segments")
        firstNode = startNode 
        lastNode = startNode
    end
    return firstNode,lastNode
end 
 

function Generator.getSegmentLength(self,segID) --Returns a list of nodes that are in a segment, (could be out of order) (altered binary search??)
    local node = self:getSegmentBegin(segID)
    local foundSegment = false
    local finding = false
    local count = 1
    local index = 1
    while foundSegment == false do
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

function calculateTotalHorz(nodeChain)
    local totalHorz = 0
    for k=1, #nodeChain do local v=nodeChain[k]
        totalHorz = totalHorz + math.abs(v.sumHoz)
    end
    return totalHorz
end

function Generator.createEfectLine(self,from,to,color) --
    local distance = getDistance(from,to)
    local direction = (to - from):normalize()
    local step = 3
    for k = 0, distance,step do
        local pos = from +(direction * k)
        table.insert(self.debugEffects,self:generateEffect(pos,(color or sm.color.new('00ffffff'))))
    end

end

function Generator.generatePerpVector2(self,direction,location,node) -- generates perpendicular vector based on last angle to wall
    if node == nil or node.last == nil then
        return generatePerpVector(direction)
    end -- generates generalized 2d perp vector
    local angleToWall = node.last.rightWall - node.last.pos  -- should be the vector to the right wall
    local angleToWall2 = generatePerpVector(direction)
    angleToWall2.z = angleToWall.z
    --print(node.last.rightWall,node.last.pos,angleToWall)
    return generatePerpVector(direction)--angleToWall

end

function Generator.getWallFlatUp(self,location,perp,cycle) -- Scans directly out to the sides to determine wall location (starts at node then goes up) good with tunnels, bad with uneven terrain
    local searchLimit = 60 -- how far to look for walls, dynamic: self.nodeChain[#self.nodeChain]].lastNode.width/2
    if self.nodeChain[self.nodeIndex -1] ~= nil and self.nodeChain[self.nodeIndex-1].width then
        searchLimit = (self.nodeChain[self.nodeIndex-1].width * 0.9 or 60)
    end

    local zOffsetLimit = 7 -- How far above/below to search [ may need to increase]
    local zOffset = 0 -- unecessary?
    local zStep = 0.5 -- granularitysearch sear
    local searchLocation = location + (perp*searchLimit)
    local hit,data = sm.physics.raycast(location, searchLocation)
    if data.valid == false then -- TODO: add or staement to check if wall or creation is there
        for k= 0, zOffsetLimit, zStep do -- Iterates z position up
            searchLocation = (location + (perp*searchLimit)) + sm.vec3.new(0,0,k) -- angle going from flat then start moving it down
            hit,data = sm.physics.raycast(location,searchLocation)
            --table.insert(self.debugEffects,self:generateEffect(location,sm.color.new('ff0000ff')))
            --table.insert(self.debugEffects,self:generateEffect(searchLocation,sm.color.new('00ff00ff')))
            if data.valid == false then
                --print("K",k,"Left wall failed",location,searchLocation)
            else
                if cycle == 1 then 
                   --self:createEfectLine(location,data.pointWorld,sm.color.new('ee127fff'))
                end
                return data.pointWorld
            end
        end
    else
        if cycle == 1 then 
            --self:createEfectLine(location,data.pointWorld,sm.color.new('ee127fff'))
        end
        return data.pointWorld
    end
end

function Generator.getWallAngleDown(self,location,perp,cycle) -- finds wall from scanning from ground to up and down (Bad with tunnels and uneven terrain)
    local searchLimit = 60 -- how far to look for walls, dynamic: self.nodeChain[#self.nodeChain]].lastNode.width/2
    if self.nodeChain[self.nodeIndex -1] ~= nil and self.nodeChain[self.nodeIndex-1].width then
        searchLimit = (self.nodeChain[self.nodeIndex-1].width * 0.9 or 60)
    end
    
    local hit, data
    local zOffsetLimit = 7 -- How far above/below to search [ may need to increase]
    local zOffsetStart = location.z -- default floor level
    local zStep = 0.5 -- granularitysearch sear
    local searchLocation = (location + (perp*searchLimit))
    searchLocation.z = zOffsetStart
    for k= zOffsetLimit, -zOffsetLimit,-zStep do -- scanning from top to bottom and below
        searchLocation = (location + (perp*searchLimit))
        searchLocation.z =  zOffsetStart + k -- gives old offset and adds(subs) k to scan from top down
        hit,data = sm.physics.raycast(location,searchLocation)
        if cycle == 1 then
            --table.insert(self.debugEffects,self:generateEffect(location,sm.color.new('ff0000ff'))) -- red dot at start locationi
            --table.insert(self.debugEffects,self:generateEffect(searchLocation,sm.color.new('00ff00ff'))) -- green dot at scan location
        end
        if data.valid == false then --or (hitL and lData.type ~= 'terrainAsset') then -- could not find wall
        else -- we found a wall, create debug effect line
            if cycle == 1 then
                --self:createEfectLine(location,data.pointWorld,sm.color.new('ee127fff')) -- red ish line
            end
            return data.pointWorld
        end
    end
    
end

function Generator.cl_changeWallSense(self,amnt)
    -- increasees wall thin
    self.wallThreshold = self.wallThreshold + (0.05* amnt)
    if self.wallThreshold <= 0 then
        self.wallThreshold = 0 
    end
    local color = "#ffffff"
    if amnt < 0 then
        color = "#ffaaaa"
    elseif amnt > 0 then
        color = "#aaffaa"
    end

    sm.gui.chatMessage("Wall Detection sensitivity: "..color ..self.wallThreshold .. " #ffffffCrouch to decrease")
end

function Generator.cl_updateWallPadding(self,amnt) -- updates global wall padding var (should be cl)
    self.wallPadding = self.wallPadding + amnt
    WALL_PADDING = self.wallPadding
    sm.gui.chatMessage("Set Wall Padding to ".. self.wallPadding)
end

-- Wider scan to find the initial wall from the top down
function Generator.findWallTopDown(self,location,direction,cycle,threshold) -- scans walls from the top down and across the perp axis (BEST)
    -- Scans from location to another location from top down 
    -- original location is estimated position based off of last wall
    -- stores floor location and if floor height threshold is passed then will return wall location
   local scanHeight = threshold + 20 -- how high from location to start scan
   local perpOffset = 2 -- start 2 away from center block
   local perpLimit = 60  -- end scan dist
   local floorValue = nil
   local scanGrain = 0.25 -- Sweeet spot may need adjustment [0.25]
   local scanStart = location + (direction * perpOffset)
   scanStart.z = location.z + scanHeight
   local scanEnd = scanStart + sm.vec3.new(0,0,-scanHeight*1.5) -- scan down even further
   local foundWall = nil

   for k= perpOffset, perpLimit, scanGrain do -- scans from pre direction, to post direction
           hit,data = sm.physics.raycast(scanStart,scanEnd) -- shoot raycast down
           if cycle == 1 then
                --print("insert effect")
                --table.insert(self.debugEffects,self:generateEffect(scanStart,sm.color.new('1111ffff'))) -- blue dot at start location
                --table.insert(self.debugEffects,self:generateEffect(scanEnd,sm.color.new('11ff11ff'))) -- green dot at end location
           end

           if hit then -- found floor
               if cycle == 1 then
                    --table.insert(self.debugEffects,self:generateEffect(scanStart,sm.color.new('1111ffff'))) -- blue dot at start location
                    --table.insert(self.debugEffects,self:generateEffect(data.pointWorld,sm.color.new('11ff11ff'))) -- green dot at end location
               end

               floorLoc = data.pointWorld.z
               if floorValue then
                    --print( "floorDif",floorValue,floorLoc, math.abs((floorLoc - floorValue)),threshold)
               end
               if floorValue and math.abs((floorLoc - floorValue))  > threshold then -- if there is a large change in floorthreshold
                   --print("found potential wall",math.abs(floorLoc - floorValue),threshold)
                   --self:createEfectLine(scanStart,data.pointWorld,sm.color.new('aaaaff')) -- white ish line
                    foundWall = data.pointWorld
                    --table.insert(self.debugEffects,self:generateEffect(data.pointWorld+ sm.vec3.new(0,0,4),sm.color.new('11ff11ff'))) -- green dot at end location

                   break -- stop looping here
               else
                   floorValue = floorLoc -- adjust floor location in case uneven terrain?
                   -- TODO to debug: Might miss smooth walls, changing it to floorlocation 
               end
            else -- use starting loc +lastfloordist as wall?
                print("WTD hit failed")
            end
           
           -- Setting wall location even though it timed out
           

           -- Set new location 
           scanStart = location + (direction * k)
           scanStart.z = location.z + scanHeight
           scanEnd = scanStart + sm.vec3.new(0,0,-scanHeight*1.5) -- scan down
   end
   if foundWall == nil then  -- just put a wall at the max scan location
        print("Max limit for wall",scanEnd)
        table.insert(self.debugEffects,self:generateEffect(scanEnd+ sm.vec3.new(0,0,4),sm.color.new('ff1111ff'))) -- green dot at end location
        foundWall = scanEnd
   end
   return foundWall,floorValue
end

function Generator.getWallTopDown(self,location,direction,cycle,threshold) -- scans walls from the top down and across the perp axis (BEST)
    -- Scans from location to another location from top down 
    -- original location is estimated position based off of last wall
    -- stores floor location and if floor height threshold is passed then will return wall location
   local scanHeight = threshold + 20 -- how high from location to start scan TODO: make 
   local perpOffset = -6 -- start BEFORE predicted wall location (bring inwards) 
   local perpLimit = 40  -- end scan dist (maybe offset*5?)
   local floorValue = nil
   local scanGrain = 0.2 -- Sweeet spot may need adjustment [0.25] TODO: also make adjustable? Wall Thickness
   local scanStart = location + (direction * perpOffset)
   scanStart.z = location.z + scanHeight -- caused issues because this shifts wall scan up and technically scan end should be lower
   local scanEnd = scanStart + sm.vec3.new(0,0,-(scanHeight + location.z)*1.5) -- scan down even further by combining location and height and adding padding
   local foundWall = nil
   --table.insert(self.debugEffects,self:generateEffect(scanStart,sm.color.new('ff00ff'))) -- purple dot at start location
   for k= perpOffset, perpLimit, scanGrain do -- scans from pre direction, to post direction
           hit,data = sm.physics.raycast(scanStart,scanEnd) -- shoot raycast down
           if cycle == 1 then
                --table.insert(self.debugEffects,self:generateEffect(scanStart,sm.color.new('1111ffff'))) -- blue dot at start location
                --table.insert(self.debugEffects,self:generateEffect(scanEnd,sm.color.new('11ff11ff'))) -- green dot at end location
           end

           if hit then -- found floor
               if cycle == 1 then
                    --table.insert(self.debugEffects,self:generateEffect(scanStart,sm.color.new('1111ffff'))) -- blue dot at start location
                    --table.insert(self.debugEffects,self:generateEffect(data.pointWorld,sm.color.new('11ff11ff'))) -- green dot at end location
               end

               local floorLoc = data.pointWorld.z
               --print(floorLoc,floorValue)
               if floorValue then
                    --print( "floorDif",floorValue,floorLoc, math.abs((floorLoc - floorValue)),threshold)
               end
               if floorValue and math.abs((floorLoc - floorValue))  > threshold then -- if there is a large change in floorthreshold
                   --print("found potential wall",math.abs(floorLoc - floorValue),threshold)
                   if cycle == 1 then
                    --table.insert(self.debugEffects,self:generateEffect(scanStart,sm.color.new('eeee11'))) -- yellow at each scan start
                    --self:createEfectLine(scanStart,data.pointWorld,sm.color.new('aaaaff')) -- white from start to stop
                   end
                   foundWall = data.pointWorld
                   break -- stop looping here
               else
                   floorValue = floorLoc -- adjust floor location in case uneven terrain?
                   -- TODO to debug: Might miss smooth walls, changing it to floorlocation 
               end
           end
           -- Set new location 
           scanStart = location + (direction * k)
           scanStart.z = location.z + scanHeight
           scanEnd = scanStart + sm.vec3.new(0,0,-scanHeight*1.5) -- scan down
   end
   return foundWall,floorValue -- also sending floor to base bank off of floor
end

function Generator.checkForSharpEdge(self,midPoint,newWall,cycle) -- TODO: Determine whether or not to slow down track scan here??
   if cycle == 1 then
       --self:createEfectLine(location,searchLocation,sm.color.new('ee127fff')) -- red ish line
       --print("FoundLeftWall",searchLocation.z,location.z) -- Validate difference/distance between walls
   end
   if lastWall then
       local wallChange = getDistance(lastWall,newWall)
       if wallChange > 6 then  -- TODO: figure out good averag and go 2+ (so var avg is 4-5)
           --print("Sharp Wall Edge",wallChange)
           if cycle == 1 then
               --self:createEfectLine(location,searchLocation,sm.color.new('ee127fff')) -- red ish line
               --table.insert(self.debugEffects,self:generateEffect(midPoint,sm.color.new('ff0000ff'))) -- red dot at start locationi
               --table.insert(self.debugEffects,self:generateEffect(searchLocation,sm.color.new('00ff00ff'))) -- green dot at scan location
               --table.insert(self.debugEffects,self:generateEffect(newWall,sm.color.new('0000ffff'))) -- blue dot at wall location
               --self:createEfectLine(location,lData.pointWorld,sm.color.new('ee127fff')) -- left is more red
               return true
           end
       end
   end
   return false
end
--TODO: Consolidate these into one function
-- Only used at startTrack Sacn
function Generator.getWallMidpoint(self,location,direction,cycle) -- cycle is new, determines which time it is ran to prevent annoying overlay on debug draw
    --print("originalZ",location.z)
    --print("scaning perp",direction)
    --if self.nodeChain == nil then return end
    -- TODO: figure out loopdy loops, will need to look forward instead of straight down in order to find ramps/inclines. have upsidedown tag for node aswell
    -- TODO: FIgure out fixes for bugs like goin in tunnels,scanner will break
    local searchLimit = 60 -- how far to look for walls, dynamic: self.nodeChain[#self.nodeChain]].lastNode.width/2
    local inTunnel = false
    if self.nodeChain[self.nodeIndex -1] ~= nil and self.nodeChain[self.nodeIndex-1].width then
        searchLimit = (self.nodeChain[self.nodeIndex-1].width * 0.8 or 60)
    end
    local incline = false
    local perp = generatePerpVector(direction)-- Generates perpendicular vector to given direction - right side 
    local perp2 = self:generatePerpVector2(direction,location,self.nodeChain[#self.nodeChain])
    if perp.z ~=0 then -- perp is zerod in prior function
        --print("perp z no need",perp.z)
        perp.z = 0
    end
    local floorHeight,floorData = sm.physics.raycast(location + self.shape.up *2.5, location + self.shape.up * -60) -- TODO: remove because not important
    local ceilingHeight,ceilingData = sm.physics.raycast(location + self.shape.up *1.1, location + self.shape.up * 50) -- Check for ceiling (initioal tunnel or starting line stuff)
    -- TODO: Check which object has been hit (for all raycasts) and alert player if player has been hit
    local floor = location.z
    if floorHeight then
        --print("local normie",floorData.normalLocal,floorData.normalWorld)
        floor = floorData.pointWorld.z+0.1
    else
        print("could not find floor",floor)
        self.scanError = true
        self.errorReason = "Floor not found or invalid coordinates"
        return nil
        -- Double check floor from higher distance?
    end
    local ceiling = nil -- or 0?
    if ceilingHeight then
        --print("local normie",floorData.normalLocal,floorData.normalWorld)
        ceiling = ceilingData.pointWorld.z-0.1
        inTunnel = true
    else
        inTunnel = false
    end

    -- Look Forward First to see if floor is rising in front
    -- First send node out to front and see if it hits a point at higher z than floor
    local front, frontData =  sm.physics.raycast(location,location + direction * self.scanSpeed) -- change multiplier?
    if front then -- TODO: UPGRADSE THIS TO determine last location from next location , subtract the z values and you get z slope dif
        local floorDif = frontData.pointWorld.z - floor
        if floorDif < -.3 then
            print("Road is sloping up")
            floor = frontData.pointWorld.z + 0.5 -- may need to adjust?
            location.z = floor 
        end
    else
        --print(location.z - floor) -- bug, it sees going gdown but doesnt determine flat
        if location.z - floor > 0.3 then
            --print("Road going down",location.z - floor)
            location.z = frontData.pointWorld.z
        end
    end
    --table.insert(self.debugEffects,self:generateEffect(location + (self.shape.up *scanFromHeight),sm.color.new('ff0000ff'))) -- oarnge dot at start location

    -- left wall Initial Find
    if inTunnel then -- if in tunnel just look directly left and right for walls
        leftWall = self:getWallFlatUp(location,-perp2,1) -- find left wall
    else
        leftWall,leftFloor = self:findWallTopDown(location,-perp2,cycle,self.wallThreshold)
    end
    if leftWall == nil then
        print("Finding Left wall failed",leftWall,location,cycle)
        -- switch scan methods?
    else -- we found the wall, create debug effect line
        self:checkForSharpEdge(location,leftWall,cycle) -- returns truefalse for failsafes
    end

    -- Right Wall Initial Find
    if inTunnel then -- if in tunnel just look directly left and right for walls
        rightWall = self:getWallFlatUp(location,perp2,1) -- find left wall
    else
        rightWall,rightFloor = self:findWallTopDown(location,perp2,cycle,self.wallThreshold)
    end
    if rightWall == nil then
        print("Finding Right Wall failed",rightWall,location,cycle)
        -- switch scan methods
    else -- we found the wall, create debug effect line
        self:checkForSharpEdge(location,rightWall,cycle)
    end
    
    if not leftWall then
        print('Left wall invalid')
    end
    if not rightWall then
        print("right wall invalid")
    end

    if not leftWall or not rightWall then
        print("Something went wrong While scanning track")
        -- Just Return Best Guess Which is just location but new floor
        self.scanError = true
        self.errorLocation = location
        self.errorReason = "Wall invalid @ red dot (check for gaps or tunnels)"
        return location
    end
   
    local midPoint = getMidpoint(leftWall,rightWall)
    midPoint.z = floor -- sets the floor as a track ground, 
    local width = getDistance(leftWall,rightWall) -- -1 padding?
    local bank = 0
    local bankThresh = 3 -- threshold to determine banking
    if leftWall.z - rightWall.z > bankThresh then -- If left wall is 3? higher than right wall, it is banked right
        bank = 1
    elseif rightWall.z - leftWall.z > bankThresh then -- if right wall is 3? hgihter than left wall, it is banked left
        bank = -1
    end -- else bank is 0
    return midPoint, width,leftWall,rightWall,bank
end

function Generator.getWallMidpoint2(self,location,direction,cycle) -- new Method for scanning Utilizes top down approach.
    -- TODO: figure out loopdy loops, will need to look forward instead of straight down in order to find ramps/inclines. have upsidedown tag for node aswell
    -- TODO: FIgure out fixes for bugs like goin in tunnels,scanner will break
    --[[
        * Initial node has to be flat surface and clear access to walls
        * Reasonable track width consistency 
        * After initial floor and wall locations are found
        * Scanner establishes perp nodes
        * Scanner has established height (5?)
            * Or no higher than 3 units above wall
        * Sets initial scan heightpos to wall height +3?
        * Scanner scans top down with multiple casts along perpnode starting from slightly inside previous wall distance to outside wall distance 
        * Scan for floor location, store z<
        * Check difference from last known floor z location.
        * If difference > 3? Establish that location as wall
        * Begin vertical z scan outwards towards wall until Sccanheight reached (start from floor locatio
        * Store distance to wall (starting 1? Closer to center of track) 
        * If difference from previous scan is >1? Establish the previous location as top of the wall (for tunnels it will stop upon 
        * intersection with terrain top (very dramatic (possibly really close) distance) might need top wall decrease 
        * Set new wall height if needed but only if dif is > 2? Initial wall height (not previous)
    ]]
    -- ALSO: Potentially get VHDif of lastWall/curWall to determine direction of turn & etc

    local searchLimit = 60 -- how far to look for walls, dynamic: self.nodeChain[#self.nodeChain]].lastNode.width/2
    local scanFromHeight = 2 --* self.shape.up
    if self.nodeChain[self.nodeIndex -1] ~= nil and self.nodeChain[self.nodeIndex-1].width then
        searchLimit = (self.nodeChain[self.nodeIndex-1].width * 0.8 or 60)
    end

    -- find the floor
    local incline = false
    local inTunnel = false
    local floorHeight,floorData = sm.physics.raycast(location + (self.shape.up *scanFromHeight), location + (self.shape.up * -60)) -- TODO: balance height to prevent confusion...
    local ceilingHeight,ceilingData = sm.physics.raycast(location + self.shape.up *1.1, location + self.shape.up * 50) -- Check for ceiling (initioal tunnel or starting line stuff)

    local floor = location.z -- setting flor to be previous floor 
    if floorHeight then
        --print("local normie",floorData.normalLocal,floorData.normalWorld)
        floor = floorData.pointWorld.z + 0.6
    else
        print("could not find floor",floor)
        self.scanError = true
        self.errorReason = "Floor not found or invalid coordinates"
        return nil
        -- Double check floor from higher distance?
    end

    local ceiling = nil -- or 0?
    if ceilingHeight then
        --print("local normie",floorData.normalLocal,floorData.normalWorld)
        ceiling = ceilingData.pointWorld.z-0.1
        inTunnel = true
        --print("Curr In tunnel")
    else
        --print("no curTunnel")
        inTunnel = false
    end
    -- Generate perpindeicular vectors towards assumed wall
    local perp = generatePerpVector(direction)-- Generates perpendicular vector to given direction - right side 
    local perp2 = self:generatePerpVector2(direction,location,self.nodeChain[#self.nodeChain])
    if perp.z ~=0 then -- perp is zerod in prior function
        --print("perp z no need",perp.z)
        perp.z = 0
    end

    -- set up wall locations
    local lastLeftWall, lastRightWall,lastCenter,leftWallDist,rightWallDist -- find previous node wall locations
    if self.nodeChain[self.nodeIndex -1] ~= nil then 
        if self.nodeChain[self.nodeIndex-1].leftWall then
            lastLeftWall = self.nodeChain[self.nodeIndex-1].leftWall
        end
        if self.nodeChain[self.nodeIndex-1].rightWall then
            lastRightWall = self.nodeChain[self.nodeIndex-1].rightWall
        end
        if self.nodeChain[self.nodeIndex-1].location then
            lastCenter = self.nodeChain[self.nodeIndex-1].location
        else
            lastCenter = location -- just use curr loc
        end
        leftWallDist = getDistance(lastLeftWall,sm.vec3.new(lastCenter.x,lastCenter.y,lastLeftWall.z))
        rightWallDist = getDistance(lastRightWall,sm.vec3.new(lastCenter.x,lastCenter.y,lastRightWall.z)) -- The Z difference skewed the distance prediction, setting z to be the same. now only skew is with minimal x/y
    end
    
    --print("Lwall RWall:",leftWallDist,rightWallDist)
    -- check previous leftWall/rightWall locations/distances/existence
    if cycle == 1 then
        --table.insert(self.debugEffects,self:generateEffect(location + self.shape.up *3.5 ,sm.color.new('ffff00ff'))) -- oarnge dot at start location
    end
    
    local wallThreshold = self.wallThreshold--0.55 -- how much difference in floor height to determine a wall [[TODO: Make user controlable dynamic, sweet spot is 0.2]]
    -- Can possibly make ^ dynamic according to failed params?
    --local location = lastLeftWall
    --print("\nLeft Wall Scan:")
    -- new wall location = location
    -- Left wall scan
    local lWallPredict = location + (-perp2*leftWallDist)
    local leftWall,leftFloor = nil
    --print("left Wall Predict",lastLeftWall,lastCenter,perp2,leftWallDist,lWallPredict)
    lWallPredict.z = lastLeftWall.z -- adjust z value???
    if inTunnel then -- if in tunnel just look directly left and right for walls
        leftWall = self:getWallFlatUp(location,-perp,cycle)
    else
        leftWall,leftFloor = self:getWallTopDown(lWallPredict,-perp2,cycle,wallThreshold)
    end
    if  leftWall == nil then
        --print("Left Top Down scan failed",wallThreshold,cycle)
        -- do failsafe scan? -- increase/decrease threshold/granularity?
        table.insert(self.debugEffects,self:generateEffect(location + self.shape.up *3.5 ,sm.color.new('bbbb00ff'))) -- oarnge dot at start location
        leftWall = self:getWallAngleDown(location,-perp,cycle) -- TODO: use perp or perp2??
        if leftWall == nil then -- only three methods
            --print("Left Angle Down Scan failed")
            leftWall = self:getWallFlatUp(location,-perp,cycle)
            if leftWall == nil then 
                print("Left All scanning methods failed",location,-perp,cycle)
                self:createEfectLine(location,lWallPredict,sm.color.new('aa3300ff')) -- redish orange line shows where it thinks the wall should be
                -- TODO: Have wall scans send back scan pos debug when failed
                print("could not Scan left Wall",location)
                self.scanError = true
                self.errorReason = "could not Scan left Wall"
                return nil
            end
        end
    else -- we found the wall, create debug effect line
        self:checkForSharpEdge(location,leftWall,cycle) -- returns true/false for morefailsafes
    end

    --print("\nRight Wall Scan:")
    ------ RIGHT WALL SCAN
    local rWallPredict = location + (perp2*rightWallDist) 
    rWallPredict.z = lastRightWall.z -- adjust zval
    local rightWall,rightFloor = nil
    if inTunnel then -- if in tunnel just look directly left and right for walls
        rightWall = self:getWallFlatUp(location,perp,cycle) -- find left wall
    else
        rightWall,rightFloor = self:getWallTopDown(rWallPredict,perp2,cycle,wallThreshold)
    end
    if  rightWall == nil then
        --print("Right Top Down scan failed",wallThreshold,cycle)
        table.insert(self.debugEffects,self:generateEffect(location + self.shape.up *3.5 ,sm.color.new('bbbb00ff'))) -- oarnge dot at start location
        rightWall = self:getWallAngleDown(location,perp,cycle)
        if rightWall == nil then -- only three methods
            --print("Right angle down Scan failed")
            rightWall = self:getWallFlatUp(location,perp,cycle)
            if rightWall == nil then 
                print("Right All scanning methods failed",location,perp,cycle)
                self:createEfectLine(location,rWallPredict,sm.color.new('aa3300ff')) -- redish orange line shows where it thinks the wall should be
                -- TODO: Have wall scans send back scan pos debug when failed, Possibly have it force a wall at the rWall Predict place (fill in gaps)
                print("could not Scan right Wall",location)
                self.scanError = true
                self.errorReason = "could not scan right Wall"
                return nil
            end
        end
    else -- we found the wall, create debug effect line
        self:checkForSharpEdge(location,rightWall,cycle)
    end
    
    -- TODO: find top of wall by scanning from bottom up until drastic raycast diff is found
    -- Error checking

    if rightWall == nil or leftWall == nil then
        print("Something went wrong While scanning track")
        -- Just Return Best Guess Which is just location but new floor
        self.scanError = true
        self.errorLocation = location
        return location
    end
    local midPoint = getMidpoint(leftWall,rightWall)
    midPoint.z = floor -- sets the floor as a track ground, 
    local width = getDistance(leftWall,rightWall) -- -1 padding?
    
    local bankThresh = 1 -- threshold to determine banking -- Can use height over width to get angle: bankAngle = (floorLeft - floorRight)/width
    local floorBank = 0
    local bankAngle = 0
    -- Removed Wall-based bank detection
    if leftFloor and rightFloor then
        if leftFloor - rightFloor > bankThresh then -- If left wall is 3? higher than right wall, it is banked right
            floorBank = 1
        elseif rightFloor - leftFloor > bankThresh then -- if right wall is 3? hgihter than left wall, it is banked left
            floorBank = -1
        end -- else bank is 0
        bankAngle = (leftFloor-rightFloor)/width
    end
    return midPoint, width,leftWall,rightWall,bankAngle
end


function Generator.getWallMidpoint3(self,location,direction,cycle) -- new Method for scanning Utilizes top down approach.
    -- Same as wallMidpoint3 but adjusting for phase 4 variables (TODO: consolidate and name variables the same and remove this func)

    local searchLimit = 60 -- how far to look for walls, dynamic: self.nodeChain[#self.nodeChain]].lastNode.width/2
    local scanFromHeight = 3 --* self.shape.up
    if self.nodeChain[self.p4ScanIndex -1] ~= nil and self.nodeChain[self.p4ScanIndex-1].width then
        searchLimit = (self.nodeChain[self.p4ScanIndex-1].width * 0.8 or 60)
    end

    -- find the floor
    local incline = false
    local inTunnel = false
    local floorHeight,floorData = sm.physics.raycast(location + (self.shape.up *scanFromHeight), location + (self.shape.up * -60)) -- TODO: balance height to prevent confusion...
    local ceilingHeight,ceilingData = sm.physics.raycast(location + self.shape.up *1.1, location + self.shape.up * 50) -- Check for ceiling (initioal tunnel or starting line stuff)
    --table.insert(self.debugEffects,self:generateEffect(location + (self.shape.up *scanFromHeight),sm.color.new('ff0000ff'))) -- oarnge dot at start location

    local floor = location.z -- setting flor to be previous floor 
    if floorHeight then
        --print("local normie",floorData.normalLocal,floorData.normalWorld)
        floor = floorData.pointWorld.z + 0.6
    else
        print("could not find floor3",floor,floorHeight,location + (self.shape.up *scanFromHeight),location + (self.shape.up * -60))
        self.scanError = true
        self.errorReason = "Floor not found or invalid coordinates"
        table.insert(self.debugEffects,self:generateEffect(location + (self.shape.up *scanFromHeight),sm.color.new('ff0000ff'))) -- oarnge dot at start location

        return nil
        -- Double check floor from higher distance?
    end

    local ceiling = nil -- or 0?
    if ceilingHeight then
        --print("local normie",floorData.normalLocal,floorData.normalWorld)
        ceiling = ceilingData.pointWorld.z-0.1
        inTunnel = true
        --print("Curr In tunnel")
    else
        --print("no curTunnel")
        inTunnel = false
    end
    -- Generate perpindeicular vectors towards assumed wall
    local perp = generatePerpVector(direction)-- Generates perpendicular vector to given direction - right side 
    local perp2 = self:generatePerpVector2(direction,location,self.nodeChain[#self.nodeChain])
    if perp.z ~=0 then -- perp is zerod in prior function
        --print("perp z no need",perp.z)
        perp.z = 0
    end

    -- set up wall locations
    local lastLeftWall, lastRightWall,lastCenter,leftWallDist,rightWallDist -- find previous node wall locations
    if self.nodeChain[self.p4ScanIndex -1] ~= nil then 
        if self.nodeChain[self.p4ScanIndex-1].leftWall then
            lastLeftWall = self.nodeChain[self.p4ScanIndex-1].leftWall
        end
        if self.nodeChain[self.p4ScanIndex-1].rightWall then
            lastRightWall = self.nodeChain[self.p4ScanIndex-1].rightWall
        end
        if self.nodeChain[self.p4ScanIndex-1].midPos then
            lastCenter = self.nodeChain[self.p4ScanIndex-1].midPos
        else
            lastCenter = location -- just use curr loc
        end
        leftWallDist = getDistance(lastLeftWall,sm.vec3.new(lastCenter.x,lastCenter.y,lastLeftWall.z))
        rightWallDist = getDistance(lastRightWall,sm.vec3.new(lastCenter.x,lastCenter.y,lastRightWall.z)) -- The Z difference skewed the distance prediction, setting z to be the same. now only skew is with minimal x/y
    end
    
    --print("Lwall RWall:",leftWallDist,rightWallDist)
    -- check previous leftWall/rightWall locations/distances/existence
    if cycle == 1 then
        --table.insert(self.debugEffects,self:generateEffect(location + self.shape.up *3.5 ,sm.color.new('ffff00ff'))) -- oarnge dot at start location
    end
    
    local wallThreshold = self.wallThreshold--0.55 -- how much difference in floor height to determine a wall [[TODO: Make user controlable dynamic, sweet spot is 0.2]]
    -- Can possibly make ^ dynamic according to failed params?
    --local location = lastLeftWall
    --print("\nLeft Wall Scan:")
    -- new wall location = location
    -- Left wall scan
    local lWallPredict = location + (-perp2*leftWallDist)
    local leftWall,leftFloor = nil
    --print("left Wall Predict",lastLeftWall,lastCenter,perp2,leftWallDist,lWallPredict)
    lWallPredict.z = lastLeftWall.z -- adjust z value???
    if inTunnel then -- if in tunnel just look directly left and right for walls
        leftWall = self:getWallFlatUp(location,-perp,cycle)
    else
        leftWall,leftFloor = self:getWallTopDown(lWallPredict,-perp2,cycle,wallThreshold)
    end
    if  leftWall == nil then
        --print("Left Top Down scan failed",wallThreshold,cycle)
        -- do failsafe scan? -- increase/decrease threshold/granularity?
        --table.insert(self.debugEffects,self:generateEffect(location + self.shape.up *3.5 ,sm.color.new('bbbb00ff'))) -- oarnge dot at start location
        leftWall = self:getWallAngleDown(location,-perp,cycle) -- TODO: use perp or perp2??
        if leftWall == nil then -- only three methods
            --print("Left Angle Down Scan failed")
            leftWall = self:getWallFlatUp(location,-perp,cycle)
            if leftWall == nil then 
                print("Left All scanning methods failed",location,-perp,cycle)
                self:createEfectLine(location,lWallPredict,sm.color.new('aa3300ff')) -- redish orange line shows where it thinks the wall should be
                -- TODO: Have wall scans send back scan pos debug when failed
                print("could not Scan left Wall",location)
                self.scanError = true
                self.errorReason = "could not Scan left Wall"
                return nil
            end
        end
    else -- we found the wall, create debug effect line
        self:checkForSharpEdge(location,leftWall,cycle) -- returns true/false for morefailsafes
    end

    --print("\nRight Wall Scan:")
    ------ RIGHT WALL SCAN
    local rWallPredict = location + (perp2*rightWallDist) 
    rWallPredict.z = lastRightWall.z -- adjust zval
    local rightWall,rightFloor = nil
    if inTunnel then -- if in tunnel just look directly left and right for walls
        rightWall = self:getWallFlatUp(location,perp,cycle) -- find left wall
    else
        rightWall,rightFloor = self:getWallTopDown(rWallPredict,perp2,cycle,wallThreshold)
    end
    if  rightWall == nil then
        --print("Right Top Down scan failed",wallThreshold,cycle)
        --table.insert(self.debugEffects,self:generateEffect(location + self.shape.up *3.5 ,sm.color.new('bbbb00ff'))) -- oarnge dot at start location
        rightWall = self:getWallAngleDown(location,perp,cycle)
        if rightWall == nil then -- only three methods
            --print("Right angle down Scan failed")
            rightWall = self:getWallFlatUp(location,perp,cycle)
            if rightWall == nil then 
                print("Right All scanning methods failed",location,perp,cycle)
                self:createEfectLine(location,rWallPredict,sm.color.new('aa3300ff')) -- redish orange line shows where it thinks the wall should be
                -- TODO: Have wall scans send back scan pos debug when failed, Possibly have it force a wall at the rWall Predict place (fill in gaps)
                print("could not Scan right Wall",location)
                self.scanError = true
                self.errorReason = "could not scan right Wall"
                return nil
            end
        end
    else -- we found the wall, create debug effect line
        self:checkForSharpEdge(location,rightWall,cycle)
    end
    
    -- TODO: find top of wall by scanning from bottom up until drastic raycast diff is found
    -- Error checking

    if rightWall == nil or leftWall == nil then
        print("Something went wrong While scanning track")
        -- Just Return Best Guess Which is just location but new floor
        self.scanError = true
        self.errorLocation = location
        return location
    end
    local midPoint = getMidpoint(leftWall,rightWall)
    midPoint.z = floor -- sets the floor as a track ground, 
    local width = getDistance(leftWall,rightWall) -- -1 padding?
    
    local bankThresh = 1 -- threshold to determine banking -- Can use height over width to get angle: bankAngle = (floorLeft - floorRight)/width
    local floorBank = 0
    local bankAngle = 0
    -- Removed Wall-based bank detection
    if leftFloor and rightFloor then
        if leftFloor - rightFloor > bankThresh then -- If left wall is 3? higher than right wall, it is banked right
            floorBank = 1
        elseif rightFloor - leftFloor > bankThresh then -- if right wall is 3? hgihter than left wall, it is banked left
            floorBank = -1
        end -- else bank is 0
        bankAngle = (leftFloor-rightFloor)/width
    end
    return midPoint, width,leftWall,rightWall,bankAngle
end


function Generator.backTraceSegment(self,initNode,startNode,straightThreshold,straightCutoff) -- goes backwards and finds beginning of turn + 3 nodes
    if initNode == nil then print("Error No init node") return end
    if initNode.id == startNode.id then 
        print("same init and start, single node trace: returning stright",initNode.id,startNode.id)
        return initNode
    end
    local index = startNode.id - 1
    local initAngle = vectorToDegrees(initNode.outVector)
    local lastAngle = 0
    local lastAngleDif = 0
    local numStraight = 0
    --local straightThreshold = straightThreshold or 1 -- angle difference before not considered straight line
    --local straightCutoff = straightCutoff or 3 -- how many straight nodes found before cutting of segment
    
    for k = index, initNode.id ,-1 do local node = self.nodeChain[k] -- used to back trace until 1, Changed to backtrace to startnode
        if node.id == self.nodeChain[1].id or node.id == initNode.id then -- Beginning of segment found
            return node
        end
        -- determine if node is the last node of last segment then quit
        --local angle = getNodeAngle(initNode,node)
        local curAngle = vectorToDegrees(node.outVector)
        local initAngleDif = math.abs(initAngle - curAngle)
        local curAngleDif =  math.abs(curAngle - lastAngle)

        if curAngleDif < straightThreshold then -- lastAngleDif == nil checked before
            numStraight = numStraight + 1 -- straight found?
            lastAngle = curAngle
            lastAngleDif = curAngleDif
        else -- continue to watch curve
            lastAngleDif = curAngleDif
            numStraight = 0 -- reset counter
            lastAngle = curAngle
            lastAngleDif = curAngleDif
        end

        if numStraight >= straightCutoff then -- enough to end curve
            numStraight = 0
            return node
        end
    end

end

--segment analyzer attempt # 6 
function Generator.analyzeSegment(self,initNode) -- Attempt # 5
    if initNode == nil then print("Error No init node") return end
    local index = initNode.id
    local initAngle = vectorToDegrees(initNode.outVector)
    local apexNode = nil
    local apexAngle = 0
    local lastAngle = 0
    local lastAngleDif = 0
    local numStraight = 0
    local straightThreshold = 3 -- min angle difference between last and current node to be considered straight
    local straightCutoff = 2 -- how many straight nodes found before cutting off curve
    local turnDir = 0
    local turnThreshold = 6-- how many degrees difference from initial node to determine a turn
    local turnCount = 0
    local turnCountThresh = 2 -- How many valid turning nodes before triggering apex node
    --print("startigna init",index,self.nodeChain[1].id,self.nodeChain[1].segID)
    for k = index, #self.nodeChain do local node = self.nodeChain[k] -- maybe not do whole chain?
        if node.next.id == self.nodeChain[1].id then
            startNode = self:backTraceSegment(initNode,node,straightThreshold,straightCutoff) -- backtraces to start
            --print("first backtraced",startNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
            return startNode,node, true
        end
        
        local angle = getNodeAngle(initNode,node) -- double check this
        --local angle = vectorAngleDiff(initNode.outVector,node.outVector)
        local curAngle = vectorToDegrees(node.outVector)
        local initAngleDif = math.abs(curAngle - initAngle) -- smooths out going from 180 to - 180
        local curAngleDif =  math.abs(curAngle - lastAngle) -- difference from last angle node
        if math.abs(curAngleDif) > 50 then -- check for sharp angle meaning it jumped from - to +
            local absDif = math.abs(lastAngle) - math.abs(curAngle)
            --print("Got sharp dif2",lastAngle,curAngle,absDif)
            if absDif < 5 then
                curAngleDif = absDif * getSign(curAngleDif)
            end
        end
        if node.id > 350 then 
            --print(node.id,"angleDif",initAngleDif,curAngleDif,curAngle-initAngle,curAngle,initAngle)
        end
        if apexNode ~= nil then -- if curve has been discovered , continue down curve until straight path found or reversal of turn
            if curAngleDif < straightThreshold then
                numStraight = numStraight + 1
                lastAngle = curAngle
                lastAngleDif = curAngleDif
            else
                lastAngleDif = curAngleDif
                lastAngle = curAngle
                numStraight = 0 -- reset counter
            end

            if numStraight >= straightCutoff then -- If cutoff number of "straight nodes found"
                startNode = self:backTraceSegment(initNode,apexNode,straightThreshold,straightCutoff) -- Go back from the discovered turn node to the begining of the straight
                
                numStraight = 0
                return startNode,node,false
            end
        else -- No Curve discovered, check if any of the angles are greater than the turn discovery, possibly count how many are above thresh?
            if initAngleDif > turnThreshold then -- angle > turnThreshold
                if turnCount < turnCountThresh then
                    turnCount = turnCount + 1
                    lastAngle = curAngle
                    lastAngleDif = curAngleDif
                else
                    apexNode = node -- Not technicaly apex node but this is the discovered turning node
                    lastAngleDif = curAngleDif -- angle
                    apexAngle = angle
                    lastAngle = curAngle
                    -- increment TurnDiscovery Counter if desired
                end
            else
                lastAngle = curAngle
            end
        end
    end
end


function Generator.setSegmentApex(self,segment) -- Sets
        local midIndex = round(#segment / 2)
        local nodeID = segment[midIndex]
        self.nodeChain[nodeID.id].apex = 1
end

function Generator.scanTrackSegments(self) -- Pairs with analyze Segments TODO: run a filterpass over segments and combine all like/adjacent segments into one segID
    local firstNode = self.nodeChain[1]
    local segID = 1
    local done = false
    local finished = false
    local flag = nil
    -- Set midpoint as apex, but once a node gets closest to wall, that can be re-set as new apex
    local startNode, endNode, finished = self:analyzeSegment(firstNode) -- returns segment start and end
    --print("firstNode",firstNode.id,#self.nodeChain)
    --print("First scan got", startNode.id,endNode.id)
    local lastNode
    local firstSegment = getSegment(self.nodeChain,firstNode,startNode) -- create segment
    --print("betweenSeg?",#firstSegment,firstNode.id,startNode.id)
    if #firstSegment > 1 then -- if curve has straight seg before
        local sType,angle = defineSegmentType(firstSegment)
        --print(segID,"Setting Between segment (start)",firstNode.id,startNode.id,sType.TYPE,angle)
        local output = segID.." setting between seg at start, " .. firstNode.id .. " - " .. startNode.id .. " : " .. sType.TYPE
        --sm.log.info(output)
        setSegmentType(firstSegment,sType,angle,segID)
        segID = segID + 1
        --lastNode = startNode
        --startNode
    else
        --sm.log.info("no between seg at start")
    end
    local segment = getSegment(self.nodeChain,startNode,endNode)
    local sType,angle = defineSegmentType(segment)
    --self:setSegmentApex(segment)
    --print(segID,"setting first segment",startNode.id,endNode.id,sType.TYPE,angle,self.nodeChain[1].id,self.nodeChain[1].segID)
    local output = segID.." setting first segment " .. startNode.id .. " - " .. endNode.id .. " : " .. sType.TYPE
    --sm.log.info(output)
    setSegmentType(segment,sType,angle,segID)
    segID = segID + 1
    lastNode = endNode
     -- store whatever the last node was to find between segments
    
    local scanTimeout = #self.nodeChain + 1
    local timeoutCounter = 0
    while not done do -- Why are we doing this?
        --print("StartLoop",startNode.id,endNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
        startNode = endNode.next
        lastNode = startNode -- store last segment end
        startNode,endNode,finished = self:analyzeSegment(startNode)
       -- print("post Segment:",startNode.id,endNode.id,segID)

        -- check for segment between
        --print("finding segments",lastNode.id,startNode.id,endNode.id)
        local betweenSeg = getSegment(self.nodeChain,lastNode,startNode) -- discover if there is segment before first "turn segment"
        --print("betweenseg?",lastNode.id,startNode.id, #betweenSeg, self.nodeChain[1].id,self.nodeChain[1].segID)
        if #betweenSeg > 1 then -- If there is no segment between last turn and next turn
            --print("set between seg")
            local sType,angle = defineSegmentType(betweenSeg)
            --print(segID,"setting between segment",lastNode.id,startNode.id,sType.TYPE,angle,self.nodeChain[1].id,self.nodeChain[1].segID)
            local output = segID.." setting between segment " .. lastNode.id .. " - " .. startNode.id .. " : " .. sType.TYPE
            --sm.log.info(output)
            --print("setting segment type between",lastNode.id,startNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
            setSegmentType(betweenSeg,sType,angle,segID)
            --print("post set segment between",self.nodeChain[1].id,self.nodeChain[1].segID)
            segID = segID + 1
        else -- set a segment between them first
            --print(segID,"no between seg",#betweenSeg,self.nodeChain[1].id,self.nodeChain[1].segID)
        end    
        -- Acutally set turn segment
        --print("getting segment",startNode.id,endNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
        local segment = getSegment(self.nodeChain,startNode,endNode)
        --self:setSegmentApex(segment)
        local sType,angle = defineSegmentType(segment)
        --print(segID,"setting segment type",startNode.id,endNode.id,sType.TYPE,angle,self.nodeChain[1].id,self.nodeChain[1].segID)
        local output = segID.." setting next segment " .. startNode.id .. " - " .. endNode.id .. " : " .. sType.TYPE
        --sm.log.info(output)
        setSegmentType(segment,sType,angle,segID)
        if finished then -- TODO: Figure if this will still work
            -- Check between then set final segment?
            done = true
            break
        end

        -- Iterate forward (timeout and segment?)
        segID = segID +1 
        timeoutCounter = timeoutCounter + 1
        if timeoutCounter >= scanTimeout then 
            print("track seg scan timeout",timeoutCounter,scanTimeout)
            break
        end
    end
    self.totalSegments = segID
    
    print("Finished scan, Segment Count:",self.totalSegments,"Node Count:",#self.nodeChain)
    --print(self.nodeChain[#self.nodeChain-1].id,self.nodeChain[#self.nodeChain-1].segType)
end




------------------------ portion for seg gen after man conmfirm ----------------

function Generator.backTraceSegmentMan(self,initNode,startNode,straightThreshold,straightCutoff) -- goes backwards and finds beginning of turn + 3 nodes
    if initNode == nil then print("Error No init node") return end
    if initNode.id == startNode.id then 
        print("same init and start, single node trace: returning stright",initNode.id,startNode.id)
        return initNode
    end
    local index = startNode.id - 1
    local initAngle = vectorToDegrees(initNode.outVector)
    local lastAngle = 0
    local lastAngleDif = 0
    local numStraight = 0
    --local straightThreshold = straightThreshold or 1 -- angle difference before not considered straight line
    --local straightCutoff = straightCutoff or 3 -- how many straight nodes found before cutting of segment
    
    for k = index, initNode.id ,-1 do local node = self.nodeChain[k] -- used to back trace until 1, Changed to backtrace to startnode
        if node.id == self.nodeChain[1].id or node.id == initNode.id then -- Beginning of segment found
            return node
        end
        -- determine if node is the last node of last segment then quit
        --local angle = getNodeAngle(initNode,node)
        local curAngle = vectorToDegrees(node.outVector)
        local initAngleDif = math.abs(initAngle - curAngle)
        local curAngleDif =  math.abs(curAngle - lastAngle)

        if curAngleDif < straightThreshold then -- lastAngleDif == nil checked before
            numStraight = numStraight + 1 -- straight found?
            lastAngle = curAngle
            lastAngleDif = curAngleDif
        else -- continue to watch curve
            lastAngleDif = curAngleDif
            numStraight = 0 -- reset counter
            lastAngle = curAngle
            lastAngleDif = curAngleDif
        end

        if numStraight >= straightCutoff then -- enough to end curve
            numStraight = 0
            return node
        end
    end

end

--segment analyzer attempt # 6 
function Generator.analyzeSegmentMan(self,initNode) -- Attempt # 5
    if initNode == nil then print("Error No init node") return end
    local index = initNode.id
    local initAngle = vectorToDegrees(initNode.outVector)
    local apexNode = nil
    local apexAngle = 0
    local lastAngle = 0
    local lastAngleDif = 0
    local numStraight = 0
    local straightThreshold = 4 -- min angle difference between last and current node to be considered straight
    local straightCutoff = 1 -- how many straight nodes found before cutting off curve
    local turnDir = 0
    local turnThreshold = 5-- how many degrees difference from initial node to determine a turn
    local turnCount = 0
    local turnCountThresh = 1 -- How many valid turning nodes before triggering apex node
    --print("startigna init",index,self.nodeChain[1].id,self.nodeChain[1].segID)
    for k = index, #self.nodeChain do local node = self.nodeChain[k] -- maybe not do whole chain?
        if node.next.id == self.nodeChain[1].id then
            startNode = self:backTraceSegmentMan(initNode,node,straightThreshold,straightCutoff) -- backtraces to start
            --print("first backtraced",startNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
            return startNode,node, true
        end
        
        local angle = getNodeAngle(initNode,node) -- double check this
        --local angle = vectorAngleDiff(initNode.outVector,node.outVector)
        local curAngle = vectorToDegrees(node.outVector)
        local initAngleDif = math.abs(curAngle - initAngle) -- smooths out going from 180 to - 180
        local curAngleDif =  math.abs(curAngle - lastAngle) -- difference from last angle node
        if math.abs(curAngleDif) > 50 then -- check for sharp angle meaning it jumped from - to +
            local absDif = math.abs(lastAngle) - math.abs(curAngle)
            print("Got sharp dif2",lastAngle,curAngle,absDif)
            if absDif < 5 then
                curAngleDif = absDif * getSign(curAngleDif)
            end
        end
        print(node.id,"angleDif",initAngleDif,curAngleDif,curAngle-initAngle,curAngle,initAngle)
        
        if apexNode ~= nil then -- if curve has been discovered , continue down curve until straight path found or reversal of turn
            if curAngleDif <= straightThreshold then
                numStraight = numStraight + 1
                lastAngle = curAngle
                lastAngleDif = curAngleDif
            else
                lastAngleDif = curAngleDif
                lastAngle = curAngle
                numStraight = 0 -- reset counter
            end

            if numStraight >= straightCutoff then -- If cutoff number of "straight nodes found"
                --print("found straight", backtracing)
                startNode = self:backTraceSegmentMan(initNode,apexNode,straightThreshold,straightCutoff) -- Go back from the discovered turn node to the begining of the straight
                numStraight = 0
                return startNode,node,false
            end
        else -- No Curve discovered, check if any of the angles are greater than the turn discovery, possibly count how many are above thresh?
            if initAngleDif >= turnThreshold then -- angle > turnThreshold
                --print("theshboof",initAngleDif,turnCount,turnCountThresh)
                if turnCount < turnCountThresh then
                    turnCount = turnCount + 1
                    lastAngle = curAngle
                    lastAngleDif = curAngleDif
                else
                    --print("Discovered turning node",node.id,initAngleDif,turnCount,turnCountThresh)
                    apexNode = node -- Not technicaly apex node but this is the discovered turning node
                    lastAngleDif = curAngleDif -- angle
                    apexAngle = angle
                    lastAngle = curAngle
                    -- increment TurnDiscovery Counter if desired
                end
            else
                lastAngle = curAngle
            end
        end
    end
end


function Generator.scanTrackSegmentsMan(self) -- Pairs with analyze Segments TODO: run a filterpass over segments and combine all like/adjacent segments into one segID
    local firstNode = self.nodeChain[1]
    local segID = 1
    local done = false
    local finished = false
    local flag = nil
    -- Set midpoint as apex, but once a node gets closest to wall, that can be re-set as new apex
    local startNode, endNode, finished = self:analyzeSegmentMan(firstNode) -- returns segment start and end
    --print("firstNode",firstNode.id,#self.nodeChain)
    --print("First scan got", startNode.id,endNode.id)
    local lastNode
    local firstSegment = getSegment(self.nodeChain,firstNode,startNode) -- create segment
    --print("betweenSeg?",#firstSegment,firstNode.id,startNode.id)
    if #firstSegment > 1 then -- if curve has straight seg before
        local sType,angle = defineSegmentType(firstSegment)
        --print(segID,"Setting Between segment (start)",firstNode.id,startNode.id,sType.TYPE,angle)
        local output = segID.." setting between seg at start, " .. firstNode.id .. " - " .. startNode.id .. " : " .. sType.TYPE
        --sm.log.info(output)
        setSegmentType(firstSegment,sType,angle,segID)
        segID = segID + 1
        --lastNode = startNode
        --startNode
    else
        --sm.log.info("no between seg at start")
    end
    local segment = getSegment(self.nodeChain,startNode,endNode)
    local sType,angle = defineSegmentType(segment)
    --self:setSegmentApex(segment)
    print(segID,"setting first segment",startNode.id,endNode.id,sType.TYPE,angle,self.nodeChain[1].id,self.nodeChain[1].segID)
    local output = segID.." setting first segment " .. startNode.id .. " - " .. endNode.id .. " : " .. sType.TYPE
    sm.log.info(output)
    setSegmentType(segment,sType,angle,segID)
    segID = segID + 1
    lastNode = endNode
     -- store whatever the last node was to find between segments
    
    local scanTimeout = #self.nodeChain + 1
    local timeoutCounter = 0
    while not done do -- Why are we doing this?
        --print("StartLoop",startNode.id,endNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
        startNode = endNode.next
        lastNode = startNode -- store last segment end
        startNode,endNode,finished = self:analyzeSegmentMan(startNode)
       -- print("post Segment:",startNode.id,endNode.id,segID)

        -- check for segment between
        --print("finding segments",lastNode.id,startNode.id,endNode.id)
        local betweenSeg = getSegment(self.nodeChain,lastNode,startNode) -- discover if there is segment before first "turn segment"
        --print("betweenseg?",lastNode.id,startNode.id, #betweenSeg, self.nodeChain[1].id,self.nodeChain[1].segID)
        if #betweenSeg > 1 then -- If there is no segment between last turn and next turn
            --print("set between seg")
            local sType,angle = defineSegmentType(betweenSeg)
            print(segID,"setting between segment",lastNode.id,startNode.id,sType.TYPE,angle,self.nodeChain[1].id,self.nodeChain[1].segID)
            local output = segID.." setting between segment " .. lastNode.id .. " - " .. startNode.id .. " : " .. sType.TYPE
            sm.log.info(output)
            --print("setting segment type between",lastNode.id,startNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
            setSegmentType(betweenSeg,sType,angle,segID)
            --print("post set segment between",self.nodeChain[1].id,self.nodeChain[1].segID)
            segID = segID + 1
        else -- set a segment between them first
            --print(segID,"no between seg",#betweenSeg,self.nodeChain[1].id,self.nodeChain[1].segID)
        end    
        -- Acutally set turn segment
        --print("getting segment",startNode.id,endNode.id,self.nodeChain[1].id,self.nodeChain[1].segID)
        local segment = getSegment(self.nodeChain,startNode,endNode)
        --self:setSegmentApex(segment)
        local sType,angle = defineSegmentType(segment)
        print(segID,"setting segment type",startNode.id,endNode.id,sType.TYPE,angle,self.nodeChain[1].id,self.nodeChain[1].segID)
        local output = segID.." setting next segment " .. startNode.id .. " - " .. endNode.id .. " : " .. sType.TYPE
        sm.log.info(output)
        setSegmentType(segment,sType,angle,segID)
        if finished then -- TODO: Figure if this will still work
            -- Check between then set final segment?
            done = true
            break
        end

        -- Iterate forward (timeout and segment?)
        segID = segID +1 
        timeoutCounter = timeoutCounter + 1
        if timeoutCounter >= scanTimeout then 
            print("track seg scan timeout",timeoutCounter,scanTimeout)
            break
        end
    end
    self.totalSegments = segID
    
    print("Finished scan, Segment Count:",self.totalSegments,"Node Count:",#self.nodeChain)
    --print(self.nodeChain[#self.nodeChain-1].id,self.nodeChain[#self.nodeChain-1].segType)
end



function Generator.generateSegmentsMan(self) -- starts loading track segments, better results after optimization is complete
    self:scanTrackSegmentsMan()
    self:hardUpdateVisual()
end

-------------------- end manPortion ------------



function Generator.generateSegments(self) -- starts loading track segments, better results after optimization is complete
    self:scanTrackSegments()
    self:hardUpdateVisual()
end



function Generator.setSectorIDs(self)
    --print("setting sector IDs")
    local totalNodes = #self.nodeChain
    local sectorSplit = totalNodes / 3
    --print(totalNodes,sectorSplit)
    for i=1, totalNodes do 
        local v = self.nodeChain[i]
        local sector = math.ceil(v.id/sectorSplit)
        v.sectorID = sector
    end
end

--- Node design (after segments deleted)
--- { id, -- Individual Node Unique Identifier
---  distance, -- Units of distance from the first node (accumulates)
---  location, -- Vec3 xyz location of node (racing line)
---  mid, -- Middle of track between the two scanned walls 
---  width, -- Width of the "track" between the two scanned walls
---  outVector,  -- Vector leading towards next node, track direction
---  perp, -- Perpendicular vector to the node's outvector
---  incline, -- How much the vector moves vertically, 
---  bank, -- How much the track is "leaned" like in banked ovals 
---  sectorID -- Which sector the node is in (for lap tracking)
--- }
function Generator.simplifyNodeChain(self) 
    local simpChain = {}
    --sm.log.info("simping node chain") -- TODO: make sure all seg IDs are consistance
    for k=1, #self.nodeChain do local v=self.nodeChain[k]
        output = v.segID .. ": " .. v.id
        --sm.log.info(output) Possibly export into json for track transport
        local newNode = {id = v.id, distance = v.distance, location = v.pos, segID =v.segID, segType = v.segType.TYPE,
                         segCurve = v.segCurve, mid = v.midPos, width = v.width, perp = v.perpVector, 
                         outVector = v.outVector,incline = v.incline, bank = v.bank, sectorID = v.sectorID } -- add race instead of location?-- Radius? Would define vMax here but car should calculate it instead
        table.insert(simpChain,newNode)
    end
    --print("simpchain = ",simpChain)
    return simpChain
end


function Generator.simplifyPitChain(self) -- Dont really need to do this... but just in case cl to sv needs it
    local simpChain = {}
    --sm.log.info("simping node chain") -- TODO: make sure all seg IDs are consistance
    for k=1, #self.pitChain do local v=self.pitChain[k]
        local newNode = {id = v.id, distance = v.distance, location = v.pos, pointType =v.pointType,  mid = v.midPos,
                   pit = v.pitPos, width = v.width, perp = v.perpVector, 
                         outVector = v.outVector,incline = v.incline, bank = v.bank, sectorID = v.sectorID } -- add race instead of location?-- Radius? Would define vMax here but car should calculate it instead
        table.insert(simpChain,newNode)
    end
    --print("simpchain = ",simpChain)
    return simpChain
end

function Generator.simplifyBoxChain(self) -- get pit boxes and simplify to array
    local boxChain = {}
    for k=1, #PIT_CHAIN_CONFIG.pbox_arr do local v=PIT_CHAIN_CONFIG.pbox_arr[k]
        local newNode = {id = v.id, location = v.location, pointType ="box", size = v.size, boxDimensions = v.boxDimensions, assigned = 0, remaining = 0, nextDriver = 0, nextRemaining = 0} -- add race instead of location?-- Radius? Would define vMax here but car should calculate it instead
        table.insert(boxChain,newNode)
    end
    return boxChain
end

-- Saving and loading?jk    
function Generator.saveRacingLine(self) -- client Saves nodeChain, may freeze game --TODO: have ways for people to send me their nodes to make track SMAR certified, (send client json? send file?)
    self:setSectorIDs() -- set sector IDs
    self.simpNodeChain = self:simplifyNodeChain()
    
 
    local data = {channel = TRACK_DATA, raceLine = true, pitline = #self.simpPitChain >= 0 and #self.simpPitBoxes > 1} -- Eventually have metaData too?
    self.network:sendToServer("sv_saveData",data)
    sm.gui.displayAlertText("Scan Complete: Track Saved")
    --print("distance?",self.totalDistance)
    sm.gui.chatMessage("\n Scan Completed, Distance (SM units): " .. string.format("%.2f",tostring(self.totalDistance)))
    if self.pitPoints then -- not needed anymore since pitChain is drawn now
        --self:drawCurPitPoints()
    end

end

function Generator.savePitLine(self)
    self.simpPitChain = self:simplifyPitChain()
    if self.simpPitChain == nil then
        print("no Pit chain")
        return
    end
    self.simpPitBoxes = self:simplifyBoxChain()
    local data = {channel = PIT_DATA, pitline = #self.simpPitChain >= 0 and #self.simpPitBoxes > 1} -- Eventually have metaData too?
    self.network:sendToServer("sv_saveData",data)
    sm.gui.displayAlertText("Pit Line Saved")
    --print("distance?",self.totalDistance)
    sm.gui.chatMessage("\n Pit Line Saved")
    if self.pitPoints then -- not needed anymore since pitChain is drawn now
        --self:drawCurPitPoints()
    end
end

function Generator.sv_saveData(self,data)
    debugPrint(self.debug,"Saving data") -- change raceline into Pitline = true or false to determine if there is a pitChain
    --debugPrint(self.debug,data)
    --print("saving",self.pitChain)
    local channel = data.channel

    data = {["raceChain"] = self.simpNodeChain, ["pitChain"] = self.simpPitChain, ["pitBoxes"] = self.simpPitBoxes} 
    -- was data.raceLine --{hello = 1,hey = 2,  happy = 3, hopa = "hdjk"}
    --print("saving boxes",data['pitBoxes'])
    sm.storage.save(channel,data) -- track was channel
    --sm.terrainData.save(data) -- saves as terrain??
    saveData(data,channel) -- worldID?

    print("Track Saved")
end

function Generator.loadData(self,channel) -- Loads any data?
    local data = self.network:sendToServer("sv_loadData",channel)
    if data == nil then
        print("Data not found?",channel)
        if data == nil then
            print("all data gone",data)
        end
    end
    return data
end

function Generator.sv_loadData(self,channel)
    print("Loading data")
    local data = sm.storage.load(channel)
    print("finished Loading",data)
    local exists = sm.terrainData.exists()
    print("data exists?",exists)
    if exists then 
        local data2 = sm.terrainData.load()
        print("finished loading terrain2",data2)
    end
    return data
end

function Generator.removeNode(self,nodeID) -- removes node
    for k, v in pairs(self.nodeChain) do
		if v.id == nodeID then
            if v.sphereTrigger then
                --print('deleting', v.sphereTrigger:getUserData())
                sm.areaTrigger.destroy(v.sphereTrigger)
                v.sphereTrigger = nil
            end
            if v.effect then
                v.effect:stop()
                v.effect:destroy()
            end
            if v.lEffect then
                v.lEffect:stop()
                v.lEffect:destroy()
            end

            if v.rEffect then
                v.rEffect:stop()
                v.rEffect:destroy()
            end
			table.remove(self.nodeChain, k)
		end
    end
    -- re index
    for k, v in pairs(self.nodeChain) do
		--print(k)
        v.id = k
    end
    -- re segID
end

function Generator.removePitNode(self,nodeID) -- removes node
    for k, v in pairs(self.pitChain) do
		if v.id == nodeID then
            if v.sphereTrigger then
                --print('deleting', v.sphereTrigger:getUserData())
                sm.areaTrigger.destroy(v.sphereTrigger)
                v.sphereTrigger = nil
            end
            if v.effect then
                v.effect:stop()
                v.effect:destroy()
            end
            if v.lEffect then
                v.lEffect:stop()
                v.lEffect:destroy()
            end

            if v.rEffect then
                v.rEffect:stop()
                v.rEffect:destroy()
            end
			table.remove(self.pitChain, k)
		end
    end
    -- re index
    for k, v in pairs(self.pitChain) do
		--print(k)
        v.id = k
    end
    -- re segID
end



function Generator.insertNode(self,nodeID,node) -- Inserts node after given ID
    for k, v in pairs(self.nodeChain) do
		if v.id == nodeID then
            v.next = node
            node.last = v
            node.next = v.next
			table.insert( self.nodeChain, k, node )
		end
    end
    -- re index and re-distance
    local totalDistance = 0
    for k, v in pairs(self.nodeChain) do
		if k > 1 then 
            totalDistance = totalDistance + getDistance(v.midPos,v.last.midPos)
        end
        v.distance = (v.last.distance + getDistance(v.midPos,v.last.midPos) or totalDistance)
        v.id = k
    end
    -- re segID
end

function Generator.getNodeVH(self,node1,node2,searchVector) -- returns horizontal and vertical distances from node1 to node2 
    -- only works on one side of pi?
    --print("getNodeP",node1.id,node1.location,"pepV",node1.perpVector,"sear",searchVector)
    --node1.pos.z = node2.pos.z
    local node1Copy,node2Copy = node1, node2
    node1Copy.z = node2Copy.z -- create fake z levels
    local goalVec = (node2.pos - node1.pos) -- multiply at * velocity? use velocity instead?
    
    local vDist = searchVector:dot(goalVec)
    local hDist = sm.vec3.cross(goalVec,searchVector).z
    
    local vhDifs = {horizontal = vDist, vertical = hDist}
    --print("vhDif",vhDifs)
    return vhDifs
end
-- MainLoop and interaction Functions


-- New ALgo?1
function Generator.racifyLine3(self)
    local straightThreshold = 9 -- Minimum length of nodes a straight has to be
    local nodeOffset = 1 -- number of nodes forward/backwards to pin (cannot be > straightLen/2) TODO; change so it only affects turn exit/entry individually
    local shiftAmmount = 2  -- Maximum node pin shiftiging amound (>2)
    local lockWeight = 10
    local lastSegID = 0 -- start with segId
    local lastSegType = nil
end


-- Working algorithm that is much better at pinning apex/turn efficient points
function Generator.racifyLine(self)
    local straightThreshold = 10 -- Minimum length of nodes a straight has to be
    local nodeOffset = 1 -- number of nodes forward/backwards to pin (cannot be > straightLen/2) TODO; change so it only affects turn exit/entry individually
    local shiftAmmount = 0.05   -- Maximum node pin shiftiging amound (>2)
    local lockWeight = 11
    local lastSegID = 0 -- start with segId
    local lastSegType = nil
    -- TODO: only racify when there curve is a medium or more
    -- Find straight
    for k=1, #self.nodeChain do local node=self.nodeChain[k]
        if lastSegID == 0 and lastSegType == nil then -- first segment
            firstFlag =true
            lastSegID = node.segID
            lastSegType = node.segType.TYPE
            --print("Set first seg2")
        end
        if node.segType.TYPE == "Straight" and lastSegID ~= node.segID then -- If new straight found
            --print(node.segType.TYPE,node.segID)
            local segLen = self:getSegmentLength(node.segID) -- Do findTypeLimits to get real length
            if segLen > straightThreshold then --- skip things too short
                -- offset first and last nodes
                --print("eligible for typelimits",node.id,node.segType.TYPE,segLen)
                local firstNode,lastNode = self:findTypeLimits(node.segType.TYPE,node) -- Gets first and last node that match selected type
                if (firstNode.id == lastNode.id) then -- track has no turns
                    break
                end
                local offsetFirstNode = getNextItem(self.nodeChain,firstNode.id,nodeOffset)
                --print("got first node offset",firstNode.id,offsetFirstNode.id,nodeOffset)
                local offsetLastNode = getNextItem(self.nodeChain,lastNode.id,-nodeOffset)
                --print("got last node offset",lastNode.id,offsetLastNode.id,-nodeOffset)
                -- gather shared vars
                if shiftAmmount > node.width/2 then print("shift ammount too much last",shiftAmmount,node.width) end
                -- actual setting node positions
                local lastTurnDirection = getSegTurn(firstNode.last.segType.TYPE) -- 1 is right, -1 is left ( IF last turn was right turn, exit point should be on left, inverse segTurn)
                if math.abs(lastTurnDirection) >= 1 then
                    local desiredTrackPos = offsetFirstNode.pos
                    desiredTrackPos = offsetFirstNode.pos + (offsetFirstNode.perpVector * (shiftAmmount * -getSign(lastTurnDirection)))
                    offsetFirstNode.pos = desiredTrackPos
                    offsetFirstNode.pinned = false -- pin/weight?
                    offsetFirstNode.weight = lockWeight
                end
                
                local nextTurnDirection = getSegTurn(lastNode.next.segType.TYPE) -- 1 is right, -1 is left ( IF next turn is right turn, entry point should be on left)
                if math.abs(nextTurnDirection) >=1 then
                    desiredTrackPos = offsetLastNode.pos
                    desiredTrackPos = offsetLastNode.pos + (offsetLastNode.perpVector * (shiftAmmount * -getSign(nextTurnDirection)))
                    offsetLastNode.pos = desiredTrackPos
                    offsetLastNode.pinned = false -- pin/weight?
                    offsetLastNode.weight = lockWeight
                end
            end 
            -- else print "too short"
        end
    end
    print("Finished racifying line")
end

-- keeper is count
function Generator.trimCurve(self,segment,keeper) -- Cuts off all nodes besides designated spot and edges
    if keeper == 1 or keeper == #segment then print("this doesnt make sense",keeper) return end 
    print("Trim curve",#segment,keeper,segment[1].id,segment[#segment].id,segment[keeper].id)
    for i = #segment-1, (keeper+1) ,-1 do local v = segment[i]
        v.last.next = v.next
        v.next.last = v.last
        --print("cutting",v.id)
        self:removeNode(v.id)
    end
    for i = (keeper - 1), 2 , -1 do local v = segment[i]
        v.last.next = v.next
        v.next.last = v.last
        --print("cutting",v.id,i,keeper-1)
        self:removeNode(v.id)
    end
    -- or just iterate through whole segment and if v.id == first mid or last then dont cut, will need to be careful since ids do mutate
end

function Generator.trimNodes(self,segment,ammount) -- cuts off the first {ammount} or last {-ammount} of nodes in a segment
    if ammount == 0 then return end 
    if ammount <0 then -- Trim from end
        for i = #segment, (#segment+1) + ammount,-1 do local v = segment[i]
            v.last.next = v.next
            v.next.last = v.last -- blip out
            self:removeNode(v.id)
        end
    elseif ammount > 0 then
        for i = 1, ammount do local v = segment[i]
            v.last.next = v.next
            v.next.last = v.last -- blip out
            self:removeNode(v.id)
        end
    else
        print("what?")
    end
end

function Generator.optimizeRaceLine(self) -- {BETA} Will try to find fastest average velocity (short path better...)
    --if true then return end
    self.isOptimizing = true
    local phase1Done = true -- monitors when all apex ndoes are done
    local poiWeight = 10 --  poi = firt/last node and apex is pinned
    --print('optimize',self.nodeChain[1].effect)
    if self.phase1Done == false then  -- if not done with phase 1
        for segID=1, self.totalSegments do
            if self.phase2Running == true then break end -- don't keep looking if on phase 2
            if self.phase1Running == false then self.phase1Running = true end -- trigger phase1
            local segment = findSegment(self.nodeChain,self.totalSegments,segID)
            if segment == nil then 
                print(" no segment found") 
                break
            end
            local apexNode = findSegApex(segment)
            if apexNode == nil then -- TODO shorterhand this?
                --print(segID,"No apex node found") 
            else
                local segTurn = getSegTurn(apexNode.segType.TYPE)
                local dir = getSign(segTurn) -- turn direction
                if (segTurn >=2 or segTurn <=-2) and apexNode.apex == 1 then -- only do this for medium and slow turns and initial apex found
                    phase1Done = false
                    local perpV = apexNode.perpVector
                    local changeDir = perpV * getSign(segTurn)
                    for k=1, #segment do local v = segment[k] -- TODO: test if segment and node chain are same object
                        local node = self.nodeChain[v.id]
                        local nextNodePosition = nil -- potential position of next node after perpV shift
                        nextNodePosition = getPosOffset(v.pos,changeDir,0.15) -- Dampen it based v.weight
                        if nextNodePosition ~= nil then 
                            if validChange(v,nextNodePosition,perpV,dir) then
                                v.pos = nextNodePosition
                            else
                                apexNode.apex = 2 -- dont switch apex nodes 
                                --v.apex = 0
                            end
                        end
                    end
                elseif apexNode.apex == 2 then
                    apexNode.pinned = true
                    phase1Done = false
                    local segLen = #segment
                    local firstNode = segment[1].id
                    local lastNode = segment[segLen].id
                    local preNodes = apexNode.id - firstNode
                    local postNodes = lastNode - apexNode.id
                    local cutoffCount = preNodes - postNodes
                   
                    self:trimNodes(segment,cutoffCount) -- evens curve to equal nodes either side of apex
                    --print("trimming curve",apexIndex,segment[apexIndex].id,apexNode.id)
                    local apexIndex = preNodes + 1 
                    --self:trimCurve(segment,apexIndex) -- cuts nodes out of turn
                    apexNode.apex = 3 -- next stage
                elseif apexNode.apex == 3 or apexNode.apex == 4 then -- if we already trimmed the node and edge nodes are not at outside walls yet
                    phase1Done = false
                    local segLen = #segment
                    local firstNode = segment[1]
                    local lastNode = segment[segLen]
                
                    local preNodes = apexNode.id - firstNode.id
                    local postNodes = lastNode.id - apexNode.id
                    if false then --preNodes ~= postNodes then
                        --print(segID,"somehow uneven cut",preNodes,postNodes)
                    else
                        --local midPoint = getMidpoint(firstNode.pos,lastNode.pos)
                        -- Use nodes.mid instead??
                        if apexNode['curveOrigin'] == nil then 
                            local curveOrigin = getCurveOrigin(firstNode.pos,lastNode.pos,apexNode.pos)-- find point that is average same distance away from all nodes (so group midpoint?)
                            apexNode['curveOrigin'] = curveOrigin
                        else -- start moving endNodes by perp axist of curveOrgigin
                            local firstNodeVector = (firstNode.pos - apexNode['curveOrigin']):normalize() -- use equipoint
                            local lastNodeVector = (lastNode.pos - apexNode['curveOrigin'] ):normalize()
                            
                            firstNodePerp = firstNode.perpVector * -getSign(segTurn) -- Use perp
                            lastNodePerp = lastNode.perpVector * -getSign(segTurn)
                            
                            local fnPos = nil -- potential position of first node after vector shift
                            local lnPos = nil -- potential position of last node after vector shift
                            
                            fnPos = getPosOffset(firstNode.pos, firstNodeVector, 0.1) 
                            lnPos = getPosOffset(lastNode.pos, lastNodeVector, 0.1) 

                            
                            fnPos = getPosOffset(fnPos, firstNodePerp, 0.05) -- offset outwards (lef/right) until wall
                            lnPos = getPosOffset(lnPos, lastNodePerp, 0.05) 

                            fnPos = getPosOffset(fnPos, firstNode.outVector * -1, 0.1) -- offset forward/backward until wall
                            lnPos = getPosOffset(lnPos, lastNode.outVector, 0.1) 


                            -- now shif
                            if fnPos ~= nil and validChange(firstNode,fnPos,firstNode.perpVector,-dir) then 
                                firstNode.pos = fnPos
                                --print("moving",firstNode.id)
                            else
                                if firstNode['atExitWall'] == nil then
                                    apexNode.apex = apexNode.apex + 1
                                    firstNode['atExitWall'] = true
                                    firstNode.pinned = true
                                    firstNode.weight = 3
                                    --print('setting node weig',firstNode.id,firstNode.weight,self.nodeChain[firstNode.id].weight)
                                end
                            end

                            if lnPos ~= nil and validChange(lastNode,lnPos,lastNode.perpVector,-dir) then 
                                lastNode.pos = lnPos
                            else
                                if lastNode['atExitWall'] == nil then
                                    apexNode.apex = apexNode.apex + 1
                                    lastNode['atExitWall'] = true
                                    lastNode.pinned = true
                                    lastNode.weight = 3
                                end
                            end
                        end
                    end

                elseif apexNode.apex == 5 then  -- cut nodes that are too close to next important
                   -- Nothing here anymore
                   -- set phase1 done?
                elseif apexNode.apex == 6 then
                    --phase1Done = false wait until all are here then increment again
                end
            end
        end
        if phase1Done and self.phase2Running == false then -- Transition to phase 2
            print('starting phase2')
            self.phase2Running = true -- 
            self.phase1Done = true
            self.phase1Running = false
        end
    elseif self.phase2Running then
        -- Cut off too close nodes
        local all_trimmed = true
        for k=1, #self.nodeChain do local v=self.nodeChain[k]
            local perpV = v.perpVector
            local vhDifLast = self:getNodeVH(v,v.last,perpV)
            local vhDifNext =  self:getNodeVH(v.next,v,perpV)
            local lastOverlap = false
            local nextOverlap = false
            if vhDifLast.vertical <40 then -- Overlapped, trim
                lastOverlap = true
            end
            if vhDifNext.vertical < 40 then
                nextOverlap = true
            end
            -- delete self if overlapping nodes and not pinned
    
            --if getDistance(v.last.pos,v.next.pos) < 1.5 then
            --    --print("really close nodes d")
            --   lastC = true
            --   nextC = true
            --end

            if not v.pinned then -- if self is an apex node
                if nextOverlap then -- if close enough to next node
                    --print("trimming node",v.id,v.pos)
                    if v.next.pinned then
                        --print("Cutting",k,v.id,vhDifNext)
                        all_trimmed = false
                        v.last.next = v.next
                        v.next.last = v.last
                        self:removeNode(v.id)
                        break -- return false
                    end
                end
                if lastOverlap then
                    if v.last.pinned then
                         --print("Cutting",k,v.id,vhDifNext)
                         all_trimmed = false
                         v.last.next = v.next
                         v.next.last = v.last
                         self:removeNode(v.id)
                         break -- return false
                    end
                end  
            end
        end
        if all_trimmed then
            print("all trimed")
        else
            return false -- go to end of loop ?
        end


        -- Cutss off overlapping turns
        print("doing intersect")
        for segID=1, self.totalSegments do
            local segment = findSegment(self.nodeChain,self.totalSegments,segID)
            if segment ~= nil then 
                
                local segTurn = getSegTurn(segment[1].segType.TYPE)
                if (segTurn >=2 or segTurn <=-2) then -- If turn is a turn
                    local firstApexNode = findSegApex(segment)
                    local lastNode = segment[#segment]
                    if segID < self.totalSegments then
                        local nextSegID = segID + 1
                        local nextSegment = findSegment(self.nodeChain,self.totalSegments,nextSegID)
                        if nextSegment then 
                            local nextSegTurn = getSegTurn(nextSegment[1].segType.TYPE)
                            if (nextSegTurn >=2 or nextSegTurn <=-2) then -- Two medium to sharp turns back to back discovered
                                -- get the intersection between the last part of first tirn and first part of last turn
                                local nextStartNode = nextSegment[1]
                                local nextApexNode = findSegApex(nextSegment)
                                local endLine = {sm.vec3.new(firstApexNode.pos.x,firstApexNode.pos.y,1),
                                                sm.vec3.new(lastNode.pos.x,lastNode.pos.y,1)}
                                local startLine = {sm.vec3.new(nextStartNode.pos.x,nextStartNode.pos.y,1),
                                                    sm.vec3.new(nextApexNode.pos.x,nextApexNode.pos.y,1)}
                                local intersectionPoint = lineIntersect(endLine,startLine)
                                if intersectionPoint ~= nil then
                                    print(segID,nextSegID,"Got turn intersection point",intersectionPoint)
                                    intersectionPoint.z = nextStartNode.pos.z -- adjust Z back
                                    -- shift first and end points to intersectionpoint 
                                    lastNode.pos = getPosOffset(intersectionPoint, lastNode.outVector * -1, 7)
                                    nextStartNode.pos = getPosOffset(intersectionPoint, nextStartNode.outVector, 7)
                                end
                            end
                        else
                            print('skipsegFind0')
                        end
                    end
                else   -- turns are shallower or straight
                end
            else
                print(" no segment found during intersect") 
                --return false
            end
        end
        print("saving important parts") --Separate into phase 3?
        -- put all "important" nodes into optImportants - Important =  Begining, apex, and end nodes of all turn segments
        for segID=1, self.totalSegments do
            local segment = findSegment(self.nodeChain,self.totalSegments,segID)
            --print("checking se",segID,self.totalSegments)
            if segment ~= nil then                
                local segTurn = getSegTurn(segment[1].segType.TYPE)
                if (segTurn >=1 or segTurn <=-1) then
                    local segBegin = segment[1]
                    local segApex = findSegApex(segment)
                    local segEnd = segment[#segment]
                    
                    if segTurn >=2 or segTurn <= -2 then -- only include begining and end of sharper turns,
                        table.insert(self.optImportants, segBegin)
                        table.insert(self.debugEffects,self:generateEffect(segBegin.pos ,sm.color.new('ffff00ff'))) -- orange at spline pos
                    end
                    if segApex == nil then
                        print("no seg apex?",segID)
                    else
                        table.insert(self.optImportants, segApex)
                        table.insert(self.debugEffects,self:generateEffect(segApex.pos ,sm.color.new('ffff00ff'))) -- orange at spline pos
                    end
                    if segTurn >=2 or segTurn <= -2 then -- only include begining and end of sharper turns,
                        table.insert(self.optImportants, segEnd)
                        table.insert(self.debugEffects,self:generateEffect(segEnd.pos ,sm.color.new('ffff00ff'))) -- orange at spline pos
                    end
                    
                else
                    --print(segment[#segment].id,self.nodeChain[#self.nodeChain].id)
                    if segment[1].id == 1 then 
                        table.insert(self.optImportants, segment[1])
                        table.insert(self.debugEffects,self:generateEffect(segment[1].pos ,sm.color.new('ffff00ff'))) -- orange at spline pos
                    elseif segment[#segment].id == self.nodeChain[#self.nodeChain].id then
                        print('last id insert',segment[#segment].id,self.nodeChain[#self.nodeChain].id)
                        table.insert(self.optImportants, segment[#segment])
                        table.insert(self.debugEffects,self:generateEffect(segment[#segment].pos ,sm.color.new('ffff00ff'))) -- orange at spline pos
                    end
                end
            else
                print(" spline segment find break, skipping") 
            end

        end
        -- end of phase2
        self.phase2Done = true
        self.phase2Running = false
        self.phase3Running = true
        print("Beginning Phase 3")
    elseif self.phase3Running then -- Phase 3, generating new spline for nodechain and initing scan
        -- Format optiImportants into optiSpline
        --print("got optiimporants",#self.optImportants)
        --self:toggleVisual(self.nodeChain)
        local splineArray = {}
        print("Generating spline arr")
        for k = 1, #self.optImportants do local v = self.optImportants[k]
            local x = v.pos.x
            local y = v.pos.y
            table.insert(splineArray, tonumber(x))
		    table.insert(splineArray, tonumber(y))
		end

        print("clearing node chain")
        for k, v in pairs(self.nodeChain) do -- erase current nodeChain
            v.last.next = v.next
            v.next.last = v.last
            self:removeNode(v.id)
        end
		self.nodeChain = {}
        --self:hardUpdateVisual()
        print("Generating new node chain")
        if splineArray then
            for i=1, #splineArray, 2 do
                --print(splineArray[i]..","..splineArray[i+1]) --pre spline
            end
            local spline = Spline()
            local splineRes = spline:getCurvePoints(splineArray,0.25,14)
            for i=1, #splineRes, 2 do
                --print(splineRes[i]..","..splineRes[i+1])
            end
            
            print("creating spline effect",#splineRes)
            for i = 1, #splineRes, 2 do 
                local x = splineRes[i]
                local y = splineRes[i+1]
                local pos = sm.vec3.new(x,y,self.location.z)
                local lastPos = self.nodeSpline[#self.nodeSpline] 
                --print(#self.nodeSpline,pos,lastPos,pos == lastPos)
                if pos == lastPos then -- skip over dupe
                    --print(i/2,"got dupe",pos)
                elseif pos and lastPos and getDistance(pos,lastPos) < 5 then 
                    --print(got things to clos)
                else
                    --table.insert(self.debugEffects,self:generateEffect(pos,sm.color.new('aaff88ff')))
				    table.insert(self.nodeSpline,pos)
                    --table.insert(self.debugEffects,self:generateEffect(pos ,sm.color.new('ffff00ff'))) -- orange at spline pos

                end
            end
        else
            print("no splineArray?",splineArray)
            return true
        end
        print("nodeSPline gen",#self.nodeSpline)
    

		-- Initialize scan for nodeSpline
		self.totalDistance = 0
		local startScanDir = (self.nodeSpline[2] - self.nodeSpline[1]):normalize()
		local startMid, width,leftWall,rightWall,bank = self:getWallMidpoint(self.nodeSpline[1],startScanDir,1)
		local startingNode = self:generateMidNode(self.p4ScanIndex,nil,startMid,startScanDir,0,width,leftWall,rightWall,bank,1) -- first node is sector 1
		startingNode.pos = self.nodeSpline[1] -- manually set point
        startingNode.pos.z = startMid.z -- adjust z value
        --print("put in starting node",startingNode.midPos,startingNode.pos)
        if leftWall == nil or rightWall == nil or startMid == nil then -- TODO: conoslidate this to function
	        print("Error finding wall and mid location")
	        print(leftWall,rightWall,nextMid)
	    else
	        local newEffect = self:generateEffect(startingNode.pos)
	        local leftEffect = self:generateEffect(leftWall + sm.vec3.new(0,0,1),sm.color.new("2244ee")) -- left wall blue
	        local rightEffect = self:generateEffect(rightWall + sm.vec3.new(0,0,1),sm.color.new("22ee44")) -- right wall green
	        startingNode.effect = newEffect -- 
	        startingNode.lEffect = leftEffect --
	        startingNode.rEffect = rightEffect --  
	    end
   		table.insert(self.nodeChain, startingNode)
        self.phase3Done = true
        self.phase3Running = false
        self.phase4Running = true
        print("Starting Phase4 Scan",#self.nodeChain,#self.nodeSpline,self.nodeChain[1].id)
       
    elseif self.phase4Running then 
        --print("Phase4 running",self.p4ScanIndex,#self.nodeChain)
		self.p4ScanIndex = self.p4ScanIndex + 1

        local lastNode = self.nodeChain[self.p4ScanIndex -1]
		local nextLocation = self.nodeSpline[self.p4ScanIndex] -- old way, need to figure out tho
        nextLocation.z = lastNode.pos.z -- pin last location
        local distance = getDistance(lastNode.pos,nextLocation)
        --print(self.p4ScanIndex,distance,nextLocation - self.nodeSpline[self.p4ScanIndex -1])
        local nextVector = (nextLocation - self.nodeSpline[self.p4ScanIndex -1]):normalize() -- should always start at 2
        -- mid prediction version
        --local predictVector = self.nodeSpline[self.p4ScanIndex] - self.nodeSpline[self.p4ScanIndex -1]
        --local predictLoc = lastNode.midPos + predictVector -- Makes next location inference based on vector of others
        --predictLoc.z = lastNode.pos.z
        --predictVector = predictVector:normalize()
    	--local wallmidPoint, width,leftWall,rightWall,bank  = self:getWallMidpoint3(nextLocation,self.scanVector,0) -- new midpoint based off of previous vector looking for perpendicular walls
    	--if self.scanError then return end
    	--local nextVector = getNormalVectorFromPoints(self.scanLocation,wallmidPoint)-- Measure from last node to current midPoint
	    --REdo scan so next vector and scan vector are aligned with midpoint differences and not just scanvector
	    --print(lastNode.id,'scanning',lastNode.midPos,predictLoc,self.p4ScanIndex,predictVector)
        local wallmidPoint2, width,leftWall,rightWall,bank  = self:getWallMidpoint3(nextLocation,nextVector,1) -- TODO: determine if we need to find top
    	--local predictMidPoint, width, leftWall, rightWall, bank  = self:getWallMidpoint3(predictLoc,predictVector,1)
        if self.scanError then print("wmp2 p3 scan fail") return end
	    local nextMid = wallmidPoint2
	    --local nextVector2 = getNormalVectorFromPoints(self.scanLocation,wallmidPoint2)-- Measure from last node to current midPoint can remove nextVector2 if necessary, doubles as inVector
        if wallmidPoint2 == nil then
	        print("Pscan4 nil vector")
	    end
	
	    if lastNode == nil then
	        print("could not find node index")
	        self.scanError = true
	        self.errorReason = "Could not format optimized node chain, (contact seraph)"
	        return true  
	    end
	    self.totalDistance = self.totalDistance + getDistance(lastNode.midPos,nextMid)
	    local newNode = self:generateMidNode(self.p4ScanIndex,lastNode,nextMid,nextVector,self.totalDistance,width,leftWall,rightWall,bank)
        --local newNode = self:generateMidNode(self.p4ScanIndex,lastNode,nextMid,predictVector,self.totalDistance,width,leftWall,rightWall,bank)

        newNode.pos = nextLocation -- adjust race line to spline location 
        newNode.pos.z = nextMid.z -- adjust to accurace z height
        --TODO: actually look down and adjust z based off of raycast to floor
	    if math.abs(nextVector.z) >0.05 then -- was nextVector.z
	        newNode.incline = nextVector.z
	        --newNode.pinned = false -- TODO: Check validity of pinning incline nodes
	    end
	    -- Finish calculations on previous node
	    lastNode.next = newNode
	    lastNode.outVector = getNormalVectorFromPoints(lastNode.pos,newNode.pos)
	    --lastNode.force = vectorAngleDiff(lastNode.inVector,lastNode.outVector) do we need this for optimizations
	    -- Add effects and put into node chain
	    if leftWall == nil or rightWall == nil or nextMid == nil then
	        print("Error finding wall and mid location")
	        print(leftWall,rightWall,nextMid)
	    else
	        local newEffect = self:generateEffect(newNode.pos)
	        local leftEffect = self:generateEffect(leftWall + sm.vec3.new(0,0,1),sm.color.new("2244ee")) -- left wall blue
	        local rightEffect = self:generateEffect(rightWall + sm.vec3.new(0,0,1),sm.color.new("22ee44")) -- right wall green
	        newNode.effect = newEffect -- 
	        newNode.lEffect = leftEffect --
	        newNode.rEffect = rightEffect --  
	    end
	    --table.insert(self.effectChain,self:generateEffect(newNode.pos))
	    --table.insert(self.effectChain,self:generateEffect(leftWall))
	    --table.insert(self.effectChain,self:generateEffect(rightWall))
	    table.insert(self.nodeChain, newNode)
	    --check if at end of node spline
        --print("nc2",self.p4ScanIndex,newNode.id,#self.nodeChain,self.nodeChain[1].id,self.nodeChain[#self.nodeChain].id)

	    if self.p4ScanIndex >= #self.nodeSpline then -- 1is padding just in case?
        	local firstNode = self.nodeChain[1]
        	newNode.next = firstNode -- link back to begining
        	newNode.outVector = getNormalVectorFromPoints(newNode.pos,firstNode.pos)
        	--newNode.force = vectorAngleDiff(newNode.inVector,newNode.outVector)

        	firstNode.last = newNode
        	firstNode.inVector = getNormalVectorFromPoints(newNode.pos,firstNode.pos) -- or lastNode.outVector if too much
            --print()
        	--firstNode.force = vectorAngleDiff(firstNode.inVector,firstNode.outVector)
        	self.phase4Running = false
			self.phase4Done = true
			self.phase5Running = true
	        print("finished scanning")
            print("Reached end of spline",self.p4ScanIndex,newNode.id,#self.nodeChain,self.nodeChain[1].id,self.nodeChain[#self.nodeChain].id)

			return false
    	end

	elseif self.phase5Running then  -- Phase 4: Adjusting nodes away from walls
		--print('phase 5 running')
		local allClear = true
        --print("nc3",v.id,#self.nodeChain)

		-- For every node in nodechain, look both left and right for a wall, if a wall is closer than padding then move pos opposite
		for k=1, #self.nodeChain do v = self.nodeChain[k]
            calculateNewForceAngles(v) -- TODO: CHeck betweenForceAngles and calculateNewForceAngles2
			local perpV = v.perpVector -- assuming left is -1
			local lWallDist = getDistToWall(v,v.pos,perpV,-1)
			if lWallDist  < WALL_PADDING  then  -- shift right
				allClear = false
				v.pos = getPosOffset(v.pos,perpV,0.1)
                --print(k,"shiftRight",v.pos)
			end
			
			local rWallDist = getDistToWall(v,v.pos,perpV,1)
			if rWallDist  < WALL_PADDING  then -- shift left
				allClear = false
				v.pos = getPosOffset(v.pos,perpV *-1,0.1)
                --print(k,"sheiftLeft",v.pos)
			end
		end
        if allClear == true then
            --print("finished wasll shift")
            return true
        end
	end

    self.scanClock = self.scanClock + 1 -- TODO: reset scan clock and timeout for every phase
    if self.scanClock >= 2000 then 
        print('scan timeout')
        return true
    end

end


function Generator.testSmoothing(self) -- Updated smoothing algo
    for k=1, #self.nodeChain do local v=self.nodeChain[k]
        local perpV = v.perpVector
        local vhDifLast = self:getNodeVH(v,v.last,perpV)
        local vhDifNext =  self:getNodeVH(v.next,v,perpV)
        local lastOverlap = false
        local nextOverlap = false

        if vhDifLast.vertical < 0 then -- Overlapped, trim
            lastOverlap = true
        end
        if vhDifNext.vertical < 0 then
            nextOverlap = true
        end
        -- delete self if overlapping nodes and not pinned

       
        calculateNewForceAngles(v)
        local perpV = v.perpVector
        -- Move other lines towards eachother
        -- Get initial angle to next node
        local initialAngle =math.abs(angleDiff(v.inVector,v.outVector))
        
        local moveThreshold = 0.001 -- Threshold before forcing node to move ("close enough" state)
        -- test leftSide
        local testLeftPos = getPosOffset(v.pos,perpV*-1,0.07) -- Dampen it based v.weight
        local testLeftinVector = getNormalVectorFromPoints(v.last.pos,testLeftPos)
        local testLeftoutVector = getNormalVectorFromPoints(testLeftPos,v.next.pos)
        local testLeftAngle = math.abs(angleDiff(testLeftinVector,testLeftoutVector))
        -- Test right side
        local testRightPos = getPosOffset(v.pos,perpV*1,0.07) -- Dampen it based v.weight
        local testRightinVector = getNormalVectorFromPoints(v.last.pos,testRightPos)
        local testRightoutVector = getNormalVectorFromPoints(testRightPos,v.next.pos)
        local testRightAngle = math.abs(angleDiff(testRightinVector,testRightoutVector))

        
        if not v.pinned then -- only if point isn't pinned down
            local difLeft = initialAngle - testLeftAngle -- 5,1 = 4
            local difRight = initialAngle - testRightAngle  -- 5, 0.5 = 4.5
            if difLeft > difRight and difLeft > moveThreshold  then 
                if validChange(v,testLeftPos,perpV,-1) then
                    v.pos = testLeftPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            end
            if difRight > difLeft and difRight > moveThreshold then 
                if validChange(v,testRightPos,perpV,1) then
                    v.pos = testRightPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            end
        end

    end
end

function Generator.iterateCustomSmoothing(self)
    self:customSmoothing(self.customSmoothStart,self.customSmoothEnd)
end


function Generator.customSmoothing(self,startID,endID) -- Updated smoothing algo that only goes between start and end points
    -- TODO: generate an array to handle the potential start/end wrapparound    
    if startID == nil or endID == nil then return end -- possibly have end be the length of nodechain if nil?
    for k=startID, endID do local v=self.nodeChain[k]
        local perpV = v.perpVector
        local vhDifLast = self:getNodeVH(v,v.last,perpV)
        local vhDifNext =  self:getNodeVH(v.next,v,perpV)
        local lastOverlap = false
        local nextOverlap = false

        if vhDifLast.vertical < 0 then -- Overlapped, trim
            lastOverlap = true
        end
        if vhDifNext.vertical < 0 then
            nextOverlap = true
        end



        -- Instead of Instantly removing the node, Move the vector forward or backward depening on whats needed
        -- if last is smaller than next,  move towards next

        if v.id == 7 then
            --print(vhDifLast.vertical,vhDifNext.vertical)
        end

        if not v.pinned then
            if vhDifLast.vertical < vhDifNext.vertical then
                local testForwardPos = getPosOffset(v.pos,v.outVector,0.02/v.weight) -- Dampen it based v.weight
                if validChange(v,testForwardPos,perpV, -1) and validChange(v,testForwardPos,perpV, 1) then
                    v.pos = testForwardPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            elseif vhDifLast.vertical > vhDifNext.vertical then
                local testBackwardPos = getPosOffset(v.pos,v.inVector*-1,0.02/v.weight)
                if validChange(v,testBackwardPos,perpV, -1) and validChange(v,testBackwardPos,perpV, 1) then
                    v.pos = testBackwardPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            else
                print("somehow same dist away")
            end
        end


        --[[if not v.pinned then -- if self is not important
            if nextOverlap then -- if close enough to next node
                if v.next.pinned == false then
                    v.last.next = v.next
                    v.next.last = v.last
                    self:removeNode(v.id)
                    break -- return false
                end
            end
            if lastOverlap then
                if v.last.pinned == false then
                     v.last.next = v.next
                     v.next.last = v.last
                     self:removeNode(v.id)
                     break -- return false
                end
            end  
        end--]]
       
        calculateNewForceAngles(v)
        -- Move other lines towards eachother
        -- Get initial angle to next node
        local initialAngle =math.abs(angleDiff(v.inVector,v.outVector))
        
        local moveThreshold = 0.002 -- Threshold before forcing node to move ("close enough" state)
        -- test leftSide
        local testLeftPos = getPosOffset(v.pos,perpV*-1,0.05/v.weight) -- Dampen it based v.weight
        local testLeftinVector = getNormalVectorFromPoints(v.last.pos,testLeftPos)
        local testLeftoutVector = getNormalVectorFromPoints(testLeftPos,v.next.pos)
        local testLeftAngle = math.abs(angleDiff(testLeftinVector,testLeftoutVector))
        -- Test right side
        local testRightPos = getPosOffset(v.pos,perpV*1,0.05/v.weight) -- Dampen it based v.weight
        local testRightinVector = getNormalVectorFromPoints(v.last.pos,testRightPos)
        local testRightoutVector = getNormalVectorFromPoints(testRightPos,v.next.pos)
        local testRightAngle = math.abs(angleDiff(testRightinVector,testRightoutVector))

        
        if not v.pinned then -- only if point isn't pinned down
            local difLeft = initialAngle - testLeftAngle -- 5,1 = 4
            local difRight = initialAngle - testRightAngle  -- 5, 0.5 = 4.5
            if difLeft > difRight and difLeft > moveThreshold  then 
                if validChange(v,testLeftPos,perpV,-1) then
                    v.pos = testLeftPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            end
            if difRight > difLeft and difRight > moveThreshold then 
                if validChange(v,testRightPos,perpV,1) then
                    v.pos = testRightPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            end
        end

    end
end


function Generator.iterateSmoothing(self) -- {DEPRECIATING} Will try to find fastest average velocity (short path better...)
    for k=1, #self.nodeChain do local v=self.nodeChain[k]
        local perpV = v.perpVector
        local vhDifLast = self:getNodeVH(v,v.last,perpV)
        local vhDifNext =  self:getNodeVH(v.next,v,perpV)
        local lastOverlap = false
        local nextOverlap = false

        if vhDifLast.vertical < 1 then -- Overlapped, trim
            lastOverlap = true
        end
        if vhDifNext.vertical < 1 then
            --nextOverlap = true
        end

        if not v.pinned then -- if self is not important
            if nextOverlap then -- if close enough to next node
                if v.next.pinned == false then
                    v.last.next = v.next
                    v.next.last = v.last
                    self:removeNode(v.id)
                    break -- return false
                end
            end
            if lastOverlap then
                if v.last.pinned == false then
                     v.last.next = v.next
                     v.next.last = v.last
                     self:removeNode(v.id)
                     break -- return false
                end
            end  
        end
       
        calculateNewForceAngles(v)
        local perpV = v.perpVector
        -- Move other lines towards eachother
        -- Get initial angle to next node
        local initialAngle =math.abs(angleDiff(v.inVector,v.outVector))
        
        local moveThreshold = 0.001 -- Threshold before forcing node to move ("close enough" state)
        -- test leftSide
        local testLeftPos = getPosOffset(v.pos,perpV*-1,self.dampening/v.weight) -- Dampen it based v.weight
        local testLeftinVector = getNormalVectorFromPoints(v.last.pos,testLeftPos)
        local testLeftoutVector = getNormalVectorFromPoints(testLeftPos,v.next.pos)
        local testLeftAngle = math.abs(angleDiff(testLeftinVector,testLeftoutVector))
        -- Test right side
        local testRightPos = getPosOffset(v.pos,perpV*1,self.dampening/v.weight) -- Dampen it based v.weight
        local testRightinVector = getNormalVectorFromPoints(v.last.pos,testRightPos)
        local testRightoutVector = getNormalVectorFromPoints(testRightPos,v.next.pos)
        local testRightAngle = math.abs(angleDiff(testRightinVector,testRightoutVector))

        
        if not v.pinned then -- only if point isn't pinned down
            local difLeft = initialAngle - testLeftAngle -- 5,1 = 4
            local difRight = initialAngle - testRightAngle  -- 5, 0.5 = 4.5
            if difLeft > difRight and difLeft > moveThreshold  then 
                if validChange(v,testLeftPos,perpV,-1) then
                    v.pos = testLeftPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            end
            if difRight > difLeft and difRight > moveThreshold then 
                if validChange(v,testRightPos,perpV,1) then
                    v.pos = testRightPos
                    calculateNewForceAngles(v) -- DO this or no?
                end
            end
        end

    end
    
    -- actually propogate
    -- Check force
    local totalForce = calculateTotalForce(self.nodeChain)
    local avgVmax = calculateAvgvMax(self.nodeChain)
    --print("vmaxAvg = ",avgVmax,totalForce)
    --print("ForceAvg = ",totalForce)
    self.scanClock = self.scanClock + 1

    local dif = math.abs(totalForce - self.totalForce)
    local sdif = avgVmax - self.avgSpeed
    --print(string.format("dif = %.3f , %.5f",dif,math.abs(dif - self.lastDif)))
    --self.smoothEqualCount = self.smoothEqualCount + 1
    if math.abs(dif - self.lastDif) < 0.016 then
        --print("smooth",self.dampening)
        self.dampening = self.dampening/ 1.05
        self.smoothEqualCount = self.smoothEqualCount + 0.1
        local progress = (self.smoothEqualCount/self.optimizeStrength) * 100 -- IF global setting dont forget to change here too
        sm.gui.displayAlertText("Optimizing: " .. string.format("%i",progress) .. "%")
    end
    self.lastDif = dif
    self.totalForce = totalForce
    if self.smoothEqualCount >= self.optimizeStrength then -- TODO: have this user defined?
        return true
    end
    --self.smoothEqualCount = self.smoothEqualCount + 0.1 -- Remove, stops cscan
end

function Generator.scanPit(self) -- Scans just like regular but looks for pit lane if user properly bloced off track
end

function Generator.quickSmooth(self,ammount)
    local scanLen = 0
    for i = 0, ammount do -- Have seperate optimize clock?
        local finished = self:testSmoothing()
        if finished then
            self.smoothing = false
            self.scanClock = 0
            print("QuickSMooth did finish",ammount)
            sm.gui.displayAlertText("Optimization Finished prematurely")
            break
        end 
        scanLen = scanLen + 1
    end
end 



function Generator.customQuickSmooth(self,ammount,startID,endID) -- only smooths between the startNode and end node (passed as IDs?)
    local scanLen = 0
    for i = 0, ammount do -- Have seperate optimize clock?
        local finished = self:customSmoothing(startID,endID)
        if finished then
            self.smoothing = false
            self.scanClock = 0
            print("QuickSMooth did finish",ammount)
            sm.gui.displayAlertText("Optimization Finished prematurely")
            break
        end 
        scanLen = scanLen + 1
    end
end 


function Generator.iterateScan(self)

    self.nodeIndex = self.nodeIndex + 1
    --print("node",self.nodeIndex)
    -- TODO: Ensure correctness of scanVector every time (check math of anglediff)
    local nextLocation = getPosOffset(self.scanLocation,self.scanVector,self.scanSpeed)
    --Potential problem. tight corners loses fidelity
    local wallmidPoint, width,leftWall,rightWall,bank  = self:getWallMidpoint2(nextLocation,self.scanVector,0) -- new midpoint based off of previous vector looking for perpendicular walls
    if self.scanError then return end
    local nextVector = getNormalVectorFromPoints(self.scanLocation,wallmidPoint)-- Measure from last node to current midPoint
    --REdo scan so next vector and scan vector are aligned with midpoint differences and not just scanvector
    local wallmidPoint2, width,leftWall,rightWall,bank  = self:getWallMidpoint2(nextLocation,nextVector,1) -- TODO: determine if we need to find top
    if self.scanError then return end
    local nextLocation2 = wallmidPoint2 -- Do another nextVector?
    local nextVector2 = getNormalVectorFromPoints(self.scanLocation,wallmidPoint2)-- Measure from last node to current midPoint can remove nextVector2 if necessary, doubles as inVector

    self.scanLocation = nextLocation2
    self.scanVector = nextVector -- not nextVector2?? TODO: investigate why
    if nextVector == nil then
        print("nil vector")
    end

    -- Gather meta data
    
    local lastNode = self.nodeChain[self.nodeIndex -1]
    if lastNode == nil then
        print("could not find node index")
        self.scanError = true
        self.errorReason = "Could not format node chain, (contact seraph)"
        return true  
    end
    --print(self.nodeIndex,"lastNode",lastNode.id)
    self.totalDistance = self.totalDistance + getDistance(lastNode.pos,nextLocation2)
   
    local newNode = self:generateMidNode(self.nodeIndex,lastNode,nextLocation2,nextVector,self.totalDistance,width,leftWall,rightWall,bank,0)
    --print("Incline vector",nextVector.z)

    if math.abs(nextVector.z) >0.05 then
        newNode.incline = nextVector.z
        newNode.pinned = false -- TODO: Check validity of pinning incline nodes
    end
    -- Finish calculations on previous node
    lastNode.next = newNode
    lastNode.outVector = getNormalVectorFromPoints(lastNode.pos,newNode.pos)
    lastNode.force = vectorAngleDiff(lastNode.inVector,lastNode.outVector)
    if math.abs(lastNode.force) < 0.05 then
        self.scanSpeed = 5 -- 5?
    elseif math.abs(lastNode.force) > 0.2 then
        self.scanSpeed = 3
    elseif math.abs(lastNode.force) > 0.4 then
        self.scanSpeed = 2
    else
        self.scanSpeed = 4
    end
    -- use rolling average force?
    --print("Last Node",lastNode.inVector,lastNode.outVector,lastNode.force)

    -- Add effects and put into node chaing
    if leftWall == nil or rightWall == nil or nextLocation2 == nil then
        print("Error finding wall and mid location")
        print(leftWall,rightWall,nextLocation2)
    else
        local newEffect = self:generateEffect(nextLocation2)
        local leftEffect = self:generateEffect(leftWall + sm.vec3.new(0,0,1),sm.color.new("2244ee")) -- left wall blue
        local rightEffect = self:generateEffect(rightWall + sm.vec3.new(0,0,1),sm.color.new("22ee44")) -- right wall green
        newNode.effect = newEffect -- 
        newNode.lEffect = leftEffect --
        newNode.rEffect = rightEffect --  

    end
    
    
    --table.insert(self.effectChain,self:generateEffect(nextLocation2))

    --table.insert(self.effectChain,self:generateEffect(leftWall))
    --table.insert(self.effectChain,self:generateEffect(rightWall))

    table.insert(self.nodeChain, newNode)
    -- Just for timeout reasons

    self.scanClock = self.scanClock + 1
    --- Check if circut is completed
    local distanceFromStart = getDistance(self.nodeChain[1].pos,newNode.pos)
    --print(distanceFromStart)
    if distanceFromStart < self.scanSpeed + 3 and self.scanClock > 3 then -- 1is padding just in case?
        local firstNode = self.nodeChain[1]
        newNode.next = firstNode -- link back to begining
        newNode.outVector = getNormalVectorFromPoints(newNode.pos,firstNode.pos)
        newNode.force = vectorAngleDiff(newNode.inVector,newNode.outVector)

        firstNode.last = newNode
        firstNode.inVector = getNormalVectorFromPoints(newNode.pos,firstNode.pos) -- or lastNode.outVector if too much
        firstNode.force = vectorAngleDiff(firstNode.inVector,firstNode.outVector)
        self.scanning = false
        local totalForce = calculateTotalForce(self.nodeChain)
        if self.debug then
            --print("finished Scanning, Total Forces = ",totalForce)
        end
        self.totalForce = (totalForce or math.inf) -- Or math.inf
        return true
    end
end

function Generator.calculateApproxSpeeds(self) -- calculates approximate speeds/changes in node segments
    for k=1, #self.nodeChain do local v=self.nodeChain[k]
        --print(self.minSpeed,self.maxSpeed)
        if v.force == nil then
            return
        end
        local force = math.abs(v.force)
        local vMax = force*5 -- Generator.calculate approximate speeds
        
        if self.minSpeed == nil or vMax < self.minSpeed  then
            self.minSpeed = vMax
        end
        if self.maxSpeed == nil or vMax > self.maxSpeed then
            self.maxSpeed = vMax
        end
        v.vMax = vMax
    end
    
end


function Generator.toggleVisual(self)
    print("displaying",self.visualizing)
    if self.visualizing then
        self:stopVisualization()
        self.visualizing = false
    else
        self:showVisualization()
        self.visualizing = true
    end
end


function Generator.eraseCurManPoints(self) -- Erases curPoints
    for k = #self.manPointsFX,1,-1 do local v = self.manPointsFX[k] -- iterate backwards cuz things get skipped
	    if v then
			if v:isPlaying() then
				v:stop() --or just stop anywhere
            end
			v:destroy()
			table.remove(self.manPointsFX,k)
            table.remove(self.manPosArr,k)
		end
	end

    for k = #self.manPosArr,1,-1 do local v = self.manPosArr[k] -- iterate backwards cuz things get skipped
	    if v then
            table.remove(self.manPosArr,k)
		end
	end
	self.manPointsFX = {} 
    self.manPosArr = {}
end

function Generator.drawCurManPoints(self) -- adds fx to fxtable
	for k = 1, #self.manPosArr do local v = self.manPosArr[k]
		local effect = self:generateEffect(v,sm.color.new("FFAFAFFF"))
		table.insert(self.manPointsFX,effect)
		effect:start()
    end

	-- Or use line (Compile this into a function that goes through all the points and generates lines between
	--self.manPointsFX = GenerateVisualPath(self.manPosArr) -- TODO: make all functions in globals capitalize
    -- Still needs fixing
end

function Generator.generateManPosArr(self) -- generates manual pos spline based on CHECK_POINT_CONFIG
	local mPointArr = {} --CHECK_POINT_CONFIG.pos_arr

	table.insert(mPointArr,self.location.x) -- starting node last
    table.insert(mPointArr,self.location.y) -- starting node first
	for k = 1, #CHECK_POINT_CONFIG.pos_arr do local v = CHECK_POINT_CONFIG.pos_arr[k]
        local x = v.x
        local y = v.y
        --print("Inserting",x,y)
        table.insert(mPointArr, tonumber(x))
        table.insert(mPointArr, tonumber(y))
    end
    --print(getDistance(CHECK_POINT_CONFIG.pos_arr[#CHECK_POINT_CONFIG.pos_arr],self.location))
    if getDistance(CHECK_POINT_CONFIG.pos_arr[#CHECK_POINT_CONFIG.pos_arr],self.location) < 50 then -- auto complete when close
        table.insert(mPointArr,self.location.x) -- starting node last
        table.insert(mPointArr,self.location.y)
    end
    --print(mPointArr)
    -- mPointArray is now all important points formatted for spline
    if mPointArr then -- Turn into spline
        local spline = Spline()
        local splineRes = spline:getCurvePoints(mPointArr,CHECK_POINT_CONFIG.tension,CHECK_POINT_CONFIG.nodes)
        local lastZPos = self.location.z
        for i = 1, #splineRes, 2 do 
            local x = splineRes[i]
            local y = splineRes[i+1]
            local newZPos = self.location.z

            local floorHeight,floorData = sm.physics.raycast(sm.vec3.new(x,y,newZPos) + self.shape.up *2.5, sm.vec3.new(x,y,newZPos) + self.shape.up * -60) -- TODO: remove because not important
            if floorHeight then
                newZPos = floorData.pointWorld.z + 0.6
            end
            local pos = sm.vec3.new(x,y,newZPos) -- TODO: replace with "look for floor function"
            lastZPos = newZPos
            local lastPos = self.manPosArr[#self.manPosArr]
            if pos == lastPos then -- skip over dupe
                --print(i/2,"got dupe",pos)
            elseif i >= #splineRes -2 then -- or 1? Skip over last node to prevent nodes too close
                --print("skipping final node") -- If this doesnt work then we can just do it after this loop runs
            elseif lastPos and getDistance(lastPos,pos) < CHECK_POINT_CONFIG.spacing then -- Should work since lastPos is only the ones that are inputted
                --print("Skipping close node")
            else
                table.insert(self.manPosArr,pos)
                --table.insert(self.debugEffects,self:generateEffect(pos ,sm.color.new('ffff00ff'))) -- orange at spline pos
            end
        end
    end
    -- Spline has been generated and trimmed, smooth
end


function Generator.handleManualPoints(self) -- Runs every clientFixedUpdatge
	if CHECK_POINT_CONFIG.hasChange then
		self:eraseCurManPoints()
		self:generateManPosArr()
		self:drawCurManPoints()
		CHECK_POINT_CONFIG.hasChange = false
    else
		self:updateManPoints() -- just do updates as needed
    end
end

function Generator.updateManPoints(self) -- does nothing for now

end

function Generator.confirmManPoints(self) -- actually puts nodes into nodechain
    if #self.nodeChain > 0 then
        print("node chain already populated, clearing")
        for k, v in pairs(self.nodeChain) do -- erase current nodeChain
            v.last.next = v.next
            v.next.last = v.last
            self:removeNode(v.id)
        end
		self.nodeChain = {}
    end
    self.totalDistance = 0
	local startScanDir = (self.manPosArr[2] - self.manPosArr[1]):normalize() -- Might be off, could use self.shape:at()
	local startMid, width,leftWall,rightWall,bank = self:getWallMidpoint(self.manPosArr[1],startScanDir,1)
	local startingNode = self:generateMidNode(1,nil,startMid,startScanDir,0,width,leftWall,rightWall,bank)
	startingNode.pos = self.manPosArr[1] -- manually set point
    startingNode.pos.z = startMid.z -- adjust z value, todo, actally do another findFloorlocation
        --print("put in starting node",startingNode.midPos,startingNode.pos)
    if leftWall == nil or rightWall == nil or startMid == nil then -- TODO: conoslidate this to function
        print("Error finding wall and mid location")
        print(leftWall,rightWall,nextMid)
	else
        local newEffect = self:generateEffect(startingNode.pos)
        local leftEffect = self:generateEffect(leftWall + sm.vec3.new(0,0,1),sm.color.new("2244ee")) -- left wall blue
        local rightEffect = self:generateEffect(rightWall + sm.vec3.new(0,0,1),sm.color.new("22ee44")) -- right wall green
        startingNode.effect = newEffect -- 
        startingNode.lEffect = leftEffect --
        startingNode.rEffect = rightEffect --  
    end
   	table.insert(self.nodeChain, startingNode)
    for i = 2, #self.manPosArr do
        local lastNode = self.nodeChain[i -1]
        local nextLocation = self.manPosArr[i] -- old way, need to figure out tho
        nextLocation.z = lastNode.pos.z -- pin last location TODO: check if this breaks everything
        --local distance = getDistance(lastNode.pos,nextLocation)
        local nextVector = (nextLocation - self.manPosArr[i - 1]):normalize() -- should always start at 2
        local wallmidPoint, width,leftWall,rightWall,bank  = self:getWallMidpoint(nextLocation,nextVector,1) -- TODO: determine if we need to find top
        if self.scanError then print("wmp2 p3 scan fail") return end
        if wallmidPoint == nil then
	        print("Confirm wall scan err")
	    end
	    if lastNode == nil then
	        print("could not find node index")
	        self.scanError = true
	        self.errorReason = "Could not format optimized node chain, (contact seraph)"
	        return true  
	    end
        --print(i,"last node",lastNode.midPos,wallmidPoint)
	    self.totalDistance = self.totalDistance + getDistance(lastNode.midPos,wallmidPoint)
	    local newNode = self:generateMidNode(i,lastNode,wallmidPoint,nextVector,self.totalDistance,width,leftWall,rightWall,bank)
        newNode.pos = nextLocation -- adjust race line to spline location 
        newNode.pos.z = wallmidPoint.z -- adjust to accurace z height
        --TODO: actually look down and adjust z based off of raycast to floor (done in manPosArr)
	    if math.abs(nextVector.z) >0.05 then -- was nextVector.z
	        newNode.incline = nextVector.z
	    end
	    -- Finish calculations on previous node
	    lastNode.next = newNode
	    lastNode.outVector = getNormalVectorFromPoints(lastNode.pos,newNode.pos)
	    --lastNode.force = vectorAngleDiff(lastNode.inVector,lastNode.outVector) do we need this for optimizations
	    -- Add effects and put into node chain
	    if leftWall == nil or rightWall == nil or wallmidPoint == nil then
	        print("Error finding wall and mid location")
	        print(leftWall,rightWall,wallmidPoint)
	    else
	        local newEffect = self:generateEffect(newNode.pos)
	        local leftEffect = self:generateEffect(leftWall + sm.vec3.new(0,0,1),sm.color.new("2244ee")) -- left wall blue
	        local rightEffect = self:generateEffect(rightWall + sm.vec3.new(0,0,1),sm.color.new("22ee44")) -- right wall green
	        newNode.effect = newEffect -- 
	        newNode.lEffect = leftEffect --
	        newNode.rEffect = rightEffect --  
	    end
	    --table.insert(self.effectChain,self:generateEffect(newNode.pos))
	    --table.insert(self.effectChain,self:generateEffect(leftWall))
	    --table.insert(self.effectChain,self:generateEffect(rightWall))
	    table.insert(self.nodeChain, newNode)

	    --check if at end of node spline
        if i >= #self.manPosArr then -- 1is padding just in case?
        	local firstNode = self.nodeChain[1]
        	newNode.next = firstNode -- link back to begining
        	newNode.outVector = getNormalVectorFromPoints(newNode.pos,firstNode.pos)
        	--newNode.force = vectorAngleDiff(newNode.inVector,newNode.outVector)
        	firstNode.last = newNode
        	firstNode.inVector = getNormalVectorFromPoints(newNode.pos,firstNode.pos) -- or lastNode.outVector if too much
        	--firstNode.force = vectorAngleDiff(firstNode.inVector,firstNode.outVector)
            print("Reached end of spline",i,newNode.id,#self.nodeChain,self.nodeChain[1].id,self.nodeChain[#self.nodeChain].id)
            self.finishedManScan = true -- putting here too just in case
			--return true
    	end
    end
    local done = false
    while not done do -- add iff to check if walls needed? or just have set to 0
        local allClear = true
        -- For every node in nodechain, look both left and right for a wall, if a wall is closer than padding then move pos opposite
        for k=1, #self.nodeChain do v = self.nodeChain[k]
            calculateNewForceAngles(v) -- TODO: CHeck betweenForceAngles and calculateNewForceAngles2
            local perpV = v.perpVector -- assuming left is -1
            local lWallDist = getDistToWall(v,v.pos,perpV,-1)
            if lWallDist  < WALL_PADDING  then  -- shift right
                allClear = false
                v.pos = getPosOffset(v.pos,perpV,0.1)
                --print(k,"shiftRight",v.pos)
            end
            
            local rWallDist = getDistToWall(v,v.pos,perpV,1)
            if rWallDist  < WALL_PADDING  then -- shift left
                allClear = false
                v.pos = getPosOffset(v.pos,perpV *-1,0.1)
                --print(k,"sheiftLeft",v.pos)
            end
        end
        if allClear == true then
            print("finished wasll shift, done")
            done = true
            self.finishedManScan = true -- do this within so it gets mutated no matter when called
            return true
        end
    end
end

function Generator.checkForEditNode(self) -- checks fo character blocking and muteates edit node and such
    -- Check for editing trigger
    local item = sm.localPlayer.getActiveItem() -- not really necessary
    local char = sm.localPlayer.getPlayer().character
    --print(char:getActiveAnimations())

    if item == sm.uuid.new("ed185725-ea12-43fc-9cd7-4295d0dbf88b") then -- holding sledgehammer
        if findKeyValue(char:getActiveAnimations(),'name','sledgehammer_guard_into') then
            self.shortStarted = true
        end

        if findKeyValue(char:getActiveAnimations(),'name','sledgehammer_guard_idle') then
            self.shortStarted = false
            if self.editingNode == false and self.nodeHovered ~= nil and not self.customSmoothLive then
                print("starting edit node")
                self.editingNode = true
            elseif self.nodeHovered == nil and self.customSmoothLive == false then -- iterate smoothing
                self.customSmoothLive = true
            end
        else -- no longer blocking
            if self.editingNode == true then
                --print("Stopping edit node edit node")
                self.editingNode = false
                --print("quickSmooth",self.customSmoothStart,self.customSmoothEnd)
                --self:customQuickSmooth(25,self.customSmoothStart,self.customSmoothEnd)
            elseif self.customSmoothLive then
                self.customSmoothLive = false -- stop iteration
            end
        end
    
        if findKeyValue(char:getActiveAnimations(),'name','sledgehammer_guard_exit') then
            if self.shortStarted == true then

                --print("got short press right click")
                self.shortClick = true
            end
        else
            if self.shortClick == true then
                self.shortStarted = false
                self.shortClick = false
                self:handleShortClick() 
            end
        end

    else

    end
end

function Generator.handleShortClick(self)
    if self.nodeHovered then 
        if self.customSelect == 0 then -- Set starting node id
            print("set Smooth Start",self.nodeHovered)
            self.customSmoothStart = self.nodeHovered
            self.nodeChain[self.nodeHovered].pinned = false -- unpin things
            sm.gui.displayAlertText("Smoothing Start: " .. tostring(self.customSmoothStart))
        elseif self.customSelect == 1 then 
            print("Set smooth end",self.nodeHovered)
            self.customSmoothEnd = self.nodeHovered
            self.nodeChain[self.nodeHovered].pinned = false -- unpin node
            sm.gui.displayAlertText("Smoothing End: " .. tostring(self.customSmoothEnd))
        end
    elseif self.pitNodeHovered then -- cycle pitNode pointType
            local newPointType = math.fmod(self.pitChain[self.pitNodeHovered].pointType+1,5)
            print("Toggling Point Type",self.pitNodeHovered,self.pitChain[self.pitNodeHovered].pointType, " to ",newPointType)
            self.pitChain[self.pitNodeHovered].pointType = newPointType
            self.pitChain[self.pitNodeHovered].typeChange = true
            sm.gui.displayAlertText("Toggling to point type " .. tostring(PIT_POINT_TYPES[newPointType + 1].NAME))
    else
        print("not hovering over node")

    end

    if self.customSelect == 1 then self.customSelect = 0 -- Toggles customSmooth start vs custom smoth end
    elseif self.customSelect == 0 then self.customSelect = 1 end
end



function Generator.handleHovering(self) -- for editing nodes specifically
    if not self.editingNode and self.scanning == false and self.smoothing == false then -- check for hover when not editing, otherwise we just edit
        local nodeData = cl_checkHoverAT() -- Just checks for general area trigger hovers
        if nodeData then -- hovering anode
            local ntype = nodeData.node_type
            if ntype == 0 then -- race
                self.pitNodeHovered = nil
                if self.nodeHovered ~= nodeData.node_id then
                    --print("Hovering Node",nodeData.node_id) -- Do a check if exists?
                    self.nodeHovered = nodeData.node_id
                end
            elseif ntype == 1 then -- pit
                self.nodeHovered = nil
                if self.pitNodeHovered ~= nodeData.node_id then
                    --print("Hovering Node",nodeData.node_id) -- Do a check if exists?
                    self.pitNodeHovered = nodeData.node_id
                end
            end
        else -- remove the hover
            self.nodeHovered = nil
            self.pitNodeHovered = nil
        end
    end

    if self.editingNode and self.nodeHovered ~= nil then -- move the node to the left/right perpVector
        local node = self.nodeChain[self.nodeHovered]
        local originPos = node.pos
        local hit, result = sm.localPlayer.getRaycast(100)
        if hit then 
            local pos = result.pointWorld
            node.pos = pos
            if node.pinned == false then
                node.pinned = true
            end
            --print('moving node',originPos,pos)
        end

    end


    if self.editingPitNode and self.pitNodeHovered ~= nil then -- move the node to the left/right perpVector
        local node = self.pitChain[self.pitNodeHovered]
        local originPos = node.pos
        local hit, result = sm.localPlayer.getRaycast(100)
        if hit then 
            local pos = result.pointWorld
            node.pos = pos -- location? mid?
            if node.pinned == false then
                node.pinned = true
            end
            --print('moving node',originPos,pos)
        end

    end
end

-- Other functs
function Generator.client_onFixedUpdate( self, timeStep ) 
    self.location = sm.shape.getWorldPosition(self.shape)
    self.onHover = cl_checkHover(self.shape)
    
    self:checkForEditNode()

    self:handleHovering()


    -- Check for manual points first, ignore scan
    if #CHECK_POINT_CONFIG.shape_arr > 0  then
        self.manualPoints = true 
    else
        if self.manualPoints then
            self.manualPoints = false
            self:eraseCurManPoints()
        end
    end

    if self.manualPoints then
        self:handleManualPoints()
    else
        
    end

    if #PIT_CHAIN_CONFIG.shape_arr > 0  then
        self.pitPoints = true 
    else
        if self.pitPoints then
            self.pitPoints = false
            self:eraseCurPitPoints()
        end
    end

    if self.pitPoints then
        self:handlePitPoints()
    else
        
    end


    self:tickClock()
    --print(self.scanError)
    if self.scanError then
        self.scanning = false
        self.smoothing = false
        if not self.errorDisplayed then
            sm.gui.displayAlertText("Scan Failed: " .. (self.errorReason or ""),10)
            self.errorDisplayed = true
            self.errorNode = self:generateEffect(self.errorLocation,sm.color.new("EE2222FF"))
            self.errorNode:start()
            return
        end
    end

    
    -- custom smoothign
    if self.customSmoothLive then 
        local finished = self:asyncSleep(self.iterateCustomSmoothing,self.asyncTimeout2)
    end


    if self.scanning and not self.instantScan then -- Debug scan
        local finished = self:asyncSleep(self.iterateScan,self.asyncTimeout)
        if finished then
            self.scanning = false
            self.scanClock = 0
            print("finished Track Scan, Generating segments")
            self:quickSmooth(self.smoothAmmount)
            self:generateSegments() --original
            --print("Finished Segment Gen, Optimizing Race line")
            if self.racifyLineOpt then
                self:racifyLine()
            end
            self:startOptimization()
            
            --self:hardUpdateVisual()
            return
        end
        if self.scanClock >= self.scanLength then
            self.scanning = false
            self.scanClock = 0
            sm.gui.displayAlertText("Scan Failed: Timeout")
        end
    end
    if self.smoothing and not self.instantOptimize then  
        local finished = self:asyncSleep(self.iterateSmoothing,self.asyncTimeout2)
        if finished then
            self.isOptimizing = false
            print("Generating segmens after optimization")
            self:generateSegments()-- testing location
            --self:printNodeChain()
            self.smoothing = false
            self.scanClock = 0
            sm.gui.displayAlertText("Optimization Finished")
            if self.saveTrack then
                self:saveRacingLine()
            end
            self:hardUpdateVisual()
            return
        end
        if self.scanClock >= self.scanLength  or self.smoothEqualCount > 3 then
            --print("Generating segmenst smoothcount")
            self:generateSegments()-- testing location
            --self:printNodeChain()
            self.smoothing = false
            self.scanClock = 0
            print("Optimization actually finished")
            sm.gui.displayAlertText("optimization Fin")
            if self.saveTrack then
                self:saveRacingLine()
            end
            self:hardUpdateVisual()
        end
    end
    --self.location = sm.shape.getWorldPosition(self.shape)
    --self:calculateApproxSpeeds()
    self:updateVisualization()
end

function Generator.tickClock(self)
    local floorCheck = math.floor(clock() - self.started)
        --print(floorCheck,self.globalTimer)
    if self.globalTimer ~= floorCheck then
        self.gotTick = true
        self.globalTimer = floorCheck
        if self.scanning then
            --self:hardUpdateVisual() 
        end
    else
        self.gotTick = false
        self.globalTimer = floorCheck
    end

    if self.showVisuals == true then 
        if not self.visualizing then
            --print("toggle visual")
            self:toggleVisual()
        end
    end
    if self.debug then
        if not self.visualizing then
            --print("toggle visual")
            self:toggleVisual()
        end
        if self.scanning == false and #self.nodeChain <=1 and self.isOptimizing == false and self.manualPoints == false then
            print('start debug scan')
            self:startTrackScan()
        end


        if self.pitPoints == true and self.finishedPitScan == false then
            self:eraseCurPitPoints()
            self:generatePitPosArr()
            --self:drawCurManPoints()
            local result = self:confirmPitPoints()
            if result then 
                --self:quickSmooth(10) -- is this even needed?
                self:showVisualization()
                print("Finished Pit road scan")
                sm.gui.displayAlertText("pit road scanned") -- needs to be xchat message
            end
            return
        end

        if self.manualPoints == true and self.debugMan and  self.finishedManScan == false then
            self:eraseCurManPoints()
            self:generateManPosArr()
            --self:drawCurManPoints()
            local result = self:confirmManPoints()
            if result then 
                --self:quickSmooth(10) -- is this even needed?
                self:showVisualization()
                self:generateSegmentsMan()
                print("Finished Segment Gen, Optimizing Race line")
                sm.gui.displayAlertText("Manual Race Line Generation Finished")
                if self.saveTrack then
                    self:saveRacingLine()
                end
            end
            return
        end 
    end
            
end

function Generator.startTrackScan(self)
    self.customSmoothStart = nil
    self.customSmoothEnd = nil

    self.scanError = false -- reset error
    self.nodeChain = {} -- reset chain
    self.scanClock = 0 -- reset scanclock
    self.started = clock()
    self.nodeIndex = 1
    sm.gui.displayAlertText("Scanning")
    local startPoint, width,leftWall,rightWall,bank = self:getWallMidpoint(self.location,self.trackStartDirection,1)
    self.scanLocation = startPoint
    self.scanVector = sm.vec3.normalize(self.trackStartDirection)
    print("Starting SCAN",#self.nodeChain,self.nodeIndex,width)
   
    local startingNode = self:generateMidNode(self.nodeIndex,nil,startPoint,self.trackStartDirection,self.totalDistance,width,leftWall,rightWall,bank)
    
    if leftWall == nil or rightWall == nil or startPoint == nil then -- TODO: Turn this into a function
        print("Error finding wall and mid location")
        print(leftWall,rightWall,startPoint)
    else
        local newEffect = self:generateEffect(startPoint)
        local leftEffect = self:generateEffect(leftWall + sm.vec3.new(0,0,1),sm.color.new("2244ee")) -- left wall blue
        local rightEffect = self:generateEffect(rightWall + sm.vec3.new(0,0,1),sm.color.new("22ee44")) -- right wall green
        startingNode.effect = newEffect -- 
        startingNode.lEffect = leftEffect --
        startingNode.rEffect = rightEffect --  
    end
    table.insert(self.nodeChain, startingNode)

    if self.instantScan then -- instant game freezing scan
        while self.scanClock < self.scanLength do
            if self.scanError then
                print("Scan error",self.debug)
                if not self.debug then
                    sm.gui.displayAlertText("Scan Failed: " .. (self.errorReason or "") .. " \n(Crouch interact to toggle debug)",10)
                else
                    sm.gui.displayAlertText("Scan Failed: " .. (self.errorReason or ""),10)
                end
                break
            end
            local finished = self:iterateScan()
            
            if finished then
                self.scanning = false
                self.scanClock = 0
                print("finished Track Scan, Generating segments")
                -- quick smoothing
                self:quickSmooth(self.smoothAmmount)
                self:generateSegments()
                -- if self.optimize then
                print("Finished Segment Gen, Optimizing Race line")
                if self.racifyLineOpt then
                    self:racifyLine()
                end
                self:startOptimization()
                self:hardUpdateVisual()
                break
            end
        end
        if self.scanClock >= self.scanLength then
            self.scanning = false
            self.scanClock = 0
            sm.gui.displayAlertText("Scan Failed: Scan timed out")
            return
        end
    else -- Slower visual scan
        self.scanning = true
    end
end

function Generator.startOptimization(self)
    sm.gui.displayAlertText("Optimizing")
    if self.instantOptimize then -- Game freezing optimization loop
        while self.scanClock < self.scanLength do -- Have seperate optimize clock?
            local finished = self:iterateSmoothing() -- giving up on new rl gen for now
            if finished then
                self.isOptimizing = false
                self:generateSegments()
                self.smoothing = false
                self.scanClock = 0
                print("finished Optimizing Track, saving")
                sm.gui.displayAlertText("Optimization Finished")
                if self.saveTrack then
                    self:saveRacingLine()
                end
                break
            end 
        end 
        if self.scanClock >= self.scanLength then
            --self:generateSegments() -- moved segment generation to after optimization, makes more sense
            self.smoothing = false
            self.scanClock = 0
            sm.gui.displayAlertText("Track too long to optimize")
            return
        end
    else -- Slower visual optimization
        self.smoothing = true
    end
end
 
function Generator.sv_toggleRacify(self,toggle) -- Turns off and on racify line
    self.racifyLineOpt = not self.racifyLineOpt
    print("Toggling racify",self.racifyLineOptw)

    if self.racifyLineOpt then 
        sm.gui.chatMessage("Race Line Enhancement Turned #22ee22ON #ffffff(Good for Road Courses)")
    else
        sm.gui.chatMessage("Race Line Enhancement Turned #ee2222OFF #ffffff(Good for Ovals)")
    end
end

function Generator.printNodeChain(self)
    for k, v in pairs(self.nodeChain) do
		print(v.id,v.segID)
    end
end

function Generator.client_canInteract(self)
    local item = sm.localPlayer.getActiveItem()
    local char = sm.localPlayer.getPlayer().character
    sm.gui.setCenterIcon( "Hit" )
    if item == sm.uuid.new("ed185725-ea12-43fc-9cd7-4295d0dbf88b") then -- holding sledgehammer
        sm.gui.setInteractionText( "",self.leftClickText,"Save Racing Line")
    else
        if sm.localPlayer.getPlayer().character:isCrouching() then
            sm.gui.setInteractionText( self.useText,"Debug Mode", self.tinkerText,"Decrease Sensitivity","")
        else
            -- TODO: change to confirm man text if man nodes == true
            sm.gui.setInteractionText( self.useText,"Start Scan", self.tinkerText,"Increase Sensitivity","")
        end
    end
    return true
end

function Generator.client_onInteract(self,character,state)
    if state then
        if self.pitPoints == true then
            --self.finishedPitScan = false
            --self:eraseCurPitPoints() -- is this necessary??
            --self:generatePitPosArr()
            --local result = self:confirmPitPoints()
            -- Pit Points should already be ready to go
            if result then
                print('pit lane scan confirmed')
            end
        end
        if self.manualPoints == true  then
            self.finishedManScan = false
            self:eraseCurManPoints()
            self:generateManPosArr()
            --self:drawCurManPoints()
            
            local result = self:confirmManPoints()
            if result then 
                --self:quickSmooth(10) -- is this even needed?
                self:showVisualization()
                self:generateSegmentsMan()
                print("Finished Segment Gen, Optimizing Race line")
                sm.gui.displayAlertText("Manual Race Line Generation Finished")
                if self.saveTrack then
                    self:saveRacingLine()
                end
            end
            return
        end 
        if character:isAiming() then -- if char is aiming then downforce detect
            self.network:sendToServer('sv_toggleRacify',state)
            -- TODO: change tooltip text
        elseif character:isCrouching() then
            self.debug = not self.debug -- togle debug
            self:toggleVisual()
            self.instantScan = false
		elseif not self.scanning then
            self.nodeChain = {}
            self.effectChain = {}
            self:startTrackScan()
            sm.gui.chatMessage("If scan does not work properly (bad shape or error): Press (upgrade) on the track scanner block to decrease wall detection sensitivity. Crouch (upgrade) to increase. then try to scan again. (may need to move scanner block)")
            sm.gui.chatMessage("NOTE: Lower sens value = higher sensitivity (better for very flat tracks with sharp/low walls) \n Higher sens value = lower sensitivity (useful for tracks with high walls and/or bumpy roads like offroad sections or banked turns)")
		else
			print("Scan already started")
		end
    end
end

function Generator.client_onUpdate(self,timeStep)
    local item = sm.localPlayer.getActiveItem()
    local char = sm.localPlayer.getPlayer().character
    --[[if self.onHover then 
        sm.gui.setCenterIcon( "" )
        if item == sm.uuid.new("ed185725-ea12-43fc-9cd7-4295d0dbf88b") then -- holding sledgehammer
            sm.gui.setCenterIcon( "Hit" )
            sm.gui.setInteractionText( "",self.leftClickText,"Save Racing Line")
        else
            sm.gui.setCenterIcon( "Hit" )
            if sm.localPlayer.getPlayer().character:isCrouching() then
                sm.gui.setInteractionText( self.useText,"Debug Mode", self.tinkerText,"Decrease Sensitivity","")
            else
                -- TODO: change to confirm man text if man nodes == true
                sm.gui.setInteractionText( self.useText,"Start Scan", self.tinkerText,"Increase Sensitivity","")
            end
        end]]
    if item == sm.uuid.new("ed185725-ea12-43fc-9cd7-4295d0dbf88b") and not self.hover then -- holding sledgehammer while not looking at the block
        if self.nodeHovered == nil then 
            sm.gui.setCenterIcon( "Hit" )
            sm.gui.setInteractionText("",self.rightClickText ,"(Hold) Edit Node Position")
        else
            if self.editingNode == false then
                sm.gui.setInteractionText("",self.rightClickText ,"Edit Node " ..tostring(self.nodeHovered) .. " Position")
            else
                sm.gui.setInteractionText("" ,"", "Editing Node " ..tostring(self.nodeHovered))
            end
        end
    else

    end

end

function Generator.client_canTinker( self, character )
	--local useText =  sm.gui.getKeyBinding( "Use", true )
    --local tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    --sm.gui.setInteractionText("Save",sm.gui.getKeyBinding("Use"), "Load", sm.gui.getKeyBinding('Tinker'))
    --sm.gui.setInteractionText( useText,"Start Scan", tinkerText,"Set Sensitivity","")
    
    return true
end

function Generator.client_onTinker( self, character, state )
    --print('onTinker')

	if state then
        if character:isCrouching() then
            self.network:sendToServer('cl_changeWallSense',-1)
        else
            self.network:sendToServer('cl_changeWallSense',1)
        end
	end
end



function Generator.client_onMelee(self,data) -- Functionality when hit by hammer, Saves track again 
	--print("cl melehit",data)
    if self.finishedManScan then
        self:generateSegments() -- uses normal way for now
        self:saveRacingLine()-- client??
    end

    if self.finishedPitScan then
        print("already finished scan")
        self:savePitLine()
    else
        print("need to confirm")
        --self:eraseCurPitPoints() -- is this necessary??
        self:generatePitPosArr()
        local result = self:confirmPitPoints()
        self:savePitLine()

    end
end

function Generator.server_onMelee(self,data) -- Functionality when hit by hammer, Saves track again 
	--print("sv rl mele")
    --self.network.sendToClients("cl_onMele",data)
end












--- PIT CHAIN HANDLER--------------
--- 

function Generator.eraseCurPitPoints(self) -- Erases curPoints fx
    for k = #self.pitPointsFX,1,-1 do local v = self.pitPointsFX[k] -- iterate backwards cuz things get skipped
	    if v then
			if v:isPlaying() then
				v:stop() --or just stop anywhere
            end
			v:destroy()
			table.remove(self.pitPointsFX,k)
		end
	end

    for k = #self.pitPosArr,1,-1 do local v = self.pitPosArr[k] -- iterate backwards cuz things get skipped
	    if v then
			table.remove(self.pitPosArr,k)
		end
	end

	self.pitPointsFX = {} -- delete other set point
    self.pitPosArr = {} -- resets this too
end

function Generator.drawCurPitPoints(self) -- adds fx to fxtable
    print("draw cur pitPoint")
	for k = 1, #self.pitPosArr do local v = self.pitPosArr[k]
		local effect = self:generateEffect(v,sm.color.new("5599AFFF"))
		table.insert(self.pitPointsFX,effect)
		effect:start()
    end
end

function Generator.generatePitPosArr(self) -- generates manual pos spline based on CHECK_POINT_CONFIG
	local mPointArr = {} --PIT_CHAIN_CONFIG.pos_arr
    -- Find the bright green node first??
	for k = 1, #PIT_CHAIN_CONFIG.pos_arr do local v = PIT_CHAIN_CONFIG.pos_arr[k]
        local x = v.x
        local y = v.y
        --print("Inserting",x,y)
        table.insert(mPointArr, tonumber(x))
        table.insert(mPointArr, tonumber(y))
    end
    --print(getDistance(CHECK_POINT_CONFIG.pos_arr[#CHECK_POINT_CONFIG.pos_arr],self.location))
    --if getDistance(PIT_CHAIN_CONFIG.pos_arr[#PIT_CHAIN_CONFIG.pos_arr],self.location) < 50 then -- auto complete when close
    --    table.insert(mPointArr,self.location.x) -- starting node last
    --    table.insert(mPointArr,self.location.y)
    --end
    --print(mPointArr)
    -- mPointArray is now all important points formatted for spline
    if mPointArr then -- Turn into spline
        local spline = Spline()
        local splineRes = spline:getCurvePoints(mPointArr,PIT_CHAIN_CONFIG.tension,PIT_CHAIN_CONFIG.nodes)
        local lastZPos = self.location.z
        for i = 1, #splineRes, 2 do 
            local x = splineRes[i]
            local y = splineRes[i+1]
            local newZPos = self.location.z

            local floorHeight,floorData = sm.physics.raycast(sm.vec3.new(x,y,newZPos) + self.shape.up *2.5, sm.vec3.new(x,y,newZPos) + self.shape.up * -60) -- TODO: remove because not important
            if floorHeight then
                newZPos = floorData.pointWorld.z + 0.6
            end
            local pos = sm.vec3.new(x,y,newZPos) -- TODO: replace with "look for floor function"
            lastZPos = newZPos
            local lastPos = self.pitPosArr[#self.pitPosArr]
            if pos == lastPos then -- skip over dupe
                --print(i/2,"got dupe",pos)
            elseif i >= #splineRes -2 then -- or 1? Skip over last node to prevent nodes too close
                --print("skipping final node") -- If this doesnt work then we can just do it after this loop runs
            elseif lastPos and getDistance(lastPos,pos) < PIT_CHAIN_CONFIG.spacing then -- Should work since lastPos is only the ones that are inputted
                --print("Skipping close node")
            else
                table.insert(self.pitPosArr,pos)
                --table.insert(self.debugEffects,self:generateEffect(pos ,sm.color.new('ffff00ff'))) -- orange at spline pos
            end
        end
    end
    -- Spline has been generated and trimmed, smooth
end

function Generator.generatePitNode(self,index,previousNode,location,inVector,distance,width) -- point types will be cycleable
    if inVector == nil then
        print("node gen no inVector")
    end
    return {id = index, pos = location, outVector = nil, last = previousNode, inVector = inVector, force = nil, distance = distance, 
            perpVector = generatePerpVector(inVector), midPos = location, width = width, next = nil, effect = nil, 
            pinned = false, weight = 1, incline = 0, apex = 0, areaTrigger = nil, hovered = false, pointType = 0, typeChange = false,
            sectorID = 3} -- move effect?
end

function Generator.handlePitPoints(self) -- Runs every clientFixedUpdatge
	if PIT_CHAIN_CONFIG.hasChange then
		self:eraseCurPitPoints()
		self:generatePitPosArr()
		--self:drawCurPitPoints()
        self:confirmPitPoints() -- creates actual pitChain which shouldnt be too laggy
		PIT_CHAIN_CONFIG.hasChange = false
    else
		self:updatePitPoints() -- just do updates as needed
    end
end

function Generator.updatePitPoints(self) -- does nothing for now

end

function Generator.confirmPitPoints(self) -- actually puts nodes into pit chain
    print("confirming pit points")
    if #PIT_CHAIN_CONFIG.shape_arr <= 1 then return end -- only do this if theres shapes to be made
    if #self.pitPosArr <= 1 then return end
    if #self.pitChain > 0 then
        print("Pit chain already populated, clearing")
        for k, v in pairs(self.pitChain) do -- erase current pit chain
            if v.last ~= nil then
                v.last.next = v.next
            end
            if v.next ~= nil then
                v.next.last = v.last
            end
            self:removePitNode(v.id)
        end
		self.pitChain = {}
    end
    print("past validate")
    self.pitDistance = 0 -- not necesarily neceessary 
    local pitPoint = PIT_CHAIN_CONFIG.shape_arr[1]
	local startScanDir = (self.pitPosArr[2] - self.pitPosArr[1]):normalize() -- Might be off, could use self.shape:at()
	local startingNode = self:generatePitNode(1,nil, self.pitPosArr[1],startScanDir,0,10) -- Generate pitNode
	startingNode.pos = self.pitPosArr[1] -- manually set point
    --print("put in starting node",startingNode.midPos,startingNode.pos)
    local newEffect = self:generateEffect(startingNode.pos)
    startingNode.effect = newEffect -- 
   	table.insert(self.pitChain, startingNode)
    for i = 2, #self.pitPosArr do
        local lastNode = self.pitChain[i -1]
        local nextLocation = self.pitPosArr[i] -- old way, need to figure out tho
        --nextLocation.z = lastNode.pos.z -- pin last location TODO: check if this breaks everything
        --local distance = getDistance(lastNode.pos,nextLocation)
        local nextVector = (nextLocation - self.pitPosArr[i - 1]):normalize() -- should always start at 2
        if self.scanError then print("wmp2 p3 scan fail") return end
        
	    if lastNode == nil then
	        print("could not find node index")
	        self.scanError = true
	        self.errorReason = "Could not format optimized pit chain, (contact seraph)"
	        return true  
	    end

        --print(i,"last node",lastNode.midPos,wallmidPoint)
	    self.pitDistance = self.pitDistance + getDistance(lastNode.midPos,nextLocation) -- Create pitdistance as 0
	    local newNode = self:generatePitNode(i,lastNode,nextLocation,nextVector,self.pitDistance,10) -- generatePitNode
        newNode.pos = nextLocation -- adjust race line to spline location 
    
	    -- Finish calculations on previous node
	    lastNode.next = newNode
	    lastNode.outVector = getNormalVectorFromPoints(lastNode.pos,newNode.pos)
	    --lastNode.force = vectorAngleDiff(lastNode.inVector,lastNode.outVector) do we need this for optimizations
	    -- Add effects and put into node chain
	    local newEffect = self:generateEffect(newNode.pos)
	    newNode.effect = newEffect -- 
	    table.insert(self.pitChain, newNode)
	    --check if at end of node spline
        if i >= #self.pitPosArr then -- 1is padding just in case?
            --print("Reached end of pit spline",i,newNode.id,#self.pitChain)
            self.finishedPitScan = true -- putting here too just in case
    	end
    end
    local done = false
    -- Dont Racify or optimize/ check walls? TODO: replicate timeout function to top
    -- removed wall adjustments
    
    self.finishedPitScan = true -- do this within so it gets mutated no matter when called
    return true
end


