-- Index a synthetic library of a few thousand books and print how long it takes.
-- Run from the repository root: luajit bench/index_bench.lua [books]
--
-- The tree is in memory (no disk). It includes a symlink of one book, a
-- notes.txt in every shelf, and dev folders (node_modules, .git, build) that
-- must not be opened. The second pass is the warm refresh the Library does
-- each time it is opened.
package.path = "./library.koplugin/?.lua;" .. package.path
local Core = require("librarycore")
local Index = require("libraryindex")

local N = tonumber(arg and arg[1]) or 5000
local per = 100
local shelves = math.ceil(N / per)
local root = "/mnt/us/documents"
local tree = { [root] = { mode = "directory", children = {}, dev = 1, ino = 1 } }

local function addDir(path, children, ino)
    tree[path] = { mode = "directory", children = children, dev = 1, ino = ino }
end

local made = 0
for d = 1, shelves do
    local shelf = string.format("shelf%02d", d)
    local dir = root .. "/" .. shelf
    local kids = {}
    tree[root].children[#tree[root].children + 1] = shelf
    local count = math.min(per, N - made)
    for i = 1, count do
        local name = string.format("S%02d Book %03d.epub", d, i)
        kids[#kids + 1] = name
        tree[dir .. "/" .. name] = {
            mode = "file", size = 1000 + i, modification = i, dev = 1, ino = d * 1000 + i,
        }
        made = made + 1
    end
    kids[#kids + 1] = "notes.txt"
    tree[dir .. "/notes.txt"] = { mode = "file", size = 20, modification = 1, dev = 1, ino = 900000 + d }
    kids[#kids + 1] = "The AWK Programming Language.pdf"
    tree[dir .. "/The AWK Programming Language.pdf"] = {
        mode = "file", size = 2000, modification = 2, dev = 1, ino = 800000 + d,
    }
    addDir(dir, kids, 700000 + d)
end
-- same file as the first book, via a second name
tree[root].children[#tree[root].children + 1] = "S01 Book 001-link.epub"
tree[root .. "/S01 Book 001-link.epub"] = {
    mode = "file", size = 1001, modification = 1, dev = 1, ino = 1001, symlink = true,
}
for _, name in ipairs({ "node_modules", ".git", "build", "venv", "__pycache__", "system", "Android" }) do
    tree[root].children[#tree[root].children + 1] = name
    local dir = root .. "/" .. name
    tree[dir] = { mode = "directory", children = { "Secret.epub" }, dev = 4, ino = 400000 }
    tree[dir .. "/Secret.epub"] = { mode = "file", size = 8, modification = 1, dev = 4, ino = 400001 }
end

local opened = {}
local fs = {
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
            dev = node.dev, ino = node.ino, symlink = node.symlink,
        }
        if field then return a[field] end
        return a
    end,
}

local idx = Index.new{
    root = root, fs = fs, is_book = Core.makeIsBook(), merge_copies = true,
    bim = {
        getBookInfo = function(_, path)
            local base = path:match("([^/]+)$") or path
            local title = Core.stem(base)
            -- every shelf's PDF is the same work, so they become one tile
            if title == "The AWK Programming Language" then
                return { title = title, authors = "Alfred V. Aho\nBrian W. Kernighan\nPeter J. Weinberger" }
            end
            return { title = title, authors = "Bench Author" }
        end,
    },
    docsettings = { findSidecarFile = function() return nil end },
    history = { hist = {
        { file = root .. "/shelf01/The AWK Programming Language.pdf", time = 500 },
    } },
    calibre_load = false,
}

local function pass(label)
    local t0 = os.clock()
    idx:build()
    local dt = os.clock() - t0
    local s = idx.stats
    print(string.format(
        "%-6s %7.1f ms   tiles %d   files %d   reused %d   refreshed %d   memory %s",
        label, dt * 1000, s.books, s.files, s.cached, s.refreshed, tostring(s.from_memory)))
    return dt
end

local cold = pass("cold")
local warm = pass("warm")
local walked_dev = opened[root .. "/node_modules"] or opened[root .. "/.git"] or opened[root .. "/build"]
if walked_dev then
    io.stderr:write("dev folder was opened\n")
    os.exit(1)
end
local pdfs = shelves
-- N epubs plus one PDF per shelf. The symlink is the same file as the first epub.
if idx.stats.files ~= N + pdfs then
    io.stderr:write(string.format("expected %d files, got %d\n", N + pdfs, idx.stats.files))
    os.exit(1)
end
local expect_tiles = N + 1 -- N unique epubs, and one tile for every AWK pdf
if idx.stats.books ~= expect_tiles then
    io.stderr:write(string.format("expected %d tiles, got %d (pdfs %d)\n", expect_tiles, idx.stats.books, pdfs))
    os.exit(1)
end
print(string.format("cold %.1f ms, warm %.1f ms, %d files, %d tiles",
    cold * 1000, warm * 1000, idx.stats.files, idx.stats.books))
