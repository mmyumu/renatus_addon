-- Core/Store.lua: creation, deduplication and storage of events; game context.
-- The active dataset is either the real one (SavedVariables) or the demo (memory only).
local _, ns = ...

local Store = {}
ns.Store = Store

------------------------------------------------------------------------
-- "Secret" values (Midnight / Forever restrictions): never stored.
------------------------------------------------------------------------
function ns.Safe(v)
    if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
    return v
end

local function pack(...) return { n = select("#", ...), ... } end

-- Protected call: nil if the function is missing or fails; secret values -> nil.
local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local res = pack(pcall(fn, ...))
    if not res[1] then return nil end
    for i = 2, res.n do res[i] = ns.Safe(res[i]) end
    return unpack(res, 2, res.n)
end
ns.Try = try

------------------------------------------------------------------------
-- Context: who, where, with whom
------------------------------------------------------------------------
local Context = {}
ns.Context = Context

function Context.Me()
    local guid = try(UnitGUID, "player") or "Player-0-UNKNOWN"
    local name = try(UnitName, "player") or "?"
    local _, class = try(UnitClass, "player")
    return guid, name, class
end

local function nonEmpty(s) return type(s) == "string" and s ~= "" and s or nil end

-- Realm of the player. The game sometimes answers "" (seen on WoW Forever since
-- 2026-11-20): the last realm seen is then used, so keys stay the same.
function Context.Realm()
    local realm = nonEmpty(try(GetNormalizedRealmName)) or nonEmpty(try(GetRealmName))
    if realm and ns.db then ns.db.realm = realm end
    return realm or (ns.db and nonEmpty(ns.db.realm)) or ""
end

function Context.GuildKey()
    if not try(IsInGuild) then return nil end
    local guildName = try(GetGuildInfo, "player")
    if not guildName then return nil end
    return guildName .. "-" .. Context.Realm(), guildName
end

-- Do two guild keys ("Name-Realm") designate the same guild? Same name, and same realm
-- or one of them without realm (keys written while the game gave an empty realm).
-- Guild names cannot contain "-": the first one separates the realm.
function Context.SameGuild(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if a == b then return true end
    local na, ra = a:match("^([^%-]*)%-(.*)$")
    local nb, rb = b:match("^([^%-]*)%-(.*)$")
    if not na or not nb or na ~= nb then return false end
    return ra == "" or rb == ""
end

function Context.Location()
    local loc = {}
    loc.z = try(GetRealZoneText) or try(GetZoneText)
    local sub = try(GetSubZoneText)
    if sub and sub ~= "" and sub ~= loc.z then loc.sz = sub end
    local inInstance = try(IsInInstance)
    if inInstance then
        local name, instanceType, difficultyID, _, _, _, _, instanceID = try(GetInstanceInfo)
        loc.i, loc.it, loc.iid, loc.d = name, instanceType, instanceID, difficultyID
    end
    if C_Map then
        local mapID = try(C_Map.GetBestMapForUnit, "player")
        loc.m = mapID
        -- Coordinates: only outside instances (the API does not provide them inside).
        if mapID and not inInstance and C_Map.GetPlayerMapPosition then
            local pos = try(C_Map.GetPlayerMapPosition, mapID, "player")
            if pos and pos.GetXY then
                local ok, x, y = pcall(pos.GetXY, pos)
                if ok and ns.Safe(x) and ns.Safe(y) then
                    loc.xy = { math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5) }
                end
            end
        end
    end
    return loc
end

-- Observed group members (never invented): { { g = guid, n = name }, ... }
function Context.Participants()
    local list = {}
    local prefix, count
    if try(IsInRaid) then prefix, count = "raid", try(GetNumGroupMembers) or 0
    elseif try(IsInGroup) then prefix, count = "party", (try(GetNumGroupMembers) or 1) - 1
    else return nil end
    for i = 1, count do
        local unit = prefix .. i
        local guid, name = try(UnitGUID, unit), try(UnitName, unit)
        if guid and name then table.insert(list, { g = guid, n = name }) end
    end
    return #list > 0 and list or nil
