-- Issue #5: the filter row scrolls instead of shrinking. The A–Z strip
-- is one right-hand column with a wide hit area. A short strip compacts
-- to letters and dots instead of shrinking the type. A vertical swipe in
-- the LiveLight edge is offered to that zone; a tap or a drag still picks
-- a letter, including letters hidden behind a dot.
local Core = require("librarycore")

local function loadScrubber(zones)
    local function stub()
        return setmetatable({}, { __index = function() return stub() end, __call = function() return stub() end })
    end
    local function cls()
        local base = {}
        base.__index = base
        function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
        function base:new(o) o = o or {}; return setmetatable(o, self) end
        return base
    end
    local old = require
    _G.require = function(name)
        if name == "librarycore" then return old("librarycore") end
        if name == "libraryzones" then return zones end
        if name == "ui/widget/container/inputcontainer" then return cls() end
        if name == "ui/gesturerange" then return { new = function() return {} end } end
        if name == "ui/geometry" then return { new = function(_, o) return o or {} end } end
        return stub()
    end
    package.loaded["libraryscrubber"] = nil
    local ok, mod = pcall(dofile, "library.koplugin/libraryscrubber.lua")
    _G.require = old
    package.loaded["libraryscrubber"] = nil
    if not ok then error(mod, 0) end
    return mod
end

describe("filter strip scroll", function()
    it("crops the end when the row is wider than the screen", function()
        local st = Core.filterScroll(0, 900, 600, 0)
        eq(st.overflow, true)
        eq(st.more_right, true)
        eq(st.more_left, false)
        eq(st.offset, 0)
    end)

    it("scrolls with the finger and stops at either end", function()
        local st = Core.filterScroll(0, 900, 600, -100)
        eq(st.offset, 100)
        eq(st.more_left, true)
        eq(st.more_right, true)
        st = Core.filterScroll(st.offset, 900, 600, -500)
        eq(st.offset, 300)
        eq(st.more_right, false)
        st = Core.filterScroll(0, 900, 600, 40)
        eq(st.offset, 0)
    end)

    it("does not crop a row that fits", function()
        local st = Core.filterScroll(0, 400, 600, -20)
        eq(st.overflow, false)
        eq(st.more_right, false)
        eq(st.offset, 0)
    end)
end)

