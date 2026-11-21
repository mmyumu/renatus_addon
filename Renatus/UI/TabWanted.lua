-- UI/TabWanted.lua: PvP Wanted Board. Opens on an overview (rival guild, score, most
-- feared enemies, latest news from the front), then wanted posters, enemy registry, records.
local _, ns = ...
local UI = ns.UI
local Views, Types = ns.Views, ns.Types

local POSTER_W, POSTER_H = 222, 186
local PER_PAGE = 6

local function provSummary(record)
    local parts = {}
    for _, key in ipairs({ "LOG", "OBS", "MAN" }) do
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
-- Overview: the rival guild, the score, the most feared enemies, the latest news
------------------------------------------------------------------------
local FEARED, NEWS = 4, 7
local INK, INK_DIM, WIN, LOSS = UI.C.ink, UI.C.inkDim, { 0.16, 0.45, 0.12 }, { 0.62, 0.1, 0.06 }

local function inked(fs, c) fs:SetTextColor(c[1], c[2], c[3]); fs:SetShadowOffset(0, 0); return fs end

-- Most feared first: sworn enemies, then who beat us most, then who was there when we
-- died; never met rivals last, highest level first.
local function feared(enemies)
    local list = {}
    for _, e in ipairs(enemies) do list[#list + 1] = e end
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

-- One line of news about an enemy encounter.
local function newsLine(e, ev)
    local p = ev.p or {}
    local member = p.member or Types.Who(ev)
    local text
    if ev.k == "PVP_CLASH" then
        text = p.result == "win" and ("vaincu par " .. member) or p.result == "loss" and ("a vaincu " .. member)
            or ("accrochage avec " .. member)
    elseif ev.k == "DEATH" then
        local k = type(p.killer) == "table" and p.killer or nil
        text = (k and k.n and Views.EnemyKey(k.n) == e.key) and ("a tué " .. Types.Who(ev))
            or ("présent à la mort de " .. Types.Who(ev))
    else
        text = "croisé par " .. member
    end
    local zone = Types.Zone(ev)
    return UI.ClassName(e.display, e.class) .. " " .. text .. ((zone and zone ~= "") and (", " .. zone) or "")
end

local function verdict(w, l)
    if w + l == 0 then return "Aucun affrontement pour l'instant. Le calme avant la tempête ?" end
    if w > l then return "Avantage à la guilde. Qu'ils viennent." end
    if w < l then return "Ils mènent. Il est temps de laver l'affront." end
    return "Égalité parfaite. Ça ne durera pas."
end

local function buildHome(c, parent, top, height)
    local h = CreateFrame("Frame", nil, parent)
    h:SetPoint("TOPLEFT", 0, top)
    h:SetSize(UI.CONTENT_W, height)
    c.home = h

    -- Banner: the rival guild and the score.
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
    h.guild:SetWidth(330)
    h.guild:SetWordWrap(false)
    h.facts = inked(UI.Text(banner, 11), INK_DIM)
    h.facts:SetPoint("TOPLEFT", h.guild, "BOTTOMLEFT", 0, -6)
    h.facts:SetWidth(340)

    local SCORE_W = 230
    h.scoreLabel = inked(UI.Text(banner, 10), INK_DIM)
    h.scoreLabel:SetPoint("TOPRIGHT", -20, -14)
    h.scoreLabel:SetWidth(SCORE_W)
    h.scoreLabel:SetJustifyH("CENTER")
    h.scoreLabel:SetText("BILAN DES AFFRONTEMENTS")
    h.score = inked(UI.Title(banner, 30), INK)
    h.score:SetPoint("TOP", h.scoreLabel, "BOTTOM", 0, -4)
    h.score:SetJustifyH("CENTER")
    local bar = CreateFrame("Frame", nil, banner)
    bar:SetSize(SCORE_W, 8)
    bar:SetPoint("TOP", h.score, "BOTTOM", 0, -6)
    h.barBg = bar:CreateTexture(nil, "ARTWORK")
    h.barBg:SetAllPoints()
    h.barBg:SetColorTexture(INK_DIM[1], INK_DIM[2], INK_DIM[3], 0.25)
    h.barWin = bar:CreateTexture(nil, "OVERLAY")
    h.barWin:SetPoint("TOPLEFT")
    h.barWin:SetHeight(8)
    h.barWin:SetColorTexture(WIN[1], WIN[2], WIN[3], 0.9)
    h.barLoss = bar:CreateTexture(nil, "OVERLAY")
    h.barLoss:SetPoint("TOPRIGHT")
    h.barLoss:SetHeight(8)
    h.barLoss:SetColorTexture(LOSS[1], LOSS[2], LOSS[3], 0.9)
    h.bar, h.barW = bar, SCORE_W
    h.verdict = inked(UI.Text(banner, 10), INK)
    h.verdict:SetPoint("TOP", bar, "BOTTOM", 0, -6)
    h.verdict:SetWidth(SCORE_W + 20)
    h.verdict:SetJustifyH("CENTER")

    local colTop, colH, colW = 126, height - 126, (UI.CONTENT_W - 8) / 2

    -- Most feared enemies (clickable: their record).
    local left = CreateFrame("Frame", nil, h)
    left:SetPoint("TOPLEFT", 0, -colTop)
    left:SetSize(colW, colH)
    UI.Skin(left, "panel")
    h.fearedTitle = UI.Section(left, "Les plus redoutés", colW - 24)
    h.fearedTitle:SetPoint("TOPLEFT", 14, -12)
    h.feared = {}
    for i = 1, FEARED do
        local row = CreateFrame("Button", nil, left)
        row:SetSize(colW - 20, 50)
        row:SetPoint("TOPLEFT", 10, -40 - (i - 1) * 52)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.85, 0.4, 0.1)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(34, 34)
        row.icon:SetPoint("LEFT", 4, 0)
        row.name = UI.Text(row, 13)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -1)
        row.name:SetPoint("RIGHT", -70, 0)
        row.name:SetWordWrap(false)
        row.sub = UI.Text(row, 10, UI.C.dim)
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
        row.sub:SetPoint("RIGHT", -4, 0)
        row.sub:SetWordWrap(false)
        row.record = UI.Text(row, 12)
        row.record:SetPoint("TOPRIGHT", -4, -3)
        row.record:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(self)
            if self.enemy then UI.Click(); c.detail = self.enemy.name; c:Refresh() end
        end)
        h.feared[i] = row
    end
    h.fearedEmpty = UI.Text(left, 12, UI.C.dim)
    h.fearedEmpty:SetPoint("TOP", 0, -70)
    h.fearedEmpty:SetWidth(colW - 40)
    h.fearedEmpty:SetJustifyH("CENTER")

    -- Latest news from the front, then a shortcut to the posters.
    local right = CreateFrame("Frame", nil, h)
    right:SetPoint("TOPRIGHT", 0, -colTop)
    right:SetSize(colW, colH)
    UI.Skin(right, "panel")
    local newsTitle = UI.Section(right, "Nouvelles du front", colW - 24)
    newsTitle:SetPoint("TOPLEFT", 14, -12)
    h.news = {}
    for i = 1, NEWS do
        local ago = UI.Text(right, 10, UI.C.dim)
        ago:SetPoint("TOPLEFT", 14, -42 - (i - 1) * 24)
        ago:SetWidth(78)
        ago:SetWordWrap(false)
        local line = UI.Text(right, 11)
        line:SetPoint("TOPLEFT", ago, "TOPRIGHT", 4, 1)
        line:SetWidth(colW - 110)
        line:SetWordWrap(false)
        h.news[i] = { ago = ago, line = line }
    end
    h.newsEmpty = UI.Text(right, 12, UI.C.dim)
    h.newsEmpty:SetPoint("TOP", 0, -70)
    h.newsEmpty:SetWidth(colW - 40)
    h.newsEmpty:SetJustifyH("CENTER")
    h.postersLink = UI.Button(right, "", colW - 28, 24, function()
        if h.posterCount > 0 then c:SetView("posters") else UI.Dialogs.Wanted() end
    end)
    h.postersLink:SetPoint("BOTTOM", 0, 12)
