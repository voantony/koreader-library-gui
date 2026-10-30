--- Controls panel: swipe down from the Library's top-right corner for
-- brightness, warmth and a few round toggles. Loaded only when opened.
-- The layout and hit-testing live in librarycore (Core.controlsLayout).
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Core = require("librarycore")
local _ = require("gettext")
local Screen = Device.screen

local C = Blitbuffer
-- Material Design glyphs from KOReader's bundled nerdfonts/symbols.ttf
-- (a fallback font of "cfont", so plain TextWidgets render them).
local GLYPH = {
    brightness = "\u{EC98}", warmth = "\u{ECA5}", wifi = "\u{ECA8}", wifi_off = "\u{ECA9}",
    night = "\u{EC0D}", cover_sleep = "\u{E9E8}", rotate = "\u{EB74}", sleep = "\u{23FE}",
}

local Controls = InputContainer:extend{
    name = "LibraryControls",
    plugin = nil,
    covers_fullscreen = true,
}

function Controls:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.powerd = Device:getPowerDevice()
    self.sliders = self:makeSliders()
    self.toggles = self:makeToggles()
    self.L = Core.controlsLayout(self.dimen.w, self.dimen.h, #self.sliders, #self.toggles)
    local range = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        Hold = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

----------------------------------------------------------------------------
-- What the panel controls
----------------------------------------------------------------------------

function Controls:makeSliders()
    local p, out = self.powerd, {}
    if Device:hasFrontlight() then
        out[#out + 1] = {
            id = "brightness", label = _("Brightness"), glyph = GLYPH.brightness,
            min = p.fl_min, max = p.fl_max,
            get = function() return p:frontlightIntensity() end,
            set = function(v)
                if v <= p.fl_min then
                    p:turnOffFrontlight()
                else
                    p:setIntensity(v)
                    if p:isFrontlightOff() then p:turnOnFrontlight() end
                end
                p:updateResumeFrontlightState()
            end,
        }
    end
    if Device:hasNaturalLight() then
        out[#out + 1] = {
            id = "warmth", label = _("Warmth"), glyph = GLYPH.warmth,
            min = p.fl_warmth_min, max = p.fl_warmth_max,
            get = function() return p:toNativeWarmth(p:frontlightWarmth()) end,
            set = function(v) p:setWarmth(p:fromNativeWarmth(v)) end,
        }
    end
    return out
end

function Controls:makeToggles()
    local plugin = self.plugin
    local NetworkMgr = Device:hasWifiToggle() and require("ui/network/manager")
    local defs = {
        wifi = {
            label = _("Wi-Fi"),
            glyph = function(on) return on and GLYPH.wifi or GLYPH.wifi_off end,
            on = function() return NetworkMgr:isWifiOn() and true or false end,
            sub = function(on) return on and _("On") or _("Off") end,
            run = function()
                local done = function() self:refresh() end
                if NetworkMgr:isWifiOn() then NetworkMgr:toggleWifiOff(done, true)
                else NetworkMgr:toggleWifiOn(done, nil, true) end
                self:refresh()
            end,
        },
        night = {
            label = _("Night mode"), glyph = GLYPH.night,
            on = function() return G_reader_settings:isTrue("night_mode") end,
            sub = function(on) return on and _("On") or _("Off") end,
            run = function()
                plugin:sendUIEvent(Event:new("ToggleNightMode"))
                self:refresh("full")
            end,
        },
        cover_sleep = {
            label = _("Cover sleep"), glyph = GLYPH.cover_sleep,
            on = function() return plugin:sleepCoverIsOn() end,
            sub = function(on) return on and _("Book cover") or _("Off") end,
            run = function() plugin:toggleSleepCover(); self:refresh() end,
        },
        rotate = {
            label = _("Rotate"), glyph = GLYPH.rotate,
            on = function() return false end,
            sub = function() return Screen:getScreenMode() == "landscape" and _("Landscape") or _("Portrait") end,
            run = function()
                self:close()
                UIManager:nextTick(function() plugin:rotateLibrary() end)
            end,
        },
        sleep = {
            label = _("Sleep"), glyph = GLYPH.sleep,
            on = function() return false end,
            sub = function() return _("Now") end,
            run = function()
                self:close()
                UIManager:scheduleIn(0.3, function() UIManager:suspend() end)
            end,
        },
    }
    local ids = Core.controlsToggles({
        wifi = NetworkMgr and true or false,
        night = true,
        cover_sleep = true,
        rotate = not Device:isAlwaysPortrait(),
        bluetooth = false, -- KOReader has no Bluetooth API on any device
        sleep = Device:canSuspend(),
    })
    local out = {}
    for _, id in ipairs(ids) do
        local t = defs[id]; t.id = id
        out[#out + 1] = t
    end
    return out
end

----------------------------------------------------------------------------
-- Painting
----------------------------------------------------------------------------

local function text(bb, s, x, y, size, opts)
    opts = opts or {}
    local t = TextWidget:new{ text = s, face = Font:getFace("cfont", size), bold = opts.bold,
        fgcolor = opts.color or C.COLOR_BLACK, bgcolor = opts.bg }
    local sz = t:getSize()
    if opts.align == "center" then x = x - math.floor(sz.w / 2)
    elseif opts.align == "right" then x = x - sz.w end
    if opts.valign == "center" then y = y - math.floor(sz.h / 2) end
    t:paintTo(bb, x, y)
    t:free()
end

function Controls:statusText()
    local parts = {}
    if Device:hasWifiToggle() then
        local on = require("ui/network/manager"):isWifiOn()
        parts[#parts + 1] = (on and GLYPH.wifi or GLYPH.wifi_off) .. "  " .. (on and _("Wi-Fi on") or _("Wi-Fi off"))
    end
    if Device:hasBattery() then
        parts[#parts + 1] = string.format("%d %%", self.powerd:getCapacity())
    end
    return table.concat(parts, "   \u{00B7}   ")
end

function Controls:paintSlider(bb, s, row)
    local L = self.L
    local v = s.get()
    text(bb, s.glyph, L.left, row.label_y, 20)
    text(bb, s.label, L.left + math.floor(66 * L.u), row.label_y + math.floor(4 * L.u), 17, { bold = true })
    text(bb, string.format("%d / %d", v, s.max), L.right, row.label_y + math.floor(8 * L.u), 14,
        { align = "right", color = C.COLOR_GRAY_4 })
    for _, b in ipairs({ { row.minus, "\u{2212}" }, { row.plus, "+" } }) do
        local c = b[1]
        bb:paintCircle(c.cx, c.cy, c.r, C.COLOR_GRAY_E)
        bb:paintCircle(c.cx, c.cy, c.r, C.COLOR_GRAY_7, math.max(2, math.floor(3 * L.u)))
        text(bb, b[2], c.cx, c.cy, 22, { align = "center", valign = "center", bold = true, bg = C.COLOR_GRAY_E })
    end
    local t = row.track
    local rr = math.floor(t.h / 2)
    bb:paintRoundedRect(t.x, t.y, t.w, t.h, C.COLOR_GRAY_D, rr)
    local fw = math.floor(t.w * Core.sliderFraction(v, s.min, s.max))
    if fw > 0 then bb:paintRoundedRect(t.x, t.y, math.max(fw, t.h), t.h, C.COLOR_GRAY_2, rr) end
    local steps = s.max - s.min
    if steps > 1 and steps <= 40 then
        for i = 1, steps - 1 do
            local x = t.x + math.floor(t.w * i / steps)
            if x > t.x + fw + row.knob_r then
                bb:paintRect(x - 1, t.y + math.floor(t.h / 2) - 4, 3, 8, C.COLOR_GRAY_9)
            end
        end
    end
    local cy = t.y + rr
    bb:paintCircle(t.x + fw, cy, row.knob_r, C.COLOR_WHITE)
    bb:paintCircle(t.x + fw, cy, row.knob_r, C.COLOR_GRAY_2, math.max(3, math.floor(5 * L.u)))
end

function Controls:paintToggle(bb, t, pos)
    local on = t.on()
    local glyph = type(t.glyph) == "function" and t.glyph(on) or t.glyph
    local bg = on and C.COLOR_GRAY_2 or C.COLOR_GRAY_E
    bb:paintCircle(pos.cx, pos.cy, pos.r, bg)
    if not on then bb:paintCircle(pos.cx, pos.cy, pos.r, C.COLOR_GRAY_7, math.max(2, math.floor(3 * self.L.u))) end
    text(bb, glyph, pos.cx, pos.cy, 30, { align = "center", valign = "center",
        color = on and C.COLOR_WHITE or C.COLOR_BLACK, bg = bg })
    text(bb, t.label, pos.cx, pos.label_y, 15, { align = "center", bold = true })
    text(bb, t.sub(on), pos.cx, pos.sub_y, 12, { align = "center", color = C.COLOR_GRAY_5 })
end

function Controls:paintTo(bb, x, y)
    local W, H, L = self.dimen.w, self.dimen.h, self.L
    -- The Library, dimmed. We paint it ourselves (and claim the whole screen)
    -- so repeated refreshes never darken it twice.
    local view = self.plugin and self.plugin.shared and self.plugin.shared.view
    if view then view:paintTo(bb, 0, 0) else bb:paintRect(0, 0, W, H, C.COLOR_WHITE) end
    bb:darkenRect(0, 0, W, H, 0.45)
    local p, r = L.panel, L.radius
    local sh = math.floor(10 * L.u)
    bb:paintRoundedRect(p.x + sh, p.y + sh, p.w, p.h, C.COLOR_GRAY_5, r)
    bb:paintRoundedRect(p.x, p.y, p.w, p.h, C.COLOR_WHITE, r)
    bb:paintBorder(p.x, p.y, p.w, p.h, math.max(2, math.floor(3 * L.u)), C.COLOR_GRAY_7, r)
    text(bb, _("Controls"), L.left, L.header_y, 22, { bold = true })
    text(bb, self:statusText(), L.right, L.header_y + math.floor(10 * L.u), 14, { align = "right", color = C.COLOR_GRAY_4 })
    for i, s in ipairs(self.sliders) do self:paintSlider(bb, s, L.sliders[i]) end
    if L.divider_y and #self.toggles > 0 then
        bb:paintRect(L.left, L.divider_y, L.right - L.left, math.max(2, math.floor(3 * L.u)), C.COLOR_GRAY_D)
    end
    for i, t in ipairs(self.toggles) do self:paintToggle(bb, t, L.toggles[i]) end
    local hd = L.handle
    bb:paintRoundedRect(hd.x, hd.y, hd.w, hd.h, C.COLOR_GRAY_B, math.floor(hd.h / 2))
end

function Controls:panelRect()
    local p = self.L.panel
    local sh = math.floor(10 * self.L.u)
    return Geom:new{ x = p.x, y = 0, w = p.w + sh, h = p.y + p.h + sh }
end

--- Repaint, refreshing only the panel's area (a full flash for night mode).
function Controls:refresh(mode)
    local rect = mode ~= "full" and self:panelRect() or nil
    UIManager:setDirty(self, function() return mode or "ui", rect end)
end

----------------------------------------------------------------------------
-- Gestures
----------------------------------------------------------------------------

function Controls:setSlider(i, v, fast)
    local s = self.sliders[i]
    if v < s.min then v = s.min elseif v > s.max then v = s.max end
    if v == s.get() then return end
    s.set(v)
    self:refresh(fast and "fast" or "ui")
end

function Controls:sliderAt(i, x)
    local t = self.L.sliders[i].track
    local s = self.sliders[i]
    return Core.sliderValue(x, t.x, t.w, s.min, s.max)
end

function Controls:onTap(_, ges)
    local what, i = Core.controlsHit(self.L, ges.pos.x, ges.pos.y)
    if not what then
        self:close()
    elseif what == "minus" then
        self:setSlider(i, self.sliders[i].get() - 1)
    elseif what == "plus" then
        self:setSlider(i, self.sliders[i].get() + 1)
    elseif what == "slider" then
        self:setSlider(i, self:sliderAt(i, ges.pos.x))
    elseif what == "toggle" then
        self.toggles[i].run()
    end
    return true
end

function Controls:onSwipe(_, ges)
    local what, i = Core.controlsHit(self.L, ges.pos.x, ges.pos.y)
    if what == "slider" and (ges.direction == "east" or ges.direction == "west") then
        self:setSlider(i, self:sliderAt(i, ges.end_pos and ges.end_pos.x or ges.pos.x))
    elseif ges.direction == "north" or not what then
        self:close()
    end
    return true
end

function Controls:onPan(_, ges)
    local what, i = Core.controlsHit(self.L, ges.start_pos.x, ges.start_pos.y)
    if what == "slider" then
        self._dragged = true
        self:setSlider(i, self:sliderAt(i, ges.pos.x), true)
    end
    return true
end

-- Drags refresh fast (and a bit ghosty); clean up once the finger lifts.
function Controls:onPanRelease()
    if self._dragged then self._dragged = nil; self:refresh() end
    return true
end

function Controls:onHold() return true end

function Controls:onClose()
    self:close()
    return true
end

function Controls:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self, "ui")
end

function Controls:onCloseWidget()
    if self.plugin then self.plugin:onControlsClosed(self) end
end

return Controls
