-- What counts as a book: KOReader's DocumentRegistry opens scripts and config
-- files as plain text (crengine registers .sh, .lua, ...), so KOReader.sh used
-- to show up as a book. These specs pin the book-format allowlist and the
-- skipped KOReader folders.
local Core = require("librarycore")
local Index = require("libraryindex")

-- A Kindle-like tree: books, KOReader.sh in the root, the koreader/ install folder.
local ROOT = "/mnt/us"
local tree = {
    [ROOT] = { mode = "directory", children = {
        "KOReader.sh", "koreader", "documents", "extensions", "update.sh", "notes.txt", "Emma.epub",
    } },
    [ROOT .. "/KOReader.sh"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/update.sh"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/notes.txt"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/Emma.epub"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/koreader"] = { mode = "directory", children = { "KOReader.sh", "reader.lua", "help", "settings" } },
    [ROOT .. "/koreader/KOReader.sh"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/koreader/reader.lua"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/koreader/help"] = { mode = "directory", children = { "quickstart.epub" } },
    [ROOT .. "/koreader/help/quickstart.epub"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/koreader/settings"] = { mode = "directory", children = { "history.lua" } },
    [ROOT .. "/koreader/settings/history.lua"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/extensions"] = { mode = "directory", children = { "kual.sh", "data" } },
    [ROOT .. "/extensions/kual.sh"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/extensions/data"] = { mode = "directory", children = { "x.epub" } },
    [ROOT .. "/extensions/data/x.epub"] = { mode = "file", size = 9, modification = 1 },
    [ROOT .. "/documents"] = { mode = "directory", children = {
        "Persuasion.AZW3", "Dune.mobi", "Comic.cbz", "Old.fb2.zip", "Map.djvu", "run.py", "config.json",
        "plugin.lua", "app.js", "x.ini", "crash.log", "Archive.zip", "cover.jpg", "Story.txt", "Moby.pdf",
    } },
}
for _, n in ipairs(tree[ROOT .. "/documents"].children) do
    tree[ROOT .. "/documents/" .. n] = { mode = "file", size = 9, modification = 1 }
end
local fs = {
    dir = function(path)
        local node = tree[path]
        if not node or node.mode ~= "directory" then error("cannot open " .. path) end
        local i = 0
        return function() i = i + 1; return node.children[i] end
    end,
    attributes = function(path, field)
        local n = tree[path]
        local a = n and { mode = n.mode, size = n.size, modification = n.modification }
        if field then return a and a[field] end
        return a
    end,
}

-- Like KOReader's DocumentRegistry:hasProvider: crengine claims scripts and config too.
local KO_PROVIDER = {
    epub = true, pdf = true, mobi = true, azw3 = true, fb2 = true, zip = true, cbz = true,
    djvu = true, txt = true, sh = true, lua = true, py = true, js = true, json = true,
    ini = true, log = true,
}
local function hasProvider(path)
    return KO_PROVIDER[Core.extension(path)] == true
end

local function names(books)
    local out = {}
    for i, b in ipairs(books) do out[i] = b.path:sub(#ROOT + 2) end
    table.sort(out)
    return out
end

describe("book formats", function()
    it("accepts real book formats, any case", function()
        for _, n in ipairs({ "a.epub", "a.PDF", "a.mobi", "a.azw3", "a.azw", "a.prc", "a.fb2", "a.fb2.zip",
                             "a.FB2.ZIP", "a.cbz", "a.cbr", "a.cb7", "a.djvu", "a.djv", "a.xps", "a.chm",
                             "a.docx", "a.rtf", "a.odt", "a.txt", "/x/y/Moby Dick.Epub" }) do
            eq(Core.isBookName(n), true, n)
        end
    end)
    it("rejects scripts and config files", function()
        for _, n in ipairs({ "KOReader.sh", "/mnt/us/koreader/KOReader.sh", "UPDATE.SH", "reader.lua", "x.py",
                             "x.js", "x.json", "x.ini", "crash.log", "a.epub.sh" }) do
            eq(Core.isBookName(n), false, n)
        end
    end)
    it("rejects other non-books and odd input", function()
        for _, n in ipairs({ "Archive.zip", "cover.jpg", "README", "", ".epub.d/x", "epub" }) do
            eq(Core.isBookName(n), false, n)
        end
        eq(Core.isBookName(nil), false)
    end)
    it("still needs KOReader to be able to open it", function()
        local is_book = Core.makeIsBook(hasProvider)
        eq(is_book("/a/KOReader.sh"), false)  -- provider says yes, allowlist says no
        eq(is_book("/a/Book.epub"), true)
        eq(is_book("/a/Book.chm"), false)     -- allowlisted, but no provider here
        eq(Core.makeIsBook(function() error("boom") end)("/a/b.epub"), false)
        eq(Core.makeIsBook()("/a/b.epub"), true)
    end)
end)

describe("scan exclusions", function()
    local is_book = Core.makeIsBook(hasProvider)
    it("skips KOReader.sh, other scripts and the koreader/ install folder", function()
        local books = Core.scan(ROOT, fs, is_book, { skip_dirs = { ROOT .. "/extensions/" } })
        same(names(books), {
            "Emma.epub", "documents/Comic.cbz", "documents/Dune.mobi", "documents/Map.djvu",
            "documents/Moby.pdf", "documents/Old.fb2.zip", "documents/Persuasion.AZW3",
            "documents/Story.txt", "notes.txt",
        })
    end)
    it("only skips listed folders, and indexes books elsewhere", function()
        local books = Core.scan(ROOT, fs, is_book)
        local n = names(books)
        eq(#n, 10)
        eq(n[1], "Emma.epub"); eq(n[10], "notes.txt")
        local has_x = false
        for _, p in ipairs(n) do if p == "extensions/data/x.epub" then has_x = true end end
        eq(has_x, true)
    end)
    it("skips the koreader folder when it is the data dir passed in skip_dirs", function()
        local books = Core.scan(ROOT .. "/koreader", fs, is_book, { skip_dirs = { ROOT .. "/koreader/settings" } })
        same(names(books), { "koreader/help/quickstart.epub" }) -- the root itself is never skipped
    end)
    it("the old hasProvider-only check would have listed KOReader.sh", function()
        local books = Core.scan(ROOT, fs, hasProvider)
        local found = false
        for _, b in ipairs(books) do if b.name == "KOReader.sh" then found = true end end
        eq(found, true)
    end)
end)

describe("Index with the book allowlist", function()
    it("drops KOReader.sh cached by an older version and keeps real books", function()
        local cache = os.tmpname()
        local function idx(is_book)
            return Index.new{
                root = ROOT, fs = fs, is_book = is_book, cache_file = cache,
                skip_dirs = { ROOT .. "/extensions" },
                bim = false, calibre_load = false,
                docsettings = { findSidecarFile = function() return nil end },
                history = { hist = {} },
            }
        end
        local old = idx(hasProvider):build()
        local had = false
        for _, b in ipairs(old) do if b.name == "KOReader.sh" then had = true end end
        eq(had, true)
        local books = idx(Core.makeIsBook(hasProvider)):build()
        same(names(books), {
            "Emma.epub", "documents/Comic.cbz", "documents/Dune.mobi", "documents/Map.djvu",
            "documents/Moby.pdf", "documents/Old.fb2.zip", "documents/Persuasion.AZW3",
            "documents/Story.txt", "notes.txt",
        })
        for _, b in ipairs(books) do
            if b.path:find("/koreader/", 1, true) then error("indexed " .. b.path) end
        end
        eq(#Core.searchIndexed(books, "koreader"), 0)
        eq(#Core.searchIndexed(books, "persuasion"), 1)
        os.remove(cache)
    end)
end)
