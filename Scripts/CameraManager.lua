-- Camera manager that handles all of camera switching and movement and automation (formerly in race control)
-- Imported as a class in Race control and is ran from onfixed and etc. 
-- Goals: Handles automated Camera switching and focusing on cars. acts as an automated race director

dofile("globalsGen8.lua")
dofile "Timer.lua" 
CameraManager = class( nil )
local clock = os.clock --global clock

function CameraManager.client_onCreate( self ) 
	self:client_init()
end

function CameraManager.client_onDestroy(self)
    print("Camera manager destroy")
    self.trackedRacer = nil
    self.trackedRacers = {}
    -- Or is this already reset in client_init?
end


function CameraManager.client_init( self,rc ) 
    if rc == nil then
        print("cl Camera manager has no rc",nil)
    end
    self.raceControl = rc
    self.started = clock()
    self.globalTimer = clock()


    self.finishCamActive = false -- wheter to focus on finish line or not
    self.isFrozen = false -- whether the camera moves

    self.recentSwitchTimer = Timer()
    self.recentSwitchTimer:start(40)


    self.maxZoomIn = 28
    self.maxZoomOut = 65 -- maximum zoom in 

    self.zoomStratOut = {ZOOM_METHODS.OUT,ZOOM_METHODS.IN,ZOOM_METHODS.OUT}
    self.zoomStratIn = {ZOOM_METHODS.IN,ZOOM_METHODS.OUT,ZOOM_METHODS.IN}
    self.zoomStratStayOut = {ZOOM_METHODS.OUT,ZOOM_METHODS.OUT,ZOOM_METHODS.OUT}
    self.zoomStratInOut = {ZOOM_METHODS.IN,ZOOM_METHODS.OUT,ZOOM_METHODS.OUT}
    self.allZoomStrats = {self.zoomStratIn,self.zoomStratOut,self.zoomStratStayOut,self.zoomStratInOut} -- List of different camera movements

    self.currentCameraMode= CAMERA_MODES.DRONE_CAM

    self.currentTrackedRacerId = nil -- Unique ID of the currently focused racer
    self.trackedRacer = nil -- current tracked racer?
    self.trackedRacers = {} -- multiple tracked racers (may only do this)
    self.trackingBias = 0.5 -- 1 is lead car, 0 is midpoint

    self.trackingLocation = sm.vec3.new(0,0,2) -- camera tracking final location

    -- Drone Camera setup
    self.droneCamSmoothness = 50 -- 3-100 (camera lag/smoothness of following racer) 
    self.droneCamDirSmoothness = 25 -- cam directio, smoothness
    self.droneTrackingRate = 0.05 -- smoothness of camera rotation

    self.droneCameraArr = {}
    self.droneCameraDirArr = {}
    self.droneCameraPos = sm.vec3.new(0,0,25) -- Direct drone cam position, gets update by average of CamArr
    self.droneCameraDir = sm.vec3.new(0,0,-1) -- Drone Camera Direction
    self.droneCameraRot = sm.quat.fromEuler(sm.vec3.new(0,0,-1))
    self.WorldUpVector = sm.vec3.new(0, 0, 1) -- 
    
    -- Onboard cam Setup
    self.onboardCamPosSmooth = 12 -- onboard camera smoothness (keep tight?)
    self.onboardCamDirSmooth = 12 -- Direction smoothness, (keep )
    self.onboardCameraPosArr = {}
    self.onboardCameraDirArr = {}
    self.onboardCameraPos = sm.vec3.new(1,0,10)
    self.onboardCameraDir = sm.vec3.new(0,1,0)

    -- Race Camera setup
    self.raceTrackingRate = 0.1
    self.raceCamDirSmooth = 9
    self.raceCameraTrackingEnabled = true 
    self.raceCameraIndex = 1 -- Which race cam 
    self.all_raceCams = {} -- Not necessary?
    self.raceCameraDirArr = {} -- Reset on new cam?
    self.chosenRaceCam = nil
    self.raceCameraPos = sm.vec3.new(10,0,15) -- The o
    self.raceCameraRot = sm.quat.fromEuler(sm.vec3.new(0,0,-1))
    self.raceCameraDir = sm.vec3.new(0,0,-1)
    -- timer:
    self.cameraHoldTimer = Timer()
    self.cameraHoldTimer:start(1)

    -- FOV/Zoom
    self.fovValue = 65
    self.zoomIn = false
    self.zoomOut = false
    self.AutoDirecting = false -- Whether to automate the camera control

