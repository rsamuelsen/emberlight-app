local _, E = ...
-- A context factory lets the same engine be tested with isolated client stores.
function E.NewSync(context)
local E = context
local N = { prefix = "EmberlightV1", queue = {}, partial = {}, peers = {}, limits = {}, imported = {} }
local C = E.Client
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function integer(s, low, high)
    if type(s) ~= "string" or #s > 16 or not s:match("^%d+$") then return nil end
    local n = tonumber(s); if n < low or n > high then return nil end; return n
end
local function safe(s, limit, required)
    return type(s) == "string" and #s <= limit and E.Clean(s, limit) == s and (not required or E.Trim(s) ~= "")
end
local HORIZON = E.maxHorizonDays * 86400
-- How long a supply request lives in game: open ones are accepted this long after they were
-- posted, and closed ones (with their pledges) are pruned after CLOSED_SUPPLY_DAYS.
local SUPPLY_DAYS, CLOSED_SUPPLY_DAYS = 90, 30
-- Senders tracked for the per-sender rate limit at once. When full, the one heard from longest
-- ago makes room, so a busy guild never shuts out a member who is newly online.
local MAX_SENDERS = 400
function N.Context()
    local db = E.Store.db
    if not db or db.settings.demo or db.settings.guildSync ~= true then
        if N.guild then N.Reset() end
        return nil
    end
    if C.CommsBlocked() then return nil end
    local key = C.ScopeKey()
    if key ~= N.guild then
        N.guild = key; N.queue = {}; N.partial = {}; N.peers = {}; N.limits = {}; N.lastHello = nil; N.lastSnapshot = nil; N.snapshotAt = nil; N.lastError=nil; N.retryAt=nil
    end
    if not key then return nil end
    local roster = C.Roster()
    local me = C.Canonical(C.Name())
    if not roster[me] then return nil end
    local name = C.Channel() == "PARTY" and "partyData" or "guildData"
    db[name] = db[name] or {}
    db[name][key] = db[name][key] or { entries = {}, replies = {} }
    local scope = db[name][key]
    -- Added for Supplies (0.5.0): default onto scopes created by an earlier version too.
    scope.supplies = scope.supplies or {}
    scope.contributions = scope.contributions or {}
    N.PruneSupplies(scope)
    -- Added in 0.7.2: the short line a member adds to an answer ("as the caravan guard").
    scope.lines = scope.lines or {}
    if not N.imported[key] then
        N.imported[key] = true
        N.ImportArchive(scope, key, me)
    end
    return scope, roster, me
end
-- Closed supply requests and their pledges go after CLOSED_SUPPLY_DAYS, and open ones after
-- SUPPLY_DAYS, when peers would refuse them anyway. At most once a minute.
function N.PruneSupplies(scope)
    local now = C.Now()
    N.prunedAt = N.prunedAt or setmetatable({}, { __mode = "k" })
    if N.prunedAt[scope] and now - N.prunedAt[scope] < 60 then return end
    N.prunedAt[scope] = now
    for id, p in pairs(scope.supplies) do
        local created = type(p) == "table" and tonumber(p.created) or 0
        if type(p) ~= "table" or created < now - SUPPLY_DAYS * 86400 or (p.cancelled and created < now - CLOSED_SUPPLY_DAYS * 86400) then
            scope.supplies[id] = nil; scope.contributions[id] = nil
        end
    end
    for id in pairs(scope.contributions) do if not scope.supplies[id] then scope.contributions[id] = nil end end
end
local function whole(v, low, high)
    return type(v) == "number" and v == math.floor(v) and v >= low and v <= high and v or nil
end
-- Notices downloaded by the optional Emberlight sync tool into the Emberlight_Data addon
-- (global EmberlightArchive). The file is local and untrusted, so each record gets the same
-- checks as a received message, except that it may be older than a live one. Imported records are
-- only shown here: Snapshot() resends a player's own records only, so nobody else's is relayed.
-- A newer revision from a live message always wins, and a withdrawal is never undone.
function N.ImportArchive(scope, key, me)
    local archive = EmberlightArchive
    if type(archive) ~= "table" or archive.format ~= 1 or type(archive.scopes) ~= "table" then return 0 end
    local list = type(archive.scopes[key]) == "table" and archive.scopes[key].notices
    if type(list) ~= "table" then return 0 end
    local now, imported, seen = C.Now(), 0, 0
    for id, n in pairs(list) do
        seen = seen + 1
        if seen > 400 then break end
        if type(id) == "string" and type(n) == "table" and N.ImportNotice(scope, id, n, me, now) then imported = imported + 1 end
    end
    -- Notices an officer removed (in game or on the website), as the server last knew them.
    local removed = archive.scopes[key].removed
    if type(removed) == "table" then
        seen = 0
        for id, flag in pairs(removed) do
            seen = seen + 1
            if seen > 400 then break end
            if flag == true and type(id) == "string" and N.ImportRemoval(scope, id, now) then imported = imported + 1 end
        end
    end
    local replies = archive.scopes[key].replies
    if type(replies) == "table" then
        seen = 0
        for id, answers in pairs(replies) do
            if type(id) == "string" and type(answers) == "table" then
                for who, r in pairs(answers) do
                    seen = seen + 1
                    if seen > 4000 then return imported end
                    if type(who) == "string" and type(r) == "table" and N.ImportReply(scope, id, who, r, now) then imported = imported + 1 end
                end
            end
        end
    end
    return imported
