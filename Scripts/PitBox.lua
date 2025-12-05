-- Pit box definer
if sm.isHost then
	dofile "globals.lua" 
end

PitBox = class( nil )
PitBox.maxChildCount = 100
PitBox.maxParentCount = 2
PitBox.connectionInput = sm.interactable.connectionType.power
PitBox.connectionOutput = sm.interactable.connectionType.bearing + sm.interactable.connectionType.logic
PitBox.colorNormal = sm.color.new( 0xe6a14dff )
PitBox.colorHighlight = sm.color.new( 0xF6a268ff )

function PitBox.server_onCreate( self ) 
	self:server_init()
end

function PitBox.client_onCreate( self ) 
	self:client_init()
end

function PitBox.server_init( self ) 
    -- Register this box in global table for scanner
    table.insert(PIT_ANCHORS.boxes, self)
    print("PitBox: Registered id " .. self.shape.id)
end

function PitBox.client_init(self)
    self.location =  sm.shape.getWorldPosition(self.shape)
    self.onHover = false
end

function PitBox.server_onDestroy(self)
    -- Remove from global registry
    for i, box in ipairs(PIT_ANCHORS.boxes) do
        if box == self then
            table.remove(PIT_ANCHORS.boxes, i)
            break
        end
    end
end

function PitBox.server_onFixedUpdate( self, timeStep )
    self.location =  sm.shape.getWorldPosition(self.shape)
end

function PitBox.client_onFixedUpdate( self, timeStep ) 
    self.onHover = cl_checkHover(self.shape)
end