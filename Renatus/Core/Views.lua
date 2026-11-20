-- Core/Views.lua: views computed from events (nothing is stored here).
local _, ns = ...

local Views = {}
ns.Views = Views

local DAY = 86400
local AGGREGATE_WINDOW = 15 * 60

local function lower(s) return s and string.lower(s) or "" end
-- Author display name (full roster name on WoW Forever).
local function who(ev) return ns.Types.Who(ev) end

function Views.Now() return (GetServerTime and GetServerTime()) or time() end

------------------------------------------------------------------------
-- Filters: { author, category, kind, since, search, guild }
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
-- Display aggregation: same occurrence key within 15 min = a single row.
-- Displayed participants are those who actually emitted the event.
------------------------------------------------------------------------
function Views.Aggregate(events)
    local items, byOcc = {}, {}
    for _, ev in ipairs(events) do
        local group = ev.occ and byOcc[ev.occ]
        if group and math.abs(group.ev.t - ev.t) <= AGGREGATE_WINDOW then
            table.insert(group.events, ev)
            if not group.seen[ev.a] then
                group.seen[ev.a] = true
                table.insert(group.authors, who(ev))
            end
        else
            local item = { ev = ev, events = { ev }, authors = { who(ev) }, seen = { [ev.a] = true } }
            if ev.occ then byOcc[ev.occ] = item end
            table.insert(items, item)
        end
    end
    return items
end

------------------------------------------------------------------------
-- Members and statistics
------------------------------------------------------------------------
local STAT_OF = {
    DEATH = "deaths", BOSS_KILL = "bosses", EXPEDITION = "expeditions", ZONE_FIRST_VISIT = "zones",
    QUEST_DONE = "quests", ANECDOTE = "anecdotes", LEVEL_UP = "levels", PVP_CLASH = "pvp",
}

-- Unofficial titles: explicit and reproducible conditions.
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
        table.insert(m.events, ev) -- already sorted from most recent to oldest
        local stat = STAT_OF[ev.k]
        if stat then m.stats[stat] = m.stats[stat] + 1 end
        if ev.k == "LEVEL_UP" and (ev.p.lvl or 0) > (m.level or 0) then m.level = ev.p.lvl end
        if not m.last or ev.t > m.last then m.last = ev.t end
    end
    -- Roster: "Dakey Dak" on WoW Forever, "Dakey" in events. Matched by GUID, then
    -- name, then first name; the full roster name is kept for display (m.display).
    for _, r in ipairs(ds.roster or {}) do
        local m = (r.guid and byGuid[r.guid]) or byName[r.name] or (not r.guid and r.first and byName[r.first]) or nil
        if m then
            m.display = r.name
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
    for _, m in ipairs(list) do
        m.display = m.display or m.name
        m.titles = Views.TitlesOf(m)
    end
    table.sort(list, function(a, b)
        if a.hasAddon ~= b.hasAddon then return a.hasAddon end
        return (a.display or "") < (b.display or "")
    end)
    return list, byGuid
end

