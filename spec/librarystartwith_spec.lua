-- Issue #10: use KOReader's own "Start with" setting instead of the
-- plugin's custom "Open Library at startup" toggle, like BookShelf does.
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
local function fakeFMMenu()
    return {
        getStartWithMenuTable = function(_)
            return {
                text_func = function() return "Start with: file browser" end,
                sub_item_table = {
                    { text = "file browser", callback = function() end },
                    { text = "history", callback = function() end },
                },
            }
        end,
    }
end

local function mainLib(fmmenu)
    ticks = {}
    -- init() runs after load(), when require is the real one again, so the
    -- fake menu module must live in package.loaded, not in load()'s extra.
    package.loaded["apps/filemanager/filemanagermenu"] = nil
    local extra = {
        ["ui/uimanager"] = {
            show = function() end, close = function() end,
            nextTick = function(_, f) ticks[#ticks + 1] = f end,
        },
        ["ui/widget/container/widgetcontainer"] = cls(),
    }
    if fmmenu ~= false then
        package.loaded["apps/filemanager/filemanagermenu"] = fmmenu or fakeFMMenu()
    end
    return load("main.lua", extra)
end

local function runTicks()
    local t = ticks; ticks = {}
    for _, f in ipairs(t) do f() end
end

local function fakeSettings(store)
    return {
        readSetting = function(_, k) return store[k] end,
        saveSetting = function(_, k, v) store[k] = v end,
        flush = function() end,
        delSetting = function(_, k) store[k] = nil end,
    }
end

local function fmSelf(Library, store)
    _G.G_reader_settings = fakeSettings(store)
    local fm = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = Library })
    return fm
end

local function startWithTable(fmmenu)
    return fmmenu.getStartWithMenuTable(fmmenu)
end

local function findEntry(tbl, text)
    for _, e in ipairs(tbl.sub_item_table) do
        if e.text == text then return e end
    end
    return nil
end

