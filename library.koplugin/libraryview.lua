--[[--
Full-screen Library view.

Layout, top to bottom:

    title bar        (menu, title, close -> file browser)
    search bar       (always visible InputText; filters as you type)
    tabs             Books | Collections | Authors | Series
    status chips     All | Unread | Reading | Finished
    cover grid
    footer           page x of y, sort

The search bar is a real InputText embedded in this widget, not a popup:
tapping it shows the on-screen keyboard and every keystroke re-filters the
in-memory index (debounced). Only the region below the search bar is
refreshed, so the keyboard and the text field are not redrawn.
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
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local time = require("ui/time")
local util = require("util")
local Core = require("librarycore")
local Tiles = require("librarytile")
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
}

local function lower(s) return util.stringLower and util.stringLower(s) or s:lower() end
LibraryView.lower = lower

function LibraryView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.width = self.dimen.w
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    self.cover_cache = Tiles.newCoverCache(self.cols * 6 * 3)
    self.query = ""
    self.page = 1
    self.group = nil         -- { kind=, name=, books= } when inside a collection/author/series
    self.timings = {}
    self.label_h = Tiles.labelHeight()
    self.gap = Size.padding.default

    self:buildChrome()
    self:reloadData()
    self:buildBody()
end

----------------------------------------------------------------------------
-- Static parts: title bar and search bar
----------------------------------------------------------------------------

function LibraryView:buildChrome()
    self.title_bar = TitleBar:new{
        width = self.width,
        fullscreen = true,
        align = "center",
        title = _("Library"),
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:onLeftIcon() end,
        left_icon_hold_callback = function() self.plugin:showLibraryMenu(self) end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local margin = Size.margin.default
    local icon_size = Screen:scaleBySize(32)
    local clear = IconButton:new{
        icon = "close",
        width = icon_size,
        height = icon_size,
        padding = Size.padding.small,
        callback = function() self:clearSearch() end,
        show_parent = self,
    }
    local avail_w = self.width - 2 * margin - clear:getSize().w - Size.padding.default
    -- InputText adds its own border/padding around `width`: measure and fit.
    local probe = InputText:new{ text = "", width = avail_w, face = Font:getFace("smallinfofont"), scroll = false }
    local input_w = avail_w - (probe:getSize().w - avail_w)
    probe:free()
    self.search_input = InputText:new{
        text = "",
        hint = _("Search title, author, series"),
        width = input_w,
        face = Font:getFace("smallinfofont"),
        focused = false,
        scroll = false,
        parent = self,
        edit_callback = function(edited)
            if edited then self:onSearchEdited() end
        end,
        enter_callback = function() self:closeKeyboard() end,
    }
    self.search_row = FrameContainer:new{
        padding = 0,
        padding_left = margin,
        padding_right = margin,
        bordersize = 0,
        HorizontalGroup:new{
            align = "center",
            self.search_input,
            HorizontalSpan:new{ width = Size.padding.default },
            clear,
        },
    }
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
end

function LibraryView:groupsFor(tab)
    if self.groups_cache[tab] then return self.groups_cache[tab] end
    local groups
    if tab == "collections" then
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
                table.sort(g.books, function(a, b)
                    return (a.series_index or math.huge) < (b.series_index or math.huge)
                end)
            end
        end
    end
    for _, g in ipairs(groups) do g.cover_book = g.cover_book or g.books[1] end
    self.groups_cache[tab] = groups
    return groups
end

--- Books matching the query (narrowing previous results while typing).
function LibraryView:searchBooks(base)
    if self.query == "" then return base end
    local previous
    if self.last_base == base and Core.isRefinement(self.last_query, self.query) then
        previous = self.last_results
    end
    local results = Core.searchIndexed(base, self.query, lower, previous)
    self.last_base, self.last_query, self.last_results = base, self.query, results
    return results
end

--- What the grid should show now: { kind = "books"|"groups", items = {...}, counts = }.
function LibraryView:currentItems()
    if self.group then
        local books = self:searchBooks(self.group.books)
        return { kind = "books", items = Core.filterStatus(books, self.filter), counts = Core.countFilters(books) }
    end
    if self.tab == "books" or self.query ~= "" then
        local books = self:searchBooks(self.sorted)
        return { kind = "books", items = Core.filterStatus(books, self.filter), counts = Core.countFilters(books) }
    end
    return { kind = "groups", items = self:groupsFor(self.tab) }
end

----------------------------------------------------------------------------
-- Body: tabs, chips, grid, footer
----------------------------------------------------------------------------

function LibraryView:keyboardHeight()
    if self.search_input:isKeyboardVisible() and self.search_input.keyboard then
        local kb = self.search_input.keyboard
        return (kb.dimen and kb.dimen.h) or kb:getSize().h
    end
    return 0
end

function LibraryView:buildTabs()
    local row = HorizontalGroup:new{ align = "center" }
    local w = math.floor((self.width - 2 * Size.margin.default - (#TABS - 1) * Size.padding.small) / #TABS)
    for i, tab in ipairs(TABS) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = Size.padding.small }) end
        table.insert(row, Tiles.Chip:new{
            text = tab.text,
            width = w,
            selected = (self.group == nil and self.query == "" and self.tab == tab.id)
                or (self.query ~= "" and tab.id == "books" and self.group == nil),
            callback = function() self:setTab(tab.id) end,
        })
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = row:getSize().h + Size.padding.small },
        row,
    }
end

function LibraryView:buildChips(counts)
    local row = HorizontalGroup:new{ align = "center" }
    if self.group then
        table.insert(row, Tiles.Chip:new{
            text = "\u{2190} " .. self.group.name,
            callback = function() self:closeGroup() end,
        })
        table.insert(row, HorizontalSpan:new{ width = Size.padding.large })
    end
    for i, f in ipairs(Core.FILTERS) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = Size.padding.small }) end
        local text = FILTER_NAMES[f]
        if counts then text = text .. " " .. (counts[f] or 0) end
        table.insert(row, Tiles.Chip:new{
            text = text,
            selected = self.filter == f,
            callback = function() self:setFilter(f) end,
        })
    end
    -- keep the row within the screen if a long group name is shown
    return FrameContainer:new{
        padding = 0,
        padding_left = Size.margin.default,
        bordersize = 0,
        width = self.width,
        height = row:getSize().h + Size.padding.small,
        row,
    }
