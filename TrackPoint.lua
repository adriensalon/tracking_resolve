local c = comp or composition or (fusion and fusion:GetCurrentComp())
assert(c, "Resolve did not supply this effect's composition.")
local root = assert(os.getenv("LOCALAPPDATA")) .. "\\TrackingResolve\\"
local surfaceKey = "TrackingResolve.TrackingSurface.Target"
local pointKey = "TrackingResolve.TrackingPoint.Target"
local surfaceRequest = c:GetData(surfaceKey)
local isSurface = surfaceRequest == true or type(surfaceRequest) == "string"
local requestKey = isSurface and surfaceKey or pointKey
local request = isSurface and surfaceRequest or c:GetData(pointKey)
c:SetData(requestKey, false)

-- The capture is downscaled before decoding to grayscale in Lua.
local TRACK_WIDTH, TRACK_HEIGHT = 320, 180
local SURFACE_CORNERS = {
    { id = "TopLeft", name = "Top Left" },
    { id = "TopRight", name = "Top Right" },
    { id = "BottomRight", name = "Bottom Right" },
    { id = "BottomLeft", name = "Bottom Left" },
}

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
    local center = isSurface and "TopLeft" or "PatternCenter"
    return inputs.MainInput1 and inputs[center] and inputs.SearchWidth and inputs.TrackForward
end

local function findEffect()
    if type(request) == "string" then
        local group = c:FindTool(request)
        local inputs = inputsFor(group)
        if isTrackingEffect(inputs) then return group, inputs end
        error("Could not find the effect that sent Bake tracking.", 0)
    end

    local group, inputs
    for _, tool in pairs(c:GetToolList(false) or {}) do
        local fields = inputsFor(tool)
        if isTrackingEffect(fields) then
            assert(not group, "Resolve did not identify which tracking effect sent the request.")
            group, inputs = tool, fields
        end
    end
    return assert(group, "Could not locate the tracking effect."), inputs
end

local group, inputs
local logName = isSurface and "SurfaceInsert.log" or "PointInsert.log"

local function status(message)
    print(message)
    local file = io.open(root .. logName, "a")
    if file then
        file:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n")
        file:close()
    end
end

