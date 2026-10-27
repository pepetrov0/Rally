--[[ Rally - raid buff assignments for all classes (WotLK 3.3.5)
     Paladins (blessings) and warriors (shouts) are assigned in the /rally
     window; every other buffer class casts its standard buff by presumption
     (druids add Thorns on top of Gift of the Wild). Assignments sync over
     addon messages (Sync.lua owns all message traffic, incl. PallyPower).
     One button casts the next buff that is missing
     (greater buffs, falling back to lesser buffs when out of reagents).
     /rally        toggle the assignment window
     /rally auto   auto-assign everyone
     /rally reset  clear all assignments
     /rally log    log every sync message (sent and received) to chat
     /rally debug  fake raid of random classes to preview the window

     File layout: Data (buff tables) > Helpers > Debug raid > Assignment
     window > Cast button (scan, arming, list) > Events > Slash.
     A 1 Hz driver refreshes the button; everything else is
     event driven.
]]

Rally = Rally or {} -- Skin.lua adds Rally.Skin when ElvUI is present
local ME = UnitName("player")
local _, MY_CLASS = UnitClass("player") -- never changes, so looked up once
local assigns -- the assignment table in use: real RallyDB.assign, or fake in debug

function Rally.Assigns() return assigns end -- Sync.lua reads and writes the table in use

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
-- spell  = greater/group version (needs reagents)
-- lesser = single-target fallback, used when reagents are missing
-- self   = true: cast on yourself (shouts, horn); others need a target
-- reach  = how far a self buff spreads from you (it hits the group around
--          the caster, so that radius matters, not the cast range)
local BUFFS = {
	KINGS   = { label = "Kings",  spell = "Greater Blessing of Kings",     lesser = "Blessing of Kings",     auras = { "Blessing of Kings", "Greater Blessing of Kings" } },
	MIGHT   = { label = "Might",  spell = "Greater Blessing of Might",     lesser = "Blessing of Might",     auras = { "Blessing of Might", "Greater Blessing of Might" } },
	WISDOM  = { label = "Wisdom", spell = "Greater Blessing of Wisdom",    lesser = "Blessing of Wisdom",    auras = { "Blessing of Wisdom", "Greater Blessing of Wisdom" } },
	SANC    = { label = "Sanct",  spell = "Greater Blessing of Sanctuary", lesser = "Blessing of Sanctuary", auras = { "Blessing of Sanctuary", "Greater Blessing of Sanctuary" } },
	FORT    = { label = "Fort",   spell = "Prayer of Fortitude",           lesser = "Power Word: Fortitude", auras = { "Power Word: Fortitude", "Prayer of Fortitude" }, self = true, reach = 30 },
	SPIRIT  = { label = "Spirit", spell = "Prayer of Spirit",              lesser = "Divine Spirit",         auras = { "Divine Spirit", "Prayer of Spirit" }, self = true, reach = 30 },
	SHADOW  = { label = "ShadP",  spell = "Prayer of Shadow Protection",   lesser = "Shadow Protection",     auras = { "Shadow Protection", "Prayer of Shadow Protection" }, self = true, reach = 30 },
	MARK    = { label = "Wild",   spell = "Gift of the Wild",              lesser = "Mark of the Wild",      auras = { "Mark of the Wild", "Gift of the Wild" }, self = true, reach = 30 },
	THORNS  = { label = "Thorns", spell = "Thorns",                        auras = { "Thorns" } },
	AI      = { label = "Int",    spell = "Arcane Brilliance",             lesser = "Arcane Intellect",      auras = { "Arcane Intellect", "Arcane Brilliance" }, self = true, reach = 30 },
	BSHOUT  = { label = "BShout", spell = "Battle Shout",                  auras = { "Battle Shout" }, self = true, reach = 100 },
	CSHOUT  = { label = "CShout", spell = "Commanding Shout",              auras = { "Commanding Shout" }, self = true, reach = 30 },
	HORN    = { label = "Horn",   spell = "Horn of Winter",                auras = { "Horn of Winter" }, self = true, reach = 30 },
	-- resurrections: not assignable, only used for the dead check
	REZ_PALADIN = { label = "Redemption",     spell = "Redemption",     auras = {} },
	REZ_PRIEST  = { label = "Resurrection",   spell = "Resurrection",   auras = {} },
	REZ_SHAMAN  = { label = "Ancestral Spirit", spell = "Ancestral Spirit", auras = {} },
	REZ_DRUID   = { label = "Revive",         spell = "Revive",         auras = {} },
}

