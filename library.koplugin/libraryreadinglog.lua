--- Reading log home page.
-- Continue reading uses the same books and tiles as the Library.
-- Today, this week and the streak come from librarystats.lua.
-- Black and white only. The page is painted once; the clock is the
-- only thing that refreshes, and only the header region, once a minute.

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

local CenterLetter, CenterIn

local ReadingLog = InputContainer:extend{
    name = "library_reading_log",
    covers_fullscreen = true,
    plugin = nil,
}

local function face(name, size)
    return Font:getFace(name, size)
end

local function clockText()
    local twelve = false
    if G_reader_settings and G_reader_settings.isTrue then
        local ok, on = pcall(function() return G_reader_settings:isTrue("twelve_hour_clock") end)
        twelve = ok and on and true or false
    end
    if twelve then
        local text = os.date("%I:%M %p")
        return (text:gsub("^0", ""))
    end
    return os.date("%H:%M")
end

local function batteryText()
    if not (Device.getPowerDevice) then return nil end
    local ok, power = pcall(Device.getPowerDevice, Device)
    if not ok or type(power) ~= "table" or type(power.getCapacity) ~= "function" then
        return nil
    end
    local ok_n, n = pcall(power.getCapacity, power)
    if not ok_n then return nil end
    return Core.batteryLabel(n)
end

local Bars = Widget:extend{
    days = nil,
    width = 0,
    height = 0,
}

function Bars:init()
    self.dimen = Geom:new{ w = self.width or 0, h = self.height or 0 }
end

function Bars:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Bars:paintTo(bb, x, y)
    if bb == nil or type(bb.paintRect) ~= "function" then return end
    local days = self.days or {}
    local n = #days
    if n < 1 then return end
    local fractions = Stats.barFractions(days)
    local gap = Size.padding.default
    local slot = math.floor((self.dimen.w - gap * (n - 1)) / n)
    if slot < 4 then slot = 4 end
    local bar_h = math.max(8, self.dimen.h - 2)
    for i = 1, n do
        local dx = x + (i - 1) * (slot + gap)
        bb:paintRect(dx, y + bar_h - 1, slot, 1, Blitbuffer.COLOR_BLACK)
        local frac = fractions[i] or 0
        if frac > 0 then
            local h = math.max(2, math.floor(bar_h * frac))
            bb:paintRect(dx, y + bar_h - h, slot, h, Blitbuffer.COLOR_BLACK)
        end
    end
end

local Hit = InputContainer:extend{}

function Hit:init()
    local child = self[1]
    local w = self.width
    local h = self.height
    if (not w or not h) and child and child.getSize then
        local sz = child:getSize()
        w = w or (sz and sz.w) or 0
        h = h or (sz and sz.h) or 0
    end
    self.dimen = Geom:new{ w = w or 0, h = h or 0 }
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
    self.cover_cache = Tiles.newCoverCache(12)
    self.covers = { store = Covers.getStore(), bim = self.plugin and self.plugin.getBIM and self.plugin:getBIM() }
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
    if not ok or type(summary) ~= "table" then return Stats.missing(os.time(), self:weekStart()) end
    return summary
end

function ReadingLog:continueBooks()
    if self.plugin and self.plugin.continueBooks then
        local ok, books = pcall(self.plugin.continueBooks, self.plugin, 4)
        if ok and type(books) == "table" then return books end
    end
    return {}
end

local function sectionTitle(text)
    return TextWidget:new{ text = text, face = face("cfont", 17), bold = true }
end

local function bodyText(text, bold)
    return TextWidget:new{ text = text, face = face("cfont", 20), bold = bold and true or false }
end

local function quietText(text)
    return TextWidget:new{ text = text, face = face("cfont", 16), fgcolor = Blitbuffer.COLOR_GRAY_4 }
end

