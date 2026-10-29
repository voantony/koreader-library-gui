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

Core.SORTS = { "title", "author", "series", "added", "size" }

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

return Core
