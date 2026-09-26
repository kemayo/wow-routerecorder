local myname, ns = ...

-- Finds loops that the route went round more than once in a row, so that all but one lap
-- can be cut. Laps are compared with dynamic time warping, which tolerates a sloppy lap
-- (drift, cut corners, short side trips). The match is direction-sensitive, so the return
-- leg of an out-and-back spur never matches its outward leg.

ns.LOOP_TOLERANCE = 20 -- yards; the mean distance allowed between two laps
-- Laps are limited by length, not point count: a fast mount can go round a loop in a few points
local MIN_LAP_POINTS = 4
local MIN_LAP_LENGTH = 3 -- times the tolerance, so that a wobble can't count as a lap
local MAX_LAP_STRETCH = 1.5 -- a repeat can be this much longer than the lap it repeats, for side trips

local sqrt, floor, ceil, min, max = math.sqrt, math.floor, math.ceil, math.min, math.max

local function Distance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

local function PathLength(pts, first, last)
    local length = 0
    for n = first + 1, last do
        length = length + Distance(pts[n - 1], pts[n])
    end
    return length
end

local function SameHeading(pts, i, j)
    local n = #pts
    local a1, a2 = pts[max(i - 1, 1)], pts[min(i + 1, n)]
    local b1, b2 = pts[max(j - 1, 1)], pts[min(j + 1, n)]
    return (a2.x - a1.x) * (b2.x - b1.x) + (a2.y - a1.y) * (b2.y - b1.y) > 0
end

-- Align all of the lap pts[first..last] against the section that starts at last.
-- Returns the index where a repeat of the lap ends, or nil if there is no repeat.
local function MatchRepeat(pts, first, last, tolerance)
    local maxlength = PathLength(pts, first, last) * MAX_LAP_STRETCH + tolerance
    local stop, length = last, 0
    while stop < #pts and length < maxlength do
        stop = stop + 1
        length = length + Distance(pts[stop - 1], pts[stop])
    end
    local a, b = last - first + 1, stop - last + 1
    if b < MIN_LAP_POINTS then return end

    -- Two rows of the DTW grid; count is the number of steps in the best path to a cell,
    -- so that cost / count is the mean distance along it.
    local prevcost, prevcount, cost, count = {}, {}, {}, {}
    for x = 1, a do
        local lap = pts[first + x - 1]
        for y = 1, b do
            local c, k
            if x == 1 and y == 1 then
                c, k = 0, 0
            elseif x == 1 then
                c, k = cost[y - 1], count[y - 1]
            elseif y == 1 then
                c, k = prevcost[1], prevcount[1]
            else
                c, k = prevcost[y - 1], prevcount[y - 1]
                if prevcost[y] < c then c, k = prevcost[y], prevcount[y] end
                if cost[y - 1] < c then c, k = cost[y - 1], count[y - 1] end
            end
            cost[y] = c + Distance(lap, pts[last + y - 1])
            count[y] = k + 1
        end
        prevcost, cost = cost, prevcost
        prevcount, count = count, prevcount
    end

    -- The repeat can end anywhere, but it has to get back to where it started
    local best, bestmean
    for y = MIN_LAP_POINTS, b do
        local mean = prevcost[y] / prevcount[y]
        if mean <= tolerance and (not bestmean or mean < bestmean) and Distance(pts[last + y - 1], pts[last]) <= tolerance * 2 then
            best, bestmean = last + y - 1, mean
        end
    end
    return best
end

-- Returns a list of {laps = {start1, start2, ..., finish}, keep = lap, removed = false}.
-- Lap n is laps[n]..laps[n + 1]; neighbouring laps share their boundary point.
function ns:FindRepeatedLoops(raw, mapID)
    local loops = {}
    local n = #raw
    if n < MIN_LAP_POINTS * 2 then return loops end

    local zw, zh = self:GetZoneSize(mapID)
    local inyards = zw and zh
    if not inyards then
        -- Measure in zone-heights, like MeasureRoute; the tolerance then comes from the step length only
        zw, zh = 1.5, 1
    end
    local pts, steps = {}, {}
    for i, position in ipairs(raw) do
        pts[i] = {x = position.x * zw, y = position.y * zh}
        if i > 1 then steps[i - 1] = Distance(pts[i - 1], pts[i]) end
    end
    table.sort(steps)
    local tolerance = max(inyards and ns.LOOP_TOLERANCE or 0,1.5 * steps[ceil(#steps / 2)])

    local grid = {}
    local function CellKey(cx, cy) return cx .. ":" .. cy end
    local function CellOf(p) return floor(p.x / tolerance), floor(p.y / tolerance) end

    local function FindLaps(j, floorindex)
        local candidates = {}
        local cx, cy = CellOf(pts[j])
        for dx = -1, 1 do
            for dy = -1, 1 do
                for _, i in ipairs(grid[CellKey(cx + dx, cy + dy)] or {}) do
                    if i >= floorindex and Distance(pts[i], pts[j]) <= tolerance and SameHeading(pts, i, j)
                        and PathLength(pts, i, j) >= tolerance * MIN_LAP_LENGTH
                    then
                        table.insert(candidates, i)
                    end
                end
            end
        end
        table.sort(candidates, function(a, b) return Distance(pts[a], pts[j]) < Distance(pts[b], pts[j]) end)
        for _, i in ipairs(candidates) do
            local k = MatchRepeat(pts, i, j, tolerance)
            if k then
                local laps = {i, j, k}
                while true do
                    k = MatchRepeat(pts, laps[#laps - 1], laps[#laps], tolerance)
                    if not k then break end
                    table.insert(laps, k)
                end
                return laps
            end
        end
    end

    local indexed, floorindex, j = 0, 1, 1
    while j <= n do
        while indexed < j - MIN_LAP_POINTS do
            indexed = indexed + 1
            local key = CellKey(CellOf(pts[indexed]))
            grid[key] = grid[key] or {}
            table.insert(grid[key], indexed)
        end
        local laps = FindLaps(j, floorindex)
        if laps then
            -- Keep the shortest lap, as the cleanest
            local keep, shortest
            for lap = 1, #laps - 1 do
                local length = PathLength(pts, laps[lap], laps[lap + 1])
                if not shortest or length < shortest then
                    keep, shortest = lap, length
                end
            end
            table.insert(loops, {laps = laps, keep = keep, removed = false})
            -- Later laps can't match into this group, so its removed ranges never overlap another's
            j = laps[#laps]
            floorindex = j
        end
        j = j + 1
    end
    return loops
end

-- The raw route with the removed laps of each accepted loop cut out
function ns:GetPrunedPath(route)
    local skip
    for _, loop in ipairs(route.loops or {}) do
        if loop.removed then
            skip = skip or {}
            local laps, keep = loop.laps, loop.keep
            for i = laps[1], laps[keep] - 1 do skip[i] = true end
            for i = laps[keep + 1] + 1, laps[#laps] do skip[i] = true end
        end
    end
    if not skip then return route.raw end
    local path = {}
    for i, position in ipairs(route.raw) do
        if not skip[i] then table.insert(path, position) end
    end
    return path
end

-- The points of one lap, for drawing
function ns:GetLapPath(route, loop, lap)
    local path = {}
    for i = loop.laps[lap], loop.laps[lap + 1] do
        table.insert(path, route.raw[i])
    end
    return path
end
