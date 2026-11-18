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

print(string.format("\n%d ok, %d echec(s)", passed, failed))
os.exit(failed == 0 and 0 or 1)
