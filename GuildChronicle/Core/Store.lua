-- Core/Store.lua : creation, deduplication et stockage des evenements ; contexte de jeu.
-- Le jeu de donnees actif est soit le reel (SavedVariables), soit la demo (memoire seulement).
local _, ns = ...

local Store = {}
ns.Store = Store

------------------------------------------------------------------------
-- Valeurs "secretes" (restrictions Midnight / Forever) : jamais stockees.
------------------------------------------------------------------------
function ns.Safe(v)
    if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
    return v
end

local function pack(...) return { n = select("#", ...), ... } end

-- Appel protege : nil si la fonction n'existe pas ou echoue ; valeurs secretes -> nil.
local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local res = pack(pcall(fn, ...))
    if not res[1] then return nil end
    for i = 2, res.n do res[i] = ns.Safe(res[i]) end
    return unpack(res, 2, res.n)
end
ns.Try = try

------------------------------------------------------------------------
-- Contexte : qui, ou, avec qui
------------------------------------------------------------------------
local Context = {}
ns.Context = Context

function Context.Me()
    local guid = try(UnitGUID, "player") or "Player-0-UNKNOWN"
    local name = try(UnitName, "player") or "?"
    local _, class = try(UnitClass, "player")
    return guid, name, class
end

function Context.GuildKey()
    if not try(IsInGuild) then return nil end
    local guildName = try(GetGuildInfo, "player")
    if not guildName then return nil end
    local realm = try(GetNormalizedRealmName) or try(GetRealmName) or ""
    return guildName .. "-" .. realm, guildName
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
        -- Coordonnees : seulement hors instance (l'API ne les donne pas en instance).
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

-- Membres du groupe observes (jamais inventes) : { { g = guid, n = nom }, ... }
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
-- Stockage reel
------------------------------------------------------------------------
local cache -- liste triee (recent d'abord), invalidee a chaque ajout

local function nextSeq(guid, public)
    local seq = ns.db.seq[guid] or { public = 0, private = 0 }
    ns.db.seq[guid] = seq
    if public then seq.public = seq.public + 1; return seq.public end
    seq.private = seq.private + 1
    return seq.private
end

-- Construit un evenement (sans l'enregistrer). opts : prov, miss, refs, occ, x, pt, loc, t
function Store.Build(kind, payload, opts)
    opts = opts or {}
    local def = ns.Types.Get(kind)
    local mode = ns.char.privacy[def.cat] or "P"
    if mode == "OFF" then return nil end
    local guid, name, class = Context.Me()
    local public = (mode == "G")
    local s = nextSeq(guid, public)
    local ev = {
        v = 1,
        id = public and (guid .. ":" .. s) or (guid .. ":p" .. s),
        a = guid, n = name, c = class,
        s = public and s or nil,
        t = opts.t or (GetServerTime and GetServerTime()) or time(),
        k = kind,
        g = Context.GuildKey(),
        loc = opts.loc or Context.Location(),
        pt = opts.pt, prov = opts.prov or "OBS", miss = opts.miss, refs = opts.refs,
        occ = opts.occ, x = opts.x,
        vis = public and "G" or "P",
        src = (opts.prov == "MAN") and "M" or "A",
        p = payload or {},
    }
    return ev
end

-- Insere un evenement deja construit (local ou recu). Renvoie false si doublon.
function Store.Insert(ev)
    if not ev or not ev.id or ns.db.events[ev.id] then return false end
    ns.db.events[ev.id] = ev
    cache = nil
    ns.EventBus.Publish("CHRONICLE_EVENT", ev)
    return true
end

-- Raccourci pour les collecteurs : construit + insere dans le jeu reel.
function Store.Add(kind, payload, opts)
    local ev = Store.Build(kind, payload, opts)
    if ev and Store.Insert(ev) then return ev end
    return nil
end

-- Pour les formulaires : ajoute au jeu de donnees actif (demo ou reel).
function Store.AddManual(kind, payload, opts)
    opts = opts or {}
    opts.prov = opts.prov or "MAN"
    if ns.char.ui.demo then
        local ev = Store.Build(kind, payload, opts)
        if ev then ns.Demo:Insert(ev) end
        return ev
    end
    return Store.Add(kind, payload, opts)
end

local function realEvents()
    if not cache then
        cache = {}
        for _, ev in pairs(ns.db.events) do table.insert(cache, ev) end
        table.sort(cache, function(a, b)
            if a.t ~= b.t then return a.t > b.t end
            return a.id > b.id
        end)
    end
    return cache
end

-- Jeu de donnees actif, meme forme en demo et en reel.
function Store.Dataset()
    if ns.char.ui.demo then return ns.Demo:Get() end
    local guid = Context.Me()
    return {
        isDemo = false,
        me = guid,
        guildKey = Context.GuildKey(),
        events = realEvents(),
        articles = ns.db.articles,
        collection = ns.db.collection,
        boosters = 0,
        founders = {},
        legends = {},
        roster = Store.Roster(),
    }
end

-- Roster de guilde (membres sans l'addon inclus, sans statistiques).
function Store.Roster()
    local roster = {}
    local n = try(GetNumGuildMembers)
    if not n or n == 0 then return roster end
    for i = 1, n do
        local name, _, rankIndex, level, _, _, _, _, online, _, class = try(GetGuildRosterInfo, i)
        if name then
            table.insert(roster, { name = (name:gsub("%-.*$", "")), rank = rankIndex, level = level, class = class, online = online })
        end
    end
    return roster
end

function Store.Count()
    local n = 0
    for _ in pairs(ns.db.events) do n = n + 1 end
    return n
end
