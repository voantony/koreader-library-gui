--[[--
Library: a cover-grid library view for KOReader.

Always-visible search bar, cover grid with reading progress, Recent sort,
collections, authors and series, and status filters. Book metadata comes from
calibre's metadata.calibre, the cover browser's database (Project: Title or
coverbrowser), or the book sidecars; the index is cached on disk. Covers come
from the plugin's own thumbnails (librarycovers.lua), or from the cover
browser's database when one of those plugins is loaded.

@module koplugin.library
--]]

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local Core = require("librarycore")
local Index = require("libraryindex")
local _ = require("gettext")
local T = ffiUtil.template

local SETTINGS_KEY = "library_plugin"

local DEFAULTS = {
    root = nil,              -- nil: the KOReader home folder
    sort = "recent",
    columns = 4,
    view = "grid",           -- "grid" | "list"
    show_continue = true,    -- Continue reading strip on the Books tab
    top_row = "continue",    -- what that strip shows: "continue" | "recent" (Recently opened)
    max_depth = 10,
    show_hidden = false,
    start_with_library = false, -- open the Library instead of the file browser
    return_to_library = true,   -- when the Library is the home screen, come back to it after reading
    debounce_ms = 150,
    barely_threshold = 0.10,    -- "Barely started" filter: opened and below this fraction
    series_skip_finished = true, -- Next in series skips books already finished
    reader_tab = true,          -- a Library tab (book icon) in the reader's top menu bar
    -- sleep_cover_prev: KOReader's sleep screen settings from before
    -- "Sleep screen: cover of last book" was turned on (restored when turned off)
}

local SORT_NAMES = {
    recent = _("Recent"),
    title  = _("Title"),
    author = _("Author"),
    series = _("Series"),
    added  = _("Date added"),
    size   = _("Size"),
}

local Library = WidgetContainer:extend{
    name = "library",
    is_doc_only = false,
}

-- Shared between FileManager and ReaderUI instances of the plugin, so the
-- index survives opening and closing books.
local shared = {
    index = nil,
    started = false,      -- the start-up Library has been shown once
    reopen = false,       -- a book was opened from the Library
    view = nil,
}
Library.shared = shared

local function collate(a, b)
    return ffiUtil.strcoll(a, b)
end
Library.collate = collate

function Library:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- In the file browser: show the Library at start-up, or again after reading.
    -- (file_chooser is only created after plugins, so test for the reader instead.)
    if not self.ui.document and self.settings.start_with_library then
        local first = not shared.started
        local back_from_book = shared.reopen and self.settings.return_to_library
        if first or back_from_book then
            shared.started = true
            shared.reopen = false
            UIManager:nextTick(function() self:onShowLibrary() end)
        end
    end
end

function Library:onDispatcherRegisterActions()
    Dispatcher:registerAction("library_show",
        { category = "none", event = "ShowLibrary", title = _("Library"), general = true })
    Dispatcher:registerAction("library_search",
        { category = "none", event = "SearchLibrary", title = _("Search library"), general = true })
    Dispatcher:registerAction("library_resume",
        { category = "none", event = "LibraryResume", title = _("Resume last book (Library)"), general = true })
    Dispatcher:registerAction("library_rescan",
        { category = "none", event = "RescanLibrary", title = _("Rescan library"), general = true, separator = true })
    Dispatcher:registerAction("library_next_in_series",
        { category = "none", event = "LibraryNextInSeries", title = _("Next in series"), reader = true })
    Dispatcher:registerAction("library_prev_in_series",
        { category = "none", event = "LibraryPrevInSeries", title = _("Previous in series"), reader = true, separator = true })
end

function Library:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function Library:getRoot()
    local root = self.settings.root
    if root and lfs.attributes(root, "mode") == "directory" then
        return root
    end
    return filemanagerutil.getHomeFolder() or Device.home_dir or "/"
end

function Library:sortName(mode)
    return SORT_NAMES[mode] or mode
end

----------------------------------------------------------------------------
-- Data sources
----------------------------------------------------------------------------

--- The cover browser's BookInfoManager (Project: Title's, or coverbrowser's).
function Library:getBIM()
    local bim = package.loaded["bookinfomanager"]
    if bim == nil then
        local ok, mod = pcall(require, "bookinfomanager")
        bim = ok and mod or false
        if not ok then package.loaded["bookinfomanager"] = nil end
    end
    if type(bim) == "table" and bim.getBookInfo then return bim end
    return nil
