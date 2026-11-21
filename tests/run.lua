-- tests/run.lua: run from the repository root with `lua tests/run.lua`.
package.path = "./tests/?.lua;" .. package.path
local Stub = require("wow_stub")
local print = print -- the stub replaces the print global

local ROOT, NAME = "Renatus", "Renatus"
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

-- The AI consent is on by default and announced at login (one shared event). Tests that
-- are not about it start with a character who said no, so event numbering stays simple;
-- opts.consent = "default" keeps the real default.
local function withConsent(opts)
    opts = opts or {}
    if opts.consent ~= "default" and opts.savedChar == nil then
        opts.savedChar = { schema = 1, exportConsent = false, consentChosen = true }
    end
    return opts
end

local function boot(opts)
    local S = Stub.reset(withConsent(opts))
    local ns = Stub.loadAddon(ROOT, NAME)
    for _, line in ipairs(S.printed) do
        if line:find("erreur") then error("erreur au chargement : " .. line, 2) end
    end
    return ns, S
end

-- Renatus + Renatus_Admin (officers' addon). Returns ns, admin namespace, stub state.
local function bootAdmin(opts)
    local S = Stub.reset(withConsent(opts))
    local ns, A = Stub.loadAddon(ROOT, NAME, { { "Renatus_Admin", "Renatus_Admin" } })
    for _, line in ipairs(S.printed) do
        if line:find("erreur") then error("erreur au chargement : " .. line, 2) end
    end
    return ns, A, S
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
    S.randomValue = 0 -- math.random() < probability always true
    Stub.fire("PLAYER_REGEN_DISABLED")
    eq(familyOf(ns, soundName(S.played[1])), "startFight")
    Stub.advance(3.05)
    eq(#S.played, 2, "une replique de combat apres 3 s")
    assert(familyOf(ns, soundName(S.played[2])):match("^fight"), "famille de combat attendue")
    eq(S.played[2].channel, "Ambience")
end)

test("bouton Tester : jamais au hasard, la derniere replique entendue en combat", function()
    local ns, S = boot({ class = "WARRIOR", specIndex = 1 })
    -- Before any fight: always the same sample line, even when spammed, module off or on.
    for _ = 1, 5 do ns.UI.Options.PlaySample() end
    SlashCmdList.RENATUS("voice test")
    eq(#S.played, 6)
    for _, p in ipairs(S.played) do eq(soundName(p), ns.Voice.SAMPLE, "toujours la replique d'exemple") end
    -- A line heard in combat becomes the one the button replays.
    ns.Voice:SetEnabled(true)
    S.inCombat = true
    S.randomValue = 0
    Stub.fire("PLAYER_REGEN_DISABLED")
    Stub.advance(3.05)
    local heard = soundName(S.played[#S.played])
    eq(ns.char.voice.lastHeard, heard)
    S.inCombat = false
    ns.UI.Options.PlaySample()
    ns.UI.Options.PlaySample()
    eq(soundName(S.played[#S.played]), heard)
    eq(soundName(S.played[#S.played - 1]), heard)
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
    local saved = RenatusCharDB
    local ns2 = boot({ specIndex = 1, savedChar = saved })
    eq(ns2.char.voice.enabled, true)
    eq(ns2.char.voice.probability, 0.2)
    eq(ns2.char.voice.interval, 3, "valeur par defaut completee")
end)

test("/renacoach on et /renatus voice off", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENACOACH("on")
    eq(ns.char.voice.enabled, true)
    SlashCmdList.RENATUS("voice off")
    eq(ns.char.voice.enabled, false)
    SlashCmdList.RENATUS("voice prob 0.3")
    eq(ns.char.voice.probability, 0.3)
end)

print("Core")

test("EventBus : un abonne qui plante n'empeche pas les autres", function()
    local ns = boot({ specIndex = 1 })
    local got = 0
    Renatus.Subscribe("X", function() error("boom") end)
    Renatus.Subscribe("X", function(v) got = v end)
    eq(ns.EventBus.Publish("X", 42), 2)
    eq(got, 42)
end)

test("une seule globale exposee en dehors des commandes slash", function()
    boot({ specIndex = 1 })
    for _, name in ipairs({ "OnLoad", "UpdateCombat", "PlayRandomSound", "DuckCombatSounds",
        "RestoreCombatSounds", "GetSpecInfos", "ConcatenateLists", "GetCharacterType", "playerClassID" }) do
        eq(rawget(_G, name), nil, "globale " .. name)
    end
    assert(type(Renatus) == "table")
end)


print("Collecteurs")

local function eventsOf(ns, kind)
    local out = {}
    for _, ev in pairs(ns.db.events) do if ev.k == kind then table.insert(out, ev) end end
    return out
end

test("passage de niveau : un evenement prive, observe, avec lieu", function()
    local ns = boot({ specIndex = 1 })
    ns.char.privacy.progression = "P"
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

test("confidentialite : partage avec la guilde par defaut, anciens personnages migres", function()
    local ns = boot({ specIndex = 1 })
    for _, cat in ipairs(ns.Types.CATEGORIES) do eq(ns.char.privacy[cat.key], "G", cat.key) end
    Stub.fire("PLAYER_LEVEL_UP", 21)
    eq(eventsOf(ns, "LEVEL_UP")[1].vis, "G")
    -- character saved before the new default: "P" becomes "G", "OFF" is kept, told once
    local ns2, S = boot({ specIndex = 1, savedChar = { schema = 1, exportConsent = false, consentChosen = true,
        privacy = { progression = "P", combat = "OFF", pvp = "G" } } })
    eq(ns2.char.privacy.progression, "G"); eq(ns2.char.privacy.combat, "OFF"); eq(ns2.char.privacy.pvp, "G")
    eq(ns2.char.privacy.album, "G", "categorie absente : nouveau defaut")
    eq(ns2.char.schema, 2)
    local told = false
    for _, line in ipairs(S.printed) do if line:find("partagés avec la guilde par défaut") then told = true end end
    assert(told, "message au chargement")
    -- next login: no migration, no message, a private choice is kept
    ns2.char.privacy.progression = "P"
    local _, S3 = boot({ specIndex = 1, savedAccount = RenatusDB, savedChar = RenatusCharDB })
    eq(RenatusCharDB.privacy.progression, "P")
    for _, line in ipairs(S3.printed) do assert(not line:find("par défaut"), "message une seule fois") end
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
    local savedA, savedC = RenatusDB, RenatusCharDB
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
    SlashCmdList.RENATUS("")
    assert(RenatusMainFrame:IsShown(), "fenetre ouverte")
    openAllTabs(ns)
    eq(#ns.UI.tabs, 5, "gazette, album + 3 journaux (pas de journal de guilde) ; les reglages sont dans les Options")
    eq(ns.UI.tabs[1].key, "gazette"); eq(ns.UI.tabs[2].key, "album"); eq(ns.UI.tabs[3].key, "wanted")
    eq(ns.UI.tabs[3].group, "main", "tableau de chasse en grand, sous l'album")
    assert(RenatusMainFrame.journalsLabel, "section journaux")
end)

test("tous les onglets s'ouvrent (demo) et se remplissent", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    openAllTabs(ns)
    local f = RenatusMainFrame
    assert(#f.containers.journal.list.items > 5, "journal rempli")
    eq(f.containers.guild, nil, "pas de journal de guilde : les faits des autres passent par la gazette")
    assert(#f.containers.members.list.items >= 9, "membres")
end)

test("membres : les derniers faits des autres ne s'affichent pas (pas de spoiler de la gazette)", function()
    local ns = boot({ specIndex = 1, roster = { { name = "Testeur", rank = 1 }, { name = "Bob", rank = 5 } } })
    ns.char.privacy.progression = "G"
    Stub.fire("PLAYER_LEVEL_UP", 21)
    local guid = "Player-1-BOB"
    ns.Store.Insert({ v = 1, id = guid .. ":1", a = guid, n = "Bob", s = 1, k = "LEVEL_UP", t = 1000, vis = "G",
        g = ns.Context.GuildKey(), p = { lvl = 40 } })
    ns.UI.Open("members")
    local c = RenatusMainFrame.containers.members
    c.selected = "Bob"; c:Refresh()
    local p = c.profile
    local text = p.recent[1]:GetText() or ""
    assert(text:find("gazette"), text)
    c.selected = "Testeur"; c:Refresh()
    text = p.recent[1]:GetText() or ""
    assert(text:find("21"), text)
end)

test("tableau de chasse : affiches, registre, fiche", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("wanted")
    local c = RenatusMainFrame.containers.wanted
    -- overview first: rival guild, score, most feared, news, shortcut to the posters
    eq(c.view, "home")
    assert(c.home:IsShown() and not c.posters:IsShown(), "accueil par defaut")
    eq(c.home.guild:GetText(), "<Les Crocs de Sang>")
    assert(c.home.score:GetText():find("–"), "score")
    local top = c.home.feared[1]
    assert(top:IsShown() and top.enemy, "le plus redoute")
    assert(c.home.news[1].line:GetText() ~= "", "nouvelles du front")
    top:Click()
    assert(c.detailFrame:IsShown() and not c.home:IsShown(), "fiche depuis l'accueil")
    c.detail = nil; c:Refresh()
    assert(c.home.postersLink.label:GetText():find("avis de recherche"), c.home.postersLink.label:GetText())
    c.home.postersLink:Click()
    eq(c.view, "posters")
    eq(c.posters.items[1].poster ~= nil, true)
    c.posters.items[1]:Click()
    assert(c.detailFrame:IsShown(), "fiche affichee")
    c.view = "registry"; c.detail = nil; c:Refresh()
    assert(c.registry:IsShown() and #c.registry.items == 4, "registre")
end)

test("gazette : article et sources", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    assert(c.current, "article selectionne")
    c.paper.sources:Click()
    assert(c.showSources, "sources affichees")
end)

test("album : force et endurance des creatures, bonus des objets", function()
    local ns = boot({ specIndex = 1 })
    local A = ns.Album
    local byId = {}
    for _, c in ipairs(ns.Cards.LIST) do byId[c.id] = c end
    local fo, en, item = A.Stats(byId["AZ:donjons:ragnaros"])
    eq(fo, 11); eq(en, 10); eq(item, false)
    fo, en, item = A.Stats(byId["AZ:tresors:potion"])
    eq(fo, 0); eq(en, 2); eq(item, true, "objet")
    eq(A.Stats(byId["AZ:est:elwynn"]), nil, "un lieu n'a pas de stats")
    -- guild cards: the rule (budget by rarity, split by class), unless the set gives them
    fo, en = A.Stats({ series = "members", rarity = "epic", class = "MAGE" })
    eq(fo, 8); eq(en, 5)
    eq(A.Stats({ series = "faits", rarity = "rare" }), nil, "un fait divers n'a pas de stats")
    local ev = { t = 1, p = { set = "x" } }
    local c = A.FromPayload({ id = "M:G:rare", n = "Dakey", r = "rare", s = "members", fo = 7, en = 2 }, ev)
    fo, en = A.Stats(c)
    eq(fo, 7); eq(en, 2)
    c = A.FromPayload({ id = "M:G:rare", n = "Dakey", r = "rare", s = "members", fo = 40, en = 2 }, ev)
    eq(c.fo, nil, "hors bornes : ignore")
end)

test("album : ouvrir un booster en demo", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("album")
    local ds = ns.Store.Dataset()
    local before = ds.boosters
    RenatusMainFrame.containers.album.booster:Click()
    eq(ds.boosters, before - 1)
end)

test("voix : la case des Options active le module", function()
    local ns, S = boot({ specIndex = 1, settingsApi = true })
    S.settings.byVar.Renatus_voice:SetValue(true)
    eq(ns.char.voice.enabled, true)
    S.settings.byVar.Renatus_voiceProbability:SetValue(0.8)
    eq(ns.char.voice.probability, 0.8)
    S.settings.byVar.Renatus_voiceFamily_death:SetValue(false)
    eq(ns.char.voice.families.death, false)
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

-- Complete messages (chunks reassembled) sent by the current client.
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
    ns.char.privacy.progression = "P"
    Stub.fire("PLAYER_DEAD")
    Stub.fire("PLAYER_LEVEL_UP", 21)       -- progression: private
    Stub.advance(2)
    local es = ops(ns, S.sent, "E")
    eq(#es, 1)
    eq(es[1].e.k, "DEATH")
    eq(es[1].e.vis, "G")
    for _, m in ipairs(S.sent) do
        eq(m.channel, "GUILD"); eq(m.prefix, "Renatus")
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
    local savedA, savedAC = RenatusDB, RenatusCharDB
    -- regroup the chunks of each message, keep those of event #2
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
    -- Bob only receives #2: he requests #1
    local nsB, SB = boot({ specIndex = 1, me = BOB })
    Stub.deliver(onlySecond, "Alice-Forever")
    Stub.advance(2)
    local rs = ops(nsB, SB.sent, "R")
    eq(#rs, 1); eq(rs[1].a, ALICE.guid); eq(rs[1].f, 1); eq(rs[1].t, 1)
    local savedB, savedBC, requestMsgs = RenatusDB, RenatusCharDB, SB.sent
    -- Alice receives the request and resends #1
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
    -- Bob holds 2 of Alice's events; Carol has nothing.
    local nsA, SA = boot({ specIndex = 1, me = ALICE })
    nsA.char.privacy.combat = "G"
    Stub.fire("PLAYER_DEAD"); Stub.fire("PLAYER_DEAD")
    Stub.advance(5)
    local fromAlice = SA.sent
    local nsB = boot({ specIndex = 1, me = BOB })
    Stub.deliver(fromAlice, "Alice-Forever")
    local savedB, savedBC = RenatusDB, RenatusCharDB
    -- Carol logs in and announces her (empty) vector
    local nsC, SC = boot({ specIndex = 1, me = CAROL })
    Stub.advance(31)
    eq(#ops(nsC, SC.sent, "V"), 1)
    local savedC, savedCC, carolV = RenatusDB, RenatusCharDB, SC.sent
    -- Bob sees Carol is behind: he announces his own
    local nsB2, SB2 = boot({ specIndex = 1, me = BOB, savedAccount = savedB, savedChar = savedBC })
    Stub.deliver(carolV, "Carol-Forever")
    Stub.advance(10)
    local vs = ops(nsB2, SB2.sent, "V")
    assert(#vs >= 1, "Bob annonce son vecteur")
    eq(vs[1].v[ALICE.guid], 2)
    local bobV = SB2.sent
    -- Carol requests, Bob (relay) answers
    local nsC2, SC2 = boot({ specIndex = 1, me = CAROL, savedAccount = savedC, savedChar = savedCC })
    Stub.deliver(bobV, "Bob-Forever")
    Stub.advance(2)
    local rs = ops(nsC2, SC2.sent, "R")
    eq(#rs, 1); eq(rs[1].f, 1); eq(rs[1].t, 2)
    local carolR, savedC2, savedCC2 = SC2.sent, RenatusDB, RenatusCharDB
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
        Stub.deliver({ { prefix = "Renatus", channel = "GUILD", msg = "S" .. text } }, "Mallory-Forever")
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
    local savedA, savedC = RenatusDB, RenatusCharDB
    local ns2, S2 = boot({ specIndex = 1, savedAccount = savedA, savedChar = savedC })
    -- reconnect "later", outside instances: the stub restarts at t=0, simulate the gap
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

print("Reglages de guilde (officiers)")

local OFFICERS = { { name = "Testeur", rank = 1 }, { name = "Bob", rank = 1 }, { name = "Carol", rank = 4 } }

-- A GUILD_CONFIG event as received from another member.
local function receivedConfig(ns, who, s, t, rival)
    local ev = { v = 1, id = who.guid .. ":" .. s, a = who.guid, n = who.name, s = s, t = t, k = "GUILD_CONFIG",
        g = ns.Context.GuildKey(), vis = "G", prov = "MAN", p = { rival = rival } }
    assert(ns.Store.Insert(ev))
    return ev
end

test("officier : guilde rivale diffusee depuis Renatus_Admin, appliquee au tableau de chasse", function()
    local ns, A, S = bootAdmin({ specIndex = 1, rank = 1, roster = OFFICERS, units = { target = GORBASH } })
    eq(ns.GuildConfig.Rival(), nil)
    SlashCmdList.RENATUSADMIN("")
    local panel = A.window.pages.rival
    A.window.tabs.rival:Click()
    eq(panel:IsShown(), true)
    eq(panel.publish.gcDisabled, false, "officier : bouton actif")
    panel.rival:SetText("  Les Crocs de Sang ")
    panel.publish:Click()
    local cfg = eventsOf(ns, "GUILD_CONFIG")[1]
    eq(cfg.vis, "G"); eq(cfg.p.rival, "Les Crocs de Sang")
    eq(ns.GuildConfig.Rival(), "Les Crocs de Sang")
    assert(panel.info:GetText():find("Testeur"), "auteur affiche")
    eq(#ns.Views.Filter(ns.Store.Dataset().events, {}), 0, "masque de la chronologie")
    Stub.fire("PLAYER_TARGET_CHANGED")
    eq(#eventsOf(ns, "ENEMY_SEEN"), 1, "rival observe")
    -- other settings kept when only the rival changes; empty = no rival
    ns.GuildConfig.Publish({ rival = "" })
    eq(ns.GuildConfig.Rival(), nil)
end)

test("simple membre : ne peut pas diffuser, mais applique le reglage d'un officier", function()
    local ns, A = bootAdmin({ specIndex = 1, rank = 3, roster = { { name = "Testeur", rank = 3 }, { name = "Bob", rank = 1 } } })
    local ev, why = ns.GuildConfig.Publish({ rival = "X" })
    eq(ev, nil); eq(why, "rang")
    A.Open("rival")
    eq(A.window.pages.rival.publish.gcDisabled, true, "bouton inactif")
    assert(A.window.status:GetText():find("Consultation"), A.window.status:GetText())
    receivedConfig(ns, BOB, 1, 1000, "Les Crocs de Sang")
    eq(ns.GuildConfig.Rival(), "Les Crocs de Sang")
end)

test("liste de guilde demandee au jeu : le reglage d'un officier s'applique sans ouvrir la fenetre de guilde", function()
    local ns, A, S = bootAdmin({ specIndex = 1, rank = 1, roster = OFFICERS, rosterPending = true })
    assert(S.rosterRequests >= 1, "liste demandee a la connexion")
    Stub.advance(1)
    receivedConfig(ns, BOB, 1, 1000, "Les Crocs de Sang")
    eq(ns.GuildConfig.Rival(), "Les Crocs de Sang")
    A.Open("diag")
    local diag = A.window.pages.diag.guildInfo:GetText()
    assert(diag:find("Liste de guilde : 3 membre") and diag:find("valable") and diag:find("dans la liste : 1"), diag)
end)

test("WoW Forever : prenom + nom dans la liste de guilde, prenom seul ailleurs", function()
    -- by first name (no GUID from the client)
    local ns, A = bootAdmin({ specIndex = 1, rank = 1, roster = { { name = "Testeur", full = "Testeur Dupont", rank = 1 } } })
    ns.GuildConfig.Publish({ rival = "Les Crocs" })
    eq(ns.GuildConfig.Rival(), "Les Crocs")
    A.Open("diag")
    local diag = A.window.pages.diag.guildInfo:GetText()
    assert(diag:find("valable") and diag:find("Testeur Dupont"), diag)
    -- by GUID, even if the first name differs
    local ns2 = bootAdmin({ specIndex = 1, rank = 1, roster = { { name = "x", full = "Autre Nom", rank = 1, guid = "Player-1-ABC" } } })
    ns2.GuildConfig.Publish({ rival = "Les Crocs" })
    eq(ns2.GuildConfig.Rival(), "Les Crocs")
    -- a rank-4 member with the same first name as an officer does not count as officer
    eq(ns.Store.FindInRoster({ { name = "Bob Un", first = "Bob", rank = 4 } }, "G2", "Bob").rank, 4)
    eq(ns.Store.FindInRoster({ { name = "Bob Un", first = "Bob", rank = 1, guid = "G1" } }, "G2", "Bob"), nil,
        "GUID connus : un homonyme ne compte pas")
end)

test("WoW Forever : onglet Membres, prenom + nom, sans doublon", function()
    local ns = boot({ specIndex = 1, roster = { { name = "Testeur", full = "Testeur Dupont", rank = 1 }, { name = "Bob", full = "Bob Martin" } } })
    ns.char.privacy.progression = "G"
    Stub.fire("PLAYER_LEVEL_UP", 21)
    local list = ns.Views.Members(ns.Store.Dataset())
    eq(#list, 2, "pas de Testeur + Testeur Dupont")
    eq(list[1].display, "Testeur Dupont"); eq(list[1].hasAddon, true); eq(list[1].name, "Testeur")
    eq(list[2].display, "Bob Martin")
    local ev = eventsOf(ns, "LEVEL_UP")[1]
    assert(ns.Types.Describe(ev, true):find("^Testeur Dupont "), ns.Types.Describe(ev, true))
    ns.UI.Open("members")
    eq(RenatusMainFrame.containers.members.list.items[1].display, "Testeur Dupont")
end)

test("reglage d'un non-officier ignore ; le plus recent gagne ; officier retrogade ignore", function()
    local S = Stub.reset({ specIndex = 1, roster = OFFICERS })
    local ns = Stub.loadAddon(ROOT, NAME)
    ns.char.rivalGuild = "Ancienne"
    eq(ns.GuildConfig.Rival(), "Ancienne", "repli : reglage local d'avant")
    receivedConfig(ns, CAROL, 1, 3000, "Usurpateurs")
    eq(ns.GuildConfig.Rival(), "Ancienne", "rang 4 : ignore")
    receivedConfig(ns, BOB, 1, 1000, "Premiere")
    receivedConfig(ns, BOB, 2, 2000, "Seconde")
    eq(ns.GuildConfig.Rival(), "Seconde", "le plus recent")
    S.roster[2].rank = 5
    Stub.fire("GUILD_ROSTER_UPDATE")
    eq(ns.GuildConfig.Rival(), "Ancienne", "Bob retrogade : ses reglages ne comptent plus")
end)

test("element GUILD_CONFIG du compagnon : publie depuis la Redaction", function()
    local ns, A = bootAdmin({ specIndex = 1, rank = 0, roster = { { name = "Testeur", rank = 0 } } })
    RenatusPress = { version = 1, items = { { id = "cfg1", kind = "GUILD_CONFIG", p = { rival = "Cest Dieu qui pilote" } } } }
    local item = A.Press.Pending()[1]
    eq(A.Press.Label(item), "Guilde rivale : Cest Dieu qui pilote")
    assert(A.Press.Publish(item))
    eq(ns.GuildConfig.Rival(), "Cest Dieu qui pilote")
    eq(#A.Press.Pending(), 0)
    RenatusPress = nil
end)

test("armurerie : effectif publie (EXT) et affiche sur la fiche de l'ennemi", function()
    local LADOU = { name = "Ladou", realm = "Forever", guild = "Cest Dieu qui pilote", level = 24, race = "Tauren", class = "WARRIOR", pvp = true }
    local ns, A = bootAdmin({ specIndex = 1, rank = 1, roster = OFFICERS, units = { target = LADOU } })
    RenatusPress = { version = 1, items = {
        { id = "cfg:1", kind = "GUILD_CONFIG", t = 10, p = { rival = "Cest Dieu qui pilote" } },
        { id = "roster:x:1", kind = "RIVAL_ROSTER", t = 11, p = { guild = "Cest Dieu qui pilote", count = 10, at = 100,
            members = { { n = "Ladou Pipø", lvl = 25, rk = 2, cl = "WARRIOR", ra = "Tauren", gs = 159, ll = 50 },
                        { n = "Inoups Acrilège", lvl = 21, rk = 0 } } } },
    } }
    local items = A.Press.Pending()
    eq(A.Press.Label(items[2]), "Effectif de Cest Dieu qui pilote : 10 membre(s)")
    assert(A.Press.Publish(items[1])); assert(A.Press.Publish(items[2]))
    local ev = eventsOf(ns, "RIVAL_ROSTER")[1]
    eq(ev.prov, "EXT"); eq(ev.vis, "G")
    eq(ns.Sync.Validate(ev, ns.Context.GuildKey()) ~= nil, true, "provenance EXT acceptee par la synchro")
    eq(ns.GuildConfig.Roster(), ev)
    local m = ns.GuildConfig.ArmoryInfo("ladou")
    eq(m.gs, 159)
    eq(ns.GuildConfig.ArmoryInfo("Lad"), nil)
    Stub.fire("PLAYER_TARGET_CHANGED")
    ns.UI.Open("wanted")
    local c = RenatusMainFrame.containers.wanted
    assert(c.rival:GetText():find("10 membre"), c.rival:GetText())
    c:ShowDetail(ns.Views.Enemies(ns.Store.Dataset())[1])
    local left = c.detailFrame.left.fontString:GetText()
    assert(left:find("Armurerie") and left:find("score d'équipement 159") and left:find("rang 2"), left)
    -- the whole rival guild is in the registry, met or not
    local list = ns.Views.Enemies(ns.Store.Dataset())
    eq(#list, 2, "Ladou (croise) + Inoups (armurerie seulement), pas de doublon Ladou / Ladou Pipø")
    eq(list[1].name, "Ladou"); eq(list[1].rival, true)
    eq(list[2].name, "Inoups"); eq(list[2].rival, true); eq(list[2].lastSeen, nil); eq(list[2].level, 21)
    eq(list[1].display, "Ladou Pipø", "nom complet affiche")
    -- a wanted poster typed with the full name lands on the same enemy
    ns.Store.AddManual("WANTED", { name = "ladou pipø", reason = "Camping" })
    local posters, enemies = ns.Views.Wanted(ns.Store.Dataset())
    eq(#enemies, 2, "pas de doublon pour le nom complet")
    eq(posters[1].enemy, enemies[1])
    eq(ns.Views.EnemyKey("Ladou Pipø"), ns.Views.EnemyKey("ladou"))
    c:Refresh()
    c.detail = nil; c.view = "registry"; c:Refresh()
    assert(c.registry.rows[1].name:GetText():find("Ladou Pipø"), "registre : nom complet")
    local row2 = c.registry.rows[2]
    assert(row2.name:GetText():find("GUILDE RIVALE"), row2.name:GetText())
    assert(row2.sub:GetText():find("jamais croisé") and row2.sub:GetText():find("chef de guilde"), row2.sub:GetText())
    RenatusPress = nil
end)

test("armurerie : l'effectif le plus recent est publie tout seul a la connexion d'un officier", function()
    local ns, A, S = bootAdmin({ specIndex = 1, rank = 1, roster = OFFICERS })
    local function roster(id, at, n)
        return { id = id, kind = "RIVAL_ROSTER", t = at, p = { guild = "Les Crocs", count = n, at = at,
            members = { { n = "Ladou Pipø", lvl = 25 } } } }
    end
    RenatusPress = { version = 1, items = {
        { id = "cfg:1", kind = "GUILD_CONFIG", t = 10, p = { rival = "Les Crocs" } },
        roster("roster:crocs:1", 100, 1), roster("roster:crocs:2", 200, 2),
        roster("roster:autre", 300, 3),
    } }
    RenatusPress.items[4].p.guild = "Autre guilde"
    eq(A.Press.AutoRoster(), nil, "pas de guilde rivale en vigueur : rien")
    assert(A.Press.Publish(A.Press.Pending()[1]))
    local ev = A.Press.AutoRoster()
    eq(ev.k, "RIVAL_ROSTER"); eq(ev.p.at, 200, "le plus recent")
    eq(ns.db.pressDone["roster:crocs:1"], "ignored")
    eq(ns.db.pressDone["roster:autre"], nil, "autre guilde : attend un clic")
    eq(ns.GuildConfig.Roster(), ev)
    eq(A.Press.AutoRoster(), nil, "rien de neuf")
    -- turned off
    ns.db.adminAutoRoster = false
    table.insert(RenatusPress.items, roster("roster:crocs:3", 400, 4))
    eq(A.Press.AutoRoster(), nil)
    ns.db.adminAutoRoster = nil
    -- once per session, on the guild roster update
    Stub.fire("GUILD_ROSTER_UPDATE")
    eq(ns.GuildConfig.Roster().p.at, 400)
    RenatusPress = nil
end)

test("armurerie : pas de publication automatique pour un non-officier", function()
    local ns, A = bootAdmin({ specIndex = 1, rank = 5, roster = { { name = "Testeur", rank = 5 } } })
    RenatusPress = { version = 1, items = { { id = "r", kind = "RIVAL_ROSTER", t = 1,
        p = { guild = "X", at = 1, members = {} } } } }
    ns.char.rivalGuild = "X"
    eq(A.Press.AutoRoster(), nil)
    eq(ns.db.pressDone["r"], nil)
    RenatusPress = nil
end)

test("sans Renatus_Admin : ni fenetre, ni icone d'administration", function()
    RenatusAdminFrame, RenatusAdminMinimapButton, SlashCmdList.RENATUSADMIN = nil, nil, nil   -- left by earlier tests
    local ns = boot({ specIndex = 1 })
    RenatusPress = { version = 1, items = {} }
    eq(Renatus.admin, nil)
    eq(RenatusAdminFrame, nil)
    eq(RenatusAdminMinimapButton, nil)
    eq(SlashCmdList.RENATUSADMIN, nil)
    RenatusPress = nil
end)

-- Every button of the members' window, by label (to compare with and without Renatus_Admin).
local function memberButtons()
    local labels = {}
    for _, f in ipairs(Stub.state.frames) do
        if f.label and f.label.GetText and f:IsShown() then
            local anc, inMain = f.parent, false
            while anc do if anc == RenatusMainFrame then inMain = true end; anc = anc.parent end
            if inMain then table.insert(labels, tostring(f.label:GetText())) end
        end
    end
    table.sort(labels)
    return table.concat(labels, "|")
end

test("fenetre des membres identique avec ou sans Renatus_Admin", function()
    local ns = boot({ specIndex = 1 })
    ns.UI.Open("gazette")
    local without = memberButtons()
    RenatusMainFrame = nil
    local nsA = bootAdmin({ specIndex = 1, rank = 0, roster = { { name = "Testeur", rank = 0 } } })
    RenatusPress = { version = 1, items = { { id = "a1", kind = "ARTICLE", p = { title = "T", body = "B" } } } }
    nsA.UI.Open("gazette")
    eq(memberButtons(), without)
    RenatusPress = nil
end)

test("fenetre d'administration : icone cle, /radmin, diagnostic, mode demo", function()
    local ns, A, S = bootAdmin({ specIndex = 1, settingsApi = true })
    eq(#S.settings.categories, 1, "plus de page Renatus Admin dans les Options du jeu")
    local icon = RenatusAdminMinimapButton
    assert(icon, "icone d'administration sur la minimap")
    assert(icon ~= ns.UI.Minimap.button, "distincte de celle des membres")
    icon.scripts.OnClick(icon, "LeftButton")
    eq(A.window:IsShown(), true)
    A.window.tabs.diag:Click()
    local diag = A.window.pages.diag
    assert(diag.syncInfo:GetText():find("Membres"), "etat de synchro")
    assert(diag.dataInfo:GetText():find("Schéma"), "donnees")
    diag.syncNow:Click()
    diag.demo:Click()
    eq(ns.char.ui.demo, true)
    SlashCmdList.RENATUSADMIN("")
    eq(A.window:IsShown(), false, "/radmin referme")
end)

print("Presse (compagnon)")

local function withPress(items)
    RenatusPress = { version = 1, items = items }
end

local OFFICER = { specIndex = 1, rank = 0, roster = { { name = "Testeur", rank = 0 } } }

test("elements du compagnon : en attente, publies signes LOG / GEN, jamais automatiques", function()
    local ns, A = bootAdmin(OFFICER)
    local Press = A.Press
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
    eq(#Press.Pending(), 2)
    eq(#eventsOf(ns, "DEATH_CAUSE"), 0, "rien de publie tout seul")
    local cause = Press.Publish(Press.Pending()[1])
    eq(cause.prov, "LOG"); eq(cause.vis, "G"); eq(cause.refs[1], death.id); eq(cause.t, death.t)
    local ds = ns.Store.Dataset()
    eq(ds.causes[death.id], cause)
    eq(#ns.Views.Filter(ds.events, {}), 1, "DEATH_CAUSE masque de la chronologie (affiche sur la mort)")
    ns.UI.Open("journal")
    local row = RenatusMainFrame.containers.journal.list.rows[1]
    assert(row.line2:GetText():find("Hogger"), "cause affichee sur la ligne de la mort")
    Press.Ignore(Press.Pending()[1])
    eq(#Press.Pending(), 0)
    local clash = ns.Store.Add("PVP_CLASH", { name = "Gorbash", result = "loss", member = "Bob" }, { prov = "LOG", vis = "G" })
    eq(ns.Types.Describe(clash, true), "Testeur rapporte : Bob tombe face à Gorbash")
    local e = ns.Views.Enemies(ns.Store.Dataset())[1]
    eq(e.losses.LOG, 1); eq(e.memberList[1], "Bob")
    local savedA, savedC = RenatusDB, RenatusCharDB
    local _, A2 = bootAdmin({ specIndex = 1, rank = 0, roster = OFFICER.roster, savedAccount = savedA, savedChar = savedC })
    withPress({ { id = "c1", kind = "DEATH_CAUSE", p = { victim = "x", cause = "y" } } })
    eq(#A2.Press.Pending(), 0, "decisions memorisees")
    RenatusPress = nil
end)

test("gazette reelle : relue et publiee dans la fenetre d'administration, plus de vote pour la une", function()
    local ns, A = bootAdmin(OFFICER)
    local Press = A.Press
    withPress({ { id = "a1", kind = "ARTICLE", p = { title = "Une", body = "Texte", style = "épique", format = "Hebdomadaire" } },
                { id = "cfg", kind = "GUILD_CONFIG", p = { rival = "X" } } })
    local w = A.Open()
    eq(w.tabs.press.label:GetText(), "Rédaction (1)")
    eq(w.tabs.rival.label:GetText(), "Guilde rivale (1)")
    local row = w.pages.press.list.rows[1]
    eq(row.item.id, "a1", "reglage de guilde range dans l'onglet Guilde rivale")
    row.scripts.OnClick(row)
    assert(w.pages.press.preview.fontString:GetText():find("Texte"), "apercu de l'article")
    row.pub:Click()
    local art = eventsOf(ns, "ARTICLE")[1]
    eq(art.prov, "GEN")
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    eq(c.current.id, art.id)
    eq(c.current.author, "Testeur")
    eq(c.paper.vote, nil, "plus de bouton de vote")
    eq(w.tabs.press.label:GetText(), "Rédaction")
    RenatusPress = nil
end)

test("non-officier : peut consulter la redaction, pas publier", function()
    local ns, A = bootAdmin({ specIndex = 1, rank = 3, roster = { { name = "Testeur", rank = 3 } } })
    withPress({ { id = "a1", kind = "ARTICLE", p = { title = "Une", body = "Texte" } } })
    local item = A.Press.Pending()[1]
    local ev, why = A.Press.Publish(item)
    eq(ev, nil); eq(why, "rang")
    local w = A.Open("press")
    eq(w.pages.press.list.rows[1].pub.gcDisabled, true, "bouton Publier inactif")
    eq(#eventsOf(ns, "ARTICLE"), 0)
    eq(#A.Press.Pending(), 1, "toujours en attente")
    RenatusPress = nil
end)

test("consentement gazette IA : publie et partage, le dernier choix compte", function()
    local ns = boot({ specIndex = 1, consent = "default" })
    local ev = eventsOf(ns, "AI_CONSENT")[1]
    eq(ev.p.ok, true, "coche par defaut, annonce a la connexion")
    eq(ev.vis, "G", "partage meme si la categorie est privee")
    eq(ns.char.exportConsent, true)
    local c = ns.UI.Options.fallbackPanel   -- no Settings API in this test: the single canvas page
    c.export:SetChecked(true)
    c.export:Click()
    eq(ns.Consent.LastConsent().p.ok, false, "decoche")
    c.export:Click()
    eq(#eventsOf(ns, "AI_CONSENT"), 3)
    eq(#ns.Views.Filter(ns.Store.Dataset().events, {}), 0, "masque de la chronologie")
    ns.Consent.SetConsent(true)
    eq(#eventsOf(ns, "AI_CONSENT"), 3, "pas de doublon")
    ns.Consent.SetConsent(false)
    eq(ns.Consent.LastConsent().p.ok, false, "retrait du consentement")
    eq(ns.char.exportConsent, false)
    -- the explicit "no" survives a new login
    local savedA, savedC = RenatusDB, RenatusCharDB
    local ns2 = boot({ specIndex = 1, savedAccount = savedA, savedChar = savedC })
    eq(ns2.char.exportConsent, false, "non conserve")
    eq(ns2.Consent.LastConsent().p.ok, false)
end)

test("consentement IA : ancien personnage jamais decide -> oui par defaut", function()
    local ns = boot({ specIndex = 1, savedChar = { schema = 1, exportConsent = false } })
    eq(ns.char.exportConsent, true)
    eq(ns.Consent.LastConsent().p.ok, true)
end)

print("Interface (v0.3)")

test("options (page de repli) : reglages du membre seulement", function()
    local ns = boot({ specIndex = 1 })
    local c = ns.UI.Options.fallbackPanel
    c.scripts.OnShow(c)
    eq(c.privacy.combat ~= nil, true, "confidentialite")
    eq(c.rival, nil, "pas de guilde rivale")
    eq(c.syncInfo, nil, "pas de diagnostic de synchro")
    eq(c.demo, nil, "pas de mode demo")
end)

print("Acces a l'addon (v0.4.2)")

test("bouton de minicarte : sur le bord, quelle que soit la taille de la minicarte", function()
    Stub.reset({ specIndex = 1 })
    local mapWidth = 198 -- Retail-based clients (Forever)
    Minimap.width = mapWidth
    local ns = Stub.loadAddon(ROOT, NAME)
    local b = ns.UI.Minimap.button
    assert(b and b:IsShown(), "bouton affiche")
    local x, y
    b.SetPoint = function(_, _, _, _, px, py) x, y = px, py end
    ns.char.ui.minimapAngle = 0
    ns.UI.Minimap:Update()
    assert(x > mapWidth / 2 and x < mapWidth / 2 + 16 and math.abs(y) < 1e-6, "sur le bord : x=" .. tostring(x))
    eq(ns.UI.Minimap.compartment, nil, "pas de menu des addons sur ce client")
    b.scripts.OnClick(b, "LeftButton")
    assert(RenatusMainFrame:IsShown(), "clic gauche : ouvre")
    b.scripts.OnClick(b, "LeftButton")
    eq(RenatusMainFrame:IsShown(), false, "clic gauche : ferme")
    ns.char.ui.showMinimap = false
    ns.UI.Minimap:Update()
    eq(b:IsShown(), false, "masquable")
end)

test("menu des addons de la minicarte (Retail) : ouvre la fenetre ou les parametres", function()
    local ns, S = boot({ specIndex = 1, compartment = true })
    eq(#S.compartment, 1)
    local entry = S.compartment[1]
    eq(entry.text, "Renatus")
    entry.func(nil, { buttonName = "LeftButton" })          -- 11.0+ menus
    assert(RenatusMainFrame:IsShown(), "ouvre")
    entry.func(nil, nil, nil, nil, "LeftButton")             -- 10.x menus
    eq(RenatusMainFrame:IsShown(), false, "ferme")
    entry.func(nil, { buttonName = "RightButton" })
    eq(ns.UI.current, "gazette", "clic droit : options du jeu, pas la fenetre")
end)

test("menu Options du jeu : page principale et sous-page Voix", function()
    local ns, S = boot({ specIndex = 1, settingsApi = true })
    local reg = S.settings
    eq(ns.UI.Options.native, true, ns.UI.Options.error)
    eq(#reg.categories, 1); eq(reg.categories[1].name, "Renatus")
    eq(#reg.subcategories, 1); eq(reg.subcategories[1].name, "Voix")
    local main, voice = 0, 0
    for _, c in ipairs(reg.controls) do
        if c.category == reg.categories[1] then main = main + 1 else voice = voice + 1 end
    end
    eq(main, 4 + #ns.Types.CATEGORIES, "minicarte, icone gazette, consentement, album + confidentialite")
    eq(voice, 8 + 10, "voix : 8 reglages + 10 familles")
    -- privacy: same table as everywhere
    reg.byVar.Renatus_privacy_combat:SetValue("G")
    eq(ns.char.privacy.combat, "G")
    ns.char.privacy.pvp = "OFF"
    eq(reg.byVar.Renatus_privacy_pvp:GetValue(), "OFF", "lit la valeur courante")
    reg.byVar.Renatus_showMinimap:SetValue(false)
    eq(ns.UI.Minimap.button:IsShown(), false)
    reg.byVar.Renatus_exportConsent:SetValue(true)
    eq(ns.Consent.LastConsent().p.ok, true)
    -- the "Open" button opens the window and closes the options panel
    SettingsPanel:Show()
    reg.buttons[1].onClick()
    eq(SettingsPanel:IsShown(), false, "panneau Options ferme")
    assert(RenatusMainFrame:IsShown())
    eq(ns.UI.current, "gazette")
    -- opening pages
    SlashCmdList.RENATUS("options")
    eq(reg.opened, reg.categories[1]:GetID())
    ns.UI.Open("voice")
    eq(reg.opened, reg.subcategories[1]:GetID(), "/renatus voice -> sous-page Voix")
    ns.UI.Open("settings")
    eq(reg.opened, reg.categories[1]:GetID())
end)

test("menu Options du jeu : API differente, repli sur un panneau avec un bouton", function()
    local S = Stub.reset({ specIndex = 1, settingsApi = true })
    Settings.RegisterAddOnSetting = function() error("old signature") end
    local ns = Stub.loadAddon(ROOT, NAME)
    eq(ns.UI.Options.native, nil)
    assert(ns.UI.Options.fallbackPanel, "panneau de repli")
    eq(#S.settings.categories, 1, "une seule entree, malgre l'echec du panneau natif")
    eq(S.settings.categories[1].frame, ns.UI.Options.fallbackPanel)
end)

test("menu Options du jeu : client sans aucune API d'options, un message", function()
    local ns, S = boot({ specIndex = 1 })
    eq(ns.UI.Options.Open(), false)
    local found
    for _, line in ipairs(S.printed) do if line:find("options indisponibles") then found = true end end
    assert(found, "message")
end)

print("Habillage et gazette (v0.5.0)")

test("habillage : textures de l'addon sur la fenetre, les panneaux et la gazette", function()
    local ns = boot({ specIndex = 1 })
    for _, tab in ipairs(ns.UI.tabs) do ns.UI.Open(tab.key) end
    eq(RenatusMainFrame.gcSkin, "window")
    eq(RenatusMainFrame.containers.gazette.paper.gcSkin, "parchment")
    eq(ns.UI.WIDTH, 948); eq(ns.UI.HEIGHT, 630)
    assert(RenatusMainFrame.close, "bouton de fermeture")
    ns.UI.Open("gazette")
    eq(RenatusMainFrame.navButtons.gazette.sel:IsShown(), true)
    eq(RenatusMainFrame.navButtons.journal.sel:IsShown(), false)
end)

test("gazette : un numero par parution, date de parution, la une suit l'ordre editorial", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    eq(#c.editions, 2, "deux numeros dans la demo")
    eq(c.editions[1].number, #c.editions, "le plus recent porte le plus grand numero")
    local first = c.editions[1]
    for i = 2, #first.articles do assert(first.articles[i - 1].order < first.articles[i].order, "ordre editorial") end
    eq(first.articles[1].title, "Tobias, onze fois regretté")
    eq(c.current, first.articles[1])
    assert(c.front:IsShown() and not c.reader:IsShown(), "premiere page")
    assert(c.front.info:GetText():find("Paru le"), "date de parution")
    -- archives: every issue with its date, most recent first; pick the older one
    c.archives:Click()
    assert(c.archive:IsShown() and not c.front:IsShown() and c.back:IsShown(), "archives")
    eq(c.archives:IsShown(), false)
    local rows = c.archive.list.rows
    eq(rows[1].number:GetText(), "N° 2"); eq(rows[2].number:GetText(), "N° 1")
    assert(rows[2].date:GetText():find("Paru le"), "date de parution")
    eq(rows[3]:IsShown(), false)
    rows[2]:Click()
    eq(c.edition, 2)
    assert(c.front:IsShown() and not c.archive:IsShown(), "retour a la une du numero choisi")
    eq(c.current, c.editions[2].articles[1])
    c.archives:Click()
    c.back:Click()
    assert(c.front:IsShown() and c.edition == 2, "retour sans changer de numero")
    c:OpenEdition(1)
    eq(c.edition, 1)
    -- read the front-page story, then its sources, then back
    c.front.storyHit:Click()
    assert(c.reader:IsShown() and c.back:IsShown(), "lecture")
    eq(c.reader.title:GetText(), first.articles[1].title)
    c.paper.sources:Click()
    assert(c.showSources and c.reader.body.fontString:GetText():find("Faits ayant servi"), "sources")
    c.back:Click()
    assert(c.front:IsShown() and not c.showSources, "retour a la une")
end)

test("gazette vide : numero zero", function()
    local ns = boot({ specIndex = 1 })
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    eq(c.current, nil)
    eq(c.front.headline:GetText(), "Les rotatives sont à l'arrêt")
    c.paper.sources:Click()
    assert(c.front:IsShown(), "pas de lecture sans article")
end)

print("Tueur (v0.6.1)")

local PALA = "Player-1-PALA"
local PLAYERS = { [PALA] = { cl = "Paladin", c = "PALADIN", ra = "Elfe de sang", raEn = "BloodElf", name = "Lumineux", realm = "Forever" } }

test("mort : le journal de combat donne le tueur (joueur), il entre au tableau de chasse", function()
    local ns, S = boot({ specIndex = 1, players = PLAYERS, classicLog = true })
    local me = S.me.guid
    -- unrelated event, then hits on the player; the fatal one has overkill
    Stub.combatLog(1, "SPELL_DAMAGE", false, PALA, "Lumineux", 0, 0, "Creature-0-1", "Loup", 0, 0, 20271, "Jugement", 2, 300, -1)
    Stub.combatLog(1, "SWING_DAMAGE", false, PALA, "Lumineux", 0, 0, me, "Testeur", 0, 0, 120, -1, 1)
    Stub.advance(1)
    Stub.combatLog(2, "SPELL_DAMAGE", false, PALA, "Lumineux", 0, 0, me, "Testeur", 0, 0, 20271, "Jugement", 2, 450, 37)
    Stub.fire("PLAYER_DEAD")
    local ev = eventsOf(ns, "DEATH")[1]
    local k = ev.p.killer
    eq(k.n, "Lumineux"); eq(k.pl, true); eq(k.c, "PALADIN"); eq(k.sp, "Jugement"); eq(k.src, "log"); eq(k.ok, 37)
    eq(ev.miss, nil, "tueur connu")
    local text = ns.Types.Describe(ev, true)
    assert(text:find("tué par Lumineux %(paladin elfe de sang%) — Jugement"), text)
    local _, byKey = ns.Views.Enemies(ns.Store.Dataset())
    local e = byKey["lumineux"]
    assert(e, "fiche ennemie")
    eq(e.losses.OBS, 1); eq(e.class, "PALADIN")
end)

test("mort : coups trop anciens ignores, chute reconnue", function()
    local ns, S = boot({ specIndex = 1, players = PLAYERS, classicLog = true })
    Stub.combatLog(1, "SWING_DAMAGE", false, PALA, "Lumineux", 0, 0, S.me.guid, "Testeur", 0, 0, 120, -1, 1)
    Stub.advance(15)
    Stub.combatLog(2, "ENVIRONMENTAL_DAMAGE", false, nil, nil, 0, 0, S.me.guid, "Testeur", 0, 0, "Falling", 900, 12)
    Stub.fire("PLAYER_DEAD")
    local ev = eventsOf(ns, "DEATH")[1]
    eq(ev.p.killer.env, "Falling")
    assert(ns.Types.Describe(ev, true):find("victime de une chute") or ns.Types.Describe(ev, true):find("chute"))
    local _, byKey = ns.Views.Enemies(ns.Store.Dataset())
    eq(byKey["lumineux"], nil, "pas de fiche pour un coup ancien")
end)

test("mort : journal de combat ferme, le recapitulatif de mort prend le relais", function()
    local ns, S = boot({ specIndex = 1, players = PLAYERS, recap = true,
        unknownEvents = { COMBAT_LOG_EVENT_UNFILTERED = true } })
    assert(ns.unsupportedEvents.COMBAT_LOG_EVENT_UNFILTERED, "signale comme indisponible")
    S.recap = {
        { timestamp = 100, event = "SWING_DAMAGE", sourceGUID = PALA, sourceName = "Lumineux", amount = 80 },
        { timestamp = 103, event = "SPELL_DAMAGE", sourceGUID = PALA, sourceName = "Lumineux", spellName = "Marteau de la justice", amount = 500, overkill = 20 },
    }
    Stub.fire("PLAYER_DEAD")
    eq(#eventsOf(ns, "DEATH"), 1, "enregistree immediatement")
    local k = eventsOf(ns, "DEATH")[1].p.killer
    eq(k.sp, "Marteau de la justice"); eq(k.src, "recap")
end)

test("mort : recapitulatif vide au moment de la mort, relu une seconde apres", function()
    local ns, S = boot({ specIndex = 1, players = PLAYERS, recap = true })
    S.recap = {}
    Stub.fire("PLAYER_DEAD")
    eq(#eventsOf(ns, "DEATH"), 0, "en attente du recapitulatif")
    S.recap = { { timestamp = 5, sourceGUID = "Creature-0-99", sourceName = "Loup affamé", spellName = "Morsure", amount = 40 } }
    Stub.advance(1.1)
    local ev = eventsOf(ns, "DEATH")[1]
    eq(ev.p.killer.n, "Loup affamé"); eq(ev.p.killer.pl, nil)
end)

test("mort : client Midnight (Forever), le journal de combat n'est jamais demande", function()
    local ns, S = boot({ specIndex = 1, players = PLAYERS })
    for _, f in ipairs(S.frames) do
        assert(not f.events.COMBAT_LOG_EVENT_UNFILTERED, "inscription interdite : action bloquee par le jeu")
    end
    eq(ns.unsupportedEvents.COMBAT_LOG_EVENT_UNFILTERED, true, "signale dans les parametres")
    Stub.combatLog(1, "SWING_DAMAGE", false, PALA, "Lumineux", 0, 0, S.me.guid, "Testeur", 0, 0, 120, 30, 1)
    Stub.fire("PLAYER_DEAD")
    local ev = eventsOf(ns, "DEATH")[1]
    eq(ev.p.killer, nil); eq(ev.miss[1], "killer")
end)

test("mort : recapitulatif avec valeurs secretes, aucun tueur invente", function()
    local ns, S = boot({ specIndex = 1, players = PLAYERS, recap = true })
    S.recap = { { timestamp = 5, sourceGUID = { secret = true }, sourceName = { secret = true }, amount = 40 } }
    Stub.fire("PLAYER_DEAD")
    Stub.advance(1.1)
    local ev = eventsOf(ns, "DEATH")[1]
    eq(ev.p.killer, nil); eq(ev.miss[1], "killer")
end)

print("Modeles et icones des cartes (creatures, butin)")

test("creatures : numero du tueur et du boss releve en jeu (modele 3D de la carte)", function()
    local hogger = { name = "Hogger", guid = "Creature-0-1-2-3-448-000AB", player = false }
    local ns, S = boot({ specIndex = 1, classicLog = true, units = { target = hogger } })
    eq(ns.NpcId("Creature-0-1-2-3-448-000AB"), 448)
    eq(ns.NpcId("Player-1-ABC"), nil); eq(ns.NpcId(nil), nil)
    Stub.fire("PLAYER_TARGET_CHANGED")
    eq(ns.Creatures.Lookup("Hogger"), 448, "cible retenue")
    -- killed by Hogger: the npc id comes from the hit itself
    Stub.combatLog(1, "SWING_DAMAGE", false, "Creature-0-1-2-3-448-000AB", "Hogger", 0, 0, S.me.guid, "Testeur", 0, 0, 900, 12, 1)
    Stub.fire("PLAYER_DEAD")
    eq(eventsOf(ns, "DEATH")[1].p.killer.npc, 448)
    -- boss of an encounter: the boss unit
    S.units.boss1 = { name = "Edwin VanCleef", guid = "Creature-0-1-2-3-639-00001", player = false }
    Stub.fire("ENCOUNTER_START", 1094, "Edwin VanCleef", 1, 5)
    S.units.boss1 = nil
    Stub.fire("ENCOUNTER_END", 1094, "Edwin VanCleef", 1, 5, 1)
    eq(eventsOf(ns, "BOSS_KILL")[1].p.npc, 639)
    -- next encounter, no boss unit: a creature of that name seen around, else nothing
    Stub.fire("ENCOUNTER_START", 1, "Hogger", 1, 5)
    Stub.fire("ENCOUNTER_END", 1, "Hogger", 1, 5, 1)
    Stub.fire("ENCOUNTER_START", 2, "Inconnu", 1, 5)
    Stub.fire("ENCOUNTER_END", 2, "Inconnu", 1, 5, 1)
    local kills = eventsOf(ns, "BOSS_KILL")
    table.sort(kills, function(a, b) return a.p.enc < b.p.enc end)
    eq(kills[1].p.npc, 448); eq(kills[2].p.npc, nil)
end)

test("bestiaire : premier mob de chaque espece tue (experience ou corps fouille), avec son numero et son type", function()
    COMBATLOG_XPGAIN_FIRSTPERSON = "%s meurt, vous gagnez %d points d'expérience."
    local ns, S = boot({ specIndex = 1, classicLog = true, units = {
        target = { name = "Traqueuse Ronce-sauvage", guid = "Creature-0-1-2-3-3819-0001", player = false, level = 22 },
        mouseover = { name = "Ours gris", guid = "Creature-0-1-2-3-1186-0002", player = false } } })
    eq(ns.Kills.Pattern(COMBATLOG_XPGAIN_FIRSTPERSON), "^(.+) meurt, vous gagnez ")
    UnitClassification = function(unit) return unit == "target" and "elite" or "normal" end
    Stub.fire("PLAYER_TARGET_CHANGED"); Stub.fire("UPDATE_MOUSEOVER_UNIT")
    Stub.fire("CHAT_MSG_COMBAT_XP_GAIN", "Traqueuse Ronce-sauvage meurt, vous gagnez 184 points d'expérience. (+92 exp Reposé)")
    Stub.fire("CHAT_MSG_COMBAT_XP_GAIN", "Traqueuse Ronce-sauvage meurt, vous gagnez 184 points d'expérience.")
    Stub.fire("CHAT_MSG_COMBAT_XP_GAIN", "Inconnu meurt, vous gagnez 10 points d'expérience.")
    -- a corpse looted (highest level: no experience)
    GetNumLootItems = function() return 1 end
    GetLootSourceInfo = function() return "Creature-0-1-2-3-1186-0002", 1 end
    Stub.fire("LOOT_OPENED")
    local kills = eventsOf(ns, "MOB_KILL")
    table.sort(kills, function(a, b) return a.p.npc < b.p.npc end)
    eq(#kills, 2, "une fois par espece ; un mob jamais vu ignore")
    eq(kills[1].p.npc, 1186); eq(kills[1].p.name, "Ours gris")
    eq(kills[2].p.npc, 3819); eq(kills[2].p.cls, "elite"); eq(kills[2].p.lvl, 22)
    eq(ns.Types.Get("MOB_KILL").hidden, true, "jamais affiche dans le journal")
    -- killed by a creature seen around: its kind goes with the killer
    Stub.combatLog(1, "SWING_DAMAGE", false, "Creature-0-1-2-3-3819-0001", "Traqueuse Ronce-sauvage", 0, 0, S.me.guid, "Testeur", 0, 0, 900, 12, 1)
    Stub.fire("PLAYER_DEAD")
    local k = eventsOf(ns, "DEATH")[1].p.killer
    eq(k.npc, 3819); eq(k.cls, "elite")
    COMBATLOG_XPGAIN_FIRSTPERSON, UnitClassification, GetNumLootItems, GetLootSourceInfo = nil, nil, nil, nil
end)

test("butin : premier objet bleu ou mieux de ce personnage, avec son numero ; icone de l'objet sur la carte", function()
    LOOT_ITEM_SELF = "Vous recevez le butin : %s."
    LOOT_ITEM_SELF_MULTIPLE = "Vous recevez le butin : %sx%d."
    local ns = boot({ specIndex = 1 })
    ns.Loot.patterns = nil
    eq(ns.Loot.Pattern("Vous recevez le butin : %sx%d."), "^Vous recevez le butin : (.+)x%d+%.$")
    local epic = "|cffa335ee|Hitem:5191::::::::60:::::|h[Lame de Cruel]|h|r"
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : " .. epic .. ".")
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : " .. epic .. ".")
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : |cff1eff00|Hitem:2000::::|h[Bottes vertes]|h|r.")
    Stub.fire("CHAT_MSG_LOOT", "Bob reçoit le butin : |cffa335ee|Hitem:6000::::|h[Pas a moi]|h|r.")
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : |cnIQ3:|Hitem:7000::::|h[Anneau bleu]|h|rx2.")
    -- WoW Forever: plain text, the item found by its name (item data, else the bags)
    C_Item = { GetItemInfo = function(name)
        if name == "Bouclier bleu" then return name, "|cnIQ3:|Hitem:8000::::|h[Bouclier bleu]|h|r", 3 end
    end }
    C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
        GetContainerItemInfo = function(_, slot)
            if slot == 2 then return { itemID = 9000, quality = 4, itemName = "Cape violette" } end
        end }
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : [Bouclier bleu].")
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : [Cape violette].")
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : [Inconnu].")
    -- not in the bags yet when the message comes: found a moment later
    local late = false
    local getInfo = C_Container.GetContainerItemInfo
    C_Container.GetContainerItemInfo = function(bag, slot)
        if late and slot == 1 then return { itemID = 9500, quality = 3, itemName = "Bottes tardives" } end
        return getInfo(bag, slot)
    end
    Stub.fire("CHAT_MSG_LOOT", "Vous recevez le butin : [Bottes tardives].")
    late = true
    Stub.advance(2)
    C_Item, C_Container = nil, nil
    local items = eventsOf(ns, "RARE_ITEM")
    table.sort(items, function(a, b) return a.p.id < b.p.id end)
    eq(#items, 5, "une fois par objet ; ni vert, ni butin des autres ; objet introuvable ignore")
    eq(items[3].p.id, 8000); eq(items[3].p.q, 3); eq(items[3].p.item, "Bouclier bleu")
    eq(items[4].p.id, 9000); eq(items[4].p.q, 4)
    eq(items[5].p.id, 9500, "retrouve une seconde plus tard")
    eq(items[1].p.id, 5191); eq(items[1].p.item, "Lame de Cruel"); eq(items[1].p.q, 4)
    eq(items[2].p.id, 7000); eq(items[2].p.q, 3)
    -- the card shows the item's icon
    GetItemIcon = function(id) return id == 5191 and 135274 or nil end
    local card = ns.Album.FromPayload({ id = "I:5191", s = "butin", r = "epic", n = "Lame de Cruel", ic = "INV_Misc_Bag_10", itm = 5191 },
        { t = 1, p = {} })
    eq(card.series, "butin"); eq(card.itemId, 5191)
    eq(ns.UI.CardArt(card), 135274)
    GetItemIcon, LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE = nil, nil, nil
    ns.Loot.patterns = nil
end)

print("Suppression (tombstones)")

local function inDataset(ns, id)
    for _, ev in ipairs(ns.Store.Dataset().events) do if ev.id == id then return true end end
    return false
end

test("supprimer une anecdote privee : clic droit dans le journal, confirmation", function()
    local ns = boot({ specIndex = 1 })
    ns.char.privacy.anecdote = "P"
    local ev = ns.Store.AddManual("ANECDOTE", { title = "Le saut raté", desc = "La falaise a gagné." })
    ns.UI.Open("journal")
    local c = RenatusMainFrame.containers.journal
    local row
    for _, r in ipairs(c.list.rows) do if r.item and r.item.ev.id == ev.id then row = r end end
    assert(row, "ligne de l'anecdote")
    local dialog = ns.UI.Dialogs.Delete(ev)
    assert(dialog and dialog.text:GetText():find("Le saut raté"), "confirmation")
    dialog.no:Click()
    assert(ns.db.events[ev.id], "annuler ne supprime rien")
    row.scripts.OnClick(row, "RightButton")
    dialog = ns.UI.Dialogs.Delete(ev)
    dialog.yes:Click()
    eq(ns.db.events[ev.id], nil, "effacee")
    eq(#eventsOf(ns, "TOMBSTONE"), 0, "privee : rien a annoncer")
    eq(inDataset(ns, ev.id), false)
end)

test("supprimer une anecdote partagee : tombstone envoye, copie videe", function()
    local ns = boot({ specIndex = 1 })
    ns.char.privacy.anecdote = "G"
    local ev = ns.Store.AddManual("ANECDOTE", { title = "Secret", desc = "Rien" })
    eq(ev.vis, "G")
    assert(ns.Store.Delete(ev.id))
    local stored = ns.db.events[ev.id]
    assert(stored and stored.del, "gardee vide pour la synchro")
    eq(stored.p.title, nil); eq(stored.loc, nil)
    local tomb = eventsOf(ns, "TOMBSTONE")[1]
    eq(tomb.refs[1], ev.id); eq(tomb.vis, "G")
    eq(inDataset(ns, ev.id), false); eq(inDataset(ns, tomb.id), true)
    eq(#ns.Views.Filter(ns.Store.Dataset().events, {}), 0, "rien d'affiche")
    -- the emptied copy is still valid on the wire
    local copy = {}
    for k, v in pairs(stored) do copy[k] = v end
    assert(ns.Sync.Validate(copy, ns.Context.GuildKey()), "copie videe acceptee")
end)

test("tombstones recus : avant ou apres l'evenement, seulement de l'auteur", function()
    local ns = boot({ specIndex = 1 })
    local g = ns.Context.GuildKey()
    local function ev(author, s, k, p, refs)
        return { v = 1, id = author .. ":" .. s, a = author, n = "Bob", s = s, t = 1795000000 + s, k = k, g = g,
            vis = "G", prov = "MAN", p = p or {}, refs = refs }
    end
    local bob, eve = "Player-1-BOB", "Player-1-EVE"
    ns.Store.Insert(ev(bob, 1, "ANECDOTE", { title = "A" }))
    ns.Store.Insert(ev(bob, 2, "TOMBSTONE", {}, { bob .. ":1" }))
    eq(ns.db.events[bob .. ":1"].del, true, "apres")
    ns.Store.Insert(ev(bob, 4, "TOMBSTONE", {}, { bob .. ":3" }))
    ns.Store.Insert(ev(bob, 3, "ANECDOTE", { title = "B" }))
    eq(ns.db.events[bob .. ":3"].del, true, "avant")
    ns.Store.Insert(ev(bob, 5, "ANECDOTE", { title = "C" }))
    ns.Store.Insert(ev(eve, 1, "TOMBSTONE", {}, { bob .. ":5" }))
    eq(ns.db.events[bob .. ":5"].del, nil, "un autre auteur ne peut pas supprimer")
    eq(ns.Store.CanDelete(ns.db.events[bob .. ":5"]), false, "pas mon anecdote")
end)

test("suppression : seulement mes saisies manuelles ; en demo aussi", function()
    local ns, S = boot({ specIndex = 1 })
    Stub.fire("PLAYER_DEAD")
    local death = eventsOf(ns, "DEATH")[1]
    eq(ns.Store.CanDelete(death), false, "evenement observe")
    eq(ns.Store.Delete(death.id), false)
    SlashCmdList.RENATUS("demo")
    local ev = ns.Store.AddManual("ANECDOTE", { title = "Démo" })
    assert(inDataset(ns, ev.id))
    assert(ns.Store.Delete(ev.id))
    eq(inDataset(ns, ev.id), false)
end)

test("visibilite : partager un evenement prive, puis le rendre prive (synchro, tombstone)", function()
    local ns, S = boot({ specIndex = 1, me = ALICE })
    ns.char.privacy.combat = "P"
    Stub.fire("PLAYER_DEAD")
    local death = eventsOf(ns, "DEATH")[1]
    eq(death.vis, "P")
    local note = ns.Store.Add("DEATH_CAUSE", { victim = death.id, cause = "x" }, { refs = { death.id } })
    eq(ns.Store.CanMakePrivate(death), false); eq(ns.Store.CanShare(death), true)
    -- right click in the journal: dialog, share
    ns.UI.Open("journal")
    local c = RenatusMainFrame.containers.journal
    local row
    for _, r in ipairs(c.list.rows) do if r.item and r.item.ev.id == death.id then row = r end end
    assert(row, "ligne de la mort")
    row.scripts.OnClick(row, "RightButton")
    local d = ns.UI.Dialogs.EventActions(death)
    eq(d.delete, nil, "evenement observe : pas de suppression")
    eq(d.visibility.label:GetText(), "Partager avec la guilde")
    d.visibility:Click()
    eq(ns.db.events[death.id], nil, "copie privee retiree")
    local shared = eventsOf(ns, "DEATH")[1]
    eq(shared.vis, "G"); eq(shared.id, ALICE.guid .. ":" .. shared.s); eq(shared.t, death.t, "date conservee")
    eq(shared.loc.z, death.loc.z)
    if note then eq(ns.db.events[note.id].refs[1], shared.id, "references suivies") end
    Stub.advance(5)
    local sent = S.sent
    local aliceDB, aliceChar = RenatusDB, RenatusCharDB
    -- Bob receives it
    local nsB = boot({ specIndex = 1, me = BOB })
    Stub.deliver(sent, "Alice-Forever")
    assert(nsB.db.events[shared.id] and not nsB.db.events[shared.id].del, "recu par Bob")
    local bobDB, bobChar = RenatusDB, RenatusCharDB
    -- Alice makes it private again
    local ns2, S2 = boot({ specIndex = 1, me = ALICE, savedAccount = aliceDB, savedChar = aliceChar })
    local ev = ns2.db.events[shared.id]
    local d2 = ns2.UI.Dialogs.EventActions(ev)
    eq(d2.visibility.label:GetText(), "Rendre privé")
    d2.visibility:Click()
    eq(ns2.db.events[shared.id].del, true, "copie partagee videe")
    local priv = {}
    for _, e in ipairs(eventsOf(ns2, "DEATH")) do if not e.del then priv[#priv + 1] = e end end
    eq(#priv, 1); eq(priv[1].vis, "P"); eq(priv[1].t, death.t)
    Stub.advance(5)
    boot({ specIndex = 1, me = BOB, savedAccount = bobDB, savedChar = bobChar })
    Stub.deliver(S2.sent, "Alice-Forever")
    eq(RenatusDB.events[shared.id].del, true, "videe chez Bob")
end)

test("visibilite : bouton « partager mes evenements passes », categories Guilde seulement", function()
    local ns = boot({ specIndex = 1 })
    ns.char.privacy.combat = "P"; ns.char.privacy.progression = "P"
    Stub.fire("PLAYER_DEAD"); Stub.fire("PLAYER_DEAD")
    Stub.fire("PLAYER_LEVEL_UP", 21)
    ns.char.privacy.combat = "G"                 -- progression stays private
    local c = ns.UI.Options.fallbackPanel
    c.sharePast:Click()
    local deaths = eventsOf(ns, "DEATH")
    eq(#deaths, 2); eq(deaths[1].vis, "G"); eq(deaths[2].vis, "G")
    assert(deaths[1].s ~= deaths[2].s)
    eq(eventsOf(ns, "LEVEL_UP")[1].vis, "P", "categorie restee privee")
    eq(ns.Store.SharePast(), 0, "rien de plus")
    -- nothing that belongs to the newsroom or to someone else
    local art = ns.Store.Add("ARTICLE", { title = "T", body = "B" }, { vis = "G", prov = "GEN", noExp = true })
    eq(ns.Store.CanMakePrivate(art), false)
    eq(ns.UI.Dialogs.EventActions(art), nil)
end)

test("mode demo : une saisie partagee ne consomme pas la vraie sequence", function()
    local ns = boot({ specIndex = 1 })
    eq(ns.char.privacy.anecdote, "G")
    SlashCmdList.RENATUS("demo")
    local ev = ns.Store.AddManual("ANECDOTE", { title = "Démo" })
    assert(ev.id:find(":demo"), ev.id)
    eq(ns.db.events[ev.id], nil, "jamais sauvegardee")
    SlashCmdList.RENATUS("demo")
    local real = ns.Store.AddManual("ANECDOTE", { title = "Vraie" })
    eq(real.s, (ns.db.seq[real.a].public), "sequence publique sans trou")
    eq(ns.Sync.Vector()[real.a].max, real.s)
end)

print("Fenetre : contenu seulement")

test("fenetre : gazette par defaut, gazette et album en tete, puis les journaux", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("")
    local f = RenatusMainFrame
    eq(ns.UI.current, "gazette")
    eq(f.navButtons.gazette.height, 52); eq(f.navButtons.album.height, 52)
    eq(f.navButtons.journal.height, 32)
    eq(f.navButtons.settings, nil); eq(f.navButtons.voice, nil)
    assert(f.options, "bouton Options")
end)

print("Album : boosters reels")

test("album : boosters gagnes (jour joue, niveau), ouverture enregistree, serie Azeroth", function()
    local ns = boot({ specIndex = 1 })
    Stub.fire("PLAYER_LEVEL_UP", 21)
    local ds = ns.Store.Dataset()
    eq(ds.boosters, 2, "1 jour joue + 1 niveau")
    local cards = ns.Album.Catalogue(ds)
    assert(#cards > 100, "serie Azeroth presente")
    ns.UI.Open("album")
    RenatusMainFrame.containers.album.booster:Click()
    local open = eventsOf(ns, "BOOSTER_OPEN")[1]
    eq(#open.p.cards, 5)
    ds = ns.Store.Dataset()
    eq(ds.boosters, 1); eq(ds.boostersOpened, 1)
    local total = 0
    for _, n in pairs(ds.collection) do total = total + n end
    eq(total, 5)
end)

test("album : icone de carte = premiere presente sur le client, sinon la generique", function()
    local ns = boot({ specIndex = 1 })
    local present = { ["Interface\\Icons\\Achievement_Zone_Westfall_01"] = true }
    function GetFileIDFromPath(path) return present[path] and 1 or nil end
    local card = { id = "t1", icons = { "Achievement_Zone_Westfall", "Achievement_Zone_Westfall_01", "INV_Misc_Map_01" } }
    eq(ns.UI.CardArt(card), "Interface\\Icons\\Achievement_Zone_Westfall_01")
    local none = { id = "t2", icons = { "Nope", "INV_Misc_Map_01" } }
    eq(ns.UI.CardArt(none), "Interface\\Icons\\INV_Misc_Map_01", "repli sur la derniere")
    GetFileIDFromPath = nil
end)

test("album : booster distribue face cachee, cartes retournees une a une ; filtre Azeroth", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("album")
    local c = RenatusMainFrame.containers.album
    c.booster:Click()
    local shown = 0
    for _, f in ipairs(c.cards) do if f:IsShown() then shown = shown + 1 end end
    assert(shown > 0)
    c.series = "family:azeroth"; c:Refresh()
    for _, f in ipairs(c.cards) do
        if f:IsShown() then assert(f.card.azeroth, "seulement Azeroth") end
    end
    assert(c.progress:GetText():find("/ 123 cartes"), c.progress:GetText())
    Stub.advance(2)
end)

local function foreign(ns, author, name, s, kind, p, t)
    local ev = { v = 1, id = author .. ":" .. s, a = author, n = name, s = s, k = kind, t = t or 1000, vis = "G",
        g = ns.Context.GuildKey(), p = p }
    assert(ns.Store.Insert(ev))
    return ev
end

local function cardSet(set, first)
    return { set = set, cards = {
        { id = "M:Player-1-ABC:rare", no = first, s = "members", r = "rare", n = "Testeur l'Intrépide",
            f = "Il tient la porte. Personne ne sait pourquoi.", cl = "WARRIOR", g = "Player-1-ABC" },
        { id = "M:Player-1-BOB:common", no = first + 1, s = "members", r = "common", n = "Bob", g = "Player-1-BOB" },
        { id = "X:boss1", no = first + 2, s = "expeditions", r = "epic", n = "Hogger tombe", ic = "INV_Misc_Head_Gnoll_01",
            npc = 448 },
        { id = "bad", r = "nope", n = "Rarete inconnue" },
    } }
end

test("catalogue publie : cartes d'un officier numerotees et datees, celles d'un non-officier ignorees", function()
    local roster = { { name = "Testeur", rank = 3 }, { name = "Off", rank = 1 }, { name = "Bob", rank = 5 } }
    local ns = boot({ specIndex = 1, roster = roster })
    local ds = ns.Store.Dataset()
    local before = ns.Album.Catalogue(ds)
    eq(before.published, false, "avant le premier set : calcul local")
    foreign(ns, "Player-1-BOB", "Bob", 1, "CARD_SET", { set = "x", cards = { { id = "Z:1", no = 1, s = "faits", r = "legendary", n = "Triche" } } })
    foreign(ns, "Player-1-OFF", "Off", 1, "CARD_SET", cardSet("E1", 1), 2000)
    ds = ns.Store.Dataset()
    local cards = ns.Album.Catalogue(ds)
    eq(cards.published, true)
    local byId = {}
    for _, c in ipairs(cards) do byId[c.id] = c end
    eq(byId["Z:1"], nil, "set d'un non-officier ignore")
    eq(byId["bad"], nil, "carte invalide ignoree")
    local mine = byId["M:Player-1-ABC:rare"]
    eq(mine.no, 1); eq(mine.t, 2000); eq(mine.guid, "Player-1-ABC")
    eq(byId["X:boss1"].npc, 448)
    eq(byId["X:boss1"].icon, "Interface\\Icons\\INV_Misc_Head_Gnoll_01")
    eq(byId["AZ:est:elwynn"].no, "B-001", "set de base numerote")
    eq(ns.UI.CardNumber(mine), "N° 001")
    eq(ns.UI.CardNumber(byId["AZ:est:elwynn"]), "N° B-001")
    -- republished later: the first number stays
    foreign(ns, "Player-1-OFF", "Off", 2, "CARD_SET", cardSet("E2", 50), 3000)
    byId = {}
    for _, c in ipairs(ns.Album.Catalogue(ns.Store.Dataset())) do byId[c.id] = c end
    eq(byId["M:Player-1-ABC:rare"].no, 1, "numero stable")
end)

test("catalogue publie : cartes possedees hors catalogue gardees, opt-out d'un membre respecte", function()
    local roster = { { name = "Testeur", rank = 3 }, { name = "Off", rank = 1 }, { name = "Bob", rank = 5 } }
    local ns = boot({ specIndex = 1, roster = roster })
    ns.Store.Add("BOOSTER_OPEN", { n = 1, cards = { "A:ancienne", "M:Player-1-BOB:common" } }, { keep = true, noExp = true, loc = {} })
    foreign(ns, "Player-1-OFF", "Off", 1, "CARD_SET", cardSet("E1", 1), 2000)
    foreign(ns, "Player-1-BOB", "Bob", 1, "CARD_PROFILE", { optOut = true, race = 1, sex = 2 }, 2100)
    local ds = ns.Store.Dataset()
    eq(ds.optOut["Player-1-BOB"], true)
    local cards = ns.Album.Catalogue(ds)
    for _, c in ipairs(cards) do assert(c.guid ~= "Player-1-BOB", "membre qui refuse l'album : pas tire") end
    local orphans = ns.Album.Orphans(ds, cards, ds.collection)
    eq(#orphans, 2, "carte ancienne + carte du membre retire, toujours dans la collection")
    for _, c in ipairs(orphans) do eq(c.orphan, true) end
    ns.UI.Open("album")
    local c = RenatusMainFrame.containers.album
    c.onlyOwned = true; c:Refresh()
    local shown = 0
    for _, f in ipairs(c.cards) do if f:IsShown() then shown = shown + 1 end end
    eq(shown, 2, "les deux cartes possedees restent visibles")
end)

test("catalogue publie : carte corrigee (contenu neuf, numero garde), carte retiree gardee par son proprietaire", function()
    local roster = { { name = "Testeur", rank = 3 }, { name = "Off", rank = 1 }, { name = "Bob", rank = 5 } }
    local ns = boot({ specIndex = 1, roster = roster })
    ns.Store.Add("BOOSTER_OPEN", { n = 1, cards = { "X:boss1" } }, { keep = true, noExp = true, loc = {} })
    foreign(ns, "Player-1-OFF", "Off", 1, "CARD_SET", cardSet("E1", 1), 2000)
    local function byId()
        local out = {}
        for _, c in ipairs(ns.Album.Catalogue(ns.Store.Dataset())) do out[c.id] = c end
        return out
    end
    local version = ns.Album.Catalogue(ns.Store.Dataset()).version
    -- correction by an officer: new name and rarity, same number, date and slot
    foreign(ns, "Player-1-OFF", "Off", 2, "CARD_SET", { set = "fix", cards = {
        { id = "X:boss1", no = 99, s = "expeditions", r = "legendary", n = "Hogger, enfin" } } }, 3000)
    -- a non-officer's correction is ignored
    foreign(ns, "Player-1-BOB", "Bob", 1, "CARD_SET", { set = "x", cards = {
        { id = "X:boss1", s = "expeditions", r = "common", n = "Triche" } } }, 4000)
    local cards = byId()
    eq(cards["X:boss1"].name, "Hogger, enfin"); eq(cards["X:boss1"].rarity, "legendary")
    eq(cards["X:boss1"].no, 3, "numero de la premiere parution")
    eq(cards["X:boss1"].t, 2000); eq(cards["X:boss1"].revised, 3000)
    eq(ns.Album.Catalogue(ns.Store.Dataset()).version, version, "memes ids : meme version de catalogue")
    -- withdrawal: out of the catalogue, still in its owner's album with its last content
    foreign(ns, "Player-1-OFF", "Off", 3, "CARD_SET", { set = "del", cards = { { id = "X:boss1", del = true } } }, 5000)
    eq(byId()["X:boss1"], nil, "retiree du catalogue")
    local ds = ns.Store.Dataset()
    local orphans = ns.Album.Orphans(ds, ns.Album.Catalogue(ds), ds.collection)
    eq(#orphans, 1); eq(orphans[1].name, "Hogger, enfin"); eq(orphans[1].orphan, true)
    -- published again: back in the catalogue
    foreign(ns, "Player-1-OFF", "Off", 4, "CARD_SET", { set = "back", cards = {
        { id = "X:boss1", s = "expeditions", r = "epic", n = "Hogger revient" } } }, 6000)
    eq(byId()["X:boss1"].name, "Hogger revient"); eq(byId()["X:boss1"].no, 3)
end)

test("set de base : corrige ou retire par un officier (numero, serie et modele gardes)", function()
    local roster = { { name = "Testeur", rank = 3 }, { name = "Off", rank = 1 }, { name = "Bob", rank = 5 } }
    local ns = boot({ specIndex = 1, roster = roster })
    ns.Store.Add("BOOSTER_OPEN", { n = 1, cards = { "AZ:est:elwynn" } }, { keep = true, noExp = true, loc = {} })
    local function byId()
        local out = {}
        for _, c in ipairs(ns.Album.Catalogue(ns.Store.Dataset())) do out[c.id] = c end
        return out
    end
    local before = byId()["AZ:bestiaire:murloc"]
    foreign(ns, "Player-1-OFF", "Off", 1, "CARD_SET", { set = "fix:1", cards = {
        { id = "AZ:bestiaire:murloc", no = 999, s = "faits", r = "epic", n = "Murloc royal", f = "Mrglglgl !",
            ic = "INV_Misc_Fish_01", fo = 5, en = 6 } } }, 2000)
    foreign(ns, "Player-1-BOB", "Bob", 1, "CARD_SET", { set = "x", cards = {
        { id = "AZ:est:elwynn", s = "est", r = "legendary", n = "Triche" } } }, 2100)
    local cards = ns.Album.Catalogue(ns.Store.Dataset())
    eq(cards.published, false, "corriger le set de base ne remplace pas le calcul local des cartes de guilde")
    local m = byId()["AZ:bestiaire:murloc"]
    eq(m.name, "Murloc royal"); eq(m.rarity, "epic"); eq(m.flavor, "Mrglglgl !")
    eq(m.fo, 5); eq(m.en, 6); eq(m.revised, 2000)
    eq(m.no, before.no, "numero B-xxx garde"); eq(m.series, "bestiaire"); eq(m.npc, before.npc)
    eq(m.icons[1], "INV_Misc_Fish_01"); eq(m.icons[2], before.icons[1])
    eq(ns.UI.CardArt(m), "Interface\\Icons\\INV_Misc_Fish_01")
    eq(byId()["AZ:est:elwynn"].name, before and "Forêt d'Elwynn", "non-officier ignore")
    -- withdrawn: out of the catalogue, still owned with its content
    foreign(ns, "Player-1-OFF", "Off", 2, "CARD_SET", { set = "fix:2", cards = { { id = "AZ:est:elwynn", del = true } } }, 3000)
    eq(byId()["AZ:est:elwynn"], nil)
    local ds = ns.Store.Dataset()
    local orphans = ns.Album.Orphans(ds, ns.Album.Catalogue(ds), ds.collection)
    eq(#orphans, 1); eq(orphans[1].name, "Forêt d'Elwynn"); eq(orphans[1].no, "B-001")
end)

test("set de base : admin/core/src/base_cards.json a jour (lua tools/export_base_cards.lua)", function()
    local Export = dofile("tools/export_base_cards.lua")
    local f = assert(io.open(Export.OUT, "r"))
    local current = f:read("*a")
    f:close()
    assert(current == Export.Json(), "base_cards.json perime : lancer lua tools/export_base_cards.lua")
end)

test("catalogue publie : toutes les cartes retirees, pas de retour au calcul local", function()
    local roster = { { name = "Testeur", rank = 3 }, { name = "Off", rank = 1 } }
    local ns = boot({ specIndex = 1, roster = roster })
    foreign(ns, "Player-1-OFF", "Off", 1, "CARD_SET", { set = "a", cards = {
        { id = "Z:1", s = "faits", r = "rare", n = "Seule" } } }, 2000)
    foreign(ns, "Player-1-OFF", "Off", 2, "CARD_SET", { set = "b", cards = { { id = "Z:1", del = true } } }, 3000)
    local cards = ns.Album.Catalogue(ns.Store.Dataset())
    eq(cards.published, true)
    for _, c in ipairs(cards) do assert(c.id:sub(1, 3) == "AZ:", "seulement le set de base : " .. c.id) end
end)

test("gazette : article corrige ou retire par son auteur ou un officier, pas par un autre", function()
    local roster = { { name = "Testeur", rank = 3 }, { name = "Off", rank = 1 }, { name = "Bob", rank = 5 } }
    local ns = boot({ specIndex = 1, roster = roster })
    local a1 = foreign(ns, "Player-1-OFF", "Off", 1, "ARTICLE",
        { title = "Hogger tombe", body = "v1", edition = "E1", key = "k1", order = 1 }, 2000)
    foreign(ns, "Player-1-OFF", "Off", 2, "ARTICLE",
        { title = "Second", body = "x", edition = "E1", key = "k2", order = 2 }, 2000)
    -- a correction arriving with no original yet is not shown on its own
    foreign(ns, "Player-1-OFF", "Off", 9, "ARTICLE", { replaces = "Player-1-OFF:404", title = "Fantome", body = "?" }, 2500)
    local function issue()
        local list = ns.Views.Editions(ns.Store.Dataset())
        eq(#list, 1)
        return list[1]
    end
    eq(#issue().articles, 2)
    -- the author corrects: same id, date, slot; new text
    local fix = foreign(ns, "Player-1-OFF", "Off", 3, "ARTICLE", { replaces = a1.id, title = "Hogger tombe (rectificatif)", body = "v2" }, 3000)
    -- a member who is neither the author nor an officer cannot
    foreign(ns, "Player-1-BOB", "Bob", 1, "ARTICLE", { replaces = a1.id, title = "Triche", body = "!" }, 4000)
    local e = issue()
    eq(#e.articles, 2)
    local first = e.articles[1]
    eq(first.id, a1.id); eq(first.title, "Hogger tombe (rectificatif)"); eq(first.body, "v2")
    eq(first.t, 2000); eq(first.revised, 3000); eq(first.key, "k1"); eq(first.order, 1); eq(first.edition, "E1")
    -- a correction of the correction still targets the original
    foreign(ns, "Player-1-OFF", "Off", 4, "ARTICLE", { replaces = fix.id, title = "v3", body = "v3" }, 5000)
    eq(issue().articles[1].title, "v3")
    -- withdrawal
    foreign(ns, "Player-1-OFF", "Off", 5, "ARTICLE", { replaces = a1.id, retract = true }, 6000)
    e = issue()
    eq(#e.articles, 1); eq(e.articles[1].title, "Second")
end)

test("profil de carte : race, sexe, objets ; envoye seulement s'il change ; opt-out", function()
    local ns = boot({ specIndex = 1 })
    function UnitSex() return 3 end
    function GetInventoryItemID(_, slot) if slot == 5 then return 12345 end end
    local ev = ns.Profile.Publish()
    eq(ev.k, "CARD_PROFILE"); eq(ev.p.sex, 3); eq(ev.p.items, "5:12345"); eq(ev.p.optOut, nil)
    eq(ns.Profile.Publish(), nil, "rien n'a change")
    ns.char.albumOptOut = true
    local ev2 = ns.Profile.Publish()
    eq(ev2.p.optOut, true)
    eq(ns.Store.Dataset().optOut[ns.Context.Me()], nil, "son propre album n'est pas concerne")
    UnitSex, GetInventoryItemID = nil, nil
end)

test("booster : le paquet s'ouvre, cartes face cachee, une retournee au clic, puis toutes", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("album")
    local c = RenatusMainFrame.containers.album
    c.booster:Click()
    local r = c.reveal
    eq(r.stage, "pack")
    assert(r.pack:IsShown(), "paquet")
    r.cards[1]:Click()
    eq(r.cards[1].turned, false, "pas avant l'ouverture")
    Stub.advance(5)
    eq(r.stage, "pack", "le paquet attend qu'on clique dessus")
    r.pack:Click()
    Stub.advance(2)
    eq(r.stage, "deal")
    eq(r.cards[1].owned, false, "face cachee")
    r.cards[1]:Click()
    Stub.advance(0.5)
    eq(r.cards[1].owned, true, "retournee")
    eq(r.revealed, 1)
    assert(not r.ok:IsShown(), "pas encore fini")
    r.all:Click()
    Stub.advance(2)
    eq(r.revealed, 5); eq(r.stage, "done")
    assert(r.ok:IsShown() and not r.all:IsShown())
    -- zoom on an owned card of the grid
    c.onlyOwned = true; c:Refresh()
    c.cards[1]:Click()
    assert(c.zoom and c.zoom:IsShown(), "carte agrandie")
    local z = ns.UI.ShowCardZoom(ns.Cards.LIST[1], 1)
    eq(z.card.no:GetText(), "N° B-001")
    eq(z.card.date:GetText(), "19/11/2026")
end)

test("catalogue publie : un CARD_SET au plus gros passe la synchro (taille)", function()
    local ns = boot({ specIndex = 1, roster = OFFICER.roster, rank = 0 })
    local cards = {}
    for i = 1, 11 do   -- more than the app packs under 4000 bytes, with long accented texts
        cards[i] = { id = "M:Player-1-ABCDEFGH:legendary" .. i, no = 100 + i, s = "members", r = "legendary",
            n = ("é"):rep(20), f = ("à"):rep(140), cl = "WARRIOR", g = "Player-1-ABCDEFGH" }
    end
    local ev = ns.Store.Add("CARD_SET", { set = "2026-11-21-0120", cards = cards }, { vis = "G", prov = "GEN", noExp = true, loc = {} })
    local text = ns.Serialize.Encode({ o = "E", e = ev, g = ns.Context.GuildKey() })
    assert(#text <= ns.Sync.MAX_EVENT_BYTES, "trop gros pour la synchro : " .. #text)
end)

test("renatus_admin : publier le numero publie ses cartes ; apercu des cartes", function()
    local ns, A = bootAdmin(OFFICER)
    withPress({
        { id = "ia:E1:a", kind = "ARTICLE", refs = {}, p = { title = "Une", body = "Un", edition = "E1", order = 1, key = "a" } },
        { id = "ia:E1:maquette", kind = "EDITION", p = { edition = "E1", cells = { { pg = 1, r = 1, w = 12, b = { { t = "story", a = "@1" } } } } } },
        { id = "cards:E1:1", kind = "CARD_SET", p = cardSet("E1", 1) },
    })
    local Press = A.Press
    local cs = Press.Pending(function(i) return i.kind == "CARD_SET" end)[1]
    assert(Press.Label(cs):find("4 carte%(s%), n° 1 à 3"), Press.Label(cs))
    local r = Press.Preview(cs)
    eq(r.stage, "done", "apercu : face visible")
    eq(r.cards[1].owned, true)
    eq(#eventsOf(ns, "CARD_SET"), 0, "apercu : rien de publie")
    local ed = Press.Pending(function(i) return i.kind == "EDITION" end)[1]
    assert(Press.Publish(ed))
    local ev = eventsOf(ns, "CARD_SET")[1]
    eq(ev.prov, "GEN"); eq(ev.vis, "G"); eq(ev.p.set, "E1")
    eq(ns.Album.Catalogue(ns.Store.Dataset()).published, true)
    RenatusPress = nil
end)

test("renatus_admin : corrections de l'app (carte, article) publiees en jeu, vues par la guilde", function()
    local ns, A = bootAdmin(OFFICER)
    ns.Store.Add("BOOSTER_OPEN", { n = 1, cards = { "X:boss1" } }, { keep = true, noExp = true, loc = {} })
    withPress({
        { id = "ia:E1:a", kind = "ARTICLE", refs = {}, p = { title = "Une", body = "Un", edition = "E1", order = 1, key = "a" } },
        { id = "ia:E1:maquette", kind = "EDITION", p = { edition = "E1", cells = { { pg = 1, r = 1, w = 12, b = { { t = "story", a = "@1" } } } } } },
        { id = "cards:E1:1", kind = "CARD_SET", p = cardSet("E1", 1) },
    })
    assert(A.Press.Publish(A.Press.Pending(function(i) return i.kind == "EDITION" end)[1]))
    local original = eventsOf(ns, "ARTICLE")[1]
    -- what the admin app writes (admin/core/src/revise.rs)
    withPress({
        { id = "fix:card:X:boss1:50", kind = "CARD_SET", p = { set = "fix:50", cards = {
            { id = "X:boss1", no = 3, s = "expeditions", r = "legendary", n = "Hogger, enfin", f = "Corrige." } } } },
        { id = "fix:card:M:Player-1-BOB:common:51", kind = "CARD_SET", p = { set = "fix:51", cards = {
            { id = "M:Player-1-BOB:common", del = true } } } },
        { id = "fix:article:" .. original.id .. ":52", kind = "ARTICLE", p = { replaces = original.id, title = "Une (rectifiee)",
            body = "Deux", quote = "", format = "Breve", style = "" } },
    })
    local Press = A.Press
    local labels = {}
    for _, item in ipairs(Press.Pending()) do labels[#labels + 1] = Press.Label(item) end
    table.sort(labels)
    eq(labels[1], "Correction d'article : Une (rectifiee)")
    eq(labels[2], "Correction de la carte : Hogger, enfin")
    eq(labels[3], "Retrait de la carte M:Player-1-BOB:common")
    for _, item in ipairs(Press.Pending()) do assert(Press.Publish(item)) end
    local ds = ns.Store.Dataset()
    local byId = {}
    for _, c in ipairs(ns.Album.Catalogue(ds)) do byId[c.id] = c end
    eq(byId["X:boss1"].name, "Hogger, enfin"); eq(byId["X:boss1"].no, 3)
    eq(byId["M:Player-1-BOB:common"], nil, "retiree")
    local list = ns.Views.Editions(ds)
    eq(#list, 1, "la correction n'est pas un numero")
    eq(#list[1].articles, 1)
    local a = list[1].articles[1]
    eq(a.id, original.id); eq(a.title, "Une (rectifiee)"); eq(a.body, "Deux"); eq(a.kind, "Breve"); eq(a.key, "a")
    eq(a.style, nil, "champ vide : efface")
    RenatusPress = nil
end)

test("renatus_admin : apercu de plus de cinq cartes, cinq par cinq (cartes suivantes)", function()
    local ns, A = bootAdmin(OFFICER)
    local cards = {}
    for i = 1, 7 do cards[i] = { id = "Z:" .. i, no = i, s = "faits", r = "common", n = "Carte " .. i } end
    withPress({ { id = "cards:E9:1", kind = "CARD_SET", p = { set = "E9", cards = cards } } })
    local item = A.Press.Pending(function(i) return i.kind == "CARD_SET" end)[1]
    local r = A.Press.Preview(item)
    eq(#r.got, 5); eq(r.got[1].name, "Carte 1")
    eq(r.more:IsShown(), true, "bouton cartes suivantes")
    eq(r.ok.label:GetText(), "Fermer")
    r.more:GetScript("OnClick")(r.more)
    eq(#r.got, 2, "les deux dernieres"); eq(r.got[1].name, "Carte 6")
    eq(r.more:IsShown(), true, "puis retour aux premieres")
    r.more:GetScript("OnClick")(r.more)
    eq(r.got[1].name, "Carte 1")
    -- five cards or less: no button
    withPress({ { id = "cards:E9:2", kind = "CARD_SET", p = { set = "E9", cards = { cards[1] } } } })
    r = A.Press.Preview(A.Press.Pending(function(i) return i.id == "cards:E9:2" end)[1])
    eq(r.more:IsShown(), false)
    RenatusPress = nil
end)

test("remise a zero : seulement ce qui est coche, pour toute la guilde ; reglages gardes", function()
    local ns, A = bootAdmin(OFFICER)
    withPress({
        { id = "ia:E1:a", kind = "ARTICLE", refs = {}, p = { title = "Une", body = "Un", edition = "E1", order = 1, key = "a" } },
        { id = "ia:E1:maquette", kind = "EDITION", p = { edition = "E1", cells = { { pg = 1, r = 1, w = 12, b = { { t = "story", a = "@1" } } } } } },
        { id = "cards:E1:1", kind = "CARD_SET", p = cardSet("E1", 1) },
    })
    assert(A.Press.Publish(A.Press.Pending(function(i) return i.kind == "EDITION" end)[1]))
    ns.UI.Open("album")
    RenatusMainFrame.containers.album.booster:Click()
    local anecdote = ns.Store.AddManual("ANECDOTE", { title = "Reste" })
    local consent = ns.Consent and ns.Consent.SetConsent and ns.Consent.SetConsent(true)
    -- the tab: gazette, cards and boosters ticked by default, journal not
    A.Open("reset")
    local page = RenatusAdminFrame.pages.reset
    eq(page.checks.gazette:GetChecked(), true); eq(page.checks.journal:GetChecked(), false)
    page.go:Click()
    eq(page.go.label:GetText(), "Confirmer ?", "deux clics")
    eq(ns.Store.Dataset().boostersOpened, 1, "rien avant confirmation")
    page.go:Click()
    local ds = ns.Store.Dataset()
    eq(#ds.articles, 0, "plus de gazette")
    eq(ns.Album.Catalogue(ds).published, false, "plus de cartes publiees")
    eq(ds.boostersOpened, 0); eq(next(ds.collection), nil, "collection videe")
    eq(ds.boosters, 1, "le booster du jour revient")
    eq(#eventsOf(ns, "TOMBSTONE"), 4, "une pierre tombale par evenement partage (ouverture comprise)")
    assert(not ns.db.events[anecdote.id].del, "journal non coche : garde")
    assert(page.info:GetText():find("4 événement"), page.info:GetText())
    -- then the journal alone: settings stay
    eq(A.Reset({ journal = true }) >= 1, true)
    assert(ns.db.events[anecdote.id].del, "journal retire")
    for _, ev in ipairs(eventsOf(ns, "AI_CONSENT")) do assert(not ev.del, "consentement garde") end
    for _, ev in ipairs(eventsOf(ns, "TOMBSTONE")) do assert(not ev.del, "pierres tombales jamais retirees") end
    RenatusPress = nil
end)

print("Mise en page de la gazette (Newsprint)")

-- Texts currently drawn on the gazette canvas.
local function canvasText(c)
    local cv, out = c.front.canvas, {}
    for i = 1, cv.nfs do table.insert(out, tostring(cv.fs[i]:GetText())) end
    return table.concat(out, "\n")
end

test("mise en page : donnees du reseau bornees, blocs inconnus ignores", function()
    local ns = boot({ specIndex = 1 })
    local NP = ns.UI.Newsprint
    eq(NP.Sanitize(nil), nil); eq(NP.Sanitize({ cells = "x" }), nil); eq(NP.Sanitize({ cells = { { pg = 0, r = 1 } } }), nil)
    local cells = {}
    for pg = 9, 1, -1 do
        for r = 1, 6 do
            for _ = 1, 6 do
                table.insert(cells, { pg = pg, r = r, w = 40, h = 5, b = {
                    { t = "story", a = "@1", cols = "2", evil = function() end }, { t = 42 }, { t = "hologramme", text = string.rep("x", 5000) } } })
            end
        end
    end
    local l = NP.Sanitize({ titles = { string.rep("t", 200) }, cells = cells })
    eq(#l.pages, NP.LIMITS.pages)
    local pg = l.pages[1]
    eq(#pg.rows, NP.LIMITS.rows); eq(#pg.rows[1].cells, NP.LIMITS.cells)
    eq(pg.title, nil, "pages lues dans l'ordre des cases (ici 9, 8...), puis triees")
    eq(pg.rows[1].h, 1); eq(pg.rows[1].cells[1].w, 12)
    local blocks = pg.rows[1].cells[1].blocks
    eq(#blocks, 2, "bloc sans type ecarte"); eq(blocks[1].cols, 2); eq(blocks[1].evil, nil)
    eq(#blocks[2].text, NP.LIMITS.text, "type inconnu garde mais jamais dessine")
    eq(NP.BLOCKS[blocks[2].t], nil)
    -- titles, row order and heights
    local l2 = NP.Sanitize({ titles = { "", "Deux" }, cells = { { pg = 2, r = 2, w = 6, b = {} }, { pg = 2, r = 1, w = 6, h = 0.3, b = {} },
        { pg = 1, r = 1, w = 12, b = {} } } })
    eq(#l2.pages, 2); eq(l2.pages[1].title, nil); eq(l2.pages[2].title, "Deux"); eq(l2.pages[2].rows[1].h, 0.3)
    -- markup: subheadings coloured word by word, accents in capitals
    local m = NP.Markup("Intro\n## Le verdict été\nFin")
    assert(m:find("|c%x+LE|r |c%x+VERDICT|r |c%x+ÉTÉ|r"), m)
end)

test("mise en page : une EDITION passe par la synchro (profondeur, taille)", function()
    local ns = boot({ specIndex = 1 })
    local cells = {}
    for r = 1, 4 do for c = 1, 3 do
        table.insert(cells, { pg = 1, r = r, w = 4, h = 0.25, b = { { t = "story", a = "@1", cols = 2, head = "xl", drop = true },
            { t = "quote", a = "0123456789" }, { t = "portrait", a = "0123456789" } } })
    end end
    local ev = ns.Store.Add("EDITION", { edition = "2026-S47", template = "grande_une", titles = { "", "Suite" }, cells = cells },
        { vis = "G", prov = "GEN", noExp = true })
    local text = ns.Serialize.Encode({ o = "E", g = "x", e = ev })
    assert(text, "encodable")
    assert(#text < ns.Sync.MAX_EVENT_BYTES, #text)
    local back = ns.Serialize.Decode(text)
    eq(back.e.p.cells[12].b[3].t, "portrait")
    assert(ns.UI.Newsprint.Sanitize(back.e.p), "relu par les autres membres")
end)

test("mise en page de demo : pages, portrait, citation, avis, sommaire", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    local e = c.editions[1]
    assert(e.layout and e.layout.template == "grande_une", "mise en page de la semaine")
    eq(e.articles[1].key, "demo-tobias", "@1 = la plus votee")
    eq(#c.pages, 2)
    eq(c.pageNext:IsShown(), true); eq(c.pagePrev.gcDisabled, true)
    local p1 = canvasText(c)
    assert(p1:find("Tobias, onze fois regretté"), "une")
    assert(p1:find("LE PORTRAIT") and p1:find("Voleur"), "portrait : classe tiree du journal")
    assert(p1:find("Il avait l'air si vulnérable"), "citation de @3")
    eq(c.front.mast:IsShown(), true)
    c.front.storyHit:Click()
    eq(c.reader.title:GetText(), "Tobias, onze fois regretté")
    c.back:Click()
    c.pageNext:Click()
    eq(c.page, 2)
    eq(c.front.running:IsShown(), true); eq(c.front.mast:IsShown(), false)
    eq(c.front.runTitle:GetText(), "DIPLOMATIE ET FAITS DIVERS")
    local p2 = canvasText(c)
    assert(p2:find("RECHERCHÉ") and p2:find("Mortefeuille"), "avis de recherche")
    assert(p2:find("DANS CETTE ÉDITION") and p2:find("Le mouton de la discorde"), "sommaire : article non place")
    assert(c.front.footRight:GetText():find("Page 2 sur 2"))
    c:OpenEdition(2)
    eq(c.page, 1, "autre edition : retour en page 1")
    eq(c.editions[2].layout, nil, "edition sans mise en page : la une classique")
    eq(#c.pages, 1)
end)

test("mise en page : un article qu'aucun bloc ne montre part sur une page de suite", function()
    local ns = boot({ specIndex = 1 })
    local NP = ns.UI.Newsprint
    local e = { articles = { { title = "A" }, { title = "B" }, { title = "C" } },
        layout = NP.Sanitize({ cells = { { pg = 1, r = 1, w = 12, b = { { t = "story", a = "@2" } } } } }) }
    local pages, placed = NP.Pages(e)
    eq(#pages, 2); eq(pages[2].title, "Suite de l'édition")
    eq(placed[e.articles[2]], true)
    eq(pages[2].rows[1].cells[1].blocks[1].a, "@1"); eq(pages[2].rows[1].cells[2].blocks[1].a, "@3")
    eq(NP.Resolve(e, "@9"), nil)
end)

local function editionItems()
    return {
        { id = "ia:E1:a", kind = "ARTICLE", refs = {}, p = { title = "Seconde", body = "Deux", edition = "E1", order = 2, key = "a" } },
        { id = "ia:E1:b", kind = "ARTICLE", refs = {}, p = { title = "Premiere", body = "Un", edition = "E1", order = 1, key = "b",
            quote = "Un", portrait = "Testeur" } },
        { id = "ia:E1:maquette", kind = "EDITION", p = { edition = "E1", template = "test", cells = {
            { pg = 1, r = 1, w = 8, b = { { t = "story", a = "@1" } } },
            { pg = 1, r = 1, w = 4, b = { { t = "portrait", a = "@1" }, { t = "quote", a = "b" }, { t = "teaser", a = "a" } } } } } },
    }
end

test("edition : publier la mise en page publie ses articles ; ordre editorial ; apercu", function()
    local ns, A = bootAdmin(OFFICER)
    withPress(editionItems())
    local Press = A.Press
    local ed = Press.Pending(function(i) return i.kind == "EDITION" end)[1]
    assert(Press.Label(ed):find("2 article"), Press.Label(ed))
    -- preview: nothing published
    Press.Preview(ed)
    local c = RenatusMainFrame.containers.gazette
    eq(#eventsOf(ns, "ARTICLE"), 0)
    eq(c.front.topRight:GetText(), "APERÇU, NON PUBLIÉ")
    eq(c.current.title, "Premiere", "@1 = premier dans l'ordre editorial")
    eq(c.endPreview:IsShown(), true); eq(c.archives:IsShown(), false)
    assert(canvasText(c):find("LE PORTRAIT"), "portrait dans l'apercu")
    c.endPreview:Click()
    eq(c.preview, nil)
    -- publication
    local ev = Press.Publish(ed)
    eq(ev.k, "EDITION"); eq(ev.prov, "GEN")
    eq(#eventsOf(ns, "ARTICLE"), 2, "articles publies avec la mise en page")
    eq(#Press.Pending(), 0)
    c:Refresh()
    local e = c.editions[1]
    eq(e.layout.template, "test")
    eq(e.articles[1].title, "Premiere")
    local text = canvasText(c)
    assert(text:find("Seconde") and text:find("« Un »"), "teaser et citation")
    RenatusPress = nil
end)

test("edition : la mise en page d'un non-officier est ignoree", function()
    local ns = boot({ specIndex = 1, rank = 0, roster = { { name = "Testeur", rank = 0 }, { name = "Bob", rank = 4 } } })
    ns.Store.Add("ARTICLE", { title = "Vraie une", body = "x", edition = "E9" }, { vis = "G", prov = "GEN", noExp = true })
    local t = GetServerTime and GetServerTime() or time()
    ns.Store.Insert({ v = 1, id = "Player-1-BOB:1", a = "Player-1-BOB", n = "Bob", s = 1, t = t, k = "EDITION",
        g = ns.Context.GuildKey(), vis = "G", prov = "GEN", p = { edition = "E9", cells = { { pg = 1, r = 1, w = 12, b = {
            { t = "notice", title = "Pirate" } } } } } })
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    eq(#ns.Store.Dataset().layouts, 1)
    eq(c.editions[1].layout, nil)
    assert(not canvasText(c):find("Pirate"))
end)

test("numeros : deux parutions la meme semaine = deux numeros ; evenements cites marques dans le journal", function()
    local ns = boot({ specIndex = 1, rank = 0, roster = { { name = "Testeur", rank = 0 } } })
    local opts = { vis = "G", prov = "MAN" }
    local old = ns.Store.Add("ANECDOTE", { title = "Bob tombe dans le lac" }, opts)
    local fresh = ns.Store.Add("ANECDOTE", { title = "Bob ressort du lac" }, opts)
    local pub = { vis = "G", prov = "GEN", noExp = true }
    -- an article from before issues: grouped by week
    ns.Store.Add("ARTICLE", { title = "Ancien", body = "x" }, pub)
    ns.Store.Add("ARTICLE", { title = "Lac 1", body = "x", edition = "E1", order = 1 }, { vis = "G", prov = "GEN", noExp = true, refs = { old.id } })
    ns.Store.Add("EDITION", { edition = "E1", till = old.t + 1, cells = { { pg = 1, r = 1, w = 12, b = { { t = "story", a = "@1" } } } } }, pub)
    ns.Store.Add("ARTICLE", { title = "Lac 2", body = "y", edition = "E2", order = 1 }, { vis = "G", prov = "GEN", noExp = true, refs = { fresh.id } })
    ns.Store.Add("ARTICLE", { title = "Lac 2 bis", body = "z", edition = "E2", order = 2 }, pub)
    local list, cited = ns.Views.Editions(ns.Store.Dataset())
    eq(#list, 3, "E1, E2 et l'ancien article")
    local byKey = {}
    for _, e in ipairs(list) do byKey[e.key] = e end
    eq(#byKey.E2.articles, 2); eq(byKey.E2.articles[1].title, "Lac 2")
    eq(byKey.E1.layout ~= nil, true, "mise en page rattachee a son numero")
    eq(byKey.E2.layout, nil)
    eq(cited[old.id], byKey.E1); eq(cited[fresh.id], byKey.E2)
    assert(byKey.E1.label:find("^Paru le "), byKey.E1.label)
    ns.UI.Open("journal")
    local marked = 0
    for _, row in ipairs(RenatusMainFrame.containers.journal.list.rows) do
        if row:IsShown() and row.item and (row.line2:GetText() or ""):find("Paru dans le n° " .. byKey.E1.number) then marked = marked + 1 end
    end
    eq(marked, 1, "l'evenement cite porte la mention")
end)

print("Notifications (icone de la gazette)")

test("icone de la gazette : nouvel article, boosters, pastilles du menu", function()
    local ns = boot({ specIndex = 1 })
    local w = RenatusGazetteWidget
    assert(w and w:IsShown(), "icone affichee")
    eq(w.gazette:IsShown(), false, "rien de neuf dans la gazette")
    eq(w.boosters.label:GetText(), "1", "booster du jour joue")
    -- An article published by someone else arrives (sync).
    local t = GetServerTime()
    ns.Store.Insert({ v = 1, id = "Player-1-BOB:1", a = "Player-1-BOB", n = "Bob", s = 1, t = t, k = "ARTICLE",
        g = ns.Context.GuildKey(), vis = "G", prov = "GEN", p = { title = "Scoop", body = "x" } })
    Stub.advance(3)
    eq(w.gazette:IsShown(), true, "pastille gazette")
    eq(w.gazette.label:GetText(), "!")
    eq(ns.UI.Notifier.Notices().gazette, 1)
    -- Right click: album; its menu entry shows the boosters, the gazette's the news.
    w.scripts.OnClick(w, "RightButton")
    eq(ns.UI.current, "album")
    local nav = RenatusMainFrame.navButtons
    eq(nav.album.badge.label:GetText(), "1")
    eq(nav.gazette.badge:IsShown(), true, "gazette signalee dans le menu")
    -- Left click: gazette, read.
    w.scripts.OnClick(w, "LeftButton")
    eq(ns.UI.current, "gazette")
    eq(ns.UI.Notifier.Notices().gazette, 0, "lu")
    eq(w.gazette:IsShown(), false)
    eq(nav.gazette.badge:IsShown(), false)
    w.scripts.OnClick(w, "LeftButton")
    eq(RenatusMainFrame:IsShown(), false, "second clic : ferme")
    -- Opening the booster clears the album pip.
    ns.UI.Open("album")
    RenatusMainFrame.containers.album.booster.scripts.OnClick(RenatusMainFrame.containers.album.booster, "LeftButton")
    eq(nav.album.badge:IsShown(), false, "plus de booster")
    eq(w.boosters:IsShown(), false)
    -- Option
    ns.char.ui.showWidget = false
    ns.UI.Notifier:Update()
    eq(w:IsShown(), false, "masquable")
end)

test("royaume vide renvoye par le jeu : cle de guilde inchangee, anciennes cles sans royaume acceptees", function()
    local ns, S = boot(OFFICER)
    eq(ns.Context.GuildKey(), "Les Testeurs-Forever")
    S.realm = ""
    eq(ns.Context.GuildKey(), "Les Testeurs-Forever", "dernier royaume connu")
    local C = ns.Context
    eq(C.SameGuild("Les Testeurs-", "Les Testeurs-Forever"), true)
    eq(C.SameGuild("Les Testeurs-Forever", "Les Testeurs-Autre"), false)
    eq(C.SameGuild("Autres-Forever", "Les Testeurs-"), false)
    -- an event written with the empty realm is still from this guild
    local t = GetServerTime()
    local ev = { v = 1, id = "Player-1-BOB:1", a = "Player-1-BOB", n = "Bob", s = 1, t = t, k = "ANECDOTE",
        g = "Les Testeurs-", vis = "G", prov = "MAN", p = { title = "x" } }
    assert(ns.Sync.Validate(ev, ns.Context.GuildKey()), "synchro : meme guilde")
    ns.Store.Insert(ev)
    eq(#ns.Views.Filter(ns.Store.Dataset().events, { guild = ns.Context.GuildKey(), kind = "ANECDOTE" }), 1, "onglet Guilde")
    -- guild settings published under the key without realm still apply
    ns.Store.Insert({ v = 1, id = "Player-1-ABC:99", a = "Player-1-ABC", n = "Testeur", s = 99, t = t, k = "GUILD_CONFIG",
        g = "Les Testeurs-", vis = "G", prov = "MAN", p = { rival = "Les Crocs" } })
    ns.GuildConfig.Invalidate()
    eq(ns.GuildConfig.Rival(), "Les Crocs")
    -- a fresh install whose game answers "" from the start: no realm to fall back on
    local ns2 = boot({ realm = "" })
    eq(ns2.Context.GuildKey(), "Les Testeurs-")
end)

test("courrier des lecteurs : la lettre parait dans le numero lu, page de courrier, encadre", function()
    local ns = boot({ specIndex = 1, rank = 0, roster = { { name = "Testeur", rank = 0 } } })
    local pub = { vis = "G", prov = "GEN", noExp = true }
    ns.Store.Add("ARTICLE", { title = "Premier", body = "x", edition = "E1", order = 1 }, pub)
    ns.Store.Add("EDITION", { edition = "E1", cells = { { pg = 1, r = 1, w = 8, b = { { t = "story", a = "@1" } } },
        { pg = 1, r = 1, w = 4, b = { { t = "letters" } } } } }, pub)
    -- an old letter without issue goes with the issue published before it
    ns.Store.Add("LETTER", { title = "Ancienne", desc = "sans numero" }, { vis = "G", prov = "MAN" })
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    eq(#c.editions[1].letters, 1)
    eq(c.paper.letter.label:GetText(), "Courrier des lecteurs (1)")
    assert(canvasText(c):find("1 lettre%. La dernière, de Testeur"), "encadre : nombre et extrait")
    -- the mail page, then writing from it
    c.paper.letter:Click()
    eq(c.mail, true)
    assert(c.reader:IsShown() and c.reader.kind:GetText() == "COURRIER DES LECTEURS")
    assert(c.reader.body.fontString:GetText():find("sans numero"), "lettre affichee")
    assert(c.reader.body.fontString:GetText():find("— Testeur, le "), "signee et datee")
    eq(c.paper.letter.label:GetText(), "Écrire à la rédaction")
    c.paper.letter:Click() -- opens the letter dialog
    local dialog = ns.UI.Dialogs.Letter(c.editions[1].key)
    dialog.inputs.title.input:SetText("Démenti")
    dialog.inputs.desc.input:SetText("Je n'étais pas au lac.")
    dialog.save:Click()
    local ev
    for _, e in ipairs(eventsOf(ns, "LETTER")) do if e.p.title == "Démenti" then ev = e end end
    eq(ev.vis, "G", "toujours partagee"); eq(ev.p.edition, "E1")
    eq(#c.editions[1].letters, 2)
    assert(c.reader.body.fontString:GetText():find("pas au lac"), "nouvelle lettre dans le meme numero")
    c.back:Click()
    eq(c.mail, false); eq(c.front:IsShown(), true)
end)

print(string.format("\n%d ok, %d echec(s)", passed, failed))
os.exit(failed == 0 and 0 or 1)
