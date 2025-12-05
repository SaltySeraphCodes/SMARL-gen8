dofile "util.lua"

-- List of globals to be listed and changed here, along with helper functions
CLOCK = os.clock
SMAR_VERSION = "1.10.5" -- Massive Pit Stop update
-- planned 1.9.0 -- Full Release for Driver overhaul and barebones for Gen8

MAX_SPEED = 10000 -- Maximum engine output any car can have ( to prevent craziness that occurs when too fast)
MOD_FOLDER = "$CONTENT_DATA/" -- ID to open files in content
DRIVER_UUID = "fbc31377-6081-426d-b518-f676840c407c"
DRIVER_GEN8_UUID = "31256788-71fb-4003-a9ca-9e6164a8faa3"
ENGINE_GEN8_UUID = "74bfdcd7-cfb2-4791-9611-602154eb90dd"
TWITCH_DATA = MOD_FOLDER .. "TwitchPlays/"
TWITCH_BLUEPRINTS = TWITCH_DATA .. "Blueprints/"
CHATTER_DATA = TWITCH_DATA .."Json_Data/chatterData.json" -- unecessary I think
--CAMERA_FOLDER = "$CONTENT_d42a91c3-2f86-4923-add5-93d8258b2c08/"
-- SELF FOLDER =- "$CONTENT_5411dc77-fa28-4c61-af84-bcb1415e3476/"
sm.SMARGlobals = {
    LOAD_CAMERA = true, -- REMEMBER TO SET THIS TO FALSE
    SMAR_CAM = -1 -- Smar camera loaded from cinecam mod
}
-- GEN 8 GLOBALS
MAX_WHEEL_ANGLE_RAD = 0.8 -- Example: 0.785 radians is 45 degrees (want 50?)
STEERING_Kp = 1  -- Proportional Gain (P) - Current Error Magnitude (default = 1 ) (drift = 0.3)
STEERING_Kd = 0.01  -- Derivative Gain (D) - Damping Factor (Needs tuning!) default 0.5
SPEED_Kp = 0.2  -- Proportional Gain (P) - Slightly reduced for stability drift = 0.1
SPEED_Kd = 0.05 -- Derivative Gain (D) - Very light damping (Needs tuning!) default 0.05 drift = 0.1

MAX_SPEED = 200 -- Tune this to engine
MIN_SPEED = 10.0  -- Tune this to engine?





MAX_STEER_VALUE = 50 -- maximum angle car can turn wheels
ALL_DRIVERS = {} -- contains all constantly updating information of each driver, can be read from anywhere that imports globals.lua (updated dynamically)
RACE_CONTROL = nil -- Contains race control Object
ALL_CAMERAS = {}
CAMERA_LEADERS = {} -- car ids and car points
TWITCH_CONNECTIONS = {} -- Shape IDs of cars that still need to get their twitchData updated
-- HARD LIMITS no engine can go past this on acident
ENGINE_SPEED_LIMIT = 1000 -- Car should never get this high anyways but just in case

--

-- Physics Defaults
DEFAULT_GRAVITY = 10 -- Good even number
DEFAULT_FRICTION = 0.0006046115371 -- Friction coeficient -- could be wrong

-- Conversion Rates
VELOCITY_ROTATION_RATE = 0.37 -- 1 rotation speed ~= 0.37 velocity length -- How fast wheels should rotate (engine  speed) to achieve a certain velocity
DECELERATION_RATE = -11.3 -- (accurate = 13.3) Multiply this number by the braking speed to get the aproximate deceleration rate for brake distance calculaitons (decrease for longer breaking distances)
-- VMAX calculation defaults
MAX_VELOCITY = 1000
DEFAULT_MAX_STEER_VEL = 2
DEFAULT_MINOR_STEER_VEL = 26
DEFAULT_MAX_STEER = (MAX_STEER_VALUE or 55)
DEFAULT_MINOR_STEER = 5
DEFAULT_VMAX_CONVERSION = 27.47018327 * math.exp(0.01100092674*1) -- * 1 <- steering angle goes here
-- K = 1/(MAxSteer-minSteer)* ln(MaxSteerVel/minSteerVel), A0 = MinSteerVEl* e^(-k*SteerInput)

-- Track generation options -- possibly move to track piece?
FORCE_SENSITIVIY = 4 -- How much angle differences affect total force on node chain
FORCE_THRESHOLD = 0.01 -- when nodes accept where they are
WALL_PADDING = 6

-- Save Channels
TRACK_DATA = 1 -- Location to save world storage for the racing line
PIT_DATA = 2


TEMP_TRACK_STORAGE = { -- Temporary storage for tracks... [unused for now]

}

PIT_CHAIN_CONFIG = {
    editing = 0,
    boxEdit = 0,
    hasChange = false,
    wallPad = 6,
    tension = 0.8,
    nodes = 7,
    spacing = 2, -- Spacing between nodes, Deletes any nodes that are closer
    pos_arr = {}, -- List of Vec3s for each position
    shape_arr = {}, --list of vec3s for each shape (more permanent)
    pbox_arr = {}, --list of pit box locations
    boxDim_arr = {} -- list of pit box dimenstions distances -direction * distance 
}

-- New manual Checkpoint globals
NODE_CHAIN = {}
CHECK_POINT_CONFIG = { -- client side
    editing = 0,
    hasChange = false,
    wallPad = 7,
    tension = 0.4,
    nodes = 10,
    spacing = 2, -- Spacing between nodes, Deletes any nodes that are closer
    pos_arr = {}, -- List of Vec3s for each position
    shape_arr = {}, --list of vec3s for each shape (more permanent)
}

CAMERA_MODES = {
        RACE_CAM = 0,    -- Follows fixed track cameras
        DRONE_CAM = 1,   -- Flying drone that follows focused racer
        FREE_CAM = 2,    -- Free cam that can float and go around wherever on input
        ONBOARD_CAM = 3,  -- Attached to the racer
        FINISH_CAM = 4, -- Fixed finishline camera
    }

ZOOM_METHODS = {
        IN  = 0,
        OUT = 1,
        STAY = 2,
}

SEGMENT_TYPES = {
    {
        TYPE = "Straight",
        THRESHOLD = {-1,1},
        COLOR = "4DD306FF"
    },
    {
        TYPE = "Fast_Right",
        THRESHOLD = {1,3},
        COLOR = "07FFECFF"
    },
    {
        TYPE = "Fast_Left",
        THRESHOLD = {-3,-1},
        COLOR = "FF6755FF"
    },
    {
        TYPE = "Medium_Right",
        THRESHOLD = {3,6},
        COLOR = "047FCAFF"
    },
    {
        TYPE = "Medium_Left",
        THRESHOLD = {-6,-3}
        , COLOR = "B80606FF"
    },
    {
        TYPE = "Slow_Right",
        THRESHOLD = {6,25},
        COLOR = "0B0066FF"
    },
    {
        TYPE = "Slow_Left",
        THRESHOLD = {-25,-6},
        COLOR = "660000FF"
    }
}
-- Engine Definitions
ENGINE_TYPES = { -- Sorted by color but could also maybe gui Dynamic? mostly defaults but also custom at end
   {
        TYPE = "road", -- slowest
        COLOR = "222222ff", -- black
        MAX_SPEED = 90, -- 73.5 lvl 5 engine
        MAX_ACCEL = 0.5,
        MAX_BRAKE = 0.60,
        GEARING = {0.45,0.35,0.21,0.17,0.15}, -- Gear acceleration Defaults (soon to be paramaterized)
        REV_LIMIT = 90/5 -- LImit for VRPM TODO: adjust properly
    },
    {
        TYPE = "sports", -- medium -- dark gray
        COLOR = "4a4a4aff",
        MAX_SPEED = 110, -- 80
        MAX_ACCEL = 0.5,
        MAX_BRAKE = 0.75, -- 1?
        GEARING = {0.55,0.46,0.23,0.18,0.18}, -- Gear acceleration Defaults (soon to be paramaterized)
        REV_LIMIT = 110/5 -- LImit for VRPM TODO: adjust properly
    },
    {
        TYPE = "formula", -- Fast
        COLOR = "7f7f7fff", -- Light gray
        MAX_SPEED = 150,
        MAX_ACCEL = 0.7,
        MAX_BRAKE = 0.85,
        GEARING = {0.60,0.48,0.25,0.20,0.19}, -- Gear acceleration Defaults (soon to be paramaterized)
        REV_LIMIT = 150/5
    },
    {
        TYPE = "insane", -- Insane -- add custom later?
        COLOR = "eeeeeeff", -- white
        MAX_SPEED = 250,
        MAX_ACCEL = 1,
        MAX_BRAKE = 0.90,
        GEARING = {0.50,0.4,0.30,0.21,0.20}, -- Gear acceleration Defaults (soon to be paramaterized)
        REV_LIMIT = 250/5
    },
    {
        TYPE = "custom", -- custom
        COLOR = "aaaa2f", -- todo
        MAX_SPEED = 250,
        MAX_ACCEL = 1,
        MAX_BRAKE = 0.85,
        GEARING = {0.48,0.45,0.50,0.5,0.15}, -- Gear acceleration Defaults (soon to be paramaterized)
        REV_LIMIT = 250/5
    }

}
-- Engine stats class to differentiate
EngineStats = class(nil)
function EngineStats.init(self,stats)
    self.TYPE = stats['TYPE']
    self.COLOR =stats['COLOR']
    self.MAX_SPEED = stats['MAX_SPEED'] + math.random(0,25)-- 73.5 lvl 5 engine
    self.MAX_ACCEL = stats['MAX_ACCEL']
    self.MAX_BRAKE = stats['MAX_BRAKE']
    self.GEARING = shallowcopy(stats['GEARING']) -- Gear acceleration Defaults (soon to be paramaterized)
    self.REV_LIMIT = self.MAX_SPEED/#self.GEARING
	return self
