-- Collectors/Expedition.lua: expedition detector (local state machine, docs §5).
--
-- Start: entering a group instance (DUNGEON / RAID), a battleground or
--        an arena (PVP), or grouping with at least one guild member outside instances (QUESTING).
-- End:   leaving the instance without coming back within 10 min; group disbanded;
--        20 min without events (QUESTING); logout -> estimated end at next login.
-- An EXPEDITION event is written at the end. Events produced meanwhile carry x = key.
-- Listed members are those actually seen in the group (never invented), guild only.
local _, ns = ...

local Exp = ns:RegisterModule("Expedition", {})
ns.Expedition = Exp
local try = ns.Try

Exp.REENTRY = 600        -- instance exit tolerance (s)
Exp.IDLE = 1200          -- idle timeout of a QUESTING expedition (s)
Exp.MIN_DURATION = 120   -- below this, with nothing notable, the expedition is dropped

local guildNames = {}
local idle = false       -- QUESTING closed for inactivity: no restart without new activity

local function now() return (GetServerTime and GetServerTime()) or time() end
local function state() return ns.char.expedition end

-- Guild members by name, first name (WoW Forever: "Dakey Dak" in the roster, "Dakey"
-- in the group) and GUID.
local function refreshGuildNames()
    local names = {}
    for _, r in ipairs(ns.Store.Roster()) do
        names[r.name] = true
        if r.first then names[r.first] = true end
        if r.guid then names[r.guid] = true end
    end
    if next(names) then guildNames = names end
end

local function groupInfo()
    local all = ns.Context.Participants() or {}
    local guild, others = {}, 0
    for _, p in ipairs(all) do
        local short = p.n:gsub("%-.*$", "")
        if guildNames[short] or guildNames[p.g] then table.insert(guild, { g = p.g, n = short }) else others = others + 1 end
    end
    return guild, others, #all
end

local function leaderGuid()
    if try(UnitIsGroupLeader, "player") then return (ns.Context.Me()) end
    local prefix = try(IsInRaid) and "raid" or "party"
    local count = try(GetNumGroupMembers) or 0
    for i = 1, math.min(count, 40) do
        local unit = prefix .. i
        if try(UnitIsGroupLeader, unit) then return try(UnitGUID, unit) end
    end
    return nil
end

-- What the current situation calls for: { kind, iid, iname } or nil.
local function desired()
    local inInstance, itype = try(IsInInstance)
    if inInstance then
        local name, _, _, _, _, _, _, instanceID = try(GetInstanceInfo)
        if itype == "party" or itype == "scenario" then return { kind = "DUNGEON", iid = instanceID, iname = name } end
        if itype == "raid" then return { kind = "RAID", iid = instanceID, iname = name } end
        if itype == "pvp" or itype == "arena" then return { kind = "PVP", iid = instanceID, iname = name } end
        return nil
    end
    local guild = groupInfo()
    if #guild > 0 then return { kind = "QUESTING" } end
    return nil
end

function Exp:CurrentKey()
    local st = ns.char and ns.char.expedition
    return st and st.key or nil
end

local function mergeMembers(st)
    local guild, others = groupInfo()
    st.members = st.members or {}
    for _, m in ipairs(guild) do st.members[m.g] = m.n end
    if others > (st.others or 0) then st.others = others end
end

local function start(d)
    idle = false
    ns.char.expSeq = (ns.char.expSeq or 0) + 1
    local me = ns.Context.Me()
    local t = now()
    local st = {
        key = me .. ":x" .. ns.char.expSeq, kind = d.kind, start = t, last = t,
        iid = d.iid, iname = d.iname, leader = leaderGuid() or me,
        loc = ns.Context.Location(), counts = {}, bosses = {}, members = {}, others = 0,
    }
    mergeMembers(st)
    ns.char.expedition = st
    ns.EventBus.Publish("EXPEDITION_STATE", st)
    return st
end

local function hasActivity(st)
    for _, n in pairs(st.counts) do if n > 0 then return true end end
    return false
end

