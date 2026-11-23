-- UI/TabMembers.lua: member profiles, statistics, unofficial titles, shared adventures.
local _, ns = ...
local UI = ns.UI
local Views, Types = ns.Views, ns.Types

local LIST_W = 220
local STATS = {
    { key = "levels", label = "Niveaux", icon = "Interface\\Icons\\Spell_Holy_SurgeOfLight" },
    { key = "bosses", label = "Boss", icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
    { key = "expeditions", label = "Expéditions", icon = "Interface\\Icons\\INV_Misc_Map02" },
    { key = "zones", label = "Zones", icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { key = "quests", label = "Quêtes", icon = "Interface\\Icons\\INV_Misc_Note_01" },
    { key = "deaths", label = "Morts", icon = "Interface\\Icons\\Ability_Rogue_FeignDeath" },
    { key = "pvp", label = "PvP", icon = "Interface\\Icons\\Ability_DualWield" },
    { key = "anecdotes", label = "Anecdotes", icon = "Interface\\Icons\\INV_Scroll_03" },
}

local function build(c)
    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Membres")

    c.list = UI.List(c, LIST_W, UI.CONTENT_H - 40, 34, function(row)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 4, 0)
        row.name = UI.Text(row, 13)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 0)
        row.sub = UI.Text(row, 10, UI.C.dim)
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(0.55, 0.38, 0.12, 0.45)
        row:SetScript("OnClick", function(self) c.selected = self.item.name; c:Refresh() end)
    end, function(row, m)
        UI.SetClassIcon(row.icon, m.class)
        row.name:SetText(UI.ClassName(m.display, m.class))
        local sub = m.level and ("Niveau " .. m.level) or "Niveau ?"
        if not m.hasAddon then sub = sub .. " · sans l'addon"
        elseif m.titles[1] then sub = sub .. " · " .. m.titles[1].title end
        row.sub:SetText(sub)
        row.sel:SetShown(c.selected == m.name)
        row:SetAlpha(m.hasAddon and 1 or 0.55)
    end)
    c.list:SetPoint("TOPLEFT", 0, -36)

    -- Profile
    local p = CreateFrame("Frame", nil, c)
    p:SetPoint("TOPLEFT", LIST_W + 12, -36)
    p:SetSize(UI.CONTENT_W - LIST_W - 12, UI.CONTENT_H - 40)
    UI.Skin(p, "panel")
    c.profile = p
    p.portrait = p:CreateTexture(nil, "ARTWORK")
    p.portrait:SetSize(56, 56)
    p.portrait:SetPoint("TOPLEFT", 14, -14)
    p.name = UI.Title(p, 22)
    p.name:SetPoint("TOPLEFT", p.portrait, "TOPRIGHT", 12, -2)
    p.sub = UI.Text(p, 12, UI.C.dim)
    p.sub:SetPoint("TOPLEFT", p.name, "BOTTOMLEFT", 0, -4)
    p.titles = UI.Text(p, 12, UI.C.gold)
    p.titles:SetPoint("TOPLEFT", p.sub, "BOTTOMLEFT", 0, -4)
    p.titles:SetWidth(380)

    -- Their album cards: see them, and ask for some in a trade (UI/Trade.lua).
    p.collection = UI.Button(p, "Voir sa collection", 150, 22, function()
        if c.guid then UI.ShowCollection(c.guid) end
    end)
    p.collection:SetPoint("TOPRIGHT", -38, -8)

    p.stats = {}
    for i, s in ipairs(STATS) do
        local cell = CreateFrame("Frame", nil, p)
        cell:SetSize(104, 40)
        local col, line = (i - 1) % 4, math.floor((i - 1) / 4)
        cell:SetPoint("TOPLEFT", 14 + col * 110, -96 - line * 46)
        UI.Box(cell, { 0.08, 0.06, 0.045, 0.9 }, { 0.4, 0.3, 0.16, 1 })
        local icon = UI.Icon(cell, 26, s.icon)
        icon:SetPoint("LEFT", 6, 0)
        cell.value = UI.Title(cell, 17, { 1, 1, 1 })
        cell.value:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 2)
        cell.label = UI.Text(cell, 10, UI.C.dim)
        cell.label:SetPoint("TOPLEFT", cell.value, "BOTTOMLEFT", 0, -1)
        cell.label:SetText(s.label)
        p.stats[s.key] = cell
    end

    p.sharedTitle = UI.Section(p, "Aventures partagées avec toi", 420)
    p.sharedTitle:SetPoint("TOPLEFT", 14, -200)
    p.shared = UI.Text(p, 12)
    p.shared:SetPoint("TOPLEFT", p.sharedTitle, "BOTTOMLEFT", 0, -8)
    p.shared:SetWidth(420)

    p.recentTitle = UI.Section(p, "Derniers faits marquants", 420)
    p.recentTitle:SetPoint("TOPLEFT", 14, -262)
    p.recent = {}
    for i = 1, 6 do
        local fs = UI.Text(p, 12)
        fs:SetPoint("TOPLEFT", p.recentTitle, "BOTTOMLEFT", 0, -8 - (i - 1) * 20)
        fs:SetWidth(430)
        fs:SetWordWrap(false)
        p.recent[i] = fs
    end

    function c:Refresh()
        local ds = ns.Store.Dataset()
        local members = Views.Members(ds)
        if not self.selected and members[1] then self.selected = members[1].name end
        self.list:SetItems(members, "Aucun membre connu pour l'instant.")
        local m
        for _, x in ipairs(members) do if x.name == self.selected then m = x end end
        if not m then p:Hide() return end
        p:Show()
        self.guid = m.guid
        p.collection:SetShown(m.hasAddon and m.guid ~= nil and m.guid ~= ds.me and not ds.isDemo)
        UI.SetClassIcon(p.portrait, m.class)
        p.name:SetText(UI.ClassName(m.display, m.class))
        local sub = (m.level and ("Niveau " .. m.level) or "Niveau inconnu")
        if m.last then sub = sub .. " · dernier fait " .. UI.Ago(m.last) end
        if not m.hasAddon then sub = sub .. " · n'utilise pas l'addon" end
        p.sub:SetText(sub)
        local titles = {}
        for _, t in ipairs(m.titles) do table.insert(titles, "« " .. t.title .. " »") end
        p.titles:SetText(#titles > 0 and table.concat(titles, "   ") or "|cff999999Aucun titre officieux… pour l'instant.|r")
        for key, cell in pairs(p.stats) do cell.value:SetText(m.stats[key] or 0) end

        local shared = Views.Shared(ds, ds.me, m.guid)
        if m.guid == ds.me then
            p.shared:SetText("|cff999999C'est toi.|r")
        elseif shared then
            p.shared:SetText(("%d expédition(s) et %d boss vaincus ensemble."):format(shared.expeditions, shared.bosses))
        else
            p.shared:SetText("|cff999999Aucune donnée.|r")
        end
        -- Only one's own facts: the others' reach everyone through the gazette (no spoilers).
        local shown = 0
        if m.guid == ds.me or ds.isDemo then
            for _, ev in ipairs(m.events) do
                if Types.Get(ev.k).importance >= 2 and shown < #p.recent then
                    shown = shown + 1
                    p.recent[shown]:SetText("|cff999999" .. UI.Date(ev.t) .. "|r  " .. Types.Describe(ev, false))
                end
            end
        end
        local none = (m.guid == ds.me or ds.isDemo) and "|cff999999Rien de notable.|r"
            or "|cff999999Ses exploits se lisent dans la gazette.|r"
        for i = shown + 1, #p.recent do p.recent[i]:SetText(i == 1 and none or "") end
    end
end

-- Title tooltip: the rules are public and reproducible.
local function titlesHelp()
    local lines = {}
    for _, t in ipairs(Views.TITLES) do table.insert(lines, "« " .. t.title .. " » : " .. t.rule) end
    return lines
end
UI.TitlesHelp = titlesHelp

UI.RegisterTab({ key = "members", label = "Membres", icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing", order = 30,
    build = function(c)
        build(c)
        local help = UI.Button(c.profile, "?", 22, 22)
        help:SetPoint("TOPRIGHT", -8, -8)
        UI.Tooltip(help, "Titres officieux", titlesHelp())
    end,
    refresh = function(c) c:Refresh() end })
