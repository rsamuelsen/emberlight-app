local _, E = ...
E.version = "0.8.9"
-- What members read for each kind of notice. Only the number travels between players and to the
-- server, so these words can change without touching the protocol. 1 to 3 are adventures.
E.categories = { "Journey", "Call for aid", "Gathering", "Guild event" }
E.routes = { "Noticeboard", "Courier letter", "Real-mail draft" }
-- How far ahead a notice's start time may be scheduled, in days. Applies to both boards.
E.maxHorizonDays = 21
function E.Clean(value, limit)
    if type(value) ~= "string" then return "" end
    -- Escape WoW markup and strip controls; text is always data, never Lua.
    value = value:gsub("|", ""):gsub("[%z\1-\8\11\12\14-\31\127]", "")
    return value:sub(1, limit or 1600)
end

function E.Trim(value)
    return value:match("^%s*(.-)%s*$")
end

function E.Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = E.Copy(v) end
    return result
end
