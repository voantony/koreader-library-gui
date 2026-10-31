-- Book details card: plain descriptions, button labels, long-press routing,
-- progress text, and opening the shelf a chip or a name points at.
local Core = require("librarycore")
local Index = require("libraryindex")

describe("description cleanup", function()
    it("strips tags, keeps paragraphs, decodes entities", function()
        eq(Core.plainDescription(nil), nil)
        eq(Core.plainDescription("   "), nil)
        eq(Core.plainDescription("<p></p>"), nil)
        eq(Core.plainDescription("  Hello  "), "Hello")
        eq(Core.plainDescription("<p>Hello</p><p>World</p>"), "Hello\n\nWorld")
        eq(Core.plainDescription("<b>Bold</b> &amp; &lt;em&gt;"), "Bold & <em>")
        eq(Core.plainDescription("<script>bad()\nbad()</script>Hi"), "Hi")
        eq(Core.plainDescription("<style>p{color:red}</style>Hi<br>There"), "Hi\nThere")
        eq(Core.plainDescription("A&#8212;B"), "A\u{2014}B")
        eq(Core.plainDescription("<!-- secret -->Visible"), "Visible")
        eq(Core.plainDescription("<div>One</div><div>Two</div>"), "One\nTwo")
    end)

    it("uses the first source that has text, then the file", function()
        eq(Core.firstDescription({ "<p></p>", "  ", "<p>Real</p>" }), "Real")
        eq(Core.firstDescription({}), nil)
        eq(Core.firstDescription(nil), nil)
        eq(Core.descriptionFrom({ "<p>Calibre</p>" }, "From the file"), "Calibre")
        eq(Core.descriptionFrom({ "<br>" }, "<p>From the file</p>"), "From the file")
        eq(Core.descriptionFrom({}, nil), nil)
    end)

    it("reads Calibre comments without putting them on the indexed props", function()
        local map = Core.calibreComments({
            { lpath = "books/Emma.epub", comments = "<p>Emma Woodhouse, handsome, clever, and rich.</p>" },
            { lpath = "books/Empty.epub", comments = "", description = "Fallback blurb" },
            { lpath = "", comments = "skipped" },
        }, "/mnt/us")
        eq(map["/mnt/us/books/Emma.epub"], "<p>Emma Woodhouse, handsome, clever, and rich.</p>")
        eq(map["/mnt/us/books/Empty.epub"], "Fallback blurb")
        local props = Core.calibreIndex({
            { lpath = "books/Emma.epub", title = "Emma", comments = "<p>Secret</p>" },
        }, "/mnt/us")
        eq(props["/mnt/us/books/Emma.epub"].title, "Emma")
        eq(props["/mnt/us/books/Emma.epub"].comments, nil)
        eq(props["/mnt/us/books/Emma.epub"].description, nil)
    end)
end)

describe("button state", function()
    it("says Open only for an unread book, Continue after it has been started", function()
        eq(Core.detailsOpenAction({ status = "new" }), "open")
        eq(Core.detailsOpenAction({}), "open")
        eq(Core.detailsOpenAction(nil), "open")
        eq(Core.detailsOpenAction({ status = "reading" }), "continue")
        eq(Core.detailsOpenAction({ status = "abandoned" }), "continue")
        eq(Core.detailsOpenAction({ status = "complete" }), "continue")
    end)

    it("marks finished, or unread when the book is already finished", function()
        eq(Core.detailsStatusAction({ status = "reading" }), "mark_finished")
        eq(Core.detailsStatusAction({ status = "new" }), "mark_finished")
        eq(Core.detailsStatusAction({ status = "abandoned" }), "mark_finished")
        eq(Core.detailsStatusAction({ status = "complete" }), "mark_unread")
        eq(Core.detailsStatusAction(nil), "mark_finished")
    end)

    it("Continue only closes the card when the book is already open", function()
        eq(Core.detailsPrimaryDismisses(true), true)
        eq(Core.detailsPrimaryDismisses(false), false)
        eq(Core.detailsPrimaryDismisses(nil), false)
    end)
end)

