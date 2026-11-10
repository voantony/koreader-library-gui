-- Issue #4: a current-book shortcut in the middle of the bottom nav: a
-- miniature of the book's cover; tapping it returns to the reader.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryzones = true, libraryindex = true, string = true, table = true, math = true }
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

local function sized(w, h)
    return { getSize = function() return { w = w, h = h } end, free = function() end }
end

local function widget(w, h)
    return { new = function(_, o)
        o = o or {}
        o.getSize = function() return { w = o.width or w, h = o.height or h } end
        o.free = function() end
        return o
    end }
end

local buttons, groups, hints
local function clsInit()
    local base = cls()
    function base:new(o)
        o = o or {}
        setmetatable(o, self)
        if o.init then o:init() end
        return o
    end
    return base
end

local cover_calls, cover_needs
local function loadFooterView()
    buttons, groups, hints = {}, {}, {}
    cover_calls, cover_needs = {}, false
    return load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = clsInit(),
        ["ui/widget/iconbutton"] = { new = function(_, o)
            o.image = {}
            o.getSize = function() return { w = 48, h = 48 } end
            buttons[#buttons + 1] = o
            return o
        end },
        ["ui/widget/textwidget"] = { new = function() return sized(80, 24) end },
        ["ui/widget/horizontalgroup"] = { new = function(_, o)
            o = o or {}
            o.getSize = function() return { w = 160, h = 48 } end
            o.free = function() end
            groups[#groups + 1] = o
            return o
        end },
        ["ui/widget/horizontalspan"] = widget(8, 8),
        ["ui/widget/container/framecontainer"] = widget(200, 48),
        ["ui/uimanager"] = {
            show = function(_, w) hints[#hints + 1] = w end,
            close = function() end,
            setDirty = function() end,
            unschedule = function() end,
            scheduleIn = function() end,
        },
        ["ui/widget/infomessage"] = { new = function(_, o) return o end },
        ["ui/geometry"] = { new = function(_, o) o.x = o.x or 0; o.y = o.y or 0; return o end },
        ["ui/gesturerange"] = { new = function() return {} end },
        ["ui/widget/container/leftcontainer"] = { new = function(_, o) return o end },
        ["ui/size"] = { margin = { default = 10 }, padding = { default = 8, small = 4, large = 16 } },
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/time"] = {
            now = function() return _G.__now_ms or 0 end,
            to_ms = function(t) return t end,
            to_s = function(t) return t end,
        },
        librarytile = {
            minTouch = function() return 48 end,
            bookCover = function(_, book, box_w, box_h, title, sub)
                cover_calls[#cover_calls + 1] = { book = book, w = box_w, h = box_h, title = title, sub = sub }
                return sized(box_w, box_h), box_w, box_h, cover_needs
            end,
        },
        device = { screen = {
            scaleBySize = function(_, n) return n end,
            scaleByDPI = function(_, n) return n end,
            getWidth = function() return 1264 end,
            getHeight = function() return 1680 end,
        }, hasKeys = function() return false end, isTouchDevice = function() return true end, hasDPad = function() return false end },
        util = { stringLower = function(s) return s:lower() end },
    })
end

local function footerView(View, opts)
    opts = opts or {}
    local opened = {}
    local v = setmetatable({
        width = 1264,
        tab = opts.tab or "books",
        sort = "recent",
        query = opts.query or "",
        page = opts.page or 1,
        pages = opts.pages or 1,
        group = opts.group,
        last_book = opts.last_book,
        missing_covers = {},
        plugin = {
            settings = {},
            sortName = function() return "Last read" end,
            openBook = function(_, path) opened[#opened + 1] = path end,
        },
    }, { __index = View })
    v.refreshBody = function(self) self.refreshed = (self.refreshed or 0) + 1 end
    v.keyboardGuard = function() end
    v.seriesPosition = function() return nil end
    return v, opened
end

local function footer(opts)
    buttons, groups = {}, {}
    local View = loadFooterView()
    cover_needs = opts.cover_needs or false
    local v, opened = footerView(View, opts)
    v:buildFooter(opts.page or 1, opts.pages or 1, opts.total or 40, opts.kind or "books")
    return v, opened, groups[#groups]
end

local function indexOf(t, value)
    for i, item in ipairs(t) do
        if item == value then return i end
    end
    return nil
end

describe("Current-book shortcut in the footer", function()
    local book = { path = "/books/Dune.epub", title = "Dune", percent = 0.42 }

    it("shows no shortcut when no book is being read", function()
        local v, _o, row = footer({ last_book = nil })
        eq(v.footer_current, nil)
        eq(#cover_calls, 0)
        eq(#row, 11, "menu, gap, text, spacer, empty slot, spacer, size, gap, view, gap, pager")
    end)

    it("shows the current book's cover in the middle, 2:3, touch-sized", function()
        local v, _o, row = footer({ last_book = book })
        eq(#cover_calls, 1)
        eq(cover_calls[1].book, book)
        eq(cover_calls[1].w, 32, "48 * 2/3")
        eq(cover_calls[1].h, 48)
        eq(cover_calls[1].title, "D", "initial placeholder when the cover is missing")
        local btn = v.footer_current
        eq(btn ~= nil, true)
        eq(btn:getSize().w, 48, "tap target is at least touch-sized")
        eq(btn:getSize().h, 48)
        eq(#row, 11, "menu, gap, text, spacer, cover, spacer, size, gap, view, gap, pager")
        local at = indexOf(row, btn)
        eq(at ~= nil, true)
        eq(at > indexOf(row, v.sort_label), true, "after the sort text")
        -- the pager group holds the page arrows
        local pager
        for _, g in ipairs(groups) do
            if g[1] and g[1].icon == "chevron.left" then pager = g end
        end
        eq(at < indexOf(row, pager), true, "before the pager")
    end)

    it("tapping the cover returns to the reader with that book", function()
        local v, opened = footer({ last_book = book })
        v.footer_current.callback()
        same(opened, { "/books/Dune.epub" })
    end)

    it("a long-press on the cover shows the title and progress", function()
        local v = footer({ last_book = book })
        local resume
        for _, b in ipairs(buttons) do
            if b.icon == "book.opened" then resume = b end
        end
        eq(resume, nil, "the Resume button is gone")
        v.footer_current.hold_callback()
        eq(hints[1].text, "Resume: Dune  ·  42 %")
    end)

    it("queues the cover for extraction when it is not ready yet", function()
        local v = footer({ last_book = book, cover_needs = true })
        eq(#v.missing_covers, 1)
        eq(v.missing_covers[1], book)
        -- rebuilding the footer does not queue it twice
        buttons, groups = {}, {}
        v:buildFooter(1, 1, 40, "books")
        eq(#v.missing_covers, 1)
    end)

    it("does not queue the cover when it is already available", function()
        local v = footer({ last_book = book })
        eq(#v.missing_covers, 0)
    end)
end)
