-- Tableau pour déterminer le type de personnage en fonction de la classe et de la spécialisation
local classSpecToType = {
    ["DEATHKNIGHT"] = { "melee", "melee", "melee" },
    ["DEMONHUNTER"] = { "melee", "melee" },
    ["DRUID"] = { "caster", "melee", "melee", "caster" },
    ["HUNTER"] = { "ranged", "melee", "ranged" },
    ["MAGE"] = { "caster", "caster", "caster" },
    ["MONK"] = { "melee", "melee", "melee" },
    ["PALADIN"] = { "melee", "melee", "melee" },
    ["PRIEST"] = { "caster", "caster", "caster" },
    ["ROGUE"] = { "melee", "melee", "melee" },
    ["SHAMAN"] = { "caster", "melee", "caster" },
    ["WARLOCK"] = { "caster", "caster", "caster" },
    ["WARRIOR"] = { "melee", "melee", "melee" },
}

-- Liste des fichiers son dans le répertoire de l'addon
local fightGeneric = {
    "allez_on_se_concentre",
    "concentre_toi",
    "on_reste_souple_sur_les_appuis",
    "cest_bien",
    "crois_en_toi",
    "garde_le_rythme",
    "heraklia_sera_fier",
    "le_bon_bout",
    "pense_a_ton_jeu_de_jambes",
    "raid_mieux_que_ca",
    "tu_peux_le_faire"
}
local fightMelee = {
    "allez_tape_plus_fort",
    "poids_vers_l_avant"
}
local fightCaster = {
    "garde_les_bras_souples_incanter",
    "inspire_bien_avant_incanter"
}
local fightRanged = {
    "bien_respirer_bien_viser"
}
local fightHealer = {
    "soigner_cest_bien",
    "soigner_coequipiers_nuls"
}
local fightDPS = {
    
}
local fightTank = {
    "abaisse_pas_ta_garde",
    "allez_meme_pas_mal",
    "allez_tu_sens_rien",
    "pas_eu_mal",
    "reste_bien_sur_tes_gardes"
}
local death = {
    "abandonne_pas",
    "pauvre_merde",
    "renatus_honte",
    "tu_feras_mieux"
}
local startFight = {
    "encore_un_defi",
    "ennemi_pas_a_ta_hauteur",
    "met_a_profit",
    "nouveau_challenge_a_relever"
}
local endFight = {
    "etirements",
    "hydrater",
    "rien_arrete"
}

local mergedFightSounds = {}
local soundChannel = "Ambience"
local duckSFXVolume = 0.25
local duckDuration = 2.8
local duckFadeDuration = 1.2
local duckFadeSteps = 8

-- Variables pour gérer le temps et la probabilité du son
local timeSinceLastUpdate = 0
local updateTime = 3 -- Vérifie toutes les 3 seconde(s)
local soundProbability = 0.5 -- Probabilité de jouer le son (0 à 1)

local lastSoundHandle
local previousSFXVolume
local duckToken = 0

-- Crée un cadre pour écouter les événements et vérifier le combat
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        OnLoad()
    elseif event == "PLAYER_LOGOUT" then
        RestoreCombatSounds(true)
    elseif event == "PLAYER_REGEN_DISABLED" then
        PlayRandomSound(startFight)
        timeSinceLastUpdate = 0
    elseif event == "PLAYER_REGEN_ENABLED" then
        PlayRandomSound(endFight)
    elseif event == "PLAYER_DEAD" then
        PlayRandomSound(death)
    end
end)

frame:SetScript("OnUpdate", function(self, elapsed)
    timeSinceLastUpdate = timeSinceLastUpdate + elapsed
    if timeSinceLastUpdate >= updateTime then
        UpdateCombat()
        timeSinceLastUpdate = 0
    end
end)

