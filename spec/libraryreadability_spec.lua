-- Readability: one tap in the simple reader menu applies a preset to the
-- open book (darker, bolder, roomier text); tapping again puts back exactly
-- what the book had, saved per book.
local R = require("libraryreadability")

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

local refresh_rate, shown
local function mainLib()
    refresh_rate, shown = 12, {}
    local old_require = require
    local real = { librarycore = true, libraryindex = true, libraryreadermenu = true, libraryreadability = true,
        string = true, table = true, math = true }
    local extra = {
        ["ui/uimanager"] = {
            show = function(_, w) shown[#shown + 1] = w end,
            close = function() end, nextTick = function(_, f) f() end,
            getRefreshRate = function() return refresh_rate, refresh_rate end,
            setRefreshRate = function(_, r) refresh_rate = r end,
        },
        ["ui/widget/container/widgetcontainer"] = cls(),
        ["ui/widget/infomessage"] = { new = function(_, o) return o end },
        ["ui/event"] = { new = function(_, name, ...) return { name = name, args = { ... } } end },
        ["device"] = { hasFrontlight = function() return true end, isTouchDevice = function() return true end,
            screen = stub() },
    }
    _G.require = function(name)
        if extra[name] ~= nil then return extra[name] end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/main.lua")
    _G.require = old_require
    if not ok then error(mod, 0) end
    return mod
end

-- A reflowable book whose modules react to KOReader's events like the real ones.
local function fakeBook(log, opts)
    opts = opts or {}
    local c = {
        font_gamma = 15, font_base_weight = 0, line_spacing = 100,
        h_page_margins = { 10, 10 }, t_page_margin = 15, b_page_margin = 15, sync_t_b_page_margins = 0,
    }
    for k, v in pairs(opts.config or {}) do c[k] = v end
    local saved = {}
    local doc = { file = "/books/Emma.epub", configurable = c,
        setTextHyphenation = function(_, on) log[#log + 1] = "hyph " .. tostring(on) end }
    local ui = { document = doc, rolling = {}, font = {}, typeset = {}, typography = { hyphenation = opts.hyph or false },
        doc_settings = {
            readSetting = function(_, k) return saved[k] end,
            saveSetting = function(_, k, v) saved[k] = v end,
            delSetting = function(_, k) saved[k] = nil end,
        } }
    local handlers = {
        SetFontGamma = function(v) c.font_gamma = v end,
        SetFontBaseWeight = function(v) c.font_base_weight = v end,
        SetLineSpace = function(v) c.line_spacing = v end,
    }
    function ui:handleEvent(ev)
        local a = ev.args[1]
        local s = ev.name
        if type(a) == "table" then s = s .. " " .. table.concat(a, ",") elseif a ~= nil then s = s .. " " .. tostring(a) end
        log[#log + 1] = s
        if handlers[ev.name] then handlers[ev.name](a) end
    end
    return ui, saved
end

local function plugin(Library, ui)
    return setmetatable({ settings = { simple_reader_menu = true }, ui = ui }, { __index = Library })
end

describe("Readability: the preset", function()
    local base = { font_gamma = 15, font_base_weight = 0, line_spacing = 100, h_page_margins = { 10, 10 },
        t_page_margin = 15, b_page_margin = 15, sync_t_b_page_margins = 0, hyphenation = false, full_refresh_count = 12 }
    it("darker, +1 weight, 115 % lines, wider margins, hyphenation, refresh every 6 pages", function()
        same(R.target(base), { font_gamma = 30, font_base_weight = 1, line_spacing = 115, h_page_margins = { 15, 15 },
            t_page_margin = 15, b_page_margin = 15, sync_t_b_page_margins = 0, hyphenation = true, full_refresh_count = 6 })
    end)
    it("never makes a setting weaker than you had it", function()
        local t = R.target({ font_gamma = 43, font_base_weight = 1.5, line_spacing = 130, h_page_margins = { 30, 20 },
            t_page_margin = 50, b_page_margin = 20, hyphenation = true, full_refresh_count = 1 })
        same(t, { font_gamma = 43, font_base_weight = 1.5, line_spacing = 130, h_page_margins = { 30, 20 },
            t_page_margin = 50, b_page_margin = 20, hyphenation = true, full_refresh_count = 1 })
    end)
    it("turns 'never' full refresh into every 6 pages", function()
        eq(R.target({ full_refresh_count = 0 }).full_refresh_count, 6)
        eq(R.target({ full_refresh_count = 6 }).full_refresh_count, 6)
    end)
    it("leaves out settings the reader does not have", function()
        same(R.target({ line_spacing = 100 }), { line_spacing = 115 })
    end)
    it("turns top/bottom sync off only when the margins end up different", function()
        eq(R.target({ t_page_margin = 10, b_page_margin = 10, sync_t_b_page_margins = 1 }).sync_t_b_page_margins, 1)
        eq(R.target({ t_page_margin = 30, b_page_margin = 10, sync_t_b_page_margins = 1 }).sync_t_b_page_margins, 0)
    end)
    it("apply remembers only what it changes; nothing to do when already there", function()
        local ch, st = R.apply(base)
        same(ch, { font_gamma = 30, font_base_weight = 1, line_spacing = 115, h_page_margins = { 15, 15 },
            hyphenation = true, full_refresh_count = 6 })
        same(st.prev, { font_gamma = 15, font_base_weight = 0, line_spacing = 100, h_page_margins = { 10, 10 },
            hyphenation = false, full_refresh_count = 12 })
        eq(R.isOn(st), true)
        eq(R.apply(R.target(base)), nil)
        eq(R.isOn(nil), false)
        eq(R.isOn({ prev = {} }), false)
    end)
    it("undo puts back the old values, but keeps a setting you changed since", function()
        local _, st = R.apply(base)
        local now = R.target(base)
        same(R.restore(st, now), st.prev, "untouched: exactly the old values")
        now.line_spacing = 125
        local back = R.restore(st, now)
        eq(back.line_spacing, nil, "your own later change stays")
        eq(back.font_gamma, 15)
        eq(back.hyphenation, false, "false is put back too")
        same(R.restore(nil, now), {})
    end)
end)

describe("Readability: in the reader", function()
    it("is a button in the simple reader menu for reflowable books only", function()
        local Library = mainLib()
        local ui = fakeBook({})
        local ids = {}
        for _, a in ipairs(plugin(Library, ui):simpleMenuActions()) do ids[#ids + 1] = a.id end
        eq(table.concat(ids, ","), "library,goto,readability,light,details")
        ui.rolling = nil -- a PDF
        ids = {}
        for _, a in ipairs(plugin(Library, ui):simpleMenuActions()) do ids[#ids + 1] = a.id end
        eq(table.concat(ids, ","), "library,goto,light,details")
    end)
    it("one tap applies the preset with KOReader's events, batched into one re-layout", function()
        local Library = mainLib()
        local log = {}
        local ui, saved = fakeBook(log)
        local self = plugin(Library, ui)
        self:toggleReadability()
        eq(table.concat(log, ";"), "BatchedUpdate;SetFontGamma 30;SetFontBaseWeight 1;SetLineSpace 115;"
            .. "SetPageHorizMargins 15,15;SetPageTopAndBottomMargin 15,15;hyph true;UpdatePos;BatchedUpdateDone")
        local c = ui.document.configurable
        same(c.h_page_margins, { 15, 15 }, "saved with the book like the bottom menu does")
        eq(ui.typography.hyphenation, true)
        eq(refresh_rate, 6)
        assert(saved.library_readability, "remembered per book")
        eq(self:readabilityIsOn(), true)
        local a
        for _, x in ipairs(self:simpleMenuActions()) do if x.id == "readability" then a = x end end
        eq(a.on(), true, "button shows the Undo state")
        eq(a.label_on, "Undo")
    end)
    it("tapping again restores exactly the previous values", function()
        local Library = mainLib()
        local log = {}
        local ui, saved = fakeBook(log, { config = { line_spacing = 105, h_page_margins = { 5, 10 } }, hyph = false })
        local self = plugin(Library, ui)
        local before = self:readabilitySnapshot()
        self:toggleReadability()
        assert(not R.equal(self:readabilitySnapshot(), before), "changed")
        self:toggleReadability()
        same(self:readabilitySnapshot(), before)
        eq(saved.library_readability, nil, "nothing left to undo")
        eq(self:readabilityIsOn(), false)
        eq(refresh_rate, 12)
    end)
    it("a book that already reads that way changes nothing", function()
        local Library = mainLib()
        local log = {}
        local ui, saved = fakeBook(log, { config = { font_gamma = 36, font_base_weight = 1, line_spacing = 120,
            h_page_margins = { 20, 20 } }, hyph = true })
        local self = plugin(Library, ui)
        refresh_rate = 6
        self:toggleReadability()
        eq(#log, 0)
        eq(saved.library_readability, nil)
        eq(shown[#shown].text, "This book already reads that way.")
    end)
end)

describe("Readability: panel layout with nine buttons", function()
    it("nine buttons sit in two rows of five; landscape keeps one row", function()
        local RM = require("libraryreadermenu")
        same(RM.items({ toc = true, search = true, config = true, readability = true, light = true, bookmark = true }),
            { "library", "toc", "goto", "search", "font", "readability", "light", "bookmark", "details" })
        local L = RM.layout(1264, 1680, 9)
        eq(L.cols, 5); eq(L.rows, 2)
        assert(L.bottom < 1680 / 2, "still in the top half")
        eq(RM.layout(1680, 1264, 9).rows, 1)
    end)
end)
