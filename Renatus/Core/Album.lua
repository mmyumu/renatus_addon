-- Core/Album.lua : catalogue de cartes (genere a partir des evenements) et boosters deterministes.
-- Aucun combat de cartes : collection et echanges uniquement.
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

Album.SERIES = {
    { key = "founders", label = "Fondateurs" },
    { key = "members", label = "Membres" },
    { key = "sworn", label = "Ennemis jurés" },
    { key = "expeditions", label = "Expéditions" },
    { key = "faits", label = "Faits divers" },
    { key = "legends", label = "Légendes" },
}

Album.BOOSTER_SIZE = 5

-- Hash djb2 sur 32 bits, sans operations binaires (Lua 5.1 portable).
function Album.Hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + string.byte(str, i)) % 4294967296 end
    return h
end

-- Generateur Park-Miller : meme graine -> meme suite, partout.
local function rng(seed)
    local state = seed % 2147483646 + 1
    return function()
        state = (state * 16807) % 2147483647
        return state
    end
end

-- Variante de carte "Membre" : la rarete est celle de la variante, pas de la personne.
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

function Album.Catalogue(ds)
    local cards = {}
    local function add(card) table.insert(cards, card) end

    for _, f in ipairs(ds.founders or {}) do
        add({ id = "F:" .. f.name, series = "founders", rarity = "rare", name = f.name, class = f.class,
            flavor = f.flavor or "Était là au commencement." })
    end

    local members = ns.Views.Members(ds)
    for _, m in ipairs(members) do
        if m.hasAddon and m.guid and not (ds.optOut and ds.optOut[m.guid]) then
            for _, variant in ipairs(MEMBER_VARIANTS) do
                add({ id = "M:" .. m.guid .. ":" .. variant.rarity, series = "members", rarity = variant.rarity,
                    name = m.name, class = m.class, flavor = variant.flavor(m) })
            end
        end
    end

    for _, e in ipairs(ns.Views.Enemies(ds)) do
        if e.sworn then
            add({ id = "E:" .. e.key, series = "sworn", rarity = "rare", name = e.name, class = e.class,
                flavor = e.nickname and ("« " .. e.nickname .. " »") or (e.swornReason or "Ennemi juré.") })
        end
    end

    local seenBoss = {}
    for _, item in ipairs(ns.Views.Aggregate(ds.events)) do
        local ev = item.ev
        if ev.k == "BOSS_KILL" and #item.authors >= 2 then
            local key = tostring(ev.p.enc or ev.p.name)
            if not seenBoss[key] then
                seenBoss[key] = true
                add({ id = "X:" .. (ev.occ or ev.id), series = "expeditions", rarity = "epic",
                    name = ev.p.name or "Boss", icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
                    flavor = "Vaincu par " .. table.concat(item.authors, ", ") .. "." })
            end
        elseif ev.k == "ANECDOTE" then
            add({ id = "A:" .. ev.id, series = "faits", rarity = "uncommon", name = ev.p.title or "Anecdote",
                icon = "Interface\\Icons\\INV_Scroll_03", flavor = ev.p.desc or "" })
        end
    end

    for _, l in ipairs(ds.legends or {}) do
        add({ id = l.id, series = "legends", rarity = "legendary", name = l.name,
            icon = l.icon or "Interface\\Icons\\INV_Misc_Rune_01", flavor = l.flavor })
    end

    table.sort(cards, function(a, b) return a.id < b.id end)
    local ids = {}
    for i, c in ipairs(cards) do ids[i] = c.id end
    cards.version = Album.Hash(table.concat(ids, "|"))
    return cards
end

-- Contenu d'un booster : derive uniquement de son identifiant et de la version du catalogue.
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
