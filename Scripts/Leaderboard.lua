--Leaderboard.lua
-- Handles the timing and scoring of drivers
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
    
    -- 1. SORT BY ABSOLUTE DISTANCE (Meters)
    table.sort(allDrivers, function(a, b)
        local distA = (a.perceptionData and a.perceptionData.Navigation and a.perceptionData.Navigation.totalRaceDistance) or -1.0
        local distB = (b.perceptionData and b.perceptionData.Navigation and b.perceptionData.Navigation.totalRaceDistance) or -1.0
        if distA ~= distB then return distA > distB end
        return (a.id or 0) > (b.id or 0)
    end)
    
    -- 2. CALCULATE SPLITS
    local leaderDist = 0.0
    if allDrivers[1] and allDrivers[1].perceptionData and allDrivers[1].perceptionData.Navigation then 
        leaderDist = allDrivers[1].perceptionData.Navigation.totalRaceDistance or 0.0
        self.leaderID = allDrivers[1].id
    end
    
    for rank, driver in ipairs(allDrivers) do
        driver.racePosition = rank
        
        -- A. GET DISTANCE GAP (Meters)
        local myDist = (driver.perceptionData and driver.perceptionData.Navigation and driver.perceptionData.Navigation.totalRaceDistance) or 0.0
        local distGap = math.max(0.0, leaderDist - myDist)
        
        -- B. CALCULATE SMOOTHED SPEED (for stable time conversion)
        local rawSpeed = 0.0
        if driver.perceptionData and driver.perceptionData.Telemetry then 
            rawSpeed = driver.perceptionData.Telemetry.speed or 0.0
        end
        
        -- Use a "running average" to smooth out braking/acceleration spikes
        -- 0.95 keeps history, 0.05 adds new data (slow moving average)
        driver.avgSpeed = (driver.avgSpeed or rawSpeed) * 0.95 + rawSpeed * 0.05
        
        -- Safety: Don't divide by 0. Assume at least 10 m/s (approx 36kph) for gap calcs
        -- This prevents gaps exploding to "999 seconds" when a car is stopped.
        local calcSpeed = math.max(driver.avgSpeed, 10.0)
        
        -- C. CONVERT TO TIME (Seconds)
        local timeGap = distGap / calcSpeed
        
        -- D. SMOOTH THE TIME GAP ITSELF
        -- Even with smoothed speed, distance can jump. Smooth the final output too.
        driver.smoothGapToLeader = (driver.smoothGapToLeader or timeGap) * 0.9 + timeGap * 0.1
        
        -- E. GAP TO NEXT CAR (Interval)
        if rank == 1 then
            driver.gapToNext = 0.0
        else
            local carAhead = allDrivers[rank - 1]
            local distToNext = (carAhead.perceptionData.Navigation.totalRaceDistance or 0) - myDist
            -- Calculate interval based on MY speed (how long to reach them)
            local timeToNext = distToNext / calcSpeed
            driver.gapToNext = (driver.gapToNext or timeToNext) * 0.9 + timeToNext * 0.1
        end
        
        -- Save for Export (keep old raceSplit as distance for debug if needed)
        driver.raceSplit = distGap 
    end
end

function Leaderboard.onLapCross(self, carID, timestamp, lapTime)
    local driver = getDriverFromId(carID)
    if not driver then return end
    
    driver.lastLap = lapTime 
    if driver.bestLap == 0 or lapTime < driver.bestLap then driver.bestLap = lapTime end
    
    -- Check for Race Finish
    if driver.currentLap > self.RC.RaceManager.targetLaps and not driver.raceFinished then
        driver.raceFinished = true
        driver.finishTime = timestamp
        
        if self.RC.RaceManager.qualifying then 
            self:recordQualifyingResult(driver)
        else 
            table.insert(self.RC.RaceManager.finishResults, self:prepareFinishData(driver)) 
        end
        self:checkRaceCompletion()
    end
end

function Leaderboard.checkRaceCompletion(self)
    -- Optional logic to end race when all cars finish
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
    -- Placeholder for quali logic
end

function Leaderboard.getLeaderboardData(self)
    local data = {}
    local drivers = getAllDrivers()
    table.sort(drivers, function(a,b) return (a.racePosition or 99) < (b.racePosition or 99) end)
    for _, d in ipairs(drivers) do table.insert(data, self:prepareFinishData(d)) end
    return data
end