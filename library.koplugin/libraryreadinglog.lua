--- Reading log home page.
-- Continue reading uses the same books and covers as the Library.
-- Today, this week and the streak come from librarystats.lua.
-- Black on white. KOReader's night mode inverts that, so the contrast
-- stays the same in the dark. The clock is the only timed refresh, and
-- only the header is marked dirty.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
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

--- Seven columns. The letter, the bar and today's mark share one x.
local WeekChart = Widget:extend{
    days = nil,
    width = 0,
    height = 0,
}

function WeekChart:init()
    self.dimen = Geom:new{ w = self.width or 0, h = self.height or 0 }
end

function WeekChart:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function WeekChart:paintTo(bb, x, y)
    if bb == nil or type(bb.paintRect) ~= "function" then return end
    local days = self.days or {}
    local n = #days
    if n < 1 then return end
    local gap = math.max(4, math.floor(self.dimen.w * 0.02))
    local slot = math.floor((self.dimen.w - gap * (n - 1)) / n)
    if slot < 8 then slot = 8 end
    -- Letters stay in their own band. Bars never climb into it.
    local label_h = math.max(22, math.floor(self.dimen.h * 0.28))
    local bar_top = y + label_h + 10
    local base = y + self.dimen.h - 2
    local bar_room = math.max(8, base - bar_top)
    local fractions = Stats.barFractions(days)
    local letter_face = face(self.label_size or 15)
    for i = 1, n do
        local day = days[i]
        local dx = x + (i - 1) * (slot + gap)
        local label = TextWidget:new{
            text = day.label or "",
            face = letter_face,
            bold = day.today and true or false,
            fgcolor = ink(),
        }
        local lw = label:getSize().w or 0
        local lx = dx + math.floor((slot - lw) / 2)
        label:paintTo(bb, lx, y)
        label:free()
        if day.today then
            bb:paintRect(lx, y + label_h - 4, math.max(8, lw), 3, ink())
        end
        local bw = math.max(6, math.floor(slot * 0.62))
        local bx = dx + math.floor((slot - bw) / 2)
        bb:paintRect(bx, base, bw, 1, ink())
        local frac = fractions[i] or 0
        if frac > 0 then
            local h = math.max(4, math.floor(bar_room * frac))
            bb:paintRect(bx, base - h, bw, h, ink())
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
    bb:paintRect(x, y + h - 1, w, 1, ink())
    local frac = tonumber(self.fraction) or 0
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    if frac > 0 then
        local fill = math.max(2, math.floor(w * frac))
        bb:paintRect(x, y, fill, math.max(2, h - 2), ink())
    end
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
    self:reload()
    self:scheduleClock()
    self:scheduleCovers()
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
    local path = Stats.dbPath(dir)
    local ok, summary = pcall(Stats.loadPath, path, os.time(), self:weekStart())
    if not ok or type(summary) ~= "table" then
        return Stats.missing(os.time(), self:weekStart())
    end
    return summary
end

function ReadingLog:continueBook()
    if self.plugin and self.plugin.continueBooks then
        local ok, books = pcall(self.plugin.continueBooks, self.plugin, 1)
        if ok and type(books) == "table" then return books[1] end
    end
    return nil
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

function ReadingLog:buildToday(summary, inner_w)
    local L = self.layout
    local minutes = Stats.minutes(summary.today.seconds)
    local number = TextWidget:new{
        text = tostring(minutes),
        face = face(L.today_size),
        bold = true,
        fgcolor = ink(),
    }
    local unit = TextWidget:new{
        text = _("min"),
        face = face(L.narrow and 18 or 22),
        bold = true,
        fgcolor = ink(),
    }
    local pages = body(Stats.pagesLabel(summary.today.pages), L.narrow and 16 or 18, true)
    local figure = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "bottom",
            number,
            HorizontalSpan:new{ width = 8 },
            unit,
        },
        VerticalSpan:new{ width = 4 },
        pages,
    }
    local badge = self:streakBadge(summary.streak)
    if L.narrow or figure:getSize().w + badge:getSize().w + L.gap > inner_w then
        return VerticalGroup:new{
            align = "left",
            figure,
            VerticalSpan:new{ width = L.gap },
            badge,
        }
    end
    local rest = math.max(L.gap, inner_w - figure:getSize().w - badge:getSize().w)
    return HorizontalGroup:new{
        align = "center",
        figure,
        HorizontalSpan:new{ width = rest },
        badge,
    }
end

function ReadingLog:streakBadge(streak)
    local label = body(_(Stats.streakLabel(streak)), self.layout.narrow and 16 or 18, true)
    return FrameContainer:new{
        padding = self.layout.narrow and 8 or 12,
        bordersize = 2,
        color = ink(),
        background = paper(),
        label,
    }
end

function ReadingLog:buildChart(summary, inner_w)
    local L = self.layout
    return WeekChart:new{
        days = summary.week.days,
        width = inner_w,
        height = L.chart_h,
        label_size = L.narrow and 14 or 16,
    }
end

function ReadingLog:timeLeft(book)
    return Core.timeLeftText(Core.knownTimeLeft(book))
end

