-- UI/Dialogs.lua: manual entry forms. Everything entered is flagged "Declared" (MAN).
local _, ns = ...
local UI = ns.UI

UI.Dialogs = {}

local CLASSES = {
    { value = "", label = "Classe inconnue" },
    { value = "WARRIOR", label = "Guerrier" }, { value = "PALADIN", label = "Paladin" },
    { value = "HUNTER", label = "Chasseur" }, { value = "ROGUE", label = "Voleur" },
    { value = "PRIEST", label = "Prêtre" }, { value = "SHAMAN", label = "Chaman" },
    { value = "MAGE", label = "Mage" }, { value = "WARLOCK", label = "Démoniste" },
    { value = "DRUID", label = "Druide" },
}

local dialog

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

-- fields : { key, label, kind = "text"|"multi"|"choice"|"check", options, value, required, max }
local function open(title, fields, onSave)
    if dialog then dialog:Hide() end
    local f = CreateFrame("Frame", nil, UI.GetWindow())
    dialog = f
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER")
    UI.Skin(f, "window")
    local t = UI.Title(f, 18)
    t:SetPoint("TOPLEFT", 16, -14)
    t:SetText(title)
    local y = -46
    local inputs = {}
    for _, field in ipairs(fields) do
        local label = UI.Text(f, 12)
        label:SetPoint("TOPLEFT", 16, y)
        label:SetText(field.label .. (field.required and " |cffcc3322*|r" or ""))
        local input
        if field.kind == "multi" then
            input = UI.EditBox(f, 380, 70, true, field.max or 400)
            input:SetPoint("TOPLEFT", 16, y - 18)
            input:SetText(field.value)
            y = y - 98
        elseif field.kind == "choice" then
            input = UI.Dropdown(f, 200, field.options)
            input:SetPoint("TOPLEFT", 16, y - 18)
            input:SetValue(field.value or field.options[1].value)
            y = y - 48
        elseif field.kind == "check" then
            label:SetText("")
            input = UI.Checkbox(f, field.label)
            input:SetPoint("TOPLEFT", 12, y)
            input:SetChecked(field.value and true or false)
            y = y - 30
        else
            input = UI.EditBox(f, 380, 24, false, field.max or 80)
            input:SetPoint("TOPLEFT", 16, y - 18)
            input:SetText(field.value)
            y = y - 50
        end
        inputs[field.key] = { field = field, input = input }
    end
    f.error = UI.Text(f, 11, UI.C.red)
    f.error:SetPoint("TOPLEFT", 16, y - 2)
    local hint = UI.Text(f, 10, UI.C.dim)
    hint:SetPoint("TOPLEFT", 16, y - 18)
    hint:SetWidth(380)
    hint:SetText("Saisie manuelle : affichée comme « déclarée », jamais comme vérifiée.")
    f:SetSize(412, -y + 76)

    local cancel = UI.Button(f, "Annuler", 100, 24, function() f:Hide() end)
    cancel:SetPoint("BOTTOMRIGHT", -16, 14)
    local save = UI.Button(f, "Enregistrer", 120, 24, function()
        local values = {}
        for key, entry in pairs(inputs) do
            local field, input = entry.field, entry.input
            local v
            if field.kind == "choice" then v = input.value
            elseif field.kind == "check" then v = input:GetChecked() and true or false
            else v = trim(input:GetText()) end
            if field.required and (v == nil or v == "") then
                f.error:SetText("Champ obligatoire : " .. field.label)
                return
            end
            if v == "" then v = nil end
            values[key] = v
        end
        f:Hide()
        onSave(values)
        UI.Refresh()
    end)
    save:SetPoint("RIGHT", cancel, "LEFT", -8, 0)
    f:Show()
    return f
end
UI.Dialogs.Open = open

local function currentZone() return ns.Try(GetRealZoneText) or "" end

