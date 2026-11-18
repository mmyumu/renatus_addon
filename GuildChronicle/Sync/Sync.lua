-- Sync/Sync.lua : synchronisation des journaux entre membres de la guilde (sans serveur).
--
-- Principe (docs/ARCHITECTURE.md §10) :
--   - chaque auteur possede un journal public en ajout seul, numerote 1, 2, 3...
--   - chaque client connait, par auteur, la plus grande sequence contigue qu'il possede
--     (son "vecteur") ;
--   - V : "voici mon vecteur" ; R : "il me manque les evenements f..t de l'auteur a" ;
--     E : "voici un evenement" (diffuse a toute la guilde, donc profite a tous).
--   - l'auteur repond vite a une demande, les relais attendent un peu et se taisent
--     si quelqu'un a deja repondu.
-- Seuls les evenements de visibilite "G" (categorie reglee sur Guilde) sont envoyes.
-- Les evenements prives ne quittent jamais le client.
local _, ns = ...

local Sync = ns:RegisterModule("Sync", {})
ns.Sync = Sync

local Transport, Ser = ns.Transport, ns.Serialize
local P = Transport.PRIORITY

Sync.PROTO = 1
Sync.MAX_RANGE = 25            -- evenements par demande
Sync.VECTOR_EVERY = 15 * 60    -- annonce periodique du vecteur
Sync.MAX_EVENT_BYTES = 6000

local vectorCache
local seenOnWire = {}     -- [id] = instant ou l'evenement est passe sur le canal (par nous ou un autre)
local requested = {}      -- [auteur:debut] = instant de la derniere demande
local scheduled = {}      -- [id] = true : reponse deja programmee
local lastVectorSent = -math.huge
Sync.peers = {}           -- [nom] = { seen = instant, proto = n }

local function now() return (GetServerTime and GetServerTime()) or time() end
local function clock() return (GetTime and GetTime()) or now() end

local ALLOWED = { v = true, id = true, a = true, n = true, c = true, s = true, t = true, k = true, g = true,
    loc = true, pt = true, prov = true, miss = true, refs = true, occ = true, x = true, vis = true, src = true,
    p = true, ded = true }
local PROVS = { OBS = true, LOG = true, MAN = true, DED = true, GEN = true }

------------------------------------------------------------------------
-- Vecteur et trous
------------------------------------------------------------------------
-- { [auteur] = { max = plus grande sequence contigue, top = plus grande sequence connue } }
local function computeVector()
    if vectorCache then return vectorCache end
    local guildKey = ns.Context.GuildKey()
    local seqs = {}
    for _, ev in pairs(ns.db.events) do
        if ev.vis == "G" and ev.s and ev.g == guildKey then
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
-- Validation des evenements recus
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
    if not guildKey or ev.g ~= guildKey then return nil, "autre guilde" end
    if type(ev.p) ~= "table" then return nil, "contenu" end
    if ev.prov ~= nil and not PROVS[ev.prov] then return nil, "provenance" end
    local clean = {}
    for k, v in pairs(ev) do if ALLOWED[k] then clean[k] = v end end
    return clean
end

-- Copie envoyable : uniquement les champs du schema (pas les annotations locales).
-- La cle de guilde voyage une seule fois, dans l'enveloppe du message.
local function wireCopy(ev)
    local out = {}
    for k, v in pairs(ev) do if ALLOWED[k] and k ~= "g" then out[k] = v end end
    return out
end

------------------------------------------------------------------------
-- Emission
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
        return encode({ o = "V", pr = Sync.PROTO, v = v })
    end, P.CONTROL)
    return true
end

-- Programme l'envoi d'un evenement ; annule si quelqu'un l'a diffuse entre-temps.
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
        end, (ns.db.events[id] and ns.db.events[id].k == "ARTICLE") and P.BULK or P.EVENT)
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

-- Demande ce qui manque pour un auteur, d'apres ce qu'on sait exister.
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
-- Reception
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
    -- Il lui manque des choses : on annonce notre vecteur pour qu'il puisse demander.
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
    if not ev then
        Sync.rejected = (Sync.rejected or 0) + 1
        Sync.lastReject = why
        return
    end
    seenOnWire[ev.id] = clock()
    if ns.db.events[ev.id] then return end
    local from = Transport.ShortName(sender)
    -- "verifie" : recu de l'auteur lui-meme ; sinon relaye par un autre membre.
    ev.rx = { by = from, direct = (from == ev.n) or nil, at = now() }
    if ns.Store.Insert(ev) then
        Sync.received = (Sync.received or 0) + 1
        vectorCache = nil
        requestMissing(ev.a, ev.s - 1)
    end
end

local function onMessage(sender, text)
    local msg = Ser.Decode(text)
    if type(msg) ~= "table" or type(msg.o) ~= "string" then return end
    local guildKey = ns.Context.GuildKey()
    if not guildKey or msg.g ~= guildKey then return end
    local name = Transport.ShortName(sender)
    Sync.peers[name] = { seen = now(), proto = msg.pr or (Sync.peers[name] and Sync.peers[name].proto) }
    local h = handlers[msg.o]
    if h then h(sender, msg) end
end
Sync.OnMessage = onMessage

------------------------------------------------------------------------
-- Cycle de vie
------------------------------------------------------------------------
function Sync:OnLogin()
    Transport.Init()
    Transport.SetHandler(onMessage)
    ns.EventBus.Subscribe("CHRONICLE_EVENT", function(ev)
        vectorCache = nil
        -- Nouvel evenement public cree ici : diffuse tout de suite (la file attend si besoin).
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
