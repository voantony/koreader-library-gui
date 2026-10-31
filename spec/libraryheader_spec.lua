-- Header and footer: clock and battery beside the search bar, menu and Resume
-- in the footer, and the optional KOReader keyboard for search.
local Core = require("librarycore")

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

describe("Header status", function()
    it("shows the clock and the battery unless each is turned off", function()
        eq(Core.showClock(nil), true)
        eq(Core.showClock({}), true)
        eq(Core.showClock({ show_clock = true }), true)
        eq(Core.showClock({ show_clock = false }), false)
        eq(Core.showBattery(nil), true)
        eq(Core.showBattery({ show_battery = false }), false)
        -- the older keyboard switch is a different key
        eq(Core.roundedKeyboard({ show_clock = false, rounded_keyboard = true }), true)
        eq(Core.roundedKeyboard({ rounded_keyboard = false }), false)
    end)

    it("uses KOReader's keyboard only when that is turned on", function()
        eq(Core.useKoreaderKeyboard(nil), false)
        eq(Core.useKoreaderKeyboard({}), false)
        eq(Core.useKoreaderKeyboard({ use_koreader_keyboard = false }), false)
        eq(Core.useKoreaderKeyboard({ use_koreader_keyboard = true }), true)
        eq(Core.roundedKeyboard({ use_koreader_keyboard = true }), true)
    end)

    it("joins the clock and the battery, and drops a missing half", function()
        eq(Core.statusLabel("10:00", "87%"), "10:00  ·  87%")
        eq(Core.statusLabel("10:00", nil), "10:00")
        eq(Core.statusLabel(nil, "87%"), "87%")
        eq(Core.statusLabel("", "87%"), "87%")
        eq(Core.statusLabel(nil, nil), nil)
        eq(Core.statusLabel("", ""), nil)
    end)

    it("prints a percentage only for a real 0..100 reading", function()
        eq(Core.batteryLabel(87), "87%")
        eq(Core.batteryLabel(87.6), "88%")
        eq(Core.batteryLabel(0), "0%")
        eq(Core.batteryLabel(100), "100%")
        eq(Core.batteryLabel(-1), nil)
        eq(Core.batteryLabel(101), nil)
        eq(Core.batteryLabel(nil), nil)
        eq(Core.batteryLabel("87"), nil)
    end)

    it("waits until the next minute, and never spins", function()
        eq(Core.nextMinuteDelay(0), 60)
        eq(Core.nextMinuteDelay(1), 59)
        eq(Core.nextMinuteDelay(59), 1)
        eq(Core.nextMinuteDelay(60), 60)
        eq(Core.nextMinuteDelay(119), 1)
        eq(Core.nextMinuteDelay(nil), 60)
    end)
end)

