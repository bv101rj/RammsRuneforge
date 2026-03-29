-------------------------------------------------------------------------------
-- RammsRuneforge — Lightweight DK runeforge mismatch warning
-- Uses LibEditMode for positioning and settings (dropdown per spec).
-- API reference: https://github.com/p3lim-wow/LibEditMode/wiki
-------------------------------------------------------------------------------
local addonName, ns = ...

-- Gate: only load for Death Knights
local _, playerClass = UnitClass("player")
if playerClass ~= "DEATHKNIGHT" then return end

-------------------------------------------------------------------------------
-- Runeforge data (enchant IDs from SpellItemEnchantment)
-- Verify with  /rrf debug  if Blizzard ever changes these.
-------------------------------------------------------------------------------
local RUNEFORGES = {
    [3368] = "Rune of the Fallen Crusader",
    [3370] = "Rune of Razorice",
    [3847] = "Rune of the Stoneskin Gargoyle",
    [6241] = "Rune of Sanguination",
    [6242] = "Rune of Spellwarding",
    [6243] = "Rune of Hysteria",
    [6244] = "Rune of Unending Thirst",
    [6245] = "Rune of the Apocalypse",
}

-- Build sorted list for dropdowns
local RUNEFORGE_SORTED = {}
for id, name in pairs(RUNEFORGES) do
    RUNEFORGE_SORTED[#RUNEFORGE_SORTED + 1] = { id = id, name = name }
end
table.sort(RUNEFORGE_SORTED, function(a, b) return a.name < b.name end)

-- Dropdown values: 0 = none, then each runeforge ID
local DROPDOWN_VALUES = { { text = "None", value = 0 } }
for _, rf in ipairs(RUNEFORGE_SORTED) do
    DROPDOWN_VALUES[#DROPDOWN_VALUES + 1] = { text = rf.name, value = rf.id }
end

local SPEC_NAMES = { "Blood", "Frost", "Unholy" }

-------------------------------------------------------------------------------
-- Saved variables & defaults
-------------------------------------------------------------------------------
local db
local DEFAULT_POSITION = { point = "CENTER", x = 0, y = 200 }

local function EnsureDB()
    if not RammsRuneforgeDB then
        RammsRuneforgeDB = {}
    end
    db = RammsRuneforgeDB
    if not db.specs then db.specs = {} end
    if not db.layouts then db.layouts = {} end
end

-------------------------------------------------------------------------------
-- Mover frame — LibEditMode owns this for positioning
-------------------------------------------------------------------------------
local mover = CreateFrame("Frame", "RammsRuneforgeMover", UIParent)
mover:SetSize(180, 30)
mover:SetPoint(DEFAULT_POSITION.point, DEFAULT_POSITION.x, DEFAULT_POSITION.y)
mover:SetClampedToScreen(true)

-------------------------------------------------------------------------------
-- Bouncing warning (created once, reused)
-------------------------------------------------------------------------------
local warnFrame = CreateFrame("Frame", nil, UIParent)
warnFrame:SetAllPoints(UIParent)
warnFrame:SetFrameStrata("HIGH")
warnFrame:Hide()

local warnText = warnFrame:CreateFontString(nil, "OVERLAY")
warnText:SetFont(STANDARD_TEXT_FONT, 30, "OUTLINE")
warnText:SetTextColor(1, 0.2, 0.2)
warnText:SetPoint("CENTER", mover, "CENTER", 0, 0)
warnText:SetText("CHANGE YOUR RUNEFORGE!")

-- GPU-side animations: bounce + pulse
local ag = warnText:CreateAnimationGroup()
ag:SetLooping("REPEAT")

local moveUp = ag:CreateAnimation("Translation")
moveUp:SetOffset(0, 18)
moveUp:SetDuration(0.35)
moveUp:SetOrder(1)
moveUp:SetSmoothing("OUT")

local moveDown = ag:CreateAnimation("Translation")
moveDown:SetOffset(0, -18)
moveDown:SetDuration(0.35)
moveDown:SetOrder(2)
moveDown:SetSmoothing("IN")

local scaleUp = ag:CreateAnimation("Scale")
scaleUp:SetScaleFrom(1, 1)
scaleUp:SetScaleTo(1.08, 1.08)
scaleUp:SetDuration(0.35)
scaleUp:SetOrder(1)
scaleUp:SetSmoothing("OUT")

local scaleDown = ag:CreateAnimation("Scale")
scaleDown:SetScaleFrom(1.08, 1.08)
scaleDown:SetScaleTo(1, 1)
scaleDown:SetDuration(0.35)
scaleDown:SetOrder(2)
scaleDown:SetSmoothing("IN")

-- Timed fade-out
local WARN_DURATION    = 6
local WARN_COOLDOWN    = 30
local lastWarnTime     = 0

local fadeOut = warnFrame:CreateAnimationGroup()
local fade = fadeOut:CreateAnimation("Alpha")
fade:SetFromAlpha(1)
fade:SetToAlpha(0)
fade:SetDuration(0.6)
fade:SetStartDelay(WARN_DURATION)
fadeOut:SetScript("OnFinished", function()
    ag:Stop()
    warnFrame:Hide()
    warnText:SetAlpha(1)
end)

local function ShowWarning(runeNameWanted)
    local now = GetTime()
    if now - lastWarnTime < WARN_COOLDOWN then return end
    lastWarnTime = now

    local msg = "CHANGE YOUR RUNEFORGE!"
    if runeNameWanted then
        msg = "Equip: " .. runeNameWanted .. "!"
    end
    warnText:SetText(msg)
    warnText:SetAlpha(1)
    warnFrame:Show()
    ag:Play()
    fadeOut:Stop()
    fadeOut:Play()
end

local function HideWarning()
    ag:Stop()
    fadeOut:Stop()
    warnFrame:Hide()
end

-------------------------------------------------------------------------------
-- Enchant ID helper — reads permanent enchant from item link
-------------------------------------------------------------------------------
local function GetPermanentEnchantID(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    return tonumber(link:match("item:%d+:(%d+)"))
end

-------------------------------------------------------------------------------
-- Core check
-------------------------------------------------------------------------------
local function CheckRuneforge()
    local specIndex = GetSpecialization()
    if not specIndex then return end

    local wantedID = db.specs[specIndex]
    if not wantedID or wantedID == 0 then
        HideWarning()
        return
    end

    local mhID = GetPermanentEnchantID(16) -- main hand

    if mhID and mhID == wantedID then
        HideWarning()
        return
    end

    ShowWarning(RUNEFORGES[wantedID])
end

-------------------------------------------------------------------------------
-- LibEditMode integration
-- API: AddFrame(frame, callback, default)
--   callback = function(frame, layoutName, point, x, y)
--   default  = { point = "CENTER", x = 0, y = 200 }
-- RegisterCallback('layout', function(layoutName) ... end)
-- AddFrameSettings(frame, { SettingObject, ... })
-------------------------------------------------------------------------------
local function RegisterEditMode()
    local LEM = LibStub and LibStub("LibEditMode", true)
    if not LEM then return end

    -- Position changed callback (user dragged the frame in edit mode)
    local function OnPositionChanged(frame, layoutName, point, x, y)
        db.layouts[layoutName] = { point = point, x = x, y = y }
    end

    LEM:AddFrame(mover, OnPositionChanged, DEFAULT_POSITION)

    -- Restore position when layout changes (also fires at login)
    LEM:RegisterCallback("layout", function(layoutName)
        local pos = db.layouts[layoutName]
        if not pos then
            pos = CopyTable(DEFAULT_POSITION)
            db.layouts[layoutName] = pos
        end
        mover:ClearAllPoints()
        mover:SetPoint(pos.point, pos.x, pos.y)
    end)

    -- Settings dropdowns — one per spec, shown in the edit mode dialog
    local settings = {}
    for specIdx, specName in ipairs(SPEC_NAMES) do
        settings[#settings + 1] = {
            name   = specName .. " Runeforge",
            kind   = LEM.SettingType.Dropdown,
            default = 0,
            get    = function(layoutName)
                return db.specs[specIdx] or 0
            end,
            set    = function(layoutName, value)
                db.specs[specIdx] = (value ~= 0) and value or nil
                CheckRuneforge()
            end,
            values = DROPDOWN_VALUES,
        }
    end

    LEM:AddFrameSettings(mover, settings)
end

-------------------------------------------------------------------------------
-- Event handling
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        EnsureDB()
        RegisterEditMode()
        events:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2, CheckRuneforge)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        lastWarnTime = 0
        C_Timer.After(0.5, CheckRuneforge)

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if arg1 == 16 or arg1 == 17 then
            C_Timer.After(0.3, CheckRuneforge)
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_RAMMSRUNEFORGE1 = "/rrf"
SlashCmdList["RAMMSRUNEFORGE"] = function(msg)
    msg = strtrim(msg):lower()

    if msg == "debug" then
        local mhEnch = GetPermanentEnchantID(16)
        local ohEnch = GetPermanentEnchantID(17)
        print("|cff66ccffRamm's Runeforge|r — Debug")
        print("  Main-hand enchant:", mhEnch or "none")
        print("  Off-hand enchant:", ohEnch or "none")
        local spec = GetSpecialization()
        local wanted = spec and db.specs[spec]
        print("  Current spec:", spec and SPEC_NAMES[spec] or "unknown")
        print("  Wanted enchant:", wanted and
              (RUNEFORGES[wanted] .. " (" .. wanted .. ")") or "none set")
        return
    end

    if msg == "check" then
        lastWarnTime = 0
        CheckRuneforge()
        return
    end

    if msg == "reset" then
        RammsRuneforgeDB = {}
        EnsureDB()
        print("|cff66ccffRamm's Runeforge|r — Settings reset. Reload UI to reapply defaults.")
        return
    end

    print("|cff66ccffRamm's Runeforge|r — Select the frame in Edit Mode to configure runeforges.")
    print("  /rrf debug — show current enchant IDs")
    print("  /rrf check — force a re-check now")
    print("  /rrf reset — reset all settings")
end

-------------------------------------------------------------------------------
-- Ready message
-------------------------------------------------------------------------------
C_Timer.After(3, function()
    print("|cff66ccffRamm's Runeforge|r loaded — select the frame in Edit Mode to configure, or type |cffffffff/rrf|r for commands.")
end)
