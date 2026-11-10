-- Issue #8: the Library view forwards gestures it does not keep to the
-- file browser's zones (LiveLight's edge slides), and a vertical swipe
-- starting on an edge strip is offered to those zones before the shelf
-- expand. The A–Z strip and the Controls corner keep priority.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o) o = o or {}; return setmetatable(o, self) end
    return base
end

local function sized(w, h)
    return { getSize = function() return { w = w, h = h } end, free = function() end }
end

local function widget(w, h)
    return { new = function(_, o)
        o = o or {}
        o.getSize = function() return { w = o.width or w, h = o.height or h } end
        o.free = function() end
        return o
    end }
end

local live_calls, live_result
local userfirst_calls, userfirst_result
local forward_calls, forward_result
local base_calls, base_handled
local device_stub

local function loadView()
    live_calls, live_result = {}, true
    userfirst_calls, userfirst_result = {}, false
    forward_calls, forward_result = {}, true
    base_calls, base_handled = {}, false
    local InputContainerStub = cls()
    function InputContainerStub.handleEvent(self, event)
        base_calls[#base_calls + 1] = event
        return base_handled
    end
    device_stub = { screen = {
        scaleBySize = function(_, n) return n end,
        scaleByDPI = function(_, n) return n end,
        getWidth = function() return 1264 end,
        getHeight = function() return 1680 end,
    }, hasKeys = function() return false end, isTouchDevice = function() return true end, hasDPad = function() return false end }
    local old_require = require
    local real = { librarycore = true, libraryindex = true, string = true, table = true, math = true }
    local extra = {
        ["ui/widget/container/inputcontainer"] = InputContainerStub,
        ["ui/widget/iconbutton"] = { new = function(_, o) o.image = {}; o.getSize = function() return { w = 48, h = 48 } end; return o end },
        ["ui/widget/textwidget"] = { new = function() return sized(80, 24) end },
        ["ui/widget/horizontalgroup"] = { new = function(_, o) o = o or {}; o.getSize = function() return { w = 160, h = 48 } end; o.free = function() end; return o end },
        ["ui/widget/horizontalspan"] = widget(8, 8),
        ["ui/widget/container/framecontainer"] = widget(200, 48),
        ["ui/geometry"] = { new = function(_, o) o.x = o.x or 0; o.y = o.y or 0; return o end },
        ["ui/gesturerange"] = { new = function() return {} end },
        ["ui/widget/container/leftcontainer"] = { new = function(_, o) return o end },
        ["ui/size"] = { margin = { default = 10 }, padding = { default = 8, small = 4, large = 16 }, line = { thin = 1 } },
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/time"] = { now = function() return 0 end, to_ms = function(t) return t end, to_s = function(t) return t end },
        librarytile = { minTouch = function() return 48 end,
            bookCover = function(_, book, box_w, box_h, title, sub) return sized(box_w, box_h), box_w, box_h, false end },
        device = device_stub,
        util = { stringLower = function(s) return s:lower() end },
        libraryzones = {
            tryLiveZones = function(ev) live_calls[#live_calls + 1] = ev; return live_result end,
            tryUserFirst = function(ev, fm) userfirst_calls[#userfirst_calls + 1] = ev; return userfirst_result end,
            liveHost = function() return {} end,
            forwardToLive = function(event, widget) forward_calls[#forward_calls + 1] = event; return forward_result end,
        },
    }
    _G.require = function(name)
        if extra[name] ~= nil then return extra[name] end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then
            return { template = function(s, ...) local a = { ... } return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end }
        end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/libraryview.lua")
    _G.require = old_require
    if not ok then error(mod, 0) end
    return mod
end

local function swipeView(View, opts)
    opts = opts or {}
    local refreshed = 0
    local v = setmetatable({
        dimen = { w = 1264, h = 1680 },
        tab = "books",
        sort = "recent",
        query = "",
        page = 1,
        pages = 1,
        cols = 4,
        view_mode = "grid",
        body_y = opts.body_y or 200,
        continue_books = opts.continue_books,
        scrubber = opts.scrubber,
        plugin = opts.plugin or {},
        cover_cache = { clear = function() end },
        search_input = { isKeyboardVisible = function() return false end },
    }, { __index = View })
    v.refreshBody = function(self) refreshed = refreshed + 1 end
    v.turnPage = function(self) self.turned = true end
    v.refreshed = function() return refreshed end
    return v
end

local function ges(direction, x, y, end_y)
    return { ges = "swipe", direction = direction,
        pos = { x = x, y = y }, end_pos = { x = x, y = end_y or y + 100 } }
end

describe("Library view zone forwarding", function()
    it("offers an unconsumed gesture to the file browser's zones", function()
        local View = loadView()
        local v = swipeView(View, {})
        local ev = { ges = "pan", pos = { x = 10, y = 500 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(#base_calls, 1, "the view's own handling ran first")
        eq(live_calls[1], ev, "the raw gesture was offered on")
    end)

    it("does not forward a gesture the view consumed", function()
        local View = loadView()
        base_handled = true
        local v = swipeView(View, {})
        eq(v:handleEvent({ handler = "onGesture", args = { { ges = "pan" } } }), true)
        eq(#live_calls, 0)
    end)

    it("returns false when neither the view nor the file browser takes it", function()
        local View = loadView()
        live_result = false
        local v = swipeView(View, {})
        eq(v:handleEvent({ handler = "onGesture", args = { { ges = "pan" } } }), false)
        eq(#live_calls, 1)
    end)

    it("hands a non-gesture event the view did not handle to the host", function()
        local View = loadView()
        local v = swipeView(View, {})
        local event = { handler = "onShowMenu", args = {} }
        eq(v:handleEvent(event), true)
        eq(#base_calls, 1)
        eq(forward_calls[1], event)
    end)

    it("does not forward a non-gesture event the view handled", function()
        local View = loadView()
        base_handled = true
        local v = swipeView(View, {})
        eq(v:handleEvent({ handler = "onShowMenu", args = {} }), true)
        eq(#forward_calls, 0)
    end)

    it("leaves a gesture-lock screensaver alone", function()
        local View = loadView()
        device_stub.screen_saver_lock = true
        local v = swipeView(View, {})
        eq(v:handleEvent({ handler = "onGesture", args = { { ges = "tap" } } }), false)
        eq(#base_calls, 0, "the view did not even look at it")
        eq(#live_calls, 0)
    end)

    it("offers an edge-starting vertical swipe to the file browser first", function()
        local View = loadView()
        local v = swipeView(View, { continue_books = { {} } })
        eq(v:onSwipe(nil, ges("south", 10, 500)), true)
        eq(#live_calls, 1, "left edge: brightness")
        eq(v._shelf_expanded, nil, "the shelf did not expand instead")
        live_calls = {}
        eq(v:onSwipe(nil, ges("north", 1250, 500)), true)
        eq(#live_calls, 1, "right edge: warmth")
    end)

    it("falls through to the shelf expand when nothing takes the edge swipe", function()
        local View = loadView()
        live_result = false
        local v = swipeView(View, { continue_books = { {} } })
        eq(v:onSwipe(nil, ges("south", 10, 500)), true)
        eq(#live_calls, 1, "offered first")
        eq(v._shelf_expanded, nil, "a downward swipe does not expand")
        eq(v:onSwipe(nil, ges("north", 10, 500)), true)
        eq(v._shelf_expanded, true, "an upward swipe expands once unclaimed")
    end)

    it("does not offer a mid-screen vertical swipe to the file browser", function()
        local View = loadView()
        local v = swipeView(View, { continue_books = { {} } })
        eq(v:onSwipe(nil, ges("north", 600, 500)), true)
        eq(#live_calls, 0)
        eq(v._shelf_expanded, true)
    end)

    it("does not offer a horizontal swipe to the file browser's zones", function()
        local View = loadView()
        local v = swipeView(View, {})
        eq(v:onSwipe(nil, ges("west", 10, 500)), true)
        eq(#live_calls, 0)
        eq(v.turned, true, "a page turn, not the light")
    end)

    it("runs a user-configured edge swipe before turning the page", function()
        local View = loadView()
        userfirst_result = true
        local v = swipeView(View, {})
        eq(v:onSwipe(nil, ges("east", 600, 10)), true)
        eq(#userfirst_calls, 1, "the top-edge swipe was offered first")
        eq(v.turned, nil, "the page did not turn instead")
    end)

    it("turns the page when no user gesture takes the edge swipe", function()
        local View = loadView()
        local v = swipeView(View, {})
        eq(v:onSwipe(nil, ges("east", 600, 10)), true)
        eq(#userfirst_calls, 1)
        eq(v.turned, true)
    end)

    it("does not offer a vertical swipe to the user-first check", function()
        local View = loadView()
        local v = swipeView(View, { continue_books = { {} } })
        eq(v:onSwipe(nil, ges("north", 600, 500)), true)
        eq(#userfirst_calls, 0, "vertical swipes go to the edge-slide check, not this one")
        eq(v._shelf_expanded, true)
    end)

    it("keeps the A–Z strip's swipe when it starts on the strip", function()
        local View = loadView()
        local scrubbed = {}
        local scrubber = {
            dimen = { x = 1144, y = 200, w = 120, h = 1400 },
            onSwipeScrubber = function(self) scrubbed[#scrubbed + 1] = true; return true end,
        }
        local v = swipeView(View, { scrubber = scrubber })
        eq(v:onSwipe(nil, ges("south", 1200, 500)), true)
        eq(#scrubbed, 1, "the strip jumped to a letter")
        eq(#live_calls, 0, "warmth did not take the strip's swipe")
    end)

    it("keeps the Controls corner swipe when it starts in the corner", function()
        local View = loadView()
        local opened = {}
        local v = swipeView(View, { plugin = { openControls = function() opened[#opened + 1] = true; return true end } })
        eq(v:onSwipe(nil, ges("south", 1200, 50)), true)
        eq(#opened, 1, "Controls opened")
        eq(#live_calls, 0)
    end)
end)

describe("bottom-left menu and the corner", function()
    local Core = require("librarycore")

    it("is the outer eighth of the bottom edge", function()
        eq(Core.inBottomLeftCorner(10, 1600, 1264, 1680), true)
        eq(Core.inBottomLeftCorner(10, 500, 1264, 1680), false, "left edge, not the corner")
        eq(Core.inBottomLeftCorner(400, 1600, 1264, 1680), false, "bottom edge, past the corner")
        eq(Core.inBottomLeftCorner(157, 1470, 1264, 1680), true)
        eq(Core.inBottomLeftCorner(158, 1470, 1264, 1680), false)
    end)

    it("offers a hold in the corner to the file browser before the menu button", function()
        local View = loadView()
        local v = swipeView(View, {})
        local opened
        v.plugin = { showLibraryMenu = function() opened = true end }
        v.footer_menu = { dimen = { x = 8, y = 1600, w = 64, h = 64 } }
        local ev = { ges = "hold", pos = { x = 20, y = 1620 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(live_calls[1], ev, "the corner hold was offered")
        eq(#base_calls, 0, "the menu button did not take it")
        eq(opened, nil)
    end)

    it("still opens the menu on a tap, and leaves an unclaimed hold to the button", function()
        local View = loadView()
        live_result = false
        local v = swipeView(View, {})
        local ev = { ges = "tap", pos = { x = 20, y = 1620 } }
        base_handled = true
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(#live_calls, 0, "a tap is not handed to the corner first")
        eq(#base_calls, 1, "the menu button sees the tap")
        live_calls, base_calls = {}, {}
        base_handled = false
        local hold = { ges = "hold", pos = { x = 20, y = 1620 } }
        eq(v:handleEvent({ handler = "onGesture", args = { hold } }), false)
        eq(#live_calls, 2, "offered first, then again once nothing kept it")
        eq(#base_calls, 1, "the button can still see an unclaimed hold")
    end)

    it("does not treat a hold outside the corner as a corner gesture", function()
        local View = loadView()
        local v = swipeView(View, {})
        eq(v:handleEvent({ handler = "onGesture", args = { { ges = "hold", pos = { x = 20, y = 400 } } } }), true)
        eq(#base_calls, 1, "the view's own widgets ran first")
        eq(live_calls[1].ges, "hold")
    end)

    it("a vertical swipe on the left edge still goes to LiveLight", function()
        local View = loadView()
        local v = swipeView(View, { continue_books = { {} } })
        eq(v:onSwipe(nil, ges("south", 20, 1620)), true)
        eq(#live_calls, 1, "brightness, even when the swipe starts on the menu")
        eq(v._shelf_expanded, nil)
    end)
end)
