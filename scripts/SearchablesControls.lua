-- SearchablesControls
-- Search box on the controls settings page: filters the list of controls as you type, by action name ("cruise control"),
-- by section ("vehicle") or by key ("ctrl", "f5").
--
-- The settings page feeds its controlsList through getNumberOfSections / getNumberOfItemsInSection /
-- getTitleForSectionHeader / populateCellForItemInSection. To learn what a row says, the game fills a list cell for it
-- and the texts are read back (name and keys). While a search is active the page gets versions of those four functions
-- that skip the rows that do not match; the game's own code still fills every row it shows, with its original section
-- and row, so changing a key works as before.

SearchablesControls = {}

-- The box sits above the right end of the list, moved by these reference pixels (see searchablesMove)
SearchablesControls.OFFSET_X = 0
SearchablesControls.OFFSET_Y = 0
SearchablesControls.GAP = 8

SearchablesControls.frame = nil
SearchablesControls.box = nil
-- {sections = {original section per shown section}, items = {[shown section] = {original row per shown row}}}
SearchablesControls.mapping = nil
-- "section:row" -> lowercase text of that row, until the page rebuilds its list
SearchablesControls.rowTexts = {}

local function getFrameClass()
    return InGameMenuSettingsFrame
end

-- ---------------------------------------------------------------------------------------------
-- Reading rows
-- ---------------------------------------------------------------------------------------------

local function collectTexts(element, texts)
    if type(element.text) == "string" and element.text ~= "" then
        table.insert(texts, element.text)
    end
    for _, child in ipairs(element.elements or {}) do
        collectTexts(child, texts)
    end
    return texts
end

-- A cell of the list that takes a row (section headers do not), to have the game fill it for reading
function SearchablesControls.findProbeCell(frame, list)
    local class = getFrameClass()
    for _, cell in ipairs(list.elements or {}) do
        local ok = pcall(class.populateCellForItemInSection, frame, list, 1, 1, cell)
        if ok and #collectTexts(cell, {}) > 0 then
            return cell
        end
    end
    return nil
end

-- Lowercase text of a row: its name and keys, as the game shows them
function SearchablesControls.getRowText(frame, list, probe, section, index)
    local key = section .. ":" .. index
    local text = SearchablesControls.rowTexts[key]
    if text == nil then
        text = ""
        local ok = pcall(getFrameClass().populateCellForItemInSection, frame, list, section, index, probe)
        if ok then
            text = Searchables.toLower(table.concat(collectTexts(probe, {}), " "))
        end
        SearchablesControls.rowTexts[key] = text
    end
    return text
end

