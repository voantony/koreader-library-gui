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
local OverlapGroup = require("ui/widget/overlapgroup")
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

local function mist()
    return Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_GRAY_5 or Blitbuffer.COLOR_BLACK
end

local function dateLine()
    local text = os.date("%A · %d %B")
    text = text:gsub(" 0(%d)", " %1")
    return text:upper()
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

--- Weekday letter above a ring. Read days are concentric rings, unread days
-- are a light outline, and today is an arc when a daily goal is on.
local function paintRing(bb, cx, cy, r, kind, frac)
    if r < 4 then r = 4 end
    if kind == "read" then
        bb:paintCircle(cx, cy, r, ink(), math.max(2, math.floor(r * 0.12)))
        bb:paintCircle(cx, cy, math.floor(r * 0.62), grey(), math.max(2, math.floor(r * 0.12)))
        bb:paintCircle(cx, cy, math.max(2, math.floor(r * 0.22)), ink())
        return
    end
    bb:paintCircle(cx, cy, r, mist(), 2)
    if kind ~= "arc" then return end
    frac = tonumber(frac) or 0
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    if frac <= 0 then return end
    local thick = math.max(4, math.floor(r * 0.28))
    local half = math.floor(thick / 2)
    local mid_r = math.max(half + 2, r - half)
    local steps = math.max(36, math.floor(2 * math.pi * mid_r * frac))
    local a0 = -math.pi / 2
    local sweep = frac * 2 * math.pi
    if bb.setPixelClamped then
        for i = 0, steps do
            local a = a0 + sweep * (i / steps)
            local px = cx + math.cos(a) * mid_r
            local py = cy + math.sin(a) * mid_r
            for oy = -half, half do
                for ox = -half, half do
                    if ox * ox + oy * oy <= half * half + half then
                        bb:setPixelClamped(math.floor(px + ox + 0.5), math.floor(py + oy + 0.5), ink())
                    end
                end
            end
        end
        return
    end
    local dot = math.max(2, half)
    for i = 0, steps do
        local a = a0 + sweep * (i / steps)
        bb:paintCircle(
            math.floor(cx + math.cos(a) * mid_r + 0.5),
            math.floor(cy + math.sin(a) * mid_r + 0.5),
            dot, ink())
    end
end

local RingRow = Widget:extend{ days = nil, width = 0, radius = 16, goal_frac = nil }

function RingRow:init()
    local w = math.max(0, math.floor(tonumber(self.width) or 0))
    local r = math.max(8, math.floor(tonumber(self.radius) or 16))
    self.radius = r
    self.label_h = 40
    self.dimen = Geom:new{ w = w, h = self.label_h + r * 2 + 8 }
end

function RingRow:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function RingRow:paintTo(bb, x, y)
    if bb == nil or type(bb.paintCircle) ~= "function" then return end
    local days = self.days or {}
    local n = #days
    if n < 1 then return end
    local slot = math.floor(self.dimen.w / n)
    local r = self.radius
    local label_h = self.label_h or 34
    local cy = y + label_h + r
    for i = 1, n do
        local day = days[i]
        local cx = x + (i - 1) * slot + math.floor(slot / 2)
        local read = (tonumber(day.pages) or 0) > 0 or (tonumber(day.seconds) or 0) > 0
        local kind = "empty"
        if not day.future and day.today and self.goal_frac then
            kind = "arc"
        elseif not day.future and read then
            kind = "read"
        end
        local label = TextWidget:new{
            text = day.label or "",
            face = face(self.label_size or 15),
            bold = day.today and true or false,
            fgcolor = day.today and ink() or grey(),
        }
        local lw = label:getSize().w or 0
        label:paintTo(bb, cx - math.floor(lw / 2), y)
        label:free()
        paintRing(bb, cx, cy, r, kind, self.goal_frac)
    end
end

local RingGlyph = Widget:extend{ radius = 36, kind = "empty", frac = 0 }

function RingGlyph:init()
    local d = (self.radius or 36) * 2 + 4
    self.dimen = Geom:new{ w = d, h = d }
end

function RingGlyph:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function RingGlyph:paintTo(bb, x, y)
    if bb == nil or type(bb.paintCircle) ~= "function" then return end
    local r = self.radius or 36
    paintRing(bb, x + r + 2, y + r + 2, r, self.kind or "empty", self.frac)
end

--- One square per day of the month. Read days are filled; the rest are an outline.
local MonthGrid = Widget:extend{ month = nil, width = 0 }

