-- ProfessionBar.lua
-- Secure profession bar with mouseover popups and mini restore button
-- v1.0.2 by ßellena, Blade's Edge US
-- https://www.curseforge.com/wow/addons/professionbar

ProfessionBarDB = ProfessionBarDB or {}

-- API shims: use the new namespaced APIs when present, fall back to the old globals otherwise
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local PlayerHasToy = PlayerHasToy or (C_ToyBox and C_ToyBox.HasToy)

local JOURNAL_SPELLS = {
    ["Mining"]    = "Mining Journal",
    ["Herbalism"] = "Herbalism Journal",
    ["Skinning"]  = "Skinning Journal",
}

-- Added helper to prevent nil-pointer crashes
local function SafeGetText(label)
    return label and label:GetText() or ""
end

local activePopup = nil -- Tracks which menu is currently open
local hideTimer = nil
local allPopups = {}    -- all popup frames ever created, so rebuilds can hide them (declared early so RefreshPopups can see it)

local function HideActivePopup()
    if activePopup and activePopup:IsShown() then
        activePopup:Hide()
        activePopup = nil
    end
end

local function RefreshPopups()
    if InCombatLockdown() then return end
    for _, popup in ipairs(allPopups) do
        if popup.UpdateContent then
            popup.UpdateContent()
        end
    end
end

local SUB_ABILITIES = {
    ["Engineering"]   = { "Gnomish Engineer", "Goblin Engineer" },
    ["Cooking"]       = { "Cooking Fire" },
    ["Fishing"]       = { "Fishing Journal" },
    ["Archaeology"]   = { "Survey" },
    ["Mining"]        = {
        "Smelting",
        { name = "Overload Elemental Deposit", id = 388213 },
        { name = "Overload Empowered Deposit", id = 423394 },
        { name = "Overload Infused Deposit",   id = 1225392 },
    },
    ["Inscription"]   = { "Milling" },
    ["Jewelcrafting"] = { "Prospecting" },
    ["Enchanting"]    = { "Disenchant" },
}

-- type = "toy"  -> checked with C_ToyBox.GetToyInfo(id) hasToy flag
-- type = "item" -> checked with GetItemCount(id) > 0
-- type = "pet"  -> checked with C_PetJournal (species ID, not item ID)
-- icon          -> optional hardcoded icon override (for items where API returns wrong icon)
-- requires      -> optional spell name that must be known (e.g. spec-locked toys)
-- NOTE: Do NOT include Profession Tools (socketed TWW gear) here
-- NOTE: Items shared between professions are duplicated intentionally

---------------------------------------------------------------------------
-- Bag scanner: finds study/knowledge consumables via tooltip text.
-- Matches any item whose tooltip contains "Use: Study" or "Study to increase
-- your" (covers Algari Notes, Treatises, gathering drops, recipes, etc.)
-- Debounced on BAG_UPDATE so scanning only happens once per event burst.
-- Results stored in studyCache[profName] = { {name, icon}, ... }
---------------------------------------------------------------------------
local STUDY_TOOLTIP = CreateFrame("GameTooltip", "ProfBarStudyScanner", nil, "GameTooltipTemplate")
STUDY_TOOLTIP:SetOwner(WorldFrame, "ANCHOR_NONE")

local studyCache = {}    -- [profName] = { {name, icon}, ... }  rebuilt on each scan
local scanPending = false
local allButtons = {}    -- all main profession buttons; populated by BuildButtons
local studyDebug = false -- toggled by /pb debug; prints scan results to chat

-- Per-profession keyword signals: if ANY tooltip line contains one of these,
-- the item belongs to that profession. Covers all expansion prefixes
-- (Dragon Isles, Khaz Algar, Thalassian, Northrend, etc.) automatically
-- because we just check for the base profession name or recipe type keyword.
local PROF_SIGNALS = {
    ["Alchemy"]        = { "Alchemy", "Recipe:" },
    ["Blacksmithing"]  = { "Blacksmithing", "Plans:" },
    ["Enchanting"]     = { "Enchanting", "Formula:" },
    ["Engineering"]    = { "Engineering", "Schematic:" },
    ["Herbalism"]      = { "Herbalism", "Herb", "Botanical", "Frond", "Seed", "Blossom" },
    ["Inscription"]    = { "Inscription", "Technique:" },
    ["Jewelcrafting"]  = { "Jewelcrafting", "Design:" },
    ["Leatherworking"] = { "Leatherworking", "Pattern:" },
    ["Mining"]         = { "Mining", "Deposit", "Ore", "Vein" },
    ["Skinning"]       = { "Skinning" },
    ["Tailoring"]      = { "Tailoring", "Pattern:" },
    ["Cooking"]        = { "Cooking", "Recipe:" },
    ["Fishing"]        = { "Fishing" },
    ["Archaeology"]    = { "Archaeology" },
}

-- Lines that flag an item as study/learnable regardless of which profession.
-- We do NOT require all of these — any one match is enough.
local STUDY_SIGNALS = {
    "Use: Study",
    "Study to increase your",
    "Use: Learn",
    "Teaches you how",
    "Teaches you the",
    "Use: Teaches",
    "Right Click to learn",
    "Right-click to learn",
    "Use: Right",
    -- Fishing consumables: bait, lures, throwback fish that grant fishing skill bonus
}

