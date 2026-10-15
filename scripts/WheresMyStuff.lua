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
WheresMyStuff.KIND_FARMLAND = "farmland"
WheresMyStuff.KIND_SELL_POINT = "sellPoint"
WheresMyStuff.KIND_CONTRACT = "contract"

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
        return Searchables.getText("searchables_unknown")
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
    return item.fillLevel > 0 and WheresMyStuff.getFillTypeTitle(item.fillTypeIndex) or Searchables.getText("searchables_empty")
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
    local name = string.format("%s (%s)", WheresMyStuff.getItemTitle(item), WheresMyStuff.getKindTitle(item.kind))
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
    farmland = "property farmland land plot",
    sellPoint = "sell selling point",
    contract = "contract mission",
}

-- Name of a kind in the player's language ("Bale", "Ballen"), for marker names and searching
function WheresMyStuff.getKindTitle(kind)
    return Searchables.getText("searchables_kind_" .. kind)
end

function WheresMyStuff.getStoreCategoryTitle(storeItem)
    if storeItem == nil then
        return ""
    end
    return Searchables.getStoreCategoryTitle(storeItem.categoryName)
end

function WheresMyStuff.newResult(kind, name, category, node, x, z, extraWords)
    return {
        kind = kind, name = name, category = category or "", node = node, x = x, z = z,
        searchText = Searchables.toLower(string.format("%s %s %s %s %s", name, category or "", WheresMyStuff.KIND_SEARCH_WORDS[kind] or "",
            WheresMyStuff.getKindTitle(kind), extraWords or "")),
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
            local result = WheresMyStuff.newResult(WheresMyStuff.KIND_VEHICLE, name, WheresMyStuff.getStoreCategoryTitle(storeItem),
                vehicle.rootNode, x, z, tostring(vehicle.typeName) .. " " .. WheresMyStuff.getLicensePlateWords(vehicle))
            result.storeItem = storeItem
            table.insert(results, result)
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
        local result = WheresMyStuff.newResult(item.kind, WheresMyStuff.getHotspotName(item), WheresMyStuff.getItemTitle(item),
            item.node, item.x, item.z, extraWords)
        -- for fill level filters: wool l>1000
        result.fillLevel = item.fillLevel
        table.insert(results, result)
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
            local result = WheresMyStuff.newResult(WheresMyStuff.KIND_BUILDING, name, WheresMyStuff.getStoreCategoryTitle(placeable.storeItem),
                placeable.rootNode, x, z, tostring(placeable.typeName))
            result.storeItem = placeable.storeItem
            table.insert(results, result)
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
        fieldName = string.format(Searchables.getText("searchables_fieldName"), fieldName)
    end
    return fieldName
end

-- ---------------------------------------------------------------------------------------------
-- Field crops and work to do
-- ---------------------------------------------------------------------------------------------

-- Field status is read from the ground at the field's center (the spot where the map shows its number) and kept a few
-- seconds, so typing does not read every field's ground again for each letter
WheresMyStuff.FIELD_STATUS_MAX_AGE = 5000
WheresMyStuff.fieldStatuses = setmetatable({}, {__mode = "k"})

-- English search words per status; the translated label (translations/, searchables_state_*) is searchable too
WheresMyStuff.FIELD_STATUS_WORDS = {
    harvest = "harvest ready",
    growing = "growing",
    withered = "withered",
    harvested = "harvested stubble",
    lime = "lime",
    fertilize = "fertilize fertilizer",
    plow = "plow plough",
    weeds = "weeds",
    stones = "stones",
    roll = "roll roller",
}

-- What the ground at a field's center says: crop, growth stage, lime, fertilizer, plowing, weeds, stones, rolling
function WheresMyStuff.readFieldState(field)
    local state = FieldState.new()
    state:update(field.posX, field.posZ)
    return state
end

-- Crop and work to do on a field: {words = searchable text, label = "Wheat, ready to harvest"}
function WheresMyStuff.getFieldStatus(field)
    local status = WheresMyStuff.fieldStatuses[field]
    if status ~= nil and g_time - status.time < WheresMyStuff.FIELD_STATUS_MAX_AGE then
        return status
    end
    status = {time = g_time, words = "", label = ""}
    WheresMyStuff.fieldStatuses[field] = status

    local ok, state = pcall(WheresMyStuff.readFieldState, field)
    if not ok or state == nil or not state.isValid then
        return status
    end

    local words, labels = {}, {}
    local function addStatus(key)
        local text = Searchables.getText("searchables_state_" .. key)
        table.insert(words, WheresMyStuff.FIELD_STATUS_WORDS[key])
        table.insert(words, text)
        table.insert(labels, text)
    end

    local fruitType = nil
    if state.fruitTypeIndex ~= nil and state.fruitTypeIndex ~= FruitType.UNKNOWN then
        fruitType = g_fruitTypeManager:getFruitTypeByIndex(state.fruitTypeIndex)
    end
    if fruitType ~= nil then
        local title = fruitType.fillType ~= nil and fruitType.fillType.title or fruitType.name
        table.insert(words, tostring(fruitType.name))
        table.insert(words, tostring(title))
        table.insert(labels, tostring(title))

        local growth = state.growthState or 0
        local minHarvest, maxHarvest = fruitType.minHarvestingGrowthState or 0, fruitType.maxHarvestingGrowthState or 0
        if fruitType.witheredState ~= nil and growth == fruitType.witheredState then
            addStatus("withered")
        elseif fruitType.cutStates ~= nil and fruitType.cutStates[growth] then
            addStatus("harvested")
        elseif minHarvest > 0 and growth >= minHarvest and growth <= maxHarvest then
            addStatus("harvest")
        elseif growth > 0 then
            addStatus("growing")
        end
    end

    -- work only counts where the game's settings ask for it
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or {}
    if state.limeLevel == 0 and info.limeRequired ~= false then
        addStatus("lime")
    end
    if state.sprayLevel == 0 then
        addStatus("fertilize")
    end
    if state.plowLevel == 0 and info.plowingRequiredEnabled ~= false then
        addStatus("plow")
    end
    if (state.weedState or 0) > 0 and info.weedsEnabled ~= false then
        addStatus("weeds")
    end
    if (state.stoneLevel or 0) > 0 and info.stonesEnabled ~= false then
        addStatus("stones")
    end
    if (state.rollerLevel or 0) > 0 then
        addStatus("roll")
    end

    status.words = table.concat(words, " ")
    status.label = table.concat(labels, ", ")
    return status
end

-- ---------------------------------------------------------------------------------------------
-- Where to sell
-- ---------------------------------------------------------------------------------------------

-- The word that starts a selling search ("sell wheat"), in English or the player's language, or nil
function WheresMyStuff.findSellWord(words)
    local translated = Searchables.toLower(Searchables.getText("searchables_sell"))
    for i, word in ipairs(words) do
        if word == "sell" or word == translated then
            return i
        end
    end
    return nil
end

-- Fill types whose name contains every word ("wheat", "wood chips"); all of them when there are no words
function WheresMyStuff.findFillTypes(words)
    local fillTypes = {}
    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        if fillType.showOnPriceTable ~= false then
            local text = Searchables.toLower(string.format("%s %s", tostring(fillType.title), tostring(fillType.name)))
            if Searchables.matchesWords(text, words) then
                fillTypes[fillType.index] = fillType
            end
        end
    end
    return fillTypes
end

-- Every selling point that buys what is named after "sell", the same ones the game's price list shows. Each result
-- shows the price per 1000 l; the best price for each fill type is marked.
function WheresMyStuff.searchSellPoints(words)
    local storageSystem = g_currentMission ~= nil and g_currentMission.storageSystem or nil
    if storageSystem == nil or storageSystem.getUnloadingStations == nil then
        return {}
    end
    local fillTypes = WheresMyStuff.findFillTypes(words)

    local offers, bestPrices = {}, {}
    for _, station in pairs(storageSystem:getUnloadingStations()) do
        if type(station) == "table" and station.isSellingPoint and not station.hideFromPricesMenu and station.acceptedFillTypes ~= nil then
            for fillTypeIndex, fillType in pairs(fillTypes) do
                if station.acceptedFillTypes[fillTypeIndex] and station.getEffectiveFillTypePrice ~= nil then
                    local price = (station:getEffectiveFillTypePrice(fillTypeIndex) or 0) * 1000
                    if price > 0 then
                        table.insert(offers, {station = station, fillType = fillType, price = price})
                        bestPrices[fillTypeIndex] = math.max(bestPrices[fillTypeIndex] or 0, price)
                    end
                end
            end
        end
    end

    local results = {}
    for _, offer in ipairs(offers) do
        local station = offer.station
        local placeable = station.owningPlaceable
        local node = station.rootNode or (placeable ~= nil and placeable.rootNode) or nil
        if node ~= nil and node ~= 0 then
            local stationName = (station.getName ~= nil and station:getName()) or (placeable ~= nil and placeable:getName()) or "?"
            local name = string.format("%s: %s %s / 1000 l", stationName, tostring(offer.fillType.title),
                g_i18n:formatMoney(offer.price, 0, true, true))
            if offer.price >= bestPrices[offer.fillType.index] then
                name = string.format("%s (%s)", name, Searchables.getText("searchables_bestPrice"))
            end
            local x, _, z = getWorldTranslation(node)
            table.insert(results, WheresMyStuff.newResult(WheresMyStuff.KIND_SELL_POINT, name,
                Searchables.getText("searchables_kind_sellPoint"), node, x, z, tostring(offer.fillType.name)))
        end
    end
    return results
end

-- Name of the NPC farmer who owns a property ("" once a player farm owns it), so typing a farmer's name finds their
-- fields and properties
function WheresMyStuff.getFarmlandNpcName(farmland)
    if farmland == nil or g_farmlandManager:getFarmlandOwner(farmland.id) ~= FarmlandManager.NO_OWNER_FARM_ID then
        return ""
    end
    local npc
    if farmland.getNPC ~= nil then
        npc = farmland:getNPC()
    elseif farmland.npcIndex ~= nil and g_npcManager ~= nil then
        npc = g_npcManager:getNPCByIndex(farmland.npcIndex)
    end
    return npc ~= nil and npc.title or ""
end

-- Every field on the map; "owned" is added to the search text of the farm's own fields
function WheresMyStuff.scanFields(farmId)
    local results = {}
    for i, field in ipairs(g_fieldManager.fields or {}) do
        if field.posX ~= nil and field.posZ ~= nil then
            local isOwned = field.farmland ~= nil and g_farmlandManager:getFarmlandOwner(field.farmland.id) == farmId
            local category = Searchables.getText(isOwned and "searchables_ownedField" or "searchables_kind_field")
            local extraWords = isOwned and ("owned mine " .. Searchables.getText("searchables_owned")) or WheresMyStuff.getFarmlandNpcName(field.farmland)
            -- crop and work to do: searchable ("wheat harvest", "lime") and shown on the marker
            local status = WheresMyStuff.getFieldStatus(field)
            local name = WheresMyStuff.getFieldName(field, i)
            if status.label ~= "" then
                name = string.format("%s (%s)", name, status.label)
            end
            local result = WheresMyStuff.newResult(WheresMyStuff.KIND_FIELD, name, category,
                nil, field.posX, field.posZ, extraWords .. " " .. status.words)
            result.areaHa = field.areaHa
            result.farmlandId = field.farmland ~= nil and field.farmland.id or nil
            table.insert(results, result)
        end
    end
    return results
end

-- Every property (farmland) on the map, by its number: typing 178 finds property 178. "owned" is added to the search
-- text of the farm's own properties.
function WheresMyStuff.scanFarmlands(farmId)
    local results = {}
    for id, farmland in pairs(g_farmlandManager:getFarmlands() or {}) do
        if farmland.xWorldPos ~= nil and farmland.zWorldPos ~= nil and farmland.showOnFarmlandsScreen ~= false then
            local name = farmland.name
            if name == nil or name == "" or tonumber(name) ~= nil then
                name = string.format(Searchables.getText("searchables_farmlandName"), tostring(farmland.id or id))
            end
            local owner = g_farmlandManager:getFarmlandOwner(farmland.id or id)
            local isOwned = owner == farmId
            local extraWords = isOwned and ("owned mine " .. Searchables.getText("searchables_owned")) or WheresMyStuff.getFarmlandNpcName(farmland)
            -- nobody owns it: it can be bought. "for sale $<100k ha>5"
            if owner == FarmlandManager.NO_OWNER_FARM_ID then
                local forSale = Searchables.getText("searchables_forSale")
                extraWords = string.format("%s for sale buy %s", extraWords, forSale)
                name = string.format("%s (%s, %s, %s ha)", name, forSale, g_i18n:formatMoney(farmland.price or 0, 0, true, true),
                    string.format("%.1f", farmland.areaInHa or 0))
            end
            local result = WheresMyStuff.newResult(WheresMyStuff.KIND_FARMLAND, name, Searchables.getText("searchables_kind_farmland"),
                nil, farmland.xWorldPos, farmland.zWorldPos, extraWords)
            result.farmlandId = farmland.id or id
            result.price = farmland.price
            result.areaHa = farmland.areaInHa
            table.insert(results, result)
        end
    end
    return results
end

-- Splits free text into lowercase words
function WheresMyStuff.getSearchWords(text)
    return Searchables.getSearchWords(text)
end

-- Value of a map result for a filter: price and size of land, fill level of pallets and bales, and for vehicles and
-- buildings whatever the shop knows (hp, width, capacity...)
function WheresMyStuff.getResultValueRange(result, kind)
    if kind == "price" and result.price ~= nil then
        return result.price, result.price
    elseif kind == "area" and result.areaHa ~= nil then
        return result.areaHa, result.areaHa
    elseif kind == "capacity" and result.fillLevel ~= nil then
        return result.fillLevel, result.fillLevel
    elseif result.storeItem ~= nil then
        return Searchables.getStoreItemValueRange(result.storeItem, kind)
    end
    return nil
end

-- Every word must appear somewhere in the name, category, kind or type (case-insensitive). A word that is only a number
-- must match a whole number, so 178 finds field and property 178 but not 1780 or 2178. Filters (ha>5, $<100k, l>1000)
-- only match results that have that value.
function WheresMyStuff.matchesSearch(result, words, filters)
    for _, filter in ipairs(filters or {}) do
        local low, high = WheresMyStuff.getResultValueRange(result, filter.kind)
        if low == nil or not Searchables.rangeMatches(filter, low, high) then
            return false
        end
    end
    for _, word in ipairs(words) do
        if word:match("^%d+$") then
            if not result.searchText:find("%f[%d]" .. word .. "%f[%D]") then
                return false
            end
        elseif not result.searchText:find(word, 1, true) then
            return false
        end
    end
    return true
end

-- Everything matching the text, unsorted
-- ---------------------------------------------------------------------------------------------
-- Contracts
-- ---------------------------------------------------------------------------------------------

-- Field contracts that can still be taken, and the ones this farm is working on. "contract", "contract harvest",
-- "contract huber". The marker shows the contract, the field and the reward.
function WheresMyStuff.scanContracts(farmId)
    local results = {}
    if g_missionManager == nil then
        return results
    end
    local available = Searchables.getText("searchables_contractAvailable")
    local active = Searchables.getText("searchables_contractActive")

    for _, mission in ipairs(g_missionManager:getMissions() or {}) do
        local field = mission.getField ~= nil and mission:getField() or nil
        local isAvailable = mission.status == MissionStatus.CREATED
        local isOurs = mission.farmId == farmId and mission.getIsInProgress ~= nil and mission:getIsInProgress()
        if field ~= nil and (isAvailable or isOurs) then
            local x, z = field.posX, field.posZ
            local fieldName = WheresMyStuff.getFieldName(field, field.getId ~= nil and field:getId() or "?")
            local npc = mission.getNPC ~= nil and mission:getNPC() or nil
            local reward = mission.getReward ~= nil and mission:getReward() or mission.reward or 0
            local state = isAvailable and available or active
            local name = string.format("%s: %s (%s, %s)", tostring(mission.title or "?"), fieldName,
                g_i18n:formatMoney(reward, 0, true, true), state)
            local extraWords = string.format("%s %s %s %s", isAvailable and "available" or "active", state,
                npc ~= nil and npc.title or "", mission.type ~= nil and tostring(mission.type.name) or "")
            local result = WheresMyStuff.newResult(WheresMyStuff.KIND_CONTRACT, name, Searchables.getText("searchables_kind_contract"),
                nil, x, z, extraWords)
            result.price = reward
            result.areaHa = field.areaHa
            table.insert(results, result)
        end
    end
    return results
end

-- Position of the word that asks for contracts ("contract"), in English or the player's language, or nil
function WheresMyStuff.findContractWord(words)
    local translated = Searchables.toLower(Searchables.getText("searchables_contract"))
    for i, word in ipairs(words) do
        if word == "contract" or word == "contracts" or word == translated then
            return i
        end
    end
    return nil
end

function WheresMyStuff.search(text, farmId)
    -- words plus shop-style filters: "for sale $<100k ha>5", "wool l>1000", "tractor hp>200"
    local query = Searchables.parseQuery(text)
    local words, filters = query.words, query.filters
    local matches = {}
    if #words == 0 and #filters == 0 then
        return matches
    end

    -- "sell wheat": where to sell it instead of where things are
    local sellIndex = WheresMyStuff.findSellWord(words)
    if sellIndex ~= nil then
        table.remove(words, sellIndex)
        return WheresMyStuff.searchSellPoints(words)
    end

    -- contracts only when asked for, so "harvest" finds fields ready to harvest, not every harvest contract
    local scans = {WheresMyStuff.scanVehicles, WheresMyStuff.scanStock, WheresMyStuff.scanBuildings, WheresMyStuff.scanFields,
        WheresMyStuff.scanFarmlands}
    local contractIndex = WheresMyStuff.findContractWord(words)
    if contractIndex ~= nil then
        table.remove(words, contractIndex)
        scans = {WheresMyStuff.scanContracts}
    end

    for _, scan in ipairs(scans) do
        for _, result in ipairs(scan(farmId)) do
            if WheresMyStuff.matchesSearch(result, words, filters) then
                table.insert(matches, result)
            end
        end
    end
    return WheresMyStuff.removePropertiesOfMatchedFields(matches)
end

-- One arrow per piece of land: a property is left out when a field on it matched too (searching 5 finds field 5 on
-- property 5). The field's arrow sits on the number the map shows. Properties without a matching field stay.
function WheresMyStuff.removePropertiesOfMatchedFields(matches)
    local fieldFarmlands = {}
    for _, result in ipairs(matches) do
        if result.kind == WheresMyStuff.KIND_FIELD and result.farmlandId ~= nil then
            fieldFarmlands[result.farmlandId] = true
        end
    end

    local kept = {}
    for _, result in ipairs(matches) do
        if result.kind ~= WheresMyStuff.KIND_FARMLAND or not fieldFarmlands[result.farmlandId] then
            table.insert(kept, result)
        end
    end
    return kept
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
-- Raw ground state of a field (by its number), to check what the field search reads
function WheresMyStuff:consoleField(numberArg)
    local number = tostring(numberArg or "")
    for i, field in ipairs(g_fieldManager.fields or {}) do
        local id = field.getId ~= nil and field:getId() or i
        if tostring(id) == number or tostring(field.name) == number then
            local ok, state = pcall(WheresMyStuff.readFieldState, field)
            if not ok or state == nil then
                return string.format("Could not read field %s: %s", number, tostring(state))
            end
            local fruitType = state.fruitTypeIndex ~= FruitType.UNKNOWN and g_fruitTypeManager:getFruitTypeByIndex(state.fruitTypeIndex) or nil
            print(string.format("Field %s at %.0f, %.0f: valid=%s fruit=%s growth=%s (harvest %s-%s, withered %s) ground=%s",
                number, field.posX, field.posZ, tostring(state.isValid), fruitType ~= nil and fruitType.name or "none",
                tostring(state.growthState), tostring(fruitType ~= nil and fruitType.minHarvestingGrowthState),
                tostring(fruitType ~= nil and fruitType.maxHarvestingGrowthState), tostring(fruitType ~= nil and fruitType.witheredState),
                tostring(state.groundType)))
            print(string.format("  spray=%s lime=%s plow=%s roller=%s weeds=%s stones=%s stubble=%s water=%s",
                tostring(state.sprayLevel), tostring(state.limeLevel), tostring(state.plowLevel), tostring(state.rollerLevel),
                tostring(state.weedState), tostring(state.stoneLevel), tostring(state.stubbleShredLevel), tostring(state.waterLevel)))
            WheresMyStuff.fieldStatuses[field] = nil
            local status = WheresMyStuff.getFieldStatus(field)
            return string.format("  search sees: %s", status.label ~= "" and status.label or "(nothing)")
        end
    end
    return string.format("No field %s. Usage: wmsField <field number>", number)
end

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
    addConsoleCommand("wmsField", "Where's My Stuff: show what the field search reads for a field", "consoleField", WheresMyStuff, "fieldNumber")
    Logging.info("[WheresMyStuff] Loaded. Console commands: wmsSummary, wmsList, wmsLeftovers, wmsShow, wmsHide, wmsGoto, wmsFind, wmsTarget, wmsField")
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
    removeConsoleCommand("wmsField")
    WheresMyStuff.removeHotspots()
    WheresMyStuffMapSearch.delete()
end

addModEventListener(WheresMyStuff)
