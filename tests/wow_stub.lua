-- tests/wow_stub.lua : simulation minimale de l'API WoW pour les tests hors client.
-- Compatible Lua 5.1 a 5.4. Les widgets acceptent n'importe quelle methode (no-op par defaut)
-- et simulent celles dont le comportement compte (scripts, textes, valeurs, visibilite).
local Stub = {}

unpack = unpack or table.unpack

local function noop() end

local Widget = {}
-- Methodes (Majuscule) inconnues : no-op. Champs (minuscule) inconnus : nil, comme en jeu.
local WidgetMeta = { __index = function(_, k)
    if Widget[k] then return Widget[k] end
    if type(k) == "string" and k:match("^%u") then return noop end
    return nil
end }

local function newWidget(kind, parent)
    local w = setmetatable({ kind = kind, parent = parent, events = {}, scripts = {}, shown = true,
        width = 100, height = 20, text = "", value = 0, checked = false, minV = 0, maxV = 0 }, WidgetMeta)
    table.insert(Stub.state.frames, w)
    return w
end
Stub.newWidget = newWidget

function Widget:RegisterEvent(e)
    if Stub.state.unknown[e] then error("Attempt to register unknown event \"" .. e .. "\"") end
    self.events[e] = true
end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:SetScript(name, fn) self.scripts[name] = fn end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:HookScript(name, fn)
    local old = self.scripts[name]
    self.scripts[name] = function(...) if old then old(...) end fn(...) end
end
function Widget:Show() self.shown = true end
function Widget:Hide()
    local was = self.shown
    self.shown = false
    if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Widget:IsShown() return self.shown end
function Widget:IsVisible() return self.shown end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:SetWidth(w) self.width = w end
function Widget:SetHeight(h) self.height = h end
function Widget:GetWidth() return self.width end
function Widget:GetHeight() return self.height end
function Widget:CreateTexture() return newWidget("Texture", self) end
function Widget:CreateFontString() return newWidget("FontString", self) end
function Widget:SetText(t)
    self.text = t
    if self.kind == "EditBox" and self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
end
function Widget:GetText() return self.text end
function Widget:SetFormattedText(fmt, ...) self.text = string.format(fmt, ...) end
function Widget:SetChecked(v) self.checked = v and true or false end
function Widget:GetChecked() return self.checked end
function Widget:SetMinMaxValues(a, b) self.minV, self.maxV = a, b end
function Widget:GetMinMaxValues() return self.minV, self.maxV end
function Widget:SetValue(v)
    self.value = v
    if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v, false) end
end
function Widget:GetValue() return self.value end
function Widget:GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
function Widget:GetStringHeight() return 14 end
function Widget:GetStringWidth() return 50 end
function Widget:GetVerticalScroll() return 0 end
function Widget:IsMouseOver() return false end
function Widget:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function Widget:GetCenter() return 0, 0 end
function Widget:GetEffectiveScale() return 1 end
function Widget:GetParent() return self.parent end
function Widget:GetName() return self.name end
function Widget:Click(button)
    if self.kind == "CheckButton" then self.checked = not self.checked end
    if self.scripts.OnClick then self.scripts.OnClick(self, button or "LeftButton") end
end

