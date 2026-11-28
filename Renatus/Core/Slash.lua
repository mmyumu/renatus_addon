-- Core/Slash.lua: /renatus (and /renacoach as a shortcut to the voice settings).
local _, ns = ...

local function onOff(v) return v and "|cff40ff40on|r" or "|cffff4040off|r" end

local function voiceStatus()
    local s = ns.char.voice
    local v = ns.Voice
    ns.Print("Renacoach %s | proba %.2f toutes les %ss | canal %s | ducking %s (%.2f)",
        onOff(s.enabled), s.probability, tostring(s.interval), s.channel, onOff(s.duck), s.duckVolume)
    ns.Print("role : %s, type : %s, familles en combat : %s",
        tostring(v.role), tostring(v.characterType), table.concat(v:GetCombatFamilies(), ", "))
    local off = {}
    for family in pairs(v.FAMILIES) do
        if s.families[family] == false then table.insert(off, family) end
    end
    if #off > 0 then ns.Print("familles coupees : %s", table.concat(off, ", ")) end
end

local function voiceHelp()
    ns.Print("/renatus voice on|off|status|test")
    ns.Print("/renatus voice prob <0-1> | interval <secondes> | channel <Ambience|Master|SFX|Dialog>")
    ns.Print("/renatus voice duck on|off | family <nom> on|off")
end

local function voiceCommand(args)
    local cmd, rest = args:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    local s = ns.char.voice
    if cmd == "on" or cmd == "off" then
        ns.Voice:SetEnabled(cmd == "on")
        voiceStatus()
    elseif cmd == "" or cmd == "status" then
        voiceStatus()
    elseif cmd == "test" then
        -- The last line heard in combat (else the sample one), never a random one.
        local _, name = ns.Voice:PlaySample()
        ns.Print("test : %s", tostring(name))
    elseif cmd == "prob" then
        local p = tonumber(rest)
        if p and p >= 0 and p <= 1 then s.probability = p; voiceStatus() else voiceHelp() end
    elseif cmd == "interval" then
        local n = tonumber(rest)
        if n and n >= 1 then s.interval = n; voiceStatus() else voiceHelp() end
    elseif cmd == "channel" then
        local valid = { Ambience = true, Master = true, SFX = true, Dialog = true, Music = true }
        if valid[rest] then s.channel = rest; voiceStatus() else voiceHelp() end
    elseif cmd == "duck" then
        s.duck = rest:lower() == "on"
        if not s.duck then ns.Voice.RestoreVolume(true) end
        voiceStatus()
    elseif cmd == "family" then
        local family, state = rest:match("^(%S+)%s+(%S+)$")
        if family and ns.Voice.FAMILIES[family] and (state == "on" or state == "off") then
            s.families[family] = state == "on"
            voiceStatus()
        else
            local names = {}
            for name in pairs(ns.Voice.FAMILIES) do table.insert(names, name) end
            table.sort(names)
            ns.Print("familles : %s", table.concat(names, ", "))
        end
    else
        voiceHelp()
    end
end

