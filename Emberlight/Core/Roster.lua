local _, E = ...
local C = E.Client
-- The officers' roster check (0.8.12): the guild in game against the website's member list. The
-- website is the truth. An officer's Emberlight Companion writes the list into
-- Emberlight_Data/Roster.lua (global EmberlightRoster) at each sync, before the game starts; for
-- anyone else the file holds no list. Nothing here is saved, sent or shared: it is read when an
-- officer opens the check and forgotten with the window.
local R = {}
E.Roster = R
R.format = 1
-- A list older than this is probably out of date: the officer is told to sync again.
R.staleAfter = 3 * 86400

local function text(value, limit)
    if type(value) ~= "string" or value == "" or #value > limit then return nil end
    local clean = E.Clean(value, limit)
    return clean ~= "" and clean or nil
end

-- The website's list as the Companion wrote it. The file is local and could be damaged or edited,
-- so only plain names and ranks are taken from it, within the sync tool's own limits.
function R.Website()
    local data = _G.EmberlightRoster
    if type(data) ~= "table" or data.format ~= R.format or type(data.members) ~= "table" then return nil end
    local members = {}
    for _, m in ipairs(data.members) do
        if #members >= 2000 then break end
        if type(m) == "table" and type(m.characters) == "table" then
            -- Alts are "Alt", or "Officer Alt" for an officer's, as the server says.
            local member = { rank = text(m.rank, 40), inGameRank = text(m.inGameRank, 40), altRank = text(m.altRank, 40) or "Alt", characters = {} }
            for _, ch in ipairs(m.characters) do
                if #member.characters >= 50 then break end
                local name = type(ch) == "table" and text(ch.name, 60)
                local key = type(ch) == "table" and text(ch.key, 120)
                if name and key and not key:find("[%-%s]") then
                    member.characters[#member.characters + 1] = { name = name, key = key, main = ch.main == true }
                    if ch.main == true then member.hasMain = true end
                end
            end
            if #member.characters > 0 then members[#members + 1] = member end
        end
    end
    return { generated = tonumber(data.generated), fresh = data.fresh == true, members = members }
end

-- A character's key as the website's list has it: the name part of its identity (lower case, a
-- space as "_"), without the realm, which on WoW: Forever is a hidden part of the megarealm.
function R.Key(name)
    local identity = C.Canonical(name)
    return identity and identity:match("^[^-]+")
end

-- Everyone in the in-game guild: name, key, rank name and rank index. Notes are never read. Also
-- returns how many members WoW says the guild has, which is more than the list when the game
-- leaves offline members out (the guild window's "Show offline members").
function R.Guild()
    if not IsInGuild or not IsInGuild() or not GetNumGuildMembers or not GetGuildRosterInfo then return nil end
    local total = tonumber((GetNumGuildMembers())) or 0
    local list = {}
    for i = 1, total do
        local name, rank, index = GetGuildRosterInfo(i)
        local key = type(name) == "string" and R.Key(name)
        if key and type(index) == "number" then
            list[#list + 1] = { name = E.Clean(name:match("^[^-]+"), 60), key = key, rank = E.Clean(rank or "", 40), index = index }
        end
    end
    return list, total
end

-- The in-game rank a character should have: the member's rank (from Discord) for their main,
-- the member's alt rank ("Alt", or "Officer Alt" for an officer) for every other character. Nil when it cannot be told: a main whose member has no
-- Discord rank, or an alt of a member who has not chosen a main on the website.
function R.Expected(website, member, character)
    if character.main then return member.inGameRank end
    if member.hasMain then return member.altRank end
end
-- Whether a character in the guild has that rank: true, false, or nil when there is nothing to
-- check. The guild master is rank 0 in game, whatever it is called.
function R.RankOk(website, member, character, entry)
    local expected = R.Expected(website, member, character)
    if not expected then return nil end
    if character.main and member.rank == "guildMaster" then return entry.index == 0 end
    return entry.index ~= 0 and entry.rank:lower() == expected:lower()
end

local function byName(a, b) return a.name:lower() < b.name:lower() end

-- The check itself.
--   notOnWebsite: characters in the guild that are no member's verified character.
--   wrongRank:    characters in the guild without the rank they should have (R.Expected).
--   members:      each member with characters in the guild, main first: { member, rows = { character, entry, rankOk } }.
--   invite:       each member with verified characters not in the guild: { member, rows = { character }, inGuild }.
function R.Check(website, guild)
    local result = { notOnWebsite = {}, wrongRank = {}, members = {}, invite = {}, inGuild = #guild, missing = 0 }
    local known, here = {}, {}
    for _, m in ipairs(website.members) do
        for _, ch in ipairs(m.characters) do known[ch.key] = true end
    end
    for _, entry in ipairs(guild) do
        here[entry.key] = entry
        if not known[entry.key] then result.notOnWebsite[#result.notOnWebsite + 1] = entry end
    end
    table.sort(result.notOnWebsite, byName)
    for _, m in ipairs(website.members) do
        local rows, missing = {}, {}
        for _, ch in ipairs(m.characters) do
            local entry = here[ch.key]
            if entry then
                local row = { character = ch, entry = entry, rankOk = R.RankOk(website, m, ch, entry), expected = R.Expected(website, m, ch) }
                rows[#rows + 1] = row
                if row.rankOk == false then result.wrongRank[#result.wrongRank + 1] = { member = m, character = ch, entry = entry, expected = row.expected } end
            else
                missing[#missing + 1] = { character = ch }
            end
        end
        if #rows > 0 then result.members[#result.members + 1] = { member = m, rows = rows } end
        if #missing > 0 then
            result.invite[#result.invite + 1] = { member = m, rows = missing, inGuild = #rows }
            result.missing = result.missing + #missing
        end
    end
    table.sort(result.wrongRank, function(a, b) return a.character.name:lower() < b.character.name:lower() end)
    return result
end

