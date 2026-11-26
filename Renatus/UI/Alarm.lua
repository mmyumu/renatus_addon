-- UI/Alarm.lua: alarm when a member of the rival guild comes into view.
--   * a banner at the top of the screen ("Rival en vue : Gorbash, Guerrier 25") and a
--     warning sound, for the player who sees them; nothing is sent to anyone;
--   * fed by Collectors/Enemies.lua (target, mouseover, nameplates) through the
--     ENEMY_SPOTTED topic of the event bus;
--   * one alarm per enemy every COOLDOWN seconds; enemies spotted while the banner is
--     shown join it ("3 rivaux en vue") and the sound plays at most once per SOUND_GAP;
--   * never in battlegrounds and arenas (the game picks the opponents there);
--   * everything can be turned off in the options (ns.char.alarm.enabled), the sound alone too.
-- Trial mode (/renatus alarme essai, this session only): any enemy player triggers it, to
-- test the alarm in the field without meeting the rival guild.
local _, ns = ...
local UI = ns.UI

local A = ns:RegisterModule("Alarm", {})
UI.Alarm = A
ns.Alarm = A

A.COOLDOWN = 300
A.SHOW_TIME = 8
A.FADE_TIME = 1
A.SOUND_GAP = 10
A.MAX_NAMES = 3
A.trial = false

local lastAlarm = {}   -- [name] = GetTime() of its last alarm (memory only)
local lastSound
local shown = {}       -- enemies on the banner, in order of arrival

local function clock() return GetTime and GetTime() or 0 end

local function settings() return ns.char.alarm end

local function inPvPInstance()
    local inside, kind = ns.Try(IsInInstance)
    return inside and (kind == "pvp" or kind == "arena") or false
end

-- "Gorbash, Guerrier 25" in class colour; the guild of an enemy who is not a rival.
local function describe(info)
    local text = UI.ClassName(info.name, info.class)
    local what = {}
    if info.className then what[#what + 1] = info.className end
    if info.level then what[#what + 1] = tostring(info.level) end
    if #what > 0 then text = text .. ", " .. table.concat(what, " ") end
    if not info.rival and info.guild then text = text .. " <" .. info.guild .. ">" end
    return text
end

-- Title and text of the banner for a list of enemies.
function A.Lines(list)
    local rivals = 0
    for _, info in ipairs(list) do if info.rival then rivals = rivals + 1 end end
    local title
    if rivals == 0 then
        title = #list > 1 and (#list .. " ennemis en vue (essai)") or "Ennemi en vue (essai)"
    else
        title = #list > 1 and (#list .. " rivaux en vue") or "Rival en vue"
    end
    local parts = {}
    for i = 1, math.min(#list, A.MAX_NAMES) do parts[#parts + 1] = describe(list[i]) end
    local text = table.concat(parts, "\n")
    if #list > A.MAX_NAMES then text = text .. ("\net %d autre(s)"):format(#list - A.MAX_NAMES) end
    return title, text
end

local function build()
    local f = CreateFrame("Button", "RenatusAlarmBanner", UIParent)
    f:SetSize(360, 64)
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(true)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnClick", function(self) self:Hide() end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.02, 0.02, 0.82)
    for _, side in ipairs({ "TOP", "BOTTOM" }) do
        local line = f:CreateTexture(nil, "BORDER")
        line:SetHeight(2)
        line:SetPoint(side .. "LEFT")
        line:SetPoint(side .. "RIGHT")
        line:SetColorTexture(UI.C.red[1], UI.C.red[2], UI.C.red[3], 1)
    end

    f.title = UI.Title(f, 20, { 1, 0.3, 0.2 })
    f.title:SetPoint("TOP", 0, -8)
    f.title:SetJustifyH("CENTER")
    f.text = UI.Text(f, 13)
    f.text:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
    f.text:SetJustifyH("CENTER")

    f:SetScript("OnUpdate", function(self)
        local age = clock() - (self.since or 0)
        if age >= A.SHOW_TIME then self:Hide() return end
        local left = A.SHOW_TIME - age
        self:SetAlpha(left < A.FADE_TIME and left / A.FADE_TIME or 1)
    end)
    f:SetScript("OnHide", function() shown = {} end)
    f:Hide()
    return f
end

function A.Banner()
    A.frame = A.frame or build()
    return A.frame
end

local function playSound(force)
    if not (force or settings().sound) then return end
    local t = clock()
    if not force and lastSound and t - lastSound < A.SOUND_GAP then return end
    lastSound = t
    if PlaySound then
        local id = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
        pcall(PlaySound, id, "Master")
    end
end

-- Shows info on the banner (joins the enemies already on it), with the sound.
function A.Show(info, force)
    local f = A.Banner()
    if not f:IsShown() then shown = {} end
    local found = false
    for i, other in ipairs(shown) do
        if other.name == info.name then shown[i] = info; found = true end
    end
    if not found then shown[#shown + 1] = info end
    local title, text = A.Lines(shown)
    f.title:SetText(title)
    f.text:SetText(text)
    f:SetHeight(40 + 16 * math.min(#shown + (#shown > A.MAX_NAMES and 1 or 0), A.MAX_NAMES + 1))
    f.since = clock()
    f:SetAlpha(1)
    f:Show()
    A.lastTitle, A.lastText = title, text
    playSound(force)
end

-- An enemy player came into view: info = { name, guild, level, class, className, rival }.
-- Returns true when it raised the alarm.
function A.Spot(info)
    if type(info) ~= "table" or type(info.name) ~= "string" then return false end
    if not settings().enabled then return false end
    if not (info.rival or A.trial) then return false end
    if inPvPInstance() then return false end
    local t = clock()
    if lastAlarm[info.name] and t - lastAlarm[info.name] < A.COOLDOWN then return false end
    lastAlarm[info.name] = t
    A.Show(info)
    return true
end

-- A fake rival, to see and hear the alarm (works even when it is turned off).
function A.Test()
    local className, class = ns.Try(UnitClass, "player")
    A.Show({ name = "Gorbash", className = className or "Guerrier", class = class or "WARRIOR",
        level = ns.Try(UnitLevel, "player"), rival = true }, true)
end

function A.SetTrial(on)
    A.trial = on and true or false
    lastAlarm = {}
end

function A:OnLogin()
    ns.EventBus.Subscribe("ENEMY_SPOTTED", A.Spot)
end
