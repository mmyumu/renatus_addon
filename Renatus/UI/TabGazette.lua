-- UI/TabGazette.lua: the satirical gazette, laid out as a newspaper.
-- One edition per week. Its pages follow the layout published with it (EDITION event,
-- drawn by UI/Newsprint.lua), or the classic front page: the most voted article in two
-- columns with a drop cap, "In brief", the other articles in a side column.
-- Clicking an article opens it in full. The admin addon can show an unpublished
-- edition here as a preview (UI.GazettePreview).
local _, ns = ...
local UI = ns.UI
local Types = ns.Types

local PAGE_W, PAGE_H = UI.CONTENT_W, UI.CONTENT_H - 32
local X0 = 22                       -- left margin of the page
local BODY_TOP = 104                -- below the masthead (page 1)
local BODY_TOP_INNER = 70           -- below the running head (pages 2+)
local BODY_BOTTOM = PAGE_H - 34     -- above the footer

local NP = UI.Newsprint
local INK, INK_DIM, RED = NP.INK, NP.INK_DIM, NP.RED
local MONTHS = { "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
    "septembre", "octobre", "novembre", "décembre" }
local DAY = 86400

-- Monday 00:00 of the week containing t, and a French label for that week.
local function weekOf(t)
    local d = date("*t", t)
    local monday = t - ((d.wday + 5) % 7) * DAY - d.hour * 3600 - d.min * 60 - d.sec
    local a, b = date("*t", monday), date("*t", monday + 6 * DAY)
    local label
    if a.month == b.month then
        label = ("Semaine du %d au %d %s %d"):format(a.day, b.day, MONTHS[b.month], b.year)
    else
        label = ("Semaine du %d %s au %d %s %d"):format(a.day, MONTHS[a.month], b.day, MONTHS[b.month], b.year)
    end
    return monday, label
end

-- A layout counts if an officer published it (same rule as guild settings). Without a
-- roster (not loaded yet, or demo/preview data) it is accepted: it only arranges articles.
local function trusted(ds, layout)
    if ds.isDemo or ds.preview or not layout.a then return true end
    local roster = ds.roster or {}
    if #roster == 0 then return true end
    return ns.GuildConfig.IsOfficerRank(ns.GuildConfig.RankOf(layout.n, layout.a))
end

-- Editions: articles grouped by week, most recent first. Inside an edition, articles
-- are ranked by votes, then editorial order, then most recent: "@1" is the front page.
-- Each edition takes the latest trusted layout published during its week.
local function editions(ds)
    local byWeek, list = {}, {}
    for _, a in ipairs(ds.articles or {}) do
        local monday, label = weekOf(a.t or 0)
        local e = byWeek[monday]
        if not e then
            e = { monday = monday, label = label, articles = {} }
            byWeek[monday] = e
            table.insert(list, e)
        end
        table.insert(e.articles, a)
    end
    table.sort(list, function(x, y) return x.monday > y.monday end)
    for i, e in ipairs(list) do
        e.number = #list - i + 1
        table.sort(e.articles, function(x, y)
            if (x.votes or 0) ~= (y.votes or 0) then return (x.votes or 0) > (y.votes or 0) end
            if (x.order or 99) ~= (y.order or 99) then return (x.order or 99) < (y.order or 99) end
            return (x.t or 0) > (y.t or 0)
        end)
    end
    for _, layout in ipairs(ds.layouts or {}) do
        local e = byWeek[(weekOf(layout.t or 0))]
        if e and (not e.layout or (layout.t or 0) > (e.layout.t or 0)) and trusted(ds, layout) then
            e.layout = layout
        end
    end
    return list
end

local function ink(fs, c) fs:SetTextColor(c[1], c[2], c[3]); fs:SetShadowOffset(0, 0); return fs end

local function rule(parent, x, y, w, h, alpha)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(INK[1], INK[2], INK[3], alpha or 0.85)
    t:SetPoint("TOPLEFT", x, -y)
    t:SetSize(w, h or 1)
    return t
