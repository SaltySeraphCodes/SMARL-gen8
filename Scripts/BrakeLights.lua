-- Copyright (c) 2019 Seraph --
--dofile "../Libs/GameImprovements/interactable.lua"
-- read in maps
if  sm.isHost then -- Just avoid anythign that isnt the host for now
	dofile "globals.lua"
end
-- Reverse Lights
-- Turns on when car starts braking
BrakeLights = class( nil )
BrakeLights.maxChildCount = -1
BrakeLights.maxParentCount = -1
BrakeLights.connectionInput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
BrakeLights.connectionOutput =sm.interactable.connectionType.logic
BrakeLights.colorNormal = sm.color.new( 0xec0000ff )
BrakeLights.colorHighlight = sm.color.new( 0xe7c000fff )
BrakeLights.poseWeightCount = 2


function BrakeLights.client_onCreate( self ) 
	self:client_init()
end

function BrakeLights.client_onDestroy(self)
	
end

function BrakeLights.client_init( self ) 
	self.id = self.shape.id
	self.racerID = nil
	self.active = true
end

function BrakeLights.client_onRefresh( self )
	self:client_onDestroy()
	--dofile "globals.lua" removed because it may erase stored data
	self:client_init()

end

function BrakeLights.setLights(self)
	if self.active ~= self.interactable.isActive then
		self.interactable:setActive(self.active)
	end
end

function BrakeLights.calculateBrakeStatus(self,power)
	--print("checking",power)
	--local brakes = getBrakes(self.racerID)
	--local status = getStatus(self.racerID)
	if power <0 then
		if self.active ~= true then
			self.active = true
			--print("breaking")
		end
	else
		if self.active ~= false then
			self.active = false
			--print("not braking")
		end
	end
	self:setLights()
end


function BrakeLights.sv_setDriverError(self,param) -- sets network state for driver error
    self.noDriverError = param
    self.driver = nil
    self.network:sendToClients("cl_setNoDriver",param)
end

function BrakeLights.cl_setNoDriver(self,param) -- sets no driver to clients -- Separate out between?>
    self.noDriverError = param
    --print( "Brakes: Driver " .. (param and "Not Detected" or "Detected"))
end

function BrakeLights.server_onFixedUpdate( self, timeStep )
	--[[if not sm.isHost then -- Just avoid anythign that isnt the host for now
		return
	end]]
	local parents = self.interactable:getParents()
    if #parents == 0 and not self.noDriverError then
        print("Brakes: No Driver Detected")
        self:sv_setDriverError(true)
    elseif  #parents == 1 and self.noDriverError then 
        --print("Improper parent",#parents)
    end

	for k=1, #parents do local v=parents[k]--for k, v in pairs(parents) do
		--print("parsparents")
        local typeparent = v:getType()
		local parentColor =  tostring(sm.shape.getColor(v:getShape()))
		local parentUUID = tostring(v:getShape():getShapeUuid())
		if parentUUID == DRIVER_UUID or parentUUID == DRIVER_GEN8_UUID then -- Driver Controller only thing we need
            if self.driver == nil then
                local id = v:getShape():getId()
                local driver = getDriverFromId(id)
                if driver == nil then
                    if not self.noDriverError then
                        print("Brakes No Driver Found")
                        self:sv_setDriverError(true)
                    end
                else
                    print("Brakes found Driver") -- Validate driver too?
                    self:sv_setDriverError(false)
                    self.driver = driver
                    self.loaded = true
                end
            end
            if v.power ~= self.accelInput then
				self:calculateBrakeStatus(v.power)
				self.accelInput = v.power
			end
		end
	end
end