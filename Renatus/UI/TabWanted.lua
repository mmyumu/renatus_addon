-- UI/TabWanted.lua: PvP Wanted Board. Opens on an overview (rival guild, score, most
-- feared enemies, latest news from the front), then wanted posters, enemy registry, records.
local _, ns = ...
local UI = ns.UI
local Views, Types = ns.Views, ns.Types

local POSTER_W, POSTER_H = 222, 186
local PER_PAGE = 6

local function provSummary(record)
    local parts = {}
    for _, key in ipairs({ "LOG", "OBS", "MAN", "DED" }) do
        local n = record[key] or 0
        if n > 0 then
            local prov = Types.PROVENANCE[key]
            table.insert(parts, ("|c%s%d %s|r"):format(UI.ColorHex(prov.color[1], prov.color[2], prov.color[3]), n, string.lower(prov.label)))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "aucune"
end

------------------------------------------------------------------------
-- Poster
------------------------------------------------------------------------
local function createPoster(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(POSTER_W, POSTER_H)
    UI.Skin(f, "parchment")
    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 0.8, 0.12)
    f.head = UI.Title(f, 22, { 0.55, 0.08, 0.05 })
    f.head:SetPoint("TOP", 0, -8)
    f.head:SetJustifyH("CENTER")
    f.head:SetText("RECHERCHÉ")
    f.portrait = f:CreateTexture(nil, "ARTWORK")
    f.portrait:SetSize(36, 36)
    f.portrait:SetPoint("TOP", 0, -34)
    f.name = UI.Title(f, 16, UI.C.ink)
    f.name:SetPoint("TOP", f.portrait, "BOTTOM", 0, -4)
    f.name:SetJustifyH("CENTER")
    f.nick = UI.Text(f, 11, UI.C.inkDim)
    f.nick:SetPoint("TOP", f.name, "BOTTOM", 0, -2)
    f.nick:SetJustifyH("CENTER")
    f.reason = UI.Text(f, 11, UI.C.ink)
    f.reason:SetPoint("TOP", f.nick, "BOTTOM", 0, -6)
    f.reason:SetWidth(POSTER_W - 20)
    f.reason:SetJustifyH("CENTER")
    f.reason:SetMaxLines(3)
    f.reward = UI.Text(f, 11, { 0.5, 0.1, 0.05 })
    f.reward:SetPoint("BOTTOM", 0, 22)
    f.reward:SetWidth(POSTER_W - 16)
    f.reward:SetJustifyH("CENTER")
    f.foot = UI.Text(f, 10, UI.C.inkDim)
    f.foot:SetPoint("BOTTOM", 0, 6)
    f.foot:SetWidth(POSTER_W - 16)
    f.foot:SetJustifyH("CENTER")
    -- Frame of the poster opened from its miniature on the overview.
    f.focus = UI.Edges(f, { 0.85, 0.15, 0.08, 1 }, "OVERLAY")
    f.focus[1]:SetHeight(2); f.focus[2]:SetHeight(2); f.focus[3]:SetWidth(2); f.focus[4]:SetWidth(2)
    return f
end

local function fillPoster(f, poster)
    local ev, e = poster.ev, poster.enemy
    UI.SetClassIcon(f.portrait, e and e.class)
    f.name:SetText((e and e.display) or ev.p.name or "?")
    local nick = ev.p.nickname or (e and e.nickname)
    f.nick:SetText(nick and ("dit « " .. nick .. " »") or (e and e.guild and ("<" .. e.guild .. ">") or ""))
    f.reason:SetText(ev.p.reason or "")
    f.reward:SetText(ev.p.reward and ("Prime : " .. ev.p.reward) or "")
    local record = e and ("V " .. Views.Total(e.wins) .. "  ·  D " .. Views.Total(e.losses) .. "  ·  ") or ""
    f.foot:SetText(record .. "affiché par " .. Types.Who(ev))
end

------------------------------------------------------------------------
-- Overview: the rival guild, two scores (whole Horde, rival guild), the rival members
-- most to fear, the enemies who beat us, the latest news
------------------------------------------------------------------------
local ROWS, NEWS = 3, 7
local INK, INK_DIM, WIN, LOSS = UI.C.ink, UI.C.inkDim, { 0.16, 0.45, 0.12 }, { 0.62, 0.1, 0.06 }

local function inked(fs, c) fs:SetTextColor(c[1], c[2], c[3]); fs:SetShadowOffset(0, 0); return fs end

