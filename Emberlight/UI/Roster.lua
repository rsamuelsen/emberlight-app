local _, E = ...
local U, R = E.UI, E.Roster
local C = U.colors
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end

-- The officers' roster check: a page for the guild master (rank 0), Flame Keepers
-- and Officer Alts only, the same in-game authority as posting guild events. Three views: "Roster check" (everyone in
-- the guild, against the website), "Needs an invite" (members' characters not in the guild) and
-- "Addon users" (who online uses Emberlight, and which version; Core/Presence.lua). A dot before
-- each name in the guild shows who is online now: green online, grey offline.
U.labels.Roster = "Officer desk"
U.rosterView = "check"

function U.RosterAllowed()
    if E.Client.Channel() ~= "GUILD" then return false end
    local name = E.Client.Name()
    local me = name and E.Client.Roster()[E.Client.Canonical(name)]
    return me ~= nil and me.officer == true
end

-- The columns of a line: character, main or alt, rank in game, and a note.
local WARN = { 1, .58, .5 }
local columns = { { 22, 252 }, { 282, 82 }, { 380, 170 }, { 568, 282 } }
local dotColors = { online = { .25, .8, .3 }, offline = { .55, .52, .47, .6 } }
local function line(i)
    local r = U.rosterRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, U.rosterChild)
    r:SetSize(858, 28)
    r.band = U.Inlay(r, 0, 0, 856, 28, {.27,.12,.14,1})
    r.cells = {}
    for c, col in ipairs(columns) do
        r.cells[c] = at(U.FitText(U.Text(r, "", 14, C.ivory, nil, "game"), col[2], 0, true), col[1], -4)
    end
    r.head = at(U.FitText(U.Text(r, "", 14, C.brown, nil, "caps"), 850, 18, false), 4, -6)
    r.presence = at(U.FitText(U.Text(r, "", 14, C.muted), 72, 20, false), 204, -4)
    r.dot = r:CreateTexture(nil, "ARTWORK")
    r.dot:SetSize(10, 10)
    r.dot:SetTexture("Interface\\AddOns\\Emberlight\\Media\\Dot.tga")
    r.rule = r:CreateTexture(nil, "ARTWORK")
    r.rule:SetPoint("BOTTOMLEFT"); r.rule:SetPoint("BOTTOMRIGHT"); r.rule:SetHeight(1)
    r.rule:SetColorTexture(.9, .85, .7, .12)
    U.rosterRows[i] = r
    return r
end

