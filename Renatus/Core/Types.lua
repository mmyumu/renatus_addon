-- Core/Types.lua: registry of event types, categories and provenances.
-- Adding a type = adding an entry to TYPES.
local _, ns = ...

local Types = {}
ns.Types = Types

Types.CATEGORIES = {
    { key = "progression", label = "Progression" },
    { key = "combat", label = "Combat" },
    { key = "exploration", label = "Exploration" },
    { key = "social", label = "Vie sociale" },
    { key = "pvp", label = "PvP" },
    { key = "anecdote", label = "Anecdotes" },
    { key = "gazette", label = "Gazette (votes, courrier)" },
}

-- Provenance: never conflated (see docs/ARCHITECTURE.md §4.2).
Types.PROVENANCE = {
    OBS = { label = "Observé", color = { 0.55, 0.85, 0.55 }, help = "Détecté automatiquement par l'addon." },
    LOG = { label = "Journal de combat", color = { 0.45, 0.7, 1 }, help = "Issu d'un fichier de journal de combat (application compagnon)." },
    MAN = { label = "Déclaré", color = { 1, 0.75, 0.3 }, help = "Déclaré manuellement par un membre, non vérifié automatiquement." },
    DED = { label = "Supposé", color = { 0.75, 0.75, 0.75 }, help = "Déduit par une règle : ce n'est pas un fait confirmé." },
    GEN = { label = "Rédaction", color = { 0.85, 0.6, 0.85 }, help = "Texte écrit par la rédaction de la gazette ; seuls les faits cités en sources font foi." },
}

-- Labels for deduced (ev.ded) and missing (ev.miss) fields.
Types.DEDUCED = {
    enemies = "Les « ennemis présents » sont ceux aperçus dans les 30 secondes avant la mort, pas forcément les tueurs.",
    finish = "Fin estimée : la session s'est terminée pendant l'expédition.",
}

local function zoneOf(ev) return ev.loc and (ev.loc.i or ev.loc.z) or nil end

local function resultText(p)
    local enemy = p.enemy or p.name or "un ennemi"
    if p.result == "win" then return "l'emporte face à " .. enemy
    elseif p.result == "loss" then return "tombe face à " .. enemy
    end
    return "affronte " .. enemy
end