end


function CameraManager.client_onRefresh( self )
	self:client_onDestroy()
	self:client_init(self.raceControl)
end


function CameraManager.asyncSleep(self,func,timeout)
    --print("weait",self.globalTimer,self.gotTick,timeout)
    if timeout == 0 or (self.gotTick and self.globalTimer % timeout == 0 )then 
        --print("timeout",self.globalTimer,self.gotTick,timeout)
        local fin = func(self) -- run function
        return fin
    end
end


function CameraManager.client_onFixedUpdate(self) -- key press readings and what not clientside
    self:cl_tickClock() -- Runs every second
    self:cl_ms_tick() -- Runs every tick
    self:cl_updateTrackingLocation()
    if self.cameraHoldTimer:done() then -- pick new cam
        self:cl_decideCameraAndFocus()
    end
    
    if self.finishCamActive then -- and isFrozen
        self:cl_executeFinishCam() -- only really need to run this once
    end

    if self.recentSwitchTimer:done() then 
        self.recentSwitch = false 
    end
   
end

function CameraManager.client_onUpdate(self,dt)
    -- Update all potential camera points in the BG
    self:cl_updateDroneCamPosition(dt)
    --self:cl_updateDroneCamRotation(dt)
    self:cl_updateDroneCamDirection(dt)
    self:cl_updateOnboardCamPosition(dt)
    self:cl_updateOnboardCamDirection(dt)
    self:cl_updateRaceCameraPosition(dt)
    self:cl_updateRaceCameraDirection(dt)
    --self:cl_updateRaceCameraRotation(dt)



    if self.cameraActive then
        self:cl_setCameraFov(dt)
        self:cl_setCameraPosition(dt)
        self:cl_setCameraRotation(dt) -- Camera direction
    end
end

-- Client
function CameraManager.toggleFinishCam(self,value) -- called from race control (todo: handle finishcam logic here too)
    if self.finishCamActive ~= value then
        --print("Toggling finish cam to",value)
        self.finishCamActive = value
    end
end

function CameraManager.cl_executeFinishCam(self) -- Sets up and runs finishCamera 
    local all_cams = getAllCameras()
    if all_cams == nil or #all_cams == 0 then 
        print("No Finish Cam Defined (or any cam)")
        return 
    end
    local chosenCamera = all_cams[1] -- First Cam will Always be the dedicated finish line camera
    local firstCar = getDriverByPos(1)  -- Grab first place driver
    if firstCar == nil then return end
    if not chosenCamera or not chosenCamera.location or not firstCar or not firstCar.nodeChain or not firstCar.nodeChain[1] then 
        self:toggleFinishCam(false)
    end
    
    local focusSpot = firstCar.nodeChain[1].mid -- Location of finish 
    local camSpot = chosenCamera.location -- location of camera.
    local goalOffset = (focusSpot - camSpot):normalize() -- look direction
    
    self.finishCameraPos = camSpot
    self.finishCameraDir = goalOffset
    if self.currentCameraMode ~= CAMERA_MODES.FINISH_CAM then
        self:setCameraMode(CAMERA_MODES.FINISH_CAM)
    end
    self.isFrozen = true
end

function CameraManager.cl_setCameraFov(self,dt) -- Directly sets camera value dep3nding on which state we are in
    --sm.camera.setFov(self.fovValue)    
end

