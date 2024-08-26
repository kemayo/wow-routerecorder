local myname, ns = ...

-- This is copied mostly from my HandyNotes handler

local RouteWorldMapDataProvider = CreateFromMixins(MapCanvasDataProviderMixin)
ns.RouteWorldMapDataProvider = RouteWorldMapDataProvider

local RoutePinMixin = CreateFromMixins(MapCanvasPinMixin)
local RoutePinConnectionMixin = {}

function RouteWorldMapDataProvider:RemoveAllData()
    if not self:GetMap() then return end

    if self.pinPool then
        self.pinPool:ReleaseAll()
        self.connectionPool:ReleaseAll()
    end
    self:GetMap().ScrollContainer:MarkCanvasDirty()
end

function RouteWorldMapDataProvider:RefreshAllData(fromOnShow)
    if not (self:GetMap() and self:GetMap():IsShown()) then return end
    self:RemoveAllData()

    local uiMapID = self:GetMap():GetMapID()
    if not uiMapID then return end

    if not self.pinPool then
        self:CreatePools()
    end

    for _, route in ipairs(ns.routes) do
        if route.mapID == uiMapID then
            self:DrawRoute(route, uiMapID)
        end
    end
end

function RouteWorldMapDataProvider:CreatePools()
    self.pinPool = CreateFramePool("FRAME", self:GetMap():GetCanvas(), nil, function(pool, pin)
        if not pin.OnReleased then
            Mixin(pin, RoutePinMixin)
        end
        (_G.FramePool_HideAndClearAnchors or _G.Pool_HideAndClearAnchors)(pool, pin)
        pin:OnReleased()

        pin.pinTemplate = nil
        pin.owningMap = nil
    end)
    self.connectionPool = CreateFramePool("FRAME", self:GetMap():GetCanvas(), nil, function(pool, connection)
        if not connection.Line then
            Mixin(connection, RoutePinConnectionMixin)
            connection:SetIgnoreParentScale(true)
            connection.Line = connection:CreateLine()
        end
        (_G.FramePool_HideAndClearAnchors or _G.Pool_HideAndClearAnchors)(pool, connection)
    end)
end

local COLORS = {
    raw = {r=1, g=0, b=0},
    straight = {r=0, g=1, b=1},
}
function RouteWorldMapDataProvider:DrawRoute(route, uiMapID)
    if ns.db.map_raw then
        self:DrawPath(route.raw, uiMapID, "raw", route)
    end
    if ns.db.map_straight then
        self:DrawPath(route.straight, uiMapID, "straight", route)
    end
end

local pins = {}
function RouteWorldMapDataProvider:DrawPath(path, uiMapID, variant, route)
    for _, node in ipairs(path) do
        local x, y = node:GetXY()
        local pin = self:AcquirePin(variant, COLORS[variant], route)
        pin:SetPosition(x, y)
        pin:Show()
        if pins[#pins] then
            self:ConnectPins(pins[#pins], pin, COLORS[variant])
        end
        table.insert(pins, pin)
    end
    wipe(pins)
end

function RouteWorldMapDataProvider:ConnectPins(pin1, pin2, color)
    local connection = self.connectionPool:Acquire()
    connection:Connect(pin1, pin2)
    connection.Line:SetVertexColor(color.r or 1, color.g or 1, color.b or 1, color.a or 0.6)
    connection:Show()
end

function RoutePinMixin:OnLoad()
    -- This is below normal handynotes pins
    self:UseFrameLevelType(ns.CLASSIC and "PIN_FRAME_LEVEL_MAP_LINK" or "PIN_FRAME_LEVEL_EVENT_OVERLAY")
    self:SetSize(12, 12)
    self:EnableMouse()
    self:SetMouseMotionEnabled(true)
    self:SetMouseClickEnabled(true)

    self.texture = self:CreateTexture(nil, "ARTWORK")
    self.texture:SetAtlas("PlayerPartyBlip")
    self.texture:SetAllPoints()
end

function RoutePinMixin:OnAcquired(variant, color, route)
    self.route = route
    self.variant = variant
    self.texture:SetVertexColor(color.r, color.g, color.b, color.a or 1)
end

function RoutePinMixin:OnMouseEnter()
    if self:GetCenter() > UIParent:GetCenter() then -- compare X coordinate
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    else
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    end
    local color = COLORS[self.variant]
    GameTooltip:AddDoubleLine("Route", self.variant, 1, 1, 1, color.r, color.g, color.b)
    GameTooltip:AddDoubleLine(" ", ("%d points"):format(#self.route[self.variant]))
    GameTooltip:AddDoubleLine(" ", ns:GetCoord(self.normalizedX, self.normalizedY))
    GameTooltip:Show()
end

function RoutePinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

function RoutePinMixin:OnMouseUp(button)
    if button == "RightButton" then
        ns:ShowConfigMenu(self.route)
    end
end

function RoutePinConnectionMixin:Connect(pin1, pin2)
    self:SetParent(pin1)
    -- Anchor straight up from the origin
    self:SetPoint("BOTTOM", pin1, "CENTER")

    if not (pin1:GetCenter() and pin2:GetCenter()) then
        -- I'm seeing reports of errors in CalculateAngleBetween which would imply one of the pins
        -- isn't returning a center. I can't reproduce this to test it, but I think aborting here
        -- should avoid errors.
        return
    end

    -- Then adjust the height to be the length from origin to pin
    local length = RegionUtil.CalculateDistanceBetween(pin1, pin2) * pin1:GetEffectiveScale()
    self:SetHeight(length)
    -- And finally rotate all the textures around the origin so they line up
    local quarter = (math.pi / 2)
    local angle = RegionUtil.CalculateAngleBetween(pin1, pin2) - quarter
    self:RotateTextures(angle, 0.5, 0)

    if ns.CLASSIC then
        -- self.Line:SetTexture("Interface\\TaxiFrame\\UI-Taxi-Line")
        self.Line:SetAtlas("_UI-Taxi-Line-horizontal")
    else
        self.Line:SetAtlas("_AnimaChannel-Channel-Line-horizontal")
    end

    self.Line:SetStartPoint("CENTER", pin1)
    self.Line:SetEndPoint("CENTER", pin2)

    self.Line:SetThickness(20)
end

do
    -- This is MapCanvasMixin.AcquirePin lightly rewritten to not require an
    -- XML template, so this can be bundled in with addons without requiring
    -- a custom bit of XML for each one.
    local function OnPinMouseUp(pin, button, upInside)
        pin:OnMouseUp(button)
        if upInside then
            pin:OnClick(button)
        end
    end
    function RouteWorldMapDataProvider:AcquirePin(...)
        local pin, newPin = self.pinPool:Acquire()
        pin.owningMap = self:GetMap()
        if newPin then
            pin:OnLoad()
            local isMouseClickEnabled = pin:IsMouseClickEnabled()
            local isMouseMotionEnabled = pin:IsMouseMotionEnabled()

            if isMouseClickEnabled then
                pin:SetScript("OnMouseUp", OnPinMouseUp)
                pin:SetScript("OnMouseDown", pin.OnMouseDown)
            end

            if isMouseMotionEnabled then
                pin:SetScript("OnEnter", pin.OnMouseEnter)
                pin:SetScript("OnLeave", pin.OnMouseLeave)
            end

            pin:SetMouseClickEnabled(isMouseClickEnabled)
            pin:SetMouseMotionEnabled(isMouseMotionEnabled)
        end

        self:GetMap().ScrollContainer:MarkCanvasDirty()
        pin:Show()
        pin:OnAcquired(...)

        return pin
    end
end

