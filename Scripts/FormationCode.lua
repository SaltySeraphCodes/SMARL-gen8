-- This is just chicken scratch for things that may be needed for the formation lap functionality


-- WIll need to get qualifying information by reading a jason with their data (jason can be populated by bython reading from db)


--Race control

function OnSetFormation() -- when input from streamdeck comes in 
    self.network:sendToServer("sv_setFormation") -- probably already there
end

function Control.sv_setFormation(self) -- sends commands to all cars and then resets self
        self:sv_sendCommand({car = {-1}, type = "setFormation", value = 4}) -- whichever formation thing is
        self:sv_sendAlert("Formation Lap")

        
end
    


-- Driver

function Driver.sv_recieveCommand(self,command) -- recieves various commands from race control
    if command == nil then return end
    --print(self.id,"revieved command",command)
    if command.type == "raceStatus" then 
        if command.value == 1 then -- Race is go
            self.safeMargin = true -- just starting out race
            self.racing = true
        elseif command.value == 0 then -- no race
            self.racing = false
        end
        -- New sguff here
    elseif command.type == "setFormation" then
        self:setFormation()
        ---
    elseif command.type == "handicap" then -- set car handicap (idk why i'm not setting directly...)
        self.handicap = command.value
    elseif command.type == "resetRace" then -- Reset Car
        self.handicap = self:sv_hard_reset()
    end
end


function Driver.setFormation(self) -- sv
    self.formationDesire = 1
end