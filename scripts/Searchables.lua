-- Searchables
-- Live search boxes on the shop and construction screens: click the box, type, and the list filters as you type.
-- This file has the shared search logic, the lifecycle and the console commands. The search box element is in
-- SearchablesSearchBox.lua, the screen hooks in SearchablesShop.lua and SearchablesConstruction.lua.

Searchables = {}
Searchables.MOD_NAME = g_currentModName
Searchables.MOD_DIRECTORY = g_currentModDirectory
Searchables.PROFILES_FILENAME = Utils.getFilename("gui/searchablesProfiles.xml", g_currentModDirectory)
Searchables.SEARCH_BOX_FILENAME = Utils.getFilename("gui/searchBox.xml", g_currentModDirectory)

-- Search text per store item, built on first use. Weak keys so reloaded store items can be collected.
Searchables.storeItemTexts = setmetatable({}, {__mode = "k"})

-- ---------------------------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------------------------

function Searchables.toLower(text)
    return utf8ToLower(tostring(text or ""))
end

-- Splits free text into lowercase words
function Searchables.getSearchWords(text)
    local words = {}
    for word in Searchables.toLower(text):gmatch("%S+") do
        table.insert(words, word)
    end
    return words
end

-- Every word must appear somewhere in the text (which is already lowercase)
function Searchables.matchesWords(searchText, words)
    for _, word in ipairs(words) do
        if not searchText:find(word, 1, true) then
            return false
        end
    end
    return true
end

function Searchables.getStoreCategoryTitle(categoryName)
    if categoryName == nil then
        return ""
    end
    local category = g_storeManager:getCategoryByName(categoryName)
    return (category ~= nil and category.title) or categoryName
end

-- Name, brand, shop categories, construction category and tab, DLC, and mod title and author of a store item
function Searchables.getStoreItemText(storeItem)
    local text = Searchables.storeItemTexts[storeItem]
    if text ~= nil then
        return text
    end

    local parts = {storeItem.name, storeItem.brandNameRaw, storeItem.dlcTitle}

    local brand = storeItem.brandIndex ~= nil and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil
    if brand ~= nil then
        table.insert(parts, brand.title)
    end

    for _, categoryName in ipairs(storeItem.categoryNames or {storeItem.categoryName}) do
        table.insert(parts, Searchables.getStoreCategoryTitle(categoryName))
    end

    local brush = storeItem.brush
    if brush ~= nil then
        table.insert(parts, brush.category ~= nil and brush.category.title or nil)
        table.insert(parts, brush.tab ~= nil and brush.tab.title or nil)
    end

    if storeItem.isMod and storeItem.customEnvironment ~= nil then
        local mod = g_modManager.nameToMod[storeItem.customEnvironment]
        if mod ~= nil then
            table.insert(parts, mod.title)
            table.insert(parts, mod.author)
        end
    end

    local strings = {}
    for _, part in pairs(parts) do
        if part ~= nil and part ~= "" then
            table.insert(strings, tostring(part))
        end
    end

    text = Searchables.toLower(table.concat(strings, "\n"))
    Searchables.storeItemTexts[storeItem] = text
    return text
end

-- The store item of a list entry the game built around one (or the entry itself if it is a store item)
function Searchables.getEntryStoreItem(entry)
    if type(entry) ~= "table" then
        return nil
    end
    if type(entry.storeItem) == "table" then
        return entry.storeItem
    end
    if entry.xmlFilename ~= nil and entry.name ~= nil and entry.species ~= nil then
        return entry
    end
    return nil
end

-- Text of a list entry. Entries without a store item fall back to their own name/title.
function Searchables.getEntryText(entry)
    local storeItem = Searchables.getEntryStoreItem(entry)
    if storeItem ~= nil then
        return Searchables.getStoreItemText(storeItem)
    end
    if type(entry) ~= "table" then
        return ""
    end

    local strings = {}
    for _, key in ipairs({"name", "title", "displayName"}) do
        if type(entry[key]) == "string" then
            table.insert(strings, entry[key])
        end
    end
    return Searchables.toLower(table.concat(strings, "\n"))
end

