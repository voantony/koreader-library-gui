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
local menu_calls, menu_result
local base_calls, base_handled
local device_stub

local function loadView()
    live_calls, live_result = {}, true
    userfirst_calls, userfirst_result = {}, false
    forward_calls, forward_result = {}, true
    menu_calls, menu_result = {}, false
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
    local real = { librarycore = true, libraryindex = true, librarygestures = true, string = true, table = true, math = true }
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
            tryMenuSwipe = function(ev) menu_calls[#menu_calls + 1] = ev; return menu_result end,
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

    it("still forwards a right-edge swipe that starts outside a short strip", function()
        local View = loadView()
        local scrubbed = {}
        local scrubber = {
            dimen = { x = 1214, y = 400, w = 50, h = 700 },
            hitRect = function(self)
                return { x = self.dimen.x - 20, y = self.dimen.y, w = self.dimen.w + 20, h = self.dimen.h }
            end,
            onSwipeScrubber = function() scrubbed[#scrubbed + 1] = true; return true end,
        }
        local v = swipeView(View, { scrubber = scrubber })
        eq(v:onSwipe(nil, ges("south", 1240, 80)), true)
        eq(#scrubbed, 0, "above the short strip")
        eq(#live_calls, 1, "warmth")
    end)

    it("does not forward a swipe that starts on the strip's hit area", function()
        local View = loadView()
        local scrubbed = {}
        local scrubber = {
            dimen = { x = 1214, y = 400, w = 50, h = 700 },
            hitRect = function(self)
                return { x = self.dimen.x - 20, y = self.dimen.y, w = self.dimen.w + 20, h = self.dimen.h }
            end,
            onSwipeScrubber = function() scrubbed[#scrubbed + 1] = true; return true end,
        }
        local v = swipeView(View, { scrubber = scrubber })
        eq(v:onSwipe(nil, ges("north", 1200, 500)), true)
        eq(#scrubbed, 1)
        eq(#live_calls, 0)
        live_calls = {}
        eq(v:handleEvent({ handler = "onGesture", args = { { ges = "swipe", direction = "north", pos = { x = 1230, y = 500 } } } }), false)
        eq(#live_calls, 0, "an unclaimed gesture on the strip is not offered on")
    end)

    it("still forwards a left-edge brightness swipe", function()
        local View = loadView()
        local v = swipeView(View, { scrubber = {
            dimen = { x = 1214, y = 200, w = 50, h = 1200 },
            onSwipeScrubber = function() return true end,
        } })
        eq(v:onSwipe(nil, ges("south", 20, 500)), true)
        eq(#live_calls, 1)
    end)

    it("still forwards a right-edge swipe when the strip is hidden", function()
        local View = loadView()
        local v = swipeView(View, {})
        eq(v:onSwipe(nil, ges("north", 1240, 500)), true)
        eq(#live_calls, 1)
    end)

    it("a swipe while a drag is up ends the drag before anything else", function()
        local View = loadView()
        local ended = {}
        local v = swipeView(View, { scrubber = {
            dimen = { x = 1214, y = 200, w = 50, h = 1200 },
            _drag = true,
            endDrag = function() ended[#ended + 1] = true; return true end,
        } })
        eq(v:onSwipe(nil, ges("north", 400, 800)), true)
        eq(#ended, 1)
        eq(#live_calls, 0)
        eq(v:onPanRelease(), true)
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

    it("offers a downward swipe from the top edge to the file browser menu", function()
        local View = loadView()
        menu_result = true
        local v = swipeView(View, { plugin = { openControls = function() return false end } })
        local ev = { ges = "swipe", direction = "south", pos = { x = 400, y = 20 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(menu_calls[1], ev, "the top-edge swipe was offered to the menu")
        eq(#base_calls, 0, "the grid, the search bar and the strip did not see it")
        eq(#live_calls, 0)
        eq(v._shelf_expanded, nil)
    end)

    it("still opens Controls from the top right when that panel is on", function()
        local View = loadView()
        menu_result = true
        local opened = 0
        local v = swipeView(View, { plugin = {
            openControls = function() opened = opened + 1; return true end,
        } })
        local ev = { ges = "swipe", direction = "south", pos = { x = 1000, y = 40 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(opened, 1)
        eq(#menu_calls, 0, "Controls took the corner; the file browser menu did not")
    end)

    it("offers the top-right swipe to the menu when Controls are off", function()
        local View = loadView()
        menu_result = true
        local opened = 0
        local v = swipeView(View, { plugin = {
            openControls = function() opened = opened + 1; return false end,
        } })
        local ev = { ges = "swipe", direction = "south", pos = { x = 1200, y = 30 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(opened, 1, "Controls was asked, and declined")
        eq(menu_calls[1], ev)
        eq(#base_calls, 0, "the A–Z strip did not take the top-edge swipe")
    end)

    it("lets the library keep a downward swipe the menu does not take", function()
        local View = loadView()
        local v = swipeView(View, { continue_books = { {} } })
        local ev = { ges = "swipe", direction = "south", pos = { x = 400, y = 800 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(#menu_calls, 1, "asked")
        eq(menu_result, false)
        eq(#base_calls, 1, "the grid still sees a swipe the menu left alone")
    end)

    it("forwards a two-finger swipe that starts on the A–Z strip", function()
        local View = loadView()
        local v = swipeView(View, { scrubber = {
            dimen = { x = 1214, y = 200, w = 50, h = 1200 },
            hitRect = function(self)
                return { x = self.dimen.x - 20, y = self.dimen.y, w = self.dimen.w + 40, h = self.dimen.h }
            end,
            onSwipeScrubber = function() return true end,
        } })
        local ev = { ges = "two_finger_swipe", direction = "east", pos = { x = 1230, y = 500 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(live_calls[1], ev, "the strip does not keep a two-finger swipe")
        eq(#base_calls, 1, "the view looked, and did not keep it")
    end)

    it("forwards a two-finger swipe from the middle of the screen", function()
        local View = loadView()
        local v = swipeView(View, {})
        local ev = { ges = "two_finger_swipe", direction = "west", pos = { x = 500, y = 800 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(live_calls[1], ev)
        eq(v.turned, nil, "a two-finger swipe is not a page turn")
    end)

    it("does not forward a top swipe the reader turned off", function()
        local View = loadView()
        menu_result = true
        local v = swipeView(View, { plugin = {
            openControls = function() return false end,
            settings = { gestures = { top_down = "nothing" } },
        } })
        local ev = { ges = "swipe", direction = "south", pos = { x = 400, y = 20 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(#menu_calls, 0, "Nothing does not open the file browser menu")
        eq(#base_calls, 0)
        eq(#live_calls, 0)
    end)

    it("runs the Library's own rotate action instead of the file browser's", function()
        local View = loadView()
        local got
        local v = swipeView(View, { plugin = {
            settings = { gestures = { two_east = "rotate_cw" } },
            rotateForEvent = function(_, event) got = event; return true end,
        } })
        local ev = { ges = "two_finger_swipe", direction = "east", pos = { x = 1230, y = 500 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(type(got), "table")
        eq(#live_calls, 0, "the file browser binding was not used")
    end)

    it("still forwards a two-finger swipe that is same as the file browser", function()
        local View = loadView()
        local v = swipeView(View, { plugin = { settings = {} }, })
        local ev = { ges = "two_finger_swipe", direction = "east", pos = { x = 1230, y = 500 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(live_calls[1], ev)
    end)

    it("does not set brightness from the left edge when that gesture is off", function()
        local View = loadView()
        local v = swipeView(View, { plugin = {
            settings = { gestures = { left_edge = "nothing" } },
        } })
        local ev = { ges = "swipe", direction = "south", pos = { x = 16, y = 800 } }
        eq(v:handleEvent({ handler = "onGesture", args = { ev } }), true)
        eq(#live_calls, 0)
        eq(#base_calls, 0, "the edge was not handed to the shelf or the page")
    end)

    it("rebuilds through the plugin on a rotation event instead of forwarding it raw", function()
        local View = loadView()
        local got
        local v = swipeView(View, { plugin = {
            rotateForEvent = function(_, event) got = event; return true end,
        } })
        local event = { handler = "onIterateRotation", args = {} }
        eq(v:handleEvent(event), true)
        eq(got, event)
        eq(#forward_calls, 0, "the file browser must not rotate while the old layout is still up")
        forward_calls = {}
        local swap = { handler = "onSwapRotation", args = {} }
        eq(v:handleEvent(swap), true)
        eq(got, swap)
        local setmode = { handler = "onSetRotationMode", args = { 1 } }
        eq(v:handleEvent(setmode), true)
        eq(got, setmode)
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

describe("left-edge brightness", function()
    local Core = require("librarycore")

    it("maps an upward drag onto a higher level, one integer at a time", function()
        -- 70% of 1680 is 1176 px for the whole 0..24 range.
        eq(Core.edgeLightLevel(800, 800, 1680, 8, 0, 24), 8)
        eq(Core.edgeLightLevel(800, 400, 1680, 8, 0, 24), 16)
        eq(Core.edgeLightLevel(800, 200, 1680, 8, 0, 24), 20)
        eq(Core.edgeLightLevel(100, 1600, 1680, 10, 0, 24), 0)
        eq(Core.edgeLightLevel(1600, 0, 1680, 10, 0, 24), 24)
    end)

    local function light()
        local sets, state = {}, { fl_intensity = 8, off = false }
        local p = {
            fl_min = 0, fl_max = 24, fl_intensity = 8,
            frontlightIntensity = function(self) return self.fl_intensity end,
            setIntensity = function(self, v)
                self.fl_intensity = v
                sets[#sets + 1] = v
            end,
            isFrontlightOff = function(self) return self.off end,
            turnOnFrontlight = function(self) self.off = false end,
            turnOffFrontlight = function(self) self.off = true; self.fl_intensity = 0 end,
            updateResumeFrontlightState = function() state.resumed = (state.resumed or 0) + 1 end,
        }
        return p, sets, state
    end

    it("sets the frontlight on the first pan and does not rebuild the library", function()
        local View = loadView()
        local p, sets, state = light()
        device_stub.getPowerDevice = function() return p end
        local v = swipeView(View, {})
        eq(v:onPan(nil, {
            pos = { x = 20, y = 400 },
            start_pos = { x = 20, y = 800 },
            relative = { x = 0, y = -400 },
        }), true)
        eq(sets[1], 16)
        eq(state.resumed >= 1, true)
        eq(v.refreshed(), 0, "the Library was not repainted")
        local n = #sets
        v:onPan(nil, {
            pos = { x = 20, y = 200 },
            start_pos = { x = 20, y = 800 },
            relative = { x = 0, y = -600 },
        })
        eq(#sets, n, "the next step waits for the same tick the slider uses")
        eq(v:onPanRelease(nil, { pos = { x = 20, y = 200 }, start_pos = { x = 20, y = 800 } }), true)
        eq(sets[#sets], 20)
        eq(v._edge, nil)
        eq(v.refreshed(), 0)
    end)

    it("a sideways pan on the left edge is not brightness", function()
        local View = loadView()
        local p, sets = light()
        device_stub.getPowerDevice = function() return p end
        local v = swipeView(View, {})
        eq(v:onPan(nil, {
            pos = { x = 80, y = 500 },
            start_pos = { x = 20, y = 500 },
            relative = { x = 60, y = 4 },
        }), false)
        eq(#sets, 0)
    end)

    it("does not set the light for a drag that starts on the A–Z strip", function()
        local View = loadView()
        local p, sets = light()
        device_stub.getPowerDevice = function() return p end
        local v = swipeView(View, { scrubber = {
            dimen = { x = 1214, y = 200, w = 50, h = 1200 },
            dragTo = function() end,
        } })
        eq(v:onPan(nil, {
            pos = { x = 1230, y = 400 },
            start_pos = { x = 1230, y = 800 },
            relative = { x = 0, y = -400 },
        }), false)
        eq(#sets, 0)
    end)

    it("a frontlight that throws does not crash the swipe", function()
        local View = loadView()
        local p = {
            fl_min = 0, fl_max = 10, fl_intensity = 3,
            frontlightIntensity = function(self) return self.fl_intensity end,
            setIntensity = function() error("no warmth") end,
            updateResumeFrontlightState = function() error("nil warmth") end,
        }
        device_stub.getPowerDevice = function() return p end
        local v = swipeView(View, {})
        eq(v:onPan(nil, {
            pos = { x = 20, y = 300 },
            start_pos = { x = 20, y = 700 },
            relative = { x = 0, y = -400 },
        }), true)
        eq(v.refreshed(), 0)
        eq(v:onPanRelease(nil, { pos = { x = 20, y = 300 } }), true)
        eq(v._edge, nil)
    end)

    it("no power device leaves the left edge to whatever zone is installed", function()
        local View = loadView()
        device_stub.getPowerDevice = nil
        local v = swipeView(View, {})
        eq(v:onSwipe(nil, ges("south", 20, 500)), true)
        eq(#live_calls, 1)
    end)
end)