end

------------------------------------------------------------------------
-- Real storage
------------------------------------------------------------------------
local cache -- sorted list (most recent first), invalidated on every insert
local demoSeq = 0 -- ids of events added in demo mode (never saved)

local function nextSeq(guid, public)
    local seq = ns.db.seq[guid] or { public = 0, private = 0 }
    ns.db.seq[guid] = seq
    if public then seq.public = seq.public + 1; return seq.public end
    seq.private = seq.private + 1
    return seq.private
end

-- Builds an event (without storing it). opts: prov, miss, refs, occ, x, pt, loc, t, vis, ded
-- (ded = list of payload fields that are deduced rather than observed, e.g. { "enemies" })
function Store.Build(kind, payload, opts)
    opts = opts or {}
    local def = ns.Types.Get(kind)
    local mode = ns.char.privacy[def.cat] or "P"
    -- opts.vis = "G": explicit publication (article, vote...), regardless of the category setting.
    if opts.vis == "G" then mode = "G" end
    -- opts.keep: always recorded (at least privately), e.g. booster openings.
    if mode == "OFF" and opts.keep then mode = "P" end
    if mode == "OFF" then return nil end
    local guid, name, class = Context.Me()
    local public = (mode == "G")
    local s, id
    if opts.demo then
        -- Demo mode: never consume a real sequence number (the sync would see a gap)
        -- nor reuse an id of the demo dataset.
        demoSeq = demoSeq + 1
        id = guid .. ":demo" .. demoSeq
    else
        s = nextSeq(guid, public)
        id = public and (guid .. ":" .. s) or (guid .. ":p" .. s)
    end
    local ev = {
        v = 1,
        id = id,
        a = guid, n = name, c = class,
        s = public and s or nil,
        t = opts.t or (GetServerTime and GetServerTime()) or time(),
        k = kind,
        g = Context.GuildKey(),
        loc = opts.loc or Context.Location(),
        pt = opts.pt, prov = opts.prov or "OBS", miss = opts.miss, refs = opts.refs,
        occ = opts.occ, ded = opts.ded,
        x = opts.x or (not opts.noExp and ns.Expedition and ns.Expedition.CurrentKey and ns.Expedition:CurrentKey()) or nil,
        vis = public and "G" or "P",
        src = (opts.prov == "MAN") and "M" or "A",
        p = payload or {},
    }
    return ev
end

------------------------------------------------------------------------
-- Deletion (tombstones, docs/ARCHITECTURE.md §3.1): an author may delete
-- their own events. A shared event is emptied but kept (the sequence must
-- stay contiguous for the sync) and a TOMBSTONE event tells the others.
------------------------------------------------------------------------
-- Keeps only what the sync needs to know the event existed.
local KEEP = { v = true, id = true, a = true, n = true, s = true, t = true, k = true, g = true, vis = true }
local function strip(ev)
    for k in pairs(ev) do if not KEEP[k] then ev[k] = nil end end
    ev.p = {}
    ev.del = true
end

-- TOMBSTONE: empties the target if it belongs to the same author.
local function applyTombstone(tomb)
    local id = tomb.refs and tomb.refs[1]
    if type(id) ~= "string" then return end
    local target = ns.db.events[id]
    if target then
        if target.a == tomb.a then strip(target) end
    else
        ns.db.tombstones[id] = tomb.a   -- the event may arrive later
    end
end

-- Inserts an already built event (local or received). Returns false on duplicate.
function Store.Insert(ev)
    if not ev or not ev.id or ns.db.events[ev.id] then return false end
    if ev.k == "TOMBSTONE" then applyTombstone(ev)
    elseif ns.db.tombstones[ev.id] == ev.a then strip(ev); ns.db.tombstones[ev.id] = nil end
    ns.db.events[ev.id] = ev
    cache = nil
    ns.EventBus.Publish("CHRONICLE_EVENT", ev)
    return true