local TYPES = {
    LEVEL_UP = { cat = "progression", icon = "Interface\\Icons\\Spell_Holy_SurgeOfLight", importance = 3,
        text = function(ev) return ("atteint le niveau %s"):format(tostring(ev.p.lvl or "?")) end },
    DEATH = { cat = "combat", icon = "Interface\\Icons\\Ability_Rogue_FeignDeath", importance = 2,
        text = function(ev)
            local s = "meurt"
            if ev.p.lvl then s = s .. " au niveau " .. ev.p.lvl end
            if ev.p.cause then s = s .. " (" .. ev.p.cause .. ")" end
            if ev.p.enemies and #ev.p.enemies > 0 then
                s = s .. " — ennemis présents : " .. table.concat(ev.p.enemies, ", ")
            end
            return s
        end },
    BOSS_KILL = { cat = "combat", icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01", importance = 4,
        text = function(ev) return "triomphe de " .. (ev.p.name or ("la rencontre n°" .. tostring(ev.p.enc or "?"))) end },
    QUEST_DONE = { cat = "progression", icon = "Interface\\Icons\\INV_Misc_Note_01", importance = 1,
        text = function(ev)
            if ev.p.title then return "termine la quête « " .. ev.p.title .. " »" end
            return "termine une quête (n°" .. tostring(ev.p.q or "?") .. ")"
        end },
    ZONE_FIRST_VISIT = { cat = "exploration", icon = "Interface\\Icons\\INV_Misc_Map_01", importance = 2,
        text = function(ev) return "découvre " .. (zoneOf(ev) or "une nouvelle contrée") end },
    EXPEDITION = { cat = "social", icon = "Interface\\Icons\\INV_Misc_Map02", importance = 4,
        text = function(ev)
            local p = ev.p
            local where = p.inst or zoneOf(ev) or "?"
            local default = (p.type == "RAID" and ("raid : " .. where))
                or (p.type == "DUNGEON" and ("expédition dans " .. where))
                or (p.type == "PVP" and ("bataille : " .. where))
                or ("expédition en " .. where)
            local s = p.title or default
            local bits = {}
            if p.duration then table.insert(bits, math.floor(p.duration / 60) .. " min") end
            if p.bosses and p.bosses > 0 then table.insert(bits, p.bosses .. " boss") end
            if p.deaths and p.deaths > 0 then table.insert(bits, p.deaths .. " mort(s)") end
            if #bits > 0 then s = s .. " (" .. table.concat(bits, ", ") .. ")" end
            return s
        end },
    GUILD_JOIN = { cat = "social", icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01", importance = 4,
        text = function(ev) return "rejoint la guilde " .. tostring(ev.p.guild or "?") end },
    PROFESSION = { cat = "progression", icon = "Interface\\Icons\\Trade_BlackSmithing", importance = 2,
        text = function(ev) return ("atteint %s en %s"):format(tostring(ev.p.rank or "?"), tostring(ev.p.skill or "?")) end },
    RARE_ITEM = { cat = "progression", icon = "Interface\\Icons\\INV_Misc_Gem_01", importance = 3,
        text = function(ev) return "obtient " .. tostring(ev.p.item or "un objet rare") end },
    ANECDOTE = { cat = "anecdote", icon = "Interface\\Icons\\INV_Scroll_03", importance = 3,
        text = function(ev) return ev.p.title or "anecdote" end },
    ENEMY_SEEN = { cat = "pvp", icon = "Interface\\Icons\\Ability_Hunter_SniperShot", importance = 1,
        text = function(ev)
            local g = ev.p.guild and (" <" .. ev.p.guild .. ">") or ""
            return "aperçoit " .. tostring(ev.p.name) .. g
        end },
    PVP_CLASH = { cat = "pvp", icon = "Interface\\Icons\\Ability_DualWield", importance = 3,
        text = function(ev)
            -- published by the editor on behalf of another member (combat log)
            if ev.p.member and ev.p.member ~= ev.n then
                return "rapporte : " .. ev.p.member .. " " .. resultText(ev.p)
            end
            return resultText(ev.p)
        end },
    ENEMY_NOTE = { cat = "pvp", icon = "Interface\\Icons\\INV_Misc_Note_02", importance = 1,
        text = function(ev)
            if ev.p.nickname then return "surnomme " .. tostring(ev.p.name) .. " « " .. ev.p.nickname .. " »" end
            return "annote la fiche de " .. tostring(ev.p.name)
        end },
    WANTED = { cat = "pvp", icon = "Interface\\Icons\\INV_Misc_Note_06", importance = 3,
        text = function(ev) return "placarde un avis de recherche contre " .. tostring(ev.p.name) end },
    WANTED_CLOSE = { cat = "pvp", icon = "Interface\\Icons\\INV_Misc_Note_06", importance = 2,
        text = function(ev) return "lève l'avis de recherche contre " .. tostring(ev.p.name) end },
    ARTICLE = { cat = "gazette", icon = "Interface\\Icons\\INV_Misc_Note_06", importance = 3,
        text = function(ev) return "publie dans la gazette : « " .. tostring(ev.p.title) .. " »" end },
    VOTE = { cat = "gazette", icon = "Interface\\Icons\\INV_Misc_Coin_01", importance = 0, hidden = true,
        text = function() return "vote pour la une" end },
    AI_CONSENT = { cat = "gazette", icon = "Interface\\Icons\\INV_Misc_Note_06", importance = 0, hidden = true,
        text = function(ev)
            return ev.p.ok and "accepte que la gazette IA parle de lui/elle" or "refuse que la gazette IA parle de lui/elle"
        end },
    DEATH_CAUSE = { cat = "combat", icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01", importance = 1, hidden = true,
        text = function(ev)
            return ("rapporte, d'après son journal de combat, la mort de %s : %s"):format(
                tostring(ev.p.victim), tostring(ev.p.cause))
        end },
    LETTER = { cat = "anecdote", icon = "Interface\\Icons\\INV_Letter_15", importance = 1,
        text = function(ev) return "écrit au courrier des lecteurs : « " .. tostring(ev.p.title) .. " »" end },
}
Types.TYPES = TYPES

local UNKNOWN = { cat = "social", icon = "Interface\\Icons\\INV_Misc_QuestionMark", importance = 0,
    text = function(ev) return "événement inconnu (" .. tostring(ev.k) .. ")" end }

function Types.Get(kind) return TYPES[kind] or UNKNOWN end

function Types.CategoryLabel(key)
    for _, c in ipairs(Types.CATEGORIES) do if c.key == key then return c.label end end
    return key
end

-- Raw text, without subject: "atteint le niveau 20".
function Types.Raw(ev)
    local def = Types.Get(ev.k)
    local ok, text = pcall(def.text, ev)
    if not ok or type(text) ~= "string" then text = "événement illisible (" .. tostring(ev.k) .. ")" end
    return text
end

-- Descriptive sentence. withName: "Brisépée atteint le niveau 20"; otherwise "Atteint le niveau 20".
function Types.Describe(ev, withName)
    local text = Types.Raw(ev)
    if withName then return (ev.n or "?") .. " " .. text end
    return (text:gsub("^%l", string.upper))
end

function Types.Zone(ev) return zoneOf(ev) end
