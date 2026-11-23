-- Core/Trade.lua: card trades and gifts between guild members (docs/ARCHITECTURE.md §9.4).
-- Two shared events:
--   TRADE_OFFER  (by the giver): p.to (guid), p.toName, p.give = { card ids }, p.want = { card ids }
--                (want empty = a gift);
--   TRADE_REPLY  (refs = { offer id }): p.ok = true/false. From the recipient it accepts or
--                declines the offer; from the giver (ok = false) it withdraws it.
-- Who owns what is replayed from the shared events in time order: shared booster openings
-- add cards, accepted offers move them. An offer only goes through if, when it is accepted,
-- the giver still owns what they give and the recipient what is asked of them; otherwise it
-- fails, the same way on every client. Members are trusted (no check of the draws): these
-- checks only keep a card from being given twice.
local _, ns = ...

local Trade = {}
ns.Trade = Trade

Trade.TTL = 7 * 86400     -- an offer not answered within a week expires
Trade.MAX_CARDS = 5       -- per side of an offer

local function now() return (GetServerTime and GetServerTime()) or time() end

-- Card id list from untrusted input; nil if invalid.
local function cardList(v, allowEmpty)
    if v == nil then v = {} end
    if type(v) ~= "table" or #v > Trade.MAX_CARDS then return nil end
    local out = {}
    for i = 1, #v do
        if type(v[i]) ~= "string" or #v[i] > 80 then return nil end
        out[i] = v[i]
    end
    if #out == 0 and not allowEmpty then return nil end
    return out
end

local function counts(list)
    local c = {}
    for _, id in ipairs(list) do c[id] = (c[id] or 0) + 1 end
    return c
end

local function has(owned, list)
    for id, n in pairs(counts(list)) do
        if ((owned and owned[id]) or 0) < n then return false end
    end
    return true
end

local function move(owned, from, to, list, t, received)
    owned[from] = owned[from] or {}
    owned[to] = owned[to] or {}
    for _, id in ipairs(list) do
        owned[from][id] = owned[from][id] - 1
        if owned[from][id] == 0 then owned[from][id] = nil end
        owned[to][id] = (owned[to][id] or 0) + 1
        received[to] = received[to] or {}
        received[to][id] = { from = from, t = t }
    end
end

