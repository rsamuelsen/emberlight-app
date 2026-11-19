local _, E = ...
-- Who uses Emberlight, which version, and the officers' grand message (0.9.0, the owner's
-- request, 18 November 2026).
--
-- Version: with sharing on, every addon tells guildmates online its version (kind "A" in
-- Core/Sync.lua) whenever it shares its notices: at login or reload, and again when a guildmate
-- asks (every few minutes). A version newer than this one is believed when an officer's addon
-- (guild master, Flame Keeper, Officer Alt) says it, or two different members' addons do, so one
-- member cannot make the whole guild think it is out of date. The newest believed version is kept
-- in EmberlightDB.localData.newestAddon, so the next login can tell the member even before anyone
-- answers. The member is told once per login or reload, in the chat window, never again until the
-- next one.
--
-- Officers see who answered, and with which version, on the roster check's "Addon users" view
-- (UI/Roster.lua). Only versions are kept, for this session; nothing is saved about anyone.
--
-- The member's own Companion also writes the guild's newest published version into
-- Emberlight_Data/Latest.lua (global EmberlightLatest) when it checks for addon updates; that is
-- believed at once (it comes from the signed release list), so the notice works with nobody online.
--
-- Grand message: an officer writes a short message that shows large on the screen of every
-- guildmate online with this version (kind "B"), and is posted in guild chat too, so members
-- without the addon read it there (and addon users find it again in chat). Every receiving addon checks the sender's
-- in-game rank itself, so the words alone never grant anything. At most one from the same officer
-- a minute and three from all officers in five minutes are shown; the rest are dropped.
local P = { heard = {}, votes = {}, grands = {}, shownGrands = {} }
E.Presence = P
P.url = "https://emberlightrp.com/portal/addons"
-- How long after login or reload a newly learned version may still be mentioned.
P.window = 180
P.grandLimit = 200
P.grandEvery = 60
P.grandBurst, P.grandBurstWindow = 3, 300

function P.Parse(version)
    if type(version) ~= "string" or #version > 16 then return nil end
    local a, b, c = version:match("^(%d+)%.(%d+)%.(%d+)$")
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if not a or a > 99 or b > 999 or c > 999 then return nil end
    return { a, b, c }
end
-- Whether version `a` is newer than `b`.
function P.Newer(a, b)
    local x, y = P.Parse(a), P.Parse(b)
    if not x or not y then return false end
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

local function db()
    return E.Store.db and E.Store.db.localData
end
function P.Newest()
    local d = db()
    local n = d and d.newestAddon
    if type(n) == "table" and P.Newer(n.version, E.version) then return n.version end
    return nil
end

function P.NoticeText(newest)
    return "Emberlight: you are using an old version of the Emberlight addon (" .. E.version .. "). Version " .. newest
        .. " is out. Please update through Emberlight Companion, or download the latest from " .. P.url
end
-- Says it once per login or reload, and only soon after it: later news waits for the next one.
function P.Notify(now)
    if P.told then return false end
    now = now or E.Client.Now()
    if P.started and now - P.started > P.window then return false end
    local newest = P.Newest()
    if not newest then return false end
    P.told = true
    -- Red-orange, not the white or gold other addons use, so it stands out (owner, 18 November).
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(P.NoticeText(newest), 1, .35, .2) end
    if E.UI and E.UI.RefreshSettings and E.UI.settings and E.UI.settings:IsShown() then pcall(E.UI.RefreshSettings) end
    return true
end

-- A guildmate's addon told its version. `officer` is the sender's in-game authority, from the
-- guild roster, never from the message.
function P.Heard(sender, version, officer, now)
    if type(sender) ~= "string" or not P.Parse(version) then return false end
    now = now or E.Client.Now()
    if not P.heard[sender] then
        local n = 0
        for _ in pairs(P.heard) do n = n + 1 end
        if n >= 1000 then return false end
    end
    P.heard[sender] = { version = version, at = now }
    if P.Newer(version, E.version) then
        local votes = P.votes[version]
        if not votes then
            local n = 0
            for _ in pairs(P.votes) do n = n + 1 end
            if n >= 20 then return true end
            votes = {}; P.votes[version] = votes
        end
        votes[sender] = true
        local count = 0
        for _ in pairs(votes) do count = count + 1 end
        local d = db()
        if d and (officer or count >= 2) and (not P.Newest() or P.Newer(version, P.Newest())) then
            d.newestAddon = { version = version, at = now }
            P.Notify(now)
        end
    end
    return true
end

