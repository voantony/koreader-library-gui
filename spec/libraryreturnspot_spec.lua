-- Coming back from a book lands where the Library was; a short flick on a
-- cover turns the page instead of opening the book.
local Core = require("librarycore")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, string = true, table = true, math = true }
    _G.require = function(name)
        if extra[name] ~= nil then return extra[name] end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
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

describe("return spot (pure)", function()
    it("keeps tab, shelf with its parent page and search, page, filter, sort, layout", function()
        local spot = Core.returnSpot({
            tab = "series", group = { kind = "series", name = "Oz", books = { 1, 2 } },
            parent_page = 4, parent_query = "oz", page = 3, query = "",
            filter = "unread", sort = "title", view_mode = "list", book = "/oz3",
        }, 77)
        same(spot, { tab = "series", group = { kind = "series", name = "Oz" }, parent_page = 4,
            parent_query = "oz", page = 3, filter = "unread", sort = "title", view_mode = "list",
            book = "/oz3", pid = 77 })
    end)

    it("keeps search text only when the book came from search results", function()
        eq(Core.returnSpot({ tab = "books", query = "" }, 1).query, nil)
        eq(Core.returnSpot({ tab = "books", query = "tolk" }, 1).query, "tolk")
    end)

    it("has no shelf fields without a shelf, and a sane page", function()
        local spot = Core.returnSpot({ tab = "books", parent_page = 5, page = 0 }, 1)
        eq(spot.group, nil); eq(spot.parent_page, nil); eq(spot.page, 1)
        eq(Core.returnSpot(nil, 1), nil)
        eq(Core.returnSpot({}, 1), nil)
    end)

    it("is only usable in the same KOReader run", function()
        local spot = Core.returnSpot({ tab = "books" }, 10)
        eq(Core.returnSpotUsable(spot, 10), true)
        eq(Core.returnSpotUsable(spot, 11), false)
        eq(Core.returnSpotUsable(nil, 10), false)
        eq(Core.returnSpotUsable({ tab = "books" }, 10), false)
    end)
end)

describe("short swipe on a cover (pure)", function()
    it("a finger that barely moved is a tap", function()
        eq(Core.shortSwipe({ x = 100, y = 100 }, { x = 105, y = 97 }, 20), nil)
        eq(Core.shortSwipe(nil, { x = 1, y = 1 }, 20), nil)
        eq(Core.shortSwipe({ x = 1, y = 1 }, nil, 20), nil)
    end)

    it("a finger that moved is a swipe in its main direction", function()
        eq(Core.shortSwipe({ x = 100, y = 100 }, { x = 70, y = 110 }, 20), "west")
        eq(Core.shortSwipe({ x = 100, y = 100 }, { x = 130, y = 90 }, 20), "east")
        eq(Core.shortSwipe({ x = 100, y = 100 }, { x = 95, y = 60 }, 20), "north")
        eq(Core.shortSwipe({ x = 100, y = 100 }, { x = 100, y = 120 }, 20), "south")
    end)

    it("a tap right after a page turn is ignored", function()
        eq(Core.tapTooSoon(1100, 1000), true)
        eq(Core.tapTooSoon(1300, 1000), false)
        eq(Core.tapTooSoon(1000, nil), false)
        eq(Core.tapTooSoon(900, 1000), false)
    end)
end)

local function loadView()
    return load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = cls(),
        ["ui/uimanager"] = { unschedule = function() end, scheduleIn = function() end, setDirty = function() end },
        ["ui/time"] = { now = function() return _G.__now_ms or 0 end, to_ms = function(t) return t end },
        util = { stringLower = function(s) return s:lower() end },
        device = { screen = { scaleByDPI = function(_, n) return n end, getWidth = function() return 600 end,
            getHeight = function() return 800 end }, hasKeys = function() return false end, input = {} },
    })
end

local function library()
    local books = {}
    for i = 1, 30 do
        books[i] = { path = "/oz" .. i, title = "Oz " .. i, authors = { "Baum" }, series = "Oz", series_index = i }
    end
    books[31] = { path = "/emma", title = "Emma", authors = { "Austen" } }
    return books
end

