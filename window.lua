local myname, ns = ...
local myfullname = C_AddOns.GetAddOnMetadata(myname, "Title")

-- A small window that starts/stops a recording and shows live progress.

local WINDOW_WIDTH = 300
local COLLAPSED_HEIGHT = 92
local EXPANDED_HEIGHT = 300
local COORD_LIST_HEIGHT = 110

local Window = CreateFrame("Frame", "RouteRecorderWindow", UIParent, "BasicFrameTemplateWithInset")
Window:SetSize(WINDOW_WIDTH, COLLAPSED_HEIGHT)
Window:SetPoint("CENTER")
Window:SetFrameStrata("DIALOG")
Window:SetMovable(true)
Window:EnableMouse(true)
Window:SetClampedToScreen(true)
Window:RegisterForDrag("LeftButton")
Window:SetScript("OnDragStart", Window.StartMoving)
Window:SetScript("OnDragStop", Window.StopMovingOrSizing)
Window:Hide()
Window.TitleText:SetText(myfullname)
tinsert(UISpecialFrames, "RouteRecorderWindow")

-- Always visible: start/stop, and a single line of live (or idle) status.
local StartStopButton = CreateFrame("Button", nil, Window, "UIPanelButtonTemplate")
StartStopButton:SetSize(120, 22)
StartStopButton:SetPoint("TOP", Window, "TOP", 0, -30)

local StatsText = Window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
StatsText:SetPoint("TOP", StartStopButton, "BOTTOM", 0, -4)
StatsText:SetJustifyH("CENTER")

-- Everything below here only appears once at least one route has been recorded this session.
local RouteDropdown = CreateFrame("DropdownButton", nil, Window, "WowStyle1DropdownTemplate")
RouteDropdown:SetSize(240, 22)
RouteDropdown:SetPoint("TOP", StatsText, "BOTTOM", 0, -8)

local SummaryText = Window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
SummaryText:SetPoint("TOP", RouteDropdown, "BOTTOM", 0, -6)
SummaryText:SetJustifyH("CENTER")

local CoordScroll = CreateFrame("ScrollFrame", nil, Window, "UIPanelScrollFrameTemplate")
CoordScroll:SetPoint("TOP", SummaryText, "BOTTOM", 0, -8)
CoordScroll:SetSize(220, COORD_LIST_HEIGHT)
local CoordContent = CreateFrame("Frame", nil, CoordScroll)
CoordContent:SetSize(220, 1)
CoordScroll:SetScrollChild(CoordContent)
local CoordText = CoordContent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
CoordText:SetPoint("TOPLEFT")
CoordText:SetJustifyH("LEFT")
CoordText:SetWidth(220)

local EpsilonLabel = Window:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
EpsilonLabel:SetPoint("TOPLEFT", CoordScroll, "BOTTOMLEFT", 4, -10)
EpsilonLabel:SetText("Straighten tolerance:")

local EpsilonBox = CreateFrame("EditBox", nil, Window, "InputBoxTemplate")
EpsilonBox:SetSize(60, 20)
EpsilonBox:SetAutoFocus(false)
EpsilonBox:SetPoint("LEFT", EpsilonLabel, "RIGHT", 10, -1)

local StraightenButton = CreateFrame("Button", nil, Window, "UIPanelButtonTemplate")
StraightenButton:SetSize(110, 22)
StraightenButton:SetPoint("TOPLEFT", EpsilonLabel, "BOTTOMLEFT", -4, -10)
StraightenButton:SetText("Straighten")

local CopyButton = CreateFrame("Button", nil, Window, "UIPanelButtonTemplate")
CopyButton:SetSize(110, 22)
CopyButton:SetPoint("LEFT", StraightenButton, "RIGHT", 8, 0)
CopyButton:SetText("Copy Coords")

local tweakwidgets = {RouteDropdown, SummaryText, CoordScroll, EpsilonLabel, EpsilonBox, StraightenButton, CopyButton}
local function SetTweakPanelShown(shown)
    for _, widget in ipairs(tweakwidgets) do
        widget:SetShown(shown)
    end
    Window:SetHeight(shown and EXPANDED_HEIGHT or COLLAPSED_HEIGHT)
end
-- Collapsed until SyncState (on first OnShow) has real route data to decide otherwise.
-- Also keeps RouteDropdown:IsShown() false so SetupMenu below won't generate against
-- ns.routes before ADDON_LOADED has created it.
SetTweakPanelShown(false)

