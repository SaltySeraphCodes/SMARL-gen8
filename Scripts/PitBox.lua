-- Pit box definer (only for the boxds themselves)
if sm.isHost then
	--print("Loaded Engine Class") -- Do whatever here?
end
dofile "globals.lua" -- Or json.load?

PitBox = class( nil )
PitBox.maxChildCount = 100
PitBox.maxParentCount = 2
PitBox.connectionInput = sm.interactable.connectionType.power
PitBox.connectionOutput = sm.interactable.connectionType.bearing + sm.interactable.connectionType.logic
PitBox.colorNormal = sm.color.new( 0xe6a14dff )
PitBox.colorHighlight = sm.color.new( 0xF6a268ff )


-- pitbox checks for size based off of blocks attached -- bounding box is created
-- Size gets set in global settings (front left, front right, back left, back right)
-- subsequent blocks placed have the same dimensions

function PitBox.server_onCreate( self ) 
	self:server_init()
	
end

function PitBox.client_onCreate( self ) 
	self:client_init()
end

function PitBox.client_onDestroy(self)
    print("Client destroy")
    self:cl_removeNode(self.id)
end

function PitBox.server_onDestroy(self)

end

function PitBox.client_onRefresh( self )
	self:client_onDestroy()
    self:client_init()
end

function PitBox.server_onRefresh( self )
	--self:client_onDestroy()
    self:server_onDestroy()
	--self.effect = sm.effect.createEffect("GasEngine - Level 3", self.interactable )
    --print("Engine server refresh")
    self:server_init()
    -- send to server refresh
end

function PitBox.server_init( self ) 
    -- Note: put error states up front
    
    --print("Gen7 Engine Initialized")
end

function PitBox.client_init(self)
    self.boxDimensions = {
        ['fl'] = 1,
        ['fr'] = 1,
        ['bl'] = 1,
        ['br'] = 1
    }
    
    self.boxEffects = {
    }
    self.location =  sm.shape.getWorldPosition(self.shape)
    print("pbox Placed",self.location)
    self.onHover = false
    self.useText =  sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    --print("adding node?",PIT_CHAIN_CONFIG.editing)
    if PIT_CHAIN_CONFIG.boxEdit ~= 0 then -- Editing pitBox
        table.insert(PIT_CHAIN_CONFIG.pbox_arr,PIT_CHAIN_CONFIG.boxEdit,self)
        self.id = PIT_CHAIN_CONFIG.boxEdit
        print("Edited pitBox  ",self.id,self.location)
        self:cl_showAlert("Edited pit box  "..self.id)
        PIT_CHAIN_CONFIG.boxEdit = 0
    else
        table.insert(PIT_CHAIN_CONFIG.pbox_arr,self)
        self.id = #PIT_CHAIN_CONFIG.pbox_arr
        --TODO: do a shape_arr and pos_arr checker
        print("Adding pit box  ",self.id,self.location)
        self:cl_showAlert("Created pit box    "..self.id)
    end
    --PIT_CHAIN_CONFIG.hasChange = true
end




function PitBox.cl_removeNode(self,nodeID) -- removes node
    for k, v in pairs(PIT_CHAIN_CONFIG.pbox_arr) do
		if v.id == nodeID then
			table.remove(PIT_CHAIN_CONFIG.pbox_arr, k)
		end
    end
    -- re index only when not editing
    if PIT_CHAIN_CONFIG.boxEdit ~= 0 then
        for k, v in pairs(PIT_CHAIN_CONFIG.pbox_arr) do
            v.id = k
        end
    else
        self:cl_showAlert("Removed pit box  "..nodeID)
    end
    --PIT_CHAIN_CONFIG.hasChange = true
end


function PitBox.sv_sendAlert(self,msg) -- sends alert message to all clients (individual clients not recognized yet)
    self.network:sendToClients("cl_showAlert",msg) --TODO maybe have pcall here for aborting versus stopping
end

function PitBox.cl_showAlert(self,msg) -- client recieves alert
    --print("Displaying",msg)
    sm.gui.displayAlertText(msg,3)
end



function PitBox.cl_generateVisuals(self) -- generate four corners of box
    print("generating visuals")
    for k=1, #self.boxEffects do local v=self.boxEffects[k]
        if v.effect == nil then
            v.effect = self:generateEffect(v.pos)
        elseif v.effect ~= nil then
            if not v.effect:isPlaying() then
                v.effect:start()
            end
        end
    end
