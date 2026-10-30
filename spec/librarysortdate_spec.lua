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


-- Sorted by Last read or Date added, rows and covers show the date (t1116u).
local Core = require("librarycore")
local Tiles = load("librarytile.lua", {})

local function at(y, mo, d, h, mi)
    return os.time{ year = y, month = mo, day = d, hour = h or 12, min = mi or 0, sec = 0 }
end

describe("Short dates", function()
    local now = at(2026, 10, 30, 21, 0)
    it("is relative for recent times", function()
        eq(Core.shortDate(now - 20, now), "Just now")
        eq(Core.shortDate(now - 5 * 60, now), "5m ago")
        eq(Core.shortDate(now - 2 * 3600, now), "2h ago")
        eq(Core.shortDate(at(2026, 10, 29, 9, 0), now), "Yesterday")
    end)
    it("is a day and month, with the year when it is another year", function()
        eq(Core.shortDate(at(2026, 10, 12), now), "12 Oct")
        eq(Core.shortDate(at(2024, 10, 12), now), "12 Oct 2024")
    end)
    it("is nothing without a time", function()
        eq(Core.shortDate(nil, now), nil)
        eq(Core.shortDate(0, now), nil)
    end)
end)

describe("The date a sort shows", function()
    local now = at(2026, 10, 30, 21, 0)
    local book = { last_opened = now - 7200, modification = at(2026, 10, 12) }
    it("is the last-opened time for Last read and the added date for Date added", function()
        eq(Core.sortDate(book, "recent", now), "2h ago")
        eq(Core.sortDate(book, "added", now), "12 Oct")
    end)
    it("is nothing for other sorts and for never-opened books in Last read", function()
        for _, s in ipairs({ "author", "title", "series" }) do eq(Core.sortDate(book, s, now), nil) end
        eq(Core.sortDate({ modification = at(2026, 10, 12) }, "recent", now), nil)
    end)
end)

describe("Rows with a date", function()
    it("puts the date on the right of a compact row, after the status", function()
        local book = { title = "Emma", authors = { "Jane Austen" }, status = "reading", percent = 0.62 }
        local left, right = Tiles.compactText(book, "books", false, false, "2h ago")
        eq(left, "Emma · Jane Austen"); eq(right, "62 % · 2h ago")
        left, right = Tiles.compactText({ title = "Typee", status = "new" }, "books", false, false, "12 Oct")
        eq(right, "12 Oct")
        left, right = Tiles.compactText(book, "books", false, false, nil)
        eq(right, "62 %")
    end)
    it("shows the date under a cover instead of the author", function()
        local book = { title = "Emma", authors = { "Jane Austen" } }
        eq(Tiles.secondLine(book, "Yesterday"), "Yesterday")
        eq(Tiles.secondLine(book, nil), "Jane Austen")
    end)
end)
