--[[--
Library: browse all books under a folder by author, series, status,
format or folder, without walking the file tree.

@module koplugin.Library
]]

local BD = require("ui/bidi")
local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Core = require("librarycore")
local _ = require("gettext")
local T = ffiUtil.template

local SETTINGS_KEY = "library_plugin"

local DEFAULTS = {
    root = nil,          -- nil means "use the KOReader home folder"
    sort = "title",
    max_depth = 10,
    show_hidden = false,
    recent_count = 30,
}

local SORT_NAMES = {
    title  = _("Title"),
    author = _("Author"),
    series = _("Series"),
    added  = _("Date added"),
    size   = _("Size"),
}

local GROUP_NAMES = {
    author = _("Authors"),
    series = _("Series"),
    status = _("Reading status"),
    format = _("Formats"),
    folder = _("Folders"),
}

local Library = WidgetContainer:extend{
    name = "library",
    is_doc_only = false,
}

-- Scan results are shared between the file manager and reader instances,
-- so opening a book does not force a rescan.
local shared = {
    books = nil,
    root = nil,
    truncated = false,
}

function Library:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
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
    return filemanagerutil.getHomeFolder()
end

----------------------------------------------------------------------------
-- Main menu
----------------------------------------------------------------------------

function Library:addToMainMenu(menu_items)
    menu_items.library = {
        text = _("Library"),
        sorting_hint = "main",
        sub_item_table = {
            {
                text = _("Open library"),
                callback = function() self:onShowLibrary() end,
            },
            {
                text = _("Search library"),
                callback = function() self:onSearchLibrary() end,
            },
            {
                text = _("Rescan library"),
                keep_menu_open = true,
                callback = function() self:onRescanLibrary() end,
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
                        self:invalidate()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end, self:getRoot(), filemanagerutil.getHomeFolder())
                end,
            },
            {
                text_func = function()
                    return T(_("Sort books by: %1"), SORT_NAMES[self.settings.sort] or self.settings.sort)
                end,
                sub_item_table_func = function() return self:genSortMenu() end,
            },
            {
                text = _("Include hidden folders"),
                checked_func = function() return self.settings.show_hidden end,
                callback = function()
                    self.settings.show_hidden = not self.settings.show_hidden
                    self:saveSettings()
                    self:invalidate()
                end,
            },
        },
    }
end

function Library:genSortMenu()
    local items = {}
    for _, mode in ipairs(Core.SORTS) do
        table.insert(items, {
            text = SORT_NAMES[mode],
            checked_func = function() return self.settings.sort == mode end,
            radio = true,
            callback = function()
                self.settings.sort = mode
                self:saveSettings()
            end,
        })
    end
    return items
end

----------------------------------------------------------------------------
-- Data
----------------------------------------------------------------------------

function Library:invalidate()
    shared.books = nil
    shared.root = nil
    BookList.book_info_cache = {}
end

function Library:isBook(path)
    return DocumentRegistry:hasProvider(path)
end

function Library:getStatus(path)
    if self.ui.document and self.ui.document.file == path and self.ui.doc_settings then
        local summary = self.ui.doc_settings:readSetting("summary")
        return summary and summary.status or "reading"
    end
    return BookList.getBookStatus(path)
end

function Library:getProps(path)
    local ok, props = pcall(self.ui.bookinfo.getDocProps, self.ui.bookinfo, path, nil, true)
    if ok then return props end
    logger.warn("Library: cannot read metadata for", path, props)
    return nil
end

