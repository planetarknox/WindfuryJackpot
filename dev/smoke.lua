-- Fake just enough of the WoW client to run the sniffer without the game.
-- Not part of the addon. From the repo root:
--   lua dev/smoke.lua

local failures = 0

local function check(cond, message)
  if cond then
    print("ok   " .. message)
  else
    failures = failures + 1
    print("FAIL " .. message)
  end
end

local frames = {}

local function installStubs()
  frames = {}

  function CreateFrame(kind)
    local frame = { kind = kind or "Frame", events = {}, scripts = {} }
    function frame:RegisterEvent(name)
      self.events[name] = true
    end
    function frame:SetScript(name, fn)
      self.scripts[name] = fn
    end
    frames[#frames + 1] = frame
    return frame
  end

  function UnitGUID(unit)
    if unit == "player" then
      return "Player-1-TEST"
    end
  end

  DEFAULT_CHAT_FRAME = { messages = {} }
  function DEFAULT_CHAT_FRAME:AddMessage(text)
    self.messages[#self.messages + 1] = text
  end

  function SendChatMessage()
    error("SendChatMessage must never be called")
  end

  SlashCmdList = {}
  WindfuryJackpotLog = nil
end

local function fire(event, ...)
  local frame = frames[#frames]
  frame.scripts.OnEvent(frame, event, ...)
end

local function addonPath()
  local source = arg and arg[0] or "dev/smoke.lua"
  local dir = string.match(source, "^(.*)/[^/]+$") or "."
  return dir .. "/../WindfuryJackpot/WindfuryJackpot.lua"
end

local function boot()
  dofile(addonPath())
  fire("ADDON_LOADED", "WindfuryJackpot")
  fire("ADDON_LOADED", "SomeOtherAddon")
  fire("PLAYER_LOGIN")
end

local function slash(text)
  SlashCmdList["WINDFURYJACKPOT"](text)
end

local function chatCount()
  return #DEFAULT_CHAT_FRAME.messages
end

local function countContaining(fragment, startAt)
  local found = 0
  for i = startAt or 1, chatCount() do
    if string.find(DEFAULT_CHAT_FRAME.messages[i], fragment, 1, true) then
      found = found + 1
    end
  end
  return found
end

local function logCountContaining(fragment)
  local found = 0
  for i = 1, #WindfuryJackpotLog do
    if string.find(WindfuryJackpotLog[i], fragment, 1, true) then
      found = found + 1
    end
  end
  return found
end

local function logIsPlain()
  for i = 1, #WindfuryJackpotLog do
    if string.find(WindfuryJackpotLog[i], "|", 1, true) then
      return false
    end
  end
  return true
end

local PLAYER = "Player-1-TEST"
local OTHER = "Player-9-OTHER"

-- Newer layout: true/false hideCaster and raid-flag numbers. 11 header fields.
local function modern(timestamp, subevent, source, payload)
  local event = {
    timestamp, subevent, false,
    source, "Name", 0, 0,
    "Creature-0-9", "Dummy", 0, 0,
  }
  for i = 1, #payload do
    event[#event + 1] = payload[i]
  end
  return event
end

-- Original layout: no hideCaster, no raid flags. 8 header fields.
local function legacy(timestamp, subevent, source, payload)
  local event = {
    timestamp, subevent,
    source, "Name", 0,
    "Creature-0-9", "Dummy", 0,
  }
  for i = 1, #payload do
    event[#event + 1] = payload[i]
  end
  return event
end

-- Raid flags, but no hideCaster boolean. 10 header fields.
local function raidFlags(timestamp, subevent, source, payload)
  local event = {
    timestamp, subevent,
    source, "Name", 0, 0,
    "Creature-0-9", "Dummy", 0, 0,
  }
  for i = 1, #payload do
    event[#event + 1] = payload[i]
  end
  return event
end

-- hideCaster is present, raid-flag numbers are not. 9 header fields.
local function shortHeader(timestamp, subevent, source, payload)
  local event = {
    timestamp, subevent, false,
    source, "Name", 0,
    "Creature-0-9", "Dummy", 0,
  }
  for i = 1, #payload do
    event[#event + 1] = payload[i]
  end
  return event
end

local pending

local function fireInfo(eventList)
  pending = eventList
  fire("COMBAT_LOG_EVENT_UNFILTERED")
  pending = nil
end

local function fireArgs(eventList)
  fire("COMBAT_LOG_EVENT_UNFILTERED", unpack(eventList, 1, #eventList))
end

local function readFile(path)
  local handle = assert(io.open(path, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

installStubs()

function CombatLogGetCurrentEventInfo()
  if not pending then
    return
  end
  return unpack(pending, 1, #pending)
end

local toc = readFile(string.match(addonPath(), "^(.*)%.lua$") .. ".toc")
check(string.find(toc, "## Interface: 00000", 1, true) ~= nil, "toc placeholder interface")
check(string.find(toc, "/dump select(4, GetBuildInfo())", 1, true) ~= nil, "toc tells you how to replace it")
check(string.find(toc, "## SavedVariables: WindfuryJackpotLog", 1, true) ~= nil, "toc saved variable")
check(string.find(toc, "## Version: 0.1.0", 1, true) ~= nil, "toc version")
check(string.find(toc, "\nWindfuryJackpot.lua", 1, true) ~= nil, "toc loads the lua file")

boot()
local frame = frames[#frames]
check(frame.events.COMBAT_LOG_EVENT_UNFILTERED, "registers the combat log")
check(frame.events.PLAYER_LOGIN, "registers login")
check(countContaining("WindfuryJackpot 0.1.0 loaded") == 1, "login message")
check(logCountContaining("loaded") == 0, "login message is not saved in the log")

local T = 10000
local before = chatCount()
fireInfo(modern(T, "SWING_DAMAGE", OTHER, { 10, 0, 1, 0, 0, 0, false, false, false, false }))
check(chatCount() == before, "ignores events from other units")

-- amount, overkill, school, resisted, blocked, absorbed, crit, glancing, crushing, offhand
-- Times are quarters of a second so the relative stamps stay exact in binary.
fireInfo(modern(T + 1, "SPELL_EXTRA_ATTACKS", PLAYER, { 25504, "Windfury Attack", 1, 2 }))
fireInfo(modern(T + 1.25, "SWING_DAMAGE", PLAYER, { 150, 0, 1, 0, 0, 0, true, false, false, false }))
fireInfo(modern(T + 1.5, "SWING_MISSED", PLAYER, { "DODGE", false }))
fireInfo(modern(T + 1.5, "SPELL_DAMAGE", PLAYER, { 78, "Heroic Strike", 1, 80, 0, 1, 0, 0, 0, false, false, false, false }))
fireInfo(modern(T + 1.5, "SPELL_DAMAGE", PLAYER, { 8042, "Earth Shock", 8, 40, 0, 8, 0, 0, 0, false, false, false, false }))
fireInfo(modern(T + 1.75, "SWING_DAMAGE", PLAYER, { 10, 0, 1, 0, 0, 0, false, false, false, false }))
fireInfo(modern(T + 5, "SPELL_AURA_APPLIED", PLAYER, { 8232, "Windfury Weapon", 1, "BUFF" }))
fireInfo(modern(T + 5.5, "SWING_DAMAGE", PLAYER, { 90, 0, 1, 0, 0, 0, false, false, false, false }))
fireInfo(modern(T + 5.75, "SWING_DAMAGE", PLAYER, { 11, 0, 1, 0, 0, 0, false, false, false, false }))

check(countContaining("[+0.000] SPELL_EXTRA_ATTACKS id=25504 name=\"Windfury Attack\" amount=2 crit=- extra=2") == 1, "prints extra attacks")
check(countContaining("|cffffcc00") >= 1, "colors windfury lines gold")
check(countContaining("[+0.250] SWING_DAMAGE id=- name=- amount=150 crit=yes") == 1, "prints a swing inside the window")
check(countContaining("[+0.500] SWING_MISSED id=- name=- amount=- crit=- miss=DODGE") == 1, "prints a miss on the window edge")
check(countContaining("Heroic Strike") == 1, "prints physical spell damage inside the window")
check(countContaining("|cff7ec8ff") >= 1, "colors follow-up swings blue")
check(countContaining("Earth Shock") == 0, "skips non-physical spell damage")
check(countContaining("amount=10") == 0, "skips swings after the half-second window")
check(countContaining("Windfury Weapon") == 1, "prints any spell whose name contains Windfury")
check(countContaining("[+4.500] SWING_DAMAGE id=- name=- amount=90 crit=no") == 1, "a new windfury line opens a fresh window")
check(countContaining("amount=11") == 0, "window does not stretch past half a second")
check(#WindfuryJackpotLog == 6, "saved six matching lines")
check(logIsPlain(), "saved lines have no color codes")
check(WindfuryJackpotLog[1] == "[+0.000] SPELL_EXTRA_ATTACKS id=25504 name=\"Windfury Attack\" amount=2 crit=- extra=2", "saved line matches chat text")

fireInfo(modern(T + 7, "SPELL_MISSED", PLAYER, { 25504, "Windfury Attack", 1, "IMMUNE" }))
check(countContaining('name="Windfury Attack" amount=- crit=- miss=IMMUNE') == 1, "spell miss reason is the field after the spell prefix")
check(logCountContaining("miss=IMMUNE") == 1, "spell miss is saved as plain text")
check(logIsPlain(), "log stays plain after a colored trigger")

-- The function's return value wins over arguments from a different unit.
before = chatCount()
fire(
  "COMBAT_LOG_EVENT_UNFILTERED",
  unpack(legacy(T + 8, "SPELL_EXTRA_ATTACKS", OTHER, { 1, "FromArgs", 1, 1 }), 1, 12)
)
-- fire() above did not set pending, so the function returned nothing and the
-- arguments were used. That event is another unit, so it must be ignored.
-- Re-fire with the function returning our event and the arguments saying otherwise.
pending = modern(T + 9, "SPELL_EXTRA_ATTACKS", PLAYER, { 1, "FromFunction", 1, 3 })
fire(
  "COMBAT_LOG_EVENT_UNFILTERED",
  unpack(legacy(T + 9, "SPELL_EXTRA_ATTACKS", OTHER, { 1, "FromArgs", 1, 1 }), 1, 12)
)
pending = nil
check(countContaining("FromArgs") == 0, "other unit's varargs are ignored")
check(countContaining("FromFunction") == 1, "CombatLogGetCurrentEventInfo wins when it returns fields")

slash("verbose")
before = chatCount()
fireInfo(modern(T + 10, "SWING_DAMAGE", OTHER, { 10, 0, 1, 0, 0, 0, false, false, false, false }))
check(chatCount() == before, "verbose still ignores other units")
before = chatCount()
fireInfo(modern(T + 10, "SPELL_HEAL", PLAYER, { 8004, "Healing Wave", 8, 500, 0, 0, false }))
check(chatCount() == before + 1, "verbose prints a line the filter would skip")
check(countContaining('2="SPELL_HEAL"') == 1, "verbose includes the raw fields")
check(logCountContaining('2="SPELL_HEAL"') == 1, "verbose lines are saved as plain text")
slash("VERBOSE")
before = chatCount()
fireInfo(modern(T + 11, "SPELL_HEAL", PLAYER, { 8004, "Healing Wave", 8, 500, 0, 0, false }))
check(chatCount() == before, "verbose toggles back off")

slash("off")
before = chatCount()
fireInfo(modern(T + 12, "SPELL_EXTRA_ATTACKS", PLAYER, { 1, "Windfury Attack", 1, 2 }))
check(chatCount() == before, "off ignores combat log lines")
slash("on")
fireInfo(modern(T + 13, "SPELL_EXTRA_ATTACKS", PLAYER, { 1, "Windfury Attack", 1, 1 }))
check(countContaining("extra=1") == 1, "on resumes sniffing")

local sameTable = WindfuryJackpotLog
slash("clear")
check(WindfuryJackpotLog == sameTable, "clear keeps the saved-variable table")
check(#WindfuryJackpotLog == 0, "clear wipes the log")
check(countContaining("Saved combat log cleared.") == 1, "clear tells you it did")

slash("help")
check(countContaining("/wfj verbose") >= 1, "help lists verbose")
slash("")
check(countContaining("Sniffer is on") >= 1, "bare /wfj prints status")
slash("nope")
check(countContaining("Unknown /wfj command") == 1, "unknown subcommand")

slash("verbose")
slash("clear")
for i = 1, 520 do
  fireInfo(modern(T + 100 + i, "SPELL_CAST_SUCCESS", PLAYER, { 5000 + i, "Marker" .. i, 1 }))
end
check(#WindfuryJackpotLog == 500, "log keeps the last 500 lines")
-- Quotes keep Marker1 from matching Marker10, and Marker20 from matching Marker200.
check(logCountContaining('"Marker1"') == 0, "first line was dropped")
check(logCountContaining('"Marker20"') == 0, "line 20 was dropped")
check(logCountContaining('"Marker21"') == 1, "line 21 is the oldest line kept")
check(logCountContaining('"Marker520"') == 1, "newest line is kept")
check(logIsPlain(), "capped log is still plain text")

-- Second load, with no CombatLogGetCurrentEventInfo at all (older clients).
installStubs()
CombatLogGetCurrentEventInfo = nil
boot()
check(frames[#frames].events.COMBAT_LOG_EVENT_UNFILTERED, "loads when the info function is missing")

local U = 20000
fireArgs(legacy(U, "SPELL_EXTRA_ATTACKS", PLAYER, { 123, "Legacy Windfury", 1, 2 }))
fireArgs(legacy(U + 0.25, "SWING_DAMAGE", PLAYER, { 77, 1, 0, 0, 0, true, false, false }))
fireArgs(legacy(U + 0.9, "SWING_DAMAGE", PLAYER, { 5, 1, 0, 0, 0, false, false, false }))
fireArgs(raidFlags(U + 2, "SPELL_EXTRA_ATTACKS", PLAYER, { 456, "Raidflag Windfury", 1, 4 }))
fireArgs(shortHeader(U + 4, "SPELL_EXTRA_ATTACKS", PLAYER, { 789, "Shorter Windfury", 1, 1 }))
check(countContaining('name="Legacy Windfury"') == 1, "varargs path reads an 8-field header")
check(countContaining("amount=77 crit=yes") == 1, "varargs path prints the following swing")
check(countContaining("amount=5") == 0, "varargs path still applies the window")
check(countContaining('name="Raidflag Windfury"') == 1, "10-field header reads the spell name")
check(countContaining("extra=4") == 1, "10-field header reads the extra-attack count")
check(countContaining('name="Shorter Windfury"') == 1, "9-field header reads the spell name")
check(countContaining("id=789") == 1, "9-field header reads the spell id")

-- Function exists but returns nothing: use the handler arguments.
function CombatLogGetCurrentEventInfo()
end
fireArgs(legacy(U + 3, "SPELL_AURA_APPLIED", PLAYER, { 99, "Windfury Totem", 1, "BUFF" }))
check(countContaining("Windfury Totem") == 1, "empty info function falls back to varargs")

if failures > 0 then
  print("--- chat ---")
  for i = 1, chatCount() do
    print(i .. ": " .. DEFAULT_CHAT_FRAME.messages[i])
  end
  print("--- log ---")
  for i = 1, #WindfuryJackpotLog do
    print(i .. ": " .. WindfuryJackpotLog[i])
  end
  os.exit(1)
end

print("all checks passed")
