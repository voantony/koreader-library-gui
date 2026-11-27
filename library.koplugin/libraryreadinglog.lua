--- Reading log home page.
-- Continue reading uses the same books and covers as the Library.
-- Today, this week and the streak come from librarystats.lua.
-- Black on white. KOReader's night mode inverts that, so the contrast
-- stays the same in the dark. The clock is the only timed refresh, and
-- only the header is marked dirty.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Core = require("librarycore")
local Stats = require("librarystats")
local Tiles = require("librarytile")
local Covers = require("librarycovers")
local _ = require("gettext")
local Screen = Device.screen

local ReadingLog = InputContainer:extend{
    name = "library_reading_log",
    covers_fullscreen = true,
    plugin = nil,
}

local function face(size)
    return Font:getFace("cfont", size)
end

local function ink()
    return Blitbuffer.COLOR_BLACK
end

local function paper()
    return Blitbuffer.COLOR_WHITE
end

local function grey()
    return Blitbuffer.COLOR_GRAY_5 or Blitbuffer.COLOR_BLACK
end

local function clockText()
    local twelve = false
    if G_reader_settings and G_reader_settings.isTrue then
        local ok, on = pcall(function() return G_reader_settings:isTrue("twelve_hour_clock") end)
        twelve = ok and on and true or false
    end
    if twelve then
        return (os.date("%I:%M %p"):gsub("^0", ""))
    end
    return os.date("%H:%M")
end

local function batteryText()
    if not Device.getPowerDevice then return nil end
    local ok, power = pcall(Device.getPowerDevice, Device)
    if not ok or type(power) ~= "table" or type(power.getCapacity) ~= "function" then
        return nil
    end
    local ok_n, n = pcall(power.getCapacity, power)
    if not ok_n then return nil end
    return Core.batteryLabel(n)
end

--- One small circle per day. Filled = read, outline = not, lower half = today.
local WeekMarks = Widget:extend{ days = nil, width = 0 }

