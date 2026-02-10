-- AbilityAlert: Notify a friend when you use specific abilities
local addonName = "AbilityAlert"
local VERSION = "1.0"

-- Saved variables (persists between sessions)
AbilityAlertDB = AbilityAlertDB or {
    enabled = true,
    friendName = "",  -- Set this to your friend's character name
    abilities = {},   -- Abilities to track (spellID -> true)
    debugMode = false, -- Enable debug logging
    displayMode = "whisper" -- Display mode: "whisper", "nameplate", "both"
}

-- Active auras tracking (spellID -> {target, expirationTime, timerHandle})
local activeAuras = {}
-- Nameplate frames tracking
local nameplateFrames = {}
local nameplatePool = {}

-- Create the main frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

-- GUI Configuration Frame
local configFrame = nil
local abilityIcons = {}

-- Event handler
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == addonName then
            self:OnAddonLoaded()
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        self:OnCombatLog()
    elseif event == "CHAT_MSG_WHISPER" then
        self:OnWhisperReceived(...)
    elseif event == "GROUP_ROSTER_UPDATE" then
        self:OnGroupRosterUpdate()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        self:OnNameplateAdded(...)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        self:OnNameplateRemoved(...)
    end
end)

-- Debug logging function
local function DebugLog(message)
    if AbilityAlertDB.debugMode then
        print("|cff888888[DEBUG]|r " .. message)
    end
end

-- Check if player is in group/raid
local function IsPlayerInGroup(playerName)
    if not playerName or playerName == "" then return false end
    
    -- Remove realm if it's the same as player's realm
    local name, realm = strsplit("-", playerName)
    if not realm then
        name = playerName
    end
    
    local numGroupMembers = GetNumGroupMembers()
    if numGroupMembers == 0 then
        DebugLog("Not in a group")
        return false
    end
    
    local isRaid = IsInRaid()
    for i = 1, numGroupMembers do
        local unit = isRaid and "raid"..i or "party"..i
        if i == numGroupMembers and not isRaid then
            unit = "player"  -- Check player in party
        end
        
        local unitName, unitRealm = UnitName(unit)
        if unitName then
            local fullName = unitRealm and unitRealm ~= "" and (unitName .. "-" .. unitRealm) or unitName
            if fullName == playerName or unitName == name then
                DebugLog("Found player in group: " .. fullName)
                return true
            end
        end
    end
    
    return false
end

-- Initialize addon
function frame:OnAddonLoaded()
    print("|cff00ff00AbilityAlert|r v" .. VERSION .. " loaded!")
    print("Type |cffff9900/aa config|r to open configuration")
    
    -- Make sure saved variables exist
    if not AbilityAlertDB.abilities then
        AbilityAlertDB.abilities = {}
    end
    if AbilityAlertDB.debugMode == nil then
        AbilityAlertDB.debugMode = false
    end
    if not AbilityAlertDB.displayMode then
        AbilityAlertDB.displayMode = "whisper"
    end
    
    DebugLog("Addon initialized")
    DebugLog("Enabled: " .. tostring(AbilityAlertDB.enabled))
    DebugLog("Friend: " .. (AbilityAlertDB.friendName or "none"))
    DebugLog("Display Mode: " .. AbilityAlertDB.displayMode)
end

-- Handle group roster updates
function frame:OnGroupRosterUpdate()
    DebugLog("Group roster updated")
    if configFrame and configFrame:IsShown() then
        UpdateGroupValidation()
    end
end

-- Get spell duration from auras
local function GetAuraDuration(unit, spellID)
    for i = 1, 40 do
        local name, _, _, _, duration, expirationTime, _, _, _, id = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if id == spellID then
            return duration, expirationTime
        end
    end
    for i = 1, 40 do
        local name, _, _, _, duration, expirationTime, _, _, _, id = UnitAura(unit, i, "HARMFUL")
        if not name then break end
        if id == spellID then
            return duration, expirationTime
        end
    end
    return nil, nil
