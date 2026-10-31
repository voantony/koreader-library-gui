-- Index tests: calibre > BookInfoManager > sidecar > file name precedence,
-- reading state from sidecars, history order, and the incremental disk cache.
local F = require("fixtures.fake_library")
local Core = require("librarycore")
local Index = require("libraryindex")

local CACHE = os.tmpname()

-- A sidecar exists for Emma (finished) and Time Machine (reading, 42%).
local sidecars = {
    ["/mnt/test/books/Classics/Emma.EPUB"] = "/sdr/emma.lua",
    ["/mnt/test/books/Sci-Fi/The Time Machine.epub"] = "/sdr/tm.lua",
}
local sidecar_data = {
    ["/sdr/emma.lua"] = { summary = { status = "complete" }, percent_finished = 1 },
    ["/sdr/tm.lua"] = { summary = { status = "reading" }, percent_finished = 0.42,
                        doc_props = { title = "Sidecar title" } },
}
local sidecar_mtime = { ["/sdr/emma.lua"] = 10, ["/sdr/tm.lua"] = 20 }

local counters
local function reset() counters = { bim = 0, sidecar = 0, calibre = 0 } end

local fs = {
    dir = F.fs.dir,
    attributes = function(path, field)
        local a
        if sidecar_mtime[path] then
            a = { mode = "file", size = 1, modification = sidecar_mtime[path] }
        elseif path == "/mnt/test/metadata.calibre" then
            a = { mode = "file", size = 100, modification = 7 }
        else
            a = F.fs.attributes(path)
        end
        if field then return a and a[field] end
        return a
    end,
}

local bim = {
    getBookInfo = function(_, path)
        counters.bim = counters.bim + 1
        local p = F.props[path]
        if not p then return nil end
        return { title = p.title, authors = p.authors, series = p.series, series_index = p.series_index }
    end,
}

local docsettings = {
    findSidecarFile = function(_, path) return sidecars[path] end,
    openSettingsFile = function(file)
        counters.sidecar = counters.sidecar + 1
        return { data = sidecar_data[file] }
    end,
}

local function newIndex(extra)
    local opts = {
        root = F.root, fs = fs, is_book = F.is_book, cache_file = CACHE,
        bim = bim, docsettings = docsettings,
        history = { hist = {
            { file = "/mnt/test/books/Classics/Emma.EPUB", time = 500 },
            { file = "/mnt/test/books/Sci-Fi/The Time Machine.epub", time = 900 },
        } },
        calibre_load = function()
            counters.calibre = counters.calibre + 1
            return { {
                lpath = "books/Sci-Fi/Frankenstein.fb2", title = "Frankenstein; or, The Modern Prometheus",
                authors = { "Mary Shelley" }, series = "Calibre Series", series_index = 3,
            } }
        end,
    }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return Index.new(opts)
end

local function byName(books)
    local m = {}
    for _, b in ipairs(books) do m[b.name] = b end
    return m
end

