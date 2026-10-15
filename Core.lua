-- UlSource core: saved variables, settings, slash commands and the Lua
-- error log. The modules (Store, Collector, Names, Tooltip, Probe) hang
-- off the UlSource table; load order is the TOC's.
--
-- Everything that could be a secret value on this client (retail 12.x UI
-- with Midnight restrictions) is passed through UlSource.Plain before it
-- is stored or printed.

UlSource = { name = "UlSource", db = nil }

local DEFAULTS = {
    enabled = true,   -- record loot and show tooltip lines
    lines   = 3,      -- sources per tooltip
    showIDs = false,  -- append the NPC or object ID to known names
    probe   = false,  -- keep the raw per-window probe records (Probe.lua)
    quiet   = false,  -- no chat line per probe record
}

local function InitDB()
    if not UlSourceDB then UlSourceDB = {} end
    UlSourceDB.settings = UlSourceDB.settings or {}
    for k, v in pairs(DEFAULTS) do
        if UlSourceDB.settings[k] == nil then UlSourceDB.settings[k] = v end
    end
    for k in pairs(UlSourceDB.settings) do
        if DEFAULTS[k] == nil then UlSourceDB.settings[k] = nil end
    end
    UlSource.db = UlSourceDB
    if not UlSourceDB.settings.probe then UlSourceDB.probe = nil end
end

function UlSource.Version()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local v = get and get(UlSource.name, "Version")
    return v and ("v" .. v) or "(unknown version)"
end

function UlSource.Say(text)
    print("|cffffcc00" .. UlSource.name .. "|r: " .. tostring(text))
end

