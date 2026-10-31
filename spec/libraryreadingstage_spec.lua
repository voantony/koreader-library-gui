-- Unread / Barely started / Reading: an opened book you did not start is
-- unread, a few pages past the contents is barely started, a chapter in is
-- reading. Chapter marks come from the table of contents; percentages
-- stand in when there is none.
local Core = require("librarycore")

local function stage(t, th) return Core.readingStage(t, th) end

-- A typical EPUB: front matter listed in the TOC, then chapters.
-- 300 pages; Chapter 1 on page 6, Chapter 2 on page 20.
local TOC = {
    { title = "Cover", page = 1, depth = 1 },
    { title = "Title Page", page = 2, depth = 1 },
    { title = "Copyright", page = 3, depth = 1 },
    { title = "Contents", page = 4, depth = 1 },
    { title = "Chapter 1", page = 6, depth = 1 },
    { title = "Chapter 2", page = 20, depth = 1 },
    { title = "Chapter 3", page = 41, depth = 1 },
}

local function at(page, marks, pages)
    pages = pages or 300
    return Core.applyMarks({ status = "reading", percent = page / pages, pages = pages }, marks)
end

describe("table of contents marks", function()
    it("skips front matter and finds where the first chapter ends", function()
        same(Core.tocMarks(TOC, 300), { start = 6, chapter = 20, pages = 300 })
    end)
    it("knows front matter in a few languages, not chapter titles", function()
        for _, t in ipairs({ "Cover", "CONTENTS", "Table of Contents", "Índice", "Portada",
                "Dedicatoria", "Table des matières", "Inhaltsverzeichnis", "Also by Jane Doe", "Contents." }) do
            eq(Core.isFrontMatter(t), true, t)
        end
        for _, t in ipairs({ "Chapter 1", "Prologue", "Introduction", "The Title Fight", "Uno" }) do
            eq(Core.isFrontMatter(t), false, t)
        end
    end)
    it("steps from a part heading down to its first chapter", function()
        local toc = {
            { title = "Contents", page = 3, depth = 1 },
            { title = "Part One", page = 5, depth = 1 },
            { title = "1", page = 6, depth = 2 },
            { title = "2", page = 15, depth = 2 },
            { title = "Part Two", page = 100, depth = 1 },
        }
        same(Core.tocMarks(toc, 200), { start = 6, chapter = 15, pages = 200 })
    end)
    it("does not stop at a section inside the first chapter", function()
        local toc = {
            { title = "Chapter 1", page = 3, depth = 1 },
            { title = "1.1", page = 3, depth = 2 },
            { title = "1.2", page = 5, depth = 2 },
            { title = "Chapter 2", page = 12, depth = 1 },
        }
        same(Core.tocMarks(toc, 100), { start = 3, chapter = 12, pages = 100 })
    end)
    it("gives up on missing or odd tables of contents", function()
        eq(Core.tocMarks(nil, 300), nil)
        eq(Core.tocMarks({}, 300), nil)
        eq(Core.tocMarks({ { title = "Contents", page = 2, depth = 1 } }, 300), nil)
        eq(Core.tocMarks({ { title = "Chapter 1", page = 250, depth = 1 } }, 300), nil)
    end)
    it("a one-chapter book has no next chapter", function()
        same(Core.tocMarks({ { title = "Cover", page = 1 }, { title = "The Story", page = 2 } }, 50),
            { start = 2, chapter = nil, pages = 50 })
    end)
end)

describe("reading stage with chapter marks", function()
    local marks = Core.tocMarks(TOC, 300)
    it("opened only: on the cover is unread", function()
        eq(stage(at(1, marks)), "unread")
    end)
    it("on the table of contents is unread", function()
        eq(stage(at(4, marks)), "unread")
    end)
    it("on the first page of chapter 1 is still unread", function()
        eq(stage(at(6, marks)), "unread")
    end)
    it("a few pages after the contents is barely started", function()
        eq(stage(at(7, marks)), "barely")
        eq(stage(at(10, marks)), "barely")
        eq(stage(at(19, marks)), "barely")
    end)
    it("one chapter in is reading", function()
        eq(stage(at(20, marks)), "reading")
        eq(stage(at(150, marks)), "reading")
    end)
    it("ignores the percentage threshold when chapters are known", function()
        eq(stage(at(19, marks), 0.05), "barely") -- 6 %, above a 5 % threshold
        eq(stage(at(20, marks), 0.25), "reading")
    end)
    it("still works after a font change (marks are fractions of the book)", function()
        -- same book re-laid out to 600 pages: Chapter 2 now on about page 40
        local b = Core.applyMarks({ status = "reading", percent = 30 / 600, pages = 600 }, marks)
        eq(stage(b), "barely")
        b.percent = 41 / 600
        eq(stage(b), "reading")
    end)
    it("a very long first chapter counts as reading 25 % past its start", function()
        local m = { start = 2, chapter = 200, pages = 300 }
        eq(stage(at(60, m)), "barely")
        eq(stage(at(80, m)), "reading")
        local one = { start = 2, pages = 50 } -- no next chapter
        eq(stage(at(10, one, 50)), "barely")
        eq(stage(at(15, one, 50)), "reading")
    end)
end)

