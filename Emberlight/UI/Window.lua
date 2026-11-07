local _, E = ...
local U, S = E.UI, E.Store
local C = U.colors
local media = "Interface\\AddOns\\Emberlight\\Media\\"

local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end
local function clean(value, limit) return E.Clean(value, limit) end
-- The two boards keep their names in code and saved data. Members see "Guild events" (official,
-- officers post) and "Adventures" (everyone posts).
local function board(categoryIndex) return categoryIndex == 4 and "Noticeboard" or "Letters" end
-- "Mine" is every open notice the member posted, on either board: a place in the rail that is
-- only there while they have one.
U.labels = { Home = "Home", Noticeboard = "Guild events", Letters = "Adventures", Mine = "Your notices", Settings = "Settings" }
-- The three kinds of adventure, in the order they are offered, with what each is for.
U.kinds = {
    { 1, "An outing with a goal: a hunt, an escort, a search, a road to travel together." },
    { 3, "A social scene: an evening at the tavern, a ceremony, a market, a story by the fire." },
    { 2, "You need someone: a healer, a guide, a rescue, a missing thing found." },
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
local function reply(entry, response, line)
    return E.Sync.Reply(entry, response, line)
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
local function upright(parent, x, y, height)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", x, y); rule:SetSize(1, height)
    rule:SetColorTexture(unpack(C.rule))
    return rule
end
-- Ink drawings for the four kinds of notice, and the tone that settles a drawing's pale paper
-- into the parchment it lies on.
local kindArt = { "KindJourney.tga", "KindAid.tga", "KindGathering.tga", "KindGuild.tga" }
local function drawing(parent, file, width, height)
    local art = parent:CreateTexture(nil, "ARTWORK")
    art:SetSize(width, height)
    if file then art:SetTexture(media .. file) end
    art:SetVertexColor(.87, .84, .76)
    return art
end
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
    row.day = at(U.FitText(U.Text(row, "", 14, C.brown, nil, "caps"), 62, 16, false), 4, -8)
    row.clock = at(U.FitText(U.Text(row, "", 14, C.brown, nil, "caps"), 62, 16, false), 4, -26)
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
    if happening(entry) then row.day:SetText("Now"); row.clock:SetText("to " .. E.Client.Clock(entry.expires))
    else row.day:SetText(E.Client.Day(entry.start)); row.clock:SetText(E.Client.Clock(entry.start)) end
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
    else U.frame:Show(); U.frame:Raise(); U.Refresh(); U.Status() end
end

-- "Are you sure": a small sheet over the page before something that cannot be undone.
function U.Confirm(text, label, action, cancelLabel)
    local s = U.confirmSheet
    if not s then
        s = U.Paper(U.frame, 470, 170)
        s:SetPoint("CENTER", 91, 0); s:SetFrameLevel(U.frame:GetFrameLevel() + 40); s:EnableMouse(true)
        s.text = at(U.FitText(U.Text(s, "", 15, C.ink, nil, "game"), 422, 72, true), 24, -24)
        s.yes = at(U.Button(s, "", 200, function() s:Hide(); if s.action then s.action() end end, "seal"), 24, -118)
        s.no = at(U.Button(s, "Keep it", 210, function() s:Hide() end), 234, -118)
        U.confirmSheet = s
    end
    s.text:SetText(text); s.yes.label:SetText(label); s.no.label:SetText(cancelLabel or "Keep it"); s.action = action
    s:Show()
end
-- Ordinary drafts save as you type. Edits are separate, so warn before discarding those words.
function U.LeaveWriter(action)
    local e, d = U.editing, U.draft
    if U.tab == "Write" and e and d and (d.title ~= e.title or d.location ~= e.location or d.body ~= e.body) then
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
    U.expanded = false; U.homeView = nil
    U.filterWhen = "all"; U.filterKind = nil
    U.editing = nil; U.composeBoard = nil; U.tab = tab
    if U.search then U.search:SetText(""); U.search:ClearFocus() end
    U.Refresh(); U.Status()
end
-- Opens one notice on its board, from Home.
function U.OpenEntry(entry)
    entry.read = true
    U.selected = entry
    U.Go(board(entry.categoryIndex))
end

-- The window is a ledger: the leather cover with the places down its left side in gold, and one
-- parchment page. The head of the page names it and holds its one main action.
function U.Create()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(960, 660)
    f.surface = U.Surface(f, "Cover.tga")
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

    local parchment = f:CreateTexture(nil, "BORDER")
    parchment:SetPoint("TOPLEFT", 204, -22); parchment:SetSize(734, 616)
    parchment:SetTexture(media .. "Page.tga")
    local crest = f:CreateTexture(nil, "ARTWORK")
    crest:SetSize(96, 96); crest:SetPoint("TOPLEFT", 63, -26)
    crest:SetTexture(media .. "Crest128.tga")
    U.tabs = {}
    for i, tab in ipairs({ "Home", "Noticeboard", "Letters", "Mine" }) do
        local button = at(U.Button(f, U.labels[tab], 170, function() U.Go(tab) end, "nav"), 26, -140 - (i - 1) * 36)
        button:SetHeight(34)
        button.badge = U.Text(button, "", 15, C.goldHi)
        button.badge:SetPoint("RIGHT", -12, 0)
        -- The count is of unopened notices, so it carries the same seal as they do.
        button.badgeSeal = seal(button, 13)
        button.badgeSeal:SetPoint("RIGHT", button.badge, "LEFT", -3, 0)
        U.tabs[tab] = button
    end
    -- The roster check, for the guild master and Flame Keepers only (UI/Roster.lua).
    local roster = U.Button(f, U.labels.Roster, 170, function() U.Go("Roster") end, "nav")
    roster:SetHeight(34)
    roster.badge = U.Text(roster, "", 15, C.goldHi); roster.badge:SetPoint("RIGHT", -12, 0)
    roster.badgeSeal = seal(roster, 13); roster.badgeSeal:SetPoint("RIGHT", roster.badge, "LEFT", -3, 0)
    U.tabs.Roster = roster
    -- Crafting, for every member (UI/Crafting.lua): requests from the Companion and own professions.
    local crafting = U.Button(f, U.labels.Crafting, 170, function() U.Go("Crafting") end, "nav")
    crafting:SetHeight(34)
    crafting.badge = U.Text(crafting, "", 15, C.goldHi); crafting.badge:SetPoint("RIGHT", -12, 0)
    crafting.badgeSeal = seal(crafting, 13); crafting.badgeSeal:SetPoint("RIGHT", crafting.badge, "LEFT", -3, 0)
    U.tabs.Crafting = crafting
    -- Settings is a place like the others, set a little apart under a thin gold rule.
    U.navRule = U.Rule(f, 40, -290, 142, { .788, .604, .247, .35 })
    U.settingsButton = at(U.Button(f, "Settings", 170, function() U.Go("Settings") end, "nav"), 26, -300)
    U.settingsButton:SetHeight(34)


    U.pageTitle = at(U.FitText(U.Text(f, "", 27, C.ink, nil, "game"), 420, 34, false), 244, -46)
    -- The close mark: a small pewter stud with a cross cut into it.
    local close = at(U.Button(f, "", 30, function() U.LeaveWriter(function() f:Hide() end) end, "bare"), 882, -51)
    close:SetHeight(30)
    local stud = close:CreateTexture(nil, "ARTWORK")
    stud:SetSize(28, 28); stud:SetPoint("CENTER")
    stud:SetTexture(media .. "Close.tga")
    stud:SetVertexColor(.9, .9, .9)
    close:HookScript("OnEnter", function() stud:SetVertexColor(1, 1, 1) end)
    close:HookScript("OnLeave", function() stud:SetVertexColor(.9, .9, .9) end)
    U.action = at(U.Button(f, "", 170, function()
        if U.homeView then U.Go("Home")
        elseif U.tab == "Write" then U.Go(U.returnTab or "Home") else U.StartCompose(U.tab) end
    end, "seal"), 688, -50)
    U.nowButton = at(U.Button(f, "Quick post", 120, function() U.OpenHereNow() end), 560, -50)
    U.nowButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:SetText("For an adventure starting now.", 1, 1, 1); GameTooltip:Show()
    end)
    U.nowButton:HookScript("OnLeave", function() GameTooltip:Hide() end)
    U.connection = at(U.FitText(U.Text(f, "", 14, C.text), 150, 102, true), 40, -466)
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 244, -78); divider:SetSize(654, 33)
    divider:SetTexture(media .. "Divider.tga")
    U.status = at(U.FitText(U.Text(f, "", 14, C.ink, nil, "game"), 654, 18, false), 244, -598)
    if E.startupProblem then
        U.status:SetText(E.startupProblem)
        for _, button in pairs(U.tabs) do button:Disable() end
        U.settingsButton:Disable(); U.action:Hide()
        f:Hide(); return
    end
    U.CreateHome()
    U.CreateReader()
    U.CreateWriter()
    U.CreateSettings()
    U.CreateSupplies()
    U.CreateRoster()
    U.CreateCrafting()
    f:SetScript("OnShow", function()
        if InCombatLockdown and InCombatLockdown() then f:Hide(); return end
        U.timer = C_Timer.NewTicker(30, function()
            U.UpdateConnection()
            if U.tab == "Noticeboard" or U.tab == "Letters" or U.tab == "Mine" then U.RefreshReader()
            elseif U.tab == "Home" then U.RefreshHome()
            elseif U.tab == "Write" then U.WriterLabels() end
        end)
    end)
    f:SetScript("OnHide", function()
        if U.timer then U.timer:Cancel(); U.timer = nil end
        U.Status()
        if U.confirmSheet then U.confirmSheet:Hide() end
    end)
    f:Hide()
