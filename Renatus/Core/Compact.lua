-- Core/Compact.lua: old facts summed up by their author (BILAN), so the journal stops growing.
--
-- Every shared event stays in every member's SavedVariables, and a newcomer downloads
-- them all: measured on 2026-11-28, one week of journal was 3,000 events (1.7 MB), a year
-- would be 150,000 (and twice that with twice the members). So, past a number of days
-- (guild setting keepDays, GuildConfig.KeepDays), each author publishes a BILAN of their
-- own old facts and every client drops those facts:
--   - only pure observations are summed up (Compact.Summable): quests, creatures,
--     deaths without an enemy player around, bosses, outings, levels, small feats... Never
--     the gazette, the album (catalogue, boosters, trades), settings, the wanted board
--     and its deaths, nor what someone wrote by hand;
--   - a BILAN covers a run of the author's numbers, all older than the cutoff:
--     p = { of = whose numbers (nil: the author's own), name, cls, from, upto,
--           drop = which numbers are gone (bitmap, Compact.Bits), n = { [kind] = count },
--           lvl = highest level reached, last = date of the latest fact summed up,
--           boost = { d = day, s = boosters left after that day } (own BILAN only) };
--   - the BILANs of one author follow each other (from = previous upto + 1): that chain
--     says which numbers are gone for good, and the sync stops asking for them
--     (Sync.Has); the counts keep the members' statistics and titles right, the booster
--     snapshot keeps the boosters earned (Album.Replay);
--   - an officer sums up the facts of a member who has not played for keepDays + 30 days
--     (they cannot do it themselves); a member's own client never drops its own facts on
--     someone else's word.
-- The whole journal stays in Renatus Admin's archive (admin/core/src/archive.rs).
local _, ns = ...

local Compact = ns:RegisterModule("Compact", {})
ns.Compact = Compact

local DAY = 86400
Compact.DEFAULT_DAYS = 90       -- guild setting keepDays when none was published
Compact.MIN_BATCH = 200         -- facts to sum up at once (no BILAN for a handful)
Compact.MAX_SPAN = 24000        -- numbers covered by one BILAN (bitmap of 4000 characters)
Compact.IDLE_MARGIN = 30 * DAY  -- an officer sums up for a member idle keepDays + this
Compact.EVERY = 6 * 3600        -- how often a session looks for something to sum up

-- Pure observations. DEATH only without an enemy player (Sync.IsHuntDeath).
local FACTS = {
    QUEST_DONE = true, MOB_KILL = true, ZONE_FIRST_VISIT = true, DEATH = true, BOSS_KILL = true,
    EXPEDITION = true, RARE_ITEM = true, LEVEL_UP = true, PROFESSION = true, REPUTATION = true,
    MONEY = true, MOUNT = true, HEARTH_BIND = true, NEAR_DEATH = true, RESCUED = true,
    ROLL_EXTREME = true, DUEL = true, COUNTERS = true, VOTE = true,
}
Compact.FACTS = FACTS

function Compact.Summable(ev)
    return type(ev) == "table" and ev.vis == "G" and FACTS[ev.k] == true and ev.prov ~= "MAN"
        and not ns.Sync.IsHuntDeath(ev)
end

-- Gone with a BILAN: a fact, an emptied event (only a shell for the sync), a deletion.
local function droppable(ev)
    return ev.del == true or ev.k == "TOMBSTONE" or Compact.Summable(ev)
end
Compact.Droppable = droppable

------------------------------------------------------------------------
-- Bitmaps: 6 numbers per character
------------------------------------------------------------------------
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VALUE = {}
for i = 1, #ALPHABET do VALUE[ALPHABET:sub(i, i)] = i - 1 end

local Bits = {}
Compact.Bits = Bits

-- set: { [i] = true } for i in 0..n-1
function Bits.Encode(set, n)
    local out = {}
    for c = 0, math.ceil(n / 6) - 1 do
        local v = 0
        for b = 0, 5 do
            if set[c * 6 + b] then v = v + 2 ^ b end
        end
        out[#out + 1] = ALPHABET:sub(v + 1, v + 1)
    end
    return table.concat(out)
end

function Bits.Test(str, i)
    local v = VALUE[str:sub(math.floor(i / 6) + 1, math.floor(i / 6) + 1)]
    if not v then return false end
    return math.floor(v / 2 ^ (i % 6)) % 2 == 1
end

------------------------------------------------------------------------
-- Chains of BILANs
------------------------------------------------------------------------
local cache -- { chains = { [target] = { segments } }, inChain = { [id] = true }, floors = { [target] = upto } }

local function isInt(x) return type(x) == "number" and x == math.floor(x) end

local function validBilan(ev, guildKey)
    if ev.k ~= "BILAN" or ev.del or ev.vis ~= "G" or type(ev.p) ~= "table" then return nil end
    local p = ev.p
    if not isInt(p.from) or not isInt(p.upto) or p.from < 1 or p.upto < p.from then return nil end
    if type(p.drop) ~= "string" or #p.drop < math.ceil((p.upto - p.from + 1) / 6) then return nil end
    if guildKey and not ns.Context.SameGuild(ev.g, guildKey) then return nil end
    local target = type(p.of) == "string" and p.of or ev.a
    -- on someone else's behalf: officers only (same rule as the guild settings)
    if target ~= ev.a and not ns.Views.TrustedOfficer({ roster = ns.Store.Roster() }, ev) then return nil end
    return target
end

-- Ids of the BILAN events held, found once by a full scan then kept up to date (a
-- newcomer receives many BILANs in a row: no full scan of the journal for each).
local bilanIds

local function build()
    if cache then return cache end
    if not bilanIds then
        bilanIds = {}
        for id, ev in pairs(ns.db.events) do
            if ev.k == "BILAN" then bilanIds[id] = true end
        end
    end
    local guildKey = ns.Context.GuildKey()
    local byTarget = {}
    for id in pairs(bilanIds) do
        local ev = ns.db.events[id]
        local target = ev and validBilan(ev, guildKey)
        if target then
            byTarget[target] = byTarget[target] or {}
            table.insert(byTarget[target], ev)
        end
    end
    local chains, inChain, floors = {}, {}, {}
    for target, list in pairs(byTarget) do
        table.sort(list, function(a, b)
            if a.p.from ~= b.p.from then return a.p.from < b.p.from end
            return a.id < b.id
        end)
        local segments, nextFrom = {}, 1
        for _, ev in ipairs(list) do
            -- one BILAN per run of numbers; two for the same run: the first id counts
            if ev.p.from == nextFrom then
                segments[#segments + 1] = { from = ev.p.from, upto = ev.p.upto, drop = ev.p.drop, ev = ev }
                inChain[ev.id] = true
                nextFrom = ev.p.upto + 1
            end
        end
        if #segments > 0 then
            chains[target] = segments
            floors[target] = nextFrom - 1
        end
    end
    cache = { chains = chains, inChain = inChain, floors = floors }
    return cache
end

function Compact.Invalidate() cache = nil end

-- A BILAN arrived or was written: known without scanning the journal again.
local function noteBilan(ev)
    if bilanIds and ev.id then bilanIds[ev.id] = true end
    cache = nil
end

-- Is number s of this author gone for good (summed up by a BILAN of their chain)?
function Compact.Dropped(author, s)
    local segments = build().chains[author]
    if not segments or not s then return false end
    for i = #segments, 1, -1 do
        local seg = segments[i]
        if s >= seg.from then
            if s > seg.upto then return false end
            return Bits.Test(seg.drop, s - seg.from)
        end
    end
    return false
end

-- [author] = last number covered by their chain.
function Compact.Floors() return build().floors end

-- Does this BILAN count (part of its author's chain)? Its counts are added once.
function Compact.InChain(id) return build().inChain[id] == true end

-- The BILANs of an author's chain, oldest first.
function Compact.Chain(author) return build().chains[author] or {} end

-- Latest booster snapshot of a member, from their own BILANs: { d = day, s = stock } or nil.
function Compact.BoostOf(guid)
    local snap
    for _, seg in ipairs(Compact.Chain(guid)) do
        local b = seg.ev.p.boost
        if seg.ev.a == guid and type(b) == "table" and type(b.d) == "string" and type(b.s) == "number" then snap = b end
    end
    return snap
end

------------------------------------------------------------------------
-- Dropping what a chain covers
------------------------------------------------------------------------
-- Removes from this client the events the chains say are gone. Never one's own events
-- on someone else's BILAN. On an officer's BILAN (for an idle member), only what is
-- droppable here too. On the author's own, anything it says is gone: the author only
-- marks droppable events, so a kept kind marked there was deleted by them (a deletion
-- this client never received, the TOMBSTONE itself being summed up). Returns the count.
-- `only`: the one author whose chain changed (nil: every chain).
function Compact.Purge(only)
    local me = ns.Context.Me()
    local n = 0
    local chains = build().chains
    for target, segments in pairs(only and { [only] = chains[only] or {} } or chains) do
        for _, seg in ipairs(segments) do
            local own = seg.ev.a == target
            if not (target == me and not own) then
                for s = seg.from, seg.upto do
                    local id = target .. ":" .. s
                    local ev = ns.db.events[id]
                    if ev and (own or droppable(ev)) and Bits.Test(seg.drop, s - seg.from) then
                        ns.db.events[id] = nil
                        n = n + 1
                    end
                end
            end
        end
    end
    if n > 0 then
        ns.Store.Forget()
        if ns.Sync then ns.Sync.Invalidate() end
    end
    return n
end

------------------------------------------------------------------------
-- Writing a BILAN
------------------------------------------------------------------------
local function now() return (GetServerTime and GetServerTime()) or time() end

local function dayStart(t)
    local d = date("*t", t)
    return t - (d.hour * 3600 + d.min * 60 + d.sec)
end

-- Facts are summed up once older than this (start of a day).
function Compact.Cutoff(at)
    return dayStart((at or now()) - ns.GuildConfig.KeepDays() * DAY)
end

-- The run of `target`'s numbers to sum up now: from the end of their chain, as long as
-- this client holds every number and each is older than the cutoff. nil if not worth it.
local function plan(target, cutoff)
    local from = (Compact.Floors()[target] or 0) + 1
    local upto, count = from - 1, 0
    while upto - from + 1 < Compact.MAX_SPAN do
        local ev = ns.db.events[target .. ":" .. (upto + 1)]
        if not ev or (ev.t or 0) >= cutoff then break end
        upto = upto + 1
        if droppable(ev) then count = count + 1 end
    end
    if count < Compact.MIN_BATCH then return nil end
    return from, upto
end

local function summarize(target, from, upto)
    local set, counts, lvl, last, name, cls = {}, {}, nil, nil, nil, nil
    for s = from, upto do
        local ev = ns.db.events[target .. ":" .. s]
        name, cls = ev.n or name, ev.c or cls
        if droppable(ev) then
            set[s - from] = true
            if not ev.del and ev.k ~= "TOMBSTONE" then
                counts[ev.k] = (counts[ev.k] or 0) + 1
                if ev.k == "LEVEL_UP" and type(ev.p.lvl) == "number" and ev.p.lvl > (lvl or 0) then lvl = ev.p.lvl end
                if not last or ev.t > last then last = ev.t end
            end
        end
    end
    return { from = from, upto = upto, drop = Bits.Encode(set, upto - from + 1), n = counts,
        lvl = lvl, last = last, name = name, cls = cls }
end

local function publish(payload)
    return ns.Store.Add("BILAN", payload, { vis = "G", prov = "DED", noExp = true, loc = {} })
end

-- Sums up what can be: this character's old facts, and (officers) those of members idle
-- for long. Returns the BILANs published.
function Compact.Run(at)
    if ns.char.ui.demo or not ns.Context.GuildKey() then return {} end
    local t = at or now()
    local cutoff = Compact.Cutoff(t)
    local me = ns.Context.Me()
    local out = {}
    local from, upto = plan(me, cutoff)
    if from then
        local p = summarize(me, from, upto)
        -- boosters left at the end of the last day summed up: the facts that earned them go
        local day = ns.Album.DayKey(cutoff - 1)
        local events = ns.Store.Dataset().events
        local _, stock = ns.Album.Replay(events, me, ns.db.played[me], ns.GuildConfig.BoosterRules(),
            Compact.BoostOf(me), day)
        p.boost = { d = day, s = stock }
        out[#out + 1] = publish(p)
    end
    if ns.GuildConfig.CanPublish() then
        local latest, top = {}, {}
        for _, ev in pairs(ns.db.events) do
            if ev.vis == "G" and ev.s then
                if latest[ev.a] == nil or (ev.t or 0) > latest[ev.a] then latest[ev.a] = ev.t or 0 end
                if ev.s > (top[ev.a] or 0) then top[ev.a] = ev.s end
            end
        end
        local vec = ns.Sync.Vector()
        for author, last in pairs(latest) do
            -- idle for long, and nothing of theirs missing here
            if author ~= me and last < cutoff - Compact.IDLE_MARGIN
                and vec[author] and vec[author].max >= top[author] then
                local f, u = plan(author, cutoff)
                if f then
                    local p = summarize(author, f, u)
                    p.of = author
                    out[#out + 1] = publish(p)
                end
            end
        end
    end
    return out
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
function Compact:OnLogin()
    ns.EventBus.Subscribe("CHRONICLE_EVENT", function(ev)
        if ev.k == "BILAN" and ev.id and type(ev.p) == "table" then
            noteBilan(ev)
            Compact.Purge(type(ev.p.of) == "string" and ev.p.of or ev.a)
        end
    end)
    -- The roster decides which BILANs on someone's behalf count.
    ns:RegisterGameEvent("GUILD_ROSTER_UPDATE", function() Compact.Invalidate() end)
    if C_Timer then
        local function tick()
            local ok, err = pcall(Compact.Run)
            if not ok then ns.Print("erreur dans le bilan : %s", tostring(err)) end
            C_Timer.After(Compact.EVERY, tick)
        end
        -- after the sync had time to catch up (a member coming back sums up a full log)
        C_Timer.After(10 * 60, tick)
        C_Timer.After(5, function() Compact.Purge() end)
    end
end
