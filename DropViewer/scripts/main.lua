-- Drop Viewer
-- Battle gauge: in single player the drop sits under the portrait. In split
-- screen that gauge has no portrait, so the drop sits under the morale stars,
-- 12 px to the left.
-- When neither slot is ready it sits under the officer name.
-- A combo note (8+/16+/24+) sits on the next line, in the troop-line color,
-- only when that drop can rise a tier.
-- Split screen uses each player's own target gauge. The top half is player 1.
-- Assigned drops live on the AlgoManager record array.
--   character +0x7A0 = record index
--   character +0x7A4 = -1 when this actor emits that record
--   record +0x2D30 = item id, low byte. 255 is blank and stays unlabeled.
--   Ids under 16 are tier-shifted at stage start. The lower three of each
--   group of four rise one tier when the kill combo reaches 8, 16, or 24.
-- read_i32.dll reads each record's item byte once per battle, on its own thread.
-- Labels stay blank until that table is ready.

local MOD = "Drop Viewer"

local function log(msg)
    print(string.format("[%s] %s", MOD, tostring(msg)))
end

local function safe(fn, fallback)
    local ok, value = pcall(fn)
    if ok and value ~= nil then
        return value
    end
    return fallback
end

local function isLive(obj)
    return obj ~= nil and safe(function()
        return obj:IsValid()
    end, false) == true
end

local function textOf(widget)
    if not isLive(widget) then
        return "<no widget>"
    end
    return safe(function()
        local text = widget:GetText()
        if text and text.ToString then
            return text:ToString()
        end
        return tostring(text)
    end, "<GetText failed>")
end

local function unwrap(v, depth)
    depth = depth or 0
    if v == nil or depth > 3 then
        return tostring(v)
    end
    if type(v) ~= "userdata" then
        return tostring(v)
    end
    local inner = safe(function()
        if v.get then
            return v:get()
        end
        return nil
    end, nil)
    if inner ~= nil and inner ~= v then
        return unwrap(inner, depth + 1)
    end
    local asString = safe(function()
        if v.ToString then
            return v:ToString()
        end
        return nil
    end, nil)
    if asString ~= nil and asString ~= "" and asString ~= "nil" then
        return asString
    end
    return tostring(v)
end

local function scriptDirectory()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    source = source:gsub("^@", "")
    local dir = source:match("^(.*)[/\\][^/\\]+$")
    if dir and dir ~= "" then
        return dir
    end
    return "."
end

local SCRIPT_DIR = scriptDirectory()
local DLL_SEP = SCRIPT_DIR:find("\\", 1, true) and "\\" or "/"
local READER_DLL = SCRIPT_DIR .. DLL_SEP .. "read_i32.dll"
local CACHE_ROOT = os.getenv("LOCALAPPDATA")
local CACHE_DIR = CACHE_ROOT and (CACHE_ROOT .. "\\Drop Viewer") or nil
local RECORD_STRIDE = 0x2E68
local RECORD_ITEM = 0x2D30

local function customProperty(info)
    local ok, err = pcall(RegisterCustomProperty, info)
    if not ok then
        log("custom " .. tostring(info.Name) .. " " .. tostring(err))
    end
end

customProperty({
    Name = "DropRecordIndex",
    Type = PropertyTypes.IntProperty,
    BelongsToClass = "/Script/Refine.AppCharacterBase",
    OffsetInternal = 0x7A0,
})
customProperty({
    Name = "DropOwnerGate",
    Type = PropertyTypes.IntProperty,
    BelongsToClass = "/Script/Refine.AppCharacterBase",
    OffsetInternal = 0x7A4,
})
customProperty({
    Name = "DropRecordData",
    Type = PropertyTypes.Int64Property,
    BelongsToClass = "/Script/Refine.AlgoManager",
    OffsetInternal = 0x78,
})
customProperty({
    Name = "DropRecordCount",
    Type = PropertyTypes.IntProperty,
    BelongsToClass = "/Script/Refine.AlgoManager",
    OffsetInternal = 0x80,
})

