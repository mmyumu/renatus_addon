-- UI/TabAlbum.lua: guild card album (collection, sets, boosters).
local _, ns = ...
local UI = ns.UI
local Album = ns.Album

local CARD_W, CARD_H = 124, 168
local COLS, ROWS = 5, 2
local PER_PAGE = COLS * ROWS

------------------------------------------------------------------------
-- Card rendering (shared by the grid and booster opening)
------------------------------------------------------------------------
function UI.CreateCard(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(CARD_W, CARD_H)
    UI.Box(f, { 0.12, 0.09, 0.07, 1 }, UI.C.border, 3)
    f.art = f:CreateTexture(nil, "ARTWORK")
    f.art:SetSize(64, 64)
    f.art:SetPoint("TOP", 0, -30)
    f.name = UI.Title(f, 13, { 1, 1, 1 })
    f.name:SetPoint("TOP", 0, -8)
    f.name:SetWidth(CARD_W - 10)
    f.name:SetJustifyH("CENTER")
    f.name:SetWordWrap(false)
    f.flavor = UI.Text(f, 10, UI.C.text)
    f.flavor:SetPoint("TOP", f.art, "BOTTOM", 0, -8)
    f.flavor:SetWidth(CARD_W - 14)
    f.flavor:SetJustifyH("CENTER")
    f.flavor:SetMaxLines(3)
    f.rarity = UI.Text(f, 10)
    f.rarity:SetPoint("BOTTOM", 0, 8)
    f.rarity:SetJustifyH("CENTER")
    f.count = UI.Title(f, 13, UI.C.gold)
    f.count:SetPoint("TOPRIGHT", -6, -26)
    f.count:SetJustifyH("RIGHT")
    f.unknown = UI.Title(f, 40, { 0.35, 0.3, 0.25 })
    f.unknown:SetPoint("CENTER", 0, 4)
    f.unknown:SetText("?")
    UI.Tooltip(f, function(self)
        local card = self.card
        if not card then return nil end
        local r = Album.Rarity(card.rarity)
        if not self.owned then return "Carte inconnue", { "Série : " .. UI.SeriesLabel(card.series), { r.label, r.color[1], r.color[2], r.color[3] } } end
        return card.name, { { r.label, r.color[1], r.color[2], r.color[3] }, "Série : " .. UI.SeriesLabel(card.series), card.flavor or "" }
    end)
    return f
end

function UI.FillCard(f, card, count)
    f.card, f.owned = card, (count or 0) > 0
    local r = Album.Rarity(card.rarity)
    if f.owned then
        UI.Box(f, { 0.12, 0.09, 0.07, 1 }, { r.color[1], r.color[2], r.color[3], 1 }, 3)
        if card.icon then
            f.art:SetTexture(card.icon)
            f.art:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        else
            UI.SetClassIcon(f.art, card.class)
        end
        f.art:Show()
        f.name:SetText(card.name)
        if card.class then f.name:SetTextColor(UI.ClassColor(card.class)) else f.name:SetTextColor(1, 1, 1) end
        f.flavor:SetText(card.flavor or "")
        f.rarity:SetText(r.label)
        f.rarity:SetTextColor(r.color[1], r.color[2], r.color[3])
        f.count:SetText(count > 1 and ("x" .. count) or "")
        f.unknown:Hide()
        f:SetAlpha(1)
    else
        UI.Box(f, { 0.06, 0.05, 0.04, 1 }, { 0.25, 0.2, 0.15, 1 }, 3)
        f.art:Hide()
        f.name:SetText("")
        f.flavor:SetText("")
        f.rarity:SetText(r.label)
        f.rarity:SetTextColor(0.4, 0.4, 0.4)
        f.count:SetText("")
        f.unknown:Show()
        f:SetAlpha(0.85)
    end
end

function UI.SeriesLabel(key)
    for _, s in ipairs(Album.SERIES) do if s.key == key then return s.label end end
    return key
end

------------------------------------------------------------------------
-- Booster opening
------------------------------------------------------------------------
local reveal
local function showReveal(cards, collection)
    if not reveal then
        reveal = CreateFrame("Frame", nil, UI.GetWindow())
        reveal:SetFrameStrata("DIALOG")
        reveal:SetSize(5 * (CARD_W + 10) + 30, CARD_H + 110)
        reveal:SetPoint("CENTER")
        reveal:EnableMouse(true)
        UI.Skin(reveal, "window")
        reveal.title = UI.Title(reveal, 20)
        reveal.title:SetPoint("TOP", 0, -12)
        reveal.title:SetJustifyH("CENTER")
        reveal.title:SetText("Booster ouvert !")
        reveal.cards = {}
        for i = 1, Album.BOOSTER_SIZE do
            local f = UI.CreateCard(reveal)
            f:SetPoint("TOPLEFT", 15 + (i - 1) * (CARD_W + 10), -44)
            f.new = UI.Text(f, 10, UI.C.green)
            f.new:SetPoint("TOPLEFT", 6, -26)
            reveal.cards[i] = f
        end
        local ok = UI.Button(reveal, "Ranger dans l'album", 170, 24, function() reveal:Hide() end)
        ok:SetPoint("BOTTOM", 0, 14)
    end
    for i, f in ipairs(reveal.cards) do
        local card = cards[i]
        if card then
            UI.FillCard(f, card, 1)
            f.new:SetText(collection[card.id] == 1 and "NOUVEAU" or "")
            f:Show()
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
        if not ds.isDemo or (ds.boosters or 0) <= 0 then return end
        local cards = Album.Catalogue(ds)
        ds.boostersOpened = (ds.boostersOpened or 0) + 1
        ds.boosters = ds.boosters - 1
        local got = Album.BoosterContents(cards, ds.me .. ":booster:" .. ds.boostersOpened)
        for _, card in ipairs(got) do ds.collection[card.id] = (ds.collection[card.id] or 0) + 1 end
        showReveal(got, ds.collection)
        c:Refresh()
    end)
    c.booster:SetPoint("TOPRIGHT", -4, -6)
    UI.Tooltip(c.booster, function()
        local ds = ns.Store.Dataset()
        if ds.isDemo then return "Booster", { "5 cartes. Le contenu est déterminé par l'identifiant du booster : impossible de relancer le tirage." } end
        return "Boosters", { "Les boosters s'obtiendront par l'activité de guilde (règles à choisir), une fois la synchronisation en place." }
    end)

    local seriesOpts = { { value = "all", label = "Toutes les séries" } }
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
        f:SetPoint("TOPLEFT", gapX + col * (CARD_W + gapX), -84 - line * (CARD_H + 12))
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
        local owned, total, doubles = Album.Progress(cards, ds.collection, self.series ~= "all" and self.series or nil)
        self.progress:SetText(("%d / %d cartes  ·  %d doublon(s)"):format(owned, total, doubles))
        local nb = ds.boosters or 0
        self.booster:SetLabel(ds.isDemo and ("Ouvrir un booster (" .. nb .. ")") or "Boosters (bientôt)")
        self.booster:SetDisabled(not ds.isDemo or nb <= 0)

        local visible = {}
        for _, card in ipairs(cards) do
            local n = ds.collection[card.id] or 0
            if (self.series == "all" or card.series == self.series) and (not self.onlyOwned or n > 0) then
                table.insert(visible, card)
            end
        end
        table.sort(visible, function(a, b)
            if a.series ~= b.series then return a.series < b.series end
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

UI.RegisterTab({ key = "album", label = "Album", icon = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01", order = 60,
    build = build, refresh = function(c) c:Refresh() end })
