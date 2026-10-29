--[[--
Pure data logic for the Library plugin.

This module has no KOReader dependencies so it can be unit-tested with a
plain LuaJIT interpreter. Everything that touches the device (file system,
metadata, reading status) is passed in as a function.
]]

local Core = {}

Core.UNKNOWN = "\u{FFFF}" -- sorts after every real name

Core.GROUPINGS = { "author", "series", "status", "format", "folder" }

Core.STATUSES = { "reading", "new", "abandoned", "complete" }

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(s)
    return s and s:lower() or ""
end

--- Split a path into directory and file name.
function Core.splitPath(path)
    local dir, name = path:match("^(.*)/([^/]+)$")
    if not dir then
        return "", path
    end
    return dir, name
end

--- Lower-cased extension of a file name, or "" when there is none.
function Core.extension(name)
    local ext = name:match("%.([^./]+)$")
    return ext and ext:lower() or ""
end

--- File name without its extension.
function Core.stem(name)
    return name:match("^(.+)%.[^./]+$") or name
end

--- Path of `path` relative to `root`, or "" when it is the root itself.
function Core.relativeDir(root, path)
    root = root:gsub("/+$", "")
    if path == root then return "" end
    local prefix = root .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

--- KOReader stores several authors as one string joined with newlines.
-- Calibre and some EPUBs use ";" or " & " instead. Returns a list.
function Core.splitAuthors(authors)
    local list = {}
    if type(authors) ~= "string" or authors == "" then
        return list
    end
    local normalized = authors:gsub("\r", ""):gsub(";", "\n"):gsub(" & ", "\n")
    local seen = {}
    for part in normalized:gmatch("[^\n]+") do
        part = trim(part)
        if part ~= "" and not seen[part] then
            seen[part] = true
            table.insert(list, part)
        end
    end
    return list
end

----------------------------------------------------------------------------
-- Scanning
----------------------------------------------------------------------------

