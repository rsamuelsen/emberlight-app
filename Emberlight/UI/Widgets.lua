local _, E = ...
E.UI = { tab = "Home" }
local U = E.UI
-- A guild ledger: a navy leather cover with gold lettering, and one parchment page written in ink.
-- `text`, `muted`, `gold` and `goldHi` are for the leather; `ink`, `paperMuted`, `brown`, `rule`
-- and `wax` (the one main action, and what is new) are for the page.
U.colors = {
    text = { .914, .894, .824 }, muted = { .725, .761, .776 }, faint = { .545, .592, .612 },
    gold = { .788, .604, .247 }, goldHi = { .906, .784, .459 },
    ink = { .114, .102, .082 }, paperMuted = { .361, .325, .271 }, brown = { .42, .353, .204 },
    rule = { .361, .325, .271, .55 }, wax = { .478, .165, .133 }, waxHi = { .58, .22, .18 }, ivory = { .94, .89, .78 },
}
U.ink = U.colors.ink
U.paperMuted = U.colors.paperMuted
local media = "Interface\\AddOns\\Emberlight\\Media\\"
-- The game's own fonts (owner's choice, 2 October 2026): the standard text font for everything,
-- page headings included, and Morpheus, the quest-title font, only for the guild's name under the
-- crest (its lowercase is too unusual to read as a heading). Their numerals sit level, which the
-- website's fonts' did not, and the standard font has every alphabet.
U.fonts = { title = "Fonts\\MORPHEUS.TTF" }

function U.Surface(parent, file)
    local texture = parent:CreateTexture(nil, "BACKGROUND", nil, 2)
    texture:SetAllPoints(parent)
    texture:SetTexture(media .. file)
    return texture
end

-- Inlays sit on the parent's background layer, beneath its labels and controls.
function U.Inlay(parent, x, y, width, height, color)
    local fill = parent:CreateTexture(nil, "BACKGROUND")
    fill:SetPoint("TOPLEFT", x, y); fill:SetSize(width, height)
    fill:SetColorTexture(unpack(color))
    return fill
end

-- A notice's author as members read it: the name without its realm, which on WoW: Forever is a
-- hidden part of the megarealm (a member's own notices, and the server's copies, carry it).
function U.Author(value, limit) return (E.Clean(value, 120):match("^[^-]*")):sub(1, limit) end

function U.Rule(parent, x, y, width, color)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", x, y); rule:SetSize(width, 1)
    rule:SetColorTexture(unpack(color or U.colors.rule))
    return rule
end

-- A separate sheet laid over the page, for a preview or a form.
function U.Paper(parent, width, height)
    local paper = U.Panel(parent, width, height, { .847, .824, .741, 1 })
    paper:SetBackdropBorderColor(.114, .102, .082, .9)
    paper.surface = U.Surface(paper, "Page.tga")
    paper.surface:SetTexCoord(.08, .92, .08, .92)
    paper:SetClipsChildren(true)
    return paper
end

function U.FitText(text, width, height, wrap)
    text:SetSize(width, height)
    text:SetWordWrap(wrap == true)
    text:SetNonSpaceWrap(wrap == true)
    return text
end

-- Width includes the scrollbar, unlike Blizzard's template default footprint.
function U.UpdateScroll(scroll)
    local child = scroll:GetScrollChild()
    local overflow = child and child:GetHeight() > scroll:GetHeight() + 1
    if scroll.ScrollBar then scroll.ScrollBar:SetShown(overflow == true) end
    local max = child and math.max(0, child:GetHeight() - scroll:GetHeight()) or 0
    if scroll:GetVerticalScroll() > max then scroll:SetVerticalScroll(max) end
end

function U.Scroll(parent, width, height)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetSize(width - 26, height)
    if scroll.ScrollBar then
        scroll.ScrollBar:ClearAllPoints()
        scroll.ScrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, -16)
        scroll.ScrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 16)
        scroll.ScrollBar:SetWidth(16)
        scroll.ScrollBar:HookScript("OnShow", function(bar)
            local child = scroll:GetScrollChild()
            if not child or child:GetHeight() <= scroll:GetHeight() + 1 then bar:Hide() end
        end)
        scroll.ScrollBar:Hide()
    end
    scroll:HookScript("OnScrollRangeChanged", function(self) U.UpdateScroll(self) end)
    scroll:HookScript("OnShow", function(self) U.UpdateScroll(self) end)
    return scroll
