-- Issue #1: configurable widgets above the book grid.
local W = require("librarywidgets")

local function book(path, title)
    return { path = path, title = title or path }
end

describe("home widgets", function()
    it("defaults to one Continue Reading widget", function()
        local slots = W.slots({})
        eq(#slots, 1)
        eq(slots[1].kind, "continue")
        eq(W.customized({}), false)
    end)

    it("an unchecked Show Continue Reading is no widgets", function()
        local slots = W.defaultFromContinue(false)
        eq(#slots, 0)
        eq(W.areaVisible(slots, { tab = "books" }), false)
    end)

    it("a saved empty list stays empty and hides the area", function()
        local slots = W.slots({ home_widgets = {}, show_continue = true })
        eq(#slots, 0)
        eq(W.customized({ home_widgets = {} }), true)
        eq(W.areaVisible(slots, { tab = "books" }), false)
    end)

    it("keeps at most two widgets and drops None", function()
        local slots = W.normalize({
            { kind = "continue" },
            { kind = "none" },
            { kind = "favorites" },
            { kind = "series", name = "Oz" },
        })
        eq(#slots, 2)
        eq(slots[1].kind, "continue")
        eq(slots[2].kind, "favorites")
    end)

    it("uses the same gates as Continue reading", function()
        local slots = { { kind = "favorites" } }
        eq(W.areaVisible(slots, { tab = "books" }), true)
        eq(W.areaVisible(slots, { tab = "books", query = "emma" }), false)
        eq(W.areaVisible(slots, { tab = "books", filter = "unread" }), false)
        eq(W.areaVisible(slots, { tab = "authors" }), false)
        eq(W.areaVisible(slots, { tab = "books", group = {} }), false)
        eq(W.areaVisible(slots, { tab = "books", keyboard = true }), false)
    end)

    it("labels match the issue's names", function()
        eq(W.label({ kind = "continue" }), "Continue Reading")
        eq(W.label({ kind = "favorites" }), "Favorites")
        eq(W.label({ kind = "series", name = "Oz" }), "Oz")
        eq(W.label({ kind = "folder", path = "/books/Novels" }), "Novels")
    end)

    it("Favorites, a series, a collection, and a folder each return their books", function()
        local fav = book("/b/a.epub", "Emma")
        local oz = book("/b/oz.epub", "Ozma")
        local ctx = {
            continue = { book("/b/c.epub", "Now") },
            favorites = { fav },
            series = { { name = "Oz", books = { oz } } },
            collections = { { name = "Holiday", books = { book("/b/h.epub", "Carol") } } },
            all = {
                book("/books/Novels/Emma.epub", "Emma"),
                book("/books/Poems/Leaves.epub", "Leaves"),
            },
        }
        eq(W.books({ kind = "continue" }, ctx)[1].title, "Now")
        eq(W.books({ kind = "favorites" }, ctx)[1], fav)
        eq(W.books({ kind = "series", name = "Oz" }, ctx)[1], oz)
        eq(W.books({ kind = "series", name = "Missing" }, ctx)[1], nil)
        eq(W.books({ kind = "collection", name = "Holiday" }, ctx)[1].title, "Carol")
        local folder = W.books({ kind = "folder", path = "/books/Novels" }, ctx)
        eq(#folder, 1)
        eq(folder[1].title, "Emma")
    end)

    it("switching a slot and removing it with None", function()
        local slots = W.setSlot({ { kind = "continue" } }, 1, { kind = "favorites" })
        eq(slots[1].kind, "favorites")
        slots = W.setSlot(slots, 2, { kind = "series", name = "Oz" })
        eq(#slots, 2)
        eq(slots[2].name, "Oz")
        slots = W.setSlot(slots, 1, { kind = "none" })
        eq(#slots, 1)
        eq(slots[1].kind, "series")
    end)

    it("a title tap expands one of two widgets, and a second tap restores the pair", function()
        eq(W.accordion(1, nil, 1), nil)
        eq(W.accordion(2, nil, 1), 1)
        eq(W.accordion(2, 1, 1), nil)
        eq(W.accordion(2, 1, nil), nil)
        eq(W.accordion(2, nil, 2), 2)
    end)

    it("folder choices are the directories the books live in", function()
        local dirs = W.folderChoices({
            book("/mnt/books/Novels/a.epub"),
            book("/mnt/books/Novels/b.epub"),
            book("/mnt/books/Poems/c.epub"),
        })
        eq(#dirs, 2)
        eq(dirs[1], "/mnt/books/Novels")
        eq(dirs[2], "/mnt/books/Poems")
    end)
end)