-- Combined signals: item matches if ALL strings in a set appear anywhere in tooltip.
local STUDY_SIGNALS_COMBINED = {
    -- Any item with both "Use:" and "Fishing" anywhere in tooltip
    { "Use:",            "Fishing" },
    -- Throwback fish: "gain XX Midnight Fishing for YY sec" - no Use: prefix
    { "Fishing for" },
    { "Midnight Fishing" },
}

local function ScanBagsForStudyItems()
    if InCombatLockdown() then return end

    if not studyCache then studyCache = {} end
    -- We use a local table first so the UI doesn't see an empty global table mid-scan
    local tempCache = {}
    local seenIDs = {}

    for bag = 0, NUM_BAG_SLOTS + 1 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not seenIDs[info.itemID] then
                STUDY_TOOLTIP:ClearLines()
                STUDY_TOOLTIP:SetBagItem(bag, slot)

                local lines = {}
                local hasRedLine = false

                for i = 1, STUDY_TOOLTIP:NumLines() do
                    local left = _G["ProfBarStudyScannerTextLeft" .. i]
                    if left then
                        local l = left:GetText() or ""
                        if l ~= "" then
                            table.insert(lines, l)
                            local r2, g, b = left:GetTextColor()
                            if r2 and r2 > 0.9 and g < 0.2 and b < 0.2 then
                                hasRedLine = true
                            end
                        end
                    end
                end

                local allTextLower = table.concat(lines, "\n"):lower()
                local isUsable = allTextLower:find("use:", 1, true) or
                    allTextLower:find("right-click", 1, true)

                local isStudy = false
                for _, signal in ipairs(STUDY_SIGNALS) do
                    if allTextLower:find(signal:lower(), 1, true) then
                        isStudy = true
                        break
                    end
                end

                local profMatches = {}
                for prof, keywords in pairs(PROF_SIGNALS) do
                    for _, kw in ipairs(keywords) do
                        if allTextLower:find(kw:lower(), 1, true) then
                            profMatches[prof] = true
                            break
                        end
                    end
                end

                if not next(profMatches) then
                    for _, combo in ipairs(STUDY_SIGNALS_COMBINED) do
                        local allMatch = true
                        for _, term in ipairs(combo) do
                            if not allTextLower:find(term:lower(), 1, true) then
                                allMatch = false
                                break
                            end
                        end
                        if allMatch then
                            profMatches["Fishing"] = true
                            isUsable = true
                            break
                        end
                    end
                end

                if (isUsable or isStudy) and next(profMatches) then
                    local itemName = info.hyperlink and info.hyperlink:match("%[(.-)%]") or tostring(info.itemID)
                    seenIDs[info.itemID] = true
                    local itemIcon = info.iconFileID or C_Item.GetItemIconByID(info.itemID)

                    for prof in pairs(profMatches) do
                        tempCache[prof] = tempCache[prof] or {}
                        table.insert(tempCache[prof], {
                            name = itemName,
                            icon = itemIcon,
                            unusable = hasRedLine,
                            itemID = info.itemID
                        })
                    end
                end
            end
        end
    end

    studyCache = tempCache
    scanPending = false
    if allButtons then
        for _, b in ipairs(allButtons) do
            if b.RefreshStudy then b.RefreshStudy() end
        end
    end
end

-- Pre-load all uncached item data before scanning.
-- Collects every itemID in bags, requests load for any that aren't cached,
-- then waits for GET_ITEM_INFO_RECEIVED until all are ready, then scans.
local pendingItemIDs = {} -- itemID -> true, waiting for cache
local loadListenerActive = false
local itemLoadFrame = CreateFrame("Frame")

local function RunScanWhenReady(loadedID)
    -- Mark the just-loaded item as ready
    if loadedID then
        pendingItemIDs[loadedID] = nil
    end
    -- Check if anything is still waiting
    if next(pendingItemIDs) then return end
    -- All items loaded
    loadListenerActive = false
    itemLoadFrame:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    ScanBagsForStudyItems()
end

itemLoadFrame:SetScript("OnEvent", function(self, event, itemID)
    if event == "GET_ITEM_INFO_RECEIVED" then
        RunScanWhenReady(itemID)
    end
end)

local function ScheduleBagScan()
    if scanPending then return end
    scanPending = true
    local dbg = studyDebug

    -- First pass: request load for any uncached items
    wipe(pendingItemIDs)
    for bag = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                if not C_Item.IsItemDataCachedByID(info.itemID) then
                    pendingItemIDs[info.itemID] = true
                    C_Item.RequestLoadItemDataByID(info.itemID)
                end
            end
        end
    end

    if next(pendingItemIDs) then
        local count = 0
        for _ in pairs(pendingItemIDs) do count = count + 1 end
        if dbg then print("|cff00FF00[ProfBar Scan]|r Waiting for " .. count .. " items...") end
        
        if not loadListenerActive then
            loadListenerActive = true
            itemLoadFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
        end
        -- Fallback scan
        C_Timer.After(5, function()
            if scanPending then
                loadListenerActive = false
                itemLoadFrame:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
                ScanBagsForStudyItems()
            end
        end)
    else
        -- All cached, small delay to ensure tooltip system is ready
        C_Timer.After(0.2, ScanBagsForStudyItems)
    end
end

