local M = {}

local function nearest(value)
    return math.floor(value + 0.5)
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- Track a pattern across `count` grayscale frames.
--
-- readFrame() returns a string of `width * height` bytes (top-down, one luma byte per pixel).
-- params = {
--   centerX, centerY,          -- pattern center, normalized 0..1 (y up, Fusion convention)
--   patternWidth, patternHeight, -- pattern size, normalized
--   searchWidth, searchHeight,   -- search region size, normalized
-- }
--
-- Returns motion = { { x, y }, ... } of normalized offsets from the pattern center
-- (x right, y up), or motion, lostFrame when the feature is lost.
function M.track(readFrame, count, width, height, params)
    assert(count > 0, "There are no frames to track.")

    local originX = nearest(params.centerX * (width - 1))
    local originY = nearest((1 - params.centerY) * (height - 1))
    local halfWidth = math.max(3, nearest(params.patternWidth * width / 2))
    local halfHeight = math.max(3, nearest(params.patternHeight * height / 2))
    local searchRadiusX = math.max(halfWidth + 1, nearest(params.searchWidth * width / 2))
    local searchRadiusY = math.max(halfHeight + 1, nearest(params.searchHeight * height / 2))
    assert(originX >= halfWidth and originX + halfWidth < width
        and originY >= halfHeight and originY + halfHeight < height,
        "Keep the whole tracking region inside A.")

    -- Sample the reference pattern (9x9 points spanning the pattern box) from frame one.
    local input = assert(readFrame(), "The first A frame could not be read.")
    local samples, sampleCount = {}, 0
    local sum, squareSum = 0, 0
    for iy = -4, 4 do
        local y = nearest(iy * halfHeight / 4)
        for ix = -4, 4 do
            local x = nearest(ix * halfWidth / 4)
            local offset = y * width + x
            local value = input:byte(originY * width + originX + offset + 1)
            samples[#samples + 1] = { offset = offset, value = value }
            sum, squareSum = sum + value, squareSum + value * value
            sampleCount = sampleCount + 1
        end
    end
    local mean = sum / sampleCount
    local referenceVariance = squareSum - sum * mean
    assert(referenceVariance / sampleCount >= 16, "Choose a region with more visible detail.")
    for _, sample in ipairs(samples) do
        sample.value = sample.value - mean
    end

    -- Normalized cross-correlation of the pattern against the window at (cx, cy).
    local function score(frame, cx, cy)
        local sampleSum, sampleSquares, cross = 0, 0, 0
        local base = cy * width + cx + 1
        for _, sample in ipairs(samples) do
            local value = frame:byte(base + sample.offset)
            sampleSum = sampleSum + value
            sampleSquares = sampleSquares + value * value
            cross = cross + value * sample.value
        end
        local variance = sampleSquares - sampleSum * sampleSum / sampleCount
        if variance <= 0 then return -2 end
        return cross / math.sqrt(variance * referenceVariance)
    end

    local searchX, searchY = originX, originY
    local motion = { { x = 0, y = 0 } }
    for frame = 2, count do
        input = assert(readFrame(), "An A frame is missing from the capture.")
        local bestScore, bestDistance = -2, math.huge
        local bestX, bestY
        local minY = clamp(searchY - searchRadiusY, halfHeight, height - 1 - halfHeight)
        local maxY = clamp(searchY + searchRadiusY, halfHeight, height - 1 - halfHeight)
        local minX = clamp(searchX - searchRadiusX, halfWidth, width - 1 - halfWidth)
        local maxX = clamp(searchX + searchRadiusX, halfWidth, width - 1 - halfWidth)
        for candidateY = minY, maxY do
            for candidateX = minX, maxX do
                local s = score(input, candidateX, candidateY)
                local distance = (candidateX - searchX) ^ 2 + (candidateY - searchY) ^ 2
                if s > bestScore + 1e-8
                    or (math.abs(s - bestScore) < 1e-8 and distance < bestDistance) then
                    bestScore, bestDistance, bestX, bestY = s, distance, candidateX, candidateY
                end
            end
        end
        if bestScore < 0.55 then return motion, frame end

        -- Subpixel refinement: parabolic fit of the correlation peak.
        local sx, sy = bestX, bestY
        if bestX > halfWidth and bestX < width - 1 - halfWidth then
            local left = score(input, bestX - 1, bestY)
            local right = score(input, bestX + 1, bestY)
            local denominator = left - 2 * bestScore + right
            if denominator < -1e-9 then
                sx = bestX + (left - right) / (2 * denominator)
            end
        end
        if bestY > halfHeight and bestY < height - 1 - halfHeight then
            local up = score(input, bestX, bestY - 1)
            local down = score(input, bestX, bestY + 1)
            local denominator = up - 2 * bestScore + down
            if denominator < -1e-9 then
                sy = bestY + (up - down) / (2 * denominator)
            end
        end

        motion[#motion + 1] = { x = (sx - originX) / (width - 1), y = (originY - sy) / (height - 1) }
        searchX, searchY = nearest(sx), nearest(sy)
    end
    return motion
end

return M
