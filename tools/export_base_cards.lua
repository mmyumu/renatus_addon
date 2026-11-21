-- tools/export_base_cards.lua: the base card set (Renatus/Core/Cards.lua) as JSON, for the
-- admin app's editor (admin/core/src/base_cards.json, read by admin/core/src/revise.rs).
-- Each card is written as a CARD_SET entry (id, no, s, r, n, f, ic, fo, en, it, npc).
-- Run from the repository root after changing Cards.lua:  lua tools/export_base_cards.lua
-- (tests/run.lua fails while the file is out of date).
local Export = { OUT = "admin/core/src/base_cards.json" }

local function quote(s)
    s = s:gsub('[%c"\\]', function(ch)
        if ch == '"' then return '\\"' elseif ch == "\\" then return "\\\\"
        elseif ch == "\n" then return "\\n" end
        return ("\\u%04x"):format(ch:byte())
    end)
    return '"' .. s .. '"'
end

local KEYS = { "id", "no", "s", "r", "n", "f", "ic", "fo", "en", "it", "npc" }

local function encode(entry)
    local parts = {}
    for _, k in ipairs(KEYS) do
        local v = entry[k]
        if v ~= nil then
            local text = type(v) == "string" and quote(v) or tostring(v)
            parts[#parts + 1] = quote(k) .. ": " .. text
        end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

function Export.Json()
    local ns = {}
    assert(loadfile("Renatus/Core/Cards.lua"))("Renatus", ns)
    local lines = {}
    for _, c in ipairs(ns.Cards.LIST) do
        lines[#lines + 1] = "    " .. encode({
            id = c.id, no = c.no, s = c.series, r = c.rarity, n = c.name, f = c.flavor,
            ic = c.icons and c.icons[1], fo = c.fo, en = c.en, it = c.item and true or nil, npc = c.npc,
        })
    end
    return ('{\n  "date": %d,\n  "cards": [\n%s\n  ]\n}\n'):format(ns.Cards.BASE_DATE, table.concat(lines, ",\n"))
end

if arg and arg[0] and arg[0]:match("export_base_cards%.lua$") then
    local f = assert(io.open(Export.OUT, "w"))
    f:write(Export.Json())
    f:close()
    print(Export.OUT)
end

return Export
