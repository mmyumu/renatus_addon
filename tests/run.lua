-- tests/run.lua : lancer depuis la racine du depot avec `lua tests/run.lua`.
package.path = "./tests/?.lua;" .. package.path
local Stub = require("wow_stub")
local print = print -- le stub remplace la globale print

local ROOT, NAME = "GuildChronicle", "GuildChronicle"
local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. "\n       " .. tostring(err))
    end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "") .. " attendu=" .. tostring(expected) .. " obtenu=" .. tostring(actual), 2)
    end
end

local function boot(opts)
    local S = Stub.reset(opts)
    local ns = Stub.loadAddon(ROOT, NAME)
    for _, line in ipairs(S.printed) do
        if line:find("erreur") then error("erreur au chargement : " .. line, 2) end
    end
    return ns, S
end

local function soundName(entry) return entry.path:match("([%w_]+)%.ogg$") end

local function familyOf(ns, sound)
    for family, list in pairs(ns.Voice.FAMILIES) do
        for _, s in ipairs(list) do if s == sound then return family end end
    end
end

print("Voice / Renacoach")

test("les 34 sons references existent sur disque", function()
    local ns = boot({ specIndex = 1 })
    local count = 0
    for _, list in pairs(ns.Voice.FAMILIES) do
        for _, s in ipairs(list) do
            count = count + 1
            local f = io.open(ROOT .. "/Voice/Sounds/" .. s .. ".ogg", "rb")
            assert(f, "fichier manquant : " .. s)
            f:close()
        end
    end
    eq(count, 34, "nombre de sons")
end)

