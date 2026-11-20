-- Core/Album.lua: card catalogue (generated from events) and deterministic boosters.
-- No card battles: collection and trading only.
local _, ns = ...

local Album = {}
ns.Album = Album

Album.RARITIES = {
    { key = "common", label = "Commune", color = { 0.82, 0.82, 0.82 }, weight = 60 },
    { key = "uncommon", label = "Peu commune", color = { 0.12, 1, 0 }, weight = 25 },
    { key = "rare", label = "Rare", color = { 0, 0.44, 0.87 }, weight = 10 },
    { key = "epic", label = "Épique", color = { 0.64, 0.21, 0.93 }, weight = 4 },
    { key = "legendary", label = "Légendaire", color = { 1, 0.5, 0 }, weight = 1 },
}
local RARITY_INDEX = {}
for i, r in ipairs(Album.RARITIES) do RARITY_INDEX[r.key] = i end
Album.RARITY_INDEX = RARITY_INDEX

function Album.Rarity(key) return Album.RARITIES[RARITY_INDEX[key] or 1] end

-- Guild series (generated from events) then the fixed Azeroth set (Core/Cards.lua).
Album.SERIES = {
    { key = "members", label = "Membres", family = "guild" },
    { key = "founders", label = "Fondateurs", family = "guild" },
    { key = "expeditions", label = "Exploits", family = "guild" },
    { key = "une", label = "À la une", family = "guild" },
    { key = "faits", label = "Faits divers", family = "guild" },
    { key = "sworn", label = "Avis de recherche", family = "guild" },
    { key = "legends", label = "Légendes", family = "guild" },
}
for _, s in ipairs(ns.Cards.SERIES) do
    table.insert(Album.SERIES, { key = s.key, label = s.label, family = "azeroth" })
end

-- Boosters (docs/ARCHITECTURE.md §9.2, "generous" rule): 1 per day played,
-- +1 per level gained, boss defeated, outing with a guild member; at most 5 a day.
Album.DAILY_CAP = 5
Album.BONUS = { LEVEL_UP = true, BOSS_KILL = true }

Album.BOOSTER_SIZE = 5

-- 32-bit djb2 hash, without bitwise operators (portable Lua 5.1).
function Album.Hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + string.byte(str, i)) % 4294967296 end
    return h
end

-- Park-Miller generator: same seed -> same sequence, everywhere.
local function rng(seed)
    local state = seed % 2147483646 + 1
    return function()
        state = (state * 16807) % 2147483647
        return state
    end
end

-- "Member" card variant: rarity belongs to the variant, not to the person.
local MEMBER_VARIANTS = {
    { rarity = "common", flavor = function(m) return "Membre de la guilde." end },
    { rarity = "rare", flavor = function(m) return ("%d expéditions, %d boss vaincus."):format(m.stats.expeditions, m.stats.bosses) end },
    { rarity = "epic", flavor = function(m)
        local t = m.titles and m.titles[1]
        return t and ("« " .. t.title .. " »") or "Un destin encore à écrire."
    end },
    { rarity = "legendary", flavor = function(m)
        for _, ev in ipairs(m.events) do
            if ev.k == "ANECDOTE" then return "Souvenir : " .. (ev.p.title or "") end
        end
        return "Légende en devenir."
    end },
}

local function levelRarity(lvl)
    if lvl >= 60 then return "legendary" elseif lvl >= 50 then return "epic"
    elseif lvl >= 40 then return "rare" elseif lvl >= 20 then return "uncommon" end
    return "common"
end