function MonthGrid:init()
    local w = math.max(0, math.floor(tonumber(self.width) or 0))
    local cells = (self.month and self.month.cells) or {}
    local rows = math.max(1, math.ceil(#cells / 7))
    local gap = 10
    local cell = math.floor((w - gap * 6) / 7)
    local cap = self.cell_max or 32
    if cell > cap then cell = cap end
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
    local top = y + 52
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

local Sized = Widget:extend{ width = 0, height = 0 }

function Sized:init()
    self.dimen = Geom:new{
        w = math.floor(tonumber(self.width) or 0),
        h = math.floor(tonumber(self.height) or 0),
    }
end

function Sized:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Sized:paintTo(bb, x, y)
    if self[1] and self[1].paintTo then
        local s = self[1]:getSize()
        local dx = math.max(0, math.floor((self.dimen.w - (s.w or 0)) / 2))
        local dy = math.max(0, math.floor((self.dimen.h - (s.h or 0)) / 2))
        self[1]:paintTo(bb, x + dx, y + dy)
    end
    if bb and bb.paintBorder then
        bb:paintBorder(x, y, self.dimen.w, self.dimen.h, 1, ink(), 0, 0)
    end
end

function ReadingLog:fixedCover(book, w, h)
    self.missing_covers = self.missing_covers or {}
    if not self._covers_ready then
        self.missing_covers[#self.missing_covers + 1] = book
        return self:emptyCover(w, h)
    end
    local bb, ready = Tiles.getCover(self.cover_cache, self.covers, book, w - 2, h - 2)
    if not ready then self.missing_covers[#self.missing_covers + 1] = book end
    local child
    if bb then
        local bw, bh = bb:getWidth(), bb:getHeight()
        local box_w, box_h = w - 2, h - 2
        if bw < box_w - 1 or bh < box_h - 1 then
            local RenderImage = require("ui/renderimage")
            local scale = math.max(box_w / bw, box_h / bh)
            local nw = math.max(box_w, math.floor(bw * scale + 0.5))
            local nh = math.max(box_h, math.floor(bh * scale + 0.5))
            local scaled = RenderImage:scaleBlitBuffer(bb, nw, nh, false)
            local cropped = require("ffi/blitbuffer").new(box_w, box_h, scaled:getType())
            cropped:blitFrom(scaled, 0, 0,
                math.max(0, math.floor((nw - box_w) / 2)),
                math.max(0, math.floor((nh - box_h) / 2)),
                box_w, box_h)
            scaled:free()
            bb = cropped
        end
        local ImageWidget = require("ui/widget/imagewidget")
        child = ImageWidget:new{
            image = bb, image_disposable = false,
            width = bb:getWidth(), height = bb:getHeight(),
        }
    end
    return Sized:new{ width = w, height = h, child or VerticalSpan:new{ width = 1 } }
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

--- "Done by Sat 12 Dec", without the book title.
function ReadingLog:doneByLine(book)
    local line = self:forecastCaption(book)
    if type(line) ~= "string" then return nil end
    local date = line:match("done by (.+)$")
    if not date or date == "" then return nil end
    return "Done by " .. date
end

function ReadingLog:measure()
    local W = math.floor(self.dimen.w or 0)
    local H = math.floor(self.dimen.h or 0)
    local narrow = W < 900
    local margin = narrow and 18 or 36
    local inner = math.max(200, W - 2 * margin)
    local style = self:statsStyle()
    local tab = self._tab or "today"
    local detailed = style == "detailed"
    local minimal = style == "minimal"
    local card = self:continueStyle() == "card"
    local yearly = Stats.yearGoalOf(self.plugin and self.plugin.settings)
    local show_main = not (detailed and tab ~= "today")
    local button_h = math.max(Tiles.minTouch(), narrow and 48 or 56)
    local header_h = narrow and 76 or 98
    local switch_h = detailed and (narrow and 48 or 54) or 0
    local gap = narrow and 12 or 18
    local goal_h = 0
    if yearly and show_main and style == "standard" then
        goal_h = narrow and 70 or 84
    end
    local chrome = header_h + button_h + switch_h + margin + gap * 3
    local room = math.max(240, H - chrome)
    local week_h, continue_h
    if not show_main then
        week_h, continue_h = 0, 0
    elseif minimal then
        week_h = narrow and 128 or 156
        continue_h = room - week_h - gap
    elseif detailed then
        week_h = narrow and 236 or 280
        continue_h = room - week_h - gap
    else
        week_h = math.floor(room * (narrow and 0.34 or 0.32))
        local week_min = narrow and 210 or 270
        local week_max = narrow and 280 or 440
        if week_h < week_min then week_h = week_min end
        if week_h > week_max then week_h = week_max end
        continue_h = room - week_h - goal_h
        local continue_min = card and (narrow and 240 or 300) or (narrow and 420 or 560)
        if continue_h < continue_min then
            week_h = math.max(week_min - 30, week_h - (continue_min - continue_h))
            continue_h = room - week_h - goal_h
        end
    end
    return {
        narrow = narrow, margin = margin, inner = inner, gap = gap,
        header_h = header_h, button_h = button_h, switch_h = switch_h,
        week_h = week_h, continue_h = continue_h, goal_h = goal_h,
        show_main = show_main, card = card, detailed = detailed,
        minimal = minimal, yearly = yearly, style = style, tab = tab,
        pad = narrow and 12 or 16,
    }
end

function ReadingLog:box(child)
    local m = self._m or {}
    return FrameContainer:new{
        padding = m.pad or 14,
        bordersize = 2,
        radius = (m.narrow and 12 or 16),
        color = ink(),
        background = paper(),
        child,
    }
end

function ReadingLog:contentWidth()
    local m = self._m
    return m.inner - (m.pad + 2) * 2
end

function ReadingLog:sectionLabel(text)
    return heading(text, self._m.narrow and 16 or 18)
end

function ReadingLog:spreadPair(left, right, width)
    local gap = math.max(8, width - left:getSize().w - right:getSize().w)
    return HorizontalGroup:new{
        align = "center",
        left,
        HorizontalSpan:new{ width = gap },
        right,
    }
end

function ReadingLog:coverSizes(n)
    local m = self._m
    n = math.max(1, n or 1)
    local gap = m.narrow and 8 or 12
    local slot = math.floor((m.inner - gap * (n - 1)) / n)
    if slot < 72 then slot = 72 end
    local fw = math.floor(m.inner * (m.card and 0.28 or 0.25))
    local fh = math.floor(fw * 3 / 2)
    local row_h = math.floor(slot * 3 / 2)
    -- Keep the featured cover at about a quarter of the page. The recent
    -- row gives up height first when the screen cannot hold both at 2:3.
    local reserve = (m.narrow and 460 or 700)
    if m.yearly and m.style ~= "minimal" then reserve = reserve + (m.narrow and 64 or 84) end
    if m.detailed then reserve = reserve + (m.narrow and 56 or 64) end
    if m.minimal then reserve = m.narrow and 280 or 360 end
    if m.card then reserve = (m.narrow and 420 or 620) + (m.yearly and 80 or 0) end
    local max_row = self.dimen.h - reserve - (m.card and 0 or fh)
    if not m.card and max_row > 80 and row_h > max_row then
        row_h = max_row
    end
    return {
        feat_w = fw, feat_h = fh, feat_floor_w = math.floor(fw * 0.82),
        slot = slot, row_h = row_h, row_gap = gap,
    }
end

function ReadingLog:buildCoverRow(books, sizes)
    local n = #books
    local gap = sizes.row_gap
    local slot = sizes.slot
    -- bookCover keeps a 2:3 cover. Give it that height so the row uses the full width.
    local cover_h = sizes.row_h
    local row = HorizontalGroup:new{ align = "top" }
    for i, book in ipairs(books) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local cover = self:fixedCover(book, slot, cover_h)
        local pct = Core.progressPercent(book)
        local col = VerticalGroup:new{
            align = "center",
            cover,
            VerticalSpan:new{ width = 8 },
            Bar:new{ width = slot, height = 4, fraction = tonumber(book.percent) or 0 },
            VerticalSpan:new{ width = 4 },
            muted(string.format("%d%% Read", pct), self._m.narrow and 12 or 14),
        }
        table.insert(row, Hit:new{
            width = col:getSize().w,
            height = col:getSize().h,
            callback = function() self:openBook(book) end,
            col,
        })
    end
    return row
end

function ReadingLog:featuredCard(book, sizes)
    local m = self._m
    local cw, ch = sizes.feat_w, sizes.feat_h
    local cover = Hit:new{
        width = cw, height = ch,
        callback = function() self:openBook(book) end,
        self:coverBox(book, cw, ch),
    }
    local text_w = math.max(80, self:contentWidth() - cw - m.gap)
    local pct = Core.progressPercent(book)
    local author = book.authors and book.authors[1] or ""
    local text = VerticalGroup:new{ align = "left" }
    table.insert(text, TextWidget:new{
        text = book.title or "", face = face(m.narrow and 18 or 22),
        bold = true, fgcolor = ink(), max_width = text_w,
    })
    if author ~= "" then
        table.insert(text, VerticalSpan:new{ width = 4 })
        table.insert(text, TextWidget:new{
            text = author, face = face(m.narrow and 14 or 16),
            fgcolor = grey(), max_width = text_w,
        })
    end
    table.insert(text, VerticalSpan:new{ width = 14 })
    table.insert(text, Bar:new{ width = text_w, height = 4, fraction = tonumber(book.percent) or 0 })
    table.insert(text, VerticalSpan:new{ width = 6 })
    local pct_w = muted(string.format("%d%% Read", pct), m.narrow and 13 or 15)
    local done = self:doneByLine(book)
    if done then
        local done_w = muted(done, m.narrow and 12 or 14)
        table.insert(text, self:spreadPair(pct_w, done_w, text_w))
    else
        table.insert(text, pct_w)
    end
    local row = HorizontalGroup:new{
        align = "center",
        cover,
        HorizontalSpan:new{ width = m.gap },
        text,
    }
    return self:box(row)
end

function ReadingLog:buttonFace(text, width, height, filled)
    local label = TextWidget:new{
        text = text, face = face(16), bold = true,
        fgcolor = filled and paper() or ink(),
    }
    return FrameContainer:new{
        padding = 0,
        bordersize = filled and 0 or 2,
        radius = 10,
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

function ReadingLog:buildCard(books, sizes)
    local m = self._m
    local n = #books
    local pick = math.floor(tonumber(self._pick) or 1)
    if pick < 1 or pick > n then pick = 1 end
    self._pick = pick
    local book = books[pick]
    local cw, ch = sizes.feat_w, sizes.feat_h
    local text_w = math.max(100, self:contentWidth() - cw - m.gap)
    local record = self:bookRecord(book)
    local days_line = type(record) == "table" and Stats.bookDaysLine(record.days, record.seconds)
    local pct = Core.progressPercent(book)
    local left_secs = Core.knownTimeLeft(book)
    local function cycle()
        self._pick = pick % n + 1
        self:reload()
    end
    local kicker = muted(_("CONTINUE READING"), 12)
    local pager = body(string.format("%d / %d ›", pick, n), 15, true)
    local top = self:spreadPair(kicker, Hit:new{
        width = pager:getSize().w + 8,
        height = pager:getSize().h + 8,
        callback = cycle,
        pager,
    }, text_w)
    local text = VerticalGroup:new{ align = "left", top, VerticalSpan:new{ width = 8 } }
    table.insert(text, TextWidget:new{
        text = book.title or "", face = face(m.narrow and 18 or 22),
        bold = true, fgcolor = ink(), max_width = text_w,
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
    table.insert(text, Bar:new{ width = text_w, height = 5, fraction = tonumber(book.percent) or 0 })
    table.insert(text, VerticalSpan:new{ width = 6 })
    local pct_w = body(pct .. "%", 16, true)
    if left_secs then
        local left_w = muted(Stats.weekHours(left_secs) .. " " .. _("left"), 15)
        table.insert(text, self:spreadPair(pct_w, left_w, text_w))
    else
        table.insert(text, pct_w)
    end
    local bw = math.floor((text_w - 10) / 2)
    local bh = math.max(44, Tiles.minTouch())
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
    local row = HorizontalGroup:new{
        align = "center",
        Hit:new{
            width = cw, height = ch,
            callback = function() self:openBook(book) end,
            self:coverBox(book, cw, ch),
        },
        HorizontalSpan:new{ width = m.gap },
        text,
    }
    return self:box(row)
end

function ReadingLog:showDetails(book)
    if self.plugin and self.plugin.showBookDetails then
        pcall(self.plugin.showBookDetails, self.plugin, book, nil)
    end
end

function ReadingLog:buildContinue(sizes)
    self.missing_covers = {}
    local books = self:continueBooks()
    local m = self._m
    local col = VerticalGroup:new{ align = "left" }
    if #books == 0 then
        table.insert(col, self:sectionLabel(_("Currently reading")))
        table.insert(col, VerticalSpan:new{ width = 8 })
        table.insert(col, muted(_("Nothing in progress."), 16))
        return col
    end
    if m.card then
        table.insert(col, self:buildCard(books, sizes))
        return col
    end
    table.insert(col, self:sectionLabel(_("Currently reading")))
    table.insert(col, VerticalSpan:new{ width = 8 })
    table.insert(col, self:featuredCard(books[1], sizes))
    table.insert(col, VerticalSpan:new{ width = m.gap })
    table.insert(col, self:sectionLabel(_("Recent books")))
    table.insert(col, VerticalSpan:new{ width = 8 })
    table.insert(col, self:buildCoverRow(books, sizes))
    return col
end

function ReadingLog:goalRow(inner_w)
    local m = self._m
    local goal = m.yearly
    if not goal then return nil end
    local done = self:finishedCount(goal.year)
    local frac = Stats.yearFraction(done, goal.amount)
    local pct = math.floor(frac * 100 + 0.5)
    local ylbl = heading(tostring(goal.year), m.narrow and 18 or 22)
    local plbl = body(pct .. "%", m.narrow and 18 or 22, true)
    local blbl = muted(string.format("%d/%d books", done, goal.amount), m.narrow and 14 or 16)
    local rail_w = inner_w - ylbl:getSize().w - plbl:getSize().w - blbl:getSize().w - 36
    if rail_w < 48 then rail_w = math.max(48, math.floor(inner_w * 0.35)) end
    return VerticalGroup:new{
        align = "left",
        self:sectionLabel(_("Reading goals")),
        VerticalSpan:new{ width = 10 },
        HorizontalGroup:new{
            align = "center",
            ylbl,
            HorizontalSpan:new{ width = 12 },
            Bar:new{ width = rail_w, height = m.narrow and 10 or 12, fraction = frac },
            HorizontalSpan:new{ width = 12 },
            plbl,
            HorizontalSpan:new{ width = 10 },
            blbl,
        },
    }
end

function ReadingLog:ringRadius(content_w, band_h, n)
    n = math.max(1, n or 7)
    local slot = math.floor(content_w / n)
    local r = math.floor((band_h - 26) / 2)
    local cap = math.floor(slot * 0.42)
    if r > cap then r = cap end
    if r < (self._m.narrow and 11 or 14) then r = self._m.narrow and 11 or 14 end
    local ring_cap = self._m and self._m.narrow and 16 or 22
    ring_cap = ring_cap - (self._ring_cut or 0)
    if ring_cap < 10 then ring_cap = 10 end
    if r > ring_cap then r = ring_cap end
    return r
end

function ReadingLog:averageColumns(summary, width)
    local m = self._m
    local week = summary.week or {}
    local big = m.narrow and 16 or (m.detailed and 16 or 18)
    local function column(number, caption)
        local n = TextWidget:new{
            text = number, face = face(big), bold = true, fgcolor = ink(),
            max_width = math.floor(width / 2) - 8,
        }
        local c = muted(caption, m.narrow and 12 or 14)
        local col = VerticalGroup:new{
            align = "left",
            n,
            VerticalSpan:new{ width = 2 },
            c,
        }
        return CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width / 2), h = col:getSize().h },
            col,
        }
    end
    return HorizontalGroup:new{
        align = "top",
        column(Stats.pagesLabel(week.average_pages), _("a day on average")),
        column(Stats.weekHours(week.average_seconds), _("a day on average")),
    }
end

function ReadingLog:buildWeekTile(summary, target_h, compact, content_w)
    local m = self._m
    content_w = content_w or self:contentWidth()
    local head = heading(_("THIS WEEK"), m.narrow and 14 or 16)
    local totals = muted(Stats.weekTotalLine(summary.week), m.narrow and 13 or 15)
    local days = summary.week.days or {}
    local goal_frac = self:goal() and select(2, Stats.goalProgress(summary.today, self:goal())) or nil
    local used_guess = (m.narrow and 150 or 190)
    local band = math.max(used_guess, (target_h or used_guess) - (m.pad + 2) * 2 - 120)
    if compact then band = m.narrow and 78 or 96 end
    local r = self:ringRadius(content_w, band, #days)
    local rings = RingRow:new{
        days = days, width = content_w, radius = r,
        goal_frac = goal_frac, label_size = m.narrow and 13 or 15,
    }
    local body_col = VerticalGroup:new{
        align = "left",
        self:spreadPair(head, totals, content_w),
        VerticalSpan:new{ width = compact and 8 or 12 },
        rings,
        VerticalSpan:new{ width = compact and 8 or 14 },
        self:averageColumns(summary, content_w),
        VerticalSpan:new{ width = 8 },
    }
    local streak = muted(Stats.streakCaption(summary.streak, self:bestStreak(summary)), m.narrow and 13 or 14)
    local goal = self:goal()
    if goal then
        local goal_text = Stats.goalLine(summary.today, goal) .. " today"
        local goal_w = muted(goal_text, m.narrow and 12 or 14)
        if streak:getSize().w + goal_w:getSize().w + 16 <= content_w then
            table.insert(body_col, self:spreadPair(streak, goal_w, content_w))
        else
            table.insert(body_col, streak)
        end
    else
        table.insert(body_col, streak)
    end
    table.insert(body_col, 1, HorizontalSpan:new{ width = content_w })
    return self:box(body_col)
end

function ReadingLog:buildActivity(summary, height, content_w)
    local m = self._m
    content_w = content_w or self:contentWidth()
    local goal = self:goal()
    local frac = goal and select(2, Stats.goalProgress(summary.today, goal)) or nil
    local read = (summary.today.pages or 0) > 0 or (summary.today.seconds or 0) > 0
    local kind = frac and "arc" or (read and "read" or "empty")
    local r = (m.narrow and 36 or 52) - (self._ring_cut or 0)
    if r < 22 then r = 22 end
    local max_r = math.floor((content_w - 130) / 2)
    if max_r < 22 then max_r = 22 end
    if r > max_r then r = max_r end
    local glyph = RingGlyph:new{ radius = r, kind = kind, frac = frac or 0 }
    local text_w = math.max(60, content_w - (r * 2 + 8) - 10)
    local lines = VerticalGroup:new{
        align = "left",
        heading(_("ACTIVITY"), m.narrow and 13 or 15),
        VerticalSpan:new{ width = 8 },
        TextWidget:new{
            text = Stats.pagesLabel(summary.today.pages),
            face = face(m.narrow and 16 or 18), bold = true, fgcolor = ink(), max_width = text_w,
        },
        VerticalSpan:new{ width = 2 },
        muted(Stats.weekHours(summary.today.seconds) .. " " .. _("read"), m.narrow and 13 or 15),
        VerticalSpan:new{ width = 2 },
        TextWidget:new{
            text = Stats.streakLabel(summary.streak),
            face = face(m.narrow and 13 or 15), fgcolor = grey(), max_width = text_w,
        },
    }
    if goal then
        table.insert(lines, VerticalSpan:new{ width = 6 })
        table.insert(lines, muted(Stats.goalLine(summary.today, goal), 13))
    end
    local row = HorizontalGroup:new{
        align = "center",
        glyph,
        HorizontalSpan:new{ width = 10 },
        lines,
    }
    local extra = (height or 0) - row:getSize().h - (m.pad + 2) * 2
    local col = VerticalGroup:new{ align = "left", HorizontalSpan:new{ width = content_w }, row }
    if extra > 8 then table.insert(col, VerticalSpan:new{ width = extra }) end
    return self:box(col)
end

function ReadingLog:buildMinimalStrip(summary)
    local m = self._m
    local content_w = self:contentWidth()
    local col_w = math.floor(content_w / 3)
    local big = m.narrow and 26 or 34
    local function column(number, caption)
        local n = TextWidget:new{
            text = number, face = face(big), bold = true, fgcolor = ink(), max_width = col_w - 8,
        }
        local c = muted(caption, m.narrow and 12 or 14)
        local col = VerticalGroup:new{ align = "left", n, VerticalSpan:new{ width = 2 }, c }
        return CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = math.max(col:getSize().h, m.narrow and 64 or 78) },
            col,
        }
    end
    local best = self:bestStreak(summary)
    local streak_n = tostring(math.floor(tonumber(summary.streak) or 0))
    local streak_c = best > (tonumber(summary.streak) or 0) and (_("Streak") .. " · " .. _("best") .. " " .. best) or _("Streak")
    return self:box(HorizontalGroup:new{
        align = "center",
        column(Stats.weekHours(summary.today.seconds), _("Today")),
        column(Stats.weekHours(summary.week.seconds), _("This week")),
        column(streak_n, streak_c),
    })
end

function ReadingLog:buildMonth(summary)
    local m = self._m
    local month = summary.month or {}
    local grid_w = m.inner
    local chrome = m.narrow and 340 or 420
    local budget = math.max(180, self.dimen.h - chrome)
    local cell = math.floor((budget - 48) / 6) - 8
    if cell > (m.narrow and 40 or 72) then cell = m.narrow and 40 or 72 end
    if cell < 22 then cell = 22 end
    return VerticalGroup:new{
        align = "left",
        heading(month.name or _("Month"), m.narrow and 22 or 28),
        VerticalSpan:new{ width = 8 },
        muted(Stats.monthCaption(month), 16),
        VerticalSpan:new{ width = m.gap },
        self:box(MonthGrid:new{
            month = month,
            width = grid_w - (m.pad + 2) * 2,
            cell_max = cell,
        }),
    }
end

function ReadingLog:buildYear(summary)
    local m = self._m
    local year = summary.year or {}
    local col = VerticalGroup:new{ align = "left" }
    table.insert(col, heading(tostring(year.year or os.date("%Y")), m.narrow and 26 or 34))
    table.insert(col, VerticalSpan:new{ width = 12 })
    local content_w = self:contentWidth()
    local big = m.narrow and 28 or 40
    local function column(number, caption)
        return VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = number, face = face(big), bold = true, fgcolor = ink(), max_width = math.floor(content_w / 2) - 8 },
            VerticalSpan:new{ width = 2 },
            muted(caption, 14),
        }
    end
    local pages_col = column(Stats.pagesLabel(year.pages), _("this year"))
    local time_col = column(Stats.weekHours(year.seconds), string.format("%d %s", math.floor(tonumber(year.days) or 0), _("days")))
    local col_h = math.max(pages_col:getSize().h, time_col:getSize().h) + 8
    table.insert(col, self:box(HorizontalGroup:new{
        align = "top",
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(content_w / 2), h = col_h },
            pages_col,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(content_w / 2), h = col_h },
            time_col,
        },
    }))
    local goals = self:goalRow(m.inner)
    if goals then
        table.insert(col, VerticalSpan:new{ width = m.gap })
        table.insert(col, goals)
    else
        table.insert(col, VerticalSpan:new{ width = 10 })
        table.insert(col, muted(Stats.yearTotalsLine(year), 15))
    end
    return col