end

-- A flat surface with a fine ink edge.
function U.Panel(parent, width, height, color)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if width then f:SetSize(width, height) end
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(unpack(color or { 1, 1, 1, .2 }))
    f:SetBackdropBorderColor(unpack(U.colors.rule))
    return f
end
function U.Text(parent, text, size, color, width, face)
    local t = parent:CreateFontString(nil, "OVERLAY")
    size = size or 14
    -- Keep labels readable too; only the member's chosen reading size may be smaller than 14.
    if face == "title" then t:SetFont(U.fonts.title, size, "")
    else t:SetFont(STANDARD_TEXT_FONT, math.max(14, size), "") end
    -- A font that will not load would leave the text invisible; the standard font always loads.
    if not t:GetFont() then t:SetFont(STANDARD_TEXT_FONT, size, "") end
    t:SetTextColor(unpack(color or U.colors.ink))
    t:SetJustifyH("LEFT")
    t:SetJustifyV("TOP")
    if width then t:SetWidth(width) end
    t:SetText(text or "")
    return t
end

-- One button, six looks: "seal" is the wax-red main action of a page, "ink" every other control
-- on the page, "flat" a small choice drawn in ink (filled when it is the one chosen), "bare" a
-- mark with no edge, "nav" a place in the rail on the leather, and "row" one line of a ledger list.
local C = U.colors
local clear = { 0, 0, 0, 0 }
local looks = {
    header = { bg = clear, hover = {1,1,1,.08}, border = clear, text = C.text, selectedText = C.goldHi },
    brass = { bg = {.11,.17,.21,1}, hover = {.18,.27,.32,1}, border = C.gold, text = C.goldHi },
    seal = { bg = C.wax, hover = C.waxHi, border = { .31, .09, .07, 1 }, text = C.ivory },
    ink = { bg = {.13,.21,.25,1}, hover = {.21,.32,.36,1}, border = {.49,.49,.38,1}, text = C.ivory, selectedBg = {.15,.34,.34,1} },
    flat = { bg = {.09,.16,.20,1}, hover = {.17,.27,.31,1}, border = {.32,.40,.40,1}, text = C.text,
        selectedBg = {.26,.17,.075,1}, selectedText = C.goldHi },
    bare = { bg = clear, hover = { .114, .102, .082, .12 }, border = clear, text = C.ink },
    nav = { bg = clear, hover = { 1, 1, 1, .05 }, border = clear, text = C.muted, selectedText = C.ink },
    row = { bg = clear, hover = { .114, .102, .082, .07 }, border = clear, text = C.ink, selectedBg = { .361, .325, .271, .16 } },
}
-- Paint the two ends independently so the filigree keeps its shape on short controls.
local plates = { seal = "PlateRed.tga", brass = "PlateBlue.tga", flat = "PlateBlue.tga", ink = "PlateBlue.tga" }
local function plate(b)
    local art = plates[b.variant]
    if art and b.selected then art = "PlateGold.tga" end
    for i, texture in ipairs(b.skin) do
        texture:SetShown(art ~= nil)
        if art then
            texture:SetTexture(media .. art)
            local left = i == 1 and 0 or i == 2 and .10 or .90
            local right = i == 1 and .10 or i == 2 and .90 or 1
            texture:SetTexCoord(left, right, 0, 1)
        end
    end
    if art then
        local cap = math.min(b:GetHeight() * .33, b:GetWidth() * .25)
        b.skin[1]:SetWidth(cap); b.skin[3]:SetWidth(cap)
        b.skin[2]:ClearAllPoints(); b.skin[2]:SetPoint("TOPLEFT", cap, 0); b.skin[2]:SetPoint("BOTTOMRIGHT", -cap, 0)
    end
    return art ~= nil
