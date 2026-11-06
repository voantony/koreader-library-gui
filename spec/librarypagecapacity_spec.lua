-- Page 1 of the Books tab leaves room for the Continue reading strip, so it
-- holds fewer book slots than later pages that use the full body. Core.page
-- (and pageCount / pageOfIndex) must keep next/prev, go-to-page, jump-to-last,
-- A–Z, the footer "x / N", and a remembered page correct when the two
-- capacities differ.
local Core = require("librarycore")

local function seq(n)
    local t = {}
    for i = 1, n do t[i] = i end
    return t
end

local function book(path, status, opened)
    return { path = path, title = path, status = status, last_opened = opened }
end

describe("Variable per-page capacity", function()
    describe("pageCount", function()
        it("is 1 when the list is empty or fits on page 1", function()
            eq(Core.pageCount(0, 5, 10), 1)
            eq(Core.pageCount(1, 5, 10), 1)
            eq(Core.pageCount(5, 5, 10), 1)
            eq(Core.pageCount(4, 5, 10), 1)
        end)

        it("counts a smaller page 1 and larger later pages", function()
            -- 197 grid books, 5 on page 1, 10 after: 1 + ceil(192/10) = 21
            eq(Core.pageCount(197, 5, 10), 21)
            eq(Core.pageCount(6, 5, 10), 2)
            eq(Core.pageCount(15, 5, 10), 2)   -- first + later, last page full
            eq(Core.pageCount(16, 5, 10), 3)   -- one leftover on page 3
            eq(Core.pageCount(25, 5, 10), 3)
        end)

        it("matches even paging when later equals first (or is omitted)", function()
            eq(Core.pageCount(25, 10), 3)
            eq(Core.pageCount(25, 10, 10), 3)
            eq(Core.pageCount(20, 10, 10), 2)
            eq(Core.pageCount(10, 10, 10), 1)
            eq(Core.pageCount(0, 10, 10), 1)
        end)
    end)

    describe("pageOfIndex", function()
        it("puts the first page's items on page 1 and later items on later pages", function()
            eq(Core.pageOfIndex(1, 5, 10), 1)
            eq(Core.pageOfIndex(5, 5, 10), 1)
            eq(Core.pageOfIndex(6, 5, 10), 2)
            eq(Core.pageOfIndex(15, 5, 10), 2)
            eq(Core.pageOfIndex(16, 5, 10), 3)
            eq(Core.pageOfIndex(25, 5, 10), 3)
            eq(Core.pageOfIndex(26, 5, 10), 4)
        end)

        it("matches floor((i-1)/per)+1 when pages are even", function()
            for i = 1, 25 do
                eq(Core.pageOfIndex(i, 10), math.floor((i - 1) / 10) + 1, "i=" .. i)
                eq(Core.pageOfIndex(i, 10, 10), math.floor((i - 1) / 10) + 1, "i=" .. i)
            end
        end)
    end)

    describe("Core.page slices", function()
        it("returns the first-page slice and a full later-page slice", function()
            local list = seq(27)
            local p1, page, pages = Core.page(list, 5, 1, 10)
            same(p1, { 1, 2, 3, 4, 5 })
            eq(page, 1)
            eq(pages, 4)
            same(Core.page(list, 5, 2, 10), { 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 })
            same(Core.page(list, 5, 3, 10), { 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 })
            same(Core.page(list, 5, 4, 10), { 26, 27 })
        end)

        it("fits fewer books than page 1 onto a single page", function()
            local items, page, pages = Core.page(seq(3), 5, 1, 10)
            same(items, { 1, 2, 3 })
            eq(page, 1)
            eq(pages, 1)
            local _, p2 = Core.page(seq(3), 5, 2, 10)
            eq(p2, 1)
        end)

        it("uses one page when the count lands exactly on page 1's capacity", function()
            local items, page, pages = Core.page(seq(5), 5, 1, 10)
            same(items, { 1, 2, 3, 4, 5 })
            eq(page, 1)
            eq(pages, 1)
        end)

        it("fills the last page exactly when n = first + k * later", function()
            local items, page, pages = Core.page(seq(15), 5, 2, 10)
            same(items, { 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 })
            eq(page, 2)
            eq(pages, 2)
            local last, lp, n = Core.page(seq(25), 5, 99, 10)
            same(last, { 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 })
            eq(lp, 3)
            eq(n, 3)
        end)

        it("leaves a short last page when n is just over a boundary", function()
            local items, page, pages = Core.page(seq(16), 5, 3, 10)
            same(items, { 16 })
            eq(page, 3)
            eq(pages, 3)
        end)

        it("treats an empty list as one empty page", function()
            local items, page, pages = Core.page({}, 5, 1, 10)
            eq(#items, 0)
            eq(page, 1)
            eq(pages, 1)
            local _, p2, n2 = Core.page({}, 5, 9, 10)
            eq(p2, 1)
            eq(n2, 1)
        end)

        it("keeps even paging when later_per_page is omitted", function()
            local list = seq(25)
            local items, page, pages = Core.page(list, 10, 3)
            same(items, { 21, 22, 23, 24, 25 })
            eq(page, 3)
            eq(pages, 3)
        end)
    end)

    describe("navigation, footer and a remembered page", function()
        local first, later = 5, 10
        local list = seq(197) -- like the 202-book demo after 5 continue books leave the rows

        it("clamps go-to-page and jump-to-last to the last page", function()
            local items, page, pages = Core.page(list, first, 99, later)
            eq(pages, 21)
            eq(page, 21)
            eq(#items, 197 - first - 19 * later) -- 197-5-190 = 2
            same(items, { 196, 197 })
            local _, last = Core.page(list, first, pages, later)
            eq(last, 21)
        end)

        it("next/prev land on neighbouring pages of the right size", function()
            local p1 = Core.page(list, first, 1, later)
            eq(#p1, 5)
            local p2, page2, pages = Core.page(list, first, 2, later)
            eq(page2, 2)
            eq(#p2, 10)
            local expect = {}
            for i = 6, 15 do expect[#expect + 1] = i end
            same(p2, expect)
            eq(pages, 21)
            local _, page20 = Core.page(list, first, 20, later)
            eq(page20, 20)
            local last, page21 = Core.page(list, first, 21, later)
            eq(page21, 21)
            eq(#last, 2)
        end)

        it("reports the footer total as the clamped page over pageCount", function()
            local _, page, pages = Core.page(list, first, 1, later)
            eq(page .. " / " .. pages, "1 / 21")
            _, page, pages = Core.page(list, first, 21, later)
            eq(page .. " / " .. pages, "21 / 21")
        end)

        it("clamps a remembered page that no longer exists", function()
            -- previously 40 even pages of 5; after the change there are 21
            local _, page, pages = Core.page(list, first, 40, later)
            eq(pages, 21)
            eq(page, 21)
        end)
    end)

    describe("filters and the Continue reading setting", function()
        it("a filter that hides the strip switches to uniform full-page capacity", function()
            local shown = Core.showContinue{
                enabled = true, tab = "books", group = nil, query = "", filter = "all", keyboard = false,
            }
            local hidden = Core.showContinue{
                enabled = true, tab = "books", group = nil, query = "", filter = "unread", keyboard = false,
            }
            eq(shown, true)
            eq(hidden, false)
            -- All + strip: 197 remaining books, page 1 has 5 slots, later 10
            eq(Core.pageCount(197, 5, 10), 21)
            -- Unread hides the strip and uses the full body (10 per page)
            local unread = seq(50)
            local items, page, pages = Core.page(unread, 10, 21)
            eq(pages, 5)
            eq(page, 5)
            eq(#items, 10)
            -- even fewer books than one full page
            local few, p1, n1 = Core.page(seq(3), 10, 5)
            eq(n1, 1)
            eq(p1, 1)
            eq(#few, 3)
        end)

        it("turning Continue reading off pages every book at full-page capacity", function()
            eq(Core.showContinue{
                enabled = false, tab = "books", group = nil, query = "", filter = "all", keyboard = false,
            }, false)
            -- 202 books, no exclusion, 10 per page
            local items, page, pages = Core.page(seq(202), 10, 1, 10)
            eq(pages, 21)
            eq(page, 1)
            eq(#items, 10)
            local last, lp = Core.page(seq(202), 10, 99, 10)
            eq(lp, 21)
            eq(#last, 2)
        end)

        it("turning Continue reading on leaves strip books out of every page", function()
            local items = {}
            for i = 1, 30 do
                local status = (i == 2 or i == 5 or i == 9) and "reading" or "new"
                items[i] = book("/b/" .. i .. ".epub", status, 100 - i)
            end
            table.sort(items, Core.comparator("recent"))
            local strip = Core.continueReading(items, 5)
            local grid = Core.withoutShown(items, strip)
            eq(#grid, 27)
            local seen = {}
            for _, b in ipairs(strip) do seen[b.path] = true end
            local first, later = 5, 10
            local _, _, pages = Core.page(grid, first, 1, later)
            for p = 1, pages do
                for _, b in ipairs((Core.page(grid, first, p, later))) do
                    eq(seen[b.path], nil, "strip book on page " .. p)
                    seen[b.path] = true
                end
            end
            local n = 0
            for _ in pairs(seen) do n = n + 1 end
            eq(n, 30)
        end)

        it("Compact and two-column Compact never reserve a Continue strip", function()
            eq(Core.isCompact("compact"), true)
            eq(Core.isCompact("compact2"), true)
            eq(Core.isCompact("list"), false)
            eq(Core.isCompact("grid"), false)
            -- No strip means first == later, so page count is ceil(n / per)
            eq(Core.pageCount(80, 40, 40), 2)
            eq(Core.pageCount(40, 40, 40), 1)
        end)
    end)
end)
