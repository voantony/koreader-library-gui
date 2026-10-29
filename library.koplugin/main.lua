--[[--
Library: a cover-grid library view for KOReader.

Always-visible search bar, cover grid with reading progress, Recent sort,
collections, authors and series, and status filters. Book metadata comes from
calibre's metadata.calibre, the cover browser's database (Project: Title or
coverbrowser), or the book sidecars; the index is cached on disk.

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
    max_depth = 10,
    show_hidden = false,
    start_with_library = false, -- open the Library instead of the file browser
    return_to_library = true,   -- when the Library is the home screen, come back to it after reading
    debounce_ms = 150,
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
    Dispatcher:registerAction("library_rescan",
        { category = "none", event = "RescanLibrary", title = _("Rescan library"), general = true, separator = true })
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
    for _, name in ipairs(names) do
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
        sort = self.settings.sort,
        debounce_s = (self.settings.debounce_ms or 150) / 1000,
    }
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
    for _, n in ipairs({ 3, 4, 5, 6 }) do
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
    dialog = ButtonDialog:new{
        title = _("Library"),
        title_align = "center",
        buttons = {
            sort_row,
            col_row,
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
                text = _("Include hidden folders"),
                checked_func = function() return self.settings.show_hidden end,
                callback = function()
                    self.settings.show_hidden = not self.settings.show_hidden
                    self:saveSettings()
                    shared.index = nil
                end,
            },
        },
    }
end

----------------------------------------------------------------------------
-- Keep the index fresh
----------------------------------------------------------------------------

function Library:onCloseDocument()
    if self.ui.document and shared.index then
        shared.index:refreshBook(self.ui.document.file)
    end
end

function Library:onBookMetadataChanged()
    -- Edited title/author: re-read all metadata next time.
    if shared.index then
        shared.index.needs_build = true
        shared.index.force_next = true
    end
end

return Library
