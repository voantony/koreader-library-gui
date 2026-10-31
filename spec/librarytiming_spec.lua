-- The opt-in "Timing log" (librarytiming.lua).
local Timing = require("librarytiming")

local function rig(enabled)
    local now, lines = 0, {}
    local t = Timing.new{
        enabled = enabled,
        clock = function() return now end,
        write = function(line) table.insert(lines, line) end,
        date = function() return "12:00:00" end,
    }
    return t, lines, function(s) now = now + s end
end

describe("librarytiming", function()
    it("does and writes nothing while off", function()
        local t, lines, tick = rig(false)
        t:start("open", true); tick(0.1); t:painted(); t:stop("page")
        eq(#lines, 0)
        eq(t.last.open, nil)
    end)
    it("times from start to the paint that follows", function()
        local t, lines, tick = rig(true)
        t:start("page", true); tick(0.0425)
        t:painted(function(name) return name .. " note" end)
        eq(#lines, 1)
        eq(lines[1]:find("page", 1, true) ~= nil, true)
        eq(lines[1]:find("42.5 ms", 1, true) ~= nil, true)
        eq(lines[1]:find("page note", 1, true) ~= nil, true)
        eq(math.abs(t.last.page - 42.5) < 0.01, true)
        t:painted(); eq(#lines, 1, "a timer stops once")
    end)
    it("waits to be armed when it was not started armed (search: the debounce first)", function()
        local t, lines, tick = rig(true)
        t:start("search"); tick(0.2); t:painted(); eq(#lines, 0)
        t:arm("search", "query=3"); tick(0.01); t:painted()
        eq(#lines, 1)
        eq(lines[1]:find("210.0 ms", 1, true) ~= nil, true)
        eq(lines[1]:find("query=3", 1, true) ~= nil, true)
    end)
    it("restarts from the latest start", function()
        local t, lines, tick = rig(true)
        t:start("search"); tick(0.5); t:start("search"); tick(0.05); t:arm("search"); t:painted()
        eq(lines[1]:find("50.0 ms", 1, true) ~= nil, true)
    end)
    it("forgets a cancelled timer", function()
        local t, lines, tick = rig(true)
        t:start("page", true); t:start("open", true); t:cancel("page"); tick(0.01); t:painted()
        eq(#lines, 1); eq(lines[1]:find("open", 1, true) ~= nil, true)
        t:start("page", true); t:cancel(); t:painted(); eq(#lines, 1)
    end)
    it("ignores arming a timer that never started", function()
        local t, lines = rig(true)
        t:arm("filter"); t:painted(); eq(#lines, 0)
    end)
end)
