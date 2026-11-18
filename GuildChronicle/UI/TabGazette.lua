-- UI/TabGazette.lua : lecture de la gazette satirique (articles produits hors jeu par le compagnon).
local _, ns = ...
local UI = ns.UI
local Types = ns.Types

local LIST_W = 220

-- Fenetre de redaction : elements du compagnon a publier ou ignorer (un par un).
local review
local function openReview(onDone)
    if review then review:Hide() end
    local f = CreateFrame("Frame", nil, UI.GetWindow())
    review = f
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER")
    f:SetSize(560, 400)
    UI.Box(f, { 0.07, 0.055, 0.04, 0.99 }, UI.C.gold, 2)
    local t = UI.Title(f, 18)
    t:SetPoint("TOPLEFT", 16, -14)
    t:SetText("Rédaction : éléments du compagnon")
    local hint = UI.Text(f, 10, UI.C.dim)
    hint:SetPoint("TOPLEFT", 16, -38)
    hint:SetWidth(528)
    hint:SetText("Rien n'est publié sans toi. Publier = partager avec la guilde, signé de ton nom. "
        .. "Les causes de mort et affrontements viennent de ton journal de combat (provenance « Journal de combat »).")
    local list = UI.List(f, 528, 290, 40, function(row)
        row.label = UI.Text(row, 12)
        row.label:SetPoint("TOPLEFT", 6, -4)
        row.label:SetPoint("RIGHT", -190, 0)
        row.label:SetWordWrap(false)
        row.sub = UI.Text(row, 10, UI.C.dim)
        row.sub:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -3)
        row.sub:SetPoint("RIGHT", -190, 0)
        row.sub:SetWordWrap(false)
        row.pub = UI.Button(row, "Publier", 80, 22, function()
            ns.Press.Publish(row.item); f:Update(); if onDone then onDone() end
        end)
        row.pub:SetPoint("RIGHT", -96, 0)
        row.ign = UI.Button(row, "Ignorer", 80, 22, function()
            ns.Press.Ignore(row.item); f:Update(); if onDone then onDone() end
        end)
        row.ign:SetPoint("RIGHT", -8, 0)
    end, function(row, item)
        row.label:SetText(ns.Press.Label(item))
        local bits = { ns.Press.KINDS[item.kind].label }
        if item.t then table.insert(bits, UI.Date(item.t, true)) end
        if item.refs then table.insert(bits, #item.refs .. " source(s)") end
        if item.note then table.insert(bits, item.note) end
        row.sub:SetText(table.concat(bits, "  ·  "))
    end)
    list:SetPoint("TOPLEFT", 16, -64)
    local close = UI.Button(f, "Fermer", 100, 24, function() f:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -16, 12)
    function f:Update()
        list:SetItems(ns.Press.Pending(), "Rien en attente. Lance le compagnon, puis /reload.")
    end
    f:Update()
    f:Show()
    return f
end

