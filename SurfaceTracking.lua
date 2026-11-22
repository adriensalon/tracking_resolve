local M = {}

local function cross(a, b, p)
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
end

function M.isConvex(corners)
    -- Fusion coordinates are y-up, so the named corners wind clockwise.
    for i, a in ipairs(corners) do
        if cross(a, corners[i % 4 + 1], corners[(i + 1) % 4 + 1]) >= -1e-6 then
            return false
        end
    end
    return true
end

function M.firstInvalidFrame(patterns, motions)
    local corners = {}
    for frame = 1, #motions[1] do
        for i, pattern in ipairs(patterns) do
            local motion = motions[i][frame]
            corners[i] = { x = pattern.centerX + motion.x, y = pattern.centerY + motion.y }
        end
        if not M.isConvex(corners) then return frame end
    end
end

local function inside(corners, x, y)
    local p = { x = x, y = y }
    for i, a in ipairs(corners) do
        if cross(a, corners[i % 4 + 1], p) > 0 then return false end
    end
    return true
end

local function gradientScore(frame, width, cx, cy, halfWidth, halfHeight)
    local xx, yy, xy, count = 0, 0, 0, 0
    for y = cy - halfHeight + 1, cy + halfHeight - 1, 2 do
        for x = cx - halfWidth + 1, cx + halfWidth - 1, 2 do
            local pixel = y * width + x + 1
            local dx = frame:byte(pixel + 1) - frame:byte(pixel - 1)
            local dy = frame:byte(pixel + width) - frame:byte(pixel - width)
            xx, yy, xy = xx + dx * dx, yy + dy * dy, xy + dx * dy
            count = count + 1
        end
    end
    -- The smaller eigenvalue favors patches with detail along both axes.
    return (xx + yy - math.sqrt((xx - yy)^2 + 4 * xy^2)) / (2 * count)
end