end

local byline = NP.Byline

local PLACEHOLDER = {
    placeholder = true, kind = "Avis à la population", title = "Les rotatives sont à l'arrêt",
    body = "La gazette est rédigée hors du jeu par l'application Renatus Admin du rédacteur, à partir du journal de la guilde. "
        .. "Le rédacteur la publie ensuite en jeu, et les autres membres la reçoivent par la synchronisation.\n\n"
        .. "En attendant la première édition, tape /renatus demo pour feuilleter un numéro de démonstration.",
}

------------------------------------------------------------------------
-- Front page and inner pages: fixed masthead / running head, body drawn by Newsprint
------------------------------------------------------------------------
local function buildFront(c, page)
    local f = CreateFrame("Frame", nil, page)
    f:SetAllPoints()
    c.front = f
    local W = PAGE_W - 2 * X0 + 8

    -- Masthead (page 1)
    local m = CreateFrame("Frame", nil, f)
    m:SetAllPoints()
    f.mast = m
    f.topLeft = ink(UI.Text(m, 9), INK_DIM)
    f.topLeft:SetPoint("TOPLEFT", X0, -14)
    f.topRight = ink(UI.Text(m, 9), INK_DIM)
    f.topRight:SetPoint("TOPRIGHT", -X0, -14)
    f.topRight:SetJustifyH("RIGHT")
    local mast = ink(UI.Title(m, 40), INK)
    mast:SetPoint("TOP", 0, -24)
    mast:SetJustifyH("CENTER")
    mast:SetText("La Gazette de la Guilde")
    rule(m, X0 - 4, 74, W, 2)
    rule(m, X0 - 4, 78, W, 1)
    f.info = ink(UI.Text(m, 10), INK)
    f.info:SetPoint("TOP", 0, -83)
    f.info:SetJustifyH("CENTER")
    rule(m, X0 - 4, 97, W, 1)

    -- Running head (pages 2+)
    local r = CreateFrame("Frame", nil, f)
    r:SetAllPoints()
    f.running = r
    local small = ink(UI.Title(r, 20), INK)
    small:SetPoint("TOPLEFT", X0, -16)
    small:SetText("La Gazette de la Guilde")
    f.runInfo = ink(UI.Text(r, 9), INK_DIM)
    f.runInfo:SetPoint("TOPRIGHT", -X0, -22)
    f.runInfo:SetJustifyH("RIGHT")
    f.runTitle = ink(UI.Text(r, 10), RED)
    f.runTitle:SetPoint("TOPLEFT", X0, -44)
    rule(r, X0 - 4, 58, W, 2)
    rule(r, X0 - 4, 62, W, 1)

    -- Footer
    rule(f, X0 - 4, BODY_BOTTOM + 4, W, 1)
    f.footLeft = ink(UI.Text(f, 9), INK_DIM)
    f.footLeft:SetPoint("TOPLEFT", X0, -(BODY_BOTTOM + 10))
    f.footLeft:SetText("Faits vérifiés, ton inventé : chaque article cite ses sources.")
    f.footRight = ink(UI.Text(f, 9), INK_DIM)
    f.footRight:SetPoint("TOPRIGHT", -X0, -(BODY_BOTTOM + 10))
    f.footRight:SetJustifyH("RIGHT")

    f.canvas = NP.NewCanvas(f, function(a) c:Read(a) end)
end