local function showWarning(title, message)
    -- The effect runs on the Edit page, where Fusion's AskUser dialog is unavailable.
    local ffi = require("ffi")
    ffi.cdef[[
        void * __stdcall GetActiveWindow(void);
        int __stdcall MultiByteToWideChar(unsigned int codePage, unsigned long flags, const char *input,
            int inputLength, wchar_t *output, int outputLength);
        int __stdcall MessageBoxW(void *owner, const wchar_t *text, const wchar_t *title, unsigned int flags);
    ]]
    local user32 = ffi.load("user32")
    local function wide(text)
        local buffer = ffi.new("wchar_t[?]", #text + 1)
        local CP_UTF8 = 65001
        assert(ffi.C.MultiByteToWideChar(CP_UTF8, 0, text, -1, buffer, #text + 1) > 0,
            "Could not convert the tracking warning to UTF-16.")
        return buffer
    end

    local MB_ICONWARNING, MB_SETFOREGROUND = 0x30, 0x10000
    local result = user32.MessageBoxW(user32.GetActiveWindow(), wide(message), wide(title),
        MB_ICONWARNING + MB_SETFOREGROUND)
    assert(result ~= 0, "Could not show the tracking warning.")
end

local function findTrackControls()
    local suffix = isSurface and SURFACE_CORNERS[1].id or ""
    for _, child in pairs(group:GetChildrenList() or {}) do
        local fields = inputsFor(child)
        if fields.TrackReady and fields["TrackX" .. suffix] and fields["TrackY" .. suffix] then
            return child, fields
        end
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

local function track(folder, first, last, patterns, surfaceTracking)
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
    local function reader()
        local index = 0
        return function()
            index = index + 1
            if index == 1 then return reference end
            local luma, w, h = readTGA(folder .. "\\" .. files[index].name)
            assert(w == width and h == height, "Captured frames have inconsistent sizes.")
            return luma
        end
    end

    local ok, motions, lost, lostIndex = pcall(tracker.trackMany, reader(), #files, width, height, patterns)
    if not surfaceTracking then
        if not ok then error(motions, 0) end
        if lost then
            error(("Tracking lost the feature at A frame %d. Choose a feature that stays visible throughout A.")
                :format(first + lost - 1), 0)
        end
        return motions
    end

    local reason
    if not ok then
        reason = tostring(motions)
    elseif lost then
        reason = ("Tracking lost the %s corner at A frame %d."):format(patterns[lostIndex].name, first + lost - 1)
    else
        local invalidFrame = surfaceTracking.firstInvalidFrame(patterns, motions)
        if not invalidFrame then return motions end
        reason = ("The tracked corners no longer form a convex surface at A frame %d."):format(first + invalidFrame - 1)
    end

    status(reason .. " Trying other features inside the surface.")
    local recovered, failedFrame = surfaceTracking.recover(reader(), #files, width, height, patterns, tracker)
    if not recovered then
        error(("%s Surface recovery could not fit the plane from visible features at A frame %d.")
            :format(reason, first + failedFrame - 1), 0)
    end
    return recovered, true
end

local function bake(controls, fields, first, patterns, motions)
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
    local oldReady = controls:GetInput("TrackReady")
    local tracks = {}
    for index, params in ipairs(patterns) do
        local xSpline = spline(fields["TrackX" .. params.suffix])
        local ySpline = spline(fields["TrackY" .. params.suffix])
        tracks[index] = {
            x = { spline = xSpline, previous = xSpline:GetKeyFrames(), keys = {} },
            y = { spline = ySpline, previous = ySpline:GetKeyFrames(), keys = {} },
        }
    end
    for index = 1, #motions[1] do
        local frame = first + index - 1
        for slot, params in ipairs(patterns) do
            local sample, track = motions[slot][index], tracks[slot]
            local x, y = params.centerX + sample.x, params.centerY + sample.y
            track.x.keys[frame] = { x, Flags = { Linear = true } }
            track.y.keys[frame] = { y, Flags = { Linear = true } }
        end
    end

    c:StartUndo("Bake tracking")
    local ok, message = pcall(function()
        for index, track in ipairs(tracks) do
            local label = patterns[index].name or "point"
            writeKeys(track.x.spline, track.x.keys, "Could not write the horizontal track for " .. label .. ".")
            writeKeys(track.y.spline, track.y.keys, "Could not write the vertical track for " .. label .. ".")
        end
        controls:SetInput("TrackReady", 1)
        assert(controls:GetInput("TrackReady") == 1, "Could not enable the tracked position.")
    end)
    if not ok then
        for _, track in ipairs(tracks) do
            pcall(function() track.x.spline:SetKeyFrames(track.x.previous, true) end)
            pcall(function() track.y.spline:SetKeyFrames(track.y.previous, true) end)
        end
        pcall(function() controls:SetInput("TrackReady", oldReady) end)
    end
    c:EndUndo(ok)
    if not ok then error(message, 0) end
end

local function run(controls, fields)
    local surfaceTracking = isSurface and dofile(root .. "SurfaceTracking.lua")
    local attrs = c:GetAttrs()
    -- Resolve's render range is the portion of A used on the timeline.
    local first, last = attrs.COMPN_RenderStart, attrs.COMPN_RenderEnd
    assert(type(first) == "number" and type(last) == "number", "Could not read A's frame range.")
    assert(last > first, "A needs at least two frames to track motion.")

    local patternWidth, patternHeight = group:GetInput("PatternWidth", first), group:GetInput("PatternHeight", first)
    local searchWidth, searchHeight = group:GetInput("SearchWidth", first), group:GetInput("SearchHeight", first)
    local points = isSurface and SURFACE_CORNERS or { { id = "PatternCenter" } }
    local patterns, corners = {}, {}
    for index, point in ipairs(points) do
        local center = assert(group:GetInput(point.id, first),
            "Missing tracking position for " .. (point.name or "Pattern Center") .. ".")
        local x, y = center.X or center[1], center.Y or center[2]
        corners[index] = { x = x, y = y }
        patterns[index] = {
            name = point.name,
            suffix = isSurface and point.id or "",
            adaptReference = isSurface,
            centerX = x, centerY = y,
            patternWidth = patternWidth, patternHeight = patternHeight,
            searchWidth = searchWidth, searchHeight = searchHeight,
        }
    end
    assert(not surfaceTracking or surfaceTracking.isConvex(corners),
        "Place the four named corners around a convex surface at A's first frame.")
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
    local ok, motions, recovered = pcall(function()
        capture(source, first, last, folder)
        status(("Tracking A frames %d-%d."):format(first, last))
        return track(folder, first, last, patterns, surfaceTracking)
    end)
    for _, item in pairs(bmd.readdir(folder .. "\\*.tga") or {}) do
        if type(item) == "table" and item.Name then
            os.remove(folder .. "\\" .. item.Name)
        end
    end
    bmd.removedir(folder)
    if not ok then error(motions, 0) end
    bake(controls, fields, first, patterns, motions)
    if recovered then return ("Tracked %d A frames using other features on the surface."):format(#motions[1]), true end
    return ("Tracked %d A frames."):format(#motions[1])
end

local controls, fields
local ok, message, recovered = pcall(function()
    group, inputs = findEffect()
    controls, fields = findTrackControls()
    return run(controls, fields)
end)
if not ok then
    message = "Track failed. " .. tostring(message):gsub("^.-:%d+: ", "")
end
status(message)
if isSurface and fields and fields.TrackStatus then
    -- Older effect instances still expose their original Inspector status.
    controls:SetInput("TrackStatus", message)
end
if not ok or recovered then
    local title = isSurface and "Tracking Surface" or "Tracking Point"
    local shown, failure = pcall(showWarning, title, message)
    if not shown then
        status("Warning dialog unavailable. " .. tostring(failure))
    end
end