local function asInt(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        return tonumber(value)
    end
    return nil
end

local function findInstance(className, countField)
    local chosen = nil
    local all = FindAllOf(className) or {}
    for _, obj in ipairs(all) do
        if isLive(obj) then
            local name = safe(function() return obj:GetFullName() end, "")
            if not string.find(name, "Default__", 1, true) then
                chosen = chosen or obj
                local count = asInt(safe(function() return obj[countField] end, nil))
                if count and count > 0 then
                    return obj
                end
            end
        end
    end
    return chosen or FindFirstOf(className)
end

local ITEM_LABEL = {
    [0] = "HP +50",
    [1] = "HP +100",
    [2] = "HP +200",
    [3] = "HP Max",
    [4] = "Arrows +5",
    [5] = "Arrows +10",
    [6] = "Arrows +15",
    [7] = "Arrows +20",
    [8] = "Attack +1",
    [9] = "Attack +2",
    [10] = "Attack +4",
    [11] = "Attack +8",
    [12] = "Defense +1",
    [13] = "Defense +2",
    [14] = "Defense +4",
    [15] = "Defense +8",
    [16] = "Life +10",
    [17] = "Musou Max",
    [18] = "HP+SP",
    [19] = "Attack x2",
    [20] = "Defense x2",
    [21] = "Special",
    [22] = "Weapon",
    [23] = "Musou +10",
    [24] = "Item",
    [25] = "Manual",
}

local function lowByte(raw)
    local n = tonumber(raw)
    if not n then
        return nil
    end
    if n < 0 then
        n = n + 4294967296
    end
    return n % 256
end

local function itemLabel(raw)
    local low = lowByte(raw)
    if low == nil or low == 255 then
        return nil
    end
    return ITEM_LABEL[low] or string.format("item %d", low)
end

local function comboHint(raw)
    local low = lowByte(raw)
    -- 255 is a blank drop. It can become HP or arrows at combo 16, but that
    -- note is not shown.
    if low == nil or low >= 16 then
        return nil
    end
    local variant = low % 4
    if variant >= 3 then
        return nil
    end
    return string.format("%d+", (variant + 1) * 8)
end

local dropCache = nil
local launchKey = nil
local launchClock = 0
local cacheLogged = false
local dirReady = false

local function numText(n)
    return string.format("%.0f", n)
end

local function cachePaths(data, count)
    local stem = numText(data) .. "_" .. tostring(count)
    return CACHE_DIR .. "\\request_" .. stem .. ".txt", CACHE_DIR .. "\\result_" .. stem .. ".txt"
end

local function readText(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local text = file:read("*a") or ""
    file:close()
    return text
end

local function parseResult(text, data, count)
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            lines[#lines + 1] = trimmed
        end
    end
    if lines[1] ~= "ok" then
        return nil, lines[2] or "err"
    end
    if tonumber(lines[2]) ~= data or tonumber(lines[3]) ~= count then
        return nil, "mismatch"
    end
    if #lines < 3 + count then
        return nil, "short"
    end
    local items = {}
    for i = 0, count - 1 do
        items[i] = tonumber(lines[4 + i])
    end
    return { data = data, count = count, items = items }
end

local readerStart = nil

local function probeDir()
    local probe = io.open(CACHE_DIR .. "\\probe.txt", "w")
    if not probe then
        return false
    end
    probe:close()
    os.remove(CACHE_DIR .. "\\probe.txt")
    return true
end

local function bindReader()
    if readerStart ~= nil then
        return readerStart and true or false
    end
    if not CACHE_DIR then
        readerStart = false
        log("LOCALAPPDATA is missing; drop reader disabled")
        return false
    end
    local prepare, prepareErr = package.loadlib(READER_DLL, "UnitDropsPrepare")
    local start, startErr = package.loadlib(READER_DLL, "UnitDropsStart")
    if not prepare or not start then
        readerStart = false
        log("drop reader " .. tostring(startErr or prepareErr) .. " dll=" .. READER_DLL)
        return false
    end
    local ok, err = pcall(prepare)
    if not ok then
        readerStart = false
        log("drop reader prepare " .. tostring(err))
        return false
    end
    if not probeDir() then
        readerStart = false
        log("drop reader cannot write " .. CACHE_DIR)
        return false
    end
    readerStart = start
    dirReady = true
    return true
end

local function ensureDir()
    if dirReady then
        return true
    end
    return bindReader()
end

local function writeRequest(data, count, path)
    local file = io.open(path, "w")
    if not file then
        return false
    end
    file:write(numText(data) .. "\n" .. tostring(count) .. "\n")
    for i = 0, count - 1 do
        file:write(numText(data + i * RECORD_STRIDE + RECORD_ITEM) .. "\n")
    end
    file:close()
    return true
end

local function writeJob(request, result)
    local file = io.open(CACHE_DIR .. "\\job.txt", "w")
    if not file then
        return false
    end
    file:write(request .. "\n" .. result .. "\n")
    file:close()
    return true
end

local function launchReader(request, result)
    if type(readerStart) ~= "function" or not writeJob(request, result) then
        return false
    end
    local ok, err = pcall(readerStart)
    if not ok then
        log("drop reader start " .. tostring(err))
        return false
    end
    return true
end

bindReader()

local function ensureCache()
    local algo = findInstance("AlgoManager", "DropRecordCount")
    local data = isLive(algo) and asInt(safe(function() return algo.DropRecordData end, nil)) or nil
    local count = isLive(algo) and asInt(safe(function() return algo.DropRecordCount end, nil)) or nil
    if not data or not count or count <= 0 or count > 512 then
        return nil, data, count
    end
    if dropCache and dropCache.data == data and dropCache.count == count then
        return dropCache, data, count
    end
    if not CACHE_DIR then
        return nil, data, count
    end
    local request, result = cachePaths(data, count)
    local key = numText(data) .. ":" .. tostring(count)
    local text = readText(result)
    if text then
        local parsed, err = parseResult(text, data, count)
        if parsed then
            dropCache = parsed
            launchKey = nil
            cacheLogged = false
            log("drop cache ready count=" .. tostring(count))
            return dropCache, data, count
        end
        os.remove(result)
        if not cacheLogged then
            cacheLogged = true
            log("drop cache " .. tostring(err))
        end
    end
    if launchKey == key and os.clock() - launchClock < 5 then
        return nil, data, count
    end
    launchKey = key
    launchClock = os.clock()
    if not ensureDir() or not writeRequest(data, count, request) or not launchReader(request, result) then
        if not cacheLogged then
            cacheLogged = true
            log("drop reader launch failed")
        end
    end
    return nil, data, count
end

local PANE_MARK = " | "
local COMBO_MARK = " · "
local setTextFailed = false
local panes = {}
local comboLineSize = nil
local comboMissLogged = false
local portraitMissLogged = false
local clearedStars = {}
local starAttempts = {}
local restoredPasses = {}
local starLogged = false

local function setWidgetText(widget, value)
    if not isLive(widget) then
        return
    end
    local ok, err = pcall(function()
        if FText then
            widget:SetText(FText(value))
            return
        end
        local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        widget:SetText(lib:Conv_StringToText(value))
    end)
    if not ok and not setTextFailed then
        setTextFailed = true
        log("setText " .. tostring(err))
    end
end

local function sameObject(a, b)
    if not isLive(a) or not isLive(b) then
        return false
    end
    local aa = safe(function() return a:GetAddress() end, nil)
    local bb = safe(function() return b:GetAddress() end, nil)
    if aa and bb then
        return aa == bb
    end
    return a == b
end

local function isPaneWidget(widget)
    for _, state in pairs(panes) do
        if sameObject(widget, state.drop) or sameObject(widget, state.hint) then
            return true
        end
    end
    return false
end

local function styleComboText(gauge, widget, state)
    if state.fontReady then
        return
    end
    local name = gauge.text_enemy_name
    if not isLive(name) then
        return
    end
    local ok, err = pcall(function()
        local font = name.Font
        local size = font and tonumber(font.Size) or nil
        if size and size > 8 then
            comboLineSize = math.floor(size * 0.55)
            font.Size = comboLineSize
        end
        widget:SetFont(font)
        widget:SetColorAndOpacity(name.ColorAndOpacity)
        if size then
            font.Size = size
            name:SetFont(font)
        end
    end)
    if ok then
        state.fontReady = true
        return
    end
    if not setTextFailed then
        setTextFailed = true
        log("combo font " .. tostring(err))
    end
end

local function styleHintText(gauge, widget, state)
    if state.hintReady then
        return
    end
    local name = gauge.text_enemy_name
    local force = gauge.text_enemy_force
    if not isLive(name) or not isLive(force) then
        return
    end
    local ok, err = pcall(function()
        local nameSize = tonumber(safe(function() return name.Font.Size end, nil))
        local font = force.Font
        local forceSize = font and tonumber(font.Size) or nil
        if nameSize and nameSize > 8 and font then
            font.Size = math.floor(nameSize * 0.55)
        end
        widget:SetFont(font)
        widget:SetColorAndOpacity(force.ColorAndOpacity)
        if forceSize and font then
            font.Size = forceSize
            force:SetFont(font)
        end
    end)
    if ok then
        state.hintReady = true
        return
    end
    if not setTextFailed then
        setTextFailed = true
        log("combo hint font " .. tostring(err))
    end
end

local function widgetClass(widget)
    local full = safe(function() return widget:GetFullName() end, "") or ""
    if full ~= "" then
        return full
    end
    return safe(function() return widget:GetClass():GetName() end, "") or ""
end

local function widgetKey(widget)
    local addr = safe(function() return widget:GetAddress() end, nil)
    if addr then
        return string.format("%.0f", addr)
    end
    return tostring(widget)
end

local function paneState(gauge)
    local key = widgetKey(gauge)
    local state = panes[key]
    if not state then
        state = {}
        panes[key] = state
    end
    return state
end

local function asWidget(value)
    local inner = safe(function()
        if value and value.get then
            return value:get()
        end
        return nil
    end, nil)
    if isLive(inner) then
        return inner
    end
    if isLive(value) then
        return value
    end
    return nil
end

local function eachChild(box, fn)
    local children = safe(function() return box:GetAllChildren() end, nil)
    if children then
        pcall(function()
            children:ForEach(function(_, child)
                local widget = asWidget(child)
                if widget then
                    fn(widget)
                end
            end)
        end)
    end
    local count = tonumber(safe(function() return box:GetChildrenCount() end, 0)) or 0
    for index = count, 0, -1 do
        local widget = asWidget(safe(function() return box:GetChildAt(index) end, nil))
        if widget then
            fn(widget)
        end
    end
end

-- Star-row notes were an earlier copy of the combo hint. The box is rebuilt by
-- SetMoralNum, so keep removing TextBlocks until a pass finds none.
local function clearStarNotes(gauge)
    local morale = isLive(gauge) and gauge.BP_parts_enemy_morale or nil
    local box = isLive(morale) and morale.box_star or nil
    if not isLive(box) then
        return
    end
    local key = widgetKey(box)
    if clearedStars[key] then
        return
    end
    local doomed = {}
    local seen = {}
    eachChild(box, function(child)
        local keyChild = widgetKey(child)
        if seen[keyChild] or isPaneWidget(child) then
            return
        end
        seen[keyChild] = true
        if widgetClass(child):find("TextBlock", 1, true) then
            doomed[#doomed + 1] = child
        end
    end)
    for _, child in ipairs(doomed) do
        pcall(function() child:SetVisibility(1) end)
        pcall(function() box:RemoveChild(child) end)
    end
    local attempts = (starAttempts[key] or 0) + 1
    starAttempts[key] = attempts
    if #doomed == 0 or attempts >= 8 then
        clearedStars[key] = true
    end
    if #doomed > 0 and not starLogged then
        starLogged = true
        log("removed star notes " .. tostring(#doomed))
    end
end

local function vec2(value)
    if type(value) ~= "userdata" and type(value) ~= "table" then
        return 0, 0
    end
    local x = tonumber(value.X) or tonumber(value.x)
    local y = tonumber(value.Y) or tonumber(value.y)
    if x and y then
        return x, y
    end
    local text = safe(function()
        if value.ToString then
            return value:ToString()
        end
        return tostring(value)
    end, "") or ""
    local xs, ys = text:match("X=([%-%d%.]+)%s*Y=([%-%d%.]+)")
    if not xs then
        xs, ys = text:match("x=([%-%d%.]+)%s*y=([%-%d%.]+)")
    end
    return tonumber(xs) or 0, tonumber(ys) or 0
end

local function parentOf(widget)
    if not isLive(widget) then
        return nil
    end
    local direct = asWidget(safe(function() return widget:GetParent() end, nil))
    if direct then
        return direct
    end
    local slot = safe(function() return widget.Slot end, nil)
    if not slot then
        return nil
    end
    return asWidget(safe(function() return slot.Parent end, nil))
end

-- The portrait slot is fixed. The note is centered on it, under or above,
-- so a longer officer name does not move the drop.
local function portraitCanvas(marker)
    local current = marker
    for _ = 1, 12 do
        local parent = parentOf(current)
        if not isLive(parent) then
            return nil, nil
        end
        if widgetClass(parent):find("CanvasPanel", 1, true) then
            return parent, current
        end
        current = parent
    end
    return nil, nil
end

local function attachPortrait(widget, marker, above, nudge, extraY)
    if not isLive(widget) or not isLive(marker) then
        return false
    end
    local canvas, anchor = portraitCanvas(marker)
    if not isLive(canvas) or not isLive(anchor) then
        if not portraitMissLogged then
            portraitMissLogged = true
            log("portrait canvas missing")
        end
        return false
    end
    if not sameObject(parentOf(widget), canvas) then
        local old = parentOf(widget)
        if isLive(old) then
            pcall(function() old:RemoveChild(widget) end)
        end
        local added = safe(function() return canvas:AddChildToCanvas(widget) end, nil)
        if not isLive(added) then
            return false
        end
    end
    local slot = widget.Slot
    local anchorSlot = anchor.Slot
    if not isLive(slot) or not isLive(anchorSlot) then
        return false
    end
    local placed = false
    pcall(function()
        local posX, posY = vec2(anchorSlot:GetPosition())
        local sizeX, sizeY = vec2(anchorSlot:GetSize())
        local alignX, alignY = vec2(safe(function() return anchorSlot:GetAlignment() end, nil))
        if sizeX < 8 or sizeY < 8 then
            return
        end
        local left = posX - alignX * sizeX
        local top = posY - alignY * sizeY
        slot:SetAutoSize(true)
        slot:SetAnchors(anchorSlot:GetAnchors())
        local shift = tonumber(nudge) or 0
        local extra = tonumber(extraY) or 0
        slot:SetAlignment({ X = 0.5, Y = above and 1 or 0 })
        slot:SetPosition({
            X = left + sizeX * 0.5,
            Y = (above and (top - 4 + shift) or (top + sizeY + 4 - shift)) + extra,
        })
        slot:SetZOrder((tonumber(safe(function() return anchorSlot:GetZOrder() end, 0)) or 0) + 5)
        placed = true
    end)
    return placed
end

-- Fallback when the portrait and the star row are both missing.
local function attachUnderName(widget, name, extraY, xShift)
    if not isLive(widget) or not isLive(name) then
        return false
    end
    local canvas, anchor = portraitCanvas(name)
    if not isLive(canvas) or not isLive(anchor) then
        return false
    end
    if not sameObject(parentOf(widget), canvas) then
        local old = parentOf(widget)
        if isLive(old) then
            pcall(function() old:RemoveChild(widget) end)
        end
        local added = safe(function() return canvas:AddChildToCanvas(widget) end, nil)
        if not isLive(added) then
            return false
        end
    end
    local slot = widget.Slot
    local anchorSlot = anchor.Slot
    if not isLive(slot) or not isLive(anchorSlot) then
        return false
    end
    local placed = false
    pcall(function()
        local posX, posY = vec2(anchorSlot:GetPosition())
        local sizeX, sizeY = vec2(anchorSlot:GetSize())
        local alignX, alignY = vec2(safe(function() return anchorSlot:GetAlignment() end, nil))
        local fontSize = tonumber(safe(function() return name.Font.Size end, nil))
        if sizeY < 8 then
            sizeY = fontSize and fontSize > 8 and fontSize or 22
        end
        if sizeX < 8 then
            sizeX = 8
        end
        local left = posX - alignX * sizeX
        local top = posY - alignY * sizeY
        local extra = tonumber(extraY) or 0
        local slide = tonumber(xShift) or 0
        slot:SetAutoSize(true)
        slot:SetAnchors(anchorSlot:GetAnchors())
        slot:SetAlignment({ X = 0.0, Y = 0.0 })
        slot:SetPosition({
            X = left + slide,
            Y = top + sizeY + 2 + extra,
        })
        slot:SetZOrder((tonumber(safe(function() return anchorSlot:GetZOrder() end, 0)) or 0) + 5)
        placed = true
    end)
    return placed
end

-- The star box's own canvas is often an empty inner slot. Keep walking
-- until a canvas slot has a real size, and prefer the one that shares the
-- officer name's canvas and sits at or below that name.
local function canvasRect(marker, stopAt)
    local found = {}
    local current = marker
    for _ = 1, 12 do
        if stopAt and sameObject(current, stopAt) then
            break
        end
        local parent = parentOf(current)
        if not isLive(parent) then
            break
        end
        if widgetClass(parent):find("CanvasPanel", 1, true) and isLive(current.Slot) then
            local slot = current.Slot
            local posX, posY = vec2(safe(function() return slot:GetPosition() end, nil))
            local sizeX, sizeY = vec2(safe(function() return slot:GetSize() end, nil))
            local h = sizeY
            if h >= 8 or math.abs(posX) > 4 or math.abs(posY) > 4 then
                local alignX, alignY = vec2(safe(function() return slot:GetAlignment() end, nil))
                local w = sizeX >= 8 and sizeX or 8
                local drawH = h >= 8 and h or 16
                local left = posX - alignX * w
                local top = posY - alignY * drawH
                found[#found + 1] = {
                    canvas = parent,
                    slot = slot,
                    left = left,
                    bottom = top + drawH,
                }
            end
        end
        current = parent
    end
    return found
end

local function pickStarRect(gauge)
    local morale = isLive(gauge) and asWidget(safe(function() return gauge.BP_parts_enemy_morale end, nil)) or nil
    if not isLive(morale) then
        return nil
    end
    local box = asWidget(safe(function() return morale.box_star end, nil))
    local rects = canvasRect(isLive(box) and box or morale, gauge)
    if #rects == 0 and isLive(box) then
        rects = canvasRect(morale, gauge)
    end
    if #rects == 0 then
        return nil
    end
    local name = isLive(gauge) and gauge.text_enemy_name or nil
    local nameRects = isLive(name) and canvasRect(name, gauge) or {}
    local nameRect = nameRects[1]
    if nameRect then
        for _, rect in ipairs(rects) do
            if sameObject(rect.canvas, nameRect.canvas) and rect.bottom >= nameRect.bottom - 2 then
                return rect
            end
        end
    end
    return rects[#rects]
end

local starSlotLogged = false
local starPlaceLogged = false

local function attachUnderStars(gauge, widget, extraY, xShift)
    if not isLive(widget) then
        return false
    end
    local rect = pickStarRect(gauge)
    if not rect then
        if not starSlotLogged then
            starSlotLogged = true
            log("star slot missing")
        end
        return false
    end
    local canvas = rect.canvas
    if not sameObject(parentOf(widget), canvas) then
        local old = parentOf(widget)
        if isLive(old) then
            pcall(function() old:RemoveChild(widget) end)
        end
        local added = safe(function() return canvas:AddChildToCanvas(widget) end, nil)
        if not isLive(added) then
            return false
        end
    end
    local slot = widget.Slot
    if not isLive(slot) then
        return false
    end
    local placed = false
    pcall(function()
        local extra = tonumber(extraY) or 0
        local slide = tonumber(xShift) or 0
        slot:SetAutoSize(true)
        slot:SetAnchors(rect.slot:GetAnchors())
        slot:SetAlignment({ X = 0.0, Y = 0.0 })
        slot:SetPosition({
            X = rect.left + slide,
            Y = rect.bottom + 4 + extra,
        })
        slot:SetZOrder((tonumber(safe(function() return rect.slot:GetZOrder() end, 0)) or 0) + 5)
        placed = true
    end)
    if placed and not starPlaceLogged then
        starPlaceLogged = true
        log(string.format("drop under morale stars y %.0f", rect.bottom))
    end
    return placed
end

local function gaugePortrait(gauge)
    if isLive(gauge.gauge_enemy_face_frame) then
        return gauge.gauge_enemy_face_frame
    end
    if isLive(gauge.mask_face) then
        return gauge.mask_face
    end
    if isLive(gauge.still_face) then
        return gauge.still_face
    end
    return nil
end

local function portraitUsable(gauge)
    local portrait = gaugePortrait(gauge)
    if not isLive(portrait) then
        return nil
    end
    local _, anchor = portraitCanvas(portrait)
    local anchorSlot = isLive(anchor) and anchor.Slot or nil
    if not isLive(anchorSlot) then
        return nil
    end
    local sizeX, sizeY = vec2(safe(function() return anchorSlot:GetSize() end, nil))
    if sizeX >= 8 and sizeY >= 8 then
        return portrait
    end
    return nil
end

local function splitGauge(gauge)
    return string.find(widgetClass(gauge), "gauge_enemy_multi", 1, true) ~= nil
end

local function splitDropX(gauge)
    if splitGauge(gauge) then
        return -12
    end
    return 0
end

local function placeComboText(gauge, widget)
    local state = paneState(gauge)
    if not splitGauge(gauge) then
        local portrait = portraitUsable(gauge)
        if isLive(portrait) and attachPortrait(widget, portrait, false, 8) then
            return true
        end
        if isLive(gaugePortrait(gauge)) then
            return false
        end
    end
    local morale = isLive(gauge) and asWidget(safe(function() return gauge.BP_parts_enemy_morale end, nil)) or nil
    if isLive(morale) then
        if attachUnderStars(gauge, widget, 0, splitDropX(gauge)) then
            if not comboMissLogged then
                comboMissLogged = true
                log("drop under morale stars")
            end
            return true
        end
        state.starTries = (state.starTries or 0) + 1
        if state.starTries < 10 then
            return false
        end
    end
    local name = isLive(gauge) and gauge.text_enemy_name or nil
    if isLive(name) and attachUnderName(widget, name, 0, splitDropX(gauge)) then
        if not comboMissLogged then
            comboMissLogged = true
            log("drop under officer name")
        end
        return true
    end
    if not comboMissLogged then
        comboMissLogged = true
        log("combo portrait missing")
    end
    return false
end

-- Same portrait slot as the drop, one combo-font below it, plus 8 pixels
-- so the gold line clears the drop. Nothing is measured, and the combo is not
-- parented until that step is known, so it cannot sit on the drop.
local function lineStep(gauge)
    if comboLineSize and comboLineSize >= 4 then
        return comboLineSize
    end
    local name = isLive(gauge) and gauge.text_enemy_name or nil
    local size = tonumber(safe(function()
        if not isLive(name) then
            return nil
        end
        return name.Font.Size
    end, nil))
    if size and size > 8 then
        comboLineSize = math.floor(size * 0.55)
    end
    if comboLineSize and comboLineSize >= 4 then
        return comboLineSize
    end
    return nil
end

local function placeComboHint(gauge, widget)
    local step = lineStep(gauge)
    if not step or not isLive(widget) then
        return false
    end
    if not splitGauge(gauge) then
        local portrait = portraitUsable(gauge)
        if isLive(portrait) then
            return attachPortrait(widget, portrait, false, 8, step + 8)
        end
        if isLive(gaugePortrait(gauge)) then
            return false
        end
    end
    local morale = isLive(gauge) and asWidget(safe(function() return gauge.BP_parts_enemy_morale end, nil)) or nil
    if isLive(morale) then
        if attachUnderStars(gauge, widget, step + 8, splitDropX(gauge)) then
            return true
        end
        local state = paneState(gauge)
        if (state.starTries or 0) < 10 then
            return false
        end
    end
    local name = isLive(gauge) and gauge.text_enemy_name or nil
    if isLive(name) then
        return attachUnderName(widget, name, step + 8, splitDropX(gauge))
    end
    return false
end

local function ensureComboText(gauge)
    clearStarNotes(gauge)
    local state = paneState(gauge)
    if state.placed and isLive(state.drop) and isLive(parentOf(state.drop)) then
        if not state.fontReady then
            styleComboText(gauge, state.drop, state)
        end
        -- The first frames often have no star size. Keep moving the slot
        -- so a name placement does not stay above the stars.
        placeComboText(gauge, state.drop)
        return state.drop
    end
    state.placed = false
    if not isLive(state.drop) then
        local class = StaticFindObject("/Script/UMG.TextBlock")
        local widget = class and StaticConstructObject(class, gauge) or nil
        if not isLive(widget) then
            return nil
        end
        state.drop = widget
        state.fontReady = false
    end
    if placeComboText(gauge, state.drop) then
        state.placed = true
        styleComboText(gauge, state.drop, state)
    end
    return state.drop
end

local function ensureComboHint(gauge)
    local state = paneState(gauge)
    if state.hintPlaced and isLive(state.hint) and isLive(parentOf(state.hint)) then
        if not state.hintReady then
            styleHintText(gauge, state.hint, state)
        end
        placeComboHint(gauge, state.hint)
        return state.hint
    end
    state.hintPlaced = false
    if not isLive(state.hint) then
        local class = StaticFindObject("/Script/UMG.TextBlock")
        local widget = class and StaticConstructObject(class, gauge) or nil
        if not isLive(widget) then
            return nil
        end
        state.hint = widget
        state.hintReady = false
    end
    if placeComboHint(gauge, state.hint) then
        state.hintPlaced = true
        styleHintText(gauge, state.hint, state)
    end
    return state.hint
end

-- The first combo note scaled text_enemy_force to 0.75 and appended " · 8+".
-- That text sits under InvalidationBox_0, so the scaled suffix stays painted
-- until the box cache is thrown out. The live note is under the portrait.
local function stripForceCombo(current)
    if type(current) ~= "string" then
        return current
    end
    local cut = current:find(COMBO_MARK, 1, true)
    if cut then
        return current:sub(1, cut - 1)
    end
    local trimmed = current:gsub("%s+%d+%+%s+HP/Arrows%s*$", "")
    trimmed = trimmed:gsub("%s*%(%d+%+[^)]*%)%s*$", "")
    trimmed = trimmed:gsub("%s+%d+%+%s+combo%s*$", "")
    trimmed = trimmed:gsub("%s+%d+%+%s*$", "")
    return trimmed
end

local function isOurNote(text)
    if type(text) ~= "string" or text == "" or text:find("<", 1, true) == 1 then
        return false
    end
    if text:find(COMBO_MARK, 1, true) or text:find("|", 1, true) then
        return true
    end
    if text:match("^%s*%d+%+[%^↑]?%s*$") or text:match("%d%+%s+HP/Arrows") or text:match("%d%+%s+combo") or text:match("^item %d+$") then
        return true
    end
    for _, label in pairs(ITEM_LABEL) do
        if text == label or text:sub(1, #label + #COMBO_MARK) == label .. COMBO_MARK then
            return true
        end
    end
    return false
end

local stalePasses = {}
local staleLogged = false

local function removeStaleNotes(gauge)
    local key = widgetKey(gauge)
    if (stalePasses[key] or 0) >= 12 then
        return
    end
    stalePasses[key] = (stalePasses[key] or 0) + 1
    local name = gauge.text_enemy_name
    local force = gauge.text_enemy_force
    local removed = 0
    local seen = {}
    local function consider(widget)
        if not isLive(widget) or isPaneWidget(widget) or sameObject(widget, name) or sameObject(widget, force) then
            return
        end
        if not widgetClass(widget):find("TextBlock", 1, true) then
            return
        end
        if not isOurNote(textOf(widget)) then
            return
        end
        pcall(function() widget:SetVisibility(1) end)
        setWidgetText(widget, "")
        local parent = parentOf(widget)
        if isLive(parent) then
            pcall(function() parent:RemoveChild(widget) end)
        end
        removed = removed + 1
    end
    local function walk(widget, depth)
        local current = asWidget(widget)
        if not current or depth > 12 then
            return
        end
        local id = widgetKey(current)
        if seen[id] then
            return
        end
        seen[id] = true
        consider(current)
        local count = tonumber(safe(function() return current:GetChildrenCount() end, 0)) or 0
        for index = 0, count - 1 do
            walk(safe(function() return current:GetChildAt(index) end, nil), depth + 1)
        end
    end
    local root = safe(function() return gauge.WidgetTree.RootWidget end, nil)
    walk(root, 0)
    local current = name
    for _ = 1, 8 do
        local parent = parentOf(current)
        if not isLive(parent) then
            break
        end
        walk(parent, 0)
        current = parent
    end
    if removed > 0 and not staleLogged then
        staleLogged = true
        log("removed extra notes " .. tostring(removed))
    end
end

local nameReveals = 0

local function cleanOfficerName(widget)
    if not isLive(widget) then
        return false
    end
    local current = textOf(widget)
    if type(current) ~= "string" then
        return false
    end
    local cut = current:find(PANE_MARK, 1, true)
    if not cut then
        cut = current:find("|", 1, true)
    end
    if not cut then
        return false
    end
    local base = current:sub(1, cut - 1):gsub("%s+$", "")
    if base ~= current then
        setWidgetText(widget, base)
    end
    return true
end

local function revealName(gauge, stripped)
    local name = gauge.text_enemy_name
    if not isLive(name) then
        return
    end
    if not stripped and nameReveals >= 24 then
        return
    end
    pcall(function()
        name:InvalidateLayoutAndVolatility()
        name:ForceVolatile(true)
    end)
    local box = gauge.InvalidationBox_0
    if isLive(box) then
        pcall(function() box:InvalidateCache() end)
    end
    if not stripped then
        nameReveals = nameReveals + 1
    end
end

local function gaugeShown(gauge)
    local vis = tonumber(safe(function() return gauge:GetVisibility() end, nil))
    if vis == nil then
        return true
    end
    return vis ~= 1 and vis ~= 2
end

local function settleForce(gauge)
    if not isLive(gauge) then
        return
    end
    clearStarNotes(gauge)
    removeStaleNotes(gauge)
    local key = widgetKey(gauge)
    if (restoredPasses[key] or 0) >= 3 then
        return
    end
    local force = gauge.text_enemy_force
    if not isLive(force) then
        return
    end
    local before = textOf(force)
    local cleaned = stripForceCombo(before)
    pcall(function()
        force:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        force:SetRenderScale({ X = 1, Y = 1 })
    end)
    if cleaned ~= before then
        setWidgetText(force, cleaned)
    end
    -- Count only while the gauge is on screen. A hidden widget can burn the
    -- retries before its slate exists, and the invalidation box would keep
    -- the scaled " · 8+" frame.
    if not gaugeShown(gauge) then
        return
    end
    pcall(function()
        force:InvalidateLayoutAndVolatility()
        force:ForceVolatile(true)
    end)
    local box = gauge.InvalidationBox_0
    if isLive(box) then
        pcall(function() box:InvalidateCache() end)
    end
    local passes = restoredPasses[key] or 0
    restoredPasses[key] = passes + 1
end

local function restoreAllGauges()
    for _, className in ipairs({ "BP_parts_gauge_enemy_C", "BP_parts_gauge_enemy_multi_C" }) do
        local all = FindAllOf(className) or {}
        for _, gauge in ipairs(all) do
            settleForce(gauge)
        end
    end
end

local paneWatch = { key = nil, side = nil, follow = 0 }

local function paintCombo(gauge, combo, hintBox)
    pcall(function()
        combo:InvalidateLayoutAndVolatility()
        combo:ForceVolatile(true)
        if isLive(hintBox) then
            hintBox:InvalidateLayoutAndVolatility()
            hintBox:ForceVolatile(true)
        end
    end)
    local box = isLive(gauge) and gauge.InvalidationBox_0 or nil
    if isLive(box) then
        pcall(function() box:InvalidateCache() end)
    end
end

local function findHud()
    local manager = FindFirstOf("BP_Battle_HUD_Manager_C")
    if isLive(manager) and isLive(manager.Battle2DHUD) then
        return manager.Battle2DHUD
    end
    return FindFirstOf("BP_2d_hud_C")
end

local function applyPane(gauge, label, hint, actorKey)
    if not isLive(gauge) then
        return
    end
    settleForce(gauge)
    local name = gauge.text_enemy_name
    local stripped = cleanOfficerName(name)
    revealName(gauge, stripped)
    local combo = ensureComboText(gauge)
    if not isLive(combo) then
        return
    end
    local hintBox = ensureComboHint(gauge)
    local dropText = label
    local gold = hint
    local side = dropText and (gold and (dropText .. gold) or dropText) or nil
    local key = tostring(actorKey) .. "|" .. tostring(side)
    if dropText then
        if textOf(combo) ~= dropText then
            setWidgetText(combo, dropText)
        end
        pcall(function()
            combo:SetVisibility(4)
            combo:SetRenderOpacity(1)
        end)
    else
        if textOf(combo) ~= "" then
            setWidgetText(combo, "")
        end
        pcall(function() combo:SetVisibility(1) end)
    end
    if isLive(hintBox) then
        if gold then
            if textOf(hintBox) ~= gold then
                setWidgetText(hintBox, gold)
            end
            pcall(function()
                hintBox:SetVisibility(4)
                hintBox:SetRenderOpacity(1)
            end)
        else
            if textOf(hintBox) ~= "" then
                setWidgetText(hintBox, "")
            end
            pcall(function() hintBox:SetVisibility(1) end)
        end
    end
    if paneWatch.key ~= key or side ~= paneWatch.side then
        paneWatch.key = key
        paneWatch.side = side
        if paneWatch.follow < 3 then
            paneWatch.follow = 3
        end
    end
    if paneWatch.follow <= 0 or not isLive(parentOf(combo)) or not gaugeShown(gauge) then
        return
    end
    paintCombo(gauge, combo, hintBox)
    paneWatch.follow = paneWatch.follow - 1
end

local function emittingActor(actor)
    if not isLive(actor) then
        return nil
    end
    if asInt(actor.DropOwnerGate) == -1 then
        return actor
    end
    local leader = safe(function() return actor:GetLeader() end, nil)
    if isLive(leader) and asInt(leader.DropOwnerGate) == -1 then
        return leader
    end
    return nil
end

local function playerIdOf(actor)
    local value = safe(function() return actor.m_ePlayerID end, nil)
    if type(value) == "number" then
        return math.floor(value)
    end
    local inner = safe(function()
        if value and value.get then
            return value:get()
        end
        return nil
    end, nil)
    if type(inner) == "number" then
        return math.floor(inner)
    end
    local text = safe(function()
        if value and value.ToString then
            return value:ToString()
        end
        return tostring(value)
    end, "") or ""
    if string.find(text, "PLAYER2", 1, true) then
        return 1
    end
    if string.find(text, "PLAYER1", 1, true) then
        return 0
    end
    return nil
end

local function localPlayers()
    local byId = {}
    local all = FindAllOf("AppCharacterPlayer") or {}
    for _, actor in ipairs(all) do
        if isLive(actor) then
            local name = safe(function() return actor:GetFullName() end, "") or ""
            if not string.find(name, "Default__", 1, true) then
                local localOk = safe(function() return actor:IsLocallyControlled() end, false) == true
                if localOk then
                    local id = playerIdOf(actor)
                    if id == 0 or id == 1 then
                        byId[id] = actor
                    end
                end
            end
        end
    end
    return byId
end

local function lockEmitter(actor)
    if not isLive(actor) then
        return nil
    end
    local camera = safe(function() return actor.ATPCCamera end, nil)
    if not isLive(camera) then
        return nil
    end
    local lockObj = safe(function() return camera:GetCameraLockOnTargetObject() end, nil)
    local lockOn = isLive(lockObj) and safe(function() return lockObj:GetTargetActor() end, nil) or nil
    if isLive(lockOn) and asInt(lockOn.DropOwnerGate) == -1 then
        return lockOn
    end
    return nil
end

local function currentEmitter()
    local players = localPlayers()
    local player = players[0]
    if not isLive(player) then
        player = FindFirstOf("AppCharacterPlayer")
    end
    if isLive(player) and isLive(player.ATPCCamera) then
        local lockObj = safe(function() return player.ATPCCamera:GetCameraLockOnTargetObject() end, nil)
        local lockOn = isLive(lockObj) and safe(function() return lockObj:GetTargetActor() end, nil) or nil
        if isLive(lockOn) and asInt(lockOn.DropOwnerGate) == -1 then
            return lockOn
        end
    end
    local hudActor = FindFirstOf("BattleHUDManager") or FindFirstOf("BP_Battle_HUD_Manager_C")
    local chars = FindFirstOf("CharacterManager")
    local gaugeUnit = isLive(hudActor) and safe(function()
        return hudActor:GetEnemyGaugeUnit(chars)
    end, nil) or nil
    return emittingActor(gaugeUnit)
end

local splitDropLogged = false

local function enemyRows()
    local all = FindAllOf("BP_2d_hud_multi_C") or {}
    for _, hud in ipairs(all) do
        if isLive(hud) then
            local name = safe(function() return hud:GetFullName() end, "") or ""
            if not string.find(name, "Default__", 1, true) and gaugeShown(hud) then
                local up = asWidget(safe(function() return hud.BP_parts_2d_hud_split_screen_up end, nil))
                local down = asWidget(safe(function() return hud.BP_parts_2d_hud_split_screen_down end, nil))
                local upGauge = isLive(up) and asWidget(safe(function() return up.BP_parts_gauge_enemy_multi end, nil)) or nil
                local downGauge = isLive(down) and asWidget(safe(function() return down.BP_parts_gauge_enemy_multi end, nil)) or nil
                if isLive(upGauge) and isLive(downGauge) and gaugeShown(up) and gaugeShown(down) then
                    if not splitDropLogged then
                        splitDropLogged = true
                        log("split gauges")
                    end
                    return {
                        { id = 0, gauge = upGauge },
                        { id = 1, gauge = downGauge },
                    }
                end
            end
        end
    end
    local hud = findHud()
    local gauge = isLive(hud) and asWidget(hud.BP_parts_gauge_enemy) or nil
    if isLive(gauge) then
        return { { id = 0, gauge = gauge } }
    end
    return {}
end

local function dropFor(actor)
    if not dropCache or not isLive(actor) then
        return nil, nil, ""
    end
    local actorKey = widgetKey(actor)
    local index = asInt(safe(function() return actor.DropRecordIndex end, nil))
    local raw = index and dropCache.items[index] or nil
    if raw == nil then
        return nil, nil, actorKey
    end
    return itemLabel(raw), comboHint(raw), actorKey
end

local function refreshLabel()
    local players = localPlayers()
    for _, row in ipairs(enemyRows()) do
        local actor = lockEmitter(players[row.id])
        if not isLive(actor) and row.id == 0 then
            actor = currentEmitter()
        end
        local label, hint, actorKey = dropFor(actor)
        applyPane(row.gauge, label, hint, actorKey or "")
    end
end

local paneFailed = false
local hooksReady = {}

local function ensureHooks()
    if not hooksReady.gauge then
        local ok, err = pcall(function()
            RegisterHook("/Game/UI/02_battle/BP_parts_gauge_enemy.BP_parts_gauge_enemy_C:Tick", function()
            end, function(self)
                local gauge = safe(function() return self:get() end, nil)
                if isLive(gauge) then
                    local settled, settleErr = pcall(settleForce, gauge)
                    if not settled and not paneFailed then
                        paneFailed = true
                        log("pane " .. tostring(settleErr))
                    end
                end
                local hooked, hookErr = pcall(refreshLabel)
                if not hooked and not paneFailed then
                    paneFailed = true
                    log("pane " .. tostring(hookErr))
                end
            end)
        end)
        if ok then
            hooksReady.gauge = true
        elseif not hooksReady.gaugeLogged and isLive(FindFirstOf("BP_parts_gauge_enemy_C")) then
            hooksReady.gaugeLogged = true
            log("gauge tick hook " .. tostring(err))
        end
    end
end

local restorePasses = 0

local function refreshPane()
    ensureCache()
    -- A few passes clear leftover notes. After that the live gauge is enough.
    if restorePasses < 4 then
        restoreAllGauges()
        restorePasses = restorePasses + 1
    end
    refreshLabel()
    ensureHooks()
end

ensureHooks()

local loopOk, loopErr = pcall(function()
    LoopAsync(400, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(refreshPane)
            if not ok and not paneFailed then
                paneFailed = true
                log("pane " .. tostring(err))
            end
        end)
    end)
end)
if not loopOk then
    log("pane loop " .. tostring(loopErr))
end

if type(readerStart) == "function" then
    log("loaded script=" .. SCRIPT_DIR .. " reader=bound")
else
    log("loaded script=" .. SCRIPT_DIR .. " reader=failed dll=" .. READER_DLL)
end
