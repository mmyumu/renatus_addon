-- UI/MainWindow.lua: main window (/renatus), tab navigation on the left.
local _, ns = ...
local UI = ns.UI

-- The gold dialog border is about 12 px wide: the window is a bit larger than
-- the content so that nothing is drawn over it.
UI.WIDTH, UI.HEIGHT = 912, 594
UI.NAV_W = 168
UI.CONTENT_W = 698   -- usable width of a tab
UI.CONTENT_H = 494   -- usable height of a tab
local MARGIN = 14    -- inside the gold border
local TOP = 66       -- below the header

UI.tabs = {}

-- tab = { key, label, icon, order, build(container), refresh(container) }
function UI.RegisterTab(tab)
    table.insert(UI.tabs, tab)
    table.sort(UI.tabs, function(a, b) return a.order < b.order end)
end

local window

local function savePosition(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    ns.char.ui.point = { point, relPoint, x, y }
end

local function build()
    local f = CreateFrame("Frame", "RenatusMainFrame", UIParent)
    f:SetSize(UI.WIDTH, UI.HEIGHT)
    local p = ns.char.ui.point
    if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else f:SetPoint("CENTER") end
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition(self) end)
    f:SetScript("OnHide", function() UI.CloseMenus() end)
    UI.Skin(f, "window")
    if UISpecialFrames then table.insert(UISpecialFrames, "RenatusMainFrame") end

    -- Header: dark red banner under the title, gold rule below.
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", MARGIN - 2, -MARGIN + 2)
    header:SetPoint("TOPRIGHT", -MARGIN + 2, -MARGIN + 2)
    header:SetHeight(TOP - MARGIN - 6)
    local banner = header:CreateTexture(nil, "BACKGROUND")
    banner:SetAllPoints()
    banner:SetColorTexture(0.3, 0.05, 0.03, 0.55)
    local rule = header:CreateTexture(nil, "BORDER")
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")
    rule:SetHeight(2)
    rule:SetColorTexture(0.85, 0.66, 0.28, 0.85)
    local crestFrame = header:CreateTexture(nil, "ARTWORK")
    crestFrame:SetSize(46, 46)
    crestFrame:SetPoint("LEFT", 6, 0)
    crestFrame:SetColorTexture(0.85, 0.66, 0.28, 1)
    local crest = UI.Icon(header, 42, "Interface\\Icons\\INV_Misc_Book_09")
    crest:SetDrawLayer("OVERLAY")
    crest:SetPoint("CENTER", crestFrame, "CENTER")
    local title = UI.Title(header, 26)
    title:SetPoint("TOPLEFT", crestFrame, "TOPRIGHT", 12, 0)
    title:SetText("Chronique de la Guilde")
    f.subtitle = UI.Text(header, 12, UI.C.dim)
    f.subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -3)
    f.demoBadge = UI.Text(header, 13, UI.C.red, UI.FONT_TITLE)
    f.demoBadge:SetPoint("RIGHT", -40, 0)
    f.demoBadge:SetText("MODE DÉMO — données fictives")

    -- Close button: the game's red cross on the top-right corner, flat box otherwise.
    local close = CreateFrame("Button", nil, f)
    local T = UI.TEX
    if UI.HasFile(T.closeUp) then
        close:SetSize(32, 32)
        close:SetPoint("TOPRIGHT", -4, -4)
        close:SetNormalTexture(T.closeUp)
        close:SetPushedTexture(T.closeDown)
        close:SetHighlightTexture(T.closeHighlight, "ADD")
    else
        close:SetSize(26, 26)
        close:SetPoint("TOPRIGHT", -MARGIN - 6, -MARGIN - 8)
        UI.Box(close, { 0.32, 0.08, 0.05, 1 }, { 0.75, 0.58, 0.25, 1 })
        local x = UI.Text(close, 14, UI.C.gold)
        x:SetPoint("CENTER", 0, 0)
        x:SetJustifyH("CENTER")
        x:SetText("X")
    end
    close:SetFrameLevel((header:GetFrameLevel() or 1) + 5)
    close:SetScript("OnClick", function() f:Hide() end)
    f.close = close

    -- Navigation
    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", MARGIN, -TOP)
    nav:SetSize(UI.NAV_W - 8, UI.HEIGHT - TOP - MARGIN)
    UI.Skin(nav, "panel")

    -- Content
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", MARGIN + UI.NAV_W - 4, -TOP)
    content:SetSize(UI.CONTENT_W + 16, UI.HEIGHT - TOP - MARGIN)
    UI.Skin(content, "panel")

    f.navButtons, f.containers = {}, {}
    for i, tab in ipairs(UI.tabs) do
        local b = CreateFrame("Button", nil, nav)
        b:SetSize(UI.NAV_W - 24, 40)
        b:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 44)
        -- Selected tab and hover: the gold glow of the quest log, flat colours otherwise.
        local glow = UI.HasFile(UI.TEX.glow)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        if glow then
            hl:SetTexture(UI.TEX.glow); hl:SetBlendMode("ADD"); hl:SetAlpha(0.35)
        else
            hl:SetColorTexture(1, 0.85, 0.4, 0.1)
        end
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetAllPoints()
        if glow then
            b.sel:SetTexture(UI.TEX.glow); b.sel:SetBlendMode("ADD"); b.sel:SetVertexColor(1, 0.8, 0.4)
        else
            b.sel:SetColorTexture(0.55, 0.38, 0.12, 0.55)
        end
        local icon = UI.Icon(b, 30, tab.icon)
        icon:SetPoint("LEFT", 5, 0)
        b.text = UI.Text(b, 15, UI.C.gold, UI.FONT_TITLE)
        b.text:SetShadowOffset(1, -1)
        b.text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        b.text:SetJustifyV("MIDDLE")
        b.text:SetText(tab.label)
        b:SetScript("OnClick", function() UI.Click(); UI.ShowTab(tab.key) end)
        f.navButtons[tab.key] = b

        local c = CreateFrame("Frame", nil, content)
        c:SetPoint("TOPLEFT", 8, -8)
        c:SetSize(UI.CONTENT_W, UI.CONTENT_H)
        c:Hide()
        f.containers[tab.key] = c
    end

    local version = UI.Text(nav, 10, UI.C.dim)
    version:SetPoint("BOTTOMLEFT", 10, 10)
    version:SetText("v" .. ns.version)

    window = f
    f:Hide()
    return f
