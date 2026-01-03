-- UIManager.lua
UIManager = class(nil)

local GUI_LAYOUT = "$CONTENT_DATA/Gui/Layouts/RCGen8.layout"

function UIManager:init(raceControl)
    self.RC = raceControl
    self.gui = nil
    self.isOpen = false
    self.confirmAction = nil 
    
    -- [[ FIX: INJECT CALLBACKS INTO ROUTER ]]
    -- SM GUI expects callbacks on the main Script Class instance (RaceControl)
    -- We forward them to self.UIManager methods here.
    local rc = self.RC
    rc.cl_onBtnStart = function(self) self.UIManager:cl_onBtnStart() end
    rc.cl_onBtnStop = function(self) self.UIManager:cl_onBtnStop() end
    rc.cl_onBtnCaution = function(self) self.UIManager:cl_onBtnCaution() end
    rc.cl_onBtnFormation = function(self) self.UIManager:cl_onBtnFormation() end
    rc.cl_onBtnEntries = function(self) self.UIManager:cl_onBtnEntries() end
    rc.cl_onBtnReset = function(self) self.UIManager:cl_onBtnReset() end
    rc.cl_onSettingsChange = function(self, btn) self.UIManager:cl_onSettingsChange(btn) end
    rc.cl_onToggleSetting = function(self, btn) self.UIManager:cl_onToggleSetting(btn) end
    rc.cl_onBtnLearning = function(self) self.UIManager:cl_onBtnLearning() end
    rc.cl_onPopUpResponse = function(self, btn) self.UIManager:cl_onPopUpResponse(btn) end
    rc.cl_onClose = function(self) self.UIManager:cl_onClose() end
end

