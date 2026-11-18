-- tests/wow_stub.lua : simulation minimale de l'API WoW pour les tests hors client.
-- Compatible Lua 5.1 a 5.4.
local Stub = {}

unpack = unpack or table.unpack

-- opts : { class, specIndex (nil = pas de GetSpecialization), specRole, groupRole,
--          unknownEvents = { NAME = true }, cvars = {}, savedAccount, savedChar }
function Stub.reset(opts)
    opts = opts or {}
    local S = {
        frames = {}, timers = {}, now = 0, played = {}, stopped = {},
        cvars = opts.cvars or { Sound_SFXVolume = "1" },
        inCombat = false, dead = false, randomValue = opts.randomValue or 0.99,
        printed = {},
    }
    Stub.state = S

    local unknown = opts.unknownEvents or {}

    function CreateFrame()
        local f = { events = {}, shown = true, scripts = {} }
        function f:RegisterEvent(e)
            if unknown[e] then error("Attempt to register unknown event \"" .. e .. "\"") end
            self.events[e] = true
        end
        function f:UnregisterEvent(e) self.events[e] = nil end
        function f:SetScript(name, fn) self.scripts[name] = fn end
        function f:Show() self.shown = true end
        function f:Hide() self.shown = false end
        function f:IsShown() return self.shown end
        table.insert(S.frames, f)
        return f
    end

    C_Timer = {
        After = function(delay, fn) table.insert(S.timers, { at = S.now + delay, fn = fn }) end,
    }
    function GetCVar(k) return S.cvars[k] end
    function SetCVar(k, v) S.cvars[k] = tostring(v) end
    function PlaySoundFile(path, channel)
        table.insert(S.played, { path = path, channel = channel })
        return true, #S.played
    end
    function StopSound(handle) table.insert(S.stopped, handle) end
    function InCombatLockdown() return S.inCombat end
    function UnitIsDeadOrGhost() return S.dead end
    function UnitClass() return opts.class or "Warrior", opts.class or "WARRIOR", 1 end
    if opts.specIndex ~= nil then
        function GetSpecialization()
            if opts.specIndex == "error" then error("no specs here") end
            return opts.specIndex
        end
        function GetSpecializationInfo() return 1, "spec", "", 0, opts.specRole or "DAMAGER" end
    else
        GetSpecialization, GetSpecializationInfo = nil, nil
    end
    function UnitGroupRolesAssigned() return opts.groupRole or "NONE" end
    function print(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        table.insert(S.printed, table.concat(parts, " "))
    end
    math.random = function(n)
        if n then return 1 end
        return S.randomValue
    end

    SlashCmdList = {}
    GuildChronicleDB = opts.savedAccount
    GuildChronicleCharDB = opts.savedChar
    GuildChronicle = nil
    return S
end

function Stub.fire(event, ...)
    for _, f in ipairs(Stub.state.frames) do
        if (f.events[event]) and f.scripts.OnEvent then
            f.scripts.OnEvent(f, event, ...)
        end
    end
end

-- Avance le temps : timers C_Timer et OnUpdate des frames visibles (pas de 0,1 s).
function Stub.advance(seconds)
    local S = Stub.state
    local target = S.now + seconds
    while S.now < target - 1e-9 do
        local step = math.min(0.1, target - S.now)
        S.now = S.now + step
        for _, f in ipairs(S.frames) do
            if f.shown and f.scripts.OnUpdate then f.scripts.OnUpdate(f, step) end
        end
        local due = {}
        for i = #S.timers, 1, -1 do
            if S.timers[i].at <= S.now + 1e-9 then
                table.insert(due, 1, S.timers[i])
                table.remove(S.timers, i)
            end
        end
        table.sort(due, function(a, b) return a.at < b.at end)
        for _, t in ipairs(due) do t.fn() end
    end
end

-- Charge l'addon dans l'ordre du TOC, puis ADDON_LOADED et PLAYER_LOGIN.
function Stub.loadAddon(root, name)
    local ns = {}
    local toc = assert(io.open(root .. "/" .. name .. ".toc"))
    for line in toc:lines() do
        line = line:gsub("\r", "")
        if line ~= "" and not line:match("^#") then
            local path = root .. "/" .. line:gsub("\\", "/")
            local chunk = assert(loadfile(path))
            chunk(name, ns)
        end
    end
    toc:close()
    Stub.fire("ADDON_LOADED", name)
    Stub.fire("PLAYER_LOGIN")
    return ns
end

return Stub
