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

describe("LiveLight overlap with the A–Z strip", function()
    it("recognises a vertical swipe that starts in an outer eighth", function()
        eq(Core.edgeVerticalSwipe({ direction = "north", pos = { x = 1200, y = 400 } }, 1264), "right")
        eq(Core.edgeVerticalSwipe({ direction = "south", pos = { x = 20, y = 400 } }, 1264), "left")
        eq(Core.edgeVerticalSwipe({ direction = "north", pos = { x = 600, y = 400 } }, 1264), nil)
        eq(Core.edgeVerticalSwipe({ direction = "west", pos = { x = 1200, y = 400 } }, 1264), nil)
    end)

    it("a vertical swipe on the strip is offered to LiveLight and does not jump", function()
        local offered, jumped = {}, {}
        local Scrubber = loadScrubber({
            tryLiveZones = function(ges) offered[#offered + 1] = ges; return true end,
        })
        local sc = Scrubber:new{
            letters = { "A", "B" },
            width = 120, height = 400, dpi = 300,
            screen_w = 1264, screen_h = 1680,
            view = { dimen = { w = 1264, h = 1680 } },
            jumpTo = function(_, letter) jumped[#jumped + 1] = letter end,
        }
        sc:init()
        sc.dimen.x, sc.dimen.y = 1144, 200
        local ges = { direction = "north", pos = { x = 1200, y = 300 }, ges = "swipe" }
        eq(sc:onSwipeScrubber(nil, ges), true)
        eq(#offered, 1)
        eq(#jumped, 0)
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