-- ---------------------------------------------------------------------------------------------
-- Horsepower and price filters
-- ---------------------------------------------------------------------------------------------
-- Typed among the words: hp>200, hp<=300, 200-300hp, 250hp, $<50k, price>100000, $100k-200k, $144,500.
-- A vehicle with several engine options matches when any of them fits.

-- Horsepower {min, max} per store item, or false for items without an engine. Read from the item's XML, which is slow,
-- so it is cached and filled in the background after loading (see Searchables:update).
Searchables.storeItemPower = setmetatable({}, {__mode = "k"})
Searchables.preloadIndex = 1

-- "144,500" -> 144500, "50k" -> 50000, "1.5m" -> 1500000
function Searchables.parseAmount(text)
    local number, suffix = tostring(text or ""):match("^([%d%.,]+)([km]?)$")
    if number == nil then
        return nil
    end
    number = number:gsub(",", "")
    if suffix == "" then
        -- no suffix: dots are thousands separators too (144.500)
        return tonumber((number:gsub("%.", "")))
    end
    local value = tonumber(number)
    if value == nil then
        return nil
    end
    return value * (suffix == "k" and 1000 or 1000000)
end

-- Joins what people type with spaces, so "hp > 200", "200 hp", "$ 100k - 200k" work like "hp>200", "200hp", "$100k-200k"
function Searchables.normalizeQueryText(text)
    text = Searchables.toLower(text)
    text = text:gsub("€", "$"):gsub("£", "$")
    text = text:gsub("%s*([<>]=?)%s*", "%1")
    text = text:gsub("%s+=%s*", "=")
    text = text:gsub("(%d[km]?)%s*%-%s*(%d)", "%1-%2")
    text = text:gsub("(%d[km]?)%s+hp", "%1hp")
    text = text:gsub("hp%s+([%d<>=])", "hp%1")
    text = text:gsub("price%s+([%d<>=])", "price%1")
    text = text:gsub("%$%s+", "$")
    return text
end

-- A horsepower or price filter from one word, or nil: {kind = "hp"|"price", min, max, minStrict, maxStrict}
function Searchables.parseFilter(word)
    local kind = "hp"
    local rest = word:match("^hp(.+)$") or word:match("^(.+)hp$")
    if rest == nil then
        kind = "price"
        rest = word:match("^%$(.+)$") or word:match("^price(.+)$") or word:match("^(.+)%$$")
    end
    if rest == nil then
        return nil
    end
    rest = rest:gsub("^:", "")

    local operator, amountText = rest:match("^([<>]=?)(.+)$")
    if operator == nil then
        operator, amountText = rest:match("^(=)(.+)$")
    end
    if operator ~= nil then
        local amount = Searchables.parseAmount(amountText)
        if amount == nil then
            return nil
        elseif operator == ">" then
            return {kind = kind, min = amount, minStrict = true}
        elseif operator == ">=" then
            return {kind = kind, min = amount}
        elseif operator == "<" then
            return {kind = kind, max = amount, maxStrict = true}
        elseif operator == "<=" then
            return {kind = kind, max = amount}
        end
        return {kind = kind, min = amount, max = amount}
    end

    local fromText, toText = rest:match("^([%d%.,]+[km]?)%-([%d%.,]+[km]?)$")
    if fromText ~= nil then
        local from, to = Searchables.parseAmount(fromText), Searchables.parseAmount(toText)
        if from == nil or to == nil then
            return nil
        end
        return {kind = kind, min = math.min(from, to), max = math.max(from, to)}
    end

    local amount = Searchables.parseAmount(rest)
    if amount == nil then
        return nil
    end
    return {kind = kind, min = amount, max = amount}
end

-- Half-typed filters ("hp", "hp>", "$", "200-") are ignored instead of searched as words, so the list does not empty
-- out while typing them
function Searchables.isUnfinishedFilter(word)
    return word == "hp" or word == "price" or word:find("[<>=%$]") ~= nil or word:match("^hp") ~= nil
        or word:match("hp$") ~= nil or word:match("^price") ~= nil or word:match("^[%d%.,]+[km]?%-$") ~= nil
