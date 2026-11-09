-- Issue #6: the search bar's clear (X) button is hidden while the query is
-- empty and shown once there is text. Crossing that line does not rebuild
-- the text box or reopen the keyboard; the button's slot stays reserved.
--
-- LibraryView needs KOReader's UI modules, so they are stubbed here; only
-- the class table is under test.

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o) o = o or {}; return setmetatable(o, self) end
    return base
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryzones = true, libraryindex = true, string = true, table = true, math = true, io = true, os = true }
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

describe("search clear button (issue #6)", function()
    local last_group, dirty, opened_keyboard
    local function harness()
        last_group, dirty, opened_keyboard = nil, 0, 0
        local UIManager = {
            scheduleIn = function() end,
            unschedule = function() end,
            setDirty = function(_, _, fn)
                dirty = dirty + 1
                local mode = fn()
                eq(mode, "ui")
            end,
            show = function() end,
            close = function() end,
        }
        local IconButton = cls()
        function IconButton:getSize() return { w = self.width or 22, h = self.height or 22 } end
        local HorizontalGroup = cls()
        local old_new = HorizontalGroup.new
        function HorizontalGroup:new(o)
            local g = old_new(self, o)
            last_group = g
            return g
        end
        local InputText = cls()
        function InputText:getText() return self.text or "" end
        function InputText:setText(t) self.text = t end
        function InputText:onCloseWidget() self.closed = (self.closed or 0) + 1 end
        function InputText:isKeyboardVisible() return self.keyboard_visible and true or false end
        function InputText:getSize() return { w = self.width or 0, h = 40 } end
        function InputText:focus() self.focused = true end
        function InputText:unfocus() self.focused = false end
        function InputText:onShowKeyboard() self.keyboard_visible = true end
        function InputText:onCloseKeyboard() self.keyboard_visible = false end
        local View = load("libraryview.lua", {
            ["ui/uimanager"] = UIManager,
            ["ui/widget/container/inputcontainer"] = cls(),
            ["ui/widget/inputtext"] = InputText,
            ["ui/widget/iconbutton"] = IconButton,
            ["ui/widget/horizontalgroup"] = HorizontalGroup,
            ["ui/widget/container/framecontainer"] = cls(),
            ["ui/widget/container/centercontainer"] = cls(),
            ["ui/widget/horizontalspan"] = cls(),
            ["ui/font"] = { getFace = function() return {} end },
            ["ui/size"] = {
                margin = { default = 10 },
                padding = { default = 5, large = 10, small = 2 },
                border = { button = 1 },
            },
            ["device"] = {
                screen = { scaleBySize = function(_, n) return n end },
                isTouchDevice = function() return true end,
                hasDPad = function() return false end,
            },
            ["ffi/blitbuffer"] = { COLOR_GRAY_7 = 1, COLOR_WHITE = 2, COLOR_BLACK = 3 },
            ["ui/geometry"] = { new = function(_, o) return o or {} end },
            ["librarytile"] = { minTouch = function() return 40 end },
        })
        local v = setmetatable({
            show_clock = false,
            show_battery = false,
            rounded_keyboard = false,
            use_koreader_keyboard = false,
            width = 800,
            dimen = { w = 800, h = 1200 },
            query = "",
        }, { __index = View })
        v.searchHint = function() return "Search title, author, series" end
        v.assembleHeader = function(self) self.header_built = (self.header_built or 0) + 1 end
        v.refreshBody = function(self) self.body_refreshed = (self.body_refreshed or 0) + 1 end
        v.openKeyboard = function(self) opened_keyboard = opened_keyboard + 1 end
        v.headerRegion = function() return { x = 0, y = 0, w = 800, h = 80 } end
        return v
    end

    local function has_clear(group)
        for _, child in ipairs(group) do
            if type(child) == "table" and child.icon == "close" then return true end
        end
        return false
    end

    it("hides the clear button while the query is empty", function()
        local v = harness()
        v:buildSearchRow()
        eq(v._search_clear ~= nil, true, "the button stays in the row")
        eq(v._search_clear_visible, false)
        eq(v.search_input:getText(), "")
        eq(has_clear(last_group), true)
        eq(v._search_clear.paintTo ~= v._search_clear._library_paint, true, "it does not paint")
        -- slot reserved: 770 - 2*1 - 2*10 - 22 - 22 - 2*5
        eq(v.search_input.width, 694)
    end)

    it("shows the clear button with a query", function()
        local v = harness()
        v:buildSearchRow("austen")
        eq(v._search_clear_visible, true)
        eq(has_clear(last_group), true)
        eq(v._search_clear.paintTo, v._search_clear._library_paint)
        eq(v.search_input.width, 694)
    end)

    it("appears on the first character and disappears on clear without a new text box", function()
        local v = harness()
        v:buildSearchRow()
        local input = v.search_input
        eq(v.header_built, 1)
        input:setText("a")
        v:applySearch("a")
        eq(v.search_input, input, "the text box is not rebuilt")
        eq(input.closed or 0, 0)
        eq(v._search_clear_visible, true)
        eq(v.header_built, 1)
        eq(dirty, 1, "the header is repainted")
        eq(opened_keyboard, 0)
        v:clearSearch()
        eq(v.search_input, input)
        eq(v.search_input:getText(), "")
        eq(v._search_clear_visible, false)
        eq(v.header_built, 1)
        eq(opened_keyboard, 0)
        v:updateSearchClear()
        eq(v.header_built, 1)
        eq(dirty, 2, "an unchanged clear state does not repaint")
        input:setText("a")
        v:applySearch("a")
        v:applySearch("a")
        eq(v.header_built, 1)
        eq(dirty, 3)
    end)

    it("leaves the keyboard up while the clear button comes and goes", function()
        local v = harness()
        v:buildSearchRow()
        v.search_input.keyboard_visible = true
        v.search_input:setText("a")
        v:applySearch("a")
        eq(opened_keyboard, 0, "the keyboard is not reopened")
        eq(v.search_input.keyboard_visible, true)
        v:clearSearch()
        eq(opened_keyboard, 0)
        eq(v.search_input.keyboard_visible, true, "clearing does not close it either")
        eq(v._search_clear_visible, false)
    end)
end)
