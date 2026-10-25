--[[ Rally sync (3.3.5a) - all of Rally's addon-message traffic in one file.

Rally's own language (paladin AND warrior rows):
  R;<caster>;<k1,...,k10>   one caster's assignment row; tokens are Rally's
                            assign keys (KINGS, BSHOUT, ...), "-" = none;
                            columns follow Rally.CLASSES. ";" is the delimiter
                            because some 3.3.5 servers strip "|" from addon
                            messages as a malformed chat-link escape (old
                            senders using "|" are still accepted).
  Row edits are broadcast via Rally.SendRow, or all at once via
  Rally.SyncAll, through one paced outgoing queue. Incoming rows are
  accepted from the caster himself or an officer, and validated against
  Rally.ASSIGN. Sync.lua reads the small interface Rally.lua exposes on
  the Rally table: Assigns, CLASSES, ASSIGN, GRID, Roster, Units,
  IsOfficer, SenderIsOfficer, DebugOn.

PallyPower's language (prefix PLPWR), bridged to Rally's paladin rows:
  ASSIGN <paladin> <classId> <blessingId>     one cell (0 = none)
  MASSIGN <paladin> <blessingId>              whole row
  SELF <skills>@<assignments>@...             a paladin announcing himself
  REQ                                         "everyone send me SELF"
  CLEAR                                       clear assignments

  * Listening on PLPWR copies incoming paladin blessing assignments into
    Rally's assign table (warriors have no PallyPower counterpart).
  * Hooking SendAddonMessage: whenever Rally broadcasts a paladin row on
    the RALLY prefix, the same change goes to PallyPower users as ASSIGN
    or MASSIGN.
  * A paladin running Rally announces himself with SELF and SYMCOUNT like
    a real PallyPower, and answers REQ. Spell ranks are sent with talent
    points = 0.

Class ids: 1 Warrior, 2 Rogue, 3 Priest, 4 Druid, 5 Paladin, 6 Hunter,
           7 Mage, 8 Warlock, 9 Shaman, 10 Death Knight
Blessing ids (wotlk): 1 Wisdom, 2 Might, 3 Kings, 4 Sanctuary
Blessing ids (classic): 1 Wisdom, 2 Might, 3 Kings, 6 Sanctuary
Nothing is sent or ingested while /rally debug is active (fake raid only).

Traffic logging: /rally log prints every RALLY/PLPWR message (sent and
received) to the chat window.
]]

local ME = UnitName("player")
local _, MY_CLASS = UnitClass("player")
local RALLY_PREFIX = "RALLY"
local PP_PREFIX = "PLPWR"

---------------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------------

local function Channel()
	if GetNumRaidMembers() > 0 then return "RAID" end
	if GetNumPartyMembers() > 0 then return "PARTY" end
end

local function ClassOf(name)
	if name == ME then return MY_CLASS end
	for _, u in ipairs(Rally.Units()) do
		if UnitName(u) == name then return (select(2, UnitClass(u))) end
	end
end

---------------------------------------------------------------------------
-- One paced outgoing queue for both protocols (never trips the throttle)
---------------------------------------------------------------------------

local out, acc = {}, 0
local SendSelf, selfAt, syncAt, OnPP -- forward: PP announce / delayed Rally.SyncAll / PP message parser

-- The driver's OnUpdate only runs while it is shown, i.e. while something is
-- queued or scheduled; it hides itself once idle so it costs nothing per frame.
local driver = CreateFrame("Frame")

