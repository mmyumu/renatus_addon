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

-- Inner margin: the "window" skin border (iron frame + garnet corners) is ~24 px thick.
local PAD = 28
local FIELD_W = 380

-- fields : { key, label, kind = "text"|"multi"|"choice"|"check", options, value, required, max }
-- opts   : { hint = footer text, save = save button label }
local function open(title, fields, onSave, opts)
    opts = opts or {}
    if dialog then dialog:Hide() end
    local f = CreateFrame("Frame", nil, UI.GetWindow())
    dialog = f
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER")
    UI.Skin(f, "window")
    local t = UI.Title(f, 18)
    t:SetPoint("TOPLEFT", PAD, -PAD + 2)
    t:SetText(title)
    local y = -PAD - 32
    local inputs = {}
    for _, field in ipairs(fields) do
        local label = UI.Text(f, 12)
        label:SetPoint("TOPLEFT", PAD, y)
        label:SetText(field.label .. (field.required and " |cffcc3322*|r" or ""))
        local input
        if field.kind == "multi" then
            input = UI.EditBox(f, FIELD_W, 90, true, field.max or 400)
            input:SetPoint("TOPLEFT", PAD, y - 18)
            input:SetText(field.value)
            y = y - 120
        elseif field.kind == "choice" then
            input = UI.Dropdown(f, 200, field.options)
            input:SetPoint("TOPLEFT", PAD, y - 18)
            input:SetValue(field.value or field.options[1].value)
            y = y - 50
        elseif field.kind == "check" then
            label:SetText("")
            input = UI.Checkbox(f, field.label)
            input:SetPoint("TOPLEFT", PAD - 4, y)
            input:SetChecked(field.value and true or false)
            y = y - 30
        else
            input = UI.EditBox(f, FIELD_W, 24, false, field.max or 80)
            input:SetPoint("TOPLEFT", PAD, y - 18)
            input:SetText(field.value)
            y = y - 54
        end
        inputs[field.key] = { field = field, input = input }
    end
    f.error = UI.Text(f, 11, UI.C.red)
    f.error:SetPoint("TOPLEFT", PAD, y)
    f.error:SetWidth(FIELD_W)
    local hint = UI.Text(f, 10, UI.C.dim)
    hint:SetPoint("TOPLEFT", PAD, y - 16)
    hint:SetWidth(FIELD_W)
    hint:SetText(opts.hint or "Saisie manuelle : affichée comme « déclarée », jamais comme vérifiée.")
    local hintH = math.max(12, hint:GetStringHeight() or 12)
    f:SetSize(FIELD_W + 2 * PAD, -y + 16 + hintH + 12 + 24 + PAD)

    local cancel = UI.Button(f, "Annuler", 100, 24, function() f:Hide() end)
    cancel:SetPoint("BOTTOMRIGHT", -PAD, PAD - 4)
    local save = UI.Button(f, opts.save or "Enregistrer", 120, 24, function()
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
    f.inputs, f.save = inputs, save
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
    return ns.GuildConfig.Rival() or ""
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
    end, { hint = "Prénom seul (« Ladou ») ou nom complet (« Ladou Pipø ») : les deux désignent le même ennemi."
        .. " Saisie manuelle : affichée comme « déclarée »." })
end

-- A letter to the editor about an issue (its key, nil = the latest one): published at
-- once, signed, at the end of that issue for every member.
function UI.Dialogs.Letter(edition)
    return open("Courrier des lecteurs", {
        { key = "title", label = "Objet", required = true, max = 80 },
        { key = "desc", label = "Votre lettre à la rédaction", kind = "multi", required = true, max = 400 },
    }, function(v)
        ns.Store.AddManual("LETTER", { title = v.title, desc = v.desc, edition = edition }, { vis = "G" })
    end, {
        save = "Envoyer",
        hint = "Publiée aussitôt, signée de ton nom, dans le courrier des lecteurs de ce numéro.",
    })
end

