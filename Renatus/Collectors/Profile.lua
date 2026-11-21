-- Collectors/Profile.lua: the member's card profile (CARD_PROFILE), so that the cards about
-- them show their own character: race, sex, class and the items they wear (3D portrait,
-- UI/TabAlbum.lua), and whether they asked not to be in the others' album (optOut).
-- Sent at login when something changed, and when the album option changes. Every member
-- sends it: no card portrait is reserved to anyone.
local _, ns = ...

local Profile = ns:RegisterModule("CardProfile", {})
ns.Profile = Profile
local try = ns.Try

-- Visible slots: head, shoulders, shirt, chest, waist, legs, feet, wrists, hands, back,
-- main hand, off hand, tabard.
Profile.SLOTS = { 1, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 19 }

function Profile.Build()
    local _, raceFile, raceID = try(UnitRace, "player")
    local _, class = try(UnitClass, "player")
    local items = {}
    if GetInventoryItemID then
        for _, slot in ipairs(Profile.SLOTS) do
            local id = ns.Safe(try(GetInventoryItemID, "player", slot))
            if type(id) == "number" then items[#items + 1] = slot .. ":" .. id end
        end
    end
    return {
        race = ns.Safe(raceID), raceFile = ns.Safe(raceFile), sex = ns.Safe(try(UnitSex, "player")),
        class = ns.Safe(class), items = #items > 0 and table.concat(items, ",") or nil,
        optOut = ns.char.albumOptOut and true or nil,
        -- level: which versions of the member's card are earned (admin/core/src/cards.rs)
        lvl = ns.Safe(try(UnitLevel, "player")),
    }
end

local function same(a, b)
    if not a or not b then return false end
    for _, k in ipairs({ "race", "raceFile", "sex", "class", "items", "optOut", "lvl" }) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- Latest profile this character sent.
local function last()
    local me = ns.Context.Me()
    local best
    for _, ev in pairs(ns.db.events) do
        if ev.k == "CARD_PROFILE" and ev.a == me and not ev.del and (not best or (ev.t or 0) > (best.t or 0)) then
            best = ev
        end
    end
    return best and best.p
end

-- Sends the profile if it changed; returns the event, if any.
function Profile.Publish()
    if ns.char.ui.demo then return nil end
    local p = Profile.Build()
    if same(p, last()) then return nil end
    return ns.Store.Add("CARD_PROFILE", p, { keep = true, noExp = true, loc = {} })
end

function Profile:OnLogin()
    -- Items and race are reliable a few seconds after login.
    if C_Timer then C_Timer.After(15, Profile.Publish) else Profile.Publish() end
end
