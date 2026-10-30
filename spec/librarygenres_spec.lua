-- Genres: the Collections tab switches between Collections and Genres; genres
-- come from each book's keywords (Calibre tags) already in the index.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

-- Load a plugin file with KOReader stubbed; `extra[name]` overrides a module.
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



local Core = require("librarycore")

local function names(list)
    local t = {}
    for i, g in ipairs(list) do t[i] = g.name .. "(" .. #g.books .. ")" end
    return table.concat(t, ", ")
end

local function bk(title, keywords) return { path = "/" .. title, title = title, keywords = keywords } end

describe("Genres: splitting keywords", function()
    it("splits on new lines, commas and semicolons, never on &", function()
        same(Core.splitKeywords("Mystery & Thriller\nClassics"), { "Mystery & Thriller", "Classics" })
        same(Core.splitKeywords(" Science Fiction ; Fantasy,  Children's \r\n"), { "Science Fiction", "Fantasy", "Children's" })
        same(Core.splitKeywords("Biography &  Memoir"), { "Biography & Memoir" })
        same(Core.splitKeywords(",,; \n"), {})
        same(Core.splitKeywords(nil), {})
    end)
end)

describe("Genres: grouping", function()
    local books = {
        bk("Dune", "Science Fiction"),
        bk("Emma", "Classics\nLiterary Fiction"),
        bk("Kim", "classics; Espionage & Intelligence"),
        bk("Ozma", "Children's, Fantasy, Classics"),
        bk("Notes", nil),
        bk("Blank", " ; "),
        bk("Twice", "Fantasy\nfantasy"), -- same genre twice in one book: listed once
    }

    it("merges case-insensitively, shows the most common spelling, sorts by name, Unsorted last", function()
        local g = Core.genreGroups(books, nil, nil, "Unsorted")
        eq(names(g), "Children's(1), Classics(3), Espionage & Intelligence(1), Fantasy(2), Literary Fiction(1), Science Fiction(1), Unsorted(2)")
        eq(g[#g].unsorted, true)
        for _, x in ipairs(g) do eq(x.kind, "genres") end
    end)

    it("a book with several genres is in each, in the order given (the current sort)", function()
        local g = Core.genreGroups(books)
        local classics
        for _, x in ipairs(g) do if x.name == "Classics" then classics = x end end
        eq(classics.books[1].title .. "," .. classics.books[2].title .. "," .. classics.books[3].title, "Emma,Kim,Ozma")
    end)

    it("no Unsorted group when every book has a genre", function()
        local g = Core.genreGroups({ bk("A", "Poetry"), bk("B", "Essays") })
        eq(names(g), "Essays(1), Poetry(1)")
    end)

    it("all 26 of Antony's Calibre genres come through whole", function()
        local list = { "Classics", "Biography & Memoir", "Literary Fiction", "Occult & Esoteric", "Science Fiction",
            "History", "Politics", "Self-Help", "Military & War", "Philosophy", "Historical Fiction", "Religion",
            "Sports", "Espionage & Intelligence", "Humor", "Poetry", "Fantasy", "Music", "Business & Economics",
            "Mystery & Thriller", "Psychology", "Reference", "Essays", "Technology", "Children's", "Nature & Outdoors" }
        local bs = {}
        for i, name in ipairs(list) do bs[i] = bk("Book" .. i, name) end
        -- calibre tags arrive joined by new lines (Core.calibreIndex)
        local calibre = Core.calibreIndex({ { lpath = "x.epub", title = "X", tags = { "Mystery & Thriller", "Classics" } } }, "/b")
        same(Core.splitKeywords(calibre["/b/x.epub"].keywords), { "Mystery & Thriller", "Classics" })
        eq(#Core.genreGroups(bs), 26)
    end)
end)

describe("Genres: the Collections tab switch", function()
    local View = load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = cls(),
        ["ui/uimanager"] = { unschedule = function() end, scheduleIn = function() end },
        util = { stringLower = function(s) return s:lower() end },
    })
    local saved
    local function view(settings)
        local input = { text = "" }
        function input:setText(t) self.text = t end
        function input:getText() return self.text end
        saved = 0
        local v = setmetatable({
            tab = "collections", query = "", filter = "all", page = 3, all_books = {},
            groups_cache = {}, fuzzy_search = true, search_input = input,
            plugin = {
                settings = settings,
                saveSettings = function() saved = saved + 1 end,
                getCollections = function() return { { kind = "collections", name = "Favorites", books = {} } } end,
            },
        }, { __index = View })
        v.keyboardGuard = function() end
        v.applyRemembered = function() end
        v.refreshBody = function() end
        v.updateSearchHint = function() end
        return v
    end
    local BOOKS = { bk("Dune", "Science Fiction"), bk("Notes", nil), bk("Emma", "Classics") }

    it("shows Collections by default and Genres once switched, remembered in settings", function()
        local settings = {}
        local v = view(settings); v.sorted = BOOKS
        eq(names(v:currentItems().items), "Favorites(0)")
        eq(v:searchHint(), "Search collections\u{2026}")
        v:setCollectionsView("genres")
        eq(settings.collections_view, "genres")
        eq(saved, 1)
        eq(v.page, 1)
        eq(names(v:currentItems().items), "Classics(1), Science Fiction(1), Unsorted(1)")
        eq(v:searchHint(), "Search genres\u{2026}")
        -- a new view (next time the Library opens) starts on Genres
        local v2 = view(settings); v2.sorted = BOOKS
        eq(v2:showingGenres(), true)
        v2:setCollectionsView("collections")
        eq(settings.collections_view, nil)
        eq(names(v2:currentItems().items), "Favorites(0)")
    end)

    it("search narrows genres by name; a genre opens as a shelf of books", function()
        local v = view({ collections_view = "genres" }); v.sorted = BOOKS
        v.query = "scien"
        eq(names(v:currentItems().items), "Science Fiction(1)")
        v.query = ""
        local g = v:currentItems().items[1]
        v:openGroup(g)
        local d = v:currentItems()
        eq(d.kind, "books"); eq(d.items[1].title, "Emma")
        eq(Core.viewKey(v.tab, v.group), "genres:Classics")
    end)
end)
