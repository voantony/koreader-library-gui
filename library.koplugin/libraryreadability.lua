--[[--
Readability: one tap in the simple reader menu makes the open book easier to
read on a washed-out e-ink screen (darker text, slightly bolder font, a bit
more line spacing, comfortable margins, hyphenation, a full refresh every
few pages). Tapping it again puts back what the book had before.

The pure parts live here (what the preset changes, what Undo puts back), so
the specs can load them. main.lua reads the current values from KOReader and
applies them with KOReader's own events (Library:applyReadability).

A snapshot is a flat table:
  font_gamma, font_base_weight, line_spacing (numbers),
  h_page_margins ({ left, right }), t_page_margin, b_page_margin,
  sync_t_b_page_margins (0/1), hyphenation (boolean),
  full_refresh_count (number, KOReader's global "full refresh every N pages")
Any field may be missing (the reader does not have that setting).
--]]

local M = {}

-- The preset is a floor: it never makes a setting weaker than you had it.
M.PRESET = {
    font_gamma = 30,       -- KOReader's "Contrast" index 30 (gamma 1.9; 15 is 1.0)
    font_base_weight = 1,  -- "Font weight +1"
    line_spacing = 115,    -- percent
    h_margin = 15,         -- left/right page margins (KOReader's "large")
    v_margin = 15,         -- top/bottom page margins
    refresh_every = 6,     -- a full refresh at least every 6 pages
}

M.KEYS = { "font_gamma", "font_base_weight", "line_spacing", "h_page_margins",
    "t_page_margin", "b_page_margin", "sync_t_b_page_margins", "hyphenation", "full_refresh_count" }

local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = copy(x) end
    return o
end
M.copy = copy

local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
M.equal = equal

local function atLeast(v, floor)
    v = tonumber(v)
    if not v or v < floor then return floor end
    return v
end

--- What the preset turns `cur` into. Fields `cur` lacks stay missing.
function M.target(cur)
    local P = M.PRESET
    local t = copy(cur)
    if cur.font_gamma ~= nil then t.font_gamma = atLeast(cur.font_gamma, P.font_gamma) end
    if cur.font_base_weight ~= nil then t.font_base_weight = atLeast(cur.font_base_weight, P.font_base_weight) end
    if cur.line_spacing ~= nil then t.line_spacing = atLeast(cur.line_spacing, P.line_spacing) end
    if type(cur.h_page_margins) == "table" then
        t.h_page_margins = { atLeast(cur.h_page_margins[1], P.h_margin), atLeast(cur.h_page_margins[2], P.h_margin) }
    end
    if cur.t_page_margin ~= nil then t.t_page_margin = atLeast(cur.t_page_margin, P.v_margin) end
    if cur.b_page_margin ~= nil then t.b_page_margin = atLeast(cur.b_page_margin, P.v_margin) end
    -- top and bottom kept in sync only if they still match
    if cur.sync_t_b_page_margins ~= nil and t.t_page_margin ~= t.b_page_margin then
        t.sync_t_b_page_margins = 0
    end
    if cur.hyphenation ~= nil then t.hyphenation = true end
    local r = tonumber(cur.full_refresh_count)
    if r ~= nil and (r == 0 or r > P.refresh_every) then t.full_refresh_count = P.refresh_every end
    return t
end

--- The keys whose value differs between two snapshots, in M.KEYS order.
function M.diff(a, b)
    local out = {}
    for _, k in ipairs(M.KEYS) do
        if not equal(a[k], b[k]) then out[#out + 1] = k end
    end
    return out
end

--- Start: given the current values, what to set and what to remember.
-- Returns changes (key -> new value) and the state to save in the book's
-- settings, or nil when the book already reads this way (nothing to undo).
function M.apply(cur)
    local t = M.target(cur)
    local keys = M.diff(cur, t)
    if #keys == 0 then return nil end
    local changes, prev, applied = {}, {}, {}
    for _, k in ipairs(keys) do
        changes[k] = copy(t[k])
        prev[k] = copy(cur[k])
        applied[k] = copy(t[k])
    end
    return changes, { prev = prev, applied = applied }
end

--- Undo: what to put back. A setting you changed yourself after the tap
-- (its value is no longer the one we set) is left as you set it.
function M.restore(state, cur)
    local changes = {}
    if type(state) ~= "table" or type(state.prev) ~= "table" then return changes end
    local applied = state.applied or {}
    for _, k in ipairs(M.KEYS) do
        if state.prev[k] ~= nil and equal(cur[k], applied[k]) then
            changes[k] = copy(state.prev[k])
        end
    end
    return changes
end

--- Is the preset on for this book (there is something to undo)?
function M.isOn(state)
    return type(state) == "table" and type(state.prev) == "table" and next(state.prev) ~= nil
end

return M
