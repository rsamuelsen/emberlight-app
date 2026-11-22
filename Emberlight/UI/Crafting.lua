local _, E = ...
local U, P = E.UI, E.Professions
local C = U.colors
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end

-- Crafting (0.8.13, the owner's request, 7 November 2026): a page for every member,
-- so nobody has to remember a slash command. It shows the crafting requests the Companion brought
-- at its last sync (Emberlight_Data/Crafting.lua) and this character's professions. Read only:
-- asking for something, taking a request and marking it done are on the guild website, because
-- the game cannot reach it.
--
-- Guild bank (1.0.1, the owner's request, 22 November 2026): a fourth view for every member with
-- what the guild bank holds, each tab's Info text and the officers' wanted list, as the website last
-- saw it (Emberlight_Data/Bank.lua, Core/GuildBank.lua). Searchable and read only: nothing in the
-- bank can be taken or asked for from here.
U.labels.Crafting = "Crafting"

local columns = { { 4, 322 }, { 342, 204 }, { 562, 284 } }
local function line(i)
    local r = U.craftRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, U.craftChild)
    r:SetSize(858, 28)
    r.cells = {}
    for c, col in ipairs(columns) do
        r.cells[c] = at(U.FitText(U.Text(r, "", 14, C.ivory, nil, "game"), col[2], 0, true), col[1], -4)
    end
    r.dot = r:CreateTexture(nil, "ARTWORK")
    r.dot:SetSize(10, 10); r.dot:SetPoint("TOPLEFT", 6, -9)
    r.dot:SetTexture("Interface\\AddOns\\Emberlight\\Media\\Dot.tga")
    r.action = at(U.Button(r, "", 190, function()
        if r.crafter then U.Whisper(r.crafter)
        elseif r.recipe then
            U.recipePage = U.findPage; U.foundRecipe = r.recipe; U.findPage = 1; U.craftList:SetVerticalScroll(0); U.RefreshCrafting()
        end
    end, "flat"), 656, -1)
    r.action:SetHeight(26)
    r.note = at(U.FitText(U.Text(r, "", 13, C.muted, nil, "game"), 826, 0, true), 16, -24)
    r.head = at(U.FitText(U.Text(r, "", 14, C.goldHi, nil, "caps"), 850, 18, false), 4, -6)
    r.rule = r:CreateTexture(nil, "ARTWORK")
    r.rule:SetPoint("BOTTOMLEFT"); r.rule:SetPoint("BOTTOMRIGHT"); r.rule:SetHeight(1)
    r.rule:SetColorTexture(.361, .325, .271, .3)
    U.craftRows[i] = r
    return r
end

function U.CreateCrafting()
    local page = CreateFrame("Frame", nil, U.frame)
    page:SetPoint("TOPLEFT", 0, -16); page:SetPoint("BOTTOMRIGHT", 0, -16)
    U.craftPage = page
    U.Inlay(page, 8, -144, 944, 492, {.044,.104,.102,.97})
    U.craftView = "requests"
    U.craftTabs = {}
    for i, view in ipairs({ {"requests", "Requests"}, {"skills", "My professions"}, {"find", "Find a crafter"}, {"bank", "Guild bank"} }) do
        U.craftTabs[i] = at(U.Button(page, view[2], 152, function()
            U.craftView = view[1]; U.craftList:SetVerticalScroll(0); U.RefreshCrafting()
        end, "flat"), 38 + (i-1)*160, -102)
    end
    U.findPage = 1
    U.findField = U.Field(page, "Recipe or profession", 38, -145, 432, 32, 100)
    U.findField.caption:SetTextColor(unpack(C.muted))
    U.findField:SetScript("OnTextChanged", function()
        U.findPage = 1; U.foundRecipe = nil; U.craftList:SetVerticalScroll(0); U.RefreshCrafting()
    end)
    U.bankField = U.Field(page, "Search the guild bank", 38, -145, 432, 32, 100)
    U.bankField.caption:SetTextColor(unpack(C.muted))
    U.bankField:SetScript("OnTextChanged", function() U.craftList:SetVerticalScroll(0); U.RefreshCrafting() end)
    U.bankSummary = at(U.FitText(U.Text(page, "", 14, C.muted), 436, 52, true), 486, -151)
    U.findBack = at(U.Button(page, "Back to recipes", 150, function()
        U.foundRecipe = nil; U.findPage = U.recipePage or 1; U.craftList:SetVerticalScroll(0); U.RefreshCrafting()
    end), 480, -165)
    local function pageBy(offset)
        U.findPage = U.findPage + offset; U.craftList:SetVerticalScroll(0); U.RefreshCrafting()
    end
    U.findPrev = at(U.Button(page, "Previous", 92, function() pageBy(-1) end), 655, -165)
    U.findNext = at(U.Button(page, "Next", 80, function() pageBy(1) end), 757, -165)
    U.findCount = at(U.FitText(U.Text(page,"",14,C.muted), 80,22,false), 847,-173)
    U.craftSummary = at(U.FitText(U.Text(page, "", 14, C.muted), 878, 52, true), 38, -151)
    U.craftShare = at(U.Button(page, "", 200, function()
        local on = not P.Enabled()
        P.SetEnabled(on)
        U.Status(on and "Your professions will be shared with the guild website again." or "Your professions are no longer shared. The website drops them after your next Companion sync.")
        U.RefreshCrafting()
    end), 722, -102)
    U.Rule(page, 38, -207, 884)
    local list = U.Scroll(page, 884, 412)
    list:SetPoint("TOPLEFT", 38, -213)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(858, 412); list:SetScrollChild(child)
    U.craftList, U.craftChild, U.craftRows = list, child, {}
    local empty = at(U.Panel(page, 884, 260, {.047,.103,.095,1}), 38, -215)
    empty.surface = U.Surface(empty, "WorkshopBench.tga")
    empty.title = at(U.Text(empty, "", 24, C.ivory), 30, -52)
    empty.hint = at(U.FitText(U.Text(empty, "", 16, C.text), 370, 66, true), 30, -99)
    U.craftBrowse = at(U.Button(empty, "Find a crafter", 172, function()
        U.craftTabs[empty.synced and 3 or 2]:Click()
        if empty.synced then U.findField:SetFocus() end
    end, "brass"), 30, -177)
    U.craftEmpty = empty
    page:Hide()
end

local function what(r) return (r.quantity > 1 and (r.quantity .. " x ") or "") .. r.recipe end

-- The lines of the page: headings, requests (a second line for a note), then professions.
function U.CraftingLines(data, skills)
    local out = {}
    local function head(text) out[#out + 1] = { head = text } end
    local function row(cells, note) out[#out + 1] = { cells = cells, note = note } end
    local function none(text) out[#out + 1] = { cells = { text }, muted = true } end
    if data then
        local making, forYou, mine = {}, {}, {}
        for _, r in ipairs(data.requests) do
            if r.takenByMe then making[#making + 1] = r
            elseif r.mine then mine[#mine + 1] = r
            elseif r.status == "open" and #r.canMakeWith > 0 then forYou[#forYou + 1] = r end
        end
        if #making > 0 then head("You are making (" .. #making .. ")") end
        for _, r in ipairs(making) do row({ what(r), "for " .. r.forCharacter, r.skill }, r.note) end
        if #forYou > 0 then head("You can make (" .. #forYou .. ")") end
        for _, r in ipairs(forYou) do row({ what(r), "for " .. r.forCharacter, "with " .. table.concat(r.canMakeWith, ", ") }, r.note) end
        if #mine > 0 then head("Your requests (" .. #mine .. ")") end
        for _, r in ipairs(mine) do row({ what(r), "for " .. r.forCharacter, r.crafter and (r.crafter .. " is making it") or "Waiting for a crafter" }) end
    end
    if not skills then return out end
    if not P.Enabled() then return out end
    head("Your professions on this character")
    if #skills == 0 then none("No professions recorded for this character yet.") end
    for _, s in ipairs(skills) do
        local recipes = P.noRecipes[s.skill] and "" or s.recipes > 0 and (s.recipes .. " recipes") or "Open its window once"
        row({ s.skill, s.rank .. " / " .. s.max, recipes })
    end
    return out
end

-- Who is online in the guild right now, by character key (the same list the Officer desk reads).
local function onlineNow()
    local online = {}
    local guild = E.Roster and E.Roster.Guild and E.Roster.Guild()
    for _, entry in ipairs(guild or {}) do if entry.online then online[entry.key] = true end end
    return online, guild ~= nil
end
local dotOnline, dotOffline = { .25, .8, .3 }, { .55, .52, .47, .6 }

local function finderRows()
    local d = _G.EmberlightDirectory
    local rows, count = {}, 0
    local page = U.findPage
    local perPage = 12
    local function onPage()
        count = count + 1
        return count > (page-1)*perPage and count <= page*perPage
    end
    local function note(text) rows[#rows+1] = { cells={text}, muted=true } end
    if type(d) ~= "table" or d.format ~= 1 or type(d.names) ~= "table" or type(d.recipes) ~= "table" then
        note("The guild recipe list is not here yet. Run Emberlight Companion before you start the game, and it will be here next time.")
    elseif U.foundRecipe then
        local r = U.foundRecipe
        rows[1] = { head = E.Clean(r.name,100) }
        if type(r.materials) == "string" and r.materials ~= "" then note("Materials: " .. E.Clean(r.materials,3000)) end
        -- Crafters who are online come first, so the one to whisper is at the top.
        local online, known = onlineNow()
        local crafters = {}
        for _, id in ipairs(r.crafters) do
            local who = E.Clean(d.names[id],120)
            if who ~= "" then
                local on = known and online[E.Roster.Key(who) or ""] or false
                crafters[#crafters+1] = { who = who, on = on, known = known }
            end
        end
        table.sort(crafters, function(a, b)
            if a.on ~= b.on then return a.on end
            return a.who < b.who
        end)
        for _, c in ipairs(crafters) do
            if onPage() then
                rows[#rows+1] = { cells = { c.who, c.known and (c.on and "Online now" or "Offline") or "" }, crafter = c.who, online = c.known and c.on or nil }
            end
        end
        if count == 0 then note("Nobody has shared this recipe yet.") end
    else
        local query = E.Fold(E.Trim(U.findField:GetText()))
        if query == "" then
            local stamp = tonumber(d.generated)
            note("Search for an item or profession." .. (stamp and (" Last sync: " .. E.Client.Stamp(stamp) .. " server time.") or ""))
        else
            for _, r in ipairs(d.recipes) do
                if type(r)=="table" and type(r.crafters)=="table" then
                    local name, skill = E.Clean(r.name,100), E.Clean(r.skill,24)
                    if E.Fold(name .. " " .. skill .. " " .. E.Clean(r.aliases,1600)):find(query,1,true) and onPage() then
                        rows[#rows+1] = { cells={name,skill}, recipe=r }
                    end
                end
            end
            if count == 0 then note("No recipe matches that. Try a shorter name, or a profession such as Alchemy.") end
        end
    end
    local pages = math.max(1, math.ceil(count/perPage))
    U.findPrev:SetEnabled(page > 1); U.findNext:SetEnabled(page < pages)
    U.findCount:SetText(page .. " / " .. pages)
    return rows
end

-- The Guild bank view: Info texts, the wanted list and what the bank holds, or the items that match
-- the search. At most 300 lines, so a full bank never builds a thousand rows at once.
local function money(copper)
    local g, sv, c = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if sv > 0 then parts[#parts + 1] = sv .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end
function U.BankRows(bank, query)
    local rows = {}
    local function note(text) rows[#rows + 1] = { cells = { text }, muted = true } end
    if not bank then
        note("The guild bank appears here after Emberlight Companion has run, once an officer has opened the bank in game.")
        return rows
    end
    local function item(i) rows[#rows + 1] = { cells = { i.name, i.count .. (i.count == 1 and " item" or " items"), table.concat(i.tabs, ", ") } } end
    if query ~= "" then
        local found = 0
        for _, i in ipairs(bank.items) do
            if E.Fold(i.name):find(query, 1, true) then
                found = found + 1
                if found <= 300 then item(i) end
            end
        end
        if found == 0 then note("The guild bank holds nothing by that name.") end
        return rows
    end
    for _, t in ipairs(bank.tabs) do
        if t.text ~= "" then
            rows[#rows + 1] = { head = "About " .. t.name }
            rows[#rows + 1] = { cells = { "" }, note = t.text }
        end
    end
    -- Item requests, read only (asked and answered on the website, like crafting requests).
    local mine, waiting = {}, {}
    for _, r in ipairs(bank.requests or {}) do
        if r.mine then mine[#mine + 1] = r elseif r.status == "open" then waiting[#waiting + 1] = r end
    end
    local said = { open = "Waiting", filled = "Given", declined = "Not this time" }
    if #waiting > 0 then
        rows[#rows + 1] = { head = "Members asking (" .. #waiting .. ")" }
        for _, r in ipairs(waiting) do
            rows[#rows + 1] = { cells = { r.count .. " x " .. r.item, "for " .. r.character, r.createdAt and ("asked " .. E.Client.Stamp(r.createdAt)) or "" }, note = r.note }
        end
    end
    if #mine > 0 then
        rows[#rows + 1] = { head = "Your requests (" .. #mine .. ")" }
        for _, r in ipairs(mine) do
            rows[#rows + 1] = { cells = { r.count .. " x " .. r.item, said[r.status] or r.status, r.decidedBy and ("by " .. r.decidedBy) or "" }, note = r.answer }
        end
    end
    if #bank.wanted > 0 then
        rows[#rows + 1] = { head = "Wanted by the guild (" .. #bank.wanted .. ")" }
        for _, w in ipairs(bank.wanted) do
            rows[#rows + 1] = { cells = { w.name, w.have .. " of " .. w.target, w.have >= w.target and "Enough for now" or "" } }
        end
    end
    rows[#rows + 1] = { head = "In the guild bank (" .. #bank.items .. ")" }
    if #bank.items == 0 then note("Nothing yet, or no tab you can see.") end
    for n, i in ipairs(bank.items) do
        if n > 300 then note("Search to see the rest."); break end
        item(i)
    end
    return rows
end

function U.RefreshCrafting()
    if not U.craftPage then return end
    for _, r in ipairs(U.craftRows) do r:Hide() end
    local skills = U.craftView == "skills"
    U.SelectButton(U.craftTabs[1], U.craftView == "requests"); U.SelectButton(U.craftTabs[2], skills)
    local find = U.craftView == "find"
    local bankView = U.craftView == "bank"
    U.SelectButton(U.craftTabs[3], find)
    U.SelectButton(U.craftTabs[4], bankView)
    U.findField:GetParent():SetShown(find); U.findField.caption:SetShown(find)
    U.bankField:GetParent():SetShown(bankView); U.bankField.caption:SetShown(bankView); U.bankSummary:SetShown(bankView)
    U.findPrev:SetShown(find); U.findNext:SetShown(find); U.findCount:SetShown(find)
    U.findBack:SetShown(find and U.foundRecipe ~= nil); U.craftSummary:SetShown(not find and not bankView)
    U.craftShare:SetShown(skills)
    U.craftShare.label:SetText(P.Enabled() and "Pause sharing" or "Share my professions")
    local rows, emptyRequests
    if bankView then
        local bank = E.GuildBank.Website()
        local parts = {}
        if bank and bank.copper then parts[#parts + 1] = "The guild bank holds " .. money(bank.copper) .. "." end
        if bank and bank.readAt then parts[#parts + 1] = "Last read in game " .. E.Client.Stamp(bank.readAt) .. " server time." end
        parts[#parts + 1] = bank and bank.requestsOpen and "Ask for an item on the website's Guild Bank page." or "See more on the website's Guild Bank page."
        U.bankSummary:SetText(table.concat(parts, " "))
        rows = U.BankRows(bank, E.Fold(E.Trim(U.bankField:GetText())))
    elseif find then rows = finderRows()
    elseif skills then
        U.craftSummary:SetText(P.Enabled() and "Your professions are shared with the guild. Open a profession window to update its known recipes."
            or "Sharing is paused. You can turn it on again here.")
        rows = U.CraftingLines(nil, P.Mine())
    else
        local data = P.Requests()
        local summary = data and ("Requests from your last Companion sync" .. (data.generated and (", " .. E.Client.Stamp(data.generated) .. " server time") or "") .. ".")
            or "Crafting requests appear here after Emberlight Companion has run."
        U.craftSummary:SetText(summary .. " Open Professions on the guild website to ask, take a request or mark it done.")
        rows = U.CraftingLines(data)
        emptyRequests = #rows == 0
        if emptyRequests then
            U.craftEmpty.synced = data ~= nil
            U.craftEmpty.title:SetText(data and "Nothing waiting for you" or "No requests to show yet")
            U.craftEmpty.hint:SetText(data and "No request needs you right now. You can still search the guild's recipes to find a crafter and see the materials."
                or "Run Emberlight Companion before you start the game to see requests here. You can already check your own professions.")
            U.craftBrowse.label:SetText(data and "Find a crafter" or "My professions")
        end
    end
    U.craftEmpty:SetShown(emptyRequests == true)
    U.craftList:SetShown(not emptyRequests)
    local y = 0
    for i, item in ipairs(rows) do
        local r = line(i)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y)
        r.head:SetShown(item.head ~= nil)
        r.recipe, r.crafter = item.recipe, item.crafter
        r.action:SetShown(item.recipe ~= nil or item.crafter ~= nil)
        r.action.label:SetText(item.crafter and "Whisper" or "View crafters")
        local contentHeight = 18
        local showDot = item.online ~= nil
        r.dot:SetShown(showDot)
        if showDot then r.dot:SetVertexColor(unpack(item.online and dotOnline or dotOffline)) end
        r.cells[1]:ClearAllPoints(); at(r.cells[1], showDot and 22 or columns[1][1], -4)
        r.cells[1]:SetWidth(item.muted and 846 or showDot and columns[1][2] - 18 or columns[1][2])
        for c, cell in ipairs(r.cells) do
            cell:SetShown(item.head == nil)
            cell:SetText(item.cells and item.cells[c] or "")
            contentHeight = math.max(contentHeight, cell:GetStringHeight())
            cell:SetTextColor(unpack(item.muted and C.muted or c == 1 and C.ivory or (showDot and item.online) and dotOnline or C.muted))
        end
        r.note:SetShown(item.note ~= nil)
        if item.note then
            r.note:ClearAllPoints(); at(r.note, 16, -contentHeight - 8)
            r.note:SetText(item.note)
            contentHeight = contentHeight + 4 + r.note:GetStringHeight()
        end
        r.rule:SetShown(item.head == nil and not item.muted)
        if item.head then r.head:SetText(item.head) end
        local height = item.head and (i == 1 and 28 or 40) or contentHeight + 12
        r.head:ClearAllPoints(); r.head:SetPoint("TOPLEFT", 4, (item.head and i > 1) and -18 or -6)
        r:SetHeight(height)
        r:Show()
        y = y + height
    end
    U.craftChild:SetHeight(math.max(U.craftList:GetHeight(), y + 8))
    U.UpdateScroll(U.craftList)
end