end

function LibraryView:buildFooter(page, pages, total, kind)
    local f = Font:getFace("cfont", 15)
    local left = kind == "books" and T(_("%1 books · %2"), total, self.plugin:sortName(self.sort))
        or T(_("%1 groups"), total)
    local text = TextWidget:new{ text = left, face = f, fgcolor = Blitbuffer.COLOR_GRAY_3 }
    local pager = TextWidget:new{ text = T(_("‹  %1 / %2  ›"), page, pages), face = f, bold = true }
    local h = math.max(text:getSize().h, pager:getSize().h) + Size.padding.small
    local spacer = self.width - 2 * Size.margin.default - text:getSize().w - pager:getSize().w
    return FrameContainer:new{
        padding = 0,
        padding_left = Size.margin.default,
        bordersize = 0,
        width = self.width,
        height = h,
        HorizontalGroup:new{ align = "center", text, HorizontalSpan:new{ width = math.max(0, spacer) }, pager },
    }
end

function LibraryView:buildGrid(items, kind, layout, height)
    local grid = VerticalGroup:new{ align = "left" }
    self.tiles = {}
    self.missing_covers = {}
    -- Spread spare height between rows (same spacing on every page).
    local vgap = math.max(self.gap,
        math.floor((height - layout.rows * layout.tile_h) / (layout.rows + 1)))
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
                bim = self.plugin:getBIM(),
                cover_cache = self.cover_cache,
                on_tap = function(t) self:onTileTap(t) end,
                on_hold = function(t) self:onTileHold(t) end,
            }
            if tile.needs_cover then
                local b = tile.book or (tile.group and tile.group.cover_book)
                if b then table.insert(self.missing_covers, b.path) end
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
            dimen = Geom:new{ w = self.width, h = math.floor(height / 2) },
            TextWidget:new{ text = msg, face = Font:getFace("infofont") },
        }
    end
    -- Fixed height, so the footer stays at the bottom however many rows there are.
    return TopContainer:new{
        dimen = Geom:new{ w = self.width, h = height },
        grid,
    }
