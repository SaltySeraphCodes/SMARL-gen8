-- SMARL Gen 8 Globals & Utilities
-- Foundation file for the SM Auto Racers Mod (SMARL)

CLOCK = os.clock

-- --- CONSTANTS ---
SMAR_VERSION = "2.0.0 (Gen 8)"
MOD_FOLDER = "$CONTENT_DATA/"

-- IDs
DRIVER_UUID = "fbc31377-6081-426d-b518-f676840c407c"
DRIVER_GEN8_UUID = "a6e9d911-f86f-4292-af3c-7694049eef43"
ENGINE_GEN8_UUID = "e7d83a24-c998-43fe-9690-1575c38c89f6"
DOWNFORCE_BLOCK_UUID = "1e3b7ff3-d066-4b8b-9cb1-fa4a6ad8cc7c"

-- Paths
TRACK_DATA_CHANNEL = "SM_AutoRacers_TrackData"
OUTPUT_DATA = "$CONTENT_DATA/SMARL_Manager/JsonData/RaceOutput/raceData.json"
MAP_DATA_PATH = "$CONTENT_DATA/SMARL_Manager/JsonData/TrackData/current_map.json"
RACER_DATA_PATH = "$CONTENT_DATA/SMARL_Manager/JsonData/RacerData/"
TWITCH_BLUEPRINTS_PATH = "$CONTENT_DATA/SMARL_Manager/TwitchPlays/Blueprints/"
TUNING_PROFILES ="$CONTENT_DATA/SMARL_Manager/JsonData/tuning_profiles.json"
-- Physics Defaults
DEFAULT_GRAVITY = 10
DEFAULT_FRICTION = 0.0006
VELOCITY_ROTATION_RATE = 0.37
DECELERATION_RATE = -11.3 
FORCE_SENSITIVIY = 4

-- [[ FEATURE FLAGS ]]
-- [[ FEATURE FLAGS ]]
ENABLE_TORQUE_VECTORING = false -- [FIX] Disabled for stability debugging
TV_INTENSITY = 1.0 -- 0.0 to 2.0 (Strength of Virtual Torque Vectoring)
ENABLE_ESC = true
ESC_INTENSITY = 0.5 -- 0.0 to 1.0 (Strength of counter-steer/braking)
STEERING_INVERTED = false -- [FIX] Disable inversion to test native mapping again
ENABLE_ESC = true
ESC_INTENSITY = 0.5 -- 0.0 to 1.0 (Strength of counter-steer/braking)
TELEMETRY_DEBUG = false -- Toggle to show "Ideal vs Actual" headings

-- --- GLOBAL STATE ---
ALL_DRIVERS = {} 
ALL_CAMERAS = {}
RACE_CONTROL = nil 
TWITCH_CONNECTIONS = {}
sm.SMARGlobals = { LOAD_CAMERA = true, SMAR_CAM = -1 }

-- NEW: Pit Anchors Registry for Scanning
PIT_ANCHORS = {
    start = nil,    -- Type 1 (Pit Begin)
    entry = nil,    -- Type 2 (Pit Entrance)
    exit = nil,     -- Type 3 (Pit Exit)
    endPoint = nil, -- Type 4 (Pit End)
    boxes = {}      -- List of PitBox objects
}

-- --- ENUMS / TYPES ---

PIT_CHAIN_CONFIG = {
    editing = 0,
    boxEdit = 0,
    hasChange = false,
    wallPad = 6,
    tension = 0.8,
    nodes = 7,
    spacing = 2, 
    pos_arr = {}, 
    shape_arr = {}, 
    pbox_arr = {}, 
    boxDim_arr = {} 
}

CHECK_POINT_CONFIG = { 
    editing = 0,
    hasChange = false,
    wallPad = 7,
    tension = 0.4,
    nodes = 10,
    spacing = 2, 
    pos_arr = {}, 
    shape_arr = {}, 
}

CAMERA_MODES = { RACE_CAM = 0, DRONE_CAM = 1, FREE_CAM = 2, ONBOARD_CAM = 3, FINISH_CAM = 4 }
ZOOM_METHODS = { IN = 0, OUT = 1, STAY = 2 }

WHEEL_DB = {
    ["69e362c3-32aa-4cd1-adc0-dcfc47b92c0d"] = "SML", -- Small Wheel
    ["db66f0b1-0c50-4b74-bdc7-771374204b1f"] = "LRG", -- Large Wheel
    -- Add generic/mod fallback or specific mod UUIDs here
}

function getWheelCode(uuidString)
    return WHEEL_DB[uuidString] or "UNK" -- Returns "UNK" for unknown/modded wheels
end


