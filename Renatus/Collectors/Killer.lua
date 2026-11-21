-- Collectors/Killer.lua: who (or what) killed the player.
--
-- Two sources, both optional and tried in this order:
--   1. the combat log (COMBAT_LOG_EVENT_UNFILTERED): the last damage taken in the
--      previous 10 seconds is kept in memory (never saved), the fatal one names the killer.
--      Only on clients that still open it to addons (not Midnight-based ones like Forever);
--   2. the game's death recap (C_DeathRecap), which the default UI shows after a death.
-- Secret values are ignored: when nothing readable is left, the death is recorded
-- without a killer.
local _, ns = ...

local Killer = ns:RegisterModule("CollectorKiller", {})
ns.Killer = Killer
local try = ns.Try
local Safe = ns.Safe

Killer.WINDOW = 10   -- seconds of damage history kept
Killer.MAX_HITS = 12

local hits = {}      -- most recent last: { t, guid, name, flags, spell, amount, overkill, env }
local myGuid

local SWING = { SWING_DAMAGE = true }
local SPELL = { SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true, RANGE_DAMAGE = true, SPELL_BUILDING_DAMAGE = true }
local ENV = {
    Falling = "une chute", Drowning = "la noyade", Fatigue = "l'épuisement",
    Fire = "le feu", Lava = "la lave", Slime = "la vase",
}

local function isPlayerGuid(guid) return type(guid) == "string" and guid:find("^Player%-") ~= nil end

-- Describes a source: name, and for a player class, race, realm.
local function describe(guid, name, spell, amount, overkill, env, src)
    if env then
        return { env = env, n = ENV[env] or string.lower(tostring(env)), dmg = amount, src = src }
    end
    if not name or name == "" then return nil end
    local k = { n = name, sp = spell, dmg = amount, src = src }
    if overkill and overkill > 0 then k.ok = overkill end
    if isPlayerGuid(guid) then
        k.pl = true
        local cl, c, ra, _, _, pname, realm = try(GetPlayerInfoByGUID, guid)
        k.cl, k.c, k.ra = cl, c, ra
        if pname and pname ~= "" then k.n = pname end
        if realm and realm ~= "" then k.r = realm end
    else
        -- a creature: its npc id (3D model on its album card) and kind (elite, rare...), from
        -- Collectors/Creatures.lua
        local info = ns.Creatures and ns.Creatures.Info(name)
        k.npc = ns.NpcId(guid) or (info and info.npc) or nil
        k.cls = info and info.cls or nil
    end
    return k
end

-- Combat log: damage taken by the player.
local function onCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    local _, sub, _, sguid, sname, sflags, _, dguid, _, _, _, a12, a13, a14, a15, a16 = CombatLogGetCurrentEventInfo()
    dguid = Safe(dguid)
    if not dguid or dguid ~= myGuid then return end
    sub = Safe(sub)
    local spell, amount, overkill, env
    if SWING[sub] then
        spell, amount, overkill = "Attaque en mêlée", a12, a13
    elseif SPELL[sub] then
        spell, amount, overkill = a13, a15, a16
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        env, amount, overkill = a12, a13, a14
    else
        return
    end
    table.insert(hits, {
        t = GetTime(), guid = Safe(sguid), name = Safe(sname), spell = Safe(spell),
        amount = Safe(amount), overkill = Safe(overkill), env = Safe(env),
    })
    if #hits > Killer.MAX_HITS then table.remove(hits, 1) end
end

local function fromLog()
    local now, fatal, last = GetTime(), nil, nil
    for i = #hits, 1, -1 do
        local h = hits[i]
        if now - h.t > Killer.WINDOW then break end
        last = last or h
        if not fatal and h.overkill and h.overkill > 0 then fatal = h end
    end
    local h = fatal or last
    if not h then return nil end
    return describe(h.guid, h.name, h.spell, h.amount, h.overkill, h.env, "log")
end

-- Death recap: the event with the latest timestamp is the fatal one.
local function fromRecap()
    local api = C_DeathRecap
    if not (api and api.GetRecapEvents) then return nil end
    local ok, events = pcall(api.GetRecapEvents)
    if not ok or type(events) ~= "table" then return nil end
    local best, bestT
    for _, e in ipairs(events) do
        if type(e) == "table" then
            local t = Safe(e.timestamp) or 0
            if not bestT or t > bestT then best, bestT = e, t end
        end
    end
    if not best then return nil end
    local spell = Safe(best.spellName)
    if not spell and Safe(best.event) == "SWING_DAMAGE" then spell = "Attaque en mêlée" end
    return describe(Safe(best.sourceGUID), Safe(best.sourceName), spell, Safe(best.amount), Safe(best.overkill),
        Safe(best.environmentalType), "recap")
end

-- Midnight-based clients (WoW Forever included) close the combat log to addons.
-- Registering it there is not a Lua error that pcall could catch: the game blocks
-- the call and shows "addon blocked from an action only available to the Blizzard UI".
-- Those clients are the ones with secret values, so that is what we test.
function Killer.CombatLogAllowed()
    return type(issecretvalue) ~= "function"
end

function Killer.Find()
    return fromLog() or fromRecap()
end

-- True if the death recap may still provide something a moment after the death.
function Killer.RecapPending()
    return C_DeathRecap ~= nil and C_DeathRecap.GetRecapEvents ~= nil
end

function Killer.Reset() hits = {} end

function Killer:OnLogin()
    myGuid = try(UnitGUID, "player")
    if Killer.CombatLogAllowed() then
        ns:RegisterGameEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
    else
        -- Listed in Settings > unavailable events.
        ns.unsupportedEvents.COMBAT_LOG_EVENT_UNFILTERED = true
    end
    -- Back to life: the damage history is no longer useful.
    ns:RegisterGameEvent("PLAYER_ALIVE", Killer.Reset)
    ns:RegisterGameEvent("PLAYER_UNGHOST", Killer.Reset)
end
