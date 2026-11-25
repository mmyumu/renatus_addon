-- UI/Notifier.lua: "something new" notices.
--   * a small movable gazette icon on screen, with a red "!" pip when the gazette has
--     articles not read yet and a gold pip with the number of boosters left to open;
--     left click opens the gazette, right click the album, drag moves it;
--   * the same pips on the navigation entries of the main window.
-- An article counts as read once the gazette tab has been shown after it arrived. A
-- special issue ("hors-série") counts apart: it stays new until its own front page has
-- been shown, so that a regular issue published after it does not hide it.
local _, ns = ...
local UI = ns.UI

local N = ns:RegisterModule("Notifier", {})
UI.Notifier = N

N.ICON = UI.MEDIA .. "gazette"   -- a tilted front page (tools/make_media.py)
local SIZE = 40
local BOOSTER_COLOR = { 0.85, 0.6, 0.08 }

-- Special issues are "new" for this long after they came out (a character created
-- later is not greeted by every past one).
N.SPECIAL_NEW_DAYS = 30

-- Special issues not read yet, most recent first: published by someone else, recent,
-- and whose front page was never shown on this character. `list`: Views.Editions(ds).
function N.UnreadSpecials(ds, list)
    ds = ds or ns.Store.Dataset()
    if ds.isDemo or ds.preview then return {} end
    list = list or ns.Views.Editions(ds)
    local read = ns.char.ui.specialsRead or {}
    local recent = ns.Views.Now() - N.SPECIAL_NEW_DAYS * 86400
    local out = {}
    for _, e in ipairs(list) do
        local mine = e.layout and e.layout.a == ds.me
        if e.special and not read[e.key] and not mine and (e.t or 0) >= recent then out[#out + 1] = e end
    end
    return out
end

function N.MarkSpecialRead(edition, ds)
    ds = ds or ns.Store.Dataset()
    if ds.isDemo or ds.preview or not (edition and edition.special) then return end
    local read = ns.char.ui.specialsRead or {}
    ns.char.ui.specialsRead = read
    if not read[edition.key] then
        read[edition.key] = true
        N:Schedule()
    end
end

-- Current notices: { gazette = number of unread articles of regular issues, specials =
-- special issues not read yet, boosters = number to open }. Own articles (the officer
-- who published them) are never "new". The demo dataset has no reading history: only
-- its boosters count.
function N.Notices(ds)
    ds = ds or ns.Store.Dataset()
    local unread = 0
    local specials = {}
    if not ds.isDemo then
        local seen = ns.char.ui.gazetteSeen or 0
        for _, a in ipairs(ds.articles or {}) do
            if (a.t or 0) > seen and not (a.ev and a.ev.a == ds.me) and not ns.Views.IsSpecialKey(a.edition) then
                unread = unread + 1
            end
        end
        specials = N.UnreadSpecials(ds)
    end
    local trades = (not ds.isDemo and ns.Trade) and #ns.Trade.Incoming(ds) or 0
    return { gazette = unread, specials = specials, boosters = ds.boosters or 0, trades = trades }
end

-- Everything published so far counts as read.
function N.MarkGazetteRead(ds)
    ds = ds or ns.Store.Dataset()
    if ds.isDemo then return end
    local latest = ns.char.ui.gazetteSeen or 0
    for _, a in ipairs(ds.articles or {}) do
        if (a.t or 0) > latest then latest = a.t end
    end
    ns.char.ui.gazetteSeen = latest
end

-- Readers' letters of an issue not read yet: neither shown on its mail page on this
-- character nor written by the player. Tracked by letter id, not by time: a letter
-- can reach us by sync long after it was written.
function N.UnreadLetters(edition, ds)
    ds = ds or ns.Store.Dataset()
    if ds.isDemo or ds.preview or not edition then return 0 end
    local read = ns.char.ui.lettersRead or {}
    local n = 0
    for _, l in ipairs(edition.letters or {}) do
        if l.id ~= nil and not read[l.id] and not (l.ev and l.ev.a == ds.me) then n = n + 1 end
    end
    return n
end

function N.MarkLettersRead(edition, ds)
    ds = ds or ns.Store.Dataset()
    if ds.isDemo or not edition then return end
    local read = ns.char.ui.lettersRead or {}
    ns.char.ui.lettersRead = read
    for _, l in ipairs(edition.letters or {}) do
        if l.id ~= nil then read[l.id] = true end
    end
end

local function pipText(n) return n > 0 and (n > 9 and "9+" or tostring(n)) or nil end

local function windowOn(key)
    local f = RenatusMainFrame
    return f and f:IsShown() and UI.current == key
end

local function onClick(_, button)
    UI.Click()
    local key = button == "RightButton" and "album" or "gazette"
    if windowOn(key) then RenatusMainFrame:Hide() else UI.Open(key) end
end

local function tooltip()
    local n = N.last or { gazette = 0, specials = {}, boosters = 0, trades = 0 }
    local lines = {}
    for _, e in ipairs(n.specials or {}) do
        lines[#lines + 1] = { "Hors-série paru : « " .. e.special .. " » !", 1, 0.45, 0.35 }
    end
    if n.gazette > 0 then
        lines[#lines + 1] = { n.gazette > 1 and (n.gazette .. " nouveaux articles dans la gazette !")
            or "Un nouvel article dans la gazette !", 1, 0.45, 0.35 }
    elseif #(n.specials or {}) == 0 then
        lines[#lines + 1] = "Rien de neuf dans la gazette."
    end
    if n.boosters > 0 then
        lines[#lines + 1] = { n.boosters > 1 and (n.boosters .. " boosters à ouvrir dans l'album.")
            or "Un booster à ouvrir dans l'album.", 1, 0.82, 0.2 }
    end
    if (n.trades or 0) > 0 then
        lines[#lines + 1] = { n.trades > 1 and (n.trades .. " offres d'échange de cartes attendent ta réponse.")
            or "Une offre d'échange de cartes attend ta réponse.", 1, 0.82, 0.2 }
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = { "Clic gauche : la gazette", 0.6, 0.6, 0.6 }
    lines[#lines + 1] = { "Clic droit : l'album", 0.6, 0.6, 0.6 }
    lines[#lines + 1] = { "Glisser : déplacer", 0.6, 0.6, 0.6 }
    return "Renatus", lines
end

local function savePosition(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    ns.char.ui.widgetPoint = { point, relPoint, x, y }
end

local function build()
    local b = CreateFrame("Button", "RenatusGazetteWidget", UIParent)
    b:SetSize(SIZE, SIZE)
    local p = ns.char.ui.widgetPoint
    if p then b:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else b:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -260, -24) end
    b:SetFrameStrata("MEDIUM")
    b:SetClampedToScreen(true)
    b:SetMovable(true)
    b:EnableMouse(true)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self) GameTooltip:Hide(); self:StartMoving() end)
    b:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition(self) end)
    b:SetScript("OnClick", onClick)

    -- Halo that breathes while there is something new.
    local glow = b:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("TOPLEFT", -14, 14)
    glow:SetPoint("BOTTOMRIGHT", 14, -14)
    glow:SetTexture(UI.MEDIA .. "glow")
    glow:SetBlendMode("ADD")
    glow:Hide()
    b.glow = glow

    -- The front page fills the button (it carries its own shadow); hover lights it up.
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(N.ICON)
    b.icon = icon
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(N.ICON)
    hl:SetAlpha(0.35)
    hl:SetBlendMode("ADD")

    b.gazette = UI.Badge(b, 18)
    b.gazette:SetPoint("CENTER", b, "TOPRIGHT", -4, -4)
    b.boosters = UI.Badge(b, 18, BOOSTER_COLOR)
    b.boosters:SetPoint("CENTER", b, "BOTTOMRIGHT", -4, 4)

    local clock = 0
    b:SetScript("OnUpdate", function(_, elapsed)
        if not glow:IsShown() then return end
        clock = clock + elapsed
        glow:SetAlpha(0.45 + 0.35 * math.sin(clock * 3))
    end)
    UI.Tooltip(b, tooltip)
    return b
end

-- Recomputes the notices and updates the icon and the navigation pips.
function N:Refresh(ds)
    ds = ds or ns.Store.Dataset()
    local n = N.Notices(ds)
    N.last = n
    local gazettePip = (n.gazette > 0 or #n.specials > 0) and "!" or nil
    -- the gold pip: boosters to open and trade offers to answer, both in the album
    local boosterPip = pipText(n.boosters + (n.trades or 0))
    UI.SetNavBadge("gazette", not windowOn("gazette") and gazettePip or nil)
    UI.SetNavBadge("album", boosterPip)
    local b = self.button
    if not b then return end
    b:SetShown(ns.char.ui.showWidget and true or false)
    b.gazette:Set(gazettePip)
    b.boosters:Set(boosterPip)
    b.glow:SetShown(gazettePip ~= nil or boosterPip ~= nil)
end

-- Many events can arrive at once (sync): one recomputation every 2 seconds at most.
local pending = false
function N:Schedule()
    if pending then return end
    pending = true
    C_Timer.After(2, function() pending = false; N:Refresh() end)
end

function N:Update() self:Refresh() end

function N:OnLogin()
    self.button = build()
    self:Refresh()
end

ns.EventBus.Subscribe("CHRONICLE_EVENT", function() N:Schedule() end)
ns.EventBus.Subscribe("UI_TAB_SHOWN", function(key)
    local ds = ns.Store.Dataset()
    if key == "gazette" then N.MarkGazetteRead(ds) end
    N:Refresh(ds)
end)