end

function ReadingLog:missingNote()
    return self:box(VerticalGroup:new{
        align = "left",
        heading(_(Stats.NOTE), self._m.narrow and 16 or 18),
        VerticalSpan:new{ width = 6 },
        muted(_("KOReader's statistics plugin keeps the time and the pages."), 15),
    })
end

function ReadingLog:buildStats(summary, target_h)
    if summary.missing then return self:missingNote() end
    local m = self._m
    if m.minimal then return self:buildMinimalStrip(summary) end
    if m.detailed and m.tab == "month" then return self:buildMonth(summary) end
    if m.detailed and m.tab == "year" then return self:buildYear(summary) end
    if m.detailed then
        local gap = 12
        local activity_w = math.floor(m.inner * 0.40)
        local week_w = m.inner - gap - activity_w
        local chrome = (m.pad + 2) * 2
        local week = self:buildWeekTile(summary, target_h, true, week_w - chrome)
        local activity = self:buildActivity(summary, week:getSize().h, activity_w - chrome)
        return HorizontalGroup:new{
            align = "top",
            activity,
            HorizontalSpan:new{ width = gap },
            week,
        }
    end
    return self:buildWeekTile(summary, target_h, false)
end

local Segmented = Widget:extend{ width = 0, height = 48, selected = "today", labels = nil }

