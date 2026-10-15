-- SearchablesSearchBox
-- A text box added to an open screen or menu page. Click it and type: onChanged(text) runs every time the text changes.
-- Enter or a click elsewhere stops typing and keeps the search, Esc clears it.
-- Optional fields the owner can set after new(): menu (the tabbed menu the box lives in, see below), onCaptureEnded,
-- onEnterPressed, onClose, recentKey (remembers searches under that name and offers them while the box is empty).

SearchablesSearchBox = {}
local SearchablesSearchBox_mt = Class(SearchablesSearchBox)

-- fs25_textInputIconBox is 31px wide and anchored outside the right edge of the text input
SearchablesSearchBox.ICON_BOX_WIDTH = 31

-- Every box made, to find the one being typed in (weak, so deleted boxes drop out)
SearchablesSearchBox.instances = setmetatable({}, {__mode = "k"})

-- The view element the game loaded for a screen or frame. Mouse, key, open and close events go through it (and its
-- children); the controller itself only gets what the view did not use.
function SearchablesSearchBox.getScreenView(screen)
    local view = g_gui.screens ~= nil and g_gui.screens[screen:class()] or nil
    return view or screen.elements[1]
end

-- Loads gui/searchBox.xml into the screen's view, as its last child so it is drawn on top and gets mouse events first.
-- The screen is the target of the text input: while typing, the text input switches to its own input context and
-- turns the screen's input off, so typed letters do not trigger menu actions.
function SearchablesSearchBox.new(screen, placeholder, onChanged)
    local view = SearchablesSearchBox.getScreenView(screen)
    if view == nil then
        Logging.error("[Searchables] Screen '%s' has no view to add a search box to", tostring(screen.name))
        return nil
    end

    local xmlFile = loadXMLFile("SearchablesSearchBox", Searchables.SEARCH_BOX_FILENAME)
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[Searchables] Could not load '%s'", Searchables.SEARCH_BOX_FILENAME)
        return nil
    end

    local numElements = #view.elements
    g_gui:loadGuiRec(xmlFile, "GUI", view, screen)
    delete(xmlFile)

    local root = view.elements[numElements + 1]
    local input = root ~= nil and root:getDescendantById("searchablesInput") or nil
    if input == nil then
        Logging.error("[Searchables] Search box could not be created")
        if root ~= nil then
            root:delete()
        end
        return nil
    end

    local self = setmetatable({}, SearchablesSearchBox_mt)
    self.screen = screen
    self.menu = screen
    self.root = root
    self.input = input
    self.placeholder = root:getDescendantById("searchablesPlaceholder")
    self.countText = root:getDescendantById("searchablesCount")
    self.onChanged = onChanged
    self.lastText = ""
    self.wasCapturing = false
    self.menuButtonsPending = false

    self.placeholder:setText(placeholder or Searchables.getText("searchables_placeholder"))

    -- raiseCallback passes the target (the screen) first
    input.onEscPressedCallback = function()
        self:clear()
    end
    input.onEnterPressedCallback = function()
        self:checkTextChanged()
        if self.onEnterPressed ~= nil then
            self.onEnterPressed(self:getText())
        end
    end
    -- the screen's view passes its close on to its children, so this is how the box learns the screen closed
    root.onCloseCallback = function()
        if self.onClose ~= nil then
            self.onClose()
        end
    end

    -- recent searches are drawn under the box and clicked there, so the root draws and takes mouse events for them
    local rootDraw, rootMouseEvent = root.draw, root.mouseEvent
    root.draw = function(element, ...)
        rootDraw(element, ...)
        self:drawRecentSearches()
    end
    root.mouseEvent = function(element, posX, posY, isDown, isUp, button, eventUsed)
        if self:onRecentMouseEvent(posX, posY, isDown, isUp, button, eventUsed) then
            return true
        end
        return rootMouseEvent(element, posX, posY, isDown, isUp, button, eventUsed)
    end

    root:updateAbsolutePosition()
    SearchablesSearchBox.instances[self] = true

    return self
end

-- ---------------------------------------------------------------------------------------------
-- Recent searches
-- ---------------------------------------------------------------------------------------------