end

-- Shortcut for collectors: build + insert into the real dataset.
function Store.Add(kind, payload, opts)
    local ev = Store.Build(kind, payload, opts)
    if ev and Store.Insert(ev) then return ev end
    return nil
end

-- For forms: adds to the active dataset (demo or real).
function Store.AddManual(kind, payload, opts)
    opts = opts or {}
    opts.prov = opts.prov or "MAN"
    if ns.char.ui.demo then
        opts.demo = true
        local ev = Store.Build(kind, payload, opts)
        if ev then ns.Demo:Insert(ev) end
        return ev
    end
    return Store.Add(kind, payload, opts)
end

local function realEvents()
    if not cache then
        cache = {}
        for _, ev in pairs(ns.db.events) do
            if not ev.del then table.insert(cache, ev) end
        end
        table.sort(cache, function(a, b)
            if a.t ~= b.t then return a.t > b.t end
            return a.id > b.id
        end)
    end
    return cache
end

-- Active dataset, same shape in demo and real mode.
function Store.Dataset()
    if ns.char.ui.demo then return ns.Demo:Get() end
    local guid = Context.Me()
    local events = realEvents()
    local ds = {
        isDemo = false,
        me = guid,
        guildKey = Context.GuildKey(),
        events = events,
        articles = ns.Views.Articles(events),
        layouts = ns.Views.Layouts(events),
        causes = ns.Views.DeathCauses(events),
        collection = nil,   -- filled below from BOOSTER_OPEN events
        boosters = 0,
        founders = {},
        legends = {},
        roster = Store.Roster(),
        rival = ns.GuildConfig.Rival(),
        huntSince = ns.GuildConfig.HuntSince(),
    }
    -- Corrections of published articles need the roster (who is an officer).
    ds.articles = ns.Views.Revise(ds, ds.articles)
    local rivalRoster = ns.GuildConfig.Roster()
    ds.rivalRoster = rivalRoster and rivalRoster.p or nil
    -- Card profiles: portraits, and members who asked not to be in the others' album.
    ds.profiles = ns.Views.Profiles(events)
    ds.optOut = {}
    for author, p in pairs(ds.profiles) do
        if p.optOut and author ~= guid then ds.optOut[author] = true end
    end
    local opened, collection = ns.Album.Opened(events, guid)
    ds.trades = ns.Trade.Replay(events)
    ds.collection = ns.Trade.Apply(collection, ds.trades, guid)
    ds.boostersOpened = opened
    ds.boosters = math.max(0, ns.Album.Earned(events, guid, ns.db.played[guid],
        ns.GuildConfig.BoosterRules()) - opened)
    return ds
end

-- Today counts as a day played (one booster), whatever is recorded.
function Store.MarkPlayed()
    local guid = Context.Me()
    if not guid or guid == "Player-0-UNKNOWN" then return end
    ns.db.played[guid] = ns.db.played[guid] or {}
    ns.db.played[guid][ns.Album.DayKey(GetServerTime and GetServerTime() or time())] = true
end

-- Own events entered by hand can be deleted (anecdotes, notes, declarations...).
function Store.CanDelete(ev)
    if type(ev) ~= "table" or ev.del or ev.prov ~= "MAN" then return false end
    if ns.Types.Get(ev.k).hidden then return false end
    return ev.a == Store.Dataset().me
end

function Store.Delete(id)
    local ds = Store.Dataset()
    if ds.isDemo then
        for i, ev in ipairs(ds.events) do
            if ev.id == id and Store.CanDelete(ev) then
                table.remove(ds.events, i)
                ns.EventBus.Publish("CHRONICLE_EVENT", ev)
                return true
            end
        end
        return false
    end
    local ev = ns.db.events[id]
    if not Store.CanDelete(ev) then return false end
    if ev.vis ~= "G" then
        -- Private: never left this client, simply removed.
        ns.db.events[id] = nil
        cache = nil
        ns.EventBus.Publish("CHRONICLE_EVENT", ev)
        return true
    end
    local tomb = Store.Build("TOMBSTONE", {}, { vis = "G", prov = "MAN", refs = { id }, noExp = true, loc = {} })
    return Store.Insert(tomb) and true or false
