-- Core/Settings.lua: SavedVariables, defaults, schema version.
--   RenatusDB      (account)    : data shared between characters
--   RenatusCharDB  (character)  : character settings
local _, ns = ...

local Settings = {}
ns.Settings = Settings

Settings.SCHEMA = 2

local ACCOUNT_DEFAULTS = {
    schema = 2,
    voiceDuck = {},   -- SFX volume to restore if the game exited during ducking
    events = {},      -- [id] = event (all characters of the account + received later through sync)
    seq = {},         -- [guid] = { public = n, private = n }
    articles = {},    -- (obsolete: articles are ARTICLE events)
    pressDone = {},   -- [id] = "published" | "ignored": companion items already handled
    collection = {},  -- album: [cardId] = number of copies
    tombstones = {},  -- [deleted event id] = author GUID (deletion received before the event)
    played = {},      -- [guid] = { ["YYYY-MM-DD"] = true }: days played (1 booster each)
    -- Local health data, never broadcast; read by Renatus Admin's "Suivi" tab:
    -- peers[name] = { first, seen, proto, ver }, sync = { received, rejected, lastReject, lastRejectAt },
    -- roster = { at, members = { { name, rank, level, class, guid } } },
    -- trace = { on, entries }: sync debugging trace (/renatus sync trace), off by default
    monitor = { peers = {}, sync = {}, trace = { on = false, entries = {} } },
}

local CHAR_DEFAULTS = {
    schema = 2,
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
        -- lastHeard = nil       -- last line heard in game, replayed by the "Tester" button
        families = {
            startFight = true, endFight = true, death = true,
            fightGeneric = true, fightTank = true, fightHealer = true, fightDPS = true,
            fightMelee = true, fightCaster = true, fightRanged = true,
        },
    },
    -- Privacy per category: "OFF" (not recorded), "P" (private), "G" (guild).
    -- "G": shared with guild members who have the addon (sync). Sharing is the point of the
    -- addon, so it is the default; each member can make a category private or turn it off.
    privacy = {
        progression = "G", combat = "G", exploration = "G", social = "G", pvp = "G", anecdote = "G", gazette = "G", album = "G",
    },
    exportConsent = true,    -- AI gazette may talk about me (on by default, can be unticked)
    consentChosen = false,   -- the member ticked or unticked it themselves
    rivalGuild = "",         -- legacy per-character rival guild (before GUILD_CONFIG); read-only fallback
    albumOptOut = false,     -- do not appear in other people's album
    visitedMaps = {},        -- zones already visited (for "first visit")
    mobsKilled = {},         -- [npc id] = true: creatures already recorded (Collectors/Kills.lua)
    itemsSeen = {},          -- [item id] = true: rare items already recorded (Collectors/Loot.lua)
    enemySeenAt = {},        -- [name] = last recorded observation (rate limit)
    expSeq = 0,              -- local expedition counter
    -- expedition = nil      -- current expedition (Collectors/Expedition.lua)
    ui = {
        tab = "gazette",
        showMinimap = true,
        minimapAngle = 200,
        showWidget = true,       -- gazette icon with notices (UI/Notifier.lua)
        -- widgetPoint = nil     -- its position
        -- gazetteSeen = nil     -- time of the latest article read
        -- lettersRead = nil     -- [letter event id] = true: readers' letters already read
        -- specialsRead = nil    -- [special issue key] = true: special issues already opened
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

-- 2: privacy defaults to "G". Characters still on the old default "P" switch to "G"
-- ("OFF" was necessarily chosen and is kept); they are told once at load.
MIGRATIONS[2] = function(db)
    if type(db.privacy) ~= "table" then return end
    local changed = false
    for cat, mode in pairs(db.privacy) do
        if mode == "P" then db.privacy[cat] = "G"; changed = true end
    end
    if changed then Settings.privacyNowShared = true end
end

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
    if Settings.privacyNowShared then
        ns.Print("tes événements sont désormais partagés avec la guilde par défaut. "
            .. "Pour garder une catégorie pour toi : Échap > Options > AddOns > Renatus.")
    end
end
