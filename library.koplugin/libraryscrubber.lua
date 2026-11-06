--- A–Z strip down the right edge of the library grid.
-- Tap or drag a letter to jump to the first page whose sort key starts with
-- it. While the finger is down, only the strip and the letter bubble are
-- refreshed (a fast update). The grid is rebuilt once, when the finger lifts.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Core = require("librarycore")
local Screen = Device.screen

local C = Blitbuffer

local Scrubber = InputContainer:extend{
    name = "library_scrubber",
    view = nil,
    index = nil,       -- Core.scrubberIndex
    anchor = nil,      -- letter of the first item on the page now showing
    width = 120,
    height = 100,
    dpi = 300,
    screen_w = 0,
    screen_h = 0,
    bubble_letter = nil,
    DRAG_TICK = 0.06,  -- seconds between coalesced drag steps
}

local function textSize(face, s, bold, color, bg)
    local t = TextWidget:new{
        text = s, face = face, bold = bold,
        fgcolor = color or C.COLOR_BLACK,
        bgcolor = bg,
    }
    local sz = t:getSize()
    return t, sz
end

function Scrubber:init()
    self.letters = (self.index and self.index.letters) or Core.SCRUBBER_LETTERS
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local sw = self.screen_w
    local sh = self.screen_h
    if not sw or sw < 1 then sw = Screen:getWidth() end
    if not sh or sh < 1 then sh = Screen:getHeight() end
    self.screen_w, self.screen_h = sw, sh
    self.bubble = Core.scrubberBubbleRect(sw, sh, self.dpi)
    local range = function() return self.dimen end
    self.ges_events = {
        TapScrubber = { GestureRange:new{ ges = "tap", range = range } },
        PanScrubber = { GestureRange:new{ ges = "pan", range = range } },
        PanReleaseScrubber = { GestureRange:new{ ges = "pan_release", range = range } },
        SwipeScrubber = { GestureRange:new{ ges = "swipe", range = range } },
        HoldScrubber = { GestureRange:new{ ges = "hold", range = range } },
        HoldPanScrubber = { GestureRange:new{ ges = "hold_pan", range = range } },
        HoldReleaseScrubber = { GestureRange:new{ ges = "hold_release", range = range } },
    }
end

function Scrubber:getSize()
    return self.dimen
end

function Scrubber:stripRect()
    local d = self.dimen or {}
    return { x = d.x or 0, y = d.y or 0, w = d.w or self.width or 0, h = d.h or self.height or 0 }
end

function Scrubber:letterAt(y)
    local d = self.dimen or {}
    local top = d.y or 0
    local h = d.h or 0
    y = tonumber(y)
    if not y then return nil end
    -- A finger that slides off the top or bottom stays on the end letter.
    if h > 0 then
        if y < top then y = top end
        if y >= top + h then y = top + h - 1 end
    end
    return Core.scrubberLetterAt(y, top, h, self.letters)
end

function Scrubber:active(letter)
    local index = self.index
    return index and index.active and index.active[letter] or false
end

--- Nominal font size whose scaled height stays inside `px` on this dpi.
-- Font:getFace scales by the screen dpi, so the number we pass is the size
-- at KOReader's 167 dpi baseline.
function Scrubber:nominalSize(px, floor_size, cap)
    local dpi = tonumber(self.dpi) or 167
    if dpi < 1 then dpi = 167 end
    local n = math.floor((tonumber(px) or 0) * 167 / dpi)
    if floor_size and n < floor_size then n = floor_size end
    if cap and n > cap then n = cap end
    if n < 8 then n = 8 end
    return n
end

