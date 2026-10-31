--[[--
"Timing log": an opt-in log of how long the Library takes, for measuring on
a real device. Off by default; when off nothing is timed or written.

Four things are timed, each from the user's action until the Library has
painted the result into the screen buffer (the e-ink refresh is queued right
after, and is not included):

  open    the Library opening (from the tap or gesture)
  page    a page turn
  filter  a filter chip (All, Unread, Reading…)
  search  the last keystroke until its results are painted (this includes
          the short wait for more keys, Settings → debounce_ms)

One line per measurement, e.g.
  2026-10-31 14:03:22  search   212.4 ms  query=5 results=12 books=3000

Pure Lua: the clock and the writer are passed in.
--]]

local M = {}
M.__index = M

--- @param opts { enabled = bool, clock = function() -> seconds, write = function(line), date = function() -> string }
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        enabled = opts.enabled == true,
        clock = opts.clock or os.clock,
        write = opts.write or print,
        date = opts.date or function() return os.date("%Y-%m-%d %H:%M:%S") end,
        pending = {},  -- name -> start time
        armed = {},    -- name -> true: stop at the next paint
        notes = {},    -- name -> extra text for the line
        last = {},     -- name -> last measured ms (for tests and the probe)
    }, M)
end

--- Start (or restart) timing `name`. `armed`: stop at the next paint.
function M:start(name, armed)
    if not self.enabled then return end
    self.pending[name] = self.clock()
    self.armed[name] = armed and true or nil
    self.notes[name] = nil
end

--- Stop `name` at the next paint (e.g. once search results are ready).
function M:arm(name, note)
    if not self.enabled or not self.pending[name] then return end
    self.armed[name] = true
    if note then self.notes[name] = note end
end

--- Stop `name` now and write its line. Returns the milliseconds, or nil.
function M:stop(name, note)
    if not self.enabled then return nil end
    local t0 = self.pending[name]
    if not t0 then return nil end
    self.pending[name], self.armed[name] = nil, nil
    local ms = (self.clock() - t0) * 1000
    note = note or self.notes[name]
    self.notes[name] = nil
    self.last[name] = ms
    pcall(self.write, string.format("%s  %-7s %7.1f ms%s", self.date(), name, ms, note and note ~= "" and ("  " .. note) or ""))
    return ms
end

--- The Library was just painted: stop everything waiting for that.
-- `note(name)` may add context (results, books…) to each line.
function M:painted(note)
    if not self.enabled or next(self.armed) == nil then return end
    local names = {}
    for name in pairs(self.armed) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local extra = note and note(name)
        local own = self.notes[name]
        self:stop(name, (own and extra) and (own .. " " .. extra) or own or extra)
    end
end

--- Forget `name` (or everything) still running, e.g. the Library closed first.
function M:cancel(name)
    if name then
        self.pending[name], self.armed[name], self.notes[name] = nil, nil, nil
    else
        self.pending, self.armed, self.notes = {}, {}, {}
    end
end

return M
