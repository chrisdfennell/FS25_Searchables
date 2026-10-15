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
-- Hooks into IngameMapElement
-- ---------------------------------------------------------------------------------------------

-- After the map and its hotspots are drawn
function WheresMyStuffMapSearch.onMapDraw(mapElement)
    if mapElement.ingameMap == nil then
        return
    end
    WheresMyStuffMapSearch.drawArrows(mapElement.ingameMap)
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

if IngameMapElement ~= nil then
    IngameMapElement.draw = Utils.appendedFunction(IngameMapElement.draw, WheresMyStuffMapSearch.onMapDraw)
    IngameMapElement.update = Utils.appendedFunction(IngameMapElement.update, WheresMyStuffMapSearch.onMapUpdate)
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