function CameraManager.cl_setCameraPosition(self,dt)
    local CurCamPos = sm.camera.getPosition()
    local lerpMult = dt * 10
    if self.recentSwitch then
        --print('recentswitch')
        lerpMult = 1
    end

    if self.currentCameraMode == CAMERA_MODES.DRONE_CAM then 
        local LerpedPos = sm.vec3.lerp(CurCamPos,self.droneCameraPos,lerpMult)
        sm.camera.setPosition(LerpedPos) -- lerp/dt?
    elseif self.currentCameraMode == CAMERA_MODES.ONBOARD_CAM then 
        local LerpedPos = sm.vec3.lerp(CurCamPos,self.onboardCameraPos,lerpMult)
        sm.camera.setPosition(LerpedPos)
    elseif self.currentCameraMode == CAMERA_MODES.RACE_CAM then 
        sm.camera.setPosition(self.raceCameraPos)
    elseif self.currentCameraMode == CAMERA_MODES.FINISH_CAM then
        sm.camera.setPosition(self.finishCameraPos)
    else
        print("Bad camera mode set",self.currentCameraMode)
    end

end

function CameraManager.cl_setCameraRotation(self,dt) -- Camera direction/rotation
    if self.currentCameraMode == CAMERA_MODES.DRONE_CAM then 
        --sm.camera.setRotation(self.droneCameraRot)
        sm.camera.setDirection(self.droneCameraDir:normalize())-- Temporary here until rotation is fixed
    elseif self.currentCameraMode == CAMERA_MODES.ONBOARD_CAM then 
        sm.camera.setDirection(self.onboardCameraDir:normalize()) -- or rotation??
    elseif self.currentCameraMode == CAMERA_MODES.RACE_CAM then 
        sm.camera.setDirection(self.raceCameraDir:normalize())
        --sm.camera.setRotation(self.raceCameraRot) -- needs testing
    elseif self.currentCameraMode == CAMERA_MODES.FINISH_CAM then
        sm.camera.setDirection(self.finishCameraDir:normalize()) -- static so doesnt need much more
    else

    end
end

function CameraManager.enterCamera(self) -- sets the camera mode, RC will hande controls but this just  teells itself it in mode
    self.cameraActive = true
    sm.camera.setCameraState(2)

end

function CameraManager.exitCamera(self)
    self.cameraActive = false
    -- Set camera defaults?
    sm.camera.setFov(75)
    sm.camera.setCameraState(1)
end

function CameraManager.setCameraMode( self,mode ) -- client
    if self.currentCameraMode ~= mode then
        self.recentSwitch = true -- hold frame
        self.recentSwitchTimer:start(40)
        print("changing cam mode",mode)
        self.currentCameraMode = mode 
    end
end


-- CORRECTED cl_updateTrackingLocation
function CameraManager.cl_updateTrackingLocation(self)
    local trackingLocation = sm.vec3.new(0,0,5)
    
    if self.trackedRacers and #self.trackedRacers >= 1 then 
        local midPoint = sm.vec3.new(0,0,0)
        local totalRacers = #self.trackedRacers -- Use the correct count
        
        -- 1. Calculate Sum of Positions (Centroid Numerator)
        for _, racer in pairs(self.trackedRacers) do
            if racer and racer.location then
                midPoint = midPoint + racer.location
            end
        end

        -- 2. Calculate the Centroid (True Midpoint)
        -- This relies on the sm.vec3 / number support you confirmed!
        local centroidLocation = midPoint / totalRacers
        
        -- 3. Determine Bias Target (Leader)
        local mainCar = self.trackedRacers[1]  -- was getDriverByPos(1)
        
        -- Default bias location is the centroid itself (trackingBias = 0)
        local biasLocation = centroidLocation 

        if mainCar and mainCar.location then
            -- If a valid leader exists, set the bias target to the leader's location
            biasLocation = mainCar.location
        end
        
        -- 4. Apply Tracking Bias (LERP)
        -- Blends from the centroid (0.0) toward the leader's location (1.0)
        trackingLocation = sm.vec3.lerp(centroidLocation, biasLocation, self.trackingBias)

    elseif self.trackedRacer and self.trackedRacer.location then 
        -- Fallback: Only one specific racer tracked
        trackingLocation = self.trackedRacer.location
    else 
        -- Fallback: No tracked racers, search for any driver or use safe default
        local allDrivers = getAllDrivers()
        if allDrivers and #allDrivers >= 1 and allDrivers[1].location then
            self.trackedRacer = allDrivers[1]
            trackingLocation = self.trackedRacer.location
        else 
            trackingLocation = sm.vec3.new(0,0,5)
        end
    end
    --print('setting tracking location',trackingLocation)
    self.trackingLocation = trackingLocation
