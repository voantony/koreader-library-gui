-- Closing a book should paint the Library before KOReader's file browser,
-- and the two menu choices (after close, and startup) should stick.
local Return = require("libraryreturn")

describe("After closing a book", function()
    it("defaults to the Library, and keeps an explicit choice", function()
        eq(Return.afterClose(nil, nil), "library")
        eq(Return.afterClose(nil, true), "library")
        eq(Return.afterClose("library", false), "library")
        eq(Return.afterClose("filemanager", true), "filemanager")
    end)
    it("reads the old checkbox when it was turned off", function()
        eq(Return.afterClose(nil, false), "filemanager")
    end)
end)

describe("On startup", function()
    it("resumes the last book when that is saved or when KOReader starts on last", function()
        eq(Return.resumesLastBook("last", "library"), true)
        eq(Return.resumesLastBook("library", "last"), true)
        eq(Return.resumesLastBook(nil, "last"), true)
        eq(Return.resumesLastBook("library", "library"), false)
        eq(Return.resumesLastBook(nil, "library"), false)
        eq(Return.startupChoice("last", "library"), "last")
        eq(Return.startupChoice(nil, "library"), "library")
        eq(Return.startupChoice(nil, "filemanager"), nil)
    end)
    it("does not open the Library over a reader KOReader already started", function()
        eq(Return.plan{
            has_document = true, first = true, home = true, start_with = "library",
        }, nil)
    end)
    it("does not open the Library at startup when resuming the last book", function()
        eq(Return.plan{
            first = true, home = true, start_with = "library", on_startup = "last",
        }, nil)
        eq(Return.plan{
            first = true, home = false, start_with = "last", on_startup = "library",
        }, nil)
    end)
    it("opens the Library once when Start with is library", function()
        eq(Return.plan{
            first = true, home = true, start_with = "library",
        }, "show")
        eq(Return.plan{
            first = false, home = true, start_with = "library",
        }, nil)
    end)
end)

describe("Where a closed book lands", function()
    it("returns to the Library when the book was opened from it", function()
        eq(Return.plan{
            reopen = true, home = false, start_with = "history",
        }, "show")
        eq(Return.plan{
            reopen = true, home = true, closed_book = true,
        }, "show")
    end)
    it("returns to the Library when the Library is the home screen", function()
        eq(Return.plan{
            closed_book = true, home = true, reopen = false,
        }, "show")
    end)
    it("stays in the file browser when that choice is saved", function()
        eq(Return.plan{
            reopen = true, home = true, closed_book = true,
            after_close = "filemanager",
        }, nil)
        eq(Return.plan{
            reopen = true, home = true, legacy_return = false,
        }, nil)
    end)
    it("stays in the file browser for a book that was not opened from the Library", function()
        eq(Return.plan{
            closed_book = true, home = false, reopen = false, start_with = "filemanager",
        }, nil)
    end)
    it("still opens the Library when a book asks for it", function()
        eq(Return.plan{
            after_book = "show", after_close = "filemanager", reopen = true,
        }, "show")
        eq(Return.plan{
            after_book = "search", after_close = "filemanager",
        }, "search")
    end)
end)

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = {
        librarycore = true, libraryindex = true, libraryreturn = true,
        libraryrefresh = true, string = true, table = true, math = true,
    }
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

local function fakeSettings(store)
    return {
        readSetting = function(_, k) return store[k] end,
        saveSetting = function(_, k, v) store[k] = v end,
        flush = function() end,
        delSetting = function(_, k) store[k] = nil end,
    }
end

