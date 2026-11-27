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
        best = 0,
        previous_seconds = 0,
        month = Stats.monthGrid({}, now, week_start),
        year = Stats.yearTotals({}, now),
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
        previous_seconds = Stats.previousWeekSeconds(by_day, now, week_start),
        month = Stats.monthGrid(by_day, now, week_start),
        year = Stats.yearTotals(by_day, now),
        best = Stats.longestRun(read_days),
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

function Stats.streakCaption(streak, best)
    streak = math.floor(tonumber(streak) or 0)
    best = math.floor(tonumber(best) or 0)
    if best < streak then best = streak end
    if streak <= 0 and best <= 0 then return "No streak yet" end
    if streak <= 0 then return string.format("Best %d", best) end
    if streak == 1 then return string.format("1-day streak · best %d", best) end
    return string.format("%d-day streak · best %d", streak, best)
end

--- The saved record, raised when this series shows a longer run.
function Stats.rememberBest(stored, streak, longest)
    local best = math.floor(tonumber(stored) or 0)
    if best < 0 then best = 0 end
    streak = math.floor(tonumber(streak) or 0)
    longest = math.floor(tonumber(longest) or 0)
    if streak > best then best = streak end
    if longest > best then best = longest end
    return best
end

function Stats.longestRun(days)
    local nums, seen = {}, {}
    for _, text in ipairs(days or {}) do
        local y, m, d = Stats.parseYmd(text)
        if y and not seen[text] then
            seen[text] = true
            nums[#nums + 1] = Stats.dayNumber(y, m, d)
        end
    end
    table.sort(nums)
    local best, run = 0, 0
    for i, n in ipairs(nums) do
        if i > 1 and n == nums[i - 1] + 1 then run = run + 1 else run = 1 end
        if run > best then best = run end
    end
    return best
end

function Stats.previousWeekSeconds(by_day, now, week_start)
    by_day = type(by_day) == "table" and by_day or {}
    local week = Stats.weekDays(now, week_start)
    local y, m, d = Stats.parseYmd(week[1] and week[1].day)
    if not y then return 0 end
    local total = 0
    for i = 1, 7 do
        local key = os.date("%Y-%m-%d", os.time{ year = y, month = m, day = d - i, hour = 12 })
        local row = by_day[key]
        if row then total = total + math.max(0, math.floor(tonumber(row.seconds) or 0)) end
    end
    return total
end

--- "2 h 10 m" / "25 min" / "2 h". Used in the quiet week caption.
function Stats.weekHours(seconds)
    local mins = Stats.minutes(seconds)
    if mins < 60 then return string.format("%d min", mins) end
    local hours = math.floor(mins / 60)
    local rem = mins % 60
    if rem == 0 then return string.format("%d h", hours) end
    return string.format("%d h %d m", hours, rem)
end

function Stats.weekCompareLine(this_seconds, last_seconds)
    local head = Stats.weekHours(this_seconds) .. " this week"
    local delta = Stats.minutes(this_seconds) - Stats.minutes(last_seconds)
    if delta > 0 then return head .. " · " .. delta .. " min more than last" end
    if delta < 0 then return head .. " · " .. (-delta) .. " min less than last" end
    return head .. " · the same as last"
end

--- Off unless daily_goal_on is true and the amount is a whole number of
-- minutes or pages. A settings table from before this choice stays off.
function Stats.yearGoalOf(settings, now)
    if type(settings) ~= "table" or settings.yearly_goal_on ~= true then return nil end
    local amount = tonumber(settings.yearly_goal)
    if not amount or amount ~= math.floor(amount) or amount < 1 or amount > 500 then return nil end
    return { year = tonumber(os.date("%Y", tonumber(now) or os.time())), amount = amount }
end

--- Finished books whose sidecar says complete and summary.modified falls in `year`.
-- A complete book with no modified time is not counted: the year is unknown.
function Stats.finishedThisYear(books, year)
    year = tonumber(year)
    if not year then return 0 end
    local n = 0
    for _, book in ipairs(books or {}) do
        if type(book) == "table" and (book.status == "complete" or book.doc_status == "complete") then
            local when = tonumber(book.finished_at)
            if when and tonumber(os.date("%Y", when)) == year then n = n + 1 end
        end
    end
    return n
end

function Stats.yearFraction(done, amount)
    amount = tonumber(amount) or 0
    done = tonumber(done) or 0
    if amount < 1 or done < 0 then return 0 end
    local frac = done / amount
    if frac > 1 then return 1 end
    return frac
end

function Stats.goalOf(settings)
    if type(settings) ~= "table" or settings.daily_goal_on ~= true then return nil end
    local unit = settings.daily_goal_unit
    if unit ~= "minutes" and unit ~= "pages" then return nil end
    local amount = tonumber(settings.daily_goal)
    if not amount or amount ~= math.floor(amount) or amount < 1 or amount > 1440 then return nil end
    return { unit = unit, amount = amount }
end

function Stats.goalProgress(today, goal)
    today = today or {}
    if not goal then return 0, 0 end
    local have = goal.unit == "pages" and math.floor(tonumber(today.pages) or 0)
        or Stats.minutes(today.seconds)
    if have < 0 then have = 0 end
    local frac = have / goal.amount
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    return have, frac
end

function Stats.goalLine(today, goal)
    if not goal then return nil end
    local have = Stats.goalProgress(today, goal)
    local unit = goal.unit == "pages" and (goal.amount == 1 and "page" or "pages") or "min"
    return string.format("%d / %d %s", have, goal.amount, unit)
end

function Stats.monthGrid(by_day, now, week_start)
    now = tonumber(now) or os.time()
    by_day = type(by_day) == "table" and by_day or {}
    local t = os.date("*t", now)
    local first = os.time{ year = t.year, month = t.month, day = 1, hour = 12 }
    local fw = tonumber(os.date("%w", first)) + 1
    week_start = Stats.weekStart(week_start)
    local lead = (fw - week_start) % 7
    local dim = os.date("*t", os.time{ year = t.year, month = t.month + 1, day = 0, hour = 12 }).day
    local cells, read_n, seconds = {}, 0, 0
    for _ = 1, lead do cells[#cells + 1] = { blank = true } end
    for d = 1, dim do
        local key = string.format("%04d-%02d-%02d", t.year, t.month, d)
        local row = by_day[key]
        local read = type(row) == "table" and ((tonumber(row.seconds) or 0) > 0 or (tonumber(row.pages) or 0) > 0)
        if read then
            read_n = read_n + 1
            seconds = seconds + math.max(0, math.floor(tonumber(row.seconds) or 0))
        end
        cells[#cells + 1] = { day = d, read = read and true or false, today = d == t.day }
    end
    local letters = {}
    for i = 0, 6 do
        local w = ((week_start - 1 + i) % 7) + 1
        letters[i + 1] = LETTER[w]
    end
    return {
        name = os.date("%B", now),
        letters = letters,
        cells = cells,
        read_days = read_n,
        seconds = seconds,
    }
end

function Stats.monthCaption(month)
    month = month or {}
    local days = math.floor(tonumber(month.read_days) or 0)
    local day_word = days == 1 and "day" or "days"
    return string.format("%s · %d %s · %s", month.name or "", days, day_word, Stats.weekHours(month.seconds))
end

--- Remaining pages at the pace of the last 14 days. Nil when the book has
-- no page count, or fewer than 5 distinct pages in that window.
function Stats.forecast(book, pace, now)
    if type(book) ~= "table" or type(pace) ~= "table" then return nil end
    local read = math.floor(tonumber(pace.pages) or 0)
    if read < 5 then return nil end
    local pages = tonumber(book.pages)
    local pct = tonumber(book.percent) or 0
    if pct > 1 then pct = 1 end
    if pct < 0 then pct = 0 end
    if not pages or pages < 2 then return nil end
    local left = math.ceil(pages * (1 - pct) - 1e-9)
    if left < 1 then return nil end
    local per_day = read / 14
    if per_day <= 0 then return nil end
    local days = math.ceil(left / per_day)
    if days > 366 then return nil end
    now = tonumber(now) or os.time()
    local t = os.date("*t", now)
    local when = os.time{ year = t.year, month = t.month, day = t.day + days, hour = 12 }
    local date = os.date("%a %d %b", when):gsub(" 0(%d)", " %1")
    local title = type(book.title) == "string" and book.title or ""
    if title == "" then return "done by " .. date end
    return title .. " · done by " .. date
end

--- How many covers sit in the row. Five on the Colorsoft, four when the
-- row would get cramped.
function Stats.coverCount(width)
    if (tonumber(width) or 0) < 900 then return 4 end
    return 5
end

function Stats.invalidate()
    Stats._cache = nil
end

--- One series per database stamp and calendar day. `load` runs only on a miss.
function Stats.cached(path, stamp, day, load)
    local key = tostring(path) .. "|" .. tostring(stamp) .. "|" .. tostring(day)
    if Stats._cache and Stats._cache.key == key then return Stats._cache.value end
    local value = load()
    Stats._cache = { key = key, value = value }
    return value
end

function Stats.sqlString(text)
    return "'" .. tostring(text or ""):gsub("'", "''") .. "'"
end

function Stats.bookIdSQL(title)
    return "SELECT id, pages FROM book WHERE title = " .. Stats.sqlString(title) .. " ORDER BY id LIMIT 1"
end

--- Distinct pages and their time for one book, since `since` (unix).
function Stats.bookPaceSQL(id_book, since)
    id_book = math.floor(tonumber(id_book) or 0)
    since = math.floor(tonumber(since) or 0)
    return string.format(
        "SELECT COUNT(*), SUM(secs) FROM ("
        .. "SELECT page, SUM(duration) AS secs FROM page_stat_data "
        .. "WHERE id_book = %d AND start_time >= %d AND duration > 0 GROUP BY page)",
        id_book, since)
end

--- Distinct reading days and total time for one book, from `since`.
function Stats.bookLifeSQL(id_book, since)
    id_book = math.floor(tonumber(id_book) or 0)
    since = math.floor(tonumber(since) or 0)
    return string.format(
        "SELECT COUNT(*), SUM(secs) FROM ("
        .. "SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day, "
        .. "SUM(duration) AS secs FROM page_stat_data "
        .. "WHERE id_book = %d AND start_time >= %d AND duration > 0 GROUP BY day)",
        id_book, since)
end

function Stats.bookDaysLine(days, seconds)
    days = math.floor(tonumber(days) or 0)
    if days < 1 and Stats.minutes(seconds) < 1 then return nil end
    local head = days == 1 and "1 day of reading" or string.format("%d days of reading", days)
    return head .. " · " .. Stats.weekHours(seconds) .. " read"
end

--- "row" until the reader picks "card".
function Stats.continueStyle(settings)
    if type(settings) == "table" and settings.continue_style == "card" then return "card" end
    return "row"
end

function Stats.paceWindowStart(now)
    now = tonumber(now) or os.time()
    return now - 14 * 86400
end

--- Start of the one daily series: this calendar year, or 120 days, whichever
-- reaches further back. One bounded query covers the week, the month, the
-- streak, and the year line.
function Stats.seriesStart(now)
    now = tonumber(now) or os.time()
    local t = os.date("*t", now)
    local jan = os.time{ year = t.year, month = 1, day = 1, hour = 0 }
    local back = now - 120 * 86400
    if jan < back then return jan end
    return back
end

--- "standard" until the reader picks "minimal" or "detailed".
function Stats.statsStyle(settings)
    local id = type(settings) == "table" and settings.stats_style
    if id == "minimal" or id == "detailed" then return id end
    return "standard"
end

function Stats.statsStyleLabel(id)
    if id == "minimal" then return "Minimal" end
    if id == "detailed" then return "Detailed" end
    return "Standard"
end

--- filled = a past day with reading, partial = today already started,
-- outline = nothing yet (including a future day and a today still at zero).
function Stats.dayMark(day)
    if type(day) ~= "table" or day.future then return "outline" end
    local read = (tonumber(day.pages) or 0) > 0 or (tonumber(day.seconds) or 0) > 0
    if day.today then return read and "partial" or "outline" end
    if read then return "filled" end
    return "outline"
end

function Stats.todayBrief(today)
    today = today or {}
    return Stats.weekHours(today.seconds) .. " · " .. Stats.pagesLabel(today.pages)
end

function Stats.averageLine(week)
    week = week or {}
    return Stats.weekHours(week.average_seconds) .. " · "
        .. Stats.pagesLabel(week.average_pages) .. " a day on average"
end

function Stats.minimalLine(summary)
    summary = summary or {}
    local streak = math.floor(tonumber(summary.streak) or 0)
    local tail = streak <= 0 and "no streak" or Stats.streakLabel(streak)
    return "Today " .. Stats.weekHours((summary.today or {}).seconds)
        .. " · This week " .. Stats.weekHours((summary.week or {}).seconds)
        .. " · " .. tail
end

function Stats.yearTotals(by_day, now)
    now = tonumber(now) or os.time()
    local year = tonumber(os.date("%Y", now))
    local pages, seconds, days = 0, 0, 0
    for key, row in pairs(by_day or {}) do
        if type(key) == "string" and type(row) == "table" and tonumber(key:sub(1, 4)) == year then
            local p = math.max(0, math.floor(tonumber(row.pages) or 0))
            local s = math.max(0, math.floor(tonumber(row.seconds) or 0))
            if p > 0 or s > 0 then
                days = days + 1
                pages = pages + p
                seconds = seconds + s
            end
        end
    end
    return { year = year, pages = pages, seconds = seconds, days = days }
end

function Stats.yearTotalsLine(year)
    year = year or {}
    local days = math.floor(tonumber(year.days) or 0)
    local word = days == 1 and "day" or "days"
    return string.format("%s · %d %s · %s · %s",
        tostring(year.year or ""), days, word, Stats.pagesLabel(year.pages), Stats.weekHours(year.seconds))
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

local TABLES = { page_stat_data = true }

function Stats.bookSQL()
    return "SELECT COUNT(*) FROM book"
end

--- Pages are distinct (book, page) pairs that day. Time is the sum of
-- the sittings. Only page_stat_data, and only rows at or after `since`.
function Stats.dailySQL(table_name, since)
    if table_name ~= "page_stat_data" then return nil end
    since = math.floor(tonumber(since) or 0)
    return string.format(
        "SELECT day, SUM(secs), COUNT(*) FROM ("
        .. "SELECT id_book, page, strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day, "
        .. "SUM(duration) AS secs FROM page_stat_data WHERE start_time >= %d AND duration > 0 "
        .. "GROUP BY id_book, page, day) AS daily_pages GROUP BY day ORDER BY day",
        since)
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
-- One grouped query on page_stat_data, bounded by start_time. The streak,
-- the week, and the month are read from that series.
function Stats.read(exec, now, week_start)
    if type(exec) ~= "function" then return Stats.missing(now, week_start) end
    local book_ok = pcall(exec, Stats.bookSQL())
    if not book_ok then return Stats.missing(now, week_start) end
    local since = Stats.seriesStart(now)
    local daily_ok, daily = pcall(exec, Stats.dailySQL("page_stat_data", since))
    if not daily_ok then return Stats.missing(now, week_start) end
    local map = dayMap(daily)
    local list = {}
    for day in pairs(map) do list[#list + 1] = day end
    return Stats.summarize(map, list, now, week_start)
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
Stats.PROVIDER_BUILTIN = "builtin"
Stats.PROVIDER_READINGLOG = "readinglog"
Stats.PROVIDER_ACTION = "action"
-- stevenzamora1/reading-log registers this dispatcher event. Calling it
-- opens that plugin's own dashboard. We do not load its code.
Stats.READINGLOG_EVENT = "ReadingLogDashboard"
Stats.READINGLOG_MISSING = "Reading Log is not installed. Showing the built-in log."
Stats.ACTION_MISSING = "That action is not available. Showing the built-in log."

--- "builtin" unless the saved choice is the Reading Log plugin or a
-- dispatcher action. An older settings table has no key, so it stays built-in.
function Stats.provider(settings)
    local id = type(settings) == "table" and settings.reading_log_provider
    if id == Stats.PROVIDER_READINGLOG or id == Stats.PROVIDER_ACTION then return id end
    return Stats.PROVIDER_BUILTIN
end

function Stats.providerLabel(settings)
    local id = Stats.provider(settings)
    if id == Stats.PROVIDER_READINGLOG then return "Reading Log plugin" end
    if id == Stats.PROVIDER_ACTION then return "Dispatcher action" end
    return "Built-in"
end

--- A KOReader event name, or nil. Spaces and anything else are rejected
-- so a typed line cannot be a snippet of code.
function Stats.actionEvent(settings)
    local event = type(settings) == "table" and settings.reading_log_action
    if type(event) ~= "string" then return nil end
    event = event:match("^%s*(.-)%s*$")
    if not event or not event:match("^[%w_]+$") then return nil end
    return event
end

--- Where "open the reading log" should go.
-- probe.readinglog: the Reading Log plugin is loaded.
-- probe.action_ok: the saved event name is usable (defaults to that check).
-- target is "builtin", "readinglog", or "action". fallback means show the
-- built-in page and the toast.
function Stats.route(settings, probe)
    probe = probe or {}
    local id = Stats.provider(settings)
    if id == Stats.PROVIDER_READINGLOG then
        if probe.readinglog then
            return { target = "readinglog", event = Stats.READINGLOG_EVENT }
        end
        return { target = "builtin", fallback = true, toast = Stats.READINGLOG_MISSING }
    end
    if id == Stats.PROVIDER_ACTION then
        local event = Stats.actionEvent(settings)
        local ok = probe.action_ok
        if ok == nil then ok = event ~= nil end
        if event and ok then return { target = "action", event = event } end
        return { target = "builtin", fallback = true, toast = Stats.ACTION_MISSING }
    end
    return { target = "builtin" }
end

--- Sizes for the built-in page. Narrow is a 758-wide screen; wide is the
-- Colorsoft. Cover, chart and the today figure all come from the width.
function Stats.pageLayout(width)
    width = math.floor(tonumber(width) or 0)
    if width < 1 then width = 600 end
    local narrow = width < 900
    local margin = narrow and 16 or 28
    local cover = math.floor(width * (narrow and 0.32 or 0.18))
    if cover < 104 then cover = 104 end
    if cover > 200 then cover = 200 end
    return {
        narrow = narrow,
        margin = margin,
        gap = narrow and 12 or 20,
        cover_w = cover,
        cover_h = math.floor(cover * 3 / 2),
        covers = Stats.coverCount(width),
        chart_h = narrow and 88 or 112,
        today_size = narrow and 46 or 62,
    }
end

--- Side margin of the reading log. The Library button uses the same
-- distance at the bottom, so the button never sits on the screen edge.
function Stats.readingMargin(width)
    if (tonumber(width) or 0) < 900 then return 18 end
    return 36
end

--- Cover geometry for the reading log. Every cover is a whole 2:3
-- rectangle: height is always floor(width * 3 / 2). `scale` 1 fills the
-- content width with `n` covers. A lower scale keeps that ratio and leaves
-- the spare width as gaps. Nothing here crops.
function Stats.fitCovers(inner, opts)
    opts = opts or {}
    inner = math.max(1, math.floor(tonumber(inner) or 1))
    local card = opts.card and true or false
    local n = math.floor(tonumber(opts.n) or 5)
    if n < 4 then n = 4 end
    if n > 6 then n = 6 end
    local scale = tonumber(opts.scale) or 1
    if scale < 0.45 then scale = 0.45 end
    if scale > 1 then scale = 1 end
    local row_gap = math.max(4, math.floor(tonumber(opts.row_gap) or 12))
    local function aspect(w)
        w = math.max(1, math.floor(w))
        return w, math.floor(w * 3 / 2)
    end
    local feat_w, feat_h = aspect(math.floor(inner * (card and 0.28 or 0.20) * scale))
    local slot, row_h
    if card then
        slot, row_h = feat_w, feat_h
        n = 0
        row_gap = 0
    else
        local full = math.floor((inner - row_gap * (n - 1)) / n)
        if full < 1 then
            row_gap = 4
            full = math.floor((inner - row_gap * (n - 1)) / n)
        end
        slot, row_h = aspect(math.max(1, math.floor(full * scale)))
        local used = n * slot + (n - 1) * row_gap
        if used > inner and scale >= 0.999 then
            row_gap = 4
            slot, row_h = aspect(math.floor((inner - row_gap * (n - 1)) / n))
        end
    end
    return {
        n = n,
        feat_w = feat_w,
        feat_h = feat_h,
        slot = slot,
        row_h = row_h,
        row_gap = row_gap,
        cropped = false,
    }
end

--- Left edge of each of 7 day columns, and the column width. Labels and
-- bars use the same numbers so a day sits on its bar.
function Stats.chartColumns(width, gap)
    width = math.max(0, math.floor(tonumber(width) or 0))
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    local slot = math.floor((width - gap * 6) / 7)
    if slot < 1 then slot = 1 end
    local cols = {}
    for i = 0, 6 do cols[i + 1] = i * (slot + gap) end
    return slot, cols
end

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
