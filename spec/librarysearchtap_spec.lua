-- Regression: tapping the search bar crashed KOReader on the Kindle Colorsoft
-- (v2026.07.1): "inputtext.lua:161: attempt to call method
-- 'getFocusableWidgetXY' (a nil value)". On devices KOReader treats as having
-- a D-pad, InputText's tap handler asks its parent widget (our LibraryView)
-- for FocusManager methods.
--
-- LibraryView needs KOReader's UI modules, so they are stubbed here; only the
-- class table is under test.

local function stub()
    local t = {}
    return setmetatable(t, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function withStubbedUI(fn)
    local saved_loaded, saved_preload = {}, {}
    local real = {
        libraryview = true, librarycore = true, librarytile = true, librarycovers = true,
        string = true, table = true, math = true, io = true, os = true,
    }
    local base_class = {}
    base_class.__index = base_class
    function base_class:extend(o)
        o = o or {}
        o.__index = o
        return setmetatable(o, self)
    end
    local function loader(name)
        if name == "ui/widget/container/inputcontainer" then return base_class end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
        return stub()
    end
    local old_require = require
    _G.require = function(name)
        if real[name] then return old_require(name) end
        return loader(name)
    end
    package.loaded.libraryview = nil
    local ok, err = pcall(fn)
    _G.require = old_require
    package.loaded.libraryview = nil
    if not ok then error(err, 0) end
end

-- KOReader v2026.07.1 frontend/ui/widget/inputtext.lua, InputText:onTapTextBox
-- lines 146-167 (the D-pad branch), verbatim apart from the stand-ins.
local FORCED_FOCUS = 2
local function onTapTextBox(inputtext, has_dpad)
    if inputtext.parent.onSwitchFocus then
        inputtext.parent:onSwitchFocus(inputtext)
    end
    if has_dpad then
        local x, y = inputtext.parent:getFocusableWidgetXY(inputtext)
        if x and y then
            inputtext.parent:moveFocusTo(x, y, FORCED_FOCUS)
        end
    end
    return true
end

describe("search bar tap on a D-pad device", function()
    it("does not crash (Colorsoft crash.log 29 Oct 2026)", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local switched, moved = 0, 0
            local view = setmetatable({}, LibraryView)
            view.onSwitchFocus = function() switched = switched + 1 end
            local old_move = LibraryView.moveFocusTo
            view.moveFocusTo = function(...) moved = moved + 1; return old_move and old_move(...) end
            local input = { parent = view }
            local ok, err = pcall(onTapTextBox, input, true)
            eq(ok, true, tostring(err))
            eq(switched, 1, "keyboard still opens")
            eq(moved, 0, "no D-pad focus to move: the search bar is the only focusable widget")
        end)
    end)

    it("still works on touch-only devices", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local view = setmetatable({ onSwitchFocus = function() end }, LibraryView)
            eq(pcall(onTapTextBox, { parent = view }, false), true)
        end)
    end)

    it("answers FocusManager's questions without side effects", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local view = setmetatable({}, LibraryView)
            eq(type(LibraryView.getFocusableWidgetXY), "function")
            eq(type(LibraryView.moveFocusTo), "function")
            eq(view:getFocusableWidgetXY({}), nil)
            eq(view:moveFocusTo(1, 1, FORCED_FOCUS), false)
        end)
    end)
end)

describe("tapping a search result", function()
    it("hides the keyboard before opening the book", function()
        withStubbedUI(function()
            local LibraryView = require("libraryview")
            local view = setmetatable({}, LibraryView)
            local log = {}
            view.search_input = {
                isKeyboardVisible = function() return true end,
                onCloseKeyboard = function() table.insert(log, "close keyboard") end,
                unfocus = function() table.insert(log, "unfocus") end,
            }
            view.is_always_active = true
            view.plugin = { openBook = function(_, path) table.insert(log, "open " .. path) end }
            view:onTileTap({ book = { path = "/b.epub" } })
            eq(log[1], "close keyboard")
            eq(log[#log], "open /b.epub")
            eq(view.is_always_active, false)
        end)
    end)
end)