function Segmented:init()
    self.dimen = Geom:new{
        w = math.floor(tonumber(self.width) or 0),
        h = math.floor(tonumber(self.height) or 48),
    }
end

function Segmented:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Segmented:paintTo(bb, x, y)
    if bb == nil or type(bb.paintRect) ~= "function" then return end
    local w, h = self.dimen.w, self.dimen.h
    local labels = self.labels or { "Today", "Month", "Year" }
    local ids = { "today", "month", "year" }
    local radius = 12
    local third = math.floor(w / 3)
    local selected = 1
    for i, id in ipairs(ids) do
        if self.selected == id then selected = i end
    end
    if bb.paintRoundedRect then
        bb:paintRoundedRect(x, y, w, h, paper(), radius)
    else
        bb:paintRect(x, y, w, h, paper())
    end
    local function fillSegment(index)
        local sx = x + (index - 1) * third
        local sw = index == 3 and (x + w - sx) or third
        if index == 1 and bb.paintRoundedRect then
            bb:paintRoundedRect(sx, y, sw + radius, h, ink(), radius)
            bb:paintRect(sx + sw - 2, y, radius, h, ink())
        elseif index == 3 and bb.paintRoundedRect then
            bb:paintRoundedRect(sx - radius, y, sw + radius, h, ink(), radius)
            bb:paintRect(sx, y, radius, h, ink())
        else
            bb:paintRect(sx, y, sw, h, ink())
        end
    end
    fillSegment(selected)
    if bb.paintBorder then
        bb:paintBorder(x, y, w, h, 2, ink(), radius, 0)
    end
    if selected == 1 then
        bb:paintRect(x + third * 2, y + 10, 2, h - 20, ink())
    elseif selected == 3 then
        bb:paintRect(x + third, y + 10, 2, h - 20, ink())
    end
    for i, label in ipairs(labels) do
        local sx = x + (i - 1) * third
        local sw = i == 3 and (w - third * 2) or third
        local text = TextWidget:new{
            text = label,
            face = face(16),
            bold = true,
            fgcolor = i == selected and paper() or ink(),
        }
        local tw = text:getSize().w or 0
        local th = text:getSize().h or 0
        text:paintTo(bb, sx + math.floor((sw - tw) / 2), y + math.floor((h - th) / 2))
        text:free()
    end
