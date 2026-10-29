-- Loads main.lua against minimal stand-ins for KOReader modules and drives
-- the views with the dummy fixture library. Catches typos, nil calls and
-- broken navigation without needing a device or emulator.
local F = require("fixtures.fake_library")

local shown, closed, opened, ticks = {}, {}, {}, {}
local settings_store = {}

local function class()
    local C = {}
    C.__index = C
    function C:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function C:new(o) o = o or {}; setmetatable(o, self); if o.init then o:init() end; return o end
    return C
end

local Menu = class()
function Menu:init() self.item_table_stack = {}; self.page = 1; self.perpage = 10 end
function Menu:switchItemTable(title, items, itemnumber, _, subtitle)
    self.title, self.item_table, self.subtitle = title, items, subtitle
end
local BookList = Menu:extend{ book_info_cache = {} }
function BookList.getBookStatus(path) return F.get_status(path) end
function BookList.getBookStatusString(s) return s and ("<" .. s .. ">") or nil end
function BookList.resetBookInfoCache() end
function BookList.hasBookBeenOpened() return false end

local stubs = {
    ["ui/bidi"] = { dirpath = function(p) return p end, directory = function(p) return p end,
                    filename = function(p) return p end },
    ["ui/widget/booklist"] = BookList,
    ["ui/widget/buttondialog"] = class(),
    ["ui/widget/infomessage"] = class(),
    ["ui/widget/inputdialog"] = class(),
    ["ui/widget/container/widgetcontainer"] = class(),
    ["dispatcher"] = { registerAction = function() end },
    ["document/documentregistry"] = { hasProvider = function(_, p) return F.is_book(p) end },
    ["ui/uimanager"] = {
        show = function(_, w) table.insert(shown, w) end,
        close = function(_, w) table.insert(closed, w) end,
        forceRePaint = function() end,
        nextTick = function(_, fn) table.insert(ticks, fn); fn() end,
    },
    ["ffi/util"] = {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
        strcoll = function(a, b) return a < b end,
    },
    ["apps/filemanager/filemanagerutil"] = {
        getHomeFolder = function() return F.root end,
        abbreviate = function(p) return p end,
        openFile = function(_, file, pre) table.insert(opened, file); if pre then pre() end end,
        genStatusButtonsRow = function() return {} end,
        genShowFolderButton = function() return {} end,
        genBookInformationButton = function() return {} end,
        showChooseDialog = function() end,
    },
    ["libs/libkoreader-lfs"] = {
        dir = F.fs.dir,
        attributes = function(p, field)
            local a = F.fs.attributes(p)
            if field then return a and a[field] end
            return a
        end,
    },
    ["logger"] = { warn = function() end, err = function(...) print("ERR", ...) end },
    ["gettext"] = setmetatable({}, { __call = function(_, s) return s end }),
}
for name, mod in pairs(stubs) do
    package.loaded[name] = mod
end
_G.G_reader_settings = {
    readSetting = function(_, k) return settings_store[k] end,
    saveSetting = function(_, k, v) settings_store[k] = v end,
}

package.loaded["librarycore"] = nil
local Library = dofile("library.koplugin/main.lua")
local meta = dofile("library.koplugin/_meta.lua")

local function newPlugin()
    local menu_items = {}
    local ui = {
        menu = { registerToMainMenu = function(_, p) p:addToMainMenu(menu_items) end },
        bookinfo = { getDocProps = function(_, path) return F.get_props(path) end },
    }
    local plugin = Library:new{ ui = ui }
    return plugin, menu_items
end

local function find(items, text)
    for _, it in ipairs(items) do
        if it.text == text then return it end
    end
    error("no item " .. text)
end

describe("main.lua smoke", function()
    it("has metadata", function()
        eq(meta.name, "library")
    end)

    it("registers a main menu entry", function()
        local _, items = newPlugin()
        eq(items.library.text, "Library")
        eq(items.library.sorting_hint, "main")
        eq(items.library.sub_item_table[4].text_func(), "Library folder: " .. F.root)
    end)

    it("opens the home view with counts", function()
        local plugin = newPlugin()
        plugin:onShowLibrary()
        local menu = plugin.menu
        eq(menu.title, "Library (7)")
        eq(find(menu.item_table, "All books").mandatory, "7")
        eq(find(menu.item_table, "Currently reading").mandatory, "2")
        eq(find(menu.item_table, "Authors").mandatory, "5")
    end)

    it("navigates authors -> books -> back -> back", function()
        local plugin = newPlugin()
        plugin:onShowLibrary()
        local menu = plugin.menu
        menu:onMenuSelect(find(menu.item_table, "Authors"))
        eq(menu.title, "Authors (5)")
        eq(menu.item_table[#menu.item_table].text, "Unknown author")
        menu:onMenuSelect(find(menu.item_table, "Jane Austen"))
        eq(menu.title, "Jane Austen (3)")
        eq(menu.item_table[1].text, "Emma — Jane Austen")
        eq(menu.item_table[1].mandatory, "<reading>")
        menu.onReturn()
        eq(menu.title, "Authors (5)")
        menu.onReturn()
        eq(menu.title, "Library (7)")
        eq(#menu.paths, 0)
    end)

    it("orders a series by index", function()
        local plugin = newPlugin()
        plugin:onShowLibrary()
        local menu = plugin.menu
        menu:onMenuSelect(find(menu.item_table, "Series"))
        menu:onMenuSelect(find(menu.item_table, "Wells Classics"))
        eq(menu.item_table[1].text, "1. The Time Machine — H. G. Wells")
        eq(menu.item_table[2].text, "2. The War of the Worlds — H. G. Wells")
    end)

    it("opens a book on tap and closes the menu", function()
        local plugin = newPlugin()
        plugin:onShowLibrary()
        local menu = plugin.menu
        menu:onMenuSelect(find(menu.item_table, "All books"))
        local before = #opened
        menu:onMenuSelect(menu.item_table[1])
        eq(#opened, before + 1)
        eq(plugin.menu, nil)
    end)

    it("searches", function()
        local plugin = newPlugin()
        plugin:showSearchResults("shelley")
        eq(plugin.menu.title, "Search results (1)")
        eq(plugin.menu.subtitle, "Query: shelley")
        plugin.menu.onReturn()
        eq(plugin.menu.title, "Library (7)")
    end)

    it("persists settings and rescans", function()
        local plugin, items = newPlugin()
        local hidden = items.library.sub_item_table[6]
        hidden.callback()
        eq(settings_store.library_plugin.show_hidden, true)
        plugin:onRescanLibrary()
        plugin:onShowLibrary()
        eq(plugin.menu.title, "Library (8)")
        hidden.callback()
        plugin:onRescanLibrary()
    end)
end)
