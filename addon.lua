local myname, ns = ...
local myfullname = C_AddOns.GetAddOnMetadata(myname, "Title")

ns.DEFAULT_EPSILON = 0.00002

ns.CLASSIC = WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE

local Callbacks = CreateFrame("EventFrame")
Callbacks:SetUndefinedEventsAllowed(true)
Callbacks:SetScript("OnEvent", function(self, event, ...)
    self:TriggerEvent(event, event, ...)
end)
Callbacks:RegisterEvent("ADDON_LOADED")
Callbacks:Hide()
ns.Callbacks = Callbacks

Callbacks:GenerateCallbackEvents{
    "OnRouteStarted", "OnRouteStopped", "OnRouteChanged",
}
ns.Event = Callbacks.Event

-- help out with callback boilerplate:
function ns:RegisterCallback(event, func)
    if not func and ns[event] then func = ns[event] end
    if not Callbacks:DoesFrameHaveEvent(event) then
        Callbacks:RegisterEvent(event)
    end
    return Callbacks:RegisterCallback(event, func, self)
end
function ns:UnregisterCallback(event)
    if not Callbacks:DoesFrameHaveEvent(event) then
        Callbacks:UnregisterEvent(event)
    end
    return Callbacks:UnregisterCallback(event, self)
end
function ns:TriggerEvent(...)
    return Callbacks:TriggerEvent(...)
end

local db

ns:RegisterCallback("ADDON_LOADED", function(self, event, name)
    if name ~= myname then return end

    _G[myname.."DB"] = setmetatable(_G[myname.."DB"] or {}, {
        __index = {
            threshold = 10,
            interval = 1,
            map_raw = false,
            map_straight = true,
            map_loops = true,
            -- routes = {},
        },
    })
    db = _G[myname.."DB"]
    ns.db = db

    ns.routes = {}

    self:UnregisterCallback("ADDON_LOADED")
    if IsLoggedIn() then self:PLAYER_LOGIN() else self:RegisterCallback("PLAYER_LOGIN") end
end)
function ns:PLAYER_LOGIN()
    WorldMapFrame:AddDataProvider(ns.RouteWorldMapDataProvider)

    self:UnregisterCallback("PLAYER_LOGIN")
end

function ns:StartRoute(threshold)
    -- print("StartRoute", threshold)
    -- threshold in yards
    local thresholdSq = (threshold or db.threshold) ^ 2

    local mapID = C_Map.GetBestMapForUnit("player")
    local position = C_Map.GetPlayerMapPosition(mapID, "player")
    ns.route = {mapID = mapID, start = time(), raw = {},}
    local zw, zh = ns:GetZoneSize(mapID)
    table.insert(ns.route.raw, position)
    ns.ticker = C_Timer.NewTicker(db.interval, function(ticker)
        -- always on the starting mapID
        local newposition = C_Map.GetPlayerMapPosition(mapID, "player")
        local distanceSq = CalculateDistanceSq(position.x * zw, position.y * zh, newposition.x * zw, newposition.y * zh)
        -- print("Moved since last:", math.sqrt(distance))
        if distanceSq > thresholdSq then
            -- TODO: detect if the previous point is on a straight line between the new point and previous-1, and remove it?
            table.insert(ns.route.raw, newposition)
            position = newposition
            -- print("Logged", position:GetXY())
        end
    end)
    self:RegisterCallback("ZONE_CHANGED_NEW_AREA", function(...)
        if self:StopRouteIfOutOfBounds() then
            self:UnregisterCallback("ZONE_CHANGED_NEW_AREA")
        end
    end)
    self:TriggerEvent("OnRouteStarted", ns.route)
end

function ns:StopRouteIfOutOfBounds()
    if not ns.route then return end
    local position = C_Map.GetPlayerMapPosition(ns.route.mapID, "player")
    if not (position and self:PositionIsWithinBounds(position)) then
        self:StopRoute()
        return true
    end
end

function ns:StopRoute(...)
    if not self.ticker then return end
    ns.ticker = ns.ticker:Cancel()

    local route = self.route
    route.stop = time()
    route.loops = self:FindRepeatedLoops(route.raw, route.mapID)
    route.straight = self:StraightenRoute(route.raw, ns.DEFAULT_EPSILON)
    route.epsilon = ns.DEFAULT_EPSILON
    ns.route = nil

    table.insert(ns.routes, route)

    ns.RouteWorldMapDataProvider:RefreshAllData()

    self:TriggerEvent("OnRouteStopped", route)
end