--- Walk `root` and collect book files.
-- @tparam string root folder to scan
-- @tparam table fs `{ dir = function(path) -> iterator over names,
--   attributes = function(path) -> { mode=, size=, modification= } | nil }`
--   (shape-compatible with LuaFileSystem)
-- @tparam function is_book `function(path) -> bool`
-- @tparam[opt] table opts `{ max_depth = 10, show_hidden = false, limit = 20000 }`
-- @treturn table list of book records
-- @treturn bool true when the scan stopped early because of `limit`
function Core.scan(root, fs, is_book, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or 10
    local limit = opts.limit or 20000
    local show_hidden = opts.show_hidden
    root = root:gsub("/+$", "")
    local books = {}
    local truncated = false

    local function walk(dir, depth)
        if truncated then return end
        local ok, iter, state, init = pcall(fs.dir, dir)
        if not ok or not iter then return end
        local names = {}
        for name in iter, state, init do
            if name ~= "." and name ~= ".." then
                table.insert(names, name)
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            if truncated then return end
            local hidden = name:sub(1, 1) == "."
            if show_hidden or not hidden then
                local path = dir .. "/" .. name
                local attr = fs.attributes(path)
                if attr then
                    if attr.mode == "directory" then
                        -- *.sdr folders hold KOReader's per-book settings, never books
                        if depth < max_depth and not name:match("%.sdr$") then
                            walk(path, depth + 1)
                        end
                    elseif attr.mode == "file" and is_book(path) then
                        if #books >= limit then
                            truncated = true
                            return
                        end
                        table.insert(books, {
                            path = path,
                            name = name,
                            dir = dir,
                            folder = Core.relativeDir(root, dir),
                            ext = Core.extension(name),
                            size = attr.size or 0,
                            modification = attr.modification or 0,
                        })
                    end
                end
            end
        end
    end

    walk(root, 0)
    return books, truncated
end

----------------------------------------------------------------------------
-- Metadata
----------------------------------------------------------------------------

--- Fill in display fields from a metadata table (KOReader doc_props shape).
function Core.applyProps(book, props)
    props = props or {}
    local title = props.display_title or props.title
    if type(title) ~= "string" or trim(title) == "" then
        title = Core.stem(book.name)
    end
    book.title = trim(title)
    book.authors = Core.splitAuthors(props.authors)
    local series = props.series
    if type(series) == "string" and trim(series) ~= "" then
        book.series = trim(series)
        book.series_index = tonumber(props.series_index)
    else
        book.series = nil
        book.series_index = nil
    end
    book.keywords = type(props.keywords) == "string" and props.keywords or nil
    book.language = type(props.language) == "string" and props.language or nil
    return book
end

--- Enrich every book with metadata and status.
-- @tparam function get_props `function(path) -> props table | nil`
-- @tparam function get_status `function(path) -> "new"|"reading"|"abandoned"|"complete"`
function Core.enrich(books, get_props, get_status)
    for _, book in ipairs(books) do
        Core.applyProps(book, get_props and get_props(book.path))
        local status = get_status and get_status(book.path) or "new"
        book.status = Core.isKnownStatus(status) and status or "reading"
    end
    return books
end

function Core.isKnownStatus(status)
    for _, s in ipairs(Core.STATUSES) do
        if s == status then return true end
    end
    return false
end

----------------------------------------------------------------------------
-- Sorting
----------------------------------------------------------------------------

local function cmpText(a, b, collate)
    if collate then return collate(a, b) end
    return lower(a) < lower(b)
end

local function firstAuthor(book)
    return book.authors and book.authors[1] or Core.UNKNOWN
end

Core.SORTS = { "recent", "title", "author", "series", "added", "size" }

--- Return a comparator for `mode`.
-- @tparam[opt] function collate locale-aware `a < b` for strings
function Core.comparator(mode, collate)
    local function byTitle(a, b)
        if a.title ~= b.title then return cmpText(a.title, b.title, collate) end
        return a.path < b.path
    end
    if mode == "author" then
        return function(a, b)
            local aa, ba = firstAuthor(a), firstAuthor(b)
            if aa ~= ba then
                if aa == Core.UNKNOWN then return false end
                if ba == Core.UNKNOWN then return true end
                return cmpText(aa, ba, collate)
            end
            return byTitle(a, b)
        end
    elseif mode == "series" then
        return function(a, b)
            local as, bs = a.series or Core.UNKNOWN, b.series or Core.UNKNOWN
            if as ~= bs then
                if as == Core.UNKNOWN then return false end
                if bs == Core.UNKNOWN then return true end
                return cmpText(as, bs, collate)
            end
            local ai, bi = a.series_index, b.series_index
            if ai and bi and ai ~= bi then return ai < bi end
            if ai and not bi then return true end
            if bi and not ai then return false end
            return byTitle(a, b)
        end
    elseif mode == "recent" then
        -- Last opened first; never-opened books after them, newest file first.
        return function(a, b)
            local ao, bo = a.last_opened or 0, b.last_opened or 0
            if ao ~= bo then return ao > bo end
            if a.modification ~= b.modification then
                return (a.modification or 0) > (b.modification or 0)
            end
            return byTitle(a, b)
        end
    elseif mode == "added" then
        return function(a, b)
            if a.modification ~= b.modification then
                return a.modification > b.modification
            end
            return byTitle(a, b)
        end
    elseif mode == "size" then
        return function(a, b)
            if a.size ~= b.size then return a.size > b.size end
            return byTitle(a, b)
        end
    end
    return byTitle
end

--- Sort a copy of `books`.
function Core.sortBooks(books, mode, collate)
    local copy = {}
    for i, b in ipairs(books) do copy[i] = b end
    table.sort(copy, Core.comparator(mode, collate))
    return copy
end

----------------------------------------------------------------------------
-- Grouping
----------------------------------------------------------------------------

local function keysFor(book, grouping)
    if grouping == "author" then
        if book.authors and #book.authors > 0 then return book.authors end
        return { Core.UNKNOWN }
    elseif grouping == "series" then
        return { book.series or Core.UNKNOWN }
    elseif grouping == "status" then
        return { book.status or "new" }
    elseif grouping == "format" then
        return { book.ext ~= "" and book.ext or Core.UNKNOWN }
    elseif grouping == "folder" then
        return { book.folder or "" }
    end
    error("unknown grouping: " .. tostring(grouping))
end

--- Group books. A book with several authors appears under each of them.
-- @treturn table sorted list of `{ key = string, books = { ... } }`;
--   the unknown bucket (key == Core.UNKNOWN) always comes last.
function Core.group(books, grouping, collate)
    local buckets, order = {}, {}
    for _, book in ipairs(books) do
        for _, key in ipairs(keysFor(book, grouping)) do
            if not buckets[key] then
                buckets[key] = { key = key, books = {} }
                table.insert(order, buckets[key])
            end
            table.insert(buckets[key].books, book)
        end
    end
    local status_rank = {}
    for i, s in ipairs(Core.STATUSES) do status_rank[s] = i end
    table.sort(order, function(a, b)
        if a.key == Core.UNKNOWN then return false end
        if b.key == Core.UNKNOWN then return true end
        if grouping == "status" then
            return (status_rank[a.key] or 99) < (status_rank[b.key] or 99)
        end
        return cmpText(a.key, b.key, collate)
    end)
    return order
end

----------------------------------------------------------------------------
-- Search
----------------------------------------------------------------------------

--- True when `book` matches every whitespace-separated word of `query`
-- in its file name, title, authors, series or keywords.
function Core.matches(book, query, case_sensitive)
    if not query or trim(query) == "" then return true end
    local haystack = table.concat({
        book.name or "",
        book.title or "",
        table.concat(book.authors or {}, " "),
        book.series or "",
        book.keywords or "",
    }, "\n")
    if not case_sensitive then
        haystack = haystack:lower()
        query = query:lower()
    end
    for word in query:gmatch("%S+") do
        if not haystack:find(word, 1, true) then
            return false
        end
    end
    return true
end

function Core.search(books, query, case_sensitive)
    local results = {}
    for _, book in ipairs(books) do
        if Core.matches(book, query, case_sensitive) then
            table.insert(results, book)
        end
    end
    return results
end

----------------------------------------------------------------------------
-- Summaries
----------------------------------------------------------------------------

--- Most recently modified books first.
function Core.recent(books, n)
    local sorted = Core.sortBooks(books, "added")
    local out = {}
    for i = 1, math.min(n or 20, #sorted) do out[i] = sorted[i] end
    return out
end

--- Counts per status plus `all`.
function Core.countByStatus(books)
    local counts = { all = #books }
    for _, s in ipairs(Core.STATUSES) do counts[s] = 0 end
    for _, book in ipairs(books) do
        counts[book.status] = (counts[book.status] or 0) + 1
    end
    return counts
end

--- Human-readable byte size.
function Core.formatSize(bytes)
    bytes = bytes or 0
    if bytes < 1024 then return string.format("%d B", bytes) end
    local units = { "KB", "MB", "GB" }
    local value = bytes
    for _, unit in ipairs(units) do
        value = value / 1024
        if value < 1024 or unit == "GB" then
            return string.format("%.1f %s", value, unit)
        end
    end
end

--- Short label for a book in a list: "Title — Author".
function Core.label(book, show_series_index)
    local text = book.title or book.name
    if show_series_index and book.series_index then
        text = string.format("%s. %s", tostring(book.series_index):gsub("%.0$", ""), text)
    end
    if book.authors and book.authors[1] then
        text = text .. " — " .. table.concat(book.authors, ", ")
    end
    return text
end

----------------------------------------------------------------------------
-- Status filters (the chips under the search bar)
----------------------------------------------------------------------------

Core.FILTERS = { "all", "unread", "reading", "barely", "finished" }

local FILTER_STATUS = {
    unread = { new = true },
    reading = { reading = true },
    finished = { complete = true },
}

--- Thresholds offered for "Barely started" (fractions of the book).
Core.BARELY_THRESHOLDS = { 0.05, 0.10, 0.20, 0.25 }
Core.BARELY_DEFAULT = 0.10

--- A saved threshold, or the default when it is not one of the offered values.
function Core.barelyThreshold(v)
    v = tonumber(v)
    for _, t in ipairs(Core.BARELY_THRESHOLDS) do
        if v and math.abs(v - t) < 1e-9 then return t end
    end
    return Core.BARELY_DEFAULT
end

--- Opened, read past 0 % and below `threshold`, and not marked finished.
-- Never-opened books have no percent (no sidecar), so they never count.
function Core.isBarelyStarted(book, threshold)
    local p = tonumber(book.percent)
    if not p or p <= 0 then return false end
    if book.status == "complete" or book.status == "new" then return false end
    return p < Core.barelyThreshold(threshold)
end

local function wants(filter, book, threshold)
    if filter == "barely" then return Core.isBarelyStarted(book, threshold) end
    local wanted = FILTER_STATUS[filter]
    return wanted ~= nil and wanted[book.status or "new"] == true
end

--- Books matching a filter chip. `threshold` is for "barely".
function Core.filterStatus(books, filter, threshold)
    if filter ~= "barely" and not FILTER_STATUS[filter] then return books end
    local out = {}
    for _, b in ipairs(books) do
        if wants(filter, b, threshold) then table.insert(out, b) end
    end
    return out
end

function Core.countFilters(books, threshold)
    local counts = { all = #books }
    for _, f in ipairs(Core.FILTERS) do
        if f ~= "all" then counts[f] = 0 end
    end
    for _, b in ipairs(books) do
        for _, f in ipairs(Core.FILTERS) do
            if f ~= "all" and wants(f, b, threshold) then counts[f] = counts[f] + 1 end
        end
    end
    return counts
end

----------------------------------------------------------------------------
-- Search index
----------------------------------------------------------------------------

--- Precompute the lower-cased text searched for each book: title, authors,
-- series and file name. `lower` defaults to string.lower; KOReader passes a
-- Unicode-aware one.
function Core.buildSearchKey(book, lower)
    lower = lower or string.lower
    book.search_key = lower(table.concat({
        book.title or "",
        table.concat(book.authors or {}, " "),
        book.series or "",
        book.name or "",
    }, "\n"))
    return book.search_key
end

function Core.indexBooks(books, lower)
    for _, b in ipairs(books) do Core.buildSearchKey(b, lower) end
    return books
end

--- Split a query into lower-cased words.
function Core.queryWords(query, lower)
    lower = lower or string.lower
    local words = {}
    if type(query) ~= "string" then return words end
    for w in lower(query):gmatch("%S+") do table.insert(words, w) end
    return words
end

--- Fast search over precomputed keys. Every word must appear somewhere.
-- When `previous` (the results for a shorter prefix of this query) is
-- given, only those are scanned: typing narrows, it never widens.
function Core.searchIndexed(books, query, lower, previous)
    local words = Core.queryWords(query, lower)
    if #words == 0 then return books end
    local source = previous or books
    local out = {}
    local find = string.find
    for i = 1, #source do
        local b = source[i]
        local key = b.search_key or Core.buildSearchKey(b, lower)
        local ok = true
        for j = 1, #words do
            if not find(key, words[j], 1, true) then ok = false; break end
        end
        if ok then out[#out + 1] = b end
    end
    return out
end

--- True when `new_query` only extends `old_query` (so old results can be narrowed).
function Core.isRefinement(old_query, new_query)
    if not old_query or old_query == "" then return false end
    old_query = old_query:gsub("%s+$", "")
    if old_query == "" then return false end
    return new_query:sub(1, #old_query) == old_query
end

----------------------------------------------------------------------------
-- Paging
----------------------------------------------------------------------------

--- Return the slice for `page` (1-based) and the clamped page and page count.
function Core.page(list, per_page, page)
    local pages = math.max(1, math.ceil(#list / per_page))
    page = math.max(1, math.min(page or 1, pages))
    local out = {}
    local first = (page - 1) * per_page + 1
    for i = first, math.min(#list, first + per_page - 1) do
        out[#out + 1] = list[i]
    end
    return out, page, pages
end

--- How many columns/rows of tiles fit. Covers keep a 2:3 aspect ratio.
-- `min_ratio` (default 0.7) is how much smaller covers may get to fit one
-- more row.
function Core.gridLayout(width, height, cols, label_h, gap, min_ratio)
    cols = math.max(1, cols)
    min_ratio = min_ratio or 0.7
    gap = gap or 0
    local tile_w = math.floor((width - gap * (cols + 1)) / cols)
    local cover_h = math.floor(tile_w * 1.5)
    local tile_h = cover_h + label_h
    local rows = math.max(1, math.floor((height - gap) / (tile_h + gap)))
    -- If one more row fits with covers at least 70% as tall, prefer it:
    -- a fuller page beats big covers and a blank strip at the bottom.
    local more = rows + 1
    local cover_more = math.floor((height - gap) / more) - gap - label_h
    if cover_more >= min_ratio * cover_h then
        rows, cover_h = more, cover_more
        tile_h = cover_h + label_h
    end
    -- If even one row does not fit, shrink covers to the space we have.
    if tile_h + 2 * gap > height then
        tile_h = math.max(label_h + 10, height - 2 * gap)
        cover_h = tile_h - label_h
    end
    return { cols = cols, rows = rows, tile_w = tile_w, tile_h = tile_h, cover_h = cover_h, per_page = cols * rows }
end

--- How many list rows fit, one book (or group) per row.
-- `min_row_h` is the smallest row that fits the text; rows are stretched to
-- fill the height exactly so the footer stays put. The thumbnail keeps the
-- 2:3 cover ratio inside the row's padding. `opts.max_rows` caps the rows
-- (taller rows instead of a crowded page on big screens).
-- @treturn table `{ rows, row_h, thumb_w, thumb_h, per_page }`
function Core.listLayout(height, min_row_h, pad, opts)
    pad = pad or 0
    min_row_h = math.max(1, min_row_h)
    local rows = math.max(1, math.floor(height / min_row_h))
    if opts and opts.max_rows then rows = math.min(rows, opts.max_rows) end
    local row_h = math.max(min_row_h, math.floor(height / rows))
    if rows == 1 then row_h = math.max(1, math.min(row_h, height)) end
    local thumb_h = math.max(1, row_h - 2 * pad)
    local thumb_w = math.max(1, math.floor(thumb_h * 2 / 3 + 0.5))
    return { rows = rows, row_h = row_h, thumb_w = thumb_w, thumb_h = thumb_h, per_page = rows }
end

Core.VIEWS = { "grid", "list" }

--- A saved view mode, falling back to "grid".
function Core.viewMode(v)
    if v == "list" then return "list" end
    return "grid"
end

----------------------------------------------------------------------------
-- Continue reading
----------------------------------------------------------------------------

--- Books being read (status "reading"), most recently opened first.
-- Finished, on-hold and unread books are left out. Books with no history
-- entry come after opened ones, then by file date.
function Core.continueReading(books, n)
    local picked = {}
    for _, b in ipairs(books) do
        if b.status == "reading" then picked[#picked + 1] = b end
    end
    table.sort(picked, Core.comparator("recent"))
    local out = {}
    for i = 1, math.min(n or 5, #picked) do out[i] = picked[i] end
    return out
end

--- Books you have opened, most recently opened first, whatever their status
-- (reading, finished, on hold, or opened but still unread). Books with no
-- History entry are left out, and so are books whose file is gone, when
-- `exists(path)` is given (it is only asked about the books that would show).
function Core.recentlyOpened(books, n, exists)
    local picked = {}
    for _, b in ipairs(books) do
        if type(b.last_opened) == "number" and b.last_opened > 0 then picked[#picked + 1] = b end
    end
    table.sort(picked, Core.comparator("recent"))
    local out = {}
    n = n or 5
    for _, b in ipairs(picked) do
        if #out >= n then break end
        if not exists or exists(b.path) then out[#out + 1] = b end
    end
    return out
end

--- The top row of the Books tab: "continue" (Continue reading, the default)
-- or "recent" (Recently opened).
Core.TOP_ROWS = { "continue", "recent" }
function Core.topRow(v)
    if v == "recent" then return "recent" end
    return "continue"
end

--- Store the top row choice in the plugin's `settings` and save them with
-- `save()`. Returns the stored value ("continue" for anything unknown).
function Core.setTopRow(settings, mode, save)
    settings.top_row = Core.topRow(mode)
    if save then save() end
    return settings.top_row
end

--- The books for the top row in `mode`.
function Core.topRowBooks(mode, books, n, exists)
    if Core.topRow(mode) == "recent" then return Core.recentlyOpened(books, n, exists) end
    return Core.continueReading(books, n)
end

--- Whether the Continue reading strip belongs on screen now.
-- @tparam table state `{ enabled, tab, group, query, filter, keyboard }`
function Core.showContinue(state)
    if not state.enabled then return false end
    if state.tab ~= "books" or state.group then return false end
    if state.query and state.query:match("%S") then return false end
    if state.filter and state.filter ~= "all" then return false end
    if state.keyboard then return false end
    return true
end

--- Size the Continue reading strip.
-- `body_h` is the height of the grid area before the strip takes its share;
-- `label_h` is the text under each cover and `header_h` the strip's heading.
-- Up to `slots` equal slots across the width; covers are 2:3.
-- Returns nil when there is nothing to show or when the books below would
-- be left less than `min_rest` pixels.
-- @treturn table `{ count, slots, slot_w, cover_h, tile_h, height }`
function Core.continueLayout(width, body_h, n_books, label_h, header_h, gap, opts)
    opts = opts or {}
    local slots = opts.slots or 5
    local frac = opts.frac or 0.22
    local min_rest = opts.min_rest or 0
    gap = gap or 0
    if n_books <= 0 then return nil end
    local slot_w = math.floor((width - gap * (slots + 1)) / slots)
    -- cover height: a share of the body, but never wider than the slot allows
    local cover_h = math.min(math.floor(body_h * frac), math.floor(slot_w * 1.5))
    if cover_h < 2 * label_h then return nil end
    local tile_h = cover_h + label_h
    local height = header_h + tile_h + gap
    if body_h - height < min_rest then return nil end
    return {
        count = math.min(n_books, slots),
        slots = slots,
        slot_w = slot_w,
        cover_h = cover_h,
        tile_h = tile_h,
        height = height,
    }
end

--- The book to resume: the most recently opened book still being read.
function Core.resumeBook(books)
    return Core.continueReading(books, 1)[1]
end

--- "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago", or nil
-- (no time, or older than `max_days`, default 30: the caller shows a date).
function Core.relativeTime(ts, now, max_days)
    ts, now = tonumber(ts), tonumber(now)
    if not ts or not now or ts <= 0 then return nil end
    local d = math.max(0, now - ts)
    if d < 60 then return "just now" end
    if d < 3600 then return string.format("%d min ago", math.floor(d / 60)) end
    if d < 86400 then return string.format("%d h ago", math.floor(d / 3600)) end
    local days = math.floor(d / 86400)
    if days == 1 then return "yesterday" end
    if days <= (max_days or 30) then return string.format("%d days ago", days) end
    return nil
end

--- Whole percent read, e.g. 0.426 -> 43. nil without a percent.
function Core.percentText(p)
    p = tonumber(p)
    if not p then return nil end
    return string.format("%d %%", math.floor(math.max(0, math.min(1, p)) * 100 + 0.5))
end

----------------------------------------------------------------------------
-- Series
----------------------------------------------------------------------------

--- "3", "2.5" or nil.
function Core.seriesNumber(idx)
    idx = tonumber(idx)
    if not idx then return nil end
    if idx == math.floor(idx) then return string.format("%d", idx) end
    return (string.format("%.2f", idx):gsub("0+$", ""):gsub("%.$", ""))
end

--- A series' books in reading order: by series_index; books without one
-- go last, by title (then path, so the order is stable).
function Core.seriesOrder(books, collate)
    local copy = {}
    for i, b in ipairs(books) do copy[i] = b end
    table.sort(copy, function(a, b)
        local ai, bi = tonumber(a.series_index), tonumber(b.series_index)
        if ai and bi and ai ~= bi then return ai < bi end
        if ai and not bi then return true end
        if bi and not ai then return false end
        local at, bt = a.title or a.name or "", b.title or b.name or ""
        if at ~= bt then return cmpText(at, bt, collate) end
        return (a.path or "") < (b.path or "")
    end)
    return copy
end

--- Every book of `series`, in reading order.
function Core.seriesBooks(books, series, collate)
    local out = {}
    if not series then return out end
    for _, b in ipairs(books) do
        if b.series == series then out[#out + 1] = b end
    end
    return Core.seriesOrder(out, collate)
end

--- `{ read = finished books, total = books }` for a series.
function Core.seriesProgress(books)
    local read = 0
    for _, b in ipairs(books) do
        if b.status == "complete" then read = read + 1 end
    end
    return { read = read, total = #books }
end

--- Which book to open after (`dir` = 1) or before (`dir` = -1) `current`
-- in its series. `ordered` is Core.seriesOrder output and holds `current`
-- (matched by path).
-- Next: the first later book that is not finished; if every later book is
-- finished, simply the next one. Previous: the one just before.
-- Copies of the current book (same series number, e.g. an EPUB and a PDF)
-- are skipped. Returns nil at either end, or when `current` is not there.
-- `opts.skip_finished = false` makes Next the plain next book.
function Core.seriesNeighbour(ordered, current, dir, opts)
    if not current then return nil end
    local pos
    for i, b in ipairs(ordered) do
        if b.path == current.path then pos = i; break end
    end
    if not pos then return nil end
    local cur_idx = tonumber(current.series_index)
    local function same_number(b)
        return cur_idx ~= nil and tonumber(b.series_index) == cur_idx
    end
    local first
    local i = pos + dir
    while ordered[i] do
        local b = ordered[i]
        if not same_number(b) then
            if dir < 0 then return b end
            first = first or b
            if b.status ~= "complete" or (opts and opts.skip_finished == false) then return b end
        end
        i = i + dir
    end
    return first
end

----------------------------------------------------------------------------
-- Calibre metadata (metadata.calibre written by calibre or the Calibre plugin)
----------------------------------------------------------------------------

local function plain(v)
    -- rapidjson null and other userdata/cdata become nil
    if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then return v end
    return nil
end

--- Turn calibre's list into `{ [absolute path] = props }`.
-- `entries` is the decoded JSON array; `base_dir` is the folder holding the
-- metadata.calibre file (calibre's lpath values are relative to it).
function Core.calibreIndex(entries, base_dir)
    local map = {}
    base_dir = (base_dir or ""):gsub("/+$", "")
    if type(entries) ~= "table" then return map end
    for _, e in ipairs(entries) do
        local lpath = type(e) == "table" and plain(e.lpath)
        if type(lpath) == "string" and lpath ~= "" then
            local authors = {}
            if type(e.authors) == "table" then
                for _, a in ipairs(e.authors) do
                    if type(a) == "string" and a ~= "" then table.insert(authors, a) end
                end
            end
            local path = lpath:sub(1, 1) == "/" and lpath or (base_dir .. "/" .. lpath)
            map[path] = {
                title = plain(e.title),
                authors = #authors > 0 and table.concat(authors, "\n") or nil,
                series = plain(e.series),
                series_index = tonumber(plain(e.series_index)),
                keywords = type(e.tags) == "table" and table.concat(e.tags, "\n") or nil,
            }
        end
    end
    return map
end

--- Candidate folders that may hold a metadata.calibre for `root`:
-- the root and each parent (calibre writes it at the device root,
-- e.g. /mnt/us, with lpaths like "documents/...").
function Core.calibreCandidateDirs(root, extra)
    local dirs, seen = {}, {}
    local function add(d)
        if d and d ~= "" and not seen[d] then seen[d] = true; table.insert(dirs, d) end
    end
    local d = root:gsub("/+$", "")
    while d and d ~= "" do
        add(d)
        d = d:match("^(.*)/[^/]*$")
    end
    for _, e in ipairs(extra or {}) do add((e:gsub("/+$", ""))) end
    return dirs
end

----------------------------------------------------------------------------
-- Incremental index cache
----------------------------------------------------------------------------

Core.CACHE_VERSION = 2

--- Decide which scanned files can reuse cached metadata.
-- A cached entry is reused when path, size, mtime and the calibre stamp match.
-- @treturn table list of books (cached metadata copied in where valid)
-- @treturn table list of books that need fresh metadata
function Core.reconcile(scanned, cache_entries, calibre_stamp)
    local reused, stale = {}, {}
    cache_entries = cache_entries or {}
    for _, f in ipairs(scanned) do
        local c = cache_entries[f.path]
        if c and c.size == f.size and c.modification == f.modification
                and c.cal == calibre_stamp and c.src ~= "file" then
            f.title, f.authors, f.series, f.series_index = c.title, c.authors, c.series, c.series_index
            f.keywords, f.src, f.cal = c.keywords, c.src, c.cal
            f.sc_mtime, f.status, f.percent = c.sc_mtime, c.status, c.percent
            table.insert(reused, f)
        else
            -- keep reading state; only metadata is stale
            if c then f.sc_mtime, f.status, f.percent = c.sc_mtime, c.status, c.percent end
            table.insert(stale, f)
        end
    end
    return reused, stale
end

local CACHED_FIELDS = {
    "size", "modification", "title", "authors", "series", "series_index",
    "keywords", "src", "cal", "sc_mtime", "status", "percent",
}

function Core.toCacheEntries(books)
    local entries = {}
    for _, b in ipairs(books) do
        local e = {}
        for _, k in ipairs(CACHED_FIELDS) do e[k] = b[k] end
        entries[b.path] = e
    end
    return entries
end

--- Serialize a plain table (strings, numbers, booleans, nested tables) to Lua source.
function Core.serialize(value)
    local buf = {}
    local function emit(v)
        local t = type(v)
        if t == "string" then
            buf[#buf + 1] = string.format("%q", v)
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then
                buf[#buf + 1] = "0"
            elseif v == math.floor(v) and math.abs(v) < 2^53 then
                buf[#buf + 1] = string.format("%d", v)
            else
                buf[#buf + 1] = string.format("%.17g", v)
            end
        elseif t == "boolean" then
            buf[#buf + 1] = tostring(v)
        elseif t == "table" then
            buf[#buf + 1] = "{"
            local n = #v
            for i = 1, n do emit(v[i]); buf[#buf + 1] = "," end
            local keys = {}
            for k in pairs(v) do
                if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                    table.insert(keys, k)
                end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                buf[#buf + 1] = "["
                emit(k)
                buf[#buf + 1] = "]="
                emit(v[k])
                buf[#buf + 1] = ","
            end
            buf[#buf + 1] = "}"
        else
            buf[#buf + 1] = "nil"
        end
    end
    emit(value)
    return "return " .. table.concat(buf)
end

--- Load serialized data in an empty environment. Returns nil on any error.
function Core.deserialize(source)
    if type(source) ~= "string" then return nil end
    local fn = loadstring(source)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, data = pcall(fn)
    if ok and type(data) == "table" then return data end
    return nil
end

--- Put `id` into a menu-order list just before `before` (at the end when
-- `before` is missing), or take it out when not `enabled`. Idempotent.
function Core.placeMenuButton(buttons, id, before, enabled)
    for i = #buttons, 1, -1 do
        if buttons[i] == id then table.remove(buttons, i) end
    end
    if not enabled then return buttons end
    local at = #buttons + 1
    for i, v in ipairs(buttons) do
        if v == before then at = i; break end
    end
    table.insert(buttons, at, id)
    return buttons
end

----------------------------------------------------------------------------
-- Sleep screen: cover of the last book (KOReader's own "cover" screensaver)
----------------------------------------------------------------------------
-- `gs` is a small view of G_reader_settings: { read = f(key), save = f(key, value), del = f(key) }.
-- KOReader's "cover" sleep screen shows the cover of `lastfile` (the last book
-- opened), in the reader and in the file browser, unless
-- screensaver_hide_cover_in_filemanager is set. With no cover it falls back
-- to its own random-image / default picture.

local SLEEP_KEYS = { "screensaver_type", "screensaver_hide_cover_in_filemanager" }

--- True when KOReader will show the last book's cover everywhere.
function Core.sleepCoverOn(gs)
    return gs.read("screensaver_type") == "cover"
        and gs.read("screensaver_hide_cover_in_filemanager") ~= true
end

--- Switch KOReader's sleep screen to the last book's cover. Returns the
-- previous values (to keep for sleepCoverOff), or nil when it was already on.
function Core.sleepCoverEnable(gs)
    if Core.sleepCoverOn(gs) then return nil end
    local prev = {} -- prev[key] = { value = v }; {} when the key was unset
    for _, k in ipairs(SLEEP_KEYS) do
        prev[k] = { value = gs.read(k) }
    end
    gs.save("screensaver_type", "cover")
    if gs.read("screensaver_hide_cover_in_filemanager") == true then
        gs.save("screensaver_hide_cover_in_filemanager", false)
    end
    return prev
end

--- Put back what sleepCoverEnable replaced. Without saved values (cover was
-- chosen in KOReader's own menu), fall back to KOReader's default: "disable"
-- (leave the screen as it is).
function Core.sleepCoverDisable(gs, prev)
    if not prev then
        gs.save("screensaver_type", "disable")
        return
    end
    for _, k in ipairs(SLEEP_KEYS) do
        local v = prev[k] and prev[k].value
        if v == nil then gs.del(k) else gs.save(k, v) end
    end
end

return Core