function ReadingLog:buildContinue(width)
    local books = self:continueBooks()
    local gap = Size.padding.default
    local margin = Size.margin.default + gap
    local header = FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_top = Size.padding.default,
        bordersize = 0,
        sectionTitle(_("Continue reading")),
    }
    if #books == 0 then
        return VerticalGroup:new{
            align = "left",
            header,
            FrameContainer:new{
                padding = 0,
                padding_left = margin,
                padding_top = Size.padding.small,
                bordersize = 0,
                quietText(_("Nothing in progress.")),
            },
        }
    end
    local label_h = Tiles.labelHeight()
    local header_h = header:getSize().h
    local cl = Core.continueLayout(width, math.floor(self.dimen.h * 0.42), #books,
        label_h, header_h, gap, { slots = math.min(4, #books), frac = 0.72, min_rest = 0 })
    local row = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = gap } }
    local now = os.time()
    self.missing_covers = {}
    if not cl then
        return VerticalGroup:new{ align = "left", header }
    end
    for i = 1, cl.count do
        local book = books[i]
        local tile = Tiles.Tile:new{
            width = cl.slot_w,
            height = cl.tile_h,
            cover_h = cl.cover_h,
            caption = self:caption(book, now),
            book = book,
            covers = self.covers,
            cover_cache = self.cover_cache,
            on_tap = function() self:openBook(book) end,
        }
        if tile.needs_cover then self.missing_covers[#self.missing_covers + 1] = book end
        table.insert(row, tile)
        table.insert(row, HorizontalSpan:new{ width = gap })
    end
    return VerticalGroup:new{ align = "left", header, row }
end

function ReadingLog:caption(book, now)
    if type(book) ~= "table" then return nil end
    local parts = {}
    local pct = Core.percentText(book.percent)
    if book.status ~= "reading" and pct then parts[#parts + 1] = pct end
    local ago = Core.relativeTime(book.last_opened, now or os.time())
    if ago then parts[#parts + 1] = ago end
    if #parts == 0 then return nil end
    return table.concat(parts, " · ")
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

function ReadingLog:buildStats(width, summary)
    local margin = Size.margin.default + Size.padding.default
    local function block(widget, top)
        return FrameContainer:new{
            padding = 0,
            padding_left = margin,
            padding_right = margin,
            padding_top = top or Size.padding.default,
            bordersize = 0,
            width = width,
            widget,
        }
    end
    local col = VerticalGroup:new{ align = "left" }
    if summary.missing then
        table.insert(col, block(sectionTitle(_(Stats.NOTE)), Size.padding.large))
        table.insert(col, block(quietText(_("KOReader's statistics plugin keeps the time and the pages.")), Size.padding.small))
        return col
    end
    table.insert(col, block(sectionTitle(_("Today")), Size.padding.large))
    table.insert(col, block(bodyText(Stats.todayLine(summary.today), true), Size.padding.small))
    table.insert(col, block(sectionTitle(_("This week")), Size.padding.large))
    local letters = HorizontalGroup:new{ align = "center" }
    local days = summary.week.days
    local gap = Size.padding.default
    local slot = math.floor((width - 2 * margin - gap * (#days - 1)) / math.max(1, #days))
    for i, day in ipairs(days) do
        local label = TextWidget:new{
            text = day.label,
            face = face("cfont", 15),
            bold = day.today and true or false,
        }
        table.insert(letters, CenterLetter(label, slot))
        if i < #days then
            table.insert(letters, HorizontalSpan:new{ width = gap })
        end
    end
    table.insert(col, block(letters, Size.padding.small))
    local bar_h = Screen:scaleBySize(64)
    table.insert(col, block(Bars:new{
        days = days,
        width = width - 2 * margin,
        height = bar_h,
    }, Size.padding.small))
    table.insert(col, block(bodyText(Stats.weekTotalLine(summary.week)), Size.padding.small))
    table.insert(col, block(quietText(Stats.weekAverageLine(summary.week)), Size.padding.small))
    table.insert(col, block(bodyText(Stats.streakLabel(summary.streak), true), Size.padding.large))
    return col
end

--- A letter centred in a fixed slot, so the marks line up under the days.
function CenterLetter(label, slot)
    local sz = label:getSize()
    local pad = math.max(0, math.floor((slot - (sz.w or 0)) / 2))
    return HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = pad },
        label,
    }
end

function ReadingLog:buildLibraryButton(width)
    local margin = Size.margin.default
    local label = TextWidget:new{
        text = _(Stats.LIBRARY_BUTTON),
        face = face("cfont", 18),
        bold = true,
    }
    local inner_h = math.max(Tiles.minTouch(), label:getSize().h + Size.padding.default * 2)
    local button_w = width - 2 * margin
    local hit = Hit:new{
        width = button_w,
        height = inner_h,
        callback = function() self:onOpenLibrary() end,
        FrameContainer:new{
            padding = Size.padding.default,
            bordersize = Size.border.button or 1,
            radius = Size.radius and Size.radius.button or 0,
            width = button_w,
            height = inner_h,
            CenterIn(label, button_w, inner_h),
        },
    }
    return FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_right = margin,
        padding_bottom = Size.padding.default,
        bordersize = 0,
        hit,
    }
end

function CenterIn(widget, w, h)
    local CenterContainer = require("ui/widget/container/centercontainer")
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        widget,
    }
end

function ReadingLog:build()
    local width = self.dimen.w
    local margin = Size.margin.default + Size.padding.default
    local summary = self:readStats()
    self.summary = summary
    local title = TextWidget:new{ text = _("Reading log"), face = face("cfont", 22), bold = true }
    local status = Core.statusLabel(clockText(), batteryText()) or clockText()
    self._clock = TextWidget:new{ text = status, face = face("cfont", 20), bold = true }
    local clock_w = self._clock:getSize().w
    local gap = math.max(Size.padding.default, width - 2 * margin - title:getSize().w - clock_w)
    local header = FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_right = margin,
        padding_top = Size.padding.default,
        padding_bottom = Size.padding.small,
        bordersize = 0,
        HorizontalGroup:new{
            align = "center",
            title,
            HorizontalSpan:new{ width = gap },
            self._clock,
        },
    }
    self.header = header
    local rule = LineWidget:new{
        background = Blitbuffer.COLOR_GRAY_B or Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = width, h = Size.line.thin or 1 },
    }
    local button = self:buildLibraryButton(width)
    local body = VerticalGroup:new{
        align = "left",
        header,
        rule,
        self:buildContinue(width),
        self:buildStats(width, summary),
    }
    local used = body:getSize().h + button:getSize().h
    local spacer = math.max(0, self.dimen.h - used)
    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = width,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            body,
            VerticalSpan:new{ width = spacer },
            button,
        },
    }
end

function ReadingLog:reload()
    if self._closed then return end
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
