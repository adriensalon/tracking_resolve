local c = comp or composition or (fusion and fusion:GetCurrentComp())
assert(c, "Resolve did not supply this effect's composition.")
local root = assert(os.getenv("LOCALAPPDATA")) .. "\\TrackingResolve\\"
local request = c:GetData("TrackingResolve.TrackingPoint.Target")
c:SetData("TrackingResolve.TrackingPoint.Target", false)

-- The capture is downscaled before decoding to grayscale in Lua.
local TRACK_WIDTH, TRACK_HEIGHT = 320, 180

local function inputsFor(node)
    local inputs = {}
    if node then
        for key, input in pairs(node:GetInputList() or {}) do
            local id = input:GetAttrs().INPS_ID
            if id then inputs[id] = input end
            if type(key) == "string" then inputs[key] = input end
        end
    end
    return inputs
end

local function isTrackingEffect(inputs)
    return inputs.MainInput1 and inputs.PatternCenter and inputs.SearchWidth and inputs.TrackForward
end

local function findEffect()
    if type(request) == "string" then
        local group = c:FindTool(request)
        local inputs = inputsFor(group)
        if isTrackingEffect(inputs) then return group, inputs end
        error("Could not find the Tracking Point effect that sent Bake tracking.", 0)
    end

    local group, inputs
    for _, tool in pairs(c:GetToolList(false) or {}) do
        local fields = inputsFor(tool)
        if isTrackingEffect(fields) then
            assert(not group, "Resolve did not identify which Tracking Point effect sent the request.")
            group, inputs = tool, fields
        end
    end
    return assert(group, "Could not locate the Tracking Point effect."), inputs
end

local group, inputs = findEffect()

local function status(message)
    print(message)
    local file = io.open(root .. "PointInsert.log", "a")
    if file then
        file:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n")
        file:close()
    end
end

local function findTrackControls()
    for _, child in pairs(group:GetChildrenList() or {}) do
        local fields = inputsFor(child)
        if fields.TrackX and fields.TrackY and fields.TrackReady then return child, fields end
    end
    error("Could not find the tracking animation controls.", 0)
end

local function capture(source, first, last, folder)
    local attrs = c:GetAttrs()
    local resize, saver
    local ok, result = pcall(function()
        -- BetterResize is the registry ID of Fusion's Resize node.
        resize = assert(c:AddTool("BetterResize", -32768, -32768), "Could not add a temporary Resize.")
        saver = assert(c:AddTool("Saver", -32768, -32768), "Could not add a temporary Saver.")
        assert(resize:ConnectInput("Input", source), "Could not connect A to the Resize.")
        resize:SetInput("Width", TRACK_WIDTH)
        resize:SetInput("Height", TRACK_HEIGHT)
        assert(saver:ConnectInput("Input", resize.Output), "Could not connect the Resize to the Saver.")
        saver.Clip = folder .. "\\frame_.tga"
        assert(c:Render({ Start = first, End = last, Step = 1, Wait = true, Tool = saver, HiQ = true, Proxy = false }),
            "Resolve could not capture A from the Edit effect.")
    end)
    if saver then saver:Delete() end
    if resize then resize:Delete() end
    local current = c:GetAttrs()
    if current.COMPN_RenderStart ~= attrs.COMPN_RenderStart or current.COMPN_RenderEnd ~= attrs.COMPN_RenderEnd then
        c:SetAttrs({ COMPN_RenderStart = attrs.COMPN_RenderStart, COMPN_RenderEnd = attrs.COMPN_RenderEnd })
    end
    if not ok then error(result, 0) end
end

