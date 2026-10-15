-- Window: a browser for the database, opened with /us or from the Ul
-- minimap button's menu (owned by UlRemedyForever, see below).
--
-- Left: a search box and every item that has been looted, with how many
-- sources it has. Right: the selected item's sources, all of them, each
-- with its count, rate, zone, newest point and last seen; hovering a
-- source lists every zone it was seen in. Bottom: the settings as
-- checkboxes, the tooltip line count, the stats line, and the two forget
-- buttons, both behind a confirmation. Escape closes it, it can be
-- dragged, and it refreshes itself when loot comes in while it is open.
--
-- Built from BasicFrameTemplateWithInset, SearchBoxTemplate,
-- WowScrollBoxList with MinimalScrollBar, UICheckButtonTemplate and
-- UIPanelButtonTemplate, the same templates UlRemedyForever's inventory
-- browser uses, all verified on the Forever client.
--
-- Minimap: UlRemedyForever owns the one Ul minimap button and a registry;
-- this addon calls UlRemedy.Register at PLAYER_LOGIN with its id, title,
-- icon and open function, guarded so it is simply skipped when
-- UlRemedyForever is not installed. One global is read, UlRemedy, and only
-- if it exists. No shared code, no shared saved variables.

local WIDTH, HEIGHT = 680, 480
local LEFT_W = 250
local ITEM_ROW_H = 20
local SOURCE_ROW_H = 34
local ICON = "Interface\\AddOns\\UlSource\\media\\icon"
local QUESTION_MARK = 134400

local Store = UlSource.Store
local window
local selected            -- itemID

local function QualityColor(quality)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function ItemIcon(itemID)
    if C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
        if ok and icon then return icon end
    end
    return QUESTION_MARK
end

local function ItemQuality(itemID)
    if C_Item and C_Item.GetItemQualityByID then
        local ok, q = pcall(C_Item.GetItemQualityByID, itemID)
        if ok and q then return q end
    end
    return nil
end

------------------------------------------------------------------------
-- Lists
------------------------------------------------------------------------

local function MakeScrollList(parent, rowHeight, initializer)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(rowHeight)
    view:SetElementInitializer("Button", initializer)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    return box, bar
end

local RefreshWindow   -- defined below

local function InitItemRow(button, data)
    if not button.icon then
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetSize(16, 16)
        button.icon:SetPoint("LEFT", 4, 0)
        button.name = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.name:SetPoint("LEFT", button.icon, "RIGHT", 4, 0)
        button.name:SetPoint("RIGHT", -34, 0)
        button.name:SetJustifyH("LEFT")
        button.count = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.count:SetPoint("RIGHT", -6, 0)
        button.count:SetWidth(26)
        button.count:SetJustifyH("RIGHT")
        button.sel = button:CreateTexture(nil, "BACKGROUND")
        button.sel:SetAllPoints()
        button.sel:SetColorTexture(1, 0.82, 0, 0.15)
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        button:RegisterForClicks("LeftButtonUp")
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.data.itemID) end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        button:SetScript("OnClick", function(self)
            selected = self.data.itemID
            RefreshWindow()
        end)
    end
    button.data = data
    button.icon:SetTexture(data.icon)
    button.name:SetText(data.name)
    button.name:SetTextColor(QualityColor(data.quality))
    button.count:SetText(data.count)
    button.sel:SetShown(selected == data.itemID)
end

