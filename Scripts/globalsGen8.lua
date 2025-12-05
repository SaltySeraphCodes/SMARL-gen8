-- globals.lua
-- Foundation file for the SM Auto Racers Mod (SMARL)
-- Contains Class definitions, Constants, and Utility Functions.

-- --- 1. CORE UTILITIES ---

CLOCK = os.clock

-- Base Class Definition (Foundation for all modules)
class = function(base)
    local c = {}
    if base then
        setmetatable(c, {__index = base})
    end
    c.__index = c
    c.static = {}
    function c.new(...)
        local self = setmetatable({}, c)
        if self.init then
            self:init(...)
        end
        return self
    end
    function c.static:new(...)
        return c.new(...)
    end
    return c
end

-- --- 2. CONSTANTS & CONFIGURATION ---

SMAR_VERSION = "2.0.1" 
MOD_FOLDER = "$CONTENT_DATA/"

-- UUIDs
DRIVER_UUID = "fbc31377-6081-426d-b518-f676840c407c"
DRIVER_GEN8_UUID = "31256788-71fb-4003-a9ca-9e6164a8faa3"
ENGINE_GEN8_UUID = "74bfdcd7-cfb2-4791-9611-602154eb90dd"

-- File Paths
TWITCH_DATA = MOD_FOLDER .. "TwitchPlays/"
TWITCH_BLUEPRINTS = TWITCH_DATA .. "Blueprints/"
CHATTER_DATA = TWITCH_DATA .. "Json_Data/chatterData.json"
TRACK_DATA = 1 -- Storage Channel
PIT_DATA = 2   -- Storage Channel

-- Physics & Engine Defaults
MAX_SPEED = 200 -- Driver limit
MIN_SPEED = 10.0
ENGINE_SPEED_LIMIT = 1000 -- Hard limit
DEFAULT_GRAVITY = 10
DEFAULT_FRICTION = 0.0006046115371
VELOCITY_ROTATION_RATE = 0.37
DECELERATION_RATE = -11.3 

-- Control Defaults (PID)
STEERING_Kp = 1.0
STEERING_Kd = 0.01
SPEED_Kp = 0.2
SPEED_Kd = 0.05
MAX_WHEEL_ANGLE_RAD = 0.8
MAX_STEER_VALUE = 50

-- Track Generation
FORCE_SENSITIVIY = 4
FORCE_THRESHOLD = 0.01
WALL_PADDING = 6

-- --- 3. GLOBAL STATE CONTAINERS ---

ALL_DRIVERS = {} -- List of active Driver instances
ALL_CAMERAS = {} -- List of active Camera instances
RACE_CONTROL = nil -- Reference to the main RaceControl instance
TWITCH_CONNECTIONS = {} 
TEMP_TRACK_STORAGE = {} 
sm.SMARGlobals = {
    LOAD_CAMERA = true, 
    SMAR_CAM = -1
}

-- --- 4. LOOKUP TABLES (Enums) ---

CAMERA_MODES = {
    RACE_CAM = 0,
    DRONE_CAM = 1,
    FREE_CAM = 2,
    ONBOARD_CAM = 3,
    FINISH_CAM = 4,
}

ZOOM_METHODS = {
    IN  = 0,
    OUT = 1,
    STAY = 2,
}

TIRE_TYPES = { 
    [1] = { TYPE = "soft", DECAY = 0.4, GRIP = 1.0, MAX_SLIP_FACTOR = 1.5 },
    [2] = { TYPE = "medium", DECAY = 0.2, GRIP = 0.8, MAX_SLIP_FACTOR = 1.0 },
    [3] = { TYPE = "hard", DECAY = 0.1, GRIP = 0.6, MAX_SLIP_FACTOR = 0.5 }
}

SEGMENT_TYPES = {
    { TYPE = "Straight", THRESHOLD = {-1,1}, COLOR = "4DD306FF" },
    { TYPE = "Fast_Right", THRESHOLD = {1,3}, COLOR = "07FFECFF" },
    { TYPE = "Fast_Left", THRESHOLD = {-3,-1}, COLOR = "FF6755FF" },
    { TYPE = "Medium_Right", THRESHOLD = {3,6}, COLOR = "047FCAFF" },
    { TYPE = "Medium_Left", THRESHOLD = {-6,-3}, COLOR = "B80606FF" },
    { TYPE = "Slow_Right", THRESHOLD = {6,25}, COLOR = "0B0066FF" },
    { TYPE = "Slow_Left", THRESHOLD = {-25,-6}, COLOR = "660000FF" }
}

ENGINE_TYPES = {
   { TYPE = "road", COLOR = "222222ff", MAX_SPEED = 90, MAX_ACCEL = 0.5, MAX_BRAKE = 0.60, GEARING = {0.45,0.35,0.21,0.17,0.15} },
   { TYPE = "sports", COLOR = "4a4a4aff", MAX_SPEED = 110, MAX_ACCEL = 0.5, MAX_BRAKE = 0.75, GEARING = {0.55,0.46,0.23,0.18,0.18} },
   { TYPE = "formula", COLOR = "7f7f7fff", MAX_SPEED = 150, MAX_ACCEL = 0.7, MAX_BRAKE = 0.85, GEARING = {0.60,0.48,0.25,0.20,0.19} },
   { TYPE = "insane", COLOR = "eeeeeeff", MAX_SPEED = 250, MAX_ACCEL = 1, MAX_BRAKE = 0.90, GEARING = {0.50,0.4,0.30,0.21,0.20} },
   { TYPE = "custom", COLOR = "aaaa2f", MAX_SPEED = 250, MAX_ACCEL = 1, MAX_BRAKE = 0.85, GEARING = {0.48,0.45,0.50,0.5,0.15} }
}