local function namesToParticipants(text)
    if not text then return nil end
    local list = {}
    for name in string.gmatch(text, "[^,;]+") do
        name = trim(name)
        if name ~= "" then table.insert(list, { n = name }) end
    end
    return #list > 0 and list or nil
end

local function rivalDefault()
    local ds = ns.Store.Dataset()
    if ds.isDemo then return "Les Crocs de Sang" end
    return ns.char.rivalGuild or ""
end

function UI.Dialogs.Anecdote()
    open("Nouvelle anecdote", {
        { key = "title", label = "Titre", required = true, max = 80 },
        { key = "desc", label = "Ce qui s'est passé", kind = "multi", max = 400 },
        { key = "cat", label = "Catégorie", kind = "choice", options = {
            { value = "Soirée de guilde", label = "Soirée de guilde" }, { value = "Fait divers", label = "Fait divers" },
            { value = "Exploit", label = "Exploit" }, { value = "Rivalité", label = "Rivalité amicale" },
            { value = "Expédition improvisée", label = "Expédition improvisée" }, { value = "Autre", label = "Autre" } } },
        { key = "pt", label = "Participants (séparés par des virgules)", max = 200 },
        { key = "zone", label = "Lieu (facultatif)", value = currentZone(), max = 80 },
    }, function(v)
        ns.Store.AddManual("ANECDOTE", { title = v.title, desc = v.desc, cat = v.cat },
            { pt = namesToParticipants(v.pt), loc = { z = v.zone } })
    end)
end

function UI.Dialogs.EnemyNote(name)
    open("Fiche ennemie : ajout / annotation", {
        { key = "name", label = "Nom du personnage", required = true, value = name, max = 40 },
        { key = "guild", label = "Guilde", value = rivalDefault(), max = 48 },
        { key = "class", label = "Classe", kind = "choice", options = CLASSES, value = "" },
        { key = "nickname", label = "Surnom", max = 60 },
        { key = "note", label = "Annotation", kind = "multi", max = 300 },
        { key = "sworn", label = "Je le désigne comme ennemi juré", kind = "check" },
    }, function(v)
        ns.Store.AddManual("ENEMY_NOTE", { name = v.name, guild = v.guild, class = v.class, nickname = v.nickname,
            note = v.note, sworn = v.sworn or nil })
    end)
end

function UI.Dialogs.Clash(name)
    open("Déclarer un affrontement", {
        { key = "name", label = "Adversaire", required = true, value = name, max = 40 },
        { key = "result", label = "Issue", kind = "choice", options = {
            { value = "win", label = "Victoire" }, { value = "loss", label = "Défaite" }, { value = "draw", label = "Indécis / fuite" } } },
        { key = "zone", label = "Lieu", value = currentZone(), max = 80 },
        { key = "note", label = "Commentaire", kind = "multi", max = 300 },
    }, function(v)
        ns.Store.AddManual("PVP_CLASH", { name = v.name, enemy = v.name, result = v.result, desc = v.note }, { loc = { z = v.zone } })
    end)
end

function UI.Dialogs.Wanted(name)
    open("Placarder un avis de recherche", {
        { key = "name", label = "Recherché", required = true, value = name, max = 40 },
        { key = "nickname", label = "Surnom", max = 60 },
        { key = "reason", label = "Motif", required = true, kind = "multi", max = 200 },
        { key = "reward", label = "Récompense (symbolique)", value = "100 pièces de vantardise", max = 80 },
    }, function(v)
        ns.Store.AddManual("WANTED", { name = v.name, nickname = v.nickname, reason = v.reason, reward = v.reward })
    end)
end

function UI.Dialogs.Letter()
    open("Courrier des lecteurs", {
        { key = "title", label = "Objet", required = true, max = 80 },
        { key = "desc", label = "Votre lettre à la rédaction", kind = "multi", required = true, max = 400 },
    }, function(v)
        ns.Store.AddManual("LETTER", { title = v.title, desc = v.desc })
    end)
end
