-- Collectors/Loot.lua: the first time this character receives a rare item (blue or better),
-- a RARE_ITEM event with the item's id, so that its album card shows the item's own icon
-- (admin/core/src/cards.rs: the first one in the guild gets the card).
-- Source: the game's own loot messages about this character (CHAT_MSG_LOOT, matched with
-- the client's LOOT_ITEM_*SELF strings, any language). With an item link, its id and quality
-- come from it; WoW Forever gives addons the plain text ("[Name]"), so the item is then
-- found by its name (client item data, else the bags). Secret values are ignored.
local _, ns = ...

local Loot = ns:RegisterModule("CollectorLoot", {})
ns.Loot = Loot
local try = ns.Try

Loot.MIN_QUALITY = 3   -- rare (blue) and better
local QUALITY_COLOR = { ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6 }
local MESSAGES = { "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
    "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF" }

-- Lua pattern from a format string: "%s" captures, "%d" matches a number.
function Loot.Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "%%d+")
    return "^" .. p .. "$"
end

-- Patterns of the client's messages, built once (Loot.patterns = nil rebuilds them).
local function allPatterns()
    if not Loot.patterns then
        Loot.patterns = {}
        for _, key in ipairs(MESSAGES) do
            local p = Loot.Pattern(_G[key])
            if p then Loot.patterns[#Loot.patterns + 1] = p end
        end
    end
    return Loot.patterns
end

-- id and quality of an item from its link ("|cnIQ4:" on recent clients, else a colour code).
local function fromLink(link)
    if type(link) ~= "string" then return nil end
    local id = tonumber(link:match("|Hitem:(%d+)"))
    if not id then return nil end
    local q = tonumber(link:match("|cnIQ(%d)")) or QUALITY_COLOR[(link:match("|cff(%x%x%x%x%x%x)") or ""):lower()]
    return id, q
end

-- An item known only by its name (WoW Forever hands addons plain text, "[Name]", in the loot
-- message and even in GetItemInfo's link): the client's item data, else the bags (checked
-- on Forever: C_Container.GetContainerItemInfo gives itemID, quality, itemName). id, quality
-- or nil.
function Loot.ByName(name)
    local info = C_Item and C_Item.GetItemInfo or GetItemInfo
    local _, link, quality = try(info, name)
    local id, q = fromLink(link)
    if id then return id, quality or q end
    -- recent clients: the id straight from the name (cached items), the quality from above
    id = C_Item and tonumber(try(C_Item.GetItemIDForItemInfo, name))
    if id and quality then return id, quality end
    local c = C_Container
    if not (c and c.GetContainerNumSlots and c.GetContainerItemInfo) then return nil end
    for bag = 0, 4 do
        for slot = 1, try(c.GetContainerNumSlots, bag) or 0 do
            local item = try(c.GetContainerItemInfo, bag, slot)
            if type(item) == "table" and item.itemID then
                local itemName = item.itemName or (item.hyperlink and item.hyperlink:match("%[(.-)%]"))
                if itemName == name then return item.itemID, item.quality end
            end
        end
    end
    return nil
end

-- Item received by this character in a loot message: id, name, quality (nil if unknown).
function Loot.Parse(msg)
    msg = ns.Safe(msg)
    if type(msg) ~= "string" then return nil end
    for _, p in ipairs(allPatterns()) do
        local text = msg:match(p)
        if text then
            local name = text:match("%[(.-)%]")
            local id, q = fromLink(text)
            if id then return id, name, q end
            if name and name ~= "" then
                id, q = Loot.ByName(name)
                if id then return id, name, q end
            end
            return nil
        end
    end
    return nil
end

Loot.RETRY = 1   -- seconds: the item may reach the bags just after the message

function Loot.OnMessage(msg, retried)
    local id, name, quality = Loot.Parse(msg)
    if not id then
        if not retried and C_Timer and ns.Safe(msg) then
            C_Timer.After(Loot.RETRY, function() Loot.OnMessage(msg, true) end)
        end
        return nil
    end
    quality = quality or (C_Item and try(C_Item.GetItemQualityByID, id))
    if not quality or quality < Loot.MIN_QUALITY then return nil end
    local seen = ns.char.itemsSeen
    if seen[id] then return nil end
    seen[id] = true
    return ns.Store.Add("RARE_ITEM", { item = name, id = id, q = quality })
end

function Loot:OnLogin()
    ns:RegisterGameEvent("CHAT_MSG_LOOT", function(_, msg) Loot.OnMessage(msg) end)
end