-- Close: writes the EXPEDITION event (unless a quick pass with nothing notable).
local function close(finish, estimated)
    local st = state()
    if not st then return nil end
    ns.char.expedition = nil -- before Store.Add: the expedition must not reference itself
    ns.EventBus.Publish("EXPEDITION_STATE", nil)
    finish = math.max(finish or st.last, st.start)
    local duration = finish - st.start
    if duration < Exp.MIN_DURATION and not hasActivity(st) then return nil end
    local pt, names = {}, {}
    for guid, name in pairs(st.members) do table.insert(pt, { g = guid, n = name }); table.insert(names, name) end
    table.sort(pt, function(a, b) return a.n < b.n end)
    local c = st.counts
    local ev = ns.Store.Add("EXPEDITION", {
        key = st.key, type = st.kind, start = st.start, finish = finish, duration = duration,
        inst = st.iname, iid = st.iid, others = st.others > 0 and st.others or nil,
        bosses = c.bosses, deaths = c.deaths, quests = c.quests, zones = c.zones, levels = c.levels,
        bossNames = #st.bosses > 0 and st.bosses or nil,
    }, {
        t = st.start, loc = st.loc, pt = #pt > 0 and pt or nil,
        occ = "EXP:" .. tostring(st.iid or st.kind) .. ":" .. tostring(st.leader) .. ":" .. date("%Y%m%d", st.start),
        ded = estimated and { "finish" } or nil,
    })
    return ev
end
Exp.Close = close

function Exp:Evaluate()
    local st, d, t = state(), desired(), now()
    if st then
        if st.kind ~= "QUESTING" then
            if d and d.kind == st.kind and d.iid == st.iid then
                st.leftAt = nil
                mergeMembers(st)
                return
            end
            if d and d.kind ~= "QUESTING" then close(t); start(d); return end
            -- outside the instance: tolerate a return (repair, death, res...)
            st.leftAt = st.leftAt or t
            if t - st.leftAt >= Exp.REENTRY then close(st.leftAt) end
            return
        end
        -- QUESTING
        if d and d.kind ~= "QUESTING" then close(t); start(d); return end
        if not d then close(t); return end
        mergeMembers(st)
        if t - st.last >= Exp.IDLE then close(st.last); idle = true end
        return
    end
    if d and not (d.kind == "QUESTING" and idle) then start(d) end
    if not d then idle = false end
end

local SIGNIFICANT = { DEATH = "deaths", BOSS_KILL = "bosses", QUEST_DONE = "quests",
    ZONE_FIRST_VISIT = "zones", LEVEL_UP = "levels" }

local function onChronicleEvent(ev)
    if ev.rx or ev.k == "EXPEDITION" then return end
    local me = ns.Context.Me()
    if ev.a ~= me then return end
    local st = state()
    if not st then
        -- resuming after inactivity: new group activity restarts an expedition
        if idle then idle = false; Exp:Evaluate() end
        return
    end
    if ev.x ~= st.key then return end
    st.last = now()
    local counter = SIGNIFICANT[ev.k]
    -- Privacy: if expeditions are shared, they only count shared events.
    local shareExp = (ns.char.privacy.social == "G")
    if counter and (ev.vis == "G" or not shareExp) then
        st.counts[counter] = (st.counts[counter] or 0) + 1
        if ev.k == "BOSS_KILL" and ev.p.name and #st.bosses < 10 then table.insert(st.bosses, ev.p.name) end
    end
end

function Exp:OnLogin()
    refreshGuildNames()
    local st = state()
    -- Previous session interrupted (logout, crash): estimated end if we are no longer there.
    if st then
        local d = desired()
        local same = d and d.kind == st.kind and (st.kind == "QUESTING" or d.iid == st.iid)
        if not same and now() - (st.leftAt or st.last) > 300 then close(st.leftAt or st.last, true) end
    end
    local evaluate = function() Exp:Evaluate() end
    ns:RegisterGameEvent("PLAYER_ENTERING_WORLD", evaluate)
    ns:RegisterGameEvent("ZONE_CHANGED_NEW_AREA", evaluate)
    ns:RegisterGameEvent("GROUP_ROSTER_UPDATE", evaluate)
    ns:RegisterGameEvent("GUILD_ROSTER_UPDATE", refreshGuildNames)
    ns:RegisterGameEvent("PLAYER_LOGOUT", function()
        -- keep the state: the (estimated) close happens at next login
        local s = state()
        if s then s.last = math.max(s.last, now() - 1) end
    end)
    ns.EventBus.Subscribe("CHRONICLE_EVENT", onChronicleEvent)
    if C_Timer then
        local function tick() Exp:Evaluate(); C_Timer.After(30, tick) end
        C_Timer.After(3, tick)
    end
end

-- For the UI: current expedition (read-only).
function Exp:Current() return state() end
