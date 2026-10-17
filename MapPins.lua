-- Map Pins: a small icon on the zone map at every point where an object
-- (herb, ore vein, chest, fishing spot) was looted, for the nodes this
-- character can gather (see "Which pins" below), and a larger icon at
-- every class trainer and reagent vendor this character can use (from
-- Nearby.lua, see "Nearby pins" below).
--
-- The points come from the store: every "o:" source keeps, per zone, the
-- map ID the point was taken on and up to 40 distinct points (same spawn
-- twice is one point). Each pin shows the icon of the item the object
-- last gave, 8 pixels and rounded to a circle, and takes no mouse input at all: no tooltip, no
-- click, the map underneath behaves as if the pin were not there.
--
-- Same mechanism as UlRemedyForever's flight paths: a data provider of
-- ours on WorldMapFrame, pins acquired from the template in MapPins.xml,
-- refreshed by the map itself whenever it changes. Blizzard_WorldMap may
-- load after us, so the provider is installed on whichever ADDON_LOADED
-- first finds WorldMapFrame.

local PIN_TEMPLATE = "UlSourceNodePinTemplate"
local NEARBY_TEMPLATE = "UlSourceNearbyPinTemplate"
local ICON_TRAINER = "Interface\\Icons\\INV_Misc_Book_09"
local ICON_VENDOR = "Interface\\Icons\\INV_Misc_Coin_01"
local ICON_AMMO = "Interface\\Icons\\INV_Ammo_Arrow_02"
local QUESTION_MARK = 134400

-- Skill line IDs of the gathering professions.
local HERBALISM, MINING, FISHING = 182, 186, 356
-- Item class and subclasses that say what kind of node an item came from.
local CLASS_TRADEGOODS = 7
local SUBCLASS_METAL_AND_STONE, SUBCLASS_HERB = 7, 9

local Store = UlSource.Store
local provider
local iconCache = {}
local professions = {}        -- skill line ID -> true, for this character
local professionsDirty = true

local function Enabled()
    local st = UlSource.db and UlSource.db.settings
    return st and st.enabled and st.mapPins
end

local function IconFor(itemID)
    if not itemID then return QUESTION_MARK end
    local icon = iconCache[itemID]
    if icon then return icon end
    if C_Item and C_Item.GetItemIconByID then
        local ok, got = pcall(C_Item.GetItemIconByID, itemID)
        if ok and got then icon = got end
    end
    icon = icon or QUESTION_MARK
    iconCache[itemID] = icon
    return icon
end

------------------------------------------------------------------------
-- Which pins this character should see
------------------------------------------------------------------------

-- Nodes are shown only when the character has the profession that
-- gathers them (settings.pinsAll shows all): an herb needs Herbalism, ore
-- needs Mining, a fishing spot needs Fishing. Chests, and anything whose
-- item the client cannot classify yet, are always shown. The item's class
-- comes from C_Item.GetItemInfoInstant, which does not need the item cache.

local function RefreshProfessions()
    wipe(professions)
    if GetProfessions and GetProfessionInfo then
        for i = 1, 6 do
            local index = select(i, GetProfessions())
            if index then
                local _, _, _, _, _, _, skillLine = GetProfessionInfo(index)
                skillLine = UlSource.Plain(skillLine)
                if type(skillLine) == "number" and skillLine > 0 then professions[skillLine] = true end
            end
        end
    end
    professionsDirty = false
end

local function NeededProfession(point)
    if UlSource.FishingObjects and UlSource.FishingObjects[Store.ParseKeyID(point.key)] then
        return FISHING
    end
    if point.itemID and C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, _, _, _, classID, subclassID = pcall(C_Item.GetItemInfoInstant, point.itemID)
        if ok and classID == CLASS_TRADEGOODS then
            if subclassID == SUBCLASS_HERB then return HERBALISM end
            if subclassID == SUBCLASS_METAL_AND_STONE then return MINING end
        end
    end
    return nil
end

local function Wanted(point)
    if UlSource.db.settings.pinsAll then return true end
    local needed = NeededProfession(point)
    if not needed then return true end
    if professionsDirty then RefreshProfessions() end
    return professions[needed] == true
end

------------------------------------------------------------------------
-- Pin
------------------------------------------------------------------------

UlSourceNodePinMixin = CreateFromMixins(MapCanvasPinMixin)

function UlSourceNodePinMixin:OnLoad()
    self:SetScalingLimits(1, 1.0, 1.2)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:EnableMouse(false)
end

