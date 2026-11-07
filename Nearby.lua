-- Nearby: "/us trainer", "/us reagents" and a small window with both
-- (/us nearby, or its row in the Ul minimap menu). From where the player
-- stands, the nearest class trainer, and the nearest vendor that sells
-- this class's spell reagents (hunters: ammo for the equipped weapon).
--
-- Positions come from NPCs this account has visited, nothing else: a
-- class trainer window, or a merchant window with a reagent or ammo in
-- it, stores the NPC under UlSourceDB.nearby with the player's position
-- at that moment. No positions are shipped (Forever sources only, and
-- none has NPC positions), so a fresh account knows nobody until it has
-- been to them. What counts as a reagent or ammo is NearbyData.lua, built
-- from the Forever client's own data (tools/build_nearby.py, wago).
--
-- Whether a trainer window belongs to a class trainer is read from what
-- it offers: the services are spell names, and the spellbook knows which
-- names are the class's own (the class tabs, not General). One service
-- named like a known class spell makes it a class trainer for this
-- character; weapon masters, riding and pet trainers offer nothing that
-- sits in a class tab. The NPC's tooltip title ("Druid Trainer") is the
-- fallback when the spellbook API is not there.
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
-- Candidates: the learned entries this character can use
------------------------------------------------------------------------

-- A learned entry is usable by any faction that has actually opened its
-- window (seenBy), so a neutral vendor visited by a Horde character is
-- offered to Alliance ones only once one of them has used it too.
local function LearnedAllowed(e, mine)
    return e.seenBy ~= nil and e.seenBy[mine] == true
end

-- Every usable candidate for this character. `learnedKind` selects
-- db.nearby entries ("t" or "v") and `accept(entry)` says whether an
-- entry fits. Each candidate: { id, name, continent, x, y, learned, items }.
local function Candidates(learnedKind, accept)
    local mine = PlayerFaction()
    local learned = Store.NearbyEntries and Store.NearbyEntries() or {}
    local list = {}
    for id, e in pairs(learned) do
        if e.kind == learnedKind and LearnedAllowed(e, mine) and accept(e) then
            list[#list + 1] = { id = id, name = e.name or ("NPC " .. id), continent = e.continent, x = e.x, y = e.y,
                                learned = true, items = e.items }
        end
    end
    return list
end

