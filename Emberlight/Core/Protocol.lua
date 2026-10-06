local _, E = ...
E.Protocol = {}
local P = E.Protocol

-- Length-prefixed strings, hex encoded for transport. Never interpreted as code.
function P.Encode(fields)
    local result = {}
    for _, value in ipairs(fields) do
        value = tostring(value)
        result[#result + 1] = #value .. ":" .. value
    end
    local raw = table.concat(result)
    if #raw > 2400 then return nil end
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
function P.Decode(wire)
    if type(wire) ~= "string" or #wire > 4800 or #wire % 2 ~= 0 or wire:find("[^0-9a-f]") then return nil end
    local raw = wire:gsub("..", function(h) return string.char(tonumber(h, 16)) end)
    local fields, pos = {}, 1
    while pos <= #raw do
        if #fields >= 14 then return nil end
        local a, b, length = raw:find("^(%d+):", pos)
        if not a or #length > 4 then return nil end
        length = tonumber(length)
        if length > 1600 or b + length > #raw then return nil end
        fields[#fields + 1] = raw:sub(b + 1, b + length)
        pos = b + length + 1
    end
    return fields
end
