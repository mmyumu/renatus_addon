-- UI/TabSettings.lua : confidentialite, guilde rivale, interface, donnees.
local _, ns = ...
local UI = ns.UI

local MODES = {
    { value = "OFF", label = "Désactivé" },
    { value = "P", label = "Privé" },
    { value = "G", label = "Guilde" },
}

local function build(c)
    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Paramètres")

    local priv = UI.Section(c, "Collecte et confidentialité", 320)
    priv:SetPoint("TOPLEFT", 4, -40)
    local help = UI.Text(c, 11, UI.C.dim)
    help:SetPoint("TOPLEFT", 4, -64)
    help:SetWidth(320)
    help:SetText("Désactivé : rien n'est enregistré. Privé : visible par toi seul. Guilde : partagé avec les membres équipés (dès que la synchronisation sera disponible).")
    c.privacy = {}
    for i, cat in ipairs(ns.Types.CATEGORIES) do
        local label = UI.Text(c, 12)
        label:SetPoint("TOPLEFT", 4, -118 - (i - 1) * 30)
        label:SetText(cat.label)
        local d = UI.Dropdown(c, 130, MODES, function(v) ns.char.privacy[cat.key] = v end)
        d:SetPoint("TOPLEFT", 160, -114 - (i - 1) * 30)
        c.privacy[cat.key] = d
    end
    c.export = UI.Checkbox(c, "Autoriser l'export hors jeu (gazette / LLM)", function(v) ns.char.exportConsent = v end)
    c.export:SetPoint("TOPLEFT", 4, -310)
    UI.Tooltip(c.export, "Export hors jeu", {
        "Consentement distinct du partage en guilde.",
        "Si coché, l'application compagnon du rédacteur pourra utiliser tes événements partagés pour écrire la gazette.",
    })
    local note = UI.Text(c, 10, UI.C.dim)
    note:SetPoint("TOPLEFT", 4, -340)
    note:SetWidth(320)
    note:SetText("Un événement déjà partagé peut avoir été copié par d'autres membres : le supprimer chez toi ne garantit pas sa disparition chez eux.")

    local pvp = UI.Section(c, "Tableau de chasse", 320)
    pvp:SetPoint("TOPLEFT", 360, -40)
    local rl = UI.Text(c, 12)
    rl:SetPoint("TOPLEFT", 360, -66)
    rl:SetText("Nom de la guilde rivale :")
    c.rival = UI.EditBox(c, 220, 24, false, 48)
    c.rival:SetPoint("TOPLEFT", 360, -86)
    c.rival.edit:SetScript("OnTextChanged", function(self) ns.char.rivalGuild = self:GetText() or "" end)

    local ui = UI.Section(c, "Interface", 320)
    ui:SetPoint("TOPLEFT", 360, -132)
    c.minimap = UI.Checkbox(c, "Bouton sur la minicarte", function(v)
        ns.char.ui.showMinimap = v
        if UI.Minimap then UI.Minimap:Update() end
    end)
    c.minimap:SetPoint("TOPLEFT", 360, -156)
    c.demo = UI.Checkbox(c, "Mode démo (données fictives)", function(v)
        ns.char.ui.demo = v
        UI.Refresh()
    end)
    c.demo:SetPoint("TOPLEFT", 360, -182)
    c.optOut = UI.Checkbox(c, "Ne pas apparaître dans l'album des autres", function(v) ns.char.albumOptOut = v end)
    c.optOut:SetPoint("TOPLEFT", 360, -208)

    local data = UI.Section(c, "Données", 320)
    data:SetPoint("TOPLEFT", 360, -250)
    c.dataInfo = UI.Text(c, 12)
    c.dataInfo:SetPoint("TOPLEFT", 360, -276)
    c.dataInfo:SetWidth(320)
    local unsupported = UI.Text(c, 10, UI.C.dim)
    unsupported:SetPoint("TOPLEFT", 360, -330)
    unsupported:SetWidth(320)
    c.unsupported = unsupported

    function c:Refresh()
        for key, d in pairs(self.privacy) do d:SetValue(ns.char.privacy[key] or "P") end
        self.export:SetChecked(ns.char.exportConsent)
        self.rival:SetText(ns.char.rivalGuild or "")
        self.minimap:SetChecked(ns.char.ui.showMinimap)
        self.demo:SetChecked(ns.char.ui.demo)
        self.optOut:SetChecked(ns.char.albumOptOut)
        self.dataInfo:SetText(("%d événement(s) enregistré(s) sur ce compte.\nSchéma de données v%d."):format(ns.Store.Count(), ns.Settings.SCHEMA))
        local list = {}
        for ev in pairs(ns.unsupportedEvents) do table.insert(list, ev) end
        table.sort(list)
        self.unsupported:SetText(#list > 0 and ("Événements indisponibles sur ce client : " .. table.concat(list, ", ")) or "")
    end
end

UI.RegisterTab({ key = "settings", label = "Paramètres", icon = "Interface\\Icons\\Trade_Engineering", order = 90,
    build = build, refresh = function(c) c:Refresh() end })