end

function CameraManager.addTrackedRacer(self,racer)
    table.insert(self.trackedRacers,racer)
end

function CameraManager.removeTrackedRacer(self,racer)
    local index = getIndexKeyValue(self.trackedRacers,'id',racer.id)
    if not index then 
        return false
    end
    table.remove( self.trackedRacers, index )
end


function CameraManager.cl_resetDroneArrays(self)
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    self.droneCameraArr = {} -- Clear the history!
    self.droneCameraDirArr = {} -- Also clear the direction history
    if self.trackedRacer then
        local nextLocation = self.trackedRacer.location + self.raceControl.droneOffset
        for i=1, self.droneCamSmoothness do -- Fill the array with the starting position to prevent lag/jump
            table.insert(self.droneCameraArr, nextLocation)
        end
        local droneCameraPos = nextLocation -- Get the actual camera position
        local targetPos = self.trackingLocation
        local lookDirection = (targetPos - droneCameraPos):normalize()
        if lookDirection ~= nil then
            for i=1, self.droneCamDirSmoothness do -- Fill the array with the starting position to prevent lag/jump
                table.insert(self.droneCameraDirArr, lookDirection)
            end
        end
    end

end

function CameraManager.cl_updateDroneCamPosition(self,dt) 
    -- check if tracked racer exists
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    local currentRacerId = self.trackedRacer and self.trackedRacer.id or nil
    if currentRacerId ~= self.currentTrackedRacerId then -- Switching to new racer
        
        local lastPosition = self.droneCameraPos -- sm.camera.getPosition() -- or dronePosition
        local nextLocation = self.trackedRacer.location + self.raceControl.droneOffset
        local dist = (lastPosition-nextLocation):length2()
        --print("nextDist",dist,self.currentCameraMode)
        if self.currentCameraMode ~= CAMERA_MODES.DRONE_CAM then -- also check distance-- Reset drone position since cam too far
            --print("reset drone arr",self.currentCameraMode)
            self:cl_resetDroneArrays()
        end
        self.currentTrackedRacerId = currentRacerId
    end
    
    -- Get list of racers in top 10
    local top10Drivers = getDriversAbovePos(10)
    local avgPos = sm.vec3.new(0,0,0)
    for _,racer in pairs(top10Drivers) do 
        if racer then 
            avgPos = avgPos + racer.location
        end
    end
    avgPos = avgPos/#top10Drivers -- Average position between top 10 drivers 

    if avgPos then 
        local nextLocation = avgPos + self.raceControl.droneOffset
        if nextLocation == nil then -- Move to velocity??
            nextLocation = self.droneCameraArr[#self.droneCameraArr]  + self.raceControl.droneOffset -- Replaces with back location
        end
        table.insert(self.droneCameraArr,nextLocation)

        if #self.droneCameraArr > self.droneCamSmoothness then
            table.remove(self.droneCameraArr,1)
        end
        local avg = sm.vec3.new(0,0,0)
        for _,x in pairs(self.droneCameraArr) do
            --print(x)
            avg = avg + x
        end
        avg = avg/self.droneCamSmoothness
        self.droneCameraPos = avg-- directly pull this value onUpdate
    else -- todo get distance between camPos, next avg  and DT to determine lag spikes/camera jumps
        -- TODO: Have the drone follow the nodeChain in RC
    end

end

function CameraManager.cl_updateDroneCamRotation(self, dt) -- might need to get avg over time for smoothness?
    if self.trackingLocation then -- doesnt need focused racer?
        local droneCameraPos = sm.camera.getPosition() -- Get current camera position
        local targetPos = self.trackingLocation   -- Get target position (Racer)
        local lookVector = (targetPos - droneCameraPos):normalize()
        if lookVector:length2() < 0.0001 then
            return
        end
        -- 2. Create the Goal Quaternion from the Look Vector
        -- sm.quat.lookRotation() converts a direction vector into a quaternion rotation.
        local goalQuat = sm.quat.lookRotation(lookVector, self.WorldUpVector)
        local currentQuat = sm.camera.getRotation()
        local smoothedQuat = sm.quat.slerp(currentQuat, goalQuat, self.droneTrackingRate)
        self.droneCameraRot = smoothedQuat -- rename to rotation?
    end
end

function CameraManager.cl_updateDroneCamDirection(self, dt)
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    if self.trackedRacer then
        local droneCameraPos = self.droneCameraPos -- Get the actual camera position
        local targetPos = self.trackingLocation
        local lookDirection = (targetPos - droneCameraPos):normalize()
        if lookDirection == nil then
            lookDirection = self.droneCameraDirArr[#self.droneCameraDirArr]
        end
        table.insert(self.droneCameraDirArr,lookDirection)

        if #self.droneCameraDirArr > self.droneCamDirSmoothness then
            table.remove(self.droneCameraDirArr,1)
        end
        local avg = sm.vec3.new(0,0,0)
        for _,x in pairs(self.droneCameraDirArr) do
            avg = avg + x
        end
        avg = avg/self.droneCamDirSmoothness
        local dist =(avg - self.droneCameraDir):length2()
        --print("dirdist",dist)
        self.droneCameraDir = avg

    end
end

function CameraManager.cl_calculateHoodPos(self,racer)
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    local racerShape = self.trackedRacer.shape
    local carDir = racerShape:getAt()
    local carUp = racerShape:getUp() -- Use the 'Up' vector for vertical offset
    local centerPosition = racerShape:getWorldPosition()
    local rearLength = (self.trackedRacer.carDimensions and self.trackedRacer.carDimensions['rear']:length() * 0.3) or 0
    local targetRearLoc = centerPosition + (carDir * -rearLength) -- A point behind the center
    local newHoodPos = targetRearLoc + (carUp * 2) -- 3 units above the rear point (dynamic height)
    return newHoodPos
end

function CameraManager.cl_resetOnboardArrays(self)
    self.onboardCameraPosArr = {} -- Clear the history!
    self.onboardCameraDirArr = {} -- Also clear the direction history -- Transfer this to hood Direction too
    self.currentTrackedRacerId = currentRacerId
    -- Fill the array with the starting position to prevent lag/jump
    if self.trackedRacer then
        local startLocation = self:cl_calculateHoodPos(self.trackedRacer)
        for i=1, self.onboardCamPosSmooth do
            table.insert(self.onboardCameraPosArr, startLocation)
        end
        local racerShape = self.trackedRacer.shape
        local carDir = racerShape:getAt()
        if carDir == nil then
            return
        end
        for i=1, self.onboardCamDirSmooth do
            table.insert(self.onboardCameraDirArr, carDir)
        end
    end

end

function CameraManager.cl_updateOnboardCamPosition(self,dt)
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    local currentRacerId = self.trackedRacer and self.trackedRacer.id or nil
    if currentRacerId ~= self.currentTrackedRacerId then
       self:cl_resetOnboardArrays()
    end
    if self.trackedRacer then -- also use trackedRacer??
        -- 1. Calculate Target Position (Positioning the camera behind the racer) todo: front instead?
        local newHoodPos = self:cl_calculateHoodPos(self.trackedRacer)
        if newHoodPos == nil then -- Move to velocity??
            newHoodPos = self.onboardCameraPosArr[#self.onboardCameraPosArr]
        end
        table.insert(self.onboardCameraPosArr,newHoodPos)

        if #self.onboardCameraPosArr > self.onboardCamPosSmooth then
            table.remove(self.onboardCameraPosArr,1)
        end
        local avg = sm.vec3.new(0,0,0)
        for _,x in pairs(self.onboardCameraPosArr) do
            --print(x)
            avg = avg + x
        end
        avg = avg/self.onboardCamPosSmooth
        self.onboardCameraPos = avg-- directly pull this value onUpdate
    else -- todo get correlation between current camera pos and next avg and dt to detect lag spikes/camera jumps, anomalies, etc
        --use a default car? go to frozen?
    end

end

function CameraManager.cl_updateOnboardCamDirection(self,dt)
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    if self.trackedRacer then -- also use trackedRacer??
        local racerShape = self.trackedRacer.shape
        local carDir = racerShape:getAt()
        if carDir == nil then -- Move to velocity??
            carDir = self.onboardCameraDirArr[#self.onboardCameraDirArr]
        end
        table.insert(self.onboardCameraDirArr,carDir)

        if #self.onboardCameraDirArr > self.onboardCamDirSmooth then
            table.remove(self.onboardCameraDirArr,1)
        end
        local avg = sm.vec3.new(0,0,0)
        for _,x in pairs(self.onboardCameraDirArr) do
            --print(x)
            avg = avg + x
        end
        avg = avg/self.onboardCamDirSmooth
        self.onboardCameraDir = avg-- directly pull this value onUpdate
    else -- todo get distance between camPos, next avg  and DT to determine lag spikes/camera jumps
        -- TODO: Have the drone follow the nodeChain in RC
    end
end

function CameraManager.cl_getCamerasClose(self,position) -- returns cameras nearest to position (client)
    local all_cameras = getAllCameras()
    if all_cameras == nil or #all_cameras == 0 then
		return {}
	end
    local sortedCameras = {}
    --print("gcc",position)
    for k=1, #all_cameras do local v=all_cameras[k]-- Foreach camera, set their individual focus/power
		local dis = getDistance(position,v.location)
        table.insert(sortedCameras,{camera=v,distance=dis})
    end
    sortedCameras = sortCamerasByDistance(sortedCameras)
    return sortedCameras
end

function CameraManager.cl_assignBestCam(self) -- Runs on fixed and constantly assigns best race cam for focused racers
    -- TODO: have default/fallback position if lacking cam or lacking trackedRacer
    
    local focusPos = self.trackingLocation -- Takes the final tracking location
    --print("got focusPos",focusPos)
    if focusPos == nil then return false end
    local camerasInDist = self:cl_getCamerasClose(focusPos)
    if not camerasInDist or #camerasInDist == 0 then
        --print("no cam in dist",camerasInDist)
        return false
    end

    local trackedCar = nil
    if #self.trackedRacers > 0 then 
        trackedCar = self.trackedRacers[1]
    else
        trackedCar = self.trackedRacer
    end

    if trackedCar == nil then
        --print('no tracked car',trackedCar)
        return false 
    end -- No cars tracked... ( need default cam?)

    local carNode = trackedCar.currentNode -- start looking ahead so camera chosen isnt behind the racer
    local nodeAhead = getNextItem(trackedCar.nodeChain, carNode.id, 7) -- Not sure why 7 ahead but we can experiment this
    local distAhead = math.abs( nodeAhead.id,carNode.id )
    -- If minNode is nil, we can't reliably check the camera's position relative to the car's path
    if not nodeAhead then -- Fallback is either return nothing or use closest cam anyways
        --print("No node ahead")
        return false -- so far just returning false/fail
    end

    -- 3. Find the Best Camera closest to the node ahead's location
    local chosenCamData = camerasInDist[1] -- Start with the closest camera as the default best
    local foundAdvancedCam = false
    
    for _, camData in ipairs(camerasInDist) do 
        local camera = camData.camera
        local closestNode = camera.nearestNode
        --print("checking",_,closestNode.id,nodeAhead.id,get_los(camera, trackedCar))
        -- Use the 'or' operator to prioritize the race cam mode if logic fails
        if closestNode and nodeAhead and closestNode.id >= nodeAhead.id and get_los(camera, trackedCar) and distAhead < 35 then 
            chosenCamData = camData
            foundAdvancedCam = true
            break -- Found a suitable advanced camera, stop searching
        end
    end
    
    -- Change the final fallback to be safer:
    local distanceCutoff = 200 
    local distFromCamera = chosenCamData.distance
    local chosenCamera = chosenCamData.camera

    if distFromCamera > distanceCutoff or not foundAdvancedCam then
        -- Return nil to signal that the Drone Cam is a better choice
        self.chosenRaceCam = nil
       --print("racer too far or no camera found",foundAdvancedCam,distFromCamera,distanceCutoff)
        return false 
    else
        self.chosenRaceCam = chosenCamera 
        return true
    end
    --todo: only if different cam index than before, reset dir array
    self.raceCameraDirArr = {}
end

function CameraManager.cl_updateRaceCameraPosition(self,dt) -- onupdate here to keep consistency...
    if self.chosenRaceCam then
        self.raceCameraPos = self.chosenRaceCam.location
    end
end

function CameraManager.cl_updateRaceCameraRotation(self,dt)
    if self.trackingLocation then -- doesnt need focused racer? can just be "static",
        local targetPos = self.trackingLocation   -- Get target position (Racer)
        local lookVector = (targetPos - self.raceCameraPos):normalize()
        if lookVector:length2() < 0.0001 then
            return
        end
        -- 2. Create the Goal Quaternion from the Look Vector
        -- sm.quat.lookRotation() converts a direction vector into a quaternion rotation. Documentation says depreciated
        -- may need to avg these like in position calcs to smooth frames
        local goalQuat = sm.quat.lookRotation(lookVector, self.WorldUpVector)
        local currentQuat = sm.camera.getRotation()
        local smoothedQuat = sm.quat.slerp(currentQuat, goalQuat, self.raceTrackingRate)
        self.raceCameraRot = smoothedQuat
    end
end

function CameraManager.cl_updateRaceCameraDirection(self,dt) -- caled  onupdate for smooth mov
    if self.trackingLocation then
        local nextGoalDirection = (self.trackingLocation - self.raceCameraPos):normalize()
        if nextGoalDirection == nil then --or distance big jump?? how to transiion to new camera?
            nextGoalDirection = self.raceCameraDirArr[#self.raceCameraDirArr]
        end
        table.insert(self.raceCameraDirArr,nextGoalDirection)

        if #self.raceCameraDirArr > self.raceCamDirSmooth then
            table.remove(self.raceCameraDirArr,1)
        end
        local avg = sm.vec3.new(0,0,0)
        for _,x in pairs(self.raceCameraDirArr) do
            avg = avg + x
        end
        avg = avg/self.raceCamDirSmooth
        self.raceCameraDir = avg-- directly pull this value onUpdate
    else -- detect lag spikes like in others
        -- TODO: have static camera facing towards nearestnode
    end
end

--- race events:
--- -- Helper function to find the closest active battle
function CameraManager.findClosestBattle(self, racers, battleThreshold)
    local minDistance = battleThreshold 
    local battleCars = nil

    -- 1. Iterate through all pairs of racers
    for i, racerA in ipairs(racers) do
        for j, racerB in ipairs(racers) do
            if i < j then -- Check each unique pair once
                -- 2. Calculate the distance between them (using length2 is faster)
                local distanceSq = (racerA.location - racerB.location):length2()
                
                -- 3. Check if they are in a battle zone and it's the closest battle found so far
                if distanceSq < (battleThreshold * battleThreshold) and distanceSq < minDistance then
                    minDistance = distanceSq
                    battleCars = {racerA, racerB}
                end
            end
        end
    end
    
    -- Returns the two cars in the closest battle, or nil if no close battles were found
    return battleCars 
end

function CameraManager.build_all_drivers(self) -- Builds a set of proper driver location no matter which gen
    -- not really needed


end

function CameraManager.cl_decideCameraAndFocus(self) -- Runs onfixed after cameraHold Timer runs out
    -- Highest Priority: Check for a close battle
    local racers = getAllDrivers()
    local battleCars = self:findClosestBattle(racers, 15) -- 15m threshold
    -- Delay types
    if battleCars then
        --print("battleCars")
        -- Priority 1: Focus on the closest battle
        self:setCameraMode(CAMERA_MODES.DRONE_CAM)
        self.trackedRacers = {} --reset tracked 
        self.trackedRacer = battleCars[1]
        self:addTrackedRacer(battleCars[1])
        self:addTrackedRacer(battleCars[2])
        self.trackingBias = 0.5
        self.cameraHoldTimer:start(8.0)  -- TODO: Implement Timer()
        return
    end

    -- Car camera points ( shortcut until we detect events better)
    local sorted_drivers = getDriversByCameraPoints() -- ranks each car by how interesting their situation is (cars around, crashing, etc)
    if sorted_drivers ~= nil and #sorted_drivers > 1 then  
        local firstDriver = getDriverFromId(sorted_drivers[1].driver)
        -- check if driver???
        self.trackedRacers = {}
        self.trackedRacer = firstDriver
        self:addTrackedRacer(firstDriver) -- Maybe do top two or 3?
        local mode = self:getRandomCamMode({CAMERA_MODES.DRONE_CAM,CAMERA_MODES.RACE_CAM,CAMERA_MODES.ONBOARD_CAM}) -- gets random cam mode until better event detection
        if mode == CAMERA_MODES.RACE_CAM then -- Double check that works, if not then go Drone
            local result = self:cl_assignBestCam()
            if not result then -- fallback to drrone camera
                self:setCameraMode(CAMERA_MODES.DRONE_CAM)
                self.cameraHoldTimer:start(5)
                return
            else
                self:setCameraMode(mode)
                self.cameraHoldTimer:start(7)
                return
            end
        end
        self:setCameraMode(mode)
        self.cameraHoldTimer:start(8)
        return
    end

    -- --- PRIORITY 3: Default Tracking (Follow the Leader) ---
    local DEFAULT_HOLD_TIME = 5.0 -- seconds
    local raceLeader = getDriverByPos(1) -- Assumed function to get the current leader

    if raceLeader then
        self.trackedRacers = {}
        self.trackedRacer = raceLeader
        self:addTrackedRacer(raceLeader)
        self.trackingBias = 0.7

        -- Default to Drone Cam when nothing else is happening
        self:setCameraMode(CAMERA_MODES.DRONE_CAM) 
        self.cameraHoldTimer:start(DEFAULT_HOLD_TIME)
        return
    end

    -- --- PRIORITY 4: Idle/Fallback (No Leader, No Data) ---
    self.droneCameraPos = sm.vec3.new(0,0,50)
    self.trackingLocation = sm.vec3.new(0,0,5)
    --self:exitCamera() -- Release control (or set to a known safe view)
    self.cameraHoldTimer:start(3.0) -- Check again soon
end

function CameraManager.getRandomCamMode(self,camModeList)
    local index = math.random(1,#camModeList)
    return camModeList[index]
end

function CameraManager.cl_setZoom(self,ammount) -- zooms the camerea ( Not implemented/finished yet)
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
	if self.fovValue < 28 then --?
		self.fovValue = 10
	
	end
	if self.fovValue > 80 then 
		self.fovValue = 80
		
	end
end


function CameraManager.cl_ms_tick(self) -- frame tick
    self:sv_performTimedFuncts()
    self.recentSwitchTimer:tick()

end

function CameraManager.cl_tickClock(self) -- second tick
    local floorCheck = math.floor(clock() - self.started) 
        --print(floorCheck,self.globalTimer)
    if self.globalTimer ~= floorCheck then -- one second passed
        self.gotTick = true
        self.globalTimer = floorCheck
        self.cameraHoldTimer:tick()
        
    else
        self.gotTick = false
        self.globalTimer = floorCheck
    end
            
end

function CameraManager.sv_performTimedFuncts(self) -- here for timed functions

end