function Scrubber:paintStrip(bb, x, y)
    local d = self.dimen
    local w, h = d.w, d.h
    bb:paintRect(x, y, w, h, C.COLOR_WHITE)
    -- Hairline where the covers stop. The letters sit in a slim column on
    -- the right; the rest of the width is the touch margin.
    if bb.paintRect then
        local line = math.max(1, math.floor((tonumber(self.dpi) or 300) / 167))
        bb:paintRect(x, y, line, h, C.COLOR_GRAY_B)
    end
    local n = #self.letters
    if n < 1 or h < 1 then return end
    local slot = math.floor(h / n)
    local glyph_w = math.min(w, math.max(math.floor(w * 0.42), math.min(w, 48)))
    local glyph_x = x + w - glyph_w
    local face_px = self:nominalSize(math.max(10, slot - 4), 11, 18)
    local face = Font:getFace("cfont", face_px)
    local highlight = self.bubble_letter
    for i, letter in ipairs(self.letters) do
        local sy = y + math.floor((i - 1) * h / n)
        local sh = math.floor(i * h / n) - math.floor((i - 1) * h / n)
        local on = self:active(letter)
        local hot = highlight == letter
        local bg = C.COLOR_WHITE
        local fg = on and C.COLOR_BLACK or C.COLOR_GRAY_6
        if hot then
            bg = on and C.COLOR_BLACK or C.COLOR_GRAY_8
            fg = C.COLOR_WHITE
            local pad = math.max(1, math.floor(sh * 0.08))
            bb:paintRoundedRect(glyph_x + 2, sy + pad, glyph_w - 6, math.max(1, sh - 2 * pad), bg,
                math.floor(sh / 2))
        end
        local widget, sz = textSize(face, letter, on or hot, fg, hot and bg or C.COLOR_WHITE)
        local tx = glyph_x + math.floor((glyph_w - sz.w) / 2)
        local ty = sy + math.floor((sh - sz.h) / 2)
        widget:paintTo(bb, tx, ty)
        widget:free()
        if not hot and letter == self.anchor and on then
            local mark_w = math.max(4, math.floor(sz.w * 0.7))
            local mx = glyph_x + math.floor((glyph_w - mark_w) / 2)
            bb:paintRect(mx, ty + sz.h - 1, mark_w, math.max(1, math.floor(slot * 0.06)), C.COLOR_BLACK)
        end
    end
end

function Scrubber:paintBubble(bb)
    local letter = self.bubble_letter
    local r = self.bubble
    if not letter or not r then return end
    local radius = math.floor(r.w * 0.16)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, C.COLOR_WHITE, radius)
    local border = math.max(3, math.floor(r.w * 0.025))
    if bb.paintBorder then
        bb:paintBorder(r.x, r.y, r.w, r.h, border, C.COLOR_BLACK, radius)
    end
    local on = self:active(letter)
    local face = Font:getFace("cfont", self:nominalSize(math.floor(r.h * 0.52), 32, 96))
    local widget, sz = textSize(face, letter, true, on and C.COLOR_BLACK or C.COLOR_GRAY_6, C.COLOR_WHITE)
    widget:paintTo(bb, r.x + math.floor((r.w - sz.w) / 2), r.y + math.floor((r.h - sz.h) / 2))
    widget:free()
end

function Scrubber:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self:paintStrip(bb, x, y)
    if self.bubble_letter then self:paintBubble(bb) end
end

function Scrubber:pushRefresh(plan)
    self.last_refresh = plan
    if not plan or not UIManager.setDirty then return end
    for _, r in ipairs(plan.regions or {}) do
        local rect = Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }
        local mode = plan.mode
        UIManager:setDirty(self, function() return mode, rect end)
    end
end

function Scrubber:freeSnap()
    local snap = self._snap
    self._snap, self._snap_rect = nil, nil
    if snap and snap.free then pcall(function() snap:free() end) end
end

--- Put the covers back under the bubble.
function Scrubber:restoreSnap()
    local bb = Screen.bb
    local snap, r = self._snap, self._snap_rect
    self._snap, self._snap_rect = nil, nil
    if snap and r and bb and bb.blitFrom then
        pcall(function() bb:blitFrom(snap, r.x, r.y, 0, 0, r.w, r.h) end)
    end
    if snap and snap.free then pcall(function() snap:free() end) end
end

--- Remember the pixels under the bubble so the next letter can erase it
-- without repainting the covers.
function Scrubber:captureBubble()
    if self._snap then return end
    local bb = Screen.bb
    local r = self.bubble
    if not bb or not r or not bb.blitFrom or not Blitbuffer.new or not bb.getType then return end
    local ok, snap = pcall(Blitbuffer.new, r.w, r.h, bb:getType())
    if not ok or not snap then return end
    local copied = pcall(function() snap:blitFrom(bb, 0, 0, r.x, r.y, r.w, r.h) end)
    if not copied then
        if snap.free then snap:free() end
        return
    end
    self._snap = snap
    self._snap_rect = { x = r.x, y = r.y, w = r.w, h = r.h }
end