end

function U.Refresh()
    if not S.db then return end
    local _, roster, me = context()
    local unread, mine = { Noticeboard = 0, Letters = 0 }, 0
    for _, e in ipairs(notices()) do
        if not e.read and not e.own and not e.cancelled then unread[board(e.categoryIndex)] = unread[board(e.categoryIndex)] + 1 end
        if e.own and not e.cancelled then mine = mine + 1 end
    end
    -- "Your notices" is in the rail only while the member has something on a board.
    local showMine = mine > 0 or U.tab == "Mine" or (U.tab == "Write" and U.returnTab == "Mine")
    U.tabs.Mine:SetShown(showMine)
    -- The places after Adventures, top to bottom: Crafting, Your notices, Roster check.
    local y = -248
    U.tabs.Crafting:ClearAllPoints(); at(U.tabs.Crafting, 26, y); y = y - 36
    U.tabs.Mine:ClearAllPoints(); at(U.tabs.Mine, 26, y)
    if showMine then y = y - 36 end
    -- The roster check only while the character holds officer rank in game.
    local showRoster = U.RosterAllowed()
    if U.tab == "Roster" and not showRoster then U.tab = "Home" end
    U.tabs.Roster:SetShown(showRoster)
    U.tabs.Roster:ClearAllPoints(); at(U.tabs.Roster, 26, y)
    if showRoster then y = y - 36 end
    local below = y - 10
    -- Requests this member could make, as the Companion last brought them.
    unread.Crafting = E.Professions.WaitingForMe()
    U.navRule:ClearAllPoints(); U.navRule:SetPoint("TOPLEFT", 40, below)
    U.settingsButton:ClearAllPoints(); at(U.settingsButton, 26, below - 10)
    for tab, button in pairs(U.tabs) do
        U.SelectButton(button, tab == U.tab or (U.tab == "Write" and tab == U.returnTab))
        button.badge:SetText(unread[tab] and unread[tab] > 0 and tostring(unread[tab]) or "")
        button.badgeSeal:SetShown(unread[tab] ~= nil and unread[tab] > 0)
    end
    U.SelectButton(U.settingsButton, U.tab == "Settings")
    U.UpdateLauncherBadge()

    local writing = U.tab == "Write"
    local official = (writing and U.composeBoard or U.tab) == "Noticeboard"
    U.pageTitle:SetText(U.homeView == "joining" and "You are joining" or U.homeView == "unread" and "Unread notices"
        or writing and (U.editing and "Edit" or official and "New guild event" or "New adventure") or U.labels[U.tab] or "")
    U.action.label:SetText(U.homeView and "Back to Home" or writing and "Back" or official and "New guild event" or "New adventure")
    U.SetVariant(U.action, (writing or U.homeView) and "ink" or "seal")
    U.action:SetShown(U.homeView ~= nil or writing or U.tab == "Letters" or U.tab == "Mine" or (U.tab == "Noticeboard" and officer()))
    U.nowButton:SetShown(U.tab == "Letters" and not U.homeView)
    U.home:SetShown(U.tab == "Home")
    U.reader:SetShown(U.homeView ~= nil or U.tab == "Noticeboard" or U.tab == "Letters" or U.tab == "Mine")
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
    U.connection:SetText(message)
    U.connection:SetShown(message ~= "")
end
function U.RefreshAvailability()
    U.UpdateConnection()
    if U.reader:IsShown() then U.RefreshReader()
    elseif U.home:IsShown() then U.RefreshHome()
    elseif U.settings:IsShown() then U.RefreshSettings() end
end

