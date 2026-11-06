-- Reader status bar: current page out of the total by default, a short
-- tap cycle, and a long-press picker (libraryfooter.lua).
local Footer = require("libraryfooter")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o) o = o or {}; return setmetatable(o, self) end
    return base
end

local saved
local function mainLib(stored_footer, stored_mode)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, libraryreadermenu = true,
        librarybezel = true, libraryfooter = true, string = true, table = true, math = true }
    saved = _G.G_reader_settings
    local footer_store = stored_footer
    local mode_store = stored_mode
    _G.G_reader_settings = {
        readSetting = function(_, k)
            if k == "footer" then return footer_store end
            if k == "reader_footer_mode" then return mode_store end
        end,
        saveSetting = function(_, k, v)
            if k == "footer" then footer_store = v end
            if k == "reader_footer_mode" then mode_store = v end
        end,
    }
    _G.require = function(name)
        if name == "device" then
            return { model = "KindleColorSoft", hasFrontlight = function() return true end,
                isTouchDevice = function() return true end,
                screen = { scaleBySize = function(_, v) return v * 2 end } }
        end
        if name == "ui/widget/container/widgetcontainer" then return cls() end
        if name == "ui/widget/buttondialog" then
            return { new = function(_, o) return o end }
        end
        if name == "ui/uimanager" then
            return { show = function() end, close = function() end }
        end
        if name == "ui/event" then
            return { new = function(_, name, ...) return { name = name, args = { ... } } end }
        end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/main.lua")
    _G.require = old_require
    if not ok then _G.G_reader_settings = saved; error(mod, 0) end
    return mod
end

local function modeTables()
    local mode_index = {
        [0] = "off",
        [1] = "page_progress",
        [2] = "pages_left_book",
        [3] = "time",
        [4] = "pages_left",
        [6] = "percentage",
        [7] = "book_time_to_read",
        [8] = "chapter_time_to_read",
    }
    local mode_list = {}
    for n, name in pairs(mode_index) do mode_list[name] = n end
    return mode_index, mode_list
end

