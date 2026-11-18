-- Sync/Serialize.lua : (de)serialisation compacte de tables Lua pour les messages d'addon.
-- Sans dependance externe. Format :
--   s<texte>;   chaine (~XX = octet echappe : controles, '~' et ';')
--   n<nombre>;  nombre
--   T / F       booleens
--   { cle valeur cle valeur ... }   table
-- Le decodeur est defensif : profondeur, nombre d'elements et taille bornes ; nil si invalide.
local _, ns = ...

local Ser = {}
ns.Serialize = Ser

local MAX_DEPTH, MAX_ITEMS = 8, 4000

local function escape(s)
    return (s:gsub("[%c~;\127]", function(c) return ("~%02X"):format(c:byte()) end))
end

local function unescape(s)
    return (s:gsub("~(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function encode(v, out, depth)
    local tv = type(v)
    if tv == "string" then
        out[#out + 1] = "s" .. escape(v) .. ";"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("nombre non serialisable") end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            out[#out + 1] = ("n%d;"):format(v)
        else
            out[#out + 1] = ("n%.14g;"):format(v)
        end
    elseif tv == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif tv == "table" then
        if depth >= MAX_DEPTH then error("table trop profonde") end
        out[#out + 1] = "{"
        -- ordre stable : partie tableau puis cles triees (messages identiques d'un client a l'autre)
        local n = #v
        for i = 1, n do
            encode(i, out, depth + 1)
            encode(v[i], out, depth + 1)
        end
        local keys = {}
        for k in pairs(v) do
            local tk = type(k)
            if not (tk == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                if tk == "string" or tk == "number" then keys[#keys + 1] = k end
            end
        end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then return type(a) == "number" end
            return a < b
        end)
        for _, k in ipairs(keys) do
            local val = v[k]
            local tval = type(val)
            if tval == "string" or tval == "number" or tval == "boolean" or tval == "table" then
                encode(k, out, depth + 1)
                encode(val, out, depth + 1)
            end
        end
        out[#out + 1] = "}"
    else
        error("type non serialisable : " .. tv)
    end
end

function Ser.Encode(v)
    local out = {}
    local ok, err = pcall(encode, v, out, 0)
    if not ok then return nil, err end
    return table.concat(out)
end

-- Decodage : renvoie la valeur, ou nil si le texte est invalide.
function Ser.Decode(text)
    if type(text) ~= "string" then return nil end
    local pos, items = 1, 0
    local readValue

    local function readUntilSemicolon()
        local stop = text:find(";", pos, true)
        if not stop then error("fin inattendue") end
        local s = text:sub(pos, stop - 1)
        pos = stop + 1
        return s
    end

    function readValue(depth)
        items = items + 1
        if items > MAX_ITEMS then error("trop d'elements") end
        local tag = text:sub(pos, pos)
        pos = pos + 1
        if tag == "s" then
            return unescape(readUntilSemicolon())
        elseif tag == "n" then
            local n = tonumber(readUntilSemicolon())
            if not n then error("nombre invalide") end
            return n
        elseif tag == "T" then return true
        elseif tag == "F" then return false
        elseif tag == "{" then
            if depth >= MAX_DEPTH then error("table trop profonde") end
            local t = {}
            while true do
                local c = text:sub(pos, pos)
                if c == "}" then pos = pos + 1; return t end
                if c == "" then error("table non fermee") end
                local k = readValue(depth + 1)
                if type(k) ~= "string" and type(k) ~= "number" then error("cle invalide") end
                t[k] = readValue(depth + 1)
            end
        end
        error("balise inconnue")
    end

    local ok, value = pcall(readValue, 0)
    if not ok or pos ~= #text + 1 then return nil end
    return value
end
