-- SMARL PIT MANAGER -- Handles pit assignments and what not
-- TODO: Store and set/load multi camera positions (save in bp?)
dofile("globalsGen8.lua")
dofile "Timer.lua" 
PitManager = class( nil )
PitManager.maxChildCount = -1
PitManager.maxParentCount = -11
PitManager.connectionInput = sm.interactable.connectionType.logic
PitManager.connectionOutput = sm.interactable.connectionType.logic
PitManager.colorNormal = sm.color.new( 0xffc0cbff )
PitManager.colorHighlight = sm.color.new( 0xffb6c1ff )
local clock = os.clock --global clock to benchmark various functional speeds ( for fun)


function PitManager.client_onCreate( self ) 
	self:client_init()
end

function PitManager.server_onCreate( self )
	self:server_init()
end

function PitManager.client_onDestroy(self)
    
end

function PitManager.server_onDestroy(self)
    --print("Pit manager clearing boxes")
    self:clear_pitBoxes()
    --print("post clear",self.pitBoxes)
end

function PitManager.client_init( self,rc ) 
    if rc == nil then
        print("cl Pit manager has no rc",nil)
    end
    self.raceControl = rc
    self.pitChain = nil 
    self.pitBoxes = nil 

end

function PitManager.server_init(self,rc)
    if rc == nil then
        print("sv Pit manager has no rc",nil)
    end
    self.raceControl = rc
    self.pitChain = nil
    if self.pitBoxes  == nil then 
        self.pitBoxes = nil
    else
        --print("reloading pitboxes",self.pitBoxes)
    end

    self.run = false -- whether to run pitManager orn ot
    self.started = CLOCK()
    print("pit box server init")
end

function PitManager.client_onRefresh( self )
	self:client_onDestroy()
	self:client_init(self.raceControl)
end

function PitManager.server_onRefresh( self )
	self:server_onDestroy()
	self:server_init(self.raceControl)
end



function sleep(n)  -- n: seconds freezes game?
  local t0 = clock()
  while clock() - t0 <= n do end
end

function PitManager.asyncSleep(self,func,timeout)
    --print("weait",self.globalTimer,self.gotTick,timeout)
    if timeout == 0 or (self.gotTick and self.globalTimer % timeout == 0 )then 
        --print("timeout",self.globalTimer,self.gotTick,timeout)
        local fin = func(self) -- run function
        return fin
    end
end

function PitManager.requestPitData(self)
    print("requesting pitbox data")
    local result = self.raceControl:sv_loadPitData()
    if result == true then
        return true
    else
        print('error with pitbox req')
    end
end