end

local function loadCalibre(path)
    local rapidjson = require("rapidjson")
    local load = rapidjson.load_calibre or rapidjson.load
    return load(path)
end

function Library:getIndex()
    local root = self:getRoot()
    if shared.index and shared.index.opts.root == root
            and shared.index.opts.show_hidden == self.settings.show_hidden then
        return shared.index
    end
    local DocSettings = require("docsettings")
    local ReadHistory = require("readhistory")
    shared.index = Index.new{
        root = root,
        show_hidden = self.settings.show_hidden,
        max_depth = self.settings.max_depth,
        cache_file = DataStorage:getSettingsDir() .. "/library_index.lua",
        fs = lfs,
        is_book = function(path) return DocumentRegistry:hasProvider(path) end,
        lower = util.stringLower,
        bim = self:getBIM(),
        docsettings = DocSettings,
        history = ReadHistory,
        calibre_load = loadCalibre,
        extra_calibre_dirs = { G_reader_settings:readSetting("inbox_dir") },
        clock = function() return require("ui/time").to_s(require("ui/time").now()) end,
    }
    shared.index.needs_build = true
    return shared.index
end

--- Build or refresh the index. `force` ignores the disk cache.
function Library:ensureIndex(force)
    local index = self:getIndex()
    force = force or index.force_next
    if index.needs_build or force then
        index.force_next = nil
        local ok, err = pcall(index.build, index, force)
        if not ok then
            logger.warn("Library: index build failed:", err)
        end
        index.needs_build = false
        logger.info("Library: index", index.stats)
    end
    return index
end

function Library:getBooks()
    return self:ensureIndex().books
end