local function Send(prefix, msg, ch)
	if ch then
		out[#out + 1] = { prefix = prefix, msg = msg, ch = ch }
		driver:Show()
	end
end

local function Schedule(delay) -- returns the time to run at, and wakes the driver
	driver:Show()
	return GetTime() + delay
end

driver:SetScript("OnUpdate", function(self, elapsed)
	acc = acc + elapsed
	if acc > 0.15 and #out > 0 then
		acc = 0
		local m = table.remove(out, 1)
		SendAddonMessage(m.prefix, m.msg, m.ch)
	end
	local now = GetTime()
	if selfAt and now >= selfAt then selfAt = nil; SendSelf() end
	if syncAt and now >= syncAt then syncAt = nil; Rally.SyncAll() end
	if #out == 0 and not selfAt and not syncAt then self:Hide() end
end)
driver:Hide()

---------------------------------------------------------------------------
-- Rally's own protocol (paladins and warriors)
---------------------------------------------------------------------------

-- "|" is stripped by some 3.3.5 servers, so new rows use ";"; both parse
local function SplitRow(msg)
	return strsplit(msg:find("|", 1, true) and "|" or ";", msg)
end

-- broadcast one caster's row; Rally.lua calls this after every edit
function Rally.SendRow(caster)
	if Rally.DebugOn() then return end -- never broadcast the fake raid
	local t, ch = Rally.Assigns(), Channel()
	if not t or not ch then return end
	-- no row means "I have no information", not "clear it": broadcasting it as
	-- all "-" would wipe the assignment from every client that does know it
	local row = t[caster]
	if not row then return end
	local parts = {}
	for i, class in ipairs(Rally.CLASSES) do parts[i] = row[class] or "-" end
	Send(RALLY_PREFIX, "R;" .. caster .. ";" .. table.concat(parts, ","), ch)
end

-- broadcast every grid caster's row (officer) or just ours (everyone else)
function Rally.SyncAll()
	if Rally.DebugOn() then return end
	if not Channel() then return end
	if Rally.IsOfficer() then
		for _, r in ipairs(Rally.Roster()) do
			if Rally.GRID[r.class] then Rally.SendRow(r.name) end
		end
	else
		if Rally.GRID[MY_CLASS] then Rally.SendRow(ME) end
	end
end

local function OnRally(sender, msg)
	if sender == ME then return end
	local cmd, caster, data = SplitRow(msg)
	if cmd ~= "R" or not caster or not data then return end
	if sender ~= caster and not Rally.SenderIsOfficer(sender) then return end
	local row, i = {}, 0
	for tok in string.gmatch(data, "[^,]+") do
		i = i + 1
		if Rally.CLASSES[i] and Rally.ASSIGN[tok] then row[Rally.CLASSES[i]] = tok end
	end
	local t = Rally.Assigns()
	if not t then return end
	-- an all-"-" row means "no assignment": storing an empty table would make
	-- a warrior's row truthy (no presumed shout) and echo back on every sync
	t[caster] = next(row) and row or nil
	Rally_Refresh()
end

---------------------------------------------------------------------------
-- PallyPower bridge (prefix PLPWR)
---------------------------------------------------------------------------

local MODES = {
	wotlk   = { WISDOM = 1, MIGHT = 2, KINGS = 3, SANC = 4 },
	classic = { WISDOM = 1, MIGHT = 2, KINGS = 3, SANC = 6 },
}

-- PallyPower class id -> class token
local PP_CLASS = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN", "DEATHKNIGHT" }
local TOKEN_TO_PP = {}
for id, token in ipairs(PP_CLASS) do TOKEN_TO_PP[token] = id end

local known = {} -- known[paladin][ppClassId] = blessingId as last seen/sent on PLPWR

local function Dbg(...)
	if RallyDB and RallyDB.ppDebug then print("|cff00ccffRally sync:|r", ...) end
end

local function CurMode()
	local m = RallyDB and RallyDB.ppMode
	return MODES[m] and m or "wotlk"
end

local function IdToKey(id)
	for key, v in pairs(MODES[CurMode()]) do
		if v == id then return key end
	end
end

local lastReq = 0
local function RequestPP()
	local ch = Channel()
	if not ch then return end
	if GetTime() - lastReq < 5 then return end
	lastReq = GetTime()
	Send(PP_PREFIX, "REQ", ch)
end

---------------------------------------------------------------------------
-- Announce ourselves like PallyPower does (paladins only)
---------------------------------------------------------------------------

-- spells in blessing-id order; a nil slot is sent as "nn" (can't cast it)
local SKILL_SPELLS = {
	wotlk   = { "Blessing of Wisdom", "Blessing of Might", "Blessing of Kings", "Blessing of Sanctuary" },
	classic = { "Blessing of Wisdom", "Blessing of Might", "Blessing of Kings", "Blessing of Salvation", "Blessing of Light", "Blessing of Sanctuary" },
}
local SYMBOL_OF_KINGS = 21177

local function SpellRank(name)
	local ok, rank = GetSpellInfo(name)
	if not ok then return nil end
	return math.min(tonumber((rank or ""):match("(%d+)")) or 1, 9) -- one digit on the wire
end

local function BuildSelf()
	local spells, s = SKILL_SPELLS[CurMode()], ""
	for i = 1, #spells do
		local r = SpellRank(spells[i])
		s = s .. (r and (r .. "0") or "nn") -- rank, talent points
	end
	s = s .. "@"
	local row = (RallyDB and RallyDB.assign and RallyDB.assign[ME]) or {}
	local map = MODES[CurMode()]
	for id = 1, #PP_CLASS do
		local key = row[PP_CLASS[id]]
		local v = key and map[key]
		s = s .. ((v and v > 0) and tostring(v) or "n")
	end
	return "SELF " .. s
end

local lastSelf = 0
function SendSelf()
	if Rally.DebugOn() then return end -- the fake raid announces nothing
	if MY_CLASS ~= "PALADIN" then return end
	local ch = Channel()
	if not ch then return end
	if GetTime() - lastSelf < 3 then return end
	lastSelf = GetTime()
	Send(PP_PREFIX, BuildSelf(), ch)
	Send(PP_PREFIX, "SYMCOUNT " .. GetItemCount(SYMBOL_OF_KINGS), ch)
end

---------------------------------------------------------------------------
-- Rally -> PallyPower
---------------------------------------------------------------------------

-- row: ppClassId -> blessingId (0 = none) for one paladin
local function Push(name, row, ch)
	local k = known[name]
	if not k then k = {}; known[name] = k end
	local changed, nChanged, allSame, first = {}, 0, true, nil
	for c = 1, #PP_CLASS do
		local v = row[c] or 0
		if v ~= (k[c] or 0) then
			changed[c] = v
			nChanged = nChanged + 1
		end
		if c == 1 then first = v elseif v ~= first then allSame = false end
	end
	if nChanged == 0 then return end
	if allSame and nChanged > 1 then
		Send(PP_PREFIX, "MASSIGN " .. name .. " " .. first, ch)
	else
		for c = 1, #PP_CLASS do
			if changed[c] then Send(PP_PREFIX, "ASSIGN " .. name .. " " .. c .. " " .. changed[c], ch) end
		end
	end
	for c = 1, #PP_CLASS do k[c] = row[c] or 0 end
end

hooksecurefunc("SendAddonMessage", function(prefix, msg, ch)
	if Rally.DebugOn() or type(msg) ~= "string" then return end
	if prefix ~= RALLY_PREFIX and prefix ~= PP_PREFIX then return end
	Dbg(">", prefix, ch, msg)
	if prefix == PP_PREFIX then
		-- PallyPower changes its own assignments without hearing its own
		-- message: mirror that edit into Rally (SELF can be stale, skip it)
		if msg:match("^ASSIGN ") or msg:match("^MASSIGN ") or msg == "CLEAR" then
			OnPP(ME, msg, true)
		end
		return
	end
	local cmd, caster, data = SplitRow(msg)
	if cmd ~= "R" or not caster or not data then return end
	if ClassOf(caster) ~= "PALADIN" then return end -- PallyPower only knows paladins
	local map, row, i = MODES[CurMode()], {}, 0
	for tok in string.gmatch(data, "[^,]+") do
		i = i + 1
		local ppId = TOKEN_TO_PP[Rally.CLASSES[i]]
		if ppId then row[ppId] = map[tok] or 0 end
	end
	Push(caster, row, ch)
end)

---------------------------------------------------------------------------
-- PallyPower -> Rally
---------------------------------------------------------------------------

local function SetCell(name, ppClass, blessing)
	if not PP_CLASS[ppClass] then return end
	known[name] = known[name] or {}
	known[name][ppClass] = blessing
	if not (RallyDB and RallyDB.assign) then return end
	local row = RallyDB.assign[name]
	if not row then
		if blessing <= 0 then return end -- nothing to clear
		row = {}; RallyDB.assign[name] = row
	end
	row[PP_CLASS[ppClass]] = (blessing > 0) and IdToKey(blessing) or nil
	if not next(row) then RallyDB.assign[name] = nil end -- an empty row is "no assignment"
end

local function ClearPaladin(name)
	known[name] = {}
	if RallyDB and RallyDB.assign then RallyDB.assign[name] = nil end
end

function OnPP(sender, msg, local_)
	if (sender == ME and not local_) or type(msg) ~= "string" then return end
	local cmd = msg:match("^(%a+)")
	local touched = false

	if cmd == "REQ" then
		SendSelf()
	elseif cmd == "SELF" then
		-- "SELF <skills>@<10 assignment digits, n = none>@..."
		local _, assign = msg:match("^SELF ([^@]*)@([^@]*)")
		if assign and #assign >= #PP_CLASS then
			for c = 1, #PP_CLASS do
				SetCell(sender, c, tonumber(assign:sub(c, c)) or 0)
			end
			touched = true
		end
	elseif cmd == "ASSIGN" then
		local name, c, v = msg:match("^ASSIGN (%S+) (%d+) (%d+)")
		if name and (local_ or name == sender or Rally.SenderIsOfficer(sender)) then
			SetCell(name, tonumber(c), tonumber(v))
			touched = true
		end
	elseif cmd == "MASSIGN" then
		local name, v = msg:match("^MASSIGN (%S+) (%d+)")
		if name and (local_ or name == sender or Rally.SenderIsOfficer(sender)) then
			for c = 1, #PP_CLASS do SetCell(name, c, tonumber(v)) end
			touched = true
		end
	elseif cmd == "CLEAR" then
		if local_ or Rally.SenderIsOfficer(sender) then
			if RallyDB and RallyDB.assign then
				for name in pairs(RallyDB.assign) do
					if ClassOf(name) == "PALADIN" then ClearPaladin(name) end
				end
			end
		else
			ClearPaladin(sender)
		end
		touched = true
	end

	if touched then Rally_Refresh() end
end

---------------------------------------------------------------------------
-- Events and commands
---------------------------------------------------------------------------

local lastCount = 0
local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("RAID_ROSTER_UPDATE")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
	if event == "CHAT_MSG_ADDON" then
		if Rally.DebugOn() or (a1 ~= RALLY_PREFIX and a1 ~= PP_PREFIX) then return end
		Dbg("<", a1, a4, a2) -- prefix, sender, message
		if a1 == RALLY_PREFIX then OnRally(a4, a2) else OnPP(a4, a2) end
	elseif event == "PLAYER_ENTERING_WORLD" then
		selfAt = Schedule(4) -- introduce ourselves (paladins) after login
	else -- roster changed
		local count = GetNumRaidMembers() + GetNumPartyMembers()
		if count > lastCount then
			if not Rally.DebugOn() then -- the fake raid talks to nobody
				syncAt = Schedule(3) -- let the roster settle, then Rally.SyncAll
				selfAt = Schedule(2) -- and introduce ourselves (paladins)
				RequestPP() -- PallyPower users answer with SELF
			end
		end
		lastCount = count
		Rally_Refresh()
	end
end)