--- Repaint the strip and the bubble into the framebuffer. Does not mark the
-- library dirty, so the covers are not rebuilt.
function Scrubber:redrawDrag()
    local bb = Screen.bb
    if self.bubble_letter then
        if self._snap and self._snap_rect and bb and bb.blitFrom then
            local r = self._snap_rect
            pcall(function() bb:blitFrom(self._snap, r.x, r.y, 0, 0, r.w, r.h) end)
        else
            self:captureBubble()
        end
    else
        self:restoreSnap()
    end
    if bb and self.dimen then
        pcall(function() self:paintTo(bb, self.dimen.x, self.dimen.y) end)
    end
end

function Scrubber:applyDrag(pos)
    local letter = self:letterAt(pos and pos.y or -1)
    if letter == nil or letter == self.bubble_letter then return false end
    local previous = self.bubble_letter and self.bubble or nil
    self.bubble_letter = letter
    local plan = Core.scrubberDragRefresh(self:stripRect(), self.bubble, previous)
    self:redrawDrag()
    self:pushRefresh(plan)
    return true
end

function Scrubber:cancelTick()
    if self._tick and UIManager.unschedule then UIManager:unschedule(self._tick) end
    self._tick = nil
end

function Scrubber:flushDrag()
    local pos = self._pending
    self._pending = nil
    if pos then self:applyDrag(pos) end
end

--- A drag step. The first one runs at once; later ones in the same tick keep
-- only the latest finger position.
function Scrubber:dragTo(pos)
    self._drag = true
    self._pending = pos
    if self._tick then return end
    self:flushDrag()
    self._tick = function()
        self._tick = nil
        if self._drag and self._pending then self:dragTo(self._pending) end
    end
    if UIManager.scheduleIn then
        UIManager:scheduleIn(self.DRAG_TICK, self._tick)
    else
        self._tick = nil
    end
end

function Scrubber:jumpTo(letter)
    local page = Core.scrubberTargetPage(self.index, letter)
    local view = self.view
    if page and view and view.goToPage and view.page ~= page then
        view:goToPage(page)
        return true
    end
    return false
end

function Scrubber:endDrag()
    if not self._drag then return false end
    self:cancelTick()
    self:flushDrag()
    local letter = self.bubble_letter
    local bubble = self.bubble
    local strip = self:stripRect()
    self._drag = nil
    self.bubble_letter = nil
    self:restoreSnap()
    local page = Core.scrubberTargetPage(self.index, letter)
    local view = self.view
    local changed = page and view and view.page ~= page
    if changed then
        view:goToPage(page)
    else
        self:redrawDrag()
        self:pushRefresh(Core.scrubberReleaseRefresh(false, nil, strip, bubble))
    end
    return true
end

function Scrubber:onTapScrubber(_, ges)
    if self.view and self.view.tryOpenControlsFromTap and self.view:tryOpenControlsFromTap(ges) then
        return true
    end
    if self._drag then self:endDrag() end
    local letter = self:letterAt(ges and ges.pos and ges.pos.y)
    self:jumpTo(letter)
    return true
end

function Scrubber:onPanScrubber(_, ges)
    self:dragTo(ges and (ges.pos or ges.start_pos))
    return true
end

function Scrubber:onPanReleaseScrubber()
    return self:endDrag() or true
end

function Scrubber:onSwipeScrubber(_, ges)
    -- A downward swipe from the top of the strip (inside the Controls zone)
    -- opens Controls instead of jumping to a letter. LibraryView also checks
    -- this, but a swipe that starts on the strip is delivered here first.
    if not (self._drag) and self.view and self.view.tryOpenControls and self.view:tryOpenControls(ges) then
        return true
    end
    -- A quick flick is a swipe instead of a pan_release. Stay on the strip:
    -- do not also turn a page.
    local pos = ges and (ges.end_pos or ges.pos)
    if self._drag then
        if pos then self._pending = pos end
        self:endDrag()
        return true
    end
    local letter = self:letterAt(pos and pos.y)
    self:jumpTo(letter)
    return true
end

function Scrubber:onHoldScrubber(_, ges)
    self:dragTo(ges and ges.pos)
    return true
end

function Scrubber:onHoldPanScrubber(_, ges)
    self:dragTo(ges and (ges.pos or ges.start_pos))
    return true
end

function Scrubber:onHoldReleaseScrubber()
    return self:endDrag() or true
end

function Scrubber:onCloseWidget()
    self:cancelTick()
    self:freeSnap()
end

return Scrubber
