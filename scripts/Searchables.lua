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

-- The Search action (modDesc.xml): Ctrl+F on the keyboard, right stick click on a controller
Searchables.SEARCH_ACTION = "SEARCHABLES_SEARCH"

-- Registers the Search action in the current input context; returns the event id, or nil if the action is missing.
-- Its text is hidden: the search box itself shows where it goes.
function Searchables.registerSearchAction(target, callback)
    local action = InputAction[Searchables.SEARCH_ACTION]
    if action == nil then
        return nil
    end
    local _, eventId = g_inputBinding:registerActionEvent(action, target, callback, false, true, false, true)
    if eventId ~= nil then
        g_inputBinding:setActionEventTextVisibility(eventId, false)
    end
    return eventId
end

-- Text from translations/translation_<language>.xml
function Searchables.getText(key)
    return g_i18n:getText(key)
end

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
-- Spec filters: price, horsepower, working width, capacity, weight, speed, power needed
-- ---------------------------------------------------------------------------------------------
-- Typed among the words, e.g. hp>200, 200-300hp, $<50k, $144,500, width>9, 6-9m, l>30000, t<10, kph>50, mph<30,
-- needhp<150, affordable. A vehicle with several options (engines, tanks, widths) matches when any of them fits.

-- What can be typed: a keyword in front of the number (hp>200) or behind it (200hp), and what it filters.
-- scale turns the typed number into the unit the game stores (mph -> km/h).
Searchables.FILTER_KEYWORDS = {
    {word = "price", kind = "price", prefix = true},
    {word = "$", kind = "price", prefix = true, suffix = true},
    {word = "needhp", kind = "neededPower", prefix = true},
    {word = "reqhp", kind = "neededPower", prefix = true},
    {word = "hp", kind = "power", prefix = true, suffix = true},
    {word = "ps", kind = "power", prefix = true, suffix = true},
    {word = "width", kind = "width", prefix = true},
    {word = "m", kind = "width", suffix = true},
    {word = "capacity", kind = "capacity", prefix = true},
    {word = "cap", kind = "capacity", prefix = true},
    {word = "liters", kind = "capacity", suffix = true},
    {word = "l", kind = "capacity", prefix = true, suffix = true},
    {word = "weight", kind = "weight", prefix = true},
    {word = "t", kind = "weight", prefix = true, suffix = true},
    {word = "speed", kind = "speed", prefix = true},
    {word = "km/h", kind = "speed", suffix = true},
    {word = "kmh", kind = "speed", prefix = true, suffix = true},
    {word = "kph", kind = "speed", prefix = true, suffix = true},
    {word = "mph", kind = "speed", prefix = true, suffix = true, scale = 1.609344},
}
-- Longest first, so "needhp" is not read as "hp" and "kmh" not as "m"
table.sort(Searchables.FILTER_KEYWORDS, function(a, b)
    return #a.word > #b.word
end)

-- Spec values per store item and kind: {min, max}, or false when the item does not have it. Most come from the item's
-- XML, which is slow to read, so the XML is read in the background after loading (see Searchables.preloadSpecs).
Searchables.specRanges = setmetatable({}, {__mode = "k"})
Searchables.preloadIndex = 1

-- "144,500" -> 144500, "50k" -> 50000, "1.5m" -> 1500000, "144.500" -> 144500, "1.5" -> 1.5
function Searchables.parseAmount(text)
    local number, suffix = tostring(text or ""):match("^([%d%.,]+)([km]?)$")
    if number == nil then
        return nil
    end
    number = number:gsub(",", "")
    -- dots followed by groups of exactly three digits are thousands separators
    if number:match("^%d+%.%d%d%d$") or number:match("^%d+%.%d%d%d%.") then
        number = number:gsub("%.", "")
    end
    local value = tonumber(number)
    if value == nil then
        return nil
    end
    if suffix == "k" then
        return value * 1000
    elseif suffix == "m" then
        return value * 1000000
    end
    return value
end

-- Joins what people type with spaces, so "hp > 200", "200 hp", "$ 100k - 200k" work like "hp>200", "200hp", "$100k-200k"
function Searchables.normalizeQueryText(text)
    text = Searchables.toLower(text)
    text = text:gsub("€", "$"):gsub("£", "$")
    text = text:gsub("%s*([<>]=?)%s*", "%1")
    text = text:gsub("%s+=%s*", "=")
    text = text:gsub("(%d[km]?)%s*%-%s*(%d)", "%1-%2")
    for _, keyword in ipairs(Searchables.FILTER_KEYWORDS) do
        local word = keyword.word:gsub("%p", "%%%0")
        if keyword.suffix then
            text = text:gsub("(%d[km]?)%s+" .. word .. "(%f[%s%z])", "%1" .. keyword.word .. "%2")
        end
        if keyword.prefix then
            text = text:gsub("(%f[%w$]" .. word .. ")%s+([%d<>=])", "%1%2")
        end
    end
    return text
