-- Series browsing, Next in series, the Barely started filter and Resume.
local Core = require("librarycore")

local function paths(list)
    local out = {}
    for i, b in ipairs(list) do out[i] = b.path end
    return out
end

local function bk(t)
    t.name = t.name or (t.path:sub(2) .. ".epub")
    t.title = t.title or t.path:sub(2)
    t.modification = t.modification or 0
    return t
end

describe("series order", function()
    local books = {
        bk{ path = "/c", title = "Warlord", series = "Barsoom", series_index = 3 },
        bk{ path = "/x", title = "Zeta extra", series = "Barsoom" },
        bk{ path = "/a", title = "Princess", series = "Barsoom", series_index = 1 },
        bk{ path = "/h", title = "Half", series = "Barsoom", series_index = 2.5 },
        bk{ path = "/b", title = "Gods", series = "Barsoom", series_index = 2 },
        bk{ path = "/w", title = "Alpha extra", series = "Barsoom" },
        bk{ path = "/t", title = "Tarzan", series = "Tarzan", series_index = 1 },
        bk{ path = "/n", title = "Loose" },
    }
    it("orders by series number, books without one last by title", function()
        same(paths(Core.seriesOrder({ books[1], books[2], books[3], books[4], books[5], books[6] })),
            { "/a", "/b", "/h", "/c", "/w", "/x" })
    end)
    it("is stable for equal numbers and titles (path breaks the tie)", function()
        local d1 = bk{ path = "/d2", title = "Same", series_index = 1 }
        local d2 = bk{ path = "/d1", title = "Same", series_index = 1 }
        same(paths(Core.seriesOrder({ d1, d2 })), { "/d1", "/d2" })
    end)
    it("picks one series out of the library", function()
        same(paths(Core.seriesBooks(books, "Barsoom")), { "/a", "/b", "/h", "/c", "/w", "/x" })
        same(paths(Core.seriesBooks(books, "Tarzan")), { "/t" })
        same(paths(Core.seriesBooks(books, nil)), {})
    end)
    it("formats series numbers for tiles", function()
        eq(Core.seriesNumber(3), "3")
        eq(Core.seriesNumber(3.0), "3")
        eq(Core.seriesNumber(2.5), "2.5")
        eq(Core.seriesNumber("4"), "4")
        eq(Core.seriesNumber(1.25), "1.25")
        eq(Core.seriesNumber(nil), nil)
    end)
    it("counts finished books for the series progress", function()
        local s = { bk{ path = "/1", status = "complete" }, bk{ path = "/2", status = "reading" },
            bk{ path = "/3", status = "complete" }, bk{ path = "/4" }, bk{ path = "/5", status = "abandoned" } }
        same(Core.seriesProgress(s), { read = 2, total = 5 })
        same(Core.seriesProgress({}), { read = 0, total = 0 })
    end)
end)

describe("next in series", function()
    local function series(statuses)
        local out = {}
        for i, st in ipairs(statuses) do
            out[i] = bk{ path = "/" .. i, series = "S", series_index = i, status = st }
        end
        return out
    end
    it("opens the next unfinished book", function()
        local s = series{ "complete", "reading", "new", "new" }
        eq(Core.seriesNeighbour(s, s[2], 1).path, "/3")
    end)
    it("skips later books already finished", function()
        local s = series{ "reading", "complete", "complete", "new" }
        eq(Core.seriesNeighbour(s, s[1], 1).path, "/4")
    end)
    it("falls back to the next book when every later one is finished", function()
        local s = series{ "reading", "complete", "complete" }
        eq(Core.seriesNeighbour(s, s[1], 1).path, "/2")
    end)
    it("can ignore finished state", function()
        local s = series{ "reading", "complete", "new" }
        eq(Core.seriesNeighbour(s, s[1], 1, { skip_finished = false }).path, "/2")
    end)
    it("goes back one book for Previous, finished or not", function()
        local s = series{ "complete", "complete", "reading" }
        eq(Core.seriesNeighbour(s, s[3], -1).path, "/2")
    end)
    it("returns nil at the ends and for a book not in the list", function()
        local s = series{ "new", "new" }
        eq(Core.seriesNeighbour(s, s[2], 1), nil)
        eq(Core.seriesNeighbour(s, s[1], -1), nil)
        eq(Core.seriesNeighbour(s, bk{ path = "/zz" }, 1), nil)
        eq(Core.seriesNeighbour(s, nil, 1), nil)
    end)
    it("skips other copies of the current book (same number)", function()
        local s = Core.seriesOrder{
            bk{ path = "/2epub", title = "Two", series_index = 2, status = "reading" },
            bk{ path = "/2pdf", title = "Two", series_index = 2 },
            bk{ path = "/1", title = "One", series_index = 1, status = "complete" },
            bk{ path = "/3", title = "Three", series_index = 3 },
        }
        eq(Core.seriesNeighbour(s, s[2], 1).path, "/3")
        eq(Core.seriesNeighbour(s, s[3], -1).path, "/1")
    end)
    it("steps through books without numbers in title order", function()
        local s = Core.seriesOrder{ bk{ path = "/b", title = "B" }, bk{ path = "/a", title = "A" } }
        eq(Core.seriesNeighbour(s, s[1], 1).path, "/b")
        eq(Core.seriesNeighbour(s, s[2], -1).path, "/a")
    end)
end)

