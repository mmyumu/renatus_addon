-- Collectors/Enemies.lua : rencontres avec la guilde rivale (Wanted Board, docs §6.1).
--
-- Limites voulues (ethique, docs §6.5) :
--   - seulement les personnages de la guilde rivale configuree dans les parametres ;
--   - seulement ce que le jeu affiche (nom, royaume, guilde, niveau, race, classe, lieu) ;
--   - une observation par ennemi toutes les 10 minutes au plus : des rencontres, pas une traque.
-- Sources : cible, survol, barres de nom. Les valeurs secretes (instances) sont ignorees.
-- A la mort du joueur, les rivaux apercus dans les 30 dernieres secondes sont notes comme
-- "presents" : c'est une deduction (champ marque ded), jamais "tue par".
local _, ns = ...

local Enemies = ns:RegisterModule("CollectorEnemies", {})
ns.EnemyWatch = Enemies
local try = ns.Try

Enemies.COOLDOWN = 600
Enemies.PRESENT_WINDOW = 30

local recent = {}   -- [nom] = instant de la derniere vue (meme si non enregistree)

local function now() return (GetServerTime and GetServerTime()) or time() end

local function rival()
    local r = ns.char and ns.char.rivalGuild
    if type(r) ~= "string" then return nil end
    r = r:gsub("^%s+", ""):gsub("%s+$", "")
    return r ~= "" and string.lower(r) or nil
end

function Enemies.Observe(unit)
    local target = rival()
    if not target or not unit then return nil end
    if not try(UnitExists, unit) or not try(UnitIsPlayer, unit) then return nil end
    local guild = try(GetGuildInfo, unit)
    if not guild or string.lower(guild) ~= target then return nil end
    local name, realm = try(UnitName, unit)
    if not name or name == "" then return nil end
    local t = now()
    recent[name] = t
    local seenAt = ns.char.enemySeenAt
    if seenAt[name] and t - seenAt[name] < Enemies.COOLDOWN then return nil end
    seenAt[name] = t
    local level = try(UnitLevel, unit)
    if level and level <= 0 then level = nil end -- "??" : niveau inconnu
    local race = try(UnitRace, unit)
    local _, class = try(UnitClass, unit)
    return ns.Store.Add("ENEMY_SEEN", {
        name = name, realm = (realm and realm ~= "") and realm or nil, guild = guild,
        level = level, race = race, class = class,
        pvp = try(UnitIsPVP, unit) or nil,
    })
end

-- Noms des rivaux apercus recemment (pour la mort du joueur).
function Enemies.RecentNames(window)
    window = window or Enemies.PRESENT_WINDOW
    local t, list = now(), {}
    for name, at in pairs(recent) do
        if t - at <= window then table.insert(list, name) end
    end
    table.sort(list)
    return list
end

-- Purge des horodatages anciens (la table ne sert qu'a limiter la frequence).
local function purge()
    local t = now()
    for name, at in pairs(ns.char.enemySeenAt) do
        if t - at > 86400 then ns.char.enemySeenAt[name] = nil end
    end
end

function Enemies:OnLogin()
    purge()
    ns:RegisterGameEvent("PLAYER_TARGET_CHANGED", function() Enemies.Observe("target") end)
    ns:RegisterGameEvent("UPDATE_MOUSEOVER_UNIT", function() Enemies.Observe("mouseover") end)
    ns:RegisterGameEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Enemies.Observe(ns.Safe(unit)) end)
end
