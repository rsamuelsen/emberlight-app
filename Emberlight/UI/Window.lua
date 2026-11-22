local _, E = ...
local U, S = E.UI, E.Store
local C = U.colors
local media = "Interface\\AddOns\\Emberlight\\Media\\"

local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end
local function clean(value, limit) return E.Clean(value, limit) end
-- The two boards keep their names in code and saved data. Members see "Guild events" (official,
-- officers post) and "Adventures" (everyone posts).
local function board(categoryIndex) return categoryIndex == 4 and "Noticeboard" or "Letters" end
-- "Mine" lists the member's own notices from both boards.
U.labels = { Home = "Guild board", Schedule = "Schedule", Noticeboard = "Guild events", Letters = "Adventures", Mine = "Your notices", Settings = "Settings" }
-- What each kind of event is for, shown while writing one (0.9.3: three kinds, see E.Kind).
U.kindHelp = {
    story = "A major official event that may change the guild's story.",
    gathering = "An official event hosted by an officer, such as an initiation. It won't change the guild's story.",
    adventure = "Your own event: invite other members along for anything from a ride into the wilds to a quiet evening at the inn.",
}
-- How long a notice may stay on the board, in hours, with the words for each.
U.stays = { { 1, "1 hour" }, { 2, "2 hours" }, { 4, "4 hours" }, { 12, "12 hours" }, { 24, "1 day" }, { 72, "3 days" }, { 168, "1 week" } }

local function notices() return E.Sync.List() end
local function context() return E.Sync.ReadContext() end
local function officer()
    local _, roster, me = context()
    return roster and me and roster[me] and roster[me].officer or false
end
-- Who is joining and who cannot, for the reader and the count on each row.
local function answers(entry)
    if not entry.live then return {}, {} end
    return E.Sync.Answers(entry)
end
-- Something already under way: it started and has not ended.
local function happening(entry)
    local now = E.Client.Now()
    return entry.start <= now and entry.expires > now and not entry.cancelled
end
-- When something happens, as the whole guild reads it: the realm's clock, and the member's own
-- beside it when that differs.
local function when(timestamp)
    local own = E.Client.LocalClock(timestamp)
    return E.Client.Stamp(timestamp) .. " server time" .. (own ~= E.Client.Clock(timestamp) and (" (" .. own .. " your time)") or "")
end
local function state(entry)
    if entry.cancelled then
        if entry.moderated then return entry.moderatedBy and ("Removed by an officer (" .. clean(entry.moderatedBy, 60) .. ")") or "Removed by an officer" end
        return "Withdrawn"
    end
    if entry.expires <= E.Client.Now() then return "Ended" end
    if E.Sync.Pending(entry) then return "Sending..." end
    if entry.reply then return "Your answer: " .. entry.reply end
    return "On the board until " .. E.Client.Stamp(entry.expires)
end
-- "Today", "Tomorrow", then the date: the heading a notice is listed under.
local function dayName(timestamp, entry)
    if entry and happening(entry) then return "Happening now" end
    local days = math.floor((timestamp - E.Client.DayStart()) / 86400)
    return days <= 0 and "Today" or days == 1 and "Tomorrow" or E.Client.Date(timestamp)
end
local function caps(parent, text, x, y) return at(U.Text(parent, text, 14, C.brown, nil, "caps"), x, y) end
local function drawing(parent, file, width, height)
    local art = parent:CreateTexture(nil, "ARTWORK")
    art:SetSize(width, height)
    if file then art:SetTexture(media .. file) end
    art:SetVertexColor(.87, .84, .76)
    return art
end
local STORY_GOLD = {1, .84, .46}
-- One colour for each kind of event, the same as on the website (19 November 2026): crimson for a
-- Story Event, royal blue for a Guild Gathering, soft sage green for an Adventure. These are the
-- lighter tints, so the words stay readable on the dark board; `edge` frames the featured card.
local KIND_COLOR = {
    story = { text = {.96, .56, .62}, edge = {.70, .15, .23}, back = {.10, .035, .05, .86} },
    gathering = { text = {.60, .76, .98}, edge = {.24, .45, .78}, back = {.035, .06, .12, .86} },
    adventure = { text = {.62, .78, .67}, edge = {.56, .71, .60}, back = {.04, .085, .06, .86} },
}
local function kindColors(entry)
    local kind = E.Kind(entry)
    return KIND_COLOR[kind == E.storyLabel and "story" or entry.categoryIndex == 4 and "gathering" or "adventure"]
end
U.KindColors = kindColors
-- Every page hangs a little below the heading and its divider.
local function newPage()
    local page = CreateFrame("Frame", nil, U.frame)
    page:SetPoint("TOPLEFT", 0, -16); page:SetPoint("BOTTOMRIGHT", 0, -16)
    return page
end
-- A small sheet laid over the page to choose from, such as the calendar.
local function sheet(page, width, height, x, y)
    local s = at(U.Paper(page, width, height), x, y)
    s:SetFrameLevel(page:GetFrameLevel() + 20); s:EnableMouse(true); s:Hide()
    return s
end
-- The blue wax seal means one thing everywhere: this has not been opened yet. It is gone once
-- the member has read it, like the seal on a letter.
-- Pointing at one says so; a click still goes to whatever the seal lies on.
local function seal(parent, size)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size)
    local wax = holder:CreateTexture(nil, "OVERLAY")
    wax:SetAllPoints(holder); wax:SetTexture(media .. "Seal.tga")
    holder:EnableMouse(true)
    if holder.SetMouseClickEnabled then holder:SetMouseClickEnabled(false) end
    holder:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Not opened yet", 1, 1, 1)
        GameTooltip:Show()
    end)
    holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return holder
end
local function unreadMark(row)
    local dot = seal(row, 15)
    dot:SetPoint("TOPRIGHT", -5, -7)
    return dot
end
-- One line of a ledger list: the day and time in the margin, then the title and a note under it.
local function ledgerRow(parent, width, click)
    local row = U.Button(parent, "", width, click, "row")
    row:SetHeight(50); row.label:Hide()
    row.stripe = U.Inlay(row, 0, -6, 3, 38, C.gold)
    row.day = at(U.FitText(U.Text(row, "", 14, C.brown, nil, "caps"), 62, 16, false), 11, -8)
    row.clock = at(U.FitText(U.Text(row, "", 14, C.brown, nil, "caps"), 62, 16, false), 11, -26)
    row.title = at(U.FitText(U.Text(row, "", 14, C.ink, nil, "game"), width - 96, 18, false), 70, -8)
    row.meta = at(U.FitText(U.Text(row, "", 13, C.paperMuted, nil, "game"), width - 156, 16, false), 70, -28)
    -- How many are joining, at the foot of the row, so a busy one stands out.
    row.count = U.FitText(U.Text(row, "", 13, C.brown), 76, 16, false)
    row.count:SetPoint("TOPRIGHT", -8, -28); row.count:SetJustifyH("RIGHT")
    row.dot = unreadMark(row)
    return row
end
local function fillRow(row, entry, note)
    row.entry = entry
    row.day:SetText(happening(entry) and "Now" or E.Client.Clock(entry.start))
    local ownClock = E.Client.LocalClock(entry.start)
    row.clock:SetText(happening(entry) and ("to " .. E.Client.Clock(entry.expires)) or ownClock ~= E.Client.Clock(entry.start) and ("(" .. ownClock .. ")") or "")
    local official = entry.categoryIndex == 4
    row.stripe:SetColorTexture(unpack(official and (entry.story and C.wax or C.gold) or {.23,.39,.46,1}))
    row:SetAlpha(entry.cancelled and .68 or 1)
    row.title:SetText(clean(entry.title, 100))
    row.meta:SetText(note)
    local joining = answers(entry)
    row.count:SetText(#joining > 0 and (#joining .. " joining") or "")
    row.dot:SetShown(not entry.read and not entry.own and not entry.cancelled)
end

-- The guild crest on the rim of the minimap. Drag it around the rim; the place is remembered.
function U.CreateLauncher()
    local b = CreateFrame("Button", "EmberlightLauncher", Minimap)
    b:SetSize(34, 34)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetNormalTexture(media .. "Crest64.tga")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:RegisterForDrag("LeftButton")
    U.launcher = b
    -- A small seal with the number of notices not opened yet; nothing when there are none.
    b.seal = b:CreateTexture(nil, "OVERLAY")
    b.seal:SetSize(18, 18); b.seal:SetPoint("BOTTOMRIGHT", 4, -4)
    b.seal:SetTexture(media .. "Seal.tga")
    b.count = b:CreateFontString(nil, "OVERLAY")
    b.count:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    b.count:SetPoint("CENTER", b.seal, "CENTER", 0, 0)
    b.count:SetTextColor(1, 1, 1)
    local function follow()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        local angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
        if S.db then S.db.settings.minimap.angle = angle end
        U.PlaceLauncher(angle)
    end
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        if self.dragTimer then self.dragTimer:Cancel() end
        self.dragTimer = C_Timer.NewTicker(.05, follow)
    end)
    b:SetScript("OnDragStop", function(self) if self.dragTimer then self.dragTimer:Cancel(); self.dragTimer = nil end end)
    b:SetScript("OnClick", function() U.Toggle() end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Emberlight", .86, .68, .34)
        GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
        local newest = E.Presence and E.Presence.Newest()
        if newest then GameTooltip:AddLine("Version " .. newest .. " is out. Please update.", 1, .35, .2) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    U.PlaceLauncher()
end
-- How many open notices the member has not opened yet, on either board.
function U.UnreadCount()
    if not S.db then return 0 end
    local n = 0
    for _, e in ipairs(notices()) do
        if not e.read and not e.own and not e.cancelled and e.expires > E.Client.Now() then n = n + 1 end
    end
    return n
end
function U.UpdateLauncherBadge()
    local b = U.launcher
    if not b or not b.seal then return end
    local n = U.UnreadCount()
    b.seal:SetShown(n > 0); b.count:SetShown(n > 0)
    b.count:SetText(n > 9 and "9+" or tostring(n))
end
function U.PlaceLauncher(angle)
    local b = U.launcher
    if not b then return end
    local saved = S.db and S.db.settings.minimap
    local a = math.rad(angle or saved and saved.angle or 225)
    local radius = Minimap:GetWidth() / 2 + 6
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(a), radius * math.sin(a))
    b:SetShown(not (saved and saved.hide))
end

-- The window never grows past the screen, whatever size was chosen.
function U.FitScale()
    return math.min((UIParent:GetWidth() - 32) / 960, (UIParent:GetHeight() - 32) / 660)
end
function U.ApplyScale()
    if not U.frame then return end
    local chosen = S.db and S.db.settings.windowScale or 1
    U.frame:SetScale(math.max(.1, math.min(chosen, U.FitScale())))
end

function U.Toggle()
    if not (U.frame and U.frame:IsShown()) and InCombatLockdown and InCombatLockdown() then
        DEFAULT_CHAT_FRAME:AddMessage("Emberlight: open the ledger after combat.")
        return
    end
    if not U.frame then U.Create() end
    if U.frame:IsShown() then U.LeaveWriter(function() U.frame:Hide() end)
    else U.frame:Show(); U.frame:Raise(); U.Refresh(); U.Status(E.startupProblem) end
end

-- "Are you sure": a small sheet over the page before something that cannot be undone.
function U.Confirm(text, label, action, cancelLabel, cancel)
    local s = U.confirmSheet
    if not s then
        s = U.Paper(U.frame, 470, 170)
        s:SetPoint("CENTER", 0, 0); s:SetFrameLevel(U.frame:GetFrameLevel() + 40); s:EnableMouse(true)
        s.text = at(U.FitText(U.Text(s, "", 15, C.ink, nil, "game"), 422, 72, true), 24, -24)
        s.yes = at(U.Button(s, "", 200, function() s:Hide(); if s.action then s.action() end end, "seal"), 24, -118)
        s.no = at(U.Button(s, "Keep it", 210, function() s:Hide(); if s.cancel then s.cancel() end end), 234, -118)
        U.confirmSheet = s
    end
    s.text:SetText(text); s.yes.label:SetText(label); s.no.label:SetText(cancelLabel or "Keep it"); s.action = action; s.cancel = cancel
    s:Show()