end

-- Every way a word splits into a keyword and the rest ("hp>200" -> hp, ">200"). "$1.5m" splits both as "$" + "1.5m"
-- and as "1.5" + "m"; the caller keeps the first split that makes sense.
function Searchables.getKeywordSplits(word)
    local splits = {}
    for _, keyword in ipairs(Searchables.FILTER_KEYWORDS) do
        local length = #keyword.word
        if keyword.prefix and #word >= length and word:sub(1, length) == keyword.word then
            table.insert(splits, {keyword = keyword, rest = word:sub(length + 1)})
        end
        if keyword.suffix and #word > length and word:sub(-length) == keyword.word then
            table.insert(splits, {keyword = keyword, rest = word:sub(1, -length - 1)})
        end
    end
    return splits
end

-- A spec filter from one word, or nil: {kind, min, max, minStrict, maxStrict}
function Searchables.parseFilter(word)
    if word == "affordable" or word == Searchables.toLower(Searchables.getText("searchables_affordable")) then
        local money = g_currentMission ~= nil and g_currentMission.getMoney ~= nil and g_currentMission:getMoney() or nil
        return money ~= nil and {kind = "price", max = money} or nil
    end

    for _, split in ipairs(Searchables.getKeywordSplits(word)) do
        local filter = Searchables.parseFilterAmount(split.keyword, split.rest)
        if filter ~= nil then
            return filter
        end
    end
    return nil
end

-- The filter for a keyword and the typed amount after (or before) it: ">200", "<=50k", "200-300", "250", or nil
function Searchables.parseFilterAmount(keyword, rest)
    rest = rest:gsub("^:", "")
    if rest == "" then
        return nil
    end

    local scale = keyword.scale or 1
    local function amount(text)
        local value = Searchables.parseAmount(text)
        return value ~= nil and value * scale or nil
    end

    local operator, amountText = rest:match("^([<>]=?)(.+)$")
    if operator == nil then
        operator, amountText = rest:match("^(=)(.+)$")
    end
    if operator ~= nil then
        local value = amount(amountText)
        if value == nil then
            return nil
        elseif operator == ">" then
            return {kind = keyword.kind, min = value, minStrict = true}
        elseif operator == ">=" then
            return {kind = keyword.kind, min = value}
        elseif operator == "<" then
            return {kind = keyword.kind, max = value, maxStrict = true}
        elseif operator == "<=" then
            return {kind = keyword.kind, max = value}
        end
        return {kind = keyword.kind, min = value, max = value}
    end

    local fromText, toText = rest:match("^([%d%.,]+[km]?)%-([%d%.,]+[km]?)$")
    if fromText ~= nil then
        local from, to = amount(fromText), amount(toText)
        if from == nil or to == nil then
            return nil
        end
        return {kind = keyword.kind, min = math.min(from, to), max = math.max(from, to)}
    end

    local value = amount(rest)
    if value == nil then
        return nil
    end
    return {kind = keyword.kind, min = value, max = value}
end

-- Half-typed filters ("hp", "hp>", "width>", "$", "200-") are ignored instead of searched as words, so the list does
-- not empty out while typing them. Plain numbers ("724") stay words.
function Searchables.isUnfinishedFilter(word)
    local function isNumberish(text)
        return text:match("^[<>=:]*[%d%.,]*[km]?%-?[%d%.,]*[km]?$") ~= nil
    end
    for _, split in ipairs(Searchables.getKeywordSplits(word)) do
        if isNumberish(split.rest) then
            return true
        end
    end
    return isNumberish(word) and (word:find("[<>=]") ~= nil or word:sub(-1) == "-")
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

-- ---------------------------------------------------------------------------------------------
-- Spec values
-- ---------------------------------------------------------------------------------------------

