-- Layouts: the View picker (Small/Medium/Large covers, List, Compact),
-- Authors as a text list by default, and what list and compact rows say.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

-- Load a plugin file with KOReader stubbed; `extra[name]` overrides a module.
local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, string = true, table = true, math = true }
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

local function menuFor(view_opts)
    local shown, closed = {}, {}
    local UIManager = {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function(_, w) closed[#closed + 1] = w end,
        nextTick = function(_, f) f() end, scheduleIn = function() end,
    }
    local ButtonDialog = { new = function(_, o) return o end }
    local Library = load("main.lua", {
        ["ui/uimanager"] = UIManager,
        ["ui/widget/buttondialog"] = ButtonDialog,
        ["ui/widget/container/widgetcontainer"] = cls(),
    })
    local view = {
        sort = "recent", view_mode = "grid",
        placeName = function() return "Books" end,
        viewKey = function() return (view_opts or {}).key or "books" end,
        hasRemembered = function() return false end,
        setColumns = function(v, n) v.cols_set = n end,
        setViewMode = function(v, m) v.view_mode = m end,
    }
    for k, val in pairs((view_opts or {}).view or {}) do view[k] = val end
    local self = setmetatable({ settings = (view_opts or {}).settings or { columns = 4 }, saveSettings = function() end }, { __index = Library })
    Library.showLibraryMenu(self, view)
    return shown[1], view, closed
end


local Core = require("librarycore")

describe("View picker", function()
    local function texts(row) local t = {} for i, b in ipairs(row) do t[i] = b.text end return t end
    it("is Small, Medium, Large covers, List, Compact", function()
        local dialog = menuFor()
        same(texts(dialog.buttons[2]), { "Small covers", "\u{2713} Medium covers", "Large covers", "List", "Compact" })
    end)
    it("ticks List / Compact by the place's view", function()
        local dialog = menuFor({ view = { view_mode = "compact" } })
        same(texts(dialog.buttons[2]), { "Small covers", "Medium covers", "Large covers", "List", "\u{2713} Compact" })
    end)
    it("Large covers sets 3 columns and the grid", function()
        local settings = { columns = 4 }
        local dialog, view = menuFor({ settings = settings, view = { view_mode = "list" } })
        dialog.buttons[2][3].callback()
        eq(settings.columns, 3); eq(view.cols_set, 3); eq(view.view_mode, "grid")
        dialog.buttons[2][5].callback()
        eq(view.view_mode, "compact")
    end)
    it("keeps the sort row in the asked order", function()
        local dialog = menuFor({ view = { sort = "added" } })
        same(texts(dialog.buttons[1]), { "Author", "Title", "\u{2713} Date added", "Last read", "Series" })
    end)
end)

describe("Core views", function()
    it("knows compact; unknown falls back to grid", function()
        eq(Core.viewMode("compact"), "compact"); eq(Core.viewMode("tiles"), "grid")
        eq(Core.viewPick("grid", 5), "small"); eq(Core.viewPick("grid", 3), "large")
        eq(Core.viewPick("grid", 6), nil); eq(Core.viewPick("list", 6), "list")
    end)
    it("Authors starts as a list; Series and Books start with covers; a choice is remembered", function()
        local s = { view = "grid" }
        eq(Core.viewPrefs(s, "tab:authors").view, "list")
        eq(Core.viewPrefs(s, "tab:series").view, "grid")
        eq(Core.viewPrefs(s, "books").view, "grid")
        local _p, remembered = Core.viewPrefs(s, "tab:authors")
        eq(remembered, false, "the default is not a remembered change")
        Core.rememberViewPref(s, "tab:authors", "view", "grid", 1)
        eq(Core.viewPrefs(s, "tab:authors").view, "grid", "covers when picked")
        Core.rememberViewPref(s, "tab:series", "view", "list", 1)
        eq(Core.viewPrefs(s, "tab:series").view, "list")
        Core.rememberViewPref(s, "books", "view", "compact", 1)
        eq(Core.viewPrefs(s, "books").view, "compact")
    end)
    it("text rows only for Authors and Series shelves in List", function()
        eq(Core.textRows("list", "groups", "authors"), true)
        eq(Core.textRows("list", "groups", "series"), true)
        eq(Core.textRows("list", "groups", "collections"), false)
        eq(Core.textRows("grid", "groups", "authors"), false)
        eq(Core.textRows("list", "books", "authors"), false)
    end)
end)

describe("row text", function()
    local Tiles = load("librarytile.lua", {})
    local book = { title = "Mort", authors = { "Terry Pratchett" }, series = "Discworld", series_index = 4,
        status = "reading", percent = 0.42 }
    it("compact: Title · Author, or Author · Title when sorted by author", function()
        local l, r = Tiles.compactText(book, "books")
        eq(l, "Mort · Terry Pratchett"); eq(r, "42 %")
        eq((Tiles.compactText(book, "books", false, true)), "Terry Pratchett · Mort")
        eq((Tiles.compactText({ title = "Anon", status = "complete" }, "books", false, true)), "Anon")
        eq(select(2, Tiles.compactText({ title = "X", status = "complete" }, "books")), "\u{2713}")
        eq(select(2, Tiles.compactText({ title = "X", status = "new", percent = 0 }, "books")), "")
    end)
    it("compact shelves: name (· authors) and the count", function()
        local series = { kind = "series", name = "Discworld", books = { book, { authors = { "Terry Pratchett" } } } }
        local l, r = Tiles.compactText(series, "groups")
        eq(l, "Discworld · Terry Pratchett"); eq(r, "2 books")
        l, r = Tiles.compactText({ kind = "authors", name = "Jane Austen", books = { {} } }, "groups")
        eq(l, "Jane Austen"); eq(r, "1 book")
    end)
    it("list: the authors first when sorted by author", function()
        local a, b = Tiles.bookLines(book)
        eq(a, "Mort"); eq(b, "Terry Pratchett · Discworld #4")
        a, b = Tiles.bookLines(book, false, true)
        eq(a, "Terry Pratchett"); eq(b, "Mort · Discworld #4")
    end)
end)
