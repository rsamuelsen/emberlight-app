local _, E = ...
local U, R = E.UI, E.Roster
local C = U.colors
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end

-- The officers' roster check: a place in the rail for the guild master (rank 0), Flame Keepers
-- and Officer Alts only, the same in-game authority as posting guild events. Two views: "Roster check" (everyone in
-- the guild, against the website), "Needs an invite" (members' characters not in the guild) and
-- "Addon users" (who online uses Emberlight, and which version; Core/Presence.lua). A dot before
-- each name in the guild shows who is online now: green online, grey offline.
U.labels.Roster = "Roster check"
U.rosterView = "check"

function U.RosterAllowed()
    if E.Client.Channel() ~= "GUILD" then return false end
    local name = E.Client.Name()
    local me = name and E.Client.Roster()[E.Client.Canonical(name)]
    return me ~= nil and me.officer == true
end

-- The columns of a line: character, main or alt, rank in game, and a note.
local columns = { { 22, 212 }, { 240, 64 }, { 310, 150 }, { 466, 156 } }
local dotColors = { online = { .25, .8, .3 }, offline = { .55, .52, .47, .6 } }
local function line(i)
    local r = U.rosterRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, U.rosterChild)
    r:SetSize(626, 24)
    r.cells = {}
    for c, col in ipairs(columns) do
        r.cells[c] = at(U.FitText(U.Text(r, "", 14, C.ink, nil, "game"), col[2], 18, false), col[1], -4)
    end
    r.head = at(U.FitText(U.Text(r, "", 14, C.brown, nil, "caps"), 618, 18, false), 4, -6)
    r.dot = r:CreateTexture(nil, "ARTWORK")
    r.dot:SetSize(10, 10)
    r.dot:SetTexture("Interface\\AddOns\\Emberlight\\Media\\Dot.tga")
    r.rule = r:CreateTexture(nil, "ARTWORK")
    r.rule:SetPoint("BOTTOMLEFT"); r.rule:SetPoint("BOTTOMRIGHT"); r.rule:SetHeight(1)
    r.rule:SetColorTexture(.361, .325, .271, .3)
    U.rosterRows[i] = r
    return r
end

function U.CreateRoster()
    local page = CreateFrame("Frame", nil, U.frame)
    page:SetPoint("TOPLEFT", 0, -16); page:SetPoint("BOTTOMRIGHT", 0, -16)
    U.rosterPage = page
    U.rosterChips = {}
    local x = 244
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
    end), 768, -100)
    U.rosterAgain:SetHeight(28)
    U.rosterSummary = at(U.FitText(U.Text(page, "", 14, C.paperMuted, nil, "game"), 654, 52, true), 244, -136)
    -- Shown only when WoW leaves offline members out of the guild list.
    U.rosterOffline = at(U.Button(page, "Show offline", 124, function()
        if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
        E.Client.RequestRoster(); U.RefreshRoster()
    end), 640, -100)
    U.rosterOffline:SetHeight(28)
    U.rosterHeads = {}
    for c, label in ipairs({ "Character", "", "In-game rank", "" }) do
        U.rosterHeads[c] = at(U.FitText(U.Text(page, label, 14, C.brown, nil, "caps"), columns[c][2], 18, false), 244 + columns[c][1], -194)
    end
    U.Rule(page, 244, -214, 654)
    local list = U.Scroll(page, 654, 356)
    list:SetPoint("TOPLEFT", 244, -218)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(626, 356); list:SetScrollChild(child)
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
    local website = R.Website()
    local guild, total = R.Guild()
    local ready = website ~= nil and guild ~= nil
    U.rosterList:SetShown(ready)
    for _, h in ipairs(U.rosterHeads) do h:SetShown(ready) end
    U.rosterOffline:Hide()
    if not website then
        U.rosterSummary:SetText("No member list yet. Sync in Emberlight Companion before you start the game: an officer's Companion brings the website's member list with each sync.")
        return
    end
    if not guild then U.rosterSummary:SetText("You are not in a guild on this character."); return end
    local result = R.Check(website, guild)
    local notes = {}
    notes[#notes + 1] = "Website list from " .. stamp(website.generated) .. "."
    if website.generated and E.Client.Now() - website.generated > R.staleAfter then notes[#notes + 1] = "It is a few days old: sync again for a current one." end
    if not website.fresh then notes[#notes + 1] = "Discord ranks may be out of date (Warden had not checked them lately)." end
    local online = 0
    for _, entry in ipairs(guild) do if entry.online then online = online + 1 end end
    if U.rosterView == "addon" then
        notes[#notes + 1] = plural(online, "member", "members") .. " online. An Emberlight from this version on answers with its version within a minute or so; an older one, or one with messages paused, is not heard."
    elseif U.rosterView == "invite" then
        notes[#notes + 1] = plural(result.missing, "character", "characters") .. " of " .. plural(#result.invite, "member", "members") .. " not in the guild."
    else
        notes[#notes + 1] = plural(#guild, "character", "characters") .. " in the guild, " .. online .. " online now: " .. #result.notOnWebsite .. " not on the website, " .. #result.wrongRank .. " with a different rank."
    end
    if total and #guild < total then
        notes[#notes + 1] = "WoW listed only " .. #guild .. " of " .. total .. " guild members, so this is not the whole guild."
        U.rosterOffline:SetShown(SetGuildRosterShowOffline ~= nil)
    end
    U.rosterSummary:SetText(table.concat(notes, " "))
    local y = 0
    for i, item in ipairs(lines(result, website, guild)) do
        local r = line(i)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y)
        r.head:SetShown(item.head ~= nil)
        for c, cell in ipairs(r.cells) do
            local value = item.cells and item.cells[c] or ""
            cell:SetShown(item.head == nil)
            cell:SetText(value)
            cell:SetTextColor(unpack(item.muted and C.paperMuted or (item.warn and c == 4) and C.wax or (c == 2 or c == 4) and C.paperMuted or C.ink))
        end
        -- An alt sits a little in from its member's main.
        r.cells[1]:ClearAllPoints(); r.cells[1]:SetPoint("TOPLEFT", columns[1][1] + (item.indent and 16 or 0), -4)
        r.cells[1]:SetWidth(item.muted and 600 or columns[1][2] - (item.indent and 16 or 0))
        r.dot:ClearAllPoints(); r.dot:SetPoint("TOPLEFT", 6 + (item.indent and 16 or 0), -8)
        r.dot:SetShown(item.head == nil and not item.muted and item.online ~= nil)
        r.dot:SetVertexColor(unpack(item.online and dotColors.online or dotColors.offline))
        r.rule:SetShown(item.head == nil and not item.muted)
        if item.head then r.head:SetText(item.head) end
        local height = item.head and (i == 1 and 28 or 40) or 24
        r.head:ClearAllPoints(); r.head:SetPoint("TOPLEFT", 4, (item.head and i > 1) and -18 or -6)
        r:SetHeight(height)
        r:Show()
        y = y + height
    end
    U.rosterChild:SetHeight(math.max(U.rosterList:GetHeight(), y + 8))
    U.UpdateScroll(U.rosterList)
end
