--- Reading statistics for the Reading log, read from KOReader's statistics DB.
-- Pure: no KOReader modules, so the specs can load it.
--
-- The database is settings/statistics.sqlite3. It is opened read-only.
-- Daily pages and time come from page_stat_data (one row per book, page
-- and sitting). If that table is not there, the same query uses the
-- page_stat view. The book table is read only to confirm this file is a
-- statistics database. A missing file, a locked file, or any other
-- database is a quiet empty result: the page still shows Continue reading.
--
-- The idea of a home reading log came from SimpleUI (GPL-3.0) and from
-- stevenzamora1/reading-log (AGPL-3.0). This file is original. Nothing
-- was copied from either project.

local Stats = {}

Stats.LIBRARY = "library"
Stats.READING_LOG = "reading_log"
Stats.NOTE = "Turn on Reading statistics"
Stats.GRID_BUTTON = "Log"
Stats.LIBRARY_BUTTON = "Library"
Stats.MENU = "Reading log"
Stats.QUICK_ACTION_ID = "library_gui_reading_log"
Stats.QUICK_ACTION_MODULE = "features/sui_quickactions"
-- Monday. KOReader's statistics calendar uses 1 = Sunday .. 7 = Saturday.
Stats.WEEK_START = 2

function Stats.dispatcherAction()
    return {
        id = "library_reading_log",
        event = "ShowReadingLog",
        title = "Open Reading log",
    }
end

--- "library" unless the saved choice is exactly "reading_log".
-- A settings table from before this choice has no home_page key.
function Stats.homePage(settings)
    if type(settings) == "table" and settings.home_page == Stats.READING_LOG then
        return Stats.READING_LOG
    end
    return Stats.LIBRARY
end

function Stats.homePageLabel(settings)
    if Stats.homePage(settings) == Stats.READING_LOG then return "Reading log" end
    return "Library"
end

--- 1..7, or Monday when the stored calendar start is missing or nonsense.
function Stats.weekStart(stored)
    local n = tonumber(stored)
    if n and n >= 1 and n <= 7 and n == math.floor(n) then return n end
    return Stats.WEEK_START
end

function Stats.dbPath(settings_dir)
    if type(settings_dir) ~= "string" or settings_dir == "" then return nil end
    if settings_dir:sub(-1) == "/" then return settings_dir .. "statistics.sqlite3" end
    return settings_dir .. "/statistics.sqlite3"
end

function Stats.parseYmd(text)
    if type(text) ~= "string" then return nil end
    local y, m, d = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
    return y, m, d
end

--- Whole days, so a daylight-saving shift does not break a streak.
function Stats.dayNumber(y, m, d)
    local a = math.floor((14 - m) / 12)
    local yy = y + 4800 - a
    local mm = m + 12 * a - 3
    return d + math.floor((153 * mm + 2) / 5) + 365 * yy
        + math.floor(yy / 4) - math.floor(yy / 100) + math.floor(yy / 400) - 32045
end

function Stats.ymd(now)
    return os.date("%Y-%m-%d", now or os.time())
end

local LETTER = { "S", "M", "T", "W", "T", "F", "S" }

--- The seven days of the calendar week that holds `now`, Monday first
-- unless week_start says otherwise. Future days are marked so they are
-- not drawn as missed days.
function Stats.weekDays(now, week_start)
    now = tonumber(now) or os.time()
    local t = os.date("*t", now)
    week_start = Stats.weekStart(week_start)
    local back = (t.wday - week_start) % 7
    local days = {}
    for i = 0, 6 do
        local dt = os.time{
            year = t.year, month = t.month, day = t.day - back + i, hour = 12,
        }
        local wday = tonumber(os.date("%w", dt)) + 1
        days[i + 1] = {
            day = os.date("%Y-%m-%d", dt),
            label = LETTER[wday] or "",
            today = i == back,
            future = i > back,
            pages = 0,
            seconds = 0,
        }
    end
    return days
end

