-- Collectors/Creatures.lua: npc ids of the creatures around the player, so that the album's
-- cards of a boss or of a killer show the creature's 3D model (admin/core/src/cards.rs).
-- Only what the game shows anyway: the GUID of a creature targeted, hovered or on a
-- nameplate, and of the encounter's bosses (boss1..boss5). Secret values (instances on
-- Midnight-based clients) are ignored. Kept for the session only: nothing is stored here,
-- the ids travel inside the BOSS_KILL and DEATH events.
local _, ns = ...

local Creatures = ns:RegisterModule("CollectorCreatures", {})
ns.Creatures = Creatures
local try = ns.Try

Creatures.MAX = 200   -- names remembered (the most recent ones)

-- npc id of a creature GUID ("Creature-0-<server>-<instance>-<zone>-<npc>-<spawn>"), nil for
-- anything else (players, pets, objects, secret values).
function ns.NpcId(guid)
    guid = ns.Safe(guid)
    if type(guid) ~= "string" then return nil end
    local kind, npc = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(npc)
end

local byName, byNpc, order = {}, {}, {}
local bosses = {}   -- bosses of the current encounter: { { name = ..., npc = ... } }

-- info: { npc, name, cls (UnitClassification: normal, elite, rare, rareelite, worldboss), lvl }
local function remember(info)
    if not byName[info.name] then
        order[#order + 1] = info.name
        if #order > Creatures.MAX then
            local evicted = table.remove(order, 1)
            local old = byName[evicted]
            byName[evicted] = nil
            if old and byNpc[old.npc] == old then byNpc[old.npc] = nil end
        end
    end
    byName[info.name], byNpc[info.npc] = info, info
end

-- Records the creature shown by a unit token; returns its npc id.
function Creatures.Observe(unit)
    if not unit or not try(UnitExists, unit) or try(UnitIsPlayer, unit) then return nil end
    local npc = ns.NpcId(try(UnitGUID, unit))
    local name = try(UnitName, unit)
    if not npc or type(name) ~= "string" or name == "" then return nil end
    local lvl = try(UnitLevel, unit)
    remember({ npc = npc, name = name, cls = try(UnitClassification, unit),
        lvl = (type(lvl) == "number" and lvl > 0) and lvl or nil })
    return npc
end

-- npc id of a creature of that name seen this session.
function Creatures.Lookup(name)
    local info = type(name) == "string" and byName[name]
    return info and info.npc or nil
end

-- What is known of a creature seen this session, by name or by npc id (nil if unseen).
function Creatures.Info(name) return type(name) == "string" and byName[name] or nil end
function Creatures.ByNpc(npc) return npc and byNpc[npc] or nil end

local function scanBosses()
    for i = 1, 5 do
        local unit = "boss" .. i
        local npc = Creatures.Observe(unit)
        if npc then
            local known = false
            for _, b in ipairs(bosses) do if b.npc == npc then known = true end end
            if not known then bosses[#bosses + 1] = { name = try(UnitName, unit), npc = npc } end
        end
    end
end

-- npc id of the boss of the encounter that just ended: the boss unit named like the
-- encounter, else the first boss unit, else a creature of that name seen around.
function Creatures.BossNpc(encounterName)
    scanBosses()
    for _, b in ipairs(bosses) do
        if b.name == encounterName then return b.npc end
    end
    return (bosses[1] and bosses[1].npc) or Creatures.Lookup(encounterName)
end

function Creatures.EndEncounter() bosses = {} end

function Creatures:OnLogin()
    ns:RegisterGameEvent("PLAYER_TARGET_CHANGED", function() Creatures.Observe("target") end)
    ns:RegisterGameEvent("UPDATE_MOUSEOVER_UNIT", function() Creatures.Observe("mouseover") end)
    ns:RegisterGameEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Creatures.Observe(ns.Safe(unit)) end)
    ns:RegisterGameEvent("ENCOUNTER_START", function() bosses = {}; scanBosses() end)
    ns:RegisterGameEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT", scanBosses)
end
