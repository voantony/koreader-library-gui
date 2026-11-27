-- Reading log: statistics from KOReader's database, the home-page choice,
-- and every way onto the page.
local Stats = require("librarystats")
local Return = require("libraryreturn")

local NOW = os.time{ year = 2026, month = 11, day = 27, hour = 15, min = 0, sec = 0 }

describe("Home page setting", function()
    it("stays on the Library when nothing is saved", function()
        eq(Stats.homePage(nil), "library")
        eq(Stats.homePage({}), "library")
        eq(Stats.homePage({ on_startup = "library", after_close = "library" }), "library")
        eq(Stats.homePageLabel({}), "Library")
    end)

    it("accepts reading_log and ignores anything else", function()
        eq(Stats.homePage({ home_page = "reading_log" }), "reading_log")
        eq(Stats.homePageLabel({ home_page = "reading_log" }), "Reading log")
        eq(Stats.homePage({ home_page = "library" }), "library")
        eq(Stats.homePage({ home_page = "log" }), "library")
        eq(Stats.homePage({ home_page = "" }), "library")
    end)

    it("does not add a startup or return mode", function()
        eq(Return.plan{
            first = true, home = true, start_with = "library",
        }, "show")
        eq(Return.afterClose(nil, nil), "library")
        eq(Return.LIBRARY, "library")
    end)
end)