-- What the officers' list shows for one guildmate: their version, or nil when not heard.
function P.VersionOf(identity) local h = P.heard[identity]; return h and h.version end

-- Sending an announcement (officers only; the receivers check again).
function P.SendGrand(text, now)
    now = now or E.Client.Now()
    local scope, roster, me = E.Sync.Context()
    if not scope or not roster[me] or not roster[me].officer then return nil, "Only the guild master, Flame Keepers and Officer Alts can send an announcement." end
    text = E.Trim(E.Clean(text, P.grandLimit))
    if text == "" then return nil, "Write the message first." end
    if P.lastGrand and now - P.lastGrand < P.grandEvery then
        return nil, "Wait " .. (P.grandEvery - (now - P.lastGrand)) .. " seconds before sending another announcement."
    end
    local id = tostring(now)
    local ok, problem = E.Sync.Queue({ "B", E.Sync.guild, id, text }, "B:" .. id)
    if not ok then return nil, problem or "Could not send the message." end
    P.lastGrand = now
    -- Guild chat, for members without the addon. Only the officer's own client posts it.
    local posted = SendChatMessage ~= nil and pcall(SendChatMessage, "[Emberlight] " .. text, "GUILD")
    P.Show(text, roster[me].name, not posted)
    return true
end

-- A grand message arrived from `sender`, whose officer rank Core/Sync.lua has already checked.
function P.Grand(sender, id, text, name, now)
    now = now or E.Client.Now()
    local last = P.grands[sender]
    if last and (last.id == id or now - last.at < P.grandEvery) then return false end
    local recent = 0
    for i = #P.shownGrands, 1, -1 do
        if P.shownGrands[i] < now - P.grandBurstWindow then table.remove(P.shownGrands, i) else recent = recent + 1 end
    end
    if recent >= P.grandBurst then return false end
    P.grands[sender] = { id = id, at = now }
    P.shownGrands[#P.shownGrands + 1] = now
    P.Show(text, name)
    return true
end

-- Large on the screen for a while, and one line in chat so it can be read again.
-- `chat`: also one line in the chat window, only when guild chat does not already carry it.
function P.Show(text, name, chat)
    -- The name without its realm, as members read it everywhere else.
    local who = E.Clean(name or "", 120):match("^[^-]*"):sub(1, 60)
    if chat and DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("Emberlight, from " .. who .. ": " .. text, 1, .82, .35) end
    if E.UI and E.UI.ShowGrand then pcall(E.UI.ShowGrand, text, who) end
end

-- The Companion's word (Emberlight_Data/Latest.lua). The file is local and could be damaged, so
-- only a plain version is taken from it.
function P.FromCompanion()
    local latest = _G.EmberlightLatest
    local d = db()
    if not d or type(latest) ~= "table" or latest.format ~= 1 or not P.Parse(latest.addon) then return false end
    if not P.Newer(latest.addon, E.version) or (P.Newest() and not P.Newer(latest.addon, P.Newest())) then return false end
    d.newestAddon = { version = latest.addon, at = E.Client.Now() }
    return true
end

-- For the officer desk: how many guildmates online answered with a version, of how many online.
function P.Usage()
    if not IsInGuild or not IsInGuild() or not GetNumGuildMembers or not GetGuildRosterInfo then return nil end
    local online, using = 0, 0
    local me = E.Client.Canonical(E.Client.Name())
    for i = 1, math.min(tonumber((GetNumGuildMembers())) or 0, 2000) do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        local key = type(name) == "string" and E.Client.Canonical(name)
        if key and isOnline then
            online = online + 1
            key = E.Client.Local(key)
            if key == me or P.heard[key] then using = using + 1 end
        end
    end
    return using, online
end

-- The test commands (/emberlight test ...): what members would see, on this screen only.
function P.TestUpdate()
    local v = P.Parse(E.version)
    local next = v and (v[1] .. "." .. v[2] .. "." .. (v[3] + 1)) or "9.9.9"
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Emberlight (test, only you see this):", .7, .7, .7)
        DEFAULT_CHAT_FRAME:AddMessage(P.NoticeText(next), 1, .35, .2)
    end
end
function P.TestGrand()
    P.Show("This is how an announcement looks. Only you see this test.", E.Client.Name(), false)
end

function P.Start()
    P.started = E.Client.Now()
    local d = db()
    -- Updated since: forget the version that was newer then.
    if d and d.newestAddon ~= nil and not P.Newest() then d.newestAddon = nil end
    P.FromCompanion()
    if C_Timer and C_Timer.After then C_Timer.After(20, function() P.Notify() end) end
end