TIRE_TYPES = { 
    [1] = { TYPE = "soft", DECAY = 0.4, GRIP = 1.0, MAX_SLIP_FACTOR = 1.5 },
    [2] = { TYPE = "medium", DECAY = 0.2, GRIP = 0.8, MAX_SLIP_FACTOR = 1.0 },
    [3] = { TYPE = "hard", DECAY = 0.1, GRIP = 0.6, MAX_SLIP_FACTOR = 0.5 }
}

ENGINE_TYPES = {
   { TYPE = "road", COLOR = "222222ff", MAX_SPEED = 90, MAX_ACCEL = 1, MAX_BRAKE = 0.80, GEARING = {0.45,0.35,0.21,0.17,0.15} },
   { TYPE = "sports", COLOR = "4a4a4aff", MAX_SPEED = 110, MAX_ACCEL = 1, MAX_BRAKE = 0.80, GEARING = {0.55,0.46,0.23,0.18,0.18} },
   { TYPE = "formula", COLOR = "7f7f7fff", MAX_SPEED = 150, MAX_ACCEL = 1, MAX_BRAKE = 0.80, GEARING = {0.60,0.48,0.25,0.20,0.19} },
   { TYPE = "insane", COLOR = "eeeeeeff", MAX_SPEED = 250, MAX_ACCEL = 1, MAX_BRAKE = 0.80, GEARING = {0.50,0.4,0.30,0.21,0.20} },
   { TYPE = "custom", COLOR = "aaaa2f", MAX_SPEED = 250, MAX_ACCEL = 1, MAX_BRAKE = 0.80, GEARING = {0.48,0.45,0.50,0.5,0.15} }
}

-- --- HELPER FUNCTIONS ---

function mathClamp(min, max, value)
    return math.min(math.max(value, min), max)
end

function round(value)
    return math.floor(value + 0.5)
end

function getSign(x)
    return x > 0 and 1 or (x < 0 and -1 or 0)
end

function ratioConversion(a, b, c, d, x)
    if math.abs(b - a) < 0.0001 then return c end
    return c + (d - c) * (x - a) / (b - a)
end

function getDistance(vec1, vec2)
    return (vec2 - vec1):length()
end

function getDistanceSq(vec1, vec2)
    return (vec2 - vec1):length2()
end

function getMidpoint(locA, locB)
    return (locA + locB) * 0.5
end

function getNormalVectorFromPoints(p1, p2)
    return (p2 - p1):normalize()
end

function generatePerpVector(direction)
    if not direction then return sm.vec3.new(1,0,0) end
    return sm.vec3.new(direction.y, -direction.x, 0)
end

function vectorToDegrees(vector)
    return math.deg(math.atan2(vector.y, vector.x))
end

function angleDiff(vector1, vector2)
    local directionalCross = vector1:cross(vector2)
    return directionalCross.z * FORCE_SENSITIVIY
end

function getRotationIndexFromVector(vector,precision) 
	if vector.y >precision then return 3 end
	if vector.x > precision then return 2 end
	if vector.y < -precision then return 1 end
	if vector.x < -precision then return 0 end
	return -1
end

-- --- ACCESSORS ---

function getRaceControl() return RACE_CONTROL end
function getAllDrivers() return ALL_DRIVERS end
function getAllCameras() return ALL_CAMERAS end
function getSmarCam() return sm.SMARGlobals.SMAR_CAM end
function setSmarCam(cam) sm.SMARGlobals.SMAR_CAM = cam end

function getDriverFromId(id)
    for _, driver in ipairs(ALL_DRIVERS) do
        if driver.id == id then return driver end
    end
    return nil
end

function getDriverFromMetaId(id)
    local search_id_str = tostring(id)
    local search_id_num = tonumber(search_id_str)
    for _, v in ipairs(ALL_DRIVERS) do
        if search_id_num and v.metaData and (search_id_num == v.metaData.ID) then return v end
        if v.metaData and (search_id_str == tostring(v.metaData.ID)) then return v end
        if v.twitchCar and v.twitchData and search_id_str == v.twitchData.uid then return v end
    end
    return nil
end


function getDriversByCameraPoints() -- grabs drivers sorted by points
    local driverArr = {}
    for k=1, #ALL_DRIVERS do local driver=ALL_DRIVERS[k]
		local camPoints = driver.cameraPoints
        if driver ~= nil then
            --print("inserting driver",driver.id,camPoints)
            table.insert(driverArr,{driver=driver.id,points=camPoints})
        end
	end
    local outputArr = sortRacersByCameraPoints(driverArr)
    return outputArr
end

function getDriverByPos(racePos)
    for _, v in ipairs(ALL_DRIVERS) do
        if v.racePosition == racePos then return v end
    end
    return nil
