-- Pit lane anchor point for scanner
dofile "globals.lua"

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

function PitPoint.server_init( self ) 
	self.id = self.shape.id
    self.pointColor = "222222ff" 
    self.pointType = 0
    
    self.Color_Types = {
        ["eeeeeeff"] = { TYPE = 0, NAME = "Pit Path" },
        ["cbf66fff"] = { TYPE = 1, NAME = "Pit Begin" },    -- Start of Scan
        ["577d07ff"] = { TYPE = 2, NAME = "Pit Entrance" }, -- Speed Limit Start
        ["7c0000ff"] = { TYPE = 3, NAME = "Pit Exit" },     -- Speed Limit End
        ["f06767ff"] = { TYPE = 4, NAME = "Pit End" }       -- Merge Point
    }
    self:updateType()
end

function PitPoint.client_init(self)
    self.location =  sm.shape.getWorldPosition(self.shape)
    self.onHover = false
end

function PitPoint.server_onDestroy(self)
    -- UNREGISTER from Global Anchors
    if self.pointType == 1 and PIT_ANCHORS.start == self then PIT_ANCHORS.start = nil
    elseif self.pointType == 2 and PIT_ANCHORS.entry == self then PIT_ANCHORS.entry = nil
    elseif self.pointType == 3 and PIT_ANCHORS.exit == self then PIT_ANCHORS.exit = nil
    elseif self.pointType == 4 and PIT_ANCHORS.endPoint == self then PIT_ANCHORS.endPoint = nil
    end
end

function PitPoint.updateType(self)
    local color = tostring(self.shape.color)
    if color ~= self.pointColor then
        self.pointColor = color
        local typeData = self.Color_Types[self.pointColor]
        if typeData then
            self.pointType = typeData.TYPE
            print("PitPoint: Defined as " .. typeData.NAME .. " (" .. self.pointType .. ")")
            
            -- REGISTER to Global Anchors
            if self.pointType == 1 then PIT_ANCHORS.start = self
            elseif self.pointType == 2 then PIT_ANCHORS.entry = self
            elseif self.pointType == 3 then PIT_ANCHORS.exit = self
            elseif self.pointType == 4 then PIT_ANCHORS.endPoint = self
            end
        else
            self.pointType = 0
        end
    end
end

function PitPoint.server_onFixedUpdate( self, timeStep )
    self:updateType() -- Check for paint changes
end

function PitPoint.client_onFixedUpdate(self,timeStep)
    self.onHover = cl_checkHover(self.shape)
end