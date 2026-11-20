-- Minimap.lua: the admin icon (minimap and addon compartment), distinct from the
-- members' book icon. Click: open the admin window. Tooltip: items waiting.
local _, A = ...
local R = A.R
local UI = R.UI
local Press = A.Press

local function tooltip()
    local lines = {}
    local n = #Press.Pending()
    if n > 0 then table.insert(lines, ("%d élément(s) de l'application en attente"):format(n)) end
    table.insert(lines, "Clic : ouvrir l'administration")
    table.insert(lines, "Glisser : déplacer")
    return "Renatus Admin", lines
end

local SPEC = {
    name = "RenatusAdminMinimapButton", icon = A.ICON, title = "Renatus Admin",
    compartmentTooltip = { "Clic : ouvrir l'administration" },
    onClick = function() A.Toggle() end,
    angle = function() return R.char.ui.adminMinimapAngle or 160 end,
    setAngle = function(a) R.char.ui.adminMinimapAngle = a end,
}

-- Gold glow on the icon while something waits for review.
function A.UpdateIcon()
    local b = A.minimapButton
    if not b then return end
    local n = #Press.Pending()
    b.icon:SetVertexColor(1, 1, n > 0 and 0.55 or 1)
end

R:RegisterGameEvent("PLAYER_LOGIN", function()
    if Minimap and UI.MinimapButton then
        A.minimapButton = UI.MinimapButton(SPEC)
        UI.Tooltip(A.minimapButton, tooltip)
        A.UpdateIcon()
    end
    if UI.CompartmentEntry then A.compartment = UI.CompartmentEntry(SPEC) end
    local n = #Press.Pending()
    if n > 0 then
        R.Print("%d élément(s) de Renatus Admin en attente : /radmin ou l'icône d'administration.", n)
    end
end)
