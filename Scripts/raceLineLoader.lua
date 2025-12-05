dofile "Timer.lua" 
dofile "globals.lua"

-- Copyright (c) 2020 SaltySeraph --
--raceLineLoaderr.lua 
--[[
	- Allows users to press 'e' to export/save any generated racing lines
    - Allows users to press 'g' to load any saved racing lines
]]

Loader = class( nil )
Loader.maxChildCount = -1
Loader.maxParentCount = -1
Loader.connectionInput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Loader.connectionOutput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
Loader.colorNormal = sm.color.new( 0xffc0cbff )
Loader.colorHighlight = sm.color.new( 0xffb6c1ff )
local clock = os.clock --global clock to benchmark various functional speeds ( for fun)



-- Local helper functions utilities
function round( value )
	return math.floor( value + 0.5 )
end

function Loader.client_onCreate( self ) 
	self:client_init()
	print("Created Track Loader")
end

function Loader.client_onDestroy(self)
    --print("Loader destroyed")
    if self.effect:isPlaying() then
        self.effect:stop()
    end
    self:stopVisualization()
end

function Loader.client_init( self )  -- Only do if server side???
    --self.trackData = nil -- Will be loaded and set on network

    self.effectChain = {}
    self.debugEffects = {}
    self.effect = sm.effect.createEffect("Loot - GlowItem")
    self.effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    self.effect:setPosition(self.location)
    self.visualizing = false
    self.showSpeeds = false
    self.showSegments = true
    
    self.debug =true  -- TODO: remove, should always be true
   


     -- GUI stuff?
    self.trackName = "unnamed track" -- TODO
    self.trackuid = 1234 -- TODO
    -- error states
    self.scanError = false
    self.errorLocation = nil

    self.showWalls = false -- show wall effects (reduces total allowed effects)
    self.useText =  sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    self.onHover = false
	print("Track Loader V2.0 Client Initialized")
end


function Loader.client_onRefresh( self )
	self:client_onDestroy()
	self:client_init()
end

function Loader.server_onDestroy(self)

end

function Loader.server_onRefresh(self)
    self:server_onDestroy()
    self:server_init()
end


function Loader.server_onCreate(self)
    self:server_init()
end

function Loader.server_init(self)
    self.trackName = "Unnamed"
    self.trackID = 123 -- TODO: generate UUID
    self.location = sm.shape.getWorldPosition(self.shape)
    self.direction = self.shape:getAt()
    
    -- Saved Track data loading
    local storedTrack = self.storage:load()  -- Loads any existing data when placed:
                                            -- N: "Track Name"
                                            -- I: "uuid"
                                            -- C: [Simplified Node chain]
                                            -- O: Origin position: (position of this block when placed and saved)
                                            -- D: Origin Direction: (Direction of this block when placed and saved)
    if storedTrack == nil then -- IDK just do nothing for now
        print("No previous track data found")
    else -- Just automaticallly import and show what is saved
        print("Loaded track",storedTrack.N)
        self.trackData = storedTrack
        -- Do not set self nodechain until U and then save it
        -- Reads in track, calculates offset and places nodes in offset position
        -- Saves track to world
        self:sv_loadTrack() -- for initial placement
        --print("finished load")
        -- creates visuals for clientside
    end
end

function Loader.cl_receiveTrackData(self,data)
    -- Instead of refreshing everything, we will update the nodes
    if self.effectChain ~= nil and #self.effectChain >1 then -- if exists and has length
        for k=1, #data.nodeChain do local v=data.nodeChain[k] -- Add effect to nodeChain
            if self.effectChain[k] ~=nil then -- if "matching" point
                self.effectChain[k].location = v.location
            else
                --print("found effect?",self.effectChain[k])
            end
        end
    else
        --print("new effect chain")
        self.effectChain = data.nodeChain
    end

    self:cl_loadTrack()
end


function Loader.cl_loadTrack(self) -- validates and loads visualization of track
    if self.effectChain == nil or #self.effectChain <=1 then
        print("cl load track: Data is Nil",self.effectChain)
        return
    end
    
    for k=1, #self.effectChain do local v=self.effectChain[k] -- Add effect to nodeChain
        if v.effect == nil then
            v.effect = self:generateEffect(v.location)
        else
            -- set location?
        end
    end
    self:hardUpdateVisual()
end


function Loader.sv_loadTrack(self) -- Validates and saves track to world 
    if self.trackData == nil then
        print("sv load track: Data is Nil")
        return
    end
    -- Do not set nodechain until after official track layout is chosen
    local tempChain = {} -- create new table
    local tempChain = shallowcopy(self.trackData.C)
    --print("tc:",self.trackData.C[1].location,tempChain[1].location)

    -- Calculate offset and mutates nodechaing
    local updateChain = self:applyNodeChainOffset(tempChain) -- Should mutate sv nodeChain ( which is bad, because it perma does it, we only want temporary)
    local simpChain = self:simplifyNodeChain(tempChain)
    self.network:sendToClients("cl_receiveTrackData",{nodeChain = simpChain})
    --self:sv_sendAlert("Track Data loaded") -- TODO: only show once
    self.nodeChain = updateChain