function ReadingLog:buildContinue(inner_w)
    local L = self.layout
    local book = self:continueBook()
    local title = heading(_("Continue reading"), L.narrow and 18 or 20)
    if not book then
        return VerticalGroup:new{
            align = "left",
            title,
            VerticalSpan:new{ width = 8 },
            body(_("Nothing in progress."), 16),
        }
    end
    local cover_w, cover_h = L.cover_w, L.cover_h
    local cover = select(1, Tiles.bookCover(
        { covers = self.covers, cover_cache = self.cover_cache },
        book, cover_w, cover_h, book.title, book.authors and book.authors[1]))
    if cover and cover.needs_cover ~= nil then
        -- bookCover returns the widget; needs_cover is on the tile. Track below.
    end
    local bb, ready = Tiles.getCover(self.cover_cache, self.covers, book, cover_w, cover_h)
    if not ready then self.missing_covers = { book } else self.missing_covers = {} end
    if not cover then
        cover = FrameContainer:new{
            padding = 0, bordersize = 1, color = ink(), background = paper(),
            width = cover_w, height = cover_h,
            VerticalSpan:new{ width = cover_h },
        }
    end
    local text_w = math.max(80, inner_w - cover_w - L.gap - 8)
    local name = book.title or ""
    local author = book.authors and book.authors[1] or ""
    local pct = Core.progressPercent(book)
    local left = self:timeLeft(book)
    local progress = left and (pct .. "%  ·  " .. left .. " " .. _("left")) or (pct .. "%")
    local text = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = name, face = face(L.narrow and 17 or 20), bold = true, fgcolor = ink(), max_width = text_w },
        VerticalSpan:new{ width = 4 },
        TextWidget:new{ text = author, face = face(15), fgcolor = ink(), max_width = text_w },
        VerticalSpan:new{ width = 12 },
        Bar:new{ width = math.min(text_w, 280), height = 8, fraction = (tonumber(book.percent) or 0) },
        VerticalSpan:new{ width = 6 },
        body(progress, 16, true),
    }
    local row = HorizontalGroup:new{
        align = "center",
        cover,
        HorizontalSpan:new{ width = L.gap },
        text,
    }
    local card = FrameContainer:new{
        padding = L.narrow and 10 or 14,
        bordersize = Size.line.medium or 2,
        color = ink(),
        background = paper(),
        width = inner_w,
        row,
    }
    local hit = Hit:new{
        width = inner_w,
        height = card:getSize().h,
        callback = function() self:openBook(book) end,
        card,
    }
    return VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{ width = 10 },
        hit,
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

function ReadingLog:buildStats(summary, inner_w)
    local L = self.layout
    local col = VerticalGroup:new{ align = "left" }
    if summary.missing then
        table.insert(col, heading(_(Stats.NOTE), L.narrow and 18 or 22))
        table.insert(col, VerticalSpan:new{ width = 8 })
        table.insert(col, body(_("KOReader's statistics plugin keeps the time and the pages."), 16))
        return col
    end
    table.insert(col, heading(_("Today"), L.narrow and 18 or 20))
    table.insert(col, VerticalSpan:new{ width = 6 })
    table.insert(col, self:buildToday(summary, inner_w))
    table.insert(col, VerticalSpan:new{ width = L.gap })
    table.insert(col, heading(_("This week"), L.narrow and 18 or 20))
    table.insert(col, VerticalSpan:new{ width = 8 })
    table.insert(col, self:buildChart(summary, inner_w))
    table.insert(col, VerticalSpan:new{ width = 8 })
    table.insert(col, body(Stats.weekTotalLine(summary.week), 16, true))
    table.insert(col, VerticalSpan:new{ width = 2 })
    table.insert(col, body(Stats.weekAverageLine(summary.week), 15))
    return col
end

function ReadingLog:build()
    local width = self.dimen.w
    local L = self.layout
    local summary = self:readStats()
    self.summary = summary
    local inner = width - 2 * L.margin
    local title = heading(_("Reading log"), L.narrow and 20 or 24)
    local status = Core.statusLabel(clockText(), batteryText()) or clockText()
    self._clock = TextWidget:new{ text = status, face = face(L.narrow and 16 or 20), bold = true, fgcolor = ink() }
    local gap = math.max(8, width - 2 * L.margin - title:getSize().w - self._clock:getSize().w)
    local header = FrameContainer:new{
        padding = 0,
        padding_left = L.margin,
        padding_right = L.margin,
        padding_top = L.narrow and 10 or 16,
        padding_bottom = 8,
        bordersize = 0,
        background = paper(),
        HorizontalGroup:new{
            align = "center",
            title,
            HorizontalSpan:new{ width = gap },
            self._clock,
        },
    }
    self.header = header
    local rule = LineWidget:new{
        background = ink(),
        dimen = Geom:new{ w = width, h = Size.line.thin or 1 },
    }
    local button = self:buildLibraryButton(width)
    local body_col = VerticalGroup:new{
        align = "left",
        header,
        rule,
        self:pad(self:buildContinue(inner), L.gap),
        self:pad(self:buildStats(summary, inner), L.gap),
    }
    local used = body_col:getSize().h + button:getSize().h
    local spacer = math.max(L.gap, self.dimen.h - used)
    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = paper(),
        width = width,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            body_col,
            VerticalSpan:new{ width = spacer },
            button,
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
