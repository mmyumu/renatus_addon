-- Collectors/Feats.lua: small feats and mishaps for the gazette, one event each.
--   DUEL          a duel this character won or lost (or fled): p.winner, p.loser, p.fled
--   NEAR_DEATH    a fight survived with almost no health left: p.pct (lowest %), p.lvl
--   RESCUED       brought back to life by someone: p.by
--   ROLL_EXTREME  a 1 or a 100 on a roll (/roll 1-100, need or greed): p.roll, p.kind, p.item
--   REPUTATION    honored, revered or exalted with a faction: p.faction, p.standing
--   MONEY         first time this character owns 10, 100, 1000 gold: p.gold
--   MOUNT         a new mount (retail clients' mount journal): p.name
--   HEARTH_BIND   hearthstone bound to a new place: p.place, p.from
-- Sources are the game's own system messages, matched with the client's strings (any
-- language). WoW Forever hands addons secret values in instances: they are ignored, so
-- most of this only works in the open world. To be confirmed in game (docs/ARCHITECTURE.md §12).
local _, ns = ...

local Feats = ns:RegisterModule("CollectorFeats", {})
ns.Feats = Feats
local try = ns.Try

Feats.NEAR_DEATH = 0.05     -- at or below this share of health, a survived fight counts
Feats.RESCUE_WINDOW = 120   -- seconds between the offer and coming back to life
Feats.GOLD_MARKS = { 10, 100, 1000 }

-- Lua pattern of a client format string, capturing every argument in the order of the
-- arguments ("%s", "%d", and positional "%2$s"). Returns the pattern and, for each
-- capture, the argument it is.
function Feats.Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local order, parts, nextArg, i = {}, {}, 1, 1
    local function literal(text) return (text:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")) end
    while i <= #fmt do
        local s, e, pos, kind = fmt:find("%%(%d*)%$?([sd])", i)
        if not s then
            parts[#parts + 1] = literal(fmt:sub(i))
            break
        end
        parts[#parts + 1] = literal(fmt:sub(i, s - 1))
        order[#order + 1] = tonumber(pos) or nextArg
        nextArg = nextArg + 1
        parts[#parts + 1] = kind == "d" and "(%d+)" or "(.+)"
        i = e + 1
    end
    return "^" .. table.concat(parts) .. "$", order
end

-- Arguments of a client message (by argument number), or nil if it is not that message.
function Feats.Match(fmt, msg)
    local p, order = Feats.Pattern(fmt)
    if not p or type(msg) ~= "string" then return nil end
    local caps = { msg:match(p) }
    if #caps == 0 then return nil end
    local args = {}
    for i, index in ipairs(order) do args[index] = caps[i] end
    return args
end

local function myName() return try(UnitName, "player") end
local function strip(name) return type(name) == "string" and (name:gsub("%-.*$", "")) or name end
local function minuteKey() return date("%Y%m%d%H%M", (GetServerTime and GetServerTime()) or time()) end

------------------------------------------------------------------------
-- Duels
------------------------------------------------------------------------
function Feats.OnDuel(msg)
    local me = myName()
    for _, case in ipairs({ { "DUEL_WINNER_KNOCKOUT", false }, { "DUEL_WINNER_RETREAT", true } }) do
        local args = Feats.Match(_G[case[1]], msg)
        if args then
            -- knockout: "%1$s has defeated %2$s"; retreat: "%2$s has fled from %1$s"
            local winner, loser = strip(args[1]), strip(args[2])
            if winner ~= me and loser ~= me then return nil end
            return ns.Store.Add("DUEL", { winner = winner, loser = loser, fled = case[2] or nil },
                { occ = "DUEL:" .. tostring(winner) .. ":" .. tostring(loser) .. ":" .. minuteKey() })
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Rolls: /roll 1-100, and need or greed on an item
------------------------------------------------------------------------
local function extreme(roll) return roll == 1 or roll == 100 end

function Feats.OnRoll(msg)
    local args = Feats.Match(_G.RANDOM_ROLL_RESULT, msg)  -- "%s rolls %d (%d-%d)"
    if not args then return nil end
    local roll, low, high = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if strip(args[1]) ~= myName() or low ~= 1 or high ~= 100 or not extreme(roll) then return nil end
    return ns.Store.Add("ROLL_EXTREME", { roll = roll, kind = "roll" })
end

function Feats.OnLootRoll(msg)
    for _, case in ipairs({ { "LOOT_ROLL_ROLLED_NEED", "need" }, { "LOOT_ROLL_ROLLED_GREED", "greed" } }) do
        local args = Feats.Match(_G[case[1]], msg)  -- "Need Roll - %d for %s by %s"
        if args then
            local roll = tonumber(args[1])
            if strip(args[3]) ~= myName() or not extreme(roll) then return nil end
            local item = type(args[2]) == "string" and (args[2]:match("%[(.-)%]") or args[2]) or nil
            return ns.Store.Add("ROLL_EXTREME", { roll = roll, kind = case[2], item = item })
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Reputation: "You are now %s with %s." for honored and better
------------------------------------------------------------------------
local function goodStanding(label)
    for i = 6, 8 do
        if label == _G["FACTION_STANDING_LABEL" .. i] or label == _G["FACTION_STANDING_LABEL" .. i .. "_FEMALE"] then
            return true
        end
    end
    return false
end

function Feats.OnStanding(msg)
    local args = Feats.Match(_G.FACTION_STANDING_CHANGED, msg)
    if not args or not goodStanding(args[1]) then return nil end
    return ns.Store.Add("REPUTATION", { standing = args[1], faction = args[2] })
end

------------------------------------------------------------------------
-- Hearthstone bind place (checked at login and on system messages)
------------------------------------------------------------------------
function Feats.CheckBind()
    local place = ns.Safe(try(GetBindLocation))
    if type(place) ~= "string" or place == "" then return nil end
    local before = ns.char.bindPlace
    ns.char.bindPlace = place
    if not before or before == place then return nil end
    return ns.Store.Add("HEARTH_BIND", { place = place, from = before })
end

function Feats.OnSystem(_, msg)
    msg = ns.Safe(msg)
    if type(msg) ~= "string" then return end
    if not (Feats.OnDuel(msg) or Feats.OnRoll(msg) or Feats.OnStanding(msg)) then Feats.CheckBind() end
end

------------------------------------------------------------------------
-- Money marks (the gold already owned at the first check is not news)
------------------------------------------------------------------------
function Feats.CheckMoney()
    local copper = ns.Safe(try(GetMoney))
    if type(copper) ~= "number" then return nil end
    local gold = math.floor(copper / 10000)
    local marks = ns.char.goldMarks
    local first = marks == nil
    marks = marks or {}
    ns.char.goldMarks = marks
    local ev
    for _, mark in ipairs(Feats.GOLD_MARKS) do
        if gold >= mark and not marks[mark] then
            marks[mark] = true
            if not first then ev = ns.Store.Add("MONEY", { gold = mark }) or ev end
        end
    end
    return ev
end

------------------------------------------------------------------------
-- Near death: the lowest health of a fight, if the character comes out alive
------------------------------------------------------------------------
local fight -- { low = share of health } during a fight

local function healthShare()
    local hp, max = ns.Safe(try(UnitHealth, "player")), ns.Safe(try(UnitHealthMax, "player"))
    if type(hp) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
    return hp / max
end

function Feats.OnHealth(unit)
    if unit ~= "player" or not fight then return end
    local share = healthShare()
    if share and share > 0 and share < fight.low then fight.low = share end
end

function Feats.OnFightEnd()
    local f = fight
    fight = nil
    if not f or f.low > Feats.NEAR_DEATH or try(UnitIsDeadOrGhost, "player") then return nil end
    return ns.Store.Add("NEAR_DEATH", { pct = math.floor(f.low * 1000 + 0.5) / 10, lvl = try(UnitLevel, "player") })
end

------------------------------------------------------------------------
-- Rescue: a resurrection offer, then the character alive again
------------------------------------------------------------------------
local offer -- { by, at }

function Feats.OnOffer(_, by)
    by = strip(ns.Safe(by))
    if type(by) == "string" and by ~= "" then offer = { by = by, at = GetTime() } end
end

function Feats.OnAlive()
    local o = offer
    if not o or GetTime() - o.at > Feats.RESCUE_WINDOW or try(UnitIsDeadOrGhost, "player") then return nil end
    offer = nil
    return ns.Store.Add("RESCUED", { by = o.by })
end

------------------------------------------------------------------------
-- Mounts (retail mount journal; may never fire on Forever)
------------------------------------------------------------------------
function Feats.OnMount(_, id)
    id = ns.Safe(id)
    local name = C_MountJournal and try(C_MountJournal.GetMountInfoByID, id)
    if type(name) ~= "string" or name == "" then return nil end
    return ns.Store.Add("MOUNT", { name = name, id = id })
end

function Feats:OnLogin()
    ns:RegisterGameEvent("CHAT_MSG_SYSTEM", Feats.OnSystem)
    ns:RegisterGameEvent("CHAT_MSG_LOOT", function(_, msg) Feats.OnLootRoll(ns.Safe(msg)) end)
    ns:RegisterGameEvent("PLAYER_REGEN_DISABLED", function() fight = { low = healthShare() or 1 } end)
    ns:RegisterGameEvent("PLAYER_REGEN_ENABLED", Feats.OnFightEnd)
    ns:RegisterGameEvent("PLAYER_DEAD", function() fight = nil end)
    ns:RegisterGameEvent("UNIT_HEALTH", function(_, unit) Feats.OnHealth(unit) end)
    ns:RegisterGameEvent("RESURRECT_REQUEST", Feats.OnOffer)
    -- the state may not be updated yet when these fire
    local function alive() if C_Timer then C_Timer.After(1, Feats.OnAlive) else Feats.OnAlive() end end
    ns:RegisterGameEvent("PLAYER_ALIVE", alive)
    ns:RegisterGameEvent("PLAYER_UNGHOST", alive)
    ns:RegisterGameEvent("PLAYER_MONEY", Feats.CheckMoney)
    ns:RegisterGameEvent("NEW_MOUNT_ADDED", Feats.OnMount)
    ns:RegisterGameEvent("PLAYER_ENTERING_WORLD", function() Feats.CheckBind(); Feats.CheckMoney() end)
    Feats.CheckBind()
    Feats.CheckMoney()
end