function WeekMarks:init()
    local w = math.max(0, math.floor(tonumber(self.width) or 0))
    local n = math.max(1, #(self.days or {}))
    local slot = math.floor(w / n)
    local r = math.min(11, math.max(6, math.floor(slot * 0.22)))
    self.radius = r
    self.dimen = Geom:new{ w = w, h = r * 2 + 34 }
end

function WeekMarks:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function WeekMarks:paintTo(bb, x, y)
    if bb == nil or type(bb.paintCircle) ~= "function" then return end
    local days = self.days or {}
    local n = #days
    if n < 1 then return end
    local slot = math.floor(self.dimen.w / n)
    local r = self.radius or 8
    local cy = y + r + 1
    for i = 1, n do
        local day = days[i]
        local cx = x + (i - 1) * slot + math.floor(slot / 2)
        local mark = Stats.dayMark(day)
        if mark == "filled" then
            bb:paintCircle(cx, cy, r, ink())
        elseif mark == "partial" and type(bb.paintRect) == "function" then
            bb:paintCircle(cx, cy, r, ink())
            bb:paintRect(cx - r - 1, cy - r - 1, r * 2 + 2, r + 1, paper())
            bb:paintCircle(cx, cy, r, ink(), 2)
        else
            bb:paintCircle(cx, cy, r, ink(), 2)
        end
        local label = TextWidget:new{
            text = day.label or "",
            face = face(self.label_size or 14),
            bold = day.today and true or false,
            fgcolor = day.today and ink() or grey(),
        }
        local lw = label:getSize().w or 0
        label:paintTo(bb, cx - math.floor(lw / 2), cy + r + 8)
        label:free()
    end
end

--- One square per day of the month. Read days are filled; the rest are an outline.
local MonthGrid = Widget:extend{ month = nil, width = 0 }

function MonthGrid:init()
    local w = math.max(0, math.floor(tonumber(self.width) or 0))
    local cells = (self.month and self.month.cells) or {}
    local rows = math.max(1, math.ceil(#cells / 7))
    local gap = 10
    local cell = math.floor((w - gap * 6) / 7)
    if cell > 26 then cell = 26 end
    if cell < 10 then cell = 10 end
    self.cell = cell
    self.gap = gap
    self.dimen = Geom:new{ w = w, h = 36 + rows * (cell + 8) }
end

function MonthGrid:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function MonthGrid:paintTo(bb, x, y)
    if bb == nil or type(bb.paintRect) ~= "function" then return end
    local month = self.month or {}
    local letters = month.letters or {}
    local cells = month.cells or {}
    local cell, gap = self.cell or 14, self.gap or 6
    for i = 1, 7 do
        local label = TextWidget:new{
            text = letters[i] or "",
            face = face(12),
            fgcolor = grey(),
        }
        local dx = x + (i - 1) * (cell + gap)
        local lw = label:getSize().w or 0
        label:paintTo(bb, dx + math.floor((cell - lw) / 2), y)
        label:free()
    end
    local top = y + 34
    for i, info in ipairs(cells) do
        local col = (i - 1) % 7
        local row = math.floor((i - 1) / 7)
        local dx = x + col * (cell + gap)
        local dy = top + row * (cell + 8)
        if type(info) == "table" and not info.blank then
            if info.read then
                bb:paintRect(dx, dy, cell, cell, grey())
            else
                bb:paintRect(dx, dy, cell, 1, grey())
                bb:paintRect(dx, dy + cell - 1, cell, 1, grey())
                bb:paintRect(dx, dy, 1, cell, grey())
                bb:paintRect(dx + cell - 1, dy, 1, cell, grey())
            end
            if info.today then
                bb:paintRect(dx - 2, dy - 2, cell + 4, 1, ink())
                bb:paintRect(dx - 2, dy + cell + 1, cell + 4, 1, ink())
                bb:paintRect(dx - 2, dy - 2, 1, cell + 4, ink())
                bb:paintRect(dx + cell + 1, dy - 2, 1, cell + 4, ink())
            end
        end
    end
end

local Bar = Widget:extend{ width = 0, height = 6, fraction = 0 }

function Bar:init()
    self.dimen = Geom:new{ w = self.width or 0, h = self.height or 6 }
end

function Bar:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Bar:paintTo(bb, x, y)
    if bb == nil or type(bb.paintRect) ~= "function" then return end
    local w, h = self.dimen.w, self.dimen.h
    if w < 1 or h < 1 then return end
    bb:paintRect(x, y, w, h, grey())
    local frac = tonumber(self.fraction) or 0
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    if frac <= 0 then return end
    local fill = math.floor(w * frac)
    if fill < 2 then fill = 2 end
    if fill > w then fill = w end
    bb:paintRect(x, y, fill, h, ink())
end

local Hit = InputContainer:extend{}

function Hit:init()
    self.dimen = Geom:new{ w = self.width or 0, h = self.height or 0 }
    self.ges_events = {
        TapHit = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Hit:onTapHit()
    if self.callback then self.callback() end
    return true
end

function ReadingLog:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.layout = Stats.pageLayout(self.dimen.w)
    self.cover_cache = Tiles.newCoverCache(4)
    self.covers = {
        store = Covers.getStore(),
        bim = self.plugin and self.plugin.getBIM and self.plugin:getBIM(),
    }
    if self.covers.store and self.covers.store.scan then self.covers.store:scan() end
    self._tab = "today"
    self._pick = 1
    self._covers_ready = false
    self:build()
    self:scheduleClock()
    if UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            if self._closed then return end
            self._covers_ready = true
            self:build()
            if UIManager.setDirty then UIManager:setDirty(self, "ui") end
            self:scheduleCovers()
        end)
    else
        self._covers_ready = true
    end
end

function ReadingLog:weekStart()
    local stored
    if G_reader_settings and G_reader_settings.readSetting then
        local ok, stats = pcall(function() return G_reader_settings:readSetting("statistics") end)
        if ok and type(stats) == "table" then stored = stats.calendar_start_day_of_week end
    end
    return Stats.weekStart(stored)
end

function ReadingLog:readStats()
    local dir = self.plugin and self.plugin.settingsFolder and self.plugin:settingsFolder()
    local path = Stats.dbPath(dir) or ""
    local stamp = 0
    if path ~= "" then
        local lfs = require("libs/libkoreader-lfs")
        stamp = lfs.attributes(path, "modification") or 0
    end
    local now = os.time()
    local summary = Stats.cached(path, stamp, Stats.ymd(now), function()
        local ok, value = pcall(Stats.loadPath, path, now, self:weekStart())
        if not ok or type(value) ~= "table" then return Stats.missing(now, self:weekStart()) end
        return value
    end)
    if self.plugin and self.plugin.noteBestStreak then
        self.plugin:noteBestStreak(summary)
    end
    summary.saved_best = self.plugin and self.plugin.settings and self.plugin.settings.reading_log_best
    return summary
end

function ReadingLog:continueBooks()
    local n = self.layout.covers or 5
    if self:continueStyle() == "card" then n = 5 end
    if self.plugin and self.plugin.continueBooks then
        local ok, books = pcall(self.plugin.continueBooks, self.plugin, n)
        if ok and type(books) == "table" then return books end
    end
    return {}
end

function ReadingLog:continueStyle()
    local settings = self.plugin and self.plugin.settings
    return Stats.continueStyle(settings)
end

function ReadingLog:withDb(fn)
    local dir = self.plugin and self.plugin.settingsFolder and self.plugin:settingsFolder()
    local path = Stats.dbPath(dir)
    if not path then return nil end
    local opened, conn = pcall(Stats.openReadOnly, path)
    if not opened or not conn or type(conn.exec) ~= "function" then return nil end
    local ok, value = pcall(fn, function(sql) return conn:exec(sql) end)
    if conn.close then pcall(conn.close, conn) end
    if ok then return value end
    return nil
end

function ReadingLog:bookRecord(book)
    if type(book) ~= "table" or type(book.title) ~= "string" or book.title == "" then return nil end
    local key = book.title
    self._records = self._records or {}
    if self._records[key] then return self._records[key] end
    local record = self:withDb(function(exec)
        local id_rows = Stats.columnsToRows(exec(Stats.bookIdSQL(book.title)))
        local id = id_rows[1] and tonumber(id_rows[1][1])
        if not id then return nil end
        local now = os.time()
        local pace_rows = Stats.columnsToRows(exec(Stats.bookPaceSQL(id, Stats.paceWindowStart(now))))
        local life_rows = Stats.columnsToRows(exec(Stats.bookLifeSQL(id, Stats.seriesStart(now))))
        return {
            pages = id_rows[1] and tonumber(id_rows[1][2]),
            pace = {
                pages = pace_rows[1] and tonumber(pace_rows[1][1]) or 0,
                seconds = pace_rows[1] and tonumber(pace_rows[1][2]) or 0,
            },
            days = life_rows[1] and tonumber(life_rows[1][1]) or 0,
            seconds = life_rows[1] and tonumber(life_rows[1][2]) or 0,
        }
    end)
    self._records[key] = record or false
    return record
end

local function heading(text, size)
    return TextWidget:new{ text = text, face = face(size or 18), bold = true, fgcolor = ink() }
end

local function body(text, size, bold)
    return TextWidget:new{
        text = text or "",
        face = face(size or 16),
        bold = bold and true or false,
        fgcolor = ink(),
    }
end

local function muted(text, size, bold)
    return TextWidget:new{
        text = text or "",
        face = face(size or 15),
        bold = bold and true or false,
        fgcolor = grey(),
    }
end

function ReadingLog:pad(widget, top)
    local m = self.layout.margin
    return FrameContainer:new{
        padding = 0,
        padding_left = m,
        padding_right = m,
        padding_top = top or 0,
        bordersize = 0,
        background = paper(),
        widget,
    }
end

function ReadingLog:statsStyle()
    return Stats.statsStyle(self.plugin and self.plugin.settings)
end

function ReadingLog:goal()
    return Stats.goalOf(self.plugin and self.plugin.settings)
end

function ReadingLog:bestStreak(summary)
    local saved = summary and summary.saved_best
    if saved == nil and self.plugin and self.plugin.settings then
        saved = self.plugin.settings.reading_log_best
    end
    return Stats.rememberBest(saved, summary and summary.streak, summary and summary.best)
end

function ReadingLog:finishedCount(year)
    local books = {}
    if self.plugin and self.plugin.getBooks then
        local ok, list = pcall(self.plugin.getBooks, self.plugin)
        if ok and type(list) == "table" then books = list end
    end
    return Stats.finishedThisYear(books, year)
end

function ReadingLog:emptyCover(w, h)
    return FrameContainer:new{
        padding = 0, bordersize = 1, color = ink(), background = paper(),
        width = w, height = h,
        VerticalSpan:new{ width = h },
    }
end

function ReadingLog:coverBox(book, w, h)
    if not self._covers_ready then
        self.missing_covers[#self.missing_covers + 1] = book
        return self:emptyCover(w, h)
    end
    local _, ready = Tiles.getCover(self.cover_cache, self.covers, book, w, h)
    if not ready then self.missing_covers[#self.missing_covers + 1] = book end
    local cover = select(1, Tiles.bookCover(
        { covers = self.covers, cover_cache = self.cover_cache },
        book, w, h, book.title, book.authors and book.authors[1]))
    if cover then return cover end
    return self:emptyCover(w, h)
end

function ReadingLog:forecastCaption(book)
    if type(book) ~= "table" then return nil end
    local record = self:bookRecord(book)
    if type(record) ~= "table" or type(record.pace) ~= "table" then return nil end
    return Stats.forecast({
        title = book.title,
        pages = book.pages or record.pages,
        percent = book.percent,
    }, record.pace, os.time())
end

function ReadingLog:buildCoverRow(books, inner_w)
    local L = self.layout
    local n = #books
    local gap = L.narrow and 12 or 18
    local slot = math.floor((inner_w - gap * (n - 1)) / n)
    local cap = L.narrow and 132 or 148
    if slot > cap then slot = cap end
    if slot < 64 then slot = 64 end
    local cover_h = math.floor(slot * 1.4)
    local row = HorizontalGroup:new{ align = "top" }
    for i, book in ipairs(books) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local cover = self:coverBox(book, slot, cover_h)
        local pct = Core.progressPercent(book)
        local col = VerticalGroup:new{
            align = "left",
            cover,
            VerticalSpan:new{ width = 8 },
            Bar:new{ width = slot, height = 3, fraction = tonumber(book.percent) or 0 },
            VerticalSpan:new{ width = 4 },
            muted(string.format("%d%% Read", pct), L.narrow and 12 or 14),
        }
        table.insert(row, Hit:new{
            width = slot,
            height = col:getSize().h,
            callback = function() self:openBook(book) end,
            col,
        })
    end
    local group = VerticalGroup:new{ align = "left", row }
    local forecast = self:forecastCaption(books[1])
    if forecast then
        table.insert(group, VerticalSpan:new{ width = 10 })
        table.insert(group, muted(forecast, 15))
    end
    return group
end

function ReadingLog:buttonFace(text, width, height, filled)
    local label = TextWidget:new{
        text = text,
        face = face(16),
        bold = true,
        fgcolor = filled and paper() or ink(),
    }
    return FrameContainer:new{
        padding = 0,
        bordersize = filled and 0 or 1,
        color = ink(),
        background = filled and ink() or paper(),
        width = width,
        height = height,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            label,
        },
    }
end

function ReadingLog:buildCard(books, inner_w)
    local L = self.layout
    local n = #books
    local pick = math.floor(tonumber(self._pick) or 1)
    if pick < 1 or pick > n then pick = 1 end
    self._pick = pick
    local book = books[pick]
    local cover_w = L.narrow and 128 or 164
    if cover_w + 150 > inner_w then cover_w = math.max(96, inner_w - 150) end
    local cover_h = math.floor(cover_w * 1.45)
    local cover = Hit:new{
        width = cover_w,
        height = cover_h,
        callback = function() self:openBook(book) end,
        self:coverBox(book, cover_w, cover_h),
    }
    local text_w = math.max(80, inner_w - cover_w - L.gap)
    local record = self:bookRecord(book)
    local days_line = type(record) == "table" and Stats.bookDaysLine(record.days, record.seconds)
    local pct = Core.progressPercent(book)
    local left_secs = Core.knownTimeLeft(book)
    local label = muted(_("Continue reading"), 12)
    local pager = body(string.format("%d / %d ›", pick, n), 15, true)
    local pager_gap = math.max(8, text_w - label:getSize().w - pager:getSize().w)
    local function cycle()
        self._pick = pick % n + 1
        self:reload()
    end
    local top = HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = pager_gap },
        Hit:new{
            width = pager:getSize().w + 8,
            height = pager:getSize().h + 6,
            callback = cycle,
            pager,
        },
    }
    local text = VerticalGroup:new{ align = "left", top, VerticalSpan:new{ width = 8 } }
    table.insert(text, TextWidget:new{
        text = book.title or "",
        face = face(L.narrow and 18 or 22),
        bold = true,
        fgcolor = ink(),
        max_width = text_w,
    })
    local author = book.authors and book.authors[1] or ""
    if author ~= "" then
        table.insert(text, VerticalSpan:new{ width = 4 })
        table.insert(text, TextWidget:new{
            text = author, face = face(15), fgcolor = grey(), max_width = text_w,
        })
    end
    if days_line then
        table.insert(text, VerticalSpan:new{ width = 8 })
        table.insert(text, muted(days_line, 14))
    end
    table.insert(text, VerticalSpan:new{ width = 12 })
    table.insert(text, Bar:new{
        width = math.min(text_w, 320), height = 4, fraction = tonumber(book.percent) or 0,
    })
    table.insert(text, VerticalSpan:new{ width = 6 })
    local pct_w = body(pct .. "%", 16, true)
    local left_w = left_secs and muted(Stats.weekHours(left_secs) .. " " .. _("left"), 15) or nil
    if left_w then
        local gap = math.max(8, math.min(text_w, 320) - pct_w:getSize().w - left_w:getSize().w)
        table.insert(text, HorizontalGroup:new{
            align = "center", pct_w, HorizontalSpan:new{ width = gap }, left_w,
        })
    else
        table.insert(text, pct_w)
    end
    local bw = math.floor((math.min(text_w, 360) - 10) / 2)
    local bh = 40
    table.insert(text, VerticalSpan:new{ width = 14 })
    table.insert(text, HorizontalGroup:new{
        align = "center",
        Hit:new{
            width = bw, height = bh,
            callback = function() self:openBook(book) end,
            self:buttonFace(_("Continue"), bw, bh, true),
        },
        HorizontalSpan:new{ width = 10 },
        Hit:new{
            width = bw, height = bh,
            callback = function() self:showDetails(book) end,
            self:buttonFace(_("Details"), bw, bh, false),
        },
    })
    return HorizontalGroup:new{
        align = "top",
        cover,
        HorizontalSpan:new{ width = L.gap },
        text,
    }
end

function ReadingLog:showDetails(book)
    if self.plugin and self.plugin.showBookDetails then
        pcall(self.plugin.showBookDetails, self.plugin, book, nil)
    end
end

function ReadingLog:buildContinue(inner_w)
    local L = self.layout
    self.missing_covers = {}
    local books = self:continueBooks()
    local card = self:continueStyle() == "card"
    local col = VerticalGroup:new{ align = "left" }
    if not card then
        table.insert(col, heading(_("Continue reading"), L.narrow and 18 or 22))
    end
    if #books == 0 then
        if card then table.insert(col, heading(_("Continue reading"), L.narrow and 18 or 22)) end
        table.insert(col, VerticalSpan:new{ width = 8 })
        table.insert(col, muted(_("Nothing in progress."), 16))
        return col
    end
    if not card then table.insert(col, VerticalSpan:new{ width = 14 }) end
    if card then
        table.insert(col, self:buildCard(books, inner_w))
    else
        table.insert(col, self:buildCoverRow(books, inner_w))
    end
    return col
end

function ReadingLog:goalBlock(summary, width)
    local goal = self:goal()
    local line = Stats.goalLine(summary.today, goal)
    if not line then return nil end
    local _, frac = Stats.goalProgress(summary.today, goal)
    local w = math.min(width, self.layout.narrow and 220 or 280)
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = 8 },
        muted(line, 15),
        VerticalSpan:new{ width = 6 },
        Bar:new{ width = w, height = 3, fraction = frac },
    }
