-- UI/Minimap.lua: minimap button (click: open/close; drag: move).
local _, ns = ...
local UI = ns.UI

local M = ns:RegisterModule("Minimap", {})
UI.Minimap = M

local RADIUS = 80

local function place(button, angle)
    local rad = math.rad(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * RADIUS, math.sin(rad) * RADIUS)
end

function M:OnLogin()
    if not Minimap then return end
    local b = CreateFrame("Button", "RenatusMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then UI.Open("settings") else UI.Toggle() end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            ns.char.ui.minimapAngle = angle
            place(self, angle)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    UI.Tooltip(b, "Chronique de la Guilde", { "Clic gauche : ouvrir", "Clic droit : paramètres", "Glisser : déplacer" })
    self.button = b
    self:Update()
end

function M:Update()
    if not self.button then return end
    place(self.button, ns.char.ui.minimapAngle or 200)
    self.button:SetShown(ns.char.ui.showMinimap)
end
