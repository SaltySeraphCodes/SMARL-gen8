
-- Pit lane and pit box generator
if sm.isHost then
	--print("Loaded Engine Class") -- Do whatever here?
end
dofile "globals.lua" -- Or json.load?

PitPoint = class( nil )
PitPoint.maxChildCount = 100
PitPoint.maxParentCount = 2
PitPoint.connectionInput = sm.interactable.connectionType.power
PitPoint.connectionOutput = sm.interactable.connectionType.bearing + sm.interactable.connectionType.logic
PitPoint.colorNormal = sm.color.new( 0xe6a14dff )
PitPoint.colorHighlight = sm.color.new( 0xF6a268ff )



function PitPoint.server_onCreate( self ) 
	self:server_init()
	
end

function PitPoint.client_onCreate( self ) 
	self:client_init()
end

function PitPoint.client_onDestroy(self)
    self:cl_removeNode(self.id)
end

function PitPoint.server_onDestroy(self)

end

function PitPoint.client_onRefresh( self )
	self:client_onDestroy()
    self:client_init()
end

function PitPoint.server_onRefresh( self )
	--self:client_onDestroy()
    self:server_onDestroy()
	--self.effect = sm.effect.createEffect("GasEngine - Level 3", self.interactable )
    --print("Engine server refresh")
    self:server_init()
    -- send to server refresh
end

function PitPoint.server_init( self ) 
    
	self.id = self.shape.id
   -- load point tyoe and color
    self.pointColor = "222222ff" -- or self.shape.color maybe use ID instead
    self.pointType = 0
   
    
    self.Color_Types = {
        ["eeeeeeff"] = {
            TYPE = 0,
            NAME = "Pit Path"
        },
        ["cbf66fff"] = {
            TYPE = 1,
            NAME = "Pit Begin"
        },
        ["577d07ff"] = {
            TYPE = 2,
            NAME = "Pit Entrance"
        },
        ["7c0000ff"] = {
            TYPE = 3,
            NAME = "Pit Exit"
        },
        ["f06767ff"] = {
            TYPE = 4,
            NAME = "Pit End"
        }
    }
    self:updateType()
end

function PitPoint.client_init(self)
    self.location =  sm.shape.getWorldPosition(self.shape)
    self.onHover = false
    self.useText =  sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    self.pointType = 0
    
    --print("adding node?",PIT_CHAIN_CONFIG.editing)
    if PIT_CHAIN_CONFIG.editing ~= 0 then -- Editing pitpoint
        --print("adding editing pitpoint",PIT_CHAIN_CONFIG.editing)
        table.insert(PIT_CHAIN_CONFIG.shape_arr,PIT_CHAIN_CONFIG.editing,self)
        table.insert(PIT_CHAIN_CONFIG.pos_arr,PIT_CHAIN_CONFIG.editing,self.location)
        self.id = PIT_CHAIN_CONFIG.editing
        print("Edited pitPoint  ",self.id,self.location)
        self:cl_showAlert("Edited pitPoint  "..self.id)
        PIT_CHAIN_CONFIG.editing = 0
    else
        table.insert(PIT_CHAIN_CONFIG.shape_arr,self)
        table.insert(PIT_CHAIN_CONFIG.pos_arr,self.location)
        self.id = #PIT_CHAIN_CONFIG.shape_arr
        --TODO: do a shape_arr and pos_arr checker
        print("Adding PitPoint  ",self.id,self.location,self.pointType)
        self:cl_showAlert("Created PitPoint    "..self.id)
    end
    PIT_CHAIN_CONFIG.hasChange = true
end




function PitPoint.cl_removeNode(self,nodeID) -- removes node
    for k, v in pairs(PIT_CHAIN_CONFIG.shape_arr) do
		if v.id == nodeID then
			table.remove(PIT_CHAIN_CONFIG.shape_arr, k)
            table.remove(PIT_CHAIN_CONFIG.pos_arr,k)
		end
    end
    -- re index only when not editing
    if PIT_CHAIN_CONFIG.editing ~= 0 then
        for k, v in pairs(PIT_CHAIN_CONFIG.shape_arr) do
            v.id = k
        end
        --self:cl_showAlert("Editing pitpoint  "..nodeID)
    else
        self:cl_showAlert("Removed pitpoint  "..nodeID)
    end
    
    PIT_CHAIN_CONFIG.hasChange = true
end


function PitPoint.sv_sendAlert(self,msg) -- sends alert message to all clients (individual clients not recognized yet)
    self.network:sendToClients("cl_showAlert",msg) --TODO maybe have pcall here for aborting versus stopping