-- Shared adventures: aggregated groups where both emitted the event,
-- plus events of one that list the other as an observed participant.
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
-- Wanted Board: computed enemy records
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
    -- Oldest to newest so that the latest observations win.
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
                e.members[p.member or who(ev)] = true
                table.insert(e.encounters, 1, ev)
            end
            if ev.k == "PVP_CLASH" then
                if p.result == "win" then e.wins[ev.prov] = (e.wins[ev.prov] or 0) + 1
                elseif p.result == "loss" then
                    e.losses[ev.prov] = (e.losses[ev.prov] or 0) + 1
                    e.killedMembers[p.member or who(ev)] = true
                end
            end
            if ev.k == "ENEMY_NOTE" then
                if p.nickname then table.insert(e.nicknames, 1, { text = p.nickname, by = who(ev), t = ev.t }) end
                if p.note then table.insert(e.notes, 1, { text = p.note, by = who(ev), t = ev.t, prov = ev.prov }) end
                if p.sworn then e.swornVotes[ev.a or ev.n or "?"] = true end
            end
        elseif ev.k == "DEATH" then
            local k = type(p.killer) == "table" and p.killer or nil
            local killerKey = k and k.pl and type(k.n) == "string" and enemyKey(k.n)
            if killerKey then
                -- Killed by a player: a verified defeat (combat log or death recap).
                local e = get(k.n)
                see(e, "class", k.c, ev.t)
                see(e, "race", k.ra, ev.t)
                see(e, "realm", k.r, ev.t)
                e.lastSeen, e.lastZone = ev.t, ns.Types.Zone(ev)
                e.members[who(ev)] = true
                e.losses[ev.prov] = (e.losses[ev.prov] or 0) + 1
                e.killedMembers[who(ev)] = true
                table.insert(e.encounters, 1, ev)
            end
            for _, name in ipairs(p.enemies or {}) do
                if enemyKey(name) ~= killerKey then
                    local e = byKey[enemyKey(name)] or get(name)
                    e.presentAtDeaths = e.presentAtDeaths + 1
                    table.insert(e.encounters, 1, ev)
                end
            end
        end
    end
    -- Rival guild: every member known from the armory is listed, met or not
    -- (in game "Ladou", on the armory "Ladou Pipø"); anyone seen in that guild is flagged.
    if ds.rival then
        local rival = lower(ds.rival)
        for _, e in ipairs(list) do
            if e.guild and lower(e.guild) == rival then e.rival = true end
        end
        local roster = ds.rivalRoster
        if roster and type(roster.members) == "table" then
            local at = roster.at or 0
            for _, m in ipairs(roster.members) do
                if type(m) == "table" and type(m.n) == "string" then
                    local e
                    for _, x in ipairs(list) do
                        if ns.GuildConfig.SameCharacter(x.name, m.n) then e = x break end
                    end
                    e = e or get(m.n:match("^(%S+)") or m.n)
                    e.rival, e.armory, e.fullName = true, m, m.n
                    e.guild = e.guild or roster.guild
                    e.class = e.class or m.cl
                    e.race = e.race or m.ra
                    if m.lvl and (not e.levelAt or at > e.levelAt) then
                        e.level, e.levelAt, e.levelSrc = m.lvl, at, "armory"
                    end
                end
            end
        end
    end
    for _, e in ipairs(list) do
        local votes, killed = 0, 0
        for _ in pairs(e.swornVotes) do votes = votes + 1 end
        for _ in pairs(e.killedMembers) do killed = killed + 1 end
        local verifiedLosses = e.losses.OBS + e.losses.LOG
        -- Explicit rule (docs/ARCHITECTURE.md §6.2)
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
    -- Met most recently first; then never met (rival guild), highest level first.
    table.sort(list, function(a, b)
        if (a.lastSeen or 0) ~= (b.lastSeen or 0) then return (a.lastSeen or 0) > (b.lastSeen or 0) end
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
        return a.key < b.key
    end)
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
-- Gazette: articles (ARTICLE events) and votes (VOTE, one per member per week)
------------------------------------------------------------------------
function Views.WeekKey(t) return date("%Y-%W", t) end

function Views.Articles(events, meGuid)
    local list, byId = {}, {}
    for _, ev in ipairs(events) do
        if ev.k == "ARTICLE" then
            local p = ev.p or {}
            local a = { id = ev.id, t = ev.t, kind = p.format, title = p.title, body = p.body, style = p.style,
                refs = ev.refs, author = who(ev), ia = (p.ia == true) or nil, week = Views.WeekKey(ev.t), votes = 0, ev = ev }
            byId[ev.id] = a
            table.insert(list, a)
        end
    end
    -- Each member's latest vote for a given week wins (events: most recent first).
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

-- Death causes from combat logs: [death id] = DEATH_CAUSE event.
function Views.DeathCauses(events)
    local causes = {}
    for _, ev in ipairs(events) do
        if ev.k == "DEATH_CAUSE" and ev.refs and ev.refs[1] and not causes[ev.refs[1]] then
            causes[ev.refs[1]] = ev
        end
    end
    return causes
end
