-- Map Pins: a small icon on the zone map at every point where an object
-- (herb, ore vein, chest, fishing spot) was looted.
--
-- The points come from the store: every "o:" source keeps, per zone, the
-- map ID the point was taken on and up to 40 distinct points (same spawn
-- twice is one point). Each pin shows the icon of the item the object
-- last gave, 12 pixels, and takes no mouse input at all: no tooltip, no
-- click, the map underneath behaves as if the pin were not there.
--
-- Same mechanism as UlRemedyForever's flight paths: a data provider of
-- ours on WorldMapFrame, pins acquired from the template in MapPins.xml,
-- refreshed by the map itself whenever it changes. Blizzard_WorldMap may
-- load after us, so the provider is installed on whichever ADDON_LOADED
-- first finds WorldMapFrame.

local PIN_TEMPLATE = "UlSourceNodePinTemplate"
local QUESTION_MARK = 134400

local Store = UlSource.Store
local provider
local iconCache = {}

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
-- Pin
------------------------------------------------------------------------

UlSourceNodePinMixin = CreateFromMixins(MapCanvasPinMixin)

function UlSourceNodePinMixin:OnLoad()
    self:SetScalingLimits(1, 1.0, 1.2)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:EnableMouse(false)
end

function UlSourceNodePinMixin:OnAcquired(point)
    self.Icon:SetTexture(IconFor(point.itemID))
    self.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    self:SetPosition(point.x, point.y)
end

------------------------------------------------------------------------
-- Data provider
------------------------------------------------------------------------

local ProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function ProviderMixin:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
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
        map:AcquirePin(PIN_TEMPLATE, point)
    end
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
frame:SetScript("OnEvent", function(self, event)
    local ok, installed = pcall(InstallProvider)
    if not ok then
        UlSource.Say("map pins could not be installed: " .. tostring(installed))
        self:UnregisterAllEvents()
    elseif provider then
        self:UnregisterAllEvents()
    end
end)
