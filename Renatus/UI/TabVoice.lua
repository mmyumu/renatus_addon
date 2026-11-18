-- UI/TabVoice.lua: voice module settings (Renacoach), fully functional.
local _, ns = ...
local UI = ns.UI

local FAMILY_LABELS = {
    startFight = "Début de combat", endFight = "Fin de combat", death = "Mort",
    fightGeneric = "Encouragements (tous)", fightTank = "Tank", fightHealer = "Soigneur", fightDPS = "DPS",
    fightMelee = "Corps à corps", fightCaster = "Lanceur de sorts", fightRanged = "Distance",
}
local FAMILY_ORDER = { "startFight", "endFight", "death", "fightGeneric", "fightTank", "fightHealer",
    "fightDPS", "fightMelee", "fightCaster", "fightRanged" }
local CHANNELS = {
    { value = "Ambience", label = "Ambiance" }, { value = "Master", label = "Général" },
    { value = "SFX", label = "Effets" }, { value = "Dialog", label = "Dialogues" }, { value = "Music", label = "Musique" },
}

local ROLES = {
    { value = "AUTO", label = "Automatique" }, { value = "TANK", label = "Tank" },
    { value = "HEALER", label = "Soigneur" }, { value = "DAMAGER", label = "DPS" },
}
local KINDS = {
    { value = "AUTO", label = "Automatique" }, { value = "melee", label = "Corps à corps" },
    { value = "caster", label = "Lanceur de sorts" }, { value = "ranged", label = "Distance" },
}
local ROLE_LABEL = { TANK = "tank", HEALER = "soigneur", DAMAGER = "DPS" }
local KIND_LABEL = { melee = "corps à corps", caster = "lanceur de sorts", ranged = "distance" }

