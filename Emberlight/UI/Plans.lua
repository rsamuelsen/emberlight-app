local _, E = ...
local U, S, C = E.UI, E.Store, E.Client
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end

-- Notes, tracked invitations and previously seen words are private to a character and guild.
-- Only guildData travels through the sync tool. Keep these outside it.
local function personal()
    if not S.db then return nil end
    local name, guild = C.Name(), C.ScopeKey()
    if not name or not guild then return nil end
    local localData = S.db.localData
    localData.plans = localData.plans or {}
    local key = name .. "/" .. guild
    local p = localData.plans[key]
    if not p then p = { events = {} }; localData.plans[key] = p end
    return p
end
local function record(e, create)
    local p = personal()
    if not p or not e then return nil end
    if create and not p.events[e.id] then p.events[e.id] = { expires = e.expires } end
    return p.events[e.id]
end
local function snapshot(e)
    return { title = e.title, body = e.body, location = e.location, cancelled = e.cancelled == true }
end
function U.PlanChanges(e)
    if not e or e.own or e.reply ~= "I will join" then return nil end
    local r = record(e, true)
    if not r then return nil end
    if not r.seen then r.seen = snapshot(e); return nil end
    local old, lines = r.seen, {}
    if e.cancelled and not old.cancelled then lines[#lines+1] = "This invitation was withdrawn." end
    if old.location ~= e.location then
        local function place(v) return v and v ~= "" and E.Clean(v, 100) or "Place not told" end
        lines[#lines+1] = "Meeting place changed: " .. place(old.location) .. " → " .. place(e.location)
    end
    if old.title ~= e.title then lines[#lines+1] = "Title changed from " .. E.Clean(old.title, 100) .. "." end
    if old.body ~= e.body then lines[#lines+1] = "The invitation text has changed." end
    if #lines > 0 then return table.concat(lines, "\n") end
end
function U.AnswerPlan(e, response, line)
    if not e then return end
    local conflict
    if response == "I will join" and e.reply ~= response then
        for _, other in ipairs(E.Sync.List()) do
            if other.id ~= e.id and not other.cancelled and other.start == e.start and (other.own or other.reply == response) then
                conflict = other.title; break
            end
        end
    end
    local previous = e.reply
    if not E.Sync.Reply(e, response, line) then U.Status("Could not reply. Check your connection and the notice expiry."); return end
    local r = record(e, response == "I will join")
    if r and previous ~= response then r.seen = response == "I will join" and snapshot(e) or nil end
    if U.lineSheet then U.lineSheet:Hide(); U.lineField:ClearFocus() end
    U.Refresh()
    U.Status(conflict and ("You're going. Also at this time: " .. E.Clean(conflict, 100)) or "Reply queued.")
end

-- A single readable suffix fits the existing location field on every client. A secret
-- location clears the entire field through the ordinary draft/post paths.
local pinPattern = "%[Map (%d+): (%d+%.%d), (%d+%.%d)%]$"
function U.MeetingPoint(location)
    local map, x, y = tostring(location or ""):match(pinPattern)
    map, x, y = tonumber(map), tonumber(x), tonumber(y)
    if map and map > 0 and map <= 999999 and x <= 100 and y <= 100 then return map, x/100, y/100 end
end
function U.UseLocation(field)
    if U.fields and field == U.fields.location and U.draft.secret then return end
    local map, x, y = E.Map.Here()
    if not map then U.Status("Your map position is unavailable here."); return end
    local label = E.Trim((field:GetText():gsub(pinPattern, "")))
    if label == "" and C_Map and C_Map.GetMapInfo then
        local info = C_Map.GetMapInfo(map)
        label = info and E.Clean(info.name, 100) or ""
    end
    local pin = string.format("[Map %d: %.1f, %.1f]", map, x*100, y*100)
    local value = label == "" and pin or (label .. " " .. pin)
    if #value > 100 then U.Status("Shorten the meeting place to leave room for its map coordinates."); return end
    field:SetText(value)
    if U.fields and field == U.fields.location then U.draft.location = value; U.SaveDraft(); U.WriterLabels() end
end
local function showMeetingPoint()
    local e = U.selected
    local map, x, y = U.MeetingPoint(e and e.location)
    if not map then return end
    if C_Map and C_Map.GetMapInfo and not C_Map.GetMapInfo(map) then
        U.Status("This map is unavailable on your client."); return
    end
    local lib = U.MapLibrary()
    if not lib or not WorldMapFrame or not WorldMapFrame.SetMapID then
        U.Status("Meeting coordinates: " .. E.Clean(e.location, 100)); return
    end
    if InCombatLockdown and InCombatLockdown() then U.Status("Open the meeting map after combat."); return end
    if not U.meetingMarker then
        local marker = CreateFrame("Frame", nil, UIParent)
        marker:SetSize(28, 28)
        local icon = marker:CreateTexture(nil, "OVERLAY"); icon:SetAllPoints()
        icon:SetTexture("Interface\\AddOns\\Emberlight\\Media\\Flame.tga")
        marker:EnableMouse(true)
        marker:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:SetText(self.title); GameTooltip:Show() end)
        marker:SetScript("OnLeave", function() GameTooltip:Hide() end)
        U.meetingMarker = marker
        WorldMapFrame:HookScript("OnHide", function() lib:RemoveWorldMapIcon("EmberlightMeeting", marker); marker:Hide() end)
    end
    U.meetingMarker.title = E.Clean(e.title, 100)
    if ShowUIPanel then ShowUIPanel(WorldMapFrame) else WorldMapFrame:Show() end
    WorldMapFrame:SetMapID(map)
    lib:RemoveWorldMapIcon("EmberlightMeeting", U.meetingMarker)
    if lib:AddWorldMapIconMap("EmberlightMeeting", U.meetingMarker, map, x, y, HBD_PINS_WORLDMAP_SHOW_WORLD or 3) then
        U.frame:Hide()
    else
        U.Status("The map could not place this pin: " .. E.Clean(e.location, 100))
    end
end

local function openNotes()
    local e = U.selected
    if not e or not e.own then return end
    local saved = record(e, true)
    if not saved then return end
    local sheet = U.sceneSheet
    if not sheet then
        sheet = U.Paper(U.frame, 520, 264); sheet:SetPoint("CENTER"); sheet:EnableMouse(true)
        sheet:SetFrameLevel(U.frame:GetFrameLevel()+40)
        at(U.Text(sheet,"Private scene notes",19,U.colors.ink), 22,-16)
        sheet.field = U.Field(sheet,"Saved on this character until the invitation expires",22,-49,476,138,1200,true)
        local field = sheet.field
        local scroll = U.Scroll(field:GetParent(), 464, 120)
        at(scroll, 5, -7)
        field:ClearAllPoints(); field:SetParent(scroll); field:SetSize(431, 115)
        scroll:SetScrollChild(field)
        scroll:EnableMouse(true); scroll:SetScript("OnMouseDown", function() field:SetFocus() end)
        field:SetScript("OnCursorChanged", function(_, _, y, _, h)
            scroll:SetVerticalScroll(math.max(0, -y - scroll:GetHeight() + h + 12))
        end)
        sheet.field:SetScript("OnTextChanged", function(self, typed)
            if typed and sheet.record then sheet.record.notes = E.Clean(self:GetText(),1200) end
        end)
        at(U.Button(sheet,"Done",96,function() sheet:Hide() end),402,-219)
        U.sceneSheet = sheet
    end
    sheet.entry = e; sheet.record = saved; sheet.field:SetText(saved.notes or ""); sheet:Show(); sheet.field:SetFocus()
end

local function createTracker()
    local f = U.Panel(UIParent, 302, 91, {.04,.055,.085,.94})
    f:SetBackdropBorderColor(unpack(U.colors.gold)); f:SetClampedToScreen(true); f:SetMovable(true)
    f:SetPoint("CENTER", UIParent, "CENTER", 240, 110); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self.dragging = true; self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relative, x, y = self:GetPoint()
        S.db.settings.trackerPosition = {point, relative, x, y}
    end)
    f:SetScript("OnMouseDown", function(self) self.dragging = false end)
    f:SetScript("OnMouseUp", function(self, key)
        if self.dragging or key ~= "LeftButton" or not self.entry then return end
        if InCombatLockdown and InCombatLockdown() then return end
        if not U.frame or not U.frame:IsShown() then U.Toggle() end
        U.LeaveWriter(function() if self.entry then U.OpenEntry(self.entry) end end)
    end)
    local pos = S.db.settings.trackerPosition
    local anchors = { CENTER=true, TOP=true, BOTTOM=true, LEFT=true, RIGHT=true, TOPLEFT=true, TOPRIGHT=true, BOTTOMLEFT=true, BOTTOMRIGHT=true }
    if type(pos)=="table" and anchors[pos[1]] and anchors[pos[2]] and type(pos[3])=="number" and type(pos[4])=="number" then
        f:ClearAllPoints(); f:SetPoint(pos[1],UIParent,pos[2],pos[3],pos[4])
    end
    f.title = at(U.FitText(U.Text(f,"",16,U.colors.goldHi),236,36,true),12,-7)
    f.time = at(U.FitText(U.Text(f,"",14,U.colors.ivory),276,18,false),12,-45)
    f.place = at(U.FitText(U.Text(f,"",14,U.colors.muted),276,18,false),12,-66)
    at(U.Button(f,"X",30,function()
        local p = personal(); if p then p.tracked = nil end
        f:Hide()
        if U.selected and U.frame and U.frame:IsShown() then U.ShowEntry(U.selected) end
    end,"brass"),264,-5)
    return f
end
function U.UpdateTracker(list)
    local p = personal()
    local found
    if p and p.tracked then
        for _, e in ipairs(list or E.Sync.List()) do
            if e.id == p.tracked and e.expires > C.Now() and not e.cancelled then found = e; break end
        end
    end
    if not found then
        if U.tracker then U.tracker.entry = nil; U.tracker:Hide() end
        return
    end
    U.tracker = U.tracker or createTracker()
    local f = U.tracker
    f.entry = found; f.title:SetText(E.Clean(found.title,100))
    f.time:SetText(U.Until(found.start) .. "   /   " .. C.Clock(found.start) .. " server time")
    f.place:SetText(found.location ~= "" and E.Clean(found.location,100) or "Place not told"); f:Show()
end
function U.CreatePlanButtons()
    local function button(label, width, x, click)
        local b = at(U.Button(U.paper,label,width,click,"ink"),x,0)
        b:SetHeight(26)
        return b
    end
    U.trackPlan = button("Track",88,176,function()
        local p = personal(); if not p or not U.selected then return end
        p.tracked = p.tracked ~= U.selected.id and U.selected.id or nil
        record(U.selected,true)
        U.UpdateTracker(); U.ShowEntry(U.selected)
    end)
    U.meetingMap = button("Show on map",132,272,showMeetingPoint)
    U.planReminder = button("",175,414,function()
        local r = record(U.selected,true); if not r then return end
        local minutes = r.minutes or 15
        r.minutes = minutes == 15 and 30 or minutes == 30 and 5 or 15
        U.ShowEntry(U.selected)
    end)
    U.sceneNotes = button("Scene notes",122,600,openNotes)
    U.seenChanges = button("Mark seen",128,746,function()
        local r = record(U.selected,false)
        if r then r.seen = snapshot(U.selected); U.Refresh() end
    end)
end
function U.ShowPlanButtons(e)
    local p = personal()
    local open = e and not e.cancelled and e.expires > C.Now()
    U.trackPlan:SetShown(open and p ~= nil)
    U.trackPlan.label:SetText(e and p and p.tracked == e.id and "Untrack" or "Track")
    U.meetingMap:SetShown(open and U.MeetingPoint(e.location) ~= nil)
    U.sceneNotes:SetShown(e and e.own and p ~= nil)
    local r = record(e,false)
    U.planReminder:SetShown(open and p and (e.own or e.reply=="I will join"))
    U.planReminder:SetEnabled(S.db.settings.reminders)
    U.planReminder.label:SetText(S.db.settings.reminders and ("Remind: " .. (r and r.minutes or 15) .. " min") or "Reminders off")
    local changes = U.PlanChanges(e)
    U.seenChanges:SetShown(changes ~= nil)
    return changes
end
function U.PlanMinutes(e)
    local r = record(e,false)
    return r and (r.minutes == 5 or r.minutes == 30) and r.minutes or 15
end
function U.PrunePlans(now)
    local p = personal()
    if p then
        for id,r in pairs(p.events) do
            if r.expires < now then p.events[id] = nil; if p.tracked == id then p.tracked = nil end end
        end
    end
end
