--[[ Rally - raid buff assignments for all classes (WotLK 3.3.5)
     Assign each buffer a buff per target class. Assignments sync over addon
     messages. One button casts the next buff that is missing (greater buffs,
     falling back to lesser buffs when out of reagents).
     /rally        toggle the assignment window
     /rally auto   auto-assign everyone
     /rally reset  clear all assignments
]]

Rally = Rally or {} -- Skin.lua adds Rally.Skin when ElvUI is present
local PREFIX = "RALLY"
local ME = UnitName("player")

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
	AI      = { label = "Int",    spell = "Arcane Brilliance",             lesser = "Arcane Intellect",      auras = { "Arcane Intellect", "Arcane Brilliance" } },
	BSHOUT  = { label = "BShout", spell = "Battle Shout",                  auras = { "Battle Shout" }, self = true },
	CSHOUT  = { label = "CShout", spell = "Commanding Shout",              auras = { "Commanding Shout" }, self = true },
	HORN    = { label = "Horn",   spell = "Horn of Winter",                auras = { "Horn of Winter" }, self = true },
}

-- spell ids, only used to look up icons (works even if the spell isn't known)
local SPELL_IDS = {
	KINGS = 25898, MIGHT = 25782, WISDOM = 25894, SANC = 25899,
	FORT = 21562, SPIRIT = 27681, SHADOW = 27683,
	MARK = 21849, AI = 23028,
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
	AI     = { label = "Int",    buffs = { "AI" } },
	BSHOUT = { label = "BShout", buffs = { "BSHOUT" } },
	CSHOUT = { label = "CShout", buffs = { "CSHOUT" } },
	HORN   = { label = "Horn",   buffs = { "HORN" } },
}

-- options each class can cycle through. Paladins are assigned per target
-- class; every other class is assigned for the whole row at once.
local CASTERS = {
	PALADIN     = { "KINGS", "MIGHT", "WISDOM", "SANC" },
	PRIEST      = { "PRIEST" }, -- priests cast all three buffs
	DRUID       = { "MARK" },
	MAGE        = { "AI" },
	WARRIOR     = { "BSHOUT", "CSHOUT" },
	DEATHKNIGHT = { "HORN" },
}

-- target class columns (order matters for the sync message)
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

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

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
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

local function Channel()
	if GetNumRaidMembers() > 0 then return "RAID" end
	if GetNumPartyMembers() > 0 then return "PARTY" end
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

local function CanEdit(caster) return caster == ME or IsOfficer() end

local function Roster() -- list of buffers currently in the group
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

---------------------------------------------------------------------------
-- Sync: one message per buffer, "R|name|k1,k2,...,k10" ("-" = nothing)
---------------------------------------------------------------------------
local queue = {}

local function Send(caster)
	local ch = Channel()
	if not ch then return end
	local row, parts = RallyDB.assign[caster] or {}, {}
	for i, class in ipairs(CLASSES) do parts[i] = row[class] or "-" end
	queue[#queue + 1] = { msg = "R|" .. caster .. "|" .. table.concat(parts, ","), ch = ch }
end

local function SyncAll()
	if not Channel() then return end
	if IsOfficer() then
		for _, r in ipairs(Roster()) do Send(r.name) end
	else
		Send(ME)
	end
end

---------------------------------------------------------------------------
-- Assignment window
---------------------------------------------------------------------------
local NAME_W, CELL, ROW_H = 110, 30, 30 -- square cells
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
	local half = (CELL - 2 - 4) / 2
	for i, tex in ipairs(cell.icons) do
		if i <= n then
			tex:SetTexture(BuffIcon(buffs[i]))
			tex:ClearAllPoints()
			if n == 1 then
				tex:SetPoint("TOPLEFT", 2, -2)
				tex:SetPoint("BOTTOMRIGHT", -2, 2)
			else
				tex:SetSize(half, half)
				tex:SetPoint("TOPLEFT", 2 + ((i - 1) % 2) * half, -2 - math.floor((i - 1) / 2) * half)
			end
			tex:Show()
		else
			tex:Hide()
		end
	end
end

local function ShowCellTooltip(cell, row, class)
	local key = (RallyDB.assign[row.caster] or {})[class]
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

local function Cycle(caster, casterClass, targetClass, dir)
	if not CanEdit(caster) then return end
	local list = CASTERS[casterClass]
	local row = RallyDB.assign[caster]
	if not row then row = {}; RallyDB.assign[caster] = row end
	local idx = 0
	for i, k in ipairs(list) do if row[targetClass] == k then idx = i end end
	idx = idx + dir
	if idx > #list then idx = 0 elseif idx < 0 then idx = #list end
	local value = idx > 0 and list[idx] or nil
	if casterClass == "PALADIN" then
		row[targetClass] = value
	else -- everyone else: the whole row at once
		for _, class in ipairs(CLASSES) do row[class] = value end
	end
	Send(caster)
	Rally_Refresh()
end

local function GetRow(i)
	if rows[i] then return rows[i] end
	local row = CreateFrame("Frame", nil, frame)
	row:SetSize(NAME_W + CELL * #CLASSES, ROW_H)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -62 - (i - 1) * ROW_H)
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 0, 0)
	row.name:SetWidth(NAME_W - 5)
	row.name:SetJustifyH("LEFT")
	row.cells = {}
	for c, class in ipairs(CLASSES) do
		local b = CreateFrame("Button", nil, row)
		b:SetSize(CELL - 2, CELL - 2)
		b:SetPoint("LEFT", NAME_W + (c - 1) * CELL, 0)
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
			Cycle(row.caster, row.casterClass, class, button == "RightButton" and -1 or 1)
		end)
		row.cells[c] = b
	end
	rows[i] = row
	return row
end

function Rally_Refresh()
	if not frame or not frame:IsShown() then return end
	local roster = Roster()
	for i, r in ipairs(roster) do
		local row = GetRow(i)
		row.caster, row.casterClass = r.name, r.class
		local color = RAID_CLASS_COLORS[r.class]
		row.name:SetText(r.name)
		row.name:SetTextColor(color.r, color.g, color.b)
		local assigned, editable = RallyDB.assign[r.name] or {}, CanEdit(r.name)
		for c, class in ipairs(CLASSES) do
			local cell, key = row.cells[c], assigned[class]
			SetCellIcons(cell, key)
			cell:SetAlpha(editable and 1 or 0.5)
		end
		row:Show()
	end
	for i = #roster + 1, #rows do rows[i]:Hide() end
	frame:SetHeight(104 + math.max(#roster, 1) * ROW_H)
	frame.empty:SetShown(#roster == 0)
end

local function AutoAssign()
	if not IsOfficer() then
		print("|cff00ccffRally:|r only the leader or an assistant can auto-assign.")
		return
	end
	local paladins, warriors = 0, 0
	for _, r in ipairs(Roster()) do
		local row = {}
		if r.class == "PALADIN" then
			paladins = paladins + 1
			for _, class in ipairs(CLASSES) do row[class] = PALADIN_PRIORITY[class][paladins] end
		else
			local key = CASTERS[r.class][1]
			if r.class == "WARRIOR" then -- alternate the two shouts
				warriors = warriors + 1
				key = (warriors % 2 == 1) and "BSHOUT" or "CSHOUT"
			end
			for _, class in ipairs(CLASSES) do row[class] = key end
		end
		RallyDB.assign[r.name] = row
		Send(r.name)
	end
	Rally_Refresh()
end

local function BuildWindow()
	frame = CreateFrame("Frame", "RallyFrame", UIParent)
	frame:SetSize(NAME_W + CELL * #CLASSES + 36, 150)
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
	title:SetPoint("TOP", 0, -16)
	title:SetText("Rally")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -5, -5)

	for c, class in ipairs(CLASSES) do
		local h = CreateFrame("Frame", nil, frame)
		h:SetSize(24, 24)
		h:SetPoint("TOPLEFT", 18 + NAME_W + (c - 1) * CELL + 3, -36)
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
	frame.empty:SetPoint("TOP", 0, -70)
	frame.empty:SetText("No buffer classes in your group.")

	local auto = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	auto:SetSize(100, 22)
	auto:SetPoint("BOTTOMLEFT", 20, 16)
	auto:SetText("Auto-assign")
	auto:SetScript("OnClick", AutoAssign)

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMRIGHT", -22, 20)
	hint:SetJustifyH("RIGHT")
	hint:SetText("Click: next   Right-click: previous\n(non-paladins: whole row)")

	Skin("window", frame, close, auto)
end

---------------------------------------------------------------------------
-- Cast button: casts the next missing assigned buff
---------------------------------------------------------------------------
local btn

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

local function FindNeed()
	local row = RallyDB.assign[ME]
	if not row or UnitIsDeadOrGhost("player") then return end
	local units = Units()
	for _, class in ipairs(CLASSES) do
		local opt = row[class] and ASSIGN[row[class]]
		if opt then
			for _, bkey in ipairs(opt.buffs) do
				local buff = BUFFS[bkey]
				local spell, isLesser = PickSpell(buff)
				if spell then
					for _, u in ipairs(units) do
						local _, uclass = UnitClass(u)
						if uclass == class and UnitIsConnected(u) and UnitIsVisible(u) and not UnitIsDeadOrGhost(u)
							and not HasBuff(u, buff)
							and (buff.self or IsSpellInRange(spell, u) ~= 0) then
							return buff, spell, isLesser, buff.self and "player" or u, UnitName(u), bkey
						end
					end
				end
			end
		end
	end
end

local function UpdateButton()
	if InCombatLockdown() then return end
	local buff, spell, isLesser, unit, name, bkey = FindNeed()
	if buff then
		btn:SetAttribute("spell", spell)
		btn:SetAttribute("unit", unit)
		btn:SetText(buff.label .. (isLesser and " (L)" or "") .. " > " .. name)
		btn.icon:SetTexture(BuffIcon(bkey))
		btn.iconFrame:Show()
	else
		btn:SetAttribute("spell", nil)
		btn:SetAttribute("unit", nil)
		btn:SetText("Rally: all buffed")
		btn.iconFrame:Hide()
	end
end

local function BuildButton()
	btn = CreateFrame("Button", "RallyCastButton", UIParent, "SecureActionButtonTemplate, UIPanelButtonTemplate")
	btn:SetSize(200, 30)
	btn:SetPoint("CENTER", 0, -200)
	btn:SetAttribute("type", "spell")
	btn:RegisterForClicks("AnyUp")

	-- icon of the buff that will be cast (own frame so skins can't strip it)
	btn.iconFrame = CreateFrame("Frame", nil, btn)
	btn.iconFrame:SetSize(22, 22)
	btn.iconFrame:SetPoint("LEFT", 6, 0)
	btn.icon = btn.iconFrame:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(unpack(ICON_CROP))
	btn.iconFrame:Hide()
	local fs = btn:GetFontString()
	fs:ClearAllPoints()
	fs:SetPoint("LEFT", 34, 0)
	fs:SetPoint("RIGHT", -6, 0)
	fs:SetJustifyH("LEFT")
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
		GameTooltip:AddLine("Left-click: cast next buff", 1, 1, 1)
		GameTooltip:AddLine("Right-click: assignments", 1, 1, 1)
		GameTooltip:AddLine("Shift-drag: move", 1, 1, 1)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	if RallyDB.pos then
		btn:ClearAllPoints()
		btn:SetPoint(RallyDB.pos[1], UIParent, RallyDB.pos[2], RallyDB.pos[3], RallyDB.pos[4])
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local driver = CreateFrame("Frame")
local tick, qtick, syncAt, lastCount = 0, 0, nil, 0

driver:SetScript("OnUpdate", function(_, elapsed)
	tick, qtick = tick + elapsed, qtick + elapsed
	if qtick > 0.2 and #queue > 0 then
		qtick = 0
		local m = table.remove(queue, 1)
		SendAddonMessage(PREFIX, m.msg, m.ch)
	end
	if syncAt and GetTime() >= syncAt then syncAt = nil; SyncAll() end
	if tick > 1 then tick = 0; if btn then UpdateButton() end end
end)

driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("RAID_ROSTER_UPDATE")
driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
driver:RegisterEvent("CHAT_MSG_ADDON")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")

driver:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
	if event == "PLAYER_LOGIN" then
		RallyDB = RallyDB or {}
		RallyDB.assign = RallyDB.assign or {}
		BuildWindow()
		BuildButton()
		UpdateButton()
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, msg, _, sender = a1, a2, a3, a4
		if prefix ~= PREFIX or sender == ME then return end
		local cmd, caster, data = strsplit("|", msg)
		if cmd ~= "R" or not caster or not data then return end
		if sender ~= caster and not SenderIsOfficer(sender) then return end
		local row, i = {}, 0
		for tok in string.gmatch(data, "[^,]+") do
			i = i + 1
			if CLASSES[i] and ASSIGN[tok] then row[CLASSES[i]] = tok end
		end
		RallyDB.assign[caster] = row
		Rally_Refresh()
	elseif event == "PLAYER_REGEN_ENABLED" then
		UpdateButton()
	else -- roster changed
		local count = GetNumRaidMembers() + GetNumPartyMembers()
		if count > lastCount then syncAt = GetTime() + 3 end
		lastCount = count
		Rally_Refresh()
	end
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
SLASH_RALLY1 = "/rally"
SlashCmdList["RALLY"] = function(msg)
	if msg == "reset" then
		wipe(RallyDB.assign)
		SyncAll()
		Rally_Refresh()
		print("|cff00ccffRally:|r assignments cleared.")
	elseif msg == "auto" then
		AutoAssign()
	elseif frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end
