-- WindfuryJackpot, step one: watch the combat log and write down what Windfury
-- looks like on this client. Later versions will turn that into a slot machine.
-- This version never casts spells or presses buttons.

-- A frame is an invisible UI object. Addons use one to sign up for events.
-- An event is a named message from the game, such as "you logged in" or
-- "something happened in combat". We register the ones we care about, and the
-- game calls our function when they happen.
-- The combat log is the stream of every swing, spell, and aura in a fight,
-- the same stream the Combat Log chat window shows. We read it so we can see
-- how Windfury shows up here, instead of guessing from other versions of WoW.

local ADDON_NAME = "WindfuryJackpot"
local VERSION = "0.1.0"

-- Half a second, measured on the combat log's own clock. Past clients count
-- that clock in seconds (the fraction is milliseconds). If these timestamps
-- turn out to be whole milliseconds, this window is too small; verbose mode
-- prints the raw timestamp so we can fix it.
local FOLLOW_WINDOW = 0.5

-- SavedVariables keep the last few hundred printed lines so a target-dummy
-- session can be sent in as a file after you log out.
local MAX_LOG_LINES = 500

-- Chat color codes. |cAARRGGBB turns color on, |r turns it off.
-- Gold marks the Windfury / extra-attack line. Blue marks swings just after it.
local COLOR_TRIGGER = "|cffffcc00"
local COLOR_FOLLOW = "|cff7ec8ff"

local enabled = true
local verbose = false
local followUntil -- combat-log timestamp; later swings before this are kept
local timeOrigin -- first timestamp we printed, so the chat shows small numbers

local function trim(text)
  if type(text) ~= "string" then
    return ""
  end
  return string.match(text, "^%s*(.-)%s*$") or ""
end

local function show(value)
  if value == nil then
    return "-"
  end
  if value == true then
    return "yes"
  end
  if value == false then
    return "no"
  end
  return tostring(value)
end

local function showName(value)
  if type(value) ~= "string" then
    return "-"
  end
  return string.format("%q", value)
end

local function dumpValue(value)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  end
  if kind == "number" or kind == "boolean" then
    return tostring(value)
  end
  if value == nil then
    return "nil"
  end
  return "<" .. kind .. ">"
end

-- Seconds since the first line we printed, with millisecond precision.
local function relativeTime(timestamp)
  if type(timestamp) ~= "number" then
    return "?"
  end
  if not timeOrigin then
    timeOrigin = timestamp
  end
  return string.format("%+.3f", timestamp - timeOrigin)
end

local function say(text)
  -- DEFAULT_CHAT_FRAME is the window you type in. AddMessage stays on this
  -- computer. We never call SendChatMessage, which would talk to other players.
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  end
end