end
function U.ButtonState(b)
    local look = looks[b.variant] or looks.ink
    if plate(b) then
        local shade = b.pressed and .67 or b.hover and 1 or b.selected and .78 or .89
        for _, texture in ipairs(b.skin) do texture:SetVertexColor(shade, shade, shade) end
        b:SetBackdropColor(0, 0, 0, 0); b:SetBackdropBorderColor(0, 0, 0, 0)
        b.label:SetTextColor(unpack(b.selected and look.selectedText or look.text))
        return
    end
    local bg = b.hover and look.hover or b.selected and look.selectedBg or look.bg
    local r, g, bl, a = unpack(bg)
    local shade = b.pressed and .8 or 1
    b:SetBackdropColor(r * shade, g * shade, bl * shade, a or 1)
    b:SetBackdropBorderColor(unpack(look.border))
    b.label:SetTextColor(unpack(b.selected and look.selectedText or look.text))
    if b.mark then b.mark:SetShown(b.selected or false) end
    if b.badge and b.variant == "nav" then
        -- On the bookmark the count is written in ink, clear of the ribbon's notched end.
        b.badge:SetTextColor(unpack(b.selected and C.ink or C.goldHi))
        b.badge:ClearAllPoints(); b.badge:SetPoint("RIGHT", b.selected and -36 or -12, 0)
    end
end
function U.SelectButton(b, selected)
    b.selected = selected
    U.ButtonState(b)
end
function U.SetVariant(b, variant)
    b.variant = variant
    U.ButtonState(b)
end
function U.Button(parent, text, width, click, variant)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width or 140, 32)
    b.variant = variant or "ink"
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b.skin = {}
    for i, coords in ipairs({ { 0, .1 }, { .1, .9 }, { .9, 1 } }) do
        local texture = b:CreateTexture(nil, "BACKGROUND")
        texture:SetTexCoord(coords[1], coords[2], 0, 1)
        if i == 1 then texture:SetPoint("TOPLEFT"); texture:SetPoint("BOTTOMLEFT")
        elseif i == 3 then texture:SetPoint("TOPRIGHT"); texture:SetPoint("BOTTOMRIGHT") end
        b.skin[i] = texture
    end

    b.label = U.Text(b, text, variant == "nav" and 17 or 15)
    b.label:SetJustifyV("MIDDLE")
    if variant == "header" then
        b.label:SetPoint("CENTER"); b.label:SetJustifyH("CENTER")
        b.mark = U.Rule(b, 2, -30, width - 4, C.goldHi)
        b.mark:SetHeight(2)
    elseif variant == "nav" then
        b.label:SetPoint("LEFT", 30, 0)
        -- A gold cloth bookmark lies under the place the member is in.
        b.mark = b:CreateTexture(nil, "BACKGROUND")
        b.mark:SetPoint("TOPLEFT", 4, -1); b.mark:SetPoint("BOTTOMRIGHT", -4, 1)
        b.mark:SetTexture(media .. "Bookmark.tga")
        b.mark:SetVertexColor(.92, .88, .8)
    elseif variant == "row" then
        b.label:SetPoint("CENTER")
        b.under = U.Rule(b, 0, 0, width or 140, { .361, .325, .271, .4 })
        b.under:ClearAllPoints(); b.under:SetPoint("BOTTOMLEFT"); b.under:SetPoint("BOTTOMRIGHT"); b.under:SetHeight(1)
    else
        b.label:SetPoint("CENTER")
        b.label:SetJustifyH("CENTER")
    end
    -- A narrow button (a plus, a minus, the cross) gives its whole width to its mark.
    local function room(self, w, h)
        local narrow = w < 60
        U.FitText(self.label, w - (self.variant == "nav" and 40 or narrow and 0 or 20), narrow and h or math.min(20, h - 8), false)
    end
    room(b, width or 140, 32)
    b:SetScript("OnSizeChanged", function(self, w, h)
        U.ButtonState(self)
        room(self, w, h)
    end)
    b:SetScript("OnEnter", function(self) self.hover = true; U.ButtonState(self) end)
    b:SetScript("OnLeave", function(self) self.hover = false; self.pressed = false; U.ButtonState(self) end)
    b:SetScript("OnMouseDown", function(self) self.pressed = true; U.ButtonState(self) end)
    b:SetScript("OnMouseUp", function(self) self.pressed = false; U.ButtonState(self) end)
    b:SetScript("OnClick", click)
    b:SetScript("OnDisable", function(self) self:SetAlpha(.4) end)
    b:SetScript("OnEnable", function(self) self:SetAlpha(1) end)
    U.ButtonState(b)
    return b
