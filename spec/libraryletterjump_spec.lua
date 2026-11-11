-- Issue #7: a jump on the A–Z strip shows the letter's first matching book
-- at the top of the grid, instead of wherever the page boundary falls.
-- The page is anchored at that book; any other page turn, or a change to
-- the list, drops back to fixed pages.
--
-- LibraryView needs KOReader's UI modules, so they are stubbed here; only
-- the class table is under test.

local Core = require("librarycore")

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

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryzones = true, libraryindex = true, string = true, table = true, math = true, io = true, os = true }
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

describe("letter jump (issue #7)", function()
    local function books()
        local out = {}
        for _, letter in ipairs({ "A", "B", "C", "D", "E", "F" }) do
            for i = 1, 5 do out[#out + 1] = { title = letter .. " book " .. i } end
        end
        return out
    end

    local refreshed
    local function harness()
        refreshed = 0
        local View = load("libraryview.lua", {
            ["ui/uimanager"] = { scheduleIn = function() end, unschedule = function() end, setDirty = function() end },
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/widget/inputtext"] = cls(),
            ["ui/time"] = { now = function() return 0 end, to_ms = function() return 0 end, to_s = function() return "0" end },
        })
        local grid = books()
        local v = setmetatable({
            tab = "books",
            sort = "title",
            filter = nil,
            query = "",
            show_continue = false,
            group = nil,
            page = 1,
            pages = 4,
            scrubber = { index = Core.scrubberIndex(grid, 9, nil, 9) },
        }, { __index = View })
        v.timeStart = function() end
        v.refreshBody = function() refreshed = refreshed + 1 end
        return v, grid
    end

    it("shows the letter's first book at the top, not mid-page", function()
        local v, grid = harness()
        -- full height: 9 a page. D starts at index 16, so the fixed page 2
        -- (books 10-18) shows it seventh, in the bottom row.
        local fixed = Core.page(grid, 9, 2, 9)
        eq(fixed[1].title, "B book 5")
        eq(fixed[7].title, "D book 1")
        eq(v:jumpToLetter("D"), true)
        eq(v.page, 2)
        eq(v._jump_anchor.index, 16)
        eq(v._jump_anchor.letter, "D")
        local shown = v:anchoredPageItems(grid, fixed, 2, 9, 9, "title")
        eq(#shown, 9)
        eq(shown[1].title, "D book 1")
        eq(shown[5].title, "D book 5")
        eq(shown[9].title, "E book 4")
    end)

    it("a plain page turn clears the anchor", function()
        local v = harness()
        v:jumpToLetter("D")
        eq(v._jump_anchor ~= nil, true)
        v:goToPage(3)
        eq(v.page, 3)
        eq(v._jump_anchor, nil)
    end)

    it("repeating the same jump is a no-op", function()
        local v = harness()
        eq(v:jumpToLetter("D"), true)
        local after_first = refreshed
        eq(v:jumpToLetter("D"), false)
        eq(refreshed, after_first)
    end)

    it("a letter tap collapses the shelf unless asked not to, and swipe up still works", function()
        local v = harness()
        v._shelf_expanded = true
        v._strip_possible = true
        v.body_y = 80
        v.letter_keeps_shelf = false
        eq(v:jumpToLetter("D"), true)
        eq(v.page, 2)
        eq(v._shelf_expanded, nil, "the default still collapses the shelf")
        eq(v._jump_anchor ~= nil, true)
        local up = { pos = { x = 40, y = 500 }, end_pos = { x = 40, y = 200 } }
        eq(v:toggleShelfExpand(true, up), true, "swipe up still expands after the jump")
        eq(v._shelf_expanded, true)
    end)

    it("Letter tap keeps shelf expanded leaves the shelf open", function()
        local v = harness()
        v._shelf_expanded = true
        v._strip_possible = true
        v.body_y = 80
        v.letter_keeps_shelf = true
        eq(v:jumpToLetter("D"), true)
        eq(v._shelf_expanded, true)
    end)

    it("an inactive letter jumps nowhere", function()
        local v = harness()
        eq(v:jumpToLetter("Q"), false)
        eq(v.page, 1)
        eq(v._jump_anchor, nil)
    end)

    it("the anchor drops when the list changes", function()
        local v, grid = harness()
        v:jumpToLetter("D")
        local fixed = Core.page(grid, 9, 2, 9)
        v.query = "x"
        local shown = v:anchoredPageItems(grid, fixed, 2, 9, 9, "title")
        eq(shown, fixed)
        eq(v._jump_anchor, nil)
    end)

    it("paging continues from the anchor without repeating or skipping books", function()
        local v, grid = harness()
        v:jumpToLetter("D")
        local fixed = Core.page(grid, 9, 2, 9)
        local shown = v:anchoredPageItems(grid, fixed, v.page, 9, 9, "title")
        eq(shown[1].title, "D book 1")
        eq(shown[9].title, "E book 4")
        eq(v.page, 2)
        eq(v.page >= 1 and v.page <= v.pages, true)

        v:turnPage(1)
        local nxt = v:anchoredPageItems(grid, fixed, v.page, 9, 9, "title")
        eq(nxt[1].title, "E book 5", "the next window starts on the following book")
        eq(nxt[#nxt].title, "F book 5", "and runs through the end of the list")
        eq(v.page, v.pages, "a window that reaches the last book is the last page")
        local seen = {}
        for _, b in ipairs(shown) do seen[b.title] = true end
        for _, b in ipairs(nxt) do
            eq(seen[b.title], nil, "no title from the jump window is repeated")
        end

        v:turnPage(-1)
        local back = v:anchoredPageItems(grid, fixed, v.page, 9, 9, "title")
        eq(back[1].title, "D book 1")
        eq(back[9].title, "E book 4")
        eq(v.page, 2)

        v:turnPage(-1)
        local prev = v:anchoredPageItems(grid, fixed, v.page, 9, 9, "title")
        eq(#prev, 9)
        eq(prev[1].title, "B book 2")
        eq(prev[9].title, "C book 5", "the previous window ends on the book before the jump")
        eq(v.page, 1)
        eq(v.page >= 1 and v.page <= v.pages, true)
        for _, b in ipairs(prev) do
            eq(seen[b.title], nil, "no title from the jump window is skipped into the previous page")
        end
    end)

    it("a forward step that is not the end of the list advances the page number", function()
        local v, grid = harness()
        v.scrubber = { index = Core.scrubberIndex(grid, 5, nil, 5) }
        v.pages = Core.pageCount(#grid, 5, 5)
        v:jumpToLetter("D")
        v:anchoredPageItems(grid, {}, v.page, 5, 5, "title")
        local before = v.page
        eq(before, Core.pageOfIndex(16, 5, 5))
        v:turnPage(1)
        local nxt = v:anchoredPageItems(grid, {}, v.page, 5, 5, "title")
        eq(nxt[1].title, "E book 1")
        eq(#nxt, 5)
        eq(v.page, before + 1)
        eq(v.page < v.pages, true)
    end)

    it("the anchor drops when the book at the anchor no longer matches", function()
        local v, grid = harness()
        v:jumpToLetter("D")
        local shifted = {}
        for i, b in ipairs(grid) do shifted[i] = b end
        shifted[16] = { title = "C book 6" }
        local fixed = Core.page(shifted, 9, 2, 9)
        local shown = v:anchoredPageItems(shifted, fixed, 2, 9, 9, "title")
        eq(shown, fixed)
        eq(v._jump_anchor, nil)
    end)
end)
