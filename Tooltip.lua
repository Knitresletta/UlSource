-- Tooltip: the "Source:" lines under an item, read from the store.
--
-- At most settings.lines sources, the one the item appeared in most often
-- first. Two lines per source so the tooltip stays as narrow as the item's
-- own lines: the source's name (or "NPC 4436" until a name is known) with
-- the rate, "25% (3/12)" windows, then in grey the zone it was seen most
-- in with the newest point there and how long ago.
--
-- Hooked with TooltipDataProcessor.AddTooltipPostCall for item tooltips,
-- GameTooltip and ItemRefTooltip only. AddLine is the only call made on
-- the tooltip: no money frames, no layout functions (secret values).

local LABEL = "|cffffcc00Source:|r "
local INDENT = "         "
local R, G, B = 0.9, 0.9, 0.9

local Store = UlSource.Store

local function Ago(t)
    if not t then return nil end
    local d = time() - t
    if d < 90 then return "just now" end
    if d < 3600 then return math.floor(d / 60 + 0.5) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600 + 0.5) .. "h ago" end
    return math.floor(d / 86400 + 0.5) .. "d ago"
end

-- "Razorfen Quilguard", "Briarthorn", "Agam'ar (skinning)", "NPC 4436".
function UlSource.SourceLabel(src)
    local name = src.name
    if not name then
        name = (src.kind == "o" and "Object " or "NPC ") .. tostring(src.id)
    elseif UlSource.db.settings.showIDs then
        name = name .. " (" .. tostring(src.id) .. ")"
    end
    if src.kind == "s" then name = name .. " (skinning)" end
    return name
end

-- "25% (3/12)": windows the item was in, out of windows from this source.
function UlSource.SourceRate(src)
    local pct = src.windows > 0 and math.floor(src.n / src.windows * 100 + 0.5) or 0
    return pct .. "% (" .. src.n .. "/" .. src.windows .. ")"
end

-- "Razorfen Kraul 42,61, 3h ago": zone with the newest point, then age.
-- nil when neither is known.
function UlSource.SourceWhere(src)
    local parts = {}
    if src.zone then
        local where = src.zone
        if src.x and src.y then
            where = where .. string.format(" %.0f,%.0f", src.x * 100, src.y * 100)
        end
        parts[#parts + 1] = where
    end
    local ago = Ago(src.last)
    if ago then parts[#parts + 1] = ago end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- Everything on one line, for the window and /us <id> in chat.
function UlSource.SourceLine(src)
    local parts = { UlSource.SourceLabel(src), UlSource.SourceRate(src) }
    parts[#parts + 1] = UlSource.SourceWhere(src)
    return table.concat(parts, ", ")
end

local function AddLines(tooltip, itemID)
    if not itemID or not UlSource.db or not UlSource.db.settings.enabled then return end
    local list = Store.ItemSources(itemID)
    if not list or #list == 0 then return end
    local max = UlSource.db.settings.lines or 3
    for i = 1, math.min(max, #list) do
        local src = list[i]
        local prefix = (i == 1) and LABEL or INDENT
        tooltip:AddLine(prefix .. UlSource.SourceLabel(src) .. "  " .. UlSource.SourceRate(src), R, G, B)
        local where = UlSource.SourceWhere(src)
        if where then tooltip:AddLine(INDENT .. where, 0.7, 0.7, 0.7) end
    end
    if #list > max then
        tooltip:AddLine(INDENT .. "+" .. (#list - max) .. " more (/us " .. itemID .. ")", 0.6, 0.6, 0.6)
    end
end

local function ItemIDFromTooltip(tooltip)
    if tooltip.GetItem then
        local _, link = tooltip:GetItem()
        if type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
   and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
        local ok, err = pcall(AddLines, tooltip, (data and data.id) or ItemIDFromTooltip(tooltip))
        if not ok then UlSource.Say("tooltip: " .. tostring(err)) end
    end)
else
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tt and tt.HookScript then
            tt:HookScript("OnTooltipSetItem", function(tooltip)
                pcall(AddLines, tooltip, ItemIDFromTooltip(tooltip))
            end)
        end
    end
end