end

-- Words and filters typed in a search box
function Searchables.parseQuery(text)
    local query = {words = {}, filters = {}}
    for word in Searchables.normalizeQueryText(text):gmatch("%S+") do
        local filter = Searchables.parseFilter(word)
        if filter ~= nil then
            table.insert(query.filters, filter)
        elseif not Searchables.isUnfinishedFilter(word) then
            table.insert(query.words, word)
        end
    end
    return query
end

function Searchables.isQueryEmpty(query)
    return #query.words == 0 and #query.filters == 0
end

function Searchables.hasFilter(query, kind)
    for _, filter in ipairs(query.filters) do
        if filter.kind == kind then
            return true
        end
    end
    return false
end

-- Lowest and highest horsepower of a vehicle's engine options, or nil for items without an engine. Uses the same
-- spec function the shop uses to show horsepower.
function Searchables.getStoreItemPower(storeItem)
    local power = Searchables.storeItemPower[storeItem]
    if power == nil then
        power = false
        local specType = storeItem.species == StoreSpecies.VEHICLE and g_storeManager:getSpecTypeByName("power") or nil
        if specType ~= nil then
            local ok, minPower, maxPower = pcall(function()
                StoreItemUtil.loadSpecsFromXML(storeItem)
                return specType.getValueFunc(storeItem, nil, nil, nil, true, true)
            end)
            if ok and type(minPower) == "number" then
                power = {minPower, maxPower or minPower}
            end
        end
        Searchables.storeItemPower[storeItem] = power
    end
    if power then
        return power[1], power[2]
    end
    return nil
end

function Searchables.getStoreItemValueRange(storeItem, kind)
    if storeItem == nil then
        return nil
    end
    if kind == "hp" then
        return Searchables.getStoreItemPower(storeItem)
    end
    return storeItem.price, storeItem.price
end

-- Does a value range (low..high) overlap the filter's range
function Searchables.rangeMatches(filter, low, high)
    if filter.min ~= nil and (high < filter.min or (filter.minStrict and high == filter.min)) then
        return false
    end
    if filter.max ~= nil and (low > filter.max or (filter.maxStrict and low == filter.max)) then
        return false
    end
    return true
end

function Searchables.matchesFilters(storeItem, filters)
    for _, filter in ipairs(filters) do
        local low, high = Searchables.getStoreItemValueRange(storeItem, filter.kind)
        if low == nil or not Searchables.rangeMatches(filter, low, high) then
            return false
        end
    end
    return true
end

function Searchables.matchesStoreItem(storeItem, query)
    -- words first: cheap, and spares loading horsepower for items the words already rule out
    return Searchables.matchesWords(Searchables.getStoreItemText(storeItem), query.words)
        and Searchables.matchesFilters(storeItem, query.filters)
end

function Searchables.matchesEntry(entry, query)
    if not Searchables.matchesWords(Searchables.getEntryText(entry), query.words) then
        return false
    end
    return #query.filters == 0 or Searchables.matchesFilters(Searchables.getEntryStoreItem(entry), query.filters)
end

-- Entries of a list matching the query. Returns the list itself when there is nothing to filter.
function Searchables.filterEntries(list, query)
    if Searchables.isQueryEmpty(query) then
        return list
    end
    local matches = {}
    for _, entry in ipairs(list) do
        if Searchables.matchesEntry(entry, query) then
            table.insert(matches, entry)
        end
    end
    return matches
end

-- Reads the horsepower of one more vehicle per frame, so the first horsepower search does not freeze the game
function Searchables.preloadPower()
    local items = g_storeManager:getItems()
    -- skip quickly over items that need no loading, but load at most one per frame
    for _ = 1, 50 do
        local storeItem = items[Searchables.preloadIndex]
        if storeItem == nil then
            Searchables.isPreloadDone = true
            return
        end
        Searchables.preloadIndex = Searchables.preloadIndex + 1
        if storeItem.species == StoreSpecies.VEHICLE and Searchables.storeItemPower[storeItem] == nil then
            Searchables.getStoreItemPower(storeItem)
            return
        end
    end
end

