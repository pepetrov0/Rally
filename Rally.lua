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
]]

Rally = Rally or {} -- Skin.lua adds Rally.Skin when ElvUI is present
local ME = UnitName("player")
local assigns -- the assignment table in use: real RallyDB.assign, or fake in debug

function Rally.Assigns() return assigns end -- Sync.lua reads and writes the table in use

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
-- spell  = greater/group version (needs reagents)
-- lesser = single-target fallback, used when reagents are missing
-- self   = true: cast on yourself (shouts, horn); others need a target
local BUFFS = {
	KINGS   = { label = "Kings",  spell = "Greater Blessing of Kings",     lesser = "Blessing of Kings",     auras = { "Blessing of Kings", "Greater Blessing of Kings" } },
	MIGHT   = { label = "Might",  spell = "Greater Blessing of Might",     lesser = "Blessing of Might",     auras = { "Blessing of Might", "Greater Blessing of Might" } },
	WISDOM  = { label = "Wisdom", spell = "Greater Blessing of Wisdom",    lesser = "Blessing of Wisdom",    auras = { "Blessing of Wisdom", "Greater Blessing of Wisdom" } },
	SANC    = { label = "Sanct",  spell = "Greater Blessing of Sanctuary", lesser = "Blessing of Sanctuary", auras = { "Blessing of Sanctuary", "Greater Blessing of Sanctuary" } },
	FORT    = { label = "Fort",   spell = "Prayer of Fortitude",           lesser = "Power Word: Fortitude", auras = { "Power Word: Fortitude", "Prayer of Fortitude" } },
	SPIRIT  = { label = "Spirit", spell = "Prayer of Spirit",              lesser = "Divine Spirit",         auras = { "Divine Spirit", "Prayer of Spirit" } },
	SHADOW  = { label = "ShadP",  spell = "Prayer of Shadow Protection",   lesser = "Shadow Protection",     auras = { "Shadow Protection", "Prayer of Shadow Protection" } },
	MARK    = { label = "Wild",   spell = "Gift of the Wild",              lesser = "Mark of the Wild",      auras = { "Mark of the Wild", "Gift of the Wild" } },
	THORNS  = { label = "Thorns", spell = "Thorns",                        auras = { "Thorns" } },
	AI      = { label = "Int",    spell = "Arcane Brilliance",             lesser = "Arcane Intellect",      auras = { "Arcane Intellect", "Arcane Brilliance" } },
	BSHOUT  = { label = "BShout", spell = "Battle Shout",                  auras = { "Battle Shout" }, self = true },
	CSHOUT  = { label = "CShout", spell = "Commanding Shout",              auras = { "Commanding Shout" }, self = true },
	HORN    = { label = "Horn",   spell = "Horn of Winter",                auras = { "Horn of Winter" }, self = true },
}

