-- UI/TabWanted.lua: PvP Wanted Board (wanted posters, enemy registry, records).
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
    f.name:SetText(ev.p.name or "?")
    local nick = ev.p.nickname or (e and e.nickname)
    f.nick:SetText(nick and ("dit « " .. nick .. " »") or (e and e.guild and ("<" .. e.guild .. ">") or ""))
    f.reason:SetText(ev.p.reason or "")
    f.reward:SetText(ev.p.reward and ("Prime : " .. ev.p.reward) or "")
    local record = e and ("V " .. Views.Total(e.wins) .. "  ·  D " .. Views.Total(e.losses) .. "  ·  ") or ""
    f.foot:SetText(record .. "affiché par " .. (ev.n or "?"))
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function build(c)
    c.view = "posters"
    c.page = 1

    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Tableau de chasse")
    c.rival = UI.Text(c, 11, UI.C.dim)
    c.rival:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)

    local function setView(v) c.view = v; c.detail = nil; c:Refresh() end
    c.tabPosters = UI.ToggleButton(c, "Avis de recherche", 140, 24, function() setView("posters") end)
    c.tabPosters:SetPoint("TOPLEFT", 4, -46)
    c.tabRegistry = UI.ToggleButton(c, "Registre des ennemis", 150, 24, function() setView("registry") end)
    c.tabRegistry:SetPoint("LEFT", c.tabPosters, "RIGHT", 6, 0)
    local addWanted = UI.Button(c, "+ Avis", 80, 24, function() UI.Dialogs.Wanted() end)
    addWanted:SetPoint("TOPRIGHT", -4, -46)
    local addClash = UI.Button(c, "+ Affrontement", 120, 24, function() UI.Dialogs.Clash() end)
    addClash:SetPoint("RIGHT", addWanted, "LEFT", -6, 0)
    local addEnemy = UI.Button(c, "+ Ennemi", 90, 24, function() UI.Dialogs.EnemyNote() end)
    addEnemy:SetPoint("RIGHT", addClash, "LEFT", -6, 0)

    local bodyTop, bodyH = -80, UI.CONTENT_H - 104

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
    posters.prev:SetPoint("LEFT", c.tabRegistry, "RIGHT", 16, 0)
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
        local sworn = e.sworn and "  |cffcc2a1aENNEMI JURÉ|r" or ""
        row.name:SetText(UI.ClassName(e.name, e.class) .. (e.nickname and ("  |cff999999« " .. e.nickname .. " »|r") or "") .. sworn)
        local bits = {}
        if e.guild then table.insert(bits, "<" .. e.guild .. ">") end
        if e.level then table.insert(bits, "niv. " .. e.level .. " (vu " .. UI.Ago(e.levelAt) .. ")") end
        if e.lastZone then table.insert(bits, "dernière rencontre : " .. e.lastZone) end
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
    local note = UI.Button(d, "+ Note / surnom", 130, 22, function() UI.Dialogs.EnemyNote(c.detail) end)
    note:SetPoint("BOTTOMLEFT", 14, 10)
    local clash = UI.Button(d, "Déclarer un affrontement", 180, 22, function() UI.Dialogs.Clash(c.detail) end)
    clash:SetPoint("LEFT", note, "RIGHT", 8, 0)
    local wanted = UI.Button(d, "Placarder un avis", 140, 22, function() UI.Dialogs.Wanted(c.detail) end)
    wanted:SetPoint("LEFT", clash, "RIGHT", 8, 0)

    c.ethics = UI.Text(c, 10, UI.C.dim)
    c.ethics:SetPoint("BOTTOMLEFT", 4, 0)
    c.ethics:SetText("Uniquement des informations visibles en jeu sur des personnages. Partagé avec la guilde seulement.")

    function c:ShowDetail(e)
        UI.SetClassIcon(d.portrait, e.class)
        d.name:SetText(UI.ClassName(e.name, e.class))
        local ident = {}
        if e.guild then table.insert(ident, "<" .. e.guild .. ">") end
        if e.race or e.class then table.insert(ident, (e.race or "?") .. " " .. string.lower(e.class or "?")) end
        if e.level then table.insert(ident, "niveau " .. e.level .. " observé " .. UI.Ago(e.levelAt)) end
        d.ident:SetText(table.concat(ident, "  ·  "))
        d.sworn:SetText(e.sworn and ("ENNEMI JURÉ — " .. (e.swornReason or "")) or "")

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
            if ev.k == "DEATH" then text = (ev.n or "?") .. " meurt, " .. e.name .. " présent" end
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
        self.tabPosters:SetSelected(self.view == "posters")
        self.tabRegistry:SetSelected(self.view == "registry")

        local detailEnemy
        if self.detail then
            for _, e in ipairs(enemies) do if e.key == Views.EnemyKey(self.detail) then detailEnemy = e end end
        end
        posters:SetShown(self.view == "posters" and not detailEnemy)
        self.registry:SetShown(self.view == "registry" and not detailEnemy)
        d:SetShown(detailEnemy ~= nil)
        self.ethics:SetShown(not detailEnemy)
        if detailEnemy then self:ShowDetail(detailEnemy) return end

        if self.view == "registry" then
            self.registry:SetItems(enemies, "Aucun ennemi enregistré.\nLes joueurs de la guilde rivale croisés en jeu apparaîtront ici,\nou ajoute-les avec « + Ennemi ».")
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

UI.RegisterTab({ key = "wanted", label = "Tableau de chasse", icon = "Interface\\Icons\\Ability_DualWield", order = 40,
    build = build, refresh = function(c) c:Refresh() end })
