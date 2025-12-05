
function getCollisionAvoidanceSteer(vhDif)
    local newSteer = 0
    if vhDif['vertical'] < 0 and vhDif['vertical'] > -10 then -- if intersection is behind midpoint of car
        if vhDif['horizontal'] > 0 then -- car is on right
            newSteer = ratioConversion(-6,2,-0.22,0,vhDif['horizontal'])--/(self.followStrength/1.5)   --TODO: figure out if getting passed/attack/defend?
        else -- brake
            --newSteer = ratioConversion(6,-2,0.22,0,vhDif['horizontal'])
        end
    else -- if intersection is in front possibly make it turn less hard?
        if vhDif['horizontal'] > 0 then -- car is on right
            newSteer = ratioConversion(-6,2,-0.12,0,vhDif['horizontal'])--/(self.followStrength/1.5)   --TODO: figure out if getting passed/attack/defend?
        else -- slowdown
            --newSteer = ratioConversion(6,-2,0.12,0,vhDif['horizontal'])
        end
    end
    return newSteer
end

function calculateCollisionMove(pointName,vhDif,opponent) -- move to global?
    local accel = 0
    local steer = 0
    -- if corner is frontleft 
    if pointName == "fl" then
        --print("fl",vhDif)
        if vhDif['vertical'] < 0 and vhDif['vertical'] > -10 then -- if point behind midpoint of car
            if vhDif['horizontal'] > 0 then -- car is on right side of midpoint
                newSteer = ratioConversion(0,5,0.2,0,vhDif['horizontal']) -- should turn sharper the closer to 0
                print("Steer avoidance right",vhDif['horizontal'],newSteer)
                --steer  = getCollisionAvoidanceSteer(vhDif)
            end
        end
        --print("Got steer FL",vhDif,steer)
    elseif pointName == "fr" then
        --print("fr",vhDif)
        if vhDif['vertical'] < 0 and vhDif['vertical'] > -10 then -- if point behind midpoint of car
            if vhDif['horizontal'] < 0 then -- car is on right side of midpoint
                newSteer = ratioConversion(-5,0,0,0.2,vhDif['horizontal']) -- should turn sharper the closer to 0
                print("Steer avoidance left",vhDif['horizontal'],newSteer)
                --steer  = getCollisionAvoidanceSteer(vhDif)
            end
        end

    elseif pointName == "bl" then -- dont need to do much
    elseif pointName == "br" then -- also not important
    end


    return accel,steer
end


function Driver.newUpdateCollisionLayer(self)-- -- New updated collision layer
    if self.carData == nil then return end -- not scanned
    --print(self.carData.carDimensions)
    if self.carData.carDimensions == nil then return end -- not scanned
    if self.engine == nil then return end
    if self.engine.engineStats == nil then return end -- Do validattion instead?

    local colThrottle = self.strategicThrottle
    local colSteer = self.strategicSteering
    local passSteer = 0 -- add on to colSteer
    local oppInRange = {}--self.opponentFlags -- possibly attatch to self so no regeneration necessary?
    local selfWidth = self.leftColDist + self.rightColDist
    local hasDraft = false
    local carsInRange = getDriversInDistance(self,60) -- also accounts for draft may be too 
    
    local timeScaleMultiplier = 0.5 -- ~1 second lookahead (adjustable) (40 iterations per second)
    local collisionPadding = 2 -- additional space  multiplier given to radar/collision > 1 for grow, < 1 for shrink
    local futurePosition = self.location + (self.velocity * timeScaleMultiplier) -- get future location
    self.futureLocation = futurePosition
    --print("future",self.location,self.velocity,futurePosition)
    local selfCollisionBox = generateBounds(futurePosition,self.carDimensions,self.shape:getAt(),self.shape:getRight(),collisionPadding)
    -- make effect for debug
    --print(self.fflEffect)
    self.fflEffect.pos = selfCollisionBox[1].position
    self.ffrEffect.pos = selfCollisionBox[2].position
    self.fblEffect.pos = selfCollisionBox[3].position
    self.fbrEffect.pos = selfCollisionBox[4].position

    local centerLocation = getCarCenter(self) -- returns center of car

    if carsInRange == nil then -- No cars go home
        if self.passing.isPassing then
            self:cancelPass()
        end
        if self.drafting then
            self.drafting = false
        end
        return 
    end
    
    for k=1, #carsInRange do local opponent=carsInRange[k] -- May need to have deep copy of carsInrange or create new class
        if opponent.carDimensions == nil then
            --self:sv_sendAlert("Car ".. self.id .. " Not Scanned; Place on Lift")
            break
        end
        local opDir = opponent.shape:getAt()
        local opFuturePos = opponent.location + (opponent.velocity * timeScaleMultiplier)
        local opCollisionBox = generateBounds(opFuturePos,opponent.carDimensions,opDir,opponent.shape:getRight(),collisionPadding)
        local centerLocation = getCarCenter(self) -- returns center of car
        local collisionPotential = getCollisionPotential(selfCollisionBox,opCollisionBox)
        if collisionPotential == false then 
            break -- no collision potential
        else
            local intersectPoint = selfCollisionBox[collisionPotential]
            local intersectVH = getPointRelativeLoc(centerLocation,intersectPoint['position'],opDir)
            --print(self.id,collisionPotential,intersectPoint['name'],intersectVH)
            local accel,steer = calculateCollisionMove(intersectPoint['name'],intersectVH,opponent) -- dont need opponent
            --print("Got",accel,steer, "to avoid car")
        end

    end
    --self.strategicThrottle = colThrottle
    --self.strategicSteering = self.strategicSteering + colSteer + passSteer
