--[[ Rally - raid buff assignments for all classes (WotLK 3.3.5)
     Assign each buffer a buff per target class. Assignments sync over addon
     messages. One button casts the next buff that is missing.
     /rally        toggle the assignment window
     /rally reset  clear all assignments
]]

local PREFIX = "RALLY"
local ME = UnitName("player")

BINDING_HEADER_RALLY = "Rally"
_G["BINDING_NAME_CLICK RallyCastButton:LeftButton"] = "Cast next assigned buff"

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
-- self = true: spell is cast on yourself (shouts, horn); others need a target
local BUFFS = {
	KINGS   = { label = "Kings",   spell = "Greater Blessing of Kings",   auras = { "Blessing of Kings", "Greater Blessing of Kings" } },
	MIGHT   = { label = "Might",   spell = "Greater Blessing of Might",   auras = { "Blessing of Might", "Greater Blessing of Might" } },
	WISDOM  = { label = "Wisdom",  spell = "Greater Blessing of Wisdom",  auras = { "Blessing of Wisdom", "Greater Blessing of Wisdom" } },
	SANC    = { label = "Sanct",   spell = "Greater Blessing of Sanctuary", auras = { "Blessing of Sanctuary", "Greater Blessing of Sanctuary" } },
	FORT    = { label = "Fort",    spell = "Prayer of Fortitude",         auras = { "Power Word: Fortitude", "Prayer of Fortitude" } },
	SPIRIT  = { label = "Spirit",  spell = "Prayer of Spirit",            auras = { "Divine Spirit", "Prayer of Spirit" } },
	SHADOW  = { label = "ShadP",   spell = "Prayer of Shadow Protection", auras = { "Shadow Protection", "Prayer of Shadow Protection" } },
	MARK    = { label = "Wild",    spell = "Gift of the Wild",            auras = { "Mark of the Wild", "Gift of the Wild" } },
	AI      = { label = "Int",     spell = "Arcane Brilliance",           auras = { "Arcane Intellect", "Arcane Brilliance" } },
	BSHOUT  = { label = "BShout",  spell = "Battle Shout",                auras = { "Battle Shout" }, self = true },
	CSHOUT  = { label = "CShout",  spell = "Commanding Shout",            auras = { "Commanding Shout" }, self = true },
	HORN    = { label = "Horn",    spell = "Horn of Winter",              auras = { "Horn of Winter" }, self = true },
}

-- which buffs each class can be assigned (add more here to extend)
local CASTERS = {
	PALADIN     = { "KINGS", "MIGHT", "WISDOM", "SANC" },
	PRIEST      = { "FORT", "SPIRIT", "SHADOW" },
	DRUID       = { "MARK" },
	MAGE        = { "AI" },
	WARRIOR     = { "BSHOUT", "CSHOUT" },
	DEATHKNIGHT = { "HORN" },
}

-- target class columns (order matters for the sync message)
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

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
local NAME_W, CELL_W, ROW_H = 110, 34, 22
local frame, rows = nil, {}

local function Cycle(caster, casterClass, targetClass, dir)
	if not CanEdit(caster) then return end
	local list = CASTERS[casterClass]
	local row = RallyDB.assign[caster]
	if not row then row = {}; RallyDB.assign[caster] = row end
	local idx = 0
	for i, k in ipairs(list) do if row[targetClass] == k then idx = i end end
	idx = idx + dir
	if idx > #list then idx = 0 elseif idx < 0 then idx = #list end
	row[targetClass] = idx > 0 and list[idx] or nil
	Send(caster)
	Rally_Refresh()
end

local function GetRow(i)
	if rows[i] then return rows[i] end
	local row = CreateFrame("Frame", nil, frame)
	row:SetSize(NAME_W + CELL_W * #CLASSES, ROW_H)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -62 - (i - 1) * ROW_H)
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 0, 0)
	row.name:SetWidth(NAME_W - 5)
	row.name:SetJustifyH("LEFT")
	row.cells = {}
	for c, class in ipairs(CLASSES) do
		local b = CreateFrame("Button", nil, row)
		b:SetSize(CELL_W - 2, ROW_H - 2)
		b:SetPoint("LEFT", NAME_W + (c - 1) * CELL_W, 0)
		b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		b.text:SetPoint("CENTER")
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
			cell.text:SetText(key and BUFFS[key].label or "")
			if key then cell:SetBackdropColor(0.1, 0.4, 0.1, 0.9) else cell:SetBackdropColor(0, 0, 0, 0.5) end
			cell:SetBackdropBorderColor(0.4, 0.4, 0.4, editable and 1 or 0.3)
		end
		row:Show()
	end
	for i = #roster + 1, #rows do rows[i]:Hide() end
	frame:SetHeight(100 + math.max(#roster, 1) * ROW_H)
	frame.empty:SetShown(#roster == 0)
end

local function BuildWindow()
	frame = CreateFrame("Frame", "RallyFrame", UIParent)
	frame:SetSize(NAME_W + CELL_W * #CLASSES + 36, 150)
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
		h:SetPoint("TOPLEFT", 18 + NAME_W + (c - 1) * CELL_W + 4, -36)
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

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOM", 0, 18)
	hint:SetText("Left-click: next buff   Right-click: previous buff")
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

local function FindNeed()
	local row = RallyDB.assign[ME]
	if not row or UnitIsDeadOrGhost("player") then return end
	local units = Units()
	for _, class in ipairs(CLASSES) do
		local buff = row[class] and BUFFS[row[class]]
		if buff and GetSpellInfo(buff.spell) then
			for _, u in ipairs(units) do
				local _, uclass = UnitClass(u)
				if uclass == class and UnitIsConnected(u) and UnitIsVisible(u) and not UnitIsDeadOrGhost(u)
					and not HasBuff(u, buff)
					and (buff.self or IsSpellInRange(buff.spell, u) ~= 0) then
					return buff, buff.self and "player" or u, UnitName(u)
				end
			end
		end
	end
end

local function UpdateButton()
	if InCombatLockdown() then return end
	local buff, unit, name = FindNeed()
	if buff then
		btn:SetAttribute("spell", buff.spell)
		btn:SetAttribute("unit", unit)
		btn:SetText(buff.label .. " > " .. name)
	else
		btn:SetAttribute("spell", nil)
		btn:SetAttribute("unit", nil)
		btn:SetText("Rally: all buffed")
	end
end

local function BuildButton()
	btn = CreateFrame("Button", "RallyCastButton", UIParent, "SecureActionButtonTemplate, UIPanelButtonTemplate")
	btn:SetSize(160, 28)
	btn:SetPoint("CENTER", 0, -200)
	btn:SetAttribute("type", "spell")
	btn:RegisterForClicks("AnyUp")
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
			if CLASSES[i] and BUFFS[tok] then row[CLASSES[i]] = tok end
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
	elseif frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end