-- Yes / no question. onYes runs only on confirmation.
local confirm
function UI.Dialogs.Confirm(title, text, yesLabel, onYes)
    if confirm then confirm:Hide() end
    local f = CreateFrame("Frame", nil, UI.GetWindow())
    confirm = f
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER")
    f:SetSize(420, 170)
    UI.Skin(f, "window")
    local t = UI.Title(f, 18)
    t:SetPoint("TOPLEFT", 26, -24)
    t:SetText(title)
    local body = UI.Text(f, 12)
    body:SetPoint("TOPLEFT", 26, -54)
    body:SetWidth(368)
    body:SetText(text)
    f.text = body
    local no = UI.Button(f, "Annuler", 100, 24, function() f:Hide() end)
    no:SetPoint("BOTTOMRIGHT", -26, 24)
    f.no = no
    local yes = UI.Button(f, yesLabel or "Confirmer", 120, 24, function()
        f:Hide()
        onYes()
    end)
    yes:SetPoint("RIGHT", no, "LEFT", -8, 0)
    f.yes = yes
    f:Show()
    return f
end

-- Actions on one of the player's own events (right click in the journal): share it with
-- the guild or make it private, delete it. nil when none applies.
local actions
function UI.Dialogs.EventActions(ev)
    local Store = ns.Store
    local share, private, delete = Store.CanShare(ev), Store.CanMakePrivate(ev), Store.CanDelete(ev)
    if not (share or private or delete) then return nil end
    if actions then actions:Hide() end
    local what = ev.p and ev.p.title and ("« " .. ev.p.title .. " »") or ns.Types.Describe(ev, false)
    local f = CreateFrame("Frame", nil, UI.GetWindow())
    actions = f
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER")
    f:SetSize(460, 170)
    UI.Skin(f, "window")
    local t = UI.Title(f, 18)
    t:SetPoint("TOPLEFT", 26, -24)
    t:SetText(share and "Événement privé" or private and "Événement partagé" or "Mon événement")
    local body = UI.Text(f, 12)
    body:SetPoint("TOPLEFT", 26, -54)
    body:SetWidth(408)
    body:SetText(what .. "\n\n" .. (share and "Visible par toi seul. Le partager l'envoie aux membres de la guilde équipés de l'addon (et à la gazette, si tu l'acceptes)."
        or private and "Partagé avec la guilde. Le rendre privé efface la copie des autres membres ; une copie déjà lue ne peut pas être reprise."
        or ""))
    f.text = body
    local no = UI.Button(f, "Annuler", 90, 24, function() f:Hide() end)
    no:SetPoint("BOTTOMRIGHT", -26, 24)
    f.no = no
    local anchor = no
    if delete then
        f.delete = UI.Button(f, "Supprimer", 100, 24, function()
            f:Hide()
            UI.Dialogs.Delete(ev)
        end)
        f.delete:SetPoint("RIGHT", anchor, "LEFT", -8, 0)
        anchor = f.delete
    end
    if share or private then
        f.visibility = UI.Button(f, share and "Partager avec la guilde" or "Rendre privé", 170, 24, function()
            f:Hide()
            if share then Store.Share(ev.id) else Store.MakePrivate(ev.id) end
            UI.Refresh()
        end)
        f.visibility:SetPoint("RIGHT", anchor, "LEFT", -8, 0)
    end
    f:Show()
    return f
end

-- Deletion of one of the player's own events, after confirmation.
function UI.Dialogs.Delete(ev)
    if not ns.Store.CanDelete(ev) then return nil end
    local what = ev.p and ev.p.title and ("« " .. ev.p.title .. " »") or ns.Types.Describe(ev, false)
    local text = "Supprimer " .. what .. " de ton journal ?"
    if ev.vis == "G" then
        text = text .. "\n\nCet événement est partagé : la suppression est envoyée aux autres membres, "
            .. "dont l'addon effacera sa copie. Une copie déjà lue ou recopiée ailleurs ne peut pas être reprise."
    end
    return UI.Dialogs.Confirm("Supprimer", text, "Supprimer", function()
        ns.Store.Delete(ev.id)
        UI.Refresh()
    end)
end