end

-- Send expiration message
local function SendExpirationMessage(spellID, targetName)
    local spellName = GetSpellInfo(spellID)
    local friendName = AbilityAlertDB.friendName
    local displayMode = AbilityAlertDB.displayMode
    
    if displayMode == "whisper" or displayMode == "both" then
        if friendName and friendName ~= "" and IsPlayerInGroup(friendName) then
            local message = string.format("[AbilityAlert] %s expired on %s", spellName or "Unknown", targetName)
            SendChatMessage(message, "WHISPER", nil, friendName)
            DebugLog("Sent expiration message for " .. (spellName or "Unknown"))
        end
    end
end

-- Get or create nameplate icon container
local function GetNameplateContainer(nameplate)
    if not nameplate.AbilityAlertIcons then
        local container = CreateFrame("Frame", nil, nameplate)
        container:SetSize(200, 30)
        container:SetPoint("BOTTOM", nameplate, "TOP", 0, 5)
        container.icons = {}
        nameplate.AbilityAlertIcons = container
    end
    return nameplate.AbilityAlertIcons
end

-- Update nameplate icons for a unit
local function UpdateNameplateIcons(unitToken)
    local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
    if not nameplate then return end
    
    local container = GetNameplateContainer(nameplate)
    
    -- Hide all existing icons first
    for _, icon in ipairs(container.icons) do
        icon:Hide()
    end
    
    -- Check for tracked auras on this unit
    local activeIcons = {}
    for i = 1, 40 do
        local name, texture, count, _, duration, expirationTime, caster, _, _, spellID = UnitAura(unitToken, i, "HELPFUL")
        if not name then break end
        
        if caster == "player" and AbilityAlertDB.abilities[spellID] then
            table.insert(activeIcons, {spellID = spellID, texture = texture, expirationTime = expirationTime, duration = duration})
        end
    end
    
    for i = 1, 40 do
        local name, texture, count, _, duration, expirationTime, caster, _, _, spellID = UnitAura(unitToken, i, "HARMFUL")
        if not name then break end
        
        if caster == "player" and AbilityAlertDB.abilities[spellID] then
            table.insert(activeIcons, {spellID = spellID, texture = texture, expirationTime = expirationTime, duration = duration})
        end
    end
    
    -- Create/update icons
    for idx, auraData in ipairs(activeIcons) do
        local icon = container.icons[idx]
        if not icon then
            icon = CreateFrame("Frame", nil, container)
            icon:SetSize(24, 24)
            
            icon.texture = icon:CreateTexture(nil, "ARTWORK")
            icon.texture:SetAllPoints()
            icon.texture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
            
            icon.border = icon:CreateTexture(nil, "OVERLAY")
            icon.border:SetAllPoints()
            icon.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            icon.border:SetBlendMode("ADD")
            
            icon.cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
            icon.cooldown:SetAllPoints()
            icon.cooldown:SetDrawEdge(false)
            
            container.icons[idx] = icon
        end
        
        icon.texture:SetTexture(auraData.texture)
        icon:SetPoint("LEFT", (idx - 1) * 28, 0)
        
        if auraData.duration and auraData.duration > 0 then
            icon.cooldown:SetCooldown(auraData.expirationTime - auraData.duration, auraData.duration)
        end
        
        icon:Show()
    end
end

-- Handle nameplate added
function frame:OnNameplateAdded(unitToken)
    local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
    if nameplate then
        nameplateFrames[unitToken] = nameplate
        DebugLog("Nameplate added for " .. unitToken)
        
        if AbilityAlertDB.displayMode == "nameplate" or AbilityAlertDB.displayMode == "both" then
            UpdateNameplateIcons(unitToken)
        end
    end
end

-- Handle nameplate removed
function frame:OnNameplateRemoved(unitToken)
    nameplateFrames[unitToken] = nil
    DebugLog("Nameplate removed for " .. unitToken)
