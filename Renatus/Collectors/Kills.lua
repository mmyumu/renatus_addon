-- Collectors/Kills.lua: the first time this character kills a kind of creature, a MOB_KILL
-- event (npc id, name, kind, level), for the guild's bestiary in the album: one card per
-- creature, with its 3D model (admin/core/src/cards.rs).
-- WoW Forever closes the combat log to addons, so a kill is seen through:
--   - the experience message ("<name> meurt, vous gagnez N points d'expérience", matched
--     with the client's COMBATLOG_XPGAIN_FIRSTPERSON, any language), the creature then
--     found by name among those seen around (Collectors/Creatures.lua);
--   - the corpse being looted (GetLootSourceInfo gives its GUID), which also covers the
--     highest level, where kills give no experience.
-- Secret values are ignored; never displayed in the journal.
local _, ns = ...

local Kills = ns:RegisterModule("CollectorKills", {})
ns.Kills = Kills
local try = ns.Try

-- Pattern of the experience message: the name, up to the first number.
function Kills.Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local head = fmt:match("^(.-)%%d")
    if not head or not head:find("%%s") then return nil end
    local p = head:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    p = p:gsub("%%%%s", "(.+)", 1)
    return "^" .. p
end

-- Records a creature killed for the first time by this character; returns the event.
function Kills.Record(info)
    if not info or not info.npc or type(info.name) ~= "string" or info.name == "" then return nil end
    local seen = ns.char.mobsKilled
    if seen[info.npc] then return nil end
    seen[info.npc] = true
    return ns.Store.Add("MOB_KILL", { npc = info.npc, name = info.name, cls = info.cls, lvl = info.lvl })
end

function Kills.OnExperience(msg)
    msg = ns.Safe(msg)
    if type(msg) ~= "string" then return nil end
    Kills.pattern = Kills.pattern or Kills.Pattern(_G.COMBATLOG_XPGAIN_FIRSTPERSON)
    local name = Kills.pattern and msg:match(Kills.pattern)
    if not name then return nil end
    return Kills.Record(ns.Creatures and ns.Creatures.Info(name))
end

function Kills.OnLoot()
    if not (GetNumLootItems and GetLootSourceInfo) then return end
    for slot = 1, try(GetNumLootItems) or 0 do
        local sources = { try(GetLootSourceInfo, slot) }
        for i = 1, #sources, 2 do
            local npc = ns.NpcId(sources[i])
            if npc then Kills.Record(ns.Creatures and ns.Creatures.ByNpc(npc)) end
        end
    end
end

function Kills:OnLogin()
    ns:RegisterGameEvent("CHAT_MSG_COMBAT_XP_GAIN", function(_, msg) Kills.OnExperience(msg) end)
    ns:RegisterGameEvent("LOOT_OPENED", Kills.OnLoot)
end
