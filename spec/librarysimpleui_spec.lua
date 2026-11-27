-- SimpleUI keeps its own Library tab. When the setting is on, Library GUI
-- adds a separate navigation action that can be put in that slot.
local SimpleUI = require("librarysimpleui")

local QA_NAME = SimpleUI.QA_NAME
local CONFIG_NAME = SimpleUI.CONFIG_NAME
local PATH = "/plugins/simpleui.koplugin/?.lua"

local function fakeQA(with_delegate)
    local registry = {}
    local calls = { unregister = {}, delegate = {} }
    local QA = {}
    function QA.register(desc)
        registry[desc.id] = desc
    end
    function QA.unregister(id)
        calls.unregister[#calls.unregister + 1] = id
        if id == "home" then
            calls.refused_builtin = id
            return
        end
        registry[id] = nil
    end
    function QA.isRegistered(id)
        return registry[id] ~= nil
    end
    function QA.isBuiltin(id)
        return id == "home"
    end
    if with_delegate ~= false then
        function QA.setBuiltinDelegate(builtin_id, external_id)
            calls.delegate[#calls.delegate + 1] = { builtin_id, external_id }
        end
    end
    function QA.get(id)
        return registry[id]
    end
    QA.calls = calls
    return QA
end

local function harness(QA, extra)
    extra = extra or {}
    local loaded = {}
    local Config = extra.config or { invalidated = 0 }
    if type(Config) == "table" and Config.invalidateTabsCache == nil then
        function Config.invalidateTabsCache()
            Config.invalidated = Config.invalidated + 1
        end
    end
    local rebuilt = 0
    local plugin = extra.simpleui
    if plugin == nil then
        plugin = {
            _scheduleRebuild = function() rebuilt = rebuilt + 1 end,
        }
    end
    local function load(name)
        loaded[#loaded + 1] = name
        if name == QA_NAME then return QA end
        if name == CONFIG_NAME then return Config end
        return nil
    end
    return {
        load = load,
        loaded = loaded,
        config = Config,
        plugin = plugin,
        rebuilt = function() return rebuilt end,
    }
end

describe("SimpleUI library action", function()
    it("stays off unless the setting is explicitly on", function()
        eq(SimpleUI.enabled(nil), false)
        eq(SimpleUI.enabled({}), false)
        eq(SimpleUI.enabled({ simpleui_library = false }), false)
        eq(SimpleUI.enabled({ simpleui_library = "yes" }), false)
        eq(SimpleUI.enabled({ simpleui_library = true }), true)
    end)

    it("notices SimpleUI only when its plugin folder is on the search path", function()
        eq(SimpleUI.installed(nil), false)
        eq(SimpleUI.installed(""), false)
        eq(SimpleUI.installed("/koreader/plugins/library.koplugin/?.lua"), false)
        eq(SimpleUI.installed(PATH), true)
        eq(SimpleUI.installed("plugins/simpleui.koplugin/?.lua;plugins/library.koplugin/?.lua"), true)
    end)

    it("does nothing when SimpleUI is not installed, even if the setting is on", function()
        local QA = fakeQA()
        local h = harness(QA)
        eq(SimpleUI.sync({
            settings = { simpleui_library = true },
            path = "/plugins/library.koplugin/?.lua",
            load = h.load,
            simpleui = false,
        }), "absent")
        eq(#h.loaded, 0)
        eq(SimpleUI.sync({
            settings = {},
            path = "/plugins/library.koplugin/?.lua",
            load = h.load,
            simpleui = false,
        }), "absent")
        eq(#h.loaded, 0)
        eq(QA.isRegistered(SimpleUI.ACTION_ID), false)
    end)

    it("registers Library GUI and does not try to remove SimpleUI's Library tab", function()
        local opened = 0
        local QA = fakeQA()
        local h = harness(QA)
        eq(SimpleUI.sync({
            settings = { simpleui_library = true },
            path = PATH,
            load = h.load,
            open = function() opened = opened + 1 end,
            simpleui = h.plugin,
        }), "registered")
        local desc = QA.get(SimpleUI.ACTION_ID)
        eq(desc.id, "library_gui")
        eq(desc.label, "Library GUI")
        eq(desc.icon, "nerd:F405")
        eq(desc.is_in_place, false)
        eq(QA.isRegistered("home"), false)
        eq(#QA.calls.unregister, 0)
        desc.execute({})
        eq(opened, 1)
        desc.execute({})
        local function boom() error("library failed") end
        QA.register(SimpleUI.descriptor(boom))
        QA.get(SimpleUI.ACTION_ID).execute({})
        eq(h.config.invalidated, 1)
        eq(h.rebuilt(), 1)
        eq(QA.calls.delegate[1][1], "home")
        eq(QA.calls.delegate[1][2], "library_gui")
    end)

    it("still registers when SimpleUI has no home-tab delegate", function()
        local QA = fakeQA(false)
        local h = harness(QA)
        eq(QA.setBuiltinDelegate, nil)
        eq(SimpleUI.sync({
            settings = { simpleui_library = true },
            path = PATH,
            load = h.load,
            open = function() end,
            simpleui = false,
            config = false,
        }), "registered")
        eq(QA.isRegistered("library_gui"), true)
        eq(h.config.invalidated, 0)
    end)

    it("removes only the Library GUI action when the setting is turned off", function()
        local QA = fakeQA()
        local h = harness(QA)
        SimpleUI.sync({
            settings = { simpleui_library = true },
            path = PATH,
            load = h.load,
            open = function() end,
            simpleui = h.plugin,
        })
        eq(SimpleUI.sync({
            settings = { simpleui_library = false },
            path = PATH,
            load = h.load,
            simpleui = h.plugin,
        }), "unregistered")
        eq(QA.isRegistered("library_gui"), false)
        eq(QA.calls.unregister[1], "library_gui")
        eq(QA.calls.refused_builtin, nil)
        eq(QA.calls.delegate[#QA.calls.delegate][1], "home")
        eq(QA.calls.delegate[#QA.calls.delegate][2], nil)
        eq(h.config.invalidated, 2)
        eq(h.rebuilt(), 2)
    end)

    it("leaves a missing action list alone when the setting is off", function()
        local h = harness(nil)
        eq(SimpleUI.sync({
            settings = { simpleui_library = false },
            path = PATH,
            load = function() return nil end,
            simpleui = false,
        }), "absent")
        eq(h.rebuilt(), 0)
    end)

    it("opens the reader copy while a book is open, and the file browser otherwise", function()
        local reader_key = "apps/reader/readerui"
        local fm_key = "apps/filemanager/filemanager"
        local prev_reader, prev_fm = package.loaded[reader_key], package.loaded[fm_key]
        local log = {}
        local reader_lib = { onShowLibrary = function() log[#log + 1] = "reader" end }
        local fm_lib = { onShowLibrary = function() log[#log + 1] = "fm" end }
        package.loaded[reader_key] = {
            instance = { document = { file = "/books/Emma.epub" }, library = reader_lib },
        }
        package.loaded[fm_key] = { instance = { library = fm_lib } }
        SimpleUI.openFromRunningUI()
        package.loaded[reader_key] = { instance = { library = reader_lib } }
        SimpleUI.openFromRunningUI()
        package.loaded[reader_key] = nil
        SimpleUI.openFromRunningUI()
        -- KOReader may expose the handler as a callable table, not a function.
        local table_called = false
        local handler = setmetatable({}, {
            __call = function() table_called = true; return true end,
        })
        package.loaded[fm_key] = { instance = { library = { onShowLibrary = handler } } }
        SimpleUI.openFromRunningUI()
        package.loaded[reader_key] = prev_reader
        package.loaded[fm_key] = prev_fm
        eq(table.concat(log, ","), "reader,fm,fm")
        eq(table_called, true)
    end)

    it("finds SimpleUI on the file browser, then on the reader", function()
        local reader_key = "apps/reader/readerui"
        local fm_key = "apps/filemanager/filemanager"
        local prev_reader, prev_fm = package.loaded[reader_key], package.loaded[fm_key]
        local on_fm = {}
        local on_reader = {}
        package.loaded[fm_key] = { instance = { simpleui = on_fm } }
        package.loaded[reader_key] = { instance = { simpleui = on_reader } }
        eq(SimpleUI.findSimpleUI(), on_fm)
        package.loaded[fm_key] = { instance = { _simpleui_plugin = on_fm } }
        eq(SimpleUI.findSimpleUI(), on_fm)
        package.loaded[fm_key] = nil
        eq(SimpleUI.findSimpleUI(), on_reader)
        package.loaded[reader_key] = prev_reader
        package.loaded[fm_key] = prev_fm
    end)
end)

describe("Use as SimpleUI library page", function()
    local function stub()
        return setmetatable({}, {
            __index = function() return stub() end,
            __call = function() return stub() end,
        })
    end

    local function loadMain()
        local old_require = require
        local real = { librarycore = true, librarysimpleui = true, string = true, table = true, math = true }
        _G.require = function(name)
            if real[name] then return old_require(name) end
            if name == "gettext" then return function(s) return s end end
            if name == "ffi/util" then
                return { template = function(s) return s end }
            end
            return stub()
        end
        local ok, mod = pcall(dofile, "library.koplugin/main.lua")
        _G.require = old_require
        if not ok then error(mod, 0) end
        return mod
    end

    local function menuItem(items, text)
        for _, item in ipairs(items.library.sub_item_table) do
            if item.text == text then return item end
        end
    end

    it("is off in the Library menu until it is turned on, then registers", function()
        local Library = loadMain()
        local items = {}
        local self = setmetatable({
            settings = {},
            ui = { menu = {} },
            saveSettings = function() end,
            barelyMenu = function() return {} end,
            topRowMenu = function() return {} end,
            sleepCoverMenu = function() return {} end,
        }, { __index = Library })
        Library.addToMainMenu(self, items)
        local item = menuItem(items, "Use as SimpleUI library page")
        eq(item ~= nil, true)
        eq(item.checked_func(), false)

        local QA = fakeQA()
        local h = harness(QA)
        local prev_path = package.path
        local prev_qa = package.preload[QA_NAME]
        local prev_cfg = package.preload[CONFIG_NAME]
        local prev_fm = package.loaded["apps/filemanager/filemanager"]
        package.path = PATH .. ";" .. package.path
        package.preload[QA_NAME] = function() return QA end
        package.preload[CONFIG_NAME] = function() return h.config end
        package.loaded["apps/filemanager/filemanager"] = { instance = { simpleui = h.plugin } }
        item.callback()
        eq(self.settings.simpleui_library, true)
        eq(item.checked_func(), true)
        eq(QA.get("library_gui").label, "Library GUI")
        eq(h.rebuilt(), 1)
        item.callback()
        eq(self.settings.simpleui_library, false)
        eq(QA.isRegistered("library_gui"), false)
        eq(QA.calls.unregister[1], "library_gui")
        eq(QA.calls.refused_builtin, nil)
        package.path = prev_path
        package.preload[QA_NAME] = prev_qa
        package.preload[CONFIG_NAME] = prev_cfg
        package.loaded[QA_NAME] = nil
        package.loaded[CONFIG_NAME] = nil
        package.loaded["apps/filemanager/filemanager"] = prev_fm
    end)
end)
