-- Core/Settings.lua : SavedVariables, valeurs par defaut, version de schema.
--   GuildChronicleDB      (compte)      : donnees partagees entre personnages
--   GuildChronicleCharDB  (personnage)  : reglages du personnage
local _, ns = ...

local Settings = {}
ns.Settings = Settings

Settings.SCHEMA = 1

local ACCOUNT_DEFAULTS = {
    schema = 1,
    voiceDuck = {},   -- volume SFX a restaurer si le jeu a quitte pendant un ducking
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
        families = {
            startFight = true, endFight = true, death = true,
            fightGeneric = true, fightTank = true, fightHealer = true, fightDPS = true,
            fightMelee = true, fightCaster = true, fightRanged = true,
        },
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
    GuildChronicleDB = type(GuildChronicleDB) == "table" and GuildChronicleDB or {}
    GuildChronicleCharDB = type(GuildChronicleCharDB) == "table" and GuildChronicleCharDB or {}
    migrate(GuildChronicleDB)
    migrate(GuildChronicleCharDB)
    applyDefaults(GuildChronicleDB, ACCOUNT_DEFAULTS)
    applyDefaults(GuildChronicleCharDB, CHAR_DEFAULTS)
    ns.db = GuildChronicleDB
    ns.char = GuildChronicleCharDB
end
