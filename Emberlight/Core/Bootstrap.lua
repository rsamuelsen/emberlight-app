local _, E = ...
E.version = "1.0.1"
-- What members read for each kind of notice. Only the number travels between players and to the
-- server, so these words can change without touching the protocol. Since 0.9.3 (19 November 2026,
-- the owner's decision after the staff meeting) there are three kinds of event: a Story Event and
-- a Guild Gathering (both official, category 4; a Story Event carries a mark, see E.Kind) and an
-- Adventure (what members post). 1 to 3 were Journey, Call for aid and Gathering; all three are
-- Adventures now, and a new one is posted as 1.
E.categories = { "Adventure", "Adventure", "Adventure", "Guild Gathering" }
E.storyLabel = "Story Event"
E.routes = { "Noticeboard", "Courier letter", "Real-mail draft" }
-- The window every addon checks a notice against, in days: its start and its end must lie within
-- this of the time it travels with (`created`). Unchanged since the first release, so older addons
-- keep taking what this one sends. An event further ahead travels with a later `created` (see
-- E.Sync.Created): an addon before 0.9.3 takes it once it is near enough, this one at once.
E.maxHorizonDays = 21
-- How far ahead an event may start, in days (the owner's decision, 19 November 2026): an
-- Adventure up to 31 days, a Guild Gathering or a Story Event up to two years (as on the website).
E.adventureDays = 31
E.officialDays = 730
function E.AheadDays(categoryIndex) return categoryIndex == 4 and E.officialDays or E.adventureDays end
-- What a notice is called: "Story Event", "Guild Gathering" or "Adventure".
function E.Kind(entry)
    if type(entry) ~= "table" then return "" end
    if entry.categoryIndex == 4 and entry.story then return E.storyLabel end
    return E.categories[entry.categoryIndex] or E.categories[1]
end
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

-- A name without accents or capitals (16 November 2026, the owner's request): "Thörgrim" is
-- "thorgrim", so a name typed on the website without an accent still finds the game's character.
-- Only the common Latin letters with accents (UTF-8, two bytes) are folded; anything else stays.
local folds = {}
for letters, plain in pairs({
    ["àáâãäåā"] = "a", ["ç"] = "c", ["èéêëē"] = "e", ["ìíîïī"] = "i", ["ñ"] = "n", ["òóôõöøō"] = "o",
    ["ùúûüū"] = "u", ["ýÿ"] = "y", ["æ"] = "ae", ["œ"] = "oe", ["ß"] = "ss", ["ð"] = "d", ["þ"] = "th",
    ["ÀÁÂÃÄÅĀ"] = "a", ["Ç"] = "c", ["ÈÉÊËĒ"] = "e", ["ÌÍÎÏĪ"] = "i", ["Ñ"] = "n", ["ÒÓÔÕÖØŌ"] = "o",
    ["ÙÚÛÜŪ"] = "u", ["Ý"] = "y", ["Æ"] = "ae", ["Œ"] = "oe", ["Ð"] = "d", ["Þ"] = "th",
}) do
    for ch in letters:gmatch("[\192-\223][\128-\191]") do folds[ch] = plain end
end
function E.Fold(value)
    if type(value) ~= "string" then return value end
    return (value:gsub("[\192-\223][\128-\191]", folds):lower())
end