function ns:PositionIsWithinBounds(position)
    local x, y = position:GetXY()
    if not (x and y) or not (WithinRange(x, 0, 1) and WithinRange(y, 0, 1)) then
        return false
    end
    return true
end

function ns:CalculateDistance(position1, position2, scalex, scaley)
    scalex, scaley = scalex or 1, scaley or 1
    return CalculateDistance(
        position1.x * scalex, position1.y * scaley,
        position2.x * scalex, position2.y * scaley
    )
end

function ns:MeasureRoute(route, mapID)
    -- The route will be measured in zone-heights if no mapID is provided
    local zw, zh = 1.5, 1
    if mapID then
        -- With a mapID, this will return yards
        zw, zh = self:GetZoneSize(mapID)
    end
    local distance = 0
    for i, position in ipairs(route) do
        if route[i - 1] then
            distance = distance + self:CalculateDistance(route[i - 1], position, zw, zh)
        end
    end
    return distance
end

function ns:StraightenRoute(raw, epsilon)
    local straight = {}
    for i, position in ipairs(raw) do
        -- Now, work out whether this was superfluous:
        if i == 1 or i == #raw then
            -- First and last coords always get added
            table.insert(straight, position)
        elseif raw[i - 1] and raw[i + 1] then
            -- Is this point on a straight line between the point before and after it?
            -- Check whether the distance <a to b> + <b to c> is about the same as <a to c>
            local routedistance = self:CalculateDistance(position, raw[i - 1]) + self:CalculateDistance(position, raw[i + 1])
            local straightdistance = self:CalculateDistance(raw[i - 1], raw[i + 1])
            -- Third arg to ApproximatelyEqual is the tuning factor for the curve, and is
            -- how far the distances are allowed to deviate while still being "equal".
            -- Worst-case for this is long slow gentle curves, which will be entirely smoothed
            -- into a straight line. Fixing this would involve doing something more
            -- complicated.
            -- (This is coord-scaled, so 0-1 as percent-of-zone; MathUtil.Epsilon is .000001, which is too small)
            if not ApproximatelyEqual(routedistance, straightdistance, epsilon or ns.DEFAULT_EPSILON) then
                table.insert(straight, position)
            end
        end
    end
    return straight
end

-- Call after changing a route's epsilon or which of its loops are removed
function ns:RefreshRoute(route)
    route.straight = self:StraightenRoute(self:GetPrunedPath(route), route.epsilon)
    self.RouteWorldMapDataProvider:RefreshAllData()
    self:TriggerEvent("OnRouteChanged", route)
end

function ns:ShowRouteToCopy(route)
    local function coordify(position)
        return self:GetCoord(position:GetXY())
    end
    local path = self:GetPrunedPath(route)
    self:ClearText()
    self:ShowTextToCopy(("%d (%d) points; %d yards traveled; %d seconds"):format(#route.straight, #path, self:MeasureRoute(path, route.mapID), route.stop - route.start))
    self:ShowTextToCopy(path == route.raw and "Raw coords" or "Raw coords (repeated loops removed)", unpack(TableUtil.Transform(path, coordify)))
    self:ShowTextToCopy("Straightened coords", unpack(TableUtil.Transform(route.straight, coordify)))
end

_G.RouteRecorder_Straighten = function(coords, epsilon)
    local raw = TableUtil.Transform(coords, function(coord)
        return CreateVector2D(ns:GetXY(coord))
    end)
    local straight = ns:StraightenRoute(raw, epsilon)
    local mapID = C_Map.GetBestMapForUnit("player")
    local route = {
        raw = raw,
        straight = straight,
        loops = ns:FindRepeatedLoops(raw, mapID),
        epsilon = epsilon,
        start = time(),
        stop = time(),
        mapID = mapID,
    }
    ns:ShowRouteToCopy(route)
    table.insert(ns.routes, route)
    ns.RouteWorldMapDataProvider:RefreshAllData()
end

do
    cache = {}
    function ns:GetZoneSize(mapID)
        if not cache[mapID] then
            local width, height
            if C_Map.GetMapWorldSize then
                width, height = C_Map.GetMapWorldSize(mapID)
            else -- TODO: test this branch...
                -- classic doesn't have GetMapWorldSize???
                local _, center = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.5, 0.5))
                local _, topleft = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
                if center and topleft then
                    local top, left = topleft:GetXY()
                    local bottom, right = center:GetXY()
                    width = (left - right) * 2
                    height = (top - bottom) * 2
                end
            end
            cache[mapID] = {width, height}
        end
        return unpack(cache[mapID])
    end