PIT_POINT_TYPES = {
    { TYPE = 0, NAME = "Pit Path", COLOR = "aaaaffff" },
    { TYPE = 1, NAME = "Pit Begin", COLOR = "cbf66fff" },
    { TYPE = 2, NAME = "Pit Entrance", COLOR = "577d07ff" },
    { TYPE = 3, NAME = "Pit Exit", COLOR = "7c0000ff" },
    { TYPE = 4, NAME = "Pit End", COLOR = "f06767ff" }
}

-- Configuration Tables (Client Side mostly)
PIT_CHAIN_CONFIG = { editing = 0, boxEdit = 0, hasChange = false, wallPad = 6, tension = 0.8, nodes = 7, spacing = 2, pos_arr = {}, shape_arr = {}, pbox_arr = {}, boxDim_arr = {} }
CHECK_POINT_CONFIG = { editing = 0, hasChange = false, wallPad = 7, tension = 0.4, nodes = 10, spacing = 2, pos_arr = {}, shape_arr = {} }
NODE_CHAIN = {}


-- --- 5. CLASSES ---

EngineStats = class(nil)
function EngineStats.init(self,stats)
    self.TYPE = stats['TYPE']
    self.COLOR = stats['COLOR']
    self.MAX_SPEED = stats['MAX_SPEED'] + math.random(0,25)
    self.MAX_ACCEL = stats['MAX_ACCEL']
    self.MAX_BRAKE = stats['MAX_BRAKE']
    self.GEARING = shallowcopy(stats['GEARING']) 
    self.REV_LIMIT = self.MAX_SPEED / #self.GEARING
    return self
end 


-- --- 6. MATH & VECTOR HELPERS ---

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
    return c + (d - c) * (x - b) / (a - b)
end

-- Optimized Distance (Uses length2 where possible for comparisons, length for actual distance)
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

-- Angle Helpers
function vectorToDegrees(vector)
    return math.deg(math.atan2(vector.y, vector.x))
end

function angleDiff(vector1, vector2)
    -- Simplified to z-cross logic you were using
    local directionalCross = vector1:cross(vector2)
    return directionalCross.z * FORCE_SENSITIVIY
end

-- --- 7. ACCESSORS & LIST HELPERS ---

function getRaceControl()
    return RACE_CONTROL
end

function getAllDrivers()
    return ALL_DRIVERS
end

function getAllCameras()
    return ALL_CAMERAS
end

function getSmarCam()
    return sm.SMARGlobals.SMAR_CAM
end

function setSmarCam(cam)
    sm.SMARGlobals.SMAR_CAM = cam
end

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
        -- Check Meta ID (Numeric)
        if search_id_num and v.carData and v.carData.metaData and (search_id_num == v.carData.metaData.ID) then
            return v
        end
        -- Check Meta ID (String)
        if v.carData and v.carData.metaData and (search_id_str == tostring(v.carData.metaData.ID)) then
            return v
        end
        -- Check Twitch UID
        if v.twitchCar and v.sv_twitchData and search_id_str == v.sv_twitchData.uid then
            return v
        end
    end
    return nil
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
        if v.racePosition <= racePos then
            table.insert(selected, v)
        end
    end
    return selected
end

function getLapsLeft()
    local leader = getDriverByPos(1)
    if leader and getRaceControl() then
        return getRaceControl().targetLaps - leader.currentLap
    end
    return 0
end

-- Node Chain Navigation
function getNextItem(chain, currentId, offset)
    if not chain or #chain == 0 then return nil end
    offset = offset or 1

    -- Find index (Optimization: If nodes are sorted 1..N, we can use ID directly if ID==Index)
    -- Assuming ID is index for now to speed up. If IDs are unique hashes, we need a lookup table.
    -- Your generator seems to set ID = k, so ID is Index.
    local currentIndex = currentId 
    
    -- Safety check if IDs aren't indices
    if chain[currentIndex] == nil or chain[currentIndex].id ~= currentId then
         for i, node in ipairs(chain) do
             if node.id == currentId then currentIndex = i break end
         end
    end

    local chainLength = #chain
    local newIndex = ((currentIndex + offset - 1) % chainLength) + 1 
    return chain[newIndex]
end


-- --- 8. TABLE UTILITIES ---

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

function tableConcat(t1,t2)
    for i=1,#t2 do
        t1[#t1+1] = t2[i]
    end
    return t1
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

-- --- 9. SORTERS ---

function sortRacersByCameraPoints(inTable)
    table.sort(inTable, function(a,b) return a['points'] > b['points'] end)
    return inTable
end

function sortCamerasByDistance(inTable)
    table.sort(inTable, function(a,b) return a['distance'] < b['distance'] end)
    return inTable
end

-- --- 10. ENGINE/VEHICLE HELPERS ---

function getEngineType(color)
    for _, v in ipairs(ENGINE_TYPES) do
        if color == v.COLOR then return v end
    end
    return ENGINE_TYPES[1]
end

function getBrakingDistance(speed, mass, brakePower, targetSpeed)
    if speed <= targetSpeed then return 0 end
    
    local bpAdj = mathClamp(0.02, brakePower, brakePower - 0.2)
    if mass > 10000 then bpAdj = 0.03 end
    
    local top = targetSpeed^2 - speed^2
    local bottom = 2 * (bpAdj * DECELERATION_RATE) -- DECELERATION_RATE is negative
    return top / bottom
end

-- Debug Print
function debugPrint(debug, info)
    if debug then print(info) end
end

print("Globals Loaded (Refactored)")