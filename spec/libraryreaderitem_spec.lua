-- Issue #3: a "Library" item at the top of the reader's ☰ tab. Opening the
-- Library from a book closes the book first (progress saved), then shows it.
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

local ticks
local function mainLib()
    ticks = {}
    return load("main.lua", {
        ["ui/uimanager"] = {
            show = function() end, close = function() end,
            nextTick = function(_, f) ticks[#ticks + 1] = f end,
        },
        ["ui/widget/container/widgetcontainer"] = cls(),
    })
end

local function runTicks()
    local t = ticks; ticks = {}
    for _, f in ipairs(t) do f() end
end

local function readerSelf(Library, log)
    local ui = { document = { file = "/books/Emma.epub" }, menu = {} }
    function ui.menu:onTapCloseMenu() log[#log + 1] = "close menu" end
    function ui:onClose() log[#log + 1] = "close book"; self.document = nil end
    function ui:showFileManager(file) log[#log + 1] = "file browser " .. file end
    local self = setmetatable({ settings = {}, ui = ui }, { __index = Library })
    self.barelyMenu = function() return {} end
    self.topRowMenu = function() return {} end
    self.sleepCoverMenu = function() return {} end
    return self
end

describe("Library item in the reader menu", function()
    it("Core.placeFirst puts the item first, once", function()
        local Core = require("librarycore")
        local l = { "history", "open_previous_document" }
        Core.placeFirst(l, "library_open")
        Core.placeFirst(l, "library_open")
        eq(table.concat(l, ","), "library_open,history,open_previous_document")
    end)

    it("is the first item of the ☰ tab, labelled Library, only in a book", function()
        local Library = mainLib()
        local order = { main = { "history", "open_previous_document" }, ["KOMenu:menu_buttons"] = { "navi", "filemanager", "main" } }
        package.loaded["ui/elements/reader_menu_order"] = order
        local items = {}
        Library.addToMainMenu(readerSelf(Library, {}), items)
        eq(items.library_open.text, "Library")
        eq(order.main[1], "library_open")
        eq(order.main[2], "history")
        -- the book-icon Library tab is still there too
        assert(items.library_tab, "Library tab kept")
        -- the file browser gets no such item
        local fm_items = {}
        local fm = readerSelf(Library, {}); fm.ui.document = nil
        Library.addToMainMenu(fm, fm_items)
        eq(fm_items.library_open, nil)
        package.loaded["ui/elements/reader_menu_order"] = nil
    end)

    it("tapping it closes the menu, then the book, then opens the Library over the file browser", function()
        local Library = mainLib()
        Library.shared.view = nil
        local log, items = {}, {}
        local self = readerSelf(Library, log)
        Library.addToMainMenu(self, items)
        items.library_open.callback()
        eq(table.concat(log, "; "), "close menu")
        runTicks()
        eq(table.concat(log, "; "), "close menu; close book; file browser /books/Emma.epub")
        eq(Library.shared.after_book, nil) -- no file browser instance in this spec: flag cleared
    end)

    it("the new file browser's plugin copy opens the Library once", function()
        local Library = mainLib()
        Library.shared.view = nil
        Library.shared.after_book = "show"
        _G.G_reader_settings = { readSetting = function() return { start_with_library = false } end }
        local opened = {}
        local fm = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = Library })
        fm.onShowLibrary = function(_, search) opened[#opened + 1] = search and "search" or "show" end
        Library.init(fm)
        eq(Library.shared.after_book, nil)
        runTicks()
        eq(table.concat(opened, ","), "show")
        -- a later file browser start does not open it again
        Library.init(fm); runTicks()
        eq(#opened, 1)
        _G.G_reader_settings = nil
    end)

    it("the Library gesture (ShowLibrary) from a book takes the same path", function()
        local Library = mainLib()
        Library.shared.view = nil
        local log = {}
        local self = readerSelf(Library, log)
        local fmlib = { onShowLibrary = function() log[#log + 1] = "library shown" end }
        package.loaded["apps/filemanager/filemanager"] = { instance = { library = fmlib } }
        eq(self:onShowLibrary(), true)
        runTicks()
        eq(table.concat(log, "; "), "close book; file browser /books/Emma.epub; library shown")
        package.loaded["apps/filemanager/filemanager"] = nil
    end)
end)
