--- A–Z strip down the right edge of the library grid.
-- Tap or drag a letter to jump to the first page whose sort key starts with
-- it. While the finger is down, only the strip and the letter bubble are
-- refreshed (a fast update). Letting go always clears the bubble and asks
-- for a UI refresh of the rectangle under it, then rebuilds the grid once.
-- A touch that starts on the strip is never offered to LiveLight.
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
    -- If no release event arrives, hide the bubble anyway.
    BUBBLE_TIMEOUT = 1.0,
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
    -- `letters` is the full alphabet the finger scrubs. Paint may show
    -- only every few of them, with dots, when the column is short.
    if not self.letters then
        self.letters = (self.index and self.index.letters) or Core.SCRUBBER_LETTERS
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local sw = self.screen_w
    local sh = self.screen_h
    if not sw or sw < 1 then sw = Screen:getWidth() end
    if not sh or sh < 1 then sh = Screen:getHeight() end
    self.screen_w, self.screen_h = sw, sh
    self.bubble = Core.scrubberBubbleRect(sw, sh, self.dpi)
    if not self.hit_extra then
        self.hit_extra = Core.scrubberGutterHit(self.dpi)
    end
    local range = function() return self:hitRect() end
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

--- Where a finger counts as on the strip. The painted column, plus a
-- gutter overlap on the left and the rest of the way to the screen edge.
function Scrubber:hitRect()
    local d = self.dimen or {}
    local x0 = math.floor(d.x or 0)
    local w = math.floor(d.w or 0)
    local extra = math.floor(tonumber(self.hit_extra) or 0)
    if extra < 0 then extra = 0 end
    local x = x0 - extra
    if x < 0 then x = 0 end
    local right = x0 + w
    local edge = math.floor(tonumber(self.screen_w) or 0)
    if edge > 0 and x0 > edge * 0.5 and right < edge then
        right = edge
    end
    return Core.gestureRect{
        x = x,
        y = math.floor(d.y or 0),
        w = math.max(0, right - x),
        h = math.floor(d.h or 0),
    }
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
    if not d or not bb then return end
    local w, h = tonumber(d.w) or 0, tonumber(d.h) or 0
    if w < 1 or h < 1 then return end
    bb:paintRect(x, y, w, h, C.COLOR_WHITE)
    -- Hairline where the covers stop. The letters sit just to its right.
    -- The wider hit area is not painted; it overlaps the gutter and the edge.
    local line = math.max(1, math.floor((tonumber(self.dpi) or 300) / 167))
    if bb.paintRect then
        bb:paintRect(x, y, line, h, C.COLOR_GRAY_B)
    end
    local marks = Core.scrubberMarks(self.letters, h, Core.scrubberMinSlot(self.dpi))
    local n = #marks
    if n < 1 or h < 1 then return end
    local inset = math.max(line + 1, 2)
    local right_pad = math.max(1, math.floor(w * 0.08))
    local glyph_w = math.max(1, w - inset - right_pad)
    local glyph_x = x + inset
    local face_px = self:nominalSize(math.max(14, math.floor(h / n) - 2), 16, 26)
    local face = Font:getFace("cfont", face_px)
    local dot_face = Font:getFace("cfont", self:nominalSize(10, 10, 14))
    local highlight = self.bubble_letter
    for i, mark in ipairs(marks) do
        local sy = y + math.floor((i - 1) * h / n)
        local sh = math.floor(i * h / n) - math.floor((i - 1) * h / n)
        if mark.dot then
            local widget, sz = textSize(dot_face, "·", true, C.COLOR_GRAY_6, C.COLOR_WHITE)
            widget:paintTo(bb, glyph_x + math.floor((glyph_w - sz.w) / 2), sy + math.floor((sh - sz.h) / 2))
            widget:free()
        elseif type(mark.letter) == "string" and mark.letter ~= "" then
            local letter = mark.letter
            local on = self:active(letter)
            local hot = highlight == letter
            local bg = C.COLOR_WHITE
            local fg = on and C.COLOR_BLACK or C.COLOR_GRAY_6
            local box_w = math.max(1, glyph_w - 4)
            if hot then
                bg = on and C.COLOR_BLACK or C.COLOR_GRAY_8
                fg = C.COLOR_WHITE
                local pad = math.max(1, math.floor(sh * 0.08))
                local box_h = math.max(1, sh - 2 * pad)
                bb:paintRoundedRect(glyph_x + 2, sy + pad, box_w, box_h, bg,
                    math.min(math.floor(sh / 2), math.floor(box_w / 2), math.floor(box_h / 2)))
            end
            local widget, sz = textSize(face, letter, true, fg, hot and bg or C.COLOR_WHITE)
            local tx = glyph_x + math.floor((glyph_w - (sz.w or 0)) / 2)
            local ty = sy + math.floor((sh - (sz.h or 0)) / 2)
            widget:paintTo(bb, tx, ty)
            widget:free()
            if not hot and letter == self.anchor and on then
                local mark_w = math.max(4, math.floor((sz.w or 0) * 0.7))
                local mx = glyph_x + math.floor((glyph_w - mark_w) / 2)
                bb:paintRect(mx, ty + (sz.h or 0) - 1, mark_w, math.max(1, math.floor(sh * 0.08)), C.COLOR_BLACK)
            end
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

