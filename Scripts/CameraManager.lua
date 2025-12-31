-- Camera manager that handles all of camera switching and movement and automation (formerly in race control)
-- Imported as a class in Race control and is ran from onfixed and etc. 
-- Goals: Handles automated Camera switching and focusing on cars. acts as an automated race director

dofile("globals.lua")
dofile "Timer.lua" 
CameraManager = class( nil )
local clock = os.clock --global clock

-- Helper function to sort cameras
function sortCamerasByDistance(cameraList)
    table.sort(cameraList, function(a, b) return a.distance < b.distance end)
    return cameraList
end

function CameraManager.client_onCreate( self ) 
	self:client_init()
end

function CameraManager.client_onDestroy(self)
    print("Camera manager destroy")
    self.trackedRacer = nil
    self.trackedRacers = {}
    self:exitCamera()
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
    self.droneOffset = sm.vec3.new(0, 0, 15) -- Default drone height/offset
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
        --print("changing cam mode",mode)
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
        -- [FIX] Robust Location Check: Try .location -> shape -> body
        local carPos = self.trackedRacer.location 
        if not carPos and self.trackedRacer.shape then carPos = self.trackedRacer.shape:getWorldPosition() end
        if not carPos and self.trackedRacer.body then carPos = self.trackedRacer.body:getWorldPosition() end
        
        -- Only proceed if we found a valid position
        if carPos and self.raceControl and self.raceControl.droneOffset then
            local nextLocation = carPos + self.raceControl.droneOffset
            for i=1, self.droneCamSmoothness do 
                table.insert(self.droneCameraArr, nextLocation)
            end
            
            local droneCameraPos = nextLocation 
            local targetPos = self.trackingLocation or carPos -- Fallback to carPos if tracking is nil
            
            local lookDirection = (targetPos - droneCameraPos):normalize()
            if lookDirection ~= nil then
                for i=1, self.droneCamDirSmoothness do 
                    table.insert(self.droneCameraDirArr, lookDirection)
                end
            end
        end
    end
end

