SmarlCamera = class()
--MOD_FOLDER = "$CONTENT_DATA/" -- folder
dofile "$CONTENT_DATA/Scripts/globals.lua" -- load smar globals?
--print("hjelloo??")
-- WHEN Loading tools manually, put this into toolsets.json:
--"$CONTENT_5411dc77-fa28-4c61-af84-bcb1415e3476/Tools/Database/ToolSets/smarltools.toolset"
function SmarlCamera.client_onCreate( self )
	self:client_init()
	--print("client create??")
end
--TODO CAMERA ACTIONS
-- Gymbol lock: keep x/y/z axis aligned while able to aim 
-- movement speed change
-- smooth ler--p speed change
-- part lock: lock pos to part/body
--fake shake (horizontal & veryical) kinda done
--side tilt?
--zooming /soom speed
--free cam on locked an individual shape by id
--drine cam type )
-- Camera modes: (Freecam, Pinned to shape, drone/helicopter)
-- camera settings (shake when near car?)
-- Have presets for certain modes (shake, action shake, smooth shake)
-- auto focus on targets
-- auto change camera
-- auto zoom
-- auto shake?
-- set drone height and speed
-- increment shake/sped amounts

function SmarlCamera.client_init( self )
	self.angle = 0
	self.offsetPos = 0
	self.zoomStrength = 60
	self.zoomIn = false
	self.zoomOut= false
	self.zoomSpeed = 0.05 -- how fast to zoom in
	self.zoomAccel = 0.003 -- how quick to ramp it
	self.raceStatus = 0
	self.gameWorld = sm.world.getCurrentWorld()
	self.player = sm.localPlayer.getPlayer()
	self.character = self.player:getCharacter()
	--print(self.player)
	self.location = self.character:getWorldPosition()
	self.primaryState = false
	self.secondaryState = false
	print("Smarl camera loaded",self.player,self.location)
	self.freeCamLocation = self.location
	self.freeCamDirection = sm.camera.getDirection()
	self.freeCamActive = false
	self.freeCamOffset = sm.vec3.new(0,0,0)

	self.raceCamActive = false
	self.raceCamDirection = sm.camera.getDirection()
	self.raceCamLocation = self.location

	self.droneCamActive = false
	
	self.hoodCamActive = false

	self.network:sendToServer("server_init")

	self.shakeVector = { -- camera shake vector
		xStrength = 0.0, -- amount
		xBump = 0.0, -- baked lerp
		yStrength = 0.0,
		yBump = 0.0,
		zStrength = 0.0,
		zBump = 0.0,

		rStrengthX = 0.01,
		rBumpX = 0.01,
		rStrengthY = 0.01,
		rBumpY = 0.01,
		rStrengthZ = 0.01,
		rBumpZ = 0.01,

	}
	
	self.freezeCam = false
	self.moveDir = sm.vec3.new(0,0,0)
	self.moveSpeed = 1 -- 1 is default, 0 is none, can increment by 0.01?
	self.moveAccel = sm.vec3.new(0,0,0) -- rate of movement
	self.lockMove = false -- locks whatever current move ment 
	self.debugCounter = 0
	self.fovValue = 70

	self.targetCamLocation = self.location
	self.targetCamDirection = sm.camera.getDirection()

	self.externalControlsEnabled = false -- whether kepyress reader is active
	self.clickCamOn = false -- Whether the user used left click to turn on freecam (allows teleporting)

	-- GUI 
	--print("loading gui")
	self.guiOpen = false
	self.RaceControlGUI = sm.gui.createGuiFromLayout( MOD_FOLDER.."Gui/Layouts/RaceControl.layout",false )
	
	if self.selectedColorButton == nil then
		self.selectedColorButton = "ColorButtonRed"
	end

	--self.RaceControlGUI:setButtonCallback( "StopRaceBtn", "client_buttonPress" )
	--self.RaceControlGUI:setButtonCallback( "StartRaceBtn", "client_buttonPress" )
	--self.RaceControlGUI:setButtonCallback( "CautionRaceBtn", "client_buttonPress" )

	self.RaceControlGUI:setButtonCallback( "ColorButtonRed", "cl_onColorButtonClick" )
	self.RaceControlGUI:setButtonCallback( "ColorButtonYellow", "cl_onColorButtonClick" )
	self.RaceControlGUI:setButtonCallback( "ColorButtonGreen", "cl_onColorButtonClick" )
	self.RaceControlGUI:setButtonCallback( "ColorButtonWhite", "cl_onColorButtonClick" )



	-- etc...
	self.RaceControlGUI:setButtonCallback( "ResetRace", "client_buttonPress" )
	self.RaceControlGUI:setButtonCallback("PopUpYNYes", "client_buttonPress")
	self.RaceControlGUI:setButtonCallback("PopUpYNNo", "client_buttonPress")
	self.RaceControlGUI:setOnCloseCallback( "client_onRaceControlGUIClose" )

