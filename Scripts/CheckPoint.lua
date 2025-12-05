-- CHeckpoint.lua, 
--[[
    Functionality:
        - logic block with arrow on it
        - gets placed down (beta in race order, can destroy/reset location but only on latest node)
        - Has two nodes show up (or possibly visual square) nodes will indicate width of track
        - Press E on it to increase width (possible ui) of nodes
        - data contains width and direction
        - Crouch and press E to decrease width of nodes (possible seat/camera interaction for more controls
        - node saves previous width of last node so not a lot of manual adjustment is needed
        - In future, possible optional/Split node, car can roll for chance to choose different path
        - Finish Loop/path by shooting First node with spud gun, nodes will form between each CP
        - Each Node will scan for walls and adjust accordingly (stay 5 ft away from wall), if no walls, it will attempt direct path to next node
        - Nodes will be straight paths, curves will be handled by cars, will not try to optimize apexes yet
        - once satisfie with nodes (after node generation), shoot first node with spud gun again to lock/save the path in place
        - nodelist gets saved in world under incrementing ID, race control can select ID (eventually, default 1 & overwritten)
]]
dofile "globals.lua"
dofile "Timer.lua" 

CheckPoint = class( nil )
CheckPoint.maxChildCount = -1
CheckPoint.maxParentCount = -11
CheckPoint.connectionInput = sm.interactable.connectionType.logic
CheckPoint.connectionOutput = sm.interactable.connectionType.logic
CheckPoint.colorNormal = sm.color.new( 0xffc0cbff )
CheckPoint.colorHighlight = sm.color.new( 0xffb6c1ff )
local clock = os.clock --global clock to benchmark various functional speeds ( for fun)



-- Local helper functions utilities
function round( value )
	return math.floor( value + 0.5 )
end

function CheckPoint.client_onCreate( self ) 
	self:client_init()
end

function CheckPoint.server_onCreate( self ) 
	self:server_init()
end

function CheckPoint.client_onDestroy(self)
    --print('cldest',self.id)
    self:cl_removeNode(self.id)
end

function CheckPoint.server_onDestroy(self) -- remove node
    --print('servdest',self.id)
end

function CheckPoint.client_init( self ) 
    self.location =  sm.shape.getWorldPosition(self.shape)
    self.onHover = false
    self.useText =  sm.gui.getKeyBinding( "Use", true )
    self.tinkerText = sm.gui.getKeyBinding( "Tinker", true )
    --print("adding node?",CHECK_POINT_CONFIG.editing)
    if CHECK_POINT_CONFIG.editing ~= 0 then -- Editing checkpoint
        --print("adding editing checkpoint",CHECK_POINT_CONFIG.editing)
        table.insert(CHECK_POINT_CONFIG.shape_arr,CHECK_POINT_CONFIG.editing,self)
        table.insert(CHECK_POINT_CONFIG.pos_arr,CHECK_POINT_CONFIG.editing,self.location)
        self.id = CHECK_POINT_CONFIG.editing
        print("Edited checkpoint",self.id,self.location)
        self:cl_showAlert("Edited Checkpoint    "..self.id)
        CHECK_POINT_CONFIG.editing = 0
    else
        table.insert(CHECK_POINT_CONFIG.shape_arr,self)
        table.insert(CHECK_POINT_CONFIG.pos_arr,self.location)
        self.id = #CHECK_POINT_CONFIG.shape_arr
        --TODO: do a shape_arr and pos_arr checker
        print("Adding checkpoint",self.id,self.location)
        self:cl_showAlert("Created Checkpoint    "..self.id)
    end
    CHECK_POINT_CONFIG.hasChange = true
end

function CheckPoint.client_updateEffects(self)

end

function CheckPoint.server_init(self)
   -- moved everything client side for now
   --table.insert(CHECK_POINT_CONFIG.shape_arr,self)
end

function CheckPoint.client_onRefresh( self )
	self:client_onDestroy()
	self:client_init()
end

function CheckPoint.server_onRefresh( self )
	self:server_onDestroy()
	self:server_init()
end

function sleep(n)  -- n: seconds freezes game?
  local t0 = clock()
  while clock() - t0 <= n do end
end

function CheckPoint.asyncSleep(self,func,timeout)
    --print("weait",self.globalTimer,self.gotTick,timeout)
    if timeout == 0 or (self.gotTick and self.globalTimer % timeout == 0 )then 
        --print("timeout",self.globalTimer,self.gotTick,timeout)
        local fin = func(self) -- run function
        return fin
    end
end


function CheckPoint.cl_removeNode(self,nodeID) -- removes node
    for k, v in pairs(CHECK_POINT_CONFIG.shape_arr) do
		if v.id == nodeID then
			table.remove(CHECK_POINT_CONFIG.shape_arr, k)
            table.remove(CHECK_POINT_CONFIG.pos_arr,k)
		end
    end
    -- re index only when not editing
    if CHECK_POINT_CONFIG.editing ~= 0 then
        for k, v in pairs(CHECK_POINT_CONFIG.shape_arr) do
            v.id = k
        end
        --self:cl_showAlert("Editing Checkpoint  "..nodeID)
    else
        self:cl_showAlert("Removed Checkpoint  "..nodeID)
    end
    
    CHECK_POINT_CONFIG.hasChange = true
end


function CheckPoint.sv_sendAlert(self,msg) -- sends alert message to all clients (individual clients not recognized yet)
    self.network:sendToClients("cl_showAlert",msg) --TODO maybe have pcall here for aborting versus stopping
end

function CheckPoint.cl_showAlert(self,msg) -- client recieves alert
    --print("Displaying",msg)
    sm.gui.displayAlertText(msg,3)
end

function CheckPoint.cl_generateVisuals(self)
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

function CheckPoint.generateEffect(self,location,color) -- Creates new effect at param location
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



function CheckPoint.cl_changeTension(self,amnt)
    -- increasees wall thin
    CHECK_POINT_CONFIG.tension = CHECK_POINT_CONFIG.tension + amnt
    if CHECK_POINT_CONFIG.tension <= 0 then
        CHECK_POINT_CONFIG.tension = 0 
    elseif CHECK_POINT_CONFIG.tension >= 1 then 
        CHECK_POINT_CONFIG.tension = 1
    end
    local color = "#ffffff"
    if amnt < 0 then
        color = "#ffaaaa"
    elseif amnt > 0 then
        color = "#aaffaa"
    end
    sm.gui.chatMessage("Set Racing Line Tension: "..color ..CHECK_POINT_CONFIG.tension .. " #ffffffCrouch to decrease")
end


function CheckPoint.cl_changeNodes(self,amnt)
    -- increasees wall thin
    CHECK_POINT_CONFIG.nodes = CHECK_POINT_CONFIG.nodes + amnt
    if CHECK_POINT_CONFIG.nodes <= 1 then
        CHECK_POINT_CONFIG.nodes = 1
    elseif CHECK_POINT_CONFIG.nodes >= 25 then 
        CHECK_POINT_CONFIG.nodes = 25
    end
    local color = "#ffffff"
    if amnt < 0 then
        color = "#ffaaaa"
    elseif amnt > 0 then
        color = "#aaffaa"
    end
    sm.gui.chatMessage("Set Node Count: "..color ..CHECK_POINT_CONFIG.nodes .. " #ffffffCrouch to decrease")
end

function CheckPoint.server_onProjectile(self,hitLoc,time,shotFrom) -- Functionality when hit by spud gun
	print("Destroying all")
    for k = #CHECK_POINT_CONFIG.shape_arr, 1, -1 do
        local shape = CHECK_POINT_CONFIG.shape_arr[k].shape
        if shape then 
            print("destroying",shape)
            shape:destroyShape()
        else
            print("no shape?")
        end
            
    end
end

function CheckPoint.server_onMelee(self,data) -- Functionality when hit by hammer
	--print("melehit",self.id,#CHECK_POINT_CONFIG.shape_arr) -- Means save node?
    self:sv_sendAlert("Editing Checkpoint  "..self.id)
    CHECK_POINT_CONFIG.editing = self.id
    self.shape:destroyShape()
end
-- Parameter editing functs


function CheckPoint.client_canTinker( self, character )
    return true
end

function CheckPoint.client_onTinker( self, character, state )
	if state then
        if character:isCrouching() then
            self:cl_changeNodes(-1)
        else
            self:cl_changeNodes(1)
        end
        CHECK_POINT_CONFIG.hasChange = true
	end
end

function CheckPoint.client_onInteract(self,character,state)
    if state then
        if character:isCrouching() then
            self:cl_changeTension(-0.1)
        else
            self:cl_changeTension(0.1)
        end
        CHECK_POINT_CONFIG.hasChange = true
    end
end

function CheckPoint.client_onUpdate(self,timeStep)
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
function CheckPoint.server_onFixedUpdate( self, timeStep )
    -- First check if driver has seat connectd
    --self:parseParents()
    self.location =  sm.shape.getWorldPosition(self.shape)
end

function CheckPoint.client_onFixedUpdate(self,timeStep)
    self.onHover = cl_checkHover(self.shape)
end