function UIManager:create()
    if self.gui then return end
    self.gui = sm.gui.createGuiFromLayout(GUI_LAYOUT, false, { isHud = false, isInteractive = true, needsCursor = true })
    self.gui:setButtonCallback("BtnStart", "cl_onBtnStart")
    self.gui:setButtonCallback("BtnStop", "cl_onBtnStop")
    self.gui:setButtonCallback("BtnCaution", "cl_onBtnCaution")
    self.gui:setButtonCallback("BtnFormation", "cl_onBtnFormation")
    self.gui:setButtonCallback("BtnEntries", "cl_onBtnEntries")
    self.gui:setButtonCallback("BtnReset", "cl_onBtnReset")
    self.gui:setButtonCallback("BtnLapsAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnLapsSub", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnHandiAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnHandiSub", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnDraftAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnDraftSub", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnTireWear", "cl_onToggleSetting")
    self.gui:setButtonCallback("BtnTireHeat", "cl_onToggleSetting")
    self.gui:setButtonCallback("BtnFuelUsage", "cl_onToggleSetting")
    self.gui:setButtonCallback("BtnWearMultAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnWearMultSub", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnFuelMultAdd", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnFuelMultSub", "cl_onSettingsChange")
    self.gui:setButtonCallback("BtnQualifying", "cl_onToggleSetting")
    self.gui:setButtonCallback("BtnLearning", "cl_onBtnLearning")
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

function UIManager:onFixedUpdate()
    if not self.isOpen or not self.gui then return end
    
    -- 1. Update Status Header using networked metadata
    local statusNames = { [0]="STOPPED", [1]="RACING", [2]="CAUTION", [3]="FORMATION" }
    -- Check raceMetaData first (client sync), fallback to 0
    local meta = self.RC.raceMetaData or {}
    local status = meta.status or 0
    
    local text = "STATUS: " .. (statusNames[status] or "UNKNOWN")
    self.gui:setText("StatusHeader", text)
    
    -- 2. Update Lap Counter
    local laps = self.RC.targetLaps or 0 -- Client-side variable
    local curLap = self.RC.currentLap or 0 -- Client-side variable
    -- If using metaData:
    -- local laps = meta.lapsTotal or 0
    -- local curLap = meta.lapsCurrent or 0
    
    -- Fallback to reading RC properties directly if they are synced via network elsewhere
    if self.RC.raceMetaData then
         -- Assuming raceMetaData structure from RaceControlGen8:
         -- { status, lapsLeft, qualifying }
         -- We might need to reconstruct current lap if only lapsLeft is sent
         -- For now, use RC properties assuming they are synced.
    end

    self.gui:setText("LapCounter", "Lap: " .. curLap .. " / " .. laps)

    -- 3. Update Values (Handicap/Draft)
    -- These need to be synced variables on the client side of RaceControl
    local handi = self.RC.handiCapMultiplier or 0.0
    local draft = self.RC.draftStrength or 0.0
    
    self.gui:setText("ValLaps", tostring(laps))
    self.gui:setText("ValHandi", string.format("%.1f", handi))
    self.gui:setText("ValDraft", string.format("%.1f", draft))
    
    -- 4. Update Toggles
    local tires = meta.tires or false
    local heat = meta.tireHeat or false
    local fuel = meta.fuelEnabled or false
    local quali = self.RC.qualifying 
    
    local wearMult = meta.tireWearMult or 1.0
    local fuelMult = meta.fuelMult or 1.0
    
    -- If qualifying is in metadata string "true"/"false"
    if meta.qualifying == "true" then quali = true end
    
    self.gui:setText("BtnTireWear", "Tires: " .. (tires and "ON" or "OFF"))
    self.gui:setText("BtnTireHeat", "Heat: " .. (heat and "ON" or "OFF"))
    self.gui:setText("BtnFuelUsage", "Fuel: " .. (fuel and "ON" or "OFF"))
    self.gui:setText("ValWearMult", string.format("%.1fx", wearMult))
    self.gui:setText("ValFuelMult", string.format("%.1fx", fuelMult))
    self.gui:setText("BtnQualifying", "Quali: " .. (quali and "ON" or "OFF"))
    
    local learningLocked = meta.learningLocked or false
    -- We invert logic for the button text: if Locked, Learning is OFF (or Restricted)
    -- Actually user wants "Learning Lock" button or "Learning" button?
    -- User asked: "Learning Lock button". So if ON -> Locked. If OFF -> Unlocked.
    -- Let's stick to "LEARN: ON" (Unlocked) vs "LEARN: LOCK" (Locked)
    self.gui:setText("BtnLearning", "LEARN: " .. (learningLocked and "LOCK" or "ON"))
    
    -- 5. Update Entries Button
    -- Entries state is likely managed by TwitchManager logic but needs client visibility
    -- If not synced, default to unknown or check RC flag
    local entries = self.RC.entriesOpen
    self.gui:setText("BtnEntries", "Entries: " .. (entries and "OPEN" or "CLOSED"))
end

function UIManager:cl_onBtnStart() self.RC.network:sendToServer("sv_set_race", 1) end
function UIManager:cl_onBtnStop() self.RC.network:sendToServer("sv_set_race", 0) end
function UIManager:cl_onBtnCaution() self.RC.network:sendToServer("sv_set_race", 2) end
function UIManager:cl_onBtnFormation() self.RC.network:sendToServer("sv_set_race", 3) end

function UIManager:cl_onBtnReset()
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
    if btnName == "BtnWearMultAdd" then self.RC.network:sendToServer("sv_editTireWearMultiplier", 0.1) end
    if btnName == "BtnWearMultSub" then self.RC.network:sendToServer("sv_editTireWearMultiplier", -0.1) end
    if btnName == "BtnFuelMultAdd" then self.RC.network:sendToServer("sv_editFuelUsageMultiplier", 0.1) end
    if btnName == "BtnFuelMultSub" then self.RC.network:sendToServer("sv_editFuelUsageMultiplier", -0.1) end
end

function UIManager:cl_onToggleSetting(btnName)
    if btnName == "BtnTireWear" then self.RC.network:sendToServer("sv_toggleTireWear") end
    if btnName == "BtnTireHeat" then self.RC.network:sendToServer("sv_toggleTireHeat") end
    if btnName == "BtnFuelUsage" then self.RC.network:sendToServer("sv_toggleFuelUsage") end
    if btnName == "BtnQualifying" then self.RC.network:sendToServer("sv_toggleQualifying") end
end

function UIManager:cl_onBtnEntries()
    self.RC.network:sendToServer("sv_toggleEntries")
end

function UIManager:cl_onBtnLearning()
    self.RC.network:sendToServer("sv_toggleLearningLock")
end

function UIManager:cl_onClose()
    self.isOpen = false
end

return UIManager