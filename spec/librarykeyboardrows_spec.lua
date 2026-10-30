-- The footer's "202 books · Last read ▾" label opens a sort picker.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

-- Load a plugin file with KOReader stubbed; `extra[name]` overrides a module.
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


local function pickerFor(sort)
    local shown, closed = {}, {}
    local Library = load("main.lua", {
        ["ui/uimanager"] = {
            show = function(_, w) shown[#shown + 1] = w end,
            close = function(_, w) closed[#closed + 1] = w end,
        },
        ["ui/widget/buttondialog"] = { new = function(_, o) return o end },
        ["ui/widget/container/widgetcontainer"] = cls(),
    })
    local view = { sort = sort, resorted = {} }
    function view:resort(m) self.resorted[#self.resorted + 1] = m; self.sort = m end
    local self = setmetatable({ settings = {} }, { __index = Library })
    local dialog = Library.showSortPicker(self, view)
    return dialog, view, shown, closed
end

local function texts(dialog)
    local t = {}
    for i, row in ipairs(dialog.buttons) do eq(#row, 1); t[i] = row[1].text end
    return t
end

-- On the Authors tab the search keyboard has no number row: the letters get
-- its space. Everywhere else keeps it (t1117u).
local Keyboard = require("librarykeyboard")

local function layout()
    local digits, letters = {}, {}
    for d = 1, 9 do digits[d] = { tostring(d) .. "!", { tostring(d), north = "!" }, "`", "!" } end
    digits[10] = { "0)", "0", "-", "_" }
    for c = 1, 10 do letters[c] = { "Q", "q", "?", "1" } end
    return { digits, letters, { { "A", "a", "(", "2" } }, { { label = "⌥" } } }
end

describe("Keyboard without the number row", function()
    it("knows a number row (keys as strings or popups)", function()
        local keys = layout()
        eq(Keyboard.isNumberRow(keys[1]), true)
        eq(Keyboard.isNumberRow(keys[2]), false)
        eq(Keyboard.isNumberRow(keys[4]), false)
    end)
    it("drops it, leaving the letter rows and the symbols key, without changing the layout", function()
        local keys = layout()
        local out = Keyboard.withoutNumberRow(keys)
        eq(#out, 3); eq(out[1], keys[2]); eq(out[3][1].label, "⌥")
        eq(#keys, 4)
    end)
    it("leaves a layout with no number row alone", function()
        local keys = layout()
        table.remove(keys, 1)
        eq(Keyboard.withoutNumberRow(keys), keys)
    end)
end)

describe("Which places get the letters-only keyboard", function()
    local View = load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = cls(),
        util = { stringLower = function(s) return s:lower() end },
    })
    local function viewAt(tab, group)
        local built = 0
        local input = { hide_number_row = false, keyboard = {} }
        input.isKeyboardVisible = function() return false end
        input.initKeyboard = function() built = built + 1 end
        local v = setmetatable({ tab = tab, group = group, search_input = input }, { __index = View })
        return v, input, function() return built end
    end
    it("is the Authors list only", function()
        eq(viewAt("authors"):wantsLettersKeyboard(), true)
        eq(viewAt("authors", { name = "Jane Austen" }):wantsLettersKeyboard(), false)
        for _, t in ipairs({ "books", "series", "collections" }) do eq(viewAt(t):wantsLettersKeyboard(), false) end
    end)
    it("rebuilds the keyboard only when the kind changes", function()
        local v, input, built = viewAt("authors")
        eq(v:matchKeyboard(), true); eq(input.hide_number_row, true); eq(built(), 1)
        eq(v:matchKeyboard(), false); eq(built(), 1)
        v.tab = "books"
        eq(v:matchKeyboard(), true); eq(input.hide_number_row, false); eq(built(), 2)
    end)
end)