end

function ReadingLog:buildWeekTile(summary, inner_w)
    local L = self.layout
    local head = heading(_("This week"), L.narrow and 18 or 20)
    local totals = muted(Stats.weekTotalLine(summary.week), L.narrow and 14 or 16)
    local gap = math.max(8, inner_w - head:getSize().w - totals:getSize().w)
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            head,
            HorizontalSpan:new{ width = gap },
            totals,
        },
        VerticalSpan:new{ width = 14 },
        WeekMarks:new{
            days = summary.week.days,
            width = inner_w,
            label_size = L.narrow and 13 or 15,
        },
        VerticalSpan:new{ width = 8 },
        muted(Stats.averageLine(summary.week), L.narrow and 14 or 16),
    }
end

function ReadingLog:buildActivity(summary, inner_w)
    local size = self.layout.narrow and 16 or 18
    local pages = body(Stats.pagesLabel(summary.today.pages), size, true)
    local minutes = body(Stats.weekHours(summary.today.seconds), size, true)
    local streak = body(Stats.streakLabel(summary.streak), size, true)
    local gap = 22
    local used = pages:getSize().w + minutes:getSize().w + streak:getSize().w + gap * 2
    if used > inner_w then
        return VerticalGroup:new{
            align = "left",
            pages,
            VerticalSpan:new{ width = 4 },
            minutes,
            VerticalSpan:new{ width = 4 },
            streak,
        }
    end
    return HorizontalGroup:new{
        align = "center",
        pages,
        HorizontalSpan:new{ width = gap },
        minutes,
        HorizontalSpan:new{ width = gap },
        streak,
    }
