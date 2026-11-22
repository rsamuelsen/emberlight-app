local _, E = ...
-- The guild bank for the website (0.8.14, the owner's request, 16 November 2026). When the
-- guild master, a Flame Keeper or an Officer Alt opens the guild bank, the addon reads the bank's
-- transaction logs (gold and items put in and taken out, as the game's own Log tabs show them) and
-- how much gold the bank holds, and keeps them in EmberlightDB.localData.bankScans. The officer's
-- Emberlight Companion uploads them after the game closes; on the website every line waits until an
-- officer approves it (Officers, Bank desk, Bank log).
--
-- What lies in the bank (1.0.1, the owner's request, 22 November 2026, after the guild bought its
-- first tab): the same visit also reads each tab this character can look inside (every slot's item,
-- stack size and quality), each tab's name, icon and Info text, and, for the guild master, each
-- rank's bank settings (view, deposit, edit the Info text, stacks per day, gold per day), for the
-- website's Guild Bank page and the permissions helper. The tabs are asked for one at a time, as
-- the game sends them one at a time.
--
-- Only reading. The logs, tabs and Info text are asked for (QueryGuildBankLog, QueryGuildBankTab,
-- QueryGuildBankText, as the bank window does) and read; nothing is clicked, moved, deposited or
-- withdrawn, no setting or text is changed, and nothing is sent to other players. A rank check here
-- is a convenience: the website checks who uploads. "/emberlight bank off" stops it.
--
-- Members see the bank in game through the Companion: Emberlight_Data/Bank.lua (global
-- EmberlightBank) holds what the website last saw, for the Crafting page's Guild bank view
-- (UI/Crafting.lua) and the "Guild bank: 12" line on item tooltips.
local B = {}
E.GuildBank = B
-- Scans kept for the Companion, and lines read per log (the game keeps 25).
B.keep = 10
B.maxLines = 100
B.slots = 98
B.format = 1

local function db()
    local d = E.Store.db and E.Store.db.localData
    if not d then return nil end
    d.bankScans = type(d.bankScans) == "table" and d.bankScans or {}
    return d.bankScans
end
function B.Enabled() return E.Store.db and E.Store.db.settings.readBankLog ~= false end
function B.SetEnabled(on) E.Store.db.settings.readBankLog = on and true or false end
-- The "Guild bank: 12" line on item tooltips: on unless the member switched it off.
function B.TooltipOn() return E.Store.db and E.Store.db.settings.bankTooltip ~= false end
function B.SetTooltip(on) E.Store.db.settings.bankTooltip = on and true or false end

-- The guild master (rank index 0), Flame Keepers and Officer Alts, as for guild events.
function B.Officer()
    if not IsInGuild or not IsInGuild() or not GetGuildInfo then return false end
    local _, rank, index = GetGuildInfo("player")
    return index == 0 or E.Client.officerRanks[rank] == true
end

-- "3 hours ago" as the game gives it: whole hours, and whether it counted in months or years.
local function age(year, month, day, hour)
    year, month, day, hour = tonumber(year) or 0, tonumber(month) or 0, tonumber(day) or 0, tonumber(hour) or 0
    return year * 8760 + month * 730 + day * 24 + hour, year > 0 or month > 0
end
local function text(value, limit)
    if type(value) ~= "string" then return nil end
    local clean = E.Trim(E.Clean(value, limit))
    return clean ~= "" and clean or nil
end
-- The Info text keeps its line breaks.
local function info(value)
    if type(value) ~= "string" then return nil end
    local lines = {}
    for line in (value .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = E.Clean(line, 2047) end
    return E.Trim(table.concat(lines, "\n")):sub(1, 2047)
end

local function tabCount() return math.min(tonumber(GetNumGuildBankTabs and GetNumGuildBankTabs()) or 0, 12) end

-- One tab's slots, if the game has sent them. Nil when this character cannot look inside.
function B.ReadTab(tab)
    if not GetGuildBankItemLink or not GetGuildBankItemInfo then return nil end
    local slots = {}
    for slot = 1, B.slots do
        local link = GetGuildBankItemLink(tab, slot)
        local itemId = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
        if itemId then
            local _, count, _, _, quality = GetGuildBankItemInfo(tab, slot)
            count = tonumber(count) or 0
            if count > 0 then
                local getInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
                local stack = getInfo and select(8, getInfo(link)) or nil
                slots[#slots + 1] = { slot = slot, itemId = itemId, item = text(link:match("%[(.-)%]"), 100), count = math.floor(count),
                    quality = tonumber(quality), stack = tonumber(stack) and tonumber(stack) > 0 and math.floor(tonumber(stack)) or nil }
            end
        end
    end
    return slots
end

-- Each rank's guild bank settings, for the guild master only (the game answers for the rank chosen in
-- guild control, which only the guild master can choose). Rank 1 in guild control is the guild
-- master, who can always do everything, so it is left out. Not read while the guild control window
-- is open, so nothing the guild master is editing changes under them.
function B.ReadRanks(tabs)
    if not IsGuildLeader or not IsGuildLeader() or not GuildControlGetNumRanks or not GuildControlSetRank or not GetGuildBankTabPermissions then return nil end
    if GuildControlUI and GuildControlUI.IsShown and GuildControlUI:IsShown() then return nil end
    local ranks = {}
    for i = 2, math.min(tonumber(GuildControlGetNumRanks()) or 0, 20) do
        local ok = pcall(GuildControlSetRank, i)
        local name = ok and GuildControlGetRankName and text(GuildControlGetRankName(i), 40)
        if name then
            local rank = { index = i - 1, name = name, tabs = {} }
            local okGold, gold = pcall(GetGuildBankWithdrawGoldLimit or function() return nil end)
            rank.goldPerDay = okGold and tonumber(gold) and math.max(0, math.floor(gold)) or nil
            for tab = 1, tabs do
                local okTab, view, deposit, edit, stacks = pcall(GetGuildBankTabPermissions, tab)
                if okTab then
                    rank.tabs[#rank.tabs + 1] = { tab = tab, view = view and true or false, deposit = deposit and true or false, editText = edit and true or false, stacksPerDay = math.max(0, math.floor(tonumber(stacks) or 0)) }
                end
            end
            ranks[#ranks + 1] = rank
        end
    end
    return #ranks > 0 and ranks or nil
end

-- The logs as the game has them now, and what lies in the tabs the game has sent (`arrived`). Nil
-- when this character cannot read them.
function B.Read(arrived, texts)
    if not GetNumGuildBankTabs or not GetNumGuildBankTransactions or not GetGuildBankTransaction then return nil end
    local scan = { at = E.Client.Now(), character = E.Client.Name(), tabs = {}, money = {} }
    if GetGuildBankMoney then
        local ok, copper = pcall(GetGuildBankMoney)
        if ok and type(copper) == "number" and copper >= 0 then scan.bankMoney = math.floor(copper) end
    end
    local lines = 0
    local count = tabCount()
    for tab = 1, count do
        local name = GetGuildBankTabInfo and text((GetGuildBankTabInfo(tab)), 40)
        local list = {}
        for i = 1, math.min(tonumber(GetNumGuildBankTransactions(tab)) or 0, B.maxLines) do
            local kind, who, link, count, _, _, year, month, day, hour = GetGuildBankTransaction(tab, i)
            who = text(who, 60)
            -- A move between tabs changes nothing in the bank.
            if type(kind) == "string" and kind ~= "move" and who then
                local hours, rough = age(year, month, day, hour)
                local itemId = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
                local item = type(link) == "string" and text(link:match("%[(.-)%]"), 100) or nil
                list[#list + 1] = { type = kind, name = who, itemId = itemId, item = item, count = math.max(1, tonumber(count) or 1), hours = hours, rough = rough or nil }
            end
        end
        scan.tabs[#scan.tabs + 1] = { tab = tab, name = name, lines = list }
        lines = lines + #list
    end
    if GetNumGuildBankMoneyTransactions and GetGuildBankMoneyTransaction then
        for i = 1, math.min(tonumber(GetNumGuildBankMoneyTransactions()) or 0, B.maxLines) do
            local kind, who, copper, year, month, day, hour = GetGuildBankMoneyTransaction(i)
            who = text(who, 60)
            if type(kind) == "string" and who and tonumber(copper) and copper > 0 then
                local hours, rough = age(year, month, day, hour)
                scan.money[#scan.money + 1] = { type = kind, name = who, copper = math.floor(copper), hours = hours, rough = rough or nil }
            end
        end
    end
    -- What lies in the tabs (1.0.1). Every tab is listed with its name; slots only for the tabs this
    -- character can see and the game has sent.
    if arrived and count > 0 and GetGuildBankTabInfo then
        scan.contents = {}
        for tab = 1, count do
            local name, icon, viewable = GetGuildBankTabInfo(tab)
            local entry = { tab = tab, name = text(name, 40), icon = tonumber(icon) }
            if viewable and arrived[tab] then
                entry.slots = B.ReadTab(tab)
                if texts and texts[tab] and GetGuildBankText then entry.text = info(GetGuildBankText(tab)) end
            end
            scan.contents[#scan.contents + 1] = entry
        end
        scan.ranks = B.ReadRanks(count)
    end
    return scan, lines + #scan.money
end

-- Keeps a scan for the Companion, newest first. Another read by the same character within a few
-- minutes (the logs arrive one at a time) replaces the last one. Only the newest scan keeps what lay
-- in the tabs: the website only wants the newest, and it keeps the upload small.
function B.Save(scan)
    local all = db()
    if not all or not scan then return end
    local last = all[1]
    if type(last) == "table" and last.character == scan.character and scan.at - (tonumber(last.at) or 0) < 300 then
        -- A read with no tabs yet does not throw away one that had them.
        if not scan.contents and last.contents then scan.contents, scan.ranks = last.contents, last.ranks end
        all[1] = scan
    else
        table.insert(all, 1, scan)
    end
    for i = 2, #all do
        if type(all[i]) == "table" then all[i].contents, all[i].ranks = nil, nil end
    end
    for i = #all, B.keep + 1, -1 do all[i] = nil end
end

function B.Lines()
    local all = db() or {}
    local last = all[1]
    local lines = { B.Enabled() and "The guild bank log and what lies in the bank are read when an officer opens the guild bank." or "Reading the guild bank is switched off. Type /emberlight bank on to switch it on." }
    if type(last) == "table" then
        lines[#lines + 1] = "Last read " .. E.Client.Stamp(tonumber(last.at) or 0) .. " server time by " .. tostring(last.character):match("^[^-]+") .. ". Your Companion sends it to the website when the game is closed."
    end
    lines[#lines + 1] = B.TooltipOn() and "Item tooltips say how many the guild bank holds. Type /emberlight banktip off to hide that line." or "Item tooltips do not show the guild bank. Type /emberlight banktip on to show it."
    return lines
end

-- The guild bank as the website last saw it (Emberlight_Data/Bank.lua). The file is local and could
-- be damaged or edited, so only plain values are taken from it. Nil before the first sync.
local cache, cacheOf
function B.Website()
    local data = _G.EmberlightBank
    if cacheOf == data then return cache end
    cacheOf, cache = data, nil
    if type(data) ~= "table" or data.format ~= B.format or type(data.items) ~= "table" then return nil end
    local bank = { generated = tonumber(data.generated), readAt = tonumber(data.readAt), copper = tonumber(data.copper), tabs = {}, items = {}, wanted = {}, byId = {}, requests = {}, requestsOpen = data.requestsOpen == true }
    for _, t in ipairs(type(data.tabs) == "table" and data.tabs or {}) do
        if type(t) == "table" and tonumber(t.tab) and #bank.tabs < 12 then
            bank.tabs[#bank.tabs + 1] = { tab = tonumber(t.tab), name = text(t.name, 40) or ("Tab " .. t.tab), text = info(t.text) or "", readAt = tonumber(t.readAt) }
        end
    end
    for _, i in ipairs(data.items) do
        if type(i) == "table" and tonumber(i.id) and tonumber(i.count) and #bank.items < 1200 then
            local tabs = {}
            for _, name in ipairs(type(i.tabs) == "table" and i.tabs or {}) do tabs[#tabs + 1] = text(name, 40) end
            local item = { id = tonumber(i.id), name = text(i.name, 100) or ("Item " .. i.id), count = tonumber(i.count), quality = tonumber(i.quality), tabs = tabs }
            bank.items[#bank.items + 1] = item
            bank.byId[item.id] = item
        end
    end
    table.sort(bank.items, function(a, b) return a.name:lower() < b.name:lower() end)
    for _, w in ipairs(type(data.wanted) == "table" and data.wanted or {}) do
        if type(w) == "table" and tonumber(w.target) and #bank.wanted < 60 then
            bank.wanted[#bank.wanted + 1] = { id = tonumber(w.id), name = text(w.name, 100) or "", target = tonumber(w.target), have = tonumber(w.have) or 0 }
        end
    end
    -- Item requests (same day, the owner: "like asking crafters"): read only here, asked and answered
    -- on the website. Officers get every open one, a member their own.
    local statuses = { open = true, filled = true, declined = true }
    for _, r in ipairs(type(data.requests) == "table" and data.requests or {}) do
        local item = type(r) == "table" and text(r.item, 100)
        if item and tonumber(r.count) and statuses[r.status] and #bank.requests < 100 then
            bank.requests[#bank.requests + 1] = {
                id = tonumber(r.id), character = text(r.character, 60) or "", itemId = tonumber(r.itemId), item = item, count = tonumber(r.count),
                note = text(r.note, 200), status = r.status, answer = text(r.answer, 200), decidedBy = text(r.decidedBy, 60), createdAt = tonumber(r.createdAt), mine = r.mine == true,
            }
        end
    end
    cache = bank
    return bank
end

-- After logging in: officers hear how many members' item requests wait on the website; a member
-- hears once when one of theirs was answered (remembered in settings.bankSeen). Like crafting requests.
function B.RequestNotice()
    local bank = B.Website()
    local settings = E.Store.db and E.Store.db.settings
    if not bank or not settings or not DEFAULT_CHAT_FRAME then return end
    local seen = type(settings.bankSeen) == "table" and settings.bankSeen or {}
    local keep, waiting, answered = {}, 0, 0
    for _, r in ipairs(bank.requests) do
        if r.status == "open" and not r.mine then waiting = waiting + 1 end
        if r.mine and r.status ~= "open" and r.id then
            if not seen[r.id] then answered = answered + 1 end
            keep[r.id] = true
        end
    end
    settings.bankSeen = keep
    if waiting > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("Emberlight: %s for an item from the guild bank. Open Emberlight > Crafting > Guild bank to see %s, and answer on the website's Guild Bank page.", waiting == 1 and "A member asked" or (waiting .. " members asked"), waiting == 1 and "it" or "them"))
    end
    if answered > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("Emberlight: the officers answered %s. Open Emberlight > Crafting > Guild bank to see %s.", answered == 1 and "your guild bank request" or (answered .. " of your guild bank requests"), answered == 1 and "it" or "them"))
    end
end

-- The tooltip line: how many of this item the guild bank holds, from the last sync.
function B.TooltipLine(tooltip)
    if not B.TooltipOn() or not tooltip or not tooltip.GetItem then return end
    local name, link = tooltip:GetItem()
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    local bank = id and B.Website()
    local item = bank and bank.byId[id]
    -- A wanted item matches by its number, or by its name when the officer typed only a name.
    local folded = type(name) == "string" and name:lower() or nil
    local wanted
    for _, w in ipairs(bank and bank.wanted or {}) do
        if (w.id and w.id == id) or (not w.id and folded and w.name:lower() == folded) then wanted = w; break end
    end
    if item then tooltip:AddLine("Guild bank: " .. item.count, 1, .82, .35) end
    if wanted then tooltip:AddLine("Wanted by the guild: " .. wanted.have .. " of " .. wanted.target, 1, .82, .35) end
    if item or wanted then tooltip:Show() end
end
function B.HookTooltips()
    if B.hooked then return end
    B.hooked = true
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
            if tooltip == GameTooltip or tooltip == ItemRefTooltip then pcall(B.TooltipLine, tooltip) end
        end)
    else
        for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
            if tooltip and tooltip.HookScript then tooltip:HookScript("OnTooltipSetItem", function(self) pcall(B.TooltipLine, self) end) end
        end
    end
end

function B.Start()
    if B.frame or not CreateFrame then return end
    pcall(B.HookTooltips)
    local frame = CreateFrame("Frame")
    B.frame = frame
    local pending, told = false, false
    -- Tabs whose slots and Info text the game has sent during this visit.
    local arrived, texts, queue, waiting = {}, {}, {}, nil
    local function read()
        pending = false
        if not B.open or not B.Enabled() or not B.Officer() then return end
        local scan, count = B.Read(arrived, texts)
        if not scan then return end
        B.Save(scan)
        if not told and count > 0 then
            told = true
            DEFAULT_CHAT_FRAME:AddMessage("Emberlight: guild bank read (" .. count .. " log lines). Your Companion sends it to the website, where officers approve the log.")
        end
    end
    local function soon()
        if pending then return end
        pending = true
        C_Timer.After(1, function() pcall(read) end)
    end
    -- Asks for the next tab's slots and Info text; the game answers one tab at a time.
    local function nextTab()
        waiting = table.remove(queue, 1)
        if not waiting or not B.open then waiting = nil; return end
        local asked = waiting
        if QueryGuildBankTab then pcall(QueryGuildBankTab, asked) end
        if QueryGuildBankText then pcall(QueryGuildBankText, asked) end
        -- No answer within a few seconds: go on with the next tab.
        C_Timer.After(3, function() if waiting == asked then nextTab() end end)
    end
    local function opened()
        if B.open then return end
        B.open, told = true, false
        arrived, texts, queue, waiting = {}, {}, {}, nil
        if not B.Enabled() or not B.Officer() or not QueryGuildBankLog then return end
        -- Ask for every tab's log and the gold log, the way the Log tab does, then read them.
        local count = tabCount()
        for tab = 1, count do pcall(QueryGuildBankLog, tab) end
        pcall(QueryGuildBankLog, (MAX_GUILDBANK_TABS or 8) + 1)
        for tab = 1, count do
            local _, _, viewable = GetGuildBankTabInfo and GetGuildBankTabInfo(tab)
            if viewable then queue[#queue + 1] = tab end
        end
        C_Timer.After(.5, nextTab)
        soon()
    end
    local banker = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "GUILDBANKLOG_UPDATE", "GUILDBANK_UPDATE_MONEY", "GUILDBANKBAGSLOTS_CHANGED", "GUILDBANK_UPDATE_TEXT", "GUILDBANK_UPDATE_TABS" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event, kind)
        if event == "PLAYER_ENTERING_WORLD" then
            if not B.noticed then B.noticed = true; C_Timer.After(10, function() pcall(B.RequestNotice) end) end
        elseif event == "GUILDBANKFRAME_OPENED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and banker and kind == banker) then opened()
        elseif event == "GUILDBANKFRAME_CLOSED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" and banker and kind == banker) then B.open = false; waiting = nil
        elseif B.open and event == "GUILDBANKBAGSLOTS_CHANGED" then
            -- The tab asked for has arrived (or an item moved): read again, then ask for the next.
            if waiting then arrived[waiting] = true; waiting = nil; C_Timer.After(.4, nextTab) end
            soon()
        elseif B.open and event == "GUILDBANK_UPDATE_TEXT" then
            local tab = tonumber(kind) or (GetCurrentGuildBankTab and GetCurrentGuildBankTab())
            if tab then texts[tab] = true end
            soon()
        elseif B.open and (event == "GUILDBANKLOG_UPDATE" or event == "GUILDBANK_UPDATE_MONEY" or event == "GUILDBANK_UPDATE_TABS") then soon() end
    end)
end
