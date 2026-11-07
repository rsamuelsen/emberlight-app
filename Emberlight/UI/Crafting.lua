local _, E = ...
local U, P = E.UI, E.Professions
local C = U.colors
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end

-- Crafting (0.8.13, the owner's request, 7 November 2026): a place in the rail for every member,
-- so nobody has to remember a slash command. It shows the crafting requests the Companion brought
-- at its last sync (Emberlight_Data/Crafting.lua) and this character's professions. Read only:
-- asking for something, taking a request and marking it done are on the guild website, because
-- the game cannot reach it.
U.labels.Crafting = "Crafting"

local columns = { { 4, 250 }, { 260, 160 }, { 426, 196 } }
local function line(i)
    local r = U.craftRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, U.craftChild)
    r:SetSize(626, 24)
    r.cells = {}
    for c, col in ipairs(columns) do
        r.cells[c] = at(U.FitText(U.Text(r, "", 14, C.ink, nil, "game"), col[2], 18, false), col[1], -4)
    end
    r.note = at(U.FitText(U.Text(r, "", 13, C.paperMuted, nil, "game"), 600, 18, false), 20, -24)
    r.head = at(U.FitText(U.Text(r, "", 14, C.brown, nil, "caps"), 618, 18, false), 4, -6)
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
    U.craftSummary = at(U.FitText(U.Text(page, "", 14, C.paperMuted, nil, "game"), 430, 70, true), 244, -102)
    -- Sharing professions with the website, on or off, without a slash command.
    at(U.Text(page, "Share my professions", 14, C.paperMuted), 698, -100)
    U.craftShare = at(U.Button(page, "", 200, function()
        local on = not P.Enabled()
        P.SetEnabled(on)
        U.Status(on and "Your professions will be shared with the guild website again." or "Your professions are no longer shared. The website drops them after your next Companion sync.")
        U.RefreshCrafting()
    end), 698, -122)
    U.Rule(page, 244, -178, 654)
    local list = U.Scroll(page, 654, 392)
    list:SetPoint("TOPLEFT", 244, -182)
    local child = CreateFrame("Frame", nil, list)
    child:SetSize(626, 392); list:SetScrollChild(child)
    U.craftList, U.craftChild, U.craftRows = list, child, {}
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
        head("You are making (" .. #making .. ")")
        if #making == 0 then none("Nothing right now.") end
        for _, r in ipairs(making) do row({ what(r), "for " .. r.forCharacter, r.skill }, r.note) end
        head("You can make (" .. #forYou .. ")")
        if #forYou == 0 then none("No open requests for your professions.") end
        for _, r in ipairs(forYou) do row({ what(r), "for " .. r.forCharacter, "with " .. table.concat(r.canMakeWith, ", ") }, r.note) end
        head("Your requests (" .. #mine .. ")")
        if #mine == 0 then none("You have not asked for anything.") end
        for _, r in ipairs(mine) do row({ what(r), "for " .. r.forCharacter, r.crafter and (r.crafter .. " is making it") or "Waiting for a crafter" }) end
    end
    head("Your professions on this character")
    if not P.Enabled() then none("Not shared with the website. Turn on Share my professions above to share them.")
    elseif #skills == 0 then none("None the website lists yet.") end
    for _, s in ipairs(skills) do
        local recipes = P.noRecipes[s.skill] and "" or s.recipes > 0 and (s.recipes .. " recipes") or "Open its window once"
        row({ s.skill, s.rank .. " / " .. s.max, recipes })
    end
    return out
end

function U.RefreshCrafting()
    if not U.craftPage then return end
    for _, r in ipairs(U.craftRows) do r:Hide() end
    U.craftShare.label:SetText(P.Enabled() and "On" or "Off")
    local data = P.Requests()
    if data then
        U.craftSummary:SetText("Requests from your last Companion sync" .. (data.generated and (", " .. E.Client.Stamp(data.generated) .. " server time") or "")
            .. ". To ask for something, take a request or mark it done, use Professions on the guild website.")
    else
        U.craftSummary:SetText("Guild members' crafting requests appear here when the Emberlight Companion syncs before you play. You ask for things, and take requests, under Professions on the guild website.")
    end
    local y = 0
    for i, item in ipairs(U.CraftingLines(data, P.Mine())) do
        local r = line(i)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y)
        r.head:SetShown(item.head ~= nil)
        for c, cell in ipairs(r.cells) do
            cell:SetShown(item.head == nil)
            cell:SetText(item.cells and item.cells[c] or "")
            cell:SetTextColor(unpack(item.muted and C.paperMuted or c == 1 and C.ink or C.paperMuted))
        end
        r.cells[1]:SetWidth(item.muted and 600 or columns[1][2])
        r.note:SetShown(item.note ~= nil)
        if item.note then r.note:SetText("\"" .. item.note .. "\"") end
        r.rule:SetShown(item.head == nil and not item.muted)
        if item.head then r.head:SetText(item.head) end
        local height = item.head and (i == 1 and 28 or 40) or item.note and 44 or 24
        r.head:ClearAllPoints(); r.head:SetPoint("TOPLEFT", 4, (item.head and i > 1) and -18 or -6)
        r:SetHeight(height)
        r:Show()
        y = y + height
    end
    U.craftChild:SetHeight(math.max(U.craftList:GetHeight(), y + 8))
    U.UpdateScroll(U.craftList)
end
