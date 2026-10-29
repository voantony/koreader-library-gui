-- Dummy, in-memory library used by the unit tests.
-- Titles are public-domain classics; no file here comes from a real device.
local M = {}

M.root = "/mnt/test/books"

-- path -> attributes. Directories list their children in `children`.
M.tree = {
    ["/mnt/test/books"] = { mode = "directory", children = {
        "Classics", "Sci-Fi", ".hidden", "notes.txt", "Pride and Prejudice.epub", "cover.jpg",
    } },
    ["/mnt/test/books/Pride and Prejudice.epub"] = { mode = "file", size = 500000, modification = 1000 },
    ["/mnt/test/books/notes.txt"] = { mode = "file", size = 10, modification = 1 },
    ["/mnt/test/books/cover.jpg"] = { mode = "file", size = 2000, modification = 1 },
    ["/mnt/test/books/.hidden"] = { mode = "directory", children = { "secret.epub" } },
    ["/mnt/test/books/.hidden/secret.epub"] = { mode = "file", size = 1, modification = 1 },
    ["/mnt/test/books/Classics"] = { mode = "directory", children = {
        "Emma.EPUB", "Moby Dick.pdf", "Moby Dick.sdr", "Deep",
    } },
    ["/mnt/test/books/Classics/Emma.EPUB"] = { mode = "file", size = 400000, modification = 3000 },
    ["/mnt/test/books/Classics/Moby Dick.pdf"] = { mode = "file", size = 9000000, modification = 2000 },
    ["/mnt/test/books/Classics/Moby Dick.sdr"] = { mode = "directory", children = { "metadata.pdf.lua" } },
    ["/mnt/test/books/Classics/Moby Dick.sdr/metadata.pdf.lua"] = { mode = "file", size = 100, modification = 1 },
    ["/mnt/test/books/Classics/Deep"] = { mode = "directory", children = { "Deeper" } },
    ["/mnt/test/books/Classics/Deep/Deeper"] = { mode = "directory", children = { "Persuasion.mobi" } },
    ["/mnt/test/books/Classics/Deep/Deeper/Persuasion.mobi"] = { mode = "file", size = 300000, modification = 500 },
    ["/mnt/test/books/Sci-Fi"] = { mode = "directory", children = {
        "The Time Machine.epub", "The War of the Worlds.epub", "Frankenstein.fb2",
    } },
    ["/mnt/test/books/Sci-Fi/The Time Machine.epub"] = { mode = "file", size = 200000, modification = 4000 },
    ["/mnt/test/books/Sci-Fi/The War of the Worlds.epub"] = { mode = "file", size = 250000, modification = 4500 },
    ["/mnt/test/books/Sci-Fi/Frankenstein.fb2"] = { mode = "file", size = 350000, modification = 100 },
}

-- LuaFileSystem-shaped fake.
M.fs = {
    dir = function(path)
        local node = M.tree[path]
        if not node or node.mode ~= "directory" then
            error("cannot open " .. path)
        end
        local i = 0
        return function()
            i = i + 1
            return node.children[i]
        end
    end,
    attributes = function(path)
        local node = M.tree[path]
        if not node then return nil end
        return { mode = node.mode, size = node.size, modification = node.modification }
    end,
}

local BOOK_EXTS = { epub = true, pdf = true, mobi = true, fb2 = true }

function M.is_book(path)
    local ext = path:match("%.([^./]+)$")
    return ext ~= nil and BOOK_EXTS[ext:lower()] == true
end

-- Metadata as KOReader's BookInfo would report it (doc_props shape).
M.props = {
    ["/mnt/test/books/Pride and Prejudice.epub"] = {
        title = "Pride and Prejudice", authors = "Jane Austen", keywords = "romance\nclassic",
    },
    ["/mnt/test/books/Classics/Emma.EPUB"] = { title = "Emma", authors = "Jane Austen" },
    ["/mnt/test/books/Classics/Moby Dick.pdf"] = { title = "  ", authors = nil }, -- empty metadata
    ["/mnt/test/books/Classics/Deep/Deeper/Persuasion.mobi"] = { title = "Persuasion", authors = "Jane Austen" },
    ["/mnt/test/books/Sci-Fi/The Time Machine.epub"] = {
        title = "The Time Machine", authors = "H. G. Wells", series = "Wells Classics", series_index = "1",
    },
    ["/mnt/test/books/Sci-Fi/The War of the Worlds.epub"] = {
        title = "The War of the Worlds", authors = "H. G. Wells", series = "Wells Classics", series_index = 2,
    },
    ["/mnt/test/books/Sci-Fi/Frankenstein.fb2"] = {
        title = "Frankenstein", authors = "Mary Shelley\nPercy Bysshe Shelley",
    },
}

M.status = {
    ["/mnt/test/books/Pride and Prejudice.epub"] = "complete",
    ["/mnt/test/books/Classics/Emma.EPUB"] = "reading",
    ["/mnt/test/books/Sci-Fi/The Time Machine.epub"] = "abandoned",
    ["/mnt/test/books/Sci-Fi/Frankenstein.fb2"] = "something-unexpected",
}

function M.get_props(path) return M.props[path] end
function M.get_status(path) return M.status[path] or "new" end

return M
