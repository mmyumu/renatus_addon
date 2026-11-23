-- Collectors/Counters.lua: trivia counted through the day, sent as one COUNTERS event when
-- the day changes (never one event per jump). p.from, p.to, then only the non-zero ones:
--   jumps    jumps (JumpOrAscendStart)
--   drunk    times this character got drunk (DRUNK_MESSAGE_SELF3/4 after being sober)
--   spirit   visits to the spirit healer (CONFIRM_XP_LOSS)
--   bagfull  "inventory full" errors (at most one per 10 s)
--   fish     fish caught (loot window opened by fishing)
--   hearth   hearthstone uses (spell 8690)
--   earned, spent  copper earned and spent
--   emotes   { { e = "SLAP", to = "Name", n = 3 }, ... }: emotes aimed at guild members
-- Hooks and messages missing on WoW Forever are simply never counted.
local _, ns = ...

local Counters = ns:RegisterModule("CollectorCounters", {})
ns.Counters = Counters
local try = ns.Try

Counters.HEARTHSTONE = 8690
Counters.BAGFULL_GAP = 10
-- Emotes worth telling when aimed at a guild member.
Counters.EMOTES = {
    SLAP = true, KISS = true, HUG = true, LOVE = true, CHICKEN = true, RUDE = true, SPIT = true,
    ROFL = true, LAUGH = true, BONK = true, POKE = true, TICKLE = true, CUDDLE = true, FLEX = true,
    DANCE = true, CHEER = true, THANK = true, BOW = true, INSULT = true, FLIRT = true, CRY = true,
    APPLAUD = true, GIGGLE = true, MOON = true, PITY = true, SHOO = true, BITE = true, PRAISE = true,
}

local function now() return (GetServerTime and GetServerTime()) or time() end
local function today() return date("%Y%m%d", now()) end

-- The day's counters, after sending the previous day's.
function Counters.Bag()
    local bag = ns.char.counters
    if type(bag) ~= "table" or bag.day ~= today() then
        if type(bag) == "table" then Counters.Flush(bag) end
        bag = { day = today(), from = now(), n = {}, emotes = {} }
        ns.char.counters = bag
    end
    return bag
end

-- COUNTERS event for a finished day (nothing if nothing was counted).
function Counters.Flush(bag)
    local p, any = { from = bag.from, to = bag.last or bag.from }, false
    for key, n in pairs(bag.n or {}) do
        if n > 0 then p[key] = n; any = true end
    end
    local emotes = {}
    for key, n in pairs(bag.emotes or {}) do
        local e, to = key:match("^([^|]+)|(.+)$")
        if e then emotes[#emotes + 1] = { e = e, to = to, n = n } end
    end
    table.sort(emotes, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.e .. a.to < b.e .. b.to end)
    if #emotes > 0 then
        while #emotes > 10 do table.remove(emotes) end
        p.emotes = emotes
        any = true
    end
    if not any then return nil end
    return ns.Store.Add("COUNTERS", p, { t = p.to, noExp = true, loc = {} })
end

function Counters.Bump(key, n)
    local bag = Counters.Bag()
    bag.n[key] = (bag.n[key] or 0) + (n or 1)
    bag.last = now()
end

------------------------------------------------------------------------
-- Sources
------------------------------------------------------------------------
local soberAgain = true
function Counters.OnSystem(_, msg)
    msg = ns.Safe(msg)
    if type(msg) ~= "string" then return end
    if msg == _G.DRUNK_MESSAGE_SELF1 then soberAgain = true
    elseif (msg == _G.DRUNK_MESSAGE_SELF3 or msg == _G.DRUNK_MESSAGE_SELF4) and soberAgain then
        soberAgain = false
        Counters.Bump("drunk")
    end
end

local lastFull = -math.huge
function Counters.OnError(_, _, msg)
    msg = ns.Safe(msg)
    if msg == nil or msg ~= _G.ERR_INV_FULL then return end
    if GetTime() - lastFull < Counters.BAGFULL_GAP then return end
    lastFull = GetTime()
    Counters.Bump("bagfull")
end

local money
function Counters.OnMoney()
    local m = ns.Safe(try(GetMoney))
    if type(m) ~= "number" then return end
    if money then
        if m > money then Counters.Bump("earned", m - money)
        elseif m < money then Counters.Bump("spent", money - m) end
    end
    money = m
end

-- Guild member's name for an emote's target (a name typed after the emote, else the target).
local function guildTarget(name)
    if type(name) == "string" and name ~= "" then
        name = name:gsub("%-.*$", "")
        local m = ns.Store.FindInRoster(ns.Store.Roster(), nil, name)
        return m and (m.first or m.name) or nil
    end
    if not try(UnitIsPlayer, "target") then return nil end
    local target = ns.Safe(try(UnitName, "target"))
    if type(target) ~= "string" or target == try(UnitName, "player") then return nil end
    if try(UnitIsInMyGuild, "target") then return target end
    local m = ns.Store.FindInRoster(ns.Store.Roster(), ns.Safe(try(UnitGUID, "target")), target)
    return m and target or nil
end

function Counters.OnEmote(token, name)
    token = type(token) == "string" and token:upper() or nil
    if not token or not Counters.EMOTES[token] then return end
    local to = guildTarget(ns.Safe(name))
    if not to then return end
    local bag = Counters.Bag()
    local key = token .. "|" .. to
    bag.emotes[key] = (bag.emotes[key] or 0) + 1
    bag.last = now()
end

local function hook(name, fn)
    if type(_G[name]) == "function" and hooksecurefunc then pcall(hooksecurefunc, name, fn) end
end

function Counters:OnLogin()
    Counters.Bag() -- sends yesterday's counters
    money = ns.Safe(try(GetMoney))
    hook("JumpOrAscendStart", function() Counters.Bump("jumps") end)
    hook("DoEmote", Counters.OnEmote)
    ns:RegisterGameEvent("CHAT_MSG_SYSTEM", Counters.OnSystem)
    ns:RegisterGameEvent("UI_ERROR_MESSAGE", Counters.OnError)
    ns:RegisterGameEvent("CONFIRM_XP_LOSS", function() Counters.Bump("spirit") end)
    ns:RegisterGameEvent("PLAYER_MONEY", Counters.OnMoney)
    ns:RegisterGameEvent("LOOT_OPENED", function()
        if try(IsFishingLoot) then Counters.Bump("fish") end
    end)
    ns:RegisterGameEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spell)
        if unit == "player" and ns.Safe(spell) == Counters.HEARTHSTONE then Counters.Bump("hearth") end
    end)
end
