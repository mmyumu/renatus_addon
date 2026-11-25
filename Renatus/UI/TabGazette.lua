-- UI/TabGazette.lua: the satirical gazette, laid out as a newspaper.
-- One issue per publication (Views.Editions), dated; past issues are listed in the
-- archives (button "Archives" under the page). Its pages follow
-- the layout published with it (EDITION event, drawn by UI/Newsprint.lua), or the classic
-- front page: the first article in two columns with a drop cap, "In brief", the other
-- articles in a side column.
-- Clicking an article opens it in full. The admin addon can show an unpublished
-- edition here as a preview (UI.GazettePreview).
-- Special issues ("hors-série") are numbered apart and listed first in the archives;
-- the tab opens on the latest regular issue, and a glowing "Hors-série" button under the
-- page leads to a special issue not read yet (or out this week).
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
local DAY = 86400

local function ink(fs, c) fs:SetTextColor(c[1], c[2], c[3]); fs:SetShadowOffset(0, 0); return fs end

local function rule(parent, x, y, w, h, alpha)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(INK[1], INK[2], INK[3], alpha or 0.85)
    t:SetPoint("TOPLEFT", x, -y)
    t:SetSize(w, h or 1)
    return t
end

local byline = NP.Byline

-- "Édition n° 12  ·  Paru le …" or "Hors-série n° 2  ·  Spécial Noël  ·  Paru le …".
local function editionLine(e)
    if not e then return "" end
    if e.special then return "Hors-série n° " .. e.number .. "  ·  " .. e.special .. "  ·  " .. e.label end
    return "Édition n° " .. e.number .. "  ·  " .. e.label
end

