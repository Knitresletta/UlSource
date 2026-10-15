-- Collector: listens to the loot window and hands one record per window
-- to the store. It reads, it never changes how looting works.
--
-- The record is taken on LOOT_READY, before auto loot empties the window
-- (LOOT_OPENED comes after, with nothing left in it). LOOT_READY fires
-- twice per window on this client; the second one is told apart by its
-- content: same slots and sources within 1.5 seconds is the same window.
--
-- Every slot's source GUID comes from GetLootSourceInfo, which is readable
-- in combat and in instances (probe 0.1.x). The GUID gives the kind and
-- the ID; the kind becomes the key prefix: "c:" for a creature's drops,
-- "o:" for an object (node, chest), and "s:" for a creature looted right
-- after a Skinning cast, so skins and drops are counted apart. Slots whose
-- GUID is of another kind (an item opened from the bags, for example) are
-- counted as unattributed and skipped.
--
-- The name of a creature is taken from the current target when its GUID
-- is readable and equals the source GUID. Inside instances it is secret
-- and stays nil; the shipped table and the name learner cover it.

local SAME_WINDOW_SECONDS = 1.5
local SKIN_WINDOW_SECONDS = 2
local SLOT_ITEM = 1

local Plain = UlSource.Plain
local Store = UlSource.Store

local lastSignature, lastWindowAt = nil, 0
local lastSkinAt = 0
local lastError

local function Enabled()
    return UlSource.db and UlSource.db.settings.enabled
end

local function Report(what, err)
    err = tostring(err)
    if err == lastError then return end
    lastError = err
    UlSource.Say("collector " .. what .. ": " .. err)
end

------------------------------------------------------------------------
-- Context
------------------------------------------------------------------------

local function Position()
    if not C_Map or not C_Map.GetBestMapForUnit then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or (issecretvalue and issecretvalue(mapID)) then return nil end
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    x, y = Plain(x), Plain(y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

local function Zone()
    local zone = GetRealZoneText and Plain(GetRealZoneText())
    if type(zone) ~= "string" or zone == "" then
        zone = GetZoneText and Plain(GetZoneText())
    end
    if type(zone) ~= "string" or zone == "" then return nil end
    return zone
end

-- The target's readable GUID and name, when it is a dead unit.
local function DeadTarget()
    if not UnitExists or not UnitExists("target") then return nil end
    local guid = Plain(UnitGUID("target"))
    local name = Plain(UnitName("target"))
    if type(guid) ~= "string" or guid == "<secret>" then return nil end
    if type(name) ~= "string" or name == "<secret>" then return guid, nil end
    return guid, name
end

------------------------------------------------------------------------
-- Reading the window
------------------------------------------------------------------------

local function KindFor(parsed)
    if parsed.kind == "Creature" or parsed.kind == "Vehicle" then
        if GetTime() - lastSkinAt <= SKIN_WINDOW_SECONDS then return "s" end
        return "c"
    elseif parsed.kind == "GameObject" then
        return "o"
    end
    return nil
end

-- Returns sources ({ [key] = { kind, id, guid, items } }) and a signature
-- string for the duplicate check, or nil when the window has no slots.
local function ReadWindow()
    local n = GetNumLootItems and tonumber(Plain(GetNumLootItems())) or 0
    if n == 0 then return nil end
    local sources = {}
    local sigParts = {}
    for slot = 1, n do
        local slotType = GetLootSlotType and Plain(GetLootSlotType(slot))
        local itemID, name, qty
        if slotType == SLOT_ITEM then
            local link = GetLootSlotLink and Plain(GetLootSlotLink(slot))
            itemID = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
            local _, lootName, lootQty = GetLootSlotInfo(slot)
            name = Plain(lootName)
            qty = tonumber(Plain(lootQty))
            if type(name) ~= "string" or name == "<secret>" then name = nil end
        end
        local res = { GetLootSourceInfo(slot) }
        if #res == 0 then
            Store.NoteUnattributed()
        end
        for i = 1, #res, 2 do
            local guid = Plain(res[i])
            local sourceQty = tonumber(Plain(res[i + 1]))
            local parsed = UlSource.ParseGUID(guid)
            local kind = parsed.id and KindFor(parsed)
            if kind then
                local key = Store.Key(kind, parsed.id)
                local src = sources[key]
                if not src then
                    src = { kind = kind, id = parsed.id, guid = guid, items = {} }
                    sources[key] = src
                end
                if itemID then
                    local it = src.items[itemID]
                    if not it then
                        it = { name = name, qty = 0 }
                        src.items[itemID] = it
                    end
                    it.qty = it.qty + (sourceQty or qty or 1)
                end
                sigParts[#sigParts + 1] = key .. "/" .. tostring(itemID or slotType)
            else
                Store.NoteUnattributed()
            end
        end
    end
    if next(sources) == nil then return nil end
    table.sort(sigParts)
    return sources, table.concat(sigParts, ",")
end

local function OnLootReady()
    if not Enabled() then return end
    local sources, signature = ReadWindow()
    if not sources then return end
    local now = GetTime()
    if signature == lastSignature and now - lastWindowAt < SAME_WINDOW_SECONDS then
        return
    end
    lastSignature, lastWindowAt = signature, now

    local targetGUID, targetName = DeadTarget()
    if targetGUID and targetName then
        for _, src in pairs(sources) do
            if src.guid == targetGUID then src.name = targetName end
        end
    end
    local x, y = Position()
    Store.RecordWindow(sources, { zone = Zone(), x = x, y = y })
end

local function OnSpellcast(unit, _, spellID)
    if unit ~= "player" then return end
    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        name = info and Plain(info.name)
    end
    if name == "Skinning" then lastSkinAt = GetTime() end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local frame = CreateFrame("Frame", "UlSourceCollectorFrame")
frame:RegisterEvent("LOOT_READY")
if not pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player") then
    frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
frame:SetScript("OnEvent", function(_, event, ...)
    if not UlSource.db then return end
    if event == "LOOT_READY" then
        local ok, err = pcall(OnLootReady)
        if not ok then Report("loot window", err) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        pcall(OnSpellcast, ...)
    end
end)
