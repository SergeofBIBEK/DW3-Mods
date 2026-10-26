-- Drop Viewer
-- Battle gauge: drop name under the officer portrait. A combo note (8+/16+/24+)
-- sits on the next line, in the troop-line color, only when that drop can rise a tier.
-- Pause Unit Info: drop name only, above the portrait. This mod does not change
-- the officer name or unitname_ruby. Orders mods own that upper line.
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
local comboText = nil
local comboHintText = nil
local comboFontReady = false
local comboHintFontReady = false
local comboPlaced = false
local comboMissLogged = false
local portraitMissLogged = false
local infoOwned = {}
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

local function styleComboText(gauge, widget)
    if comboFontReady then
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
            font.Size = math.floor(size * 0.55)
        end
        widget:SetFont(font)
        widget:SetColorAndOpacity(name.ColorAndOpacity)
        if size then
            font.Size = size
            name:SetFont(font)
        end
    end)
    if ok then
        comboFontReady = true
        return
    end
    if not setTextFailed then
        setTextFailed = true
        log("combo font " .. tostring(err))
    end
end

local function styleHintText(gauge, widget)
    if comboHintFontReady then
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
        comboHintFontReady = true
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
        if seen[keyChild] or sameObject(child, comboText) or sameObject(child, comboHintText) then
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

local function attachPortrait(widget, marker, above, nudge)
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
        slot:SetAlignment({ X = 0.5, Y = above and 1 or 0 })
        slot:SetPosition({
            X = left + sizeX * 0.5,
            Y = above and (top - 4 + shift) or (top + sizeY + 4 - shift),
        })
        slot:SetZOrder((tonumber(safe(function() return anchorSlot:GetZOrder() end, 0)) or 0) + 5)
        placed = true
    end)
    return placed
end

local function lineHeight(widget)
    pcall(function() widget:ForceLayoutPrepass() end)
    local _, height = vec2(safe(function() return widget:GetDesiredSize() end, nil))
    if height >= 4 then
        return height
    end
    local font = safe(function() return widget.Font end, nil)
    local size = font and tonumber(font.Size) or 12
    return size
end

-- The drop stays centered under the portrait. The gold combo is centered
-- on the line below it.
local function placeHintBelow(drop, hint)
    local dropSlot = drop.Slot
    local hintSlot = hint.Slot
    if not isLive(dropSlot) or not isLive(hintSlot) then
        return
    end
    local centerX, topY = vec2(dropSlot:GetPosition())
    local step = lineHeight(drop)
    pcall(function()
        hintSlot:SetAutoSize(true)
        hintSlot:SetAlignment({ X = 0.5, Y = 0 })
        hintSlot:SetPosition({ X = centerX, Y = topY + step })
        local z = tonumber(safe(function() return dropSlot:GetZOrder() end, 0)) or 0
        hintSlot:SetZOrder(z + 1)
    end)
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

local function placeComboText(gauge, widget)
    local portrait = gaugePortrait(gauge)
    if not isLive(portrait) then
        if not comboMissLogged then
            comboMissLogged = true
            log("combo portrait missing")
        end
        return false
    end
    if attachPortrait(widget, portrait, false, 8) then
        return true
    end
    return false
end

local function ensureComboText(gauge)
    clearStarNotes(gauge)
    if comboPlaced and isLive(comboText) and isLive(parentOf(comboText)) then
        styleComboText(gauge, comboText)
        placeComboText(gauge, comboText)
        return comboText
    end
    comboPlaced = false
    if not isLive(comboText) then
        local class = StaticFindObject("/Script/UMG.TextBlock")
        local widget = class and StaticConstructObject(class, gauge) or nil
        if not isLive(widget) then
            return nil
        end
        comboText = widget
        comboFontReady = false
    end
    if placeComboText(gauge, comboText) then
        comboPlaced = true
        styleComboText(gauge, comboText)
    end
    return comboText
end

local function ensureComboHint(gauge)
    if not isLive(comboHintText) then
        local class = StaticFindObject("/Script/UMG.TextBlock")
        local widget = class and StaticConstructObject(class, gauge) or nil
        if not isLive(widget) then
            return nil
        end
        comboHintText = widget
        comboHintFontReady = false
    end
    if placeComboText(gauge, comboHintText) then
        styleHintText(gauge, comboHintText)
    end
    return comboHintText
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

local function nameHasInfoMark(text)
    return type(text) == "string"
        and (text:find("DropViewerInfo", 1, true) or text:find("UnitDropsInfo", 1, true))
end