end

function UI.GetWindow() return window or build() end

local function tabByKey(key)
    for _, t in ipairs(UI.tabs) do if t.key == key then return t end end
    return UI.tabs[1]
end

function UI.RefreshHeader()
    local f = UI.GetWindow()
    local ds = ns.Store.Dataset()
    local _, guildName = ns.Context.GuildKey()
    f.subtitle:SetText(ds.isDemo and ds.guildKey or (guildName and ("<" .. guildName .. ">") or "Sans guilde"))
    if ds.isDemo then f.demoBadge:Show() else f.demoBadge:Hide() end
end

function UI.ShowTab(key)
    local f = UI.GetWindow()
    local tab = tabByKey(key)
    UI.CloseMenus()
    for k, c in pairs(f.containers) do
        if k == tab.key then c:Show() else c:Hide() end
        f.navButtons[k].sel:SetShown(k == tab.key)
    end
    local c = f.containers[tab.key]
    if not c.built then
        tab.build(c)
        c.built = true
    end
    UI.current = tab.key
    ns.char.ui.tab = tab.key
    if tab.refresh then tab.refresh(c) end
end

function UI.Refresh()
    if not window or not window:IsShown() then return end
    UI.RefreshHeader()
    UI.ShowTab(UI.current)
end

function UI.Open(key)
    local f = UI.GetWindow()
    f:Show()
    UI.RefreshHeader()
    UI.ShowTab(key or UI.current or ns.char.ui.tab)
end

function UI.Toggle()
    local f = UI.GetWindow()
    if f:IsShown() then f:Hide() else UI.Open() end
end

-- New events refresh the window if it is open (at most once per second).
local pending = false
ns.EventBus.Subscribe("CHRONICLE_EVENT", function()
    if pending or not window or not window:IsShown() then return end
    pending = true
    C_Timer.After(1, function() pending = false; UI.Refresh() end)
end)