end 

function SmarlCamera.server_init(self)
	self.cameraLoaded = false -- whether tool is loaded into global
	self.externalControlsEnabled = false -- whether kepyress reader is active
	self.sv_dataUpdated = false -- Flag for if data gets updated
	print("SMAR Version ",SMAR_VERSION, "Loaded")
end

function SmarlCamera.load_camera(self) -- attatches camera to smar globals
	print("loading smar cam?",SMAR_CAM)
	if setSmarCam ~= nil then
		setSmarCam(self)
		--print("set smar cam")
		self.cameraLoaded = true
	else
		print("globals not loaded")
		-- set globals load error true
	end
end

function SmarlCamera.client_onDestroy(self)
	if self.RaceControlGUI then
		self.RaceControlGUI:close()
		self.RaceControlGUI:destroy()
	end
end


function SmarlCamera.server_createCam(self,player)
	local cam = self.curCam
	print("teleporting to",self.curCam)
	local normalVec = sm.vec3.normalize(self.freeCamDirection)
	local degreeAngle = math.atan2(normalVec.x,normalVec.y) --+ 1.5708 -- Hopefully accounts for xaxis woes, could switch y and x
	local newChar = sm.character.createCharacter( player, self.gameWorld, sm.vec3.new(cam.x,cam.y,cam.z), -degreeAngle)--cam.angle )	
	self.character = newChar
	player:setCharacter(newChar)

end

function SmarlCamera.cl_recieveCommand(self,com) -- takes in string commands and runs them
	--print("cam recieved",com,com.command,com.value)

	if self.freezeCam and (com.command == "setPos" or com.command == "setDir") then
        -- Ignore movement commands if the camera is frozen
        return 
    end

	if com.command == "setMode" then
		--print("got set",com)
		if com.value == 0 then
			self:activateFreecam()
			self:deactivateRaceCam()
		elseif com.value == 1 then
			--self:deactivateFreecam()
			self:activateRaceCam()
		end -- Add drone cam??
	elseif com.command == "ExitCam" then
		if self.freeCamActive then
			self:exitFreecam()
		end	
	elseif com.command == "EnterCam" then
		if not self.freeCamActive then
			self:EnterFreecam()
		end
	elseif com.command == "SetZoom" then
		self:cl_setZoom(com.value)
	elseif com.command == "MoveCamera" then
		self:cl_setMoveDir(com.value)
	elseif com.command == "setPos" then
		self:cl_setPosition(com.value)
	elseif com.command == "setDir" then
		--print("setting dir",com.value)
		self:cl_setDirection(com.value)
	elseif com.command == "forceDir" then
		--print("forcing dir",com.value)
		self:cl_forceDirection(com.value) -- Freezes camera in state??
	end


end

function SmarlCamera.sv_recieveCommand(self,com)
	--print("cam sv_recieved",com,com.command,com.value)
	if com.command == "test" then -- switch??
		print("foff")
	elseif com.command == "setRaceMode" then
		--print("star update race mode icon")
		self.sv_colorIndex = com.value
		self.sv_dataUpdated = true;
	end
end


function SmarlCamera.sv_ping(self,ping) -- get ing
    print("SmCam got sv ping",ping)
end

