-- Closing the Library: no X; "Close Library" is the last item of the
-- three-bar menu. The menu and Resume buttons are in the footer.
-- The Back key still closes (or leaves a shelf).
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

describe("Library footer buttons", function()
    local Core = require("librarycore")
    local shown
    local function viewWith(extra)
        shown = {}
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/uimanager"] = { show = function(_, w) shown[#shown + 1] = w end, close = function() end },
            ["ui/widget/infomessage"] = { new = function(_, o) return o end },
        })
        return setmetatable(extra or {}, { __index = View })
    end

    it("is the menu button and a Resume button that needs a book", function()
        local off = Core.footerChrome(false)
        eq(off[1].icon, "appbar.menu")
        eq(off[1].enabled, true)
        eq(off[2].icon, "book.opened")
        eq(off[2].enabled, false, "no last book: Resume is not tappable")
        eq(Core.footerChrome(true)[2].enabled, true)
        eq(#Core.footerChrome(true), 2)
    end)

    it("Resume opens the last book, including from inside a shelf", function()
        local book = { path = "/b/emma.epub", title = "Emma", percent = 0.62 }
        local v = viewWith({ last_book = book })
        local opened
        v.keyboardGuard = function() end
        v.plugin = { openBook = function(_, path, view) opened = path; eq(view, v) end }
        v:onResume()
        eq(opened, "/b/emma.epub")
        v.group = { kind = "series", name = "Oz" }; v.tab = "series"; opened = nil
        v:onResume()
        eq(opened, "/b/emma.epub")
        v:showResumeHint()
        eq(shown[1].text, "Resume: Emma  ·  62 %")
    end)

    it("tracks the last book as the library changes", function()
        local books = {}
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
        })
        local v = setmetatable({ width = 1264, sort = "recent" }, { __index = View })
        v.plugin = { getBooks = function() return books end, collate = function(a, b) return a < b end }
        v:reloadData()
        eq(v.last_book, nil)
        eq(Core.footerChrome(v.last_book ~= nil)[2].enabled, false)
        books = { { path = "/a.epub", title = "A", status = "reading", percent = 0.3, last_opened = 100 } }
        v:reloadData()
        eq(v.last_book.path, "/a.epub")
        eq(Core.footerChrome(true)[2].enabled, true)
        books = {}
        v:reloadData()
        eq(v.last_book, nil)
    end)

    it("the menu button opens the Library menu", function()
        local v = viewWith()
        local opened
        v.plugin = { showLibraryMenu = function(_, view) opened = view end }
        v:onLeftIcon()
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