test("desactive par defaut : aucun son en combat", function()
    local ns, S = boot({ specIndex = 1 })
    eq(ns.char.voice.enabled, false)
    S.inCombat = true
    Stub.fire("PLAYER_REGEN_DISABLED")
    Stub.advance(10)
    eq(#S.played, 0, "sons joues")
end)

test("guerrier protection (Retail) : memes familles que Renacoach", function()
    local ns = boot({ class = "WARRIOR", specIndex = 3, specRole = "TANK" })
    eq(table.concat(ns.Voice:GetCombatFamilies(), ","), "fightGeneric,fightTank,fightMelee")
    eq(#ns.Voice:CollectSounds(ns.Voice:GetCombatFamilies()), 18)
end)

test("chasseur Precision : distance (correction du bug)", function()
    local ns = boot({ class = "HUNTER", specIndex = 2, specRole = "DAMAGER" })
    eq(ns.Voice.characterType, "ranged")
end)

test("Forever sans specialisations : repli generique + type de classe", function()
    local ns = boot({ class = "HUNTER", specIndex = nil,
        unknownEvents = { PLAYER_SPECIALIZATION_CHANGED = true, ACTIVE_TALENT_GROUP_CHANGED = true } })
    eq(table.concat(ns.Voice:GetCombatFamilies(), ","), "fightGeneric,fightRanged")
    assert(ns.unsupportedEvents.PLAYER_SPECIALIZATION_CHANGED, "evenement absent non signale")
end)

test("GetSpecialization qui plante : pas d'erreur, repli sur le role de groupe", function()
    local ns = boot({ class = "DRUID", specIndex = "error", groupRole = "HEALER" })
    eq(table.concat(ns.Voice:GetCombatFamilies(), ","), "fightGeneric,fightHealer")
end)

test("entree en combat puis repliques periodiques (proba 1)", function()
    local ns, S = boot({ class = "WARRIOR", specIndex = 1 })
    ns.Voice:SetEnabled(true)
    S.inCombat = true
    S.randomValue = 0 -- math.random() < probability toujours vrai
    Stub.fire("PLAYER_REGEN_DISABLED")
    eq(familyOf(ns, soundName(S.played[1])), "startFight")
    Stub.advance(3.05)
    eq(#S.played, 2, "une replique de combat apres 3 s")
    assert(familyOf(ns, soundName(S.played[2])):match("^fight"), "famille de combat attendue")
    eq(S.played[2].channel, "Ambience")
end)

test("tirage au-dessus de la probabilite : pas de replique periodique", function()
    local ns, S = boot({ specIndex = 1 })
    ns.Voice:SetEnabled(true)
    S.inCombat = true
    S.randomValue = 0.995
    Stub.fire("PLAYER_REGEN_DISABLED")
    Stub.advance(9.1)
    eq(#S.played, 1, "seulement startFight")
end)

test("mort : la replique de fin de combat ne coupe pas celle de mort", function()
    local ns, S = boot({ specIndex = 1 })
    ns.Voice:SetEnabled(true)
    S.inCombat = true
    Stub.fire("PLAYER_REGEN_DISABLED")
    S.dead = true
    Stub.fire("PLAYER_DEAD")
    S.inCombat = false
    Stub.fire("PLAYER_REGEN_ENABLED")
    eq(#S.played, 2)
    eq(familyOf(ns, soundName(S.played[2])), "death")
end)

test("hors combat : plus de repliques periodiques", function()
    local ns, S = boot({ specIndex = 1 })
    ns.Voice:SetEnabled(true)
    S.randomValue = 0
    S.inCombat = true
    Stub.fire("PLAYER_REGEN_DISABLED")
    S.inCombat = false
    Stub.fire("PLAYER_REGEN_ENABLED")
    local n = #S.played
    Stub.advance(10)
    eq(#S.played, n)
end)

test("famille coupee : jamais jouee", function()
    local ns, S = boot({ specIndex = 1 })
    ns.Voice:SetEnabled(true)
    ns.char.voice.families.startFight = false
    S.inCombat = true
    Stub.fire("PLAYER_REGEN_DISABLED")
    eq(#S.played, 0)
end)

test("ducking : volume abaisse puis restaure", function()
    local ns, S = boot({ specIndex = 1, cvars = { Sound_SFXVolume = "0.8" } })
    ns.Voice:SetEnabled(true)
    ns.Voice:Play("death")
    eq(S.cvars.Sound_SFXVolume, "0.25")
    eq(ns.db.voiceDuck.previous, "0.8")
    Stub.advance(5)
    eq(tonumber(S.cvars.Sound_SFXVolume), 0.8)
    eq(ns.db.voiceDuck.previous, nil)
end)

test("crash pendant un ducking : volume restaure au chargement suivant", function()
    local _, S = boot({ specIndex = 1, cvars = { Sound_SFXVolume = "0.25" },
        savedAccount = { schema = 1, voiceDuck = { previous = "0.7" } } })
    eq(S.cvars.Sound_SFXVolume, "0.7")
end)

test("reglages conserves entre deux sessions", function()
    local ns = boot({ specIndex = 1 })
    ns.char.voice.enabled = true
    ns.char.voice.probability = 0.2
    local saved = GuildChronicleCharDB
    local ns2 = boot({ specIndex = 1, savedChar = saved })
    eq(ns2.char.voice.enabled, true)
    eq(ns2.char.voice.probability, 0.2)
    eq(ns2.char.voice.interval, 3, "valeur par defaut completee")
end)

test("/renacoach on et /chronicle voice off", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENACOACH("on")
    eq(ns.char.voice.enabled, true)
    SlashCmdList.GUILDCHRONICLE("voice off")
    eq(ns.char.voice.enabled, false)
    SlashCmdList.GUILDCHRONICLE("voice prob 0.3")
    eq(ns.char.voice.probability, 0.3)
end)

print("Core")

test("EventBus : un abonne qui plante n'empeche pas les autres", function()
    local ns = boot({ specIndex = 1 })
    local got = 0
    GuildChronicle.Subscribe("X", function() error("boom") end)
    GuildChronicle.Subscribe("X", function(v) got = v end)
    eq(ns.EventBus.Publish("X", 42), 2)
    eq(got, 42)
end)

test("une seule globale exposee en dehors des commandes slash", function()
    boot({ specIndex = 1 })
    for _, name in ipairs({ "OnLoad", "UpdateCombat", "PlayRandomSound", "DuckCombatSounds",
        "RestoreCombatSounds", "GetSpecInfos", "ConcatenateLists", "GetCharacterType", "playerClassID" }) do
        eq(rawget(_G, name), nil, "globale " .. name)
    end
    assert(type(GuildChronicle) == "table")
end)


print("Collecteurs")

local function eventsOf(ns, kind)
    local out = {}
    for _, ev in pairs(ns.db.events) do if ev.k == kind then table.insert(out, ev) end end
    return out
end

test("passage de niveau : un evenement prive, observe, avec lieu", function()
    local ns = boot({ specIndex = 1 })
    Stub.fire("PLAYER_LEVEL_UP", 21)
    local list = eventsOf(ns, "LEVEL_UP")
    eq(#list, 1)
    local ev = list[1]
    eq(ev.p.lvl, 21)
    eq(ev.prov, "OBS")
    eq(ev.vis, "P")
    eq(ev.id, "Player-1-ABC:p1")
    eq(ev.loc.z, "Forêt d'Elwynn")
    eq(ev.loc.xy[1], 500)
    eq(ev.g, "Les Testeurs-Forever")
end)

test("categorie desactivee : rien n'est enregistre", function()
    local ns = boot({ specIndex = 1 })
    ns.char.privacy.progression = "OFF"
    Stub.fire("PLAYER_LEVEL_UP", 21)
    eq(#eventsOf(ns, "LEVEL_UP"), 0)
end)

test("categorie Guilde : sequence publique", function()
    local ns = boot({ specIndex = 1 })
    ns.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD")
    local ev = eventsOf(ns, "DEATH")[1]
    eq(ev.id, "Player-1-ABC:1")
    eq(ev.vis, "G")
    eq(ev.miss[1], "killer")
end)

test("evenements persistants apres rechargement, sans doublon", function()
    local ns = boot({ specIndex = 1 })
    Stub.fire("PLAYER_LEVEL_UP", 21)
    local savedA, savedC = GuildChronicleDB, GuildChronicleCharDB
    local ns2 = boot({ specIndex = 1, savedAccount = savedA, savedChar = savedC })
    eq(#eventsOf(ns2, "LEVEL_UP"), 1)
    Stub.fire("PLAYER_LEVEL_UP", 22)
    eq(#eventsOf(ns2, "LEVEL_UP"), 2)
    eq(ns2.Store.Insert(eventsOf(ns2, "LEVEL_UP")[1]), false, "reinsertion refusee")
end)

test("boss : seulement en cas de victoire, nom secret ignore", function()
    local ns = boot({ specIndex = 1 })
    Stub.fire("ENCOUNTER_END", 1094, "Edwin VanCleef", 1, 5, 0)
    eq(#eventsOf(ns, "BOSS_KILL"), 0)
    Stub.fire("ENCOUNTER_END", 1094, { secret = true }, 1, 5, 1)
    local ev = eventsOf(ns, "BOSS_KILL")[1]
    eq(ev.p.enc, 1094)
    eq(ev.p.name, nil)
    assert(ev.occ:match("^ENC:1094:"), "cle d'occurrence")
end)

test("premiere visite de zone : la zone de connexion ne compte pas", function()
    local ns, S = boot({ specIndex = 1 })
    eq(#eventsOf(ns, "ZONE_FIRST_VISIT"), 0)
    S.mapID, S.zone = 1436, "Marche de l'Ouest"
    Stub.fire("ZONE_CHANGED_NEW_AREA")
    Stub.fire("ZONE_CHANGED_NEW_AREA")
    eq(#eventsOf(ns, "ZONE_FIRST_VISIT"), 1)
end)

test("entree en guilde : pas a l'installation, oui ensuite", function()
    local ns, S = boot({ specIndex = 1 })
    Stub.advance(11)
    Stub.fire("PLAYER_GUILD_UPDATE")
    eq(#eventsOf(ns, "GUILD_JOIN"), 0)
    S.guild = "Les Nouveaux"
    Stub.fire("PLAYER_GUILD_UPDATE")
    eq(#eventsOf(ns, "GUILD_JOIN"), 1)
end)

print("Vues (donnees de demo)")

local function demo()
    local ns = boot({ specIndex = 1 })
    ns.char.ui.demo = true
    return ns, ns.Store.Dataset()
end

test("agregation : VanCleef = une seule ligne, 3 membres confirmes", function()
    local ns, ds = demo()
    local items = ns.Views.Aggregate(ns.Views.Filter(ds.events, { kind = "BOSS_KILL" }))
    eq(#items, 1)
    eq(#items[1].authors, 3)
end)

test("agregation : meme boss a 2 jours d'ecart = deux lignes", function()
    local ns = boot({ specIndex = 1 })
    local a = { id = "A:1", a = "A", n = "A", t = 1000, k = "BOSS_KILL", occ = "ENC:1:x", p = {} }
    local b = { id = "B:1", a = "B", n = "B", t = 1000 + 2 * 86400, k = "BOSS_KILL", occ = "ENC:1:x", p = {} }
    eq(#ns.Views.Aggregate({ b, a }), 2)
end)

test("titres officieux selon des regles explicites", function()
    local ns, ds = demo()
    local members = ns.Views.Members(ds)
    local titles = {}
    for _, m in ipairs(members) do
        for _, t in ipairs(m.titles) do titles[m.name .. ":" .. t.title] = true end
    end
    assert(titles["Tobias:Habitué du cimetière"], "Tobias")
    assert(titles["Vespérine:Explorateur infatigable"], "Vesperine")
end)

test("Wanted : bilan ventile par provenance, ennemi jure", function()
    local ns, ds = demo()
    local posters, enemies = ns.Views.Wanted(ds)
    eq(#posters, 3)
    local gorbash
    for _, e in ipairs(enemies) do if e.name == "Gorbash" then gorbash = e end end
    eq(gorbash.losses.LOG, 3)
    eq(gorbash.losses.MAN, 1)
    eq(gorbash.sworn, true)
    eq(gorbash.presentAtDeaths, 1)
end)

test("aventures partagees", function()
    local ns, ds = demo()
    local _, byGuid = ns.Views.Members(ds)
    local bri
    for guid, m in pairs(byGuid) do if m.name == "Brisépée" then bri = guid end end
    local shared = ns.Views.Shared(ds, ds.me, bri)
    eq(shared.bosses, 1)
    eq(shared.expeditions, 1)
end)

test("album : booster deterministe, 5 cartes", function()
    local ns, ds = demo()
    local cards = ns.Album.Catalogue(ds)
    local a = ns.Album.BoosterContents(cards, "X:booster:1")
    local b = ns.Album.BoosterContents(cards, "X:booster:1")
    local c = ns.Album.BoosterContents(cards, "X:booster:2")
    eq(#a, 5)
    local same, differs = true, false
    for i = 1, 5 do
        if a[i].id ~= b[i].id then same = false end
        if a[i].id ~= c[i].id then differs = true end
    end
    assert(same, "meme identifiant -> meme contenu")
    assert(differs, "identifiants differents -> contenus differents")
end)

test("recherche dans le journal", function()
    local ns, ds = demo()
    eq(#ns.Views.Filter(ds.events, { search = "vancleef" }), 3)
end)

print("Interface")

local function openAllTabs(ns)
    for _, tab in ipairs(ns.UI.tabs) do
        ns.UI.Open(tab.key)
        eq(ns.UI.current, tab.key)
    end
end

test("tous les onglets s'ouvrent (donnees reelles vides)", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.GUILDCHRONICLE("")
    assert(GuildChronicleMainFrame:IsShown(), "fenetre ouverte")
    openAllTabs(ns)
    eq(#ns.UI.tabs, 8)
end)

test("tous les onglets s'ouvrent (demo) et se remplissent", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.GUILDCHRONICLE("demo")
    openAllTabs(ns)
    local f = GuildChronicleMainFrame
    assert(#f.containers.journal.list.items > 5, "journal rempli")
    assert(#f.containers.guild.list.items > 20, "guilde remplie")
    assert(#f.containers.members.list.items >= 9, "membres")
end)

test("filtres du journal de guilde", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.GUILDCHRONICLE("demo")
    ns.UI.Open("guild")
    local c = GuildChronicleMainFrame.containers.guild
    local all = #c.list.items
    c.state.category = "pvp"; c:Refresh()
    local pvp = #c.list.items
    assert(pvp > 0 and pvp < all, "filtre categorie")
    c.state.category = "all"; c.state.member = "Tobias"; c:Refresh()
    for _, item in ipairs(c.list.items) do eq(item.ev.n, "Tobias") end
    c.state.member = "all"; c.state.importance = 3; c:Refresh()
    for _, item in ipairs(c.list.items) do assert(ns.Types.Get(item.ev.k).importance >= 3) end
end)

test("tableau de chasse : affiches, registre, fiche", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.GUILDCHRONICLE("demo")
    ns.UI.Open("wanted")
    local c = GuildChronicleMainFrame.containers.wanted
    eq(c.posters.items[1].poster ~= nil, true)
    c.posters.items[1]:Click()
    assert(c.detailFrame:IsShown(), "fiche affichee")
    c.view = "registry"; c.detail = nil; c:Refresh()
    assert(c.registry:IsShown() and #c.registry.items == 4, "registre")
end)

test("gazette : article et sources", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.GUILDCHRONICLE("demo")
    ns.UI.Open("gazette")
    local c = GuildChronicleMainFrame.containers.gazette
    assert(c.current, "article selectionne")
    c.paper.sources:Click()
    assert(c.showSources, "sources affichees")
end)

test("album : ouvrir un booster en demo", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.GUILDCHRONICLE("demo")
    ns.UI.Open("album")
    local ds = ns.Store.Dataset()
    local before = ds.boosters
    GuildChronicleMainFrame.containers.album.booster:Click()
    eq(ds.boosters, before - 1)
end)

test("voix : la case active le module", function()
    local ns = boot({ specIndex = 1 })
    ns.UI.Open("voice")
    local c = GuildChronicleMainFrame.containers.voice
    c.enabled:Click()
    eq(ns.char.voice.enabled, true)
end)

test("formulaires : anecdote manuelle marquee 'declare'", function()
    local ns = boot({ specIndex = 1 })
    ns.UI.Open("journal")
    for _, open in pairs(ns.UI.Dialogs) do if open ~= ns.UI.Dialogs.Open then open() end end
    local ev = ns.Store.AddManual("ANECDOTE", { title = "Test" })
    eq(ev.prov, "MAN")
    eq(ev.src, "M")
    eq(ns.db.events[ev.id], ev)
end)

test("formulaire en demo : rien n'est sauvegarde", function()
    local ns = boot({ specIndex = 1 })
    ns.char.ui.demo = true
    ns.Store.AddManual("ANECDOTE", { title = "Test" })
    eq(ns.Store.Count(), 0)
end)


print("Voix : specialisations (Retail / Forever)")

test("spe reconnue par identifiant : guerrier Protection (73) = tank corps a corps", function()
    local ns = boot({ class = "WARRIOR", specIndex = 3, specID = 73, specRole = "TANK" })
    eq(table.concat(ns.Voice:GetCombatFamilies(), ","), "fightGeneric,fightTank,fightMelee")
end)

test("chasseur : Precision (254) distance, Survie (255) corps a corps", function()
    eq(boot({ class = "HUNTER", specIndex = 2, specID = 254 }).Voice.characterType, "ranged")
    eq(boot({ class = "HUNTER", specIndex = 3, specID = 255 }).Voice.characterType, "melee")
end)

test("spe inconnue (Forever) : role de la spe garde, type par la classe ou rien", function()
    local ns = boot({ class = "DRUID", specIndex = 2, specID = 9999, specRole = "HEALER" })
    eq(ns.Voice.role, "HEALER")
    eq(ns.Voice.characterType, nil, "druide : pas de devinette")
    eq(table.concat(ns.Voice:GetCombatFamilies(), ","), "fightGeneric,fightHealer")
end)

test("reglage manuel du role et du style", function()
    local ns = boot({ class = "SHAMAN", specIndex = nil })
    ns.char.voice.roleOverride = "HEALER"
    ns.char.voice.typeOverride = "caster"
    ns.Voice:RebuildPools()
    eq(table.concat(ns.Voice:GetCombatFamilies(), ","), "fightGeneric,fightHealer,fightCaster")
    eq(ns.Voice.roleSource, "manuel")
end)

print("Synchronisation")

local ALICE = { guid = "Player-1-AAA", name = "Alice" }
local BOB = { guid = "Player-1-BBB", name = "Bob" }
local CAROL = { guid = "Player-1-CCC", name = "Carol" }

-- Messages complets (morceaux reassembles) emis par le client courant.
local function decodeSent(ns, sent)
    local out, acc = {}, nil
    for _, m in ipairs(sent) do
        local tag, body = m.msg:sub(1, 1), m.msg:sub(2)
        if tag == "S" then table.insert(out, ns.Serialize.Decode(body))
        elseif tag == "F" then acc = { body }
        elseif tag == "M" then table.insert(acc, body)
        elseif tag == "L" then table.insert(acc, body); table.insert(out, ns.Serialize.Decode(table.concat(acc))); acc = nil end
    end
    return out
end

local function ops(ns, sent, op)
    local out = {}
    for _, m in ipairs(decodeSent(ns, sent)) do if m.o == op then table.insert(out, m) end end
    return out
end

test("serialisation : aller-retour, caracteres speciaux, entree invalide", function()
    local ns = boot({ specIndex = 1 })
    local v = { a = "x;y~z\n|é", n = -3.25, big = 1795000000, t = true, f = false, list = { 1, "deux", { 3 } } }
    local text = ns.Serialize.Encode(v)
    assert(not text:find("\n"), "pas de saut de ligne brut")
    local back = ns.Serialize.Decode(text)
    eq(back.a, v.a); eq(back.n, -3.25); eq(back.big, 1795000000); eq(back.t, true); eq(back.f, false)
    eq(back.list[2], "deux"); eq(back.list[3][1], 3)
    eq(ns.Serialize.Encode(v), text, "deterministe")
    eq(ns.Serialize.Decode("{s1;"), nil)
    eq(ns.Serialize.Decode("zzz"), nil)
    eq(ns.Serialize.Decode(text .. "x"), nil)
end)

test("evenement public diffuse, evenement prive jamais", function()
    local ns, S = boot({ specIndex = 1, me = ALICE })
    ns.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD")
    Stub.fire("PLAYER_LEVEL_UP", 21)       -- progression : privee
    Stub.advance(2)
    local es = ops(ns, S.sent, "E")
    eq(#es, 1)
    eq(es[1].e.k, "DEATH")
    eq(es[1].e.vis, "G")
    for _, m in ipairs(S.sent) do
        eq(m.channel, "GUILD"); eq(m.prefix, "GChron")
        assert(not m.msg:find("LEVEL_UP"), "evenement prive envoye !")
    end
end)

test("reception : evenement insere, verifie (recu de l'auteur), visible dans Guilde", function()
    local nsA, SA = boot({ specIndex = 1, me = ALICE })
    nsA.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD")
    Stub.advance(2)
    local sent = SA.sent
    local ns = boot({ specIndex = 1, me = BOB })
    Stub.deliver(sent, "Alice-Forever")
    local ev = ns.db.events["Player-1-AAA:1"]
    assert(ev, "evenement recu")
    eq(ev.n, "Alice")
    eq(ev.rx.direct, true)
    local ds = ns.Store.Dataset()
    eq(#ns.Views.Filter(ds.events, { guild = ds.guildKey }), 1)
end)

test("message long (article) : decoupe en morceaux <= 255 octets et reassemble", function()
    local ns, S = boot({ specIndex = 1, me = ALICE })
    local body = string.rep("La rédaction s'étonne ; ~ encore. ", 60)
    local ev = ns.Store.Add("ARTICLE", { title = "Long", body = body }, { vis = "G", prov = "GEN", noExp = true })
    Stub.advance(20)
    assert(#S.sent > 5, "plusieurs morceaux")
    local nsB = boot({ specIndex = 1, me = BOB })
    Stub.deliver(S.sent, "Alice-Forever")
    eq(nsB.db.events[ev.id].p.body, body)
end)

test("trou dans la sequence : demande ciblee, l'auteur repond", function()
    local nsA, SA = boot({ specIndex = 1, me = ALICE })
    nsA.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD"); Stub.fire("PLAYER_DEAD")
    Stub.advance(5)
    local savedA, savedAC = GuildChronicleDB, GuildChronicleCharDB
    -- regroupe les morceaux de chaque message, garde ceux de l'evenement n°2
    local onlySecond, current = {}, {}
    for _, m in ipairs(SA.sent) do
        table.insert(current, m)
        local tag = m.msg:sub(1, 1)
        if tag == "S" or tag == "L" then
            local d = decodeSent(nsA, current)[1]
            if d and d.o == "E" and d.e.s == 2 then for _, x in ipairs(current) do table.insert(onlySecond, x) end end
            current = {}
        end
    end
    assert(#onlySecond >= 1)
    -- Bob ne recoit que le n°2 : il demande le n°1
    local nsB, SB = boot({ specIndex = 1, me = BOB })
    Stub.deliver(onlySecond, "Alice-Forever")
    Stub.advance(2)
    local rs = ops(nsB, SB.sent, "R")
    eq(#rs, 1); eq(rs[1].a, ALICE.guid); eq(rs[1].f, 1); eq(rs[1].t, 1)
    local savedB, savedBC, requestMsgs = GuildChronicleDB, GuildChronicleCharDB, SB.sent
    -- Alice recoit la demande et renvoie le n°1
    local nsA2, SA2 = boot({ specIndex = 1, me = ALICE, savedAccount = savedA, savedChar = savedAC })
    Stub.deliver(requestMsgs, "Bob-Forever")
    Stub.advance(3)
    local es = ops(nsA2, SA2.sent, "E")
    eq(#es, 1); eq(es[1].e.s, 1)
    local answer = SA2.sent
    local nsB2 = boot({ specIndex = 1, me = BOB, savedAccount = savedB, savedChar = savedBC })
    Stub.deliver(answer, "Alice-Forever")
    eq(nsB2.Sync.Vector()[ALICE.guid].max, 2)
end)

test("vecteurs : un nouveau venu rattrape l'historique via un relais", function()
    -- Bob possede 2 evenements d'Alice ; Carol n'a rien.
    local nsA, SA = boot({ specIndex = 1, me = ALICE })
    nsA.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD"); Stub.fire("PLAYER_DEAD")
    Stub.advance(5)
    local fromAlice = SA.sent
    local nsB = boot({ specIndex = 1, me = BOB })
    Stub.deliver(fromAlice, "Alice-Forever")
    local savedB, savedBC = GuildChronicleDB, GuildChronicleCharDB
    -- Carol se connecte et annonce son vecteur (vide)
    local nsC, SC = boot({ specIndex = 1, me = CAROL })
    Stub.advance(31)
    eq(#ops(nsC, SC.sent, "V"), 1)
    local savedC, savedCC, carolV = GuildChronicleDB, GuildChronicleCharDB, SC.sent
    -- Bob voit que Carol est en retard : il annonce le sien
    local nsB2, SB2 = boot({ specIndex = 1, me = BOB, savedAccount = savedB, savedChar = savedBC })
    Stub.deliver(carolV, "Carol-Forever")
    Stub.advance(10)
    local vs = ops(nsB2, SB2.sent, "V")
    assert(#vs >= 1, "Bob annonce son vecteur")
    eq(vs[1].v[ALICE.guid], 2)
    local bobV = SB2.sent
    -- Carol demande, Bob (relais) repond
    local nsC2, SC2 = boot({ specIndex = 1, me = CAROL, savedAccount = savedC, savedChar = savedCC })
    Stub.deliver(bobV, "Bob-Forever")
    Stub.advance(2)
    local rs = ops(nsC2, SC2.sent, "R")
    eq(#rs, 1); eq(rs[1].f, 1); eq(rs[1].t, 2)
    local carolR, savedC2, savedCC2 = SC2.sent, GuildChronicleDB, GuildChronicleCharDB
    local nsB3, SB3 = boot({ specIndex = 1, me = BOB, savedAccount = savedB, savedChar = savedBC })
    Stub.deliver(carolR, "Carol-Forever")
    Stub.advance(10)
    eq(#ops(nsB3, SB3.sent, "E"), 2)
    local relayed = SB3.sent
    local nsC3 = boot({ specIndex = 1, me = CAROL, savedAccount = savedC2, savedChar = savedCC2 })
    Stub.deliver(relayed, "Bob-Forever")
    local ev = nsC3.db.events["Player-1-AAA:2"]
    assert(ev, "recu par relais")
    eq(ev.rx.direct, nil); eq(ev.rx.by, "Bob")
end)

test("rejets : autre guilde, prive, identifiant falsifie", function()
    local ns = boot({ specIndex = 1, me = BOB })
    local function deliverEvent(e)
        local text = ns.Serialize.Encode({ o = "E", g = "Les Testeurs-Forever", e = e })
        Stub.deliver({ { prefix = "GChron", channel = "GUILD", msg = "S" .. text } }, "Mallory-Forever")
    end
    local base = { v = 1, id = "Player-1-AAA:1", a = "Player-1-AAA", n = "Alice", s = 1, t = 1, k = "DEATH",
        g = "Les Testeurs-Forever", vis = "G", p = {}, prov = "OBS" }
    local function copy(over) local t = {} for k, v in pairs(base) do t[k] = v end for k, v in pairs(over) do t[k] = v end return t end
    deliverEvent(copy({ g = "Autre-Forever" }))
    deliverEvent(copy({ vis = "P" }))
    deliverEvent(copy({ id = "Player-1-AAA:7" }))
    deliverEvent(copy({ prov = "VRAI" }))
    eq(ns.Store.Count(), 0)
    eq(ns.Sync.Status().rejected, 4)
    deliverEvent(copy({ secret = "x" }))
    eq(ns.Store.Count(), 1)
    eq(ns.db.events["Player-1-AAA:1"].secret, nil, "champ hors schema retire")
    eq(ns.db.events["Player-1-AAA:1"].rx.direct, nil, "envoye par un autre que l'auteur : relaye")
end)

test("pas d'envoi en instance ni en combat ; reprise a la sortie", function()
    local ns, S = boot({ specIndex = 1, me = ALICE, instance = { type = "party", name = "Mortemines", iid = 36 } })
    ns.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD")
    Stub.advance(5)
    eq(#S.sent, 0, "rien en instance")
    S.instance = nil
    S.inCombat = true
    Stub.advance(5)
    eq(#S.sent, 0, "rien en combat")
    S.inCombat = false
    Stub.advance(2)
    eq(#ops(ns, S.sent, "E"), 1)
end)

test("debit limite : rafale de 4 puis 1 message par 1,2 s", function()
    local ns, S = boot({ specIndex = 1, me = ALICE })
    for i = 1, 10 do ns.Transport.Send("x" .. i) end
    Stub.advance(0.1)
    eq(#S.sent, 4)
    Stub.advance(12)
    eq(#S.sent, 10)
end)

print("Expeditions")

local ROSTER = { { name = "Bob" }, { name = "Testeur" } }

test("donjon : debut a l'entree, boss rattache, fin 10 min apres la sortie", function()
    local ns, S = boot({ specIndex = 1, roster = ROSTER, group = { { guid = BOB.guid, name = "Bob", leader = true }, { guid = "Player-9-X", name = "Inconnu" } } })
    S.instance = { type = "party", name = "Mortemines", iid = 36 }
    Stub.fire("PLAYER_ENTERING_WORLD")
    local st = ns.Expedition:Current()
    eq(st.kind, "DUNGEON")
    eq(st.leader, BOB.guid)
    Stub.advance(400)
    Stub.fire("ENCOUNTER_END", 1, "VanCleef", 1, 5, 1)
    local boss = eventsOf(ns, "BOSS_KILL")[1]
    eq(boss.x, st.key)
    S.instance = nil
    Stub.fire("ZONE_CHANGED_NEW_AREA")
    Stub.advance(300)
    eq(#eventsOf(ns, "EXPEDITION"), 0, "tolerance de sortie")
    Stub.advance(330)
    local exp = eventsOf(ns, "EXPEDITION")[1]
    assert(exp, "expedition cloturee")
    eq(exp.p.type, "DUNGEON"); eq(exp.p.inst, "Mortemines"); eq(exp.p.bosses, 1)
    eq(exp.p.bossNames[1], "VanCleef")
    eq(exp.p.others, 1, "joueur hors guilde compte, pas nomme")
    eq(#exp.pt, 1); eq(exp.pt[1].n, "Bob")
    eq(exp.x, nil)
    eq(ns.Expedition:Current(), nil)
    assert(ns.Types.Describe(exp, true):find("Mortemines"), "texte")
end)

test("donjon : ressortir et revenir (reparation) = meme expedition", function()
    local ns, S = boot({ specIndex = 1 })
    S.instance = { type = "party", name = "Mortemines", iid = 36 }
    Stub.fire("PLAYER_ENTERING_WORLD")
    local key = ns.Expedition:CurrentKey()
    S.instance = nil; Stub.fire("ZONE_CHANGED_NEW_AREA"); Stub.advance(200)
    S.instance = { type = "party", name = "Mortemines", iid = 36 }; Stub.fire("PLAYER_ENTERING_WORLD")
    Stub.advance(700)
    eq(ns.Expedition:CurrentKey(), key)
end)

test("passage eclair sans rien de notable : oublie", function()
    local ns, S = boot({ specIndex = 1 })
    S.instance = { type = "party", name = "Mortemines", iid = 36 }
    Stub.fire("PLAYER_ENTERING_WORLD")
    Stub.advance(30)
    S.instance = nil; Stub.fire("ZONE_CHANGED_NEW_AREA")
    Stub.advance(700)
    eq(#eventsOf(ns, "EXPEDITION"), 0)
end)

test("groupe avec un membre de la guilde : expedition QUESTING, fin a la dissolution", function()
    local ns, S = boot({ specIndex = 1, roster = ROSTER })
    S.group = { { guid = BOB.guid, name = "Bob-Forever" } }
    Stub.fire("GROUP_ROSTER_UPDATE")
    eq(ns.Expedition:Current().kind, "QUESTING")
    Stub.advance(200)
    Stub.fire("QUEST_TURNED_IN", 42)
    Stub.advance(200)
    S.group = {}
    Stub.fire("GROUP_ROSTER_UPDATE")
    local exp = eventsOf(ns, "EXPEDITION")[1]
    eq(exp.p.type, "QUESTING"); eq(exp.p.quests, 1); eq(exp.pt[1].n, "Bob")
end)

test("groupe sans membre de la guilde : pas d'expedition", function()
    local ns, S = boot({ specIndex = 1, roster = ROSTER })
    S.group = { { guid = "Player-9-X", name = "Inconnu" } }
    Stub.fire("GROUP_ROSTER_UPDATE")
    eq(ns.Expedition:Current(), nil)
end)

test("deconnexion pendant une expedition : fin estimee a la connexion suivante", function()
    local ns, S = boot({ specIndex = 1 })
    S.instance = { type = "raid", name = "Molten Core", iid = 409 }
    Stub.fire("PLAYER_ENTERING_WORLD")
    Stub.advance(1000)
    Stub.fire("PLAYER_DEAD")
    Stub.fire("PLAYER_LOGOUT")
    local savedA, savedC = GuildChronicleDB, GuildChronicleCharDB
    local ns2, S2 = boot({ specIndex = 1, savedAccount = savedA, savedChar = savedC })
    -- reconnexion "plus tard", hors instance : le stub repart de t=0, on simule l'ecart
    S2.now = 5000
    ns2.Expedition:OnLogin()
    local exp = eventsOf(ns2, "EXPEDITION")[1]
    assert(exp, "cloturee")
    eq(exp.ded[1], "finish"); eq(exp.p.type, "RAID"); eq(exp.p.deaths, 1)
end)

print("Tableau de chasse automatique")

local GORBASH = { name = "Gorbash", realm = "Forever", guild = "Les Crocs de Sang", level = 25, race = "Orc", class = "WARRIOR", pvp = true }

test("sans guilde rivale configuree : rien n'est enregistre", function()
    local ns = boot({ specIndex = 1, units = { target = GORBASH } })
    Stub.fire("PLAYER_TARGET_CHANGED")
    eq(#eventsOf(ns, "ENEMY_SEEN"), 0)
end)

test("rival cible : fiche creee, une observation par 10 min", function()
    local ns, S = boot({ specIndex = 1, units = { target = GORBASH, mouseover = GORBASH } })
    ns.char.rivalGuild = "les crocs de sang "
    Stub.fire("PLAYER_TARGET_CHANGED")
    Stub.fire("UPDATE_MOUSEOVER_UNIT")
    eq(#eventsOf(ns, "ENEMY_SEEN"), 1)
    local ev = eventsOf(ns, "ENEMY_SEEN")[1]
    eq(ev.p.name, "Gorbash"); eq(ev.p.level, 25); eq(ev.p.class, "WARRIOR"); eq(ev.p.race, "Orc")
    Stub.advance(601)
    Stub.fire("UPDATE_MOUSEOVER_UNIT")
    eq(#eventsOf(ns, "ENEMY_SEEN"), 2)
    local enemies = ns.Views.Enemies(ns.Store.Dataset())
    eq(#enemies, 1); eq(enemies[1].level, 25)
end)

test("autre guilde, PNJ ou nom secret : ignores", function()
    local secret = { name = { secret = true }, guild = "Les Crocs de Sang" }
    local ns = boot({ specIndex = 1, units = {
        target = { name = "Passant", guild = "Les Gentils" },
        mouseover = { name = "Garde", guild = "Les Crocs de Sang", player = false },
        nameplate1 = secret } })
    ns.char.rivalGuild = "Les Crocs de Sang"
    Stub.fire("PLAYER_TARGET_CHANGED"); Stub.fire("UPDATE_MOUSEOVER_UNIT"); Stub.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(#eventsOf(ns, "ENEMY_SEEN"), 0)
end)

test("mort juste apres avoir vu un rival : present (suppose), pas tueur", function()
    local ns = boot({ specIndex = 1, units = { nameplate3 = GORBASH } })
    ns.char.rivalGuild = "Les Crocs de Sang"
    Stub.fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    Stub.advance(10)
    Stub.fire("PLAYER_DEAD")
    local death = eventsOf(ns, "DEATH")[1]
    eq(death.p.enemies[1], "Gorbash"); eq(death.ded[1], "enemies"); eq(death.prov, "OBS")
    local enemies = ns.Views.Enemies(ns.Store.Dataset())
    eq(enemies[1].presentAtDeaths, 1)
    eq(ns.Views.Total(enemies[1].losses), 0, "aucune defaite inventee")
    Stub.advance(60)
    Stub.fire("PLAYER_DEAD")
    local withEnemies = 0
    for _, d in ipairs(eventsOf(ns, "DEATH")) do if d.p.enemies then withEnemies = withEnemies + 1 end end
    eq(withEnemies, 1, "fenetre de 30 s")
end)

print("Presse (compagnon)")

local function withPress(items)
    GuildChroniclePress = { version = 1, items = items }
end

test("elements du compagnon : en attente, publies signes LOG / GEN, jamais automatiques", function()
    local ns = boot({ specIndex = 1 })
    ns.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD")
    local death = eventsOf(ns, "DEATH")[1]
    withPress({
        { id = "c1", kind = "DEATH_CAUSE", t = death.t, refs = { death.id },
          p = { victim = "Testeur", cause = "Hogger (Coup de massue)", killer = "Hogger" } },
        { id = "a1", kind = "ARTICLE", refs = { death.id },
          p = { title = "Drame à Elwynn", body = "Selon nos sources...", style = "sarcastique", format = "Brève" } },
        { id = "bad", kind = "INCONNU", p = {} },
    })
    eq(#ns.Press.Pending(), 2)
    eq(#eventsOf(ns, "DEATH_CAUSE"), 0, "rien de publie tout seul")
    local cause = ns.Press.Publish(ns.Press.Pending()[1])
    eq(cause.prov, "LOG"); eq(cause.vis, "G"); eq(cause.refs[1], death.id); eq(cause.t, death.t)
    local ds = ns.Store.Dataset()
    eq(ds.causes[death.id], cause)
    eq(#ns.Views.Filter(ds.events, {}), 1, "DEATH_CAUSE masque de la chronologie (affiche sur la mort)")
    ns.UI.Open("journal")
    local row = GuildChronicleMainFrame.containers.journal.list.rows[1]
    assert(row.line2:GetText():find("Hogger"), "cause affichee sur la ligne de la mort")
    ns.Press.Ignore(ns.Press.Pending()[1])
    eq(#ns.Press.Pending(), 0)
    local clash = ns.Store.Add("PVP_CLASH", { name = "Gorbash", result = "loss", member = "Bob" }, { prov = "LOG", vis = "G" })
    eq(ns.Types.Describe(clash, true), "Testeur rapporte : Bob tombe face à Gorbash")
    local e = ns.Views.Enemies(ns.Store.Dataset())[1]
    eq(e.losses.LOG, 1); eq(e.memberList[1], "Bob")
    local savedA, savedC = GuildChronicleDB, GuildChronicleCharDB
    local ns2 = boot({ specIndex = 1, savedAccount = savedA, savedChar = savedC })
    eq(#ns2.Press.Pending(), 0, "decisions memorisees")
    GuildChroniclePress = nil
end)

test("gazette reelle : article publie, vote une fois par semaine", function()
    local ns = boot({ specIndex = 1 })
    withPress({ { id = "a1", kind = "ARTICLE", p = { title = "Une", body = "Texte", style = "épique", format = "Hebdomadaire" } } })
    local art = ns.Press.Publish(ns.Press.Pending()[1])
    eq(art.prov, "GEN")
    ns.UI.Open("gazette")
    local c = GuildChronicleMainFrame.containers.gazette
    eq(c.current.id, art.id)
    eq(c.current.author, "Testeur")
    c.paper.vote:Click()
    eq(c.current.votes, 1); eq(c.current.voted, true)
    c.paper.vote:Click()
    eq(c.current.votes, 1, "pas de double vote")
    c.press:Click()
    GuildChroniclePress = nil
end)

test("consentement gazette IA : publie et partage, le dernier choix compte", function()
    local ns = boot({ specIndex = 1 })
    eq(#eventsOf(ns, "AI_CONSENT"), 0, "rien coche : rien a annoncer")
    ns.UI.Open("settings")
    local c = GuildChronicleMainFrame.containers.settings
    c.export:Click()
    local ev = eventsOf(ns, "AI_CONSENT")[1]
    eq(ev.vis, "G", "partage meme si la categorie est privee"); eq(ev.p.ok, true)
    eq(#ns.Views.Filter(ns.Store.Dataset().events, {}), 0, "masque de la chronologie")
    ns.Press.SetConsent(true)
    eq(#eventsOf(ns, "AI_CONSENT"), 1, "pas de doublon")
    c.export:Click()
    eq(#eventsOf(ns, "AI_CONSENT"), 2)
    eq(ns.Press.LastConsent().p.ok, false, "retrait du consentement")
    eq(ns.char.exportConsent, false)
end)

print("Interface (v0.3)")

test("parametres : etat de la synchronisation ; voix : reglages manuels", function()
    local ns = boot({ specIndex = 1 })
    ns.UI.Open("settings")
    local c = GuildChronicleMainFrame.containers.settings
    assert(c.syncInfo:GetText():find("Membres"), "etat de synchro")
    c.syncNow:Click()
    ns.UI.Open("voice")
    local v = GuildChronicleMainFrame.containers.voice
    assert(v.status:GetText():find("Rôle"), "statut voix")
end)

print(string.format("\n%d ok, %d echec(s)", passed, failed))
os.exit(failed == 0 and 0 or 1)