function SmarlCamera.cl_ping(self,ping) -- get ing
    print("SmCam got cl ping",ping) -- cant do sandbox violations of course but can set events/commands to be read by server
	--self.tool:updateFpCamera( 30.0, sm.vec3.new( 0.0, 0.0, 0.0 ), 1, 1 ) -- aimwaiit?
	--self.tool:updateCamera( 2.8, 30.0, sm.vec3.new( 0.65, 0.0, 0.05 ), 1 )
    --self.network:sendToServer("sv_ping",ping)
end

function SmarlCamera.cl_setZoom(self,ammount) -- zooms the camere
	if ammount < 0 then
		self.zoomOut = true
		--print("zooming out")
	elseif ammount > 0 then
			self.zoomIn = true
			--print("zoom in")
	elseif ammount == 0 then
		self.zoomIn = false
		self.zoomOut = false
	end
	if self.fovValue < 10 then --?
		self.fovValue = 10
	
	end
	if self.fovValue > 90 then 
		self.fovValue = 90 
		
	end
	--print("zoom",self.zoomSpeed,self.fovValue)
end

function SmarlCamera.cl_setMoveDir(self,move) -- normalized vector to indicate movementDirection
	self.moveDir = move
	-- any fancy things can go here
end

function SmarlCamera.cl_setPosition(self,targetPosition) -- sets race camera to specified -position, resets zoom to 70
	if not self.freezeCam then
		self.targetCamLocation = targetPosition -- Store the target location
	end
end

function SmarlCamera.cl_setDirection(self,targetDirection) -- sets race camera to specified -position, resets zoom to 70
	if not self.freezeCam then 
		self.targetCamDirection = targetDirection -- Store the target direction
	end
end

function SmarlCamera.cl_forceDirection(self,direction)-- Freezes cam in direction and disables all other movement until sent to freecam
    -- 1. Set the freeze flag
	self.freezeCam = true 
    -- 2. Instantly execute the change (to bypass the smoothing layer)
    sm.camera.setDirection(direction)
    -- 3. Store the new direction as the target, so if freezeCam is released, 
    --    the camera doesn't snap back to an old direction.
    self.targetCamDirection = direction
    -- Since the camera is frozen in direction, no need to update position, 
    -- but setting the target location to current cam position is a safe practice.
    self.targetCamLocation = sm.camera.getPosition() 
    -- Optional: If forceDir should also stop position smoothing:
    -- self.targetCamLocation = sm.camera.getPosition() 
end


function SmarlCamera.cl_setMoveSpeed(self,speed) -- int that sets movement speed
	self.moveSpeed = speed
end

function SmarlCamera.cl_setShakeStrength(self,strength) --sets shake distance - ammount
	self.shakeStrength = speed
end


function SmarlCamera.cl_setShakeSpeed(self,speed) -- int sets shake speed (bumpiness) (disable xyz?)
	self.shakeSpeed = speed
end

function SmarlCamera.cl_setShakePreset(self,preset) -- int Presets for shaking modes (speed and strength)
	self.shakePreset = preset
end

function SmarlCamera.server_teleportPlayer(self,location)
	print("teleporting to",location)	
	local player = self.player
	local normalVec = sm.vec3.normalize(self.freeCamDirection)
	local degreeAngle = math.atan2(normalVec.x,normalVec.y) --+ 1.5708 -- Hopefully accounts for xaxis woes, could switch y and x
	local newChar = sm.character.createCharacter( player, self.gameWorld,location,-degreeAngle)
	self.character = newChar
	player:setCharacter(newChar)

end

function SmarlCamera.client_onRefresh( self )
	print("refresh smarlCam")
	self:client_init()
end

function SmarlCamera.client_onWorldCreated( self, world )
	print("created world",world)
end


function SmarlCamera.client_onEvent( self, world )
	print("OnEvenr",world)
end

--[[
function SmarlCamera.client_onToggle(self, backwards) check this
	local dir = 1
	if backwards then
		dir = -1
	end
	self:toggleCamera(dir)
	
end]]

function SmarlCamera.switchCam(self,cam) -- Actually does the teleporting
	local player = self.player
	self.network:sendToServer( "server_createCam", player)
	
end


function SmarlCamera.cl_teleportCharacter(self,location) -- Client teleports character to vec3 location
	self.network:sendToServer( "server_teleportPlayer", location)
