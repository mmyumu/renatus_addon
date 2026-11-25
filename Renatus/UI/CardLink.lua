-- UI/CardLink.lua: a card shared in the chat, the way items are linked.
-- Shift-click a card (album, booster, zoom) puts plain text in the chat box:
--     [Renatus: Forêt d'Elwynn #AZ:est:elwynn]
-- The server refuses custom hyperlinks in sent messages, so the text travels as is (players
-- without the addon read it as it is) and a chat filter turns it, on arrival, into a link
-- coloured by the card's rarity. The link borrows the "garrmission" type, as WeakAuras does:
-- every client knows it, and a link with no mission number does nothing on its own. Clicking
-- it opens the card large, if this client knows it (the catalogue differs from one guild, or
-- one sync, to another): otherwise a line in the chat says why, and nothing else happens.
-- Every step is protected: a failure never reaches the chat frame or the Blizzard UI.
local _, ns = ...
local UI = ns.UI
local Album = ns.Album

local CardLink = {}
ns.CardLink = CardLink

local LINK_TYPE = "garrmission:renatus:"
local UNKNOWN_COLOR = "ffd4a017"   -- addon colour: card unknown here

------------------------------------------------------------------------
-- Text <-> link (pure)
------------------------------------------------------------------------
-- An id travels in the message: no space, bracket or escape character.
local function linkableId(id)
    return type(id) == "string" and id ~= "" and not id:find("[%s%[%]|]") and id or nil
end

-- Plain text sent in the chat for a card, nil if the card cannot be linked.
function CardLink.Text(card)
    local id = card and linkableId(card.id)
    if not id then return nil end
    local name = tostring(card.name or "Carte"):gsub("[%[%]|]", "")
    if name == "" then name = "Carte" end
    if card.shiny then name = name .. " (brillante)" end
    return ("[Renatus: %s #%s]"):format(name, id)
end

local function hex(color)
    return ("ff%02x%02x%02x"):format(math.floor(color[1] * 255 + 0.5), math.floor(color[2] * 255 + 0.5),
        math.floor(color[3] * 255 + 0.5))
end

-- The message with each card text turned into a link. rarityOf(id): rarity key or nil.
-- Returns nil when the message holds no card.
function CardLink.Linkify(msg, rarityOf)
    if type(msg) ~= "string" or not msg:find("[Renatus: ", 1, true) then return nil end
    local out, n = msg:gsub("%[Renatus: ([^%]|]-) #([^%]%s|]+)%]", function(name, id)
        local rarity = rarityOf and rarityOf(id)
        local color = rarity and Album.RARITY_INDEX[rarity] and hex(Album.Rarity(rarity).color) or UNKNOWN_COLOR
        return ("|c%s|H%s%s|h[%s]|h|r"):format(color, LINK_TYPE, id, name)
    end)
    return n > 0 and out or nil
end

-- Card id of a clicked link, nil for any other link.
function CardLink.IdOf(link)
    return type(link) == "string" and link:match("^garrmission:renatus:(.+)$") or nil
end

------------------------------------------------------------------------
-- Cards known on this client (cached until the journal changes)
------------------------------------------------------------------------
local cache
local function known()
    local ds = ns.Store.Dataset()
    if not cache or cache.ds ~= ds then cache = { ds = ds, byId = Album.Known(ds) } end
    return cache.byId, ds
end
function CardLink.Forget() cache = nil end

local function rarityOf(id)
    local ok, byId = pcall(known)
    local card = ok and byId[id]
    return card and card.rarity or nil
end

------------------------------------------------------------------------
-- Sharing: shift-click on a card
------------------------------------------------------------------------
local function linkClick()
    if IsModifiedClick then
        local ok, v = pcall(IsModifiedClick, "CHATLINK")
        if ok then return v and true or false end
    end
    return IsShiftKeyDown and IsShiftKeyDown() and true or false
end

-- Puts the text in the open chat box, or opens one with it.
local function insert(text)
    local util = ChatFrameUtil or {}
    for _, fn in ipairs({ ChatEdit_InsertLink or false, util.InsertLink or false }) do
        if fn then
            local ok, done = pcall(fn, text)
            if ok and done then return true end
        end
    end
    local open = ChatFrame_OpenChat or util.OpenChat
    if open then return (pcall(open, text)) end
    return false
end

-- To call first in a card's OnClick: true if the click shared the card (nothing else to do).
function CardLink.ShiftClick(card)
    if not card or not linkClick() then return false end
    local text = CardLink.Text(card)
    if not text then return false end
    insert(text)
    return true
end

------------------------------------------------------------------------
-- Receiving: chat filter and click on the link
------------------------------------------------------------------------
local function secret(v) return issecretvalue and issecretvalue(v) end

local function filter(_, _, msg, ...)
    if secret(msg) then return false end
    local ok, out = pcall(CardLink.Linkify, msg, rarityOf)
    if ok and out then return false, out, ... end
    return false
end

-- Opens a shared card large. Returns true if this client knows it.
function CardLink.Show(id)
    local byId, ds = known()
    local card = byId[id]
    if not card then
        ns.Print("cette carte n'est pas dans ton catalogue (autre guilde, ou synchro pas encore à jour).")
        return false
    end
    UI.Open("album")
    local mine = ds.collection and ds.collection[id] or 0
    UI.ShowCardZoom(card, 1, mine > 0 and ("Tu l'as aussi (x%d). Clique pour refermer."):format(mine)
        or "Tu ne l'as pas encore. Clique pour refermer.")
    return true
end

local function onLink(link)
    local id = CardLink.IdOf(link)
    if not id then return end
    if linkClick() then
        -- shift-click on a link: passed on, as for an item
        local card = (known())[id] or { id = id, name = "Carte" }
        insert(CardLink.Text(card) or "")
        return
    end
    CardLink.Show(id)
end

local CHAT_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM", "CHAT_MSG_CHANNEL", "CHAT_MSG_COMMUNITIES_CHANNEL",
}

function CardLink.Init()
    local util = ChatFrameUtil or {}
    local add = util.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
    if add then
        for _, event in ipairs(CHAT_EVENTS) do pcall(add, event, filter) end
    end
    if hooksecurefunc and SetItemRef then
        hooksecurefunc("SetItemRef", function(link)
            local ok, err = pcall(onLink, link)
            if not ok then ns.Print("lien de carte : %s", tostring(err)) end
        end)
    end
    ns.EventBus.Subscribe("CHRONICLE_EVENT", CardLink.Forget)
end

CardLink.Init()