describe("Status refresh", function()
    local scheduled, unscheduled, dirty
    local function view(opts)
        scheduled, unscheduled, dirty = {}, {}, 0
        local UIManager = {
            scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
            unschedule = function(_, fn) unscheduled[#unscheduled + 1] = fn end,
            setDirty = function(_, widget, fn)
                dirty = dirty + 1
                local mode = fn()
                eq(mode, "ui")
                eq(widget ~= nil, true)
            end,
            show = function() end,
            close = function() end,
        }
        local View = load("libraryview.lua", {
            ["ui/uimanager"] = UIManager,
            ["ui/widget/container/inputcontainer"] = cls(),
        })
        local v = setmetatable({
            show_clock = true,
            show_battery = true,
            width = 1264,
            dimen = { w = 1264, h = 1680 },
            header = { getSize = function() return { h = 80 } end },
            covers = { bim = true },
            cover_cache = { clear = function() end },
        }, { __index = View })
        if opts then for k, val in pairs(opts) do v[k] = val end end
        return v
    end

    it("schedules a single tick, and only while something is shown", function()
        local v = view()
        v.updateStatusText = function() return false end
        v:scheduleStatusRefresh()
        eq(#scheduled, 1)
        eq(scheduled[1].delay, Core.nextMinuteDelay(os.time()))
        eq(scheduled[1].delay >= 1 and scheduled[1].delay <= 60, true)
        scheduled[1].fn()
        eq(#scheduled, 2, "the next minute is armed after this one")
        eq(dirty, 0, "an unchanged clock does not refresh")
        v.show_clock, v.show_battery = false, false
        v:scheduleStatusRefresh()
        eq(#scheduled, 2, "both off: the timer stops")
        eq(#unscheduled >= 1, true)
    end)

    it("refreshes only the header when the minute changes", function()
        local v = view()
        v.updateStatusText = function() return true end
        v:onStatusTick()
        eq(dirty, 1)
    end)

    it("drops the timer when the Library closes", function()
        local v = view()
        v.updateStatusText = function() return false end
        v:scheduleStatusRefresh()
        local tick = v._status_tick
        v:onCloseWidget()
        eq(v._closed, true)
        eq(v._status_tick, nil)
        eq(unscheduled[#unscheduled], tick)
    end)
end)

describe("KOReader keyboard for search", function()
    local function harness()
        local shown, closed = {}, {}
        local InputDialog = {
            new = function(_, o)
                o.getInputText = o.getInputText or function() return o.input end
                o.onShowKeyboard = function(d) d.keyboard_shown = true end
                return o
            end,
        }
        local UIManager = {
            show = function(_, w) shown[#shown + 1] = w end,
            close = function(_, w) closed[#closed + 1] = w end,
            scheduleIn = function() end,
            unschedule = function() end,
        }
        local View = load("libraryview.lua", {
            ["ui/widget/inputdialog"] = InputDialog,
            ["ui/uimanager"] = UIManager,
            ["ui/widget/container/inputcontainer"] = cls(),
        })
        local text = "emma"
        local embedded = false
        local v = setmetatable({
            use_koreader_keyboard = true,
            query = "emma",
            search_input = {
                getText = function() return text end,
                setText = function(_, t) text = t end,
                isKeyboardVisible = function() return false end,
                onShowKeyboard = function() embedded = true end,
                focus = function() embedded = true end,
                hide_number_row = false,
            },
        }, { __index = View })
        v.searchHint = function() return "Search title, author, series" end
        v.applySearch = function(_, q) v.applied = q end
        v.onSearchEdited = function(self) self.live = (self.live or 0) + 1 end
        v.markSearchFocus = function() end
        v.refreshBody = function() end
        v.matchKeyboard = function() end
        return v, shown, closed, function() return text, embedded end
    end

    it("opens KOReader's dialog and not the Library keyboard", function()
        local v, shown, _c, state = harness()
        v:openKeyboard()
        local _text, embedded = state()
        eq(embedded, false)
        eq(#shown, 1)
        eq(shown[1].title, "Search")
        eq(shown[1].input, "emma")
        eq(shown[1].input_hint, "Search title, author, series")
        eq(shown[1].keyboard_shown, true)
        -- a second tap does not stack another dialog
        v:onSwitchFocus(v.search_input)
        eq(#shown, 1)
    end)

    it("filters as the dialog changes, and Cancel restores the old query", function()
        local v, shown, closed, state = harness()
        v:openKoreaderSearch()
        local dialog = shown[1]
        dialog.getInputText = function() return "austen" end
        dialog.edited_callback(false)
        eq(v.live, nil)
        dialog.edited_callback(true)
        eq(state(), "austen")
        eq(v.live, 1)
        dialog.buttons[1][1].callback()
        eq(v.applied, "emma")
        eq(closed[1], dialog)
        eq(v._search_dialog, nil)
    end)

    it("Search keeps what was typed", function()
        local v, shown = harness()
        v:openKoreaderSearch()
        shown[1].getInputText = function() return "bronte" end
        shown[1].buttons[1][2].callback()
        eq(v.applied, "bronte")
        eq(shown[1].buttons[1][2].is_enter_default, true)
    end)

    it("still uses the Library keyboard when the setting is off", function()
        local v, shown, _c, state = harness()
        v.use_koreader_keyboard = false
        v:openKeyboard()
        local _text, embedded = state()
        eq(embedded, true)
        eq(#shown, 0)
    end)
end)

describe("Header settings in the menu", function()
    local function menuFor(settings)
        local shown = {}
        local UIManager = {
            show = function(_, w) shown[#shown + 1] = w end,
            close = function() end,
            nextTick = function(_, f) f() end,
            scheduleIn = function() end,
        }
        local Library = load("main.lua", {
            ["ui/uimanager"] = UIManager,
            ["ui/widget/buttondialog"] = { new = function(_, o) return o end },
            ["ui/widget/container/widgetcontainer"] = cls(),
        })
        local view = {
            sort = "recent", view_mode = "grid",
            placeName = function() return "Books" end,
            viewKey = function() return "books" end,
            hasRemembered = function() return false end,
            setShowClock = function(v, on) v.clock = on end,
            setShowBattery = function(v, on) v.battery = on end,
            setUseKoreaderKeyboard = function(v, on) v.koreader_keyboard = on end,
        }
        local self = setmetatable({
            settings = settings or { columns = 4 },
            saveSettings = function() end,
        }, { __index = Library })
        Library.showLibraryMenu(self, view)
        return shown[1], view, self.settings
    end

    it("shows the clock, the battery and KOReader's keyboard above Close", function()
        local dialog = menuFor()
        local rows = dialog.buttons
        eq(rows[#rows][1].text, "\u{2715} Close Library")
        eq(rows[#rows - 1][1].text, "Use KOReader's keyboard")
        eq(rows[#rows - 2][1].text, "\u{2713} Show clock")
        eq(rows[#rows - 2][2].text, "\u{2713} Show battery")
    end)

    it("toggles clock and battery separately, and the keyboard on its own", function()
        local dialog, view, settings = menuFor({
            columns = 4, show_clock = true, show_battery = true,
            use_koreader_keyboard = false, rounded_keyboard = true,
        })
        local rows = dialog.buttons
        rows[#rows - 2][1].callback()
        eq(settings.show_clock, false)
        eq(settings.show_battery, true)
        eq(settings.rounded_keyboard, true)
        eq(view.clock, false)
        rows[#rows - 2][2].callback()
        eq(settings.show_battery, false)
        eq(view.battery, false)
        rows[#rows - 1][1].callback()
        eq(settings.use_koreader_keyboard, true)
        eq(view.koreader_keyboard, true)
        eq(settings.show_clock, false, "the keyboard switch does not turn the clock back on")
    end)
end)
