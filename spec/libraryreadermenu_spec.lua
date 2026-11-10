-- Simple reader menu: tapping the top of a page opens a small panel instead
-- of KOReader's full reader menu; More… opens the full one exactly as the tap
-- used to. Also Exit KOReader (with a confirm) in that panel and in Controls.
local RM = require("libraryreadermenu")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, libraryreadermenu = true, string = true, table = true, math = true }
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

local ticks, shown, closed
local function mainLib()
    ticks, shown, closed = {}, {}, {}
    return load("main.lua", {
        ["ui/uimanager"] = {
            show = function(_, w) shown[#shown + 1] = w end,
            close = function(_, w) closed[#closed + 1] = w end,
            nextTick = function(_, f) ticks[#ticks + 1] = f end,
        },
        ["ui/widget/container/widgetcontainer"] = cls(),
        ["ui/event"] = { new = function(_, name, ...) return { name = name, args = { ... } } end },
        ["device"] = { hasFrontlight = function() return true end, isTouchDevice = function() return true end,
            screen = stub() },
    })
end
local function runTicks() local t = ticks; ticks = {}; for _, f in ipairs(t) do f() end end

-- A ReaderMenu-like object: the method KOReader's top tap zones call.
local function fakeReader(log, activation)
    local ReaderMenu = {}
    ReaderMenu.__index = ReaderMenu
    function ReaderMenu:onTapShowMenu(ges) log[#log + 1] = "full menu " .. tostring(ges and ges.tag); return true end
    function ReaderMenu:onSwipeShowMenu() log[#log + 1] = "full menu (swipe)"; return true end
    function ReaderMenu:registerToMainMenu() end
    local menu = setmetatable({ activation_menu = activation or "swipe_tap" }, ReaderMenu)
    local ui = { document = { file = "/books/Emma.epub", getPageCount = function() return 300 end },
        menu = menu, toc = {}, search = {}, config = {}, bookmark = { isPageBookmarked = function() return true end },
        doc_props = { display_title = "Emma" } }
    function ui:getCurrentPage() return 12 end
    function ui:handleEvent(ev) log[#log + 1] = "event " .. ev.name end
    return ui, ReaderMenu
end

local FakePanel = {}
FakePanel.__index = FakePanel
function FakePanel:new(o) return setmetatable(o, FakePanel) end
function FakePanel:show() self.is_shown = true end

local function readerLib(Library, ui, settings)
    local self = setmetatable({ settings = settings or { simple_reader_menu = true }, ui = ui }, { __index = Library })
    return self
end

describe("opening the next screen after the panel closes", function()
    it("waits until the panel strip has been repainted", function()
        local ran = false
        local ui = {
            tickAfterNext = function(_, fn) ran = true; fn() end,
            nextTick = function() error("nextTick paints the next screen in the same frame as the strip") end,
        }
        eq(RM.afterPanelClose(ui, function() end), "tickAfterNext")
        eq(ran, true)
    end)

    it("uses nextTick only when that is all KOReader offers", function()
        local ran = false
        local ui = { nextTick = function(_, fn) ran = true; fn() end }
        eq(RM.afterPanelClose(ui, function() end), "nextTick")
        eq(ran, true)
        eq(RM.afterPanelClose({}, function() end), "now")
        eq(RM.afterPanelClose(nil, nil), nil)
    end)
end)

describe("Simple reader menu: pure parts", function()
    it("lists the buttons in panel order, leaving out what the reader lacks", function()
        same(RM.items({ toc = true, search = true, config = true, light = true, bookmark = true }),
            { "library", "toc", "goto", "search", "font", "light", "bookmark", "details" })
        same(RM.items({}), { "library", "goto", "details" })
        same(RM.items({ light = true }), { "library", "goto", "light", "details" })
        same(RM.items(nil), { "library", "goto", "details" })
    end)
    it("takes the tap only when on and KOReader's tap opens a menu at all", function()
        eq(RM.shouldIntercept(true, "swipe_tap"), true)
        eq(RM.shouldIntercept(nil, "tap"), true, "nil setting counts as on")
        eq(RM.shouldIntercept(nil, nil), true)
        eq(RM.shouldIntercept(false, "swipe_tap"), false, "setting off")
        eq(RM.shouldIntercept(true, "swipe"), false, "swipe-only menu: a tap opens nothing")
    end)
    it("chooses the Library GUI bar by default, and KOReader's menu when asked", function()
        eq(RM.topTapMode(nil), "bar")
        eq(RM.topTapMode({}), "bar")
        eq(RM.topTapMode({ simple_reader_menu = true }), "bar")
        eq(RM.topTapMode({ top_tap = "bar" }), "bar")
        eq(RM.topTapMode({ top_tap = "koreader" }), "koreader")
        eq(RM.topTapMode({ top_tap = "nope" }), "bar", "unknown value is the bar")
        eq(RM.topTapMode({ simple_reader_menu = false }), "koreader", "old checkbox, off")
        eq(RM.topTapMode({ top_tap = "bar", simple_reader_menu = false }), "bar", "explicit choice wins")
        eq(RM.topTapMode({ top_tap = "koreader", simple_reader_menu = true }), "koreader")
        local s = {}
        eq(RM.setTopTapMode(s, "koreader"), "koreader")
        eq(s.top_tap, "koreader")
        eq(s.simple_reader_menu, false, "old checkbox stays in step")
        eq(RM.setTopTapMode(s, "bar"), "bar")
        eq(s.top_tap, "bar")
        eq(s.simple_reader_menu, true)
        eq(RM.setTopTapMode(s, "other"), "bar")
        local legacy = { simple_reader_menu = false }
        RM.migrateTopTap(legacy)
        eq(legacy.top_tap, "koreader")
        RM.migrateTopTap(legacy)
        eq(legacy.top_tap, "koreader", "a saved choice is left alone")
        local chosen = { top_tap = "bar", simple_reader_menu = false }
        RM.migrateTopTap(chosen)
        eq(chosen.top_tap, "bar")
        eq(RM.opensLibraryBar({ top_tap = "bar" }, "tap"), true)
        eq(RM.opensLibraryBar({ top_tap = "koreader" }, "tap"), false)
        eq(RM.opensLibraryBar({ top_tap = "koreader" }, "swipe_tap"), false)
        eq(RM.opensLibraryBar({ top_tap = "bar" }, "swipe"), false, "swipe-only: a tap opens nothing")
        eq(RM.opensLibraryBar({}, nil), true)
        eq(RM.opensLibraryBar({ simple_reader_menu = false }, "swipe_tap"), false)
    end)
    it("writes the progress line", function()
        eq(RM.progressText(12, 300, 12 / 300), "Page 12 of 300  \u{00B7}  4 %")
        eq(RM.progressText(nil, nil, 0.5), "50 %")
        eq(RM.progressText(3, 10, nil), "Page 3 of 10")
        eq(RM.progressText(nil, 0, nil), "")
        eq(RM.progressText(1, 2, 0.5, { page_of = "S. %d / %d" }), "S. 1 / 2  \u{00B7}  50 %")
    end)
    it("lays out 8 buttons as 4 x 2 under the title, with More… and Exit below", function()
        local L = RM.layout(1264, 1680, 8)
        eq(L.cols, 4); eq(L.rows, 2)
        eq(#L.tiles, 8)
        assert(L.tiles[5].y > L.tiles[1].y, "second row lower")
        eq(L.tiles[5].x, L.tiles[1].x)
        assert(L.more.y > L.tiles[8].y + L.tiles[8].h - 1, "More under the buttons")
        eq(L.exit.y, L.more.y, "Exit beside More")
        assert(L.exit.x > L.more.x + L.more.w, "Exit right of More")
        assert(L.more.w > L.exit.w, "More is the wide one")
        assert(L.bottom < 1680 / 2, "panel stays in the top half: " .. L.bottom)
        eq(L.panel.y < 0, true, "top corners hang off screen")
    end)
    it("fewer buttons fit one row; landscape keeps 8 in one row", function()
        eq(RM.layout(1264, 1680, 3).cols, 3)
        eq(RM.layout(1264, 1680, 3).rows, 1)
        local L = RM.layout(1680, 1264, 8)
        eq(L.rows, 1)
        assert(L.bottom < 1264 * 0.6)
    end)
    it("says what a tap hits", function()
        local L = RM.layout(1264, 1680, 8)
        local t = L.tiles[6]
        eq(select(2, RM.hit(L, t.x + 5, t.y + 5)), 6)
        eq(RM.hit(L, t.x + 5, t.y + 5), "tile")
        eq(RM.hit(L, L.more.x + 10, L.more.y + 10), "more")
        eq(RM.hit(L, L.exit.x + 10, L.exit.y + 10), "exit")
        eq(RM.hit(L, L.left + 5, L.title_y + 5), "panel", "title: inside, does nothing")
        eq(RM.hit(L, 600, 1500), nil, "page below: close")
    end)
end)

describe("Simple reader menu: the top tap", function()
    it("opens the small panel instead of KOReader's full menu", function()
        local Library = mainLib()
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = FakePanel
        local log = {}
        local ui = readerLib(Library, (fakeReader(log)))
        ui:hookReaderMenuTap()
        eq(ui.ui.menu:onTapShowMenu({ tag = "t1" }), true)
        eq(#log, 0, "full menu not opened")
        local p = Library.shared.reader_panel
        assert(p and p.is_shown, "panel shown")
        eq(p.title, "Emma")
        eq(p.subtitle, "Page 12 of 300  \u{00B7}  4 %")
        local ids = {}
        for _, a in ipairs(p.actions) do ids[#ids + 1] = a.id end
        eq(table.concat(ids, ","), "library,toc,goto,search,font,light,bookmark,details")
        eq(p.actions[7].on(), true, "bookmarked page shows as on")
        -- a second tap while it is open does not stack another panel
        ui.ui.menu:onTapShowMenu({})
        eq(Library.shared.reader_panel, p)
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = nil
    end)
    it("More… opens KOReader's full menu exactly like the old tap (same gesture)", function()
        local Library = mainLib()
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = FakePanel
        local log = {}
        local ui = readerLib(Library, (fakeReader(log)))
        ui:hookReaderMenuTap()
        ui.ui.menu:onTapShowMenu({ tag = "right-third" })
        Library.shared.reader_panel.on_more()
        eq(table.concat(log, ";"), "full menu right-third")
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = nil
    end)
    it("buttons send KOReader's own events", function()
        local Library = mainLib()
        Library.shared.reader_panel = nil
        local log = {}
        local self = readerLib(Library, (fakeReader(log)))
        local by = {}
        for _, a in ipairs(self:simpleMenuActions()) do by[a.id] = a end
        by.toc.run(); by["goto"].run(); by.search.run(); by.font.run(); by.bookmark.run()
        eq(table.concat(log, ";"), "event ShowToc;event ShowGotoDialog;event ShowFulltextSearchInput;event ShowConfigMenu;event ToggleBookmark")
    end)
    it("goes straight through when the old checkbox is off", function()
        local Library = mainLib()
        package.loaded.libraryreaderpanel = FakePanel
        local log = {}
        local self = readerLib(Library, (fakeReader(log)), { simple_reader_menu = false })
        self:hookReaderMenuTap()
        self.ui.menu:onTapShowMenu({ tag = "x" })
        eq(table.concat(log, ";"), "full menu x")
        eq(Library.shared.reader_panel, nil)
        -- and turning it back on works without reopening the book
        self.settings.simple_reader_menu = true
        self.ui.menu:onTapShowMenu({})
        assert(Library.shared.reader_panel, "panel now")
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = nil
    end)
    it("opens KOReader's own menu on a top tap when set to KOReader menu", function()
        local Library = mainLib()
        package.loaded.libraryreaderpanel = FakePanel
        local log = {}
        local self = readerLib(Library, (fakeReader(log)), { top_tap = "koreader", simple_reader_menu = true })
        self:hookReaderMenuTap()
        eq(self.ui.menu:onTapShowMenu({ tag = "native" }), true)
        eq(table.concat(log, ";"), "full menu native")
        eq(Library.shared.reader_panel, nil, "the Library GUI bar stays closed")
        -- the same hook follows a change back to the bar, without reopening the book
        self.settings.top_tap = "bar"
        self.settings.simple_reader_menu = true
        self.ui.menu:onTapShowMenu({ tag = "bar" })
        assert(Library.shared.reader_panel and Library.shared.reader_panel.is_shown, "bar now")
        eq(table.concat(log, ";"), "full menu native", "KOReader's menu was not opened for the bar")
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = nil
    end)
    it("opens the Library GUI bar when that choice is stored", function()
        local Library = mainLib()
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = FakePanel
        local log = {}
        local self = readerLib(Library, (fakeReader(log)), { top_tap = "bar" })
        self:hookReaderMenuTap()
        eq(self.ui.menu:onTapShowMenu({ tag = "top" }), true)
        eq(#log, 0, "KOReader's menu not opened")
        assert(Library.shared.reader_panel and Library.shared.reader_panel.is_shown, "bar shown")
        Library.shared.reader_panel = nil
        -- switching to KOReader menu uses the same tap handler
        self.settings.top_tap = "koreader"
        self.ui.menu:onTapShowMenu({ tag = "again" })
        eq(table.concat(log, ";"), "full menu again")
        eq(Library.shared.reader_panel, nil)
        package.loaded.libraryreaderpanel = nil
    end)
    it("leaves a swipe-only Activate menu setting alone", function()
        local Library = mainLib()
        package.loaded.libraryreaderpanel = FakePanel
        local log = {}
        local self = readerLib(Library, (fakeReader(log, "swipe")))
        self:hookReaderMenuTap()
        self.ui.menu:onTapShowMenu({ tag = "s" })
        eq(table.concat(log, ";"), "full menu s", "KOReader's own method decides (it opens nothing for real)")
        eq(Library.shared.reader_panel, nil)
        package.loaded.libraryreaderpanel = nil
    end)
    it("does not touch the swipe down, and hooks only once", function()
        local Library = mainLib()
        package.loaded.libraryreaderpanel = FakePanel
        local log = {}
        local ui, ReaderMenu = fakeReader(log)
        local self = readerLib(Library, ui)
        self:hookReaderMenuTap()
        local hooked = ui.menu.onTapShowMenu
        self:hookReaderMenuTap()
        eq(ui.menu.onTapShowMenu, hooked, "second init does not wrap again")
        eq(rawget(ui.menu, "onSwipeShowMenu"), nil, "swipe method untouched")
        eq(ReaderMenu.onTapShowMenu ~= hooked, true, "class method untouched (other books unaffected)")
        ui.menu:onSwipeShowMenu()
        eq(table.concat(log, ";"), "full menu (swipe)")
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = nil
    end)
    it("falls back to KOReader's menu if the panel can't load", function()
        local Library = mainLib()
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = nil
        local old = package.preload.libraryreaderpanel
        package.preload.libraryreaderpanel = function() error("boom") end
        local log = {}
        local self = readerLib(Library, (fakeReader(log)))
        self:hookReaderMenuTap()
        self.ui.menu:onTapShowMenu({ tag = "f" })
        eq(table.concat(log, ";"), "full menu f")
        package.preload.libraryreaderpanel = old
        package.loaded.libraryreaderpanel = nil
    end)
    it("has a ☰ choice, Library GUI bar by default, saved with the other settings", function()
        local Library = mainLib()
        local self = readerLib(Library, (fakeReader({})), {})
        local saved_key, saved
        _G.G_reader_settings = {
            saveSetting = function(_, key, value) saved_key, saved = key, value end,
        }
        local item = self:topTapMenu()
        eq(item.text_func(), "Top tap opens: Library GUI bar")
        eq(#item.sub_item_table, 2)
        eq(item.sub_item_table[1].text, "Library GUI bar")
        eq(item.sub_item_table[2].text, "KOReader menu")
        eq(item.sub_item_table[1].radio, true)
        eq(item.sub_item_table[2].radio, true)
        eq(item.sub_item_table[1].checked_func(), true)
        eq(item.sub_item_table[2].checked_func(), false)
        item.sub_item_table[2].callback()
        eq(self.settings.top_tap, "koreader")
        eq(self.settings.simple_reader_menu, false)
        eq(saved_key, "library_plugin")
        eq(saved.top_tap, "koreader")
        eq(item.text_func(), "Top tap opens: KOReader menu")
        eq(item.sub_item_table[1].checked_func(), false)
        eq(item.sub_item_table[2].checked_func(), true)
        item.sub_item_table[1].callback()
        eq(self.settings.top_tap, "bar")
        eq(self.settings.simple_reader_menu, true)
        eq(saved.top_tap, "bar")
        eq(item.text_func(), "Top tap opens: Library GUI bar")
        _G.G_reader_settings = nil
    end)
    it("reads a turned-off Simple reader menu as KOReader menu at startup", function()
        local Library = mainLib()
        local stored = { simple_reader_menu = false }
        _G.G_reader_settings = {
            readSetting = function() return stored end,
            saveSetting = function() end,
        }
        local ui = {
            document = { file = "/books/Emma.epub" },
            menu = { registerToMainMenu = function() end, onTapShowMenu = function() return true end },
        }
        local self = setmetatable({ ui = ui }, { __index = Library })
        Library.init(self)
        eq(self.settings.top_tap, "koreader")
        eq(self.settings.simple_reader_menu, false)
        -- a fresh install still gets the bar
        stored = {}
        local fresh = setmetatable({ ui = ui }, { __index = Library })
        Library.init(fresh)
        eq(fresh.settings.top_tap, "bar")
        eq(fresh.settings.simple_reader_menu, true)
        _G.G_reader_settings = nil
    end)
end)

describe("Exit KOReader", function()
    it("asks first; Exit closes our windows, then sends KOReader's Exit event", function()
        local Library = mainLib()
        local confirm
        package.loaded["ui/widget/confirmbox"] = { new = function(_, o) confirm = o; return o end }
        local log = {}
        local self = readerLib(Library, (fakeReader(log)))
        local view, controls = { name = "view" }, { name = "controls" }
        Library.shared.view, Library.shared.controls = view, controls
        self:confirmExit()
        eq(confirm.text, "Exit KOReader?")
        eq(confirm.ok_text, "Exit")
        eq(#log, 0, "nothing happens before the confirm")
        confirm.ok_callback()
        eq(table.concat(log, ";"), "event Exit")
        eq(Library.shared.view, nil)
        eq(Library.shared.controls, nil)
        local names = {}
        for _, w in ipairs(closed) do names[#names + 1] = w.name end
        eq(table.concat(names, ","), "controls,view")
        package.loaded["ui/widget/confirmbox"] = nil
    end)
    it("the reader panel's Exit button asks the same question", function()
        local Library = mainLib()
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = FakePanel
        local asked = 0
        local self = readerLib(Library, (fakeReader({})))
        self.confirmExit = function() asked = asked + 1 end
        self:showSimpleMenu(function() end)
        Library.shared.reader_panel.on_exit()
        eq(asked, 1)
        Library.shared.reader_panel = nil
        package.loaded.libraryreaderpanel = nil
    end)
    it("Rotate from a book only rotates (does not open the Library)", function()
        local Library = mainLib()
        local log = {}
        local self = readerLib(Library, (fakeReader(log)))
        self.onShowLibrary = function() log[#log + 1] = "library" end
        self:rotateLibrary()
        runTicks()
        eq(table.concat(log, ";"), "event IterateRotation")
    end)
    it("closes the Library, rotates, then rebuilds it where it was", function()
        local Library = mainLib()
        local log = {}
        local ui = { handleEvent = function(_, ev) log[#log + 1] = "event " .. ev.name end }
        local self = setmetatable({ settings = {}, ui = ui }, { __index = Library })
        local restored
        local view = { placeState = function() return { tab = "authors", page = 3 } end }
        Library.shared.view = view
        self.onShowLibrary = function()
            log[#log + 1] = "show"
            Library.shared.view = {
                restorePlace = function(_, st)
                    restored = st
                    log[#log + 1] = "restore"
                end,
            }
            return true
        end
        package.loaded["apps/reader/readerui"] = nil
        package.loaded["apps/filemanager/filemanager"] = { instance = { library = self } }
        eq(self:rotateForEvent({ name = "IterateRotation" }), true)
        eq(closed[#closed], view, "the old layout is closed before the screen turns")
        eq(table.concat(log, ";"), "event IterateRotation")
        runTicks()
        eq(table.concat(log, ";"), "event IterateRotation;show;restore")
        eq(restored.tab, "authors")
        eq(restored.page, 3)
        Library.shared.view = nil
        package.loaded["apps/filemanager/filemanager"] = nil
    end)
end)

describe("Packaging", function()
    it("the release zip and the Kindle staging script ship every plugin file", function()
        local files = {}
        local p = io.popen("ls library.koplugin")
        for f in p:lines() do if f:match("%.lua$") then files[#files + 1] = f end end
        p:close()
        assert(#files >= 12, "found plugin files")
        for _, path in ipairs({ "Makefile", "tools/stage_for_kindle.sh" }) do
            local fh = assert(io.open(path)); local s = fh:read("*a"); fh:close()
            local line = s:match("FILES%s*:?=%s*\"?([^\n\"]+)")
            for _, f in ipairs(files) do
                assert((" " .. line .. " "):find(" " .. f:gsub("%.", "%%.") .. " "), path .. " is missing " .. f)
            end
        end
    end)
end)
