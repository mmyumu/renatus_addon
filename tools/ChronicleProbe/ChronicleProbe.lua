-- ChronicleProbe : addon de diagnostic (Phase 0).
-- N'ecrit rien d'autre que ChronicleProbeDB. Toutes les sorties sont protegees
-- (pcall + issecretvalue) pour ne jamais casser sur une "secret value" Midnight.
--
-- Commandes :
--   /gcprobe            resume dans le chat
--   /gcprobe comm       envoie un message addon de test (GUILD, PARTY/RAID, WHISPER a soi-meme)
--   /gcprobe burst      envoie 30 messages a soi-meme pour mesurer le throttling
--   /gcprobe sound      joue un son de Renatus (module Voice) sur le canal Ambience
--   /gcprobe reset      efface les donnees collectees
-- Les resultats complets sont dans WTF/Account/<COMPTE>/SavedVariables/ChronicleProbe.lua
-- (ecrit a la deconnexion ou au /reload).

local PREFIX = "GCProbe"
local MAX_PER_EVENT = 15
local MAX_LOG = 400

local DB

local function isSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) and true or false
end

local function safe(v)
    if isSecret(v) then return "<secret>" end
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "<tostring error>"
end

local function packSafe(...)
    local out = {}
    for i = 1, select("#", ...) do
        out[i] = safe((select(i, ...)))
    end
    return out
end

local function lookup(path)
    local cur = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

local function context()
    local inInstance, instanceType = false, "?"
    if IsInInstance then
        local ok, a, b = pcall(IsInInstance)
        if ok then inInstance, instanceType = safe(a), safe(b) end
    end
    local inCombat = InCombatLockdown and safe(InCombatLockdown()) or "?"
    local t = GetServerTime and GetServerTime() or time()
    return { t = t, inInstance = inInstance, instanceType = instanceType, inCombat = inCombat }
end

local function log(kind, data)
    local entry = context()
    entry.kind = kind
    entry.data = data
    table.insert(DB.log, entry)
    while #DB.log > MAX_LOG do table.remove(DB.log, 1) end
end

-- API dont on veut connaitre l'existence (type de la valeur globale)
local API_NAMES = {
    "GetBuildInfo", "GetServerTime", "C_Timer.After", "C_Timer.NewTicker", "issecretvalue",
    "C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix", "SendAddonMessage",
    "C_ChatInfo.InChatMessagingLockdown", "CombatLogGetCurrentEventInfo",
    "IsInGuild", "GetGuildInfo", "GetNumGuildMembers", "GetGuildRosterInfo", "C_GuildInfo.GuildRoster", "GuildRoster",
    "C_Club.GetGuildClubId", "IsInGroup", "IsInRaid", "GetNumGroupMembers", "UnitGUID", "UnitFullName",
    "GetRealmName", "GetNormalizedRealmName", "IsInInstance", "GetInstanceInfo",
    "C_Map.GetBestMapForUnit", "C_Map.GetMapInfo", "GetRealZoneText", "GetSubZoneText", "GetZoneText",
    "GetSpecialization", "GetSpecializationInfo", "GetSpecializationRole", "GetTalentTabInfo",
    "UnitGroupRolesAssigned", "GetNumSkillLines", "GetSkillLineInfo", "C_TradeSkillUI.GetAllProfessionTradeSkillLines",
    "GetProfessions", "C_QuestLog.GetTitleForQuestID", "C_QuestLog.IsQuestFlaggedCompleted", "GetQuestLogTitle",
    "GetAchievementInfo", "GetTotalAchievementPoints", "C_MountJournal.GetNumMounts", "GetNumCompanions",
    "C_DeathRecap.GetRecapEvents", "GetDeathRecapLink", "C_EncounterJournal", "EJ_GetEncounterInfo",
    "PlaySoundFile", "StopSound", "GetCVar", "SetCVar", "C_CVar.GetCVar",
    "UnitClassification", "C_Item.GetItemInfo", "GetItemInfo", "C_GameRules", "WOW_PROJECT_ID", "WOW_PROJECT_CAMELOT",
    "WOW_PROJECT_MAINLINE", "WOW_PROJECT_CLASSIC", "LOOT_ITEM_SELF", "ERR_ZONE_EXPLORED",
    -- PvP / Wanted Board / narration
    "LoggingCombat", "C_Map.GetPlayerMapPosition", "GetPVPLifetimeStats", "GetPVPSessionStats",
    "UnitIsPVP", "UnitIsEnemy", "UnitRace", "C_PvP", "COMBATLOG_HONORGAIN", "COMBATLOG_HONORAWARD",
}