describe("Reading log totals and streak", function()
    it("sums today and this week, and keeps a streak through yesterday", function()
        -- Friday 27 Nov 2026. The week is Monday 23 through Sunday 29.
        local by_day = {
            ["2026-11-27"] = { pages = 2, seconds = 360 },
            ["2026-11-26"] = { pages = 1, seconds = 600 },
            ["2026-11-24"] = { pages = 1, seconds = 60 },
            ["2026-11-20"] = { pages = 4, seconds = 30 },
        }
        local summary = Stats.summarize(by_day, nil, NOW, 2)
        eq(summary.missing, false)
        eq(summary.today.pages, 2)
        eq(summary.today.seconds, 360)
        eq(summary.week.pages, 4)
        eq(summary.week.seconds, 1020)
        eq(summary.week.average_pages, 0)
        eq(summary.week.average_seconds, 204)
        eq(#summary.week.days, 7)
        eq(summary.week.days[1].day, "2026-11-23")
        eq(summary.week.days[5].today, true)
        eq(summary.week.days[6].future, true)
        eq(summary.week.days[6].pages, 0)
        eq(summary.streak, 2)
        eq(Stats.todayLine(summary.today), "2 pages · 6 min")
        eq(Stats.weekTotalLine(summary.week), "4 pages · 17 min")
        eq(Stats.streakLabel(summary.streak), "2-day streak")
        local bars = Stats.barFractions(summary.week.days)
        eq(bars[5], 1)
        eq(bars[6], 0)
        eq(bars[7], 0)
    end)

    it("counts a streak that ended yesterday, and stops at a gap", function()
        eq(Stats.currentStreak({ "2026-11-25", "2026-11-26" }, "2026-11-27"), 2)
        eq(Stats.currentStreak({ "2026-11-27" }, "2026-11-27"), 1)
        eq(Stats.currentStreak({ "2026-11-20", "2026-11-21", "2026-11-22" }, "2026-11-27"), 0)
        eq(Stats.currentStreak({}, "2026-11-27"), 0)
        eq(Stats.streakLabel(0), "No streak yet")
        eq(Stats.streakLabel(1), "1-day streak")
    end)

    it("labels one page and a short sitting as a minute", function()
        eq(Stats.pagesLabel(0), "0 pages")
        eq(Stats.pagesLabel(1), "1 page")
        eq(Stats.durationLabel(0), "0 min")
        eq(Stats.durationLabel(30), "1 min")
        eq(Stats.durationLabel(3600), "1 h")
        eq(Stats.durationLabel(5400), "1 h 30 min")
    end)
end)

describe("Reading statistics database", function()
    local function column(rows)
        if #rows == 0 then return {} end
        local out = {}
        for c = 1, #rows[1] do
            out[c] = {}
            for r = 1, #rows do out[c][r] = rows[r][c] end
        end
        return out
    end

    it("returns the quiet note when the file is missing", function()
        local summary = Stats.loadPath("/tmp/koreader-library-gui-no-such-statistics.sqlite3", NOW, 2)
        eq(summary.missing, true)
        eq(summary.ok, false)
        eq(summary.note, "Turn on Reading statistics")
        eq(summary.streak, 0)
        eq(summary.today.pages, 0)
        eq(#summary.week.days, 7)
    end)

    it("returns the quiet note when the file is not a statistics database", function()
        local summary = Stats.read(function() error("no such table: book") end, NOW, 2)
        eq(summary.missing, true)
        eq(summary.note, "Turn on Reading statistics")
    end)

    it("reads an empty database as zeroes, not as a missing plugin", function()
        local function exec(sql)
            if sql:find("COUNT", 1, true) then return column({ { 0 } }) end
            return {}
        end
        local summary = Stats.read(exec, NOW, 2)
        eq(summary.missing, false)
        eq(summary.today.pages, 0)
        eq(summary.today.seconds, 0)
        eq(summary.week.pages, 0)
        eq(summary.streak, 0)
        eq(summary.note, nil)
    end)

    it("treats a missing page_stat_data table as no statistics", function()
        local function exec(sql)
            if sql:find("page_stat_data", 1, true) then error("no such table: page_stat_data") end
            if sql:find("FROM book", 1, true) then return column({ { 1 } }) end
            error("unexpected " .. sql)
        end
        local summary = Stats.read(exec, NOW, 2)
        eq(summary.missing, true)
        eq(summary.note, "Turn on Reading statistics")
    end)

    it("queries a fixture database for pages, time and the streak", function()
        local path = os.tmpname() .. "-reading-log.sqlite3"
        os.remove(path)
        local function sql(statement)
            local cmd = string.format("env -u LD_LIBRARY_PATH sqlite3 -separator '|' %q %q", path, statement)
            local handle = io.popen(cmd, "r")
            local text = handle:read("*a") or ""
            local closed = handle:close()
            if not closed then error(text) end
            return text
        end
        sql([[
CREATE TABLE book (
    id integer PRIMARY KEY,
    title text,
    authors text,
    notes integer,
    last_open integer,
    highlights integer,
    pages integer,
    series text,
    language text,
    md5 text,
    total_read_time integer,
    total_read_pages integer
);
CREATE TABLE page_stat_data (
    id_book integer,
    page integer NOT NULL DEFAULT 0,
    start_time integer NOT NULL DEFAULT 0,
    duration integer NOT NULL DEFAULT 0,
    total_pages integer NOT NULL DEFAULT 0
);
]])
        local function at(day, hour)
            return os.time{ year = 2026, month = 11, day = day, hour = hour or 15, min = 0, sec = 0 }
        end
        local function insert(page, day, hour, duration)
            sql(string.format(
                "INSERT INTO page_stat_data (id_book, page, start_time, duration, total_pages) VALUES (1, %d, %d, %d, 100);",
                page, at(day, hour), duration))
        end
        insert(1, 27, 10, 120)
        insert(1, 27, 11, 60)
        insert(2, 27, 12, 180)
        insert(3, 27, 13, 0)
        insert(1, 26, 15, 600)
        insert(1, 24, 15, 60)
        insert(1, 20, 15, 30)
        sql("INSERT INTO book (id, title, authors, md5, total_read_time, total_read_pages) VALUES (1, 'Fixture', 'Tester', 'abc', 900, 4);")
        local conn = {
            exec = function(_, statement)
                local text = sql(statement)
                if text == "" then return {} end
                local rows = {}
                for line in text:gmatch("[^\n]+") do
                    local cols = {}
                    for field in (line .. "|"):gmatch("(.-)|") do
                        local n = tonumber(field)
                        cols[#cols + 1] = n or field
                    end
                    rows[#rows + 1] = cols
                end
                return column(rows)
            end,
            close = function() end,
        }
        local summary = Stats.loadPath(path, NOW, 2, function() return conn end)
        os.remove(path)
        eq(summary.missing, false)
        eq(summary.today.pages, 2)
        eq(summary.today.seconds, 360)
        eq(summary.week.pages, 4)
        eq(summary.week.seconds, 1020)
        eq(summary.streak, 2)
        eq(Stats.dailySQL("page_stat_data", 0):find("page_stat_data", 1, true) ~= nil, true)
        eq(Stats.dailySQL("page_stat", 0), nil)
        eq(Stats.bookSQL():find("book", 1, true) ~= nil, true)
        eq(Stats.dbPath("/mnt/us/koreader/settings"), "/mnt/us/koreader/settings/statistics.sqlite3")
    end)
end)

describe("Reading log styles", function()
    it("keeps Standard, the cover row, and both goals off until chosen", function()
        eq(Stats.statsStyle(nil), "standard")
        eq(Stats.statsStyle({}), "standard")
        eq(Stats.statsStyle({ stats_style = "nope" }), "standard")
        eq(Stats.statsStyle({ stats_style = "minimal" }), "minimal")
        eq(Stats.statsStyle({ stats_style = "detailed" }), "detailed")
        eq(Stats.statsStyleLabel("standard"), "Standard")
        eq(Stats.continueStyle({}), "row")
        eq(Stats.continueStyle({ continue_style = "card" }), "card")
        eq(Stats.goalOf({}), nil)
        eq(Stats.goalOf({ daily_goal_on = true, daily_goal_unit = "minutes", daily_goal = 30 }).amount, 30)
        eq(Stats.yearGoalOf({}), nil)
        eq(Stats.yearGoalOf({ yearly_goal_on = true, yearly_goal = 12 }).amount, 12)
    end)

    it("marks a read day, an empty day, and today in progress", function()
        eq(Stats.dayMark({ pages = 2 }), "filled")
        eq(Stats.dayMark({ pages = 0, seconds = 0 }), "outline")
        eq(Stats.dayMark({ today = true, pages = 1 }), "partial")
        eq(Stats.dayMark({ today = true, pages = 0, seconds = 0 }), "outline")
        eq(Stats.dayMark({ future = true, pages = 4 }), "outline")
    end)

    it("writes the today line, the one average line, and the minimal line", function()
        local summary = {
            today = { pages = 46, seconds = 110 * 60 },
            week = { pages = 322, seconds = 110 * 60, average_pages = 46, average_seconds = 110 * 60 },
            streak = 12,
        }
        eq(Stats.todayBrief(summary.today), "1 h 50 m · 46 pages")
        eq(Stats.averageLine(summary.week), "1 h 50 m · 46 pages a day on average")
        eq(Stats.minimalLine(summary), "Today 1 h 50 m · This week 1 h 50 m · 12-day streak")
        eq(Stats.streakCaption(12, 41), "12-day streak · best 41")
    end)

    it("counts finished books only when the sidecar time is in that year", function()
        local this_year = os.time{ year = 2026, month = 3, day = 2, hour = 12 }
        local last_year = os.time{ year = 2025, month = 12, day = 1, hour = 12 }
        local n = Stats.finishedThisYear({
            { status = "complete", finished_at = this_year },
            { status = "complete", finished_at = last_year },
            { status = "complete" },
            { status = "reading", finished_at = this_year },
        }, 2026)
        eq(n, 1)
        eq(Stats.yearFraction(6, 12), 0.5)
        local year = Stats.yearTotals({
            ["2026-11-27"] = { pages = 2, seconds = 60 },
            ["2025-11-27"] = { pages = 9, seconds = 60 },
        }, os.time{ year = 2026, month = 11, day = 27, hour = 12 })
        eq(year.days, 1)
        eq(year.pages, 2)
    end)

    it("hides a forecast without enough recent pages, and shows one when the pace is there", function()
        local book = { title = "The Prince and the Pauper", pages = 320, percent = 0.25 }
        eq(Stats.forecast(book, { pages = 4 }, NOW), nil)
        local line = Stats.forecast(book, { pages = 14 }, NOW)
        eq(type(line) == "string" and line:find("The Prince and the Pauper", 1, true) ~= nil, true)
        eq(line:find("done by", 1, true) ~= nil, true)
    end)

    it("uses five covers on the Colorsoft and four on a narrow screen", function()
        eq(Stats.coverCount(1264), 5)
        eq(Stats.coverCount(758), 4)
    end)
end)

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o) o = o or {}; return setmetatable(o, self) end
    return base
end

local function load(file, extra)
    local old_require = require
    local real = {
        librarycore = true, librarystats = true, libraryreturn = true,
        string = true, table = true, math = true, io = true, os = true,
    }
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

describe("Reading log layout", function()
    it("keeps every reading-log cover whole at 2:3", function()
        eq(Stats.readingMargin(758), 18)
        eq(Stats.readingMargin(1264), 36)
        for _, width in ipairs({ 1264, 758 }) do
            local inner = width - 2 * Stats.readingMargin(width)
            local ideal = Stats.fitCovers(inner, { n = 5, scale = 1, row_gap = 12 })
            eq(ideal.n, 5)
            eq(ideal.cropped, false)
            eq(ideal.feat_h, math.floor(ideal.feat_w * 3 / 2))
            eq(ideal.row_h, math.floor(ideal.slot * 3 / 2))
            eq(math.abs(ideal.feat_w - math.floor(inner * 0.20)) <= 1, true)
            eq(ideal.n * ideal.slot + (ideal.n - 1) * ideal.row_gap <= inner, true)
            for _, n in ipairs({ 5, 4 }) do
                for _, scale in ipairs({ 1, 0.85, 0.7 }) do
                    local plan = Stats.fitCovers(inner, { n = n, scale = scale, row_gap = 12 })
                    eq(plan.cropped, false)
                    eq(plan.feat_h, math.floor(plan.feat_w * 3 / 2))
                    eq(plan.row_h, math.floor(plan.slot * 3 / 2))
                    eq(plan.n * plan.slot + (plan.n - 1) * plan.row_gap <= inner, true)
                end
            end
            local card = Stats.fitCovers(inner, { card = true, scale = 1 })
            eq(card.feat_h, math.floor(card.feat_w * 3 / 2))
            eq(card.n, 0)
        end
    end)

    it("gives a narrow screen a smaller today figure and a wide screen a larger one", function()
        local small = Stats.pageLayout(758)
        local large = Stats.pageLayout(1264)
        eq(small.narrow, true)
        eq(large.narrow, false)
        eq(small.today_size < large.today_size, true)
        eq(small.cover_w >= 104, true)
        eq(large.cover_w <= 200, true)
        eq(small.margin < large.margin, true)
    end)
    it("lines the seven day labels up on the bars", function()
        local slot, cols = Stats.chartColumns(700, 8)
        eq(#cols, 7)
        eq(cols[1], 0)
        eq(cols[2], slot + 8)
        eq(cols[7] + slot <= 700, true)
    end)
end)

describe("Reading log provider", function()
    it("stays on the built-in log until a provider is saved", function()
        eq(Stats.provider(nil), "builtin")
        eq(Stats.provider({}), "builtin")
        eq(Stats.providerLabel({}), "Built-in")
        eq(Stats.route({}, {}).target, "builtin")
    end)
    it("opens the Reading Log plugin when it is installed, and falls back when it is not", function()
        local settings = { reading_log_provider = "readinglog" }
        local open = Stats.route(settings, { readinglog = true })
        eq(open.target, "readinglog")
        eq(open.event, "ReadingLogDashboard")
        local missing = Stats.route(settings, { readinglog = false })
        eq(missing.target, "builtin")
        eq(missing.fallback, true)
        eq(missing.toast, Stats.READINGLOG_MISSING)
    end)
    it("runs a named dispatcher action, and falls back when the name is missing", function()
        eq(Stats.actionEvent({ reading_log_action = "  ReadingLogDashboard  " }), "ReadingLogDashboard")
        eq(Stats.actionEvent({ reading_log_action = "not an event" }), nil)
        eq(Stats.actionEvent({ reading_log_action = "" }), nil)
        local settings = { reading_log_provider = "action", reading_log_action = "ShowCatalog" }
        local open = Stats.route(settings, {})
        eq(open.target, "action")
        eq(open.event, "ShowCatalog")
        local missing = Stats.route({ reading_log_provider = "action" }, {})
        eq(missing.target, "builtin")
        eq(missing.fallback, true)
        eq(missing.toast, Stats.ACTION_MISSING)
        local refused = Stats.route(settings, { action_ok = false })
        eq(refused.target, "builtin")
        eq(refused.fallback, true)
    end)
end)

describe("Ways onto the Reading log", function()
    it("offers Reading log and Home page in the KOReader menu, next to startup", function()
        local Library = load("main.lua", {})
        local saved
        local self = setmetatable({
            ui = {},
            settings = {},
            saveSettings = function(s) saved = s.settings.home_page end,
            showReadingLog = function() return "opened" end,
        }, { __index = Library })
        local items = {}
        Library.addToMainMenu(self, items)
        local rows = items.library.sub_item_table
        local reading, home, provider, style, daily, cont, yearly, after, startup
        local ri, hi, pi, sti, di, ci, yi, ai, si
        for i, entry in ipairs(rows) do
            if entry.text == "Reading log" then reading, ri = entry, i end
            if entry.text_func and entry.text_func():find("Home page", 1, true) == 1 then home, hi = entry, i end
            if entry.text_func and entry.text_func():find("Reading log provider", 1, true) == 1 then provider, pi = entry, i end
            if entry.text_func and entry.text_func():find("Stats style", 1, true) == 1 then style, sti = entry, i end
            if entry.text_func and entry.text_func():find("Daily goal", 1, true) == 1 then daily, di = entry, i end
            if entry.text_func and entry.text_func():find("Continue reading", 1, true) == 1 then cont, ci = entry, i end
            if entry.text_func and entry.text_func():find("Yearly book goal", 1, true) == 1 then yearly, yi = entry, i end
            if entry.text_func and entry.text_func():find("After closing a book", 1, true) == 1 then after, ai = entry, i end
            if entry.text_func and entry.text_func():find("On startup", 1, true) == 1 then startup, si = entry, i end
        end
        eq(reading ~= nil, true)
        eq(home ~= nil, true)
        eq(provider ~= nil, true)
        eq(style ~= nil, true)
        eq(daily ~= nil, true)
        eq(cont ~= nil, true)
        eq(yearly ~= nil, true)
        eq(after ~= nil, true)
        eq(startup ~= nil, true)
        eq(hi, ri + 1)
        eq(pi, hi + 1)
        eq(sti, pi + 1)
        eq(di, sti + 1)
        eq(ci, di + 1)
        eq(yi, ci + 1)
        eq(ai, yi + 1)
        eq(si, ai + 1)
        eq(style.text_func(), "Stats style: Standard")
        eq(style.sub_item_table[1].text, "Standard")
        eq(style.sub_item_table[1].checked_func(), true)
        eq(daily.text_func(), "Daily goal: Off")
        eq(cont.text_func(), "Continue reading: Cover row")
        eq(yearly.text_func(), "Yearly book goal: Off")
        eq(provider.text_func(), "Reading log provider: Built-in")
        eq(provider.sub_item_table[1].text, "Built-in")
        eq(provider.sub_item_table[2].text, "Reading Log plugin")
        eq(provider.sub_item_table[1].checked_func(), true)
        eq(home.text_func(), "Home page: Library")
        eq(home.sub_item_table[1].text, "Library")
        eq(home.sub_item_table[2].text, "Reading log")
        eq(home.sub_item_table[1].checked_func(), true)
        local opened
        self.showReadingLog = function() opened = true return "opened" end
        reading.callback()
        eq(opened, true)
        home.sub_item_table[2].callback()
        eq(self.settings.home_page, "reading_log")
        eq(saved, "reading_log")
        eq(home.sub_item_table[2].checked_func(), true)
        eq(home.text_func(), "Home page: Reading log")
        eq(self:wantsReadingLog(false, {}), true)
        eq(self:wantsReadingLog(false, { grid = true }), false)
        eq(self:wantsReadingLog(true, {}), false)
        self.settings.home_page = nil
        eq(self:wantsReadingLog(false, {}), false)
        Library.shared.prefer_log = true
        eq(self:wantsReadingLog(false, {}), true)
        eq(self:wantsReadingLog(false, { grid = true }), false)
        Library.shared.prefer_log = nil
    end)

    it("opens the grid from the Reading log, and the log from the grid", function()
        local opened_grid, opened_log = false, false
        local UIManager = {
            nextTick = function(_, fn) fn() end,
            scheduleIn = function() end,
            unschedule = function() end,
            show = function() end,
            close = function() end,
            setDirty = function() end,
        }
        local Log = load("libraryreadinglog.lua", { ["ui/uimanager"] = UIManager })
        local log = {
            plugin = { onOpenLibraryGrid = function() opened_grid = true return true end },
        }
        Log.onOpenLibrary(log)
        eq(opened_grid, true)
        local View = load("libraryview.lua", { ["ui/uimanager"] = UIManager })
        local grid = {
            plugin = { onShowReadingLog = function() opened_log = true return true end },
        }
        View.onOpenReadingLog(grid)
        eq(opened_log, true)
    end)

    it("registers an Open Reading log dispatcher action", function()
        local Library = load("main.lua", {})
        local actions = {}
        local self = setmetatable({
            dispatcher = {
                registerAction = function(_, id, spec) actions[id] = spec end,
            },
            showReadingLog = function(_, opts) return opts end,
        }, { __index = Library })
        Library.onDispatcherRegisterActions(self)
        local action = Stats.dispatcherAction()
        eq(actions[action.id].event, "ShowReadingLog")
        eq(actions[action.id].title, "Open Reading log")
        eq(actions[action.id].general, true)
        eq(actions.library_show.event, "ShowLibrary")
        local opts = Library.onShowReadingLog(self)
        eq(opts.full, true)
    end)

    it("registers a SimpleUI quick action when that module is present", function()
        local Library = load("main.lua", {})
        Library.shared.sui_reading_log = nil
        local registered = {}
        local QA = {
            register = function(descriptor) registered[#registered + 1] = descriptor end,
        }
        local shown = 0
        local self = setmetatable({
            onShowReadingLog = function() shown = shown + 1 return true end,
        }, { __index = Library })
        eq(Library.simpleUIModule(), nil)
        local descriptor = Library.registerSimpleUIQuickAction(self, QA)
        eq(descriptor.id, "library_gui_reading_log")
        eq(descriptor.label, "Reading log")
        eq(descriptor.is_in_place, false)
        local key = "apps/filemanager/filemanager"
        local previous = package.loaded[key]
        package.loaded[key] = { instance = { library = self } }
        descriptor.execute()
        package.loaded[key] = previous
        eq(shown, 1)
        local again = Library.registerSimpleUIQuickAction(self, QA)
        eq(again, descriptor)
        eq(#registered, 1)
        Library.shared.sui_reading_log = nil
    end)

    it("sends every entry point to the chosen provider and falls back to the built-in log", function()
        local Library = load("main.lua", {})
        local toasts = {}
        local plugin_opened = false
        local builtin = false
        local self = setmetatable({
            ui = {
                readinglog = {
                    onReadingLogDashboard = function() plugin_opened = true return true end,
                },
                handleEvent = function() return true end,
            },
            settings = { home_page = "reading_log", reading_log_provider = "readinglog" },
            saveSettings = function() end,
            showReadingLog = function() builtin = true return true end,
            showReadingLogToast = function(_, text) toasts[#toasts + 1] = text end,
        }, { __index = Library })
        eq(Library.onShowReadingLog(self), true)
        eq(plugin_opened, true)
        eq(builtin, false)
        eq(Library.onShowLibrary(self, false, { full = true }), true)
        eq(builtin, false)
        self.ui.readinglog = nil
        Library.onShowReadingLog(self)
        eq(builtin, true)
        eq(toasts[#toasts], Stats.READINGLOG_MISSING)
        builtin = false
        self.settings.reading_log_provider = "action"
        self.settings.reading_log_action = "ShowCatalog"
        local seen
        self.ui.handleEvent = function(_, ev) seen = ev return true end
        eq(Library.onShowReadingLog(self), true)
        eq(seen ~= nil, true)
        eq(builtin, false)
        self.ui.handleEvent = function() return false end
        Library.onShowReadingLog(self)
        eq(builtin, true)
        eq(toasts[#toasts], Stats.ACTION_MISSING)
        Library.shared.prefer_log = nil
        Library.shared.log = nil
    end)

    it("opens the Reading log from startup when that is the home page", function()
        local Library = load("main.lua", {})
        local shown
        local self = setmetatable({
            ui = {},
            settings = { home_page = "reading_log" },
            showReadingLog = function(_, opts) shown = opts return true end,
        }, { __index = Library })
        Library.shared.prefer_log = nil
        Library.shared.log = nil
        eq(Library.onShowLibrary(self, false, { full = true }), true)
        eq(shown.full, true)
        eq(self:wantsReadingLog(false, { grid = true }), false)
    end)
end)
