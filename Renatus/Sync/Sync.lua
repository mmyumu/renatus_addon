-- Sync/Sync.lua: journal synchronization between guild members (serverless).
--
-- Principle (docs/ARCHITECTURE.md §10):
--   - each author owns an append-only public log, numbered 1, 2, 3...
--   - each client knows, per author, the highest contiguous sequence it holds
--     (its "vector"); numbers summed up by a BILAN (Core/Compact.lua) count as held;
--   - V: "here is my vector"; R: "I am missing events f..t of author a";
--     E: "here is an event" (broadcast to the whole guild, so everyone benefits).
--   - the author answers a request quickly, relays wait a bit and stay silent
--     if someone already answered.
--   - catch-up of a member far behind (a newcomer, a long absence): Q asks one member
--     for a page of one class of events (what makes the addon work, the gazette and the
--     rival guild, the card ledger, the last days), A answers how many are coming and
--     where the next page starts. The old history comes last, through R.
-- Sending order (Transport.PRIORITY): what just happened first, then the catch-up
-- tiers, so a newcomer's history never holds back the live events of the others.
-- Only events with visibility "G" (category set to Guild) are sent.
-- Private events never leave the client.
local _, ns = ...

local Sync = ns:RegisterModule("Sync", {})
ns.Sync = Sync

local Transport, Ser = ns.Transport, ns.Serialize
local P = Transport.PRIORITY
local trace = Transport.Trace

Sync.PROTO = 1
Sync.MAX_RANGE = 25            -- events per request
Sync.VECTOR_EVERY = 15 * 60    -- periodic vector announcement
Sync.MAX_EVENT_BYTES = 6000
Sync.LIVE_AGE = 6 * 3600       -- younger than this: sent as live, before any catch-up
Sync.RECENT_AGE = 7 * 86400    -- the "last days" catch-up class
Sync.CATCHUP_MIN = 100         -- events behind from which a full catch-up starts
Sync.PAGE = 120                -- events per catch-up page
Sync.CATCHUP_STEPS = { "essential", "gazette", "ledger", "recent" }

local vectorCache
local seenOnWire = {}     -- [id] = time the event went over the wire (sent by us or someone else)
local requested = {}      -- [author:from] = time of the last request
local scheduled = {}      -- [id] = time the reply was scheduled
local lastVectorSent = -math.huge
Sync.peers = {}           -- [name] = { seen = time, proto = n }

local function now() return (GetServerTime and GetServerTime()) or time() end
local function clock() return (GetTime and GetTime()) or now() end

local ALLOWED = { v = true, id = true, a = true, n = true, c = true, s = true, t = true, k = true, g = true,
    loc = true, pt = true, prov = true, miss = true, refs = true, occ = true, x = true, vis = true, src = true,
    p = true, ded = true, del = true }
local PROVS = { OBS = true, LOG = true, MAN = true, DED = true, GEN = true, EXT = true }

------------------------------------------------------------------------
-- Classes and priorities
------------------------------------------------------------------------
local CLASS_OF_KIND = {
    -- what makes the addon work: settings, catalogue, deletions, consents, profiles, summaries
    GUILD_CONFIG = "essential", CARD_SET = "essential", TOMBSTONE = "essential", AI_CONSENT = "essential",
    CARD_PROFILE = "essential", RIVAL_ROSTER = "essential", BILAN = "essential",
    -- the gazette and the rival guild
    ARTICLE = "gazette", EDITION = "gazette", LETTER = "gazette", ENEMY_SEEN = "gazette", ENEMY_NOTE = "gazette",
    PVP_CLASH = "gazette", PVP_KILL = "gazette", WANTED = "gazette", WANTED_CLOSE = "gazette",
    DEATH_CAUSE = "gazette",
    -- the card ledger (collections are replayed from it)
    BOOSTER_OPEN = "ledger", TRADE_OFFER = "ledger", TRADE_REPLY = "ledger",
}
local PRIORITY_OF_CLASS = { essential = P.ESSENTIAL, gazette = P.GAZETTE, ledger = P.LEDGER,
    recent = P.RECENT, history = P.HISTORY }
