-- Sync/Sync.lua: journal synchronization between guild members (serverless).
--
-- Principle (docs/ARCHITECTURE.md §10):
--   - each author owns an append-only public log, numbered 1, 2, 3...
--   - each client knows, per author, the highest contiguous sequence it holds
--     (its "vector");
--   - V: "here is my vector"; R: "I am missing events f..t of author a";
--     E: "here is an event" (broadcast to the whole guild, so everyone benefits).
--   - the author answers a request quickly, relays wait a bit and stay silent
--     if someone already answered.
-- Only events with visibility "G" (category set to Guild) are sent.
-- Private events never leave the client.
local _, ns = ...

local Sync = ns:RegisterModule("Sync", {})
ns.Sync = Sync

local Transport, Ser = ns.Transport, ns.Serialize
local P = Transport.PRIORITY

Sync.PROTO = 1
Sync.MAX_RANGE = 25            -- events per request
Sync.VECTOR_EVERY = 15 * 60    -- periodic vector announcement
Sync.MAX_EVENT_BYTES = 6000

local vectorCache
local seenOnWire = {}     -- [id] = time the event went over the wire (sent by us or someone else)
local requested = {}      -- [author:from] = time of the last request
local scheduled = {}      -- [id] = true: reply already scheduled
local lastVectorSent = -math.huge
Sync.peers = {}           -- [name] = { seen = time, proto = n }

local function now() return (GetServerTime and GetServerTime()) or time() end
local function clock() return (GetTime and GetTime()) or now() end

local ALLOWED = { v = true, id = true, a = true, n = true, c = true, s = true, t = true, k = true, g = true,
    loc = true, pt = true, prov = true, miss = true, refs = true, occ = true, x = true, vis = true, src = true,
    p = true, ded = true, del = true }
local PROVS = { OBS = true, LOG = true, MAN = true, DED = true, GEN = true, EXT = true }

------------------------------------------------------------------------
-- Vector and gaps
------------------------------------------------------------------------
-- { [author] = { max = highest contiguous sequence, top = highest known sequence } }
local function computeVector()
    if vectorCache then return vectorCache end
    local guildKey = ns.Context.GuildKey()
    local seqs = {}
    for _, ev in pairs(ns.db.events) do
        if ev.vis == "G" and ev.s and ns.Context.SameGuild(ev.g, guildKey) then
            seqs[ev.a] = seqs[ev.a] or {}
            seqs[ev.a][ev.s] = true
        end
    end
    local vec = {}
    for author, set in pairs(seqs) do
        local max, top = 0, 0
        while set[max + 1] do max = max + 1 end
        for s in pairs(set) do if s > top then top = s end end
        vec[author] = { max = max, top = top }
    end
    vectorCache = vec
    return vec
end
Sync.Vector = computeVector

function Sync.Invalidate() vectorCache = nil end

local function hasEvent(author, s) return ns.db.events[author .. ":" .. s] ~= nil end

------------------------------------------------------------------------
-- Validation of received events
------------------------------------------------------------------------
local function isInt(x) return type(x) == "number" and x == math.floor(x) end

function Sync.Validate(ev, guildKey)
    if type(ev) ~= "table" then return nil, "pas une table" end
    if type(ev.a) ~= "string" or #ev.a > 64 or not ev.a:match("^Player%-") then return nil, "auteur" end
    if not isInt(ev.s) or ev.s < 1 then return nil, "sequence" end
    if ev.id ~= ev.a .. ":" .. ev.s then return nil, "identifiant" end
    if type(ev.n) ~= "string" or #ev.n > 48 then return nil, "nom" end
    if type(ev.t) ~= "number" then return nil, "date" end
    if type(ev.k) ~= "string" or #ev.k > 24 or not ev.k:match("^[%u_]+$") then return nil, "type" end
    if ev.vis ~= "G" then return nil, "visibilite" end
    if not guildKey or not ns.Context.SameGuild(ev.g, guildKey) then return nil, "autre guilde" end
    if type(ev.p) ~= "table" then return nil, "contenu" end
    if ev.prov ~= nil and not PROVS[ev.prov] then return nil, "provenance" end
    local clean = {}
    for k, v in pairs(ev) do if ALLOWED[k] then clean[k] = v end end
    return clean
