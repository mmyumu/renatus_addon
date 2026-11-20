-- UI/TabGazette.lua: the satirical gazette, laid out as a newspaper front page.
-- One edition per week: masthead, the front-page story (most voted article of
-- the week) in two columns with a drop cap, "In brief" from the week's events,
-- the other articles in a side column. Clicking an article opens it in full.
local _, ns = ...
local UI = ns.UI
local Types = ns.Types

local PAGE_W, PAGE_H = UI.CONTENT_W, UI.CONTENT_H - 32
local X0 = 22                       -- left margin of the page
local COL_W, COL_GAP = 202, 16      -- the front-page story's two columns
local MAIN_W = 2 * COL_W + COL_GAP  -- 420
local RULE_X = X0 + MAIN_W + 13
local RX = RULE_X + 13              -- side column
local RW = PAGE_W - 22 - RX
local BODY_TOP = 104                -- below the masthead
local BODY_BOTTOM = PAGE_H - 34     -- above the footer
local DROP_W = 36

local INK = { 0.13, 0.08, 0.05 }
local INK_DIM = { 0.38, 0.27, 0.17 }
local RED = { 0.55, 0.08, 0.05 }
local MONTHS = { "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
    "septembre", "octobre", "novembre", "décembre" }
local DAY = 86400

------------------------------------------------------------------------
-- Text flow helpers (measured with an invisible FontString)
------------------------------------------------------------------------
local function tokens(text)
    local list = {}
    for word, sep in (text or ""):gmatch("(%S+)(%s*)") do list[#list + 1] = word .. sep end
    return list
end

local function join(list, i, j)
    if j < i then return "" end
    return (table.concat(list, "", i, j):gsub("%s+$", ""))
end

-- Index of the last token (from i) that still fits in height h at the measure's width.
local function fit(m, list, i, h)
    local lo, hi = i - 1, #list
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        m:SetText(join(list, i, mid))
        if (m:GetStringHeight() or 0) <= h + 0.5 then lo = mid else hi = mid - 1 end
    end
    return lo
end

local function firstChar(text)
    return text:match("^([\1-\127\194-\244][\128-\191]*)")
end

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

-- Editions: articles grouped by week, most recent first; inside an edition,
-- the front page is the most voted article (ties: the most recent).
local function editions(articles)
    local byWeek, list = {}, {}
    for _, a in ipairs(articles) do
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
            return (x.t or 0) > (y.t or 0)
        end)
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

local function byline(a)
    local bits = {}
    if a.author then
        table.insert(bits, a.ia and ("Rédigé par IA, relu par " .. a.author) or ("Par " .. a.author))
    end
    table.insert(bits, UI.Date(a.t))
    if (a.votes or 0) > 0 then table.insert(bits, a.votes .. " vote" .. (a.votes > 1 and "s" or "") .. " pour la une") end
    return table.concat(bits, "  ·  ")
end

