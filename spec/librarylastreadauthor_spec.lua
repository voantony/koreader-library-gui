-- Last read: books never opened, and books opened at the same moment, fall
-- back to author order, then title within an author.
local Core = require("librarycore")

local function titles(list)
    local t = {}
    for i, b in ipairs(list) do t[i] = b.title end
    return table.concat(t, ",")
end

describe("Last read sort fallback", function()
    it("never-opened books come after opened ones, by author then title", function()
        local books = {
            { path = "/1", title = "Ivanhoe", authors = { "Walter Scott" }, modification = 9 },
            { path = "/2", title = "Persuasion", authors = { "Jane Austen" }, modification = 1 },
            { path = "/3", title = "Dracula", authors = { "Bram Stoker" }, last_opened = 10, modification = 2 },
            { path = "/4", title = "Emma", authors = { "Jane Austen" }, modification = 5 },
            { path = "/5", title = "Anon Tales", modification = 8 }, -- no author: last
            { path = "/6", title = "Rob Roy", authors = { "Walter Scott" }, last_opened = 0 },
            { path = "/7", title = "Kidnapped", authors = { "Robert Louis Stevenson" }, last_opened = 20 },
        }
        eq(titles(Core.sortBooks(books, "recent")),
            "Kidnapped,Dracula,Emma,Persuasion,Ivanhoe,Rob Roy,Anon Tales")
    end)

    it("books opened at the same time are ordered by author too", function()
        local books = {
            { path = "/1", title = "Zuleika", authors = { "Max Beerbohm" }, last_opened = 50 },
            { path = "/2", title = "Adam Bede", authors = { "George Eliot" }, last_opened = 50 },
            { path = "/3", title = "Middlemarch", authors = { "George Eliot" }, last_opened = 50 },
            { path = "/4", title = "Emma", authors = { "Jane Austen" }, last_opened = 60 },
        }
        local sorted = Core.sortBooks(books, "recent")
        eq(sorted[1].title, "Emma")
        eq(titles(sorted), "Emma,Adam Bede,Middlemarch,Zuleika") -- George Eliot before Max Beerbohm
        -- within one author, by title
        local eliot = {}
        for _, b in ipairs(sorted) do if b.authors[1] == "George Eliot" then eliot[#eliot + 1] = b.title end end
        same(eliot, { "Adam Bede", "Middlemarch" })
    end)

    it("matches the Author sort for the never-opened tail", function()
        local books = {}
        local names = { "Mark Twain", "Jane Austen", "Bram Stoker", "Leo Tolstoy", "Anne Brontë" }
        for i, a in ipairs(names) do
            books[i] = { path = "/" .. i, title = "Book " .. (6 - i), authors = { a }, modification = i }
        end
        eq(titles(Core.sortBooks(books, "recent")), titles(Core.sortBooks(books, "author")))
    end)

    it("Date added is unchanged: newest file first", function()
        local books = {
            { path = "/1", title = "A", authors = { "Zed" }, modification = 1 },
            { path = "/2", title = "B", authors = { "Abe" }, modification = 3 },
        }
        eq(titles(Core.sortBooks(books, "added")), "B,A")
    end)
end)
