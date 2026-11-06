--[[--
Full-screen Library view.

Layout, top to bottom:

    header           search bar, and beside it the clock and battery when those
                     are on. No "Library" title: that row is the books'.
    tabs             Books | Collections | Authors | Series
    status chips     All | Unread | Reading | Barely started | Finished
    continue reading (Books tab, no search or filter:
                     the books in progress, with percent and last-read time)
    cover grid or list   an A–Z strip on the right when sorted by title, author or series
    footer           menu, Resume, page x of y, sort
                     (in a series: "2 of 5 read")

Inside a series the books are in series order and numbered ("3 · Title").
Paging past the last page (swipe or page key) opens the next series, and
before the first page the previous one, so a whole shelf of series can be
flipped through without going back to the list. A long-press on a page
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
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local time = require("ui/time")
local util = require("util")
local Core = require("librarycore")
local Scrubber = require("libraryscrubber")
local Tiles = require("librarytile")
local Covers = require("librarycovers")
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
    view_mode = "grid",     -- "grid" | "list" | "compact" | "compact2"
    show_continue = true,   -- the Continue reading strip on the Books tab
    top_row = "continue",   -- what that strip shows: "continue" | "recent" (Recently opened)
    continue_slots = 5,
    barely_threshold = 0.10, -- "Barely started" when chapters are unknown: below this fraction
    rounded_keyboard = true, -- "Rounded keyboard in search"
    fuzzy_search = true,     -- "Typo-tolerant search"
    show_clock = true,       -- clock beside the search bar
    show_battery = true,     -- battery percentage beside the search bar
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
    self.ges_events = { TapArea = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
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

----------------------------------------------------------------------------
-- Header: search bar, with the clock and battery beside it
----------------------------------------------------------------------------

function LibraryView:buildChrome()
    self:buildSearchRow()
    self:scheduleStatusRefresh()
end

--- Long-press on the Resume button: which book it opens.
function LibraryView:showResumeHint()
    local book = self.last_book
    if not book then return end
    local pct = Core.percentText(book.percent)
    UIManager:show(InfoMessage:new{
        text = T(_("Resume: %1"), book.title or book.name) .. (pct and ("  ·  " .. pct) or ""),
        timeout = 2,
    })
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
    local input_w = field_w - 2 * border - 2 * hpad - magnifier:getSize().w - clear:getSize().w - 2 * Size.padding.default
    if self.search_input then
        text = text or self.search_input:getText()
        self.search_input:onCloseWidget() -- frees its keyboard
    end
    self._search_hint = self:searchHint()
    self.search_input = SearchInput:new{
        text = text or "",
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
            HorizontalGroup:new{
                align = "center",
                magnifier,
                HorizontalSpan:new{ width = Size.padding.default },
                self.search_input,
                HorizontalSpan:new{ width = Size.padding.default },
                clear,
            },
        },
    }
    self:assembleHeader()
end

--- Width reserved for the clock and battery, from a wide sample so "9:59"
-- becoming "10:00" does not move the search bar.
function LibraryView:measureStatusSlot()
    if not (self.show_clock or self.show_battery) then return 0 end
    -- Wide digits, so the field does not jump at 10:00. Battery width is reserved
    -- only when this device actually reports a percentage.
    local clock = self.show_clock and (self:twelveHour() and "88:88 PM" or "88:88") or nil
    local battery = (self.show_battery and self:readBattery()) and "100%" or nil
    local sample = Core.statusLabel(clock, battery)
    if not sample then return 0 end
    local face = self._status_face or Font:getFace("cfont", 20)
    local t = TextWidget:new{ text = sample, face = face, bold = true }
    local w = t:getSize().w
    if t.free then t:free() end
    return w
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

function LibraryView:readBattery()
    if not self.show_battery then return nil end
    if type(Device) ~= "table" or type(Device.hasBattery) ~= "function" then return nil end
    local ok, has = pcall(Device.hasBattery, Device)
    if not ok or not has or type(Device.getPowerDevice) ~= "function" then return nil end
    local okd, powerd = pcall(Device.getPowerDevice, Device)
    if not okd or type(powerd) ~= "table" or type(powerd.getCapacity) ~= "function" then return nil end
    local okc, cap = pcall(powerd.getCapacity, powerd)
    if not okc then return nil end
    return Core.batteryLabel(cap)
end

function LibraryView:buildStatusWidget()
    self.status_label = nil
    self.status_box = nil
    if not (self.show_clock or self.show_battery) then
        self._status_text = nil
        return nil
    end
    local face = self._status_face or Font:getFace("cfont", 20)
    local battery = self:readBattery()
    self._status_has_battery = battery ~= nil
    local text = Core.statusLabel(self:readClock(), battery) or ""
    self._status_text = text
    local label = TextWidget:new{ text = text, face = face, bold = true }
    local slot_w = self._status_slot_w or label:getSize().w
    local slot_h = self.search_field and self.search_field:getSize().h or label:getSize().h
    self.status_label = label
    self.status_box = RightContainer:new{
        dimen = Geom:new{ w = slot_w, h = slot_h },
        label,
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

--- Swap the clock and battery text. Does not repaint.
function LibraryView:updateStatusText()
    if not self.status_label or type(self.status_label.setText) ~= "function" then return false end
    local text = Core.statusLabel(self:readClock(), self:readBattery()) or ""
    if text == self._status_text then return false end
    self._status_text = text
    self.status_label:setText(text)
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

function LibraryView:onStatusTick()
    -- A battery that appears or disappears changes the search bar's width.
    local has_battery = (self.show_battery and self:readBattery() ~= nil) and true or false
    if self.search_field and has_battery ~= (self._status_has_battery and true or false)
            and not (self.search_input and self.search_input.isKeyboardVisible
                and self.search_input:isKeyboardVisible()) then
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

local FILTER_SHORT = { barely = _("Barely") }
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

function LibraryView:buildChips(counts)
    local margin = Size.margin.default + Size.padding.default
    local gap = Size.padding.default
    local avail = self.width - 2 * margin
    -- Narrow screens: drop the counts of unselected filters, then shorten names.
    local row
    for compact = 0, 2 do
        row = HorizontalGroup:new{ align = "center" }
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
            local selected = self.filter == f
            local text = (compact >= 2 and FILTER_SHORT[f]) or FILTER_NAMES[f]
            if counts and (compact == 0 or selected) then text = text .. " " .. (counts[f] or 0) end
            table.insert(row, Tiles.Chip:new{
                text = text,
                selected = selected,
                callback = function() self:setFilter(f) end,
                show_parent = self,
            })
        end
        if row:getSize().w <= avail then break end
    end
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
    -- Page arrows are real buttons, as well as swipes. A tap moves one page.
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
    -- Menu and Resume live here, not in the top corners: those are hard to hit on e-ink.
    -- Same thumb-sized target as the page arrows. Resume stays put, dimmed, with no book.
    local chrome_icon = Screen:scaleBySize(22)
    local chrome_pad = math.max(0, math.floor((touch - chrome_icon) / 2))
    local function chromeButton(item)
        local enabled = item.enabled ~= false
        local callback, hold
        if item.id == "menu" then
            callback = function() self:onLeftIcon() end
            hold = callback
        else
            callback = function() if self.last_book then self:onResume() end end
            hold = function() if self.last_book then self:showResumeHint() end end
        end
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
    local menu_btn, resume_btn
    for _, item in ipairs(Core.footerChrome(self.last_book ~= nil)) do
        local btn = chromeButton(item)
        if item.id == "menu" then menu_btn = btn else resume_btn = btn end
    end
    self.footer_menu, self.footer_resume = menu_btn, resume_btn
    local button_gap = Size.padding.small
    local buttons_w = menu_btn:getSize().w + button_gap + resume_btn:getSize().w + Size.padding.default
    -- "202 books · Last read ▾": tap it to pick the sort (books only; a
    -- series keeps its reading order).
    local sortable = kind == "books" and not self:inSeries()
    if sortable then left = left .. " \u{25BE}" end
    local max_text = math.max(Screen:scaleBySize(72),
        self.width - 2 * margin - buttons_w - pager:getSize().w - Size.padding.default)
    local text = TextWidget:new{ text = left, face = f, fgcolor = Blitbuffer.COLOR_GRAY_4, max_width = max_text }
    self.sort_label = nil
    if sortable then
        text = TapArea:new{ min_h = touch, callback = function() self:showSortPicker() end, text }
        self.sort_label = text
    end
    local h = math.max(text:getSize().h, pager:getSize().h, menu_btn:getSize().h)
    local spacer = self.width - 2 * margin - buttons_w - text:getSize().w - pager:getSize().w
    return FrameContainer:new{
        padding = 0,
        padding_left = margin,
        bordersize = 0,
        width = self.width,
        height = h,
        HorizontalGroup:new{
            align = "center",
            menu_btn,
            HorizontalSpan:new{ width = button_gap },
            resume_btn,
            HorizontalSpan:new{ width = Size.padding.default },
            text,
            HorizontalSpan:new{ width = math.max(Size.padding.small, spacer) },
            pager,
        },
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
                author_first = kind == "books" and self.sort == "author",
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
function LibraryView:buildContinueHeader()
    local f = Font:getFace("cfont", 17)
    local heading = Core.topRow(self.top_row) == "recent" and _("Recently opened") or _("Continue reading")
    local label = TextWidget:new{ text = heading, face = f, bold = true }
    local row = HorizontalGroup:new{ align = "center", label }
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
    local fixed = header_h + Size.padding.small
        + tabs:getSize().h + (chips and chips:getSize().h or 0) + sep:getSize().h
        + footer_probe:getSize().h
    local keyboard_h = self:keyboardHeight()
    -- Word suggestions: a row right above the keyboard, kept while it is up
    -- (empty when there is nothing to suggest) so the grid does not jump.
    local suggest_row = keyboard_h > 0 and self.search_suggestions and self:buildSuggestions() or nil
    if suggest_row then fixed = fixed + suggest_row:getSize().h end
    local grid_h = math.max(self.label_h + 20, self.dimen.h - fixed - keyboard_h)

    -- Continue reading / Recently opened: shown only on page 1 of the Books
    -- tab (no search, no filter, no group). Later pages use the full body
    -- so more books fit. Compact and two-column Compact never show the
    -- strip. Books already in the strip stay out of the paged rows on
    -- every page so a title never appears twice.
    local strip
    self.continue_tiles = nil
    self.continue_books = nil
    local continue_books, continue_layout
    local full_h = grid_h
    if data.kind == "books" and not Core.isCompact(self.view_mode) and Core.showContinue{
            enabled = self.show_continue, tab = self.tab, group = self.group,
            query = self.query, filter = self.filter, keyboard = keyboard_h > 0 } then
        local cbooks = Core.topRowBooks(self.top_row, self.all_books, self.continue_slots, fileExists)
        local min_rest = self.view_mode == "list" and 3 * self.list_row_h or (self.label_h + 100)
        local cl = Core.continueLayout(self.width, full_h, #cbooks, self.continue_label_h,
            self:continueHeaderHeight(), self.gap, { slots = self.continue_slots, min_rest = min_rest, frac = 0.3 })
        if cl then
            continue_books = cbooks
            continue_layout = cl
        end
    end

    -- The A–Z strip takes a slice of the width, so covers are laid out in
    -- what remains and never slide under it. Date and progress sorts leave
    -- the grid full width (no strip).
    local letter_mode = (#data.items > 0) and Core.scrubberMode{
        enabled = self:scrubberEnabled(),
        kind = data.kind,
        sort = self.sort,
        in_series = self:inSeries(),
        tab = self.group and self.group.kind or self.tab,
    } or nil
    local grid_w, letter_w = self.width, 0
    if letter_mode then
        letter_w = Core.scrubberWidth(self:screenDpi())
        grid_w = Core.gridContentWidth(self.width, letter_w)
        letter_w = self.width - grid_w
    end

    local function layoutFor(h, under_strip)
        if Core.isCompact(self.view_mode) then
            local layout = Core.listLayout(h, Tiles.compactRowHeight(), 0, { max_rows = 40 })
            local ncols = Core.listColumns(self.view_mode)
            layout.cols, layout.per_page = ncols, layout.rows * ncols
            return layout
        elseif Core.textRows(self.view_mode, data.kind, self.tab) then
            -- Authors: one line per row; Series: the name over its authors.
            return Core.listLayout(h, Tiles.textRowHeight(self.tab == "series" and 2 or 1), 0, { max_rows = 24 })
        elseif self.view_mode == "list" then
            return Core.listLayout(h, self.list_row_h, Size.padding.small, { max_rows = 10 })
        else
            -- Under the Continue reading strip, accept smaller covers for a second row.
            return Core.gridLayout(grid_w, h, self.cols, self.label_h, self.gap, under_strip and 0.6 or nil)
        end
    end

    local later_layout = layoutFor(full_h, false)
    local page1_h = continue_layout and (full_h - continue_layout.height) or full_h
    local page1_layout = continue_layout and layoutFor(page1_h, true) or later_layout
    local first_per, later_per = page1_layout.per_page, later_layout.per_page

    -- Books in the strip appear only there (page 1), so leave them out of
    -- the paged rows on every page: each title is on screen once. The
    -- footer still counts all books.
    local grid_items = continue_books and Core.withoutShown(data.items, continue_books) or data.items
    local page_items, page, pages = Core.page(grid_items, first_per, self.page, later_per)
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

    local strip_widget = strip and self:buildContinue(self.continue_books, strip)
    local continue_missing = self.missing_covers
    local grid
    if self.view_mode == "list" or Core.isCompact(self.view_mode) then
        grid = self:buildList(page_items, data.kind, layout, grid_h, grid_w)
    else
        grid = self:buildGrid(page_items, data.kind, layout, grid_h, grid_w)
    end
    if self.scrubber and self.scrubber.freeSnap then self.scrubber:freeSnap() end
    self.scrubber = nil
    if letter_mode and letter_w > 0 then
        local anchor_item = page_items[1]
        local anchor = anchor_item and Core.scrubberBucket(Core.scrubberItemKey(anchor_item, letter_mode)) or nil
        self.scrubber = self:buildScrubber(grid_items, first_per, letter_mode, letter_w, grid_h, anchor, later_per)
        grid = HorizontalGroup:new{ align = "top", grid, self.scrubber }
    end
    for _, p in ipairs(continue_missing) do table.insert(self.missing_covers, p) end
    local footer = self:buildFooter(page, pages, #data.items, data.kind)

    self.body = VerticalGroup:new{ align = "left", tabs }
    if chips then table.insert(self.body, chips) end
    table.insert(self.body, sep)
    if strip_widget then
        table.insert(self.body, strip_widget)
    end
    table.insert(self.body, grid)
    table.insert(self.body, footer)
    if suggest_row then table.insert(self.body, suggest_row) end

    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.dimen.w,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            self.header,
            VerticalSpan:new{ width = Size.padding.small },
            self.body,
        },
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

--- One flashing refresh of the Library after an overlay closes, when
-- the cover grid is showing. No rebuild.
function LibraryView:flashOverlay()
    local mode = self:refreshMode("overlay")
    if mode ~= "flashui" or not UIManager.setDirty then return end
    UIManager:setDirty(self, function()
        return mode, self.dimen, true
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
    self:refreshBody()
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
        UIManager:close(dialog)
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
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function LibraryView:setUseKoreaderKeyboard(on)
    on = on and true or false
    if on == (self.use_koreader_keyboard and true or false) then return end
    self:keyboardGuard()
    if self._search_dialog then
        local dialog = self._search_dialog
        self._search_dialog = nil
        UIManager:close(dialog)
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
    local target = self.page + dir
    if target >= 1 and target <= self.pages then return self:goToPage(target) end
    if self:inSeries() and self:stepSeries(dir) then return end
    if wrap then self:goToPage(dir > 0 and 1 or self.pages) end
end

function LibraryView:goToPage(page)
    if not self.pages then return end
    page = math.max(1, math.min(page, self.pages))
    if page == self.page then return end
    self:timeStart("page", true)
    self.page = page
    self._turned_ms = time.to_ms(time.now())
    self:refreshBody(nil, "page")
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

--- Nil when this list should not show the strip. Otherwise the mode, the
-- reserved width and the width left for the covers.
function LibraryView:scrubberPlan(kind, n_items)
    if n_items ~= nil and n_items < 1 then return nil end
    local mode = Core.scrubberMode({
        enabled = self:scrubberEnabled(),
        kind = kind or "books",
        sort = self.sort,
        in_series = self.inSeries and self:inSeries() or false,
        tab = self.group and self.group.kind or self.tab,
    })
    if not mode then return nil end
    local width = self.width or 0
    local strip_w = Core.scrubberWidth(self:screenDpi())
    local content_w = Core.gridContentWidth(width, strip_w)
    return { mode = mode, width = width - content_w, content_w = content_w }
end

function LibraryView:buildScrubber(items, per_page, mode, width, height, anchor, later_per_page)
    local index = Core.scrubberIndex(items, per_page, function(item)
        return Core.scrubberItemKey(item, mode)
    end, later_per_page)
    return Scrubber:new{
        view = self,
        index = index,
        anchor = anchor,
        width = width,
        height = height,
        dpi = self:screenDpi(),
        screen_w = self.dimen and self.dimen.w or self.width,
        screen_h = self.dimen and self.dimen.h or 0,
        show_parent = self,
    }
end

--- True when a gesture began on the letter strip.
function LibraryView:gestureOnScrubber(ges)
    local d = self.scrubber and self.scrubber.dimen
    if not d or not ges then return false end
    local function inside(p)
        return p and p.x and p.y
            and p.x >= d.x and p.y >= d.y
            and p.x < d.x + d.w and p.y < d.y + d.h
    end
    return inside(ges.pos) or inside(ges.start_pos)
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

function LibraryView:onSwipe(_, ges)
    if self.scrubber and self.scrubber._drag then
        local pos = ges and (ges.end_pos or ges.pos)
        if pos then self.scrubber._pending = pos end
        self.scrubber:endDrag()
        return true
    end
    if self:tryOpenControls(ges) then return true end
    if self.scrubber and self:gestureOnScrubber(ges) then
        self.scrubber:onSwipeScrubber(nil, ges)
        return true
    end
    local dir = ges.direction
    if dir == "west" or dir == "north" then
        self:turnPage(1, true)
    elseif dir == "east" or dir == "south" then
        self:turnPage(-1, true)
    else
        return false
    end
    return true
end

--- A drag that has left the letter strip keeps driving it. Anywhere else, a
-- pan is not a page turn.
function LibraryView:onPan(_, ges)
    if self.scrubber and self.scrubber._drag then
        self.scrubber:dragTo(ges and ges.pos)
        return true
    end
    return false
end

function LibraryView:onHoldPan(_, ges)
    if self.scrubber and self.scrubber._drag then
        self.scrubber:dragTo(ges and ges.pos)
        return true
    end
    return false
end

function LibraryView:onPanRelease()
    if self.scrubber and self.scrubber._drag then
        self.scrubber:endDrag()
        return true
    end
    return false
end

function LibraryView:onHoldRelease()
    if self.scrubber and self.scrubber._drag then
        self.scrubber:endDrag()
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
        self.plugin:openBook(tile.book.path, self)
    end
end

function LibraryView:onResume()
    self:keyboardGuard()
    local book = self.last_book or Core.resumeBook(self.all_books)
    if book then self.plugin:openBook(book.path, self) end
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
    if self.group then
        self:closeGroup()
        return true
    end
    UIManager:close(self)
    return true
end

function LibraryView:onCloseWidget()
    self._closed = true
    if self.scrubber and self.scrubber.freeSnap then self.scrubber:freeSnap() end
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

--- The footer's sort label was tapped: Author, Title, Date added, Last read, Series.
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