end

function ReadingLog:buildStandard(summary, inner_w)
    local L = self.layout
    local col = VerticalGroup:new{ align = "left" }
    table.insert(col, heading(_("Today"), L.narrow and 18 or 20))
    table.insert(col, VerticalSpan:new{ width = 6 })
    table.insert(col, body(Stats.todayBrief(summary.today), L.narrow and 18 or 22, true))
    local goal = self:goalBlock(summary, inner_w)
    if goal then table.insert(col, goal) end
    if self:statsStyle() == "detailed" then
        table.insert(col, VerticalSpan:new{ width = L.gap })
        table.insert(col, self:buildActivity(summary, inner_w))
    end
    table.insert(col, VerticalSpan:new{ width = L.gap + 6 })
    table.insert(col, self:buildWeekTile(summary, inner_w))
    table.insert(col, VerticalSpan:new{ width = 12 })
    table.insert(col, body(Stats.streakCaption(summary.streak, self:bestStreak(summary)), L.narrow and 15 or 16))
    return col
end

function ReadingLog:buildMonth(summary, inner_w)
    local L = self.layout
    local month = summary.month or {}
    local grid_w = inner_w
    if not L.narrow and grid_w > 460 then grid_w = 460 end
    return VerticalGroup:new{
        align = "left",
        heading(month.name or _("Month"), L.narrow and 18 or 22),
        VerticalSpan:new{ width = 14 },
        MonthGrid:new{ month = month, width = grid_w },
        VerticalSpan:new{ width = 12 },
        muted(Stats.monthCaption(month), 16),
    }
