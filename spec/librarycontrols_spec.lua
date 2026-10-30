-- Controls panel: the corner it opens from, which toggles a device gets,
-- slider maths, the layout and what a tap hits.
local Core = require("librarycore")

describe("Controls corner", function()
    it("is the top-right eighth of the screen", function()
        eq(Core.inControlsCorner(1200, 50, 1264, 1680), true)
        eq(Core.inControlsCorner(1264 * 7 / 8, 1680 / 8, 1264, 1680), true)
        eq(Core.inControlsCorner(1000, 50, 1264, 1680), false, "the title bar's middle keeps its swipe")
        eq(Core.inControlsCorner(1200, 400, 1264, 1680), false, "the grid keeps its page swipe")
        eq(Core.inControlsCorner(10, 10, 1264, 1680), false)
    end)
end)

describe("Controls toggles", function()
    it("keeps the panel order and leaves out what the device lacks", function()
        same(Core.controlsToggles({ wifi = true, night = true, cover_sleep = true, rotate = true, bluetooth = false, sleep = true }),
            { "wifi", "night", "cover_sleep", "rotate", "sleep" })
        same(Core.controlsToggles({ night = true, cover_sleep = true }), { "night", "cover_sleep" })
        same(Core.controlsToggles({ sleep = true, bluetooth = true, wifi = true }), { "wifi", "bluetooth", "sleep" })
        same(Core.controlsToggles(nil), {})
    end)
end)

describe("Controls sliders", function()
    it("maps a tap on the track to a whole step", function()
        eq(Core.sliderValue(100, 100, 400, 0, 24), 0)
        eq(Core.sliderValue(500, 100, 400, 0, 24), 24)
        eq(Core.sliderValue(300, 100, 400, 0, 24), 12)
        eq(Core.sliderValue(308, 100, 400, 0, 24), 12)
        eq(Core.sliderValue(309, 100, 400, 0, 24), 13)
        eq(Core.sliderValue(-50, 100, 400, 0, 10), 0, "left of the track")
        eq(Core.sliderValue(900, 100, 400, 0, 10), 10, "right of the track")
        eq(Core.sliderValue(300, 100, 0, 3, 10), 3, "no track")
    end)
    it("places the knob", function()
        eq(Core.sliderFraction(12, 0, 24), 0.5)
        eq(Core.sliderFraction(-1, 0, 24), 0)
        eq(Core.sliderFraction(30, 0, 24), 1)
        eq(Core.sliderFraction(5, 5, 5), 0)
    end)
end)

