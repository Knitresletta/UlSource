-- Nearby: "/us trainer" and "/us reagents". From where the player stands,
-- the nearest class trainer, and the nearest vendor that sells this
-- class's spell reagents (hunters: ammo for the equipped ranged weapon).
--
-- Positions come from NearbyData.lua (vmangos 1.12, built by
-- tools/build_nearby.py) in world coordinates, and from NPCs this account
-- has visited: a trainer window or a merchant window with a reagent or
-- ammo in it stores the NPC under UlSourceDB.nearby with the player's
-- position at that moment. A learned entry wins over the shipped rows for
-- the same NPC, so an NPC Forever has moved is right after one visit, and
-- a Forever-new one exists after one visit.
--
-- The player's world position is C_Map.GetWorldPosFromMapPos of the map
-- position, the same API UlRemedyForever's flight paths rely on. Inside
-- instances the map ID is a secret value and the commands say so. The
-- answer names the zone by projecting the point back onto the continent
-- map (C_Map.GetMapInfoAtPosition) and gives zone coordinates, distance
-- in yards and a compass direction. Reads only: nothing is bought or
-- trained here.

local Plain = UlSource.Plain
local Store = UlSource.Store

local RANGED_SLOT = 18
local WEAPON_CLASS, BOW, GUN, CROSSBOW = 2, 2, 3, 18
local ARROW, BULLET = 2, 3

local CLASS_NAMES = {
    WARRIOR = "warrior", PALADIN = "paladin", HUNTER = "hunter", ROGUE = "rogue", PRIEST = "priest",
    SHAMAN = "shaman", MAGE = "mage", WARLOCK = "warlock", DRUID = "druid",
}

local function Data() return UlSource.NearbyData end

------------------------------------------------------------------------
-- Who and where the player is
------------------------------------------------------------------------

local function PlayerClass()
    local _, token = UnitClass("player")
    token = Plain(token)
    return type(token) == "string" and token or nil
end

-- "A", "H" or nil.
local function PlayerFaction()
    local f = Plain(UnitFactionGroup("player"))
    if f == "Alliance" then return "A" elseif f == "Horde" then return "H" end
    return nil
end

local function PlayerMapID()
    if not C_Map or not C_Map.GetBestMapForUnit then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if type(mapID) ~= "number" or (issecretvalue and issecretvalue(mapID)) then return nil end
    return mapID
end