end

-- Updating methods (layers and awhat not)
function Driver.updateCollisionLayer(self)
    if self.carData == nil then return end -- not scanned
    --print(self.carData.carDimensions)
    if self.carData.carDimensions == nil then return end -- not scanned
    if self.engine == nil then return end
    if self.engine.engineStats == nil then return end -- Do validattion instead?
    --if self.speed < 5 then return end -- too slow
    local carsInRange = getDriversInDistance(self,70) -- gets list of all cars within certain distanvce
    if carsInRange == nil then -- No cars go home
        if self.passing.isPassing then
            self:cancelPass()
        end
        if self.drafting then
            self.drafting = false
        end
        return 
    end
    --print(self.opponentFlags)
    -- GEnerate Flag structure
    local colThrottle = self.strategicThrottle
    local colSteer = self.strategicSteering
    local passSteer = 0 -- add on to colSteer
    local oppInRange = {}--self.opponentFlags -- possibly attatch to self so no regeneration necessary?
    local selfWidth = self.leftColDist + self.rightColDist
    -- set up local car radar (big values )
    self.carRadar = {
        front = 100,
        rear = -100,
        right = 100,
        left = -100
    }
    
    local alongSideLeft = -100
    local alongSideRight = 100 

    local hasDraft = false

    for k=1, #carsInRange do local opponent=carsInRange[k] -- May need to have deep copy of carsInrange or create new class
        if opponent.carDimensions == nil then
            --self:sv_sendAlert("Car ".. self.id .. " Not Scanned; Place on Lift")
            break
        end
        if opponent.rearColDist == nil or opponent.frontColDist == nil then
            break
        end
        --local distance = getDriverDistance(self,opponent,#self.nodeChain) -- TODO: Remove cuz obsolete?
        local vhDist = getDriverHVDistances(self,opponent)
        local oppWidth
        if opponent.leftColDist == nil or opponent.rightColDist == nil then
            oppWidth = selfWidth
        else 
            oppWidth = (opponent.leftColDist + opponent.rightColDist) or selfWidth -- in case oppwidth is broken
        end
        if vhDist['vertical'] < 100 or vhDist['vertical'] > -25 then -- ??
            if oppInRange[opponent.id] == nil then
                oppInRange[opponent.id] ={data = opponent, inRange = true,  vhDist = {}, flags = {frontWatch = false,frontWarning = false, frontEmergency = false,
                                            alongSide = false, leftWarning = false,rightWarning = false,leftEmergency = false,rightEmergency = false,
                                            pass = false, letPass = false, drafting = false                 
            }}
            else
                oppInRange[opponent.id].flags.inRange = true
            end
        else
            if oppInRange[opponent.id] == nil then
                oppInRange[opponent.id] ={data = opponent, inRange = false, vhDist = {}, flags = {frontWatch = false,frontWarning = false, frontEmergency = false,
                alongSide = false, leftWarning = false,rightWarning = false,leftEmergency = false,rightEmergency = false,
                pass = false, letPass = false, drafting = false,  }}
            else
                oppInRange[opponent.id].inRange = false -- Sets everything to false to reset
                oppInRange[opponent.id].flags = {frontWatch = false,frontWarning = false, frontEmergency = false,
                alongSide = false, leftWarning = false,rightWarning = false,leftEmergency = false,rightEmergency = false,
                pass = false, letPass = false, drafting = false   }
            end
        end
        --obsoleteVHDistances(self,opponent)
        if vhDist == nil then break end -- send error?
        oppInRange[opponent.id].vhDist = vhDist -- send to opp

        local frontCol = nil
        local rearCol = nil
        local leftCol = nil
        local rightCol = nil

        if vhDist['horizontal'] > 0 then -- opponent on right
            rightCol = vhDist['horizontal'] - (self.rightColDist + (opponent.leftColDist or self.leftColDist))
        elseif  vhDist['horizontal'] <= 0 then -- opponent on left
            leftCol = vhDist['horizontal'] + (self.leftColDist + (opponent.rightColDist or self.rightColDist)) -- Failsaif to its own width
            -- if leftCol >= 0 then print("danger on left?")
        end



        if vhDist['vertical'] > 0 then -- if opponent in front 
            frontCol = vhDist['vertical'] - (self.frontColDist + (opponent.rearColDist or self.rearColDist))
        elseif vhDist['vertical'] <=0 then -- if opp behind 
            rearCol = vhDist['vertical'] + (self.rearColDist + (opponent.frontColDist or self.frontColDist))
            --if rearCol >= 0 then print("danger from behind") end
        end


        -- update localRadar
       if frontCol then
            if frontCol < self.carRadar.front then
                self.carRadar.front = frontCol
            end
       else
            self.carRadar.front = 100
       end
       
       if rearCol then
        if rearCol > self.carRadar.rear then
            self.carRadar.rear = rearCol
        end
        else
            self.carRadar.rear = -100
        end

       if leftCol then
        if leftCol > self.carRadar.left then
            self.carRadar.left = leftCol
        end
        else
            self.carRadar.left = -100
            --oppFlags.leftWarning = false
        end

       if rightCol then
        if rightCol < self.carRadar.right then
            self.carRadar.right = rightCol
        end
        else
            self.carRadar.right = 100
            --oppFlags.rightWarning = false
        end
       
        local oppFlags = oppInRange[opponent.id].flags
        if frontCol and frontCol < 70 then -- In draft range? (globals.draftRange)
            if (rightCol and rightCol <0.2) or (leftCol and leftCol > -0.2) then -- If overlapping (a little margin)
                oppFlags.drafting = true
                hasDraft = true
                --print(self.id,opponent.id,"hasDraft",hasDraft,oppFlags.drafting)
            else
                oppFlags.drafting = false
            end
        end
        
        if frontCol and frontCol < 50 and frontCol > 10 then -- somewhat close
            if self.speed - opponent.speed  > 1 then -- moving 1 faster ?
                if (rightCol and rightCol <0) or (leftCol and leftCol > -0) then -- If overlapping
                    oppFlags.frontWatch = true
                else
                    oppFlags.frontWatch = false
                end
            else
                oppFlags.frontWatch = false -- good idea??
            end
        else
            oppFlags.frontWatch = false
        end

        if frontCol and frontCol <= 20 then -- even closer, check for passing
            if self.speed - opponent.speed > 0.2 then -- if approaching 
                if (rightCol and rightCol <0) or (leftCol and leftCol > -0) then -- If overlapping, Makke separate flag?
                    local catchDist = self.speed * vhDist['vertical']/(self.speed-opponent.speed) -- vertical dist *should* be positive and
                    local brakeDist = getBrakingDistance(self.speed*2,self.mass,self.engine.engineStats.MAX_BRAKE/2,opponent.speed) * 2.5 -- dampening? make variable
                    --print("catchDist",catchDist-brakeDist) --TODO: Check this??
                    if catchDist - brakeDist < 18 and catchDist - brakeDist >0 then -- and greater than 0?
                        oppFlags.frontWarning = true -- check for passing
                    else
                        oppFlags.frontWarning = false
                    end
                else
                    oppFlags.frontWarning = false
                end
            else
                oppFlags.frontWarning = false
            end
        else
            oppFlags.frontWarning = false
        end
        
        if frontCol and frontCol < 2.9 then -- if real close use 0?
            if (rightCol and rightCol <0) or (leftCol and leftCol > 0) then -- If overlapping
                --print(self.tagText,"FrontEmerg",frontCol,self.passing)
                oppFlags.frontEmergency = true
            else
                oppFlags.frontEmergency = false -- good idea??
            end
        else
            oppFlags.frontEmergency = false

        end

        if rearCol and rearCol < -2 then
            --print("car behind",rearCol)
            if oppFlags.pass then
                --print("Pass complete")
                if self.passing.isPassing then
                    --print("stoppass")
                    oppFlags.pass = false
                    self:cancelPass()
                else
                    --print("unmatched pass???")
                end
                oppFlags.pass = false
            end
        end
        --print(frontCol,rearCol,oppFlags.frontEmergency,oppFlags.frontWarning)
-- Set & process flags & pass ( side)
        if (frontCol and frontCol <= 1.8) or (rearCol and rearCol >=0.4) then -- if car really close
            if (leftCol and leftCol <= 0.05) or (rightCol and rightCol >= -0.05) then
                oppFlags.alongSide = true
                if leftCol and leftCol > -selfWidth then
                    --print("car blcokingLeft",leftCol)
                    if leftCol > alongSideLeft then
                        alongSideLeft =  leftCol
                    end 
                end

                if rightCol and rightCol < selfWidth then
                    --print("car blcokingRight",rightCol)
                    if rightCol < alongSideRight then
                        alongSideRight = rightCol
                    end
                end

            else
                oppFlags.alongSide = false
            end

            if (leftCol and leftCol >= -6) then
                oppFlags.leftWarning = true
            else
                oppFlags.leftWarning = false
            end

            if (rightCol and rightCol <= 6) then
                oppFlags.rightWarning = true
            else
                oppFlags.rightWarning = false
            end
    
            if (leftCol and leftCol >=-0.6) then
                oppFlags.leftEmergency = true
             else
                oppFlags.leftEmergency = false
            end

            if (rightCol and rightCol <= 0.6) then
                oppFlags.rightEmergency = true
             else
                oppFlags.rightEmergency = false
             end
       
        else -- no warnings here
            oppFlags.rightWarning = false
            oppFlags.leftWarning = false
            oppFlags.rightEmergency = false
            oppFlags.leftEmergency = false
            oppFlags.alongSide = false -- ?
        end
        --print(self.tagText,"",frontCol,rearCol,leftCol,rightCol)
        if (frontCol or 0) <= -0.6 or (rearCol or 0) >= 0.6  then -- if car abnormally close/overlapping?
            --print(self.tagText,"close vertical",leftCol,rightCol,frontCol,rearCol)
            if (leftCol or 0) >= 0.7 or  (rightCol or 0) <= -0.7 then
                --print(self.tagText,"Collision with Opp",frontCol,rearCol,leftCol,rightCol)
                -- check if speed < 4
                if self.speed < 5 then -- double check disparity between speed and desired speed
                    --print(self.tagText,"Bad collision likely",self.shape.worldPosition.z,self.currentNode.mid.z,self.stuck,self.stuckTimeout)
                    -- check if z index is high
                    if self.shape.worldPosition.z > self.currentNode.mid.z + 2 or (self.stuck and self.stuckTimeout >= 5) then
                        --print(self.tagText,"Horrendus collision detected")
                        if self.carResetsEnabled then
                            print(self.tagText,"resetting colided car")
                            -- add check clearTrack
                            --self.lost = true
                            self:resetPosition(true)
                        end
                    end
                end
            end
        end
   --[[Pass calculations print("could pass?")
                self.passCommit = self:calculateClosestPassPoint(opponent,vhDist)
                local passDirection = self.passCommit
                if passDirection == 0 then
                    self.passCommit = 0
                    local testThrot = 0.9- math.abs(vMax/self.speed) 
                    if testThrot < colThrottle then
                        print("warning eadjust",testThrot)
                        colThrottle = testThrot
                    end
                    --print("EMERGENCY PASS FAILURE")
                else
                    self.goalOffset = self:calculateGoalOffset(oppInRange[opponent.id],passDirection)
                    self.passing.isPassing = true
                    elf.passing.carID = opponent.id
                    print("Start warning p[ass",passDirection) -- potentially set flag for ePass?
                    oppFlags.pass = true]]

                    --[[Emergency pass calculationsself.passCommit = self:calculateClosestPassPoint(opponent,vhDist)
                    local passDirection = self.passCommit
                    if passDirection ~= 0 then -- This is an emergency pass, execute if possible
                        self.goalOffset = self:calculateGoalOffset(oppInRange[opponent.id],passDirection)
                        print("ePass start",passDirection)
                        eThrot = 0.99 - math.abs(vMax/self.speed)
                        self.passing.isPassing = true
                        oppFlags.pass = true
                    else
                        if self.passing.isPassing and self.speed - vMax < 0 then
                            print("epassFail")
                            self:cancelPass()
                            oppFlags.pass = false
                        end
                        print("ebrake1")
                        eThrot = 0.80- math.abs(vMax/self.speed)
                    end]]
        
        -- TODO: ADD YELLOW FLAGS Stopped cars will add global yellow flags with segID and trackPos

        -- Process and execute flags
    

        if oppFlags.frontWatch then
            local vMax =opponent.speed
            local eThrot = colThrottle
            if self.speed - opponent.speed > 8 or opponent.speed < 9 then
                --print("Approaching front fast",self.speed,opponent.speed)
                eThrot = eThrot - 1
                --print("emergency brake")
                if self.passing.isPassing or oppFlags.pass then --and vhDist['vertical'] < 7 then -- TODO: determine if this is correct decision, dont cancel pass if opp is far away
                    --print("canceled pass emergency pass")
                    self:cancelPass()
                    oppFlags.pass = false
                end
            end
        end
         

        if oppFlags.frontWarning and not self.passing.isPassing then
            if self.speed - opponent.speed > 0.2 and frontCol < 20 then
                local vMax =opponent.speed - 0.3
                --print("could pass?")
            end
        end
        if oppFlags.frontEmergency then
            --print("ftooo close",frontCol,oppFlags.alongSide,self.passing.isPassing,oppFlags.pass)
        end
        if oppFlags.frontEmergency and not oppFlags.alongSide then--and not passing? oppFlags.pass
            local vMax =opponent.speed-4
            local eThrot = colThrottle
            if frontCol > 0 and frontCol <= 8 then
                if self.speed - vMax > 0.1 and not oppFlags.pass then -- make smooth ratio instead? -- maybe have closer range? and not self.passing.isPassing?
                    --print(self.tagText,"AlertClose ") -- TODO: FIX emergency comes up while already passing, make sure car isnt being passed (oppFlags.pass?)
                    eThrot = 0.90- math.abs(vMax/self.speed) 
                else
                    if oppFlags.pass then -- maybe add pass ID(s) to self.passing.isPassing flag to cancel from outside of function too
                        if self.passing.isPassing and self.speed - vMax < 0 then
                            self:cancelPass()
                            --print("epassFail2")
                            oppFlags.pass = false
                        end
                    else
                        if self.passing.isPassing then
                            --print(self.tagText,"pasCancel?")
                            --print("oppPass but not self.pass")
                            oppFlags.pass = false
                        end
                        eThrot = 0.75- math.abs(vMax/self.speed) 
                        --print(self.tagText,"ebrake2",oppFlags.pass,self.passing.isPassing)
                    end
                end
            else -- way too close
                eThrot = 0.9- math.abs(vMax/self.speed)
                --print(self.tagText,"ebrake3",eThrot)
                if oppFlags.pass then
                    oppFlags.pass = false
                end
                if self.passing.isPassing then
                    --print("canceling pass")
                    self:cancelPass()
                    oppFlags.pass = false
                end
                --print(self.id,"ebrake",self.curGear,self.engine.VRPM,eThrot)
                --colSteer = colSteer + 0.01 -- or whichever inside is
            end

            if eThrot < colThrottle then
                colThrottle = eThrot
            end
            
        end

        if oppFlags.leftWarning and leftCol ~= nil then -- multiply by opposite if car is behind
            --colSteer = colSteer + 1/(leftCol*10) negative-- Divide by speed?
            colSteer = colSteer + ratioConversion(-6,2,-0.13,0,leftCol)--/(self.followStrength/1.5)   --TODO: figure out if getting passed/attack/defend?
            if self.carAlongSide.right ~= 0 then
                colSteer = colSteer/3
            end
            --print(self.tagText,"leftColSteer",colSteer,leftCol)
        end
        if oppFlags.rightWarning and rightCol ~= nil then
            --colSteer = colSteer +  1/(rightCol*10) positive
            colSteer = colSteer + ratioConversion(6,-2,0.13,0,rightCol)--/(self.followStrength/1.5)  -- Convert x to a ratio from a,b to  c,d
            if self.carAlongSide.left ~= 0 then
                colSteer = colSteer/3
            end
            --print(self.tagText,"righColSteer",colSteer,rightCol)
        end

        if oppFlags.leftEmergency then
            --colSteer = colSteer + 1/(leftCol*20)-- adjust to 
        end
        if oppFlags.rightEmergency then
            --colSteer = colSteer +  1/(rightCol*20) -- figure out adjust
        end
        if self.strategicSteering ~= colSteer then

        end
        if self.passing.isPassing then
            colSteer = colSteer/1.4 
        else
            colSteer = colSteer/1.1
        end

        
        -- Real Passing ALGo
        local catchDist = self.speed * vhDist['vertical']/(self.speed-opponent.speed) -- vertical dist *should* be positive and
        local brakeDist = getBrakingDistance(self.speed*2,self.mass,self.engine.engineStats.MAX_BRAKE/2,opponent.speed) -- dampening? make variable
        -- TODO: CHeck this^
        local vMax =opponent.speed
        if vhDist['vertical'] > -1 then
            --print(catchDist,brakeDist,catchDist-brakeDist)
        end
        if vhDist['vertical'] - (self.frontColDist + opponent.rearColDist) >=0  and vhDist['vertical'] < 30 then -- if opponent is somewhat close
            --print(self.tagText,"check pass?",self.speed-opponent.speed)
            if (self.speed-opponent.speed) > 0.5 then --and vhDist['vertical'] - (self.frontColDist + opponent.rearColDist) < 14 then -- if catching ish
                --print(self.id,"approaching",self.speed-opponent.speed,oppFlags.pass,self.passing.isPassing)
                if not oppFlags.pass and not self.passing.isPassing then 
                    --print(self.id,vhDist['vertical'] - (self.frontColDist + opponent.rearColDist),self.carRadar.front)
                    if vhDist['vertical'] - (self.frontColDist + opponent.rearColDist) <= self.carRadar.front then -- if this is the closest, maybe not
                        --print(self.tagText,"Can potentially pass",catchDist,brakeDist)
                        local passDirection = self:checkPassingSpace(opponent)
                        if passDirection ~= 0 then 
                            self.passCommit = passDirection
                            --print(self.tagText,"commiting pass",passDirection,vhDist['vertical'])
                            self.goalOffset = self:calculateGoalOffset(oppInRange[opponent.id],passDirection)
                            --print(self.tagText,"->",opponent.tagText,vhDist['vertical'],self.carRadar.front,self.carRadar.front - (vhDist['vertical'] - (self.frontColDist + opponent.rearColDist)))
                            -- double check that opponent is proper one
                            if (self.carRadar.front - (vhDist['vertical'] - (self.frontColDist + opponent.rearColDist)) ~= 0) then
                                print(self.tagText,"not closes racer to pass",self.carRadar.front - (vhDist['vertical'] - (self.frontColDist + opponent.rearColDist)))
                            end
                            self.passing.isPassing = true
                            self.passing.carID = opponent.id
                            oppFlags.pass = true -- Maybe make passing function?
                        else 
                            --print(self.id,"subprime pass point",vhDist['vertical'],passDirection)
                            self.passCommit = 0
                            oppFlags.pass = false
                            if oppFlags.frontWarning then
                                local testThrot = 0.9- math.abs(vMax/self.speed) 
                                if testThrot < colThrottle then
                                    --print("warning eadjust",testThrot)
                                    colThrottle = testThrot
                                end
                            end
                            --print("EMERGENCY PASS FAILURE")
                        end
                    end -- else: the car is not the closest
                else -- If already passing (midpass)
                    local space = self:confirmPassingSpace(opponent,self.passCommit)
                    --print(self.id,"midPass",space,vhDist.vertical)
                    if vhDist.vertical > 15 or vhDist.vertical < -1 then
                        if oppFlags.pass then
                            --print("dont pass this?")
                            oppFlags.pass = false
                            self:cancelPass()
                        else
                            if self.passing.isPassing then
                                --print("mismatch pass cancel")
                                self:cancelPass()
                            end
                        end
                    end
                    if space ~= self.passCommit then
                        if vhDist.vertical > 7 then
                            --print("cancelpass spaceChange",self.carRadar.front,space)
                            oppFlags.pass = false
                            self:cancelPass()
                        else
                            --print("too late now lol",vhDist.horizontal) -- either keep going or slow down depending on next turn?
                            if vhDist.horizontal > -1 or vhDist.horizontal < 1 then
                                if (self.carAlongSide.left == 0 and self.carAlongSide.right == 0) then
                                    colThrottle = colThrottle - 0.05
                                    --print("nowheretogo slow")
                                    oppFlags.pass = false
                                    self:cancelPass()
                                else
                                    --print("cahrgeAhead")
                                end
                            end
                        end
                    else
                        --passSteer =0 --self:calculatePassOffset(opponent,self.passCommit,vhDist)
                        self.goalOffset = self:calculateGoalOffset(oppInRange[opponent.id],self.passCommit)
                    end
                end
            else
                --print(self.id,"Not Catching")
                if oppFlags.pass then
                    oppFlags.pass = false
                    self:cancelPass()
                else
                    self:cancelPass()
                end

            end
        else-- Keep eye on car, check speed dif
            if (self.speed-opponent.speed) > 3 and vhDist['vertical'] > 0 then -- look for closest space
                --print("approaching car fast")
                local passDirection = self:calculateClosestPassPoint(opponent)
                local passDirection = self.passCommit
                if passDirection ~= 0 then -- This is an emergency pass, execute if possible
                    self.passCommit = passDirection
                    self.goalOffset = self:calculateGoalOffset(oppInRange[opponent.id],passDirection)
                    --print("ePass start",passDirection)
                    eThrot = 0.99 - math.abs(vMax/self.speed)
                    --print(self.tagText,"set passing emergency",opponent.tagText)
                    self.passing.isPassing = true
                    self.passing.carID = opponent.id
                    oppFlags.pass = true
                else
                    if self.passing.isPassing and self.speed - vMax < 0 then
                        print("epassFail")
                        self:cancelPass()
                        oppFlags.pass = false
                    end
                    --print("ebrake1")
                    eThrot = 0.75 - math.abs(vMax/self.speed)
                end
            end
        end

    end
    if self.passing.isPassing then
        --print(self.id,"midPass",self.passing.carID)
        if self.opponentFlags[self.passing.carID] ~= nil then
            local passCarData = self.opponentFlags[self.passing.carID]
            --print(self.id,passCarData.vhDist)
            if passCarData.vhDist.vertical > 15 or passCarData.vhDist.vertical < -1 then
                
                if passCarData.pass then
                    passCarData.pass = false
                    self:cancelPass()
                else
                    --print(self.id,"pass Complete?",passCarData.pass)
                    self:cancelPass()
                end
            end
        else
            --print("oppGone???")
            self:cancelPass()
        end
    end

    --print(self.id,getRaceControl().draftingEnabled)
    if not self.raceControlError then
        if getRaceControl().draftingEnabled then
            if hasDraft then
                if (self.caution or self.formation) then -- deny draft due to caution and what not
                else
                -- print(self.id,"HS",self.id,hasDraft)
                    self.drafting = true
                end
            else
                self.drafting = false
            end
        else
            self.drafting = false
        end
    end

    if self.carRadar.front > 70 then -- also post pass check? 
        if self.drafting then
            --print("false draft",self.id)
            --self.drafting = false
        end
    end
    --print(self.id,self.goalOffset)
    if self.passing.isPassing then
        --print(self.id,"passing")
    end

    -- Alongside stuff
    if alongSideLeft >-100 then
        self.carAlongSide.left = alongSideLeft
    else
        self.carAlongSide.left = 0
    end

    if alongSideRight < 100 then
        --print("reset alongside")
        self.carAlongSide.right = alongSideRight
    else
        self.carAlongSide.right = 0
    end


    self.strategicThrottle = colThrottle
    self.strategicSteering = self.strategicSteering + colSteer + passSteer
    --print("passSteer and stratSteer",self.strategicSteering,colSteer,passSteer)
    self.opponentFlags = oppInRange
    --print(oppInRange)

end

-- Passing functionality
function Driver.cancelPass(self) -- cancels passing
    --print("cancelPass",self)
    self.passing.isPassing = false
    self.passing.carID = nil
    self.goalOffset = nil
    self.passCommit = 0 
end

function Driver.checkPassingSpace(self,opponent) -- calculates the best direction to pass -1 = left, 1 = right, 0 = nope.. bigger numbers will represent confidence level
    --if  (self.caution or self.formation) then return 0 end
    if not self.currentNode then return 0 end
    if not opponent then return 0 end
    if not opponent.currentNode then return 0 end -- Consolidate to validation function?
    if not self.futureLook or self.futureLook.direction == nil then return 0 end
    local passEligible = true
    local passDir = 0
    local oppDist = getDriverHVDistances(self,opponent)
    local oppDist = oppDist.vertical
    if oppDist <=4 then -- Maximum  margin will be at 1
        oppDist = 4
    end

    if self.safeMargin then -- prevent crazy passes?
        passeligible = false
    end

    -- CHeckk if on straight/ going to turn depending on aggressive state
    if self.currentNode.segType == "Straight" then
        --print("onstraight",self.futureLook.distance)
        if self.futureLook.distance > 45 then
            --print('Eigible pass?',self.futureLook.distance)
            passEligible = true
        end
    end


    local marginRatio = ratioConversion(15,4,-0.6,-3,oppDist) -- Convert x to a ratio from a,b to  c,d
    local turnDir = getSign(self.futureLook.direction)
    local oppTPos = opponent.trackPosition -- OOOR Just take the opponents distance from left/right wall
    local width = (opponent.currentNode.width or 20)
    local oppWidth = (opponent.leftColDist + opponent.rightColDist)
    local selfWidth = self.leftColDist + self.rightColDist
    local margin = self.passAggression + marginRatio --if distance is greater, aggression is smaller
    --print("margin",margin,((width/2) - oppTPos - oppWidth) + margin)
    if turnDir == 1 then -- turning right
        local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
        if spaceLeft < selfWidth then
            --print("No room on inside")
        else
            if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside
                if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                    --print("Passing on inside")
                    passDir = 1
                else 
                    --print("car on your inside")
                end
            else
                --print("Car blocking inside") -- Could check for room past the car on inside?
                local laneWidth = width/3 
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('checking for three wide')
                    passDir = 1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= 1 then -- if a decision wasnt made check the other side for room
            spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        --print("Passing on outise")
                        passDir = -1
                    else
                        --print("car on your outside")
                    end
                else
                    local laneWidth = width/3 
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print('checking for three wide')
                        passDir = -1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    elseif turnDir == -1 then -- turning left
        local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
        if spaceLeft < selfWidth then
            --print("No room on inside (left)")
        else
            if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                    --print("Passing on inside")
                    passDir = -1
                else
                    --print("car on your inside")
                end
            else
                local laneWidth = width/3 
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('checking for three wide')
                    passDir = -1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= -1 then -- if a decision wasnt made check the other side for room
            spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside (right)")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                    --print("Passing on outside")
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        --print("Passing on inside")
                        passDir = 1
                    else
                        --print("car on your inside")
                    end
                else
                    local laneWidth = width/3 
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print('checking for three wide')
                        passDir = 1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    else
        
        passDir = self:calculateClosestPassPoint(opponent) -- default to left turn? maybe test oval
        --print("No Upcoming turns",passDir)
    end
    
    if passDir == 0 or passEligible == false then -- no decisions made
       passDir = 0

    end
    --print(self.tagText,"Passing space",passDir)  
    return passDir
end

function Driver.calculateClosestPassPoint(self,opponent) -- oppLoc = diver vh dist
    --if  (self.caution or self.formation) then return 0 end
    if not self.currentNode then return 0 end
    if not opponent then return 0 end
    if not opponent.currentNode then return 0 end    local oppTPos = opponent.trackPosition -- OOOR Just take the opponents distance from left/right wall
    local oppLoc
    if self.opponentFlags[opponent.id] ~= nil then
        oppLoc =  self.opponentFlags[opponent.id].vhDist
    else
        --print("could not find opp in flags")
        return 0 
    end
    local width = (opponent.currentNode.width or 20)
    local oppWidth = (opponent.leftColDist + opponent.rightColDist)
    local selfWidth = self.leftColDist + self.rightColDist
    local optimalDir = getSign(oppLoc.horizontal) -- easiest direction to move
    local mostSpace = -getSign(self.trackPosition) -- more space to move
    local margin = -0.5

    if optimalDir == mostSpace and optimalDir == 1 then -- the world aligns to the right
        local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
        if spaceLeft > selfWidth then
            if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside
                if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                    passDir = 1
                end
            end
        end
        if passDir ~= 1 then -- check other side
            spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  - 2 -- bigger margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        passDir = -1
                    end
                end
            end
        end
    elseif optimalDir == mostSpace and optimalDir == -1 then -- best to move left
        local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
        if spaceLeft > selfWidth then
            if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                    passDir = -1
                end
            end
        end
        -- check other side
        if passDir ~= -1 then -- if a decision wasnt made check the other side for room
            spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        passDir = 1
                    end
                end
            end
        end
    else
        -- DO next best execution
        if optimalDir == 1 then -- easiest to go to right
            local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        passDir = 1
                        --print("Yeet Right")
                    end
                end
            end
            if passDir ~= 1 then -- check other side
                spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  - 2 -- bigger margin
                if spaceLeft > selfWidth then
                    if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                        if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                            passDir = -1
                            --print(" Yolo left")
                        end
                    end
                end
            end
        elseif optimalDir == -1 then -- best to move left
            local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
            if spaceLeft > selfWidth then
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        passDir = -1
                        --print("yeet left")
                    end
                end
            end
            if passDir ~= -1 then -- check other side
                spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
                if spaceLeft > selfWidth then
                    if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                        if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                            passDir = 1
                            --print(" yolo right")
                        end
                    end
                end
            end
        end
    end
    if passDir == 0 then -- no room??
        print("No yolo")
        if self.trackPosition > 0 then
            --print("Yolo Left")
            --passDir = -1
        else
            --print("yolo right")
           -- passDir = 1
        end
        --passDir = 0
    end

    if passDir == 0 then -- no decisions made
       --print("Stuck in middle Yolo",passDir)
    end  
    --print(self.tagText,"Closest patt",passDir) 
    return passDir
end

function Driver.confirmPassingSpace(self,opponent,dir) -- checks if the previus committed space is still availible
    --if  (self.caution or self.formation) then return 0 end
    if not self.currentNode then return 0 end
    if not opponent then return 0 end
    if not opponent.currentNode then return 0 end -- Consolidate to validation function?
    local passDir = 0
    local oppDist = getDriverHVDistances(self,opponent)
    local oppDist = oppDist.vertical
    if oppDist <=4 then -- Maximum  margin will be at 1
        oppDist = 4
    end
    local marginRatio = ratioConversion(15,4,-0.6,-3,oppDist) -- Convert x to a ratio from a,b to  c,d
    
    local oppTPos = opponent.trackPosition -- OOOR Just take the opponents distance from left/right wall
    local width = (opponent.currentNode.width or 20)
    local oppWidth = (opponent.leftColDist + opponent.rightColDist)
    local selfWidth = self.leftColDist + self.rightColDist
    local margin = self.passAggression + marginRatio --if distance is greater, aggression is smaller
    local laneWidth = width/3 

    --print("margin",margin,((width/2) - oppTPos - oppWidth) + margin)
    if dir == 1 then -- turning right
        local spaceLeft = ((width/2) - oppTPos - oppWidth) + margin
        if spaceLeft < selfWidth then
            --print("No room on inside")
        else
            if not (opponent.carRadar.right < selfWidth and (opponent.carRadar.front < 1)) then -- room on opponents inside
                if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                    --print("Passing on inside")
                    passDir = 1
                else
                    --print("car on your inside")
                end
            else
                --print("Car blocking inside") -- Could check for room past the car on inside?
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('confirming for three wide')
                    passDir = 1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= 1 then -- if a decision wasnt made check the other side for room
            spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent (may need to figure out how to split difference)
                    if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                        --print("Passing on outise")
                        passDir = -1
                    else
                        --print("car on your outside")
                    end
                else
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print('confirming for three wide')
                        passDir = -1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    elseif dir == -1 then -- turning left
        local spaceLeft = math.abs(-(width/2) - oppTPos + oppWidth)  + margin
        if spaceLeft < selfWidth then
            --print("No room on inside (left)")
        else
            if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on left of opponent
                if self.carAlongSide.left == 0 or self.carAlongSide.left < -selfWidth then -- if no car to your left (may need to mess with negatives?)
                    --print("Passing on inside")
                    passDir = -1
                else
                    --print("car on your inside")
                end
            else
                if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                    --print('confirming for three wide')
                    passDir = -1 -- should then switch over to next opponent eventually
                end
            end
        end
        -- check other side
        if passDir ~= -1 then -- if a decision wasnt made check the other side for room
            spaceLeft = ((width/2) - oppTPos - oppWidth)  + margin
            if spaceLeft < selfWidth then
                --print("No room on outside (right)")
            else
                if not (opponent.carRadar.left > -selfWidth and (opponent.carRadar.front < 0)) then --if there is no car in front/on right of opponent (may need to figure out how to split difference)
                    --print("Passing on outside")
                    if self.carAlongSide.right == 0 or self.carAlongSide.right > selfWidth then -- if no car to your righty
                        --print("Passing on inside")
                        passDir = 1
                    else
                        --print("car on your inside")
                    end
                else
                    if math.abs(opponent.trackPosition) > laneWidth then -- check if possibility for three wide
                        --print('confirming for three wide')
                        passDir = 1 -- should then switch over to next opponent eventually
                    end
                end
            end
        end
    else
        --print("Pass dir confirming 0???") -- maybe add some othe optyion??
    end

    if passDir == 0 then -- no decisions made, cancel the pass
        --print("Stuck in middle",passDir)
    end  
    --print(self.tagText,"pass",passDir)  
    return passDir
end