local function isInfoMarker(widget)
    if not isLive(widget) then
        return false
    end
    if nameHasInfoMark(widgetClass(widget)) then
        return true
    end
    local name = safe(function() return widget:GetName() end, "") or ""
    return nameHasInfoMark(name)
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
        if not isLive(widget) or sameObject(widget, comboText) or sameObject(widget, comboHintText) or sameObject(widget, name) or sameObject(widget, force) then
            return
        end
        if infoOwned[widgetKey(widget)] or isInfoMarker(widget) then
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

local function applyPane(label, hint, actorKey)
    local hud = findHud()
    local gauge = isLive(hud) and hud.BP_parts_gauge_enemy or nil
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
            placeHintBelow(combo, hintBox)
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

local function currentEmitter()
    local player = FindFirstOf("AppCharacterPlayer")
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

local function refreshLabel()
    local label = nil
    local hint = nil
    local actorKey = ""
    if dropCache then
        local actor = currentEmitter()
        if isLive(actor) then
            actorKey = widgetKey(actor)
            local index = asInt(safe(function() return actor.DropRecordIndex end, nil))
            local raw = index and dropCache.items[index] or nil
            if raw ~= nil then
                label = itemLabel(raw)
                hint = comboHint(raw)
            end
        end
    end
    applyPane(label, hint, actorKey)
end

-- Pause Unit Info. One TextBlock above the officer portrait, drop name only.
-- The line above the name is unitname_ruby. In-game Orders and Havie Unit
-- Orders write that line, including "Officer - Orders: ..." while a sub-officer
-- is highlighted and the card still shows the commander. This code never
-- changes UnitName or unitname_ruby, and the only widget it removes is an
-- older DropViewerInfo text left behind by Ctrl+R. A UnitDropsInfo
-- widget from the previous name is removed the same way.
local infoFailed = false
local infoFontLogged = false
local infoLogs = 0
local infoMissLogged = false
local infoEntries = {}
local infoAnswers = {}

local function callInt(actor, method)
    local value = safe(function() return actor[method](actor) end, nil)
    if type(value) == "userdata" then
        value = unwrap(value)
    end
    local n = asInt(value)
    if n ~= nil then
        return n
    end
    if type(value) == "string" then
        return tonumber(value:match("(%d+)%s*$"))
    end
    return nil
end

local function fieldInt(obj, field)
    if obj == nil then
        return nil
    end
    local value = safe(function() return obj[field] end, nil)
    if type(value) == "userdata" then
        value = unwrap(value)
    end
    return asInt(value)
end

local function asBool(value)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        if value == 1 then
            return true
        end
        if value == 0 then
            return false
        end
    end
    local text = tostring(value):lower()
    if text == "true" then
        return true
    end
    if text == "false" then
        return false
    end
    return nil
end

local function readFocus(list)
    local focus = safe(function() return list.FocusUnit end, nil)
    local inner = focus
    if type(focus) == "userdata" then
        local got = safe(function()
            if focus.get then
                return focus:get()
            end
            return nil
        end, nil)
        if got ~= nil then
            inner = got
        end
    end
    local unit = fieldInt(inner, "UnitID")
    if unit == nil and inner ~= focus then
        unit = fieldInt(focus, "UnitID")
        if unit ~= nil then
            inner = focus
        end
    end
    local group = fieldInt(inner, "GroupID")
    local rank = fieldInt(inner, "Rank")
    if unit == nil then
        unit = fieldInt(list, "NowFocusUnit")
    end
    -- FocusUnit.GroupID stays -1 while the card shows a real officer.
    -- NowFocusGroupID is the highlighted row's AlgoGroupID.
    if group == nil or group < 0 then
        local nowGroup = fieldInt(list, "NowFocusGroupID")
        if nowGroup ~= nil and nowGroup >= 0 then
            group = nowGroup
        end
    end
    return {
        unit = unit,
        group = group,
        rank = rank,
        ally = asBool(safe(function() return list.IsNowFocusAlly end, nil)),
    }
end

local function widgetShown(widget)
    local vis = tonumber(safe(function() return widget:GetVisibility() end, nil))
    if vis == nil then
        return true
    end
    return vis ~= 1 and vis ~= 2
end

local function branchShown(widget)
    local current = widget
    for _ = 1, 6 do
        if not isLive(current) then
            break
        end
        if not widgetShown(current) then
            return false
        end
        current = parentOf(current)
    end
    return true
end

-- Officers stay spawned, so one pass covers a scroll through the unit list.
local emitterScan = { at = -1000, rows = {} }

