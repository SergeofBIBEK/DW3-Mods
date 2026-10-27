-- Combo Efficiency Indicator
-- Random item boxes add a quality step from the combo rate at pickup.
-- rate = (Perfect * 15 + Great * 5) / max(scenario timer, 300)
--   >= 0.13 is Peerless, >= 0.06 is Refined, otherwise Common.
-- Good hits are not part of this rate.
-- The timer is ScenarioManager:GetScenarioTimer(0), the same first float
-- the pickup function reads. The 300 second floor is the game's floor.
--   AppCharacterPlayer +0xD6C = Perfect count
--   AppCharacterPlayer +0xD70 = Great count
-- The label sits just above the player portrait, lined up with its left edge,
-- then 8 px lower.
-- A gauge with no portrait uses the officer name instead.
-- Each local player has their own Perfect and Great counts. The top half
-- shows player 1. The bottom half shows player 2.
-- The gauge's outer slot is above the canvas, so that slot is not used.

local MOD = "Combo Efficiency"
local PERFECT_WEIGHT = 15
local GREAT_WEIGHT = 5
local TIME_FLOOR = 300
local RATE_PLUS_TWO = 0.13
local RATE_PLUS_ONE = 0.06
local NUDGE_Y = 8

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

local function customProperty(info)
    local ok, err = pcall(RegisterCustomProperty, info)
    if not ok then
        log("custom " .. tostring(info.Name) .. " " .. tostring(err))
    end
end

customProperty({
    Name = "ComboPerfectCount",
    Type = PropertyTypes.IntProperty,
    BelongsToClass = "/Script/Refine.AppCharacterPlayer",
    OffsetInternal = 0xD6C,
})
customProperty({
    Name = "ComboGreatCount",
    Type = PropertyTypes.IntProperty,
    BelongsToClass = "/Script/Refine.AppCharacterPlayer",
    OffsetInternal = 0xD70,
})
local function asInt(value)
    if type(value) == "number" then
        return math.floor(value)
    end
    if type(value) == "string" then
        return tonumber(value)
    end
    if type(value) ~= "userdata" then
        return nil
    end
    local inner = safe(function()
        if value.get then
            return value:get()
        end
        return nil
    end, nil)
    if type(inner) == "number" then
        return math.floor(inner)
    end
    local text = safe(function()
        if value.ToString then
            return value:ToString()
        end
        return tostring(value)
    end, "") or ""
    return tonumber(text:match("-?%d+"))
end

-- PLAYER1 is player id 0. The digit in that name is not the id.
local function playerId(actor)
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
    if string.match(text, "^%-?%d+$") then
        return tonumber(text)
    end
    return nil
end

local boards = {}

local function boardFor(id)
    local board = boards[id]
    if not board then
        board = { paintLeft = 0, fontReady = false }
        boards[id] = board
    end
    return board
end

local function textOf(widget)
    if not isLive(widget) then
        return ""
    end
    return safe(function()
        local text = widget:GetText()
        if text and text.ToString then
            return text:ToString()
        end
        return tostring(text)
    end, "") or ""
end

local function setWidgetText(widget, value)
    if not isLive(widget) then
        return
    end
    pcall(function()
        if FText then
            widget:SetText(FText(value))
            return
        end
        local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        widget:SetText(lib:Conv_StringToText(value))
    end)
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

local function ownedLabel(widget)
    for _, board in pairs(boards) do
        if sameObject(widget, board.widget) then
            return true
        end
    end
    return false
end

local function widgetClass(widget)
    local full = safe(function() return widget:GetFullName() end, "") or ""
    if full ~= "" then
        return full
    end
    return safe(function() return widget:GetClass():GetName() end, "") or ""
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

local function shown(widget)
    if not isLive(widget) then
        return false
    end
    local vis = safe(function() return widget:GetVisibility() end, nil)
    local n = tonumber(vis)
    if not n and type(vis) == "userdata" then
        n = tonumber(safe(function()
            if vis.get then
                return vis:get()
            end
            return nil
        end, nil))
        if not n then
            local text = safe(function()
                if vis.ToString then
                    return vis:ToString()
                end
                return tostring(vis)
            end, "") or ""
            if text:find("Collapsed", 1, true) then
                return false
            end
            if text:find("Hidden", 1, true) and not text:find("HitTest", 1, true) then
                return false
            end
            if text:find("Visible", 1, true) or text:find("HitTestInvisible", 1, true) then
                return true
            end
        end
    end
    if n == nil then
        return true
    end
    return n == 0 or n == 3 or n == 4