function Scrubber:pushRefresh(plan, prefer_view)
    self.last_refresh = plan
    if not plan or not UIManager.setDirty then return end
    -- The strip widget is thrown away when a letter jump rebuilds the
    -- page. Dirty the view, which stays, so the panel still updates the
    -- rectangle the bubble covered.
    local host = (prefer_view and self.view) or self
    -- A jump rebuilds the page and drops this strip. Refreshing a widget
    -- that is already closed crashes the repaint, so the region is asked
    -- for on its own.
    if host and host._closed then host = nil end
    for _, r in ipairs(plan.regions or {}) do
        local rect = Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }
        local mode = plan.mode
        UIManager:setDirty(host, function() return mode, rect end)
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

function Scrubber:cancelBubbleTimeout()
    if self._bubble_timeout and UIManager.unschedule then
        UIManager:unschedule(self._bubble_timeout)
    end
    self._bubble_timeout = nil
end

--- Hide the letter if no pan_release, hold_release or swipe ever arrives.
function Scrubber:armBubbleTimeout()
    self:cancelBubbleTimeout()
    self._bubble_timeout = function()
        self._bubble_timeout = nil
        if self._drag or self.bubble_letter then self:endDrag() end
    end
    if UIManager.scheduleIn then
        UIManager:scheduleIn(self.BUBBLE_TIMEOUT or 1, self._bubble_timeout)
    end
end

--- Drop the centered letter and refresh the rectangle under it.
-- Safe to call more than once. Does not jump to a page.
function Scrubber:clearBubble()
    if self._clearing then return false end
    if not (self.bubble_letter or self._drag or self._pending or self._snap or self._bubble_timeout) then
        return false
    end
    self._clearing = true
    self:cancelTick()
    self:cancelBubbleTimeout()
    local bubble = self.bubble
    local strip = self:stripRect()
    self._drag = nil
    self._pending = nil
    self.bubble_letter = nil
    self:restoreSnap()
    self:redrawDrag()
    self:pushRefresh(Core.scrubberReleaseRefresh(false, nil, strip, bubble), true)
    self._clearing = false
    return true
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
    self:armBubbleTimeout()
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
    local view = self.view
    if view and view.jumpToLetter then return view:jumpToLetter(letter) end
    local page = Core.scrubberTargetPage(self.index, letter)
    if page and view and view.goToPage and view.page ~= page then
        view:goToPage(page)
        return true
    end
    return false
end

function Scrubber:endDrag()
    if not (self._drag or self.bubble_letter) then
        self:cancelBubbleTimeout()
        return false
    end
    self:cancelTick()
    self:flushDrag()
    local letter = self.bubble_letter
    self:clearBubble()
    local view = self.view
    if view and view._closed then return true end
    if view and view.jumpToLetter then
        view:jumpToLetter(letter)
    else
        self:jumpTo(letter)
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
    -- Once a drag is underway the lift still has to clear the bubble, so
    -- Controls does not take that swipe.
    if not self._drag and self.view and self.view.tryOpenControls and self.view:tryOpenControls(ges) then
        return true
    end
    -- The strip wins over LiveLight. A flick that starts here picks a letter
    -- and is not offered to the warmth zone, even though the column sits
    -- inside the outer eighth.
    local pos = ges and (ges.end_pos or ges.pos)
    if self._drag or self.bubble_letter then
        if pos then self._pending = pos end
        self:endDrag()
        return true
    end
    -- A quick flick is a swipe instead of a pan_release. Stay on the strip:
    -- do not also turn a page.
    local letter = self:letterAt((ges and ges.pos and ges.pos.y) or (pos and pos.y))
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
    self:clearBubble()
    self:cancelTick()
    self:freeSnap()
end

return Scrubber
