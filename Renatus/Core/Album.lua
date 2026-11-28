-- Core/Album.lua: card catalogue and deterministic boosters.
-- The catalogue is the same for everyone: the base set (Core/Cards.lua) plus the cards an
-- officer published (CARD_SET events, written with the gazette by the admin app and spread
-- by the sync like any event). Each card has a number and a publication date.
-- Before the first CARD_SET, the guild cards are computed locally from the journal as
-- before (Album.Legacy), so nothing disappears during the transition.
-- No card battles: collection only.
local _, ns = ...

local Album = {}
ns.Album = Album

Album.RARITIES = {
    { key = "common", label = "Commune", color = { 0.82, 0.82, 0.82 } },
    { key = "uncommon", label = "Peu commune", color = { 0.12, 1, 0 } },
    { key = "rare", label = "Rare", color = { 0, 0.44, 0.87 } },
    { key = "epic", label = "Épique", color = { 0.64, 0.21, 0.93 } },
    { key = "legendary", label = "Légendaire", color = { 1, 0.5, 0 } },
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
    { key = "butin", label = "Butin", family = "guild" },
    { key = "mobs", label = "Bestiaire de la guilde", family = "guild" },
    { key = "terreurs", label = "Terreurs", family = "guild" },
    { key = "legends", label = "Légendes", family = "guild" },
}
for _, s in ipairs(ns.Cards.SERIES) do
    table.insert(Album.SERIES, { key = s.key, label = s.label, family = "azeroth" })
end

-- Boosters (docs/ARCHITECTURE.md §9.2): a guild setting (GUILD_CONFIG.p.boosters,
-- published by an officer). Two forms:
--   - per source (current): { day, cap, src = { [source] = { qty, n, cap } } }: `day`
--     per day played, + `qty` boosters every `n` occurrences of each source, at most
--     `cap` a day from that source; at most `cap` a day in all. 0 always means 0 (n = 0
--     or qty = 0: the source gives nothing). `qty` absent (rules published before it
--     existed) = 1. No upper limit (only a sanity bound).
--   - legacy { day, bonus, cap }: `day` per day played, + `bonus` per level gained,
--     boss defeated, outing with a guild member; at most `cap` a day. Still read for the
--     days it was in force, and DEFAULT_RULE (before any setting) keeps that form so no
--     one loses boosters already earned.
Album.DEFAULT_RULE = { day = 1, bonus = 1, cap = 5, shiny = 20 }
Album.RULE_LIMITS = { day = { 0, 10 }, bonus = { 0, 10 }, cap = { 1, 20 } } -- legacy form only
Album.RULE_MAX = 1000000000
Album.BONUS = { LEVEL_UP = true, BOSS_KILL = true }

-- Last encounter of each Classic dungeon (DungeonEncounter ids; one per wing for
-- Scarlet Monastery, Dire Maul, Blackrock Spire and Stratholme; Season of Discovery
-- variants included).
Album.FINAL_ENCOUNTERS = {
    [2735] = true, -- Ragefire Chasm: Bazzalan
    [592] = true,  -- Wailing Caverns: Mutanus the Devourer
    [2747] = true, -- Deadmines: Edwin VanCleef
    [2755] = true, -- Shadowfang Keep: Archmage Arugal
    [2910] = true, [2767] = true, [2891] = true, -- Blackfathom Deeps: Aku'mai
    [2760] = true, -- Stormwind Stockade: Bazil Thredd
    [2772] = true, [2940] = true, -- Gnomeregan: Mekgineer Thermaplugg
    [2778] = true, -- Razorfen Kraul: Charlga Razorflank
    [2779] = true, -- Scarlet Monastery, Graveyard: Bloodmage Thalnos
    [447] = true,  -- Scarlet Monastery, Library: Arcanist Doan
    [448] = true,  -- Scarlet Monastery, Armory: Herod
    [450] = true,  -- Scarlet Monastery, Cathedral: High Inquisitor Whitemane
    [2785] = true, -- Razorfen Downs: Amnennar the Coldbringer
    [554] = true,  -- Uldaman: Archaedas
    [600] = true,  -- Zul'Farrak: Chief Ukorz Sandscalp
    [429] = true,  -- Maraudon: Princess Theradras
    [493] = true, [2959] = true, -- Sunken Temple: Shade of Eranikus
    [2790] = true, -- Blackrock Depths: Emperor Dagran Thaurissan
    [275] = true,  -- Lower Blackrock Spire: Overlord Wyrmthalak
    [3069] = true, -- Upper Blackrock Spire: General Drakkisath
    [346] = true,  -- Dire Maul East: Alzzin the Wildshaper
    [361] = true,  -- Dire Maul West: Prince Tortheldrin
    [368] = true,  -- Dire Maul North: King Gordok
    [478] = true,  -- Stratholme, living side: Balnazzar
    [484] = true,  -- Stratholme, undead side: Baron Rivendare
    [2801] = true, -- Scholomance: Darkmaster Gandling
    [3080] = true, -- Demon Fall Canyon: Azgaloth
}

