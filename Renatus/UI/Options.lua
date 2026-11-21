-- UI/Options.lua: every Renatus setting, in the game's Esc > Options > AddOns > Renatus.
-- The addon window only shows content (gazette, album, journals).
--
--   Renatus            native controls: display, privacy, AI consent, album
--     Voix             native controls: Renacoach voice lines
--
-- Members only see their own settings. Guild settings (rival guild), the editorial
-- tools, sync diagnostics and the demo mode live in the Renatus_Admin addon.
-- Every setting reads and writes ns.char directly, so the window stays consistent.
-- If the Settings API is missing or differs on this client, one canvas page with
-- the same settings (built with the addon's own widgets) is registered instead.
local ADDON, ns = ...
local UI = ns.UI

local O = ns:RegisterModule("Options", {})
UI.Options = O

local MODES = {
    { "OFF", "Désactivé" },
    { "P", "Privé" },
    { "G", "Guilde" },
}
local SHARE_PAST_HELP = "Partage avec la guilde tes événements déjà enregistrés en privé, pour les catégories réglées sur « Guilde ». Un événement à la fois : clic droit dessus dans Mon journal."

local function sharePast()
    local n = ns.Store.SharePast()
    ns.Print(n > 0 and ("%d événement(s) passé(s) partagé(s) avec la guilde.") or "aucun événement privé à partager (catégories réglées sur « Guilde »).", n)
    if UI.Refresh then UI.Refresh() end
end

local PRIVACY_HELP = "Désactivé : rien n'est enregistré. Privé : visible par toi seul. Guilde : partagé avec les membres équipés de l'addon."
local CONSENT_HELP = "Si coché, tes événements partagés avec la guilde peuvent être envoyés à une IA (Claude) par l'application du rédacteur, pour écrire la gazette. Si décoché, rien de toi n'est envoyé et ton nom est retiré des faits des autres. Ton choix est partagé avec la guilde."

local FAMILY_LABELS = {
    startFight = "Début de combat", endFight = "Fin de combat", death = "Mort",
    fightGeneric = "Encouragements (tous)", fightTank = "Tank", fightHealer = "Soigneur", fightDPS = "DPS",
    fightMelee = "Corps à corps", fightCaster = "Lanceur de sorts", fightRanged = "Distance",
}
local FAMILY_ORDER = { "startFight", "endFight", "death", "fightGeneric", "fightTank", "fightHealer",
    "fightDPS", "fightMelee", "fightCaster", "fightRanged" }
local CHANNELS = { { "Ambience", "Ambiance" }, { "Master", "Général" }, { "SFX", "Effets" },
    { "Dialog", "Dialogues" }, { "Music", "Musique" } }
local ROLES = { { "AUTO", "Automatique" }, { "TANK", "Tank" }, { "HEALER", "Soigneur" }, { "DAMAGER", "DPS" } }
local KINDS = { { "AUTO", "Automatique" }, { "melee", "Corps à corps" }, { "caster", "Lanceur de sorts" }, { "ranged", "Distance" } }

local function openWindow(tab)
    if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() then
        if HideUIPanel then HideUIPanel(SettingsPanel) else SettingsPanel:Hide() end
    end
    UI.Open(tab)
end
O.OpenWindow = openWindow

local function playSample() ns.Voice:PlaySample() end
O.PlaySample = playSample

------------------------------------------------------------------------
-- Fallback page (no usable Settings API): addon widgets on a canvas.
------------------------------------------------------------------------
local function buildCanvas()
    local f = CreateFrame("Frame")
    f.name = "Renatus"
    local x, y = 16, -16
    local title = UI.Title(f, 22)
    title:SetPoint("TOPLEFT", x, y)
    title:SetText("Renatus")
    y = y - 40

    local priv = UI.Section(f, "Collecte et confidentialité", 300)
    priv:SetPoint("TOPLEFT", x, y)
    y = y - 28
    f.privacy = {}
    local opts = {}
    for _, m in ipairs(MODES) do opts[#opts + 1] = { value = m[1], label = m[2] } end
    for _, cat in ipairs(ns.Types.CATEGORIES) do
        local label = UI.Text(f, 12)
        label:SetPoint("TOPLEFT", x, y - 4)
        label:SetText(cat.label)
        local d = UI.Dropdown(f, 130, opts, function(v) ns.char.privacy[cat.key] = v end)
        d:SetPoint("TOPLEFT", x + 180, y)
        f.privacy[cat.key] = d
        y = y - 26
    end
    UI.Tooltip(priv, "Confidentialité", { PRIVACY_HELP })
    f.sharePast = UI.Button(f, "Partager mes événements passés", 230, 22, sharePast)
    f.sharePast:SetPoint("TOPLEFT", x, y - 2)
    UI.Tooltip(f.sharePast, "Partager mes événements passés", { SHARE_PAST_HELP })
    y = y - 30
    f.export = UI.Checkbox(f, "La gazette rédigée par IA peut parler de moi", function(v) ns.Consent.SetConsent(v) end)
    f.export:SetPoint("TOPLEFT", x, y)
    UI.Tooltip(f.export, "Gazette IA", { CONSENT_HELP })
    f.minimap = UI.Checkbox(f, "Bouton sur la minicarte", function(v)
        ns.char.ui.showMinimap = v
        if UI.Minimap then UI.Minimap:Update() end
    end)
    f.minimap:SetPoint("TOPLEFT", x, y - 24)
    f.widget = UI.Checkbox(f, "Icône de la gazette (nouveautés)", function(v)
        ns.char.ui.showWidget = v
        if UI.Notifier then UI.Notifier:Update() end
    end)
    f.widget:SetPoint("TOPLEFT", x, y - 48)
    f.optOut = UI.Checkbox(f, "Ne pas apparaître dans l'album des autres", function(v)
        ns.char.albumOptOut = v
        if ns.Profile then ns.Profile.Publish() end
    end)
    f.optOut:SetPoint("TOPLEFT", x, y - 72)

    function f:Refresh()
        for key, d in pairs(self.privacy) do d:SetValue(ns.char.privacy[key] or "G") end
        self.export:SetChecked(ns.char.exportConsent)
        self.minimap:SetChecked(ns.char.ui.showMinimap)
        self.widget:SetChecked(ns.char.ui.showWidget)
        self.optOut:SetChecked(ns.char.albumOptOut)
    end
    f:SetScript("OnShow", function(self) self:Refresh() end)
    return f
end

------------------------------------------------------------------------
-- Native pages (Settings API, 11.0+ signatures, also used by Midnight / Forever)
------------------------------------------------------------------------
local function buildNative()
    local S = Settings
    local createCheckbox = S.CreateCheckbox or S.CreateCheckBox
    local createDropdown = S.CreateDropdown or S.CreateDropDown
    assert(S.RegisterVerticalLayoutCategory and S.RegisterAddOnSetting and createCheckbox and createDropdown,
        "Settings API incomplete")
    local char = ns.char

    local function page(category, layout)
        local P = { category = category, layout = layout }
        function P.header(text)
            if CreateSettingsListSectionHeaderInitializer then
                layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
            end
        end
        function P.button(label, text, tooltip, onClick)
            if CreateSettingsButtonInitializer then
                layout:AddInitializer(CreateSettingsButtonInitializer(label, text, onClick, tooltip, true))
            end
        end
        -- tbl[field] is the stored value; onChange runs after the value is written.
        function P.setting(key, tbl, field, varType, name, default, onChange)
            local s = S.RegisterAddOnSetting(category, "Renatus_" .. key, field, tbl, varType, name, default)
            s:SetValueChangedCallback(function(_, value)
                if onChange then onChange(value) end
                UI.Refresh()
            end)
            return s
        end
        function P.checkbox(key, tbl, field, name, default, tooltip, onChange)
            createCheckbox(category, P.setting(key, tbl, field, S.VarType.Boolean, name, default, onChange), tooltip)
        end
        function P.dropdown(key, tbl, field, name, default, choices, tooltip, onChange)
            local s = P.setting(key, tbl, field, S.VarType.String, name, default, onChange)
            createDropdown(category, s, function()
                local container = S.CreateControlTextContainer()
                for _, c in ipairs(choices) do container:Add(c[1], c[2]) end
                return container:GetData()
            end, tooltip)
        end
        function P.slider(key, tbl, field, name, default, min, max, step, format, tooltip, onChange)
            if not (S.CreateSlider and S.CreateSliderOptions) then return end
            local s = P.setting(key, tbl, field, S.VarType.Number, name, default, onChange)
            local opts = S.CreateSliderOptions(min, max, step)
            if opts.SetLabelFormatter and MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
                opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, format)
            end
            S.CreateSlider(category, s, opts, tooltip)
        end
        return P
    end

    -- Main page
    local category, layout = S.RegisterVerticalLayoutCategory("Renatus")
    local P = page(category, layout)
    P.button("Fenêtre de Renatus", "Ouvrir", "Gazette, album et journaux.", function() openWindow() end)
    P.header("Affichage")
    P.checkbox("showMinimap", char.ui, "showMinimap", "Bouton sur la minicarte", true,
        "Affiche le bouton de Renatus sur le bord de la minicarte. Renatus reste accessible par /renatus et par le menu des addons de la minicarte.",
        function() if UI.Minimap then UI.Minimap:Update() end end)
    P.checkbox("showWidget", char.ui, "showWidget", "Icône de la gazette (nouveautés)", true,
        "Petite icône déplaçable à l'écran : un « ! » rouge quand la gazette a de nouveaux articles, une pastille dorée avec le nombre de boosters à ouvrir. Clic gauche : la gazette ; clic droit : l'album.",
        function() if UI.Notifier then UI.Notifier:Update() end end)
    P.header("Collecte et confidentialité")
    for _, cat in ipairs(ns.Types.CATEGORIES) do
        P.dropdown("privacy_" .. cat.key, char.privacy, cat.key, cat.label, "G", MODES, PRIVACY_HELP)
    end
    P.button("Événements passés", "Partager", SHARE_PAST_HELP, sharePast)
    P.checkbox("exportConsent", char, "exportConsent", "La gazette rédigée par IA peut parler de moi", true,
        CONSENT_HELP, function(v) ns.Consent.SetConsent(v) end)
    P.checkbox("albumOptOut", char, "albumOptOut", "Ne pas apparaître dans l'album des autres", false,
        "Tes cartes de membre ne sont plus proposées dans l'album des autres.",
        function() if ns.Profile then ns.Profile.Publish() end end)

    -- Voice page
    local vcat, vlayout
    if S.RegisterVerticalLayoutSubcategory then
        vcat, vlayout = S.RegisterVerticalLayoutSubcategory(category, "Voix")
    end
    local V = vcat and page(vcat, vlayout) or P
    if not vcat then P.header("Voix (Renacoach)") end
    local voice = char.voice
    local function rebuild() ns.Voice:RebuildPools() end
    V.checkbox("voice", voice, "enabled", "Répliques de Renacoach en combat", false,
        "Le coach vocal, pour la blague : les répliques d'origine de Renacoach, entendues par toi seul.",
        function(v) ns.Voice:SetEnabled(v) end)
    V.button("Tester", "Écouter une réplique",
        "Rejoue la dernière réplique entendue en combat (une réplique d'exemple tant que tu n'en as entendu aucune), pour régler le volume. Les autres se découvrent en jouant.",
        playSample)
    V.slider("voiceProbability", voice, "probability", "Chance de réplique en combat", 0.5, 0, 1, 0.05,
        function(v) return math.floor(v * 100 + 0.5) .. " %" end, "À chaque tirage en combat.")
    V.slider("voiceInterval", voice, "interval", "Tirage toutes les", 3, 1, 15, 1,
        function(v) return math.floor(v + 0.5) .. " s" end)
    V.dropdown("voiceChannel", voice, "channel", "Canal audio", "Ambience", CHANNELS)
    V.checkbox("voiceDuck", voice, "duck", "Baisser les effets sonores pendant une réplique", true, nil,
        function(v) if not v then ns.Voice.RestoreVolume(true) end end)
    V.slider("voiceDuckVolume", voice, "duckVolume", "Volume des effets pendant une réplique", 0.25, 0, 1, 0.05,
        function(v) return math.floor(v * 100 + 0.5) .. " %" end)
    V.dropdown("voiceRole", voice, "roleOverride", "Rôle", "AUTO", ROLES,
        "Automatique : d'après la spécialisation ou le rôle de groupe. Si ta spé n'est pas reconnue (Forever), choisis-le ici.", rebuild)
    V.dropdown("voiceType", voice, "typeOverride", "Style de combat", "AUTO", KINDS, nil, rebuild)
    V.header("Familles de répliques")
    for _, key in ipairs(FAMILY_ORDER) do
        V.checkbox("voiceFamily_" .. key, voice.families, key, FAMILY_LABELS[key], true)
    end

    S.RegisterAddOnCategory(category)
    O.voiceCategory = vcat
    return category
end

-- Fallback: one canvas page with the member settings; the voice stays on /renatus voice.
local function buildFallback()
    local panel = buildCanvas()
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

-- Opens the game's options on a Renatus page: nil / "settings" = main, "voice".
function O.Open(which)
    local c = O.category
    if which == "voice" and O.voiceCategory then c = O.voiceCategory end
    if c and Settings and Settings.OpenToCategory and type(c) == "table" and c.GetID then
        Settings.OpenToCategory(c:GetID())
        return true
    elseif c and InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(c)
        InterfaceOptionsFrame_OpenToCategory(c) -- twice: known bug of the old panel
        return true
    end
    ns.Print("options indisponibles sur ce client : /renatus help")
    return false
end