-- Big events: a fresh edition goes out right after the live events, not among them.
local HEAVY = { ARTICLE = true, EDITION = true, CARD_SET = true }

-- A death that matters to the wanted board: killed by a player, or enemies around.
function Sync.IsHuntDeath(ev)
    if ev.k ~= "DEATH" or type(ev.p) ~= "table" then return false end
    local k = ev.p.killer
    if type(k) == "table" and k.pl then return true end
    return type(ev.p.enemies) == "table" and #ev.p.enemies > 0
end

function Sync.ClassOf(ev, at)
    local c = CLASS_OF_KIND[ev.k]
    if c then return c end
    if Sync.IsHuntDeath(ev) then return "gazette" end
    if (at or now()) - (ev.t or 0) < Sync.RECENT_AGE then return "recent" end
    return "history"
end

-- Queue priority of an event: live if recent, else its catch-up tier.
function Sync.PriorityOf(ev)
    local t = now()
    if t - (ev.t or 0) < Sync.LIVE_AGE then return HEAVY[ev.k] and P.ESSENTIAL or P.LIVE end
    return PRIORITY_OF_CLASS[Sync.ClassOf(ev, t)]
end

------------------------------------------------------------------------
-- Vector and gaps
------------------------------------------------------------------------
-- Held, or summed up by a BILAN (the event is gone for good: nobody can send it).
local function has(author, s)
    if ns.db.events[author .. ":" .. s] ~= nil then return true end
    return ns.Compact ~= nil and ns.Compact.Dropped(author, s)
end
Sync.Has = has

-- { [author] = { max = highest contiguous sequence, top = highest known sequence } }
local function computeVector()
    if vectorCache then return vectorCache end
    local guildKey = ns.Context.GuildKey()
    local tops = {}
    for _, ev in pairs(ns.db.events) do
        if ev.vis == "G" and ev.s and ns.Context.SameGuild(ev.g, guildKey) and ev.s > (tops[ev.a] or 0) then
            tops[ev.a] = ev.s
        end
    end
    if ns.Compact then
        for author, upto in pairs(ns.Compact.Floors()) do
            if upto > (tops[author] or 0) then tops[author] = upto end
        end
    end
    local vec = {}
    for author, top in pairs(tops) do
        local max = 0
        while has(author, max + 1) do max = max + 1 end
        vec[author] = { max = max, top = math.max(top, max) }
    end
    vectorCache = vec
    return vec
end
Sync.Vector = computeVector

function Sync.Invalidate() vectorCache = nil end

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

local function vectorMax()
    local v = {}
    for author, info in pairs(computeVector()) do v[author] = info.max end
    return v
end

function Sync.SendVector(force)
    if not force and clock() - lastVectorSent < 60 then return false end
    lastVectorSent = clock()
    Transport.Send(function()
        return encode({ o = "V", pr = Sync.PROTO, ve = ns.version, v = vectorMax() })
    end, P.CONTROL)
    return true
end