--- Collections as groups: { kind="collections", name=, books= }.
function Library:getCollections()
    local ok, ReadCollection = pcall(require, "readcollection")
    if not ok or not ReadCollection.coll then return {} end
    if ReadCollection._read then pcall(ReadCollection._read, ReadCollection) end
    local index = self:ensureIndex()
    local names = {}
    for name in pairs(ReadCollection.coll) do table.insert(names, name) end
    local settings = ReadCollection.coll_settings or {}
    table.sort(names, function(a, b)
        local oa = settings[a] and settings[a].order or math.huge
        local ob = settings[b] and settings[b].order or math.huge
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    local groups = {}
    for _i, name in ipairs(names) do
        local items = ReadCollection.getOrderedCollection and ReadCollection:getOrderedCollection(name) or {}
        local books = {}
        for _, item in ipairs(items) do
            local book = item.file and index:recordFor(item.file)
            if book then table.insert(books, book) end
        end
        local title = name
        if name == ReadCollection.default_collection_name then
            local fmc = self.ui.collections
            title = fmc and fmc.getCollectionTitle and fmc:getCollectionTitle(name) or _("Favorites")
        end
        table.insert(groups, { kind = "collections", name = title, books = books })
    end
    return groups
end

----------------------------------------------------------------------------
-- Showing the Library
----------------------------------------------------------------------------

function Library:newView()
    local LibraryView = require("libraryview")
    return LibraryView:new{
        plugin = self,
        cols = self.settings.columns,
        view_mode = Core.viewMode(self.settings.view),
        show_continue = self.settings.show_continue ~= false,
        top_row = Core.topRow(self.settings.top_row),
        sort = self.settings.sort,
        debounce_s = (self.settings.debounce_ms or 150) / 1000,
        barely_threshold = Core.barelyThreshold(self.settings.barely_threshold),
    }
end

----------------------------------------------------------------------------
-- Series navigation and resume
----------------------------------------------------------------------------

--- The open book's record and its series, in reading order.
function Library:currentSeries()
    local doc = self.ui.document
    if not doc or not doc.file then return nil end
    local index = self:ensureIndex()
    local current = index.by_path[doc.file] or index:recordFor(doc.file)
    if not current or not current.series then return nil, nil, current end
    local books = Core.seriesBooks(index.books, current.series, collate)
    local found = false
    for _, b in ipairs(books) do if b.path == current.path then found = true; break end end
    if not found then -- opened from outside the Library folder
        table.insert(books, current)
        books = Core.seriesOrder(books, collate)
    end
    return books, current.series, current
end

--- The book Next (dir = 1) or Previous (dir = -1) in series would open.
function Library:seriesTarget(dir)
    local books, _series, current = self:currentSeries()
    if not books then return nil, current end
    return Core.seriesNeighbour(books, current, dir,
        { skip_finished = self.settings.series_skip_finished ~= false }), current
end

--- "3 · Title" for menus and messages.
function Library:seriesLabel(book)
    local n = Core.seriesNumber(book.series_index)
    return (n and (n .. " · ") or "") .. (book.title or book.name)
end

function Library:openInSeries(dir)
    if not self.ui.document then
        UIManager:show(InfoMessage:new{ text = _("Open a book first."), timeout = 2 })
        return true
    end
    local target, current = self:seriesTarget(dir)
    if not target then
        local text
        if not (current and current.series) then
            text = _("This book is not part of a series.")
        elseif dir > 0 then
            text = T(_("“%1” is the last book of %2."), current.title or current.name, current.series)
        else
            text = T(_("“%1” is the first book of %2."), current.title or current.name, current.series)
        end
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
        return true
    end
    logger.info("Library: series", dir > 0 and "next" or "previous", "->", target.path)
    filemanagerutil.openFile(self.ui, target.path)
    return true
end

function Library:onLibraryNextInSeries() return self:openInSeries(1) end
function Library:onLibraryPrevInSeries() return self:openInSeries(-1) end

--- Open the most recently read book that is not finished, at its saved position.
function Library:onLibraryResume()
    local book = Core.resumeBook(self:getBooks())
    if not book then
        UIManager:show(InfoMessage:new{ text = _("No book in progress."), timeout = 2 })
        return true
    end
    if self.ui.document and self.ui.document.file == book.path then return true end
    self:openBook(book.path, shared.view)
    return true
end

function Library:onShowLibrary(focus_search)
    if shared.view then
        if focus_search then shared.view:focusSearch() end
        return true
    end
    local index = self:getIndex()
    local function show()
        local view = self:newView()
        shared.view = view
        UIManager:show(view)
        if focus_search then UIManager:nextTick(function() view:focusSearch() end) end
    end
    if index.needs_build then
        local msg = InfoMessage:new{ text = _("Loading library…") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        self:ensureIndex()
        UIManager:close(msg)
    else
        -- Cheap refresh of reading state and history order.
        self:refreshReadingState()
    end
    show()
    return true
end

function Library:onSearchLibrary()
    return self:onShowLibrary(true)
end

function Library:onRescanLibrary()
    self:ensureIndex(true)
    local index = shared.index
    UIManager:show(InfoMessage:new{
        text = T(_("Library rescanned: %1 books."), #index.books),
        timeout = 2,
    })
    if shared.view then shared.view:refreshData() end
    return true
end

function Library:onViewClosed(view)
    if shared.view == view then shared.view = nil end
end

--- Re-read sidecars that changed and history order (cheap, mtime-based).
function Library:refreshReadingState()
    local index = shared.index
    if not index or index.needs_build then return end
    -- A rebuild with a warm cache only stats files and reads changed sidecars.
    local ok, err = pcall(index.build, index, false)
    if not ok then logger.warn("Library: refresh failed:", err) end
end

function Library:openBook(path, view)
    shared.reopen = true
    filemanagerutil.openFile(self.ui, path, function()
        if view then UIManager:close(view) end
    end)
end

function Library:showBookDialog(book, view)
    local BookList = require("ui/widget/booklist")
    local file = book.path
    local dialog
    local function close() UIManager:close(dialog) end
    local function after_status_change()
        close()
        if BookList.resetBookInfoCache then BookList.resetBookInfoCache(file) end
        if shared.index then shared.index:refreshBook(file) end
        if view then view:refreshData() end
    end
    local been_opened = BookList.hasBookBeenOpened(file)
    local doc_settings_or_file = been_opened and BookList.getDocSettings(file) or file
    local bim = self:getBIM()
    local props = bim and bim.getDocProps and bim:getDocProps(file) or nil
    local buttons = {
        filemanagerutil.genStatusButtonsRow(doc_settings_or_file, after_status_change),
        {},
        {
            filemanagerutil.genShowFolderButton(file, function()
                close()
                if view then UIManager:close(view) end
            end),
            filemanagerutil.genBookInformationButton(doc_settings_or_file, props, close),
        },
        {
            {
                text = _("Open"),
                callback = function()
                    close()
                    self:openBook(file, view)
                end,
            },
        },
    }
    dialog = ButtonDialog:new{
        title = book.title .. (book.authors and book.authors[1] and ("\n" .. book.authors[1]) or ""),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- The ☰ menu inside the Library view.
function Library:showLibraryMenu(view)
    local dialog
    local function close() UIManager:close(dialog) end
    local sort_row, col_row = {}, {}
    for _, mode in ipairs({ "recent", "title", "author", "series", "added" }) do
        table.insert(sort_row, {
            text = (self.settings.sort == mode and "✓ " or "") .. SORT_NAMES[mode],
            callback = function()
                close()
                self.settings.sort = mode
                self:saveSettings()
                view:resort(mode)
            end,
        })
    end
    local view_row = {}
    for _i, mode in ipairs(Core.VIEWS) do
        local name = mode == "list" and _("List") or _("Grid")
        table.insert(view_row, {
            text = (Core.viewMode(self.settings.view) == mode and "✓ " or "") .. T(_("View: %1"), name),
            callback = function()
                close()
                self.settings.view = mode
                self:saveSettings()
                view:setViewMode(mode)
            end,
        })
    end
    table.insert(view_row, {
        text = (self.settings.show_continue ~= false and "✓ " or "")
            .. (Core.topRow(self.settings.top_row) == "recent" and _("Show Recently opened") or _("Show Continue reading")),
        callback = function()
            close()
            self.settings.show_continue = self.settings.show_continue == false
            self:saveSettings()
            view:setShowContinue(self.settings.show_continue)
        end,
    })
    for _i, n in ipairs({ 3, 4, 5, 6 }) do
        table.insert(col_row, {
            text = (self.settings.columns == n and "✓ " or "") .. T(_("%1 columns"), n),
            callback = function()
                close()
                self.settings.columns = n
                self:saveSettings()
                view:setColumns(n)
            end,
        })
    end
    local barely_row = {}
    local th = Core.barelyThreshold(self.settings.barely_threshold)
    for _i, t in ipairs(Core.BARELY_THRESHOLDS) do
        table.insert(barely_row, {
            text = (th == t and "✓ " or "") .. T(_("Barely started < %1 %"), math.floor(t * 100 + 0.5)),
            callback = function()
                close()
                self.settings.barely_threshold = t
                self:saveSettings()
                view:setBarelyThreshold(t)
            end,
        })
    end
    dialog = ButtonDialog:new{
        title = _("Library"),
        title_align = "center",
        buttons = {
            sort_row,
            view_row,
            col_row,
            barely_row,
            {
                {
                    text = (self.settings.start_with_library and "✓ " or "") .. _("Start with Library"),
                    callback = function()
                        close()
                        self.settings.start_with_library = not self.settings.start_with_library
                        self:saveSettings()
                    end,
                },
                {
                    text = _("Rescan"),
                    callback = function()
                        close()
                        self:onRescanLibrary()
                    end,
                },
            },
            {
                {
                    text = _("File browser"),
                    callback = function()
                        close()
                        UIManager:close(view)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

----------------------------------------------------------------------------
-- Main menu (file browser and reader)
----------------------------------------------------------------------------

--- Next / Previous in series entries for the reader's Library menu.
function Library:seriesMenuItems()
    local function item(dir)
        return {
            text_func = function()
                local ok, target = pcall(self.seriesTarget, self, dir)
                local name = dir > 0 and _("Next in series") or _("Previous in series")
                if ok and target then return name .. ": " .. self:seriesLabel(target) end
                return name
            end,
            enabled_func = function()
                local ok, target = pcall(self.seriesTarget, self, dir)
                return ok and target ~= nil
            end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:openInSeries(dir)
            end,
            separator = dir < 0,
        }
    end
    return item(1), item(-1)
end

function Library:barelyMenu()
    local items = {}
    for _i, t in ipairs(Core.BARELY_THRESHOLDS) do
        table.insert(items, {
            text = T(_("Below %1 %"), math.floor(t * 100 + 0.5)),
            radio = true,
            checked_func = function() return Core.barelyThreshold(self.settings.barely_threshold) == t end,
            callback = function()
                self.settings.barely_threshold = t
                self:saveSettings()
                if shared.view then shared.view:setBarelyThreshold(t) end
            end,
        })
    end
    return {
        text_func = function()
            return T(_("Barely started: below %1 %"),
                math.floor(Core.barelyThreshold(self.settings.barely_threshold) * 100 + 0.5))
        end,
        help_text = _("The Barely started filter shows books you have opened and read less than this much of. Books never opened are not included."),
        sub_item_table = items,
    }
end

--- ☰ → Library → Top row: Continue reading (books in progress, the default)
-- or Recently opened (every book opened, newest first, whatever its status).
local TOP_ROW_NAMES = { continue = _("Continue reading"), recent = _("Recently opened") }

function Library:setTopRow(mode)
    Core.setTopRow(self.settings, mode, function() self:saveSettings() end)
    if shared.view then shared.view:setTopRow(self.settings.top_row) end
end

function Library:topRowMenu()
    local items = {}
    for _i, mode in ipairs(Core.TOP_ROWS) do
        table.insert(items, {
            text = TOP_ROW_NAMES[mode],
            radio = true,
            checked_func = function() return Core.topRow(self.settings.top_row) == mode end,
            callback = function() self:setTopRow(mode) end,
        })
    end
    return {
        text_func = function()
            return T(_("Top row: %1"), TOP_ROW_NAMES[Core.topRow(self.settings.top_row)])
        end,
        help_text = _("The row of large covers at the top of the Books tab. Continue reading shows the books you are reading. Recently opened shows every book you have opened, newest first, including finished and on-hold ones. The Resume button always opens the most recent book you are still reading."),
        sub_item_table = items,
    }
end

--- Put (or take) our tab into the reader's top menu bar, just before the
-- file browser tab. reader_menu_order is a cached module table, so this is
-- idempotent: drop any earlier copy first.
local READER_TAB_ID = "library_tab"
local function placeReaderTab(enabled)
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or type(order) ~= "table" then return end
    local buttons = order["KOMenu:menu_buttons"]
    if type(buttons) ~= "table" then return end
    Core.placeMenuButton(buttons, READER_TAB_ID, "filemanager", enabled)
    -- a top-level entry with no items: tapping it runs the callback
    order[READER_TAB_ID] = enabled and {} or nil
end

function Library:addReaderTab(menu_items)
    local enabled = self.settings.reader_tab ~= false
    placeReaderTab(enabled)
    if not enabled then return end
    menu_items[READER_TAB_ID] = {
        icon = "book.opened",
        text = _("Library"), -- only shown if a custom menu order leaves the tab out
        remember = false,
        callback = function()
            if self.ui.menu then self.ui.menu:onTapCloseMenu() end
            -- let the menu close before the Library opens over the book
            UIManager:nextTick(function() self:onShowLibrary() end)
        end,
    }
end

--- G_reader_settings, as the small interface Core's sleep screen helpers use.
local function readerSettings()
    return {
        read = function(k) return G_reader_settings:readSetting(k) end,
        save = function(k, v) G_reader_settings:saveSetting(k, v) end,
        del = function(k) G_reader_settings:delSetting(k) end,
    }
end

--- ☰ → Library → Sleep screen: cover of last book. A shortcut to KOReader's
-- own "Show book cover on sleep screen", which also covers the file browser
-- and the Library; turning it off restores the previous sleep screen.
function Library:sleepCoverMenu()
    return {
        text = _("Sleep screen: cover of last book"),
        help_text = _("When the device sleeps, show the cover of the book you read last, also when you are in the Library or the file browser. This turns on KOReader's own \"Show book cover on sleep screen\" (Settings → Screen → Sleep screen). If the book has no cover, KOReader shows its usual sleep screen image. Turning this off brings back the sleep screen you had before."),
        checked_func = function() return Core.sleepCoverOn(readerSettings()) end,
        callback = function()
            local gs = readerSettings()
            if Core.sleepCoverOn(gs) then
                Core.sleepCoverDisable(gs, self.settings.sleep_cover_prev)
                self.settings.sleep_cover_prev = nil
            else
                self.settings.sleep_cover_prev = Core.sleepCoverEnable(gs)
            end
            self:saveSettings()
            logger.info("Library: sleep screen", G_reader_settings:readSetting("screensaver_type"),
                "hide in file browser:", G_reader_settings:readSetting("screensaver_hide_cover_in_filemanager"))
        end,
    }
end

function Library:addToMainMenu(menu_items)
    menu_items.library = {
        text = _("Library"),
        sorting_hint = "main",
        sub_item_table = {
            {
                text = _("Open Library"),
                callback = function() self:onShowLibrary() end,
            },
            {
                text = _("Rescan library"),
                keep_menu_open = true,
                callback = function() self:onRescanLibrary() end,
                separator = true,
            },
            {
                text = _("Open Library at startup"),
                help_text = _("Show the Library instead of the file browser when KOReader starts. Close the Library (X) to get to the file browser."),
                checked_func = function() return self.settings.start_with_library end,
                callback = function()
                    self.settings.start_with_library = not self.settings.start_with_library
                    self:saveSettings()
                end,
            },
            {
                text = _("Return to Library after closing a book"),
                enabled_func = function() return self.settings.start_with_library end,
                checked_func = function() return self.settings.return_to_library end,
                callback = function()
                    self.settings.return_to_library = not self.settings.return_to_library
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Library folder: %1"), BD.dirpath(filemanagerutil.abbreviate(self:getRoot())))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    filemanagerutil.showChooseDialog(_("Library folder:"), function(path)
                        self.settings.root = path
                        self:saveSettings()
                        shared.index = nil
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end, self:getRoot(), filemanagerutil.getHomeFolder())
                end,
            },
            {
                text = _("Clear cover cache"),
                help_text = _("Delete the Library's cover thumbnails. They are made again, in the background, the next time the Library is open."),
                keep_menu_open = true,
                callback = function() self:clearCoverCache() end,
            },
            {
                text = _("Include hidden folders"),
                checked_func = function() return self.settings.show_hidden end,
                callback = function()
                    self.settings.show_hidden = not self.settings.show_hidden
                    self:saveSettings()
                    shared.index = nil
                end,
                separator = true,
            },
            self:barelyMenu(),
            self:topRowMenu(),
            self:sleepCoverMenu(),
            {
                text = _("Library tab in the reader menu"),
                help_text = _("Show a Library tab (book icon) in the top menu bar while reading, next to the file browser tab."),
                checked_func = function() return self.settings.reader_tab ~= false end,
                callback = function()
                    self.settings.reader_tab = self.settings.reader_tab == false
                    self:saveSettings()
                    -- the reader rebuilds its menu tabs the next time the menu opens
                    if self.ui.document and self.ui.menu then self.ui.menu.tab_item_table = nil end
                end,
            },
            {
                text = _("Next in series skips finished books"),
                help_text = _("Next in series opens the next book you have not finished. Turn this off to always open the very next book."),
                checked_func = function() return self.settings.series_skip_finished ~= false end,
                callback = function()
                    self.settings.series_skip_finished = self.settings.series_skip_finished == false
                    self:saveSettings()
                end,
            },
        },
    }
    if self.ui.document then
        self:addReaderTab(menu_items)
        -- inside a book: Next / Previous in series right under Open Library
        local next_item, prev_item = self:seriesMenuItems()
        table.insert(menu_items.library.sub_item_table, 2, next_item)
        table.insert(menu_items.library.sub_item_table, 3, prev_item)
    end
end

----------------------------------------------------------------------------
-- Keep the index fresh
----------------------------------------------------------------------------

function Library:onCloseDocument()
    if self.ui.document and shared.index then
        shared.index:refreshBook(self.ui.document.file)
    end
end

--- A custom cover was set or removed in Book information: drop our thumbnail.
function Library:onInvalidateMetadataCache(file)
    if not file then return end
    local Covers = require("librarycovers")
    Covers.getStore():forget(file)
    if shared.view then
        shared.view.cover_cache:clear()
        shared.view:refreshBody()
    end
end

function Library:clearCoverCache()
    local Covers = require("librarycovers")
    local store = Covers.getStore()
    Covers.kill()
    local n, bytes = store:usage()
    store:clear()
    if shared.view then
        shared.view.cover_cache:clear()
        shared.view:refreshBody(true)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Removed %1 cover thumbnails (%2)."), n, Core.formatSize(bytes)),
        timeout = 2,
    })
end

function Library:onBookMetadataChanged()
    -- Edited title/author: re-read all metadata next time.
    if shared.index then
        shared.index.needs_build = true
        shared.index.force_next = true
    end
end

return Library