end

-- Handle combat log events
function frame:OnCombatLog()
    local timestamp, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _, spellID, spellName = CombatLogGetCurrentEventInfo()
    
    if not AbilityAlertDB.enabled then return end
    if not AbilityAlertDB.abilities[spellID] then return end
    
    local playerGUID = UnitGUID("player")
    if sourceGUID ~= playerGUID then return end
    
    -- Handle aura application (buffs/debuffs)
    if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH" then
        DebugLog("Tracked aura applied: " .. spellName .. " on " .. (destName or "Unknown"))
        
        local friendName = AbilityAlertDB.friendName
        local displayMode = AbilityAlertDB.displayMode
        
        if displayMode == "whisper" or displayMode == "both" then
            if not friendName or friendName == "" then
                print("|cffff0000AbilityAlert:|r No recipient set! Use /aa config to set one")
                return
            end
            
            if not IsPlayerInGroup(friendName) then
                print("|cffff0000AbilityAlert:|r " .. friendName .. " is not in your group/raid!")
                return
            end
        end
        
        -- Try to get duration from the aura
        local duration, expirationTime = GetAuraDuration(destGUID and "target" or "player", spellID)
        
        -- If we can't find it, try to get it from common units
        if not duration then
            local units = {"player", "target", "focus", "mouseover"}
            for _, unit in ipairs(units) do
                if UnitExists(unit) and UnitGUID(unit) == destGUID then
                    duration, expirationTime = GetAuraDuration(unit, spellID)
                    if duration then break end
                end
            end
        end
        
        -- Send message if in whisper mode
        if displayMode == "whisper" or displayMode == "both" then
            local message
            if duration and duration > 0 then
                message = string.format("[AbilityAlert] %s used on %s (Duration: %.1fs)", spellName, destName or "Unknown", duration)
            else
                message = string.format("[AbilityAlert] %s used on %s", spellName, destName or "Unknown")
            end
            
            SendChatMessage(message, "WHISPER", nil, friendName)
            print("|cff00ff00AbilityAlert:|r Sent notification to " .. friendName)
        end
        
        -- Update nameplates if in nameplate mode
        if displayMode == "nameplate" or displayMode == "both" then
            -- Find the unit token for the destination
            if destGUID then
                for unitToken, _ in pairs(nameplateFrames) do
                    if UnitExists(unitToken) and UnitGUID(unitToken) == destGUID then
                        C_Timer.After(0.1, function()
                            UpdateNameplateIcons(unitToken)
                        end)
                        break
                    end
                end
            end
        end
        
        -- Schedule expiration message if duration exists
        if duration and duration > 0 and expirationTime then
            -- Cancel existing timer for this spell on this target if any
            local key = spellID .. "_" .. (destName or "Unknown")
            if activeAuras[key] and activeAuras[key].timerHandle then
                activeAuras[key].timerHandle:Cancel()
            end
            
            -- Create new timer
            local timerHandle = C_Timer.NewTimer(duration, function()
                SendExpirationMessage(spellID, destName or "Unknown")
                activeAuras[key] = nil
            end)
            
            activeAuras[key] = {
                target = destName,
                expirationTime = expirationTime,
                timerHandle = timerHandle
            }
        end
        
    -- Handle aura removal
    elseif subevent == "SPELL_AURA_REMOVED" then
        DebugLog("Tracked aura removed: " .. spellName .. " from " .. (destName or "Unknown"))
        
        -- Cancel scheduled expiration message since it was removed early
        local key = spellID .. "_" .. (destName or "Unknown")
        if activeAuras[key] then
            if activeAuras[key].timerHandle then
                activeAuras[key].timerHandle:Cancel()
            end
            
            -- Send expiration message
            local displayMode = AbilityAlertDB.displayMode
            if displayMode == "whisper" or displayMode == "both" then
                local friendName = AbilityAlertDB.friendName
                if friendName and friendName ~= "" and IsPlayerInGroup(friendName) then
                    local message = string.format("[AbilityAlert] %s expired on %s", spellName, destName or "Unknown")
                    SendChatMessage(message, "WHISPER", nil, friendName)
                end
            end
            
            -- Update nameplates
            if displayMode == "nameplate" or displayMode == "both" then
                if destGUID then
                    for unitToken, _ in pairs(nameplateFrames) do
                        if UnitExists(unitToken) and UnitGUID(unitToken) == destGUID then
                            UpdateNameplateIcons(unitToken)
                            break
                        end
                    end
                end
            end
            
            activeAuras[key] = nil
        end
        
    -- Handle instant cast spells (no aura)
    elseif subevent == "SPELL_CAST_SUCCESS" then
        -- Check if this spell applies an aura by waiting a bit
        C_Timer.After(0.1, function()
            local hasAura = false
            if destGUID then
                local units = {"player", "target", "focus", "mouseover"}
                for _, unit in ipairs(units) do
                    if UnitExists(unit) and UnitGUID(unit) == destGUID then
                        local _, _ = GetAuraDuration(unit, spellID)
                        if _ then
                            hasAura = true
                            break
                        end
                    end
                end
            end
            
            -- Only send message for instant abilities without auras
            if not hasAura then
                DebugLog("Instant ability cast: " .. spellName)
                local displayMode = AbilityAlertDB.displayMode
                
                if displayMode == "whisper" or displayMode == "both" then
                    local friendName = AbilityAlertDB.friendName
                    if friendName and friendName ~= "" and IsPlayerInGroup(friendName) then
                        local message = string.format("[AbilityAlert] %s used on %s", spellName, destName or "Unknown")
                        SendChatMessage(message, "WHISPER", nil, friendName)
                        print("|cff00ff00AbilityAlert:|r Sent notification to " .. friendName)
                    end
                end
            end
        end)
    end
