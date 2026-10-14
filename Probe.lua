-- Probe: records every loot window, raw, so the Forever loot API can be
-- read from the saved variables after a session. No tooltip, no database
-- yet. This file answers the open questions in README.md:
--
--   1. Does GetLootSourceInfo exist and return a GUID per slot?
--   2. What do gathering GUIDs (herbs, ore, fishing) look like?
--   3. How does skinning come through (corpse GUID plus a profession cast)?
--   4. Which fields are secret values when the loot window opens in or
--      right after combat?
--
-- Per loot window it stores: the event arguments, every slot (info, link,
-- type, sources), the player's map position, zone texts, the current
-- target, whether the client calls it fishing loot, the last spell the
-- player cast (the gathering spell that opened a node), and the last kills
-- seen in the combat log. Each read is wrapped in pcall and each value in
-- UlSource.Plain, so a secret value or a missing function is recorded as
-- such instead of breaking the window.
--
-- Kill counting is probed two ways, because the Midnight restrictions
-- Forever runs with may hide enemy data in the combat log: PARTY_KILL and
-- UNIT_DIED from COMBAT_LOG_EVENT_UNFILTERED, with a count of how many of
-- those arrived with secret GUIDs. If the combat log turns out useless, the
-- loot windows themselves (one per corpse) are the fallback denominator.

local MAX_LOOTS = 400     -- oldest records are dropped beyond this
local MAX_KILLS = 30      -- ring of recent kills kept for context
local CAST_WINDOW = 30    -- seconds; older casts are still stored, with their age

local db                  -- UlSourceDB.probe
local playerGUID
local lastCast            -- { spellID, name, at, castGUID }
local kills = {}          -- newest last
local current             -- the loot record for the open window
local lastError

local Plain = UlSource.Plain

