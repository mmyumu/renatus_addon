-- Core/Press.lua : elements produits hors jeu par l'application compagnon du redacteur.
--
-- Le compagnon ecrit Interface/AddOns/GuildChronicle_Press/Press.lua (une simple table Lua).
-- Le jeu le relit a chaque /reload. Rien n'est publie automatiquement : le redacteur
-- passe en revue chaque element (Publier / Ignorer) dans l'onglet Gazette.
-- Une fois publie, l'element devient un evenement signe par le redacteur :
--   DEATH_CAUSE, PVP_CLASH -> provenance LOG ("d'apres le journal de combat de X")
--   ARTICLE                -> provenance GEN (redaction ; les faits sont dans refs)
local _, ns = ...

local Press = {}
ns.Press = Press

local KINDS = {
    DEATH_CAUSE = { prov = "LOG", label = "Cause de mort" },
    PVP_CLASH = { prov = "LOG", label = "Affrontement (journal de combat)" },
    ARTICLE = { prov = "GEN", label = "Article" },
}
Press.KINDS = KINDS

local function valid(item)
    return type(item) == "table" and type(item.id) == "string" and KINDS[item.kind] ~= nil
        and type(item.p) == "table"
end

function Press.Available()
    return type(GuildChroniclePress) == "table" and type(GuildChroniclePress.items) == "table"
end

function Press.Pending()
    local out = {}
    if not Press.Available() then return out end
    for _, item in ipairs(GuildChroniclePress.items) do
        if valid(item) and not ns.db.pressDone[item.id] then table.insert(out, item) end
    end
    return out
end

function Press.Label(item)
    local k = KINDS[item.kind]
    local p = item.p
    if item.kind == "ARTICLE" then return k.label .. " : " .. tostring(p.title) end
    if item.kind == "DEATH_CAUSE" then return ("Mort de %s : %s"):format(tostring(p.victim), tostring(p.cause)) end
    if item.kind == "PVP_CLASH" then
        return ("%s %s %s"):format(tostring(p.member), p.result == "win" and "a vaincu" or "a été vaincu par", tostring(p.name))
    end
    return k.label
end

function Press.Publish(item)
    if not valid(item) or ns.db.pressDone[item.id] then return nil end
    local k = KINDS[item.kind]
    local refs = {}
    for _, r in ipairs(type(item.refs) == "table" and item.refs or {}) do
        if type(r) == "string" then table.insert(refs, r) end
    end
    local ev = ns.Store.Add(item.kind, item.p, {
        prov = k.prov, refs = #refs > 0 and refs or nil, vis = "G", noExp = true,
        loc = type(item.loc) == "table" and item.loc or {},
        occ = item.occ, t = type(item.t) == "number" and item.t or nil,
    })
    if ev then ns.db.pressDone[item.id] = "published" end
    return ev
end

function Press.Ignore(item)
    if valid(item) then ns.db.pressDone[item.id] = "ignored" end
end
