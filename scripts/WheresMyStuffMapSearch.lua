-- WheresMyStuffMapSearch
-- Search box at the top of the in-game map: click it (or press Ctrl+F) and type what you are looking for. A moment
-- after you stop typing every match gets a big arrow that shrinks down onto it; Enter also centers the map on the
-- nearest. Esc or an empty box clears the markers. Hooks the game's IngameMapElement, so it also shows on other full
-- screen maps.

WheresMyStuffMapSearch = {}

WheresMyStuffMapSearch.ARROW_ICON = Utils.getFilename("icon_arrow.dds", g_currentModDirectory)

-- Arrow animation in pixels / milliseconds: starts big, shrinks onto the target, then bobs gently
WheresMyStuffMapSearch.ARROW_START_SIZE = 160
WheresMyStuffMapSearch.ARROW_END_SIZE = 40
WheresMyStuffMapSearch.SHRINK_DURATION = 900
WheresMyStuffMapSearch.STAGGER = 40
WheresMyStuffMapSearch.MAX_STAGGERED = 10
WheresMyStuffMapSearch.BOB_HEIGHT = 4
WheresMyStuffMapSearch.BOB_PERIOD = 1200
-- Gap between the arrow tip and the target, so the tip sits on top of the marker dot
WheresMyStuffMapSearch.TIP_GAP = 8

-- Only the nearest results get an arrow; the rest still get a marker dot
WheresMyStuffMapSearch.MAX_ARROWS = 40

-- Search box, centered at the top of the map
WheresMyStuffMapSearch.BOX_TOP_OFFSET = 110

-- Search this long after the last key, so the arrows do not restart on every letter
WheresMyStuffMapSearch.SEARCH_DELAY = 300
-- Only maps at least this wide (share of the screen) get a box; small preview maps do not
WheresMyStuffMapSearch.MIN_MAP_WIDTH = 0.4
-- The box hides when its map has not been updated for this long (the map was closed or hidden)
WheresMyStuffMapSearch.HIDE_AFTER = 250

-- Results list under the box: nearest matches first, click to pan the map there, double-click to also navigate there
WheresMyStuffMapSearch.LIST_ROWS = 8
WheresMyStuffMapSearch.LIST_ROW_HEIGHT = 24
WheresMyStuffMapSearch.LIST_TEXT_SIZE = 15
WheresMyStuffMapSearch.LIST_PADDING_X = 10
WheresMyStuffMapSearch.LIST_GAP = 6
WheresMyStuffMapSearch.DOUBLE_CLICK_TIME = 400

-- One search box per frame or screen that shows a map: owner -> box
WheresMyStuffMapSearch.boxes = {}

-- ---------------------------------------------------------------------------------------------
-- Searching
-- ---------------------------------------------------------------------------------------------