-- opts : { class, specIndex (nil = pas de GetSpecialization), specRole, groupRole,
--          unknownEvents = { NAME = true }, cvars = {}, savedAccount, savedChar, guild, mapID }
function Stub.reset(opts)
    opts = opts or {}
    local S = {
        frames = {}, timers = {}, now = 0, played = {}, stopped = {},
        cvars = opts.cvars or { Sound_SFXVolume = "1" },
        inCombat = false, dead = false, randomValue = opts.randomValue or 0.99,
        printed = {}, unknown = opts.unknownEvents or {},
        guild = opts.guild == nil and "Les Testeurs" or opts.guild,
        mapID = opts.mapID or 1429, zone = "Forêt d'Elwynn", level = 20,
        sent = {}, units = opts.units or {}, group = opts.group or {}, roster = opts.roster or {},
        instance = opts.instance, -- { type = "party", name = "Mortemines", iid = 36 }
        me = opts.me or { guid = "Player-1-ABC", name = "Testeur" },
    }
    Stub.state = S

    function CreateFrame(frameType, name, parent)
        local w = newWidget(frameType, parent)
        if name then w.name = name; _G[name] = w end
        return w
    end
    UIParent = newWidget("Frame")
    Minimap = newWidget("Frame")
    GameTooltip = newWidget("GameTooltip")
    UISpecialFrames = {}
    function GetCursorPosition() return 0, 0 end
    function IsMouseButtonDown() return false end
    PlaySound, SOUNDKIT = nil, nil
    RAID_CLASS_COLORS, CLASS_ICON_TCOORDS = nil, nil

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
    local function groupUnit(unit)
        local i = unit and tonumber(unit:match("^party(%d+)$") or unit:match("^raid(%d+)$") or "")
        return i and S.group[i]
    end
    function UnitClass(unit)
        local u = S.units[unit]
        if u then return u.class, u.class, 1 end
        return "Guerrier", opts.class or "WARRIOR", 1
    end
    function UnitGUID(unit)
        if unit == "player" then return S.me.guid end
        local g = groupUnit(unit)
        if g then return g.guid end
    end
    function UnitName(unit)
        if unit == "player" then return S.me.name end
        local g = groupUnit(unit)
        if g then return g.name end
        local u = S.units[unit]
        if u then return u.name, u.realm end
    end
    function UnitLevel(unit)
        local u = S.units[unit]
        if u then return u.level end
        return S.level
    end
    function UnitExists(unit) return unit == "player" or S.units[unit] ~= nil or groupUnit(unit) ~= nil end
    function UnitIsPlayer(unit) local u = S.units[unit]; return u and u.player ~= false or false end
    function UnitRace(unit) local u = S.units[unit]; if u then return u.race end return "Humain" end
    function UnitIsPVP(unit) local u = S.units[unit]; return u and u.pvp or false end
    function UnitIsGroupLeader(unit)
        if unit == "player" then return S.leader == true end
        local g = groupUnit(unit)
        return g and g.leader or false
    end
    function GetTime() return S.now end
    if opts.specIndex ~= nil then
        function GetSpecialization()
            if opts.specIndex == "error" then error("no specs here") end
            return opts.specIndex
        end
        function GetSpecializationInfo() return opts.specID or 1, "spec", "", 0, opts.specRole or "DAMAGER" end
    else
        GetSpecialization, GetSpecializationInfo = nil, nil
    end
    function UnitGroupRolesAssigned() return opts.groupRole or "NONE" end
    function IsInGuild() return S.guild ~= false end
    function GetGuildInfo(unit)
        if unit and unit ~= "player" then
            local u = S.units[unit]
            return u and u.guild
        end
        if S.guild then return S.guild, "Membre", 3 end
    end
    function GetNormalizedRealmName() return "Forever" end
    function GetRealZoneText() return S.zone end
    function GetSubZoneText() return "" end
    function IsInInstance()
        if S.instance then return true, S.instance.type end
        return false, "none"
    end
    function GetInstanceInfo()
        local i = S.instance
        if i then return i.name, i.type, 1, "Normal", 5, 0, false, i.iid end
        return S.zone, "none", 0, "", 0, 0, false, 0
    end
    function IsInRaid() return false end
    function IsInGroup() return #S.group > 0 end
    function GetNumGroupMembers() return #S.group > 0 and (#S.group + 1) or 0 end
    function GetNumGuildMembers() return #S.roster end
    function GetGuildRosterInfo(i)
        local r = S.roster[i]
        if r then return r.name .. "-Forever", "Membre", r.rank or 2, r.level or 20, "", "", "", "", true, 0, r.class or "WARRIOR" end
    end
    C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix) S.prefix = prefix; return true end,
        SendAddonMessage = function(prefix, msg, channel)
            assert(#msg <= 255, "message d'addon trop long : " .. #msg)
            table.insert(S.sent, { prefix = prefix, msg = msg, channel = channel })
            return 0
        end,
    }
    C_Map = {
        GetBestMapForUnit = function() return S.mapID end,
        GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.25 end } end,
    }
    C_QuestLog = { GetTitleForQuestID = function(id) return "Quête " .. id end }
    issecretvalue = function(v) return type(v) == "table" and v.secret == true end
    function GetServerTime() return 1795000000 + math.floor(S.now) end
    time = os.time
    date = os.date
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
    GuildChronicleMainFrame = nil
    return S
end

function Stub.fire(event, ...)
    local frames = {}
    for _, f in ipairs(Stub.state.frames) do frames[#frames + 1] = f end
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then
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
            if f.shown and f.scripts.OnUpdate and f.kind ~= "Texture" then f.scripts.OnUpdate(f, step) end
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

-- Rejoue les messages d'addon emis par un autre client (sender = "Nom-Royaume").
function Stub.deliver(messages, sender)
    for _, m in ipairs(messages) do
        Stub.fire("CHAT_MSG_ADDON", m.prefix, m.msg, m.channel, sender)
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