local PROF_ITEMS = {
    ["Engineering"] = {
        -- Toys: Blingtrons
        { id = 87214,  name = "Blingtron 4000",                           type = "toy" },                                -- Summons Blingtron 4000, daily gift giver
        { id = 111821, name = "Blingtron 5000",                           type = "toy" },                                -- Summons Blingtron 5000, daily gift giver
        { id = 168667, name = "Blingtron 7000",                           type = "toy" },                                -- Summons Blingtron 7000, daily gift giver
        -- Toys: Wormholes
        { id = 48933,  name = "Wormhole Generator: Northrend",            type = "toy" },                                -- Teleport to random Northrend location
        { id = 87215,  name = "Wormhole Generator: Pandaria",             type = "toy" },                                -- Teleport to random Pandaria location
        { id = 112059, name = "Wormhole Centrifuge",                      type = "toy" },                                -- Teleport to random Draenor location
        { id = 151652, name = "Wormhole Generator: Argus",                type = "toy" },                                -- Teleport to random Argus location
        { id = 168807, name = "Wormhole Generator: Kul Tiras",            type = "toy" },                                -- Teleport to random Kul Tiras location
        { id = 168808, name = "Wormhole Generator: Zandalar",             type = "toy" },                                -- Teleport to random Zandalar location
        { id = 172924, name = "Wormhole Generator: Shadowlands",          type = "toy" },                                -- Teleport to random Shadowlands location
        { id = 221966, name = "Wormhole Generator: Khaz Algar",           type = "toy" },                                -- Teleport to random Khaz Algar location
        { id = 198156, name = "Wyrmhole Generator: Dragon Isles",         type = "toy" },                                -- Teleport to random Dragon Isles location
        -- Toys: Transporters (Gnomish only)
        { id = 18986,  name = "Ultrasafe Transporter: Gadgetzan",         type = "toy", requires = "Gnomish Engineer" }, -- Teleport to Gadgetzan (may malfunction)
        { id = 30544,  name = "Ultrasafe Transporter: Toshley's Station", type = "toy", requires = "Gnomish Engineer" }, -- Teleport to Toshley's Station (may malfunction)
        -- Toys: Transporters (Goblin only)
        { id = 18984,  name = "Dimensional Ripper - Everlook",            type = "toy", requires = "Goblin Engineer" },  -- Teleport to Everlook (may malfunction)
        { id = 30542,  name = "Dimensional Ripper - Area 52",             type = "toy", requires = "Goblin Engineer" },  -- Teleport to Area 52 (may malfunction)
        -- Toys: Other
        { id = 40678,  name = "MOLL-E",                                   type = "toy" },                                -- Mailbox
        --  { id = 116139, name = "Snowmaster 9000",                     type = "toy", icon = 135863 },  -- Creates a snowball
        { id = 17716,  name = "Snowmaster 9000",                          type = "toy" },                                -- Creates a snowball
        { id = 168496, name = "Loot-A-Rang",                              type = "toy" },                                -- Loots nearby corpses
        { id = 18660,  name = "World Enlarger",                           type = "toy" },                                -- Shrinks you down
        { id = 221962, name = "Defective Escape Pod",                     type = "toy" },                                -- Summons a random mount
        { id = 221915, name = "Irresistible Red Button",                  type = "toy" },                                -- TWW Engineering Toy
        { id = 221914, name = "Convincingly Realistic Dummy",             type = "toy" },                                -- TWW Engineering Toy
        -- Items: Non-consumable
        -- { id = 49040,  name = "Jeeves",                                   type = "item" },                               -- Portable repairbot, bank, and vendor
        -- { id = 144341, name = "Rechargeable Reaves Battery",              type = "item" },                               -- Summons Reaves in multiple modes including anvil
        { id = 40772,  name = "Gnomish Army Knife",                       type = "item" },                               -- Portable mining/skinning/herbalism tool (resserect dead player)
        --   { id = 109253, name = "Ultimate Gnomish Army Knife",         type = "item" },  -- Upgraded portable tool (NO resserect dead player)
        { id = 114943, name = "Ultimate Gnomish Army Knife",              type = "item" },                               -- Upgraded portable tool (resserect dead player)
        -- Items: Consumable
        { id = 87216,  name = "Thermal Anvil",                            type = "item" },                               -- Portable anvil
        { id = 198268, name = "Portable Tinker's Workbench",              type = "item" },                               -- Portable Engineering crafting station
        { id = 221913, name = "Algari Tinker's Workbench",                type = "item" },                               -- Portable TWW crafting station
        { id = 47828,  name = "Goblin Beam Welder",                       type = "item" },                               -- Repair Mechanicals (30 Charges)
        { id = 77532,  name = "Locksmith's Powderkeg",                    type = "item" },                               -- Unlock chests and doors (Level 35 and below)
        -- { id = 60853,  name = "Volatile Seaforium Blastpack",             type = "item" },                               -- Unlock chests and doors (Level 35 and below)
        { id = 34113,  name = "Field Repair Bot 110G",                    type = "item" },                               -- Deployable Repair Bot (also used to build Jeeves)
        { id = 18232,  name = "Field Repair Bot 74A",                     type = "item" },                               -- Deployable Repair Bot (also used to build Jeeves)
        -- Pets (species ID)
        { id = 3274,   name = "Alvin the Anvil",                          type = "pet" },
        { id = 2966,   name = "Alvin the Anvil",                          type = "pet" }, -- Battle pet, also functions as an anvil
    },
    ["Mining"] = {
        --      { id = 87213,  name = "Mist-Piercing Goggles",               type = "item" },  -- Reveals hidden mines in Pandaria (no need to equip)
        { id = 210711, name = "Algari Mining Pick", type = "item" },                  -- TWW Mining Tool
    },
    ["Herbalism"] = {
        --      { id = 87213,  name = "Mist-Piercing Goggles",               type = "item" },  -- Reveals hidden herbs in Pandaria (no need to equip)
        { id = 210712, name = "Algari Sickle", type = "item" },                       -- TWW Herbalism Tool
    },
    ["Skinning"] = {
        -- Add skinning items/toys here
        { id = 210713, name = "Algari Skinning Knife", type = "item" },               -- TWW Skinning Tool
    },
    ["Leatherworking"] = {
        { id = 198677, name = "Tanning Rack",                 type = "item" },        -- Portable LW crafting station
        { id = 210717, name = "Algari Leatherworker's Apron", type = "item" },        -- TWW LW Tool
    },
    ["Tailoring"] = {
        -- Add tailoring items/toys here
        { id = 210718, name = "Algari Weaver's Needle", type = "item" },              -- TWW Tailoring Tool
    },
    ["Enchanting"] = {
        -- Add enchanting items/toys here
        { id = 210710, name = "Algari Enchanter's Rod", type = "item" },              -- TWW Enchanting Tool
    },
    ["Blacksmithing"] = {
        { id = 152839, name = "Khaz'gorian Hammer", type = "item" },                               -- Portable anvil
        { id = 87216,  name = "Thermal Anvil",      type = "item" },                               -- Portable anvil (craftable by Engineers)
        { id = 210741, name = "Everburning Forge",  type = "item" },                               -- TWW Portable Blacksmithing Forge
        {
            id = 2966,
            name = "Alvin the Anvil",
            { id = 3274, name = "Alvin the Anvil", type = "pet" },
            type = "pet"
        },                                                                                         -- Battle pet, also functions as an anvil
    },
    ["Jewelcrafting"] = {
        -- Add jewelcrafting items/toys here
        { id = 210716, name = "Algari Jeweler's Glass", type = "item" },              -- TWW Jewelcrafting Tool
    },
    ["Inscription"] = {
        { id = 37118,  name = "Scroll of Recall",      type = "item" },               -- Teleport to your Hearthstone location
        { id = 210715, name = "Algari Scribe's Quill", type = "item" },               -- TWW Inscription Tool
    },
    ["Alchemy"] = {
        { id = 44322,  name = "Mercurial Alchemist Stone", type = "item" },            -- Trinket that boosts potions
        { id = 198265, name = "Portable Alchemist's Lab",  type = "item" },            -- Portable alchemy crafting station
        { id = 210732, name = "Algari Alchemist's Robe",   type = "item" },            -- TWW Alchemy Tool
    },
    ["Cooking"] = {
        { id = 134020, name = "Chef's Hat", type = "toy" },                          -- Speeds up cooking cast time
        --     { id = 6657,  name = "Recipe: Savory Deviate Delight",      type = "item" },  -- Buff food, turns you into a pirate or ninja
    },
    ["Fishing"] = {
        -- Toys: Rafts (area restricted)
        { id = 85500,  name = "Anglers Fishing Raft",               type = "toy" },   -- Portable fishing raft
        { id = 107950, name = "Bipsi's Bobbing Berg",               type = "toy" },   -- Portable fishing iceberg
        { id = 168016, name = "Hyper-Compressed Ocean",             type = "toy" },   -- Summons a fishing pool anywhere
        -- Toys: Other
        { id = 86596,  name = "Nat's Fishing Chair",                type = "toy" },   -- Portable fishing chair, increases fishing skill
        -- Toys: Bobbers
        { id = 85973,  name = "Crate of Bobbers: Tauren",           type = "toy" },   -- Tauren bobber
        { id = 142259, name = "Crate of Bobbers: Tottle",           type = "toy" },   -- Tottle bobber
        { id = 142528, name = "Crate of Bobbers: Murloc",           type = "toy" },   -- Murloc bobber
        { id = 142529, name = "Crate of Bobbers: Gnome",            type = "toy" },   -- Gnome bobber
        { id = 142530, name = "Crate of Bobbers: Sylvanas",         type = "toy" },   -- Sylvanas bobber
        { id = 143662, name = "Crate of Bobbers: Anduin",           type = "toy" },   -- Anduin bobber
        -- Items: Poles
        { id = 44050,  name = "Mastercraft Kalu'ak Fishing Pole",   type = "item" },  -- Fishing pole with +30 fishing skill
        { id = 19022,  name = "Nat Pagle's Extreme Angler FC-5000", type = "item" },  -- Fishing pole
        { id = 210714, name = "Driftwood Fishing Pole",             type = "item" },  -- TWW Fishing Tool
        -- Items: Hats
        { id = 33820,  name = "Weather-Beaten Fishing Hat",         type = "item" },  -- Hat with fishing skill bonus, also spawns a worm
    },
    ["Archaeology"] = {
        -- Add archaeology items/toys here
    },
}