end

function PitBox.generateEffect(self,location,color) -- Creates new effect at param location
    local effect = sm.effect.createEffect("Loot - GlowItem")
    effect:setParameter("uuid", sm.uuid.new("4a1b886b-913e-4aad-b5b6-6e41b0db23a6"))
    effect:setScale(sm.vec3.new(0,0,0))
    local color = (color or sm.color.new("AFAFAFFF"))
    
    --local testUUID = sm.uuid.new("42c8e4fc-0c38-4aa8-80ea-1835dd982d7c")
    --effect:setParameter( "uuid", testUUID) -- Eventually trade out to calculate from force
    --effect:setParameter( "Color", color )
    effect:setPosition(location) -- remove too
    effect:setParameter( "Color", color )
    return effect
end

-- param changing functions



function PitBox.cl_changeTension(self,amnt)
    -- increasees wall thin
    PIT_CHAIN_CONFIG.tension = PIT_CHAIN_CONFIG.tension + amnt
    if PIT_CHAIN_CONFIG.tension <= 0 then
        PIT_CHAIN_CONFIG.tension = 0 
    elseif PIT_CHAIN_CONFIG.tension >= 1 then 
        PIT_CHAIN_CONFIG.tension = 1
    end
    local color = "#ffffff"
    if amnt < 0 then
        color = "#ffaaaa"
    elseif amnt > 0 then
        color = "#aaffaa"
    end
    sm.gui.chatMessage("Set Racing Line Tension: "..color ..PIT_CHAIN_CONFIG.tension .. " #ffffffCrouch to decrease")
end


function PitBox.cl_changeNodes(self,amnt)
    -- increasees wall thin
    PIT_CHAIN_CONFIG.nodes = PIT_CHAIN_CONFIG.nodes + amnt
    if PIT_CHAIN_CONFIG.nodes <= 1 then
        PIT_CHAIN_CONFIG.nodes = 1
    elseif PIT_CHAIN_CONFIG.nodes >= 25 then 
        PIT_CHAIN_CONFIG.nodes = 25
    end
    local color = "#ffffff"
    if amnt < 0 then
        color = "#ffaaaa"
    elseif amnt > 0 then
        color = "#aaffaa"
    end
    sm.gui.chatMessage("Set Node Count: "..color ..PIT_CHAIN_CONFIG.nodes .. " #ffffffCrouch to decrease")
end

function PitBox.server_onProjectile(self,hitLoc,time,shotFrom) -- Functionality when hit by spud gun
	print("Destroying all")
    for k = #PIT_CHAIN_CONFIG.pbox_arr, 1, -1 do
        local shape = PIT_CHAIN_CONFIG.pbox_arr[k].shape
        if shape then 
            print("destroying",shape)
            shape:destroyShape()
        else
            print("no shape?")
        end
            
    end
end

function PitBox.server_onMelee(self,data) -- Functionality when hit by hammer
	--print("melehit",self.id,#PIT_CHAIN_CONFIG.shape_arr) -- Means save node?
    self:sv_sendAlert("Editing pitpoint  "..self.id)
    PIT_CHAIN_CONFIG.boxEdit = self.id
    self.shape:destroyShape()
end
-- Parameter editing functs


function PitBox.client_canTinker( self, character )
    return true
end

function PitBox.client_onTinker( self, character, state )
	if state then
        if character:isCrouching() then
            print("smaller")
        else
            print("bigger")
        end
        --PIT_CHAIN_CONFIG.hasChange = true
	end
end

function PitBox.client_onInteract(self,character,state)
    if state then
        if character:isCrouching() then
            print("narrower")
        else
            print("wider")
        end
        --PIT_CHAIN_CONFIG.hasChange = true
    end
end

function PitBox.client_onUpdate(self,timeStep)
   

end

function PitBox.server_onFixedUpdate( self, timeStep )
    -- First check if driver has seat connectd
    --self:parseParents()
    self.location =  sm.shape.getWorldPosition(self.shape)
end

function PitBox.client_onFixedUpdate(self,timeStep)
    
end




function PitBox.updateType(self) -- Ran to constantly check if engine is updated -- can be changed to onPainted
   
end



function PitBox.server_onFixedUpdate( self, timeStep )
    --print(self.noDriverError,self.noStatsError )
end



function PitBox.client_showMessage( self, params )
	sm.gui.chatMessage( params )
end
