-- Controls panel e-ink refreshes: drags redraw only the slider row with a
-- quick "a2" refresh (coalesced); lifting the finger (wherever it is) flashes the
-- panel once with "flashui"; taps flash once after they stop.
local Core = require("librarycore")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function withPanel(fn)
    local log, timers = {}, {}
    local UIManager = {
        setDirty = function(_, w, f)
            local mode, rect = f()
            log[#log + 1] = { mode = mode, rect = rect }
        end,
        scheduleIn = function(_, d, f) timers[f] = d end,
        unschedule = function(_, f) timers[f] = nil end,
        close = function() end,
    }
    local Geom = { new = function(_, o) return o end }
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    local old_require = require
    _G.require = function(name)
        if name == "librarycore" or name == "librarycontrols" or name == "string" or name == "table" or name == "math" then return old_require(name) end
        if name == "ui/widget/container/inputcontainer" then return base end
        if name == "ui/uimanager" then return UIManager end
        if name == "ui/geometry" then return Geom end
        if name == "gettext" then return function(s) return s end end
        return stub()
    end
    package.loaded.librarycontrols = nil
    local ok, err = pcall(function()
        local Controls = require("librarycontrols")
        local p = setmetatable({}, Controls)
        local W, H = 1264, 1680
        p.dimen = { x = 0, y = 0, w = W, h = H }
        p.values = { 8, 3 }
        p.sliders = {}
        for i = 1, 2 do
            p.sliders[i] = { min = 0, max = 24, get = function() return p.values[i] end,
                set = function(v) p.values[i] = v end }
        end
        p.toggles = {}
        p.L = Core.controlsLayout(W, H, 2, 0)
        p.log, p.timers = log, timers
        p.fire = function()
            local fs = {}
            for f in pairs(timers) do fs[#fs + 1] = f end
            for _, f in ipairs(fs) do timers[f] = nil; f() end
        end
        p.pending = function() local n = 0; for _ in pairs(timers) do n = n + 1 end; return n end
        fn(p)
    end)
    _G.require = old_require
    package.loaded.librarycontrols = nil
    if not ok then error(err, 0) end
end

local function at(p, i, frac)
    local t = p.L.sliders[i].track
    return { x = t.x + math.floor(t.w * frac), y = t.y + 5 }
end
local function modes(p) local t = {}; for _, e in ipairs(p.log) do t[#t + 1] = e.mode end; return t end

describe("Controls refreshes", function()
    it("drags with fast row-only refreshes and flashes the panel once on pan_release", function()
        withPanel(function(p)
            local s = at(p, 1, 0.1)
            p:onPan(nil, { start_pos = s, pos = at(p, 1, 0.5) })
            p:onPan(nil, { start_pos = s, pos = at(p, 1, 0.7) })
            p:onPan(nil, { start_pos = s, pos = at(p, 1, 0.3) })
            -- coalesced: the first step at once, the rest wait for the tick
            same(modes(p), { "a2" })
            local row = p:sliderRowRect(1)
            for _, e in ipairs(p.log) do
                eq(e.rect.y, row.y); eq(e.rect.h, row.h)
            end
            eq(row.h < p:panelRect().h / 3, true, "row is a small strip of the panel")
            p:onPanRelease(nil, { pos = at(p, 1, 0.3) })
            -- release applies the latest position, then one flash
            same(modes(p), { "a2", "a2", "flashui" })
            local last = p.log[#p.log].rect
            same(last, p:panelRect())
            eq(p.pending(), 0, "no stray timer left")
            eq(p.values[1], 7)
        end)
    end)
    it("keeps following and still flashes when the finger leaves the slider", function()
        withPanel(function(p)
            local s = at(p, 2, 0.5)
            p:onPan(nil, { start_pos = s, pos = { x = s.x + 40, y = s.y + 600 } })
            p:onPan(nil, { start_pos = s, pos = { x = 5000, y = 1600 } })
            p:onPanRelease(nil, { pos = { x = 5000, y = 1600 } })
            eq(p.values[2], 24, "clamped to max")
            eq(modes(p)[#p.log], "flashui")
        end)
    end)
    it("ends a quick drag reported as a swipe with one flash", function()
        withPanel(function(p)
            p:onSwipe(nil, { direction = "east", pos = at(p, 1, 0.2), end_pos = at(p, 1, 0.9) })
            same(modes(p), { "a2", "flashui" })
            eq(p.closed, nil, "panel stays open")
        end)
    end)
    it("handles hold, hold_pan and hold_release", function()
        withPanel(function(p)
            p:onHold(nil, { pos = at(p, 1, 0.5) })
            p:onHoldPan(nil, { start_pos = at(p, 1, 0.5), pos = at(p, 1, 0.8) })
            p:onHoldRelease(nil, { pos = at(p, 1, 0.8) })
            same(modes(p), { "a2", "a2", "flashui" })
            eq(p.pending(), 0)
        end)
    end)
    it("flashes after a drag whose release never arrives", function()
        withPanel(function(p)
            p:onPan(nil, { start_pos = at(p, 1, 0.1), pos = at(p, 1, 0.6) })
            eq(p.pending(), 2, "the drag tick and the watchdog")
            p.fire()
            same(modes(p), { "a2", "flashui" })
            eq(p._drag, nil)
        end)
    end)
    it("coalesces drag events: each tick applies only the latest position", function()
        withPanel(function(p)
            local s = at(p, 1, 0.1)
            p:onPan(nil, { start_pos = s, pos = at(p, 1, 0.5) })
            eq(p.values[1], 12)
            for _, f in ipairs({ 0.55, 0.6, 0.7, 0.75 }) do p:onPan(nil, { start_pos = s, pos = at(p, 1, f) }) end
            eq(p.values[1], 12, "nothing applied between ticks")
            local tick = p._tick_fn
            p.timers[tick] = nil; tick()
            eq(p.values[1], 18, "the tick applies the latest value once")
            same(modes(p), { "a2", "a2" })
            -- an idle tick with nothing new does nothing and stops ticking
            tick = p._tick_fn
            p.timers[tick] = nil; tick()
            eq(p._tick_fn, nil)
            same(modes(p), { "a2", "a2" })
            for _, e in ipairs(p.log) do eq(e.rect.h, p:sliderRowRect(1).h) end
            p:onPanRelease()
            same(modes(p), { "a2", "a2", "flashui" })
            eq(p.pending(), 0)
        end)
    end)
    it("taps redraw the row with ui and flash once after the taps stop", function()
        withPanel(function(p)
            local plus = p.L.sliders[1].plus
            for _ = 1, 3 do p:onTap(nil, { pos = { x = plus.cx, y = plus.cy } }) end
            same(modes(p), { "ui", "ui", "ui" })
            eq(p.pending(), 1, "one debounced flash, not one per tap")
            p.fire()
            same(modes(p), { "ui", "ui", "ui", "flashui" })
            eq(p.values[1], 11)
            p:onTap(nil, { pos = at(p, 1, 0.5) })
            p.fire()
            eq(p.log[#p.log].mode, "flashui", "tap on the track flashes too")
        end)
    end)
    it("a pan that starts off the sliders does nothing, and closing cancels the flash", function()
        withPanel(function(p)
            p:onPan(nil, { start_pos = { x = 10, y = 1600 }, pos = { x = 600, y = 1600 } })
            p:onPanRelease()
            same(modes(p), {})
            p:onTap(nil, { pos = at(p, 1, 0.9) })
            p:onCloseWidget()
            eq(p.pending(), 0)
        end)
    end)
end)
