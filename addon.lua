local myname, ns = ...
local myfullname = C_AddOns.GetAddOnMetadata(myname, "Title")

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
    "OnRouteStarted", "OnRouteStopped",
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

ns:RegisterCallback("ADDON_LOADED", function(self, event, name)
    if name ~= myname then return end

    _G[myname.."DB"] = setmetatable(_G[myname.."DB"] or {}, {
        __index = {
            threshold = 10,
            interval = 1,
            map_raw = false,
            map_straight = true,
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
    route.straight = {}
    ns.route = nil

    local zw, zh = ns:GetZoneSize(route.mapID)
    local distance = 0
    for i, position in ipairs(route.raw) do
        -- Every coordinate gets logged:
        -- table.insert(raw, self:GetCoord(position:GetXY()))
        -- add the travel distance:
        if route.raw[i - 1] then
            -- distance = distance + CalculateDistance(route[i - 1].x * zw, route[i - 1].y * zh, position.x * zw, position.y * zh)
            distance = distance + self:CalculateDistance(route.raw[i - 1], position, zw, zh)
        end
        -- Now, work out whether this was superfluous:
        if i == 1 or i == #route.raw then
            -- First and last coords always get added
            table.insert(route.straight, position)
        elseif route.raw[i - 1] and route.raw[i + 1] then
            -- Is this point on a straight line between the point before and after it?
            -- Check whether the distance <a to b> + <b to c> is about the same as <a to c>
            local routedistance = self:CalculateDistance(position, route.raw[i - 1]) + self:CalculateDistance(position, route.raw[i + 1])
            local straightdistance = self:CalculateDistance(route.raw[i - 1], route.raw[i + 1])
            -- Third arg to ApproximatelyEqual is the tuning factor for the curve, and is
            -- how far the distances are allowed to deviate while still being "equal".
            -- Worst-case for this is long slow gentle curves, which will be entirely smoothed
            -- into a straight line. Fixing this would involve doing something more
            -- complicated.
            -- (This is coord-scaled, so 0-1 as percent-of-zone; MathUtil.Epsilon is .000001, which is too small)
            if not ApproximatelyEqual(routedistance, straightdistance, 0.0001) then
                table.insert(route.straight, position)
            end
        end
    end
    local function coordify(position)
        return ns:GetCoord(position:GetXY())
    end
    self:ShowTextToCopy(("%d (%d) points; %d yards traveled; %d seconds"):format(#route.straight, #route.raw, distance, route.stop - route.start))
    self:ShowTextToCopy("Raw coords", unpack(TableUtil.Transform(route.raw, coordify)))
    self:ShowTextToCopy("Straightened coords", unpack(TableUtil.Transform(route.straight, coordify)))

    table.insert(ns.routes, route)

    ns.RouteWorldMapDataProvider:RefreshAllData()
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

function ns:ShowConfigMenu()
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

        local map = rootDescription:CreateButton("On map...")
        map:CreateCheckbox("Raw points", checkIsSelected, checkSetSelected, "map_raw")
        map:CreateCheckbox("Straightened points", checkIsSelected, checkSetSelected, "map_straight")

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
        if ns.ticker then
            ns:StopRoute()
        else
            ns:StartRoute()
        end
    elseif button == "RightButton" then
        ns:ShowConfigMenu()
    end
end

do
    local window
    function ns:ShowTextToCopy(...)
        local TextDump = LibStub("LibTextDump-1.0")
        if not window then
            window = TextDump:New(myname, 420, 180)
        end
        window:AddLine(string.join(', ', tostringall(...)))
        window:Display()
    end
end