end

function ReadingLog:buildYear(summary, inner_w)
    local L = self.layout
    local year = summary.year or {}
    local col = VerticalGroup:new{ align = "left" }
    local goal = Stats.yearGoalOf(self.plugin and self.plugin.settings)
    if not goal then
        table.insert(col, heading(tostring(year.year or os.date("%Y")), L.narrow and 20 or 24))
        table.insert(col, VerticalSpan:new{ width = 8 })
    end
    table.insert(col, muted(Stats.yearTotalsLine(year), 16))
    if not goal then return col end
    local done = self:finishedCount(goal.year)
    local frac = Stats.yearFraction(done, goal.amount)
    local pct = math.floor(frac * 100 + 0.5)
    local ylbl = heading(tostring(goal.year), L.narrow and 18 or 22)
    local plbl = body(pct .. "%", L.narrow and 18 or 22, true)
    local blbl = muted(string.format("%d/%d books", done, goal.amount), 15)
    local rail_w = inner_w - ylbl:getSize().w - plbl:getSize().w - blbl:getSize().w - 36
    if rail_w < 48 then rail_w = math.max(48, math.floor(inner_w * 0.4)) end
    table.insert(col, VerticalSpan:new{ width = 18 })
    table.insert(col, HorizontalGroup:new{
        align = "center",
        ylbl,
        HorizontalSpan:new{ width = 12 },
        Bar:new{ width = rail_w, height = L.narrow and 8 or 10, fraction = frac },
        HorizontalSpan:new{ width = 12 },
        plbl,
        HorizontalSpan:new{ width = 12 },
        blbl,
    })
    return col
