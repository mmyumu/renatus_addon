-- Window.lua: the admin window (/radmin, admin minimap icon), separate from the members'
-- window so that the Renatus addon looks the same for everyone.
--   Rédaction      gazette items from the Renatus Admin app: preview, publish, ignore
--   Guilde rivale  rival guild in force, app proposals (setting + armory roster), manual entry
--   Boosters       how many boosters members earn (guild setting)
--   Diagnostic     sync status, local data, unsupported events, demo mode
-- Publishing is for officers (A.IsOfficer); everyone else can only look.
local _, A = ...
local R = A.R
local UI = R.UI
local Press = A.Press
local GC = R.GuildConfig

local W, H = 760, 540
local PAD = 22
local BODY_TOP = 112
local BODY_W = W - 2 * PAD

local window

local function notify(why)
    if why == "rang" then R.Print("publication refusée : %s", A.RankHelp()) end
end

------------------------------------------------------------------------
-- Rédaction
------------------------------------------------------------------------
local function preview(item)
    if not item then return "Clique un élément pour le relire avant de le publier." end
    local p, lines = item.p, {}
    if item.kind == "ARTICLE" and p.retract == true then
        table.insert(lines, "|cffd4a017" .. Press.Label(item) .. "|r")
        table.insert(lines, "|cff999999Publier retire cet article de son numéro, pour toute la guilde.|r")
    elseif item.kind == "ARTICLE" then
        if p.replaces then
            table.insert(lines, "|cff999999Correction : publier remplace l'article déjà paru, à la même place dans son numéro.|r")
        end
        table.insert(lines, "|cffd4a017" .. tostring(p.title) .. "|r")
        local meta = {}
        for _, v in ipairs({ p.format, p.style, p.ia == true and "rédigé par IA" or nil }) do
            if v then table.insert(meta, tostring(v)) end
        end
        if #meta > 0 then table.insert(lines, "|cff999999" .. table.concat(meta, " · ") .. "|r") end
        table.insert(lines, "")
        table.insert(lines, tostring(p.body or ""))
    elseif item.kind == "EDITION" then
        table.insert(lines, "|cffd4a017" .. Press.Label(item) .. "|r")
        table.insert(lines, "|cff999999Publier la mise en page publie aussi ses articles en attente.|r")
        local layout = R.UI.Newsprint.Sanitize(p)
        for i, pg in ipairs(layout and layout.pages or {}) do
            table.insert(lines, "")
            table.insert(lines, ("Page %d%s"):format(i, pg.title and (" : " .. pg.title) or ""))
            for _, row in ipairs(pg.rows) do
                local cells = {}
                for _, cell in ipairs(row.cells) do
                    local blocks = {}
                    for _, b in ipairs(cell.blocks) do table.insert(blocks, b.t .. (b.a and (" " .. b.a) or "")) end
                    table.insert(cells, ("[%d/12 : %s]"):format(cell.w, table.concat(blocks, ", ")))
                end
                table.insert(lines, "  " .. table.concat(cells, " "))
            end
        end
        table.insert(lines, "\n|cff999999« Aperçu dans la gazette » montre les pages telles que la guilde les verra.|r")
        local sets = Press.EditionCards(item)
        if #sets > 0 then
            table.insert(lines, "")
            for _, cs in ipairs(sets) do table.insert(lines, "Avec : " .. Press.Label(cs)) end
        end
    elseif item.kind == "CARD_SET" then
        table.insert(lines, "|cffd4a017" .. Press.Label(item) .. "|r")
        if type(p.set) == "string" and p.set:find("^fix:") then
            table.insert(lines, "|cff999999Correction du catalogue : la carte garde son numéro, ceux qui l'ont voient la nouvelle version ; une carte retirée ne sort plus des boosters mais reste à ceux qui l'ont.|r")
        else
            table.insert(lines, "|cff999999Publiées avec la mise en page du même numéro. « Aperçu » les montre comme dans l'album.|r")
        end
        table.insert(lines, "")
        for _, c in ipairs(type(p.cards) == "table" and p.cards or {}) do
            if c.del == true then
                table.insert(lines, "Retrait du catalogue : " .. tostring(c.id))
            else
                local r = R.Album.Rarity(c.r)
                local stats = (tonumber(c.fo) and tonumber(c.en)) and ("  " .. c.fo .. "/" .. c.en) or ""
                table.insert(lines, ("|c%sN° %s  %s|r  (%s)%s"):format(UI.ColorHex(r.color[1], r.color[2], r.color[3]),
                    tostring(c.no or "?"), tostring(c.n), r.label, stats))
                if c.f then table.insert(lines, "   |cffbbbbbb" .. tostring(c.f) .. "|r") end
            end
        end
    else
        table.insert(lines, Press.Label(item))
    end
    if item.refs then table.insert(lines, ("\n|cff999999%d source(s) dans le journal de la guilde.|r"):format(#item.refs)) end
    if item.note then table.insert(lines, "|cff999999" .. tostring(item.note) .. "|r") end
    return table.concat(lines, "\n")
end

-- Pending items list with Publish / Ignore; onSelect(item) on row click.
local function itemList(parent, width, height, filter, emptyText, onChanged, onSelect)
    local list
    list = UI.List(parent, width, height, 40, function(row)
        row.label = UI.Text(row, 12)
        row.label:SetPoint("TOPLEFT", 6, -4)
        row.label:SetPoint("RIGHT", -186, 0)
        row.label:SetWordWrap(false)
        row.sub = UI.Text(row, 10, UI.C.dim)
        row.sub:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -3)
        row.sub:SetPoint("RIGHT", -186, 0)
        row.sub:SetWordWrap(false)
        row.pub = UI.Button(row, "Publier", 80, 22, function()
            local _, why = Press.Publish(row.item)
            notify(why)
            onChanged()
        end)
        row.pub:SetPoint("RIGHT", -94, 0)
        row.ign = UI.Button(row, "Ignorer", 80, 22, function() Press.Ignore(row.item); onChanged() end)
        row.ign:SetPoint("RIGHT", -8, 0)
        row:SetScript("OnClick", function(self) if onSelect then onSelect(self.item) end end)
    end, function(row, item)
        row.label:SetText(Press.Label(item))
        local bits = { Press.KINDS[item.kind].label }
        if item.t then table.insert(bits, UI.Date(item.t, true)) end
        if item.refs then table.insert(bits, #item.refs .. " source(s)") end
        row.sub:SetText(table.concat(bits, "  ·  "))
        row.pub:SetDisabled(not A.IsOfficer())
    end)
    function list:Update() self:SetItems(Press.Pending(filter), emptyText) end
    return list
end

local function buildPress(f, page)
    local hint = UI.Text(page, 11, UI.C.dim)
    hint:SetPoint("TOPLEFT", 0, 0)
    hint:SetWidth(BODY_W)
    hint:SetText("Articles préparés par l'application Renatus Admin. Rien n'est diffusé sans « Publier » : "
        .. "l'article part alors à toute la guilde, signé de ton nom.")
    page.list = itemList(page, 440, 360, Press.IsGazetteItem,
        "Rien en attente. Rédige la gazette dans l'application Renatus Admin, puis /reload.",
        function() page.selected = nil; f:Refresh() end,
        function(item) page.selected = item; f:Refresh() end)
    page.list:SetPoint("TOPLEFT", 0, -34)
    page.preview = UI.ScrollText(page, BODY_W - 456, 330, 12)
    page.preview:SetPoint("TOPLEFT", 456, -34)
    page.look = UI.Button(page, "Aperçu", 190, 22, function()
        if page.selected then Press.Preview(page.selected) end
    end)
    page.look:SetPoint("TOPLEFT", 456, -372)
    UI.Tooltip(page.look, "Aperçu", { "Ouvre la gazette (ou l'album, pour des cartes) sur cet élément, comme s'il était publié.",
        "Rien n'est diffusé." })
    function page:Refresh()
        self.list:Update()
        if self.selected and R.db.pressDone[self.selected.id] then self.selected = nil end
        self.preview:SetText(preview(self.selected))
        local k = self.selected and self.selected.kind
        self.look:SetDisabled(k ~= "ARTICLE" and k ~= "EDITION" and k ~= "CARD_SET")
    end
end

------------------------------------------------------------------------
-- Guilde rivale
------------------------------------------------------------------------
local function buildRival(f, page)
    local cur = UI.Section(page, "En vigueur dans la guilde", 340)
    cur:SetPoint("TOPLEFT", 0, 0)
    page.info = UI.Text(page, 12)
    page.info:SetPoint("TOPLEFT", 0, -28)
    page.info:SetWidth(BODY_W)

    local prop = UI.Section(page, "Proposé par l'application", 340)
    prop:SetPoint("TOPLEFT", 0, -104)
    local hint = UI.Text(page, 10, UI.C.dim)
    hint:SetPoint("TOPLEFT", 0, -130)
    hint:SetWidth(BODY_W)
    hint:SetText("L'application relit l'armurerie à son lancement puis toutes les heures, et ne propose l'effectif que s'il a changé. "
        .. "Publier = la guilde rivale et son effectif valent pour tous les membres.")
    page.list = itemList(page, BODY_W, 106, Press.IsGuildItem,
        "Rien en attente.", function() f:Refresh() end)
    page.list:SetPoint("TOPLEFT", 0, -150)

    page.auto = UI.Checkbox(page, "Publier l'effectif tout seul à la connexion (la guilde rivale garde son clic)",
        function(v) R.db.adminAutoRoster = v; if v then Press.AutoRoster() end; f:Refresh() end)
    page.auto:SetPoint("TOPLEFT", -4, -262)

    local man = UI.Section(page, "Saisie manuelle (sans l'application)", 340)
    man:SetPoint("TOPLEFT", 0, -292)
    page.rival = UI.EditBox(page, 260, 24, false, 48)
    page.rival:SetPoint("TOPLEFT", 0, -324)
    page.publish = UI.Button(page, "Diffuser", 100, 22, function()
        local _, why = GC.Publish({ rival = page.rival:GetText() or false })
        notify(why)
        f:Refresh()
    end)
    page.publish:SetPoint("LEFT", page.rival, "RIGHT", 8, 0)
    UI.Tooltip(page.publish, "Diffuser à la guilde", { "Nom exact de la guilde. Vide = aucune guilde rivale.",
        "Sans effectif : pour le relever, passe par l'application.", A.RankHelp() })

    function page:Refresh()
        local rival, cfg, roster = GC.Rival(), GC.Current(), GC.Roster()
        local lines = { rival and ("Guilde rivale : |cffd4a017<" .. rival .. ">|r") or "Guilde rivale : aucune" }
        if cfg then
            table.insert(lines, ("Diffusée par %s, %s."):format(tostring(cfg.n), UI.Ago(cfg.t)))
        elseif rival then
            table.insert(lines, "(réglage local de ce personnage, pas encore diffusé)")
        end
        if roster then
            table.insert(lines, ("Effectif de l'armurerie : %d membre(s), relevé %s."):format(
                roster.p.count or #roster.p.members, UI.Ago(roster.p.at or roster.t)))
        elseif rival then
            table.insert(lines, "Effectif de l'armurerie : pas encore publié.")
        end
        self.info:SetText(table.concat(lines, "\n"))
        if not self.rival.edit:HasFocus() then self.rival:SetText(rival or "") end
        self.publish:SetDisabled(not A.IsOfficer())
        self.auto:SetChecked(R.db.adminAutoRoster ~= false)
        self.list:Update()
    end
end

------------------------------------------------------------------------
-- Diagnostic
------------------------------------------------------------------------
local function buildDiag(f, page)
    local sync = UI.Section(page, "Synchronisation", 330)
    sync:SetPoint("TOPLEFT", 0, 0)
    page.syncInfo = UI.Text(page, 11)
    page.syncInfo:SetPoint("TOPLEFT", 0, -28)
    page.syncInfo:SetWidth(340)
    page.syncNow = UI.Button(page, "Synchroniser maintenant", 190, 22, function()
        if R.Sync then R.Sync.SendVector(true) end
        f:Refresh()
    end)
    page.syncNow:SetPoint("TOPLEFT", 0, -110)

    local data = UI.Section(page, "Données", 330)
    data:SetPoint("TOPLEFT", 370, 0)
    page.dataInfo = UI.Text(page, 11)
    page.dataInfo:SetPoint("TOPLEFT", 370, -28)
    page.dataInfo:SetWidth(340)
    page.unsupported = UI.Text(page, 10, UI.C.dim)
    page.unsupported:SetPoint("TOPLEFT", 370, -64)
    page.unsupported:SetWidth(340)

    local gs = UI.Section(page, "Réglages de guilde", 330)
    gs:SetPoint("TOPLEFT", 0, -150)
    page.guildInfo = UI.Text(page, 11)
    page.guildInfo:SetPoint("TOPLEFT", 0, -178)
    page.guildInfo:SetWidth(BODY_W)

    local tools = UI.Section(page, "Outils", 330)
    tools:SetPoint("TOPLEFT", 0, -300)
    page.demo = UI.Checkbox(page, "Mode démo dans ma fenêtre Renatus (données fictives, rien n'est sauvegardé)",
        function(v) R.char.ui.demo = v; R.UI.Refresh() end)
    page.demo:SetPoint("TOPLEFT", 0, -330)

    function page:Refresh()
        if R.Sync then
            local st = R.Sync.Status()
            local lines = {}
            table.insert(lines, st.canSend and "|cff8fd88fActive|r" or ("|cffcc9933En pause|r (" .. tostring(st.reason) .. ")"))
            table.insert(lines, ("Membres équipés vus : %d  ·  messages en attente : %d"):format(st.peers, st.queue))
            table.insert(lines, ("Événements partagés connus : %d (%d auteurs)"):format(st.shared, st.authors))
            local last = st.stats.lastReceived and UI.Ago(st.stats.lastReceived) or "jamais"
            table.insert(lines, ("Reçus : %d  ·  dernier message : %s"):format(st.received, last))
            if st.rejected > 0 then table.insert(lines, ("|cffcc6633%d événement(s) rejeté(s) (invalides)|r"):format(st.rejected)) end
            self.syncInfo:SetText(table.concat(lines, "\n"))
        end
        self.dataInfo:SetText(("%d événement(s) enregistré(s) sur ce compte.\nSchéma de données v%d."):format(
            R.Store.Count(), R.Settings.SCHEMA))
        local list = {}
        for ev in pairs(R.unsupportedEvents) do table.insert(list, ev) end
        table.sort(list)
        self.unsupported:SetText(#list > 0 and ("Événements indisponibles sur ce client : " .. table.concat(list, ", ")) or "")
        self.demo:SetChecked(R.char.ui.demo)
        self.guildInfo:SetText(table.concat(GC.Diagnose(), "\n"))
    end
end

------------------------------------------------------------------------
-- Remise à zéro: remove some of one's own events, for the whole guild
------------------------------------------------------------------------
local function buildReset(f, page)
    local sec = UI.Section(page, "Repartir de zéro", 340)
    sec:SetPoint("TOPLEFT", 0, 0)
    local hint = UI.Text(page, 11, UI.C.dim)
    hint:SetPoint("TOPLEFT", 0, -30)
    hint:SetWidth(BODY_W)
    hint:SetText("Retire tes propres événements cochés, pour toute la guilde (la synchro prévient chacun, même hors ligne). "
        .. "Les autres membres ne sont pas touchés. Tes jours de jeu restent : tes boosters reviennent.")
    page.checks = {}
    for i, g in ipairs(A.RESET_GROUPS) do
        local cb = UI.Checkbox(page, g.label, function() page.confirm = nil; page:Refresh() end)
        cb:SetPoint("TOPLEFT", -4, -64 - (i - 1) * 28)
        cb:SetChecked(g.default and true or false)
        page.checks[g.key] = cb
    end
    local y = -64 - #A.RESET_GROUPS * 28 - 12
    page.go = UI.Button(page, "Retirer", 150, 24, function()
        local selected, any = {}, false
        for key, cb in pairs(page.checks) do
            if cb:GetChecked() then selected[key] = true; any = true end
        end
        if not any then return end
        if not page.confirm then
            page.confirm = true
            page:Refresh()
            return
        end
        page.confirm = nil
        local n = A.Reset(selected)
        page.result = ("%d événement(s) retiré(s). Fais /reload ; pour une nouvelle gazette, rédige-la dans l'application."):format(n)
        page:Refresh()
        f:Refresh()
    end)
    page.go:SetPoint("TOPLEFT", 0, y)
    page.info = UI.Text(page, 11)
    page.info:SetPoint("TOPLEFT", 0, y - 34)
    page.info:SetWidth(BODY_W)

    -- Wanted Board: a start date for the whole guild (guild setting); nothing is deleted.
    local hy = y - 72
    local hunt = UI.Section(page, "Tableau de chasse", 340)
    hunt:SetPoint("TOPLEFT", 0, hy)
    page.huntInfo = UI.Text(page, 11, UI.C.dim)
    page.huntInfo:SetPoint("TOPLEFT", 0, hy - 28)
    page.huntInfo:SetWidth(BODY_W)
    page.huntReset = UI.Button(page, "Repartir de 0-0", 150, 24, function()
        if not page.huntConfirm then page.huntConfirm = true; page:Refresh() return end
        page.huntConfirm = nil
        local _, why = GC.Publish({ huntSince = (GetServerTime and GetServerTime()) or time() })
        notify(why)
        f:Refresh()
    end)
    page.huntReset:SetPoint("TOPLEFT", 0, hy - 64)
    page.huntUndo = UI.Button(page, "Tout reprendre depuis le début", 220, 24, function()
        page.huntConfirm = nil
        local _, why = GC.Publish({ huntSince = false })
        notify(why)
        f:Refresh()
    end)
    page.huntUndo:SetPoint("LEFT", page.huntReset, "RIGHT", 8, 0)

    function page:Refresh()
        local since = GC.HuntSince()
        if self.huntConfirm then
            self.huntInfo:SetText("|cffff6644Remettre le tableau de chasse à 0-0 pour toute la guilde ? Reclique pour confirmer.|r")
        else
            self.huntInfo:SetText((since and ("Compté depuis le " .. R.Views.DateLabel(since) .. date(" à %H:%M", since) .. ". ")
                or "Compté depuis le début. ")
                .. "Repartir de 0-0 ignore les combats d'avant (score, registre, nouvelles, ennemis jurés) "
                .. "sans rien effacer : les morts restent dans les journaux, les avis restent placardés.")
        end
        self.huntReset:SetLabel(self.huntConfirm and "Confirmer ?" or "Repartir de 0-0")
        self.huntReset:SetDisabled(not A.IsOfficer())
        self.huntUndo:SetDisabled(not A.IsOfficer() or not since)

        local any = false
        for _, cb in pairs(self.checks) do if cb:GetChecked() then any = true end end
        self.go:SetDisabled(not any or not A.IsOfficer())
        self.go:SetLabel(self.confirm and "Confirmer ?" or "Retirer")
        if self.confirm then
            self.info:SetText("|cffff6644Retirer pour toute la guilde ce qui est coché ? Reclique pour confirmer. "
                .. "C'est définitif.|r")
        else
            self.info:SetText(self.result or (A.IsOfficer() and "" or A.RankHelp()))
        end
    end
end

------------------------------------------------------------------------
-- Boosters
------------------------------------------------------------------------
-- Form: "per day played" and the overall daily maximum, then for each source
-- (R.Album.SOURCES) "Q boosters every N" and its own daily maximum. 0 always means 0.
local function buildBoosters(f, page)
    local sec = UI.Section(page, "Règle des boosters", 340)
    sec:SetPoint("TOPLEFT", 0, 0)
    page.info = UI.Text(page, 11)
    page.info:SetPoint("TOPLEFT", 0, -26)
    page.info:SetWidth(BODY_W)
    local hint = UI.Text(page, 10, UI.C.dim)
    hint:SetPoint("TOPLEFT", 0, -44)
    hint:SetWidth(BODY_W)
    hint:SetText("Vaut pour tous les membres à partir du jour où elle est diffusée ; les jours passés gardent la règle d'alors. "
        .. "« Boosters » / « Tous les N » : tant de boosters toutes les N fois. 0 = rien (source coupée). Pas de limite haute.")

    page.fields, page.src = {}, {}
    local function box(key, x, y, w)
        local b = UI.EditBox(page, w or 64, 22, false, 10)
        b:SetPoint("TOPLEFT", x, y)
        return b
    end
    local function label(text, x, y, size, color)
        local t = UI.Text(page, size or 12, color)
        t:SetPoint("TOPLEFT", x, y)
        t:SetText(text)
        return t
    end
    label("Par jour joué", 0, -82)
    page.fields.day = box("day", 160, -78)
    label("Maximum par jour (en tout)", 300, -82)
    page.fields.cap = box("cap", 490, -78)

    -- Sources in two columns: label, boosters, every N, daily maximum.
    local COL_W, ROW_H, TOP, BOX_W = 358, 26, -140, 50
    local QTY_X, N_X, CAP_X = 160, 220, 280
    local perCol = math.ceil(#R.Album.SOURCES / 2)
    for c = 0, 1 do
        label("Source", c * COL_W, TOP + 22, 10, UI.C.dim)
        label("Boosters", c * COL_W + QTY_X + 2, TOP + 22, 10, UI.C.dim)
        label("Tous les", c * COL_W + N_X + 2, TOP + 22, 10, UI.C.dim)
        label("Max/jour", c * COL_W + CAP_X + 2, TOP + 22, 10, UI.C.dim)
    end
    for i, s in ipairs(R.Album.SOURCES) do
        local c, r = math.floor((i - 1) / perCol), (i - 1) % perCol
        local x, y = c * COL_W, TOP - r * ROW_H
        local name = label(s.label, x, y - 4)
        name:SetWidth(QTY_X - 6)
        name:SetWordWrap(false)
        page.src[s.key] = {
            qty = box(s.key .. ".qty", x + QTY_X, y, BOX_W),
            n = box(s.key .. ".n", x + N_X, y, BOX_W),
            cap = box(s.key .. ".cap", x + CAP_X, y, BOX_W),
        }
    end

    local function each(fn)
        for _, b in pairs(page.fields) do fn(b) end
        for _, s in pairs(page.src) do fn(s.qty); fn(s.n); fn(s.cap) end
    end
    -- shiny cards: 1 card in N comes out shiny (0 = none), on the publish row
    local bottom = TOP - perCol * ROW_H - 14
    label("Brillantes : 1 carte sur", 300, bottom - 4)
    page.fields.shiny = box("shiny", 490, bottom)
    label("(toutes raretés, 0 = aucune)", 562, bottom - 5, 10, UI.C.dim)

    page.publish = UI.Button(page, "Diffuser", 100, 22, function()
        local rule = { day = page.fields.day:GetText(), cap = page.fields.cap:GetText(), shiny = page.fields.shiny:GetText(), src = {} }
        for key, s in pairs(page.src) do rule.src[key] = { qty = s.qty:GetText(), n = s.n:GetText(), cap = s.cap:GetText() } end
        local _, why = GC.Publish({ boosters = rule })
        notify(why)
        each(function(b) b.edit:ClearFocus() end)
        f:Refresh()
    end)
    page.publish:SetPoint("TOPLEFT", 0, bottom)
    UI.Tooltip(page.publish, "Diffuser à la guilde", { "Case vide ou invalide = 0.", A.RankHelp() })

    function page:Refresh()
        local rule, ev = GC.Boosters()
        if ev then
            self.info:SetText(("|cffd4a017En vigueur : diffusée par %s, %s.|r"):format(tostring(ev.n), UI.Ago(ev.t)))
        else
            self.info:SetText("|cffd4a017En vigueur : règle par défaut (aucune règle diffusée).|r")
        end
        local full = R.Album.Expand(rule)
        local function set(b, v) if not b.edit:HasFocus() then b:SetText(tostring(v)) end end
        set(self.fields.day, full.day); set(self.fields.cap, full.cap); set(self.fields.shiny, full.shiny)
        for key, s in pairs(self.src) do set(s.qty, full.src[key].qty); set(s.n, full.src[key].n); set(s.cap, full.src[key].cap) end
        self.publish:SetDisabled(not A.IsOfficer())
    end
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
local PAGES = {
    { key = "press", label = "Rédaction", build = buildPress },
    { key = "rival", label = "Guilde rivale", build = buildRival },
    { key = "boosters", label = "Boosters", build = buildBoosters },
    { key = "diag", label = "Diagnostic", build = buildDiag },
    { key = "reset", label = "Remise à zéro", build = buildReset },
}

local function build()
    local f = CreateFrame("Frame", "RenatusAdminFrame", UIParent)
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    UI.Skin(f, "window")
    if UISpecialFrames then table.insert(UISpecialFrames, "RenatusAdminFrame") end

    local icon = UI.Icon(f, 32, A.ICON)
    icon:SetPoint("TOPLEFT", PAD, -PAD)
    local title = UI.Title(f, 22)
    title:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    title:SetText("Renatus : administration")
    f.status = UI.Text(f, 11)
    f.status:SetPoint("TOPLEFT", PAD, -62)
    f.status:SetWidth(BODY_W - 40)

    -- Same close plate as the members' window.
    local close = CreateFrame("Button", nil, f)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -PAD, -PAD)
    close:SetNormalTexture(UI.MEDIA .. "close")
    close:SetPushedTexture(UI.MEDIA .. "close")
    local closeHl = close:CreateTexture(nil, "HIGHLIGHT")
    closeHl:SetAllPoints()
    closeHl:SetColorTexture(1, 0.8, 0.4, 0.2)
    closeHl:SetBlendMode("ADD")
    close:SetScript("OnClick", function() f:Hide() end)
    f.close = close

    f.tabs, f.pages = {}, {}
    local prev
    for _, def in ipairs(PAGES) do
        local b = UI.ToggleButton(f, def.label, 130, 24, function() f:ShowPage(def.key) end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("TOPLEFT", PAD, -82) end
        prev = b
        f.tabs[def.key] = b
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", PAD, -BODY_TOP - 8)
        page:SetSize(BODY_W, H - BODY_TOP - PAD - 8)
        def.build(f, page)
        page:Hide()
        f.pages[def.key] = page
    end

    function f:ShowPage(key)
        self.page = key
        for k, page in pairs(self.pages) do page:SetShown(k == key) end
        for k, b in pairs(self.tabs) do b:SetSelected(k == key) end
        self:Refresh()
    end

    function f:Refresh()
        local _, _, rank = R.Try(GetGuildInfo, "player")
        if A.IsOfficer() then
            self.status:SetText(("|cff8fd88fOfficier (rang %d) : tu peux publier.|r"):format(rank))
        else
            self.status:SetText("|cffcc9933Consultation seulement.|r " .. A.RankHelp())
        end
        local nPress, nGuild = #Press.Pending(Press.IsGazetteItem), #Press.Pending(Press.IsGuildItem)
        self.tabs.press:SetLabel(nPress > 0 and ("Rédaction (" .. nPress .. ")") or "Rédaction")
        self.tabs.rival:SetLabel(nGuild > 0 and ("Guilde rivale (" .. nGuild .. ")") or "Guilde rivale")
        local page = self.pages[self.page]
        if page then page:Refresh() end
        if A.UpdateIcon then A.UpdateIcon() end
    end

    f:SetScript("OnShow", function(self) self:Refresh() end)
    f:Hide()
    return f
end

function A.GetWindow()
    if not window then
        window = build()
        A.window = window
        -- Start where there is something to do.
        local guild = #Press.Pending(Press.IsGuildItem) > 0 and #Press.Pending(Press.IsGazetteItem) == 0
        window:ShowPage(guild and "rival" or "press")
    end
    return window
end

function A.Open(page)
    local f = A.GetWindow()
    f:Show()
    if page then f:ShowPage(page) else f:Refresh() end
    return f
end

function A.Toggle()
    local f = A.GetWindow()
    if f:IsShown() then f:Hide() else A.Open() end
end

-- The roster (officer ranks) may arrive after the window opened.
R:RegisterGameEvent("GUILD_ROSTER_UPDATE", function()
    if window and window:IsShown() then window:Refresh() end
end)

-- /radmin brillantes: a shiny copy of 3 commons the officer already owns, to see the
-- shiny finish in game. Kept on this client only (ns.db.testCards): never shared, never
-- tradable, invisible to the others. "/radmin brillantes off" takes them back.
function A.TestShiny(off)
    local ds = R.Store.Dataset()
    if ds.isDemo then R.Print("pas en mode démo (la démo a déjà des brillantes).") return end
    R.db.testCards = R.db.testCards or {}
    if off then
        R.db.testCards[ds.me] = nil
        R.Print("cartes brillantes de test retirées.")
    else
        local picks = {}
        for _, card in ipairs(R.Album.Catalogue(ds)) do
            local normal, shiny = R.Album.Copies(ds.collection, card.id)
            if card.rarity == "common" and normal > 0 and shiny == 0 then picks[#picks + 1] = card end
        end
        table.sort(picks, function(a, b) return a.id < b.id end)
        if #picks == 0 then R.Print("aucune commune sans brillante dans ta collection.") return end
        local given, names = {}, {}
        for i = 1, math.min(3, #picks) do
            given[R.Album.ShinyId(picks[i].id)] = 1
            names[i] = picks[i].name
        end
        R.db.testCards[ds.me] = given
        R.Print("brillantes de test (sur ce client seulement) : %s. « /radmin brillantes off » pour les retirer.",
            table.concat(names, ", "))
    end
    R.UI.Open("album")
    local album = R.UI.GetWindow().containers.album
    if album and album.Refresh then album:Refresh() end
end

SLASH_RENATUSADMIN1 = "/radmin"
SlashCmdList.RENATUSADMIN = function(msg)
    local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "brillantes" then return A.TestShiny(rest == "off") end
    A.Toggle()
end
