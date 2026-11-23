local name, E = ...
local startup = CreateFrame("Frame")
startup:RegisterEvent("ADDON_LOADED")
startup:SetScript("OnEvent", function(self, _, loaded)
    if loaded ~= name then return end
    self:UnregisterEvent("ADDON_LOADED")
    local db, problem = E.Store.Init(EmberlightDB)
    if db then
        EmberlightDB = db
        E.Sync.Start()
        E.Professions.Start()
        E.GuildBank.Start()
        E.GuildSeen.Start()
        E.Presence.Start()
        E.Map.Start()
    end
    E.startupProblem = problem
    E.UI.CreateLauncher()
    if db then E.UI.StartMapPins() end
    if db then C_Timer.NewTicker(30, E.UI.CheckReminders) end
end)
-- A key to open and close the window, set by the member under Key Bindings, AddOns (Bindings.xml).
BINDING_HEADER_EMBERLIGHT = "Emberlight"
BINDING_NAME_EMBERLIGHT_TOGGLE = "Open or close Emberlight"
function EmberlightToggle() E.UI.Toggle() end
-- The addon menu beside the minimap (named in the TOC), for members who hide the crest button.
function Emberlight_OnAddonCompartmentClick() E.UI.Toggle() end
SLASH_EMBERLIGHT1 = "/emberlight"
SlashCmdList.EMBERLIGHT = function(message)
    local code = type(message) == "string" and message:match("^%s*[Vv][Ee][Rr][Ii][Ff][Yy]%s*(.*)$")
    if code then
        local ok, problem = E.Sync.Verify(code)
        DEFAULT_CHAT_FRAME:AddMessage(ok and "Emberlight: proof sent. Guild members online will report it to the website at their next sync." or ("Emberlight: " .. problem))
    elseif type(message) == "string" and message:lower():match("^%s*professions") then
        local choice = message:lower():match("^%s*professions%s+(%a+)")
        if choice == "on" or choice == "off" then
            E.Professions.SetEnabled(choice == "on")
            DEFAULT_CHAT_FRAME:AddMessage(choice == "on" and "Emberlight: your professions will be shared with the guild's website again." or "Emberlight: your professions are no longer shared. The website will drop them after your next Companion sync.")
        end
        for _, line in ipairs(E.Professions.Lines()) do DEFAULT_CHAT_FRAME:AddMessage("Emberlight: " .. line) end
    elseif type(message) == "string" and message:lower():match("^%s*banktip") then
        local choice = message:lower():match("^%s*banktip%s+(%a+)")
        if (choice == "on" or choice == "off") and E.Store.db then E.GuildBank.SetTooltip(choice == "on") end
        DEFAULT_CHAT_FRAME:AddMessage(E.GuildBank.TooltipOn() and "Emberlight: item tooltips say how many the guild bank holds (from your last Companion sync). Type /emberlight banktip off to hide it."
            or "Emberlight: item tooltips no longer show the guild bank. Type /emberlight banktip on to show it again.")
    elseif type(message) == "string" and message:lower():match("^%s*bank") then
        local choice = message:lower():match("^%s*bank%s+(%a+)")
        if choice == "on" or choice == "off" then E.GuildBank.SetEnabled(choice == "on") end
        for _, line in ipairs(E.GuildBank.Lines()) do DEFAULT_CHAT_FRAME:AddMessage("Emberlight: " .. line) end
    elseif type(message) == "string" and message:lower():match("^%s*requests?%s*$") then
        -- Opens the window on Crafting; the slash command is only a shortcut.
        if E.UI.frame and E.UI.frame:IsShown() then E.UI.Go("Crafting")
        else E.UI.Toggle(); if E.UI.frame and E.UI.frame:IsShown() then E.UI.Go("Crafting") end end
    elseif type(message) == "string" and message:lower():match("^%s*map%s+debug%s*$") then
        for _, line in ipairs(E.UI.MapDebugLines()) do DEFAULT_CHAT_FRAME:AddMessage("Emberlight: " .. line) end
    elseif type(message) == "string" and message:lower():match("^%s*map%s*%a*%s*$") then
        local choice = message:lower():match("^%s*map%s+(%a+)")
        if (choice == "on" or choice == "off") and E.Store.db then E.Map.SetEnabled(choice == "on") end
        local on = E.Store.db and E.Store.db.settings.guildMap
        DEFAULT_CHAT_FRAME:AddMessage(on and "Emberlight: the guild map is on. Guildmates who turned it on too see you as a flame on their maps, and you see them. Never shared in dungeons, raids or battlegrounds. Type /emberlight map off to stop."
            or "Emberlight: the guild map is off. Nobody sees you on their map. Type /emberlight map on to share and see guildmates who share.")
    elseif type(message) == "string" and message:lower():match("^%s*test%s+grand%s*$") then
        E.Presence.TestGrand()
    elseif type(message) == "string" and message:lower():match("^%s*test%s+update%s*$") then
        E.Presence.TestUpdate()
    elseif type(message) == "string" and message:lower():match("^%s*help%s*$") then
        for _, line in ipairs({
            "Emberlight commands:",
            "/emberlight: open or close the window",
            "/emberlight map on | off: show yourself and guildmates on the maps, or not (map debug: where the flames sit, for a bug report)",
            "/emberlight verify CODE: prove a character is yours (the website gives the code)",
            "/emberlight professions on | off: share your professions with the website, or not",
            "/emberlight requests: open Crafting",
            "/emberlight banktip on | off: show on item tooltips how many the guild bank holds, or not",
            "/emberlight test grand | test update: see an announcement or the update notice, on your screen only",
            "/emberlight info: version, character and guild, for a bug report",
            "Officers: /emberlight announce TEXT (or grand TEXT) sends an announcement; /emberlight bank on | off reads the guild bank",
        }) do DEFAULT_CHAT_FRAME:AddMessage(line, 1, .82, .35) end
    elseif type(message) == "string" and (message:lower():match("^%s*grand%s") or message:lower():match("^%s*announce%s")) then
        local ok, problem = E.Presence.SendGrand(message:match("^%s*%a+%s+(.*)$"))
        if not ok then DEFAULT_CHAT_FRAME:AddMessage("Emberlight: " .. problem) end
    elseif type(message) == "string" and message:match("^%s*[Ii][Nn][Ff][Oo]%s*$") then
        for _, line in ipairs(E.Client.Info()) do DEFAULT_CHAT_FRAME:AddMessage("Emberlight: " .. line) end
    else
        E.UI.Toggle()
    end
end
