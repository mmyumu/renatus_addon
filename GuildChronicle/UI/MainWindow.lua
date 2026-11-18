-- UI/MainWindow.lua : fenetre principale (/chronicle), navigation par onglets a gauche.
local _, ns = ...
local UI = ns.UI

UI.WIDTH, UI.HEIGHT = 900, 580
UI.NAV_W = 168
UI.CONTENT_W = UI.WIDTH - UI.NAV_W - 34      -- 698
UI.CONTENT_H = UI.HEIGHT - 86                -- 494

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
    local f = CreateFrame("Frame", "GuildChronicleMainFrame", UIParent)
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
    UI.Box(f, UI.C.bg, { 0.75, 0.58, 0.25, 1 }, 2)
    if UISpecialFrames then table.insert(UISpecialFrames, "GuildChronicleMainFrame") end

    -- En-tete
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 2, -2)
    header:SetPoint("TOPRIGHT", -2, -2)
    header:SetHeight(52)
    UI.Box(header, { 0.2, 0.06, 0.04, 1 }, { 0.75, 0.58, 0.25, 0.6 })
    local crest = UI.Icon(header, 38, "Interface\\Icons\\INV_Misc_Book_09")
    crest:SetPoint("LEFT", 10, 0)
    local title = UI.Title(header, 24)
    title:SetPoint("TOPLEFT", crest, "TOPRIGHT", 10, 2)
    title:SetText("Chronique de la Guilde")
    f.subtitle = UI.Text(header, 12, UI.C.dim)
    f.subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    f.demoBadge = UI.Text(header, 13, UI.C.red, UI.FONT_TITLE)
    f.demoBadge:SetPoint("RIGHT", -48, 0)
    f.demoBadge:SetText("MODE DÉMO — données fictives")

    local close = CreateFrame("Button", nil, header)
    close:SetSize(26, 26)
    close:SetPoint("RIGHT", -10, 0)
    UI.Box(close, { 0.32, 0.08, 0.05, 1 }, { 0.75, 0.58, 0.25, 1 })
    local x = UI.Text(close, 14, UI.C.gold)
    x:SetPoint("CENTER", 0, 0)
    x:SetJustifyH("CENTER")
    x:SetText("X")
    close:SetScript("OnClick", function() f:Hide() end)

    -- Navigation
    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", 8, -62)
    nav:SetSize(UI.NAV_W - 8, UI.HEIGHT - 72)
    UI.Box(nav, UI.C.panel, { 0.4, 0.3, 0.16, 1 })

    -- Contenu
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", UI.NAV_W + 8, -62)
    content:SetSize(UI.CONTENT_W + 16, UI.HEIGHT - 72)
    UI.Box(content, { 0.1, 0.08, 0.06, 0.95 }, { 0.4, 0.3, 0.16, 1 })

    f.navButtons, f.containers = {}, {}
    for i, tab in ipairs(UI.tabs) do
        local b = CreateFrame("Button", nil, nav)
        b:SetSize(UI.NAV_W - 16, 40)
        b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 44)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.85, 0.4, 0.1)
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetAllPoints()
        b.sel:SetColorTexture(0.55, 0.38, 0.12, 0.55)
        local icon = UI.Icon(b, 30, tab.icon)
        icon:SetPoint("LEFT", 5, 0)
        b.text = UI.Text(b, 13, UI.C.gold)
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
    version:SetPoint("BOTTOMLEFT", 8, 8)
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

-- Les nouveaux evenements rafraichissent la fenetre si elle est ouverte (au plus 1 fois/s).
local pending = false
ns.EventBus.Subscribe("CHRONICLE_EVENT", function()
    if pending or not window or not window:IsShown() then return end
    pending = true
    C_Timer.After(1, function() pending = false; UI.Refresh() end)
end)