-- Runs the search typed so far. Returns the number of matches, or nil when the box is empty or there is no farm.
function WheresMyStuffMapSearch.runSearch(box)
    local text = box.pendingText or box:getText()
    box.pendingText = nil

    if #WheresMyStuff.getSearchWords(text) == 0 then
        WheresMyStuff.removeHotspots()
        box:setCount(nil)
        return nil
    end

    local farmId = WheresMyStuff.resolveFarmId()
    if farmId == nil then
        return nil
    end

    local matches = WheresMyStuff.runSearch(text, farmId)
    box:setCount(#matches)
    return #matches
end

function WheresMyStuffMapSearch.onTextChanged(box, text)
    box.pendingText = text
    box.searchTime = g_time + WheresMyStuffMapSearch.SEARCH_DELAY
end

-- Enter: search now (if still waiting) and center the map on the nearest result
function WheresMyStuffMapSearch.onEnterPressed(box)
    if box.pendingText ~= nil then
        WheresMyStuffMapSearch.runSearch(box)
    end

    local mapElement = box.mapElement
    local nearest = WheresMyStuff.hotspots[1]
    if mapElement ~= nil and nearest ~= nil and mapElement.panToHotspot ~= nil then
        mapElement:panToHotspot(nearest)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Search box
-- ---------------------------------------------------------------------------------------------

-- The box for the frame (or screen) the map belongs to, made the first time that map is shown
function WheresMyStuffMapSearch.getBox(mapElement)
    local owner = mapElement.target
    if owner == nil then
        return nil
    end

    local box = WheresMyStuffMapSearch.boxes[owner]
    if box == nil and box ~= false then
        box = SearchablesSearchBox.new(owner, Searchables.getText("searchables_mapPlaceholder"), function(text)
            WheresMyStuffMapSearch.onTextChanged(WheresMyStuffMapSearch.boxes[owner], text)
        end)
        if box == nil then
            -- logged by SearchablesSearchBox; do not try again every frame
            WheresMyStuffMapSearch.boxes[owner] = false
            return nil
        end

        -- the in-game menu around the map frame registers its buttons while the box is open
        local currentScreen = g_gui.currentGui ~= nil and g_gui.currentGui.target or nil
        box.menu = currentScreen or owner
        box.onEnterPressed = function()
            WheresMyStuffMapSearch.onEnterPressed(box)
        end
        box.recentKey = "map"

        -- show what was searched before (also searches made with wmsFind)
        if WheresMyStuff.searchQuery ~= nil then
            box.input:setText(WheresMyStuff.searchQuery)
            box.lastText = box.input:getText()
            box:setCount(WheresMyStuff.searchMatchCount)
        end

        -- hide once the map stops updating (closed, or another page)
        local rootUpdate = box.root.update
        box.root.update = function(element, dt)
            rootUpdate(element, dt)
            if g_time - (box.lastMapUpdate or 0) > WheresMyStuffMapSearch.HIDE_AFTER then
                box:setVisible(false)
            end
        end

        WheresMyStuffMapSearch.boxes[owner] = box
    end

    return box or nil
end

function WheresMyStuffMapSearch.positionBox(box, mapElement)
    local width, height = box:getSize()
    local _, topOffset = getNormalizedScreenValues(0, WheresMyStuffMapSearch.BOX_TOP_OFFSET)
    local x = mapElement.absPosition[1] + mapElement.absSize[1] * 0.5 - width * 0.5
    local y = mapElement.absPosition[2] + mapElement.absSize[2] - topOffset - height
    box:setPosition(x, y)
end

-- ---------------------------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------------------------

function WheresMyStuffMapSearch.getArrowOverlay()
    if WheresMyStuffMapSearch.arrowOverlay == nil then
        WheresMyStuffMapSearch.arrowOverlay = Overlay.new(WheresMyStuffMapSearch.ARROW_ICON, 0, 0, 1, 1)
    end
    return WheresMyStuffMapSearch.arrowOverlay
end

-- Screen position of a world position on this map, same math as IngameMap:drawHotspot. Returns x, y, visible.
function WheresMyStuffMapSearch.worldToScreen(ingameMap, worldX, worldZ)
    local objectX = (worldX + ingameMap.worldCenterOffsetX) / ingameMap.worldSizeX * ingameMap.mapExtensionScaleFactor + ingameMap.mapExtensionOffsetX
    local objectZ = (worldZ + ingameMap.worldCenterOffsetZ) / ingameMap.worldSizeZ * ingameMap.mapExtensionScaleFactor + ingameMap.mapExtensionOffsetZ
    local x, y, _, visible = ingameMap.layout:getMapObjectPosition(objectX, objectZ, 0, 0, 0, false)
    return x, y, visible
end

-- Arrow size in pixels for the n-th arrow: eases from big to small, later arrows start a little later
function WheresMyStuffMapSearch.getArrowSize(index, elapsed)
    local delay = math.min(index - 1, WheresMyStuffMapSearch.MAX_STAGGERED) * WheresMyStuffMapSearch.STAGGER
    local t = math.clamp((elapsed - delay) / WheresMyStuffMapSearch.SHRINK_DURATION, 0, 1)
    local eased = 1 - (1 - t) ^ 3
    local startSize, endSize = WheresMyStuffMapSearch.ARROW_START_SIZE, WheresMyStuffMapSearch.ARROW_END_SIZE
    return startSize + (endSize - startSize) * eased, t
end

function WheresMyStuffMapSearch.drawArrows(ingameMap)
    if WheresMyStuff.searchQuery == nil or #WheresMyStuff.hotspots == 0 then
        return
    end

    local overlay = WheresMyStuffMapSearch.getArrowOverlay()
    local elapsed = g_time - (WheresMyStuff.searchStartTime or g_time)
    local _, tipGap = getNormalizedScreenValues(0, WheresMyStuffMapSearch.TIP_GAP)

    -- draw farthest first so the nearest arrows end up on top
    local count = math.min(#WheresMyStuff.hotspots, WheresMyStuffMapSearch.MAX_ARROWS)
    for i = count, 1, -1 do
        local hotspot = WheresMyStuff.hotspots[i]
        if hotspot:getIsVisible() then
            local worldX, worldZ = hotspot:getWorldPosition()
            local x, y, visible = WheresMyStuffMapSearch.worldToScreen(ingameMap, worldX, worldZ)
            if visible then
                local sizePx, progress = WheresMyStuffMapSearch.getArrowSize(i, elapsed)
                local bobPx = math.sin((g_time + i * 150) / WheresMyStuffMapSearch.BOB_PERIOD * 2 * math.pi) * WheresMyStuffMapSearch.BOB_HEIGHT * progress
                local width, height = getNormalizedScreenValues(sizePx, sizePx)
                local _, bob = getNormalizedScreenValues(0, bobPx)

                overlay:setDimension(width, height)
                overlay:setPosition(x - width * 0.5, y + tipGap + math.abs(bob))
                overlay:setColor(unpack(WheresMyStuffHotspot.getColor(hotspot.kind)))
                overlay:render()
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Results list
-- ---------------------------------------------------------------------------------------------

-- Distance from the camera to a hotspot as text, or ""
function WheresMyStuffMapSearch.getDistanceText(hotspot, viewerX, viewerZ)
    if viewerX == nil then
        return ""
    end
    local x, z = hotspot:getWorldPosition()
    local distance = MathUtil.vector2Length(x - viewerX, z - viewerZ)
    if distance >= 1000 then
        return string.format("%.1f km", distance / 1000)
    end
    return string.format("%d m", math.floor(distance + 0.5))
end

-- Draws the nearest results under the search box and remembers where each row is for clicks
function WheresMyStuffMapSearch.drawResultsList(box)
    box.listRows = {}
    local hotspots = WheresMyStuff.hotspots
    if WheresMyStuff.searchQuery == nil or #hotspots == 0 or not box.root:getIsVisible() then
        return
    end

    local width = box:getSize()
    local _, rowHeight = getNormalizedScreenValues(0, WheresMyStuffMapSearch.LIST_ROW_HEIGHT)
    local _, textSize = getNormalizedScreenValues(0, WheresMyStuffMapSearch.LIST_TEXT_SIZE)
    local padX = getNormalizedScreenValues(WheresMyStuffMapSearch.LIST_PADDING_X, 0)
    local _, gap = getNormalizedScreenValues(0, WheresMyStuffMapSearch.LIST_GAP)

    local count = math.min(#hotspots, WheresMyStuffMapSearch.LIST_ROWS)
    local hasMore = #hotspots > count
    local rows = count + (hasMore and 1 or 0)
    local x = box.root.absPosition[1]
    local top = box.root.absPosition[2] - gap
    drawFilledRect(x, top - rows * rowHeight, width, rows * rowHeight, 0, 0, 0, 0.75)

    local viewerX, viewerZ = WheresMyStuff.getViewerPosition()
    local textY = (rowHeight - textSize) * 0.5 + textSize * 0.15
    for i = 1, count do
        local hotspot = hotspots[i]
        local y = top - i * rowHeight
        local isHovered = box.hoveredRow == i
        if isHovered then
            drawFilledRect(x, y, width, rowHeight, 1, 1, 1, 0.12)
        end

        local color = WheresMyStuffHotspot.getColor(hotspot.kind)
        drawFilledRect(x, y + rowHeight * 0.2, padX * 0.35, rowHeight * 0.6, color[1], color[2], color[3], 1)

        local distance = WheresMyStuffMapSearch.getDistanceText(hotspot, viewerX, viewerZ)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(0.7, 0.7, 0.7, 1)
        renderText(x + width - padX, y + textY, textSize, distance)
        local distanceWidth = getTextWidth(textSize, distance) + padX

        setTextAlignment(RenderText.ALIGN_LEFT)
        if isHovered then
            setTextColor(1, 0.85, 0.1, 1)
        else
            setTextColor(1, 1, 1, 1)
        end
        local name = Utils.limitTextToWidth(string.format("%d. %s", i, hotspot:getName()), textSize, width - padX * 2 - distanceWidth, false, "...")
        renderText(x + padX, y + textY, textSize, name)

        table.insert(box.listRows, {x = x, y = y, width = width, height = rowHeight, hotspot = hotspot})
    end

    if hasMore then
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(0.7, 0.7, 0.7, 1)
        renderText(x + padX, top - rows * rowHeight + textY, textSize,
            string.format(Searchables.getText("searchables_moreResults"), #hotspots - count))
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

-- The list row under the mouse, or nil
function WheresMyStuffMapSearch.getRowAt(box, posX, posY)
    for i, row in ipairs(box.listRows or {}) do
        if posX >= row.x and posX <= row.x + row.width and posY >= row.y and posY <= row.y + row.height then
            return i, row
        end
    end
    return nil
end

-- Click pans the map to a result; a second click on the same row also makes it the navigation target
function WheresMyStuffMapSearch.onListClick(box, mapElement, index, row)
    if mapElement.panToHotspot ~= nil then
        mapElement:panToHotspot(row.hotspot)
    end
    if box.lastClickedRow == index and g_time - (box.lastClickTime or 0) < WheresMyStuffMapSearch.DOUBLE_CLICK_TIME then
        WheresMyStuff.setTarget(row.hotspot)
    end
    box.lastClickedRow = index
    box.lastClickTime = g_time
end

-- ---------------------------------------------------------------------------------------------
-- Hooks into IngameMapElement
-- ---------------------------------------------------------------------------------------------

-- After the map and its hotspots are drawn
function WheresMyStuffMapSearch.onMapDraw(mapElement)
    if mapElement.ingameMap == nil then
        return
    end
    WheresMyStuffMapSearch.drawArrows(mapElement.ingameMap)

    local box = mapElement.target ~= nil and WheresMyStuffMapSearch.boxes[mapElement.target] or nil
    if box and box.mapElement == mapElement then
        WheresMyStuffMapSearch.drawResultsList(box)
    end
end

-- Clicks on the results list go to the list; everything else goes to the map as usual
function WheresMyStuffMapSearch.onMapMouseEvent(mapElement, superFunc, posX, posY, isDown, isUp, button, eventUsed)
    local box = mapElement.target ~= nil and WheresMyStuffMapSearch.boxes[mapElement.target] or nil
    if box and box.mapElement == mapElement and mapElement:getIsActive() then
        local index, row = nil, nil
        if not eventUsed then
            index, row = WheresMyStuffMapSearch.getRowAt(box, posX, posY)
        end
        box.hoveredRow = index
        if row ~= nil and button == Input.MOUSE_BUTTON_LEFT and (isDown or isUp) then
            if isUp then
                WheresMyStuffMapSearch.onListClick(box, mapElement, index, row)
            end
            return true
        end
    end
    return superFunc(mapElement, posX, posY, isDown, isUp, button, eventUsed)
end

-- Every frame while a map is shown: keep its box visible and in place, and run the search once typing pauses
function WheresMyStuffMapSearch.onMapUpdate(mapElement, dt)
    if mapElement.absSize[1] < WheresMyStuffMapSearch.MIN_MAP_WIDTH then
        return
    end
    local box = WheresMyStuffMapSearch.getBox(mapElement)
    if box == nil then
        return
    end

    box.mapElement = mapElement
    box.lastMapUpdate = g_time
    if not box.root.visible then
        box:setVisible(true)
    end
    WheresMyStuffMapSearch.positionBox(box, mapElement)
    box:update()

    -- opened by quick find: put the cursor in the box
    if WheresMyStuffMapSearch.focusWhenShown then
        WheresMyStuffMapSearch.focusWhenShown = false
        box:focus()
    end

    if box.pendingText ~= nil and g_time >= box.searchTime then
        WheresMyStuffMapSearch.runSearch(box)
    end
end

-- The map removes its action events by target when it closes, so this one goes with them
function WheresMyStuffMapSearch.onMapRegisterActionEvents(mapElement)
    Searchables.registerSearchAction(mapElement, WheresMyStuffMapSearch.onSearchAction)
end

-- The Search action (Ctrl+F / right stick) puts the cursor in the box, with the on-screen keyboard where there is one
function WheresMyStuffMapSearch.onSearchAction(mapElement)
    local box = mapElement.target ~= nil and WheresMyStuffMapSearch.boxes[mapElement.target] or nil
    if box and not g_gui:getIsDialogVisible() then
        box:focus()
    end
end

-- Quick find: the Search key (Ctrl+F) while walking or driving opens the map with the cursor in the search box.
-- Only from the keyboard: on a controller the Search button (right stick) has its own job outside menus.
WheresMyStuffMapSearch.quickFindTargets = {}

function WheresMyStuffMapSearch.onRegisterGlobalPlayerActionEvents(inputComponent, contextName)
    local key = contextName or "default"
    local target = WheresMyStuffMapSearch.quickFindTargets[key] or {}
    WheresMyStuffMapSearch.quickFindTargets[key] = target
    Searchables.registerSearchAction(target, WheresMyStuffMapSearch.onQuickFind)
end

function WheresMyStuffMapSearch.onQuickFind()
    if g_gui:getIsGuiVisible() or g_inputBinding.lastInputMode ~= GS_INPUT_HELP_MODE_KEYBOARD then
        return
    end
    local menu = g_inGameMenu
    if menu == nil or menu.pageMapOverview == nil then
        return
    end
    WheresMyStuffMapSearch.focusWhenShown = true
    g_gui:changeScreen(nil, InGameMenu)
    menu:goToPage(menu.pageMapOverview)
end

if PlayerInputComponent ~= nil and PlayerInputComponent.registerGlobalPlayerActionEvents ~= nil then
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents,
        WheresMyStuffMapSearch.onRegisterGlobalPlayerActionEvents)
end

if IngameMapElement ~= nil then
    IngameMapElement.draw = Utils.appendedFunction(IngameMapElement.draw, WheresMyStuffMapSearch.onMapDraw)
    IngameMapElement.update = Utils.appendedFunction(IngameMapElement.update, WheresMyStuffMapSearch.onMapUpdate)
    IngameMapElement.mouseEvent = Utils.overwrittenFunction(IngameMapElement.mouseEvent, WheresMyStuffMapSearch.onMapMouseEvent)
    IngameMapElement.registerActionEvents = Utils.appendedFunction(IngameMapElement.registerActionEvents, WheresMyStuffMapSearch.onMapRegisterActionEvents)
else
    Logging.warning("[Searchables] In-game map not found, map search is not available")
end

function WheresMyStuffMapSearch.delete()
    for _, box in pairs(WheresMyStuffMapSearch.boxes) do
        if box then
            box:delete()
        end
    end
    WheresMyStuffMapSearch.boxes = {}

    if WheresMyStuffMapSearch.arrowOverlay ~= nil then
        WheresMyStuffMapSearch.arrowOverlay:delete()
        WheresMyStuffMapSearch.arrowOverlay = nil
    end
end
