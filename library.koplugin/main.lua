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
local Event = require("ui/event")
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
    rounded_keyboard = true,    -- "Rounded keyboard in search": softer keys for the search bar only
    fuzzy_search = true,        -- "Typo-tolerant search": accents ignored, small typos forgiven
    remember_views = true,      -- each shelf (collection, author, series, tab) remembers its layout, sort, filter
    controls_panel = true,      -- swipe down from the Library's top-right corner: light, warmth, toggles
    -- view_memory: { [key] = { view =, sort =, filter =, t = } }, see Core.viewKey
    -- sleep_cover_prev: KOReader's sleep screen settings from before
    -- "Sleep screen: cover of last book" was turned on (restored when turned off)
}

local SORT_NAMES = {
    recent = _("Last read"),
    title  = _("Title"),
    author = _("Author"),
    series = _("Series"),
    added  = _("Date added"),
    size   = _("Size"),
}

local VIEW_NAMES = {
    small = _("Small covers"),
    medium = _("Medium covers"),
    large = _("Large covers"),
    list = _("List"),
    compact = _("Compact"),
    compact2 = _("Compact · 2 columns"),
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
    controls = nil,       -- the open Controls panel
    after_book = nil,     -- "show" / "search": open the Library once the book has closed
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
    if not self.ui.document and shared.after_book then
        -- Library was asked for from inside a book, which has now closed.
        local focus_search = shared.after_book == "search"
        shared.after_book = nil
        shared.started = true
        shared.reopen = false
        UIManager:nextTick(function() self:onShowLibrary(focus_search) end)
    elseif not self.ui.document and self.settings.start_with_library then
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

-- load_calibre keeps the fields the grid needs and drops comments. The
-- details card wants the blurb, so it reads the whole file, and only then.
local function loadCalibreFull(path)
    local rapidjson = require("rapidjson")
    if rapidjson.load then return rapidjson.load(path) end
    return loadCalibre(path)
end

--- KOReader's own folders, never scanned for books.
function Library:getSkipDirs()
    local dirs = {}
    local ok, data_dir = pcall(DataStorage.getDataDir, DataStorage)
    if ok and data_dir then table.insert(dirs, data_dir) end
    local ok2, full = pcall(DataStorage.getFullDataDir, DataStorage)
    if ok2 and full then table.insert(dirs, full) end
    local cwd = lfs.currentdir and lfs.currentdir()
    if cwd and lfs.attributes(cwd .. "/reader.lua", "mode") == "file" then
        table.insert(dirs, cwd) -- the install folder (KOReader runs from it)
    end
    return dirs
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
        is_book = Core.makeIsBook(function(path) return DocumentRegistry:hasProvider(path) end),
        skip_dirs = self:getSkipDirs(),
        lower = util.stringLower,
        bim = self:getBIM(),
        docsettings = DocSettings,
        history = ReadHistory,
        calibre_load = loadCalibre,
        calibre_load_full = loadCalibreFull,
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
    local prefs = Core.viewPrefs(self.settings, "books")
    return LibraryView:new{
        plugin = self,
        cols = self.settings.columns,
        view_mode = Core.viewMode(self.settings.view),
        filter = prefs and prefs.filter or "all",
        show_continue = self.settings.show_continue ~= false,
        top_row = Core.topRow(self.settings.top_row),
        sort = self.settings.sort,
        debounce_s = (self.settings.debounce_ms or 150) / 1000,
        barely_threshold = Core.barelyThreshold(self.settings.barely_threshold),
        rounded_keyboard = Core.roundedKeyboard(self.settings),
        fuzzy_search = Core.fuzzySearch(self.settings),
    }
end

----------------------------------------------------------------------------
-- Per-shelf memory: layout, sort and filter (see Core.viewPrefs)
----------------------------------------------------------------------------

--- What `key` should show, or nil when "Remember layout for each shelf" is off.
function Library:viewPrefs(key)
    return Core.viewPrefs(self.settings, key)
end

--- A layout, sort or filter was changed at `key`. With the memory off, the
-- layout and sort are global (as before) and the filter is not kept.
function Library:rememberViewPref(key, field, value)
    local changed
    if Core.rememberViews(self.settings) then
        changed = Core.rememberViewPref(self.settings, key, field, value)
    elseif field ~= "filter" and self.settings[field] ~= value then
        self.settings[field] = value
        changed = true
    end
    if changed then self:saveSettings() end
end

function Library:resetViewPrefs(key)
    Core.resetViewPrefs(self.settings, key)
    self:saveSettings()
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
        local shelf = shared.open_shelf
        shared.open_shelf = nil
        if shelf and shared.view.openNamedShelf then
            shared.view:openNamedShelf(shelf.kind, shelf.name)
        elseif focus_search then
            shared.view:focusSearch()
        end
        return true
    end
    if self.ui.document then return self:leaveBook(focus_search) end
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
    local shelf = shared.open_shelf
    shared.open_shelf = nil
    show()
    if shelf and shared.view and shared.view.openNamedShelf then
        shared.view:openNamedShelf(shelf.kind, shelf.name)
    end
    return true
end

--- From inside a book: close it the way KOReader's file browser button does
-- (progress, settings and history saved), then open the Library over the
-- file browser. The file browser's copy of the plugin picks up `after_book`.
function Library:leaveBook(focus_search)
    local ui = self.ui
    local file = ui.document.file
    shared.after_book = focus_search and "search" or "show"
    ui:onClose()
    ui:showFileManager(file)
    if shared.after_book then
        -- the file browser was already there, so no new plugin copy ran init
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        local lib = FileManager and FileManager.instance and FileManager.instance.library
        shared.after_book = nil
        if lib then UIManager:nextTick(function() lib:onShowLibrary(focus_search) end) end
    end
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

----------------------------------------------------------------------------
-- Controls panel (librarycontrols.lua, loaded on first use)
----------------------------------------------------------------------------

function Library:controlsEnabled()
    return self.settings.controls_panel ~= false and Device:isTouchDevice()
end

function Library:openControls()
    if shared.controls or not self:controlsEnabled() then return false end
    local Controls = require("librarycontrols")
    local panel = Controls:new{ plugin = self }
    shared.controls = panel
    UIManager:show(panel, "ui")
    return true
end

function Library:onControlsClosed(panel)
    if shared.controls == panel then shared.controls = nil end
end

--- Send a KOReader event (night mode, rotation) to the file browser or reader.
function Library:sendUIEvent(ev)
    if self.ui and self.ui.handleEvent then
        self.ui:handleEvent(ev)
    else
        UIManager:broadcastEvent(ev)
    end
end

--- The Library plugin of whatever is on screen now (the file browser is
-- rebuilt when it rotates).
local function currentLibrary(fallback)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.library or fallback
end

--- Rotate 90° clockwise and bring the Library back where it was: it is laid
-- out for one screen size, so it is rebuilt.
function Library:rotateLibrary()
    local view = shared.view
    local state = view and view:placeState()
    if view then UIManager:close(view) end
    self:sendUIEvent(Event:new("IterateRotation"))
    UIManager:nextTick(function()
        local lib = currentLibrary(self)
        lib:onShowLibrary()
        if state and shared.view then shared.view:restorePlace(state) end
    end)
end

function Library:controlsMenu()
    return {
        text = _("Controls panel (swipe down from top-right corner)"),
        help_text = _("In the Library, swipe down from the top-right corner for brightness, warmth, Wi-Fi, night mode, the cover sleep screen, rotation and sleep. Swipe up or tap outside the panel to close it. Controls your device does not have are left out."),
        enabled_func = function() return Device:isTouchDevice() end,
        checked_func = function() return self.settings.controls_panel ~= false end,
        callback = function()
            self.settings.controls_panel = self.settings.controls_panel == false
            self:saveSettings()
        end,
    }
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

--- The dialog a long-press used to open: reading status, Show folder,
-- Book information and Open. The details card keeps it on More.
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

--- Plain blurb for the details card. Calibre, the sidecar and book info come
-- first; the file itself is opened only when those have nothing. Not called
-- while the grid is built.
function Library:fileDescription(path)
    local doc = self.ui and self.ui.document
    if doc and doc.file == path then
        -- The book is already open: read its props, don't open it a second time.
        if doc.getProps then
            local ok, props = pcall(doc.getProps, doc)
            if ok and type(props) == "table" then return props.description end
        end
        return nil
    end
    if not DocumentRegistry.openDocument then return nil end
    local ok, opened = pcall(DocumentRegistry.openDocument, DocumentRegistry, path)
    if not ok or not opened then return nil end
    local props
    pcall(function() props = opened:getProps() end)
    pcall(function() opened:close() end)
    if type(props) == "table" then return props.description end
    return nil
end

function Library:loadDescription(book)
    if not book or type(book.path) ~= "string" then return nil end
    local candidates = {}
    local index = shared.index
    if index and index.descriptionCandidates then
        local ok, list = pcall(index.descriptionCandidates, index, book.path)
        if ok and type(list) == "table" then candidates = list end
    end
    local file_text
    if not Core.firstDescription(candidates) then
        local ok, raw = pcall(self.fileDescription, self, book.path)
        if ok then file_text = raw end
    end
    return Core.descriptionFrom(candidates, file_text)
end

function Library:collectionNames(path)
    local ok, groups = pcall(self.getCollections, self)
    if not ok or type(groups) ~= "table" then return {} end
    return Core.collectionNames(path, groups)
end

--- The open book, from the index when we have it.
function Library:currentBook()
    local doc = self.ui and self.ui.document
    if not doc or type(doc.file) ~= "string" then return nil end
    local index = shared.index
    if not index then
        local ok, idx = pcall(self.ensureIndex, self)
        if ok then index = idx end
    end
    if index then
        local book = index.by_path and index.by_path[doc.file]
        if not book and index.recordFor then
            local ok, rec = pcall(index.recordFor, index, doc.file)
            if ok then book = rec end
        end
        if book then return book end
    end
    local name = doc.file:match("[^/]+$") or doc.file
    return { path = doc.file, name = name, title = Core.stem(name), status = "reading" }
end

--- Write status the way the file browser's status buttons do, then refresh.
function Library:setReadingStatus(book, status, view)
    if not book or type(book.path) ~= "string" then return end
    local file = book.path
    local BookList = require("ui/widget/booklist")
    local handle = file
    local summary = { status = status }
    if BookList.hasBookBeenOpened and BookList.hasBookBeenOpened(file) and BookList.getDocSettings then
        handle = BookList.getDocSettings(file)
        if handle.readSetting then
            local existing = handle:readSetting("summary")
            if type(existing) == "table" then
                existing.status = status
                summary = existing
            end
        end
    end
    filemanagerutil.saveSummary(handle, summary)
    if BookList.setBookInfoCacheProperty then
        BookList.setBookInfoCacheProperty(file, "status", status)
    end
    if BookList.resetBookInfoCache then BookList.resetBookInfoCache(file) end
    book.status = status
    if shared.index and shared.index.refreshBook then
        pcall(shared.index.refreshBook, shared.index, file)
    end
    if view and view.refreshData then view:refreshData() end
end

--- Open a Genres, Collections, Series or Authors shelf. From inside a book
-- this closes it and opens the Library on that shelf.
function Library:openShelf(kind, name, view)
    if view and view.openNamedShelf then
        view:openNamedShelf(kind, name)
        return
    end
    if shared.view and shared.view.openNamedShelf then
        shared.view:openNamedShelf(kind, name)
        return
    end
    shared.open_shelf = { kind = kind, name = name }
    self:onShowLibrary()
end

--- The read-only details card. `view` is the Library when opened from a
-- long-press; from the reader menu it is nil and Continue only closes.
function Library:showBookDetails(book, view, opts)
    if not book or type(book.path) ~= "string" then return end
    opts = opts or {}
    local already_open = opts.already_open and true or false
    if not already_open and not view and self.ui and self.ui.document
            and self.ui.document.file == book.path then
        already_open = true
    end
    local time_left = Core.knownTimeLeft(book)
    if shared.index and shared.index.knownTimeLeft then
        local ok, t = pcall(shared.index.knownTimeLeft, shared.index, book.path, book)
        if ok and t then time_left = t end
    end
    local info = {
        title = book.title or book.name or "",
        authors = Core.authorNames(book),
        series = book.series,
        series_line = Core.seriesLine(book),
        genres = Core.splitKeywords(book.keywords),
        collections = {},
        time_left = time_left,
        description = self:loadDescription(book),
    }
    local ok_names, names = pcall(self.collectionNames, self, book.path)
    if ok_names and type(names) == "table" then info.collections = names end
    local Details = require("librarydetails")
    local Tiles = require("librarytile")
    local Covers = require("librarycovers")
    local card
    card = Details:new{
        book = book,
        info = info,
        already_open = already_open,
        covers = (view and view.covers) or { store = Covers.getStore(), bim = self:getBIM() },
        cover_cache = (view and view.cover_cache) or Tiles.newCoverCache(4),
        on_continue = function()
            UIManager:close(card)
            if Core.detailsPrimaryDismisses(already_open) then return end
            UIManager:nextTick(function() self:openBook(book.path, view) end)
        end,
        on_status = function()
            local action = Core.detailsStatusAction(book)
            self:setReadingStatus(book, action == "mark_unread" and "new" or "complete", view)
            if card.setStatusLabel then card:setStatusLabel() end
            if card.setProgress then card:setProgress() end
        end,
        on_close = function()
            UIManager:close(card)
        end,
        on_more = function()
            UIManager:close(card)
            UIManager:nextTick(function() self:showBookDialog(book, view) end)
        end,
        on_shelf = function(kind, name)
            UIManager:close(card)
            UIManager:nextTick(function() self:openShelf(kind, name, view) end)
        end,
    }
    UIManager:show(card)
    return card
end

--- The sort picker from the Library's footer label ("202 books · Last read ▾").
function Library:showSortPicker(view)
    local dialog
    local buttons = {}
    for _, mode in ipairs(Core.SORT_MENU) do
        table.insert(buttons, { {
            text = (view.sort == mode and "\u{2713} " or "") .. SORT_NAMES[mode],
            callback = function()
                UIManager:close(dialog)
                if view.sort ~= mode then view:resort(mode) end -- remembered for this tab or shelf
            end,
        } })
    end
    dialog = ButtonDialog:new{ title = _("Sort by"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
    return dialog
end

--- Go to page: a number box opened from the footer's "63 / 72".
function Library:showPageJump(view)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local function go()
        local n = tonumber(dialog:getInputText())
        if not n then return end
        UIManager:close(dialog)
        view:goToPage(math.floor(n))
    end
    dialog = InputDialog:new{
        title = _("Go to page"),
        input = "",
        input_hint = T(_("1 – %1"), view.pages),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Go"), is_enter_default = true, callback = go },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

--- The ☰ menu inside the Library view.
function Library:showLibraryMenu(view)
    local dialog
    local function close() UIManager:close(dialog) end
    local sort_row, col_row = {}, {}
    for _, mode in ipairs(Core.SORT_MENU) do
        table.insert(sort_row, {
            text = (view.sort == mode and "✓ " or "") .. SORT_NAMES[mode],
            callback = function()
                close()
                view:resort(mode) -- remembered for this shelf (or the default, on the Books tab)
            end,
        })
    end
    -- View: Small, Medium, Large covers (columns, for every shelf), List, Compact.
    -- (two rows: the cover sizes, then the text views)
    local view_row, text_row = {}, {}
    local pick = Core.viewPick(view.view_mode, self.settings.columns)
    for _i, p in ipairs(Core.VIEW_PICKER) do
        table.insert(p.columns and view_row or text_row, {
            text = (pick == p.id and "✓ " or "") .. VIEW_NAMES[p.id],
            callback = function()
                close()
                if p.columns and self.settings.columns ~= p.columns then
                    self.settings.columns = p.columns
                    self:saveSettings()
                    view:setColumns(p.columns)
                end
                view:setViewMode(p.view)
            end,
        })
    end
    table.insert(col_row, {
        text = (self.settings.show_continue ~= false and "✓ " or "")
            .. (Core.topRow(self.settings.top_row) == "recent" and _("Show Recently opened") or _("Show Continue reading")),
        callback = function()
            close()
            self.settings.show_continue = self.settings.show_continue == false
            self:saveSettings()
            view:setShowContinue(self.settings.show_continue)
        end,
    })
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
    local buttons = { sort_row, view_row, text_row, col_row, barely_row }
    -- Each shelf remembers its own layout, sort and filter: offer to forget them.
    local remember = Core.rememberViews(self.settings)
    if remember then
        local place = view:placeName()
        local on_books = view:viewKey() == "books"
        table.insert(buttons, {
            {
                text = on_books and _("\u{21BA} Reset default layout (covers, Last read, All)")
                    or T(_("\u{21BA} Reset “%1” to default"), place),
                enabled = view:hasRemembered(),
                callback = function()
                    close()
                    view:resetRemembered()
                end,
            },
        })
    end
    local title = _("Library")
    if remember and view:viewKey() ~= "books" then
        title = T(_("Library · %1"), view:placeName())
            .. (view:hasRemembered() and ("\n" .. _("Layout, sort and filter remembered here")) or "")
    end
    table.insert(buttons, {
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
    })
    -- Last item: leave the Library for the file browser (the title bar has no X).
    table.insert(buttons, {
        {
            text = "\u{2715} " .. _("Close Library"),
            callback = function()
                close()
                UIManager:close(view)
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
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
        help_text = _("The row of large covers at the top of the Books tab. Continue reading shows the books you are reading. Recently opened shows every book you have opened, newest first, including finished and on-hold ones. The Resume icon (top right) always opens the most recent book you are still reading."),
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

local READER_ITEM_ID = "library_open"

-- Put a "Library" item at the top of the reader's ☰ tab, above History.
local function placeReaderItem()
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or type(order) ~= "table" or type(order.main) ~= "table" then return end
    Core.placeFirst(order.main, READER_ITEM_ID)
end

function Library:addReaderItem(menu_items)
    placeReaderItem()
    menu_items[READER_ITEM_ID] = {
        text = _("Library"),
        help_text = _("Close this book and open the Library. Your page and settings are saved first."),
        callback = function()
            if self.ui.menu then self.ui.menu:onTapCloseMenu() end
            UIManager:nextTick(function() self:onShowLibrary() end)
        end,
    }
end

--- "Book details" directly under the reader's Library item. Same card as a
-- long-press. Continue closes it and returns to the open page.
local READER_DETAILS_ID = "library_details"
function Library:addBookDetailsItem(menu_items)
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if ok and type(order) == "table" and type(order.main) == "table" then
        Core.placeAfter(order.main, READER_DETAILS_ID, READER_ITEM_ID)
    end
    menu_items[READER_DETAILS_ID] = {
        text = _("Book details"),
        help_text = _("Title, author, description and progress for this book. Continue returns to the page."),
        callback = function()
            if self.ui.menu then self.ui.menu:onTapCloseMenu() end
            UIManager:nextTick(function()
                local book = self:currentBook()
                if book then self:showBookDetails(book, nil, { already_open = true }) end
            end)
        end,
    }
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

--- ☰ → Library → Remember layout for each shelf, and a way to forget them all.
function Library:rememberViewsMenu()
    return {
        text = _("Remember layout for each shelf"),
        help_text = _("Each collection, author, series and tab remembers its own layout (grid or list), sort and status filter, and opens the way you left it. The Books tab sets the default for places you have not changed. To reset the place you are in, use the Library's ☰ menu. Long-press this item to forget every shelf at once."),
        checked_func = function() return Core.rememberViews(self.settings) end,
        callback = function()
            self.settings.remember_views = not Core.rememberViews(self.settings)
            self:saveSettings()
            if shared.view then
                shared.view:applyRemembered()
                shared.view:refreshBody(true)
            end
        end,
        hold_callback = function(touchmenu_instance)
            local n = Core.countViewMemory(self.settings)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = T(_("Forget the layout, sort and filter remembered for %1 shelves? The Books tab's default stays."), n),
                ok_text = _("Forget"),
                ok_callback = function()
                    Core.resetAllViewPrefs(self.settings)
                    self:saveSettings()
                    if shared.view then
                        shared.view:applyRemembered()
                        shared.view:refreshBody(true)
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
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

function Library:sleepCoverIsOn()
    return Core.sleepCoverOn(readerSettings())
end

--- Turn "Sleep screen: cover of last book" on or off (menu and Controls panel).
function Library:toggleSleepCover()
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
end

--- ☰ → Library → Sleep screen: cover of last book. A shortcut to KOReader's
-- own "Show book cover on sleep screen", which also covers the file browser
-- and the Library; turning it off restores the previous sleep screen.
function Library:sleepCoverMenu()
    return {
        text = _("Sleep screen: cover of last book"),
        help_text = _("When the device sleeps, show the cover of the book you read last, also when you are in the Library or the file browser. This turns on KOReader's own \"Show book cover on sleep screen\" (Settings → Screen → Sleep screen). If the book has no cover, KOReader shows its usual sleep screen image. Turning this off brings back the sleep screen you had before."),
        checked_func = function() return self:sleepCoverIsOn() end,
        callback = function() self:toggleSleepCover() end,
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
                text = _("Rounded keyboard in search"),
                help_text = _("Give the Library's search bar a softer on-screen keyboard: rounded keys with gaps between them on a light background, like the Kindle or a phone. Only the Library's search uses it; every other keyboard in KOReader stays as it is."),
                checked_func = function() return Core.roundedKeyboard(self.settings) end,
                callback = function()
                    self.settings.rounded_keyboard = not Core.roundedKeyboard(self.settings)
                    self:saveSettings()
                    if shared.view then shared.view:setRoundedKeyboard(self.settings.rounded_keyboard) end
                end,
            },
            {
                text = _("Typo-tolerant search"),
                help_text = _("Search also finds close matches: accents and punctuation are ignored (bronte finds Brontë) and small typos are forgiven (harry poter finds Harry Potter). Exact matches stay at the top."),
                checked_func = function() return Core.fuzzySearch(self.settings) end,
                callback = function()
                    self.settings.fuzzy_search = not Core.fuzzySearch(self.settings)
                    self:saveSettings()
                    if shared.view then shared.view:setFuzzySearch(self.settings.fuzzy_search) end
                end,
            },
            self:rememberViewsMenu(),
            self:controlsMenu(),
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
        self:addReaderItem(menu_items)
        self:addBookDetailsItem(menu_items)
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
