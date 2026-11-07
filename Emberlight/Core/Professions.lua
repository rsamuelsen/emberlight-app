local _, E = ...
-- Professions for the website (0.8.13, the owner's request, 7 November 2026). The addon reads the
-- character's professions with their levels ("Mining 64 / 125") at login and whenever the game
-- says the skills changed, and the recipes the character knows whenever a profession window is
-- open. It only writes them into EmberlightDB.localData.professions; the member's Emberlight
-- Companion uploads them after the game closes, for the member's own verified characters, and
-- the website shows them on its Professions page. With sharing on, the character's levels and
-- recipe numbers are also told to guildmates online (see "Shared through guildmates" below).
--
-- Only reading: no window is opened, no filter or header is changed. A window with a filter on
-- (or a collapsed header) shows fewer recipes, so recipes are only ever added; they go when the
-- character no longer has the profession. A member who does not want this types
-- "/emberlight professions off": the website is then told the character lists none.
--
-- Shared through guildmates (same version, the owner's request): a member without the Companion
-- still reaches the website. With sharing on, the addon tells guildmates online its character's
-- levels and recipe numbers over the guild addon channel (kinds "F" and "G" in Core/Sync.lua);
-- their addons keep it in localData.relayedProfessions and their Companions upload it
-- (POST /v1/professions/relayed). The server stores each share once and lets the member's own
-- Companion win. Only this character's own data is ever sent; nothing about anyone else.
--
-- Crafting requests (same version): members ask on the website for something a guild crafter
-- knows. The Companion writes the open ones this member can make, or asked for, into
-- Emberlight_Data/Crafting.lua (global EmberlightCrafting) at each sync. The addon only shows
-- them: the Crafting place in the window lists them (UI/Crafting.lua), a new one is mentioned
-- once in chat, and opening a profession window says how many are waiting for it. Taking or finishing one is on the website.
local P = {}
E.Professions = P

-- The website's names, in English. The game names them in the client's language; the spell of
-- the same name gives that word on any client, and the table below covers the rest.
P.skills = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism", "Leatherworking", "Mining", "Skinning", "Tailoring", "Cooking", "First Aid", "Fishing" }
P.noRecipes = { Herbalism = true, Skinning = true, Fishing = true }
P.maxRecipes = 600
P.maxReagents = 8
local spells = { Alchemy = 2259, Blacksmithing = 2018, Enchanting = 7411, Engineering = 4036, Leatherworking = 2108, Mining = 2575, Skinning = 8613, Tailoring = 3908, Cooking = 2550, ["First Aid"] = 3273, Fishing = 7620 }
local names = {
    -- German, French, Spanish and Italian clients, the ones EU members are most likely to play.
    Alchemy = { "Alchimie", "Alquimia", "Alchimia" },
    Blacksmithing = { "Schmiedekunst", "Forge", "Herrería", "Forgiatura" },
    Enchanting = { "Verzauberkunst", "Enchantement", "Encantamiento", "Incantamento" },
    Engineering = { "Ingenieurskunst", "Ingénierie", "Ingeniería", "Ingegneria" },
    Herbalism = { "Kräuterkunde", "Herboristerie", "Herboristería", "Erbalismo" },
    Leatherworking = { "Lederverarbeitung", "Travail du cuir", "Peletería", "Conciatura" },
    Mining = { "Bergbau", "Minage", "Minería", "Estrazione" },
    Skinning = { "Kürschnerei", "Dépeçage", "Desuello", "Scuoiatura" },
    Tailoring = { "Schneiderei", "Couture", "Sastrería", "Sartoria" },
    Cooking = { "Kochkunst", "Cuisine", "Cocina", "Cucina" },
    ["First Aid"] = { "Erste Hilfe", "Secourisme", "Primeros auxilios", "Primo soccorso" },
    Fishing = { "Angeln", "Pêche", "Pesca" },
}
-- Retail's skill line numbers (GetProfessionInfo), so the owner can try this on Retail too.
local lines = { [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering", [182] = "Herbalism", [165] = "Leatherworking", [186] = "Mining", [393] = "Skinning", [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid", [356] = "Fishing" }

local english
-- The website's name for a profession the game names `name`, or nil for anything else (weapon
-- skills, languages, riding, a hunter's beast training).
function P.English(name)
    if type(name) ~= "string" then return nil end
    if not english then
        english = {}
        for _, skill in ipairs(P.skills) do english[skill:lower()] = skill end
        for skill, list in pairs(names) do for _, word in ipairs(list) do english[word:lower()] = skill end end
        local spellName = (C_Spell and C_Spell.GetSpellName) or (GetSpellInfo and function(id) return (GetSpellInfo(id)) end)
        if spellName then
            for skill, id in pairs(spells) do
                local ok, word = pcall(spellName, id)
                if ok and type(word) == "string" and word ~= "" then english[word:lower()] = skill end
            end
        end
    end
    return english[E.Trim(name):lower()]
end

local function db()
    local d = E.Store.db and E.Store.db.localData
    if not d then return nil end
    d.professions = type(d.professions) == "table" and d.professions or {}
    return d.professions
end
local function me() return E.Client.Canonical(E.Client.Name()) end
local function entry(create)
    local all, key = db(), me()
    if not all or not key or key:find("^your_character") then return nil end
    if create and type(all[key]) ~= "table" then all[key] = { skills = {}, recipes = {}, at = 0 } end
    local e = all[key]
    if type(e) ~= "table" then return nil end
    e.skills = type(e.skills) == "table" and e.skills or {}
    e.recipes = type(e.recipes) == "table" and e.recipes or {}
    return e
end
function P.Enabled() return E.Store.db and E.Store.db.settings.shareProfessions ~= false end

-- The character's professions as the game lists them: { [english] = { rank, max } }, and whether
-- the list was whole (a collapsed header hides what is under it).
function P.ReadSkills()
    local found, complete = {}, true
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, header, expanded, rank, _, _, max = GetSkillLineInfo(i)
            if header then
                if not expanded then complete = false end
            else
                local skill = P.English(name)
                if skill and type(rank) == "number" and type(max) == "number" and max > 0 then found[skill] = { rank = rank, max = max } end
            end
        end
        return found, complete
    end
    if GetProfessions and GetProfessionInfo then
        -- GetProfessions gives nil for a slot not taken (no second profession, no fishing), so
        -- every slot is checked: ipairs would stop at the first gap and miss Cooking and Fishing.
        local slots = { GetProfessions() }
        for i = 1, select("#", GetProfessions()) do
            local index = slots[i]
            local name, _, rank, max, _, _, line
            if index then name, _, rank, max, _, _, line = GetProfessionInfo(index) end
            local skill = lines[line] or P.English(name)
            if skill and type(rank) == "number" and type(max) == "number" and max > 0 then found[skill] = { rank = rank, max = max } end
        end
        return found, true
    end
    return nil
end

-- A change also redraws the Crafting place if it is open (the owner, 7 November 2026: it kept
-- saying "Open its window once" until the page was opened again). Once, a moment later.
local redraw
local function changed(e)
    e.at = E.Client.Now()
    if redraw or not (C_Timer and C_Timer.After) then return end
    redraw = true
    C_Timer.After(.2, function()
        redraw = nil
        local U = E.UI
        if U and U.craftPage and U.craftPage:IsShown() and U.RefreshCrafting then pcall(U.RefreshCrafting) end
    end)
end

-- Record the skill list. Only a real change moves the date, so the Companion uploads only then.
function P.ScanSkills()
    if not P.Enabled() then return end
    local found, complete = P.ReadSkills()
    if not found then return end
    local e = entry(true)
    if not e then return end
    local dirty = e.hidden == true
    e.hidden = nil
    for skill, s in pairs(found) do
        local old = e.skills[skill]
        if type(old) ~= "table" or old.rank ~= s.rank or old.max ~= s.max then e.skills[skill] = s; dirty = true end
    end
    if complete then
        for skill in pairs(e.skills) do
            if not found[skill] then e.skills[skill] = nil; e.recipes[skill] = nil; dirty = true end
        end
    end
    -- A partial list never removes anything, and the server is told it was partial.
    if e.complete ~= complete then e.complete = complete; dirty = true end
    if dirty then changed(e) end
end

local function number(link, kind)
    return type(link) == "string" and tonumber(link:match(kind .. ":(%d+)")) or nil
end

-- A recipe's materials as the window listed them, all or none: a half list (an item the game had
-- not loaded yet) is dropped and read again next time the window opens.
function P.Reagents(list)
    if type(list) ~= "table" or #list == 0 or #list > P.maxReagents then return nil end
    local out = {}
    for _, g in ipairs(list) do
        local name = type(g) == "table" and type(g.name) == "string" and E.Trim(E.Clean(g.name, 100)) or ""
        local count = type(g) == "table" and tonumber(g.count)
        if name == "" or not count or count < 1 or count > 100 or count % 1 ~= 0 then return nil end
        out[#out + 1] = { name = name, item = g.item, count = count }
    end
    return out
end
function P.ReagentText(list)
    if type(list) ~= "table" then return "" end
    local parts = {}
    for _, g in ipairs(list) do parts[#parts + 1] = tostring(g.item or g.name) .. "x" .. tostring(g.count) end
    return table.concat(parts, ",")
end

-- Add the recipes a profession window shows. `skillName`, `rank` and `max` are the window's own.
function P.AddRecipes(skillName, rank, max, list)
    if not P.Enabled() then return end
    local skill = P.English(skillName)
    if not skill or P.noRecipes[skill] then return end
    local e = entry(true)
    if not e then return end
    local dirty = false
    if type(rank) == "number" and type(max) == "number" and max > 0 then
        local old = e.skills[skill]
        if type(old) ~= "table" or old.rank ~= rank or old.max ~= max then e.skills[skill] = { rank = rank, max = max }; dirty = true end
    end
    if not e.skills[skill] then return end
    local known = type(e.recipes[skill]) == "table" and e.recipes[skill] or {}
    e.recipes[skill] = known
    local count = 0
    for _ in pairs(known) do count = count + 1 end
    for _, r in ipairs(list) do
        local name = E.Trim(E.Clean(r.name, 100))
        if name ~= "" then
            local key = r.item and ("i:" .. r.item) or r.spell and ("s:" .. r.spell) or ("n:" .. name:lower())
            local reagents = P.Reagents(r.reagents)
            if not known[key] and count < P.maxRecipes then
                known[key] = { name = name, item = r.item, spell = r.spell, reagents = reagents }
                count = count + 1
                dirty = true
            elseif known[key] then
                if known[key].name ~= name then known[key].name = name; dirty = true end
                if reagents and P.ReagentText(reagents) ~= P.ReagentText(known[key].reagents) then known[key].reagents = reagents; dirty = true end
            end
        end
    end
    if dirty then changed(e) end
end

-- The open profession window (the classic trade skill window), unless it shows someone else's.
function P.ScanTradeSkill()
    if not GetTradeSkillLine or not GetNumTradeSkills or not GetTradeSkillInfo then return end
    if (IsTradeSkillLinked and IsTradeSkillLinked()) or (IsTradeSkillGuild and IsTradeSkillGuild()) then return end
    local name, rank, max = GetTradeSkillLine()
    local list = {}
    for i = 1, GetNumTradeSkills() do
        local recipe, kind = GetTradeSkillInfo(i)
        if type(recipe) == "string" and kind ~= "header" and kind ~= "subheader" then
            local item = number(GetTradeSkillItemLink and GetTradeSkillItemLink(i), "item")
            local spell = number(GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(i), "enchant")
            local reagents = {}
            for j = 1, (GetTradeSkillNumReagents and GetTradeSkillNumReagents(i) or 0) do
                local reagent, _, count = GetTradeSkillReagentInfo(i, j)
                reagents[j] = { name = reagent, count = count, item = number(GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i, j), "item") }
            end
            list[#list + 1] = { name = recipe, item = item, spell = spell, reagents = reagents }
        end
    end
    P.AddRecipes(name, rank, max, list)
    P.WindowNotice(name)
end

-- WoW: Forever (and Retail) read the open profession window through C_TradeSkillUI. The owner's
-- check in game on 7 November 2026: Forever has no GetTradeSkill* functions, but it has
-- GetAllRecipeIDs, GetRecipeInfo, GetRecipeSchematic and GetBaseProfessionInfo. The list is only
-- right while the window is open (closed, it still answers with an old list), and it lists every
-- recipe of that profession, learned or not, so only learned ones are kept. Never opens a window.
function P.ScanModern()
    local T = C_TradeSkillUI
    if not T or not T.GetAllRecipeIDs or not T.GetRecipeInfo or not T.GetBaseProfessionInfo then return end
    if not P.windowOpen or (T.IsTradeSkillReady and not T.IsTradeSkillReady()) then return end
    -- Someone else's profession (a link, the guild list, an NPC): not this character's.
    for _, check in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting", "IsRuneforging" }) do
        if T[check] and T[check]() then return end
    end
    local prof = T.GetBaseProfessionInfo()
    if type(prof) ~= "table" then return end
    local skill = lines[prof.professionID] or P.English(prof.professionName)
    if not skill then return end
    local itemName = (C_Item and C_Item.GetItemNameByID) or (GetItemInfo and function(id) return (GetItemInfo(id)) end)
    local list = {}
    for _, id in ipairs(T.GetAllRecipeIDs() or {}) do
        local info = T.GetRecipeInfo(id)
        if type(info) == "table" and info.learned and type(info.name) == "string" and not info.isRecraft then
            local item, reagents = nil, {}
            local ok, schematic = pcall(T.GetRecipeSchematic, id, false)
            if ok and type(schematic) == "table" then
                item = tonumber(schematic.outputItemID)
                for _, slot in ipairs(type(schematic.reagentSlotSchematics) == "table" and schematic.reagentSlotSchematics or {}) do
                    local first = type(slot.reagents) == "table" and slot.reagents[1]
                    if slot.required ~= false and type(first) == "table" and first.itemID then
                        local name = itemName and itemName(first.itemID)
                        -- Not loaded yet: ask the game, and the materials are read next time.
                        if not name and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, first.itemID) end
                        reagents[#reagents + 1] = { name = name, count = slot.quantityRequired, item = first.itemID }
                    end
                end
            end
            -- A recipe's number is its spell (Wowhead /forever/spell=); what it makes is the item.
            list[#list + 1] = { name = info.name, item = item, spell = tonumber(id), reagents = reagents }
        end
    end
    P.AddRecipes(skill, prof.skillLevel, prof.maxSkillLevel, list)
    P.WindowNotice(skill)
end

-- Enchanting's own window on the classic client (the craft window).
function P.ScanCraft()
    if not GetCraftDisplaySkillLine or not GetNumCrafts or not GetCraftInfo then return end
    local name, rank, max = GetCraftDisplaySkillLine()
    if not name then return end
    local list = {}
    for i = 1, GetNumCrafts() do
        local recipe, _, kind = GetCraftInfo(i)
        if type(recipe) == "string" and kind ~= "header" then
            local reagents = {}
            for j = 1, (GetCraftNumReagents and GetCraftNumReagents(i) or 0) do
                local reagent, _, count = GetCraftReagentInfo(i, j)
                reagents[j] = { name = reagent, count = count, item = number(GetCraftReagentItemLink and GetCraftReagentItemLink(i, j), "item") }
            end
            list[#list + 1] = { name = recipe, spell = number(GetCraftItemLink and GetCraftItemLink(i), "enchant"), reagents = reagents }
        end
    end
    P.AddRecipes(name, rank, max, list)
    P.WindowNotice(name)
end

-- This character's professions as recorded: { skill, rank, max, recipes }, in the website's order.
function P.Mine()
    local out = {}
    if not P.Enabled() then return out end
    pcall(P.ScanSkills)
    local e = entry(false)
    for _, skill in ipairs(P.skills) do
        local s = e and e.skills[skill]
        if type(s) == "table" then
            local count = 0
            for _ in pairs(type(e.recipes[skill]) == "table" and e.recipes[skill] or {}) do count = count + 1 end
            out[#out + 1] = { skill = skill, rank = s.rank, max = s.max, recipes = count }
        end
    end
    return out
end

-- "/emberlight professions": what this character has recorded, and on or off.
function P.Lines()
    if not P.Enabled() then return { "Professions are not shared with the website. Type /emberlight professions on to share them." } end
    local out = {}
    for _, s in ipairs(P.Mine()) do
        local recipes = P.noRecipes[s.skill] and "" or s.recipes > 0 and string.format(", %d recipes", s.recipes) or ", open its window once to read the recipes"
        out[#out + 1] = string.format("%s %d / %d%s", s.skill, s.rank, s.max, recipes)
    end
    if #out == 0 then out[1] = "This character has no professions the website lists yet." end
    out[#out + 1] = "The Emberlight Companion sends these to the website after you close the game."
    return out
end
-- The crafting requests the Companion last downloaded. The file is local and could be damaged or
-- edited, so only plain text within the sync tool's own limits is taken from it.
P.craftingFormat = 1
local function plain(v, limit)
    if type(v) ~= "string" or v == "" or #v > limit then return nil end
    local clean = E.Clean(v, limit)
    return clean ~= "" and clean or nil
end
function P.Requests()
    local data = _G.EmberlightCrafting
    if type(data) ~= "table" or data.format ~= P.craftingFormat or type(data.requests) ~= "table" then return nil end
    local out = {}
    for _, r in ipairs(data.requests) do
        if #out >= 100 then break end
        local id, quantity = type(r) == "table" and tonumber(r.id), type(r) == "table" and tonumber(r.quantity)
        local skill, recipe, who = id and plain(r.skill, 20), id and plain(r.recipe, 100), id and plain(r.forCharacter, 60)
        if skill and recipe and who and quantity and quantity >= 1 and quantity <= 20 and (r.status == "open" or r.status == "claimed") then
            local can = {}
            for _, name in ipairs(type(r.canMakeWith) == "table" and r.canMakeWith or {}) do
                local n = plain(name, 60)
                if n and #can < 10 then can[#can + 1] = n end
            end
            out[#out + 1] = { id = id, skill = skill, recipe = recipe, quantity = quantity, forCharacter = who, note = plain(r.note, 300),
                status = r.status, crafter = plain(r.crafter, 60), mine = r.mine == true, takenByMe = r.takenByMe == true, canMakeWith = can }
        end
    end
    return { generated = tonumber(data.generated), requests = out }
end

-- Requests this member could take: open, not their own, and one of their characters knows it.
local function forMe(r) return r.status == "open" and not r.mine and #r.canMakeWith > 0 end
local function what(r) return (r.quantity > 1 and (r.quantity .. " x ") or "") .. r.recipe end

-- How many open requests this member could make (the rail's count on Crafting).
function P.WaitingForMe()
    local data = P.Requests()
    local count = 0
    for _, r in ipairs(data and data.requests or {}) do if forMe(r) then count = count + 1 end end
    return count
end

-- "/emberlight requests" (kept as a shortcut; the Crafting place in the window shows the same).
function P.RequestLines()
    local data = P.Requests()
    if not data then return { "No crafting requests here yet. The Emberlight Companion brings them in when it syncs." } end
    local mine, open, taken = {}, {}, {}
    for _, r in ipairs(data.requests) do
        if r.mine then
            mine[#mine + 1] = string.format("You asked for %s for %s: %s.", what(r), r.forCharacter, r.crafter and (r.crafter .. " is making it") or "waiting for a crafter")
        elseif r.takenByMe then
            taken[#taken + 1] = string.format("You are making %s for %s.%s", what(r), r.forCharacter, r.note and (" Note: " .. r.note) or "")
        elseif forMe(r) then
            open[#open + 1] = string.format("%s (%s) for %s, you can make it with %s.%s", what(r), r.skill, r.forCharacter, table.concat(r.canMakeWith, ", "), r.note and (" Note: " .. r.note) or "")
        end
    end
    local out = {}
    for _, list in ipairs({ taken, open, mine }) do for _, line in ipairs(list) do out[#out + 1] = line end end
    if #out == 0 then out[1] = "No open crafting requests for you right now." end
    out[#out + 1] = "To take one or mark it done, use Professions on the guild's website. This list is from your last sync."
    return out
end

-- Once per request: a short line in chat when a new one arrives that this member can make.
function P.NewRequestNotice()
    local data = P.Requests()
    local settings = E.Store.db and E.Store.db.settings
    if not data or not settings then return end
    local seen = type(settings.craftSeen) == "table" and settings.craftSeen or {}
    local keep, fresh = {}, 0
    for _, r in ipairs(data.requests) do
        if forMe(r) then
            if not seen[r.id] then fresh = fresh + 1 end
            keep[r.id] = true
        end
    end
    settings.craftSeen = keep
    if fresh > 0 and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("Emberlight: %s you can make. Open Emberlight and choose Crafting to see %s.", fresh == 1 and "A guild member asked for something" or (fresh .. " new crafting requests"), fresh == 1 and "it" or "them"))
    end
end

-- Once per profession and session: how many open requests this window's profession has.
local told = {}
function P.WindowNotice(windowName)
    local skill = P.English(windowName)
    if not skill or told[skill] then return end
    local data = P.Requests()
    if not data then return end
    local count = 0
    for _, r in ipairs(data.requests) do if forMe(r) and r.skill == skill then count = count + 1 end end
    told[skill] = true
    if count > 0 and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("Emberlight: %d %s for %s %s waiting. Open Emberlight and choose Crafting to see %s.", count, count == 1 and "request" or "requests", skill, count == 1 and "is" or "are", count == 1 and "it" or "them"))
    end
end

-- Sharing with guildmates ---------------------------------------------------------------------
P.shareEvery = 3600      -- send again at most this often while nothing changed (late arrivals)
P.shareChangedAfter = 900 -- and after a change, not more often than this
P.maxRelayed = 200
P.relayDays = 14
local KEYS_PER_PART = 1400 -- bytes of recipe numbers in one message (the protocol's field limit is 1600)

-- The messages that share this character's professions: one "F" with the levels, then "G" parts
-- with each profession's recipe numbers ("i2661,s7418"). A hidden entry shares an empty list, so
-- the website drops it too.
function P.ShareMessages(guild)
    local e = entry(false)
    if not e or type(e.at) ~= "number" or e.at <= 0 then return {} end
    local skills = {}
    if not e.hidden then
        for _, skill in ipairs(P.skills) do
            local s = e.skills[skill]
            if type(s) == "table" then skills[#skills + 1] = string.format("%s=%d/%d", skill, s.rank, s.max) end
        end
    end
    local at = tostring(e.at)
    local out = { { fields = { "F", guild, at, e.complete == false and "0" or "1", table.concat(skills, ",") }, key = "F:" .. at } }
    if e.hidden then return out end
    for _, skill in ipairs(P.skills) do
        local known = e.skills[skill] and type(e.recipes[skill]) == "table" and e.recipes[skill]
        if known then
            local keys = {}
            for _, r in pairs(known) do
                if type(r) == "table" and (r.item or r.spell) then keys[#keys + 1] = r.item and ("i" .. r.item) or ("s" .. r.spell) end
            end
            table.sort(keys)
            local parts, current = {}, {}
            local size = 0
            for _, k in ipairs(keys) do
                if size + #k + 1 > KEYS_PER_PART then parts[#parts + 1] = table.concat(current, ","); current = {}; size = 0 end
                current[#current + 1] = k; size = size + #k + 1
            end
            if #current > 0 then parts[#parts + 1] = table.concat(current, ",") end
            for i, payload in ipairs(parts) do
                out[#out + 1] = { fields = { "G", guild, at, skill, tostring(i), tostring(#parts), payload }, key = "G:" .. skill .. ":" .. i .. ":" .. at }
            end
        end
    end
    return out
end

-- Send this character's professions to guildmates online: at login, after a change (not too
-- often), and once an hour so members who log in later hear them too.
function P.Share(force)
    local N = E.Sync
    if not N or not N.Ready() or not E.Store.db then return false end
    local e = entry(false)
    if not e or type(e.at) ~= "number" or e.at <= 0 then return false end
    -- Sharing switched off and the empty list already sent: nothing more to say.
    if e.hidden and P.sharedFor == e.at then return false end
    local now = E.Client.Now()
    local due = force or not P.sharedAt or (P.sharedFor ~= e.at and now - P.sharedAt >= P.shareChangedAfter) or now - P.sharedAt >= P.shareEvery
    if not due then return false end
    local _, _, me = N.Context()
    if not me then return false end
    for _, m in ipairs(P.ShareMessages(N.guild)) do
        if not N.Queue(m.fields, m.key) then return false end
    end
    P.sharedAt, P.sharedFor = now, e.at
    return true
end

local function relayed()
    local d = E.Store.db and E.Store.db.localData
    if not d then return nil end
    d.relayedProfessions = type(d.relayedProfessions) == "table" and d.relayedProfessions or {}
    return d.relayedProfessions
end

-- A recipe's name in this game, if it knows the item or spell yet (nil otherwise; the website
-- then takes the name another member's game gave it).
local function recipeName(item, spell)
    local ok, name
    if item then
        local get = (C_Item and C_Item.GetItemNameByID) or (GetItemInfo and function(id) return (GetItemInfo(id)) end)
        if get then ok, name = pcall(get, item) end
    elseif spell then
        local get = (C_Spell and C_Spell.GetSpellName) or (GetSpellInfo and function(id) return (GetSpellInfo(id)) end)
        if get then ok, name = pcall(get, spell) end
    end
    if ok and type(name) == "string" then
        name = E.Trim(E.Clean(name, 100))
        if name ~= "" then return name end
    end
    return nil
end

-- A guildmate's share (kinds "F" and "G"), from `sender` (WoW names the sender, so nobody can
-- share for someone else). The newest share per character is kept; the same one again changes
-- nothing, so it is never stored twice.
function P.Receive(fields, sender)
    local all = relayed()
    if not all or type(sender) ~= "string" then return false end
    local now = E.Client.Now()
    local at = tonumber(fields[3])
    if not at or at % 1 ~= 0 or at > now + 300 or at < now - P.relayDays * 86400 then return false end
    local old = all[sender]
    if fields[1] == "F" and #fields == 5 then
        if type(old) == "table" and type(old.at) == "number" and old.at >= at then return false end
        if fields[4] ~= "0" and fields[4] ~= "1" or #fields[5] > 400 then return false end
        local skills = {}
        for part in fields[5]:gmatch("[^,]+") do
            local skill, rank, max = part:match("^([%a ]+)=(%d+)/(%d+)$")
            rank, max = tonumber(rank), tonumber(max)
            local known = false
            for _, s in ipairs(P.skills) do if s == skill then known = true end end
            if not known or not rank or not max or max < 1 or max > 1000 or rank > max or skills[skill] then return false end
            skills[skill] = { rank = rank, max = max }
        end
        if type(old) ~= "table" then
            -- Room for a new character: forget the oldest shares first.
            local count, oldest = 0, nil
            for key, v in pairs(all) do
                if type(v) ~= "table" or type(v.received) ~= "number" or v.received < now - P.relayDays * 86400 then all[key] = nil
                else
                    count = count + 1
                    if not oldest or v.received < all[oldest].received then oldest = key end
                end
            end
            if count >= P.maxRelayed and oldest then all[oldest] = nil end
        end
        all[sender] = { at = at, complete = fields[4] == "1", skills = skills, recipes = {}, received = now }
        return true
    elseif fields[1] == "G" and #fields == 7 then
        local skill, part, total = fields[4], tonumber(fields[5]), tonumber(fields[6])
        if type(old) ~= "table" or old.at ~= at or not old.skills[skill] or P.noRecipes[skill] then return false end
        if not part or not total or part < 1 or total > 10 or part > total or #fields[7] > 1600 then return false end
        local known = type(old.recipes[skill]) == "table" and old.recipes[skill] or {}
        old.recipes[skill] = known
        local count = 0
        for _ in pairs(known) do count = count + 1 end
        local added = false
        for k in fields[7]:gmatch("[^,]+") do
            local kind, number = k:match("^([is])(%d+)$")
            number = tonumber(number)
            if not kind or not number or number < 1 or number >= 10000000 then return added end
            local key = (kind == "i" and "i:" or "s:") .. number
            if not known[key] and count < P.maxRecipes then
                local item, spell = kind == "i" and number or nil, kind == "s" and number or nil
                known[key] = { item = item, spell = spell, name = recipeName(item, spell) }
                count = count + 1
                added = true
            end
        end
        return added
    end
    return false
end

-- Names the game did not know when a share arrived, once it has loaded them (a few at a time).
function P.NameShared()
    local all = relayed()
    local left = 200
    for _, v in pairs(all or {}) do
        for _, list in pairs(type(v) == "table" and type(v.recipes) == "table" and v.recipes or {}) do
            for _, r in pairs(list) do
                if left <= 0 then return end
                if type(r) == "table" and not r.name then r.name = recipeName(r.item, r.spell); left = left - 1 end
            end
        end
    end
end

function P.SetEnabled(on)
    E.Store.db.settings.shareProfessions = on
    if on then P.ScanSkills(); return end
    -- Off: forget what was recorded and tell the website this character lists none.
    local all = db()
    if not all then return end
    for key, e in pairs(all) do
        if type(e) == "table" then all[key] = { skills = {}, recipes = {}, complete = true, hidden = true, at = E.Client.Now() } end
    end
end

function P.Start()
    if P.frame or not CreateFrame then return end
    local frame = CreateFrame("Frame")
    P.frame = frame
    local pending = {}
    -- Profession windows fire their update event many times while they open: read once after.
    local function soon(what, fn)
        if pending[what] then return end
        pending[what] = true
        C_Timer.After(.5, function() pending[what] = nil; pcall(fn) end)
    end
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "SKILL_LINES_CHANGED", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_CLOSE", "CHAT_MSG_SKILL", "CRAFT_SHOW", "CRAFT_UPDATE" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" and not P.noticed then
            P.noticed = true
            C_Timer.After(8, function() pcall(P.NewRequestNotice) end)
            -- Share with guildmates once the guild channel is ready; check again every minute.
            if C_Timer.NewTicker then P.shareTicker = C_Timer.NewTicker(60, function() pcall(P.Share); pcall(P.NameShared) end) end
            C_Timer.After(45, function() pcall(P.Share) end)
        end
        -- The newer API keeps an old list after the window closes, so it is read only while open.
        if event == "TRADE_SKILL_SHOW" then P.windowOpen = true elseif event == "TRADE_SKILL_CLOSE" then P.windowOpen = false; return end
        if event == "PLAYER_ENTERING_WORLD" or event == "SKILL_LINES_CHANGED" or event == "CHAT_MSG_SKILL" then soon("skills", P.ScanSkills)
        elseif event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then soon("craft", P.ScanCraft)
        -- The classic window where the game has it (classic clients), else the newer one (Forever).
        elseif GetNumTradeSkills then soon("trade", P.ScanTradeSkill)
        else soon("trade", P.ScanModern) end
    end)
end