end

function SmarlCamera.toggleCamera(self,dir) -- Determines next Cam and then causes telepoirt dir [-1,1] direction in list of cams
	print("Toggleing",dir,curCamID,"next:",nextCamID)
	--self:setZoom(self.curCam.zoom)
end


function SmarlCamera.client_onEquip( self )
	print("on SMARL CONtoller Tool",self.location)
	sm.audio.play( "PotatoRifle - Equip" )

end

function SmarlCamera.client_onUnequip( self )

end


function SmarlCamera.client_onPrimaryUse( self, state )
	print("test")
	if state == 1 then
		self.zooming = true
	elseif state == 2 then
		self.zoomAccel = self.zoomAccel + 0.003
		self.accelZoom = true
	elseif state == 0 then
		self.zooming = false
		self.zoomAccel = 0
		self.zoomSpeed = 0.01
		self.accelZoom = false
	end
	
	return true
end

function SmarlCamera.client_onSecondaryUse( self, state )
	--print('help')
	sm.camera.setCameraPullback( 1, 1 )
	if state == 1 then
		self.zoomoutg = true
	elseif state == 2 then
		self.zoomAccel = self.zoomAccel + 0.003
		self.accelZoom = true
	elseif state == 0 then
		self.zoomoutg = false
		self.zoomAccel = 0
		self.zoomSpeed = 0.01
		self.accelZoom = false
	end
	
	return true
end

function SmarlCamera.client_onReload(self)
	local isSprinting =  self.tool:isSprinting()
	local isCrouching =  self.tool:isCrouching() 
	local dir = 1
	local raceStatus = self.raceStatus
	print("Checking ", SMAR_VERSION)
	if isCrouching then
		dir = -1
	end
	sm.gui.chatMessage( "SMAR VERSON: " ..SMAR_VERSION )
	raceStatus = raceStatus + dir
	--print("Setting race status",raceStatus,dir)
	--print(sm.smarlFunctions)
	self.raceStatus = raceStatus
	return true
end

function SmarlCamera.client_onFixedUpdate( self, timeStep )
	local moveVel = self.tool:getRelativeMoveDirection()*2.5
	
	if getRaceControl() ~= nil and getRaceControl().viewIngCamera == true then
		--print("ignoring input")
	else
		if self.freeCamActive then 
			--print("moveVel",moveVel)
			-- dont do jumping
			moveVel.z = 0
			self.moveAccel = moveVel
		end
	end
	--print(sm.tool.interactState)
end

function SmarlCamera.client_onClientDataUpdate(self,clientData)
	local selectedColor -- Set default as self.selectedColorButton
	if clientData.colorIndex then
		if clientData.colorIndex == 0 then -- red
			selectedColor = "ColorButtonRed"
		elseif clientData.colorIndex == 2 then -- yellow
			selectedColor = "ColorButtonYellow"
		elseif clientData.colorIndex == 1 then -- Green
			selectedColor = "ColorButtonGreen"
		elseif clientData.colorIndex == 3 then -- white
			selectedColor = "ColorButtonWhite"
		else --Fall Back
			selectedColor = "ColorButtonRed"
		end
	end

	if self.RaceControlGUI then
		self:cl_updateColorButton( selectedColor )
	else
		self.selectedColorButton = selectedColorButton
	end
end

