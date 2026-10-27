-- Mount UI
-- Personal HUD edits for the mounted dash icons.
-- The mounted button guide stays hidden. Nothing in this script shows it again.
-- The mash prompt is a different widget and is left alone.
-- Moves the dash icons under the Musou bar, beside the horse icon.
-- Compact layout: X 496, bottom margin 0, spacing 60 (native 108).
-- Solo row height stays 108. Two local players add X -90.
-- Their icons are shorter than that row and sit on its bottom edge.
-- The split row uses the icon height, and that edge moves up by the
-- leftover height. Until the horse icon can be measured, the row starts
-- 17 higher than solo.

local MOD = "Mount UI"
local POSITION_X = 496.0
local BOTTOM_MARGIN = 0.0
local SPACING = 60.0
local NATIVE_SPACING = 108.0
local ICON_HEIGHT = 108.0
local SPLIT_X = -90.0
local SPLIT_Y = 17.0
local PAD = (SPACING - NATIVE_SPACING) * 0.5
local PLAYER_CACHE_SEC = 0.25

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

local function objectName(obj)
    local full = safe(function() return obj:GetFullName() end, "") or ""
    local short = safe(function()
        return obj:GetClass():GetName()
    end, "") or ""
    if full == "" then
        return short
    end
    if short == "" then
        return full
    end
    return full .. " " .. short
end

local function parentOf(widget)
    if not isLive(widget) then
        return nil
    end
    local direct = asWidget(safe(function() return widget:GetParent() end, nil))
    if direct and not sameObject(direct, widget) then
        return direct
    end
    local slot = safe(function() return widget.Slot end, nil)
    if not isLive(slot) then
        return nil
    end
    local fromSlot = asWidget(safe(function() return slot.Parent end, nil))
    if fromSlot and not sameObject(fromSlot, widget) then
        return fromSlot
    end
    return nil
end

-- The gauge is nested inside the HUD. The HUD user widget sits outside the
-- panel parent chain, on the widget tree's outer.
local function hostOf(widget)
    local current = widget
    for _ = 1, 12 do
        if not isLive(current) then
            return nil
        end
        local name = objectName(current)
        if string.find(name, "Default__", 1, true) then
            return nil
        end
        if isLive(safe(function() return current.BP_parts_battle_horse_boost end, nil)) then
            return current
        end
        local parent = parentOf(current)
        if parent then
            current = parent
        else
            local outer = asWidget(safe(function() return current:GetOuter() end, nil))
            if outer and not sameObject(outer, current) then
                current = outer
            else
                return nil
            end
        end
    end
    return nil
end

local function pointAnchors(x, y)
    return {
        Minimum = { X = x, Y = y },
        Maximum = { X = x, Y = y },
    }
end

local function isCanvasSlot(slot)
    if not isLive(slot) then
        return false
    end
    return string.find(objectName(slot), "CanvasPanelSlot", 1, true) ~= nil
end

local function isGauge(widget)
    local name = objectName(widget)
    return string.find(name, "gauge_horse_boost", 1, true) ~= nil
        or string.find(name, "BattleHorseBoostGauge", 1, true) ~= nil
end

