local _, E = ...
E.Client = {}

function E.Client.Now() return GetServerTime() end
-- "First Last-Realm", the way the guild roster and addon messages name the player. The realm is
-- the normalized one ("ClassicBetaPvE2"): the display name has spaces, which the identity keeps
-- (C.Canonical). On the WoW: Forever beta UnitFullName returns the first name and the SURNAME
-- ("Ann", "Example"), not a realm, so a second value that is not this realm is the surname.
function E.Client.Name()
    local name, second = UnitFullName("player")
    if not name then return "Your character" end
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or "Unknown"
    if type(second) == "string" and second ~= "" and second ~= realm then name = name .. " " .. second end
    return name .. "-" .. realm
end
function E.Client.Build()
    local version, build, _, interface = GetBuildInfo()
    return string.format("%s %s (%s) / interface %s", E.Client.IsRetail() and "Retail" or "World of Warcraft", version, build, interface)
end
function E.Client.IsRetail()
    return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
end
-- Sharing needs addon messages and the group and guild functions, not a particular game client.
-- WoW: Forever's beta (October 2026) is not Retail: version 1.60.1, interface 16001, project 18;
-- a member there reported all of these present. Whether they behave as on Retail is unverified.
function E.Client.CanShare()
    return C_ChatInfo ~= nil and C_ChatInfo.SendAddonMessage ~= nil and C_ChatInfo.RegisterAddonMessagePrefix ~= nil
        and IsInGroup ~= nil and GetNumSubgroupMembers ~= nil and UnitFullName ~= nil and UnitGUID ~= nil
end
-- Server time. Members live in different time zones, so every time the addon shows or asks for is
-- the realm's clock, the one the game itself shows. The realm's distance from UTC is read from
-- that clock, to the nearest quarter of an hour; without it (the tests) the realm is taken as UTC.
function E.Client.RealmOffset()
    if not GetGameTime then return 0 end
    local hour, minute = GetGameTime()
    if type(hour) ~= "number" or type(minute) ~= "number" then return 0 end
    local utc = date("!*t", GetServerTime())
    if type(utc) ~= "table" then return 0 end
    local difference = (hour * 60 + minute) - (utc.hour * 60 + utc.min)
    if difference > 840 then difference = difference - 1440 elseif difference < -720 then difference = difference + 1440 end
    return math.floor(difference / 15 + .5) * 900
end
-- The moment today began on the realm's clock.
function E.Client.DayStart()
    local offset = E.Client.RealmOffset()
    return math.floor((GetServerTime() + offset) / 86400) * 86400 - offset
end
function E.Client.Stamp(timestamp)
    return date("!%a %d %b, %H:%M", timestamp + E.Client.RealmOffset())
end
-- The two halves of a stamp, for the margin of a ledger line.
function E.Client.Day(timestamp) return date("!%a %d", timestamp + E.Client.RealmOffset()) end
function E.Client.Date(timestamp) return date("!%a %d %b", timestamp + E.Client.RealmOffset()) end
function E.Client.Clock(timestamp) return date("!%H:%M", timestamp + E.Client.RealmOffset()) end
-- For the calendar: the weekday (0 is Monday), the day of the month and the month's name.
function E.Client.Weekday(timestamp) return ((tonumber(date("!%w", timestamp + E.Client.RealmOffset())) or 0) + 6) % 7 end
function E.Client.MonthDay(timestamp) return tonumber(date("!%d", timestamp + E.Client.RealmOffset())) or 0 end
function E.Client.Month(timestamp) return date("!%B", timestamp + E.Client.RealmOffset()) end
-- The same moment on the member's own computer clock.
function E.Client.LocalClock(timestamp) return date("%H:%M", timestamp) end