local function isRaid(ev) return type(ev.loc) == "table" and ev.loc.it == "raid" end

-- Booster sources, in display order. `one`/`many`: wording for DescribeRule
-- ("1 par <one>", "1 tous les N <many>"); `fem` picks "toutes les".
Album.SOURCES = {
    { key = "level", label = "Niveau gagné", one = "niveau gagné", many = "niveaux gagnés",
        match = function(ev) return ev.k == "LEVEL_UP" end },
    { key = "dungeonEnd", label = "Boss de fin de donjon", one = "boss de fin de donjon", many = "boss de fin de donjon",
        match = function(ev)
            return ev.k == "BOSS_KILL" and not isRaid(ev) and Album.FINAL_ENCOUNTERS[tonumber(ev.p and ev.p.enc) or 0] == true
        end },
    { key = "dungeonBoss", label = "Boss de donjon (tous)", one = "boss de donjon", many = "boss de donjon",
        match = function(ev) return ev.k == "BOSS_KILL" and not isRaid(ev) end },
    { key = "raidBoss", label = "Boss de raid", one = "boss de raid", many = "boss de raid",
        match = function(ev) return ev.k == "BOSS_KILL" and isRaid(ev) end },
    { key = "outing", label = "Sortie avec la guilde", one = "sortie avec la guilde", many = "sorties avec la guilde", fem = true,
        match = function(ev) return ev.k == "EXPEDITION" and type(ev.pt) == "table" and #ev.pt > 0 end },
    { key = "honor", label = "Victoire honorable", one = "victoire honorable", many = "victoires honorables", fem = true,
        match = function(ev) return ev.k == "PVP_KILL" end },
    { key = "quest", label = "Quête rendue", one = "quête rendue", many = "quêtes rendues", fem = true,
        match = function(ev) return ev.k == "QUEST_DONE" end },
    { key = "zone", label = "Nouvelle zone", one = "nouvelle zone découverte", many = "nouvelles zones découvertes", fem = true,
        match = function(ev) return ev.k == "ZONE_FIRST_VISIT" end },
    { key = "rareItem", label = "Objet rare ou mieux", one = "objet rare ou mieux obtenu", many = "objets rares ou mieux obtenus",
        match = function(ev) return ev.k == "RARE_ITEM" end },
    { key = "reputation", label = "Rang de réputation", one = "rang de réputation atteint", many = "rangs de réputation atteints",
        match = function(ev) return ev.k == "REPUTATION" end },
    { key = "mount", label = "Monture obtenue", one = "monture obtenue", many = "montures obtenues", fem = true,
        match = function(ev) return ev.k == "MOUNT" end },
    { key = "duel", label = "Duel gagné", one = "duel gagné", many = "duels gagnés",
        match = function(ev) return ev.k == "DUEL" and type(ev.p) == "table" and ev.p.winner ~= nil and ev.p.winner == ev.n end },
}

-- A whole number from 0 to RULE_MAX (anything else: 0).
local function count(v)
    v = tonumber(v)
    if not v or v ~= v then return 0 end
    return math.max(0, math.min(Album.RULE_MAX, math.floor(v)))
end

-- Shiny cards: 1 card in `shiny` comes out of a booster shiny (0 = never). A rule
-- published before shiny cards existed has no such field: the default applies.
local function shinyRate(r)
    if type(r) == "table" and r.shiny ~= nil then return count(r.shiny) end
    return Album.DEFAULT_RULE.shiny
end

-- A valid rule from untrusted input. Per-source form: missing or bad values are 0.
-- Legacy form: missing or bad fields take the default, values kept within RULE_LIMITS.
function Album.Rule(r)
    local out = {}
    if type(r) == "table" and type(r.src) == "table" then
        out.day, out.cap, out.src = count(r.day), count(r.cap), {}
        local legacyBonus = 0
        for _, s in ipairs(Album.SOURCES) do
            local v = type(r.src[s.key]) == "table" and r.src[s.key] or {}
            out.src[s.key] = { qty = v.qty == nil and 1 or count(v.qty), n = count(v.n), cap = count(v.cap) }
            if out.src[s.key].n > 0 and out.src[s.key].qty > 0 and (s.key == "level" or s.key == "dungeonBoss" or s.key == "outing") then legacyBonus = 1 end
        end
        out.bonus = legacyBonus -- read only by clients older than the per-source form
        out.shiny = shinyRate(r)
        return out
    end
    for k, lim in pairs(Album.RULE_LIMITS) do
        local v = type(r) == "table" and tonumber(r[k])
        v = v and math.floor(v) or Album.DEFAULT_RULE[k]
        out[k] = math.max(lim[1], math.min(lim[2], v))
    end
    out.shiny = shinyRate(r)
    return out
end

-- The per-source equivalent of any rule (legacy rules: `bonus` per level, boss or
-- outing), to fill the admin form.
function Album.Expand(r)
    r = Album.Rule(r)
    if r.src then return r end
    local src = {}
    for _, s in ipairs(Album.SOURCES) do
        local on = r.bonus > 0 and (s.key == "level" or s.key == "dungeonBoss" or s.key == "raidBoss" or s.key == "outing")
        src[s.key] = { qty = on and r.bonus or 0, n = on and 1 or 0, cap = on and r.cap or 0 }
    end
    return Album.Rule({ day = r.day, cap = r.cap, src = src, shiny = r.shiny })
end

-- Boosters earned on one day under `rule`. `hits` = { [source key] = occurrences }
-- (per-source rule) and `bonus` = legacy bonus events that day.
function Album.DayTotal(rule, hits, bonus)
    if not rule.src then return math.min(rule.cap, rule.day + rule.bonus * (bonus or 0)) end
    local total = rule.day
    for key, s in pairs(rule.src) do
        local n = hits and hits[key] or 0
        if s.n > 0 and n > 0 then total = total + math.min(s.cap, math.floor(n / s.n) * s.qty) end
    end
    return math.min(rule.cap, total)
end

-- Rule in force on a day ("YYYY-MM-DD"): the last one published on or before that
-- day. `rules` = { { from = dayKey, rule = rule }, ... } sorted by `from`.
function Album.RuleOn(rules, key)
    local found = Album.DEFAULT_RULE
    for _, r in ipairs(rules or {}) do
        if r.from <= key then found = r.rule else break end
    end
    return found
end

function Album.DescribeRule(r)
    r = Album.Rule(r)
    local shiny = r.shiny > 0 and ("Brillantes : 1 carte sur %d."):format(r.shiny) or "Pas de carte brillante."
    if not r.src then
        return ("On en gagne %d par jour joué, +%d par niveau, boss vaincu ou sortie avec un membre de la guilde (%d par jour au plus).\n%s")
            :format(r.day, r.bonus, r.cap, shiny)
    end
    local lines = { ("On en gagne %d par jour joué, %d par jour au plus en tout."):format(r.day, r.cap) }
    for _, s in ipairs(Album.SOURCES) do
        local v = r.src[s.key]
        if v.n > 0 and v.qty > 0 and v.cap > 0 then
            local every = v.n == 1 and ("%d par %s"):format(v.qty, s.one)
                or ("%d %s les %d %s"):format(v.qty, s.fem and "toutes" or "tous", v.n, s.many)
            table.insert(lines, ("+ %s (%d par jour au plus)"):format(every, v.cap))
        end
    end
    table.insert(lines, shiny)
    return table.concat(lines, "\n")
end


------------------------------------------------------------------------
-- Shiny cards: a finish, not a rarity (as foils in a TCG). Any card can come out of a
-- booster shiny; same number, text and stats, only its look changes. A shiny copy is the
-- card id followed by "+": openings, trades and collections count it as a card of its own,
-- with no other change to their format.
------------------------------------------------------------------------
Album.SHINY_SUFFIX = "+"

function Album.ShinyId(id) return id .. Album.SHINY_SUFFIX end

-- Base id of a card id, and whether it is a shiny copy.
function Album.BaseId(id)
    if type(id) == "string" and #id > 1 and id:sub(-1) == Album.SHINY_SUFFIX then return id:sub(1, -2), true end
    return id, false
end

-- The shiny copy of a card (a new table; the card itself is left as is).
function Album.Shiny(card)
    if card.shiny then return card end
    local c = {}
    for k, v in pairs(card) do c[k] = v end
    c.id, c.baseId, c.shiny = Album.ShinyId(card.id), card.id, true
    return c
end

-- Copies of a card in a collection: normal, shiny.
function Album.Copies(collection, id)
    id = Album.BaseId(id)
    collection = collection or {}
    return collection[id] or 0, collection[Album.ShinyId(id)] or 0
end

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

------------------------------------------------------------------------
-- Force and endurance
------------------------------------------------------------------------
-- Creatures have a force and an endurance (0 to 12), items a bonus (+force / +endurance);
-- places, articles and events none. The base set sets them by hand (Core/Cards.lua), the
-- admin app's AI for the guild cards; otherwise this rule, the same as the app's
-- (admin/core/src/cards.rs, default_stats): a budget by rarity, split by class.
Album.STAT_MAX = 12
Album.STAT_BUDGET = { common = 4, uncommon = 6, rare = 9, epic = 13, legendary = 17 }
-- Share of the budget that goes to force.
Album.FORCE_SHARE = {
    WARRIOR = 0.45, PALADIN = 0.4, HUNTER = 0.55, ROGUE = 0.6, PRIEST = 0.35,
    SHAMAN = 0.5, MAGE = 0.65, WARLOCK = 0.6, DRUID = 0.5,
}
-- Guild series whose cards are someone who fights.
Album.FIGHTERS = { members = true, founders = true, sworn = true, mobs = true, terreurs = true }

function Album.DefaultStats(rarity, class)
    local budget = Album.STAT_BUDGET[rarity] or Album.STAT_BUDGET.common
    local fo = math.floor(budget * (Album.FORCE_SHARE[class or ""] or 0.5) + 0.5)
    return fo, budget - fo
end

-- force, endurance, isItem of a card; nil if it has none.
function Album.Stats(card)
    if card.fo and card.en then return card.fo, card.en, card.item and true or false end
    if Album.FIGHTERS[card.series] then
        local fo, en = Album.DefaultStats(card.rarity, card.class)
        return fo, en, false
    end
    return nil
end

local function levelRarity(lvl)
    if lvl >= 60 then return "legendary" elseif lvl >= 50 then return "epic"
    elseif lvl >= 40 then return "rare" elseif lvl >= 20 then return "uncommon" end
    return "common"
end

-- Guild cards computed locally from the journal (before published sets existed).
function Album.Legacy(ds)
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
                    name = m.display or m.name, class = m.class, guid = m.guid, flavor = variant.flavor(m) })
            end
            local top = 0
            for _, ev in ipairs(m.events) do
                if ev.k == "LEVEL_UP" and (ev.p.lvl or 0) > top then top = ev.p.lvl end
            end
            for lvl = 10, top, 10 do
                add({ id = "L:" .. m.guid .. ":" .. lvl, series = "members", rarity = levelRarity(lvl),
                    name = (m.display or m.name) .. ", niveau " .. lvl, class = m.class, guid = m.guid,
                    flavor = lvl >= 60 and "Le sommet. La guilde s'incline (un peu)."
                        or ("Niveau " .. lvl .. " atteint. Le plus dur reste à venir, comme toujours.") })
            end
        end
    end

    -- Wanted: sworn enemies (epic) and enemies met often or who killed one of us; rare
    -- from the second victim (same rules as admin/core/src/cards.rs).
    for _, e in ipairs(ns.Views.Enemies(ds)) do
        local losses = 0
        for _ in pairs(e.killedMembers or {}) do losses = losses + 1 end
        if e.sworn or losses > 0 or #e.encounters >= 3 then
            add({ id = "E:" .. e.key, series = "sworn", rarity = e.sworn and "epic" or (losses >= 2 and "rare" or "uncommon"),
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
            add({ id = "D:" .. ev.id, series = "faits", rarity = k.pl and "uncommon" or "common",
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

    return cards
end

------------------------------------------------------------------------
-- Published cards (CARD_SET)
------------------------------------------------------------------------
local SERIES_KEYS = {}
for _, s in ipairs(Album.SERIES) do SERIES_KEYS[s.key] = true end

local function str(v, max)
    if type(v) ~= "string" or v == "" then return nil end
    return #v > max and v:sub(1, max) or v
end

-- One card of a CARD_SET payload, checked (it comes from the network).
local function fromPayload(c, ev)
    if type(c) ~= "table" then return nil end
    local id, name = str(c.id, 80), str(c.n, 60)
    if not id or not name or not RARITY_INDEX[c.r] then return nil end
    local icon = str(c.ic, 80)
    if icon and not icon:match("^[%w_]+$") then icon = nil end
    local fo, en = tonumber(c.fo), tonumber(c.en)
    if not (fo and en and fo >= 0 and en >= 0 and fo <= Album.STAT_MAX and en <= Album.STAT_MAX) then
        fo, en = nil, nil
    end
    return {
        fo = fo and math.floor(fo), en = en and math.floor(en), item = (fo and c.it == true) or nil,
        id = id, no = tonumber(c.no), series = SERIES_KEYS[c.s] and c.s or "faits", rarity = c.r, name = name,
        flavor = str(c.f, 200) or "", class = str(c.cl, 20), guid = str(c.g, 40),
        icon = icon and ("Interface\\Icons\\" .. icon) or nil, npc = tonumber(c.npc), itemId = tonumber(c.itm),
        t = ev.t, set = str(ev.p.set, 40),
    }
end

Album.FromPayload = fromPayload

-- Base set cards by id (Core/Cards.lua).
local BASE = {}
for _, c in ipairs(ns.Cards.LIST) do BASE[c.id] = c end

-- Cards published by officers, oldest publication first. An id keeps its first number,
-- date and slot. A later set may correct a card (same id: its content replaces the old one)
-- or withdraw it ({ id = ..., del = true }): it leaves the catalogue, owners keep it
-- (Album.Orphans); publishing it again brings it back. The base set (Core/Cards.lua) is
-- corrected the same way, by its ids (Album.BaseSet). Returns the catalogue list, the
-- withdrawn cards ([id] = last content) and the corrections of the base set
-- ([id] = { card = latest correction, withdrawn = true|nil }).
function Album.Published(ds)
    local sets = {}
    for _, ev in ipairs(ds.events or {}) do
        if ev.k == "CARD_SET" and not ev.del and type(ev.p) == "table" and type(ev.p.cards) == "table"
            and ns.Views.TrustedOfficer(ds, ev) then
            table.insert(sets, ev)
        end
    end
    table.sort(sets, function(a, b)
        if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) < (b.t or 0) end
        return tostring(a.id) < tostring(b.id)
    end)
    local list, slot, withdrawn, base = {}, {}, {}, {}
    for _, ev in ipairs(sets) do
        for _, c in ipairs(ev.p.cards) do
            local id = type(c) == "table" and str(c.id, 80)
            if id and BASE[id] then
                local fix = base[id] or {}
                base[id] = fix
                if c.del == true then
                    fix.withdrawn = true
                else
                    local card = fromPayload(c, ev)
                    if card then
                        card.revised = ev.t
                        fix.card, fix.withdrawn = card, nil
                    end
                end
            elseif id and c.del == true then
                if slot[id] then withdrawn[id] = true end
            else
                local card = fromPayload(c, ev)
                local at = card and slot[card.id]
                if at then
                    local first = list[at]
                    card.no, card.t, card.set, card.revised = first.no, first.t, first.set, ev.t
                    list[at] = card
                    withdrawn[card.id] = nil
                elseif card then
                    list[#list + 1] = card
                    slot[card.id] = #list
                end
            end
        end
    end
    local live, gone = {}, {}
    for _, card in ipairs(list) do
        if withdrawn[card.id] then gone[card.id] = card else live[#live + 1] = card end
    end
    return live, gone, base
end

-- A base set card with a correction: its text, rarity, stats and icon change; its number,
-- series, model and map stay.
local function corrected(card, fix)
    local c = {}
    for k, v in pairs(card) do c[k] = v end
    c.name, c.flavor, c.rarity = fix.name, fix.flavor, fix.rarity
    c.fo, c.en, c.item = fix.fo, fix.en, fix.item
    if fix.icon then
        local first = fix.icon:gsub("^Interface\\Icons\\", "")
        local icons = { first }
        for _, name in ipairs(card.icons or {}) do
            if name ~= first then icons[#icons + 1] = name end
        end
        c.icons = icons
    end
    c.revised = fix.revised
    return c
end

-- The base set as published: each card with its latest correction (fixes: third result of
-- Album.Published), and the withdrawn ones ([id] = card).
function Album.BaseSet(fixes)
    local live, gone = {}, {}
    for _, card in ipairs(ns.Cards.LIST) do
        local fix = fixes and fixes[card.id]
        local c = (fix and fix.card) and corrected(card, fix.card) or card
        if fix and fix.withdrawn then gone[c.id] = c else live[#live + 1] = c end
    end
    return live, gone
end

-- The catalogue boosters draw from: base set + published cards (or, before the first
-- published set, the guild cards computed locally). Members who opted out are left out.
function Album.Catalogue(ds)
    local cards = {}
    local published, withdrawn, fixes = Album.Published(ds)
    local isPublished = #published > 0 or next(withdrawn) ~= nil
    local guild = isPublished and published or Album.Legacy(ds)
    for _, c in ipairs(guild) do
        if not (c.guid and ds.optOut and ds.optOut[c.guid]) then table.insert(cards, c) end
    end
    for _, c in ipairs((Album.BaseSet(fixes))) do table.insert(cards, c) end
    table.sort(cards, function(a, b) return a.id < b.id end)
    local ids = {}
    for i, c in ipairs(cards) do ids[i] = c.id end
    cards.version = Album.Hash(table.concat(ids, "|"))
    cards.published = isPublished
    return cards
end

-- Every card this client can describe, by id: published (live or withdrawn), the base set
-- (corrected, withdrawn included), then the guild cards computed locally. A shiny id
-- ("<id>+") gives the shiny copy of the card, made on first use.
function Album.Known(ds)
    local byId = {}
    local live, gone, fixes = Album.Published(ds)
    for _, c in ipairs(live) do byId[c.id] = c end
    for id, c in pairs(gone) do byId[id] = c end
    local baseLive, baseGone = Album.BaseSet(fixes)
    for _, c in ipairs(baseLive) do byId[c.id] = c end
    for id, c in pairs(baseGone) do byId[id] = c end
    for _, c in ipairs(Album.Legacy(ds)) do byId[c.id] = byId[c.id] or c end
    return setmetatable(byId, { __index = function(t, id)
        local base, shiny = Album.BaseId(id)
        local c = shiny and rawget(t, base)
        if not c then return nil end
        c = Album.Shiny(c)
        rawset(t, id, c)
        return c
    end })
end

-- A card by its id (a card shared in the chat), nil if this client does not know it: a card
-- of another guild, or a set not synced yet.
function Album.Find(ds, id)
    if type(id) ~= "string" then return nil end
    return Album.Known(ds)[id]
end

-- Owned cards missing from the catalogue (an older edition, an opted-out member): still
-- shown in the album, never drawn. Looked up in the published sets, then the local cards.
-- One entry per card, normal and shiny copies together (base id).
function Album.Orphans(ds, cards, collection)
    local known = {}
    for _, c in ipairs(cards) do known[c.id] = true end
    local missing = {}
    for id, n in pairs(collection or {}) do
        id = Album.BaseId(id)
        if n > 0 and not known[id] then
            known[id] = true
            missing[#missing + 1] = id
        end
    end
    if #missing == 0 then return {} end
    table.sort(missing)
    local byId = Album.Known(ds)
    local out = {}
    for _, id in ipairs(missing) do
        local c = byId[id] or { id = id, series = "faits", rarity = "common", name = "Carte retirée",
            flavor = "Cette carte n'est plus au catalogue. Elle reste dans ta collection." }
        local copy = {}
        for k, v in pairs(c) do copy[k] = v end
        copy.orphan = true
        out[#out + 1] = copy
    end
    return out
end

------------------------------------------------------------------------
-- Boosters earned, opened, and the resulting collection (real mode)
------------------------------------------------------------------------
local function dayKey(t) return date("%Y-%m-%d", t) end
Album.DayKey = dayKey

-- Boosters earned by `me`: from their own events and the days they played. Each day
-- is counted with the rule in force that day (`rules`, see Album.RuleOn), so changing
-- the rule never takes back boosters already earned. No debt: the days are replayed in
-- order and an opening that the stock (boosters left from earlier days plus that day's)
-- cannot cover, because the rule changed during the day or was received late (the sync
-- is peer to peer), is a gift. Openings the stock covers use it up (before v1.0.20 a day
-- gave as many as were opened that day, so opening older boosters never emptied the
-- stock).
-- `snap` = { d = day, s = stock }: the BILAN of `me` that summed up their facts until
-- that day (Core/Compact.lua). Days up to it are not replayed (their facts are gone):
-- the stock starts from s; their openings still count. `untilDay`: stop after that day.
-- Returns the openings and the stock left.
function Album.Replay(events, me, playedDays, rules, snap, untilDay)
    local days = {} -- [dayKey] = { bonus = legacy bonus events, hits = { [source] = n }, opened = n }
    local function day(key)
        days[key] = days[key] or { bonus = 0, hits = {}, opened = 0 }
        return days[key]
    end
    for key in pairs(playedDays or {}) do day(key) end
    for _, ev in ipairs(events) do
        if ev.a == me and not ev.del and ev.k == "BOOSTER_OPEN" then
            local d = day(dayKey(ev.t))
            d.opened = d.opened + 1
        end
        if ev.a == me and not ev.del then
            local def = ns.Types.Get(ev.k)
            if not def.hidden then
                local d = day(dayKey(ev.t))
                if Album.BONUS[ev.k] or (ev.k == "EXPEDITION" and ev.pt and #ev.pt > 0) then
                    d.bonus = d.bonus + 1
                end
                for _, s in ipairs(Album.SOURCES) do
                    if s.match(ev) then d.hits[s.key] = (d.hits[s.key] or 0) + 1 end
                end
            end
        end
    end
    local keys = {}
    for key in pairs(days) do
        if not untilDay or key <= untilDay then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local snapDay = type(snap) == "table" and type(snap.d) == "string" and type(snap.s) == "number" and snap.d or nil
    local opened, stock = 0, snapDay and snap.s or 0
    for _, key in ipairs(keys) do
        local d = days[key]
        if not (snapDay and key <= snapDay) then
            stock = math.max(0, stock + Album.DayTotal(Album.RuleOn(rules, key), d.hits, d.bonus) - d.opened)
        end
        opened = opened + d.opened
    end
    return opened, stock
end

-- Openings + stock left, so Earned - opened = boosters available.
function Album.Earned(events, me, playedDays, rules, snap)
    local opened, stock = Album.Replay(events, me, playedDays, rules, snap)
    return opened + stock
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

-- Booster slots (as in a TCG): each slot has a minimum rarity and a chance to come out
-- higher, so a booster always holds 7 commons or better, 2 uncommons or better and 1 rare
-- or better, and a lucky one can hold several rares, or an epic among the commons.
-- Odds per 1000, in the order of Album.RARITIES.
Album.BOOSTER_SLOTS = {
    { count = 7, odds = { 850, 110, 30, 8, 2 } },    -- common or better
    { count = 2, odds = { 0, 850, 120, 25, 5 } },    -- uncommon or better
    { count = 1, odds = { 0, 0, 800, 170, 30 } },    -- rare or better
}
Album.BOOSTER_SIZE = 0
for _, s in ipairs(Album.BOOSTER_SLOTS) do Album.BOOSTER_SIZE = Album.BOOSTER_SIZE + s.count end

-- Booster contents: derived only from its id and the catalogue version. Opened boosters
-- store their card ids (BOOSTER_OPEN), so changing the draw never alters past boosters.
-- `shiny`: 1 card in `shiny` is a shiny copy (0 or nil: none). Drawn from a sequence of
-- its own, so the cards themselves are the same whatever the rate.
function Album.BoosterContents(cards, boosterId, shiny)
    if #cards == 0 then return {} end
    local byRarity = {}
    for _, c in ipairs(cards) do
        local i = RARITY_INDEX[c.rarity] or 1
        byRarity[i] = byRarity[i] or {}
        table.insert(byRarity[i], c)
    end
    local nextValue = rng(Album.Hash(boosterId .. "#" .. tostring(cards.version)))
    local shinyRoll = rng(Album.Hash(boosterId .. "#shiny"))
    shiny = tonumber(shiny) or 0
    local result = {}
    for _, slot in ipairs(Album.BOOSTER_SLOTS) do
        local total = 0
        for i = 1, #Album.RARITIES do total = total + (slot.odds[i] or 0) end
        local floor = 1
        while (slot.odds[floor] or 0) == 0 and floor < #Album.RARITIES do floor = floor + 1 end
        for _ = 1, slot.count do
            local roll = nextValue() % total
            local idx = floor
            for i = 1, #Album.RARITIES do
                local w = slot.odds[i] or 0
                if roll < w then idx = i break end
                roll = roll - w
            end
            -- A rarity with no card in the catalogue falls back to the next lower one that
            -- has some (below the slot's minimum only if nothing at or above it exists).
            while idx > 1 and not byRarity[idx] do idx = idx - 1 end
            while not byRarity[idx] do idx = idx + 1 end
            local pool = byRarity[idx]
            local card = pool[(nextValue() % #pool) + 1]
            if shiny >= 1 and shinyRoll() % math.floor(shiny) == 0 then card = Album.Shiny(card) end
            table.insert(result, card)
        end
    end
    return result
end

function Album.Progress(cards, collection, series)
    local owned, total, doubles = 0, 0, 0
    for _, c in ipairs(cards) do
        if not series or c.series == series then
            total = total + 1
            local normal, shiny = Album.Copies(collection, c.id)
            local n = normal + shiny
            if n > 0 then owned = owned + 1 end
            if n > 1 then doubles = doubles + n - 1 end
        end
    end
    return owned, total, doubles
end
