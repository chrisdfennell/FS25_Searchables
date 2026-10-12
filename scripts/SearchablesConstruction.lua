-- SearchablesConstruction
-- Search box on the construction screen: filters the buildings (and other items) in every category and tab as you type.
-- Esc clears the search, closing the screen clears it too. The box is made on the screen's first update, because its
-- open and close callbacks were bound when the game loaded its UI, before any mod.
--
-- The screen keeps its lists in screen.items[category][tab]. After the game (re)builds them the full lists are kept
-- aside and the screen gets filtered copies, so everything the screen does with them (showing, selecting, buying)
-- works on what is shown.

SearchablesConstruction = {}

-- The box sits just under the item menu on the left, moved by these reference pixels (see searchablesMove)
SearchablesConstruction.OFFSET_X = 0
SearchablesConstruction.OFFSET_Y = 0
SearchablesConstruction.GAP = 8

SearchablesConstruction.screen = nil
SearchablesConstruction.box = nil
SearchablesConstruction.originals = nil
SearchablesConstruction.hasWarned = false

-- ---------------------------------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------------------------------

-- Keeps the full lists the game just built. Returns false if the lists do not look like screen.items[category][tab].
function SearchablesConstruction.keepOriginals(screen)
    SearchablesConstruction.originals = nil

    local items = screen.items
    if type(items) ~= "table" then
        return false
    end

    local originals = {}
    for categoryIndex, tabs in pairs(items) do
        if type(tabs) ~= "table" then
            return false
        end
        originals[categoryIndex] = {}
        for tabIndex, list in pairs(tabs) do
            if type(list) ~= "table" then
                return false
            end
            originals[categoryIndex][tabIndex] = list
        end
    end

    SearchablesConstruction.originals = originals
    return true
end

-- Gives the screen the lists filtered by the current search (or the full lists when the box is empty)
function SearchablesConstruction.applyFilter(screen)
    local originals = SearchablesConstruction.originals
    if originals == nil then
        return
    end

    local box = SearchablesConstruction.box
    local query = Searchables.parseQuery(box ~= nil and box:getText() or "")
    local shown, total = 0, 0

    for categoryIndex, tabs in pairs(originals) do
        for tabIndex, list in pairs(tabs) do
            local filtered = Searchables.filterEntries(list, query)
            screen.items[categoryIndex][tabIndex] = filtered
            shown = shown + #filtered
            total = total + #list
        end
    end

    if box ~= nil then
        if not Searchables.isQueryEmpty(query) then
            box:setCount(shown, total)
        else
            box:setCount(nil)
        end
    end
end

function SearchablesConstruction.onTextChanged(text)
    local screen = SearchablesConstruction.screen
    if screen == nil or SearchablesConstruction.originals == nil then
        return
    end

    SearchablesConstruction.applyFilter(screen)
    if screen.itemList ~= nil then
        screen.itemList:reloadData()
    end
end

-- Menu actions the screen registered while typing went into the text input's context and are gone now; let the
-- screen register them again in its own context
function SearchablesConstruction.onCaptureEnded()
    local screen = SearchablesConstruction.screen
    if screen ~= nil and screen.updateMenuState ~= nil then
        screen:updateMenuState()
    end
end

-- ---------------------------------------------------------------------------------------------
-- Search box
-- ---------------------------------------------------------------------------------------------

-- Closing the screen starts the next visit with the full lists
function SearchablesConstruction.onScreenClosed()
    local screen, box = SearchablesConstruction.screen, SearchablesConstruction.box
    if box ~= nil and box:getText() ~= "" then
        box:reset()
        box:setCount(nil)
        SearchablesConstruction.applyFilter(screen)
    end
end

function SearchablesConstruction.createBox(screen)
    SearchablesConstruction.screen = screen
    SearchablesConstruction.box = SearchablesSearchBox.new(screen, Searchables.getText("searchables_constructionPlaceholder"), SearchablesConstruction.onTextChanged)
    if SearchablesConstruction.box ~= nil then
        SearchablesConstruction.box.onCaptureEnded = SearchablesConstruction.onCaptureEnded
        SearchablesConstruction.box.onClose = SearchablesConstruction.onScreenClosed
    end
end

function SearchablesConstruction.updateBoxPosition()
    local box, screen = SearchablesConstruction.box, SearchablesConstruction.screen
    if box == nil then
        return
    end

    local width, height = box:getSize()
    local offsetX, offsetY = getNormalizedScreenValues(SearchablesConstruction.OFFSET_X, SearchablesConstruction.OFFSET_Y)
    local _, gap = getNormalizedScreenValues(0, SearchablesConstruction.GAP)
    local menuBox = screen.menuBox
    local x, y
    if menuBox ~= nil then
        x = menuBox.absPosition[1]
        y = menuBox.absPosition[2] - gap - height
        -- no room under the menu: go above it, and stay on screen
        if y < gap then
            y = math.min(menuBox.absPosition[2] + menuBox.absSize[2] + gap, 1 - height - gap)
        end
    else
        local marginX, marginY = getNormalizedScreenValues(40, 40)
        x, y = marginX, 1 - height - marginY
    end
    box:setPosition(x + offsetX, y + offsetY)
end

function SearchablesConstruction.delete()
    if SearchablesConstruction.box ~= nil then
        SearchablesConstruction.box:delete()
    end
    SearchablesConstruction.box = nil
    SearchablesConstruction.screen = nil
    SearchablesConstruction.originals = nil
end

-- ---------------------------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------------------------

-- The screen rebuilds its lists on open and whenever what is buyable changes
function SearchablesConstruction.onRebuildData(screen)
    if not SearchablesConstruction.keepOriginals(screen) then
        if not SearchablesConstruction.hasWarned then
            SearchablesConstruction.hasWarned = true
            Logging.warning("[Searchables] Construction screen lists are not laid out as expected, construction search is off")
        end
        return
    end
    SearchablesConstruction.applyFilter(screen)
end

-- Runs every frame while the construction screen is open (its open/close callbacks were bound before mods loaded)
function SearchablesConstruction.onScreenUpdate(screen, dt)
    if SearchablesConstruction.screen ~= screen then
        SearchablesConstruction.createBox(screen)
    end
    local box = SearchablesConstruction.box
    if box == nil then
        return
    end

    local isVisible = SearchablesConstruction.originals ~= nil and (screen.menuBox == nil or screen.menuBox:getIsVisible())
    if isVisible ~= box.root.visible then
        box:setVisible(isVisible)
    end

    if isVisible then
        SearchablesConstruction.updateBoxPosition()
    end
    box:update()
end

if ConstructionScreen ~= nil then
    ConstructionScreen.rebuildData = Utils.appendedFunction(ConstructionScreen.rebuildData, SearchablesConstruction.onRebuildData)
    ConstructionScreen.update = Utils.appendedFunction(ConstructionScreen.update, SearchablesConstruction.onScreenUpdate)
else
    Logging.warning("[Searchables] Construction screen not found, construction search is not available")
end
