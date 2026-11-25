-- UI/Trade.lua: card trades between members (Core/Trade.lua).
--   * UI.ShowTrades(): offers received (accept, decline), sent (withdraw) and past ones;
--   * UI.ShowTradeComposer(to, wantId): a new offer, my cards on the left, theirs on the
--     right, the card under the mouse shown large in between. Nothing asked = a gift.
local _, ns = ...
local UI = ns.UI
local Album, Trade = ns.Album, ns.Trade

local PAD = 34

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function cardsById(ds) return Album.Known(ds) end

local function cardOf(byId, id)
    return byId[id] or { id = id, series = "faits", rarity = "common", name = "Carte inconnue",
        flavor = "Cette carte n'est pas encore arrivée chez toi (catalogue pas encore synchronisé)." }
end

local function colored(card)
    local r = Album.Rarity(card.rarity).color
    return (card.shiny and (UI.SHINY_MARK .. " ") or "") .. "|c" .. UI.ColorHex(r[1], r[2], r[3]) .. tostring(card.name) .. "|r"
end

local function names(byId, ids)
    local out = {}
    for i, id in ipairs(ids) do out[i] = colored(cardOf(byId, id)) end
    return table.concat(out, ", ")
end

local function who(guid, name) return ns.Store.DisplayName(guid, name) or name or "?" end

