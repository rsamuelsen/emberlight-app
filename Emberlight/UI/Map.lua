local _, E = ...
local U, M = E.UI, E.Map
local media = "Interface\\AddOns\\Emberlight\\Media\\"
-- The guild map's flames (Core/Map.lua): one small flame per guildmate who shares, coloured by
-- class, on the world map and on the minimap. Hovering one tells its name, level, class and
-- where, as the game does for party members. Party and raid members are left out: the game
-- already shows them.
U.mapPins = U.mapPins or { world = {}, mini = {} }
local pins = U.mapPins
-- How wide the minimap is, in yards, at each zoom (outdoors, indoors), as the game draws it.
local outdoor = { 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local indoor = { 300, 240, 180, 120, 80, 50 }

local function color(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 1, .6, .25
end

local function vector(x, y)
    if CreateVector2D then return CreateVector2D(x, y) end
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end
local function xy(v)
    if not v then return nil end
    if v.GetXY then return v:GetXY() end
    return v.x, v.y
end
-- A point on one map, as a point on another (a zone's on its continent, or the other way).
local function onMap(p, target)
    if p.map == target then return p.x, p.y end
    if not C_Map or not C_Map.GetWorldPosFromMapPos or not C_Map.GetMapPosFromWorldPos then return nil end
    local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, p.map, vector(p.x, p.y))
    if not ok or not continent or not world then return nil end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, world, target)
    if not ok2 then return nil end
    local x, y = xy(pos)
    if type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return x, y
end
-- A map's width and height in yards.
local sizes = {}
local function size(map)
    if sizes[map] ~= nil then return sizes[map] or nil end
    sizes[map] = false
    if not C_Map or not C_Map.GetWorldPosFromMapPos then return nil end
    local ok, _, a = pcall(C_Map.GetWorldPosFromMapPos, map, vector(0, 0))
    local ok2, _, b = pcall(C_Map.GetWorldPosFromMapPos, map, vector(1, 1))
    if not ok or not ok2 or not a or not b then return nil end
    local ax, ay = xy(a); local bx, by = xy(b)
    -- The world's first number runs north to south and its second west to east.
    local w, h = math.abs(ay - by), math.abs(ax - bx)
    if w <= 0 or h <= 0 then return nil end
    sizes[map] = { w, h }
    return sizes[map]
end

local function grouped(name)
    if not name then return false end
    local ok, party = pcall(function() return (UnitInParty and UnitInParty(name)) or (UnitInRaid and UnitInRaid(name)) end)
    return ok and party and true or false
end

local function tooltip(pin)
    local info = M.Info(pin.who)
    if not info then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(info.name or "?", color(info.classFile))
    local line = {}
    if type(info.level) == "number" and info.level > 0 then line[#line + 1] = "Level " .. info.level end
    if type(info.class) == "string" then line[#line + 1] = info.class end
    if #line > 0 then GameTooltip:AddLine(table.concat(line, " "), 1, 1, 1) end
    local p = M.positions[pin.who]
    local mapInfo = p and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(p.map)
    if mapInfo and mapInfo.name then GameTooltip:AddLine(mapInfo.name, .8, .8, .8) end
    if type(info.rank) == "string" then GameTooltip:AddLine(E.Clean(info.rank, 40), .6, .6, .6) end
    if info.away then GameTooltip:AddLine("Away", .6, .6, .6) end
    GameTooltip:AddLine("Right-click to whisper", .5, .8, .5)
    GameTooltip:Show()
end

local function pin(list, i, parent, size)
    local p = list[i]
    if p then
        if p:GetParent() ~= parent then p:SetParent(parent) end
        return p
    end
    p = CreateFrame("Frame", nil, parent)
    p:SetSize(size, size)
    p.icon = p:CreateTexture(nil, "OVERLAY")
    p.icon:SetAllPoints()
    p.icon:SetTexture(media .. "Flame.tga")
    p:EnableMouse(true)
    p:SetScript("OnEnter", tooltip)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Right-click: start a whisper to them, as the game's own name menus do.
    p:SetScript("OnMouseUp", function(self, button)
        if button ~= "RightButton" then return end
        local info = M.Info(self.who)
        if info then U.Whisper(info.full or info.name) end
    end)
    p.base = size
    list[i] = p
    return p
end

function U.Whisper(name)
    if type(name) ~= "string" or name == "" then return end
    if ChatFrame_SendTell then pcall(ChatFrame_SendTell, name)
    elseif ChatFrameUtil and ChatFrameUtil.SendTell then pcall(ChatFrameUtil.SendTell, name)
    elseif ChatFrame_OpenChat then pcall(ChatFrame_OpenChat, "/w " .. name .. " ") end
end
-- The member's flame size, and a faded flame for someone away.
local function look(f, info)
    local scale = E.Store.db and E.Store.db.settings.flameSize or 1
    f:SetSize(f.base * scale, f.base * scale)
    f.icon:SetVertexColor(color(info.classFile))
    f:SetAlpha(info.away and .45 or 1)
end

local function each(fn)
    for who, p in pairs(M.positions) do
        local info = M.Info(who)
        if info and not grouped(info.name) then fn(who, p, info) end
    end
end

function U.RefreshWorldPins()
    local map = WorldMapFrame
    local used = 0
    if map and map:IsShown() and map.GetMapID and map.GetCanvas and M.Enabled() then
        local canvas = map:GetCanvas()
        local shown = map:GetMapID()
        if canvas and shown then
            local w, h = canvas:GetWidth(), canvas:GetHeight()
            local scale = 1 / math.max(.01, canvas:GetScale())
            each(function(who, p, info)
                local x, y = onMap(p, shown)
                if not x then return end
                used = used + 1
                local f = pin(pins.world, used, canvas, 16)
                f.who = who
                f:SetScale(scale)
                f:SetFrameStrata(map:GetFrameStrata())
                f:SetFrameLevel(canvas:GetFrameLevel() + 500)
                f:ClearAllPoints()
                f:SetPoint("CENTER", canvas, "TOPLEFT", x * w / scale, -y * h / scale)
                look(f, info)
                f:Show()
            end)
        end
    end
    for i = used + 1, #pins.world do pins.world[i]:Hide() end
    pins.worldUsed = used
end

function U.RefreshMinimapPins()
    local used = 0
    if Minimap and Minimap:IsShown() and M.Enabled() and next(M.positions) then
        local here, px, py = M.Here()
        local yards = here and size(here)
        if yards then
            local zoom = (Minimap.GetZoom and Minimap:GetZoom() or 0) + 1
            local across = ((IsIndoors and IsIndoors()) and indoor or outdoor)[zoom] or outdoor[1]
            local radius = Minimap:GetWidth() / 2
            local perYard = Minimap:GetWidth() / across
            local facing = 0
            if GetCVar and GetCVar("rotateMinimap") == "1" and GetPlayerFacing then
                local ok, f = pcall(GetPlayerFacing)
                if ok and type(f) == "number" then facing = f end
            end
            local cos, sin = math.cos(-facing), math.sin(-facing)
            each(function(who, p, info)
                local x, y = onMap(p, here)
                if not x then return end
                -- East and north of this character, in yards, then on the minimap in pixels.
                local east, north = (x - px) * yards[1], (py - y) * yards[2]
                local dx, dy = (east * cos - north * sin) * perYard, (east * sin + north * cos) * perYard
                if dx * dx + dy * dy > (radius - 4) * (radius - 4) then return end
                used = used + 1
                local f = pin(pins.mini, used, Minimap, 14)
                f.who = who
                f:SetFrameLevel(Minimap:GetFrameLevel() + 5)
                f:ClearAllPoints()
                f:SetPoint("CENTER", Minimap, "CENTER", dx, dy)
                look(f, info)
                f:Show()
            end)
        end
    end
    for i = used + 1, #pins.mini do pins.mini[i]:Hide() end
    pins.miniUsed = used
end

function U.RefreshMapPins()
    pcall(U.RefreshWorldPins)
    pcall(U.RefreshMinimapPins)
end

-- Kept in place while the map is open or the character moves: a few times a second, and only
-- while there is someone to show.
function U.StartMapPins()
    if U.mapTicker or not CreateFrame then return end
    local f = CreateFrame("Frame")
    U.mapTicker = f
    local since = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        since = since + elapsed
        if since < .2 then return end
        since = 0
        if not next(M.positions) and (pins.worldUsed or 0) == 0 and (pins.miniUsed or 0) == 0 then return end
        U.RefreshMapPins()
    end)
end