function PitManager.sv_loadPitData(self,pitChain,pitBoxes)
    print('loading pit data')
    if pitChain == nil or pitBoxes == nil then
        print("Missing pitData PC, PB: ",pitChain ,pitBoxes )
        return
    end
    self.pitChain = pitChain
    self.pitBoxes = pitBoxes

    if self.pitChain == nil or #self.pitChain == 0 then 
        sm.log.warning("NO PIT LANE DATA FOUND")
    end

    if self.pitBoxes == nil or #self.pitBoxes == 0 then 
        sm.log.warning("NO PIT BOX DATA FOUND")
    else
        --print('pbox loaded',self.pitBoxes)
    end
    
    if self.raceControl.pitsEnabled then
        print("Pit Manager Loaded",#self.pitBoxes)
        self.run = true
    end
end


function PitManager.sv_sendCommand(self,command) -- sends a command to Driver Command Structure: {Car [id or -1/0? for all], type [racestatus..etc], value [0,1]}
    -- parse recipients
    local recipients = command.car
    if recipients[1] == -1 then -- send all
        local allDrivers = getAllDrivers()
        for k=1, #allDrivers do local v=allDrivers[k]
            v:sv_recieveCommand(command)
        end
    else -- send to just one
        local drivers = getDriversFromIdList(command.car)
        for k=1, #drivers do local v=drivers[k]
            v:sv_recieveCommand(command)
        end
    end
end


function PitManager.getOpenPitBox(self) -- returns first open pitbox with no assignments
    --print("get open pit box")
    --print(#self.pitBoxes)
    if self.pitBoxes == nil then 
        print("No pit boxes - NIL")
        return end
    if #self.pitBoxes == 0 then
        print(" 0 pit boxes")
        return end
    local openBox = getKeyValue(self.pitBoxes,"assigned",0) -- search for open box

    if openBox == false then -- no open box
        return  -- do a secondary check here?
    end
    return openBox
end

function PitManager.getClosestOpenBox(self) -- returns box with the smallest 'remaining' value
    local min = nil
    local item = nil
    local i
    if self.pitBoxes == nil then return end
    for i=1,#self.pitBoxes do
        local box = self.pitBoxes[i]
        if box['nextDriver'] ~= 0 then
            local remaining =  box['remaining']
            if min == nil then 
                min = remaining
            else
                if remaining == nil then
                    print("nil compare")
                end
                if remaining < min then
                    min = remaining
                end
            end
        else
            return box -- empty next in line -- possibly use the one furthest from entrance?
        end
    end
    if box == nil then
        print("Pits completely full",self.pitBoxes)
    end
    return box
end

function PitManager.sv_pit_racer(self,pit_data) -- sets pit 
    --print("Pit manager pitting car",pit_data)
    --send command to car to pit
    local racer_id = pit_data['racer_id']
    local racer = getDriverFromMetaId(racer_id)
    if racer == nil then
        print("PitManager: driver not in race",pit_data)
        return -- cancels stop
    end
    print(racer.tagText, "Pitting")
    local pitBox = self:getOpenPitBox() 
    if pitBox == nil then
        print("Pit boxes full, getting least time ")
        pitBox = self:getClosestOpenBox() -- returns pit box with shortest repair time remaining
        if pitBox == nil then
            if self.pitBoxes == nil then
                print("something went wrong - pitboxes Null")
                -- Requesting bitboxdata one more time
                self:requestPitData()
            elseif #self.pitBoxes == 0 then
                print("something went wrong, no pitboxes found ")
            end

        end
    end

    if pitBox == nil then
        sm.log.error("Could not assign pitbox to car")
        return false
    end
    --print("Assigning pit box to car",pitBox)
    self:assignPitBox(racer,pitBox,pit_data)
    return true
end

function PitManager.sv_managePitBoxes(self) -- monitors cars in pits, runs timers and unassigns and moves pit boxes along
    if self.pitBoxes == nil then 
        if self.pitBoxError == false then
            print("Pit boxes not found")
            local result = self:requestPitData()
            if result == false then
                self.pitBoxError = true
                return
            end
        else
            return 
        end
    end
    for i=1,#self.pitBoxes do
        local box = self.pitBoxes[i]
        if box['assigned'] ~= 0 then -- if car is assigned
            local driver = getDriverFromId(box['assigned']) -- racer might directly be assigned to prevent the search
            if driver then
                if driver.pitState == 0 or driver.assignedBox.id ~= box.id then
                    --print("mismanaged pit box... clearing",driver.pitState,driver.assignedBox.id, box.id)
                    self:clear_pitBox(box)
                else
                    local remaining =  box['remaining']
                    if remaining <= 0 then 
                        --print(driver.tagText, "PitManager: Car finished pit") -- change this too
                        self:finishPitStop(driver,box)
                    end
                end
            end
        end

    end

    -- TODO: CHeck for "duplicate" assignments of cars and clear them out

end

function PitManager.server_onFixedUpdate(self)
    self:tickClock()
    self:ms_tick() -- 1 tick is 1 tick
    if self.run == false then return end -- run stuff ast this point
    self:sv_managePitBoxes()

end

function PitManager.client_onFixedUpdate(self) -- key press readings and what not clientside
    
end

function PitManager.client_onUpdate(self,dt)
    
end

-- Pit managment (In Lane+ box)
function PitManager.calculatePitTime(self,pit_data)
    local totalTime = 0
    if pit_data['Tire_Change'] > 0 then
        totalTime = totalTime + PIT_TIMING['TIRE_CHANGE']
    end

    totalTime = totalTime + (pit_data['Fuel_Fill'] * PIT_TIMING['FUEL_FILL'])
    --print("calculating pit time",pit_data,"=",totalTime)
    return totalTime
end


function PitManager.finishPitStop(self,racer,pitBox) -- unassigns pit box from car
    pitBox['assigned'] = 0
    pitBox['remaining'] = 0
    racer.assigneBox = nil
    racer.pitState = 5 -- send command instead??
    if pitBox['nextDriver'] ~= 0 then -- moves next queue forward
        pitBox['assigned'] = pitBox['nextDriver']
        pitBox['remaining'] = pitBox['nextRemaining']
        pitBox['nextDriver'] = 0
        pitBox['nextRemaining'] = 0
    end
end

function PitManager.assignPitBox(self,racer,pitBox,pit_data) -- calculates pit time and assigns racer to box
    local pitTime = self:calculatePitTime(pit_data)
    if pitBox['assigned'] ~= 0 then
        if pitBox['nextDriver'] ~= 0 then
            print("Error pit box full",pitBox)
            return
        else
            pitBox['nextDriver'] = racer.id
            pitBox['nextRemaining'] = pitTime
        end
    else
        pitBox['assigned'] = racer.id -- or assign racer?? so theres no need to search??
        pitBox['remaining'] = pitTime
    end
    racer.assignedBox = pitBox
end

function PitManager.clear_pitBox(self,pitBox)
    pitBox['assigned'] = 0
    pitBox['remaining'] = 0
    pitBox['nextDriver'] = 0
    pitBox['nextRemaining'] = 0
end


function PitManager.clear_pitBoxes(self) -- sets all pit boxes to be cleared
    if self.pitBoxes == nil then 
        print("cant clear nil pitboxes")
        return end
    for i=1,#self.pitBoxes do
        local pitBox = self.pitBoxes[i]
        pitBox['assigned'] = 0
        pitBox['remaining'] = 0
        pitBox['nextDriver'] = 0
        pitBox['nextRemaining'] = 0
    end
    print("cleared pitboxes",#self.pitBoxes)
end
-- networking
function PitManager.sv_ping(self,ping) -- get ing
    print("rc got sv ping",ping)
end

function PitManager.cl_ping(self,ping) -- get ing
    print("rc got cl ping",ping)
    self.network:sendToServer("sv_ping",ping)
end

function PitManager.client_showMessage( self, params )
	sm.gui.chatMessage( params )
end

function PitManager.cl_onChatCommand( self, params )

end

function PitManager.sv_n_onChatCommand( self, params, player )

end

function PitManager.sv_sendAlert(self,msg) -- sends alert message to all clients (individual clients not recognized yet)
    --self.network:sendToClients("cl_showAlert",msg) --TODO maybe have pcall here for aborting versus stopping
end

function PitManager.cl_showAlert(self,msg) -- client recieves alert
    print("Displaying",msg)
    sm.gui.displayAlertText(msg,3) --TODO: Uncomment this before pushing to production
end


function PitManager.ms_tick(self) -- frame tick
    self:sv_performTimedFuncts()
end

function PitManager.tickClock(self) -- second tick
    local floorCheck = math.floor(clock() - self.started) 
        --print(floorCheck,self.globalTimer)
    if self.globalTimer ~= floorCheck then
        self.gotTick = true
        self.globalTimer = floorCheck
        --self.dataOutputTimer:tick()
        
    else
        self.gotTick = false
        self.globalTimer = floorCheck
    end
            
end

function PitManager.sv_performTimedFuncts(self)

end



function PitManager.sv_execute_instruction(self,instruction)


end