-- A special issue keeps its button under the page this long after it came out.
local SPECIAL_SHOWN_DAYS = 7

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
    local label = edition and edition.label or ns.Views.DateLabel(now)
    if c.preview then label = ns.Views.DateLabel(now) end
    local pages, placed = NP.Pages(edition)
    c.pages = pages
    if c.page > #pages then c.page = #pages end
    if c.page < 1 then c.page = 1 end
    local pg = pages[c.page]
    local number = edition and ((edition.special and "HORS-SÉRIE N° " or "ÉDITION N° ") .. edition.number) or "ÉDITION N° 0"
    if c.preview then number = "APERÇU, NON PUBLIÉ" end
    local special = edition and edition.special and not c.preview
    if special then label = "« " .. edition.special .. " »   ·   " .. label end

    f.topLeft:SetText(guild and ("Le journal de <" .. guild .. ">") or "Le journal de la guilde")
    f.topRight:SetText(number)
    f.info:SetText(label .. "   ·   " .. (edition and (#edition.articles .. " article" .. (#edition.articles > 1 and "s" or "")) or "Numéro zéro")
        .. "   ·   Prix : un sou de cuivre")
    f.runInfo:SetText(number .. "  ·  " .. label)
    f.runTitle:SetText(NP.Upper(pg.title or ("Page " .. c.page)))
    f.mast:SetShown(c.page == 1)
    f.running:SetShown(c.page > 1)
    f.footRight:SetText(#pages > 1 and ("Page " .. c.page .. " sur " .. #pages) or (edition and "Page 1" or ""))

    local since, till = now - 7 * DAY, now
    if edition and not c.preview then since, till = edition.since, edition.till end
    local ctx = NP.Context(ds, edition, since, till, placed)
    ctx.placeholder = PLACEHOLDER
    if not c.preview then ctx.openMail = function() c:OpenMail() end end
    local top = c.page == 1 and (BODY_TOP + 4) or (BODY_TOP_INNER + 4)
    NP.Draw(f.canvas, ctx, pg, X0, top, PAGE_W - 2 * X0, BODY_BOTTOM - 2)
    -- Shortcuts (tests, keyboard-free navigation): first headline and story of the page.
    f.headline = f.canvas.headline
    f.storyHit = f.canvas.storyHit
    f.letterLink = f.canvas.letterLink
    if special then UI.Notifier.MarkSpecialRead(edition, ds) end
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

-- Readers' letters of an issue, on the reading page.
local function refreshMail(c, edition)
    local r = c.reader
    local letters = edition.letters or {}
    r.edition:SetText(editionLine(edition))
    r.kind:SetText("COURRIER DES LECTEURS")
    r.title:SetText(#letters > 0 and "Vos lettres à la rédaction" or "Pas encore de courrier")
    r.meta:SetText(#letters .. " lettre" .. (#letters > 1 and "s" or "") .. "  ·  publiées telles quelles, signées de leur auteur")
    local parts = {}
    for _, l in ipairs(letters) do
        parts[#parts + 1] = "## " .. tostring(l.title or "Sans objet") .. "\n" .. tostring(l.body or "")
            .. "\n— " .. tostring(l.author) .. ", le " .. ns.Views.DateLabel(l.t or 0)
    end
    if #parts == 0 then
        parts[1] = "Une remarque, un démenti, une rumeur ? Écris à la rédaction : ta lettre paraîtra ici, dans ce numéro."
    end
    r.body:SetText(NP.Markup(table.concat(parts, "\n\n")))
end

local function refreshReader(c, ds, edition, a)
    local r = c.reader
    r.edition:SetText(editionLine(edition))
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
-- Archives: every issue, most recent first, with its date
------------------------------------------------------------------------
local ARCHIVE_W = 600
local ROW_H = 42

local function plural(n, word) return n .. " " .. word .. (n > 1 and "s" or "") end

local function buildArchive(c, page)
    local r = CreateFrame("Frame", nil, page)
    r:SetAllPoints()
    c.archive = r
    local x = (PAGE_W - ARCHIVE_W) / 2
    local mast = ink(UI.Title(r, 22), INK)
    mast:SetPoint("TOP", 0, -14)
    mast:SetJustifyH("CENTER")
    mast:SetText("La Gazette de la Guilde")
    local sub = ink(UI.Text(r, 9), INK_DIM)
    sub:SetPoint("TOP", 0, -42)
    sub:SetJustifyH("CENTER")
    sub:SetText("ARCHIVES  ·  LES HORS-SÉRIES, PUIS TOUS LES NUMÉROS PARUS")
    rule(r, X0 - 4, 56, PAGE_W - 2 * X0 + 8, 2)
    rule(r, X0 - 4, 60, PAGE_W - 2 * X0 + 8, 1)
    r.list = UI.List(r, ARCHIVE_W + 14, BODY_BOTTOM - 76, ROW_H, function(row)
        row.number = ink(UI.Title(row, 15), INK)
        row.number:SetPoint("TOPLEFT", 6, -4)
        row.date = ink(UI.Text(row, 11), INK)
        row.date:SetPoint("LEFT", row.number, "RIGHT", 10, 0)
        row.count = ink(UI.Text(row, 10), INK_DIM)
        row.count:SetPoint("TOPRIGHT", -6, -7)
        row.count:SetJustifyH("RIGHT")
        row.headline = ink(UI.Text(row, 10), INK_DIM)
        row.headline:SetPoint("TOPLEFT", 6, -23)
        row.headline:SetWidth(ARCHIVE_W - 30)
        row.headline:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            if self.item then UI.Click(); c:OpenEdition(self.item.index) end
        end)
    end, function(row, item)
        local e = item.edition
        local color = item.index == c.shown and RED or INK
        row.number:SetText((e.special and "HS n° " or "N° ") .. e.number)
        row.number:SetTextColor(color[1], color[2], color[3])
        row.date:SetText(e.special and (e.special .. "  ·  " .. e.label) or e.label)
        local letters = e.letters and #e.letters or 0
        row.count:SetText(plural(#e.articles, "article") .. (letters > 0 and ("  ·  " .. plural(letters, "lettre")) or ""))
        local first = e.articles[1]
        row.headline:SetText(first and ("« " .. tostring(first.title or "") .. " »") or "")
    end)
    r.list:SetPoint("TOPLEFT", x, -70)
    r.list.empty:SetTextColor(INK_DIM[1], INK_DIM[2], INK_DIM[3])
    r.list.empty:SetShadowOffset(0, 0)
end

local function refreshArchive(c)
    -- Special issues first (most recent first): they are not lost among the dailies.
    local items = {}
    for _, special in ipairs({ true, false }) do
        for i, e in ipairs(c.editions or {}) do
            if (e.special ~= nil) == special then items[#items + 1] = { index = i, edition = e } end
        end
    end
    c.archive.list:SetItems(items, "Aucun numéro paru pour l'instant.")
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
    buildArchive(c, page)
    UI.gazette = c

    -- Toolbar under the page.
    local barY = -(PAGE_H + 8)
    c.archives = UI.Button(c, "Archives", 90, 22, function() c:OpenArchive() end)
    c.archives:SetPoint("TOPLEFT", 0, barY)
    UI.Tooltip(c.archives, "Archives", { "Tous les numéros parus, avec leur date." })
    c.pagePrev = UI.Button(c, "‹ Page", 70, 22, function() c.page = c.page - 1; c:Refresh() end)
    c.pagePrev:SetPoint("LEFT", c.archives, "RIGHT", 12, 0)
    c.pageNext = UI.Button(c, "Page ›", 70, 22, function() c.page = c.page + 1; c:Refresh() end)
    c.pageNext:SetPoint("LEFT", c.pagePrev, "RIGHT", 4, 0)
    c.back = UI.Button(c, "‹ Retour au journal", 150, 22, function()
        c.reading = nil; c.showSources = false; c.mail = false; c.browsing = false; c:Refresh()
    end)
    c.back:SetPoint("TOPLEFT", 0, barY)
    c.endPreview = UI.Button(c, "Quitter l'aperçu", 130, 22, function() c:SetPreview(nil) end)
    c.endPreview:SetPoint("TOPLEFT", 0, barY)

    -- Readers' letters: the issue's mail page, and from there, writing one.
    page.letter = UI.Button(c, "Courrier des lecteurs", 190, 22, function()
        local e = c.editions and c.editions[c.shown]
        if c.mail or not e then
            UI.Dialogs.Letter(e and e.key)
        else
            c:OpenMail()
        end
    end)
    -- New letters since the last visit of the mail page: a breathing halo and a pip.
    local halo = page.letter:CreateTexture(nil, "BACKGROUND", nil, -8)
    halo:SetPoint("TOPLEFT", -12, 10)
    halo:SetPoint("BOTTOMRIGHT", 12, -10)
    halo:SetTexture(UI.MEDIA .. "glow")
    halo:SetBlendMode("ADD")
    halo:SetVertexColor(1, 0.8, 0.35)
    halo:Hide()
    page.letter.halo = halo
    page.letter.unread = UI.Badge(page.letter, 16)
    page.letter.unread:SetPoint("CENTER", page.letter, "TOPRIGHT", -2, -2)
    local clock = 0
    page.letter:HookScript("OnUpdate", function(_, elapsed)
        if not halo:IsShown() then return end
        clock = clock + elapsed
        halo:SetAlpha(0.5 + 0.35 * math.sin(clock * 3))
    end)
    -- A special issue not read yet (or out this week): a glowing shortcut to it.
    page.special = UI.Button(c, "Hors-série", 240, 22, function()
        if page.special.index then UI.Click(); c:OpenEdition(page.special.index) end
    end)
    local shalo = page.special:CreateTexture(nil, "BACKGROUND", nil, -8)
    shalo:SetPoint("TOPLEFT", -12, 10)
    shalo:SetPoint("BOTTOMRIGHT", 12, -10)
    shalo:SetTexture(UI.MEDIA .. "glow")
    shalo:SetBlendMode("ADD")
    shalo:SetVertexColor(1, 0.45, 0.35)
    shalo:Hide()
    page.special.halo = shalo
    page.special.unread = UI.Badge(page.special, 16)
    page.special.unread:SetPoint("CENTER", page.special, "TOPRIGHT", -2, -2)
    local sclock = 0
    page.special:HookScript("OnUpdate", function(_, elapsed)
        if not shalo:IsShown() then return end
        sclock = sclock + elapsed
        shalo:SetAlpha(0.5 + 0.35 * math.sin(sclock * 3))
    end)
    page.sources = UI.Button(c, "Sources", 90, 22, function()
        if not c.current then return end
        c.showSources = not c.showSources
        c.reading = c.current.id
        c:Refresh()
    end)

    -- c.edition: the issue picked in the archives (index in c.editions), nil = the latest
    -- regular one; c.shown: the one on display.
    c.edition, c.page = nil, 1
    c:HookScript("OnHide", function() c.preview = nil; c.edition = nil end)
    function c:Read(a)
        if not a or a.placeholder then return end
        self.reading = a.id
        self.showSources = false
        self.mail = false
        self.browsing = false
        self:Refresh()
    end

    -- Archives: the list of issues; picking one shows its first page.
    function c:OpenArchive()
        if self.preview then return end
        self.browsing, self.reading, self.mail, self.showSources = true, nil, false, false
        self:Refresh()
    end

    function c:OpenEdition(i)
        self.edition, self.page = i, 1
        self.browsing, self.reading, self.mail, self.showSources = false, nil, false, false
        self:Refresh()
    end

    -- Readers' letters of the issue on display.
    function c:OpenMail()
        if self.preview then return end
        self.mail, self.reading, self.showSources, self.browsing = true, nil, false, false
        self:Refresh()
    end

    -- Preview of an unpublished edition: { articles = {...}, layout = EDITION payload }, or nil.
    function c:SetPreview(p)
        self.preview = p
        self.edition, self.page, self.reading, self.showSources, self.mail, self.browsing = nil, 1, nil, false, false, false
        self:Refresh()
    end

    function c:Dataset()
        local ds = ns.Store.Dataset()
        if not self.preview then return ds end
        local layout = NP.Sanitize(self.preview.layout)
        local t = ns.Views.Now()
        if layout then layout.t, layout.edition = t, "preview" end
        local view = {}
        for k, v in pairs(ds) do view[k] = v end
        view.preview = true
        view.articles, view.layouts = {}, { layout }
        for i, a in ipairs(self.preview.articles or {}) do
            local copy = {}
            for k, v in pairs(a) do copy[k] = v end
            copy.t = t
            copy.edition = "preview"
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
        for _, b in ipairs({ page.letter, page.sources, page.special }) do
            b:ClearAllPoints()
            if right then b:SetPoint("RIGHT", right, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, -(PAGE_H + 8)) end
            right = b
        end

        local list = ns.Views.Editions(ds)
        self.editions = list
        if self.edition and (self.edition > #list or self.edition < 1) then self.edition = nil end
        local shown = self.edition
        if not shown then
            for i, e in ipairs(list) do
                if not e.special then shown = i break end
            end
        end
        self.shown = shown or 1
        local edition = list[self.shown]

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
        local mail = self.mail and edition ~= nil and not reading and not self.preview
        if not mail then self.mail = false end
        local archive = self.browsing and not reading and not mail and not self.preview
        if not archive then self.browsing = false end

        self.front:SetShown(not reading and not mail and not archive)
        self.reader:SetShown(reading ~= nil or mail)
        self.archive:SetShown(archive)
        self.back:SetShown(reading ~= nil or mail or archive)
        self.endPreview:SetShown(self.preview ~= nil and not reading)
        self.archives:SetShown(not reading and not mail and not archive and not self.preview)
        page.sources:SetDisabled(self.current == nil)
        page.sources:SetLabel(self.showSources and reading and "Article" or "Sources")
        if archive then
            refreshArchive(self)
        elseif mail then
            refreshMail(self, edition)
            UI.Notifier.MarkLettersRead(edition, ds)
        elseif reading then
            refreshReader(self, ds, edition, reading)
        else
            refreshFront(self, ds, edition)
        end
        local letters = edition and edition.letters and #edition.letters or 0
        page.letter:SetLabel(mail and "Écrire à la rédaction"
            or (letters > 0 and ("Courrier des lecteurs (" .. letters .. ")") or "Courrier des lecteurs"))
        page.letter:SetShown(not self.preview and not archive)
        local unread = (mail or self.preview) and 0 or UI.Notifier.UnreadLetters(edition, ds)
        page.letter.halo:SetShown(unread > 0)
        page.letter.unread:Set(unread > 0 and (unread > 9 and "9+" or tostring(unread)) or nil)
        page.sources:SetShown(not mail and not archive)
        -- shortcut to a special issue: the first unread one, else one out this week
        local target, unreadSpecial
        if not self.preview and not archive and not mail and not reading then
            target = UI.Notifier.UnreadSpecials(ds, list)[1]
            unreadSpecial = target ~= nil
            if not target then
                for _, e in ipairs(list) do
                    if e.special and (e.t or 0) >= ns.Views.Now() - SPECIAL_SHOWN_DAYS * DAY then target = e break end
                end
            end
            if target == edition then target, unreadSpecial = nil, false end
        end
        page.special.index = nil
        if target then
            for i, e in ipairs(list) do if e == target then page.special.index = i end end
            local title = target.special
            if #title > 26 then
                -- cut before byte 25, on a UTF-8 character boundary
                local cut = 25
                while cut > 1 and (title:byte(cut) or 0) >= 0x80 and title:byte(cut) < 0xC0 do cut = cut - 1 end
                title = title:sub(1, cut - 1) .. "…"
            end
            page.special:SetLabel("Hors-série : " .. title)
        end
        page.special:SetShown(page.special.index ~= nil)
        page.special.halo:SetShown(unreadSpecial and true or false)
        page.special.unread:Set(unreadSpecial and "!" or nil)
        local pages = self.pages and #self.pages or 1
        local paging = not reading and not mail and not archive and pages > 1
        self.pagePrev:SetShown(paging)
        self.pageNext:SetShown(paging)
        self.pagePrev:SetDisabled(self.page <= 1)
        self.pageNext:SetDisabled(self.page >= pages)
        self.pagePrev:ClearAllPoints()
        if self.preview then
            self.pagePrev:SetPoint("LEFT", self.endPreview, "RIGHT", 12, 0)
        else
            self.pagePrev:SetPoint("LEFT", self.archives, "RIGHT", 12, 0)
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
