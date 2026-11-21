-- Core/Init.lua: namespace, module lifecycle, cautious registration to WoW events.
local ADDON, ns = ...

ns.name = ADDON
ns.version = "0.12.0-test.8"
ns.modules = {}
ns.moduleOrder = {}

local function printf(fmt, ...)
    print("|cffd4a017Renatus|r " .. string.format(fmt, ...))
end
ns.Print = printf

-- A module = table with OnInitialize(ns) (after SavedVariables are loaded)
-- and OnLogin(ns) (PLAYER_LOGIN, character APIs available).
function ns:RegisterModule(name, module)
    assert(not self.modules[name], "module deja enregistre : " .. name)
    module.name = name
    self.modules[name] = module
    table.insert(self.moduleOrder, name)
    return module
end

local function callModules(method)
    for _, name in ipairs(ns.moduleOrder) do
        local module = ns.modules[name]
        if module[method] then
            local ok, err = pcall(module[method], module, ns)
            if not ok then
                printf("erreur dans %s:%s : %s", name, method, tostring(err))
            end
        end
    end
end

-- WoW event dispatcher. Registration goes through pcall: on WoW Forever,
-- a missing or forbidden event must never prevent the addon from loading.
local eventFrame = CreateFrame("Frame")
local handlers = {}
ns.unsupportedEvents = {}

function ns:RegisterGameEvent(event, handler)
    if not handlers[event] then
        local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then
            ns.unsupportedEvents[event] = true
            return false
        end
        handlers[event] = {}
    end
    table.insert(handlers[event], handler)
    return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        eventFrame:UnregisterEvent("ADDON_LOADED")
        ns.Settings:Load()
        callModules("OnInitialize")
        return
    end
    if event == "PLAYER_LOGIN" then
        callModules("OnLogin")
    end
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok then
            printf("erreur sur %s : %s", event, tostring(err))
        end
    end
end)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

-- Only exposed global: the public API (journal subscription, etc.).
Renatus = { ns = ns }
