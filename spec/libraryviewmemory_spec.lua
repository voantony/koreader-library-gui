-- Per-shelf memory: every place in the Library (the Books tab, a tab's list,
-- one collection, author or series) remembers its own layout, sort and
-- status filter, and "Reset to default" forgets them.
local Core = require("librarycore")

describe("Core.viewKey", function()
    it("names the Books tab, the other tabs and single groups", function()
        eq(Core.viewKey("books", nil), "books")
        eq(Core.viewKey(nil, nil), "books")
        eq(Core.viewKey("authors", nil), "tab:authors")
        eq(Core.viewKey("series", { kind = "series", name = "Oz" }), "series:Oz")
        eq(Core.viewKey("collections", { kind = "collections", name = "Favorites" }), "collections:Favorites")
        eq(Core.viewKey("authors", { kind = "authors", name = "Jane Austen" }), "authors:Jane Austen")
    end)
    it("keeps a series and an author of the same name apart", function()
        local a = Core.viewKey("series", { kind = "series", name = "Mars" })
        local b = Core.viewKey("authors", { kind = "authors", name = "Mars" })
        eq(a ~= b, true)
    end)
end)

describe("Core.viewPrefs", function()
    it("starts from grid, Recent, All", function()
        local prefs, remembered = Core.viewPrefs({}, "series:Oz")
        same(prefs, { view = "grid", sort = "recent", filter = "all" })
        eq(remembered, false)
    end)
    it("uses the Books tab's layout and sort as the default everywhere", function()
        local s = { view = "list", sort = "title" }
        same((Core.viewPrefs(s, "series:Oz")), { view = "list", sort = "title", filter = "all" })
        local _p, remembered = Core.viewPrefs(s, "books")
        eq(remembered, true, "the Books tab differs from the defaults")
    end)
    it("lays a place's own choices over the default", function()
        local s = { view = "grid", sort = "recent", view_memory = { ["series:Oz"] = { view = "list", filter = "unread" } } }
        local prefs, remembered = Core.viewPrefs(s, "series:Oz")
        same(prefs, { view = "list", sort = "recent", filter = "unread" })
        eq(remembered, true)
        same((Core.viewPrefs(s, "series:Mars")), { view = "grid", sort = "recent", filter = "all" })
    end)
    it("ignores broken saved values", function()
        local s = { view = "mosaic", sort = "bogus", view_memory = { x = { view = 3, sort = "nope", filter = "maybe" } } }
        local prefs, remembered = Core.viewPrefs(s, "x")
        same(prefs, { view = "grid", sort = "recent", filter = "all" })
        eq(remembered, false)
    end)
    it("returns nil when the memory is turned off", function()
        eq(Core.viewPrefs({ remember_views = false }, "series:Oz"), nil)
        eq(Core.rememberViews({ remember_views = false }), false)
        eq(Core.rememberViews({}), true)
        eq(Core.rememberViews(nil), true)
    end)
end)