end

function ReadingLog:missingNote()
    return VerticalGroup:new{
        align = "left",
        heading(_(Stats.NOTE), self.layout.narrow and 18 or 20),
        VerticalSpan:new{ width = 8 },
        muted(_("KOReader's statistics plugin keeps the time and the pages."), 16),
    }
end

function ReadingLog:buildStats(summary, inner_w)
    if summary.missing then return self:missingNote() end
    local style = self:statsStyle()
    if style == "minimal" then
        return body(Stats.minimalLine(summary), self.layout.narrow and 16 or 18)
    end
    local tab = self._tab or "today"
    if style == "detailed" and tab == "month" then return self:buildMonth(summary, inner_w) end
    if style == "detailed" and tab == "year" then return self:buildYear(summary, inner_w) end
    return self:buildStandard(summary, inner_w)
end

function ReadingLog:buildSwitch(inner_w)
    local tabs = {
        { id = "today", label = _("Today") },
        { id = "month", label = _("Month") },
        { id = "year", label = _("Year") },
    }
    local gap = 8
    local cell = math.floor((inner_w - gap * 2) / 3)
    local h = self.layout.narrow and 40 or 44
    local row = HorizontalGroup:new{ align = "center" }
    for i, tab in ipairs(tabs) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local on = (self._tab or "today") == tab.id
        table.insert(row, Hit:new{
            width = cell,
            height = h,
            callback = function()
                self._tab = tab.id
                self:reload()
            end,
            self:buttonFace(tab.label, cell, h, on),
        })
    end
    return row
