-- SearchablesShop
-- Search box on the shop screen:
--  * on a list of items (a category, a brand, ...) it filters that list as you type
--  * on the tile pages (categories, brands, packs, DLCs) typing searches the whole shop and lists the results
-- Esc, going back or switching tabs clears the search.

SearchablesShop = {}

-- The box sits under the Balance panel (or, if that is not found, at the right end of the bottom button bar),
-- moved by these reference pixels (see searchablesMove)
SearchablesShop.OFFSET_X = 0
SearchablesShop.OFFSET_Y = 0
SearchablesShop.BALANCE_GAP = 12
SearchablesShop.BALANCE_PROFILES = {fs25_shopMoneyBoxBg = true, fs25_shopMoneySlotsBoxBg = true}

-- Whole-shop search starts at this many characters; a single letter matches nearly everything
SearchablesShop.MIN_GLOBAL_SEARCH_LENGTH = 2

SearchablesShop.RESULTS_CATEGORY = "SEARCHABLES"

-- Filtered list -> full list it came from, so a filtered list the game hands back is not taken as the full list
SearchablesShop.originalLists = setmetatable({}, {__mode = "k"})
-- Display items made for whole-shop results, reused while typing (making them is the slow part)
SearchablesShop.displayItemCache = {}

SearchablesShop.menu = nil
SearchablesShop.box = nil
SearchablesShop.lastPageId = nil
SearchablesShop.isShowingResults = false
SearchablesShop.isClosingResults = false

-- ---------------------------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------------------------

function SearchablesShop.isItemsPage(menu, page)
    return page ~= nil and (page == menu.pageShopItemDetails or Searchables.isInstanceOf(page, ShopItemsFrame))
end

function SearchablesShop.isTilesPage(menu, page)
    return page ~= nil and Searchables.isInstanceOf(page, ShopCategoriesFrame)
end

function SearchablesShop.getQuery()
    local box = SearchablesShop.box
    return Searchables.parseQuery(box ~= nil and box:getText() or "")
end

-- Pages change by pushing frames; the text input has to let go of input meanwhile, or the menu would register its
-- button actions in the text input's context and lose them when typing ends
function SearchablesShop.withInputReleased(func)
    local box = SearchablesShop.box
    local wasCapturing = box:getIsCapturing()
    box:releaseInput()
    func()
    if wasCapturing then
        box:captureInput(true)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Whole-shop search
-- ---------------------------------------------------------------------------------------------

-- Same rule the game uses for what the shop lists
function SearchablesShop.isBuyable(storeItem)
    return not storeItem.isBundleItem and storeItem.showInStore
        and (storeItem.species == StoreSpecies.VEHICLE or storeItem.species == StoreSpecies.HANDTOOL)
        and g_storeManager:getIsItemUnlocked(storeItem)
end

local function compareByName(a, b)
    return a.sortName < b.sortName
end

local function compareByValue(a, b)
    if a.sortValue ~= b.sortValue then
        return a.sortValue < b.sortValue
    end
    return a.sortName < b.sortName
end

-- Display items for every buyable store item matching the query. With a filter they are sorted by its value, lowest
-- first; otherwise items with every word in their name come first, then by name.
function SearchablesShop.findDisplayItems(query)
    local nameMatches, otherMatches = {}, {}
    -- sorted by the first filter typed: "hp>200" by horsepower, "$<50k" by price, "width>9" by width
    local sortKind = query.filters[1] ~= nil and query.filters[1].kind or nil

    for _, storeItem in ipairs(g_storeManager:getItems()) do
        if SearchablesShop.isBuyable(storeItem) and Searchables.matchesStoreItem(storeItem, query) then
            local sortName = Searchables.toLower(storeItem.name)
            local match = {storeItem = storeItem, sortName = sortName}
            if sortKind ~= nil then
                local _, high = Searchables.getStoreItemValueRange(storeItem, sortKind)
                match.sortValue = high or 0
                table.insert(otherMatches, match)
            elseif Searchables.matchesWords(sortName, query.words) then
                table.insert(nameMatches, match)
            else
                table.insert(otherMatches, match)
            end
        end
    end

    table.sort(nameMatches, compareByName)
    table.sort(otherMatches, sortKind ~= nil and compareByValue or compareByName)

    local displayItems = {}
    for _, matches in ipairs({nameMatches, otherMatches}) do
        for _, match in ipairs(matches) do
            local displayItem = SearchablesShop.displayItemCache[match.storeItem]
            if displayItem == nil then
                displayItem = g_shopController:makeDisplayItem(match.storeItem)
                SearchablesShop.displayItemCache[match.storeItem] = displayItem
            end
            if displayItem ~= nil then
                table.insert(displayItems, displayItem)
            end
        end
    end
    return displayItems
end

