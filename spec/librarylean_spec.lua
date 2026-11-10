-- Read / New badges, time left from stored reading stats, the Want to Read
-- collection, Cover only (remembered per place), and the read-only fact lines.
local Core = require("librarycore")
local Index = require("libraryindex")

local function fact(book, id, now)
    for _, f in ipairs(Core.bookFacts(book, now)) do
        if f.id == id then return f.value end
    end
end

describe("Read and New badges", function()
    it("marks a book New only when it has never been opened", function()
        eq(Core.tileBadge({ status = "new", opened = false }), "new")
        eq(Core.tileBadge({ status = "new" }), "new")
        eq(Core.tileBadge({ title = "No sidecar" }), "new")
    end)
    it("does not mark New a book that was opened and left at the start", function()
        eq(Core.tileBadge({ status = "new", opened = true, last_opened = 10 }), nil)
        eq(Core.tileBadge({ status = "new", opened = false, last_opened = 10 }), nil)
        eq(Core.tileBadge({ status = "new", last_opened = 10, percent = 0.01 }), nil)
        eq(Core.tileBadge({ status = "new", percent = 0 }), nil)
    end)
    it("marks Read from KOReader's doc status, including when that says finished", function()
        eq(Core.tileBadge({ status = "complete", opened = true }), "read")
        eq(Core.tileBadge({ status = "reading", doc_status = "complete" }), "read")
        eq(Core.tileBadge({ doc_status = "complete", opened = false }), "read")
    end)
    it("leaves an in-progress book without a Read or New badge", function()
        eq(Core.tileBadge({ status = "reading", opened = true, percent = 0.4 }), nil)
        eq(Core.tileBadge({ status = "abandoned", opened = true }), "hold")
    end)
end)

describe("time left from reading stats", function()
    local reading = { status = "reading", percent = 0.4, pages = 100 }
    it("estimates from this book's own seconds per page", function()
        eq(Core.estimateTimeLeft(reading, { avg_time = 90 }), 60 * 90)
        eq(Core.readingSpeed({ total_read_time = 3000, total_read_pages = 30 }), 100)
        eq(Core.estimateTimeLeft(reading, { total_read_time = 3000, total_read_pages = 30 }), 6000)
    end)
    it("uses a page count KOReader stored on the stats when the book has none", function()
        local book = { status = "reading", percent = 0.5 }
        eq(Core.estimateTimeLeft(book, { avg_time = 60, pages = 10 }), 300)
    end)
    it("hides the estimate when there is no measurement, and never invents a pace", function()
        eq(Core.estimateTimeLeft(reading, nil), nil)
        eq(Core.estimateTimeLeft(reading, {}), nil)
        eq(Core.estimateTimeLeft(reading, { avg_time = 0 }), nil)
        eq(Core.estimateTimeLeft(reading, { total_read_time = 0, total_read_pages = 10 }), nil)
        eq(Core.estimateTimeLeft({ status = "reading", percent = 0.4 }, { avg_time = 90 }), nil)
        eq(Core.estimateTimeLeft({ status = "new", percent = 0, pages = 100 }, { avg_time = 90 }), nil)
        eq(Core.estimateTimeLeft({ status = "complete", percent = 1, pages = 100 }, { avg_time = 90 }), nil)
        eq(Core.estimateTimeLeft({ status = "abandoned", percent = 0.4, pages = 100 }, { avg_time = 90 }), nil)
    end)
    it("shows a duration on an in-progress tile only when one was stored", function()
        eq(Core.tileTimeLeft({ status = "reading", time_left = 7200 }), "2h")
        eq(Core.tileTimeLeft({ status = "reading" }), nil)
        eq(Core.tileTimeLeft({ status = "complete", time_left = 7200 }), nil)
        eq(Core.tileTimeLeft({ status = "new", time_left = 7200 }), nil)
    end)
    it("asks a stats provider once per book, and not when the sidecar already knows", function()
        local calls = {}
        local idx = Index.new({
            stats_for = function(path)
                calls[path] = (calls[path] or 0) + 1
                if path == "/slow" then return { avg_time = 100 } end
            end,
        })
        local slow = { path = "/slow", status = "reading", percent = 0.4, pages = 100 }
        eq(idx:timeLeftFor(slow, { stats = { avg_time = 90 } }), 5400)
        eq(calls["/slow"], nil)
        eq(idx:timeLeftFor(slow, {}), 6000)
        eq(idx:timeLeftFor(slow, {}), 6000)
        eq(calls["/slow"], 1)
        local stored = { path = "/stored", status = "reading", percent = 0.5, pages = 10 }
        eq(idx:timeLeftFor(stored, { time_left = 90 }), 90)
        eq(calls["/stored"], nil)
        eq(idx:timeLeftFor({ path = "/done", status = "complete", percent = 1, pages = 10 }, { stats = { avg_time = 10 } }), nil)
        eq(calls["/done"], nil)
    end)
end)