local function refreshFront(c, ds, edition)
    local f = c.front
    local _, guildName = ns.Context.GuildKey()
    local guild = ds.isDemo and ds.guildKey or guildName
    local now = ns.Views.Now()
    local monday, weekLabel = weekOf(edition and edition.monday or now)
    local pages, placed = NP.Pages(edition)
    c.pages = pages
    if c.page > #pages then c.page = #pages end
    if c.page < 1 then c.page = 1 end
    local pg = pages[c.page]
    local number = edition and ("ÉDITION N° " .. edition.number) or "ÉDITION N° 0"
    if c.preview then number = "APERÇU, NON PUBLIÉ" end

    f.topLeft:SetText(guild and ("Le journal de <" .. guild .. ">") or "Le journal de la guilde")
    f.topRight:SetText(number)
    f.info:SetText(weekLabel .. "   ·   " .. (edition and (#edition.articles .. " article" .. (#edition.articles > 1 and "s" or "")) or "Numéro zéro")
        .. "   ·   Prix : un sou de cuivre")
    f.runInfo:SetText(number .. "  ·  " .. weekLabel)
    f.runTitle:SetText(NP.Upper(pg.title or ("Page " .. c.page)))
    f.mast:SetShown(c.page == 1)
    f.running:SetShown(c.page > 1)
    f.footRight:SetText(#pages > 1 and ("Page " .. c.page .. " sur " .. #pages) or (edition and "Page 1" or ""))

    local ctx = NP.Context(ds, edition, monday, placed)
    ctx.placeholder = PLACEHOLDER
    local top = c.page == 1 and (BODY_TOP + 4) or (BODY_TOP_INNER + 4)
    NP.Draw(f.canvas, ctx, pg, X0, top, PAGE_W - 2 * X0, BODY_BOTTOM - 2)
    -- Shortcuts (tests, keyboard-free navigation): first headline and story of the page.
    f.headline = f.canvas.headline
    f.storyHit = f.canvas.storyHit
    f.letterLink = f.canvas.letterLink
end

------------------------------------------------------------------------
-- Reading an article (or its sources)
------------------------------------------------------------------------
local function buildReader(c, page)
    local r = CreateFrame("Frame", nil, page)
    r:SetAllPoints()
    c.reader = r
    local W = 600
    local x = (PAGE_W - W) / 2
    local mast = ink(UI.Title(r, 22), INK)
    mast:SetPoint("TOP", 0, -14)
    mast:SetJustifyH("CENTER")
    mast:SetText("La Gazette de la Guilde")
    r.edition = ink(UI.Text(r, 9), INK_DIM)
    r.edition:SetPoint("TOP", 0, -42)
    r.edition:SetJustifyH("CENTER")
    rule(r, X0 - 4, 56, PAGE_W - 2 * X0 + 8, 2)
    rule(r, X0 - 4, 60, PAGE_W - 2 * X0 + 8, 1)
    r.kind = ink(UI.Text(r, 10), RED)
    r.kind:SetPoint("TOPLEFT", x, -72)
    r.title = ink(UI.Title(r, 24), INK)
    r.title:SetPoint("TOPLEFT", r.kind, "BOTTOMLEFT", 0, -4)
    r.title:SetWidth(W)
    r.meta = ink(UI.Text(r, 9), INK_DIM)
    r.meta:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -6)
    r.meta:SetWidth(W)
    local sep = r:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(INK[1], INK[2], INK[3], 0.6)
    sep:SetHeight(1)
    sep:SetWidth(W)
    sep:SetPoint("TOPLEFT", r.meta, "BOTTOMLEFT", 0, -6)
    r.body = UI.ScrollText(r, W + 8, PAGE_H - 200, 13, INK)
    r.body:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -10)
    r.body.fontString:SetShadowOffset(0, 0)
    rule(r, X0 - 4, BODY_BOTTOM + 4, PAGE_W - 2 * X0 + 8, 1)
    r.notice = ink(UI.Text(r, 9), INK_DIM)
    r.notice:SetPoint("TOPLEFT", X0, -(BODY_BOTTOM + 10))
    r.notice:SetText("Article généré à partir d'événements réels. Le ton est inventé, les faits ne le sont pas : consulte les sources.")
end

local function refreshReader(c, ds, edition, a)
    local r = c.reader
    r.edition:SetText(edition and ("Édition n° " .. edition.number .. "  ·  " .. edition.label) or "")
    r.kind:SetText(NP.Upper(a.kind or "Article"))
    r.title:SetText(a.title or "")
    r.meta:SetText(byline(a) .. "  ·  style : " .. (a.style or "?") .. "  ·  " .. #(a.refs or {}) .. " source(s)")
    if c.showSources then
        local byId = {}
        for _, ev in ipairs(ds.events) do byId[ev.id] = ev end
        local lines = { "Faits ayant servi à la rédaction de cet article :", "" }
        for _, id in ipairs(a.refs or {}) do
            local ev = byId[id]
            if ev then
                local prov = Types.PROVENANCE[ev.prov] or Types.PROVENANCE.OBS
                table.insert(lines, "• " .. UI.Date(ev.t, true) .. " — " .. Types.Describe(ev, true) .. " [" .. string.lower(prov.label) .. "]")
            else
                table.insert(lines, "• (événement " .. id .. " absent de ton journal local)")
            end
        end
        if #(a.refs or {}) == 0 then table.insert(lines, "Aucune source référencée : article d'opinion.") end
        r.body:SetText(table.concat(lines, "\n"))
    else
        r.body:SetText(NP.Markup(a.body or ""))
    end
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function build(c)
    local page = CreateFrame("Frame", nil, c)
    page:SetPoint("TOPLEFT", 0, 0)
    page:SetSize(PAGE_W, PAGE_H)
    UI.Skin(page, "parchment")
    c.paper = page
    buildFront(c, page)
    buildReader(c, page)
    UI.gazette = c

    -- Toolbar under the page.
    local barY = -(PAGE_H + 8)
    c.prev = UI.Button(c, "‹", 30, 22, function() c.edition = c.edition + 1; c.page = 1; c.reading = nil; c:Refresh() end)
    c.prev:SetPoint("TOPLEFT", 0, barY)
    UI.Tooltip(c.prev, "Édition précédente")
    c.next = UI.Button(c, "›", 30, 22, function() c.edition = c.edition - 1; c.page = 1; c.reading = nil; c:Refresh() end)
    c.next:SetPoint("LEFT", c.prev, "RIGHT", 4, 0)
    UI.Tooltip(c.next, "Édition suivante")
    c.pagePrev = UI.Button(c, "‹ Page", 70, 22, function() c.page = c.page - 1; c:Refresh() end)
    c.pagePrev:SetPoint("LEFT", c.next, "RIGHT", 12, 0)
    c.pageNext = UI.Button(c, "Page ›", 70, 22, function() c.page = c.page + 1; c:Refresh() end)
    c.pageNext:SetPoint("LEFT", c.pagePrev, "RIGHT", 4, 0)
    c.back = UI.Button(c, "‹ Retour au journal", 150, 22, function()
        c.reading = nil; c.showSources = false; c:Refresh()
    end)
    c.back:SetPoint("TOPLEFT", 0, barY)
    c.endPreview = UI.Button(c, "Quitter l'aperçu", 130, 22, function() c:SetPreview(nil) end)
    c.endPreview:SetPoint("TOPLEFT", 0, barY)

    page.letter = UI.Button(c, "Courrier des lecteurs", 160, 22, function() UI.Dialogs.Letter() end)
    page.vote = UI.Button(c, "Voter pour la une", 140, 22, function()
        local a = c.current
        if not a or a.voted or c.preview then return end
        if ns.Store.Dataset().isDemo then
            a.votes = (a.votes or 0) + 1; a.voted = true
        else
            -- One vote per member per week: the latest counts (computed in Views.Articles).
            ns.Store.Add("VOTE", { week = ns.Views.WeekKey(ns.Views.Now()) },
                { refs = { a.id }, vis = "G", prov = "MAN", noExp = true, loc = {} })
        end
        c:Refresh()
    end)
    page.sources = UI.Button(c, "Sources", 90, 22, function()
        if not c.current then return end
        c.showSources = not c.showSources
        c.reading = c.current.id
        c:Refresh()
    end)

    c.edition, c.page = 1, 1
    c:HookScript("OnHide", function() c.preview = nil end)
    function c:Read(a)
        if not a or a.placeholder then return end
        self.reading = a.id
        self.showSources = false
        self:Refresh()
    end

    -- Preview of an unpublished edition: { articles = {...}, layout = EDITION payload }, or nil.
    function c:SetPreview(p)
        self.preview = p
        self.edition, self.page, self.reading, self.showSources = 1, 1, nil, false
        self:Refresh()
    end

    function c:Dataset()
        local ds = ns.Store.Dataset()
        if not self.preview then return ds end
        local layout = NP.Sanitize(self.preview.layout)
        local t = ns.Views.Now()
        if layout then layout.t = t end
        local view = {}
        for k, v in pairs(ds) do view[k] = v end
        view.preview = true
        view.articles, view.layouts = {}, { layout }
        for i, a in ipairs(self.preview.articles or {}) do
            local copy = { votes = 0 }
            for k, v in pairs(a) do copy[k] = v end
            copy.t = t
            copy.id = copy.id or ("preview:" .. i)
            copy.order = copy.order or i
            view.articles[i] = copy
        end
        return view
    end

    function c:Refresh()
        local ds = self:Dataset()
        -- right-aligned buttons, from the right
        local right
        for _, b in ipairs({ page.letter, page.vote, page.sources }) do
            b:ClearAllPoints()
            if right then b:SetPoint("RIGHT", right, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, -(PAGE_H + 8)) end
            right = b
        end

        local list = editions(ds)
        self.editions = list
        if self.edition > #list then self.edition = math.max(1, #list) end
        if self.edition < 1 then self.edition = 1 end
        local edition = list[self.edition]

        -- Article being read, if any (it may belong to any edition).
        local reading
        if self.reading then
            for _, e in ipairs(list) do
                for _, a in ipairs(e.articles) do
                    if a.id == self.reading then reading = a; edition = e end
                end
            end
            if not reading then self.reading = nil end
        end
        self.current = reading or (edition and edition.articles[1]) or nil

        self.front:SetShown(not reading)
        self.reader:SetShown(reading ~= nil)
        self.back:SetShown(reading ~= nil)
        self.endPreview:SetShown(self.preview ~= nil and not reading)
        local browse = not reading and not self.preview
        self.prev:SetShown(browse)
        self.next:SetShown(browse)
        self.prev:SetDisabled(self.edition >= #list)
        self.next:SetDisabled(self.edition <= 1)
        page.sources:SetDisabled(self.current == nil)
        page.sources:SetLabel(self.showSources and reading and "Article" or "Sources")
        page.vote:SetDisabled(self.current == nil or self.current.voted or self.preview ~= nil)
        if reading then refreshReader(self, ds, edition, reading) else refreshFront(self, ds, edition) end
        local pages = self.pages and #self.pages or 1
        local paging = not reading and pages > 1
        self.pagePrev:SetShown(paging)
        self.pageNext:SetShown(paging)
        self.pagePrev:SetDisabled(self.page <= 1)
        self.pageNext:SetDisabled(self.page >= pages)
        self.pagePrev:ClearAllPoints()
        if self.preview then
            self.pagePrev:SetPoint("LEFT", self.endPreview, "RIGHT", 12, 0)
        else
            self.pagePrev:SetPoint("LEFT", self.next, "RIGHT", 12, 0)
        end
    end
end

-- Shows an unpublished edition in the members' window (used by Renatus_Admin).
-- articles: list of { key, title, body, kind, quote, portrait, author, ia, order };
-- layout: EDITION payload (nil = classic front page).
function UI.GazettePreview(articles, layout)
    UI.Open("gazette")
    if UI.gazette then UI.gazette:SetPreview({ articles = articles or {}, layout = layout }) end
end

UI.RegisterTab({ key = "gazette", group = "main", label = "Gazette", icon = "Interface\\Icons\\INV_Misc_Note_06", order = 1,
    build = build, refresh = function(c) c:Refresh() end })
