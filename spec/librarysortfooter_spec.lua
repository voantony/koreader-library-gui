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

describe("Sort picker from the footer label", function()
    it("lists Author, Title, Date added, Last read, Series with the current one ticked", function()
        local dialog, _v, shown = pickerFor("recent")
        eq(shown[1], dialog)
        eq(dialog.title, "Sort by")
        same(texts(dialog), { "Author", "Title", "Date added", "\u{2713} Last read", "Series" })
        same(texts((pickerFor("author"))), { "\u{2713} Author", "Title", "Date added", "Last read", "Series" })
    end)

    it("picking one closes the picker and re-sorts", function()
        local dialog, view, _s, closed = pickerFor("recent")
        dialog.buttons[2][1].callback()
        eq(closed[1], dialog)
        same(view.resorted, { "title" })
    end)

    it("picking the current sort just closes", function()
        local dialog, view, _s, closed = pickerFor("added")
        dialog.buttons[3][1].callback()
        eq(#closed, 1); eq(#view.resorted, 0)
    end)
end)

describe("LibraryView sort label", function()
    local View = load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = cls(),
        util = { stringLower = function(s) return s:lower() end },
    })
    it("tapping it hides the keyboard and opens the picker", function()
        local calls = {}
        local v = setmetatable({}, { __index = View })
        v.keyboardGuard = function() calls[#calls + 1] = "keyboard" end
        v.plugin = { showSortPicker = function(_, view) calls[#calls + 1] = "picker"; eq(view, v) end }
        v:showSortPicker()
        same(calls, { "keyboard", "picker" })
    end)

    it("the chosen sort is remembered for the place it was picked in", function()
        local remembered = {}
        local v = setmetatable({ tab = "authors", group = { kind = "authors", name = "Jane Austen" }, page = 3 },
            { __index = View })
        v.plugin = { rememberViewPref = function(_, key, field, value) remembered[#remembered + 1] = key .. " " .. field .. "=" .. value end }
        v.reloadData = function() end
        v.reresolveGroup = function() end
        v.refreshBody = function() end
        v:resort("added")
        eq(v.sort, "added"); eq(v.page, 1)
        same(remembered, { "authors:Jane Austen sort=added" })
        v.group = nil; v.tab = "books"
        v:resort("author")
        eq(remembered[2], "books sort=author")
    end)
end)
