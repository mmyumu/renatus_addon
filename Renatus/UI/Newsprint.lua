-- UI/Newsprint.lua: the gazette's page layout engine.
--
-- An edition's layout is plain data (EDITION event, written by the Renatus Admin app).
-- On the wire it is a flat list of cells, to stay within the sync's nesting limit
-- (Sync/Serialize.lua: 8 levels, the event itself already uses 3):
--   p = { template = "grande_une",
--         titles = { "", "Diplomatie" },                 -- page titles (pages 2+ show theirs)
--         cells = {                                       -- in reading order
--           { pg = 1, r = 1, w = 12, h = 0.6,             -- page, row, relative width (12-column
--             b = { { t = "story", a = "@1", cols = 3 } } },  -- grid), row height share (optional)
--           { pg = 1, r = 2, w = 4, b = { { t = "portrait", a = "k1" }, { t = "figure" } } } } }
-- It becomes pages -> rows -> cells -> blocks here (N.Sanitize).
-- Block types (t) are a fixed vocabulary, see BLOCKS below. Unknown types are skipped,
-- so a layout written for a newer addon still shows what this version understands.
-- Articles are referenced by "@n" (n-th article of the edition: votes, then editorial
-- order) or by their key (p.key). An article that no block shows ends up in the
-- "contents" block, or on an extra page: nothing is ever lost.
--
-- Geometry: rows share the page height (fixed h first, the rest evenly). Inside a cell,
-- fixed blocks (quote, portrait...) take their natural height, "soft" blocks (brief,
-- contents) at most theirs, and stories fill what is left, cut with "Lire la suite".
local _, ns = ...
local UI = ns.UI
local Types = ns.Types

local N = {}
UI.Newsprint = N

N.INK = { 0.13, 0.08, 0.05 }
N.INK_DIM = { 0.38, 0.27, 0.17 }
N.RED = { 0.55, 0.08, 0.05 }
local INK, INK_DIM, RED = N.INK, N.INK_DIM, N.RED
local DAY = 86400

local GUTTER = 26        -- between cells (a vertical rule in the middle)
local ROW_GAP = 14       -- between rows (a horizontal rule in the middle)
local BLOCK_GAP = 12     -- between blocks of a cell
local COL_GAP = 14       -- between the text columns of a story
local DROP_W = 36
local BODY_SIZE = 11

N.LIMITS = { pages = 4, rows = 4, cells = 4, blocks = 6, text = 600 }

------------------------------------------------------------------------
-- Layout data: validation (it comes from the network)
------------------------------------------------------------------------
local FIELDS = {   -- block fields kept, with their type
    t = "string", a = "string", cols = "number", head = "string", drop = "boolean", kicker = "string",
    text = "string", by = "string", value = "string", label = "string", title = "string", name = "string",
    tex = "string", caption = "string", size = "number", max = "number", lines = "number",
}

