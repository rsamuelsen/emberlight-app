local _, E = ...
-- The guild bank log for the website (0.8.14, the owner's request, 16 November 2026). When the
-- guild master, a Flame Keeper or an Officer Alt opens the guild bank, the addon reads the bank's
-- transaction logs (gold and items put in and taken out, as the game's own Log tabs show them) and
-- how much gold the bank holds, and keeps them in EmberlightDB.localData.bankScans. The officer's
-- Emberlight Companion uploads them after the game closes; on the website every line waits until an
-- officer approves it (Officers, Vault desk, Bank log).
--
-- Only reading. The logs are asked for (QueryGuildBankLog, as the Log tab does) and read; nothing
-- is clicked, moved, deposited or withdrawn, and nothing is sent to other players. A rank check here
-- is a convenience: the website checks who uploads. "/emberlight bank off" stops it.
local B = {}
E.GuildBank = B
-- Scans kept for the Companion, and lines read per log (the game keeps 25).
B.keep = 10
B.maxLines = 100

local function db()
    local d = E.Store.db and E.Store.db.localData
    if not d then return nil end
    d.bankScans = type(d.bankScans) == "table" and d.bankScans or {}
    return d.bankScans
end
function B.Enabled() return E.Store.db and E.Store.db.settings.readBankLog ~= false end
function B.SetEnabled(on) E.Store.db.settings.readBankLog = on and true or false end

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

-- The logs as the game has them now. Nil when this character cannot read them.
function B.Read()
    if not GetNumGuildBankTabs or not GetNumGuildBankTransactions or not GetGuildBankTransaction then return nil end
    local scan = { at = E.Client.Now(), character = E.Client.Name(), tabs = {}, money = {} }
    if GetGuildBankMoney then
        local ok, copper = pcall(GetGuildBankMoney)
        if ok and type(copper) == "number" and copper >= 0 then scan.bankMoney = math.floor(copper) end
    end
    local lines = 0
    for tab = 1, math.min(tonumber(GetNumGuildBankTabs()) or 0, 12) do
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
    return scan, lines + #scan.money
end

-- Keeps a scan for the Companion, newest first. Another read by the same character within a few
-- minutes (the logs arrive one at a time) replaces the last one.
function B.Save(scan)
    local all = db()
    if not all or not scan then return end
    local last = all[1]
    if type(last) == "table" and last.character == scan.character and scan.at - (tonumber(last.at) or 0) < 300 then
        all[1] = scan
    else
        table.insert(all, 1, scan)
    end
    for i = #all, B.keep + 1, -1 do all[i] = nil end
end

function B.Lines()
    local all = db() or {}
    local last = all[1]
    local lines = { B.Enabled() and "The guild bank log is read when an officer opens the guild bank." or "Reading the guild bank log is switched off. Type /emberlight bank on to switch it on." }
    if type(last) == "table" then
        lines[#lines + 1] = "Last read " .. E.Client.Stamp(tonumber(last.at) or 0) .. " server time by " .. tostring(last.character):match("^[^-]+") .. ". Your Companion sends it to the website when the game is closed."
    end
    return lines
end

function B.Start()
    if B.frame or not CreateFrame then return end
    local frame = CreateFrame("Frame")
    B.frame = frame
    local pending, told = false, false
    local function read()
        pending = false
        if not B.open or not B.Enabled() or not B.Officer() then return end
        local scan, count = B.Read()
        if not scan then return end
        B.Save(scan)
        if not told and count > 0 then
            told = true
            DEFAULT_CHAT_FRAME:AddMessage("Emberlight: guild bank log read (" .. count .. " lines). Your Companion sends it to the website, where officers approve it.")
        end
    end
    local function soon()
        if pending then return end
        pending = true
        C_Timer.After(1, function() pcall(read) end)
    end
    local function opened()
        if B.open then return end
        B.open, told = true, false
        if not B.Enabled() or not B.Officer() or not QueryGuildBankLog then return end
        -- Ask for every tab's log and the gold log, the way the Log tab does, then read them.
        for tab = 1, math.min(tonumber(GetNumGuildBankTabs and GetNumGuildBankTabs()) or 0, 12) do pcall(QueryGuildBankLog, tab) end
        pcall(QueryGuildBankLog, (MAX_GUILDBANK_TABS or 8) + 1)
        soon()
    end
    local banker = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
    for _, event in ipairs({ "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "GUILDBANKLOG_UPDATE", "GUILDBANK_UPDATE_MONEY" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event, kind)
        if event == "GUILDBANKFRAME_OPENED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and banker and kind == banker) then opened()
        elseif event == "GUILDBANKFRAME_CLOSED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" and banker and kind == banker) then B.open = false
        elseif B.open and (event == "GUILDBANKLOG_UPDATE" or event == "GUILDBANK_UPDATE_MONEY") then soon() end
    end)
end
