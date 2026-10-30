# WindfuryJackpot

A joke slot-machine UI for shaman Windfury procs, for Blizzard's WoW Forever client (classic-style, game version 1.60.x).

This version watches your combat log and writes down how Windfury shows up, so a later version can build the slot machine from real events.

Copy the `WindfuryJackpot` folder into the game. Leave `dev/` where it is; the game does not load it.

## Install

1. Copy `WindfuryJackpot` into the Forever client's AddOns folder, so the files look like this:

   `Interface/AddOns/WindfuryJackpot/WindfuryJackpot.toc`

   `Interface/AddOns/WindfuryJackpot/WindfuryJackpot.lua`

   The `.toc` has to sit directly inside `AddOns/WindfuryJackpot/`, not in another subfolder.

2. Open `WindfuryJackpot.toc`. The Interface number is a placeholder (`00000`) because the real one is not known until launch. In game, run:

   `/dump select(4, GetBuildInfo())`

   Replace `00000` with the number that prints.

3. On the character-select screen, open AddOns and enable WindfuryJackpot. If it is marked out of date, tick **Load out of date AddOns**.

4. Type `/console scriptErrors 1` so Lua errors show in your chat window instead of failing silently.

5. Type `/reload`.

## Try it on a dummy

1. You should see one line: `WindfuryJackpot 0.1.0 loaded...`. If you do not, the addon is not enabled, or the Interface number is still wrong and "Load out of date AddOns" is off.
2. Buff Windfury Weapon and hit a target dummy.
3. Watch the chat window you type in. Gold lines are extra attacks, or any spell with Windfury in the name. Blue lines are melee hits in the next half second (weapon swings, and spell hits whose school includes Physical). The number in brackets is seconds since the first line, with milliseconds (`+1.250` is 1 second and 250 ms).
4. `/wfj help` lists commands. `/wfj verbose` prints every combat-log line that comes from you. That is noisy, and it is what to turn on if the gold/blue filter misses the proc.
5. Log out (or `/reload`), then send this file:

   `WTF/Account/<ACCOUNT>/SavedVariables/WindfuryJackpot.lua`

   `<ACCOUNT>` is the folder name under `WTF/Account/`. The file holds the last 500 combat lines, as plain text. Messages from `/wfj` itself are not stored.

The addon only writes to your own chat window. It does not send anything to party, raid, or public chat, and it does not press buttons for you.

## Commands

- `/wfj` — show whether sniffing is on
- `/wfj on` — start watching (this is the default)
- `/wfj off` — stop
- `/wfj verbose` — toggle the full dump
- `/wfj clear` — erase the saved log
- `/wfj help` — list these

## Check the script without the game

If Lua 5.1 is installed, from the repo root:

```
lua dev/smoke.lua
```

That fakes the frame and the combat log, then feeds a few fake events through both ways a client can deliver them (`CombatLogGetCurrentEventInfo`, or the event arguments when that function is missing).