end

-- Officer tool (Renatus_Admin, "Remise à zéro"): removes every own event that `keep`
-- selects (a kind set { ARTICLE = true, ... } or a function(ev)), for everyone: shared ones
-- are emptied by a tombstone, private ones simply dropped. Returns the number removed.
function Store.RetractOwn(kinds)
    local wanted = type(kinds) == "function" and kinds or function(ev) return kinds[ev.k] end
    if Store.Dataset().isDemo then return 0 end
    local me = Context.Me()
    local ids = {}
    for id, ev in pairs(ns.db.events) do
        if ev.a == me and not ev.del and ev.k ~= "TOMBSTONE" and wanted(ev) then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local ev = ns.db.events[id]
        if ev.vis ~= "G" then
            ns.db.events[id] = nil
        else
            Store.Insert(Store.Build("TOMBSTONE", {}, { vis = "G", prov = "MAN", refs = { id }, noExp = true, loc = {} }))
        end
    end
    cache = nil
    if #ids > 0 then ns.EventBus.Publish("CHRONICLE_EVENT", { k = "TOMBSTONE" }) end
    return #ids
end

------------------------------------------------------------------------
-- Visibility of an existing event. An id carries its visibility (guid:n is in the
-- public sequence, guid:pn is not), so changing it means a copy under a new id:
--   private -> guild : public copy (next public sequence number), private one removed;
--   guild -> private : private copy, and a TOMBSTONE empties the shared one everywhere.
-- Date, place, payload and provenance are kept.
------------------------------------------------------------------------
local COPIED = { "t", "k", "g", "loc", "pt", "prov", "miss", "refs", "occ", "ded", "x", "src", "p" }

local function ownVisible(ev)
    return type(ev) == "table" and not ev.del and ev.a == Context.Me()
        and not ns.Types.Get(ev.k).hidden and ev.prov ~= "GEN" and ev.prov ~= "EXT"
end

function Store.CanShare(ev) return ownVisible(ev) and ev.vis ~= "G" end
function Store.CanMakePrivate(ev) return ownVisible(ev) and ev.vis == "G" end

local function copyAs(ev, public)
    local guid = Context.Me()
    local s = nextSeq(guid, public)
    local copy = { v = 1, a = ev.a, n = ev.n, c = ev.c, vis = public and "G" or "P", s = public and s or nil,
        id = public and (guid .. ":" .. s) or (guid .. ":p" .. s) }
    for _, f in ipairs(COPIED) do copy[f] = ev[f] end
    return copy
end

-- Local references (refs) to the old id follow the copy.
local function remap(old, new)
    for _, e in pairs(ns.db.events) do
        for i, r in ipairs(type(e.refs) == "table" and e.refs or {}) do
            if r == old then e.refs[i] = new end
        end
    end
end

-- Returns the new event, or nil.
function Store.Share(id)
    if Store.Dataset().isDemo then return nil end
    local ev = ns.db.events[id]
    if not Store.CanShare(ev) then return nil end
    local copy = copyAs(ev, true)
    ns.db.events[id] = nil
    remap(id, copy.id)
    Store.Insert(copy)
    return copy
end

function Store.MakePrivate(id)
    if Store.Dataset().isDemo then return nil end
    local ev = ns.db.events[id]
    if not Store.CanMakePrivate(ev) then return nil end
    local copy = copyAs(ev, false)
    remap(id, copy.id)
    Store.Insert(copy)
    Store.Insert(Store.Build("TOMBSTONE", {}, { vis = "G", prov = "MAN", refs = { id }, noExp = true, loc = {} }))
    return copy
end

