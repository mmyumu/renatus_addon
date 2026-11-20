-- Core/GuildConfig.lua: guild-wide settings, published by an officer (docs §7.3).
--
-- A GUILD_CONFIG event is an ordinary shared event (always "G") whose payload is the
-- whole configuration: { rival = "Guild name" }. It travels with the sync like any
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

local cache -- { config = event or false }, invalidated by new events and roster updates

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

-- The GUILD_CONFIG event in force (or nil).
function GuildConfig.Current()
    if cache then return cache.config or nil end
    local guildKey = ns.Context.GuildKey()
    local best
    for _, ev in pairs(ns.db.events) do
        if ev.k == "GUILD_CONFIG" and ev.vis == "G" and not ev.del and ev.g == guildKey
            and type(ev.p) == "table" and GuildConfig.IsOfficerRank(rankOf(ev.n, ev.a))
            and (not best or ev.t > best.t or (ev.t == best.t and ev.id > best.id)) then
            best = ev
        end
    end
    -- An empty roster usually means it is not loaded yet: do not cache that answer.
    if #ns.Store.Roster() > 0 then cache = { config = best or false } end
    return best
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
            elseif ev.g ~= guildKey then why = ("autre guilde (%s)"):format(tostring(ev.g))
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

-- Publishes a new configuration (officers only). Fields left out are kept from the
-- configuration in force, so publishing { rival = "X" } does not reset the rest.
function GuildConfig.Publish(fields)
    if not GuildConfig.CanPublish() then return nil, "rang" end
    local payload = {}
    local cur = GuildConfig.Current()
    if cur then for k, v in pairs(cur.p) do payload[k] = v end end
    for k, v in pairs(fields or {}) do payload[k] = v end
    payload.rival = trim(payload.rival)
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
        if ev.k == "RIVAL_ROSTER" and ev.vis == "G" and not ev.del and ev.g == guildKey
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
    ns:RegisterGameEvent("GUILD_ROSTER_UPDATE", function() cache = nil end)
    -- Officer checks need the roster: ask for it now rather than wait for the guild window.
    ns.Store.RequestRoster()
end