function CameraManager.cl_updateDroneCamPosition(self,dt) 
    -- check if tracked racer exists
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    local currentRacerId = self.trackedRacer and self.trackedRacer.id or nil
    
    -- [FIX] LOCAL HELPER: Robust Position Getter
    -- This prevents the 'perceptionData is nil' crash by avoiding server-only data
    local function getRacerPos(racer)
        if not racer then return nil end
        if racer.location then return racer.location end
        if racer.shape then return racer.shape:getWorldPosition() end
        if racer.body then return racer.body:getWorldPosition() end
        return nil
    end

    if currentRacerId ~= self.currentTrackedRacerId then -- Switching to new racer
        local lastPosition = self.droneCameraPos
        local racerPos = getRacerPos(self.trackedRacer)
        
        if racerPos then
            -- [FIX] Apply offset logic correctly
            local nextLocation = racerPos + self.raceControl.droneOffset
            local dist = (lastPosition-nextLocation):length2()
            if self.currentCameraMode ~= CAMERA_MODES.DRONE_CAM then 
                self:cl_resetDroneArrays()
            end
        end
        self.currentTrackedRacerId = currentRacerId
    end
    
    -- Get list of racers in top 10
    local top10Drivers = getDriversAbovePos(10)
    local avgPos = sm.vec3.new(0,0,0)
    local count = 0
    
    for _,racer in pairs(top10Drivers) do 
        -- [FIX] Use local helper instead of accessing perceptionData
        local rPos = getRacerPos(racer)
        if rPos then 
            avgPos = avgPos + rPos
            count = count + 1
        end
    end
    
    if count > 0 then
        avgPos = avgPos / count -- Average position
        
        local nextLocation = avgPos + self.raceControl.droneOffset
        if nextLocation == nil then 
            -- Fallback to last known if somehow nil
            nextLocation = self.droneCameraArr[#self.droneCameraArr] + self.raceControl.droneOffset 
        end
        
        table.insert(self.droneCameraArr, nextLocation)

        if #self.droneCameraArr > self.droneCamSmoothness then
            table.remove(self.droneCameraArr, 1)
        end
        
        local avg = sm.vec3.new(0,0,0)
        for _,x in pairs(self.droneCameraArr) do
            avg = avg + x
        end
        avg = avg / self.droneCamSmoothness
        self.droneCameraPos = avg
    else 
        -- Fallback if no group average possible
        local racerPos = getRacerPos(self.trackedRacer)
        if racerPos then
             self.droneCameraPos = racerPos + self.raceControl.droneOffset
        end
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
        -- sm.quat.lookRotation() converts a direction vector into a quaternion rotation. Documentation says depreciated
        -- may need to avg these like in position calcs to smooth frames
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
    -- [FIX 1/3] Guard against nil shape (e.g. car destroyed or not streamed in)
    if not racerShape or not sm.exists(racerShape) then return nil end

    local carDir = racerShape:getAt()
    local carUp = racerShape:getUp() -- Use the 'Up' vector for vertical offset
    local centerPosition = racerShape:getWorldPosition()
    local rearLength = 1.0 -- Default safe value
    if self.trackedRacer.carDimensions and self.trackedRacer.carDimensions['rear'] then
        rearLength = self.trackedRacer.carDimensions['rear']:length() * 0.3
    end
    local targetRearLoc = centerPosition + (carDir * -rearLength) -- A point behind the center
    local newHoodPos = targetRearLoc + (carUp * 2) -- 3 units above the rear point (dynamic height)
    return newHoodPos
end

function CameraManager.cl_resetOnboardArrays(self)
    self.onboardCameraPosArr = {} -- Clear the history!
    self.onboardCameraDirArr = {} -- Also clear the direction history -- Transfer this to hood Direction too
    
    -- FIXED: Define currentRacerId from the current racer object
    local currentRacerId = self.trackedRacer and self.trackedRacer.id
    self.currentTrackedRacerId = currentRacerId
    
    -- Fill the array with the starting position to prevent lag/jump
    if self.trackedRacer then
        local startLocation = self:cl_calculateHoodPos(self.trackedRacer)
        if startLocation then -- Guard against nil start pos
            for i=1, self.onboardCamPosSmooth do
                table.insert(self.onboardCameraPosArr, startLocation)
            end
        end

        local racerShape = self.trackedRacer.shape
        -- [FIX 2/3] Robust Check for Reset
        if not racerShape or not sm.exists(racerShape) then return end
        
        local carDir = racerShape:getAt()
        if carDir == nil then return end
        
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
        
        -- Guard against nil newHoodPos if array is empty (first frame error)
        if newHoodPos then 
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
        end
    else 
        -- use a default car? go to frozen?
    end

end

function CameraManager.cl_updateOnboardCamDirection(self,dt)
    if self.trackedRacer == nil or getDriverFromId(self.trackedRacer.id) == nil then return end

    if self.trackedRacer then -- also use trackedRacer??
        local racerShape = self.trackedRacer.shape
        local carDir = nil
        
        -- [FIX 3/3] Robust Check for Update Direction
        if racerShape and sm.exists(racerShape) then
            carDir = racerShape:getAt()
        end
        
        if carDir == nil then -- Fallback to history or default
            if #self.onboardCameraDirArr > 0 then
                carDir = self.onboardCameraDirArr[#self.onboardCameraDirArr]
            else
                carDir = sm.vec3.new(0, 1, 0) -- Safe Default
            end
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

    -- [FIX] Define helper function to get location safely
    local function getRacerPos(racer)
        if not racer then return nil end
        if racer.location then return racer.location end
        if racer.shape and sm.exists(racer.shape) then return racer.shape:getWorldPosition() end
        if racer.body then return racer.body:getWorldPosition() end
        return nil
    end

    -- 1. Iterate through all pairs of racers
    for i, racerA in ipairs(racers) do
        for j, racerB in ipairs(racers) do
            if i < j then -- Check each unique pair once
                -- 2. Calculate the distance between them (using length2 is faster)
                -- [FIX] Use safe getter, do not access perceptionData
                local racerALoc = getRacerPos(racerA)
                local racerBLoc = getRacerPos(racerB)
                
                if racerALoc and racerBLoc then
                    local distanceSq = (racerALoc - racerBLoc):length2()
                    
                    -- 3. Check if they are in a battle zone and it's the closest battle found so far
                    if distanceSq < (battleThreshold * battleThreshold) and distanceSq < minDistance then
                        minDistance = distanceSq
                        battleCars = {racerA, racerB}
                    end
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
    local racers = getAllDrivers()
    
    -- [[ FIX 1: IMMEDIATE FAIL-SAFE ]]
    -- If there are no drivers at all, force Idle immediately to break the loop
    if not racers or #racers == 0 then
        self.trackedRacer = nil
        self.trackedRacers = {}
        
        -- Force Drone Cam (Safe default that doesn't rely on car position)
        self:setCameraMode(CAMERA_MODES.DRONE_CAM)
        self.droneCameraPos = sm.vec3.new(0,0,50)
        self.trackingLocation = sm.vec3.new(0,0,5)
        
        self.cameraHoldTimer:start(2.0) -- Wait 2 seconds before checking again
        return
    end

    -- Highest Priority: Check for a close battle
    local battleCars = self:findClosestBattle(racers, 15) -- 15m threshold
    
    if battleCars then
        -- Priority 1: Focus on the closest battle
        self:setCameraMode(CAMERA_MODES.DRONE_CAM)
        self.trackedRacers = {} 
        self.trackedRacer = battleCars[1]
        self:addTrackedRacer(battleCars[1])
        self:addTrackedRacer(battleCars[2])
        self.trackingBias = 0.5
        self.cameraHoldTimer:start(8.0)
        return
    end

    -- Priority 2: Car camera points
    local sorted_drivers = getDriversByCameraPoints() 
    
    -- [[ FIX 2: VALIDATION CHECK ]]
    -- Ensure the driver actually exists before trying to track them
    if sorted_drivers ~= nil and #sorted_drivers > 0 then  
        local firstDriver = getDriverFromId(sorted_drivers[1].driver)
        
        if firstDriver and sm.exists(firstDriver.shape) then
            self.trackedRacers = {}
            self.trackedRacer = firstDriver
            self:addTrackedRacer(firstDriver) 

            local mode = self:getRandomCamMode({CAMERA_MODES.DRONE_CAM,CAMERA_MODES.RACE_CAM,CAMERA_MODES.ONBOARD_CAM})
            
            if mode == CAMERA_MODES.RACE_CAM then 
                local result = self:cl_assignBestCam()
                if not result then 
                    self:cl_resetDroneArrays()
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
    end

    -- --- PRIORITY 3: Default Tracking (Follow the Leader) ---
    local DEFAULT_HOLD_TIME = 5.0 
    local raceLeader = getDriverByPos(1) 

    if raceLeader and sm.exists(raceLeader.shape) then
        self.trackedRacers = {}
        self.trackedRacer = raceLeader
        self:addTrackedRacer(raceLeader)
        self.trackingBias = 0.7

        self:setCameraMode(CAMERA_MODES.DRONE_CAM) 
        self.cameraHoldTimer:start(DEFAULT_HOLD_TIME)
        return
    end

    -- --- PRIORITY 4: Idle/Fallback (No Leader, No Data) ---
    -- [[ FIX 3: CLEANUP ]]
    -- Clear the tracked variables so cl_ms_tick doesn't panic
    self.trackedRacer = nil
    self.trackedRacers = {}
    
    self:setCameraMode(CAMERA_MODES.DRONE_CAM) -- Force a mode so we don't get stuck in Onboard
    self.droneCameraPos = sm.vec3.new(0,0,50)
    self.trackingLocation = sm.vec3.new(0,0,5)
    
    self.cameraHoldTimer:start(3.0) 
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

    -- [[ FIX: PRUNE ZOMBIE RACERS ]]
    -- Remove any tracked racers that no longer exist physically
    if self.trackedRacers then
        for i = #self.trackedRacers, 1, -1 do
            local racer = self.trackedRacers[i]
            -- Check if Shape exists
            if not racer or not racer.shape or not sm.exists(racer.shape) then
                table.remove(self.trackedRacers, i)
            end
        end
        
        -- If we lost our primary target, trigger a re-decision immediately
        if #self.trackedRacers == 0 and self.trackedRacer then
            self.trackedRacer = nil
            self.cameraHoldTimer:start(0) -- Force new camera choice next tick
        end
    end
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