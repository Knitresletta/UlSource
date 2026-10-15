-- Name learner: fills in creature names the shipped table does not have.
--
-- Whenever the target or the mouseover unit changes, and the unit's GUID
-- and name are readable (outside instances they are; inside they are
-- secret values and nothing is done), and the creature's ID is a source
-- the store has without a name, the name is written to the store. That is
-- all; it never fires a request and never touches the unit.

local Plain = UlSource.Plain
local Store = UlSource.Store

local function Learn(unit)
    if not UnitExists or not UnitExists(unit) then return end
    local guid = Plain(UnitGUID(unit))
    if type(guid) ~= "string" or guid == "<secret>" then return end
    local parsed = UlSource.ParseGUID(guid)
    if (parsed.kind ~= "Creature" and parsed.kind ~= "Vehicle") or not parsed.id then return end
    if not Store.WantsName("c", parsed.id) then return end
    local name = Plain(UnitName(unit))
    if type(name) ~= "string" or name == "<secret>" or name == "" then return end
    Store.LearnName("c", parsed.id, name)
end

local frame = CreateFrame("Frame", "UlSourceNamesFrame")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:SetScript("OnEvent", function(_, event)
    if not UlSource.db or not UlSource.db.settings.enabled then return end
    pcall(Learn, event == "PLAYER_TARGET_CHANGED" and "target" or "mouseover")
end)
