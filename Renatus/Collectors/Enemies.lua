-- Collectors/Enemies.lua: encounters with the rival guild (Wanted Board, docs §6.1).
--
-- Deliberate limits (ethics, docs §6.5):
--   - only characters of the rival guild configured in the settings;
--   - only what the game displays (name, realm, guild, level, race, class, location);
--   - at most one observation per enemy every 10 minutes: encounters, not tracking.
-- Sources: target, mouseover, nameplates. Secret values (instances) are ignored.
-- When the player dies, rivals seen in the last 30 seconds are recorded as
-- "present": a deduction (field flagged in ded), never "killed by".
-- Honorable kills (PVP_KILL, below): any enemy player, named like killers are.
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
-- needs to describe its victim (and the guild of whoever kills us). Never saved as such.
local hostile = {}  -- [name] = { t, level, race, class, className, guild }
Enemies.HOSTILE_TTL = 300

local function isHostile(unit)
    local enemy = try(UnitIsEnemy, "player", unit)
    if enemy ~= nil then return enemy end
    local mine, theirs = try(UnitFactionGroup, "player"), try(UnitFactionGroup, unit)
    return mine ~= nil and theirs ~= nil and mine ~= theirs
end

local function remember(unit, name, guild)
    if not isHostile(unit) then return nil end
    local level = try(UnitLevel, unit)
    local className, class = try(UnitClass, unit)
    hostile[name] = { t = now(), level = (level and level > 0) and level or nil, race = try(UnitRace, unit),
        class = class, className = className, guild = guild }
    return hostile[name]
end

-- Tells the alarm (UI/Alarm.lua) an enemy player or a rival is in view, on every sighting:
-- the alarm has its own rate limit.
local function spotted(unit, name, guild, info, isRival)
    if not (info or isRival) then return end
    if not info then
        local level = try(UnitLevel, unit)
        local className, class = try(UnitClass, unit)
        info = { level = (level and level > 0) and level or nil, class = class, className = className }
    end
    ns.EventBus.Publish("ENEMY_SPOTTED", { name = name, guild = guild, level = info.level, class = info.class,
        className = info.className, rival = isRival or nil })
end

function Enemies.Observe(unit)
    if not unit then return nil end
    if not try(UnitExists, unit) or not try(UnitIsPlayer, unit) then return nil end
    local name, realm = try(UnitName, unit)
    if not name or name == "" then return nil end
    local guild = try(GetGuildInfo, unit)
    local info = remember(unit, name, guild)
    local target = rival()
    local isRival = target ~= nil and guild ~= nil and string.lower(guild) == target
    spotted(unit, name, guild, info, isRival)
    if not isRival then return nil end
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

-- What was seen of an enemy player in the last minutes (any guild), or nil.
function Enemies.Known(name)
    if type(name) ~= "string" then return nil end
    local info = hostile[name] or hostile[name:match("^([^%-]+)") or name]
    if info and now() - info.t <= Enemies.HOSTILE_TTL then return info end
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
-- too): "a contribué", not "a tué". The victim is named like a killer is: a defeat names
-- whoever beat us, a victory names whoever we beat.
--
-- Several layers, so that no kill is lost (the message did not arrive on Forever on 22/11):
--   1. the chat message, read with every known format (with or without rank, honor...);
--      failing that, a recently seen enemy whose name starts the message;
--   2. the session kill counter (PLAYER_PVP_KILLS_CHANGED): each increase the messages do
--      not explain is a kill; its victim is a hostile player seen dead in the last seconds
--      (target, nameplates, group targets), else an unnamed kill (prov DED);
--   3. unrecognised messages are kept (ns.char.honorMisses) to fix the formats.
------------------------------------------------------------------------
local function escape(s) return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")) end

-- Pattern capturing the victim's name from a COMBATLOG_HONORGAIN-like format (any language).
function Enemies.HonorPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local head, rest = fmt:match("^(.-)%%s(.*)$")
    if not head then return nil end
    local literal = rest:match("^(.-)%%[sd]") or rest
    if literal == "" then return nil end
    return "^" .. escape(head) .. "(.-)" .. escape(literal)
end

-- Every honor format the client knows: with rank, without rank, with diminishing returns.
local HONOR_FORMATS = { "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK", "COMBATLOG_HONORGAIN_EXHAUSTION1",
    "COMBATLOG_HONORGAIN_EXHAUSTION2", "COMBATLOG_HONORGAIN_EXHAUSTION3", "COMBATLOG_HONORGAIN_EXHAUSTION4" }