-- Replays the shared events (ds.events: most recent first). Returns:
--   owned    = { [guid] = { [cardId] = copies } }   (shared booster openings and trades only)
--   offers   = { [offerId] = offer }, list = offers sorted most recent first
--     offer = { id, t, from, fromName, to, toName, give, want, status, at }
--     status: "pending", "accepted", "declined", "cancelled", "expired", "failed"
--   received = { [guid] = { [cardId] = { from = guid, t = time } } } (the last copy received)
--   given    = { [guid] = { [cardId] = copies given away } }, got = same for copies received
function Trade.Replay(events, at)
    at = at or now()
    local offers, list = {}, {}
    for _, ev in ipairs(events) do
        if ev.k == "TRADE_OFFER" and ev.vis == "G" and not ev.del then
            local p = ev.p or {}
            local give, want = cardList(p.give), cardList(p.want, true)
            if give and want and type(p.to) == "string" and p.to ~= ev.a then
                local o = { id = ev.id, t = ev.t, from = ev.a, fromName = ev.n, to = p.to,
                    toName = type(p.toName) == "string" and p.toName or "?",
                    give = give, want = want, status = "pending" }
                offers[ev.id] = o
                list[#list + 1] = o
            end
        end
    end
    local owned, received, given, got = {}, {}, {}, {}
    local function tally(book, guid, ids)
        book[guid] = book[guid] or {}
        for _, id in ipairs(ids) do book[guid][id] = (book[guid][id] or 0) + 1 end
    end
    -- oldest first (the list is sorted by time then id, descending)
    for i = #events, 1, -1 do
        local ev = events[i]
        if ev.vis == "G" and not ev.del then
            if ev.k == "BOOSTER_OPEN" then
                local mine = owned[ev.a] or {}
                owned[ev.a] = mine
                for _, id in ipairs(type(ev.p.cards) == "table" and ev.p.cards or {}) do
                    if type(id) == "string" then mine[id] = (mine[id] or 0) + 1 end
                end
            elseif ev.k == "TRADE_REPLY" then
                local o = offers[type(ev.refs) == "table" and ev.refs[1] or ""]
                if o and o.status == "pending" and ev.t >= o.t then
                    if ev.a == o.from and ev.p.ok ~= true then
                        o.status, o.at = "cancelled", ev.t
                    elseif ev.a == o.to and ev.t <= o.t + Trade.TTL then
                        o.at = ev.t
                        if ev.p.ok ~= true then
                            o.status = "declined"
                        elseif has(owned[o.from], o.give) and has(owned[o.to], o.want) then
                            o.status = "accepted"
                            move(owned, o.from, o.to, o.give, ev.t, received)
                            move(owned, o.to, o.from, o.want, ev.t, received)
                            tally(given, o.from, o.give); tally(got, o.to, o.give)
                            tally(given, o.to, o.want); tally(got, o.from, o.want)
                        else
                            o.status = "failed"
                        end
                    end
                end
            end
        end
    end
    for _, o in ipairs(list) do
        if o.status == "pending" and at > o.t + Trade.TTL then o.status, o.at = "expired", o.t + Trade.TTL end
    end
    table.sort(list, function(a, b)
        local ta, tb = a.at or a.t, b.at or b.t
        if ta ~= tb then return ta > tb end
        return a.id > b.id
    end)
    return { owned = owned, offers = offers, list = list, received = received, given = given, got = got }
end

-- The player's collection as shown: all their own openings (shared or not), plus the cards
-- received, minus the cards given (ds.trades = Trade.Replay(ds.events)).
function Trade.Apply(collection, trades, me)
    for id, n in pairs(trades.got[me] or {}) do collection[id] = (collection[id] or 0) + n end
    for id, n in pairs(trades.given[me] or {}) do
        collection[id] = (collection[id] or 0) - n
        if collection[id] <= 0 then collection[id] = nil end
    end
    return collection
end

------------------------------------------------------------------------
-- Views for the player
------------------------------------------------------------------------
local function pendingWhere(ds, fn)
    local out = {}
    for _, o in ipairs(ds.trades and ds.trades.list or {}) do
        if o.status == "pending" and fn(o) then out[#out + 1] = o end
    end
    return out
end

function Trade.Incoming(ds) return pendingWhere(ds, function(o) return o.to == ds.me end) end
function Trade.Outgoing(ds) return pendingWhere(ds, function(o) return o.from == ds.me end) end

-- Offers involving the player that are over, most recent first.
function Trade.History(ds, limit)
    local out = {}
    for _, o in ipairs(ds.trades and ds.trades.list or {}) do
        if o.status ~= "pending" and (o.from == ds.me or o.to == ds.me) then
            out[#out + 1] = o
            if limit and #out >= limit then break end
        end
    end
    return out
end

-- A member's collection as everyone sees it (shared openings and trades).
function Trade.CollectionOf(ds, guid)
    if guid == ds.me then return ds.collection or {} end
    return ds.trades and ds.trades.owned[guid] or {}
end

-- Copies the player can still offer: what the others see they own, minus the copies
-- already promised in their pending offers.
function Trade.Tradable(ds)
    local out = {}
    for id, n in pairs(ds.trades and ds.trades.owned[ds.me] or {}) do out[id] = n end
    for _, o in ipairs(Trade.Outgoing(ds)) do
        for _, id in ipairs(o.give) do
            if out[id] then
                out[id] = out[id] - 1
                if out[id] <= 0 then out[id] = nil end
            end
        end
    end
    return out
end

-- Why trading is not possible right now (nil if it is).
function Trade.Unavailable(ds)
    if ds.isDemo then return "Pas d'échanges en mode démo." end
    if not ds.guildKey then return "Il faut être dans une guilde pour échanger." end
    if ns.char.privacy.album ~= "G" then
        return "Pour échanger, partage ton album avec la guilde (Options, confidentialité : Album sur « Guilde »)."
    end
    return nil
end

-- Can the player accept this offer? true, or false and the reason.
function Trade.CanAccept(ds, o)
    if o.status ~= "pending" or o.to ~= ds.me then return false, "Cette offre n'est plus valable." end
    local why = Trade.Unavailable(ds)
    if why then return false, why end
    if not has(ds.trades.owned[o.from], o.give) then return false, "Il n'a plus toutes les cartes proposées." end
    if not has(Trade.Tradable(ds), o.want) then return false, "Tu n'as plus toutes les cartes demandées." end
    return true
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------
local function add(kind, payload, refs)
    return ns.Store.Add(kind, payload, { vis = "G", keep = true, noExp = true, loc = {}, refs = refs })
end

-- Proposes `give` (card ids, at least one) against `want` (may be empty: a gift) to `to`.
-- Returns the event, or nil and the reason.
function Trade.Offer(ds, to, toName, give, want)
    local why = Trade.Unavailable(ds)
    if why then return nil, why end
    give, want = cardList(give), cardList(want, true)
    if not give then return nil, "Choisis de 1 à " .. Trade.MAX_CARDS .. " cartes à donner." end
    if not want then return nil, "Pas plus de " .. Trade.MAX_CARDS .. " cartes demandées." end
    if type(to) ~= "string" or to == ds.me then return nil, "Choisis un membre." end
    if not has(Trade.Tradable(ds), give) then return nil, "Tu n'as plus ces cartes (ou elles sont déjà proposées)." end
    if not has(ds.trades.owned[to], want) then return nil, "Il n'a pas ces cartes." end
    return add("TRADE_OFFER", { to = to, toName = toName, give = give, want = want })
end

function Trade.Reply(ds, offerId, ok)
    local o = ds.trades and ds.trades.offers[offerId]
    if not o or o.status ~= "pending" then return nil, "Cette offre n'est plus valable." end
    if ok then
        local can, why = Trade.CanAccept(ds, o)
        if not can then return nil, why end
    elseif o.to ~= ds.me then
        return nil, "Cette offre ne t'est pas adressée."
    end
    return add("TRADE_REPLY", { ok = ok and true or false }, { offerId })
end

function Trade.Cancel(ds, offerId)
    local o = ds.trades and ds.trades.offers[offerId]
    if not o or o.status ~= "pending" or o.from ~= ds.me then return nil, "Cette offre n'est plus valable." end
    return add("TRADE_REPLY", { ok = false }, { offerId })
end

------------------------------------------------------------------------
-- Chat notices when an offer or an answer arrives from someone else
------------------------------------------------------------------------
local function who(guid, name) return ns.Store.DisplayName(guid, name) or name or "?" end

ns.EventBus.Subscribe("CHRONICLE_EVENT", function(ev)
    if type(ev) ~= "table" or not ev.rx or ev.vis ~= "G" then return end
    local me = ns.Context.Me()
    if ev.k == "TRADE_OFFER" and type(ev.p) == "table" and ev.p.to == me then
        if now() > (ev.t or 0) + Trade.TTL then return end
        local gift = type(ev.p.want) ~= "table" or #ev.p.want == 0
        ns.Print(gift and "%s t'offre des cartes ! Ouvre l'album, bouton « Échanges »."
            or "%s te propose un échange de cartes. Ouvre l'album, bouton « Échanges ».", who(ev.a, ev.n))
    elseif ev.k == "TRADE_REPLY" and type(ev.refs) == "table" then
        local offer = ns.db.events[ev.refs[1]]
        if offer and offer.a == me and type(offer.p) == "table" and offer.p.to == ev.a then
            if ev.p.ok ~= true then
                ns.Print("%s a refusé ton offre de cartes.", who(ev.a, ev.n))
                return
            end
            local ds = ns.Store.Dataset()
            local o = ds.trades and ds.trades.offers[offer.id]
            if o and o.status == "accepted" then
                ns.Print("%s a accepté ton offre de cartes : l'échange est fait.", who(ev.a, ev.n))
            elseif o and o.status == "failed" then
                ns.Print("%s a accepté ton offre, mais une des cartes n'était plus disponible : rien n'a changé de main.", who(ev.a, ev.n))
            end
        end
    end
end)