end 

function EngineStats.setMaxSpeed(self,speed)
    self.MAX_SPEED = speed
end

function EngineStats.getMaxSpeed(self,speed)
    return self.MAX_SPEED
end
-------------------Pit style data----------------------
--[[
print('entyppe',ENGINE_TYPES[1])
local en1 = EngineStats()
en1:init(ENGINE_TYPES[1])
local en2 = EngineStats()
en2:init(ENGINE_TYPES[1])
en1:setMaxSpeed(49)
print('set speed',en1:getMaxSpeed(),ENGINE_TYPES[1],en2:getMaxSpeed())
en2:setMaxSpeed(39)
en1.GEARING[1] = 2
print('set speed2',en1:getMaxSpeed(),ENGINE_TYPES[1],en2:getMaxSpeed())
]]

PIT_TIMING = {
    TIRE_CHANGE = 3,
    FUEL_FILL = 0.05 -- Rate per 1 level of fuel meaning 100 Fuel = 5 seconds
}

TIRE_TYPES = { 
    [1] = { -- Soft
        TYPE = "soft", 
        DECAY = 0.4, 
        GRIP = 1.0, 
        MAX_SLIP_FACTOR = 1.5 -- High wear from sliding
    },
    [2] = { -- Medium
        TYPE = "medium",
        DECAY = 0.2,
        GRIP = 0.8,
        MAX_SLIP_FACTOR = 1.0 
    },
    [3] = { -- Hard
        TYPE = "hard",
        DECAY = 0.1,
        GRIP = 0.6,
        MAX_SLIP_FACTOR = 0.5 -- Low wear from sliding
    }
}


PIT_POINT_TYPES = {
    {
        TYPE = 0,
        NAME = "Pit Path",
        COLOR = "aaaaffff"
    },
    {
        TYPE = 1,
        NAME = "Pit Begin",
        COLOR = "cbf66fff"
    },
    {
        TYPE = 2,
        NAME = "Pit Entrance",
         COLOR = "577d07ff"
    },
   {
        TYPE = 3,
        NAME = "Pit Exit",
        COLOR = "7c0000ff"
    },
    {
        TYPE = 4,
        NAME = "Pit End",
        COLOR = "f06767ff"
    }
}

-- Data managment
function saveData(data,channel) -- gather more params
    TEMP_TRACK_STORAGE[channel] = data
end

function loadData(channel)
    --print("loading",channel,TEMP_TRACK_STORAGE[channel])
    return TEMP_TRACK_STORAGE[channel]
end

function getRaceControl()
    --if RACE_CONTROL == nil then
    return RACE_CONTROL
end


function cameraCompare(a,b)
    --print(a.cameraID)
	return a['cameraID'] < b['cameraID']
end

function sortCameras()
    --print("Sorting Cameras")
    table.sort(ALL_CAMERAS, cameraCompare)
    --print(ALL_CAMERAS)
end


function chpoCompare(a,b)
    --print(a.cameraID)
	return a['cpIndex'] < b['cpIndex']
end

function sortCheckpoints()
    table.sort(CHECK_POINT_CONFIG.shape_arr, chpoCompare)
end

function setSmarCam(cam)
    sm.SMARGlobals.SMAR_CAM = cam
    --print("set smar cam",SMAR_CAM)
end

function getSmarCam()
    return  sm.SMARGlobals.SMAR_CAM
end

function table.clone(org)
    return {table.unpack(org)} -- doesnt work
end


function cloneTable(t) -- clones table without refferences
	local o = {}
	
	for k, v in pairs(t) do
		if type(v) == "table" then
			o[k] = cloneTable(v)
		else
			o[k] = v
		end
	end
	
	return o
end


function shallowcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else -- number, string, boolean, etc
        copy = orig
    end
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
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end
-- Helper functions
-- client onhover checker
function cl_checkHover(check_shape) -- checks if shape is being looked at
    local hit,raycastResult = sm.localPlayer.getRaycast(10)
    if hit then
        local shape = raycastResult:getShape()
        if shape then
            if check_shape == shape then
                return true
            else
                return false
            end
        else
            return false
        end
    else
        return false
    end
    return false
end


function validateAT (trigger)
    local data = trigger:getUserData()
    if data then 
        return data
    end
end

function cl_checkHoverAT(sphereTrigger) -- Checks if sphereTrigger is seen
    --local hit,raycastResult = sm.localPlayer.getRaycast(10)
    local hit,raycastResult = sm.physics.raycast( sm.localPlayer.getRaycastStart(), 
                                                sm.localPlayer.getRaycastStart() + (sm.localPlayer.getDirection() * 70),
                                                nil,
                                                sm.physics.filter.areaTrigger)
    if hit then
        local target = raycastResult:getAreaTrigger()
        if target then
            local status, data = pcall(validateAT,target) -- Could pcall whole function
            if status == false then  return false end
            return data
        else 
            return false
        end
    else
        return false
    end
    return false
end


-- Car helpers

function displayCarRadar(radar) -- prints fun radar
    print(

    )
end