end


function Loader.simplifyNodeChain(self,chain) 
    local simpChain = {}
    --sm.log.info("simping node chain") -- TODO: make sure all seg IDs are consistance
    for k=1, #chain do local v=chain[k]
        local newNode = {location = v.tempLoc, segType = v.segType.TYPE, effect = nil}
        table.insert(simpChain,newNode)
    end
    return simpChain
end


function Loader.sv_saveTrack(self) -- Reads simplified node chain and saves it
    local worldNodeChain = self:sv_loadWorldTrackData(TRACK_DATA)
    if worldNodeChain == nil then
        print("Could not find World Track data")
        return 
    end
    self.trackData = {
        ["N"] = self.trackName,
        ["I"] = self.trackID,
       [ "C"] = worldNodeChain,
       [ "O"] = self.location,
       [ "D"] = self.direction -- self.shape.at
    }
    self.storage:save(self.trackData)
end

function Loader.confirmTempChanges(self) -- Sets temporary changes into permanant changes, Mutates whole nodechain, cannot be reset unless through storage.load?
    for k=1, #self.nodeChain do local v=self.nodeChain[k] -- TODO: actually remove temporrary keys from table
        if v.tempLoc then
            v.location = v.tempLoc
            v.tempLoc = nil
        end
        if v.tempMid then
            v.mid = v.tempMid
            v.tempMid = nil
        end
        if v.tempPerp then
            v.perp = v.tempPerp
            v.tempPerp = nil
        end
        if v.tempOut then
            v.outVector = v.tempOut
            v.tempOut = nil
        end
    end
end

function Loader.sv_saveWoldTrackData(self)
    debugPrint(self.debug,"Saving track data")
    self:confirmTempChanges() -- applies temp changes to real nodechain
    local channel = TRACK_DATA
    data = self.nodeChain
    sm.storage.save(channel,data) -- track was channel
    saveData(data,channel) -- Goes into global for no reason...?
    print("Track Saved")
    self:sv_sendAlert("Track Saved To World")
end

function Loader.sv_exportTrack(self) -- Exports track as a .json file
end

function Loader.sv_importTrack(self) -- Imports .json file
end


