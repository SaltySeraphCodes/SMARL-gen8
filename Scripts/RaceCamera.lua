RaceCamera = class()
RaceCamera.maxParentCount = -1
RaceCamera.maxChildCount = -1
RaceCamera.connectionInput = sm.interactable.connectionType.logic
RaceCamera.connectionOutput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
RaceCamera.colorNormal = sm.color.new(0x666666ff)
RaceCamera.colorHighlight = sm.color.new(0x888888ff)
dofile "globals.lua" -- load smar globals

--dofile "CameraController.lua"

function RaceCamera.server_onCreate( self ) 
	if not sm.isHost then -- Just avoid anythign that isnt the host for now
		return
	end
	self:server_init()
	print("ServerCreate")
end
 

function RaceCamera.client_init( self ) 
	--if not sm.isHost then -- Just avoid anythign that isnt the host for now
	--	return
	--end
	self.location = self.shape:getWorldPosition() + sm.vec3.new(0,0,1) -- move camera slightly above block
	self.cameraID = self.shape.id -- unique I belive
	self.active = false
	--table.insert(ALL_CAMERAS,self)
	--print("Race Camera Created",self.cameraID,#ALL_CAMERAS)

end


function RaceCamera.server_init( self ) 
	-- store location and nearest node with nearest node search
	-- load self.nodechain
	--iterate over chain
	self.cameraID = self.shape.id -- unique I belive
	self.cameraIndex = #ALL_CAMERAS + 1 -- index at 1
	self.location = self.shape:getWorldPosition() + sm.vec3.new(0,0,1) -- move camera slightly above block
	self.active = false
	self:sv_loadData(TRACK_DATA) -- sets self.nodechain & self.nodeMap
	if self.nodeChain then
		self.nearestNode = self:find_nearest_node(self.nodeChain,self.location)
	end
	table.insert(ALL_CAMERAS,self)
	print("Race Camera server Created",self.cameraID,#ALL_CAMERAS)

end

function RaceCamera.find_nearest_node(self,nodeChain,location) -- returns closest node 
	local closestDist = nil
	local closestNode = nil
	for v = 1, #nodeChain do node = nodeChain[v]
		local dist = getDistance(location,node.location)
		if closestDist == nil or dist < closestDist then
			closestDist = dist
			closestNode = node
		end
	end
	return closestNode
end


function RaceCamera.server_onRefresh( self )
	--if not sm.isHost then -- Just avoid anythign that isnt the host for now
	--	return
	--end 
	self:client_onDestroy()
	dofile "globals.lua"
	self:client_init()
	self:server_init()
end

function RaceCamera.client_onCreate(self)
	--if not sm.isHost then -- Just avoid anythign that isnt the host for now
	--	return
	--end 
	self:client_init()
end



function RaceCamera.client_onDestroy(self)
	for k, v in pairs(ALL_CAMERAS) do
		if v.cameraID == self.cameraID then
			print("Camera removed")
			table.remove(ALL_CAMERAS, k)
			return
		end
	end
end


function RaceCamera.sv_loadData(self,channel)
    local data = sm.storage.load(channel)
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


function RaceCamera.on_trackLoaded(self,data) -- Callback for when track data is actually loaded
    --print('on_trackLoaded')
    if data == nil then
        self.trackLoaded = false
    else
        self.trackLoaded = true
        self.nodeChain = data
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
    end
end

function RaceCamera.setFocus(self,racePos)
	--print("setting Focus",self)
	--print("Setting CamFocus on Pos: ",racePos)
	local racerID = getIDFromPos(racePos)
	--print("Setting focus On CarID:",racerID)
end

function RaceCamera.client_onInteract(self, char, state)
	--if not sm.isHost then -- Just avoid anythign that isnt the host for now
	--	return
	--end 
	print("raceCameraInteract",char,state)
	sm.localPlayer.getPlayer():getCharacter():setLockingInteractable(nil)
	sm.camera.setCameraState(1)
	-- TODO: Make Interaction change camera ID
	--sm.localPlayer.getPlayer():getCharacter():setLockingInteractable(nil)
	--sm.camera.setCameraState(1)
	--self.active = false
	--if state and #self.interactable:getParents() == 0 then
		--self.active = true
		--self.current_dir = char:getDirection()
		--sm.camera.setCameraState(2)
		--sm.camera.setPosition(self.shape:getWorldPosition())
		--char:setLockingInteractable(self.interactable)
	--end
end

function RaceCamera.client_onFixedUpdate(self,dt)
	if self.active then
		--local hit,result = sm.physics.spherecast(sm.camera.getPosition(), sm.camera.getPosition() + (sm.camera.getDirection() * 200), 1, 12)
		--print('hm',self.cameraID,hit,result.type)
	end
end

function RaceCamera.server_onFixedUpdate(self,dt)
	--if not sm.isHost then -- Just avoid anythign that isnt the host for now
	--	return
	--end 
	if #ALL_CAMERAS == 0 then
		print("refresh cam")
		self:server_onRefresh()
	end

	--print("isnum",sm.interactable.isNumberType(self.interactable))
end

function RaceCamera.client_onAction(self, movement, state)
	--if not sm.isHost then -- Just avoid anythign that isnt the host for now
	--	return
	--end 
	print("raceCam",movement,state)
	if movement == 0 then
		--none
		--sm.camera.setPosition(sm.localPlayer.getPlayer():getCharacter():getWorldPosition() + sm.vec3.new(0, 0, 0))
	elseif movement == 1 then
		self.left = state
	elseif movement == 2 then
		self.right = state
	elseif movement == 3 then
		self.forward = state
	elseif movement == 4 then
		self.backward = state
	elseif (movement == 15 or movement == 17) and state then
		print("set false")
		self:setActivity(false)
		sm.localPlayer.getPlayer():getCharacter():setLockingInteractable(nil)
		sm.camera.setCameraState(1)
		
	elseif movement == 20 then
		self.speed = math.min(self.max, self.speed + self.step)
		print(self.speed)
	elseif movement == 21 then
		self.speed = math.max(self.min, self.speed - self.step)
		print(self.speed)
	end
end

function RaceCamera.setActivity(self,active)
	--if not sm.isHost then -- Just avoid anythign that isnt the host for now
	--	return
	--end 
	print(self.cameraID,"Settig activeity",active)
	self.active = active

end