end

-- Wire copy: schema fields only (no local annotations).
-- The guild key travels once, in the message envelope.
local function wireCopy(ev)
    local out = {}
    for k, v in pairs(ev) do if ALLOWED[k] and k ~= "g" then out[k] = v end end
    return out
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------
local function encode(msg)
    msg.g = ns.Context.GuildKey()
    return Ser.Encode(msg)
end

function Sync.SendVector(force)
    if not force and clock() - lastVectorSent < 60 then return false end
    lastVectorSent = clock()
    Transport.Send(function()
        local v = {}
        for author, info in pairs(computeVector()) do v[author] = info.max end
        return encode({ o = "V", pr = Sync.PROTO, ve = ns.version, v = v })
    end, P.CONTROL)
    return true
end

-- Schedules sending an event; cancelled if someone broadcast it meanwhile.
local function sendEvent(id, delay)
    if scheduled[id] then return end
    scheduled[id] = true
    local function enqueue()
        Transport.Send(function()
            scheduled[id] = nil
            local seen = seenOnWire[id]
            if seen and clock() - seen < 60 then return nil end
            local ev = ns.db.events[id]
            if not ev or ev.vis ~= "G" then return nil end
            local text = encode({ o = "E", e = wireCopy(ev) })
            if not text or #text > Sync.MAX_EVENT_BYTES then return nil end
            seenOnWire[id] = clock()
            return text
        end, (ns.db.events[id] and (ns.db.events[id].k == "ARTICLE" or ns.db.events[id].k == "EDITION" or ns.db.events[id].k == "CARD_SET")) and P.BULK or P.EVENT)
    end
    if delay and delay > 0 and C_Timer then C_Timer.After(delay, enqueue) else enqueue() end
end
Sync.SendEvent = sendEvent

local function request(author, from, to)
    local key = author .. ":" .. from
    if requested[key] and clock() - requested[key] < 90 then return end
    requested[key] = clock()
    to = math.min(to, from + Sync.MAX_RANGE - 1)
    Transport.Send(encode({ o = "R", a = author, f = from, t = to }), P.CONTROL)
end

-- Requests what is missing for an author, based on what we know exists.
local function requestMissing(author, knownTop)
    local info = computeVector()[author] or { max = 0, top = 0 }
    local top = math.max(knownTop or 0, info.top)
    if top <= info.max then return end
    local from = info.max + 1
    local to = from
    while to < top and not hasEvent(author, to + 1) and to - from < Sync.MAX_RANGE - 1 do to = to + 1 end
    request(author, from, to)
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
local handlers = {}

function handlers.V(sender, msg)
    if type(msg.v) ~= "table" then return end
    local mine = computeVector()
    local peerBehind = false
    for author, max in pairs(msg.v) do
        if type(author) == "string" and isInt(max) then
            local have = mine[author] and mine[author].max or 0
            if max > have then requestMissing(author, max) end
        end
    end
    for author, info in pairs(mine) do
        local theirs = msg.v[author]
        if info.max > 0 and (not isInt(theirs) or theirs < info.max) then peerBehind = true end
    end
    -- They are missing things: announce our vector so they can request.
    if peerBehind and C_Timer then
        C_Timer.After(2 + math.random() * 6, function() Sync.SendVector(false) end)
    end
end