end

-- Handle incoming whispers (display alerts from friend)
function frame:OnWhisperReceived(message, sender)
    DebugLog("Whisper received from " .. sender .. ": " .. message)
    
    if not AbilityAlertDB.enabled then 
        DebugLog("Addon disabled, ignoring whisper")
        return 
    end
    
    -- Check if message is from AbilityAlert
    if string.match(message, "^%[AbilityAlert%]") then
        DebugLog("AbilityAlert message detected, displaying notification")
        -- Display as a raid warning style message
        RaidNotice_AddMessage(RaidWarningFrame, message, ChatTypeInfo["RAID_WARNING"])
        print("|cffff9900" .. sender .. ":|r " .. message)
        
        -- Optional: Play a sound
        PlaySound(8959) -- "ReadyCheck" sound
    end
end

-- Get all spells from player's spellbook
local function GetPlayerSpells()
    local spells = {}
    local i = 1
    
    while true do
        local spellName, _, spellID = GetSpellBookItemName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        
        local spellType = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
        if spellType ~= "FUTURESPELL" and spellType ~= "FLYOUT" and spellID then
            local texture = GetSpellTexture(spellID)
            if texture then
                table.insert(spells, {id = spellID, name = spellName, texture = texture})
            end
        end
        
        i = i + 1
    end
    
    return spells
end

