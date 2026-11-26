local _, E = ...
local U, S = E.UI, E.Store
local C = U.colors
local media = "Interface\\AddOns\\Emberlight\\Media\\"
-- The Schedule's Month view (1.0.4), made to look like the guild website's calendar as far as the
-- game allows: a Monday-first month on the realm's clock, a ledger on parchment, guild events in
-- gold (a Story Event in crimson), members' Adventures in blue, a wax seal on today, and the day's
-- list underneath. Only the guild's own plans are shown: Blizzard's holidays were tried and left
-- out (owner, 26 November 2026: the game's calendar marked every day). Nothing here reads or
-- changes the game's own calendar.
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end

local CELL_W, CELL_H, GRID_X, GRID_Y = 126, 34, 38, -220
local STORY, GUILD, MEMBER = { .70, .15, .23 }, { .79, .60, .25 }, { .20, .36, .62 }
local INK = { .114, .102, .082 }
local PIPS = 6

local function kindOf(entry)
    if E.Kind(entry) == E.storyLabel then return STORY end
    return entry.categoryIndex == 4 and GUILD or MEMBER
end

-- The day offset (from today) of the first of the month that holds `offset`.
local function firstOfMonth(offset)
    return offset - math.max(1, E.Client.MonthDay(E.Client.DayStart() + offset * 86400 + 43200)) + 1
end
local function noon(day) return E.Client.DayStart() + day * 86400 + 43200 end

local function earlier(a, b)
    if a.start ~= b.start then return a.start < b.start end
    if (a.categoryIndex == 4) ~= (b.categoryIndex == 4) then return a.categoryIndex == 4 end
    return a.id < b.id
end

function U.CreateMonth()
    local page = CreateFrame("Frame", nil, U.reader)
    page:SetAllPoints(U.reader)
    page:Hide()
    U.monthPage = page
    U.monthTitle = at(U.FitText(U.Text(page, "", 22, C.ink), 230, 30, false), 40, -160)
    -- What the colours mean.
    local legend, x = {}, 262
    for _, item in ipairs({ { "Story Event", STORY, 96 }, { "Guild event", GUILD, 90 }, { "Adventure", MEMBER, 82 } }) do
        local pip = page:CreateTexture(nil, "ARTWORK")
        pip:SetSize(12, 12); pip:SetPoint("TOPLEFT", x, -168); pip:SetColorTexture(unpack(item[2]))
        local label = at(U.FitText(U.Text(page, item[1], 14, C.paperMuted), item[3], 18, false), x + 16, -165)
        legend[#legend + 1] = { pip = pip, label = label }
        x = x + 16 + item[3] + 10
    end
    U.monthLegend = legend
    U.monthBack = at(U.Button(page, "<", 34, function() U.TurnMonth(-1) end, "flat"), 748, -156)
    U.monthNext = at(U.Button(page, ">", 34, function() U.TurnMonth(1) end, "flat"), 786, -156)
    U.monthToday = at(U.Button(page, "This month", 98, function() U.OpenMonth() end, "flat"), 824, -156)
    for _, b in ipairs({ U.monthBack, U.monthNext, U.monthToday }) do b:SetHeight(30) end
    for i, name in ipairs({ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }) do
        local head = at(U.FitText(U.Text(page, name, 14, C.brown, nil, "caps"), CELL_W, 18, false), GRID_X + (i - 1) * CELL_W, -198)
        head:SetJustifyH("CENTER")
    end
    U.Rule(page, GRID_X, -217, CELL_W * 7, { .361, .325, .271, .55 })
    U.monthCells = {}
    for i = 1, 42 do
        local cell = CreateFrame("Button", nil, page, "BackdropTemplate")
        cell:SetSize(CELL_W, CELL_H)
        cell:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        at(cell, GRID_X + ((i - 1) % 7) * CELL_W, GRID_Y - math.floor((i - 1) / 7) * CELL_H)
        cell.number = at(U.FitText(U.Text(cell, "", 15, INK, nil, "game"), 28, 18, false), 6, -3)
        cell.seal = cell:CreateTexture(nil, "OVERLAY")
        cell.seal:SetSize(18, 18); cell.seal:SetPoint("TOPRIGHT", -4, -3); cell.seal:SetTexture(media .. "Seal.tga")
        cell.pips = {}
        for p = 1, PIPS do
            local pip = cell:CreateTexture(nil, "ARTWORK")
            pip:SetSize(16, 7); pip:SetPoint("BOTTOMLEFT", 6 + (p - 1) * 19, 4)
            cell.pips[p] = pip
        end
        cell.more = U.FitText(U.Text(cell, "", 14, C.paperMuted), 30, 16, false)
        cell.more:SetPoint("TOPRIGHT", -24, -4); cell.more:SetJustifyH("RIGHT")
        cell:SetScript("OnClick", function(self)
            if self.day == nil then return end
            U.monthChosen = self.day
            U.RefreshMonth()
        end)
        cell:SetScript("OnEnter", function(self)
            self.hover = true; U.PaintMonthCell(self)
            local lines = self.lines
            if not lines or #lines == 0 then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(E.Client.Date(self.noon), 1, 1, 1)
            for _, line in ipairs(lines) do GameTooltip:AddLine(line, .9, .86, .75) end
            GameTooltip:Show()
        end)
        cell:SetScript("OnLeave", function(self) self.hover = false; U.PaintMonthCell(self); GameTooltip:Hide() end)
        U.monthCells[i] = cell
    end
    -- The chosen day, underneath: its heading, then a short ledger of what happens.
    U.monthDayHead = at(U.FitText(U.Text(page, "", 14, C.brown, nil, "caps"), 600, 18, false), 40, -434)
    U.Rule(page, GRID_X, -454, CELL_W * 7, { .361, .325, .271, .55 })
    local list = U.Scroll(page, 884, 124)
    list:SetPoint("TOPLEFT", 38, -458)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(858, 124); list:SetScrollChild(child)
    U.monthList, U.monthChild, U.monthRows = list, child, {}
    U.monthEmpty = at(U.FitText(U.Text(child, "", 15, C.paperMuted), 800, 20, false), 8, -8)
end

-- One day's box: tinted by its most important event, the chosen one framed and the pointed-at one
-- a little stronger.
function U.PaintMonthCell(cell)
    local tint = cell.tint
    local alpha = tint and (cell.chosen and .42 or cell.hover and .34 or .24) or (cell.chosen and .16 or cell.hover and .10 or 0)
    local color = tint or INK
    cell:SetBackdropColor(color[1], color[2], color[3], alpha)
    if cell.chosen then cell:SetBackdropBorderColor(.42, .353, .204, 1)
    else cell:SetBackdropBorderColor(.361, .325, .271, cell.inMonth and .4 or .15) end
end

function U.TurnMonth(delta)
    local first = U.monthFirst or firstOfMonth(0)
    local target = firstOfMonth(first + (delta < 0 and -1 or 31))
    if target < firstOfMonth(0) or target > E.officialDays then return end
    U.monthFirst = target
    -- The chosen day follows into the new month: the same date, or its first day.
    U.monthChosen = target
    if target == firstOfMonth(0) then U.monthChosen = 0 end
    U.RefreshMonth()
end

-- Open on this month with today chosen (the first time, and "This month").
function U.OpenMonth()
    U.monthFirst = firstOfMonth(0); U.monthChosen = 0
    if U.monthPage and U.monthPage:IsShown() then U.RefreshMonth() end
end

local function dayRow(i)
    local row = U.monthRows[i]
    if row then return row end
    row = U.Button(U.monthChild, "", 854, function(self)
        local entry = self.entry
        if not entry then return end
        U.selected = entry; U.expanded = true; entry.read = true
        U.Refresh()
    end, "row")
    row:SetHeight(28); row.label:Hide()
    row.stripe = U.Inlay(row, 0, -4, 3, 20, GUILD)
    row.clock = at(U.FitText(U.Text(row, "", 14, C.brown, nil, "caps"), 90, 18, false), 10, -5)
    row.title = at(U.FitText(U.Text(row, "", 15, C.ink, nil, "game"), 470, 18, false), 104, -5)
    row.kind = at(U.FitText(U.Text(row, "", 14, C.paperMuted), 150, 18, false), 584, -5)
    row.note = U.FitText(U.Text(row, "", 14, C.brown), 100, 18, false)
    row.note:SetPoint("TOPRIGHT", -8, -5); row.note:SetJustifyH("RIGHT")
    U.monthRows[i] = row
    return row
end

function U.RefreshMonth()
    if not U.monthPage then return end
    local now, today = E.Client.Now(), E.Client.DayStart()
    local first = U.monthFirst or firstOfMonth(0)
    U.monthFirst = first
    if U.monthChosen == nil then U.monthChosen = 0 end
    local firstNoon = noon(first)
    local monthName = E.Client.MonthYear(firstNoon)
    U.monthTitle:SetText(monthName)
    U.monthBack:SetEnabled(first > firstOfMonth(0))
    U.monthNext:SetEnabled(firstOfMonth(first + 31) <= E.officialDays)
    U.monthToday:SetEnabled(first ~= firstOfMonth(0) or U.monthChosen ~= 0)
    -- What is on, by day offset from today.
    local byDay = {}
    for _, e in ipairs(E.Sync.List()) do
        if not e.cancelled and e.expires > now then
            local day = math.floor((e.start - today) / 86400)
            byDay[day] = byDay[day] or {}
            table.insert(byDay[day], e)
        end
    end
    for _, list in pairs(byDay) do table.sort(list, earlier) end
    local lead = E.Client.Weekday(firstNoon)
    for i, cell in ipairs(U.monthCells) do
        local day = first + i - 1 - lead
        local stamp = noon(day)
        cell.inMonth = E.Client.MonthYear(stamp) == monthName
        cell.noon = stamp
        cell.day = cell.inMonth and day or nil
        cell.chosen = cell.inMonth and day == U.monthChosen
        cell.number:SetText(E.Client.MonthDay(stamp))
        cell.number:SetTextColor(unpack(cell.inMonth and INK or C.paperMuted))
        cell.number:SetAlpha(cell.inMonth and 1 or .45)
        cell.seal:SetShown(cell.inMonth and day == 0)
        local events = cell.inMonth and byDay[day] or nil
        cell.lines = {}
        local top
        for p = 1, PIPS do
            local entry = events and events[p]
            cell.pips[p]:SetShown(entry ~= nil)
            if entry then cell.pips[p]:SetColorTexture(unpack(kindOf(entry))) end
        end
        if events then
            for _, entry in ipairs(events) do
                local color = kindOf(entry)
                if top == nil or color == STORY or (color == GUILD and top ~= STORY) then top = color end
                if #cell.lines < 8 then cell.lines[#cell.lines + 1] = E.Client.Clock(entry.start) .. "  " .. E.Clean(entry.title, 60) end
            end
        end
        cell.tint = top
        cell.more:SetText(events and #events > PIPS and ("+" .. (#events - PIPS)) or "")
        cell:SetEnabled(cell.inMonth)
        U.PaintMonthCell(cell)
    end
    -- The chosen day, underneath.
    local chosen = U.monthChosen
    local stamp = noon(chosen)
    U.monthDayHead:SetText((chosen == 0 and "Today  /  " or chosen == 1 and "Tomorrow  /  " or "") .. E.Client.Date(stamp) .. "  /  server time")
    local events = byDay[chosen] or {}
    local y, count = 0, 0
    for _, entry in ipairs(events) do
        count = count + 1
        local row = dayRow(count)
        row.entry = entry
        row:SetPoint("TOPLEFT", 0, -y); y = y + 30
        local color = kindOf(entry)
        row.stripe:SetColorTexture(color[1], color[2], color[3], 1)
        local happening = entry.start <= now
        row.clock:SetText(happening and "Now" or E.Client.Clock(entry.start))
        row.title:SetText(E.Clean(entry.title, 100))
        row.kind:SetText(E.Kind(entry))
        local joining = E.Sync.Answers and entry.live and #(E.Sync.Answers(entry)) or 0
        row.note:SetText(entry.own and "You host" or entry.reply == "I will join" and "You're going" or entry.reply == "Unable to attend" and "Can't attend" or joining > 0 and (joining .. " joining") or "")
        row:SetAlpha(1); row:Show()
        U.SelectButton(row, false)
    end
    for i = count + 1, #U.monthRows do U.monthRows[i].entry = nil; U.monthRows[i]:Hide() end
    U.monthEmpty:SetText(count == 0 and (chosen < 0 and "That day has passed." or "Nothing is planned for this day.") or "")
    U.monthChild:SetHeight(math.max(U.monthList:GetHeight(), y))
    U.UpdateScroll(U.monthList)
end