end

local readLogged = false
local timerState = "pending"
local scenario = nil
local playerLogged = false
local refreshLogged = false
local placeLogged = false
local placeFailLogged = false
local geoState = "pending"
local placeTries = 0
local swept = false
local slate = nil

local BONUS_WORDS = {
    [0] = "Common",
    [1] = "Refined",
    [2] = "Peerless",
}

-- Common is a quiet gray. Refined is steel blue.
-- Peerless fades purple in and back out over the yellow, twice a second.
-- The blend is linear, so the color moves the whole way instead of sitting on yellow.
local BONUS_COLOR = {
    [0] = { R = 0.16, G = 0.16, B = 0.18, A = 1.0 },
    [1] = { R = 0.55, G = 0.82, B = 1.0, A = 1.0 },
}
local FLASH_YELLOW = { R = 1.0, G = 0.92, B = 0.10, A = 1.0 }
local FLASH_PURPLE = { R = 0.75, G = 0.18, B = 1.0, A = 1.0 }
local PULSE_PERIOD = 0.5
local pulseOn = false

local function bonusText(bonus)
    return BONUS_WORDS[bonus] or BONUS_WORDS[0]
end

local function isOurText(text)
    if type(text) ~= "string" then
        return false
    end
    if text == "Common" or text == "Plain" or text == "Refined" or text == "Peerless" then
        return true
    end
    if text:find("Quality Bonus:", 1, true) == 1 then
        return true
    end
    if text:match("^%+%d$") then
        return true
    end
    -- Previous build wrote "Combo N". Drop those on reload.
    return text:match("^Combo %d+$") ~= nil
end