end

local function refreshHome(c, ds, posters, enemies)
    local h = c.home
    local rival = ds.isDemo and "Les Crocs de Sang" or ns.GuildConfig.Rival()
    local wins, losses, met, sworn, rivals = 0, 0, 0, 0, 0
    for _, e in ipairs(enemies) do
        wins, losses = wins + Views.Total(e.wins), losses + Views.Total(e.losses)
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
        facts[#facts + 1] = rivals .. " membre" .. (rivals > 1 and "s" or "") .. " repéré" .. (rivals > 1 and "s" or "")
    end
    facts[#facts + 1] = met .. " ennemi" .. (met > 1 and "s" or "") .. " croisé" .. (met > 1 and "s" or "")
    if sworn > 0 then facts[#facts + 1] = sworn .. " ennemi" .. (sworn > 1 and "s" or "") .. " juré" .. (sworn > 1 and "s" or "") end
    local text = table.concat(facts, "  ·  ")
    if not rival then text = text .. "\nLes officiers la choisissent dans Renatus Admin." end
    h.facts:SetText(text)

    h.score:SetText(("|cff2a7320%d|r  –  |cff9e1a10%d|r"):format(wins, losses))
    local total = wins + losses
    if total > 0 then
        local w = math.floor(h.barW * wins / total + 0.5)
        h.barWin:SetWidth(math.max(1, w)); h.barWin:SetShown(wins > 0)
        h.barLoss:SetWidth(math.max(1, h.barW - w)); h.barLoss:SetShown(losses > 0)
    else
        h.barWin:Hide(); h.barLoss:Hide()
    end
    h.verdict:SetText("victoires – défaites\n" .. verdict(wins, losses))

    local list = feared(enemies)
    local anyFight = list[1] and (list[1].sworn or Views.Total(list[1].losses) + Views.Total(list[1].wins) + list[1].presentAtDeaths > 0)
    h.fearedTitle:SetText(anyFight and "Les plus redoutés" or "Les plus menaçants")
    for i, row in ipairs(h.feared) do
        local e = list[i]
        row.enemy = e
        if e then
            UI.SetClassIcon(row.icon, e.class)
            row.name:SetText(UI.ClassName(e.display, e.class) .. (e.nickname and ("  |cff999999« " .. e.nickname .. " »|r") or ""))
            local bits = {}
            if e.sworn then bits[#bits + 1] = "|cffcc2a1aENNEMI JURÉ|r" end
            local l = Views.Total(e.losses)
            if l > 0 then bits[#bits + 1] = "nous a vaincus " .. l .. " fois" end
            if e.presentAtDeaths > 0 then bits[#bits + 1] = "présent à " .. e.presentAtDeaths .. " mort(s)" end
            if #bits == 0 then
                if e.level then bits[#bits + 1] = "niveau " .. e.level end
                bits[#bits + 1] = e.lastSeen and ("croisé " .. UI.Ago(e.lastSeen)) or "jamais croisé"
            end
            row.sub:SetText(table.concat(bits, "  ·  "))
            row.record:SetText("|cff66dd66V " .. Views.Total(e.wins) .. "|r  |cffdd5544D " .. l .. "|r")
            row:Show()
        else
            row:Hide()
        end
    end
    h.fearedEmpty:SetText(#list == 0 and "Aucun ennemi connu.\nCeux que la guilde croise en jeu apparaîtront ici." or "")

    -- News: every encounter of every enemy, most recent first.
    local seen, items = {}, {}
    for _, e in ipairs(enemies) do
        for _, ev in ipairs(e.encounters) do
            local id = (ev.id or tostring(ev)) .. "@" .. e.key
            if not seen[id] then seen[id] = true; items[#items + 1] = { e = e, ev = ev } end
        end
    end
    table.sort(items, function(a, b) return (a.ev.t or 0) > (b.ev.t or 0) end)
    for i, n in ipairs(h.news) do
        local item = items[i]
        n.ago:SetText(item and UI.Ago(item.ev.t) or "")
        n.line:SetText(item and newsLine(item.e, item.ev) or "")
    end
    h.newsEmpty:SetText(#items == 0 and "Rien à signaler sur le front.\nLes rencontres avec la guilde rivale s'afficheront ici." or "")

    h.posterCount = #posters
    h.postersLink:SetLabel(#posters > 0 and ("Voir les " .. #posters .. " avis de recherche ›")
        or "Placarder le premier avis de recherche")
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

    function c:SetView(v) self.view = v; self.detail = nil; self:Refresh() end
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
        d:SetShown(detailEnemy ~= nil)
        if detailEnemy then self:ShowDetail(detailEnemy) return end
        if self.view == "home" then refreshHome(self, ds, postersList, enemies) return end

        if self.view == "registry" then
            self.registry:SetItems(enemies, "Aucun ennemi enregistré.\nLes membres de la guilde rivale (armurerie) et ceux croisés en jeu apparaîtront ici,\nou ajoute-les avec « + Ennemi ».")
            return
        end
        local pages = math.max(1, math.ceil(#postersList / PER_PAGE))
        self.page = math.max(1, math.min(self.page, pages))
        for i, f in ipairs(posters.items) do
            local poster = postersList[(self.page - 1) * PER_PAGE + i]
            f.poster = poster
            if poster then fillPoster(f, poster); f:Show() else f:Hide() end
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
