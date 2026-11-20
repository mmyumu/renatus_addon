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
    eq(#ns.UI.tabs, 6, "gazette, album + 4 journaux ; les reglages sont dans les Options")
    eq(ns.UI.tabs[1].key, "gazette"); eq(ns.UI.tabs[2].key, "album")
    assert(RenatusMainFrame.journalsLabel, "section journaux")
end)

test("tous les onglets s'ouvrent (demo) et se remplissent", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    openAllTabs(ns)
    local f = RenatusMainFrame
    assert(#f.containers.journal.list.items > 5, "journal rempli")
    assert(#f.containers.guild.list.items > 20, "guilde remplie")
    assert(#f.containers.members.list.items >= 9, "membres")
end)

test("filtres du journal de guilde", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("guild")
    local c = RenatusMainFrame.containers.guild
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
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("wanted")
    local c = RenatusMainFrame.containers.wanted
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

test("gazette reelle : relue et publiee dans la fenetre d'administration, vote une fois par semaine", function()
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
    c.paper.vote:Click()
    eq(c.current.votes, 1); eq(c.current.voted, true)
    c.paper.vote:Click()
    eq(c.current.votes, 1, "pas de double vote")
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
    eq(main, 3 + #ns.Types.CATEGORIES, "minicarte, consentement, album + confidentialite")
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

test("gazette : une edition par semaine, la une est l'article le plus vote", function()
    local ns = boot({ specIndex = 1 })
    SlashCmdList.RENATUS("demo")
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    assert(#c.editions >= 2, "editions par semaine")
    eq(c.editions[1].number, #c.editions, "la plus recente porte le plus grand numero")
    local first = c.editions[1]
    for _, a in ipairs(first.articles) do assert(a.votes <= first.articles[1].votes, "une = plus de votes") end
    eq(c.current, first.articles[1])
    assert(c.front:IsShown() and not c.reader:IsShown(), "premiere page")
    assert(c.front.info:GetText():find("Semaine du"), "semaine")
    eq(c.next.gcDisabled, true, "pas d'edition plus recente")
    -- older edition
    c.prev:Click()
    eq(c.edition, 2)
    eq(c.current, c.editions[2].articles[1])
    c.next:Click()
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

test("gazette vide : numero zero, rien a voter", function()
    local ns = boot({ specIndex = 1 })
    ns.UI.Open("gazette")
    local c = RenatusMainFrame.containers.gazette
    eq(c.current, nil)
    eq(c.front.headline:GetText(), "Les rotatives sont à l'arrêt")
    eq(c.paper.vote.gcDisabled, true)
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

print("Suppression (tombstones)")

local function inDataset(ns, id)
    for _, ev in ipairs(ns.Store.Dataset().events) do if ev.id == id then return true end end
    return false
end

test("supprimer une anecdote privee : clic droit dans le journal, confirmation", function()
    local ns = boot({ specIndex = 1 })
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

print(string.format("\n%d ok, %d echec(s)", passed, failed))
os.exit(failed == 0 and 0 or 1)
