-- Combo Efficiency Indicator
-- Random item boxes add a quality step from the combo rate at pickup.
-- rate = (Perfect * 15 + Great * 5) / max(scenario timer, 300)
--   >= 0.13 is Peerless, >= 0.06 is Refined, otherwise Common.
-- Good hits are not part of this rate.
-- The timer is ScenarioManager:GetScenarioTimer(0), the same first float
-- the pickup function reads. The 300 second floor is the game's floor.
--   AppCharacterPlayer +0xD6C = Perfect count
--   AppCharacterPlayer +0xD70 = Great count
-- The label sits just above the player portrait, lined up with its left edge.
-- The gauge's outer slot is above the canvas, so that slot is not used.

local MOD = "Combo Efficiency"
local PERFECT_WEIGHT = 15
local GREAT_WEIGHT = 5
local TIME_FLOOR = 300
local RATE_PLUS_TWO = 0.13
local RATE_PLUS_ONE = 0.06
local NUDGE_X = 12

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

local label = nil
local placedFor = nil
local fontReady = false
local readLogged = false
local seenPerfect = nil
local seenGreat = nil
local seenBonus = nil
local timerState = "pending"
local scenario = nil
local playerLogged = false
local refreshLogged = false
local placeLogged = false
local placeFailLogged = false
local paintLeft = 0
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

local function playerActor()
    local all = FindAllOf("AppCharacterPlayer") or {}
    local fallback = nil
    local controlled = nil
    for _, actor in ipairs(all) do
        if isLive(actor) then
            local name = safe(function() return actor:GetFullName() end, "") or ""
            if not string.find(name, "Default__", 1, true) then
                fallback = fallback or actor
                local id = asInt(safe(function() return actor.m_ePlayerID end, nil))
                local localOk = safe(function() return actor:IsLocallyControlled() end, false) == true
                if localOk and (id == nil or id == 0) then
                    return actor
                end
                if localOk and not controlled then
                    controlled = actor
                end
            end
        end
    end
    return controlled or fallback
end

local function itemBonus()
    local actor = playerActor()
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
    if perfect ~= seenPerfect or great ~= seenGreat or bonus ~= seenBonus then
        seenPerfect = perfect
        seenGreat = great
        seenBonus = bonus
        log(string.format("perfect %d great %d time %.1f rate %.3f bonus +%d", perfect, great, rawSeconds, rate, bonus))
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

local function hideLabel()
    pulseOn = false
    if isLive(label) then
        pcall(function() label:SetVisibility(1) end)
    end
end

local function removeStale(canvas)
    if not isLive(canvas) then
        return
    end
    local count = tonumber(safe(function() return canvas:GetChildrenCount() end, 0)) or 0
    for index = count - 1, 0, -1 do
        local child = asWidget(safe(function() return canvas:GetChildAt(index) end, nil))
        if isLive(child) and not sameObject(child, label) and widgetClass(child):find("TextBlock", 1, true) and isOurText(textOf(child)) then
            pcall(function() child:SetVisibility(1) end)
            pcall(function() canvas:RemoveChild(child) end)
        end
    end
end

local function styleLabel(hud, widget)
    if fontReady or not isLive(widget) then
        return
    end
    local gauge = isLive(hud) and hud.bp_parts_gauge_pc or nil
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
        fontReady = true
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
        if isLive(widget) and not sameObject(widget, label) and isOurText(textOf(widget)) then
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

local function placeOnHud(hud, widget)
    if not isLive(hud) or not isLive(widget) then
        return false
    end
    placeTries = placeTries + 1
    sweepStale()
    local gauge = hud.bp_parts_gauge_pc
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
        -- The portrait row stretches sideways, so a slot X offset stays put.
        -- Shift the text itself.
        pcall(function()
            widget:SetRenderTranslation({ X = NUDGE_X, Y = 0.0 })
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
        if x and w <= 280 and h <= 280 then
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

local function ensureLabel(hud)
    local hudKey = safe(function() return hud:GetAddress() end, hud)
    if isLive(label) and placedFor == hudKey and isLive(parentOf(label)) then
        if not fontReady then
            styleLabel(hud, label)
        end
        return label
    end
    placedFor = nil
    if not isLive(label) then
        local class = StaticFindObject("/Script/UMG.TextBlock")
        local widget = class and StaticConstructObject(class, hud) or nil
        if not isLive(widget) then
            return nil
        end
        label = widget
        fontReady = false
        pcall(function() widget:SetVisibility(4) end)
    end
    if placeOnHud(hud, label) then
        placedFor = hudKey
        styleLabel(hud, label)
        paintLeft = 8
    end
    return label
end

local function refresh()
    local hud = findHud()
    if not isLive(hud) or not shown(hud) then
        hideLabel()
        return
    end
    local bonus = itemBonus()
    if bonus == nil then
        hideLabel()
        return
    end
    local widget = ensureLabel(hud)
    if not isLive(widget) then
        pulseOn = false
        return
    end
    local text = bonusText(bonus)
    if textOf(widget) ~= text then
        setWidgetText(widget, text)
        if paintLeft < 3 then
            paintLeft = 3
        end
    end
    local flashing = tintLabel(widget, bonus)
    pulseOn = flashing
    pcall(function()
        widget:SetVisibility(4)
        widget:SetRenderOpacity(1)
    end)
    if paintLeft > 0 then
        paintLabel(widget)
        paintLeft = paintLeft - 1
    end
end

log("loaded")

local loopOk, loopErr = pcall(function()
    LoopAsync(200, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(refresh)
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

-- One hook for the life of the script. The portrait gauge tick is already on the
-- game thread, so this does not queue a new callback every flash step. It stops
-- the moment the word leaves Peerless, including when a rank decays.
local pulseLogged = false
local lastPulseDraw = 0
local pulseOk, pulseErr = pcall(function()
    RegisterHook("/Game/UI/02_battle/bp_parts_gauge_pc.bp_parts_gauge_pc_C:Tick", function()
        if not pulseOn or not isLive(label) then
            return
        end
        local now = os.clock()
        if now - lastPulseDraw < 0.05 then
            return
        end
        lastPulseDraw = now
        local ok, err = pcall(function()
            tintLabel(label, 2)
            paintLabel(label)
        end)
        if not ok and not pulseLogged then
            pulseLogged = true
            log("pulse " .. tostring(err))
        end
    end)
end)
if not pulseOk then
    log("pulse " .. tostring(pulseErr))
end
