-- Editorial.lua: items produced outside the game by the companion app, reviewed here.
--
-- The companion writes Renatus_Admin/Press.lua (a plain Lua table, RenatusPress).
-- The game reloads it on every /reload. Nothing is published automatically: an officer
-- reviews each item (Publish / Ignore) in the admin window (Window.lua).
-- Once published, the item becomes an event signed by the editor:
--   DEATH_CAUSE, PVP_CLASH -> provenance LOG ("according to X's combat log")
--   ARTICLE                -> provenance GEN (editorial; facts are in refs)
--   GUILD_CONFIG           -> guild settings (officers only, see Renatus/Core/GuildConfig.lua)
--   RIVAL_ROSTER           -> provenance EXT: the rival guild's roster from the armory
local _, A = ...

local R = Renatus.ns
A.R = R
Renatus.admin = A   -- no new global: reachable through the Renatus API table

-- Admin icon (minimap, window header): a key, distinct from the members' book.
A.ICON = "Interface\\Icons\\INV_Misc_Key_03"

local Press = {}
A.Press = Press

-- Admin actions are for officers (same rank rule as guild settings).
function A.IsOfficer() return R.GuildConfig.CanPublish() end
function A.RankHelp()
    return ("Réservé aux rangs 0 à %d de la guilde (0 = maître de guilde)."):format(R.GuildConfig.OFFICER_MAX_RANK)
end

local KINDS = {
    DEATH_CAUSE = { prov = "LOG", label = "Cause de mort" },
    PVP_CLASH = { prov = "LOG", label = "Affrontement (journal de combat)" },
    ARTICLE = { prov = "GEN", label = "Article" },
    GUILD_CONFIG = { label = "Réglage de guilde" },
    RIVAL_ROSTER = { prov = "EXT", label = "Armurerie" },
}
Press.KINDS = KINDS

local function valid(item)
    return type(item) == "table" and type(item.id) == "string" and KINDS[item.kind] ~= nil
        and type(item.p) == "table"
end

function Press.Available()
    return type(RenatusPress) == "table" and type(RenatusPress.items) == "table"
end

-- Items not handled yet; filter(item) -> bool keeps a subset.
function Press.Pending(filter)
    local out = {}
    if not Press.Available() then return out end
    for _, item in ipairs(RenatusPress.items) do
        if valid(item) and not R.db.pressDone[item.id] and (not filter or filter(item)) then
            table.insert(out, item)
        end
    end
    return out
end

-- Guild settings (rival guild and its armory roster) vs. gazette content.
function Press.IsGuildItem(item) return item.kind == "GUILD_CONFIG" or item.kind == "RIVAL_ROSTER" end
function Press.IsGazetteItem(item) return not Press.IsGuildItem(item) end

function Press.Label(item)
    local k = KINDS[item.kind]
    local p = item.p
    if item.kind == "ARTICLE" then return (p.ia == true and "Article (IA)" or k.label) .. " : " .. tostring(p.title) end
    if item.kind == "DEATH_CAUSE" then return ("Mort de %s : %s"):format(tostring(p.victim), tostring(p.cause)) end
    if item.kind == "PVP_CLASH" then
        return ("%s %s %s"):format(tostring(p.member), p.result == "win" and "a vaincu" or "a été vaincu par", tostring(p.name))
    end
    if item.kind == "RIVAL_ROSTER" then
        local n = type(p.members) == "table" and #p.members or 0
        return ("Effectif de %s : %d membre(s)"):format(tostring(p.guild), p.count or n)
    end
    if item.kind == "GUILD_CONFIG" then
        return "Guilde rivale : " .. (R.GuildConfig.Trim(p.rival) or "aucune")
    end
    return k.label
end

-- Returns the published event, or nil and a reason.
function Press.Publish(item)
    if not valid(item) or R.db.pressDone[item.id] then return nil, "deja traite" end
    if not A.IsOfficer() then return nil, "rang" end
    local ev, why
    if item.kind == "GUILD_CONFIG" then
        ev, why = R.GuildConfig.Publish({ rival = item.p.rival or false })
    else
        local k = KINDS[item.kind]
        local refs = {}
        for _, r in ipairs(type(item.refs) == "table" and item.refs or {}) do
            if type(r) == "string" then table.insert(refs, r) end
        end
        ev = R.Store.Add(item.kind, item.p, {
            prov = k.prov, refs = #refs > 0 and refs or nil, vis = "G", noExp = true,
            loc = type(item.loc) == "table" and item.loc or {},
            occ = item.occ, t = type(item.t) == "number" and item.t or nil,
        })
    end
    if ev then R.db.pressDone[item.id] = "published" end
    return ev, why
end

function Press.Ignore(item)
    if valid(item) then R.db.pressDone[item.id] = "ignored" end
end