-- Create Configuration GUI
function CreateConfigFrame()
    if configFrame then return configFrame end
    
    configFrame = CreateFrame("Frame", "AbilityAlertConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    configFrame:SetSize(620, 500)
    configFrame:SetPoint("CENTER")
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:Hide()
    
    configFrame.title = configFrame:CreateFontString(nil, "OVERLAY")
    configFrame.title:SetFontObject("GameFontHighlight")
    configFrame.title:SetPoint("CENTER", configFrame.TitleBg, "CENTER", 5, 0)
    configFrame.title:SetText("AbilityAlert Configuration")
    
    -- Enable/Disable checkbox
    configFrame.enableCheckbox = CreateFrame("CheckButton", nil, configFrame, "UICheckButtonTemplate")
    configFrame.enableCheckbox:SetPoint("TOPLEFT", 20, -35)
    configFrame.enableCheckbox.text:SetText("Enable AbilityAlert")
    configFrame.enableCheckbox:SetChecked(AbilityAlertDB.enabled)
    configFrame.enableCheckbox:SetScript("OnClick", function(self)
        AbilityAlertDB.enabled = self:GetChecked()
        print("|cff00ff00AbilityAlert:|r " .. (AbilityAlertDB.enabled and "Enabled" or "Disabled"))
    end)
    
    -- Display Mode section
    configFrame.displayModeLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    configFrame.displayModeLabel:SetPoint("TOPLEFT", 20, -75)
    configFrame.displayModeLabel:SetText("Display Mode:")
    
    configFrame.whisperRadio = CreateFrame("CheckButton", nil, configFrame, "UIRadioButtonTemplate")
    configFrame.whisperRadio:SetPoint("TOPLEFT", 120, -72)
    configFrame.whisperRadio.text:SetText("Whisper")
    configFrame.whisperRadio:SetChecked(AbilityAlertDB.displayMode == "whisper")
    configFrame.whisperRadio:SetScript("OnClick", function()
        AbilityAlertDB.displayMode = "whisper"
        configFrame.whisperRadio:SetChecked(true)
        configFrame.nameplateRadio:SetChecked(false)
        configFrame.bothRadio:SetChecked(false)
        UpdateRecipientVisibility()
    end)
    
    configFrame.nameplateRadio = CreateFrame("CheckButton", nil, configFrame, "UIRadioButtonTemplate")
    configFrame.nameplateRadio:SetPoint("LEFT", configFrame.whisperRadio, "RIGHT", 80, 0)
    configFrame.nameplateRadio.text:SetText("Nameplate")
    configFrame.nameplateRadio:SetChecked(AbilityAlertDB.displayMode == "nameplate")
    configFrame.nameplateRadio:SetScript("OnClick", function()
        AbilityAlertDB.displayMode = "nameplate"
        configFrame.whisperRadio:SetChecked(false)
        configFrame.nameplateRadio:SetChecked(true)
        configFrame.bothRadio:SetChecked(false)
        UpdateRecipientVisibility()
    end)
    
    configFrame.bothRadio = CreateFrame("CheckButton", nil, configFrame, "UIRadioButtonTemplate")
    configFrame.bothRadio:SetPoint("LEFT", configFrame.nameplateRadio, "RIGHT", 100, 0)
    configFrame.bothRadio.text:SetText("Both")
    configFrame.bothRadio:SetChecked(AbilityAlertDB.displayMode == "both")
    configFrame.bothRadio:SetScript("OnClick", function()
        AbilityAlertDB.displayMode = "both"
        configFrame.whisperRadio:SetChecked(false)
        configFrame.nameplateRadio:SetChecked(false)
        configFrame.bothRadio:SetChecked(true)
        UpdateRecipientVisibility()
    end)
    
    -- Recipient Name Label
    configFrame.recipientLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    configFrame.recipientLabel:SetPoint("TOPLEFT", 20, -110)
    configFrame.recipientLabel:SetText("Recipient (Name-Server):")
    
    -- Recipient EditBox
    configFrame.recipientBox = CreateFrame("EditBox", nil, configFrame, "InputBoxTemplate")
    configFrame.recipientBox:SetSize(200, 20)
    configFrame.recipientBox:SetPoint("TOPLEFT", 20, -130)
    configFrame.recipientBox:SetAutoFocus(false)
    configFrame.recipientBox:SetText(AbilityAlertDB.friendName)
    configFrame.recipientBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    configFrame.recipientBox:SetScript("OnTextChanged", function(self)
        AbilityAlertDB.friendName = self:GetText()
        UpdateGroupValidation()
    end)
    
    -- Group validation status
    configFrame.groupStatus = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    configFrame.groupStatus:SetPoint("LEFT", configFrame.recipientBox, "RIGHT", 10, 0)
    
    -- Abilities section
    configFrame.abilitiesLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    configFrame.abilitiesLabel:SetPoint("TOPLEFT", 20, -170)
    configFrame.abilitiesLabel:SetText("Your Class Abilities (Click to Track):")
    
    -- Scroll frame for abilities
    configFrame.scrollFrame = CreateFrame("ScrollFrame", nil, configFrame, "UIPanelScrollFrameTemplate")
    configFrame.scrollFrame:SetPoint("TOPLEFT", 20, -195)
    configFrame.scrollFrame:SetPoint("BOTTOMRIGHT", -35, 40)
    
    configFrame.scrollChild = CreateFrame("Frame")
    configFrame.scrollFrame:SetScrollChild(configFrame.scrollChild)
    configFrame.scrollChild:SetWidth(configFrame.scrollFrame:GetWidth())
    configFrame.scrollChild:SetHeight(1)
    
    -- Close button
    configFrame.closeButton = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    configFrame.closeButton:SetSize(80, 22)
    configFrame.closeButton:SetPoint("BOTTOM", 0, 10)
    configFrame.closeButton:SetText("Close")
    configFrame.closeButton:SetScript("OnClick", function()
        configFrame:Hide()
    end)
    
    configFrame:SetScript("OnShow", function()
        UpdateAbilitiesList()
        UpdateGroupValidation()
        UpdateRecipientVisibility()
    end)
    
    return configFrame
end

-- Update recipient field visibility based on display mode
function UpdateRecipientVisibility()
    if not configFrame then return end
    
    local displayMode = AbilityAlertDB.displayMode
    local needsRecipient = displayMode == "whisper" or displayMode == "both"
    
    if needsRecipient then
        configFrame.recipientLabel:Show()
        configFrame.recipientBox:Show()
        configFrame.groupStatus:Show()
    else
        configFrame.recipientLabel:Hide()
        configFrame.recipientBox:Hide()
        configFrame.groupStatus:Hide()
    end
end

-- Update group validation status
function UpdateGroupValidation()
    if not configFrame then return end
    
    local friendName = AbilityAlertDB.friendName
    if not friendName or friendName == "" then
        configFrame.groupStatus:SetText("|cff888888Not set|r")
        return
    end
    
    if IsPlayerInGroup(friendName) then
        configFrame.groupStatus:SetText("|cff00ff00✓ In Group|r")
    else
        configFrame.groupStatus:SetText("|cffff0000✗ Not in Group|r")
    end
end

-- Update abilities list
function UpdateAbilitiesList()
    if not configFrame then return end
    
    -- Clear existing icons
    for _, icon in ipairs(abilityIcons) do
        icon:Hide()
        icon:SetParent(nil)
    end
    wipe(abilityIcons)
    
    -- Get player spells
    local spells = GetPlayerSpells()
    
    if #spells == 0 then
        local emptyText = configFrame.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyText:SetPoint("TOPLEFT", 10, -10)
        emptyText:SetText("|cff888888No abilities found in your spellbook.|r")
        table.insert(abilityIcons, emptyText)
        configFrame.scrollChild:SetHeight(configFrame.scrollFrame:GetHeight())
        return
    end
    
    -- Create icon grid
    local iconSize = 36
    local padding = 4
    local iconsPerRow = 12
    local row = 0
    local col = 0
    
    for _, spell in ipairs(spells) do
        local iconButton = CreateFrame("Button", nil, configFrame.scrollChild)
        iconButton:SetSize(iconSize, iconSize)
        iconButton:SetPoint("TOPLEFT", 5 + (col * (iconSize + padding)), -5 - (row * (iconSize + padding)))
        
        -- Icon texture
        local texture = iconButton:CreateTexture(nil, "ARTWORK")
        texture:SetAllPoints()
        texture:SetTexture(spell.texture)
        iconButton.texture = texture
        iconButton.spellID = spell.id
        iconButton.spellName = spell.name
        
        -- Border
        local border = iconButton:CreateTexture(nil, "OVERLAY")
        border:SetAllPoints()
        border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        border:SetBlendMode("ADD")
        border:Hide()
        iconButton.border = border
        
        -- Set desaturation based on tracking status
        if AbilityAlertDB.abilities[spell.id] then
            texture:SetDesaturation(0)
            border:Show()
        else
            texture:SetDesaturation(1)
        end
        
        -- Click handler
        iconButton:SetScript("OnClick", function(self)
            if AbilityAlertDB.abilities[self.spellID] then
                AbilityAlertDB.abilities[self.spellID] = nil
                self.texture:SetDesaturation(1)
                self.border:Hide()
                print("|cff00ff00AbilityAlert:|r Untracked: " .. self.spellName)
            else
                AbilityAlertDB.abilities[self.spellID] = true
                self.texture:SetDesaturation(0)
                self.border:Show()
                print("|cff00ff00AbilityAlert:|r Tracking: " .. self.spellName)
            end
        end)
        
        -- Tooltip
        iconButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.spellID)
            GameTooltip:AddLine(" ")
            if AbilityAlertDB.abilities[self.spellID] then
                GameTooltip:AddLine("|cff00ff00Click to untrack|r", 1, 1, 1)
            else
                GameTooltip:AddLine("|cff888888Click to track|r", 1, 1, 1)
            end
            GameTooltip:Show()
        end)
        
        iconButton:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
        
        table.insert(abilityIcons, iconButton)
        
        col = col + 1
        if col >= iconsPerRow then
            col = 0
            row = row + 1
        end
    end
    
    local totalHeight = math.max((row + 1) * (iconSize + padding) + 10, configFrame.scrollFrame:GetHeight())
    configFrame.scrollChild:SetHeight(totalHeight)