function U.CreateRoster()
    local page = CreateFrame("Frame", nil, U.frame)
    page:SetPoint("TOPLEFT", 0, -16); page:SetPoint("BOTTOMRIGHT", 0, -16)
    U.rosterPage = page
    U.Inlay(page, 8, -144, 944, 74, {.18,.087,.095,1})
    U.Inlay(page, 8, -219, 944, 28, {.26,.18,.17,1})
    -- The list sits on a dark panel like the other pages; the rows are light on dark so it stays easy to read.
    U.Inlay(page, 8, -248, 944, 388, {.06,.085,.115,.97})
    U.rosterChips = {}
    local x = 38
    for _, chip in ipairs({ { "check", "Roster check", 120 }, { "invite", "Needs an invite", 140 }, { "addon", "Addon users", 120 } }) do
        local button = at(U.Button(page, chip[2], chip[3], function()
            U.rosterView = chip[1]; U.rosterList:SetVerticalScroll(0); U.RefreshRoster()
        end, "flat"), x, -102)
        button:SetHeight(26); button.key = chip[1]
        U.rosterChips[#U.rosterChips + 1] = button
        x = x + chip[3] + 4
    end
    U.rosterAgain = at(U.Button(page, "Check again", 130, function()
        E.Client.RequestRoster(); E.Sync.Refresh(); U.RefreshRoster(); U.Status("Checked again. WoW may take a moment to send the whole guild.")
    end), 385, -53)
    U.rosterAgain:SetHeight(28)
    U.rosterSummary = at(U.FitText(U.Text(page, "", 14, C.ivory, nil, "game"), 880, 65, true), 38, -152)
    -- Shown only when WoW leaves offline members out of the guild list.
    U.rosterOffline = at(U.Button(page, "Show offline", 124, function()
        if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
        E.Client.RequestRoster(); U.RefreshRoster()
    end), 522, -53)
    U.rosterOffline:SetHeight(28)
    U.rosterHeads = {}
    for c, label in ipairs({ "Character", "Main / alt", "In-game rank", "Details" }) do
        U.rosterHeads[c] = at(U.FitText(U.Text(page, label, 14, C.goldHi, nil, "caps"), columns[c][2], 18, false), 38 + columns[c][1], -225)
    end
    U.presenceHeading = at(U.FitText(U.Text(page, "Status", 14, C.goldHi), 72, 18, false), 242, -225)
    U.Rule(page, 38, -244, 884)
    local list = U.Scroll(page, 884, 326)
    list:SetPoint("TOPLEFT", 38, -250)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(858, 326); list:SetScrollChild(child)
    U.rosterList, U.rosterChild, U.rosterRows = list, child, {}
    page:Hide()
end

local function stamp(t) return t and E.Client.Stamp(t) .. " server time" or "an unknown time" end
local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

-- The lines of the chosen view: headings, then character lines.
local function lines(result, website, guildList)
    local out = {}
    local function head(text) out[#out + 1] = { head = text } end
    local function row(cells, warn, indent, online) out[#out + 1] = { cells = cells, warn = warn, indent = indent, online = online } end
    local function none(text) out[#out + 1] = { cells = { text }, muted = true } end
    if U.rosterView == "addon" then
        local P = E.Presence
        local me = R.Key(E.Client.Name())
        local using, unheard = {}, {}
        for _, entry in ipairs(guildList or {}) do
            if entry.online then
                local identity = E.Client.Local(E.Client.Canonical(entry.full))
                local version = entry.key == me and E.version or P.VersionOf(identity)
                if version then using[#using + 1] = { entry = entry, version = version }
                else unheard[#unheard + 1] = { entry = entry, older = E.Sync.peers[identity] ~= nil } end
            end
        end
        table.sort(using, function(a, b) return a.entry.name:lower() < b.entry.name:lower() end)
        table.sort(unheard, function(a, b) return a.entry.name:lower() < b.entry.name:lower() end)
        local newest = P.Newest() or E.version
        for _, item in ipairs(using) do if P.Newer(item.version, newest) then newest = item.version end end
        head("Online with Emberlight (" .. #using .. ")")
        if #using == 0 then none("Nobody has answered yet. Press Check again, then wait a minute.") end
        for _, item in ipairs(using) do
            local old = P.Newer(newest, item.version)
            row({ item.entry.name, "", item.entry.rank, "Emberlight " .. item.version .. (old and ", out of date" or "") }, old, false, true)
        end
        head("Online, not heard (" .. #unheard .. ")")
        if #unheard == 0 then none("None.") end
        for _, item in ipairs(unheard) do
            row({ item.entry.name, "", item.entry.rank, item.older and "An older Emberlight" or "No answer" }, false, false, true)
        end
        return out
    end
    if U.rosterView == "invite" then
        head("Members' characters not in the guild (" .. result.missing .. ")")
        if #result.invite == 0 then none("None. Every member's verified character is in the guild.") end
        for _, group in ipairs(result.invite) do
            for i, item in ipairs(group.rows) do
                local ch = item.character
                local rank = R.Expected(website, group.member, ch)
                local note = rank and ("Invite as " .. rank) or ch.main and "No rank on Discord" or "No main chosen on the website"
                if i == 1 and group.inGuild > 0 then note = note .. " (has others in the guild)" end
                row({ ch.name, ch.main and "Main" or "Alt", "Not in the guild", note }, false, i > 1)
            end
        end
        return out
    end
    head("Not on the website (" .. #result.notOnWebsite .. ")")
    if #result.notOnWebsite == 0 then none("None. Everyone in the guild is a member's verified character.") end
    for _, entry in ipairs(result.notOnWebsite) do
        row({ entry.name, "", entry.rank, "Not a member's character" }, true, false, entry.online)
    end
    head("Rank differs from Discord (" .. #result.wrongRank .. ")")
    if #result.wrongRank == 0 then none("None.") end
    for _, item in ipairs(result.wrongRank) do
        row({ item.character.name, item.character.main and "Main" or "Alt", item.entry.rank, "Should be " .. item.expected }, true, false, item.entry.online)
    end
    local count = 0
    for _, group in ipairs(result.members) do count = count + #group.rows end
    head("Members in the guild (" .. count .. ")")
    if count == 0 then none("None of the members' characters are in this guild.") end
    for _, group in ipairs(result.members) do
        for i, item in ipairs(group.rows) do
            local note = item.rankOk == false and ("Should be " .. item.expected) or item.rankOk ~= nil and ""
                or item.character.main and "No rank on Discord" or "No main chosen on the website"
            row({ item.character.name, item.character.main and "Main" or "Alt", item.entry.rank, note }, item.rankOk == false, i > 1, item.entry.online)
        end
    end
    return out
end

function U.RefreshRoster()
    if not U.rosterPage then return end
    for _, chip in ipairs(U.rosterChips) do U.SelectButton(chip, chip.key == U.rosterView) end
    for _, r in ipairs(U.rosterRows) do r:Hide() end
    local addonUsers = U.rosterView == "addon"
    local website
    if not addonUsers then website = R.Website() end
    local guild, total = R.Guild()
    local ready = (addonUsers or website ~= nil) and guild ~= nil
    U.rosterList:SetShown(ready)
    U.presenceHeading:SetShown(ready and U.rosterView == "check")
    for i, h in ipairs(U.rosterHeads) do h:SetShown(ready and (i ~= 2 or not addonUsers)) end
    U.rosterOffline:Hide()
    if not addonUsers and not website then
        U.rosterSummary:SetText("No member list yet. Sync in Emberlight Companion before you start the game: an officer's Companion brings the website's member list with each sync.")
        return
    end
    if not guild then U.rosterSummary:SetText("You are not in a guild on this character."); return end
    local result = website and R.Check(website, guild)
    local notes = {}
    if website then
        notes[#notes + 1] = "Website list from " .. stamp(website.generated) .. "."
        if website.generated and E.Client.Now() - website.generated > R.staleAfter then notes[#notes + 1] = "It is a few days old: sync again for a current one." end
        if not website.fresh then notes[#notes + 1] = "Discord ranks may be out of date (Warden had not checked them lately)." end
    end
    local online = 0
    for _, entry in ipairs(guild) do if entry.online then online = online + 1 end end
    if U.rosterView == "addon" then
        local using, heardOnline = E.Presence.Usage()
        notes[#notes + 1] = (using and (using .. " of " .. heardOnline .. " online use Emberlight.") or
            (plural(online, "member", "members") .. " online.")) .. " Version replies can take a minute."
    elseif U.rosterView == "invite" then
        notes[#notes + 1] = plural(result.missing, "character", "characters") .. " of " .. plural(#result.invite, "member", "members") .. " not in the guild."
    else
        notes[#notes + 1] = plural(#guild, "character", "characters") .. " in the guild, " .. online .. " online now: " .. #result.notOnWebsite .. " not on the website, " .. #result.wrongRank .. " with a different rank."
    end
    if not addonUsers and total and #guild < total then
        notes[#notes + 1] = "WoW listed only " .. #guild .. " of " .. total .. " guild members, so this is not the whole guild."
        U.rosterOffline:SetShown(SetGuildRosterShowOffline ~= nil)
    end
    U.rosterSummary:SetText(table.concat(notes, " "))
    local y = 0
    for i, item in ipairs(lines(result, website, guild)) do
        local r = line(i)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y)
        r.head:SetShown(item.head ~= nil)
        local contentHeight = 18
        local showPresence = U.rosterView == "check" and item.online ~= nil
        r.presence:SetShown(showPresence)
        r.presence:SetText(showPresence and (item.online and "Online" or "Offline") or "")
        local nameWidth = showPresence and 174 or columns[1][2]
        r.cells[1]:SetWidth(item.muted and 824 or nameWidth - (item.indent and 16 or 0))
        for c, cell in ipairs(r.cells) do
            local value = item.cells and item.cells[c] or ""
            cell:SetShown(item.head == nil)
            cell:SetText(value)
            contentHeight = math.max(contentHeight, cell:GetStringHeight())
            cell:SetTextColor(unpack(item.muted and C.muted or (item.warn and c == 4) and WARN or (c == 2 or c == 4) and C.muted or C.ivory))
        end
        -- An alt sits a little in from its member's main.
        r.cells[1]:ClearAllPoints(); r.cells[1]:SetPoint("TOPLEFT", columns[1][1] + (item.indent and 16 or 0), -4)
        r.dot:ClearAllPoints(); r.dot:SetPoint("TOPLEFT", 6 + (item.indent and 16 or 0), -8)
        r.dot:SetShown(item.head == nil and not item.muted and item.online ~= nil)
        r.dot:SetVertexColor(unpack(item.online and dotColors.online or dotColors.offline))
        r.rule:SetShown(item.head == nil and not item.muted)
        if item.head then r.head:SetText(item.head) end
        local height = item.head and (i == 1 and 28 or 40) or contentHeight + 12
        r.head:ClearAllPoints(); r.head:SetPoint("TOPLEFT", 4, (item.head and i > 1) and -18 or -6)
        r.band:SetHeight(height - 2)
        if item.head then r.band:SetColorTexture(.27,.15,.15,1)
        else r.band:SetColorTexture(1, 1, 1, i % 2 == 0 and .045 or 0) end
        r.head:SetTextColor(unpack(C.ivory))
        r:SetHeight(height)
        r:Show()
        y = y + height
    end
    U.rosterChild:SetHeight(math.max(U.rosterList:GetHeight(), y + 8))
    U.UpdateScroll(U.rosterList)
end
