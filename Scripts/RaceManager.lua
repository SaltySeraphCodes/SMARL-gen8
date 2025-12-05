-- RaceManager.lua: Handles the state of the race (Start/Stop/Caution/Formation).

RaceManager = class(nil)

-- Race States
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

    -- Settings
    self.handiCapEnabled = true
    self.draftingEnabled = true
    self.tireWearEnabled = true
end

function RaceManager.server_onFixedUpdate(self, dt)
    -- 1. AUTO-START (Formation Lap Logic)
    if self.state == STATE_FORMATION then
        local leader = getDriverByPos(1)
        -- Access the track node chain to calculate percentage
        if leader and leader.nodeChain and leader.currentNode then
            local totalNodes = #leader.nodeChain
            if totalNodes > 0 then
                local leaderNodeIndex = leader.currentNode.id
                
                -- 97% Threshold: Automatically go Green when leader nears the line
                -- This mimics the "Safety Car in this lap" timing
                local startThreshold = totalNodes * 0.97
                
                if leaderNodeIndex > startThreshold then
                    print("RaceManager: Leader reached start zone ("..leaderNodeIndex.."/"..totalNodes.."). GREEN FLAG!")
                    self:setState(STATE_RACING)
                end
            end
        end
    end
    
    -- Check finish condition (Backup check)
    -- (Main finish logic is handled by Leaderboard onLapCross)
end

function RaceManager.setState(self, newState)
    if self.state == newState then return end
    
    print("RaceManager: State changing from", self.state, "to", newState)
    self.state = newState
    
    -- Broadcast new state to all drivers
    self:broadcastCommand({ type = "raceStatus", value = newState })
    
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
        -- Handle status requests
    end
end

function RaceManager.resetRace(self)
    self:setState(STATE_STOPPED)
    self.currentLap = 0
    self.finishResults = {}
    self.qualifyingResults = {}
    -- Reset all drivers
    local drivers = getAllDrivers()
    for _, driver in ipairs(drivers) do
        driver.currentLap = 0
        driver.raceFinished = false
        if driver.resetCar then driver:resetCar(true) end
    end
    if self.RC then self.RC:sv_output_data() end
end