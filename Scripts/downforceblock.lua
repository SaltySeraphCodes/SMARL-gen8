-- Copyright (c) 2019 Seraph --
dofile "globals.lua"

-- Purpose, add an artificial downforce to vehicles, saves to block and blueprint
-- Usage: Place block on vehicle, interact to increase downforce, crouch+interact to decrease downforce
-- Downforce is applied only when vehicle is relatively flat, not when going up or down steep inclines
-- TODO: Consider vehicle speed and parts for more realistic downforce application
-- TODO: Integrate with driver AI to detect and adjust for downforce effects
-- TODO: Add visual indicators for downforce level (when debug mode is enabled (onTinker)
-- TODO: Have downforce able to be toggled by logic blocks (eg a sensor or gate/switch)

DownforceBlock = class( nil )
DownforceBlock.maxChildCount = -1
DownforceBlock.maxParentCount = 0
DownforceBlock.connectionInput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
DownforceBlock.connectionOutput =sm.interactable.connectionType.logic
DownforceBlock.colorNormal = sm.color.new( 0x9999ffff )
DownforceBlock.colorHighlight = sm.color.new( 0xaaaaffff )
DownforceBlock.poseWeightCount = 2

function DownforceBlock.server_onCreate(self)
    self:server_init()
end

function DownforceBlock.client_onCreate( self ) 
	self:client_init()
end

function DownforceBlock.client_onDestroy(self)
	
end

function DownforceBlock.client_init( self ) 
    self.useText =  sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    self.onHover = false
end

function DownforceBlock.server_onDestroy(self)

end

function DownforceBlock.server_init( self ) 
    self.downforceChannel = 1 -- apparenlty 1 is transfered over...
	self.forceStrength = (self.storage:load() or 0 )
    self.interactable:setPower(self.forceStrength)
    print("loaded downforce:",self.forceStrength)
end

function DownforceBlock.client_onRefresh( self )
	self:client_onDestroy()
	--dofile "globals.lua" removed because it may erase stored data
	self:client_init()

end


function DownforceBlock.server_onRefresh( self )
	self:server_onDestroy()
	--dofile "globals.lua" removed because it may erase stored data
	self:server_init()

end

function DownforceBlock.perform_downforce(self) -- SV
    --print('downforce?',self.forceStrength)
    if self.forceStrength == nil then self.forceStrength = 0 end
    local velocity = sm.shape.getVelocity(self.shape)
    local speed = velocity:length()
    local maxForce = -1200
    local minForce = -500
    local offset = 0.05 -- offset towards/from front to push down

    local force = self.shape.up * -self.forceStrength -- -- invert so slower has higher? TODO: Check for wedges/aero parts, tire warmth factor too
  
    if velocity.z < -0.5 then -- TODO: Just do an math.abs and only apply downforce outside of range?
    
    elseif velocity.z > 1.5 then -- going up
   
    else -- GOing flat, normal downforce
        sm.physics.applyImpulse(self.shape.body,force,true)--,--self.shape.at)
    end 
end

function DownforceBlock.server_onFixedUpdate( self, timeStep )
	--[[if not sm.isHost then -- Just avoid anythign that isnt the host for now
		return
	end]]
	self:perform_downforce()
	
end

function DownforceBlock.cl_notifyChat(self,message)
    sm.gui.chatMessage(message)
end



function DownforceBlock.client_onFixedUpdate( self, timeStep ) 
    self.onHover = cl_checkHover(self.shape)
end

function DownforceBlock.client_onUpdate(self, timeStep)
    if self.onHover then 
        sm.gui.setInteractionText( self.useText,"Increase Force ", self.useText," + Crouch = Decrease Force","" )
    else
    end
end


function DownforceBlock.sv_update_force(self,ammount)
    self.forceStrength = self.forceStrength + ammount
    self.network:sendToClients("cl_notifyChat","Set Force Strength:" .. tostring(self.forceStrength))
    self.interactable:setPower(self.forceStrength)
    self.storage:save(self.forceStrength)
    --print("saved",self.forceStrength)
end

function DownforceBlock.client_canTinker( self, character )
    --print("canTinker")
	return true -- Any conditions when it cant? like on 
end

function DownforceBlock.client_onTinker( self, character, state )
    --print('onTinker')
	if state then
       
	end
end



function DownforceBlock.client_onInteract(self,character,state)
    -- if driver active, then toggle userControl
    --print("client onInteract")
    if state then
        if character:isCrouching() then
           self.network:sendToServer("sv_update_force",-100) -- TDOO have adjustable ammounts
        else -- if character is not aiming and not crouching
            self.network:sendToServer("sv_update_force",100)
        end
    end    
end

-- Downforce Detection and helpers
function Driver.sv_onInteract(self,params) -- so far for only for downforce detection
    --print(self.userSeated,self.userControl)
    local state = params.state
    local crouch = params.crouch
    if state and not self.userSeated then -- E pressed
        if self.downforceDetect == false then -- if not already detecting
            if self.speed <= 1 then -- maybe smaller?
                if self.onLift == false then
                    print("Detecting Downforce")
                    self:sv_sendAlert("Detecting Downforce...")
                    self.downforceDetect = true
                    self.dfTestVect.z = 0 -- reset test vec
                else
                    print("Car shjould not be onlift")
                end
            else
                print("Car should be still")
            end
        else
            print("already detecting downforce...",self.downforceDetect)
            self.downforceDetect = false
        end
    end
end