local function newView(View, settings)
    local opened = {}
    local v = setmetatable({
        tab = "books", query = "", page = 1, filter = "all", sort = "recent", view_mode = "grid",
        sorted = library(), all_books = library(), groups_cache = {},
        search_input = { setText = function(self, t) self.text = t end },
        plugin = {
            settings = settings or {}, saveSettings = function() end, collate = nil,
            getCollections = function() return {} end,
            openBook = function(_, path) opened[#opened + 1] = path end,
        },
    }, { __index = View })
    v.keyboardGuard = function() end
    v.updateSearchHint = function() end
    v.reloadData = function() end
    v.refreshBody = function(self) self.refreshed = (self.refreshed or 0) + 1; self.pages = 4
        self.page = math.max(1, math.min(self.page, self.pages)) end
    return v, opened
end

describe("view: back from a book", function()
    local View = loadView()

    it("comes back to the same shelf, page, filter, sort and layout; Back leads to its parent page", function()
        local v = newView(View)
        local oz
        for _, g in ipairs(v:groupsFor("series")) do if g.name == "Oz" then oz = g end end
        v.tab, v.page = "series", 2
        v:openGroup(oz)
        v.page, v.filter, v.sort, v.view_mode = 3, "unread", "title", "list"
        local spot = Core.returnSpot(v:returnState("/oz20"), 1)

        local w = newView(View) -- a fresh Library, as after the book closes
        w:restoreReturn(spot)
        eq(w.tab, "series"); eq(w.group.name, "Oz"); eq(w.page, 3)
        eq(w.filter, "unread"); eq(w.sort, "title"); eq(w.view_mode, "list")
        eq(w.query, "")
        w:closeGroup()
        eq(w.group, nil); eq(w.page, 2)
    end)

    it("clamps the page when the list got shorter", function()
        local w = newView(View)
        w:restoreReturn({ tab = "books", page = 9 })
        eq(w.page, 4)
    end)

    it("brings back the search only when the book was picked from results", function()
        local v = newView(View)
        v.query, v.page = "oz", 2
        local w = newView(View)
        w:restoreReturn(Core.returnSpot(v:returnState("/oz5"), 1))
        eq(w.query, "oz"); eq(w.search_input.text, "oz"); eq(w.page, 2)
        local x = newView(View)
        x:restoreReturn(Core.returnSpot({ tab = "books", query = "", page = 1 }, 1))
        eq(x.query, "")
    end)

    it("a shelf that is gone falls back to its tab", function()
        local w = newView(View)
        w:restoreReturn({ tab = "series", group = { kind = "series", name = "Gone" }, page = 2 })
        eq(w.tab, "series"); eq(w.group, nil)
    end)
end)

describe("view: a short flick on a cover", function()
    local View = loadView()
    local book_tile = { book = { path = "/emma" } }

    it("turns the page and does not open the book", function()
        local v, opened = newView(View)
        v.pages, v.page = 4, 1
        _G.__now_ms = 5000
        v:onTouch(nil, { pos = { x = 300, y = 400 } })
        v:onTileTap(book_tile, { pos = { x = 270, y = 405 } })
        eq(#opened, 0); eq(v.page, 2)
    end)

    it("a plain tap still opens the book", function()
        local v, opened = newView(View)
        v.pages, v.page = 4, 1
        _G.__now_ms = 5000
        v:onTouch(nil, { pos = { x = 300, y = 400 } })
        v:onTileTap(book_tile, { pos = { x = 303, y = 398 } })
        eq(opened[1], "/emma"); eq(v.page, 1)
    end)

    it("a tap right after a page turn is the end of the swipe", function()
        local v, opened = newView(View)
        v.pages, v.page = 4, 1
        _G.__now_ms = 5000
        v:goToPage(2)
        _G.__now_ms = 5150
        v:onTileTap(book_tile, { pos = { x = 300, y = 400 } })
        eq(#opened, 0)
        _G.__now_ms = 5600
        v:onTileTap(book_tile, { pos = { x = 300, y = 400 } })
        eq(opened[1], "/emma")
    end)

    it("touch never consumes the event", function()
        local v = newView(View)
        eq(v:onTouch(nil, { pos = { x = 1, y = 1 } }), false)
    end)
end)

describe("plugin: saved spot", function()
    local function plugin(pid, settings)
        local Library = load("main.lua", {
            ffi = { cdef = function() end, C = { getpid = function() return pid end } },
            ["ui/uimanager"] = { nextTick = function(_, f) f() end, scheduleIn = function() end },
            ["ui/widget/container/widgetcontainer"] = cls(),
        })
        local saved = 0
        local self = setmetatable({ settings = settings, saveSettings = function() saved = saved + 1 end },
            { __index = Library })
        return self, function() return saved end
    end
    local view = { returnState = function(_, path) return { tab = "authors", page = 2, book = path } end }

    it("is saved to the settings when a book opens, and taken once", function()
        local settings = {}
        local lib = plugin(4242, settings)
        lib:saveReturnSpot(view, "/emma")
        eq(settings.return_spot.tab, "authors"); eq(settings.return_spot.pid, 4242)
        local spot = lib:takeReturnSpot()
        eq(spot.tab, "authors"); eq(spot.page, 2); eq(spot.book, "/emma")
        eq(settings.return_spot, nil)
        eq(lib:takeReturnSpot(), nil)
    end)

    it("survives the plugin being re-created (settings copy), same run", function()
        local settings = {}
        plugin(4242, settings):saveReturnSpot(view, "/emma")
        local again = plugin(4242, settings) -- new module copy, nothing in memory
        eq(again:takeReturnSpot().tab, "authors")
    end)

    it("is not used after a fresh KOReader start", function()
        local settings = {}
        plugin(4242, settings):saveReturnSpot(view, "/emma")
        local fresh = plugin(5555, settings)
        eq(fresh:takeReturnSpot(), nil)
        eq(settings.return_spot, nil)
    end)
end)
