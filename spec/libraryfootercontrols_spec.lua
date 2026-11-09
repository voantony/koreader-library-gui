-- Issue #5: size and view controls beside the page navigation in the
-- footer. Tap steps the cover size (Small -> Medium -> Large, switching
-- to the grid) or the form factor (Grid -> List -> Compact -> Compact 2);
-- a long-press on either opens the sort and view picker.
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

local buttons, groups
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

local function loadFooterView()
    buttons, groups = {}, {}
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
        ["ui/geometry"] = { new = function(_, o) o.x = o.x or 0; o.y = o.y or 0; return o end },
        ["ui/gesturerange"] = { new = function() return {} end },
        ["ui/widget/container/leftcontainer"] = { new = function(_, o) return o end },
        ["ui/size"] = { margin = { default = 10 }, padding = { default = 8, small = 4, large = 16 },
            line = { thin = 1 } },
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/time"] = {
            now = function() return _G.__now_ms or 0 end,
            to_ms = function(t) return t end,
            to_s = function(t) return t end,
        },
        librarytile = {
            minTouch = function() return 48 end,
            bookCover = function(_, book, box_w, box_h, title, sub)
                return sized(box_w, box_h), box_w, box_h, false
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
    local saved, picked = {}, {}
    local cleared = 0
    local v = setmetatable({
        width = 1264,
        tab = opts.tab or "books",
        sort = "recent",
        query = opts.query or "",
        page = opts.page or 1,
        pages = opts.pages or 1,
        group = opts.group,
        last_book = opts.last_book,
        cols = opts.cols or 4,
        view_mode = opts.view_mode or "grid",
        cover_cache = { clear = function() cleared = cleared + 1 end },
        plugin = {
            settings = {},
            sortName = function() return "Last read" end,
            openBook = function() end,
            saveSettings = function() saved[#saved + 1] = true end,
            showSortPicker = function() picked[#picked + 1] = true end,
        },
    }, { __index = View })
    v.refreshBody = function(self) self.refreshed = (self.refreshed or 0) + 1 end
    v.keyboardGuard = function() end
    v.seriesPosition = function() return nil end
    return v, saved, picked, function() return cleared end
end

local function footer(opts)
    buttons, groups = {}, {}
    local View = loadFooterView()
    local v, saved, picked, cleared = footerView(View, opts)
    v:buildFooter(opts.page or 1, opts.pages or 1, opts.total or 40, opts.kind or "books")
    return v, saved, picked, cleared, groups[#groups]
end

local function findButton(icon)
    for _, b in ipairs(buttons) do
        if b.icon == icon then return b end
    end
    return nil
end

local function indexOf(t, value)
    for i, item in ipairs(t) do
        if item == value then return i end
    end
    return nil
end

describe("Footer size and view controls", function()
    it("shows a size and a view button beside the pager", function()
        local v, _s, _p, _c, row = footer({})
        local size = findButton("zoom.page")
        local view = findButton("column.three")
        eq(size ~= nil, true, "size button")
        eq(view ~= nil, true, "view button, grid form")
        eq(v.footer_size, size)
        eq(v.footer_view, view)
        -- after the sort text (and the cover, when there is one), before the pager
        local pager
        for _, g in ipairs(groups) do
            if g[1] and g[1].icon == "chevron.left" then pager = g end
        end
        eq(indexOf(row, size) > indexOf(row, v.sort_label), true)
        eq(indexOf(row, view), indexOf(row, size) + 2, "one gap between them")
        eq(indexOf(row, pager), indexOf(row, view) + 2, "one gap, then the pager")
    end)

    it("the view button icon follows the current form", function()
        local _v1 = footer({ view_mode = "list" })
        eq(findButton("column.one") ~= nil, true, "list form")
        local _v2 = footer({ view_mode = "compact2" })
        eq(findButton("column.two") ~= nil, true, "two-column compact form")
        local _v3 = footer({ view_mode = "compact" })
        eq(findButton("column.one") ~= nil, true, "compact form")
    end)

    it("tapping size steps Medium -> Large and saves the columns", function()
        local v, saved, _p, cleared = footer({ cols = 4, view_mode = "grid" })
        findButton("zoom.page").callback()
        eq(v.cols, 3, "Large covers")
        eq(v.plugin.settings.columns, 3)
        eq(#saved, 1, "columns saved like the picker does")
        eq(cleared(), 1, "cover cache cleared for the new size")
        eq(v.view_mode, "grid")
        eq(v.page, 1)
        eq(v.refreshed, 1, "one refresh for the size step")
    end)

    it("tapping size wraps Large -> Small and switches a list to the grid", function()
        local v = footer({ cols = 3, view_mode = "list" })
        findButton("zoom.page").callback()
        eq(v.cols, 5, "Small covers")
        eq(v.view_mode, "grid", "picking a size shows the grid, like the picker")
        findButton("zoom.page").callback()
        eq(v.cols, 4, "Medium covers")
    end)

    it("tapping view steps Grid -> List -> Compact -> Compact 2 -> Grid", function()
        local v = footer({ view_mode = "grid" })
        local view = findButton("column.three")
        view.callback()
        eq(v.view_mode, "list")
        -- the button is rebuilt with the new form's icon on refresh
        buttons, groups = {}, {}
        v:buildFooter(1, 1, 40, "books")
        eq(findButton("column.one") ~= nil, true, "list form icon after the step")
        findButton("column.one").callback()
        eq(v.view_mode, "compact")
        buttons, groups = {}, {}
        v:buildFooter(1, 1, 40, "books")
        findButton("column.one").callback()
        eq(v.view_mode, "compact2")
        buttons, groups = {}, {}
        v:buildFooter(1, 1, 40, "books")
        eq(findButton("column.two") ~= nil, true, "two-column icon after the step")
        findButton("column.two").callback()
        eq(v.view_mode, "grid")
    end)

    it("a long-press on either opens the sort and view picker", function()
        local v, _s, picked = footer({})
        findButton("zoom.page").hold_callback()
        eq(#picked, 1)
        findButton("column.three").hold_callback()
        eq(#picked, 2)
    end)

    it("both buttons show with no book being read", function()
        footer({ last_book = nil })
        eq(findButton("zoom.page") ~= nil, true)
        eq(findButton("column.three") ~= nil, true)
    end)

    it("the bottom-left menu opens on a tap and does not keep a hold", function()
        local v = footer({})
        local menu = findButton("appbar.menu")
        eq(menu, v.footer_menu)
        eq(menu.hold_callback, nil)
        local opened
        v.plugin.showLibraryMenu = function(_, view) opened = view end
        menu.callback()
        eq(opened, v)
    end)
end)