describe("Start with menu registration", function()
    it("adds a library entry to KOReader's Start with menu", function()
        local fmmenu = fakeFMMenu()
        local Library = mainLib(fmmenu)
        local store = {}
        local fm = fmSelf(Library, store)
        Library.init(fm)
        local tbl = startWithTable(fmmenu)
        eq(#tbl.sub_item_table, 3)
        local entry = findEntry(tbl, "library")
        eq(entry ~= nil, true)
        eq(entry.radio, true)
        eq(entry.checked_func(), false)
        _G.G_reader_settings = nil
    end)

    it("labels the parent row Start with: library when chosen", function()
        local fmmenu = fakeFMMenu()
        local Library = mainLib(fmmenu)
        local store = { start_with = "library" }
        local fm = fmSelf(Library, store)
        Library.init(fm)
        eq(startWithTable(fmmenu).text_func(), "Start with: library")
        store.start_with = "history"
        eq(startWithTable(fmmenu).text_func(), "Start with: file browser")
        _G.G_reader_settings = nil
    end)

    it("adds the entry only once across repeated inits", function()
        local fmmenu = fakeFMMenu()
        local Library = mainLib(fmmenu)
        local store = {}
        local fm = fmSelf(Library, store)
        Library.init(fm)
        Library.init(fm)
        local count = 0
        for _, e in ipairs(startWithTable(fmmenu).sub_item_table) do
            if e.text == "library" then count = count + 1 end
        end
        eq(count, 1)
        _G.G_reader_settings = nil
    end)

    it("choosing library saves Start with and shows the Library now", function()
        local fmmenu = fakeFMMenu()
        local Library = mainLib(fmmenu)
        local store = {}
        local fm = fmSelf(Library, store)
        local shown, closed = {}, false
        fm.onShowLibrary = function() shown[#shown + 1] = true end
        Library.init(fm)
        local entry = findEntry(startWithTable(fmmenu), "library")
        entry.callback({ closeMenu = function() closed = true end })
        eq(store.start_with, "library")
        eq(closed, true)
        eq(#shown, 1)
        eq(entry.checked_func(), true)
        _G.G_reader_settings = nil
    end)

    it("is a no-op when the KOReader menu module is unavailable", function()
        local Library = mainLib(false)
        local store = {}
        local fm = fmSelf(Library, store)
        Library.init(fm) -- must not error; registration is skipped
        runTicks()
        _G.G_reader_settings = nil
    end)
end)

describe("Start with library at startup", function()
    it("shows the Library once on the first file-browser start", function()
        local Library = mainLib()
        local store = { start_with = "library" }
        local fm = fmSelf(Library, store)
        local shown = {}
        fm.onShowLibrary = function() shown[#shown + 1] = true end
        Library.init(fm)
        runTicks()
        eq(#shown, 1)
        -- a later file browser start does not show it again
        Library.init(fm)
        runTicks()
        eq(#shown, 1)
        _G.G_reader_settings = nil
    end)

    it("does not show the Library for other Start with values", function()
        local Library = mainLib()
        local store = { start_with = "history" }
        local fm = fmSelf(Library, store)
        local shown = {}
        fm.onShowLibrary = function() shown[#shown + 1] = true end
        Library.init(fm)
        runTicks()
        eq(#shown, 0)
        _G.G_reader_settings = nil
    end)

    it("returns to the Library after a book opened from it closes", function()
        local Library = mainLib()
        local store = { start_with = "library" }
        local fm = fmSelf(Library, store)
        local shown = {}
        fm.onShowLibrary = function() shown[#shown + 1] = true end
        Library.init(fm)
        runTicks()
        eq(#shown, 1)
        Library.shared.reopen = true -- openBook sets this
        Library.init(fm)
        runTicks()
        eq(#shown, 2)
        _G.G_reader_settings = nil
    end)

    it("stays in the file browser after a book when return is off", function()
        local Library = mainLib()
        local store = { start_with = "library", library_plugin = { return_to_library = false } }
        local fm = fmSelf(Library, store)
        local shown = {}
        fm.onShowLibrary = function() shown[#shown + 1] = true end
        Library.init(fm)
        runTicks()
        eq(#shown, 1)
        Library.shared.reopen = true
        Library.init(fm)
        runTicks()
        eq(#shown, 1)
        _G.G_reader_settings = nil
    end)
end)

describe("Migration from the old startup toggle", function()
    it("moves an enabled old toggle to Start with library", function()
        local Library = mainLib()
        local store = { library_plugin = { start_with_library = true } }
        local fm = fmSelf(Library, store)
        Library.init(fm)
        eq(store.start_with, "library")
        eq(store.library_plugin.start_with_library, nil)
        _G.G_reader_settings = nil
    end)

    it("does not overwrite an explicit Start with choice", function()
        local Library = mainLib()
        local store = { start_with = "history", library_plugin = { start_with_library = true } }
        local fm = fmSelf(Library, store)
        Library.init(fm)
        eq(store.start_with, "history")
        eq(store.library_plugin.start_with_library, nil)
        _G.G_reader_settings = nil
    end)
end)

describe("Return to Library menu entry", function()
    it("is only enabled when the Library is the home screen", function()
        local Library = mainLib()
        local store = {}
        _G.G_reader_settings = fakeSettings(store)
        local self = setmetatable({ ui = {}, settings = { return_to_library = true } }, { __index = Library })
        local items = {}
        Library.addToMainMenu(self, items)
        local entry
        for _, e in ipairs(items.library.sub_item_table) do
            if e.text == "Return to Library after closing a book" then entry = e end
        end
        eq(entry ~= nil, true)
        eq(entry.enabled_func(), false)
        store.start_with = "library"
        eq(entry.enabled_func(), true)
        _G.G_reader_settings = nil
    end)

    it("no longer offers a custom startup toggle", function()
        local Library = mainLib()
        local store = {}
        _G.G_reader_settings = fakeSettings(store)
        local self = setmetatable({ ui = {}, settings = { return_to_library = true } }, { __index = Library })
        local items = {}
        Library.addToMainMenu(self, items)
        for _, e in ipairs(items.library.sub_item_table) do
            eq(e.text ~= "Open Library at startup", true)
        end
        _G.G_reader_settings = nil
    end)
end)

-- Do not leak the fake menu module into later spec files.
package.loaded["apps/filemanager/filemanagermenu"] = nil