end

function ReadingLog:buildSwitch()
    local m = self._m
    local h = m.switch_h > 0 and m.switch_h or 48
    local selected = self._tab or "today"
    local painted = Segmented:new{
        width = m.inner,
        height = h,
        selected = selected,
        labels = { _("Today"), _("Month"), _("Year") },
    }
    local cell = math.floor(m.inner / 3)
    local ids = { "today", "month", "year" }
    local hits = HorizontalGroup:new{ align = "center" }
    for i, id in ipairs(ids) do
        local w = i == 3 and (m.inner - cell * 2) or cell
        table.insert(hits, Hit:new{
            width = w,
            height = h,
            callback = function()
                self._tab = id
                self:reload()
            end,
            VerticalSpan:new{ width = h },
        })
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = m.inner, h = h },
        allow_mirroring = false,
        painted,
        hits,
    }
end

function ReadingLog:buildHeader()
    local m = self._m
    local date = heading(dateLine(), m.narrow and 13 or 15)
    local battery = batteryText()
    local left = VerticalGroup:new{ align = "left", date }
    if battery then
        table.insert(left, VerticalSpan:new{ width = 2 })
        table.insert(left, muted(battery, m.narrow and 13 or 15))
    end
    self._clock = TextWidget:new{
        text = clockText(),
        face = face(m.narrow and 24 or 30),
        bold = true,
        fgcolor = ink(),
    }
    local gap = math.max(8, m.inner - left:getSize().w - self._clock:getSize().w)
    local header = FrameContainer:new{
        padding = 0,
        padding_left = m.margin,
        padding_right = m.margin,
        padding_top = m.narrow and 14 or 22,
        bordersize = 0,
        background = paper(),
        HorizontalGroup:new{
            align = "center",
            left,
            HorizontalSpan:new{ width = gap },
            self._clock,
        },
    }
    self.header = header
    return header
