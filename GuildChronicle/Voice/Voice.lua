-- Voice/Voice.lua : module "Renacoach" (repliques vocales), porte depuis Renacoach v1.0.0.
--
-- Comportement conserve (valeurs par defaut identiques a l'original) :
--   entree en combat -> startFight ; sortie -> endFight ; mort -> death ;
--   en combat, toutes les 3 s, 50 % de chances de jouer une replique de combat
--   (generique + role + type) ; une seule replique a la fois ; ducking du volume SFX.
-- Differences volontaires (voir docs/ARCHITECTURE.md) :
--   - module optionnel, desactive par defaut, reglable (/chronicle voice) ;
--   - plus aucune fonction globale ;
--   - repli si les specialisations n'existent pas (WoW Forever) ;
--   - correction de la table du chasseur (Precision etait classe "melee") ;
--   - le volume SFX est restaure au chargement suivant si le jeu a quitte pendant un ducking ;
--   - la replique de mort n'est pas coupee par celle de fin de combat.
local ADDON, ns = ...

local Voice = ns:RegisterModule("Voice", {})
ns.Voice = Voice

local SOUND_DIR = "Interface\\AddOns\\" .. ADDON .. "\\Voice\\Sounds\\"

-- Type de personnage par classe et index de specialisation (ordre Retail).
local classSpecToType = {
    DEATHKNIGHT = { "melee", "melee", "melee" },
    DEMONHUNTER = { "melee", "melee" },
    DRUID = { "caster", "melee", "melee", "caster" },
    EVOKER = { "caster", "caster", "caster" },
    HUNTER = { "ranged", "ranged", "melee" },   -- Maitrise des betes, Precision, Survie
    MAGE = { "caster", "caster", "caster" },
    MONK = { "melee", "melee", "melee" },
    PALADIN = { "melee", "melee", "melee" },
    PRIEST = { "caster", "caster", "caster" },
    ROGUE = { "melee", "melee", "melee" },
    SHAMAN = { "caster", "melee", "caster" },
    WARLOCK = { "caster", "caster", "caster" },
    WARRIOR = { "melee", "melee", "melee" },
}

-- Repli sans specialisation : seulement les classes sans ambiguite.
local classOnlyType = {
    HUNTER = "ranged", MAGE = "caster", PRIEST = "caster", WARLOCK = "caster",
    ROGUE = "melee", WARRIOR = "melee", PALADIN = "melee",
}

-- Familles de repliques : contenu identique a Renacoach v1.0.0.
local FAMILIES = {
    fightGeneric = {
        "allez_on_se_concentre", "concentre_toi", "on_reste_souple_sur_les_appuis", "cest_bien",
        "crois_en_toi", "garde_le_rythme", "heraklia_sera_fier", "le_bon_bout",
        "pense_a_ton_jeu_de_jambes", "raid_mieux_que_ca", "tu_peux_le_faire",
    },
    fightMelee = { "allez_tape_plus_fort", "poids_vers_l_avant" },
    fightCaster = { "garde_les_bras_souples_incanter", "inspire_bien_avant_incanter" },
    fightRanged = { "bien_respirer_bien_viser" },
    fightHealer = { "soigner_cest_bien", "soigner_coequipiers_nuls" },
    fightDPS = {},
    fightTank = {
        "abaisse_pas_ta_garde", "allez_meme_pas_mal", "allez_tu_sens_rien", "pas_eu_mal",
        "reste_bien_sur_tes_gardes",
    },
    death = { "abandonne_pas", "pauvre_merde", "renatus_honte", "tu_feras_mieux" },
    startFight = { "encore_un_defi", "ennemi_pas_a_ta_hauteur", "met_a_profit", "nouveau_challenge_a_relever" },
    endFight = { "etirements", "hydrater", "rien_arrete" },
}
Voice.FAMILIES = FAMILIES

local ROLE_FAMILY = { DAMAGER = "fightDPS", TANK = "fightTank", HEALER = "fightHealer" }
local TYPE_FAMILY = { melee = "fightMelee", caster = "fightCaster", ranged = "fightRanged" }

local lastSoundHandle
local duckToken = 0
local combatFamilies = {}   -- familles jouees en combat, selon role et type
local elapsedSinceTick = 0
local ticker = CreateFrame("Frame")
ticker:Hide()

local function settings() return ns.char.voice end

-- Role : specialisation Retail si disponible, sinon role de groupe, sinon inconnu.
function Voice.ResolveRole()
    if type(GetSpecialization) == "function" and type(GetSpecializationInfo) == "function" then
        local ok, specIndex = pcall(GetSpecialization)
        if ok and specIndex then
            local ok2, _, _, _, _, role = pcall(GetSpecializationInfo, specIndex)
            if ok2 and role then return role, specIndex end
        end
    end
    if type(UnitGroupRolesAssigned) == "function" then
        local ok, role = pcall(UnitGroupRolesAssigned, "player")
        if ok and role and role ~= "NONE" then return role, nil end
    end
    return nil, nil
end

function Voice.ResolveCharacterType(specIndex)
    local _, playerClass = UnitClass("player")
    if not playerClass then return nil end
    if specIndex and classSpecToType[playerClass] then
        return classSpecToType[playerClass][specIndex]
    end
    return classOnlyType[playerClass]
end

function Voice:RebuildPools()
    local role, specIndex = Voice.ResolveRole()
    local characterType = Voice.ResolveCharacterType(specIndex)
    combatFamilies = { "fightGeneric" }
    if ROLE_FAMILY[role] then table.insert(combatFamilies, ROLE_FAMILY[role]) end
    if TYPE_FAMILY[characterType] then table.insert(combatFamilies, TYPE_FAMILY[characterType]) end
    self.role, self.characterType = role, characterType
    return combatFamilies
end

function Voice:GetCombatFamilies() return combatFamilies end

-- Liste des fichiers jouables pour un ensemble de familles (familles desactivees exclues).
function Voice:CollectSounds(families)
    local enabledFamilies = settings().families
    local result = {}
    for _, family in ipairs(families) do
        if enabledFamilies[family] ~= false then
            for _, sound in ipairs(FAMILIES[family] or {}) do
                table.insert(result, sound)
            end
        end
    end
    return result
end

------------------------------------------------------------------------
-- Ducking du volume SFX (persistant en cas de crash)
------------------------------------------------------------------------
local FADE_DURATION, FADE_STEPS, DUCK_DURATION = 1.2, 8, 2.8

local function restore(immediate)
    duckToken = duckToken + 1
    local saved = ns.db.voiceDuck.previous
    if not saved then return end

    if immediate then
        SetCVar("Sound_SFXVolume", saved)
        ns.db.voiceDuck.previous = nil
        return
    end

    local token = duckToken
    local startVolume = tonumber(GetCVar("Sound_SFXVolume")) or settings().duckVolume
    local targetVolume = tonumber(saved) or startVolume
    local stepDuration = FADE_DURATION / FADE_STEPS
    for step = 1, FADE_STEPS do
        C_Timer.After(stepDuration * step, function()
            if token ~= duckToken or not ns.db.voiceDuck.previous then return end
            local volume = startVolume + (targetVolume - startVolume) * (step / FADE_STEPS)
            SetCVar("Sound_SFXVolume", tostring(volume))
            if step == FADE_STEPS then ns.db.voiceDuck.previous = nil end
        end)
    end
end
Voice.RestoreVolume = restore

local function duck()
    local current = tonumber(GetCVar("Sound_SFXVolume")) or 1
    if not ns.db.voiceDuck.previous then
        ns.db.voiceDuck.previous = tostring(current)
    end
    SetCVar("Sound_SFXVolume", tostring(math.min(current, settings().duckVolume)))
    duckToken = duckToken + 1
    local token = duckToken
    C_Timer.After(DUCK_DURATION, function()
        if token == duckToken and ns.db.voiceDuck.previous then restore(false) end
    end)
end

------------------------------------------------------------------------
-- Lecture
------------------------------------------------------------------------
function Voice:PlayFile(name)
    local path = SOUND_DIR .. name .. ".ogg"
    if lastSoundHandle then StopSound(lastSoundHandle) end
    local willPlay, handle = PlaySoundFile(path, settings().channel)
    if not willPlay then
        willPlay, handle = PlaySoundFile(path, "Master")
    end
    if willPlay and settings().duck then duck() end
    lastSoundHandle = handle
    return willPlay, name
end

-- Joue une replique au hasard parmi des familles. Ne fait rien si le module est desactive.
function Voice:PlayFamilies(families)
    if not settings().enabled then return false end
    local sounds = self:CollectSounds(families)
    if #sounds == 0 then return false end
    return self:PlayFile(sounds[math.random(#sounds)])
end

function Voice:Play(family) return self:PlayFamilies({ family }) end

------------------------------------------------------------------------
-- Declencheurs (identiques a Renacoach, sauf priorite de la mort)
------------------------------------------------------------------------
ticker:SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceTick = elapsedSinceTick + elapsed
    if elapsedSinceTick < settings().interval then return end
    elapsedSinceTick = 0
    if InCombatLockdown() and math.random() < settings().probability then
        Voice:PlayFamilies(combatFamilies)
    end
end)

local function onCombatStart()
    elapsedSinceTick = 0
    if not settings().enabled then return end
    Voice:Play("startFight")
    ticker:Show()
end

local function onCombatEnd()
    ticker:Hide()
    -- A la mort, la sortie de combat arrive en meme temps : on laisse la replique de mort.
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end
    Voice:Play("endFight")
end

local function onDeath()
    Voice:Play("death")
end

function Voice:OnInitialize()
    -- Le jeu a quitte (crash, deconnexion) pendant un ducking : on rend son volume au joueur.
    if ns.db.voiceDuck.previous then restore(true) end
end

function Voice:OnLogin()
    self:RebuildPools()
    ns:RegisterGameEvent("PLAYER_REGEN_DISABLED", onCombatStart)
    ns:RegisterGameEvent("PLAYER_REGEN_ENABLED", onCombatEnd)
    ns:RegisterGameEvent("PLAYER_DEAD", onDeath)
    ns:RegisterGameEvent("PLAYER_LOGOUT", function() restore(true) end)
    -- Ces evenements peuvent ne pas exister sur Forever : RegisterGameEvent l'absorbe.
    local rebuild = function() Voice:RebuildPools() end
    ns:RegisterGameEvent("PLAYER_SPECIALIZATION_CHANGED", rebuild)
    ns:RegisterGameEvent("ACTIVE_TALENT_GROUP_CHANGED", rebuild)
    ns:RegisterGameEvent("PLAYER_ROLES_ASSIGNED", rebuild)
end

function Voice:SetEnabled(enabled)
    settings().enabled = enabled and true or false
    if not enabled then
        ticker:Hide()
        if lastSoundHandle then StopSound(lastSoundHandle) end
        restore(true)
    elseif InCombatLockdown() then
        ticker:Show()
    end
end
