local _, E = ...
local U = E.UI
local C = U.colors
local function at(widget, x, y) widget:SetPoint("TOPLEFT", x, y); return widget end
-- The officers' grand message (Core/Presence.lua): a parchment banner high on the screen for
-- fifteen seconds, which a click puts away, and the sheet an officer writes it on.

function U.ShowGrand(text, from)
    local b = U.grandBanner
    if not b then
        b = U.Paper(UIParent, 620, 128)
        b:SetPoint("TOP", 0, -150)
        b:SetFrameStrata("HIGH")
        b:EnableMouse(true)
        b.from = U.FitText(U.Text(b, "", 14, C.brown, nil, "caps"), 572, 18, false)
        b.from:SetPoint("TOP", 0, -16); b.from:SetJustifyH("CENTER")
        b.text = U.FitText(U.Text(b, "", 20, C.ink, nil, "game"), 572, 78, true)
        b.text:SetPoint("TOP", 0, -40); b.text:SetJustifyH("CENTER")
        b:SetScript("OnMouseDown", function(self) self:Hide() end)
        U.grandBanner = b
    end
    b.from:SetText("A message from " .. (from ~= "" and from or "an officer"))
    b.text:SetText(text)
    b:Show()
    if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then pcall(PlaySound, SOUNDKIT.RAID_WARNING) end
    if b.timer then b.timer:Cancel() end
    b.timer = C_Timer.NewTimer(15, function() b:Hide(); b.timer = nil end)
end

function U.OpenGrand(text)
    local s = U.grandSheet
    if not s then
        s = U.Paper(U.frame, 520, 238)
        s:SetPoint("CENTER", 91, 0); s:SetFrameLevel(U.frame:GetFrameLevel() + 40); s:EnableMouse(true)
        at(U.Text(s, "Grand message", 16, C.brown, nil, "caps"), 24, -20)
        at(U.FitText(U.Text(s, "Shows large on the screen of every guildmate online with Emberlight " .. E.version .. " or newer, and in guild chat for everyone. One a minute at most.", 14, C.paperMuted), 472, 40, true), 24, -42)
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
                if ok then U.Status("Grand message sent.") else U.Status(problem); U.OpenGrand(text) end
            end, "Back", function() U.OpenGrand(text) end)
        end, "seal"), 24, -184)
        at(U.Button(s, "Cancel", 120, function() s:Hide() end), 224, -184)
        U.grandSheet = s
    end
    s.field:SetText(text or "")
    s:Show()
    s.field:SetFocus()
end