function handlers.R(sender, msg)
    if type(msg.a) ~= "string" or not isInt(msg.f) or not isInt(msg.t) then return end
    if msg.t < msg.f or msg.t - msg.f >= Sync.MAX_RANGE then return end
    local me = ns.Context.Me()
    local delay = (msg.a == me) and (0.2 + math.random() * 0.8) or (3 + math.random() * 5)
    for s = msg.f, msg.t do
        local id = msg.a .. ":" .. s
        if ns.db.events[id] and ns.db.events[id].vis == "G" then sendEvent(id, delay) end
    end
end

function handlers.E(sender, msg)
    if type(msg.e) == "table" and msg.e.g == nil then msg.e.g = msg.g end
    local ev, why = Sync.Validate(msg.e, ns.Context.GuildKey())
    local mon = ns.db.monitor.sync
    if not ev then
        Sync.rejected = (Sync.rejected or 0) + 1
        Sync.lastReject = why
        mon.rejected = (mon.rejected or 0) + 1
        mon.lastReject = ("%s (de %s)"):format(tostring(why), tostring(Transport.ShortName(sender)))
        mon.lastRejectAt = now()
        return
    end
    seenOnWire[ev.id] = clock()
    if ns.db.events[ev.id] then return end
    local from = Transport.ShortName(sender)
    -- "verified": received from the author themselves; otherwise relayed by another member.
    -- On WoW Forever the sender is the full name ("Renaa Fitzherak") while UnitName gives "Renaa".
    local direct = from == ev.n or (from and from:match("^(%S+)")) == ev.n
    ev.rx = { by = from, direct = direct or nil, at = now() }
    if ns.Store.Insert(ev) then
        Sync.received = (Sync.received or 0) + 1
        mon.received = (mon.received or 0) + 1
        mon.lastReceived = now()
        vectorCache = nil
        requestMissing(ev.a, ev.s - 1)
    end
end

local function onMessage(sender, text)
    local msg = Ser.Decode(text)
    if type(msg) ~= "table" or type(msg.o) ~= "string" then return end
    local guildKey = ns.Context.GuildKey()
    if not guildKey or not ns.Context.SameGuild(msg.g, guildKey) then return end
    local name = Transport.ShortName(sender)
    Sync.peers[name] = { seen = now(), proto = msg.pr or (Sync.peers[name] and Sync.peers[name].proto) }
    -- Persisted for Renatus Admin's monitoring (local only).
    local peers = ns.db.monitor.peers
    local p = peers[name] or { first = now() }
    p.seen, p.proto = now(), msg.pr or p.proto
    if type(msg.ve) == "string" and #msg.ve <= 24 then p.ver = msg.ve end
    peers[name] = p
    local h = handlers[msg.o]
    if h then h(sender, msg) end
end
Sync.OnMessage = onMessage

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
function Sync:OnLogin()
    Transport.Init()
    Transport.SetHandler(onMessage)
    ns.EventBus.Subscribe("CHRONICLE_EVENT", function(ev)
        vectorCache = nil
        -- New public event created here: broadcast right away (the queue waits if needed).
        local me = ns.Context.Me()
        if ev.a == me and ev.vis == "G" and not ev.rx then sendEvent(ev.id, 0) end
    end)
    if C_Timer then
        local function periodic()
            Sync.SendVector(true)
            C_Timer.After(Sync.VECTOR_EVERY, periodic)
        end
        C_Timer.After(15 + math.random() * 15, periodic)
    end
end

function Sync.Status()
    local canSend, reason = Transport.CanSend()
    local peers, recent = 0, 0
    for _, p in pairs(Sync.peers) do
        peers = peers + 1
        if now() - p.seen < 3600 then recent = recent + 1 end
    end
    local shared, authors = 0, 0
    for _, info in pairs(computeVector()) do authors = authors + 1; shared = shared + info.max end
    return {
        canSend = canSend, reason = reason, queue = Transport.QueueLength(),
        peers = peers, recentPeers = recent, shared = shared, authors = authors,
        stats = Transport.stats, received = Sync.received or 0, rejected = Sync.rejected or 0,
    }
end
