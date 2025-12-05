-- SMARL PIT MANAGER -- Handles pit assignments and what not
dofile("globals.lua")
dofile "Timer.lua" 
PitManager = class( nil )
PitManager.maxChildCount = -1
PitManager.maxParentCount = -11
PitManager.connectionInput = sm.interactable.connectionType.logic
PitManager.connectionOutput = sm.interactable.connectionType.logic
PitManager.colorNormal = sm.color.new( 0xffc0cbff )
PitManager.colorHighlight = sm.color.new( 0xffb6c1ff )
local clock = os.clock 

function PitManager.client_onCreate( self ) 
	self:client_init()
end

function PitManager.server_onCreate( self )
	self:server_init()
end

function PitManager.client_onDestroy(self) end

function PitManager.server_onDestroy(self)
    self:clear_pitBoxes()
end

function PitManager.client_init( self,rc ) 
    if rc == nil then return end
    self.raceControl = rc
    self.pitChain = nil 
    self.pitBoxes = nil 
end

function PitManager.server_init(self,rc)
    if rc == nil then return end
    self.raceControl = rc
    self.pitChain = nil
    self.pitBoxes = nil
    self.run = false 
    self.started = CLOCK()
    print("PitManager Server Init")
end

function PitManager.client_onRefresh( self )
	self:client_onDestroy()
	self:client_init(self.raceControl)
end

function PitManager.server_onRefresh( self )
	self:server_onDestroy()
	self:server_init(self.raceControl)
end

-- NEW: Link Pit Chain to Main Chain
function PitManager.linkPitTrack(self)
    if not self.pitChain or #self.pitChain == 0 then 
        print("PitManager: No Pit Chain to link.")
        return 
    end
    if not self.raceControl.trackNodeChain or #self.raceControl.trackNodeChain == 0 then
        print("PitManager: No Main Track Chain to link.")
        return
    end

    -- 1. Find Main Track Node closest to Pit Start (Node 1)
    local pitStart = self.pitChain[1]
    local mainEntryNode = self:findClosestNode(self.raceControl.trackNodeChain, pitStart.location)
    
    if mainEntryNode then
        -- 2. Tag the Main Node so drivers know to switch here
        mainEntryNode.isPitEntry = true
        mainEntryNode.pitConnectIndex = 1 
        print("PitManager: LINKED ENTRY at Node " .. mainEntryNode.id)
    end
    
    -- 3. Find Main Track Node closest to Pit End (Last Node)
    local pitEnd = self.pitChain[#self.pitChain]
    local mainExitNode = self:findClosestNode(self.raceControl.trackNodeChain, pitEnd.location)
    
    if mainExitNode then
        -- 4. Tag the Pit End Node so drivers merge back safely
        pitEnd.mergeTargetIndex = mainExitNode.id
        print("PitManager: LINKED EXIT merging at Node " .. mainExitNode.id)
    end
end

function PitManager.findClosestNode(self, chain, pos)
    local bestNode = nil
    local minDst = math.huge
    for _, node in ipairs(chain) do
        local dist = (node.location - pos):length()
        if dist < minDst then
            minDst = dist
            bestNode = node
        end
    end
    return bestNode
end

function PitManager.sv_loadPitData(self, pitChain, pitBoxes)
    print('PitManager: Loading Data...')
    self.pitChain = pitChain
    
    -- Populate live boxes from global anchors if manual list is empty
    if not pitBoxes or #pitBoxes == 0 then
        self.pitBoxes = {}
        for _, box in ipairs(PIT_ANCHORS.boxes) do
            table.insert(self.pitBoxes, {
                id = box.shape.id,
                location = box.shape:getWorldPosition(),
                rotation = box.shape:getAt(),
                assigned = 0,
                remaining = 0,
                nextDriver = 0
            })
        end
    else
        self.pitBoxes = pitBoxes
    end

    if self.pitChain and #self.pitChain > 0 then
        self.run = true
        self:linkPitTrack()
    else
        print("PitManager: Pit Chain empty or nil.")
    end
end

function PitManager.getOpenPitBox(self) 
    if not self.pitBoxes then return nil end
    for _, box in ipairs(self.pitBoxes) do
        if box.assigned == 0 then return box end
    end
    return nil
end

function PitManager.getClosestOpenBox(self) 
    if not self.pitBoxes then return nil end
    local bestBox = nil
    local minRemain = math.huge
    
    for _, box in ipairs(self.pitBoxes) do
        if box.assigned ~= 0 then
            if box.remaining < minRemain and box.nextDriver == 0 then
                minRemain = box.remaining
                bestBox = box
            end
        else
            return box -- Found empty
        end
    end
    return bestBox
end

function PitManager.sv_pit_racer(self, pit_data) 
    local racer_id = pit_data['racer_id']
    local racer = getDriverFromMetaId(racer_id)
    if racer == nil then return false end
    
    print(racer.tagText, "Requesting Pit Stop...")
    
    local pitBox = self:getOpenPitBox() 
    if pitBox == nil then
        pitBox = self:getClosestOpenBox() 
    end

    if pitBox == nil then
        print("PitManager: PITS FULL. Denied.")
        return false
    end
    
    self:assignPitBox(racer, pitBox, pit_data)
    return true
end

function PitManager.sv_managePitBoxes(self) 
    if not self.pitBoxes then return end
    
    for i, box in ipairs(self.pitBoxes) do
        if box.assigned ~= 0 then
            local driver = getDriverFromId(box.assigned)
            if driver then
                -- Check if driver has finished stop
                if driver.pitState == 5 then -- Pit Out
                     self:finishPitStop(driver, box)
                elseif driver.pitState == 4 then -- Stopped
                     -- Decrement timer? Handled by driver for now
                end
            else
                -- Driver lost? Clear box
                self:clear_pitBox(box)
            end
        end
    end
end

function PitManager.server_onFixedUpdate(self)
    if self.run then self:sv_managePitBoxes() end
end

function PitManager.calculatePitTime(self, pit_data)
    local totalTime = 5.0 -- Base stop time
    if pit_data['Tire_Change'] > 0 then totalTime = totalTime + 4.0 end
    totalTime = totalTime + (pit_data['Fuel_Fill'] * 0.1)
    return totalTime
end

function PitManager.finishPitStop(self, racer, pitBox) 
    self:clear_pitBox(pitBox)
    racer.assignedBox = nil
    -- If there was a queue, move next driver up?
end

function PitManager.assignPitBox(self, racer, pitBox, pit_data) 
    local pitTime = self:calculatePitTime(pit_data)
    pitBox.assigned = racer.id
    pitBox.remaining = pitTime
    
    racer.assignedBox = pitBox
    racer.pitTotalTime = pitTime
    
    -- Send command to driver to prepare for pit
    racer:sv_setup_pit(pit_data)
end

function PitManager.clear_pitBox(self, pitBox)
    pitBox.assigned = 0
    pitBox.remaining = 0
    pitBox.nextDriver = 0
end

function PitManager.clear_pitBoxes(self) 
    if not self.pitBoxes then return end
    for _, box in ipairs(self.pitBoxes) do self:clear_pitBox(box) end
end