local function features(frame, width, height, corners, params)
    local found = {}
    local patternWidth, patternHeight = math.min(params.patternWidth, 0.055), math.min(params.patternHeight, 0.055)
    local halfWidth = math.max(3, math.floor(patternWidth * width / 2 + 0.5))
    local halfHeight = math.max(3, math.floor(patternHeight * height / 2 + 0.5))
    local cornerPaddingX = (halfWidth + 3) / (width - 1) + params.patternWidth / 2
    local cornerPaddingY = (halfHeight + 3) / (height - 1) + params.patternHeight / 2
    local function independentOfCorners(x, y)
        for _, corner in ipairs(corners) do
            if math.abs(corner.x - x) < cornerPaddingX and math.abs(corner.y - y) < cornerPaddingY then
                return false
            end
        end
        return true
    end
    local positions = { 0.20, 0.50, 0.80 }
    local offsets = { { 0, 0 }, { -0.08, 0 }, { 0.08, 0 }, { 0, -0.08 }, { 0, 0.08 } }
    local tl, tr, br, bl = corners[1], corners[2], corners[3], corners[4]
    for _, column in ipairs(positions) do
        for _, row in ipairs(positions) do
            local best, bestScore = nil, 16
            for _, offset in ipairs(offsets) do
                local u, v = column + offset[1], row + offset[2]
                local x = (tl.x * (1 - u) + tr.x * u) * (1 - v) + (bl.x * (1 - u) + br.x * u) * v
                local y = (tl.y * (1 - u) + tr.y * u) * (1 - v) + (bl.y * (1 - u) + br.y * u) * v
                local cx, cy = math.floor(x * (width - 1) + 0.5), math.floor((1 - y) * (height - 1) + 0.5)
                local left, right = (cx - halfWidth) / (width - 1), (cx + halfWidth) / (width - 1)
                local top, bottom = 1 - (cy - halfHeight) / (height - 1), 1 - (cy + halfHeight) / (height - 1)
                if independentOfCorners(x, y) and left >= 0 and right <= 1 and bottom >= 0 and top <= 1
                    and inside(corners, left, top) and inside(corners, right, top)
                    and inside(corners, left, bottom) and inside(corners, right, bottom) then
                    local score = gradientScore(frame, width, cx, cy, halfWidth, halfHeight)
                    if score > bestScore then
                        best = { centerX = cx / (width - 1), centerY = 1 - cy / (height - 1) }
                        bestScore = score
                    end
                end
            end
            if best then
                best.patternWidth, best.patternHeight = patternWidth, patternHeight
                best.searchWidth, best.searchHeight = params.searchWidth, params.searchHeight
                best.adaptReference, best.minimumConfidence = true, 0.65
                found[#found + 1] = best
            end
        end
    end
    return found
end

local function solve(rows)
    for i = 1, 8 do
        local pivot = i
        for j = i + 1, 8 do
            if math.abs(rows[j][i]) > math.abs(rows[pivot][i]) then pivot = j end
        end
        if math.abs(rows[pivot][i]) < 1e-9 then return nil end
        rows[i], rows[pivot] = rows[pivot], rows[i]
        local divisor = rows[i][i]
        for k = i, 9 do rows[i][k] = rows[i][k] / divisor end
        for j = 1, 8 do
            if j ~= i then
                local factor = rows[j][i]
                for k = i, 9 do rows[j][k] = rows[j][k] - factor * rows[i][k] end
            end
        end
    end
    local model = {}
    for i = 1, 8 do model[i] = rows[i][9] end
    return model
end

local function fit(matches)
    local rows = {}
    for _, p in ipairs(matches) do
        local x, y, u, v = p.x, p.y, p.u, p.v
        rows[#rows + 1] = { x, y, 1, 0, 0, 0, -u * x, -u * y, u }
        rows[#rows + 1] = { 0, 0, 0, x, y, 1, -v * x, -v * y, v }
    end
    if #rows == 8 then return solve(rows) end

    -- Least-squares refinement over all features agreeing with the model.
    local normal = {}
    for i = 1, 8 do
        normal[i] = {}
        for j = 1, 9 do
            local product = 0
            for _, row in ipairs(rows) do product = product + row[i] * row[j] end
            normal[i][j] = product
        end
    end
    return solve(normal)
end

local function project(model, x, y)
    local scale = model[7] * x + model[8] * y + 1
    if scale <= 1e-5 then return nil end
    return (model[1] * x + model[2] * y + model[3]) / scale,
        (model[4] * x + model[5] * y + model[6]) / scale
end

local function bounds(points)
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(points) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
    end
    return minX, maxX, minY, maxY
end

local function surfaceForFrame(matches, corners, previous, width, height, params)
    if #matches < 4 then return nil end
    local bestInliers, bestError, bestProjection = {}, math.huge
    local function consider(model, minimum)
        if not model then return end
        local inliers, errorSum = {}, 0
        for _, p in ipairs(matches) do
            local u, v = project(model, p.x, p.y)
            if u then
                local err = ((p.u - u) * width)^2 + ((p.v - v) * height)^2
                if err <= 9 then
                    inliers[#inliers + 1] = p
                    errorSum = errorSum + err
                end
            end
        end
        if #inliers < minimum or #inliers < #bestInliers
            or (#inliers == #bestInliers and errorSum >= bestError) then return end
        local minX, maxX, minY, maxY = bounds(inliers)
        if maxX - minX < 0.45 or maxY - minY < 0.45 then return end

        local projection = {}
        for i, p in ipairs(corners) do
            local x, y = project(model, p.x, p.y)
            if not x or math.abs(x - previous[i].x) > params.searchWidth
                or math.abs(y - previous[i].y) > params.searchHeight then return end
            projection[i] = { x = x, y = y }
        end
        if not M.isConvex(projection) then return end
        bestInliers, bestError, bestProjection = inliers, errorSum, projection
    end

    local minimum = math.max(4, math.floor(#matches / 2) + 1)
    consider(fit(matches), minimum)
    local order, seed = {}, 12345
    for i = 1, #matches do order[i] = i end
    -- Repeatable samples of four points avoid bias toward one part of the surface.
    for _ = 1, 64 do
        if #bestInliers == #matches or #matches == 4 then break end
        local subset = {}
        for i = 1, 4 do
            seed = (seed * 16807) % 2147483647
            local j = i + seed % (#matches - i + 1)
            order[i], order[j] = order[j], order[i]
            subset[i] = matches[order[i]]
        end
        consider(fit(subset), minimum)
    end
    if #bestInliers > 4 then consider(fit(bestInliers), minimum) end
    return bestProjection
end

function M.recover(readFrame, count, width, height, patterns, pointTracking)
    local reference = assert(readFrame(), "The first A frame could not be read.")
    local manualCorners, motions = {}, {}
    for i, params in ipairs(patterns) do
        manualCorners[i] = { x = params.centerX, y = params.centerY }
        motions[i] = { { x = 0, y = 0 } }
    end
    local minX, maxX, minY, maxY = bounds(manualCorners)
    local function normalized(x, y)
        return (x - minX) / (maxX - minX) - 0.5, (y - minY) / (maxY - minY) - 0.5
    end
    local corners, trackers = {}, {}
    local function add(params)
        local ok, advance = pcall(pointTracking.newTracker, reference, width, height, params)
        if ok then
            local x, y = normalized(params.centerX, params.centerY)
            trackers[#trackers + 1] = { advance = advance, x = x, y = y, cx = params.centerX, cy = params.centerY }
        end
    end
    for i, params in ipairs(patterns) do
        local x, y = normalized(params.centerX, params.centerY)
        corners[i] = { x = x, y = y }
        add(params)
    end
    for _, params in ipairs(features(reference, width, height, manualCorners, patterns[1])) do
        add(params)
    end
    if #trackers < 4 then return nil, 1 end

    local previous = manualCorners
    for frame = 2, count do
        local image = assert(readFrame(), "An A frame is missing from the capture.")
        local matches = {}
        for _, tracker in ipairs(trackers) do
            local motion = tracker.advance(image)
            if motion then
                matches[#matches + 1] = { x = tracker.x, y = tracker.y,
                    u = tracker.cx + motion.x, v = tracker.cy + motion.y }
            end
        end
        local positions = surfaceForFrame(matches, corners, previous, width, height, patterns[1])
        if not positions then return nil, frame end
        for i, p in ipairs(positions) do
            motions[i][frame] = { x = p.x - manualCorners[i].x, y = p.y - manualCorners[i].y }
        end
        previous = positions
    end
    return motions
end

return M
