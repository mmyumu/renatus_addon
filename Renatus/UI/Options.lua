-- UI/Options.lua: "Renatus" entry in the game's Options > AddOns panel.
-- Native controls (Blizzard Settings API) for the simple options; the rest
-- (rival guild, sync, voice details) stays in the addon window, reachable by a button.
-- Every setting reads and writes the same tables as the addon window (ns.char),
-- so both stay consistent. If the Settings API is missing or differs on this
-- client, a minimal panel with just the button is registered instead.
local ADDON, ns = ...
local UI = ns.UI

local O = ns:RegisterModule("Options", {})
UI.Options = O

local MODES = {
    { "OFF", "Désactivé" },
    { "P", "Privé" },
    { "G", "Guilde" },
}

local function openWindow(tab)
    if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() then
        if HideUIPanel then HideUIPanel(SettingsPanel) else SettingsPanel:Hide() end
    end
    UI.Open(tab)
end
O.OpenWindow = openWindow

-- Native panel (Settings API, 11.0+ signatures, also used by Midnight / Forever).
local function buildNative()
    local S = Settings
    local createCheckbox = S.CreateCheckbox or S.CreateCheckBox
    local createDropdown = S.CreateDropdown or S.CreateDropDown
    assert(S.RegisterVerticalLayoutCategory and S.RegisterAddOnSetting and createCheckbox and createDropdown,
        "Settings API incomplete")

    local category, layout = S.RegisterVerticalLayoutCategory("Renatus")

    local function header(text)
        if CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end

    local function button(label, text, tooltip, onClick)
        if CreateSettingsButtonInitializer then
            layout:AddInitializer(CreateSettingsButtonInitializer(label, text, onClick, tooltip, true))
        end
    end

    -- tbl[field] is the stored value; onChange runs after the value is written.
    local function setting(key, tbl, field, varType, name, default, onChange)
        local s = S.RegisterAddOnSetting(category, "Renatus_" .. key, field, tbl, varType, name, default)
        s:SetValueChangedCallback(function(_, value)
            if onChange then onChange(value) end
            UI.Refresh()
        end)
        return s
    end

    local function checkbox(key, tbl, field, name, default, tooltip, onChange)
        createCheckbox(category, setting(key, tbl, field, S.VarType.Boolean, name, default, onChange), tooltip)
    end

    local function modeOptions()
        local container = S.CreateControlTextContainer()
        for _, m in ipairs(MODES) do container:Add(m[1], m[2]) end
        return container:GetData()
    end

    local char = ns.char

    button("Fenêtre de Renatus", "Ouvrir", "Journal, guilde, tableau de chasse, gazette, album.",
        function() openWindow() end)

    header("Interface")
    checkbox("showMinimap", char.ui, "showMinimap", "Bouton sur la minicarte", true,
        "Affiche le bouton de Renatus sur le bord de la minicarte. Renatus reste accessible par /renatus et par le menu des addons de la minicarte.",
        function() if UI.Minimap then UI.Minimap:Update() end end)
    checkbox("demo", char.ui, "demo", "Mode démo (données fictives)", false,
        "Remplit chaque écran avec des données inventées. Rien n'est sauvegardé ni partagé.")

    header("Collecte et confidentialité")
    for _, cat in ipairs(ns.Types.CATEGORIES) do
        local s = setting("privacy_" .. cat.key, char.privacy, cat.key, S.VarType.String, cat.label, "P")
        createDropdown(category, s, modeOptions,
            "Désactivé : rien n'est enregistré. Privé : visible par toi seul. Guilde : partagé avec les membres équipés de l'addon.")
    end
    checkbox("exportConsent", char, "exportConsent", "La gazette rédigée par IA peut parler de moi", false,
        "Si coché, tes événements partagés avec la guilde peuvent être envoyés à une IA (Claude) par l'application du rédacteur, pour écrire la gazette. Si décoché, rien de toi n'est envoyé et ton nom est retiré des faits des autres. Ton choix est partagé avec la guilde.",
        function(v) ns.Press.SetConsent(v) end)
    checkbox("albumOptOut", char, "albumOptOut", "Ne pas apparaître dans l'album des autres", false,
        "Ta carte de membre n'est plus proposée dans l'album de guilde.")

    header("Voix (Renacoach)")
    checkbox("voice", char.voice, "enabled", "Répliques de Renacoach en combat", false,
        "Joue les répliques d'origine de Renacoach en combat. Réglages détaillés dans l'onglet Voix.",
        function(v) ns.Voice:SetEnabled(v) end)

    header("Plus de réglages")
    button("Guilde rivale, synchronisation", "Paramètres", "Ouvre l'onglet Paramètres de la fenêtre de Renatus.",
        function() openWindow("settings") end)
    button("Réglages détaillés de la voix", "Voix", "Ouvre l'onglet Voix de la fenêtre de Renatus.",
        function() openWindow("voice") end)

    S.RegisterAddOnCategory(category)
    return category
end

-- Fallback: a plain frame with a title and a button to open the window.
local function buildFallback()
    local panel = CreateFrame("Frame")
    panel.name = "Renatus"
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Renatus")
    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 16, -44)
    text:SetText("Les réglages sont dans la fenêtre de Renatus (onglet Paramètres).")
    local b = UI.Button(panel, "Ouvrir Renatus", 160, 24, function() openWindow("settings") end)
    b:SetPoint("TOPLEFT", 16, -72)
    O.fallbackPanel = panel
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Renatus")
        Settings.RegisterAddOnCategory(category)
        return category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
        return panel
    end
end

function O:OnInitialize()
    if Settings then
        local ok, result = pcall(buildNative)
        if ok then
            self.category, self.native = result, true
            return
        end
        self.error = result
    end
    local ok, result = pcall(buildFallback)
    if ok then self.category = result else self.error = result end
end

-- Opens the game's options on the Renatus page (falls back to the addon window).
function O.Open()
    local c = O.category
    if c and Settings and Settings.OpenToCategory and type(c) == "table" and c.GetID then
        Settings.OpenToCategory(c:GetID())
    elseif c and InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(c)
        InterfaceOptionsFrame_OpenToCategory(c) -- twice: known bug of the old panel
    else
        UI.Open("settings")
    end
end
