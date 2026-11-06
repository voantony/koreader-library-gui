--[[--
Reader status bar: the pure part. No KOReader modules here, so the specs
can load it; main.lua reads the footer, applies the default, and shows
the picker.

When a book opens, if the status bar is still showing pages left and we
have not touched it before, we switch it to the current page out of the
total (for example 42 / 310). A view someone chose is left alone.

A tap then cycles through a short list of views; a long-press opens a
picker to jump to one, include or exclude it from the cycle, skim, go
to a page, or hide the bar.
--]]

local M = {}

M.PAGE_PROGRESS = "page_progress"

-- KOReader's footer mode numbers, used when the live footer has not
-- built mode_list. Off is 0.
M.MODE = {
    off = 0,
    page_progress = 1,
    pages_left_book = 2,
    time = 3,
    pages_left = 4,
    percentage = 6,
    book_time_to_read = 7,
    chapter_time_to_read = 8,
}

M.NAME_BY_MODE = {}
for name, n in pairs(M.MODE) do
    M.NAME_BY_MODE[n] = name
end

-- "Pages left" views we replace once with the current page out of the total.
M.PAGES_LEFT = {
    pages_left = true,
    pages_left_book = true,
}

-- Tap-cycle views, in order.
M.VIEWS = {
    { id = "page_progress" },
    { id = "chapter_time_to_read" },
    { id = "book_time_to_read" },
    { id = "percentage" },
    { id = "pages_left" },
    { id = "time" },
}

function M.modeName(footer, stored)
    if type(footer) == "table" then
        if type(footer.mode_index) == "table" and footer.mode ~= nil then
            local name = footer.mode_index[footer.mode]
            if type(name) == "string" then return name end
        end
        if type(footer.mode) == "string" then return footer.mode end
        if type(footer.mode) == "number" then return M.NAME_BY_MODE[footer.mode] end
    end
    if type(stored) == "string" then return stored end
    if type(stored) == "number" then return M.NAME_BY_MODE[stored] end
end

function M.isPagesLeft(name)
    return M.PAGES_LEFT[name] == true
end

--- What to do when a book opens.
-- s: { enabled = (our setting, nil = on), current = (mode name),
-- prev = (mode we saved when we switched it before, nil = never),
-- all_at_once = (KOReader showing every item at once) }.
-- Returns the mode to switch to, or nil to leave it alone.
function M.plan(s)
    if s.enabled == false or s.prev ~= nil then return nil end
    if s.all_at_once then return nil end
    if not M.isPagesLeft(s.current) then return nil end
    return M.PAGE_PROGRESS
end

--- What to restore when the setting is turned off: the mode from before
-- we switched it, but only if the bar is still showing the one we set.
function M.restore(current, prev)
    if prev == nil then return nil end
    if current ~= M.PAGE_PROGRESS then return nil end
    return prev
end

--- Which cycle views are on. Missing entries count as on.
function M.enabledSet(stored)
    local set = {}
    for _, v in ipairs(M.VIEWS) do
        set[v.id] = not (type(stored) == "table" and stored[v.id] == false)
    end
    return set
end

function M.enabledList(enabled)
    local list = {}
    enabled = enabled or {}
    for _, v in ipairs(M.VIEWS) do
        if enabled[v.id] then list[#list + 1] = v.id end
    end
    return list
end

function M.countOn(enabled)
    return #M.enabledList(enabled)
end

--- False only when turning `id` off would leave the cycle empty.
function M.canDisable(enabled, id)
    enabled = M.enabledSet(enabled)
    if not enabled[id] then return true end
    return M.countOn(enabled) > 1
end

--- Toggle `id` in the cycle. Returns a new set, or nil if that would
-- leave nothing on.
function M.toggle(enabled, id)
    enabled = M.enabledSet(enabled)
    local known = false
    for _, v in ipairs(M.VIEWS) do
        if v.id == id then known = true; break end
    end
    if not known then return nil end
    if enabled[id] and M.countOn(enabled) <= 1 then return nil end
    local out = M.enabledSet(enabled)
    out[id] = not enabled[id]
    return out
end

--- After a toggle, which view should stay on screen. If the one that
-- was showing was turned off, prefer the current page, else the first
-- view still on.
function M.currentAfterToggle(enabled, current, id)
    if current ~= id then return current end
    if enabled and enabled[current] then return current end
    if enabled and enabled[M.PAGE_PROGRESS] then return M.PAGE_PROGRESS end
    local list = M.enabledList(enabled)
    return list[1] or current
end

--- The next view a tap should show. "off" (a hidden bar) and a view
-- that is not in the cycle both go to the first view still on.
function M.next(enabled, current)
    local list = M.enabledList(enabled)
    if #list == 0 then return nil end
    if current == nil or current == "off" then return list[1] end
    for i, id in ipairs(list) do
        if id == current then
            return list[(i % #list) + 1]
        end
    end
    return list[1]
end

--- Claim a long-press only while our setting is on, the footer is
-- visible, and the press is inside the footer's own box — so a hold
-- on the text above it still highlights.
function M.shouldClaimHold(s)
    if s.enabled == false then return false end
    if not s.footer_visible then return false end
    if not s.has_dimen then return false end
    if not s.inside then return false end
    return true
end

function M.shouldCycle(s)
    if s.enabled == false then return false end
    if s.all_at_once then return false end
    return true
end

function M.parseClockToMinutes(s)
    if type(s) ~= "string" then return nil end
    local h, m = s:match("^(%d+):(%d+)$")
    if h then return tonumber(h) * 60 + tonumber(m) end
    return tonumber(s)
end

function M.formatMinutes(min)
    min = tonumber(min)
    if not min then return nil end
    min = math.floor(min + 0.5)
    if min < 1 then return nil end
    if min < 60 then return tostring(min) .. " min" end
    local h = math.floor(min / 60)
    local rest = min % 60
    if rest == 0 then return tostring(h) .. " h" end
    return tostring(h) .. " h " .. tostring(rest) .. " min"
end

--- A live label when we have the numbers (for example "12 min left in
-- chapter"), or nil to use a static name.
function M.viewLabel(id, info)
    info = info or {}
    if id == "page_progress" then
        local page, pages = tonumber(info.page), tonumber(info.pages)
        if page and pages then return tostring(page) .. " / " .. tostring(pages) end
    elseif id == "chapter_time_to_read" then
        local t = M.formatMinutes(info.chapter_min)
        if t then return t .. " left in chapter" end
    elseif id == "book_time_to_read" then
        local t = M.formatMinutes(info.book_min)
        if t then return t .. " left in book" end
    elseif id == "percentage" then
        local pct = tonumber(info.percent)
        if pct then
            if pct <= 1 then pct = pct * 100 end
            return tostring(math.floor(pct + 0.5)) .. "% read"
        end
    elseif id == "pages_left" then
        local n = tonumber(info.chapter_left)
        if n then
            if n == 1 then return "1 page left in chapter" end
            return tostring(n) .. " pages left in chapter"
        end
    elseif id == "time" then
        if type(info.clock) == "string" and info.clock ~= "" then return info.clock end
    end
end

return M