local function FormatDuration(seconds)
    seconds = floor(seconds)
    return ("%d:%02d"):format(floor(seconds / 60), seconds % 60)
end

local function RouteLabel(route)
    return ("%d: %s"):format(route.mapID, date("%H:%M:%S", route.start))
end

local function UpdateLiveStats()
    local route = ns.route
    if not route then return end
    local distance = ns:MeasureRoute(route.raw, route.mapID)
    StatsText:SetText(("Recording... %s   %d pts   %d yd"):format(FormatDuration(time() - route.start), #route.raw, distance))
end

-- The route currently displayed in the results/tweak panel below.
local selectedroute
local function RefreshRouteDisplay()
    if not selectedroute then return end
    local distance = ns:MeasureRoute(selectedroute.raw, selectedroute.mapID)
    SummaryText:SetText(("%d raw points, %d straightened  \194\183  %d yards  \194\183  %s"):format(
        #selectedroute.raw, #selectedroute.straight, distance, FormatDuration(selectedroute.stop - selectedroute.start)
    ))

    local lines = {}
    for i, position in ipairs(selectedroute.straight) do
        lines[i] = ("%d.  %d"):format(i, ns:GetCoord(position:GetXY()))
    end
    CoordText:SetText(table.concat(lines, "\n"))
    CoordContent:SetHeight(max(CoordText:GetStringHeight(), CoordScroll:GetHeight()))
    CoordScroll:SetVerticalScroll(0)
end

local function SyncState()
    if ns.ticker then
        StartStopButton:SetText("Stop Recording")
        UpdateLiveStats()
    else
        StartStopButton:SetText("Start Recording")
        StatsText:SetText("Not recording")
    end

    -- The currently selected route may have been deleted (via the map pin's context menu).
    if selectedroute and not tIndexOf(ns.routes, selectedroute) then
        selectedroute = nil
    end
    if not selectedroute then
        selectedroute = ns.routes[#ns.routes]
    end

    local hasroutes = #ns.routes > 0
    SetTweakPanelShown(hasroutes)
    if hasroutes then
        RouteDropdown:GenerateMenu()
        RefreshRouteDisplay()
    end
end

-- Not calling SyncState() yet: ns.routes doesn't exist until ADDON_LOADED, which is
-- guaranteed to have happened by the time anything can actually show this window.
Window:SetScript("OnShow", SyncState)

StartStopButton:SetScript("OnClick", function()
    if ns.ticker then
        ns:StopRoute()
    else
        ns:StartRoute()
    end
end)

RouteDropdown:SetupMenu(function(dropdown, rootDescription)
    for i = #ns.routes, 1, -1 do
        local route = ns.routes[i]
        rootDescription:CreateRadio(RouteLabel(route), function() return selectedroute == route end, function()
            selectedroute = route
            EpsilonBox:SetText(ns.epsilonToString(route.epsilon))
            RefreshRouteDisplay()
            return MenuResponse.Close
        end)
    end
end)

StraightenButton:SetScript("OnClick", function()
    if not selectedroute then return end
    local epsilon = tonumber(EpsilonBox:GetText()) or ns.DEFAULT_EPSILON
    selectedroute.straight = ns:StraightenRoute(selectedroute.raw, epsilon)
    selectedroute.epsilon = epsilon
    EpsilonBox:SetText(ns.epsilonToString(epsilon))
    RefreshRouteDisplay()
    ns.RouteWorldMapDataProvider:RefreshAllData()
end)

CopyButton:SetScript("OnClick", function()
    if not selectedroute then return end
    ns:ShowRouteToCopy(selectedroute)
end)

local liveticker
ns:RegisterCallback("OnRouteStarted", function(self, route)
    liveticker = C_Timer.NewTicker(0.5, UpdateLiveStats)
    SyncState()
    Window:Show()
end)

ns:RegisterCallback("OnRouteStopped", function(self, route)
    if liveticker then liveticker = liveticker:Cancel() end
    selectedroute = route
    EpsilonBox:SetText(ns.epsilonToString(route.epsilon))
    SyncState()
    Window:Show()
end)

function ns:ToggleWindow()
    if Window:IsShown() then
        Window:Hide()
    else
        Window:Show()
    end
end
