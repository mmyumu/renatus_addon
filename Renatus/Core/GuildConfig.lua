-- Core/GuildConfig.lua: guild-wide settings, published by an officer (docs §7.3).
--
-- A GUILD_CONFIG event is an ordinary shared event (always "G") whose payload is the
-- whole configuration: { rival = "Guild name", boosters = { day, bonus, cap },
-- huntSince = time the Wanted Board starts from (fights before it are left out) }. It travels with the sync like any
-- other event. Every client decides on its own which one applies:
--   - its author must be, in the guild roster seen by this client, at rank
--     OFFICER_MAX_RANK or above (0 = guild master, 1 = the rank below, ...);
--   - among the valid ones, the most recent wins.
-- The check uses the current roster: an officer who is demoted no longer counts.
-- Members never edit these settings: the Renatus_Admin addon publishes them.
local _, ns = ...

local GuildConfig = ns:RegisterModule("GuildConfig", {})
ns.GuildConfig = GuildConfig

-- Highest rank index (0 = guild master) allowed to publish guild settings.
GuildConfig.OFFICER_MAX_RANK = 1

local cache -- { config = event or false, rules = list }, invalidated by new events and roster updates

local function trim(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end
GuildConfig.Trim = trim

-- Rank index of a guild member (nil if not in the roster), by GUID then name.
local function rankOf(name, guid)
    local m = ns.Store.FindInRoster(ns.Store.Roster(), guid, name)
    return m and m.rank
end
GuildConfig.RankOf = rankOf

function GuildConfig.IsOfficerRank(rank)
    return type(rank) == "number" and rank <= GuildConfig.OFFICER_MAX_RANK
end

-- Can the current character publish guild settings?
function GuildConfig.CanPublish()
    if not ns.Context.GuildKey() then return false end
    local _, _, rank = ns.Try(GetGuildInfo, "player")
    return GuildConfig.IsOfficerRank(rank)
end

-- Valid GUILD_CONFIG events (author of officer rank in the current roster), oldest first.
local function validConfigs()
    local guildKey = ns.Context.GuildKey()
    local list = {}
    for _, ev in pairs(ns.db.events) do
        if ev.k == "GUILD_CONFIG" and ev.vis == "G" and not ev.del and ns.Context.SameGuild(ev.g, guildKey)
            and type(ev.p) == "table" and GuildConfig.IsOfficerRank(rankOf(ev.n, ev.a)) then
            list[#list + 1] = ev
        end
    end
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.id < b.id
    end)
    return list
end

local function load()
    if cache then return cache end
    local list = validConfigs()
    -- Booster rules over time: each config carrying one starts it on its day.
    local rules = {}
    for _, ev in ipairs(list) do
        if type(ev.p.boosters) == "table" then
            local from = ns.Album.DayKey(ev.t)
            if rules[#rules] and rules[#rules].from == from then table.remove(rules) end
            rules[#rules + 1] = { from = from, rule = ns.Album.Rule(ev.p.boosters), ev = ev }
        end
    end
    local result = { config = list[#list] or false, rules = rules }
    -- An empty roster usually means it is not loaded yet: do not cache that answer.
    if #ns.Store.Roster() > 0 then cache = result end
    return result
end

-- The GUILD_CONFIG event in force (or nil).
function GuildConfig.Current()
    return load().config or nil
end

-- Booster rules published over time, for Album.Earned / Album.RuleOn.
function GuildConfig.BoosterRules()
    return load().rules
end

-- Booster rule in force today, and the event that set it (nil = default rule).
function GuildConfig.Boosters()
    local rules = load().rules
    local last = rules[#rules]
    if last then return last.rule, last.ev end
    return ns.Album.DEFAULT_RULE, nil
end

function GuildConfig.Invalidate() cache = nil end

-- Why each GUILD_CONFIG event counts or not (admin diagnostics). Returns text lines.
function GuildConfig.Diagnose()
    local lines = {}
    local guildKey = ns.Context.GuildKey()
    local roster = ns.Store.Roster()
    local _, _, myRank = ns.Try(GetGuildInfo, "player")
    local myGuid, me = ns.Context.Me()
    local mine = ns.Store.FindInRoster(roster, myGuid, me)
    table.insert(lines, ("Guilde : %s"):format(tostring(guildKey)))
    table.insert(lines, ("Liste de guilde : %d membre(s)%s"):format(#roster,
        #roster == 0 and " (pas encore reçue du jeu)" or ""))
    table.insert(lines, ("Ton rang (jeu) : %s  ·  dans la liste : %s (%s)"):format(tostring(myRank),
        tostring(mine and mine.rank), mine and mine.name or "introuvable"))
    local n = 0
    for _, ev in pairs(ns.db.events) do
        if ev.k == "GUILD_CONFIG" then
            n = n + 1
            local why
            if ev.vis ~= "G" then why = "non partagé"
            elseif ev.del then why = "supprimé"
            elseif not ns.Context.SameGuild(ev.g, guildKey) then why = ("autre guilde (%s)"):format(tostring(ev.g))
            elseif type(ev.p) ~= "table" then why = "contenu invalide"
            else
                local r = rankOf(ev.n, ev.a)
                if r == nil then why = ("%s absent de la liste de guilde"):format(tostring(ev.n))
                elseif not GuildConfig.IsOfficerRank(r) then why = ("%s est de rang %d"):format(tostring(ev.n), r)
                else why = "valable" end
            end
            table.insert(lines, ("<%s> par %s, %s : %s"):format(tostring(ev.p and ev.p.rival or "aucune"),
                tostring(ev.n), date("%d/%m %H:%M", ev.t or 0), why))
        end
    end
    if n == 0 then table.insert(lines, "Aucun réglage de guilde reçu.") end
    return lines
end

-- Rival guild name: the guild setting, otherwise the one this character entered
-- before guild settings existed (kept so nothing is lost on update).
function GuildConfig.Rival()
    local cfg = GuildConfig.Current()
    if cfg then return trim(cfg.p.rival) end
    return trim(ns.char.rivalGuild)
end

-- Start of the Wanted Board (fights before it are left out), or nil.
function GuildConfig.HuntSince()
    local cfg = GuildConfig.Current()
    local t = cfg and cfg.p.huntSince
    return type(t) == "number" and t or nil
end

-- Publishes a new configuration (officers only). Fields left out are kept from the
-- configuration in force, so publishing { rival = "X" } does not reset the rest.
-- { boosters = { day, bonus, cap } } applies from the day it is published on.
function GuildConfig.Publish(fields)
    if not GuildConfig.CanPublish() then return nil, "rang" end
    local payload = {}
    local cur = GuildConfig.Current()
    if cur then for k, v in pairs(cur.p) do payload[k] = v end end
    for k, v in pairs(fields or {}) do payload[k] = v end
    payload.rival = trim(payload.rival)
    if payload.boosters ~= nil then payload.boosters = ns.Album.Rule(payload.boosters) end
    if type(payload.huntSince) ~= "number" then payload.huntSince = nil end -- false: from the start
    local ev = ns.Store.Add("GUILD_CONFIG", payload, { vis = "G", prov = "MAN", noExp = true, loc = {} })
    GuildConfig.Invalidate()
    return ev
end

------------------------------------------------------------------------
-- Rival guild roster from the armory (RIVAL_ROSTER, provenance EXT)
------------------------------------------------------------------------
-- Published by an officer from the admin app: { guild, count, at, src,
-- members = { { n, lvl, rk, cl, ra, gs, il, ll }, ... } }. Only the latest one for the
-- rival guild in force counts; it must come from an officer, like GUILD_CONFIG.

function GuildConfig.Roster()
    local rival = GuildConfig.Rival()
    if not rival then return nil end
    rival = rival:lower()
    local guildKey = ns.Context.GuildKey()
    local best
    for _, ev in pairs(ns.db.events) do
        if ev.k == "RIVAL_ROSTER" and ev.vis == "G" and not ev.del and ns.Context.SameGuild(ev.g, guildKey)
            and type(ev.p) == "table" and type(ev.p.members) == "table"
            and type(ev.p.guild) == "string" and ev.p.guild:lower() == rival
            and GuildConfig.IsOfficerRank(rankOf(ev.n, ev.a))
            and (not best or (ev.p.at or ev.t) > (best.p.at or best.t)) then
            best = ev
        end
    end
    return best
end

-- Does an in-game name ("Ladou") designate an armory character ("Ladou Pipø")?
function GuildConfig.SameCharacter(gameName, armoryName)
    if type(gameName) ~= "string" or type(armoryName) ~= "string" or gameName == "" then return false end
    local g, a = gameName:lower(), armoryName:lower()
    return g == a or a:match("^(%S+)") == g
end

-- Armory entry of an enemy, and the roster event it comes from.
function GuildConfig.ArmoryInfo(name)
    local roster = GuildConfig.Roster()
    if not roster then return nil end
    for _, m in ipairs(roster.p.members) do
        if type(m) == "table" and GuildConfig.SameCharacter(name, m.n) then return m, roster end
    end
    return nil
end

function GuildConfig:OnLogin()
    ns.EventBus.Subscribe("CHRONICLE_EVENT", function(ev)
        if ev.k == "GUILD_CONFIG" then cache = nil end
    end)
    ns:RegisterGameEvent("GUILD_ROSTER_UPDATE", function() cache = nil; ns.Store.InvalidateNames() end)
    -- Officer checks need the roster: ask for it now rather than wait for the guild window.
    ns.Store.RequestRoster()
end