local BUTTON_SIZE = 36
local BUTTON_PADDING = 4

---------------------------------------------------------------------------
-- Spell texture helper
---------------------------------------------------------------------------
local function GetSpellTex(name)
    if not name then return nil end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(name)
    if info and info.iconID then return info.iconID end
    return nil
end

---------------------------------------------------------------------------
-- Check if spell name exists in spellbook
---------------------------------------------------------------------------
local function IsKnownSpellName(name)
    if not name then return false end
    -- Scan flat spellbook list (works for profession spells in current WoW API)
    local i = 1
    while true do
        local ok, si = pcall(C_SpellBook.GetSpellBookItemInfo, i, Enum.SpellBookSpellBank.Player)
        if not ok or not si then break end
        if si.name == name then return true end
        i = i + 1
    end
    return false
end

---------------------------------------------------------------------------
-- Check if player owns a toy/item/pet
---------------------------------------------------------------------------
local function PlayerHasItem(entry)
    if entry.requires and not IsKnownSpellName(entry.requires) then
        return false
    end
    if entry.type == "toy" then
        return PlayerHasToy(entry.id)
    elseif entry.type == "item" then
        return GetItemCount(entry.id, true) > 0
    elseif entry.type == "pet" then
        -- Returns > 0 if you actually own the pet
        local count = C_PetJournal.GetNumCollectedInfo(entry.id)
        return count > 0
    end
    return false