-- spell ids, only used to look up icons (works even if the spell isn't known)
local SPELL_IDS = {
	KINGS = 25898, MIGHT = 25782, WISDOM = 25894, SANC = 25899,
	FORT = 21562, SPIRIT = 27681, SHADOW = 27683,
	MARK = 21849, THORNS = 467, AI = 23028,
	BSHOUT = 6673, CSHOUT = 469, HORN = 57330,
	REZ_PALADIN = 7328, REZ_PRIEST = 2006, REZ_SHAMAN = 2008, REZ_DRUID = 50769,
}

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local ICON_CROP = { 0.07, 0.93, 0.07, 0.93 }

local function BuffIcon(key)
	local buff = BUFFS[key]
	if not buff.icon then
		buff.icon = select(3, GetSpellInfo(buff.spell)) or select(3, GetSpellInfo(SPELL_IDS[key]))
	end
	return buff.icon or FALLBACK_ICON
end

-- what a cell can be set to; each option casts one or more buffs
local ASSIGN = {
	KINGS  = { label = "Kings",  buffs = { "KINGS" } },
	MIGHT  = { label = "Might",  buffs = { "MIGHT" } },
	WISDOM = { label = "Wisdom", buffs = { "WISDOM" } },
	SANC   = { label = "Sanct",  buffs = { "SANC" } },
	PRIEST = { label = "All",    buffs = { "FORT", "SPIRIT", "SHADOW" } },
	MARK   = { label = "Wild",   buffs = { "MARK" } },
	DRUID  = { label = "Wild+",  buffs = { "MARK", "THORNS" } }, -- presumed druid combo
	AI     = { label = "Int",    buffs = { "AI" } },
	BSHOUT = { label = "BShout", buffs = { "BSHOUT" } },
	CSHOUT = { label = "CShout", buffs = { "CSHOUT" } },
	HORN   = { label = "Horn",   buffs = { "HORN" } },
}

-- spell options per buffer class. Paladins and warriors are listed and
-- assigned in the /rally window; for everyone else the standard buffs are
-- presumed.
local CASTERS = {
	PALADIN     = { "KINGS", "MIGHT", "WISDOM", "SANC" },
	PRIEST      = { "PRIEST" }, -- priests cast all three buffs
	DRUID       = { "DRUID" }, -- druids cast Wild and Thorns
	MAGE        = { "AI" },
	WARRIOR     = { "BSHOUT", "CSHOUT" },
	DEATHKNIGHT = { "HORN" },
}

-- classes that can resurrect; dead raiders come before any buff
local REZ = { PALADIN = "REZ_PALADIN", PRIEST = "REZ_PRIEST", SHAMAN = "REZ_SHAMAN", DRUID = "REZ_DRUID" }

-- classes that get a row (and a saved assignment) in the /rally window
local GRID = { PALADIN = true, WARRIOR = true }

-- target class columns (order matters for the sync message)
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

Rally.GRID, Rally.CLASSES, Rally.ASSIGN = GRID, CLASSES, ASSIGN -- Sync.lua wire format

-- auto-assign: blessings per target class in order of priority.
-- Paladin #1 (by name) gets entry 1, paladin #2 gets entry 2, ...
local PALADIN_PRIORITY = {
	WARRIOR     = { "KINGS", "MIGHT", "SANC" },
	DEATHKNIGHT = { "KINGS", "MIGHT", "SANC" },
	ROGUE       = { "KINGS", "MIGHT" },
	HUNTER      = { "KINGS", "MIGHT", "WISDOM" },
	PALADIN     = { "KINGS", "WISDOM", "MIGHT", "SANC" },
	SHAMAN      = { "KINGS", "WISDOM", "MIGHT" },
	DRUID       = { "KINGS", "WISDOM", "MIGHT" },
	PRIEST      = { "KINGS", "WISDOM" },
	MAGE        = { "KINGS", "WISDOM" },
	WARLOCK     = { "KINGS", "WISDOM" },
}

local REBUFF_BELOW = 60 -- seconds left before a buff counts as "missing"

-- presumed standard buffs: priests cast all three prayers, druids cast
-- Wild and Thorns; unassigned warriors alternate the two shouts by position
local function PresumedRow(class, indexInClass)
	local key = CASTERS[class][1]
	if class == "WARRIOR" then key = (indexInClass % 2 == 1) and "BSHOUT" or "CSHOUT" end
	local row = {}
	for _, c in ipairs(CLASSES) do row[c] = key end
	return row
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Size(obj, w, h)
	obj:SetWidth(w)
	obj:SetHeight(h)
end

local function SetShown(obj, shown)
	if shown then obj:Show() else obj:Hide() end
end

local function Units()
	local t, n = {}, GetNumRaidMembers()
	if n > 0 then
		for i = 1, n do t[#t + 1] = "raid" .. i end
	else
		t[1] = "player"
		for i = 1, GetNumPartyMembers() do t[#t + 1] = "party" .. i end
	end
	return t
end

Rally.Units = Units -- Sync.lua shares it

local function IsOfficer()
	if GetNumRaidMembers() > 0 then return IsRaidLeader() or IsRaidOfficer() end
	if GetNumPartyMembers() > 0 then return IsPartyLeader() end
	return true
end

local function SenderIsOfficer(name)
	local n = GetNumRaidMembers()
	if n > 0 then
		for i = 1, n do
			local rname, rank = GetRaidRosterInfo(i)
			if rname == name then return rank and rank > 0 end
		end
	else
		for i = 1, GetNumPartyMembers() do
			if UnitName("party" .. i) == name then return UnitIsPartyLeader("party" .. i) end
		end
	end
	return false
end
Rally.IsOfficer, Rally.SenderIsOfficer = IsOfficer, SenderIsOfficer -- Sync.lua authority checks

---------------------------------------------------------------------------
-- Debug: fake raid of random classes to preview the window (/rally debug)
---------------------------------------------------------------------------
local debugOn, fakeRoster, fakeDB = false
function Rally.DebugOn() return debugOn end -- Sync.lua ignores real traffic in debug
local SYL_A = { "Al", "Bra", "Cyn", "Drak", "Elu", "Fen", "Grim", "Hal", "Kor", "Lyr", "Mor", "Sel", "Thra", "Vor" }
local SYL_B = { "ad", "din", "gar", "ion", "ka", "mon", "rus", "sha", "tha", "var", "wyn", "zil" }

local function CanEdit(caster) return debugOn or caster == ME or IsOfficer() end

local function MakeFakeRoster()
	local list, seen = {}, {}
	for i = 1, 25 do
		local name
		repeat
			name = SYL_A[math.random(#SYL_A)] .. SYL_B[math.random(#SYL_B)]
		until not seen[name]
		seen[name] = true
		-- first three slots are paladins so the window always has rows to show
		list[#list + 1] = { name = name, class = i <= 3 and "PALADIN" or CLASSES[math.random(#CLASSES)] }
	end
	table.sort(list, function(a, b)
		if a.class ~= b.class then return a.class < b.class end
		return a.name < b.name
	end)
	return list
end

local function Roster() -- list of buffers currently in the group
	if debugOn then return fakeRoster end
	local list = {}
	for _, u in ipairs(Units()) do
		local name = UnitName(u)
		local _, class = UnitClass(u)
		if name and CASTERS[class] then list[#list + 1] = { name = name, class = class } end
	end
	table.sort(list, function(a, b)
		if a.class ~= b.class then return a.class < b.class end
		return a.name < b.name
	end)
	return list
end

Rally.Roster = Roster -- Sync.lua enumerates grid casters for SyncAll

---------------------------------------------------------------------------
-- Assignment window
---------------------------------------------------------------------------
-- window layout: square cells with generous spacing
local NAME_W, CELL, GAP, PAD = 130, 40, 6, 26
local PITCH, ROW_H = CELL + GAP, CELL + 6
local ROWS_TOP = 84 -- distance from the window top to the first row
local frame, rows = nil, {}

-- let an optional skin (ElvUI) restyle a widget; never breaks the addon
local skinFailed
local function Skin(kind, ...)
	if not Rally.Skin or skinFailed then return end
	local ok, err = pcall(Rally.Skin, kind, ...)
	if not ok then
		skinFailed = true
		print("|cff00ccffRally:|r skin error: " .. tostring(err))
	end
end

-- show the option's buff icons in a cell: one big icon, or a 2x2 mini grid
local function SetCellIcons(cell, key)
	local buffs = key and ASSIGN[key].buffs
	local n = buffs and #buffs or 0
	local half = (CELL - 4) / 2
	for i, tex in ipairs(cell.icons) do
		if i <= n then
			tex:SetTexture(BuffIcon(buffs[i]))
			tex:ClearAllPoints()
			if n == 1 then
				tex:SetPoint("TOPLEFT", 2, -2)
				tex:SetPoint("BOTTOMRIGHT", -2, 2)
			else
				Size(tex, half, half)
				tex:SetPoint("TOPLEFT", 2 + ((i - 1) % 2) * half, -2 - math.floor((i - 1) / 2) * half)
			end
			tex:Show()
		else
			tex:Hide()
		end
	end
end

local function ShowCellTooltip(cell, row, class)
	local key = (assigns[row.caster] or {})[class]
	GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
	GameTooltip:SetText(row.caster .. " > " .. LOCALIZED_CLASS_NAMES_MALE[class])
	if key then
		for _, bkey in ipairs(ASSIGN[key].buffs) do
			GameTooltip:AddLine(BUFFS[bkey].spell, 1, 1, 1)
		end
	else
		GameTooltip:AddLine("Not assigned", 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function Cycle(caster, targetClass, dir, wholeRow)
	if not CanEdit(caster) then return end
	local cls
	for _, r in ipairs(Roster()) do
		if r.name == caster then cls = r.class end
	end
	local list = CASTERS[cls] or CASTERS.PALADIN -- blessings or shouts
	local row = assigns[caster]
	if not row then row = {}; assigns[caster] = row end
	local idx = 0
	for i, k in ipairs(list) do if row[targetClass] == k then idx = i end end
	idx = idx + dir
	if idx > #list then idx = 0 elseif idx < 0 then idx = #list end
	local value = idx > 0 and list[idx] or nil
	if wholeRow then
		for _, class in ipairs(CLASSES) do row[class] = value end
	else
		row[targetClass] = value
	end
	Rally.SendRow(caster)
	Rally_Refresh()
end

local function GetRow(i)
	if rows[i] then return rows[i] end
	local row = CreateFrame("Frame", nil, frame)
	Size(row, NAME_W + PITCH * #CLASSES, ROW_H)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -ROWS_TOP - (i - 1) * ROW_H)
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", 0, 0)
	row.name:SetWidth(NAME_W - 8)
	row.name:SetJustifyH("LEFT")
	row.cells = {}
	for c, class in ipairs(CLASSES) do
		local b = CreateFrame("Button", nil, row)
		Size(b, CELL, CELL)
		b:SetPoint("LEFT", NAME_W + (c - 1) * PITCH, 0)
		b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		b:SetBackdropColor(0, 0, 0, 0.5)
		b:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
		b.icons = {}
		for i = 1, 4 do
			local tex = b:CreateTexture(nil, "ARTWORK")
			tex:SetTexCoord(unpack(ICON_CROP))
			b.icons[i] = tex
		end
		b:SetScript("OnEnter", function(self) ShowCellTooltip(self, row, class) end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		Skin("cell", b)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(self, button)
			-- warriors: a shout covers the whole raid, so any click fills the row
			Cycle(row.caster, class, button == "RightButton" and -1 or 1, IsShiftKeyDown() or row.class == "WARRIOR")
		end)
		row.cells[c] = b
	end
	rows[i] = row
	return row
end

function Rally_Refresh()
	if not frame or not frame:IsShown() then return end
	-- the window lists paladins and warriors; every other class casts its
	-- standard buffs without needing an assignment
	local roster = {}
	for _, r in ipairs(Roster()) do
		if GRID[r.class] then roster[#roster + 1] = r end
	end
	for i, r in ipairs(roster) do
		local row = GetRow(i)
		row.caster = r.name
		row.class = r.class
		local color = RAID_CLASS_COLORS[r.class]
		row.name:SetText(r.name)
		row.name:SetTextColor(color.r, color.g, color.b)
		local assigned, editable = assigns[r.name] or {}, CanEdit(r.name)
		for c, class in ipairs(CLASSES) do
			local cell, key = row.cells[c], assigned[class]
			SetCellIcons(cell, key)
			cell:SetAlpha(editable and 1 or 0.5)
		end
		row:Show()
	end
	for i = #roster + 1, #rows do rows[i]:Hide() end
	frame:SetHeight(ROWS_TOP + 70 + math.max(#roster, 1) * ROW_H)
	SetShown(frame.empty, #roster == 0)
end

local function AutoAssign()
	if not IsOfficer() and not debugOn then
		print("|cff00ccffRally:|r only the leader or an assistant can auto-assign.")
		return
	end
	local paladins, warriors = 0, 0
	for _, r in ipairs(Roster()) do
		if r.class == "PALADIN" then
			paladins = paladins + 1
			local row = {}
			for _, class in ipairs(CLASSES) do row[class] = PALADIN_PRIORITY[class][paladins] end
			assigns[r.name] = row
			Rally.SendRow(r.name)
		elseif r.class == "WARRIOR" then
			warriors = warriors + 1
			assigns[r.name] = PresumedRow("WARRIOR", warriors)
			Rally.SendRow(r.name)
		end
	end
	Rally_Refresh()
end

local function BuildWindow()
	frame = CreateFrame("Frame", "RallyFrame", UIParent)
	Size(frame, PAD * 2 + NAME_W + PITCH * #CLASSES - GAP, 150)
	frame:SetPoint("CENTER")
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetScript("OnShow", Rally_Refresh)
	frame:Hide()
	tinsert(UISpecialFrames, "RallyFrame")

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -20)
	title:SetText("Rally")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local HEAD = CELL - 6 -- class icon size, a bit smaller than a cell
	for c, class in ipairs(CLASSES) do
		local h = CreateFrame("Frame", nil, frame)
		Size(h, HEAD, HEAD)
		h:SetPoint("TOPLEFT", PAD + NAME_W + (c - 1) * PITCH + (CELL - HEAD) / 2, -ROWS_TOP + 40)
		local t = h:CreateTexture(nil, "ARTWORK")
		t:SetAllPoints()
		t:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
		t:SetTexCoord(unpack(CLASS_ICON_TCOORDS[class]))
		h:EnableMouse(true)
		h:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(LOCALIZED_CLASS_NAMES_MALE[class])
		end)
		h:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.empty:SetPoint("TOP", 0, -ROWS_TOP - 10)
	frame.empty:SetText("No paladins or warriors in your group.")

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOM", 0, 26)
	hint:SetJustifyH("CENTER")
	hint:SetText("Click: next   Shift-click: whole row   Right-click: previous")

	Skin("window", frame, close)
end

---------------------------------------------------------------------------
-- Cast button: casts the next missing assigned buff
---------------------------------------------------------------------------
local btn, flashStart

local function FormatLeft(t)
	if t >= 3600 then return math.floor(t / 3600 + 0.5) .. "h" end
	if t >= 60 then return math.floor(t / 60 + 0.5) .. "m" end
	return math.floor(t) .. "s"
end

-- second and third results: seconds left and total duration (nil when absent or untimed)
local function HasBuff(unit, buff)
	for i = 1, 40 do
		local name, _, _, _, _, duration, expires = UnitBuff(unit, i)
		if not name then return false end
		for _, a in ipairs(buff.auras) do
			if a == name then
				if expires and expires > 0 then
					local left = expires - GetTime()
					return left >= REBUFF_BELOW, left, duration
				end
				return true
			end
		end
	end
	return false
end

local function Known(spell) return GetSpellInfo(spell) ~= nil end

-- How far away a raider may stand and still be listed. 3.3.5 has no
-- yard-exact distance API, so we use the native distance checks:
-- CheckInteractDistance(unit, 1) is 28 yd, UnitInRange(unit) is the 40 yd
-- one. The range we have for the buff picks the bucket, so a 30 yd buff
-- is not offered for someone 35 yd away.
local function InRange(unit, range)
	if range and range < 40 then return CheckInteractDistance(unit, 1) end
	return (UnitInRange and UnitInRange(unit)) or CheckInteractDistance(unit, 1)
end

-- max range of a spell in yards (nil when the spell is unknown)
local function SpellRange(spell)
	local _, _, _, _, _, range = GetSpellInfo(spell)
	return range
end

-- greater version if we know it and have the reagents, else the lesser one
local function PickSpell(buff)
	if not buff.lesser then
		if Known(buff.spell) then return buff.spell end
		return nil
	end
	if Known(buff.spell) then
		local usable, noMana = IsUsableSpell(buff.spell) -- false without reagents
		if usable or noMana then return buff.spell end
	end
	if Known(buff.lesser) then return buff.lesser, true end
end

-- the row I cast from: saved assignment for paladins and warriors,
-- presumed otherwise (an unassigned warrior keeps alternating shouts)
local function MyRow()
	if not CASTERS[MY_CLASS] then return nil end
	if MY_CLASS == "PALADIN" then return RallyDB.assign[ME] end
	local index = 0
	for _, r in ipairs(Roster()) do
		if r.class == MY_CLASS then
			index = index + 1
			if r.name == ME then
				-- only grid classes read saved assignments; everyone else presumes
				local saved = GRID[MY_CLASS] and RallyDB.assign[ME]
				if saved and next(saved) then return saved end
				return PresumedRow(MY_CLASS, index)
			end
		end
	end
end

local function FakeScan() -- fake "missing buffs" list for the debug raid
	local keys = { "KINGS", "MIGHT", "WISDOM", "SANC", "FORT", "SPIRIT", "SHADOW", "MARK", "AI", "BSHOUT", "CSHOUT", "HORN" }
	local list = {}
	for i = 1, #fakeRoster do
		local member, buffs, seen = fakeRoster[i], {}, {}
		for _ = 1, math.random(3) do
			local key = keys[math.random(#keys)]
			if not seen[key] then
				seen[key] = true
				buffs[#buffs + 1] = key
			end
		end
		if #buffs == 0 then buffs[1] = keys[math.random(#keys)] end
		list[#list + 1] = { name = member.name, class = member.class, buffs = buffs }
	end
	return list
end

-- Walks everyone in the group for the buffs assigned to me. Dead, offline
-- and out-of-range raiders are skipped entirely (no list entry, no count).
-- Returns list = players missing something in two consecutive scans (each
-- with the buff keys missing), and cast = the first buff I can actually cast
-- right now (every listed unit is in range already). The two-scan rule is
-- there because a buff being overridden by someone else's cast vanishes
-- from the aura list for a frame or two; a scan landing in that gap must
-- not flash the missing-buff card over a buff the player actually has.
local seenMissing = {}
-- 3.3.5 has no line-of-sight check, so a raider behind a wall passes the
-- distance test and the button keeps aiming at them. When a cast fails for any
-- reason, that raider is passed over for a while so the next one is tried;
-- they stay on the missing list, the button just stops aiming at them.
local SKIP_FOR = 5
local skipUntil, rezSkipUntil, lastTarget, lastRez = {}, {}, nil, false
local rezPick -- name of the dead raider the button is aiming at, kept until it fails

-- Dead raiders in range, when I can resurrect. Returns list, cast like Scan:
-- the pick is random, but sticks until it is resurrected or a cast on it fails,
-- then another random one is tried.
local function ScanDead(units, key)
	local spell = BUFFS[key].spell
	local range, list, open, now = SpellRange(spell), {}, {}, GetTime()
	for _, u in ipairs(units) do
		if UnitIsDead(u) and not UnitIsGhost(u) and UnitIsConnected(u) and UnitIsVisible(u) and InRange(u, range) then
			local name = UnitName(u)
			local _, uclass = UnitClass(u)
			local entry = { name = name, class = uclass, buffs = { key },
				castIt = { key = key, spell = spell, unit = u, target = name, rez = true } }
			list[#list + 1] = entry
			if (rezSkipUntil[name] or 0) < now and (skipUntil[name] or 0) < now then open[#open + 1] = entry end
		end
	end
	local pick
	for _, e in ipairs(open) do if e.name == rezPick then pick = e end end
	if not pick and #open > 0 then pick = open[math.random(#open)] end
	rezPick = pick and pick.name
	return list, pick and pick.castIt
end

local THORNS_MAX = 10 -- Thorns is only worth casting in groups this small
local function SkipBuff(bkey, size) return bkey == "THORNS" and size > THORNS_MAX end

local lowestLeft, lowestDur -- least time left on any of my buffs among the raiders scanned, and that buff's full duration

local people = {} -- scanned raiders for the button tooltip: name, class, least time left on my buffs, missing

local function Scan()
	lowestLeft, lowestDur = nil, nil
	people = {}
	local seenPeople = {}
	if debugOn then return FakeScan() end
	local list, cast = {}, nil
	if UnitIsDeadOrGhost("player") then return list end
	local units, byName = Units(), {}
	local size = #units
	local rezKey = REZ[MY_CLASS]
	if rezKey and not InCombatLockdown() and Known(BUFFS[rezKey].spell) then
		local dead, rez = ScanDead(units, rezKey)
		if #dead > 0 then return dead, rez, true end
	end
	local row = MyRow()
	if not row then return list end
	local refresh -- with nobody missing: the buff with the least time left, to be recast
	local byClass -- units grouped by class, built on first use and shared by all buffs
	for _, class in ipairs(CLASSES) do
		local opt = row[class] and ASSIGN[row[class]]
		if opt then
			if not byClass then
				byClass = {}
				for _, u in ipairs(units) do
					local _, uclass = UnitClass(u)
					if uclass then
						local bucket = byClass[uclass]
						if not bucket then bucket = {}; byClass[uclass] = bucket end
						bucket[#bucket + 1] = u
					end
				end
			end
			local members = byClass[class]
			for _, bkey in ipairs(opt.buffs) do
				local buff = BUFFS[bkey]
				local spell, lesser
				if members and not SkipBuff(bkey, size) then spell, lesser = PickSpell(buff) end
				-- the lesser version of a self buff is single-target
				local onSelf = buff.self and not lesser
				if spell then
					-- a self buff is cast on the player but still lands on
					-- everyone around them, so everyone is checked for it
					local range = onSelf and buff.reach or SpellRange(spell)
					for _, u in ipairs(members) do
						local pname = UnitName(u)
						local p = seenPeople[pname]
						if not p then
							p = { name = pname, class = class }
							seenPeople[pname] = p
							people[#people + 1] = p
						end
						local usable = false
						if not UnitIsConnected(u) then p.off = true
						elseif UnitIsDeadOrGhost(u) then p.dead = true
						elseif UnitIsVisible(u) and InRange(u, range) then usable = true
						else p.oor = true end
						if usable then
							local has, left, dur = HasBuff(u, buff)
							if not has and not p.missing then p.missing, p.key = true, bkey end
							if left and (not p.left or left < p.left) then
								p.left = left
								if not p.missing then p.key = bkey end
							end
							p.key = p.key or bkey
							if left and (not lowestLeft or left < lowestLeft) then lowestLeft, lowestDur = left, dur end
							if has and left and (not refresh or left < refresh.left) then
								local target = not onSelf and UnitName(u) or nil
								if not target or (skipUntil[target] or 0) < GetTime() then
									refresh = { left = left, castIt = { key = bkey, spell = spell,
										unit = onSelf and "player" or u, target = target } }
								end
							end
							if not has then
							local name = UnitName(u)
							local entry = byName[name]
							if not entry then
								entry = { name = name, class = class, buffs = {},
									castIt = { key = bkey, spell = spell, unit = onSelf and "player" or u,
											target = not onSelf and name or nil } }
								byName[name] = entry
								list[#list + 1] = entry
							end
							entry.buffs[#entry.buffs + 1] = bkey
							end
						end
					end
				end
			end
		end
	end
	local now, confirmed, time = {}, {}, GetTime()
	for _, e in ipairs(list) do now[e.name] = true end
	for name in pairs(seenMissing) do if not now[name] then seenMissing[name] = nil end end
	for _, e in ipairs(list) do
		if seenMissing[e.name] then
			confirmed[#confirmed + 1] = e
			if not cast and (not e.castIt.target or (skipUntil[e.castIt.target] or 0) < time) then
				cast = e.castIt
			end
		end
		seenMissing[e.name] = true
	end
	if not cast and #list == 0 and refresh then cast = refresh.castIt end
	return confirmed, cast
end

-- missing-buffs list shown above the cast button
local BTN_W, LINE_H = 200, 17
local listFrame, listLines = nil, {}

local function GetListLine(i)
	if listLines[i] then return listLines[i] end
	local line = CreateFrame("Frame", nil, listFrame)
	Size(line, BTN_W - 16, LINE_H)
	line:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 8, -8 - (i - 1) * LINE_H)
	line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	line.name:SetPoint("LEFT", 21, 0) -- icon comes first, tiny gap
	line.name:SetWidth(BTN_W - 16 - 21)
	line.name:SetJustifyH("LEFT")
	-- one missing buff at a time; the next appears when it is applied
	line.time = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	line.time:SetPoint("RIGHT", 0, 0)
	line.icon = line:CreateTexture(nil, "ARTWORK")
	Size(line.icon, 16, 16)
	line.icon:SetPoint("LEFT", 0, 0)
	line.icon:SetTexCoord(unpack(ICON_CROP))
	listLines[i] = line
	return line
end

local function UpdateList(list)
	local n = #list
	for i = 1, n do
		local line, entry = GetListLine(i), list[i]
		local color = RAID_CLASS_COLORS[entry.class]
		line.name:SetText(entry.name)
		line.name:SetTextColor(color.r, color.g, color.b)
		line.icon:SetTexture(BuffIcon(entry.buffs[1]))
		line.icon:Show()
		line.time:SetText("")
		line:Show()
	end
	for i = n + 1, #listLines do listLines[i]:Hide() end
	listFrame:SetHeight(16 + n * LINE_H)
	SetShown(listFrame, n > 0)
end

-- Secure attributes can't change in combat, so the button is armed with what
-- needs no target choice just before combat starts: shouts and horn (cast on
-- yourself) and the priest prayers, Gift of the Wild and Arcane Brilliance, which hit the group
-- around the caster.
-- Several buffs go in a castsequence that walks through them click by click.
-- Paladins: a greater blessing lands on the whole class, so one representative
-- per assigned class is enough. Going into combat everyone is still buffed, so
-- nothing is filtered on missing: the button refreshes them as they run out. Each click (see the wrapped OnClick in
-- BuildButton) moves on to the next pair, so the blessings go out in order.
-- Reagents must last 5 casts per buff about to be armed (GetSpellCount counts
-- casts left, and the buffs of a class share their reagent).
local REAGENT_CASTS = 5
local function HasReagents(spell, buffs) return (GetSpellCount(spell) or 0) >= REAGENT_CASTS * buffs end

local function ArmPaladin(row)
	local picks, units = {}, Units()
	btn.armedClasses = {}
	for _, class in ipairs(CLASSES) do
		local opt = row[class] and ASSIGN[row[class]]
		local buff = opt and BUFFS[opt.buffs[1]]
		local spell = buff and PickSpell(buff)
		if spell and spell == buff.spell then
			local range = SpellRange(spell)
			for _, u in ipairs(units) do
				local _, uclass = UnitClass(u)
				if uclass == class and UnitIsConnected(u) and UnitIsVisible(u) and not UnitIsDeadOrGhost(u)
					and InRange(u, range) then
					picks[#picks + 1] = { spell = spell, unit = u, class = class }
					break
				end
			end
		end
	end
	local n = 0
	for _, pick in ipairs(picks) do
		if HasReagents(pick.spell, #picks) then
			n = n + 1
			btn:SetAttribute("rally-spell" .. n, pick.spell)
			btn:SetAttribute("rally-unit" .. n, pick.unit)
			btn.armedClasses[pick.class] = true
		end
	end
	if n == 0 then return false end
	btn:SetAttribute("type", "spell")
	btn:SetAttribute("rally-i", 0)
	btn:SetAttribute("rally-n", n)
	btn.armed = true
	return true
end

local function ArmCombat()
	btn.armed, btn.armedKeys, btn.armedClasses = nil, {}, nil
	btn:SetAttribute("rally-n", 0)
	local row = MyRow()
	if not row or UnitIsDeadOrGhost("player") then return false end
	if MY_CLASS == "PALADIN" then return ArmPaladin(row) end
	local spells, seen, reagent, needs, keyOf = {}, {}, 0, {}, {}
	for _, class in ipairs(CLASSES) do
		local opt = row[class] and ASSIGN[row[class]]
		for _, bkey in ipairs(opt and opt.buffs or {}) do
			local buff = BUFFS[bkey]
			if not seen[bkey] and buff.self then
				seen[bkey] = true
				-- a reagent buff needs the group version known; the reagents are
				-- checked below, otherwise it waits for out of combat
				local spell = PickSpell(buff)
				if spell and (not buff.lesser or spell == buff.spell) then
					spells[#spells + 1] = spell
					keyOf[spell] = bkey
					if buff.lesser then reagent = reagent + 1; needs[spell] = true end
				end
			end
		end
	end
	for i = #spells, 1, -1 do
		if needs[spells[i]] and not HasReagents(spells[i], reagent) then table.remove(spells, i) end
	end
	if #spells == 0 then return false end
	for _, spell in ipairs(spells) do btn.armedKeys[keyOf[spell]] = true end
	if #spells == 1 then
		btn:SetAttribute("type", "spell")
		btn:SetAttribute("spell", spells[1])
		btn:SetAttribute("unit", "player")
	else
		btn:SetAttribute("type", "macro")
		btn:SetAttribute("macrotext", "/castsequence [@player] reset=10 " .. table.concat(spells, ", "))
	end
	btn.armed = true
	return true
end

local lastList = {}

-- hovering the button turns the list into everyone scanned, a timer or status on the right:
-- missing first, then the least time left; buffs without a timer, dead, offline and out of range last
local function ShowPeople()
	table.sort(people, function(a, b)
		local function key(x) return x.missing and -1 or x.left or (x.off and 4e12 or x.dead and 3e12 or x.oor and 2e12 or 1e12) end
		local ka, kb = key(a), key(b)
		if ka ~= kb then return ka < kb end
		return a.name < b.name
	end)
	local n = math.min(#people, 25)
	for i = 1, n do
		local line, p = GetListLine(i), people[i]
		local c = RAID_CLASS_COLORS[p.class] or { r = 1, g = 1, b = 1 }
		local text, tr, tg, tb = "", 0.6, 0.6, 0.6
		if p.missing then text, tr, tg, tb = "missing", 1, 0.15, 0.15
		elseif p.left then text, tr, tg, tb = FormatLeft(p.left), 0.1, 1, 0.1
		elseif p.off then text = "OFF"
		elseif p.dead then text = "DEAD"
		elseif p.oor then text = "OOR" end
		line.icon:SetTexture(BuffIcon(p.key or "KINGS"))
		SetShown(line.icon, p.key ~= nil)
		line.name:SetText(p.name)
		line.name:SetTextColor(c.r, c.g, c.b)
		line.time:SetText(text)
		line.time:SetTextColor(tr, tg, tb)
		line:Show()
	end
	for i = n + 1, #listLines do listLines[i]:Hide() end
	listFrame:SetHeight(16 + n * LINE_H)
	SetShown(listFrame, n > 0)
end

local function RenderList()
	if btn.hovered and #people > 0 then ShowPeople() else UpdateList(lastList) end
end

local function ShowButtonTip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Rally")
	GameTooltip:AddLine("Left-click: cast next missing buff", 1, 1, 1)
	GameTooltip:AddLine("Right-click: assignments", 1, 1, 1)
	GameTooltip:AddLine("Shift-drag: move", 1, 1, 1)
	GameTooltip:Show()
end

local function UpdateButton()
	if not btn then return end
	local list, cast, dead = Scan()
	if not lowestLeft then
		btn.left:SetText("")
	else
		btn.left:SetText(FormatLeft(lowestLeft))
		if lowestDur and lowestDur > 0 and lowestLeft < lowestDur * 0.1 then btn.left:SetTextColor(1, 0.15, 0.15)
		else btn.left:SetTextColor(0.1, 1, 0.1) end
	end
	local inCombat = InCombatLockdown()
	if inCombat then -- only what the armed button can cast is listed; the rest is hidden
		local shown = {}
		for _, e in ipairs(list) do
			local buffs = {}
			for _, key in ipairs(e.buffs) do
				if (btn.armedKeys and btn.armedKeys[key]) or (btn.armedClasses and btn.armedClasses[e.class]) then
					buffs[#buffs + 1] = key
				end
			end
			if #buffs > 0 then shown[#shown + 1] = { name = e.name, class = e.class, buffs = buffs } end
		end
		list = shown
	end
	lastList = list
	RenderList()

	if not debugOn and not CASTERS[MY_CLASS] and not REZ[MY_CLASS] then -- this class casts nothing: no button
		if not inCombat then btn:Hide() end
		return
	end
	-- combat lockdown refuses Show/Hide/SetAttribute on a protected button, so
	-- only touch them out of combat; Enable/Disable and arming happen at the
	-- combat transitions (PLAYER_REGEN_DISABLED/ENABLED), not here
	if inCombat then -- the button only casts what ArmCombat armed, so say so
		btn:SetText("In combat!")
		btn.iconFrame:Hide()
		btn.flash:Hide()
		flashStart = nil -- combat pauses/resets the 60s
		return
	end
	btn:Show() -- visible for caster classes; the text states how much is missing
	btn:Enable()
	if #list == 0 then -- everybody is buffed
		flashStart = nil -- fresh 60s the next time buffs go missing
		btn:SetText("All good.")
		btn.flash:Hide()
		if cast then -- nothing missing: a click refreshes the buff that runs out first
			btn:SetAttribute("spell", cast.spell)
			btn:SetAttribute("unit", cast.unit)
			btn.target, btn.rez = cast.target, nil
			btn.icon:SetTexture(BuffIcon(cast.key))
			btn.iconFrame:Show()
		else
			btn:SetAttribute("spell", nil)
			btn:SetAttribute("unit", nil)
			btn.iconFrame:Hide()
		end
		return
	end
	local missing = 0
	for _, e in ipairs(list) do missing = missing + #e.buffs end
	btn:SetText(missing .. (dead and " dead!" or " missing!"))
	flashStart = flashStart or GetTime()
	if GetTime() - flashStart < 60 then btn.flash:Show() else btn.flash:Hide() end -- a minute of being ignored: stop
	if cast then
		btn:SetAttribute("spell", cast.spell)
		btn:SetAttribute("unit", cast.unit)
		btn.target, btn.rez = cast.target, cast.rez
		btn.icon:SetTexture(BuffIcon(cast.key))
		btn.iconFrame:Show()
	else -- people are missing buffs, but none can be cast right now (e.g. out of range)
		btn:SetAttribute("spell", nil)
		btn:SetAttribute("unit", nil)
		btn.iconFrame:Hide()
	end
end

local function BuildList()
	listFrame = CreateFrame("Frame", "RallyList", UIParent)
	Size(listFrame, BTN_W, 40)
	listFrame:SetPoint("BOTTOM", btn, "TOP", 0, 4)
	listFrame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	listFrame:SetBackdropColor(0, 0, 0, 0.8)
	listFrame:Hide()
	Skin("list", listFrame)
end

local function BuildButton()
	btn = CreateFrame("Button", "RallyCastButton", UIParent, "SecureActionButtonTemplate, UIPanelButtonTemplate")
	Size(btn, BTN_W, 36)
	btn:SetPoint("CENTER", 0, -200)
	btn:SetAttribute("type", "spell")
	btn:SetAttribute("type2", "") -- right-click shows the assignments; only left-click may cast
	btn:RegisterForClicks("AnyUp")

	-- icon of the buff that will be cast (own frame so skins can't strip it)
	btn.iconFrame = CreateFrame("Frame", nil, btn)
	Size(btn.iconFrame, 26, 26)
	btn.iconFrame:SetPoint("LEFT", 6, 0)
	btn.icon = btn.iconFrame:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(unpack(ICON_CROP))
	btn.iconFrame:Hide()
	local fs = btn:GetFontString()
	fs:ClearAllPoints()
	fs:SetPoint("LEFT", 44, 0) -- leaves a gap after the 32px-wide icon
	fs:SetPoint("RIGHT", -44, 0)
	fs:SetJustifyH("LEFT")
	-- lowest time left on my buffs, rightmost
	btn.left = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	btn.left:SetPoint("RIGHT", -8, 0)

	-- white flash while buffs are missing (3.3.5 has no animation API)
	btn.flash = CreateFrame("Frame", nil, btn)
	btn.flash:SetAllPoints()
	local ftex = btn.flash:CreateTexture(nil, "OVERLAY")
	ftex:SetAllPoints()
	ftex:SetTexture("Interface\\Buttons\\WHITE8X8")
	ftex:SetBlendMode("ADD")
	btn.flash:SetScript("OnUpdate", function(self)
		self:SetAlpha((0.5 + 0.5 * math.sin(GetTime() * math.pi)) * 0.45)
	end)
	btn.flash:Hide()
	-- in combat an armed paladin button steps through its representatives: this
	-- runs in the secure environment before each click casts
	local header = CreateFrame("Frame", nil, UIParent, "SecureHandlerBaseTemplate")
	SecureHandlerWrapScript(btn, "OnClick", header, [[
		local n = self:GetAttribute("rally-n") or 0
		if n == 0 then return end
		local i = (self:GetAttribute("rally-i") or 0) % n + 1
		self:SetAttribute("rally-i", i)
		self:SetAttribute("spell", self:GetAttribute("rally-spell" .. i))
		self:SetAttribute("unit", self:GetAttribute("rally-unit" .. i))
	]])
	Skin("castbutton", btn)
	btn:SetMovable(true)
	btn:RegisterForDrag("LeftButton")
	btn:SetScript("OnDragStart", function(self)
		if IsShiftKeyDown() and not InCombatLockdown() then self:StartMoving() end
	end)
	btn:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		RallyDB.pos = { p, rp, x, y }
	end)
	btn:HookScript("PreClick", function(self)
		lastTarget = self:GetAttribute("unit") and not InCombatLockdown() and btn.target or nil
		lastRez = btn.rez
	end)
	btn:HookScript("OnClick", function(_, button)
		if button == "RightButton" then
			if frame:IsShown() then frame:Hide() else frame:Show() end
		end
	end)
	btn:SetScript("OnEnter", function(self) self.hovered = true; ShowButtonTip(self); RenderList() end)
	btn:SetScript("OnLeave", function(self) self.hovered = nil; GameTooltip:Hide(); RenderList() end)
	if RallyDB.pos then
		btn:ClearAllPoints()
		btn:SetPoint(RallyDB.pos[1], UIParent, RallyDB.pos[2], RallyDB.pos[3], RallyDB.pos[4])
	end
	BuildList()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local driver = CreateFrame("Frame")
local tick = 0

driver:SetScript("OnUpdate", function(_, elapsed)
	tick = tick + elapsed
	if tick > 1 then tick = 0; if btn then UpdateButton() end end
end)

driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("UNIT_SPELLCAST_FAILED")
driver:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
driver:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

driver:SetScript("OnEvent", function(_, event, unit)
	if event == "PLAYER_LOGIN" then
		RallyDB = RallyDB or {}
		RallyDB.assign = RallyDB.assign or {}
		assigns = RallyDB.assign
		BuildWindow()
		BuildButton()
		UpdateButton()
	elseif event:find("^UNIT_SPELLCAST") then
		if unit == "player" and lastTarget then
			if event ~= "UNIT_SPELLCAST_SUCCEEDED" then
				skipUntil[lastTarget] = GetTime() + SKIP_FOR
			elseif lastRez then -- they stay dead until they accept; don't recast on them meanwhile
				rezSkipUntil[lastTarget] = GetTime() + 60 -- separate, so buffing them isn't blocked
			end
			lastTarget = nil
			if btn then UpdateButton() end
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- entering combat: Enable/Disable and SetAttribute are refused once the
		-- lockdown is up, and this event fires before that, so this is the last
		-- chance to make the button inert until combat ends
		if btn and not ArmCombat() then -- nothing castable without a target choice
			btn:Disable()
			btn:SetAttribute("type", nil) -- a stale pre-combat spell must not go off
		end
		UpdateButton()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if btn then -- re-arm: UpdateButton sets a fresh spell/unit out of combat
			btn.armed = nil
			btn:SetAttribute("rally-n", 0) -- stop the click wrapper rotating targets
			btn:SetAttribute("type", "spell")
			btn:SetAttribute("macrotext", nil)
			btn:Enable()
		end
		UpdateButton()
	end
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
-- debug keeps everything fake in a local table: no syncs, real data
-- (RallyDB / saved variables) is never written to
local function ToggleDebug()
	debugOn = not debugOn
	if debugOn then
		fakeRoster = MakeFakeRoster()
		fakeDB = {}
		print("|cff00ccffRally:|r debug raid active - real assignments are untouched.")
	else
		fakeRoster, fakeDB = nil, nil
		print("|cff00ccffRally:|r debug raid off.")
	end
	assigns = debugOn and fakeDB or RallyDB.assign
	Rally_Refresh()
	if frame then
		frame:Show()
	end
	if debugOn then
		AutoAssign() -- pre-populate the grid so the layout is visible at once
		if btn then UpdateButton() end -- fake missing-buff list above the button
	end
end

SLASH_RALLY1 = "/rally"
SlashCmdList["RALLY"] = function(msg)
	msg = strlower(strtrim(msg or ""))
	if msg == "reset" then
		wipe(assigns)
		-- an empty table is an explicit clear (SyncAll sends it as all "-");
		-- a missing row is not broadcast at all, so mark the roster's rows
		for _, r in ipairs(Roster()) do
			if GRID[r.class] then assigns[r.name] = {} end
		end
		Rally.SyncAll()
		Rally_Refresh()
		print("|cff00ccffRally:|r assignments cleared.")
	elseif msg == "log" then
		RallyDB = RallyDB or {}
		RallyDB.ppDebug = not RallyDB.ppDebug
		print("|cff00ccffRally:|r sync log " .. (RallyDB.ppDebug and "on" or "off"))
	elseif msg == "debug" then
		ToggleDebug()
	elseif msg == "auto" then
		AutoAssign()
	elseif frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end