local function clampN(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function cleanBlock(b)
    if type(b) ~= "table" or type(b.t) ~= "string" then return nil end
    local out = {}
    for k, kind in pairs(FIELDS) do
        local v = b[k]
        if kind == "number" and type(v) == "string" then v = tonumber(v) end
        if kind == "string" and type(v) == "number" then v = tostring(v) end
        if type(v) == kind then
            if kind == "string" then v = v:sub(1, N.LIMITS.text) end
            if kind == "number" and v ~= v then v = nil end   -- NaN
            out[k] = v
        end
    end
    return out
end

local function list(t, max)
    local out = {}
    if type(t) ~= "table" then return out end
    for i = 1, math.min(#t, max) do out[#out + 1] = t[i] end
    return out
end

-- Network payload (flat cells) -> { pages = { { title, rows = { { h, cells = { { w, blocks } } } } } } },
-- with bounded sizes, or nil if unusable.
function N.Sanitize(p)
    if type(p) ~= "table" or type(p.cells) ~= "table" then return nil end
    local pages, byPage = {}, {}
    for i = 1, math.min(#p.cells, 256) do
        local c = p.cells[i]
        local pg, r = type(c) == "table" and tonumber(c.pg), type(c) == "table" and tonumber(c.r)
        if pg and r and pg >= 1 and r >= 1 then
            local page = byPage[pg]
            if not page and #pages < N.LIMITS.pages then
                local title = type(p.titles) == "table" and p.titles[pg]
                page = { key = pg, title = type(title) == "string" and title ~= "" and title:sub(1, 60) or nil, rows = {}, byRow = {} }
                byPage[pg] = page
                pages[#pages + 1] = page
            end
            local row = page and page.byRow[r]
            if page and not row and #page.rows < N.LIMITS.rows then
                row = { key = r, cells = {} }
                page.byRow[r] = row
                page.rows[#page.rows + 1] = row
            end
            if row and #row.cells < N.LIMITS.cells then
                local blocks = {}
                for _, b in ipairs(list(c.b, N.LIMITS.blocks)) do
                    local cb = cleanBlock(b)
                    if cb then blocks[#blocks + 1] = cb end
                end
                row.cells[#row.cells + 1] = { w = clampN(tonumber(c.w) or 1, 1, 12), blocks = blocks }
                local h = tonumber(c.h)
                if h and h == h and not row.h then row.h = clampN(h, 0.1, 1) end
            end
        end
    end
    if #pages == 0 then return nil end
    table.sort(pages, function(x, y) return x.key < y.key end)
    for _, page in ipairs(pages) do
        table.sort(page.rows, function(x, y) return x.key < y.key end)
        page.byRow, page.key = nil, nil
        for _, row in ipairs(page.rows) do row.key = nil end
    end
    return { pages = pages, template = type(p.template) == "string" and p.template:sub(1, 40) or nil }
end

-- The layout used when an edition has none: the historical front page.
function N.Default()
    return { template = "classique", pages = { { rows = { { cells = {
        { w = 8, blocks = { { t = "story", a = "@1", cols = 2, drop = true }, { t = "brief" } } },
        { w = 4, blocks = { { t = "contents" }, { t = "figure" }, { t = "letters" } } },
    } } } } } }
end

-- Article referenced by a block: "@n" or a key.
function N.Resolve(edition, ref)
    if type(ref) ~= "string" or not edition then return nil end
    local n = tonumber(ref:match("^@(%d+)$"))
    if n then return edition.articles[n] end
    for _, a in ipairs(edition.articles) do
        if a.key == ref or a.id == ref then return a end
    end
    return nil
end

local SHOWS_ARTICLE = { story = true, teaser = true }

-- Final pages of an edition: its layout (or the default one), plus an extra page
-- for articles that no block shows when there is no "contents" block to list them.
function N.Pages(edition)
    local layout = edition and edition.layout or N.Default()
    local pages = {}
    for _, pg in ipairs(layout.pages) do pages[#pages + 1] = pg end
    local placed, hasContents = {}, false
    for _, pg in ipairs(pages) do
        for _, row in ipairs(pg.rows) do
            for _, cell in ipairs(row.cells) do
                for _, b in ipairs(cell.blocks) do
                    if SHOWS_ARTICLE[b.t] then
                        local a = N.Resolve(edition, b.a)
                        if a then placed[a] = true end
                    elseif b.t == "contents" then
                        hasContents = true
                    end
                end
            end
        end
    end
    local rest = {}
    for i, a in ipairs(edition and edition.articles or {}) do
        if not placed[a] then rest[#rest + 1] = "@" .. i end
    end
    if #rest > 0 and not hasContents then
        local rows = {}
        for i = 1, #rest, 2 do
            local cells = { { w = 6, blocks = { { t = "story", a = rest[i], cols = 1 } } } }
            if rest[i + 1] then cells[2] = { w = 6, blocks = { { t = "story", a = rest[i + 1], cols = 1 } } } end
            rows[#rows + 1] = { cells = cells }
        end
        for i = 1, #rows, 2 do
            pages[#pages + 1] = { title = "Suite de l'édition", rows = { rows[i], rows[i + 1] } }
        end
    end
    return pages, placed
end

------------------------------------------------------------------------
-- Text helpers
------------------------------------------------------------------------
local function tokens(text)
    local out = {}
    for word, sep in (text or ""):gmatch("(%S+)(%s*)") do out[#out + 1] = word .. sep end
    return out
end

local function join(toks, i, j)
    if j < i then return "" end
    return (table.concat(toks, "", i, j):gsub("%s+$", ""))
end

-- Index of the last token (from i) that still fits in height h at the measure's width.
local function fit(m, toks, i, h)
    local lo, hi = i - 1, #toks
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        m:SetText(join(toks, i, mid))
        if (m:GetStringHeight() or 0) <= h + 0.5 then lo = mid else hi = mid - 1 end
    end
    return lo
end

local function firstChar(text)
    return text:match("^([\1-\127\194-\244][\128-\191]*)")
end

-- string.upper leaves accented letters alone ("NéCROLOGIE"): UTF-8 French letters too.
local ACCENTS = { ["à"] = "À", ["â"] = "Â", ["ä"] = "Ä", ["ç"] = "Ç", ["é"] = "É", ["è"] = "È", ["ê"] = "Ê", ["ë"] = "Ë",
    ["î"] = "Î", ["ï"] = "Ï", ["ô"] = "Ô", ["ö"] = "Ö", ["ù"] = "Ù", ["û"] = "Û", ["ü"] = "Ü", ["ÿ"] = "Ÿ", ["œ"] = "Œ", ["æ"] = "Æ" }
function N.Upper(text)
    return (string.upper(tostring(text or "")):gsub("[\195\197][\128-\191]", ACCENTS))
end
local upper = N.Upper

local function hex(c) return UI.ColorHex(c[1], c[2], c[3]) end

-- Light markup in article bodies: a line starting with "## " is a subheading
-- (capitals, red). Each word is coloured on its own so that a subheading cut
-- between two columns keeps its colour.
function N.Markup(body)
    local out = {}
    for line in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do
        local head = line:match("^%s*##%s*(.-)%s*$")
        if head and head ~= "" then
            local words = {}
            for w in head:gmatch("%S+") do words[#words + 1] = "|c" .. hex(RED) .. upper(w) .. "|r" end
            line = table.concat(words, " ")
        end
        out[#out + 1] = line
    end
    return (table.concat(out, "\n"):gsub("\n+$", ""))
end

local function plain(body)
    return ((body or ""):gsub("^%s*##%s*", ""):gsub("\n%s*##%s*", "\n"))
end

local function byline(a)
    local bits = {}
    if a.author then
        table.insert(bits, a.ia and ("Rédigé par IA, relu par " .. a.author) or ("Par " .. a.author))
    end
    if a.t then table.insert(bits, UI.Date(a.t)) end
    if (a.votes or 0) > 0 then table.insert(bits, a.votes .. " vote" .. (a.votes > 1 and "s" or "") .. " pour la une") end
    return table.concat(bits, "  ·  ")
end
N.Byline = byline

------------------------------------------------------------------------
-- Widget pools: a page is redrawn on every refresh
------------------------------------------------------------------------
local Pool = {}
Pool.__index = Pool

function N.NewCanvas(parent, onRead)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    local cv = setmetatable({ frame = f, fs = {}, tex = {}, btn = {}, nfs = 0, ntex = 0, nbtn = 0, onRead = onRead }, Pool)
    cv.readClick = function(btn) if btn.article and cv.onRead then cv.onRead(btn.article) end end
    cv.measure = UI.Text(f, BODY_SIZE)
    cv.measure:SetPoint("TOPLEFT", 0, 0)
    cv.measure:SetAlpha(0)
    return cv
end

function Pool:Reset()
    for i = 1, self.nfs do self.fs[i]:Hide() end
    for i = 1, self.ntex do self.tex[i]:Hide() end
    for i = 1, self.nbtn do self.btn[i]:Hide() end
    self.nfs, self.ntex, self.nbtn = 0, 0, 0
    self.headline, self.storyHit, self.stories = nil, nil, {}
end

-- FontString: kind "title" (MORPHEUS) or "text".
function Pool:Text(kind, size, color, w)
    self.nfs = self.nfs + 1
    local fs = self.fs[self.nfs]
    if not fs then
        fs = UI.Text(self.frame, size)
        self.fs[self.nfs] = fs
    end
    fs:SetFont(kind == "title" and UI.FONT_TITLE or UI.FONT_BODY, size, "")
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetShadowOffset(0, 0)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetSpacing(kind == "body" and 2 or 0)
    fs:SetMaxLines(0)
    fs:SetWordWrap(true)
    fs:ClearAllPoints()
    if w then fs:SetWidth(w) end
    fs:SetText("")
    fs:Show()
    return fs
end

function Pool:Texture(layer)
    self.ntex = self.ntex + 1
    local t = self.tex[self.ntex]
    if not t then
        t = self.frame:CreateTexture(nil, "ARTWORK")
        self.tex[self.ntex] = t
    end
    t:SetDrawLayer(layer or "ARTWORK")
    t:SetTexCoord(0, 1, 0, 1)
    t:SetVertexColor(1, 1, 1, 1)
    if t.SetDesaturated then t:SetDesaturated(false) end
    t:ClearAllPoints()
    t:Show()
    return t
end

function Pool:Rule(x, y, w, h, alpha)
    local t = self:Texture("ARTWORK")
    t:SetColorTexture(INK[1], INK[2], INK[3], alpha or 0.85)
    t:SetPoint("TOPLEFT", x, -y)
    t:SetSize(w, h or 1)
    return t
end

-- Engraving look for game art on newsprint: grey, then warmed up.
function Pool:Engrave(t)
    if t.SetDesaturated then t:SetDesaturated(true) end
    t:SetVertexColor(0.86, 0.72, 0.52, 1)
end

-- Invisible button (click area); fn(article).
function Pool:Hit(x, y, w, h, article, tooltip)
    self.nbtn = self.nbtn + 1
    local b = self.btn[self.nbtn]
    if not b then
        b = CreateFrame("Button", nil, self.frame)
        b.text = UI.Text(b, 10)
        b.text:SetPoint("LEFT")
        self.btn[self.nbtn] = b
    end
    b:SetScript("OnClick", self.readClick)
    b:SetFrameLevel((self.frame:GetFrameLevel() or 1) + 2)
    b.text:SetText("")
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", x, -y)
    b:SetSize(math.max(1, w), math.max(1, h))
    b.article = article
    UI.Tooltip(b, tooltip or "Lire l'article en entier")
    b:Show()
    return b
end

-- Red "Lire la suite ›" link.
function Pool:More(x, y, article)
    local b = self:Hit(x, y, 120, 14, article)
    b.text:SetText("Lire la suite ›")
    b.text:SetTextColor(RED[1], RED[2], RED[3])
    b.text:SetShadowOffset(0, 0)
    b:SetFrameLevel((self.frame:GetFrameLevel() or 1) + 3)
    return b
end

-- Height of a text in a given font, width and spacing.
function Pool:Measure(kind, size, w, text, spacing)
    local m = self.measure
    m:SetFont(kind == "title" and UI.FONT_TITLE or UI.FONT_BODY, size, "")
    m:SetSpacing(spacing or 0)
    m:SetWidth(w)
    m:SetText(text or "")
    return m:GetStringHeight() or size
end

------------------------------------------------------------------------
-- Blocks
------------------------------------------------------------------------
-- Each block: measure(cv, ctx, b, w) -> natural height (0 = nothing to show)
-- and draw(cv, ctx, b, x, y, w, h). kind = "fixed", "soft" or "fill".
local BLOCKS = {}
N.BLOCKS = BLOCKS

local function headSize(b, w)
    local sizes = { xl = 30, l = 24, m = 18, s = 15 }
    if sizes[b.head or ""] then return sizes[b.head] end
    if w >= 560 then return 28 elseif w >= 380 then return 24 elseif w >= 250 then return 18 end
    return 15
end

local function sectionTitle(cv, label, x, y, w)
    local t = cv:Text("text", 10, INK, w)
    t:SetPoint("TOPLEFT", x, -y)
    t:SetText(upper(label))
    cv:Rule(x, y + 14, w, 1, 0.6)
    return 20
end

-- Story: kicker, headline, byline, text in 1 to 4 columns, optional drop cap.
local function storyHeader(cv, a, b, w, x, y, draw)
    local size = headSize(b, w)
    local kicker = b.kicker or (a and upper(a.kind or "À la une")) or ""
    local title = a and a.title or ""
    local by = a and byline(a) or ""
    local h = 15 + cv:Measure("title", size, w, title) + 4 + (by ~= "" and 16 or 0)
    if draw then
        local k = cv:Text("text", 10, RED, w)
        k:SetPoint("TOPLEFT", x, -y)
        k:SetText(upper(kicker))
        local head = cv:Text("title", size, INK, w)
        head:SetPoint("TOPLEFT", x, -(y + 15))
        head:SetMaxLines(3)
        head:SetText(title)
        cv.headline = cv.headline or head
        if by ~= "" then
            local by_ = cv:Text("text", 9, INK_DIM, w)
            by_:SetPoint("TOPLEFT", x, -(y + 15 + (head:GetStringHeight() or size) + 4))
            by_:SetText(by)
        end
    end
    return h
end

local function storyCols(b, w)
    local cols = b.cols and math.floor(b.cols) or (w >= 560 and 3 or w >= 380 and 2 or 1)
    cols = clampN(cols, 1, 4)
    while cols > 1 and (w - (cols - 1) * COL_GAP) / cols < 120 do cols = cols - 1 end
    return cols, (w - (cols - 1) * COL_GAP) / cols
end

-- Flows text into cols columns of width colW, at most maxH high (balanced when it fits).
-- Returns the used height and whether the text was cut.
local function flow(cv, text, drop, x, y, cols, colW, maxH)
    local m = cv.measure
    m:SetFont(UI.FONT_BODY, BODY_SIZE, "")
    m:SetSpacing(2)
    m:SetWidth(colW)
    m:SetText("A")
    local lineH = (m:GetStringHeight() or 14) + 2
    if maxH < 2 * lineH then return 0, true end
    m:SetText("A\nA\nA")
    local threeLines = m:GetStringHeight() or 42

    local first = drop and firstChar(text) or nil
    if first and not (first:match("^%a") or #first > 1) then first = nil end
    if text:sub(1, 2) == "|c" then first = nil end
    local toks = tokens(first and text:sub(#first + 1) or text)
    local besideH = first and math.min(threeLines, maxH) or 0
    local indentW = colW - DROP_W

    m:SetWidth(colW)
    m:SetText(join(toks, 1, #toks))
    local total = (m:GetStringHeight() or 0) + besideH * 0.2
    local colH = math.min(maxH, math.max(besideH + lineH, math.ceil(total / cols) + lineH))
    local cuts
    while true do
        cuts = {}
        local idx = 0
        for c = 1, cols do
            local h = colH
            if c == 1 and first then
                m:SetWidth(indentW)
                local a = fit(m, toks, idx + 1, besideH)
                cuts[#cuts + 1] = { from = idx + 1, to = a, x = x + DROP_W, y = y, w = indentW }
                idx = a
                h = colH - besideH - 2
                m:SetWidth(colW)
                local b2 = fit(m, toks, idx + 1, h)
                cuts[#cuts + 1] = { from = idx + 1, to = b2, x = x, y = y + besideH + 2, w = colW }
                idx = b2
            else
                m:SetWidth(colW)
                local e = fit(m, toks, idx + 1, h)
                cuts[#cuts + 1] = { from = idx + 1, to = e, x = x + (c - 1) * (colW + COL_GAP), y = y, w = colW }
                idx = e
            end
        end
        if idx >= #toks or colH >= maxH then break end
        colH = math.min(maxH, colH + lineH)
    end
    local last = cuts[#cuts]
    local overflow = last.to < #toks
    if overflow then
        m:SetWidth(last.w)
        last.to = fit(m, toks, last.from, (y + colH - last.y) - lineH - 4)
    end
    if first then
        local d = cv:Text("title", 46, RED)
        d:SetPoint("TOPLEFT", x, -(y - 4))
        d:SetText(first)
    end
    for i, cut in ipairs(cuts) do
        local fs = cv:Text("body", BODY_SIZE, INK, cut.w)
        fs:SetPoint("TOPLEFT", cut.x, -cut.y)
        fs:SetText(join(toks, cut.from, cut.to) .. ((overflow and i == #cuts) and " …" or ""))
    end
    return colH, overflow, last.x, y + colH - lineH + 2
end

BLOCKS.story = {
    kind = "fill",
    measure = function(cv, ctx, b, w)
        local a = ctx.article(b.a)
        if not a then return 0 end
        return storyHeader(cv, a, b, w, 0, 0, false) + 3 * 16
    end,
    draw = function(cv, ctx, b, x, y, w, h)
        local a = ctx.article(b.a)
        if not a then return end
        local top = storyHeader(cv, a, b, w, x, y, true)
        local cols, colW = storyCols(b, w)
        local text = N.Markup(a.body or "")
        local used, overflow, mx, my = flow(cv, text, b.drop ~= false, x, y + top, cols, colW, h - top)
        local hit = not a.placeholder and cv:Hit(x, y, w, top + used, a) or nil
        if overflow and not a.placeholder then cv:More(mx or x, my or (y + h - 14), a) end
        table.insert(cv.stories, { article = a, hit = hit })
        cv.storyHit = cv.storyHit or hit
    end,
}

-- Teaser: kicker, title, a few lines, link (the side-column article).
local function teaserH(cv, a, w, lines)
    local snippet = plain(a.body):gsub("\n+", " ")
    local th = math.min(cv:Measure("title", 15, w, a.title or ""), 3 * 17)
    local sh = math.min(cv:Measure("text", 10, w, snippet), lines * 12.5)
    return 12 + 3 + th + 4 + sh + 3 + 14, snippet
end

local function drawTeaser(cv, a, x, y, w, lines)
    local h, snippet = teaserH(cv, a, w, lines)
    local k = cv:Text("text", 9, RED, w)
    k:SetPoint("TOPLEFT", x, -y)
    k:SetText(upper(a.kind or "Article"))
    local t = cv:Text("title", 15, INK, w)
    t:SetMaxLines(3)
    t:SetPoint("TOPLEFT", x, -(y + 15))
    t:SetText(a.title or "")
    local s = cv:Text("text", 10, INK, w)
    s:SetMaxLines(lines)
    s:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -4)
    s:SetText(snippet)
    local link = cv:Text("text", 10, RED)
    link:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -3)
    link:SetText("Lire la suite ›")
    cv:Hit(x, y, w, h, a)
    return h
end

BLOCKS.teaser = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        local a = ctx.article(b.a)
        return a and teaserH(cv, a, w, clampN(b.lines or 3, 1, 8)) or 0
    end,
    draw = function(cv, ctx, b, x, y, w)
        local a = ctx.article(b.a)
        if a then drawTeaser(cv, a, x, y, w, clampN(b.lines or 3, 1, 8)) end
    end,
}

-- Contents: the articles that no other block shows.
local function unplaced(ctx)
    local out = {}
    for _, a in ipairs(ctx.edition and ctx.edition.articles or {}) do
        if not ctx.placed[a] then out[#out + 1] = a end
    end
    return out
end

BLOCKS.contents = {
    kind = "soft",
    measure = function(cv, ctx, b, w)
        local rest = unplaced(ctx)
        if #rest == 0 then return 0 end
        local h = 22
        for _, a in ipairs(rest) do h = h + teaserH(cv, a, w, 3) + 14 end
        return h
    end,
    draw = function(cv, ctx, b, x, y, w, h)
        local rest = unplaced(ctx)
        local top = y + sectionTitle(cv, b.title or "Dans cette édition", x, y, w) + 2
        for _, a in ipairs(rest) do
            local th = teaserH(cv, a, w, 3)
            if top + th > y + h + 1 then break end
            drawTeaser(cv, a, x, top, w, 3)
            cv:Rule(x, top + th + 6, w, 1, 0.4)
            top = top + th + 14
        end
    end,
}

-- In brief: the week's notable events.
local function briefLines(ctx, max)
    local lines = {}
    local ds, monday = ctx.ds, ctx.monday
    if not (ctx.edition or ds.isDemo) then return lines end
    local events = ns.Views.Filter(ds.events or {}, { since = monday, minImportance = 3 })
    for _, ev in ipairs(events) do
        if ev.t < monday + 7 * DAY and #lines < max then
            lines[#lines + 1] = "• " .. Types.Describe(ev, true)
        end
    end
    return lines
end

BLOCKS.brief = {
    kind = "soft",
    measure = function(cv, ctx, b, w)
        local lines = briefLines(ctx, clampN(b.max or 6, 1, 12))
        if #lines == 0 then return 0 end
        return 20 + cv:Measure("text", 10, w, table.concat(lines, "\n"), 3)
    end,
    draw = function(cv, ctx, b, x, y, w, h)
        local lines = briefLines(ctx, clampN(b.max or 6, 1, 12))
        local top = y + sectionTitle(cv, b.title or "En bref", x, y, w)
        local shown = {}
        for _, l in ipairs(lines) do
            shown[#shown + 1] = l
            if cv:Measure("text", 10, w, table.concat(shown, "\n"), 3) > y + h - top then
                shown[#shown] = nil
                break
            end
        end
        local fs = cv:Text("text", 10, INK, w)
        fs:SetSpacing(3)
        fs:SetPoint("TOPLEFT", x, -top)
        fs:SetText(table.concat(shown, "\n"))
    end,
}

-- Pull quote: an article's quote (p.quote) or free text, between two rules.
local function quoteOf(ctx, b)
    if b.text then return b.text, b.by end
    local a = ctx.article(b.a)
    if a and a.quote then return a.quote, b.by or a.title end
    return nil
end

BLOCKS.quote = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        local text, by = quoteOf(ctx, b)
        if not text then return 0 end
        return 8 + cv:Measure("title", 16, w - 12, "« " .. text .. " »") + (by and 18 or 4) + 8
    end,
    draw = function(cv, ctx, b, x, y, w, h)
        local text, by = quoteOf(ctx, b)
        cv:Rule(x, y, w, 2)
        local q = cv:Text("title", 16, RED, w - 12)
        q:SetJustifyH("CENTER")
        q:SetPoint("TOPLEFT", x + 6, -(y + 8))
        q:SetText("« " .. text .. " »")
        if by then
            local s = cv:Text("text", 9, INK_DIM, w)
            s:SetJustifyH("RIGHT")
            s:SetPoint("TOPLEFT", x, -(y + h - 22))
            s:SetText("— " .. by)
        end
        cv:Rule(x, y + h - 2, w, 1)
    end,
}

-- Figure of the week: a value with a caption; by default, the week's deaths.
local function figureOf(ctx, b)
    if b.value and b.value ~= "deaths" then return b.value, b.label or "" end
    local deaths = 0
    for _, ev in ipairs(ctx.ds.events or {}) do
        if ev.k == "DEATH" and ev.t >= ctx.monday and ev.t < ctx.monday + 7 * DAY then deaths = deaths + 1 end
    end
    if deaths == 0 then return nil end
    return tostring(deaths), b.label or (deaths == 1 and "décès dans la guilde cette semaine. Un seul : la rédaction s'ennuie."
        or "décès dans la guilde cette semaine. Les esprits gardiens font des heures supplémentaires.")
end

BLOCKS.figure = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        local v, label = figureOf(ctx, b)
        if not v then return 0 end
        local vw = math.max(50, cv:Measure("title", 34, 400, v) > 0 and (#v * 18 + 14) or 50)
        return 20 + math.max(42, cv:Measure("text", 10, w - vw, label) + 8)
    end,
    draw = function(cv, ctx, b, x, y, w)
        local v, label = figureOf(ctx, b)
        local top = y + sectionTitle(cv, b.title or "Le chiffre de la semaine", x, y, w)
        local vw = math.max(50, #v * 18 + 14)
        local num = cv:Text("title", 34, RED)
        num:SetPoint("TOPLEFT", x, -top)
        num:SetText(v)
        local l = cv:Text("text", 10, INK, w - vw)
        l:SetPoint("TOPLEFT", x + vw, -(top + 4))
        l:SetText(label)
    end,
}

-- Portrait: an engraved medallion (class emblem in a ring), the name and a caption.
-- Drawn from data every member has (roster, journal), never from the live game
-- model: everyone sees the same page.
local function portraitOf(ctx, b)
    local name = b.name
    local a = ctx.article(b.a)
    if not name and a then name = a.portrait end
    if type(name) ~= "string" or name == "" then return nil end
    local who = { name = name }
    local m = ns.Store.FindInRoster(ctx.ds.roster or {}, nil, name)
    if m then who.name, who.class, who.level = m.name or name, m.class, m.level end
    for _, ev in ipairs(ctx.ds.events or {}) do
        if ev.n == name or (m and ev.n == m.first) then
            who.class = who.class or ev.c
            if ev.k == "LEVEL_UP" and ev.p and not who.level then who.level = ev.p.lvl end
            if who.class and who.level then break end
        end
    end
    who.caption = b.caption or (a and a.title) or nil
    return who
end

local CLASS_FR = { WARRIOR = "Guerrier", PALADIN = "Paladin", HUNTER = "Chasseur", ROGUE = "Voleur", PRIEST = "Prêtre",
    DEATHKNIGHT = "Chevalier de la mort", SHAMAN = "Chaman", MAGE = "Mage", WARLOCK = "Démoniste", MONK = "Moine",
    DRUID = "Druide", DEMONHUNTER = "Chasseur de démons", EVOKER = "Évocateur" }

local function portraitSub(who)
    local cls = who.class and (CLASS_FR[who.class] or who.class) or nil
    if cls and who.level then return cls .. " de niveau " .. who.level end
    return cls or (who.level and ("Niveau " .. who.level)) or ""
end

local MEDAL = 64

BLOCKS.portrait = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        local who = portraitOf(ctx, b)
        if not who then return 0 end
        local top = 20
        if w >= 180 then
            local tw = w - MEDAL - 12
            local th = cv:Measure("title", 16, tw, who.name) + 14 + (who.caption and cv:Measure("text", 10, tw, who.caption) + 4 or 0)
            return top + math.max(MEDAL, th)
        end
        return top + MEDAL + 6 + cv:Measure("title", 16, w, who.name) + 14
            + (who.caption and cv:Measure("text", 10, w, who.caption) + 4 or 0)
    end,
    draw = function(cv, ctx, b, x, y, w)
        local who = portraitOf(ctx, b)
        local top = y + sectionTitle(cv, b.title or "Le portrait", x, y, w)
        local wide = w >= 180
        local mx = wide and x or (x + (w - MEDAL) / 2)
        local back = cv:Texture("BACKGROUND")
        back:SetColorTexture(N.INK_DIM[1], N.INK_DIM[2], N.INK_DIM[3], 0.18)
        back:SetPoint("TOPLEFT", mx + 4, -(top + 4))
        back:SetSize(MEDAL - 8, MEDAL - 8)
        local icon = cv:Texture("ARTWORK")
        UI.SetClassIcon(icon, who.class)
        cv:Engrave(icon)
        icon:SetPoint("TOPLEFT", mx + 8, -(top + 8))
        icon:SetSize(MEDAL - 16, MEDAL - 16)
        local ring = cv:Texture("OVERLAY")
        ring:SetTexture(UI.MEDIA .. "ring")
        ring:SetVertexColor(INK[1] + 0.25, INK[2] + 0.2, INK[3] + 0.12, 1)
        ring:SetPoint("TOPLEFT", mx, -top)
        ring:SetSize(MEDAL, MEDAL)
        local tx, ty, tw = x, top + MEDAL + 6, w
        if wide then tx, ty, tw = x + MEDAL + 12, top + 2, w - MEDAL - 12 end
        local n = cv:Text("title", 16, INK, tw)
        if not wide then n:SetJustifyH("CENTER") end
        n:SetPoint("TOPLEFT", tx, -ty)
        n:SetText(who.name)
        local sub = cv:Text("text", 9, INK_DIM, tw)
        if not wide then sub:SetJustifyH("CENTER") end
        sub:SetPoint("TOPLEFT", n, "BOTTOMLEFT", 0, -2)
        sub:SetText(portraitSub(who))
        if who.caption then
            local c = cv:Text("text", 10, INK, tw)
            if not wide then c:SetJustifyH("CENTER") end
            c:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -4)
            c:SetText(who.caption)
        end
    end,
}

-- Picture: a game texture (icon, artwork), engraved, with a caption.
local function pictureTex(b)
    return type(b.tex) == "string" and b.tex:match("^Interface[\\/]") and b.tex or nil
end

BLOCKS.picture = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        if not pictureTex(b) then return 0 end
        local size = clampN(b.size or 80, 32, math.min(160, w))
        return size + (b.caption and (6 + cv:Measure("text", 9, w, b.caption)) or 0)
    end,
    draw = function(cv, ctx, b, x, y, w)
        local size = clampN(b.size or 80, 32, math.min(160, w))
        local px = x + (w - size) / 2
        local frame = cv:Texture("BACKGROUND")
        frame:SetColorTexture(INK[1], INK[2], INK[3], 0.85)
        frame:SetPoint("TOPLEFT", px - 2, -(y - 2))
        frame:SetSize(size + 4, size + 4)
        local t = cv:Texture("ARTWORK")
        t:SetTexture(pictureTex(b))
        if b.tex:find("[\\/][Ii]cons[\\/]") then t:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
        cv:Engrave(t)
        t:SetPoint("TOPLEFT", px, -y)
        t:SetSize(size, size)
        if b.caption then
            local c = cv:Text("text", 9, INK_DIM, w)
            c:SetJustifyH("CENTER")
            c:SetPoint("TOPLEFT", x, -(y + size + 6))
            c:SetText(b.caption)
        end
    end,
}

-- Notice: a boxed small ad / announcement.
local function box(cv, x, y, w, h)
    cv:Rule(x, y, w, 1)
    cv:Rule(x, y + h - 1, w, 1)
    cv:Rule(x, y, 1, h)
    cv:Rule(x + w - 1, y, 1, h)
end

BLOCKS.notice = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        if not b.text and not b.title then return 0 end
        return 10 + (b.title and cv:Measure("title", 14, w - 16, b.title) + 4 or 0)
            + (b.text and cv:Measure("text", 10, w - 16, b.text) or 0) + 10
    end,
    draw = function(cv, ctx, b, x, y, w, h)
        box(cv, x, y, w, h)
        local top = y + 10
        if b.title then
            local t = cv:Text("title", 14, INK, w - 16)
            t:SetJustifyH("CENTER")
            t:SetPoint("TOPLEFT", x + 8, -top)
            t:SetText(b.title)
            top = top + (t:GetStringHeight() or 14) + 4
        end
        if b.text then
            local s = cv:Text("text", 10, INK, w - 16)
            s:SetJustifyH("CENTER")
            s:SetPoint("TOPLEFT", x + 8, -top)
            s:SetText(b.text)
        end
    end,
}

-- Wanted: a small poster from the wanted board (an open WANTED, by name or the latest).
local function wantedOf(ctx, b)
    local closed = {}
    for _, ev in ipairs(ctx.ds.events or {}) do
        if ev.k == "WANTED_CLOSE" and ev.p and ev.p.name then closed[string.lower(ev.p.name)] = closed[string.lower(ev.p.name)] or ev.t end
    end
    for _, ev in ipairs(ctx.ds.events or {}) do
        if ev.k == "WANTED" and ev.p and type(ev.p.name) == "string"
            and (not b.name or string.lower(b.name) == string.lower(ev.p.name))
            and not ((closed[string.lower(ev.p.name)] or 0) > ev.t) then
            return ev.p
        end
    end
    return nil
end

local function wantedLines(p)
    local lines = {}
    if p.nickname then lines[#lines + 1] = "« " .. p.nickname .. " »" end
    if p.reason then lines[#lines + 1] = p.reason end
    if p.reward then lines[#lines + 1] = "Récompense : " .. p.reward end
    return table.concat(lines, "\n")
end

BLOCKS.wanted = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        local p = wantedOf(ctx, b)
        if not p then return 0 end
        return 8 + 24 + cv:Measure("title", 16, w - 16, p.name) + 4 + cv:Measure("text", 10, w - 16, wantedLines(p), 2) + 10
    end,
    draw = function(cv, ctx, b, x, y, w, h)
        local p = wantedOf(ctx, b)
        box(cv, x, y, w, h)
        cv:Rule(x + 3, y + 3, w - 6, 1, 0.5)
        local t = cv:Text("title", 20, RED, w - 16)
        t:SetJustifyH("CENTER")
        t:SetPoint("TOPLEFT", x + 8, -(y + 8))
        t:SetText(b.title or "RECHERCHÉ")
        local n = cv:Text("title", 16, INK, w - 16)
        n:SetJustifyH("CENTER")
        n:SetPoint("TOPLEFT", x + 8, -(y + 32))
        n:SetText(p.name)
        local d = cv:Text("text", 10, INK, w - 16)
        d:SetJustifyH("CENTER")
        d:SetSpacing(2)
        d:SetPoint("TOPLEFT", n, "BOTTOMLEFT", 0, -4)
        d:SetText(wantedLines(p))
    end,
}

-- Readers' letters: invitation and link to the letter dialog.
local LETTER = "Une remarque, un démenti, une rumeur ? La rédaction lit tout, et publie ce qui l'arrange."
BLOCKS.letters = {
    kind = "fixed",
    measure = function(cv, ctx, b, w)
        return 20 + cv:Measure("text", 10, w, b.text or LETTER) + 6 + 14
    end,
    draw = function(cv, ctx, b, x, y, w)
        local top = y + sectionTitle(cv, b.title or "Courrier des lecteurs", x, y, w)
        local t = cv:Text("text", 10, INK, w)
        t:SetPoint("TOPLEFT", x, -top)
        t:SetText(b.text or LETTER)
        local ly = top + (t:GetStringHeight() or 28) + 6
        local link = cv:Hit(x, ly, w, 14, nil, "Écrire à la rédaction")
        link.text:SetText("Écrire à la rédaction ›")
        link.text:SetTextColor(RED[1], RED[2], RED[3])
        link.text:SetShadowOffset(0, 0)
        link:SetScript("OnClick", function() UI.Dialogs.Letter() end)
        cv.letterLink = link
    end,
}

------------------------------------------------------------------------
-- Page rendering
------------------------------------------------------------------------
local SOFT_SHARE = 0.45

-- Lays out one cell's blocks in (x, y, w, h).
local function drawCell(cv, ctx, cell, x, y, w, h)
    local items, fixedH, fills = {}, 0, 0
    for _, b in ipairs(cell.blocks) do
        local def = BLOCKS[b.t]
        if def then
            local nat = def.measure(cv, ctx, b, w) or 0
            if nat > 0 then
                items[#items + 1] = { b = b, def = def, nat = nat }
                if def.kind == "fixed" then fixedH = fixedH + nat end
                if def.kind == "fill" then fills = fills + 1 end
            end
        end
    end
    if #items == 0 then return end
    local gaps = (#items - 1) * BLOCK_GAP
    -- Fixed blocks that do not fit are dropped from the bottom of the cell.
    while fixedH + gaps > h and #items > 0 do
        local dropped = false
        for i = #items, 1, -1 do
            if items[i].def.kind == "fixed" then
                fixedH = fixedH - items[i].nat
                table.remove(items, i)
                gaps = math.max(0, (#items - 1) * BLOCK_GAP)
                dropped = true
                break
            end
        end
        if not dropped then break end
    end
    local left = math.max(0, h - fixedH - gaps)
    -- Soft blocks: at most their natural height, sharing with the stories.
    local softs = 0
    for _, it in ipairs(items) do if it.def.kind == "soft" then softs = softs + 1 end end
    for _, it in ipairs(items) do
        if it.def.kind == "fixed" then it.h = it.nat end
    end
    -- With a story in the cell, soft blocks get at most SOFT_SHARE of the room left.
    local cap = (fills > 0 and left * SOFT_SHARE or left) / math.max(1, softs)
    local softUsed = 0
    for _, it in ipairs(items) do
        if it.def.kind == "soft" then
            it.h = math.min(it.nat, cap)
            softUsed = softUsed + it.h
        end
    end
    local fillH = fills > 0 and math.max(0, left - softUsed) / fills or 0
    for _, it in ipairs(items) do
        if it.def.kind == "fill" then it.h = fillH end
    end
    local cy = y
    for i, it in ipairs(items) do
        if it.h > 4 then
            it.def.draw(cv, ctx, it.b, x, cy, w, it.h)
            cy = cy + it.h
            if i < #items then
                if it.def.kind ~= "fixed" or items[i + 1].def.kind ~= "fixed" then
                    cv:Rule(x, cy + BLOCK_GAP / 2, w, 1, 0.35)
                end
                cy = cy + BLOCK_GAP
            end
        end
    end
end

-- Draws page `page` of the layout in the body area (x0, top) .. (x0 + width, bottom).
function N.Draw(cv, ctx, page, x0, top, width, bottom)
    cv:Reset()
    local rows = page.rows
    local bodyH = bottom - top
    local avail = bodyH - (#rows - 1) * ROW_GAP
    local fixed, free = 0, 0
    for _, r in ipairs(rows) do
        if r.h then fixed = fixed + r.h * bodyH else free = free + 1 end
    end
    local scale = (fixed > avail) and (avail / fixed) or 1
    local rest = free > 0 and math.max(0, avail - fixed * scale) / free or 0
    local y = top
    for ri, r in ipairs(rows) do
        local rh = r.h and (r.h * bodyH * scale) or rest
        if free == 0 and ri == #rows then rh = bottom - y end
        local total = 0
        for _, c in ipairs(r.cells) do total = total + c.w end
        local cw = width - (#r.cells - 1) * GUTTER
        local x = x0
        for ci, c in ipairs(r.cells) do
            local w = cw * c.w / total
            drawCell(cv, ctx, c, x, y, w, rh)
            x = x + w + GUTTER
            if ci < #r.cells then cv:Rule(x - GUTTER / 2, y, 1, rh, 0.6) end
        end
        y = y + rh
        if ri < #rows then
            cv:Rule(x0, y + ROW_GAP / 2 - 1, width, 1, 0.85)
            y = y + ROW_GAP
        end
    end
end

-- Rendering context of an edition.
function N.Context(ds, edition, monday, placed)
    local ctx = { ds = ds, edition = edition, monday = monday, placed = placed or {} }
    function ctx.article(ref)
        if edition then return N.Resolve(edition, ref) end
        return ref == "@1" and ctx.placeholder or nil
    end
    return ctx
end