function Loader.sv_loadWorldTrackData(self,channel) -- Loads any saved track data (simplified nodechain only) from world storage
    local worldNodeChain = sm.storage.load(channel)
    if worldNodeChain == nil then
        print("Server did not find track data") 
        if self.trackLoadError then
        else
            print("Track Data not found")
            self.trackLoadError = true
        end
    else
        print("Found Track Data",#worldNodeChain)
        --print("Server found track data") 
        if self.trackLoadError then
            print("Track Loaded")
            self.trackLoadError = false
        else
            --print("Track Loaded, initial")
        end
        return worldNodeChain
    end
end

-- Helpers
--TODO: move these to global
function calculateRotation(dir1,dir2)
    local radDif = vectorAngleDiff(dir1,dir2)
    return radDif -- TODO: just remove and use raw function, no need to wrap
end


function calculateOffset(pos1,pos2) -- calculate full offset between two vectors, will need original and new rotations?
    local offset = (pos2 - pos1) -- Might have to do a pi/2 or /180
    return offset
end

function Loader.getNewCoordinates(self,point,offset,angle) -- tak
    -- apply rotation (and pos offset?)
    --local fakeRot = math.pi/2 -- Performs a negative rotation so pi/2 rotates -90 Degress and vise versa? can either inverse here or inverse in rotation grab?
    angle = angle * -1 -- inverse angle ()
    local distFromZero = self.trackData.O -- How far away original node is from 0,0
    local centeredPoint = point - distFromZero -- Point centered around 0,0 based on origin
    --print(point.z - distFromZero.z)
    -- rotate Point(s) around 0,0
    local pointX = (centeredPoint.x*math.cos(angle) - centeredPoint.y*math.sin(angle))
    local pointY = (centeredPoint.x*math.sin(angle) + centeredPoint.y*math.cos(angle))
    local pointZ = centeredPoint.z
    local newPoint = sm.vec3.new(pointX,pointY,pointZ)
    -- offset point back to original offset
    newPoint = newPoint + distFromZero
    -- offset Point to new Location
    newPoint = newPoint + offset
    return newPoint
end

function Loader.applyNodeChainOffset(self,tempChain) -- alters temporary chain
    if tempChain == nil or #tempChain <=1 then
        print("ApplyNCO: No node chain")
        return 
    end
    local offset = calculateOffset(self.trackData.O,self.location) 
    local radians = calculateRotation(self.trackData.D,self.direction)
    local rotationQuat = sm.vec3.getRotation(self.trackData.D:normalize(),self.direction:normalize()) -- Retu
    for k=1, #tempChain do local node=tempChain[k]
        local newLocation = self:getNewCoordinates(node.location,offset,radians)
        
        --print("oldLoc",node.location.z - newLocation.z)
        
        local newMid = self:getNewCoordinates(node.mid,offset,radians)
        node['tempLoc'] = newLocation
        node['tempMid'] = newMid
        node['tempPerp'] = node.perp:rotateZ(radians) --rotationQuat * node.perp 
        node['tempOut'] = node.outVector:rotateZ(radians) --rotationQuat * node.outVector
    end 
    --local checkIndex = 20
    --print(tempChain[checkIndex].outVector.x,tempChain[checkIndex].tempOut.x)
    return tempChain
end

--visualization helpers

function Loader.sv_sendAlert(self,msg) -- sends alert message to all clients (individual clients not recognized yet)
    self.network:sendToClients("cl_showAlert",msg)
end

function Loader.cl_showAlert(self,msg) -- client recieves alert
    print("Showing Alert:",msg)
    sm.gui.displayAlertText(msg,3)
end


function Loader.toggleVisual(self,nodeChain)
    --print("displaying",self.visualizing)
    if self.visualizing then
        self:stopVisualization()
        self.visualizing = false
    else
        self:showVisualization()
        self.visualizing = true
    end
end

function Loader.stopVisualization(self) -- Stops all effects in node chain (specify in future?)
    --debugPrint(self.debug,'Stoppionng visualizaition')
    for k=1, #self.effectChain do local v=self.effectChain[k]
        if v.effect ~= nil then
            v.effect:stop()
        end
    end
    --TODO: have error catching for too large client data size (chunk data by 250? nodes)
    self.visualizing = false
end

function Loader.showVisualization(self) -- Clientstarts all effects
    for k=1, #self.effectChain do local v=self.effectChain[k]
        if v.effect ~= nil then
            if not v.effect:isPlaying() then
                v.effect:start()
            end
        end
    end
    self.visualizing = true
end

function Loader.updateVisualization(self) -- moves/updates effects according to nodeChain
    for k=1, #self.effectChain do local v=self.effectChain[k]
        if v.effect ~= nil then
            if v.location ~= nil then -- possibly only trigger on change
                v.effect:setPosition(v.location)
                if self.showSegments then
                    if v.segType ~= nil then
                        local color = sm.color.new(v.segType.COLOR)
                        v.effect:setParameter( "Color", color )
                    end
                end
                if self.visualizing then
                    if not v.effect:isPlaying() then
                        v.effect:start()
                    end
                else
                    v.effect:stop()
                end
            end
        end
    end
end

function Loader.hardUpdateVisual(self) -- toggle visuals to gain color
    self:stopVisualization()
    self:showVisualization()
end

function Loader.generateEffect(self,location,color) -- Creates new effect at param location
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

function Loader.createEfectLine(self,from,to,color) --
    local distance = getDistance(from,to)
    local direction = (to - from):normalize()
    local step = 3
    for k = 0, distance,step do
        local pos = from +(direction * k)
        table.insert(self.debugEffects,self:generateEffect(pos,(color or sm.color.new('00ffffff'))))
    end

end

function Loader.client_onInteract(self,character,state)
     if state then
		if character:isCrouching() then -- I guess toggle visuals?
            self.debug = not self.debug -- togle debug
            self:toggleVisual(self.effectChain)
		else -- Save track
			self.network:sendToServer("sv_saveTrack")
            self:cl_showAlert("Track Saved to Block")
		end
	end
end

function Loader.server_onFixedUpdate(self, timeStep)
    local location = sm.shape.getWorldPosition(self.shape)
    local direction = self.shape.at
    if self.trackData == nil then
        --print("No Track Data")
    else
        if (location ~= self.location or direciton ~= self.direciton) then
            if sm.shape.getVelocity(self.shape):length() == 0 then
                self.location = location
                self.direction = direction
                self:sv_loadTrack()
            else
                --self:stopVisualization()
            end
        end
    end

end

function Loader.client_onFixedUpdate( self, timeStep ) 
    self:updateVisualization()
    self.onHover = cl_checkHover(self.shape)
end

function Loader.client_onUpdate(self, timeStep)
    if self.onHover then 
        sm.gui.setInteractionText( self.useText,"Save Track Scan To Block ", self.tinkerText,"Save Block's Scan To World","" )
    else
    end
end

function Loader.client_canTinker( self, character )
	return true
end

function Loader.client_onTinker( self, character, state )
    --print('onTinker')
	if state then
        self.network:sendToServer('sv_saveWoldTrackData')
	end
end