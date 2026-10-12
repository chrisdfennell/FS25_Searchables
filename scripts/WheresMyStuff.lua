-- WheresMyStuff
-- Scans every pallet, big bag and bale owned by a farm, groups them by fill type and reports
-- where each one is, and searches vehicles, stock, buildings and fields (map search: WheresMyStuffMapSearch).
-- Console commands: wmsSummary, wmsList, wmsLeftovers, wmsShow, wmsHide, wmsGoto, wmsFind, wmsTarget.
-- Part of Searchables: splitting and lowercasing search text uses the shared core in Searchables.lua.

WheresMyStuff = {}
WheresMyStuff.MOD_NAME = g_currentModName
WheresMyStuff.MOD_DIRECTORY = g_currentModDirectory

WheresMyStuff.KIND_PALLET = "pallet"
WheresMyStuff.KIND_BIGBAG = "bigBag"
WheresMyStuff.KIND_BALE = "bale"
WheresMyStuff.KIND_VEHICLE = "vehicle"
WheresMyStuff.KIND_BUILDING = "building"
WheresMyStuff.KIND_FIELD = "field"

-- Group key for pallets and big bags with nothing in them
WheresMyStuff.EMPTY_KEY = "EMPTY"

-- Vehicle types that count as pallets even if the specialization layout differs (mods, tree sapling pallets)
WheresMyStuff.PALLET_TYPE_NAMES = {
    pallet = true,
    treeSaplingPallet = true,
    bigBag = true,
}

-- ---------------------------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------------------------

function WheresMyStuff.getPalletKind(vehicle)
    if vehicle.spec_bigBag ~= nil or vehicle.typeName == "bigBag" then
        return WheresMyStuff.KIND_BIGBAG
    end
    if vehicle.isPallet or WheresMyStuff.PALLET_TYPE_NAMES[vehicle.typeName] then
        return WheresMyStuff.KIND_PALLET
    end
    return nil
end

-- Returns a list of items: {kind, object, node, fillTypeIndex, fillLevel, x, y, z}
-- farmId nil means every farm.
function WheresMyStuff.scanItems(farmId)
    local items = {}

    local vehicleSystem = g_currentMission.vehicleSystem
    if vehicleSystem ~= nil then
        for _, vehicle in ipairs(vehicleSystem.vehicles) do
            local kind = WheresMyStuff.getPalletKind(vehicle)
            local isShopPreview = vehicle.propertyState == VehiclePropertyState.SHOP_CONFIG

            if kind ~= nil and not isShopPreview and vehicle.rootNode ~= nil
                and (farmId == nil or vehicle:getOwnerFarmId() == farmId) then
                local spec = vehicle.spec_pallet or vehicle.spec_bigBag
                local fillUnitIndex = (spec ~= nil and spec.fillUnitIndex) or 1
                local fillTypeIndex, fillLevel = FillType.UNKNOWN, 0
                if vehicle.getFillUnitFillType ~= nil then
                    fillTypeIndex = vehicle:getFillUnitFillType(fillUnitIndex)
                    fillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
                end

                local x, y, z = getWorldTranslation(vehicle.rootNode)
                table.insert(items, {kind = kind, object = vehicle, node = vehicle.rootNode, fillTypeIndex = fillTypeIndex, fillLevel = fillLevel, x = x, y = y, z = z})
            end
        end
    end

    local itemSystem = g_currentMission.itemSystem
    if itemSystem ~= nil and itemSystem.itemsToSave ~= nil then
        -- keyed by the item object itself, so pairs, not ipairs
        for object, _ in pairs(itemSystem.itemsToSave) do
            if WheresMyStuff.isVisibleBale(object) and (farmId == nil or object:getOwnerFarmId() == farmId) then
                local x, y, z = getWorldTranslation(object.nodeId)
                table.insert(items, {kind = WheresMyStuff.KIND_BALE, object = object, node = object.nodeId, fillTypeIndex = object:getFillType(), fillLevel = object:getFillLevel() or 0, x = x, y = y, z = z})
            end
        end
    end

    return items
end