describe("compact A–Z marks", function()
    it("paints every letter when the strip is tall enough", function()
        local slot = Core.scrubberMinSlot(300)
        local marks = Core.scrubberMarks(Core.SCRUBBER_LETTERS, slot * #Core.SCRUBBER_LETTERS, slot)
        eq(#marks, #Core.SCRUBBER_LETTERS)
        eq(marks[1].letter, "#")
        eq(marks[#marks].letter, "Z")
        for _, mark in ipairs(marks) do eq(mark.dot or false, false) end
    end)

    it("shows letters with dots when the strip is short, and keeps the ends", function()
        local slot = Core.scrubberMinSlot(300)
        local marks = Core.scrubberMarks(Core.SCRUBBER_LETTERS, slot * 15, slot)
        eq(#marks <= 15, true)
        eq(#marks < #Core.SCRUBBER_LETTERS, true)
        eq(marks[1].letter, "#")
        eq(marks[#marks].letter, "Z")
        local dots, letters = 0, 0
        for i, mark in ipairs(marks) do
            if mark.dot then
                dots = dots + 1
                eq(mark.text, "·")
                eq(i > 1 and i < #marks, true, "dots sit between letters")
            else
                letters = letters + 1
            end
        end
        eq(dots > 0, true)
        eq(letters >= 2, true)
        -- A dot separates neighbouring shown letters.
        eq(marks[2].dot, true)
    end)

    it("a drag on a short strip still reaches a letter that is only a dot", function()
        local Scrubber = loadScrubber({})
        local sc = Scrubber:new{
            letters = Core.SCRUBBER_LETTERS,
            width = 168, height = 400, dpi = 300,
            screen_w = 1264, screen_h = 1680,
            view = { dimen = { w = 1264, h = 1680 } },
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 0, 0
        local marks = Core.scrubberMarks(Core.SCRUBBER_LETTERS, 400, Core.scrubberMinSlot(300))
        eq(#marks < #Core.SCRUBBER_LETTERS, true)
        local shown = {}
        for _, mark in ipairs(marks) do
            if mark.letter then shown[mark.letter] = true end
        end
        local hidden
        for _, letter in ipairs(Core.SCRUBBER_LETTERS) do
            if not shown[letter] then hidden = letter break end
        end
        eq(hidden ~= nil, true)
        local found = false
        for y = 0, 399 do
            if sc:letterAt(y) == hidden then found = true break end
        end
        eq(found, true, "dragging passes through " .. tostring(hidden))
    end)
end)

describe("split A–Z when the column is short", function()
    it("keeps one column when every letter fits", function()
        local slot = Core.scrubberMinSlot(300)
        local left, right = Core.scrubberSplit(Core.SCRUBBER_LETTERS, slot * #Core.SCRUBBER_LETTERS, slot)
        eq(left, nil)
        eq(right, nil)
    end)

    it("splits #–M and N–Z when the column is short, without growing the shelf", function()
        local slot = Core.scrubberMinSlot(300)
        -- Ten slots is shorter than 27 letters. The split is only which
        -- letters to paint; the shelf height is not this number.
        local left, right = Core.scrubberSplit(Core.SCRUBBER_LETTERS, slot * 10, slot)
        eq(#left + #right, #Core.SCRUBBER_LETTERS)
        eq(left[1], "#")
        eq(left[#left], "M")
        eq(right[1], "N")
        eq(right[#right], "Z")
        eq(#left >= #right, true)
        eq(#left - #right <= 1, true)
    end)

    it("a left-hand strip's hit area reaches the screen edge", function()
        local Scrubber = loadScrubber({})
        local sc = Scrubber:new{
            letters = { "#", "A", "B", "M" },
            side = "left",
            width = 44, height = 700, dpi = 300,
            screen_w = 1072, screen_h = 1448,
            hit_extra = 20,
            view = { dimen = { w = 1072, h = 1448 } },
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 0, 400
        local hit = sc:hitRect()
        eq(hit.x, 0)
        eq(hit.w > sc.dimen.w, true, "the gutter past the letters still counts")
    end)
end)

describe("LiveLight overlap with the A–Z strip", function()
    it("recognises a vertical swipe that starts in an outer eighth", function()
        eq(Core.edgeVerticalSwipe({ direction = "north", pos = { x = 1200, y = 400 } }, 1264), "right")
        eq(Core.edgeVerticalSwipe({ direction = "south", pos = { x = 20, y = 400 } }, 1264), "left")
        eq(Core.edgeVerticalSwipe({ direction = "north", pos = { x = 600, y = 400 } }, 1264), nil)
        eq(Core.edgeVerticalSwipe({ direction = "west", pos = { x = 1200, y = 400 } }, 1264), nil)
    end)

    it("a vertical swipe on the strip scrubs a letter and does not call LiveLight", function()
        local offered, jumped = {}, {}
        local Scrubber = loadScrubber({
            tryLiveZones = function(ges) offered[#offered + 1] = ges; return true end,
        })
        local sc = Scrubber:new{
            letters = { "A", "B", "C", "D" },
            width = 50, height = 400, dpi = 300,
            screen_w = 1264, screen_h = 1680,
            hit_extra = 20,
            view = { dimen = { w = 1264, h = 1680 }, jumpToLetter = function(_, letter)
                jumped[#jumped + 1] = letter
                return true
            end },
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 1214, 200
        local ges = { direction = "north", pos = { x = 1230, y = 300 }, ges = "swipe" }
        eq(sc:onSwipeScrubber(nil, ges), true)
        eq(#offered, 0)
        eq(#jumped, 1)
        local hit = sc:hitRect()
        eq(hit.x < sc.dimen.x, true, "hit overlaps the gutter")
        eq(hit.x + hit.w >= 1264, true, "hit reaches the screen edge")
    end)

    it("a tap on the strip still jumps, and a swipe LiveLight declines still jumps", function()
        local jumped = {}
        local Scrubber = loadScrubber({
            tryLiveZones = function() return false end,
        })
        local sc = Scrubber:new{
            letters = { "A", "B", "C", "D" },
            width = 120, height = 400, dpi = 300,
            screen_w = 1264, screen_h = 1680,
            view = { dimen = { w = 1264, h = 1680 }, jumpToLetter = function(_, letter)
                jumped[#jumped + 1] = letter
                return true
            end },
            index = { active = { A = true, B = true, C = true, D = true }, page = { A = 1, B = 1, C = 1, D = 1 }, first = { A = 1, B = 2, C = 3, D = 4 } },
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 0, 0
        eq(sc:onTapScrubber(nil, { pos = { x = 10, y = 50 } }), true)
        eq(#jumped, 1)
        eq(sc:onSwipeScrubber(nil, { direction = "south", pos = { x = 20, y = 300 }, ges = "swipe" }), true)
        eq(#jumped, 2, "LiveLight left the swipe, so the strip jumped")
    end)
end)

describe("centered letter preview", function()
    it("a hold shows a large letter in the middle, and release hides it", function()
        local jumped = {}
        local Scrubber = loadScrubber({})
        local sc = Scrubber:new{
            letters = Core.SCRUBBER_LETTERS,
            width = 168, height = 1200, dpi = 300,
            screen_w = 1264, screen_h = 1680,
            view = { dimen = { w = 1264, h = 1680 }, jumpToLetter = function(_, letter)
                jumped[#jumped + 1] = letter
                return true
            end },
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 1096, 200
        eq(sc:onHoldScrubber(nil, { pos = { x = 1140, y = 800 } }), true)
        eq(sc.bubble_letter ~= nil, true)
        local side = sc.bubble.w
        eq(side >= 220, true)
        eq(sc.bubble.h, side)
        eq(sc.bubble.x, math.floor((1264 - side) / 2))
        eq(sc.bubble.y, math.floor((1680 - side) / 2))
        eq(sc.last_refresh.mode, "fast")
        for _, region in ipairs(sc.last_refresh.regions) do
            eq(region.w < 1264 or region.h < 1680, true)
        end
        eq(sc:onHoldReleaseScrubber(), true)
        eq(sc.bubble_letter, nil)
        eq(#jumped, 1)
    end)

    it("a drag keeps the fast refresh and never asks for a full flash", function()
        local Scrubber = loadScrubber({})
        local sc = Scrubber:new{
            letters = { "A", "M", "Z" },
            width = 168, height = 900, dpi = 300,
            screen_w = 1264, screen_h = 1680,
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 0, 0
        sc:onPanScrubber(nil, { pos = { x = 40, y = 100 } })
        eq(sc.bubble_letter, "A")
        eq(sc.last_refresh.mode, "fast")
        sc._tick = nil
        sc:onPanScrubber(nil, { pos = { x = 40, y = 800 } })
        eq(sc.bubble_letter, "Z")
        eq(sc.last_refresh.mode, "fast")
        sc:onPanReleaseScrubber()
        eq(sc.bubble_letter, nil)
        eq(sc.last_refresh.mode, "ui")
    end)
end)

describe("letter bubble is cleared however the scrub ends", function()
    local function scrubber(jumped)
        local Scrubber = loadScrubber({})
        local sc = Scrubber:new{
            letters = { "A", "M", "Z" },
            width = 50, height = 900, dpi = 300,
            screen_w = 1264, screen_h = 1680,
            view = { dimen = { w = 1264, h = 1680 }, jumpToLetter = function(_, letter)
                if jumped then jumped[#jumped + 1] = letter end
                return true
            end },
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 1214, 100
        return sc
    end

    local function down(sc, y)
        sc._tick = nil
        sc:dragTo({ x = 1230, y = y or 200 })
        eq(sc.bubble_letter ~= nil, true)
    end

    it("a lift on the strip clears it and asks for a UI refresh", function()
        local sc = scrubber()
        down(sc, 200)
        eq(sc:onPanReleaseScrubber(), true)
        eq(sc.bubble_letter, nil)
        eq(sc._drag, nil)
        eq(sc.last_refresh.mode, "ui")
        local saw
        for _, region in ipairs(sc.last_refresh.regions) do
            if region.w == sc.bubble.w and region.h == sc.bubble.h then saw = true end
        end
        eq(saw, true, "the bubble rectangle is refreshed")
    end)

    it("a lift off the strip still clears it", function()
        local sc = scrubber()
        down(sc, 200)
        sc._pending = { x = 100, y = 400 }
        eq(sc:onPanReleaseScrubber(), true)
        eq(sc.bubble_letter, nil)
    end)

    it("a swipe that ends outside the strip clears it and does not offer LiveLight", function()
        local offered = {}
        local Scrubber = loadScrubber({
            tryLiveZones = function(ges) offered[#offered + 1] = ges; return true end,
        })
        local sc = Scrubber:new{
            letters = { "A", "M", "Z" },
            width = 50, height = 900, dpi = 300,
            screen_w = 1264, screen_h = 1680,
            view = { dimen = { w = 1264, h = 1680 }, jumpToLetter = function() return true end },
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 1214, 100
        down(sc, 200)
        eq(sc:onSwipeScrubber(nil, {
            direction = "north", ges = "swipe",
            pos = { x = 1230, y = 200 },
            end_pos = { x = 200, y = 40 },
        }), true)
        eq(sc.bubble_letter, nil)
        eq(#offered, 0)
        eq(sc.last_refresh.mode, "ui")
    end)

    it("a hold release clears it", function()
        local sc = scrubber()
        eq(sc:onHoldScrubber(nil, { pos = { x = 1230, y = 200 } }), true)
        eq(sc.bubble_letter ~= nil, true)
        eq(sc:onHoldReleaseScrubber(), true)
        eq(sc.bubble_letter, nil)
        eq(sc.last_refresh.mode, "ui")
    end)

    it("a page change still refreshes the bubble rectangle", function()
        local jumped = {}
        local sc = scrubber(jumped)
        down(sc, 500)
        eq(sc:endDrag(), true)
        eq(#jumped, 1)
        eq(sc.bubble_letter, nil)
        eq(sc.last_refresh.mode, "ui")
    end)

    it("rebuilding the strip mid-drag clears the bubble without jumping", function()
        local jumped = {}
        local sc = scrubber(jumped)
        down(sc, 200)
        eq(sc:clearBubble(), true)
        eq(sc.bubble_letter, nil)
        eq(#jumped, 0)
        eq(sc.last_refresh.mode, "ui")
    end)

    it("closing the strip clears the bubble", function()
        local sc = scrubber()
        down(sc, 200)
        sc:onCloseWidget()
        eq(sc.bubble_letter, nil)
        eq(sc._bubble_timeout, nil)
    end)

    it("a fast scrub past both ends, then a release, does not index off the alphabet", function()
        local sc = scrubber()
        sc.letters = Core.SCRUBBER_LETTERS
        local ys = { sc.dimen.y - 1000, sc.dimen.y, sc.dimen.y + sc.dimen.h - 1,
            sc.dimen.y + sc.dimen.h, sc.dimen.y + 5000 }
        for _, y in ipairs(ys) do
            local letter = sc:letterAt(y)
            eq(type(letter), "string")
            local known = false
            for _, item in ipairs(Core.SCRUBBER_LETTERS) do
                if item == letter then known = true end
            end
            eq(known, true)
        end
        for i = 0, 40 do
            sc._tick = nil
            sc:dragTo({ x = sc.dimen.x + 2, y = sc.dimen.y - 100 + i * 40 })
            if sc.bubble_letter ~= nil then
                eq(type(sc.bubble_letter), "string")
            end
        end
        eq(sc:onPanReleaseScrubber(), true)
        eq(sc.bubble_letter, nil)
        local hit = sc:hitRect()
        eq(type(hit.contains), "function")
        eq(hit:contains({ x = sc.dimen.x + 2, y = sc.dimen.y + 2, w = 0, h = 0 }), true)
        eq(hit:contains({ x = -20, y = sc.dimen.y, w = 0, h = 0 }), false)
    end)

    it("an empty strip and a single letter do not crash a scrub", function()
        local sc = scrubber()
        sc.letters = {}
        eq(sc:letterAt(sc.dimen.y + 10), nil)
        sc:dragTo({ x = sc.dimen.x, y = sc.dimen.y + 10 })
        eq(sc.bubble_letter, nil)
        sc:onPanReleaseScrubber()
        sc.letters = { "Q" }
        eq(sc:letterAt(sc.dimen.y - 30), "Q")
        eq(sc:letterAt(sc.dimen.y + sc.dimen.h + 30), "Q")
        sc._tick = nil
        sc:dragTo({ x = sc.dimen.x, y = sc.dimen.y + 10 })
        eq(sc.bubble_letter, "Q")
        sc._tick = nil
        sc:dragTo({ x = sc.dimen.x, y = sc.dimen.y + 400 })
        eq(sc.bubble_letter, "Q")
        sc:onSwipeScrubber(nil, {
            direction = "north", pos = { x = sc.dimen.x, y = sc.dimen.y },
            end_pos = { x = 10, y = 10 },
        })
        eq(sc.bubble_letter, nil)
    end)

    it("a closed library does not refresh the strip or jump", function()
        local jumped = {}
        local sc = scrubber(jumped)
        down(sc, 200)
        sc.view._closed = true
        eq(sc:endDrag(), true)
        eq(#jumped, 0)
        eq(sc.bubble_letter, nil)
    end)

    it("a fallback timeout clears the bubble when no release arrives", function()
        local jumped = {}
        local sc = scrubber(jumped)
        down(sc, 200)
        eq(type(sc._bubble_timeout), "function")
        sc._bubble_timeout()
        eq(sc.bubble_letter, nil)
        eq(#jumped, 1, "the letter under the finger is still applied")
        eq(sc.last_refresh.mode, "ui")
    end)
end)

describe("gesture ranges never crash contains", function()
    -- The device crash: gesturerange.lua calls range:contains. A nil range
    -- is skipped. A plain table is not, and that is what hitRect returned.
    local function deviceMatch(range_fn, pos)
        local range = range_fn()
        if not range or not range:contains(pos) then return false end
        return true
    end

    it("an empty or missing box is a rectangle that matches nothing", function()
        local function check(box)
            local g = Core.gestureRect(box)
            eq(g ~= nil, true)
            eq(type(g.contains), "function")
            eq(g:contains({ x = 10, y = 10, w = 0, h = 0 }), false)
            eq(deviceMatch(function() return Core.gestureRect(box) end, { x = 1, y = 1, w = 0, h = 0 }), false)
        end
        check(nil)
        check({})
        check({ x = "no" })
        check({ w = -4, h = -2 })
    end)

    it("keeps a box that already has contains", function()
        local g = { x = 0, y = 0, w = 10, h = 10, contains = function() return true end }
        eq(Core.gestureRect(g), g)
    end)

    it("the strip hit box matches a point and does not crash before layout", function()
        local Scrubber = loadScrubber({})
        local sc = Scrubber:new{
            letters = { "A" }, width = 50, height = 400, dpi = 300,
            screen_w = 1264, screen_h = 1680,
        }
        sc:init()
        sc.dimen = nil
        local bare = sc:hitRect()
        eq(bare ~= nil, true)
        eq(type(bare.contains), "function")
        eq(deviceMatch(function() return sc:hitRect() end, { x = 100, y = 100, w = 0, h = 0 }), false)
        sc.dimen = { x = 1214, y = 200, w = 50, h = 400 }
        eq(deviceMatch(function() return sc:hitRect() end, { x = 1230, y = 300, w = 0, h = 0 }), true)
        eq(sc:hitRect():contains({ x = -5, y = 300, w = 0, h = 0 }), false)
    end)
end)