function Enemies.HonorPatterns()
    local list, seen = {}, {}
    for _, key in ipairs(HONOR_FORMATS) do
        local pattern = Enemies.HonorPattern(_G[key])
        if pattern and not seen[pattern] then seen[pattern] = true; list[#list + 1] = pattern end
    end
    return list
end

-- The victim's name in an honor message, or nil.
function Enemies.VictimOf(msg)
    Enemies.honorPatterns = Enemies.honorPatterns or Enemies.HonorPatterns()
    for _, pattern in ipairs(Enemies.honorPatterns) do
        local name = msg:match(pattern)
        if name and name ~= "" then return name end
    end
    -- Unknown format: an enemy seen recently whose name starts the message (longest first).
    local best
    for name, info in pairs(hostile) do
        if now() - info.t <= Enemies.HOSTILE_TTL and msg:sub(1, #name) == name
            and not msg:sub(#name + 1, #name + 1):match("[%w\128-\255]") and (not best or #name > #best) then
            best = name
        end
    end
    return best
end

Enemies.DEAD_WINDOW = 15
local deadSeen = {}       -- [name] = time a hostile player was seen dead (memory only)
local lastKill = {}       -- [name] = time: the same kill is announced once
local credits = {}        -- times of recognised messages not yet matched with the counter
local owed = 0            -- counter increases not yet explained
local checkPending = false
local sessionKills

local function sessionCount()
    local hk = try(GetPVPSessionStats)
    return type(hk) == "number" and hk or nil
end

local function inBattleground()
    local inside, kind = try(IsInInstance)
    return inside and (kind == "pvp" or kind == "arena")
end

-- Units where a dead enemy can be seen.
local function watchedUnits()
    local list = { "target", "focus", "mouseover", "softenemy" }
    for i = 1, 40 do list[#list + 1] = "nameplate" .. i end
    for i = 1, 4 do list[#list + 1] = "party" .. i .. "target" end
    for i = 1, 40 do list[#list + 1] = "raid" .. i .. "target" end
    return list
end
local WATCHED = watchedUnits()

-- A hostile player shown dead on this unit: remembered as a possible victim.
function Enemies.CheckDead(unit)
    if not unit or not try(UnitExists, unit) or not try(UnitIsPlayer, unit) then return nil end
    if not try(UnitIsDeadOrGhost, unit) or not isHostile(unit) then return nil end
    local name = try(UnitName, unit)
    if not name or name == "" then return nil end
    remember(unit, name, try(GetGuildInfo, unit))
    deadSeen[name] = deadSeen[name] or now()
    return name
end

local function scanDead()
    for _, unit in ipairs(WATCHED) do Enemies.CheckDead(unit) end
end

-- Records a kill; name may be nil (kill counted by the game but not announced).
function Enemies.RecordKill(name, prov)
    if inBattleground() then return nil end -- battlegrounds: summed up by the expedition
    local t = now()
    if name then
        if lastKill[name] and t - lastKill[name] < 60 then return nil end
        lastKill[name] = t
        deadSeen[name] = nil
    end
    local info = name and hostile[name]
    if info and t - info.t > Enemies.HOSTILE_TTL then info = nil end
    -- Not seen around: maybe still the target.
    if name and not info and try(UnitName, "target") == name then
        Enemies.Observe("target")
        info = hostile[name]
    end
    local p = { name = name }
    if info then
        p.level, p.race, p.class, p.className, p.guild = info.level, info.race, info.class, info.className, info.guild
    end
    -- DED: the game counted a kill without naming the victim, or the victim was deduced.
    return ns.Store.Add("PVP_KILL", p, (prov or not name) and { prov = prov or "DED" } or nil)
end

-- Unrecognised honor messages, kept to adjust the formats (last 10, this character).
local function keepMiss(msg)
    local misses = ns.char.honorMisses or {}
    ns.char.honorMisses = misses
    table.insert(misses, 1, { t = now(), msg = msg:sub(1, 200) })
    while #misses > 10 do table.remove(misses) end
end

function Enemies.OnHonorMessage(msg)
    msg = ns.Safe(msg)
    if type(msg) ~= "string" then return nil end
    local name = Enemies.VictimOf(msg)
    if not name then keepMiss(msg) return nil end
    credits[#credits + 1] = now()
    return Enemies.RecordKill(name)
end

-- Counter increases the messages did not explain: victims seen dead, else unnamed.
local function settle()
    checkPending = false
    local t = now()
    local fresh = {}
    for _, at in ipairs(credits) do if t - at <= 10 then fresh[#fresh + 1] = at end end
    local explained = math.min(owed, #fresh)
    owed = math.min(owed - explained, 5)
    credits = {}
    if owed <= 0 then owed = 0 return end
    scanDead()
    local victims = {}
    for name, at in pairs(deadSeen) do
        if t - at <= Enemies.DEAD_WINDOW then victims[#victims + 1] = { name = name, t = at }
        else deadSeen[name] = nil end
    end
    table.sort(victims, function(a, b) return a.t > b.t end)
    for i = 1, owed do
        local v = victims[i]
        Enemies.RecordKill(v and v.name, v and "DED" or nil)
    end
    owed = 0
end

-- The session counter went up (or appeared).
function Enemies.OnKillsChanged()
    local count = sessionCount()
    if not count then return end
    local before = sessionKills
    sessionKills = count
    -- Counter unknown until now (not ready at login): at least one kill.
    local delta = before and count - before or (count > 0 and 1 or 0)
    if delta <= 0 then return end
    owed = owed + delta
    scanDead()
    if checkPending then return end
    checkPending = true
    if C_Timer then C_Timer.After(2, settle) else settle() end
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
    ns:RegisterGameEvent("PLAYER_ENTERING_WORLD", function() sessionKills = sessionKills or sessionCount() end)
    ns:RegisterGameEvent("CHAT_MSG_COMBAT_HONOR_GAIN", function(_, msg) Enemies.OnHonorMessage(msg) end)
    ns:RegisterGameEvent("PLAYER_PVP_KILLS_CHANGED", Enemies.OnKillsChanged)
    -- An enemy player dying on screen: remembered a few seconds as a possible victim.
    ns:RegisterGameEvent("UNIT_HEALTH", function(_, unit)
        unit = ns.Safe(unit)
        if type(unit) == "string" and unit ~= "player" and not unit:match("^party%d$") and not unit:match("^raid%d+$") then
            Enemies.CheckDead(unit)
        end
    end)
end