-- Fermenting bales inside an object storage keep a hidden real bale; skip those so nothing is counted twice.
function WheresMyStuff.isVisibleBale(object)
    if type(object) ~= "table" or object.isa == nil or not object:isa(Bale) then
        return false
    end
    if object.nodeId == nil or object.nodeId == 0 or not getVisibility(object.nodeId) then
        return false
    end
    if object.getNeedsSaving ~= nil and not object:getNeedsSaving() then
        return false
    end
    return true
end

-- Groups items by fill type. Returns a list of groups sorted by value (highest first).
function WheresMyStuff.groupItems(items)
    local groupsByKey = {}
    local groups = {}

    for _, item in ipairs(items) do
        local isEmpty = item.fillLevel <= 0 or item.fillTypeIndex == nil or item.fillTypeIndex == FillType.UNKNOWN
        local key = isEmpty and WheresMyStuff.EMPTY_KEY or item.fillTypeIndex

        local group = groupsByKey[key]
        if group == nil then
            group = {
                key = key,
                fillTypeIndex = not isEmpty and item.fillTypeIndex or nil,
                name = isEmpty and WheresMyStuff.EMPTY_KEY or g_fillTypeManager:getFillTypeNameByIndex(item.fillTypeIndex),
                title = isEmpty and "Empty pallets / big bags" or WheresMyStuff.getFillTypeTitle(item.fillTypeIndex),
                pallet = 0,
                bigBag = 0,
                bale = 0,
                liters = 0,
                value = 0,
                items = {},
            }
            groupsByKey[key] = group
            table.insert(groups, group)
        end

        group[item.kind] = group[item.kind] + 1
        table.insert(group.items, item)
        if not isEmpty then
            group.liters = group.liters + item.fillLevel
            group.value = group.value + item.fillLevel * WheresMyStuff.getPricePerLiter(item.fillTypeIndex)
        end
    end

    table.sort(groups, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end
        return a.title < b.title
    end)

    return groups
end