------------------------------------------------------------------------
-- Front page
------------------------------------------------------------------------
local function buildFront(c, page)
    local f = CreateFrame("Frame", nil, page)
    f:SetAllPoints()
    c.front = f

    f.topLeft = ink(UI.Text(f, 9), INK_DIM)
    f.topLeft:SetPoint("TOPLEFT", X0, -14)
    f.topRight = ink(UI.Text(f, 9), INK_DIM)
    f.topRight:SetPoint("TOPRIGHT", -X0, -14)
    f.topRight:SetJustifyH("RIGHT")
    local mast = ink(UI.Title(f, 40), INK)
    mast:SetPoint("TOP", 0, -24)
    mast:SetJustifyH("CENTER")
    mast:SetText("La Gazette de la Guilde")
    rule(f, X0 - 4, 74, PAGE_W - 2 * X0 + 8, 2)
    rule(f, X0 - 4, 78, PAGE_W - 2 * X0 + 8, 1)
    f.info = ink(UI.Text(f, 10), INK)
    f.info:SetPoint("TOP", 0, -83)
    f.info:SetJustifyH("CENTER")
    rule(f, X0 - 4, 97, PAGE_W - 2 * X0 + 8, 1)
    local colRule = rule(f, RULE_X, BODY_TOP + 4, 1, BODY_BOTTOM - BODY_TOP - 8, 0.6)
    f.colRule = colRule
    rule(f, X0 - 4, BODY_BOTTOM + 4, PAGE_W - 2 * X0 + 8, 1)
    f.footLeft = ink(UI.Text(f, 9), INK_DIM)
    f.footLeft:SetPoint("TOPLEFT", X0, -(BODY_BOTTOM + 10))
    f.footLeft:SetText("Faits vérifiés, ton inventé : chaque article cite ses sources.")
    f.footRight = ink(UI.Text(f, 9), INK_DIM)
    f.footRight:SetPoint("TOPRIGHT", -X0, -(BODY_BOTTOM + 10))
    f.footRight:SetJustifyH("RIGHT")

    -- Front-page story
    f.kicker = ink(UI.Text(f, 10), RED)
    f.headline = ink(UI.Title(f, 24), INK)
    f.headline:SetWidth(MAIN_W)
    f.headline:SetMaxLines(2)
    f.by = ink(UI.Text(f, 9), INK_DIM)
    f.by:SetWidth(MAIN_W)
    f.drop = ink(UI.Title(f, 46), RED)
    f.colA = ink(UI.Text(f, 11), INK)
    f.colB = ink(UI.Text(f, 11), INK)
    f.colC = ink(UI.Text(f, 11), INK)
    for _, col in ipairs({ f.colA, f.colB, f.colC }) do col:SetSpacing(2) end
    f.colA:SetWidth(COL_W - DROP_W)
    f.colB:SetWidth(COL_W)
    f.colC:SetWidth(COL_W)
    f.more = CreateFrame("Button", nil, f)
    f.more:SetSize(120, 14)
    f.more.text = ink(UI.Text(f.more, 10), RED)
    f.more.text:SetPoint("LEFT")
    f.more.text:SetText("Lire la suite ›")
    f.more:SetScript("OnClick", function() c:Read(c.current) end)
    -- The whole story block opens the article.
    f.storyHit = CreateFrame("Button", nil, f)
    f.storyHit:SetScript("OnClick", function() c:Read(c.current) end)
    UI.Tooltip(f.storyHit, "Lire l'article en entier")

    -- Invisible measuring string (same font, spacing as the columns).
    f.measure = UI.Text(f, 11)
    f.measure:SetSpacing(2)
    f.measure:SetPoint("TOPLEFT", 0, 0)
    f.measure:SetAlpha(0)

    -- In brief
    f.briefTitle = ink(UI.Text(f, 10), INK)
    f.briefTitle:SetText("EN BREF")
    f.briefRule = rule(f, 0, 0, MAIN_W, 1)
    f.brief = ink(UI.Text(f, 10), INK)
    f.brief:SetWidth(MAIN_W)
    f.brief:SetSpacing(3)

    -- Side column: other articles, figure of the week, readers' letters.
    f.sideTitle = ink(UI.Text(f, 10), INK)
    f.sideTitle:SetPoint("TOPLEFT", RX, -(BODY_TOP + 4))
    f.sideTitle:SetText("DANS CETTE ÉDITION")
    rule(f, RX, BODY_TOP + 18, RW, 1)
    f.items = {}
    for i = 1, 3 do
        local it = CreateFrame("Button", nil, f)
        it:SetWidth(RW)
        it.kicker = ink(UI.Text(it, 9), RED)
        it.kicker:SetPoint("TOPLEFT", 0, 0)
        it.title = ink(UI.Title(it, 15), INK)
        it.title:SetWidth(RW)
        it.title:SetMaxLines(3)
        it.title:SetPoint("TOPLEFT", it.kicker, "BOTTOMLEFT", 0, -3)
        it.snippet = ink(UI.Text(it, 10), INK)
        it.snippet:SetWidth(RW)
        it.snippet:SetMaxLines(3)
        it.snippet:SetPoint("TOPLEFT", it.title, "BOTTOMLEFT", 0, -4)
        it.link = ink(UI.Text(it, 10), RED)
        it.link:SetPoint("TOPLEFT", it.snippet, "BOTTOMLEFT", 0, -3)
        it.link:SetText("Lire la suite ›")
        it.rule = rule(it, 0, 0, RW, 1, 0.5)
        it:SetScript("OnClick", function(self) c:Read(self.article) end)
        f.items[i] = it
    end
    f.figure = ink(UI.Title(f, 34), RED)
    f.figureText = ink(UI.Text(f, 10), INK)
    f.figureText:SetWidth(RW - 50)
    f.figureTitle = ink(UI.Text(f, 10), INK)
    f.figureTitle:SetText("LE CHIFFRE DE LA SEMAINE")
    f.figureRule = rule(f, 0, 0, RW, 1, 0.5)
    f.letterTitle = ink(UI.Text(f, 10), INK)
    f.letterTitle:SetText("COURRIER DES LECTEURS")
    f.letterText = ink(UI.Text(f, 10), INK)
    f.letterText:SetWidth(RW)
    f.letterText:SetText("Une remarque, un démenti, une rumeur ? La rédaction lit tout, et publie ce qui l'arrange.")
    f.letterLink = CreateFrame("Button", nil, f)
    f.letterLink:SetSize(RW, 14)
    f.letterLink.text = ink(UI.Text(f.letterLink, 10), RED)
    f.letterLink.text:SetPoint("LEFT")
    f.letterLink.text:SetText("Écrire à la rédaction ›")
    f.letterLink:SetScript("OnClick", function() UI.Dialogs.Letter() end)