end
function U.Field(parent, label, x, y, width, height, max, multiline)
    local caption = U.Text(parent, label, 14, U.colors.paperMuted)
    caption:SetPoint("TOPLEFT", x, y)
    -- A writing panel: paler paper inside a thin ink border, toned to sit on the page.
    local surround = U.Panel(parent, width, height, { 0, 0, 0, 0 })
    surround:SetBackdropBorderColor(0, 0, 0, 0)
    surround.surface = U.Surface(surround, "Field.tga")
    surround.surface:SetVertexColor(.93, .95, 1)
    surround:SetClipsChildren(true)
    surround:SetPoint("TOPLEFT", x, y - 20)
    local edit = CreateFrame("EditBox", nil, surround)
    edit.caption = caption
    edit:SetPoint("TOPLEFT", 10, -8)
    edit:SetPoint("BOTTOMRIGHT", -10, 8)
    edit:SetFont(STANDARD_TEXT_FONT, 14, "")
    edit:SetTextColor(unpack(U.colors.ink))
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(max)
    edit:SetMultiLine(multiline or false)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if not multiline then edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end) end
    -- A click anywhere in the panel starts writing, not only on the text itself (a multi-line box
    -- is as high as its text, one line while empty).
    surround:EnableMouse(true)
    surround:SetScript("OnMouseDown", function() edit:SetFocus(); edit:SetCursorPosition(#edit:GetText()) end)
    return edit
end
-- Reading text: the long, scrolling text of a notice. Its size is the member's choice in Settings.
-- Only text that reflows inside a scroll area follows it, so a larger size never clips a label.
U.textSizes = { { 13, "Small" }, { 15, "Normal" }, { 17, "Large" }, { 19, "Largest" } }
U.reading = {}
function U.TextSize()
    local db = E.Store and E.Store.db
    return db and db.settings.textSize or 15
end
function U.ApplyTextSize()
    for _, apply in ipairs(U.reading) do apply(U.TextSize()) end
end
function U.ScrollText(parent, width, height, color)
    local scroll = U.Scroll(parent, width, height)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(width - 32, height)
    scroll:SetScrollChild(child)
    local text = U.Text(child, "", U.TextSize(), color, width - 32, "game")
    text:SetFont(STANDARD_TEXT_FONT, U.TextSize(), "")
    text:SetWordWrap(true); text:SetNonSpaceWrap(true)
    text:SetPoint("TOPLEFT")
    scroll.text = text
    scroll.Reflow = function(self)
        local w = self:GetWidth() - 6
        child:SetWidth(w); text:SetWidth(w)
        child:SetHeight(math.max(self:GetHeight(), text:GetStringHeight() + 12))
        U.UpdateScroll(self)
    end
    scroll.SetContent = function(self, content)
        if self.content == content then U.UpdateScroll(self); return end
        self.content = content
        text:SetText(content)
        self:Reflow()
        self:SetVerticalScroll(0)
        U.UpdateScroll(self)
    end
    U.reading[#U.reading + 1] = function(size)
        text:SetFont(STANDARD_TEXT_FONT, size, "")
        scroll:Reflow()
    end
    return scroll
end
-- A setting chosen with two buttons: a caption, then less, the current value, more.
function U.Stepper(parent, label, x, y, width, step, size, dark)
    size = size or 32
    local caption = U.Text(parent, label, 14, dark and C.muted or C.paperMuted)
    caption:SetPoint("TOPLEFT", x, y)
    local s = {}
    s.less = U.Button(parent, "-", size, function() step(-1) end, "flat")
    s.less:SetPoint("TOPLEFT", x, y - 20)
    s.value = U.FitText(U.Text(parent, "", 16, dark and C.ivory or C.ink), width - 2 * size - 8, 20, false)
    s.value:SetPoint("TOPLEFT", x + size + 4, y - 26)
    s.value:SetJustifyH("CENTER")
    s.more = U.Button(parent, "+", size, function() step(1) end, "flat")
    s.more:SetPoint("TOPLEFT", x + width - size, y - 20)
    return s
end
-- The line at the foot of the page: what just happened, or why something could not.
function U.Status(message)
    if U.statusTimer then U.statusTimer:Cancel(); U.statusTimer = nil end
    if not U.status then return end
    U.status:SetText(message or "")
    if message and message ~= "" then
        U.statusTimer = C_Timer.NewTimer(8, function() U.status:SetText(""); U.statusTimer = nil end)
    end
end
-- "in 2 days": how soon something starts, for lists and the reader.
function U.Until(timestamp)
    local seconds = timestamp - E.Client.Now()
    if seconds <= 0 then return "started" end
    if seconds < 3600 then return "in " .. math.max(1, math.floor(seconds / 60)) .. " min" end
    if seconds < 172800 then local h = math.floor(seconds / 3600); return "in " .. h .. (h == 1 and " hour" or " hours") end
    return "in " .. math.floor(seconds / 86400) .. " days"
end
-- A month on the realm clock. Both picking a start and browsing the schedule use
-- the same 42 cells and the same day limits. Day offsets are relative to today.
function U.MonthCalendar(parent, x, y, choose)
    local calendar = U.Paper(parent, 410, 346)
    calendar:SetPoint("TOPLEFT", x, y)
    calendar:SetFrameLevel(parent:GetFrameLevel() + 30)
    calendar:EnableMouse(true)
    local function label(text, left, top, width)
        local t = U.FitText(U.Text(calendar, text, 14, U.colors.brown), width, 19, false)
        t:SetPoint("TOPLEFT", left, top)
        return t
    end
    local function firstDay(today, offset)
        return offset - math.max(1, E.Client.MonthDay(today + offset * 86400 + 43200)) + 1
    end
    local function turn(delta)
        local edge = calendar.first + (delta < 0 and -1 or 31)
        calendar.first = firstDay(E.Client.DayStart(), edge)
        calendar:Paint()
    end
    calendar.month = label("", 16, -14, 235)
    calendar.back = U.Button(calendar, "<", 34, function() turn(-1) end, "flat")
    calendar.back:SetPoint("TOPLEFT", 272, -7)
    calendar.next = U.Button(calendar, ">", 34, function() turn(1) end, "flat")
    calendar.next:SetPoint("TOPLEFT", 311, -7)
    local close = U.Button(calendar, "X", 34, function() calendar:Hide() end, "flat")
    close:SetPoint("TOPLEFT", 358, -7)
    for i, day in ipairs({"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}) do
        label(day, 15 + (i-1)*55, -51, 50):SetJustifyH("CENTER")
    end
    calendar.cells = {}
    for i = 1, 42 do
        local cell = U.Button(calendar, "", 51, function(self)
            if self.days ~= nil then calendar:Hide(); choose(self.days) end
        end, "flat")
        cell:SetPoint("TOPLEFT", 15 + ((i-1)%7)*55, -75 - math.floor((i-1)/7)*43)
        cell:SetHeight(38)
        calendar.cells[i] = cell
    end
    function calendar:Paint()
        local today = E.Client.DayStart()
        local noon = today + self.first*86400 + 43200
        local month = E.Client.MonthYear(noon)
        self.month:SetText(month)
        self.back:SetEnabled(self.first > 0)
        self.next:SetEnabled(firstDay(today, self.first + 31) <= self.limit)
        local lead = E.Client.Weekday(noon)
        for i, cell in ipairs(self.cells) do
            local day = self.first + i - 1 - lead
            local t = today + day*86400
            local available = day >= 0 and day <= self.limit and E.Client.MonthYear(t + 43200) == month
            cell.days = available and day or nil
            cell:SetShown(available)
            if available then
                local count = self.counts and self.counts[day] or 0
                cell.label:SetText(E.Client.MonthDay(t + 43200) .. (count > 0 and "*" or ""))
                U.SelectButton(cell, day == self.chosen)
            end
        end
    end
    function calendar:Open(day, limit)
        self.chosen = math.max(0, math.min(day, limit))
        self.first = firstDay(E.Client.DayStart(), self.chosen)
        self.limit, self.counts = limit, nil
        self:Paint(); self:Show()
    end
    calendar:Hide()
    return calendar
end
