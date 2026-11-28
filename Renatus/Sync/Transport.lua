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
-- Lower goes first. LIVE: what just happened (new events, gap fills of recent ones). Then
-- the catch-up tiers of a member who is far behind (Sync.ClassOf): what makes the addon
-- work (settings, catalogue), the gazette and the rival guild, the card ledger, the last
-- days, and the old history last. EVENT is the default for anything else.
Transport.PRIORITY = { CONFIG = 1, CONTROL = 2, LIVE = 3, EVENT = 3,
    ESSENTIAL = 4, GAZETTE = 5, LEDGER = 6, RECENT = 7, HISTORY = 8 }

local queue = {}       -- { prio, seq, make, parts, index }
local queueSeq = 0
local tokens = Transport.BURST
local sinceToken = 0
local partial = {}     -- [sender] = { chunks }
local handler          -- function(sender, text)
local registered = false
Transport.stats = { sent = 0, received = 0, dropped = 0, lastSent = nil, lastReceived = nil }
Transport.lastChunks = 0   -- number of chunks of the message being handled

------------------------------------------------------------------------
-- Debugging trace (/renatus sync trace on): what goes over the wire, kept in
-- RenatusDB.monitor.trace so it can be read after a /reload. Local only.
------------------------------------------------------------------------
Transport.TRACE_MAX = 600
Transport.TRACE_RAW = 8000

function Transport.Tracing()
    local tr = ns.db and ns.db.monitor and ns.db.monitor.trace
    return tr and tr.on and tr or nil
end

-- fields: plain values; `raw` (optional) is kept up to TRACE_RAW bytes.
function Transport.Trace(what, fields)
    local tr = Transport.Tracing()
    if not tr then return end
    local e = fields or {}
    e.w = what
    e.at = (GetServerTime and GetServerTime()) or time()
    if type(e.raw) == "string" and #e.raw > Transport.TRACE_RAW then
        e.rawLen, e.raw = #e.raw, e.raw:sub(1, Transport.TRACE_RAW)
    end
    local list = tr.entries
    list[#list + 1] = e
    while #list > Transport.TRACE_MAX do table.remove(list, 1) end
end

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

-- Chunks we sent lately, to recognize them when the channel echoes them back:
-- on WoW Forever the sender is "First Last" while UnitName gives only "First".
local echo = {}        -- [chunk] = clock time
local echoCount = 0
local function clock() return (GetTime and GetTime()) or time() end

local function rememberSent(msg)
    if not echo[msg] then echoCount = echoCount + 1 end
    echo[msg] = clock()
    if echoCount > 300 then
        local limit = clock() - 120
        for k, at in pairs(echo) do
            if at < limit then echo[k] = nil; echoCount = echoCount - 1 end
        end
    end
end

local function rawSend(msg)
    local send = api()
    if type(send) ~= "function" then return false end
    local ok, res = pcall(send, Transport.PREFIX, msg, "GUILD")
    -- Retail returns a code (0 = success); older versions return nothing or a boolean.
    local sent = ok and (res == nil or res == true or res == 0)
    if sent then rememberSent(msg) end
    return sent
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
                Transport.Trace("sendRefused", { part = item.index, parts = #item.parts })
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
    local from = shortName(sender)
    if from == me then return end -- our own messages come back too
    if from:match("^(%S+)") == me and echo[msg] and clock() - echo[msg] < 120 then
        -- our own message under our full name: forget the peer entry it used to create
        local peers = ns.db and ns.db.monitor and ns.db.monitor.peers
        if peers then peers[from] = nil end
        return
    end
    local tag, body = msg:sub(1, 1), msg:sub(2)
    local text, chunks
    if tag == "S" then
        text, chunks = body, 1
    elseif tag == "F" then
        if partial[sender] then
            -- the previous long message never got its last chunk
            Transport.Trace("lostEnd", { from = sender, chunks = #partial[sender], raw = table.concat(partial[sender]) })
        end
        partial[sender] = { body }
    elseif tag == "M" or tag == "L" then
        local acc = partial[sender]
        if not acc then
            Transport.stats.dropped = Transport.stats.dropped + 1
            Transport.Trace("orphan", { from = sender, tag = tag, raw = body })
            return
        end
        acc[#acc + 1] = body
        if #acc > 200 then
            partial[sender] = nil
            Transport.stats.dropped = Transport.stats.dropped + 1
            Transport.Trace("tooManyChunks", { from = sender })
            return
        end
        if tag == "L" then text, chunks = table.concat(acc), #acc; partial[sender] = nil end
    else
        Transport.Trace("badTag", { from = sender, raw = msg })
    end
    if text then
        Transport.lastChunks = chunks
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