-- /renatus sync: state, gaps, debugging trace.
local function syncCommand(args)
    local cmd, rest = args:match("^(%S*)%s*(.-)$")
    cmd, rest = (cmd or ""):lower(), (rest or ""):lower()
    local tr = ns.db.monitor.trace
    if cmd == "trace" and (rest == "on" or rest == "off") then
        tr.on = rest == "on"
        ns.Print("trace de synchro %s (%d entrées). Fais /reload pour l'écrire sur le disque.", onOff(tr.on), #tr.entries)
    elseif cmd == "trace" and rest == "clear" then
        tr.entries = {}
        ns.Print("trace de synchro vidée")
    elseif cmd == "now" then
        ns.Sync.SendVector(true)
        ns.Print("synchro relancée : %d trou(s) redemandé(s)", ns.Sync.RequestGaps())
    elseif cmd == "" or cmd == "status" then
        local st = ns.Sync.Status()
        ns.Print("envoi %s%s | file %d | reçus %d | rejetés %d | trace %s (%d)",
            onOff(st.canSend), st.reason and (" (" .. st.reason .. ")") or "", st.queue,
            st.received, st.rejected, onOff(tr.on), #tr.entries)
        local CLASS_LABEL = { essential = "réglages et catalogue", gazette = "gazette et guilde rivale",
            ledger = "boosters et échanges", recent = "derniers jours" }
        if st.catchup then
            ns.Print("rattrapage en cours avec %s : %s%s", tostring(st.catchup.peer),
                CLASS_LABEL[st.catchup.class] or tostring(st.catchup.class),
                st.catchup.expect and (" (%d/%d)"):format(st.catchup.got or 0, st.catchup.expect) or "")
        end
        for author, info in pairs(ns.Sync.Vector()) do
            if info.top > info.max then
                local last = ns.db.events[author .. ":" .. info.top]
                ns.Print("trou : %s, tout jusqu'au n° %d, connu jusqu'au n° %d",
                    last and last.n or author, info.max, info.top)
            end
        end
    else
        ns.Print("/renatus sync [status] | now | trace on|off|clear")
    end
end

-- /renatus alarme: rival guild alarm (UI/Alarm.lua).
local function alarmCommand(args)
    local cmd, rest = args:match("^(%S*)%s*(.-)$")
    cmd, rest = (cmd or ""):lower(), (rest or ""):lower()
    local s = ns.char.alarm
    local function status()
        local rival = ns.GuildConfig.Rival()
        ns.Print("alarme %s | son %s | essai %s | guilde rivale : %s", onOff(s.enabled), onOff(s.sound),
            onOff(ns.Alarm.trial), rival or "aucune")
    end
    if cmd == "on" or cmd == "off" then
        s.enabled = cmd == "on"
        status()
    elseif cmd == "son" and (rest == "on" or rest == "off") then
        s.sound = rest == "on"
        status()
    elseif cmd == "test" then
        ns.Alarm.Test()
        if not s.enabled then ns.Print("(test seulement : l'alarme est désactivée)") end
    elseif cmd == "essai" then
        ns.Alarm.SetTrial(not ns.Alarm.trial)
        ns.Print(ns.Alarm.trial and "mode essai on : tout joueur ennemi déclenche l'alarme, jusqu'à /renatus alarme essai ou /reload."
            or "mode essai off : seule la guilde rivale déclenche l'alarme.")
        if ns.Alarm.trial and not s.enabled then ns.Print("attention : l'alarme est désactivée (/renatus alarme on)") end
    elseif cmd == "" or cmd == "status" then
        status()
    else
        ns.Print("/renatus alarme [status] | on|off | son on|off | test | essai")
    end
end

SLASH_RENATUS1 = "/renatus"
SlashCmdList.RENATUS = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "voice" then
        voiceCommand(rest)
    elseif cmd == "sync" then
        syncCommand(rest)
    elseif cmd == "alarme" or cmd == "alarm" then
        alarmCommand(rest)
    elseif cmd == "demo" then
        ns.char.ui.demo = not ns.char.ui.demo
        ns.Print("mode démo %s", onOff(ns.char.ui.demo))
        ns.UI.Open()
        ns.UI.Refresh()
    elseif cmd == "options" then
        ns.UI.Options.Open()
    elseif cmd == "help" then
        ns.Print("/renatus : ouvrir la fenêtre")
        ns.Print("/renatus options : réglages (aussi dans Échap > Options > AddOns > Renatus)")
        ns.Print("/renatus voice ... : réglages de Renacoach (aussi /renacoach)")
        ns.Print("/renatus sync [now | trace on|off|clear] : état de la synchro, diagnostic")
        ns.Print("/renatus alarme [on|off | son on|off | test | essai] : alarme guilde rivale")
    elseif cmd == "" then
        ns.UI.Toggle()
    else
        local keys = { journal = true, guild = true, members = true, wanted = true, gazette = true, album = true, settings = true, voice = true }
        if keys[cmd] then ns.UI.Open(cmd) else ns.Print("commande inconnue, tape /renatus help") end
    end
end

SLASH_RENACOACH1 = "/renacoach"
SlashCmdList.RENACOACH = function(msg) voiceCommand(msg or "") end
