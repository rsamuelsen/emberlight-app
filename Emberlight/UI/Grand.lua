local _, E = ...
local U = E.UI
local C = U.colors
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end
-- The officers' announcement (Core/Presence.lua): a crimson banner with the phoenix, high on the
-- screen for fifteen seconds. It slides in with a flash of gold and a fanfare, and a click puts
-- it away. Below it, the sheet an officer writes it on.
local media = "Interface\\AddOns\\Emberlight\\Media\\"
local GOLD, IVORY = { 1, .84, .46 }, { 1, .96, .86 }
local SLIDE, FLASH = .55, .9

local function animate(b, elapsed)
    b.age = (b.age or 0) + elapsed
    local rise = math.min(1, b.age / SLIDE)
    rise = 1 - (1 - rise) * (1 - rise)
    b:SetAlpha(rise)
    b:ClearAllPoints(); b:SetPoint("TOP", 0, -150 + (1 - rise) * 46)
    b.flash:SetAlpha(math.max(0, .5 * (1 - b.age / FLASH)))
    if b.age >= math.max(SLIDE, FLASH) then b:SetScript("OnUpdate", nil) end
end

-- The quieter choice (Settings, 1.0.4): a small card in the top left corner, away from the middle
-- of the screen, for eight seconds. A click puts it away.
local function showToast(text, from)
    local t = U.grandToast
    if not t then
        t = U.Panel(UIParent, 340, 96, { .10, .035, .05, .94 })
        t:SetBackdropBorderColor(unpack(GOLD))
        t:SetPoint("TOPLEFT", 24, -170)
        t:SetFrameStrata("HIGH")
        t:EnableMouse(true)
        t.crest = t:CreateTexture(nil, "ARTWORK")
        t.crest:SetSize(44, 44); t.crest:SetPoint("TOPLEFT", 12, -12)
        t.crest:SetTexture(media .. "Crest64.tga")
        t.from = U.FitText(U.Text(t, "", 14, GOLD, nil, "caps"), 262, 18, false)
        t.from:SetPoint("TOPLEFT", 66, -10)
        t.text = U.FitText(U.Text(t, "", 15, IVORY, nil, "game"), 262, 60, true)
        t.text:SetPoint("TOPLEFT", 66, -30)
        t:SetScript("OnMouseDown", function(self) self:Hide() end)
        U.grandToast = t
    end
    t.from:SetText("From " .. (from ~= "" and from or "an officer"))
    t.text:SetText(text)
    t:SetAlpha(1); t:Show()
    if t.timer then t.timer:Cancel() end
    t.timer = C_Timer.NewTimer(8, function() t:Hide(); t.timer = nil end)
end

function U.ShowGrand(text, from)
    local st = E.Store.db and E.Store.db.settings
    local sound = not st or st.grandSound ~= false
    if st and st.grandStyle == "toast" then
        if U.grandBanner then U.grandBanner:Hide() end
        showToast(text, from)
        if sound and PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE or 878) end
        return
    end
    if U.grandToast then U.grandToast:Hide() end
    local b = U.grandBanner
    if not b then
        b = CreateFrame("Frame", nil, UIParent)
        b:SetSize(640, 160)
        b:SetPoint("TOP", 0, -150)
        b:SetFrameStrata("HIGH")
        b:EnableMouse(true)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints(); b.bg:SetTexture(media .. "AnnounceBanner.tga")
        -- The guild's own phoenix, the one in the title bar, not a painted stand-in.
        b.crest = b:CreateTexture(nil, "ARTWORK")
        b.crest:SetSize(112, 112); b.crest:SetPoint("TOPRIGHT", -38, -24)
        b.crest:SetTexture(media .. "Crest128.tga")
        b.flash = b:CreateTexture(nil, "OVERLAY")
        b.flash:SetAllPoints(); b.flash:SetColorTexture(1, .86, .5, 1); b.flash:SetAlpha(0)
        b.from = U.FitText(U.Text(b, "", 15, GOLD, nil, "caps"), 440, 20, false)
        b.from:SetPoint("TOPLEFT", 36, -26); b.from:SetJustifyH("CENTER")
        b.text = U.FitText(U.Text(b, "", 22, IVORY, nil, "game"), 440, 84, true)
        b.text:SetPoint("TOPLEFT", 36, -54); b.text:SetJustifyH("CENTER")
        b:SetScript("OnMouseDown", function(self) self:Hide() end)
        U.grandBanner = b
    end
    b.from:SetText("A announcement from " .. (from ~= "" and from or "an officer"))
    b.text:SetText(text)
    b.age = 0
    b:SetAlpha(0); b:Show()
    b:SetScript("OnUpdate", animate)
    -- The quest-complete fanfare, not the raid warning horn (the owner, 19 November).
    if sound and PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE or 878) end
    if b.timer then b.timer:Cancel() end
    b.timer = C_Timer.NewTimer(15, function() b:Hide(); b.timer = nil end)
end

function U.OpenGrand(text)
    local s = U.grandSheet
    if not s then
        s = U.Paper(U.frame, 520, 238)
        s:SetPoint("CENTER"); s:SetFrameLevel(U.frame:GetFrameLevel() + 40); s:EnableMouse(true)
        at(U.Text(s, "Announcement", 16, C.brown, nil, "caps"), 24, -20)
        at(U.FitText(U.Text(s, "Appears in guild chat and on screen for guildmates using Emberlight 0.9.0 or later. You can send one message per minute.", 14, C.paperMuted), 472, 40, true), 24, -42)
        s.field = U.Field(s, "Message (up to " .. E.Presence.grandLimit .. " letters)", 24, -90, 472, 56, E.Presence.grandLimit, true)
        -- Asked once more before it goes, since it lands on everyone's screen at once.
        s.send = at(U.Button(s, "Send to the guild", 190, function()
            local text = E.Trim(E.Clean(s.field:GetText(), E.Presence.grandLimit))
            if text == "" then U.Status("Write the message first."); return end
            s:Hide()
            -- The sheet has room for a few lines: the start of the message is enough to recognise it.
            local preview = #text > 90 and (text:sub(1, 87):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "...") or text
            U.Confirm("Send to everyone online? It shows on their screens and in guild chat.\n\"" .. preview .. "\"", "Send to everyone", function()
                local ok, problem = E.Presence.SendGrand(text)
                if ok then U.Status("Announcement sent.") else U.Status(problem); U.OpenGrand(text) end
            end, "Back", function() U.OpenGrand(text) end)
        end, "seal"), 24, -184)
        at(U.Button(s, "Cancel", 120, function() s:Hide() end), 224, -184)
        U.grandSheet = s
    end
    s.field:SetText(text or "")
    s:Show()
    s.field:SetFocus()
end