-- Shows the results in the shop's item list, opening it on top of the tile page the first time
function SearchablesShop.showResults(query, text)
    local menu = SearchablesShop.menu
    local frame = menu.pageShopItemDetails
    local items = SearchablesShop.findDisplayItems(query)
    local title = string.format("%s: %s", Searchables.getText("searchables_resultsTitle"), string.trim(text))

    SearchablesShop.withInputReleased(function()
        menu.currentCategoryName = "misc"
        if ShopMenu.DETAILS ~= nil then
            menu.currentItemDetailsType = ShopMenu.DETAILS.VEHICLE
        end
        menu.currentDisplayItems = items
        frame:setDisplayItems(items)
        frame:setCategory(SearchablesShop.RESULTS_CATEGORY, title, ShopMenu.SLICE_ID ~= nil and ShopMenu.SLICE_ID.VEHICLES or nil)

        if not SearchablesShop.isShowingResults then
            SearchablesShop.isShowingResults = true
            menu:pushDetail(frame)
        end

        if frame.resetListSelection ~= nil then
            frame:resetListSelection()
        end
    end)
end

-- Back to the tile page the search started on, keeping what is typed so far
function SearchablesShop.closeResults()
    local menu = SearchablesShop.menu
    SearchablesShop.withInputReleased(function()
        SearchablesShop.isClosingResults = true
        menu:popDetail()
        SearchablesShop.isClosingResults = false
    end)
    SearchablesShop.isShowingResults = false
end

-- ---------------------------------------------------------------------------------------------
-- Search box
-- ---------------------------------------------------------------------------------------------

function SearchablesShop.onTextChanged(text)
    local menu = SearchablesShop.menu
    local page = menu.currentPage
    local query = Searchables.parseQuery(text)
    -- a horsepower or price filter alone is enough; words need a couple of letters
    local isLongEnough = #query.filters > 0 or utf8Strlen(table.concat(query.words, " ")) >= SearchablesShop.MIN_GLOBAL_SEARCH_LENGTH

    if SearchablesShop.isShowingResults then
        if isLongEnough then
            SearchablesShop.showResults(query, text)
        else
            SearchablesShop.closeResults()
        end
    elseif SearchablesShop.isTilesPage(menu, page) then
        if isLongEnough then
            SearchablesShop.showResults(query, text)
        end
    elseif SearchablesShop.isItemsPage(menu, page) and page.searchablesItems ~= nil then
        page:setDisplayItems(page.searchablesItems, unpack(page.searchablesArgs or {}))
    end
end

function SearchablesShop.createBox(menu)
    SearchablesShop.menu = menu
    SearchablesShop.isShowingResults = false
    SearchablesShop.box = SearchablesSearchBox.new(menu, Searchables.getText("searchables_shopPlaceholder"), SearchablesShop.onTextChanged)
    if SearchablesShop.box ~= nil then
        SearchablesShop.box.recentKey = "shop"
    end
end

-- The dark "Balance" panel at the top of the shop (the wider variant also shows slots). Searching the view is not free,
-- so a found panel is kept while visible and a missing one is looked for again at most twice a second.
function SearchablesShop.findBalancePanel(menu)
    local panel = SearchablesShop.balancePanel
    if panel ~= nil and panel:getIsVisible() then
        return panel
    end
    if g_time < (SearchablesShop.nextBalanceSearchTime or 0) then
        return nil
    end
    SearchablesShop.nextBalanceSearchTime = g_time + 500

    local view = SearchablesSearchBox.getScreenView(menu)
    local matches = view:getDescendants(function(element)
        return SearchablesShop.BALANCE_PROFILES[element.profile] and element:getIsVisible()
    end)
    SearchablesShop.balancePanel = matches[1]
    return matches[1]
end

function SearchablesShop.updateBoxPosition()
    local box, menu = SearchablesShop.box, SearchablesShop.menu
    if box == nil then
        return
    end

    local width, height = box:getSize()
    local offsetX, offsetY = getNormalizedScreenValues(SearchablesShop.OFFSET_X, SearchablesShop.OFFSET_Y)
    local balance = SearchablesShop.findBalancePanel(menu)
    local panel = menu.buttonsPanel
    local x, y
    if balance ~= nil then
        local _, gap = getNormalizedScreenValues(0, SearchablesShop.BALANCE_GAP)
        x = balance.absPosition[1]
        y = balance.absPosition[2] - gap - height
    elseif panel ~= nil then
        x = panel.absPosition[1] + panel.absSize[1] - width
        y = panel.absPosition[2] + (panel.absSize[2] - height) * 0.5
    else
        local marginX, marginY = getNormalizedScreenValues(40, 40)
        x, y = 1 - width - marginX, marginY
    end
    box:setPosition(x + offsetX, y + offsetY)
end

