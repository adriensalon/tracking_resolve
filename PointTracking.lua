local M = {}

local function nearest(value)
    return math.floor(value + 0.5)
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- Prepare a pattern from the first grayscale frame and advance it one frame at a time.
--
-- input is a string of `width * height` bytes (top-down, one luma byte per pixel).
-- params = {
--   centerX, centerY,          -- pattern center, normalized 0..1 (y up, Fusion convention)
--   patternWidth, patternHeight, -- pattern size, normalized
--   searchWidth, searchHeight,   -- search region size, normalized
--   adaptReference,              -- allow recovery using a recent confident match
--   minimumConfidence,          -- optional first-reference match threshold
-- }
--
local function newTracker(input, width, height, params)
    local originX = nearest(params.centerX * (width - 1))
    local originY = nearest((1 - params.centerY) * (height - 1))
    local halfWidth = math.max(3, nearest(params.patternWidth * width / 2))
    local halfHeight = math.max(3, nearest(params.patternHeight * height / 2))
    local searchRadiusX = math.max(halfWidth + 1, nearest(params.searchWidth * width / 2))
    local searchRadiusY = math.max(halfHeight + 1, nearest(params.searchHeight * height / 2))
    assert(originX >= halfWidth and originX + halfWidth < width
        and originY >= halfHeight and originY + halfHeight < height,
        "Keep the whole tracking region inside A.")

    -- Sample a 9x9 grid spanning the pattern box.
    local offsets = {}
    for iy = -4, 4 do
        local y = nearest(iy * halfHeight / 4)
        for ix = -4, 4 do
            local x = nearest(ix * halfWidth / 4)
            offsets[#offsets + 1] = y * width + x
        end
    end
    local sampleCount = #offsets

    local function makeScorer(frame, cx, cy)
        local samples = {}
        local sum, squareSum = 0, 0
        local base = cy * width + cx + 1
        for index, offset in ipairs(offsets) do
            local value = frame:byte(base + offset)
            samples[index] = value
            sum, squareSum = sum + value, squareSum + value * value
        end
        local mean = sum / sampleCount
        local referenceVariance = squareSum - sum * mean
        if referenceVariance / sampleCount < 16 then return nil end
        for index, value in ipairs(samples) do
            samples[index] = value - mean
        end

        -- Normalized cross-correlation of the pattern against a candidate window.
        return function(candidate, x, y)
            local sampleSum, sampleSquares, cross = 0, 0, 0
            local start = y * width + x + 1
            for index, offset in ipairs(offsets) do
                local value = candidate:byte(start + offset)
                sampleSum = sampleSum + value
                sampleSquares = sampleSquares + value * value
                cross = cross + value * samples[index]
            end
            local variance = sampleSquares - sampleSum * sampleSum / sampleCount
            if variance <= 0 then return -2 end
            return cross / math.sqrt(variance * referenceVariance)
        end
    end

    local firstScorer = assert(makeScorer(input, originX, originY), "Choose a region with more visible detail.")
    local searchX, searchY = originX, originY
    local function locate(frame, score, minimum)
        local bestScore, bestDistance = -2, math.huge
        local bestX, bestY
        local minY = clamp(searchY - searchRadiusY, halfHeight, height - 1 - halfHeight)
        local maxY = clamp(searchY + searchRadiusY, halfHeight, height - 1 - halfHeight)
        local minX = clamp(searchX - searchRadiusX, halfWidth, width - 1 - halfWidth)
        local maxX = clamp(searchX + searchRadiusX, halfWidth, width - 1 - halfWidth)
        for candidateY = minY, maxY do
            for candidateX = minX, maxX do
                local s = score(frame, candidateX, candidateY)
                local distance = (candidateX - searchX) ^ 2 + (candidateY - searchY) ^ 2
                if s > bestScore + 1e-8
                    or (math.abs(s - bestScore) < 1e-8 and distance < bestDistance) then
                    bestScore, bestDistance, bestX, bestY = s, distance, candidateX, candidateY
                end
            end
        end
        if bestScore < minimum then return nil end

        -- Subpixel refinement: parabolic fit of the correlation peak.
        local sx, sy = bestX, bestY
        if bestX > halfWidth and bestX < width - 1 - halfWidth then
            local left = score(frame, bestX - 1, bestY)
            local right = score(frame, bestX + 1, bestY)
            local denominator = left - 2 * bestScore + right
            if denominator < -1e-9 then
                sx = bestX + (left - right) / (2 * denominator)
            end
        end
        if bestY > halfHeight and bestY < height - 1 - halfHeight then
            local up = score(frame, bestX, bestY - 1)
            local down = score(frame, bestX, bestY + 1)
            local denominator = up - 2 * bestScore + down
            if denominator < -1e-9 then
                sy = bestY + (up - down) / (2 * denominator)
            end
        end

        return sx, sy, bestScore
    end

    local recentScorer
    return function(frame)
        local sx, sy, confidence = locate(frame, firstScorer, params.minimumConfidence or 0.55)
        if not sx and recentScorer then
            sx, sy, confidence = locate(frame, recentScorer, 0.70)
        end
        if not sx then return nil end

        searchX, searchY = nearest(sx), nearest(sy)
        if params.adaptReference and confidence >= 0.70 then
            recentScorer = makeScorer(frame, searchX, searchY) or recentScorer
        end
        return { x = (sx - originX) / (width - 1), y = (originY - sy) / (height - 1) }
    end
end

M.newTracker = newTracker

-- Read each frame once for all patterns. Offsets are normalized with x right and y up.
-- On loss, also return the frame and pattern indices where tracking stopped.
function M.trackMany(readFrame, count, width, height, patterns)
    assert(count > 0, "There are no frames to track.")
    local reference = assert(readFrame(), "The first A frame could not be read.")
    local trackers, motions = {}, {}
    for index, params in ipairs(patterns) do
        local ok, advance = pcall(newTracker, reference, width, height, params)
        if not ok then
            if params.name then
                advance = params.name .. ": " .. tostring(advance):gsub("^.-:%d+: ", "")
            end
            error(advance, 0)
        end
        trackers[index], motions[index] = advance, { { x = 0, y = 0 } }
    end

    local samples = {}
    for frame = 2, count do
        local input = assert(readFrame(), "An A frame is missing from the capture.")
        for index, advance in ipairs(trackers) do
            local sample = advance(input)
            if not sample then return motions, frame, index end
            samples[index] = sample
        end
        for index, sample in ipairs(samples) do
            motions[index][frame] = sample
        end
    end
    return motions
end

function M.track(readFrame, count, width, height, params)
    local motions, lost = M.trackMany(readFrame, count, width, height, { params })
    return motions[1], lost
end

return M