end

function ReadingLog:build()
    local width = self.dimen.w
    local L = self.layout
    local summary = self:readStats()
    self.summary = summary
    local inner = width - 2 * L.margin
    local when = os.date("%A %d %B"):gsub(" 0(%d)", " %1")
    local date = heading(when, L.narrow and 16 or 20)
    local date_col = VerticalGroup:new{ align = "left", date }
    local battery = batteryText()
    if battery then
        table.insert(date_col, VerticalSpan:new{ width = 2 })
        table.insert(date_col, muted(battery, 14))
    end
    self._clock = TextWidget:new{
        text = clockText(),
        face = face(L.narrow and 36 or 48),
        bold = true,
        fgcolor = ink(),
    }
    local gap = math.max(8, inner - date_col:getSize().w - self._clock:getSize().w)
    local header = FrameContainer:new{
        padding = 0,
        padding_left = L.margin,
        padding_right = L.margin,
        padding_top = L.narrow and 16 or 28,
        padding_bottom = 4,
        bordersize = 0,
        background = paper(),
        HorizontalGroup:new{
            align = "center",
            date_col,
            HorizontalSpan:new{ width = gap },
            self._clock,
        },
    }
    self.header = header
    local style = self:statsStyle()
    local tab = self._tab or "today"
    local show_continue = not (style == "detailed" and tab ~= "today")
    local parts = VerticalGroup:new{ align = "left", header }
    if show_continue then
        table.insert(parts, self:pad(self:buildContinue(inner), L.narrow and 18 or 28))
    else
        table.insert(parts, VerticalSpan:new{ width = L.narrow and 16 or 24 })
    end
    table.insert(parts, self:pad(self:buildStats(summary, inner), L.narrow and 16 or 22))
    if style == "detailed" then
        table.insert(parts, self:pad(self:buildSwitch(inner), L.narrow and 18 or 24))
    end
    local button = self:buildLibraryButton(width)
    local used = parts:getSize().h + button:getSize().h
    local spacer = math.max(L.gap, self.dimen.h - used)
    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = paper(),
        width = width,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            parts,
            VerticalSpan:new{ width = spacer },
            button,
        },
    }
