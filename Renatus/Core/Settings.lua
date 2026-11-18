-- Core/Settings.lua: SavedVariables, defaults, schema version.
--   RenatusDB      (account)    : data shared between characters
--   RenatusCharDB  (character)  : character settings
local _, ns = ...

local Settings = {}
ns.Settings = Settings

Settings.SCHEMA = 1

local ACCOUNT_DEFAULTS = {
    schema = 1,
    voiceDuck = {},   -- SFX volume to restore if the game exited during ducking
    events = {},      -- [id] = event (all characters of the account + received later through sync)
    seq = {},         -- [guid] = { public = n, private = n }
    articles = {},    -- (obsolete: articles are ARTICLE events)
    pressDone = {},   -- [id] = "published" | "ignored": companion items already handled
    collection = {},  -- album: [cardId] = number of copies
}

local CHAR_DEFAULTS = {
    schema = 1,
    voice = {
        -- Renacoach is a "just for fun" option: disabled by default.
        enabled = false,
        probability = 0.5,   -- original Renacoach values
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
    -- Privacy per category: "OFF" (not recorded), "P" (private), "G" (guild).
    -- "G": shared with guild members who have the addon (sync).
    privacy = {
        progression = "P", combat = "P", exploration = "P", social = "P", pvp = "P", anecdote = "P", gazette = "P",
    },
    exportConsent = false,   -- off-game export (companion / LLM), separate consent
    rivalGuild = "",         -- rival guild name (Wanted Board)
    albumOptOut = false,     -- do not appear in other people's album
    visitedMaps = {},        -- zones already visited (for "first visit")
    enemySeenAt = {},        -- [name] = last recorded observation (rate limit)
    expSeq = 0,              -- local expedition counter
    -- expedition = nil      -- current expedition (Collectors/Expedition.lua)
    ui = {
        tab = "journal",
        showMinimap = true,
        minimapAngle = 200,
        demo = false,
    },
}

-- Deep copy of missing defaults, without overwriting existing values.
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

-- Migrations: MIGRATIONS[n] upgrades a table from schema n-1 to schema n.
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
