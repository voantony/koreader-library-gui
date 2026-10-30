-- Closing the Library: no X in the title bar; "Close Library" is the last
-- item of the three-bar menu. The Back key still closes (or leaves a shelf).
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
    }
    local self = setmetatable({ settings = { columns = 4 }, saveSettings = function() end }, { __index = Library })
    Library.showLibraryMenu(self, view)
    return shown[1], view, closed
end

describe("Close Library", function()
    it("is the last item of the three-bar menu", function()
        local dialog = menuFor()
        local rows = dialog.buttons
        local last = rows[#rows]
        eq(#last, 1)
        eq(last[1].text, "\u{2715} Close Library")
        for i = 1, #rows - 1 do
            for _, b in ipairs(rows[i]) do
                eq(tostring(b.text):find("Close Library", 1, true), nil, "only once")
            end
        end
    end)

    it("is still last inside a shelf (with Reset in the menu)", function()
        local dialog = menuFor({ key = "series:Oz" })
        local rows = dialog.buttons
        eq(rows[#rows][1].text, "\u{2715} Close Library")
    end)

    it("closes the menu and then the whole Library", function()
        local dialog, view, closed = menuFor()
        local rows = dialog.buttons
        rows[#rows][1].callback()
        eq(#closed, 2)
        eq(closed[1], dialog)
        eq(closed[2], view)
    end)
end)

describe("Library title bar", function()
    local shown
    local function titleBarArgs(last_book)
        local args
        shown = {}
        local TitleBar = { new = function(_, o) args = o; return o end }
        local View = load("libraryview.lua", {
            ["ui/widget/titlebar"] = TitleBar,
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/uimanager"] = { show = function(_, w) shown[#shown + 1] = w end },
            ["ui/widget/infomessage"] = { new = function(_, o) return o end },
        })
        local v = setmetatable({ width = 1264, last_book = last_book }, { __index = View })
        v.buildSearchRow = function() end
        v:buildChrome()
        return args, v
    end

    it("has the menu button and no X", function()
        local a = titleBarArgs()
        eq(a.left_icon, "appbar.menu")
        eq(a.close_callback, nil)
        eq(a.right_icon, nil, "no last book: no Resume icon")
    end)

    it("shows a Resume icon that opens the last book", function()
        local book = { path = "/b/emma.epub", title = "Emma", percent = 0.62 }
        local a, v = titleBarArgs(book)
        eq(a.right_icon, "book.opened")
        eq(a.close_callback, nil)
        local opened
        v.keyboardGuard = function() end
        v.plugin = { openBook = function(_, path, view) opened = path; eq(view, v) end }
        a.right_icon_tap_callback()
        eq(opened, "/b/emma.epub")
        -- works inside a shelf too: nothing depends on the tab or group
        v.group = { kind = "series", name = "Oz" }; v.tab = "series"; opened = nil
        a.right_icon_tap_callback()
        eq(opened, "/b/emma.epub")
        -- long-press: the book's title as a hint
        a.right_icon_hold_callback()
        eq(shown[1].text, "Resume: Emma  ·  62 %")
    end)

    it("shows or hides the icon when the books change", function()
        local args = {}
        local TitleBar = { new = function(_, o) args[#args + 1] = o; return o end }
        local books
        local View = load("libraryview.lua", {
            ["ui/widget/titlebar"] = TitleBar,
            ["ui/widget/container/inputcontainer"] = cls(),
        })
        local v = setmetatable({ width = 1264, sort = "recent" }, { __index = View })
        v.plugin = { getBooks = function() return books end }
        v:buildTitleBar()
        eq(args[1].right_icon, nil)
        books = { { path = "/a.epub", title = "A", status = "reading", percent = 0.3, last_opened = 100 } }
        v:reloadData()
        eq(#args, 2, "rebuilt once")
        eq(args[2].right_icon, "book.opened")
        eq(v._title_changed, true, "whole view repainted")
        v:reloadData()
        eq(#args, 2, "no rebuild when nothing changed")
        books = {}
        v:reloadData()
        eq(args[3].right_icon, nil)
    end)

    it("the menu button opens the Library menu", function()
        local a, v = titleBarArgs()
        local opened
        v.plugin = { showLibraryMenu = function(_, view) opened = view end }
        a.left_icon_tap_callback()
        eq(opened, v)
    end)
end)

describe("Back key", function()
    it("still closes the Library, or leaves an open shelf first", function()
        local closed = {}
        local UIManager = { close = function(_, w) closed[#closed + 1] = w end }
        local View = load("libraryview.lua", {
            ["ui/uimanager"] = UIManager,
            ["ui/widget/container/inputcontainer"] = cls(),
        })
        local v = setmetatable({}, { __index = View })
        local left_group = false
        v.group = { kind = "series" }
        v.closeGroup = function(self) left_group = true; self.group = nil end
        eq(v:onClose(), true)
        eq(left_group, true); eq(#closed, 0)
        eq(v:onClose(), true)
        eq(closed[1], v)
    end)
end)