end
-- Ordinary drafts save as you type. Edits are separate, so warn before discarding those words.
local function editChanged()
    local e, d = U.editing, U.draft
    return e and d and (d.title ~= e.title or d.location ~= e.location or d.body ~= e.body)
end
function U.LeaveWriter(action)
    if U.tab == "Write" and editChanged() then
        U.Confirm("Leave without saving these changes? Your original notice stays on the board.", "Leave without saving", action, "Keep editing")
    else action() end
end
-- Leaves whatever is being written and shows a page.
function U.Go(tab)
    U.LeaveWriter(function() U.GoNow(tab) end)
end
function U.GoNow(tab)
    if U.confirmSheet then U.confirmSheet:Hide() end
    if U.nowSheet then U.nowSheet:Hide() end
    if U.answersSheet then U.answersSheet:Hide() end
    if U.lineSheet then U.lineSheet:Hide() end
    if U.grandSheet then U.grandSheet:Hide() end
    if U.sceneSheet then U.sceneSheet:Hide() end
    U.expanded = false; U.homeView = nil; U.fromHome = nil; U.selected = nil
    U.filterWhen = "all"; U.dateFilter = nil
    if U.browseCalendar then U.browseCalendar:Hide() end
    U.editing = nil; U.composeBoard = nil; U.tab = tab
    if U.search then U.search:SetText(""); U.search:ClearFocus() end
    U.Refresh(); U.Status()
end
-- Opens one notice on its board, from Home.
function U.OpenEntry(entry)
    entry.read = true
    U.GoNow(board(entry.categoryIndex))
    U.selected = entry; U.fromHome = true; U.expanded = true
    U.Refresh()
end

-- One header is shared by the guild board, schedule, reader and tools.
function U.Create()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(960, 660)
    f.surface = U.Surface(f, "Cover.tga")
    f.surface:SetTexCoord(.17, .83, .17, .83)
    U.Rule(f, 0, -1, 960, C.gold)
    U.Rule(f, 0, -658, 960, C.gold)
    -- The same gold line down both sides, so the whole window has a border (the owner, 19 November).
    for _, x in ipairs({ 0, 959 }) do
        local side = f:CreateTexture(nil, "ARTWORK")
        side:SetPoint("TOPLEFT", x, -1); side:SetSize(1, 658)
        side:SetColorTexture(unpack(C.gold))
    end
    U.frame = f
    _G.EmberlightWindow = f
    table.insert(UISpecialFrames, "EmberlightWindow")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if S.db then
            local point, _, relativePoint, x, y = self:GetPoint()
            S.db.settings.position = { point, relativePoint, x, y }
        end
    end)
    U.ApplyScale()
    local p = S.db and S.db.settings.position
    local anchors = { CENTER=true, TOP=true, BOTTOM=true, LEFT=true, RIGHT=true, TOPLEFT=true, TOPRIGHT=true, BOTTOMLEFT=true, BOTTOMRIGHT=true }
    if type(p) == "table" and anchors[p[1]] and anchors[p[2]] and type(p[3]) == "number" and type(p[4]) == "number" then
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else f:SetPoint("CENTER") end

    U.parchment = f:CreateTexture(nil, "BORDER")
    U.parchment:SetPoint("TOPLEFT", 8, -58); U.parchment:SetPoint("BOTTOMRIGHT", -8, 8)
    U.parchment:SetTexture(media .. "Page.tga")
    U.parchment:SetTexCoord(.08, .92, .08, .92)
    U.masthead = f:CreateTexture(nil, "BORDER", nil, 4)
    U.masthead:SetPoint("TOPLEFT", 8, -58); U.masthead:SetSize(944, 102)
    local crest = at(drawing(f, "Crest64.tga", 44, 44), 17, -8)
    crest:SetVertexColor(1, 1, 1)
    at(U.Text(f, "Emberlight", 23, C.goldHi, nil, "title"), 68, -17)
    U.Rule(f, 12, -56, 936, C.gold)
    U.tabs = {}
    local function tab(key, x, width, secondary)
        local button = at(U.Button(f, U.labels[key], width, function() U.Go(key) end,
            secondary and "flat" or "header"), x, secondary and -121 or -11)
        button.badge = U.FitText(U.Text(button, "", 14, C.goldHi), 24, 18, false)
        button.badge:SetPoint("RIGHT", -2, 0)
        button.badgeSeal = seal(button, 10)
        button.badgeSeal:SetPoint("RIGHT", button.badge, "LEFT", -1, 0)
        U.tabs[key] = button
    end
    tab("Home", 206, 120)
    tab("Schedule", 334, 112)
    tab("Crafting", 454, 122)
    tab("Roster", 584, 132)
    tab("Noticeboard", 112, 143, true)
    tab("Letters", 260, 140, true)
    tab("Mine", 405, 132, true)
    U.allEvents = at(U.Button(f, "All plans", 91, function() U.Go("Schedule") end, "flat"), 17, -121)
    U.settingsButton = at(U.Button(f, "Settings", 98, function() U.Go("Settings") end, "header"), 803, -11)
    -- The realm's clock, in the header of every page (the owner, 19 November: it must always be visible,
    -- because every time in Emberlight is server time). Hover for the date and your own time.
    local clockBox = CreateFrame("Frame", nil, f)
    clockBox:SetSize(84, 42); at(clockBox, 718, -8)
    clockBox:EnableMouse(true)
    U.serverClockLabel = U.FitText(U.Text(clockBox, "Server time", 12, C.muted), 84, 14, false)
    U.serverClockLabel:SetPoint("TOP", 0, -2); U.serverClockLabel:SetJustifyH("CENTER")
    U.serverClockTime = U.FitText(U.Text(clockBox, "", 21, C.goldHi, nil, "game"), 84, 24, false)
    U.serverClockTime:SetPoint("TOP", 0, -17); U.serverClockTime:SetJustifyH("CENTER")
    clockBox:SetScript("OnEnter", function(self)
        local now = E.Client.Now()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Server time: " .. E.Client.Stamp(now) .. "\nYour time: " .. E.Client.LocalClock(now) .. "\nEvery time in Emberlight is server time.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    clockBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    U.pageTitle = at(U.FitText(U.Text(f, "", 26, C.ink), 490, 34, false), 38, -69)
    -- The close button stays in the header on every page.
    local close = at(U.Button(f, "×", 30, function() U.LeaveWriter(function() f:Hide() end) end, "brass"), 913, -12)
    close:SetHeight(30)
    U.action = at(U.Button(f, "", 170, function()
        if U.homeView then U.Go("Home")
        elseif U.tab == "Roster" then U.OpenGrand()
        elseif U.tab == "Write" then U.Go(U.returnTab or "Home") else U.StartCompose(U.tab) end
    end, "seal"), 751, -68)
    U.nowButton = at(U.Button(f, "Quick post", 120, function() U.OpenHereNow() end), 622, -68)
    U.nowButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:SetText("An Adventure starting now.", 1, 1, 1); GameTooltip:Show()
    end)
    U.nowButton:HookScript("OnLeave", function() GameTooltip:Hide() end)
    U.connection = at(U.FitText(U.Text(f, "", 14, C.paperMuted), 890, 18, false), 38, -626)
    U.status = at(U.FitText(U.Text(f, "", 14, C.ink), 890, 18, false), 38, -603)
    if E.startupProblem then
        U.status:SetText(E.startupProblem)
        for _, button in pairs(U.tabs) do button:Disable() end
        U.settingsButton:Disable(); U.allEvents:Hide(); U.nowButton:Hide(); U.action:Hide()
        f:Hide(); return
    end
    U.CreateHome()
    U.CreateReader()
    U.CreatePlanButtons()
    U.CreateWriter()
    U.CreateSettings()
    U.CreateSupplies()
    U.CreateRoster()
    U.CreateCrafting()
    f:SetScript("OnShow", function()
        if InCombatLockdown and InCombatLockdown() then f:Hide(); return end
        U.UpdateServerClock()
        U.clockTimer = C_Timer.NewTicker(5, U.UpdateServerClock) -- a ticker, not a per-frame script
        U.timer = C_Timer.NewTicker(30, function()
            U.UpdateConnection()
            if U.reader:IsShown() then U.RefreshReader()
            elseif U.tab == "Home" then U.RefreshHome()
            elseif U.tab == "Write" then U.WriterLabels() end
        end)
    end)
    f:SetScript("OnHide", function()
        if U.timer then U.timer:Cancel(); U.timer = nil end
        if U.clockTimer then U.clockTimer:Cancel(); U.clockTimer = nil end
        U.Status()
        if U.confirmSheet then U.confirmSheet:Hide() end
    end)
    f:Hide()
end

-- Hours and minutes on the realm's clock, kept current while the window is open.
function U.UpdateServerClock()
    if U.serverClockTime then U.serverClockTime:SetText(E.Client.Clock(E.Client.Now())) end
end

function U.Refresh()
    if not S.db then return end
    local unread = { Noticeboard = 0, Letters = 0 }
    for _, e in ipairs(notices()) do
        if not e.read and not e.own and not e.cancelled then unread[board(e.categoryIndex)] = unread[board(e.categoryIndex)] + 1 end
    end
    local showRoster = U.RosterAllowed()
    if U.tab == "Roster" and not showRoster then U.tab = "Home" end
    U.tabs.Roster:SetShown(showRoster)
    local inSchedule = U.tab == "Schedule" or U.tab == "Letters" or U.tab == "Noticeboard" or U.tab == "Mine"
    local browsing = inSchedule and not U.expanded and not U.homeView
    U.allEvents:SetShown(browsing)
    U.SelectButton(U.allEvents, U.tab == "Schedule")
    for _, key in ipairs({"Letters", "Noticeboard", "Mine"}) do U.tabs[key]:SetShown(browsing) end
    unread.Crafting = E.Professions.WaitingForMe()
    for tab, button in pairs(U.tabs) do
        local selected = tab == U.tab or (U.tab == "Write" and tab == U.returnTab)
        if tab == "Schedule" then selected = inSchedule and not U.fromHome or U.tab == "Write" end
        if tab == "Home" and U.fromHome then selected = true end
        U.SelectButton(button, selected)
        local count = unread[tab] or 0
        button.badge:SetText(count > 9 and "9+" or count > 0 and tostring(count) or "")
        if button.variant == "flat" then
            button.badge:SetTextColor(unpack(selected and C.goldHi or C.text))
            button.label:ClearAllPoints(); button.label:SetPoint("CENTER", count > 0 and -13 or 0, 0)
        end
        button.badgeSeal:SetShown(count > 0 and tab ~= "Crafting")
    end
    U.SelectButton(U.settingsButton, U.tab == "Settings")
    local home = U.tab == "Home"
    local darkPage = home or U.tab == "Write" or U.tab == "Crafting" or U.tab == "Settings" or U.tab == "Roster"
    local scene = inSchedule and not U.expanded and "Chart" or U.tab == "Crafting" and "Workshop"
        or U.tab == "Roster" and "Dispatch" or U.tab == "Settings" and "Handbook"
    U.masthead:SetShown(scene ~= nil and scene ~= false)
    if scene then U.masthead:SetTexture(media .. scene .. "Header.tga") end
    U.parchment:SetShown(not darkPage)
    U.pageTitle:SetShown(not (inSchedule and U.expanded))
    U.pageTitle:SetTextColor(unpack((darkPage or scene) and C.ivory or C.ink))
    U.status:SetTextColor(unpack(darkPage and C.ivory or C.ink))
    U.connection:SetTextColor(unpack(darkPage and C.muted or C.paperMuted))
    U.UpdateLauncherBadge()
    U.UpdateServerClock()

    local writing = U.tab == "Write"
    local official = (writing and U.composeBoard or U.tab) == "Noticeboard"
    U.pageTitle:SetText(U.homeView == "changed" and "Changes to your plans" or U.homeView == "joining" and "You are joining" or U.homeView == "unread" and "Unread notices"
        or writing and (U.editing and "Edit" or official and "New Guild Gathering" or "New Adventure") or U.labels[U.tab] or "")
    U.action:ClearAllPoints()
    local actionX = writing and 38 or U.tab == "Roster" and 566 or browsing and 548 or 751
    -- The action button belongs to the window, the Officer desk's view buttons to its page (which hangs
    -- 16 below the window's top), so the button needs 16 more to share their centre line.
    at(U.action, actionX, U.tab == "Roster" and -115 or browsing and -121 or -68)
    U.action:SetWidth(writing and 148 or 170)
    U.pageTitle:ClearAllPoints(); at(U.pageTitle, writing and 208 or 38, -69)
    U.action.label:SetText(U.homeView and "Back to Home" or writing and ("‹ " .. (U.labels[U.returnTab] or U.labels.Home)) or U.tab == "Roster" and "Announcement" or official and "New Guild Gathering" or "New Adventure")
    U.SetVariant(U.action, writing and "brass" or U.homeView and "ink" or "seal")
    -- On the roster check, the officers' announcement (UI/Grand.lua).
    U.action:SetShown(not (inSchedule and U.expanded) and (U.homeView ~= nil or writing or U.tab == "Schedule" or U.tab == "Letters" or U.tab == "Mine" or (U.tab == "Noticeboard" and officer()) or (U.tab == "Roster" and U.RosterAllowed())))
    U.nowButton:SetShown(home or U.tab == "Letters" and browsing)
    U.nowButton:ClearAllPoints(); at(U.nowButton, home and 38 or 728, home and -568 or -121)
    U.nowButton:SetWidth(home and 215 or 120)
    U.nowButton.label:SetText(home and "Start an adventure now" or "Quick post")
    U.SetVariant(U.nowButton, home and "brass" or "ink")
    U.home:SetShown(U.tab == "Home")
    U.reader:SetShown(inSchedule)
    U.writer:SetShown(writing)
    U.settings:SetShown(U.tab == "Settings")
    U.supplies:Hide()
    U.rosterPage:SetShown(U.tab == "Roster")
    U.craftPage:SetShown(U.tab == "Crafting")
    if U.craftPage:IsShown() then U.RefreshCrafting() end
    if U.rosterPage:IsShown() then U.RefreshRoster() end
    if U.home:IsShown() then U.RefreshHome() end
    if U.reader:IsShown() then U.RefreshReader() end
    if U.writer:IsShown() then U.LoadDraft() end
    if U.settings:IsShown() then U.RefreshSettings() end
    U.UpdateConnection()