function SmarlCamera.client_onUpdate( self, timeStep )
	if  not sm.exists(self.character) then
		self.character = self.player:getCharacter()
		return end
		--sm.camera.setFov(20) -- TODO: clean this up into fewer functions

	--print("Actual",sm.camera.getPosition(),sm.camera.getDirection())
	
	--self.location = self.character:getWorldPosition() -- Make this only move according to camera mode
	--[[if not self.freeCamActive then -- if nothing active  
		--print("wut")
		self.freeCamLocation = self.character:getWorldPosition()
		self.freeCamLocation.z = self.freeCamLocation.z + 2
	else
		self.freeCamDirection = sm.camera.getDirection() -- only allow mouse move when mouse move abvle
	end]]

	-- === 1. FREE CAM MODE ===
	local goalPos = sm.vec3.new(self.freeCamLocation.x,self.freeCamLocation.y,self.freeCamLocation.z)
	--local goalDir = self.character:getDirection()
	
	if self.freeCamActive then 
        
        -- A. Prepare Free Cam Targets (This block MUST be inside the active check)
        
        local moveDir = self.moveDir
        moveDir = sm.vec3.lerp(self.moveAccel, moveDir, timeStep * 4)
        self.moveAccel = moveDir
        
        -- Shake Calculations (Keep these simplified for clarity, using your existing variables)
        local xNoise = sm.noise.floatNoise2d(self.debugCounter * self.shakeVector.xBump + 3, 10, 5) * self.shakeVector.xStrength
        local yNoise = sm.noise.floatNoise2d(self.debugCounter * self.shakeVector.yBump + 6, 10, 6) * self.shakeVector.yStrength
        local zNoise = sm.noise.floatNoise2d(self.debugCounter * self.shakeVector.zBump + 8, 10, 7) * self.shakeVector.zStrength
        
        local xNoiseR = sm.noise.floatNoise2d(self.debugCounter * self.shakeVector.rBumpX, 10, 4) * self.shakeVector.rStrengthX
        local yNoiseR = sm.noise.floatNoise2d(self.debugCounter * self.shakeVector.rBumpY, 10, 3) * self.shakeVector.rStrengthY
        local zNoiseR = sm.noise.floatNoise2d(self.debugCounter * self.shakeVector.rBumpZ, 10, 2) * self.shakeVector.rStrengthZ

        -- Apply Movement and Shake to Goal Position
        local goalPos = self.freeCamLocation + moveDir * self.moveSpeed
        goalPos.x = goalPos.x + xNoise
        goalPos.y = goalPos.y + yNoise
        goalPos.z = goalPos.z + zNoise

        -- Apply Rotation Noise to Goal Direction (using current direction for reference)
        local goalDir = self.character:getDirection()
        goalDir.x = goalDir.x + xNoiseR
        goalDir.y = goalDir.y + yNoiseR
        goalDir.z = goalDir.z + zNoiseR
        
        -- B. Execute Free Cam Movement
        local posLerpFactor = timeStep * 10
        local dirLerpFactor = timeStep * 4
        self.freeCamLocation = sm.vec3.lerp(self.freeCamLocation, goalPos, posLerpFactor)
        self.freeCamDirection = sm.vec3.lerp(self.freeCamDirection, goalDir, dirLerpFactor) 

        sm.camera.setPosition(self.freeCamLocation) 
        sm.camera.setDirection(self.freeCamDirection)
        
    -- === 2. RACE CONTROL MODES (Drone/Race/Onboard) ===
    elseif self.raceCamActive or self.droneCamActive or self.hoodCamActive then
		local MAX_TIMESTEP = 0.0333 -- Max time step equivalent to ~30 FPS (or 2 frames of 60 FPS)
        if not self.freezeCam and self.targetCamLocation and self.targetCamDirection then
			local BASE_POS_LERP = 8 -- A factor that results in smooth movement (e.g., 8 to 12)
			local CATCHUP_FACTOR = 0.1  -- How aggressively the camera closes the gap (0.1 to 1.0)
			local MAX_TRAIL_DISTANCE = 10 -- Max distance to use the CATCHUP LERP (in meters)
			local DIR_LERP = 12
            local finalDirLerpFactor = timeStep * DIR_LERP
            local currentPos = sm.camera.getPosition()
            local currentDir = sm.camera.getDirection()
			local lagDistance = (self.targetCamLocation - currentPos):length()
			local finalPosLerpFactor
			-- 2. DYNAMIC LERP FACTOR CALCULATION
			if lagDistance > MAX_TRAIL_DISTANCE then
				-- A. Massive Lag/Jump: Force a smoother but fast catch-up LERP, 
				finalPosLerpFactor = timeStep * 20.0 -- Use a higher factor for the immediate catchup (use maximum dt?)
			elseif lagDistance > 0.01 then -- If there's any noticeable lag
				local catchUpRatio = math.min(lagDistance * CATCHUP_FACTOR, 1.0)
				finalPosLerpFactor = timeStep * (BASE_POS_LERP + (BASE_POS_LERP * catchUpRatio))
			else
				finalPosLerpFactor = timeStep * BASE_POS_LERP
			end
			local CLAMPED_LERP_FACTOR = math.min(finalPosLerpFactor, 0.4)
            local finalPos = sm.vec3.lerp(currentPos, self.targetCamLocation, CLAMPED_LERP_FACTOR)
            local finalDir = sm.vec3.lerp(currentDir, self.targetCamDirection, DIR_LERP)

			local DIST_TO_TARGET = (self.targetCamLocation - currentPos):length()
			if DIST_TO_TARGET > 8.0 then -- If camera trails too far behind
				--print("jump to target")
				--finalPos = self.targetCamLocation
			end

            --sm.camera.setPosition(finalPos)
            sm.camera.setDirection(finalDir)
        end        
    end

	--zoom
	local zoomAmmount = 0
	if self.zoomIn then 
		--print("zoomin")
		zoomAmmount = -0.6
	elseif self.zoomOut then
		--print("zoomOut")
		zoomAmmount = 0.6
	end
	if zoomAmmount ~= 0 then 
		self.zoomSpeed = sm.util.lerp(self.zoomSpeed,zoomAmmount,0.1)
	else
		self.zoomSpeed = sm.util.lerp(self.zoomSpeed,zoomAmmount,0.1) --0,m  
	end
	self.fovValue = sm.util.lerp(self.fovValue,self.fovValue + self.zoomSpeed,0.5)
	if self.fovValue < 15 then --?
		self.fovValue = 15
	
	end
	if self.fovValue > 60 then 
		self.fovValue = 60
		
	end
	--sm.camera.setFov(self.fovValue) -- TODO: clean this up into fewer functions
	self.debugCounter = self.debugCounter + 1
	--print("Cinecamera cl Update After")

	-- GUIL Setting
	if RACE_CONTROL then -- Need better connector for RACE_CONTROL
		local raceStat = " - "
		local lapStat = " - "
		local statusText = ""
		if RACE_CONTROL.raceStatus == 1 then
			raceStat = "Race Status: #11ee11Racing"
		elseif RACE_CONTROL.raceStatus == 0 then
			raceStat = "Race Status: #ff2222Stopped"
		elseif RACE_CONTROL.raceStatus == 2 then
			raceStat = "Race Status: #ffff11Caution"
		
		elseif RACE_CONTROL.raceStatus == 3 then
			raceStat = "Race Status: #fafafaFormation"
		
		end
		if RACE_CONTROL.raceFinished then
			raceStat = "Race Status: #99FF99Finished"
		end    

		if RACE_CONTROL.currentLap ~= nil then
			lapStat = "Lap ".. RACE_CONTROL.currentLap .. " of " .. RACE_CONTROL.targetLaps
		end

		if self.RaceControlGUI then
			self.RaceControlGUI:setText("StatusText", raceStat )
			self.RaceControlGUI:setText("LapStat", lapStat )
		end
	end