SearchablesSearchBox.RECENT_ROW_HEIGHT = 24
SearchablesSearchBox.RECENT_TEXT_SIZE = 15
SearchablesSearchBox.RECENT_PADDING_X = 10
SearchablesSearchBox.RECENT_GAP = 6

-- Shown while typing in an empty box
function SearchablesSearchBox:getShownRecentSearches()
    if self.recentKey == nil or not self:getIsCapturing() or self.input:getText() ~= "" then
        return nil
    end
    local list = Searchables.getRecentSearches(self.recentKey)
    return #list > 0 and list or nil
end

function SearchablesSearchBox:drawRecentSearches()
    self.recentRows = {}
    local list = self:getShownRecentSearches()
    if list == nil then
        return
    end

    local width = self:getSize()
    local _, rowHeight = getNormalizedScreenValues(0, SearchablesSearchBox.RECENT_ROW_HEIGHT)
    local _, textSize = getNormalizedScreenValues(0, SearchablesSearchBox.RECENT_TEXT_SIZE)
    local padX = getNormalizedScreenValues(SearchablesSearchBox.RECENT_PADDING_X, 0)
    local _, gap = getNormalizedScreenValues(0, SearchablesSearchBox.RECENT_GAP)
    local x = self.root.absPosition[1]
    local top = self.root.absPosition[2] - gap
    local rows = #list + 1
    drawFilledRect(x, top - rows * rowHeight, width, rows * rowHeight, 0, 0, 0, 0.8)

    local textY = (rowHeight - textSize) * 0.5 + textSize * 0.15
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(0.7, 0.7, 0.7, 1)
    renderText(x + padX, top - rowHeight + textY, textSize, Searchables.getText("searchables_recent"))
    for i, text in ipairs(list) do
        local y = top - (i + 1) * rowHeight
        if self.hoveredRecent == i then
            drawFilledRect(x, y, width, rowHeight, 1, 1, 1, 0.12)
            setTextColor(1, 0.85, 0.1, 1)
        else
            setTextColor(1, 1, 1, 1)
        end
        renderText(x + padX, y + textY, textSize, Utils.limitTextToWidth(text, textSize, width - padX * 2, false, "..."))
        table.insert(self.recentRows, {x = x, y = y, width = width, height = rowHeight, text = text})
    end
    setTextColor(1, 1, 1, 1)
end

-- A click on a recent search types it into the box (and the box keeps the cursor)
function SearchablesSearchBox:onRecentMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    self.hoveredRecent = nil
    if eventUsed or self:getShownRecentSearches() == nil then
        return false
    end
    for i, row in ipairs(self.recentRows or {}) do
        if posX >= row.x and posX <= row.x + row.width and posY >= row.y and posY <= row.y + row.height then
            self.hoveredRecent = i
            if button == Input.MOUSE_BUTTON_LEFT and (isDown or isUp) then
                if isUp then
                    self.input:setText(row.text)
                    self:checkTextChanged()
                end
                return true
            end
            return false
        end
    end
    return false
end

-- Only while still attached: when the game deleted the screen first, the box went with it
function SearchablesSearchBox:delete()
    SearchablesSearchBox.instances[self] = nil
    if self.root.parent ~= nil then
        self:releaseInput()
        self.root:delete()
    end
end

function SearchablesSearchBox:getText()
    return self.input:getText()
end

function SearchablesSearchBox:hasText()
    return #Searchables.getSearchWords(self.input:getText()) > 0
end

function SearchablesSearchBox:getIsCapturing()
    return self.input.isCapturingInput == true
end

-- Empties the box and tells the owner, so the full list comes back
function SearchablesSearchBox:clear()
    self.input:setText("")
    self:checkTextChanged()
end

-- Empties the box without telling the owner (for when the owner resets its own state, e.g. leaving a page)
function SearchablesSearchBox:reset()
    self.input:setText("")
    self.lastText = ""
end

-- Stop typing (the text stays)
function SearchablesSearchBox:releaseInput()
    if self.input.forcePressed then
        self.input:setForcePressed(false)
    end
end