-- AcquirePin calls this on every pin after OnAcquired, and it calls
-- SetPassThroughButtons, which the client blocks (ADDON_ACTION_BLOCKED) on a
-- pin with mouse input disabled: 24 blocked actions per map open on
-- 0.5.0. The pin takes no mouse at all, so pass-through has nothing to
-- decide; overriding it to do nothing is the whole fix.
function UlSourceNodePinMixin:CheckMouseButtonPassthrough()
end

function UlSourceNodePinMixin:OnAcquired(point)
    self.Icon:SetTexture(IconFor(point.itemID))
    self.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    self:SetPosition(point.x, point.y)
end

------------------------------------------------------------------------
-- Nearby pins: class trainers and reagent vendors (Nearby.lua), in world
-- coordinates, projected onto whatever map is open. These take the
-- mouse: a tooltip with the name and what the NPC is for.
------------------------------------------------------------------------

UlSourceNearbyPinMixin = CreateFromMixins(MapCanvasPinMixin)

function UlSourceNearbyPinMixin:OnLoad()
    self:SetScalingLimits(1, 1.0, 1.2)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_FLIGHT_POINT")
end

function UlSourceNearbyPinMixin:OnAcquired(entry, x, y)
    self.entry = entry
    local icon = entry.kind == "t" and ICON_TRAINER or (entry.ammo and ICON_AMMO or ICON_VENDOR)
    self.Icon:SetTexture(icon)
    self.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    self.Ring:SetVertexColor(entry.learned and 0.3 or 0, entry.learned and 0.8 or 0, 0, 0.9)
    self:SetPosition(x, y)
end

function UlSourceNearbyPinMixin:OnMouseEnter()
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.name, 1, 1, 1)
    GameTooltip:AddLine(e.detail .. (e.learned and ", visited" or ""), 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function UlSourceNearbyPinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

-- Continent and zone maps only: the Azeroth and cosmic maps span more than
-- one continent and have no single world coordinate system.
local function ContinentOf(mapID)
    local info = C_Map.GetMapInfo(mapID)
    local worldType = Enum.UIMapType and Enum.UIMapType.World
    local cosmicType = Enum.UIMapType and Enum.UIMapType.Cosmic
    if not info or info.mapType == worldType or info.mapType == cosmicType then return nil end
    local continentID = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.5, 0.5))
    continentID = UlSource.Plain(continentID)
    return type(continentID) == "number" and continentID or nil
end

local function AddNearbyPins(map, mapID)
    if not UlSource.NearbyPoints or not UlSource.db.settings.nearbyPins then return end
    local continentID = ContinentOf(mapID)
    if not continentID then return end
    for _, entry in ipairs(UlSource.NearbyPoints()) do
        if entry.continent == continentID then
            local _, pos = C_Map.GetMapPosFromWorldPos(continentID, CreateVector2D(entry.x, entry.y), mapID)
            if pos then
                local x, y = pos:GetXY()
                if type(x) == "number" and type(y) == "number" and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                    map:AcquirePin(NEARBY_TEMPLATE, entry, x, y)
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Data provider
------------------------------------------------------------------------

local ProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function ProviderMixin:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
    self:GetMap():RemoveAllPinsByTemplate(NEARBY_TEMPLATE)
end

function ProviderMixin:RefreshAllData()
    self:RemoveAllData()
    if not Enabled() then return end
    local map = self:GetMap()
    local mapID = map:GetMapID()
    if not mapID then return end
    local ok, points = pcall(Store.PinsForMap, mapID)
    if not ok then
        UlSource.Say("map pins: " .. tostring(points))
        return
    end
    for _, point in ipairs(points) do
        if Wanted(point) then map:AcquirePin(PIN_TEMPLATE, point) end
    end
    local okNearby, err = pcall(AddNearbyPins, map, mapID)
    if not okNearby then UlSource.Say("nearby pins: " .. tostring(err)) end
end

function UlSource.RefreshMapPins()
    if provider and WorldMapFrame and WorldMapFrame:IsShown() then
        provider:RefreshAllData()
    end
end

local function InstallProvider()
    if provider or not WorldMapFrame or not WorldMapFrame.AddDataProvider then return false end
    provider = CreateFromMixins(ProviderMixin)
    WorldMapFrame:AddDataProvider(provider)
    return true
end

local frame = CreateFrame("Frame", "UlSourceMapPinsFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:SetScript("OnEvent", function(self, event)
    if event == "SKILL_LINES_CHANGED" then
        professionsDirty = true
        UlSource.RefreshMapPins()
        return
    end
    local ok, installed = pcall(InstallProvider)
    if not ok then
        UlSource.Say("map pins could not be installed: " .. tostring(installed))
        self:UnregisterEvent("ADDON_LOADED")
        self:UnregisterEvent("PLAYER_LOGIN")
    elseif provider then
        self:UnregisterEvent("ADDON_LOADED")
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)
