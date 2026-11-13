--[[--
Full-screen Library view.

Layout, top to bottom:

    header           search bar, and beside it the clock and battery when those
                     are on. No "Library" title: that row is the books'.
    tabs             Books | Collections | Authors | Series
    status chips     All | Unread | Reading | Barely started | Finished
    continue reading (Books tab, no search or filter:
                     the books in progress, with percent and last-read time)
    cover grid or list   an A–Z strip on the right when sorted by title, author, author then year, or series
    footer           menu, page x of y, sort, current-book cover
                     (in a series: "2 of 5 read")

Inside a series the books are in series order and numbered ("3 · Title").
Paging past the last page (a left or right swipe, or a page key) opens
the next series, and before the first page the previous one, so a whole
shelf of series can be flipped through without going back to the list.
Up and down do not turn pages. A long-press on a page
arrow jumps to the first or last page of the list on screen (a tab, a
folder, search results, or the series that is open). A tap still moves
one page.

The search bar is a real InputText embedded in this widget, not a popup:
tapping it shows the Library keyboard and every keystroke re-filters the
in-memory index (debounced). Only the region below the header is refreshed,
so the keyboard and the text field are not redrawn. "Use KOReader's keyboard"
opens KOReader's InputDialog instead, and leaves this keyboard unused.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local time = require("ui/time")
local util = require("util")
local Core = require("librarycore")
local Gestures = require("librarygestures")
local ok_status, status_mod = pcall(require, "librarystatus")
local Status = (ok_status and type(status_mod) == "table" and status_mod.DEFAULT == "icon"
    and type(status_mod.markOps) == "function") and status_mod or nil
local Scrubber = require("libraryscrubber")
local Tiles = require("librarytile")
local Covers = require("librarycovers")
local Zones = require("libraryzones")
local Keyboard = require("librarykeyboard")
local Suggest = require("librarysuggest")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local TABS = {
    { id = "books", text = _("Books") },
    { id = "collections", text = _("Collections") },
    { id = "authors", text = _("Authors") },
    { id = "series", text = _("Series") },
}

local FILTER_NAMES = {
    all = _("All"),
    unread = _("Unread"),
    reading = _("Reading"),
    barely = _("Barely started"),
    finished = _("Finished"),
}

local LibraryView = InputContainer:extend{
    name = "library_view",
    covers_fullscreen = true,
    plugin = nil,      -- the Library plugin instance (data + actions)
    cols = 4,
    debounce_s = 0.15,
    sort = "recent",
    tab = "books",
    filter = "all",
    view_mode = "grid",     -- "grid" | "list" | "list2" | "compact" | "compact2" | "covers"
    show_continue = true,   -- the Continue reading strip on the Books tab
    filter_expands = true, -- a filter hides the widgets unless this is off (#11)
    widget_covers = "compact", -- "compact" (120px cap) | "fill" (#12)
    az_layout = "one",      -- "one" | "auto" | "split" (#14)
    letter_keeps_shelf = false, -- a letter tap collapses an expanded shelf unless this is on (#15)
    tab_row = "top",        -- "top" under the search bar, or "bottom" under the footer (#17)
    layout_button = "classic", -- "classic" four-step cycle | "layouts" grid/list/list2 (#13)
    top_row = "continue",   -- what that strip shows: "continue" | "recent" (Recently opened)
    continue_slots = 5,
    barely_threshold = 0.10, -- "Barely started" when chapters are unknown: below this fraction
    rounded_keyboard = true, -- "Rounded keyboard in search"
    fuzzy_search = true,     -- "Typo-tolerant search"
    show_clock = true,       -- clock beside the search bar
    show_battery = true,     -- battery beside the search bar
    status_style = nil,      -- "icon" | "compact" | "plain"; nil is the default (icon)
    status_bar_size = "small", -- "small" | "match" for the Status bar face (#16)
    use_koreader_keyboard = false, -- stock InputDialog instead of the Library keyboard
    search_suggestions = true, -- "Word suggestions": a row of words above the keyboard
    timing = nil,            -- the "Timing log" (librarytiming.lua), from the plugin
}

--- The search bar's text box: KOReader's InputText, with our own keyboard
-- (see librarykeyboard.lua) when "Rounded keyboard in search" is on. Only
-- this text box gets it; every other one in KOReader keeps the stock keyboard.
local SearchInput = InputText:extend{
    rounded_keyboard = true,
    hide_number_row = false,
    use_koreader_keyboard = false,
}
LibraryView.SearchInput = SearchInput

function SearchInput:initKeyboard()
    -- KOReader's own dialog brings the stock keyboard. This field only displays the query.
    if self.use_koreader_keyboard then
        self.key_events = {}
        self.keyboard = nil
        return
    end
    if self.rounded_keyboard and (Device:isTouchDevice() or Device:hasDPad()) then
        local RoundedKeyboard = Keyboard.class()
        if RoundedKeyboard then
            self.key_events = {}
            self.keyboard = RoundedKeyboard:new{
                keyboard_layer = self.input_type == "number" and 4 or 2,
                hide_number_row = self.hide_number_row,
                inputbox = self,
            }
            return
        end
    end
    return InputText.initKeyboard(self)
end

function SearchInput:onSwipeTextBox(arg, ges)
    -- InputText flashes the whole screen on a diagonal swipe. A downward
    -- swipe that started in the Controls zone should open the panel instead.
    local parent = self.parent
    if parent and parent.tryOpenControls and parent:tryOpenControls(ges) then
        return true
    end
    return InputText.onSwipeTextBox(self, arg, ges)
end

function SearchInput:onTapTextBox(arg, ges)
    local parent = self.parent
    if parent and parent.tryOpenControlsFromTap and parent:tryOpenControlsFromTap(ges) then
        return true
    end
    return InputText.onTapTextBox(self, arg, ges)
end

-- Typing: only the text box changes. KOReader's InputText marks its parent
-- (this whole Library) dirty for each key, which repaints every tile and then
-- the keyboard above them. When the screen is just as we left it (the
-- keyboard on top, the Library right under it, nothing else waiting to be
-- painted), the new text is painted on its own instead, and only the text
-- box is refreshed. Anything else takes KOReader's usual path.
local ECHO_PARENT = { name = "library_search_echo" } -- not on screen: setDirty only queues the refresh

function SearchInput:paintTo(bb, x, y)
    InputText.paintTo(self, bb, x, y)
    if bb == Screen.bb then self._painted_at = { x = x, y = y } end
end

function SearchInput:initTextBox(...)
    local parent = self.parent
    if not Keyboard.canEchoDirect(UIManager._window_stack, UIManager._dirty, self.keyboard, parent, self._painted_at) then
        return InputText.initTextBox(self, ...)
    end
    self.parent = ECHO_PARENT
    local ok, err = pcall(InputText.initTextBox, self, ...)
    self.parent = parent
    -- later cursor moves inside the box repaint through the Library as usual
    local tw = self.text_widget
    if tw then
        tw.dialog = parent
        if tw.text_widget then tw.text_widget.dialog = parent end
    end
    if not ok then error(err, 0) end
    self.echo_direct_count = (self.echo_direct_count or 0) + 1
    UIManager:widgetRepaint(self, self._painted_at.x, self._painted_at.y)
end

local lfs = require("libs/libkoreader-lfs")
local function fileExists(p) return lfs.attributes(p, "mode") == "file" end

local function lower(s) return util.stringLower and util.stringLower(s) or s:lower() end
LibraryView.lower = lower

function LibraryView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.width = self.dimen.w
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        -- where a finger went down, so a short flick that KOReader reports as a tap still turns the page
        Touch = { GestureRange:new{ ges = "touch", range = self.dimen } },
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        -- A drag that starts on the A–Z strip and slides off it, and the lift.
        Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        HoldPan = { GestureRange:new{ ges = "hold_pan", range = self.dimen } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    self.view_mode = Core.viewMode(self.view_mode)
    -- grid pages, list thumbnails and the Continue reading covers
    self.cover_cache = Tiles.newCoverCache(self.cols * 6 * 3 + 40)
    -- Where covers come from: our own thumbnails, and the cover browser's
    -- database when Project: Title or Cover browser is loaded.
    self.covers = { store = Covers.getStore(), bim = self.plugin:getBIM() }
    self.covers.store:scan()
    self.query = ""
    self.page = 1
    self.group = nil         -- { kind=, name=, books= } when inside a collection/author/series
    self.timings = {}
    self.label_h = Tiles.labelHeight()
    self.cover_label_h = Tiles.coverLabelHeight()
    self.list_row_h = Tiles.listRowHeight()
    self.continue_label_h = Tiles.labelHeight()
    self.gap = Size.padding.default

    self:buildChrome()
    self:reloadData()
    self:buildBody()
end

--- Painted: the "Timing log" stops whatever was waiting for this.
function LibraryView:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    local t = self.timing
    if t and t.enabled and bb == Screen.bb then
        t:painted(function(name) return self:timingNote(name) end)
    end
end

function LibraryView:timingNote(name)
    local items = self.current and self.current.items and #self.current.items or 0
    local books = self.all_books and #self.all_books or 0
    if name == "page" then return string.format("page=%d/%d books=%d", self.page or 1, self.pages or 1, books) end
    if name == "search" then return string.format("results=%d books=%d", items, books) end
    return string.format("items=%d books=%d", items, books)
end

function LibraryView:timeStart(name, armed)
    if self.timing then self.timing:start(name, armed) end
end

--- A tappable area around a widget. `min_w` / `min_h` grow the hit target
-- without growing the widget inside it. `align = "center"` keeps that
-- widget in the middle of the larger target.
local TapArea = InputContainer:extend{ callback = nil, min_h = 0, min_w = 0, align = "left" }

function TapArea:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = math.max(size.w, self.min_w or 0),
        h = math.max(size.h, self.min_h or 0),
    }
    local range = function() return Core.gestureRect(self.dimen) end
    self.ges_events = { TapArea = { GestureRange:new{ ges = "tap", range = range } } }
    if self.hold_callback then
        self.ges_events.HoldArea = { GestureRange:new{ ges = "hold", range = range } }
    end
    local box = Geom:new{ w = self.dimen.w, h = self.dimen.h }
    if self.align == "center" then
        self[1] = CenterContainer:new{ dimen = box, self[1] }
    else
        self[1] = LeftContainer:new{ dimen = box, self[1] }
    end
end

function TapArea:getSize() return self.dimen end

function TapArea:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

function TapArea:onTapArea()
    if self.callback then self.callback() end
    return true
end

function TapArea:onHoldArea()
    if self.hold_callback then self.hold_callback() end
    return true
end

--- A widget title. Long-press opens the widget menu (#1). Tap is left
-- for the accordion (#2); with no tap handler the press is not eaten.
local WidgetTitle = InputContainer:extend{}

function WidgetTitle:init()
    local label = self[1]
    local sz = label and label.getSize and label:getSize() or { w = 40, h = 20 }
    self.dimen = Geom:new{ x = 0, y = 0, w = math.max(sz.w, self.min_w or 0), h = math.max(sz.h, self.min_h or 24) }
    local range = function() return Core.gestureRect(self.dimen) end
    self.ges_events = {
        TapWidgetTitle = { GestureRange:new{ ges = "tap", range = range } },
        HoldWidgetTitle = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function WidgetTitle:getSize() return self.dimen end

function WidgetTitle:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

function WidgetTitle:onTapWidgetTitle()
    if self.on_tap then self.on_tap(); return true end
    return false
end

function WidgetTitle:onHoldWidgetTitle()
    if self.on_hold then self.on_hold() end
    return true
end

----------------------------------------------------------------------------
-- Header: search bar, with the clock and battery beside it
----------------------------------------------------------------------------

function LibraryView:buildChrome()
    self:buildSearchRow()
    self:scheduleStatusRefresh()
end

--- Long-press on the current-book cover: which book it opens.
function LibraryView:showResumeHint()
    local book = self.last_book
    if not book then return end
    local pct = Core.percentText(book.percent)
    local note = InfoMessage:new{
        text = T(_("Resume: %1"), book.title or book.name) .. (pct and ("  ·  " .. pct) or ""),
        timeout = 2,
    }
    if self.plugin and self.plugin.showOverLibrary then
        self.plugin:showOverLibrary(note, self)
    else
        UIManager:show(note)
    end
end

--- The search bar: a rounded field with a magnifier, the text box and a
-- clear button. It fills the header except for the clock and battery.
function LibraryView:buildSearchRow(text)
    local margin = Size.margin.default + Size.padding.default
    local icon_size = Screen:scaleBySize(22)
    local hpad = Size.padding.large
    local border = Size.border.button
    local face = Font:getFace("smallinfofont")
    self._status_face = Font:getFace("cfont", 20)
    self._header_margin = margin
    local gap = Size.padding.large
    local status_w = self:measureStatusSlot()
    self._status_slot_w = status_w
    local field_w = self.width - 2 * margin - status_w - (status_w > 0 and gap or 0)
    if field_w < Screen:scaleBySize(140) then field_w = Screen:scaleBySize(140) end
    -- What this row will show: what was passed, what the old box held, or
    -- nothing yet. The clear button is always in the row (issue #6). Showing
    -- and hiding it does not rebuild this text box: that would drop the
    -- keyboard. Its slot stays reserved so the field does not jump.
    if self.search_input then
        text = text or self.search_input:getText()
        self.search_input:onCloseWidget() -- frees its keyboard
    end
    text = text or ""
    local magnifier = IconButton:new{
        icon = "appbar.search",
        width = icon_size,
        height = icon_size,
        padding = 0,
        callback = function() self:openKeyboard() end,
        show_parent = self,
    }
    local clear = IconButton:new{
        icon = "close",
        width = icon_size,
        height = icon_size,
        padding = Size.padding.small,
        callback = function() self:clearSearch() end,
        show_parent = self,
    }
    -- Spans in the row: one after the magnifier, and one before the clear button.
    local gaps = 2
    local input_w = field_w - 2 * border - 2 * hpad - magnifier:getSize().w
        - clear:getSize().w - gaps * Size.padding.default
    self._search_hint = self:searchHint()
    self.search_input = SearchInput:new{
        text = text,
        hint = self._search_hint,
        width = input_w,
        face = face,
        focused = false,
        scroll = false,
        parent = self,
        bordersize = 0,
        margin = 0,
        padding = Size.padding.small,
        rounded_keyboard = self.rounded_keyboard and not self.use_koreader_keyboard,
        use_koreader_keyboard = self.use_koreader_keyboard,
        edit_callback = function(edited)
            if edited then self:onSearchEdited() end
        end,
        enter_callback = function() self:closeKeyboard() end,
    }
    local inner_h = math.max(self.search_input:getSize().h, Tiles.minTouch() - 2 * border)
    local row = {
        align = "center",
        magnifier,
        HorizontalSpan:new{ width = Size.padding.default },
        self.search_input,
        HorizontalSpan:new{ width = Size.padding.default },
        clear,
    }
    self.search_field = FrameContainer:new{
        padding = 0,
        padding_left = hpad,
        padding_right = Size.padding.small,
        bordersize = border,
        color = Blitbuffer.COLOR_GRAY_7,
        radius = math.floor((inner_h + 2 * border) / 2),
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = field_w - 2 * border - hpad - Size.padding.small, h = inner_h },
            HorizontalGroup:new(row),
        },
    }
    self._search_clear = clear
    self._search_clear_visible = text ~= ""
    self:setSearchClearShown(text ~= "")
    self:assembleHeader()
end

--- Paint the clear button only while there is a query. The text box and the
-- keyboard stay as they are.
function LibraryView:setSearchClearShown(on)
    local clear = self._search_clear
    if not clear then return end
    on = on and true or false
    if not clear._library_clear_saved then
        clear._library_clear_saved = true
        clear._library_paint = clear.paintTo
        clear._library_callback = clear.callback
    end
    self._search_clear_visible = on
    if on then
        clear.paintTo = clear._library_paint
        clear.callback = clear._library_callback
    else
        clear.paintTo = function() end
        clear.callback = function() end
    end
end

--- The drawn battery. The clock is a TextWidget beside it.
local StatusMark = Widget:extend{
    kind = "icon",
    percent = 0,
    charging = false,
    unit = 1,
}

function StatusMark:init()
    local w, h = 0, 0
    if Status then w, h = Status.markSize(self.kind, self.unit) end
    self.dimen = Geom:new{ w = w, h = h }
end

function StatusMark:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function StatusMark:setState(power)
    self.percent = power and power.percent or 0
    self.charging = power and power.charging or false
    self.charged = power and power.charged or false
end

function StatusMark:paintTo(bb, x, y)
    -- The screen buffer is FFI cdata, not a table. Only skip a test double.
    if not Status or bb == nil or type(bb.paintRect) ~= "function" then return end
    local ops = Status.markOps(self.kind, self.percent, self.charging, self.unit)
    for i = 1, #ops do
        local op = ops[i]
        local c = op.color == "white" and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        bb:paintRect(x + op.x, y + op.y, op.w, op.h, c)
    end
end

function LibraryView:statusStyle()
    if not Status then return "plain" end
    return Status.style(self.status_style)
end

function LibraryView:statusUnit()
    if not (Screen and Screen.scaleBySize) then return 1 end
    local ok, n = pcall(Screen.scaleBySize, Screen, 1)
    if ok and type(n) == "number" and n >= 1 then return n end
    return 1
end

function LibraryView:statusFace(style)
    style = style or self:statusStyle()
    if not Status then
        return Font:getFace("cfont", 20), true
    end
    local spec = Status.face(style, self.status_bar_size)
    return Font:getFace(spec.font, spec.size), spec.bold and true or false
end

function LibraryView:measureStatusText(text, face, bold)
    local t = TextWidget:new{ text = text, face = face, bold = bold and true or false }
    local sz = t:getSize()
    local w = sz and sz.w or 0
    if t.free then t:free() end
    return w
end

--- Width reserved for the clock and battery, from a wide sample so "9:59"
-- becoming "10:00" does not move the search bar.
function LibraryView:measureStatusSlot()
    if not (self.show_clock or self.show_battery) then return 0 end
    local style = self:statusStyle()
    local twelve = self:twelveHour()
    self._status_twelve = twelve
    local face, bold = self:statusFace(style)
    self._status_face = face
    self._status_bold = bold
    -- Wide digits, so the field does not jump at 10:00. Battery width is reserved
    -- only when this device actually reports a percentage.
    local clock = self.show_clock and (twelve and "88:88 PM" or "88:88") or nil
    local power = self.show_battery and self:readPower() or nil
    if style == "plain" or not Status then
        local sample = Core.statusLabel(clock, power and "100%" or nil)
        if not sample then return 0 end
        return self:measureStatusText(sample, face, true)
    end
    local clock_w = clock and self:measureStatusText(clock, face, bold) or 0
    local batt_w = 0
    if power then
        if style == "compact" then
            for _, sample in ipairs(Status.compactSamples()) do
                local w = self:measureStatusText(sample, face, false)
                if w > batt_w then batt_w = w end
            end
        else
            batt_w = Status.markSize(style, self:statusUnit())
        end
    end
    if clock_w == 0 then return batt_w end
    if batt_w == 0 then return clock_w end
    return clock_w + Status.gap(self:statusUnit()) + batt_w
end

function LibraryView:twelveHour()
    local gs = rawget(_G, "G_reader_settings")
    if type(gs) ~= "table" or type(gs.isTrue) ~= "function" then return false end
    local ok, on = pcall(gs.isTrue, gs, "twelve_hour_clock")
    return ok and on and true or false
end

function LibraryView:readClock()
    if not self.show_clock then return nil end
    local twelve = self:twelveHour()
    local ok, datetime = pcall(require, "datetime")
    if ok and type(datetime) == "table" and type(datetime.secondsToHour) == "function" then
        local ok2, text = pcall(datetime.secondsToHour, os.time(), twelve)
        if ok2 and type(text) == "string" and text ~= "" then return text end
    end
    if twelve then return (os.date("%I:%M %p"):gsub("^0", "")) end
    return os.date("%H:%M")
end

--- Percent, charging and charged, or nil when this device has no reading.
function LibraryView:readPower()
    if not self.show_battery then return nil end
    if type(Device) ~= "table" or type(Device.hasBattery) ~= "function" then return nil end
    local ok, has = pcall(Device.hasBattery, Device)
    if not ok or not has or type(Device.getPowerDevice) ~= "function" then return nil end
    local okd, powerd = pcall(Device.getPowerDevice, Device)
    if not okd or type(powerd) ~= "table" or type(powerd.getCapacity) ~= "function" then return nil end
    local okc, cap = pcall(powerd.getCapacity, powerd)
    if not okc then return nil end
    local charging, charged = false, false
    if type(powerd.isCharging) == "function" then
        local okch, v = pcall(powerd.isCharging, powerd)
        if okch then charging = v and true or false end
    end
    if type(powerd.isCharged) == "function" then
        local okcd, v = pcall(powerd.isCharged, powerd)
        if okcd then charged = v and true or false end
    end
    if Status then return Status.state(cap, charging, charged) end
    local label = Core.batteryLabel(cap)
    local n = label and tonumber(label:match("^(%d+)")) or nil
    if not n then return nil end
    return { percent = n, charging = charging, charged = charged }
end

function LibraryView:readBattery()
    local power = self:readPower()
    if not power then return nil end
    return Core.batteryLabel(power.percent)
end

--- KOReader's own battery glyph when the device provides one, else the same map.
function LibraryView:batterySymbol(power)
    if not power then return "" end
    if type(Device) == "table" and type(Device.getPowerDevice) == "function" then
        local okd, powerd = pcall(Device.getPowerDevice, Device)
        if okd and type(powerd) == "table" and type(powerd.getBatterySymbol) == "function" then
            local ok, sym = pcall(powerd.getBatterySymbol, powerd,
                power.charged and true or false, power.charging and true or false, power.percent)
            if ok and type(sym) == "string" and sym ~= "" then return sym end
        end
    end
    if Status then return Status.koreaderSymbol(power.percent, power.charging, power.charged) end
    return ""
end

function LibraryView:freeStatusWidgets()
    self.status_label = nil
    self._status_clock = nil
    self._status_batt_label = nil
    self._status_mark = nil
    self.status_box = nil
end

function LibraryView:buildStatusWidget()
    self:freeStatusWidgets()
    if not (self.show_clock or self.show_battery) then
        self._status_text = nil
        self._status_fp = nil
        return nil
    end
    local style = self:statusStyle()
    local face, bold = self:statusFace(style)
    self._status_face = face
    self._status_bold = bold
    local power = self:readPower()
    self._status_has_battery = power ~= nil
    local clock = self:readClock()
    local slot_w = self._status_slot_w
    local slot_h = self.search_field and self.search_field:getSize().h or 0
    local inner
    if style == "plain" or not Status then
        local text = Core.statusLabel(clock, power and Core.batteryLabel(power.percent) or nil) or ""
        self._status_text = text
        self._status_fp = text
        local label = TextWidget:new{ text = text, face = face, bold = true }
        self.status_label = label
        inner = label
        if not slot_w or slot_w <= 0 then slot_w = label:getSize().w end
        if slot_h <= 0 then slot_h = label:getSize().h end
    else
        local parts = { align = "center" }
        if clock then
            local label = TextWidget:new{ text = clock, face = face, bold = bold }
            self._status_clock = label
            self.status_label = label
            parts[#parts + 1] = label
        end
        if power then
            if clock then
                parts[#parts + 1] = HorizontalSpan:new{ width = Status.gap(self:statusUnit()) }
            end
            if style == "compact" then
                local text = self:batterySymbol(power) .. power.percent .. "%"
                local label = TextWidget:new{ text = text, face = face, bold = false }
                self._status_batt_label = label
                parts[#parts + 1] = label
            else
                local mark = StatusMark:new{
                    kind = style,
                    percent = power.percent,
                    charging = power.charging,
                    charged = power.charged,
                    unit = self:statusUnit(),
                }
                self._status_mark = mark
                parts[#parts + 1] = mark
            end
        end
        inner = HorizontalGroup:new(parts)
        local sz = inner:getSize()
        if not slot_w or slot_w <= 0 then slot_w = sz.w end
        if slot_h <= 0 then slot_h = sz.h end
        local gh = sz.h or 0
        if slot_h > gh then
            local pad = math.floor((slot_h - gh) / 2)
            inner = VerticalGroup:new{
                VerticalSpan:new{ width = pad },
                inner,
            }
        end
        self._status_fp = table.concat({
            style,
            clock or "",
            power and tostring(power.percent) or "",
            power and power.charging and "1" or "0",
            power and power.charged and "1" or "0",
        }, "|")
        self._status_text = self._status_fp
    end
    self.status_box = RightContainer:new{
        dimen = Geom:new{ w = slot_w, h = slot_h },
        inner,
    }
    -- Tap (not swipe) on the clock/battery opens Controls, so the panel
    -- does not depend on the swipe alone. The search field to the left
    -- keeps its own taps.
    return TapArea:new{
        callback = function() self:onStatusTap() end,
        self.status_box,
    }
end

--- Tap the header clock or battery: open Controls.
function LibraryView:onStatusTap()
    if not (self.plugin and self.plugin.openControls) then return false end
    if self.plugin:openControls() then
        self:keyboardGuard()
        return true
    end
    return false
end

--- Swap the clock and battery. Does not repaint.
function LibraryView:updateStatusText()
    local style = self:statusStyle()
    if style == "plain" or not Status then
        if not self.status_label or type(self.status_label.setText) ~= "function" then return false end
        local text = Core.statusLabel(self:readClock(), self:readBattery()) or ""
        if text == self._status_text then return false end
        self._status_text = text
        self.status_label:setText(text)
        return true
    end
    local clock = self:readClock()
    local power = self:readPower()
    local fp = table.concat({
        style,
        clock or "",
        power and tostring(power.percent) or "",
        power and power.charging and "1" or "0",
        power and power.charged and "1" or "0",
    }, "|")
    if fp == self._status_fp then return false end
    -- A battery that appears or disappears, or a clock that does, needs a new row.
    local had_clock = self._status_clock ~= nil
    local had_batt = (self._status_mark or self._status_batt_label) ~= nil
    if (clock ~= nil) ~= had_clock or (power ~= nil) ~= had_batt then return false end
    self._status_fp = fp
    self._status_text = fp
    if clock and self._status_clock and self._status_clock.setText then
        self._status_clock:setText(clock)
    end
    if self._status_mark and self._status_mark.setState then
        self._status_mark:setState(power)
    end
    if power and self._status_batt_label and self._status_batt_label.setText then
        self._status_batt_label:setText(self:batterySymbol(power) .. power.percent .. "%")
    end
    return true
end

function LibraryView:assembleHeader()
    local margin = self._header_margin or (Size.margin.default + Size.padding.default)
    local row = { align = "center", self.search_field }
    local status = self:buildStatusWidget()
    if status then
        row[#row + 1] = HorizontalSpan:new{ width = Size.padding.large }
        row[#row + 1] = status
    end
    self.header = FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_right = margin,
        padding_top = Size.padding.default,
        padding_bottom = Size.padding.small,
        bordersize = 0,
        HorizontalGroup:new(row),
    }
end

function LibraryView:headerRegion()
    local h = 0
    if self.header and self.header.getSize then h = self.header:getSize().h or 0 end
    return Geom:new{ x = 0, y = 0, w = self.dimen and self.dimen.w or self.width or 0, h = h }
end

--- One refresh at the next minute, and only while the clock or battery is shown.
-- Unscheduled when the Library closes or both are turned off.
function LibraryView:scheduleStatusRefresh()
    if self._status_tick then UIManager:unschedule(self._status_tick); self._status_tick = nil end
    if self._closed or not (self.show_clock or self.show_battery) then return end
    local delay = Core.nextMinuteDelay(os.time())
    self._status_tick = function()
        self._status_tick = nil
        if self._closed then return end
        self:onStatusTick()
        self:scheduleStatusRefresh()
    end
    UIManager:scheduleIn(delay, self._status_tick)
end

function LibraryView:statusTyping()
    return self.search_input and self.search_input.isKeyboardVisible
        and self.search_input:isKeyboardVisible() and true or false
end

function LibraryView:onStatusTick()
    -- A battery that appears or disappears, or a 12-hour switch, changes the
    -- search bar's width. Rebuild unless the keyboard is up.
    local has_battery = (self.show_battery and self:readPower() ~= nil) and true or false
    local twelve = self:twelveHour()
    if self.search_field and not self:statusTyping()
            and (has_battery ~= (self._status_has_battery and true or false)
                or twelve ~= self._status_twelve) then
        self:buildSearchRow()
        self:refreshBody(true)
        return
    end
    if not self:updateStatusText() then return end
    if not UIManager.setDirty then return end
    UIManager:setDirty(self, function()
        return "ui", self:headerRegion(), true
    end)
end

--- KOReader's Time and date menu broadcasts this when twelve_hour_clock flips.
function LibraryView:onTimeFormatChanged()
    if self._closed then return end
    if self:statusTyping() then
        self:updateStatusText()
        if UIManager.setDirty then
            UIManager:setDirty(self, function()
                return "ui", self:headerRegion(), true
            end)
        end
        return
    end
    if not self.search_field then return end
    self:buildSearchRow()
    self:refreshBody(true)
end

function LibraryView:setStatusBarSize(size_id)
    self.status_bar_size = size_id == "match" and "match" or "small"
    self:buildSearchRow()
    self:refreshBody(true)
end

function LibraryView:setStatusStyle(id)
    if not Status then return end
    id = Status.style(id)
    if id == Status.style(self.status_style) then return end
    self.status_style = id
    self:buildSearchRow()
    self:scheduleStatusRefresh()
    self:refreshBody(true)
end

function LibraryView:setShowClock(on)
    on = on and true or false
    if on == (self.show_clock and true or false) then return end
    self.show_clock = on
    self:buildSearchRow()
    self:scheduleStatusRefresh()
    self:refreshBody(true)
end

function LibraryView:setShowBattery(on)
    on = on and true or false
    if on == (self.show_battery and true or false) then return end
    self.show_battery = on
    self:buildSearchRow()
    self:scheduleStatusRefresh()
    self:refreshBody(true)
end

--- The field's border follows the keyboard: dark while typing.
function LibraryView:markSearchFocus(on)
    if self.search_field then
        self.search_field.color = on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_7
    end
end

--- Turn "Rounded keyboard in search" on or off: the search bar gets a new
-- text box (and keyboard); what was typed is kept.
function LibraryView:setRoundedKeyboard(on)
    on = on and true or false
    if on == self.rounded_keyboard then return end
    if self.search_input:isKeyboardVisible() then self:keyboardGuard() end
    self.rounded_keyboard = on
    self:buildSearchRow()
    self:refreshBody(true)
end

--- Turn "Typo-tolerant search" on or off and redo the current search.
function LibraryView:setFuzzySearch(on)
    on = on and true or false
    if on == self.fuzzy_search then return end
    self.fuzzy_search = on
    self.last_query, self.last_results = nil, nil
    if self.query ~= "" then self:refreshBody(true) end
end

----------------------------------------------------------------------------
-- Data
----------------------------------------------------------------------------

--- (Re)read books from the plugin's index and sort them.
function LibraryView:reloadData()
    self.all_books = self.plugin:getBooks()
    self.sorted = Core.sortBooks(self.all_books, self.sort, self.plugin.collate)
    self.last_query, self.last_results = nil, nil
    self.groups_cache = {}
    -- The book the Resume icon opens; show or hide the icon to match.
    -- The book the footer Resume button opens. The footer is rebuilt with the body.
    self.last_book = Core.resumeBook(self.all_books)
end

function LibraryView:groupsFor(tab)
    if tab == "collections" and self:showingGenres() then return self:groupsFor("genres") end
    if self.groups_cache[tab] then return self.groups_cache[tab] end
    local groups
    if tab == "genres" then
        -- the keywords (Calibre tags) already in the index: no book is opened
        groups = Core.genreGroups(self.sorted, self.plugin.collate, lower, _("Unsorted"))
    elseif tab == "collections" then
        groups = self.plugin:getCollections()
        -- Like the Kindle: a collection's books follow the chosen sort.
        for _, g in ipairs(groups) do
            g.books = Core.sortBooks(g.books, self.sort, self.plugin.collate)
        end
    else
        groups = {}
        for _, g in ipairs(Core.group(self.sorted, tab == "authors" and "author" or "series", self.plugin.collate)) do
            if g.key ~= Core.UNKNOWN then
                table.insert(groups, { kind = tab, name = g.key, books = g.books })
            end
        end
        if tab == "series" then
            for _, g in ipairs(groups) do
                g.books = Core.seriesOrder(g.books, self.plugin.collate)
            end
        end
    end
    for _, g in ipairs(groups) do g.cover_book = g.cover_book or g.books[1] end
    self.groups_cache[tab] = groups
    return groups
end

--- The Collections tab shows Genres instead (the switch under the tabs).
function LibraryView:showingGenres()
    local s = self.plugin.settings
    return s ~= nil and s.collections_view == "genres"
end

--- Flip the Collections tab between "collections" and "genres" (remembered).
function LibraryView:setCollectionsView(mode)
    local s = self.plugin.settings
    if not s then return end
    local want = mode == "genres" and "genres" or nil
    if s.collections_view == want then return end
    self:keyboardGuard()
    s.collections_view = want
    if self.plugin.saveSettings then self.plugin:saveSettings() end
    self.page = 1
    self:updateSearchHint()
    self:refreshBody(true, "tab")
end

--- The search bar's placeholder: what it searches here.
function LibraryView:searchHint()
    if self.group then return T(_("Search in %1\u{2026}"), self.group.name) end
    local scope = Core.searchScope(self.tab, self.group)
    if scope == "authors" then return _("Search authors\u{2026}") end
    if scope == "series" then return _("Search series or authors\u{2026}") end
    if scope == "collections" and self:showingGenres() then return _("Search genres\u{2026}") end
    if scope == "collections" then return _("Search collections\u{2026}") end
    return _("Search title, author, series")
end

--- Rebuild the search bar when its placeholder should change (new tab or shelf).
function LibraryView:updateSearchHint()
    if self._search_hint and self._search_hint ~= self:searchHint() then
        self:buildSearchRow(self.query)
    end
end

--- Empty the search without searching again (the caller rebuilds the body).
function LibraryView:resetQuery()
    if self._search_action then UIManager:unschedule(self._search_action); self._search_action = nil end
    if self.query ~= "" then
        self.search_input:setText("")
        self.query = ""
    end
end

--- Books matching the query (narrowing previous results while typing).
function LibraryView:searchBooks(base)
    if self.query == "" then return base end
    local previous
    if self.last_base == base and Core.isRefinement(self.last_query, self.query) then
        previous = self.last_results
    end
    local results = Core.searchIndexed(base, self.query, lower, previous, self.fuzzy_search)
    self.last_base, self.last_query, self.last_results = base, self.query, results
    return results
end

--- What the grid should show now: { kind = "books"|"groups", items = {...}, counts = }.
function LibraryView:currentItems()
    local th = self.barely_threshold
    if self.group then
        local books = self:searchBooks(self.group.books)
        return { kind = "books", items = Core.filterStatus(books, self.filter, th), counts = Core.countFilters(books, th) }
    end
    if Core.searchScope(self.tab) == "books" then
        local books = self:searchBooks(self.sorted)
        return { kind = "books", items = Core.filterStatus(books, self.filter, th), counts = Core.countFilters(books, th) }
    end
    -- Authors, Series, Collections: the search narrows the tab's shelves.
    local groups = self:groupsFor(self.tab)
    if self.query ~= "" then groups = Core.searchGroups(groups, self.query, lower, self.fuzzy_search) end
    return { kind = "groups", items = groups }
end

----------------------------------------------------------------------------
-- Body: tabs, chips, grid, footer
----------------------------------------------------------------------------

function LibraryView:keyboardHeight()
    local input = self.search_input
    if not (input and input.keyboard) then return 0 end
    local kb = input.keyboard
    local shown = input.isKeyboardVisible and input:isKeyboardVisible()
    if not shown and UIManager._window_stack then
        for _, entry in ipairs(UIManager._window_stack) do
            if entry.widget == kb then shown = true; break end
        end
    end
    if not shown then return 0 end
    local h = kb.dimen and kb.dimen.h
    if not h and kb.getSize then h = kb:getSize().h end
    return h or 0
end

function LibraryView:buildTabs()
    local margin = Size.margin.default + Size.padding.default
    local row = HorizontalGroup:new{ align = "bottom" }
    local w = math.floor((self.width - 2 * margin) / #TABS)
    for _, tab in ipairs(TABS) do
        table.insert(row, Tiles.Tab:new{
            text = tab.text,
            width = w,
            selected = self.group == nil and self.tab == tab.id,
            callback = function() self:setTab(tab.id) end,
            show_parent = self,
        })
    end
    -- the tabs sit on a hairline, the selected one marked by a thick underline
    return VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = self.width, h = row:getSize().h }, row },
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY_B,
            dimen = Geom:new{ w = self.width - 2 * margin, h = Size.line.thin },
        },
    }
end

local GROUP_COUNT = { authors = _("%1 authors"), series = _("%1 series"), collections = _("%1 collections"),
    genres = _("%1 genres") }

--- Collections tab: the Collections | Genres switch.
function LibraryView:buildCollectionsSwitch()
    local margin = Size.margin.default + Size.padding.default
    local genres = self:showingGenres()
    local row = HorizontalGroup:new{
        align = "center",
        Tiles.Chip:new{ text = _("Collections"), selected = not genres,
            callback = function() self:setCollectionsView("collections") end, show_parent = self },
        HorizontalSpan:new{ width = Size.padding.default },
        Tiles.Chip:new{ text = _("Genres"), selected = genres,
            callback = function() self:setCollectionsView("genres") end, show_parent = self },
    }
    local pad = Size.padding.default
    return FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_top = pad,
        bordersize = 0,
        width = self.width,
        height = row:getSize().h + 2 * pad,
        row,
    }
end

--- Horizontal filter row (#5). Chips keep their full labels. When they
-- are wider than the screen the last one is cropped and a chevron marks
-- that more sits past the edge. A sideways drag or swipe scrolls the row.
local FilterStrip = InputContainer:extend{ name = "library_filter_strip" }

function FilterStrip:init()
    local row = self[1]
    local h = (row and row.getSize and row:getSize().h or 0) + 2 * (self.pad or 0)
    self.content_w = row and row.getSize and row:getSize().w or 0
    self.dimen = Geom:new{ w = self.view_w or 0, h = h }
    local scroll = Core.filterScroll(self.offset, self.content_w, self.dimen.w, 0)
    self.offset = scroll.offset
    self._scroll = scroll
    local range = function() return Core.gestureRect(self.dimen) end
    self.ges_events = {
        PanFilter = { GestureRange:new{ ges = "pan", range = range } },
        SwipeFilter = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

function FilterStrip:getSize()
    return self.dimen
end

function FilterStrip:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local row = self[1]
    -- The framebuffer crops whatever passes the screen edge. That cropped
    -- chip is the cue that more filters sit past the edge (#5).
    if row then row:paintTo(bb, x - (self.offset or 0), y) end
end

function FilterStrip:applyScroll(dx)
    local st = Core.filterScroll(self.offset, self.content_w, self.dimen.w, dx)
    self.offset = st.offset
    self._scroll = st
    if self.on_offset then self.on_offset(st.offset) end
    if UIManager.setDirty then
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
    return st.overflow
end

function FilterStrip:onPanFilter(_, ges)
    if not (self._scroll and self._scroll.overflow) then return false end
    local dx = ges and ges.relative and tonumber(ges.relative.x) or 0
    self:applyScroll(dx)
    return true
end

function FilterStrip:onSwipeFilter(_, ges)
    if not (self._scroll and self._scroll.overflow) then return false end
    local dir = ges and ges.direction
    if dir ~= "west" and dir ~= "east" then return false end
    local step = math.floor((self.dimen.w or 0) * 0.6)
    -- A west swipe moves the row left, revealing what was past the right edge.
    self:applyScroll(dir == "west" and -step or step)
    return true
end

function LibraryView:buildChips(counts)
    local margin = Size.margin.default + Size.padding.default
    local gap = Size.padding.default
    local avail = self.width - 2 * margin
    -- Full labels, even when that is wider than the screen (#5). The strip
    -- scrolls; it does not drop counts or shorten names to squeeze in.
    local row = HorizontalGroup:new{ align = "center" }
    if self.group then
        table.insert(row, Tiles.Chip:new{
            text = "\u{2190} " .. self.group.name,
            max_text_w = math.floor(self.width * 0.22),
            callback = function() self:closeGroup() end,
            show_parent = self,
        })
        table.insert(row, HorizontalSpan:new{ width = Size.padding.large })
    end
    for i, f in ipairs(Core.FILTERS) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local text = FILTER_NAMES[f] or f
        if counts then text = text .. " " .. (counts[f] or 0) end
        table.insert(row, Tiles.Chip:new{
            text = text,
            selected = self.filter == f,
            callback = function() self:setFilter(f) end,
            show_parent = self,
        })
    end
    local pad = Size.padding.default
    local strip = FilterStrip:new{
        view_w = avail,
        pad = 0,
        offset = self._filter_offset or 0,
        on_offset = function(off) self._filter_offset = off end,
        row,
    }
    return FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_top = pad,
        bordersize = 0,
        width = self.width,
        height = strip:getSize().h + 2 * pad,
        strip,
    }
end

--- The current book's cover in the middle of the footer (issue #4).
-- Tap it to return to the reader. A long-press shows the title and progress,
-- which used to live on the Resume button. No cover yet: the book's initial
-- in a bordered box. Returns the button and its width.
function LibraryView:buildCurrentBookButton(height)
    local book = self.last_book
    if not book then return nil, height end
    local cover, _w, _h, needs = Tiles.bookCover(self, book,
        math.floor(height * 2 / 3 + 0.5), height,
        Core.scrubberBucket(book.title or book.name or ""), nil)
    if needs and self.missing_covers then
        local seen = false
        for _, b in ipairs(self.missing_covers) do
            if b == book then seen = true break end
        end
        if not seen then table.insert(self.missing_covers, book) end
    end
    local btn = TapArea:new{
        min_w = Tiles.minTouch(), min_h = Tiles.minTouch(), align = "center",
        callback = function() self:onResume() end,
        hold_callback = function() self:showResumeHint() end,
        cover,
    }
    return btn, btn:getSize().w
end

function LibraryView:buildFooter(page, pages, total, kind)
    local margin = Size.margin.default + Size.padding.default
    local f = Font:getFace("cfont", 15)
    local left = kind == "books" and T(_("%1 books · %2"), total, self.plugin:sortName(self.sort))
        or T(GROUP_COUNT[(self.tab == "collections" and self:showingGenres()) and "genres" or self.tab]
            or _("%1 groups"), total)
    if self:inSeries() then
        local pr = Core.seriesProgress(self.group.books)
        left = T(_("%1 of %2 read"), pr.read, pr.total)
        local pos, count = self:seriesPosition()
        if pos then left = left .. " · " .. T(_("series %1 of %2 · swipe on for the next"), pos, count) end
    end
    -- Page arrows are real buttons, as well as left and right swipes. A tap
    -- moves one page. Up and down do not.
    -- A long-press jumps to the first or last page.
    -- The chevron stays the same size as before. The hit target grows sideways
    -- to about 10 mm (at least 120 px at 300 dpi) so it is easy to hit on a
    -- Kindle, without a taller or filled-in footer.
    local touch = Tiles.minTouch()
    local hit_w = math.max(touch, self:pageHit())
    local icon = Screen:scaleBySize(20)
    local pad_v = math.max(0, math.floor((touch - icon) / 2))
    local pad_h = math.max(pad_v, math.ceil((hit_w - icon) / 2))
    local function arrow(name, dir, enabled)
        local btn = IconButton:new{
            icon = name,
            width = icon, height = icon,
            padding = pad_v,
            padding_left = pad_h,
            padding_right = pad_h,
            padding_top = pad_v,
            padding_bottom = pad_v,
            enabled = enabled,
            allow_flash = false, -- the page redraw is the feedback: one refresh, not two
            callback = function() self:turnPage(dir, false) end,
            hold_callback = function() self:jumpToEnd(dir) end,
            show_parent = self,
        }
        if not enabled and btn.image then btn.image.dim = true end
        return btn
    end
    local more = self:inSeries() -- past the last page: the next series
    -- "3 / 12": its own tap target between the arrows, and only a tap. The
    -- number is drawn at the same size as before and centered in a wider
    -- invisible target (about 10 mm). A tap opens the number box. A long-press
    -- on an arrow still jumps to the first or last page. One page: nothing to type.
    local page_label = TextWidget:new{ text = T(_("%1 / %2"), page, pages), face = f, bold = true }
    self.page_label = nil
    if pages > 1 then
        page_label = TapArea:new{
            min_w = hit_w, min_h = touch, align = "center",
            callback = function() self:showPageJump() end,
            page_label,
        }
        self.page_label = page_label
    end
    local pager = HorizontalGroup:new{
        align = "center",
        arrow("chevron.left", -1, page > 1 or more),
        page_label,
        arrow("chevron.right", 1, page < pages or more),
    }
    -- The menu lives here, not in a top corner: those are hard to hit on e-ink.
    -- Same thumb-sized target as the page arrows.
    local chrome_icon = Screen:scaleBySize(22)
    local chrome_pad = math.max(0, math.floor((touch - chrome_icon) / 2))
    local function chromeButton(item)
        local enabled = item.enabled ~= false
        local callback, hold
        -- A tap opens the menu (#1). A hold does not: the button sits
        -- in the bottom-left corner, and a hold there is that corner's
        -- gesture. Swipes are not claimed by the button at all.
        callback = function() self:onLeftIcon() end
        hold = nil
        local btn = IconButton:new{
            icon = item.icon,
            width = chrome_icon, height = chrome_icon,
            padding = chrome_pad,
            enabled = enabled,
            allow_flash = false,
            callback = callback,
            hold_callback = hold,
            show_parent = self,
        }
        if not enabled and btn.image then btn.image.dim = true end
        return btn
    end
    -- Size and view beside the page navigation (issue #5): same thumb-sized
    -- target as the other chrome buttons, always enabled.
    local function navButton(icon, callback, hold)
        return IconButton:new{
            icon = icon,
            width = chrome_icon, height = chrome_icon,
            padding = chrome_pad,
            enabled = true,
            allow_flash = false,
            callback = callback,
            hold_callback = hold,
            show_parent = self,
        }
    end
    local menu_btn
    for _, item in ipairs(Core.footerChrome(self.last_book ~= nil)) do
        local btn = chromeButton(item)
        if item.id == "menu" then menu_btn = btn end
    end
    self.footer_menu, self.footer_resume = menu_btn, nil
    -- Button:onHoldSelectButton returns true even with no hold callback,
    -- which would swallow a hold in the bottom-left corner.
    if menu_btn.ges_events then
        menu_btn.ges_events.HoldSelectButton = nil
        menu_btn.ges_events.HoldReleaseSelectButton = nil
    end
    local button_gap = Size.padding.small
    local buttons_w = menu_btn:getSize().w + Size.padding.default
    -- Size steps the cover size, view steps the form factor; a long-press
    -- on either opens the sort and view picker.
    local size_btn = navButton("zoom.page",
        function() self:cycleCoverSize() end,
        function() self:showSortPicker() end)
    local view_btn = navButton(Core.viewFormIcon(self.view_mode),
        function() self:cycleViewMode() end,
        function() self:showSortPicker() end)
    self.footer_size, self.footer_view = size_btn, view_btn
    local nav_w = size_btn:getSize().w + button_gap + view_btn:getSize().w + button_gap + pager:getSize().w
    -- The current book's cover, centred between the text and the pager.
    -- A touch-sized target; the visible miniature keeps its 2:3 shape.
    -- The slot stays the same width with or without a book, so the footer
    -- does not jump. Empty, it is just space in the middle.
    local slot_h = Tiles.minTouch()
    local current_btn, current_w = self:buildCurrentBookButton(slot_h)
    if not current_btn then current_w = slot_h end
    self.footer_current = current_btn
    -- "202 books · Last read ▾": tap it to pick the sort (books only; a
    -- series keeps its reading order).
    local sortable = kind == "books" and not self:inSeries()
    if sortable then left = left .. " \u{25BE}" end
    local max_text = math.max(Screen:scaleBySize(72),
        self.width - 2 * margin - buttons_w - nav_w - current_w - Size.padding.default)
    local text = TextWidget:new{ text = left, face = f, fgcolor = Blitbuffer.COLOR_GRAY_4, max_width = max_text }
    self.sort_label = nil
    if sortable then
        text = TapArea:new{ min_h = touch, callback = function() self:showSortPicker() end, text }
        self.sort_label = text
    end
    local h = math.max(text:getSize().h, pager:getSize().h, menu_btn:getSize().h)
    local rest = self.width - 2 * margin - buttons_w - text:getSize().w - nav_w - current_w
    local row = {
        align = "center",
        menu_btn,
        HorizontalSpan:new{ width = Size.padding.default },
        text,
    }
    -- Split the free space around the cover slot so it sits in the middle.
    local half = math.max(Size.padding.small, math.floor(rest / 2))
    local slot = current_btn or HorizontalSpan:new{ width = current_w }
    table.insert(row, HorizontalSpan:new{ width = half })
    table.insert(row, slot)
    table.insert(row, HorizontalSpan:new{ width = half })
    table.insert(row, size_btn)
    table.insert(row, HorizontalSpan:new{ width = button_gap })
    table.insert(row, view_btn)
    table.insert(row, HorizontalSpan:new{ width = button_gap })
    table.insert(row, pager)
    return FrameContainer:new{
        padding = 0,
        padding_left = margin,
        bordersize = 0,
        width = self.width,
        height = h,
        HorizontalGroup:new(row),
    }
end

function LibraryView:buildGrid(items, kind, layout, height, width)
    width = width or self.width
    local grid = VerticalGroup:new{ align = "left" }
    self.tiles = {}
    self.missing_covers = {}
    -- Spread spare height between rows (same spacing on every page).
    -- (capped: a lone row under Continue reading should not float mid-page)
    local now = os.time()
    local vgap = math.max(self.gap, math.min(3 * Size.padding.large,
        math.floor((height - layout.rows * layout.tile_h) / (layout.rows + 1))))
    local i = 1
    for _ = 1, layout.rows do
        if i > #items then break end
        local row = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = self.gap } }
        for _ = 1, layout.cols do
            local item = items[i]
            if not item then break end
            local tile = Tiles.Tile:new{
                width = layout.tile_w,
                height = layout.tile_h,
                cover_h = layout.cover_h,
                cover_only = kind == "books" and Core.isCoverOnly(self.view_mode),
                book = kind == "books" and item or nil,
                group = kind == "groups" and item or nil,
                series_number = kind == "books" and self:inSeries(),
                date_text = kind == "books" and not self:inSeries() and Core.sortDate(item, self.sort, now) or nil,
                covers = self.covers,
                cover_cache = self.cover_cache,
                on_tap = function(t, ges) self:onTileTap(t, ges) end,
                on_hold = function(t) self:onTileHold(t) end,
            }
            if tile.needs_cover then
                local b = tile.book or (tile.group and tile.group.cover_book)
                if b then table.insert(self.missing_covers, b) end
            end
            table.insert(self.tiles, tile)
            table.insert(row, tile)
            table.insert(row, HorizontalSpan:new{ width = self.gap })
            i = i + 1
        end
        table.insert(grid, VerticalSpan:new{ width = vgap })
        table.insert(grid, row)
    end
    if #items == 0 then
        local msg = self.query ~= "" and T(_("No books match “%1”."), self.query) or _("Nothing here yet.")
        grid = CenterContainer:new{
            dimen = Geom:new{ w = width, h = math.floor(height / 2) },
            TextWidget:new{ text = msg, face = Font:getFace("infofont") },
        }
    end
    -- Fixed height, so the footer stays at the bottom however many rows there are.
    return TopContainer:new{
        dimen = Geom:new{ w = width, h = height },
        grid,
    }
end

function LibraryView:buildList(items, kind, layout, height, width)
    width = width or self.width
    self.tiles = {}
    self.missing_covers = {}
    local compact = Core.isCompact(self.view_mode)
    local Row = compact and Tiles.CompactRow or Tiles.ListRow
    local text_only = Core.textRows(self.view_mode, kind, self.tab) and not self.group
    -- Compact · 2 columns: down the left column, then the right, with a rule between.
    local ncols = Core.listColumns(self.view_mode)
    local rule = Size.line.thin
    local col_w = ncols == 1 and width or math.floor((width - rule) / ncols)
    local columns = Core.columnMajor(items, layout.rows, ncols)
    local now = os.time()
    local groups = {}
    for c = 1, ncols do groups[c] = VerticalGroup:new{ align = "left" } end
    for c = 1, ncols do
        local list = groups[c]
        for _i, item in ipairs(columns[c]) do
            local row = Row:new{
                width = col_w,
                height = layout.row_h,
                thumb_w = layout.thumb_w,
                thumb_h = layout.thumb_h,
                book = kind == "books" and item or nil,
                group = kind == "groups" and item or nil,
                series_number = kind == "books" and self:inSeries(),
                author_first = kind == "books" and (self.sort == "author" or self.sort == "author_year"),
                text_only = text_only,
                date_text = kind == "books" and not self:inSeries() and Core.sortDate(item, self.sort, now) or nil,
                covers = self.covers,
                cover_cache = self.cover_cache,
                on_tap = function(t, ges) self:onTileTap(t, ges) end,
                on_hold = function(t) self:onTileHold(t) end,
            }
            if row.needs_cover then
                local b = row.book or (row.group and row.group.cover_book)
                if b then table.insert(self.missing_covers, b) end
            end
            table.insert(self.tiles, row)
            table.insert(list, row)
        end
    end
    local list = groups[1]
    if ncols > 1 then
        list = HorizontalGroup:new{ align = "top" }
        for c = 1, ncols do
            if c > 1 then
                table.insert(list, LineWidget:new{ background = Blitbuffer.COLOR_GRAY_D,
                    dimen = Geom:new{ w = rule, h = layout.rows * layout.row_h } })
            end
            table.insert(list, groups[c])
        end
    end
    if #items == 0 then
        local msg = self.query ~= "" and T(_("No books match “%1”."), self.query) or _("Nothing here yet.")
        list = CenterContainer:new{
            dimen = Geom:new{ w = width, h = math.floor(height / 2) },
            TextWidget:new{ text = msg, face = Font:getFace("infofont") },
        }
    end
    return TopContainer:new{
        dimen = Geom:new{ w = width, h = height },
        list,
    }
end

--- "43 % · 3 h ago" under a top-row cover; "Finished · 2 d ago" or
-- "On hold · …" for those books in Recently opened.
function LibraryView:resumeCaption(book, now)
    local parts = {}
    local pct = Core.percentText(book.percent)
    if book.status == "complete" or book.status == "abandoned" then
        parts[#parts + 1] = Tiles.statusLine(book)
    elseif book.status ~= "new" and pct and book.status ~= "reading" then
        parts[#parts + 1] = pct -- (books being read show it on the bar)
    end
    local ago = Core.relativeTime(book.last_opened, now or os.time())
    if not ago and book.last_opened then ago = os.date("%d %b", book.last_opened) end
    if ago then parts[#parts + 1] = ago end
    return table.concat(parts, " · ")
end

--- The strip's heading: "Continue reading" or "Recently opened". (Resume
-- is the button in the footer.)
function LibraryView:currentWidgetSlots()
    local Widgets = require("librarywidgets")
    if self.home_widgets ~= nil then return Widgets.normalize(self.home_widgets) end
    return Widgets.defaultFromContinue(self.show_continue ~= false)
end

function LibraryView:openWidgetMenu(index)
    if self.plugin and self.plugin.showWidgetMenu then
        self.plugin:showWidgetMenu(self, index)
    end
end

--- Tap a title to expand that widget over the other (#2). The other
-- becomes the tab on the right. Tap the title again, or the tab, to
-- return to the side-by-side pair. One widget has nothing to expand over.
function LibraryView:tapWidgetTitle(index)
    local Widgets = require("librarywidgets")
    local n = #self:currentWidgetSlots()
    if n < 2 then return false end
    self._widget_expanded = Widgets.accordion(n, self._widget_expanded, index)
    self:refreshBody(true)
    return true
end

function LibraryView:setHomeWidgets(slots)
    self.home_widgets = slots
    if self.plugin and self.plugin.settings then
        self.plugin.settings.home_widgets = slots
        if self.plugin.saveSettings then self.plugin:saveSettings() end
    end
    self._wpage = {}
    self._widget_expanded = nil
    self.page = 1
    self:refreshBody(true)
end

--- Pages remembered per widget. The view's copy wins for this session;
-- settings keep them across a book (the plugin is recreated) and a restart.
function LibraryView:widgetPages()
    if type(self._widget_pages) == "table" then return self._widget_pages end
    local settings = self.plugin and self.plugin.settings
    local pages = settings and settings.widget_pages
    if type(pages) == "table" then return pages end
    return {}
end

function LibraryView:setWidgetPage(spec, page)
    local Widgets = require("librarywidgets")
    local pages = Widgets.rememberPage(self:widgetPages(), spec, page)
    self._widget_pages = pages
    local settings = self.plugin and self.plugin.settings
    if type(settings) == "table" then
        settings.widget_pages = pages
        if self.plugin.saveSettings then self.plugin:saveSettings() end
    end
end

function LibraryView:widgetBookContext()
    local favorites, collections, series = {}, {}, {}
    if self.plugin and self.plugin.getCollections then
        local ok, groups = pcall(self.plugin.getCollections, self.plugin)
        if ok and type(groups) == "table" then
            collections = groups
            for _, g in ipairs(groups) do
                if g.name == "Favorites" then favorites = g.books or {} end
            end
        end
    end
    if self.groupsFor then
        local ok, groups = pcall(self.groupsFor, self, "series")
        if ok and type(groups) == "table" then series = groups end
    end
    return {
        continue = Core.topRowBooks(self.top_row, self.all_books, 40, fileExists),
        favorites = favorites,
        collections = collections,
        series = series,
        all = self.all_books,
    }
end

function LibraryView:buildOneWidget(spec, index, col_w, header_h, body_h, Widgets, ctx)
    local books = Widgets.books(spec, ctx)
    local gap = self.gap or 8
    -- Three covers across, and the tile must fit under the title inside
    -- the height reserved for the band so it does not paint over the grid.
    local per = col_w > 800 and 5 or 3
    local slot_w = math.max(48, math.floor((col_w - gap * (per + 1)) / per))
    local label_h = 36
    -- Fill the band. A 120px cap left a gap under covers that had room (#12).
    local cover_h = Widgets.coverHeight(slot_w, body_h, label_h, self.widget_covers)
    local pages = math.max(1, math.ceil(math.max(#books, 1) / per))
    if #books == 0 then pages = 1 end
    local page = Widgets.storedPage(self:widgetPages(), spec) or 1
    if page > pages then page = pages end
    if page < 1 then page = 1 end
    local face = Font:getFace("cfont", 16)
    local title = WidgetTitle:new{
        min_h = header_h,
        on_hold = function() self:openWidgetMenu(index) end,
        on_tap = function() self:tapWidgetTitle(index) end,
        TextWidget:new{ text = Widgets.label(spec), face = face, bold = true },
    }
    local function step(dir)
        self:setWidgetPage(spec, page + dir)
        self:refreshBody(true)
    end
    local function chevron(glyph, dir, enabled)
        return TapArea:new{
            min_w = 32, min_h = header_h, align = "center",
            callback = function() if enabled then step(dir) end end,
            TextWidget:new{ text = glyph, face = face, bold = true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_8 },
        }
    end
    local head = HorizontalGroup:new{
        align = "center",
        title,
        HorizontalSpan:new{ width = gap },
        chevron("<", -1, page > 1),
        chevron(">", 1, page < pages),
    }
    local book_row = HorizontalGroup:new{ align = "top" }
    if #books == 0 then
        book_row = TextWidget:new{ text = _("Nothing here yet."), face = face }
    else
        local start = (page - 1) * per + 1
        local now = os.time()
        for i = start, math.min(#books, start + per - 1) do
            local tile = Tiles.Tile:new{
                width = slot_w,
                height = cover_h + label_h,
                cover_h = cover_h,
                caption = self.resumeCaption and self:resumeCaption(books[i], now) or nil,
                book = books[i],
                covers = self.covers,
                cover_cache = self.cover_cache,
                on_tap = function(t, ges) self:onTileTap(t, ges) end,
                on_hold = function(t) self:onTileHold(t) end,
            }
            if tile.needs_cover and self.missing_covers then
                table.insert(self.missing_covers, books[i])
            end
            table.insert(book_row, tile)
            table.insert(book_row, HorizontalSpan:new{ width = gap })
        end
    end
    return VerticalGroup:new{
        align = "left",
        FrameContainer:new{ padding = 0, padding_left = gap, bordersize = 0, head },
        book_row,
    }
end

--- The other widget, written down the right edge. Tap it to restore the pair.
function LibraryView:buildWidgetTab(spec, index, width, height, Widgets)
    local name = Widgets.label(spec)
    local face = Font:getFace("cfont", 14)
    local col = VerticalGroup:new{ align = "center" }
    for ch in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if ch == " " then
            table.insert(col, VerticalSpan:new{ width = 8 })
        else
            table.insert(col, TextWidget:new{ text = ch, face = face, bold = true })
        end
    end
    local hit = WidgetTitle:new{
        min_w = width,
        min_h = math.min(height, 280),
        on_tap = function()
            self._widget_expanded = nil
            self:refreshBody(true)
        end,
        on_hold = function() self:openWidgetMenu(index) end,
        col,
    }
    return FrameContainer:new{
        padding = 2,
        padding_top = Size.padding.default,
        bordersize = Size.line.thin,
        radius = 8,
        width = width,
        height = height,
        hit,
    }
end

function LibraryView:buildHomeWidgets(slots, width, height)
    local Widgets = require("librarywidgets")
    local ctx = self:widgetBookContext()
    local n = math.max(1, #slots)
    local gap = self.gap or 8
    local header_h = self:continueHeaderHeight()
    local body_h = math.max(48, height - header_h)
    local expanded = self._widget_expanded
    if expanded and slots[expanded] and n >= 2 then
        local other = expanded == 1 and 2 or 1
        local tab_w = 48
        local main_w = width - tab_w - gap * 2
        local main = self:buildOneWidget(slots[expanded], expanded, main_w, header_h, body_h, Widgets, ctx)
        local tab = self:buildWidgetTab(slots[other], other, tab_w, height, Widgets)
        local row = HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = gap },
            main,
            tab,
        }
        return TopContainer:new{ dimen = Geom:new{ w = width, h = height }, row }
    end
    local col_w = math.floor((width - gap * (n + 1)) / n)
    local row = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = gap } }
    for i, spec in ipairs(slots) do
        table.insert(row, self:buildOneWidget(spec, i, col_w, header_h, body_h, Widgets, ctx))
        table.insert(row, HorizontalSpan:new{ width = gap })
    end
    return TopContainer:new{ dimen = Geom:new{ w = width, h = height }, row }
end

function LibraryView:buildContinueHeader()
    local f = Font:getFace("cfont", 17)
    local heading = Core.topRow(self.top_row) == "recent" and _("Recently opened") or _("Continue reading")
    local label = TextWidget:new{ text = heading, face = f, bold = true }
    local title = WidgetTitle:new{
        min_h = 28,
        on_hold = function() self:openWidgetMenu(1) end,
        on_tap = function() return self:tapWidgetTitle(1) end,
        label,
    }
    local row = HorizontalGroup:new{ align = "center", title }
    return FrameContainer:new{
        padding = 0,
        padding_left = Size.margin.default + self.gap,
        padding_top = Size.padding.default,
        bordersize = 0,
        row,
    }
end

--- The Continue reading strip: a heading and up to `slots` large covers.
function LibraryView:buildContinue(books, cl)
    local header = self:buildContinueHeader()
    local row = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = self.gap } }
    self.continue_tiles = {}
    local now = os.time()
    for i = 1, cl.count do
        local tile = Tiles.Tile:new{
            width = cl.slot_w,
            height = cl.tile_h,
            cover_h = cl.cover_h,
            caption = self:resumeCaption(books[i], now),
            book = books[i],
            covers = self.covers,
            cover_cache = self.cover_cache,
            on_tap = function(t, ges) self:onTileTap(t, ges) end,
            on_hold = function(t) self:onTileHold(t) end,
        }
        if tile.needs_cover then table.insert(self.missing_covers, books[i]) end
        table.insert(self.continue_tiles, tile)
        table.insert(row, tile)
        table.insert(row, HorizontalSpan:new{ width = self.gap })
    end
    local strip = VerticalGroup:new{ align = "left", header, row }
    return TopContainer:new{
        dimen = Geom:new{ w = self.width, h = cl.height },
        strip,
    }
end

function LibraryView:continueHeaderHeight()
    if not self._continue_header_h then
        local t = TextWidget:new{ text = "Ag", face = Font:getFace("cfont", 17), bold = true }
        self._continue_header_h = t:getSize().h + Size.padding.default
        t:free()
    end
    return self._continue_header_h
end

--- Rebuild everything below the search bar.
function LibraryView:buildBody()
    local t0 = time.now()
    local data = self:currentItems()
    local t1 = time.now()

    local tabs = self:buildTabs()
    local chips = data.kind == "books" and self:buildChips(data.counts) or nil
    if not chips and self.tab == "collections" and not self.group then chips = self:buildCollectionsSwitch() end
    local sep = VerticalSpan:new{ width = Size.padding.small }
    local footer_probe = self:buildFooter(1, 1, 0, data.kind)
    local header_h = self.header and self.header:getSize().h or 0
    -- The expand hairline sits between the search bar and the padding under
    -- it. Count it here so the grid does not run past the bottom of the screen.
    local rule_h = self._shelf_expanded and (Size.line.thin or 1) or 0
    local fixed = header_h + rule_h + Size.padding.small
        + tabs:getSize().h + (chips and chips:getSize().h or 0) + sep:getSize().h
        + footer_probe:getSize().h
    local keyboard_h = self:keyboardHeight()
    -- Word suggestions: a row right above the keyboard, kept while it is up
    -- (empty when there is nothing to suggest) so the grid does not jump.
    local suggest_row = keyboard_h > 0 and self.search_suggestions and self:buildSuggestions() or nil
    if suggest_row then fixed = fixed + suggest_row:getSize().h end
    local grid_h = math.max(self.label_h + 20, self.dimen.h - fixed - keyboard_h)

    -- Continue reading / Recently opened: shown only on page 1 of the Books
    -- tab (no search, no open group). A filter does not hide the widgets
    -- or expand the shelf (#11). Later pages use the full body so more
    -- books fit. Compact and two-column Compact never show the strip.
    -- Books already in the strip stay out of the paged rows on every page
    -- so a title never appears twice.
    local strip
    self.continue_tiles = nil
    self.continue_books = nil
    local continue_books, continue_layout
    local full_h = grid_h
    -- A swipe up hides the strip for now (issue #3): the shelf takes its
    -- space, exactly as when "Show Continue Reading" is off. The flag
    -- clears itself when there is no strip to hide (another tab, a search,
    -- the keyboard), so the hairline under the search bar only ever marks
    -- a real, temporary hide.
    local Widgets = require("librarywidgets")
    local widget_state = {
        tab = self.tab, group = self.group, query = self.query,
        filter = self.filter, keyboard = keyboard_h > 0,
        filter_expands = self.filter_expands ~= false,
    }
    local custom_widgets = self.home_widgets ~= nil
    local widget_slots = custom_widgets and Widgets.normalize(self.home_widgets) or nil
    local widget_area = custom_widgets and Widgets.areaVisible(widget_slots, widget_state)
        and data.kind == "books" and not Core.isCompact(self.view_mode)
    local strip_possible = widget_area or (data.kind == "books" and not Core.isCompact(self.view_mode) and Core.showContinue{
        enabled = self.show_continue, tab = self.tab, group = self.group,
        query = self.query, filter = self.filter, keyboard = keyboard_h > 0,
        filter_expands = self.filter_expands ~= false })
    -- Whether this screen can show a widget band at all. A letter jump
    -- keeps the expand gesture working from this, including on a later
    -- page (#15). The slot is not a shelf-height constraint.
    self._strip_possible = strip_possible and true or false
    if not strip_possible then self._shelf_expanded = nil end
    self._widget_band_h = nil
    if widget_area and not self._shelf_expanded then
        self._widget_band_h = math.max(140, math.floor(full_h * 0.30))
        continue_layout = { height = self._widget_band_h }
        for _, spec in ipairs(widget_slots) do
            if spec.kind == "continue" then
                continue_books = Core.topRowBooks(self.top_row, self.all_books, self.continue_slots, fileExists)
            end
        end
    elseif strip_possible and not self._shelf_expanded then
        local cbooks = Core.topRowBooks(self.top_row, self.all_books, self.continue_slots, fileExists)
        local min_rest = (self.view_mode == "list" or self.view_mode == "list2") and 3 * self.list_row_h or (self.label_h + 100)
        local cl = Core.continueLayout(self.width, full_h, #cbooks, self.continue_label_h,
            self:continueHeaderHeight(), self.gap, { slots = self.continue_slots, min_rest = min_rest, frac = 0.3 })
        if cl then
            continue_books = cbooks
            continue_layout = cl
        end
    end

    -- The A–Z strip takes a slice of the width, so covers are laid out in
    -- what remains and never slide under it. Which lists get it is
    -- Core.scrubberMode (alphabetical sorts, Authors, a multi-page Series
    -- list; not Last read, not Compact · 2 columns, not a one-page search).
    -- The sort itself is left alone.
    local function letterMode(pages)
        if #data.items < 1 then return nil end
        return self:scrubberLetterMode(data.kind, pages)
    end
    -- A short shelf cannot show every letter in one column. Split the
    -- alphabet across both edges then (#14). The slot minimum only decides
    -- that; it does not change the shelf height. Use the shorter page (the
    -- one under the widgets) so the two pages do not disagree.
    local az_h = full_h
    if continue_layout then
        local short = full_h - continue_layout.height
        if short < az_h then az_h = math.max(1, short) end
    end
    local split_left, split_right = Core.azHalves(
        self.az_layout, Core.SCRUBBER_LETTERS, az_h, Core.scrubberMinSlot(self:screenDpi()))
    local function widthsFor(mode)
        if not mode then return self.width, 0 end
        local strip_w = Core.scrubberWidth(self:screenDpi())
        local cols = split_left and 2 or 1
        local content_w = Core.gridContentWidth(self.width, strip_w * cols)
        local reserved = self.width - content_w
        local one_w = cols == 2 and math.floor(reserved / 2) or reserved
        return content_w, one_w
    end
    local letter_mode = letterMode(nil)
    local grid_w, letter_w = widthsFor(letter_mode)

    local function layoutFor(h, under_strip)
        if Core.isCompact(self.view_mode) then
            local layout = Core.listLayout(h, Tiles.compactRowHeight(), 0, { max_rows = 40 })
            local ncols = Core.listColumns(self.view_mode)
            layout.cols, layout.per_page = ncols, layout.rows * ncols
            return layout
        elseif Core.textRows(self.view_mode, data.kind, self.tab) then
            -- Authors: one line per row; Series: the name over its authors.
            return Core.listLayout(h, Tiles.textRowHeight(self.tab == "series" and 2 or 1), 0, { max_rows = 24 })
        elseif self.view_mode == "list" or self.view_mode == "list2" then
            local layout = Core.listLayout(h, self.list_row_h, Size.padding.small, { max_rows = 10 })
            local ncols = Core.listColumns(self.view_mode)
            layout.cols = ncols
            layout.per_page = layout.rows * ncols
            return layout
        else
            -- Cover only keeps the progress row and drops the title, so more
            -- covers fit. Shelves still need their names, so they keep the
            -- full label. Under the Continue reading strip, accept smaller
            -- covers for a second row.
            local label_h = self.label_h
            if Core.isCoverOnly(self.view_mode) and data.kind == "books" then
                label_h = self.cover_label_h
            end
            return Core.gridLayout(grid_w, h, self.cols, label_h, self.gap, under_strip and 0.6 or nil)
        end
    end

    local function pageSlice()
        local later_layout = layoutFor(full_h, false)
        local page1_h = continue_layout and (full_h - continue_layout.height) or full_h
        local page1_layout = continue_layout and layoutFor(page1_h, true) or later_layout
        local first_per, later_per = page1_layout.per_page, later_layout.per_page
        -- Books in the Continue reading strip appear only there (page 1), so
        -- leave them out of the paged rows: each title is on screen once.
        -- The footer still counts all books.
        local grid_items = continue_books and Core.withoutShown(data.items, continue_books) or data.items
        local page_items, page, pages = Core.page(grid_items, first_per, self.page, later_per)
        -- A letter jump anchors the page at its first matching book (#7):
        -- the matching books start at the top instead of wherever the page
        -- boundary falls.
        page_items = self:anchoredPageItems(grid_items, page_items, page, first_per, later_per, letter_mode)
        return later_layout, page1_layout, page1_h, first_per, later_per, grid_items, page_items, page, pages
    end
    local later_layout, page1_layout, page1_h, first_per, later_per, grid_items, page_items, page, pages = pageSlice()
    -- A one-page search, or a Series list that fits on one page, drops the
    -- strip. Laying out again at full width can only fit the same or more,
    -- so the page count does not grow back across the threshold.
    local fitted = letterMode(pages)
    if fitted ~= letter_mode then
        letter_mode = fitted
        grid_w, letter_w = widthsFor(letter_mode)
        later_layout, page1_layout, page1_h, first_per, later_per, grid_items, page_items, page, pages = pageSlice()
    end
    self.page, self.pages = page, pages
    self.current = data
    self.missing_covers = {}

    local on_first = page == 1 and continue_layout ~= nil
    local layout = on_first and page1_layout or later_layout
    grid_h = on_first and page1_h or full_h
    if on_first then
        strip = continue_layout
        self.continue_books = continue_books
    end
    self.layout = layout

    local strip_widget
    if self._widget_band_h and widget_slots then
        strip_widget = self:buildHomeWidgets(widget_slots, self.width, self._widget_band_h)
    else
        strip_widget = strip and self:buildContinue(self.continue_books, strip)
    end
    local continue_missing = self.missing_covers
    local grid
    if self.view_mode == "list" or self.view_mode == "list2" or Core.isCompact(self.view_mode) then
        grid = self:buildList(page_items, data.kind, layout, grid_h, grid_w)
    else
        grid = self:buildGrid(page_items, data.kind, layout, grid_h, grid_w)
    end
    for _, sc in ipairs(self.scrubbers or {}) do
        self:dropScrubber(sc)
    end
    self:dropScrubber(self.scrubber)
    self.scrubber, self.scrubbers = nil, nil
    if letter_mode and letter_w > 0 then
        local anchor_item = page_items[1]
        local anchor = anchor_item and Core.scrubberBucket(Core.scrubberItemKey(anchor_item, letter_mode)) or nil
        if split_left and split_right then
            local left = self:buildScrubber(grid_items, first_per, letter_mode, letter_w, grid_h, anchor, later_per, {
                letters = split_left, side = "left",
            })
            local right = self:buildScrubber(grid_items, first_per, letter_mode, letter_w, grid_h, anchor, later_per, {
                letters = split_right, side = "right",
            })
            -- Either half can jump: both carry the full index.
            self.scrubber = right
            self.scrubbers = { left, right }
            grid = HorizontalGroup:new{ align = "top", left, grid, right }
        else
            self.scrubber = self:buildScrubber(grid_items, first_per, letter_mode, letter_w, grid_h, anchor, later_per)
            self.scrubbers = { self.scrubber }
            grid = HorizontalGroup:new{ align = "top", grid, self.scrubber }
        end
    end
    for _, p in ipairs(continue_missing) do table.insert(self.missing_covers, p) end
    local footer = self:buildFooter(page, pages, #data.items, data.kind)

    -- Tabs stay under the search bar unless the reader moves them under
    -- the footer (#17). Filters stay with the shelf either way.
    local tabs_bottom = Core.tabRow(self.tab_row) == "bottom"
    self.body = VerticalGroup:new{ align = "left" }
    if not tabs_bottom then table.insert(self.body, tabs) end
    if chips then table.insert(self.body, chips) end
    table.insert(self.body, sep)
    if strip_widget then
        table.insert(self.body, strip_widget)
    end
    table.insert(self.body, grid)
    table.insert(self.body, footer)
    if tabs_bottom then table.insert(self.body, tabs) end
    if suggest_row then table.insert(self.body, suggest_row) end

    -- While the shelf is expanded by a swipe, a hairline under the search
    -- bar marks the widgets as only temporarily hidden (issue #3).
    local frame = {
        align = "left",
        self.header,
    }
    if self._shelf_expanded then
        table.insert(frame, LineWidget:new{
            background = Blitbuffer.COLOR_GRAY_B,
            dimen = Geom:new{ w = self.dimen.w, h = Size.line.thin },
        })
    end
    table.insert(frame, VerticalSpan:new{ width = Size.padding.small })
    table.insert(frame, self.body)
    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.dimen.w,
        height = self.dimen.h,
        VerticalGroup:new(frame),
    }
    self.body_y = (self.header and self.header:getSize().h or 0) + Size.padding.small
    self.timings.filter_s = time.to_s(t1 - t0)
    self.timings.build_s = time.to_s(time.now() - t1)
    self:scheduleCoverExtraction()
end

--- What the search box searches here, for word suggestions: the books (or
-- shelves) the query narrows. Returns the list and whether it is shelves.
function LibraryView:suggestionScope()
    if self.group then return self.group.books, false end
    if Core.searchScope(self.tab) == "books" then return self.all_books, false end
    return self:groupsFor(self.tab), true
end

--- The words to suggest from, built once per scope (and again when the
-- library changes).
function LibraryView:suggestionWords()
    local items, shelves = self:suggestionScope()
    local c = self._vocab
    if c and c.items == items then return c.vocab end
    local t0 = time.now()
    local vocab = Suggest.vocabulary(items, lower, shelves)
    self.timings.vocab_s = time.to_s(time.now() - t0)
    self._vocab = { items = items, vocab = vocab }
    return vocab
end

--- The row of suggested words (the space is kept even when it is empty).
function LibraryView:buildSuggestions()
    local margin = Size.margin.default + Size.padding.default
    local gap = Size.padding.default
    local avail = self.width - 2 * margin
    local words = {}
    if self.query ~= "" then
        words = Suggest.suggest(self:suggestionWords(), self.query, { lower = lower, fuzzy = self.fuzzy_search })
    end
    local row = HorizontalGroup:new{ align = "center" }
    local used = 0
    for _, w in ipairs(words) do
        local chip = Tiles.Chip:new{
            text = w,
            max_text_w = math.floor(avail * 0.4),
            callback = function() self:useSuggestion(w) end,
        }
        local cw = chip:getSize().w + (used > 0 and gap or 0)
        if used + cw > avail then break end
        if used > 0 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        table.insert(row, chip)
        used = used + cw
    end
    self.suggestions = words
    local h = self._suggest_h
    if not h then
        h = Tiles.Chip:new{ text = "Ag" }:getSize().h
        self._suggest_h = h
    end
    local pad = Size.padding.small
    return FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_top = pad,
        padding_bottom = pad,
        bordersize = 0,
        width = self.width,
        height = h + 2 * pad,
        LeftContainer:new{ dimen = Geom:new{ w = avail, h = h }, row },
    }
end

--- A suggestion was tapped: it replaces the half-typed word, and the search
-- runs at once. The keyboard stays up for the next word.
function LibraryView:useSuggestion(word)
    local text = Suggest.apply(self.search_input:getText(), word)
    if self._search_action then UIManager:unschedule(self._search_action); self._search_action = nil end
    local input = self.search_input
    input:setText(text, true)
    if input.goToEnd then input:goToEnd() end -- type on after the word
    if self._search_action then UIManager:unschedule(self._search_action); self._search_action = nil end
    self:applySearch(text)
end

--- Turn "Word suggestions" on or off.
function LibraryView:setSearchSuggestions(on)
    on = on and true or false
    if on == self.search_suggestions then return end
    self.search_suggestions = on
    self:refreshBody(true)
end

--- Region below the header (where results are drawn).
function LibraryView:bodyRegion()
    return Geom:new{ x = 0, y = self.body_y, w = self.dimen.w, h = self.dimen.h - self.body_y }
end

--- While the keyboard is up, the results refresh stops above the keyboard.
-- The old region ran from the header to the bottom edge, so every keystroke
-- pushed one near-fullscreen update through the keys. The keys are painted
-- with the library (they sit above it) but are not part of this refresh:
-- a second refresh of the keyboard would be merged with this one, since the
-- two rectangles share an edge, and the full-height flash would be back.
function LibraryView:resultsRegion()
    local r = Core.searchRefreshRegion(self.dimen.w, self.dimen.h, self.body_y or 0, self:keyboardHeight())
    return Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }
end

--- Rebuild and refresh only the results region (fast path used while typing).
-- reason is for e-ink ghosting ("page", "tab", "shelf", "overlay"): see libraryrefresh.lua.
function LibraryView:refreshBody(full, reason)
    -- A full repaint already covers the header, so the clock can move with it.
    if full or self._title_changed then self:updateStatusText() end
    self:buildBody()
    local typing = self:keyboardHeight() > 0
    local region
    if typing then
        region = self:resultsRegion()
    elseif full or self._title_changed then
        region = self.dimen
    else
        region = self:bodyRegion()
    end
    self._title_changed = nil
    local mode = self:refreshMode(reason)
    UIManager:setDirty(self, function()
        return mode, region, true
    end)
end

--- "flashui" on e-ink when we should clear cover ghosts; "ui" otherwise.
-- libraryrefresh.lua is required here so specs that stub require() keep
-- the old "ui" refresh (the stub has no decide function).
function LibraryView:refreshMode(reason)
    local ok, Refresh = pcall(require, "libraryrefresh")
    if not (ok and type(Refresh) == "table" and type(Refresh.decide) == "function") then
        return "ui"
    end
    local eink = type(Device.hasEinkScreen) == "function" and Device:hasEinkScreen() == true
    local every
    if type(UIManager.getRefreshRate) == "function" then
        local ok_rate, rate = pcall(UIManager.getRefreshRate, UIManager)
        if ok_rate then every = tonumber(rate) end
    end
    if every == nil and _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        every = tonumber(_G.G_reader_settings:readSetting("full_refresh_count"))
    end
    local settings = self.plugin and self.plugin.settings
    local mode, turns = Refresh.decide{
        eink = eink,
        choice = settings and settings.flash_ghosting,
        reason = reason,
        turns = self._page_turns or 0,
        every = every,
        cover_grid = Refresh.isCoverGrid(self.view_mode),
    }
    self._page_turns = turns
    return mode
end

--- One full-screen refresh of this view after a menu or dialog closes.
-- The target is the Library, never a nil widget (that only refreshes
-- whatever is already in the framebuffer, often the file browser) and
-- never a rectangle the size of the menu. The A–Z strip, the clock and
-- the footer are inside this rectangle. No rebuild.
function LibraryView:flashOverlay()
    if not UIManager.setDirty then return end
    local d = self.dimen
    local mode, rect = "full", {
        x = 0, y = 0,
        w = d and d.w or 0,
        h = d and d.h or 0,
    }
    local ok, Refresh = pcall(require, "libraryrefresh")
    if ok and type(Refresh) == "table" and type(Refresh.overlayClose) == "function" then
        mode, rect = Refresh.overlayClose(d and d.w, d and d.h)
    end
    if type(Geom) == "table" and type(Geom.new) == "function" and type(rect) == "table" then
        local g = Geom:new{
            x = tonumber(rect.x) or 0, y = tonumber(rect.y) or 0,
            w = tonumber(rect.w) or 0, h = tonumber(rect.h) or 0,
        }
        if type(g) == "table" and type(g.w) == "number" then rect = g end
    end
    UIManager:setDirty(self, function()
        return mode, rect
    end)
end

----------------------------------------------------------------------------
-- Search
----------------------------------------------------------------------------

function LibraryView:onSearchEdited()
    self:timeStart("search") -- from this (last) keystroke until its results are painted
    if self._search_action then UIManager:unschedule(self._search_action) end
    self._search_action = function()
        self._search_action = nil
        self:applySearch(self.search_input:getText())
    end
    UIManager:scheduleIn(self.debounce_s, self._search_action)
end

function LibraryView:applySearch(text)
    text = text or ""
    if text == self.query then
        if self.timing then self.timing:cancel("search") end
        return
    end
    self.query = text
    self.page = 1
    if self.timing then self.timing:arm("search", "query=" .. #text) end
    self:updateSearchClear()
    self:refreshBody()
end

--- Show the clear (X) button only while there is a query to clear, and hide
-- it again once the query is empty (issue #6). The text box is not rebuilt
-- and the keyboard is not reopened.
function LibraryView:updateSearchClear()
    if not self.search_input or not self._search_clear then return end
    local want = self.search_input:getText() ~= ""
    if want == self._search_clear_visible then return end
    self:setSearchClearShown(want)
    if UIManager.setDirty then
        UIManager:setDirty(self, function() return "ui", self:headerRegion(), true end)
    end
end

function LibraryView:clearSearch()
    if self._search_action then UIManager:unschedule(self._search_action); self._search_action = nil end
    self.search_input:setText("")
    self:applySearch("")
end

-- On devices KOReader treats as having a D-pad (the Kindle Colorsoft on
-- v2026.07, the desktop emulator), InputText's tap handler also asks its
-- parent for FocusManager:getFocusableWidgetXY() and moveFocusTo(). This view
-- is not a FocusManager, so tapping the search bar crashed with "attempt to
-- call method 'getFocusableWidgetXY' (a nil value)". The search bar is the only
-- focusable widget here, so there is never a D-pad focus to move.
function LibraryView:getFocusableWidgetXY() return nil end
function LibraryView:moveFocusTo() return false end

-- Called by InputText when its box is tapped.
function LibraryView:onSwitchFocus(inputbox)
    if self.use_koreader_keyboard then
        self:openKoreaderSearch()
        return
    end
    if not inputbox.focused then inputbox:focus() end
    if not inputbox:isKeyboardVisible() then
        self:openKeyboard()
    end
end

--- Authors (the list of names, not one author's books): a letters-only
-- keyboard, with no number row; numbers stay behind the symbols key.
function LibraryView:wantsLettersKeyboard()
    return self.tab == "authors" and not self.group
end

--- Rebuild the search keyboard when the place wants the other kind.
function LibraryView:matchKeyboard()
    local input = self.search_input
    local want = self:wantsLettersKeyboard()
    if input.hide_number_row == want then return false end
    input.hide_number_row = want
    if input.keyboard and not input:isKeyboardVisible() then input:initKeyboard() end
    return true
end

function LibraryView:openKeyboard()
    if self.use_koreader_keyboard then return self:openKoreaderSearch() end
    self:matchKeyboard()
    self.search_input:focus()
    self.search_input:onShowKeyboard()
    self:markSearchFocus(true)
    -- While the (modal) keyboard is up, taps outside it must still reach the grid.
    self.is_always_active = true
    self:refreshBody()
end

--- KOReader's stock text box and keyboard. What is typed still filters the
-- Library; Cancel puts the previous query back.
function LibraryView:openKoreaderSearch()
    if self._search_dialog then return end
    local original = self.search_input and self.search_input:getText() or self.query or ""
    local dialog
    local done = false
    local function finish(keep)
        if done then return end
        done = true
        local text = keep and (dialog:getInputText() or "") or original
        self._search_dialog = nil
        if self.plugin and self.plugin.closeOverLibrary then
            self.plugin:closeOverLibrary(dialog, self)
        else
            UIManager:close(dialog)
        end
        if self._search_action then UIManager:unschedule(self._search_action); self._search_action = nil end
        if self.search_input then self.search_input:setText(text) end
        self:applySearch(text)
    end
    dialog = InputDialog:new{
        title = _("Search"),
        input = original,
        input_hint = self:searchHint(),
        -- Each keystroke, once the text has actually changed. InputDialog passes
        -- this through to its text box; `edited` is false while the box is first drawn.
        edited_callback = function(edited)
            if not edited or done or not dialog.getInputText then return end
            local text = dialog:getInputText() or ""
            if self.search_input then self.search_input:setText(text) end
            self:onSearchEdited()
        end,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() finish(false) end },
            { text = _("Search"), is_enter_default = true, callback = function() finish(true) end },
        } },
    }
    self._search_dialog = dialog
    if self.plugin and self.plugin.showOverLibrary then
        self.plugin:showOverLibrary(dialog, self)
    else
        UIManager:show(dialog)
    end
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function LibraryView:setUseKoreaderKeyboard(on)
    on = on and true or false
    if on == (self.use_koreader_keyboard and true or false) then return end
    self:keyboardGuard()
    if self._search_dialog then
        local dialog = self._search_dialog
        self._search_dialog = nil
        if self.plugin and self.plugin.closeOverLibrary then
            self.plugin:closeOverLibrary(dialog, self)
        else
            UIManager:close(dialog)
        end
    end
    self.use_koreader_keyboard = on
    self:buildSearchRow()
    self:refreshBody(true)
end

function LibraryView:closeKeyboard()
    if self.search_input:isKeyboardVisible() then
        self.search_input:onCloseKeyboard()
    end
    self.search_input:unfocus()
    self:markSearchFocus(false)
    self.is_always_active = false
    self:refreshBody(true, "overlay")
end

-- The keyboard's own layout changes (e.g. switching to symbols) can change its height.
function LibraryView:onKeyboardHeightChanged()
    self:refreshBody(true)
end

-- Tap on empty space with the keyboard up: hide it.
function LibraryView:onTapOutside(_, ges)
    if self:tryOpenControlsFromTap(ges) then return true end
    if self.search_input:isKeyboardVisible() then
        local kb = self.search_input.keyboard
        if not (kb.dimen and ges.pos:intersectWith(kb.dimen)) then
            self:closeKeyboard()
            return true
        end
    end
    return false
end

-- Focus the search bar from a gesture/dispatcher action.
function LibraryView:focusSearch()
    self:openKeyboard()
end

----------------------------------------------------------------------------
-- Navigation
----------------------------------------------------------------------------

function LibraryView:keyboardGuard()
    -- When a tile is tapped while typing, hide the keyboard first.
    if self.search_input:isKeyboardVisible() then
        self.search_input:onCloseKeyboard()
        self.search_input:unfocus()
        self:markSearchFocus(false)
        self.is_always_active = false
    end
end

function LibraryView:setTab(id)
    self:keyboardGuard()
    self:resetQuery() -- each tab searches its own things: start afresh
    self.tab, self.group, self.page = id, nil, 1
    self:updateSearchHint()
    self:applyRemembered()
    self:refreshBody(true, "tab")
end

function LibraryView:setFilter(f)
    self:timeStart("filter", true)
    self:keyboardGuard()
    self.filter, self.page = f, 1
    self:rememberPref("filter", f)
    self:refreshBody(true)
end

function LibraryView:openGroup(group)
    self.saved_page = self.page
    self.saved_query = self.query -- e.g. "tolk" on Authors, back on close
    self:resetQuery()
    self.group, self.page = group, 1
    self:updateSearchHint()
    self:applyRemembered()
    self:refreshBody(true, "shelf")
end

function LibraryView:closeGroup()
    self.group = nil
    self.page = self.saved_page or 1
    self:resetQuery()
    if self.saved_query and self.saved_query ~= "" then
        self.query = self.saved_query
        self.search_input:setText(self.query)
    end
    self.saved_query = nil
    self:updateSearchHint()
    self:applyRemembered()
    self:refreshBody(true)
end

----------------------------------------------------------------------------
-- Per-shelf memory (layout, sort, filter)
----------------------------------------------------------------------------

--- The key this place's layout, sort and filter are remembered under.
function LibraryView:viewKey()
    return Core.viewKey(self.tab, self.group)
end

--- A name for this place in menus: "Oz", "Authors", "Books".
function LibraryView:placeName()
    if self.group then return self.group.name end
    for _, t in ipairs(TABS) do if t.id == self.tab then return t.text end end
    return _("Books")
end

--- After the sort changed, the open group's book list is stale: pick the
-- same group again from the re-sorted data.
function LibraryView:reresolveGroup()
    local g = self.group
    if not g then return end
    local kind = g.kind
    if kind ~= "collections" and kind ~= "authors" and kind ~= "series" and kind ~= "genres" then return end
    for _, ng in ipairs(self:groupsFor(kind)) do
        if ng.name == g.name then self.group = ng; return end
    end
end

--- Put back what this place remembers (nothing when the memory is off).
-- Does not redraw; the caller does.
function LibraryView:applyRemembered()
    local prefs = self.plugin.viewPrefs and self.plugin:viewPrefs(self:viewKey())
    if not prefs then return false end
    self.view_mode = Core.viewMode(prefs.view)
    self.filter = prefs.filter
    if prefs.sort ~= self.sort then
        self.sort = prefs.sort
        self:reloadData()
        self:reresolveGroup()
    end
    return true
end

--- Remember a change for this place (see Core.rememberViewPref).
function LibraryView:rememberPref(field, value)
    if self.plugin.rememberViewPref then self.plugin:rememberViewPref(self:viewKey(), field, value) end
end

--- Whether this place has its own remembered layout/sort/filter.
function LibraryView:hasRemembered()
    if not self.plugin.viewPrefs then return false end
    local _prefs, remembered = self.plugin:viewPrefs(self:viewKey())
    return remembered
end

--- "Reset to default": forget this place's settings and show the defaults.
function LibraryView:resetRemembered()
    if self.plugin.resetViewPrefs then self.plugin:resetViewPrefs(self:viewKey()) end
    self.page = 1
    self:applyRemembered()
    self:refreshBody(true)
end

function LibraryView:onLeftIcon()
    self.plugin:showLibraryMenu(self)
end

--- True inside a series opened from the Series tab.
function LibraryView:inSeries()
    return self.group ~= nil and self.group.kind == "series"
end

--- Position of the open series among the Series tab's groups: pos, count.
function LibraryView:seriesPosition()
    if not self:inSeries() then return nil end
    local groups = self:groupsFor("series")
    for i, g in ipairs(groups) do
        if g.name == self.group.name then return i, #groups end
    end
    return nil, #groups
end

--- Open the next (dir = 1) or previous (-1) series in place. Returns true
-- when there was one. Lands on the first page going forward and on the
-- last page going back, so paging feels continuous.
function LibraryView:stepSeries(dir)
    local pos = self:seriesPosition()
    if not pos then return false end
    local groups = self:groupsFor("series")
    local g = groups[pos + dir]
    if not g then return false end
    self.group = g
    self.page = dir > 0 and 1 or math.huge
    self:applyRemembered()
    self:refreshBody(true, "shelf")
    return true
end

--- Long-press on a page arrow: the first page (dir < 0) or the last (dir > 0)
-- of the list on screen. Already there, or only one page: nothing happens
-- and the screen is not rebuilt, so a following tap can still open a book.
-- Stays inside the open folder or series. A tap still steps to the
-- neighbouring series from either end.
function LibraryView:jumpToEnd(dir)
    if not self.pages then return end
    self:goToPage(dir < 0 and 1 or self.pages)
end

--- One page forward or back; in a series, past either end steps to the
-- neighbouring series instead of wrapping.
function LibraryView:turnPage(dir, wrap)
    if not self.pages then return end
    -- A letter jump keeps its own windows: the next page starts where this
    -- one ended, and the previous page ends where this one starts (#7).
    if self:_turnAnchoredPage(dir, wrap) then return end
    local target = self.page + dir
    if target >= 1 and target <= self.pages then return self:goToPage(target) end
    if self:inSeries() and self:stepSeries(dir) then return end
    if wrap then self:goToPage(dir > 0 and 1 or self.pages) end
end

--- Step the letter-jump window by one page. True when the anchor handled
-- the turn (including a wrap off either end, which drops back to fixed pages).
function LibraryView:_turnAnchoredPage(dir, wrap)
    local anchor = self._jump_anchor
    if not anchor or type(anchor.index) ~= "number" or type(anchor.count) ~= "number" then
        return false
    end
    if anchor.key ~= self:_jumpAnchorKey() then
        self._jump_anchor = nil
        return false
    end
    local n = math.floor(tonumber(anchor.n) or 0)
    if n < 1 then return false end
    local first_per = math.max(1, math.floor(tonumber(anchor.first_per) or anchor.count))
    local later_per = math.max(1, math.floor(tonumber(anchor.later_per) or first_per))
    local function leave()
        self._jump_anchor = nil
        self._shelf_expanded = nil
        if self.inSeries and self:inSeries() and self:stepSeries(dir) then return true end
        if wrap then self:goToPage(dir > 0 and 1 or self.pages) end
        return true
    end
    local next_index, count, page
    if dir > 0 then
        next_index = anchor.index + anchor.count
        if next_index > n then return leave() end
        page = Core.pageOfIndex(next_index, first_per, later_per)
        local cap = (page == 1) and first_per or later_per
        count = math.min(cap, n - next_index + 1)
    else
        if anchor.index <= 1 then return leave() end
        local back = math.min(later_per, anchor.index - 1)
        next_index = anchor.index - back
        if Core.pageOfIndex(next_index, first_per, later_per) == 1 then
            back = math.min(first_per, anchor.index - 1)
            next_index = anchor.index - back
        end
        count = back
        page = Core.pageOfIndex(next_index, first_per, later_per)
    end
    anchor.index = next_index
    anchor.count = count
    self._shelf_expanded = nil
    -- The footer page is the fixed page that holds the first book on screen.
    -- A window that reaches the last book is the last page, so Next does not
    -- look like it has another page of the same books.
    if next_index + count - 1 >= n then page = self.pages end
    self:timeStart("page", true)
    self.page = math.max(1, math.min(page, self.pages))
    self._turned_ms = time.to_ms(time.now())
    self:refreshBody(nil, "page")
    return true
end

function LibraryView:goToPage(page, anchor, opts)
    if not self.pages then return end
    page = math.max(1, math.min(page, self.pages))
    if page == self.page and anchor == nil and self._jump_anchor == nil then return end
    -- The expand is for the page that was showing. Another page draws its
    -- own layout, and page 2+ never had the Continue strip. A letter jump
    -- is not that: it keeps the shelf as it was (#15).
    if page ~= self.page and not (opts and opts.keep_shelf) then self._shelf_expanded = nil end
    -- A letter jump carries its first matching book: the page is shown from
    -- that book, so its books start at the top (issue #7). A direct page
    -- request (the footer number, a long-press) clears the anchor and
    -- returns to fixed pages. Paging with the arrows keeps the window;
    -- see _turnAnchoredPage.
    if anchor then
        self._jump_anchor = {
            index = anchor.index, origin = anchor.index, letter = anchor.letter,
            key = self:_jumpAnchorKey(),
        }
    else
        self._jump_anchor = nil
    end
    self:timeStart("page", true)
    self.page = page
    self._turned_ms = time.to_ms(time.now())
    self:refreshBody(nil, "page")
end

--- Jump to a letter on the A–Z strip, with the first matching book at the
-- top of the grid (issue #7). Returns false when the letter has nothing
-- under it, or when the view is already showing exactly that jump.
function LibraryView:jumpToLetter(letter)
    local index = self.scrubber and self.scrubber.index
    local page = Core.scrubberTargetPage(index, letter)
    local first = Core.scrubberFirstIndex(index, letter)
    if not page or not first then return false end
    local anchor = self._jump_anchor
    if page == self.page and anchor and anchor.index == first and anchor.letter == letter then return false end
    self:goToPage(page, { index = first, letter = letter }, { keep_shelf = self.letter_keeps_shelf == true })
    return true
end

--- What the list a letter jump was made on looked like: tab, group, sort,
-- filter, query, and whether Continue reading takes books out of the grid.
-- A jump only holds while all of it is unchanged (#7).
function LibraryView:_jumpAnchorKey()
    return table.concat({
        tostring(self.tab), tostring(self.group), tostring(self.sort),
        tostring(self.filter), tostring(self.query), tostring(self.show_continue),
    }, "|")
end

--- The page's items when a letter jump is holding the view (#7): the page
-- starts at the anchor instead of at the fixed page boundary. Paging keeps
-- that window and continues from either end. Returns `page_items` unchanged
-- when there is no jump, the list has changed since the jump, or the book
-- the jump landed on no longer falls under that letter.
function LibraryView:anchoredPageItems(grid_items, page_items, page, first_per, later_per, letter_mode)
    local anchor = self._jump_anchor
    if not anchor or type(anchor.index) ~= "number" or type(anchor.letter) ~= "string" then return page_items end
    if anchor.key ~= self:_jumpAnchorKey() then self._jump_anchor = nil; return page_items end
    if type(letter_mode) ~= "string" then self._jump_anchor = nil; return page_items end
    grid_items = grid_items or {}
    local origin = anchor.origin or anchor.index
    local item = grid_items[origin]
    if not item or Core.scrubberBucket(Core.scrubberItemKey(item, letter_mode)) ~= anchor.letter then
        self._jump_anchor = nil
        return page_items
    end
    local first = math.max(1, math.floor(tonumber(first_per) or 1))
    local later = math.max(1, math.floor(tonumber(later_per) or first))
    local size = anchor.count
    if type(size) ~= "number" then
        size = (page == 1) and first or later
    end
    local n = #grid_items
    if anchor.index > n then
        self._jump_anchor = nil
        return page_items
    end
    size = math.min(math.max(1, math.floor(size)), n - anchor.index + 1)
    anchor.count = size
    anchor.first_per = first
    anchor.later_per = later
    anchor.n = n
    anchor.origin = origin
    return Core.pageFrom(grid_items, anchor.index, size)
end

function LibraryView:onNextPage() self:turnPage(1); return true end
function LibraryView:onPrevPage() self:turnPage(-1); return true end

--- Dots per inch, or KOReader's 167 baseline when the device does not say.
function LibraryView:screenDpi()
    if Screen and Screen.getDPI then
        local ok, dpi = pcall(function() return Screen:getDPI() end)
        if ok and type(dpi) == "number" and dpi >= 1 then return dpi end
    end
    return 167
end

--- How wide a page arrow or the page number must be to hit, in pixels.
function LibraryView:pageHit()
    return Core.pageHitPx(self:screenDpi())
end

--- The A–Z strip is on unless the setting says otherwise.
function LibraryView:scrubberEnabled()
    if self.show_scrubber ~= nil then return self.show_scrubber and true or false end
    return Core.showScrubber(self.plugin and self.plugin.settings)
end

function LibraryView:setShowScrubber(on)
    on = on and true or false
    if self.show_scrubber == on then return end
    self.show_scrubber = on
    self:refreshBody(true)
end

--- The letter field for the strip on this list, or nil when it stays off.
-- `pages` is the page count once layout is known; omit it before that.
function LibraryView:scrubberLetterMode(kind, pages)
    local q = self.query
    return Core.scrubberMode({
        enabled = self:scrubberEnabled(),
        kind = kind or "books",
        sort = self.sort,
        in_series = self.inSeries and self:inSeries() or false,
        tab = self.group and self.group.kind or self.tab,
        view = self.view_mode,
        searching = (type(q) == "string" and q:match("%S") ~= nil) or nil,
        pages = pages,
    })
end

--- Nil when this list should not show the strip. Otherwise the mode, the
-- reserved width and the width left for the covers.
function LibraryView:scrubberPlan(kind, n_items, pages)
    if n_items ~= nil and n_items < 1 then return nil end
    local mode = self:scrubberLetterMode(kind, pages)
    if not mode then return nil end
    local width = self.width or 0
    local strip_w = Core.scrubberWidth(self:screenDpi())
    local content_w = Core.gridContentWidth(width, strip_w)
    return { mode = mode, width = width - content_w, content_w = content_w }
end

function LibraryView:buildScrubber(items, per_page, mode, width, height, anchor, later_per_page, extra)
    extra = extra or {}
    local index = Core.scrubberIndex(items, per_page, function(item)
        return Core.scrubberItemKey(item, mode)
    end, later_per_page)
    return Scrubber:new{
        view = self,
        index = index,
        anchor = anchor,
        letters = extra.letters,
        side = extra.side,
        width = width,
        height = height,
        dpi = self:screenDpi(),
        screen_w = self.dimen and self.dimen.w or self.width,
        screen_h = self.dimen and self.dimen.h or 0,
        hit_extra = Core.scrubberGutterHit(self:screenDpi()),
        show_parent = self,
    }
end

function LibraryView:eachScrubber()
    if self.scrubbers and #self.scrubbers > 0 then return self.scrubbers end
    if self.scrubber then return { self.scrubber } end
    return {}
end

function LibraryView:scrubberHit(ges)
    local function inside(d, p)
        return d and p and p.x and p.y
            and p.x >= d.x and p.y >= d.y
            and p.x < d.x + d.w and p.y < d.y + d.h
    end
    for _, sc in ipairs(self:eachScrubber()) do
        local hit = (sc.hitRect and sc:hitRect()) or sc.dimen
        if inside(hit, ges and ges.pos) or inside(hit, ges and ges.start_pos) then
            return sc
        end
    end
end

--- True when a gesture began on a letter strip.
function LibraryView:gestureOnScrubber(ges)
    return self:scrubberHit(ges) ~= nil
end

function LibraryView:draggingScrubber()
    for _, sc in ipairs(self:eachScrubber()) do
        if sc._drag then return sc end
    end
end

--- Open Controls when this swipe started in the top-right zone and went
-- downward (including a slight diagonal). Checked before the A–Z strip so
-- a pull from the top of the strip does not jump to a letter.
function LibraryView:tryOpenControls(ges)
    if not (ges and self.plugin and self.plugin.openControls) then return false end
    if not Core.isControlsSwipe(ges.direction) then return false end
    local pos = ges.pos or ges.start_pos
    if not (pos and pos.x and pos.y) then return false end
    if not Core.inControlsCorner(pos.x, pos.y, self.dimen.w, self.dimen.h) then return false end
    if self.plugin:openControls() then
        self:keyboardGuard()
        return true
    end
    return false
end

--- A "tap" that started in the Controls zone and moved downward: open
-- Controls instead of the widget under the finger (Series tab, search, A–Z).
function LibraryView:tryOpenControlsFromTap(ges)
    if not (ges and self.plugin and self.plugin.openControls and self.dimen) then return false end
    local down = self._touch or ges.start_pos
    local up = ges.pos or down
    local tol = Screen and Screen.scaleByDPI and Screen:scaleByDPI(20)
    tol = tonumber(tol) or 20
    if not Core.controlsTapIsSwipe(down, up, self.dimen.w, self.dimen.h, tol) then
        return false
    end
    if self.plugin:openControls() then
        self:keyboardGuard()
        return true
    end
    return false
end

--- Gestures the view itself does not keep go to the file browser underneath
-- (issue #8): UIManager only delivers an event to the topmost widget, so
-- without this the file browser's zones -- LiveLight's edge slides,
-- KOReader's own edge swipes and menu gestures -- never see anything while
-- the Library is showing. The view's own widgets and handlers run first;
-- only what they leave is offered on. A gesture-lock screensaver is left
-- alone so its wake gesture still reaches it.
-- Hold and double-tap in the bottom-left corner belong to the file
-- browser's corner gestures, not to the menu button that sits there.
-- A tap is not in this set: a tap on the button opens the menu (#1).
-- A downward swipe from the top edge is the file browser's top menu
-- (issue #9). It is offered before the grid, the search bar and the A–Z
-- strip, which would otherwise keep it. The Controls panel still wins
-- in its own corner when that panel is switched on.
local CORNER_GESTURE = { hold = true, hold_release = true, double_tap = true }

-- What the letter strip actually handles. A two-finger swipe or a
-- multiswipe that happens to start on the strip is not one of these, so
-- it is still offered to the file browser (issue #9).
local STRIP_GESTURE = {
    tap = true, touch = true, swipe = true,
    pan = true, pan_release = true,
    hold = true, hold_pan = true, hold_release = true,
}

local ROTATION_EVENT = {
    onIterateRotation = true,
    onSwapRotation = true,
    onInvertRotation = true,
    onSetRotationMode = true,
}

function LibraryView:gestureSettings()
    return self.plugin and self.plugin.settings
end

--- "filebrowser" when this library has no gesture menu choice yet.
function LibraryView:gestureChoice(slot)
    local G = package.loaded.librarygestures or Gestures
    if type(G) ~= "table" or type(G.choice) ~= "function" then return "filebrowser" end
    local value = G.choice(self:gestureSettings(), slot)
    if type(value) ~= "string" then return "filebrowser" end
    return value
end

function LibraryView:gestureSlot(ev)
    local G = package.loaded.librarygestures or Gestures
    if type(G) ~= "table" or type(G.slotFor) ~= "function" or not self.dimen then return nil end
    local slot = G.slotFor(ev, self.dimen.w, self.dimen.h)
    if type(slot) ~= "string" then return nil end
    return slot
end

--- Run an action the reader picked for this gesture. True when the gesture
-- is finished with (including "nothing", which does not reach the file browser).
function LibraryView:runLibraryGesture(action, ev)
    local plugin = self.plugin
    if action == "nothing" then return true end
    if action == "show_menu" then
        if Zones.tryMenuSwipe and Zones.tryMenuSwipe(ev) then return true end
        if plugin and plugin.showKoreaderMenu then plugin:showKoreaderMenu(ev) end
        return true
    end
    if action == "rotate_cw" or action == "rotate_ccw" or action == "toggle_orientation" then
        if plugin and plugin.rotateForEvent and Event and Event.new then
            local name = action == "toggle_orientation" and "SwapRotation" or "IterateRotation"
            local arg = action == "rotate_ccw" and true or nil
            plugin:rotateForEvent(Event:new(name, arg))
        end
        return true
    end
    if action == "brightness" then
        local kind = ev and (ev.ges == "pan" or ev.ges == "hold_pan" or ev.ges == "pan_release"
            or ev.ges == "hold_release") and ev.ges or "swipe"
        self:trackEdgeLight(kind, ev, true)
        return true
    end
    if action == "warmth" then
        if Zones.tryLiveZones then Zones.tryLiveZones(ev) end
        return true
    end
    if action == "open_book" then
        if plugin and plugin.onLibraryResume then plugin:onLibraryResume() end
        return true
    end
    if action == "library_menu" then
        if plugin and plugin.showLibraryMenu then plugin:showLibraryMenu(self) end
        return true
    end
    if action == "controls" then
        if plugin and plugin.openControls then plugin:openControls() end
        return true
    end
    if action == "page_next" or action == "page_prev" then
        self:turnPage(action == "page_next" and 1 or -1, true)
        return true
    end
    return false
end

--- A gesture the reader gave their own action, or turned off. False when
-- the choice is still "same as file browser", so the existing path runs.
function LibraryView:libraryGesture(ev)
    local slot = self:gestureSlot(ev)
    if not slot or slot == "other" then return false end
    local choice = self:gestureChoice(slot)
    if choice == "filebrowser" then return false end
    local moving = ev.ges == "pan" or ev.ges == "hold_pan"
        or ev.ges == "pan_release" or ev.ges == "hold_release"
    if moving and choice ~= "nothing" and choice ~= "brightness" and choice ~= "warmth" then
        return false
    end
    return self:runLibraryGesture(choice, ev)
end

--- Unlisted gestures (and "other") are forwarded only while that switch
-- is still "same as file browser". A listed gesture set to something else
-- was already handled.
function LibraryView:forwardSpareGesture(ev)
    local slot = self:gestureSlot(ev)
    if slot and slot ~= "other" and self:gestureChoice(slot) ~= "filebrowser" then
        return false
    end
    if (not slot or slot == "other") and self:gestureChoice("other") == "nothing" then
        return false
    end
    return true
end

function LibraryView:cornerGestureFirst(ev)
    if not (ev and CORNER_GESTURE[ev.ges] and ev.pos and self.dimen) then return false end
    if not Core.inBottomLeftCorner(ev.pos.x, ev.pos.y, self.dimen.w, self.dimen.h) then
        return false
    end
    if self:gestureChoice("hold_bl") == "nothing" then return true end
    return Zones.tryLiveZones(ev) and true or false
end

--- The strip keeps a tap, a one-finger swipe or a drag that started on it.
-- Anything else (a two-finger swipe, a multiswipe) is not the strip's.
function LibraryView:scrubberKeeps(ev)
    return ev and STRIP_GESTURE[ev.ges] and self:gestureOnScrubber(ev) and true or false
end

--- Downward swipe from the top edge: the file browser's top menu, unless
-- the Controls panel is on and the swipe started in its corner.
function LibraryView:topMenuSwipeFirst(ev)
    if not (ev and ev.ges == "swipe" and ev.direction == "south") then return false end
    if self:gestureChoice("top_down") ~= "filebrowser" then return false end
    if self:tryOpenControls(ev) then return true end
    if not Zones.tryMenuSwipe then return false end
    return Zones.tryMenuSwipe(ev) and true or false
end

function LibraryView:handleEvent(event)
    -- The input that just closed a menu is still in this frame. It must
    -- not reach a file-browser zone, and it must not close this view.
    if self._overlay_just_closed and (event.handler == "onGesture" or event.handler == "onClose") then
        return true
    end
    if event.handler == "onGesture" then
        if Device.screen_saver_lock then return false end
        local ev = event.args and event.args[1]
        if ev and self:libraryGesture(ev) then return true end
        if ev and self:cornerGestureFirst(ev) then return true end
        if ev and self:topMenuSwipeFirst(ev) then return true end
        if InputContainer.handleEvent(self, event) then return true end
        -- A one-finger gesture that started on the A–Z strip is never
        -- offered to LiveLight. The strip picks the letter.
        if ev and not self:scrubberKeeps(ev) and self:forwardSpareGesture(ev)
            and Zones.tryLiveZones(ev) then
            return true
        end
        return false
    end
    -- Rotation has to rebuild this view: the file browser turns the screen
    -- and lays itself out again, and leaves the Library at the old size
    -- (issue #9).
    if ROTATION_EVENT[event.handler] and self.plugin and self.plugin.rotateForEvent then
        return self.plugin:rotateForEvent(event) and true or false
    end
    -- A Dispatcher action the view does not handle (a Gestures-plugin
    -- binding fired by the zone walk above, issue #9) goes to the file
    -- browser, which is the widget that can run it.
    if InputContainer.handleEvent(self, event) then return true end
    return Zones.forwardToLive(event, self)
end

function LibraryView:onSwipe(_, ges)
    local drag = self:draggingScrubber()
    if drag then
        local pos = ges and (ges.end_pos or ges.pos)
        if pos then drag._pending = pos end
        drag:endDrag()
        return true
    end
    if self:trackEdgeLight("swipe", ges) then return true end
    if self:tryOpenControls(ges) then return true end
    local hit = self:scrubberHit(ges)
    if hit then
        hit:onSwipeScrubber(nil, ges)
        return true
    end
    -- A horizontal swipe the reader gave their own action in KOReader's
    -- Gestures (top/bottom edge swipes, issue #9) runs that action before
    -- the Library turns its page. Only a configured one fires; anything
    -- else falls through to the page turn below.
    local d = ges and ges.direction
    if d == "west" or d == "east" then
        local slot = self:gestureSlot({ ges = "swipe", direction = d, pos = ges.pos or ges.start_pos })
        local skip = (slot == "top_side" or slot == "bottom_side") and self:gestureChoice(slot) == "nothing"
        if not skip and Zones.tryUserFirst(ges, Zones.liveHost()) then return true end
    end
    -- A vertical slide that this view did not keep is LiveLight's (issue #8).
    -- Warmth on the right edge always comes through here. Brightness on the
    -- left does too, unless Left-edge brightness took the swipe above. The
    -- A–Z strip already took a swipe that started on it. Warmth only sees a
    -- right-edge swipe that started outside the strip (above or below a
    -- short column). If nothing there takes it, the shelf expand below
    -- still runs.
    if (d == "north" or d == "south") and ges.pos and Core.edgeStrip(ges.pos.x, self.dimen.w) then
        local slot = self:gestureSlot({ ges = "swipe", direction = d, pos = ges.pos })
        if self:gestureChoice(slot or "") == "filebrowser" and Zones.tryLiveZones(ges) then return true end
    end
    -- Left is next, right is previous. Up and down are not page turns.
    -- They are still consumed: the file browser under the Library must not
    -- see them, except for an edge-starting slide, which is offered to its
    -- zones above (issue #8). A diagonal that is not the Controls gesture
    -- is left alone (a long diagonal swipe is also how KOReader takes a
    -- screenshot).
    -- A straight up/down swipe expands or restores the shelf (issue #3).
    local turn = Core.libraryPageTurn(ges and ges.direction)
    if not turn then
        if d == "north" or d == "south" then
            self:toggleShelfExpand(d == "north", ges)
            return true
        end
        return false
    end
    self:turnPage(turn, true)
    return true
end

--- Swipe up on the lower library area hides the Continue strip for now
-- (issue #3); swipe down brings it back. Only a real swipe counts: a
-- tap that drifted a little (tapWasSwipe) has no end_pos, so it still
-- opens the book instead of expanding. The swipe must start below the
-- search bar, and expanding only applies while a strip is showing.
--- True when a swipe up has a widget band it can hide. Page 2 of an
-- ordinary turn already uses the full shelf, so it does not. A letter
-- jump must still be able to expand and collapse (#15).
function LibraryView:shelfCanExpand()
    -- The band is on screen: a swipe up hides it, as before.
    if self.continue_books then return true end
    if not self._strip_possible then return false end
    -- Page 1 can show the band. A letter jump can too, even from a later
    -- page, so the gesture is not stranded (#15).
    if self.page == 1 or self._jump_anchor then return true end
    return false
end

function LibraryView:toggleShelfExpand(expand, ges)
    local pos = ges and ges.pos
    if not (ges and ges.end_pos and pos and pos.y) then return false end
    if self.body_y and pos.y < self.body_y then return false end
    if expand then
        if self._shelf_expanded or not self:shelfCanExpand() then return false end
        self._shelf_expanded = true
    else
        if not self._shelf_expanded then return false end
        self._shelf_expanded = nil
    end
    self:refreshBody(true, "shelf")
    return true
end

-- Same cadence as the Controls brightness slider: the first step now,
-- then at most one step every 0.06 s. Nothing here repaints the Library.
LibraryView.EDGE_LIGHT_TICK = 0.06

function LibraryView:powerDevice()
    if not Device.getPowerDevice then return nil end
    local ok, p = pcall(Device.getPowerDevice, Device)
    if not ok or type(p) ~= "table" then return nil end
    if type(p.fl_min) ~= "number" or type(p.fl_max) ~= "number" then return nil end
    if type(p.setIntensity) ~= "function" or type(p.frontlightIntensity) ~= "function" then return nil end
    return p
end

function LibraryView:applyEdgeLevel(level)
    local edge = self._edge
    local p = edge and edge.powerd
    if not p then return end
    -- A Kindle without warmth, or a powerd that throws, must not take the
    -- gesture handler down with it. The light call is the whole update:
    -- nothing here repaints the Library.
    if level <= p.fl_min and type(p.turnOffFrontlight) == "function" then
        pcall(p.turnOffFrontlight, p)
    elseif type(p.setIntensity) == "function" then
        pcall(p.setIntensity, p, level)
        if type(p.isFrontlightOff) == "function" and type(p.turnOnFrontlight) == "function" then
            local ok_off, off = pcall(p.isFrontlightOff, p)
            if ok_off and off then pcall(p.turnOnFrontlight, p) end
        end
    end
    if type(p.updateResumeFrontlightState) == "function" then
        pcall(p.updateResumeFrontlightState, p)
    end
    edge.level = level
    self:paintEdgeLevel(level)
end

function LibraryView:flushEdgeLight()
    local edge = self._edge
    if not edge then return end
    local level = edge.pending
    edge.pending = nil
    if level == nil or level == edge.applied then return end
    edge.applied = level
    self:applyEdgeLevel(level)
end

function LibraryView:queueEdgeLight(level)
    local edge = self._edge
    if not edge then return end
    edge.pending = level
    if edge.tick then return end
    self:flushEdgeLight()
    edge.tick = function()
        if self._edge then self._edge.tick = nil end
        if self._edge and self._edge.pending ~= nil then
            self:queueEdgeLight(self._edge.pending)
        end
    end
    if UIManager.scheduleIn then
        UIManager:scheduleIn(self.EDGE_LIGHT_TICK, edge.tick)
    else
        edge.tick = nil
    end
end

--- A small number, refreshed fast and by itself. The Library is not in
-- the update. Nil when there is no framebuffer to draw on.
function LibraryView:paintEdgeLevel(level)
    local bb = Screen and Screen.bb
    local rect = self._edge_level_rect
    if not rect and self.dimen then
        local w = math.max(48, math.floor((self.dimen.w or 0) * 0.12))
        local h = 48
        rect = {
            x = math.floor(((self.dimen.w or 0) - w) / 2),
            y = math.floor((self.dimen.h or 0) / 8),
            w = w, h = h,
        }
        self._edge_level_rect = rect
    end
    if not rect then return end
    if bb and bb.paintRect then
        pcall(function()
            bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)
            local face = Font:getFace("cfont", 20)
            local widget = TextWidget:new{
                text = tostring(level), face = face, bold = true,
            }
            local sz = widget:getSize()
            widget:paintTo(bb,
                rect.x + math.floor((rect.w - sz.w) / 2),
                rect.y + math.floor((rect.h - sz.h) / 2))
            widget:free()
        end)
    end
    if UIManager.setDirty then
        local g = Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        UIManager:setDirty(nil, function() return "fast", g end)
    end
end

function LibraryView:clearEdgeLevel()
    local rect = self._edge_level_rect
    self._edge_level_rect = nil
    if not rect or not UIManager.setDirty then return end
    local g = Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    UIManager:setDirty(self, function() return "ui", g end)
end

function LibraryView:beginEdgeLight(start_y)
    if self._edge then return true end
    local p = self:powerDevice()
    if not p then return false end
    local ok, level = pcall(p.frontlightIntensity, p)
    if not ok or type(level) ~= "number" then return false end
    self._edge = {
        powerd = p,
        start_y = start_y,
        start_level = level,
        level = level,
        applied = level,
    }
    return true
end

function LibraryView:moveEdgeLight(y)
    local edge = self._edge
    if not edge or not y then return end
    local level = Core.edgeLightLevel(edge.start_y, y, self.dimen and self.dimen.h or 0,
        edge.start_level, edge.powerd.fl_min, edge.powerd.fl_max)
    self:queueEdgeLight(level)
end

function LibraryView:endEdgeLight()
    local edge = self._edge
    if not edge then return false end
    if edge.tick and UIManager.unschedule then UIManager:unschedule(edge.tick) end
    edge.tick = nil
    self:flushEdgeLight()
    self._edge = nil
    self:clearEdgeLevel()
    return true
end

--- Left-edge brightness. True when this gesture is part of that slide.
-- A touch that started on the A–Z strip is not one. The slide starts only
-- when Left-edge brightness is on, or when `anywhere` is set (a gesture
-- slot set to Brightness). A slide already underway still moves and ends.
-- Warmth is not this path: a right-edge swipe falls through to the file
-- browser. No frontlight: false, so those zones still get the gesture.
function LibraryView:trackEdgeLight(kind, ges, anywhere)
    if type(ges) ~= "table" or not self.dimen then return false end
    local start = ges.start_pos or ges.pos
    if self._edge then
        if kind == "pan" or kind == "hold_pan" then
            self:moveEdgeLight(ges.pos and ges.pos.y)
            return true
        end
        if kind == "pan_release" or kind == "hold_release" or kind == "swipe" then
            local y = (ges.end_pos and ges.end_pos.y) or (ges.pos and ges.pos.y)
            self:moveEdgeLight(y)
            self:endEdgeLight()
            return true
        end
        return false
    end
    -- Off (nil or false) does not start a slide. The caller then treats the
    -- gesture as if this handler were not here.
    if not anywhere and not Core.edgeBrightness(self:gestureSettings()) then
        return false
    end
    if not (start and start.x and start.y) then return false end
    if not anywhere and self:gestureOnScrubber({ pos = start, start_pos = start }) then return false end
    if not anywhere and Core.edgeStrip(start.x, self.dimen.w) ~= "left" then return false end
    if kind == "pan" or kind == "hold_pan" then
        local rel = ges.relative
        if rel and math.abs(rel.y or 0) < math.abs(rel.x or 0) then return false end
        if not self:beginEdgeLight(start.y) then return false end
        self:moveEdgeLight(ges.pos and ges.pos.y or start.y)
        return true
    end
    if kind == "swipe" and (ges.direction == "north" or ges.direction == "south") then
        if not self:beginEdgeLight(start.y) then return false end
        local y = (ges.end_pos and ges.end_pos.y) or (ges.pos and ges.pos.y)
        self:moveEdgeLight(y)
        self:endEdgeLight()
        return true
    end
    return false
end

--- A drag that has left the letter strip keeps driving it. When Left-edge
-- brightness is on, a vertical drag that starts on the left edge sets the
-- frontlight directly, the way the Controls brightness slider does, and
-- does not repaint the Library. Off, that drag is left to the gesture.
function LibraryView:onPan(_, ges)
    local drag = self:draggingScrubber()
    if drag then
        drag:dragTo(ges and ges.pos)
        return true
    end
    if self:trackEdgeLight("pan", ges) then return true end
    return false
end

function LibraryView:onHoldPan(_, ges)
    local drag = self:draggingScrubber()
    if drag then
        drag:dragTo(ges and ges.pos)
        return true
    end
    if self:trackEdgeLight("hold_pan", ges) then return true end
    return false
end

function LibraryView:onPanRelease(_, ges)
    if self:trackEdgeLight("pan_release", ges) then return true end
    local drag = self:draggingScrubber()
    if drag then
        drag:endDrag()
        return true
    end
    return false
end

function LibraryView:onHoldRelease(_, ges)
    if self:trackEdgeLight("hold_release", ges) then return true end
    local drag = self:draggingScrubber()
    if drag then
        drag:endDrag()
        return true
    end
    return false
end

--- Remember where a finger went down. Never consumes the event.
function LibraryView:onTouch(_, ges)
    self._touch = ges and ges.pos and { x = ges.pos.x, y = ges.pos.y } or nil
    return false
end

--- A "tap" on a cover that was really a short swipe (or the tail of a page
-- turn) turns the page instead of opening the book. True when handled.
function LibraryView:tapWasSwipe(ges)
    local down = self._touch
    self._touch = nil
    if Core.tapTooSoon(time.to_ms(time.now()), self._turned_ms) then return true end
    local dir = Core.shortSwipe(down, ges and ges.pos, Screen:scaleByDPI(20)) -- under KOReader's 35 dp pan threshold
    if not dir then return false end
    self:onSwipe(nil, { direction = dir, pos = down })
    return true
end

function LibraryView:onTileTap(tile, ges)
    if self:tapWasSwipe(ges) then return end
    self:keyboardGuard()
    if tile.group then
        self:openGroup(tile.group)
    else
        self.plugin:openBook(Core.openPath(tile.book), self)
    end
end

function LibraryView:onResume()
    self:keyboardGuard()
    local book = self.last_book or Core.resumeBook(self.all_books)
    if book then self.plugin:openBook(Core.openPath(book), self) end
end

function LibraryView:setBarelyThreshold(t)
    self.barely_threshold = Core.barelyThreshold(t)
    self.page = 1
    self:refreshBody(true)
end

function LibraryView:onTileHold(tile)
    if Core.longPressAction(tile) ~= "details" then return end
    self:keyboardGuard()
    self.plugin:showBookDetails(tile.book, self)
end

--- Close the card's destination: the Genres, Collections, Series or Authors
-- shelf named `name`. One refresh. Returns true when that shelf exists.
function LibraryView:openNamedShelf(kind, name)
    if kind ~= "genres" and kind ~= "collections" and kind ~= "series" and kind ~= "authors" then
        return false
    end
    self:keyboardGuard()
    self:resetQuery()
    local s = self.plugin.settings
    if kind == "genres" or kind == "collections" then
        self.tab = "collections"
        if s then
            local want = kind == "genres" and "genres" or nil
            if s.collections_view ~= want then
                s.collections_view = want
                if self.plugin.saveSettings then self.plugin:saveSettings() end
            end
        end
    else
        self.tab = kind
    end
    self.group, self.page = nil, 1
    self.groups_cache = {}
    if not self.sorted and self.reloadData then self:reloadData() end
    local groups = self:groupsFor(kind == "genres" and "genres" or self.tab)
    local g = Core.shelfMatch(name, groups, lower)
    if g then
        self.saved_page = 1
        self.group = g
        self.page = 1
    end
    self:updateSearchHint()
    self:applyRemembered()
    self:refreshBody(true, "shelf")
    return g ~= nil
end

function LibraryView:onClose()
    -- Back that already dismissed a dialog (KOReader's menu does not
    -- consume it) would otherwise close the Library and leave the file
    -- browser on screen.
    if self._overlay_just_closed then return true end
    if self.group then
        self:closeGroup()
        return true
    end
    UIManager:close(self)
    return true
end

function LibraryView:dropScrubber(sc)
    if not sc then return end
    if sc.clearBubble then sc:clearBubble() end
    if sc.freeSnap then sc:freeSnap() end
end

function LibraryView:onCloseWidget()
    self._closed = true
    for _, sc in ipairs(self.scrubbers or {}) do
        self:dropScrubber(sc)
    end
    self:dropScrubber(self.scrubber)
    if self.timing then
        for _, name in ipairs({ "page", "filter", "search" }) do self.timing:cancel(name) end
    end
    if self._search_action then UIManager:unschedule(self._search_action) end
    if self._status_tick then UIManager:unschedule(self._status_tick); self._status_tick = nil end
    if self._search_dialog then
        local dialog = self._search_dialog
        self._search_dialog = nil
        UIManager:close(dialog)
    end
    if self._cover_poll then UIManager:unschedule(self._cover_poll) end
    if self._cover_submit then UIManager:unschedule(self._cover_submit) end
    if not self.covers.bim then Covers.cancel() end
    self.cover_cache:clear()
    -- Cover buffers live in C memory the Lua GC does not see: collect now.
    collectgarbage("collect")
    if self.plugin then self.plugin:onViewClosed(self) end
end

--- Where the Library is (tab, open group, page, search), to rebuild it
-- after the screen rotates.
function LibraryView:placeState()
    return {
        tab = self.tab,
        group = self.group and { kind = self.group.kind, name = self.group.name },
        page = self.page,
        query = self.query ~= "" and self.query or nil,
    }
end

function LibraryView:restorePlace(st)
    if st.tab and st.tab ~= self.tab then self:setTab(st.tab) end
    if st.group then
        for _, g in ipairs(self:groupsFor(st.group.kind)) do
            if g.name == st.group.name then self:openGroup(g); break end
        end
    end
    if st.query then
        self.search_input:setText(st.query)
        self:applySearch(st.query)
    end
    if st.page and st.page > 1 then self:goToPage(st.page) end
end

--- Everything needed to come back here after reading `book_path`.
function LibraryView:returnState(book_path)
    return {
        tab = self.tab,
        group = self.group and { kind = self.group.kind, name = self.group.name },
        parent_page = self.saved_page,
        parent_query = self.saved_query,
        page = self.page,
        query = self.query,
        filter = self.filter,
        sort = self.sort,
        view_mode = self.view_mode,
        book = book_path,
        widget_pages = self:widgetPages(),
    }
end

--- Back from a book: the same tab, shelf (Back still leads to its parent at
-- the page it was on), filter, sort, layout and page (clamped if the list
-- got shorter). Search text only if the book came from search results.
function LibraryView:restoreReturn(spot)
    if type(spot) ~= "table" then return false end
    self.tab, self.group, self.page = spot.tab or "books", nil, 1
    self.saved_page, self.saved_query = nil, nil
    self:resetQuery()
    if spot.group then
        for _, g in ipairs(self:groupsFor(self.tab)) do
            if g.name == spot.group.name then
                self.group = g
                self.saved_page = spot.parent_page or 1
                self.saved_query = spot.parent_query
                break
            end
        end
    end
    self:applyRemembered()
    if spot.view_mode then self.view_mode = Core.viewMode(spot.view_mode) end
    if spot.filter then self.filter = spot.filter end
    if spot.sort and spot.sort ~= self.sort then
        self.sort = spot.sort
        self:reloadData()
        self:reresolveGroup()
    end
    if spot.query then
        self.query = spot.query
        if self.search_input then self.search_input:setText(spot.query) end
    end
    if type(spot.widget_pages) == "table" then
        self._widget_pages = spot.widget_pages
        local settings = self.plugin and self.plugin.settings
        if type(settings) == "table" then settings.widget_pages = spot.widget_pages end
    end
    self.page = spot.page or 1 -- buildBody clamps it to the pages there are
    self:updateSearchHint()
    self:refreshBody(true)
    return true
end

--- After a book's status or metadata changed.
function LibraryView:refreshData()
    self:reloadData()
    self:reresolveGroup()
    self:refreshBody(true)
end

--- The footer's sort label was tapped: Author, Author then year, Title, Date added, Last read, Series.
function LibraryView:showSortPicker()
    self:keyboardGuard()
    self.plugin:showSortPicker(self)
end

--- The footer's "63 / 72" was tapped: ask for a page number.
function LibraryView:showPageJump()
    if not self.pages or self.pages < 2 then return end
    self:keyboardGuard()
    self.plugin:showPageJump(self)
end

function LibraryView:resort(mode)
    self.sort = mode
    self:rememberPref("sort", mode)
    self:reloadData()
    self:reresolveGroup()
    self.page = 1
    self:refreshBody(true)
end

function LibraryView:setViewMode(mode)
    self.view_mode = Core.viewMode(mode)
    self:rememberPref("view", self.view_mode)
    self.page = 1
    self:refreshBody(true)
end

--- Footer size control: one step smaller, then wrap from small back to
-- large. The layout stays whatever it was (#13). Hold opens the picker.
function LibraryView:cycleCoverSize()
    local cols = Core.nextColumns(self.cols)
    if self.plugin and self.plugin.settings then
        self.plugin.settings.columns = cols
        if self.plugin.saveSettings then self.plugin:saveSettings() end
    end
    self.cols = cols
    if self.cover_cache and self.cover_cache.clear then self.cover_cache:clear() end
    self.page = 1
    self:refreshBody(true)
end

--- Footer layout control: cover grid, list, two-column list. The cover
-- size is left alone (#13). Hold opens the picker.
function LibraryView:cycleViewMode()
    local settings = self.plugin and self.plugin.settings
    self:setViewMode(Core.nextViewMode(self.view_mode, Core.layoutButton(settings)))
end

function LibraryView:setLayoutButton(mode)
    self.layout_button = Core.layoutButton({ layout_button = mode })
    if self.plugin and self.plugin.settings then
        self.plugin.settings.layout_button = self.layout_button
    end
end

function LibraryView:setFilterExpands(on)
    self.filter_expands = on ~= false
    self:refreshBody(true)
end

function LibraryView:setWidgetCovers(mode)
    self.widget_covers = mode == "fill" and "fill" or "compact"
    self:refreshBody(true)
end

function LibraryView:setAzLayout(mode)
    self.az_layout = Core.azLayout({ az_layout = mode })
    self:refreshBody(true)
end

function LibraryView:setLetterKeepsShelf(on)
    self.letter_keeps_shelf = on == true
end

function LibraryView:setTabRow(pos)
    self.tab_row = Core.tabRow(pos)
    self:refreshBody(true)
end

function LibraryView:setShowContinue(on)
    self.show_continue = on and true or false
    self.page = 1
    self:refreshBody(true)
end

function LibraryView:setTopRow(mode)
    self.top_row = Core.topRow(mode)
    self.page = 1
    self:refreshBody(true)
end

function LibraryView:setColumns(cols)
    self.cols = cols
    self.cover_cache:clear()
    self.page = 1
    self:refreshBody(true)
end

----------------------------------------------------------------------------
-- Covers not extracted yet
----------------------------------------------------------------------------

function LibraryView:scheduleCoverExtraction()
    if not self.missing_covers then return end
    if self.covers.bim then return self:scheduleBIMExtraction() end
    return self:scheduleBuiltinExtraction()
end

--- Built-in covers: queue the visible books first, then the rest of the
-- current list, and redraw when a visible cover lands.
function LibraryView:scheduleBuiltinExtraction()
    local store = self.covers.store
    self.pending_covers = self.missing_covers
    if #self.pending_covers == 0 and Covers.isRunning() then return end
    local rest = {}
    for _, b in ipairs(self.continue_books or {}) do rest[#rest + 1] = b end
    for _, it in ipairs(self.current and self.current.items or {}) do
        local b = it.path and it or it.cover_book
        if b then rest[#rest + 1] = b end
    end
    local items = Covers.order(self.pending_covers, rest, function(b) return store:state(b) ~= nil end)
    if #items == 0 then return end
    -- Same work at the head of the queue as last time: nothing to rewrite.
    local sig = items[1].key .. "|" .. #items
    if sig == self._cover_sig and Covers.isRunning() then return end
    self._cover_sig = sig
    -- After the first paint, so opening the Library is not slowed by the fork.
    if self._cover_submit then UIManager:unschedule(self._cover_submit) end
    self._cover_submit = function()
        self._cover_submit = nil
        Covers.submit(items, function(done) self:onCoversProgress(done) end)
    end
    UIManager:nextTick(self._cover_submit)
end

--- Called by the background job while it runs: redraw if a visible cover is ready.
function LibraryView:onCoversProgress(done)
    local landed = false
    for _, b in ipairs(self.pending_covers or {}) do
        if self.covers.store:refresh(b) then landed = true end
    end
    if landed then
        self.timings.covers_landed = (self.timings.covers_landed or 0) + 1
        self:refreshBody()
    elseif done then
        self._cover_sig = nil
    end
end

--- Project: Title or Cover browser loaded: let its BookInfoManager extract
-- into its database, as before.
function LibraryView:scheduleBIMExtraction()
    local bim = self.covers.bim
    if #self.missing_covers == 0 then return end
    if self._cover_poll then return end -- a job is already running for an earlier page
    local files = {}
    for _, b in ipairs(self.missing_covers) do
        table.insert(files, { filepath = b.path, cover_specs = { max_cover_w = 600, max_cover_h = 600 } })
    end
    UIManager:nextTick(function()
        local ok, launched = pcall(bim.extractInBackground, bim, files)
        if not ok or not launched then return end
        local polls = 0
        self._cover_poll = function()
            polls = polls + 1
            local running = bim:isExtractingInBackground()
            if not running or polls % 5 == 0 then
                -- drop "not found" results and redraw the grid with the new covers
                self:refreshBody()
            end
            if running and polls < 120 then
                UIManager:scheduleIn(1, self._cover_poll)
            else
                self._cover_poll = nil
            end
        end
        UIManager:scheduleIn(1, self._cover_poll)
    end)
end

return LibraryView