describe("reading stage without a table of contents", function()
    local function pct(p, pages) return { status = "reading", percent = p, pages = pages } end
    it("opened with no progress saved is unread", function()
        eq(stage({ status = "reading" }), "unread")
        eq(stage(pct(0)), "unread")
    end)
    it("up to page 3 or 2 % is unread", function()
        eq(stage(pct(3 / 300, 300)), "unread")
        eq(stage(pct(6 / 300, 300)), "unread")   -- 2 %
        eq(stage(pct(15 / 1000, 1000)), "unread") -- 1.5 %
        eq(stage(pct(3 / 40, 40)), "unread")     -- page 3 of a short book
        eq(stage(pct(0.015)), "unread")          -- page count unknown
    end)
    it("then barely started below the threshold, reading from it", function()
        eq(stage(pct(10 / 300, 300)), "barely")
        eq(stage(pct(29 / 300, 300)), "barely")
        eq(stage(pct(30 / 300, 300)), "reading") -- 10 %, the default
        eq(stage(pct(0.07, 300), 0.05), "reading")
        eq(stage(pct(0.18, 300), 0.20), "barely")
    end)
end)

describe("reading stage keeps KOReader's own marks", function()
    local marks = Core.tocMarks(TOC, 300)
    it("finished stays finished, wherever you are", function()
        local b = at(1, marks); b.status = "complete"
        eq(stage(b), "finished")
        eq(stage({ status = "complete" }), "finished")
    end)
    it("on hold stays on hold, never opened stays unread", function()
        local b = at(10, marks); b.status = "abandoned"
        eq(stage(b), "on_hold")
        eq(stage({ status = "new" }), "unread")
        eq(stage({}), "unread")
    end)
end)

describe("status chips use the stage", function()
    local marks = Core.tocMarks(TOC, 300)
    local books = {
        { path = "/never", status = "new" },
        { path = "/opened", status = "reading", percent = 1 / 300, pages = 300 },
        { path = "/toc", status = "reading", percent = 4 / 300, pages = 300 },
        { path = "/few", status = "reading", percent = 9 / 300, pages = 300 },
        { path = "/chapter", status = "reading", percent = 20 / 300, pages = 300 },
        { path = "/nomarks", status = "reading", percent = 0.5, pages = 300 },
        { path = "/done", status = "complete", percent = 1 },
    }
    for i = 2, 5 do Core.applyMarks(books[i], marks) end
    local function paths(list)
        local out = {}
        for i, b in ipairs(list) do out[i] = b.path end
        return out
    end
    it("sorts each book into exactly one chip", function()
        same(paths(Core.filterStatus(books, "unread")), { "/never", "/opened", "/toc" })
        same(paths(Core.filterStatus(books, "barely")), { "/few" })
        same(paths(Core.filterStatus(books, "reading")), { "/chapter", "/nomarks" })
        same(paths(Core.filterStatus(books, "finished")), { "/done" })
        same(Core.countFilters(books), { all = 7, unread = 3, barely = 1, reading = 2, finished = 1 })
    end)
    it("keeps marks and page count through the index cache", function()
        local cached = Core.deserialize(Core.serialize({ entries = Core.toCacheEntries{
            { path = "/few", size = 1, modification = 1, status = "reading", percent = 9 / 300,
              pages = 300, m_start = 6 / 300, m_chap = 20 / 300, cal = "s", src = "bim" },
        } }))
        local reused = Core.reconcile({ { path = "/few", size = 1, modification = 1 } }, cached.entries, "s")
        eq(reused[1].pages, 300)
        eq(stage(reused[1]), "barely")
        local _, stale = Core.reconcile({ { path = "/few", size = 2, modification = 1 } }, cached.entries, "s")
        eq(stage(stale[1]), "barely")
    end)
end)

describe("index reads the stage from the sidecar", function()
    local Index = require("libraryindex")
    local data = {}
    local idx = Index.new{
        root = "/b", cache_file = os.tmpname(),
        fs = { attributes = function(p, f) return f and 1 or { mode = "file", modification = 1 } end },
        docsettings = {
            findSidecarFile = function(_, path) return data[path] and path .. ".sdr" end,
            openSettingsFile = function(file) return { data = data[file:gsub("%.sdr$", "")] } end,
        },
    }
    local marks = { start = 6, chapter = 20, pages = 300 }
    it("an opened book still on the contents is unread (NEW), not reading", function()
        data["/b/a.epub"] = { summary = { status = "reading" }, percent_finished = 4 / 300,
                              doc_pages = 300, library_marks = marks }
        local b = { path = "/b/a.epub" }
        idx:refreshState(b)
        eq(b.status, "new")
        eq(Core.continueReading({ b }, 5)[1], nil)
    end)
    it("a few pages in stays reading, as barely started", function()
        data["/b/c.epub"] = { summary = { status = "reading" }, percent_finished = 9 / 300,
                              doc_pages = 300, library_marks = marks }
        local b = { path = "/b/c.epub" }
        idx:refreshState(b)
        eq(b.status, "reading")
        eq(Core.readingStage(b), "barely")
        eq(Core.continueReading({ b }, 5)[1], b)
    end)
    it("finished stays finished even on page 1", function()
        data["/b/d.epub"] = { summary = { status = "complete" }, percent_finished = 1 / 300, doc_pages = 300 }
        local b = { path = "/b/d.epub" }
        idx:refreshState(b)
        eq(b.status, "complete")
    end)
end)