describe("barely started", function()
    local books = {
        bk{ path = "/new", status = "new" },
        bk{ path = "/zero", status = "reading", percent = 0 },
        bk{ path = "/p3", status = "reading", percent = 0.03 },
        bk{ path = "/p7", status = "reading", percent = 0.07 },
        bk{ path = "/p10", status = "reading", percent = 0.10 },
        bk{ path = "/p15", status = "abandoned", percent = 0.15 },
        bk{ path = "/p24", status = "reading", percent = 0.24 },
        bk{ path = "/p50", status = "reading", percent = 0.5 },
        bk{ path = "/done", status = "complete", percent = 0.02 },
        bk{ path = "/nopct", status = "reading" },
    }
    it("counts opened books above 0 % and below the threshold", function()
        same(paths(Core.filterStatus(books, "barely", 0.10)), { "/p3", "/p7" })
        same(paths(Core.filterStatus(books, "barely", 0.05)), { "/p3" })
        same(paths(Core.filterStatus(books, "barely", 0.20)), { "/p3", "/p7", "/p10", "/p15" })
        same(paths(Core.filterStatus(books, "barely", 0.25)), { "/p3", "/p7", "/p10", "/p15", "/p24" })
    end)
    it("never counts unopened, finished or percent-less books", function()
        for _, p in ipairs({ "/new", "/zero", "/done", "/nopct" }) do
            for _, b in ipairs(Core.filterStatus(books, "barely", 0.25)) do
                if b.path == p then error(p .. " should not count") end
            end
        end
    end)
    it("defaults to 10 % and only accepts the offered thresholds", function()
        eq(Core.barelyThreshold(nil), 0.10)
        eq(Core.barelyThreshold(0.05), 0.05)
        eq(Core.barelyThreshold(0.25), 0.25)
        eq(Core.barelyThreshold(0.5), 0.10)
        eq(Core.barelyThreshold("0.2"), 0.20)
        same(paths(Core.filterStatus(books, "barely")), { "/p3", "/p7" })
    end)
    it("shows a count on its chip", function()
        local c = Core.countFilters(books, 0.10)
        eq(c.barely, 2); eq(c.all, 10); eq(c.reading, 7); eq(c.unread, 1); eq(c.finished, 1)
        eq(Core.countFilters(books, 0.25).barely, 5)
    end)
    it("keeps percent through the index cache", function()
        local cached = Core.deserialize(Core.serialize({ entries = Core.toCacheEntries{
            bk{ path = "/p3", size = 1, modification = 1, status = "reading", percent = 0.03, cal = "s" },
        } }))
        local reused = Core.reconcile({ { path = "/p3", size = 1, modification = 1 } }, cached.entries, "s")
        eq(reused[1].percent, 0.03)
        eq(Core.isBarelyStarted(reused[1]), true)
        local _, stale = Core.reconcile({ { path = "/p3", size = 2, modification = 1 } }, cached.entries, "s")
        eq(stale[1].percent, 0.03) -- reading state survives a metadata refresh
    end)
end)

