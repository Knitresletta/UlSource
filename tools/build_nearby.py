#!/usr/bin/env python3
"""Build NearbyData.lua: class trainers and reagent/ammo vendors with positions.

Nearby.lua answers "where is the nearest class trainer" and "where is the
nearest vendor with my class reagents" (hunters: ammo) from where the player
stands. The positions are server data, not in the client files, so the
table is built from the same server database as NameData.lua:

  --vmangos DB   The vmangos world database as SQLite (mangos.sqlite from
                 the db-sqlite-*.zip on the vmangos/core GitHub release
                 tagged db_latest). Vanilla 1.12. Forever may have moved or
                 added NPCs; Nearby.lua learns those on a visit and the
                 learned position wins.

Usage:
    python3 -I tools/build_nearby.py --vmangos /path/mangos.sqlite -o NearbyData.lua

Trainers: creature_template rows with trainer_type 0 (class trainer) and a
trainer_class, one row per spawn point on the two continents (map 0 Eastern
Kingdoms, map 1 Kalimdor). Vendors: every creature whose npc_vendor list
holds a class reagent (the vendor-sold items consumed by class spells) or
arrows and bullets, again one row per spawn. Faction from the faction
table's team (469 Alliance, 67 Horde), with the few team-less city factions
named below; everything else is neutral. World coordinates as the client's
C_Map.GetWorldPosFromMapPos gives them: x grows northwards, y westwards.
"""

import argparse
import datetime
import math
import sqlite3
import sys

CLASS_BY_TRAINER_CLASS = {
    1: "WARRIOR", 2: "PALADIN", 3: "HUNTER", 4: "ROGUE", 5: "PRIEST",
    7: "SHAMAN", 8: "MAGE", 9: "WARLOCK", 11: "DRUID",
}

# Vendor-sold items that class spells consume (spell_template reagent
# columns, checked 17.10.2026). Campfire wood and wand reagents are left out.
REAGENT_CLASS = {
    5140: "ROGUE",     # Flash Powder (Vanish)
    5565: "WARLOCK",   # Infernal Stone
    16583: "WARLOCK",  # Demonic Figurine
    17020: "MAGE",     # Arcane Powder
    17031: "MAGE",     # Rune of Teleportation
    17032: "MAGE",     # Rune of Portals
    17021: "DRUID",    # Wild Berries
    17026: "DRUID",    # Wild Thornroot
    17034: "DRUID",    # Maple Seed
    17035: "DRUID",    # Stranglethorn Seed
    17036: "DRUID",    # Ashwood Seed
    17037: "DRUID",    # Hornbeam Seed
    17038: "DRUID",    # Ironwood Seed
    17028: "PRIEST",   # Holy Candle
    17029: "PRIEST",   # Sacred Candle
    17030: "SHAMAN",   # Ankh
    17033: "PALADIN",  # Symbol of Divinity
    21177: "PALADIN",  # Symbol of Kings
}

AMMO_CLASS, ARROW, BULLET = 6, 2, 3

ALLIANCE_FACTIONS = {"Stormwind", "Darnassus", "Ironforge", "Gnomeregan Exiles",
                     "Human, Theramore", "Alliance Generic", "Stormpike Guard", "Wildhammer Clan"}
HORDE_FACTIONS = {"Orgrimmar", "Undercity", "Thunder Bluff", "Darkspear Trolls",
                  "Frostwolf Clan", "Revantusk Trolls"}

CONTINENTS = (0, 1)
SAME_SPOT_YARDS = 50


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def faction_letter(team, name):
    if team == 469 or name in ALLIANCE_FACTIONS:
        return "A"
    if team == 67 or name in HORDE_FACTIONS:
        return "H"
    return "N"


def read_templates(conn, where):
    """entry -> (name, faction letter, trainer_class). Newest patch row wins."""
    out = {}
    rows = conn.execute(f"""
        select t.entry, t.patch, t.name, t.trainer_class, fa.team, fa.name
        from creature_template t
        left join faction_template f on f.id = t.faction
        left join faction fa on fa.id = f.faction_id
        where {where}
        order by t.entry, t.patch""")
    for entry, _patch, name, trainer_class, team, fname in rows:
        out[entry] = (name.strip(), faction_letter(team, fname or ""), trainer_class)
    return out


def read_spawns(conn, entries):
    """entry -> list of (continent, x, y), nearby duplicates folded."""
    spawns = {e: [] for e in entries}
    rows = conn.execute("""
        select id, id2, id3, id4, id5, map, position_x, position_y
        from creature where map in (0, 1)""")
    for id1, id2, id3, id4, id5, cont, x, y in rows:
        for e in (id1, id2, id3, id4, id5):
            if e in spawns:
                pts = spawns[e]
                if not any(c == cont and math.hypot(px - x, py - y) < SAME_SPOT_YARDS for c, px, py in pts):
                    pts.append((cont, round(x, 1), round(y, 1)))
    return spawns


