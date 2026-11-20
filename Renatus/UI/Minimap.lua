-- UI/Minimap.lua: ways to open the addon besides /renatus.
--   * minimap button (left click: open/close; right click: settings; drag: move);
--   * entry in the Retail addon compartment (the "addons" button next to the minimap).
local _, ns = ...
local UI = ns.UI

local M = ns:RegisterModule("Minimap", {})
UI.Minimap = M

M.ICON = "Interface\\Icons\\INV_Misc_Book_09"

-- Distance from the minimap centre: on its edge, whatever its size
-- (about 140 px on Classic clients, about 200 px on Retail-based ones like Forever).
local function radius()
    local w = Minimap and Minimap:GetWidth() or 0
    if not w or w <= 0 then w = 140 end
    return w / 2 + 5
end

local function place(button, angle)
    local rad = math.rad(angle)
    local r = radius()
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

local function onClick(button)
    if button == "RightButton" then UI.Options.Open() else UI.Toggle() end
end
M.OnClick = onClick

local TOOLTIP = { "Clic gauche : ouvrir", "Clic droit : options", "Glisser : déplacer" }

-- Minimap button, also used by Renatus_Admin for its own icon.
-- spec = { name, icon, title, tooltip = { lines }, onClick(button), angle() -> degrees, setAngle(degrees) }
function UI.MinimapButton(spec)
    local b = CreateFrame("Button", spec.name, Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture(spec.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.icon = icon
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:SetScript("OnClick", function(_, button) spec.onClick(button) end)
    b:SetScript("OnDragStart", function(btn)
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            spec.setAngle(angle)
            place(btn, angle)
        end)
    end)
    b:SetScript("OnDragStop", function(btn) btn:SetScript("OnUpdate", nil) end)
    UI.Tooltip(b, spec.title, spec.tooltip)
    function b:Place() place(self, spec.angle()) end
    -- The minimap can be resized by the game or by other addons: stay on its edge.
    if Minimap.HookScript then
        Minimap:HookScript("OnSizeChanged", function() if b:IsShown() then b:Place() end end)
    end
    b:Place()
    return b
end

-- Retail addon compartment entry (absent on clients without it). Returns true if registered.
function UI.CompartmentEntry(spec)
    if not (AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon) then return nil end
    return pcall(AddonCompartmentFrame.RegisterAddon, AddonCompartmentFrame, {
        text = spec.title,
        icon = spec.icon,
        notCheckable = true,
        registerForAnyClick = true,
        func = function(_, input, _, _, mouseButton)
            -- The click button is passed in different positions depending on the client version.
            local button = type(input) == "table" and input.buttonName or mouseButton
            spec.onClick(button)
        end,
        funcOnEnter = function(owner)
            if not GameTooltip then return end
            GameTooltip:SetOwner(owner or UIParent, "ANCHOR_LEFT")
            GameTooltip:SetText(spec.title)
            for _, line in ipairs(spec.compartmentTooltip or spec.tooltip or {}) do GameTooltip:AddLine(line, 1, 1, 1) end
            GameTooltip:Show()
        end,
        funcOnLeave = function() if GameTooltip then GameTooltip:Hide() end end,
    }) or nil
end

local SPEC = {
    name = "RenatusMinimapButton", icon = M.ICON, title = "Renatus", tooltip = TOOLTIP,
    compartmentTooltip = { TOOLTIP[1], TOOLTIP[2] },
    onClick = function(button) onClick(button) end,
    angle = function() return ns.char.ui.minimapAngle or 200 end,
    setAngle = function(a) ns.char.ui.minimapAngle = a end,
}

function M:OnLogin()
    if Minimap then self.button = UI.MinimapButton(SPEC) end
    self.compartment = UI.CompartmentEntry(SPEC)
    self:Update()
end

function M:Update()
    if not self.button then return end
    self.button:Place()
    self.button:SetShown(ns.char.ui.showMinimap)
end
