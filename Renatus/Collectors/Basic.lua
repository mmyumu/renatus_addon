-- Collectors/Basic.lua: first collectors, limited to near-certain events.
-- Every registration is protected: an event missing on Forever is simply ignored.
-- To be confirmed/refined with the probe (docs/ARCHITECTURE.md §12).
local _, ns = ...

local Basic = ns:RegisterModule("CollectorBasic", {})
local try = ns.Try

local function today() return date("%Y%m%d", (GetServerTime and GetServerTime()) or time()) end

local function onLevelUp(_, level)
    level = ns.Safe(level)
    if level then ns.Store.Add("LEVEL_UP", { lvl = level }) end
end

-- With a pet out (hunter, warlock) PLAYER_DEAD fires twice for one death.
local firstDeath = ns.Once(ns.Store.DEATH_TWIN)

local function onDead()
    if not firstDeath() then return end
    -- Rivals seen just before: "present", not "killers" (a deduction, flagged as such).
    local enemies = ns.EnemyWatch and ns.EnemyWatch.RecentNames() or {}
    local level = try(UnitLevel, "player")
    local participants = ns.Context.Participants()
    local function record(killer)
        -- A player killer seen just before: their guild and level (rival guild filter).
        local seen = killer and killer.pl and ns.EnemyWatch and ns.EnemyWatch.Known(killer.n)
        if seen then killer.gd, killer.lv = seen.guild, killer.lv or seen.level end
        ns.Store.Add("DEATH", { lvl = level, enemies = #enemies > 0 and enemies or nil, killer = killer }, {
            miss = not killer and { "killer" } or nil,  -- neither the combat log nor the death recap told us
            pt = participants,
            ded = #enemies > 0 and { "enemies" } or nil,
        })
    end
    local killer = ns.Killer and ns.Killer.Find()
    if killer or not (ns.Killer and ns.Killer.RecapPending()) or not C_Timer then
        record(killer)
    else
        -- The death recap may be filled a moment after the death.
        C_Timer.After(1, function() record(ns.Killer.Find()) end)
    end
end

local function onQuestTurnedIn(_, questID)
    questID = ns.Safe(questID)
    if not questID then return end
    local title = C_QuestLog and try(C_QuestLog.GetTitleForQuestID, questID)
    ns.Store.Add("QUEST_DONE", { q = questID, title = title })
end

local function onEncounterEnd(_, encounterID, encounterName, difficultyID, groupSize, success)
    encounterID, success = ns.Safe(encounterID), ns.Safe(success)
    local name = ns.Safe(encounterName)
    -- the boss's npc id, for the 3D model on its album card (Collectors/Creatures.lua)
    local npc = ns.Creatures and ns.Creatures.BossNpc(name)
    if ns.Creatures then ns.Creatures.EndEncounter() end
    if not encounterID or success ~= 1 then return end
    ns.Store.Add("BOSS_KILL", {
        enc = encounterID, name = name, diff = ns.Safe(difficultyID), size = ns.Safe(groupSize), npc = npc,
    }, {
        occ = "ENC:" .. tostring(encounterID) .. ":" .. today(),
        pt = ns.Context.Participants(),
    })
end

-- First visit known to the addon (not necessarily the character's first ever).
local function checkZone(silent)
    local mapID = C_Map and try(C_Map.GetBestMapForUnit, "player")
    local key = mapID or try(GetRealZoneText)
    if not key or key == "" then return end
    local visited = ns.char.visitedMaps
    if visited[key] then return end
    visited[key] = (GetServerTime and GetServerTime()) or time()
    if not silent then ns.Store.Add("ZONE_FIRST_VISIT", {}) end
end

-- Guild join: only after a first baseline measurement (otherwise installing the
-- addon while already in a guild would be counted as joining).
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
    ns.Store.MarkPlayed()   -- one booster per day played
    ns.Store.RetractTwinDeaths()   -- deaths recorded twice by older versions
    ns:RegisterGameEvent("PLAYER_LEVEL_UP", onLevelUp)
    ns:RegisterGameEvent("PLAYER_DEAD", onDead)
    ns:RegisterGameEvent("QUEST_TURNED_IN", onQuestTurnedIn)
    ns:RegisterGameEvent("ENCOUNTER_END", onEncounterEnd)
    ns:RegisterGameEvent("ZONE_CHANGED_NEW_AREA", function() checkZone(false) end)
    ns:RegisterGameEvent("PLAYER_GUILD_UPDATE", onGuildUpdate)
    -- The login zone is the starting point, no event.
    checkZone(true)
    -- Guild info sometimes arrives after login: baseline taken at +10 s.
    if C_Timer then C_Timer.After(10, takeGuildBaseline) else takeGuildBaseline() end
end
