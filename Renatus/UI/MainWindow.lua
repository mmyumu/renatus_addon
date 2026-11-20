-- UI/MainWindow.lua: main window (/renatus), tab navigation on the left.
local _, ns = ...
local UI = ns.UI

-- Layout. The frame border (Media/frame.tga) is about 22 px wide; nothing is
-- drawn over it. The usable area of a tab stays 698 x 494.
UI.CONTENT_W = 698   -- usable width of a tab
UI.CONTENT_H = 494   -- usable height of a tab
UI.NAV_W = 188       -- width of the navigation panel
local MARGIN = 20    -- inside the frame border
local GAP = 6        -- between navigation and content
local HEADER_H = 70
local TOP = MARGIN + HEADER_H + 6
local PANEL_H = UI.CONTENT_H + 20
UI.WIDTH = MARGIN + UI.NAV_W + GAP + UI.CONTENT_W + 16 + MARGIN   -- 948
UI.HEIGHT = TOP + PANEL_H + MARGIN                                 -- 630

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

    -- Header: red banner, crest in a gold medallion, centred title.
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", MARGIN - 2, -MARGIN + 2)
    header:SetPoint("TOPRIGHT", -MARGIN + 2, -MARGIN + 2)
    header:SetHeight(HEADER_H)
    local banner = header:CreateTexture(nil, "BACKGROUND")
    banner:SetAllPoints()
    banner:SetTexture(UI.MEDIA .. "header")
    local crest = header:CreateTexture(nil, "ARTWORK")
    crest:SetSize(40, 40)
    crest:SetPoint("LEFT", 22, -2)
    crest:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    crest:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    if crest.SetMask then pcall(crest.SetMask, crest, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
    local ring = header:CreateTexture(nil, "OVERLAY")
    ring:SetSize(60, 60)
    ring:SetPoint("CENTER", crest, "CENTER")
    ring:SetTexture(UI.MEDIA .. "ring")
    local title = UI.Title(header, 30)
    title:SetPoint("TOP", 0, -8)
    title:SetJustifyH("CENTER")
    title:SetText("Chronique de la Guilde")
    f.subtitle = UI.Text(header, 12, { 0.85, 0.74, 0.55 })
    f.subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    f.subtitle:SetJustifyH("CENTER")
    f.demoBadge = UI.Text(header, 12, { 1, 0.45, 0.35 }, UI.FONT_TITLE)
    f.demoBadge:SetPoint("TOPRIGHT", -44, -12)
    f.demoBadge:SetJustifyH("RIGHT")
    f.demoBadge:SetText("MODE DÉMO")

    -- Close button: square red plate with a gold cross.
    local close = CreateFrame("Button", nil, f)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -MARGIN - 4, -MARGIN - 4)
    close:SetNormalTexture(UI.MEDIA .. "close")
    close:SetPushedTexture(UI.MEDIA .. "close")
    local closeHl = close:CreateTexture(nil, "HIGHLIGHT")
    closeHl:SetAllPoints()
    closeHl:SetColorTexture(1, 0.8, 0.4, 0.2)
    closeHl:SetBlendMode("ADD")
    close:SetFrameLevel((header:GetFrameLevel() or 1) + 5)
    close:SetScript("OnClick", function() f:Hide() end)
    f.close = close

    -- Navigation
    local nav = CreateFrame("Frame", nil, f)
    f.nav = nav
    nav:SetPoint("TOPLEFT", MARGIN, -TOP)
    nav:SetSize(UI.NAV_W, PANEL_H)
    UI.Skin(nav, "panel")

    -- Content
    local content = CreateFrame("Frame", nil, f)
    f.content = content
    content:SetPoint("TOPLEFT", MARGIN + UI.NAV_W + GAP, -TOP)
    content:SetSize(UI.CONTENT_W + 16, PANEL_H)
    UI.Skin(content, "panel")

    -- Navigation: the three main features (tab.group == "main") in large, then
    -- the journals in a smaller section. Settings live in the game's Options.
    f.navButtons, f.containers = {}, {}
    local y = 10
    local journals
    for _, tab in ipairs(UI.tabs) do
        local main = tab.group == "main"
        if not main and not journals then
            journals = UI.Text(nav, 11, { 0.85, 0.66, 0.36 })
            journals:SetPoint("TOPLEFT", 14, -(y + 10))
            journals:SetText("JOURNAUX")
            local line = nav:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(0.85, 0.66, 0.28, 0.5)
            line:SetHeight(1)
            line:SetPoint("LEFT", journals, "RIGHT", 6, 0)
            line:SetPoint("RIGHT", nav, "RIGHT", -12, 0)
            y = y + 30
            f.journalsLabel = journals
        end
        local h, iconSize, textSize = main and 52 or 32, main and 36 or 22, main and 17 or 13
        local b = CreateFrame("Button", nil, nav)
        b:SetSize(UI.NAV_W - 12, h)
        b:SetPoint("TOPLEFT", 6, -y)
        y = y + h + (main and 6 or 3)
        -- Selected tab: red glow with a gold bar; hover: the same, fainter.
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(UI.MEDIA .. "navsel")
        hl:SetAlpha(0.35)
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetAllPoints()
        b.sel:SetTexture(UI.MEDIA .. "navsel")
        local sep = b:CreateTexture(nil, "BACKGROUND", nil, -1)
        sep:SetPoint("BOTTOMLEFT", 4, -2)
        sep:SetPoint("BOTTOMRIGHT", -4, -2)
        sep:SetHeight(1)
        sep:SetColorTexture(0.45, 0.26, 0.14, 0.45)
        local icon = UI.Icon(b, iconSize, tab.icon)
        icon:SetPoint("LEFT", 10, 0)
        local rim = CreateFrame("Frame", nil, b)
        rim:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        rim:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        UI.Edges(rim, { 0.62, 0.47, 0.24, 1 })
        b.text = UI.Text(b, textSize, UI.C.gold, main and UI.FONT_TITLE or nil)
        b.text:SetShadowOffset(1, -1)
        b.text:SetPoint("LEFT", icon, "RIGHT", 10, 0)
        b.text:SetPoint("RIGHT", -4, 0)
        -- Large entries may take two lines ("Tableau de chasse").
        b.text:SetWordWrap(main)
        if main and b.text.SetMaxLines then b.text:SetMaxLines(2) end
        b.text:SetJustifyV("MIDDLE")
        b.text:SetText(tab.label)
        -- Something new in this tab (UI/Notifier.lua): a pip on the right.
        b.badge = UI.Badge(b, main and 20 or 16)
        b.badge:SetPoint("RIGHT", -8, 0)
        b.text:SetPoint("RIGHT", b.badge, "LEFT", -4, 0)
        b:SetScript("OnClick", function() UI.Click(); UI.ShowTab(tab.key) end)
        f.navButtons[tab.key] = b

        local c = CreateFrame("Frame", nil, content)
        c:SetPoint("TOPLEFT", 8, -10)
        c:SetSize(UI.CONTENT_W, UI.CONTENT_H)
        c:Hide()
        f.containers[tab.key] = c
    end

    -- Settings: in Esc > Options > AddOns > Renatus.
    f.options = UI.Button(nav, "Options", 84, 22, function() UI.Options.Open() end)
    f.options:SetPoint("BOTTOMRIGHT", -10, 10)
    UI.Tooltip(f.options, "Options", { "Réglages de Renatus : confidentialité, minicarte, voix.",
        "Aussi dans Échap > Options > AddOns > Renatus." })

    local version = UI.Text(nav, 10, UI.C.dim)
    version:SetPoint("BOTTOMLEFT", 12, 14)
    version:SetText("v" .. ns.version)

    window = f
    f:Hide()
    return f
