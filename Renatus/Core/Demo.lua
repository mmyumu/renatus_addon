-- Core/Demo.lua: fictional dataset to preview the UI (/renatus demo).
-- Nothing is saved: everything lives in memory and disappears on /reload.
-- Names are made up (except yours, to fill "Mon journal").
local _, ns = ...

local Demo = {}
ns.Demo = Demo

local DAY, HOUR = 86400, 3600
local RIVALS = "Les Crocs de Sang"

local dataset

local MEMBERS = {
    { key = "bri", name = "Brisépée", class = "WARRIOR" },
    { key = "mel", name = "Mélisande", class = "PRIEST" },
    { key = "fen", name = "Fendragon", class = "PALADIN" },
    { key = "ves", name = "Vespérine", class = "MAGE" },
    { key = "tob", name = "Tobias", class = "ROGUE" },
    { key = "omb", name = "Ombrelune", class = "DRUID" },
    { key = "kae", name = "Kael'zar", class = "WARLOCK" },
    { key = "pis", name = "Pistache", class = "HUNTER" },
}

local ENEMIES = {
    Gorbash = { class = "WARRIOR", race = "Orc", level = 25 },
    Sombrelame = { class = "ROGUE", race = "Mort-vivant", level = 24 },
    Lysandra = { class = "MAGE", race = "Elfe de sang", level = 23 },
    Mortefeuille = { class = "WARLOCK", race = "Mort-vivant", level = 26 },
}

