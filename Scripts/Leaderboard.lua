-- Leaderboard.lua: Handles positions, lap times, sector splits, and scoring.

Leaderboard = class(nil)

function Leaderboard.server_init(self, raceControl)
    self.RC = raceControl
    self.leaderID = nil
end

function Leaderboard.server_onFixedUpdate(self, dt)
    self:updateRealTimePositions()
end

function Leaderboard.updateRealTimePositions(self)
    local allDrivers = getAllDrivers()
    if #allDrivers == 0 then return end
    
    -- Sort drivers based on progress (Lap -> Sector -> Continuous Score)
    table.sort(allDrivers, function(a, b)
        if a.currentLap ~= b.currentLap then
            return a.currentLap > b.currentLap
        end
        
        -- Tie breaker using perception data (continuous position)
        local scoreA = a.perceptionData and a.perceptionData.Navigation and a.perceptionData.Navigation.continuousPositionScore or 0
        local scoreB = b.perceptionData and b.perceptionData.Navigation and b.perceptionData.Navigation.continuousPositionScore or 0
        
        if scoreA ~= scoreB then return scoreA > scoreB end
        return false
    end)
    
    -- Assign Ranks and Calculate Splits
    local leaderScore = 0
    if allDrivers[1] then 
        leaderScore = allDrivers[1].perceptionData and allDrivers[1].perceptionData.Navigation and allDrivers[1].perceptionData.Navigation.continuousPositionScore or 0
    end

    for rank, driver in ipairs(allDrivers) do
        driver.racePosition = rank
        if rank == 1 then 
            self.leaderID = driver.id 
            driver.raceSplit = 0.0
        else
            -- Estimate split based on score difference (1.0 score approx 1 second at avg speed?)
            -- This is a heuristic. Real splits require historical timestamps of nodes.
            local score = driver.perceptionData and driver.perceptionData.Navigation and driver.perceptionData.Navigation.continuousPositionScore or 0
            driver.raceSplit = (leaderScore - score) * 1.5 -- Rough time estimate multiplier
        end
    end
end

function Leaderboard.onLapCross(self, carID, timestamp, lapTime)
    local driver = getDriverFromId(carID)
    if not driver then return end
    
    -- Finalize lap stats
    driver.lastLap = lapTime -- Store locally
    
    if driver.bestLap == 0 or lapTime < driver.bestLap then
        driver.bestLap = lapTime
    end

    -- Check race finish condition
    if driver.currentLap > self.RC.RaceManager.targetLaps and not driver.raceFinished then
        driver.raceFinished = true
        driver.finishTime = timestamp
        
        -- Log final result
        if self.RC.RaceManager.qualifying then
            self:recordQualifyingResult(driver)
        else
            table.insert(self.RC.RaceManager.finishResults, self:prepareFinishData(driver))
        end
        
        -- Check if everyone is done
        self.RC:checkRaceCompletion() 
    end
end

function Leaderboard.onSectorCross(self, carID, sectorID, timestamp)
    local driver = getDriverFromId(carID)
    if not driver then return end

    local lastSectorTime = driver.lastSectorTime or timestamp
    local sectorTime = timestamp - lastSectorTime
    driver.lastSectorTime = timestamp
    
    local finishedSector = sectorID - 1
    if finishedSector == 0 then finishedSector = 3 end 
    
    if not driver.sectorTimes then driver.sectorTimes = {0,0,0} end
    driver.sectorTimes[finishedSector] = sectorTime
end

-- Helpers for Data Export

function Leaderboard.prepareFinishData(self, driver)
    -- This table structure matches what your Python script expects via JSON
    return {
        ['position'] = driver.racePosition,
        ['racer_id'] = driver.id,
        ['name'] = driver.tagText or "Unknown",
        ['best_lap'] = driver.bestLap or 0,
        ['last_lap'] = driver.lastLap or 0, -- ADDED THIS LINE
        ['finishTime'] = driver.finishTime or 0,
        ['split'] = driver.raceSplit or 0,
        ['laps'] = driver.currentLap,
        ['pitting'] = driver.pitState or 0
    }
end

function Leaderboard.recordQualifyingResult(self, driver)
    -- Logic to save quali result (if separate from main finish results)
end

function Leaderboard.getLeaderboardData(self)
    local data = {}
    local drivers = getAllDrivers()
    
    -- Ensure they are sorted by rank before export
    table.sort(drivers, function(a,b) return (a.racePosition or 99) < (b.racePosition or 99) end)

    for _, d in ipairs(drivers) do
        table.insert(data, self:prepareFinishData(d))
    end
    return data
end