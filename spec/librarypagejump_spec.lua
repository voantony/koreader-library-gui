-- Tapping the footer's "63 / 72" opens a Go to page box. The plugin manager
-- lists it as "Library GUI"; on the device the menu and header stay "Library".
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, string = true, table = true, math = true }
    _G.require = function(name)
        if extra[name] ~= nil then return extra[name] end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then
            return { template = function(s, ...)
                local a = { ... }
                return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
            end }
        end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/" .. file)
    _G.require = old_require
    if not ok then error(mod, 0) end
    return mod
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o) o = o or {}; return setmetatable(o, self) end
    return base
end

local function mainWith(shown, closed)
    return load("main.lua", {
        ["ui/uimanager"] = {
            show = function(_, w) shown[#shown + 1] = w end,
            close = function(_, w) closed[#closed + 1] = w end,
        },
        ["ui/widget/container/widgetcontainer"] = cls(),
    })
end

local function jumpDialog(typed, pages)
    local shown, closed, went = {}, {}, {}
    local Library = mainWith(shown, closed)
    local InputDialog = { new = function(_, o)
        o.getInputText = function() return typed end
        o.onShowKeyboard = function() o.keyboard = true end
        return o
    end }
    package.loaded["ui/widget/inputdialog"] = InputDialog
    local view = { pages = pages or 72 }
    function view:goToPage(n) went[#went + 1] = n end
    local self = setmetatable({ settings = {} }, { __index = Library })
    local dialog = Library.showPageJump(self, view)
    package.loaded["ui/widget/inputdialog"] = nil
    local go = dialog.buttons[1][2]
    return dialog, go, went, shown, closed
end

describe("Go to page from the footer", function()
    it("opens a number box with the page range and the keyboard up", function()
        local dialog, go, _w, shown = jumpDialog("", 72)
        eq(shown[1], dialog)
        eq(dialog.title, "Go to page")
        eq(dialog.input_type, "number")
        eq(dialog.input_hint, "1 – 72")
        eq(go.text, "Go")
        eq(dialog.keyboard, true)
    end)

    it("Go jumps to the typed page and closes", function()
        local dialog, go, went, _s, closed = jumpDialog("63")
        go.callback()
        same(went, { 63 })
        eq(closed[1], dialog)
    end)

    it("ignores text that is not a number", function()
        local _d, go, went, _s, closed = jumpDialog("abc")
        go.callback()
        eq(#went, 0); eq(#closed, 0)
    end)

    it("out-of-range pages are clamped by goToPage", function()
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            util = { stringLower = function(s) return s:lower() end },
        })
        local v = setmetatable({ page = 2, pages = 10 }, { __index = View })
        v.refreshBody = function() end
        v:goToPage(99); eq(v.page, 10)
        v:goToPage(-3); eq(v.page, 1)
    end)
end)

describe("LibraryView page label", function()
    local View = load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = cls(),
        util = { stringLower = function(s) return s:lower() end },
    })
    it("tapping it hides the search keyboard and asks the plugin for the box", function()
        local calls = {}
        local v = setmetatable({ pages = 5 }, { __index = View })
        v.keyboardGuard = function() calls[#calls + 1] = "keyboard" end
        v.plugin = { showPageJump = function(_, view) calls[#calls + 1] = "jump"; eq(view, v) end }
        v:showPageJump()
        same(calls, { "keyboard", "jump" })
    end)

    it("does nothing on a single page", function()
        local v = setmetatable({ pages = 1 }, { __index = View })
        v.keyboardGuard = function() error("should not run") end
        v.plugin = { showPageJump = function() error("should not run") end }
        v:showPageJump()
    end)
end)

describe("Plugin name", function()
    it("shows as Library GUI in plugin management", function()
        local meta = load("_meta.lua", {})
        eq(meta.fullname, "Library GUI")
        assert(meta.description:find("Library GUI", 1, true), "description names Library GUI")
    end)

    it("the main menu entry and its Open item stay plain Library", function()
        local Library = mainWith({}, {})
        local self = setmetatable({ settings = {}, ui = {} }, { __index = Library })
        self.barelyMenu = function() return {} end
        self.topRowMenu = function() return {} end
        self.sleepCoverMenu = function() return {} end
        local items = {}
        Library.addToMainMenu(self, items)
        eq(items.library.text, "Library")
        eq(items.library.sub_item_table[1].text, "Open Library")
    end)
end)
