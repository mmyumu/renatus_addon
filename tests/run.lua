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

print(string.format("\n%d ok, %d echec(s)", passed, failed))
os.exit(failed == 0 and 0 or 1)
