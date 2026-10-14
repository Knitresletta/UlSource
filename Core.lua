-- UlSource core: saved variables, slash commands and the Lua error log.
--
-- Probe build (0.1.x): there is no feature yet. Probe.lua writes raw loot
-- data to UlSourceDB.probe so the Forever loot API can be read from the
-- saved variables file after a play session. Everything that could be a
-- secret value on this client (retail 12.x UI with Midnight restrictions)
-- is passed through UlSource.Plain before it is stored or printed.

UlSource = { name = "UlSource", db = nil }

local DEFAULTS = {
    quiet = false,   -- no chat line per loot window
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

local function PrintHelp()
    UlSource.Say(UlSource.Version() .. " probe build. Commands:")
    print("  /us probe: what the probe has recorded so far (loot windows, kills, missing API)")
    print("  /us last: print the last recorded loot window in detail")
    print("  /us quiet: toggle the chat line per loot window")
    print("  /us probereset: forget all probe data")
    print("  /us errors: save this session's Lua errors and blocked actions, print the last five")
end

SLASH_ULSOURCE1 = "/us"
SLASH_ULSOURCE2 = "/ulsource"
SlashCmdList["ULSOURCE"] = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if not UlSource.db then
        UlSource.Say("not loaded yet.")
        return
    end
    if cmd == "probe" then
        if UlSource.ProbeSummary then UlSource.ProbeSummary() end
    elseif cmd == "last" then
        if UlSource.ProbePrintLast then UlSource.ProbePrintLast() end
    elseif cmd == "quiet" then
        UlSource.db.settings.quiet = not UlSource.db.settings.quiet
        UlSource.Say("chat line per loot window " .. (UlSource.db.settings.quiet and "off" or "on") .. ".")
    elseif cmd == "probereset" then
        if UlSource.ProbeReset then UlSource.ProbeReset() end
    elseif cmd == "errors" then
        local ok, err = pcall(UlSource.DumpErrors, true)
        if not ok then UlSource.Say("could not read the error list: " .. tostring(err)) end
    else
        PrintHelp()
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
        if UlSource.ProbeInit then UlSource.ProbeInit() end
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGOUT" then
        -- Also fires on /reload: the error list is about to be lost.
        pcall(UlSource.DumpErrors, false)
    elseif event == "PLAYER_LOGIN" then
        UlSource.Say(UlSource.Version() .. " probe build loaded. Loot windows are being recorded; |cffffcc00/us|r for commands.")
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)