def read_items(conn):
    reagents = {}
    for entry, name in conn.execute(
            "select entry, name from item_template where entry in (%s) group by entry"
            % ",".join(str(i) for i in REAGENT_CLASS)):
        reagents[entry] = (REAGENT_CLASS[entry], name.strip())
    ammo = {}
    for entry, name, sub, lvl in conn.execute("""
            select entry, name, subclass, required_level from item_template
            where class = ? and subclass in (?, ?) group by entry""", (AMMO_CLASS, ARROW, BULLET)):
        ammo[entry] = (sub, lvl, name.strip())
    return reagents, ammo


def read_vendor_items(conn, wanted):
    """vendor entry -> sorted list of wanted item IDs it sells."""
    out = {}
    for entry, item in conn.execute("select entry, item from npc_vendor"):
        if item in wanted:
            out.setdefault(entry, set()).add(item)
    return {e: sorted(items) for e, items in out.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vmangos", required=True, help="path to mangos.sqlite")
    ap.add_argument("-o", "--output", default="NearbyData.lua")
    args = ap.parse_args()
    conn = sqlite3.connect(f"file:{args.vmangos}?mode=ro", uri=True)

    reagents, ammo = read_items(conn)
    vendor_items = read_vendor_items(conn, set(reagents) | set(ammo))

    trainers = read_templates(conn, "t.trainer_type = 0 and t.trainer_class in (%s)"
                              % ",".join(str(c) for c in CLASS_BY_TRAINER_CLASS))
    # Everything that opens a trainer window without being a class trainer:
    # trainer types 1 to 3 (mounts, tradeskills and weapon masters, pets) and
    # every NPC with the trainer flag (npc_flags bit 16) outside the class set.
    other_trainers = read_templates(conn, "t.trainer_type in (1, 2, 3) or ((t.npc_flags & 16) "
                                          "and not (t.trainer_type = 0 and t.trainer_class > 0))")
    vendors = read_templates(conn, "t.entry in (%s)" % ",".join(str(e) for e in vendor_items))
    spawns = read_spawns(conn, set(trainers) | set(vendors))

    trainer_rows, vendor_rows = [], []
    for entry, (name, faction, tclass) in sorted(trainers.items()):
        for cont, x, y in spawns[entry]:
            trainer_rows.append((entry, name, CLASS_BY_TRAINER_CLASS[tclass], faction, cont, x, y))
    for entry, (name, faction, _) in sorted(vendors.items()):
        for cont, x, y in spawns[entry]:
            vendor_rows.append((entry, name, faction, cont, x, y, vendor_items[entry]))

    today = datetime.date.today().isoformat()
    with open(args.output, "w", encoding="utf-8") as out:
        out.write("-- Generated by tools/build_nearby.py on %s, do not edit by hand.\n" % today)
        out.write("-- Source: vmangos world database (vanilla 1.12). Positions are world\n"
                  "-- coordinates (x north, y west) on continent 0 (Eastern Kingdoms) or\n"
                  "-- 1 (Kalimdor). Forever may differ; Nearby.lua learns visited NPCs.\n\n")
        out.write("UlSource.NearbyData = {\n")
        out.write("-- class reagents sold by vendors: itemID -> { class, name }\n")
        out.write("reagents = {\n")
        for item in sorted(reagents):
            cls, name = reagents[item]
            out.write("[%d]={%s,%s},\n" % (item, lua_string(cls), lua_string(name)))
        out.write("},\n")
        out.write("-- ammo: itemID -> { subclass (2 arrow, 3 bullet), required level, name }\n")
        out.write("ammo = {\n")
        for item in sorted(ammo):
            sub, lvl, name = ammo[item]
            out.write("[%d]={%d,%d,%s},\n" % (item, sub, lvl, lua_string(name)))
        out.write("},\n")
        out.write("-- class trainers, one row per spawn: { npcID, name, class, faction, continent, x, y }\n")
        out.write("trainers = {\n")
        for entry, name, cls, faction, cont, x, y in trainer_rows:
            out.write("{%d,%s,%s,%s,%d,%s,%s},\n" % (entry, lua_string(name), lua_string(cls),
                                                    lua_string(faction), cont, x, y))
        out.write("},\n")
        out.write("-- vendors with reagents or ammo, one row per spawn: { npcID, name, faction, continent, x, y, { itemIDs } }\n")
        out.write("vendors = {\n")
        for entry, name, faction, cont, x, y, items in vendor_rows:
            out.write("{%d,%s,%s,%d,%s,%s,{%s}},\n" % (entry, lua_string(name), lua_string(faction), cont, x, y,
                                                      ",".join(str(i) for i in items)))
        out.write("},\n")
        out.write("-- trainers that are not class trainers (mounts, weapon masters and professions, pets),\n"
                  "-- so a visit to one is never learned as a class trainer\n")
        out.write("notClassTrainers = {\n")
        for entry in sorted(other_trainers):
            out.write("[%d]=true,\n" % entry)
        out.write("},\n")
        out.write("}\n")

    print("trainers: %d NPCs, %d spawns; vendors: %d NPCs, %d spawns; %d reagents, %d ammo; %d other trainers excluded"
          % (len(trainers), len(trainer_rows), len(vendors), len(vendor_rows), len(reagents), len(ammo),
             len(other_trainers)), file=sys.stderr)


if __name__ == "__main__":
    main()
