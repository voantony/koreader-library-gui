-- Author, then year: comparator, publication-year parsing, and the menu/pref wiring.
local Core = require("librarycore")
local Index = require("libraryindex")

local function u16(n)
    n = math.floor(n) % 65536
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
    n = math.floor(n) % 4294967296
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256)
end

-- A stored (or raw-deflated) zip. CRC is left at 0; the year reader does not check it.
local function zipOf(files)
    local parts, cds = {}, {}
    local offset = 0
    for _, f in ipairs(files) do
        local name, data = f.name, f.data
        local method = f.method or 0
        local usize = f.usize or #data
        local hdr = "PK\003\004" .. u16(20) .. u16(0) .. u16(method)
            .. u16(0) .. u16(0) .. u32(0)
            .. u32(#data) .. u32(usize)
            .. u16(#name) .. u16(0) .. name
        parts[#parts + 1] = hdr .. data
        cds[#cds + 1] = "PK\001\002" .. u16(20) .. u16(20) .. u16(0) .. u16(method)
            .. u16(0) .. u16(0) .. u32(0)
            .. u32(#data) .. u32(usize)
            .. u16(#name) .. u16(0) .. u16(0)
            .. u16(0) .. u16(0) .. u32(0)
            .. u32(offset) .. name
        offset = offset + #hdr + #data
    end
    local locals = table.concat(parts)
    local cd = table.concat(cds)
    local eocd = "PK\005\006" .. u16(0) .. u16(0) .. u16(#files) .. u16(#files)
        .. u32(#cd) .. u32(#locals) .. u16(0)
    return locals .. cd .. eocd
end

local CONTAINER = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]]

local function opf(inner)
    return '<?xml version="1.0"?>'
        .. '<package xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">'
        .. "<metadata>" .. inner .. "</metadata></package>"
end

local function writeBytes(path, bytes)
    local f = assert(io.open(path, "wb"))
    f:write(bytes)
    f:close()
end

local function epubWith(inner)
    local path = os.tmpname() .. ".epub"
    writeBytes(path, zipOf({
        { name = "META-INF/container.xml", data = CONTAINER },
        { name = "OEBPS/book.opf", data = opf(inner) },
    }))
    return path
end

local function bk(path, title, author, year)
    return {
        path = path,
        title = title,
        authors = author and { author } or nil,
        year = year,
    }
end

local function titles(books)
    local out = {}
    for i, b in ipairs(books) do out[i] = b.title end
    return out
end

describe("Author, then year", function()
    it("orders by the first author, then the year, oldest first", function()
        local books = {
            bk("p-citrus", "Citrus", "Ann", nil),
            bk("p-banana", "Banana", "Ann", 2010),
            bk("p-date", "Date", "Ann", 1990),
            bk("p-apple", "Apple", "Ann", 1990),
            bk("p-zebra", "Zebra", nil, 1800),
            bk("p-zoe", "Yarn", "Zoe", 2020),
            bk("p-same-b", "Apple", "Ann", 1990),
        }
        books[#books].path = "p-same-b"
        -- two "Apple" / 1990: the path decides. p-apple < p-same-b.
        same(titles(Core.sortBooks(books, "author_year")), {
            "Apple", "Apple", "Date", "Banana", "Citrus", "Yarn", "Zebra",
        })
        local sorted = Core.sortBooks(books, "author_year")
        eq(sorted[1].path, "p-apple")
        eq(sorted[2].path, "p-same-b")
        eq(sorted[#sorted].title, "Zebra")
    end)

    it("uses the first author only, and the same collator as Author", function()
        local books = {
            bk("a", "Early", "Zoe", 1900),
            bk("b", "Late", "Ann", 2020),
            { path = "c", title = "Co", authors = { "Zoe", "Ann" }, year = 1800 },
        }
        -- Ann first. Both Zoe books follow, oldest year first (Co is 1800, Early is 1900).
        same(titles(Core.sortBooks(books, "author_year")), { "Late", "Co", "Early" })
        -- A collator that sorts Z before A, the same hook the Author sort uses.
        local reversed = Core.sortBooks(books, "author_year", function(a, b) return a > b end)
        eq(reversed[1].authors[1], "Zoe")
        eq(reversed[#reversed].authors[1], "Ann")
    end)

    it("does not crash on a missing or malformed year", function()
        local books = {
            { path = "a", title = "A", authors = { "Ann" }, year = "nope" },
            { path = "b", title = "B", authors = { "Ann" }, year = {} },
            { path = "c", title = "C", authors = { "Ann" }, year = 0 / 0 },
            { path = "d", title = "D", authors = { "Ann" }, year = false },
            { path = "e", title = "E", authors = { "Ann" } },
        }
        same(titles(Core.sortBooks(books, "author_year")), { "A", "B", "C", "D", "E" })
    end)

    it("shows the year on a row that shows a sort date", function()
        eq(Core.sortDate({ year = 2003 }, "author_year"), "2003")
        eq(Core.sortDate({ year = false }, "author_year"), nil)
        eq(Core.sortDate({ year = "0101-01-01" }, "author_year"), nil)
        eq(Core.sortDate({}, "author"), nil)
    end)
end)

describe("publication year parsing", function()
    it("reads a 4-digit year and ignores Calibre's undefined date", function()
        eq(Core.publicationYear("2003"), 2003)
        eq(Core.publicationYear("2003-05-01"), 2003)
        eq(Core.publicationYear("2003-05-01T00:00:00+00:00"), 2003)
        eq(Core.publicationYear("  1999-12-31T23:59:59Z"), 1999)
        eq(Core.publicationYear(2003), 2003)
        eq(Core.publicationYear("0101-01-01"), nil)
        eq(Core.publicationYear("0101-01-01T00:00:00+00:00"), nil)
        eq(Core.publicationYear("0101"), nil)
        eq(Core.publicationYear("yesterday"), nil)
        eq(Core.publicationYear(""), nil)
        eq(Core.publicationYear(nil), nil)
        eq(Core.publicationYear({}), nil)
        eq(Core.publicationYear(true), nil)
        eq(Core.publicationYear(2003.5), nil)
        eq(Core.publicationYear(99), nil)
        eq(Core.publicationYear(0 / 0), nil)
        eq(Core.publicationYear("200"), nil)
        eq(Core.publicationYear("May 2003"), nil)
    end)

    it("reads dc:date variants from an OPF", function()
        local function year(inner)
            return Core.yearFromOpf(opf(inner))
        end
        eq(year("<dc:date>2003</dc:date>"), 2003)
        eq(year("<dc:date>2003-05-01</dc:date>"), 2003)
        eq(year("<dc:date>2003-05-01T00:00:00+00:00</dc:date>"), 2003)
        eq(year("<dc:date>\n  2003-05-01\n</dc:date>"), 2003)
        eq(year("<dc:date><![CDATA[2003-05-01]]></dc:date>"), 2003)
        eq(year('<dc:date opf:event="publication">1991</dc:date>'
            .. '<dc:date opf:event="modification">2020-01-01</dc:date>'), 1991)
        eq(year('<dc:date opf:event="modification">2020-01-01</dc:date>'
            .. '<dc:date opf:event="publication">1991</dc:date>'), 1991)
        eq(year("<dc:date>0101-01-01T00:00:00+00:00</dc:date><dc:date>2004</dc:date>"), 2004)
        eq(year("<dc:date>0101-01-01T00:00:00+00:00</dc:date>"), nil)
        eq(year("<dc:date>not-a-date</dc:date>"), nil)
        eq(year("<dc:date>"), nil)
        eq(Core.yearFromOpf(nil), nil)
        eq(Core.yearFromOpf(123), nil)
        eq(Core.yearFromOpf("<dc:date>2003"), nil)
        eq(year('<meta property="dcterms:issued">1988-04-02</meta>'), 1988)
        eq(year('<meta property="dcterms:modified">2020-01-01</meta>'), nil)
    end)

    it("takes the year from Calibre pubdate, then KOReader metadata", function()
        local map = Core.calibreIndex({
            { lpath = "a.epub", title = "A", pubdate = "2003-05-01T00:00:00+00:00" },
            { lpath = "b.epub", title = "B", pubdate = "0101-01-01T00:00:00+00:00" },
            { lpath = "c.epub", title = "C", pubdate = "not a date" },
            { lpath = "d.epub", title = "D" },
            { lpath = "e.epub", title = "E", pubdate = "2003" },
        }, "/mnt/us")
        eq(map["/mnt/us/a.epub"].year, 2003)
        eq(map["/mnt/us/b.epub"].year, nil)
        eq(map["/mnt/us/c.epub"].year, nil)
        eq(map["/mnt/us/d.epub"].year, nil)
        eq(map["/mnt/us/e.epub"].year, 2003)
        local book = { name = "a.epub" }
        Core.applyProps(book, map["/mnt/us/a.epub"])
        eq(book.year, 2003)
        Core.applyProps(book, { title = "From KOReader", date = "1984-06-08" })
        eq(book.year, 1984)
        eq(book.title, "From KOReader")
        Core.applyProps(book, { title = "No date", date = {} })
        eq(book.year, nil)
        Core.applyProps(book, { title = "Year field", year = 1971, date = "1999" })
        eq(book.year, 1971)
    end)

    it("reads the year from an EPUB OPF and ignores everything else", function()
        local path = epubWith("<dc:date>2003-05-01T00:00:00+00:00</dc:date>")
        eq(Core.epubPublicationYear(path), 2003)
        eq(Core.epubPublicationYear(path, { budget = 0, clock = function() return 1 end }), nil)
        os.remove(path)

        local bare = os.tmpname() .. ".epub"
        writeBytes(bare, "this is not a zip")
        eq(Core.epubPublicationYear(bare), nil)
        os.remove(bare)

        local empty = os.tmpname() .. ".epub"
        writeBytes(empty, "")
        eq(Core.epubPublicationYear(empty), nil)
        os.remove(empty)

        local pdf = os.tmpname() .. ".pdf"
        writeBytes(pdf, opf("<dc:date>2003</dc:date>"))
        eq(Core.epubPublicationYear(pdf), nil)
        os.remove(pdf)

        local bomb = os.tmpname() .. ".epub"
        writeBytes(bomb, zipOf({
            { name = "META-INF/container.xml", data = CONTAINER },
            { name = "OEBPS/book.opf", data = "x", method = 8, usize = 400000000 },
        }))
        eq(Core.epubPublicationYear(bomb), nil)
        os.remove(bomb)

        local slipped = os.tmpname() .. ".epub"
        writeBytes(slipped, zipOf({
            { name = "META-INF/container.xml", data = CONTAINER:gsub("OEBPS/book.opf", "../book.opf") },
            { name = "../book.opf", data = opf("<dc:date>2003</dc:date>") },
            { name = "OEBPS/real.opf", data = opf("<dc:date>1888</dc:date>") },
        }))
        eq(Core.epubPublicationYear(slipped), 1888)
        os.remove(slipped)
    end)

    it("inflates a deflated OPF when zlib is available", function()
        -- Raw deflate (windowBits -15) of `known`, the same inflate the updater uses.
        -- Without zlib the stored-zip tests above still cover the reader.
        local compressed = ""
        local hex = "458d410ec2201045afd2b02fc3acb4643a3d0b8149350225301a8f6f171a773f"
            .. "efbde4d3f62e797a491ff7a3ae06ad331b530bf11176994e57874f713537d5e601"
            .. "dab3677bf41d5204c952a4ea00b40886a98886143430a5e8cf218ccb729ddd6576"
            .. "48f06304ff0ebe3ffc01"
        local Update = require("libraryupdate")
        local known = "<?xml version=\"1.0\"?><package xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><metadata><dc:date>1998-07-01</dc:date></metadata></package>"
        for i = 1, #hex, 2 do
            compressed = compressed .. string.char(tonumber(hex:sub(i, i + 1), 16))
        end
        local out = Update.inflateRaw(compressed, #known)
        if type(out) ~= "string" then return end
        eq(out, known)
        local path = os.tmpname() .. ".epub"
        writeBytes(path, zipOf({
            { name = "mimetype", data = "application/epub+zip" },
            { name = "OEBPS/content.opf", data = compressed, method = 8, usize = #known },
        }))
        eq(Core.epubPublicationYear(path), 1998)
        os.remove(path)
    end)
end)

describe("year on the index", function()
    it("prefers Calibre, then KOReader metadata, then the EPUB", function()
        local path = epubWith("<dc:date>2003</dc:date>")
        local idx = Index.new({
            fs = { attributes = function() return nil end },
            bim = { getBookInfo = function() return { title = "From BIM", authors = "Ann", date = "1984-06-08" } end },
        })
        local book = { path = path, name = "book.epub", ext = "epub" }
        idx:fillMeta(book, {}, "s", nil)
        eq(book.title, "From BIM")
        eq(book.year, 1984)

        local dir = path:match("^(.*)/")
        local base = path:match("([^/]+)$")
        local calibre = Core.calibreIndex({
            { lpath = base, title = "From Calibre", authors = { "Ann" }, pubdate = "1962-03-04" },
        }, dir)
        book = { path = path, name = base, ext = "epub" }
        idx:fillMeta(book, calibre, "s", { doc_props = { date = "1999" } })
        eq(book.year, 1962)
        eq(book.title, "From Calibre")

        calibre = Core.calibreIndex({
            { lpath = base, title = "Placeholder", authors = { "Ann" }, pubdate = "0101-01-01T00:00:00+00:00" },
        }, dir)
        idx.opts.bim = nil
        book = { path = path, name = base, ext = "epub" }
        idx:fillMeta(book, calibre, "s", { doc_props = { title = "Side", date = "1977-01-02" } })
        eq(book.year, 1977)

        book = { path = path, name = base, ext = "epub", year = false }
        idx:fillMeta(book, {}, "s", nil)
        eq(book.year, false, "a checked file with no year is not opened again")
        os.remove(path)
    end)

    it("fills a year missing from an older cache, then keeps it", function()
        local root = os.tmpname()
        os.remove(root)
        assert(os.execute("mkdir -p '" .. root:gsub("'", "'\\''") .. "'"))
        local path = root .. "/Book.epub"
        writeBytes(path, zipOf({
            { name = "META-INF/container.xml", data = CONTAINER },
            { name = "OEBPS/book.opf", data = opf("<dc:date>2003-05-01</dc:date>") },
        }))
        local cache = os.tmpname()
        local fs = {
            dir = function(dir)
                if dir ~= root then return function() return nil end end
                local sent = false
                return function()
                    if sent then return nil end
                    sent = true
                    return "Book.epub"
                end
            end,
            attributes = function(p)
                if p == root then return { mode = "directory", size = 0, modification = 1 } end
                if p == path then return { mode = "file", size = 10, modification = 5 } end
                return nil
            end,
        }
        local function newIndex()
            return Index.new({
                root = root, fs = fs, cache_file = cache,
                is_book = function(p) return p:lower():match("%.epub$") ~= nil end,
                bim = { getBookInfo = function() return { title = "Cached", authors = "Ann" } end },
            })
        end
        writeBytes(cache, Core.serialize({
            version = Core.CACHE_VERSION,
            root = root,
            entries = {
                [path] = {
                    size = 10, modification = 5, title = "Cached",
                    authors = { "Ann" }, src = "bim", cal = "",
                    sc_mtime = false, status = "new",
                },
            },
        }))
        local first = newIndex()
        local books = first:build()
        eq(first.stats.cached, 1)
        eq(first.stats.refreshed, 0)
        eq(books[1].title, "Cached")
        eq(books[1].year, 2003)
        os.remove(path)
        local second = newIndex()
        books = second:build()
        eq(books[1].year, 2003, "the cached year stands when the file is not re-read")
        eq(second.stats.refreshed, 0)
        os.remove(cache)
        os.execute("rmdir '" .. root:gsub("'", "'\\''") .. "'")
    end)

    it("remembers the year on a reconciled cache entry", function()
        local reused = Core.reconcile(
            { { path = "/x", size = 1, modification = 1, ext = "epub" } },
            { ["/x"] = { size = 1, modification = 1, title = "X", src = "bim", cal = "s", year = 2001, status = "new" } },
            "s")
        eq(reused[1].year, 2001)
        local again = Core.reconcile(
            { { path = "/x", size = 1, modification = 1 } },
            { ["/x"] = { size = 1, modification = 1, title = "X", src = "bim", cal = "s", year = false, status = "new" } },
            "s")
        eq(again[1].year, false)
        local old = Core.reconcile(
            { { path = "/x", size = 1, modification = 1 } },
            { ["/x"] = { size = 1, modification = 1, title = "X", src = "bim", cal = "s", status = "new" } },
            "s")
        eq(old[1].year, nil)
    end)
end)

describe("Author, then year in the menus and per-shelf memory", function()
    it("accepts the sort in per-shelf memory and rejects an unknown one", function()
        local s = {}
        eq(Core.rememberViewPref(s, "series:Oz", "sort", "author_year", 10), true)
        eq(s.view_memory["series:Oz"].sort, "author_year")
        eq(Core.viewPrefs(s, "series:Oz").sort, "author_year")
        local books = { view = "grid", sort = "author_year" }
        eq(Core.defaultPrefs(books).sort, "author_year")
        eq(Core.rememberViewPref({}, "k", "sort", "not-a-sort"), false)
        eq(Core.viewPrefs({ view = "grid", sort = "nope" }, "books").sort, "recent")
    end)

    it("is on the footer picker and the library menu, just after Author", function()
        local function stub()
            return setmetatable({}, {
                __index = function() return stub() end,
                __call = function() return stub() end,
            })
        end
        local function load(file, extra)
            local old_require = require
            local real = { librarycore = true, libraryindex = true, libraryyear = true, string = true, table = true, math = true }
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
        local function cls()
            local base = {}
            base.__index = base
            function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
            function base:new(o) o = o or {}; return setmetatable(o, self) end
            return base
        end
        local shown = {}
        local Library = load("main.lua", {
            ["ui/widget/buttondialog"] = { new = function(_, o) return o end },
            ["ui/widget/container/widgetcontainer"] = cls(),
        })
        local resorted = {}
        local view = {
            sort = "author",
            view_mode = "grid",
            placeName = function() return "Books" end,
            viewKey = function() return "books" end,
            hasRemembered = function() return false end,
            resort = function(_, mode) resorted[#resorted + 1] = mode end,
        }
        local self = setmetatable({
            settings = { columns = 4 },
            saveSettings = function() end,
            closeOverLibrary = function() end,
            showOverLibrary = function(_, w) shown[#shown + 1] = w end,
        }, { __index = Library })
        local picker = Library.showSortPicker(self, view)
        eq(picker.buttons[1][1].text, "\u{2713} Author")
        eq(picker.buttons[2][1].text, "Author, then year")
        picker.buttons[2][1].callback()
        same(resorted, { "author_year" })

        Library.showLibraryMenu(self, view)
        local menu = shown[#shown]
        local row = {}
        for i, button in ipairs(menu.buttons[1]) do row[i] = button.text end
        same(row, { "\u{2713} Author", "Author, then year", "Title", "Date added", "Last read", "Series" })
        menu.buttons[1][2].callback()
        same(resorted, { "author_year", "author_year" })
    end)

    it("shows the A–Z strip for it, keyed like Author", function()
        eq(Core.scrubberMode{ kind = "books", sort = "author_year" }, "author")
        eq(Core.scrubberMode{ kind = "books", sort = "author_year", view = "compact" }, "author")
        eq(Core.scrubberMode{ kind = "books", sort = "author_year", view = "list" }, "author")
        eq(Core.scrubberMode{ kind = "books", sort = "author_year", in_series = true }, nil)
        eq(Core.scrubberMode{ kind = "books", sort = "author_year", view = "compact2" }, nil)
        eq(Core.scrubberItemKey({ authors = { "Frank Herbert", "Other" } }, "author"), "Frank Herbert")
    end)
end)