end
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "ProfessionBarFrame", UIParent, "BackdropTemplate")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ProfessionBarDB.pos = { point, relPoint, x, y }
end)
frame:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
frame:SetBackdropColor(0, 0, 0, 0.7)
frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
frame:SetFrameLevel(5)

---------------------------------------------------------------------------
-- Build buttons (forward declared so miniBtn can reference it)
---------------------------------------------------------------------------
local BuildButtons
local UpdateMiniBtnColor
local initFrame -- forward-declared so BuildButtons can register PLAYER_REGEN_ENABLED

---------------------------------------------------------------------------
-- Mini restore button
---------------------------------------------------------------------------
local miniBtn = CreateFrame("Button", "ProfessionBarMiniBtn", UIParent, "BackdropTemplate")
miniBtn:SetSize(32, 18)
miniBtn:SetMovable(true)
miniBtn:SetClampedToScreen(true)
miniBtn:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 10,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
miniBtn:SetBackdropColor(0, 0, 0, 0.85)
miniBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
miniBtn:EnableMouse(true)
miniBtn:RegisterForDrag("LeftButton")
miniBtn:SetScript("OnDragStart", function(self) self:StartMoving() end)
miniBtn:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ProfessionBarDB.miniPos = { point, relPoint, x, y }
end)

local miniBtnLabel = miniBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
miniBtnLabel:SetPoint("CENTER")
miniBtnLabel:SetText("PB")
miniBtnLabel:SetTextColor(1, 0.82, 0)

UpdateMiniBtnColor = function()
    if ProfessionBarDB.showItems then
        miniBtn:SetBackdropColor(0, 0.2, 0.6, 0.85)
        miniBtn:SetBackdropBorderColor(0.3, 0.6, 1.0, 1)
    else
        miniBtn:SetBackdropColor(0, 0, 0, 0.85)
        miniBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    end
end

miniBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
miniBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        if InCombatLockdown() then
            print("|cff00FF00[ProfessionBar]|r Cannot toggle tools during combat.")
            return
        end
        ProfessionBarDB.showItems = not ProfessionBarDB.showItems
        BuildButtons()
        UpdateMiniBtnColor()
        if ProfessionBarDB.showItems then
            print("|cff00FF00[ProfessionBar]|r Tools/items shown.")
        else
            print("|cff00FF00[ProfessionBar]|r Tools/items hidden.")
        end
    else
        if InCombatLockdown() then
            print("|cff00FF00[ProfessionBar]|r Cannot show/hide bar during combat.")
            return
        end
        if frame:IsShown() then
            frame:Hide()
            ProfessionBarDB.hidden = true
        else
            frame:Show()
            ProfessionBarDB.hidden = false
        end
    end
end)
miniBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("ProfessionBar", 1, 0.82, 0)
    if frame:IsShown() then
        GameTooltip:AddLine("Left-click to hide bar", 0.5, 1, 0.5)
    else
        GameTooltip:AddLine("Left-click to show bar", 0.5, 1, 0.5)
    end
    if ProfessionBarDB.showItems then
        GameTooltip:AddLine("Right-click to hide tools/items", 1, 1, 0.5)
    else
        GameTooltip:AddLine("Right-click to show tools/items", 1, 1, 0.5)
    end
    GameTooltip:AddLine("Drag to move", 0.5, 0.5, 1)
    GameTooltip:Show()
end)
miniBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------
-- Build buttons
---------------------------------------------------------------------------
local buildPending = false -- debounce: prevents double-build in same frame

