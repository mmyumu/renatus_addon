-- Core/Consent.lua: consent to the AI gazette (docs §7, §8.4).
local _, ns = ...

local Consent = ns:RegisterModule("Consent", {})
ns.Consent = Consent

-- The choice is published in the shared journal (AI_CONSENT event, always "G") so that
-- the editor's companion knows it: without explicit consent, this character's events
-- are never sent to the AI and their name is removed from other people's facts.
-- The latest choice (highest sequence) wins. Consent is on by default: a character who
-- never chose (no AI_CONSENT event, box never touched) is switched on and announced;
-- an explicit "no" is always kept.
local function lastConsent()
    local me, best = ns.Context.Me(), nil
    for _, ev in pairs(ns.db.events) do
        if ev.k == "AI_CONSENT" and ev.a == me and ev.vis == "G" and (not best or (ev.s or 0) > (best.s or 0)) then
            best = ev
        end
    end
    return best
end
Consent.LastConsent = lastConsent

local function publishConsent(value)
    if not ns.Context.GuildKey() then return nil end
    local last = lastConsent()
    if last and (last.p.ok and true or false) == value then return last end
    if not last and not value then return nil end -- never accepted: nothing to announce
    return ns.Store.Add("AI_CONSENT", { ok = value }, { vis = "G", prov = "MAN", noExp = true, loc = {} })
end

function Consent.SetConsent(value)
    value = value and true or false
    ns.char.exportConsent = value
    ns.char.consentChosen = true
    return publishConsent(value)
end

function Consent:OnLogin()
    -- Characters saved when the default was "no" and who never chose: default "yes".
    if not ns.char.consentChosen and not lastConsent() then ns.char.exportConsent = true end
    -- Choice made outside a guild, or default not announced yet: announce it now. At
    -- PLAYER_LOGIN the guild is often not known yet (GetGuildInfo answers nil): try again
    -- when the guild info arrives, until it goes through once.
    local announced = false
    local function announce()
        if announced or not ns.Context.GuildKey() then return end
        announced = true
        publishConsent(ns.char.exportConsent and true or false)
    end
    announce()
    ns:RegisterGameEvent("PLAYER_GUILD_UPDATE", announce)
    ns:RegisterGameEvent("GUILD_ROSTER_UPDATE", announce)
end