describe("progress text", function()
    it("is a percent, and time left only when that duration is already known", function()
        eq(Core.progressPercent({ status = "reading", percent = 0.37 }), 37)
        eq(Core.progressPercent({ status = "new" }), 0)
        eq(Core.progressPercent({ status = "complete" }), 100)
        eq(Core.progressPercent({ status = "complete", percent = 0.37 }), 37)
        eq(Core.timeLeftText(nil), nil)
        eq(Core.timeLeftText(0), nil)
        eq(Core.timeLeftText(29), nil)
        eq(Core.timeLeftText(59), "1m")
        eq(Core.timeLeftText(120), "2m")
        eq(Core.timeLeftText(3600), "1h")
        eq(Core.timeLeftText(3 * 3600 + 39 * 60), "3h 39m")
        local pct, left = Core.progressParts({ status = "reading", percent = 0.37, time_left = 3 * 3600 + 39 * 60 })
        eq(Core.progressLine(pct, left), "37% · 3h 39m left")
        pct, left = Core.progressParts({ status = "reading", percent = 0.37 })
        eq(left, nil)
        eq(Core.progressLine(pct, left), "37%")
        eq(Core.knownTimeLeft({ time_left = 10 }), 10)
        eq(Core.knownTimeLeft({}, { stats = { time_left = 5 } }), 5)
        eq(Core.knownTimeLeft({ percent = 0.2 }, { stats = {} }), nil)
        -- a zero stored on the book does not count, so a real sidecar value can
        eq(Core.knownTimeLeft({ time_left = 0 }, { time_left = 80 }), 80)
    end)
end)

describe("long-press routing", function()
    it("opens details for a book and does nothing for a shelf", function()
        eq(Core.longPressAction({ book = { path = "/a.epub", title = "A" } }), "details")
        eq(Core.longPressAction({ group = { name = "Austen", kind = "authors" } }), nil)
        eq(Core.longPressAction({ book = { title = "no path" } }), nil)
        eq(Core.longPressAction({ book = { path = "" } }), nil)
        eq(Core.longPressAction(nil), nil)
    end)
end)

describe("details layout", function()
    it("uses two columns on a wide screen and one when two do not fit", function()
        eq(Core.detailsLayout(1264, 1680).columns, 2)
        eq(Core.detailsLayout(1680, 1264).columns, 2)
        eq(Core.detailsLayout(600, 800).columns, 1)
        eq(Core.detailsLayout(480, 800).columns, 1)
        eq(Core.detailsLayout(1680, 400).columns, 1)
        local wide = Core.detailsLayout(1264, 1680)
        eq(wide.cover_w < wide.text_w, true)
        eq(wide.text_w >= 300, true)
        local narrow = Core.detailsLayout(600, 800)
        eq(narrow.text_w, narrow.inner_w)
    end)
end)

describe("description page turns", function()
    local area = { x = 10, y = 20, w = 100, h = 80 }

    it("pages forward on the right half or a north swipe, back on the left or south", function()
        eq(Core.descriptionPageTurn({ kind = "tap", x = 80, y = 40 }, area), 1)
        eq(Core.descriptionPageTurn({ kind = "tap", x = 20, y = 40 }, area), -1)
        eq(Core.descriptionPageTurn({ kind = "swipe", direction = "north", x = 40, y = 40 }, area), 1)
        eq(Core.descriptionPageTurn({ kind = "swipe", direction = "south", x = 40, y = 40 }, area), -1)
        eq(Core.descriptionPageTurn({ kind = "swipe", direction = "east", x = 40, y = 40 }, area), nil)
        eq(Core.descriptionPageTurn({ kind = "tap", x = 200, y = 40 }, area), nil)
        eq(Core.descriptionPageTurn({ kind = "tap" }, area), nil)
    end)

    it("stays on the page at either end, and when there is only one page", function()
        eq(Core.turnPage(1, 4, 1), 2)
        eq(Core.turnPage(4, 4, 1), 4)
        eq(Core.turnPage(1, 3, -1), 1)
        eq(Core.turnPage(2, 1, 1), 1)
        eq(Core.turnPage(2, 3, 0), 2)
    end)
end)

