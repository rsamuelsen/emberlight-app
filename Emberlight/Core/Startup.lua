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
    end
    E.startupProblem = problem
    E.UI.CreateLauncher()
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
    else
        E.UI.Toggle()
    end
end