function gl_checkForClearTrack(nodeID,nodeChain) -- Checks for any cars within 50? nodes on node chain
    local clearFlag = true
    local clearThreshold = distance -- make dynamic?
    local minNode = getNextItem(nodeChain,nodeID,-50)
    local maxNode = getNextItem(nodeChain,nodeID,10)
    --print("MinNode",minNode.id)
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
        if v.id ~= self.id then 
            --print("scanning",v.id,v.stuck,v.rejoining,v.currentNode.id)
            if not (v.stuck or v.rejoining) then -- If its not stuck
                if v.currentNode ~= nil and v.speed > 10 then 
                    local node = v.currentNode.id
                    ---print("checking clear ",minNode.id,node,self.currentNode.id)
                    local nodeDist = getNodeDistBackward(#nodeChain,maxNode.id,node)
                    if nodeDist < 50 then
                        print("not clear")
                        clearFlag = false
                    end
                    --if (node > minNode.id and node < self.currentNode.id)  then
                    --    clearFlag = false
                    --end
                end
            end
        end
    end
    return clearFlag
end
    -- Track related helper

function generateNodeMap(nodeChain) -- Creates a mapped 2d array of nodes based on [y],[x] location -- try for pathType??
    local map = {} -- Wwhole map
    local indexGroup = {} -- array of nodes within an index of the map

    if nodeChain == nil then
        print("Could not generate nodemap; no nodes")
    end

    for k=1, #nodeChain do local node=nodeChain[k]
        local row = round(node.location.y)
        local col = round(node.location.x)
        if map[row] == nil then
            map[row] = {}
        end
        if map[row][col] == nil then
            map[row][col] ={}
        end
        table.insert(map[row][col],node)
        --print("insertingnode",row,col,map[row])
    end
    return map
end


function displayNodeMap(nodeMap,location) -- attempts to display nodemap
    mapString = "\n"
    mapXSize = 100
    mapYSize = 40
    local approxRow = round(location.y)
    local approxCol = round(location.x)
    for row = -mapYSize/2, mapYSize/2 do
        for col = -mapXSize/2, mapXSize/2 do
            if nodeMap[approxRow + row] ~= nil then -- Row contains something
                if nodeMap[approxRow + row][approxCol + col] ~= nil then -- Column contains something
                    if col ==0 and row == 0 then 
                        mapString = mapString .. "@" -- Self Pos
                    else
                        mapString = mapString .. "O" -- Node Pos
                    end
                else -- Column contains nothing
                    if col ==0 and row == 0 then 
                        mapString = mapString .. "@"
                    else  
                        mapString = mapString .. "-" 
                    end
                end
            else -- Row doesnt contain anything
                if col ==0 and row == 0 then 
                    mapString = mapString .. "@" 
                else  
                    mapString = mapString .. "-" 
                end
            end
        end
        mapString = mapString .. "\n"
    end
    print(mapString)
end


function GenerateVisualPath(path,exportArr) --generates the line effect for  a path
	for k = 1, #path do local v = path
		if k == #path then
			return
		end
        local startPos = v
        local endPos = path[k+1]
        local line = Line()
        line:init(0.2,sm.color.new(1,1,1)) -- white
        line.update(startPos,endPos)
        table.insert(exportArr, line)
        print("drawing line",line)
    end
    return exportArr
end

function cl_generateSphereTrigger(id,ntype,pos)
    -- send to server?
    -- radius, position, rotation filter, userdata
    local trigger = sm.areaTrigger.createSphere(1, pos, nil, nil, {['node_id']=id,['node_type'] = ntype})
    --print('create tgrgger',id,pos)
    return trigger
end

function findClosestNode(nodeChain,location)
    --print("fnn")
    -- New way, search towards near
    local closestPhysicalNode = getNodeClosest(nodeChain,location)
    --print("FCN",closestPhysicalNode.id,closestPhysicalNode.location,location,getDistance(closestPhysicalNode.location,location))
    return closestPhysicalNode
end
-- possibly use areaTrigger?
-- Get closest nodes to the nearest location?
function getNearestNode(nodeMap,location) -- TODO: Get outer bounds of nodeMap, detect if outside, instead of searching all, just search for nearest node in general direction
    local availibleNodes = {}
    local approxRow = round(location.y)
    local approxCol = round(location.x)
    local distance = nil
    local searchDistance = 0 -- how far away to search
    
    --print("getting nearest node",approxRow,approxCol)
    local possibleRow = nodeMap[approxRow]
    if possibleRow ~= nil then
        local possibleCol = nodeMap[approxRow][approxCol]
        if possibleCol ~= nil then
            availibleNodes = nodeMap[approxRow][approxCol] -- posssibly index even more?
            print("imediate nodes",availibleNodes)
        end
    end 

    -- Just general ineffeciient track can that should only be called last resourt
    local searchLimit = 200
    while availibleNodes == nil or #availibleNodes == 0 do
        --print("while",searchDistance)
        searchDistance = searchDistance + 1
        if searchDistance > searchLimit then
            print("Searchlimit reached")
            break
        end
        local extendedNodes = {}
        for row = -searchDistance, searchDistance do
            for col = -searchDistance, searchDistance do -- SOmehow skip over nodes already seen
                if nodeMap[approxRow + row] ~= nil then -- valid node with row
                    if  nodeMap[approxRow + row][approxCol + col] ~= nil then -- Valid column node
                        --print()
                        --print("Found",approxRow + row,approxCol + col, nodeMap[approxRow + row][approxCol + col])
                        local extendedSearchNodes = nodeMap[approxRow +row][approxCol + col]
                        --print("Extended",extendedSearchNodes,extendedSearchNodes[1])
                        if extendedSearchNodes ~= nil and #extendedSearchNodes > 0 then
                            for j = 1, #extendedSearchNodes do local eNode = extendedSearchNodes[j]
                                --print(eNode.bank,math.abs(eNode.location.z - location.z), 2 + math.abs(5* eNode.bank))
                                if math.abs(eNode.location.z - location.z) < 3 + math.abs(6* eNode.bank) then -- make smaller/bigger dif?
                                    --print(location.z,eNode.location.z)
                                    table.insert(extendedNodes, eNode) -- puts nodes into extendedNode
                                else
                                    --print("node not on same level")
                                end
                            end
                        end
                    else
                        --print('badCol')
                    end
                else
                    --print("badRow",nodeMap[approxRow])
                end
            end
        end
        if extendedNodes ~= nil and #extendedNodes > 0 then
            --print("whats goin ong",extendedNodes)
            --if availibleNodes == nil then availibleNodes = {} end -- make empty
            availibleNodes = tableConcat(availibleNodes,extendedNodes)
        else
            --print("expand",searchDistance,"search failed",location)
        end
    end
    -- print("pre filter",#availibleNodes)

    -- filter node zs
    for i=1, #availibleNodes do local node = availibleNodes[i]
        --print("nodefilter?",math.abs(node.location.z - location.z))
        if node == nil then print("Bad node") return end
        if math.abs(node.location.z - location.z) > 3  + math.abs(6* node.bank) then -- TODO: just make lower priority instead of removing...
            --print(node.id,"not in range")
            table.remove( availibleNodes,i )
        end
    end
    --print("post filter",#availibleNodes)

    if availibleNodes == nil or #availibleNodes == 0 then -- Nothing directly
        --print("Could not find any nodes close")
        return nil
    else
        --print("Node canidates",availibleNodes)
    end
    --print("near nodes",availibleNodes,location)
    return getNodeClosest(availibleNodes,location) -- else return the closest nodes

end

function getNodeClosest(nodeList,location) -- Gets node closest to to {location}
    local minDist = nil 
    local closestNode = nil
    local closestZ = nil
    local closeZNode = nil
    for i=1, #nodeList do local node = nodeList[i]        
        if closestZ == nil then
            closestZ = math.abs(location.z - node.location.z)
            closeZNode = node
        else
            if math.abs(location.z - node.location.z) < closestZ then
                --print("Found closer z node",closestZ,location.z,node.location.z)
                closestZ = math.abs(location.z - node.location.z)
                closeZNode = node
            end
        end
        local nDist = getDistance(node.location,location)
        if (minDist == nil or nDist < minDist) then
            closestNode =  node
            minDist = nDist
        end
        
    end
    if closestNode.id == closeZNode.id then 
        -- nodes are same
    else
        -- nodes are different
        --print("Found different levels of z node close",location,closestNode.location,closeZNode.location)
        if math.abs(closestNode.location.z - closeZNode.location.z) < 4 then
            --print("nodes are close enoug", math.abs(closestNode.location.z - closeZNode.location.z))
        else
            --Sprint("possible split in node verticals")
            if math.abs(location.z - closeZNode.location.z) < 4 then -- Make bigger or smaller?? 
                closestNode = closeZNode
                --print("moving to closer z node")
            else
                print("staying with closest")
            end
        end

    end
    --print("Closest Node:",node,minDist)
    if closestNode == nil then
        --print("Could not determine closest node, z difference?")
    end
    --print("getNodeClosest",closestNode.id,closestNode.location,location)
    return closestNode
end


function searchNodeSegment(nodeList,segmentID) -- binary search node to find segment 
   
    if nodeList == nil then return 0 end
    
    local minIndex = 1 -- can shortcut?
    local maxIndex = #nodeList
    for i=minIndex, #nodeList do local node = nodeList[i] -- failsafe loop, should return much faster than full n
        searchIndex = math.floor((maxIndex+minIndex)/2)
        --if searchIndex == 0 then searchIndex = 1 end
        if nodeList[searchIndex].segID == segmentID then-- found search
            return searchIndex -- return Index
        elseif nodeList[searchIndex].segID > segmentID then -- currently too high, search low
            maxIndex = searchIndex - 1
        elseif nodeList[searchIndex].segID < segmentID then -- currently too low, search high
            minIndex = searchIndex +1
        end
    end
    print("seg not found",segmentID,searchIndex,nodeList[searchIndex].segID)
    return searchIndex
end



-- Engine/Driver Connector helpers TODO: get this to a more accurate and dynamic flavor
function calculateMaximumVelocity(segBegin,segEnd,segLen) -- gets maximumSpeed based on segment node and length of turn
    local segType = segBegin.segType
    local segCurve = segBegin.segCurve -- TODO: investigate curve
    local segLen = (segLen or 10)
    local angle = math.abs(segCurve)
    local angle2 = angleDiff(segBegin.outVector,segEnd.outVector) -- depreciated

    --print(angle,segType,getVmax(angle))

    if  segType == "Straight" then -- sometimes things go wrong
        return getVmax(angle) * 2
    elseif segType == "Fast_Right" or segType == "Fast_Left" then
        if segLen >= 5 then -- Long turn
            return getVmax(angle)*2 
        else
            return getVmax(angle)*1.5
        end
    elseif segType == "Medium_Right" or segType == "Medium_Left" then
        if segLen >= 15 then -- Long turn
            return getVmax(angle*1.4)*0.90
        else
            return getVmax(angle*1.4)*0.88
        end
    elseif segType == "Slow_Right" or segType == "Slow_Left" then
        if segLen >= 25 then -- Long turn
            --print("slowVMax Return1",getVmax(angle*1.5)*0.80 )
            return getVmax(angle*1.5)*0.90 
        else
            --print("slowVMax Return2",getVmax(angle*1.7)*0.75 )
            return getVmax(angle*1.5)*0.85
        end
    end
    return getVmax(angle)
end


function getBrakingDistance(speed,mass,brakePower,targetSpeed) -- Get distance needed to go from speed {target}
    --print(speed,targetSpeed)
    if speed <= targetSpeed then -- already there
        return 0
    end
    --local ticksToTarget = (speed-targetSpeed)/(brakePower)
    -- Ignoring the effects of negative acceleration, calculate distance
    --print("ticks",ticksToTarget)
    --return speed * ticksToTarget-- D = S*T -- Old dist formula
    local BPADJ = brakePower -0.2
    --local BPADJ = brakePower - 0.2
    if mass > 10000 then -- make longer brake dist?
        BPADJ = 0.03
    end
    --    local massAdj = mass-5000 -- Default weight will be 5000 TODO: Set Global --ratioConversion(4300,1500,brakePower,0.01,mass)
    --    BPADJ = brakePower - massAdj/1000
    if BPADJ <= 0 then BPADJ = 0.02 end-- minimum brakePower end
    if BPADJ >= brakePower then BPADJ = brakePower end -- maximum brakePower (TODO: COnver Global brakePower to mass based and not engine based)
    --end

    local top = targetSpeed^2 - speed^2
    local bottom = 2*(BPADJ*DECELERATION_RATE)
    local distance = top/bottom
    --print("M:",mass,BPADJ,targetSpeed,speed,distance)
    return distance

end

function mathClamp(min,max,value) -- caps value based off of max and min
    if value > max then
        return max
    elseif value < min then
        return min
    end
    return value
end

function getRotationIndexFromVector(vector,precision) -- Precision fraction 0-1
	if vector.y >precision then -- north?
		return 3
	end
	if vector.x > precision then
		return 2
	end
	if vector.y < -precision then
		return 1
	end
	if vector.x < -precision then
		return 0
	end
	return -1
end

--camera things
function getCameraIndexFromId(id) -- returns position in cam array
    for k=1, #ALL_CAMERAS do local v=ALL_CAMERAS[k]
		if v.cameraID == id then 
			return k
		end
	end
end

function getCameraFromId(id) -- returns position in cam array
    for k=1, #ALL_CAMERAS do local v=ALL_CAMERAS[k]
		if v.cameraID == id then 
			return v
		end
	end
end

-- Driver things


function getDriverFromId(id)
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
		if v.id == id then 
			return v
		end
	end
end


function getDriverFromMetaId(id)
    -- Ensure the input 'id' is a string for robust comparison, as it might be a string of an integer or a user ID.
    local search_id_str = tostring(id)
    
    -- Attempt to get a numeric version of the ID for comparison against number-based IDs
    local search_id_num = tonumber(search_id_str) -- Will this error out if the id is actually a string? (contains letters like a youtubeID)

    for k = 1, #ALL_DRIVERS do
        local v = ALL_DRIVERS[k]

        -- 1. Check for 'metaData.ID' match (Primary check)
        -- metaData.ID is often a number, so we check against the numeric version first.
        if v.carData and v.carData.metaData and search_id_num and (search_id_num == v.carData.metaData.ID) then
            return v
        end
        
        -- Fallback: Check against string version of metaData.ID in case it's stored as a string
        if v.carData and v.carData.metaData and (search_id_str == tostring(v.carData.metaData.ID)) then
            return v
        end

        -- 2. Check for 'twitchData.uid' match (Secondary check)
        -- This is typically a string (Twitch user ID/name), so we check against the string version.
        if v.twitchCar and v.sv_twitchData then
            print("car",v.sv_twitchData,search_id_str)
            -- The 'uid' is the field we are searching for a string match
            if search_id_str == v.sv_twitchData.uid then
                print('found')
                return v
            end
        end
    end
    
    return nil -- Explicitly return nil if no driver is found
end

function getAllDrivers()
    return ALL_DRIVERS
end

function getAllCameras() -- all trackside cameras
    return ALL_CAMERAS
end

function getFieldValuesFromList(list, field_name)
    local results = {}
    for _, sub_table in ipairs(list) do
        if sub_table[field_name] ~= nil then
            table.insert(results, sub_table[field_name])
        end
    end
    return results
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
    --print("sorting",driverArr)
    local outputArr = sortRacersByCameraPoints(driverArr)
    --print("sorted",outputArr)
    return outputArr
end

function getDriversFromIdList(idList) -- game id
    local driverList = {}
    for k=1, #idList do local v=idList[k]
		local driver = getDriverFromId(v)
        if driver ~= nil then
            table.insert(driverList,driver)
        else
            print("driver not found",v)
        end
	end
    return driverList
end

function getDriversFromMetaIdList(idList) -- car meta
    local driverList = {}
    for k=1, #idList do local v=idList[k]
		local driver = getDriverFromMetaId(v)
        if driver ~= nil then
            table.insert(driverList,driver)
        else
            print("driver not found",v)
        end
	end
    return driverList
end

function getDriversInDistance(driver,distance) -- returns table of all drivers within a certain distance
    local drivers = {}
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
        if v.id ~= driver.id then -- Dont look at yourself   need to mitigate pitstate pass handling and driver.pitState == 0 and v.pitState == 0 
            if v.goalNode ~= nil and driver.goalNode ~= nil then
                if v.carDimensions ~= nil then
                    if getDistance(driver.location,v.location) <= distance then -- Possibly just use trackDist/ID dist instead because we may get unececsary noise
                        if v.goalNode.segID == nil or driver.goalNode.segID == nil then
                            table.insert(drivers,v)
                        elseif math.abs(v.goalNode.segID - driver.goalNode.segID) < 4 then -- within 4 segments could adjust if necessary
                            table.insert(drivers,v)
                        else
                            --print("too far")
                        end
                    end
                end
            end
		end
	end
    return drivers
end

function getDriverDistance(driver,target,totalNodes) -- GEts the distance between two drivers ONLY use for general dist tracking, not precise
    if driver == nil or target == nil then return 0 end 
    if driver.currentNode == nil then return 0 end -- bad
    if target.currentNode == nil then return 0 end -- error
    local sign = 1
    if driver.currentNode.id < 20 and totalNodes - target.currentNode.id < 20 then -- Check if there is an overlap/lap passed(if close, then driver ahead)
        sign = -1
    elseif totalNodes - driver.currentNode.id < 20 and target.currentNode.id < 20 then -- Driver is ahead of target
        sign = 1
    elseif driver.currentNode.id > target.currentNode.id then -- driver is in front of target
        sign = -1
    elseif driver.currentNode.id < target.currentNode.id then -- driver is behind target
        sign = 1
    else -- Drivers on same node, extreeme close, will need better way to check distances
        sign = 1
    end
    --local slope = (target.location.y - driver.location.y)/ (target.location.x - driver.location.x)
   
    
    local distance =getDistance(driver.location, target.location) * sign -- just take node differences to save computation
    --print(driver.id)
  
    --print("distance",distance)
    return distance

end

function getDriverPosition(id) -- Gets race Posistion of racer accoring to racerID
	local driver= getDriverFromId(id)
	
	if driver == nil then 
		print("GetPosition: Invalid Race ID",id,driver)
		return 0
	end
	local position = driver.racePosition
	if position == nil then
		print("getPos: driver Position is nil")
		return 0
	end
	return position
end

function getDriverByPos(racePos) -- Return whole racer based off of race posistion
	for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
		--print(v.racePosition)
        if v.racePosition == racePos or v.racePosition == 0 then 
			--print("v")
			return v
		end
	end
end

function getDriversAbovePos(racePos) -- Gets all drivers above specified racePosition
    local selectedDrivers = {}
    for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
		--print(v.racePosition)
        if v.racePosition <= racePos then
			table.insert(selectedDrivers,v)
		end
	end
    return selectedDrivers
end



function getLapsLeft()
	for k=1, #ALL_DRIVERS do local v=ALL_DRIVERS[k]
		if v and v.racePosition and v.racePosition <= 1 then
            if getRaceControl() ~= nil then
			    return ( getRaceControl().targetLaps - v.currentLap)
            end
		end
	end
    return 10
end

function getRelativeSpeed(driverA,driverB)
	local relSpeed = driverA.speed - driverB.speed
	--print(string.format("REl = %.2f",relSpeed))
	--if relSpeed < 10 then return 10 end
	return relSpeed
end

function getCarCenter(racer)
    local rotation  =  racer.carDimensions['center']['rotation']
    local newRot =  rotation * racer.shape:getAt()
    return racer.shape:getWorldPosition() + (newRot * racer.carDimensions['center']['length'])
end 

function getPointRelativeLoc(center,checkPos,checkDir) -- similar to driver vh distances but the old school way
    center.z = checkPos.z --- THis setting of z mutates driver and may loead to unwanted consequences
    local goalVec = (center - checkPos) -- multiply at * velocity? use velocity instead?
    
    local vDist = checkDir:dot(goalVec)
    local hDist = sm.vec3.cross(goalVec,checkDir).z
    --print("v",vDist)
    local vhDifs = {horizontal = hDist, vertical = vDist}
    return vhDifs
end

function offsetAlongVector(location,target,dir) -- grabs offset from a vector
    local goalVec = (target.location - location) -- maybe use mid
    local vecAngle = math.acos(dir:dot(goalVec)/(goalVec:length())) -- convert pos/neg length somehow? ALL OF THIS IS UNECESSARY< JUST TAKE DOT PROCUT for vert dist :(
    local vecDeg = math.deg(vecAngle)
    local remainingDeg = 180 - vecDeg -- angle
    local realAngle = vecDeg -- < 90 and vecDeg or remainingDeg ----makes distance always positive, useful? 
    local realAngleR = math.rad(realAngle) -- convert to radians for sin functions or rewrite sin?
    local dist = goalVec:length() -- Hypotenuse

    local verticalDist = dist * math.cos(realAngleR) -- SocahToah heh
    --local verticalDist2 = math.sqrt( dist^2 - horizontalDist^2)-- pythag, a + b = c, solve for a
    local horizontalDist = dist * math.sin(realAngleR) -- opposite = hyp * sin (can go negative) THREE DIFFERENT WAYS TO DO THIS, only need cross product in the end...?
    --local horizontalDist2 = math.sqrt( dist^2 - verticalDist2^2 ) -- pythag crosscheck (always positive) (takes more calculations)
    --print(horizontalDist)
    local vhDifs = {horizontal = horizontalDist, vertical = verticalDist}
    return vhDifs
end


function getDriverHVDistances(driver,target) -- returns horizontal and vertical distances from driver to target driver
    -- vector angle dif -- Problems: something wierd going on when facing -+x axis with horizontal dist, mismatch distances
    local sPos = sm.vec3.new(driver.location.x,driver.location.y,target.location.z) -- making new vector to not mutate current driver location
    --driver.location.z = target.location.z --- THis setting of z mutates driver and may loead to unwanted consequences
    local goalVec = (target.shape.worldPosition - driver.shape.worldPosition) -- multiply at * velocity? use velocity instead?
    
    local vDist = driver.shape.at:dot(goalVec)
    local hDist = sm.vec3.cross(goalVec,driver.shape.at).z
    
    local vhDifs = {horizontal = hDist, vertical = vDist}
    return vhDifs
end

function getNodeVHDist(driver,node) -- returns offset to a node
    local sPos = sm.vec3.new(driver.location.x,driver.location.y,node.location.z) -- making new vector to not mutate current driver location
    --driver.location.z = node.location.z -- THis used to mutate driver location, gets set in new node
    local goalVec = (node.mid - sPos) -- multiply at * velocity? use velocity instead?
    
    local hDist = node.perp:dot(goalVec) * -1 -- Left is neg right is pos
    local vDist = sm.vec3.cross(goalVec,node.perp).z
    
    local vhDifs = {horizontal = hDist, vertical = vDist}
    return vhDifs
end

function getLocationVHDist(node,location) -- returns vhDist offset based on a node/location (based off of nodes mid)
    local sPos = sm.vec3.new(node.location.x,node.location.y,location.z) -- making new vector to not mutate current driver location
    --node.location.z = location.z mutated bad
    local goalVec = (sPos - location) -- multiply at * velocity? use velocity instead?
    
    local hDist = node.perp:dot(goalVec) * -1 -- Left is neg right is pos
    local vDist = sm.vec3.cross(goalVec,node.perp).z
    
    local vhDifs = {horizontal = hDist, vertical = vDist}
    return vhDifs
end

function getRaceNodeVHDist(node,location) -- returns vhDist offset based on a node/location (based off of nodes mid)
    local sPos = sm.vec3.new(node.location.x,node.location.y,location.z) -- making new vector to not mutate current driver location
    --node.location.z = location.z mutated bad
    local goalVec = (sPos - location) -- multiply at * velocity? use velocity instead?
    
    local hDist = node.perp:dot(goalVec) * -1 -- Left is neg right is pos
    local vDist = sm.vec3.cross(goalVec,node.perp).z
    
    local vhDifs = {horizontal = hDist, vertical = vDist}
    return vhDifs
end




function getLocationTracPos(loc1,loc2) -- ?
end

function withinBound(location,bound) -- determines if location is within boundaries of bound
	local box1 = {bound.left, bound.left + bound.buffer}
    local box2 = {bound.right, bound.right + bound.buffer}
    local minX = math.min(box1[1].x,box1[2].x,box2[1].x,box2[2].x) -- todo: also store this instead of calculating every time too
	local minY = math.min(box1[1].y,box1[2].y,box2[1].y,box2[2].y)
	local maxX = math.max(box1[1].x,box1[2].x,box2[1].x,box2[2].x) 
	local maxY = math.max(box1[1].y,box1[2].y,box2[1].y,box2[2].y)
	if location.x > minX and location.x < maxX then
		if location.y > minY and location.y < maxY then
			return true
		end
	end
	return false
end

function squareIntersect(location,square) -- determines if location is within boundaries of carBound square
    local minX = math.min(square[1].position.x,square[2].position.x,square[3].position.x,square[4].position.x) -- todo: also store this instead of calculating every time too
	local minY = math.min(square[1].position.y,square[2].position.y,square[3].position.y,square[4].position.y)
	local maxX = math.max(square[1].position.x,square[2].position.x,square[3].position.x,square[4].position.x) 
	local maxY = math.max(square[1].position.y,square[2].position.y,square[3].position.y,square[4].position.y)
	if location.x > minX and location.x < maxX then
		if location.y > minY and location.y < maxY then
			return true
		end
	end
	return false
end


function lineIntersect(line1,line2) -- pulled from stack overflow
    local ax = line1[1].x
    local ay = line1[1].y
    local bx = line1[2].x
    local by = line1[2].y
    local cx = line2[1].x
    local cy = line2[1].y
    local dx = line2[2].x
    local dy = line2[2].y

    local d = (ax-bx)*(cy-dy)-(ay-by)*(cx-dx)
    if d == 0 then return end  -- they are parallel
    local a, b = ax*by-ay*bx, cx*dy-cy*dx
    local x = (a*(cx-dx) - b*(ax-bx))/d
    local y = (a*(cy-dy) - b*(ay-by))/d
    if x <= math.max(ax, bx) and x >= math.min(ax, bx) and
        x <= math.max(cx, dx) and x >= math.min(cx, dx) then
        -- between start and end of both lines
        return sm.vec3.new(x, y,0)
    end
end

-- format{ front, left, right, back,location,directionF,direction}
function generateBounds(location,dimensions,frontDir,rightDir,padding) -- Generates a 4 node box for front left right and back corners of position
    --print("gen bounds",location,dimensions,frontDir,rightDir,padding,dimensions['front']:length(),dimensions['left']:length())
    local bounds = {
    {['name'] = 'fl', ['position'] = location + (frontDir *  (dimensions['front']:length()*padding) ) + (-rightDir *  dimensions['left']:length()*padding)},
    {['name'] = 'fr', ['position'] = location + (frontDir *  (dimensions['front']:length()*padding) ) + (rightDir *  dimensions['left']:length()*padding)},
    {['name'] = 'bl', ['position'] = location + (-frontDir *  (dimensions['front']:length()*padding) ) + (-rightDir *  dimensions['left']:length()*padding)},
    {['name'] = 'br', ['position'] = location + (-frontDir *  (dimensions['front']:length()*padding) ) + (rightDir *  dimensions['left']:length()*padding)}
    }
    return bounds
end

function getCollisionPotential(selfBox,opBox) -- Determines if bounding box1 colides with box 2
    --print("gettinc colPot",selfBox)
    for k=1, #selfBox do local corner=selfBox[k]
        --print(corner['name'])
        local pos = corner['position']
        if squareIntersect(pos,opBox) then
            return k -- index in selfBox (corner)
        end
    end
    return false
end

-- More node stuff
function getNodeDistForward(nodeChainLen,startID,endID) -- gets node distance searching forward
    local dist = 0
    for k=1, nodeChainLen do  -- shouuld loop around the whole thing
        nextID = getNextIndex(nodeChainLen,startID,k)
        if nextID == endID then
            return k
        end
    end
end

function getNodeDistBackward(nodeChainLen,startID,endID) -- gets node distance searching Backward
    local dist = 0
    for k=1, nodeChainLen do  -- shouuld loop around the whole thing
        nextID = getNextIndex(nodeChainLen,startID,-k)
        if nextID == endID then
            return k
        end
    end
end



function getSegment(nodeChain,first,last) -- Shoves first node and last node into a list Possibly Rename to CollectSegment
    if first.id > last.id then -- causes issues, but needs to be possible due to finish line crossover
        print("getSeg possible flipflop",first.id,last.id)
    end
    local segList = {}
    local node = first
    while node.id ~= last.id do
        table.insert(segList,node)
        node = node.next
    end
    -- put final node in list?
    if node.id == last.id then
        table.insert(segList,node)
    end
    
    return segList
end

-- TODO: Make more efficient, use binary search to find begin of node and to find end of node (getSegBegin, getSegEnd, then getSegment)
function findSegment(nodeChain,totalSegments,segID) --Returns a list of nodes that are in a segment, (could be out of order) (altered binary search??)
    if segID == nil then print("bad segid",segID) return nil end
    local segList = {}
    local node = findSegmentBegin(nodeChain,totalSegments,segID) -- first node
    local index = node.id
    --print("node",node.id)
    local foundSegment = false
    local finding = false
    local timeout = 0
    local timeoutLimit = 500
    while (node ~= nil and timeout <= timeoutLimit) do
        if node.segID == segID then
            table.insert(segList,node)
            if not finding then
                finding = true
            end
        else 
            if finding then
                finding = false
                timeout = 0
                break
            end
        end
        node = getNextItem(nodeChain,index,1)
        index = index + 1
        timeout = timeout + 1
        if timeout >= timeoutLimit then
            print("SegFind timeout",segID)
            return nil
        end
    end    
    return segList
end



function findSegmentEnd(nodeChain,totalSegments,segID) -- TODO: Make more efficient (dont need to look through all nodes, hah BINARY SEARCH DUH)
    local segNodeIndex = searchNodeSegment(nodeChain,segID)-- Made Effficient with Binary search: 431 worst case to 72 on SC
    for i=segNodeIndex, #nodeChain do local node = nodeChain[i]
        if node ~= nil then
            local nextNode =  getNextItem(nodeChain,i,1)
            if nextNode.segID == getNextIndex(totalSegments,segID,1) then
                return node -- returns node so we dont go into the wrong seg
            end
        end
    end   
end

function findSegmentBegin(nodeChain,totalSegments,segID) -- parameratize by passing in nodeChain
    local segNodeIndex = searchNodeSegment(nodeChain,segID)-- random index with segmentID
    for i=segNodeIndex, 1,-1 do local node = nodeChain[i] -- iterate backwards until first node found (reversed segEnd)
        if node ~= nil then
            local prevNode =  getNextItem(nodeChain,i,-1)
            if prevNode.segID ~= node.segID then
                return node
            else
            end
        end
    end 
end


function getSegTurn(segType) -- quickly returns -1 - 1 of segment's turn based on the type
    if segType == "Fast_Right" then return 1 
    elseif segType == "Medium_Right" then return 2
    elseif segType == "Slow_Right" then return 3 
    end

    if segType == "Fast_Left" then return -1 
    elseif segType == "Medium_Left" then return -2 
    elseif segType == "Slow_Left" then return -3 
    end
    
    return 0
end

function findSegApex(segment)
    for k=1, #segment do local node=segment[k] 
        if node.apex >= 1 then  -- only finds initial apex (value 1), true apex is value 2 and should not be shifted
            return node
        end
    end
   print("apexFind")
end

function getNodeAngle(node1,node2) -- gets the angle difference between node 1 in vector and node2 outvector
    local firstVec = node1.inVector
    local lastVec = node2.outVector
    local angle = angleDiff(firstVec,lastVec) *2 -- maybe not as necessary? adjust to fit thresholds
    return angle
end

function defineSegmentType(segment) -- defines a segment based off of invector and outVector
    if segment == nil then
        print("NIl segment")
    end
    if  #segment == 1 then
        --print("single node segment")
    end
    
    local angleDifTotal = 0
    local lastAngleDif = 0
    local lastAngle = 0
    local angleTotal = 0
    for k=1, #segment do local node=segment[k]
        if k == 1 then sdif = 0 
            lastAngle = vectorToDegrees(node.outVector)
        else
            local newAngle = vectorToDegrees(node.outVector)
            local angleDif = (lastAngle -newAngle)
            if math.abs(angleDif) > 50 then 
                local absDif = math.abs(lastAngle) - math.abs(newAngle)
                --print("Got sharp dif",node.id,lastAngle,newAngle,absDif)
                if absDif < 45 then
                    --print("False alarm",absDif,-angleDif)
                    if getSign(lastAngle) == 1 and getSign(newAngle) == -1 then -- Went from right to left
                        angleDif = absDif * getSign(newAngle)
                    elseif getSign(lastAngle) == -1 and getSign(newAngle) == 1 then -- went from left to right
                        angleDif = absDif * getSign(newAngle)
                    else
                        print("got false positive",lastAngle,newAngle,absDif)
                    end

                elseif absDif < 25 then
                    print("false alarm??",absDif,angleDif)
                end
            end
            angleDifTotal = angleDifTotal + angleDif
            lastAngle = newAngle
        end
    end
    local angleDifAvg = angleDifTotal/#segment

    local stype = getSegType(angleDifAvg)
    if stype == nil then
        print("Something went werong with defining segments",angleDifAvg)
    else
        --print("got type",stype,angleDifAvg)
        return stype,angleDifAvg
    end
end

function setSegmentType(segment,stype,curve,segID) -- Sets all nodes in segment to specified {type}
    --print("setting seg type global",segID,segment[1].id,segment[#segment].id)
    for k=1, #segment do local node=segment[k]
        node.segType = stype
        node.segCurve = curve
        --print("setting node ide",node.id,segID)
        node.segID = segID
        --print("after node ide",node.id,segID)

    end
    if #segment == 1 then
        --print("single set seg",segID,segment[1].id,segment[1].segType.TYPE,segment[1].segID)
    end
end

function getSegType(force)
    for k=1, #SEGMENT_TYPES do local v=SEGMENT_TYPES[k]
        --print("searching",color,v.COLOR)
        if force >= v.THRESHOLD[1] and force < v.THRESHOLD[2] then
            --print("foundSegment",v)
            return v
        end
    end
    print("COULD NOT FIND SEG TIYPE")
end


-- Helpers
function fullTableMatch(table,key,value) -- checks if all objects in tables key matches value
    for i,v in ipairs(table) do
        if v[key] ~= value then
            return false
        end
    end
    return true
end

function findKeyValue(table,key,value) -- finds if key = value within a table
    --print('cm',#table,table)
    for i=1 ,#table do local v = table[i][key]
        --print(i,v)
        --print('check',v)
        if v == value then
            return true
        end
    end
    return false
end

function findValue(table,value) -- finds if value is in a table
    for i=1 ,#table do local v = table[i]
        --print(i,v)
        --print('check',v)
        if v == value then
            return true
        end
    end
    return false
end

function getIndexKeyValue(table,key,value) -- returns if key = value within a table
    --print('cm',#table,table)
    for i=1 ,#table do local v = table[i][key]
        --print(i,v)
        --print('check',v)
        if v == value then
            return i
        end
    end
    return false
end

function getKeyValue(table,key,value) -- returns if key = value within a table
    --print('cm',#table,table)
    for i=1 ,#table do local v = table[i][key]
        --print(i,v)
        --print('check',v)
        if v == value then
            return table[i]
        end
    end
    return false
end

function getPosOffset(location,vector,step)
    --print("old location",location,vector,vector*step)
    local newLocation = location  + (vector*step) -- -location?
    return newLocation
end

function getNormalVectorFromPoints(p1,p2)
   -- print("normalizing subtraction?",p2,p1)
    return sm.vec3.normalize(p2-p1)
end


function ratioConversion(a,b,c,d,x) -- Convert x to a ratio from a,b to  c,d
    --TODO: add a clamp here so it does nor exceed max/min ratios
	return c+ (d - c) * (x - b) / (a - b)  -- Scale equation
end

function steeringToDegrees(value) -- Converts a value between -1 and 1 to steering input
    local converted = ratioConversion(-1,1,-MAX_STEER_VALUE,MAX_STEER_VALUE,value)
    if converted > MAX_STEER_VALUE then -- steering limits (could be dynamic?)
        converted = MAX_STEER_VALUE 
    elseif converted < -MAX_STEER_VALUE then 
        converted = -MAX_STEER_VALUE
    end
    return converted
end

function degreesToSteering(value)
    local converted = ratioConversion(-MAX_STEER_VALUE,MAX_STEER_VALUE,-1,1,value)
    --print("got converted",converted)
    if converted > 1 then
        return 1
    elseif converted < -1 then
        return -1
    end
    return converted
end

function radiansToSteering(value)
    local converted = ratioConversion(-MAX_STEER_VALUE,MAX_STEER_VALUE,-1,1,math.deg(value))
    --print("got converted",converted)
    if converted > 1 then
        return 1
    elseif converted < -1 then
        return -1
    end
    return converted
    
end

function degreesToVector(angle)
    local x = math.cos(angle)
    local y = math.sin(angle)
    return sm.vec3.new(x,y,0)
end

function vectorToDegrees(vector)
    return math.deg(math.atan2(vector.y,vector.x))--*180/math.pi
end

function angleToRadians(angle) -- Gets angle in degrees and converts to radians
    return angle*math.pi/180 -- Or just use math.rad
end

function splitString(inputstr, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = {}
  for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
    table.insert(t, str)
  end
  return t
end




------------

function steeringToRadians(steering) -- NOt really necessary because it will just be a combination of before

end

function getEngineType(color)
    for k=1, #ENGINE_TYPES do local v=ENGINE_TYPES[k]
        --print("searching",color,v.COLOR)
        if color == v.COLOR then
            --print("found",v,color)
            return v
        end
    end
    -- else return slowest
    return ENGINE_TYPES[1]
end


function getDefaultEngineType(color)
    for k=1, #DEFAULT_ENGINE_TYPES do local v=DEFAULT_ENGINE_TYPES[k]
        --print("searching",color,v.COLOR)
        if color == v.COLOR then
            --print("found",v,color)
            return v
        end
    end
    -- else return slowest
    return DEFAULT_ENGINE_TYPES[1]
end

function getDistance(vector1,vector2) -- Gets the distance between two vec3s 
    local diff = vector2 - vector1
    local dist = sm.vec3.length(diff)
    return dist
end

function getMidpoint(locA,locB) -- Returns vec3 contianing the midpoint of two vectors
	local midpoint = sm.vec3.new((locA.x +locB.x)/2 ,(locA.y+locB.y)/2,locA.z)
	return midpoint
end

function getCurveOrigin(locA,locB,apexLoc) -- gets x/y combo that is on the "inside" of a curve based on greater distance fom apex
    local testPos1 = sm.vec3.new(locA.x,locB.y,locA.z)
    local testPos2 = sm.vec3.new(locB.x,locA.y,locA.z)
    -- Fix for 3d, Find the 2D origin and then find the lowest Z point, most turns shouldnt be inverted
    -- checks which is furthest from apex
    if getDistance(testPos1,apexLoc) < getDistance(testPos2,apexLoc) then
        return testPos2
    elseif getDistance(testPos1,apexLoc) > getDistance(testPos2,apexLoc) then
        return testPos1
    else -- WHAT? means that its a straight line equally lengthed from apex...
        print("THis should never happen but curve origin to apex dist is somehow equal on both sides")
    end
end




function findFurthestShape(shapeList,direction) -- Finds the furthest shape in the direction out of a list of shapes from a body (make sure body is on lift)
    if #shapeList <= 1 then return shapeList[1] end -- may break but shouldnt be able to be called if no shapes exist in a body
    local furthest = nil
    local dir = {"x",1} -- chooses between x and y and direction (-1,1)
    if direction.x == 0 then
        dir = {"y",direction.y}
    elseif direction.y == 0 then
        dir = {'x',direction.x}
    else
        print("ERROR finding furthest shape",direction)
    end
    --print("scanning dir",dir,direction)
    for k=1, #shapeList do local shape=shapeList[k]
        --print("scanning",shape)
        local curLocation = shape.worldPosition
        if furthest == nil or (curLocation[dir[1]] - furthest.worldPosition[dir[1]]) * dir[2] > 0 then -- subtracts then multiplies by the pos/neg factor
          --print("New furht?",curLocation,dir,furthest)
          furthest = shape
        end
    end
    --print("Found FUrthest",furthest)
    return furthest

end

function getDirectionOffset(shapeList,direction,origin) -- Returns vector offset in relevant direction of the furthest shape from origin
    if shapeList == nil then print("Direction offset Nil shapelist",shapeList) return end
    if direction == nil then print("Direction offset Nil direction",direction) return end
    if origin == nil then print("Direction offset nil origin",origin) return end 

    local furthestShape = findFurthestShape(shapeList,direction)

    local offset = furthestShape.worldPosition-origin

    offset.z = 0 -- Just keep same z value for now
    if direction.x == 0 then
        offset.x = 0
    elseif direction.y == 0 then
        offset.y = 0
    else
        print("ERROR getting direction offset",direction)
        return nil
    end

    return offset

end

-- rotate point

function rotateAroundPoint(origin,point,angle) -- tak
    -- apply rotation (and pos offset?)
    --local fakeRot = math.pi/2 -- Performs a negative rotation so pi/2 rotates -90 Degress and vise versa? can either inverse here or inverse in rotation grab?
    angle = angle * -1 -- inverse angle ()
    local centeredPoint = point - sm.vec3.new(0,0,0) -- Point centered around 0,0 based on origin
    --print(point.z - distFromZero.z)
    -- rotate Point(s) around 0,0
    local pointX = (centeredPoint.x*math.cos(angle) - centeredPoint.y*math.sin(angle))
    local pointY = (centeredPoint.x*math.sin(angle) + centeredPoint.y*math.cos(angle))
    local pointZ = centeredPoint.z
    local newPoint = sm.vec3.new(pointX,pointY,pointZ)
    -- offset point back to original offset
    newPoint = newPoint + origin
    -- offset Point to new Location
    newPoint = newPoint
    return newPoint
end

function calculateNewForceAngles(v) -- updates forces on a node
    if v.next == nil or v.last == nil then return end
    if v.inVector == nil or v.outVector == nil then return end
    v.outVector = getNormalVectorFromPoints(v.pos,v.next.pos)
    v.inVector = getNormalVectorFromPoints(v.last.pos,v.pos)
    v.force = angleDiff(v.inVector,v.outVector)
    v.perpVector = generatePerpVector(v.outVector)
    return v
end


function calculateNewForceAngles2(v) -- updates forces on a node without updating perp vector
    if v.next == nil or v.last == nil then return end
    if v.inVector == nil or v.outVector == nil then return end
    v.outVector = getNormalVectorFromPoints(v.pos,v.next.pos)
    v.inVector = getNormalVectorFromPoints(v.last.pos,v.pos)
    v.force = angleDiff(v.inVector,v.outVector)
    return v
end

function validChange(node,location,perp,dir) -- checks if a point is within track bounds + padding
    local valid = false
    local distance = getDistToWall(node,location,perp,dir) -- gets closest dist of virtual and physical wall based off of node data
    if distance > WALL_PADDING then -- if not too close to wall
          valid = true
    end
    return valid
end

function getDistToWall(node,location,perp,dir) -- sends out 3? raycasts to determine the distance to the wall, returns distance between vectors
    local zOffsetLimit = 0.6 -- How far above/below to search
    local zOffset = 0 -- unecessary?
    local zStep = 0.05 -- how many things to check
    local hit,data = sm.physics.raycast(location, location + (perp*dir)*300)
    if data.valid == false then -- If first try failed, just go all out
        for k=-zOffsetLimit, zOffsetLimit,zStep do 
            local newLocation = location + sm.vec3.new(0,0,k)
            hit,data = sm.physics.raycast(newLocation, newLocation +  (perp*dir)*300)
            if data.valid == false then
            else
                break -- average rest of measurements?
            end
        end
    end

    local virtualWall = nil
    -- Find which wall to use based on dir (-1 1)
    if dir == 1 then
        virtualWall = node.rightWall
    elseif dir == -1 then
        virtualWall = node.leftWall
    end

    if not data.valid then
        return getDistance(location,virtualWall) -- use virtual wall
    else -- compare real and virtual wall so no corner cuts
        local vWallD= getDistance(location,virtualWall)
        local wallD = getDistance(location,data.pointWorld)
        local closest = math.min( vWallD,wallD )
        --print("v",vWallDist,"w",wallD,"m",closest)
        return closest
    end
end


function posAngDif(location,vec,pos) -- gets the angle from the given location facing {vector} to a point {pos}
    local goalVec = (pos - location):normalize()
    goalVec.z = vec.z
    local cos = sm.vec3.dot(vec,goalVec) -- (divide by magnitude?)
    --print(cos)
    local bigAngle = math.acos( cos )
    if not bigAngle or tostring(bigAngle) == "nan" or bigAngle ~= bigAngle then
        print("som wong",vec,location,pos,cos,goalVec)
    end
    return bigAngle
end

function getPointAngleDiff(location,target) -- Same as above but probably more precise?
    return math.atan2(target.y-location.y,target.x - location.x)
end


function posAngleDif3(location,vec,target) -- Same as above but probably more precise?
    local goalVec = (target - location):normalize()
    local VangleDif = angleDiff(vec,goalVec)
    --targetAngle = targetAngle - math.atan2(vec.y,vec.x)
    return VangleDif * 9-- Dampen from force sensitivity?
end


function posAngleDif4(location,vec,target) -- Same as above but probably even more precise?
    local goalVec = (target - location):normalize()
    local VangleDif = vectorAngleDiff(vec,goalVec)
    --targetAngle = targetAngle - math.atan2(vec.y,vec.x)
    return VangleDif -- Dampen from force sensitivity?
end

function angleDiff(vector1,vector2) -- gets the angle difference between vectors TODO, usevactual formula
    local directionalOffset = sm.vec3.dot(vector2,vector1)
	local directionalCross = sm.vec3.cross(vector2,vector1)
    dif = (directionalCross.z) * FORCE_SENSITIVIY
    return dif
end


function vectorAngleDiff(vector1,vector2) -- gets the angle difference between vectors (Actuall proper math)
    -- Only care about 2d ange for now, 
    -- PROBlem, pi/2 and 3pi/2 are the same (no negative or positive) TODO: fix formula to get full radians of 2pi /2
    vector1.z =0
    vector2.z =0
    local dotProduct = sm.vec3.dot(vector1,vector2)
    local directionalCross = sm.vec3.cross(vector2,vector1)

    local lengthProduct = vector1:length() * vector2:length()

    if dotProduct == lengthProduct or string.format("%.4f",dotProduct) == string.format("%.4f",lengthProduct) then
        return 0 -- Preemptive straight vec
    end
    local rads = math.acos(dotProduct / lengthProduct) * getSign(directionalCross.z)
    if math.abs(tostring(rads)) == tostring(0/0) then
        rads = 0
    end
    --print("d",dotProduct,directionalCross.z,vector2,rads)
    return rads -- returns radians, degrees = math.deg() range of <-pi to =pi
end

function determineAngle(vector1,vector2)
   local dot = x1*x2 + y1*y2      -- dot product
    det = x1*y2 - y1*x2      -- determinant
    angle = atan2(det, dot)  -- atan2(y, x) or atan2(sin, cos)
end

function generatePerpVector(direction) -- SiteEffect! Z will always be 0, Nomatter what
    if direction == nil then
        print("perp,no direction")
    end
    return sm.vec3.new(direction.y,-direction.x,0) -- banked turns?
end

function calculateTotalForce(nodeChain)
    local totalForce = 0
    for k=1, #nodeChain do local v=nodeChain[k]
        totalForce = totalForce + math.abs(v.force)
    end
    --print("return total force",totalForce)
    return totalForce
end

function calculateAvgvMax(nodeChain)
    local totalVmax = 0
    local lenChain = #nodeChain
    for k=1, #nodeChain do local v=nodeChain[k]
        totalVmax = totalVmax + ( v.vMaxEst or 0 )
    end
    return totalVmax/lenChain
end

function findInArray(array,item) -- finds specific item within array of items (both passed)
    for i,v in ipairs(array) do
        if v == item then
            return true
        end
    end
end

function getSpeedColorScale(minColor,maxColor,value) -- Returns A scaled color Green is 0, red is max
    --print("getting scaled color",minColor,maxColor,value)
    local scaledColor = ratioConversion(minColor,maxColor,0,1,value) -- scale it to be between 0 and 1
    return sm.color.new(2.0 * scaledColor, 2.0 * (1 - scaledColor), 0)
end
    -- Math
function getSign(x) -- helper function until they get addes separtgely Bug, Zero returns zero TODO: search where this is used
    return x > 0 and 1 or (x < 0 and -1 or 0)
 end

 function getSignRealDep(x) -- Depreciated
    if x<0 then
    return -1
    elseif x>=0 then
    return 1
    else
    return 0
    end
end

 function round( value )
	return math.floor( value + 0.5 )
end

function rampToGoal(goal,value,rate) -- ramps value to goal by rate
    if value == nil then value = 0 end
    if value == goal then
         return goal
    elseif value > goal then 
        return value - rate
    elseif value < goal then 
        return value + rate
    end
end

    -- Data
function tableConcat(t1,t2)
    for i=1,#t2 do
        t1[#t1+1] = t2[i]  --corrected bug. if t1[#t1+i] is used, indices will be skipped
    end
    return t1
end
function debugPrint(debug,info)
    if debug then
        print(info)
    end
end


function toEngineSpeed(velocity) -- Converts car velocity length to engine rotation speed (rate 0.37)*
    return velocity/VELOCITY_ROTATION_RATE 
end
function toVelocity(rotationSpeed) -- Converts car rotation speed approximate velocity
    if rotationSpeed == nil then return 0 end
    return rotationSpeed*VELOCITY_ROTATION_RATE 
end


function getVmax(angle,maxSteer,minSteer,maxVel,minVel)
    local k = 1/((maxSteer or DEFAULT_MAX_STEER) -(minSteer or DEFAULT_MINOR_STEER))* math.log((maxVel or DEFAULT_MAX_STEER_VEL)/(minVel or DEFAULT_MINOR_STEER_VEL) )
    local A0 = (minVel or DEFAULT_MINOR_STEER_VEL)* math.exp(-k*(minSteer or DEFAULT_MINOR_STEER))
    return A0 * math.exp(k*angle)
end

function getVmax2(angle,minSpeed,maxSpeed) -- uses a ratio to determine speed from engines
    local speed = 0
    if angle < 0.20 then 
        speed = maxSpeed + 10 -- returns full speeds on straights~ give leeway for drafting
    end
    speed =  logarithmic_linear_decrease(angle,2.4,90,minSpeed)
    local speedBoost = maxSpeed/75
    speed = speed + speedBoost

    speed = mathClamp(minSpeed,maxSpeed+ 11,speed)

    return speed
end

function linear_decrease(input,max_input, initial_output, final_output) -- final output is minimum, init is max
    local input_range = max_input -- Assuming input range is 0 to 1
    local output_range = initial_output - final_output
    local coefficient = output_range / input_range
  
    local output = initial_output - coefficient * input
    return output
end

function logarithmic_linear_decrease(input,max_input, initial_output, final_output)
    local input_range = max_input -- Assuming input range is 0 to 3
    local output_range = initial_output - final_output
  
    -- Linear component:
    local linear_decrease = output_range / input_range * input
  
    -- Logarithmic component:
    local logarithmic_decrease = math.log(input + 1) * output_range / 20
  
    -- Combine linear and logarithmic decrease:
    local total_decrease = linear_decrease + logarithmic_decrease
  
    local output = initial_output - total_decrease
    return output
  end


function linear_increase(input, max_input, initial_output, final_output)
    local input_range = max_input -- Assuming input range is 0 to 1
    local output_range = final_output - initial_output
    local coefficient = output_range / input_range

    local output = initial_output + coefficient * input
    return output
end
-- Get maximum Value in a table
function getMax(arr)
    local max = nil
    local i
    for i=1,#arr do
        local compare = arr[i]
        if max == nil then 
            max = compare
        else
            if compare == nil then
                print("nil compare")
            end
            if compare > max then
                max = compare
            end
        end
    end
    return max
end

-- Get Minimum value in a table
function getMin(arr)
    local min = nil
    local i
    for i=1,#arr do
        local compare = arr[i]
        if min == nil then 
            min = compare
        else
            if compare == nil then
                print("nil compare")
            end
            if compare < min then
                min = compare
            end
        end
    end
    return min
end

function checkMax(previous,current)
    if previous == nil and current == nil then
        print("CheckMax of two nils error")
        return 0
    end

    if previous == nil or current == nil then
        return (current or previous)
    end

    if current > previous then
        return current
    else
        return previous
    end
end


function checkMin(previous,current)
    if previous == nil and current == nil then
        print("CheckMin of two nils error")
        return 0
    end

    if previous == nil or current == nil then
        return (current or previous)
    end

    if current < previous then
        return current
    else
        return previous
    end
end


function compareKeyMin(a,b,key)
    local aVal = a[key]
    local bVal = b[key]
    if aVal == nil and bVal == nil then
        print("CompareKey compare nil",key)
        return 0
    end

    if aVal == nil or bVal == nil then
        return (a or b)
    end

    if aVal > bVal then
        return b
    else
        return a
    end
end

function getMinValue(array,key) -- returns item with minimum value of key
    local min = nil
    local item = nil
    local i
    for i=1,#array do
        local compare = array[i][key]
        if min == nil then 
            min = compare
            item = array[i]
        else
            if compare == nil then
                print("nil compare")
            end
            if compare < min then
                min = compare
                item = array[i]
            end
        end
    end
    return item 
end

function getMaxValue(array,key)
    local max = nil
    local item = nil
    local i
    for i=1,#array do
        local compare = array[i][key]
        if max == nil then 
            max = compare
            item = array[i]
        else
            if compare == nil then
                print("nil compare")
            end
            if compare > max then
                max = compare
                item = array[i]
            end
        end
    end
    return item 
end

function getNextItem_new(linkedList, itemIndex, direction)
    -- 1. Defensive Checks
    if type(linkedList) ~= 'table' or #linkedList == 0 then
        return nil 
    end
    
    local listLength = #linkedList
    
    if type(itemIndex) ~= 'number' or itemIndex < 1 or itemIndex > listLength then
        return nil
    end

    if type(direction) ~= 'number' then
        direction = 1 -- If direction is missing, default to 1 (next item)
    end

    -- 2. Index Calculation (Universal Modulo Logic)
    
    -- a. Convert the current 1-based index to a 0-based index and apply the offset.
    local targetZeroIndex = itemIndex + direction - 1 

    -- b. Apply the safe modulo operation. 
    -- This guarantees a result between 0 and listLength - 1, handling both positive and negative 'direction'.
    local safeZeroIndex = ((targetZeroIndex % listLength) + listLength) % listLength
    
    -- c. Convert back to 1-based index for Lua.
    local nextIndex = safeZeroIndex + 1
    
    -- 3. Return Item
    return linkedList[nextIndex]
end


function getNextItem(linkedList,itemIndex,direction) -- Gets {direction} items ahead/behind in a linked list (handles wrapping)
    local nextIndex = 1
    if direction >= 0 then
        nextIndex = (itemIndex + direction -1 ) % #linkedList +1 -- because lua arrays -_-
    else
        nextIndex = (itemIndex + direction + #linkedList -1) %#linkedList + 1
    end
    return linkedList[nextIndex]
end

function getNextIndex(totalIndexes,currentIndex,direction) -- Gets {direction} items ahead/behind in a linked list (handles wrapping)
    local nextIndex = 1
    if direction >= 0 then
        nextIndex = (currentIndex + direction -1 ) % totalIndexes +1 -- because lua arrays -_-
    else
        nextIndex = (currentIndex + direction + totalIndexes -1) %totalIndexes + 1
    end
    return nextIndex    
end

function get_los(camera, racer) -- returns true if camera can see racer
    -- 1. Defensive Checks (Ensure all required properties exist)

    -- Check if 'racer' or required properties are missing
    if not racer or not racer.body or not racer.location or not sm.exists(racer.body) then
        print("no racer??")
        return false
    end
    
    -- Check if 'camera' or required properties are missing
    if not camera or not camera.location or not camera.shape or not camera.shape.body then
        print( "no body?"
        )
        -- We require the camera location and its own body for the second raycast exclusion
        return false
    end

    local cameraLocation = camera.location
    local racerLocation = racer.location
    local racerBody = racer.body
    local cameraBody = camera.shape.body
    
    -- 2. Raycast 1: Check Line of Sight *to* the Racer (excluding everything else)

    -- sm.physics.raycastTarget checks if anything is between cameraLocation and racerLocation,
    -- but only reports the specified target (racerBody).
    -- If 'hit' is true, it means the ray successfully hit the racer's body *first* before anything else.
    local targetHit, targetData = sm.physics.raycastTarget(cameraLocation, racerLocation, racerBody)
    
    -- If the raycastTarget hit the target, we have guaranteed LOS *unless* the camera itself is in the way.
    if targetHit then
        -- We tentatively have sight. Proceed to the second check to exclude the camera's body itself.
        -- Note: Scrap Mechanic's raycastTarget might not always function as a perfect "closest hit" check.
        -- Let's rely more on the general raycast for obstructions.
        --print("Got target hit")
    end
    
    -- 3. Raycast 2: Check for Obstructions (excluding the camera's body and the racer's body)

    -- The crucial check: Raycast the entire scene. We want to know if the first object hit is an obstruction.
    -- We exclude the camera's own body to prevent false positives when the camera is inside its shape/mount.
    -- We also exclude the racer's body, as it's the target.
    local obstructionHit, obstructionData = sm.physics.raycast(cameraLocation, racerLocation, cameraBody) 

    if obstructionHit then
        -- Check what was hit first. The raycast is a *general* check.
        local hitType = obstructionData.type
        
        if hitType == "body" then
             -- Body hits don't matter, we saw something so lets let it thru
            return true
            
        elseif hitType == "terrainAsset" then -- Dont check ground...
            -- Hit the ground, a rock, a wall, etc. -> obstruction.
            return false
        end
        
        -- Default to assuming an obstruction if raycast hit something unexpected/unhandled
        return false

    else
        -- Raycast hit nothing between the camera and the racer's location.
        -- This is the best indicator of true LOS.
        return true 
    end
end


function get_los_old(camera,racer)  -- returns true if camera can see racer
    if not sm.exists(racer.body) then
        return false
    end
    if not camera then
        return false
    end
    local hasSight = false

    hit, data = sm.physics.raycastTarget(camera.location,racer.location,racer.body)
    if hit then
        hasSight = true
    end
    
    hit, data = sm.physics.raycast(camera.location, racer.location,camera.shape.body)
    if hit then
        
        if data.type == "body" then hasSight = true end 
        if data.type == "terrainAsset" then
            hasSight = false
        end
        --print(data.type,hasSight)
    else -- should expand a bit
        hasSight = true -- just giving benefit of the doubt here
    end

    return hasSight
end

---- Racer meta data helps
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
    return a['points'] > b['points']
end

function camerasDistanceCompare(a,b)
    return a['distance'] < b['distance']
end
-- Need a check min or some way to figure out which is which
-- *See SMARL FRICTION RESEARCH for data chart
print("loaded globals and helpers")
