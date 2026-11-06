-- Store: the database. One SavedVariables table, UlSourceDB, account-wide.
-- The shape is described in README.md under "Data model". In short:
--
--   db.sources[key]  one entry per thing that was looted: "c:4436" (a
--                    creature's drops), "o:1621" (a node or chest),
--                    "s:4511" (a skinned corpse). Windows opened, last
--                    time, and per zone a count and a few recent points.
--   db.items[id]     one entry per item: its name and, per source key,
--                    how many windows it appeared in and the total amount.
--   db.names.c/.o    names learned in play, by NPC or object ID. The only
--                    names there are (no shipped table since 0.8.0: Forever
--                    sources only, and no Forever source has NPC names).
--   db.nearby[npcID] class trainers and reagent vendors visited, with the
--                    position seen. They win over NearbyData.lua.
--
-- Nothing is stored per loot. The drop rate of an item from a source is
-- items[id].sources[key].n / sources[key].windows, both counted from the
-- same windows. Only this file writes to the database; the collector and
-- the name learner hand it records, the tooltip reads from it.

local DB_VERSION = 1
local POINTS_PER_ZONE = 5          -- creatures roam; a few recent points are enough
local NODE_POINTS_PER_ZONE = 40    -- objects stand still; every distinct spawn is worth keeping
local SAME_SPOT = 0.005            -- map fraction; closer than this is the same spawn

local db

local Store = {}
UlSource.Store = Store

------------------------------------------------------------------------
-- Keys
------------------------------------------------------------------------

function Store.Key(kind, id)
    return kind .. ":" .. tostring(id)
end

-- "c:4436" -> "c", 4436
function Store.ParseKey(key)
    local kind, id = key:match("^(%a):(%d+)$")
    return kind, tonumber(id)
end

function Store.ParseKeyID(key)
    local _, id = Store.ParseKey(key)
    return id
end

------------------------------------------------------------------------
-- Init and migration
------------------------------------------------------------------------

function Store.Init()
    db = UlSource.db
    if db.version == nil then
        -- First install, or a 0.1.x file (probe data only). Nothing to carry over.
        db.version = DB_VERSION
    elseif db.version ~= DB_VERSION then
        -- No older shape exists yet. When one does, migrate here; wipe only
        -- as a last resort, and say so.
        UlSource.Say("database version " .. tostring(db.version) .. " is unknown to " .. UlSource.Version()
            .. "; starting a fresh database.")
        db.sources, db.items, db.names = nil, nil, nil
        db.version = DB_VERSION
    end
    db.sources = db.sources or {}
    db.items = db.items or {}
    db.names = db.names or {}
    db.names.c = db.names.c or {}
    db.names.o = db.names.o or {}
    db.unattributed = db.unattributed or 0
    db.nearby = db.nearby or {}
end

------------------------------------------------------------------------
-- Writing
------------------------------------------------------------------------

local function Round4(v)
    return math.floor(v * 10000 + 0.5) / 10000
end

-- sources: { [key] = { kind, id, name?, items = { [itemID] = { name, qty } } } }
-- ctx:     { zone, mapID?, x?, y? }  (x, y are fractions of the map mapID)
-- One call per loot window. Every source in the table gets one window.
function Store.RecordWindow(sources, ctx)
    if not db then return end
    local now = time()
    for key, src in pairs(sources) do
        local s = db.sources[key]
        if not s then
            s = { kind = src.kind, id = src.id, windows = 0, zones = {} }
            db.sources[key] = s
        end
        s.windows = s.windows + 1
        s.last = now
        if src.fishing then s.fishing = true end
        if src.name then Store.LearnName(src.kind, src.id, src.name) end

        if ctx.zone then
            local z = s.zones[ctx.zone]
            if not z then
                z = { n = 0, points = {} }
                s.zones[ctx.zone] = z
            end
            z.n = z.n + 1
            if ctx.x and ctx.y then
                z.mapID = ctx.mapID or z.mapID
                local x, y = Round4(ctx.x), Round4(ctx.y)
                local found
                if s.kind == "o" then
                    for i, pt in ipairs(z.points) do
                        if math.abs(pt[1] - x) <= SAME_SPOT and math.abs(pt[2] - y) <= SAME_SPOT then
                            found = i
                            break
                        end
                    end
                end
                if found then
                    local pt = table.remove(z.points, found)
                    pt[3] = now
                    table.insert(z.points, 1, pt)
                else
                    table.insert(z.points, 1, { x, y, now })
                    local cap = (s.kind == "o") and NODE_POINTS_PER_ZONE or POINTS_PER_ZONE
                    while #z.points > cap do table.remove(z.points) end
                end
            end
        end

        local bestQty = -1
        for itemID, it in pairs(src.items) do
            if (it.qty or 0) > bestQty then
                bestQty = it.qty or 0
                s.lastItem = itemID
            end
            local item = db.items[itemID]
            if not item then
                item = { sources = {} }
                db.items[itemID] = item
            end
            item.name = it.name or item.name
            local p = item.sources[key]
            if not p then
                p = { n = 0, qty = 0 }
                item.sources[key] = p
            end
            p.n = p.n + 1
            p.qty = p.qty + (it.qty or 1)
            p.last = now
        end
    end
    if UlSource.OnDataChanged then UlSource.OnDataChanged() end
end

-- Every zone a source was seen in, most seen first: { name, n, points }.
function Store.SourceZones(key)
    local s = db and db.sources[key]
    if not s then return nil end
    local list = {}
    for name, z in pairs(s.zones or {}) do
        list[#list + 1] = { name = name, n = z.n, points = z.points or {} }
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    return list
end

function Store.NoteUnattributed()
    if db then db.unattributed = (db.unattributed or 0) + 1 end
end

-- kind "c" or "s" are both creatures; "o" is an object.
function Store.LearnName(kind, id, name)
    if not db or not id or not name or name == "" then return false end
    local bucket = (kind == "o") and db.names.o or db.names.c
    if bucket[id] == name then return false end
    bucket[id] = name
    return true
end

-- A visited class trainer or reagent vendor, by NPC ID (Nearby.lua):
-- { kind = "t"|"v", name, class?, items?, faction?, seenBy, continent, x, y, last }.
-- faction is the shipped table's ("A", "H", "N") or nil for an unknown NPC;
-- seenBy holds the player factions that have opened its window.
-- Overwrites: the newest visit is the truth about where the NPC stands.
function Store.RecordNearby(npcID, rec)
    if not db or not npcID or not rec then return end
    rec.last = time()
    db.nearby[npcID] = rec
end

function Store.NearbyEntries()
    return db and db.nearby or {}
end

-- Drop learned entries the predicate accepts; returns how many.
function Store.ForgetNearbyWhere(pred)
    if not db then return 0 end
    local n = 0
    for id, e in pairs(db.nearby) do
        if pred(id, e) then db.nearby[id] = nil; n = n + 1 end
    end
    return n
end

function Store.ClearNearby()
    if not db then return 0 end
    local n = 0
    for _ in pairs(db.nearby) do n = n + 1 end
    wipe(db.nearby)
    return n
end

function Store.ClearItem(itemID)
    if not db or not db.items[itemID] then return false end
    db.items[itemID] = nil
    return true
end

function Store.ClearAll()
    if not db then return end
    wipe(db.sources)
    wipe(db.items)
    wipe(db.names.c)
    wipe(db.names.o)
    wipe(db.nearby)
    db.unattributed = 0
end

------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------

-- The display name for a source key, or nil when nothing knows it.
function Store.SourceName(key)
    local kind, id = Store.ParseKey(key)
    if not kind then return nil end
    local bucket = (kind == "o") and db.names.o or db.names.c
    return bucket[id]
end

-- Does this creature need a name? Used by the learner to stay cheap.
function Store.WantsName(kind, id)
    if not db then return false end
    local bucket = (kind == "o") and db.names.o or db.names.c
    if bucket[id] then return false end
    if kind == "o" then return db.sources[Store.Key("o", id)] ~= nil end
    return db.sources[Store.Key("c", id)] ~= nil or db.sources[Store.Key("s", id)] ~= nil
end

-- The zone a source was seen most in, and the newest point there.
local function BestZone(s)
    local bestName, best
    for name, z in pairs(s.zones or {}) do
        if not best or z.n > best.n then bestName, best = name, z end
    end
    if not best then return nil end
    local pt = best.points[1]
    return bestName, pt and pt[1], pt and pt[2]
end

-- How sure the drop rate n/windows is: the lower end of a 95% Wilson
-- interval. A plain rate would put a source seen once with the item once
-- (1/1, "100%") above one seen a hundred times with the item in thirty
-- (30/100). Weighed by how little is known, 1/1 scores 0.21, 30/100
-- scores 0.22 and 3/3 scores 0.44, so a well-sampled rate wins over a
-- lucky first window but a run of hits still climbs fast.
local function RateScore(n, windows)
    if not windows or windows <= 0 then return 0 end
    local z = 1.96
    local p = n / windows
    local denom = 1 + z * z / windows
    local centre = p + z * z / (2 * windows)
    local spread = z * math.sqrt((p * (1 - p) + z * z / (4 * windows)) / windows)
    return (centre - spread) / denom
end

-- Sorted list of what is known about an item, best source first: the
-- highest drop rate (see RateScore), then the plain rate, then the most
-- windows, then the newest sighting.
-- { key, kind, id, name, n, qty, windows, last, zone, x, y }
-- Only sources with a name: a drop source whose creature has no name yet
-- is not worth showing (Jonatan, 07.11.2026). It keeps counting, and
-- shows up the moment the name is learned.
function Store.ItemSources(itemID)
    local item = db and db.items[itemID]
    if not item then return nil end
    local list = {}
    for key, p in pairs(item.sources) do
        local s = db.sources[key]
        local kind, id = Store.ParseKey(key)
        local name = Store.SourceName(key)
        local zone, x, y
        if s then zone, x, y = BestZone(s) end
        if name then
            list[#list + 1] = {
                key = key, kind = kind, id = id, name = name,
                n = p.n, qty = p.qty, windows = s and s.windows or p.n, last = p.last,
                zone = zone, x = x, y = y,
            }
        end
    end
    for _, src in ipairs(list) do
        src.score = RateScore(src.n, src.windows)
        src.rate = src.windows > 0 and src.n / src.windows or 0
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.rate ~= b.rate then return a.rate > b.rate end
        if a.n ~= b.n then return a.n > b.n end
        return (a.last or 0) > (b.last or 0)
    end)
    return list, item.name
end

-- Zone entries written before 0.4.0 have no map ID. Build name -> map ID
-- once from the map tree and fill them in. Idempotent and cheap.
local mapIDsResolved = false
function Store.ResolveMapIDs()
    if mapIDsResolved or not db or not C_Map or not C_Map.GetMapChildrenInfo then return end
    mapIDsResolved = true
    local byName = {}
    for _, root in ipairs({ 946, 947 }) do
        local ok, children = pcall(C_Map.GetMapChildrenInfo, root, nil, true)
        if ok and type(children) == "table" then
            for _, info in ipairs(children) do
                local name = UlSource.Plain(info.name)
                if type(name) == "string" and byName[name] == nil then byName[name] = info.mapID end
            end
        end
    end
    for _, s in pairs(db.sources) do
        for zoneName, z in pairs(s.zones or {}) do
            if z.mapID == nil and byName[zoneName] then z.mapID = byName[zoneName] end
        end
    end
end

-- Every point of every object source taken on this map:
-- { x, y, key, itemID, fishing }, newest first within a source.
function Store.PinsForMap(mapID)
    local list = {}
    if not db or not mapID then return list end
    Store.ResolveMapIDs()
    for key, s in pairs(db.sources) do
        if s.kind == "o" then
            for _, z in pairs(s.zones or {}) do
                if z.mapID == mapID then
                    for _, pt in ipairs(z.points or {}) do
                        list[#list + 1] = { x = pt[1], y = pt[2], key = key, itemID = s.lastItem, fishing = s.fishing }
                    end
                end
            end
        end
    end
    return list
end

function Store.Stats()
    if not db then return nil end
    local sources, items, pairsN, named = 0, 0, 0, 0
    for key in pairs(db.sources) do
        sources = sources + 1
        if Store.SourceName(key) then named = named + 1 end
    end
    for _, item in pairs(db.items) do
        items = items + 1
        for _ in pairs(item.sources) do pairsN = pairsN + 1 end
    end
    local learned = 0
    for _ in pairs(db.names.c) do learned = learned + 1 end
    for _ in pairs(db.names.o) do learned = learned + 1 end
    return { sources = sources, named = named, items = items, pairs = pairsN, learned = learned,
             unattributed = db.unattributed or 0 }
end
