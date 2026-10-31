--[[--
Simple reader menu: the pure parts (which buttons, where they go, what a tap
hits, when the top-of-page tap should open it). No KOReader modules here, so
the specs can load it; the panel itself is libraryreaderpanel.lua.
--]]

local M = {}

-- Every button the panel can have, in panel order (left to right, top to
-- bottom). `needs` names the capability the device or reader must have.
M.ITEMS = {
    { id = "library",  needs = nil },
    { id = "toc",      needs = "toc" },
    { id = "goto",     needs = nil },
    { id = "search",   needs = "search" },
    { id = "font",     needs = "config" },
    { id = "readability", needs = "readability" },
    { id = "light",    needs = "light" },
    { id = "bookmark", needs = "bookmark" },
    { id = "details",  needs = nil },
}

--- The ids of the buttons to show, given what this reader can do.
-- caps: { toc =, search =, config =, readability =, light =, bookmark = } (booleans).
function M.items(caps)
    caps = caps or {}
    local out = {}
    for _, it in ipairs(M.ITEMS) do
        if not it.needs or caps[it.needs] then out[#out + 1] = it.id end
    end
    return out
end

--- Should a tap in KOReader's top menu zone open the simple menu?
-- enabled: our setting (nil counts as on). activation: KOReader's
-- "activate_menu" setting ("swipe_tap", "tap" or "swipe"); with "swipe" a tap
-- opens nothing in KOReader, so it opens nothing here either.
function M.shouldIntercept(enabled, activation)
    if enabled == false then return false end
    return activation ~= "swipe"
end

--- "Page 12 of 300 · 4 %" (or just the percentage when pages are unknown).
-- fmt: optional template function (KOReader's T) and translations table.
function M.progressText(page, total, percent, tr)
    tr = tr or {}
    local pct = percent and math.floor(percent * 100 + 0.5)
    local page_part
    if page and total and total > 0 then
        page_part = string.format(tr.page_of or "Page %d of %d", page, total)
    end
    if page_part and pct then return page_part .. "  \u{00B7}  " .. pct .. " %" end
    if page_part then return page_part end
    if pct then return pct .. " %" end
    return ""
end

--- Layout of the panel. It hangs from the top edge (its top corners are off
-- screen), full width less a margin, like the Kindle's reading toolbar.
-- Returns L with L.panel, L.title_y, L.sub_y, L.tiles[i] = {x, y, w, h,
-- icon_cx, icon_cy, icon_size, label_y}, L.more = {x, y, w, h}, L.handle.
function M.layout(w, h, n)
    local u = math.min(w, h) / 1264
    local function px(v) return math.floor(v * u + 0.5) end
    local L = { u = u }
    local margin, pad, r = px(20), px(44), px(40)
    local pw = w - 2 * margin
    local x = margin
    L.radius = r
    L.left, L.right = x + pad, x + pw - pad
    L.title_y = px(30)
    L.sub_y = px(30 + 62)
    local y = px(30 + 62 + 56)
    L.divider_y = y
    y = y + px(18)
    -- 7-8 buttons: 4 + 4; 9-10: 5 + 5 (two rows keep the panel short)
    local cols = n <= 4 and math.max(n, 1) or (n <= 6 and 3 or (n <= 8 and 4 or 5))
    if w > h and n > 4 then cols = math.min(n, 10) end -- landscape: one row
    local rows = math.ceil(n / cols)
    local cw = (L.right - L.left) / cols
    local th = px(196)
    local icon = px(78)
    L.tiles = {}
    for i = 1, n do
        local row, col = math.floor((i - 1) / cols), (i - 1) % cols
        local tx = math.floor(L.left + cw * col)
        local ty = y + row * th
        L.tiles[i] = {
            x = tx, y = ty, w = math.floor(cw), h = th,
            icon_cx = math.floor(tx + cw / 2), icon_cy = ty + px(66), icon_size = icon,
            label_y = ty + px(124),
        }
    end
    L.cols, L.rows = cols, rows
    y = y + rows * th + px(10)
    local mh = px(96)
    -- More… (wide) and Exit (narrow) share the bottom row
    local gap = px(24)
    local ew = math.floor((L.right - L.left) * 0.28)
    L.more = { x = L.left, y = y, w = L.right - L.left - ew - gap, h = mh }
    L.exit = { x = L.right - ew, y = y, w = ew, h = mh }
    y = y + mh + px(26)
    L.handle = { x = x + math.floor(pw / 2) - px(60), y = y, w = px(120), h = px(12) }
    y = y + px(36)
    L.panel = { x = x, y = -r, w = pw, h = y + r }
    L.bottom = y
    return L
end

--- What a point hits: "tile", i / "more" / "exit" / "panel" / nil (outside: close).
function M.hit(L, x, y)
    local function inRect(r) return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end
    for i, t in ipairs(L.tiles) do
        if inRect(t) then return "tile", i end
    end
    if inRect(L.more) then return "more" end
    if L.exit and inRect(L.exit) then return "exit" end
    local p = L.panel
    if x >= p.x and x < p.x + p.w and y < p.y + p.h then return "panel" end
    return nil
end

return M
