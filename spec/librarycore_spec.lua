local Core = require("librarycore")
local F = require("fixtures.fake_library")

local function names(books)
    local out = {}
    for i, b in ipairs(books) do out[i] = b.name end
    return out
end

local function titles(books)
    local out = {}
    for i, b in ipairs(books) do out[i] = b.title end
    return out
end

local function library()
    local books = Core.scan(F.root, F.fs, F.is_book)
    return Core.enrich(books, F.get_props, F.get_status)
end

describe("helpers", function()
    it("splits paths", function()
        local d, n = Core.splitPath("/a/b/c.epub")
        eq(d, "/a/b"); eq(n, "c.epub")
        d, n = Core.splitPath("c.epub")
        eq(d, ""); eq(n, "c.epub")
    end)
    it("finds extensions and stems", function()
        eq(Core.extension("Emma.EPUB"), "epub")
        eq(Core.extension("README"), "")
        eq(Core.extension("archive.tar.gz"), "gz")
        eq(Core.stem("Moby Dick.pdf"), "Moby Dick")
        eq(Core.stem("README"), "README")
    end)
    it("computes relative folders", function()
        eq(Core.relativeDir("/r", "/r"), "")
        eq(Core.relativeDir("/r/", "/r/a/b"), "a/b")
        eq(Core.relativeDir("/r", "/other/x"), "/other/x")
        eq(Core.relativeDir("/r", "/rx/y"), "/rx/y")
    end)
    it("splits author strings", function()
        same(Core.splitAuthors("A\nB"), { "A", "B" })
        same(Core.splitAuthors("A; B ;A"), { "A", "B" })
        same(Core.splitAuthors("A & B"), { "A", "B" })
        same(Core.splitAuthors(""), {})
        same(Core.splitAuthors(nil), {})
    end)
    it("formats sizes", function()
        eq(Core.formatSize(0), "0 B")
        eq(Core.formatSize(1536), "1.5 KB")
        eq(Core.formatSize(9000000), "8.6 MB")
        eq(Core.formatSize(5 * 1024 ^ 4), "5120.0 GB")
    end)
end)

