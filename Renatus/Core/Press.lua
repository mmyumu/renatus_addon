-- Core/Press.lua: items produced outside the game by the editor's companion app.
--
-- The companion writes Interface/AddOns/Renatus_Press/Press.lua (a plain Lua table).
-- The game reloads it on every /reload. Nothing is published automatically: the editor
-- reviews each item (Publish / Ignore) in the Gazette tab.
-- Once published, the item becomes an event signed by the editor:
--   DEATH_CAUSE, PVP_CLASH -> provenance LOG ("according to X's combat log")
--   ARTICLE                -> provenance GEN (editorial; facts are in refs)
local _, ns = ...

local Press = ns:RegisterModule("Press", {})
ns.Press = Press

local KINDS = {
    DEATH_CAUSE = { prov = "LOG", label = "Cause de mort" },
    PVP_CLASH = { prov = "LOG", label = "Affrontement (journal de combat)" },
    ARTICLE = { prov = "GEN", label = "Article" },
}
Press.KINDS = KINDS

local function valid(item)
    return type(item) == "table" and type(item.id) == "string" and KINDS[item.kind] ~= nil
        and type(item.p) == "table"
end

function Press.Available()
    return type(RenatusPress) == "table" and type(RenatusPress.items) == "table"
end

function Press.Pending()
    local out = {}
    if not Press.Available() then return out end
    for _, item in ipairs(RenatusPress.items) do
        if valid(item) and not ns.db.pressDone[item.id] then table.insert(out, item) end
    end
    return out
end

function Press.Label(item)
    local k = KINDS[item.kind]
    local p = item.p
    if item.kind == "ARTICLE" then return (p.ia == true and "Article (IA)" or k.label) .. " : " .. tostring(p.title) end
    if item.kind == "DEATH_CAUSE" then return ("Mort de %s : %s"):format(tostring(p.victim), tostring(p.cause)) end
    if item.kind == "PVP_CLASH" then
        return ("%s %s %s"):format(tostring(p.member), p.result == "win" and "a vaincu" or "a été vaincu par", tostring(p.name))
    end
    return k.label
end

function Press.Publish(item)
    if not valid(item) or ns.db.pressDone[item.id] then return nil end
    local k = KINDS[item.kind]
    local refs = {}
    for _, r in ipairs(type(item.refs) == "table" and item.refs or {}) do
        if type(r) == "string" then table.insert(refs, r) end
    end
    local ev = ns.Store.Add(item.kind, item.p, {
        prov = k.prov, refs = #refs > 0 and refs or nil, vis = "G", noExp = true,
        loc = type(item.loc) == "table" and item.loc or {},
        occ = item.occ, t = type(item.t) == "number" and item.t or nil,
    })
    if ev then ns.db.pressDone[item.id] = "published" end
    return ev
end

function Press.Ignore(item)
    if valid(item) then ns.db.pressDone[item.id] = "ignored" end
end

------------------------------------------------------------------------
-- Consent to the AI gazette (docs §7, §8.4)
------------------------------------------------------------------------
-- The choice is published in the shared journal (AI_CONSENT event, always "G") so that
-- the editor's companion knows it: without explicit consent, this character's events
-- are never sent to the AI and their name is removed from other people's facts.
-- The latest choice (highest sequence) wins. Nothing checked = no consent.
local function lastConsent()
    local me, best = ns.Context.Me(), nil
    for _, ev in pairs(ns.db.events) do
        if ev.k == "AI_CONSENT" and ev.a == me and ev.vis == "G" and (not best or (ev.s or 0) > (best.s or 0)) then
            best = ev
        end
    end
    return best
end
Press.LastConsent = lastConsent

local function publishConsent(value)
    if not ns.Context.GuildKey() then return nil end
    local last = lastConsent()
    if last and (last.p.ok and true or false) == value then return last end
    if not last and not value then return nil end -- never accepted: nothing to announce
    return ns.Store.Add("AI_CONSENT", { ok = value }, { vis = "G", prov = "MAN", noExp = true, loc = {} })
end

function Press.SetConsent(value)
    value = value and true or false
    ns.char.exportConsent = value
    return publishConsent(value)
end

function Press:OnLogin()
    -- Choice made outside a guild, or before v0.4: announce it now.
    publishConsent(ns.char.exportConsent and true or false)
end
