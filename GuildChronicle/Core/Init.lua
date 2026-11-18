-- Core/Init.lua : namespace, cycle de vie des modules, inscription prudente aux evenements WoW.
local ADDON, ns = ...

ns.name = ADDON
ns.version = "0.1.0"
ns.modules = {}
ns.moduleOrder = {}

local function printf(fmt, ...)
    print("|cffd4a017Guild Chronicle|r " .. string.format(fmt, ...))
end
ns.Print = printf

-- Un module = table avec OnInitialize(ns) (apres chargement des SavedVariables)
-- et OnLogin(ns) (PLAYER_LOGIN, API du personnage disponibles).
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

-- Dispatcher d'evenements WoW. L'inscription passe par pcall : sur WoW Forever,
-- un evenement absent ou interdit ne doit jamais empecher l'addon de charger.
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

-- Seule globale exposee : l'API publique (abonnement au journal, etc.).
GuildChronicle = { ns = ns }
