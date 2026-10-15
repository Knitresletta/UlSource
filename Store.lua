-- Store: the database. One SavedVariables table, UlSourceDB, account-wide.
-- The shape is described in README.md under "Data model". In short:
--
--   db.sources[key]  one entry per thing that was looted: "c:4436" (a
--                    creature's drops), "o:1621" (a node or chest),
--                    "s:4511" (a skinned corpse). Windows opened, last
--                    time, and per zone a count and a few recent points.
--   db.items[id]     one entry per item: its name and, per source key,
--                    how many windows it appeared in and the total amount.
--   db.names.c/.o    names learned in play, by NPC or object ID. They win
--                    over the shipped NameData.lua table.
--
-- Nothing is stored per loot. The drop rate of an item from a source is
-- items[id].sources[key].n / sources[key].windows, both counted from the
-- same windows. Only this file writes to the database; the collector and
-- the name learner hand it records, the tooltip reads from it.

local DB_VERSION = 1
local POINTS_PER_ZONE = 5

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
end

------------------------------------------------------------------------
-- Writing
------------------------------------------------------------------------

local function Round4(v)
    return math.floor(v * 10000 + 0.5) / 10000
end

-- sources: { [key] = { kind, id, name?, items = { [itemID] = { name, qty } } } }
-- ctx:     { zone, x?, y? }
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
        if src.name then Store.LearnName(src.kind, src.id, src.name) end

        if ctx.zone then
            local z = s.zones[ctx.zone]
            if not z then
                z = { n = 0, points = {} }
                s.zones[ctx.zone] = z
            end
            z.n = z.n + 1
            if ctx.x and ctx.y then
                table.insert(z.points, 1, { Round4(ctx.x), Round4(ctx.y), now })
                while #z.points > POINTS_PER_ZONE do table.remove(z.points) end
            end
        end

        for itemID, it in pairs(src.items) do
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
    local shipped = (kind == "o") and UlSource.ObjectNames or UlSource.NPCNames
    if shipped and shipped[id] == name then return false end   -- the table has it already
    bucket[id] = name
    return true
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
    if bucket[id] then return bucket[id] end
    local shipped = (kind == "o") and UlSource.ObjectNames or UlSource.NPCNames
    return shipped and shipped[id] or nil
end

-- Does this creature need a name? Used by the learner to stay cheap.
function Store.WantsName(kind, id)
    if not db then return false end
    local bucket = (kind == "o") and db.names.o or db.names.c
    if bucket[id] then return false end
    local shipped = (kind == "o") and UlSource.ObjectNames or UlSource.NPCNames
    if shipped and shipped[id] then return false end
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

-- Sorted list of what is known about an item, best source first:
-- { key, kind, id, name, n, qty, windows, last, zone, x, y }
function Store.ItemSources(itemID)
    local item = db and db.items[itemID]
    if not item then return nil end
    local list = {}
    for key, p in pairs(item.sources) do
        local s = db.sources[key]
        local kind, id = Store.ParseKey(key)
        local zone, x, y
        if s then zone, x, y = BestZone(s) end
        list[#list + 1] = {
            key = key, kind = kind, id = id, name = Store.SourceName(key),
            n = p.n, qty = p.qty, windows = s and s.windows or p.n, last = p.last,
            zone = zone, x = x, y = y,
        }
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return (a.last or 0) > (b.last or 0)
    end)
    return list, item.name
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