-- The nearest candidate on the player's continent, or nil.
local function Nearest(learnedKind, accept, continentID, px, py)
    local best, bestD
    for _, c in ipairs(Candidates(learnedKind, accept)) do
        if c.continent == continentID then
            local dx, dy = c.x - px, c.y - py
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then best, bestD = c, d end
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
            -- r[1] holds every class token that uses the item, space separated.
            if r[1]:find(class, 1, true) then wanted[id] = true; names[#names + 1] = r[2] end
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

local NOT_HERE = "position not readable here (instance or loading screen)"

-- Text for the nearest class trainer, or nil and a reason.
local function TrainerAccept(class)
    return function(e) return e.class == class end
end

local function VendorAccept(wanted)
    return function(e)
        for _, id in ipairs(e.items or {}) do if wanted[id] then return true end end
        return false
    end
end

function UlSource.NearbyTrainerText()
    local class = PlayerClass()
    if not class or not Data() then return nil, "no class data" end
    local continentID, px, py, mapID = PlayerWorld()
    if not continentID then return nil, NOT_HERE end
    local hit = Nearest("t", TrainerAccept(class), continentID, px, py)
    local who = (CLASS_NAMES[class] or class:lower()) .. " trainer"
    if not hit then return nil, "no " .. who .. " visited on this continent yet" end
    return Describe(hit, px, py, continentID, mapID), who
end

-- Text for the nearest reagent (or ammo) vendor, or nil and a reason.
function UlSource.NearbyReagentsText()
    local class = PlayerClass()
    if not class or not Data() then return nil, "no class data" end
    local wanted, label = WantedItems(class)
    if not next(wanted) then
        return nil, (CLASS_NAMES[class] or class:lower()) .. "s buy no reagents from vendors"
    end
    local continentID, px, py, mapID = PlayerWorld()
    if not continentID then return nil, NOT_HERE end
    local hit = Nearest("v", VendorAccept(wanted), continentID, px, py)
    local who = class == "HUNTER" and (label .. " vendor") or "reagent vendor"
    if not hit then
        return nil, "no " .. who .. " visited on this continent yet" .. (class ~= "HUNTER" and label and (" (" .. label .. ")") or "")
    end
    local best = hit.items and BestWanted(hit.items, wanted)
    local text = Describe(hit, px, py, continentID, mapID)
    if best then text = text .. " (sells " .. best .. ")" end
    return text, who
end

function UlSource.NearestTrainer()
    local text, who = UlSource.NearbyTrainerText()
    if text then UlSource.Say("nearest " .. who .. ": " .. text .. ".") else UlSource.Say("trainer: " .. who .. ".") end
    UlSource.Say("last trainer window: " .. lastTrainerCheck)
end

function UlSource.NearestReagentVendor()
    local text, who = UlSource.NearbyReagentsText()
    if text then UlSource.Say("nearest " .. who .. ": " .. text .. ".") else UlSource.Say("reagents: " .. who .. ".") end
end

-- Every trainer and vendor this character can use, for the map pins:
-- { kind = "t"|"v", id, name, continent, x, y, learned, detail }, where
-- detail is "shaman trainer" or "sells Ankh".
function UlSource.NearbyPoints()
    local class = PlayerClass()
    if not class or not Data() then return {} end
    local list = {}
    local who = (CLASS_NAMES[class] or class:lower()) .. " trainer"
    for _, c in ipairs(Candidates("t", TrainerAccept(class))) do
        c.kind, c.detail = "t", who
        list[#list + 1] = c
    end
    local wanted = WantedItems(class)
    if next(wanted) then
        for _, c in ipairs(Candidates("v", VendorAccept(wanted))) do
            local best = c.items and BestWanted(c.items, wanted)
            c.kind, c.detail = "v", best and ("sells " .. best) or "vendor"
            c.ammo = class == "HUNTER"
            list[#list + 1] = c
        end
    end
    return list
end

------------------------------------------------------------------------
-- Window: the two answers, refreshed while open. A row in the Ul minimap
-- menu (UlRemedyForever owns the button) and /us nearby open it.
------------------------------------------------------------------------

local ICON = "Interface\\AddOns\\UlSource\\media\\icon"
local REFRESH_SECONDS = 3
local WIN_W, WIN_H = 420, 128

local nearbyWindow, ticker

local function RefreshNearbyWindow()
    local w = nearbyWindow
    if not w or not w:IsShown() then return end
    local function fill(line, fn, label)
        local text, who = fn()
        if text then
            line.title:SetText(label .. " |cffaaaaaa(" .. who .. ")|r")
            line.text:SetText(text)
        else
            line.title:SetText(label)
            line.text:SetText("|cff999999" .. who .. "|r")
        end
    end
    fill(w.trainer, UlSource.NearbyTrainerText, "Nearest trainer")
    fill(w.vendor, UlSource.NearbyReagentsText, "Nearest reagents")
end

local function MakeLine(parent, yOffset)
    local line = {}
    line.title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    line.title:SetPoint("TOPLEFT", 14, yOffset)
    line.title:SetJustifyH("LEFT")
    line.text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    line.text:SetPoint("TOPLEFT", line.title, "BOTTOMLEFT", 0, -3)
    line.text:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
    line.text:SetJustifyH("LEFT")
    line.text:SetWordWrap(true)
    return line
end

local function CreateNearbyWindow()
    local f = CreateFrame("Frame", "UlSourceNearbyWindow", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIN_W, WIN_H)
    f:SetPoint("CENTER", 0, 200)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    tinsert(UISpecialFrames, "UlSourceNearbyWindow")
    if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
    local title = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
    if title then title:SetText("UlSource: nearby") end
    f.trainer = MakeLine(f, -32)
    f.vendor = MakeLine(f, -78)
    f:SetScript("OnShow", function()
        RefreshNearbyWindow()
        if C_Timer and C_Timer.NewTicker and not ticker then
            ticker = C_Timer.NewTicker(REFRESH_SECONDS, function() pcall(RefreshNearbyWindow) end)
        end
    end)
    f:SetScript("OnHide", function()
        if ticker then ticker:Cancel(); ticker = nil end
    end)
    f:Hide()   -- a new frame is shown by default; the toggle must show it
    return f
end

function UlSource.ToggleNearbyWindow()
    if not UlSource.db then return end
    if not nearbyWindow then
        local ok, err = pcall(CreateNearbyWindow)
        if not ok then
            UlSource.Say("could not build the nearby window: " .. tostring(err))
            return
        end
        nearbyWindow = err
    end
    if nearbyWindow:IsShown() then nearbyWindow:Hide() else nearbyWindow:Show() end
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

-- Whether the trainer window open now is a class trainer for this
-- character: the NPC's tooltip title ("Druid Trainer", "Weapon Master",
-- "Riding Trainer") holds the character's localized class name. Read
-- from a scanning tooltip of our own; nil when the title is not readable.
-- Diagnostics for /us trainer: what the last trainer window looked like.
local lastTrainerCheck = "no trainer window opened yet"

-- The unit tooltip's lines after the name, via the client's tooltip data
-- (C_TooltipInfo, the retail way, no frame needed), else a scanning
-- tooltip of our own. Empty when nothing is readable.
local scan
local function NpcTitleLines(unit)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
        if ok and type(data) == "table" and type(data.lines) == "table" then
            for i = 2, math.min(4, #data.lines) do
                local text = Plain(data.lines[i] and data.lines[i].leftText)
                if type(text) == "string" and text ~= "<secret>" and text ~= "" then lines[#lines + 1] = text end
            end
        end
    end
    if #lines == 0 then
        if not scan then
            scan = CreateFrame("GameTooltip", "UlSourceScanTooltip", UIParent, "GameTooltipTemplate")
        end
        local ok = pcall(function()
            scan:SetOwner(UIParent, "ANCHOR_NONE")
            scan:ClearLines()
            scan:SetUnit(unit)
        end)
        if ok then
            for i = 2, math.min(4, scan:NumLines()) do
                local fs = _G["UlSourceScanTooltipTextLeft" .. i]
                local text = fs and Plain(fs:GetText())
                if type(text) == "string" and text ~= "<secret>" and text ~= "" then lines[#lines + 1] = text end
            end
        end
    end
    return lines
end

-- The names of every spell in the class tabs of the player's spellbook
-- (every skill line but the first, General), or nil when the API is not
-- there. GetSpellBookItemName gives the name first (verified on Forever
-- 16.10.2026, UlRemedyForever's Trainer Preview).
local function ClassSpellNames()
    local SB = C_SpellBook
    if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemName) then return nil end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local names, count = {}, 0
    local ok, n = pcall(SB.GetNumSpellBookSkillLines)
    n = ok and tonumber(Plain(n)) or 0
    for line = 2, n do
        local okInfo, info = pcall(SB.GetSpellBookSkillLineInfo, line)
        local offset = okInfo and info and tonumber(Plain(info.itemIndexOffset))
        local items = okInfo and info and tonumber(Plain(info.numSpellBookItems))
        if offset and items and not (info.isGuild or info.isOffSpec) then
            for slot = offset + 1, offset + items do
                local okName, name = pcall(SB.GetSpellBookItemName, slot, bank)
                name = okName and Plain(name)
                if type(name) == "string" and name ~= "<secret>" and name ~= "" then
                    names[name] = true
                    count = count + 1
                end
            end
        end
    end
    return names, count
end

local function IsClassTrainerForMe()
    if not UnitExists or not UnitExists("npc") then
        lastTrainerCheck = "trainer window without an npc unit"
        return nil
    end
    local who = Plain(UnitName("npc"))
    who = type(who) == "string" and who or "?"
    local n = GetNumTrainerServices and tonumber(Plain(GetNumTrainerServices())) or 0
    local known, count = ClassSpellNames()
    if known then
        local seen = {}
        for i = 1, n do
            local name = Plain(GetTrainerServiceInfo(i))
            if type(name) == "string" and name ~= "<secret>" then
                if known[name] then
                    lastTrainerCheck = who .. ": offers " .. name .. ", a spell in your class tabs, learned"
                    return true
                end
                if #seen < 4 then seen[#seen + 1] = name end
            end
        end
        lastTrainerCheck = who .. ": none of " .. n .. " services (" .. table.concat(seen, ", ")
            .. ") is among the " .. count .. " spells in your class tabs, not a class trainer"
        return false
    end
    -- Fallback: the NPC's tooltip title.
    local className = Plain(UnitClass("player"))
    if type(className) ~= "string" then
        lastTrainerCheck = who .. ": no spellbook API and class name not readable"
        return nil
    end
    local lines = NpcTitleLines("npc")
    if #lines == 0 then
        lastTrainerCheck = who .. ": no spellbook API and no tooltip title readable"
        return nil
    end
    for _, text in ipairs(lines) do
        if text:find(className, 1, true) then
            lastTrainerCheck = who .. ": tooltip \"" .. text .. "\" holds " .. className .. ", learned"
            return true
        end
    end
    lastTrainerCheck = who .. ": tooltip \"" .. table.concat(lines, " / ") .. "\" does not hold " .. className .. ", not a class trainer"
    return false
end

-- The record for a visit: position now and the set of player factions
-- that have opened its window (no shipped faction: an NPC is offered to
-- the factions that have actually used it).
local function Here(id)
    local continentID, x, y = PlayerWorld()
    if not continentID then return nil end
    local old = Store.NearbyEntries()[id]
    local seenBy = old and old.seenBy or {}
    local mine = PlayerFaction()
    if mine then seenBy[mine] = true end
    return { continent = continentID, x = math.floor(x * 10 + 0.5) / 10, y = math.floor(y * 10 + 0.5) / 10,
             seenBy = seenBy }
end

local function OnTrainerShow()
    if not UlSource.db or not UlSource.db.settings.enabled or not Data() then return end
    if IsTradeskillTrainer and IsTradeskillTrainer() then return end
    local n = GetNumTrainerServices and tonumber(Plain(GetNumTrainerServices())) or 0
    if n == 0 then return end
    local id, name = NPC()
    if not id or not IsClassTrainerForMe() then return end
    local rec = Here(id)
    if not rec then return end
    rec.kind, rec.class, rec.name = "t", PlayerClass(), name
    Store.RecordNearby(id, rec)
    if UlSource.RefreshMapPins then UlSource.RefreshMapPins() end
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
    local rec = Here(id)
    if not rec then return end
    table.sort(items)
    rec.kind, rec.name, rec.items = "v", name, items
    Store.RecordNearby(id, rec)
    if UlSource.RefreshMapPins then UlSource.RefreshMapPins() end
end

local frame = CreateFrame("Frame", "UlSourceNearbyFrame")
frame:RegisterEvent("TRAINER_SHOW")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        if UlRemedy and type(UlRemedy.Register) == "function" then
            pcall(UlRemedy.Register, {
                id = "UlSourceNearby",
                title = "UlSource: nearby",
                icon = ICON,
                open = UlSource.ToggleNearbyWindow,
            })
        end
        self:UnregisterEvent("PLAYER_LOGIN")
    elseif event == "TRAINER_SHOW" then
        local ok, err = pcall(OnTrainerShow)
        if not ok then Report("trainer", err) end
    elseif event == "MERCHANT_SHOW" then
        local ok, err = pcall(OnMerchantShow)
        if not ok then Report("merchant", err) end
    end
end)