-- Home: the next guild event, what the member is joining, and what is new since they last looked.
local function homeRows(page, x, limit)
    local rows = {}
    for i = 1, limit do
        rows[i] = at(ledgerRow(page, 313, function(self) if self.entry then U.OpenEntry(self.entry) end end), x, -306 - (i - 1) * 52)
    end
    return rows
end
local function fillRows(rows, list, empty, emptyText, note)
    for i, row in ipairs(rows) do
        local entry = list[i]
        row:SetShown(entry ~= nil)
        if entry then fillRow(row, entry, note(entry)) else row.entry = nil end
    end
    empty:SetText(#list == 0 and emptyText or "")
end
function U.CreateHome()
    local page = newPage(); U.home = page
    caps(page, "Next guild event", 244, -104)
    U.homeSeal = at(seal(page, 56), 836, -112)
    U.homeArt = drawing(page, kindArt[4], 60, 60); U.homeArt:SetPoint("TOPLEFT", 240, -124)
    U.homeTitle = at(U.FitText(U.Text(page, "", 22, C.ink, nil, "game"), 520, 28, false), 308, -124)
    U.homeWhen = at(U.FitText(U.Text(page, "", 16, C.paperMuted), 654, 38, true), 244, -158)
    U.homeWhere = at(U.FitText(U.Text(page, "", 14, C.paperMuted, nil, "game"), 654, 18, false), 244, -198)
    U.homeJoin = at(U.Button(page, "I will join", 140, function()
        if U.nextEvent and reply(U.nextEvent, "I will join") then U.Refresh(); U.Status("Reply queued.") else U.Status("Could not reply. Check your connection.") end
    end, "seal"), 244, -224)
    U.homeOpen = U.Button(page, "Read it", 120, function() if U.nextEvent then U.OpenEntry(U.nextEvent) end end)
    U.Rule(page, 244, -270, 654)
    upright(page, 571, -282, 280)
    caps(page, "You are joining", 244, -284)
    U.joiningAll = at(U.Button(page, "View all", 92, function() U.OpenHomeView("joining") end, "bare"), 465, -278)
    U.joiningAll:SetHeight(26)
    U.joiningRows = homeRows(page, 244, 5)
    U.joiningEmpty = at(U.FitText(U.Text(page, "", 15, C.paperMuted), 300, 60, true), 244, -312)
    caps(page, "New since you last looked", 585, -284)
    U.freshAll = at(U.Button(page, "View all", 92, function() U.OpenHomeView("unread") end, "bare"), 806, -278)
    U.freshAll:SetHeight(26)
    U.freshRows = homeRows(page, 585, 5)
    U.freshEmpty = at(U.FitText(U.Text(page, "", 15, C.paperMuted), 300, 60, true), 585, -312)
end
function U.OpenHomeView(view)
    U.GoNow("Letters"); U.homeView = view; U.filterKind = nil
    U.filterWhen = view; U.expanded = false; U.selected = nil; U.Refresh()
end
function U.RefreshHome()
    local now = E.Client.Now()
    local nextEvent, joining, fresh = nil, {}, {}
    for _, e in ipairs(notices()) do
        if not e.cancelled and e.expires > now then
            if e.categoryIndex == 4 and (not nextEvent or e.start < nextEvent.start) then nextEvent = e end
            if e.own or e.reply == "I will join" then joining[#joining + 1] = e
            elseif not e.read then fresh[#fresh + 1] = e end
        end
    end
    table.sort(joining, function(a, b) if a.start == b.start then return a.id < b.id end; return a.start < b.start end)
    U.nextEvent = nextEvent
    local canJoin = nextEvent ~= nil and not nextEvent.own and nextEvent.reply ~= "I will join"
    U.homeJoin:SetShown(canJoin)
    U.homeJoin:SetEnabled(E.Sync.Ready() or false)
    U.joiningAll:SetShown(#joining > 0); U.freshAll:SetShown(#fresh > 0)
    U.homeSeal:SetShown(nextEvent ~= nil and not nextEvent.read and not nextEvent.own)
    U.homeArt:SetShown(nextEvent ~= nil)
    U.homeOpen:SetShown(nextEvent ~= nil)
    U.homeOpen:ClearAllPoints(); at(U.homeOpen, canJoin and 394 or 244, -224)
    if nextEvent then
        U.homeTitle:SetText(clean(nextEvent.title, 100))
        U.homeWhen:SetText(when(nextEvent.start) .. " / " .. U.Until(nextEvent.start))
        local answer = nextEvent.own and "You are hosting" or nextEvent.reply and ("Your answer: " .. nextEvent.reply) or "You have not answered"
        local place = clean(nextEvent.location, 100)
        U.homeWhere:SetText((place ~= "" and (place .. " / ") or "") .. answer)
    elseif context() then
        U.homeTitle:SetText("No guild events are planned."); U.homeWhen:SetText(""); U.homeWhere:SetText("")
    else
        U.homeTitle:SetText("Sharing is not connected"); U.homeWhen:SetText(E.Sync.Status()); U.homeWhere:SetText("See Settings.")
    end
    fillRows(U.joiningRows, joining, U.joiningEmpty, "Nothing yet. Answer \"I will join\" on an event or an adventure and it appears here.",
        function(e) return e.own and "You are hosting" or U.Until(e.start) end)
    fillRows(U.freshRows, fresh, U.freshEmpty, "Nothing new.", function(e) return U.labels[board(e.categoryIndex)] .. " / from " .. U.Author(e.author, 40) end)
end

-- A board: filters and the list down the left of the page, under a heading for each day, and the
-- notice being read on the right. An empty board is one plain line in the middle of the page.
function U.CreateReader()
    local page = newPage(); U.reader = page
    U.emptyArt = drawing(page, "Empty.tga", 240, 120); U.emptyArt:SetPoint("TOPLEFT", 451, -120)
    U.empty = at(U.FitText(U.Text(page, "", 19, C.paperMuted, nil, "game"), 654, 26, false), 244, -256)
    U.empty:SetJustifyH("CENTER")
    U.emptyHint = at(U.FitText(U.Text(page, "", 15, C.paperMuted), 654, 20, false), 244, -288)
    U.emptyHint:SetJustifyH("CENTER")
    local body = CreateFrame("Frame", nil, page)
    body:SetAllPoints(page); U.boardBody = body
    U.filterWhen = "all"
    U.whenChips = {}
    -- Date/answer filters on every board; adventure kinds have their own row.
    local x = 244
    for _, chip in ipairs({ { "all", "All", 52 }, { "today", "Today", 70 }, { "week", "This week", 96 }, { "joining", "Joining", 80 }, { "unread", "Unread", 80 } }) do
        local button = at(U.Button(body, chip[2], chip[3], function() U.filterWhen = chip[1]; U.selected = nil; U.list:SetVerticalScroll(0); U.RefreshReader() end, "flat"), x, -102)
        button:SetHeight(26); button.key = chip[1]
        U.whenChips[#U.whenChips + 1] = button
        x = x + chip[3] + 4
    end
    U.kindChips = {}
    x = 898
    for i = #U.kinds, 1, -1 do
        local kind = U.kinds[i]
        local width = ({ 84, 98, 108 })[i]
        x = x - width
        local button = at(U.Button(body, E.categories[kind[1]], width, function()
            U.filterKind = U.filterKind ~= kind[1] and kind[1] or nil; U.list:SetVerticalScroll(0); U.RefreshReader()
        end, "flat"), x, -132)
        button:SetHeight(26); button.kind = kind[1]
        U.kindChips[i] = button
        x = x - 4
    end
    U.search = U.Field(body, "", 244, -138, 584, 28, 100)
    U.search.caption:Hide()
    U.searchHint = at(U.FitText(U.Text(U.search:GetParent(), "Search subject, meeting place or organiser", 14, C.paperMuted), 554, 20, false), 10, -6)
    U.search:SetScript("OnTextChanged", function(self)
        U.searchHint:SetShown(self:GetText() == "")
        if U.list then U.list:SetVerticalScroll(0); U.RefreshReader() end
    end)
    U.search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    U.searchClear = at(U.Button(body, "Clear", 60, function() U.search:SetText(""); U.search:ClearFocus() end, "bare"), 838, -158)
    U.searchClear:SetHeight(28)
    local list = U.Scroll(body, 312, 380)
    list:SetPoint("TOPLEFT", 244, -192)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(286, 380); list:SetScrollChild(child)
    U.list, U.listChild, U.rows, U.heads = list, child, {}, {}
    U.listEmpty = at(U.FitText(U.Text(child, "", 14, C.paperMuted), 276, 40, true), 4, -8)
    U.listRule = upright(body, 554, -192, 380)
    local paper = CreateFrame("Frame", nil, body)
    paper:SetSize(332, 380); paper:SetPoint("TOPLEFT", 566, -192); U.paper = paper
    U.readerArt = drawing(paper, nil, 56, 56); U.readerArt:SetPoint("TOPLEFT", -2, -6)
    U.readerKind = at(U.FitText(U.Text(paper, "", 14, C.brown, nil, "caps"), 270, 16, false), 62, -2)
    U.readerTitle = at(U.FitText(U.Text(paper, "", 21, C.ink, nil, "game"), 270, 42, true), 62, -18)
    U.readerMeta = at(U.FitText(U.Text(paper, "", 14, C.paperMuted, nil, "game"), 332, 52, true), 0, -62)
    U.expand = at(U.Button(paper, "Read on a full page", 180, function()
        U.expanded = not U.expanded; U.RefreshReader()
    end, "bare"), 0, -112)
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
    at(U.Button(U.lineSheet, "Keep this line", 170, function() U.lineField:ClearFocus(); U.lineSheet:Hide() end), 24, -112)
    at(U.Button(U.lineSheet, "Cancel", 120, function()
        U.lineField:SetText(U.selected and E.Sync.MyLine(U.selected) or ""); U.lineSheet:Hide()
    end), 204, -112)
    U.lineButton = at(U.Button(paper, "Add a line", 120, function() U.lineSheet:Show(); U.lineField:SetFocus() end, "bare"), 0, -300)
    U.lineButton:SetHeight(26)
    U.readerState = at(U.FitText(U.Text(paper, "", 14, C.paperMuted), 194, 40, true), 138, -302)
    U.join = at(U.Button(paper, "I will join", 130, function()
        if U.selected and reply(U.selected, "I will join", U.lineField:GetText()) then U.lineField:ClearFocus(); U.Refresh(); U.Status("Reply queued.") else U.Status("Could not reply. Check your connection and the notice expiry.") end
    end, "seal"), 0, -344)
    U.decline = at(U.Button(paper, "Unable", 110, function()
        if U.selected and reply(U.selected, "Unable to attend") then U.Refresh(); U.Status("Reply queued.") else U.Status("Could not reply. Check your connection and the notice expiry.") end
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
end

function U.LayoutReader()
    local full = U.expanded == true
    local kinds = U.tab == "Letters" and not U.homeView
    local top = full and -102 or kinds and -192 or -162
    local width = full and 654 or 332
    U.list:SetShown(not full); U.listRule:SetShown(not full)
    U.list:SetPoint("TOPLEFT", 244, top); U.list:SetHeight(572 + top)
    U.listRule:SetPoint("TOPLEFT", 554, top); U.listRule:SetHeight(572 + top)
    U.paper:ClearAllPoints(); at(U.paper, full and 244 or 566, top); U.paper:SetSize(width, full and 470 or 380)
    for _, chip in ipairs(U.whenChips) do chip:SetShown(not full); U.SelectButton(chip, chip.key == U.filterWhen) end
    for _, chip in ipairs(U.kindChips) do chip:SetShown(not full and kinds); U.SelectButton(chip, chip.kind == U.filterKind) end
    local searchY = kinds and -158 or -128
    local holder = U.search:GetParent(); holder:ClearAllPoints(); at(holder, 244, searchY); holder:SetShown(not full)
    U.searchHint:SetShown(not full and U.search:GetText() == "")
    U.searchClear:ClearAllPoints(); at(U.searchClear, 838, searchY); U.searchClear:SetShown(not full)
    U.readerTitle:SetWidth(width - 62); U.readerKind:SetWidth(width - 62); U.readerMeta:SetWidth(width)
    U.expand.label:SetText(full and "Back to the list" or "Read on a full page")
    U.readerBody:SetWidth(width - 26); U.readerBody:SetHeight(full and 230 or 130); U.readerBody:Reflow()
    local lower = full and 100 or 0
    U.whoHead:ClearAllPoints(); at(U.whoHead, 0, -278 - lower); U.whoHead:SetWidth(width - 110)
    U.answersButton:ClearAllPoints(); at(U.answersButton, width - 102, -274 - lower)
    U.lineButton:ClearAllPoints(); at(U.lineButton, 0, -300 - lower)
    U.readerState:ClearAllPoints(); at(U.readerState, 138, -302 - lower); U.readerState:SetWidth(width - 138)
    U.readerState:SetHeight(full and 30 or 40)
    for _, pair in ipairs({{U.join,0},{U.decline,138},{U.edit,0},{U.withdraw,102},{U.again,216},{U.moderate,width-76}}) do
        pair[1]:ClearAllPoints(); at(pair[1], pair[2], -344 - (full and 94 or 0))
    end
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
    local all, entries = 0, {}
    local now, today = E.Client.Now(), E.Client.DayStart()
    local query = E.Trim(clean(U.search:GetText(), 100)):lower()
    for _, e in ipairs(notices()) do
        if U.homeView or mine and e.own or not mine and board(e.categoryIndex) == U.tab then
            all = all + 1
            local joined = e.own or e.reply == "I will join"
            local keep = (not U.homeView or not e.cancelled and e.expires > now and (U.homeView == "joining" and joined
                or U.homeView == "unread" and not joined and (not e.read or e == U.selected)))
                and (U.filterWhen == "all"
                or U.filterWhen == "today" and e.start < today + 86400
                or U.filterWhen == "week" and e.start < today + 7 * 86400
                or U.filterWhen == "joining" and joined
                or U.filterWhen == "unread" and (not e.read or e == U.selected) and not e.own and not e.cancelled)
                and (not U.filterKind or events or mine or U.homeView or e.categoryIndex == U.filterKind)
            local searchable = (clean(e.title, 100) .. " " .. clean(e.location, 100) .. " " .. U.Author(e.author, 120)):lower()
            keep = keep and (query == "" or searchable:find(query, 1, true) ~= nil)
            if keep then entries[#entries + 1] = e end
        end
    end
    -- Soonest first: a board is read as "what is coming up".
    table.sort(entries, function(a, b) if a.start == b.start then return a.id < b.id end; return a.start < b.start end)
    U.boardBody:SetShown(all > 0)
    U.emptyArt:SetShown(all == 0)
    U.empty:SetText(all == 0 and (events and "No guild events are planned." or mine and "You have nothing on the boards." or "No adventures posted yet.") or "")
    U.emptyHint:SetText(all > 0 and "" or not context() and "Sharing is not connected. See Settings."
        or events and (officer() and "Post one with New guild event." or "Officers post them here.") or mine and "Post one with New adventure." or "Post the first with New adventure.")
    U.LayoutReader()
    local height = U.list:GetHeight()
    U.listEmpty:SetText(all > 0 and #entries == 0 and "Nothing here matches. Choose All to see everything." or "")
    local found, y, lastDay, heads = false, 0, nil, 0
    for i, entry in ipairs(entries) do
        local day = dayName(entry.start, entry)
        if day ~= lastDay then
            heads = heads + 1
            local head = U.heads[heads]
            if not head then head = U.FitText(U.Text(U.listChild, "", 14, C.brown, nil, "caps"), 276, 16, false); U.heads[heads] = head end
            head:SetPoint("TOPLEFT", 4, -y - 6); head:SetText(day); head:Show()
            y = y + 26; lastDay = day
        end
        local row = U.rows[i]
        if not row then
            row = ledgerRow(U.listChild, 282, function(self)
                U.selected = self.entry
                self.entry.read = true
                U.Refresh()
            end)
            U.rows[i] = row
        end
        row:SetPoint("TOPLEFT", 0, -y)
        y = y + 52
        fillRow(row, entry, entry.cancelled and (entry.moderated and "Removed by an officer" or "Withdrawn")
            or entry.expires <= now and "Ended"
            or E.Sync.Pending(entry) and "Sending..."
            or entry.reply and ("You: " .. entry.reply)
            or mine and clean(entry.category, 50)
            or (events and "" or (clean(entry.category, 50) .. " / ")) .. U.Author(entry.author, 55))
        row:Show()
        U.SelectButton(row, U.selected == entry)
        if U.selected == entry then found = true end
    end
    U.listChild:SetHeight(math.max(height, y))
    U.UpdateScroll(U.list)
    if not found then U.selected = nil; U.expanded = false; U.LayoutReader() end
    U.ShowEntry(U.selected)
    if U.answersSheet and U.answersSheet:IsShown() then
        if U.selected then U.OpenAnswers() else U.answersSheet:Hide() end
    end
end

function U.ShowEntry(entry)
    U.join:Hide(); U.decline:Hide(); U.withdraw:Hide(); U.edit:Hide(); U.moderate:Hide(); U.again:Hide()
    U.readerArt:SetShown(entry ~= nil)
    U.expand:SetShown(entry ~= nil); U.answersButton:SetShown(entry ~= nil)
    U.lineButton:Hide()
    if entry then U.readerArt:SetTexture(media .. (kindArt[entry.categoryIndex] or kindArt[1])) end
    if not entry then
        U.readerKind:SetText("")
        U.readerTitle:SetText(U.labels[U.tab] or "")
        U.readerMeta:SetText(U.tab == "Noticeboard" and "Select an event to read." or U.tab == "Mine" and "Select one to read, change or withdraw." or "Select an adventure to read.")
        U.readerBody:SetContent("")
        U.readerState:SetText("")
        U.whoHead:SetText("")
        U.lineField:GetParent():Hide(); U.lineField.caption:Hide()
        U.lineSheet:Hide()
        return
    end
    U.readerKind:SetText(clean(entry.category, 50))
    U.readerTitle:SetText(clean(entry.title, 100))
    local starts = entry.start and entry.start > 0 and (when(entry.start) .. "\n" .. U.Until(entry.start) .. " / ") or ""
    local place = clean(entry.location, 100)
    if place == "" and entry.categoryIndex ~= 4 then place = "Place not told" end
    U.readerMeta:SetText(starts .. (place ~= "" and (place .. " / from ") or "from ") .. U.Author(entry.author, 70))
    U.readerBody:SetContent(clean(entry.body, 1600))
    local joining, unable = answers(entry)
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
    U.again:SetShown(entry.own == true)
    U.moderate:SetShown(open and not entry.own and officer())
    local ready = E.Sync.Ready() or false
    for _, button in ipairs({ U.join, U.decline, U.withdraw, U.edit, U.again, U.moderate, U.lineButton }) do button:SetEnabled(ready) end
    U.SelectButton(U.join, entry.reply == "I will join"); U.SelectButton(U.decline, entry.reply == "Unable to attend")
    U.join.label:SetText(entry.reply == "I will join" and "You're going" or "I will join")
    U.SetVariant(U.join, entry.reply == "I will join" and "ink" or "seal")
end

-- Writing: what kind it is, when it starts by the realm's clock, how long it stays on the board,
-- then the words. The day and the time are chosen from a small sheet; Post is the only step.
function U.CreateWriter()
    local page = newPage(); U.writer = page
    U.draft = {}
    local function set(key, value)
        if U.editing then return end
        U.draft[key] = value; U.SaveDraft(); U.WriterLabels()
    end
    U.kindButtons = {}
    for i, kind in ipairs(U.kinds) do
        U.kindButtons[i] = at(U.Button(page, E.categories[kind[1]], 150, function() set("category", kind[1]) end, "flat"), 244 + (i - 1) * 158, -102)
        U.kindButtons[i]:SetHeight(30)
    end
    U.kindNote = at(U.FitText(U.Text(page, "", 15, C.paperMuted), 654, 18, false), 244, -138)

    at(U.Text(page, "Starts", 14, C.paperMuted), 244, -166)
    U.dayButton = at(U.Button(page, "", 190, function()
        U.clock:Hide(); U.calendar:SetShown(not U.calendar:IsShown()); U.WriterLabels()
    end), 244, -186)
    U.timeButton = at(U.Button(page, "", 110, function()
        U.calendar:Hide(); U.clock:SetShown(not U.clock:IsShown()); U.WriterLabels()
    end), 442, -186)
    at(U.Text(page, "server time", 14, C.paperMuted), 562, -194)
    local now = at(U.Panel(page, 190, 52, { .114, .102, .082, .08 }), 708, -166)
    at(U.Text(now, "Server time now", 13, C.brown, nil, "caps"), 12, -8)
    U.serverNow = at(U.FitText(U.Text(now, "", 17, C.ink, nil, "game"), 170, 20, false), 12, -26)

    at(U.Text(page, "Stays on the board for", 14, C.paperMuted), 244, -232)
    U.lastButtons = {}
    for i, stay in ipairs(U.stays) do
        U.lastButtons[i] = at(U.Button(page, stay[2], 88, function() set("hours", stay[1]) end, "flat"), 244 + (i - 1) * 94, -252)
        U.lastButtons[i]:SetHeight(28); U.lastButtons[i].hours = stay[1]
    end
    U.startPreview = at(U.FitText(U.Text(page, "", 14, C.brown), 654, 18, false), 244, -286)

    U.fields = {}
    U.fields.title = U.Field(page, "Subject", 244, -312, 400, 34, 100)
    U.fields.location = U.Field(page, "Meeting place", 656, -312, 242, 34, 100)
    U.secretToggle = at(U.Button(page, "Keep it secret", 110, function()
        if U.editing then return end
        U.draft.secret = not U.draft.secret
        if U.draft.secret then U.draft.location = "" end
        U.SaveDraft(); U.LoadDraft()
    end, "flat"), 788, -310)
    U.secretToggle:SetHeight(20)
    U.fields.body = U.Field(page, "Message", 244, -372, 654, 136, 1600, true)
    U.bodyCount = at(U.FitText(U.Text(page, "", 14, C.paperMuted), 210, 18, false), 688, -372)
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
    body:ClearAllPoints(); body:SetParent(U.bodyScroll); body:SetWidth(612); body:SetHeight(120)
    U.bodyScroll:SetScrollChild(body)
    U.bodyScroll:HookScript("OnScrollRangeChanged", function(self) U.UpdateScroll(self) end)
    U.bodyScroll:HookScript("OnShow", function(self) U.UpdateScroll(self) end)
    -- An empty message box is one line high: a click anywhere in the panel starts writing.
    U.bodyScroll:EnableMouse(true)
    U.bodyScroll:SetScript("OnMouseDown", function() body:SetFocus(); body:SetCursorPosition(#body:GetText()) end)
    body:SetFont(STANDARD_TEXT_FONT, U.TextSize(), "")
    U.reading[#U.reading + 1] = function(size) body:SetFont(STANDARD_TEXT_FONT, size, "") end
    for key, field in pairs(U.fields) do
        field:SetScript("OnTextChanged", function(self, user)
            if user then
                U.draft[key] = self:GetText(); U.SaveDraft()
                self.caption:SetText(key == "title" and "Subject" or key == "body" and "Message" or "Meeting place")
                if U.bodyCount then U.bodyCount:SetText(#(U.draft.body or "") .. " / 1600 bytes") end
            end
        end)
    end
    -- Tab moves on through the boxes (Shift and Tab moves back), and Enter moves on from the
    -- one-line boxes. A secret meeting place is passed over.
    local order = { U.fields.title, U.fields.location, U.fields.body }
    function U.FocusNext(from, back)
        local at
        for i, field in ipairs(order) do if field == from then at = i end end
        if not at then return end
        for _ = 1, #order do
            at = (at + (back and -2 or 0)) % #order + 1
            if order[at] ~= U.fields.location or not U.draft.secret then order[at]:SetFocus(); return end
        end
    end
    for i, field in ipairs(order) do
        field:SetScript("OnTabPressed", function(self) U.FocusNext(self, IsShiftKeyDown and IsShiftKeyDown()) end)
        if i < #order then field:SetScript("OnEnterPressed", function(self) U.FocusNext(self) end) end
    end
    U.writerAction = at(U.Button(page, "Post", 170, function() U.Publish() end, "seal"), 244, -542)
    U.writerHint = at(U.FitText(U.Text(page, "", 14, C.paperMuted), 470, 34, true), 428, -542)

    -- The calendar: today and the three weeks after it, Monday first.
    U.calendar = sheet(page, 296, 212, 244, -220)
    U.calendarMonth = at(U.Text(U.calendar, "", 14, C.brown, nil, "caps"), 16, -10)
    for i, name in ipairs({ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }) do
        local head = at(U.FitText(U.Text(U.calendar, name, 14, C.paperMuted), 36, 18, false), 16 + (i - 1) * 38, -32)
        head:SetJustifyH("CENTER")
    end
    U.dayCells = {}
    for i = 1, 28 do
        local cell = at(U.Button(U.calendar, "", 36, function(self)
            if self.days then U.calendar:Hide(); set("startDays", self.days) end
        end, "flat"), 16 + ((i - 1) % 7) * 38, -52 - math.floor((i - 1) / 7) * 38)
        cell:SetHeight(34)
        U.dayCells[i] = cell
    end
    -- The clock: an hour, then a quarter.
    U.clock = sheet(page, 296, 204, 442, -220)
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
            U.fields[key].caption:SetText(key == "title" and "Subject (required)" or "Message (required)")
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
    U.selected = result; U.editing = nil; U.composeBoard = nil
    U.tab = U.returnTab or "Letters"
    U.Refresh(); U.Status(editing and "Saved." or "Posted.")
end
-- "Post again": a new notice with the same words, kind, place and time on the board, set to the
-- same day and time one week after the original (the next such week that has not begun). For a
-- weekly evening that is all there is to do; any other day is chosen as usual.
function U.PostAgain(entry)
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
    if days > E.maxHorizonDays then days = E.maxHorizonDays end
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
    U.editDraftEntry = nil
    U.editing = entry
    U.returnTab = U.tab == "Mine" and "Mine" or board(entry.categoryIndex)
    U.tab = "Write"
    U.Refresh()
end
function U.StartCompose(fromBoard)
    U.editing = nil
    U.composeBoard = fromBoard
    U.returnTab = fromBoard
    U.tab = "Write"
    U.Refresh()
end
function U.SaveDraft()
    if U.loading then return end
    if U.editing then U.draft = S.CleanDraft(U.draft) else U.draft = S.SaveDraft(U.draft) end
end
function U.LoadDraft()
    U.loading = true
    U.calendar:Hide(); U.clock:Hide()
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
        field.caption:SetText(key == "title" and "Subject" or key == "body" and "Message" or "Meeting place")
        field:SetText(clean(U.draft[key], key == "body" and 1600 or 100)); field:ClearFocus()
    end
    U.loading = false; U.WriterLabels()
end
function U.WriterLabels()
    local d = U.draft
    local locked = U.editing ~= nil
    local official = d.category == 4
    for i, kind in ipairs(U.kinds) do
        local button = U.kindButtons[i]
        button:SetShown(not official)
        U.SelectButton(button, d.category == kind[1])
        button:SetEnabled(not locked)
        if d.category == kind[1] then U.kindNote:SetText(kind[2]) end
    end
    if official then U.kindNote:SetText("A guild event: official business for everyone, posted by an officer.") end
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
    local own = E.Client.LocalClock(start)
    U.startPreview:SetText((own ~= E.Client.Clock(start) and ("Starts " .. own .. " your time. ") or "") .. (ends <= E.Client.Now() and "That time has already passed." or "Leaves the board " .. E.Client.Stamp(ends) .. " server time."))
    U.serverNow:SetText(E.Client.Stamp(E.Client.Now()))
    -- The calendar starts on the Monday of this week; days before today are left out.
    local today = E.Client.DayStart()
    local first = E.Client.Weekday(today)
    for i, cell in ipairs(U.dayCells) do
        local n = i - 1 - first
        cell.days = n >= 0 and n <= E.maxHorizonDays and n or nil
        cell:SetShown(cell.days ~= nil)
        if cell.days then
            cell.label:SetText(tostring(E.Client.MonthDay(today + n * 86400 + 43200)))
            U.SelectButton(cell, n == days)
        end
    end
    local month, last = E.Client.Month(today + 43200), E.Client.Month(today + E.maxHorizonDays * 86400 + 43200)
    U.calendarMonth:SetText(month == last and month or month .. " and " .. last)
    for _, cell in ipairs(U.hourCells) do U.SelectButton(cell, cell.hour == hour) end
    for _, cell in ipairs(U.minuteCells) do U.SelectButton(cell, cell.minute == minute) end
    local secret = d.secret == true and not official
    U.secretToggle:SetShown(not official); U.SelectButton(U.secretToggle, secret); U.secretToggle:SetEnabled(not locked)
    U.fields.location:SetEnabled(not secret)
    if secret then U.fields.location:SetText("Not told") end
    U.writerAction.label:SetText(locked and "Save changes" or "Post")
    U.bodyCount:SetText(#(d.body or "") .. " / 1600 bytes")
    local party = E.Client.Channel() == "PARTY"
    if locked then
        U.writerHint:SetText("The kind, the start and the time on the board cannot change. Withdraw and post again for that.")
    elseif U.composeBoard == "Noticeboard" then
        U.writerHint:SetText("Your draft is saved as you write. " .. (party and "Only the party leader can post guild events." or "Guild events require the guild leader, Flame Keeper or Officer Alt rank."))
    else
        U.writerHint:SetText("Your draft is saved as you write. It goes to your " .. (party and "party" or "guild") .. "; any member can answer.")
    end
end

-- Everyday preferences first; sharing explanations and recovery controls open on demand.
function U.CreateSettings()
    local page = newPage(); U.settings = page
    caps(page, "Appearance", 244, -104)
    U.scaleStep = U.Stepper(page, "Window size", 244, -130, 200, function(direction)
        local chosen = math.floor(S.db.settings.windowScale * 10 + .5) + direction
        S.db.settings.windowScale = math.max(8, math.min(14, chosen)) / 10
        U.ApplyScale(); U.RefreshSettings()
    end)
    U.textStep = U.Stepper(page, "Reading text", 471, -130, 200, function(direction)
        local index = 2
        for i, option in ipairs(U.textSizes) do if option[1] == S.db.settings.textSize then index = i end end
        S.db.settings.textSize = U.textSizes[math.max(1, math.min(#U.textSizes, index + direction))][1]
        U.ApplyTextSize(); U.RefreshSettings()
    end)
    at(U.Text(page, "Minimap button", 14, C.paperMuted), 698, -130)
    U.minimapToggle = at(U.Button(page, "", 200, function()
        S.db.settings.minimap.hide = not S.db.settings.minimap.hide
        U.PlaceLauncher(); U.RefreshSettings()
    end), 698, -150)
    U.resetWindow = at(U.Button(page, "Reset window", 150, function()
        S.db.settings.windowScale = 1; S.db.settings.position = nil
        U.frame:ClearAllPoints(); U.frame:SetPoint("CENTER"); U.ApplyScale(); U.RefreshSettings()
    end, "bare"), 244, -188)
    U.resetWindow:SetHeight(26)
    at(U.Text(page, "Chat reminder", 14, C.paperMuted), 244, -230)
    U.reminderToggle = at(U.Button(page, "", 200, function()
        S.db.settings.reminders = not S.db.settings.reminders; U.RefreshSettings()
    end), 698, -220)
    at(U.FitText(U.Text(page, "One line 15 minutes before something you are joining or hosting.", 14, C.paperMuted), 654, 34, true), 244, -254)
    U.Rule(page, 244, -296, 654)
    caps(page, "About", 244, -308)
    U.aboutVersion = at(U.Text(page, "Emberlight " .. E.version, 15, C.paperMuted), 244, -330)
    U.sharingHelp = at(U.Button(page, "How sharing works +", 230, function()
        U.settingsHelp = U.settingsHelp ~= "sharing" and "sharing" or nil; U.RefreshSettings()
    end, "bare"), 244, -352)
    U.connectionHelp = at(U.FitText(U.Text(page,
        "Without the Companion, you receive a notice or answer when you and its writer are online with Emberlight at the same time. Received notices are kept on your computer. The Companion can also bring notices saved on the guild website into your next game session.",
        15, C.paperMuted), 654, 100, true), 244, -386)
    U.troubleshooting = at(U.Button(page, "Troubleshooting +", 230, function()
        U.settingsHelp = U.settingsHelp ~= "trouble" and "trouble" or nil; U.RefreshSettings()
    end, "bare"), 244, -390)
    U.permissions = at(U.FitText(U.Text(page, "", 14, C.paperMuted), 654, 48, true), 244, -430)
    U.syncToggle = at(U.Button(page, "", 170, function()
        S.db.settings.guildSync = not S.db.settings.guildSync
        E.Sync.Reset(); E.Client.RequestRoster(); U.Refresh(); U.Status()
    end), 244, -482)
    U.syncRefresh = at(U.Button(page, "Check for notices", 200, function()
        E.Client.RequestRoster()
        U.Status(E.Sync.Refresh() and "Checking for notices..." or "Wait 30 seconds before checking again.")
    end), 422, -482)
    U.reportHint = at(U.Text(page, "Click the details, then Ctrl+C, for a bug report:", 14, C.paperMuted), 244, -524)
    -- The version line doubles as the details for a bug report: a click selects all of it, ready
    -- for Ctrl+C (an addon cannot write the clipboard itself). Typing in it changes nothing.
    U.buildInfo = at(CreateFrame("EditBox", nil, page), 244, -546)
    U.buildInfo:SetSize(654, 20)
    U.buildInfo:SetFont(STANDARD_TEXT_FONT, 14, "")
    U.buildInfo:SetTextColor(unpack(C.paperMuted))
    U.buildInfo:SetAutoFocus(false)
    U.buildInfo:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    U.buildInfo:SetScript("OnTextChanged", function(self, typed) if typed then self:SetText(U.ReportDetails()); self:HighlightText() end end)
    U.buildInfo:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    U.buildInfo:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Click, then Ctrl+C, to copy these details for a bug report.", 1, 1, 1, 1, true); GameTooltip:Show()
    end)
    U.buildInfo:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
    U.permissions:SetText(status .. (roster and ("\n" .. clean(roster[me].rank, 80) .. ": " .. (roster[me].officer and "You can post adventures and guild events." or "You can post adventures and answer guild events.")) or ""))
    U.sharingHelp.label:SetText("How sharing works " .. (U.settingsHelp == "sharing" and "-" or "+"))
    U.troubleshooting.label:SetText("Troubleshooting " .. (U.settingsHelp == "trouble" and "-" or "+"))
    U.troubleshooting:ClearAllPoints(); at(U.troubleshooting, 244, U.settingsHelp == "sharing" and -494 or -390)
    U.connectionHelp:SetShown(U.settingsHelp == "sharing")
    for _, widget in ipairs({U.permissions,U.syncToggle,U.syncRefresh,U.reportHint,U.buildInfo}) do widget:SetShown(U.settingsHelp == "trouble") end
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
    U.buildInfo:SetText(U.ReportDetails())
    U.buildInfo:SetCursorPosition(0) -- show the start of the line, not its end
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
-- finding RP tonight. It is an ordinary adventure underneath, so every version of the addon sees it.
function U.OpenHereNow()
    local s = U.nowSheet
    if not s then
        s = U.Paper(U.frame, 520, 316)
        s:SetPoint("CENTER", 91, 0); s:SetFrameLevel(U.frame:GetFrameLevel() + 40); s:EnableMouse(true)
        at(U.Text(s, "Quick post", 16, C.brown, nil, "caps"), 24, -20)
        at(U.Text(s, "For an adventure starting now.", 14, C.paperMuted), 24, -42)
        s.kinds = {}
        for i, kind in ipairs({ 3, 2, 1 }) do
            local b = at(U.Button(s, E.categories[kind], 140, function() s.kind = kind; U.RefreshHereNow() end, "flat"), 24 + (i - 1) * 148, -68)
            b:SetHeight(28); b.kind = kind; s.kinds[i] = b
        end
        s.where = U.Field(s, "Where are you?", 24, -106, 472, 30, 100)
        s.what = U.Field(s, "What is happening?", 24, -164, 472, 30, 100)
        at(U.Text(s, "Stays on the board for", 14, C.paperMuted), 24, -226)
        s.stays = {}
        for i, hours in ipairs({ 1, 2 }) do
            local b = at(U.Button(s, hours == 1 and "1 hour" or "2 hours", 96, function() s.hours = hours; U.RefreshHereNow() end, "flat"), 200 + (i - 1) * 104, -221)
            b:SetHeight(26); b.hours = hours; s.stays[i] = b
        end
        s.post = at(U.Button(s, "Post", 150, function() U.PostHereNow() end, "seal"), 24, -262)
        at(U.Button(s, "Cancel", 120, function() s:Hide() end), 184, -262)
        s.where:SetScript("OnTabPressed", function() s.what:SetFocus() end)
        s.where:SetScript("OnEnterPressed", function() s.what:SetFocus() end)
        s.what:SetScript("OnTabPressed", function() s.where:SetFocus() end)
        U.nowSheet = s
    end
    s.kind = 3; s.hours = 2
    s.where:SetText(""); s.what:SetText("")
    U.RefreshHereNow()
    s:Show()
end
function U.RefreshHereNow()
    local s = U.nowSheet
    for _, b in ipairs(s.kinds) do U.SelectButton(b, b.kind == s.kind) end
    for _, b in ipairs(s.stays) do U.SelectButton(b, b.hours == s.hours) end
end
function U.PostHereNow()
    local s = U.nowSheet
    local where, what = E.Trim(E.Clean(s.where:GetText(), 100)), E.Trim(E.Clean(s.what:GetText(), 100))
    if where == "" then U.Status("Say where you are."); return end
    if what == "" then U.Status("Say what is happening."); return end
    -- It starts now: this minute on the realm's clock.
    local clock = E.Client.Now() + E.Client.RealmOffset()
    local draft = { route = 1, category = s.kind, hours = s.hours, title = what, location = where, body = what,
        startDays = 0, startHour = math.floor((clock % 86400) / 3600), startMinute = math.floor((clock % 3600) / 60) }
    -- Posting saves the draft it is given; the member's own unfinished draft is put back after.
    local kept = S.GetDraft()
    local result, problem = E.Sync.Post(draft)
    S.SaveDraft(kept)
    if not result then U.Status(problem or "Could not post. Check your connection."); return end
    s:Hide(); U.selected = result; U.Go("Letters"); U.Status("Posted.")
end

-- A reminder in chat, once, 15 minutes before something the member is joining or hosting. It is
-- one line in the chat window, never a pop-up, and it can be switched off in Settings.
function U.CheckReminders()
    U.UpdateLauncherBadge()
    local db = S.db
    if not db or not db.settings.reminders or not E.Sync.ReadContext() then return end
    local now, done = E.Client.Now(), db.localData.reminded
    for id, start in pairs(done) do if start < now - 86400 then done[id] = nil end end
    for _, e in ipairs(E.Sync.List()) do
        if (e.own or e.reply == "I will join") and not e.cancelled and e.start > now and e.start - now <= 900 and not done[e.id] then
            done[e.id] = e.start
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