--- Scan if needed, then call `callback()` once books are available.
function Library:withBooks(callback, force)
    local root = self:getRoot()
    if not force and shared.books and shared.root == root then
        return callback()
    end
    local msg = InfoMessage:new{ text = _("Scanning library…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, err = pcall(function()
            local books, truncated = Core.scan(root, lfs, function(p) return self:isBook(p) end, {
                max_depth = self.settings.max_depth,
                show_hidden = self.settings.show_hidden,
            })
            Core.enrich(books,
                function(p) return self:getProps(p) end,
                function(p) return self:getStatus(p) end)
            shared.books, shared.root, shared.truncated = books, root, truncated
        end)
        UIManager:close(msg)
        if not ok then
            logger.err("Library: scan failed", err)
            UIManager:show(InfoMessage:new{ text = _("Library scan failed. See crash.log for details.") })
            return
        end
        if shared.truncated then
            UIManager:show(InfoMessage:new{
                text = T(_("Only the first %1 books were indexed."), #shared.books),
                timeout = 3,
            })
        end
        callback()
    end)
end

----------------------------------------------------------------------------
-- Views
----------------------------------------------------------------------------

local function collate(a, b)
    return ffiUtil.strcoll(a, b)
end

function Library:createMenu()
    local menu
    menu = BookList:new{
        name = "library",
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function() self:onSearchLibrary() end,
        ui = self.ui,
        search_callback = function(query) self:showSearchResults(query) end,
    }
    menu.paths = {}
    menu.onMenuSelect = function(_menu, item)
        if item.file then
            filemanagerutil.openFile(self.ui, item.file, function() menu:onClose() end)
        elseif item.callback then
            table.insert(menu.paths, { view = self.current_view, page = menu.page })
            item.callback()
        end
        return true
    end
    menu.onMenuHold = function(_menu, item)
        if item.file then self:showBookDialog(item) end
        return true
    end
    menu.onReturn = function()
        local prev = table.remove(menu.paths)
        if prev then
            self:render(prev.view, prev.page)
        end
    end
    menu.close_callback = function()
        UIManager:close(menu)
        if self.menu == menu then self.menu = nil end
    end
    -- BookList's close button calls onClose, which walks Menu's own stack; we keep ours.
    menu.onClose = function()
        menu.close_callback()
        return true
    end
    self.menu = menu
    UIManager:show(menu)
    return menu
end

--- A view is `{ title=, subtitle=, items=function() -> item_table }`.
function Library:render(view, page)
    self.current_view = view
    local items = view.items()
    local itemnumber
    if page and page > 1 and self.menu.perpage then
        itemnumber = (page - 1) * self.menu.perpage + 1
    end
    self.menu:switchItemTable(view.title, items, itemnumber, nil, view.subtitle or "")
end

function Library:show(view)
    if not self.menu then self:createMenu() end
    self.menu.paths = {}
    self:render(view)
end

function Library:bookItems(books, opts)
    opts = opts or {}
    local sorted = opts.keep_order and books or Core.sortBooks(books, opts.sort or self.settings.sort, collate)
    local items = {}
    for _, book in ipairs(sorted) do
        local mandatory
        if opts.show_status then
            mandatory = BookList.getBookStatusString(book.status, false, true) or BookList.getBookStatusString("new")
        else
            mandatory = book.ext:upper()
        end
        table.insert(items, {
            text = Core.label(book, opts.show_series_index),
            file = book.path,
            mandatory = mandatory,
            mandatory_dim = book.status == "complete" or nil,
        })
    end
    return items
end

function Library:groupLabel(grouping, key)
    if key == Core.UNKNOWN then
        return ({ author = _("Unknown author"), series = _("No series"), format = _("No extension") })[grouping]
            or _("Unknown")
    end
    if grouping == "status" then
        return BookList.getBookStatusString(key) or key
    elseif grouping == "format" then
        return key:upper()
    elseif grouping == "folder" then
        return key == "" and _("(library root)") or BD.directory(key)
    end
    return key
end

function Library:homeView()
    local counts = Core.countByStatus(shared.books)
    local view = {
        title = T(_("Library (%1)"), #shared.books),
        subtitle = BD.dirpath(filemanagerutil.abbreviate(shared.root)),
    }
    view.items = function()
        local items = {
            {
                text = _("All books"),
                mandatory = tostring(#shared.books),
                callback = function() self:render(self:booksView(_("All books"), shared.books)) end,
            },
            {
                text = _("Currently reading"),
                mandatory = tostring(counts.reading),
                callback = function()
                    local reading = {}
                    for _, b in ipairs(shared.books) do
                        if b.status == "reading" then table.insert(reading, b) end
                    end
                    self:render(self:booksView(_("Currently reading"), reading))
                end,
            },
            {
                text = _("Recently added"),
                mandatory = tostring(math.min(self.settings.recent_count, #shared.books)),
                callback = function()
                    self:render(self:booksView(_("Recently added"),
                        Core.recent(shared.books, self.settings.recent_count), { keep_order = true }))
                end,
            },
        }
        for _, grouping in ipairs(Core.GROUPINGS) do
            local groups = Core.group(shared.books, grouping, collate)
            table.insert(items, {
                text = GROUP_NAMES[grouping],
                mandatory = tostring(#groups),
                callback = function() self:render(self:groupsView(grouping, groups)) end,
            })
        end
        return items
    end
    return view
end

function Library:groupsView(grouping, groups)
    return {
        title = T(_("%1 (%2)"), GROUP_NAMES[grouping], #groups),
        items = function()
            local items = {}
            for _, group in ipairs(groups) do
                local label = self:groupLabel(grouping, group.key)
                table.insert(items, {
                    text = label,
                    mandatory = tostring(#group.books),
                    callback = function()
                        local opts = {}
                        if grouping == "series" and group.key ~= Core.UNKNOWN then
                            opts.sort = "series"
                            opts.show_series_index = true
                        elseif grouping == "status" then
                            opts.show_status = false
                        end
                        self:render(self:booksView(label, group.books, opts))
                    end,
                })
            end
            return items
        end,
    }
end

function Library:booksView(title, books, opts)
    opts = opts or {}
    if opts.show_status == nil then opts.show_status = true end
    return {
        title = T(_("%1 (%2)"), title, #books),
        subtitle = opts.subtitle,
        items = function() return self:bookItems(books, opts) end,
    }
end

function Library:showSearchResults(query)
    self:withBooks(function()
        local results = Core.search(shared.books, query)
        local view = self:booksView(_("Search results"), results, { subtitle = T(_("Query: %1"), query) })
        if self.menu then
            table.insert(self.menu.paths, { view = self.current_view, page = self.menu.page })
            self:render(view)
        else
            self:show(self:homeView())
            table.insert(self.menu.paths, { view = self.current_view, page = 1 })
            self:render(view)
        end
    end)
end

----------------------------------------------------------------------------
-- Book actions (long-press)
----------------------------------------------------------------------------

function Library:refreshBook(path)
    BookList.resetBookInfoCache(path)
    for _, b in ipairs(shared.books or {}) do
        if b.path == path then
            b.status = self:getStatus(path)
            if not Core.isKnownStatus(b.status) then b.status = "reading" end
        end
    end
end

function Library:showBookDialog(item)
    local file = item.file
    local dialog
    local function close() UIManager:close(dialog) end
    local function after_status_change()
        close()
        self:refreshBook(file)
        if self.menu and self.current_view then
            self:render(self.current_view, self.menu.page)
        end
    end
    local been_opened = BookList.hasBookBeenOpened(file)
    local doc_settings_or_file = been_opened and BookList.getDocSettings(file) or file
    local props = self:getProps(file)
    local buttons = {
        filemanagerutil.genStatusButtonsRow(doc_settings_or_file, after_status_change),
        {},
        {
            filemanagerutil.genShowFolderButton(file, function()
                close()
                if self.menu then self.menu:onClose() end
            end),
            filemanagerutil.genBookInformationButton(doc_settings_or_file, props, close),
        },
        {
            {
                text = _("Open"),
                callback = function()
                    close()
                    filemanagerutil.openFile(self.ui, file, function()
                        if self.menu then self.menu:onClose() end
                    end)
                end,
            },
        },
    }
    dialog = ButtonDialog:new{
        title = BD.filename(item.text),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

function Library:onShowLibrary()
    self:withBooks(function() self:show(self:homeView()) end)
    return true
end

function Library:onRescanLibrary()
    self:invalidate()
    self:withBooks(function()
        UIManager:show(InfoMessage:new{
            text = T(_("Library rescanned: %1 books."), #shared.books),
            timeout = 2,
        })
        if self.menu then self:show(self:homeView()) end
    end, true)
    return true
end

function Library:onSearchLibrary()
    local dialog
    dialog = InputDialog:new{
        title = _("Search library"),
        input_hint = _("Title, author, series, keyword or file name"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        if query and query:match("%S") then
                            self:showSearchResults(query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

-- Keep statuses fresh when a book is closed or its status changes elsewhere.
function Library:onCloseDocument()
    if self.ui.document and shared.books then
        self:refreshBook(self.ui.document.file)
    end
end

function Library:onBookMetadataChanged()
    -- Titles/authors may have changed; rebuild lazily on next open.
    if shared.books then
        shared.books = nil
    end
end

return Library
