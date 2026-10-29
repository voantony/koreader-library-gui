local Covers = require("librarycovers")

-- In-memory file system with the adapter interface librarycovers expects.
local function fakeFS()
    local files = {}
    local fs = { files = files }
    fs.exists = function(p) return files[p] ~= nil end
    fs.read = function(p) return files[p] end
    fs.write = function(p, s) files[p] = s; return true end
    fs.rename = function(a, b)
        if files[a] == nil then return false end
        files[b], files[a] = files[a], nil
        return true
    end
    fs.remove = function(p) local had = files[p] ~= nil; files[p] = nil; return had end
    fs.list = function(dir)
        local out = {}
        for p in pairs(files) do
            local d, name = p:match("^(.*)/([^/]+)$")
            if d == dir then out[#out + 1] = name end
        end
        table.sort(out)
        return out
    end
    fs.size = function(p) return files[p] and #files[p] or nil end
    fs.mkdir = function() end
    return fs
end

local DIR = "/cache/library_covers"
local QUEUE = DIR .. "/queue.txt"

local function book(path, mtime, size) return { path = path, modification = mtime or 100, size = size or 2000 } end

local function names(fs)
    local out = {}
    for _, n in ipairs(fs.list(DIR)) do out[#out + 1] = n end
    return out
end

-- Runs the worker over `books` with a fake extractor: covers[path] is the
-- cover to return, "error" raises, nil means "no cover".
local function run(fs, books, covers, extra)
    fs.write(QUEUE, Covers.encodeQueue(Covers.order(books, nil)))
    local extracted = {}
    local env = {
        fs = fs, dir = DIR, queue = QUEUE,
        extract = function(path)
            extracted[#extracted + 1] = path
            local c = covers[path]
            if c == "error" then error("broken file") end
            return c
        end,
        save = function(cover, tmp) fs.write(tmp, "JPEG:" .. cover); return true end,
    }
    for k, v in pairs(extra or {}) do env[k] = v end
    return Covers.work(env), extracted
end

describe("covers: cache key", function()
    it("hashes paths to 16 hex digits, stably", function()
        local h = Covers.hash("/mnt/us/documents/Emma.epub")
        eq(#h, 16)
        assert(h:match("^%x+$"), h)
        eq(Covers.hash("/mnt/us/documents/Emma.epub"), h)
        eq(Covers.hash(""), "811c9dc55bd1e995")
    end)
    it("gives different paths different hashes", function()
        local seen = {}
        for i = 1, 2000 do
            local h = Covers.hash("/mnt/us/documents/Author " .. (i % 37) .. "/Book " .. i .. ".epub")
            assert(not seen[h], "collision at " .. i)
            seen[h] = true
        end
        assert(Covers.hash("ab") ~= Covers.hash("ba"))
    end)
    it("puts mtime and size in the key", function()
        local k = Covers.key(book("/b/x.epub", 1700000000, 12345))
        eq(k, Covers.hash("/b/x.epub") .. "-1700000000-12345")
        assert(Covers.key(book("/b/x.epub", 1700000001, 12345)) ~= k, "mtime")
        assert(Covers.key(book("/b/x.epub", 1700000000, 12346)) ~= k, "size")
        eq(Covers.hashOf(k), Covers.hash("/b/x.epub"))
    end)
    it("parses cache file names", function()
        local k = Covers.key(book("/b/x.epub"))
        local key, ext = Covers.parseName(k .. ".jpg")
        eq(key, k); eq(ext, "jpg")
        eq(select(2, Covers.parseName(k .. ".none")), "none")
        eq(Covers.parseName("queue.txt"), nil)
        eq(Covers.parseName(k .. ".jpg.tmp"), nil)
    end)
end)

describe("covers: thumbnail size", function()
    it("is the cover box of a tile at 3 columns", function()
        -- Kindle Colorsoft: 1264 px wide; gap and padding as on the device
        local w, h = Covers.thumbBox(1264, 1680, 10, 5)
        local tile_w = math.floor((1264 - 10 * 4) / 3)
        eq(w, tile_w - 10); eq(h, math.floor(tile_w * 1.5) - 5)
    end)
    it("covers every tile the column menu can make", function()
        local gap, pad = 10, 5
        local bw, bh = Covers.thumbBox(1264, 1680, gap, pad)
        for cols = 3, 6 do
            local tile_w = math.floor((1264 - gap * (cols + 1)) / cols)
            assert(tile_w - 2 * pad <= bw and math.floor(tile_w * 1.5) - pad <= bh, cols .. " columns")
        end
    end)
    it("uses the narrow side in landscape", function()
        same({ Covers.thumbBox(1680, 1264, 10, 5) }, { Covers.thumbBox(1264, 1680, 10, 5) })
    end)
    it("is capped at 800 px on very large screens", function()
        local w, h = Covers.thumbBox(2400, 3200, 0, 0)
        eq(h, 800)
        assert(w <= 534, w)
    end)
    it("only ever scales down", function()
        same({ Covers.fitDown(1200, 1800, 400, 600) }, { 400, 600 })
        same({ Covers.fitDown(1000, 1000, 400, 600) }, { 400, 400 })
        same({ Covers.fitDown(300, 450, 400, 600) }, { 300, 450 })
    end)
end)

describe("covers: queue order", function()
    local a, b, c, d = book("/a"), book("/b"), book("/c"), book("/d")
    it("puts visible books first, then the rest, each once", function()
        local items = Covers.order({ c, a }, { a, b, c, d })
        local paths = {}
        for i, it in ipairs(items) do paths[i] = it.path end
        same(paths, { "/c", "/a", "/b", "/d" })
        eq(items[1].key, Covers.key(c))
    end)
    it("skips books that are done", function()
        local items = Covers.order({ a, b }, { c, d }, function(x) return x.path == "/b" or x.path == "/d" end)
        eq(#items, 2); eq(items[1].path, "/a"); eq(items[2].path, "/c")
    end)
    it("round-trips through the queue file", function()
        local items = Covers.order({ book("/x y/é.epub") }, { book("/z.pdf") })
        same(Covers.decodeQueue(Covers.encodeQueue(items)), items)
        eq(Covers.encodeQueue({}), "")
        eq(#Covers.decodeQueue(Covers.encodeQueue({ { key = "k", path = "bad\npath" } })), 0)
    end)
    it("follows a rewritten queue between books", function()
        local fs = fakeFS()
        local order = {}
        local pages = { book("/p1"), book("/p2"), book("/p3") }
        fs.write(QUEUE, Covers.encodeQueue(Covers.order(pages, nil)))
        Covers.work{
            fs = fs, dir = DIR, queue = QUEUE,
            extract = function(path)
                order[#order + 1] = path
                if path == "/p1" then -- the user turned the page: /p3 is visible now
                    fs.write(QUEUE, Covers.encodeQueue(Covers.order({ pages[3] }, pages)))
                end
                return "cover"
            end,
            save = function(cover, tmp) fs.write(tmp, cover); return true end,
        }
        same(order, { "/p1", "/p3", "/p2" })
    end)
    it("stops when the queue file is removed", function()
        local fs = fakeFS()
        local seen = {}
        fs.write(QUEUE, Covers.encodeQueue(Covers.order({ book("/1"), book("/2") }, nil)))
        local stats = Covers.work{
            fs = fs, dir = DIR, queue = QUEUE,
            extract = function(path) seen[#seen + 1] = path; fs.remove(QUEUE); return "c" end,
            save = function(cover, tmp) fs.write(tmp, cover); return true end,
        }
        same(seen, { "/1" }); eq(stats.done, 1)
    end)
end)

describe("covers: worker and store", function()
    it("writes a thumbnail per book and finds it", function()
        local fs = fakeFS()
        local b = book("/books/Emma.epub")
        local stats = run(fs, { b }, { ["/books/Emma.epub"] = "emma" })
        eq(stats.done, 1)
        local store = Covers.newStore(DIR, fs)
        local state, path = store:state(b)
        eq(state, "cover")
        eq(fs.read(path), "JPEG:emma")
        same(names(fs), { Covers.key(b) .. ".jpg", "queue.txt" })
    end)
    it("marks books without a cover, and broken ones, so they are not retried", function()
        local fs = fakeFS()
        local plain, broken = book("/plain.txt"), book("/broken.epub")
        local stats, extracted = run(fs, { plain, broken }, { ["/broken.epub"] = "error" })
        eq(stats.none, 2)
        local store = Covers.newStore(DIR, fs)
        eq(store:state(plain), "none"); eq(store:state(broken), "none")
        local _, again = run(fs, { plain, broken }, {})
        eq(#extracted, 2); eq(#again, 0, "no second attempt")
    end)
    it("retries when the file's mtime changes, and drops the old thumbnail", function()
        local fs = fakeFS()
        local v1 = book("/books/Emma.epub", 100)
        run(fs, { v1 }, {})
        local v2 = book("/books/Emma.epub", 200)
        local store = Covers.newStore(DIR, fs)
        eq(store:state(v2), nil, "new mtime: not extracted yet")
        local stats = run(fs, { v2 }, { ["/books/Emma.epub"] = "emma2" })
        eq(stats.done, 1)
        store:scan()
        eq(store:state(v2), "cover")
        eq(store:state(v1), nil, "old marker removed")
        same(names(fs), { Covers.key(v2) .. ".jpg", "queue.txt" })
    end)
    it("gives up on a book after repeated interrupted attempts", function()
        local fs = fakeFS()
        local b = book("/crash.epub")
        local key = Covers.key(b)
        -- two earlier runs died while on this book
        fs.write(DIR .. "/" .. key .. ".try", "2")
        local stats, extracted = run(fs, { b }, { ["/crash.epub"] = "c" })
        eq(stats.gave_up, 1); eq(#extracted, 0)
        eq(Covers.newStore(DIR, fs):state(b), "none")
        -- one interrupted attempt is retried
        local fs2 = fakeFS()
        fs2.write(DIR .. "/" .. key .. ".try", "1")
        stats = run(fs2, { b }, { ["/crash.epub"] = "c" })
        eq(stats.done, 1)
        eq(fs2.exists(DIR .. "/" .. key .. ".try"), false)
    end)
    it("treats a failed save as no cover, without leaving a temp file", function()
        local fs = fakeFS()
        local b = book("/x.epub")
        run(fs, { b }, { ["/x.epub"] = "c" }, { save = function() return false end })
        same(names(fs), { Covers.key(b) .. ".none", "queue.txt" })
    end)
    it("refreshes one book from disk and forgets a path", function()
        local fs = fakeFS()
        local b = book("/b.epub")
        local store = Covers.newStore(DIR, fs)
        store:scan()
        eq(store:state(b), nil)
        fs.write(DIR .. "/" .. Covers.key(b) .. ".jpg", "img")
        eq(store:state(b), nil, "still the old listing")
        eq(store:refresh(b), "cover")
        store:forget("/b.epub")
        eq(store:state(b), nil)
        eq(fs.exists(DIR .. "/" .. Covers.key(b) .. ".jpg"), false)
    end)
    it("reports usage and clears everything", function()
        local fs = fakeFS()
        run(fs, { book("/1"), book("/2"), book("/3") }, { ["/1"] = "aa", ["/2"] = "bbb" })
        local store = Covers.newStore(DIR, fs)
        local n, bytes = store:usage()
        eq(n, 3); eq(bytes, #"JPEG:aa" + #"JPEG:bbb" + 1) -- the .none marker holds the try count
        store:clear()
        same(names(fs), {})
    end)
end)