local function build()
    local now = (GetServerTime and GetServerTime()) or time()
    local meGuid, meName, meClass = ns.Context.Me()
    local who = { me = { g = meGuid, n = meName, c = meClass } }
    for i, m in ipairs(MEMBERS) do
        who[m.key] = { g = ("Player-0000-DEMO%02d"):format(i), n = m.name, c = m.class }
    end
    local seq = {}
    local events = {}
    local guildKey = "Guilde de démonstration"

    local function E(author, kind, daysAgo, hour, payload, opts)
        opts = opts or {}
        local w = who[author]
        seq[author] = (seq[author] or 0) + 1
        local t = now - daysAgo * DAY - (now % DAY) + hour * HOUR + (opts.min or 0) * 60
        if t > now then t = now - 60 * seq[author] end
        local ev = {
            v = 1, id = w.g .. ":" .. seq[author], a = w.g, n = w.n, c = w.c, s = seq[author], t = t,
            k = kind, g = guildKey, loc = opts.loc or { z = opts.zone }, pt = opts.pt, prov = opts.prov or "OBS",
            miss = opts.miss, refs = opts.refs, occ = opts.occ, ded = opts.ded, vis = "G", src = opts.prov == "MAN" and "M" or "A",
            p = payload or {},
        }
        table.insert(events, ev)
        return ev
    end
    local function P(...) local l = {} for _, k in ipairs({ ... }) do table.insert(l, { g = who[k].g, n = who[k].n }) end return l end
    local function seen(author, d, h, enemy, zone)
        local e = ENEMIES[enemy]
        return E(author, "ENEMY_SEEN", d, h, { name = enemy, guild = RIVALS, class = e.class, race = e.race, level = e.level }, { zone = zone })
    end
    local dm = { z = "Marche de l'Ouest", i = "Les Mortemines", it = "party" }

    -- My journal
    for i, lvl in ipairs({ 18, 19, 20, 21, 22 }) do E("me", "LEVEL_UP", 22 - i * 4, 21, { lvl = lvl }, { zone = "Marche de l'Ouest" }) end
    E("me", "ZONE_FIRST_VISIT", 21, 19, {}, { zone = "Marche de l'Ouest" })
    E("me", "ZONE_FIRST_VISIT", 14, 20, {}, { zone = "Les Carmines" })
    E("me", "ZONE_FIRST_VISIT", 8, 22, {}, { zone = "Bois de la Pénombre" })
    E("me", "ZONE_FIRST_VISIT", 3, 20, {}, { zone = "Vallée de Strangleronce" })
    E("me", "QUEST_DONE", 12, 19, { q = 155, title = "La Confrérie défias" }, { zone = "Marche de l'Ouest" })
    E("me", "QUEST_DONE", 10, 21, { q = 166, title = "La Confrérie défias (suite)" }, { zone = "Marche de l'Ouest" })
    local expOcc = "EXP:36:demo"
    local function expP(duration, deaths) return { type = "DUNGEON", inst = "Les Mortemines", duration = duration, bosses = 1, deaths = deaths, bossNames = { "Edwin VanCleef" } } end
    local exp = E("me", "EXPEDITION", 9, 20, expP(5400, 2), { loc = dm, pt = P("bri", "mel", "tob", "pis"), occ = expOcc })
    local d1 = E("me", "DEATH", 9, 20, { lvl = 20 }, { loc = dm, min = 30, miss = { "killer" } })
    local d2 = E("me", "DEATH", 9, 20, { lvl = 20 }, { loc = dm, min = 50, miss = { "killer" } })
    local occ = "ENC:1:demo"
    local boss = E("me", "BOSS_KILL", 9, 21, { enc = 1, name = "Edwin VanCleef" }, { loc = dm, min = 20, occ = occ, pt = P("bri", "mel", "tob", "pis") })
    E("me", "ANECDOTE", 5, 22, { title = "Le saut de la foi raté", desc = "Tentative de raccourci depuis la falaise de Strangleronce. La falaise a gagné.", cat = "Exploit" },
        { zone = "Vallée de Strangleronce", prov = "MAN", pt = P("ves") })
    seen("me", 3, 20, "Gorbash", "Vallée de Strangleronce")
    local d3 = E("me", "DEATH", 3, 20, { lvl = 22, enemies = { "Gorbash" } }, { zone = "Vallée de Strangleronce", min = 5, miss = { "killer" }, ded = { "enemies" } })
    E("me", "PVP_CLASH", 2, 21, { name = "Sombrelame", enemy = "Sombrelame", result = "win" }, { zone = "Bois de la Pénombre", prov = "MAN" })

    -- The others
    E("bri", "BOSS_KILL", 9, 21, { enc = 1, name = "Edwin VanCleef" }, { loc = dm, min = 21, occ = occ })
    E("mel", "BOSS_KILL", 9, 21, { enc = 1, name = "Edwin VanCleef" }, { loc = dm, min = 20, occ = occ })
    E("bri", "EXPEDITION", 9, 20, expP(5300, 0), { loc = dm, pt = P("mel", "tob", "pis"), occ = expOcc, min = 1 })
    E("pis", "EXPEDITION", 9, 20, expP(5400, 1), { loc = dm, pt = P("bri", "mel", "tob"), occ = expOcc, min = 2 })
    -- Death cause from Pistache's combat log (companion), published by her.
    E("pis", "DEATH_CAUSE", 9, 20, { victim = meName, cause = "Ronfleur le Maladroit (Coup de pioche)", killer = "Ronfleur le Maladroit" },
        { loc = {}, prov = "LOG", refs = { d1.id }, min = 31 })
    E("bri", "LEVEL_UP", 4, 22, { lvl = 23 }, { zone = "Les Carmines" })
    E("bri", "PVP_CLASH", 3, 20, { name = "Gorbash", enemy = "Gorbash", result = "loss" }, { zone = "Vallée de Strangleronce", prov = "LOG" })
    E("mel", "ANECDOTE", 7, 21, { title = "Le mouton de la discorde", desc = "Mélisande a soigné un mouton métamorphosé pendant trois minutes, persuadée qu'il s'agissait du tank.", cat = "Fait divers" },
        { zone = "Les Mortemines", prov = "MAN", pt = P("bri") })
    seen("mel", 6, 19, "Sombrelame", "Bois de la Pénombre")
    E("mel", "ENEMY_NOTE", 6, 19, { name = "Sombrelame", nickname = "L'Ombre qui pique", sworn = true }, { prov = "MAN" })
    for i, prov in ipairs({ "MAN", "LOG", "LOG" }) do
        E("fen", "PVP_CLASH", 12 - i * 3, 21, { name = "Gorbash", enemy = "Gorbash", result = "loss" }, { zone = "Vallée de Strangleronce", prov = prov })
    end
    E("fen", "ENEMY_NOTE", 3, 22, { name = "Gorbash", nickname = "Le Broyeur de Chefs", sworn = true,
        note = "A une passion inexpliquée pour les chefs de guilde." }, { prov = "MAN" })
    E("fen", "WANTED", 3, 22, { name = "Gorbash", nickname = "Le Broyeur de Chefs", reason = "A tué notre chef de guilde trois fois.",
        reward = "300 pièces de vantardise" }, { prov = "MAN" })
    E("omb", "ENEMY_NOTE", 2, 20, { name = "Gorbash", sworn = true, note = "Toujours là quand on sort de l'auberge." }, { prov = "MAN" })
    E("omb", "ANECDOTE", 4, 21, { title = "La grande course des félins", desc = "Course en forme de félin jusqu'à Comté-de-l'Or. Ombrelune est arrivée deuxième sur deux.", cat = "Soirée de guilde" },
        { zone = "Forêt d'Elwynn", prov = "MAN", pt = P("tob", "ves") })
    E("omb", "LEVEL_UP", 1, 22, { lvl = 24 }, { zone = "Les Paluns" })
    local zones = { "Forêt d'Elwynn", "Marche de l'Ouest", "Les Carmines", "Bois de la Pénombre", "Les Paluns", "Loch Modan",
        "Dun Morogh", "Sombrivage", "Les Tarides", "Contreforts de Hautebrande", "Orneval", "Les Serres-Rocheuses",
        "Mille pointes", "Marécage d'Âprefange", "Désolace", "Vallée de Strangleronce" }
    for i, z in ipairs(zones) do E("ves", "ZONE_FIRST_VISIT", 25 - i, 20, {}, { zone = z }) end
    seen("ves", 2, 19, "Lysandra", "Contreforts de Hautebrande")
    E("ves", "WANTED", 2, 20, { name = "Sombrelame", nickname = "L'Ombre qui pique",
        reason = "Recherché pour comportements répétés de furtivité excessive.", reward = "Une chope à la taverne" }, { prov = "MAN" })
    for i = 1, 11 do E("tob", "DEATH", 20 - i, 20, { lvl = 19 + math.floor(i / 4) }, { zone = (i % 2 == 0) and "Bois de la Pénombre" or "Les Paluns", miss = { "killer" } }) end
    seen("tob", 1, 21, "Mortefeuille", "Bois de la Pénombre")
    E("tob", "WANTED", 1, 21, { name = "Mortefeuille", nickname = "Le Gardien du Cimetière",
        reason = "Soupçonné de camper le même cimetière depuis mardi.", reward = "Le respect éternel de Tobias" }, { prov = "MAN" })
    E("kae", "PVP_CLASH", 4, 22, { name = "Mortefeuille", enemy = "Mortefeuille", result = "win" }, { zone = "Bois de la Pénombre", prov = "LOG" })
    seen("kae", 4, 22, "Mortefeuille", "Bois de la Pénombre")
    -- Honorable kills: the victim is named, rival guild or not; counted without a name (DED)
    -- when the game did not say whom.
    E("bri", "PVP_KILL", 2, 21, { name = "Lysandra", guild = RIVALS, race = "Elfe de sang", class = "MAGE", className = "Mage", level = 23 },
        { zone = "Contreforts de Hautebrande", prov = "OBS" })
    E("pis", "PVP_KILL", 1, 20, { name = "Brisecorne", guild = "Les Vents du Sud", race = "Tauren", class = "HUNTER", className = "Chasseur", level = 24 },
        { zone = "Les Tarides", prov = "OBS" })
    E("tob", "PVP_KILL", 0, 22, {}, { zone = "Les Tarides", prov = "DED" })
    E("pis", "QUEST_DONE", 6, 20, { q = 1, title = "Le familier perdu" }, { zone = "Loch Modan" })
    E("pis", "LEVEL_UP", 6, 21, { lvl = 21 }, { zone = "Loch Modan" })

    -- Readers' letters about this week's issue.
    E("tob", "LETTER", 0, 0, { edition = "demo-2", title = "Droit de réponse",
        desc = "Onze morts, c'est faux : la douzième ne compte pas, j'étais déjà fantôme. Je demande un rectificatif." },
        { prov = "MAN", zone = "Bois de la Pénombre" })
    E("mel", "LETTER", 0, 0, { edition = "demo-2", title = "Au sujet du mouton",
        desc = "Le mouton allait très bien grâce à moi. Je ne regrette rien." }, { prov = "MAN", zone = "Hurlevent" })

    table.sort(events, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.id > b.id
    end)

    local articles = {
        { id = "demo-art-1", t = now - 8 * DAY, kind = "Édition spéciale", style = "Journaliste sarcastique",
            title = "Une expédition réussie malgré les efforts d'un membre pour rejoindre le cimetière",
            body = ("Hier soir, cinq courageux aventuriers ont entrepris une expédition périlleuse dans les Mortemines. "
                .. "Tous sont finalement revenus victorieux, bien que %s ait insisté pour visiter deux fois les services funéraires locaux. "
                .. "La rédaction salue cette persévérance.\n\nEdwin VanCleef, joint par nos services, n'a pas souhaité commenter. "
                .. "Il faut dire qu'il n'est plus en état de le faire."):format(meName),
            refs = { exp.id, d1.id, d2.id, boss.id } },
        { id = "demo-art-3", t = now - 120, kind = "Nécrologie", style = "Rédacteur de faits divers",
            title = "Tobias, onze fois regretté",
            body = "Tobias nous a quittés. Puis il est revenu. Puis il nous a quittés de nouveau. "
                .. "Avec onze décès en vingt jours, Tobias pulvérise le record de la guilde et s'adjuge le titre convoité d'Habitué du cimetière. "
                .. "Les esprits gardiens le reconnaissent désormais de loin et lui gardent sa place.\n\nNi fleurs ni couronnes : il en aura besoin la prochaine fois.",
            refs = {}, key = "demo-tobias", portrait = "Tobias",
            quote = "Les esprits gardiens le reconnaissent désormais de loin." },
        { id = "demo-art-2", t = now - 120, kind = "Diplomatie", style = "Propagandiste de guilde",
            title = "Les Crocs de Sang démentent tout campement prolongé",
            body = "Dans un communiqué que personne n'a lu, la guilde rivale affirme ne « camper aucun cimetière ». "
                .. "Pourtant, Mortefeuille a été aperçu à proximité immédiate du cimetière du Bois de la Pénombre, et Tobias a quitté ce monde onze fois en vingt jours. "
                .. "La rédaction ne tire aucune conclusion. Elle laisse ce soin à ses lecteurs, qui sont intelligents et forcément d'accord avec elle.\n\n"
                .. "Fendragon, chef de guilde, a de son côté croisé Gorbash à trois reprises. Le bilan de ces rencontres reste confidentiel, sur demande expresse de l'intéressé.",
            refs = {} },
        { id = "demo-art-4", t = now - 120, kind = "Carnet mondain", style = "Chroniqueur mondain",
            title = "Le mouton de la discorde",
            body = "Mélisande a soigné un mouton pendant trois minutes, persuadée qu'il s'agissait du tank. "
                .. "Le mouton se porte à merveille. Le tank, lui, n'a pas survécu.\n\n## Réaction de l'intéressée\n"
                .. "« Il avait l'air si vulnérable », a confié Mélisande à notre envoyé spécial, qui n'a pas su quoi répondre.",
            refs = {}, quote = "Il avait l'air si vulnérable." },
    }
    -- Two issues: an older one, then this week's (Tobias on the front page).
    for i, a in ipairs(articles) do a.order, a.edition = i, i == 1 and "demo-1" or "demo-2" end

    -- This week's edition is published at once, as in real life (articles + layout).
    -- Layout of this week's edition, as the EDITION event carries it (see UI/Newsprint.lua).
    local layouts = { ns.UI.Newsprint.Sanitize({ template = "grande_une", titles = { "", "Diplomatie et faits divers" }, cells = {
        { pg = 1, r = 1, w = 12, h = 0.6, b = { { t = "story", a = "@1", cols = 3, head = "xl", drop = true } } },
        { pg = 1, r = 2, w = 4, b = { { t = "portrait", a = "@1" } } },
        { pg = 1, r = 2, w = 4, b = { { t = "teaser", a = "@2" } } },
        { pg = 1, r = 2, w = 4, b = { { t = "quote", a = "@3" }, { t = "figure" } } },
        { pg = 2, r = 1, w = 7, h = 0.62, b = { { t = "story", a = "@2", cols = 2, drop = true } } },
        { pg = 2, r = 1, w = 5, b = { { t = "wanted", name = "Mortefeuille" }, { t = "contents" } } },
        { pg = 2, r = 2, w = 8, b = { { t = "brief", max = 5 } } },
        { pg = 2, r = 2, w = 4, b = { { t = "notice", title = "Petite annonce",
            text = "Cherche tank capable de survivre à un mouton. Se présenter à l'auberge." } } },
    } }) }
    layouts[1].t, layouts[1].edition = now - 60, "demo-2"

    dataset = {
        isDemo = true,
        rival = RIVALS,
        me = meGuid,
        guildKey = guildKey,
        events = events,
        articles = articles,
        layouts = layouts,
        causes = ns.Views.DeathCauses(events),
        collection = {},
        boosters = 3,
        boostersOpened = 0,
        founders = { { name = meName, class = meClass }, { name = "Fendragon", class = "PALADIN" } },
        legends = {
            { id = "L:pont", name = "La Bataille du Pont", flavor = "Cinq contre huit. Personne n'a lâché le pont. Personne n'a compris pourquoi." },
            { id = "L:premier", name = "Le Premier Rassemblement", flavor = "Le soir où tout a commencé, devant l'auberge de Comté-de-l'Or." },
        },
        roster = {},
    }
    -- Starting collection: a deterministic subset of the catalogue.
    for _, card in ipairs(ns.Album.Catalogue(dataset)) do
        local h = ns.Album.Hash(card.id)
        if card.rarity ~= "legendary" and h % 3 == 0 then dataset.collection[card.id] = (h % 7 == 0) and 2 or 1 end
        if h % 13 == 0 then dataset.collection[ns.Album.ShinyId(card.id)] = 1 end   -- a few shiny ones
    end
    return dataset
end

function Demo:Get()
    if not dataset then build() end
    return dataset
end

function Demo:Insert(ev)
    local ds = self:Get()
    table.insert(ds.events, 1, ev)
    ns.EventBus.Publish("CHRONICLE_EVENT", ev)
end

function Demo:Reset() dataset = nil end