-- Shares the current character's past private events of the categories set to "Guilde",
-- oldest first. Returns how many.
function Store.SharePast()
    if Store.Dataset().isDemo then return 0 end
    local list = {}
    for _, ev in pairs(ns.db.events) do
        if Store.CanShare(ev) and ns.char.privacy[ns.Types.Get(ev.k).cat] == "G" then list[#list + 1] = ev end
    end
    table.sort(list, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.id < b.id end)
    for _, ev in ipairs(list) do Store.Share(ev.id) end
    return #list
end

-- Guild roster (members without the addon included, no statistics).
-- The client only fills the guild roster once someone asks for it (guild window,
-- or this request); GUILD_ROSTER_UPDATE follows. Throttled: at most every 10 s.
local lastRosterRequest
function Store.RequestRoster()
    local now = time()
    if lastRosterRequest and now - lastRosterRequest < 10 then return end
    if not try(IsInGuild) then return end
    lastRosterRequest = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then try(C_GuildInfo.GuildRoster)
    elseif GuildRoster then try(GuildRoster) end
end

function Store.Roster()
    local roster = {}
    local n = try(GetNumGuildMembers)
    if not n or n == 0 then
        Store.RequestRoster()
        return roster
    end
    for i = 1, n do
        local name, _, rankIndex, level, _, _, _, _, online, _, class, _, _, _, _, _, guid = try(GetGuildRosterInfo, i)
        if name then
            name = name:gsub("%-.*$", "")
            table.insert(roster, { name = name, first = name:match("^(%S+)"), rank = rankIndex, level = level,
                class = class, online = online, guid = type(guid) == "string" and guid or nil })
        end
    end
    Store.SnapshotRoster(roster)
    return roster
end

-- Snapshot of the guild roster for Renatus Admin's monitoring (local, at most every 10 min).
function Store.SnapshotRoster(roster)
    local mon = ns.db and ns.db.monitor
    if not mon or #roster == 0 then return end
    local now = (GetServerTime and GetServerTime()) or time()
    if mon.roster and now - (mon.roster.at or 0) < 600 then return end
    local members = {}
    for _, m in ipairs(roster) do
        members[#members + 1] = { name = m.name, rank = m.rank, level = m.level, class = m.class, guid = m.guid }
    end
    mon.roster = { at = now, members = members }
end

-- Name to display for an event author: the roster's full name on WoW Forever
-- ("Dakey Dak" for "Dakey"), the recorded name otherwise. Cached until the roster changes.
local nameCache
function Store.InvalidateNames() nameCache = nil end
function Store.DisplayName(guid, name)
    if not nameCache then
        local roster = Store.Roster()
        if #roster == 0 then return name end
        nameCache = { roster = roster, byKey = {} }
    end
    local key = tostring(guid) .. "|" .. tostring(name)
    local hit = nameCache.byKey[key]
    if hit == nil then
        local m = Store.FindInRoster(nameCache.roster, guid, name)
        hit = m and m.name or false
        nameCache.byKey[key] = hit
    end
    return hit or name
end

-- Roster entry of a character. On WoW Forever characters have a first and a last name:
-- the roster says "Dakey Dak" while UnitName and events say "Dakey". The GUID settles it
-- when the client gives one; otherwise the exact name, then the first name.
function Store.FindInRoster(roster, guid, name)
    if guid and roster[1] and roster[1].guid then
        -- The client gives GUIDs: they alone count (no impersonation by first name).
        for _, m in ipairs(roster) do if m.guid == guid then return m end end
        return nil
    end
    if type(name) ~= "string" then return nil end
    name = name:gsub("%-.*$", "")
    for _, m in ipairs(roster) do if m.name == name then return m end end
    local first = name:lower()
    for _, m in ipairs(roster) do if m.first and m.first:lower() == first then return m end end
    return nil
end

function Store.Count()
    local n = 0
    for _ in pairs(ns.db.events) do n = n + 1 end
    return n
end
