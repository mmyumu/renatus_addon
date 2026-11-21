-- tests/wow_stub.lua: minimal WoW API simulation for out-of-client tests.
-- Compatible with Lua 5.1 to 5.4. Widgets accept any method (no-op by default)
-- and simulate the ones whose behaviour matters (scripts, texts, values, visibility).
local Stub = {}

unpack = unpack or table.unpack

local function noop() end

local Widget = {}
-- Unknown (Capitalized) methods: no-op. Unknown (lowercase) fields: nil, as in game.
-- Methods that only some widget types have: calling them elsewhere errors, as in game.
local ONLY_ON = {
    HasFocus = { EditBox = true }, SetFocus = { EditBox = true }, ClearFocus = { EditBox = true },
    SetMaxLetters = { EditBox = true }, SetAutoFocus = { EditBox = true }, SetMultiLine = { EditBox = true },
    SetChecked = { CheckButton = true }, GetChecked = { CheckButton = true },
}
local WidgetMeta = { __index = function(self, k)
    if ONLY_ON[k] and not ONLY_ON[k][rawget(self, "kind")] then return nil end
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

-- opts: { class, specIndex (nil = no GetSpecialization), specRole, groupRole,
--          unknownEvents = { NAME = true }, cvars = {}, savedAccount, savedChar, guild, mapID }
function Stub.reset(opts)
    opts = opts or {}
    local S = {
        frames = {}, timers = {}, now = 0, played = {}, stopped = {},
        cvars = opts.cvars or { Sound_SFXVolume = "1" },
        inCombat = false, dead = false, randomValue = opts.randomValue or 0.99,
        printed = {}, unknown = opts.unknownEvents or {},
        guild = opts.guild == nil and "Les Testeurs" or opts.guild,
        realm = opts.realm == nil and "Forever" or opts.realm,
        mapID = opts.mapID or 1429, zone = "Forêt d'Elwynn", level = 20,
        sent = {}, units = opts.units or {}, group = opts.group or {}, roster = opts.roster or {},
        instance = opts.instance, -- { type = "party", name = "Mortemines", iid = 36 }
        me = opts.me or { guid = "Player-1-ABC", name = "Testeur" },
        rank = opts.rank or 3,
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
        local u = S.units[unit]
        if u then return u.guid end
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
        if S.guild then return S.guild, "Membre", S.rank end
    end
    function GetNormalizedRealmName() return S.realm end
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
    -- opts.rosterPending: like the real client, the roster stays empty until requested.
    S.rosterLoaded = not opts.rosterPending
    S.rosterRequests = 0
    function GetNumGuildMembers() return S.rosterLoaded and #S.roster or 0 end
    C_GuildInfo = { GuildRoster = function()
        S.rosterRequests = S.rosterRequests + 1
        if not S.rosterLoaded then
            S.rosterLoaded = true
            C_Timer.After(0.5, function() Stub.fire("GUILD_ROSTER_UPDATE") end)
        end
    end }
    function GetGuildRosterInfo(i)
        local r = S.roster[i]
        -- r.full: WoW Forever "first last" name; r.guid: 17th value, as on recent clients.
        if r then
            return (r.full or r.name) .. "-Forever", "Membre", r.rank or 2, r.level or 20, "", "", "", "", true, 0,
                r.class or "WARRIOR", 0, 0, false, false, 0, r.guid
        end
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
    -- Midnight-based client (secret values) unless opts.classicLog: then no issecretvalue.
    issecretvalue = nil
    if not opts.classicLog then
        issecretvalue = function(v) return type(v) == "table" and v.secret == true end
    end
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

    -- Combat log (S.cleu = packed arguments of the current event), players by GUID, death recap.
    S.players = opts.players or {}
    function CombatLogGetCurrentEventInfo()
        local e = S.cleu or { n = 0 }
        return unpack(e, 1, e.n or #e)
    end
    function GetPlayerInfoByGUID(guid)
        local p = S.players[guid]
        if p then return p.cl, p.c, p.ra, p.raEn, 2, p.name, p.realm end
    end
    C_DeathRecap = nil
    if opts.recap then
        C_DeathRecap = { GetRecapEvents = function() return S.recap end }
    end

    Settings, AddonCompartmentFrame, SettingsPanel = nil, nil, nil
    CreateSettingsListSectionHeaderInitializer, CreateSettingsButtonInitializer = nil, nil
    InterfaceOptions_AddCategory = nil
    if opts.settingsApi then Stub.installSettingsApi(S) end
    if opts.compartment then
        S.compartment = {}
        AddonCompartmentFrame = { RegisterAddon = function(_, info) table.insert(S.compartment, info) end }
    end

    SlashCmdList = {}
    RenatusDB = opts.savedAccount
    RenatusCharDB = opts.savedChar
    Renatus = nil
    RenatusMainFrame = nil
    return S
end

-- Simplified Settings API (Retail 11.0+ signatures). S.settings records what the
-- addon registered: categories, settings (by variable), controls and buttons.
function Stub.installSettingsApi(S)
    local reg = { categories = {}, subcategories = {}, byVar = {}, controls = {}, buttons = {}, headers = {}, opened = nil }
    S.settings = reg
    local function newCategory(name, frame)
        local cat = { name = name, frame = frame, id = #reg.categories + 1 }
        function cat:GetID() return self.id end
        return cat
    end
    local function newLayout(cat)
        return { AddInitializer = function(_, init)
            if init.kind == "button" then table.insert(reg.buttons, init) else table.insert(reg.headers, init.text) end
        end }
    end
    local function control(kind)
        return function(category, setting, options, tooltip)
            table.insert(reg.controls, { kind = kind, setting = setting, options = options, category = category })
            if kind == "slider" and options and options.format then setting.formatted = options.format(setting:GetValue()) end
        end
    end
    Settings = {
        VarType = { Boolean = "boolean", Number = "number", String = "string" },
        RegisterVerticalLayoutCategory = function(name)
            local cat = newCategory(name)
            return cat, newLayout(cat)
        end,
        RegisterCanvasLayoutCategory = function(frame, name) return newCategory(name, frame) end,
        RegisterVerticalLayoutSubcategory = function(parent, name)
            local cat = newCategory(name)
            cat.parent = parent
            table.insert(reg.subcategories, cat)
            cat.id = 100 + #reg.subcategories
            return cat, newLayout(cat)
        end,
        RegisterCanvasLayoutSubcategory = function(parent, frame, name)
            local cat = newCategory(name, frame)
            cat.parent = parent
            table.insert(reg.subcategories, cat)
            cat.id = 100 + #reg.subcategories
            return cat
        end,
        CreateSlider = control("slider"),
        CreateSliderOptions = function(min, max, step)
            return { min = min, max = max, step = step, SetLabelFormatter = function(self, _, fn) self.format = fn end }
        end,
        RegisterAddOnCategory = function(cat) table.insert(reg.categories, cat) end,
        RegisterAddOnSetting = function(category, variable, key, tbl, varType, name, default)
            assert(not reg.byVar[variable], "variable deja enregistree : " .. variable)
            if tbl[key] == nil then tbl[key] = default end
            assert(type(tbl[key]) == varType, variable .. " : type " .. type(tbl[key]) .. " au lieu de " .. varType)
            local s = { variable = variable, name = name, default = default }
            function s:GetValue() return tbl[key] end
            function s:SetValue(v)
                tbl[key] = v
                if self.callback then self.callback(self, v) end
            end
            function s:SetValueChangedCallback(fn) self.callback = fn end
            reg.byVar[variable] = s
            return s
        end,
        CreateCheckbox = control("checkbox"),
        CreateDropdown = control("dropdown"),
        CreateControlTextContainer = function()
            local data = {}
            return {
                Add = function(_, value, label) table.insert(data, { value = value, label = label }) end,
                GetData = function() return data end,
            }
        end,
        OpenToCategory = function(id) reg.opened = id end,
    }
    function CreateSettingsListSectionHeaderInitializer(text) return { kind = "header", text = text } end
    function CreateSettingsButtonInitializer(name, text, onClick)
        return { kind = "button", name = name, text = text, onClick = onClick }
    end
    SettingsPanel = newWidget("Frame")
    SettingsPanel.shown = false
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

-- Advances time: C_Timer timers and OnUpdate of visible frames (0.1 s steps).
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

-- Combat log event (same arguments as CombatLogGetCurrentEventInfo).
function Stub.combatLog(...)
    Stub.state.cleu = { n = select("#", ...), ... }
    Stub.fire("COMBAT_LOG_EVENT_UNFILTERED")
end

-- Replays addon messages sent by another client (sender = "Name-Realm").
function Stub.deliver(messages, sender)
    for _, m in ipairs(messages) do
        Stub.fire("CHAT_MSG_ADDON", m.prefix, m.msg, m.channel, sender)
    end
end

-- Loads the addon in TOC order, then ADDON_LOADED and PLAYER_LOGIN.
local function runToc(root, name)
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
    return ns
end

-- Loads an addon, then optional dependent addons ({ { root, name }, ... }), like the
-- client: each addon's files, its ADDON_LOADED, then a single PLAYER_LOGIN.
-- Returns the first addon's namespace, then the others'.
function Stub.loadAddon(root, name, extras)
    local ns = runToc(root, name)
    Stub.fire("ADDON_LOADED", name)
    local others = {}
    for _, e in ipairs(extras or {}) do
        table.insert(others, runToc(e[1], e[2]))
        Stub.fire("ADDON_LOADED", e[2])
    end
    Stub.fire("PLAYER_LOGIN")
    return ns, table.unpack(others)
end

return Stub