-- Schedules sending an event; cancelled if someone broadcast it after we scheduled it
-- (a reply waiting behind a long queue must not go out a second time).
local function sendEvent(id, delay, priority)
    if scheduled[id] then return end
    local ev = ns.db.events[id]
    if not ev then return end
    local at = clock()
    scheduled[id] = at
    priority = priority or Sync.PriorityOf(ev)
    local function enqueue()
        Transport.Send(function()
            scheduled[id] = nil
            local seen = seenOnWire[id]
            if seen and seen >= at then trace("sendSkip", { id = id, why = "deja diffuse" }); return nil end
            local cur = ns.db.events[id]
            if not cur or cur.vis ~= "G" then trace("sendSkip", { id = id, why = "absent ou prive" }); return nil end
            local text, err = encode({ o = "E", e = wireCopy(cur) })
            if not text then trace("sendSkip", { id = id, k = cur.k, why = "encodage : " .. tostring(err) }); return nil end
            if #text > Sync.MAX_EVENT_BYTES then
                trace("sendSkip", { id = id, k = cur.k, why = "trop gros", len = #text })
                return nil
            end
            seenOnWire[id] = clock()
            trace("sendE", { id = id, k = cur.k, len = #text })
            return text
        end, priority)
    end
    if delay and delay > 0 and C_Timer then C_Timer.After(delay, enqueue) else enqueue() end
end
Sync.SendEvent = sendEvent

local function request(author, from, to)
    local key = author .. ":" .. from
    if requested[key] and clock() - requested[key] < 90 then return end
    requested[key] = clock()
    to = math.min(to, from + Sync.MAX_RANGE - 1)
    trace("sendR", { a = author, f = from, t = to })
    Transport.Send(encode({ o = "R", a = author, f = from, t = to }), P.CONTROL)
end

-- Requests what is missing for an author, based on what we know exists: every gap,
-- not only the first one (an event that never arrives must not hide the next gaps).
-- At most MAX_GAPS ranges and MAX_ASK numbers per round: after a catch-up by class,
-- the gaps are many and small.
Sync.MAX_GAPS = 8
Sync.MAX_ASK = 100
local function requestMissing(author, knownTop)
    local info = computeVector()[author] or { max = 0, top = 0 }
    local top = math.max(knownTop or 0, info.top)
    local from, ranges, asked = info.max + 1, 0, 0
    while from <= top and ranges < Sync.MAX_GAPS and asked < Sync.MAX_ASK do
        if has(author, from) then
            from = from + 1
        else
            local to = from
            while to < top and not has(author, to + 1) and to - from < Sync.MAX_RANGE - 1 do to = to + 1 end
            request(author, from, to)
            ranges = ranges + 1
            asked = asked + (to - from + 1)
            from = to + 1
        end
    end
end

-- Asks right away for every gap we know of (/renatus sync now).
function Sync.RequestGaps()
    local n = 0
    for author, info in pairs(computeVector()) do
        if info.top > info.max then
            for key in pairs(requested) do
                if key:sub(1, #author + 1) == author .. ":" then requested[key] = nil end
            end
            requestMissing(author)
            n = n + 1
        end
    end
    return n
end

------------------------------------------------------------------------
-- Catch-up by class (Q / A)
------------------------------------------------------------------------
-- catchup = { steps, step (index), peer, cur (cursor of the next page), asked (clock of
-- the last Q), expect (events announced by A), got, progress (clock), tried = { [peer] } }
local catchup
local essentialDone = false   -- the "essential" class is checked once per session
Sync.Q_TIMEOUT = 30           -- no answer to Q: ask someone else
Sync.STALL = 60               -- no event of the page for that long: go on

-- Is this message for us? "Alice Liddell" (Forever, full name) or "Alice".
local function forMe(to)
    if type(to) ~= "string" then return false end
    local _, me = ns.Context.Me()
    return to == me or to:match("^(%S+)") == me
end

-- Newest first: the latest issue of the gazette, the settings in force.
local function newer(a, b)
    if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) > (b.t or 0) end
    return a.id > b.id
end

local function afterCursor(ev, cur)
    if type(cur) ~= "table" or type(cur.t) ~= "number" or type(cur.id) ~= "string" then return true end
    return (ev.t or 0) < cur.t or ((ev.t or 0) == cur.t and ev.id < cur.id)
end

local function sendQ()
    local c = catchup
    c.asked, c.expect, c.got = clock(), nil, 0
    c.tried[c.peer] = true
    local step = c.steps[c.step]
    trace("sendQ", { to = c.peer, c = step })
    Transport.Send(function()
        return encode({ o = "Q", to = c.peer, c = step, v = vectorMax(), cur = c.cur })
    end, P.CONTROL)
end

local function advance()
    local c = catchup
    if not c then return end
    if not c.cur then
        c.step = c.step + 1
        if c.step > #c.steps then
            trace("catchupDone", {})
            catchup = nil
            -- what is left (old history, holes) goes through the usual requests
            Sync.RequestGaps()
            return
        end
    end
    sendQ()
end

-- Another member to ask: the most recently seen one we have not tried yet.
local function otherPeer(tried)
    local best, bestSeen
    for name, p in pairs(Sync.peers) do
        if not tried[name] and (not bestSeen or p.seen > bestSeen) then best, bestSeen = name, p.seen end
    end
    return best
end

local function watch()
    local c = catchup
    if not c or not C_Timer then return end
    local t = clock()
    if not c.expect then
        if t - c.asked >= Sync.Q_TIMEOUT then
            local peer = otherPeer(c.tried)
            if not peer then
                trace("catchupStop", { why = "personne ne repond" })
                catchup = nil
                return
            end
            c.peer = peer
            sendQ()
        end
    elseif t - c.progress >= Sync.STALL then
        advance()
    end
    if catchup then C_Timer.After(5, watch) end
end

local function startCatchup(peer, full)
    if catchup then
        -- found out we are far behind while checking the essentials: go all the way
        if full and #catchup.steps == 1 then catchup.steps = Sync.CATCHUP_STEPS end
        return
    end
    local steps = full and Sync.CATCHUP_STEPS or { "essential" }
    catchup = { steps = steps, step = 1, peer = peer, tried = {} }
    essentialDone = true
    trace("catchupStart", { peer = peer, full = full or nil })
    sendQ()
    if C_Timer then C_Timer.After(5, watch) end
end

-- What the catch-up is doing (for /renatus sync), or nil.
function Sync.Catchup()
    if not catchup then return nil end
    return { class = catchup.steps[catchup.step], peer = catchup.peer, expect = catchup.expect, got = catchup.got }
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
local handlers = {}

function handlers.V(sender, msg)
    if type(msg.v) ~= "table" then return end
    local mine = computeVector()
    local peerBehind, behind = false, 0
    for author, max in pairs(msg.v) do
        if type(author) == "string" and isInt(max) then
            local have = mine[author] and mine[author].max or 0
            if max > have then
                behind = behind + (max - have)
                requestMissing(author, max)
            end
        end
    end
    for author, info in pairs(mine) do
        local theirs = msg.v[author]
        if info.max > 0 and (not isInt(theirs) or theirs < info.max) then peerBehind = true end
    end
    -- Far behind: catch up class by class with this member; otherwise, once per
    -- session, make sure nothing essential is missing (settings, catalogue, summaries).
    if behind >= Sync.CATCHUP_MIN or not essentialDone then
        startCatchup(Transport.ShortName(sender), behind >= Sync.CATCHUP_MIN)
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
    local have = 0
    for s = msg.f, msg.t do
        local id = msg.a .. ":" .. s
        if ns.db.events[id] and ns.db.events[id].vis == "G" then have = have + 1; sendEvent(id, delay) end
    end
    trace("gotR", { from = sender, a = msg.a, f = msg.f, t = msg.t, have = have })
end

-- A catch-up page for whoever asked us: the events of the class they lack, newest first.
function handlers.Q(sender, msg)
    if not forMe(msg.to) or not PRIORITY_OF_CLASS[msg.c] or msg.c == "history" then return end
    local v = type(msg.v) == "table" and msg.v or {}
    local guildKey, t = ns.Context.GuildKey(), now()
    local list = {}
    for _, ev in pairs(ns.db.events) do
        if ev.vis == "G" and ev.s and ns.Context.SameGuild(ev.g, guildKey)
            and ev.s > (isInt(v[ev.a]) and v[ev.a] or 0) and Sync.ClassOf(ev, t) == msg.c
            and afterCursor(ev, msg.cur) then
            list[#list + 1] = ev
        end
    end
    table.sort(list, newer)
    local n = math.min(#list, Sync.PAGE)
    for i = 1, n do sendEvent(list[i].id, 0, Sync.PriorityOf(list[i])) end
    local last = list[n]
    local cur = (#list > n and last) and { t = last.t, id = last.id } or nil
    trace("gotQ", { from = sender, c = msg.c, n = n, more = cur and true or nil })
    Transport.Send(encode({ o = "A", to = Transport.ShortName(sender), c = msg.c, n = n, cur = cur }), P.CONTROL)
end

function handlers.A(sender, msg)
    local c = catchup
    if not c or not forMe(msg.to) or msg.c ~= c.steps[c.step] or c.expect then return end
    if not isInt(msg.n) then return end
    c.peer = Transport.ShortName(sender)
    c.expect, c.got, c.progress = msg.n, 0, clock()
    c.cur = type(msg.cur) == "table" and msg.cur or nil
    trace("gotA", { from = sender, c = msg.c, n = msg.n, more = c.cur and true or nil })
    if msg.n == 0 then advance() end
end

-- Catch-up progress: the page is (nearly) there, ask for the next one.
local function countForCatchup(ev)
    local c = catchup
    if not c or not c.expect then return end
    if Sync.ClassOf(ev) ~= c.steps[c.step] then return end
    c.got, c.progress = c.got + 1, clock()
    if c.got >= math.ceil(c.expect * 0.8) then advance() end
end

function handlers.E(sender, msg)
    if type(msg.e) == "table" and msg.e.g == nil then msg.e.g = msg.g end
    local ev, why = Sync.Validate(msg.e, ns.Context.GuildKey())
    local mon = ns.db.monitor.sync
    local e = type(msg.e) == "table" and msg.e or {}
    if not ev then
        trace("gotE", { from = sender, id = tostring(e.id), k = tostring(e.k), result = "rejete : " .. tostring(why) })
        Sync.rejected = (Sync.rejected or 0) + 1
        Sync.lastReject = why
        mon.rejected = (mon.rejected or 0) + 1
        mon.lastReject = ("%s (de %s)"):format(tostring(why), tostring(Transport.ShortName(sender)))
        mon.lastRejectAt = now()
        return
    end
    seenOnWire[ev.id] = clock()
    if ns.db.events[ev.id] then
        trace("gotE", { from = sender, id = ev.id, k = ev.k, result = "doublon" })
        countForCatchup(ev)
        return
    end
    -- Summed up by a BILAN: gone for good, an older client resent it.
    if ns.Compact and ns.Compact.Dropped(ev.a, ev.s) then
        trace("gotE", { from = sender, id = ev.id, k = ev.k, result = "resume" })
        return
    end
    local from = Transport.ShortName(sender)
    -- "verified": received from the author themselves; otherwise relayed by another member.
    -- On WoW Forever the sender is the full name ("Renaa Fitzherak") while UnitName gives "Renaa".
    local direct = from == ev.n or (from and from:match("^(%S+)")) == ev.n
    ev.rx = { by = from, direct = direct or nil, at = now() }
    local inserted = ns.Store.Insert(ev)
    trace("gotE", { from = sender, id = ev.id, k = ev.k, result = inserted and "insere" or "refuse par le stockage" })
    if inserted then
        Sync.received = (Sync.received or 0) + 1
        mon.received = (mon.received or 0) + 1
        mon.lastReceived = now()
        vectorCache = nil
        countForCatchup(ev)
        requestMissing(ev.a, ev.s - 1)
    end
end

local function onMessage(sender, text)
    local msg = Ser.Decode(text)
    if type(msg) ~= "table" or type(msg.o) ~= "string" then
        trace("undecodable", { from = sender, len = #text, chunks = Transport.lastChunks, raw = text })
        return
    end
    local guildKey = ns.Context.GuildKey()
    if not guildKey or not ns.Context.SameGuild(msg.g, guildKey) then
        trace("otherGuild", { from = sender, o = msg.o, g = tostring(msg.g) })
        return
    end
    if msg.o == "V" then
        -- only the authors we are behind on (the full vector is large)
        local mine, behind = computeVector(), {}
        for author, max in pairs(type(msg.v) == "table" and msg.v or {}) do
            local have = mine[author] and mine[author].max or 0
            if isInt(max) and max > have then behind[#behind + 1] = ("%s:%d>%d"):format(author, max, have) end
        end
        trace("gotV", { from = sender, ve = msg.ve, behind = table.concat(behind, " ") })
    elseif msg.o ~= "R" and msg.o ~= "E" and msg.o ~= "Q" and msg.o ~= "A" then
        trace("got" .. msg.o, { from = sender, len = #text })
    end
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
        if ev.a == me and ev.vis == "G" and not ev.rx and ev.id then sendEvent(ev.id, 0) end
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
        catchup = Sync.Catchup(),
    }
end