local function gaugeChildren(box)
    local found = {}
    local count = asInt(safe(function() return box:GetChildrenCount() end, 0)) or 0
    if count < 0 then
        count = 0
    end
    for index = 0, count - 1 do
        local child = asWidget(safe(function() return box:GetChildAt(index) end, nil))
        if isLive(child) and isGauge(child) then
            found[#found + 1] = child
        end
    end
    return found
end

local function applyPad(slot)
    local margin = { Left = PAD, Top = 0.0, Right = PAD, Bottom = 0.0 }
    local ok = pcall(function()
        slot:SetPadding(margin)
    end)
    if ok then
        return true
    end
    return pcall(function()
        local padding = slot.Padding
        padding.Left = PAD
        padding.Top = 0.0
        padding.Right = PAD
        padding.Bottom = 0.0
        slot.Padding = padding
    end)
end

local slate = nil

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

local function vec2(value)
    if type(value) ~= "userdata" and type(value) ~= "table" then
        return nil, nil
    end
    local x = tonumber(value.X) or tonumber(value.x)
    local y = tonumber(value.Y) or tonumber(value.y)
    if x and y then
        return x, y
    end
    return nil, nil
end

-- Bottom of the horse icon, and the canvas height, in that canvas's space.
-- A bottom-anchored slot uses y = bottom - height, which is negative when
-- the icon sits above the canvas bottom.
local function horseBottom(canvas, horse)
    local lib = slateLib()
    if not isLive(lib) or not isLive(canvas) or not isLive(horse) then
        return nil, nil
    end
    local okHorse, horseGeo = pcall(function() return horse:GetCachedGeometry() end)
    local okCanvas, canvasGeo = pcall(function() return canvas:GetCachedGeometry() end)
    if not okHorse or not okCanvas or horseGeo == nil or canvasGeo == nil then
        return nil, nil
    end
    local okHorseSize, horseSize = pcall(function() return lib:GetLocalSize(horseGeo) end)
    local okCanvasSize, canvasSize = pcall(function() return lib:GetLocalSize(canvasGeo) end)
    if not okHorseSize or not okCanvasSize then
        return nil, nil
    end
    local horseW, horseH = vec2(horseSize)
    local _, canvasH = vec2(canvasSize)
    if not horseW or horseW < 2 or not horseH or horseH < 2 or not canvasH or canvasH < 2 then
        return nil, nil
    end
    local okFar, far = pcall(function()
        return lib:LocalToAbsolute(horseGeo, { X = 0.0, Y = horseH })
    end)
    if not okFar or far == nil then
        return nil, nil
    end
    local okLocal, localPos = pcall(function()
        return lib:AbsoluteToLocal(canvasGeo, far)
    end)
    if not okLocal or localPos == nil then
        return nil, nil
    end
    local _, bottom = vec2(localPos)
    if not bottom then
        return nil, nil
    end
    return bottom, canvasH
end

-- Slot size, then desired size, then the brush. Values outside a HUD
-- icon are ignored so a raw texture size does not become the row height.
local function spanHeight(widget)
    if not isLive(widget) then
        return nil
    end
    local slot = safe(function() return widget.Slot end, nil)
    if isLive(slot) then
        local _, h = vec2(safe(function() return slot:GetSize() end, nil))
        if h and h >= 8 and h <= 220 then
            return h
        end
    end
    local _, desired = vec2(safe(function() return widget:GetDesiredSize() end, nil))
    if desired and desired >= 8 and desired <= 220 then
        return desired
    end
    local _, brush = vec2(safe(function() return widget.Brush.ImageSize end, nil))
    if brush and brush >= 8 and brush <= 220 then
        return brush
    end
    return nil
end

local function visualScale(widget)
    local transform = safe(function() return widget:GetRenderTransform() end, nil)
    if type(transform) ~= "userdata" and type(transform) ~= "table" then
        return nil
    end
    local _, y = vec2(transform.Scale)
    if y and y > 0.2 and y < 0.98 then
        return y
    end
    return nil
end

local function applyCanvas(slot, anchorX, anchorY, alignX, alignY, x, y, w, h)
    if not isCanvasSlot(slot) then
        return false, "type"
    end
    local function place(useOffsets)
        slot:SetAutoSize(false)
        slot:SetAnchors(pointAnchors(anchorX, anchorY))
        slot:SetAlignment({ X = alignX, Y = alignY })
        if useOffsets then
            slot:SetOffsets({ Left = x, Top = y, Right = w, Bottom = h })
        else
            slot:SetPosition({ X = x, Y = y })
            slot:SetSize({ X = w, Y = h })
        end
        slot:SetAutoSize(false)
    end
    if pcall(function() place(false) end) then
        return true
    end
    if pcall(function() place(true) end) then
        return true
    end
    return false, "update"
end

-- PLAYER1 is the first local player. A name like "PLAYER1" must not be
-- read as the digit 1.
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
    if string.find(text, "PLAYER1", 1, true) then
        return 0
    end
    if string.find(text, "PLAYER2", 1, true) then
        return 1
    end
    if string.match(text, "^%-?%d+$") then
        return tonumber(text)
    end
    return nil
end

local playerCache = {}
local playerCacheAt = -1
local splitOn = false

local function refreshPlayers()
    local now = os.clock()
    if playerCacheAt >= 0 and now - playerCacheAt < PLAYER_CACHE_SEC then
        return
    end
    playerCacheAt = now
    playerCache = {}
    local loose = nil
    local all = FindAllOf("AppCharacterPlayer") or {}
    for _, actor in ipairs(all) do
        if isLive(actor) then
            local name = safe(function() return actor:GetFullName() end, "") or ""
            if not string.find(name, "Default__", 1, true) then
                local controlled = safe(function()
                    return actor:IsLocallyControlled()
                end, false) == true
                if controlled then
                    local id = playerId(actor)
                    if id == 0 or id == 1 then
                        playerCache[id] = actor
                    elseif not loose then
                        loose = actor
                    end
                end
            end
        end
    end
    if not isLive(playerCache[0]) and isLive(loose) then
        playerCache[0] = loose
    end
    splitOn = isLive(playerCache[0]) and isLive(playerCache[1])
end

local loggedLayout = false
local loggedHorse = false
local loggedSize = false
local loggedH = nil
local sizeKnown = false
-- Both halves share this once either horse icon has a real height.
-- A later pass with no icon must not put that half back at 108.
local sharedIconH = nil
local loggedHide = false
local loggedSlot = false
local loggedPad = false
local loggedBox = false
local loggedEmpty = false

-- The game fades this widget in when you mount. Collapsing it makes that
-- fade start over. Stop the fade and leave the widget at zero size.
local function forceHide(guide)
    if not isLive(guide) then
        return false
    end
    return pcall(function()
        guide:StopAllAnimations()
        guide:SetRenderOpacity(0)
        guide:SetRenderScale({ X = 0.0, Y = 0.0 })
    end)
end

local function syncGuide(host)
    local guide = asWidget(safe(function() return host.BP_parts_battle_guide_interact end, nil))
    if not isLive(guide) then
        return false
    end
    local ok = forceHide(guide)
    if ok and not loggedHide then
        loggedHide = true
        log("interact guide hidden")
    end
    return ok
end

local function layoutBoost(host)
    if not isLive(host) then
        return
    end
    refreshPlayers()
    local boost = asWidget(safe(function() return host.BP_parts_battle_horse_boost end, nil))
    if not isLive(boost) then
        if string.find(objectName(host), "horse_boost", 1, true) then
            boost = host
        else
            return
        end
    end
    local box = asWidget(safe(function() return boost.HorizontalBox end, nil))
    if not isLive(box) then
        if not loggedBox then
            loggedBox = true
            log("dash row missing")
        end
        return
    end
    local gauges = gaugeChildren(box)
    local count = #gauges
    if count < 1 then
        if not loggedEmpty then
            loggedEmpty = true
            log("dash row empty")
        end
        return
    end
    local padded = true
    for _, gauge in ipairs(gauges) do
        local slot = safe(function() return gauge.Slot end, nil)
        if isLive(slot) then
            if not applyPad(slot) then
                padded = false
            end
        end
    end
    if not padded and not loggedPad then
        loggedPad = true
        log("dash icon padding was not applied")
    end
    local splitX = 0.0
    local splitY = 0.0
    if splitOn then
        splitX = SPLIT_X
        splitY = SPLIT_Y
        -- The spur widget itself has no horse icon. Walking its parents
        -- during stage load crashed, and writing the tall row from here
        -- put the split placement back. Leave the slot alone.
        local pc = asWidget(safe(function() return host.bp_parts_gauge_pc_multi end, nil))
        if not isLive(pc) then
            pc = asWidget(safe(function() return host.bp_parts_gauge_pc end, nil))
        end
        if not isLive(pc) and not sharedIconH then
            return
        end
    end
    local width = SPACING * count
    local x = POSITION_X + splitX
    local y = -(BOTTOM_MARGIN + splitY)
    local horseAligned = false
    if splitOn then
        local gauge = asWidget(safe(function() return host.bp_parts_gauge_pc_multi end, nil))
        if not isLive(gauge) then
            gauge = asWidget(safe(function() return host.bp_parts_gauge_pc end, nil))
        end
        local horse = isLive(gauge) and asWidget(safe(function() return gauge.icon_horse_call end, nil)) or nil
        local canvas = asWidget(safe(function() return boost.Slot.Parent end, nil))
        local bottom, canvasH = horseBottom(canvas, horse)
        if bottom and canvasH then
            local aligned = bottom - canvasH
            if aligned > -400 and aligned < 80 then
                y = aligned
                horseAligned = true
                if not loggedHorse then
                    loggedHorse = true
                    loggedLayout = false
                end
            end
        end
    end
    local rowH = ICON_HEIGHT
    if splitOn then
        local icon = gauges[1]
        local image = asWidget(safe(function() return icon.Image_base end, nil))
        if not isLive(image) then
            image = asWidget(safe(function() return icon.Image_gauge end, nil))
        end
        local imageH = spanHeight(image)
        local gaugeH = spanHeight(icon)
        local pc = asWidget(safe(function() return host.bp_parts_gauge_pc_multi end, nil))
        if not isLive(pc) then
            pc = asWidget(safe(function() return host.bp_parts_gauge_pc end, nil))
        end
        local horseIcon = isLive(pc) and asWidget(safe(function() return pc.icon_horse_call end, nil)) or nil
        local horseH = spanHeight(horseIcon)
        local scale = visualScale(icon) or visualScale(boost)
        local scaleH = scale and (ICON_HEIGHT * scale) or nil
        local picked = nil
        local function consider(h)
            if h and h >= 16 and h < ICON_HEIGHT - 4 and (not picked or h < picked) then
                picked = h
            end
        end
        consider(imageH)
        consider(gaugeH)
        consider(horseH)
        if not picked then
            consider(scaleH)
        end
        if not picked and sharedIconH then
            picked = sharedIconH
        end
        if picked then
            sharedIconH = picked
            rowH = picked
            -- Bottom anchor keeps a shorter slot on the old edge. The icons
            -- sit on that edge, so the edge has to move up with them.
            if not horseAligned then
                y = y - (ICON_HEIGHT - rowH)
            end
            for _, gauge in ipairs(gauges) do
                local slot = safe(function() return gauge.Slot end, nil)
                if isLive(slot) then
                    pcall(function() slot:SetVerticalAlignment(3) end)
                end
            end
        end
        local measured = imageH or gaugeH or horseH or scale
        if not loggedSize or (loggedH and math.abs(loggedH - rowH) > 1) or (measured and not sizeKnown) then
            loggedSize = true
            sizeKnown = sizeKnown or measured ~= nil
            loggedH = rowH
            loggedLayout = false
            log(string.format(
                "spur box image %.0f gauge %.0f horse %.0f scale %.2f",
                imageH or -1, gaugeH or -1, horseH or -1, scale or 0))
        end
    end
    local inner = safe(function() return box.Slot end, nil)
    local outer = safe(function() return boost.Slot end, nil)
    local innerOk, innerWhy = applyCanvas(inner, 0.5, 0.5, 0.5, 0.5, 0.0, 0.0, width, rowH)
    local outerOk, outerWhy = applyCanvas(outer, 0.0, 1.0, 0.0, 1.0, x, y, width, rowH)
    if innerOk and outerOk then
        if not loggedLayout then
            loggedLayout = true
            log(string.format(
                "dash icons x %.0f y %.0f h %.0f spacing %.0f count %d",
                x, y, rowH, SPACING, count))
        end
        pcall(function()
            boost:InvalidateLayoutAndVolatility()
        end)
        return
    end
    if not loggedSlot then
        loggedSlot = true
        if innerWhy == "type" or outerWhy == "type" then
            log("dash icon slot is not a canvas slot")
        else
            log("dash icon slot update failed")
        end
    end
end

local hostByGauge = {}

local function fallbackHost(widget)
    local name = objectName(widget)
    if string.find(name, "gauge_pc_multi", 1, true) then
        local splits = FindAllOf("BP_parts_2d_hud_split_screen_C") or {}
        for _, split in ipairs(splits) do
            if isLive(split) then
                local gauge = asWidget(safe(function() return split.bp_parts_gauge_pc_multi end, nil))
                if sameObject(gauge, widget) then
                    return split
                end
            end
        end
        return nil
    end
    local manager = FindFirstOf("BP_Battle_HUD_Manager_C")
    if isLive(manager) then
        local hud = asWidget(manager.Battle2DHUD)
        if not isLive(hud) then
            hud = asWidget(manager.Battle2DHUDWidget)
        end
        if isLive(hud) then
            return hud
        end
    end
    return FindFirstOf("BP_2d_hud_C")
end

local function resolveHost(widget)
    local addr = safe(function() return tostring(widget:GetAddress()) end, nil)
    local cached = addr and hostByGauge[addr] or nil
    if isLive(cached) then
        return cached
    end
    local host = hostOf(widget)
    if not isLive(host) then
        host = fallbackHost(widget)
    end
    if addr and isLive(host) then
        hostByGauge[addr] = host
    end
    return host
end

local tickLogged = false

local function onGaugeTick(self)
    local widget = asWidget(self)
    if not isLive(widget) then
        return
    end
    if string.find(objectName(widget), "Default__", 1, true) then
        return
    end
    local host = resolveHost(widget)
    if not isLive(host) then
        return
    end
    layoutBoost(host)
    syncGuide(host)
end

local function onTick(self)
    local ok, err = pcall(onGaugeTick, self)
    if not ok and not tickLogged then
        tickLogged = true
        log("tick " .. tostring(err))
    end
end

local function isDefault(obj)
    return string.find(objectName(obj), "Default__", 1, true) ~= nil
end

local function applyHost(host)
    if not isLive(host) or isDefault(host) then
        return
    end
    layoutBoost(host)
    syncGuide(host)
end

-- The gauge tick function is not loaded with the main menu. Drop Viewer waits
-- until the widget class exists, then registers. This pass also edits the HUD
-- directly so a missed hook still moves the icons.
local function applyLive()
    local manager = FindFirstOf("BP_Battle_HUD_Manager_C")
    if isLive(manager) then
        applyHost(asWidget(manager.Battle2DHUD))
        applyHost(asWidget(manager.Battle2DHUDWidget))
    end
    applyHost(FindFirstOf("BP_2d_hud_C"))
    applyHost(FindFirstOf("BP_2d_hud_multi_C"))
    local splits = FindAllOf("BP_parts_2d_hud_split_screen_C") or {}
    for _, split in ipairs(splits) do
        applyHost(split)
    end
    local boosts = FindAllOf("BP_parts_battle_horse_boost_C") or {}
    for _, boost in ipairs(boosts) do
        if isLive(boost) and not isDefault(boost) then
            layoutBoost(boost)
        end
    end
end

local PC_PATHS = {
    "/Game/UI/02_battle/bp_parts_gauge_pc.bp_parts_gauge_pc_C:Tick",
    "/Game/UI/02_battle/BP_parts_gauge_pc.BP_parts_gauge_pc_C:Tick",
}
local MULTI_PATHS = {
    "/Game/UI/02_battle/bp_parts_gauge_pc_multi.bp_parts_gauge_pc_multi_C:Tick",
    "/Game/UI/02_battle/BP_parts_gauge_pc_multi.BP_parts_gauge_pc_multi_C:Tick",
}
local FADE_PATHS = {
    "/Game/UI/02_battle/BP_parts_battle_guide_interact.BP_parts_battle_guide_interact_C:FadeIn",
    "/Game/UI/02_battle/bp_parts_battle_guide_interact.bp_parts_battle_guide_interact_C:FadeIn",
}

local hooked = {}

local function classReady(names)
    for _, name in ipairs(names) do
        if isLive(FindFirstOf(name)) then
            return true
        end
    end
    return false
end

local function tryRegister(paths)
    for _, path in ipairs(paths) do
        local ok = pcall(function()
            RegisterHook(path, function()
            end, function(self)
                onTick(self)
            end)
        end)
        if ok then
            log("hooked " .. path)
            return true
        end
    end
    return false
end

local function onGuideFadeIn(self)
    local guide = asWidget(self)
    if not isLive(guide) or isDefault(guide) then
        return
    end
    forceHide(guide)
end

local function tryRegisterFade()
    for _, path in ipairs(FADE_PATHS) do
        local ok = pcall(function()
            RegisterHook(path, function()
            end, function(self)
                local hideOk, err = pcall(onGuideFadeIn, self)
                if not hideOk and not hooked.fadeLogged then
                    hooked.fadeLogged = true
                    log("guide " .. tostring(err))
                end
            end)
        end)
        if ok then
            log("hooked " .. path)
            return true
        end
    end
    return false
end

local function ensureHooks()
    if not hooked.pc and classReady({ "bp_parts_gauge_pc_C", "BP_parts_gauge_pc_C" }) then
        if tryRegister(PC_PATHS) then
            hooked.pc = true
        elseif not hooked.pcLogged then
            hooked.pcLogged = true
            log("player gauge tick hook failed")
        end
    end
    if not hooked.multi and classReady({ "bp_parts_gauge_pc_multi_C", "BP_parts_gauge_pc_multi_C" }) then
        if tryRegister(MULTI_PATHS) then
            hooked.multi = true
        elseif not hooked.multiLogged then
            hooked.multiLogged = true
            log("split gauge tick hook failed")
        end
    end
    if not hooked.fade and classReady({ "BP_parts_battle_guide_interact_C", "bp_parts_battle_guide_interact_C" }) then
        if tryRegisterFade() then
            hooked.fade = true
        elseif not hooked.fadeMissLogged then
            hooked.fadeMissLogged = true
            log("guide fade hook failed")
        end
    end
end

local loopLogged = false
local loopOk, loopErr = pcall(function()
    LoopAsync(200, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                ensureHooks()
                applyLive()
            end)
            if not ok and not loopLogged then
                loopLogged = true
                log("refresh " .. tostring(err))
            end
        end)
    end)
end)
if not loopOk then
    log("loop " .. tostring(loopErr))
end

log("loaded")