describe("Core.rememberViewPref", function()
    it("stores a group's layout, sort and filter in view_memory", function()
        local s = {}
        eq(Core.rememberViewPref(s, "series:Oz", "view", "list", 100), true)
        eq(Core.rememberViewPref(s, "series:Oz", "filter", "finished", 101), true)
        eq(Core.rememberViewPref(s, "series:Oz", "sort", "title", 102), true)
        eq(s.view_memory["series:Oz"].view, "list")
        eq(s.view_memory["series:Oz"].filter, "finished")
        eq(s.view_memory["series:Oz"].sort, "title")
        eq(s.view, nil, "the default is untouched")
    end)
    it("reports no change for the same value", function()
        local s = {}
        Core.rememberViewPref(s, "k", "view", "list")
        eq(Core.rememberViewPref(s, "k", "view", "list"), false)
    end)
    it("writes the default layout and sort from the Books tab, as before", function()
        local s = { view = "grid", sort = "recent" }
        eq(Core.rememberViewPref(s, "books", "view", "list"), true)
        eq(Core.rememberViewPref(s, "books", "sort", "author"), true)
        eq(s.view, "list"); eq(s.sort, "author")
        eq(s.view_memory, nil)
        Core.rememberViewPref(s, "books", "filter", "reading")
        eq(s.view_memory.books.filter, "reading")
        eq(Core.defaultPrefs(s).filter, "reading")
    end)
    it("rejects unknown values", function()
        local s = {}
        eq(Core.rememberViewPref(s, "k", "view", "mosaic"), false)
        eq(Core.rememberViewPref(s, "k", "filter", "maybe"), false)
        eq(Core.rememberViewPref(s, "k", "nonsense", "x"), false)
        eq(s.view_memory, nil)
    end)
    it("stores nothing for groups while the memory is off", function()
        local s = { remember_views = false }
        eq(Core.rememberViewPref(s, "series:Oz", "view", "list"), false)
        eq(s.view_memory, nil)
    end)
    it("drops the oldest places past the limit", function()
        local mem = { books = { filter = "reading" } }
        for i = 1, 5 do mem["k" .. i] = { view = "list", t = i } end
        eq(Core.pruneViewMemory(mem, 3), 2)
        eq(mem.k1, nil); eq(mem.k2, nil)
        eq(mem.k3 ~= nil and mem.k5 ~= nil, true)
        eq(mem.books.filter, "reading", "the Books tab entry is kept")
    end)
end)

describe("reset", function()
    it("forgets one place", function()
        local s = { view_memory = { ["series:Oz"] = { view = "list" }, ["series:Mars"] = { view = "list" } } }
        Core.resetViewPrefs(s, "series:Oz")
        eq(s.view_memory["series:Oz"], nil)
        eq(s.view_memory["series:Mars"].view, "list")
        eq(Core.countViewMemory(s), 1)
    end)
    it("puts the Books tab back to grid, Recent, All", function()
        local s = { view = "list", sort = "title", view_memory = { books = { filter = "unread" }, x = { view = "list" } } }
        Core.resetViewPrefs(s, "books")
        same(Core.defaultPrefs(s), { view = "grid", sort = "recent", filter = "all" })
        eq(s.view_memory.x.view, "list", "other places keep theirs")
    end)
    it("forgets every place but keeps the default", function()
        local s = { view = "list", view_memory = { books = { filter = "unread" }, a = { view = "grid" }, b = { sort = "title" } } }
        Core.resetAllViewPrefs(s)
        eq(Core.countViewMemory(s), 0)
        eq(s.view_memory.books.filter, "unread")
        eq(s.view, "list")
    end)
end)

----------------------------------------------------------------------------
-- LibraryView: moving between places applies what each remembers
----------------------------------------------------------------------------

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function withStubbedUI(fn)
    local real = {
        libraryview = true, librarycore = true, librarytile = true, librarycovers = true,
        string = true, table = true, math = true, io = true, os = true,
    }
    local base_class = {}
    base_class.__index = base_class
    function base_class:extend(o)
        o = o or {}
        o.__index = o
        return setmetatable(o, self)
    end
    local old_require = require
    _G.require = function(name)
        if real[name] then return old_require(name) end
        if name == "ui/widget/container/inputcontainer" then return base_class end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
        return stub()
    end
    package.loaded.libraryview = nil
    local ok, err = pcall(fn)
    _G.require = old_require
    package.loaded.libraryview = nil
    if not ok then error(err, 0) end
end

