-- UI/Timeline.lua: timeline shared by "Mon journal" and "Guilde".
local _, ns = ...
local UI = ns.UI
local Types, Views = ns.Types, ns.Views

local ROW_H = 48

local function categoryOptions()
    local opts = { { value = "all", label = "Toutes catégories" } }
    for _, c in ipairs(Types.CATEGORIES) do table.insert(opts, { value = c.key, label = c.label }) end
    return opts
end

local PERIODS = {
    { value = "all", label = "Depuis toujours" },
    { value = "today", label = "Aujourd'hui" },
    { value = "week", label = "7 derniers jours" },
    { value = "month", label = "30 derniers jours" },
}

local IMPORTANCE = {
    { value = 0, label = "Tout" },
    { value = 3, label = "Grandes étapes" },
}

local causes = {}   -- death causes (combat log) of the displayed dataset

local function hasMissing(ev, what)
    for _, m in ipairs(ev.miss or {}) do if m == what then return true end end
    return false
end

local function participantsText(ev)
    if not ev.pt or #ev.pt == 0 then return nil end
    local names = {}
    for _, p in ipairs(ev.pt) do table.insert(names, p.n) end
    return table.concat(names, ", ")
end

local function rowTooltip(row)
    local item = row.item
    if not item then return nil end
    local ev = item.ev
    local lines = {}
    table.insert(lines, UI.Date(ev.t, true))
    local zone = Types.Zone(ev)
    if zone then
        local where = zone
        if ev.loc and ev.loc.sz then where = where .. " — " .. ev.loc.sz end
        if ev.loc and ev.loc.xy then where = where .. string.format(" (%.1f, %.1f)", ev.loc.xy[1] / 10, ev.loc.xy[2] / 10) end
        table.insert(lines, where)
    end
    if ev.p and ev.p.desc then table.insert(lines, { ev.p.desc, 1, 1, 1 }) end
    local prov = Types.PROVENANCE[ev.prov] or Types.PROVENANCE.OBS
    table.insert(lines, { "Provenance : " .. prov.label .. " — " .. prov.help, prov.color[1], prov.color[2], prov.color[3] })
    if #item.authors > 1 then
        table.insert(lines, { "Confirmé par : " .. table.concat(item.authors, ", "), 0.55, 0.85, 0.55 })
    end
    local pt = participantsText(ev)
    if pt then table.insert(lines, { "Présents selon " .. Types.Who(ev) .. " : " .. pt, 0.8, 0.8, 0.8 }) end
    if ev.k == "EXPEDITION" and ev.p then
        if ev.p.bossNames then table.insert(lines, { "Boss : " .. table.concat(ev.p.bossNames, ", "), 1, 0.82, 0 }) end
        if ev.p.others then table.insert(lines, { ev.p.others .. " joueur(s) hors guilde dans le groupe", 0.8, 0.8, 0.8 }) end
        if ev.p.finish then table.insert(lines, { "Fin : " .. UI.Date(ev.p.finish, true), 0.8, 0.8, 0.8 }) end
    end
    local cause = causes[ev.id]
    if cause then
        table.insert(lines, { "Cause : " .. tostring(cause.p.cause) .. " (d'après le journal de combat de " .. tostring(cause.n) .. ")",
            Types.PROVENANCE.LOG.color[1], Types.PROVENANCE.LOG.color[2], Types.PROVENANCE.LOG.color[3] })
    elseif hasMissing(ev, "killer") then
        table.insert(lines, { "Cause de la mort inconnue : le journal de combat n'est pas accessible aux addons.", 0.6, 0.6, 0.6 })
    end
    for _, field in ipairs(ev.ded or {}) do
        if Types.DEDUCED[field] then table.insert(lines, { "Supposé — " .. Types.DEDUCED[field], 0.75, 0.75, 0.75 }) end
    end
    if ev.rx then
        table.insert(lines, { ev.rx.direct and ("Reçu directement de " .. tostring(ev.rx.by))
            or ("Relayé par " .. tostring(ev.rx.by) .. " (copie de l'original de " .. Types.Who(ev) .. ")"), 0.6, 0.6, 0.6 })
    end
    if ev.vis == "P" then table.insert(lines, { "Privé : visible uniquement par toi.", 0.6, 0.6, 0.6 }) end
    if ns.Store.CanDelete(ev) then table.insert(lines, { "Clic droit : supprimer", 1, 0.82, 0 }) end
    return Types.Describe(ev, true), lines