describe("tappable shelves", function()
    it("matches a genre, author, series or collection by name, never Unsorted", function()
        local groups = {
            { name = "Classics", books = {} },
            { name = "Unsorted", unsorted = true, books = {} },
        }
        eq(Core.shelfMatch("classics", groups).name, "Classics")
        eq(Core.shelfMatch("Unsorted", groups), nil)
        eq(Core.shelfMatch("", groups), nil)
    end)

    it("lists the collections a book is in", function()
        local names = Core.collectionNames("/e", {
            { name = "Favorites", books = { { path = "/e" }, { path = "/p" } } },
            { name = "Other", books = { { path = "/p" } } },
            { name = "Unsorted", unsorted = true, books = { { path = "/e" } } },
        })
        same(names, { "Favorites" })
    end)

    it("gives each author its own name, and the series its own line", function()
        same(Core.authorNames({ authors = { "Arthur Conan Doyle", "Someone Else" } }),
            { "Arthur Conan Doyle", "Someone Else" })
        same(Core.authorNames({ authors = "Jane Austen\nAnother" }), { "Jane Austen", "Another" })
        eq(Core.seriesLine({ series = "Sherlock Holmes", series_index = 5 }), "Sherlock Holmes #5")
        eq(Core.seriesLine({ series = "Sherlock Holmes" }), "Sherlock Holmes")
        eq(Core.seriesLine({ title = "Emma" }), nil)
    end)

    it("packs chips onto rows", function()
        same(Core.packRows({ 10, 10, 10 }, 25, 2), { { 1, 2 }, { 3 } })
        same(Core.packRows({ 30 }, 25, 2), { { 1 } })
        same(Core.packRows({}, 25, 2), {})
    end)
end)

describe("description is not part of the grid index", function()
    it("loads Calibre comments and a stored time left only when asked", function()
        local calls = 0
        local idx = Index.new{
            root = "/mnt/us",
            fs = {
                attributes = function(path, field)
                    local a
                    if path == "/mnt/us/metadata.calibre" then
                        a = { mode = "file", size = 10, modification = 1 }
                    elseif path == "/sdr/emma.lua" then
                        a = { mode = "file", size = 1, modification = 3 }
                    end
                    if field then return a and a[field] end
                    return a
                end,
            },
            calibre_load = function()
                calls = calls + 1
                return {
                    { lpath = "Emma.epub", title = "Emma", comments = "<p>Emma Woodhouse, handsome, clever, and rich.</p>" },
                }
            end,
            docsettings = {
                findSidecarFile = function(_, path)
                    if path == "/mnt/us/Emma.epub" then return "/sdr/emma.lua" end
                end,
                openSettingsFile = function()
                    return { data = {
                        doc_props = { description = "Sidecar blurb" },
                        stats = { time_left = 3 * 3600 + 39 * 60 },
                    } }
                end,
            },
        }
        local list = idx:descriptionCandidates("/mnt/us/Emma.epub")
        eq(list[1], "<p>Emma Woodhouse, handsome, clever, and rich.</p>")
        eq(list[2], "Sidecar blurb")
        eq(Core.firstDescription(list), "Emma Woodhouse, handsome, clever, and rich.")
        eq(idx:knownTimeLeft("/mnt/us/Emma.epub", {}), 3 * 3600 + 39 * 60)
        eq(idx:knownTimeLeft("/mnt/us/Emma.epub", { time_left = 10 }), 10)
        eq(calls >= 1, true)
    end)

    it("uses the full calibre read when the slim loader has no comments", function()
        local slim, full = 0, 0
        local idx = Index.new{
            root = "/mnt/us",
            fs = {
                attributes = function(path, field)
                    local a = path == "/mnt/us/metadata.calibre" and { mode = "file", size = 10, modification = 1 } or nil
                    if field then return a and a[field] end
                    return a
                end,
            },
            calibre_load = function()
                slim = slim + 1
                return { { lpath = "Emma.epub", title = "Emma" } }
            end,
            calibre_load_full = function()
                full = full + 1
                return { { lpath = "Emma.epub", comments = "<p>From the full file.</p>" } }
            end,
            docsettings = { findSidecarFile = function() return nil end },
        }
        local list = idx:descriptionCandidates("/mnt/us/Emma.epub")
        eq(list[1], "<p>From the full file.</p>")
        eq(Core.firstDescription(list), "From the full file.")
        eq(full, 1)
        eq(slim, 0)
    end)
end)

