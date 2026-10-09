local _, E = ...
local C = E.Client

-- Party and guild transport and identity. Authority never comes from message contents.
function C.Channel()
    return E.Store.db.settings.shareMode == "party" and "PARTY" or "GUILD"
end
-- A character's identity: "name-realm", lowercased, a space in the name kept as "_". WoW: Forever
-- names have a first name and a surname, and removing the space made "Ann Abel" and "Anna Bel"
-- one identity; names never contain "_". Matches sync/src/records.rs and server/src/notice.ts.
function C.Canonical(name)
    if type(name) ~= "string" or #name > 120 then return nil end
    if not name:find("-", 1, true) then name = name .. "-" .. (GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()) end
    return (name:gsub("%s+", "_"):lower())
end
function C.Party()
    if not C.CanShare() or not IsInGroup(LE_PARTY_CATEGORY_HOME) or IsInRaid(LE_PARTY_CATEGORY_HOME) then return nil end
    -- Do not confuse a premade party with a simultaneous matchmade instance group.
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return nil end
    local n = GetNumSubgroupMembers(LE_PARTY_CATEGORY_HOME)
    if n < 1 or n > 4 then return nil end
    local roster, guids, leader = {}, {}, nil
    for i = 0, n do
        local unit = i == 0 and "player" or "party" .. i
        local name, realm = UnitFullName(unit)
        if realm == "" then realm = nil end
        local guid = UnitGUID(unit)
        if not name or not guid then return nil end
        local full = name .. "-" .. (realm or GetNormalizedRealmName())
        local officer = UnitIsGroupLeader(unit, LE_PARTY_CATEGORY_HOME) and true or false
        if officer then leader = guid end
        roster[C.Canonical(full)] = { name=full, officer=officer, rank=officer and "Party leader" or "Party member" }
        guids[#guids+1] = guid
    end
    if not leader then return nil end
    table.sort(guids)
    -- Changing members or leader starts a separate board, without leaking old notices.
    return "party:" .. leader .. ":" .. table.concat(guids, ","), roster
end
function C.ScopeKey()
    if C.Channel() == "PARTY" then return C.Party() end
    if not C.CanShare() or not IsInGuild or not IsInGuild() or not C_Club or not C_Club.GetGuildClubId then return nil end
    local id = C_Club.GetGuildClubId()
    if not id then return nil end
    return tostring(GetCurrentRegion()) .. ":" .. tostring(id)
end
function C.Roster()
    if C.Channel() == "PARTY" then local _, roster = C.Party(); return roster or {} end
    local guild = C.ScopeKey()
    if C.rosterCache and C.rosterGuild == guild and C.rosterUntil > C.Now() then return C.rosterCache end
    local members, names = {}, {}
    if not guild or not GetNumGuildMembers or not GetGuildRosterInfo then return members end
    for i = 1, GetNumGuildMembers() do
        -- Do not retain public/officer notes, or any other guild records.
        local name, rank, index = GetGuildRosterInfo(i)
        local key = C.Canonical(name)
        if key and type(index) == "number" then
            members[key] = { name = name, officer = index == 0 or rank == "Flame Keeper", rank = rank }
            -- A roster name without a realm: C.Local finds this member by name alone.
            if not name:find("-", 1, true) then names[key:match("^[^-]+")] = key end
        end
    end
    C.rosterCache = members; C.rosterNames = names; C.rosterGuild = guild; C.rosterUntil = C.Now() + 2
    return members
end
-- WoW: Forever is one megarealm split into hidden realms ("ClassicBetaPvE", "ClassicBetaPvE2")
-- that nobody chooses. The guild roster and addon messages name members without a realm, and
-- C.Canonical fills in the reader's own, so a member on the other hidden realm is known here by the
-- wrong realm, while what they write themselves (notice ids, the server's copies) carries their
-- true one. Names are unique on the megarealm, so an identity whose name matches a roster member
-- the roster gave no realm is that member. Returns the identity as this client keys it: its roster
-- key. Anything else (a realm the roster names, someone not in the guild) is returned unchanged.
function C.Local(identity)
    if type(identity) ~= "string" or C.Channel() ~= "GUILD" then return identity end
    local roster = C.Roster()
    if roster[identity] or C.rosterCache ~= roster or not C.rosterNames then return identity end
    local name = identity:match("^([^-]+)%-")
    return name and C.rosterNames[name] or identity
end
-- The name a record of this player's own carries as its author: the roster's name, with this
-- player's realm when the roster gives none, so that it matches the owner (the sync tool and the
-- server refuse a notice whose author is not its owner's name).
function C.Author(roster, me)
    local name = roster[me] and roster[me].name or C.Name()
    if not name:find("-", 1, true) then name = name .. "-" .. (GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()) end
    return name
end
function C.RequestRoster()
    C.rosterCache = nil
    if C.Channel() == "GUILD" and C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
end
function C.CommsBlocked()
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return true end
    if InCombatLockdown and InCombatLockdown() then return true end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return true end
    return false
end
function C.RegisterPrefix(prefix)
    if not C_ChatInfo or not C_ChatInfo.RegisterAddonMessagePrefix then return false end
    C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    return C_ChatInfo.IsAddonMessagePrefixRegistered(prefix)
end
function C.SendPacket(prefix, packet)
    if C.CommsBlocked() then return false end
    local result = C_ChatInfo.SendAddonMessage(prefix, packet, C.Channel())
    local errors = { [3]="Waiting for the message throttle", [5]="No party connection", [8]="Waiting for the channel throttle", [10]="No guild connection", [11]="Messages paused by WoW" }
    return Enum and Enum.SendAddonMessageResult and result == Enum.SendAddonMessageResult.Success,
        errors[result] or ("Message not accepted by WoW (" .. tostring(result) .. ")")
end
