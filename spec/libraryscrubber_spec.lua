-- A–Z strip: which page a letter opens, when the strip is hidden, how big the
-- hit targets are, and which rectangles a drag refreshes.
local Core = require("librarycore")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = {
        librarycore = true, libraryindex = true, libraryscrubber = true,
        string = true, table = true, math = true,
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
    package.loaded[file:gsub("%.lua$", "")] = nil
    local ok, mod = pcall(dofile, "library.koplugin/" .. file)
    _G.require = old_require
    if not ok then error(mod, 0) end
    return mod
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o)
        o = o or {}
        setmetatable(o, self)
        if o.init then o:init() end
        return o
    end
    return base
end

describe("Scrubber letter to page", function()
    local function titles(list, per_page)
        return Core.scrubberIndex(list, per_page, function(b) return b.title end)
    end

    it("sends each letter to the first page that has it, and leaves empty letters inactive", function()
        local books = {
            { title = "1984" },
            { title = "Animal Farm" },
            { title = "Emma" },
            { title = "Pride and Prejudice" },
        }
        local idx = titles(books, 2)
        eq(idx.page["#"], 1)
        eq(idx.page.A, 1)
        eq(idx.page.E, 2)
        eq(idx.page.P, 2)
        eq(idx.active.A, true)
        eq(idx.active.E, true)
        eq(idx.active.B, false)
        eq(idx.active.Q, false)
        eq(Core.scrubberTargetPage(idx, "E"), 2)
        eq(Core.scrubberTargetPage(idx, "B"), nil)
        eq(Core.scrubberTargetPage(idx, "#"), 1)
        -- a later book with the same letter does not move the first page
        local again = titles({
            { title = "Emma" }, { title = "East of Eden" }, { title = "Pride and Prejudice" },
        }, 1)
        eq(again.page.E, 1)
        eq(again.page.P, 3)
    end)

    it("folds accents and treats digits and symbols as #", function()
        eq(Core.scrubberBucket("Émile"), "E")
        eq(Core.scrubberBucket("émile"), "E")
        eq(Core.scrubberBucket("Brontë"), "B")
        eq(Core.scrubberBucket("  Animal Farm"), "A")
        eq(Core.scrubberBucket("1984"), "#")
        eq(Core.scrubberBucket("#1"), "#")
        eq(Core.scrubberBucket(""), "#")
        eq(Core.scrubberBucket(nil), "#")
        eq(Core.scrubberBucket(Core.UNKNOWN), "#")
        local books = {
            { authors = { "Austen" }, title = "Emma" },
            { authors = { "Émile Zola" }, title = "Nana" },
            { authors = {}, title = "Untitled" },
        }
        local idx = Core.scrubberIndex(books, 1, function(b) return Core.scrubberItemKey(b, "author") end)
        eq(Core.scrubberItemKey(books[2], "author"), "Émile Zola")
        eq(idx.page.A, 1)
        eq(idx.page.E, 2)
        eq(idx.page["#"], 3)
        eq(Core.scrubberBucket(Core.scrubberItemKey({ series = "Oz" }, "series")), "O")
        eq(Core.scrubberBucket(Core.scrubberItemKey({ name = "Poetry" }, "name")), "P")
    end)

    it("maps a finger to equal slots, # at the top and Z at the bottom", function()
        local letters = Core.SCRUBBER_LETTERS
        eq(#letters, 27)
        eq(letters[1], "#")
        eq(letters[27], "Z")
        local y, h = 100, 2700 -- 100 px each
        eq(Core.scrubberLetterAt(y, y, h), "#")
        eq(Core.scrubberLetterAt(y + 100, y, h), "A")
        eq(Core.scrubberLetterAt(y + 150, y, h), "A")
        eq(Core.scrubberLetterAt(y + 199, y, h), "A")
        eq(Core.scrubberLetterAt(y + 200, y, h), "B")
        eq(Core.scrubberLetterAt(y + h - 1, y, h), "Z")
        eq(Core.scrubberLetterAt(y - 1, y, h), nil)
        eq(Core.scrubberLetterAt(y + h, y, h), nil)
        -- the slot is the full strip width; the width itself is the grab target
        eq(Core.scrubberWidth(300) >= 120, true)
    end)
end)

describe("Scrubber hidden when the list is not alphabetical", function()
    it("shows for title, author and series, and hides for date, last read and size", function()
        eq(Core.scrubberMode({ kind = "books", sort = "title" }), "title")
        eq(Core.scrubberMode({ kind = "books", sort = "author" }), "author")
        eq(Core.scrubberMode({ kind = "books", sort = "series" }), "series")
        eq(Core.scrubberMode({ kind = "books", sort = "recent" }), nil)
        eq(Core.scrubberMode({ kind = "books", sort = "added" }), nil)
        eq(Core.scrubberMode({ kind = "books", sort = "size" }), nil)
        eq(Core.scrubberMode({ kind = "books", sort = "title", in_series = true }), nil)
        eq(Core.scrubberMode({ kind = "books", sort = "title", enabled = false }), nil)
    end)

    it("uses shelf names for authors, series, collections and genres", function()
        eq(Core.scrubberMode({ kind = "groups", sort = "recent", tab = "authors" }), "name")
        eq(Core.scrubberMode({ kind = "groups", sort = "added", tab = "series" }), "name")
        eq(Core.scrubberMode({ kind = "groups", sort = "title", tab = "collections" }), "name")
        eq(Core.scrubberMode({ kind = "groups", sort = "title", tab = "genres" }), "name")
        eq(Core.scrubberMode({ kind = "groups", sort = "title", tab = "books" }), nil)
    end)

    it("is on unless the setting turns it off, and the grid gives the strip its width", function()
        eq(Core.showScrubber(nil), true)
        eq(Core.showScrubber({}), true)
        eq(Core.showScrubber({ show_scrubber = false }), false)
        local strip = Core.scrubberWidth(300)
        eq(strip >= 120, true)
        eq(Core.gridContentWidth(1264, strip), 1264 - strip)
        eq(Core.gridContentWidth(1264, 0), 1264)
        -- a huge strip cannot eat the covers
        eq(Core.gridContentWidth(1264, 5000) >= 632, true)
    end)
end)

describe("Page control hit areas", function()
    it("is at least 10 mm and 120 px wide at 300 dpi", function()
        local px = Core.pageHitPx(300)
        eq(px >= 120, true)
        eq(px >= math.floor(10 * 300 / 25.4 + 0.5), true)
        -- a lower density keeps the same physical 10 mm, not a fixed 120 px
        local small = Core.pageHitPx(167)
        eq(small >= math.floor(10 * 167 / 25.4 + 0.5), true)
        eq(small < 120, true)
    end)

    local function sized(w, h)
        return { getSize = function() return { w = w, h = h } end, free = function() end }
    end

    it("grows the page arrows and the page number sideways, and leaves the menu button", function()
        local buttons = {}
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/widget/iconbutton"] = { new = function(_, o)
                o.image = {}
                o.getSize = function()
                    local pad_l = o.padding_left or o.padding or 0
                    local pad_r = o.padding_right or o.padding or 0
                    local pad_t = o.padding_top or o.padding or 0
                    local pad_b = o.padding_bottom or o.padding or 0
                    return { w = (o.width or 0) + pad_l + pad_r, h = (o.height or 0) + pad_t + pad_b }
                end
                buttons[#buttons + 1] = o
                return o
            end },
            ["ui/widget/textwidget"] = { new = function() return sized(80, 24) end },
            ["ui/widget/horizontalgroup"] = { new = function(_, o)
                o = o or {}
                o.getSize = function()
                    local w, h = 0, 0
                    for _, child in ipairs(o) do
                        if child.getSize then
                            local s = child:getSize()
                            w = w + (s.w or 0)
                            if (s.h or 0) > h then h = s.h end
                        end
                    end
                    return { w = w, h = h }
                end
                o.free = function() end
                return o
            end },
            ["ui/widget/horizontalspan"] = { new = function(_, o)
                o = o or {}
                o.getSize = function() return { w = o.width or 8, h = 8 } end
                o.free = function() end
                return o
            end },
            ["ui/widget/container/framecontainer"] = { new = function(_, o)
                o = o or {}
                o.getSize = function() return { w = o.width or 0, h = o.height or 0 } end
                o.free = function() end
                return o
            end },
            ["ui/widget/container/centercontainer"] = { new = function(_, o) return o end },
            ["ui/widget/container/leftcontainer"] = { new = function(_, o) return o end },
            ["ui/geometry"] = { new = function(_, o) o.x = o.x or 0; o.y = o.y or 0; return o end },
            ["ui/gesturerange"] = { new = function() return {} end },
            ["ui/size"] = { margin = { default = 10 }, padding = { default = 8, small = 4, large = 16 } },
            ["ui/font"] = { getFace = function() return {} end },
            librarytile = { minTouch = function() return 76 end },
            device = { screen = {
                scaleBySize = function(_, n) return n end,
                getWidth = function() return 1264 end,
                getHeight = function() return 1680 end,
                getDPI = function() return 300 end,
            }, hasKeys = function() return false end, isTouchDevice = function() return true end,
                hasDPad = function() return false end },
            util = { stringLower = function(s) return s:lower() end },
        })
        local v = setmetatable({
            width = 1264,
            tab = "books",
            sort = "title",
            query = "",
            page = 3,
            pages = 12,
            last_book = nil,
            plugin = { settings = {}, sortName = function() return "Title" end },
        }, { __index = View })
        v:buildFooter(3, 12, 40, "books")
        local prev, nxt, menu
        for _, b in ipairs(buttons) do
            if b.icon == "chevron.left" then prev = b
            elseif b.icon == "chevron.right" then nxt = b
            elseif b.icon == "appbar.menu" then menu = b end
        end
        local function hit_w(b)
            return b.width + (b.padding_left or 0) + (b.padding_right or 0)
        end
        eq(hit_w(prev) >= 120, true)
        eq(hit_w(nxt) >= 120, true)
        -- the chevron itself stays the icon, not a filled slab
        eq(prev.width, 20)
        eq(nxt.width, 20)
        eq(v.page_label.dimen.w >= 120, true)
        eq(v.page_label.dimen.h >= 76, true)
        eq(v.page_label.align, "center")
        -- menu and resume keep the smaller thumb target, so the footer does not grow a heavy bar
        eq(hit_w(menu) < hit_w(prev), true)
        eq(hit_w(menu) < 120, true)
        local function hit_h(b)
            local top = b.padding_top or b.padding or 0
            local bottom = b.padding_bottom or b.padding or 0
            return b.height + top + bottom
        end
        -- same row height as the menu: the page buttons grow wider, not taller
        eq(hit_h(prev), hit_h(menu))
    end)