-- Lowest and highest of the values a spec function returns with returnValues/returnRange (the shop's own functions)
local function getSpecFunctionRange(storeItem, specName)
    local specType = g_storeManager:getSpecTypeByName(specName)
    if specType == nil or specType.getValueFunc == nil then
        return nil
    end
    local low, high = specType.getValueFunc(storeItem, nil, nil, nil, true, true)
    if type(low) ~= "number" then
        return nil
    end
    return low, type(high) == "number" and high or low
end

-- How each kind is read from a store item (after its specs are loaded). Returns low, high or nil.
Searchables.SPEC_READERS = {
    power = function(storeItem)
        return getSpecFunctionRange(storeItem, "power")
    end,
    weight = function(storeItem)
        return getSpecFunctionRange(storeItem, "weight")
    end,
    capacity = function(storeItem)
        local low, high = getSpecFunctionRange(storeItem, "capacity")
        if low == nil or high == 0 or low == math.huge then
            return nil
        end
        return low, high
    end,
    width = function(storeItem)
        local workingWidth = storeItem.specs.workingWidth
        if type(workingWidth) ~= "table" or workingWidth.width == nil then
            return nil
        end
        return workingWidth.minWidth or workingWidth.width, workingWidth.width
    end,
    -- km/h; tools without an engine have a working speed limit instead
    speed = function(storeItem)
        local speed = storeItem.specs.maxSpeed or storeItem.specs.speedLimit
        if type(speed) ~= "number" then
            return nil
        end
        return speed, speed
    end,
    -- stored in kW like the game's PTO power; turned into hp like the shop shows it
    neededPower = function(storeItem)
        local neededPower = storeItem.specs.neededPower
        if type(neededPower) ~= "table" then
            return nil
        end
        local low, high = math.huge, -math.huge
        for _, value in pairs(neededPower.config or {}) do
            low, high = math.min(low, value), math.max(high, value)
        end
        if low == math.huge then
            low = neededPower.base or 0
            high = neededPower.maxPower or low
        end
        if low == 0 then
            return nil
        end
        local lowHp, highHp = g_i18n:getPower(low), g_i18n:getPower(high)
        return lowHp, highHp
    end,
}

-- Lowest and highest value of a kind for a store item, or nil if it has none
function Searchables.getStoreItemValueRange(storeItem, kind)
    if storeItem == nil then
        return nil
    end
    if kind == "price" then
        return storeItem.price, storeItem.price
    end

    local ranges = Searchables.specRanges[storeItem]
    if ranges == nil then
        ranges = {}
        Searchables.specRanges[storeItem] = ranges
    end

    local range = ranges[kind]
    if range == nil then
        range = false
        local reader = Searchables.SPEC_READERS[kind]
        if reader ~= nil and storeItem.species == StoreSpecies.VEHICLE then
            local ok, low, high = pcall(function()
                StoreItemUtil.loadSpecsFromXML(storeItem)
                if storeItem.specs == nil then
                    return nil
                end
                return reader(storeItem)
            end)
            if ok and type(low) == "number" then
                range = {low, type(high) == "number" and high or low}
            end
        end
        ranges[kind] = range
    end

    if range then
        return range[1], range[2]
    end
    return nil
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
    -- words first: cheap, and spares reading specs for items the words already rule out
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

-- Reads the specs of one more vehicle per frame, so the first spec search does not freeze the game
function Searchables.preloadSpecs()
    local items = g_storeManager:getItems()
    -- skip quickly over items that need no loading, but load at most one per frame
    for _ = 1, 50 do
        local storeItem = items[Searchables.preloadIndex]
        if storeItem == nil then
            Searchables.isPreloadDone = true
            return
        end
        Searchables.preloadIndex = Searchables.preloadIndex + 1
        if storeItem.species == StoreSpecies.VEHICLE and storeItem.specs == nil then
            pcall(StoreItemUtil.loadSpecsFromXML, storeItem)
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
-- In-game help
-- ---------------------------------------------------------------------------------------------

Searchables.HELP_FILENAME = Utils.getFilename("help/helpLine.xml", g_currentModDirectory)

-- Adds the "Searchables" chapter to the Help page in the pause menu, after the map's own help is loaded
function Searchables.loadHelpLines(helpLineManager, superFunc, ...)
    local isLoaded = superFunc(helpLineManager, ...)
    if isLoaded then
        helpLineManager:loadFromXML(Searchables.HELP_FILENAME)
    end
    return isLoaded
end

if HelpLineManager ~= nil then
    HelpLineManager.loadMapData = Utils.overwrittenFunction(HelpLineManager.loadMapData, Searchables.loadHelpLines)
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
        Searchables.preloadSpecs()
    end
end

function Searchables:deleteMap()
    removeConsoleCommand("searchablesDumpUi")
    removeConsoleCommand("searchablesMove")
    SearchablesShop.delete()
    SearchablesConstruction.delete()
end

addModEventListener(Searchables)