local function Report(what, err)
    err = tostring(err)
    if err == lastError then return end
    lastError = err
    UlSource.Say("probe " .. what .. ": " .. err)
    if db then
        db.errors = db.errors or {}
        db.errors[#db.errors + 1] = { at = date("%Y-%m-%d %H:%M:%S"), what = what, err = err }
        if #db.errors > 50 then table.remove(db.errors, 1) end
    end
end

-- Calls f and returns its results, or records the error under `what`.
local function Try(what, f, ...)
    local res = { pcall(f, ...) }
    if res[1] then
        return select(2, unpack(res))
    end
    Report(what, res[2])
    return nil
end

------------------------------------------------------------------------
-- GUIDs
------------------------------------------------------------------------

-- "Creature-0-4379-0-123-299-0000A4B6C1" -> kind "Creature", id 299.
-- GameObject GUIDs carry the object ID in the same position. Players,
-- items and pets have other layouts; only the kind is read for those.
local function ParseGUID(guid)
    guid = Plain(guid)
    if type(guid) ~= "string" then return { raw = guid } end
    local parts = {}
    for part in guid:gmatch("[^-]+") do parts[#parts + 1] = part end
    local kind = parts[1]
    local rec = { raw = guid, kind = kind }
    if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" or kind == "Pet" then
        rec.id = tonumber(parts[6])
    elseif kind == "Item" then
        rec.id = tonumber(parts[3]) -- not the item ID, just the layout for inspection
    end
    return rec
end

------------------------------------------------------------------------
-- Context readers
------------------------------------------------------------------------

local function ReadPosition()
    local rec = {}
    if not C_Map then
        rec.note = "no C_Map"
        return rec
    end
    local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    rec.mapID = Plain(mapID)
    if mapID and C_Map.GetMapInfo then
        local info = C_Map.GetMapInfo(mapID)
        rec.mapName = info and Plain(info.name)
        rec.mapType = info and Plain(info.mapType)
    end
    if mapID and C_Map.GetPlayerMapPosition then
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if pos then
            local x, y = pos:GetXY()
            rec.x = Plain(x)
            rec.y = Plain(y)
        else
            rec.note = "GetPlayerMapPosition returned nil"
        end
    end
    return rec
end

local function ReadZone()
    return {
        zone = GetZoneText and Plain(GetZoneText()),
        real = GetRealZoneText and Plain(GetRealZoneText()),
        sub = GetSubZoneText and Plain(GetSubZoneText()),
        instance = GetInstanceInfo and Plain((GetInstanceInfo())),
    }
end

local function ReadUnit(unit)
    if not UnitExists or not UnitExists(unit) then return nil end
    local guid = UnitGUID and UnitGUID(unit)
    return {
        guid = ParseGUID(guid),
        name = Plain(UnitName(unit)),
        dead = Plain(UnitIsDead and UnitIsDead(unit)),
        level = Plain(UnitLevel and UnitLevel(unit)),
        creatureType = Plain(UnitCreatureType and UnitCreatureType(unit)),
    }
end

local function ReadLastCast()
    if not lastCast then return nil end
    local age = GetTime() - lastCast.at
    return {
        spellID = lastCast.spellID,
        name = lastCast.name,
        age = math.floor(age * 10) / 10,
        recent = age <= CAST_WINDOW,
    }
end

local function ReadRecentKills()
    local out = {}
    local now = GetTime()
    for i = math.max(1, #kills - 4), #kills do
        local k = kills[i]
        if k then
            out[#out + 1] = { event = k.event, guid = k.guid, name = k.name, age = math.floor((now - k.at) * 10) / 10 }
        end
    end
    return out
end

------------------------------------------------------------------------
-- Loot slots
------------------------------------------------------------------------

local function ReadSources(slot)
    if not GetLootSourceInfo then return { note = "no GetLootSourceInfo" } end
    local res = { pcall(GetLootSourceInfo, slot) }
    if not res[1] then return { error = tostring(res[2]) } end
    local list = {}
    for i = 2, #res, 2 do
        list[#list + 1] = { guid = ParseGUID(res[i]), quantity = Plain(res[i + 1]) }
    end
    if #list == 0 then list.note = "returned nothing" end
    return list
end

local function ReadSlot(slot)
    local rec = { slot = slot }
    if GetLootSlotInfo then
        local res = { pcall(GetLootSlotInfo, slot) }
        if res[1] then
            rec.icon = Plain(res[2])
            rec.name = Plain(res[3])
            rec.quantity = Plain(res[4])
            rec.currencyID = Plain(res[5])
            rec.quality = Plain(res[6])
            rec.locked = Plain(res[7])
            rec.isQuestItem = Plain(res[8])
            rec.questID = Plain(res[9])
            rec.isActive = Plain(res[10])
        else
            rec.infoError = tostring(res[2])
        end
    else
        rec.infoError = "no GetLootSlotInfo"
    end
    if GetLootSlotLink then
        local ok, link = pcall(GetLootSlotLink, slot)
        rec.link = ok and Plain(link) or ("error: " .. tostring(link))
        if ok and type(link) == "string" then
            rec.itemID = tonumber(link:match("item:(%d+)"))
        end
    end
    if GetLootSlotType then
        local ok, kind = pcall(GetLootSlotType, slot)
        rec.slotType = ok and Plain(kind) or ("error: " .. tostring(kind))
    end
    rec.sources = ReadSources(slot)
    return rec
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local function OnLootOpened(autoLoot, isFromItem)
    local rec = {
        n = (db.count or 0) + 1,
        at = date("%Y-%m-%d %H:%M:%S"),
        autoLoot = Plain(autoLoot),
        isFromItem = Plain(isFromItem),
        inCombat = Plain(InCombatLockdown and InCombatLockdown()),
        fishing = "no IsFishingLoot",
        numItems = "no GetNumLootItems",
        position = Try("position", ReadPosition),
        zone = Try("zone", ReadZone),
        target = Try("target", ReadUnit, "target"),
        lastCast = ReadLastCast(),
        recentKills = ReadRecentKills(),
        slots = {},
        taken = {},
    }
    if IsFishingLoot then rec.fishing = Plain(Try("IsFishingLoot", IsFishingLoot)) end
    if GetNumLootItems then rec.numItems = Plain(Try("GetNumLootItems", GetNumLootItems)) end
    local n = tonumber(rec.numItems) or 0
    for slot = 1, n do
        rec.slots[slot] = Try("slot " .. slot, ReadSlot, slot) or { slot = slot, error = "unreadable" }
    end

    db.count = rec.n
    db.loots[#db.loots + 1] = rec
    while #db.loots > MAX_LOOTS do
        table.remove(db.loots, 1)
        db.dropped = (db.dropped or 0) + 1
    end
    current = rec

    if not UlSource.db.settings.quiet then
        local first = rec.slots[1]
        local src = first and first.sources and first.sources[1] and first.sources[1].guid
        local where = (src and src.kind) and (src.kind .. " " .. tostring(src.id or "?")) or "no source GUID"
        local who = rec.target and rec.target.name and (" (" .. tostring(rec.target.name) .. ")") or ""
        local pos = rec.position or {}
        local xy = (type(pos.x) == "number" and type(pos.y) == "number")
            and string.format(" %.1f,%.1f", pos.x * 100, pos.y * 100) or ""
        UlSource.Say("loot #" .. rec.n .. ": " .. n .. " slot(s), " .. where .. who
            .. ", " .. tostring(pos.mapName or "?") .. xy
            .. (rec.lastCast and rec.lastCast.recent and (", after " .. tostring(rec.lastCast.name)) or ""))
    end
end

local function OnLootSlotCleared(slot)
    if current then
        current.taken[#current.taken + 1] = { slot = Plain(slot), at = date("%H:%M:%S") }
    end
end

local function OnLootClosed()
    if current then
        current.closedAt = date("%H:%M:%S")
        current = nil
    end
end

local function OnSpellcast(unit, castGUID, spellID)
    if unit ~= "player" then return end
    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        name = info and info.name
    elseif GetSpellInfo then
        name = GetSpellInfo(spellID)
    end
    lastCast = { spellID = Plain(spellID), name = Plain(name), at = GetTime(), castGUID = Plain(castGUID) }
end

local function OnCombatLog()
    if not CombatLogGetCurrentEventInfo then
        db.combatLog.note = "no CombatLogGetCurrentEventInfo"
        return
    end
    local _, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
    if issecretvalue and issecretvalue(subevent) then
        db.combatLog.secretSubevents = (db.combatLog.secretSubevents or 0) + 1
        return
    end
    if subevent ~= "PARTY_KILL" and subevent ~= "UNIT_DIED" then return end
    local c = db.combatLog
    c[subevent] = (c[subevent] or 0) + 1
    local secret = issecretvalue and (issecretvalue(destGUID) or issecretvalue(destName))
    if secret then c.secretDest = (c.secretDest or 0) + 1 end
    if subevent == "PARTY_KILL" then
        local mine = (not (issecretvalue and issecretvalue(sourceGUID))) and sourceGUID == playerGUID
        if mine then c.myKills = (c.myKills or 0) + 1 end
    end
    kills[#kills + 1] = { event = subevent, guid = ParseGUID(destGUID), name = Plain(destName), at = GetTime() }
    while #kills > MAX_KILLS do table.remove(kills, 1) end
end

------------------------------------------------------------------------
-- API inventory, written once per login so the file says what exists
------------------------------------------------------------------------

local API_NAMES = {
    "GetLootSourceInfo", "GetLootSlotInfo", "GetLootSlotLink", "GetLootSlotType",
    "GetNumLootItems", "IsFishingLoot", "LootSlotHasItem", "GetLootInfo",
    "CombatLogGetCurrentEventInfo", "UnitGUID", "UnitCreatureType",
    "C_Map.GetBestMapForUnit", "C_Map.GetPlayerMapPosition", "C_Map.GetMapInfo",
    "C_Spell.GetSpellInfo", "GetSpellInfo", "C_Item.GetItemInfo", "GetItemInfo",
    "C_LootHistory.GetNumItems", "TooltipDataProcessor.AddTooltipPostCall",
    "issecretvalue", "canaccessvalue",
}

local function Resolve(path)
    local v = _G
    for part in path:gmatch("[^.]+") do
        if type(v) ~= "table" then return nil end
        v = v[part]
    end
    return v
end

local function InventoryAPI()
    local out = {}
    for _, name in ipairs(API_NAMES) do
        out[name] = type(Resolve(name))
    end
    return out
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------

function UlSource.ProbeSummary()
    if not db then return end
    UlSource.Say("probe: " .. #db.loots .. " loot windows stored (" .. (db.count or 0) .. " seen, "
        .. (db.dropped or 0) .. " dropped), " .. #(db.errors or {}) .. " probe errors.")
    local c = db.combatLog
    print("  combat log: PARTY_KILL " .. (c.PARTY_KILL or 0) .. " (mine " .. (c.myKills or 0) .. "), UNIT_DIED "
        .. (c.UNIT_DIED or 0) .. ", with secret target " .. (c.secretDest or 0)
        .. ", secret subevents " .. (c.secretSubevents or 0) .. (c.note and (", " .. c.note) or ""))
    local missing = {}
    for name, kind in pairs(db.api or {}) do
        if kind == "nil" then missing[#missing + 1] = name end
    end
    table.sort(missing)
    print("  missing API: " .. (#missing > 0 and table.concat(missing, ", ") or "none of the probed names"))
    local withSource, withoutSource = 0, 0
    for _, rec in ipairs(db.loots) do
        local s = rec.slots[1] and rec.slots[1].sources
        if s and s[1] and s[1].guid and s[1].guid.kind then withSource = withSource + 1 else withoutSource = withoutSource + 1 end
    end
    print("  loot windows with a source GUID on slot 1: " .. withSource .. ", without: " .. withoutSource)
    if lastError then print("  last probe error: " .. lastError) end
end

local function PrintTable(t, indent, depth)
    if depth > 4 then print(indent .. "...") return end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" then
            print(indent .. tostring(k) .. ":")
            PrintTable(v, indent .. "  ", depth + 1)
        else
            print(indent .. tostring(k) .. " = " .. tostring(v))
        end
    end
end

function UlSource.ProbePrintLast()
    if not db then return end
    local rec = db.loots[#db.loots]
    if not rec then
        UlSource.Say("no loot window recorded yet.")
        return
    end
    UlSource.Say("last loot window (#" .. rec.n .. ", " .. rec.at .. "):")
    PrintTable(rec, "  ", 0)
end

function UlSource.ProbeReset()
    if not db then return end
    wipe(db.loots)
    wipe(db.combatLog)
    db.errors = nil
    db.count = 0
    db.dropped = 0
    wipe(kills)
    UlSource.Say("probe data forgotten.")
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

function UlSource.ProbeInit()
    UlSource.db.probe = UlSource.db.probe or {}
    db = UlSource.db.probe
    db.loots = db.loots or {}
    db.combatLog = db.combatLog or {}
    db.count = db.count or 0
    db.version = UlSource.Version()
    db.api = Try("api inventory", InventoryAPI)
    db.build = Plain(GetBuildInfo and select(2, GetBuildInfo()))
end

local frame = CreateFrame("Frame", "UlSourceProbeFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_SLOT_CLEARED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
if not pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player") then
    frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID and UnitGUID("player")
        return
    end
    if not db then return end   -- ADDON_LOADED has not run yet
    if event == "LOOT_OPENED" then
        Try("LOOT_OPENED", OnLootOpened, ...)
    elseif event == "LOOT_SLOT_CLEARED" then
        Try("LOOT_SLOT_CLEARED", OnLootSlotCleared, ...)
    elseif event == "LOOT_CLOSED" then
        Try("LOOT_CLOSED", OnLootClosed)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        Try("UNIT_SPELLCAST_SUCCEEDED", OnSpellcast, ...)
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local ok, err = pcall(OnCombatLog)
        if not ok then
            db.combatLog.errors = (db.combatLog.errors or 0) + 1
            db.combatLog.lastError = tostring(err)
        end
    end
end)
