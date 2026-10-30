-- The search bar searches what the tab shows: books on Books (and inside a
-- shelf), author names on Authors, series names or their authors on Series,
-- collection names on Collections. Typos are forgiven everywhere. Also the
-- sort menu's order (Author, Title, Date added, Last read, then Series).
local Core = require("librarycore")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, string = true, table = true, math = true }
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

local function bk(title, author, series, extra)
    local b = { path = "/b/" .. title .. ".epub", name = title .. ".epub", title = title,
        authors = { author }, series = series, modification = 0, status = "new" }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end

local BOOKS = {
    bk("The Hobbit", "J. R. R. Tolkien"),
    bk("Guards! Guards!", "Terry Pratchett", "Discworld"),
    bk("Mort", "Terry Pratchett", "Discworld"),
    bk("Good Omens", "Neil Gaiman", "Discworld"), -- (not really; a second author)
    bk("Dune", "Frank Herbert", "Dune"),
    bk("Emma", "Jane Austen"),
}

local function names(list)
    local out = {}
    for i, g in ipairs(list) do out[i] = g.title or g.name end
    return table.concat(out, ",")
end

local function groupsOf(kind)
    local out = {}
    for _, g in ipairs(Core.group(BOOKS, kind == "authors" and "author" or "series")) do
        if g.key ~= Core.UNKNOWN then out[#out + 1] = { kind = kind, name = g.key, books = g.books } end
    end
    return out
end

describe("Core.searchScope", function()
    it("follows the tab; a shelf searches its books", function()
        eq(Core.searchScope("books"), "books")
        eq(Core.searchScope("authors"), "authors")
        eq(Core.searchScope("series"), "series")
        eq(Core.searchScope("collections"), "collections")
        eq(Core.searchScope("authors", { name = "Jane Austen" }), "books")
    end)
end)

describe("Core.searchGroups", function()
    it("Authors: matches author names, typos forgiven, not book titles", function()
        local g = groupsOf("authors")
        eq(names(Core.searchGroups(g, "tolkein", nil, true)), "J. R. R. Tolkien")
        eq(names(Core.searchGroups(g, "pratch", nil, true)), "Terry Pratchett")
        eq(names(Core.searchGroups(g, "hobbit", nil, true)), "", "titles are not searched here")
        eq(names(Core.searchGroups(g, "tolkein", nil, false)), "", "exact matching when typo-tolerance is off")
    end)

    it("Series: matches the series name or its authors", function()
        local g = groupsOf("series")
        eq(names(Core.searchGroups(g, "discwrld", nil, true)), "Discworld")
        eq(names(Core.searchGroups(g, "pratchet", nil, true)), "Discworld", "by author, with a typo")
        eq(names(Core.searchGroups(g, "gaiman", nil, true)), "Discworld", "any of its authors")
        eq(names(Core.searchGroups(g, "herbert", nil, true)), "Dune")
        eq(names(Core.searchGroups(g, "mort", nil, true)), "", "book titles are not searched here")
    end)

    it("Collections: matches collection names", function()
        local g = { { kind = "collections", name = "Favorites", books = { BOOKS[1] } },
                    { kind = "collections", name = "To read", books = { BOOKS[6] } } }
        eq(names(Core.searchGroups(g, "favorits", nil, true)), "Favorites")
        eq(names(Core.searchGroups(g, "tolkien", nil, true)), "")
    end)

    it("leaves the shelves themselves usable", function()
        local g = groupsOf("series")
        Core.searchGroups(g, "dune", nil, true)
        eq(g[1].name, "Discworld"); eq(#g[1].books, 3)
        same(g[1].authors, { "Terry Pratchett", "Neil Gaiman" })
    end)
end)

describe("series shelves show their authors", function()
    local Tiles = load("librarytile.lua", {})
    it("one or two authors, then +N; other shelves show the count", function()
        local g = groupsOf("series")
        eq(Tiles.groupSecondLine(g[1]), "Terry Pratchett, Neil Gaiman")
        eq(Tiles.groupSecondLine(g[2]), "Frank Herbert")
        local many = { kind = "series", name = "X", books = {
            bk("a", "A"), bk("b", "B"), bk("c", "C"), bk("d", "D") } }
        eq(Tiles.groupSecondLine(many), "A, B +2")
        eq(Tiles.groupSecondLine({ kind = "authors", name = "Jane Austen", books = { BOOKS[6] } }), "1 book")
        eq(Tiles.groupSecondLine({ kind = "series", name = "Y", books = { bk("z", nil), bk("w", nil) } }), "2 books")
    end)
end)

describe("LibraryView search scope", function()
    local View = load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = cls(),
        ["ui/uimanager"] = { unschedule = function() end, scheduleIn = function() end },
        util = { stringLower = function(s) return s:lower() end },
    })
    local function view(tab)
        local input = { text = "" }
        function input:setText(t) self.text = t end
        function input:getText() return self.text end
        local v = setmetatable({
            tab = tab, query = "", filter = "all", page = 1, sorted = BOOKS, all_books = BOOKS,
            groups_cache = {}, fuzzy_search = true, search_input = input,
            plugin = { collate = nil, getCollections = function() return {} end },
        }, { __index = View })
        v.keyboardGuard = function() end
        v.applyRemembered = function() end
        v.refreshBody = function() end
        return v
    end

    it("Books searches books; Authors and Series narrow their shelves", function()
        local v = view("books"); v.query = "tolkein"
        local d = v:currentItems()
        eq(d.kind, "books"); eq(names(d.items), "The Hobbit")
        v = view("authors"); v.query = "tolkein"
        d = v:currentItems()
        eq(d.kind, "groups"); eq(names(d.items), "J. R. R. Tolkien")
        v = view("series"); v.query = "pratchet"
        d = v:currentItems()
        eq(d.kind, "groups"); eq(names(d.items), "Discworld")
    end)

    it("inside a shelf, searches that shelf's books", function()
        local v = view("authors")
        v.group = { kind = "authors", name = "Terry Pratchett", books = { BOOKS[2], BOOKS[3] } }
        v.query = "mrot"
        eq(names(v:currentItems().items), "Mort")
    end)

    it("the placeholder names the scope", function()
        eq(view("books"):searchHint(), "Search title, author, series")
        eq(view("authors"):searchHint(), "Search authors\u{2026}")
        eq(view("series"):searchHint(), "Search series or authors\u{2026}")
        eq(view("collections"):searchHint(), "Search collections\u{2026}")
        local v = view("authors"); v.group = { name = "Jane Austen", books = {} }
        eq(v:searchHint(), "Search in Jane Austen\u{2026}")
    end)

    it("switching tabs clears the search; a shelf keeps the list's search for Back", function()
        local v = view("authors")
        v.query = "pratch"; v.search_input:setText("pratch")
        local g = v:currentItems().items[1]
        v:openGroup(g)
        eq(v.query, ""); eq(v.search_input:getText(), "")
        v:closeGroup()
        eq(v.query, "pratch", "back on Authors with the search as it was")
        eq(v.search_input:getText(), "pratch")
        v:setTab("series")
        eq(v.query, ""); eq(v.search_input:getText(), "")
        eq(v.tab, "series")
    end)
end)

describe("sort menu", function()
    it("is Author, Title, Date added, Last read, then Series", function()
        same(Core.SORT_MENU, { "author", "title", "added", "recent", "series" })
    end)
    it("Last read: most recently opened first; Date added: newest first", function()
        local a = { path = "a", title = "A", last_opened = 100, modification = 5 }
        local b = { path = "b", title = "B", last_opened = 300, modification = 1 }
        local c = { path = "c", title = "C", modification = 9 }
        eq(names(Core.sortBooks({ a, b, c }, "recent")), "B,A,C")
        eq(names(Core.sortBooks({ a, b, c }, "added")), "C,A,B")
        local d = { path = "d", title = "D" } -- no date: last, no crash
        eq(names(Core.sortBooks({ d, a, c }, "added")), "C,A,D")
    end)
end)