-- A value that is safe to store in saved variables and to concatenate.
-- Secret values become the string "<secret>", so the saved file shows
-- exactly which fields the client hides. Tables are not descended.
function UlSource.Plain(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    return tostring(v)
end

-- "Creature-0-4379-0-123-299-0000A4B6C1" -> { kind = "Creature", id = 299 }.
-- GameObject, Vehicle and Pet GUIDs carry their ID in the same position.
-- Other kinds (Player, Item) get only the kind.
function UlSource.ParseGUID(guid)
    guid = UlSource.Plain(guid)
    if type(guid) ~= "string" then return { raw = guid } end
    local parts = {}
    for part in guid:gmatch("[^-]+") do parts[#parts + 1] = part end
    local kind = parts[1]
    local rec = { raw = guid, kind = kind }
    if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" or kind == "Pet" then
        rec.id = tonumber(parts[6])
    end
    return rec
end

------------------------------------------------------------------------
-- Lua error log (same approach as UlRemedyForever)
------------------------------------------------------------------------
-- The client keeps the session's Lua errors and warnings in
-- ScriptErrorsFrame.errorData and forgets them on reload. Blocked actions
-- (protected calls refused because of taint) never reach that frame; they
-- arrive as ADDON_ACTION_BLOCKED/FORBIDDEN and are counted here. Both are
-- written to UlSourceDB.errors at logout, reload and /us errors.
local MAX_LOGGED_ERRORS = 40
local blocked = {}   -- functionName -> { count, kind, stack, last }

local function Clip(text, n)
    text = UlSource.Plain(text)
    if text == nil then return nil end
    text = tostring(text):gsub("Interface[/\\]AddOns[/\\]", "")
    if #text > n then text = text:sub(1, n) .. "..." end
    return text
end

local function NoteBlocked(kind, addonName, functionName)
    if addonName ~= UlSource.name then return end
    local key = tostring(functionName or "?")
    local rec = blocked[key]
    if not rec then
        rec = { count = 0, kind = kind, stack = Clip(debugstack(3, 12, 0), 1200) }
        blocked[key] = rec
    end
    rec.count = rec.count + 1
    rec.last = date("%H:%M:%S")
end

function UlSource.DumpErrors(announce)
    if not UlSource.db then return end
    local frameData = ScriptErrorsFrame and ScriptErrorsFrame.errorData
    local list = {}
    if type(frameData) == "table" then
        local n = #frameData
        for i = math.max(1, n - MAX_LOGGED_ERRORS + 1), n do
            local e = frameData[i]
            local ok, rec = pcall(function()
                return {
                    kind = e.messageType == 1 and "warning" or "error",
                    count = tonumber(UlSource.Plain(e.count)) or 0,
                    time = UlSource.Plain(e.time),
                    message = Clip(e.message, 400),
                    stack = Clip(e.stack, 1200),
                }
            end)
            list[#list + 1] = ok and rec or { kind = "unreadable", message = tostring(rec) }
        end
    end
    local blockedList, blockedTotal = {}, 0
    for fn, rec in pairs(blocked) do
        blockedList[#blockedList + 1] = { func = fn, count = rec.count, kind = rec.kind, last = rec.last, stack = rec.stack }
        blockedTotal = blockedTotal + rec.count
    end
    table.sort(blockedList, function(a, b) return a.count > b.count end)
    UlSource.db.errors = {
        at = date("%Y-%m-%d %H:%M:%S"),
        version = UlSource.Version(),
        total = type(frameData) == "table" and #frameData or 0,
        blocked = blockedList,
        blockedTotal = blockedTotal,
        source = ScriptErrorsFrame and (type(frameData) == "table" and "ScriptErrorsFrame.errorData" or "frame without errorData") or "no ScriptErrorsFrame",
        list = list,
    }
    if announce then
        UlSource.Say("saved " .. #list .. " of " .. UlSource.db.errors.total
            .. " Lua errors and warnings (" .. UlSource.db.errors.source .. "), written to the saved variables on reload or logout.")
        for i = math.max(1, #list - 4), #list do
            local e = list[i]
            print("  " .. (e.count or 0) .. "x " .. (e.kind or "?") .. ": " .. (e.message or "?"))
        end
        print("  blocked actions this session: " .. blockedTotal)
        for i = 1, math.min(5, #blockedList) do
            local b = blockedList[i]
            print("    " .. b.count .. "x " .. b.func .. " (" .. b.kind .. ", last " .. (b.last or "?") .. ")")
        end
    end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local function OnOff(v) return v and "|cff00ff00on|r" or "|cffff4444off|r" end

local function PrintHelp()
    local st = UlSource.db.settings
    UlSource.Say(UlSource.Version() .. ". Recording " .. OnOff(st.enabled) .. ", probe " .. OnOff(st.probe) .. ". Commands:")
    print("  /us: open or close the browser window (also in the Ul minimap button's menu)")
    print("  /us <item link or ID>: everything known about an item")
    print("  /us stats: how much is known (sources, items, names)")
    print("  /us toggle: recording and tooltip lines on or off")
    print("  /us lines <1-10>: sources per tooltip (now " .. tostring(st.lines) .. ")")
    print("  /us ids: show NPC and object IDs next to known names (now " .. OnOff(st.showIDs) .. ")")
    print("  /us clear <item link or ID>: forget everything about one item")
    print("  /us clearall yes: forget everything")
    print("  /us probe: keep raw per-window records for API probing (now " .. OnOff(st.probe) .. ")")
    print("  /us probestats, /us probelast, /us probereset: look at or forget the probe records")
    print("  /us errors: save this session's Lua errors and blocked actions, print the last five")
end

local function ItemIDFrom(text)
    local id = text:match("item:(%d+)") or text:match("^(%d+)$")
    return id and tonumber(id)
end

local function PrintItem(itemID)
    local list, name = UlSource.Store.ItemSources(itemID)
    if not list then
        UlSource.Say("nothing recorded for item " .. itemID .. ".")
        return
    end
    UlSource.Say((name or ("item " .. itemID)) .. ", " .. #list .. " source(s):")
    for _, src in ipairs(list) do
        print("  " .. UlSource.SourceLine(src) .. "  [" .. src.key .. ", " .. src.qty .. " total]")
    end
end

local function PrintStats()
    local st = UlSource.Store.Stats()
    if not st then return end
    UlSource.Say(st.sources .. " sources (" .. st.named .. " with a name), " .. st.items .. " items, "
        .. st.pairs .. " item-source pairs, " .. st.learned .. " names learned in play, "
        .. st.unattributed .. " slots without a usable source.")
end

SLASH_ULSOURCE1 = "/us"
SLASH_ULSOURCE2 = "/ulsource"
SlashCmdList["ULSOURCE"] = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S+)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not UlSource.db then
        UlSource.Say("not loaded yet.")
        return
    end
    local st = UlSource.db.settings
    if cmd == "" or cmd == "show" or cmd == "window" then
        if UlSource.ToggleWindow then UlSource.ToggleWindow() else PrintHelp() end
    elseif cmd == "help" then
        PrintHelp()
    elseif cmd == "stats" then
        PrintStats()
    elseif cmd == "toggle" then
        st.enabled = not st.enabled
        UlSource.Say("recording and tooltip lines " .. OnOff(st.enabled) .. ".")
    elseif cmd == "lines" then
        local n = tonumber(rest)
        if n and n >= 1 and n <= 10 then
            st.lines = math.floor(n)
            UlSource.Say("showing up to " .. st.lines .. " sources per tooltip.")
        else
            UlSource.Say("/us lines <1-10>")
        end
    elseif cmd == "ids" then
        st.showIDs = not st.showIDs
        UlSource.Say("IDs next to names " .. OnOff(st.showIDs) .. ".")
    elseif cmd == "clear" then
        local id = ItemIDFrom(rest)
        if not id then
            UlSource.Say("/us clear <item link or ID>")
        elseif UlSource.Store.ClearItem(id) then
            UlSource.Say("forgot item " .. id .. ".")
        else
            UlSource.Say("nothing recorded for item " .. id .. ".")
        end
    elseif cmd == "clearall" then
        if rest:lower() == "yes" then
            UlSource.Store.ClearAll()
            UlSource.Say("forgot everything.")
        else
            UlSource.Say("this forgets every source, item and learned name. Type /us clearall yes to do it.")
        end
    elseif cmd == "probe" then
        st.probe = not st.probe
        if st.probe and UlSource.ProbeInit then UlSource.ProbeInit() end
        if not st.probe then UlSource.db.probe = nil end
        UlSource.Say("probe records " .. OnOff(st.probe) .. (st.probe and ". Raw loot windows go to UlSourceDB.probe." or ". Probe data dropped."))
    elseif cmd == "probestats" then
        if UlSource.ProbeSummary then UlSource.ProbeSummary() end
    elseif cmd == "probelast" then
        if UlSource.ProbePrintLast then UlSource.ProbePrintLast() end
    elseif cmd == "probereset" then
        if UlSource.ProbeReset then UlSource.ProbeReset() end
    elseif cmd == "quiet" then
        st.quiet = not st.quiet
        UlSource.Say("probe chat line " .. OnOff(not st.quiet) .. ".")
    elseif cmd == "errors" then
        local ok, err = pcall(UlSource.DumpErrors, true)
        if not ok then UlSource.Say("could not read the error list: " .. tostring(err)) end
    else
        local id = ItemIDFrom(msg)
        if id then PrintItem(id) else PrintHelp() end
    end
end

local frame = CreateFrame("Frame", "UlSourceCoreFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        pcall(NoteBlocked, event == "ADDON_ACTION_BLOCKED" and "blocked" or "forbidden", arg1, arg2)
    elseif event == "ADDON_LOADED" and arg1 == UlSource.name then
        InitDB()
        UlSource.Store.Init()
        if UlSource.db.settings.probe and UlSource.ProbeInit then UlSource.ProbeInit() end
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGOUT" then
        -- Also fires on /reload: the error list is about to be lost.
        pcall(UlSource.DumpErrors, false)
    elseif event == "PLAYER_LOGIN" then
        UlSource.Say(UlSource.Version() .. " loaded. |cffffcc00/us|r for commands.")
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)