local function asNumber(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        return tonumber(value)
    end
    if type(value) ~= "userdata" then
        return nil
    end
    local inner = safe(function()
        if value.get then
            return value:get()
        end
        return nil
    end, nil)
    if type(inner) == "number" then
        return inner
    end
    local text = safe(function()
        if value.ToString then
            return value:ToString()
        end
        return tostring(value)
    end, "") or ""
    return tonumber(text:match("-?%d+%.?%d*"))
end

local function liveNamed(className)
    local all = FindAllOf(className) or {}
    for _, obj in ipairs(all) do
        if isLive(obj) then
            local name = safe(function() return obj:GetFullName() end, "") or ""
            if not string.find(name, "Default__", 1, true) then
                return obj
            end
        end
    end
    return nil
end

-- UScenarioManager is the game-instance subsystem. The actor BP_ScenarioManager_C
-- does not own this timer.
local function scenarioManager()
    if isLive(scenario) then
        return scenario
    end
    scenario = liveNamed("ScenarioManager")
    return scenario
end

-- Seconds the item roll divides by. Slot 0 is the float at ScenarioManager +0x110.
local function scenarioSeconds()
    local mgr = scenarioManager()
    if not isLive(mgr) then
        scenario = nil
        if timerState ~= "missing" then
            timerState = "missing"
            log("scenario timer missing")
        end
        return 0
    end
    local seconds = asNumber(safe(function()
        return mgr:GetScenarioTimer(0)
    end, nil))
    if seconds == nil then
        if timerState ~= "bad" then
            timerState = "bad"
            log("scenario timer unreadable")
        end
        return 0
    end
    if seconds < 0 then
        seconds = 0
    end
    if timerState ~= "ok" then
        timerState = "ok"
        log(string.format("scenario timer %.1f", seconds))
    end
    return seconds
end

local function localPlayers()
    local byId = {}
    local loose = nil
    local all = FindAllOf("AppCharacterPlayer") or {}
    for _, actor in ipairs(all) do
        if isLive(actor) then
            local name = safe(function() return actor:GetFullName() end, "") or ""
            if not string.find(name, "Default__", 1, true) then
                local localOk = safe(function() return actor:IsLocallyControlled() end, false) == true
                if localOk then
                    local id = playerId(actor)
                    if id == 0 or id == 1 then
                        byId[id] = actor
                    elseif not loose then
                        loose = actor
                    end
                end
            end
        end
    end
    if not isLive(byId[0]) and isLive(loose) then
        byId[0] = loose
    end
    return byId
end

local function itemBonus(actor, board, playerNumber)
    if not isLive(actor) then
        if not playerLogged then
            playerLogged = true
            log("player not found")
        end
        return nil
    end
    local perfect = asInt(safe(function() return actor.ComboPerfectCount end, nil))
    local great = asInt(safe(function() return actor.ComboGreatCount end, nil))
    if perfect == nil or great == nil then
        if not readLogged then
            readLogged = true
            log("counts unreadable")
        end
        return nil
    end
    if perfect < 0 then
        perfect = 0
    end
    if great < 0 then
        great = 0
    end
    local rawSeconds = scenarioSeconds()
    local seconds = rawSeconds
    if seconds < TIME_FLOOR then
        seconds = TIME_FLOOR
    end
    local rate = (perfect * PERFECT_WEIGHT + great * GREAT_WEIGHT) / seconds
    local bonus = 0
    if rate >= RATE_PLUS_TWO then
        bonus = 2
    elseif rate >= RATE_PLUS_ONE then
        bonus = 1
    end
    if perfect ~= board.seenPerfect or great ~= board.seenGreat or bonus ~= board.seenBonus then
        board.seenPerfect = perfect
        board.seenGreat = great
        board.seenBonus = bonus
        log(string.format(
            "player %d perfect %d great %d time %.1f rate %.3f bonus +%d",
            playerNumber, perfect, great, rawSeconds, rate, bonus
        ))
    end
    return bonus
end

local function findHud()
    local manager = FindFirstOf("BP_Battle_HUD_Manager_C")
    if isLive(manager) and isLive(manager.Battle2DHUD) then
        return manager.Battle2DHUD
    end
    return FindFirstOf("BP_2d_hud_C")
end

local function hideBoard(board)
    if not board then
        return
    end
    board.bonus = nil
    if isLive(board.widget) then
        pcall(function() board.widget:SetVisibility(1) end)
    end
end

local function removeStale(canvas)
    if not isLive(canvas) then
        return
    end
    local count = tonumber(safe(function() return canvas:GetChildrenCount() end, 0)) or 0
    for index = count - 1, 0, -1 do
        local child = asWidget(safe(function() return canvas:GetChildAt(index) end, nil))
        if isLive(child) and not ownedLabel(child) and widgetClass(child):find("TextBlock", 1, true) and isOurText(textOf(child)) then
            pcall(function() child:SetVisibility(1) end)
            pcall(function() canvas:RemoveChild(child) end)
        end
    end
end

local function styleLabel(gauge, widget, board)
    if board.fontReady or not isLive(widget) then
        return
    end
    local source = isLive(gauge) and gauge.text_pc_name or nil
    local ok = false
    if isLive(source) then
        ok = pcall(function()
            local font = source.Font
            local size = font and tonumber(font.Size) or nil
            local restore = size
            local labelSize = 18
            if size and size >= 8 then
                labelSize = math.floor(size * 0.7)
                if labelSize < 14 then
                    labelSize = 14
                end
            end
            if font then
                font.Size = labelSize
            end
            widget:SetFont(font)
            if restore and font then
                font.Size = restore
                source:SetFont(font)
            end
        end)
    end
    pcall(function()
        widget:SetShadowOffset({ X = 1.0, Y = 1.0 })
        widget:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 })
    end)
    if ok then
        board.fontReady = true
    end
end

local function slateLib()
    if isLive(slate) then
        return slate
    end
    slate = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary")
    if not isLive(slate) then
        slate = StaticFindObject("/Script/UMG.SlateBlueprintLibrary")
    end
    return slate
end

local function zeroAnchors()
    return {
        Minimum = { X = 0.0, Y = 0.0 },
        Maximum = { X = 0.0, Y = 0.0 },
    }
end