end

function ReadingLog:assemble(summary, sizes)
    local m = self._m
    local parts = VerticalGroup:new{ align = "left", self:buildHeader() }
    if m.show_main then
        table.insert(parts, self:pad(self:buildContinue(sizes), m.gap))
        if m.yearly and m.style ~= "minimal" and not (m.detailed and m.tab ~= "today") then
            local goals = self:goalRow(m.inner)
            if goals then table.insert(parts, self:pad(goals, m.gap)) end
        end
        table.insert(parts, self:pad(self:buildStats(summary, m.week_h), m.gap))
    else
        table.insert(parts, self:pad(self:buildStats(summary, 0), m.gap))
    end
    if m.detailed then
        table.insert(parts, self:pad(self:buildSwitch(), m.narrow and 8 or 10))
    end
    return parts, self:buildLibraryButton(self.dimen.w)
end

function ReadingLog:build()
    local summary = self:readStats()
    self.summary = summary
    self._ring_cut = 0
    self._m = self:measure()
    local m = self._m
    local books_n = #(self:continueBooks() or {})
    local cap = self.layout.covers or (m.narrow and 4 or 5)
    if books_n < 1 then books_n = 1 end
    if books_n > cap then books_n = cap end
    local sizes = self:coverSizes(books_n)
    local parts, button = self:assemble(summary, sizes)
    local guard = 0
    while guard < 8 do
        local overflow = parts:getSize().h + button:getSize().h - self.dimen.h
        if overflow <= 0 then break end
        guard = guard + 1
        local row_floor = m.narrow and 96 or 150
        if not m.card and sizes.row_h > row_floor then
            sizes.row_h = math.max(row_floor, sizes.row_h - math.ceil(overflow * 0.75))
        else
            local floor_h = math.floor((sizes.feat_floor_w or 80) * 3 / 2)
            sizes.feat_h = math.max(floor_h, sizes.feat_h - math.ceil(overflow * 0.5))
            sizes.feat_w = math.max(sizes.feat_floor_w or 64, math.floor(sizes.feat_h * 2 / 3))
        end
        if m.gap > 6 then m.gap = math.max(6, m.gap - 2) end
        self._ring_cut = (self._ring_cut or 0) + 2
        parts, button = self:assemble(summary, sizes)
    end
    local room = self.dimen.h - parts:getSize().h - button:getSize().h
    local spacer = 0
    if room > 6 then spacer = math.min(12, room) end
    self[1] = FrameContainer:new{
        padding = 0, bordersize = 0, background = paper(),
        width = self.dimen.w, height = self.dimen.h,
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
        radius = 12,
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
        padding_bottom = 8,
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