-- Most feared first: sworn enemies, then who beat us most, then who was there when we
-- died; never met rivals last, highest level first.
local function feared(enemies, keep)
    local list = {}
    for _, e in ipairs(enemies) do if keep(e) then list[#list + 1] = e end end
    local function score(e) return Views.Total(e.losses) * 3 + Views.Total(e.wins) + e.presentAtDeaths end
    table.sort(list, function(a, b)
        if a.sworn ~= b.sworn then return a.sworn end
        if score(a) ~= score(b) then return score(a) > score(b) end
        if (a.lastSeen ~= nil) ~= (b.lastSeen ~= nil) then return a.lastSeen ~= nil end
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
        return a.key < b.key
    end)
    return list
end

local function killedUs(e, ev)
    if ev.k == "PVP_CLASH" then return ev.p and ev.p.result == "loss" end
    local k = ev.k == "DEATH" and type(ev.p) == "table" and type(ev.p.killer) == "table" and ev.p.killer
    return k and k.pl and type(k.n) == "string" and Views.EnemyKey(k.n) == e.key or false
end

-- When this enemy last beat one of us (encounters are newest first).
local function lastWin(e)
    for _, ev in ipairs(e.encounters) do if killedUs(e, ev) then return ev.t end end
end

-- Those who beat us: most victories over us first, then the most recent.
local function killers(enemies)
    local list = {}
    for _, e in ipairs(enemies) do
        if Views.Total(e.losses) > 0 then e.lastWin = lastWin(e); list[#list + 1] = e end
    end
    table.sort(list, function(a, b)
        local la, lb = Views.Total(a.losses), Views.Total(b.losses)
        if la ~= lb then return la > lb end
        if (a.lastWin or 0) ~= (b.lastWin or 0) then return (a.lastWin or 0) > (b.lastWin or 0) end
        return a.key < b.key
    end)
    return list
end

-- An enemy without a record (honorable kill outside the rival guild): "un tauren guerrier (60)".
local function anonymous(p)
    local parts = {}
    if p.race then parts[#parts + 1] = string.lower(p.race) end
    if p.className then parts[#parts + 1] = string.lower(p.className) end
    local s = "un " .. (#parts > 0 and table.concat(parts, " ") or "ennemi")
    if p.level then s = s .. " (" .. p.level .. ")" end
    return UI.ClassName(s, p.class)
end

-- One line of news about an enemy encounter; e is nil for an unnamed honorable kill.
-- Our victories start with the member ("Brisépée a tué Lysandra"), the rest with the enemy.
local function newsLine(e, ev)
    local p = ev.p or {}
    local member = p.member or Types.Who(ev)
    local name = e and UI.ClassName(e.display, e.class) or anonymous(p)
    local text
    -- The game counts any participation in an honorable kill, not only the killing blow.
    if ev.k == "PVP_KILL" or (ev.k == "PVP_CLASH" and p.result == "win") then
        text = member .. " a tué " .. name
    elseif ev.k == "PVP_CLASH" then
        text = name .. (p.result == "loss" and " a vaincu " or " accrochage avec ") .. member
    elseif ev.k == "DEATH" then
        text = name .. (killedUs(e, ev) and " a tué " or " présent à la mort de ") .. Types.Who(ev)
    else
        text = name .. " croisé par " .. member
    end
    local zone = Types.Zone(ev)
    return text .. ((zone and zone ~= "") and (", " .. zone) or "")
end

local function verdict(w, l)
    if w + l == 0 then return "Aucun affrontement pour l'instant. Le calme avant la tempête ?" end
    if w > l then return "Avantage à la guilde. Qu'ils viennent." end
    if w < l then return "Ils mènent. Il est temps de laver l'affront." end
    return "Égalité parfaite. Ça ne durera pas."
end

-- A score block of the banner: label, "wins – losses", a bar.
local SCORE_W = 150
local function scoreBlock(banner, label)
    local s = CreateFrame("Frame", nil, banner)
    s:SetSize(SCORE_W, 64)
    s.label = inked(UI.Text(s, 10), INK_DIM)
    s.label:SetPoint("TOP", 0, 0)
    s.label:SetWidth(SCORE_W)
    s.label:SetJustifyH("CENTER")
    s.label:SetWordWrap(false)
    s.label:SetText(label)
    s.score = inked(UI.Title(s, 26), INK)
    s.score:SetPoint("TOP", s.label, "BOTTOM", 0, -3)
    s.score:SetJustifyH("CENTER")
    local bar = CreateFrame("Frame", nil, s)
    bar:SetSize(SCORE_W - 10, 6)
    bar:SetPoint("TOP", s.score, "BOTTOM", 0, -5)
    local bg = bar:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints()
    bg:SetColorTexture(INK_DIM[1], INK_DIM[2], INK_DIM[3], 0.25)
    s.barWin = bar:CreateTexture(nil, "OVERLAY")
    s.barWin:SetPoint("TOPLEFT")
    s.barWin:SetHeight(6)
    s.barWin:SetColorTexture(WIN[1], WIN[2], WIN[3], 0.9)
    s.barLoss = bar:CreateTexture(nil, "OVERLAY")
    s.barLoss:SetPoint("TOPRIGHT")
    s.barLoss:SetHeight(6)
    s.barLoss:SetColorTexture(LOSS[1], LOSS[2], LOSS[3], 0.9)
    s.barW = SCORE_W - 10
    return s
end

local function fillScore(s, score)
    s.score:SetText(("|cff2a7320%d|r  –  |cff9e1a10%d|r"):format(score.w, score.l))
    local total = score.w + score.l
    if total > 0 then
        local w = math.floor(s.barW * score.w / total + 0.5)
        s.barWin:SetWidth(math.max(1, w)); s.barWin:SetShown(score.w > 0)
        s.barLoss:SetWidth(math.max(1, s.barW - w)); s.barLoss:SetShown(score.l > 0)
    else
        s.barWin:Hide(); s.barLoss:Hide()
    end
end

-- A titled panel holding a scrolling list.
local function listPanel(parent, w, h, title, rowHeight, createRow, updateRow)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetSize(w, h)
    UI.Skin(panel, "panel")
    panel.title = UI.Section(panel, title, w - 24)
    panel.title:SetPoint("TOPLEFT", 14, -10)
    panel.list = UI.List(panel, w - 20, h - 40, rowHeight, createRow, updateRow)
    panel.list:SetPoint("TOPLEFT", 10, -34)
    panel.list.empty:SetFont(UI.FONT_BODY, 11, "")
    panel.list.empty:SetPoint("TOP", 0, -16)
    return panel
end

-- Enemy rows: class icon, name, one line of detail, record; a click opens their record.
local function enemyPanel(c, parent, w, h, sub)
    return listPanel(parent, w, h, "", 32, function(row)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(26, 26)
        row.icon:SetPoint("LEFT", 4, 0)
        row.name = UI.Text(row, 12)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 0)
        row.name:SetPoint("RIGHT", -64, 0)
        row.name:SetWordWrap(false)
        row.sub = UI.Text(row, 10, UI.C.dim)
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        row.sub:SetPoint("RIGHT", -4, 0)
        row.sub:SetWordWrap(false)
        row.record = UI.Text(row, 11)
        row.record:SetPoint("TOPRIGHT", -4, -2)
        row.record:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(self)
            if self.item then UI.Click(); c.detail = self.item.name; c:Refresh() end
        end)
    end, function(row, e)
        UI.SetClassIcon(row.icon, e.class)
        row.name:SetText(UI.ClassName(e.display, e.class) .. (e.nickname and ("  |cff999999« " .. e.nickname .. " »|r") or ""))
        row.sub:SetText(sub(e))
        row.record:SetText("|cff66dd66V " .. Views.Total(e.wins) .. "|r  |cffdd5544D " .. Views.Total(e.losses) .. "|r")
    end)
end

local function rivalSub(e)
    local bits = {}
    if e.sworn then bits[#bits + 1] = "|cffcc2a1aENNEMI JURÉ|r" end
    local l = Views.Total(e.losses)
    if l > 0 then bits[#bits + 1] = "nous a vaincus " .. l .. " fois" end
    if e.presentAtDeaths > 0 then bits[#bits + 1] = "présent à " .. e.presentAtDeaths .. " mort(s)" end
    if #bits == 0 then
        if e.level then bits[#bits + 1] = "niveau " .. e.level end
        bits[#bits + 1] = e.lastSeen and ("croisé " .. UI.Ago(e.lastSeen)) or "jamais croisé"
    end
    return table.concat(bits, "  ·  ")
end

local function killerSub(e)
    local bits = {}
    if e.rival then bits[#bits + 1] = "|cffe08a1eGUILDE RIVALE|r"
    elseif e.sworn then bits[#bits + 1] = "|cffcc2a1aENNEMI JURÉ|r" end
    bits[#bits + 1] = Views.Total(e.losses) .. " fois"
    if e.lastWin then bits[#bits + 1] = "dernière " .. UI.Ago(e.lastWin) end
    return table.concat(bits, "  ·  ")
end

-- Mini wanted poster: a click opens the poster itself on the board.
local MINI_W, MINI_H, MINIS = 104, 96, 3
local function createMini(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(MINI_W, MINI_H)
    UI.Skin(f, "parchment")
    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 0.8, 0.15)
    f.head = inked(UI.Title(f, 12), { 0.55, 0.08, 0.05 })
    f.head:SetPoint("TOP", 0, -6)
    f.head:SetText("RECHERCHÉ")
    f.portrait = f:CreateTexture(nil, "ARTWORK")
    f.portrait:SetSize(22, 22)
    f.portrait:SetPoint("TOP", 0, -22)
    f.name = inked(UI.Text(f, 11), INK)
    f.name:SetPoint("TOP", f.portrait, "BOTTOM", 0, -4)
    f.name:SetWidth(MINI_W - 8)
    f.name:SetJustifyH("CENTER")
    f.name:SetWordWrap(false)
    f.reward = inked(UI.Text(f, 9), { 0.5, 0.1, 0.05 })
    f.reward:SetPoint("TOP", f.name, "BOTTOM", 0, -3)
    f.reward:SetWidth(MINI_W - 10)
    f.reward:SetJustifyH("CENTER")
    f.reward:SetMaxLines(2)
    return f
end

local function fillMini(f, poster)
    local ev, e = poster.ev, poster.enemy
    UI.SetClassIcon(f.portrait, e and e.class)
    f.name:SetText((e and e.display) or ev.p.name or "?")
    f.reward:SetText(ev.p.reward and ("Prime : " .. ev.p.reward) or (ev.p.nickname and ("« " .. ev.p.nickname .. " »")) or "")
end

local function plural(n, word) return n .. " " .. word .. (n > 1 and "s" or "") end

local function buildHome(c, parent, top, height)
    local h = CreateFrame("Frame", nil, parent)
    h:SetPoint("TOPLEFT", 0, top)
    h:SetSize(UI.CONTENT_W, height)
    c.home = h

    -- Banner: the rival guild and both scores.
    local banner = CreateFrame("Frame", nil, h)
    banner:SetPoint("TOPLEFT", 0, 0)
    banner:SetSize(UI.CONTENT_W, 116)
    UI.Skin(banner, "parchment")
    h.banner = banner
    local crest = UI.Icon(banner, 64, "Interface\\Icons\\Ability_DualWield")
    crest:SetPoint("LEFT", 18, 0)
    local rim = CreateFrame("Frame", nil, banner)
    rim:SetPoint("TOPLEFT", crest, "TOPLEFT", -2, 2)
    rim:SetPoint("BOTTOMRIGHT", crest, "BOTTOMRIGHT", 2, -2)
    UI.Edges(rim, { 0.45, 0.26, 0.1, 1 })
    h.kicker = inked(UI.Text(banner, 10), LOSS)
    h.kicker:SetPoint("TOPLEFT", crest, "TOPRIGHT", 16, 2)
    h.guild = inked(UI.Title(banner, 24), INK)
    h.guild:SetPoint("TOPLEFT", h.kicker, "BOTTOMLEFT", 0, -4)
    h.guild:SetWidth(250)
    h.guild:SetWordWrap(false)
    h.facts = inked(UI.Text(banner, 11), INK_DIM)
    h.facts:SetPoint("TOPLEFT", h.guild, "BOTTOMLEFT", 0, -6)
    h.facts:SetWidth(250)

    h.rivalScore = scoreBlock(banner, "CONTRE LA GUILDE RIVALE")
    h.rivalScore:SetPoint("TOPRIGHT", -16, -14)
    h.hordeScore = scoreBlock(banner, "CONTRE TOUTE LA HORDE")
    h.hordeScore:SetPoint("TOPRIGHT", h.rivalScore, "TOPLEFT", -14, 0)
    local divider = banner:CreateTexture(nil, "ARTWORK")
    divider:SetSize(1, 52)
    divider:SetPoint("TOPRIGHT", h.rivalScore, "TOPLEFT", -7, -4)
    divider:SetColorTexture(INK_DIM[1], INK_DIM[2], INK_DIM[3], 0.35)
    h.verdict = inked(UI.Text(banner, 10), INK)
    h.verdict:SetPoint("TOP", h.rivalScore, "BOTTOMLEFT", -7, -10)
    h.verdict:SetWidth(2 * SCORE_W + 24)
    h.verdict:SetJustifyH("CENTER")

    local colTop, colW = 126, (UI.CONTENT_W - 8) / 2
    local colH = height - colTop
    local panelH = (colH - 8) / 2

    -- Left: the rival guild members to fear, then those who beat us.
    h.rivals = enemyPanel(c, h, colW, panelH, rivalSub)
    h.rivals:SetPoint("TOPLEFT", 0, -colTop)
    h.killers = enemyPanel(c, h, colW, panelH, killerSub)
    h.killers:SetPoint("TOPLEFT", h.rivals, "BOTTOMLEFT", 0, -8)
    h.killers.title:SetText("Ils nous ont vaincus")

    -- Right: latest news from the front, then the wanted posters in miniature.
    h.news = listPanel(h, colW, panelH, "Nouvelles du front", 20, function(row)
        row.ago = UI.Text(row, 10, UI.C.dim)
        row.ago:SetPoint("LEFT", 4, 0)
        row.ago:SetWidth(70)
        row.ago:SetWordWrap(false)
        row.line = UI.Text(row, 11)
        row.line:SetPoint("LEFT", row.ago, "RIGHT", 4, 0)
        row.line:SetPoint("RIGHT", -4, 0)
        row.line:SetWordWrap(false)
        row:EnableMouse(false)
    end, function(row, item)
        row.ago:SetText(UI.Ago(item.ev.t))
        row.line:SetText(newsLine(item.e, item.ev))
    end)
    h.news:SetPoint("TOPRIGHT", 0, -colTop)

    local w = CreateFrame("Frame", nil, h)
    w:SetSize(colW, panelH)
    w:SetPoint("TOPLEFT", h.news, "BOTTOMLEFT", 0, -8)
    UI.Skin(w, "panel")
    h.wanted = w
    w.title = UI.Section(w, "Avis de recherche", colW - 24)
    w.title:SetPoint("TOPLEFT", 14, -10)
    w.offset = 0
    local function scroll(delta)
        w.offset = math.max(0, math.min(math.max(0, #(w.items or {}) - MINIS), w.offset - delta))
        c:Refresh()
    end
    h.postersLink = UI.Button(w, "", 104, 18, function()
        if (h.posterCount or 0) > 0 then c:SetView("posters") else UI.Dialogs.Wanted() end
    end)
    h.postersLink:SetPoint("TOPRIGHT", -12, -9)
    w.next = UI.Button(w, ">", 20, 18, function() scroll(-1) end)
    w.next:SetPoint("RIGHT", h.postersLink, "LEFT", -6, 0)
    w.prev = UI.Button(w, "<", 20, 18, function() scroll(1) end)
    w.prev:SetPoint("RIGHT", w.next, "LEFT", -2, 0)
    w:EnableMouseWheel(true)
    w:SetScript("OnMouseWheel", function(_, delta) scroll(delta) end)
    w.minis = {}
    local gap = (colW - 20 - MINIS * MINI_W) / (MINIS - 1)
    for i = 1, MINIS do
        local f = createMini(w)
        f:SetPoint("TOPLEFT", 10 + (i - 1) * (MINI_W + gap), -34)
        f:SetScript("OnClick", function(self)
            if not self.index then return end
            UI.Click()
            c.view, c.detail = "posters", nil
            c.page = math.ceil(self.index / PER_PAGE)
            c.focus = self.poster.ev.id
            c:Refresh()
        end)
        w.minis[i] = f
    end
    w.empty = UI.Text(w, 11, UI.C.dim)
    w.empty:SetPoint("TOP", 0, -60)
    w.empty:SetWidth(colW - 40)
    w.empty:SetJustifyH("CENTER")
end

local function refreshHome(c, ds, posters, enemies)
    local h = c.home
    local rival = ds.isDemo and "Les Crocs de Sang" or ns.GuildConfig.Rival()
    local met, sworn, rivals = 0, 0, 0
    for _, e in ipairs(enemies) do
        if e.lastSeen then met = met + 1 end
        if e.sworn then sworn = sworn + 1 end
        if e.rival then rivals = rivals + 1 end
    end
    h.kicker:SetText(rival and "GUILDE RIVALE" or "PAS ENCORE DE GUILDE RIVALE")
    h.guild:SetText(rival and ("<" .. rival .. ">") or "Ennemis de la guilde")
    local facts = {}
    local roster = not ds.isDemo and ns.GuildConfig.Roster()
    if roster then
        facts[#facts + 1] = (roster.p.count or #roster.p.members) .. " membres selon l'armurerie"
    elseif rival then
        facts[#facts + 1] = plural(rivals, "membre") .. " repéré" .. (rivals > 1 and "s" or "")
    end
    facts[#facts + 1] = plural(met, "ennemi") .. " croisé" .. (met > 1 and "s" or "")
    if sworn > 0 then facts[#facts + 1] = plural(sworn, "ennemi") .. " juré" .. (sworn > 1 and "s" or "") end
    if ds.huntSince then facts[#facts + 1] = "depuis le " .. Views.DateLabel(ds.huntSince) end
    local text = table.concat(facts, "  ·  ")
    if not rival then text = text .. "\nLes officiers la choisissent dans Renatus Admin." end
    h.facts:SetText(text)

    -- Scores: the whole Horde, and the rival guild alone (the verdict speaks of the rival).
    local horde, rivalScore = Views.PvpScore(ds, enemies)
    fillScore(h.hordeScore, horde)
    fillScore(h.rivalScore, rivalScore)
    h.rivalScore:SetAlpha(rival and 1 or 0.45)
    local v = rival and rivalScore or horde
    h.verdict:SetText(verdict(v.w, v.l))

    -- Rival guild: its members most to fear, never met ones by level.
    local list = rival and feared(enemies, function(e) return e.rival end) or {}
    local first = list[1]
    local fought = first and (first.sworn or Views.Total(first.losses) + Views.Total(first.wins) + first.presentAtDeaths > 0)
    h.rivals.title:SetText(fought and "Guilde rivale : les plus redoutés" or "Guilde rivale : les plus menaçants")
    h.rivals.list:SetItems(list, rival and "Aucun membre connu.\nL'armurerie ou une rencontre les fera apparaître."
        or "Pas encore de guilde rivale.")

    -- Those who beat us, rival or not.
    h.killers.list:SetItems(killers(enemies), "Personne ne nous a vaincus.\nPour l'instant.")

    -- News: every encounter of every enemy, most recent first, plus the honorable kills
    -- that name no one (outside the rival guild): without them only our deaths would show.
    local seen, items = {}, {}
    for _, e in ipairs(enemies) do
        for _, ev in ipairs(e.encounters) do
            local id = (ev.id or tostring(ev)) .. "@" .. e.key
            if not seen[id] then seen[id] = true; items[#items + 1] = { e = e, ev = ev } end
        end
    end
    for _, ev in ipairs(ds.events) do
        if ev.k == "PVP_KILL" and not (ev.p and ev.p.name) and Views.InHunt(ds, ev) then items[#items + 1] = { ev = ev } end
    end
    table.sort(items, function(a, b) return (a.ev.t or 0) > (b.ev.t or 0) end)
    h.news.list:SetItems(items, "Rien à signaler sur le front.")

    -- Wanted posters in miniature.
    local w = h.wanted
    w.items = posters
    w.offset = math.max(0, math.min(w.offset, #posters - MINIS))
    for i, f in ipairs(w.minis) do
        local index = w.offset + i
        f.poster, f.index = posters[index], posters[index] and index
        if f.poster then fillMini(f, f.poster); f:Show() else f:Hide() end
    end
    w.prev:SetShown(#posters > MINIS); w.next:SetShown(#posters > MINIS)
    w.prev:SetDisabled(w.offset <= 0); w.next:SetDisabled(w.offset >= #posters - MINIS)
    w.empty:SetText(#posters == 0 and "Aucun avis placardé.\nUn ennemi te pourrit la vie ?" or "")
    h.posterCount = #posters
    h.postersLink:SetLabel(#posters > 0 and ("Tout voir (" .. #posters .. ") ›") or "Placarder ›")
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function build(c)
    c.view = "home"
    c.page = 1

    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Tableau de chasse")
    c.rival = UI.Text(c, 11, UI.C.dim)
    c.rival:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)

    function c:SetView(v) self.view = v; self.detail, self.focus = nil, nil; self:Refresh() end
    c.tabHome = UI.ToggleButton(c, "Vue d'ensemble", 116, 24, function() c:SetView("home") end)
    c.tabHome:SetPoint("TOPLEFT", 4, -46)
    c.tabPosters = UI.ToggleButton(c, "Avis", 64, 24, function() c:SetView("posters") end)
    c.tabPosters:SetPoint("LEFT", c.tabHome, "RIGHT", 6, 0)
    c.tabRegistry = UI.ToggleButton(c, "Registre", 84, 24, function() c:SetView("registry") end)
    c.tabRegistry:SetPoint("LEFT", c.tabPosters, "RIGHT", 6, 0)
    local addWanted = UI.Button(c, "+ Avis", 80, 24, function() UI.Dialogs.Wanted() end)
    addWanted:SetPoint("TOPRIGHT", -4, -46)
    local addClash = UI.Button(c, "+ Affrontement", 120, 24, function() UI.Dialogs.Clash() end)
    addClash:SetPoint("RIGHT", addWanted, "LEFT", -6, 0)
    local addEnemy = UI.Button(c, "+ Ennemi", 90, 24, function() UI.Dialogs.EnemyNote() end)
    addEnemy:SetPoint("RIGHT", addClash, "LEFT", -6, 0)

    local bodyTop, bodyH = -80, UI.CONTENT_H - 104
    buildHome(c, c, bodyTop, bodyH + 20)

    -- Posters view
    local posters = CreateFrame("Frame", nil, c)
    posters:SetPoint("TOPLEFT", 0, bodyTop)
    posters:SetSize(UI.CONTENT_W, bodyH)
    c.posters = posters
    posters.items = {}
    for i = 1, PER_PAGE do
        local f = createPoster(posters)
        local col, line = (i - 1) % 3, math.floor((i - 1) / 3)
        f:SetPoint("TOPLEFT", 6 + col * (POSTER_W + 8), -line * (POSTER_H + 8))
        f:SetScript("OnClick", function(self) if self.poster then c.detail = self.poster.ev.p.name; c:Refresh() end end)
        posters.items[i] = f
    end
    posters.empty = UI.Text(posters, 13, UI.C.dim)
    posters.empty:SetPoint("TOP", 0, -60)
    posters.empty:SetJustifyH("CENTER")
    posters.empty:SetWidth(500)
    posters.prev = UI.Button(posters, "<", 28, 22, function() c.page = c.page - 1; c:Refresh() end)
    posters.prev:SetPoint("LEFT", c.tabRegistry, "RIGHT", 14, 0)
    posters.next = UI.Button(posters, ">", 28, 22, function() c.page = c.page + 1; c:Refresh() end)
    posters.next:SetPoint("LEFT", posters.prev, "RIGHT", 40, 0)
    posters.pageText = UI.Text(posters, 11, UI.C.dim)
    posters.pageText:SetPoint("LEFT", posters.prev, "RIGHT", 4, 0)
    posters.pageText:SetWidth(32)
    posters.pageText:SetJustifyH("CENTER")
    posters.pageText:SetJustifyV("MIDDLE")

    -- Registry view
    c.registry = UI.List(c, UI.CONTENT_W, bodyH, 40, function(row)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(28, 28)
        row.icon:SetPoint("LEFT", 6, 0)
        row.name = UI.Text(row, 13)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
        row.sub = UI.Text(row, 10, UI.C.dim)
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        row.record = UI.Text(row, 12)
        row.record:SetPoint("RIGHT", -10, 0)
        row.record:SetJustifyH("RIGHT")
        row.record:SetJustifyV("MIDDLE")
        row:SetScript("OnClick", function(self) c.detail = self.item.name; c:Refresh() end)
    end, function(row, e)
        UI.SetClassIcon(row.icon, e.class)
        local badges = (e.sworn and "  |cffcc2a1aENNEMI JURÉ|r" or "") .. (e.rival and "  |cffe08a1eGUILDE RIVALE|r" or "")
        row.name:SetText(UI.ClassName(e.display, e.class) .. (e.nickname and ("  |cff999999« " .. e.nickname .. " »|r") or "") .. badges)
        local bits = {}
        if e.guild then table.insert(bits, "<" .. e.guild .. ">") end
        if e.armory and e.armory.rk then table.insert(bits, e.armory.rk == 0 and "chef de guilde" or ("rang " .. e.armory.rk)) end
        if e.level then
            table.insert(bits, "niv. " .. e.level .. (e.levelSrc == "armory" and " (armurerie)" or (" (vu " .. UI.Ago(e.levelAt) .. ")")))
        end
        if e.lastZone then table.insert(bits, "dernière rencontre : " .. e.lastZone)
        elseif not e.lastSeen then table.insert(bits, "jamais croisé") end
        row.sub:SetText(table.concat(bits, "  ·  "))
        row.record:SetText("|cff66dd66V " .. Views.Total(e.wins) .. "|r   |cffdd5544D " .. Views.Total(e.losses) .. "|r")
    end)
    c.registry:SetPoint("TOPLEFT", 0, bodyTop)
    -- Registry filter: every enemy met, or the rival guild only.
    c.rivalFilter = UI.ToggleButton(c, "Guilde rivale", 110, 24, function()
        c.rivalOnly = not c.rivalOnly
        c:Refresh()
    end)
    c.rivalFilter:SetPoint("LEFT", c.tabRegistry, "RIGHT", 14, 0)

    -- Record view
    local d = CreateFrame("Frame", nil, c)
    d:SetPoint("TOPLEFT", 0, bodyTop)
    d:SetSize(UI.CONTENT_W, bodyH + 20)
    UI.Skin(d, "panel")
    c.detailFrame = d
    local back = UI.Button(d, "< Retour", 80, 22, function() c.detail = nil; c:Refresh() end)
    back:SetPoint("TOPRIGHT", -8, -8)
    d.portrait = d:CreateTexture(nil, "ARTWORK")
    d.portrait:SetSize(64, 64)
    d.portrait:SetPoint("TOPLEFT", 14, -14)
    d.name = UI.Title(d, 22)
    d.name:SetPoint("TOPLEFT", d.portrait, "TOPRIGHT", 12, 0)
    d.ident = UI.Text(d, 12, UI.C.dim)
    d.ident:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -4)
    d.ident:SetWidth(520)
    d.sworn = UI.Title(d, 14, UI.C.red)
    d.sworn:SetPoint("TOPLEFT", d.ident, "BOTTOMLEFT", 0, -4)
    d.left = UI.ScrollText(d, 300, bodyH - 110, 12)
    d.left:SetPoint("TOPLEFT", 14, -96)
    d.right = UI.ScrollText(d, 340, bodyH - 110, 12)
    d.right:SetPoint("TOPLEFT", 334, -96)
    local note = UI.Button(d, "+ Note / surnom", 130, 22, function() UI.Dialogs.EnemyNote(c.detailName) end)
    note:SetPoint("BOTTOMLEFT", 14, 10)
    local clash = UI.Button(d, "Déclarer un affrontement", 180, 22, function() UI.Dialogs.Clash(c.detailName) end)
    clash:SetPoint("LEFT", note, "RIGHT", 8, 0)
    local wanted = UI.Button(d, "Placarder un avis", 140, 22, function() UI.Dialogs.Wanted(c.detailName) end)
    wanted:SetPoint("LEFT", clash, "RIGHT", 8, 0)

    function c:ShowDetail(e)
        c.detailName = e.display
        UI.SetClassIcon(d.portrait, e.class)
        d.name:SetText(UI.ClassName(e.display, e.class))
        local ident = {}
        if e.guild then table.insert(ident, "<" .. e.guild .. ">") end
        if e.race or e.class then table.insert(ident, (e.race or "?") .. " " .. string.lower(e.class or "?")) end
        if e.level then
            table.insert(ident, "niveau " .. e.level .. (e.levelSrc == "armory" and " (armurerie)" or (" observé " .. UI.Ago(e.levelAt))))
        end
        d.ident:SetText(table.concat(ident, "  ·  "))
        d.sworn:SetText(e.sworn and ("ENNEMI JURÉ — " .. (e.swornReason or ""))
            or (e.rival and "MEMBRE DE LA GUILDE RIVALE") or "")

        local L = {}
        table.insert(L, "|cffffd100Bilan|r")
        table.insert(L, "Victoires : " .. Views.Total(e.wins) .. " (" .. provSummary(e.wins) .. ")")
        table.insert(L, "Défaites : " .. Views.Total(e.losses) .. " (" .. provSummary(e.losses) .. ")")
        if e.presentAtDeaths > 0 then
            table.insert(L, "|cffbbbbbbPrésent lors de " .. e.presentAtDeaths .. " mort(s) de nos membres (supposé, tueur inconnu).|r")
        end
        table.insert(L, "")
        table.insert(L, "|cffffd100Dernière rencontre|r")
        table.insert(L, e.lastSeen and (UI.Date(e.lastSeen, true) .. (e.lastZone and (", " .. e.lastZone) or "")) or "jamais observé")
        table.insert(L, "")
        table.insert(L, "|cffffd100Membres impliqués|r")
        table.insert(L, #e.memberList > 0 and table.concat(e.memberList, ", ") or "—")
        table.insert(L, "")
        table.insert(L, "|cffffd100Surnoms et annotations|r")
        if #e.nicknames == 0 and #e.notes == 0 then table.insert(L, "—") end
        for _, n in ipairs(e.nicknames) do table.insert(L, "« " .. n.text .. " »  |cff999999— " .. (n.by or "?") .. "|r") end
        for _, n in ipairs(e.notes) do table.insert(L, n.text .. "  |cff999999— " .. (n.by or "?") .. "|r") end
        local arm, roster = ns.GuildConfig.ArmoryInfo(e.name)
        if arm then
            table.insert(L, "")
            table.insert(L, "|cffffd100Armurerie|r  |cff999999(relevé " .. UI.Ago(roster.p.at or roster.t) .. ")|r")
            local bits = { arm.n }
            if arm.lvl then table.insert(bits, "niveau " .. arm.lvl) end
            if arm.rk then table.insert(bits, arm.rk == 0 and "chef de guilde" or ("rang " .. arm.rk)) end
            table.insert(L, table.concat(bits, ", "))
            local gear = {}
            if arm.gs then table.insert(gear, "score d'équipement " .. arm.gs) end
            if arm.il then table.insert(gear, "niveau d'objet moyen " .. arm.il) end
            if #gear > 0 then table.insert(L, table.concat(gear, ", ")) end
            if arm.ll then table.insert(L, "dernière connexion " .. UI.Ago(arm.ll)) end
        end
        d.left:SetText(table.concat(L, "\n"))

        local R = { "|cffffd100Historique des rencontres|r" }
        for i, ev in ipairs(e.encounters) do
            if i > 30 then break end
            local prov = Types.PROVENANCE[ev.prov] or Types.PROVENANCE.OBS
            local text = Types.Describe(ev, true)
            if ev.k == "DEATH" then text = Types.Who(ev) .. " meurt, " .. e.display .. " présent" end
            local provLabel = ev.k == "DEATH" and "supposé" or string.lower(prov.label)
            table.insert(R, ("|cff999999%s|r  %s  |c%s[%s]|r"):format(UI.Date(ev.t), text,
                UI.ColorHex(prov.color[1], prov.color[2], prov.color[3]), provLabel))
        end
        if #e.encounters == 0 then table.insert(R, "Aucune rencontre enregistrée.") end
        d.right:SetText(table.concat(R, "\n"))
    end

    function c:Refresh()
        local ds = ns.Store.Dataset()
        local rival = ds.isDemo and "Les Crocs de Sang" or ns.GuildConfig.Rival()
        local line = rival and ("Guilde rivale : <" .. rival .. ">") or "Guilde rivale pas encore choisie par les officiers."
        local roster = not ds.isDemo and ns.GuildConfig.Roster()
        if roster then
            line = line .. ("  ·  %d membre(s) selon l'armurerie (relevé %s)"):format(
                roster.p.count or #roster.p.members, UI.Ago(roster.p.at or roster.t))
        end
        self.rival:SetText(line)
        local postersList, enemies = Views.Wanted(ds)
        self.tabHome:SetSelected(self.view == "home")
        self.tabPosters:SetSelected(self.view == "posters")
        self.tabRegistry:SetSelected(self.view == "registry")

        local detailEnemy
        if self.detail then
            for _, e in ipairs(enemies) do if e.key == Views.EnemyKey(self.detail) then detailEnemy = e end end
        end
        self.home:SetShown(self.view == "home" and not detailEnemy)
        posters:SetShown(self.view == "posters" and not detailEnemy)
        self.registry:SetShown(self.view == "registry" and not detailEnemy)
        self.rivalFilter:SetShown(self.view == "registry" and not detailEnemy)
        self.rivalFilter:SetSelected(self.rivalOnly == true)
        d:SetShown(detailEnemy ~= nil)
        if detailEnemy then self:ShowDetail(detailEnemy) return end
        if self.view == "home" then refreshHome(self, ds, postersList, enemies) return end

        if self.view == "registry" then
            if self.rivalOnly then
                local rivals = {}
                for _, e in ipairs(enemies) do if e.rival then rivals[#rivals + 1] = e end end
                self.registry:SetItems(rivals, "Aucun membre de la guilde rivale connu.\nL'armurerie ou une rencontre les fera apparaître.")
                return
            end
            self.registry:SetItems(enemies, "Aucun ennemi enregistré.\nLes membres de la guilde rivale (armurerie) et ceux croisés en jeu apparaîtront ici,\nou ajoute-les avec « + Ennemi ».")
            return
        end
        local pages = math.max(1, math.ceil(#postersList / PER_PAGE))
        self.page = math.max(1, math.min(self.page, pages))
        for i, f in ipairs(posters.items) do
            local poster = postersList[(self.page - 1) * PER_PAGE + i]
            f.poster = poster
            if poster then fillPoster(f, poster); f:Show() else f:Hide() end
            for _, edge in ipairs(f.focus) do edge:SetShown(poster ~= nil and poster.ev.id == self.focus) end
        end
        posters.empty:SetText(#postersList == 0 and "Aucun avis de recherche placardé.\nUn ennemi te pourrit la vie ? « + Avis »." or "")
        posters.pageText:SetText(self.page .. "/" .. pages)
        posters.prev:SetShown(pages > 1)
        posters.next:SetShown(pages > 1)
        posters.prev:SetDisabled(self.page <= 1)
        posters.next:SetDisabled(self.page >= pages)
    end
end

UI.RegisterTab({ key = "wanted", group = "main", label = "Tableau de chasse", icon = "Interface\\Icons\\Ability_DualWield", order = 3,
    build = build, refresh = function(c) c:Refresh() end })
