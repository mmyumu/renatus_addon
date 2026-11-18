-- Core/Settings.lua : SavedVariables, valeurs par defaut, version de schema.
--   RenatusDB      (compte)      : donnees partagees entre personnages
--   RenatusCharDB  (personnage)  : reglages du personnage
local _, ns = ...

local Settings = {}
ns.Settings = Settings

Settings.SCHEMA = 1

local ACCOUNT_DEFAULTS = {
    schema = 1,
    voiceDuck = {},   -- volume SFX a restaurer si le jeu a quitte pendant un ducking
    events = {},      -- [id] = evenement (tous personnages du compte + recus plus tard par la synchro)
    seq = {},         -- [guid] = { public = n, private = n }
    articles = {},    -- (obsolete : les articles sont des evenements ARTICLE)
    pressDone = {},   -- [id] = "published" | "ignored" : elements du compagnon deja traites
    collection = {},  -- album : [cardId] = nombre d'exemplaires
}

local CHAR_DEFAULTS = {
    schema = 1,
    voice = {
        -- Renacoach est une option "pour la blague" : desactive par defaut.
        enabled = false,
        probability = 0.5,   -- valeurs d'origine de Renacoach
        interval = 3,
        channel = "Ambience",
        duck = true,
        duckVolume = 0.25,
        roleOverride = "AUTO",   -- AUTO, TANK, HEALER, DAMAGER
        typeOverride = "AUTO",   -- AUTO, melee, caster, ranged
        families = {
            startFight = true, endFight = true, death = true,
            fightGeneric = true, fightTank = true, fightHealer = true, fightDPS = true,
            fightMelee = true, fightCaster = true, fightRanged = true,
        },
    },
    -- Confidentialite par categorie : "OFF" (non enregistre), "P" (prive), "G" (guilde).
    -- "G" : partage avec les membres de la guilde equipes de l'addon (synchronisation).
    privacy = {
        progression = "P", combat = "P", exploration = "P", social = "P", pvp = "P", anecdote = "P", gazette = "P",
    },
    exportConsent = false,   -- export hors jeu (compagnon / LLM), consentement distinct
    rivalGuild = "",         -- nom de la guilde rivale (Wanted Board)
    albumOptOut = false,     -- ne pas apparaitre dans l'album des autres
    visitedMaps = {},        -- zones deja visitees (pour "premiere visite")
    enemySeenAt = {},        -- [nom] = derniere observation enregistree (limite de frequence)
    expSeq = 0,              -- compteur local des expeditions
    -- expedition = nil      -- expedition en cours (Collectors/Expedition.lua)
    ui = {
        tab = "journal",
        showMinimap = true,
        minimapAngle = 200,
        demo = false,
    },
}

-- Copie profonde des valeurs par defaut manquantes, sans ecraser l'existant.
local function applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            applyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end
Settings.applyDefaults = applyDefaults

-- Migrations : MIGRATIONS[n] fait passer une table du schema n-1 au schema n.
local MIGRATIONS = {}

local function migrate(db)
    db.schema = db.schema or Settings.SCHEMA
    while db.schema < Settings.SCHEMA do
        local step = MIGRATIONS[db.schema + 1]
        if step then step(db) end
        db.schema = db.schema + 1
    end
end

function Settings:Load()
    RenatusDB = type(RenatusDB) == "table" and RenatusDB or {}
    RenatusCharDB = type(RenatusCharDB) == "table" and RenatusCharDB or {}
    migrate(RenatusDB)
    migrate(RenatusCharDB)
    applyDefaults(RenatusDB, ACCOUNT_DEFAULTS)
    applyDefaults(RenatusCharDB, CHAR_DEFAULTS)
    ns.db = RenatusDB
    ns.char = RenatusCharDB
end