-- True when the object is an instance of the class or of a subclass. Game classes made with Class() have isa(), class()
-- and superClass(), the same calls the game itself uses (unloadingStation:isa(UnloadingStation), controller:class()).
function Searchables.isInstanceOf(object, class)
    if type(object) ~= "table" or class == nil then
        return false
    end
    if type(object.isa) == "function" then
        return object:isa(class)
    end
    if type(object.class) ~= "function" then
        return false
    end
    local current = object:class()
    while current ~= nil do
        if current == class then
            return true
        end
        current = type(current.superClass) == "function" and current:superClass() or nil
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Console commands
-- ---------------------------------------------------------------------------------------------

local function formatPx(x, y)
    return string.format("%4d,%4d", math.floor(x * (g_referenceScreenWidth or 1920) + 0.5), math.floor(y * (g_referenceScreenHeight or 1080) + 0.5))
end

local function dumpElement(element, depth, maxDepth)
    local line = string.format("%s%-18s id=%-24s name=%-20s profile=%-36s pos=%s size=%s%s",
        string.rep("  ", depth), tostring(element.typeName or "?"), tostring(element.id or "-"), tostring(element.name or "-"),
        tostring(element.profile or "-"), formatPx(element.absPosition[1], element.absPosition[2]),
        formatPx(element.absSize[1], element.absSize[2]), element:getIsVisible() and "" or "  (hidden)")
    print(line)
    if depth < maxDepth then
        for _, child in ipairs(element.elements) do
            dumpElement(child, depth + 1, maxDepth)
        end
    end
end

-- Prints the element tree of the open screen (positions in 1920x1080 reference pixels) to find where boxes fit
function Searchables:consoleDumpUi(maxDepthArg)
    local screen = g_gui.currentGui ~= nil and g_gui.currentGui.target or nil
    if screen == nil then
        return "No screen is open. Open the shop or construction screen first (the console works on top of it)."
    end
    local maxDepth = tonumber(maxDepthArg) or 6
    print(string.format("Element tree of '%s' (depth %d):", tostring(g_gui.currentGuiName), maxDepth))
    dumpElement(screen, 0, maxDepth)
    return "Done."
end

-- Nudges a search box by a number of reference pixels, so we can find the right spot in-game
function Searchables:consoleMove(whichArg, dxArg, dyArg)
    local module = ({shop = SearchablesShop, construction = SearchablesConstruction})[tostring(whichArg):lower()]
    local dx, dy = tonumber(dxArg), tonumber(dyArg)
    if module == nil or dx == nil or dy == nil then
        return "Usage: searchablesMove shop|construction <dxPx> <dyPx>   (positive moves right / up)"
    end
    module.OFFSET_X = module.OFFSET_X + dx
    module.OFFSET_Y = module.OFFSET_Y + dy
    module.updateBoxPosition()
    return string.format("Offset is now %d, %d px. Put these values in OFFSET_X / OFFSET_Y to keep them.", module.OFFSET_X, module.OFFSET_Y)
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

function Searchables:loadMap(name)
    -- a dedicated server shows no menus, so there is nothing to style there
    if g_gui ~= nil and g_dedicatedServer == nil then
        g_gui:loadProfiles(Searchables.PROFILES_FILENAME)
    end

    Searchables.preloadIndex = 1
    Searchables.isPreloadDone = g_dedicatedServer ~= nil

    addConsoleCommand("searchablesDumpUi", "Searchables: print the element tree of the open screen", "consoleDumpUi", Searchables, "[maxDepth]")
    addConsoleCommand("searchablesMove", "Searchables: nudge a search box by some pixels", "consoleMove", Searchables, "shop|construction dxPx dyPx")
    Logging.info("[Searchables] Loaded. Search boxes are on the shop and construction screens.")
end

function Searchables:update(dt)
    if not Searchables.isPreloadDone then
        Searchables.preloadPower()
    end
end

function Searchables:deleteMap()
    removeConsoleCommand("searchablesDumpUi")
    removeConsoleCommand("searchablesMove")
    SearchablesShop.delete()
    SearchablesConstruction.delete()
end

addModEventListener(Searchables)