-- Start typing. withoutDelay: for picking up again after the owner had to release input to change pages, so no keys
-- get lost. Without it the text input ignores keys for a moment, so the key of a hotkey that opened it is not typed.
function SearchablesSearchBox:captureInput(withoutDelay)
    if not self.input.forcePressed then
        self.input:setForcePressed(true)
        if withoutDelay then
            self.input.blockTime = 0
        end
    end
end

-- Jump into the box from the Search action (Ctrl+F / right stick on a controller). Where the platform has an on-screen
-- keyboard (Steam Deck, Big Picture) it opens too, so the search can be typed without a keyboard.
function SearchablesSearchBox:focus()
    if not self.root:getIsVisible() then
        return false
    end
    self:captureInput()
    self.input:openIme()
    return true
end

function SearchablesSearchBox:setVisible(isVisible)
    if not isVisible then
        self:releaseInput()
    end
    self.root:setVisible(isVisible)
end

function SearchablesSearchBox:getIsVisible()
    return self.root:getIsVisible()
end

-- Positions the bottom left corner of the box (screen coordinates 0..1)
function SearchablesSearchBox:setPosition(x, y)
    self.root:setAbsolutePosition(x, y)
end

-- Size of the box in screen coordinates, including the icon box that sticks out on its right
function SearchablesSearchBox:getSize()
    local iconWidth = getNormalizedScreenValues(SearchablesSearchBox.ICON_BOX_WIDTH, 0)
    return self.root.absSize[1] + iconWidth, self.root.absSize[2]
end

-- "12 of 40", or "12 found" when there is no total. nil clears it.
function SearchablesSearchBox:setCount(shown, total)
    if shown == nil then
        self.countText:setText("")
    elseif shown == 0 then
        self.countText:setText(Searchables.getText("searchables_countNone"))
    elseif total == nil or shown == total then
        self.countText:setText(string.format(Searchables.getText("searchables_countFound"), shown))
    else
        self.countText:setText(string.format(Searchables.getText("searchables_countOf"), shown, total))
    end
end

function SearchablesSearchBox:checkTextChanged()
    local text = self.input:getText()
    if text ~= self.lastText then
        self.lastText = text
        if self.onChanged ~= nil then
            self.onChanged(text)
        end
    end
end

-- Call every frame while the screen is open. Polling also catches pasted text, which raises no callback.
function SearchablesSearchBox:update()
    self:checkTextChanged()

    local isCapturing = self:getIsCapturing()
    self.placeholder:setVisible(not isCapturing and self.input:getText() == "")

    if self.wasCapturing and not isCapturing then
        if self.recentKey ~= nil then
            Searchables.addRecentSearch(self.recentKey, self.input:getText())
        end
        -- the menu buttons it wanted to register while typing go into its own input context now
        if self.menuButtonsPending then
            self.menuButtonsPending = false
            local menu = self.menu
            if menu ~= nil and menu.updateButtonsPanel ~= nil and menu.currentPage ~= nil then
                menu:updateButtonsPanel(menu.currentPage)
            end
        end
        if self.onCaptureEnded ~= nil then
            self.onCaptureEnded()
        end
    end
    self.wasCapturing = isCapturing
end

-- ---------------------------------------------------------------------------------------------
-- Menu buttons while typing
-- ---------------------------------------------------------------------------------------------

-- Tabbed menus register their bottom button actions in the current input context. While a box is being typed in that
-- is the text input's context, which is thrown away when typing ends, and the buttons would stop working. So the menu
-- waits until typing ends (see update).
function SearchablesSearchBox.assignMenuButtonInfo(menu, superFunc, ...)
    for box in pairs(SearchablesSearchBox.instances) do
        if box.menu == menu and box:getIsCapturing() then
            box.menuButtonsPending = true
            return
        end
    end
    return superFunc(menu, ...)
end

for _, className in ipairs({"ShopMenu", "InGameMenu"}) do
    local menuClass = _G[className]
    if menuClass ~= nil then
        menuClass.assignMenuButtonInfo = Utils.overwrittenFunction(menuClass.assignMenuButtonInfo, SearchablesSearchBox.assignMenuButtonInfo)
    end
end