describe("Controls layout", function()
    local L = Core.controlsLayout(1264, 1680, 2, 5)
    it("hangs from the top edge on the right", function()
        eq(L.panel.y < 0, true, "top corners off screen")
        eq(L.panel.x + L.panel.w, 1264 - 20)
        eq(L.panel.w, 920)
        eq(L.bottom < 1680 / 2 + 400, true, "leaves the lower Library visible")
    end)
    it("keeps every toggle label inside the panel", function()
        for _, t in ipairs(L.toggles) do
            eq(t.sub_y + 40 < L.panel.y + L.panel.h, true)
            eq(t.cx - t.r > L.panel.x and t.cx + t.r < L.panel.x + L.panel.w, true)
        end
    end)
    it("centres a short last row", function()
        eq(#L.toggles, 5)
        eq(L.toggles[4].cy, L.toggles[5].cy)
        local mid = (L.left + L.right) / 2
        eq(math.abs((L.toggles[4].cx + L.toggles[5].cx) / 2 - mid) <= 1, true)
    end)
    it("fits landscape and small screens", function()
        local S = Core.controlsLayout(600, 800, 2, 6)
        eq(S.panel.x >= 0, true)
        eq(S.bottom < 800, true)
        local Ls = Core.controlsLayout(1680, 1264, 2, 5)
        eq(Ls.panel.x + Ls.panel.w, 1680 - 20)
        eq(Ls.bottom < 1264, true)
    end)
    it("drops the slider block when there is no light", function()
        local N = Core.controlsLayout(1264, 1680, 0, 3)
        eq(#N.sliders, 0)
        eq(N.divider_y, nil)
        eq(N.bottom < L.bottom, true)
    end)
end)

describe("Controls hit-testing", function()
    local L = Core.controlsLayout(1264, 1680, 2, 5)
    it("finds buttons, sliders and toggles", function()
        local s = L.sliders[1]
        eq(select(1, Core.controlsHit(L, s.minus.cx, s.minus.cy)), "minus")
        eq(select(1, Core.controlsHit(L, s.plus.cx, s.plus.cy)), "plus")
        local what, i = Core.controlsHit(L, s.track.x + 50, s.track.y)
        eq(what, "slider"); eq(i, 1)
        what, i = Core.controlsHit(L, L.sliders[2].track.x + 10, L.sliders[2].track.y + 5)
        eq(what, "slider"); eq(i, 2)
        what, i = Core.controlsHit(L, L.toggles[3].cx, L.toggles[3].cy)
        eq(what, "toggle"); eq(i, 3)
        what, i = Core.controlsHit(L, L.toggles[5].cx, L.toggles[5].label_y + 10)
        eq(what, "toggle", "the label is part of the button"); eq(i, 5)
    end)
    it("treats the rest of the panel as inert and outside as close", function()
        eq(Core.controlsHit(L, L.left + 5, L.header_y + 5), "panel")
        eq(Core.controlsHit(L, 100, 1500), nil)
        eq(Core.controlsHit(L, 100, 100), nil, "left of the panel")
        eq(Core.controlsHit(L, 1000, L.bottom + 50), nil, "below the panel")
    end)
end)

----------------------------------------------------------------------------
-- LibraryView: the corner swipe opens the panel, other swipes turn pages
----------------------------------------------------------------------------

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function withView(fn)
    local real = { libraryview = true, librarycore = true, librarytile = true, librarycovers = true,
        string = true, table = true, math = true, io = true, os = true }
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    local old_require = require
    _G.require = function(name)
        if real[name] then return old_require(name) end
        if name == "ui/widget/container/inputcontainer" then return base end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
        return stub()
    end
    package.loaded.libraryview = nil
    local ok, err = pcall(function()
        local LibraryView = require("libraryview")
        local view = setmetatable({}, LibraryView)
        view.dimen = { x = 0, y = 0, w = 1264, h = 1680 }
        view.search_input = { isKeyboardVisible = function() return false end }
        view.turned = {}
        view.turnPage = function(self, d) table.insert(self.turned, d) end
        fn(view)
    end)
    _G.require = old_require
    package.loaded.libraryview = nil
    if not ok then error(err, 0) end
end

local function swipe(dir, x, y) return { direction = dir, pos = { x = x, y = y } } end

describe("corner swipe in the Library", function()
    it("opens the Controls panel", function()
        withView(function(view)
            local opened = 0
            view.plugin = { openControls = function() opened = opened + 1; return true end }
            eq(view:onSwipe(nil, swipe("south", 1220, 60)), true)
            eq(opened, 1)
            eq(#view.turned, 0, "no page turn")
        end)
    end)
    it("turns back a page when the panel is turned off", function()
        withView(function(view)
            view.plugin = { openControls = function() return false end }
            view:onSwipe(nil, swipe("south", 1220, 60))
            same(view.turned, { -1 })
        end)
    end)
    it("leaves swipes elsewhere alone", function()
        withView(function(view)
            local opened = 0
            view.plugin = { openControls = function() opened = opened + 1; return true end }
            view:onSwipe(nil, swipe("south", 600, 60))
            view:onSwipe(nil, swipe("south", 1220, 800))
            view:onSwipe(nil, swipe("west", 1220, 60))
            eq(opened, 0)
            same(view.turned, { -1, -1, 1 })
        end)
    end)
end)