end

function SmarlCamera.server_onFixedUpdate( self, timeStep )
	--print(CLOCK)
	--print("rc_server FIxed update before")
	if not self.cameraLoaded then
		self:load_camera()
	else
		-- Check for data update flag?
	if	self.sv_dataUpdated then
		self:sv_updateIcon({colorIndex = self.sv_colorIndex})
		self.sv_dataUpdated = false
	end

	end
	--print("rc_server FIxed update after")

end

function SmarlCamera.client_onEquippedUpdate( self, primaryState, secondaryState )
	--print(primaryState,secondaryState)
	if primaryState ~= self.primaryState then
		if primaryState == 1 then
			--print("left clicked",primaryState)
			self:activateFreecam()
			self.clickCamOn = true
		end
		self.primaryState = primaryState
	end

	if secondaryState ~= self.secondaryState then
		if secondaryState == 1 then
			--print("right clicked",secondaryState)
			if self.clickCamOn then 
				self:deactivateFreecam()
				self.clickCamOn = false
			end
		end
		self.secondaryState = secondaryState
	end

	return true, true
end

function SmarlCamera.client_onToggle( self)
	--print("toggle",self.guiOpen)
	self.RaceControlGUI:open()
	self.guiOpen = true
	-- TODO: Make a switch that opens and closes on toggle
