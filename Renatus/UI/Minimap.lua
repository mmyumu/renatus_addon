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

local function createButton(self)
    local b = CreateFrame("Button", "RenatusMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture(M.ICON)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:SetScript("OnClick", function(_, button) onClick(button) end)
    b:SetScript("OnDragStart", function(btn)
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            ns.char.ui.minimapAngle = angle
            place(btn, angle)
        end)
    end)
    b:SetScript("OnDragStop", function(btn) btn:SetScript("OnUpdate", nil) end)
    UI.Tooltip(b, "Renatus", TOOLTIP)
    -- The minimap can be resized by the game or by other addons: stay on its edge.
    if Minimap.HookScript then
        Minimap:HookScript("OnSizeChanged", function() self:Update() end)
    end
    self.button = b
end

-- Retail addon compartment. Registered at runtime (no global function needed);
-- absent on clients without it.
local function registerCompartment(self)
    if not (AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon) then return end
    local ok = pcall(AddonCompartmentFrame.RegisterAddon, AddonCompartmentFrame, {
        text = "Renatus",
        icon = M.ICON,
        notCheckable = true,
        registerForAnyClick = true,
        func = function(_, input, _, _, mouseButton)
            -- The click button is passed in different positions depending on the client version.
            local button = type(input) == "table" and input.buttonName or mouseButton
            onClick(button)
        end,
        funcOnEnter = function(owner)
            if not GameTooltip then return end
            GameTooltip:SetOwner(owner or UIParent, "ANCHOR_LEFT")
            GameTooltip:SetText("Renatus")
            for _, line in ipairs({ TOOLTIP[1], TOOLTIP[2] }) do GameTooltip:AddLine(line, 1, 1, 1) end
            GameTooltip:Show()
        end,
        funcOnLeave = function() if GameTooltip then GameTooltip:Hide() end end,
    })
    self.compartment = ok
end

function M:OnLogin()
    if Minimap then createButton(self) end
    registerCompartment(self)
    self:Update()
end

function M:Update()
    if not self.button then return end
    place(self.button, ns.char.ui.minimapAngle or 200)
    self.button:SetShown(ns.char.ui.showMinimap)
end