end)

describe("Scrubber refresh regions", function()
    local strip = { x = 1144, y = 220, w = 120, h = 1100 }
    local bubble = { x = 500, y = 700, w = 220, h = 220 }
    local screen = 1264 * 1680

    local function smaller(regions)
        eq(#regions > 0, true)
        for _, r in ipairs(regions) do
            eq(r.w * r.h < screen, true, "region covers the whole screen")
            eq(r.x >= 0 and r.y >= 0, true)
        end
    end

    it("refreshes only the strip and the bubble, with a fast update, while dragging", function()
        local plan = Core.scrubberDragRefresh(strip, bubble, nil)
        eq(plan.mode, "fast")
        eq(#plan.regions, 2)
        same(plan.regions[1], strip)
        same(plan.regions[2], bubble)
        smaller(plan.regions)
        -- the bubble does not move, so the next letter refreshes the same two rects once each
        local again = Core.scrubberDragRefresh(strip, bubble, bubble)
        eq(#again.regions, 2)
        eq(again.mode, "fast")
    end)

    it("on release repaints the results once when the page changes, otherwise just the bubble", function()
        local body = { x = 0, y = 180, w = 1264, h = 1400 }
        local changed = Core.scrubberReleaseRefresh(true, body, strip, bubble)
        eq(changed.mode, "ui")
        eq(changed.mode ~= "full", true)
        same(changed.regions, { body })
        local stay = Core.scrubberReleaseRefresh(false, body, strip, bubble)
        eq(stay.mode, "ui")
        smaller(stay.regions)
        eq(#stay.regions, 2)
        same(stay.regions[1], strip)
        same(stay.regions[2], bubble)
    end)

    it("a drag on the widget refreshes those rects only, and jumps once on release", function()
        local log, timers = {}, {}
        local UIManager = {
            setDirty = function(_, _, f)
                local mode, rect = f()
                log[#log + 1] = { mode = mode, rect = rect }
            end,
            scheduleIn = function(_, d, f) timers[f] = d end,
            unschedule = function(_, f) timers[f] = nil end,
        }
        local Scrubber = load("libraryscrubber.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/uimanager"] = UIManager,
            ["ui/geometry"] = { new = function(_, o) return o end },
            ["ui/gesturerange"] = { new = function() return {} end },
            ["ffi/blitbuffer"] = {},
            device = { screen = {
                getWidth = function() return 1264 end,
                getHeight = function() return 1680 end,
                getDPI = function() return 300 end,
                scaleBySize = function(_, n) return n end,
            } },
        })
        local books = {}
        for i, letter in ipairs(Core.SCRUBBER_LETTERS) do
            local title = letter == "#" and "1984" or (letter .. " book")
            books[i] = { title = title }
        end
        local index = Core.scrubberIndex(books, 1, function(b) return b.title end)
        local went = {}
        local view = { page = 1, goToPage = function(_, n) went[#went + 1] = n end }
        local s = Scrubber:new{
            view = view,
            index = index,
            width = 120,
            height = 2700,
            dpi = 300,
            screen_w = 1264,
            screen_h = 1680,
        }
        s.dimen.x, s.dimen.y = 1144, 100
        -- E is index 6 ("#" is 1). Slot height 100.
        local function at(i)
            return { x = 1144 + 40, y = 100 + (i - 1) * 100 + 10 }
        end
        s:onPanScrubber(nil, { pos = at(6) })
        eq(s.bubble_letter, "E")
        eq(#log, 2, "strip and bubble, nothing else")
        for _, e in ipairs(log) do
            eq(e.mode, "fast")
            eq(e.rect.w * e.rect.h < screen, true)
        end
        same(log[1].rect, s:stripRect())
        same(log[2].rect, s.bubble)
        -- more movement before the tick: no further refresh yet
        s:onPanScrubber(nil, { pos = at(13) }) -- L
        s:onPanScrubber(nil, { pos = at(16) }) -- O
        eq(#log, 2)
        eq(s.bubble_letter, "E")
        local tick = s._tick
        timers[tick] = nil
        tick()
        eq(s.bubble_letter, "O")
        eq(#log, 4)
        eq(log[3].mode, "fast")
        eq(log[4].mode, "fast")
        s:onPanReleaseScrubber()
        same(went, { index.page.O })
        eq(view.page, 1, "goToPage is the view's; the scrubber does not assign the page itself")
        for _, e in ipairs(log) do
            eq(e.mode ~= "full", true)
            eq(e.rect.w * e.rect.h < screen, true)
        end
        local n = 0
        for _ in pairs(timers) do n = n + 1 end
        eq(n, 0, "no drag timer left running")
    end)

    it("an inactive letter does not turn the page, and a swipe on the strip does not either", function()
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/geometry"] = { new = function(_, o) return o end },
            ["ui/gesturerange"] = { new = function() return {} end },
            device = { screen = {
                scaleBySize = function(_, n) return n end,
                getDPI = function() return 300 end,
                getWidth = function() return 1264 end,
                getHeight = function() return 1680 end,
            }, hasKeys = function() return false end, isTouchDevice = function() return true end,
                hasDPad = function() return false end },
            util = { stringLower = function(s) return s:lower() end },
        })
        local jumped = {}
        local v = setmetatable({
            width = 1264, sort = "recent", tab = "books", page = 2, pages = 8,
            show_scrubber = true,
            plugin = { settings = { show_scrubber = true } },
        }, { __index = View })
        eq(v:scrubberPlan("books", 40), nil)
        v.sort = "title"
        local plan = v:scrubberPlan("books", 40)
        eq(plan.mode, "title")
        eq(plan.width >= 120, true)
        eq(plan.content_w, 1264 - plan.width)
        v.sort = "added"
        eq(v:scrubberPlan("books", 40), nil)
        v.show_scrubber = false
        v.sort = "title"
        eq(v:scrubberPlan("books", 40), nil)
        v.show_scrubber = true
        local ended = 0
        v.page = 2
        v.scrubber = {
            _drag = true,
            dimen = { x = 1144, y = 200, w = 120, h = 800 },
            endDrag = function() ended = ended + 1 end,
            onSwipeScrubber = function() jumped[#jumped + 1] = "swipe" end,
        }
        v.turnPage = function() error("a drag on the strip must not turn the page") end
        v:onSwipe(nil, { direction = "west", pos = { x = 100, y = 400 }, end_pos = { x = 40, y = 400 } })
        eq(ended, 1)
        eq(v.page, 2)
        v.scrubber._drag = nil
        v:onSwipe(nil, { direction = "west", pos = { x = 1180, y = 500 } })
        same(jumped, { "swipe" })
        eq(v.page, 2)
    end)
end)