-- Screen position of a widget inside a canvas. Slot offsets on the outer
-- gauge panel are not the painted rectangle.
local function markerRect(canvas, marker)
    local lib = slateLib()
    if not isLive(lib) or not isLive(canvas) or not isLive(marker) then
        geoState = "unsupported"
        return nil
    end
    local okMarker, markerGeo = pcall(function() return marker:GetCachedGeometry() end)
    local okCanvas, canvasGeo = pcall(function() return canvas:GetCachedGeometry() end)
    if not okMarker or not okCanvas or markerGeo == nil or canvasGeo == nil then
        geoState = "unsupported"
        return nil
    end
    local okSize, size = pcall(function() return lib:GetLocalSize(markerGeo) end)
    if not okSize or size == nil then
        geoState = "unsupported"
        return nil
    end
    local sizeX, sizeY = vec2(size)
    if sizeX < 2 or sizeY < 2 then
        return nil
    end
    local okOrigin, origin = pcall(function()
        return lib:LocalToAbsolute(markerGeo, { X = 0.0, Y = 0.0 })
    end)
    local okFar, far = pcall(function()
        return lib:LocalToAbsolute(markerGeo, { X = sizeX, Y = sizeY })
    end)
    if not okOrigin or not okFar or origin == nil or far == nil then
        geoState = "unsupported"
        return nil
    end
    local absX, absY = vec2(origin)
    local farX, farY = vec2(far)
    local okLocal, localPos = pcall(function()
        return lib:AbsoluteToLocal(canvasGeo, { X = absX, Y = absY })
    end)
    local okBottom, bottom = pcall(function()
        return lib:AbsoluteToLocal(canvasGeo, { X = farX, Y = farY })
    end)
    if not okLocal or not okBottom or localPos == nil or bottom == nil then
        geoState = "unsupported"
        return nil
    end
    geoState = "ready"
    local x, y = vec2(localPos)
    local right, low = vec2(bottom)
    local w = right - x
    local h = low - y
    if w < 2 or h < 2 or w > 700 or h > 280 then
        return nil
    end
    if x < -40 or y < -40 or x > 2200 or y > 1400 then
        return nil
    end
    return x, y, w, h
end

local function nearestCanvas(marker)
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

local function slotTopLeft(slot)
    local posX, posY = vec2(slot:GetPosition())
    local sizeX, sizeY = vec2(slot:GetSize())
    local alignX, alignY = vec2(safe(function() return slot:GetAlignment() end, nil))
    if sizeX < 8 then
        sizeX = 0
    end
    if sizeY < 8 then
        sizeY = 0
    end
    return posX - alignX * sizeX, posY - alignY * sizeY, sizeX, sizeY
end

local function tintLabel(widget, bonus)
    if not isLive(widget) then
        return false
    end
    local color = BONUS_COLOR[bonus] or BONUS_COLOR[0]
    local flashing = bonus == 2
    if flashing then
        local phase = os.clock() / PULSE_PERIOD
        phase = phase - math.floor(phase)
        local wave
        if phase < 0.5 then
            wave = phase * 2
        else
            wave = (1 - phase) * 2
        end
        color = {
            R = FLASH_YELLOW.R + (FLASH_PURPLE.R - FLASH_YELLOW.R) * wave,
            G = FLASH_YELLOW.G + (FLASH_PURPLE.G - FLASH_YELLOW.G) * wave,
            B = FLASH_YELLOW.B + (FLASH_PURPLE.B - FLASH_YELLOW.B) * wave,
            A = 1.0,
        }
    end
    pcall(function()
        widget:SetColorAndOpacity({
            SpecifiedColor = color,
            ColorUseRule = 0,
        })
    end)
    return flashing
end

local function paintLabel(widget)
    if not isLive(widget) then
        return
    end
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
        end
        current = parent
    end
end

local function sweepStale()
    if swept then
        return
    end
    swept = true
    local all = FindAllOf("TextBlock") or {}
    for _, widget in ipairs(all) do
        if isLive(widget) and not ownedLabel(widget) and isOurText(textOf(widget)) then
            local parent = parentOf(widget)
            pcall(function() widget:SetVisibility(1) end)
            if isLive(parent) then
                pcall(function() parent:RemoveChild(widget) end)
            end
        end
    end
end

local function parentOn(canvas, widget)
    if sameObject(parentOf(widget), canvas) then
        return true
    end
    local old = parentOf(widget)
    if isLive(old) then
        pcall(function() old:RemoveChild(widget) end)
    end
    local added = pcall(function() canvas:AddChildToCanvas(widget) end)
    return added and isLive(parentOf(widget))
end

local function applySlot(widget, anchors, x, y, alignX, alignY)
    local slot = widget.Slot
    if not isLive(slot) then
        return false
    end
    return pcall(function()
        slot:SetAutoSize(true)
        slot:SetAnchors(anchors)
        slot:SetAlignment({ X = alignX, Y = alignY })
        slot:SetPosition({ X = x, Y = y })
        slot:SetZOrder(80)
    end)
end