describe("Index", function()
    os.remove(CACHE)

    it("prefers calibre, then BookInfoManager, then sidecar, then file name", function()
        reset()
        local idx = newIndex()
        local books = byName(idx:build())
        eq(books["Frankenstein.fb2"].title, "Frankenstein; or, The Modern Prometheus")
        eq(books["Frankenstein.fb2"].src, "calibre")
        eq(books["Frankenstein.fb2"].series, "Calibre Series")
        eq(books["Emma.EPUB"].src, "bim")
        eq(books["The Time Machine.epub"].title, "The Time Machine") -- BIM beats sidecar
        eq(counters.calibre, 1)
    end)

    it("falls back to the sidecar's doc_props without a BookInfoManager", function()
        reset()
        os.remove(CACHE)
        local idx = newIndex({ bim = false, calibre_load = false })
        local books = byName(idx:build())
        eq(books["The Time Machine.epub"].title, "Sidecar title")
        eq(books["The Time Machine.epub"].src, "sidecar")
        eq(books["Emma.EPUB"].title, "Emma")
        eq(books["Emma.EPUB"].src, "file")
        os.remove(CACHE)
    end)

    it("reads status, percent and last-opened time", function()
        reset()
        local idx = newIndex()
        local books = byName(idx:build())
        eq(books["Emma.EPUB"].status, "complete")
        eq(books["The Time Machine.epub"].status, "reading")
        eq(books["The Time Machine.epub"].percent, 0.42)
        eq(books["Persuasion.mobi"].status, "new")
        eq(books["The Time Machine.epub"].last_opened, 900)
        Core.sortBooks(idx.books, "recent")
    end)

    it("reuses the disk cache: no metadata or sidecar reads when nothing changed", function()
        reset()
        local idx = newIndex()
        idx:build()
        eq(idx.stats.from_cache, true)
        eq(idx.stats.refreshed, 0)
        eq(idx.stats.cached, 7)
        eq(counters.calibre, 0)
        eq(counters.sidecar, 0)
        eq(byName(idx.books)["Frankenstein.fb2"].series, "Calibre Series")
    end)

    it("refreshes only the book whose mtime changed", function()
        reset()
        local node = F.tree["/mnt/test/books/Classics/Emma.EPUB"]
        node.modification = node.modification + 1
        local idx = newIndex()
        idx:build()
        node.modification = node.modification - 1
        eq(idx.stats.refreshed, 1)
        eq(idx.stats.cached, 6)
    end)

    it("re-reads reading state only when the sidecar changed", function()
        reset()
        sidecar_mtime["/sdr/tm.lua"] = 21
        sidecar_data["/sdr/tm.lua"].percent_finished = 0.5
        local idx = newIndex()
        local books = byName(idx:build())
        eq(counters.sidecar, 1)
        eq(books["The Time Machine.epub"].percent, 0.5)
    end)

    it("ignores the cache for another root or when forced", function()
        reset()
        local idx = newIndex()
        idx:build(true)
        eq(idx.stats.from_cache, false)
        eq(idx.stats.refreshed, 7)
    end)

    it("keeps percent read from the disk cache without re-reading sidecars", function()
        reset()
        local warm = newIndex()
        warm:build() -- make sure a cache with the current sidecars is on disk
        reset()
        local idx = newIndex()
        local books = byName(idx:build())
        eq(idx.stats.from_cache, true)
        eq(counters.sidecar, 0)
        eq(books["The Time Machine.epub"].percent, 0.5)
        eq(books["Emma.EPUB"].percent, 1)
        eq(books["Persuasion.mobi"].percent, nil)
        -- so the "Barely started" filter works on a cached index too
        eq(#Core.filterStatus(idx.books, "barely", 0.25), 0)
        eq(#Core.filterStatus(idx.books, "barely", 0.10), 0)
        sidecar_mtime["/sdr/tm.lua"] = 22
        sidecar_data["/sdr/tm.lua"].percent_finished = 0.04
        local idx2 = newIndex()
        idx2:build()
        reset()
        local idx3 = newIndex()
        idx3:build()
        eq(counters.sidecar, 0)
        eq(#Core.filterStatus(idx3.books, "barely", 0.05), 1)
        sidecar_data["/sdr/tm.lua"].percent_finished = 0.5
        sidecar_mtime["/sdr/tm.lua"] = 23
    end)

    it("builds search keys over title, authors and series", function()
        local idx = newIndex()
        local books = idx:build()
        eq(#Core.searchIndexed(books, "wells classics"), 2)
        eq(#Core.searchIndexed(books, "prometheus"), 1)
        eq(#Core.searchIndexed(books, "austen"), 3)
        os.remove(CACHE)
    end)

    it("precomputes the words typo-tolerant search uses", function()
        local idx = newIndex()
        local books = idx:build()
        for _, b in ipairs(books) do
            eq(type(b.search_tokens), "table")
            eq(type(b.search_norm), "string")
        end
        eq(#Core.searchIndexed(books, "austne", nil, nil, true), 3)
        eq(#Core.searchIndexed(books, "prometeus", nil, nil, true), 1)
        os.remove(CACHE)
    end)
    it("refreshes from the books in memory: no disk-cache read, search text kept", function()
        reset()
        local idx = newIndex()
        idx:build()
        local reads = 0
        local readCache = idx.readCache
        idx.readCache = function(...) reads = reads + 1; return readCache(...) end
        local tokens = byName(idx.books)["Persuasion.mobi"].search_tokens
        reset()
        idx:build()
        eq(reads, 0)
        eq(idx.stats.from_memory, true)
        eq(idx.stats.cached, 7)
        eq(counters.sidecar, 0)
        eq(counters.calibre, 0)
        eq(byName(idx.books)["Persuasion.mobi"].search_tokens, tokens) -- not rebuilt
        eq(#Core.searchIndexed(idx.books, "austen"), 3)
        -- a book that changed on disk is read again, with fresh search text
        local node = F.tree["/mnt/test/books/Classics/Emma.EPUB"]
        node.modification = node.modification + 1
        idx:build()
        node.modification = node.modification - 1
        eq(idx.stats.refreshed, 1)
        eq(type(byName(idx.books)["Emma.EPUB"].search_key), "string")
        -- forced: the disk and memory are both ignored
        idx:build(true)
        eq(idx.stats.from_cache, false)
        eq(idx.stats.refreshed, 7)
        os.remove(CACHE)
    end)

    it("still sees reading-state changes when refreshing from memory", function()
        reset()
        local idx = newIndex()
        idx:build()
        sidecar_mtime["/sdr/tm.lua"] = 30
        sidecar_data["/sdr/tm.lua"].percent_finished = 0.7
        reset()
        local books = byName(idx:build())
        eq(idx.stats.from_memory, true)
        eq(counters.sidecar, 1)
        eq(books["The Time Machine.epub"].percent, 0.7)
        sidecar_data["/sdr/tm.lua"].percent_finished = 0.5
        sidecar_mtime["/sdr/tm.lua"] = 23
        os.remove(CACHE)
    end)
end)
