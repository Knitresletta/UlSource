# UlSource

Where did this come from? An addon for **World of Warcraft: Forever** that records where your materials come from, both mob drops and gathering nodes, and shows it to you later in the item tooltip.

A separate addon from [UlRemedyForever](https://github.com/Knitresletta/UlRemedyForever). Same author, same style, no shared code. UlRemedyForever is a set of small fixes that remember nothing; UlSource is a database that grows every time you loot.

> **Status:** probe build 0.1.3, collects raw loot data and nothing else. Target client: Forever beta (build 1.60.1, interface `16001`).

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
| Kill counter | Counts looted corpses and node openings so the drop rate has a denominator | The loot windows themselves, one per corpse or node (the combat log is closed to addons on Forever, see below) | Counters in Store |
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

## What the probe has found so far

Build 1.60.1.70374, 15.10.2026:

- **The combat log is closed to addons.** `RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")` is refused with `ADDON_ACTION_FORBIDDEN` (the "blocked from an action only available to the Blizzard UI" popup) and `CombatLogGetCurrentEventInfo` does not exist. This is the Midnight restriction Forever runs with. Kills cannot be counted, so the denominator for drop rates is looted corpses, which is what the loot window gives anyway.
- **Auto loot empties the window before `LOOT_OPENED`.** With auto loot on, Blizzard's loot frame takes everything on `LOOT_READY`, which fires first; `LOOT_OPENED` then reports zero slots. The probe records on `LOOT_READY` since 0.1.1.
- **`LOOT_READY` fires twice per window**, once before `LOOT_OPENED` and once about a quarter second after it. Since 0.1.2 the second one is noted on the open record instead of starting a new one.
- **`GetLootSourceInfo` works** and gives one GUID and quantity per slot. A corpse gives `Creature-0-4615-1-3278-3456-...` (NPC ID 3456, Razormane Pathfinder), an herb node gives `GameObject-0-4615-1-3278-3730-...` (object ID 3730, a Bruiseweed node), with the Herbalism cast (spell 3570) recorded 0 s before. Money slots have `GetLootSlotType` 2 and no link.
- **Loot is readable in combat.** Corpses looted while still in combat (Razorfen Kraul, 0.1.3) gave their slots and source GUIDs like any other. Two empty hyena corpses in the Barrens had zero slots, which is just empty corpses.
- **Inside an instance the target is secret, the loot source is not.** In Razorfen Kraul (party of 5) `UnitName`, `UnitGUID` and `UnitCreatureType` for the target all came back as secret values, but `GetLootSourceInfo` still gave plain `Creature-...-<npcID>-...` GUIDs for every slot (16 windows). So the NPC ID is always available; the NPC's *name* is only readable outside instances. The addon will have to learn names where it can and show the ID until then.
- **No map position inside an instance.** `C_Map.GetBestMapForUnit("player")` returns nil in Razorfen Kraul, so no coordinates; the zone text (`GetRealZoneText`) is still there.
- **Chests and other objects** come through like herb nodes: a GameObject GUID (19861 for Henrig Lonebrow's Journal) with the cast "Opening - No Text" just before.
- **Group loot:** items at or above the loot threshold (a green belt, a blue Death Prophet Spine) stay in the window unclaimed while the roll runs, still with their source GUID. Items won on rolls by others never open a window on this client, so they are not seen.
- **Money slots** have `GetLootSlotType` 2, no link, quantity 0, and the amount in copper as the source quantity.
- **Not seen yet:** mining, skinning, fishing.
- **These exist:** `GetLootSourceInfo`, `GetLootSlotInfo`, `GetLootSlotLink`, `GetLootSlotType`, `GetLootInfo`, `IsFishingLoot`, `C_Map.GetPlayerMapPosition` (works, map 1413 The Barrens), `TooltipDataProcessor.AddTooltipPostCall`, `issecretvalue`, `canaccessvalue`. **These do not:** the global `GetItemInfo` and `GetSpellInfo` (use `C_Item` and `C_Spell`), `C_LootHistory.GetNumItems`.
- A creature GUID looks like `Creature-0-4615-1-3278-4128-00004FF037`: the sixth field is the NPC ID (4128, Hecklefang Stalker).

## Probe build (0.1.x)

The current version has no tooltip and no database. It records every loot window, raw, to `UlSourceDB.probe` in the saved variables file (`WTF/Account/<account>/SavedVariables/UlSource.lua`): the event arguments, every slot with its source GUIDs, map position, zone, target, whether the client calls it fishing loot, and the last spell you cast (the gathering spell that opened a node). Values the client hides as secret are stored as `<secret>`, missing functions as `no <name>`, so the file says exactly what Forever gives an addon. The last 400 loot windows are kept.

| Command | Description |
|---------|-------------|
| `/us probe` | What has been recorded: loot windows, kill events and how many had secret data, missing API |
| `/us last` | Print the last loot window in full |
| `/us quiet` | Toggle the one-line chat note per loot window |
| `/us probereset` | Forget all probe data |
| `/us errors` | Save this session's Lua errors and blocked actions to the saved variables (also done on logout and reload) |

To answer the open questions, one session should include: killing and looting a few mobs (some looted while still in combat), herbs, ore, a fishing cast, skinning a corpse, and opening a chest. Then log out or `/reload` so the file is written, and read it.

## Minimap button (planned)

UlSource has no minimap button of its own. UlRemedyForever is the master addon and owns the one Ul minimap button: left-click opens its options, right-click opens a menu with one row per installed Ul addon. UlSource registers itself into that menu at `PLAYER_LOGIN`:

```lua
if UlRemedy and UlRemedy.Register then
    UlRemedy.Register({
        id = "UlSource",
        title = "UlSource",
        icon = "Interface\\AddOns\\UlSource\\media\\icon",
        open = UlSource.ToggleWindow,
    })
end
```

and nothing more. The guard means UlSource works exactly the same when UlRemedyForever is not installed: slash commands only, no button.

**Dependency:** UlSource reads one global, `UlRemedy`, and only if it exists. The TOC gets `## OptionalDeps: UlRemedyForever` so the load order is explicit (it is alphabetical anyway, and `UlRemedyForever` sorts first). No shared code, no shared saved variables. The button, the menu and the registry live in UlRemedyForever and are described there. UlDungeonCompanion registers the same way, so the menu has all three.

## Development

Same loop as UlRemedyForever: package with the `package-addon` skill in dry-run mode, copy the zip to the Windows machine over scp, unpack into the Forever AddOns folder, full restart when the TOC gains files, `/reload` otherwise. Release to CurseForge only on an explicit yes.
