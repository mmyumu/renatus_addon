-- Core/EventBus.lua: internal publish/subscribe between modules.
-- A failing subscriber does not prevent the others from receiving the event.
local _, ns = ...

local EventBus = {}
ns.EventBus = EventBus

local subscribers = {}

function EventBus.Subscribe(topic, fn)
    assert(type(fn) == "function", "Subscribe : fonction attendue")
    subscribers[topic] = subscribers[topic] or {}
    table.insert(subscribers[topic], fn)
    return fn
end

function EventBus.Unsubscribe(topic, fn)
    local list = subscribers[topic]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

function EventBus.Publish(topic, ...)
    local list = subscribers[topic]
    if not list then return 0 end
    -- copy: a subscriber may unsubscribe during dispatch
    local snapshot = { unpack(list) }
    for i = 1, #snapshot do
        local ok, err = pcall(snapshot[i], ...)
        if not ok and ns.Print then
            ns.Print("erreur d'un abonne a %s : %s", tostring(topic), tostring(err))
        end
    end
    return #snapshot
end

Renatus.Subscribe = EventBus.Subscribe
Renatus.Unsubscribe = EventBus.Unsubscribe