-- Evenements a tester (inscription) puis a journaliser (payload reel)
local EVENTS = {
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "QUEST_TURNED_IN", "QUEST_ACCEPTED",
    "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "UI_INFO_MESSAGE", "CHAT_MSG_SYSTEM", "CHAT_MSG_COMBAT_XP_GAIN",
    "CHAT_MSG_SKILL", "SKILL_LINES_CHANGED", "CHAT_MSG_LOOT", "ACHIEVEMENT_EARNED", "NEW_MOUNT_ADDED", "COMPANION_LEARNED",
    "ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL", "PARTY_KILL", "UNIT_DIED",
    "PLAYER_GUILD_UPDATE", "GUILD_ROSTER_UPDATE", "GROUP_ROSTER_UPDATE", "GROUP_JOINED", "GROUP_LEFT",
    "PLAYER_SPECIALIZATION_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED", "CHARACTER_POINTS_CHANGED",
    "CHAT_MSG_ADDON", "CHAT_MSG_ADDON_LOGGED", "ADDON_RESTRICTION_STATE_CHANGED",
    "CHAT_MSG_COMBAT_HONOR_GAIN", "PLAYER_PVP_KILLS_CHANGED", "DUEL_FINISHED",
    "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
}
-- Inscription testee puis immediatement annulee (trop volumineux a journaliser)
local TEST_ONLY_EVENTS = { "COMBAT_LOG_EVENT_UNFILTERED", "COMBAT_LOG_EVENT" }
-- Evenements frequents : on n'en garde que quelques occurrences
local NOISY = { GUILD_ROSTER_UPDATE = 3, GROUP_ROSTER_UPDATE = 5, CHAT_MSG_SYSTEM = 10, ZONE_CHANGED = 10,
    PLAYER_TARGET_CHANGED = 5, UPDATE_MOUSEOVER_UNIT = 5, NAME_PLATE_UNIT_ADDED = 5 }

-- Pour le Wanted Board : que peut-on lire d'un joueur ennemi vu en cible, survol ou barre de nom ?
local ENEMY_SIGHTING_MAX = 40
local function unitCall(fn, unit)
    if type(fn) ~= "function" then return "absent" end
    local res = { pcall(fn, unit) }
    if not table.remove(res, 1) then return "ERROR: " .. safe(res[1]) end
    return table.concat(packSafe(unpack(res)), " | ")
end

local function logEnemySighting(event, unit)
    if not unit or isSecret(unit) then return end
    local okP, isPlayer = pcall(UnitIsPlayer, unit)
    if not okP or isSecret(isPlayer) or not isPlayer then return end
    local okE, isEnemy = pcall(UnitIsEnemy, "player", unit)
    if not okE or isSecret(isEnemy) or not isEnemy then return end
    DB.enemySightings = DB.enemySightings or {}
    if #DB.enemySightings >= ENEMY_SIGHTING_MAX then return end
    local entry = context()
    entry.event = event
    entry.unit = unit
    entry.name = unitCall(UnitName, unit)
    entry.guild = unitCall(GetGuildInfo, unit)
    entry.level = unitCall(UnitLevel, unit)
    entry.race = unitCall(UnitRace, unit)
    entry.class = unitCall(UnitClass, unit)
    entry.guid = unitCall(UnitGUID, unit)
    entry.pvp = unitCall(UnitIsPVP, unit)
    entry.dead = unitCall(UnitIsDead, unit)
    table.insert(DB.enemySightings, entry)
end

local frame = CreateFrame("Frame")

local function snapshotApis()
    local apis = {}
    for _, name in ipairs(API_NAMES) do
        local v = lookup(name)
        apis[name] = (type(v) == "string" or type(v) == "number") and safe(v) or type(v)
    end
    DB.apis = apis
end

local function call(label, fn, ...)
    if type(fn) ~= "function" then DB.calls[label] = "absent"; return end
    local res = { pcall(fn, ...) }
    if res[1] then
        table.remove(res, 1)
        DB.calls[label] = packSafe(unpack(res))
    else
        DB.calls[label] = "ERROR: " .. safe(res[2])
    end