function SearchablesShop.delete()
    if SearchablesShop.box ~= nil then
        SearchablesShop.box:delete()
    end
    SearchablesShop.box = nil
    SearchablesShop.menu = nil
    SearchablesShop.balancePanel = nil
    SearchablesShop.isShowingResults = false
    SearchablesShop.displayItemCache = {}
end

-- ---------------------------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------------------------

-- Every list the game hands the items frame passes through here, so the filter also survives the game refreshing it
function SearchablesShop.setDisplayItems(frame, superFunc, items, ...)
    if type(items) ~= "table" then
        return superFunc(frame, items, ...)
    end

    local original = SearchablesShop.originalLists[items] or items
    frame.searchablesItems = original
    frame.searchablesArgs = {...}

    local query = SearchablesShop.getQuery()
    local shown = Searchables.filterEntries(original, query)
    if shown ~= original then
        SearchablesShop.originalLists[shown] = original
    end

    -- the menu keeps its own reference to the list; keep it pointing at what is shown
    local menu = g_shopMenu
    if menu ~= nil and (menu.currentDisplayItems == items or menu.currentDisplayItems == original) then
        menu.currentDisplayItems = shown
    end

    local box = SearchablesShop.box
    if box ~= nil then
        if not Searchables.isQueryEmpty(query) then
            box:setCount(#shown, #original)
        else
            box:setCount(nil)
        end
    end

    return superFunc(frame, shown, ...)
end

function SearchablesShop.resetSearch()
    SearchablesShop.isShowingResults = false
    if SearchablesShop.box ~= nil then
        SearchablesShop.box:reset()
        SearchablesShop.box:setCount(nil)
    end
end

-- Runs every frame while the shop is open. The menu's open, close and page change callbacks were bound when the game
-- loaded its UI, before any mod, so hooking them would do nothing; update is called on the menu directly.
-- (Closing the menu also closes the text input, because the box is part of the menu's view.)
function SearchablesShop.onMenuUpdate(menu, dt)
    -- created once per menu; if that failed the error is logged and the shop works as usual
    if SearchablesShop.menu ~= menu then
        SearchablesShop.createBox(menu)
        SearchablesShop.lastPageId = menu.currentPageId
    end
    local box = SearchablesShop.box
    if box == nil then
        return
    end

    -- another tab: start over. Opening a list or the results keeps the tab, so this does not fire for those.
    if menu.currentPageId ~= SearchablesShop.lastPageId then
        SearchablesShop.lastPageId = menu.currentPageId
        SearchablesShop.resetSearch()
    end

    local page = menu.currentPage
    local isVisible = SearchablesShop.isItemsPage(menu, page) or SearchablesShop.isTilesPage(menu, page)
    if isVisible ~= box.root.visible then
        box:setVisible(isVisible)
    end

    if isVisible then
        SearchablesShop.updateBoxPosition()
    end
    -- also while hidden, so the end of typing is noticed and deferred menu buttons get registered
    box:update()
end

-- Going back from a list (or the results) clears the search, unless the search itself closed the results
function SearchablesShop.onPopDetail(menu)
    if SearchablesShop.menu ~= menu or SearchablesShop.isClosingResults then
        return
    end
    SearchablesShop.resetSearch()
end

-- The Search action (Ctrl+F / right stick) jumps into the box. The menu registers its button actions on every page
-- change and removes the ones in customButtonEvents before the next, so the Search action goes in there too.
-- While typing the menu waits with its buttons (see SearchablesSearchBox), so this then waits as well.
function SearchablesShop.onMenuButtonsAssigned(menu)
    local box = SearchablesShop.box
    if box == nil or SearchablesShop.menu ~= menu or box:getIsCapturing() then
        return
    end
    local eventId = Searchables.registerSearchAction(SearchablesShop, SearchablesShop.onSearchAction)
    if eventId ~= nil and menu.customButtonEvents ~= nil then
        table.insert(menu.customButtonEvents, eventId)
    end
end

function SearchablesShop:onSearchAction()
    if SearchablesShop.box ~= nil then
        SearchablesShop.box:focus()
    end
end

if ShopMenu ~= nil and ShopItemsFrame ~= nil and ShopCategoriesFrame ~= nil then
    ShopItemsFrame.setDisplayItems = Utils.overwrittenFunction(ShopItemsFrame.setDisplayItems, SearchablesShop.setDisplayItems)
    ShopMenu.update = Utils.appendedFunction(ShopMenu.update, SearchablesShop.onMenuUpdate)
    ShopMenu.popDetail = Utils.appendedFunction(ShopMenu.popDetail, SearchablesShop.onPopDetail)
    ShopMenu.assignMenuButtonInfo = Utils.appendedFunction(ShopMenu.assignMenuButtonInfo, SearchablesShop.onMenuButtonsAssigned)
else
    Logging.warning("[Searchables] Shop menu not found, shop search is not available")
end