end

--- Rebuild everything below the search bar.
function LibraryView:buildBody()
    local t0 = time.now()
    local data = self:currentItems()
    local t1 = time.now()

    local tabs = self:buildTabs()
    local chips = data.kind == "books" and self:buildChips(data.counts) or nil
    local sep = LineWidget:new{
        background = Blitbuffer.COLOR_GRAY_9,
        dimen = Geom:new{ w = self.width, h = Size.line.thin },
    }
    local footer_probe = self:buildFooter(1, 1, 0, data.kind)
    local fixed = self.title_bar:getHeight() + self.search_row:getSize().h + Size.padding.small
        + tabs:getSize().h + (chips and chips:getSize().h or 0) + sep:getSize().h
        + footer_probe:getSize().h
    local grid_h = math.max(self.label_h + 20, self.dimen.h - fixed - self:keyboardHeight())
    local layout = Core.gridLayout(self.width, grid_h, self.cols, self.label_h, self.gap)
    self.layout = layout

    local page_items, page, pages = Core.page(data.items, layout.per_page, self.page)
    self.page, self.pages = page, pages
    self.current = data
    local grid = self:buildGrid(page_items, data.kind, layout, grid_h)
    local footer = self:buildFooter(page, pages, #data.items, data.kind)

    self.body = VerticalGroup:new{ align = "left", tabs }
    if chips then table.insert(self.body, chips) end
    table.insert(self.body, sep)
    table.insert(self.body, grid)
    table.insert(self.body, footer)

    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.dimen.w,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            self.title_bar,
            self.search_row,
            VerticalSpan:new{ width = Size.padding.small },
            self.body,
        },
    }
    self.body_y = self.title_bar:getHeight() + self.search_row:getSize().h + Size.padding.small
    self:updateTitle()
    self.timings.filter_s = time.to_s(t1 - t0)
    self.timings.build_s = time.to_s(time.now() - t1)
    self:scheduleCoverExtraction()
end

function LibraryView:updateTitle()
    local title = self.group and self.group.name or _("Library")
    -- TitleBar:setTitle() does not update title_bar.title: track it ourselves.
    if (self._title or _("Library")) ~= title then
        self._title = title
        self.title_bar:setTitle(title, true)
        self._title_changed = true
    end
end

--- Region below the search bar (where results are drawn).
function LibraryView:bodyRegion()
    return Geom:new{ x = 0, y = self.body_y, w = self.dimen.w, h = self.dimen.h - self.body_y }
end

--- Rebuild and refresh only the results region (fast path used while typing).
function LibraryView:refreshBody(full)
    self:buildBody()
    local region = (full or self._title_changed) and self.dimen or self:bodyRegion()
    self._title_changed = nil
    UIManager:setDirty(self, function()
        return "ui", region, true
    end)
end

----------------------------------------------------------------------------
-- Search
----------------------------------------------------------------------------

function LibraryView:onSearchEdited()
    if self._search_action then UIManager:unschedule(self._search_action) end
    self._search_action = function()
        self._search_action = nil
        self:applySearch(self.search_input:getText())
    end
    UIManager:scheduleIn(self.debounce_s, self._search_action)
end

function LibraryView:applySearch(text)
    text = text or ""
    if text == self.query then return end
    self.query = text
    self.page = 1
    self:refreshBody()
end

function LibraryView:clearSearch()
    if self._search_action then UIManager:unschedule(self._search_action); self._search_action = nil end
    self.search_input:setText("")
    self:applySearch("")
