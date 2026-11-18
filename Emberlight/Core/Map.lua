local _, E = ...
local C = E.Client
-- The guild map (0.9.0, a member's suggestion the owner took up, 18 November 2026). Guildmates
-- who switch it on in Settings see each other as small flames on the world map and the minimap,
-- coloured by class. On by default (the owner's decision, 18 November 2026), with one line in
-- chat the first time saying so and how to switch it off; someone who has it off neither shares
-- nor sees. Pausing messages in Settings stops it too.
--
-- What travels: only "this character is at this point of this map", on its own addon prefix,
-- to the guild. Name, level and class come from the guild roster on the receiving side, so a
-- message can never claim to be someone else. Nothing is saved; a position is forgotten a couple
-- of minutes after its last message, and at once when the member switches the map off.
--
-- Light on traffic: while moving a position is sent at most every 10 seconds, standing still
-- once a minute. Nothing is sent in a dungeon, raid, battleground or arena, or in combat; on
-- entering one, guildmates are told to remove the flame.
local M = { positions = {}, heardAt = {} }
E.Map = M
M.prefix = "EmberlightMap"
M.moving = 10
M.still = 60
M.forget = 150
M.maxPositions = 500
-- The smallest move worth telling, in map units (a few yards on a zone map).
M.step = .002

function M.Enabled()
    local st = E.Store.db and E.Store.db.settings
    return st ~= nil and st.guildMap == true and st.guildSync == true and not st.demo
end

-- Where this character is, or nil (no map position: a dungeon, or the game does not say).
function M.Here()
    if IsInInstance then
        local inside = IsInInstance()
        if inside then return nil end
    end
    if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetPlayerMapPosition then return nil end
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or type(map) ~= "number" then return nil end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if not ok2 or not pos then return nil end
    local x, y = pos.x, pos.y
    if pos.GetXY then x, y = pos:GetXY() end
    if type(x) ~= "number" or type(y) ~= "number" or x <= 0 or y <= 0 or x >= 1 or y >= 1 then return nil end
    return map, x, y
end

-- "1:<map>:<x>:<y>" with x and y in ten-thousandths, or "1:0" for "remove my flame".
function M.Encode(map, x, y)
    if not map then return "1:0" end
    return string.format("1:%d:%d:%d", map, math.floor(x * 10000 + .5), math.floor(y * 10000 + .5))
end
function M.Decode(packet)
    if type(packet) ~= "string" or #packet > 40 then return nil end
    if packet == "1:0" then return false end
    local map, x, y = packet:match("^1:(%d+):(%d+):(%d+)$")
    map, x, y = tonumber(map), tonumber(x), tonumber(y)
    if not map or map < 1 or map > 999999 or #packet > 30 or x < 1 or x > 9999 or y < 1 or y > 9999 then return nil end
    return map, x / 10000, y / 10000
end

function M.Send(packet)
    if C.CommsBlocked() then return false end
    local ok, sent = pcall(C.SendPacket, M.prefix, packet)
    return ok and sent
end

-- Called every couple of seconds: tells the guild where this character is, when it is worth it.
function M.Tick(now)
    now = now or C.Now()
    M.Prune(now)
    local on = M.Enabled() and IsInGuild and IsInGuild() and C.Channel() == "GUILD"
    if not on then
        if M.shared then M.shared = nil; M.Send(M.Encode(nil)) end
        if next(M.positions) then M.positions = {}; M.Changed() end
        return
    end
    if C.CommsBlocked() then return end
    local map, x, y = M.Here()
    if not map then
        if M.shared then if M.Send(M.Encode(nil)) then M.shared = nil end end
        return
    end
    local last = M.shared
    local moved = not last or last.map ~= map or math.abs(last.x - x) > M.step or math.abs(last.y - y) > M.step
    local since = last and now - last.at or math.huge
    if (moved and since >= M.moving) or since >= M.still then
        if M.Send(M.Encode(map, x, y)) then M.shared = { map = map, x = x, y = y, at = now } end
    end
end

-- A guildmate's message. Only guild members, never this character, at most one every 3 seconds each.
function M.Receive(prefix, packet, channel, sender, now)
    if prefix ~= M.prefix or channel ~= "GUILD" or not M.Enabled() then return false end
    if issecretvalue and (issecretvalue(packet) or issecretvalue(sender)) then return false end
    now = now or C.Now()
    local who = C.Canonical(sender)
    if not who then return false end
    who = C.Local(who)
    local roster = C.Roster()
    if who == C.Canonical(C.Name()) or not roster[who] then return false end
    if M.heardAt[who] and now - M.heardAt[who] < 3 then return false end
    local map, x, y = M.Decode(packet)
    if map == nil then return false end
    M.heardAt[who] = now
    if map == false then
        if M.positions[who] then M.positions[who] = nil; M.Changed() end
        return true
    end
    if not M.positions[who] then
        local n = 0
        for _ in pairs(M.positions) do n = n + 1 end
        if n >= M.maxPositions then return false end
    end
    M.positions[who] = { map = map, x = x, y = y, at = now }
    M.Changed()
    return true
end

function M.Prune(now)
    local gone = false
    for who, p in pairs(M.positions) do
        if p.at < now - M.forget then M.positions[who] = nil; gone = true end
    end
    for who, at in pairs(M.heardAt) do if at < now - M.forget then M.heardAt[who] = nil end end
    if gone then M.Changed() end
end

function M.Changed()
    if E.UI and E.UI.RefreshMapPins then pcall(E.UI.RefreshMapPins) end
end

-- For the flame's tooltip: the guild roster's name, level, class and rank for an identity.
-- Read at most every 10 seconds; notes and anything else are never read.
function M.Info(who)
    local now = C.Now()
    if not M.info or not M.infoUntil or M.infoUntil < now then
        M.info = {}
        M.infoUntil = now + 10
        if GetNumGuildMembers and GetGuildRosterInfo then
            for i = 1, math.min(tonumber((GetNumGuildMembers())) or 0, 2000) do
                local name, rank, _, level, class, _, _, _, _, status, classFile = GetGuildRosterInfo(i)
                local key = type(name) == "string" and C.Canonical(name)
                -- Away: "<AFK>" on some clients, 1 on others (2 is busy).
                local away = status == 1 or (type(status) == "string" and status:upper():find("AFK", 1, true) ~= nil)
                if key then M.info[key] = { name = name:match("^[^-]+"), full = name, rank = rank, level = level, class = class, classFile = classFile, away = away } end
            end
        end
    end
    return M.info[who]
end

function M.SetEnabled(on)
    E.Store.db.settings.guildMap = on == true
    if not on then M.positions = {}; M.Changed() end
    M.Tick()
end

function M.Start()
    if M.frame or not CreateFrame then return end
    C.RegisterPrefix(M.prefix)
    local frame = CreateFrame("Frame")
    M.frame = frame
    pcall(frame.RegisterEvent, frame, "CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, ...) pcall(M.Receive, ...) end)
    if C_Timer and C_Timer.NewTicker then M.timer = C_Timer.NewTicker(2, function() pcall(M.Tick) end) end
    M.TellOnce()
end
-- The first time the map is on for this account: one line, so nobody is on it without knowing.
function M.TellOnce()
    local d = E.Store.db and E.Store.db.localData
    if not d or d.mapTold or not E.Store.db.settings.guildMap then return false end
    d.mapTold = true
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Emberlight: the guild map is on. Guildmates with it on see you as a small flame on their maps, and you see them (never in dungeons, raids or battlegrounds). Switch it off in Emberlight's Settings, or type /emberlight map off.", 1, .82, .35)
    end
    return true
end
