-- UI/Timeline.lua: "Mon journal", the player's own events. The other members' events are
-- synced but not listed anywhere: they reach everyone through the gazette (no spoilers).
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

local causes = {}   -- death causes (combat log) of the displayed dataset
local cited = {}    -- [event id] = gazette issue whose articles cite it (Views.Editions)

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
    local issue = cited[ev.id]
    if issue then
        table.insert(lines, { "Paru dans la gazette n° " .. issue.number .. " (" .. string.lower(issue.label) .. ")", 0.83, 0.63, 0.09 })
    end
    if ev.vis == "P" then table.insert(lines, { "Privé : visible uniquement par toi.", 0.6, 0.6, 0.6 }) end
    local hint = {}
    if ns.Store.CanShare(ev) then hint[#hint + 1] = "partager avec la guilde" end
    if ns.Store.CanMakePrivate(ev) then hint[#hint + 1] = "rendre privé" end
    if ns.Store.CanDelete(ev) then hint[#hint + 1] = "supprimer" end
    if #hint > 0 then table.insert(lines, { "Clic droit : " .. table.concat(hint, ", "), 1, 0.82, 0 }) end
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
    -- Right click on one of your own events: share / make private, delete.
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" and self.item then UI.Dialogs.EventActions(self.item.ev) end
    end)
end

local function updateRow(row, item)
    local ev = item.ev
    local def = Types.Get(ev.k)
    row.icon:SetTexture(def.icon)
    row.line1:SetText(Types.Describe(ev, false))
    local bits = {}
    local zone = Types.Zone(ev)
    if zone then table.insert(bits, zone) end
    local pt = participantsText(ev)
    if pt then table.insert(bits, "avec " .. pt) end
    if ev.k == "ANECDOTE" and ev.p.cat then table.insert(bits, ev.p.cat) end
    if causes[ev.id] then table.insert(bits, "|cff73b3ff" .. tostring(causes[ev.id].p.cause) .. "|r")
    elseif hasMissing(ev, "killer") and not (ev.p and ev.p.cause) then table.insert(bits, "cause inconnue") end
    if cited[ev.id] then table.insert(bits, "|cffd4a017Paru dans le n° " .. cited[ev.id].number .. "|r") end
    row.line2:SetText(table.concat(bits, "  ·  "))
    local prov = Types.PROVENANCE[ev.prov] or Types.PROVENANCE.OBS
    row.badge:SetText(prov.label .. (ev.vis == "P" and "  |cff999999(privé)|r" or ""))
    row.badge:SetTextColor(prov.color[1], prov.color[2], prov.color[3])
    row.date:SetText(UI.Ago(ev.t))
end

function UI.BuildTimeline(c)
    local state = { category = "all", period = "all", search = "" }
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
    local search = UI.EditBox(c, 200, 22)
    search:SetPoint("LEFT", period, "RIGHT", 8, 0)
    search.hint = UI.Text(search, 11, UI.C.dim)
    search.hint:SetPoint("LEFT", 6, 0)
    search.hint:SetJustifyV("MIDDLE")
    search.hint:SetText("Rechercher…")
    search.edit:SetScript("OnTextChanged", function(self)
        state.search = self:GetText() or ""
        search.hint:SetShown(state.search == "")
        refresh()
    end)

    c.list = UI.List(c, UI.CONTENT_W, UI.CONTENT_H - 84, ROW_H, createRow, updateRow)
    c.list:SetPoint("TOPLEFT", 0, -82)

    function c:Refresh()
        local ds = ns.Store.Dataset()
        causes = ds.causes or {}
        cited = select(2, Views.Editions(ds))
        local f = {
            category = state.category ~= "all" and state.category or nil,
            since = Views.PeriodStart(state.period),
            search = state.search,
        }
        f.author = ds.me
        local _, name = ns.Context.Me()
        self.title:SetText("Mon journal")
        self.info:SetText("Les aventures de " .. tostring(name) .. ", consignées au fil de l'eau.")
        local items = {}
        for i, ev in ipairs(Views.Filter(ds.events, f)) do items[i] = { ev = ev } end
        self.list:SetItems(items, "Ton journal est encore vierge.\nIl se remplira tout seul : niveaux, boss, découvertes, morts…\nTu peux aussi ajouter une anecdote.")
    end
end

UI.RegisterTab({ key = "journal", label = "Mon journal", icon = "Interface\\Icons\\INV_Misc_Book_09", order = 10,
    build = function(c) UI.BuildTimeline(c) end,
    refresh = function(c) c:Refresh() end })