-- Fonction appelée lors de la connexion du joueur
function OnLoad()
    -- Récupère l'ID de la classe du joueur
    local _, _, classID = UnitClass("player")
    playerClassID = classID
    local role = GetSpecInfos()

    -- print(role)
    mergedFightSounds = {}
    if role == "DAMAGER" then
        mergedFightSounds = ConcatenateLists(fightGeneric, fightDPS);
    elseif role == "TANK" then
        mergedFightSounds = ConcatenateLists(fightGeneric, fightTank);
    elseif role == "HEALER" then
        mergedFightSounds = ConcatenateLists(fightGeneric, fightHealer);
    end

    -- print(table.getn(mergedFightSounds))

    -- Appel de la fonction pour obtenir et afficher le type de personnage
    local characterType = GetCharacterType()
    if characterType then
        if characterType == "melee" then
            mergedFightSounds = ConcatenateLists(mergedFightSounds, fightMelee);
        elseif characterType == "caster" then
            mergedFightSounds = ConcatenateLists(mergedFightSounds, fightCaster);
        elseif characterType == "ranged" then
            mergedFightSounds = ConcatenateLists(mergedFightSounds, fightRanged);
        end
    end

    -- print(table.getn(mergedFightSounds))
end

-- Fonction pour vérifier si le joueur est en combat et jouer un son aléatoire de la liste
function UpdateCombat()
    if InCombatLockdown() then
        if math.random() < soundProbability then
            PlayRandomSound(mergedFightSounds)
        end
    end
end

-- Fonction pour jouer un son aléatoire de la liste
function PlayRandomSound(sounds)
    if not sounds or #sounds == 0 then
        return
    end

    local randomIndex = math.random(#sounds)
    local randomSoundFile = "Interface\\AddOns\\Renacoach\\Resources\\" .. sounds[randomIndex] .. ".ogg"
    -- print("play: " .. randomSoundFile)
    if lastSoundHandle then
        StopSound(lastSoundHandle)
    end
    local willPlay, soundHandle = PlaySoundFile(randomSoundFile, soundChannel)
    if not willPlay then
        willPlay, soundHandle = PlaySoundFile(randomSoundFile, "Master")
    end
    if willPlay then
        DuckCombatSounds()
    end
    lastSoundHandle = soundHandle
end

function DuckCombatSounds()
    local currentSFXVolume = tonumber(GetCVar("Sound_SFXVolume")) or 1
    if not previousSFXVolume then
        previousSFXVolume = tostring(currentSFXVolume)
    end

    SetCVar("Sound_SFXVolume", tostring(math.min(currentSFXVolume, duckSFXVolume)))

    duckToken = duckToken + 1
    local currentDuckToken = duckToken
    C_Timer.After(duckDuration, function()
        if currentDuckToken == duckToken and previousSFXVolume then
            RestoreCombatSounds()
        end
    end)
end

function RestoreCombatSounds(immediate)
    duckToken = duckToken + 1
    if not previousSFXVolume then
        return
    end

    if immediate then
        SetCVar("Sound_SFXVolume", previousSFXVolume)
        previousSFXVolume = nil
        return
    end

    local restoreToken = duckToken
    local startVolume = tonumber(GetCVar("Sound_SFXVolume")) or duckSFXVolume
    local targetVolume = tonumber(previousSFXVolume) or startVolume
    local stepDuration = duckFadeDuration / duckFadeSteps

    for step = 1, duckFadeSteps do
        C_Timer.After(stepDuration * step, function()
            if restoreToken ~= duckToken or not previousSFXVolume then
                return
            end

            local progress = step / duckFadeSteps
            local nextVolume = startVolume + ((targetVolume - startVolume) * progress)
            SetCVar("Sound_SFXVolume", tostring(nextVolume))

            if step == duckFadeSteps then
                previousSFXVolume = nil
            end
        end)
    end
end

-- Fonction pour récupérer et afficher le rôle de la spécialisation active
function GetSpecInfos()
    local specIndex = GetSpecialization()
    local id, name, description, icon, role, primaryStat = GetSpecializationInfo(specIndex)
    return role
end

-- Fonction pour concaténer deux listes
function ConcatenateLists(list1, list2)
    local result = {}
    for _, value in ipairs(list1) do
        table.insert(result, value)
    end
    for _, value in ipairs(list2) do
        table.insert(result, value)
    end
    return result
end

-- Fonction pour déterminer le type de personnage (caster, melee, ranged)
function GetCharacterType()
    local _, playerClass = UnitClass("player")
    local specIndex = GetSpecialization()

    if not specIndex then
        -- print("Aucune spécialisation active.")
        return
    end

    local classSpecs = classSpecToType[playerClass]
    if not classSpecs then
        -- print("Classe non reconnue.")
        return
    end

    local characterType = classSpecs[specIndex]
    return characterType
end
