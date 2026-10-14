# UlSource

Where did this come from? An addon for **World of Warcraft: Forever** that records where your materials come from, both mob drops and gathering nodes, and shows it to you later in the item tooltip.

A separate addon from [UlRemedyForever](https://github.com/Knitresletta/UlRemedyForever). Same author, same style, no shared code. UlRemedyForever is a set of small fixes that remember nothing; UlSource is a database that grows every time you loot.

> **Status:** probe build 0.1.0, collects raw loot data and nothing else. Target client: Forever beta (build 1.60.1, interface `16001`).

## Why

Forever has no trustworthy drop database. Wowhead and the old Classic databases describe 1.12, and Forever has changed drop tables, zones and professions. The only reliable source is what you see yourself. UlSource collects it so that a week later, when you need twenty Linen Cloth or a stack of Peacebloom, the tooltip tells you where you found it last time and how often.

## Scope

**It does:**
- Record every item you loot with its source: the mob (name and NPC ID) or the gathering node (name and object ID), the zone, the coordinates and the time.
- Count kills and node openings per source, so drop rates are real fractions ("12 of 40 Murloc Scouts dropped it"), not just "seen once".
- Show the collected data in the item tooltip: top sources, zone, drop rate, last seen.
- Let you clear the data, per item or everything.

**It deliberately does not:**
- Ship any pre-made drop data. Everything in the database comes from this account's own looting.
- Share data with other players. Addon messages over a chat channel (the mechanism UlRemedyForever uses for auction prices) would be the way if that ever becomes wanted. That is a separate decision, a separate version and a separate section in this README, with the same "what leaves your machine" honesty as UlRemedyForever.
- Change how looting works. No auto-loot, no filtering, no selling. It watches and writes down.
- Track quest rewards, vendor purchases, mail or trades. Only loot windows.

## How it would work

| Element | Does | Needs | Writes |
|---|---|---|---|
| Collector | Listens to the loot window opening, reads every slot and its source | `LOOT_OPENED`, `LOOT_SLOT_CLEARED`, `GetLootSourceInfo`, `GetLootSlotInfo`, `C_Map.GetPlayerMapPosition` | Nothing directly, hands records to Store |
| Source resolver | Turns a loot source GUID into "mob 1234 Murloc Scout" or "node 5678 Peacebloom" | The GUID string (type and ID are in it), `UNIT_SPELLCAST_SUCCEEDED` for the gathering spell that opened a node | Nothing |
| Kill counter | Counts kills and node openings so the drop rate has a denominator | `COMBAT_LOG_EVENT_UNFILTERED` (`UNIT_DIED` for your kills), the same gathering spell event | Counters in Store |
| Store | The database, one entry per item with a list of sources and counts | SavedVariables `UlSourceDB` | SavedVariables only |
| Tooltip | Adds the lines to the item tooltip | `TooltipDataProcessor` (Forever runs the retail 12.x tooltip code, not the Classic `OnTooltipSetItem` hook) | Nothing |
| Options and slash | `/us` to list, clear and toggle | `UlSourceDB.settings` | Settings |

Nothing calls out of the game. No network, no other addons, no chat messages. The addon reads loot, combat log and map position, and writes one SavedVariables file.

## Open questions to settle first

These must be probed in-game before the data model is drawn, in the same way the trainer API was probed for UlRemedyForever:

1. **Does `GetLootSourceInfo` exist and work on Forever?** It is the retail API that gives a GUID per loot slot. Without it the source has to be guessed from the target or the last cast, which is much weaker.
2. **What do gathering GUIDs look like?** A node is a GameObject; the GUID should carry its object ID. Check that herbs, ore and fishing all come through the loot window the same way.
3. **Skinning:** the corpse is the source, but the item came from a profession, not a kill. Decide whether that counts as a mob drop, a node, or its own category.
4. **Secret values:** Forever's client marks some UI values as secret in combat. Check that loot slot info and source GUIDs are readable when the loot window opens right after a kill.
5. **Database size:** one entry per (item, source) with counters stays small. Per-loot rows with coordinates do not. Decide early whether coordinates are kept per loot or averaged per source.

## First step

A probe build with no UI: on every loot window, write the raw slot info, source GUIDs, player position and the last gathering spell to `UlSourceDB.probe`, then read the file after a session of killing and gathering. That answers questions 1 to 4 with real data before any design is locked.

## Probe build (0.1.x)

The current version has no tooltip and no database. It records every loot window, raw, to `UlSourceDB.probe` in the saved variables file (`WTF/Account/<account>/SavedVariables/UlSource.lua`): the event arguments, every slot with its source GUIDs, map position, zone, target, whether the client calls it fishing loot, the last spell you cast (the gathering spell that opened a node), and the last kills seen in the combat log. Values the client hides as secret are stored as `<secret>`, missing functions as `no <name>`, so the file says exactly what Forever gives an addon. The last 400 loot windows are kept.

| Command | Description |
|---------|-------------|
| `/us probe` | What has been recorded: loot windows, kill events and how many had secret data, missing API |
| `/us last` | Print the last loot window in full |
| `/us quiet` | Toggle the one-line chat note per loot window |
| `/us probereset` | Forget all probe data |
| `/us errors` | Save this session's Lua errors and blocked actions to the saved variables (also done on logout and reload) |

To answer the open questions, one session should include: killing and looting a few mobs (some looted while still in combat), herbs, ore, a fishing cast, skinning a corpse, and opening a chest. Then log out or `/reload` so the file is written, and read it.

## Development

Same loop as UlRemedyForever: package with the `package-addon` skill in dry-run mode, copy the zip to the Windows machine over scp, unpack into the Forever AddOns folder, full restart when the TOC gains files, `/reload` otherwise. Release to CurseForge only on an explicit yes.
