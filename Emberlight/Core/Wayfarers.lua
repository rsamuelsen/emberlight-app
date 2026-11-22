local _, E = ...
-- The officers' Wayfarers list in game (1.0.1, the owner's request, 22 November 2026): the same
-- people and groups as the website's Wayfarers page (Officers, Wayfarers), with who is online now
-- from the guild roster, so officers can follow new members up while they play. An officer's
-- Emberlight Companion writes the list into Emberlight_Data/Wayfarers.lua (global
-- EmberlightWayfarers) at each sync; for anyone else the file holds no list. Read only: notes,
-- follow-up days and the follow-up officer are set on the website. Nothing here is saved or sent.
local W = {}
E.Wayfarers = W
W.format = 1

-- The website's groups, in its order, with its words (web src/utils/wayfarers.ts).
W.groups = {
    { key = "due", title = "Follow-up due" },
    { key = "hello", title = "Needs a first hello" },
    { key = "quiet", title = "Quiet" },
    { key = "character", title = "No character yet" },
    { key = "away", title = "Away" },
    { key = "fine", title = "Doing fine" },
}
local known = {}
for _, g in ipairs(W.groups) do known[g.key] = true end
-- The website's note labels.
W.labels = { said_hello = "Said hello", followed_up = "Followed up", reached_out = "Check-in" }

local function text(value, limit)
    if type(value) ~= "string" or value == "" or #value > limit * 4 then return nil end
    local clean = E.Clean(value, limit)
    return clean ~= "" and clean or nil
end

-- The list as the Companion wrote it. The file is local and could be damaged or edited, so only
-- plain values are taken from it, within the sync tool's own limits. Nil when there is no list.
function W.Website()
    local data = _G.EmberlightWayfarers
    if type(data) ~= "table" or data.format ~= W.format or type(data.list) ~= "table" then return nil end
    local list = {}
    for _, w in ipairs(data.list) do
        if #list >= 500 then break end
        local name = type(w) == "table" and text(w.name, 100)
        if name and known[w.group] then
            local person = {
                name = name, main = text(w.main, 60), days = tonumber(w.days), group = w.group, quietDays = tonumber(w.quietDays),
                nextFollowUp = type(w.nextFollowUp) == "string" and w.nextFollowUp:match("^%d%d%d%d%-%d%d%-%d%d$") or nil,
                followUpBy = text(w.followUpBy, 100), mentor = text(w.mentor, 100), away = tonumber(w.away), lastSeen = tonumber(w.lastSeen),
                characters = {},
            }
            if type(w.lastFollowUp) == "table" and tonumber(w.lastFollowUp.at) then
                person.lastFollowUp = { label = W.labels[w.lastFollowUp.label] or "Note", by = text(w.lastFollowUp.by, 60) or "an officer", at = tonumber(w.lastFollowUp.at) }
            end
            for _, ch in ipairs(type(w.characters) == "table" and w.characters or {}) do
                local cname, key = type(ch) == "table" and text(ch.name, 60), type(ch) == "table" and text(ch.key, 120)
                if cname and key and not key:find("[%-%s]") and #person.characters < 20 then
                    person.characters[#person.characters + 1] = { name = cname, key = key, main = ch.main == true }
                end
            end
            list[#list + 1] = person
        end
    end
    return { generated = tonumber(data.generated), list = list }
end

-- Which of a Wayfarer's characters is online now, from the guild list (E.Roster.Guild), accents
-- aside as in the roster check. Returns the game's name for it, or nil.
function W.OnlineAs(person, guild)
    local online = {}
    for _, entry in ipairs(guild or {}) do
        if entry.online then online[entry.key] = entry.name; online[E.Fold(entry.key)] = online[E.Fold(entry.key)] or entry.name end
    end
    for _, ch in ipairs(person.characters) do
        local name = online[ch.key] or online[E.Fold(ch.key)]
        if name then return name end
    end
end

-- "Said hello by Alice Example, 3 days ago", the next follow-up day, and the mentor: one line.
function W.Details(person, now)
    local parts = {}
    if person.nextFollowUp then parts[#parts + 1] = "Next follow-up " .. person.nextFollowUp .. (person.followUpBy and (" (" .. person.followUpBy .. ")") or "") end
    if person.lastFollowUp then
        local days = math.max(0, math.floor((now - person.lastFollowUp.at) / 86400))
        parts[#parts + 1] = person.lastFollowUp.label .. " by " .. person.lastFollowUp.by .. ", " .. (days == 0 and "today" or days == 1 and "yesterday" or (days .. " days ago"))
    end
    if person.mentor then parts[#parts + 1] = "Mentor: " .. person.mentor end
    if person.group == "quiet" and person.quietDays then parts[#parts + 1] = person.quietDays .. " days quiet" end
    return table.concat(parts, ". ")
end