describe("Want to Read collection", function()
    it("adds and removes a book in the Want to Read collection", function()
        local coll = {}
        eq(Core.bookInCollection(coll, "/a.epub", Core.WANT_TO_READ), false)
        eq(Core.toggleCollection(coll, "/a.epub"), true)
        eq(Core.WANT_TO_READ, "Want to Read")
        eq(coll["Want to Read"]["/a.epub"].file, "/a.epub")
        eq(Core.bookInCollection(coll, "/a.epub", Core.WANT_TO_READ), true)
        eq(Core.wantToReadLabel(true), "Remove from Want to Read")
        eq(Core.toggleCollection(coll, "/a.epub"), false)
        eq(Core.bookInCollection(coll, "/a.epub", Core.WANT_TO_READ), false)
        eq(Core.wantToReadLabel(false), "Add to Want to Read")
    end)
    it("finds a book stored as a list item, and ignores a different collection", function()
        local coll = {
            ["Want to Read"] = { { file = "/a.epub" } },
            Favorites = { ["/a.epub"] = { file = "/a.epub" } },
        }
        eq(Core.bookInCollection(coll, "/a.epub", "Want to Read"), true)
        eq(Core.bookInCollection(coll, "/missing.epub", "Want to Read"), false)
        eq(Core.setCollectionMembership(nil, "/a.epub", "Want to Read", true), false)
    end)
end)

describe("Cover only view", function()
    it("is a view of its own, remembered per place the way other layouts are", function()
        eq(Core.viewMode("covers"), "covers")
        eq(Core.isCoverOnly("covers"), true)
        eq(Core.isCoverOnly("grid"), false)
        eq(Core.viewPick("covers", 4), "covers")
        local s = {}
        eq(Core.rememberViewPref(s, "series:Oz", "view", "covers", 5), true)
        eq(Core.viewPrefs(s, "series:Oz").view, "covers")
        eq(Core.viewPrefs(s, "series:Mars").view, "grid")
        eq(Core.viewPrefs(s, "books").view, "grid")
    end)
    it("remembers Cover only for one folder without changing another", function()
        local classics = Core.viewKey("books", { kind = "folder", name = "Classics" })
        local scifi = Core.viewKey("books", { kind = "folder", name = "Sci-Fi" })
        eq(classics, "folder:Classics")
        local s = { view = "list" }
        Core.rememberViewPref(s, classics, "view", "covers", 9)
        eq(Core.viewPrefs(s, classics).view, "covers")
        eq(Core.viewPrefs(s, scifi).view, "list")
    end)
end)

describe("read-only details", function()
    local now = 1e9
    local book = {
        title = "Emma", authors = { "Jane Austen" }, series = "Novels", series_index = 4,
        pages = 310.2, percent = 0.42, status = "reading", last_opened = now - 3600,
        size = 1500000, path = "/books/Emma.epub", time_left = 7200,
    }
    it("lists title, author, series, pages, progress, last read, size and path", function()
        eq(fact(book, "title", now), "Emma")
        eq(fact(book, "author", now), "Jane Austen")
        eq(fact(book, "series", now), "Novels #4")
        eq(fact(book, "pages", now), "310")
        eq(fact(book, "progress", now), "42% · 2h left")
        eq(fact(book, "last_read", now), "1h ago")
        eq(fact(book, "size", now), "1.4 MB")
        eq(fact(book, "path", now), "/books/Emma.epub")
    end)
    it("omits pages and size when they are unknown, and says Never when unread", function()
        local fresh = { title = "New Book", status = "new", opened = false, path = "/n.epub" }
        eq(fact(fresh, "pages", now), nil)
        eq(fact(fresh, "size", now), nil)
        eq(fact(fresh, "series", now), nil)
        eq(fact(fresh, "last_read", now), "Never")
        eq(fact(fresh, "progress", now), "0%")
        local lines = Core.detailLines(fresh, now)
        same(lines, { "Last read  Never", "File  /n.epub" })
    end)
    it("does not put a time left on the progress of a finished book", function()
        eq(fact({ status = "complete", percent = 1, time_left = 999, title = "Done" }, "progress", now), "100%")
    end)
    it("keeps the extra lines to pages, last read, size and path", function()
        same(Core.detailLines(book, now), {
            "Pages  310",
            "Last read  1h ago",
            "Size  1.4 MB",
            "File  /books/Emma.epub",
        })
    end)
end)

describe("tile text for the new badges and time left", function()
    local function stub()
        return setmetatable({}, {
            __index = function() return stub() end,
            __call = function() return stub() end,
        })
    end
    local old = require
    _G.require = function(name)
        if name == "librarycore" or name == "string" or name == "table" or name == "math" then
            return old(name)
        end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then
            return { template = function(s, ...)
                local a = { ... }
                return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
            end }
        end
        return stub()
    end
    local ok, Tiles = pcall(dofile, "library.koplugin/librarytile.lua")
    _G.require = old
    if not ok then error(Tiles, 0) end

    it("shows Read, New, and a time left beside the percent", function()
        eq(select(2, Tiles.compactText({ title = "Done", status = "complete" }, "books")), "Read")
        eq(select(2, Tiles.compactText({ title = "Fresh", status = "new", opened = false }, "books")), "New")
        eq(select(2, Tiles.compactText({ title = "Opened", status = "new", opened = true }, "books")), "")
        eq(select(2, Tiles.compactText(
            { title = "Now", status = "reading", percent = 0.42, time_left = 7200 }, "books")), "42 % · 2h")
        eq(select(2, Tiles.compactText(
            { title = "Now", status = "reading", percent = 0.42 }, "books")), "42 %")
    end)
end)