end

function SmarlCamera.client_onAction(self, input, active)
	print("action",input,active)
end

function SmarlCamera.cl_unfreezeCam(self)
    if self.freezeCam then
        self.freezeCam = false
        print("SmarlCamera: Unfreeze command received. Camera released.")
    end
end


function SmarlCamera.activateFreecam(self)
	--print("activate1",self.freeCamDirection,sm.localPlayer.getDirection())
	-- CLEANUP: Disable all other modes first
    self.raceCamActive = false
    self.droneCamActive = false
    self.hoodCamActive = false
    
    self.freezeCam = false -- Ensure camera is unlocked
    self.debugCounter = 0

	-- Use the CURRENT camera state as the starting point for freecam
    self.freeCamLocation = sm.camera.getPosition()
    self.freeCamDirection = sm.camera.getDirection()
	-- Set the character's direction to match the camera's direction, 
    -- or else the character may immediately spin when returned to control.
    -- (This may require a server/client action depending on your char control setup)
    -- sm.localPlayer.setDirection(self.freeCamDirection)
	
	print("freecam Activated",self.freeCamDirection)
	--self.freeCamOffset = self.freeCamDirection What was this used for? no longer needed?
	sm.camera.setCameraState(2)
	self.freeCamActive = true
end

function SmarlCamera.activateRaceCam(self)
	-- CLEANUP: Disable other modes that are not race cam
    self.freeCamActive = false
    self.droneCamActive = false
    self.hoodCamActive = false
    
    self.raceCamActive = true
end

function SmarlCamera.deactivateRaceCam(self)

	self.raceCamActive = false
end

function SmarlCamera.deactivateFreecam(self)
	if self.character == nil then print("no char") return end
	self.freeCamActive = false
	print("freecam Deacivated")
	self.character:setLockingInteractable(nil)
	self:cl_teleportCharacter(self.freeCamLocation) -- teleports char to cam loc
	self.tool:updateFpCamera( 70.0, sm.vec3.new( 0.0, 0.0, 0.0 ), 1, 1 ) -- aimwaiit?
	sm.camera.setCameraState(1)
end

function SmarlCamera.exitFreecam(self)
	print("Camera exited")
	self.freezecam = false
	self.character:setLockingInteractable(nil)
	self.tool:updateFpCamera( 70.0, sm.vec3.new( 0.0, 0.0, 0.0 ), 1, 1 ) -- aimwaiit?
	sm.camera.setCameraState(1)
	self.freeCamActive = false
end

function SmarlCamera.EnterFreecam(self)
	print("Enter Entered")
	if self.location == nil then
		self.location = sm.vec3.new(0,0,10)
	end
	if self.freeCamDirection == nil then
		self.freeCamDirection = sm.vec3.new(0,0,1)
	end
	self.debugCounter = 0
	sm.camera.setPosition(self.location)
	sm.camera.setDirection(self.freeCamDirection)
	sm.camera.setCameraState(2)
	--self.character:setLockingInteractable(self.interactable)
	self.freeCamActive = true
	self.raceCamActive = false
end



-- Json and keypress reader
function SmarlCamera.sv_ReadJson(self)
    local jsonData = sm.json.open(MOD_FOLDER.."JsonData/cameraInput.json")
   
    if jsonData == nil or jsonData == {} or not jsonData or #jsonData == 0 or jsonData == "{}" then
        print("NO data")
        return
	else
		print("data",jsonData)
		self:parseJsonData(jsonData)
	end
	
end

function SmarlCamera.parseJsonData(self)
	
end



-- GUI Functions

function SmarlCamera.sv_updateIcon( self, params ) -- Up[dates colors]
	if params.colorIndex then
		self.colorIndex = params.colorIndex
	end
	self.network:setClientData( {colorIndex = self.colorIndex } )
end

