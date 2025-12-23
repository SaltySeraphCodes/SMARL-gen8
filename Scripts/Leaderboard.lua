-- Leaderboard.lua
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
    
    table.sort(allDrivers, function(a, b)
        -- [FIX] Safety Checks: Default nil laps to 0
        local lapA = a.currentLap or 0
        local lapB = b.currentLap or 0
        
        if lapA ~= lapB then return lapA > lapB end
        
        -- [FIX] Safety Checks: Deep nil checks for navigation score
        local scoreA = 0
        if a.perceptionData and a.perceptionData.Navigation then
            scoreA = a.perceptionData.Navigation.continuousPositionScore or 0
        end
        
        local scoreB = 0
        if b.perceptionData and b.perceptionData.Navigation then
            scoreB = b.perceptionData.Navigation.continuousPositionScore or 0
        end
        
        if scoreA ~= scoreB then return scoreA > scoreB end
        
        -- Fallback: Sort by ID if scores are identical (prevents jitter)
        return (a.id or 0) > (b.id or 0)
    end)
    
    local leaderScore = 0
    if allDrivers[1] and allDrivers[1].perceptionData and allDrivers[1].perceptionData.Navigation then 
        leaderScore = allDrivers[1].perceptionData.Navigation.continuousPositionScore or 0 
    end
    
    for rank, driver in ipairs(allDrivers) do
        driver.racePosition = rank
        if rank == 1 then 
            self.leaderID = driver.id 
            driver.raceSplit = 0.0
        else
            local score = 0
            if driver.perceptionData and driver.perceptionData.Navigation then
                score = driver.perceptionData.Navigation.continuousPositionScore or 0
            end
            driver.raceSplit = (leaderScore - score) * 1.5 
        end
    end
end

function Leaderboard.onLapCross(self, carID, timestamp, lapTime)
    local driver = getDriverFromId(carID)
    if not driver then return end
    driver.lastLap = lapTime 
    if driver.bestLap == 0 or lapTime < driver.bestLap then driver.bestLap = lapTime end
    if driver.currentLap > self.RC.RaceManager.targetLaps and not driver.raceFinished then
        driver.raceFinished = true
        driver.finishTime = timestamp
        if self.RC.RaceManager.qualifying then self:recordQualifyingResult(driver)
        else table.insert(self.RC.RaceManager.finishResults, self:prepareFinishData(driver)) end
        self:checkRaceCompletion()
    end
end

function Leaderboard.checkRaceCompletion(self)
    -- Logic to detect if all cars finished
end

function Leaderboard.prepareFinishData(self, driver)
    return {
        ['position'] = driver.racePosition,
        ['racer_id'] = driver.id,
        ['name'] = driver.tagText or "Unknown",
        ['best_lap'] = driver.bestLap or 0,
        ['last_lap'] = driver.lastLap or 0, 
        ['finishTime'] = driver.finishTime or 0,
        ['split'] = driver.raceSplit or 0,
        ['laps'] = driver.currentLap,
        ['pitting'] = driver.pitState or 0
    }
end

function Leaderboard.recordQualifyingResult(self, driver)
    -- Logic to save quali result
end

function Leaderboard.getLeaderboardData(self)
    local data = {}
    local drivers = getAllDrivers()
    table.sort(drivers, function(a,b) return (a.racePosition or 99) < (b.racePosition or 99) end)
    for _, d in ipairs(drivers) do table.insert(data, self:prepareFinishData(d)) end
    return data
end