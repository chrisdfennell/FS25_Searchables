-- WheresMyStuffHotspot
-- Map marker for one search result (pallet, big bag, bale, vehicle, building or field).
-- Follows the object if it is moved and hides itself once it is gone. Fields have no node and stay put.

WheresMyStuffHotspot = {}
local WheresMyStuffHotspot_mt = Class(WheresMyStuffHotspot, MapHotspot)

WheresMyStuffHotspot.ICON = Utils.getFilename("icon_marker.dds", g_currentModDirectory)
WheresMyStuffHotspot.ICON_SIZE = 20

-- Marker tint per item kind
WheresMyStuffHotspot.COLORS = {
    pallet = {1.00, 0.60, 0.10, 1},
    bigBag = {0.25, 0.60, 1.00, 1},
    bale = {0.45, 0.85, 0.25, 1},
    vehicle = {1.00, 0.25, 0.85, 1},
    building = {1.00, 0.85, 0.10, 1},
    field = {0.30, 0.95, 0.95, 1},
    farmland = {0.75, 1.00, 0.30, 1},
    sellPoint = {1.00, 0.40, 0.40, 1},
}

function WheresMyStuffHotspot.getColor(kind)
    return WheresMyStuffHotspot.COLORS[kind] or {1, 1, 1, 1}
end

-- item: {kind, x, z, ...} search result, name: text shown when the marker is selected, node: object to follow or nil
function WheresMyStuffHotspot.new(item, name, node)
    local self = MapHotspot.new(WheresMyStuffHotspot_mt)

    self.node = node
    self.name = name
    self.width, self.height = getNormalizedScreenValues(WheresMyStuffHotspot.ICON_SIZE, WheresMyStuffHotspot.ICON_SIZE)
    self.icon = Overlay.new(WheresMyStuffHotspot.ICON, 0, 0, self.width, self.height)
    self.kind = item.kind
    self.icon:setColor(unpack(WheresMyStuffHotspot.getColor(item.kind)))
    self.clickArea = MapHotspot.getClickCircle(0.667)

    self:setWorldPosition(item.x, item.z)

    return self
end

-- Listed under the "Other" map filter
function WheresMyStuffHotspot:getCategory()
    return MapHotspot.CATEGORY_OTHER
end

function WheresMyStuffHotspot:getName()
    return self.name
end

function WheresMyStuffHotspot:getIsObjectPresent()
    return self.node ~= nil and self.node ~= 0 and entityExists(self.node)
end

-- Markers without a node (fields) are fixed positions and never go away
function WheresMyStuffHotspot:getIsStatic()
    return self.node == nil
end

-- Live position, so the marker stays on a pallet that was picked up and moved
function WheresMyStuffHotspot:getWorldPosition()
    if self:getIsObjectPresent() then
        local x, _, z = getWorldTranslation(self.node)
        return x, z
    end
    return WheresMyStuffHotspot:superClass().getWorldPosition(self)
end

-- Hide once the item was sold, opened or otherwise deleted
function WheresMyStuffHotspot:getIsVisible()
    if not WheresMyStuffHotspot:superClass().getIsVisible(self) then
        return false
    end
    return self:getIsStatic() or self:getIsObjectPresent()
end
