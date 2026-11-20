-- Window.lua: the admin window (/radmin, admin minimap icon), separate from the members'
-- window so that the Renatus addon looks the same for everyone.
--   Rédaction      gazette items from the Renatus Admin app: preview, publish, ignore
--   Guilde rivale  rival guild in force, app proposals (setting + armory roster), manual entry
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
    if item.kind == "ARTICLE" then
        table.insert(lines, "|cffd4a017" .. tostring(p.title) .. "|r")
        local meta = {}
        for _, v in ipairs({ p.format, p.style, p.ia == true and "rédigé par IA" or nil }) do
            if v then table.insert(meta, tostring(v)) end
        end
        if #meta > 0 then table.insert(lines, "|cff999999" .. table.concat(meta, " · ") .. "|r") end
        table.insert(lines, "")
        table.insert(lines, tostring(p.body or ""))
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
    page.preview = UI.ScrollText(page, BODY_W - 456, 360, 12)
    page.preview:SetPoint("TOPLEFT", 456, -34)
    function page:Refresh()
        self.list:Update()
        if self.selected and R.db.pressDone[self.selected.id] then self.selected = nil end
        self.preview:SetText(preview(self.selected))
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
    hint:SetText("Onglet Guilde rivale de l'application, « Actualiser depuis l'armurerie », puis /reload. "
        .. "Publier = la guilde rivale et son effectif valent pour tous les membres.")
    page.list = itemList(page, BODY_W, 120, Press.IsGuildItem,
        "Rien en attente.", function() f:Refresh() end)
    page.list:SetPoint("TOPLEFT", 0, -150)

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
        if not self.rival:HasFocus() then self.rival:SetText(rival or "") end
        self.publish:SetDisabled(not A.IsOfficer())
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

    local tools = UI.Section(page, "Outils", 330)
    tools:SetPoint("TOPLEFT", 0, -160)
    page.demo = UI.Checkbox(page, "Mode démo dans ma fenêtre Renatus (données fictives, rien n'est sauvegardé)",
        function(v) R.char.ui.demo = v; R.UI.Refresh() end)
    page.demo:SetPoint("TOPLEFT", 0, -190)

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
    end
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
local PAGES = {
    { key = "press", label = "Rédaction", build = buildPress },
    { key = "rival", label = "Guilde rivale", build = buildRival },
    { key = "diag", label = "Diagnostic", build = buildDiag },
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

SLASH_RENATUSADMIN1 = "/radmin"
SlashCmdList.RENATUSADMIN = function() A.Toggle() end
