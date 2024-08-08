local myname, ns = ...
local myfullname = C_AddOns.GetAddOnMetadata(myname, "Title")

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
            -- routes = {},
        },
    })
    db = _G[myname.."DB"]
    ns.db = db

    self:UnregisterCallback("ADDON_LOADED")
    if IsLoggedIn() then self:PLAYER_LOGIN() else self:RegisterCallback("PLAYER_LOGIN") end
end)
function ns:PLAYER_LOGIN()
    self:UnregisterCallback("PLAYER_LOGIN")
end

function ns:GetPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    local position = C_Map.GetPlayerMapPosition(mapID, "player")
    return position, mapID
end

function ns:StartRoute(threshold)
    -- print("StartRoute", threshold)
    -- threshold in yards
    local thresholdSq = (threshold or 10) ^ 2

    local position, mapID = self:GetPosition()
    ns.route = {mapID = mapID, start = time()}
    local zw, zh = ns:GetZoneSize(mapID)
    table.insert(ns.route, position)
    ns.ticker = C_Timer.NewTicker(1, function(ticker)
        local newposition = self:GetPosition()
        local distanceSq = CalculateDistanceSq(position.x * zw, position.y * zh, newposition.x * zw, newposition.y * zh)
        -- print("Moved since last:", math.sqrt(distance))
        if distanceSq > thresholdSq then
            table.insert(ns.route, newposition)
            position = newposition
            -- print("Logged", position:GetXY())
        end
    end)
    ns:RegisterCallback("ZONE_CHANGED_NEW_AREA", self.StopRoute)
end

function ns:StopRoute(...)
    ns.ticker = ns.ticker:Cancel()

    local route = ns.route
    route.stop = time()
    ns.route = nil

    local zw, zh = ns:GetZoneSize(route.mapID)
    local distance = 0
    local out = {}
    for i, position in ipairs(route) do
        if route[i - 1] then
            distance = distance + CalculateDistance(route[i - 1].x * zw, route[i - 1].y * zh, position.x * zw, position.y * zh)
        end
        table.insert(out, self:GetCoord(position:GetXY()))
    end
    print("Finished route", #route, "points; ", distance, "yards traveled;", route.stop - route.start, "seconds")

    StaticPopup_Show("ROUTERECORDER_COPYBOX", nil, nil, string.join(", ", unpack(out)))
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

_G.RouteRecorder_OnAddonCompartmentClick = function(addon, button, ...)
    -- DevTools_Dump({addon, button, ...})
    if button == "LeftButton" then
        if ns.ticker then
            ns:StopRoute()
        else
            ns:StartRoute()
        end
    elseif button == "RightButton" then
    end
end

StaticPopupDialogs["ROUTERECORDER_COPYBOX"] = {
    text = "Copy me",
    hasEditBox = true,
    hideOnEscape = true,
    whileDead = true,
    closeButton = true,
    editBoxWidth = 350,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    button1 = "Done",
    OnButton1 = function(self, data)
        return false
    end,
    OnShow = function(self, data)
        if data then
            self.editBox:SetText(data)
            self.editBox:HighlightText()
        end
    end,
}
