-- UI/TabAlbum.lua: guild card album (collection, sets, boosters).
local _, ns = ...
local UI = ns.UI
local Album = ns.Album

local CARD_W, CARD_H = 132, 184
local COLS, ROWS = 5, 2
local PER_PAGE = COLS * ROWS
local ART_W, ART_H = CARD_W - 20, 78

------------------------------------------------------------------------
-- Card art: the first candidate icon present on this client.
------------------------------------------------------------------------
local ICONS = "Interface\\Icons\\"
local artCache = {}

-- True if the client has this file (unknown = assumed present).
function UI.HasFile(path)
    if not GetFileIDFromPath then return true end
    local ok, id = pcall(GetFileIDFromPath, path)
    if not ok then return true end
    return id ~= nil
end

function UI.CardArt(card)
    if card.icon then return card.icon end
    if not card.icons or #card.icons == 0 then return nil end
    local cached = artCache[card.id]
    if cached then return cached end
    local chosen = ICONS .. card.icons[#card.icons]
    for _, name in ipairs(card.icons) do
        if UI.HasFile(ICONS .. name) then chosen = ICONS .. name break end
    end
    artCache[card.id] = chosen
    return chosen
end

------------------------------------------------------------------------
-- Card rendering (shared by the grid and booster opening)
------------------------------------------------------------------------
function UI.CreateCard(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(CARD_W, CARD_H)
    -- glow behind epic and legendary cards
    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.glow:SetPoint("TOPLEFT", -18, 18)
    f.glow:SetPoint("BOTTOMRIGHT", 18, -18)
    f.glow:SetTexture(UI.MEDIA .. "glow")
    f.glow:SetBlendMode("ADD")
    -- face
    f.base = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    f.base:SetPoint("TOPLEFT", 3, -3)
    f.base:SetPoint("BOTTOMRIGHT", -3, 3)
    f.base:SetColorTexture(0.1, 0.07, 0.05, 1)
    f.leather = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    f.leather:SetPoint("TOPLEFT", 3, -3)
    f.leather:SetPoint("BOTTOMRIGHT", -3, 3)
    f.leather:SetTexture(UI.MEDIA .. "leather", "REPEAT", "REPEAT")
    f.leather:SetHorizTile(true)
    f.leather:SetVertTile(true)
    -- back (unknown card)
    f.back = f:CreateTexture(nil, "BACKGROUND", nil, -5)
    f.back:SetPoint("TOPLEFT", 3, -3)
    f.back:SetPoint("BOTTOMRIGHT", -3, 3)
    f.back:SetTexture(UI.MEDIA .. "cardback")
    -- art window
    f.art = f:CreateTexture(nil, "ARTWORK")
    f.art:SetSize(ART_W, ART_H)
    f.art:SetPoint("TOP", 0, -12)
    local artRim = CreateFrame("Frame", nil, f)
    artRim:SetPoint("TOPLEFT", f.art, "TOPLEFT", -1, 1)
    artRim:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT", 1, -1)
    f.artRim = UI.Edges(artRim, { 0.85, 0.66, 0.3, 1 })
    -- name banner
    f.banner = f:CreateTexture(nil, "ARTWORK")
    f.banner:SetPoint("TOPLEFT", f.art, "BOTTOMLEFT", -2, -4)
    f.banner:SetPoint("TOPRIGHT", f.art, "BOTTOMRIGHT", 2, -4)
    f.banner:SetHeight(20)
    f.banner:SetColorTexture(0.3, 0.06, 0.04, 0.9)
    f.name = UI.Text(f, 11, { 1, 1, 1 })
    f.name:SetPoint("LEFT", f.banner, "LEFT", 3, 0)
    f.name:SetPoint("RIGHT", f.banner, "RIGHT", -3, 0)
    f.name:SetJustifyH("CENTER")
    f.name:SetJustifyV("MIDDLE")
    f.name:SetWordWrap(false)
    f.flavor = UI.Text(f, 9, { 0.88, 0.82, 0.7 })
    f.flavor:SetPoint("TOP", f.banner, "BOTTOM", 0, -5)
    f.flavor:SetWidth(CARD_W - 18)
    f.flavor:SetJustifyH("CENTER")
    f.flavor:SetMaxLines(4)
    f.flavor:SetSpacing(1)
    -- footer: series, rarity gem
    f.series = UI.Text(f, 8, { 0.7, 0.6, 0.45 })
    f.series:SetPoint("BOTTOMLEFT", 9, 8)
    f.series:SetPoint("RIGHT", -24, 0)
    f.series:SetWordWrap(false)
    f.gem = f:CreateTexture(nil, "OVERLAY")
    f.gem:SetSize(13, 13)
    f.gem:SetPoint("BOTTOMRIGHT", -7, 6)
    f.gem:SetTexture(UI.MEDIA .. "gem")
    f.count = UI.Text(f, 11, UI.C.gold)
    f.count:SetPoint("TOPRIGHT", -8, -8)
    f.count:SetJustifyH("RIGHT")
    f.count:SetShadowOffset(1, -1)
    f.unknown = UI.Title(f, 34, { 0.95, 0.78, 0.4 })
    f.unknown:SetPoint("CENTER", 0, 4)
    f.unknown:SetText("?")
    -- frame tinted by rarity
    f.frame = UI.NineSlice(f, "cardframe", 0.25, 18, "OVERLAY")
    f.new = UI.Text(f, 10, { 0.4, 1, 0.4 }, UI.FONT_TITLE)
    f.new:SetPoint("TOPLEFT", 8, -8)
    f.new:SetShadowOffset(1, -1)
    UI.Tooltip(f, function(self)
        local card = self.card
        if not card then return nil end
        local r = Album.Rarity(card.rarity)
        if not self.owned then return "Carte inconnue", { "Série : " .. UI.SeriesLabel(card.series), { r.label, r.color[1], r.color[2], r.color[3] } } end
        return card.name, { { r.label, r.color[1], r.color[2], r.color[3] }, "Série : " .. UI.SeriesLabel(card.series), card.flavor or "" }
    end)
    return f
end

local function tintFrame(f, c, a)
    for _, t in ipairs(f.frame) do t:SetVertexColor(c[1], c[2], c[3], a or 1) end
end

function UI.FillCard(f, card, count, faceDown)
    f.card, f.owned = card, (count or 0) > 0 and not faceDown
    local r = Album.Rarity(card.rarity)
    f.gem:SetVertexColor(r.color[1], r.color[2], r.color[3])
    local face = f.owned
    for _, t in ipairs({ f.leather, f.art, f.banner, f.name, f.flavor, f.artRim[1], f.artRim[2], f.artRim[3], f.artRim[4] }) do
        t:SetShown(face)
    end
    f.back:SetShown(not face)
    f.unknown:Hide()   -- the card back already says "unknown"
    f.new:SetText("")
    if face then
        tintFrame(f, r.color)
        local art = UI.CardArt(card)
        if art then
            f.art:SetTexture(art)
            f.art:SetTexCoord(0.08, 0.92, 0.2, 0.8)   -- wide crop of a square icon
        else
            UI.SetClassIcon(f.art, card.class)
        end
        f.name:SetText(card.name)
        if card.class then f.name:SetTextColor(UI.ClassColor(card.class)) else f.name:SetTextColor(1, 1, 1) end
        f.flavor:SetText(card.flavor or "")
        f.series:SetText(UI.SeriesLabel(card.series))
        f.count:SetText((count or 0) > 1 and ("x" .. count) or "")
        local idx = Album.RARITY_INDEX[card.rarity] or 1
        f.glow:SetShown(idx >= 4)
        f.glow:SetVertexColor(r.color[1], r.color[2], r.color[3], idx >= 5 and 0.55 or 0.3)
        f:SetAlpha(1)
    else
        tintFrame(f, { 0.45, 0.4, 0.35 })
        f.series:SetText(UI.SeriesLabel(card.series))
        f.count:SetText("")
        f.glow:Hide()
        f:SetAlpha(faceDown and 1 or 0.8)
    end
end

function UI.SeriesLabel(key)
    for _, s in ipairs(Album.SERIES) do if s.key == key then return s.label end end
    return key
end

------------------------------------------------------------------------
-- Booster opening: the five cards are dealt face down, then turned one by one.
------------------------------------------------------------------------
local reveal
local function showReveal(cards, collection)
    if not reveal then
        reveal = CreateFrame("Frame", nil, UI.GetWindow())
        reveal:SetFrameStrata("DIALOG")
        reveal:SetSize(5 * (CARD_W + 12) + 40, CARD_H + 120)
        reveal:SetPoint("CENTER")
        reveal:EnableMouse(true)
        UI.Skin(reveal, "window")
        reveal.title = UI.Title(reveal, 22)
        reveal.title:SetPoint("TOP", 0, -24)
        reveal.title:SetJustifyH("CENTER")
        reveal.title:SetText("Booster ouvert !")
        reveal.cards = {}
        for i = 1, Album.BOOSTER_SIZE do
            local f = UI.CreateCard(reveal)
            f:SetPoint("TOPLEFT", 26 + (i - 1) * (CARD_W + 12), -58)
            reveal.cards[i] = f
        end
        reveal.ok = UI.Button(reveal, "Ranger dans l'album", 170, 24, function() reveal:Hide() end)
        reveal.ok:SetPoint("BOTTOM", 0, 22)
    end
    reveal.token = (reveal.token or 0) + 1
    local token = reveal.token
    for i, f in ipairs(reveal.cards) do
        local card = cards[i]
        if card then
            UI.FillCard(f, card, 1, true)
            f:Show()
            local function turn()
                if reveal.token ~= token then return end
                UI.FillCard(f, card, 1)
                f.new:SetText(collection[card.id] == 1 and "NOUVEAU" or "")
                UI.Click()
            end
            if C_Timer then C_Timer.After(0.35 * i, turn) else turn() end
        else
            f:Hide()
        end
    end
    reveal:Show()
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function build(c)
    c.series = "all"
    c.page = 1
    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Album de la Guilde")
    c.progress = UI.Text(c, 11, UI.C.dim)
    c.progress:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)

    c.booster = UI.Button(c, "Ouvrir un booster", 170, 26, function()
        local ds = ns.Store.Dataset()
        if (ds.boosters or 0) <= 0 then return end
        local cards = Album.Catalogue(ds)
        local n = (ds.boostersOpened or 0) + 1
        local got = Album.BoosterContents(cards, ds.me .. ":booster:" .. n)
        if ds.isDemo then
            ds.boostersOpened, ds.boosters = n, ds.boosters - 1
            for _, card in ipairs(got) do ds.collection[card.id] = (ds.collection[card.id] or 0) + 1 end
        else
            local ids = {}
            for i, card in ipairs(got) do ids[i] = card.id end
            ns.Store.Add("BOOSTER_OPEN", { n = n, cards = ids, cv = cards.version }, { keep = true, noExp = true, loc = {} })
            ds = ns.Store.Dataset()
        end
        showReveal(got, ds.collection)
        c:Refresh()
    end)
    c.booster:SetPoint("TOPRIGHT", -4, -6)
    UI.Tooltip(c.booster, function()
        local ds = ns.Store.Dataset()
        return "Booster", { "5 cartes. Le contenu est déterminé par l'identifiant du booster : impossible de relancer le tirage.",
            "On en gagne 1 par jour joué, +1 par niveau, boss vaincu ou sortie avec un membre de la guilde (5 par jour au plus)." }
    end)

    local seriesOpts = { { value = "all", label = "Toutes les séries" },
        { value = "family:guild", label = "— Guilde (toutes)" }, { value = "family:azeroth", label = "— Azeroth (toutes)" } }
    for _, s in ipairs(Album.SERIES) do table.insert(seriesOpts, { value = s.key, label = s.label }) end
    c.seriesDropdown = UI.Dropdown(c, 170, seriesOpts, function(v) c.series = v; c.page = 1; c:Refresh() end)
    c.seriesDropdown:SetPoint("TOPLEFT", 4, -48)
    c.seriesDropdown:SetValue("all")
    c.ownedOnly = UI.Checkbox(c, "Seulement mes cartes", function(v) c.onlyOwned = v; c.page = 1; c:Refresh() end)
    c.ownedOnly:SetPoint("LEFT", c.seriesDropdown, "RIGHT", 14, 0)

    c.prev = UI.Button(c, "<", 28, 22, function() c.page = c.page - 1; c:Refresh() end)
    c.prev:SetPoint("TOPRIGHT", -80, -48)
    c.pageText = UI.Text(c, 11, UI.C.dim)
    c.pageText:SetPoint("LEFT", c.prev, "RIGHT", 4, 0)
    c.pageText:SetWidth(40)
    c.pageText:SetJustifyH("CENTER")
    c.pageText:SetJustifyV("MIDDLE")
    c.next = UI.Button(c, ">", 28, 22, function() c.page = c.page + 1; c:Refresh() end)
    c.next:SetPoint("LEFT", c.pageText, "RIGHT", 4, 0)

    c.cards = {}
    local gapX = math.floor((UI.CONTENT_W - COLS * CARD_W) / (COLS + 1))
    for i = 1, PER_PAGE do
        local f = UI.CreateCard(c)
        local col, line = (i - 1) % COLS, math.floor((i - 1) / COLS)
        f:SetPoint("TOPLEFT", gapX + col * (CARD_W + gapX), -82 - line * (CARD_H + 10))
        c.cards[i] = f
    end
    c.empty = UI.Text(c, 13, UI.C.dim)
    c.empty:SetPoint("TOP", 0, -160)
    c.empty:SetWidth(520)
    c.empty:SetJustifyH("CENTER")
    c.note = UI.Text(c, 10, UI.C.dim)
    c.note:SetPoint("BOTTOMLEFT", 4, 0)
    c.note:SetText("La rareté est celle de la variante de la carte, pas la valeur du membre : chacun a sa légendaire.")

    function c:Refresh()
        local ds = ns.Store.Dataset()
        local cards = Album.Catalogue(ds)
        local family = self.series:match("^family:(.+)$")
        local function inFilter(card)
            if self.series == "all" then return true end
            if family then return (card.azeroth and "azeroth" or "guild") == family end
            return card.series == self.series
        end
        local owned, total, doubles = 0, 0, 0
        for _, card in ipairs(cards) do
            if inFilter(card) then
                total = total + 1
                local n = ds.collection[card.id] or 0
                if n > 0 then owned = owned + 1 end
                if n > 1 then doubles = doubles + n - 1 end
            end
        end
        self.progress:SetText(("%d / %d cartes  ·  %d doublon(s)"):format(owned, total, doubles))
        local nb = ds.boosters or 0
        self.booster:SetLabel("Ouvrir un booster (" .. nb .. ")")
        self.booster:SetDisabled(nb <= 0)

        local visible = {}
        for _, card in ipairs(cards) do
            local n = ds.collection[card.id] or 0
            if inFilter(card) and (not self.onlyOwned or n > 0) then
                table.insert(visible, card)
            end
        end
        local order = {}
        for i, sr in ipairs(Album.SERIES) do order[sr.key] = i end
        table.sort(visible, function(a, b)
            if a.series ~= b.series then return (order[a.series] or 99) < (order[b.series] or 99) end
            local ra, rb = Album.RARITY_INDEX[a.rarity], Album.RARITY_INDEX[b.rarity]
            if ra ~= rb then return ra < rb end
            return a.name < b.name
        end)
        local pages = math.max(1, math.ceil(#visible / PER_PAGE))
        self.page = math.max(1, math.min(self.page, pages))
        for i, f in ipairs(self.cards) do
            local card = visible[(self.page - 1) * PER_PAGE + i]
            if card then UI.FillCard(f, card, ds.collection[card.id] or 0); f:Show() else f:Hide() end
        end
        self.pageText:SetText(self.page .. "/" .. pages)
        self.prev:SetDisabled(self.page <= 1)
        self.next:SetDisabled(self.page >= pages)
        self.empty:SetText(#visible == 0 and "Aucune carte à afficher.\nLe catalogue se construit à partir de l'histoire de la guilde : membres, ennemis jurés, exploits, faits divers." or "")
    end
end

UI.RegisterTab({ key = "album", group = "main", label = "Album", icon = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01", order = 2,
    build = build, refresh = function(c) c:Refresh() end })