end

function ReadingLog:openBook(book)
    local path = Core.openPath(book)
    if path and self.plugin and self.plugin.openBook then
        self.plugin:openBook(path, self)
    end
end

function ReadingLog:onOpenLibrary()
    local plugin = self.plugin
    if not (plugin and plugin.onOpenLibraryGrid) then return false end
    local function go() return plugin:onOpenLibraryGrid() end
    if UIManager and UIManager.nextTick then
        UIManager:nextTick(go)
        return true
    end
    return go()
end

function ReadingLog:buildLibraryButton(width)
    local L = self.layout
    local label = heading(_("Library"), L.narrow and 18 or 20)
    local inner_h = math.max(Tiles.minTouch(), label:getSize().h + 20)
    local button_w = width - 2 * L.margin
    local CenterContainer = require("ui/widget/container/centercontainer")
    local framed = FrameContainer:new{
        padding = 0,
        bordersize = 2,
        color = ink(),
        background = paper(),
        width = button_w,
        height = inner_h,
        CenterContainer:new{
            dimen = Geom:new{ w = button_w, h = inner_h },
            label,
        },
    }
    return FrameContainer:new{
        padding = 0,
        padding_left = L.margin,
        padding_right = L.margin,
        padding_bottom = L.margin,
        bordersize = 0,
        background = paper(),
        Hit:new{
            width = button_w,
            height = inner_h,
            callback = function() self:onOpenLibrary() end,
            framed,
        },
    }
end

function ReadingLog:reload()
    if self._closed then return end
    self.layout = Stats.pageLayout(self.dimen and self.dimen.w)
    self:build()
    if UIManager.setDirty then UIManager:setDirty(self, "ui") end
end

function ReadingLog:headerRegion()
    local h = 0
    if self.header and self.header.getSize then h = self.header:getSize().h or 0 end
    return Geom:new{ x = 0, y = 0, w = self.dimen.w, h = h }
end

function ReadingLog:scheduleClock()
    if self._clock_tick and UIManager.unschedule then UIManager:unschedule(self._clock_tick) end
    local delay = Core.nextMinuteDelay(os.time())
    self._clock_tick = function()
        self._clock_tick = nil
        if self._closed then return end
        if self._clock and self._clock.setText then
            local status = Core.statusLabel(clockText(), batteryText()) or clockText()
            self._clock:setText(status)
            if UIManager.setDirty then
                UIManager:setDirty(self, function()
                    return "ui", self:headerRegion(), true
                end)
            end
        end
        self:scheduleClock()
    end
    if UIManager.scheduleIn then UIManager:scheduleIn(delay, self._clock_tick) end
end

function ReadingLog:scheduleCovers()
    local missing = self.missing_covers
    if not missing or #missing == 0 then return end
    local store = self.covers and self.covers.store
    local items = Covers.order(missing, nil, function(book)
        return store and store.state and store:state(book) ~= nil
    end)
    if #items == 0 then return end
    UIManager:nextTick(function()
        if self._closed then return end
        pcall(Covers.submit, items, function(done)
            if self._closed then return end
            if done then self:reload() end
        end)
    end)
end

function ReadingLog:onClose()
    UIManager:close(self)
    return true
end

function ReadingLog:onCloseWidget()
    self._closed = true
    if self._clock_tick and UIManager.unschedule then
        UIManager:unschedule(self._clock_tick)
        self._clock_tick = nil
    end
    if self.plugin and self.plugin.onReadingLogClosed then
        self.plugin:onReadingLogClosed(self)
    end
end

return ReadingLog