describe("resume", function()
    local books = {
        bk{ path = "/old", status = "reading", last_opened = 100, percent = 0.5 },
        bk{ path = "/fin", status = "complete", last_opened = 900 },
        bk{ path = "/new", status = "new", last_opened = 800 },
        bk{ path = "/now", status = "reading", last_opened = 500, percent = 0.2 },
        bk{ path = "/hold", status = "abandoned", last_opened = 950 },
        bk{ path = "/nohist", status = "reading", modification = 5 },
    }
    it("resumes the most recently opened book still being read", function()
        eq(Core.resumeBook(books).path, "/now")
        same(paths(Core.continueReading(books, 5)), { "/now", "/old", "/nohist" })
    end)
    it("has nothing to resume when no book is being read", function()
        eq(Core.resumeBook({ bk{ path = "/a", status = "complete" } }), nil)
        eq(Core.resumeBook({}), nil)
    end)
    it("says how long ago a book was read", function()
        eq(Core.relativeTime(1000, 1030), "just now")
        eq(Core.relativeTime(1000, 1000 + 5 * 60), "5 min ago")
        eq(Core.relativeTime(1000, 1000 + 3 * 3600 + 5), "3 h ago")
        eq(Core.relativeTime(1000, 1000 + 86400 + 10), "yesterday")
        eq(Core.relativeTime(1000, 1000 + 4 * 86400), "4 days ago")
        eq(Core.relativeTime(1000, 1000 + 40 * 86400), nil)
        eq(Core.relativeTime(nil, 1000), nil)
        eq(Core.relativeTime(2000, 1000), "just now") -- clock skew
    end)
    it("formats percent read", function()
        eq(Core.percentText(0.426), "43 %")
        eq(Core.percentText(1), "100 %")
        eq(Core.percentText(nil), nil)
    end)
end)

describe("reader menu Library tab", function()
    local function base() return { "navi", "typeset", "setting", "tools", "search", "filemanager", "main" } end
    it("goes just before the file browser tab", function()
        local b = Core.placeMenuButton(base(), "library_tab", "filemanager", true)
        eq(table.concat(b, ","), "navi,typeset,setting,tools,search,library_tab,filemanager,main")
    end)
    it("is added only once however often the menu is rebuilt", function()
        local b = base()
        Core.placeMenuButton(b, "library_tab", "filemanager", true)
        Core.placeMenuButton(b, "library_tab", "filemanager", true)
        eq(#b, 8)
    end)
    it("goes last when there is no file browser tab, and can be taken out", function()
        local b = Core.placeMenuButton({ "navi", "main" }, "library_tab", "filemanager", true)
        eq(table.concat(b, ","), "navi,main,library_tab")
        Core.placeMenuButton(b, "library_tab", "filemanager", false)
        eq(table.concat(b, ","), "navi,main")
    end)
end)

describe("sleep screen: cover of last book", function()
    local function store(init)
        local t = {}
        for k, v in pairs(init or {}) do t[k] = v end
        return t, {
            read = function(k) return t[k] end,
            save = function(k, v) t[k] = v end,
            del = function(k) t[k] = nil end,
        }
    end
    it("is off by default (KOReader's default sleep screen)", function()
        local _, gs = store{ screensaver_type = "disable" }
        eq(Core.sleepCoverOn(gs), false)
    end)
    it("turns on KOReader's cover sleep screen and restores the previous one", function()
        local t, gs = store{ screensaver_type = "random_image", screensaver_dir = "/pics" }
        local prev = Core.sleepCoverEnable(gs)
        eq(t.screensaver_type, "cover")
        eq(Core.sleepCoverOn(gs), true)
        Core.sleepCoverDisable(gs, prev)
        eq(t.screensaver_type, "random_image")
        eq(t.screensaver_dir, "/pics")
        eq(t.screensaver_hide_cover_in_filemanager, nil)
        eq(Core.sleepCoverOn(gs), false)
    end)
    it("shows the cover in the file browser too, and puts that option back", function()
        local t, gs = store{ screensaver_type = "cover", screensaver_hide_cover_in_filemanager = true }
        eq(Core.sleepCoverOn(gs), false)
        local prev = Core.sleepCoverEnable(gs)
        eq(t.screensaver_hide_cover_in_filemanager, false)
        eq(Core.sleepCoverOn(gs), true)
        Core.sleepCoverDisable(gs, prev)
        eq(t.screensaver_type, "cover")
        eq(t.screensaver_hide_cover_in_filemanager, true)
    end)
    it("restores an unset sleep screen as unset", function()
        local t, gs = store{}
        local prev = Core.sleepCoverEnable(gs)
        Core.sleepCoverDisable(gs, prev)
        eq(t.screensaver_type, nil)
    end)
    it("leaves settings alone when already on, and turns off to KOReader's default", function()
        local t, gs = store{ screensaver_type = "cover" }
        eq(Core.sleepCoverEnable(gs), nil)
        eq(t.screensaver_type, "cover")
        Core.sleepCoverDisable(gs, nil)
        eq(t.screensaver_type, "disable")
    end)
end)