end
-- The server's word that an officer removed a notice: the same outcome as a received M record.
-- The server checked the officer's rights; the archive is local and written by the sync tool, so
-- nothing is relayed from it (the officer's own M record still travels from their client).
function N.ImportRemoval(scope, id, now)
    local entry = scope.entries[id]
    if not entry or entry.cancelled or entry.expires <= now then return false end
    entry.cancelled = true; entry.moderated = true
    return true
end
-- The same checks as a received R record: an open notice that is not the respondent's own, one of
-- the two answers, and a newer revision than the one already known. A line may come with it.
function N.ImportReply(scope, id, who, r, now)
    local entry = scope.entries[id]
    if #who > 120 or not who:find("-", 1, true) or who:find("[%s|:]") then return false end
    who = C.Local(who)
    if not entry or entry.cancelled or entry.expires <= now or who == entry.owner then return false end
    local rev = whole(r.revision, 1, 999999999999999)
    if not rev or (r.response ~= "I will join" and r.response ~= "Unable to attend") then return false end
    scope.replies[id] = scope.replies[id] or {}
    local answers = scope.replies[id]
    if not answers[who] and count(answers) >= 100 then return false end
    local changed = false
    if not answers[who] or answers[who].revision < rev then
        answers[who] = { revision = rev, response = r.response }
        changed = true
    end
    -- The line given with the answer (on the website or in game), with its own revision, under the
    -- same checks as a received L record. A bad line is ignored; the answer still counts.
    local lineRev = whole(r.lineRevision, 1, 999999999999999)
    if lineRev and safe(r.line, 80) then
        scope.lines = scope.lines or {}
        scope.lines[id] = scope.lines[id] or {}
        local lines = scope.lines[id]
        if (not lines[who] or lines[who].revision < lineRev) and (lines[who] or count(lines) < 100) then
            lines[who] = { revision = lineRev, text = r.line }
            changed = true
        end
    end
    return changed
end
function N.ImportNotice(scope, id, n, me, now)
    local owner = n.owner
    if type(owner) ~= "string" or #owner > 120 or #id > 150 or id:sub(1, #owner + 1) ~= owner .. ":" or not id:sub(#owner + 2):match("^%d+$") then return false end
    local rev = whole(n.revision, 1, 999999999999999)
    local created = whole(n.created, 1, now + 60)
    local expires = whole(n.expires, now + 1, now + HORIZON + 14460)
    local category = whole(n.category, 1, 4)
    if not rev or not created or not expires or not category or expires <= created or expires - created > HORIZON + 14400 + 120 then return false end
    local start = whole(n.start, created - 172800, created + HORIZON + 60)
    if not start or type(n.cancelled) ~= "boolean" then return false end
    if not safe(n.title, 100, true) or not safe(n.location, 100) or not safe(n.body, 1600, true) or not safe(n.author, 120, true) then return false end
    -- The server's copy names the owner's true realm; this client may know them by another.
    owner = C.Local(owner)
    local old = scope.entries[id]
    if old and (old.owner ~= owner or old.created ~= created or old.expires ~= expires or old.categoryIndex ~= category or old.start ~= start) then return false end
    if old and (old.revision >= rev or old.cancelled) then return false end
    if not old then
        local own = 0
        for _, v in pairs(scope.entries) do if v.owner == owner then own = own + 1 end end
        if own >= 10 or count(scope.entries) >= 200 then return false end
    end
    local entry = old or {}
    entry.id = id; entry.owner = owner; entry.author = n.author; entry.revision = rev; entry.created = created; entry.expires = expires
    entry.start = start; entry.categoryIndex = category; entry.category = E.categories[category]; entry.cancelled = n.cancelled
    entry.title = n.title; entry.location = n.location; entry.body = n.body; entry.own = owner == me; entry.live = true
    scope.entries[id] = entry
    return true
end
function N.Ready()
    return N.registered and N.Context() ~= nil and not C.CommsBlocked()
end
function N.Reset()
    N.guild = nil; N.queue = {}; N.partial = {}; N.peers = {}; N.lastHello = nil; N.lastSnapshot = nil; N.snapshotAt = nil; N.lastError=nil; N.retryAt=nil
end
function N.Changed()
    if E.UI and E.UI.UpdateLauncherBadge then E.UI.UpdateLauncherBadge() end
    if E.UI and E.UI.frame and E.UI.frame:IsShown() then
        if E.UI.tab == "Noticeboard" or E.UI.tab == "Letters" or E.UI.tab == "Mine" then E.UI.RefreshReader() end
        if E.UI.tab == "Home" then E.UI.RefreshHome() end
        if E.UI.tab == "Supplies" then E.UI.RefreshSupplies() end
        if E.UI.tab == "Settings" then E.UI.RefreshSettings() end
        if E.UI.connection then E.UI.connection:SetText(N.Status()) end
    end
end
function N.Status()
    local db = E.Store.db
    if db.settings.demo then return "Sharing is off." end
    if not db.settings.guildSync then return "Sharing is off. Enable it in Settings." end
    if C.CommsBlocked() then return "Sharing is paused by WoW." end
    if not N.Context() then return C.Channel()=="PARTY" and "Party / join a manually invited group of 2-5 players." or (IsInGuild and not IsInGuild() and "Join the guild to see its boards." or "Waiting for the guild roster.") end
    if not N.registered then return "Addon channel unavailable. Reload after other addons finish loading." end
    if N.lastError then return N.lastError .. ". Refresh notices to retry." end
    local online = 0
    for actor, seen in pairs(N.peers) do if seen > C.Now() - 300 then online = online + 1 else N.peers[actor]=nil end end
    return string.format("%s / %d recent contact(s) / %d queued", C.Channel()=="PARTY" and "Party" or "Guild", online, #N.queue)
end
function N.Queue(fields, key)
    if not N.Ready() then return nil, "Sharing is not ready. Check Settings." end
    if fields[2] ~= N.guild then return nil, "Your group changed. Try again after the roster updates." end
    for _, q in ipairs(N.queue) do if q.key == key then return true end end
    if #N.queue >= 64 then return nil, "Too many messages are queued. Try again shortly." end
    local wire = E.Protocol.Encode(fields)
    if not wire then return nil, "This notice is too large to share." end
    N.packetID = (N.packetID or 0) + 1
    local official = (fields[1] == "N" and tonumber(fields[7]) == 4) or fields[1] == "S"
    N.queue[#N.queue+1] = { key=key, wire=wire, id=tostring(N.packetID), part=1, since=C.Now(), guild=N.guild, official=official }
    return true
end
function N.Fields(entry)
    return { "N", N.guild, entry.id, entry.revision, entry.created, entry.expires,
        entry.categoryIndex, entry.cancelled and "1" or "0", entry.title, entry.location, entry.body, entry.start }
end
-- Day/hour/minute are chosen on the realm's clock (server time), which every member shares
-- whatever their own time zone; see Client.DayStart.
function N.StartTime(days, hour, minute)
    return C.DayStart() + (days or 0) * 86400 + (hour or 0) * 3600 + (minute or 0) * 60
end
-- A new revision, always above `after` when given: the revision the record already has. A copy
-- downloaded from the server (an answer or edit made on the website, or on another computer) can
-- be ahead of this computer's own count, and a change made here must still win over it.
function N.Revision(after)
    local db = E.Store.db
    db.localData.syncSequence = math.max((db.localData.syncSequence or 0) + 1, C.Now() * 1000, (tonumber(after) or 0) + 1)
    return db.localData.syncSequence
end
function N.List()
    local data, roster, me = N.Context()
    local list = {}
    if not data then return list end
    for id, entry in pairs(data.entries) do
        if entry.expires <= C.Now() then data.entries[id] = nil; data.replies[id] = nil; data.lines[id] = nil
        elseif roster[entry.owner] and (entry.categoryIndex ~= 4 or roster[entry.owner].officer) then
            entry.own = entry.owner == me
            local reply = (data.replies[id] or {})[me]
            entry.reply = reply and reply.response or nil
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a,b) if a.created == b.created then return a.id < b.id end; return a.created > b.created end)
    return list
end
function N.Post(draft)
    local data, roster, me = N.Context()
    if not N.Ready() or not data then return nil, "Turn sharing on in Settings, and be in the guild." end
    if draft.route ~= 1 then return nil, "Choose the noticeboard to post a notice." end
    local ok, problem = E.Store.Validate(draft); if not ok then return nil, problem end
    if draft.category == 4 and not roster[me].officer then return nil, C.Channel()=="PARTY" and "Only the party leader can post official events." or "Official guild events require the guild leader or Flame Keeper rank." end
    N.List()
    local own = 0; for _, entry in pairs(data.entries) do if entry.owner == me then own = own + 1 end end
    if own >= 10 or count(data.entries) >= 200 then return nil, "The board is full. Wait for older notices to expire." end
    local d = E.Store.SaveDraft(draft)
    local start = N.StartTime(d.startDays, d.startHour, d.startMinute)
    local expires = start + d.hours * 3600
    if expires <= C.Now() then return nil, "Choose a time that hasn't already passed." end
    -- Every client refuses a notice that reaches further ahead than this, so say so here.
    if start > C.Now() + HORIZON or expires > C.Now() + HORIZON + 14400 then
        return nil, "That reaches too far ahead. A notice must start and leave the board within three weeks."
    end
    local revision = N.Revision()
    local entry = { id=me .. ":" .. string.format("%.0f",revision), owner=me, author=C.Author(roster, me),
        revision=revision, created=C.Now(), expires=expires, start=start, title=d.title,
        location=d.location, body=d.body, category=E.categories[d.category], categoryIndex=d.category, own=true, live=true }
    local queued, why = N.Queue(N.Fields(entry), "N:" .. entry.id .. ":" .. revision)
    if not queued then return nil, why end
    data.entries[entry.id] = entry
    return entry
end
function N.Cancel(entry)
    local data, roster, me = N.Context()
    if not N.Ready() or not data or data.entries[entry.id] ~= entry or entry.owner ~= me or entry.cancelled or entry.expires <= C.Now() then return false end
    if entry.categoryIndex == 4 and not roster[me].officer then return false end
    local changed = E.Copy(entry); changed.cancelled = true; changed.revision = N.Revision(entry.revision)
    if not N.Queue(N.Fields(changed), "N:" .. changed.id .. ":" .. changed.revision) then return false end
    entry.cancelled = true; entry.revision = changed.revision; return true
end
-- Editing keeps id/created/expires/category fixed, matching what Apply() accepts as an update.
function N.Edit(entry, draft)
    local data, roster, me = N.Context()
    if not N.Ready() or not data or data.entries[entry.id] ~= entry or entry.owner ~= me or entry.cancelled or entry.expires <= C.Now() then return nil, "You can only edit your own open notices." end
    local hours = math.max(1, math.ceil((entry.expires - entry.created) / 3600))
    local ok, problem = E.Store.Validate({ title = draft.title, body = draft.body, route = 1 })
    if not ok then return nil, problem end
    local changed = E.Copy(entry)
    changed.title = E.Clean(draft.title, 100); changed.location = E.Clean(draft.location, 100); changed.body = E.Clean(draft.body, 1600)
    changed.revision = N.Revision(entry.revision)
    if not N.Queue(N.Fields(changed), "N:" .. changed.id .. ":" .. changed.revision) then return nil, "Could not queue the update." end
    entry.title, entry.location, entry.body, entry.revision = changed.title, changed.location, changed.body, changed.revision
    return entry
end
-- Any current officer/leader can remove another member's notice. Kept distinct from Cancel: the
-- author's identity in the record never changes, only a visible moderated/cancelled flag.
function N.Moderate(entry)
    local data, roster, me = N.Context()
    if not N.Ready() or not data or data.entries[entry.id] ~= entry or entry.owner == me or entry.cancelled or entry.expires <= C.Now() then return false end
    if not roster[me] or not roster[me].officer then return false end
    local revision = N.Revision()
    if not N.Queue({ "M", N.guild, entry.id, tostring(revision) }, "M:" .. entry.id .. ":" .. revision) then return false end
    entry.cancelled = true; entry.moderated = true; entry.moderator = me; entry.moderatedBy = roster[me].name; entry.modRevision = revision
    return true
end
-- Proof that a website character claim is really this player's: the website shows a code, the
-- member types `/emberlight verify CODE` on that character, and every guild member online sees it
-- arrive from that character (WoW names the sender). Their sync tool reports what they saw; the
-- claimant's own client never records its own code, so the proof always comes from someone else.
N.PROOF_CODE = "^[A-Z2-9]+$"
function N.Verify(code)
    code = type(code) == "string" and E.Trim(code):upper() or ""
    if #code ~= 8 or not code:match(N.PROOF_CODE) then return nil, "Type the 8-character code the website shows, like /emberlight verify ABCD2345." end
    if not N.Ready() then return nil, "Sharing is not ready. Check Settings, and be in your guild." end
    local ok, problem = N.Queue({ "V", N.guild, code }, "V:" .. code)
    if not ok then return nil, problem end
    return true
end
function N.Pending(entry)
    local prefix = "N:" .. entry.id .. ":" .. entry.revision
    for _, q in ipairs(N.queue) do if q.key == prefix then return true end end
    return false
end
function N.Reply(entry, response, line)
    local data, roster, me = N.Context()
    if not N.Ready() or not data or data.entries[entry.id] ~= entry or entry.owner == me or entry.cancelled or entry.expires <= C.Now() then return false end
    if not roster[entry.owner] or (entry.categoryIndex == 4 and not roster[entry.owner].officer) then return false end
    if response ~= "I will join" and response ~= "Unable to attend" then return false end
    local revision = N.Revision(((data.replies[entry.id] or {})[me] or {}).revision)
    if not N.Queue({"R",N.guild,entry.id,revision,response}, "R:" .. entry.id .. ":" .. revision) then return false end
    data.replies[entry.id] = data.replies[entry.id] or {}
    data.replies[entry.id][me] = {revision=revision,response=response}
    entry.reply = response
    -- The line travels as its own "L" record, so an addon from before 0.7.2 still receives the
    -- answer and only leaves the line out. Saying "Unable to attend" clears a line already sent.
    local previous = (data.lines[entry.id] or {})[me]
    local text = response == "I will join" and E.Trim(E.Clean(line, 80)) or ""
    if text ~= "" or previous then N.Line(entry, text) end
    return true
end
function N.MyLine(entry)
    local data, _, me = N.Context()
    local line = data and (data.lines[entry.id] or {})[me]
    return line and line.text or ""
end
function N.Line(entry, text)
    local data, _, me = N.Context()
    if not data then return false end
    local revision = N.Revision(((data.lines[entry.id] or {})[me] or {}).revision)
    if not N.Queue({"L",N.guild,entry.id,revision,text}, "L:" .. entry.id .. ":" .. revision) then return false end
    data.lines[entry.id] = data.lines[entry.id] or {}
    data.lines[entry.id][me] = {revision=revision,text=text}
    return true
end
-- Who answered a notice, by the names the roster knows: those joining, then those who cannot.
-- The member's own answer is listed first, as "You". Names are shown without their realm.
function N.Answers(entry)
    local data, roster, me = N.Context()
    local joining, unable = {}, {}
    if not data then return joining, unable end
    local mine
    local lines = data.lines[entry.id] or {}
    local function named(actor, name)
        local line = lines[actor] and lines[actor].text or ""
        return line ~= "" and (name .. " (" .. line .. ")") or name
    end
    for actor, reply in pairs(data.replies[entry.id] or {}) do
        if roster[actor] then
            if actor == me then mine = reply.response == "I will join" and joining or unable
            elseif reply.response == "I will join" then joining[#joining + 1] = named(actor, E.Clean(roster[actor].name, 120):match("^[^-]+") or "")
            else unable[#unable + 1] = E.Clean(roster[actor].name, 120):match("^[^-]+") or "" end
        end
    end
    table.sort(joining); table.sort(unable)
    if mine then table.insert(mine, 1, mine == joining and named(me, "You") or "You") end
    return joining, unable
end
function N.Responses(entry)
    local data, roster = N.Context()
    if not data then return "" end
    local lines = {}
    for actor, reply in pairs(data.replies[entry.id] or {}) do
        if roster[actor] then lines[#lines+1] = E.Clean(roster[actor].name,120) .. ": " .. reply.response end
    end
    table.sort(lines)
    return #lines > 0 and "\n\nReplies received\n" .. table.concat(lines, "\n") or ""
end
-- Supplies: officer-created requests, any member pledges/reports a delivery, and only the
-- request's own organiser can confirm a receipt. Pledged/delivered (contributor-owned) and
-- confirmed (organiser-owned) are tracked separately so the two writers never race each other;
-- there is no expiry, only an explicit close by the organiser, matching the archived local
-- prototype's pledge -> handover -> confirmed-receipt flow (archive/local-prototype/Core/Supplies.lua).
function N.SupplyFields(project)
    return { "S", N.guild, project.id, project.revision, project.created,
        project.cancelled and "1" or "0", project.item, project.goal, project.title, project.location, project.body }
end
function N.SupplyList()
    local data, roster, me = N.Context()
    local list = {}
    if not data then return list end
    for id, project in pairs(data.supplies) do
        if roster[project.owner] and roster[project.owner].officer then
            project.own = project.owner == me
            list[#list + 1] = project
        end
    end
    table.sort(list, function(a, b) if a.created == b.created then return a.id < b.id end; return a.created > b.created end)
    return list
end
function N.Contributions(project)
    local data = N.Context()
    if not data then return {} end
    return data.contributions[project.id] or {}
end
function N.Totals(project)
    local pledged, delivered, confirmed = 0, 0, 0
    for _, c in pairs(N.Contributions(project)) do
        pledged = pledged + (c.pledged or 0); delivered = delivered + (c.delivered or 0); confirmed = confirmed + (c.confirmed or 0)
    end
    return pledged, delivered, confirmed
end
function N.PostSupply(draft)
    local data, roster, me = N.Context()
    if not N.Ready() or not data then return nil, "Enable sharing in Settings and join the selected party or guild." end
    if not roster[me].officer then return nil, C.Channel()=="PARTY" and "Only the party leader can post a supply request." or "Supply requests require the guild leader or Flame Keeper rank." end
    local title, item, body, location = E.Trim(E.Clean(draft.title,100)), E.Trim(E.Clean(draft.item,100)), E.Trim(E.Clean(draft.body,800)), E.Clean(draft.location,100)
    if title == "" or item == "" or body == "" then return nil, "Complete the subject, material and message." end
    local goal = tonumber(draft.goal)
    if not goal or goal ~= math.floor(goal) or goal < 1 or goal > 1000000 then return nil, "Enter a whole quantity between 1 and 1,000,000." end
    local own, active = 0, 0
    for _, v in pairs(data.supplies) do
        if not v.cancelled then active = active + 1; if v.owner == me then own = own + 1 end end
    end
    if own >= 10 or active >= 50 then return nil, "The supply ledger is full. Close older requests first." end
    local revision = N.Revision()
    local project = { id=me..":"..string.format("%.0f",revision), owner=me, author=C.Author(roster, me), revision=revision,
        created=C.Now(), item=item, goal=goal, title=title, location=location, body=body, own=true }
    local queued, why = N.Queue(N.SupplyFields(project), "S:" .. project.id .. ":" .. revision)
    if not queued then return nil, why end
    data.supplies[project.id] = project
    return project
end
function N.CloseSupply(project)
    local data, roster, me = N.Context()
    if not N.Ready() or not data or data.supplies[project.id] ~= project or project.owner ~= me or project.cancelled then return false end
    local changed = E.Copy(project); changed.cancelled = true; changed.revision = N.Revision()
    if not N.Queue(N.SupplyFields(changed), "S:" .. changed.id .. ":" .. changed.revision) then return false end
    project.cancelled = true; project.revision = changed.revision; return true
end
function N.Pledge(project, pledged, delivered)
    local data, roster, me = N.Context()
    if not N.Ready() or not data or data.supplies[project.id] ~= project or project.cancelled then return nil, "This request is not open." end
    pledged, delivered = tonumber(pledged), tonumber(delivered)
    if not pledged or pledged ~= math.floor(pledged) or pledged < 0 or pledged > 1000000 then return nil, "Enter a whole pledged quantity between 0 and 1,000,000." end
    if not delivered or delivered ~= math.floor(delivered) or delivered < 0 or delivered > 1000000 then return nil, "Enter a whole delivered quantity between 0 and 1,000,000." end
    data.contributions[project.id] = data.contributions[project.id] or {}
    local contributors = data.contributions[project.id]
    if not contributors[me] and count(contributors) >= 100 then return nil, "This request has reached its contributor limit." end
    local revision = N.Revision()
    if not N.Queue({"P",N.guild,project.id,revision,pledged,delivered}, "P:" .. project.id .. ":" .. revision) then return nil, "Could not queue the pledge." end
    local c = contributors[me] or { name = roster[me].name }
    c.name = roster[me].name; c.pledged = pledged; c.delivered = delivered; c.deliveredAt = C.Now(); c.pledgeRevision = revision
    contributors[me] = c
    return true
end
function N.Confirm(project, contributor, confirmed)
    local data, roster, me = N.Context()
    if not N.Ready() or not data or data.supplies[project.id] ~= project or project.owner ~= me then return nil, "Only the request's organiser can confirm receipt." end
    confirmed = tonumber(confirmed)
    if not confirmed or confirmed ~= math.floor(confirmed) or confirmed < 0 or confirmed > 1000000 then return nil, "Enter a whole confirmed quantity between 0 and 1,000,000." end
    local contributors = data.contributions[project.id]
    local c = contributors and contributors[contributor]
    if not c then return nil, "This contributor has not pledged anything yet." end
    local revision = N.Revision()
    if not N.Queue({"C",N.guild,project.id,contributor,revision,confirmed}, "C:" .. project.id .. ":" .. contributor .. ":" .. revision) then return nil, "Could not queue the confirmation." end
    c.confirmed = confirmed; c.confirmedAt = C.Now(); c.confirmedBy = roster[me].name; c.confirmer = me; c.confirmRevision = revision
    return true
end
function N.Snapshot()
    if N.lastSnapshot and C.Now() - N.lastSnapshot < 30 then return end
    local data, roster, me = N.Context(); if not data or not N.Ready() then return end
    N.lastSnapshot = C.Now()
    for _, entry in ipairs(N.List()) do
        -- No relaying somebody else's record: only the authenticated author resends it.
        if entry.owner == me then N.Queue(N.Fields(entry), "N:" .. entry.id .. ":" .. entry.revision) end
        local reply = (data.replies[entry.id] or {})[me]
        if reply and not entry.cancelled then N.Queue({"R",N.guild,entry.id,reply.revision,reply.response}, "R:" .. entry.id .. ":" .. reply.revision) end
        local line = (data.lines[entry.id] or {})[me]
        if line and not entry.cancelled then N.Queue({"L",N.guild,entry.id,line.revision,line.text}, "L:" .. entry.id .. ":" .. line.revision) end
        if entry.moderated and entry.moderator == me then N.Queue({"M",N.guild,entry.id,tostring(entry.modRevision)}, "M:" .. entry.id .. ":" .. entry.modRevision) end
    end
    for _, project in ipairs(N.SupplyList()) do
        if project.owner == me then N.Queue(N.SupplyFields(project), "S:" .. project.id .. ":" .. project.revision) end
        local mine = (data.contributions[project.id] or {})[me]
        if mine and mine.pledgeRevision then N.Queue({"P",N.guild,project.id,mine.pledgeRevision,mine.pledged,mine.delivered}, "P:" .. project.id .. ":" .. mine.pledgeRevision) end
        for contributor, c in pairs(data.contributions[project.id] or {}) do
            if c.confirmer == me then N.Queue({"C",N.guild,project.id,contributor,c.confirmRevision,c.confirmed}, "C:" .. project.id .. ":" .. contributor .. ":" .. c.confirmRevision) end
        end
    end
end
function N.Refresh()
    if not N.Ready() then return false end
    if N.lastHello and C.Now() - N.lastHello < 30 then return false end
    if not N.Queue({"H", N.guild}, "H") then return false end
    C.RequestRoster()
    N.lastHello = C.Now(); N.Snapshot(); return true
end
-- Whether a notice or supply id ("<owner>:<number>") was written by this sender. The owner part is
-- the author's own identity, with their true realm; WoW's sender may carry this client's realm
-- instead (C.Local), so the two are compared as this client keys them.
function N.Owns(sender, id)
    local owner = type(id) == "string" and #id <= 150 and id:match("^(.+):%d+$")
    return owner and C.Local(owner) == sender or false
end
function N.Apply(fields, sender)
    local data, roster, me = N.Context()
    if not data or not roster[sender] or fields[2] ~= N.guild then return false end
    local kind = fields[1]
    if kind == "H" and #fields == 2 then
        -- Answer after a short random wait, so a guild's clients do not all answer at once, and
        -- count it as a hello of our own: everyone online hears the answers, so this client need
        -- not ask again for a while. Traffic then grows with the number online, not its square.
        N.lastHello = C.Now()
        if not N.snapshotAt then N.snapshotAt = C.Now() + math.random(2, 15) end
        return true
    end
    if kind == "N" and #fields == 12 then
        local id, rev = fields[3], integer(fields[4],1,999999999999999)
        -- Any notice still open is accepted, however long ago it was posted: its author resends it
        -- (and its edits and withdrawal, which keep the original created time) for its whole life.
        -- Created is bounded by the longest life a notice can have, and start by created, the same
        -- rules as the archive import and the server.
        local created = integer(fields[5], C.Now()-HORIZON-14520, C.Now()+60)
        local expires = integer(fields[6], C.Now()+1, C.Now()+HORIZON+14460)
        local category = integer(fields[7],1,4)
        local start = integer(fields[12], C.Now()-HORIZON-14520-172800, C.Now()+HORIZON+60)
        if not rev or not created or not expires or expires <= created or expires-created > HORIZON+14400+120 or not category or not start then return false end
        if start < created-172800 or start > created+HORIZON+60 then return false end
        if not N.Owns(sender, id) then return false end
        if fields[8] ~= "0" and fields[8] ~= "1" then return false end
        if not safe(fields[9],100,true) or not safe(fields[10],100) or not safe(fields[11],1600,true) then return false end
        if category == 4 and not roster[sender].officer then return false end
        local old = data.entries[id]
        if old and (old.owner ~= sender or old.revision >= rev or old.cancelled or old.created ~= created or old.expires ~= expires or old.categoryIndex ~= category or old.start ~= start) then return false end
        if not old then
            N.List()
            local own=0; for _, v in pairs(data.entries) do if v.owner == sender then own=own+1 end end
            if own >= 10 or count(data.entries) >= 200 then return false end
        end
        local entry = old or {}
        entry.id=id; entry.owner=sender; entry.author=roster[sender].name; entry.revision=rev; entry.created=created; entry.expires=expires; entry.start=start
        entry.categoryIndex=category; entry.category=E.categories[category]; entry.cancelled=fields[8]=="1"
        entry.title=fields[9]; entry.location=fields[10]; entry.body=fields[11]; entry.own=sender==me; entry.live=true
        data.entries[id]=entry; return true
    elseif kind == "R" and #fields == 5 then
        local entry=data.entries[fields[3]]; local rev=integer(fields[4],1,999999999999999)
        if not entry or not rev or entry.owner == sender or entry.cancelled or entry.expires <= C.Now() then return false end
        if not roster[entry.owner] or (entry.categoryIndex==4 and not roster[entry.owner].officer) then return false end
        if fields[5] ~= "I will join" and fields[5] ~= "Unable to attend" then return false end
        data.replies[entry.id]=data.replies[entry.id] or {}
        local replies=data.replies[entry.id]
        if replies[sender] and replies[sender].revision >= rev then return false end
        if not replies[sender] and count(replies) >= 100 then return false end
        replies[sender]={revision=rev,response=fields[5]}; return true
    elseif kind == "L" and #fields == 5 then
        -- A member's short line with their answer: theirs alone, bounded, newer revision wins.
        local entry = data.entries[fields[3]]; local rev = integer(fields[4], 1, 999999999999999)
        if not entry or not rev or entry.owner == sender or entry.cancelled or entry.expires <= C.Now() then return false end
        if not safe(fields[5], 80) then return false end
        data.lines[entry.id] = data.lines[entry.id] or {}
        local lines = data.lines[entry.id]
        if lines[sender] and lines[sender].revision >= rev then return false end
        if not lines[sender] and count(lines) >= 100 then return false end
        lines[sender] = {revision=rev,text=fields[5]}; return true
    elseif kind == "V" and #fields == 3 then
        local code = fields[3]
        if #code ~= 8 or not code:match(N.PROOF_CODE) then return false end
        local proofs = E.Store.db.localData.proofs
        local now = C.Now()
        for k, p in pairs(proofs) do if type(p) ~= "table" or type(p.at) ~= "number" or p.at < now - 7 * 86400 then proofs[k] = nil end end
        local key = sender .. "|" .. code
        if not proofs[key] and count(proofs) >= 50 then return false end
        proofs[key] = { character = sender, code = code, at = now }
        return true
    elseif kind == "M" and #fields == 4 then
        local entry = data.entries[fields[3]]; local rev = integer(fields[4], 1, 999999999999999)
        if not entry or not rev or entry.owner == sender or entry.cancelled or entry.expires <= C.Now() then return false end
        if not roster[sender] or not roster[sender].officer then return false end
        entry.cancelled = true; entry.moderated = true; entry.moderator = sender; entry.moderatedBy = roster[sender].name; entry.modRevision = rev
        return true
    elseif kind == "S" and #fields == 11 then
        local id, rev = fields[3], integer(fields[4], 1, 999999999999999)
        -- A supply request has no end time: it is accepted for SUPPLY_DAYS after it was posted, and
        -- older ones are pruned (N.PruneSupplies), so late joiners still get it and nothing grows forever.
        local created = integer(fields[5], C.Now()-SUPPLY_DAYS*86400, C.Now()+60)
        local goal = integer(fields[8], 1, 1000000)
        if not rev or not created or not goal then return false end
        if not N.Owns(sender, id) then return false end
        if fields[6] ~= "0" and fields[6] ~= "1" then return false end
        if not safe(fields[9],100,true) or not safe(fields[10],100) or not safe(fields[7],100,true) or not safe(fields[11],800,true) then return false end
        if not roster[sender].officer then return false end
        local old = data.supplies[id]
        if old and (old.owner ~= sender or old.revision >= rev or old.cancelled or old.created ~= created or old.item ~= fields[7] or old.goal ~= goal) then return false end
        if not old then
            local own, active = 0, 0
            for _, v in pairs(data.supplies) do
                if not v.cancelled then active = active + 1; if v.owner == sender then own = own + 1 end end
            end
            if own >= 10 or active >= 50 then return false end
        end
        local project = old or {}
        project.id=id; project.owner=sender; project.author=roster[sender].name; project.revision=rev; project.created=created
        project.cancelled=fields[6]=="1"; project.item=fields[7]; project.goal=goal; project.title=fields[9]; project.location=fields[10]; project.body=fields[11]
        project.own=sender==me
        data.supplies[id]=project; return true
    elseif kind == "P" and #fields == 6 then
        local project = data.supplies[fields[3]]; local rev = integer(fields[4], 1, 999999999999999)
        local pledged = integer(fields[5], 0, 1000000)
        local delivered = integer(fields[6], 0, 1000000)
        if not project or not rev or not pledged or not delivered or project.cancelled then return false end
        data.contributions[project.id] = data.contributions[project.id] or {}
        local contributors = data.contributions[project.id]
        local c = contributors[sender]
        if c and c.pledgeRevision and c.pledgeRevision >= rev then return false end
        if not c and count(contributors) >= 100 then return false end
        c = c or { name = roster[sender].name }
        c.name = roster[sender].name; c.pledged = pledged; c.delivered = delivered; c.deliveredAt = C.Now(); c.pledgeRevision = rev
        contributors[sender] = c
        return true
    elseif kind == "C" and #fields == 6 then
        local project = data.supplies[fields[3]]; local contributor = C.Local(fields[4]); local rev = integer(fields[5], 1, 999999999999999)
        local confirmed = integer(fields[6], 0, 1000000)
        if not project or not rev or not confirmed or project.owner ~= sender then return false end
        local contributors = data.contributions[project.id]
        local c = contributors and contributors[contributor]
        if not c then return false end
        if c.confirmRevision and c.confirmRevision >= rev then return false end
        c.confirmed = confirmed; c.confirmedAt = C.Now(); c.confirmedBy = roster[sender].name; c.confirmer = sender; c.confirmRevision = rev
        return true
    end
    return false
end
function N.Receive(prefix, packet, channel, sender)
    if prefix ~= N.prefix or channel ~= C.Channel() or C.CommsBlocked() then return end
    if issecretvalue and (issecretvalue(packet) or issecretvalue(sender)) then return end
    local data, roster, me=N.Context(); sender=C.Canonical(sender)
    if not data or not sender or sender==me or not roster[sender] or type(packet)~="string" or #packet>230 then return end
    local now=C.Now()
    for actor,p in pairs(N.partial) do if p.time < now-45 then N.partial[actor]=nil end end
    for actor,l in pairs(N.limits) do if l.time < now-60 then N.limits[actor]=nil end end
    local limit=N.limits[sender]
    if not limit then
        if count(N.limits)>=MAX_SENDERS then
            local oldest
            for actor,l in pairs(N.limits) do if not oldest or l.time < N.limits[oldest].time then oldest=actor end end
            N.limits[oldest]=nil
        end
        limit={time=now,n=0}; N.limits[sender]=limit
    end
    limit.n=limit.n+1; if limit.n>180 then return end
    local id,part,total,chunk=packet:match("^1:(%d+):(%d+):(%d+):([0-9a-f]+)$")
    part=integer(part,1,27); total=integer(total,1,27)
    if not id or #id>12 or not part or not total or part>total or #chunk>180 then return end
    local p=N.partial[sender]
    if not p or p.id~=id then
        if not p and count(N.partial)>=64 then return end
        p={id=id,total=total,time=now,chunks={}}; N.partial[sender]=p
    end
    if p.total~=total then N.partial[sender]=nil; return end
    if p.chunks[part] and p.chunks[part]~=chunk then N.partial[sender]=nil; return end
    p.chunks[part]=chunk
    if count(p.chunks)~=total then return end
    N.partial[sender]=nil
    local fields=E.Protocol.Decode(table.concat(p.chunks))
    -- The window is refreshed on the next tick, once for however many records arrived.
    if fields and N.Apply(fields,sender) then N.peers[sender]=now; N.dirty=true end
end
function N.Tick()
    if N.dirty then N.dirty=false; N.Changed() end
    local ready = N.Ready()
    if E.UI and E.UI.connection and E.UI.frame:IsShown() then E.UI.connection:SetText(N.Status()) end
    if not ready then return end
    if not N.lastHello or C.Now()-N.lastHello >= 180 then N.Refresh() end
    if N.snapshotAt and C.Now() >= N.snapshotAt then N.snapshotAt=nil; N.Snapshot() end
    local q=N.queue[1]
    if q then
        local _, roster, me = N.Context()
        if q.guild~=N.guild or C.Now()-q.since>180 or (q.official and not roster[me].officer) then table.remove(N.queue,1)
        elseif not N.retryAt or C.Now() >= N.retryAt then
            local total=math.ceil(#q.wire/180)
            local packet="1:"..q.id..":"..q.part..":"..total..":"..q.wire:sub((q.part-1)*180+1,q.part*180)
            local sent, problem = C.SendPacket(N.prefix,packet)
            if sent then
                N.lastError=nil; N.retryAt=nil
                q.part=q.part+1
                if q.part>total then table.remove(N.queue,1) end
            else N.lastError=problem or "Message not accepted by WoW"; N.retryAt=C.Now()+5 end
        end
    end
end
function N.Start()
    N.registered=C.RegisterPrefix(N.prefix)
    C.RequestRoster()
    local frame=CreateFrame("Frame")
    for _, event in ipairs({"CHAT_MSG_ADDON","GUILD_ROSTER_UPDATE","PLAYER_GUILD_UPDATE","PLAYER_ENTERING_WORLD","GROUP_ROSTER_UPDATE","PARTY_LEADER_CHANGED"}) do frame:RegisterEvent(event) end
    frame:SetScript("OnEvent",function(_,event,...)
        if event=="CHAT_MSG_ADDON" then N.Receive(...)
        elseif event=="PLAYER_GUILD_UPDATE" or event=="PLAYER_ENTERING_WORLD" then N.Reset(); C.RequestRoster(); N.Changed()
        else C.rosterCache=nil; N.Context(); N.Changed() end
    end)
    N.timer=C_Timer.NewTicker(.4,N.Tick)
end
return N
end
E.Sync = E.NewSync(E)
function E.ActiveSync()
    return E.Sync
end
