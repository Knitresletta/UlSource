# UlSource

Where did this come from? An addon for **World of Warcraft: Forever** that records where your materials come from, both mob drops and gathering nodes, and shows it to you later in the item tooltip.

A separate addon from [UlRemedyForever](https://github.com/Knitresletta/UlRemedyForever). Same author, same style, no shared code. UlRemedyForever is a set of small fixes that remember nothing; UlSource is a database that grows every time you loot.

> **Status:** 0.3.0: records loot, shows sources in tooltips, browser window with a seat in the Ul minimap menu. Not verified in play: mining, skinning, fishing (no character has those professions yet). Target client: Forever beta (build 1.60.1, interface `16001`).

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

## How it works

| Element | Does | Needs | Writes |
|---|---|---|---|
| Collector (`Collector.lua`) | Reads every slot and its source when a loot window is ready, one record per window | `LOOT_READY`, `GetLootSourceInfo`, `GetLootSlotInfo`, `GetLootSlotLink`, `C_Map.GetPlayerMapPosition`, `UNIT_SPELLCAST_SUCCEEDED` for the Skinning cast | Nothing directly, hands records to Store |
| Store (`Store.lua`) | The database: sources with window counts and points, items with per-source counts, learned names. The only module that writes to it | SavedVariables `UlSourceDB` | SavedVariables only |
| Name table (`NameData.lua`) | NPC and object names shipped with the addon, built by `tools/build_names.py` | The vmangos 1.12 world database at build time | Nothing |
| Name learner (`Names.lua`) | Fills in creature names the table does not have | `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`, `UnitGUID`, `UnitName` outside instances | Names in Store |
| Tooltip (`Tooltip.lua`) | Adds the Source lines to the item tooltip | `TooltipDataProcessor` (Forever runs the retail 12.x tooltip code), `AddLine` only | Nothing |
| Window (`Window.lua`) | The browser: searchable item list, the selected item's sources, settings, forget buttons. Registers in UlRemedyForever's minimap menu when that addon is there | Store, `UlRemedy.Register` if it exists | Settings |
| Core (`Core.lua`) | Settings, `/us` commands, Lua error log | `UlSourceDB.settings`, `ScriptErrorsFrame.errorData` | Settings, `UlSourceDB.errors` |
| Probe (`Probe.lua`) | Raw per-window records for API probing, off by default | The same loot events | `UlSourceDB.probe` when on |

The combat log is closed to addons on Forever, so there is no kill counter: the denominator for a drop rate is loot windows opened on that source.

Nothing calls out of the game. No network, no other addons, no chat messages. The addon reads loot, combat log and map position, and writes one SavedVariables file.

## Open questions, and what the probe answered

1. **Does `GetLootSourceInfo` exist and work on Forever?** Yes. One GUID and quantity per slot, readable in combat and inside instances. Answered 15.10.2026.
2. **What do gathering GUIDs look like?** Herb nodes and chests are GameObjects with the object ID in the GUID. Mining and fishing not seen yet, expected to be the same.
3. **Skinning:** not seen yet. The plan below treats a Creature source with a Skinning cast just before as its own source kind, so skins and drops get separate rates.
4. **Secret values:** loot slots and source GUIDs are never secret. The target's name and GUID are secret inside instances, so NPC names must be learned outside and the ID shown until then.
5. **Database size:** decided below. Counters per (item, source), a few recent points per source and zone, no per-loot rows.

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
- **Mining, fishing and skinning are not verified.** No character on this account has those professions yet. All three go through the loot window, so they are expected to record like herbs and corpses: an ore vein as a GameObject source, open-water fishing as the fishing bobber object (35591) and pool fishing as the pool object, a skinned corpse as its creature GUID right after a Skinning cast. Expected, not seen.
- **These exist:** `GetLootSourceInfo`, `GetLootSlotInfo`, `GetLootSlotLink`, `GetLootSlotType`, `GetLootInfo`, `IsFishingLoot`, `C_Map.GetPlayerMapPosition` (works, map 1413 The Barrens), `TooltipDataProcessor.AddTooltipPostCall`, `issecretvalue`, `canaccessvalue`. **These do not:** the global `GetItemInfo` and `GetSpellInfo` (use `C_Item` and `C_Spell`), `C_LootHistory.GetNumItems`.
- A creature GUID looks like `Creature-0-4615-1-3278-4128-00004FF037`: the sixth field is the NPC ID (4128, Hecklefang Stalker).

## Data model

Drafted 15.10.2026, implemented in 0.2.0 as written here, with one change: learned names live in `UlSourceDB.names` (by NPC or object ID) rather than on each source entry, so a name learned for `c:4511` also serves `s:4511`.

Everything lives in one SavedVariables table, `UlSourceDB`, account-wide: what one character learns, every character sees. The shape is chosen so that the tooltip can be drawn from one lookup per item, and so that the file stays small no matter how much is looted.

### The three questions the tooltip answers

For an item: **where did it come from** (which sources), **how often** (dropped in x of y windows), and **where was that** (zone and a point). Everything stored exists to answer one of those three. Nothing is stored per loot.

### Sources

A source is the thing that was looted, identified by a short key:

| Key | Means | Comes from |
|---|---|---|
| `c:4436` | A creature's drop, NPC ID 4436 | `Creature-...` GUID from `GetLootSourceInfo` |
| `o:1621` | A game object: herb node, ore vein, chest | `GameObject-...` GUID from `GetLootSourceInfo` |
| `s:4511` | A skinned corpse, NPC ID 4511 | `Creature-...` GUID when the player cast Skinning within 2 seconds before `LOOT_READY` |

The skinning key is separate from the drop key on purpose: a corpse that has been looted and then skinned opens two windows with the same GUID, and "Boar Ribs, 1 of 12 Thunderhawks" would be a lie if the twelve included the skinning windows. The same mechanism would give fishing its own kind (`f:`) if fishing turns out to carry a GUID; it is unknown until seen.

```lua
UlSourceDB.sources["c:4436"] = {
    kind = "c", id = 4436,
    name = "Razorfen Quilguard",      -- nil until learned, see below
    windows = 12,                     -- loot windows opened on this source
    last = 1760500000,                -- time() of the last window
    zones = {
        ["Razorfen Kraul"] = {
            n = 12,
            points = { { 0.46, 0.85, 1760500000 }, ... },   -- newest first, at most 5; empty inside instances
        },
    },
}
```

Points are kept as a short list per zone, not averaged. A creature roams and a node has several spawn points, and the average of five spawn points is a place where nothing grows. Five recent points per zone is enough for "around 46,85 in the Barrens" and costs nothing.

### Items

```lua
UlSourceDB.items[2450] = {
    name = "Briarthorn",             -- from the loot slot, so the tooltip works before the item cache is warm
    sources = {
        ["o:1621"] = { n = 5, qty = 11, last = 1760500000 },   -- windows it appeared in, total quantity, last time
        ["c:4436"] = { n = 1, qty = 1,  last = 1760400000 },
    },
}
```

The drop rate for an item from a source is `items[id].sources[key].n / sources[key].windows`. Both numbers come from the same windows, so the fraction is honest: "5 of 5 Briarthorn nodes" and "1 of 12 Razorfen Quilguards".

### What counts as one window

`LOOT_READY` fires twice per window; the second one within 1.5 seconds of the first is ignored. A window with no slots has no GUID to attribute and is not counted (an empty corpse is not lootable in the first place, so this is rare). Money and currency slots carry a GUID and so count the window for the source, but the money itself is not stored. Every slot is read on `LOOT_READY`, before auto loot empties the window, and an item counts whether or not it is then taken, so items left for a group roll are seen. A window may hold slots from more than one GUID (the client supports looting several corpses at once); then each source gets one window and each slot is attributed to its own GUID.

What the data cannot see, said once: corpses looted by other group members, and items others win on rolls. The denominator is "windows this account opened", not kills.

### Names

The loot source is a GUID; the name of the creature is not in it, and inside instances the target's name and GUID are secret values. Names come from three places, in this order:

1. **A shipped table**, `NameData.lua`: NPC ID to name for 10,381 creatures and object ID to name for 743 chests, nodes and fishing pools, generated by `tools/build_names.py` from the vmangos world database (vanilla 1.12). Names are server data and not in the client files, so a server database is the only offline source. Forever keeps the 1.12 IDs for everything old (checked against the probe: 4436 Razorfen Quilguard, 1621 Briarthorn, 19861 Henrig Lonebrow's Journal). Forever-new creatures and objects are not in it.
2. **The target at loot time**, outside instances: when the target's GUID is readable and equals the source GUID, its name is stored on the source.
3. **Two cheap learners afterwards:** on `PLAYER_TARGET_CHANGED` and `UPDATE_MOUSEOVER_UNIT`, when `UnitGUID` is readable and points to a creature whose `c:` or `s:` entry has no name yet, the name is written. Game objects have no unit, so a Forever-new node is named after the first item it gave ("Briarthorn") until a better source exists.

Learned names are stored in `UlSourceDB.names` and win over the shipped table, so a renamed creature shows its Forever name once seen; a name the table already has is not stored again. The tooltip shows `Razorfen Quilguard` when the name is known and `NPC 4436` until then, never a guess.

Wowhead's Forever database has the new creatures and rares; pulling those into the table is a later tool, not part of 0.2.0.

### Tooltip

Under the item's own lines, at most three sources, best first (most windows the item appeared in):

```
Source: Briarthorn node, 5 of 5, The Barrens 46,85 (2 h ago)
        Razorfen Quilguard, 1 of 12, Razorfen Kraul
        NPC 4523, 1 of 9, Razorfen Kraul
```

Same hook as UlRemedyForever: `TooltipDataProcessor.AddTooltipPostCall` for `Enum.TooltipDataType.Item`, `AddLine` only, no money frames or layout calls inside the tooltip.

### Size

A source is about 200 bytes plus 30 per point, an item-source pair about 50. Two thousand sources and five thousand pairs, which is a long time of looting, is under one megabyte. No cap is needed, but `/us clear` per item and `/us clearall` exist.

### Settings and housekeeping

```lua
UlSourceDB.settings = { enabled = true, lines = 3, showIDs = false, probe = false }
UlSourceDB.version = 1     -- bumped when the shape changes; an older file is migrated or, if that is impossible, wiped with a chat line saying so
UlSourceDB.probe = ...     -- raw probe records, only while /us probe is on; the 0.1.x data is dropped when 0.2.0 loads
```

### Still open

- **Mining, skinning and fishing** have not been seen. The `s:` rule is a plan, not a fact.
- **Fishing:** every open-water catch has the same source, the fishing bobber, so one source holds every zone and the tooltip shows only the zone fished most. A per-zone view for that one source is the fix if it bothers anyone.
- **Per-character or account-wide:** account-wide is the draft, because a node is in the same place for every character. Nothing in the model depends on it.

## Commands

`/us help` prints the list with the current state.

| Command | Description |
|---------|-------------|
| `/us` | Open or close the browser window |
| `/us <item link or ID>` | Everything known about an item: every source with count, rate, zone and last seen |
| `/us stats` | How much is known: sources, items, item-source pairs, names learned |
| `/us toggle` | Recording and tooltip lines on or off |
| `/us lines <1-10>` | Sources per tooltip (default 3) |
| `/us ids` | Show NPC and object IDs next to known names |
| `/us clear <item link or ID>` | Forget everything about one item |
| `/us clearall yes` | Forget everything |
| `/us probe` | Keep raw per-window records in `UlSourceDB.probe` for API probing (off by default) |
| `/us probestats`, `/us probelast`, `/us probereset` | Look at or forget the probe records |
| `/us errors` | Save this session's Lua errors and blocked actions to the saved variables (also done on logout and reload) |

## Probe

`/us probe` turns on the raw recorder from the 0.1.x builds: every loot window is stored in full (event arguments, every slot with its source GUIDs, position, zone, target, the last spell cast, group and instance) in `UlSourceDB.probe`, last 400 windows, with secret values written as `<secret>` and missing functions as `no <name>`. It exists so that the next unknown (mining, skinning, fishing) can be looked at in the saved variables file after a session, and costs nothing while off.

## Window

`/us` (or the UlSource row in the Ul minimap button's menu) opens the browser. Left: a search box and every item that has been looted, with how many sources it has; hovering shows the item's tooltip, with the Source lines. Right: the selected item's sources, all of them, each with its count, rate, zone, newest point and last seen; hovering a source lists every zone it was seen in with the recent points. Bottom: Recording, Show IDs and Probe as checkboxes, the tooltip line count with - and +, the stats line, and **Forget item** and **Forget all**, both behind a confirmation. Escape closes it, it can be dragged, and it refreshes itself when loot comes in while it is open.

### Minimap

UlSource has no minimap button of its own. UlRemedyForever owns the one Ul minimap button (since its 1.15.0): left-click opens its options, right-click opens a menu with one row per installed Ul addon. UlSource registers itself into that menu at `PLAYER_LOGIN`:

```lua
if UlRemedy and type(UlRemedy.Register) == "function" then
    UlRemedy.Register({ id = "UlSource", title = "UlSource", icon = ..., open = UlSource.ToggleWindow })
end
```

and nothing more. The guard means UlSource works exactly the same when UlRemedyForever is not installed: slash command only, no button.

**Dependency:** UlSource reads one global, `UlRemedy`, and only if it exists. The TOC has `## OptionalDeps: UlRemedyForever` so the load order is explicit. No shared code, no shared saved variables. The button, the menu and the registry live in UlRemedyForever and are described there.

## Development

Same loop as UlRemedyForever: package with the `package-addon` skill in dry-run mode, copy the zip to the Windows machine over scp, unpack into the Forever AddOns folder, full restart when the TOC gains files, `/reload` otherwise. Release to CurseForge only on an explicit yes.