end

function UI.GetWindow() return window or build() end

UI.DEFAULT_TAB = "gazette"

local function tabByKey(key)
    local default
    for _, t in ipairs(UI.tabs) do
        if t.key == key then return t end
        if t.key == UI.DEFAULT_TAB then default = t end
    end
    return default or UI.tabs[1]
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
        local b = f.navButtons[k]
        b.sel:SetShown(k == tab.key)
        if k == tab.key then b.text:SetTextColor(1, 1, 1)
        else b.text:SetTextColor(UI.C.gold[1], UI.C.gold[2], UI.C.gold[3]) end
    end
    local c = f.containers[tab.key]
    if not c.built then
        tab.build(c)
        c.built = true
    end
    UI.current = tab.key
    ns.char.ui.tab = tab.key
    if tab.refresh then tab.refresh(c) end
    ns.EventBus.Publish("UI_TAB_SHOWN", tab.key)
end

-- Pip on a navigation entry (nil hides it). No-op until the window exists.
function UI.SetNavBadge(key, text)
    local b = window and window.navButtons[key]
    if b then b.badge:Set(text) end
end

function UI.Refresh()
    if not window or not window:IsShown() then return end
    UI.RefreshHeader()
    UI.ShowTab(UI.current)
end

-- Former tabs now in the game's Options.
local IN_OPTIONS = { settings = true, voice = true }

function UI.Open(key)
    if IN_OPTIONS[key] then return UI.Options.Open(key) end
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
