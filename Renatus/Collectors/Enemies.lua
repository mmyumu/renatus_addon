-- Collectors/Enemies.lua: encounters with the rival guild (Wanted Board, docs §6.1).
--
-- Deliberate limits (ethics, docs §6.5):
--   - only characters of the rival guild configured in the settings;
--   - only what the game displays (name, realm, guild, level, race, class, location);
--   - at most one observation per enemy every 10 minutes: encounters, not tracking.
-- Sources: target, mouseover, nameplates. Secret values (instances) are ignored.
-- When the player dies, rivals seen in the last 30 seconds are recorded as
-- "present": a deduction (field flagged in ded), never "killed by".
-- Honorable kills (PVP_KILL, below): any enemy player, named only if in the rival guild.
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

-- Enemy players seen in the last minutes (any guild), in memory only: what an honorable kill
-- needs to describe its victim. Never saved; non-rivals are recorded without their name.
local hostile = {}  -- [name] = { t, level, race, class, className, guild }
Enemies.HOSTILE_TTL = 300

local function isHostile(unit)
    local enemy = try(UnitIsEnemy, "player", unit)
    if enemy ~= nil then return enemy end
    local mine, theirs = try(UnitFactionGroup, "player"), try(UnitFactionGroup, unit)
    return mine ~= nil and theirs ~= nil and mine ~= theirs
end

local function remember(unit, name, guild)
    if not isHostile(unit) then return end
    local level = try(UnitLevel, unit)
    local className, class = try(UnitClass, unit)
    hostile[name] = { t = now(), level = (level and level > 0) and level or nil, race = try(UnitRace, unit),
        class = class, className = className, guild = guild }
end

function Enemies.Observe(unit)
    if not unit then return nil end
    if not try(UnitExists, unit) or not try(UnitIsPlayer, unit) then return nil end
    local name, realm = try(UnitName, unit)
    if not name or name == "" then return nil end
    local guild = try(GetGuildInfo, unit)
    remember(unit, name, guild)
    local target = rival()
    if not target then return nil end
    if not guild or string.lower(guild) ~= target then return nil end
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

------------------------------------------------------------------------
-- Honorable kills (PVP_KILL). The game says "<name> meurt (victoire honorable : <rang>)"
-- for every enemy player killed with the player's participation (outside battlegrounds
-- too): "a contribué", not "a tué". The victim is named only if they belong to the rival
-- guild; anyone else is kept as race, class and level.
------------------------------------------------------------------------
local function escape(s) return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")) end

-- Pattern capturing the victim's name from COMBATLOG_HONORGAIN (any language).
function Enemies.HonorPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local head, rest = fmt:match("^(.-)%%s(.*)$")
    if not head then return nil end
    local literal = rest:match("^(.-)%%[sd]") or rest
    if literal == "" then return nil end
    return "^" .. escape(head) .. "(.-)" .. escape(literal)
end

local lastKill = {}      -- [name] = time: the same kill is announced once
local lastHonorMessage = -math.huge
local sessionKills

local function sessionCount()
    local hk = try(GetPVPSessionStats)
    return type(hk) == "number" and hk or nil
end

local function inBattleground()
    local inside, kind = try(IsInInstance)
    return inside and (kind == "pvp" or kind == "arena")
end

-- Records a kill; name may be nil (kill counted by the game but not announced).
function Enemies.RecordKill(name)
    if inBattleground() then return nil end -- battlegrounds: summed up by the expedition
    local t = now()
    if name then
        if lastKill[name] and t - lastKill[name] < 60 then return nil end
        lastKill[name] = t
    end
    local info = name and hostile[name]
    if info and t - info.t > Enemies.HOSTILE_TTL then info = nil end
    -- Not seen around: maybe still the target.
    if name and not info and try(UnitName, "target") == name then
        Enemies.Observe("target")
        info = hostile[name]
    end
    local target = rival()
    local p = {}
    if info then p.level, p.race, p.class, p.className = info.level, info.race, info.class, info.className end
    local isRival = info and info.guild and target and string.lower(info.guild) == target
    local opts
    if isRival then
        p.name, p.guild = name, info.guild
    elseif not name then
        opts = { prov = "DED" } -- the game counted a kill without saying whom
    end
    return ns.Store.Add("PVP_KILL", p, opts)
end

function Enemies.OnHonorMessage(msg)
    msg = ns.Safe(msg)
    if type(msg) ~= "string" then return nil end
    Enemies.honorPattern = Enemies.honorPattern or Enemies.HonorPattern(_G.COMBATLOG_HONORGAIN)
    local name = Enemies.honorPattern and msg:match(Enemies.honorPattern)
    if not name or name == "" then return nil end
    lastHonorMessage = now()
    sessionKills = sessionCount() or sessionKills
    return Enemies.RecordKill(name)
end

-- Fallback when the message never comes: the session counter went up.
function Enemies.OnKillsChanged()
    local count = sessionCount()
    if not count then return end
    local before = sessionKills
    sessionKills = count
    if not before or count <= before then return end
    local function check()
        if now() - lastHonorMessage <= 3 then return end
        for _ = 1, math.min(count - before, 5) do Enemies.RecordKill(nil) end
    end
    if C_Timer then C_Timer.After(2, check) else check() end
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
    sessionKills = sessionCount()
    ns:RegisterGameEvent("CHAT_MSG_COMBAT_HONOR_GAIN", function(_, msg) Enemies.OnHonorMessage(msg) end)
    ns:RegisterGameEvent("PLAYER_PVP_KILLS_CHANGED", Enemies.OnKillsChanged)
end
