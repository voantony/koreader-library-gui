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
        package.loaded["apps/filemanager/filemanager"] = { instance = { library = fm } }
        local entry = findEntry(startWithTable(fmmenu), "library")
        entry.callback({ closeMenu = function() closed = true end })
        eq(store.start_with, "library")
        eq(closed, true)
        eq(#shown, 1)
        eq(entry.checked_func(), true)
        package.loaded["apps/filemanager/filemanager"] = nil
        _G.G_reader_settings = nil
    end)

    it("shows the Library on the live file browser, not the instance that patched the menu", function()
        local fmmenu = fakeFMMenu()
        local Library = mainLib(fmmenu)
        local store = {}
        local first = fmSelf(Library, store)
        local shown = {}
        first.onShowLibrary = function() shown[#shown + 1] = "first" end
        Library.init(first)
        local second = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = Library })
        second.onShowLibrary = function() shown[#shown + 1] = "second" end
        package.loaded["apps/filemanager/filemanager"] = { instance = { library = second } }
        local entry = findEntry(startWithTable(fmmenu), "library")
        entry.callback({ closeMenu = function() end })
        eq(shown[1], "second")
        eq(#shown, 1)
        package.loaded["apps/filemanager/filemanager"] = nil
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

    it("keeps an explicit Start with and does not delete the old toggle", function()
        local Library = mainLib()
        for _, choice in ipairs({ "history", "last", "favorites" }) do
            local store = { start_with = choice, library_plugin = { start_with_library = true } }
            local fm = fmSelf(Library, store)
            Library.init(fm)
            eq(store.start_with, choice)
            eq(store.library_plugin.start_with_library, true)
        end
        _G.G_reader_settings = nil
    end)

    it("drops the old toggle once Start with is already library", function()
        local Library = mainLib()
        local store = { start_with = "library", library_plugin = { start_with_library = true } }
        local fm = fmSelf(Library, store)
        Library.init(fm)
        eq(store.start_with, "library")
        eq(store.library_plugin.start_with_library, nil)
        _G.G_reader_settings = nil
    end)

    it("migrates a kept toggle once Start with is back to the file browser", function()
        local Library = mainLib()
        local store = { start_with = "history", library_plugin = { start_with_library = true } }
        local fm = fmSelf(Library, store)
        Library.init(fm)
        eq(store.library_plugin.start_with_library, true)
        store.start_with = "filemanager"
        Library.init(fm)
        eq(store.start_with, "library")
        eq(store.library_plugin.start_with_library, nil)
        _G.G_reader_settings = nil
    end)
end)

describe("After closing a book, and On startup", function()
    it("offers Return to Library and Return to file browser", function()
        local Library = mainLib()
        local store = {}
        _G.G_reader_settings = fakeSettings(store)
        local self = setmetatable({
            ui = {}, settings = { return_to_library = true }, saveSettings = function() end,
        }, { __index = Library })
        local items = {}
        Library.addToMainMenu(self, items)
        local entry
        for _, e in ipairs(items.library.sub_item_table) do
            if e.text_func and e.text_func():find("After closing a book", 1, true) == 1 then
                entry = e
            end
        end
        eq(entry ~= nil, true)
        eq(entry.sub_item_table[1].text, "Return to Library")
        eq(entry.sub_item_table[2].text, "Return to file browser")
        eq(entry.sub_item_table[1].checked_func(), true)
        eq(entry.sub_item_table[2].checked_func(), false)
        entry.sub_item_table[2].callback()
        eq(self.settings.after_close, "filemanager")
        eq(self.settings.return_to_library, false)
        eq(entry.sub_item_table[2].checked_func(), true)
        eq(entry.text_func(), "After closing a book: Return to file browser")
        _G.G_reader_settings = nil
    end)

    it("Resume last book saves Start with last and does not leave it on library", function()
        local Library = mainLib()
        local store = { start_with = "library" }
        _G.G_reader_settings = fakeSettings(store)
        local self = setmetatable({
            ui = {}, settings = {}, saveSettings = function() end,
        }, { __index = Library })
        local items = {}
        Library.addToMainMenu(self, items)
        local entry
        for _, e in ipairs(items.library.sub_item_table) do
            if e.text_func and e.text_func():find("On startup", 1, true) == 1 then entry = e end
        end
        eq(entry.sub_item_table[1].text, "Open Library")
        eq(entry.sub_item_table[2].text, "Resume last book")
        eq(entry.sub_item_table[1].checked_func(), true)
        entry.sub_item_table[2].callback()
        eq(self.settings.on_startup, "last")
        eq(store.start_with, "last")
        eq(entry.sub_item_table[2].checked_func(), true)
        eq(entry.sub_item_table[1].checked_func(), false)
        eq(entry.text_func(), "On startup: Resume last book")
        _G.G_reader_settings = nil
    end)

    it("offers Left-edge brightness off by default, next to Gestures", function()
        local Library = mainLib()
        local self = setmetatable({
            ui = {}, settings = {}, saveSettings = function() end,
        }, { __index = Library })
        local items = {}
        Library.addToMainMenu(self, items)
        local brightness, gestures, bi, gi
        for i, e in ipairs(items.library.sub_item_table) do
            if e.text == "Left-edge brightness" then brightness, bi = e, i end
            if e.text == "Gestures" then gestures, gi = e, i end
        end
        eq(brightness ~= nil, true)
        eq(gestures ~= nil, true)
        eq(gi, bi + 1)
        eq(brightness.checked_func(), false)
        eq(brightness.help_text:find("vertical swipe", 1, true) ~= nil, true)
        eq(brightness.help_text:find("Off by default", 1, true) ~= nil, true)
        eq(brightness.help_text:find("file browser", 1, true) ~= nil, true)
        eq(brightness.help_text:find("gesture setting", 1, true) ~= nil, true)
        eq(gestures.help_text:find("left edge setting brightness", 1, true), nil)
        eq(gestures.help_text:find("Left-edge brightness is off", 1, true) ~= nil, true)
        brightness.callback()
        eq(self.settings.edge_brightness, true)
        eq(brightness.checked_func(), true)
        brightness.callback()
        eq(self.settings.edge_brightness, false)
        eq(brightness.checked_func(), false)
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
