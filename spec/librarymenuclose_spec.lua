-- Closing a menu or dialog over the Library must leave the Library on
-- top, repaint the Library (never the file browser under it), and request
-- a full-screen flash only after the dialog's own refresh has been painted.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra, real_extra)
    local old_require = require
    local real = {
        librarycore = true, libraryzones = true, libraryindex = true,
        librarygestures = true, librarywidgets = true, libraryrefresh = true,
        libraryreadermenu = true,
        string = true, table = true, math = true,
    }
    if real_extra then
        for k, v in pairs(real_extra) do real[k] = v end
    end
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

-- A window stack with the file browser under the Library. nextTick is
-- queued, not run: that is the frame where a dialog's own refresh is
-- painted. tickAfterNext is the frame after that.
local function world()
    local stack, ticks, later, dirty = {}, {}, {}, {}
    local UIManager = { _window_stack = stack }
    function UIManager:show(w)
        stack[#stack + 1] = { widget = w }
    end
    function UIManager:isWidgetShown(w)
        for i = 1, #stack do
            if stack[i].widget == w then return true end
        end
        return false
    end
    function UIManager:close(w)
        for i = #stack, 1, -1 do
            if stack[i].widget == w then
                table.remove(stack, i)
                if type(w.onCloseWidget) == "function" then w:onCloseWidget() end
                return
            end
        end
    end
    function UIManager:nextTick(fn) ticks[#ticks + 1] = fn end
    function UIManager:tickAfterNext(fn) later[#later + 1] = fn end
    function UIManager:setDirty(w, fn)
        local mode, rect = fn()
        dirty[#dirty + 1] = { w = w, mode = mode, rect = rect }
    end
    function UIManager:runTicks()
        local batch = ticks
        ticks = {}
        for i = 1, #batch do batch[i]() end
    end
    function UIManager:runAfter()
        local batch = later
        later = {}
        for i = 1, #batch do batch[i]() end
    end
    local function top()
        return stack[#stack] and stack[#stack].widget
    end
    return UIManager, stack, dirty, top
end

local function harness()
    local UIManager, stack, dirty, top = world()
    local Library = load("main.lua", {
        ["ui/uimanager"] = UIManager,
        ["ui/widget/buttondialog"] = {
            new = function(_, o)
                -- KOReader: Back and a tap outside both call onClose, which
                -- closes. A tap outside used to be the only path with a callback.
                function o:onClose()
                    UIManager:close(self)
                    return true
                end
                function o:onTapClose()
                    self:onClose()
                    return true
                end
                return o
            end,
        },
        ["ui/widget/container/widgetcontainer"] = cls(),
        ["ui/widget/inputdialog"] = {
            new = function(_, o)
                -- KOReader's onTap closes on a tap outside and returns nothing,
                -- so the tap falls through to whatever is underneath.
                function o:onTap() end
                function o:getInputText() return "" end
                function o:onShowKeyboard() end
                return o
            end,
        },
        ["librarydetails"] = {
            new = function(_, o)
                function o:onClose()
                    if self.on_close then self.on_close() end
                    return true
                end
                return o
            end,
        },
    })
    local flashes = {}
    local fm = { name = "filemanager", covers_fullscreen = true }
    local view = {
        name = "library",
        dimen = { x = 0, y = 0, w = 1264, h = 1680 },
        sort = "recent", view_mode = "grid", pages = 14,
        placeName = function() return "Books" end,
        viewKey = function() return "books" end,
        hasRemembered = function() return false end,
        footer_menu = { dimen = { x = 0, y = 1600, w = 80, h = 80 } },
        resort = function() end,
        setHomeWidgets = function() end,
        refreshData = function() end,
        setShowClock = function() end,
        flashOverlay = function(self)
            flashes[#flashes + 1] = self
        end,
    }
    UIManager:show(fm)
    UIManager:show(view)
    local self = setmetatable({
        settings = { columns = 4 },
        saveSettings = function() end,
        ui = {},
    }, { __index = Library })
    view.plugin = self
    Library.shared.view = view
    return {
        Library = Library, self = self, view = view, fm = fm,
        UIManager = UIManager, stack = stack, dirty = dirty, top = top,
        flashes = flashes,
    }
end

local function assertLibraryStays(h, dialog)
    -- The same-frame nextTick is only the "this input already closed a
    -- dialog" flag. The flash waits for the frame after the close repaint.
    eq(#h.flashes, 0, "flash waits until the close repaint has been painted")
    h.UIManager:runTicks()
    eq(#h.flashes, 0, "nextTick is too early to flash")
    eq(h.view._overlay_just_closed, nil)
    h.UIManager:runAfter()
    eq(#h.flashes, 1)
    eq(h.flashes[1], h.view, "the Library is what gets repainted")
    eq(h.flashes[1] == h.fm, false)
    eq(h.UIManager:isWidgetShown(h.view), true, "Library stays on top")
    eq(h.UIManager:isWidgetShown(h.fm), true, "file browser stays underneath")
    eq(h.top(), h.view)
    if dialog then eq(h.UIManager:isWidgetShown(dialog), false) end
    eq(#h.dirty, 0, "the close itself did not setDirty the file browser")
end

describe("Menu close repaints the Library", function()
    it("flashes the whole screen on the Library, not a menu rectangle", function()
        local dirty = {}
        local UIManager = {
            setDirty = function(_, w, fn)
                local mode, rect = fn()
                dirty[#dirty + 1] = { w = w, mode = mode, rect = rect }
            end,
        }
        local View = load("libraryview.lua", {
            ["ui/uimanager"] = UIManager,
            ["ui/widget/container/inputcontainer"] = cls(),
        })
        local v = setmetatable({
            dimen = { x = 0, y = 0, w = 1264, h = 1680 },
        }, { __index = View })
        v:flashOverlay()
        eq(#dirty, 1)
        eq(dirty[1].w, v)
        eq(dirty[1].mode, "full")
        eq(dirty[1].rect.x, 0)
        eq(dirty[1].rect.y, 0)
        eq(dirty[1].rect.w, 1264)
        eq(dirty[1].rect.h, 1680)
    end)

    it("the Library menu: a button, Back and a tap outside", function()
        local function press(which)
            local h = harness()
            h.Library.showLibraryMenu(h.self, h.view)
            local dialog = h.top()
            eq(dialog.buttons[#dialog.buttons][1].text, "\u{2715} Close Library")
            if which == "button" then
                -- Show clock closes the menu and stays on the Library.
                local found
                for _, row in ipairs(dialog.buttons) do
                    for _, b in ipairs(row) do
                        if b.text == "\u{2713} Show clock" or b.text == "Show clock" then found = b end
                    end
                end
                found.callback()
            elseif which == "back" then
                eq(dialog:onClose(), true)
            else
                eq(dialog:onTapClose(), true)
            end
            assertLibraryStays(h, dialog)
        end
        press("button")
        press("back")
        press("tap")
    end)

    it("Clock and battery: the button used to call UIManager:close, and there was no tap callback", function()
        local function press(which)
            local h = harness()
            h.Library.showStatusStyleDialog(h.self, h.view)
            local dialog = h.top()
            if which == "button" then
                dialog.buttons[1][1].callback()
            elseif which == "back" then
                eq(dialog:onClose(), true)
            else
                eq(dialog:onTapClose(), true)
            end
            assertLibraryStays(h, dialog)
        end
        press("button")
        press("back")
        press("tap")
    end)

    it("Updates: Back and a tap outside, which had no tap_close_callback", function()
        local function press(which)
            local h = harness()
            h.Library.showUpdatesMenu(h.self, h.view)
            local dialog = h.top()
            if which == "button" then
                dialog.buttons[2][1].callback() -- Off
            elseif which == "back" then
                eq(dialog:onClose(), true)
            else
                eq(dialog:onTapClose(), true)
            end
            assertLibraryStays(h, dialog)
        end
        press("button")
        press("back")
        press("tap")
    end)

    it("sort picker, widget picker and the book dialog", function()
        local h = harness()
        local dialog = h.Library.showSortPicker(h.self, h.view)
        dialog.buttons[1][1].callback()
        assertLibraryStays(h, dialog)

        h = harness()
        h.Library.showWidgetMenu(h.self, h.view, 1)
        dialog = h.top()
        eq(dialog:onClose(), true)
        assertLibraryStays(h, dialog)

        h = harness()
        h.Library.showWidgetMenu(h.self, h.view, 1)
        dialog = h.top()
        dialog.buttons[1][1].callback()
        assertLibraryStays(h, dialog)

        h = harness()
        package.loaded["ui/widget/booklist"] = {
            hasBookBeenOpened = function() return false end,
        }
        h.self:showBookDialog({ path = "/b.epub", title = "Emma", authors = { "Austen" } }, h.view)
        package.loaded["ui/widget/booklist"] = nil
        dialog = h.top()
        eq(dialog:onTapClose(), true)
        assertLibraryStays(h, dialog)
    end)

    it("Go to page: Cancel, and a tap outside no longer falls through", function()
        local h = harness()
        package.loaded["ui/widget/inputdialog"] = {
            new = function(_, o)
                function o:onTap() end
                function o:getInputText() return "" end
                function o:onShowKeyboard() end
                return o
            end,
        }
        local dialog = h.self:showPageJump(h.view)
        package.loaded["ui/widget/inputdialog"] = nil
        eq(dialog:onTap(), true, "the tap is consumed")
        dialog.buttons[1][1].callback() -- Cancel
        assertLibraryStays(h, dialog)
    end)

    it("Gestures: a choice hands off to the next dialog, Back and a tap close it", function()
        local h = harness()
        h.Library.showGestureMenu(h.self, h.view)
        local dialog = h.top()
        dialog.buttons[1][1].callback() -- top swipe → choices
        eq(h.UIManager:isWidgetShown(h.view), true)
        eq(h.top() ~= h.view, true, "the next dialog is showing")
        local choices = h.top()
        eq(choices:onClose(), true)
        assertLibraryStays(h, choices)

        h = harness()
        h.Library.showGestureMenu(h.self, h.view)
        dialog = h.top()
        eq(dialog:onTapClose(), true)
        assertLibraryStays(h, dialog)
    end)

    it("the details card: Close", function()
        local h = harness()
        package.loaded["librarydetails"] = {
            new = function(_, o)
                function o:onClose()
                    if self.on_close then self.on_close() end
                    return true
                end
                return o
            end,
        }
        package.loaded["librarytile"] = { newCoverCache = function() return {} end }
        package.loaded["librarycovers"] = { getStore = function() return {} end }
        local card = h.self:showBookDetails({
            path = "/b.epub", title = "Emma", authors = { "Austen" },
        }, h.view)
        package.loaded["librarydetails"] = nil
        package.loaded["librarytile"] = nil
        package.loaded["librarycovers"] = nil
        eq(h.top(), card)
        eq(card:onClose(), true)
        assertLibraryStays(h, card)
    end)

    it("KOReader's menu: Back, swipe and a tap outside stay in the menu, then the Library is repainted", function()
        local h = harness()
        local touched = {}
        local menu = {
            onShowMenu = function(self)
                local touch = {
                    onBack = function() touched.back = true end,
                    onClose = function() touched.close = true end,
                    onSwipe = function() touched.swipe = true end,
                    onTapCloseAllMenus = function() touched.tap = true end,
                }
                self.menu_container = { touch }
                h.UIManager:show(self.menu_container)
            end,
        }
        h.self.ui = { menu = menu }
        eq(h.Library.showKoreaderMenu(h.self), true)
        local touch = menu.menu_container[1]
        eq(touch:onBack(), true)
        eq(touch:onClose(), true)
        eq(touch:onSwipe(), true)
        eq(touch:onTapCloseAllMenus(), true)
        eq(touched.back, true)
        eq(touched.tap, true)
        -- The menu's own close refreshes with setDirty(nil). Ours runs after.
        h.UIManager:close(menu.menu_container)
        eq(h.top(), h.view, "closing the menu does not uncover the file browser")
        assertLibraryStays(h, menu.menu_container)
    end)

    it("does not flash the file browser when the Library itself is closed", function()
        local h = harness()
        h.UIManager:close(h.view)
        h.UIManager:runTicks()
        h.UIManager:runAfter()
        eq(#h.flashes, 0)
        eq(h.top(), h.fm)
    end)
end)

describe("A closing tap does not dismiss the Library", function()
    it("Back while a dialog has just closed does not close the Library", function()
        local closed = {}
        local UIManager = { close = function(_, w) closed[#closed + 1] = w end }
        local View = load("libraryview.lua", {
            ["ui/uimanager"] = UIManager,
            ["ui/widget/container/inputcontainer"] = cls(),
        })
        local v = setmetatable({ _overlay_just_closed = true }, { __index = View })
        eq(v:onClose(), true)
        eq(#closed, 0)
        v._overlay_just_closed = nil
        v.group = nil
        eq(v:onClose(), true)
        eq(closed[1], v)
    end)

    it("the gesture that closed a menu is not offered to a file-browser zone", function()
        local seen = {}
        package.loaded["apps/filemanager/filemanager"] = {
            instance = {
                _ordered_touch_zones = {},
                handleEvent = function() seen[#seen + 1] = true; return true end,
            },
        }
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/uimanager"] = { close = function() end },
        }, { libraryzones = true })
        local v = setmetatable({
            _overlay_just_closed = true,
            dimen = { w = 1264, h = 1680 },
        }, { __index = View })
        local event = { handler = "onGesture", args = { { ges = "tap", pos = { x = 10, y = 10 } } } }
        eq(v:handleEvent(event), true)
        eq(#seen, 0, "the file browser did not see the closing tap")
        package.loaded["apps/filemanager/filemanager"] = nil
    end)
end)
