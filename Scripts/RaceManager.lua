-- RaceManager.lua
RaceManager = class(nil)

local STATE_STOPPED = 0
local STATE_RACING = 1
local STATE_CAUTION = 2
local STATE_FORMATION = 3

function RaceManager.server_init(self, raceControl)
    self.RC = raceControl
    self.state = STATE_STOPPED
    self.targetLaps = 10
    self.currentLap = 0
    self.raceFinished = false
    self.qualifying = false 
    self.finishResults = {}
    self.qualifyingResults = {}
    self.handiCapEnabled = true
    self.draftingEnabled = true
    
    -- Tire Settings
    self.tireWearEnabled = true
    self.tireWearMultiplier = 1.0 
    self.tireHeatEnabled = true
    
    -- Fuel Settings
    self.fuelUsageEnabled = true
    self.fuelUsageMultiplier = 1.0 
end

function RaceManager.server_onFixedUpdate(self, dt)
    if self.state == STATE_FORMATION then
        local leader = getDriverByPos(1)
        if leader and leader.nodeChain and leader.currentNode then
            local totalNodes = #leader.nodeChain
            if totalNodes > 0 then
                local leaderNodeIndex = leader.currentNode.id
                local startThreshold = totalNodes * 0.97
                if leaderNodeIndex > startThreshold then
                    print("RaceManager: Leader reached start zone. GREEN FLAG!")
                    self:setState(STATE_RACING)
                end
            end
        end
    end
end

function RaceManager.setState(self, newState)
    if self.state == newState then return end
    print("RaceManager: State changing from", self.state, "to", newState)
    self.state = newState
    self:broadcastCommand({ type = "raceStatus", value = newState })
    
    -- [[ NEW: AUTOMATED LEARNING LOCK ]]
    -- Strategy: Learn during Qualifying/Practice, Lock in for the Race.
    local shouldLock = false
    
    if newState == STATE_RACING then
        if self.qualifying then
            shouldLock = false -- Keep learning during Quali
            print("RaceManager: Qualifying Started - LEARNING ENABLED")
        else
            shouldLock = true -- Lock it down for the Race
            print("RaceManager: Race Started - LEARNING LOCKED (Physics Protected)")
        end
    elseif newState == STATE_STOPPED then
        shouldLock = false -- Always unlock when stopped so we can tune in testing
    end

    -- Update RC property to sync with UI
    if self.RC then 
        self.RC.learningLocked = shouldLock 
        self.RC:sv_syncRaceData()
    end

    -- Broadcast the Lock Command
    self:broadcastCommand({ type = "set_learning_lock", value = shouldLock })

    if newState == STATE_STOPPED then
        self.raceFinished = false
        self.finishResults = {}
    end
end

function RaceManager.broadcastCommand(self, command)
    local drivers = getAllDrivers()
    for _, driver in ipairs(drivers) do
        if driver and driver.sv_recieveCommand then
            driver:sv_recieveCommand(command)
        end
    end
end

function RaceManager.handleCommand(self, command)
    if command.type == "get_raceStatus" then
        -- Status request
    end
end

function RaceManager.resetRace(self)
    self:setState(STATE_STOPPED)
    self.currentLap = 0
    self.finishResults = {}
    self.qualifyingResults = {}
    local drivers = getAllDrivers()
    for _, driver in ipairs(drivers) do
        driver.currentLap = 0
        driver.raceFinished = false
        if driver.resetCar then driver:resetCar(true) end
    end
    if self.RC then self.RC:sv_output_data() end
end