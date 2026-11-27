--[[--
Opt-in SimpleUI navigation action.

SimpleUI's Library tab is its built-in quick action "home". Another plugin
cannot remove that action. SimpleUI does let another plugin add its own
action, which a person can then put on the bottom bar in the Library
tab's place.

When "Use as SimpleUI library page" is on, and SimpleUI's folder is on
the Lua search path (KOReader adds that folder only while the plugin is
enabled), this module registers the action "library_gui". The label is
"Library GUI", so it is distinct from SimpleUI's own "Library" row in
the tab list. Tapping it opens this plugin's Library. The same call is
made again on every start: SimpleUI keeps the list in memory only.

If SimpleUI offers setBuiltinDelegate, the built-in "home" action is
pointed at this one as well. That function is not in SimpleUI 3.1.1.
Stock SimpleUI needs the tab swap described in the README.

Nothing here is loaded from SimpleUI, and nothing is registered when
SimpleUI is absent or the setting is off.
]]

local M = {}

M.ACTION_ID = "library_gui"
M.QA_NAME = "features/sui_quickactions"
M.CONFIG_NAME = "infra/sui_config"
-- Nerd Font private-use book glyph. SimpleUI draws any "nerd:" codepoint
-- on a tab; this is not one of its icon files.
M.ICON = "nerd:F405"

local function translate(text)
    local ok, gettext = pcall(require, "gettext")
    if ok and type(gettext) == "function" then
        return gettext(text)
    end
    return text
end

local function warn(message)
    local ok, logger = pcall(require, "logger")
    if ok and type(logger) == "table" and type(logger.warn) == "function" then
        logger.warn(message)
    end
end

--- True only when the setting has been turned on. Nil and false stay off,
-- including a settings table saved before this key existed.
function M.enabled(settings)
    return type(settings) == "table" and settings.simpleui_library == true
end

--- True when an enabled simpleui.koplugin is on Lua's search path.
function M.installed(path)
    if type(path) ~= "string" then return false end
    return path:find("simpleui%.koplugin", 1) ~= nil
end

function M.descriptor(open)
    return {
        id = M.ACTION_ID,
        label = translate("Library GUI"),
        icon = M.ICON,
        is_in_place = false,
        execute = function(_ctx)
            if type(open) ~= "function" then return end
            local ok, err = pcall(open)
            if not ok then
                warn("Library: SimpleUI action failed: " .. tostring(err))
            end
        end,
    }
end

--- Call onShowLibrary when the UI has one. KOReader can surface that
-- handler as a callable table rather than a function, so a type check
-- of "function" would skip the live plugin and leave the tab inert.
-- Returns true when a handler was found and called. The handler's own
-- return value is not used: a missing return must not fall through to
-- another UI.
local function showLibrary(ui)
    if type(ui) ~= "table" or ui.onShowLibrary == nil then return false end
    ui:onShowLibrary()
    return true
end

--- The live Library plugin: the reader while a book is open, otherwise
-- the file browser. KOReader keeps each copy on that UI as `.library`.
function M.openFromRunningUI()
    local reader = package.loaded["apps/reader/readerui"]
    local rui = reader and reader.instance
    if rui and rui.document and showLibrary(rui.library) then return true end
    local fm_mod = package.loaded["apps/filemanager/filemanager"]
    local fm = fm_mod and fm_mod.instance
    if fm and showLibrary(fm.library) then return true end
    if rui and showLibrary(rui.library) then return true end
    return nil
end

function M.findSimpleUI()
    local fm_mod = package.loaded["apps/filemanager/filemanager"]
    local fm = fm_mod and fm_mod.instance
    if type(fm) == "table" then
        if type(fm.simpleui) == "table" then return fm.simpleui end
        if type(fm._simpleui_plugin) == "table" then return fm._simpleui_plugin end
    end
    local reader = package.loaded["apps/reader/readerui"]
    local rui = reader and reader.instance
    if type(rui) == "table" and type(rui.simpleui) == "table" then
        return rui.simpleui
    end
    return nil
end

--- Drop SimpleUI's cached tab list and ask it to redraw the bar, when
-- those entry points exist. A saved tab id is ignored until the action
-- is registered and this cache is cleared.
function M.refreshTabs(opts)
    opts = opts or {}
    local Config = opts.config
    if Config == nil and type(opts.load) == "function" then
        local ok, mod = pcall(opts.load, M.CONFIG_NAME)
        if ok then Config = mod end
    elseif Config == nil then
        Config = package.loaded[M.CONFIG_NAME]
    end
    if type(Config) == "table" and type(Config.invalidateTabsCache) == "function" then
        Config.invalidateTabsCache()
    end
    local plugin = opts.simpleui
    if plugin == nil then plugin = M.findSimpleUI() end
    if type(plugin) == "table" and type(plugin._scheduleRebuild) == "function" then
        pcall(plugin._scheduleRebuild, plugin)
    end
end

local function loadQA(opts)
    local loadmod = opts.load or require
    local ok, QA = pcall(loadmod, M.QA_NAME)
    if not ok or type(QA) ~= "table" then return nil end
    return QA
end

local function pointHomeAt(QA, external_id)
    if type(QA) ~= "table" or type(QA.setBuiltinDelegate) ~= "function" then
        return
    end
    pcall(QA.setBuiltinDelegate, "home", external_id)
end

--- Register or remove the action so it matches the setting.
-- Returns "registered", "unregistered", or "absent".
-- `opts.load` replaces `require` (tests). `opts.path` replaces `package.path`.
-- `opts.open` is the function the action runs. `opts.simpleui` is the
-- SimpleUI plugin instance, when the caller already has it; false skips
-- the lookup. `opts.config` is SimpleUI's config module, when already loaded.
function M.sync(opts)
    opts = opts or {}
    local path = opts.path
    if path == nil then path = package.path end
    local want = M.enabled(opts.settings) and M.installed(path)
    if not want then
        if not M.installed(path) then return "absent" end
        local QA
        if opts.load then
            QA = loadQA(opts)
        else
            QA = package.loaded[M.QA_NAME]
        end
        if type(QA) ~= "table" or type(QA.unregister) ~= "function" then
            return "absent"
        end
        local was = type(QA.isRegistered) == "function" and QA.isRegistered(M.ACTION_ID) == true
        QA.unregister(M.ACTION_ID)
        pointHomeAt(QA, nil)
        if was then M.refreshTabs(opts) end
        return "unregistered"
    end
    local QA = loadQA(opts)
    if not QA or type(QA.register) ~= "function" then
        warn("Library: SimpleUI is installed but its action list could not be loaded")
        return "absent"
    end
    local open = opts.open or M.openFromRunningUI
    QA.register(M.descriptor(open))
    pointHomeAt(QA, M.ACTION_ID)
    M.refreshTabs(opts)
    return "registered"
end

return M
