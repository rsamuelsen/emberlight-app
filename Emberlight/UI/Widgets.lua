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
    if not overflow and scroll:GetVerticalScroll() > 0 then scroll:SetVerticalScroll(0) end
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
    -- "title" is a heading. "game" is text at exactly the size given (what a member wrote). Labels
    -- and the small "caps" captions were sized for a narrower face, so they are set a little smaller.
    if face == "title" then t:SetFont(U.fonts.title, size, "")
    else t:SetFont(STANDARD_TEXT_FONT, face == "game" and size or face == "caps" and size - 2 or size - 1, "") end
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
    seal = { bg = C.wax, hover = C.waxHi, border = { .31, .09, .07, 1 }, text = C.ivory },
    ink = { bg = clear, hover = { .114, .102, .082, .1 }, border = { .114, .102, .082, .75 }, text = C.ink, selectedBg = { .114, .102, .082, .16 } },
    flat = { bg = clear, hover = { .114, .102, .082, .1 }, border = { .114, .102, .082, .7 }, text = C.ink, selectedBg = { .114, .102, .082, .88 }, selectedText = C.ivory },
    bare = { bg = clear, hover = { .114, .102, .082, .12 }, border = clear, text = C.ink },
    nav = { bg = clear, hover = { 1, 1, 1, .05 }, border = clear, text = C.muted, selectedText = C.ink },
    row = { bg = clear, hover = { .114, .102, .082, .07 }, border = clear, text = C.ink, selectedBg = { .361, .325, .271, .16 } },
}
-- "seal" and "ink" are painted plates: a wax-red one rimmed in pewter, and a slip of parchment
-- with an ink border. Each is drawn in three pieces so its shaped ends keep their proportions.
-- "flat", the small choice, is a square slip of the same parchment; its ends are narrower.
local plates = { seal = { "ButtonSeal.tga", .1, .6 }, ink = { "ButtonInk.tga", .1, .6 }, flat = { "ButtonSmall.tga", .2, .2 } }
local function plate(b)
    local art = plates[b.variant]
    for i, texture in ipairs(b.skin) do
        texture:SetShown(art ~= nil)
        if art then
            texture:SetTexture(media .. art[1])
            texture:SetTexCoord(i == 1 and 0 or i == 2 and art[2] or 1 - art[2], i == 1 and art[2] or i == 2 and 1 - art[2] or 1, 0, 1)
        end
    end
    if art then
        local cap = b:GetHeight() * art[3]
        b.skin[1]:SetWidth(cap); b.skin[3]:SetWidth(cap)
        b.skin[2]:ClearAllPoints(); b.skin[2]:SetPoint("TOPLEFT", cap, 0); b.skin[2]:SetPoint("BOTTOMRIGHT", -cap, 0)
    end
    return art ~= nil
end
function U.ButtonState(b)
    local look = looks[b.variant] or looks.ink
    if plate(b) then
        -- The chosen one of a set of small choices is inked in dark; other plates only dim.
        local shade = b.pressed and .72 or b.selected and (look.selectedText and .4 or .74) or b.hover and 1 or .92
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
    if b.badge then
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
    if variant == "nav" then
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
    text:SetWordWrap(true); text:SetNonSpaceWrap(true)
    text:SetPoint("TOPLEFT")
    scroll.text = text
    scroll.SetContent = function(self, content)
        if self.content == content then U.UpdateScroll(self); return end
        self.content = content
        text:SetText(content)
        child:SetHeight(math.max(height, text:GetStringHeight() + 12))
        self:SetVerticalScroll(0)
        U.UpdateScroll(self)
    end
    U.reading[#U.reading + 1] = function(size)
        text:SetFont(STANDARD_TEXT_FONT, size, "")
        child:SetHeight(math.max(height, text:GetStringHeight() + 12))
        U.UpdateScroll(scroll)
    end
    return scroll
end
-- A setting chosen with two buttons: a caption, then less, the current value, more.
function U.Stepper(parent, label, x, y, width, step, size)
    size = size or 32
    local caption = U.Text(parent, label, 14, U.colors.paperMuted)
    caption:SetPoint("TOPLEFT", x, y)
    local s = {}
    s.less = U.Button(parent, "-", size, function() step(-1) end, "flat")
    s.less:SetPoint("TOPLEFT", x, y - 20)
    s.value = U.FitText(U.Text(parent, "", 16, U.colors.ink), width - 2 * size - 8, 20, false)
    s.value:SetPoint("TOPLEFT", x + size + 4, y - 26)
    s.value:SetJustifyH("CENTER")
    s.more = U.Button(parent, "+", size, function() step(1) end, "flat")
    s.more:SetPoint("TOPLEFT", x + width - size, y - 20)
    return s
end
-- The line at the foot of the page: what just happened, or why something could not.
function U.Status(message)
    if U.status then U.status:SetText(message or "") end
end
-- "in 2 days": how soon something starts, for lists and the reader.
function U.Until(timestamp)
    local seconds = timestamp - E.Client.Now()
    if seconds <= 0 then return "started" end
    if seconds < 3600 then return "in " .. math.max(1, math.floor(seconds / 60)) .. " min" end
    if seconds < 172800 then local h = math.floor(seconds / 3600); return "in " .. h .. (h == 1 and " hour" or " hours") end
    return "in " .. math.floor(seconds / 86400) .. " days"
end
