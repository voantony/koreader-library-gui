--- Simple reader menu: a small panel that hangs from the top of the page
-- when you tap the top of the screen while reading. A few big buttons for
-- what people use most, and More… for KOReader's full reader menu.
-- Layout and hit-testing are in libraryreadermenu.lua; what each button does
-- is passed in by the plugin (main.lua, Library:simpleMenuActions).
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local RM = require("libraryreadermenu")
local _ = require("gettext")
local Screen = Device.screen

local C = Blitbuffer

local Panel = InputContainer:extend{
    name = "LibraryReaderMenu",
    title = nil,       -- book title
    subtitle = nil,    -- "Page 12 of 300 · 4 %"
    actions = nil,     -- list of { id, label, icon | glyph, on = fn?, run = fn }
    on_more = nil,     -- open KOReader's full reader menu
    on_exit = nil,     -- ask, then quit KOReader
    on_close = nil,
}

function Panel:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- taps anywhere are ours (outside the panel: close), but we only paint
    -- and refresh the panel itself, so the page underneath is left alone
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.L = RM.layout(W, H, #self.actions)
    local range = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        Hold = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function Panel:panelRect()
    local p = self.L.panel
    local sh = math.floor(10 * self.L.u)
    return Geom:new{ x = p.x, y = 0, w = p.w + sh, h = p.y + p.h + sh }
end

local function text(bb, s, x, y, size, opts)
    opts = opts or {}
    local t = TextWidget:new{ text = s, face = Font:getFace("cfont", size), bold = opts.bold,
        fgcolor = opts.color or C.COLOR_BLACK, bgcolor = opts.bg, max_width = opts.max_width }
    local sz = t:getSize()
    if opts.align == "center" then x = x - math.floor(sz.w / 2)
    elseif opts.align == "right" then x = x - sz.w end
    if opts.valign == "center" then y = y - math.floor(sz.h / 2) end
    t:paintTo(bb, x, y)
    t:free()
end

function Panel:paintTile(bb, a, t)
    local L = self.L
    local on = a.on and a.on() or false
    local s = t.icon_size
    local cx, cy = t.icon_cx, t.icon_cy
    local br = math.floor(s * 0.72)
    -- "on" (this page is bookmarked): a darker disc with a black ring
    bb:paintCircle(cx, cy, br, on and C.COLOR_GRAY_9 or C.COLOR_GRAY_E)
    if on then bb:paintCircle(cx, cy, br, C.COLOR_BLACK, math.max(3, math.floor(5 * L.u))) end
    if a.icon then
        local ok, icon = pcall(IconWidget.new, IconWidget, { icon = a.icon, width = s, height = s,
            alpha = true })
        if ok and icon then
            icon:paintTo(bb, cx - math.floor(s / 2), cy - math.floor(s / 2))
            icon:free()
        end
    elseif a.glyph then
        text(bb, a.glyph, cx, cy, 26, { align = "center", valign = "center", bold = a.bold_glyph,
            bg = on and C.COLOR_GRAY_9 or C.COLOR_GRAY_E })
    end
    local label = (on and a.label_on) or a.label
    text(bb, label, cx, t.label_y, 14, { align = "center", bold = true, max_width = t.w - math.floor(8 * L.u) })
end

function Panel:paintTo(bb, x, y)
    local L = self.L
    local p, r = L.panel, L.radius
    local sh = math.floor(10 * L.u)
    bb:paintRoundedRect(p.x + sh, p.y + sh, p.w, p.h, C.COLOR_GRAY_5, r)
    bb:paintRoundedRect(p.x, p.y, p.w, p.h, C.COLOR_WHITE, r)
    bb:paintBorder(p.x, p.y, p.w, p.h, math.max(2, math.floor(3 * L.u)), C.COLOR_GRAY_7, r)
    local tw = L.right - L.left
    text(bb, self.title or "", L.left, L.title_y, 20, { bold = true, max_width = tw })
    if self.subtitle and self.subtitle ~= "" then
        text(bb, self.subtitle, L.left, L.sub_y, 14, { color = C.COLOR_GRAY_4, max_width = tw })
    end
    bb:paintRect(L.left, L.divider_y, tw, math.max(2, math.floor(3 * L.u)), C.COLOR_GRAY_D)
    for i, a in ipairs(self.actions) do self:paintTile(bb, a, L.tiles[i]) end
    local m = L.more
    local mr = math.floor(m.h / 2)
    bb:paintRoundedRect(m.x, m.y, m.w, m.h, C.COLOR_GRAY_E, mr)
    bb:paintBorder(m.x, m.y, m.w, m.h, math.max(2, math.floor(2 * L.u)), C.COLOR_GRAY_9, mr)
    text(bb, _("More…  ·  full KOReader menu"), m.x + math.floor(m.w / 2), m.y + mr, 16,
        { align = "center", valign = "center", bold = true, bg = C.COLOR_GRAY_E, max_width = m.w - 2 * mr })
    local e = L.exit
    if e then
        local er = math.floor(e.h / 2)
        bb:paintRoundedRect(e.x, e.y, e.w, e.h, C.COLOR_WHITE, er)
        bb:paintBorder(e.x, e.y, e.w, e.h, math.max(2, math.floor(2 * L.u)), C.COLOR_GRAY_9, er)
        local s = math.floor(e.h * 0.5)
        local label = _("Exit")
        local ok, icon = pcall(IconWidget.new, IconWidget, { icon = "exit", width = s, height = s, alpha = true })
        local lw = TextWidget:new{ text = label, face = Font:getFace("cfont", 16), bold = true }
        local total = (ok and icon and s + math.floor(14 * L.u) or 0) + lw:getSize().w
        lw:free()
        local x0 = e.x + math.floor((e.w - total) / 2)
        if ok and icon then
            icon:paintTo(bb, x0, e.y + math.floor((e.h - s) / 2))
            icon:free()
            x0 = x0 + s + math.floor(14 * L.u)
        end
        text(bb, label, x0, e.y + er, 16, { valign = "center", bold = true })
    end
    local hd = L.handle
    bb:paintRoundedRect(hd.x, hd.y, hd.w, hd.h, C.COLOR_GRAY_B, math.floor(hd.h / 2))
end

function Panel:show()
    UIManager:show(self, "ui", self:panelRect())
end

function Panel:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self, "ui", self:panelRect())
end

--- Close, then run `fn` once the page underneath has repainted.
function Panel:closeThen(fn)
    self:close()
    if fn then UIManager:nextTick(fn) end
end

function Panel:onTap(_, ges)
    local what, i = RM.hit(self.L, ges.pos.x, ges.pos.y)
    if what == "tile" then
        local a = self.actions[i]
        self:closeThen(a and a.run)
    elseif what == "more" then
        self:closeThen(self.on_more)
    elseif what == "exit" then
        self:closeThen(self.on_exit)
    elseif not what then
        self:close()
    end
    return true
end

function Panel:onSwipe(_, ges)
    -- a swipe up (or anywhere outside) puts the panel away
    if ges.direction == "north" or RM.hit(self.L, ges.pos.x, ges.pos.y) == nil then self:close() end
    return true
end

function Panel:onHold() return true end

function Panel:onClose()
    self:close()
    return true
end

function Panel:onCloseWidget()
    if self.on_close then self.on_close(self) end
end

return Panel
