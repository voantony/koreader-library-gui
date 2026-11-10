-- Issue #3: a swipe up on the lower library area expands the bookshelf
-- over the widgets (the Continue strip hides, as when "Show Continue
-- Reading" is off), with a hairline under the search bar marking the
-- hide as temporary. A swipe down restores the strip.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryzones = true, libraryindex = true, string = true, table = true, math = true }
    _G.require = function(name)
        if extra[name] ~= nil then return extra[name] end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then
            return { template = function(s, ...)
                local a = { ... }
                return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
            end }
        end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/" .. file)
    _G.require = old_require
    if not ok then error(mod, 0) end
    return mod
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

local shelf_size = {
    margin = { default = 10 }, padding = { default = 8, small = 4, large = 16 },
    line = { thin = 1 },
}
local buttons, groups, vgroups, lines
local function clsInit()
    local base = cls()
    function base:new(o)
        o = o or {}
        setmetatable(o, self)
        if o.init then o:init() end
        return o
    end
    return base
end

local function loadShelfView()
    buttons, groups, vgroups, lines = {}, {}, {}, {}
    return load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = clsInit(),
        ["ui/widget/iconbutton"] = { new = function(_, o)
            o.image = {}
            o.getSize = function() return { w = 48, h = 48 } end
            buttons[#buttons + 1] = o
            return o
        end },
        ["ui/widget/textwidget"] = { new = function() return sized(80, 24) end },
        ["ui/widget/horizontalgroup"] = { new = function(_, o)
            o = o or {}
            o.getSize = function() return { w = 160, h = 48 } end
            o.free = function() end
            groups[#groups + 1] = o
            return o
        end },
        ["ui/widget/verticalgroup"] = { new = function(_, o)
            o = o or {}
            o.getSize = function() return { w = 200, h = 200 } end
            o.free = function() end
            vgroups[#vgroups + 1] = o
            return o
        end },
        ["ui/widget/linewidget"] = { new = function(_, o)
            o = o or {}
            lines[#lines + 1] = o
            return o
        end },
        ["ui/widget/horizontalspan"] = widget(8, 8),
        ["ui/widget/verticalspan"] = widget(8, 8),
        ["ui/widget/container/framecontainer"] = widget(200, 48),
        ["ui/geometry"] = { new = function(_, o) o.x = o.x or 0; o.y = o.y or 0; return o end },
        ["ui/gesturerange"] = { new = function() return {} end },
        ["ui/widget/container/leftcontainer"] = { new = function(_, o) return o end },
        ["ui/size"] = shelf_size,
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/time"] = {
            now = function() return _G.__now_ms or 0 end,
            to_ms = function(t) return t end,
            to_s = function(t) return t end,
        },
        librarytile = {
            minTouch = function() return 48 end,
            bookCover = function(_, book, box_w, box_h, title, sub)
                return sized(box_w, box_h), box_w, box_h, false
            end,
        },
        device = { screen = {
            scaleBySize = function(_, n) return n end,
            scaleByDPI = function(_, n) return n end,
            getWidth = function() return 1264 end,
            getHeight = function() return 1680 end,
        }, hasKeys = function() return false end, isTouchDevice = function() return true end, hasDPad = function() return false end },
        util = { stringLower = function(s) return s:lower() end },
    })
end

local built_strip
local function shelfView(View, opts)
    opts = opts or {}
    local books = {}
    local nbooks = opts.books or 8
    for i = 1, nbooks do
        books[i] = { path = "/b/" .. i .. ".epub", title = "Book " .. i,
            status = (i <= 3) and "reading" or "new", last_opened = 100 - i }
    end
    local v = setmetatable({
        width = 1264,
        dimen = { w = 1264, h = 1680 },
        tab = opts.tab or "books",
        sort = "recent",
        query = opts.query or "",
        filter = "all",
        page = opts.page or 1,
        pages = 1,
        group = nil,
        view_mode = "grid",
        cols = 4,
        label_h = 40,
        gap = 10,
        show_continue = true,
        top_row = "continue",
        continue_slots = 5,
        show_scrubber = false,
        all_books = books,
        last_book = nil,
        continue_label_h = 20,
        header = sized(1264, 100),
        timings = {},
        plugin = {
            settings = {},
            sortName = function() return "Last read" end,
            openBook = function() end,
        },
    }, { __index = View })
    v.keyboardGuard = function() end
    v.seriesPosition = function() return nil end
    v.keyboardHeight = function() return 0 end
    v.currentItems = function(self) return { kind = "books", items = self.all_books, counts = {} } end
    v.buildTabs = function() return sized(1264, 60) end
    v.buildChips = function() return nil end
    v.buildContinue = function(self, cbooks, layout)
        built_strip = { books = cbooks, layout = layout }
        return sized(1264, 200)
    end
    v.buildGrid = function(self, _items, _kind, _layout, height)
        self._grid_h = height
        return sized(1264, 800)
    end
    v.scheduleCoverExtraction = function() end
    v.refreshBody = function(self, full, reason)
        self.refreshed = (self.refreshed or 0) + 1
        self.refresh_reason = reason
        self:buildBody()
    end
    return v
end

local function body(opts)
    buttons, groups, vgroups, lines = {}, {}, {}, {}
    built_strip = nil
    local View = loadShelfView()
    local v = shelfView(View, opts)
    v:buildBody()
    return v
end

local function indexOf(t, value)
    for i, item in ipairs(t) do
        if item == value then return i end
    end
    return nil
end

local function swipeUp(v)
    return v:onSwipe(nil, { direction = "north", pos = { x = 600, y = 500 }, end_pos = { x = 600, y = 300 } })
end

local function swipeDown(v)
    return v:onSwipe(nil, { direction = "south", pos = { x = 600, y = 500 }, end_pos = { x = 600, y = 700 } })
end

describe("Swipe to expand the bookshelf", function()
    it("shows the strip normally, with no hairline", function()
        local v = body({})
        eq(built_strip ~= nil, true, "strip built on page 1")
        eq(#v.continue_books, 3)
        eq(#lines, 0)
        eq(v._shelf_expanded, nil)
    end)

    it("swipe up hides the strip and draws the hairline under the search bar", function()
        local v = body({})
        built_strip = nil
        eq(swipeUp(v), true)
        eq(v._shelf_expanded, true)
        eq(v.refreshed, 1)
        eq(v.refresh_reason, "shelf")
        eq(built_strip, nil, "strip not rebuilt while expanded")
        eq(v.continue_books, nil)
        eq(#lines, 1)
        eq(lines[1].dimen.w, 1264)
        eq(lines[1].dimen.h, 1)
        local frame = vgroups[#vgroups]
        eq(indexOf(frame, v.header), 1)
        eq(indexOf(frame, lines[1]), 2, "immediately below the search bar")
        eq(indexOf(frame, v.body), 4)
    end)

    it("swipe down restores the strip and removes the hairline", function()
        local v = body({})
        swipeUp(v)
        built_strip = nil
        lines = {}
        eq(swipeDown(v), true)
        eq(v._shelf_expanded, nil)
        eq(v.refreshed, 2)
        eq(built_strip ~= nil, true, "strip rebuilt")
        eq(#v.continue_books, 3)
        eq(#lines, 0)
    end)

    it("a tap that drifted up still opens the book instead of expanding", function()
        local v = body({})
        -- tapWasSwipe synthesises a swipe with no end_pos
        eq(v:onSwipe(nil, { direction = "north", pos = { x = 600, y = 500 } }), true, "still consumed")
        eq(v._shelf_expanded, nil)
        eq(v.refreshed, nil)
    end)

    it("a swipe starting in the search bar does not expand", function()
        local v = body({})
        eq(v:onSwipe(nil, { direction = "north", pos = { x = 600, y = 50 }, end_pos = { x = 600, y = 20 } }), true)
        eq(v._shelf_expanded, nil)
        eq(v.refreshed, nil)
    end)

    it("swipe up does nothing when no strip is showing", function()
        local v = body({ page = 2, books = 40 })
        eq(v.pages >= 2, true, "a real second page")
        eq(v.page, 2)
        eq(v.continue_books, nil, "later pages already use the full body")
        eq(swipeUp(v), true, "still consumed")
        eq(v._shelf_expanded, nil)
        eq(v.refreshed, nil)
    end)

    it("swipe down does nothing when not expanded", function()
        local v = body({})
        eq(swipeDown(v), true, "still consumed")
        eq(v._shelf_expanded, nil)
        eq(v.refreshed, nil)
    end)

    it("a diagonal swipe is left alone", function()
        local v = body({})
        eq(v:onSwipe(nil, { direction = "northeast", pos = { x = 600, y = 500 }, end_pos = { x = 700, y = 400 } }), false)
        eq(v._shelf_expanded, nil)
        eq(v.refreshed, nil)
    end)

    it("reserves the hairline in the grid height", function()
        local v = body({})
        swipeUp(v)
        local with_one = v._grid_h
        shelf_size.line.thin = 7
        v:buildBody()
        eq(v._grid_h, with_one - 6, "a taller hairline leaves that much less for the grid")
        shelf_size.line.thin = 1
        eq(#lines >= 1, true)
    end)

    it("turning the page clears the expanded flag", function()
        local v = body({ books = 40 })
        swipeUp(v)
        eq(v._shelf_expanded, true)
        eq(v.pages >= 2, true)
        lines = {}
        v:goToPage(2)
        eq(v.page, 2)
        eq(v._shelf_expanded, nil)
        eq(#lines, 0, "page 2 is not marked as a temporary hide")
    end)

    it("the expanded state clears itself when the strip would not show anyway", function()
        local v = body({})
        swipeUp(v)
        eq(v._shelf_expanded, true)
        -- searching hides the strip for its own reason
        v.query = "emma"
        lines = {}
        v:buildBody()
        eq(v._shelf_expanded, nil)
        eq(#lines, 0)
    end)
end)