-- spell ids, only used to look up icons (works even if the spell isn't known)
local SPELL_IDS = {
	KINGS = 25898, MIGHT = 25782, WISDOM = 25894, SANC = 25899,
	FORT = 21562, SPIRIT = 27681, SHADOW = 27683,
	MARK = 21849, THORNS = 467, AI = 23028,
	BSHOUT = 6673, CSHOUT = 469, HORN = 57330,
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

local function HasBuff(unit, buff)
	for i = 1, 40 do
		local name, _, _, _, _, _, expires = UnitBuff(unit, i)
		if not name then return false end
		for _, a in ipairs(buff.auras) do
			if a == name then
				if expires and expires > 0 and expires - GetTime() < REBUFF_BELOW then return false end
				return true
			end
		end
	end
	return false
end

local function Known(spell) return GetSpellInfo(spell) ~= nil end

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
	local _, myClass = UnitClass("player")
	if not CASTERS[myClass] then return nil end
	if myClass == "PALADIN" then return RallyDB.assign[ME] end
	local index = 0
	for _, r in ipairs(Roster()) do
		if r.class == myClass then
			index = index + 1
			if r.name == ME then
				-- only grid classes read saved assignments; everyone else presumes
				local saved = GRID[myClass] and RallyDB.assign[ME]
				if saved and next(saved) then return saved end
				return PresumedRow(myClass, index)
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
local function Scan()
	if debugOn then return FakeScan() end
	local list, cast = {}, nil
	local row = MyRow()
	if not row or UnitIsDeadOrGhost("player") then return list end
	local units, byName = Units(), {}
	for _, class in ipairs(CLASSES) do
		local opt = row[class] and ASSIGN[row[class]]
		if opt then
			for _, bkey in ipairs(opt.buffs) do
				local buff = BUFFS[bkey]
				local spell = PickSpell(buff)
				if spell then
					for _, u in ipairs(units) do
						local _, uclass = UnitClass(u)
						if uclass == class and UnitIsConnected(u) and UnitIsVisible(u) and not UnitIsDeadOrGhost(u)
							and not HasBuff(u, buff)
							and (buff.self or IsSpellInRange(spell, u) ~= 0) then
							local name = UnitName(u)
							local entry = byName[name]
							if not entry then
								entry = { name = name, class = class, buffs = {},
									castIt = { key = bkey, spell = spell, unit = buff.self and "player" or u } }
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
	local now, confirmed = {}, {}
	for _, e in ipairs(list) do now[e.name] = true end
	for name in pairs(seenMissing) do if not now[name] then seenMissing[name] = nil end end
	for _, e in ipairs(list) do
		if seenMissing[e.name] then
			confirmed[#confirmed + 1] = e
			if not cast then cast = e.castIt end
		end
		seenMissing[e.name] = true
	end
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
	line.icons = {}
	for j = 1, 1 do -- one missing buff at a time; the next appears when applied
		local tex = line:CreateTexture(nil, "ARTWORK")
		Size(tex, 16, 16)
		tex:SetPoint("LEFT", (j - 1) * 18, 0)
		tex:SetTexCoord(unpack(ICON_CROP))
		line.icons[j] = tex
	end
	listLines[i] = line
	return line
end

local function UpdateList(list)
	local n = #list
	for i = 1, n do
		local line, entry = GetListLine(i), list[i]
		local color = RAID_CLASS_COLORS[entry.class]
		line.name:SetText(entry.name)
		line.name:SetPoint("LEFT", 21, 0)
		line.name:SetTextColor(color.r, color.g, color.b)
		for j, tex in ipairs(line.icons) do
			local key = entry.buffs[j]
			if key then tex:SetTexture(BuffIcon(key)); tex:Show() else tex:Hide() end
		end
		line:Show()
	end
	for i = n + 1, #listLines do listLines[i]:Hide() end
	listFrame:SetHeight(16 + n * LINE_H)
	SetShown(listFrame, n > 0)
end

local function UpdateButton()
	if not btn then return end
	local list, cast = Scan()
	UpdateList(list)
	local inCombat = InCombatLockdown()

	local _, myClass = UnitClass("player")
	if not debugOn and not CASTERS[myClass] then -- this class casts nothing: no button
		if not inCombat then btn:Hide() end
		return
	end
	-- combat lockdown refuses Show/Hide on a protected button, so only touch
	-- them out of combat; Enable/Disable likewise happen at the combat
	-- transitions (PLAYER_REGEN_DISABLED/ENABLED), not here
	if not inCombat then
		btn:Show() -- visible for caster classes; the text states how much is missing
		btn:Enable()
	end
	if #list == 0 then -- everybody is buffed
		flashStart = nil -- fresh 60s the next time buffs go missing
		if not inCombat then
			btn:SetAttribute("spell", nil)
			btn:SetAttribute("unit", nil)
		end
		btn:SetText("All good.")
		btn.iconFrame:Hide()
		btn.flash:Hide()
		return
	end
	local missing = 0
	for _, e in ipairs(list) do missing = missing + #e.buffs end
	btn:SetText(missing .. " missing!")
	if inCombat then
		btn.flash:Hide()
		flashStart = nil -- combat pauses/resets the 60s
	else
		flashStart = flashStart or GetTime()
		if GetTime() - flashStart < 60 then btn.flash:Show() else btn.flash:Hide() end -- a minute of being ignored: stop
	end
	if cast and not inCombat then
		btn:SetAttribute("spell", cast.spell)
		btn:SetAttribute("unit", cast.unit)
		btn.icon:SetTexture(BuffIcon(cast.key))
		btn.iconFrame:Show()
	else -- people are missing buffs, but none can be cast right now (out of range, or in combat)
		if not inCombat then
			btn:SetAttribute("spell", nil)
			btn:SetAttribute("unit", nil)
		end
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
	fs:SetPoint("RIGHT", -6, 0)
	fs:SetJustifyH("LEFT")

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
	btn:HookScript("OnClick", function(_, button)
		if button == "RightButton" then
			if frame:IsShown() then frame:Hide() else frame:Show() end
		end
	end)
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Rally")
		GameTooltip:AddLine("Left-click: cast next missing buff", 1, 1, 1)
		GameTooltip:AddLine("Right-click: assignments", 1, 1, 1)
		GameTooltip:AddLine("Shift-drag: move", 1, 1, 1)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

driver:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		RallyDB = RallyDB or {}
		RallyDB.assign = RallyDB.assign or {}
		assigns = RallyDB.assign
		BuildWindow()
		BuildButton()
		UpdateButton()
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- entering combat: Enable/Disable and SetAttribute are refused once the
		-- lockdown is up, and this event fires before that, so this is the last
		-- chance to make the button inert until combat ends
		btn:Disable()
		btn:SetAttribute("type", nil) -- a stale pre-combat spell must not go off
		UpdateButton()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if btn then -- re-arm: UpdateButton sets a fresh spell/unit out of combat
			btn:SetAttribute("type", "spell")
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
