-- Sync/Transport.lua: sending and receiving addon messages on the GUILD channel.
--
-- - Long messages split into chunks (first byte: S single, F first, M middle, L last).
--   On a given channel, messages from the same sender arrive in order.
-- - Priority queue with rate limiting (token bucket), to stay under client throttling.
-- - Sends ONLY outside instances and combat (Midnight / Forever restrictions):
--   the queue simply waits, nothing is lost.
-- - A queued message can be cancelled at send time (make() returns nil).
local _, ns = ...

local Transport = {}
ns.Transport = Transport

Transport.PREFIX = "Renatus"
Transport.CHUNK = 250          -- payload bytes per message (client limit: 255)
Transport.BURST = 4            -- max tokens
Transport.RATE = 1.2           -- seconds per token
Transport.PRIORITY = { CONFIG = 1, CONTROL = 2, EVENT = 3, BULK = 4, LOW = 5 }

local queue = {}       -- { prio, seq, make, parts, index }
local queueSeq = 0
local tokens = Transport.BURST
local sinceToken = 0
local partial = {}     -- [sender] = { chunks }
local handler          -- function(sender, text)
local registered = false
Transport.stats = { sent = 0, received = 0, dropped = 0, lastSent = nil, lastReceived = nil }

local function try(fn, ...) return ns.Try(fn, ...) end

local function api()
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        return C_ChatInfo.SendAddonMessage, C_ChatInfo.RegisterAddonMessagePrefix
    end
    return SendAddonMessage, RegisterAddonMessagePrefix
end

-- Can we send now? (reason returned for display)
function Transport.CanSend()
    if not registered then return false, "canal indisponible" end
    if not try(IsInGuild) then return false, "hors guilde" end
    if try(IsInInstance) then return false, "en instance" end
    if try(InCombatLockdown) then return false, "en combat" end
    return true
end

function Transport.QueueLength() return #queue end

function Transport.SetHandler(fn) handler = fn end

-- make: function returning the full text (or nil to cancel), called at send time.
function Transport.Send(make, priority)
    if type(make) == "string" then
        local text = make
        make = function() return text end
    end
    queueSeq = queueSeq + 1
    table.insert(queue, { prio = priority or Transport.PRIORITY.EVENT, seq = queueSeq, make = make })
    table.sort(queue, function(a, b)
        -- a message already in progress goes first (otherwise its chunks get interleaved)
        if (a.parts ~= nil) ~= (b.parts ~= nil) then return a.parts ~= nil end
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.seq < b.seq
    end)
end

local function split(text)
    local size = Transport.CHUNK - 1
    if #text <= size then return { "S" .. text } end
    local parts = {}
    for i = 1, #text, size do
        local piece = text:sub(i, i + size - 1)
        local tag = (i == 1) and "F" or ((i + size > #text) and "L" or "M")
        parts[#parts + 1] = tag .. piece
    end
    return parts
end

local function rawSend(msg)
    local send = api()
    if type(send) ~= "function" then return false end
    local ok, res = pcall(send, Transport.PREFIX, msg, "GUILD")
    -- Retail returns a code (0 = success); older versions return nothing or a boolean.
    return ok and (res == nil or res == true or res == 0)
end

local function pump()
    while #queue > 0 and tokens >= 1 do
        if not Transport.CanSend() then return end
        local item = queue[1]
        if not item.parts then
            local text = item.make()
            if text then
                item.parts, item.index = split(text), 1
            else
                table.remove(queue, 1) -- cancelled (already broadcast by someone else, or deleted)
            end
        end
        if item.parts then
            if rawSend(item.parts[item.index]) then
                tokens = tokens - 1
                item.index = item.index + 1
                Transport.stats.sent = Transport.stats.sent + 1
                Transport.stats.lastSent = (GetServerTime and GetServerTime()) or time()
                if item.index > #item.parts then table.remove(queue, 1) end
            else
                tokens = 0 -- client-side throttle: wait for the next token
            end
        end
    end
end
Transport.Pump = pump

local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
    sinceToken = sinceToken + elapsed
    while sinceToken >= Transport.RATE do
        sinceToken = sinceToken - Transport.RATE
        if tokens < Transport.BURST then tokens = tokens + 1 end
    end
    pump()
end)

local function shortName(sender)
    if not sender then return nil end
    return (sender:gsub("%-.*$", ""))
end
Transport.ShortName = shortName

function Transport.OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= Transport.PREFIX or channel ~= "GUILD" then return end
    msg, sender = ns.Safe(msg), ns.Safe(sender)
    if type(msg) ~= "string" or #msg < 1 or not sender then return end
    local _, me = ns.Context.Me()
    if shortName(sender) == me then return end -- our own messages come back too
    local tag, body = msg:sub(1, 1), msg:sub(2)
    local text
    if tag == "S" then
        text = body
    elseif tag == "F" then
        partial[sender] = { body }
    elseif tag == "M" or tag == "L" then
        local acc = partial[sender]
        if not acc then Transport.stats.dropped = Transport.stats.dropped + 1; return end
        acc[#acc + 1] = body
        if #acc > 200 then partial[sender] = nil; Transport.stats.dropped = Transport.stats.dropped + 1; return end
        if tag == "L" then text = table.concat(acc); partial[sender] = nil end
    end
    if text then
        Transport.stats.received = Transport.stats.received + 1
        Transport.stats.lastReceived = (GetServerTime and GetServerTime()) or time()
        if handler then handler(sender, text) end
    end
end

function Transport.Init()
    local _, register = api()
    if type(register) == "function" then
        local ok = pcall(register, Transport.PREFIX)
        registered = ok
    end
    ns:RegisterGameEvent("CHAT_MSG_ADDON", function(_, ...) Transport.OnAddonMessage(...) end)
    return registered
end

-- For tests: empties the queue and refills the tokens.
function Transport.Reset()
    queue, partial, tokens, sinceToken = {}, {}, Transport.BURST, 0
end
