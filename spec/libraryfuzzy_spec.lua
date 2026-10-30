-- "Typo-tolerant search": accents, punctuation, typos, transpositions,
-- prefixes, multi-word queries, ranking, and short words staying exact.
local Core = require("librarycore")

local function book(path, title, authors, series)
    return { path = path, name = path:match("[^/]+$") .. ".epub", title = title, authors = authors, series = series }
end

local function library()
    return Core.indexBooks({
        book("/jane", "Jane Eyre", { "Charlotte Brontë" }),
        book("/hp1", "Harry Potter and the Philosopher's Stone", { "J. K. Rowling" }, "Harry Potter"),
        book("/hp2", "Harry Potter and the Chamber of Secrets", { "J. K. Rowling" }, "Harry Potter"),
        book("/cien", "Cien años de soledad", { "Gabriel García Márquez" }),
        book("/obrien", "At Swim-Two-Birds", { "Flann O'Brien" }),
        book("/dune", "Dune", { "Frank Herbert" }, "Dune"),
        book("/tess", "Tess of the d’Urbervilles", { "Thomas Hardy" }),
        book("/hobbit", "The Hobbit", { "J. R. R. Tolkien" }),
        book("/pride", "Pride and Prejudice", { "Jane Austen" }),
        book("/strange", "Jonathan Strange & Mr Norrell", { "Susanna Clarke" }),
    })
end

local function paths(list)
    local out = {}
    for i, b in ipairs(list) do out[i] = b.path end
    return out
end

local function has(list, path)
    for _, b in ipairs(list) do if b.path == path then return true end end
    return false
end

local function search(books, q) return Core.searchFuzzy(books, q) end

describe("Core.normalizeText", function()
    it("folds accents and case", function()
        eq(Core.normalizeText("Brontë GARCÍA Márquez Æsop Straße"), "bronte garcia marquez aesop strasse")
    end)
    it("drops apostrophes and turns other punctuation into spaces", function()
        eq(Core.normalizeText("O'Brien d’Urbervilles Swim-Two-Birds: «Hi»…"), "obrien durbervilles swim two birds   hi  ")
    end)
    it("keeps other scripts", function()
        eq(Core.normalizeText("Война и мир"), "Война и мир")
    end)
end)

describe("Core.typoBudget", function()
    it("forgives 0 edits under 4 letters, 1 for 4-7, 2 for 8+", function()
        eq(Core.typoBudget(3), 0)
        eq(Core.typoBudget(4), 1)
        eq(Core.typoBudget(7), 1)
        eq(Core.typoBudget(8), 2)
        eq(Core.typoBudget(12), 2)
    end)
end)

describe("Core.prefixDistance", function()
    it("measures against the closest prefix of the word", function()
        eq(Core.prefixDistance("pott", "potter", 1), 0)
        eq(Core.prefixDistance("poter", "potter", 1), 1)
        eq(Core.prefixDistance("pottre", "potter", 1), 1, "transposition counts once")
        eq(Core.prefixDistance("hrary", "harry", 1), 1)
        eq(Core.prefixDistance("xyzw", "potter", 1), nil)
        eq(Core.prefixDistance("philospher", "philosophers", 2), 1)
        eq(Core.prefixDistance("phliospoher", "philosophers", 2), 2)
    end)
    it("gives up above the cap", function()
        eq(Core.prefixDistance("pxtxer", "potter", 1), nil)
        eq(Core.prefixDistance("pxtxer", "potter", 2), 2)
    end)
end)