local function build(c)
    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("La Gazette de la Guilde")
    c.press = UI.Button(c, "Rédaction", 130, 22, function() openReview(function() c:Refresh() end) end)
    c.press:SetPoint("TOPRIGHT", -4, -6)
    UI.Tooltip(c.press, "Rédaction", { "Articles et causes de mort produits par l'application compagnon,",
        "à relire avant publication. Nécessite le compagnon et l'addon GuildChronicle_Press." })
    local motto = UI.Text(c, 11, UI.C.dim)
    motto:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    motto:SetText("Toute l'information, rien que l'information, et parfois un peu plus.")

    c.list = UI.List(c, LIST_W, UI.CONTENT_H - 50, 52, function(row)
        row.kind = UI.Text(row, 10, UI.C.red)
        row.kind:SetPoint("TOPLEFT", 6, -4)
        row.title = UI.Text(row, 12)
        row.title:SetPoint("TOPLEFT", row.kind, "BOTTOMLEFT", 0, -2)
        row.title:SetWidth(LIST_W - 26)
        row.title:SetMaxLines(2)
        row.date = UI.Text(row, 10, UI.C.dim)
        row.date:SetPoint("TOPRIGHT", -6, -4)
        row.date:SetJustifyH("RIGHT")
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(0.55, 0.38, 0.12, 0.45)
        row:SetScript("OnClick", function(self) c.selected = self.item.id; c.showSources = false; c:Refresh() end)
    end, function(row, a)
        row.kind:SetText(string.upper(a.kind or "Article"))
        row.title:SetText(a.title or "")
        row.date:SetText(UI.Date(a.t))
        row.sel:SetShown(c.selected == a.id)
    end)
    c.list:SetPoint("TOPLEFT", 0, -46)

    -- Page de journal (parchemin)
    local paper = CreateFrame("Frame", nil, c)
    paper:SetPoint("TOPLEFT", LIST_W + 12, -46)
    paper:SetSize(UI.CONTENT_W - LIST_W - 12, UI.CONTENT_H - 50)
    UI.Box(paper, UI.C.parchment, { 0.3, 0.18, 0.08, 1 }, 2)
    c.paper = paper
    local W = UI.CONTENT_W - LIST_W - 40
    paper.kind = UI.Text(paper, 11, { 0.55, 0.08, 0.05 })
    paper.kind:SetPoint("TOPLEFT", 14, -12)
    paper.title = UI.Title(paper, 19, UI.C.ink)
    paper.title:SetPoint("TOPLEFT", paper.kind, "BOTTOMLEFT", 0, -4)
    paper.title:SetWidth(W)
    paper.title:SetShadowOffset(0, 0)
    paper.meta = UI.Text(paper, 10, UI.C.inkDim)
    paper.meta:SetPoint("TOPLEFT", paper.title, "BOTTOMLEFT", 0, -6)
    paper.meta:SetWidth(W)
    local rule = paper:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.3, 0.18, 0.08, 0.6)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", paper.meta, "BOTTOMLEFT", 0, -6)
    rule:SetWidth(W)
    paper.body = UI.ScrollText(paper, W + 8, UI.CONTENT_H - 210, 13, UI.C.ink)
    paper.body:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -8)
    paper.notice = UI.Text(paper, 10, UI.C.inkDim)
    paper.notice:SetPoint("BOTTOMLEFT", 14, 40)
    paper.notice:SetWidth(W)
    paper.notice:SetText("Article généré à partir d'événements réels. Le ton est inventé, les faits ne le sont pas : consulte les sources.")

    paper.sources = UI.Button(paper, "Sources", 90, 22, function()
        c.showSources = not c.showSources
        c:Refresh()
    end)
    paper.sources:SetPoint("BOTTOMLEFT", 14, 10)
    paper.vote = UI.Button(paper, "Voter pour la une", 140, 22, function()
        local ds = ns.Store.Dataset()
        local a = c.current
        if not a then return end
        if a.voted then return end
        if ds.isDemo then
            a.votes = (a.votes or 0) + 1; a.voted = true
        else
            -- Un vote par membre et par semaine : le dernier compte (calcule dans Views.Articles).
            ns.Store.Add("VOTE", { week = ns.Views.WeekKey(ns.Views.Now()) },
                { refs = { a.id }, vis = "G", prov = "MAN", noExp = true, loc = {} })
        end
        c:Refresh()
    end)
    paper.vote:SetPoint("LEFT", paper.sources, "RIGHT", 8, 0)
    paper.letter = UI.Button(paper, "Courrier des lecteurs", 160, 22, function() UI.Dialogs.Letter() end)
    paper.letter:SetPoint("LEFT", paper.vote, "RIGHT", 8, 0)

    function c:Refresh()
        local ds = ns.Store.Dataset()
        local pending = (not ds.isDemo and ns.Press.Available()) and #ns.Press.Pending() or 0
        self.press:SetLabel(pending > 0 and ("Rédaction (" .. pending .. ")") or "Rédaction")
        self.press:SetShown(not ds.isDemo and ns.Press.Available())
        local articles = {}
        for _, a in ipairs(ds.articles or {}) do table.insert(articles, a) end
        table.sort(articles, function(a, b) return (a.t or 0) > (b.t or 0) end)
        if not self.selected and articles[1] then self.selected = articles[1].id end
        self.list:SetItems(articles, "Aucune édition pour l'instant.")
        local a
        for _, x in ipairs(articles) do if x.id == self.selected then a = x end end
        self.current = a
        if not a then
            paper.kind:SetText("")
            paper.title:SetText("Les rotatives sont à l'arrêt")
            paper.meta:SetText("")
            paper.body:SetText("La gazette est rédigée hors du jeu (application compagnon du rédacteur), à partir du journal de la guilde, "
                .. "puis publiée en jeu par le rédacteur avec le bouton « Rédaction ». Les autres membres la reçoivent par la synchronisation.\n\n"
                .. "En attendant, tape |cff8a1a10/chronicle demo|r pour feuilleter une édition de démonstration.")
            paper.sources:SetDisabled(true)
            paper.vote:SetDisabled(true)
            return
        end
        paper.kind:SetText(string.upper(a.kind or "Article"))
        paper.title:SetText(a.title or "")
        local meta = UI.Date(a.t) .. (a.author and ("  ·  par " .. a.author) or "") .. "  ·  style : " .. (a.style or "?")
            .. "  ·  " .. #(a.refs or {}) .. " source(s)"
        if a.votes and a.votes > 0 then meta = meta .. "  ·  " .. a.votes .. " vote(s) pour la une" end
        paper.meta:SetText(meta)
        paper.sources:SetDisabled(false)
        paper.vote:SetDisabled(a.voted)
        paper.sources:SetLabel(self.showSources and "Article" or "Sources")
        if self.showSources then
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
            paper.body:SetText(table.concat(lines, "\n"))
        else
            paper.body:SetText(a.body or "")
        end
    end
end

UI.RegisterTab({ key = "gazette", label = "Gazette", icon = "Interface\\Icons\\INV_Misc_Note_06", order = 50,
    build = build, refresh = function(c) c:Refresh() end })
