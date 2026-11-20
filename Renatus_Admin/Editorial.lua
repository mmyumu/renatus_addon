-- Editorial.lua: items produced outside the game by the companion app, reviewed here.
--
-- The companion writes Renatus_Admin/Press.lua (a plain Lua table, RenatusPress).
-- The game reloads it on every /reload. An officer reviews each item (Publish / Ignore)
-- in the admin window (Window.lua). One exception: the rival guild's armory roster (public
-- data) is published without a click when an officer logs in (Press.AutoRoster).
-- Once published, the item becomes an event signed by the editor:
--   DEATH_CAUSE, PVP_CLASH -> provenance LOG ("according to X's combat log")
--   ARTICLE                -> provenance GEN (editorial; facts are in refs)
--   EDITION                -> provenance GEN: page layout of an edition (Renatus/UI/Newsprint.lua);
--                             publishing it also publishes its pending articles (same p.edition)
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
    EDITION = { prov = "GEN", label = "Mise en page" },
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
    if item.kind == "EDITION" then
        local n = #Press.EditionArticles(item)
        local layout = R.UI.Newsprint.Sanitize(p)
        local pages = layout and #layout.pages or 0
        return ("Mise en page « %s » : %d page(s), %d article(s)"):format(tostring(p.template or "libre"), pages, n)
    end
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

-- Pending articles of an edition (same p.edition), in editorial order.
function Press.EditionArticles(edition)
    local tag = edition.p and edition.p.edition
    if not tag then return {} end
    local out = Press.Pending(function(i) return i.kind == "ARTICLE" and i.p.edition == tag end)
    table.sort(out, function(x, y) return (tonumber(x.p.order) or 99) < (tonumber(y.p.order) or 99) end)
    return out
end

-- Article as the gazette shows it (preview of an unpublished edition).
local function previewArticle(item)
    local p = item.p
    local _, me = R.Context.Me()
    return { id = item.id, key = p.key, order = tonumber(p.order), title = p.title, body = p.body, kind = p.format,
        style = p.style, quote = p.quote, portrait = p.portrait, ia = (p.ia == true) or nil, author = me, refs = item.refs }
end

-- Opens the members' gazette on the edition (or the article) as it would look once published.
function Press.Preview(item)
    if not valid(item) then return end
    if item.kind == "EDITION" then
        local arts = {}
        for _, a in ipairs(Press.EditionArticles(item)) do arts[#arts + 1] = previewArticle(a) end
        R.UI.GazettePreview(arts, item.p)
    elseif item.kind == "ARTICLE" then
        R.UI.GazettePreview({ previewArticle(item) }, nil)
    end
end

-- Returns the published event, or nil and a reason.
function Press.Publish(item)
    if not valid(item) or R.db.pressDone[item.id] then return nil, "deja traite" end
    if not A.IsOfficer() then return nil, "rang" end
    local ev, why
    if item.kind == "EDITION" then
        -- Articles first: the layout refers to them.
        for _, a in ipairs(Press.EditionArticles(item)) do Press.Publish(a) end
    end
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

-- Armory roster of the rival guild in force: an officer's client publishes the latest
-- pending one by itself (R.db.adminAutoRoster == false turns this off); older pending ones,
-- and one not newer than the roster in force, are set aside. Changing the rival guild
-- itself (GUILD_CONFIG) still needs a click. Returns the published event, if any.
function Press.AutoRoster()
    if R.db.adminAutoRoster == false or not A.IsOfficer() then return nil end
    local rival = R.GuildConfig.Rival()
    if not rival then return nil end
    rival = rival:lower()
    local list = Press.Pending(function(i)
        return i.kind == "RIVAL_ROSTER" and type(i.p.guild) == "string" and i.p.guild:lower() == rival
            and type(i.p.members) == "table"
    end)
    if #list == 0 then return nil end
    local function at(i) return tonumber(i.p.at) or tonumber(i.t) or 0 end
    table.sort(list, function(x, y) return at(x) > at(y) end)
    for i = 2, #list do Press.Ignore(list[i]) end
    local latest, cur = list[1], R.GuildConfig.Roster()
    if cur and (tonumber(cur.p.at) or cur.t or 0) >= at(latest) then Press.Ignore(latest) return nil end
    local ev = Press.Publish(latest)
    if ev then R.Print("effectif de <%s> publié automatiquement (%s).", tostring(latest.p.guild), Press.Label(latest)) end
    return ev
end

-- Once per session, as soon as the guild roster tells this character is an officer.
local autoDone = false
R:RegisterGameEvent("GUILD_ROSTER_UPDATE", function()
    if autoDone or not A.IsOfficer() then return end
    autoDone = true
    Press.AutoRoster()
end)