-- Which sections and rows match the query; nil when the box is empty
function SearchablesControls.buildMapping(frame, text)
    local query = Searchables.parseQuery(text)
    if #query.words == 0 and #query.excludes == 0 then
        return nil
    end
    local class = getFrameClass()
    local list = frame.controlsList
    local probe = SearchablesControls.findProbeCell(frame, list)
    if probe == nil then
        return nil
    end

    local mapping = {sections = {}, items = {}, shown = 0, total = 0}
    local sectionCount = class.getNumberOfSections(frame, list) or 1
    for section = 1, sectionCount do
        local title = class.getTitleForSectionHeader ~= nil and class.getTitleForSectionHeader(frame, list, section) or ""
        local count = class.getNumberOfItemsInSection(frame, list, section) or 0
        local kept = {}
        for index = 1, count do
            local rowText = Searchables.toLower(tostring(title)) .. " " .. SearchablesControls.getRowText(frame, list, probe, section, index)
            if Searchables.matchesQueryText(rowText, query) then
                table.insert(kept, index)
            end
        end
        mapping.total = mapping.total + count
        if #kept > 0 then
            table.insert(mapping.sections, section)
            mapping.items[#mapping.sections] = kept
            mapping.shown = mapping.shown + #kept
        end
    end
    return mapping
end

-- ---------------------------------------------------------------------------------------------
-- The filtered list
-- ---------------------------------------------------------------------------------------------

-- The page's list functions while a search is active: shown section/row -> original section/row
function SearchablesControls.installFilter(frame)
    if frame.searchablesFiltered then
        return
    end
    frame.searchablesFiltered = true
    local class = getFrameClass()

    local function isFiltered(page, list)
        return list == page.controlsList and SearchablesControls.mapping ~= nil
    end
    frame.getNumberOfSections = function(page, list, ...)
        if isFiltered(page, list) then
            return #SearchablesControls.mapping.sections
        end
        return class.getNumberOfSections(page, list, ...)
    end
    frame.getNumberOfItemsInSection = function(page, list, section, ...)
        if isFiltered(page, list) then
            return #(SearchablesControls.mapping.items[section] or {})
        end
        return class.getNumberOfItemsInSection(page, list, section, ...)
    end
    frame.getTitleForSectionHeader = function(page, list, section, ...)
        if isFiltered(page, list) then
            return class.getTitleForSectionHeader(page, list, SearchablesControls.mapping.sections[section], ...)
        end
        return class.getTitleForSectionHeader(page, list, section, ...)
    end
    frame.populateCellForItemInSection = function(page, list, section, index, cell, ...)
        if isFiltered(page, list) then
            local mapping = SearchablesControls.mapping
            local items = mapping.items[section]
            if items == nil or items[index] == nil then
                return
            end
            return class.populateCellForItemInSection(page, list, mapping.sections[section], items[index], cell, ...)
        end
        return class.populateCellForItemInSection(page, list, section, index, cell, ...)
    end
end

-- Applies the box's text to the list
function SearchablesControls.applyFilter()
    local frame, box = SearchablesControls.frame, SearchablesControls.box
    if frame == nil or frame.controlsList == nil then
        return
    end
    local ok, mapping = pcall(SearchablesControls.buildMapping, frame, box ~= nil and box:getText() or "")
    SearchablesControls.mapping = ok and mapping or nil
    if not ok then
        Logging.warning("[Searchables] Could not filter the controls list: %s", tostring(mapping))
    end
    if SearchablesControls.mapping ~= nil then
        SearchablesControls.installFilter(frame)
    end

    if box ~= nil then
        if SearchablesControls.mapping ~= nil then
            box:setCount(SearchablesControls.mapping.shown, SearchablesControls.mapping.total)
        else
            box:setCount(nil)
        end
    end
    -- reloading also repaints the cell that was used for reading rows
    frame.controlsList:reloadData()
end

function SearchablesControls.onTextChanged(text)
    SearchablesControls.applyFilter()
end

-- ---------------------------------------------------------------------------------------------
-- Search box
-- ---------------------------------------------------------------------------------------------

function SearchablesControls.createBox(frame)
    SearchablesControls.frame = frame
    SearchablesControls.box = SearchablesSearchBox.new(frame, Searchables.getText("searchables_controlsPlaceholder"), SearchablesControls.onTextChanged)
    local box = SearchablesControls.box
    if box ~= nil then
        box.menu = g_inGameMenu or frame
        box.recentKey = "controls"
        box.onClose = SearchablesControls.reset
    end
end

function SearchablesControls.updateBoxPosition()
    local box, frame = SearchablesControls.box, SearchablesControls.frame
    if box == nil or frame == nil or frame.controlsList == nil then
        return
    end
    local list = frame.controlsList
    local width, height = box:getSize()
    local offsetX, offsetY = getNormalizedScreenValues(SearchablesControls.OFFSET_X, SearchablesControls.OFFSET_Y)
    local _, gap = getNormalizedScreenValues(0, SearchablesControls.GAP)
    local x = list.absPosition[1] + list.absSize[1] - width
    local y = math.min(list.absPosition[2] + list.absSize[2] + gap, 1 - height - gap)
    box:setPosition(x + offsetX, y + offsetY)
end

-- Leaving the menu starts the next visit with the full list
function SearchablesControls.reset()
    SearchablesControls.mapping = nil
    SearchablesControls.rowTexts = {}
    if SearchablesControls.box ~= nil then
        SearchablesControls.box:reset()
        SearchablesControls.box:setCount(nil)
    end
end

function SearchablesControls.delete()
    if SearchablesControls.box ~= nil then
        SearchablesControls.box:delete()
    end
    SearchablesControls.box = nil
    SearchablesControls.frame = nil
    SearchablesControls.mapping = nil
    SearchablesControls.rowTexts = {}
end

-- ---------------------------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------------------------

-- Every frame while the settings page is open: show the box with the controls list, keep it in place
function SearchablesControls.onFrameUpdate(frame, dt)
    if frame.controlsList == nil then
        return
    end
    if SearchablesControls.frame ~= frame then
        SearchablesControls.createBox(frame)
    end
    local box = SearchablesControls.box
    if box == nil then
        return
    end

    local isVisible = frame.controlsList:getIsVisible()
    if isVisible ~= box.root.visible then
        box:setVisible(isVisible)
    end
    if isVisible then
        SearchablesControls.updateBoxPosition()
    end
    box:update()
end

-- The page rebuilds its list when the device or a key changes: read the rows again and keep the search
function SearchablesControls.onSetupControlsView(frame)
    if SearchablesControls.frame ~= frame then
        return
    end
    SearchablesControls.rowTexts = {}
    if SearchablesControls.mapping ~= nil then
        SearchablesControls.applyFilter()
    end
end

local frameClass = getFrameClass()
if frameClass ~= nil and frameClass.populateCellForItemInSection ~= nil then
    frameClass.update = Utils.appendedFunction(frameClass.update, SearchablesControls.onFrameUpdate)
    if frameClass.setupControlsView ~= nil then
        frameClass.setupControlsView = Utils.appendedFunction(frameClass.setupControlsView, SearchablesControls.onSetupControlsView)
    end
else
    Logging.warning("[Searchables] Controls settings page not found, controls search is not available")
end