BuildButtons = function()
    if InCombatLockdown() then
        initFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    if buildPending then return end
    buildPending = true

    for _, b in ipairs(allButtons) do
        b:Hide(); b:ClearAllPoints()
    end
    for _, p in ipairs(allPopups) do p:Hide() end
    allButtons = {}
    allPopups = {}

    local profSlots = { GetProfessions() }
    local profs = {}
    for _, idx in ipairs(profSlots) do
        if idx then
            local name = GetProfessionInfo(idx)
            if name and name ~= "" then table.insert(profs, name) end
        end
    end

    if #profs == 0 then
        buildPending = false
        C_Timer.After(2, BuildButtons)
        return
    end

    local col = 0
    for _, profName in ipairs(profs) do
        local castName = JOURNAL_SPELLS[profName] or profName
        local btn = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate")
        btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)

        btn:RegisterForClicks("AnyUp", "AnyDown")
        btn:SetAttribute("type1", "spell")
        btn:SetAttribute("spell1", castName)
        btn:SetAttribute("type2", "macro")
        btn:SetAttribute("macrotext2", "/run")

        btn:SetPoint("LEFT", frame, "LEFT", 4 + col * (BUTTON_SIZE + BUTTON_PADDING), 0)

        local tex = GetSpellTex(castName) or GetSpellTex(profName)
        btn:SetNormalTexture(tex or "Interface/Icons/INV_Misc_QuestionMark")
        btn:SetPushedTexture("Interface/Buttons/UI-Quickslot-Depress")
        btn:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square", "ADD")

        btn:SetScript("PreClick", function(self, button)
            self._rightClick = (button == "RightButton")
        end)
        btn:SetScript("PostClick", function(self, button)
            if self._rightClick then
                self._rightClick = false
                if InCombatLockdown() then
                    print("|cff00FF00[ProfessionBar]|r Cannot refresh during combat.")
                    return
                end
                print("|cff00FF00[ProfessionBar]|r Refreshing " .. profName .. "...")
                buildPending = false
                BuildButtons()
                scanPending = false
                ScheduleBagScan()
            end
        end)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(profName, 1, 1, 1)
            GameTooltip:Show()
            if self.popup and not InCombatLockdown() then
                if activePopup and activePopup ~= self.popup then activePopup:Hide() end
                if (self.popupButtons and #self.popupButtons > 0) or (studyCache[profName] and #studyCache[profName] > 0) then
                    self.popup:Show()
                    activePopup = self.popup
                end
            end
        end)

        btn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            if self.popup then
                C_Timer.After(0.15, function()
                    if not self:IsMouseOver() and not self.popup:IsMouseOver() then
                        self.popup:Hide()
                        if activePopup == self.popup then activePopup = nil end
                    end
                end)
            end
        end)

        table.insert(allButtons, btn)
        col = col + 1

        do
            local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            popup:SetFrameStrata("HIGH")
            popup:SetBackdrop({
                bgFile = "Interface/Tooltips/UI-Tooltip-Background",
                edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
                tile = true,
                tileSize = 16,
                edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 }
            })
            popup:SetBackdropColor(0, 0, 0, 0.85)
            popup:Hide()
            popup:SetPoint("BOTTOM", btn, "TOP", 0, 2)
            btn.popup = popup
            table.insert(allPopups, popup)

            local MAX_COLS = 8
            local addedKeys = {}
            btn.popupButtons = {}

            local function AddPopupButton(name, row, col, attrType, attrVal, texID, itemID, realType)
                local key = attrType .. "|" .. tostring(attrVal)
                if addedKeys[key] then return nil end
                addedKeys[key] = true

                local pb = CreateFrame("Button", nil, popup, "SecureActionButtonTemplate")
                pb:SetSize(BUTTON_SIZE, BUTTON_SIZE)
                pb:RegisterForClicks("AnyUp", "AnyDown")
                pb:SetAttribute("type", attrType)
                if attrType == "spell" then
                    pb:SetAttribute("spell", attrVal)
                elseif attrType == "macro" then
                    pb:SetAttribute("macrotext", attrVal)
                else
                    pb:SetAttribute("item", attrVal)
                end

                pb:SetPoint("TOPLEFT", popup, "TOPLEFT", 4 + (col - 1) * (BUTTON_SIZE + 4),
                    -(4 + (row - 1) * (BUTTON_SIZE + 4)))

                local displayTex = texID
                local cleanID = tonumber(itemID)
                if cleanID and realType == "pet" then
                    local _, petIcon = C_PetJournal.GetPetInfoBySpeciesID(cleanID)
                    displayTex = petIcon
                elseif cleanID and realType == "toy" then
                    _, _, displayTex = C_ToyBox.GetToyInfo(cleanID)
                end

                if displayTex then
                    pb:SetNormalTexture(displayTex)
                elseif cleanID then
                    pb:SetNormalTexture("Interface/Icons/INV_Misc_QuestionMark")
                    local item = Item:CreateFromItemID(cleanID)
                    item:ContinueOnItemLoad(function() if not displayTex then pb:SetNormalTexture(C_Item.GetItemIconByID(
                            cleanID)) end end)
                else
                    pb:SetNormalTexture("Interface/Icons/INV_Misc_QuestionMark")
                end

                -- Bright green highlight border overlay for learnable/study items
                local highlightBorder = pb:CreateTexture(nil, "OVERLAY")
                highlightBorder:SetAllPoints(pb)
                highlightBorder:SetTexture("Interface/Buttons/UI-ActionButton-Border")
                highlightBorder:SetBlendMode("ADD")
                highlightBorder:SetVertexColor(0, 1, 0, 0.9)
                highlightBorder:Hide()
                pb.highlightBorder = highlightBorder

                pb:SetScript("OnEnter", function(s)
                    if hideTimer then
                        hideTimer:Cancel(); hideTimer = nil
                    end
                    GameTooltip:SetOwner(s, "ANCHOR_TOP")
                    GameTooltip:SetText(name); GameTooltip:Show()
                end)
                pb:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                    if hideTimer then hideTimer:Cancel() end
                    hideTimer = C_Timer.NewTimer(0.2,
                        function() if activePopup then
                                activePopup:Hide(); activePopup = nil
                            end end)
                end)
                return pb
            end

            local totalRows = 0
            local maxUsedCols = 0

            local subs = SUB_ABILITIES[profName]
            local knownSubs = {}
            if subs then
                for _, sub in ipairs(subs) do
                    local sName = type(sub) == "table" and sub.name or sub
                    if IsKnownSpellName(sName) then table.insert(knownSubs, { name = sName }) end
                end
            end

            for i, sub in ipairs(knownSubs) do
                local r, c = math.ceil(i / MAX_COLS), ((i - 1) % MAX_COLS) + 1
                local pb = AddPopupButton(sub.name, r, c, "spell", sub.name, GetSpellTex(sub.name))
                if pb then
                    table.insert(btn.popupButtons, pb); maxUsedCols = math.max(maxUsedCols, c)
                end
            end
            totalRows = math.ceil(#knownSubs / MAX_COLS)

            local ownedItems = {}
            if ProfessionBarDB.showItems then
                local items = PROF_ITEMS[profName]
                if items then
                    for _, entry in ipairs(items) do
                        if PlayerHasItem(entry) then table.insert(ownedItems, entry) end
                    end
                end
            end

            for i, entry in ipairs(ownedItems) do
                local r, c = totalRows + math.ceil(i / MAX_COLS), ((i - 1) % MAX_COLS) + 1
                local attrType = entry.type or "item"
                local attrVal = (attrType == "pet" and ("/summonpet " .. entry.name) or ("item:" .. entry.id))
                local pb = AddPopupButton(entry.name, r, c, (attrType == "pet" and "macro" or "item"), attrVal,
                    entry.icon, entry.id, entry.type)
                if pb then
                    table.insert(btn.popupButtons, pb); maxUsedCols = math.max(maxUsedCols, c)
                end
            end
            totalRows = totalRows + math.ceil(#ownedItems / MAX_COLS)

            local studyBaseRow = totalRows
            local studyButtons = {}
            btn.RefreshStudy = function()
                for _, pb in ipairs(studyButtons) do
                    pb:Hide(); pb:SetParent(nil)
                end
                wipe(studyButtons)
                -- Clear study-item dedup keys so they can be re-added after each scan.
                for k in pairs(addedKeys) do
                    if k:sub(1, 6) == "macro|" then addedKeys[k] = nil end
                end
                local items = studyCache[profName] or {}
                local si = 0
                local currentMaxCols = maxUsedCols
                for _, entry in ipairs(items) do
                    if not entry.unusable then
                        si = si + 1
                        local r, c = studyBaseRow + math.ceil(si / MAX_COLS), ((si - 1) % MAX_COLS) + 1
                        local pb = AddPopupButton(entry.name, r, c, "macro", "/use " .. entry.name, entry.icon, nil, nil)
                        if pb then
                            if pb.highlightBorder then pb.highlightBorder:Show() end
                            table.insert(studyButtons, pb); currentMaxCols = math.max(currentMaxCols, c)
                        end
                    end
                end
                local finalRows = studyBaseRow + math.ceil(si / MAX_COLS)
                popup:SetSize(math.max(1, currentMaxCols) * 40 + 8, math.max(1, finalRows) * 40 + 8)
            end
            btn.RefreshStudy()
        end
    end
    frame:SetSize(col * 40 + 8, 44)
    if not ProfessionBarDB.hidden then frame:Show() end
    buildPending = false
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local function RestorePositions()
    -- Restore main frame position
    frame:ClearAllPoints()
    if ProfessionBarDB.pos then
        local p = ProfessionBarDB.pos
        -- Explicit UIParent check to avoid "Couldn't find region" error
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    end

    -- Restore mini button position
    miniBtn:ClearAllPoints()
    if ProfessionBarDB.miniPos then
        local p = ProfessionBarDB.miniPos
        miniBtn:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        miniBtn:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    end
    miniBtn:Show()
    UpdateMiniBtnColor()

    -- Restore hidden state
    if ProfessionBarDB.hidden then
        frame:Hide()
    end
end

initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:RegisterEvent("SKILL_LINES_CHANGED")
initFrame:RegisterEvent("ZONE_CHANGED")
initFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
initFrame:RegisterEvent("BAG_UPDATE")
initFrame:RegisterEvent("TOYS_UPDATED")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "BAG_UPDATE" then
        -- Re-scan bags for study items (debounced); ScanBagsForStudyItems will
        -- call RefreshStudy on any open popups once the scan completes.
        ScheduleBagScan()
        return
    end
    if event == "TOYS_UPDATED" then
        -- Toy box finished loading or changed; rebuild so toy ownership is accurate.
        C_Timer.After(0.5, function()
            BuildButtons()
        end)
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        -- PLAYER_ENTERING_WORLD fires after profession data is available from server,
        -- making it more reliable than PLAYER_LOGIN for building the bar.
        -- Use a short delay to let other addons (ArkInventory etc.) settle first.
        C_Timer.After(0.5, function()
            RestorePositions()
            BuildButtons()
            if GetNumBagSlots and C_Container then
                ScheduleBagScan()
            end
        end)
        -- Retry loop: keep rescanning until item count stabilises (handles late-caching items)
        local lastCount = 0
        local retryCount = 0
        local maxRetries = 6
        local function RetryUntilStable()
            retryCount = retryCount + 1
            if retryCount > maxRetries then return end
            scanPending = false
            ScheduleBagScan()
            C_Timer.After(9, function()
                local newCount = 0
                for _, items in pairs(studyCache) do newCount = newCount + #items end
                if newCount ~= lastCount then
                    lastCount = newCount
                    RetryUntilStable()
                end
            end)
        end
        C_Timer.After(8, RetryUntilStable)
        return
    end
    if event == "PLAYER_LOGIN" then
        -- PLAYER_LOGIN is kept as a fallback but PLAYER_ENTERING_WORLD handles the main build.
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat just ended; fire any deferred BuildButtons rebuild and stop listening.
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        C_Timer.After(0, function()
            BuildButtons()
        end)
    else
        C_Timer.After(1, function()
            BuildButtons()
            scanPending = false
            ScheduleBagScan()
        end)
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_PROFESSIONBAR1 = "/profbar"
SLASH_PROFESSIONBAR2 = "/pb"
SlashCmdList["PROFESSIONBAR"] = function(msg)
    msg = msg and msg:lower():gsub("^%s*(.-)%s*$", "%1") or ""
    if msg == "debug" then
        studyDebug = not studyDebug
        print("|cff00FF00[ProfessionBar]|r Scan debug " ..
        (studyDebug and "|cff00FF00ON|r — right-click any profession button to rescan." or "|cffFF4444OFF|r"))
        return
    elseif msg:sub(1, 6) == "spell " then
        -- /pb spell <name> — search C_SpellBook and C_Professions for matching spells
        local search = msg:sub(7):lower()
        print("|cff00FF00[ProfessionBar]|r Searching for: " .. search)
        local found = 0
        -- Search spellbook
        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
            for i = 1, C_SpellBook.GetNumSpellBookSkillLines() do
                local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
                if info then
                    for j = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                        local ok, si = pcall(C_SpellBook.GetSpellBookItemInfo, j, Enum.SpellBookSpellBank.Player)
                        if ok and si and si.name and si.name:lower():find(search, 1, true) then
                            print("  SpellBook: |cffFFFF00" .. si.name .. "|r id=" .. tostring(si.spellID))
                            found = found + 1
                        end
                    end
                end
            end
        end
        -- Search C_Professions trait entries
        if C_Professions then
            local profSlots = { GetProfessions() }
            for _, slot in ipairs(profSlots) do
                if slot then
                    local profName, _, _, _, _, _, skillLine = GetProfessionInfo(slot)
                    local ok, configID = pcall(function()
                        return C_Professions.GetProfessionConfig and C_Professions.GetProfessionConfig(skillLine)
                    end)
                    if ok and configID then
                        local ok2, nodes = pcall(C_Traits.GetTreeNodes, configID)
                        if ok2 and nodes then
                            for _, nodeID in ipairs(nodes) do
                                local ok3, nodeInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
                                if ok3 and nodeInfo and nodeInfo.activeEntry then
                                    local ok4, entryInfo = pcall(C_Traits.GetEntryInfo, configID,
                                        nodeInfo.activeEntry.entryID)
                                    if ok4 and entryInfo and entryInfo.definitionID then
                                        local ok5, defInfo = pcall(C_Traits.GetDefinitionInfo, entryInfo.definitionID)
                                        if ok5 and defInfo and defInfo.spellID then
                                            local name = C_Spell.GetSpellName(defInfo.spellID) or ""
                                            if name:lower():find(search, 1, true) then
                                                print("  Trait[" ..
                                                profName .. "]: |cffFFFF00" .. name .. "|r id=" .. defInfo.spellID)
                                                found = found + 1
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if found == 0 then print("  Nothing found.") end
        return
    elseif msg == "profspells" then
        -- Dump all profession-related spells via C_Professions
        print("|cff00FF00[ProfessionBar]|r Dumping profession spells...")
        local profSlots = { GetProfessions() }
        for _, slot in ipairs(profSlots) do
            if slot then
                local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(slot)
                print("  Prof: |cffFFFF00" ..
                (name or "?") .. "|r skillLine=" .. tostring(skillLine) .. " rank=" .. tostring(rank))
                if C_Professions and C_Professions.GetProfessionSlots then
                    -- Try to find config ID
                    local configID = C_Professions.GetProfessionConfig and C_Professions.GetProfessionConfig(skillLine)
                    print("    configID=" .. tostring(configID))
                end
                -- Scan spellbook profession tab
                if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
                    for i = 1, C_SpellBook.GetNumSpellBookSkillLines() do
                        local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
                        if info and info.name == name then
                            print("    SpellBook tab found: offset=" ..
                            info.itemIndexOffset .. " count=" .. info.numSpellBookItems)
                            for j = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                                local si = C_SpellBook.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Player)
                                if si then
                                    print("      |cffFFFF00" ..
                                    tostring(si.name) ..
                                    "|r id=" .. tostring(si.spellID) .. " type=" .. tostring(si.itemType))
                                end
                            end
                        end
                    end
                end
            end
        end
        return
    elseif msg == "reset" then
        buildPending = false
        if InCombatLockdown() then
            print("|cff00FF00[ProfessionBar]|r Cannot reset positions during combat.")
            return
        end
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        ProfessionBarDB.pos = nil
        miniBtn:ClearAllPoints()
        miniBtn:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
        ProfessionBarDB.miniPos = nil
        frame:Show()
        ProfessionBarDB.hidden = false
        print("|cff00FF00[ProfessionBar]|r Positions reset to center.")
    elseif msg == "tools" then
        if InCombatLockdown() then
            print("|cff00FF00[ProfessionBar]|r Cannot toggle tools during combat.")
            return
        end
        ProfessionBarDB.showItems = not ProfessionBarDB.showItems
        BuildButtons()
        UpdateMiniBtnColor()
        if ProfessionBarDB.showItems then
            print("|cff00FF00[ProfessionBar]|r Tools/items shown.")
        else
            print("|cff00FF00[ProfessionBar]|r Tools/items hidden.")
        end
    else
        if InCombatLockdown() then
            print("|cff00FF00[ProfessionBar]|r Cannot show/hide bar during combat.")
            return
        end
        if frame:IsShown() then
            frame:Hide()
            ProfessionBarDB.hidden = true
        else
            frame:Show()
            ProfessionBarDB.hidden = false
        end
    end
end
-- v1.8 (Revision: 0014)