--- Consecutive reading days ending today, or yesterday if today is still
-- empty. A day with any reading counts. A gap ends the run.
function Stats.currentStreak(days, today_ymd)
    local y, m, d = Stats.parseYmd(today_ymd)
    if not y then return 0 end
    local today_n = Stats.dayNumber(y, m, d)
    local nums, seen = {}, {}
    for _, text in ipairs(days or {}) do
        local yy, mm, dd = Stats.parseYmd(text)
        if yy and not seen[text] then
            seen[text] = true
            nums[#nums + 1] = Stats.dayNumber(yy, mm, dd)
        end
    end
    table.sort(nums)
    if #nums == 0 then return 0 end
    local last = nums[#nums]
    if last ~= today_n and last ~= today_n - 1 then return 0 end
    local streak = 1
    for i = #nums - 1, 1, -1 do
        if nums[i] == nums[i + 1] - 1 then
            streak = streak + 1
        elseif nums[i] ~= nums[i + 1] then
            break
        end
    end
    return streak
end

local function blankWeek(now, week_start)
    return {
        days = Stats.weekDays(now, week_start),
        pages = 0,
        seconds = 0,
        average_pages = 0,
        average_seconds = 0,
    }
end

function Stats.missing(now, week_start)
    return {
        ok = false,
        missing = true,
        note = Stats.NOTE,
        today = { pages = 0, seconds = 0 },
        week = blankWeek(now, week_start),
        streak = 0,
    }
end

--- `by_day` maps "YYYY-MM-DD" to { pages =, seconds = }.
-- `read_days` is every day that has any reading, including days older
-- than the week. When it is omitted, the keys of `by_day` are the days.
function Stats.summarize(by_day, read_days, now, week_start)
    now = tonumber(now) or os.time()
    by_day = type(by_day) == "table" and by_day or {}
    local today_key = Stats.ymd(now)
    local today_row = by_day[today_key] or {}
    local week = Stats.weekDays(now, week_start)
    local pages, seconds, elapsed = 0, 0, 0
    for _, day in ipairs(week) do
        local row = by_day[day.day]
        if row then
            day.pages = math.floor(tonumber(row.pages) or 0)
            day.seconds = math.floor(tonumber(row.seconds) or 0)
            if day.pages < 0 then day.pages = 0 end
            if day.seconds < 0 then day.seconds = 0 end
        end
        if not day.future then
            elapsed = elapsed + 1
            pages = pages + day.pages
            seconds = seconds + day.seconds
        end
    end
    if elapsed < 1 then elapsed = 1 end
    if not read_days then
        read_days = {}
        for key in pairs(by_day) do read_days[#read_days + 1] = key end
    end
    return {
        ok = true,
        missing = false,
        note = nil,
        today = {
            pages = math.max(0, math.floor(tonumber(today_row.pages) or 0)),
            seconds = math.max(0, math.floor(tonumber(today_row.seconds) or 0)),
        },
        week = {
            days = week,
            pages = pages,
            seconds = seconds,
            average_pages = math.floor(pages / elapsed),
            average_seconds = math.floor(seconds / elapsed),
        },
        streak = Stats.currentStreak(read_days, today_key),
    }
end

--- 0..1 of the tallest day this week, so the bars share one scale.
-- Future days and an empty week are 0.
function Stats.barFractions(days)
    local peak = 0
    for _, day in ipairs(days or {}) do
        local pages = tonumber(day.pages) or 0
        if not day.future and pages > peak then peak = pages end
    end
    local out = {}
    for i, day in ipairs(days or {}) do
        if day.future or peak <= 0 then
            out[i] = 0
        else
            out[i] = (tonumber(day.pages) or 0) / peak
        end
    end
    return out
end

function Stats.minutes(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return 0 end
    return math.floor(seconds / 60 + 0.5)
end

function Stats.durationLabel(seconds)
    local mins = Stats.minutes(seconds)
    if mins < 60 then return string.format("%d min", mins) end
    local hours = math.floor(mins / 60)
    local rem = mins % 60
    if rem == 0 then return string.format("%d h", hours) end
    return string.format("%d h %d min", hours, rem)
end

function Stats.pagesLabel(n)
    n = math.floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    if n == 1 then return "1 page" end
    return string.format("%d pages", n)
end

function Stats.streakLabel(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return "No streak yet" end
    if n == 1 then return "1-day streak" end
    return string.format("%d-day streak", n)
end

function Stats.todayLine(today)
    today = today or {}
    return Stats.pagesLabel(today.pages) .. " · " .. Stats.durationLabel(today.seconds)
end

function Stats.weekTotalLine(week)
    week = week or {}
    return Stats.pagesLabel(week.pages) .. " · " .. Stats.durationLabel(week.seconds)
end

function Stats.weekAverageLine(week)
    week = week or {}
    return "avg " .. Stats.pagesLabel(week.average_pages) .. " · " .. Stats.durationLabel(week.average_seconds)
end

local TABLES = { page_stat_data = true, page_stat = true }

function Stats.bookSQL()
    return "SELECT COUNT(*) FROM book"
end

--- Pages are distinct (book, page) pairs that day. Time is the sum of
-- the sittings, including a page opened more than once.
function Stats.dailySQL(table_name, since)
    if not TABLES[table_name] then return nil end
    since = math.floor(tonumber(since) or 0)
    return string.format(
        "SELECT day, SUM(secs), COUNT(*) FROM ("
        .. "SELECT id_book, page, strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day, "
        .. "SUM(duration) AS secs FROM %s WHERE start_time >= %d AND duration > 0 "
        .. "GROUP BY id_book, page, day) AS daily_pages GROUP BY day ORDER BY day",
        table_name, since)
end

--- lua-ljsqlite3 hands back one array per column. A test double may do
-- the same. An empty result is an empty list.
function Stats.columnsToRows(result)
    if type(result) ~= "table" then return {} end
    if type(result[1]) ~= "table" then
        if result[1] == nil then return {} end
        return { { result[1] } }
    end
    local cols = #result
    local n = #result[1]
    local rows = {}
    for r = 1, n do
        local row = {}
        for c = 1, cols do row[c] = result[c][r] end
        rows[r] = row
    end
    return rows
end

local function asDay(value)
    if type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d$") then return value end
    if value == nil or type(value) == "table" then return nil end
    local text = tostring(value)
    if text:match("^%d%d%d%d%-%d%d%-%d%d$") then return text end
    return nil
end

local function dayMap(result)
    local map = {}
    for _, row in ipairs(Stats.columnsToRows(result)) do
        local day = asDay(row[1])
        if day then
            map[day] = {
                seconds = tonumber(row[2]) or 0,
                pages = tonumber(row[3]) or 0,
            }
        end
    end
    return map
end

--- `exec(sql)` runs one statement. It may throw. Nil means no rows.
-- One query lists every reading day with its pages and seconds. The
-- streak is those days.
function Stats.read(exec, now, week_start)
    if type(exec) ~= "function" then return Stats.missing(now, week_start) end
    local book_ok = pcall(exec, Stats.bookSQL())
    if not book_ok then return Stats.missing(now, week_start) end
    local function pull(table_name)
        local daily_ok, daily = pcall(exec, Stats.dailySQL(table_name, 0))
        if not daily_ok then return nil end
        local map = dayMap(daily)
        local list = {}
        for day in pairs(map) do list[#list + 1] = day end
        return map, list
    end
    local by_day, read_days = pull("page_stat_data")
    if not by_day then
        by_day, read_days = pull("page_stat")
    end
    if not by_day then return Stats.missing(now, week_start) end
    return Stats.summarize(by_day, read_days, now, week_start)
end

function Stats.openReadOnly(path)
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(path, "ro")
    pcall(function() conn:exec("PRAGMA query_only=ON;") end)
    pcall(function() conn:exec("PRAGMA busy_timeout=200;") end)
    return conn
end

--- Read `path`, or the quiet empty result when it is not a statistics DB.
-- `opener(path)` defaults to KOReader's read-only SQLite open.
function Stats.loadPath(path, now, week_start, opener)
    if type(path) ~= "string" or path == "" then return Stats.missing(now, week_start) end
    local file = io.open(path, "rb")
    if not file then return Stats.missing(now, week_start) end
    file:close()
    opener = opener or Stats.openReadOnly
    local opened, conn = pcall(opener, path)
    -- lua-ljsqlite3's connection is cdata, not a table. Any object with
    -- exec is enough; a failed open is not.
    if not opened or not conn or type(conn.exec) ~= "function" then
        return Stats.missing(now, week_start)
    end
    local function exec(sql)
        return conn:exec(sql)
    end
    local ok, summary = pcall(Stats.read, exec, now, week_start)
    if conn.close then pcall(conn.close, conn) end
    if not ok or type(summary) ~= "table" then return Stats.missing(now, week_start) end
    return summary
end

--- The descriptor SimpleUI's QA.register accepts. `run` opens the log.
-- Registered only when that module is actually installed.
function Stats.quickAction(run)
    return {
        id = Stats.QUICK_ACTION_ID,
        label = Stats.MENU,
        is_in_place = false,
        execute = function()
            if run then return run() end
        end,
    }
end

return Stats
