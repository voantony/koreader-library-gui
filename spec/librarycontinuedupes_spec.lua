-- The Continue reading strip sits above the grid on page 1 only. Its books
-- stay out of the paged rows on every page: no book shows twice, none goes missing.
local Core = require("librarycore")

local function book(path, status, opened)
    return { path = path, title = path, status = status, last_opened = opened }
end

local function library()
    local books = {}
    for i = 1, 30 do
        local status = (i == 2 or i == 5 or i == 9) and "reading" or (i % 4 == 0 and "complete" or "new")
        books[i] = book("/b/" .. i .. ".epub", status, 100 - i)
    end
    return books
end

local function paths(list)
    local t = {}
    for i, b in ipairs(list) do t[i] = b.path end
    return t
end

describe("Grid under the Continue reading strip", function()
    it("leaves out the strip's books and keeps the order of the rest", function()
        local items = library()
        table.sort(items, Core.comparator("recent"))
        local strip = Core.continueReading(items, 5)
        same(paths(strip), { "/b/2.epub", "/b/5.epub", "/b/9.epub" })
        local grid = Core.withoutShown(items, strip)
        eq(#grid, #items - 3)
        same(paths(grid), { "/b/1.epub", "/b/3.epub", "/b/4.epub", "/b/6.epub", "/b/7.epub", "/b/8.epub",
            "/b/10.epub", "/b/11.epub", "/b/12.epub", "/b/13.epub", "/b/14.epub", "/b/15.epub", "/b/16.epub",
            "/b/17.epub", "/b/18.epub", "/b/19.epub", "/b/20.epub", "/b/21.epub", "/b/22.epub", "/b/23.epub",
            "/b/24.epub", "/b/25.epub", "/b/26.epub", "/b/27.epub", "/b/28.epub", "/b/29.epub", "/b/30.epub" })
        eq(#items, 30) -- the full list is untouched
    end)

    it("across all pages every book shows exactly once (strip + grid)", function()
        for _, sort in ipairs({ "recent", "title", "author", "added" }) do
            local items = library()
            table.sort(items, Core.comparator(sort))
            local strip = Core.continueReading(items, 5)
            local grid = Core.withoutShown(items, strip)
            local seen = {}
            for _, b in ipairs(strip) do seen[b.path] = (seen[b.path] or 0) + 1 end
            local _p, _n, pages = Core.page(grid, 8, 1)
            for p = 1, pages do
                for _, b in ipairs((Core.page(grid, 8, p))) do seen[b.path] = (seen[b.path] or 0) + 1 end
            end
            local n = 0
            for path, c in pairs(seen) do eq(c, 1, sort .. " " .. path); n = n + 1 end
            eq(n, 30, sort)
            eq(pages, math.ceil(27 / 8), sort)
        end
    end)


    it("page 1 holds fewer slots than later pages; every book still shows once", function()
        local items = library()
        table.sort(items, Core.comparator("recent"))
        local strip = Core.continueReading(items, 5)
        local grid = Core.withoutShown(items, strip)
        local first, later = 5, 10
        local seen = {}
        for _, b in ipairs(strip) do seen[b.path] = (seen[b.path] or 0) + 1 end
        local p1, page, pages = Core.page(grid, first, 1, later)
        eq(page, 1)
        eq(#p1, first)
        eq(pages, Core.pageCount(#grid, first, later))
        eq(pages, 1 + math.ceil((#grid - first) / later))
        for p = 1, pages do
            local slice = Core.page(grid, first, p, later)
            local expect = (p == 1) and first or math.min(later, #grid - first - (p - 2) * later)
            eq(#slice, expect, "page " .. p)
            for _, b in ipairs(slice) do seen[b.path] = (seen[b.path] or 0) + 1 end
        end
        local n = 0
        for path, c in pairs(seen) do eq(c, 1, path); n = n + 1 end
        eq(n, 30)
        for _, b in ipairs(strip) do
            for p = 1, pages do
                for _, row in ipairs((Core.page(grid, first, p, later))) do
                    eq(row.path ~= b.path, true, "strip book leaked onto page " .. p)
                end
            end
        end
    end)

    it("Recently opened strip: its books (finished ones too) leave the grid", function()
        local items = library()
        local strip = Core.recentlyOpened(items, 5)
        same(paths(strip), { "/b/1.epub", "/b/2.epub", "/b/3.epub", "/b/4.epub", "/b/5.epub" })
        eq(#Core.withoutShown(items, strip), 25)
    end)

    it("no strip, or an empty one, leaves the grid as it is", function()
        local items = library()
        eq(Core.withoutShown(items, nil), items)
        eq(Core.withoutShown(items, {}), items)
    end)
end)