-- Read a TGA (uncompressed or RLE, 8/24/32-bit) and return a flat luma byte string (top-down).
local function readTGA(path)
    local file = assert(io.open(path, "rb"), "Could not open " .. path)
    local data = file:read("*a")
    file:close()
    local idLen = data:byte(1) or 0
    local colorMapType = data:byte(2) or 0
    local imageType = data:byte(3) or 0
    local width = (data:byte(13) or 0) + (data:byte(14) or 0) * 256
    local height = (data:byte(15) or 0) + (data:byte(16) or 0) * 256
    local depth = data:byte(17) or 24
    local descriptor = data:byte(18) or 0
    assert(width > 0 and height > 0 and #data >= 18, "Invalid TGA header.")
    assert(colorMapType == 0 and (depth == 8 or depth == 24 or depth == 32),
        ("Unsupported %d-bit TGA capture."):format(depth))
    local bytesPerPixel = depth / 8
    local pos = 19 + idLen

    local function readPixel()
        assert(pos + bytesPerPixel - 1 <= #data, "A captured TGA frame is truncated.")
        local b, g, r = data:byte(pos, pos + bytesPerPixel - 1)
        pos = pos + bytesPerPixel
        return r and math.floor((r * 299 + g * 587 + b * 114) / 1000) or b
    end

    local pixels, pixelCount = {}, width * height
    if imageType == 2 or imageType == 3 then
        for _ = 1, pixelCount do pixels[#pixels + 1] = readPixel() end
    elseif imageType == 10 or imageType == 11 then
        while #pixels < pixelCount do
            local header = assert(data:byte(pos), "A captured TGA frame is truncated.")
            pos = pos + 1
            local count = header % 128 + 1
            assert(#pixels + count <= pixelCount, "A captured TGA frame has invalid run lengths.")
            if header >= 128 then
                local value = readPixel()
                for _ = 1, count do pixels[#pixels + 1] = value end
            else
                for _ = 1, count do pixels[#pixels + 1] = readPixel() end
            end
        end
    else
        error(("Unsupported TGA image type %d."):format(imageType))
    end

    local topDown = descriptor % 64 >= 32
    local rightToLeft = descriptor % 32 >= 16
    local out = {}
    for row = 0, height - 1 do
        local srcRow = topDown and row or (height - 1 - row)
        for col = 0, width - 1 do
            local srcCol = rightToLeft and (width - 1 - col) or col
            out[#out + 1] = string.char(pixels[srcRow * width + srcCol + 1])
        end
    end
    return table.concat(out), width, height
end

local function track(folder, first, last, params)
    local files = {}
    for _, item in pairs(bmd.readdir(folder .. "\\*.tga") or {}) do
        local name = type(item) == "table" and item.Name
        local frame = name and name:match("^frame_([%-]?%d+)%.tga$")
        if frame then files[#files + 1] = { name = name, frame = tonumber(frame) } end
    end
    table.sort(files, function(left, right) return left.frame < right.frame end)
    assert(#files == last - first + 1, ("Captured %d of %d A frames."):format(#files, last - first + 1))
    for index = 2, #files do
        assert(files[index].frame == files[index - 1].frame + 1, "The captured A frames are not consecutive.")
    end

    local tracker = dofile(root .. "PointTracking.lua")
    local reference, width, height = readTGA(folder .. "\\" .. files[1].name)
    local index = 0
    return tracker.track(function()
        index = index + 1
        if index == 1 then return reference end
        local luma, w, h = readTGA(folder .. "\\" .. files[index].name)
        assert(w == width and h == height, "Captured frames have inconsistent sizes.")
        return luma
    end, #files, width, height, params)
end

local function bake(controls, fields, first, motion, centerX, centerY)
    local function spline(input)
        local output = assert(input:GetConnectedOutput(), "A tracking animation spline is missing.")
        return output:GetTool()
    end
    local function writeKeys(spline, keys, message)
        assert(spline:SetKeyFrames(keys, true) ~= false, message)
        local written = assert(spline:GetKeyFrames(), message)
        for frame, key in pairs(keys) do
            local actual = written[frame] and written[frame][1]
            assert(actual and math.abs(actual - key[1]) < 1e-6, message)
        end
    end
    local xSpline, ySpline = spline(fields.TrackX), spline(fields.TrackY)
    local oldX, oldY = xSpline:GetKeyFrames(), ySpline:GetKeyFrames()
    local oldReady = controls:GetInput("TrackReady")
    local xKeys, yKeys = {}, {}
    for index, sample in ipairs(motion) do
        local frame = first + index - 1
        xKeys[frame] = { centerX + sample.x, Flags = { Linear = true } }
        yKeys[frame] = { centerY + sample.y, Flags = { Linear = true } }
    end

    c:StartUndo("Bake tracking")
    local ok, message = pcall(function()
        writeKeys(xSpline, xKeys, "Could not write the horizontal track.")
        writeKeys(ySpline, yKeys, "Could not write the vertical track.")
        controls:SetInput("TrackReady", 1)
        assert(controls:GetInput("TrackReady") == 1, "Could not enable the tracked position.")
    end)
    if not ok then
        pcall(function() xSpline:SetKeyFrames(oldX, true) end)
        pcall(function() ySpline:SetKeyFrames(oldY, true) end)
        pcall(function() controls:SetInput("TrackReady", oldReady) end)
    end
    c:EndUndo(ok)
    if not ok then error(message, 0) end
end

local function run()
    local controls, fields = findTrackControls()

    local attrs = c:GetAttrs()
    -- Resolve's render range is the portion of A used on the timeline.
    local first, last = attrs.COMPN_RenderStart, attrs.COMPN_RenderEnd
    assert(type(first) == "number" and type(last) == "number", "Could not read A's frame range.")
    assert(last > first, "A needs at least two frames to track motion.")

    local center = assert(group:GetInput("PatternCenter", first), "A tracking center is required.")
    local params = {
        centerX = center.X or center[1],
        centerY = center.Y or center[2],
        patternWidth = group:GetInput("PatternWidth", first),
        patternHeight = group:GetInput("PatternHeight", first),
        searchWidth = group:GetInput("SearchWidth", first),
        searchHeight = group:GetInput("SearchHeight", first),
    }
    local source = assert(inputs.MainInput1:GetConnectedOutput(), "Resolve did not expose A's image to this effect.")

    local jobIndex = 0
    local folder
    repeat
        jobIndex = jobIndex + 1
        folder = root .. ("PointInsertJobs\\%d-%d"):format(os.time(), jobIndex)
    until not bmd.direxists(folder)
    bmd.createdir(folder)
    assert(bmd.direxists(folder), "Could not create a capture folder.")

    status(("Capturing A frames %d-%d."):format(first, last))
    local ok, motion, lost = pcall(function()
        capture(source, first, last, folder)
        status(("Tracking A frames %d-%d."):format(first, last))
        return track(folder, first, last, params)
    end)
    for _, item in pairs(bmd.readdir(folder .. "\\*.tga") or {}) do
        if type(item) == "table" and item.Name then
            os.remove(folder .. "\\" .. item.Name)
        end
    end
    bmd.removedir(folder)
    if not ok then error(motion, 0) end
    if lost then
        error(("Tracking lost the feature at A frame %d. Choose a feature that stays visible throughout A.")
            :format(first + lost - 1))
    end
    bake(controls, fields, first, motion, params.centerX, params.centerY)
    status(("Tracked %d A frames."):format(#motion))
end

local ok, message = pcall(run)
if not ok then
    status("Track failed. " .. tostring(message):gsub("^.-:%d+: ", ""))
end