local function InitSourceRow(button, data)
    if not button.name then
        button.name = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        button.name:SetPoint("TOPLEFT", 6, -2)
        button.name:SetPoint("RIGHT", -6, 0)
        button.name:SetJustifyH("LEFT")
        button.detail = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.detail:SetPoint("TOPLEFT", button.name, "BOTTOMLEFT", 0, -1)
        button.detail:SetPoint("RIGHT", -6, 0)
        button.detail:SetJustifyH("LEFT")
        button.detail:SetTextColor(0.8, 0.8, 0.8)
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        button:SetScript("OnEnter", function(self)
            local src = self.data
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(UlSource.SourceLabel(src), 1, 0.82, 0)
            GameTooltip:AddLine(src.key .. ", " .. src.windows .. " loot window(s), " .. src.qty .. " of this item in total", 0.8, 0.8, 0.8)
            local zones = Store.SourceZones(src.key)
            if zones and #zones > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Seen in", 1, 0.82, 0)
                for _, z in ipairs(zones) do
                    local pts = {}
                    for _, p in ipairs(z.points) do
                        pts[#pts + 1] = string.format("%.0f,%.0f", p[1] * 100, p[2] * 100)
                    end
                    GameTooltip:AddLine("  " .. z.name .. ": " .. z.n .. "x" .. (#pts > 0 and ("  " .. table.concat(pts, "  ")) or ""), 0.9, 0.9, 0.9)
                end
            end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    button.data = data
    button.name:SetText(UlSource.SourceLabel(data))
    local line = UlSource.SourceLine(data)
    -- SourceLine starts with the label; show the rest under the name.
    local label = UlSource.SourceLabel(data)
    if line:sub(1, #label + 2) == label .. ", " then line = line:sub(#label + 3) end
    button.detail:SetText(line)
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------

local function ItemList(filter)
    local dp = CreateDataProvider()
    local db = UlSource.db
    local list = {}
    for itemID, item in pairs(db.items) do
        local name = item.name or ("item " .. itemID)
        if filter == "" or name:lower():find(filter, 1, true) then
            local count = 0
            for _ in pairs(item.sources) do count = count + 1 end
            list[#list + 1] = { itemID = itemID, name = name, count = count,
                                icon = ItemIcon(itemID), quality = ItemQuality(itemID) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    for _, row in ipairs(list) do dp:Insert(row) end
    return dp, #list
end

local function SourceList(itemID)
    local dp = CreateDataProvider()
    local list, name = itemID and Store.ItemSources(itemID)
    if list then
        for _, src in ipairs(list) do dp:Insert(src) end
    end
    return dp, list and #list or 0, name
end

RefreshWindow = function()
    if not window or not window:IsShown() or not UlSource.db then return end
    local filter = (window.search:GetText() or ""):lower()
    local items, nItems = ItemList(filter)
    window.itemBox:SetDataProvider(items, true)
    if selected and not UlSource.db.items[selected] then selected = nil end
    local sources, nSources, name = SourceList(selected)
    window.sourceBox:SetDataProvider(sources, true)
    if selected then
        window.detailTitle:SetText((name or ("item " .. selected)) .. "  |cff999999" .. nSources .. " source(s)|r")
    else
        window.detailTitle:SetText(nItems > 0 and "Pick an item on the left" or "Nothing looted yet")
    end
    local st = UlSource.db.settings
    window.enabledBox:SetChecked(st.enabled)
    window.idsBox:SetChecked(st.showIDs)
    window.probeBox:SetChecked(st.probe)
    window.linesText:SetText("Tooltip lines: " .. tostring(st.lines))
    local stats = Store.Stats()
    if stats then
        window.stats:SetText(stats.sources .. " sources, " .. stats.items .. " items, " .. stats.pairs .. " pairs, "
            .. stats.learned .. " names learned")
    end
    window.forgetItem:SetEnabled(selected ~= nil)
end
UlSource.RefreshWindow = RefreshWindow

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------

local function Confirm(text, fn)
    if StaticPopup_ShowGenericConfirmation then
        StaticPopup_ShowGenericConfirmation(text, fn)
    else
        fn()
    end
end

local function CreateWindow()
    local f = CreateFrame("Frame", "UlSourceWindow", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    tinsert(UISpecialFrames, "UlSourceWindow")
    if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
    local title = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
    if title then title:SetText("UlSource: where things come from") end

    local BOTTOM_H = 58

    -- Left: search and items.
    f.search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    f.search:SetSize(LEFT_W - 24, 20)
    f.search:SetPoint("TOPLEFT", 18, -32)
    f.search:HookScript("OnTextChanged", RefreshWindow)

    local leftPanel = CreateFrame("Frame", nil, f)
    leftPanel:SetPoint("TOPLEFT", 10, -56)
    leftPanel:SetPoint("BOTTOMLEFT", 10, BOTTOM_H)
    leftPanel:SetWidth(LEFT_W)
    f.itemBox, f.itemBar = MakeScrollList(leftPanel, ITEM_ROW_H, InitItemRow)
    f.itemBox:SetPoint("TOPLEFT")
    f.itemBox:SetPoint("BOTTOMRIGHT", -14, 0)
    f.itemBar:SetPoint("TOPLEFT", f.itemBox, "TOPRIGHT", 2, 0)
    f.itemBar:SetPoint("BOTTOMLEFT", f.itemBox, "BOTTOMRIGHT", 2, 0)

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.15)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 6, 24)
    divider:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMRIGHT", 6, 0)

    -- Right: the selected item's sources.
    f.detailTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.detailTitle:SetPoint("TOPLEFT", divider, "TOPRIGHT", 12, -2)
    f.detailTitle:SetPoint("RIGHT", -24, 0)
    f.detailTitle:SetJustifyH("LEFT")

    local rightPanel = CreateFrame("Frame", nil, f)
    rightPanel:SetPoint("TOPLEFT", divider, "TOPRIGHT", 6, -24)
    rightPanel:SetPoint("BOTTOMRIGHT", -10, BOTTOM_H)
    f.sourceBox, f.sourceBar = MakeScrollList(rightPanel, SOURCE_ROW_H, InitSourceRow)
    f.sourceBox:SetPoint("TOPLEFT")
    f.sourceBox:SetPoint("BOTTOMRIGHT", -14, 0)
    f.sourceBar:SetPoint("TOPLEFT", f.sourceBox, "TOPRIGHT", 2, 0)
    f.sourceBar:SetPoint("BOTTOMLEFT", f.sourceBox, "BOTTOMRIGHT", 2, 0)

    -- Bottom: settings, stats, forget buttons.
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 10, BOTTOM_H - 4)
    line:SetPoint("BOTTOMRIGHT", -10, BOTTOM_H - 4)

    local function CheckBox(label, x, onClick)
        local box = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        box:SetSize(24, 24)
        box:SetPoint("BOTTOMLEFT", x, 30)
        if box.Text then
            box.Text:SetText(label)
            box.Text:SetFontObject("GameFontHighlightSmall")
        end
        box:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) RefreshWindow() end)
        return box
    end
    f.enabledBox = CheckBox("Recording", 12, function(v) UlSource.db.settings.enabled = v end)
    f.idsBox = CheckBox("Show IDs", 112, function(v) UlSource.db.settings.showIDs = v end)
    f.probeBox = CheckBox("Probe", 202, function(v)
        UlSource.db.settings.probe = v
        if v and UlSource.ProbeInit then UlSource.ProbeInit() end
        if not v then UlSource.db.probe = nil end
    end)

    f.linesText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.linesText:SetPoint("BOTTOMLEFT", 300, 37)
    local function Step(d)
        local st = UlSource.db.settings
        st.lines = math.max(1, math.min(10, (st.lines or 3) + d))
        RefreshWindow()
    end
    local minus = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    minus:SetSize(22, 22)
    minus:SetText("-")
    minus:SetPoint("BOTTOMLEFT", 392, 31)
    minus:SetScript("OnClick", function() Step(-1) end)
    local plus = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    plus:SetSize(22, 22)
    plus:SetText("+")
    plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    plus:SetScript("OnClick", function() Step(1) end)

    f.forgetItem = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.forgetItem:SetSize(100, 22)
    f.forgetItem:SetText("Forget item")
    f.forgetItem:SetPoint("BOTTOMRIGHT", -118, 31)
    f.forgetItem:SetScript("OnClick", function()
        local id = selected
        if not id then return end
        local item = UlSource.db.items[id]
        local name = item and item.name or ("item " .. id)
        Confirm("Forget everything UlSource knows about " .. name .. "?", function()
            Store.ClearItem(id)
            selected = nil
            RefreshWindow()
        end)
    end)
    f.forgetAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.forgetAll:SetSize(100, 22)
    f.forgetAll:SetText("Forget all")
    f.forgetAll:SetPoint("BOTTOMRIGHT", -12, 31)
    f.forgetAll:SetScript("OnClick", function()
        Confirm("Forget every source, item and learned name UlSource has recorded?", function()
            Store.ClearAll()
            selected = nil
            RefreshWindow()
        end)
    end)

    f.stats = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.stats:SetPoint("BOTTOMLEFT", 16, 12)
    f.stats:SetPoint("RIGHT", -12, 0)
    f.stats:SetJustifyH("LEFT")
    f.stats:SetTextColor(0.6, 0.6, 0.6)

    f:SetScript("OnShow", RefreshWindow)
    return f
end

function UlSource.ToggleWindow()
    if not UlSource.db then return end
    if not window then
        local ok, err = pcall(CreateWindow)
        if not ok then
            UlSource.Say("could not build the window: " .. tostring(err))
            return
        end
        window = err
    end
    if window:IsShown() then window:Hide() else window:Show() end
end

-- Called by the store after every recorded window; cheap when hidden.
function UlSource.OnDataChanged()
    if window and window:IsShown() then pcall(RefreshWindow) end
end

------------------------------------------------------------------------
-- Minimap menu registration (UlRemedyForever owns the button)
------------------------------------------------------------------------

local frame = CreateFrame("Frame", "UlSourceWindowFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self)
    if UlRemedy and type(UlRemedy.Register) == "function" then
        pcall(UlRemedy.Register, {
            id = "UlSource",
            title = "UlSource",
            icon = ICON,
            open = UlSource.ToggleWindow,
        })
    end
    self:UnregisterEvent("PLAYER_LOGIN")
end)
