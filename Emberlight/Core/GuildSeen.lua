local _, E = ...
-- When guildmates were last in game, for the officers' activity overview (0.8.15, the owner's
-- decision, 18 November 2026; in-game "last online" allowed since 2 November). The guild window
-- already shows every member who is online and how long others have been offline ("3 days"); the
-- addon notes that, to the hour, in EmberlightDB.localData.guildSeen. The member's Emberlight
-- Companion uploads it after the game closes, and the website counts it as a sign of life.
--
-- Only character names and times. Notes, zones, levels and anything else in the guild list are
-- never read, and nothing is sent to other players. The guild window is read at most every few
-- minutes, and only what the game already shows the player.
local G = {}
E.GuildSeen = G
-- Characters kept, and how long one the list no longer shows is remembered.
G.keep = 1500
G.forget = 90 * 86400
-- How often the list is read while the game keeps saying it changed.
G.every = 300

local HOUR = 3600
local function toHour(t) return math.floor(t / HOUR) * HOUR end

local function db()
    local d = E.Store.db and E.Store.db.localData
    if not d then return nil end
    d.guildSeen = type(d.guildSeen) == "table" and d.guildSeen or {}
    local s = d.guildSeen
    s.characters = type(s.characters) == "table" and s.characters or {}
    return s
end

-- "Offline for 3 days" as the game gives it, in hours. Months and years are rough in the game too.
local function hoursAway(year, month, day, hour)
    return (tonumber(year) or 0) * 8760 + (tonumber(month) or 0) * 730 + (tonumber(day) or 0) * 24 + (tonumber(hour) or 0)
end

-- Everyone the guild list shows now: identity -> last time in game, to the hour. Nil outside a guild.
function G.Read(now)
    if not IsInGuild or not IsInGuild() or not GetNumGuildMembers or not GetGuildRosterInfo then return nil end
    now = now or E.Client.Now()
    local seen = {}
    for i = 1, math.min(tonumber((GetNumGuildMembers())) or 0, 2000) do
        local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
        local key = type(name) == "string" and E.Client.Canonical(name)
        if key then
            if online then
                seen[key] = toHour(now)
            elseif GetGuildRosterLastOnline then
                local year, month, day, hour = GetGuildRosterLastOnline(i)
                -- Nothing at all means the game does not know; it is left out rather than guessed.
                if year or month or day or hour then seen[key] = toHour(now - hoursAway(year, month, day, hour) * HOUR) end
            end
        end
    end
    return seen
end

-- Keeps the newest time for each character. One the list no longer shows (offline members hidden
-- in the guild window, or someone who left) keeps its last time until it is old.
function G.Save(seen, now)
    local s = db()
    if not s or not seen then return end
    now = now or E.Client.Now()
    local all = s.characters
    for key, at in pairs(seen) do
        if type(at) == "number" and at <= now and (type(all[key]) ~= "number" or all[key] < at) then all[key] = at end
    end
    local count = 0
    for key, at in pairs(all) do
        if type(at) ~= "number" or at < now - G.forget then all[key] = nil else count = count + 1 end
    end
    -- Too many (a damaged file): drop the oldest.
    while count > G.keep do
        local oldest, when
        for key, at in pairs(all) do if not when or at < when then oldest, when = key, at end end
        all[oldest] = nil
        count = count - 1
    end
    s.at = now
end

function G.Start()
    if G.frame or not CreateFrame then return end
    local frame = CreateFrame("Frame")
    G.frame = frame
    local last = 0
    pcall(frame.RegisterEvent, frame, "GUILD_ROSTER_UPDATE")
    frame:SetScript("OnEvent", function()
        local now = E.Client.Now()
        if now - last < G.every then return end
        last = now
        pcall(function() G.Save(G.Read(now), now) end)
    end)
end