function Album.Catalogue(ds)
    local cards = {}
    local function add(card) table.insert(cards, card) end

    for _, f in ipairs(ds.founders or {}) do
        add({ id = "F:" .. f.name, series = "founders", rarity = "rare", name = f.name, class = f.class,
            flavor = f.flavor or "Était là au commencement." })
    end

    -- Members: four variants each, plus a card every 10 levels reached.
    local members = ns.Views.Members(ds)
    for _, m in ipairs(members) do
        if m.hasAddon and m.guid and not (ds.optOut and ds.optOut[m.guid]) then
            for _, variant in ipairs(MEMBER_VARIANTS) do
                add({ id = "M:" .. m.guid .. ":" .. variant.rarity, series = "members", rarity = variant.rarity,
                    name = m.display or m.name, class = m.class, flavor = variant.flavor(m) })
            end
            local top = 0
            for _, ev in ipairs(m.events) do
                if ev.k == "LEVEL_UP" and (ev.p.lvl or 0) > top then top = ev.p.lvl end
            end
            for lvl = 10, top, 10 do
                add({ id = "L:" .. m.guid .. ":" .. lvl, series = "members", rarity = levelRarity(lvl),
                    name = (m.display or m.name) .. ", niveau " .. lvl, class = m.class,
                    flavor = lvl >= 60 and "Le sommet. La guilde s'incline (un peu)."
                        or ("Niveau " .. lvl .. " atteint. Le plus dur reste à venir, comme toujours.") })
            end
        end
    end

    -- Wanted: sworn enemies (epic) and enemies met often or who killed one of us.
    for _, e in ipairs(ns.Views.Enemies(ds)) do
        local losses = 0
        for _ in pairs(e.killedMembers or {}) do losses = losses + 1 end
        if e.sworn or losses > 0 or #e.encounters >= 3 then
            add({ id = "E:" .. e.key, series = "sworn", rarity = e.sworn and "epic" or (losses > 0 and "rare" or "uncommon"),
                name = e.name, class = e.class, icon = not e.class and "Interface\\Icons\\Ability_DualWield" or nil,
                flavor = e.nickname and ("« " .. e.nickname .. " »")
                    or (losses > 0 and ("A envoyé " .. losses .. " des nôtres au cimetière."))
                    or (e.swornReason or (#e.encounters .. " rencontres. Il commence à nous connaître.")) })
        end
    end

    local seenBoss = {}
    for _, item in ipairs(ns.Views.Aggregate(ds.events)) do
        local ev = item.ev
        local p = ev.p or {}
        if ev.k == "BOSS_KILL" then
            local key = tostring(p.enc or p.name)
            if not seenBoss[key] then
                seenBoss[key] = true
                add({ id = "X:" .. (ev.occ or ev.id), series = "expeditions", rarity = #item.authors >= 2 and "epic" or "rare",
                    name = p.name or "Boss", icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
                    flavor = "Vaincu par " .. table.concat(item.authors, ", ") .. "." })
            end
        elseif ev.k == "EXPEDITION" and ev.pt and #ev.pt >= 2 then
            local names = { ev.n }
            for _, x in ipairs(ev.pt) do names[#names + 1] = x.n end
            add({ id = "XP:" .. (ev.occ or ev.id), series = "expeditions", rarity = #ev.pt >= 4 and "epic" or "rare",
                name = p.inst or "Expédition", icon = "Interface\\Icons\\INV_Misc_Map02",
                flavor = "Avec " .. table.concat(names, ", ") .. "." })
        elseif ev.k == "ANECDOTE" then
            add({ id = "A:" .. ev.id, series = "faits", rarity = "uncommon", name = p.title or "Anecdote",
                icon = "Interface\\Icons\\INV_Scroll_03", flavor = p.desc or "" })
        elseif ev.k == "DEATH" and type(p.killer) == "table" and p.killer.n then
            local k = p.killer
            add({ id = "D:" .. ev.id, series = "faits", rarity = k.pl and "rare" or "common",
                name = (ev.n or "?") .. (k.env and ", victime de " or ", tué par ") .. tostring(k.n),
                class = ev.c, icon = "Interface\\Icons\\Ability_Rogue_FeignDeath",
                flavor = k.sp and ("D'un coup de « " .. tostring(k.sp) .. " ». La guilde se souvient.")
                    or "Un moment de solitude, immortalisé." })
        end
    end

    -- Front pages: every published article; the front page of an issue is epic.
    local front = {}
    for _, e in ipairs((ns.Views.Editions(ds))) do
        if e.articles[1] then front[e.articles[1]] = true end
    end
    for _, a in ipairs(ds.articles or {}) do
        add({ id = "U:" .. a.id, series = "une", rarity = front[a] and "epic" or "rare",
            name = a.title or "Article", icon = "Interface\\Icons\\INV_Misc_Note_06",
            flavor = (a.kind and (a.kind .. ". ") or "") .. "Paru le " .. date("%d/%m/%Y", a.t or 0) .. "." })
    end

    for _, l in ipairs(ds.legends or {}) do
        add({ id = l.id, series = "legends", rarity = "legendary", name = l.name,
            icon = l.icon or "Interface\\Icons\\INV_Misc_Rune_01", flavor = l.flavor })
    end

    -- Fixed Azeroth set.
    for _, c in ipairs(ns.Cards.LIST) do add(c) end

    table.sort(cards, function(a, b) return a.id < b.id end)
    local ids = {}
    for i, c in ipairs(cards) do ids[i] = c.id end
    cards.version = Album.Hash(table.concat(ids, "|"))
    return cards
end

------------------------------------------------------------------------
-- Boosters earned, opened, and the resulting collection (real mode)
------------------------------------------------------------------------
local function dayKey(t) return date("%Y-%m-%d", t) end
Album.DayKey = dayKey

-- Boosters earned by `me`: from their own events and the days they played.
function Album.Earned(events, me, playedDays)
    local days = {}
    local function day(key)
        days[key] = days[key] or 1
        return key
    end
    for key in pairs(playedDays or {}) do day(key) end
    for _, ev in ipairs(events) do
        if ev.a == me and not ev.del then
            local def = ns.Types.Get(ev.k)
            if not def.hidden then
                local key = day(dayKey(ev.t))
                if Album.BONUS[ev.k] or (ev.k == "EXPEDITION" and ev.pt and #ev.pt > 0) then
                    days[key] = days[key] + 1
                end
            end
        end
    end
    local total = 0
    for _, n in pairs(days) do total = total + math.min(Album.DAILY_CAP, n) end
    return total
end

-- Own BOOSTER_OPEN events: number opened and card counts.
function Album.Opened(events, me)
    local opened, collection = 0, {}
    for _, ev in ipairs(events) do
        if ev.k == "BOOSTER_OPEN" and ev.a == me and not ev.del then
            opened = opened + 1
            for _, id in ipairs(ev.p.cards or {}) do collection[id] = (collection[id] or 0) + 1 end
        end
    end
    return opened, collection
end

-- Booster contents: derived only from its id and the catalogue version.
function Album.BoosterContents(cards, boosterId)
    if #cards == 0 then return {} end
    local byRarity = {}
    for _, c in ipairs(cards) do
        local i = RARITY_INDEX[c.rarity] or 1
        byRarity[i] = byRarity[i] or {}
        table.insert(byRarity[i], c)
    end
    local total = 0
    for _, r in ipairs(Album.RARITIES) do total = total + r.weight end
    local nextValue = rng(Album.Hash(boosterId .. "#" .. tostring(cards.version)))
    local result = {}
    for _ = 1, Album.BOOSTER_SIZE do
        local roll = nextValue() % total
        local idx = 1
        for i, r in ipairs(Album.RARITIES) do
            if roll < r.weight then idx = i break end
            roll = roll - r.weight
        end
        while idx > 1 and not byRarity[idx] do idx = idx - 1 end
        while not byRarity[idx] do idx = idx + 1 end
        local pool = byRarity[idx]
        table.insert(result, pool[(nextValue() % #pool) + 1])
    end
    return result
end

function Album.Progress(cards, collection, series)
    local owned, total, doubles = 0, 0, 0
    for _, c in ipairs(cards) do
        if not series or c.series == series then
            total = total + 1
            local n = collection[c.id] or 0
            if n > 0 then owned = owned + 1 end
            if n > 1 then doubles = doubles + n - 1 end
        end
    end
    return owned, total, doubles
end