local function reader(Library, settings, footer_settings, mode)
    local refreshed, events = {}, {}
    local mode_index, mode_list = modeTables()
    local dimen = {
        contains = function(_, pos)
            return pos and pos.x and pos.x >= 0 and pos.y and pos.y >= 1000
        end,
    }
    local footer = {
        settings = footer_settings or {},
        mode = mode or Footer.MODE.pages_left,
        mode_index = mode_index,
        mode_list = mode_list,
        pageno = 42,
        pages = 310,
        percent_finished = 0.135,
        footer_content = { dimen = dimen },
    }
    function footer:applyFooterMode(m) self.mode = m end
    function footer:onUpdateFooter() refreshed[#refreshed + 1] = "update" end
    function footer:refreshFooter() refreshed[#refreshed + 1] = "refresh" end
    function footer:onHoldFooter() events[#events + 1] = "orig-hold"; return "orig-hold" end
    function footer:onToggleFooterMode() events[#events + 1] = "orig-cycle"; return "orig-cycle" end
    local lib = setmetatable({
        settings = settings,
        ui = { document = {}, view = { footer = footer, footer_visible = true } },
        saveSettings = function() end,
    }, { __index = Library })
    return lib, footer, refreshed, events
end

describe("Reader status bar: default to page out of total", function()
    it("switches pages-left views to current page / total, once", function()
        eq(Footer.plan{ current = "pages_left" }, "page_progress")
        eq(Footer.plan{ current = "pages_left_book" }, "page_progress")
        eq(Footer.plan{ current = "page_progress" }, nil, "already showing it")
        eq(Footer.plan{ current = "time" }, nil, "a chosen view is left alone")
        eq(Footer.plan{ current = "pages_left", prev = "pages_left" }, nil, "already done once")
        eq(Footer.plan{ current = "pages_left", enabled = false }, nil, "setting off")
        eq(Footer.plan{ current = "pages_left", all_at_once = true }, nil, "all-at-once is custom")
    end)
    it("restores the old view only if ours is still showing", function()
        eq(Footer.restore("page_progress", "pages_left"), "pages_left")
        eq(Footer.restore("time", "pages_left"), nil, "changed since: keep it")
        eq(Footer.restore("page_progress", nil), nil, "we never switched it")
    end)
    it("reads KOReader's mode numbers and the live mode_index", function()
        eq(Footer.modeName(nil, 1), "page_progress")
        eq(Footer.modeName(nil, 4), "pages_left")
        eq(Footer.modeName({ mode = "time" }), "time")
        eq(Footer.modeName({ mode = 8, mode_index = { [8] = "chapter_time_to_read" } }),
            "chapter_time_to_read")
    end)
end)

describe("Reader status bar: tap cycle", function()
    it("lists the six views in the agreed order", function()
        local ids = {}
        for i, v in ipairs(Footer.VIEWS) do ids[i] = v.id end
        same(ids, {
            "page_progress",
            "chapter_time_to_read",
            "book_time_to_read",
            "percentage",
            "pages_left",
            "time",
        })
    end)
    it("treats a missing choice as every view on", function()
        local on = Footer.enabledSet(nil)
        eq(Footer.countOn(on), 6)
        eq(on.page_progress, true)
        eq(on.time, true)
        eq(Footer.enabledSet({ time = false }).time, false)
        eq(Footer.enabledSet({ time = false }).page_progress, true)
    end)
    it("refuses to turn off the last view still on", function()
        local only = Footer.enabledSet({
            page_progress = true,
            chapter_time_to_read = false,
            book_time_to_read = false,
            percentage = false,
            pages_left = false,
            time = false,
        })
        eq(Footer.canDisable(only, "page_progress"), false)
        eq(Footer.toggle(only, "page_progress"), nil)
        local two = Footer.toggle(Footer.enabledSet(nil), "time")
        eq(two.time, false)
        eq(Footer.countOn(two), 5)
        eq(Footer.canDisable(two, "time"), true)
    end)
    it("cycles in order, skipping views that are off, and wraps around", function()
        local all = Footer.enabledSet(nil)
        eq(Footer.next(all, "off"), "page_progress")
        eq(Footer.next(all, nil), "page_progress")
        eq(Footer.next(all, "page_progress"), "chapter_time_to_read")
        eq(Footer.next(all, "chapter_time_to_read"), "book_time_to_read")
        eq(Footer.next(all, "book_time_to_read"), "percentage")
        eq(Footer.next(all, "percentage"), "pages_left")
        eq(Footer.next(all, "pages_left"), "time")
        eq(Footer.next(all, "time"), "page_progress")
        local no_chapter = Footer.enabledSet({ chapter_time_to_read = false, book_time_to_read = false })
        eq(Footer.next(no_chapter, "page_progress"), "percentage")
        eq(Footer.next(all, "battery"), "page_progress", "unknown view starts the cycle")
    end)
    it("moves the on-screen view when that view is turned off", function()
        local after = Footer.toggle(Footer.enabledSet(nil), "pages_left")
        eq(Footer.currentAfterToggle(after, "page_progress", "pages_left"), "page_progress")
        eq(Footer.currentAfterToggle(after, "pages_left", "pages_left"), "page_progress")
        after.page_progress = false
        eq(Footer.currentAfterToggle(after, "page_progress", "page_progress"), "chapter_time_to_read")
    end)
    it("leaves KOReader's hide/show alone when every item is shown at once", function()
        eq(Footer.shouldCycle{ all_at_once = true }, false)
        eq(Footer.shouldCycle{ enabled = false }, false)
        eq(Footer.shouldCycle{}, true)
    end)
end)

describe("Reader status bar: long-press claim and labels", function()
    it("claims a hold only inside a visible footer", function()
        eq(Footer.shouldClaimHold{ footer_visible = true, has_dimen = true, inside = true }, true)
        eq(Footer.shouldClaimHold{ enabled = false, footer_visible = true, has_dimen = true, inside = true }, false)
        eq(Footer.shouldClaimHold{ footer_visible = false, has_dimen = true, inside = true }, false)
        eq(Footer.shouldClaimHold{ footer_visible = true, has_dimen = false, inside = true }, false)
        eq(Footer.shouldClaimHold{ footer_visible = true, has_dimen = true, inside = false }, false,
            "hold on the text above the bar is not ours")
    end)
    it("builds readable labels when the numbers are known", function()
        eq(Footer.viewLabel("page_progress", { page = 42, pages = 310 }), "42 / 310")
        eq(Footer.viewLabel("page_progress", {}), nil)
        eq(Footer.viewLabel("chapter_time_to_read", { chapter_min = 12 }), "12 min left in chapter")
        eq(Footer.viewLabel("book_time_to_read", { book_min = 65 }), "1 h 5 min left in book")
        eq(Footer.viewLabel("percentage", { percent = 0.135 }), "14% read")
        eq(Footer.viewLabel("percentage", { percent = 45 }), "45% read")
        eq(Footer.viewLabel("pages_left", { chapter_left = 12 }), "12 pages left in chapter")
        eq(Footer.viewLabel("pages_left", { chapter_left = 1 }), "1 page left in chapter")
        eq(Footer.viewLabel("time", { clock = "10:27" }), "10:27")
        eq(Footer.formatMinutes(12), "12 min")
        eq(Footer.formatMinutes(60), "1 h")
        eq(Footer.parseClockToMinutes("1:05"), 65)
    end)
end)

describe("Reader status bar: in the reader", function()
    it("switches pages left to 42 / 310 when a book opens, once", function()
        local Library = mainLib()
        local lib, footer, refreshed = reader(Library, { footer_page_total = true },
            { pages_left = true, page_progress = true }, Footer.MODE.pages_left)
        lib:onReaderReady()
        eq(footer.mode, Footer.MODE.page_progress)
        eq(lib.settings.footer_page_total_prev, "pages_left")
        eq(#refreshed > 0, true)
        local n = #refreshed
        lib:onReaderReady()
        eq(footer.mode, Footer.MODE.page_progress)
        eq(#refreshed, n, "second book: nothing more")
    end)
    it("does nothing when the view was already chosen, or when every item is shown at once", function()
        local Library = mainLib()
        local lib, footer = reader(Library, { footer_page_total = true },
            {}, Footer.MODE.time)
        lib:onReaderReady()
        eq(footer.mode, Footer.MODE.time)
        eq(lib.settings.footer_page_total_prev, nil)
        footer = reader(Library, { footer_page_total = true },
            { all_at_once = true }, Footer.MODE.pages_left)
        -- reader() returns lib, footer — redo clearly
        lib, footer = reader(Library, { footer_page_total = true },
            { all_at_once = true }, Footer.MODE.pages_left)
        lib:onReaderReady()
        eq(footer.mode, Footer.MODE.pages_left)
    end)
    it("menu toggle off puts the old view back; on switches again", function()
        local Library = mainLib()
        local lib, footer = reader(Library, { footer_page_total = true },
            { pages_left = true, page_progress = true }, Footer.MODE.pages_left)
        lib:onReaderReady()
        local item = lib:footerPageTotalMenuItem()
        eq(item.checked_func(), true)
        item.callback()
        eq(lib.settings.footer_page_total, false)
        eq(footer.mode, Footer.MODE.pages_left)
        eq(lib.settings.footer_page_total_prev, nil)
        eq(item.checked_func(), false)
        item.callback()
        eq(footer.mode, Footer.MODE.page_progress)
        eq(lib.settings.footer_page_total, true)
    end)
    it("a hold inside the footer opens the picker; a hold above it does not", function()
        local Library = mainLib()
        local lib, footer, _, events = reader(Library, { footer_page_total = true },
            {}, Footer.MODE.page_progress)
        local opened = 0
        lib.showFooterPicker = function() opened = opened + 1 end
        lib:onReaderReady()
        eq(footer:onHoldFooter({ pos = { x = 200, y = 1600 } }), true)
        eq(opened, 1)
        eq(#events, 0)
        eq(footer:onHoldFooter({ pos = { x = 200, y = 40 } }), "orig-hold")
        eq(opened, 1)
        eq(events[1], "orig-hold")
    end)
    it("does not steal a hold when the setting is off or the footer is hidden", function()
        local Library = mainLib()
        local lib, footer, _, events = reader(Library, { footer_page_total = false },
            {}, Footer.MODE.page_progress)
        local opened = 0
        lib.showFooterPicker = function() opened = opened + 1 end
        lib:onReaderReady()
        eq(footer:onHoldFooter({ pos = { x = 200, y = 1600 } }), "orig-hold")
        eq(opened, 0)
        lib.settings.footer_page_total = true
        lib.ui.view.footer_visible = false
        -- re-hook is skipped; the installed hook reads settings and visibility live
        eq(footer:onHoldFooter({ pos = { x = 200, y = 1600 } }), "orig-hold")
        eq(opened, 0)
    end)
    it("a tap walks the cycle; after Show nothing the next tap brings the bar back", function()
        local Library = mainLib()
        local lib, footer, _, events = reader(Library, { footer_page_total = true },
            { all_at_once = false }, Footer.MODE.page_progress)
        lib:onReaderReady()
        eq(footer:onToggleFooterMode(), true)
        eq(footer.mode, Footer.MODE.chapter_time_to_read)
        eq(footer:onToggleFooterMode(), true)
        eq(footer.mode, Footer.MODE.book_time_to_read)
        lib:setFooterMode(footer, "off")
        eq(footer.mode, Footer.MODE.off)
        eq(footer:onToggleFooterMode(), true)
        eq(footer.mode, Footer.MODE.page_progress)
        eq(#events, 0)
    end)
    it("skips views turned off in the cycle", function()
        local Library = mainLib()
        local lib, footer = reader(Library, {
            footer_page_total = true,
            footer_cycle = { chapter_time_to_read = false, book_time_to_read = false },
        }, {}, Footer.MODE.page_progress)
        lib:onReaderReady()
        footer:onToggleFooterMode()
        eq(footer.mode, Footer.MODE.percentage)
    end)
    it("leaves tapping to KOReader when the setting is off", function()
        local Library = mainLib()
        local lib, footer, _, events = reader(Library, { footer_page_total = false },
            {}, Footer.MODE.page_progress)
        lib:onReaderReady()
        eq(footer:onToggleFooterMode(), "orig-cycle")
        eq(events[1], "orig-cycle")
    end)
    it("the picker lists Skim, Go to page and Show nothing under the views", function()
        local Library = mainLib()
        local lib = reader(Library, { footer_page_total = true }, {}, Footer.MODE.page_progress)
        local dialog = lib:showFooterPicker()
        eq(dialog.title, "Status bar")
        -- 6 view rows + Skim + Go to page + Show nothing
        eq(#dialog.buttons, 9)
        eq(dialog.buttons[7][1].text, "Skim\u{2026}")
        eq(dialog.buttons[8][1].text, "Go to page\u{2026}")
        eq(dialog.buttons[9][1].text, "Show nothing")
        eq(#dialog.buttons[1], 2, "each view has a jump button and a checkbox")
    end)
end)