local function emitterRows()
    local now = os.clock()
    if emitterScan.rows and now - emitterScan.at < 1.0 then
        return emitterScan.rows
    end
    local rows = {}
    local all = FindAllOf("AppCharacterBase") or {}
    for _, actor in ipairs(all) do
        if isLive(actor) and asInt(actor.DropOwnerGate) == -1 then
            local full = safe(function() return actor:GetFullName() end, "") or ""
            if not full:find("Default__", 1, true) then
                rows[#rows + 1] = {
                    actor = actor,
                    unit = callInt(actor, "GetUnitTypeInt"),
                    rank = callInt(actor, "GetUnitRankNum"),
                    side = safe(function() return unwrap(actor:GetSide()) end, nil),
                    index = asInt(actor.DropRecordIndex),
                }
            end
        end
    end
    emitterScan.at = now
    emitterScan.rows = rows
    return rows
end

local function collectEmitters(unitId, rank, wantAlly, useRank, useSide)
    local matches = {}
    local playerSide = nil
    if useSide and wantAlly ~= nil then
        local player = FindFirstOf("AppCharacterPlayer")
        if isLive(player) then
            playerSide = safe(function() return unwrap(player:GetSide()) end, nil)
        end
    end
    for _, row in ipairs(emitterRows()) do
        if row.unit == unitId and isLive(row.actor) then
            local rankOk = true
            if useRank and rank ~= nil then
                rankOk = row.rank == rank
            end
            local sideOk = true
            if useSide and wantAlly ~= nil and playerSide ~= nil and row.side ~= nil then
                local same = tostring(row.side) == tostring(playerSide)
                sideOk = (same == true) == (wantAlly == true)
            end
            if rankOk and sideOk then
                matches[#matches + 1] = row.actor
            end
        end
    end
    return matches
end

local function pickEmitter(matches, groupId)
    local ready = {}
    for _, actor in ipairs(matches) do
        local index = asInt(actor and actor.DropRecordIndex)
        if isLive(actor) and index and index >= 0 then
            ready[#ready + 1] = actor
        end
    end
    matches = ready
    if #matches == 1 then
        return matches[1]
    end
    if #matches == 0 then
        return nil
    end
    if groupId ~= nil and groupId >= 0 then
        local found = nil
        local count = 0
        for _, actor in ipairs(matches) do
            if asInt(actor.DropRecordIndex) == groupId then
                found = actor
                count = count + 1
            end
        end
        if count == 1 then
            return found
        end
    end
    local label = nil
    local same = true
    for _, actor in ipairs(matches) do
        local index = asInt(actor.DropRecordIndex)
        local this = ""
        if index and dropCache and dropCache.items[index] ~= nil then
            this = itemLabel(dropCache.items[index]) or ""
        end
        if label == nil then
            label = this
        elseif this ~= label then
            same = false
            break
        end
    end
    if same then
        return matches[1]
    end
    return nil
end

local uiLib = nil
local unitNames = {}
local nameSampleLogged = false

local function cleanName(text)
    if type(text) ~= "string" then
        return ""
    end
    return (text:match("^%s*(.-)%s*$")) or ""
end

local function textValue(value)
    if type(value) == "string" then
        return value
    end
    if value == nil then
        return nil
    end
    local asString = safe(function()
        if value.ToString then
            return value:ToString()
        end
        return nil
    end, nil)
    if type(asString) == "string" and asString ~= "" then
        return asString
    end
    local shown = unwrap(value)
    if type(shown) == "string" and shown ~= "" and shown ~= "nil" then
        return shown
    end
    return nil
end

local function uiFunction()
    if isLive(uiLib) then
        return uiLib
    end
    uiLib = StaticFindObject("/Script/Refine.Default__UIFunction")
    return isLive(uiLib) and uiLib or nil
end

local function unitDisplayName(unitId, disp)
    if unitId == nil then
        return nil
    end
    local key = tostring(unitId) .. (disp and ":d" or ":r")
    local cached = unitNames[key]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local fn = uiFunction()
    if not fn then
        return nil
    end
    local text = nil
    local ok = pcall(function()
        text = textValue(fn:GetUnitName(unitId, disp and true or false))
    end)
    if not ok then
        unitNames[key] = false
        return nil
    end
    local cleaned = cleanName(text)
    unitNames[key] = cleaned ~= "" and cleaned or false
    return unitNames[key] ~= false and unitNames[key] or nil
end

local function sameCardName(unitId, card, useDisp)
    if card == "" or unitId == nil then
        return false
    end
    local raw = unitDisplayName(unitId, false)
    if raw and raw:lower() == card:lower() then
        return true
    end
    if not useDisp then
        return false
    end
    local disp = unitDisplayName(unitId, true)
    return disp ~= nil and disp:lower() == card:lower()
end

local function readEntries(array)
    local rows = {}
    if array == nil then
        return rows
    end
    local function take(info)
        local inner = info
        if info and info.get then
            local got = safe(function() return info:get() end, nil)
            if got ~= nil then
                inner = got
            end
        end
        local unit = fieldInt(inner, "UnitID")
        if unit and unit ~= 0 then
            rows[#rows + 1] = {
                unit = unit,
                group = fieldInt(inner, "GroupID"),
                rank = fieldInt(inner, "Rank"),
            }
        end
    end
    local walked = false
    local ok = pcall(function()
        array:ForEach(function(info)
            walked = true
            take(info)
        end)
    end)
    if ok and walked then
        return rows
    end
    local count = tonumber(safe(function() return array:GetArrayNum() end, 0)) or 0
    for index = 0, count - 1 do
        take(safe(function() return array:Get(index) end, nil))
    end
    return rows
end

local function emittersNamed(card, wantAlly, useDisp)
    local matches = {}
    local function gather(useSide)
        local found = {}
        local playerSide = nil
        if useSide and wantAlly ~= nil then
            local player = FindFirstOf("AppCharacterPlayer")
            if isLive(player) then
                playerSide = safe(function() return unwrap(player:GetSide()) end, nil)
            end
        end
        for _, row in ipairs(emitterRows()) do
            if isLive(row.actor) and sameCardName(row.unit, card, useDisp) then
                local keep = true
                if useSide and wantAlly ~= nil and playerSide ~= nil and row.side ~= nil then
                    local same = tostring(row.side) == tostring(playerSide)
                    keep = (same == true) == (wantAlly == true)
                end
                if keep then
                    found[#found + 1] = row.actor
                end
            end
        end
        return found
    end
    matches = gather(true)
    if #matches == 0 then
        matches = gather(false)
    end
    return matches
end

local function listEntryForName(list, card, ally, useDisp)
    local arrays = {}
    if ally ~= false and list then
        arrays[#arrays + 1] = safe(function() return list.UnitInfoList end, nil)
    end
    if ally ~= true and list then
        arrays[#arrays + 1] = safe(function() return list.EnemyUnitInfoList end, nil)
    end
    local hits = {}
    for _, array in ipairs(arrays) do
        for _, entry in ipairs(readEntries(array)) do
            if sameCardName(entry.unit, card, useDisp) then
                hits[#hits + 1] = entry
            end
        end
    end
    if #hits == 1 then
        return hits[1]
    end
    return nil
end

local function labelFromActor(actor, count, how)
    local index = asInt(actor and actor.DropRecordIndex)
    if not index or index < 0 or not dropCache then
        return nil, how .. " index=" .. tostring(index)
    end
    local raw = dropCache.items[index]
    local why = string.format("%s index=%s n=%d", how, tostring(index), count)
    if lowByte(raw) == 255 then
        why = why .. " blank"
    end
    return itemLabel(raw), why
end

local ambiguousLogged = {}

local function logAmbiguous(card, matches, rowGroup, focusGroup)
    local key = tostring(card) .. ":" .. tostring(rowGroup) .. ":" .. tostring(focusGroup)
    if ambiguousLogged[key] then
        return
    end
    ambiguousLogged[key] = true
    local bits = {}
    for _, actor in ipairs(matches) do
        local unit = callInt(actor, "GetUnitTypeInt")
        bits[#bits + 1] = string.format(
            "type=%s rank=%s index=%s raw=[%s] disp=[%s]",
            tostring(unit),
            tostring(callInt(actor, "GetUnitRankNum")),
            tostring(asInt(actor.DropRecordIndex)),
            tostring(unitDisplayName(unit, false)),
            tostring(unitDisplayName(unit, true))
        )
    end
    log(string.format(
        "info ambiguous [%s] row=%s focus=%s %s",
        card,
        tostring(rowGroup),
        tostring(focusGroup),
        table.concat(bits, " | ")
    ))
end

-- List rows keep AlgoGroupID in GroupID. GetGroupNowPos indexes the
-- battle-record array by that id, so it is the same number as DropRecordIndex.
local setupScan = { at = -1000, rows = {} }

local function setupRows()
    local now = os.clock()
    if setupScan.rows and now - setupScan.at < 1.0 then
        return setupScan.rows
    end
    local rows = {}
    for _, className in ipairs({
        "BP_parts_battle_setup_chara_list_C",
        "BP_parts_battle_setup_chara_sub_C",
    }) do
        for _, row in ipairs(FindAllOf(className) or {}) do
            local full = safe(function() return row:GetFullName() end, "") or ""
            if isLive(row) and not full:find("Default__", 1, true) then
                rows[#rows + 1] = row
            end
        end
    end
    setupScan.at = now
    setupScan.rows = rows
    return rows
end

local function oneGroup(ids)
    local seen = {}
    local only = nil
    local count = 0
    for _, group in ipairs(ids) do
        if not seen[group] then
            seen[group] = true
            only = group
            count = count + 1
        end
    end
    if count == 1 then
        return only
    end
    return nil
end

local function focusedListGroup(card)
    local want = cleanName(card):lower()
    if want == "" or want:find("<", 1, true) then
        return nil
    end
    local function fromMarker(useLine)
        local hits = {}
        for _, row in ipairs(setupRows()) do
            if isLive(row) and widgetShown(row) then
                local marker = safe(function()
                    if useLine then
                        return row.focus_line
                    end
                    return row.text_chara_focus
                end, nil)
                if isLive(marker) and widgetShown(marker) then
                    local shown = cleanName(textOf(row.text_chara_focus))
                    if shown == "" or shown:find("<", 1, true) then
                        shown = cleanName(textOf(row.text_chara))
                    end
                    if shown:lower() == want then
                        local group = fieldInt(row, "GroupID")
                        if group ~= nil and group >= 0 then
                            hits[#hits + 1] = group
                        end
                    end
                end
            end
        end
        return oneGroup(hits)
    end
    local group = fromMarker(false)
    if group ~= nil then
        return group
    end
    return fromMarker(true)
end

-- Exactly one emitter whose record index is this group. Several matches,
-- or none, stay unresolved so another officer's drop is not borrowed.
local function emitterByGroup(matches, groupId)
    if groupId == nil or groupId < 0 then
        return nil
    end
    local found = nil
    local count = 0
    for _, actor in ipairs(matches) do
        local index = asInt(actor and actor.DropRecordIndex)
        if isLive(actor) and index ~= nil and index >= 0 and index == groupId then
            found = actor
            count = count + 1
        end
    end
    if count == 1 then
        return found
    end
    return nil
end

-- NowFocusGroupID for these officers is 1, 2, 3, 4 while their record
-- indexes are 16, 17, 18, 19. The focus value is the row in the pause list.
local function listEntries(list, ally)
    local arrays = {}
    if ally ~= false and list then
        arrays[#arrays + 1] = safe(function() return list.UnitInfoList end, nil)
    end
    if ally ~= true and list then
        arrays[#arrays + 1] = safe(function() return list.EnemyUnitInfoList end, nil)
    end
    local rows = {}
    for _, array in ipairs(arrays) do
        for _, entry in ipairs(readEntries(array)) do
            rows[#rows + 1] = entry
        end
    end
    return rows
end

local function ordinalAt(entries, card, useDisp, luaIndex)
    local entry = entries[luaIndex]
    if not entry or not sameCardName(entry.unit, card, useDisp) then
        return nil
    end
    local count = 0
    for index = 1, luaIndex do
        if sameCardName(entries[index].unit, card, useDisp) then
            count = count + 1
        end
    end
    if count >= 1 then
        return count
    end
    return nil
end

local function emitterByOrder(matches, ordinal)
    if ordinal == nil or ordinal < 1 then
        return nil
    end
    local ready = {}
    for _, actor in ipairs(matches) do
        local index = asInt(actor and actor.DropRecordIndex)
        if isLive(actor) and index ~= nil and index >= 0 then
            ready[#ready + 1] = actor
        end
    end
    table.sort(ready, function(a, b)
        return asInt(a.DropRecordIndex) < asInt(b.DropRecordIndex)
    end)
    return ready[ordinal]
end

local orderLogged = {}
local listLogged = {}

local function logList(card, entries, focusGroup)
    if listLogged[card] then
        return
    end
    listLogged[card] = true
    local bits = {}
    for index = 1, math.min(#entries, 8) do
        local entry = entries[index]
        bits[#bits + 1] = string.format(
            "%d:type=%s group=%s",
            index,
            tostring(entry.unit),
            tostring(entry.group)
        )
    end
    log(string.format(
        "info list [%s] focus=%s n=%d %s",
        card,
        tostring(focusGroup),
        #entries,
        table.concat(bits, " | ")
    ))
end

local function logOrder(card, focusGroup, ordinal, actor)
    local key = tostring(card) .. ":" .. tostring(focusGroup)
    if orderLogged[key] then
        return
    end
    orderLogged[key] = true
    log(string.format(
        "info order [%s] focus=%s ordinal=%s index=%s",
        card,
        tostring(focusGroup),
        tostring(ordinal),
        tostring(asInt(actor and actor.DropRecordIndex))
    ))
end

-- FocusUnit comes through as unit 0, group -1. The name painted on the card
-- is the officer. The raw unit name is tried first, so a subordinate whose
-- display name copies the officer does not compete with him. Officers who
-- share that name are separated by the highlighted list row.
local function resolveInfoLabel(list, focus, cardName)
    if not dropCache then
        return nil, "pending"
    end
    local card = cleanName(cardName)
    local ally = focus and focus.ally or nil
    if card ~= "" and not card:find("<", 1, true) then
        local useDisp = false
        local named = emittersNamed(card, ally, false)
        local entry = listEntryForName(list, card, ally, false)
        if #named == 0 then
            useDisp = true
            named = emittersNamed(card, ally, true)
            entry = listEntryForName(list, card, ally, true)
        end
        local actor = nil
        if #named > 1 then
            actor = emitterByGroup(named, focus and focus.rowGroup)
                or emitterByGroup(named, focus and focus.group)
                or emitterByGroup(named, entry and entry.group)
            if not isLive(actor) then
                local entries = listEntries(list, ally)
                local focusGroup = focus and focus.group or nil
                local ordinal = nil
                if focusGroup ~= nil and focusGroup >= 1 then
                    ordinal = ordinalAt(entries, card, useDisp, focusGroup)
                    if ordinal == nil then
                        ordinal = ordinalAt(entries, card, useDisp, focusGroup + 1)
                    end
                    if ordinal == nil and #entries == 0 and focusGroup <= #named then
                        ordinal = focusGroup
                    end
                end
                actor = emitterByOrder(named, ordinal)
                if isLive(actor) then
                    logOrder(card, focusGroup, ordinal, actor)
                else
                    logList(card, entries, focusGroup)
                end
            end
        end
        if not isLive(actor) then
            actor = pickEmitter(named, entry and entry.group or (focus and focus.group))
        end
        if not isLive(actor) and entry and entry.unit and entry.unit ~= 0 then
            local passes = {
                { true, true },
                { false, true },
                { false, false },
            }
            for _, pass in ipairs(passes) do
                local matches = collectEmitters(entry.unit, entry.rank, ally, pass[1], pass[2])
                if #matches > 0 then
                    actor = pickEmitter(matches, entry.group)
                    if isLive(actor) then
                        named = matches
                        break
                    end
                    logAmbiguous(card, matches, focus and focus.rowGroup, focus and focus.group)
                    return nil, "ambiguous " .. tostring(#matches)
                end
            end
        end
        if isLive(actor) then
            return labelFromActor(actor, #named, "name")
        end
        if #named > 1 then
            logAmbiguous(card, named, focus and focus.rowGroup, focus and focus.group)
            return nil, "ambiguous " .. tostring(#named)
        end
        if not nameSampleLogged then
            nameSampleLogged = true
            local sample = emitterRows()[1]
            local sampleName = sample and unitDisplayName(sample.unit, false) or nil
            log(string.format(
                "info name miss [%s] sample type=%s name=[%s]",
                card,
                tostring(sample and sample.unit),
                tostring(sampleName)
            ))
        end
    end
    if not focus or focus.unit == nil or focus.unit == 0 then
        return nil, "no-unit"
    end
    local passes = {
        { true, true },
        { true, false },
        { false, true },
        { false, false },
    }
    for _, pass in ipairs(passes) do
        local matches = collectEmitters(focus.unit, focus.rank, focus.ally, pass[1], pass[2])
        if #matches > 0 then
            local actor = pickEmitter(matches, focus.group)
            if not isLive(actor) then
                return nil, "ambiguous " .. tostring(#matches)
            end
            return labelFromActor(actor, #matches, "focus")
        end
    end
    return nil, "none"
end

local function cacheStamp()
    if not dropCache then
        return "pending"
    end
    return numText(dropCache.data) .. ":" .. tostring(dropCache.count)
end

local function answerFor(list, focus, name)
    local key = widgetKey(list)
    local slot = infoAnswers[key]
    if not slot then
        slot = {}
        infoAnswers[key] = slot
    end
    local card = textOf(name)
    focus.rowGroup = focusedListGroup(card)
    local token = table.concat({
        card,
        tostring(focus.ally),
        tostring(focus.group),
        tostring(focus.rowGroup),
        cacheStamp(),
    }, ":")
    local retry = slot.label == nil and not (slot.why and slot.why:find("blank", 1, true))
        and os.clock() - (slot.at or 0) > 1.0
    if slot.token ~= token or retry then
        slot.token = token
        slot.at = os.clock()
        slot.label, slot.why = resolveInfoLabel(list, focus, card)
        local why = slot.why or ""
        local failed = slot.label == nil
            and why ~= "pending"
            and why ~= "no-unit"
            and not why:find("blank", 1, true)
            and not why:find("ambiguous", 1, true)
        if failed and slot.line ~= why and infoLogs < 8 then
            slot.line = why
            infoLogs = infoLogs + 1
            log(string.format(
                "info [%s] unit=%s rank=%s group=%s ally=%s %s",
                card,
                tostring(focus.unit),
                tostring(focus.rank),
                tostring(focus.group),
                tostring(focus.ally),
                why
            ))
        end
    end
    return slot.label
end

local function eachDescendant(root, fn)
    local seen = {}
    local function walk(widget, depth)
        local current = asWidget(widget)
        if not current or depth > 16 then
            return
        end
        local id = widgetKey(current)
        if seen[id] then
            return
        end
        seen[id] = true
        fn(current)
        local count = tonumber(safe(function() return current:GetChildrenCount() end, 0)) or 0
        for index = 0, count - 1 do
            walk(safe(function() return current:GetChildAt(index) end, nil), depth + 1)
        end
    end
    walk(root, 0)
end

local function protectedCardText(detail, widget)
    if not isLive(detail) or not isLive(widget) then
        return false
    end
    return sameObject(widget, detail.UnitName)
        or sameObject(widget, detail.unitname_ruby)
        or sameObject(widget, detail.index_morale)
        or sameObject(widget, detail.index_morale_2)
        or sameObject(widget, detail.index_busho)
end

local function claimInfo(widget)
    if isLive(widget) then
        infoOwned[widgetKey(widget)] = true
    end
end

local function infoEntry(detail)
    local key = widgetKey(detail)
    local entry = infoEntries[key]
    if not entry then
        entry = { fontReady = false, reveals = 0 }
        infoEntries[key] = entry
    end
    return entry
end

local function placeInfoText(entry, widget, detail)
    local face = isLive(detail) and detail.face_000 or nil
    if not isLive(face) then
        if not infoMissLogged then
            infoMissLogged = true
            log("info portrait missing")
        end
        return false
    end
    entry.marker = face
    if attachPortrait(widget, face, true, 10) then
        return true
    end
    return false
end

local function styleInfoNote(name, widget, entry)
    if entry.fontReady or not isLive(name) or not isLive(widget) then
        return
    end
    local font = safe(function() return name.Font end, nil)
    local size = font and tonumber(font.Size) or nil
    if not size or size <= 8 then
        return
    end
    local fontOk = pcall(function()
        font.Size = math.floor(size * 0.65)
        widget:SetFont(font)
    end)
    font.Size = size
    pcall(function() name:SetFont(font) end)
    pcall(function() widget:SetColorAndOpacity(name.ColorAndOpacity) end)
    if fontOk then
        entry.fontReady = true
    elseif not infoFontLogged then
        infoFontLogged = true
        log("info font failed")
    end
end

local function findInfoMarker(detail)
    local found = nil
    local extras = {}
    local function take(widget)
        if not isInfoMarker(widget) or protectedCardText(detail, widget) then
            return
        end
        if not widgetClass(widget):find("TextBlock", 1, true) then
            return
        end
        if not found then
            found = widget
        elseif not sameObject(widget, found) then
            extras[#extras + 1] = widget
        end
    end
    local root = safe(function() return detail.WidgetTree.RootWidget end, nil)
    eachDescendant(root, take)
    for _, extra in ipairs(extras) do
        pcall(function() extra:SetVisibility(1) end)
        local parent = parentOf(extra)
        if isLive(parent) then
            pcall(function() parent:RemoveChild(extra) end)
        end
    end
    return found
end

local function makeInfoNote(detail)
    local class = StaticFindObject("/Script/UMG.TextBlock")
    if not isLive(class) then
        return nil
    end
    local widget = nil
    local named = pcall(function()
        widget = StaticConstructObject(class, detail, FName("DropViewerInfo"))
    end)
    if not named or not isLive(widget) then
        widget = safe(function() return StaticConstructObject(class, detail) end, nil)
    end
    if isLive(widget) and not isInfoMarker(widget) then
        pcall(function() widget:Rename(FName("DropViewerInfo"), detail) end)
    end
    if isLive(widget) and not isInfoMarker(widget) and not infoMissLogged then
        infoMissLogged = true
        log("info name " .. widgetClass(widget))
    end
    return widget
end

local function revealInfo(widget)
    pcall(function()
        widget:InvalidateLayoutAndVolatility()
        widget:ForceVolatile(true)
    end)
    local current = widget
    for _ = 1, 8 do
        local parent = parentOf(current)
        if not isLive(parent) then
            break
        end
        if widgetClass(parent):find("InvalidationBox", 1, true) then
            pcall(function() parent:InvalidateCache() end)
            break
        end
        current = parent
    end
end

local function ensureInfoNote(detail, name)
    local entry = infoEntry(detail)
    if not (isLive(entry.widget) and isLive(parentOf(entry.widget))) then
        local existing = findInfoMarker(detail)
        if isLive(existing) then
            entry.widget = existing
            entry.fontReady = false
        elseif not isLive(entry.widget) then
            entry.widget = makeInfoNote(detail)
            entry.fontReady = false
        end
        if isLive(entry.widget) then
            claimInfo(entry.widget)
            placeInfoText(entry, entry.widget, detail)
        end
    end
    if not isLive(entry.widget) then
        return nil, entry
    end
    claimInfo(entry.widget)
    styleInfoNote(name, entry.widget, entry)
    if isLive(entry.marker) then
        attachPortrait(entry.widget, entry.marker, true, 10)
    end
    return entry.widget, entry
end

local function showInfoNote(note, entry, label, name)
    if not isLive(note) then
        return
    end
    local nameText = textOf(name)
    local nextText = label or ""
    local key = nameText .. "|" .. nextText
    if isLive(entry.marker) then
        attachPortrait(note, entry.marker, true, 10)
    end
    if textOf(note) ~= nextText then
        setWidgetText(note, nextText)
    end
    if label then
        pcall(function()
            note:SetVisibility(4)
            note:SetRenderOpacity(1)
        end)
    else
        pcall(function() note:SetVisibility(1) end)
    end
    if entry.key ~= key then
        entry.key = key
        if (entry.reveals or 0) < 3 then
            entry.reveals = 3
        end
    end
    if (entry.reveals or 0) > 0 then
        revealInfo(note)
        entry.reveals = entry.reveals - 1
    end
end

local function refreshInfoList(list)
    if not isLive(list) then
        return
    end
    local full = safe(function() return list:GetFullName() end, "") or ""
    if full:find("Default__", 1, true) or not branchShown(list) then
        return
    end
    local detail = asWidget(safe(function() return list.BP_parts_battle_setup_chara_detail end, nil))
    if not isLive(detail) then
        return
    end
    local name = asWidget(safe(function() return detail.UnitName end, nil))
    if not isLive(name) then
        return
    end
    local focus = readFocus(list)
    local label = nil
    if focus then
        label = answerFor(list, focus, name)
    end
    local note, entry = ensureInfoNote(detail, name)
    showInfoNote(note, entry, label, name)
end

local function refreshInfo()
    local all = FindAllOf("BP_battle_setup_info_unit_C") or {}
    for _, list in ipairs(all) do
        local ok, err = pcall(refreshInfoList, list)
        if not ok and not infoFailed then
            infoFailed = true
            log("info " .. tostring(err))
        end
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
    if not hooksReady.info then
        local ok, err = pcall(function()
            RegisterHook("/Game/UI/03_battle_setup/BP_battle_setup_info_unit.BP_battle_setup_info_unit_C:Tick", function()
            end, function(self)
                local list = safe(function() return self:get() end, nil)
                local hooked, hookErr = pcall(refreshInfoList, list)
                if not hooked and not infoFailed then
                    infoFailed = true
                    log("info " .. tostring(hookErr))
                end
            end)
        end)
        if ok then
            hooksReady.info = true
        elseif not hooksReady.infoLogged and isLive(FindFirstOf("BP_battle_setup_info_unit_C")) then
            hooksReady.infoLogged = true
            log("info tick hook " .. tostring(err))
        end
    end
end

local function refreshPane()
    ensureCache()
    restoreAllGauges()
    refreshLabel()
    refreshInfo()
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