local function placeOnHud(hud, widget, gauge)
    if not isLive(hud) or not isLive(widget) then
        return false
    end
    placeTries = placeTries + 1
    sweepStale()
    if not isLive(gauge) then
        gauge = hud.bp_parts_gauge_pc
    end
    local name = isLive(gauge) and gauge.text_pc_name or nil
    local face = safe(function()
        if isLive(gauge.still_face) then
            return gauge.still_face
        end
        if isLive(gauge.gauge_player_face_base) then
            return gauge.gauge_player_face_base
        end
        return nil
    end, nil)
    local canvas = isLive(hud.canvas_hud) and hud.canvas_hud or nil
    removeStale(canvas)

    local function finish(host, anchors, x, y, how, alignX, alignY)
        removeStale(host)
        if not parentOn(host, widget) then
            return false
        end
        if not applySlot(widget, anchors, x, y, alignX, alignY) then
            return false
        end
        pcall(function()
            widget:SetRenderTranslation({ X = 0.0, Y = NUDGE_Y })
        end)
        local box = safe(function() return gauge.InvalidationBox_0 end, nil)
        if isLive(box) then
            pcall(function() box:InvalidateCache() end)
        end
        if not placeLogged then
            placeLogged = true
            log(string.format("label %s at %d,%d", how, math.floor(x), math.floor(y)))
        end
        return true
    end

    -- Alignment Y=1 puts the bottom of the text on this point, so the line
    -- sits just above the portrait and grows upward.
    if isLive(canvas) and isLive(face) and geoState ~= "unsupported" then
        local x, y, w, h = markerRect(canvas, face)
        if x and w >= 8 and h >= 8 and w <= 280 and h <= 280 then
            return finish(canvas, zeroAnchors(), x, y + 2, "above portrait", 0.0, 1.0)
        end
    end
    if isLive(face) then
        local host, anchor = nearestCanvas(face)
        local anchorSlot = isLive(anchor) and anchor.Slot or nil
        if isLive(host) and isLive(anchorSlot) then
            local left, top, sizeX, sizeY = slotTopLeft(anchorSlot)
            if sizeY >= 8 and sizeX >= 8 and sizeX <= 280 and sizeY <= 280 and left >= -30 and top >= -30 and left <= 1600 and top <= 1000 then
                return finish(host, anchorSlot:GetAnchors(), left, top + 2, "above portrait slot", 0.0, 1.0)
            end
        end
    end
    -- Split-screen gauges have no portrait. The name is the row that remains.
    if isLive(name) then
        local nameHost, anchor = nearestCanvas(name)
        local anchorSlot = isLive(anchor) and anchor.Slot or nil
        if isLive(nameHost) and isLive(anchorSlot) then
            local left, top, sizeX, sizeY = slotTopLeft(anchorSlot)
            local laidOut = sizeX >= 8 or sizeY >= 8 or math.abs(left) > 4 or math.abs(top) > 4
            if laidOut and left >= -80 and top >= -80 and left <= 2000 and top <= 1400 then
                return finish(nameHost, anchorSlot:GetAnchors(), left, top, "above name", 0.0, 1.0)
            end
        end
    end
    if geoState == "pending" and placeTries < 10 then
        return false
    end
    if isLive(canvas) and isLive(name) and geoState ~= "unsupported" then
        local x, y = markerRect(canvas, name)
        if x then
            return finish(canvas, zeroAnchors(), x, y - 6, "above name", 0.0, 1.0)
        end
    end
    if isLive(canvas) then
        return finish(canvas, zeroAnchors(), 24, 28, "fixed", 0.0, 1.0)
    end
    if not placeFailLogged then
        placeFailLogged = true
        log("place failed")
    end
    return false
end

local function ensureLabel(host, gauge, board)
    local hudKey = safe(function() return gauge:GetAddress() end, host)
    if isLive(board.widget) and board.placedFor == hudKey and isLive(parentOf(board.widget)) then
        if not board.fontReady then
            styleLabel(gauge, board.widget, board)
        end
        return board.widget
    end
    board.placedFor = nil
    if not isLive(board.widget) then
        local class = StaticFindObject("/Script/UMG.TextBlock")
        local outer = isLive(gauge) and gauge or host
        local widget = class and StaticConstructObject(class, outer) or nil
        if not isLive(widget) then
            return nil
        end
        board.widget = widget
        board.fontReady = false
        pcall(function() widget:SetVisibility(4) end)
    end
    if placeOnHud(host, board.widget, gauge) then
        board.placedFor = hudKey
        styleLabel(gauge, board.widget, board)
        board.paintLeft = 8
    end
    return board.widget
end

local splitLogged = false

local function liveMulti()
    local all = FindAllOf("BP_2d_hud_multi_C") or {}
    for _, hud in ipairs(all) do
        if isLive(hud) then
            local name = safe(function() return hud:GetFullName() end, "") or ""
            if not string.find(name, "Default__", 1, true) and shown(hud) then
                return hud
            end
        end
    end
    return nil