-- KOReader's file-browser button calls showFileManager and then forceRePaint.
-- The Library has to be on the stack before that paint.
local function harness(store, opts)
    opts = opts or {}
    local events = {}
    local painted = false
    local ticks = {}
    local UIManager = {
        show = function(_, w, mode)
            if painted then error("painted before the close call returned") end
            events[#events + 1] = { kind = "show", w = w, mode = mode }
        end,
        close = function() end,
        setDirty = function(_, w, mode)
            events[#events + 1] = { kind = "dirty", w = w, mode = mode }
        end,
        forceRePaint = function()
            painted = true
            events[#events + 1] = { kind = "paint" }
        end,
        nextTick = function(_, f) ticks[#ticks + 1] = f end,
    }
    package.loaded["apps/filemanager/filemanagermenu"] = nil
    local Library = load("main.lua", {
        ["ui/uimanager"] = UIManager,
        ["ui/widget/container/widgetcontainer"] = cls(),
    })
    local FileManager = {}
    local ReaderUI = { library = nil }
    function FileManager:showFiles()
        events[#events + 1] = { kind = "filemanager" }
        FileManager.instance = { library = ReaderUI.library }
        Library.init(ReaderUI.library)
        UIManager:show("filemanager")
    end
    function ReaderUI:showFileManager(file)
        if FileManager.instance then
            events[#events + 1] = { kind = "retarget", file = file }
        else
            FileManager:showFiles(file)
        end
    end
    package.loaded["apps/filemanager/filemanager"] = FileManager
    package.loaded["apps/reader/readerui"] = ReaderUI
    _G.G_reader_settings = fakeSettings(store)
    local fm = setmetatable({
        ui = { menu = { registerToMainMenu = function() end } },
    }, { __index = Library })
    fm.onShowLibrary = function(_, search, opts)
        events[#events + 1] = {
            kind = "library",
            search = search and true or false,
            full = opts and opts.full or false,
        }
        Library.shared.view = { name = "library" }
    end
    ReaderUI.library = fm
    if opts.before_init then opts.before_init(Library, fm) end
    Library.init(fm)
    return {
        Library = Library,
        fm = fm,
        FileManager = FileManager,
        ReaderUI = ReaderUI,
        events = events,
        ticks = ticks,
        UIManager = UIManager,
        libraryCount = function()
            local n = 0
            for _, e in ipairs(events) do if e.kind == "library" then n = n + 1 end end
            return n
        end,
        sawPaint = function()
            for _, e in ipairs(events) do if e.kind == "paint" then return true end end
            return false
        end,
    }
end

local function libraryFollowsFileManager(events)
    local fm_at, lib_at, paint_at
    for i, e in ipairs(events) do
        if e.kind == "filemanager" or (e.kind == "show" and e.w == "filemanager") then
            fm_at = fm_at or i
        elseif e.kind == "library" then
            lib_at = i
        elseif e.kind == "paint" then
            paint_at = i
        end
    end
    return fm_at, lib_at, paint_at
end

describe("Close paints the Library before the file browser", function()
    it("shows the Library, full refresh, before any paint, for a Library book", function()
        local store = { start_with = "history" }
        local h = harness(store)
        h.Library.shared.reopen = true
        h.Library.shared.closed_book = true
        -- The file browser button. TouchMenu forceRePaints after this returns.
        h.ReaderUI:showFileManager("/books/Emma.epub")
        eq(h.sawPaint(), false)
        eq(h.libraryCount(), 1)
        eq(h.Library.shared.return_pending, nil)
        local fm_at, lib_at = libraryFollowsFileManager(h.events)
        eq(fm_at ~= nil, true)
        eq(lib_at ~= nil, true)
        eq(fm_at < lib_at, true)
        local lib = h.events[lib_at]
        eq(lib.full, true)
        eq(lib.search, false)
        local full = false
        for _, e in ipairs(h.events) do
            if e.kind == "dirty" and e.mode == "full" then full = true end
        end
        eq(full, true)
        h.UIManager:forceRePaint()
        local _, _, paint_at = libraryFollowsFileManager(h.events)
        eq(lib_at < paint_at, true)
        -- A queued tick must not open it a second time.
        for _, f in ipairs(h.ticks) do f() end
        eq(h.libraryCount(), 1)
        _G.G_reader_settings = nil
    end)

    it("does the same when the Library is the home screen", function()
        local h = harness({ start_with = "library" }, {
            before_init = function(Library) Library.shared.started = true end,
        })
        h.Library.shared.closed_book = true
        h.ReaderUI:showFileManager("/books/Emma.epub")
        eq(h.sawPaint(), false)
        eq(h.libraryCount(), 1)
        local fm_at, lib_at = libraryFollowsFileManager(h.events)
        eq(fm_at < lib_at, true)
        eq(h.events[lib_at].full, true)
        _G.G_reader_settings = nil
    end)

    it("leaves the file browser on screen when that is the choice", function()
        local h = harness({
            start_with = "library",
            library_plugin = { after_close = "filemanager", return_to_library = false },
        }, {
            before_init = function(Library) Library.shared.started = true end,
        })
        h.Library.shared.reopen = true
        h.Library.shared.closed_book = true
        h.ReaderUI:showFileManager("/books/Emma.epub")
        eq(h.libraryCount(), 0)
        local fm_at = libraryFollowsFileManager(h.events)
        eq(fm_at ~= nil, true)
        h.UIManager:forceRePaint()
        eq(h.sawPaint(), true)
        eq(h.libraryCount(), 0)
        _G.G_reader_settings = nil
    end)

    it("does not open the Library for a book opened from the file browser", function()
        local h = harness({ start_with = "history" }, {
            before_init = function(Library) Library.shared.started = true end,
        })
        h.Library.shared.closed_book = true
        h.Library.shared.reopen = false
        h.ReaderUI:showFileManager("/books/Emma.epub")
        eq(h.libraryCount(), 0)
        eq(libraryFollowsFileManager(h.events) ~= nil, true)
        _G.G_reader_settings = nil
    end)

    it("retargets an existing file browser and still paints the Library first", function()
        local h = harness({ start_with = "history" })
        h.FileManager.instance = { library = h.fm }
        h.Library.shared.reopen = true
        h.ReaderUI:showFileManager("/books/Emma.epub")
        eq(h.sawPaint(), false)
        eq(h.libraryCount(), 1)
        local retarget_at, lib_at
        for i, e in ipairs(h.events) do
            if e.kind == "retarget" then retarget_at = i end
            if e.kind == "library" then lib_at = i end
            if e.kind == "filemanager" then error("a new file browser was created") end
        end
        eq(retarget_at < lib_at, true)
        eq(h.events[lib_at].full, true)
        _G.G_reader_settings = nil
    end)
end)

describe("Startup does not cover a resumed book", function()
    it("does not show the Library when KOReader opened a reader", function()
        local shown = 0
        local ticks = {}
        local Library = load("main.lua", {
            ["ui/uimanager"] = {
                show = function() end, close = function() end,
                nextTick = function(_, f) ticks[#ticks + 1] = f end,
            },
            ["ui/widget/container/widgetcontainer"] = cls(),
        })
        local store = { start_with = "library", library_plugin = { on_startup = "last" } }
        _G.G_reader_settings = fakeSettings(store)
        local fm = setmetatable({
            ui = {
                document = { file = "/books/Emma.epub" },
                menu = { registerToMainMenu = function() end },
            },
            onShowLibrary = function() shown = shown + 1 end,
        }, { __index = Library })
        Library.init(fm)
        for _, f in ipairs(ticks) do f() end
        eq(shown, 0)
        eq(store.start_with, "last")
        eq(Library.shared.return_pending, nil)
        _G.G_reader_settings = nil
    end)

    it("does not show the Library on the file browser when Start with is last", function()
        local h = harness({ start_with = "last", library_plugin = { on_startup = "library" } })
        for _, f in ipairs(h.ticks) do f() end
        eq(h.libraryCount(), 0)
        eq(h.fm.ui and true or false, true)
        -- KOReader's last wins: we do not write Start with back to library.
        local store_start = _G.G_reader_settings:readSetting("start_with")
        eq(store_start, "last")
        _G.G_reader_settings = nil
    end)
end)

describe("Library menu dialogs", function()
    it("closes After closing a book through the refresh helper", function()
        local shown = {}
        local Library = load("main.lua", {
            ["ui/uimanager"] = {
                show = function(_, w) shown[#shown + 1] = w end,
                close = function() end,
                nextTick = function(_, f) f() end,
            },
            ["ui/widget/buttondialog"] = { new = function(_, o) return o end },
            ["ui/widget/container/widgetcontainer"] = cls(),
        })
        local closed
        local view = {}
        local self = setmetatable({
            settings = { return_to_library = true },
            saveSettings = function() end,
            closeOverLibrary = function(_, widget, v)
                closed = { widget = widget, view = v }
            end,
        }, { __index = Library })
        local dialog = Library.showAfterCloseDialog(self, view)
        eq(shown[1], dialog)
        eq(dialog.buttons[1][1].text, "\u{2713} Return to Library")
        eq(dialog.buttons[2][1].text, "Return to file browser")
        dialog.buttons[2][1].callback()
        eq(closed.widget, dialog)
        eq(closed.view, view)
        eq(self.settings.after_close, "filemanager")
        eq(self.settings.return_to_library, false)
        dialog.buttons[1][1].callback()
        eq(self.settings.after_close, "library")
        eq(self.settings.return_to_library, true)
    end)

    it("closes On startup through the refresh helper and saves both choices", function()
        local Library = load("main.lua", {
            ["ui/uimanager"] = {
                show = function() end, close = function() end,
                nextTick = function(_, f) f() end,
            },
            ["ui/widget/buttondialog"] = { new = function(_, o) return o end },
            ["ui/widget/container/widgetcontainer"] = cls(),
        })
        local store = { start_with = "filemanager" }
        _G.G_reader_settings = fakeSettings(store)
        local closed = 0
        local self = setmetatable({
            settings = {},
            saveSettings = function() end,
            closeOverLibrary = function() closed = closed + 1 end,
        }, { __index = Library })
        local dialog = Library.showOnStartupDialog(self, {})
        eq(dialog.buttons[1][1].text, "Open Library")
        eq(dialog.buttons[2][1].text, "Resume last book")
        dialog.buttons[2][1].callback()
        eq(closed, 1)
        eq(self.settings.on_startup, "last")
        eq(store.start_with, "last")
        dialog.buttons[1][1].callback()
        eq(closed, 2)
        eq(self.settings.on_startup, "library")
        eq(store.start_with, "library")
        _G.G_reader_settings = nil
    end)

    it("a full return builds the index without painting the file browser first", function()
        local paints = 0
        local shown = {}
        local Library = load("main.lua", {
            ["ui/uimanager"] = {
                show = function(_, w, mode) shown[#shown + 1] = { w = w, mode = mode } end,
                close = function() end,
                forceRePaint = function() paints = paints + 1 end,
                setDirty = function() end,
                nextTick = function() end,
            },
            ["ui/widget/container/widgetcontainer"] = cls(),
        })
        Library.shared.view = nil
        local ensured = false
        local view = { name = "library" }
        local self = setmetatable({
            settings = {},
            ui = {},
            timer = function() return { start = function() end, arm = function() end } end,
            getIndex = function() return { needs_build = true } end,
            ensureIndex = function() ensured = true end,
            newView = function() return view end,
            takeReturnSpot = function() return nil end,
        }, { __index = Library })
        Library.onShowLibrary(self, false, { full = true })
        eq(paints, 0)
        eq(ensured, true)
        eq(shown[1].w, view)
        eq(shown[1].mode, "full")
        eq(#shown, 1)
    end)
end)

package.loaded["apps/filemanager/filemanager"] = nil
package.loaded["apps/reader/readerui"] = nil
package.loaded["apps/filemanager/filemanagermenu"] = nil
_G.G_reader_settings = nil
