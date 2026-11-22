local _, E = ...
E.Store = {}
local S = E.Store

function S.Init(saved)
    if type(saved) ~= "table" then saved = {} end
    if type(saved.schemaVersion) == "number" and saved.schemaVersion > 3 then
        return nil, "These saved settings belong to a newer Emberlight version. Update the addon to use them."
    end
    saved.settings = type(saved.settings) == "table" and saved.settings or {}
    -- Retire the old local mode without sending its saved examples.
    if saved.settings.demo == true then saved.settings.guildSync = false end
    saved.settings.demo = false
    saved.localData = type(saved.localData) == "table" and saved.localData or {}
    saved.localData.drafts = type(saved.localData.drafts) == "table" and saved.localData.drafts or {}
    saved.schemaVersion = 3
    -- A brand new install has nothing to opt out of yet, so sharing starts on. An upgrade from the
    -- old demo build is a separate, deliberately more cautious path handled above.
    if type(saved.settings.guildSync) ~= "boolean" then saved.settings.guildSync = true end
    -- Guild only since 0.8.0 (owner, 3 October 2026: the guild tests in the WoW: Forever beta).
    -- Party boards remain in the engine for the automated tests; members are moved to their guild,
    -- and sharing stays as they had it.
    saved.settings.shareMode = "guild"
    -- Appearance, chosen in Settings. Anything out of range falls back to the default.
    local st = saved.settings
    if type(st.windowScale) ~= "number" or st.windowScale < .8 or st.windowScale > 1.4 then st.windowScale = 1 end
    if type(st.textSize) ~= "number" or st.textSize < 13 or st.textSize > 19 then st.textSize = 15 end
    st.minimap = type(st.minimap) == "table" and st.minimap or {}
    if type(st.minimap.angle) ~= "number" then st.minimap.angle = 225 end
    st.minimap.hide = st.minimap.hide == true
    -- One line in chat before something the member joined; on unless they switch it off.
    st.reminders = st.reminders ~= false
    -- The guild map (0.9.0, Core/Map.lua): on unless the member switched it off (owner's decision,
    -- 18 November 2026). The first time, one line in chat says so and how to switch it off.
    if type(st.guildMap) ~= "boolean" then st.guildMap = true end
    -- How big the flames are: .75, 1 or 1.35.
    if st.flameSize ~= .75 and st.flameSize ~= 1.35 then st.flameSize = 1 end
    saved.localData.reminded = type(saved.localData.reminded) == "table" and saved.localData.reminded or {}
    -- Character proofs this client saw another member send (/emberlight verify), for the sync
    -- tool to report to the website (since 0.9.x).
    saved.localData.proofs = type(saved.localData.proofs) == "table" and saved.localData.proofs or {}
    -- This account's characters' professions for the website (0.8.13, Core/Professions.lua), read
    -- by the Companion. Shared unless the member typed /emberlight professions off.
    saved.localData.professions = type(saved.localData.professions) == "table" and saved.localData.professions or {}
    if type(st.shareProfessions) ~= "boolean" then st.shareProfessions = true end
    -- The guild bank log for the website, read when an officer opens the guild bank (0.8.14,
    -- Core/GuildBank.lua), read by the Companion. On unless the officer typed /emberlight bank off.
    saved.localData.bankScans = type(saved.localData.bankScans) == "table" and saved.localData.bankScans or {}
    if type(st.readBankLog) ~= "boolean" then st.readBankLog = true end
    -- "Guild bank: 12" on item tooltips (1.0.1, Core/GuildBank.lua): on unless switched off.
    if type(st.bankTooltip) ~= "boolean" then st.bankTooltip = true end
    -- When guildmates were last in game, as the guild window shows it (0.8.15, Core/GuildSeen.lua),
    -- read by the Companion for the officers' activity overview.
    saved.localData.guildSeen = type(saved.localData.guildSeen) == "table" and saved.localData.guildSeen or {}
    saved.guildData = type(saved.guildData) == "table" and saved.guildData or {}
    S.db = saved
    return saved
end

function S.DraftKey()
    return E.Client.Name() .. ":notice"
end
function S.GetDraft()
    local d = S.db.localData.drafts[S.DraftKey()]
    if d == nil then
        local previous = S.db.localData.drafts[E.Client.Name() .. ":local"]
        if type(previous) == "table" and previous.route == 1 then d = previous end
    end
    return type(d) == "table" and d.route == 1 and E.Copy(d) or { category = 1, route = 1, hours = 2, startDays = 0, startHour = 20, startMinute = 0 }
end
function S.CleanDraft(draft)
    local d = {}
    for _, key in ipairs({ "title", "location", "recipient", "body" }) do
        d[key] = E.Clean(draft[key], key == "body" and 1600 or 100)
    end
    -- An official event (4) or an Adventure (1). Journeys, Calls for aid and Gatherings from before
    -- 0.9.3 (2 and 3) are all Adventures now.
    d.category = draft.category == 4 and 4 or 1
    d.route = E.routes[draft.route] and draft.route or 1
    -- How long the notice stays on the board: an hour up to a week.
    local stays = { [1] = true, [2] = true, [4] = true, [12] = true, [24] = true, [72] = true, [168] = true }
    d.hours = stays[draft.hours] and draft.hours or 2
    -- "Keep the place secret": the meeting place is left empty and shown as not told.
    d.secret = draft.secret == true
    if d.secret then d.location = "" end
    d.startDays = math.max(0, math.min(E.AheadDays(d.category), math.floor(tonumber(draft.startDays) or 0)))
    d.startHour = math.max(0, math.min(23, math.floor(tonumber(draft.startHour) or 20)))
    d.startMinute = math.max(0, math.min(59, math.floor(tonumber(draft.startMinute) or 0)))
    d.updated = E.Client.Now()
    return d
end
function S.SaveDraft(draft)
    local d = S.CleanDraft(draft)
    S.db.localData.drafts[S.DraftKey()] = d
    return E.Copy(d)
end
function S.Validate(draft)
    if E.Trim(E.Clean(draft.title, 100)) == "" then return nil, "Enter a subject." end
    if E.Trim(E.Clean(draft.body, 1600)) == "" then return nil, "Enter a message." end
    if draft.route ~= 1 then return nil, "Choose the noticeboard to post a notice." end
    return true
end
function S.Reply(entry, response) return E.Sync.Reply(entry, response) end
function S.Cancel(entry) return E.Sync.Cancel(entry) end