end

function getDriversAbovePos(racePos)
    local selected = {}
    for _, v in ipairs(ALL_DRIVERS) do
        if v.racePosition <= racePos then table.insert(selected, v) end
    end
    return selected
end

function getLapsLeft()
    local leader = getDriverByPos(1)
    if leader and getRaceControl() then
        return getRaceControl().RaceManager.targetLaps - leader.currentLap
    end
    return 0
end

function getNextItem(chain, currentId, offset)
    if not chain or #chain == 0 then return nil end
    offset = offset or 1
    local currentIndex = currentId 
    if chain[currentIndex] == nil or chain[currentIndex].id ~= currentId then
         for i, node in ipairs(chain) do
             if node.id == currentId then currentIndex = i break end
         end
    end
    local chainLength = #chain
    local newIndex = ((currentIndex + offset - 1) % chainLength) + 1 
    return chain[newIndex]
end

-- --- TABLE UTILS ---

function shallowcopy(orig)
    local copy = {}
    for k, v in pairs(orig) do copy[k] = v end
    return copy
end

function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

function findKeyValue(table,key,value)
    for i=1 ,#table do 
        if table[i][key] == value then return true end
    end
    return false
end

function getKeyValue(table,key,value)
    for i=1 ,#table do 
        if table[i][key] == value then return table[i] end
    end
    return false
end

function getIndexKeyValue(table, key, value)
    for i = 1, #table do
        if table[i] and table[i][key] == value then
            return i
        end
    end
    return nil
end

function getDirectionOffset(shapeList,direction,origin)
    local furthest = nil
    local dir = {"x",1}
    if direction.x == 0 then dir = {"y",direction.y}
    elseif direction.y == 0 then dir = {'x',direction.x} end
    
    for k=1, #shapeList do local shape=shapeList[k]
        local curLocation = shape.worldPosition
        if furthest == nil or (curLocation[dir[1]] - furthest.worldPosition[dir[1]]) * dir[2] > 0 then
          furthest = shape
        end
    end
    local offset = furthest.worldPosition - origin
    offset.z = 0 
    if direction.x == 0 then offset.x = 0
    elseif direction.y == 0 then offset.y = 0 end
    return offset
end




-- Helpers
function get_los(camera, driver)
    if not camera or not driver or not driver.shape or not sm.exists(driver.shape) then 
        return false 
    end
    -- Simple raycast from camera to car
    local camPos = camera.location
    local carPos = driver.shape:getWorldPosition()
    local dir = carPos - camPos
    local dist = dir:length()
    
    -- Check if we hit anything static (terrain/walls) before the car
    local valid, result = sm.physics.raycast(camPos, camPos + dir)
    if valid and result.type ~= "Body" and result.fraction < 0.95 then
        return false -- View blocked by terrain or static object
    end
    return true
end

-- Sorting ---
function sortRacersByRacePos(inTable)
    table.sort(inTable, racePosCompare)
	return inTable
end

function sortRacersByCameraPoints(inTable)
    table.sort(inTable,cameraPointCompare)
    return inTable
end

function sortCamerasByDistance(inTable)
    table.sort(inTable,camerasDistanceCompare)
    return inTable
end


function racerIDCompare(a,b)
	return a['id'] < b['id']
end 

function racePosCompare(a,b)
	return a['racePosition'] < b['racePosition']
end 

function cameraPointCompare(a,b) -- sort so biggest is first
    local pA = a['points'] or 0
    local pB = b['points'] or 0
    return pA > pB
end

function camerasDistanceCompare(a,b)
    return a['distance'] < b['distance']
end

-- --- ENGINE UTILS ---

function getEngineType(color)
    for _, v in ipairs(ENGINE_TYPES) do
        if color == v.COLOR then return v end
    end
    return ENGINE_TYPES[1]
end
-- End of Globals
EngineStats = class(nil)
function EngineStats.init(self,stats)
    self.TYPE = stats['TYPE']
    self.COLOR = stats['COLOR']
    self.MAX_SPEED = stats['MAX_SPEED']
    self.MAX_ACCEL = stats['MAX_ACCEL']
    self.MAX_BRAKE = stats['MAX_BRAKE']
    self.GEARING = shallowcopy(stats['GEARING']) 
    self.REV_LIMIT = self.MAX_SPEED / #self.GEARING
    return self
end 

-- --- CLIENT UTILITIES ---

function cl_checkHover(shape)
    local valid, result = sm.localPlayer.getRaycast(2.0) 
    if valid and result.type == "Shape" and result.shape == shape then
        return true
    end
    return false
end






print("Globals Loaded (Gen 8)")