describe("scan", function()
    it("finds books recursively, skipping hidden, .sdr and non-books", function()
        local books = Core.scan(F.root, F.fs, F.is_book)
        same(names(books), {
            "Persuasion.mobi", "Emma.EPUB", "Moby Dick.pdf", -- names sort bytewise per folder
            "Pride and Prejudice.epub",
            "Frankenstein.fb2", "The Time Machine.epub", "The War of the Worlds.epub",
        })
    end)
    it("records folder, extension, size and date", function()
        local books = Core.scan(F.root, F.fs, F.is_book)
        local persuasion = books[1]
        eq(persuasion.folder, "Classics/Deep/Deeper")
        eq(persuasion.ext, "mobi")
        eq(persuasion.size, 300000)
        eq(persuasion.modification, 500)
        eq(books[4].folder, "")
    end)
    it("respects max_depth", function()
        local books = Core.scan(F.root, F.fs, F.is_book, { max_depth = 1 })
        for _, b in ipairs(books) do
            if b.name == "Persuasion.mobi" then error("went too deep") end
        end
        eq(#books, 6)
    end)
    it("includes hidden folders on request", function()
        local books = Core.scan(F.root, F.fs, F.is_book, { show_hidden = true })
        eq(#books, 8)
    end)
    it("stops at the limit and reports truncation", function()
        local books, truncated = Core.scan(F.root, F.fs, F.is_book, { limit = 3 })
        eq(#books, 3); eq(truncated, true)
        local _, t2 = Core.scan(F.root, F.fs, F.is_book)
        eq(t2, false)
    end)
    it("tolerates an unreadable root", function()
        local books = Core.scan("/does/not/exist", F.fs, F.is_book)
        eq(#books, 0)
    end)
end)

describe("enrich", function()
    it("falls back to the file name when the title is blank", function()
        for _, b in ipairs(library()) do
            if b.name == "Moby Dick.pdf" then
                eq(b.title, "Moby Dick")
                same(b.authors, {})
                eq(b.status, "new")
            end
        end
    end)
    it("normalises series and unknown statuses", function()
        for _, b in ipairs(library()) do
            if b.name == "The Time Machine.epub" then
                eq(b.series, "Wells Classics"); eq(b.series_index, 1); eq(b.status, "abandoned")
            elseif b.name == "Frankenstein.fb2" then
                eq(b.status, "reading")
                same(b.authors, { "Mary Shelley", "Percy Bysshe Shelley" })
            end
        end
    end)
end)

describe("sort", function()
    it("sorts by title, case-insensitively", function()
        same(titles(Core.sortBooks(library(), "title")), {
            "Emma", "Frankenstein", "Moby Dick", "Persuasion",
            "Pride and Prejudice", "The Time Machine", "The War of the Worlds",
        })
    end)
    it("sorts by author with unknown authors last", function()
        local sorted = Core.sortBooks(library(), "author")
        eq(sorted[1].authors[1], "H. G. Wells")
        eq(sorted[#sorted].title, "Moby Dick")
    end)
    it("sorts by series index inside a series", function()
        local sorted = Core.sortBooks(library(), "series")
        eq(sorted[1].title, "The Time Machine")
        eq(sorted[2].title, "The War of the Worlds")
    end)
    it("sorts by date added, newest first", function()
        local sorted = Core.sortBooks(library(), "added")
        eq(sorted[1].title, "The War of the Worlds")
        eq(sorted[#sorted].title, "Frankenstein")
    end)
    it("does not mutate the input", function()
        local books = library()
        local first = books[1]
        Core.sortBooks(books, "size")
        eq(books[1], first)
    end)
    it("uses a custom collator when given", function()
        local reversed = Core.sortBooks(library(), "title", function(a, b) return a > b end)
        eq(reversed[1].title, "The War of the Worlds")
    end)
end)

describe("group", function()
    it("groups by author, listing co-authors under each", function()
        local groups = Core.group(library(), "author")
        local keys = {}
        for i, g in ipairs(groups) do keys[i] = g.key .. ":" .. #g.books end
        same(keys, {
            "H. G. Wells:2", "Jane Austen:3", "Mary Shelley:1",
            "Percy Bysshe Shelley:1", Core.UNKNOWN .. ":1",
        })
    end)
    it("groups by status in a fixed order", function()
        local keys = {}
        for i, g in ipairs(Core.group(library(), "status")) do keys[i] = g.key end
        same(keys, { "reading", "new", "abandoned", "complete" })
    end)
    it("groups by format and folder", function()
        local fmt = {}
        for i, g in ipairs(Core.group(library(), "format")) do fmt[i] = g.key end
        same(fmt, { "epub", "fb2", "mobi", "pdf" })
        local folders = {}
        for i, g in ipairs(Core.group(library(), "folder")) do folders[i] = g.key end
        same(folders, { "", "Classics", "Classics/Deep/Deeper", "Sci-Fi" })
    end)
    it("rejects unknown groupings", function()
        local ok = pcall(Core.group, library(), "colour")
        eq(ok, false)
    end)
end)

describe("search", function()
    it("matches every word across fields, case-insensitively", function()
        same(titles(Core.search(library(), "austen EMMA")), { "Emma" })
        eq(#Core.search(library(), "wells classics"), 2)
        eq(#Core.search(library(), "romance"), 1)
        eq(#Core.search(library(), ".fb2"), 1)
    end)
    it("honours case sensitivity", function()
        eq(#Core.search(library(), "austen", true), 0)
        eq(#Core.search(library(), "Austen", true), 3)
    end)
    it("returns everything for an empty query", function()
        eq(#Core.search(library(), "   "), 7)
    end)
    it("treats magic characters literally", function()
        eq(#Core.search(library(), "H. G."), 2)
        eq(#Core.search(library(), "%"), 0)
    end)
end)

describe("summaries", function()
    it("returns recent books", function()
        same(titles(Core.recent(library(), 2)), { "The War of the Worlds", "The Time Machine" })
    end)
    it("counts statuses", function()
        same(Core.countByStatus(library()), {
            all = 7, new = 3, reading = 2, abandoned = 1, complete = 1,
        })
    end)
    it("builds list labels", function()
        local b = { title = "The Time Machine", authors = { "H. G. Wells" }, series_index = 1 }
        eq(Core.label(b), "The Time Machine — H. G. Wells")
        eq(Core.label(b, true), "1. The Time Machine — H. G. Wells")
        eq(Core.label({ name = "x.epub", authors = {} }), "x.epub")
        eq(Core.label({ title = "T", series_index = 2.5 }, true), "2.5. T")
    end)
end)

describe("Library core: grid, filters, search index, calibre, cache", function()
    local function bk(t) return t end
    local books = {
        bk{ path = "/a", name = "a.epub", title = "Emma", authors = { "Jane Austen" }, status = "complete", modification = 1 },
        bk{ path = "/b", name = "b.epub", title = "Dracula", authors = { "Bram Stoker" }, status = "reading",
            percent = 0.3, last_opened = 50, modification = 2 },
        bk{ path = "/c", name = "c.epub", title = "Ivanhoe", authors = { "Walter Scott" }, status = "new", modification = 3 },
        bk{ path = "/d", name = "d.epub", title = "Kidnapped", authors = { "R. L. Stevenson" }, series = "David Balfour",
            status = "abandoned", last_opened = 80, modification = 0 },
    }

    it("sorts by recent: last opened first, then newest files", function()
        local sorted = Core.sortBooks(books, "recent")
        same({ sorted[1].path, sorted[2].path, sorted[3].path, sorted[4].path }, { "/d", "/b", "/c", "/a" })
    end)

    it("filters by status chip", function()
        eq(#Core.filterStatus(books, "all"), 4)
        eq(Core.filterStatus(books, "unread")[1].path, "/c")
        eq(Core.filterStatus(books, "reading")[1].path, "/b")
        eq(Core.filterStatus(books, "finished")[1].path, "/a")
        same(Core.countFilters(books), { all = 4, unread = 1, reading = 1, finished = 1 })
    end)

    it("searches precomputed keys and narrows previous results", function()
        Core.indexBooks(books)
        eq(#Core.searchIndexed(books, "STEV"), 1)
        eq(#Core.searchIndexed(books, "balfour kid"), 1)
        eq(#Core.searchIndexed(books, ""), 4)
        local prev = Core.searchIndexed(books, "a")
        local narrowed = Core.searchIndexed(books, "au", nil, prev)
        eq(#narrowed, 1)
        eq(Core.isRefinement("au", "aus"), true)
        eq(Core.isRefinement("aus", "au"), false)
        eq(Core.isRefinement("", "a"), false)
    end)

    it("pages lists and clamps the page", function()
        local list = {}
        for i = 1, 25 do list[i] = i end
        local items, page, pages = Core.page(list, 10, 3)
        same(items, { 21, 22, 23, 24, 25 }); eq(page, 3); eq(pages, 3)
        local _, p2 = Core.page(list, 10, 9)
        eq(p2, 3)
        local empty, p3, n3 = Core.page({}, 10, 1)
        eq(#empty, 0); eq(p3, 1); eq(n3, 1)
    end)

    it("computes a grid layout with 2:3 covers", function()
        local l = Core.gridLayout(1000, 1500, 4, 60, 10)
        eq(l.cols, 4); eq(l.tile_w, 237); eq(l.rows, 4); eq(l.cover_h, 302); eq(l.per_page, 16)
        local roomy = Core.gridLayout(1000, 900, 4, 60, 10)
        eq(roomy.rows, 2); eq(roomy.cover_h, 355)
        local small = Core.gridLayout(1000, 200, 4, 60, 10)
        eq(small.rows, 1)
        eq(small.tile_h <= 180, true)
    end)

    it("maps metadata.calibre entries to absolute paths", function()
        local map = Core.calibreIndex({
            { lpath = "documents/Emma.epub", title = "Emma", authors = { "Jane Austen" }, series = "Novels",
              series_index = 2, tags = { "classic" } },
            { lpath = "", title = "skipped" },
            "junk",
        }, "/mnt/us/")
        local e = map["/mnt/us/documents/Emma.epub"]
        eq(e.title, "Emma"); eq(e.authors, "Jane Austen"); eq(e.series_index, 2); eq(e.keywords, "classic")
        local n = 0
        for _ in pairs(map) do n = n + 1 end
        eq(n, 1)
    end)

    it("looks for metadata.calibre in the root and its parents", function()
        same(Core.calibreCandidateDirs("/mnt/us/documents", { "/mnt/us/inbox" }),
            { "/mnt/us/documents", "/mnt/us", "/mnt", "/mnt/us/inbox" })
    end)

    it("reconciles scanned files with cache entries by size and mtime", function()
        local scanned = {
            { path = "/x", size = 1, modification = 1 },
            { path = "/y", size = 2, modification = 2 },
            { path = "/z", size = 3, modification = 3 },
        }
        local cache = {
            ["/x"] = { size = 1, modification = 1, title = "X", src = "bim", cal = "s", status = "new" },
            ["/y"] = { size = 2, modification = 9, title = "Y", src = "bim", cal = "s", status = "complete" },
        }
        local reused, stale = Core.reconcile(scanned, cache, "s")
        eq(#reused, 1); eq(reused[1].title, "X")
        eq(#stale, 2); eq(stale[1].status, "complete")
        local _, stale2 = Core.reconcile({ { path = "/x", size = 1, modification = 1 } }, cache, "other")
        eq(#stale2, 1)
    end)

    it("round-trips the cache through serialize/deserialize", function()
        local data = { version = 2, root = "/r", entries = { ["/a \"q\""] = { title = "A\nB", percent = 0.125, authors = { "X", "Y" }, ok = true } } }
        local back = Core.deserialize(Core.serialize(data))
        same(back, data)
        eq(Core.deserialize("return os.exit()"), nil)
        eq(Core.deserialize("garbage("), nil)
    end)
end)
