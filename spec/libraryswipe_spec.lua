-- Library page swipes: left is next, right is previous. Up and down never
-- turn a page. Controls (top-right downward, including a child widget that
-- sees the swipe first) and the A–Z strip (vertical drag and jump) win
-- over that rule.
local Core = require("librarycore")

describe("library page swipe direction", function()
    it("turns forward on a left swipe and back on a right swipe", function()
        eq(Core.libraryPageTurn("west"), 1)
        eq(Core.libraryPageTurn("east"), -1)
    end)
    it("does not turn a page up, down, or on a diagonal", function()
        eq(Core.libraryPageTurn("north"), nil)
        eq(Core.libraryPageTurn("south"), nil)
        eq(Core.libraryPageTurn("northeast"), nil)
        eq(Core.libraryPageTurn("northwest"), nil)
        eq(Core.libraryPageTurn("southeast"), nil)
        eq(Core.libraryPageTurn("southwest"), nil)
        eq(Core.libraryPageTurn(nil), nil)
        eq(Core.libraryPageTurn(""), nil)
    end)
end)

----------------------------------------------------------------------------
-- LibraryView, the search field and the A–Z strip
----------------------------------------------------------------------------

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local input_swipes

local function withWidgets(fn)
    local real = {
        libraryview = true, librarycore = true, librarytile = true, librarycovers = true,
        libraryscrubber = true,
        string = true, table = true, math = true, io = true, os = true,
    }
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    local InputText = base:extend{}
    function InputText:onSwipeTextBox()
        input_swipes = input_swipes + 1
        return false
    end
    local screen = {
        scaleByDPI = function(_, n) return n end,
        scaleBySize = function(_, n) return n end,
        getWidth = function() return 1264 end,
        getHeight = function() return 1680 end,
        getDPI = function() return 300 end,
    }
    local old_require = require
    _G.require = function(name)
        if real[name] then return old_require(name) end
        if name == "ui/widget/container/inputcontainer" then return base end
        if name == "ui/widget/inputtext" then return InputText end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
        if name == "device" then
            return { screen = screen, hasKeys = function() return false end, input = {}, isTouchDevice = function() return true end }
        end
        if name == "ui/time" then
            return { now = function() return _G.__now_ms or 0 end, to_ms = function(t) return t end }
        end
        return stub()
    end
    package.loaded.libraryview = nil
    package.loaded.libraryscrubber = nil
    input_swipes = 0
    local ok, err = pcall(function()
        local LibraryView = require("libraryview")
        local Scrubber = require("libraryscrubber")
        local view = setmetatable({}, LibraryView)
        view.dimen = { x = 0, y = 0, w = 1264, h = 1680 }
        view.search_input = { isKeyboardVisible = function() return false end }
        view.turned = {}
        view.turnPage = function(self, d) table.insert(self.turned, d) end
        view.plugin = { openControls = function() return true end }
        fn(view, LibraryView, Scrubber)
    end)
    _G.require = old_require
    package.loaded.libraryview = nil
    package.loaded.libraryscrubber = nil
    if not ok then error(err, 0) end
end

local function swipe(dir, x, y, extra)
    local ges = { direction = dir, pos = { x = x, y = y } }
    if extra then for k, v in pairs(extra) do ges[k] = v end end
    return ges
end

local function plug(view, on_open)
    local opened = 0
    view.plugin = {
        openControls = function()
            opened = opened + 1
            if on_open then return on_open() end
            return true
        end,
    }
    return function() return opened end
end

