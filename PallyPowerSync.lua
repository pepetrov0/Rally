--[[ Rally <-> PallyPower sync (3.3.5a)

Standalone add-on file: it does not touch Rally.lua. It works by

  * listening on PallyPower's addon-message prefix (PLPWR) and copying
    paladin blessing assignments into RallyDB.assign, and
  * hooking SendAddonMessage: whenever Rally broadcasts a paladin row on
    its own RALLY prefix, the same change is sent to PallyPower users as
    PLPWR ASSIGN / MASSIGN messages.

PallyPower wire format used (from PallyPower.lua):
  ASSIGN <paladin> <classId> <blessingId>     one cell (0 = none)
  MASSIGN <paladin> <blessingId>              whole row
  SELF <skills>@<assignments>@...             a paladin announcing himself
  REQ                                         "everyone send me SELF"
  CLEAR                                       clear assignments

Class ids: 1 Warrior, 2 Rogue, 3 Priest, 4 Druid, 5 Paladin, 6 Hunter,
           7 Mage, 8 Warlock, 9 Shaman, 10 Death Knight
Blessing ids (wotlk): 1 Wisdom, 2 Might, 3 Kings, 4 Sanctuary
Blessing ids (classic): 1 Wisdom, 2 Might, 3 Kings, 6 Sanctuary

Announcing yourself: if you are a paladin, Rally also sends the SELF and
SYMCOUNT messages a real PallyPower sends, so PallyPower users see you in
their paladin list (with your known blessings and Rally assignments) and
you answer their REQ. Spell ranks are sent with talent points = 0.

Commands:  /rallypp debug        print every PLPWR message received
           /rallypp mode wotlk|classic   blessing id table (default wotlk)
           /rallypp req          ask PallyPower users to announce themselves
           /rallypp self         print and send the SELF message we announce
]]

local PP_PREFIX = "PLPWR"
local ME = UnitName("player")

local MODES = {
  wotlk   = { WISDOM = 1, MIGHT = 2, KINGS = 3, SANC = 4 },
  classic = { WISDOM = 1, MIGHT = 2, KINGS = 3, SANC = 6 },
}

-- PallyPower class id -> class token
local PP_CLASS = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN", "DEATHKNIGHT" }
local TOKEN_TO_PP = {}
for id, token in ipairs(PP_CLASS) do TOKEN_TO_PP[token] = id end

-- Rally's column order (must match CLASSES in Rally.lua)
local RALLY_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local known = {} -- known[paladin][ppClassId] = blessingId as last seen/sent on PLPWR

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Dbg(...)
  if RallyDB and RallyDB.ppDebug then print("|cff00ccffRallyPP:|r", ...) end
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

local function ClassOf(name)
  if name == ME then return (select(2, UnitClass("player"))) end
  for _, u in ipairs(Units()) do
    if UnitName(u) == name then return (select(2, UnitClass(u))) end
  end
end

local function IsOfficer(name)
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

---------------------------------------------------------------------------
-- Outgoing queue (paced so we never trip the addon-message throttle)
---------------------------------------------------------------------------

local out, acc = {}, 0
local SendSelf, selfAt -- defined further down

local function PPSend(msg, ch)
  if not ch then return end
  out[#out + 1] = { msg = msg, ch = ch }
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, elapsed)
  acc = acc + elapsed
  if acc > 0.15 and #out > 0 then
    acc = 0
    local m = table.remove(out, 1)
    SendAddonMessage(PP_PREFIX, m.msg, m.ch)
  end
  if selfAt and GetTime() >= selfAt then
    selfAt = nil
    SendSelf()
  end
end)

local lastReq = 0
local function RequestPP(force)
  local ch = Channel()
  if not ch then return end
  if not force and GetTime() - lastReq < 5 then return end
  lastReq = GetTime()
  PPSend("REQ", ch)
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
  local known, rank = GetSpellInfo(name)
  if not known then return nil end
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
function SendSelf(force)
  if select(2, UnitClass("player")) ~= "PALADIN" then return end
  local ch = Channel()
  if not ch then return end
  if not force and GetTime() - lastSelf < 3 then return end
  lastSelf = GetTime()
  PPSend(BuildSelf(), ch)
  PPSend("SYMCOUNT " .. GetItemCount(SYMBOL_OF_KINGS), ch)
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
    PPSend("MASSIGN " .. name .. " " .. first, ch)
  else
    for c = 1, #PP_CLASS do
      if changed[c] then PPSend("ASSIGN " .. name .. " " .. c .. " " .. changed[c], ch) end
    end
  end
  for c = 1, #PP_CLASS do k[c] = row[c] or 0 end
end

hooksecurefunc("SendAddonMessage", function(prefix, msg, ch)
  if prefix ~= "RALLY" or type(msg) ~= "string" then return end
  local cmd, caster, data = strsplit("|", msg)
  if cmd ~= "R" or not caster or not data then return end
  if ClassOf(caster) ~= "PALADIN" then return end -- PallyPower only knows paladins
  local map, row, i = MODES[CurMode()], {}, 0
  for tok in string.gmatch(data, "[^,]+") do
    i = i + 1
    local ppId = RALLY_CLASSES[i] and TOKEN_TO_PP[RALLY_CLASSES[i]]
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
  if not row then row = {}; RallyDB.assign[name] = row end
  row[PP_CLASS[ppClass]] = (blessing > 0) and IdToKey(blessing) or nil
end

local function ClearPaladin(name)
  known[name] = {}
  if RallyDB and RallyDB.assign then RallyDB.assign[name] = nil end
end

local function OnPP(sender, msg)
  if sender == ME or type(msg) ~= "string" then return end
  Dbg(sender, msg)
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
    if name and (name == sender or IsOfficer(sender)) then
      SetCell(name, tonumber(c), tonumber(v))
      touched = true
    end
  elseif cmd == "MASSIGN" then
    local name, v = msg:match("^MASSIGN (%S+) (%d+)")
    if name and (name == sender or IsOfficer(sender)) then
      for c = 1, #PP_CLASS do SetCell(name, c, tonumber(v)) end
      touched = true
    end
  elseif cmd == "CLEAR" then
    if IsOfficer(sender) then
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

  if touched and Rally_Refresh then Rally_Refresh() end
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
    if a1 == PP_PREFIX then OnPP(a4, a2) end
  elseif event == "PLAYER_ENTERING_WORLD" then
    selfAt = GetTime() + 4
  else
    local count = GetNumRaidMembers() + GetNumPartyMembers()
    if count > lastCount then
      RequestPP() -- PallyPower users answer with SELF
      selfAt = GetTime() + 2 -- and we introduce ourselves to the newcomer
    end
    lastCount = count
  end
end)

SLASH_RALLYPP1 = "/rallypp"
SlashCmdList["RALLYPP"] = function(msg)
  local a, b = (msg or ""):match("^(%S*)%s*(%S*)")
  RallyDB = RallyDB or {}
  if a == "debug" then
    RallyDB.ppDebug = not RallyDB.ppDebug
    print("|cff00ccffRallyPP:|r debug " .. (RallyDB.ppDebug and "on" or "off"))
  elseif a == "mode" and MODES[b] then
    RallyDB.ppMode = b
    print("|cff00ccffRallyPP:|r blessing ids set to " .. b)
  elseif a == "req" then
    RequestPP(true)
  elseif a == "self" then
    print("|cff00ccffRallyPP:|r " .. BuildSelf())
    SendSelf(true)
  else
    print("|cff00ccffRallyPP:|r /rallypp debug | mode wotlk|classic | req | self   (mode: " .. CurMode() .. ")")
  end
end