function WheresMyStuff.getFillTypeTitle(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil then
        return "Unknown"
    end
    return fillType.title or fillType.name
end

function WheresMyStuff.getPricePerLiter(fillTypeIndex)
    local economyManager = g_currentMission.economyManager
    if economyManager ~= nil and economyManager.getPricePerLiter ~= nil then
        return economyManager:getPricePerLiter(fillTypeIndex) or 0
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    return (fillType ~= nil and fillType.pricePerLiter) or 0
end

-- ---------------------------------------------------------------------------------------------
-- Locations
-- ---------------------------------------------------------------------------------------------

-- Returns a readable location and whether it is on a farmland that has a field.
-- Note: a farmland with a field also includes its edges, so "on field" is approximate.
function WheresMyStuff.getLocation(x, z)
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if farmland == nil then
        return "Off farmland", false
    end

    local field = farmland.field
    if field == nil and g_fieldManager.farmlandIdFieldMapping ~= nil then
        field = g_fieldManager.farmlandIdFieldMapping[farmland.id]
    end

    if field ~= nil then
        return WheresMyStuff.getFieldName(field, farmland.id), true
    end

    return string.format("Farmland %d", farmland.id), false
end

-- Camera position, used to sort items by distance. Returns nil if unavailable (e.g. dedicated server).
function WheresMyStuff.getViewerPosition()
    local ok, x, _, z = pcall(function()
        return getWorldTranslation(g_cameraManager:getActiveCamera())
    end)
    if ok and x ~= nil then
        return x, z
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------------------------

function WheresMyStuff.formatNumber(value)
    local str = tostring(math.floor(value + 0.5))
    local sign, digits = str:match("^(-?)(%d+)$")
    if digits == nil then
        return str
    end
    digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sign .. digits
end

function WheresMyStuff.formatCounts(group)
    local parts = {}
    if group.pallet > 0 then
        table.insert(parts, string.format("%d pallet%s", group.pallet, group.pallet == 1 and "" or "s"))
    end
    if group.bigBag > 0 then
        table.insert(parts, string.format("%d big bag%s", group.bigBag, group.bigBag == 1 and "" or "s"))
    end
    if group.bale > 0 then
        table.insert(parts, string.format("%d bale%s", group.bale, group.bale == 1 and "" or "s"))
    end
    return table.concat(parts, ", ")
end

function WheresMyStuff.formatItem(item, viewerX, viewerZ)
    local location = WheresMyStuff.getLocation(item.x, item.z)
    local line = string.format("  %-7s %8s L  %-20s (x %.0f, z %.0f)", item.kind, WheresMyStuff.formatNumber(item.fillLevel), location, item.x, item.z)
    if viewerX ~= nil then
        line = line .. string.format("  %s m away", WheresMyStuff.formatNumber(MathUtil.vector2Length(item.x - viewerX, item.z - viewerZ)))
    end
    return line
end

-- ---------------------------------------------------------------------------------------------
-- Console commands
-- ---------------------------------------------------------------------------------------------

-- Optional farm id argument, otherwise the local player's farm. Returns farmId or nil, error message.
function WheresMyStuff.resolveFarmId(farmIdArg)
    if farmIdArg ~= nil and farmIdArg ~= "" then
        local farmId = tonumber(farmIdArg)
        if farmId == nil then
            return nil, string.format("Invalid farm id '%s'", farmIdArg)
        end
        return farmId
    end

    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return nil, "No farm selected. Join a farm or pass a farm id."
    end
    return farmId
end

function WheresMyStuff:consoleSummary(farmIdArg)
    local farmId, err = WheresMyStuff.resolveFarmId(farmIdArg)
    if farmId == nil then
        return err
    end

    local groups = WheresMyStuff.groupItems(WheresMyStuff.scanItems(farmId))
    if #groups == 0 then
        return string.format("Farm %d has no pallets, big bags or bales.", farmId)
    end

    local totalValue = 0
    print(string.format("Where's My Stuff? - farm %d", farmId))
    for _, group in ipairs(groups) do
        totalValue = totalValue + group.value
        if group.key == WheresMyStuff.EMPTY_KEY then
            print(string.format("  %-28s %s", group.title, WheresMyStuff.formatCounts(group)))
        else
            print(string.format("  %-28s %10s L  $%10s   %s (%s)", group.title, WheresMyStuff.formatNumber(group.liters),
                WheresMyStuff.formatNumber(group.value), WheresMyStuff.formatCounts(group), group.name))
        end
    end
    return string.format("Total estimated value: $%s. Use 'wmsList <fillType>' to see where items are.", WheresMyStuff.formatNumber(totalValue))
end

function WheresMyStuff:consoleList(fillTypeArg, farmIdArg)
    if fillTypeArg == nil or fillTypeArg == "" then
        return "Usage: wmsList <fillType> [farmId]   e.g. wmsList WOOL, or wmsList EMPTY"
    end

    local farmId, err = WheresMyStuff.resolveFarmId(farmIdArg)
    if farmId == nil then
        return err
    end

    local group = WheresMyStuff.findGroup(WheresMyStuff.groupItems(WheresMyStuff.scanItems(farmId)), fillTypeArg)
    if group == nil then
        return string.format("Farm %d has nothing of '%s'. Run wmsSummary to see fill type names.", farmId, fillTypeArg)
    end

    local viewerX, viewerZ = WheresMyStuff.sortByDistance(group.items)

    print(string.format("%s - %s", group.title, WheresMyStuff.formatCounts(group)))
    for _, item in ipairs(group.items) do
        print(WheresMyStuff.formatItem(item, viewerX, viewerZ))
    end
    return string.format("%d item(s). Use 'wmsShow %s' to mark them on the map.", #group.items, group.name)
end

-- Finds a group by fill type name or title (case-insensitive)
function WheresMyStuff.findGroup(groups, search)
    search = search:upper()
    for _, group in ipairs(groups) do
        if group.name:upper() == search or group.title:upper() == search then
            return group
        end
    end
    return nil
end

-- Sorts items nearest first. Returns the viewer position, or nil if unavailable (list is then left as is).
function WheresMyStuff.sortByDistance(items)
    local viewerX, viewerZ = WheresMyStuff.getViewerPosition()
    if viewerX ~= nil then
        table.sort(items, function(a, b)
            return MathUtil.vector2Length(a.x - viewerX, a.z - viewerZ) < MathUtil.vector2Length(b.x - viewerX, b.z - viewerZ)
        end)
    end
    return viewerX, viewerZ
end

function WheresMyStuff:consoleLeftovers(farmIdArg)
    local farmId, err = WheresMyStuff.resolveFarmId(farmIdArg)
    if farmId == nil then
        return err
    end

    local leftovers = WheresMyStuff.getLeftovers(WheresMyStuff.scanItems(farmId))
    if #leftovers == 0 then
        return "Nothing left on your fields."
    end

    local viewerX, viewerZ = WheresMyStuff.getViewerPosition()
    print("Items lying on field farmland:")
    for _, item in ipairs(leftovers) do
        print(string.format("  %-20s %s", WheresMyStuff.getItemTitle(item), WheresMyStuff.formatItem(item, viewerX, viewerZ)))
    end
    return string.format("%d item(s) on fields. Use 'wmsShow LEFTOVERS' to mark them on the map.", #leftovers)
end

function WheresMyStuff.getLeftovers(items)
    local leftovers = {}
    for _, item in ipairs(items) do
        local _, onField = WheresMyStuff.getLocation(item.x, item.z)
        if onField then
            table.insert(leftovers, item)
        end
    end
    return leftovers
end

function WheresMyStuff.getItemTitle(item)
    return item.fillLevel > 0 and WheresMyStuff.getFillTypeTitle(item.fillTypeIndex) or "Empty"
end

-- ---------------------------------------------------------------------------------------------
-- Map markers
-- ---------------------------------------------------------------------------------------------

WheresMyStuff.SHOW_ALL = "ALL"
WheresMyStuff.SHOW_LEFTOVERS = "LEFTOVERS"

-- Too many markers make the map unreadable and slow; nearest ones win
WheresMyStuff.MAX_HOTSPOTS = 500

WheresMyStuff.hotspots = {}

-- Resolves what to show: a fill type, ALL or LEFTOVERS. Returns items, label or nil, error message.
function WheresMyStuff.selectItems(selection, farmId)
    local items = WheresMyStuff.scanItems(farmId)
    local key = selection:upper()

    if key == WheresMyStuff.SHOW_ALL then
        return items, "items"
    end
    if key == WheresMyStuff.SHOW_LEFTOVERS then
        return WheresMyStuff.getLeftovers(items), "items on fields"
    end

    local group = WheresMyStuff.findGroup(WheresMyStuff.groupItems(items), selection)
    if group == nil then
        return nil, string.format("Farm %d has nothing of '%s'. Run wmsSummary to see fill type names.", farmId, selection)
    end
    return group.items, group.title
end

function WheresMyStuff.getHotspotName(item)
    if item.name ~= nil then
        return item.name
    end
    local name = string.format("%s (%s)", WheresMyStuff.getItemTitle(item), item.kind)
    if item.fillLevel > 0 then
        name = string.format("%s - %s L", name, WheresMyStuff.formatNumber(item.fillLevel))
    end
    return name
end

-- Replaces the current markers with one per item (nearest first, capped). Returns the hotspots and the number left out.
function WheresMyStuff.showHotspots(items)
    WheresMyStuff.removeHotspots()

    WheresMyStuff.sortByDistance(items)
    for i, item in ipairs(items) do
        if i > WheresMyStuff.MAX_HOTSPOTS then
            break
        end
        -- nil node is a fixed position (fields); 0 means the object has no scene node to follow
        if item.node ~= 0 then
            local hotspot = WheresMyStuffHotspot.new(item, WheresMyStuff.getHotspotName(item), item.node)
            g_currentMission:addMapHotspot(hotspot)
            table.insert(WheresMyStuff.hotspots, hotspot)
        end
    end

    return WheresMyStuff.hotspots, math.max(0, #items - WheresMyStuff.MAX_HOTSPOTS)
end

function WheresMyStuff.removeHotspots()
    for _, hotspot in ipairs(WheresMyStuff.hotspots) do
        -- also clears the map target if it was one of ours
        g_currentMission:removeMapHotspot(hotspot)
        hotspot:delete()
    end
    WheresMyStuff.hotspots = {}
    WheresMyStuff.searchQuery = nil
end

function WheresMyStuff:consoleShow(selectionArg, farmIdArg)
    if selectionArg == nil or selectionArg == "" then
        return "Usage: wmsShow <fillType|ALL|LEFTOVERS|EMPTY> [farmId]   e.g. wmsShow WOOL"
    end

    local farmId, err = WheresMyStuff.resolveFarmId(farmIdArg)
    if farmId == nil then
        return err
    end

    local items, label = WheresMyStuff.selectItems(selectionArg, farmId)
    if items == nil then
        return label
    end
    if #items == 0 then
        WheresMyStuff.removeHotspots()
        return string.format("No %s to show.", label)
    end

    local hotspots, skipped = WheresMyStuff.showHotspots(items)
    local result = string.format("Marked %d %s on the map (filter: Other). Pallets orange, big bags blue, bales green.", #hotspots, label)
    if skipped > 0 then
        result = result .. string.format(" %d farthest left out (limit %d).", skipped, WheresMyStuff.MAX_HOTSPOTS)
    end
    return result .. " Use 'wmsHide' to clear."
end

function WheresMyStuff:consoleHide()
    local count = #WheresMyStuff.hotspots
    WheresMyStuff.removeHotspots()
    return string.format("Removed %d map marker(s).", count)
end

-- Marks every item of the selection and sets the nearest one as the map target (navigation arrow)
function WheresMyStuff:consoleGoto(selectionArg, farmIdArg)
    if selectionArg == nil or selectionArg == "" then
        return "Usage: wmsGoto <fillType|ALL|LEFTOVERS|EMPTY> [farmId]   e.g. wmsGoto LEFTOVERS"
    end

    local result = WheresMyStuff:consoleShow(selectionArg, farmIdArg)
    local nearest = WheresMyStuff.hotspots[1]
    if nearest == nil then
        return result
    end

    return WheresMyStuff.setTarget(nearest)
end

function WheresMyStuff.setTarget(hotspot)
    g_currentMission:setMapTargetHotspot(hotspot)
    local x, z = hotspot:getWorldPosition()
    return string.format("Target set: %s at %s.", hotspot:getName(), (WheresMyStuff.getLocation(x, z)))
end

-- Sets the n-th current marker (as numbered by wmsFind, nearest first) as the map target
function WheresMyStuff:consoleTarget(indexArg)
    if #WheresMyStuff.hotspots == 0 then
        return "No markers. Use wmsFind or wmsShow first."
    end

    local index = tonumber(indexArg or "1")
    local hotspot = index ~= nil and WheresMyStuff.hotspots[index] or nil
    if hotspot == nil then
        return string.format("Pick a number from 1 to %d.", #WheresMyStuff.hotspots)
    end
    return WheresMyStuff.setTarget(hotspot)
end

-- ---------------------------------------------------------------------------------------------
-- Search (vehicles, stock, buildings, fields)
-- ---------------------------------------------------------------------------------------------

-- Text the search words are matched against for each kind, on top of the name and category
WheresMyStuff.KIND_SEARCH_WORDS = {
    pallet = "pallet",
    bigBag = "big bag bigbag",
    bale = "bale",
    vehicle = "vehicle",
    building = "building",
    field = "field",
}

function WheresMyStuff.getStoreCategoryTitle(storeItem)
    if storeItem == nil then
        return ""
    end
    return Searchables.getStoreCategoryTitle(storeItem.categoryName)
end

function WheresMyStuff.newResult(kind, name, category, node, x, z, extraWords)
    return {
        kind = kind, name = name, category = category or "", node = node, x = x, z = z,
        searchText = Searchables.toLower(string.format("%s %s %s %s", name, category or "", WheresMyStuff.KIND_SEARCH_WORDS[kind] or "", extraWords or "")),
    }
end

-- License plate text of a vehicle, as written and without spaces or dashes ("AB-123 ab123"), or "" if it has none
function WheresMyStuff.getLicensePlateWords(vehicle)
    local spec = vehicle.spec_licensePlates
    local data = spec ~= nil and spec.licensePlateData or nil
    if data == nil or type(data.characters) ~= "table" then
        return ""
    end
    local plate = string.trim(table.concat(data.characters, ""))
    if plate == "" then
        return ""
    end
    return plate .. " " .. plate:gsub("[%s%-_]", "")
end

-- Every vehicle the farm owns or leases, except pallets and big bags. Searchable by name, category, type and plate.
function WheresMyStuff.scanVehicles(farmId)
    local results = {}

    local vehicleSystem = g_currentMission.vehicleSystem
    if vehicleSystem == nil then
        return results
    end

    for _, vehicle in ipairs(vehicleSystem.vehicles) do
        if WheresMyStuff.getPalletKind(vehicle) == nil and vehicle.rootNode ~= nil
            and vehicle.propertyState ~= VehiclePropertyState.SHOP_CONFIG
            and vehicle:getOwnerFarmId() == farmId then
            local name = vehicle.getFullName ~= nil and vehicle:getFullName() or tostring(vehicle.typeName)
            local storeItem = vehicle.configFileName ~= nil and g_storeManager:getItemByXMLFilename(vehicle.configFileName) or nil
            local x, _, z = getWorldTranslation(vehicle.rootNode)
            table.insert(results, WheresMyStuff.newResult(WheresMyStuff.KIND_VEHICLE, name, WheresMyStuff.getStoreCategoryTitle(storeItem),
                vehicle.rootNode, x, z, tostring(vehicle.typeName) .. " " .. WheresMyStuff.getLicensePlateWords(vehicle)))
        end
    end

    return results
end

-- Pallets, big bags and bales, searchable by fill type
function WheresMyStuff.scanStock(farmId)
    local results = {}
    for _, item in ipairs(WheresMyStuff.scanItems(farmId)) do
        local extraWords = ""
        if item.fillLevel > 0 then
            extraWords = g_fillTypeManager:getFillTypeNameByIndex(item.fillTypeIndex) or ""
        end
        if item.kind == WheresMyStuff.KIND_BALE and item.object.isRoundbale ~= nil then
            extraWords = extraWords .. (item.object.isRoundbale and " round" or " square")
        end
        table.insert(results, WheresMyStuff.newResult(item.kind, WheresMyStuff.getHotspotName(item), WheresMyStuff.getItemTitle(item),
            item.node, item.x, item.z, extraWords))
    end
    return results
end

-- Buildings and other placeables of the farm, plus public ones like selling points
function WheresMyStuff.scanBuildings(farmId)
    local results = {}

    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil then
        return results
    end

    for _, placeable in ipairs(placeableSystem.placeables) do
        local ownerFarmId = placeable:getOwnerFarmId()
        if placeable.rootNode ~= nil and (ownerFarmId == farmId or ownerFarmId == AccessHandler.EVERYONE) then
            local name = placeable:getName() or ""
            local x, _, z = getWorldTranslation(placeable.rootNode)
            table.insert(results, WheresMyStuff.newResult(WheresMyStuff.KIND_BUILDING, name, WheresMyStuff.getStoreCategoryTitle(placeable.storeItem),
                placeable.rootNode, x, z, tostring(placeable.typeName)))
        end
    end

    return results
end

function WheresMyStuff.getFieldName(field, fallbackId)
    local fieldName = field.getName ~= nil and field:getName() or field.name
    if fieldName == nil or fieldName == "" then
        fieldName = tostring(field.getId ~= nil and field:getId() or fallbackId)
    end
    -- maps often name fields by number only
    if tonumber(fieldName) ~= nil then
        fieldName = "Field " .. fieldName
    end
    return fieldName
end

-- Every field on the map; "owned" is added to the search text of the farm's own fields
function WheresMyStuff.scanFields(farmId)
    local results = {}
    for i, field in ipairs(g_fieldManager.fields or {}) do
        if field.posX ~= nil and field.posZ ~= nil then
            local isOwned = field.farmland ~= nil and g_farmlandManager:getFarmlandOwner(field.farmland.id) == farmId
            local category = isOwned and "Owned field" or "Field"
            table.insert(results, WheresMyStuff.newResult(WheresMyStuff.KIND_FIELD, WheresMyStuff.getFieldName(field, i), category,
                nil, field.posX, field.posZ, isOwned and "owned mine" or ""))
        end
    end
    return results
end

-- Splits free text into lowercase words
function WheresMyStuff.getSearchWords(text)
    return Searchables.getSearchWords(text)
end

-- Every word must appear somewhere in the name, category, kind or type (case-insensitive)
function WheresMyStuff.matchesSearch(result, words)
    return Searchables.matchesWords(result.searchText, words)
end

-- Everything matching the text, unsorted
function WheresMyStuff.search(text, farmId)
    local words = WheresMyStuff.getSearchWords(text)
    local matches = {}
    if #words == 0 then
        return matches
    end

    for _, scan in ipairs({WheresMyStuff.scanVehicles, WheresMyStuff.scanStock, WheresMyStuff.scanBuildings, WheresMyStuff.scanFields}) do
        for _, result in ipairs(scan(farmId)) do
            if WheresMyStuff.matchesSearch(result, words) then
                table.insert(matches, result)
            end
        end
    end
    return matches
end

-- Runs a search and marks the results (nearest first). Shared by the map search and wmsFind.
function WheresMyStuff.runSearch(text, farmId)
    local matches = WheresMyStuff.search(text, farmId)
    WheresMyStuff.showHotspots(matches)
    WheresMyStuff.searchQuery = table.concat(WheresMyStuff.getSearchWords(text), " ")
    WheresMyStuff.searchMatchCount = #matches
    WheresMyStuff.searchStartTime = g_time
    return matches
end

-- Console arguments arrive split on spaces, so take them all: wmsFind john deere 6r
function WheresMyStuff:consoleFind(...)
    local text = table.concat({...}, " ")
    if #WheresMyStuff.getSearchWords(text) == 0 then
        return "Usage: wmsFind <text>   e.g. wmsFind fendt, wmsFind wool, wmsFind silo, wmsFind field 12"
    end

    local farmId, err = WheresMyStuff.resolveFarmId()
    if farmId == nil then
        return err
    end

    local matches = WheresMyStuff.runSearch(text, farmId)
    if #matches == 0 then
        return string.format("Nothing matching '%s'.", WheresMyStuff.searchQuery)
    end

    -- runSearch sorted nearest first, so the printed numbers match the marker order for wmsTarget
    local viewerX, viewerZ = WheresMyStuff.getViewerPosition()
    for i, result in ipairs(matches) do
        local line = string.format("  %2d. %-8s %-32s %-20s %s", i, result.kind, result.name, result.category, WheresMyStuff.getLocation(result.x, result.z))
        if viewerX ~= nil then
            line = line .. string.format("  %s m away", WheresMyStuff.formatNumber(MathUtil.vector2Length(result.x - viewerX, result.z - viewerZ)))
        end
        print(line)
    end

    return string.format("%d match(es) for '%s', marked on the map. Use 'wmsTarget <number>' to navigate to one.", #matches, WheresMyStuff.searchQuery)
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

function WheresMyStuff:loadMap(name)
    addConsoleCommand("wmsSummary", "Where's My Stuff: totals per fill type", "consoleSummary", WheresMyStuff, "[farmId]")
    addConsoleCommand("wmsList", "Where's My Stuff: list items of one fill type and where they are", "consoleList", WheresMyStuff, "fillType [farmId]")
    addConsoleCommand("wmsLeftovers", "Where's My Stuff: bales and pallets lying on fields", "consoleLeftovers", WheresMyStuff, "[farmId]")
    addConsoleCommand("wmsShow", "Where's My Stuff: mark items on the map", "consoleShow", WheresMyStuff, "fillType|ALL|LEFTOVERS|EMPTY [farmId]")
    addConsoleCommand("wmsHide", "Where's My Stuff: remove map markers", "consoleHide", WheresMyStuff)
    addConsoleCommand("wmsGoto", "Where's My Stuff: mark items on the map and target the nearest", "consoleGoto", WheresMyStuff, "fillType|ALL|LEFTOVERS|EMPTY [farmId]")
    addConsoleCommand("wmsFind", "Where's My Stuff: search vehicles, stock, buildings and fields and mark them on the map", "consoleFind", WheresMyStuff, "text")
    addConsoleCommand("wmsTarget", "Where's My Stuff: navigate to the n-th marker (nearest first)", "consoleTarget", WheresMyStuff, "[number]")
    Logging.info("[WheresMyStuff] Loaded. Console commands: wmsSummary, wmsList, wmsLeftovers, wmsShow, wmsHide, wmsGoto, wmsFind, wmsTarget")
end

function WheresMyStuff:deleteMap()
    removeConsoleCommand("wmsSummary")
    removeConsoleCommand("wmsList")
    removeConsoleCommand("wmsLeftovers")
    removeConsoleCommand("wmsShow")
    removeConsoleCommand("wmsHide")
    removeConsoleCommand("wmsGoto")
    removeConsoleCommand("wmsFind")
    removeConsoleCommand("wmsTarget")
    WheresMyStuff.removeHotspots()
    WheresMyStuffMapSearch.delete()
end

addModEventListener(WheresMyStuff)
