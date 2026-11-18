-- Core/Slash.lua : /renatus (et /renacoach comme raccourci vers les reglages vocaux).
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
        if not s.enabled then ns.Print("active d'abord le module : /renatus voice on") return end
        local pool = ns.Voice:GetCombatFamilies()
        local _, name = ns.Voice:PlayFamilies(pool)
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

SLASH_RENATUS1 = "/renatus"
SlashCmdList.RENATUS = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "voice" then
        voiceCommand(rest)
    elseif cmd == "demo" then
        ns.char.ui.demo = not ns.char.ui.demo
        ns.Print("mode démo %s", onOff(ns.char.ui.demo))
        ns.UI.Open()
        ns.UI.Refresh()
    elseif cmd == "help" then
        ns.Print("/renatus : ouvrir la fenêtre")
        ns.Print("/renatus demo : afficher des données fictives (rien n'est sauvegardé)")
        ns.Print("/renatus voice ... : réglages de Renacoach (aussi /renacoach)")
    elseif cmd == "" then
        ns.UI.Toggle()
    else
        local keys = { journal = true, guild = true, members = true, wanted = true, gazette = true, album = true, settings = true }
        if keys[cmd] then ns.UI.Open(cmd) else ns.Print("commande inconnue, tape /renatus help") end
    end
end

SLASH_RENACOACH1 = "/renacoach"
SlashCmdList.RENACOACH = function(msg) voiceCommand(msg or "") end