end

-- Slash command handling
SLASH_ABILITYALERT1 = "/aa"
SLASH_ABILITYALERT2 = "/abilityalert"

SlashCmdList["ABILITYALERT"] = function(msg)
    local cmd, arg = string.match(msg, "^(%S+)%s*(.*)$")
    if not cmd then cmd = msg end
    cmd = string.lower(cmd)
    
    if cmd == "" then
        -- Open config GUI when typing /aa alone
        CreateConfigFrame()
        if configFrame:IsShown() then
            configFrame:Hide()
        else
            configFrame:Show()
        end
        
    elseif cmd == "help" then
        print("|cff00ff00AbilityAlert Commands:|r")
        print("|cffff9900/aa|r - Open configuration window")
        print("|cffff9900/aa config|r - Open configuration window")
        print("|cffff9900/aa status|r - Show current configuration")
        print("|cffff9900/aa toggle|r - Enable/disable notifications")
        print("|cffff9900/aa test|r - Send a test message")
        print("|cffff9900/aa debug|r - Toggle debug mode")
        print(" ")
        print("|cff888888Legacy commands:|r")
        print("|cff888888/aa friend <name>|r - Set recipient via command")
        print("|cff888888/aa list|r - List tracked abilities")
        print("|cff888888/aa remove <spellID>|r - Remove ability by ID")
        print("|cff888888/aa clear|r - Clear all abilities")
        
    elseif cmd == "friend" then
        if arg and arg ~= "" then
            AbilityAlertDB.friendName = arg
            print("|cff00ff00AbilityAlert:|r Friend set to: " .. arg)
        else
            print("|cffff0000AbilityAlert:|r Please specify a friend name: /aa friend Name")
        end
        
    elseif cmd == "list" then
        print("|cff00ff00AbilityAlert:|r Tracked abilities:")
        local count = 0
        for spellID in pairs(AbilityAlertDB.abilities) do
            local name = GetSpellInfo(spellID)
            print("  - " .. (name or "Unknown") .. " (ID: " .. spellID .. ")")
            count = count + 1
        end
        if count == 0 then
            print("  (none)")
        end
        
    elseif cmd == "remove" then
        local spellID = tonumber(arg)
        if spellID and AbilityAlertDB.abilities[spellID] then
            AbilityAlertDB.abilities[spellID] = nil
            print("|cff00ff00AbilityAlert:|r Removed ability ID: " .. spellID)
            if configFrame and configFrame:IsShown() then
                UpdateAbilitiesList()
            end
        else
            print("|cffff0000AbilityAlert:|r Invalid spell ID or ability not tracked")
        end
        
    elseif cmd == "clear" then
        AbilityAlertDB.abilities = {}
        print("|cff00ff00AbilityAlert:|r All abilities cleared")
        if configFrame and configFrame:IsShown() then
            UpdateAbilitiesList()
        end
        
    elseif cmd == "toggle" then
        AbilityAlertDB.enabled = not AbilityAlertDB.enabled
        print("|cff00ff00AbilityAlert:|r " .. (AbilityAlertDB.enabled and "Enabled" or "Disabled"))
        
    elseif cmd == "test" then
        if AbilityAlertDB.friendName and AbilityAlertDB.friendName ~= "" then
            SendChatMessage("[AbilityAlert] Test message!", "WHISPER", nil, AbilityAlertDB.friendName)
            print("|cff00ff00AbilityAlert:|r Test message sent to " .. AbilityAlertDB.friendName)
        else
            print("|cffff0000AbilityAlert:|r No friend set! Use /aa config or /aa friend YourFriendName")
        end
        
    elseif cmd == "status" then
        print("|cff00ff00AbilityAlert Status:|r")
        print("  Enabled: " .. (AbilityAlertDB.enabled and "|cff00ff00Yes|r" or "|cffff0000No|r"))
        print("  Display Mode: " .. AbilityAlertDB.displayMode)
        if AbilityAlertDB.displayMode ~= "nameplate" then
            print("  Recipient: " .. (AbilityAlertDB.friendName ~= "" and AbilityAlertDB.friendName or "|cff888888(not set)|r"))
            if AbilityAlertDB.friendName ~= "" then
                if IsPlayerInGroup(AbilityAlertDB.friendName) then
                    print("  In Group: |cff00ff00Yes|r")
                else
                    print("  In Group: |cffff0000No|r")
                end
            end
        end
        print("  Debug Mode: " .. (AbilityAlertDB.debugMode and "|cff00ff00On|r" or "|cff888888Off|r"))
        local count = 0
        for _ in pairs(AbilityAlertDB.abilities) do count = count + 1 end
        print("  Tracked Abilities: " .. count)
        
    elseif cmd == "debug" then
        AbilityAlertDB.debugMode = not AbilityAlertDB.debugMode
        print("|cff00ff00AbilityAlert:|r Debug mode " .. (AbilityAlertDB.debugMode and "|cff00ff00enabled|r" or "|cff888888disabled|r"))
        
    elseif cmd == "mockwhisper" then
        local testSender = AbilityAlertDB.friendName ~= "" and AbilityAlertDB.friendName or "TestFriend"
        print("|cff00ff00AbilityAlert:|r Simulating incoming whisper from " .. testSender)
        frame:OnWhisperReceived("[AbilityAlert] Test Ability used on TestTarget (Duration: 10.0s)", testSender)
        
    elseif cmd == "config" then
        CreateConfigFrame()
        if configFrame:IsShown() then
            configFrame:Hide()
        else
            configFrame:Show()
        end
        
    else
        print("|cffff0000AbilityAlert:|r Unknown command. Type /aa help for help")
    end
end
