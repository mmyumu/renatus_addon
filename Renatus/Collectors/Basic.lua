-- Collectors/Basic.lua : premiers collecteurs, limites aux evenements quasi certains.
-- Chaque inscription est protegee : un evenement absent sur Forever est simplement ignore.
-- A confirmer/affiner avec la sonde (docs/ARCHITECTURE.md §12).
local _, ns = ...

local Basic = ns:RegisterModule("CollectorBasic", {})
local try = ns.Try

local function today() return date("%Y%m%d", (GetServerTime and GetServerTime()) or time()) end

local function onLevelUp(_, level)
    level = ns.Safe(level)
    if level then ns.Store.Add("LEVEL_UP", { lvl = level }) end
end

local function onDead()
    -- Rivaux apercus juste avant : "presents", pas "tueurs" (deduction, marquee comme telle).
    local enemies = ns.EnemyWatch and ns.EnemyWatch.RecentNames() or {}
    ns.Store.Add("DEATH", { lvl = try(UnitLevel, "player"), enemies = #enemies > 0 and enemies or nil }, {
        miss = { "killer" },                 -- inaccessible aux addons (journal de combat ferme)
        pt = ns.Context.Participants(),
        ded = #enemies > 0 and { "enemies" } or nil,
    })
end

local function onQuestTurnedIn(_, questID)
    questID = ns.Safe(questID)
    if not questID then return end
    local title = C_QuestLog and try(C_QuestLog.GetTitleForQuestID, questID)
    ns.Store.Add("QUEST_DONE", { q = questID, title = title })
end

local function onEncounterEnd(_, encounterID, encounterName, difficultyID, groupSize, success)
    encounterID, success = ns.Safe(encounterID), ns.Safe(success)
    if not encounterID or success ~= 1 then return end
    ns.Store.Add("BOSS_KILL", {
        enc = encounterID, name = ns.Safe(encounterName), diff = ns.Safe(difficultyID), size = ns.Safe(groupSize),
    }, {
        occ = "ENC:" .. tostring(encounterID) .. ":" .. today(),
        pt = ns.Context.Participants(),
    })
end

-- Premiere visite connue de l'addon (pas forcement la premiere de la vie du personnage).
local function checkZone(silent)
    local mapID = C_Map and try(C_Map.GetBestMapForUnit, "player")
    local key = mapID or try(GetRealZoneText)
    if not key or key == "" then return end
    local visited = ns.char.visitedMaps
    if visited[key] then return end
    visited[key] = (GetServerTime and GetServerTime()) or time()
    if not silent then ns.Store.Add("ZONE_FIRST_VISIT", {}) end
end

-- Entree en guilde : seulement apres une premiere mesure de reference (sinon l'installation
-- de l'addon par un membre deja en guilde serait comptee comme une entree).
local function onGuildUpdate()
    if not ns.char.guildBaseline then return end
    local _, guildName = ns.Context.GuildKey()
    if guildName and guildName ~= ns.char.lastGuild then
        ns.Store.Add("GUILD_JOIN", { guild = guildName })
    end
    if guildName then ns.char.lastGuild = guildName end
end

local function takeGuildBaseline()
    if ns.char.guildBaseline then return end
    local _, guildName = ns.Context.GuildKey()
    ns.char.lastGuild = guildName
    ns.char.guildBaseline = true
end

function Basic:OnLogin()
    ns:RegisterGameEvent("PLAYER_LEVEL_UP", onLevelUp)
    ns:RegisterGameEvent("PLAYER_DEAD", onDead)
    ns:RegisterGameEvent("QUEST_TURNED_IN", onQuestTurnedIn)
    ns:RegisterGameEvent("ENCOUNTER_END", onEncounterEnd)
    ns:RegisterGameEvent("ZONE_CHANGED_NEW_AREA", function() checkZone(false) end)
    ns:RegisterGameEvent("PLAYER_GUILD_UPDATE", onGuildUpdate)
    -- La zone de connexion sert de point de depart, sans evenement.
    checkZone(true)
    -- Les infos de guilde arrivent parfois apres la connexion : reference prise a +10 s.
    if C_Timer then C_Timer.After(10, takeGuildBaseline) else takeGuildBaseline() end
end
