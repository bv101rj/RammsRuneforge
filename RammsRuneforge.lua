-------------------------------------------------------------------------------
-- RammsRuneforge — DK runeforge mismatch + Rogue poison reminder
-- Uses LibEditMode for positioning and settings.
-- API ref: https://github.com/p3lim-wow/LibEditMode/wiki
-------------------------------------------------------------------------------
local addonName, ns = ...

local _, playerClass = UnitClass("player")
local isDK = (playerClass == "DEATHKNIGHT")
local isRogue = (playerClass == "ROGUE")
if not isDK and not isRogue then
	return
end

-------------------------------------------------------------------------------
-- DK: Runeforge data (enchant IDs from SpellItemEnchantment)
-------------------------------------------------------------------------------
local RUNEFORGES, RUNEFORGE_SORTED, DROPDOWN_VALUES
if isDK then
	RUNEFORGES = {
		[3368] = "Rune of the Fallen Crusader",
		[3370] = "Rune of Razorice",
		[3847] = "Rune of the Stoneskin Gargoyle",
		[6241] = "Rune of Sanguination",
		[6242] = "Rune of Spellwarding",
		[6243] = "Rune of Hysteria",
		[6244] = "Rune of Unending Thirst",
		[6245] = "Rune of the Apocalypse",
	}

	RUNEFORGE_SORTED = {}
	for id, name in pairs(RUNEFORGES) do
		RUNEFORGE_SORTED[#RUNEFORGE_SORTED + 1] = { id = id, name = name }
	end
	table.sort(RUNEFORGE_SORTED, function(a, b)
		return a.name < b.name
	end)

	DROPDOWN_VALUES = { { text = "None", value = 0 } }
	for _, rf in ipairs(RUNEFORGE_SORTED) do
		DROPDOWN_VALUES[#DROPDOWN_VALUES + 1] = { text = rf.name, value = rf.id }
	end
end

local SPEC_NAMES_DK = { "Blood", "Frost", "Unholy" }

-------------------------------------------------------------------------------
-- Rogue: Poison buff spell IDs
-- Modern poisons are player buffs, detected via C_UnitAuras.GetPlayerAuraBySpellID()
-------------------------------------------------------------------------------
local LETHAL_POISONS, NONLETHAL_POISONS, DRAGON_TEMPERED_BLADES_ID
if isRogue then
	LETHAL_POISONS = {
		2823, -- Deadly Poison
		315584, -- Instant Poison
		8679, -- Wound Poison
		381664, -- Amplifying Poison
	}
	NONLETHAL_POISONS = {
		3408, -- Crippling Poison
		5761, -- Numbing Poison
		381637, -- Atrophic Poison
	}
	DRAGON_TEMPERED_BLADES_ID = 381801
end

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
	if not db.specs then
		db.specs = {}
	end
	if not db.layouts then
		db.layouts = {}
	end
end

-------------------------------------------------------------------------------
-- Mover frame — LibEditMode owns this for positioning
-------------------------------------------------------------------------------
local mover = CreateFrame("Frame", "RammsRuneforgeMover", UIParent)
mover:SetSize(180, 30)
mover:SetPoint(DEFAULT_POSITION.point, DEFAULT_POSITION.x, DEFAULT_POSITION.y)
mover:SetClampedToScreen(true)

-------------------------------------------------------------------------------
-- Bouncing warning (loops until resolved — no fade-out)
-------------------------------------------------------------------------------
local warnFrame = CreateFrame("Frame", nil, UIParent)
warnFrame:SetAllPoints(UIParent)
warnFrame:SetFrameStrata("HIGH")
warnFrame:Hide()

local warnText = warnFrame:CreateFontString(nil, "OVERLAY")
warnText:SetFont(STANDARD_TEXT_FONT, 30, "OUTLINE")
warnText:SetTextColor(1, 0.2, 0.2)
warnText:SetPoint("CENTER", mover, "CENTER", 0, 0)

-- GPU-side bounce + pulse animation (loops forever)
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

-- Re-check ticker: fires while warning is visible, hides when resolved
local recheckTicker
local backgroundTicker

local function ShowWarning(msg)
	warnText:SetText(msg)
	warnText:SetAlpha(1)
	warnFrame:Show()
	if not ag:IsPlaying() then
		ag:Play()
	end
end

local function HideWarning()
	ag:Stop()
	warnFrame:Hide()
	if recheckTicker then
		recheckTicker:Cancel()
		recheckTicker = nil
	end
end

-------------------------------------------------------------------------------
-- DK: Enchant ID helper — reads permanent enchant from item link
-------------------------------------------------------------------------------
local function GetPermanentEnchantID(slot)
	local link = GetInventoryItemLink("player", slot)
	if not link then
		return nil
	end
	return tonumber(link:match("item:%d+:(%d+)"))
end

-------------------------------------------------------------------------------
-- Rogue: Count active poison buffs by category
-------------------------------------------------------------------------------
local function CountActivePoisons(list)
	local count = 0
	for _, spellID in ipairs(list) do
		if C_UnitAuras.GetPlayerAuraBySpellID(spellID) then
			count = count + 1
		end
	end
	return count
end

-------------------------------------------------------------------------------
-- Core check — branches by class
-------------------------------------------------------------------------------
local function RunCheck()
	if isDK then
		local specIndex = GetSpecialization()
		if not specIndex then
			return
		end

		local wantedID = db.specs[specIndex]
		if not wantedID or wantedID == 0 then
			HideWarning()
			return
		end

		local mhID = GetPermanentEnchantID(16)
		if mhID and mhID == wantedID then
			HideWarning()
			return
		end

		ShowWarning("Equip: " .. (RUNEFORGES[wantedID] or "Unknown") .. "!")
	elseif isRogue then
		local hasDTB = IsPlayerSpell(DRAGON_TEMPERED_BLADES_ID)
		local lethalNeeded = hasDTB and 2 or 1
		local nonlethalNeeded = hasDTB and 2 or 1

		local lethalCount = CountActivePoisons(LETHAL_POISONS)
		local nonlethalCount = CountActivePoisons(NONLETHAL_POISONS)

		if lethalCount >= lethalNeeded and nonlethalCount >= nonlethalNeeded then
			HideWarning()
			return
		end

		ShowWarning("POISONS MISSING!")
	end
end

-- Wrapper that starts the re-check ticker when a problem is found
local function Check()
	RunCheck()
	-- If warning is showing and no ticker yet, start periodic re-checks
	if warnFrame:IsShown() and not recheckTicker then
		recheckTicker = C_Timer.NewTicker(2, RunCheck)
	end
end

-------------------------------------------------------------------------------
-- LibEditMode integration
-- AddFrame(frame, callback, default)
-- RegisterCallback('layout', function(layoutName) ... end)
-- AddFrameSettings(frame, { SettingObject, ... })
-------------------------------------------------------------------------------
local function RegisterEditMode()
	local LEM = LibStub and LibStub("LibEditMode", true)
	if not LEM then
		return
	end

	local function OnPositionChanged(frame, layoutName, point, x, y)
		db.layouts[layoutName] = { point = point, x = x, y = y }
	end

	LEM:AddFrame(mover, OnPositionChanged, DEFAULT_POSITION)

	LEM:RegisterCallback("layout", function(layoutName)
		local pos = db.layouts[layoutName]
		if not pos then
			pos = CopyTable(DEFAULT_POSITION)
			db.layouts[layoutName] = pos
		end
		mover:ClearAllPoints()
		mover:SetPoint(pos.point, pos.x, pos.y)
	end)

	-- DK gets per-spec runeforge dropdowns in the edit mode dialog
	if isDK then
		local settings = {}
		for specIdx, specName in ipairs(SPEC_NAMES_DK) do
			settings[#settings + 1] = {
				name = specName .. " Runeforge",
				kind = LEM.SettingType.Dropdown,
				default = 0,
				get = function(layoutName)
					return db.specs[specIdx] or 0
				end,
				set = function(layoutName, value)
					db.specs[specIdx] = (value ~= 0) and value or nil
					Check()
				end,
				values = DROPDOWN_VALUES,
			}
		end
		LEM:AddFrameSettings(mover, settings)
	end
end

-------------------------------------------------------------------------------
-- Event handling
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

if isDK then
	events:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
end

if isRogue then
	events:RegisterEvent("UNIT_AURA")
end

events:SetScript("OnEvent", function(_, event, arg1, ...)
	if event == "ADDON_LOADED" and arg1 == addonName then
		EnsureDB()
		RegisterEditMode()
		events:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_ENTERING_WORLD" then
		C_Timer.After(2, Check)
		-- Rogue: keep a slow background poll so we catch poisons expiring
		if isRogue and not backgroundTicker then
			backgroundTicker = C_Timer.NewTicker(10, function()
				if not warnFrame:IsShown() then
					RunCheck()
					-- If RunCheck triggered a warning, start the fast ticker
					if warnFrame:IsShown() and not recheckTicker then
						recheckTicker = C_Timer.NewTicker(2, RunCheck)
					end
				end
			end)
		end
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		C_Timer.After(0.5, Check)
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if arg1 == 16 or arg1 == 17 then
			C_Timer.After(0.3, Check)
		end
	elseif event == "UNIT_AURA" and arg1 == "player" then
		RunCheck()
		if warnFrame:IsShown() and not recheckTicker then
			recheckTicker = C.Timer.NewTicker(2, RunCheck)
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
		print("|cff66ccffRamm's Runeforge|r — Debug (" .. playerClass .. ")")
		if isDK then
			local mhEnch = GetPermanentEnchantID(16)
			local ohEnch = GetPermanentEnchantID(17)
			print("  Main-hand enchant:", mhEnch or "none")
			print("  Off-hand enchant:", ohEnch or "none")
			local spec = GetSpecialization()
			local wanted = spec and db.specs[spec]
			print("  Current spec:", spec and SPEC_NAMES_DK[spec] or "unknown")
			print("  Wanted enchant:", wanted and (RUNEFORGES[wanted] .. " (" .. wanted .. ")") or "none set")
		elseif isRogue then
			local hasDTB = IsPlayerSpell(DRAGON_TEMPERED_BLADES_ID)
			print("  Dragon-Tempered Blades:", hasDTB and "YES" or "no")
			print("  Lethal poisons active:", CountActivePoisons(LETHAL_POISONS), "/ needed:", hasDTB and 2 or 1)
			print("  Non-lethal poisons active:", CountActivePoisons(NONLETHAL_POISONS), "/ needed:", hasDTB and 2 or 1)
		end
		return
	end

	if msg == "check" then
		Check()
		return
	end

	if msg == "reset" then
		RammsRuneforgeDB = {}
		EnsureDB()
		print("|cff66ccffRamm's Runeforge|r — Settings reset. Reload UI to reapply defaults.")
		return
	end

	if isDK then
		print("|cff66ccffRamm's Runeforge|r — Select the frame in Edit Mode to configure runeforges.")
	else
		print("|cff66ccffRamm's Runeforge|r — Monitors poison buffs automatically.")
	end
	print("  /rrf debug — show current status")
	print("  /rrf check — force a re-check now")
	print("  /rrf reset — reset all settings")
end

-------------------------------------------------------------------------------
-- Ready message
-------------------------------------------------------------------------------
C_Timer.After(3, function()
	if isDK then
		print(
			"|cff66ccffRamm's Runeforge|r loaded — select the frame in Edit Mode to configure, or type |cffffffff/rrf|r."
		)
	else
		print("|cff66ccffRamm's Runeforge|r loaded — monitoring poisons. Type |cffffffff/rrf|r for commands.")
	end
end)
