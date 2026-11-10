-- Same file reached twice, several formats of one book, and files that are
-- not books. Counts are taken after that, including Finished.
local Core = require("librarycore")
local Index = require("libraryindex")

local function fsFrom(tree)
    local opened = {}
    local fs = {
        opened = opened,
        dir = function(path)
            opened[path] = (opened[path] or 0) + 1
            local node = tree[path]
            if not node or node.mode ~= "directory" then error("cannot open " .. tostring(path)) end
            local i = 0
            return function()
                i = i + 1
                return node.children[i]
            end
        end,
        attributes = function(path, field)
            local node = tree[path]
            if not node then return nil end
            local a = {
                mode = node.mode, size = node.size or 0, modification = node.modification or 1,
                dev = node.dev, ino = node.ino, target = node.target, symlink = node.symlink,
            }
            if field then return a[field] end
            return a
        end,
    }
    return fs
end

local function addFile(tree, path, extra)
    local dir, name = Core.splitPath(path)
    local node = tree[dir]
    node.children[#node.children + 1] = name
    local rec = { mode = "file", size = 100, modification = 1 }
    for k, v in pairs(extra or {}) do rec[k] = v end
    tree[path] = rec
end

local function paths(books)
    local out = {}
    for i, b in ipairs(books) do out[i] = b.path end
    table.sort(out)
    return out
end

describe("path identity", function()
    it("treats trailing slashes, dot segments and /mnt/base-us as the same path", function()
        eq(Core.canonicalPath("/mnt/us/documents//A.epub"), "/mnt/us/documents/A.epub")
        eq(Core.canonicalPath("/mnt/us/documents/../documents/A.epub"), "/mnt/us/documents/A.epub")
        eq(Core.canonicalPath("/mnt/base-us/documents/A.epub"), "/mnt/us/documents/A.epub")
        eq(Core.canonicalPath("/mnt/base-us/"), "/mnt/us")
        eq(Core.fileKey("/mnt/us/documents/Book.EPUB"), Core.fileKey("/mnt/base-us/documents/book.epub"))
        eq(Core.fileKey("/home/reader/Book.EPUB"), "/home/reader/Book.EPUB") -- case stays
        local aliases = Core.pathAliases("/mnt/base-us/documents/A.epub")
        local has_us, has_base = false, false
        for _, p in ipairs(aliases) do
            if p == "/mnt/us/documents/A.epub" then has_us = true end
            if p == "/mnt/base-us/documents/A.epub" then has_base = true end
        end
        eq(has_us, true)
        eq(has_base, true)
    end)

    it("collapses two records of one file and keeps the path that is not a symlink", function()
        local books = Core.collapseSameFile({
            { path = "/mnt/us/documents/Link.epub", symlink = true, dev = 1, ino = 9, ext = "epub" },
            { path = "/mnt/base-us/documents/Real.epub", dev = 1, ino = 9, ext = "epub" },
        })
        eq(#books, 1)
        eq(books[1].path, "/mnt/base-us/documents/Real.epub") -- a real file beats a symlink
        eq(books[1].alt_paths[1], "/mnt/us/documents/Link.epub")
        -- two real directory entries: /mnt/us wins over /mnt/base-us
        local mounts = Core.collapseSameFile({
            { path = "/mnt/base-us/documents/A.epub", dev = 1, ino = 4 },
            { path = "/mnt/us/documents/A.epub", dev = 1, ino = 4 },
        })
        eq(mounts[1].path, "/mnt/us/documents/A.epub")
    end)
end)

describe("scan drops the same file and the folders that are not a library", function()
    local root = "/mnt/us/documents"
    local tree = {
        ["/mnt"] = { mode = "directory", children = { "base-us", "us" }, dev = 1, ino = 1 },
        ["/mnt/base-us"] = { mode = "directory", children = { "documents" }, dev = 1, ino = 2 },
        ["/mnt/us"] = { mode = "directory", children = { "documents" }, dev = 1, ino = 3 },
        ["/mnt/base-us/documents"] = { mode = "directory", children = {}, dev = 1, ino = 4 },
        ["/mnt/us/documents"] = { mode = "directory", children = {}, dev = 1, ino = 5 },
    }
    addFile(tree, "/mnt/base-us/documents/Done.epub", { dev = 1, ino = 10, size = 50 })
    addFile(tree, "/mnt/us/documents/Done.epub", { dev = 1, ino = 11, size = 50 }) -- other mount, same book
    addFile(tree, "/mnt/base-us/documents/Book.EPUB", { dev = 1, ino = 12 })
    addFile(tree, "/mnt/base-us/documents/book.epub", { dev = 1, ino = 13, symlink = true })
    addFile(tree, "/mnt/base-us/documents/Notes.txt", { dev = 1, ino = 14 })
    addFile(tree, "/mnt/base-us/documents/Page.html", { dev = 1, ino = 15 })
    addFile(tree, "/mnt/base-us/documents/Readme.md", { dev = 1, ino = 16 })
    addFile(tree, "/mnt/base-us/documents/data.json", { dev = 1, ino = 17 })
    addFile(tree, "/mnt/base-us/documents/Real.epub", { dev = 1, ino = 18 })
    addFile(tree, "/mnt/base-us/documents/Real-link.epub", { dev = 1, ino = 18, symlink = true, target = "/mnt/base-us/documents/Real.epub" })
    for _, name in ipairs({ "node_modules", ".git", "build", "venv", "__pycache__", "system", "Android", "highlights", "koreader" }) do
        local dir = "/mnt/base-us/documents/" .. name
        tree["/mnt/base-us/documents"].children[#tree["/mnt/base-us/documents"].children + 1] = name
        tree[dir] = { mode = "directory", children = { "Secret.epub", "notes.txt" }, dev = 2, ino = 100 + #name }
        tree[dir .. "/Secret.epub"] = { mode = "file", size = 10, modification = 1 }
        tree[dir .. "/notes.txt"] = { mode = "file", size = 10, modification = 1 }
    end
    tree["/mnt/base-us/documents"].children[#tree["/mnt/base-us/documents"].children + 1] = "Book.sdr"
    tree["/mnt/base-us/documents/Book.sdr"] = { mode = "directory", children = { "metadata.epub.lua" }, dev = 1, ino = 80 }
    tree["/mnt/base-us/documents/Book.sdr/metadata.epub.lua"] = { mode = "file", size = 20, modification = 3 }
    local fs = fsFrom(tree)

    it("keeps one path for a symlink, a case twin and the other mount", function()
        local books = Core.scan("/mnt", fs, Core.makeIsBook())
        same(paths(books), {
            -- /mnt/base-us is the copy that was walked; /mnt/us is the same volume and is not walked again
            "/mnt/base-us/documents/Book.EPUB",
            "/mnt/base-us/documents/Done.epub",
            "/mnt/base-us/documents/Real.epub",
        })
        local by = {}
        for _, b in ipairs(books) do by[b.name] = b end
        eq(by["Real.epub"].symlink, nil)
        eq(by["Real.epub"].alt_paths[1], "/mnt/base-us/documents/Real-link.epub")
        eq(fs.opened["/mnt/base-us/documents/node_modules"], nil)
        eq(fs.opened["/mnt/base-us/documents/.git"], nil)
        eq(fs.opened["/mnt/base-us/documents/build"], nil)
        eq(fs.opened["/mnt/base-us/documents/Book.sdr"], nil)
        eq(fs.opened["/mnt/us/documents"], nil) -- same volume as base-us, not walked twice
    end)

    it("can list plain text when that is asked for, still skipping exports and dev folders", function()
        local books = Core.scan("/mnt/base-us/documents", fs, Core.makeIsBook(nil, { plain = true }))
        local found = {}
        for _, b in ipairs(books) do found[b.name] = true end
        eq(found["Notes.txt"], true)
        eq(found["Page.html"], true)
        eq(found["Readme.md"], true)
        eq(found["data.json"], true)
        eq(found["Secret.epub"], nil)
        eq(found["metadata.epub.lua"], nil)
    end)
end)

describe("index groups copies and counts finished books", function()
    local root = "/mnt/base-us"
    local tree = {
        ["/mnt/base-us"] = { mode = "directory", children = { "documents", "metadata.calibre" }, dev = 1, ino = 2 },
        ["/mnt/base-us/metadata.calibre"] = { mode = "file", size = 80, modification = 5 },
        ["/mnt/base-us/documents"] = { mode = "directory", children = { "awk", "other" }, dev = 1, ino = 3 },
        ["/mnt/base-us/documents/awk"] = { mode = "directory", children = {
            "The AWK Programming Language.epub",
            "The AWK Programming Language.pdf",
            "The AWK Programming Language.azw3",
            "The AWK Programming Language.mobi",
        }, dev = 1, ino = 4 },
        ["/mnt/base-us/documents/other"] = { mode = "directory", children = {
            "Done.epub", "Reading.epub", "New.epub", "Other Title.epub", "Isbn Twin.pdf",
        }, dev = 1, ino = 5 },
    }
    local function file(path, ino)
        tree[path] = { mode = "file", size = 100 + ino, modification = ino, dev = 1, ino = ino }
    end
    file("/mnt/base-us/documents/awk/The AWK Programming Language.epub", 21)
    file("/mnt/base-us/documents/awk/The AWK Programming Language.pdf", 22)
    file("/mnt/base-us/documents/awk/The AWK Programming Language.azw3", 23)
    file("/mnt/base-us/documents/awk/The AWK Programming Language.mobi", 24)
    file("/mnt/base-us/documents/other/Done.epub", 31)
    file("/mnt/base-us/documents/other/Reading.epub", 32)
    file("/mnt/base-us/documents/other/New.epub", 33)
    file("/mnt/base-us/documents/other/Other Title.epub", 34)
    file("/mnt/base-us/documents/other/Isbn Twin.pdf", 35)
    local fs = fsFrom(tree)

    -- The sidecar KOReader wrote is under /mnt/us, the path the book was opened with.
    -- The scan sees /mnt/base-us, because that directory is first.
    local sidecars = {
        ["/mnt/us/documents/other/Done.epub"] = "/sdr/done.lua",
        ["/mnt/base-us/documents/other/Reading.epub"] = "/sdr/reading.lua",
        ["/mnt/base-us/documents/awk/The AWK Programming Language.pdf"] = "/sdr/awk-pdf.lua",
        ["/mnt/base-us/documents/awk/The AWK Programming Language.mobi"] = "/sdr/awk-mobi.lua",
        ["/mnt/base-us/documents/other/Other Title.epub"] = "/sdr/other.lua",
    }
    local data = {
        ["/sdr/done.lua"] = { summary = { status = "complete" }, percent_finished = 1 },
        ["/sdr/reading.lua"] = { summary = { status = "reading" }, percent_finished = 0.42, doc_pages = 300 },
        ["/sdr/awk-pdf.lua"] = { summary = { status = "reading" }, percent_finished = 0.2, doc_pages = 200 },
        ["/sdr/awk-mobi.lua"] = { summary = { status = "finished" }, percent_finished = 1 },
        ["/sdr/other.lua"] = { summary = { status = "complete" }, percent_finished = 0.01, doc_pages = 100 },
    }
    local docsettings = {
        findSidecarFile = function(_, path) return sidecars[path] end,
        openSettingsFile = function(file) return { data = data[file] } end,
    }
    local history = { hist = {
        { file = "/mnt/us/documents/other/Done.epub", time = 900 },
        { file = "/mnt/base-us/documents/awk/The AWK Programming Language.pdf", time = 800 },
        { file = "/mnt/base-us/documents/awk/The AWK Programming Language.mobi", time = 100 },
        { file = "/mnt/base-us/documents/other/Reading.epub", time = 700 },
    } }
    local calibre = {
        {
            lpath = "documents/other/Other Title.epub", title = "Renamed by Calibre",
            authors = { "Ada Lovelace" }, uuid = "uuid-same",
        },
        {
            lpath = "documents/other/Isbn Twin.pdf", title = "A Different Spelling",
            authors = { "Someone Else" }, uuid = "uuid-same",
            identifiers = { isbn = "978-0-306-40615-7" },
        },
    }

    local function newIndex(extra)
        local opts = {
            root = root, fs = fs, is_book = Core.makeIsBook(),
            docsettings = docsettings, history = history,
            bim = false,
            calibre_load = function() return calibre end,
            merge_copies = true,
        }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return Index.new(opts)
    end

    local function findTitle(books, title)
        for _, b in ipairs(books) do
            if b.title == title then return b end
        end
    end

    it("reads a finished sidecar stored under the other mount, and counts it once", function()
        eq(Core.normalizeDocStatus("complete"), "complete")
        eq(Core.normalizeDocStatus("Finished"), "complete")
        eq(Core.normalizeDocStatus(" reading "), "reading")
        local books = newIndex():build()
        local done = findTitle(books, "Done")
        eq(done.status, "complete")
        eq(done.open_path, "/mnt/us/documents/other/Done.epub")
        eq(Core.openPath(done), "/mnt/us/documents/other/Done.epub")
        local counts = Core.countFilters(books)
        eq(counts.all, #books)
        eq(counts.finished >= 1, true)
        local finished = Core.filterStatus(books, "finished")
        local saw = false
        for _, b in ipairs(finished) do
            if b.title == "Done" then saw = true end
        end
        eq(saw, true)
        -- sum of the chips never exceeds All (on hold is the only status left out)
        eq(counts.unread + counts.reading + counts.barely + counts.finished <= counts.all, true)
    end)

    it("groups formats of one book and prefers progress, then recent, then epub > azw3 > mobi > pdf", function()
        local books = newIndex():build()
        local awk = findTitle(books, "The AWK Programming Language")
        eq(awk.ext, "pdf") -- both pdf and mobi were started; the pdf was read later
        eq(awk.status, "reading")
        local exts = {}
        for i, c in ipairs(awk.copies) do exts[i] = c.ext end
        table.sort(exts)
        same(exts, { "azw3", "epub", "mobi" })
        local choices = Core.copyChoices(awk)
        eq(#choices, 3)
        local opened = {}
        for _, c in ipairs(choices) do opened[c.path] = c.label end
        eq(opened[awk.path], nil) -- the tile's own file is not listed again
        eq(opened["/mnt/base-us/documents/awk/The AWK Programming Language.epub"] ~= nil, true)
        -- a finished book with no recent open still counts, on its own tile
        local counts = Core.countFilters(books)
        eq(counts.finished, 2) -- Done, and Other Title (complete even at 1%)
    end)

    it("prefers epub when nobody has started the book", function()
        local bare = newIndex({ history = { hist = {} }, docsettings = {
            findSidecarFile = function() return nil end,
        } })
        local awk = findTitle(bare:build(), "The AWK Programming Language")
        eq(awk.ext, "epub")
        eq(#awk.copies, 3)
    end)

    it("merges a Calibre uuid even when the titles differ", function()
        local books = newIndex():build()
        local hit = findTitle(books, "Renamed by Calibre") or findTitle(books, "A Different Spelling")
        eq(hit ~= nil, true)
        eq(hit.copies ~= nil, true)
        eq(#hit.copies, 1)
        local other = hit.copies[1]
        eq(other.title ~= hit.title, true)
    end)

    it("leaves the formats separate when merge is off, and still drops the same file", function()
        local books = newIndex({ merge_copies = false }):build()
        local n = 0
        for _, b in ipairs(books) do
            if b.title == "The AWK Programming Language" then n = n + 1 end
            eq(b.copies, nil)
        end
        eq(n, 4)
        -- Done is still one book, not one per mount
        local done = 0
        for _, b in ipairs(books) do if b.title == "Done" then done = done + 1 end end
        eq(done, 1)
    end)
end)

describe("a few thousand files stay one quick pass", function()
    it("indexes 5000 books, skips a dev tree, and reuses the result", function()
        local root = "/mnt/us/documents"
        local tree = { [root] = { mode = "directory", children = {}, dev = 1, ino = 1 } }
        local n = 5000
        local per = 100
        for d = 1, n / per do
            local shelf = string.format("shelf%02d", d)
            local dir = root .. "/" .. shelf
            tree[root].children[#tree[root].children + 1] = shelf
            local kids = {}
            for i = 1, per do
                local name = string.format("S%02d Book %03d.epub", d, i)
                kids[#kids + 1] = name
                tree[dir .. "/" .. name] = {
                    mode = "file", size = 1000 + i, modification = i, dev = 1, ino = d * 1000 + i,
                }
            end
            kids[#kids + 1] = "notes.txt"
            tree[dir .. "/notes.txt"] = { mode = "file", size = 12, modification = 1, dev = 1, ino = 900000 + d }
            tree[dir] = { mode = "directory", children = kids, dev = 1, ino = 700000 + d }
        end
        -- a second path to the first book
        tree[root].children[#tree[root].children + 1] = "S01 Book 001-link.epub"
        tree[root .. "/S01 Book 001-link.epub"] = {
            mode = "file", size = 1001, modification = 1, dev = 1, ino = 1001, symlink = true,
        }
        for _, name in ipairs({ "node_modules", ".git", "build", "venv", "__pycache__", "system", "Android" }) do
            tree[root].children[#tree[root].children + 1] = name
            tree[root .. "/" .. name] = { mode = "directory", children = { "Secret.epub" }, dev = 4, ino = 400000 }
            tree[root .. "/" .. name .. "/Secret.epub"] = { mode = "file", size = 8, modification = 1, dev = 4, ino = 400001 }
        end
        local fs = fsFrom(tree)
        local calls = 0
        local idx = Index.new{
            root = root, fs = fs, is_book = Core.makeIsBook(), merge_copies = true,
            bim = {
                getBookInfo = function(_, path)
                    calls = calls + 1
                    local base = path:match("([^/]+)$")
                    return { title = Core.stem(base), authors = "Bench Author" }
                end,
            },
            docsettings = { findSidecarFile = function() return nil end },
            history = { hist = {} },
            calibre_load = false,
        }
        local t0 = os.clock()
        local books = idx:build()
        local cold = os.clock() - t0
        eq(#books, n) -- the link is the same file; notes and dev trees are not books
        eq(idx.stats.files, n)
        for _, b in ipairs(books) do
            if b.path:find("node_modules", 1, true) or b.path:find("/build/", 1, true)
                    or b.name == "notes.txt" or b.name == "Secret.epub" then
                error("indexed " .. b.path)
            end
        end
        eq(fs.opened[root .. "/node_modules"], nil)
        eq(fs.opened[root .. "/.git"], nil)
        eq(fs.opened[root .. "/Android"], nil)
        local t1 = os.clock()
        idx:build()
        local warm = os.clock() - t1
        eq(idx.stats.books, n)
        eq(idx.stats.refreshed, 0)
        eq(idx.stats.from_memory, true)
        eq(calls, n) -- warm pass did not ask again
        -- Generous bound: this is an in-memory tree, and a device walk of a
        -- few thousand files should stay in the same neighbourhood.
        -- Loose on purpose: a busy runner is slower, and the bound is only
        -- there so a scan that suddenly walks every dev folder fails loudly.
        eq(cold < 5, true)
        eq(warm < 5, true)
    end)
end)