describe("Core.searchFuzzy", function()
    local books = library()

    it("ignores accents both ways", function()
        same(paths(search(books, "bronte")), { "/jane" })
        same(paths(search(books, "garcia marquez")), { "/cien" })
        same(paths(search(books, "BRONTË")), { "/jane" })
        same(paths(search(books, "anos")), { "/cien" })
    end)

    it("ignores punctuation", function()
        same(paths(search(books, "obrien")), { "/obrien" })
        same(paths(search(books, "o'brien")), { "/obrien" })
        same(paths(search(books, "swim two birds")), { "/obrien" })
        same(paths(search(books, "durbervilles")), { "/tess" })
    end)

    it("forgives one typo in a 4-7 letter word", function()
        same(paths(search(books, "harry poter")), { "/hp1", "/hp2" })
        same(paths(search(books, "hobit")), { "/hobbit" })
        same(paths(search(books, "tolkein")), { "/hobbit" })
    end)

    it("counts a transposition as one edit", function()
        same(paths(search(books, "hrary")), { "/hp1", "/hp2" })
        same(paths(search(books, "austne")), { "/pride" })
    end)

    it("forgives two typos in words of 8+ letters", function()
        same(paths(search(books, "charlote brnote")), { "/jane" })
        same(paths(search(books, "filosopher")), { "/hp1" })
    end)

    it("does not forgive two typos in a short word", function()
        same(paths(search(books, "hxbxit")), {})
    end)

    it("matches word prefixes while typing, typos included", function()
        same(paths(search(books, "harry pot")), { "/hp1", "/hp2" })
        same(paths(search(books, "harry pottr")), { "/hp1", "/hp2" })
        same(paths(search(books, "chamber of secr")), { "/hp2" })
        same(paths(search(books, "chamebr")), { "/hp2" })
    end)

    it("needs every word to match, in any order", function()
        same(paths(search(books, "rowling chamber")), { "/hp2" })
        same(paths(search(books, "chambr rowlign")), { "/hp2" })
        same(paths(search(books, "potter austen")), {})
    end)

    it("keeps words under 4 letters exact", function()
        same(paths(search(books, "dun")), { "/dune" })
        same(paths(search(books, "dnu")), {})
        same(paths(search(books, "xo")), {})
    end)

    it("puts exact matches first, then accent-free ones, then by edits", function()
        local lib = Core.indexBooks({
            book("/far", "Harden", { "Ann Lee" }),        -- 1 edit: "hard" + y
            book("/typo", "Thomas Hardi", { "X" }),       -- 1 edit: y -> i
            book("/exact", "Hardy Boys", { "Y" }),        -- exact
            book("/accent", "Hárdy Annals", { "Z" }),     -- exact once accents fold
            book("/exact2", "Life of Hardy", { "W" }),    -- exact
        })
        same(paths(search(lib, "hardy")), { "/exact", "/exact2", "/accent", "/far", "/typo" })
    end)

    it("orders close matches by total edits, keeping the given order in ties", function()
        local lib = Core.indexBooks({
            book("/two", "Mistborn Tale", { "Brandon Sandersen" }),   -- 2 edits
            book("/one_a", "Mistborn", { "Brandon Sanderson" }),       -- 1 edit (re/er swapped)
            book("/one_b", "Elantris", { "Brandon Sanderson" }),       -- 1 edit
        })
        same(paths(search(lib, "sandreson")), { "/one_a", "/one_b", "/two" })
    end)

    it("leaves the plain search unchanged when it is off", function()
        eq(#Core.searchIndexed(books, "harry poter"), 0)
        eq(#Core.searchIndexed(books, "harry poter", nil, nil, true), 2)
        eq(#Core.searchIndexed(books, ""), #books)
        eq(#Core.searchIndexed(books, "  ", nil, nil, true), #books)
    end)

    it("is on unless turned off", function()
        eq(Core.fuzzySearch(nil), true)
        eq(Core.fuzzySearch({}), true)
        eq(Core.fuzzySearch({ fuzzy_search = false }), false)
    end)

    it("indexes books met outside the library on demand", function()
        local b = { path = "/x", title = "Wuthering Heights", authors = { "Emily Brontë" } }
        same(paths(Core.searchFuzzy({ b }, "wutherng")), { "/x" })
        eq(type(b.search_tokens), "table")
    end)
end)