describe("reader menu order", function()
    it("puts Book details immediately after Library, once", function()
        local order = { "library_open", "history" }
        Core.placeAfter(order, "library_details", "library_open")
        Core.placeAfter(order, "library_details", "library_open")
        eq(table.concat(order, ","), "library_open,library_details,history")
    end)
end)

-- Long-press and shelf routing through the view, with KOReader stubbed.
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

describe("long-press opens the card, a tap still opens the book", function()
    local View = load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = (function()
            local base = {}
            base.__index = base
            function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
            function base:new(o) o = o or {}; return setmetatable(o, self) end
            return base
        end)(),
        ["ui/uimanager"] = { unschedule = function() end, scheduleIn = function() end, setDirty = function() end },
        util = { stringLower = function(s) return s:lower() end },
    })

    local function books()
        return {
            { path = "/e", title = "Emma", authors = { "Jane Austen" }, series = "Novels", series_index = 2, keywords = "Classics" },
            { path = "/p", title = "Pride", authors = { "Jane Austen" }, series = "Novels", series_index = 1, keywords = "Classics" },
            { path = "/d", title = "Dracula", authors = { "Bram Stoker" }, keywords = "Horror" },
        }
    end

    local function view(settings)
        local opened, details = {}, {}
        local v = setmetatable({
            tab = "books", query = "", page = 3, sorted = books(), all_books = books(),
            groups_cache = {},
            plugin = {
                settings = settings or {},
                saveSettings = function() end,
                getCollections = function()
                    return { { kind = "collections", name = "Favorites", books = { { path = "/e" } } } }
                end,
                openBook = function(_, path) opened[#opened + 1] = path end,
                showBookDetails = function(_, book) details[#details + 1] = book.path end,
                showBookDialog = function() error("long-press must not open the old dialog") end,
            },
        }, { __index = View })
        v.keyboardGuard = function() end
        v.refreshBody = function(self) self.refreshed = (self.refreshed or 0) + 1 end
        v.applyRemembered = function() end
        return v, opened, details
    end

    it("a book hold opens details; a shelf hold does not; a tap still opens", function()
        local v, opened, details = view()
        v:onTileHold({ book = { path = "/e", title = "Emma" } })
        eq(details[1], "/e")
        v:onTileHold({ group = { name = "Jane Austen", kind = "authors" } })
        eq(#details, 1)
        v:onTileTap({ book = { path = "/p" } })
        eq(opened[1], "/p")
    end)

    it("a genre chip opens that genre, a collection opens Collections, a series stays in order", function()
        local settings = {}
        local v = view(settings)
        eq(v:openNamedShelf("genres", "classics"), true)
        eq(v.tab, "collections")
        eq(settings.collections_view, "genres")
        eq(v.group.name, "Classics")
        eq(#v.group.books, 2)

        eq(v:openNamedShelf("collections", "Favorites"), true)
        eq(settings.collections_view, nil)
        eq(v.group.name, "Favorites")
        eq(v.group.books[1].path, "/e")

        eq(v:openNamedShelf("series", "Novels"), true)
        eq(v.tab, "series")
        eq(v.group.books[1].path, "/p") -- series index 1 before 2
        eq(v.group.books[2].path, "/e")

        eq(v:openNamedShelf("authors", "Jane Austen"), true)
        eq(v.tab, "authors")
        eq(v.group.name, "Jane Austen")
        eq(#v.group.books, 2)
        eq(v:openNamedShelf("authors", "Nobody"), false)
    end)
end)