end

local function createRow(row)
    row.icon = UI.Icon(row, 34)
    row.icon:SetPoint("LEFT", 6, 0)
    row.line1 = UI.Text(row, 13)
    row.line1:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -1)
    row.line1:SetPoint("RIGHT", -110, 0)
    row.line1:SetWordWrap(false)
    row.line2 = UI.Text(row, 11, UI.C.dim)
    row.line2:SetPoint("TOPLEFT", row.line1, "BOTTOMLEFT", 0, -4)
    row.line2:SetPoint("RIGHT", -110, 0)
    row.line2:SetWordWrap(false)
    row.badge = UI.Text(row, 11)
    row.badge:SetPoint("TOPRIGHT", -8, -6)
    row.badge:SetJustifyH("RIGHT")
    row.date = UI.Text(row, 10, UI.C.dim)
    row.date:SetPoint("TOPRIGHT", row.badge, "BOTTOMRIGHT", 0, -4)
    row.date:SetJustifyH("RIGHT")
    local sep = row:CreateTexture(nil, "BACKGROUND")
    sep:SetColorTexture(0.4, 0.3, 0.16, 0.35)
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT")
    sep:SetPoint("BOTTOMRIGHT")
    UI.Tooltip(row, rowTooltip)
    -- Right click on one of your own hand-entered events: delete it.
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" and self.item then UI.Dialogs.Delete(self.item.ev) end
    end)
end