end

function ns:GetCoord(x, y)
    return floor(x * 10000 + 0.5) * 10000 + floor(y * 10000 + 0.5)
end

function ns:GetXY(coord)
    return floor(coord / 10000) / 10000, (coord % 10000) / 10000
end

-- These are tiny numbers, and I want them represented well
function ns.epsilonToString(x)
    -- shortest %g that still round-trips back to the same float
    -- (%g is "use whichever is shortest: %f or %e")
    local s
    for prec = 1, 17 do
        s = string.format("%." .. prec .. "g", x)
        if tonumber(s) == x then break end
    end

    local mant, exp = s:match("^(.-)[eE]([-+]?%d+)$")
    if mant then
        local sig = #(mant:gsub("[-.]", ""))          -- significant digits
        local dec = math.max(sig - 1 - tonumber(exp), 0)  -- decimals needed
        s = string.format("%." .. dec .. "f", x)
    end
    return s
end

local function SetLoopsRemoved(route, removed)
    for _, loop in ipairs(route.loops) do
        loop.removed = removed
    end
    ns:RefreshRoute(route)
end

-- loop and lap are set when the menu is opened from a repeated lap on the map
function ns:ShowConfigMenu(route, loop, lap)
    local function makeRadios(key, description, ...)
        local isSelected = function(val) return db[key] == val end
        local setSelected = function(val)
            db[key] = val
            ns.RouteWorldMapDataProvider:RefreshAllData()
            return MenuResponse.Close
        end
        for i=1, select("#", ...) do
            local radio = select(i, ...) -- {text, value}
            description:CreateRadio(radio[1], isSelected, setSelected, radio[2])
        end
    end
    local checkIsSelected = function(key) return db[key] end
    local checkSetSelected = function(key)
        db[key] = not db[key]
        ns.RouteWorldMapDataProvider:RefreshAllData()
        -- return MenuResponse.Clos
    end
    MenuUtil.CreateContextMenu(nil, function(owner, rootDescription)
        rootDescription:SetTag("MENU_RANGERECORDER_CONTEXT")
        rootDescription:CreateTitle(myfullname)

        if loop then
            rootDescription:CreateButton("Remove repeated laps", function()
                loop.removed = true
                ns:RefreshRoute(route)
            end)
            rootDescription:CreateButton("Keep this lap instead", function()
                loop.keep = lap
                ns:RefreshRoute(route)
            end)
            rootDescription:CreateDivider()
        end
        if route then
            rootDescription:CreateButton("Delete Route", function()
                tDeleteItem(ns.routes, route)
                ns.RouteWorldMapDataProvider:RefreshAllData()
            end)
            if route.loops and #route.loops > 0 then
                rootDescription:CreateButton("Remove all repeated loops", function() SetLoopsRemoved(route, true) end)
                rootDescription:CreateButton("Restore removed loops", function() SetLoopsRemoved(route, false) end)
            end
            rootDescription:CreateDivider()
        end

        local map = rootDescription:CreateButton("On map...")
        map:CreateCheckbox("Raw points", checkIsSelected, checkSetSelected, "map_raw")
        map:CreateCheckbox("Straightened points", checkIsSelected, checkSetSelected, "map_straight")
        map:CreateCheckbox("Repeated loops", checkIsSelected, checkSetSelected, "map_loops")

        makeRadios("threshold",
            rootDescription:CreateButton("Threshold"),
            {"5 yards", 5},
            {"10 yards", 10},
            {"25 yards", 25},
            {"40 yards", 40}
        )
        makeRadios("interval",
            rootDescription:CreateButton("Interval"),
            {"0.5 seconds", 0.5},
            {"1.0 seconds", 1},
            {"1.5 seconds", 1.5},
            {"2.0 seconds", 2},
            {"5.0 seconds", 5}
        )
    end)
end

_G.RouteRecorder_OnAddonCompartmentClick = function(addon, button, ...)
    -- DevTools_Dump({addon, button, ...})
    if button == "LeftButton" then
        ns:ToggleWindow()
    elseif button == "RightButton" then
        ns:ShowConfigMenu()
    end
end

do
    local TextDump = LibStub("LibTextDump-1.0", true)
    if not TextDump then return end
    local window
    function ns:ShowTextToCopy(...)
        if not window then
            window = TextDump:New(myname, 420, 280)
        end
        window:AddLine(string.join(', ', tostringall(...)))
        window:Display()
    end
    function ns:ClearText()
        if not window then return end
        window:Clear()
    end
end
