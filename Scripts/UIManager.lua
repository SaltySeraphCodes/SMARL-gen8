-- UIManager.lua
-- Handles the in-game GUI for Race Control.
-- Decouples UI logic from the main logic classes.

UIManager = class(nil)

local GUI_LAYOUT = "$CONTENT_DATA/Gui/Layouts/RaceControl.layout"

function UIManager:init(raceControl)
    self.RC = raceControl
    self.gui = nil
    self.isOpen = false
    self.confirmAction = nil -- Stores the action waiting for confirmation
end

function UIManager:create()
    if self.gui then return end
    self.gui = sm.gui.createGuiFromLayout(GUI_LAYOUT, false, { isHud = false, isInteractive = true, needsCursor = true })
    
    -- Bind Buttons
    self.gui:setButtonCallback("BtnStart", "cl_onBtnStart")
    self.gui:setButtonCallback("BtnStop", "cl_onBtnStop")
    self.gui:setButtonCallback("BtnCaution", "cl_onBtnCaution")
    self.gui:setButtonCallback("BtnFormation", "cl_onBtnFormation")
    
    self.gui:setButtonCallback("BtnEntries", "cl_onBtnEntries")
    self.gui:setButtonCallback("BtnReset", "cl_onBtnReset")
    
    -- Settings +/-
    self.gui:setButtonCallback("BtnLapsAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnLapsSub", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnHandiAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnHandiSub", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnDraftAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnDraftSub", "cl_onSettingsChange")
    
    -- Toggles
    self.gui:setButtonCallback("BtnTireWear", "cl_onToggleSetting")
    self.gui:setButtonCallback("BtnQualifying", "cl_onToggleSetting")
    
    -- Popup
    self.gui:setButtonCallback("PopUpYes", "cl_onPopUpResponse")
    self.gui:setButtonCallback("PopUpNo", "cl_onPopUpResponse")
    
    self.gui:setOnCloseCallback("cl_onClose")
end

function UIManager:open()
    if not self.gui then self:create() end
    if not self.gui:isActive() then
        self.gui:open()
        self.isOpen = true
    end
end

function UIManager:close()
    if self.gui and self.gui:isActive() then
        self.gui:close()
    end
    self.isOpen = false
end

function UIManager:destroy()
    if self.gui then
        self.gui:destroy()
        self.gui = nil
    end
end

-- --- UPDATE LOOP (Refreshes GUI Text) ---
function UIManager:onFixedUpdate()
    if not self.isOpen or not self.gui then return end
    
    -- 1. Update Status Header
    local statusNames = { [0]="STOPPED", [1]="RACING", [2]="CAUTION", [3]="FORMATION" }
    local statusColors = { [0]="#ff2222", [1]="#22ff22", [2]="#ffff22", [3]="#22ffff" }
    
    local status = self.RC.RaceManager and self.RC.RaceManager.state or 0
    local text = "STATUS: " .. (statusNames[status] or "UNKNOWN")
    self.gui:setText("StatusHeader", text)
    -- Note: TextColour set dynamically isn't supported via Lua directly easily in all versions, usually static.
    
    -- 2. Update Lap Counter
    local laps = self.RC.RaceManager and self.RC.RaceManager.targetLaps or 0
    local curLap = self.RC.RaceManager and self.RC.RaceManager.currentLap or 0
    self.gui:setText("LapCounter", "Lap: " .. curLap .. " / " .. laps)
    
    -- 3. Update Values
    local handi = self.RC.RaceManager and self.RC.RaceManager.handicapMultiplier or 0.0
    local draft = self.RC.RaceManager and self.RC.RaceManager.draftStrength or 0.0
    
    self.gui:setText("ValLaps", tostring(laps))
    self.gui:setText("ValHandi", string.format("%.1f", handi))
    self.gui:setText("ValDraft", string.format("%.1f", draft))
    
    -- 4. Update Toggles Text
    local tires = self.RC.RaceManager and self.RC.RaceManager.tireWearEnabled
    local quali = self.RC.RaceManager and self.RC.RaceManager.qualifying
    
    self.gui:setText("BtnTireWear", "Tires: " .. (tires and "ON" or "OFF"))
    self.gui:setText("BtnQualifying", "Quali: " .. (quali and "ON" or "OFF"))
    
    -- 5. Update Entries Button
    local entries = self.RC.TwitchManager and self.RC.TwitchManager.entriesOpen
    self.gui:setText("BtnEntries", "Entries: " .. (entries and "OPEN" or "CLOSED"))
end

-- --- CALLBACKS ---

function UIManager:cl_onBtnStart() self.RC.network:sendToServer("sv_set_race", 1) end
function UIManager:cl_onBtnStop() self.RC.network:sendToServer("sv_set_race", 0) end
function UIManager:cl_onBtnCaution() self.RC.network:sendToServer("sv_set_race", 2) end
function UIManager:cl_onBtnFormation() self.RC.network:sendToServer("sv_set_race", 3) end

function UIManager:cl_onBtnReset()
    -- Show Confirmation Popup
    self.gui:setVisible("PopUpPanel", true)
    self.confirmAction = "reset"
end

function UIManager:cl_onPopUpResponse(btnName)
    self.gui:setVisible("PopUpPanel", false)
    if btnName == "PopUpYes" and self.confirmAction == "reset" then
        self.RC.network:sendToServer("sv_reset_race")
    end
    self.confirmAction = nil
end

function UIManager:cl_onSettingsChange(btnName)
    if btnName == "BtnLapsAdd" then self.RC.network:sendToServer("sv_editLapCount", 1) end
    if btnName == "BtnLapsSub" then self.RC.network:sendToServer("sv_editLapCount", -1) end
    if btnName == "BtnHandiAdd" then self.RC.network:sendToServer("sv_editHandicap", 0.1) end
    if btnName == "BtnHandiSub" then self.RC.network:sendToServer("sv_editHandicap", -0.1) end
    if btnName == "BtnDraftAdd" then self.RC.network:sendToServer("sv_editDraft", 0.1) end
    if btnName == "BtnDraftSub" then self.RC.network:sendToServer("sv_editDraft", -0.1) end
end

function UIManager:cl_onToggleSetting(btnName)
    if btnName == "BtnTireWear" then self.RC.network:sendToServer("sv_toggleTireWear") end
    if btnName == "BtnQualifying" then self.RC.network:sendToServer("sv_toggleQualifying") end
end

function UIManager:cl_onBtnEntries()
    self.RC.network:sendToServer("sv_toggleEntries")
end

function UIManager:cl_onClose()
    self.isOpen = false
end

return UIManager