end

-- Lays the story out in two balanced columns, the first one starting with a drop cap.
local function layoutStory(f, text, top, maxH)
    local m = f.measure
    m:SetWidth(COL_W)
    m:SetText("A\nA\nA")
    local threeLines = m:GetStringHeight() or 42
    m:SetText("A")
    local lineH = (m:GetStringHeight() or 14) + 2

    local first = firstChar(text)
    local drop = first and (first:match("^%a") or #first > 1) and first or nil
    local toks = tokens(drop and text:sub(#first + 1) or text)
    if drop then f.drop:SetText(drop); f.drop:Show() else f.drop:Hide() end
    local indentW = drop and (COL_W - DROP_W) or COL_W
    local besideH = drop and threeLines or 0

    m:SetWidth(COL_W)
    m:SetText(join(toks, 1, #toks))
    local total = (m:GetStringHeight() or 0) + besideH * 0.2
    local colH = math.min(maxH, math.max(besideH + lineH, math.ceil(total / 2) + lineH))
    local a, b, cEnd
    while true do
        m:SetWidth(indentW)
        a = drop and fit(m, toks, 1, besideH) or 0
        m:SetWidth(COL_W)
        b = fit(m, toks, a + 1, colH - besideH - (drop and 2 or 0))
        cEnd = fit(m, toks, b + 1, colH)
        if cEnd >= #toks or colH >= maxH then break end
        colH = math.min(maxH, colH + lineH)
    end
    local overflow = cEnd < #toks
    if overflow then cEnd = fit(m, toks, b + 1, colH - lineH - 4) end

    f.colA:SetText(join(toks, 1, a))
    f.colB:SetText(join(toks, a + 1, b))
    f.colC:SetText(join(toks, b + 1, cEnd) .. (overflow and " …" or ""))
    f.drop:ClearAllPoints()
    f.drop:SetPoint("TOPLEFT", X0, -(top - 4))
    f.colA:ClearAllPoints()
    f.colA:SetPoint("TOPLEFT", X0 + DROP_W, -top)
    f.colB:ClearAllPoints()
    f.colB:SetPoint("TOPLEFT", X0, -(top + besideH + (drop and 2 or 0)))
    f.colC:ClearAllPoints()
    f.colC:SetPoint("TOPLEFT", X0 + COL_W + COL_GAP, -top)
    f.more:ClearAllPoints()
    f.more:SetPoint("TOPLEFT", X0 + COL_W + COL_GAP, -(top + colH - lineH + 2))
    f.more:SetShown(overflow)
    return colH
end

local function refreshFront(c, ds, edition)
    local f = c.front
    local _, guildName = ns.Context.GuildKey()
    local guild = ds.isDemo and ds.guildKey or guildName
    local now = ns.Views.Now()
    local monday, weekLabel = weekOf(edition and edition.monday or now)
    f.topLeft:SetText(guild and ("Le journal de <" .. guild .. ">") or "Le journal de la guilde")
    f.topRight:SetText(edition and ("ÉDITION N° " .. edition.number) or "ÉDITION N° 0")
    f.info:SetText(weekLabel .. "   ·   " .. (edition and (#edition.articles .. " article" .. (#edition.articles > 1 and "s" or "")) or "Numéro zéro")
        .. "   ·   Prix : un sou de cuivre")

    local une = edition and edition.articles[1]
    local kicker, title, by, text
    if une then
        kicker, title, by, text = string.upper(une.kind or "À la une"), une.title or "", byline(une), une.body or ""
    else
        kicker = "AVIS À LA POPULATION"
        title = "Les rotatives sont à l'arrêt"
        by = "La rédaction"
        text = "La gazette est rédigée hors du jeu par l'application Renatus Admin du rédacteur, à partir du journal de la guilde. "
            .. "Le rédacteur la publie ensuite en jeu avec le bouton « Rédaction », et les autres membres la reçoivent par la synchronisation.\n\n"
            .. "En attendant la première édition, tape /renatus demo pour feuilleter un numéro de démonstration."
    end
    f.footRight:SetText(une and "Page 1" or "")

    local y = BODY_TOP + 4
    f.kicker:SetText(kicker)
    f.kicker:ClearAllPoints()
    f.kicker:SetPoint("TOPLEFT", X0, -y)
    y = y + 15
    f.headline:SetText(title)
    f.headline:ClearAllPoints()
    f.headline:SetPoint("TOPLEFT", X0, -y)
    y = y + (f.headline:GetStringHeight() or 26) + 4
    f.by:SetText(by)
    f.by:ClearAllPoints()
    f.by:SetPoint("TOPLEFT", X0, -y)
    y = y + 18
    local storyTop = y

    -- In brief: the week's notable events (real data), if room is left.
    local briefLines = {}
    if edition or ds.isDemo then
        local events = ns.Views.Filter(ds.events or {}, { since = monday, minImportance = 3 })
        for _, ev in ipairs(events) do
            if ev.t < monday + 7 * DAY then
                table.insert(briefLines, "• " .. Types.Describe(ev, true))
            end
        end
    end
    local maxStory = BODY_BOTTOM - storyTop
    local briefRoom = #briefLines > 0 and math.min(#briefLines, 6) * 15 + 26 or 0
    local colH = layoutStory(f, text, storyTop, math.max(60, maxStory - briefRoom))
    f.storyHit:ClearAllPoints()
    f.storyHit:SetPoint("TOPLEFT", X0, -(BODY_TOP + 4))
    f.storyHit:SetSize(MAIN_W, storyTop + colH - BODY_TOP - 4)
    f.storyHit:SetShown(une ~= nil)
    f.more:SetFrameLevel((f.storyHit:GetFrameLevel() or 1) + 2)

    y = storyTop + colH + 10
    local lines = math.floor((BODY_BOTTOM - y - 22) / 15)
    if #briefLines > 0 and lines >= 1 then
        local shown = {}
        for i = 1, math.min(lines, #briefLines) do shown[i] = briefLines[i] end
        f.briefTitle:ClearAllPoints()
        f.briefTitle:SetPoint("TOPLEFT", X0, -y)
        f.briefRule:ClearAllPoints()
        f.briefRule:SetPoint("TOPLEFT", X0, -(y + 14))
        f.brief:ClearAllPoints()
        f.brief:SetPoint("TOPLEFT", X0, -(y + 20))
        f.brief:SetText(table.concat(shown, "\n"))
        f.brief:SetHeight(#shown * 15)
        f.briefTitle:Show(); f.briefRule:Show(); f.brief:Show()
    else
        f.briefTitle:Hide(); f.briefRule:Hide(); f.brief:Hide()
    end

    -- Side column
    y = BODY_TOP + 26
    local others = {}
    if edition then for i = 2, #edition.articles do others[#others + 1] = edition.articles[i] end end
    for i, it in ipairs(f.items) do
        local a = others[i]
        if a and y < BODY_BOTTOM - 90 then
            it.article = a
            it.kicker:SetText(string.upper(a.kind or "Article"))
            it.title:SetText(a.title or "")
            it.snippet:SetText((string.gsub(a.body or "", "\n+", " ")))
            local h = 12 + 3 + (it.title:GetStringHeight() or 18) + 4 + (it.snippet:GetStringHeight() or 36) + 3 + 14
            it:ClearAllPoints()
            it:SetPoint("TOPLEFT", RX, -y)
            it:SetHeight(h)
            it.rule:ClearAllPoints()
            it.rule:SetPoint("TOPLEFT", 0, -(h + 6))
            it:Show()
            y = y + h + 14
        else
            it.article = nil
            it:Hide()
        end
    end
    f.sideTitle:SetShown(#others > 0)

    -- Figure of the week: deaths in the guild.
    local deaths = 0
    for _, ev in ipairs(ds.events or {}) do
        if ev.k == "DEATH" and ev.t >= monday and ev.t < monday + 7 * DAY then deaths = deaths + 1 end
    end
    if #others == 0 then y = BODY_TOP + 4 end
    local showFigure = deaths > 0 and y < BODY_BOTTOM - 70
    if showFigure then
        f.figureTitle:ClearAllPoints(); f.figureTitle:SetPoint("TOPLEFT", RX, -y)
        f.figureRule:ClearAllPoints(); f.figureRule:SetPoint("TOPLEFT", RX, -(y + 14))
        f.figure:ClearAllPoints(); f.figure:SetPoint("TOPLEFT", RX, -(y + 20))
        f.figure:SetText(tostring(deaths))
        f.figureText:ClearAllPoints(); f.figureText:SetPoint("TOPLEFT", RX + 50, -(y + 24))
        f.figureText:SetText(deaths == 1 and "décès dans la guilde cette semaine. Un seul : la rédaction s'ennuie."
            or "décès dans la guilde cette semaine. Les esprits gardiens font des heures supplémentaires.")
        y = y + 70
    end
    f.figure:SetShown(showFigure); f.figureText:SetShown(showFigure)
    f.figureTitle:SetShown(showFigure); f.figureRule:SetShown(showFigure)

    local showLetter = y < BODY_BOTTOM - 70
    if showLetter then
        f.letterTitle:ClearAllPoints(); f.letterTitle:SetPoint("TOPLEFT", RX, -y)
        f.letterText:ClearAllPoints(); f.letterText:SetPoint("TOPLEFT", RX, -(y + 18))
        f.letterLink:ClearAllPoints(); f.letterLink:SetPoint("TOPLEFT", RX, -(y + 18 + (f.letterText:GetStringHeight() or 28) + 6))
    end
    f.letterTitle:SetShown(showLetter); f.letterText:SetShown(showLetter); f.letterLink:SetShown(showLetter)
    f.colRule:SetShown(true)
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
    r.kind:SetText(string.upper(a.kind or "Article"))
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
        r.body:SetText(a.body or "")
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

    -- Toolbar under the page.
    local barY = -(PAGE_H + 8)
    c.prev = UI.Button(c, "‹", 30, 22, function() c.edition = c.edition + 1; c.reading = nil; c:Refresh() end)
    c.prev:SetPoint("TOPLEFT", 0, barY)
    UI.Tooltip(c.prev, "Édition précédente")
    c.next = UI.Button(c, "›", 30, 22, function() c.edition = c.edition - 1; c.reading = nil; c:Refresh() end)
    c.next:SetPoint("LEFT", c.prev, "RIGHT", 4, 0)
    UI.Tooltip(c.next, "Édition suivante")
    c.back = UI.Button(c, "‹ Retour à la une", 140, 22, function()
        c.reading = nil; c.showSources = false; c:Refresh()
    end)
    c.back:SetPoint("TOPLEFT", 0, barY)

    page.letter = UI.Button(c, "Courrier des lecteurs", 160, 22, function() UI.Dialogs.Letter() end)
    page.vote = UI.Button(c, "Voter pour la une", 140, 22, function()
        local a = c.current
        if not a or a.voted then return end
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

    c.edition = 1
    function c:Read(a)
        if not a then return end
        self.reading = a.id
        self.showSources = false
        self:Refresh()
    end

    function c:Refresh()
        local ds = ns.Store.Dataset()
        -- right-aligned buttons, from the right
        local right
        for _, b in ipairs({ page.letter, page.vote, page.sources }) do
            b:ClearAllPoints()
            if right then b:SetPoint("RIGHT", right, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, -(PAGE_H + 8)) end
            right = b
        end

        local list = editions(ds.articles or {})
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
        self.prev:SetShown(not reading)
        self.next:SetShown(not reading)
        self.prev:SetDisabled(self.edition >= #list)
        self.next:SetDisabled(self.edition <= 1)
        page.sources:SetDisabled(self.current == nil)
        page.sources:SetLabel(self.showSources and reading and "Article" or "Sources")
        page.vote:SetDisabled(self.current == nil or self.current.voted)
        if reading then refreshReader(self, ds, edition, reading) else refreshFront(self, ds, edition) end
    end
end

UI.RegisterTab({ key = "gazette", group = "main", label = "Gazette", icon = "Interface\\Icons\\INV_Misc_Note_06", order = 1,
    build = build, refresh = function(c) c:Refresh() end })