end

-- Called by InputText when its box is tapped.
function LibraryView:onSwitchFocus(inputbox)
    if not inputbox.focused then inputbox:focus() end
    if not inputbox:isKeyboardVisible() then
        self:openKeyboard()
    end
end

function LibraryView:openKeyboard()
    self.search_input:focus()
    self.search_input:onShowKeyboard()
    -- While the (modal) keyboard is up, taps outside it must still reach the grid.
    self.is_always_active = true
    self:refreshBody()
end

function LibraryView:closeKeyboard()
    if self.search_input:isKeyboardVisible() then
        self.search_input:onCloseKeyboard()
    end
    self.search_input:unfocus()
    self.is_always_active = false
    self:refreshBody(true)
end

-- The keyboard's own layout changes (e.g. switching to symbols) can change its height.
function LibraryView:onKeyboardHeightChanged()
    self:refreshBody(true)
end

-- Tap on empty space with the keyboard up: hide it.
function LibraryView:onTapOutside(_, ges)
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
        self.is_always_active = false
    end
end

function LibraryView:setTab(id)
    self:keyboardGuard()
    if self.query ~= "" then
        self.search_input:setText("")
        self.query = ""
    end
    self.tab, self.group, self.page = id, nil, 1
    self:refreshBody(true)
end

function LibraryView:setFilter(f)
    self:keyboardGuard()
    self.filter, self.page = f, 1
    self:refreshBody(true)
end

function LibraryView:openGroup(group)
    self.saved_page = self.page
    self.group, self.page = group, 1
    self:refreshBody(true)
end

function LibraryView:closeGroup()
    self.group = nil
    self.page = self.saved_page or 1
    self:refreshBody(true)
end

function LibraryView:onLeftIcon()
    self.plugin:showLibraryMenu(self)
end

function LibraryView:goToPage(page)
    if not self.pages then return end
    page = math.max(1, math.min(page, self.pages))
    if page == self.page then return end
    self.page = page
    self:refreshBody()
end

function LibraryView:onNextPage() self:goToPage(self.page + 1); return true end
function LibraryView:onPrevPage() self:goToPage(self.page - 1); return true end

function LibraryView:onSwipe(_, ges)
    local dir = ges.direction
    if dir == "west" or dir == "north" then
        self:goToPage(self.page < self.pages and self.page + 1 or 1)
    elseif dir == "east" or dir == "south" then
        self:goToPage(self.page > 1 and self.page - 1 or self.pages)
    else
        return false
    end
    return true
end

function LibraryView:onTileTap(tile)
    self:keyboardGuard()
    if tile.group then
        self:openGroup(tile.group)
    else
        self.plugin:openBook(tile.book.path, self)
    end
end

function LibraryView:onTileHold(tile)
    if tile.book then
        self:keyboardGuard()
        self.plugin:showBookDialog(tile.book, self)
    end
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
    if self._search_action then UIManager:unschedule(self._search_action) end
    if self._cover_poll then UIManager:unschedule(self._cover_poll) end
    self.cover_cache:clear()
    -- Cover buffers live in C memory the Lua GC does not see: collect now.
    collectgarbage("collect")
    if self.plugin then self.plugin:onViewClosed(self) end
end

--- After a book's status or metadata changed.
function LibraryView:refreshData()
    self:reloadData()
    self:refreshBody(true)
end

function LibraryView:resort(mode)
    self.sort = mode
    self:reloadData()
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
-- Covers not yet in the BookInfoManager database
----------------------------------------------------------------------------

function LibraryView:scheduleCoverExtraction()
    local bim = self.plugin:getBIM()
    if not bim or not self.missing_covers or #self.missing_covers == 0 then return end
    if self._cover_poll then return end -- a job is already running for an earlier page
    local files = {}
    for _, path in ipairs(self.missing_covers) do
        table.insert(files, { filepath = path, cover_specs = { max_cover_w = 600, max_cover_h = 600 } })
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
