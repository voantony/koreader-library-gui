-- Genres from Calibre's on-device catalogue (metadata.calibre): each entry's
-- tags, matched by lpath, merged with the book's own subjects (keywords that
-- KOReader cached). The file is read once per change (its mtime and size).
local Core = require("librarycore")
local Index = require("libraryindex")

-- A small JSON reader, enough for the fixture (KOReader uses rapidjson).
local function decodeJSON(s)
    local i = 1
    local function ws() i = s:find("[^%s]", i) or #s + 1 end
    local value
    local function str()
        local j, out = i + 1, {}
        while true do
            local c = s:sub(j, j)
            if c == '"' then break end
            if c == "\\" then j = j + 1; c = s:sub(j, j) end
            out[#out + 1] = c; j = j + 1
        end
        i = j + 1
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}; i = i + 1; ws()
            if s:sub(i, i) == "}" then i = i + 1; return t end
            while true do
                ws(); local k = str(); ws(); i = i + 1 -- ':'
                t[k] = value(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            local t = {}; i = i + 1; ws()
            if s:sub(i, i) == "]" then i = i + 1; return t end
            while true do
                t[#t + 1] = value(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "]" then return t end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
        elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
        else
            local n = s:match("^-?[%d.eE+-]+", i); i = i + #n; return tonumber(n)
        end
    end
    return value()
end

local function readFile(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
local FIXTURE = "spec/fixtures/genres.metadata.calibre"

local ROOT = "/mnt/us/documents"
local tree = {
    [ROOT] = { mode = "directory", children = { "Agatha Christie", "H. G. Wells", "John Buchan", "Homer" } },
    [ROOT .. "/Agatha Christie"] = { mode = "directory", children = { "The Mysterious Affair at Styles.epub" } },
    [ROOT .. "/Agatha Christie/The Mysterious Affair at Styles.epub"] = { mode = "file", size = 300000, modification = 10 },
    [ROOT .. "/H. G. Wells"] = { mode = "directory", children = { "The Time Machine.epub" } },
    [ROOT .. "/H. G. Wells/The Time Machine.epub"] = { mode = "file", size = 200000, modification = 11 },
    [ROOT .. "/John Buchan"] = { mode = "directory", children = { "The Thirty-Nine Steps.epub" } },
    [ROOT .. "/John Buchan/The Thirty-Nine Steps.epub"] = { mode = "file", size = 100000, modification = 12 },
    [ROOT .. "/Homer"] = { mode = "directory", children = { "The Odyssey.epub" } },
    [ROOT .. "/Homer/The Odyssey.epub"] = { mode = "file", size = 400000, modification = 13 },
    ["/mnt/us/metadata.calibre"] = { mode = "file", size = 900, modification = 100 },
}
local fs = {
    dir = function(path)
        local node = tree[path]; local i = 0
        return function() i = i + 1; return node.children[i] end
    end,
    attributes = function(path, field)
        local n = tree[path]
        local a = n and { mode = n.mode, size = n.size, modification = n.modification }
        if field then return a and a[field] end
        return a
    end,
}
-- KOReader's own cached subjects (BookInfoManager keywords) for two books
local bim = { getBookInfo = function(_, path)
    if path:find("Time Machine") then return { title = "The Time Machine", authors = "H. G. Wells", keywords = "Science Fiction\nTime travel" } end
    if path:find("Odyssey") then return { title = "The Odyssey", authors = "Homer", keywords = "Poetry; Classics" } end
end }

local loads
local CACHE = os.tmpname()
local function newIndex()
    return Index.new{
        root = ROOT, fs = fs, cache_file = CACHE, bim = bim,
        is_book = function(p) return p:match("%.epub$") ~= nil end,
        calibre_load = function(path)
            loads[#loads + 1] = path
            return decodeJSON(readFile(FIXTURE))
        end,
    }
end
local function byTitle(books) local m = {}; for _, b in ipairs(books) do m[b.title] = b end; return m end
local function names(groups)
    local t = {}
    for i, g in ipairs(groups) do t[i] = g.name .. "(" .. #g.books .. ")" end
    return table.concat(t, ", ")
end

describe("Genres from metadata.calibre", function()
    it("reads the fixture like rapidjson would", function()
        local entries = decodeJSON(readFile(FIXTURE))
        eq(#entries, 3)
        same(entries[1].tags, { "Mystery & Thriller", "Classics" })
    end)

    it("matches entries by lpath and merges tags with the book's own subjects", function()
        os.remove(CACHE); loads = {}
        local books = byTitle(newIndex():build())
        eq(#loads, 1); eq(loads[1], "/mnt/us/metadata.calibre") -- the folder above documents/
        same(Core.splitKeywords(books["The Mysterious Affair at Styles"].keywords), { "Mystery & Thriller", "Classics" })
        -- calibre tags first, then subjects not already there (case-insensitive)
        same(Core.splitKeywords(books["The Time Machine"].keywords), { "Science Fiction", "classics", "Time travel" })
        eq(books["The Thirty-Nine Steps"].keywords, nil) -- no tags, no subjects
        same(Core.splitKeywords(books["The Odyssey"].keywords), { "Poetry", "Classics" }) -- not in calibre
        local all = {}
        for _, b in pairs(books) do all[#all + 1] = b end
        table.sort(all, function(a, b) return a.title < b.title end)
        eq(names(Core.genreGroups(all, nil, nil, "Unsorted")),
            "Classics(3), Mystery & Thriller(1), Poetry(1), Science Fiction(1), Time travel(1), Unsorted(1)")
    end)

    it("is parsed once: the next start reuses the cache until the file changes", function()
        os.remove(CACHE); loads = {}
        newIndex():build()
        eq(#loads, 1)
        local again = byTitle(newIndex():build())
        eq(#loads, 1, "unchanged metadata.calibre: not read again")
        same(Core.splitKeywords(again["The Mysterious Affair at Styles"].keywords), { "Mystery & Thriller", "Classics" })
        tree["/mnt/us/metadata.calibre"].modification = 200 -- calibre wrote it again
        newIndex():build()
        eq(#loads, 2)
        tree["/mnt/us/metadata.calibre"].modification = 100
        os.remove(CACHE)
    end)
end)

describe("Core.mergeKeywords", function()
    it("unions without repeats and keeps & names whole", function()
        eq(Core.mergeKeywords("Military & War\nHistory", "history; Politics"), "Military & War\nHistory\nPolitics")
        eq(Core.mergeKeywords(nil, ""), nil)
        eq(Core.mergeKeywords(nil, "Essays"), "Essays")
    end)
end)