end

function PitPoint.cl_showAlert(self,msg) -- client recieves alert
    --print("Displaying",msg)
    sm.gui.displayAlertText(msg,3)
end



function PitPoint.cl_generateVisuals(self)
    print("generating visuals")
    for k=1, #self.nodeChain do local v=self.nodeChain[k]
        if v.effect == nil then
            v.effect = self:generateEffect(v.pos)
        elseif v.effect ~= nil then
            if not v.effect:isPlaying() then
                v.effect:start()
            end
        end
    end
end

function PitPoint.generateEffect(self,location,color) -- Creates new effect at param location
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



function PitPoint.cl_changeTension(self,amnt)
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


function PitPoint.cl_changeNodes(self,amnt)
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

function PitPoint.server_onProjectile(self,hitLoc,time,shotFrom) -- Functionality when hit by spud gun
	print("Destroying all")
    for k = #PIT_CHAIN_CONFIG.shape_arr, 1, -1 do
        local shape = PIT_CHAIN_CONFIG.shape_arr[k].shape
        if shape then 
            print("destroying",shape)
            shape:destroyShape()
        else
            print("no shape?")
        end
            
    end
end

function PitPoint.server_onMelee(self,data) -- Functionality when hit by hammer
	--print("melehit",self.id,#PIT_CHAIN_CONFIG.shape_arr) -- Means save node?
    self:sv_sendAlert("Editing pitpoint  "..self.id)
    PIT_CHAIN_CONFIG.editing = self.id
    self.shape:destroyShape()
end
-- Parameter editing functs


function PitPoint.client_canTinker( self, character )
    return true
end

function PitPoint.client_onTinker( self, character, state )
	if state then
        if character:isCrouching() then
            self:cl_changeNodes(-1)
        else
            self:cl_changeNodes(1)
        end
        PIT_CHAIN_CONFIG.hasChange = true
	end
end

function PitPoint.client_onInteract(self,character,state)
    if state then
        if character:isCrouching() then
            self:cl_changeTension(-0.1)
        else
            self:cl_changeTension(0.1)
        end
        PIT_CHAIN_CONFIG.hasChange = true
    end
end

function PitPoint.client_onClientDataUpdate(self,data)
    self.pointType = data.pointType
    print("update client point time",self.id,self.pointType)
end

function PitPoint.client_onUpdate(self,timeStep)
    if self.onHover then 
        local item = sm.localPlayer.getActiveItem()
        if item == sm.uuid.new("ed185725-ea12-43fc-9cd7-4295d0dbf88b") then -- holding sledgehammer
            sm.gui.setInteractionText("" ,"Hit to edit node position","",tostring(self.id),"")
        elseif item == sm.uuid.new("c5ea0c2f-185b-48d6-b4df-45c386a575cc") then -- holding potato rifle
            sm.gui.setInteractionText("" ,"Shoot to remove all check points","","","")
        elseif sm.localPlayer.getPlayer().character:isCrouching() then
            sm.gui.setInteractionText( self.useText,"Decrease Smoothness", self.tinkerText,"Decrease Nodes","")
        else
            sm.gui.setInteractionText( self.useText,"Increase Smoothness", self.tinkerText,"Increase Nodes","")
        end
    else

    end

end
function PitPoint.server_onFixedUpdate( self, timeStep )
    -- First check if driver has seat connectd
    --self:parseParents()
    self.location =  sm.shape.getWorldPosition(self.shape)
end

function PitPoint.client_onFixedUpdate(self,timeStep)
    self.onHover = cl_checkHover(self.shape)
end



function PitPoint.updateType(self) -- Ran to constantly check if engine is updated -- can be changed to onPainted
    if tostring(self.shape.color) ~= self.pointColor then
        self.pointColor = tostring(self.shape.color)
        print("loading New Point",self.pointColor)
        self.pointType = self.Color_Types[self.pointColor]
        if self.pointType == nil then
            sm.log.error("Point Not proper color "..self.pointColor) -- gui alert?
            self.noPointError = true
        else
            self.noPointError = false
            print("Defining Point type",self.pointType)
            self.network:setClientData({ ["pointType"] = self.pointType})
        end
        PIT_CHAIN_CONFIG.hasChange = true -- add sep funct for this? call to clients?
    end
end



function PitPoint.server_onFixedUpdate( self, timeStep )
    --print(self.noDriverError,self.noStatsError )
    self:updateType()
end



function PitPoint.client_showMessage( self, params )
	sm.gui.chatMessage( params )
end
