-- Collectors/Enemies.lua: encounters with the rival guild (Wanted Board, docs §6.1).
--
-- Deliberate limits (ethics, docs §6.5):
--   - only characters of the rival guild configured in the settings;
--   - only what the game displays (name, realm, guild, level, race, class, location);
--   - at most one observation per enemy every 10 minutes: encounters, not tracking.
-- Sources: target, mouseover, nameplates. Secret values (instances) are ignored.
-- When the player dies, rivals seen in the last 30 seconds are recorded as
-- "present": a deduction (field flagged in ded), never "killed by".
local _, ns = ...

local Enemies = ns:RegisterModule("CollectorEnemies", {})
ns.EnemyWatch = Enemies
local try = ns.Try

Enemies.COOLDOWN = 600
Enemies.PRESENT_WINDOW = 30

local recent = {}   -- [name] = time last seen (even if not recorded)

local function now() return (GetServerTime and GetServerTime()) or time() end

-- Rival guild: the guild setting published by an officer (Core/GuildConfig.lua).
local function rival()
    local r = ns.GuildConfig.Rival()
    return r and string.lower(r) or nil
end

function Enemies.Observe(unit)
    local target = rival()
    if not target or not unit then return nil end
    if not try(UnitExists, unit) or not try(UnitIsPlayer, unit) then return nil end
    local guild = try(GetGuildInfo, unit)
    if not guild or string.lower(guild) ~= target then return nil end
    local name, realm = try(UnitName, unit)
    if not name or name == "" then return nil end
    local t = now()
    recent[name] = t
    local seenAt = ns.char.enemySeenAt
    if seenAt[name] and t - seenAt[name] < Enemies.COOLDOWN then return nil end
    seenAt[name] = t
    local level = try(UnitLevel, unit)
    if level and level <= 0 then level = nil end -- "??": unknown level
    local race = try(UnitRace, unit)
    local _, class = try(UnitClass, unit)
    return ns.Store.Add("ENEMY_SEEN", {
        name = name, realm = (realm and realm ~= "") and realm or nil, guild = guild,
        level = level, race = race, class = class,
        pvp = try(UnitIsPVP, unit) or nil,
    })
end

-- Names of rivals seen recently (for the player's death).
function Enemies.RecentNames(window)
    window = window or Enemies.PRESENT_WINDOW
    local t, list = now(), {}
    for name, at in pairs(recent) do
        if t - at <= window then table.insert(list, name) end
    end
    table.sort(list)
    return list
end

-- Purge old timestamps (the table only serves as a rate limit).
local function purge()
    local t = now()
    for name, at in pairs(ns.char.enemySeenAt) do
        if t - at > 86400 then ns.char.enemySeenAt[name] = nil end
    end
end

function Enemies:OnLogin()
    purge()
    ns:RegisterGameEvent("PLAYER_TARGET_CHANGED", function() Enemies.Observe("target") end)
    ns:RegisterGameEvent("UPDATE_MOUSEOVER_UNIT", function() Enemies.Observe("mouseover") end)
    ns:RegisterGameEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Enemies.Observe(ns.Safe(unit)) end)
end