-- WindfuryJackpotLog is declared in the .toc. The game loads it before
-- ADDON_LOADED and writes it out on logout. Keep the same table: replacing
-- it can make some clients save the old one instead.
local function remember(line)
  if type(WindfuryJackpotLog) ~= "table" then
    WindfuryJackpotLog = {}
  end
  local log = WindfuryJackpotLog
  log[#log + 1] = line
  while #log > MAX_LOG_LINES do
    table.remove(log, 1)
  end
end

local function report(plain, color)
  if color then
    say(color .. plain .. "|r")
  else
    say(plain)
  end
  remember(plain)
end

-- Copy every argument, including nils in the middle. A plain {...} would
-- drop everything after the first nil, and some log lines have holes.
local function pack(...)
  local count = select("#", ...)
  local fields = { n = count }
  for i = 1, count do
    fields[i] = select(i, ...)
  end
  return fields
end

-- Newer clients leave the handler arguments empty and put the fields in
-- CombatLogGetCurrentEventInfo(). Older clients have no such function and
-- pass the fields into the handler. If the function exists but returns
-- nothing, we still read the arguments so a stub cannot hide the line.
local function currentFields(...)
  if type(CombatLogGetCurrentEventInfo) == "function" then
    local fromFunction = pack(CombatLogGetCurrentEventInfo())
    if fromFunction.n > 0 then
      return fromFunction
    end
  end
  return pack(...)
end

-- The front of every line is "when, what, who". Clients disagree on how many
-- fields that header is, so we look at types instead of assuming a version:
--   * true/false in slot 3: newer layout. 11 fields if slot 7 is a number
--     (raid flags), otherwise 9.
--   * number in slot 6: raid flags, but no true/false (10 fields).
--   * otherwise the original 8-field header.
-- The source GUID is slot 4 when slot 3 is true/false, and slot 3 otherwise.
local function headerLength(fields)
  if type(fields[3]) == "boolean" then
    if type(fields[7]) == "number" then
      return 11
    end
    return 9
  end
  if type(fields[6]) == "number" then
    return 10
  end
  return 8
end

local function sourceGUID(fields)
  if type(fields[3]) == "boolean" then
    return fields[4]
  end
  return fields[3]
end

local function readEvent(fields)
  local header = headerLength(fields)
  local count = fields.n or 0
  local function pay(index)
    return fields[header + index]
  end
  local payCount = count - header
  if payCount < 0 then
    payCount = 0
  end

  -- Spell lines start with spell id, spell name, school (number, text, number).
  -- Swings skip that and start with the damage amount. A leading word is only
  -- skipped for ENVIRONMENTAL lines ("FALLING", and so on). Miss reasons are
  -- not a prefix: SWING_MISSED starts with "MISS" or "DODGE".
  local spellId, spellName, spellSchool
  local suffixAt
  local subevent = fields[2]
  local environmental = type(subevent) == "string" and string.sub(subevent, 1, 13) == "ENVIRONMENTAL"
  if payCount >= 3
      and type(pay(1)) == "number"
      and type(pay(2)) == "string"
      and type(pay(3)) == "number" then
    spellId, spellName, spellSchool = pay(1), pay(2), pay(3)
    suffixAt = 4
  elseif environmental then
    suffixAt = 2
  else
    suffixAt = 1
  end

  local isDamage = type(subevent) == "string" and string.sub(subevent, -7) == "_DAMAGE"
  local isMiss = type(subevent) == "string" and string.sub(subevent, -7) == "_MISSED"

  local missType
  if isMiss and type(pay(suffixAt)) == "string" then
    missType = pay(suffixAt)
  end

  -- On damage lines the amount has always been the first number after the
  -- spell prefix, and the critical flag the first true/false. Miss lines
  -- start with a reason ("MISS", "DODGE", ...) and their booleans are not
  -- the critical flag, so we leave crit blank there.
  local amount, crit
  for i = suffixAt, payCount do
    if amount == nil and type(pay(i)) == "number" then
      amount = pay(i)
    end
  end
  if isDamage then
    for i = suffixAt, payCount do
      if type(pay(i)) == "boolean" then
        crit = pay(i)
        break
      end
    end
  end

  local extra
  if subevent == "SPELL_EXTRA_ATTACKS" then
    extra = amount
  end

  return {
    subevent = subevent,
    spellId = spellId,
    spellName = spellName,
    spellSchool = spellSchool,
    amount = amount,
    crit = crit,
    extra = extra,
    missType = missType,
  }
end

local function nameHasWindfury(spellName)
  if type(spellName) ~= "string" then
    return false
  end
  return string.find(string.lower(spellName), "windfury", 1, true) ~= nil
end

local function isTrigger(info)
  -- Every extra-attack line, not only ones named Windfury. Sword spec and
  -- similar effects use this too, and we want to see them.
  if info.subevent == "SPELL_EXTRA_ATTACKS" then
    return true
  end
  return nameHasWindfury(info.spellName)
end

-- "Melee-ish" spell damage: the school includes Physical. Schools are a
-- bitmask where 1 means Physical, so any odd school has that bit. Auto-attacks
-- are usually SWING_ events; this catches extra hits logged as spells.
local function isMeleeishSpellDamage(info)
  if info.subevent ~= "SPELL_DAMAGE" then
    return false
  end
  return type(info.spellSchool) == "number" and (info.spellSchool % 2 == 1)
end

local function isFollowup(info)
  if info.subevent == "SWING_DAMAGE" or info.subevent == "SWING_MISSED" then
    return true
  end
  return isMeleeishSpellDamage(info)
end

local function armFollowWindow(timestamp)
  if type(timestamp) ~= "number" then
    return
  end
  local untilTime = timestamp + FOLLOW_WINDOW
  if not followUntil or untilTime > followUntil then
    followUntil = untilTime
  end
end

local function inFollowWindow(timestamp)
  return followUntil ~= nil and type(timestamp) == "number" and timestamp <= followUntil
end

local function formatFiltered(fields, info)
  local parts = {
    "[" .. relativeTime(fields[1]) .. "]",
    tostring(info.subevent or "?"),
    "id=" .. show(info.spellId),
    "name=" .. showName(info.spellName),
    "amount=" .. show(info.amount),
    "crit=" .. show(info.crit),
  }
  if info.subevent == "SPELL_EXTRA_ATTACKS" then
    parts[#parts + 1] = "extra=" .. show(info.extra)
  end
  if info.missType then
    parts[#parts + 1] = "miss=" .. info.missType
  end
  return table.concat(parts, " ")
end

-- Every raw field, numbered. Field 1 is the client's timestamp, unchanged.
local function formatVerbose(fields)
  local bits = {}
  local count = fields.n or 0
  for i = 1, count do
    bits[#bits + 1] = i .. "=" .. dumpValue(fields[i])
  end
  return "[" .. relativeTime(fields[1]) .. "] " .. table.concat(bits, " ")
end

local function onCombatLog(...)
  if not enabled then
    return
  end

  local fields = currentFields(...)
  local player
  if type(UnitGUID) == "function" then
    player = UnitGUID("player")
  end
  -- Only lines that come from us. UnitGUID and the log's source GUID are
  -- the same string for the same unit, whatever format this client uses.
  if not player or sourceGUID(fields) ~= player then
    return
  end

  local info = readEvent(fields)
  local trigger = isTrigger(info)
  if trigger then
    armFollowWindow(fields[1])
  end
  local follow = (not trigger) and inFollowWindow(fields[1]) and isFollowup(info)

  local color
  if trigger then
    color = COLOR_TRIGGER
  elseif follow then
    color = COLOR_FOLLOW
  end

  if verbose then
    report(formatVerbose(fields), color)
    return
  end

  if trigger or follow then
    report(formatFiltered(fields, info), color)
  end
end

local function initLog()
  if type(WindfuryJackpotLog) ~= "table" then
    WindfuryJackpotLog = {}
  end
  while #WindfuryJackpotLog > MAX_LOG_LINES do
    table.remove(WindfuryJackpotLog, 1)
  end
end

local function clearLog()
  if type(WindfuryJackpotLog) ~= "table" then
    WindfuryJackpotLog = {}
    return
  end
  for key in pairs(WindfuryJackpotLog) do
    WindfuryJackpotLog[key] = nil
  end
end

local function statusText()
  local watch = enabled and "on" or "off"
  local noise = verbose and "on" or "off"
  return "Sniffer is " .. watch .. ", verbose is " .. noise .. ". Type /wfj help."
end

local function onSlash(message)
  local command = string.lower(trim(message))
  if command == "" then
    say(statusText())
  elseif command == "on" then
    enabled = true
    say("Sniffer on. " .. statusText())
  elseif command == "off" then
    enabled = false
    say("Sniffer off. Combat log lines are ignored.")
  elseif command == "verbose" then
    verbose = not verbose
    if verbose then
      say("Verbose on. Printing every combat log line from you.")
    else
      say("Verbose off. Printing only Windfury-looking lines and nearby swings.")
    end
  elseif command == "clear" then
    clearLog()
    say("Saved combat log cleared.")
  elseif command == "help" then
    say("WindfuryJackpot watches your combat log and prints in this window only.")
    say("/wfj on - start watching (this is the default).")
    say("/wfj off - stop watching.")
    say("/wfj verbose - toggle a full dump of every line from you.")
    say("/wfj clear - erase the saved log.")
    say("/wfj help - show this.")
    say("Gold lines are extra attacks, or a spell with Windfury in the name.")
    say("Blue lines are melee hits in the next half second. Nothing is sent to party or public chat.")
  else
    say("Unknown /wfj command. Type /wfj help.")
  end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local addonName = ...
    if addonName == ADDON_NAME then
      initLog()
    end
  elseif event == "PLAYER_LOGIN" then
    say("WindfuryJackpot " .. VERSION .. " loaded. Watching your combat log in this window only. Type /wfj help.")
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    onCombatLog(...)
  end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

-- SlashCmdList is how the game turns "/wfj something" into a function call.
-- The word after SLASH_ has to match the table key below.
SLASH_WINDFURYJACKPOT1 = "/wfj"
SlashCmdList = SlashCmdList or {}
SlashCmdList["WINDFURYJACKPOT"] = onSlash