-- continentID, x, y, mapID of the player, or nil when the position is not
-- readable (instances, loading screens).
local function PlayerWorld()
    local mapID = PlayerMapID()
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local continentID, world = C_Map.GetWorldPosFromMapPos(mapID, pos)
    continentID = Plain(continentID)
    if type(continentID) ~= "number" or not world then return nil end
    local x, y = world:GetXY()
    x, y = Plain(x), Plain(y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return continentID, x, y, mapID
end

-- The continent map above a zone map, by walking the parents.
local function ContinentMapFor(mapID)
    local continentType = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
    local id = mapID
    for _ = 1, 8 do
        local info = C_Map.GetMapInfo(id)
        if not info then return nil end
        if info.mapType == continentType then return id end
        if not info.parentMapID or info.parentMapID == 0 then return nil end
        id = info.parentMapID
    end
    return nil
end

------------------------------------------------------------------------
-- Describing a point
------------------------------------------------------------------------

-- Eight-way compass from world deltas: x grows north, y grows west.
local function Direction(dx, dy)
    local north, west = dx, dy
    local ns = ""
    if math.abs(north) > math.abs(west) * 0.4142 then ns = north > 0 and "north" or "south" end
    local ew = ""
    if math.abs(west) > math.abs(north) * 0.4142 then ew = west > 0 and "west" or "east" end
    if ns ~= "" and ew ~= "" then return ns .. "-" .. ew end
    return ns ~= "" and ns or ew
end

-- "Orgrimmar 38,36", or nil when the map cannot place the point.
local function ZoneText(continentID, x, y, playerMapID)
    local cmap = ContinentMapFor(playerMapID)
    if not cmap or not C_Map.GetMapPosFromWorldPos or not CreateVector2D then return nil end
    local vec = CreateVector2D(x, y)
    local _, frac = C_Map.GetMapPosFromWorldPos(continentID, vec, cmap)
    if not frac then return nil end
    local fx, fy = frac:GetXY()
    if type(fx) ~= "number" or type(fy) ~= "number" then return nil end
    local info = C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(cmap, fx, fy)
    if type(info) == "table" and info[1] then info = info[1] end   -- some clients return a list
    if type(info) ~= "table" or not info.mapID or info.mapID == cmap then return nil end
    local _, zfrac = C_Map.GetMapPosFromWorldPos(continentID, vec, info.mapID)
    local text = Plain(info.name) or "?"
    if zfrac then
        local zx, zy = zfrac:GetXY()
        if type(zx) == "number" and type(zy) == "number" then
            text = text .. string.format(" %.0f,%.0f", zx * 100, zy * 100)
        end
    end
    return text
end

local function Describe(hit, px, py, continentID, playerMapID)
    local dx, dy = hit.x - px, hit.y - py
    local dist = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    local parts = { hit.name }
    local zone = ZoneText(continentID, hit.x, hit.y, playerMapID)
    if zone then parts[#parts + 1] = zone end
    if dist < 10 then
        parts[#parts + 1] = "right here"
    else
        parts[#parts + 1] = dist .. " yd " .. Direction(dx, dy)
    end
    if hit.learned then parts[#parts + 1] = "visited" end
    return table.concat(parts, ", ")
end

------------------------------------------------------------------------
-- Candidates: shipped rows plus learned entries, learned wins per NPC
------------------------------------------------------------------------

local function Allowed(faction, mine)
    return faction == "N" or faction == nil or faction == mine
end

-- Returns the nearest candidate { id, name, x, y, learned, items } on the
-- player's continent, or nil. `shipped` is a list of rows, `pick(row)`
-- returns id, name, faction, continent, x, y, items or nil to skip it.
-- `learnedKind` selects db.nearby entries ("t" or "v") and `accept(entry)`
-- says whether a learned entry fits.
local function Nearest(shipped, pick, learnedKind, accept, continentID, px, py)
    local mine = PlayerFaction()
    local learned = Store.NearbyEntries and Store.NearbyEntries() or {}
    local best, bestD
    local function consider(id, name, x, y, isLearned, items)
        local dx, dy = x - px, y - py
        local d = dx * dx + dy * dy
        if not bestD or d < bestD then
            best, bestD = { id = id, name = name, x = x, y = y, learned = isLearned, items = items }, d
        end
    end
    for _, row in ipairs(shipped) do
        local id, name, faction, cont, x, y, items = pick(row)
        if id and cont == continentID and Allowed(faction, mine) and not learned[id] then
            consider(id, name, x, y, false, items)
        end
    end
    for id, e in pairs(learned) do
        if e.kind == learnedKind and e.continent == continentID and Allowed(e.faction, mine) and accept(e) then
            consider(id, e.name or ("NPC " .. id), e.x, e.y, true, e.items)
        end
    end
    return best
end

------------------------------------------------------------------------
-- What this character needs
------------------------------------------------------------------------

-- ARROW or BULLET from the equipped ranged weapon, nil when none or unknown.
local function AmmoTypeWanted()
    local link = GetInventoryItemLink and Plain(GetInventoryItemLink("player", RANGED_SLOT))
    if type(link) ~= "string" or not C_Item or not C_Item.GetItemInfoInstant then return nil end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(link)
    classID, subClassID = Plain(classID), Plain(subClassID)
    if classID ~= WEAPON_CLASS then return nil end
    if subClassID == BOW or subClassID == CROSSBOW then return ARROW end
    if subClassID == GUN then return BULLET end
    return nil
end

-- Set of item IDs this character buys from vendors: the class's reagents,
-- or ammo of the right type for hunters. Also a short label for the chat.
local function WantedItems(class)
    local D = Data()
    local wanted, label = {}, nil
    if class == "HUNTER" then
        local sub = AmmoTypeWanted()
        for id, a in pairs(D.ammo) do
            if not sub or a[1] == sub then wanted[id] = true end
        end
        label = sub == ARROW and "arrows" or sub == BULLET and "bullets" or "ammo"
    else
        local names = {}
        for id, r in pairs(D.reagents) do
            if r[1] == class then wanted[id] = true; names[#names + 1] = r[2] end
        end
        table.sort(names)
        label = #names > 0 and table.concat(names, ", ") or nil
    end
    return wanted, label
end

-- The best-sounding item a vendor row sells from the wanted set: for ammo
-- the highest level, for reagents the first by name.
local function BestWanted(items, wanted)
    local D = Data()
    local best, bestLevel
    for _, id in ipairs(items) do
        if wanted[id] then
            local a = D.ammo[id]
            local level = a and a[2] or 0
            if not best or level > bestLevel then best, bestLevel = id, level end
        end
    end
    if not best then return nil end
    local a, r = D.ammo[best], D.reagents[best]
    return a and a[3] or r and r[2] or nil
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------

local function Unavailable(what)
    UlSource.Say(what .. ": your position is not readable here (instance or loading screen).")
end

function UlSource.NearestTrainer()
    local class = PlayerClass()
    if not class or not Data() then return end
    local continentID, px, py, mapID = PlayerWorld()
    if not continentID then return Unavailable("trainer") end
    local hit = Nearest(Data().trainers,
        function(r) if r[3] == class then return r[1], r[2], r[4], r[5], r[6], r[7] end end,
        "t", function(e) return e.class == class end,
        continentID, px, py)
    local who = (CLASS_NAMES[class] or class:lower()) .. " trainer"
    if not hit then
        UlSource.Say("no " .. who .. " known on this continent.")
        return
    end
    UlSource.Say("nearest " .. who .. ": " .. Describe(hit, px, py, continentID, mapID) .. ".")
end

function UlSource.NearestReagentVendor()
    local class = PlayerClass()
    if not class or not Data() then return end
    local wanted, label = WantedItems(class)
    if not next(wanted) then
        UlSource.Say((CLASS_NAMES[class] or class:lower()) .. "s buy no reagents from vendors.")
        return
    end
    local continentID, px, py, mapID = PlayerWorld()
    if not continentID then return Unavailable("reagents") end
    local function sells(items)
        for _, id in ipairs(items or {}) do if wanted[id] then return true end end
        return false
    end
    local hit = Nearest(Data().vendors,
        function(r) if sells(r[7]) then return r[1], r[2], r[3], r[4], r[5], r[6], r[7] end end,
        "v", function(e) return sells(e.items) end,
        continentID, px, py)
    local who = class == "HUNTER" and (label .. " vendor") or "reagent vendor"
    if not hit then
        UlSource.Say("no " .. who .. " known on this continent" .. (label and class ~= "HUNTER" and (" (" .. label .. ")") or "") .. ".")
        return
    end
    local best = hit.items and BestWanted(hit.items, wanted)
    local text = Describe(hit, px, py, continentID, mapID)
    if best then text = text .. " (sells " .. best .. ")" end
    UlSource.Say("nearest " .. who .. ": " .. text .. ".")
end

------------------------------------------------------------------------
-- Learning from visits
------------------------------------------------------------------------

local lastError

local function Report(what, err)
    err = tostring(err)
    if err == lastError then return end
    lastError = err
    UlSource.Say("nearby " .. what .. ": " .. err)
end

-- The NPC the player is talking to: id and name, or nil.
local function NPC()
    local guid = Plain(UnitGUID and UnitGUID("npc"))
    local parsed = UlSource.ParseGUID(guid)
    if parsed.kind ~= "Creature" or not parsed.id then return nil end
    local name = Plain(UnitName("npc"))
    if type(name) ~= "string" or name == "<secret>" then name = nil end
    return parsed.id, name
end

local function Here()
    local continentID, x, y = PlayerWorld()
    if not continentID then return nil end
    return { continent = continentID, x = math.floor(x * 10 + 0.5) / 10, y = math.floor(y * 10 + 0.5) / 10,
             faction = PlayerFaction() }
end

local function OnTrainerShow()
    if not UlSource.db or not UlSource.db.settings.enabled or not Data() then return end
    if IsTradeskillTrainer and IsTradeskillTrainer() then return end
    local n = GetNumTrainerServices and tonumber(Plain(GetNumTrainerServices())) or 0
    if n == 0 then return end
    local id, name = NPC()
    if not id or Data().petTrainers[id] then return end
    local rec = Here()
    if not rec then return end
    rec.kind, rec.class, rec.name = "t", PlayerClass(), name
    Store.RecordNearby(id, rec)
end

local function OnMerchantShow()
    if not UlSource.db or not UlSource.db.settings.enabled or not Data() then return end
    local D = Data()
    local n = GetMerchantNumItems and tonumber(Plain(GetMerchantNumItems())) or 0
    if n == 0 then return end
    local items = {}
    for i = 1, n do
        local link = GetMerchantItemLink and Plain(GetMerchantItemLink(i))
        local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
        if id and (D.reagents[id] or D.ammo[id]) then items[#items + 1] = id end
    end
    if #items == 0 then return end
    local id, name = NPC()
    if not id then return end
    local rec = Here()
    if not rec then return end
    table.sort(items)
    rec.kind, rec.name, rec.items = "v", name, items
    Store.RecordNearby(id, rec)
end

local frame = CreateFrame("Frame", "UlSourceNearbyFrame")
frame:RegisterEvent("TRAINER_SHOW")
frame:RegisterEvent("MERCHANT_SHOW")
frame:SetScript("OnEvent", function(_, event)
    if event == "TRAINER_SHOW" then
        local ok, err = pcall(OnTrainerShow)
        if not ok then Report("trainer", err) end
    elseif event == "MERCHANT_SHOW" then
        local ok, err = pcall(OnMerchantShow)
        if not ok then Report("merchant", err) end
    end
end)