local function updateRow(row, item, mode)
    local ev = item.ev
    local def = Types.Get(ev.k)
    row.icon:SetTexture(def.icon)
    if mode == "guild" and #item.authors > 1 then
        row.line1:SetText(Types.Describe(ev, false) .. "  |cff8fd88f(" .. #item.authors .. " membres)|r")
    elseif mode == "guild" then
        row.line1:SetText(UI.ClassName(Types.Who(ev), ev.c) .. " " .. Types.Raw(ev))
    else
        row.line1:SetText(Types.Describe(ev, false))
    end
    local bits = {}
    local zone = Types.Zone(ev)
    if zone then table.insert(bits, zone) end
    if mode == "guild" and #item.authors > 1 then
        table.insert(bits, table.concat(item.authors, ", "))
    else
        local pt = participantsText(ev)
        if pt then table.insert(bits, "avec " .. pt) end
    end
    if ev.k == "ANECDOTE" and ev.p.cat then table.insert(bits, ev.p.cat) end
    if causes[ev.id] then table.insert(bits, "|cff73b3ff" .. tostring(causes[ev.id].p.cause) .. "|r")
    elseif hasMissing(ev, "killer") and not (ev.p and ev.p.cause) then table.insert(bits, "cause inconnue") end
    row.line2:SetText(table.concat(bits, "  ·  "))
    local prov = Types.PROVENANCE[ev.prov] or Types.PROVENANCE.OBS
    row.badge:SetText(prov.label .. (ev.vis == "P" and "  |cff999999(privé)|r" or ""))
    row.badge:SetTextColor(prov.color[1], prov.color[2], prov.color[3])
    row.date:SetText(UI.Ago(ev.t))
end

-- mode: "personal" or "guild"
function UI.BuildTimeline(c, mode)
    local state = { category = "all", period = "all", member = "all", importance = 0, search = "" }
    c.state = state

    c.title = UI.Title(c, 20)
    c.title:SetPoint("TOPLEFT", 4, -2)
    c.info = UI.Text(c, 11, UI.C.dim)
    c.info:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -3)

    local addButton = UI.Button(c, "+ Anecdote", 110, 24, function() UI.Dialogs.Anecdote() end)
    addButton:SetPoint("TOPRIGHT", -4, -4)

    local y = -50
    local refresh = function() if c.Refresh then c:Refresh() end end
    local cat = UI.Dropdown(c, 150, categoryOptions, function(v) state.category = v; refresh() end)
    cat:SetPoint("TOPLEFT", 4, y)
    cat:SetValue("all")
    local period = UI.Dropdown(c, 140, PERIODS, function(v) state.period = v; refresh() end)
    period:SetPoint("LEFT", cat, "RIGHT", 8, 0)
    period:SetValue("all")
    local last = period
    if mode == "guild" then
        local member = UI.Dropdown(c, 130, function()
            local opts = { { value = "all", label = "Tous les membres" } }
            for _, m in ipairs(Views.Members(ns.Store.Dataset())) do
                if m.hasAddon then table.insert(opts, { value = m.name, label = m.display }) end
            end
            return opts
        end, function(v) state.member = v; refresh() end)
        member:SetPoint("LEFT", period, "RIGHT", 8, 0)
        member:SetValue("all")
        local imp = UI.Dropdown(c, 120, IMPORTANCE, function(v) state.importance = v; refresh() end)
        imp:SetPoint("LEFT", member, "RIGHT", 8, 0)
        imp:SetValue(0)
        c.memberDropdown = member
        last = imp
    end
    local search = UI.EditBox(c, mode == "guild" and 110 or 200, 22)
    search:SetPoint("LEFT", last, "RIGHT", 8, 0)
    search.hint = UI.Text(search, 11, UI.C.dim)
    search.hint:SetPoint("LEFT", 6, 0)
    search.hint:SetJustifyV("MIDDLE")
    search.hint:SetText("Rechercher…")
    search.edit:SetScript("OnTextChanged", function(self)
        state.search = self:GetText() or ""
        search.hint:SetShown(state.search == "")
        refresh()
    end)

    c.list = UI.List(c, UI.CONTENT_W, UI.CONTENT_H - 84, ROW_H, createRow, function(row, item) updateRow(row, item, mode) end)
    c.list:SetPoint("TOPLEFT", 0, -82)

    function c:Refresh()
        local ds = ns.Store.Dataset()
        causes = ds.causes or {}
        local f = {
            category = state.category ~= "all" and state.category or nil,
            since = Views.PeriodStart(state.period),
            search = state.search,
        }
        local emptyText
        if mode == "personal" then
            f.author = ds.me
            local _, name = ns.Context.Me()
            self.title:SetText("Mon journal")
            self.info:SetText("Les aventures de " .. tostring(name) .. ", consignées au fil de l'eau.")
            emptyText = "Ton journal est encore vierge.\nIl se remplira tout seul : niveaux, boss, découvertes, morts…\nTu peux aussi ajouter une anecdote."
        else
            f.guild = ds.guildKey
            f.authorName = state.member ~= "all" and state.member or nil
            f.minImportance = state.importance > 0 and state.importance or nil
            self.title:SetText("Histoire de la guilde")
            local shared = ns.char.privacy
            local anyShared = false
            for _, v in pairs(shared) do if v == "G" then anyShared = true end end
            self.info:SetText((ds.isDemo or anyShared) and "Événements partagés par les membres équipés de l'addon."
                or "Tu ne partages encore rien : règle des catégories sur « Guilde » dans Options > AddOns > Renatus.")
            emptyText = ds.guildKey and "Aucun événement pour ces filtres." or "Tu n'es dans aucune guilde."
        end
        local events = Views.Filter(ds.events, f)
        local items
        if mode == "guild" then
            items = Views.Aggregate(events)
        else
            items = {}
            for i, ev in ipairs(events) do items[i] = { ev = ev, events = { ev }, authors = { Types.Who(ev) } } end
        end
        self.list:SetItems(items, emptyText)
    end
end

UI.RegisterTab({ key = "journal", label = "Mon journal", icon = "Interface\\Icons\\INV_Misc_Book_09", order = 10,
    build = function(c) UI.BuildTimeline(c, "personal") end,
    refresh = function(c) c:Refresh() end })

UI.RegisterTab({ key = "guild", label = "Guilde", icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01", order = 20,
    build = function(c) UI.BuildTimeline(c, "guild") end,
    refresh = function(c) c:Refresh() end })