end

local function snapshotState()
    DB.calls = {}
    call("GetBuildInfo", GetBuildInfo)
    call("UnitGUID(player)", UnitGUID, "player")
    call("UnitFullName(player)", UnitFullName, "player")
    call("UnitClass(player)", UnitClass, "player")
    call("UnitLevel(player)", UnitLevel, "player")
    call("GetServerTime", GetServerTime)
    call("IsInGuild", IsInGuild)
    call("GetGuildInfo(player)", GetGuildInfo, "player")
    call("GetSpecialization", GetSpecialization)
    if type(GetSpecialization) == "function" then
        local ok, idx = pcall(GetSpecialization)
        if ok and idx then call("GetSpecializationInfo(current)", GetSpecializationInfo, idx) end
    end
    call("UnitGroupRolesAssigned(player)", UnitGroupRolesAssigned, "player")
    call("GetNumSkillLines", GetNumSkillLines)
    call("GetProfessions", GetProfessions)
    call("GetInstanceInfo", GetInstanceInfo)
    call("C_Map.GetBestMapForUnit(player)", lookup("C_Map.GetBestMapForUnit"), "player")
    call("GetTotalAchievementPoints", GetTotalAchievementPoints)
    call("C_ChatInfo.InChatMessagingLockdown", lookup("C_ChatInfo.InChatMessagingLockdown"))
    call("GetCVar(Sound_SFXVolume)", GetCVar, "Sound_SFXVolume")
    call("GetCVar(Sound_AmbienceVolume)", GetCVar, "Sound_AmbienceVolume")
    call("GetCVar(Sound_EnableAmbience)", GetCVar, "Sound_EnableAmbience")
end

local function registerEvents()
    DB.events = DB.events or {}
    for _, ev in ipairs(EVENTS) do
        local ok, err = pcall(frame.RegisterEvent, frame, ev)
        DB.events[ev] = ok and "ok" or ("REFUSED: " .. safe(err))
    end
    for _, ev in ipairs(TEST_ONLY_EVENTS) do
        local ok, err = pcall(frame.RegisterEvent, frame, ev)
        DB.events[ev] = ok and "ok (test only, unregistered)" or ("REFUSED: " .. safe(err))
        if ok then pcall(frame.UnregisterEvent, frame, ev) end
    end
end

local function registerPrefix()
    local fn = lookup("C_ChatInfo.RegisterAddonMessagePrefix") or RegisterAddonMessagePrefix
    call("RegisterAddonMessagePrefix", fn, PREFIX)
end

local function sendAddon(text, chatType, target)
    local fn = lookup("C_ChatInfo.SendAddonMessage") or SendAddonMessage
    if type(fn) ~= "function" then return "absent" end
    local res = { pcall(fn, PREFIX, text, chatType, target) }
    local ok = table.remove(res, 1)
    return ok and packSafe(unpack(res)) or ("ERROR: " .. safe(res[1]))
end

local function commTest()
    local me = UnitName("player")
    local results = {}
    local stamp = tostring(GetServerTime and GetServerTime() or time())
    results.WHISPER_self = sendAddon("ping:" .. stamp, "WHISPER", me)
    if IsInGuild and IsInGuild() then results.GUILD = sendAddon("ping:" .. stamp, "GUILD") end
    if IsInRaid and IsInRaid() then
        results.RAID = sendAddon("ping:" .. stamp, "RAID")
    elseif IsInGroup and IsInGroup() then
        results.PARTY = sendAddon("ping:" .. stamp, "PARTY")
    end
    results.len255 = sendAddon(string.rep("x", 255), "WHISPER", me)
    results.len256 = sendAddon(string.rep("y", 256), "WHISPER", me)
    log("COMM_SEND", results)
    print("|cff88ccffChronicleProbe|r envoi :")
    for k, v in pairs(results) do
        print("  " .. k .. " -> " .. (type(v) == "table" and table.concat(v, ", ") or safe(v)))
    end
    print("  (les receptions apparaissent comme CHAT_MSG_ADDON ; demande a un guildeu d'avoir la sonde aussi)")
end