function SmarlCamera.client_buttonPress( self, buttonName )
    --print("clButton",buttonName)
    -- if not self.cl and cl2 then self.cl = cl2 end -- Verify if game data exits
	if buttonName == "StartRaceBtn" then
		print("yes")
		-- Trigger btn
	
    elseif buttonName == "ResetRace" then
        if (self.raceStatus == 1 or self.raceStatus == 2 or self.raceStatus == 3 )and not self.raceFinished then -- Mid race
            self.RaceControlGUI:setText("PopUpYNMessage", "Still Racing, Reset?")
            self.RaceControlGUI:setVisible("PopUpYNMainPanel", true)
		    self.RaceControlGUI:setVisible("CreateRacePanel", false)
            self.PopUpYNOpen = true
        else
            --self.RaceMenu:setText("PopUpYNMessage", "Start Game?")
            --self.RaceMenu:setVisible("CreateRacePanel", false)
            self.RaceControlGUI:close()
            self:cl_send_resetRace()
        end
		
    
    elseif buttonName == "PopUpYNYes" then
            --print("resetting race match")
            self.RaceControlGUI:setVisible("CreateRacePanel", true)
            self.RaceControlGUI:setVisible("PopUpYNMainPanel", false)
            self.RaceControlGUI:close()
            self:cl_send_resetRace() -- reset race
            self.PopUpYNOpen = false
            --print("Resetting mid race")    
	elseif buttonName == "PopUpYNNo" then
		self.RaceControlGUI:setVisible("CreateRacePanel", true)
		self.RaceControlGUI:setVisible("PopUpYNMainPanel", false)
		self.PopUpYNOpen = false
    else
        print("buton not recognized")
    end
end

function SmarlCamera.client_OnOffButton( self, buttonName, state )
	self.RaceMenu:setButtonState(buttonName.. "On", state)
	self.RaceMenu:setButtonState(buttonName.. "Off", not state)
end



function SmarlCamera.cl_updateColorButton( self, colorButtonName )
	if self.selectedColorButton ~= colorButtonName then
		self.RaceControlGUI:setButtonState( self.selectedColorButton, false )
		self.selectedColorButton = colorButtonName
	end
	self.RaceControlGUI:setButtonState( self.selectedColorButton, true )
end


function SmarlCamera.cl_onColorButtonClick( self, name )
	local colorIndex = 0 -- Race State
	if name == "ColorButtonRed" then 
		colorIndex = 0
	elseif name == "ColorButtonYellow" then
		colorIndex = 2
	elseif name == "ColorButtonGreen" then
		colorIndex = 1
	elseif name == "ColorButtonWhite" then
		colorIndex = 3
	end

	self:cl_set_RaceMode(colorIndex) -- Sends Racemode update to Race Control (if exists)
	self.network:sendToServer( "sv_updateIcon", { colorIndex = colorIndex } )
end


-- Race Control control from GUI press
function SmarlCamera.cl_send_resetRace(self)
	if RACE_CONTROL then
		self.network:sendToServer("sv_setResetRace")
	else
		print("no race control")
		--TODO: GUI alert
	end
end

function SmarlCamera.sv_setResetRace(self)
	if RACE_CONTROL then
		RACE_CONTROL:sv_resetRace()
	else
		print("No server Race Control")
	end
end

function SmarlCamera.cl_set_RaceMode(self,status)
	if RACE_CONTROL then
		self.network:sendToServer("sv_setRaceMode",status)
	else
		print("No Race Control Detected")
		--TODO GUI alert?
	end
end

function SmarlCamera.sv_setRaceMode(self,status)
	if RACE_CONTROL then
        RACE_CONTROL:sv_toggleRaceMode(status)
	else
		print("No Server Race control")
	end
end


function SmarlCamera.client_onRaceControlGUIClose( self )
    --print("MenuOnclose")
    if PopUpYNOpen then
		self.RaceControlGUI:open()
		self.RaceControlGUI:setVisible("ControlRacePanel", true)
		self.RaceControlGUI:setVisible("PopUpYNMainPanel", false)
		PopUpYNOpen = false
    end
    --self.RaceMenu:destroy()
    --self.RaceMenu = sm.gui.createGuiFromLayout( "$CONTENT_"..MOD_UUID.."/Gui/Layouts/RaceMenu.layout",false )

end