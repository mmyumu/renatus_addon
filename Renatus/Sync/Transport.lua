-- Sync/Transport.lua : envoi et reception de messages d'addon sur le canal GUILD.
--
-- - Messages longs decoupes en morceaux (premier octet : S seul, F debut, M milieu, L fin).
--   Sur un canal donne, les messages d'un meme expediteur arrivent dans l'ordre.
-- - File a priorites avec debit limite (seau a jetons), pour rester sous le throttling du client.
-- - Envoi SEULEMENT hors instance et hors combat (restrictions Midnight / Forever) :
--   la file attend simplement, rien n'est perdu.
-- - Un message en attente peut etre annule au moment de l'envoi (make() renvoie nil).
local _, ns = ...

local Transport = {}
ns.Transport = Transport

Transport.PREFIX = "Renatus"
Transport.CHUNK = 250          -- octets utiles par message (limite client : 255)
Transport.BURST = 4            -- jetons max
Transport.RATE = 1.2           -- secondes par jeton
Transport.PRIORITY = { CONFIG = 1, CONTROL = 2, EVENT = 3, BULK = 4, LOW = 5 }

local queue = {}       -- { prio, seq, make, parts, index }
local queueSeq = 0
local tokens = Transport.BURST
local sinceToken = 0
local partial = {}     -- [expediteur] = { morceaux }
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

-- Peut-on emettre maintenant ? (raison renvoyee pour l'affichage)
function Transport.CanSend()
    if not registered then return false, "canal indisponible" end
    if not try(IsInGuild) then return false, "hors guilde" end
    if try(IsInInstance) then return false, "en instance" end
    if try(InCombatLockdown) then return false, "en combat" end
    return true
end

function Transport.QueueLength() return #queue end

function Transport.SetHandler(fn) handler = fn end

-- make : fonction renvoyant le texte complet (ou nil pour annuler), appelee au moment de l'envoi.
function Transport.Send(make, priority)
    if type(make) == "string" then
        local text = make
        make = function() return text end
    end
    queueSeq = queueSeq + 1
    table.insert(queue, { prio = priority or Transport.PRIORITY.EVENT, seq = queueSeq, make = make })
    table.sort(queue, function(a, b)
        -- un message deja entame passe avant tout (sinon ses morceaux se melangent)
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
    -- Retail renvoie un code (0 = succes) ; d'anciennes versions ne renvoient rien ou un booleen.
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
                table.remove(queue, 1) -- annule (deja diffuse par un autre, ou supprime)
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
                tokens = 0 -- throttle cote client : on attend le prochain jeton
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
    if shortName(sender) == me then return end -- nos propres messages reviennent aussi
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

-- Pour les tests : vide la file et remet les jetons.
function Transport.Reset()
    queue, partial, tokens, sinceToken = {}, {}, Transport.BURST, 0
end