describe("horizontal and vertical swipes in the Library", function()
    it("turns the next page on a left swipe and the previous on a right swipe", function()
        withWidgets(function(view)
            local opened = plug(view)
            eq(view:onSwipe(nil, swipe("west", 400, 800)), true)
            eq(view:onSwipe(nil, swipe("east", 400, 900)), true)
            -- the top-right zone is only special for a downward swipe
            eq(view:onSwipe(nil, swipe("west", 1100, 40)), true)
            eq(view:onSwipe(nil, swipe("east", 200, 40)), true)
            same(view.turned, { 1, -1, 1, -1 })
            eq(opened(), 0)
        end)
    end)

    it("does not turn a page on an up or down swipe", function()
        withWidgets(function(view)
            local opened = plug(view)
            for _, ges in ipairs({
                swipe("north", 400, 800),
                swipe("south", 400, 800),
                swipe("north", 200, 40),
                swipe("south", 200, 40),   -- left of the Controls zone
                swipe("north", 1100, 40),  -- up inside the zone is not Controls
                swipe("south", 1100, 900), -- below the zone
            }) do
                eq(view:onSwipe(nil, ges), true)
            end
            eq(#view.turned, 0)
            eq(opened(), 0)
        end)
    end)

    it("does not turn a page on a diagonal that is not the Controls gesture", function()
        withWidgets(function(view)
            local opened = plug(view)
            eq(view:onSwipe(nil, swipe("southwest", 200, 800)), false)
            eq(view:onSwipe(nil, swipe("northeast", 400, 800)), false)
            eq(view:onSwipe(nil, swipe("northwest", 1100, 40)), false)
            eq(#view.turned, 0)
            eq(opened(), 0)
        end)
    end)

    it("a short vertical flick does not turn the page or open the book", function()
        withWidgets(function(view)
            local opened_book = 0
            view.plugin.openBook = function() opened_book = opened_book + 1 end
            view.keyboardGuard = function() end
            _G.__now_ms = 5000
            view:onTouch(nil, { pos = { x = 300, y = 400 } })
            view:onTileTap({ book = { path = "/emma" } }, { pos = { x = 305, y = 340 } })
            view:onTouch(nil, { pos = { x = 300, y = 400 } })
            view:onTileTap({ book = { path = "/emma" } }, { pos = { x = 300, y = 460 } })
            eq(#view.turned, 0)
            eq(opened_book, 0)
            view:onTouch(nil, { pos = { x = 300, y = 400 } })
            view:onTileTap({ book = { path = "/emma" } }, { pos = { x = 260, y = 405 } })
            same(view.turned, { 1 }, "a short flick to the left still turns the page")
            eq(opened_book, 0)
        end)
    end)
end)

describe("swipe priority: Controls, then the A–Z strip, then the page", function()
    local strip = { x = 1144, y = 80, w = 120, h = 1400 }

    it("opens Controls before a page turn or the strip", function()
        withWidgets(function(view)
            local scrubbed = 0
            local opened = plug(view)
            view.scrubber = {
                dimen = strip,
                onSwipeScrubber = function() scrubbed = scrubbed + 1 end,
            }
            eq(view:onSwipe(nil, swipe("south", 1200, 90)), true)
            eq(view:onSwipe(nil, swipe("southwest", 1000, 40)), true)
            eq(view:onSwipe(nil, swipe("southeast", 900, 50)), true)
            eq(opened(), 3)
            eq(scrubbed, 0)
            eq(#view.turned, 0)
        end)
    end)

    it("gives the strip a vertical swipe below the Controls zone, and no page turn", function()
        withWidgets(function(view)
            local dirs = {}
            local opened = plug(view)
            view.scrubber = {
                dimen = strip,
                onSwipeScrubber = function(_, _, ges) dirs[#dirs + 1] = ges.direction end,
            }
            eq(view:onSwipe(nil, swipe("south", 1200, 400)), true)
            eq(view:onSwipe(nil, swipe("north", 1200, 800)), true)
            same(dirs, { "south", "north" })
            eq(opened(), 0)
            eq(#view.turned, 0)
        end)
    end)

    it("keeps a swipe that started on the strip on the strip, even if it ends on the grid", function()
        withWidgets(function(view)
            local scrubbed = 0
            view.plugin = { openControls = function() return true end }
            view.scrubber = {
                dimen = strip,
                onSwipeScrubber = function() scrubbed = scrubbed + 1 end,
            }
            local ges = swipe("west", 400, 700, { start_pos = { x = 1200, y = 700 } })
            eq(view:onSwipe(nil, ges), true)
            eq(scrubbed, 1)
            eq(#view.turned, 0, "the strip handles it; the page does not turn")
        end)
    end)

    it("still turns the page for a horizontal swipe on the grid while the strip is showing", function()
        withWidgets(function(view)
            local scrubbed = 0
            view.scrubber = {
                dimen = strip,
                onSwipeScrubber = function() scrubbed = scrubbed + 1 end,
            }
            eq(view:onSwipe(nil, swipe("west", 400, 700)), true)
            eq(view:onSwipe(nil, swipe("east", 500, 700)), true)
            eq(scrubbed, 0)
            same(view.turned, { 1, -1 })
        end)
    end)

    it("finishes an A–Z drag instead of turning a page", function()
        withWidgets(function(view)
            local ended, pending = 0, nil
            view.scrubber = {
                _drag = true,
                endDrag = function(self)
                    ended = ended + 1
                    pending = self._pending
                end,
            }
            eq(view:onSwipe(nil, swipe("north", 200, 200, { end_pos = { x = 210, y = 80 } })), true)
            eq(ended, 1)
            eq(pending.y, 80)
            eq(#view.turned, 0)
            view.scrubber._drag = true
            eq(view:onSwipe(nil, swipe("west", 200, 400)), true)
            eq(ended, 2)
            eq(#view.turned, 0, "a sideways flick while dragging does not turn the page")
        end)
    end)

    it("keeps driving a vertical drag and ignores a pan anywhere else", function()
        withWidgets(function(view)
            local dragged = 0
            view.scrubber = {
                _drag = true,
                dragTo = function() dragged = dragged + 1 end,
            }
            eq(view:onPan(nil, { pos = { x = 1200, y = 500 } }), true)
            eq(view:onHoldPan(nil, { pos = { x = 1180, y = 640 } }), true)
            eq(dragged, 2)
            eq(#view.turned, 0)
            view.scrubber._drag = nil
            eq(view:onPan(nil, { pos = { x = 400, y = 500 } }), false)
            eq(view:onHoldPan(nil, { pos = { x = 400, y = 600 } }), false)
            eq(#view.turned, 0)
        end)
    end)
end)

describe("child widgets route a downward Controls swipe first", function()
    it("the search field opens Controls and does not hand that swipe to InputText", function()
        withWidgets(function(view, LibraryView)
            local opened = plug(view)
            local box = setmetatable({ parent = view }, LibraryView.SearchInput)
            eq(box:onSwipeTextBox(nil, swipe("south", 1100, 40)), true)
            eq(box:onSwipeTextBox(nil, swipe("southwest", 1000, 30)), true)
            eq(opened(), 2)
            eq(input_swipes, 0, "InputText must not flash the screen for this swipe")
            eq(#view.turned, 0)
        end)
    end)

    it("the search field lets other swipes propagate so the Library can decide", function()
        withWidgets(function(view, LibraryView)
            local opened = plug(view)
            local box = setmetatable({ parent = view }, LibraryView.SearchInput)
            eq(box:onSwipeTextBox(nil, swipe("west", 400, 40)), false)
            eq(box:onSwipeTextBox(nil, swipe("east", 400, 40)), false)
            eq(box:onSwipeTextBox(nil, swipe("north", 400, 40)), false)
            eq(box:onSwipeTextBox(nil, swipe("south", 200, 40)), false, "down, but left of the zone")
            eq(opened(), 0)
            eq(input_swipes, 4)
            eq(#view.turned, 0, "the field itself does not turn a page")
        end)
    end)

    it("the A–Z strip opens Controls from its own swipe handler", function()
        withWidgets(function(view, _, Scrubber)
            local jumped = 0
            local opened = plug(view)
            local strip = setmetatable({
                dimen = { x = 1144, y = 80, w = 120, h = 1400 },
                view = view,
                jumpTo = function() jumped = jumped + 1 end,
            }, Scrubber)
            eq(strip:onSwipeScrubber(nil, swipe("south", 1200, 90)), true)
            eq(opened(), 1)
            eq(jumped, 0)
            eq(#view.turned, 0)
        end)
    end)

    it("the A–Z strip jumps on a vertical flick and does not turn a page", function()
        withWidgets(function(view, _, Scrubber)
            local letters = {}
            local opened = plug(view)
            local strip = setmetatable({
                dimen = { x = 1144, y = 80, w = 120, h = 1400 },
                view = view,
                jumpTo = function(_, letter) letters[#letters + 1] = letter; return true end,
            }, Scrubber)
            eq(strip:onSwipeScrubber(nil, swipe("south", 1200, 400)), true)
            eq(strip:onSwipeScrubber(nil, swipe("north", 1200, 900, { end_pos = { x = 1200, y = 200 } })), true)
            eq(opened(), 0)
            eq(#letters, 2)
            eq(letters[1] ~= nil, true)
            eq(#view.turned, 0)
            -- a sideways flick on the strip stays a jump, not a page turn
            eq(strip:onSwipeScrubber(nil, swipe("west", 1200, 700)), true)
            eq(#letters, 3)
            eq(#view.turned, 0)
        end)
    end)
end)