local function burstTest()
    local me = UnitName("player")
    DB.burst = { sent = {}, received = 0, startedAt = GetTime() }
    for i = 1, 30 do
        DB.burst.sent[i] = sendAddon("burst:" .. i, "WHISPER", me)
    end
    C_Timer.After(10, function()
        print("|cff88ccffChronicleProbe|r burst : 30 envoyes, " .. DB.burst.received .. " recus en 10 s")
        log("BURST_RESULT", { received = DB.burst.received })
    end)
end

local function soundTest()
    local path = "Interface\\AddOns\\Renatus\\Voice\\Sounds\\cest_bien.ogg"
    local res = { pcall(PlaySoundFile, path, "Ambience") }
    local ok = table.remove(res, 1)
    local out = ok and packSafe(unpack(res)) or { "ERROR: " .. safe(res[1]) }
    log("SOUND_TEST", out)
    print("|cff88ccffChronicleProbe|r PlaySoundFile(Ambience) -> " .. table.concat(out, ", "))
end

local function summary()
    local refused, okCount = {}, 0
    for ev, st in pairs(DB.events or {}) do
        if string.sub(st, 1, 2) == "ok" then okCount = okCount + 1 else table.insert(refused, ev) end
    end
    local build = DB.calls and DB.calls.GetBuildInfo
    print("|cff88ccffChronicleProbe|r build : " .. (type(build) == "table" and table.concat(build, " | ") or safe(build)))
    print("  evenements acceptes : " .. okCount .. ", refuses : " .. (#refused > 0 and table.concat(refused, ", ") or "aucun"))
    local missing = {}
    for name, t in pairs(DB.apis or {}) do if t == "nil" then table.insert(missing, name) end end
    table.sort(missing)
    print("  API absentes : " .. (#missing > 0 and table.concat(missing, ", ") or "aucune"))
    print("  evenements journalises : " .. #DB.log .. ", joueurs ennemis observes : " .. #(DB.enemySightings or {}))
    print("  (detail dans SavedVariables apres /reload)")
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "ChronicleProbe" then
            ChronicleProbeDB = ChronicleProbeDB or {}
            DB = ChronicleProbeDB
            DB.log = DB.log or {}
            DB.counts = DB.counts or {}
            registerEvents()
            registerPrefix()
            self:UnregisterEvent("ADDON_LOADED")
        end
        return
    end
    if not DB then return end

    if event == "PLAYER_LOGIN" then
        snapshotApis()
        snapshotState()
    end

    if event == "CHAT_MSG_ADDON" or event == "CHAT_MSG_ADDON_LOGGED" then
        local prefix = ...
        if isSecret(prefix) then
            log(event, { "<secret prefix>" })
            return
        end
        if prefix ~= PREFIX then return end
        local text = select(2, ...)
        if DB.burst and not isSecret(text) and string.sub(text, 1, 6) == "burst:" then
            DB.burst.received = DB.burst.received + 1
            return
        end
        log(event, packSafe(...))
        print("|cff88ccffChronicleProbe|r recu : " .. table.concat(packSafe(...), " | "))
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then logEnemySighting(event, "target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then logEnemySighting(event, "mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then logEnemySighting(event, (...)) end

    local limit = NOISY[event] or MAX_PER_EVENT
    DB.counts[event] = (DB.counts[event] or 0) + 1
    if DB.counts[event] <= limit then
        log(event, packSafe(...))
    end
    if event == "PLAYER_DEAD" or event == "ENCOUNTER_END" or event == "BOSS_KILL" or event == "PLAYER_LEVEL_UP" then
        snapshotState() -- capture le contexte (instance, carte) au moment de l'evenement
        log(event .. "_STATE", DB.calls)
    end
end)
frame:RegisterEvent("ADDON_LOADED")

SLASH_CHRONICLEPROBE1 = "/gcprobe"
SlashCmdList.CHRONICLEPROBE = function(msg)
    msg = string.lower(msg or "")
    if msg == "comm" then commTest()
    elseif msg == "burst" then burstTest()
    elseif msg == "sound" then soundTest()
    elseif msg == "reset" then
        ChronicleProbeDB = { log = {}, counts = {} }
        DB = ChronicleProbeDB
        registerEvents()
        snapshotApis()
        snapshotState()
        print("|cff88ccffChronicleProbe|r donnees effacees")
    else summary() end
end