end

-- Top half is player 1. Bottom half is player 2. Solo keeps the single gauge.
local function gaugeRows()
    local multi = liveMulti()
    if isLive(multi) then
        local up = asWidget(safe(function() return multi.BP_parts_2d_hud_split_screen_up end, nil))
        local down = asWidget(safe(function() return multi.BP_parts_2d_hud_split_screen_down end, nil))
        local upGauge = isLive(up) and asWidget(safe(function() return up.bp_parts_gauge_pc_multi end, nil)) or nil
        local downGauge = isLive(down) and asWidget(safe(function() return down.bp_parts_gauge_pc_multi end, nil)) or nil
        if isLive(upGauge) and isLive(downGauge) and shown(up) and shown(down) and shown(upGauge) and shown(downGauge) then
            if not splitLogged then
                splitLogged = true
                log("split gauges")
            end
            return {
                { id = 0, host = up, gauge = upGauge },
                { id = 1, host = down, gauge = downGauge },
            }
        end
    end
    local hud = findHud()
    if isLive(hud) and shown(hud) then
        local gauge = asWidget(safe(function() return hud.bp_parts_gauge_pc end, nil))
        if isLive(gauge) then
            return {
                { id = 0, host = hud, gauge = gauge },
            }
        end
    end
    return {}
end

local function refresh()
    local players = localPlayers()
    local rows = gaugeRows()
    local seen = {}
    pulseOn = false
    for _, row in ipairs(rows) do
        seen[row.id] = true
        local board = boardFor(row.id)
        local bonus = itemBonus(players[row.id], board, row.id + 1)
        if bonus == nil or not shown(row.gauge) then
            hideBoard(board)
        else
            local widget = ensureLabel(row.host, row.gauge, board)
            if isLive(widget) then
                local text = bonusText(bonus)
                if textOf(widget) ~= text then
                    setWidgetText(widget, text)
                    if board.paintLeft < 3 then
                        board.paintLeft = 3
                    end
                end
                local flashing = tintLabel(widget, bonus)
                board.bonus = bonus
                if flashing then
                    pulseOn = true
                end
                pcall(function()
                    widget:SetVisibility(4)
                    widget:SetRenderOpacity(1)
                end)
                if board.paintLeft > 0 then
                    paintLabel(widget)
                    board.paintLeft = board.paintLeft - 1
                end
            end
        end
    end
    for id, board in pairs(boards) do
        if not seen[id] then
            hideBoard(board)
        end
    end
end

log("loaded")

local pulseLogged = false
local lastPulseDraw = 0
local pulseHooks = {}

local function pulseDraw()
    if not pulseOn then
        return
    end
    local now = os.clock()
    if now - lastPulseDraw < 0.05 then
        return
    end
    lastPulseDraw = now
    for _, board in pairs(boards) do
        if board.bonus == 2 and isLive(board.widget) then
            local ok, err = pcall(function()
                tintLabel(board.widget, 2)
                paintLabel(board.widget)
            end)
            if not ok and not pulseLogged then
                pulseLogged = true
                log("pulse " .. tostring(err))
            end
        end
    end
end

local function classReady(name)
    local found = FindFirstOf(name)
    return isLive(found)
end

local function ensurePulseHooks()
    local paths = {
        pc = {
            className = "bp_parts_gauge_pc_C",
            path = "/Game/UI/02_battle/bp_parts_gauge_pc.bp_parts_gauge_pc_C:Tick",
        },
        multi = {
            className = "bp_parts_gauge_pc_multi_C",
            path = "/Game/UI/02_battle/bp_parts_gauge_pc_multi.bp_parts_gauge_pc_multi_C:Tick",
        },
    }
    for key, info in pairs(paths) do
        if not pulseHooks[key] and classReady(info.className) then
            local ok, err = pcall(function()
                RegisterHook(info.path, function()
                    pulseDraw()
                end)
            end)
            if ok then
                pulseHooks[key] = true
                log("pulse hook " .. key)
            elseif not pulseHooks[key .. "Logged"] then
                pulseHooks[key .. "Logged"] = true
                log("pulse hook " .. key .. " " .. tostring(err))
            end
        end
    end
end

local loopOk, loopErr = pcall(function()
    LoopAsync(200, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                ensurePulseHooks()
                refresh()
            end)
            if not ok and not refreshLogged then
                refreshLogged = true
                log("refresh " .. tostring(err))
            end
        end)
    end)
end)
if not loopOk then
    log("loop " .. tostring(loopErr))
end