-- Members the player can trade with: with the addon, known by GUID, not the player.
function UI.TradePartners(ds)
    local out = {}
    for _, m in ipairs(ns.Views.Members(ds)) do
        if m.hasAddon and m.guid and m.guid ~= ds.me then out[#out + 1] = m end
    end
    return out
end

local function frame(w, h)
    local f = CreateFrame("Frame", nil, UI.GetWindow())
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    UI.Skin(f, "window")
    f:Hide()
    return f
end

local function cardTooltip(card, extra)
    local lines = { { Album.Rarity(card.rarity).label .. " · " .. UI.SeriesLabel(card.series), 0.7, 0.7, 0.7 } }
    if card.flavor and card.flavor ~= "" then lines[#lines + 1] = card.flavor end
    for _, l in ipairs(extra or {}) do lines[#lines + 1] = l end
    return colored(card), lines
end

-- Shows the cards of an offer large: what is given, then what is asked.
local function preview(o, byId, onClose)
    local function list(ids)
        local out = {}
        for i, id in ipairs(ids) do out[i] = cardOf(byId, id) end
        return out
    end
    local giver = o.from == ns.Store.Dataset().me and "Tu donnes" or (who(o.from, o.fromName) .. " donne")
    local second
    if #o.want > 0 then
        second = function()
            UI.ShowBoosterReveal(list(o.want), {}, { preview = true, title = "En échange de", hint = "Les cartes demandées.",
                onClose = onClose })
        end
    end
    UI.ShowBoosterReveal(list(o.give), {}, { preview = true, title = giver, onNext = second, onClose = not second and onClose or nil,
        hint = #o.want > 0 and "« Cartes suivantes » : ce qui est demandé en échange." or "Un cadeau : rien n'est demandé en échange." })
end

------------------------------------------------------------------------
-- Offers window
------------------------------------------------------------------------
local STATUS = {
    accepted = "|cff66dd66échange fait|r", declined = "|cffcc5544refusé|r", cancelled = "|cff999999retiré|r",
    expired = "|cff999999expiré|r", failed = "|cffcc5544impossible : une carte n'était plus disponible|r",
}

local trades

local function describe(ds, byId, o)
    local mine = o.from == ds.me
    local other = mine and who(o.to, o.toName) or who(o.from, o.fromName)
    local gift = #o.want == 0
    local title
    if o.status == "pending" then
        local left = math.max(1, math.ceil((o.t + Trade.TTL - ((GetServerTime and GetServerTime()) or time())) / 86400))
        if mine then
            title = (gift and "Cadeau pour %s" or "Offre à %s"):format(other) .. ("  |cff999999en attente, expire dans %d j|r"):format(left)
        else
            title = (gift and "%s t'offre des cartes" or "%s te propose un échange"):format(other)
                .. ("  |cff999999expire dans %d j|r"):format(left)
        end
    else
        title = "|cff999999" .. UI.Date(o.at or o.t) .. "|r  " .. (gift and (mine and "Cadeau à " or "Cadeau de ")
            or "Échange avec ") .. other .. " : " .. (STATUS[o.status] or o.status)
    end
    local give = names(byId, o.give)
    local detail
    if mine then
        detail = "Tu donnes : " .. give .. (gift and "" or ("   ·   contre : " .. names(byId, o.want)))
    else
        detail = "Tu reçois : " .. give .. (gift and "" or ("   ·   contre ta : " .. names(byId, o.want)))
    end
    return title, detail
end

local function buildTrades()
    local f = frame(UI.CONTENT_W - 20, UI.CONTENT_H - 10)
    local t = UI.Title(f, 20)
    t:SetPoint("TOPLEFT", PAD, -PAD + 4)
    t:SetText("Échanges de cartes")
    f.close = UI.Button(f, "Fermer", 90, 24, function() f:Hide() end)
    f.close:SetPoint("TOPRIGHT", -PAD + 4, -PAD + 6)
    f.new = UI.Button(f, "Nouvelle offre", 130, 24, function()
        f:Hide()
        UI.ShowTradeComposer()
    end)
    f.new:SetPoint("RIGHT", f.close, "LEFT", -8, 0)
    f.info = UI.Text(f, 11, UI.C.dim)
    f.info:SetPoint("TOPLEFT", PAD, -PAD - 24)
    f.info:SetWidth(f:GetWidth() - 2 * PAD)
    f.error = UI.Text(f, 11, UI.C.red)
    f.error:SetPoint("BOTTOMLEFT", PAD, PAD - 10)
    f.error:SetWidth(f:GetWidth() - 2 * PAD)

    local width = f:GetWidth() - 2 * PAD + 8
    f.list = UI.List(f, width, f:GetHeight() - 2 * PAD - 60, 50, function(row)
        row.title = UI.Text(row, 12, UI.C.gold)
        row.title:SetPoint("TOPLEFT", 6, -5)
        row.title:SetPoint("RIGHT", -250, 0)
        row.title:SetWordWrap(false)
        row.detail = UI.Text(row, 11)
        row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
        row.detail:SetPoint("RIGHT", -250, 0)
        row.detail:SetWordWrap(false)
        row.see = UI.Button(row, "Voir", 60, 22, function(self) f:See(self:GetParent().item) end)
        row.see:SetPoint("RIGHT", -170, 0)
        row.a = UI.Button(row, "Accepter", 80, 22, function(self) f:Act(self:GetParent().item, "a") end)
        row.a:SetPoint("RIGHT", -86, 0)
        row.b = UI.Button(row, "Refuser", 80, 22, function(self) f:Act(self:GetParent().item, "b") end)
        row.b:SetPoint("RIGHT", -2, 0)
        UI.Tooltip(row, function(self)
            local o = self.item
            if not o then return end
            local lines = {}
            local ds = ns.Store.Dataset()
            local byId = f.byId or cardsById(ds)
            lines[#lines + 1] = { o.from == ds.me and "Tu donnes :" or "Tu reçois :", 1, 0.82, 0 }
            for _, id in ipairs(o.give) do lines[#lines + 1] = "  " .. colored(cardOf(byId, id)) end
            if #o.want > 0 then
                lines[#lines + 1] = { o.from == ds.me and "Tu demandes :" or "Il te demande :", 1, 0.82, 0 }
                for _, id in ipairs(o.want) do lines[#lines + 1] = "  " .. colored(cardOf(byId, id)) end
            end
            return self.title:GetText(), lines
        end)
    end, function(row, o)
        local ds = f.ds
        row.title:SetText(o.titleText)
        row.detail:SetText(o.detailText)
        local incoming = o.status == "pending" and o.to == ds.me
        local outgoing = o.status == "pending" and o.from == ds.me
        row.a:SetShown(incoming)
        row.b:SetShown(incoming or outgoing)
        row.b:SetLabel(outgoing and "Retirer" or "Refuser")
        -- an offer that can no longer go through stays clickable: the click says why
        if incoming then row.a:SetAlpha(Trade.CanAccept(ds, o) and 1 or 0.45) end
        row:SetAlpha(o.status == "pending" and 1 or 0.75)
    end)
    f.list:SetPoint("TOPLEFT", PAD - 4, -PAD - 44)

    function f:See(o)
        if not o then return end
        self:Hide()
        preview(o, self.byId or cardsById(ns.Store.Dataset()), function() UI.ShowTrades() end)
    end

    function f:Act(o, button)
        if not o then return end
        local ds = ns.Store.Dataset()
        local ev, why
        if o.from == ds.me then
            -- No server: an accept sent before the withdrawal reached the recipient still
            -- wins (the earlier of the two counts, the same on every client). Say so.
            local name = ns.Store.DisplayName(o.to, o.toName) or o.toName or "?"
            UI.Dialogs.Confirm("Retirer l'offre",
                ("Si %s a déjà accepté sans avoir encore reçu ton retrait, l'échange se fera quand même : "
                .. "tu le verras à la prochaine synchronisation."):format(name),
                "Retirer", function()
                    local ev2, why2 = Trade.Cancel(ns.Store.Dataset(), o.id)
                    self.error:SetText(ev2 and "" or (why2 or "Impossible."))
                    UI.Refresh()
                    self:Refresh()
                end)
            return
        elseif button == "a" then
            ev, why = Trade.Reply(ds, o.id, true)
        else
            ev, why = Trade.Reply(ds, o.id, false)
        end
        if not ev then self.error:SetText(why or "Impossible.") return end
        self.error:SetText("")
        if button == "a" and o.to == ds.me then
            ds = ns.Store.Dataset()
            local done = ds.trades.offers[o.id]
            if done and done.status == "accepted" then
                self:Hide()
                preview(done, cardsById(ds), function() UI.ShowTrades() end)
                UI.Refresh()
                return
            end
        end
        UI.Refresh()
        self:Refresh()
    end

    function f:Refresh()
        local ds = ns.Store.Dataset()
        self.ds = ds
        self.byId = cardsById(ds)
        local items = {}
        for _, o in ipairs(Trade.Incoming(ds)) do items[#items + 1] = o end
        for _, o in ipairs(Trade.Outgoing(ds)) do items[#items + 1] = o end
        for _, o in ipairs(Trade.History(ds, 30)) do items[#items + 1] = o end
        for _, o in ipairs(items) do o.titleText, o.detailText = describe(ds, self.byId, o) end
        local why = Trade.Unavailable(ds)
        self.new:SetDisabled(why ~= nil)
        self.info:SetText(why or ("Propose tes cartes aux autres membres, contre les leurs ou en cadeau. Une offre attend la réponse"
            .. " jusqu'à %d jours ; les cartes proposées restent à toi tant qu'elle n'est pas acceptée."):format(Trade.TTL / 86400))
        self.list:SetItems(items, "Aucun échange pour l'instant.\n« Nouvelle offre » pour proposer tes cartes à un membre.")
    end
    return f
end

function UI.ShowTrades()
    UI.Open("album")
    trades = trades or buildTrades()
    trades.error:SetText("")
    trades:Refresh()
    trades:Show()
    return trades
end

------------------------------------------------------------------------
-- New offer
------------------------------------------------------------------------
local LIST_W, LIST_H, ROW_H = 250, 248, 24
local composer

-- Rows of a side: { card, n, tag } sorted: what the other lacks first, then doubles, then rarity.
local function sideItems(byId, mine, theirs, lacksLabel)
    local items = {}
    for id, n in pairs(mine or {}) do
        if n > 0 then
            local card = cardOf(byId, id)
            local lacks = ((theirs or {})[id] or 0) == 0
            items[#items + 1] = { card = card, id = id, n = n, lacks = lacks, tag = lacks and lacksLabel or nil }
        end
    end
    table.sort(items, function(a, b)
        if a.lacks ~= b.lacks then return a.lacks end
        if (a.n > 1) ~= (b.n > 1) then return a.n > 1 end
        local ra, rb = Album.RARITY_INDEX[a.card.rarity] or 0, Album.RARITY_INDEX[b.card.rarity] or 0
        if ra ~= rb then return ra > rb end
        if a.card.name ~= b.card.name then return tostring(a.card.name) < tostring(b.card.name) end
        return a.id < b.id
    end)
    return items
end

-- What a side shows: its filters (name, rarity, missing / doubles), the picked cards
-- always first and always shown, whatever the filters.
local function filtered(items, picked, filter)
    local needle = UI.Fold(filter.search):match("^%s*(.-)%s*$")
    local first, rest = {}, {}
    for _, item in ipairs(items) do
        if picked[item.id] then
            first[#first + 1] = item
        elseif (filter.rarity == "all" or item.card.rarity == filter.rarity)
            and (filter.show == "all" or (filter.show == "lacks" and item.lacks) or (filter.show == "doubles" and item.n > 1))
            and (needle == "" or UI.Fold(item.card.name):find(needle, 1, true) ~= nil) then
            rest[#rest + 1] = item
        end
    end
    for _, item in ipairs(rest) do first[#first + 1] = item end
    return first
end

local RARITY_OPTS = { { value = "all", label = "Toutes raretés" } }
for _, r in ipairs(Album.RARITIES) do
    RARITY_OPTS[#RARITY_OPTS + 1] = { value = r.key, label = "|c" .. UI.ColorHex(r.color[1], r.color[2], r.color[3]) .. r.label .. "|r" }
end
local SHOW_OPTS = {
    give = { { value = "all", label = "Toutes" }, { value = "lacks", label = "Qui lui manquent" }, { value = "doubles", label = "Mes doublons" } },
    want = { { value = "all", label = "Toutes" }, { value = "lacks", label = "Qui me manquent" }, { value = "doubles", label = "Ses doublons" } },
}

local function buildComposer()
    local f = frame(UI.CONTENT_W - 20, UI.CONTENT_H - 10)
    f.give, f.want = {}, {}
    f.filters = { give = { search = "", rarity = "all", show = "all" }, want = { search = "", rarity = "all", show = "all" } }
    f.items = { give = {}, want = {} }
    local t = UI.Title(f, 20)
    t:SetPoint("TOPLEFT", PAD, -PAD + 4)
    t:SetText("Nouvelle offre")
    local with = UI.Text(f, 12)
    with:SetPoint("LEFT", t, "RIGHT", 24, -2)
    with:SetText("avec")
    f.member = UI.Dropdown(f, 190, function()
        local opts = {}
        for _, m in ipairs(UI.TradePartners(ns.Store.Dataset())) do
            opts[#opts + 1] = { value = m.guid, label = UI.ClassName(m.display, m.class) }
        end
        if #opts == 0 then opts[1] = { value = "", label = "Aucun membre avec l'addon" } end
        return opts
    end, function(v)
        if v ~= f.to then f.to, f.want = v ~= "" and v or nil, {} end
        f:Refresh()
    end)
    f.member:SetPoint("LEFT", with, "RIGHT", 8, 0)

    local function side(key, label, x)
        local head = UI.Text(f, 12, UI.C.gold)
        head:SetPoint("TOPLEFT", x, -PAD - 34)
        f[key .. "Head"] = head
        f[key .. "Label"] = label
        local filter = f.filters[key]
        -- name search
        local search = UI.EditBox(f, LIST_W - 10, 22, false, 40)
        search:SetPoint("TOPLEFT", x, -PAD - 52)
        local hint = UI.Text(search, 12, UI.C.dim)
        hint:SetPoint("LEFT", 7, 0)
        hint:SetText("Rechercher…")
        search.edit:SetScript("OnTextChanged", function(self)
            local text = self:GetText() or ""
            hint:SetShown(text == "")
            if text ~= filter.search then filter.search = text; f:Update() end
        end)
        f[key .. "Search"] = search
        -- rarity, then missing / doubles
        local rarity = UI.Dropdown(f, 120, RARITY_OPTS, function(v) filter.rarity = v; f:Update() end)
        rarity:SetPoint("TOPLEFT", x, -PAD - 78)
        rarity:SetValue("all")
        local show = UI.Dropdown(f, 120, SHOW_OPTS[key], function(v) filter.show = v; f:Update() end)
        show:SetPoint("LEFT", rarity, "RIGHT", 6, 0)
        show:SetValue("all")
        f[key .. "Rarity"], f[key .. "Show"] = rarity, show
        local list = UI.List(f, LIST_W, LIST_H, ROW_H, function(row)
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints()
            row.sel:SetColorTexture(0.55, 0.38, 0.12, 0.45)
            row.mark = UI.Text(row, 12, UI.C.gold)
            row.mark:SetPoint("LEFT", 4, 0)
            row.mark:SetJustifyV("MIDDLE")
            row.name = UI.Text(row, 12)
            row.name:SetPoint("LEFT", 18, 0)
            row.name:SetPoint("RIGHT", -70, 0)
            row.name:SetWordWrap(false)
            row.name:SetJustifyV("MIDDLE")
            row.tag = UI.Text(row, 10, UI.C.green)
            row.tag:SetPoint("RIGHT", -4, 0)
            row.tag:SetJustifyV("MIDDLE")
            row:SetScript("OnClick", function(self) UI.Click(); f:Toggle(key, self.item) end)
            row:SetScript("OnEnter", function(self) f:Show1(self.item) end)
        end, function(row, item)
            local picked = f[key][item.id] ~= nil
            row.sel:SetShown(picked)
            row.mark:SetText(picked and "+" or "")
            row.name:SetText(colored(item.card) .. (item.n > 1 and ("  |cff999999x" .. item.n .. "|r") or ""))
            row.tag:SetText(item.tag or "")
        end)
        list:SetPoint("TOPLEFT", x - 4, -PAD - 106)
        f[key .. "List"] = list
    end
    side("give", "Tu donnes", PAD)
    side("want", "Tu demandes", f:GetWidth() - PAD - LIST_W + 10)

    -- the card under the mouse, large, between the two lists
    f.big = UI.CreateCard(f)
    f.big:SetPoint("TOP", 0, -PAD - 70)
    f.big:SetScript("OnClick", nil)
    f.big:Hide()

    f.summary = UI.Text(f, 11, UI.C.dim)
    f.summary:SetPoint("BOTTOMLEFT", PAD, PAD + 18)
    f.summary:SetWidth(f:GetWidth() - 2 * PAD - 260)
    f.error = UI.Text(f, 11, UI.C.red)
    f.error:SetPoint("BOTTOMLEFT", PAD, PAD - 4)
    f.error:SetWidth(f:GetWidth() - 2 * PAD - 260)
    f.cancel = UI.Button(f, "Annuler", 90, 24, function() f:Hide(); UI.ShowTrades() end)
    f.cancel:SetPoint("BOTTOMRIGHT", -PAD + 4, PAD - 6)
    f.send = UI.Button(f, "Proposer", 140, 24, function() f:Send() end)
    f.send:SetPoint("RIGHT", f.cancel, "LEFT", -8, 0)

    function f:Show1(item)
        if not item then return end
        UI.FillCard(self.big, item.card, item.n)
        self.big:Show()
    end

    local function count(set)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        return n
    end

    function f:Toggle(key, item)
        if not item then return end
        local set = self[key]
        if set[item.id] then set[item.id] = nil
        elseif count(set) >= Trade.MAX_CARDS then
            self.error:SetText(("Pas plus de %d cartes de chaque côté."):format(Trade.MAX_CARDS))
            return
        else set[item.id] = true end
        self.error:SetText("")
        self:Show1(item)
        self:Update()
    end

    local function ids(set)
        local out = {}
        for id in pairs(set) do out[#out + 1] = id end
        table.sort(out)
        return out
    end

    function f:Send()
        local ds = ns.Store.Dataset()
        local name
        for _, m in ipairs(UI.TradePartners(ds)) do if m.guid == self.to then name = m.display end end
        local ev, why = Trade.Offer(ds, self.to, name, ids(self.give), ids(self.want))
        if not ev then self.error:SetText(why or "Impossible.") return end
        self:Hide()
        UI.Refresh()
        UI.ShowTrades()
    end

    -- Rebuilds both sides from the dataset, then shows them.
    function f:Refresh()
        local ds = ns.Store.Dataset()
        local byId = cardsById(ds)
        local mine = Trade.Tradable(ds)
        local theirs = self.to and Trade.CollectionOf(ds, self.to) or {}
        -- drop picks no longer available (a trade went through meanwhile)
        for id in pairs(self.give) do if not mine[id] then self.give[id] = nil end end
        for id in pairs(self.want) do if not theirs[id] then self.want[id] = nil end end
        self.member:SetValue(self.to or "")
        if not self.to then self.member.label:SetText("Choisis un membre") end
        self.other = "lui"
        for _, m in ipairs(UI.TradePartners(ds)) do if m.guid == self.to then self.other = m.display end end
        self.items.give = sideItems(byId, mine, theirs, self.to and "il ne l'a pas" or nil)
        self.items.want = self.to and sideItems(byId, theirs, ds.collection, "tu ne l'as pas") or {}
        self.unavailable = Trade.Unavailable(ds)
        self:Update()
    end

    -- Filters the sides and updates counts and buttons, without rebuilding (each keystroke).
    function f:Update()
        local other = self.other or "lui"
        self.giveHead:SetText(("Tu donnes (%d/%d)"):format(count(self.give), Trade.MAX_CARDS))
        self.wantHead:SetText(("Tu demandes (%d/%d)"):format(count(self.want), Trade.MAX_CARDS))
        local function empty(key, none)
            if #self.items[key] == 0 then return none end
            return "Aucune carte ne correspond à ces filtres."
        end
        self.giveList:SetItems(filtered(self.items.give, self.give, self.filters.give), empty("give",
            "Aucune carte à proposer.\nLes cartes d'un booster ouvert quand ton album était privé ne s'échangent pas."))
        self.wantList:SetItems(filtered(self.items.want, self.want, self.filters.want), empty("want",
            self.to and "Aucune carte dans sa collection." or "Choisis d'abord un membre."))
        local gift = count(self.want) == 0
        self.send:SetLabel(gift and "Offrir" or "Proposer l'échange")
        self.send:SetDisabled(not self.to or count(self.give) == 0)
        local why = self.unavailable
        if why then
            self.summary:SetText(why)
        elseif not self.to then
            self.summary:SetText("Choisis un membre, puis les cartes à donner et à demander.")
        elseif count(self.give) == 0 then
            self.summary:SetText("Clique les cartes à donner, à gauche, et celles que tu veux de " .. other .. ", à droite.")
        else
            self.summary:SetText(gift and ("Rien demandé : c'est un cadeau pour %s."):format(other)
                or ("%s devra accepter. Les cartes restent à toi d'ici là."):format(other))
        end
    end
    return f
end

-- to: member GUID (optional); wantId: a card of theirs already picked (optional).
function UI.ShowTradeComposer(to, wantId)
    UI.Open("album")
    if trades then trades:Hide() end
    composer = composer or buildComposer()
    if to and to ~= composer.to then composer.give, composer.want = {}, {} end
    composer.to = to or composer.to
    if wantId then composer.want[wantId] = true end
    composer.error:SetText("")
    composer.big:Hide()
    composer:Refresh()
    composer:Show()
    return composer
end