local function build(c)
    local s = function() return ns.char.voice end
    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Renacoach")
    local sub = UI.Text(c, 11, UI.C.dim)
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetText("Le coach vocal, pour la blague. Les répliques ne sont entendues que par toi.")

    c.enabled = UI.Checkbox(c, "Activer les répliques", function(v) ns.Voice:SetEnabled(v); c:Refresh() end)
    c.enabled:SetPoint("TOPLEFT", 4, -50)
    c.enabled.label:SetFont(UI.FONT_BODY, 14, "")

    c.status = UI.Text(c, 11, UI.C.dim)
    c.status:SetPoint("TOPLEFT", 8, -74)
    c.status:SetWidth(UI.CONTENT_W - 20)

    local general = UI.Section(c, "Fréquence et son", 320)
    general:SetPoint("TOPLEFT", 4, -104)
    c.prob = UI.Slider(c, "Chance de réplique en combat", 0, 1, 0.05, 300, "%.2f", function(v) s().probability = v end)
    c.prob:SetPoint("TOPLEFT", 4, -130)
    -- shown as a percentage
    c.prob.slider:HookScript("OnValueChanged", function(_, v)
        c.prob.label:SetText("Chance de réplique en combat : |cffffffff" .. math.floor(v * 100 + 0.5) .. " %|r")
    end)
    c.interval = UI.Slider(c, "Tirage toutes les", 1, 15, 1, 300, "%d s", function(v) s().interval = v end)
    c.interval:SetPoint("TOPLEFT", 4, -180)
    c.duck = UI.Checkbox(c, "Baisser les effets sonores pendant une réplique", function(v)
        s().duck = v
        if not v then ns.Voice.RestoreVolume(true) end
    end)
    c.duck:SetPoint("TOPLEFT", 4, -230)
    c.duckVolume = UI.Slider(c, "Volume des effets pendant une réplique", 0, 1, 0.05, 300, "%.2f", function(v) s().duckVolume = v end)
    c.duckVolume:SetPoint("TOPLEFT", 4, -262)
    local chLabel = UI.Text(c, 12)
    chLabel:SetPoint("TOPLEFT", 4, -316)
    chLabel:SetText("Canal audio :")
    c.channel = UI.Dropdown(c, 150, CHANNELS, function(v) s().channel = v end)
    c.channel:SetPoint("LEFT", chLabel, "RIGHT", 10, 0)

    local test = UI.Button(c, "Écouter une réplique", 170, 24, function()
        local was = s().enabled
        s().enabled = true
        ns.Voice:PlayFamilies(ns.Voice:GetCombatFamilies())
        s().enabled = was
    end)
    test:SetPoint("TOPLEFT", 4, -350)

    -- Forever specializations may differ from Retail: manual override available.
    local roleLabel = UI.Text(c, 12)
    roleLabel:SetPoint("TOPLEFT", 4, -394)
    roleLabel:SetText("Rôle :")
    c.role = UI.Dropdown(c, 150, ROLES, function(v) s().roleOverride = v; ns.Voice:RebuildPools(); c:Refresh() end)
    c.role:SetPoint("TOPLEFT", 120, -390)
    local kindLabel = UI.Text(c, 12)
    kindLabel:SetPoint("TOPLEFT", 4, -424)
    kindLabel:SetText("Style de combat :")
    c.kind = UI.Dropdown(c, 150, KINDS, function(v) s().typeOverride = v; ns.Voice:RebuildPools(); c:Refresh() end)
    c.kind:SetPoint("TOPLEFT", 120, -420)
    UI.Tooltip(c.role, "Rôle", { "Automatique : d'après la spécialisation ou le rôle de groupe.",
        "Si ta spé n'est pas reconnue (Forever), choisis-le ici." })

    local fam = UI.Section(c, "Familles de répliques", 320)
    fam:SetPoint("TOPLEFT", 350, -104)
    c.families = {}
    for i, key in ipairs(FAMILY_ORDER) do
        local count = #(ns.Voice.FAMILIES[key] or {})
        local cb = UI.Checkbox(c, FAMILY_LABELS[key] .. "  |cff999999(" .. count .. ")|r", function(v) s().families[key] = v end)
        cb:SetPoint("TOPLEFT", 350, -126 - (i - 1) * 26)
        c.families[key] = cb
    end

    local future = UI.Text(c, 11, UI.C.dim)
    future:SetPoint("BOTTOMLEFT", 4, 4)
    future:SetWidth(UI.CONTENT_W - 10)
    future:SetText("Bientôt : répliques déclenchées par l'histoire (morts à répétition, revanche sur un boss…), avec les sons existants uniquement.")

    function c:Refresh()
        local v = s()
        self.enabled:SetChecked(v.enabled)
        self.prob:SetValue(v.probability)
        self.prob.label:SetText("Chance de réplique en combat : |cffffffff" .. math.floor(v.probability * 100 + 0.5) .. " %|r")
        self.interval:SetValue(v.interval)
        self.duck:SetChecked(v.duck)
        self.duckVolume:SetValue(v.duckVolume)
        self.channel:SetValue(v.channel)
        for key, cb in pairs(self.families) do cb:SetChecked(v.families[key] ~= false) end
        self.role:SetValue(v.roleOverride or "AUTO")
        self.kind:SetValue(v.typeOverride or "AUTO")
        local V = ns.Voice
        local role = ROLE_LABEL[V.role] or "inconnu"
        if V.roleSource then role = role .. " (" .. V.roleSource .. ")" end
        local ctype = KIND_LABEL[V.characterType] or "inconnu"
        if V.typeSource then ctype = ctype .. " (" .. V.typeSource .. ")" end
        local spec = V.specID and ("  ·  spé n°" .. tostring(V.specID) .. (V.SPEC_TYPES[V.specID] and "" or " (non reconnue)")) or ""
        self.status:SetText(("Rôle : %s  ·  style : %s%s\nFamilles jouées en combat : %s"):format(
            role, ctype, spec, table.concat(V:GetCombatFamilies(), ", ")))
    end
end

UI.RegisterTab({ key = "voice", label = "Voix", icon = "Interface\\Icons\\Spell_Holy_Silence", order = 70,
    build = build, refresh = function(c) c:Refresh() end })