--- A view with the drawing stubbed out and a plugin backed by `settings`.
local function newView(LibraryView, settings)
    local plugin = {
        settings = settings,
        viewPrefs = function(self, key) return Core.viewPrefs(self.settings, key) end,
        rememberViewPref = function(self, key, field, value)
            if Core.rememberViews(self.settings) then
                Core.rememberViewPref(self.settings, key, field, value)
            elseif field ~= "filter" then
                self.settings[field] = value
            end
        end,
        resetViewPrefs = function(self, key) Core.resetViewPrefs(self.settings, key) end,
    }
    local view = setmetatable({}, LibraryView)
    view.plugin = plugin
    view.tab, view.group, view.page = "books", nil, 1
    local d = Core.defaultPrefs(settings)
    view.view_mode, view.sort, view.filter = d.view, d.sort, d.filter
    view.search_input = { isKeyboardVisible = function() return false end }
    view.query = ""
    view.reloads = 0
    view.refreshBody = function() end
    view.reloadData = function(self) self.reloads = self.reloads + 1; self.groups_cache = {} end
    view.groupsFor = function(self, kind)
        -- fresh tables each time, like a re-sort would make
        return { { kind = kind, name = "Oz", books = { self.sort } }, { kind = kind, name = "Mars", books = {} } }
    end
    return view
end

describe("LibraryView per-shelf memory", function()
    it("opens a series the way it was left, and the tab the way it was", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local s = {}
            local view = newView(LibraryView, s)
            view:setTab("series")
            view:openGroup({ kind = "series", name = "Oz", books = {} })
            view:setViewMode("list")
            view:setFilter("unread")
            eq(view.view_mode, "list")
            view:closeGroup()
            eq(view.view_mode, "grid", "the Series list keeps its own layout")
            eq(view.filter, "all")
            view:openGroup({ kind = "series", name = "Mars", books = {} })
            eq(view.view_mode, "grid", "another series is untouched")
            view:closeGroup()
            view:openGroup({ kind = "series", name = "Oz", books = {} })
            eq(view.view_mode, "list", "Oz comes back as a list")
            eq(view.filter, "unread")
        end)
    end)

    it("re-sorts and picks the open group again when its sort differs", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local s = { view_memory = { ["collections:Oz"] = { sort = "title" } } }
            local view = newView(LibraryView, s)
            view:setTab("collections")
            view:openGroup({ kind = "collections", name = "Oz", books = { "stale" } })
            eq(view.sort, "title")
            eq(view.reloads, 1)
            eq(view.group.books[1], "title", "the group's books follow the new sort")
            view:resort("author")
            eq(s.view_memory["collections:Oz"].sort, "author")
            eq(view.group.books[1], "author")
            view:closeGroup()
            eq(view.sort, "recent", "back to the default outside")
        end)
    end)

    it("uses the Books tab as the default for places never changed", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local s = {}
            local view = newView(LibraryView, s)
            view:setViewMode("list")
            eq(s.view, "list", "the Books tab sets the default, as before")
            view:setTab("authors")
            eq(view.view_mode, "list")
            view:openGroup({ kind = "authors", name = "Mars", books = {} })
            eq(view.view_mode, "list")
        end)
    end)

    it("resets the place you are in", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local s = {}
            local view = newView(LibraryView, s)
            view:setTab("series")
            view:openGroup({ kind = "series", name = "Oz", books = {} })
            view:setViewMode("list")
            eq(view:hasRemembered(), true)
            eq(view:placeName(), "Oz")
            view:resetRemembered()
            eq(view.view_mode, "grid")
            eq(view:hasRemembered(), false)
            eq(s.view_memory["series:Oz"], nil)
        end)
    end)

    it("behaves as before with the memory turned off", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local s = { remember_views = false }
            local view = newView(LibraryView, s)
            view:setFilter("reading")
            view:setTab("series")
            view:openGroup({ kind = "series", name = "Oz", books = {} })
            eq(view.filter, "reading", "the filter stays as it was while browsing")
            view:setViewMode("list")
            eq(s.view, "list", "layout is global")
            eq(s.view_memory, nil)
            view:closeGroup()
            eq(view.view_mode, "list")
        end)
    end)

    it("works with a plugin that has no memory (older callers)", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local view = newView(LibraryView, {})
            view.plugin = {}
            view:setTab("series")
            view:setViewMode("list")
            eq(view.view_mode, "list")
            eq(view:hasRemembered(), false)
        end)
    end)
end)
