-- Core/Views.lua : vues calculees a partir des evenements (rien n'est stocke ici).
local _, ns = ...

local Views = {}
ns.Views = Views

local DAY = 86400
local AGGREGATE_WINDOW = 15 * 60

local function lower(s) return s and string.lower(s) or "" end

function Views.Now() return (GetServerTime and GetServerTime()) or time() end

------------------------------------------------------------------------
-- Filtres : { author, category, kind, since, search, guild }
------------------------------------------------------------------------
function Views.Filter(events, f)
    f = f or {}
    local out = {}
    local search = f.search and f.search ~= "" and lower(f.search) or nil
    for _, ev in ipairs(events) do
        local keep = true
        if f.author and ev.a ~= f.author then keep = false end
        if keep and f.authorName and ev.n ~= f.authorName then keep = false end
        if keep and f.guild and ev.g ~= f.guild then keep = false end
        if keep and f.kind and ev.k ~= f.kind then keep = false end
        if keep and not f.kind and ns.Types.Get(ev.k).hidden then keep = false end
        if keep and f.category and ns.Types.Get(ev.k).cat ~= f.category then keep = false end
        if keep and f.since and ev.t < f.since then keep = false end
        if keep and f.minImportance and ns.Types.Get(ev.k).importance < f.minImportance then keep = false end
        if keep and search then
            local hay = lower(ns.Types.Describe(ev, true)) .. " " .. lower(ns.Types.Zone(ev))
                .. " " .. lower(ev.loc and ev.loc.sz) .. " " .. lower(ev.p and ev.p.desc)
            keep = string.find(hay, search, 1, true) ~= nil
        end
        if keep then table.insert(out, ev) end
    end
    return out
end

function Views.PeriodStart(key)
    local now = Views.Now()
    if key == "today" then
        local d = date("*t", now)
        return now - (d.hour * 3600 + d.min * 60 + d.sec)
    elseif key == "week" then return now - 7 * DAY
    elseif key == "month" then return now - 30 * DAY
    end
    return nil
end

------------------------------------------------------------------------
-- Agregation a l'affichage : meme cle d'occurrence a moins de 15 min = une seule ligne.
-- Les participants affiches sont ceux qui ont reellement emis l'evenement.
------------------------------------------------------------------------
function Views.Aggregate(events)
    local items, byOcc = {}, {}
    for _, ev in ipairs(events) do
        local group = ev.occ and byOcc[ev.occ]
        if group and math.abs(group.ev.t - ev.t) <= AGGREGATE_WINDOW then
            table.insert(group.events, ev)
            if not group.seen[ev.a] then
                group.seen[ev.a] = true
                table.insert(group.authors, ev.n or "?")
            end
        else
            local item = { ev = ev, events = { ev }, authors = { ev.n or "?" }, seen = { [ev.a] = true } }
            if ev.occ then byOcc[ev.occ] = item end
            table.insert(items, item)
        end
    end
    return items
end

------------------------------------------------------------------------
-- Membres et statistiques
------------------------------------------------------------------------
local STAT_OF = {
    DEATH = "deaths", BOSS_KILL = "bosses", EXPEDITION = "expeditions", ZONE_FIRST_VISIT = "zones",
    QUEST_DONE = "quests", ANECDOTE = "anecdotes", LEVEL_UP = "levels", PVP_CLASH = "pvp",
}

-- Titres officieux : conditions explicites et reproductibles.
Views.TITLES = {
    { title = "Habitué du cimetière", rule = "10 morts ou plus", test = function(s) return s.deaths >= 10 end },
    { title = "Explorateur infatigable", rule = "15 zones découvertes ou plus", test = function(s) return s.zones >= 15 end },
    { title = "Fléau des boss", rule = "10 boss vaincus ou plus", test = function(s) return s.bosses >= 10 end },
    { title = "Pilier d'expédition", rule = "10 expéditions ou plus", test = function(s) return s.expeditions >= 10 end },
    { title = "Conteur de la guilde", rule = "5 anecdotes ou plus", test = function(s) return s.anecdotes >= 5 end },
    { title = "Bagarreur", rule = "5 affrontements PvP ou plus", test = function(s) return s.pvp >= 5 end },
    { title = "Survivant improbable", rule = "niveau 20+ avec au plus 1 mort",
        test = function(s, m) return (m.level or 0) >= 20 and s.deaths <= 1 end },
}

function Views.TitlesOf(member)
    local out = {}
    for _, t in ipairs(Views.TITLES) do
        if t.test(member.stats, member) then table.insert(out, t) end
    end
    return out
end

local function newMember(guid, name, class)
    return {
        guid = guid, name = name, class = class, hasAddon = true, events = {},
        stats = { deaths = 0, bosses = 0, expeditions = 0, zones = 0, quests = 0, anecdotes = 0, levels = 0, pvp = 0 },
    }
end

function Views.Members(ds)
    local byGuid, byName, list = {}, {}, {}
    for _, ev in ipairs(ds.events) do
        local m = byGuid[ev.a]
        if not m then
            m = newMember(ev.a, ev.n, ev.c)
            byGuid[ev.a] = m
            byName[ev.n or ""] = m
            table.insert(list, m)
        end
        table.insert(m.events, ev) -- deja tries du plus recent au plus ancien
        local stat = STAT_OF[ev.k]
        if stat then m.stats[stat] = m.stats[stat] + 1 end
        if ev.k == "LEVEL_UP" and (ev.p.lvl or 0) > (m.level or 0) then m.level = ev.p.lvl end
        if not m.last or ev.t > m.last then m.last = ev.t end
    end
    for _, r in ipairs(ds.roster or {}) do
        local m = byName[r.name]
        if m then
            m.level = r.level or m.level
            m.rank, m.online = r.rank, r.online
            m.class = m.class or r.class
        else
            m = newMember(nil, r.name, r.class)
            m.hasAddon = false
            m.level, m.rank, m.online = r.level, r.rank, r.online
            byName[r.name] = m
            table.insert(list, m)
        end
    end
    for _, m in ipairs(list) do m.titles = Views.TitlesOf(m) end
    table.sort(list, function(a, b)
        if a.hasAddon ~= b.hasAddon then return a.hasAddon end
        return (a.name or "") < (b.name or "")
    end)
    return list, byGuid
end

-- Aventures partagees : groupes agreges ou les deux ont emis l'evenement,
-- plus les evenements de l'un qui citent l'autre comme participant observe.
function Views.Shared(ds, guidA, guidB)
    if not guidA or not guidB or guidA == guidB then return nil end
    local shared = { expeditions = 0, bosses = 0 }
    local counted = {}
    for _, item in ipairs(Views.Aggregate(ds.events)) do
        local hasA, hasB = false, false
        for _, ev in ipairs(item.events) do
            if ev.a == guidA then hasA = true end
            if ev.a == guidB then hasB = true end
            for _, p in ipairs(ev.pt or {}) do
                if p.g == guidA then hasA = true end
                if p.g == guidB then hasB = true end
            end
        end
        if hasA and hasB and not counted[item] then
            counted[item] = true
            if item.ev.k == "EXPEDITION" then shared.expeditions = shared.expeditions + 1 end
            if item.ev.k == "BOSS_KILL" then shared.bosses = shared.bosses + 1 end
        end
    end
    return shared
end

------------------------------------------------------------------------
-- Wanted Board : fiches ennemies calculees
------------------------------------------------------------------------
local function enemyKey(name) return lower(name) end
Views.EnemyKey = enemyKey

local function emptyRecord() return { OBS = 0, LOG = 0, MAN = 0, DED = 0 } end

function Views.Enemies(ds)
    local byKey, list = {}, {}
    local function get(name)
        local key = enemyKey(name)
        local e = byKey[key]
        if not e then
            e = { key = key, name = name, encounters = {}, notes = {}, nicknames = {}, members = {},
                wins = emptyRecord(), losses = emptyRecord(), presentAtDeaths = 0, swornVotes = {},
                killedMembers = {} }
            byKey[key] = e
            table.insert(list, e)
        end
        return e
    end
    local function see(e, field, value, t)
        if value ~= nil and (not e[field .. "At"] or t > e[field .. "At"]) then
            e[field], e[field .. "At"] = value, t
        end
    end
    -- Du plus ancien au plus recent pour que les dernieres observations l'emportent.
    for i = #ds.events, 1, -1 do
        local ev = ds.events[i]
        local p = ev.p or {}
        if ev.k == "ENEMY_SEEN" or ev.k == "ENEMY_NOTE" or ev.k == "PVP_CLASH" or ev.k == "WANTED" then
            local e = get(p.name or "?")
            see(e, "guild", p.guild, ev.t)
            see(e, "class", p.class, ev.t)
            see(e, "race", p.race, ev.t)
            see(e, "realm", p.realm, ev.t)
            if p.level then see(e, "level", p.level, ev.t) end
            if ev.k == "ENEMY_SEEN" or ev.k == "PVP_CLASH" then
                e.lastSeen, e.lastZone = ev.t, ns.Types.Zone(ev)
                e.members[p.member or ev.n or "?"] = true
                table.insert(e.encounters, 1, ev)
            end
            if ev.k == "PVP_CLASH" then
                if p.result == "win" then e.wins[ev.prov] = (e.wins[ev.prov] or 0) + 1
                elseif p.result == "loss" then
                    e.losses[ev.prov] = (e.losses[ev.prov] or 0) + 1
                    e.killedMembers[p.member or ev.n or "?"] = true
                end
            end
            if ev.k == "ENEMY_NOTE" then
                if p.nickname then table.insert(e.nicknames, 1, { text = p.nickname, by = ev.n, t = ev.t }) end
                if p.note then table.insert(e.notes, 1, { text = p.note, by = ev.n, t = ev.t, prov = ev.prov }) end
                if p.sworn then e.swornVotes[ev.n or "?"] = true end
            end
        elseif ev.k == "DEATH" and p.enemies then
            for _, name in ipairs(p.enemies) do
                local e = byKey[enemyKey(name)] or get(name)
                e.presentAtDeaths = e.presentAtDeaths + 1
                table.insert(e.encounters, 1, ev)
            end
        end
    end
    for _, e in ipairs(list) do
        local votes, killed = 0, 0
        for _ in pairs(e.swornVotes) do votes = votes + 1 end
        for _ in pairs(e.killedMembers) do killed = killed + 1 end
        local verifiedLosses = e.losses.OBS + e.losses.LOG
        -- Regle explicite (docs/ARCHITECTURE.md §6.2)
        e.sworn = votes >= 2 or verifiedLosses >= 5 or killed >= 3
        e.swornReason = (votes >= 2 and (votes .. " membres l'ont désigné"))
            or (verifiedLosses >= 5 and (verifiedLosses .. " défaites vérifiées"))
            or (killed >= 3 and (killed .. " membres vaincus")) or nil
        e.nickname = e.nicknames[1] and e.nicknames[1].text or nil
        local names = {}
        for n in pairs(e.members) do table.insert(names, n) end
        table.sort(names)
        e.memberList = names
    end
    table.sort(list, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
    return list, byKey
end

function Views.Total(record) return record.OBS + record.LOG + record.MAN end

function Views.Wanted(ds)
    local enemies, byKey = Views.Enemies(ds)
    local closed = {}
    for _, ev in ipairs(ds.events) do
        if ev.k == "WANTED_CLOSE" and ev.refs then closed[ev.refs[1]] = ev end
    end
    local posters = {}
    for _, ev in ipairs(ds.events) do
        if ev.k == "WANTED" and not closed[ev.id] then
            table.insert(posters, { ev = ev, enemy = byKey[enemyKey(ev.p.name)] })
        end
    end
    return posters, enemies
end

------------------------------------------------------------------------
-- Gazette : articles (evenements ARTICLE) et votes (VOTE, un par membre et par semaine)
------------------------------------------------------------------------
function Views.WeekKey(t) return date("%Y-%W", t) end

function Views.Articles(events, meGuid)
    local list, byId = {}, {}
    for _, ev in ipairs(events) do
        if ev.k == "ARTICLE" then
            local p = ev.p or {}
            local a = { id = ev.id, t = ev.t, kind = p.format, title = p.title, body = p.body, style = p.style,
                refs = ev.refs, author = ev.n, ia = (p.ia == true) or nil, week = Views.WeekKey(ev.t), votes = 0, ev = ev }
            byId[ev.id] = a
            table.insert(list, a)
        end
    end
    -- Le dernier vote de chaque membre pour une semaine donnee l'emporte (events : recent d'abord).
    local counted = {}
    for _, ev in ipairs(events) do
        if ev.k == "VOTE" and ev.refs and ev.refs[1] then
            local key = ev.a .. "|" .. tostring(ev.p.week)
            if not counted[key] then
                counted[key] = true
                local a = byId[ev.refs[1]]
                if a then
                    a.votes = a.votes + 1
                    if ev.a == meGuid then a.voted = true end
                end
            end
        end
    end
    return list
end

-- Causes de mort issues des journaux de combat : [id de la mort] = evenement DEATH_CAUSE.
function Views.DeathCauses(events)
    local causes = {}
    for _, ev in ipairs(events) do
        if ev.k == "DEATH_CAUSE" and ev.refs and ev.refs[1] and not causes[ev.refs[1]] then
            causes[ev.refs[1]] = ev
        end
    end
    return causes
end