end

function U.UpdateConnection()
    if not U.connection then return end
    local message = ""
    if not S.db.settings.guildSync then message = "Messages are paused.\nSaved notices remain readable.\nSee Troubleshooting in Settings."
    elseif E.Client.CommsBlocked() then message = "Sharing paused by WoW.\nSaved notices remain readable."
    elseif not E.Sync.Ready() then message = E.Sync.Status()
    elseif E.Sync.lastError then message = E.Sync.lastError .. ". See Troubleshooting in Settings." end
    U.connection:SetText((message:gsub("\n", " ")))
    U.connection:SetShown(message ~= "")
end
function U.RefreshAvailability()
    U.UpdateConnection()
    if U.reader:IsShown() then U.RefreshReader()
    elseif U.home:IsShown() then U.RefreshHome()
    elseif U.settings:IsShown() then U.RefreshSettings() end
end

-- The board is a short agenda. Only the six visible lines need frames.
function U.CreateHome()
    local page = newPage(); U.home = page
    local card = at(U.Panel(page, 886, 178, {.045,.059,.085,.70}), 36, -96); U.homeCard = card
    card:SetBackdropBorderColor(unpack(C.gold))
    U.homeStage = U.Surface(card, "StoryStage.tga")
    U.homeGathering = U.Surface(card, "GuildGathering.tga")
    U.homeArt = at(drawing(card, "BoardLantern.tga", 174, 174), 700, -2)
    U.homeArt:SetVertexColor(1,1,1)
    U.homeHead = at(U.Text(card, "", 16, C.goldHi), 30, -13)
    U.homeTitle = at(U.FitText(U.Text(card, "", 25, C.ivory), 652, 54, true), 30, -37)
    U.homeWhen = at(U.FitText(U.Text(card, "", 15, C.text), 668, 18, false), 30, -93)
    U.homeWhere = at(U.FitText(U.Text(card, "", 15, C.text), 668, 19, false), 30, -115)
    U.homeJoin = at(U.Button(card, "I will join", 135, function()
        U.AnswerPlan(U.nextEvent, "I will join")
    end, "brass"), 30, -137)
    U.homeOpen = U.Button(card, "Read invitation", 156, function()
        if U.nextEvent then U.OpenEntry(U.nextEvent) end
    end, "brass")
    at(U.Text(page, "Coming up", 21, C.ivory), 38, -293)
    U.changedPlans = at(U.Button(page, "Changes", 130, function() U.OpenHomeView("changed") end, "header"), 546, -284)
    U.joiningAll = at(U.Button(page, "Joining", 92, function() U.OpenHomeView("joining") end, "header"), 697, -284)
    U.freshAll = at(U.Button(page, "Unread", 96, function() U.OpenHomeView("unread") end, "header"), 815, -284)
    U.homeColumns = {}
    for _, col in ipairs({{"Server time", 44},{"Activity", 232},{"Type", 730}}) do
        U.homeColumns[#U.homeColumns+1] = at(U.Text(page, col[1], 14, C.goldHi), col[2], -325)
    end
    U.homeColumns[#U.homeColumns+1] = U.Rule(page, 38, -348, 882, C.gold)
    U.upcomingRows = {}
    for i = 1, 6 do
        local row = at(U.Button(page, "", 882, function(self)
            if self.entry then U.OpenEntry(self.entry) end
        end, "row"), 38, -350 - (i-1)*30)
        row:SetHeight(30); row.label:Hide()
        row.clock = at(U.FitText(U.Text(row, "", 15, C.text), 182, 22, false), 6, -5)
        row.title = at(U.FitText(U.Text(row, "", 16, C.ivory), 467, 22, false), 194, -5)
        row.kind = at(U.FitText(U.Text(row, "", 14, C.goldHi), 169, 22, false), 692, -6)
        row.dot = unreadMark(row)
        U.upcomingRows[i] = row
    end
    U.upcomingEmpty = at(U.Text(page, "", 15, C.muted), 44, -331)
    U.viewSchedule = at(U.Button(page, "View schedule", 156, function() U.Go("Schedule") end, "brass"), 766, -552)
end

function U.OpenHomeView(view)
    U.GoNow("Schedule"); U.homeView = view; U.filterWhen = view == "changed" and "all" or view; U.Refresh()
end

local function earlier(a, b)
    if a.start ~= b.start then return a.start < b.start end
    if (a.categoryIndex == 4) ~= (b.categoryIndex == 4) then return a.categoryIndex == 4 end
    return a.id < b.id
end

function U.RefreshHome()
    local now = E.Client.Now()
    local active, joining, unread, changed = {}, 0, 0, 0
    for _, e in ipairs(notices()) do
        if U.PlanChanges(e) then changed = changed + 1 end
        if not e.cancelled and e.expires > now then
            active[#active+1] = e
            if e.own or e.reply == "I will join" then joining = joining + 1
            elseif not e.read then unread = unread + 1 end
        end
    end
    table.sort(active, function(a, b)
        if (a.categoryIndex == 4) ~= (b.categoryIndex == 4) then return a.categoryIndex == 4 end
        return earlier(a, b)
    end)
    local featured = active[1]
    U.nextEvent = featured
    local official = featured and featured.categoryIndex == 4
    local story = official and E.Kind(featured) == E.storyLabel
    U.homeStage:SetShown(story)
    U.homeGathering:SetShown(official and not story)
    U.homeArt:SetShown(not official)
    U.homeTitle:SetTextColor(unpack(story and STORY_GOLD or C.ivory))
    local look = featured and kindColors(featured)
    U.homeCard:SetBackdropColor(unpack(look and look.back or {.045,.059,.085,.70}))
    U.homeCard:SetBackdropBorderColor(unpack(look and look.edge or C.gold))
    U.homeHead:SetTextColor(unpack(look and look.text or C.goldHi))
    local canJoin = featured and not featured.own and featured.reply ~= "I will join"
    U.homeJoin:SetShown(canJoin); U.homeJoin:SetEnabled(E.Sync.Ready() or false)
    U.homeOpen:SetShown(featured ~= nil); U.homeOpen:ClearAllPoints(); at(U.homeOpen, canJoin and 175 or 30, -137)
    if featured then
        U.homeHead:SetText((official and "Official guild event" or "Member activity") .. "  /  " .. E.Kind(featured))
        U.homeTitle:SetText(clean(featured.title, 100))
        U.homeWhen:SetText((happening(featured) and "Started " or "") .. when(featured.start))
        local place = clean(featured.location, 100)
        local response = featured.own and "You're hosting" or featured.reply == "I will join" and "You're going" or featured.reply
        U.homeWhere:SetText((place ~= "" and place or "Place not told") .. (response and ("   /   " .. response) or ""))
    else
        U.homeHead:SetText("Guild activity")
        U.homeTitle:SetText(context() and "Nothing on the board yet." or "Sharing is not connected")
        U.homeWhen:SetText(context() and "Start an adventure now or plan one in Schedule." or E.Sync.Status())
        U.homeWhere:SetText("")
    end
    local shown = 0
    for _, entry in ipairs(active) do
        if entry ~= featured and shown < #U.upcomingRows then
            shown = shown + 1
            local row = U.upcomingRows[shown]
            row.entry = entry
            row.clock:SetText(dayName(entry.start, entry) .. "  " .. E.Client.Clock(entry.start))
            row.title:SetText(clean(entry.title, 100)); row.kind:SetText(E.Kind(entry)); row.kind:SetTextColor(unpack(kindColors(entry).text))
            row.dot:SetShown(not entry.read and not entry.own)
            row:Show()
        end
    end
    for i = shown + 1, #U.upcomingRows do U.upcomingRows[i].entry = nil; U.upcomingRows[i]:Hide() end
    for _, column in ipairs(U.homeColumns) do column:SetShown(shown > 0) end
    U.upcomingEmpty:SetText(shown == 0 and (featured and "This is the only active invitation." or "No upcoming invitations.") or "")
    U.changedPlans:SetShown(changed > 0); U.changedPlans.label:SetText("Changes (" .. changed .. ")")
    U.joiningAll:SetShown(joining > 0); U.freshAll:SetShown(unread > 0)

end

-- The schedule and full-page invitation share a page so returning keeps the active filters.
function U.CreateReader()
    local page = newPage(); U.reader = page
    U.emptyArt = drawing(page, "Empty.tga", 240, 120); U.emptyArt:SetPoint("TOPLEFT", 360, -166)
    U.empty = at(U.FitText(U.Text(page, "", 19, C.paperMuted, nil, "game"), 654, 26, false), 153, -305)
    U.empty:SetJustifyH("CENTER")
    U.emptyHint = at(U.FitText(U.Text(page, "", 15, C.paperMuted), 654, 20, false), 153, -340)
    U.emptyHint:SetJustifyH("CENTER")
    local body = CreateFrame("Frame", nil, page)
    body:SetAllPoints(page); U.boardBody = body
    U.scheduleBand = U.Inlay(body, 8, -144, 944, 80, {.12,.19,.22,1})
    U.filterWhen = "all"
    U.whenChips = {}
    -- Date/answer filters on every board. Adventures have one kind since 0.9.3, so no kind filter.
    local x = 244
    for _, chip in ipairs({ { "all", "Any date", 96 }, { "today", "Today", 70 }, { "week", "This week", 96 }, { "joining", "Joining", 80 }, { "unread", "Unread", 80 } }) do
        local button = at(U.Button(body, chip[2], chip[3], function()
            if U.browseCalendar then U.browseCalendar:Hide() end
            U.filterWhen = chip[1]; U.dateFilter = nil; U.selected = nil
            U.list:SetVerticalScroll(0); U.RefreshReader()
        end, "flat"), x, -102)
        button:SetHeight(26); button.key = chip[1]
        U.whenChips[#U.whenChips + 1] = button
        x = x + chip[3] + 4
    end
    U.browseDate = at(U.Button(body, "Calendar", 208, function()
        if not U.browseCalendar then
            U.browseCalendar = U.MonthCalendar(page, 504, -136, function(day)
                U.dateFilter = E.Client.DayStart() + day*86400
                U.filterWhen = "all"; U.selected = nil; U.list:SetVerticalScroll(0); U.RefreshReader()
            end)
            at(U.Text(U.browseCalendar, "*  Scheduled activity", 14, C.brown), 18, -327)
        end
        local cal = U.browseCalendar
        if cal:IsShown() then cal:Hide(); return end
        local today = E.Client.DayStart()
        cal:Open(U.dateFilter and math.floor((U.dateFilter-today)/86400) or 0, E.officialDays)
        U.RefreshReader()
    end), 706, -147)
    U.search = U.Field(body, "", 244, -138, 584, 28, 100)
    U.search.caption:Hide()
    U.searchHint = at(U.FitText(U.Text(U.search:GetParent(), "Search subject, meeting place or organiser", 14, C.paperMuted), 554, 20, false), 10, -6)
    U.search:SetScript("OnTextChanged", function(self)
        U.searchHint:SetShown(self:GetText() == "")
        if U.list then U.list:SetVerticalScroll(0); U.RefreshReader() end
    end)
    U.search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    U.searchClear = at(U.Button(body, "Clear", 60, function()
        U.filterWhen = "all"; U.dateFilter = nil; U.selected = nil
        if U.browseCalendar then U.browseCalendar:Hide() end
        U.search:SetText(""); U.search:ClearFocus(); U.list:SetVerticalScroll(0); U.RefreshReader()
    end, "ink"), 838, -158)
    U.searchClear:SetHeight(28)
    local list = U.Scroll(body, 884, 398)
    list:SetPoint("TOPLEFT", 244, -192)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(858, 398); list:SetScrollChild(child)
    U.list, U.listChild, U.rows, U.heads = list, child, {}, {}
    U.listEmpty = at(U.FitText(U.Text(child, "", 14, C.paperMuted), 276, 40, true), 4, -8)

    local paper = CreateFrame("Frame", nil, body)
    paper:SetSize(332, 380); paper:SetPoint("TOPLEFT", 566, -192); U.paper = paper
    U.readerArt = at(drawing(paper, "InvitationInk.tga", 290, 145), 586, -38)
    U.readerArt:SetVertexColor(1,1,1)
    U.readerRibbon = paper:CreateTexture(nil, "BACKGROUND")
    U.readerRibbon:SetTexture(media .. "StoryStage.tga")
    U.readerRibbon:SetSize(884, 154); at(U.readerRibbon, 0, -31)
    U.readerKind = at(U.FitText(U.Text(paper, "", 14, C.brown, nil, "caps"), 270, 16, false), 62, -2)
    U.readerTitle = at(U.FitText(U.Text(paper, "", 21, C.ink, nil, "game"), 270, 42, true), 62, -18)
    U.readerHost = at(U.FitText(U.Text(paper, "", 15, C.paperMuted), 520, 39, true), 58, -139)
    U.readerMeta = at(U.FitText(U.Text(paper, "", 14, C.paperMuted), 850, 55, true), 12, -191)
    U.expand = at(U.Button(paper, "Back to schedule", 184, function()
        if U.fromHome then U.Go("Home"); return end
        U.expanded = false; U.Refresh()
    end, "ink"), 0, -112)
    U.expand:SetHeight(24)
    U.readerBody = U.ScrollText(paper, 332, 130, C.ink)
    U.readerBody:SetPoint("TOPLEFT", 0, -138)
    -- Who is joining: a heading with the counts, then the names.
    U.whoHead = at(U.FitText(U.Text(paper, "", 14, C.brown, nil, "caps"), 222, 18, false), 0, -278)
    U.answersButton = at(U.Button(paper, "See all", 102, function() U.OpenAnswers() end, "bare"), 230, -274)
    U.answersButton:SetHeight(26)
    -- A short line to go with an answer: "as the caravan guard".
    U.lineSheet = sheet(U.frame, 520, 180, 322, -220)
    U.lineField = U.Field(U.lineSheet, "Add a line to your answer (optional)", 24, -24, 472, 32, 80)
    U.saveReply = at(U.Button(U.lineSheet, "Save joining reply", 196, function()
        U.AnswerPlan(U.selected, "I will join", U.lineField:GetText())
    end, "seal"), 24, -112)
    at(U.Button(U.lineSheet, "Cancel", 120, function()
        U.lineField:SetText(U.selected and E.Sync.MyLine(U.selected) or ""); U.lineSheet:Hide()
    end), 234, -112)
    U.lineButton = at(U.Button(paper, "Add a line", 120, function() U.lineSheet:Show(); U.lineField:SetFocus() end, "bare"), 0, -300)
    U.lineButton:SetHeight(26)
    U.readerState = at(U.FitText(U.Text(paper, "", 14, C.paperMuted), 194, 40, true), 138, -302)
    U.join = at(U.Button(paper, "I will join", 130, function()
        U.AnswerPlan(U.selected, "I will join", U.lineField:GetText())
    end, "seal"), 0, -344)
    U.decline = at(U.Button(paper, "Unable", 110, function()
        U.AnswerPlan(U.selected, "Unable to attend")
    end), 138, -344)
    U.edit = at(U.Button(paper, "Edit", 96, function()
        if U.selected then U.StartEdit(U.selected) end
    end), 0, -344)
    U.again = at(U.Button(paper, "Post again", 116, function()
        if U.selected then U.PostAgain(U.selected) end
    end), 216, -344)
    U.withdraw = at(U.Button(paper, "Withdraw", 110, function()
        if not U.selected then return end
        local entry = U.selected
        U.Confirm("Withdraw \"" .. clean(entry.title, 100) .. "\"? It leaves the board for everyone and cannot be brought back.", "Withdraw", function()
            if S.Cancel(entry) then U.ShowEntry(entry); U.Refresh(); U.Status("Withdrawal queued.") else U.Status("Could not withdraw this notice. Check your connection and permissions.") end
        end)
    end), 102, -344)
    U.moderate = at(U.Button(paper, "Remove", 76, function()
        if not U.selected then return end
        local entry = U.selected
        U.Confirm("Remove \"" .. clean(entry.title, 100) .. "\" from the board? Everyone sees it as removed by an officer, and it cannot be brought back.", "Remove", function()
            if E.Sync.Moderate(entry) then U.ShowEntry(entry); U.Refresh(); U.Status("Notice removed.") else U.Status("Could not remove this notice. Check your officer rank and connection.") end
        end)
    end), 256, -344)
    -- Space for the illustration is reserved even with a long title or local-time suffix.
    local function place(widget, x, y, width, height)
        widget:ClearAllPoints(); at(widget, x, y); widget:SetSize(width, height)
    end
    place(U.paper, 38, -48, 884, 524)
    place(U.expand, 0, 0, 166, 26)
    place(U.readerKind, 58, -57, 490, 18)
    place(U.readerTitle, 58, -80, 505, 58)
    U.readerTitle:SetFont(STANDARD_TEXT_FONT, 24, "")
    U.Rule(paper, 0, -249, 884)
    place(U.readerBody, 12, -261, 842, 140)
    U.readerBody:Reflow()
    U.Rule(paper, 0, -410, 884)
    place(U.whoHead, 12, -431, 240, 22)
    place(U.readerState, 268, -430, 600, 36)
    place(U.join, 12, -476, 140, 32)
    place(U.decline, 162, -476, 154, 32)
    U.decline.label:SetText("Unable to attend")
    place(U.lineButton, 326, -476, 130, 32)
    place(U.edit, 12, -476, 100, 32)
    place(U.again, 124, -476, 124, 32)
    place(U.withdraw, 268, -476, 112, 32)
    place(U.moderate, 480, -476, 104, 32)
    place(U.answersButton, 676, -476, 196, 32)
    U.answersButton.label:SetText("Who's coming?")
    place(U.list, 38, -236, 858, 338)
    for i, chip in ipairs(U.whenChips) do
        chip:ClearAllPoints(); at(chip, 38 + (i-1)*104, -150)
    end
    place(U.search:GetParent(), 38, -188, 790, 30)
    place(U.searchClear, 838, -188, 78, 30)

end

function U.LayoutReader()
    local full = U.expanded == true
    U.list:SetShown(not full); U.paper:SetShown(full); U.scheduleBand:SetShown(not full)
    for _, chip in ipairs(U.whenChips) do chip:SetShown(not full); U.SelectButton(chip, chip.key == U.filterWhen and not U.dateFilter) end
    local holder = U.search:GetParent()
    holder:SetShown(not full); U.searchClear:SetShown(not full)
    U.searchHint:SetShown(not full and U.search:GetText() == "")
    U.browseDate:SetShown(not full and not U.homeView)
    U.browseDate.label:SetText(U.dateFilter and E.Client.Date(U.dateFilter + 43200) or "Calendar")
    if full and U.browseCalendar then U.browseCalendar:Hide() end
    U.SelectButton(U.browseDate, U.dateFilter ~= nil)
    U.expand.label:SetText(U.fromHome and "‹ Guild board" or "‹ Back to list")
end

function U.OpenAnswers()
    if not U.selected then return end
    if not U.answersSheet then
        local s = sheet(U.frame, 604, 456, 272, -114); U.answersSheet = s
        at(U.Text(s, "Answers", 22, C.ink), 24, -20)
        at(U.Button(s, "Close", 90, function() s:Hide() end), 490, -16)
        U.answersBody = U.ScrollText(s, 556, 352, C.ink); at(U.answersBody, 24, -70)
    end
    local joining, unable = answers(U.selected)
    local text = "Joining (" .. #joining .. ")\n" .. (#joining > 0 and table.concat(joining, "\n") or "No answers yet.")
        .. "\n\nUnable to attend (" .. #unable .. ")\n" .. (#unable > 0 and table.concat(unable, "\n") or "None.")
    U.answersBody:SetContent(text); U.answersSheet:Show()
end

function U.RefreshReader()
    for _, row in ipairs(U.rows) do row:Hide() end
    for _, head in ipairs(U.heads) do head:Hide() end
    local events, mine = U.tab == "Noticeboard", U.tab == "Mine"
    local wasReading = U.expanded
    local all, entries = 0, {}
    local now, today = E.Client.Now(), E.Client.DayStart()
    local calendar = U.browseCalendar
    local markedDays = calendar and calendar:IsShown() and {} or nil
    local query = E.Trim(clean(U.search:GetText(), 100)):lower()
    for _, e in ipairs(notices()) do
        if U.tab == "Schedule" or U.homeView or mine and e.own or not mine and board(e.categoryIndex) == U.tab then
            all = all + 1
            if markedDays and not e.cancelled and e.expires > now then
                local day = math.floor((e.start - today) / 86400)
                markedDays[day] = (markedDays[day] or 0) + 1
            end
            local joined = e.own or e.reply == "I will join"
            local keep = (not U.homeView or U.homeView == "changed" and (U.PlanChanges(e) or U.expanded and e == U.selected) or not e.cancelled and e.expires > now and (U.homeView == "joining" and joined
                or U.homeView == "unread" and not joined and (not e.read or e == U.selected)))
                and (U.filterWhen == "all"
                or U.filterWhen == "today" and e.start < today + 86400
                or U.filterWhen == "week" and e.start < today + 7 * 86400
                or U.filterWhen == "joining" and joined
                or U.filterWhen == "unread" and (not e.read or e == U.selected) and not e.own and not e.cancelled)
            local searchable = (clean(e.title, 100) .. " " .. clean(e.location, 100) .. " " .. U.Author(e.author, 120)):lower()
            keep = keep and (not U.dateFilter or not e.cancelled and e.expires > now and e.start >= U.dateFilter and e.start < U.dateFilter + 86400)
                and (query == "" or searchable:find(query, 1, true) ~= nil)
            if keep then entries[#entries + 1] = e end
        end
    end
    if markedDays then calendar.counts = markedDays; calendar:Paint() end
    -- Soonest first: a board is read as "what is coming up".
    table.sort(entries, earlier)
    U.boardBody:SetShown(all > 0 or U.tab == "Schedule")
    U.emptyArt:SetShown(all == 0 and U.tab ~= "Schedule")
    U.empty:SetText(all == 0 and U.tab ~= "Schedule" and (events and "No guild events are planned." or mine and "You have nothing on the boards." or "No Adventures posted yet.") or "")
    U.emptyHint:SetText((all > 0 or U.tab == "Schedule") and "" or not context() and "Sharing is not connected. See Settings."
        or events and (officer() and "Post one with New Guild Gathering." or "Officers post them here.") or mine and "Post one with New Adventure." or "Post the first with New Adventure.")
    U.LayoutReader()
    local height = U.list:GetHeight()
    U.listEmpty:SetText(all == 0 and U.tab == "Schedule" and "Nothing is scheduled." or #entries == 0 and "No matching activities. Clear your filters to see more." or "")
    local found, y, lastDay, heads = false, 0, nil, 0
    for i, entry in ipairs(entries) do
        local day = dayName(entry.start, entry)
        if day ~= lastDay then
            heads = heads + 1
            local head = U.heads[heads]
            if not head then head = U.FitText(U.Text(U.listChild, "", 14, C.brown, nil, "caps"), 276, 16, false); U.heads[heads] = head end
            head:SetPoint("TOPLEFT", 4, -y - 6); head:SetText(day == "Happening now" and day or (day .. "  /  server time")); head:Show()
            y = y + 26; lastDay = day
        end
        local row = U.rows[i]
        if not row then
            row = ledgerRow(U.listChild, 854, function(self)
                U.selected = self.entry
                U.expanded = true
                self.entry.read = true
                U.Refresh()
            end)
            U.rows[i] = row
        end
        row:SetPoint("TOPLEFT", 0, -y)
        y = y + 52
        local note = entry.cancelled and (entry.moderated and "Removed by an officer" or "Withdrawn")
            or entry.expires <= now and "Ended"
            or E.Sync.Pending(entry) and "Sending..."
            or entry.reply and ("You: " .. entry.reply)
            or mine and E.Kind(entry)
            or U.Author(entry.author, 55)
        -- A Story Event is always named as one in the list (0.9.3).
        if (U.tab == "Schedule" or E.Kind(entry) == E.storyLabel) and note ~= E.Kind(entry) then
            note = E.Kind(entry) .. " / " .. note
        end
        fillRow(row, entry, note)
        row:Show()
        U.SelectButton(row, U.selected == entry)
        if U.selected == entry then found = true end
    end
    U.listChild:SetHeight(math.max(height, y))
    U.UpdateScroll(U.list)
    if not found then U.selected = nil; U.expanded = false; U.LayoutReader() end
    if wasReading and not U.expanded then
        U.fromHome = nil; U.Refresh(); return
    end
    U.ShowEntry(U.selected)
    if U.answersSheet and U.answersSheet:IsShown() then
        if U.selected then U.OpenAnswers() else U.answersSheet:Hide() end
    end
end

function U.ShowEntry(entry)
    U.join:Hide(); U.decline:Hide(); U.withdraw:Hide(); U.edit:Hide(); U.moderate:Hide(); U.again:Hide()
    local changes = U.ShowPlanButtons(entry)
    if U.sceneSheet and U.sceneSheet.entry ~= entry then U.sceneSheet:Hide() end
    U.readerArt:SetShown(entry ~= nil and E.Kind(entry) ~= E.storyLabel)
    U.expand:SetShown(entry ~= nil); U.answersButton:SetShown(entry ~= nil)
    U.lineButton:Hide()
    local story = entry ~= nil and entry.story == true and entry.categoryIndex == 4
    U.readerRibbon:SetShown(story)
    U.readerKind:SetTextColor(unpack(story and STORY_GOLD or C.brown))
    U.readerTitle:SetTextColor(unpack(story and STORY_GOLD or C.ink))
    U.readerHost:SetTextColor(unpack(story and C.ivory or C.paperMuted))
    if not entry then
        U.readerKind:SetText("")
        U.readerHost:SetText("")
        U.readerTitle:SetText(U.labels[U.tab] or "")
        U.readerMeta:SetText(U.tab == "Noticeboard" and "Select an event to read." or U.tab == "Mine" and "Select one to read, change or withdraw." or "Select an Adventure to read.")
        U.readerBody:SetContent("")
        U.readerState:SetText("")
        U.whoHead:SetText("")
        U.lineField:GetParent():Hide(); U.lineField.caption:Hide()
        U.lineSheet:Hide()
        return
    end
    U.readerKind:SetText(E.Kind(entry))
    U.readerTitle:SetText(clean(entry.title, 100))
    local host = U.Author(entry.author, 70)
    U.readerHost:SetText(host ~= "" and ("Hosted by " .. host) or "")
    local details = {}
    if entry.start and entry.start > 0 then
        details[#details + 1] = when(entry.start) .. "  /  " .. U.Until(entry.start)
    end
    local place = clean(entry.location, 100)
    if place == "" and entry.categoryIndex ~= 4 then place = "Place not told" end
    if place ~= "" then details[#details + 1] = place end
    U.readerMeta:SetText(table.concat(details, "\n"))
    U.readerBody:SetContent((changes and (changes .. "\n\n") or "") .. clean(entry.body, 1600))
    local joining, unable = answers(entry)
    U.answersButton.label:SetText("Who's coming? (" .. #joining .. ")")
    U.whoHead:SetText(#joining == 0 and #unable == 0 and "No answers yet"
        or "Joining " .. #joining .. (#unable > 0 and (" / " .. #unable .. " unable") or ""))
    U.readerState:SetText(state(entry))
    local open = not entry.cancelled and entry.expires > E.Client.Now()
    local canAnswer = open and not entry.own
    U.lineField:GetParent():SetShown(canAnswer); U.lineField.caption:SetShown(canAnswer)
    U.lineButton:SetShown(canAnswer)
    if not canAnswer then U.lineSheet:Hide() end
    if canAnswer then
        local mine = entry.live and E.Sync.MyLine and E.Sync.MyLine(entry) or ""
        if U.lineEntry ~= entry then U.lineEntry = entry; U.lineField:SetText(mine or ""); U.lineField:ClearFocus(); U.lineSheet:Hide() end
        U.lineButton.label:SetText(U.lineField:GetText() ~= "" and "Edit your line" or "Add a line")
    end
    U.join:SetShown(open and not entry.own)
    U.decline:SetShown(open and not entry.own)
    U.withdraw:SetShown(open and entry.own)
    U.edit:SetShown(open and entry.own)
    U.again:SetShown(entry.own == true and not story)
    U.moderate:SetShown(open and not entry.own and officer())
    local ready = E.Sync.Ready() or false
    for _, button in ipairs({ U.join, U.decline, U.withdraw, U.edit, U.again, U.moderate, U.lineButton }) do button:SetEnabled(ready) end
    U.SelectButton(U.join, entry.reply == "I will join"); U.SelectButton(U.decline, entry.reply == "Unable to attend")
    U.join.label:SetText(entry.reply == "I will join" and "You're going" or "I will join")
    U.SetVariant(U.join, entry.reply == "I will join" and "ink" or "seal")
end

-- Writing: what it is (one line saying so), when it starts by the realm's clock, how long it stays
-- on the board, then the words. The day and the time are chosen from a small sheet; Post is the
-- only step. Since 0.9.3 there is nothing to pick: the board decides (an Adventure, or an officer's
-- Guild Gathering).
local function updateWriterHint()
    local d = U.draft
    if U.editing then
        U.writerHint:SetText(editChanged() and "Unsaved changes" or "")
    else
        local hasWords = (d.title or "") ~= "" or (d.body or "") ~= "" or (d.location or "") ~= ""
        U.writerHint:SetText(hasWords and "Draft saved" or "")
    end
end

function U.CreateWriter()
    local page = newPage(); U.writer = page
    U.draft = {}
    local function set(key, value)
        if U.editing then return end
        U.draft[key] = value; U.SaveDraft(); U.WriterLabels()
    end
    U.kindNote = at(U.FitText(U.Text(page, "", 14, C.muted), 880, 34, true), 38, -89)
    U.timeSummary = at(U.FitText(U.Text(page, "", 17, C.ivory), 640, 24, false), 38, -437)
    U.startPreview = at(U.FitText(U.Text(page, "", 14, C.muted), 878, 36, true), 38, -475)
    U.scheduleOptions = sheet(page, 630, 190, 170, -228)
    U.scheduleOptions:SetClipsChildren(false)
    local options = U.scheduleOptions
    at(U.Text(options, "Starts (server time)", 16, C.ink), 18, -14)
    U.dayButton = at(U.Button(options, "", 202, function()
        U.clock:Hide()
        if U.calendar:IsShown() then U.calendar:Hide()
        else U.calendar:Open(U.draft.startDays or 0, E.AheadDays(U.draft.category)) end
    end), 18, -41)
    U.timeButton = at(U.Button(options, "", 104, function()
        U.calendar:Hide(); U.clock:SetShown(not U.clock:IsShown())
    end), 228, -41)
    U.serverNow = at(U.FitText(U.Text(options, "", 14, C.paperMuted), 250, 38, true), 352, -42)
    at(U.Text(options, "Keep on the board after it starts", 14, C.paperMuted), 18, -86)
    U.lastButtons = {}
    for i, stay in ipairs(U.stays) do
        local button = at(U.Button(options, stay[2], 80, function() set("hours", stay[1]) end, "flat"), 18+(i-1)*85, -109)
        button.hours = stay[1]; U.lastButtons[i] = button
    end
    at(U.Button(options, "Done", 90, function()
        options:Hide(); U.clock:Hide(); U.calendar:Hide()
    end), 520, -149)
    U.changeTime = at(U.Button(page, "Change schedule", 180, function()
        local open = not options:IsShown()
        U.clock:Hide(); U.calendar:Hide(); options:SetShown(open)
    end, "brass"), 740, -432)
    U.fields = {}
    U.fields.title = U.Field(page, "Title", 38, -125, 882, 35, 100)
    U.pinHere = at(U.Button(page, "Use my location", 152, function() U.UseLocation(U.fields.location) end, "brass"), 636, -357)
    U.pinHere:SetHeight(22)
    U.fields.location = U.Field(page, "Meeting place", 38, -360, 882, 34, 100)
    U.secretToggle = at(U.Button(page, "Keep it secret", 124, function()
        if U.editing then return end
        U.draft.secret = not U.draft.secret
        if U.draft.secret then U.draft.location = "" end
        U.SaveDraft(); U.LoadDraft()
    end, "flat"), 796, -357)
    U.secretToggle:SetHeight(20)
    U.fields.body = U.Field(page, "Invitation", 38, -193, 882, 132, 1600, true)
    U.bodyCount = at(U.FitText(U.Text(page, "", 14, C.muted), 210, 18, false), 710, -193)
    U.bodyCount:SetJustifyH("RIGHT")
    U.fields.body:SetScript("OnCursorChanged", function(self, _, y, _, height)
        -- Keep long text editable without allowing it to paint outside its field.
        if U.bodyScroll then U.bodyScroll:SetVerticalScroll(math.max(0, -y - U.bodyScroll:GetHeight() + height + 12)) end
    end)
    -- Replace the multiline field anchors with a scrolling edit area.
    local body = U.fields.body
    local holder = body:GetParent()
    U.bodyScroll = CreateFrame("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
    U.bodyScroll:SetPoint("TOPLEFT", 8, -8); U.bodyScroll:SetPoint("BOTTOMRIGHT", -28, 8)
    body:ClearAllPoints(); body:SetParent(U.bodyScroll); body:SetWidth(842); body:SetHeight(112)
    U.bodyScroll:SetScrollChild(body)
    U.bodyScroll:HookScript("OnScrollRangeChanged", function(self) U.UpdateScroll(self) end)
    U.bodyScroll:HookScript("OnShow", function(self) U.UpdateScroll(self) end)
    -- An empty message box is one line high: a click anywhere in the panel starts writing.
    U.bodyScroll:EnableMouse(true)
    U.bodyScroll:SetScript("OnMouseDown", function() body:SetFocus(); body:SetCursorPosition(#body:GetText()) end)
    body:SetFont(STANDARD_TEXT_FONT, U.TextSize(), "")
    U.reading[#U.reading + 1] = function(size) body:SetFont(STANDARD_TEXT_FONT, size, "") end
    for key, field in pairs(U.fields) do
        field.caption:SetTextColor(unpack(C.ivory))
        field:SetScript("OnTextChanged", function(self, user)
            if user then
                U.draft[key] = self:GetText(); U.SaveDraft()
                self.caption:SetText(key == "title" and "Title" or key == "body" and "Invitation" or "Meeting place")
                updateWriterHint()
                if U.bodyCount then U.bodyCount:SetText(#(U.draft.body or "") .. " / 1600 bytes") end
            end
        end)
    end
    -- Tab moves on through the boxes (Shift and Tab moves back), and Enter moves on from the
    -- one-line boxes. A secret meeting place is passed over.
    local order = { U.fields.title, U.fields.body, U.fields.location }
    function U.FocusNext(from, back)
        local at
        for i, field in ipairs(order) do if field == from then at = i end end
        if not at then return end
        for _ = 1, #order do
            at = (at + (back and -2 or 0)) % #order + 1
            if order[at] ~= U.fields.location or not U.draft.secret then order[at]:SetFocus(); return end
        end
    end
    for _, field in ipairs(order) do
        field:SetScript("OnTabPressed", function(self) U.FocusNext(self, IsShiftKeyDown and IsShiftKeyDown()) end)
        if field ~= U.fields.body then field:SetScript("OnEnterPressed", function(self) U.FocusNext(self) end) end
    end
    U.writerAction = at(U.Button(page, "Post", 208, function() U.Publish() end, "seal"), 712, -540)
    U.writerHint = at(U.FitText(U.Text(page, "", 14, C.muted), 204, 24, false), 716, -62)
    U.writerHint:SetJustifyH("RIGHT")
    U.editHint = at(U.FitText(U.Text(page, "Only the title, invitation and meeting place can change.", 14, C.muted), 650, 38, true), 38, -540)

    U.calendar = U.MonthCalendar(options, -108, 146, function(day) set("startDays", day) end)
    -- The clock: an hour, then a quarter.
    U.clock = sheet(options, 296, 204, 222, 146)
    at(U.Text(U.clock, "Hour", 14, C.brown, nil, "caps"), 16, -10)
    U.hourCells = {}
    for hour = 0, 23 do
        local cell = at(U.Button(U.clock, string.format("%02d", hour), 42, function() set("startHour", hour) end, "flat"), 16 + (hour % 6) * 45, -30 - math.floor(hour / 6) * 30)
        cell:SetHeight(26); cell.hour = hour
        U.hourCells[hour + 1] = cell
    end
    at(U.Text(U.clock, "Minute", 14, C.brown, nil, "caps"), 16, -160)
    U.minuteCells = {}
    for i, minute in ipairs({ 0, 15, 30, 45 }) do
        local cell = at(U.Button(U.clock, string.format("%02d", minute), 42, function() U.clock:Hide(); set("startMinute", minute) end, "flat"), 106 + (i - 1) * 45, -156)
        cell:SetHeight(26); cell.minute = minute
        U.minuteCells[i] = cell
    end
end

-- Posts the notice, or saves the changes to one, and shows it on its board.
function U.Publish()
    if U.draft.secret then U.draft.location = "" end
    U.SaveDraft()
    for _, key in ipairs({"title", "body"}) do
        if E.Trim(U.draft[key] or "") == "" then
            U.fields[key].caption:SetText(key == "title" and "Title (required)" or "Invitation (required)")
            U.fields[key]:SetFocus(); U.Status(key == "title" and "Enter a subject." or "Enter a message."); return
        end
    end
    local editing = U.editing
    local result, problem
    if editing then result, problem = E.Sync.Edit(editing, U.draft) else result, problem = E.Sync.Post(U.draft) end
    if not result then U.Status(problem or "Could not post. Check your connection."); return end
    if not editing then
        -- The words are posted; the next notice starts from an empty page with the same choices.
        local d = U.draft
        S.SaveDraft({ route = 1, category = d.category, hours = d.hours, startDays = d.startDays, startHour = d.startHour, startMinute = d.startMinute })
    end
    U.GoNow(U.returnTab or "Letters")
    U.selected = result; U.expanded = true
    U.Refresh(); U.Status(editing and "Saved." or "Posted.")
end
-- "Post again": a new notice with the same words, kind, place and time on the board, set to the
-- same day and time one week after the original (the next such week that has not begun). For a
-- weekly evening that is all there is to do; any other day is chosen as usual.
function U.PostAgain(entry)
    if entry.story then U.Status("Post Story Events on the website under Officers > Events."); return end
    local draft = S.GetDraft()
    if E.Trim(draft.title or "") ~= "" or E.Trim(draft.body or "") ~= "" or E.Trim(draft.location or "") ~= "" then
        U.Confirm("You already have an unfinished notice. Replace it with a copy of this notice?", "Replace with copy", function()
            U.CopyNotice(entry)
        end, "Keep my draft")
        return
    end
    U.CopyNotice(entry)
end
function U.CopyNotice(entry)
    local now, today = E.Client.Now(), E.Client.DayStart()
    local start = entry.start + 7 * 86400
    while start <= now do start = start + 7 * 86400 end
    local days = math.floor((start - today) / 86400)
    if days > E.AheadDays(entry.categoryIndex) then days = E.AheadDays(entry.categoryIndex) end
    local within = start - (today + days * 86400)
    local hours = math.floor((entry.expires - entry.start) / 3600 + .5)
    local allowed = {}
    for _, stay in ipairs(U.stays) do allowed[stay[1]] = true end
    S.SaveDraft({ route = 1, category = entry.categoryIndex, title = entry.title, location = entry.location, body = entry.body,
        secret = entry.categoryIndex ~= 4 and (entry.location or "") == "", hours = allowed[hours] and hours or 2,
        startDays = days, startHour = math.floor((within % 86400) / 3600), startMinute = math.floor((within % 3600) / 60) })
    U.StartCompose(board(entry.categoryIndex))
    U.Status("A copy, one week later. Check the day and time, then post.")
end
function U.StartEdit(entry)
    U.expanded = false; U.fromHome = nil
    U.editDraftEntry = nil
    U.editing = entry
    U.returnTab = U.tab == "Mine" and "Mine" or board(entry.categoryIndex)
    U.homeView = nil
    U.tab = "Write"
    U.Refresh(); U.fields.title:SetFocus()
end
function U.StartCompose(fromBoard)
    U.expanded = false; U.fromHome = nil
    U.editing = nil
    U.composeBoard = fromBoard
    U.returnTab = fromBoard
    U.homeView = nil
    U.tab = "Write"
    U.Refresh(); U.fields.title:SetFocus()
end
function U.SaveDraft()
    if U.loading then return end
    if U.editing then U.draft = S.CleanDraft(U.draft) else U.draft = S.SaveDraft(U.draft) end
end
function U.LoadDraft()
    U.loading = true
    U.scheduleOptions:Hide(); U.calendar:Hide(); U.clock:Hide()
    if U.editing and U.editDraftEntry ~= U.editing then
        local e = U.editing
        local days, hour, minute = 0, 20, 0
        if e.start and e.start > 0 then
            local offset = e.start - E.Client.DayStart()
            days = math.floor(offset / 86400)
            hour = math.floor((offset % 86400) / 3600)
            minute = math.floor((offset % 3600) / 60)
        end
        U.draft = { title = e.title, location = e.location, body = e.body, category = e.categoryIndex,
            hours = math.max(1, math.ceil((e.expires - e.start) / 3600)), route = 1, secret = e.categoryIndex ~= 4 and e.location == "",
            startDays = days, startHour = hour, startMinute = minute }
        U.editDraftEntry = e
    elseif not U.editing then
        U.draft = S.GetDraft(); U.draft.route = 1
        if U.composeBoard == "Noticeboard" then U.draft.category = 4
        elseif U.draft.category == 4 or not U.draft.category then U.draft.category = 1 end
    end
    for key, field in pairs(U.fields) do
        field.caption:SetText(key == "title" and "Title" or key == "body" and "Invitation" or "Meeting place")
        field:SetText(clean(U.draft[key], key == "body" and 1600 or 100)); field:ClearFocus()
    end
    U.loading = false; U.WriterLabels()
end
function U.WriterLabels()
    local d = U.draft
    local locked = U.editing ~= nil
    local official = d.category == 4
    local editingStory = locked and U.editing.story == true
    U.kindNote:SetText(editingStory and U.kindHelp.story
        or official and U.kindHelp.gathering or U.kindHelp.adventure)
    local hours = d.hours or 2
    for _, button in ipairs(U.lastButtons) do
        U.SelectButton(button, hours == button.hours)
        button:SetEnabled(not locked)
    end
    local days, hour, minute = tonumber(d.startDays) or 0, tonumber(d.startHour) or 0, tonumber(d.startMinute) or 0
    local start = locked and U.editing.start or E.Sync.StartTime(days, hour, minute)
    local ends = locked and U.editing.expires or start + hours * 3600
    U.dayButton.label:SetText(dayName(start) .. (days > 1 and "" or ", " .. E.Client.Date(start)))
    U.timeButton.label:SetText(E.Client.Clock(start))
    U.dayButton:SetEnabled(not locked); U.timeButton:SetEnabled(not locked)
    U.SelectButton(U.dayButton, U.calendar:IsShown()); U.SelectButton(U.timeButton, U.clock:IsShown())
    U.startPreview:SetText("Leaves the board " .. when(ends))
    U.serverNow:SetText("Server time now: " .. E.Client.Stamp(E.Client.Now()))
    U.timeSummary:SetText("Starts  " .. when(start))
    U.changeTime:SetShown(not locked)
    for _, cell in ipairs(U.hourCells) do U.SelectButton(cell, cell.hour == hour) end
    for _, cell in ipairs(U.minuteCells) do U.SelectButton(cell, cell.minute == minute) end
    local secret = d.secret == true and not official
    U.secretToggle:SetShown(not official); U.SelectButton(U.secretToggle, secret); U.secretToggle:SetEnabled(not locked)
    U.pinHere:SetEnabled(not secret); U.fields.location:SetEnabled(not secret)
    if secret then U.fields.location:SetText("Not told") end
    U.writerAction.label:SetText(locked and "Save changes" or official and "Post Guild Gathering" or "Post Adventure")
    U.bodyCount:SetText(#(d.body or "") .. " / 1600 bytes")
    U.editHint:SetShown(locked)
    updateWriterHint()

end

-- Everyday preferences first; sharing explanations and recovery controls open on demand.
function U.CreateSettings()
    local page = newPage(); U.settings = page
    -- Two boxes of the same height across the whole page, with air under the last line in each.
    U.Inlay(page, 8, -148, 470, 480, {.085,.13,.17,.97})
    U.Inlay(page, 490, -148, 462, 480, {.085,.13,.17,.97})
    U.Rule(page, 38, -362, 420, {.361,.325,.271,.5})
    at(U.Text(page, "Appearance", 19, C.goldHi), 38, -162)
    U.Rule(page, 38, -184, 420)
    U.scaleStep = U.Stepper(page, "Window size", 38, -203, 186, function(direction)
        local chosen = math.floor(S.db.settings.windowScale * 10 + .5) + direction
        S.db.settings.windowScale = math.max(8, math.min(14, chosen)) / 10
        U.ApplyScale(); U.RefreshSettings()
    end, 32, true)
    U.textStep = U.Stepper(page, "Reading text", 252, -203, 186, function(direction)
        local index = 2
        for i, option in ipairs(U.textSizes) do if option[1] == S.db.settings.textSize then index = i end end
        S.db.settings.textSize = U.textSizes[math.max(1, math.min(#U.textSizes, index + direction))][1]
        U.ApplyTextSize(); U.RefreshSettings()
    end, 32, true)
    at(U.Text(page, "Minimap button", 14, C.muted), 38, -291)
    U.minimapToggle = at(U.Button(page, "", 200, function()
        S.db.settings.minimap.hide = not S.db.settings.minimap.hide
        U.PlaceLauncher(); U.RefreshSettings()
    end), 252, -282)
    U.resetWindow = at(U.Button(page, "Reset window", 150, function()
        S.db.settings.windowScale = 1; S.db.settings.position = nil
        U.frame:ClearAllPoints(); U.frame:SetPoint("CENTER"); U.ApplyScale(); U.RefreshSettings()
    end, "ink"), 38, -331)
    U.resetWindow:SetHeight(26)
    at(U.Text(page, "In game", 19, C.goldHi), 38, -376)
    U.Rule(page, 38, -400, 420)
    at(U.Text(page, "Chat reminder", 14, C.ivory), 38, -420)
    U.reminderToggle = at(U.Button(page, "", 200, function()
        S.db.settings.reminders = not S.db.settings.reminders; U.RefreshSettings()
    end), 252, -409)
    at(U.FitText(U.Text(page, "Reminders for your plans. Each invitation starts with a 15-minute reminder.", 14, C.muted), 416, 40, true), 38, -449)
    -- Map sharing and the size of the class-coloured flames.
    at(U.Text(page, "Guild map", 14, C.ivory), 38, -513)
    U.mapToggle = at(U.Button(page, "", 76, function()
        E.Map.SetEnabled(not S.db.settings.guildMap); U.RefreshSettings()
    end), 252, -502)
    -- The flames' size: small, normal, large, round again.
    U.flameSize = at(U.Button(page, "", 120, function()
        local st = S.db.settings
        st.flameSize = st.flameSize == 1 and 1.35 or st.flameSize == 1.35 and .75 or 1
        U.RefreshSettings(); if U.RefreshMapPins then U.RefreshMapPins() end
    end), 332, -502)
    at(U.FitText(U.Text(page, "You and guildmates who turn it on see each other on the maps.", 14, C.muted), 416, 42, true), 38, -543)
    -- At a glance: what is going on with this addon right now (shown while no help is open).
    U.about = {}
    U.about[1] = U.Rule(page, 510, -366, 412, C.gold)
    local function aboutLine(label, y, height)
        local caption = at(U.Text(page, label, 14, C.goldHi), 510, y)
        local body = at(U.FitText(U.Text(page, "", 14, C.text), 412, height, true), 510, y - 20)
        U.about[#U.about + 1] = caption; U.about[#U.about + 1] = body
        return body
    end
    U.aboutSharing = aboutLine("Sharing", -380, 40)
    U.aboutRole = aboutLine("Your part", -444, 40)
    U.aboutData = aboutLine("Companion", -508, 40)
    U.aboutSite = aboutLine("Guild website", -572, 20)
    at(U.Text(page, "About and sharing", 19, C.goldHi), 510, -162)
    U.Rule(page, 510, -184, 412)
    U.aboutVersion = at(U.Text(page, "Emberlight " .. E.version, 15, C.muted), 510, -203)
    -- A newer version heard from guildmates (Core/Presence.lua), in the page's red.
    U.aboutUpdate = at(U.FitText(U.Text(page, "", 15, C.goldHi), 410, 23, false), 510, -228)
    U.sharingHelp = at(U.Button(page, "How sharing works +", 230, function()
        U.settingsHelp = U.settingsHelp ~= "sharing" and "sharing" or nil; U.RefreshSettings()
    end, "ink"), 510, -265)
    U.connectionHelp = at(U.FitText(U.Text(page,
        "Without the Companion, you receive a notice or answer when you and its writer are online with Emberlight at the same time. Received notices are kept on your computer. The Companion can also bring notices saved on the guild website into your next game session.",
        15, C.muted), 412, 136, true), 510, -309)
    U.troubleshooting = at(U.Button(page, "Troubleshooting +", 230, function()
        U.settingsHelp = U.settingsHelp ~= "trouble" and "trouble" or nil; U.RefreshSettings()
    end, "ink"), 510, -309)
    U.permissions = at(U.FitText(U.Text(page, "", 14, C.muted), 410, 70, true), 510, -356)
    U.syncToggle = at(U.Button(page, "", 170, function()
        S.db.settings.guildSync = not S.db.settings.guildSync
        E.Sync.Reset(); E.Client.RequestRoster(); U.Refresh(); U.Status()
    end), 510, -422)
    U.syncRefresh = at(U.Button(page, "Check for notices", 200, function()
        E.Client.RequestRoster()
        U.Status(E.Sync.Refresh() and "Checking for notices..." or "Wait 30 seconds before checking again.")
    end), 692, -422)
    U.reportHint = at(U.Text(page, "Something wrong? Press Copy report, then Ctrl+C, and send it to an officer.", 14, C.muted), 510, -477)
    -- The version line doubles as the details for a bug report: a click selects all of it, ready
    -- for Ctrl+C (an addon cannot write the clipboard itself). Typing in it changes nothing.
    U.buildInfo = at(CreateFrame("EditBox", nil, page), 510, -507)
    U.buildInfo:SetSize(410, 28)
    U.buildInfo:SetFont(STANDARD_TEXT_FONT, 14, "")
    U.buildInfo:SetTextColor(unpack(C.muted))
    U.buildInfo:SetAutoFocus(false)
    U.buildInfo:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    U.buildInfo:SetScript("OnTextChanged", function(self, typed) if typed then self:SetText(U.ReportDetails()); self:HighlightText() end end)
    U.buildInfo:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    U.buildInfo:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Click to select the full report, then use your copy shortcut.", 1, 1, 1, 1, true); GameTooltip:Show()
    end)
    U.buildInfo:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- The game lets an addon select text but not write to the clipboard, so this selects the report
    -- and says what to press.
    U.copyReport = at(U.Button(page, "Copy report", 150, function()
        U.buildInfo:SetText(U.ReportDetails()); U.buildInfo:SetFocus(); U.buildInfo:HighlightText()
        U.Status("Report selected. Press Ctrl+C to copy it.")
    end, "ink"), 510, -545)
    U.copyReport:SetHeight(26)
end
function U.RefreshSettings()
    local on = S.db.settings.guildSync
    U.syncToggle.label:SetText(on and "Pause messages" or "Resume messages")
    U.SetVariant(U.syncToggle, "ink")
    U.syncRefresh:SetEnabled(E.Sync.Ready() or false)
    local _, roster, me = context()
    local status = not on and "Messages are paused. Saved notices remain readable."
        or E.Client.CommsBlocked() and "WoW has paused messages. Saved notices remain readable."
        or E.Sync.Ready() and "Guild notices are checked automatically." or E.Sync.Status()
    U.permissions:SetText(status .. (roster and ("\n" .. clean(roster[me].rank, 80) .. ": " .. (roster[me].officer and "You can post Adventures and Guild Gatherings." or "You can post Adventures and answer guild events.")) or ""))
    U.sharingHelp.label:SetText("How sharing works " .. (U.settingsHelp == "sharing" and "-" or "+"))
    U.troubleshooting.label:SetText("Troubleshooting " .. (U.settingsHelp == "trouble" and "-" or "+"))
    U.troubleshooting:ClearAllPoints(); at(U.troubleshooting, 510, U.settingsHelp == "sharing" and -445 or -309)
    for _, widget in ipairs(U.about) do widget:SetShown(U.settingsHelp == nil) end
    U.connectionHelp:SetShown(U.settingsHelp == "sharing")
    for _, widget in ipairs({U.permissions,U.syncToggle,U.syncRefresh,U.reportHint,U.buildInfo,U.copyReport}) do widget:SetShown(U.settingsHelp == "trouble") end
    local chosen = S.db.settings.windowScale
    local fits = chosen <= U.FitScale() + .001
    U.scaleStep.value:SetText(math.floor(chosen * 100 + .5) .. "%")
    U.scaleStep.less:SetEnabled(chosen > .8 + .001)
    U.scaleStep.more:SetEnabled(chosen < 1.4 - .001 and fits)
    local size = S.db.settings.textSize
    for i, option in ipairs(U.textSizes) do
        if option[1] == size then
            U.textStep.value:SetText(option[2])
            U.textStep.less:SetEnabled(i > 1); U.textStep.more:SetEnabled(i < #U.textSizes)
        end
    end
    U.minimapToggle.label:SetText(S.db.settings.minimap.hide and "Hidden" or "Shown")
    U.reminderToggle.label:SetText(S.db.settings.reminders and "On" or "Off")
    U.mapToggle.label:SetText(S.db.settings.guildMap and "On" or "Off")
    U.SelectButton(U.minimapToggle, not S.db.settings.minimap.hide)
    U.SelectButton(U.reminderToggle, S.db.settings.reminders)
    U.SelectButton(U.mapToggle, S.db.settings.guildMap)
    local size = S.db.settings.flameSize
    U.flameSize.label:SetText("Size: " .. (size == .75 and "Small" or size == 1.35 and "Large" or "Normal"))
    U.flameSize:SetEnabled(S.db.settings.guildMap)
    local newest = E.Presence.Newest()
    U.aboutUpdate:SetText(newest and ("Version " .. newest .. " is out. Please update.") or "")
    U.buildInfo:SetText(U.ReportDetails())
    U.buildInfo:SetCursorPosition(0) -- show the start of the line, not its end
    -- The glance card: the same facts as Troubleshooting, in plain words.
    U.aboutSharing:SetText(status)
    U.aboutRole:SetText(roster and roster[me] and (clean(roster[me].rank, 60) .. ": " .. (roster[me].officer
        and "you can post Adventures and Guild Gatherings." or "you can post Adventures and answer guild events.")) or "Not in a guild with Emberlight on this character.")
    local archive = type(EmberlightArchive) == "table" and tonumber(EmberlightArchive.generated)
    U.aboutData:SetText(archive and ("Last brought notices on " .. date("%d %b, %H:%M", archive) .. ".")
        or "Nothing brought yet. Sync Emberlight Companion before you start the game.")
    U.aboutSite:SetText((E.Presence.url:gsub("^https://", "")))
end
-- One line for a bug report: version, game build, character, guild board and when the Companion
-- last brought data. Nothing private: the board is the guild's id, already in every notice.
function U.ReportDetails()
    local archive = type(EmberlightArchive) == "table" and tonumber(EmberlightArchive.generated)
    return string.format("Emberlight %s / %s / %s / board %s / Companion data %s",
        E.version, E.Client.Build(), E.Client.Name() or "?", (E.Client.ScopeKey()) or "none",
        archive and date("%d %b %H:%M", archive) or "none")
end

-- Quick post starts at once and leaves the board after an hour or two, for
-- finding RP tonight. It is an ordinary Adventure, so every version of the addon sees it.
function U.OpenHereNow()
    local s = U.nowSheet
    if not s then
        s = U.Paper(U.frame, 520, 280)
        s:SetPoint("CENTER", 0, 0); s:SetFrameLevel(U.frame:GetFrameLevel() + 40); s:EnableMouse(true)
        at(U.Text(s, "Quick post", 16, C.brown, nil, "caps"), 24, -20)
        at(U.Text(s, "An Adventure starting now.", 14, C.paperMuted), 24, -42)
        s.where = U.Field(s, "Where are you?", 24, -70, 472, 30, 100)
        s.pinHere = at(U.Button(s, "Use my location", 150, function() U.UseLocation(s.where) end, "bare"), 346, -66)
        s.pinHere:SetHeight(24)
        s.what = U.Field(s, "What is happening?", 24, -128, 472, 30, 100)
        at(U.Text(s, "Stays on the board for", 14, C.paperMuted), 24, -190)
        s.stays = {}
        for i, hours in ipairs({ 1, 2 }) do
            local b = at(U.Button(s, hours == 1 and "1 hour" or "2 hours", 96, function() s.hours = hours; U.RefreshHereNow() end, "flat"), 200 + (i - 1) * 104, -185)
            b:SetHeight(26); b.hours = hours; s.stays[i] = b
        end
        s.post = at(U.Button(s, "Post", 150, function() U.PostHereNow() end, "seal"), 24, -226)
        at(U.Button(s, "Cancel", 120, function() s:Hide() end), 184, -226)
        s.where:SetScript("OnTabPressed", function() s.what:SetFocus() end)
        s.where:SetScript("OnEnterPressed", function() s.what:SetFocus() end)
        s.what:SetScript("OnTabPressed", function() s.where:SetFocus() end)
        U.nowSheet = s
    end
    s.hours = 2
    s.where:SetText(""); s.what:SetText("")
    U.RefreshHereNow()
    s:Show(); s.where:SetFocus()
end
function U.RefreshHereNow()
    local s = U.nowSheet
    for _, b in ipairs(s.stays) do U.SelectButton(b, b.hours == s.hours) end
end
function U.PostHereNow()
    local s = U.nowSheet
    local where, what = E.Trim(E.Clean(s.where:GetText(), 100)), E.Trim(E.Clean(s.what:GetText(), 100))
    if where == "" then s.where:SetFocus(); U.Status("Say where you are."); return end
    if what == "" then s.what:SetFocus(); U.Status("Say what is happening."); return end
    -- It starts now: this minute on the realm's clock.
    local clock = E.Client.Now() + E.Client.RealmOffset()
    local draft = { route = 1, category = 1, hours = s.hours, title = what, location = where, body = what,
        startDays = 0, startHour = math.floor((clock % 86400) / 3600), startMinute = math.floor((clock % 3600) / 60) }
    -- Posting saves the draft it is given; the member's own unfinished draft is put back after.
    local kept = S.GetDraft()
    local result, problem = E.Sync.Post(draft)
    S.SaveDraft(kept)
    if not result then U.Status(problem or "Could not post. Check your connection."); return end
    s:Hide(); U.GoNow("Letters"); U.selected = result; U.expanded = true; U.Refresh(); U.Status("Posted.")
end

-- A reminder in chat, once, 15 minutes before something the member is joining or hosting. It is
-- one line in the chat window, never a pop-up, and it can be switched off in Settings.
function U.CheckReminders()
    U.UpdateLauncherBadge()
    local db = S.db
    if not db then return end
    if not E.Sync.ReadContext() then U.UpdateTracker({}); return end
    local list = E.Sync.List()
    U.UpdateTracker(list); U.PrunePlans(E.Client.Now())
    for _, e in ipairs(list) do U.PlanChanges(e) end
    if not db.settings.reminders then return end
    local now, done = E.Client.Now(), db.localData.reminded
    for id, start in pairs(done) do if start < now - 86400 then done[id] = nil end end
    for _, e in ipairs(list) do
        if (e.own or e.reply == "I will join") and not e.cancelled and e.start > now and e.start - now <= U.PlanMinutes(e)*60 and not done[E.Client.Name() .. "/" .. e.id] and not done[e.id] then
            done[E.Client.Name() .. "/" .. e.id] = e.start
            local minutes = math.max(1, math.floor((e.start - now) / 60 + .5))
            local place = E.Clean(e.location, 100)
            local own = E.Client.LocalClock(e.start)
            DEFAULT_CHAT_FRAME:AddMessage("Emberlight: " .. E.Clean(e.title, 100) .. " starts in " .. minutes .. " min, at " .. E.Client.Clock(e.start)
                .. " server time" .. (own ~= E.Client.Clock(e.start) and (" (" .. own .. " your time)") or "")
                .. (place ~= "" and (", " .. place) or "") .. ".", .91, .78, .46)
        end
    end
end

-- Supplies is not shown since 0.6.2 (owner's decision, 2 October 2026): it waits until a guild
-- bank can be tested on WoW: Forever. The page below is kept as it was, never shown, and still
-- uses the old layout; the engine in Core/Sync.lua still accepts supply records from older versions.
local function contributionText(project)
    local rows = {}
    for actor, c in pairs(E.Sync.Contributions(project)) do
        rows[#rows + 1] = string.format("%s: pledged %d, delivered %d, confirmed %d",
            clean(c.name, 100), c.pledged or 0, c.delivered or 0, c.confirmed or 0)
    end
    table.sort(rows)
    return #rows > 0 and ("\n\nContributions\n" .. table.concat(rows, "\n")) or "\n\nNo pledges yet."
end

function U.CreateSupplies()
    local page = CreateFrame("Frame", nil, U.frame)
    page:SetAllPoints(U.frame); U.supplies = page
    U.newSupplyButton = at(U.Button(page, "New supply request", 225, function() U.OpenSupplyModal() end), 25, -120)
    local list = U.Scroll(page, 306, 405)
    list:SetPoint("TOPLEFT", 25, -179)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(278, 405); list:SetScrollChild(child)
    U.supplyList, U.supplyListChild, U.supplyRows = list, child, {}
    U.supplyEmpty = at(U.Text(child, "", 14, U.colors.muted, 260), 5, -10)
    local paper = U.Paper(page, 585, 441)
    paper:SetPoint("TOPLEFT", 350, -149); U.supplyPaper = paper
    U.supplyTitle = at(U.FitText(U.Text(paper, "", 22, U.ink), 521, 48, true), 32, -24)
    U.supplyMeta = at(U.FitText(U.Text(paper, "", 12, U.paperMuted), 521, 40, true), 32, -76)
    U.supplyTotals = at(U.FitText(U.Text(paper, "", 12, U.paperMuted), 521, 20, false), 32, -118)
    U.supplyBody = U.ScrollText(paper, 521, 100, U.ink)
    U.supplyBody:SetPoint("TOPLEFT", 32, -146)
    U.supplyState = at(U.FitText(U.Text(paper, "", 12, U.paperMuted), 521, 16, false), 32, -250)
    U.pledgeField = U.Field(paper, "Your pledge", 32, -274, 150, 36, 7)
    U.deliveredField = U.Field(paper, "Your delivered", 192, -274, 150, 36, 7)
    U.pledgeButton = at(U.Button(paper, "Save pledge", 165, function()
        if not U.selectedSupply then return end
        local ok, problem = E.Sync.Pledge(U.selectedSupply, U.pledgeField:GetText(), U.deliveredField:GetText())
        if ok then U.RefreshSupplies(); U.Status("Pledge queued.") else U.Status(problem or "Could not queue the pledge.") end
    end), 352, -294)
    U.closeSupplyButton = at(U.Button(paper, "Close request", 145, function()
        if U.selectedSupply and E.Sync.CloseSupply(U.selectedSupply) then U.RefreshSupplies(); U.Status("Request closed.") else U.Status("Could not close this request.") end
    end), 32, -336)
    U.confirmName = U.Field(paper, "Contributor", 189, -336, 130, 32, 100)
    U.confirmAmount = U.Field(paper, "Confirmed", 329, -336, 90, 32, 7)
    U.confirmButton = at(U.Button(paper, "Confirm", 124, function()
        if not U.selectedSupply then return end
        local ok, problem = E.Sync.Confirm(U.selectedSupply, E.Client.Canonical(U.confirmName:GetText()), U.confirmAmount:GetText())
        if ok then U.confirmName:SetText(""); U.RefreshSupplies(); U.Status("Confirmation queued.") else U.Status(problem or "Could not confirm receipt.") end
    end), 429, -356)
end

function U.RefreshSupplies()
    for _, row in ipairs(U.supplyRows) do row:Hide() end
    local list = E.Sync.SupplyList()
    U.supplyEmpty:SetText(#list == 0 and "No supply requests." or "")
    U.newSupplyButton:SetShown(officer())
    local found = false
    for i, project in ipairs(list) do
        local row = U.supplyRows[i]
        if not row then
            row = U.Button(U.supplyListChild, "", 276, function(self)
                U.selectedSupply = self.project
                U.ShowSupply(self.project)
                U.RefreshSupplies()
            end)
            row:SetHeight(94); row.label:Hide()
            row.title = at(U.Text(row, "", 15, U.colors.text, 250), 12, -10)
            row.title:SetHeight(36); row.title:SetWordWrap(true); row.title:SetNonSpaceWrap(true)
            row.item = at(U.Text(row, "", 11, U.colors.gold, 250), 12, -50)
            U.FitText(row.item, 250, 15, false)
            row.meta = at(U.Text(row, "", 11, U.colors.muted, 250), 12, -73)
            U.FitText(row.meta, 250, 14, false)
            U.supplyRows[i] = row
        end
        row.project = project
        row:SetPoint("TOPLEFT", 0, -(i - 1) * 102)
        local pledged = E.Sync.Totals(project)
        row.title:SetText(clean(project.title, 100))
        row.item:SetText(clean(project.item, 60) .. ": " .. pledged .. " / " .. project.goal)
        row.meta:SetText(project.cancelled and "Closed" or U.Author(project.author, 55))
        row:Show()
        U.SelectButton(row, U.selectedSupply == project)
        if U.selectedSupply == project then found = true end
    end
    U.supplyListChild:SetHeight(math.max(405, #list * 102))
    U.UpdateScroll(U.supplyList)
    if not found then U.selectedSupply = nil end
    U.ShowSupply(U.selectedSupply)
end

function U.ShowSupply(project)
    -- A field's visible box is its EditBox's parent surround, not the EditBox itself; hide both.
    U.pledgeButton:Hide(); U.pledgeField:GetParent():Hide(); U.deliveredField:GetParent():Hide(); U.pledgeField.caption:Hide(); U.deliveredField.caption:Hide()
    U.closeSupplyButton:Hide(); U.confirmName:GetParent():Hide(); U.confirmAmount:GetParent():Hide(); U.confirmButton:Hide()
    U.confirmName.caption:Hide(); U.confirmAmount.caption:Hide()
    if not project then
        U.supplyTitle:SetText("Supplies")
        U.supplyMeta:SetText("Select a request to read.")
        U.supplyTotals:SetText("")
        U.supplyBody:SetContent("")
        U.supplyState:SetText("")
        return
    end
    local _, roster, me = E.Sync.Context()
    local pledged, delivered, confirmed = E.Sync.Totals(project)
    U.supplyTitle:SetText(clean(project.title, 100))
    U.supplyMeta:SetText("Material: " .. clean(project.item, 100) .. "\nFrom " .. U.Author(project.author, 70) .. " / " .. clean(project.location, 100))
    U.supplyTotals:SetText(string.format("Goal %d  /  Pledged %d  /  Delivered %d  /  Confirmed %d", project.goal, pledged, delivered, confirmed))
    U.supplyBody:SetContent(clean(project.body, 800) .. contributionText(project))
    U.supplyState:SetText(project.cancelled and "Closed" or "Open")
    if project.cancelled then return end
    local mine = E.Sync.Contributions(project)[me]
    U.pledgeField:SetText(mine and tostring(mine.pledged or 0) or "0"); U.pledgeField:ClearFocus()
    U.deliveredField:SetText(mine and tostring(mine.delivered or 0) or "0"); U.deliveredField:ClearFocus()
    U.pledgeButton:Show(); U.pledgeField:GetParent():Show(); U.deliveredField:GetParent():Show(); U.pledgeField.caption:Show(); U.deliveredField.caption:Show()
    if officer() and project.own then
        U.closeSupplyButton:Show()
        U.confirmName:GetParent():Show(); U.confirmAmount:GetParent():Show(); U.confirmButton:Show()
        U.confirmName.caption:Show(); U.confirmAmount.caption:Show()
    end
end

function U.OpenSupplyModal()
    if not U.supplyModal then
        local modal = U.Paper(U.frame, 560, 460)
        modal:SetPoint("CENTER", 0, -25); modal:SetFrameLevel(U.frame:GetFrameLevel() + 30)
        modal:EnableMouse(true); U.supplyModal = modal
        at(U.Text(modal, "New supply request", 19, U.ink), 32, -24)
        U.newSupply = {}
        U.newSupply.title = U.Field(modal, "Subject", 32, -60, 496, 36, 100)
        U.newSupply.item = U.Field(modal, "Material", 32, -130, 240, 36, 100)
        U.newSupply.goal = U.Field(modal, "Quantity needed", 288, -130, 240, 36, 7)
        U.newSupply.location = U.Field(modal, "Handover instructions", 32, -200, 496, 36, 100)
        U.newSupply.body = U.Field(modal, "Message", 32, -270, 496, 90, 800, true)
        at(U.Button(modal, "Post request", 205, function()
            local draft = { title = U.newSupply.title:GetText(), item = U.newSupply.item:GetText(),
                goal = U.newSupply.goal:GetText(), location = U.newSupply.location:GetText(), body = U.newSupply.body:GetText() }
            local project, problem = E.Sync.PostSupply(draft)
            if not project then U.Status(problem); return end
            modal:Hide(); U.selectedSupply = project; U.RefreshSupplies(); U.Status("Supply request queued.")
        end), 32, -397)
        at(U.Button(modal, "Cancel", 145, function() modal:Hide() end), 254, -397)
    end
    for _, field in pairs(U.newSupply) do field:SetText("") end
    U.supplyModal:Show()
end
