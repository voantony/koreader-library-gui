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
-- What counts as a book
----------------------------------------------------------------------------

-- Book formats the Library lists. KOReader's DocumentRegistry also accepts
-- scripts and config files (crengine registers .sh, .lua, .py, .js, .json,
-- .ini, .log ... as plain text), so "KOReader can open it" is not enough.
Core.BOOK_EXTENSIONS = {
    epub = true, pdf = true, mobi = true, azw3 = true, azw = true, prc = true,
    fb2 = true, cbz = true, cbr = true, cb7 = true, djvu = true, djv = true,
    xps = true, chm = true, docx = true, rtf = true, odt = true, txt = true,
}

-- Never books, even if a later edit adds them above by mistake.
Core.NON_BOOK_EXTENSIONS = {
    sh = true, lua = true, py = true, js = true, json = true, ini = true, log = true,
}

--- True when the file name has a book format extension (case-insensitive).
-- `foo.fb2.zip` counts; a bare `.zip` does not.
function Core.isBookName(name)
    if type(name) ~= "string" then return false end
    local _, base = Core.splitPath(name)
    local l = base:lower()
    if l:match("%.fb2%.zip$") then return true end
    local ext = Core.extension(l)
    if Core.NON_BOOK_EXTENSIONS[ext] then return false end
    return Core.BOOK_EXTENSIONS[ext] == true
end

--- Build an `is_book(path)` predicate: a book format AND openable by KOReader.
-- @tparam[opt] function has_provider `function(path) -> bool`
function Core.makeIsBook(has_provider)
    return function(path)
        if not Core.isBookName(path) then return false end
        if has_provider then
            local ok, res = pcall(has_provider, path)
            return ok and res and true or false
        end
        return true
    end
end

--- Folder names never scanned: KOReader's own install folder.
Core.SKIP_DIR_NAMES = { koreader = true }

----------------------------------------------------------------------------
-- Scanning
----------------------------------------------------------------------------

--- Walk `root` and collect book files.
-- @tparam string root folder to scan
-- @tparam table fs `{ dir = function(path) -> iterator over names,
--   attributes = function(path) -> { mode=, size=, modification= } | nil }`
--   (shape-compatible with LuaFileSystem)
-- @tparam function is_book `function(path) -> bool`
-- @tparam[opt] table opts `{ max_depth = 10, show_hidden = false, limit = 20000,
--   skip_dirs = { "/abs/path", ... } }`. Folders named `koreader` (the
--   install folder) and every path in `skip_dirs` are never walked.
-- @treturn table list of book records
-- @treturn bool true when the scan stopped early because of `limit`
function Core.scan(root, fs, is_book, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or 10
    local limit = opts.limit or 20000
    local show_hidden = opts.show_hidden
    root = root:gsub("/+$", "")
    local skip = {}
    for _, d in ipairs(opts.skip_dirs or {}) do
        if type(d) == "string" and d ~= "" then
            skip[(d:gsub("/+$", ""))] = true
        end
    end
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
                        if depth < max_depth and not name:match("%.sdr$")
                                and not Core.SKIP_DIR_NAMES[name:lower()]
                                and not skip[path] then
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

-- The ☰ menu's sort order: Author, Title, Date added, Last read, then Series.
Core.SORT_MENU = { "author", "title", "added", "recent", "series" }
Core.SORTS = { "author", "title", "added", "recent", "series", "size" }

--- Return a comparator for `mode`.
-- @tparam[opt] function collate locale-aware `a < b` for strings
function Core.comparator(mode, collate)
    local function byTitle(a, b)
        if a.title ~= b.title then return cmpText(a.title, b.title, collate) end
        return a.path < b.path
    end
    -- Author (unknown last), then title within an author.
    local function byAuthor(a, b)
        local aa, ba = firstAuthor(a), firstAuthor(b)
        if aa ~= ba then
            if aa == Core.UNKNOWN then return false end
            if ba == Core.UNKNOWN then return true end
            return cmpText(aa, ba, collate)
        end
        return byTitle(a, b)
    end
    if mode == "author" then
        return byAuthor
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
        -- Last opened first; never-opened books (and equal times) by author.
        return function(a, b)
            local ao, bo = a.last_opened or 0, b.last_opened or 0
            if ao ~= bo then return ao > bo end
            return byAuthor(a, b)
        end
    elseif mode == "added" then
        -- Newest first.
        return function(a, b)
            local am, bm = a.modification or 0, b.modification or 0
            if am ~= bm then return am > bm end
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
-- Genres (from the keywords / Calibre tags already in the index)
----------------------------------------------------------------------------

--- Split a keywords string into genre names: on new lines, commas and
-- semicolons (never on "&": "Mystery & Thriller" is one genre), trimmed.
function Core.splitKeywords(s)
    local out = {}
    if type(s) ~= "string" then return out end
    for part in s:gmatch("[^\n\r,;]+") do
        part = trim(part):gsub("%s+", " ")
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

--- Union of two keywords strings (e.g. Calibre tags and the book's own
-- subjects), split as above, without repeats (case-insensitive), joined by
-- new lines. Nil when both are empty.
function Core.mergeKeywords(a, b)
    local out, seen = {}, {}
    for i = 1, 2 do
        for _, k in ipairs(Core.splitKeywords(i == 1 and a or b)) do
            local key = k:lower()
            if not seen[key] then seen[key] = true; out[#out + 1] = k end
        end
    end
    return #out > 0 and table.concat(out, "\n") or nil
end

--- Group books by genre. Names are merged case-insensitively (`lower`, a
-- UTF-8 aware lower-caser, defaults to string.lower) and shown in their most
-- common spelling. A book with several genres is in each; books with none
-- are in one group (`unsorted = true`, named `unsorted_name`) at the end.
-- @treturn table list of `{ kind = "genres", name =, books = }`, by name
function Core.genreGroups(books, collate, lower, unsorted_name)
    lower = lower or string.lower
    local buckets, order, none = {}, {}, {}
    for _, book in ipairs(books) do
        local seen = {}
        for _, name in ipairs(Core.splitKeywords(book.keywords)) do
            local key = lower(name)
            if not seen[key] then
                seen[key] = true
                local g = buckets[key]
                if not g then
                    g = { kind = "genres", books = {}, spellings = {}, first = {} }
                    buckets[key] = g
                    order[#order + 1] = g
                end
                g.spellings[name] = (g.spellings[name] or 0) + 1
                if not g.first[name] then g.first[name] = #g.books + 1 end
                g.books[#g.books + 1] = book
            end
        end
        if not next(seen) then none[#none + 1] = book end
    end
    for _, g in ipairs(order) do
        local best
        for name, n in pairs(g.spellings) do
            local bn = best and g.spellings[best]
            if not best or n > bn or (n == bn and g.first[name] < g.first[best]) then best = name end
        end
        g.name = best
        g.spellings, g.first = nil, nil
    end
    table.sort(order, function(a, b)
        if a.name ~= b.name then return cmpText(a.name, b.name, collate) end
        return false
    end)
    if #none > 0 then
        order[#order + 1] = { kind = "genres", name = unsorted_name or "Unsorted", books = none, unsorted = true }
    end
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
-- Typo-tolerant search ("Typo-tolerant search", on unless turned off)
----------------------------------------------------------------------------
--
-- Each book gets, once, when it is indexed (Core.buildSearchKey):
--   search_norm   title, authors, series and file name (its search_key),
--                 with accents folded (Brontë -> bronte) and punctuation
--                 turned into spaces;
--   search_tokens the words of search_norm.
-- A query word then matches a book when it is a substring of search_norm,
-- or, for words of 4+ letters, when it is within a small edit distance of
-- the start of one of the book's words (so a typo is forgiven while the
-- word is still being typed). Distances are memoised per (query word, book
-- word), so every keystroke only computes words it has not met before.

--- Accented Latin letters (both cases) -> plain ASCII, keyed by UTF-8 sequence.
local FOLD = {}
do
    local groups = {
        a = "àáâãäåāăąǎÀÁÂÃÄÅĀĂĄǍ", c = "çćĉċčÇĆĈĊČ", d = "ďđðĎĐÐ",
        e = "èéêëēĕėęěÈÉÊËĒĔĖĘĚ", g = "ĝğġģĜĞĠĢ", h = "ĥħĤĦ",
        i = "ìíîïĩīĭįıǐÌÍÎÏĨĪĬĮİǏ", j = "ĵĴ", k = "ķĶ", l = "ĺļľŀłĹĻĽĿŁ",
        n = "ñńņňŉÑŃŅŇ", o = "òóôõöøōŏőǒÒÓÔÕÖØŌŎŐǑ", r = "ŕŗřŔŖŘ",
        s = "śŝşšŚŜŞŠ", t = "ţťŧŢŤŦ", u = "ùúûüũūŭůűųǔÙÚÛÜŨŪŬŮŰŲǓ",
        w = "ŵŴ", y = "ýÿŷÝŸŶ", z = "źżžŹŻŽ",
        ss = "ß", ae = "æÆ", oe = "œŒ", th = "þÞ",
    }
    for plain, chars in pairs(groups) do
        for ch in chars:gmatch("[\192-\247][\128-\191]*") do FOLD[ch] = plain end
    end
end
Core.FOLD = FOLD

--- Lower-case, fold accents, drop apostrophes and turn other punctuation
-- into spaces. Letters of other scripts are kept as they are.
function Core.normalizeText(s, lower)
    if type(s) ~= "string" or s == "" then return "" end
    s = (lower or string.lower)(s)
    if s:find("[\128-\255]") then
        s = s:gsub("[\195-\201][\128-\191]", FOLD)
        s = s:gsub("\226\128[\152\153]", "") -- ‘ ’
        s = s:gsub("\226\128[\147\148\156\157\166]", " ") -- – — “ ” …
        s = s:gsub("\194[\160-\191]", " ") -- no-break space, « » ¿ ¡ · etc.
        s = s:lower() -- folded capitals
    end
    if s:find("[%c%p]") then
        s = s:gsub("'", ""):gsub("[%c%p]", " ")
    end
    return s
end

--- Edits forgiven in a query word of `n` letters.
function Core.typoBudget(n)
    if n >= 8 then return 2 elseif n >= 4 then return 1 end
    return 0
end

local byte = string.byte
local min = math.min
-- reusable rows for the distance table
local row2, row1, row0 = {}, {}, {}

--- Smallest Damerau-Levenshtein (optimal string alignment) distance between
-- `q` and any prefix of `t`, or nil when it is above `cap`. Columns walk `t`
-- one letter at a time; it gives up as soon as a whole column is over `cap`.
function Core.prefixDistance(q, t, cap)
    local n, m = #q, #t
    if m < n - cap then return nil end
    local prev2, prev, cur = row2, row1, row0
    for i = 0, n do prev[i] = i end
    local best = prev[n]
    local tj1 -- t's previous letter
    for j = 1, m do
        local tj = byte(t, j)
        cur[0] = j
        local colmin = j
        local qi1
        for i = 1, n do
            local qi = byte(q, i)
            local cost = (qi == tj) and 0 or 1
            local v = prev[i - 1] + cost
            local del = prev[i] + 1
            if del < v then v = del end
            local ins = cur[i - 1] + 1
            if ins < v then v = ins end
            if i > 1 and j > 1 and qi == tj1 and qi1 == tj then
                local tr = prev2[i - 2] + 1
                if tr < v then v = tr end
            end
            cur[i] = v
            if v < colmin then colmin = v end
            qi1 = qi
        end
        if cur[n] < best then best = cur[n] end
        if best == 0 or colmin > cap then break end
        prev2, prev, cur = prev, cur, prev2
        tj1 = tj
    end
    if best <= cap then return best end
    return nil
end

-- memo[query word][book word] = distance or false; reset when it grows big.
local memo, memo_words = {}, 0

local function wordCost(word, budget, tokens)
    local cache = memo[word]
    if not cache then
        if memo_words >= 64 then memo, memo_words = {}, 0 end
        cache = {}
        memo[word] = cache
        memo_words = memo_words + 1
    end
    local best
    for k = 1, #tokens do
        local t = tokens[k]
        local d = cache[t]
        if d == nil then
            d = Core.prefixDistance(word, t, budget) or false
            cache[t] = d
        end
        if d and (not best or d < best) then
            best = d
            if d == 0 then break end
        end
    end
    return best
end

--- How well `book` matches the normalised query words:
-- 0 = every word is a substring (after folding), n > 0 = total edits, nil = no match.
function Core.fuzzyScore(book, words, lower)
    local norm = book.search_norm
    if not norm then Core.buildSearchKey(book, lower); norm = book.search_norm end
    local find = string.find
    local total = 0
    for j = 1, #words do
        local w = words[j]
        if not find(norm, w, 1, true) then
            local budget = Core.typoBudget(#w)
            if budget == 0 then return nil end
            local d = wordCost(w, budget, book.search_tokens)
            if not d then return nil end
            total = total + d
        end
    end
    return total
end

--- Search with typos forgiven. Order: books where every word is found as
-- typed (the plain search), then books that match once accents and
-- punctuation are ignored, then close matches by number of edits. Within
-- each group the order of `books` is kept.
function Core.searchFuzzy(books, query, lower)
    local raw = Core.queryWords(query, lower)
    if #raw == 0 then return books end
    local words = {}
    for w in Core.normalizeText(query, lower):gmatch("%S+") do words[#words + 1] = w end
    local exact, buckets, maxd = {}, {}, 0
    local find = string.find
    for i = 1, #books do
        local b = books[i]
        local key = b.search_key or Core.buildSearchKey(b, lower)
        local ok = true
        for j = 1, #raw do
            if not find(key, raw[j], 1, true) then ok = false; break end
        end
        if ok then
            exact[#exact + 1] = b
        elseif #words > 0 then
            local d = Core.fuzzyScore(b, words, lower)
            if d then
                local bucket = buckets[d]
                if not bucket then bucket = {}; buckets[d] = bucket end
                bucket[#bucket + 1] = b
                if d > maxd then maxd = d end
            end
        end
    end
    for d = 0, maxd do
        local bucket = buckets[d]
        if bucket then
            for k = 1, #bucket do exact[#exact + 1] = bucket[k] end
        end
    end
    return exact
end

--- "Typo-tolerant search": on unless turned off.
function Core.fuzzySearch(settings)
    return not (settings and settings.fuzzy_search == false)
end

----------------------------------------------------------------------------
-- Search index
----------------------------------------------------------------------------

--- Precompute the lower-cased text searched for each book: title, authors,
-- series and file name. `lower` defaults to string.lower; KOReader passes a
-- Unicode-aware one.
function Core.buildSearchKey(book, lower)
    lower = lower or string.lower
    local authors = table.concat(book.authors or {}, " ")
    book.search_key = lower(table.concat({
        book.title or "",
        authors,
        book.series or "",
        book.name or "",
    }, "\n"))
    -- for "Typo-tolerant search" (see Core.searchFuzzy)
    local norm = Core.normalizeText(book.search_key)
    local tokens, n = {}, 0
    for w in norm:gmatch("%S+") do n = n + 1; tokens[n] = w end
    book.search_norm, book.search_tokens = norm, tokens
    local into = book.search_into -- (a shelf: keep the key on the shelf itself)
    if into then
        into.search_key, into.search_norm, into.search_tokens = book.search_key, norm, tokens
    end
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
-- With `fuzzy`, typos are forgiven (Core.searchFuzzy); `previous` is then
-- ignored, since a longer word may forgive more and results are ranked.
function Core.searchIndexed(books, query, lower, previous, fuzzy)
    if fuzzy then return Core.searchFuzzy(books, query, lower) end
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

--- What the search bar searches here: the books of an open shelf, all
-- books on the Books tab, else the shelves of the tab ("authors",
-- "series", "collections").
function Core.searchScope(tab, group)
    if group or tab == "books" or tab == nil then return "books" end
    return tab
end

--- The distinct authors of `books`, in order of first appearance.
function Core.groupAuthors(books)
    local seen, out = {}, {}
    for _, b in ipairs(books or {}) do
        for _, a in ipairs(b.authors or {}) do
            if a ~= "" and not seen[a] then seen[a] = true; out[#out + 1] = a end
        end
    end
    return out
end

--- Search a tab's shelves by name, with the same matcher as books
-- (typos forgiven when `fuzzy`). A series also matches its authors.
function Core.searchGroups(groups, query, lower, fuzzy)
    for _, g in ipairs(groups) do
        if not g.search_key then
            if g.kind == "series" and not g.authors then g.authors = Core.groupAuthors(g.books) end
            -- the key holds only the name (and a series' authors)
            Core.buildSearchKey({ name = g.name, authors = g.kind == "series" and g.authors or nil,
                search_into = g }, lower)
        end
    end
    return Core.searchIndexed(groups, query, lower, nil, fuzzy)
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

-- grid: covers; list: a row per item (covers for books, text for authors
-- and series); compact: one line per row, many rows per page.
Core.VIEWS = { "grid", "list", "compact", "compact2" }

--- A saved view mode, falling back to "grid".
function Core.viewMode(v)
    if v == "list" or v == "compact" or v == "compact2" then return v end
    return "grid"
end

--- The ☰ menu's View picker: three cover sizes (columns), List, Compact.
Core.VIEW_PICKER = {
    { id = "small", view = "grid", columns = 5 },
    { id = "medium", view = "grid", columns = 4 },
    { id = "large", view = "grid", columns = 3 },
    { id = "list", view = "list" },
    { id = "compact", view = "compact" },
    { id = "compact2", view = "compact2" },
}

--- One line per row (Compact, or Compact in two columns).
function Core.isCompact(view_mode)
    return view_mode == "compact" or view_mode == "compact2"
end

--- Columns of rows: 2 for "compact2", else 1.
function Core.listColumns(view_mode)
    return view_mode == "compact2" and 2 or 1
end

--- Split a page into `cols` columns of up to `rows`, filled column by
-- column (down the left column, then the right).
function Core.columnMajor(items, rows, cols)
    local out = {}
    for c = 1, cols do
        local col = {}
        for r = 1, rows do
            local item = items[(c - 1) * rows + r]
            if item == nil then break end
            col[#col + 1] = item
        end
        out[c] = col
    end
    return out
end

--- Which picker entry is showing now (nil: a grid at another column count).
function Core.viewPick(view_mode, columns)
    view_mode = Core.viewMode(view_mode)
    for _, p in ipairs(Core.VIEW_PICKER) do
        if p.view == view_mode and (p.columns == nil or p.columns == columns) then return p.id end
    end
    return nil
end

--- List rows of shelves are text only (no cover art) on Authors and Series.
function Core.textRows(view_mode, kind, tab)
    return Core.viewMode(view_mode) == "list" and kind == "groups" and (tab == "authors" or tab == "series")
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

--- The grid's books minus those already in the top row (matched by path),
-- so a book is never on screen twice. Order is kept; `items` is not changed.
function Core.withoutShown(items, shown)
    if not shown or #shown == 0 then return items end
    local skip = {}
    for _, b in ipairs(shown) do if b.path then skip[b.path] = true end end
    local out = {}
    for _, it in ipairs(items) do
        if not (it.path and skip[it.path]) then out[#out + 1] = it end
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

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- A short date for a row: "Just now", "5m ago", "2h ago", "Yesterday",
-- "12 Oct", or "12 Oct 2024" in another year. nil without a time.
function Core.shortDate(ts, now)
    ts, now = tonumber(ts), tonumber(now)
    if not ts or ts <= 0 then return nil end
    now = now or os.time()
    local d = now - ts
    if d >= 0 and d < 60 then return "Just now" end
    if d >= 0 and d < 3600 then return string.format("%dm ago", math.floor(d / 60)) end
    if d >= 0 and d < 86400 then return string.format("%dh ago", math.floor(d / 3600)) end
    local t, n = os.date("*t", ts), os.date("*t", now)
    local y = os.date("*t", now - 86400)
    if t.year == y.year and t.yday == y.yday then return "Yesterday" end
    local s = t.day .. " " .. MONTHS[t.month]
    if t.year ~= n.year then s = s .. " " .. t.year end
    return s
end

--- The date a row shows for its sort: when it was last opened (Last read)
-- or added (Date added); nil for other sorts and never-opened books.
function Core.sortDate(book, sort, now)
    if not book then return nil end
    if sort == "recent" then return Core.shortDate(book.last_opened, now) end
    if sort == "added" then return Core.shortDate(book.modification, now) end
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
--- Move `id` to the front of a menu order list (added once, however often called).
function Core.placeFirst(list, id)
    for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
    end
    table.insert(list, 1, id)
    return list
end

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

----------------------------------------------------------------------------
-- Look
----------------------------------------------------------------------------

--- How to put a `src_w` x `src_h` cover into a `box_w` x `box_h` slot so every
-- tile in a row has the same shape. Covers close to the slot's shape (within
-- `tolerance`, default 0.15) are scaled to fill it and the overflow is
-- cropped evenly from both sides; anything further off (square covers, wide
-- comics pages) is scaled to fit inside instead, so nothing important is cut.
-- @treturn table `{ mode = "fill"|"fit", w, h, crop_x, crop_y }`: the scaled
-- size, and where the slot starts inside it when filling.
function Core.coverPlacement(src_w, src_h, box_w, box_h, tolerance)
    tolerance = tolerance or 0.15
    src_w, src_h = math.max(1, src_w), math.max(1, src_h)
    box_w, box_h = math.max(1, box_w), math.max(1, box_h)
    local src_ratio, box_ratio = src_w / src_h, box_w / box_h
    if math.abs(src_ratio - box_ratio) / box_ratio <= tolerance then
        local scale = math.max(box_w / src_w, box_h / src_h)
        local w = math.max(box_w, math.floor(src_w * scale + 0.5))
        local h = math.max(box_h, math.floor(src_h * scale + 0.5))
        return { mode = "fill", w = w, h = h,
            crop_x = math.floor((w - box_w) / 2), crop_y = math.floor((h - box_h) / 2) }
    end
    local scale = math.min(box_w / src_w, box_h / src_h)
    return { mode = "fit", w = math.max(1, math.floor(src_w * scale + 0.5)),
        h = math.max(1, math.floor(src_h * scale + 0.5)), crop_x = 0, crop_y = 0 }
end

--- Width of the filled part of a progress bar `w` wide for `fraction`
-- (clamped to 0..1). A started book always shows at least `min_w` pixels so
-- 1 % does not look like unread.
function Core.barFill(w, fraction, min_w)
    fraction = tonumber(fraction) or 0
    if fraction <= 0 then return 0 end
    if fraction >= 1 then return w end
    return math.min(w, math.max(min_w or 0, math.floor(w * fraction + 0.5)))
end

--- "Rounded keyboard in search": on unless turned off.
function Core.roundedKeyboard(settings)
    return not (settings and settings.rounded_keyboard == false)
end

--- Clock beside the search bar: on unless turned off.
function Core.showClock(settings)
    return not (settings and settings.show_clock == false)
end

--- Battery percentage beside the search bar: on unless turned off.
function Core.showBattery(settings)
    return not (settings and settings.show_battery == false)
end

--- "Use KOReader's keyboard": off unless turned on, so the Library keyboard stays.
function Core.useKoreaderKeyboard(settings)
    return settings ~= nil and settings.use_koreader_keyboard == true
end

--- "12:34  ·  87%", or just the part that is turned on. Nil when both are missing.
function Core.statusLabel(clock_text, battery_text)
    local clock = (type(clock_text) == "string" and clock_text ~= "") and clock_text or nil
    local battery = (type(battery_text) == "string" and battery_text ~= "") and battery_text or nil
    if clock and battery then return clock .. "  ·  " .. battery end
    return clock or battery
end

--- "87%" for a capacity in 0..100. Anything else (no battery, a bad reading) is nil.
function Core.batteryLabel(capacity)
    if type(capacity) ~= "number" or capacity ~= capacity then return nil end
    local n = math.floor(capacity + 0.5)
    if n < 0 or n > 100 then return nil end
    return string.format("%d%%", n)
end

--- Seconds until the next minute, so the clock can refresh once then and not before.
-- At least 1, at most 60.
function Core.nextMinuteDelay(now)
    now = math.floor(tonumber(now) or 0)
    local delay = 60 - (now % 60)
    if delay < 1 then return 60 end
    return delay
end

--- Footer buttons: the menu, and Resume (drawn, but not tappable, when there is no book).
function Core.footerChrome(has_book)
    return {
        { id = "menu", icon = "appbar.menu", enabled = true },
        { id = "resume", icon = "book.opened", enabled = has_book and true or false },
    }
end


----------------------------------------------------------------------------
-- Per-view memory: layout, sort and filter for each shelf
----------------------------------------------------------------------------
-- A "view" is a place in the Library: the Books tab, the Collections /
-- Authors / Series lists, or one collection, author or series. The Books tab
-- holds the defaults (settings.view, settings.sort, as before); every other
-- place keeps its own layout, sort and filter once you change them there,
-- in settings.view_memory[key] = { view =, sort =, filter = }.

Core.MEMORY_FIELDS = { "view", "sort", "filter" }
Core.DEFAULT_PREFS = { view = "grid", sort = "recent", filter = "all" }
Core.VIEW_MEMORY_MAX = 300 -- oldest entries are dropped past this

--- "Remember layout for each shelf": on unless turned off.
function Core.rememberViews(settings)
    return not (settings and settings.remember_views == false)
end

--- The memory key for a place: "books", "tab:authors", "series:Oz", ...
function Core.viewKey(tab, group)
    if group then return (group.kind or tab or "group") .. ":" .. tostring(group.name) end
    if not tab or tab == "books" then return "books" end
    return "tab:" .. tab
end

local function validPref(field, v)
    if v == nil then return nil end
    if field == "view" then return Core.viewMode(v) == v and v or nil end
    if field == "sort" then
        for _, m in ipairs(Core.SORTS) do if m == v then return v end end
        return nil
    end
    if field == "filter" then
        for _, f in ipairs(Core.FILTERS) do if f == v then return v end end
        return nil
    end
end

--- The defaults every place starts from (what the Books tab shows).
function Core.defaultPrefs(settings)
    local mem = settings.view_memory and settings.view_memory.books or {}
    return {
        view = validPref("view", settings.view) or Core.DEFAULT_PREFS.view,
        sort = validPref("sort", settings.sort) or Core.DEFAULT_PREFS.sort,
        filter = validPref("filter", mem.filter) or Core.DEFAULT_PREFS.filter,
    }
end

-- Places that start with another layout than the Books tab's (until changed
-- there): Authors is a text list, A-Z.
Core.PLACE_DEFAULTS = { ["tab:authors"] = { view = "list" } }

--- Layout, sort and filter for `key`, and whether anything is remembered
-- for it (other than the defaults). With the memory turned off this is nil:
-- the Library keeps whatever is showing, as before.
function Core.viewPrefs(settings, key)
    if not Core.rememberViews(settings) then return nil, false end
    local prefs = Core.defaultPrefs(settings)
    if key == "books" then
        local d = Core.DEFAULT_PREFS
        return prefs, prefs.view ~= d.view or prefs.sort ~= d.sort or prefs.filter ~= d.filter
    end
    for f, v in pairs(Core.PLACE_DEFAULTS[key] or {}) do prefs[f] = v end
    local entry = settings.view_memory and settings.view_memory[key]
    local remembered = false
    if type(entry) == "table" then
        for _, f in ipairs(Core.MEMORY_FIELDS) do
            local v = validPref(f, entry[f])
            if v then prefs[f] = v; remembered = true end
        end
    end
    return prefs, remembered
end

--- Remember `field` = `value` for `key`. The Books tab writes the defaults.
-- Returns true when something changed (the caller saves the settings).
function Core.rememberViewPref(settings, key, field, value, now)
    value = validPref(field, value)
    if not value then return false end
    if key == "books" and field ~= "filter" then
        if settings[field] == value then return false end
        settings[field] = value
        return true
    end
    if not Core.rememberViews(settings) then return false end
    settings.view_memory = settings.view_memory or {}
    local entry = settings.view_memory[key]
    if type(entry) ~= "table" then entry = {}; settings.view_memory[key] = entry end
    if entry[field] == value then return false end
    entry[field] = value
    entry.t = now or os.time()
    Core.pruneViewMemory(settings.view_memory, Core.VIEW_MEMORY_MAX)
    return true
end

--- Drop the oldest entries past `max` (the Books tab's entry is kept).
function Core.pruneViewMemory(memory, max)
    local keys = {}
    for k, e in pairs(memory) do
        if k ~= "books" then keys[#keys + 1] = { k = k, t = type(e) == "table" and e.t or 0 } end
    end
    if #keys <= max then return 0 end
    table.sort(keys, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.k < b.k
    end)
    local dropped = 0
    for i = max + 1, #keys do memory[keys[i].k] = nil; dropped = dropped + 1 end
    return dropped
end

--- Forget what `key` remembers. For the Books tab this puts the defaults
-- back to grid, Recent, All.
function Core.resetViewPrefs(settings, key)
    if key == "books" then
        settings.view, settings.sort = Core.DEFAULT_PREFS.view, Core.DEFAULT_PREFS.sort
        if settings.view_memory then settings.view_memory.books = nil end
        return
    end
    if settings.view_memory then settings.view_memory[key] = nil end
end

--- Forget every place (the Books tab's defaults are kept).
function Core.resetAllViewPrefs(settings)
    local books = settings.view_memory and settings.view_memory.books
    settings.view_memory = books and { books = books } or {}
end

--- Number of places with their own settings.
function Core.countViewMemory(settings)
    local n = 0
    for k in pairs(settings.view_memory or {}) do if k ~= "books" then n = n + 1 end end
    return n
end


----------------------------------------------------------------------------
-- Controls panel (librarycontrols.lua): the pure parts — where it opens,
-- which toggles it shows, slider maths and the layout.
----------------------------------------------------------------------------

--- The corner a downward swipe must start in: the top-right eighth of the
-- width and of the height (KOReader's own DTAP_ZONE_TOP_RIGHT size).
function Core.inControlsCorner(x, y, w, h)
    return x >= w * 7 / 8 and y <= h / 8
end

-- Row 1 is the screen (Light, Night, Refresh), row 2 the device (Wi-Fi, Rotate, Cover sleep).
Core.CONTROL_TOGGLES = { "light", "night", "refresh", "wifi", "rotate", "cover_sleep" }

--- The toggles this device can use, in panel order. `caps[id]` is true when
-- the device supports it (light: has a front light; refresh: e-ink screen).
function Core.controlsToggles(caps)
    local out = {}
    for _, id in ipairs(Core.CONTROL_TOGGLES) do
        if caps and caps[id] then out[#out + 1] = id end
    end
    return out
end

--- The value under `x` on a slider track, rounded to a whole step.
function Core.sliderValue(x, track_x, track_w, min, max)
    if track_w <= 0 or max <= min then return min end
    local f = (x - track_x) / track_w
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return math.floor(min + f * (max - min) + 0.5)
end

--- How far along the track `v` is, 0..1.
function Core.sliderFraction(v, min, max)
    if max <= min then return 0 end
    local f = (v - min) / (max - min)
    if f < 0 then return 0 elseif f > 1 then return 1 end
    return f
end

--- Where everything goes, for a screen of w x h with `n_sliders` sliders and
-- `n_toggles` round toggles (3 per row). Sizes follow the 1264 px wide
-- Colorsoft and scale with the short side. All rects are { x, y, w, h };
-- circles are { cx, cy, r }.
function Core.controlsLayout(w, h, n_sliders, n_toggles)
    local u = math.min(w, h) / 1264
    local function px(v) return math.floor(v * u + 0.5) end
    local L = {}
    local margin, pad, r = px(20), px(52), px(40)
    local pw = math.min(w - 2 * margin, px(920))
    local x = w - margin - pw
    local left, right = x + pad, x + pw - pad
    L.u, L.radius, L.left, L.right = u, r, left, right
    L.header_y = px(36)
    local y = L.header_y + px(96)
    L.sliders = {}
    for i = 1, n_sliders do
        local s = { label_y = y }
        local cy = y + px(132)
        local br = px(38)
        s.minus = { cx = left + br, cy = cy, r = br }
        s.plus = { cx = right - br, cy = cy, r = br }
        local tx = left + 2 * br + px(34)
        s.track = { x = tx, y = cy - px(11), w = (right - left) - 4 * br - px(68), h = px(22) }
        s.knob_r = px(34)
        -- the whole row takes taps and drags, not just the thin track
        s.hit = { x = left, y = y, w = right - left, h = cy + px(50) - y }
        L.sliders[i] = s
        y = cy + px(74)
    end
    if n_sliders > 0 then
        L.divider_y = y
        y = y + px(44)
    end
    L.toggles = {}
    local cw = (right - left) / 3
    local cr = px(74)
    local row_h = px(290)
    local rows = math.ceil(n_toggles / 3)
    for i = 1, n_toggles do
        local row, col = math.floor((i - 1) / 3), (i - 1) % 3
        local in_row = math.min(3, n_toggles - row * 3)
        -- centre a short last row
        local offset = (3 - in_row) * cw / 2
        L.toggles[i] = {
            cx = math.floor(left + offset + cw * col + cw / 2),
            cy = y + cr + row * row_h,
            r = cr,
            label_y = y + cr + row * row_h + cr + px(18),
            sub_y = y + cr + row * row_h + cr + px(66),
        }
    end
    y = y + rows * row_h
    L.handle = { x = x + math.floor(pw / 2) - px(60), y = y + px(4), w = px(120), h = px(12) }
    y = y + px(40)
    -- the panel hangs from the top edge: its top corners are off screen
    L.panel = { x = x, y = -r, w = pw, h = y + r }
    L.bottom = y
    return L
end

--- Which part of the layout a point hits: "slider", i / "minus", i /
-- "plus", i / "toggle", i / "panel" / nil (outside: close).
function Core.controlsHit(L, x, y)
    local function inCircle(c) return (x - c.cx) ^ 2 + (y - c.cy) ^ 2 <= (c.r * 1.25) ^ 2 end
    local function inRect(r) return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end
    for i, s in ipairs(L.sliders) do
        if inCircle(s.minus) then return "minus", i end
        if inCircle(s.plus) then return "plus", i end
        if inRect(s.hit) then return "slider", i end
    end
    for i, t in ipairs(L.toggles) do
        if inCircle(t) or (math.abs(x - t.cx) <= t.r * 1.3 and y >= t.cy and y <= t.sub_y + t.r * 0.5) then
            return "toggle", i
        end
    end
    local p = L.panel
    if x >= p.x and x < p.x + p.w and y < p.y + p.h then return "panel" end
    return nil
end

----------------------------------------------------------------------------
-- Book details card (read-only; description is loaded when the card opens)
----------------------------------------------------------------------------

--- Move `id` to sit immediately after `after` (appended when `after` is
-- missing). Idempotent.
function Core.placeAfter(list, id, after)
    for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
    end
    local at = #list + 1
    for i, v in ipairs(list) do
        if v == after then at = i + 1; break end
    end
    table.insert(list, at, id)
    return list
end

--- Long-press on a library tile. A book opens the details card; a shelf
-- (collection, author, series, genre) does not. A normal tap is separate.
function Core.longPressAction(tile)
    if type(tile) ~= "table" then return nil end
    if tile.group and not tile.book then return nil end
    local book = tile.book
    if type(book) ~= "table" or type(book.path) ~= "string" or book.path == "" then
        return nil
    end
    return "details"
end

--- "open" when the book is unread, "continue" once it has been started
-- (reading, on hold, or finished).
function Core.detailsOpenAction(book)
    if type(book) == "table" and book.status and book.status ~= "new" then
        return "continue"
    end
    return "open"
end

--- "mark_unread" when the book is finished, otherwise "mark_finished".
function Core.detailsStatusAction(book)
    if type(book) == "table" and book.status == "complete" then
        return "mark_unread"
    end
    return "mark_finished"
end

--- The primary button only dismisses the card when this book is already
-- open in the reader. Otherwise it opens the book.
function Core.detailsPrimaryDismisses(already_open)
    return already_open and true or false
end

--- Author names to show, each one tappable on its own.
function Core.authorNames(book)
    if type(book) ~= "table" then return {} end
    local authors = book.authors
    if type(authors) == "string" then return Core.splitAuthors(authors) end
    if type(authors) ~= "table" then return {} end
    local out = {}
    for _, name in ipairs(authors) do
        if type(name) == "string" and name ~= "" then out[#out + 1] = name end
    end
    return out
end

--- Which of `names` get a tappable link on the details card: a name only
-- links when its shelf in `groups` holds 2+ books, so a tap never opens a
-- list of just this book. Names are found the way a tap finds them
-- (`Core.shelfMatch`). With no groups known yet (index not built), every
-- name stays tappable.
function Core.shelfLinks(names, groups, lower_fn)
    local out = {}
    if type(names) ~= "table" then return out end
    for i, name in ipairs(names) do
        if type(groups) ~= "table" then
            out[i] = true
        else
            local g = Core.shelfMatch(name, groups, lower_fn)
            out[i] = g ~= nil and type(g.books) == "table" and #g.books >= 2
        end
    end
    return out
end

--- Author or series shelves the way the Authors / Series tabs build them.
-- Nil when no books are known yet.
function Core.tabShelves(books, grouping, collate)
    if type(books) ~= "table" or #books == 0 then return nil end
    local groups = {}
    for _, g in ipairs(Core.group(books, grouping, collate)) do
        if g.key ~= Core.UNKNOWN then groups[#groups + 1] = { name = g.key, books = g.books } end
    end
    return groups
end

--- Author links on the details card: counted like the Authors tab.
function Core.authorLinks(names, books, collate, lower_fn)
    return Core.shelfLinks(names, Core.tabShelves(books, "author", collate), lower_fn)
end

--- Is the series line a link? Counted like the Series tab.
function Core.seriesLink(series, books, collate, lower_fn)
    if type(series) ~= "string" or series == "" then return false end
    return Core.shelfLinks({ series }, Core.tabShelves(books, "series", collate), lower_fn)[1]
end

--- Genre chips: counted like the Genres view (same spelling merge).
function Core.genreLinks(names, books, collate, lower_fn)
    if type(books) ~= "table" or #books == 0 then return Core.shelfLinks(names, nil) end
    return Core.shelfLinks(names, Core.genreGroups(books, collate, lower_fn), lower_fn)
end

--- "Sherlock Holmes #5", or just the series name. Nil when there is none.
function Core.seriesLine(book)
    if type(book) ~= "table" or type(book.series) ~= "string" or book.series == "" then
        return nil
    end
    local n = Core.seriesNumber(book.series_index)
    if n then return book.series .. " #" .. n end
    return book.series
end

--- Whole percent for the card: 0.37 -> 37. A finished book with no percent
-- reads as 100. Unread reads as 0.
function Core.progressPercent(book)
    if type(book) ~= "table" then return 0 end
    local p = tonumber(book.percent)
    if book.status == "complete" and (not p or p <= 0) then return 100 end
    if not p or p < 0 then return 0 end
    if p > 1 then p = 1 end
    return math.floor(p * 100 + 0.5)
end

--- A duration already computed elsewhere, as "3h 39m" / "2h" / "12m".
-- Nil when there is nothing to show (missing, zero, or under half a minute).
function Core.timeLeftText(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds < 30 then return nil end
    local minutes = math.floor(seconds / 60)
    if minutes < 1 then minutes = 1 end
    local hours = math.floor(minutes / 60)
    local rem = minutes % 60
    if hours > 0 and rem > 0 then return string.format("%dh %dm", hours, rem) end
    if hours > 0 then return string.format("%dh", hours) end
    return string.format("%dm", minutes)
end

--- Seconds of time left only when some earlier step already stored them
-- on the book or in its sidecar (`time_left`, or `stats.time_left`).
-- This does not estimate a duration from page statistics.
function Core.knownTimeLeft(book, sidecar)
    local function positive(v)
        v = tonumber(v)
        if v and v > 0 then return v end
    end
    if type(book) == "table" then
        local t = positive(book.time_left)
        if t then return t end
    end
    if type(sidecar) == "table" then
        local t = positive(sidecar.time_left)
        if t then return t end
        local stats = sidecar.stats
        if type(stats) == "table" then
            t = positive(stats.time_left)
            if t then return t end
        end
    end
    return nil
end

--- Percent, and the time-left text when `book.time_left` is already set.
function Core.progressParts(book)
    local left = nil
    if type(book) == "table" then left = Core.timeLeftText(book.time_left) end
    return Core.progressPercent(book), left
end

--- "37%" or "37% · 3h 39m left". `pct` is a whole number, `left` a duration.
function Core.progressLine(pct, left)
    local text = string.format("%d%%", tonumber(pct) or 0)
    if type(left) == "string" and left ~= "" then
        return text .. " \u{00B7} " .. left .. " left"
    end
    return text
end

local HTML_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'", nbsp = " ",
    mdash = "\u{2014}", ndash = "\u{2013}", hellip = "\u{2026}",
    rsquo = "\u{2019}", lsquo = "\u{2018}", rdquo = "\u{201D}", ldquo = "\u{201C}",
}

local function utf8char(cp)
    if not cp or cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return ""
    end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
    end
    if cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + (math.floor(cp / 64) % 64),
            0x80 + (cp % 64))
    end
    return string.char(
        0xF0 + math.floor(cp / 262144),
        0x80 + (math.floor(cp / 4096) % 64),
        0x80 + (math.floor(cp / 64) % 64),
        0x80 + (cp % 64))
end

--- Cut a `<tag ...> ... </tag>` block out, case-insensitively, newlines included.
local function stripBlock(s, tag)
    local lower = s:lower()
    local open, close = "<" .. tag, "</" .. tag
    local out, i = {}, 1
    while true do
        local a, b = lower:find(open, i, true)
        if not a then
            out[#out + 1] = s:sub(i)
            break
        end
        -- only a real tag, not "<tagline"
        local after = lower:sub(b + 1, b + 1)
        if after ~= "" and after ~= ">" and after ~= " " and after ~= "/" and after ~= "\n" and after ~= "\t" then
            out[#out + 1] = s:sub(i, b)
            i = b + 1
        else
            out[#out + 1] = s:sub(i, a - 1)
            local c = lower:find(close, b + 1, true)
            if not c then break end
            local gt = s:find(">", c + #close - 1, true)
            i = gt and (gt + 1) or (c + #close)
        end
    end
    return table.concat(out)
end

--- Plain text for a blurb. HTML tags are removed, common entities decoded,
-- and paragraphs kept as blank lines. Nil when nothing is left.
function Core.plainDescription(raw)
    if type(raw) ~= "string" then return nil end
    local s = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    local function dropComments(src)
        local out, i = {}, 1
        while true do
            local a = src:find("<!%-%-", i)
            if not a then
                out[#out + 1] = src:sub(i)
                break
            end
            out[#out + 1] = src:sub(i, a - 1)
            local b = src:find("%-%->", a + 4)
            if not b then break end
            i = b + 3
        end
        return table.concat(out)
    end
    s = dropComments(s)
    s = stripBlock(s, "script")
    s = stripBlock(s, "style")
    s = s:gsub("<[Bb][Rr][^>]*>", "\n")
    s = s:gsub("</[Pp]%s*>", "\n\n")
    s = s:gsub("</[Dd][Ii][Vv]%s*>", "\n")
    s = s:gsub("</[Hh][1-6]%s*>", "\n\n")
    s = s:gsub("</[Ll][Ii]%s*>", "\n")
    s = s:gsub("</[Tt][Rr]%s*>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&#[Xx](%x+);", function(hex)
        return utf8char(tonumber(hex, 16))
    end)
    s = s:gsub("&#(%d+);", function(n)
        return utf8char(tonumber(n))
    end)
    s = s:gsub("&(%a+);", function(name)
        return HTML_ENTITIES[name] or HTML_ENTITIES[name:lower()] or ("&" .. name .. ";")
    end)
    local lines, blank = {}, 0
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do
        line = trim(line:gsub("%s+", " "))
        lines[#lines + 1] = line
    end
    for _, line in ipairs(lines) do
        if line == "" then
            blank = blank + 1
            if blank == 1 and #out > 0 then out[#out + 1] = "" end
        else
            blank = 0
            out[#out + 1] = line
        end
    end
    while out[#out] == "" do out[#out] = nil end
    if #out == 0 then return nil end
    return table.concat(out, "\n")
end

--- First non-empty plain description in `list` (already in source order).
function Core.firstDescription(list)
    if type(list) ~= "table" then return nil end
    for i = 1, #list do
        local plain = Core.plainDescription(list[i])
        if plain then return plain end
    end
    return nil
end

--- Calibre / doc-settings text first; the book file's own text only fills
-- a gap. Neither is stored on the library index.
function Core.descriptionFrom(candidates, file_text)
    return Core.firstDescription(candidates) or Core.firstDescription({ file_text })
end

--- `{ [absolute path] = comments }`. Comments stay out of `calibreIndex`
-- so the grid's cache never carries blurbs.
function Core.calibreComments(entries, base_dir)
    local map = {}
    base_dir = (base_dir or ""):gsub("/+$", "")
    if type(entries) ~= "table" then return map end
    for _, e in ipairs(entries) do
        local lpath = type(e) == "table" and plain(e.lpath)
        if type(lpath) == "string" and lpath ~= "" then
            local path = lpath:sub(1, 1) == "/" and lpath or (base_dir .. "/" .. lpath)
            local text = plain(e.comments)
            if type(text) ~= "string" or text == "" then text = plain(e.description) end
            if type(text) == "string" and text ~= "" then map[path] = text end
        end
    end
    return map
end

--- Collection display names that contain `path`.
function Core.collectionNames(path, groups)
    local names = {}
    if type(path) ~= "string" then return names end
    for _, g in ipairs(groups or {}) do
        if type(g) == "table" and type(g.name) == "string" and not g.unsorted then
            for _, b in ipairs(g.books or {}) do
                local p = type(b) == "string" and b or (type(b) == "table" and b.path)
                if p == path then
                    names[#names + 1] = g.name
                    break
                end
            end
        end
    end
    return names
end

--- The shelf whose name matches `name` (case-insensitive). Unsorted is never
-- a match. `lower` defaults to string.lower.
function Core.shelfMatch(name, groups, lower_fn)
    lower_fn = lower_fn or string.lower
    if type(name) ~= "string" or name == "" then return nil end
    local key = lower_fn(name)
    for _, g in ipairs(groups or {}) do
        if type(g) == "table" and not g.unsorted and type(g.name) == "string" and lower_fn(g.name) == key then
            return g
        end
    end
    return nil
end

--- Pack item widths into rows. A single item wider than `max_w` stays on
-- its own row. Returns a list of index lists.
function Core.packRows(widths, max_w, gap)
    local rows, row, used = {}, {}, 0
    gap = gap or 0
    max_w = max_w or 0
    for i, w in ipairs(widths or {}) do
        local need = w + (#row > 0 and gap or 0)
        if #row > 0 and used + need > max_w then
            rows[#rows + 1] = row
            row, used = { i }, w
        else
            row[#row + 1] = i
            used = used + need
        end
    end
    if #row > 0 then rows[#rows + 1] = row end
    return rows
end

--- Two columns when a cover and a full description both fit. Narrow
-- screens, and landscape screens too short for that cover, use one column.
-- Sizes are the content box inside the card's margin, padding and border.
function Core.detailsLayout(w, h)
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    local margin = math.max(8, math.floor(math.min(w, h) * 0.015))
    local pad = math.max(8, margin)
    local gap = math.max(8, math.floor(margin * 0.8))
    local border = 2
    local inner_w = w - 2 * margin - 2 * pad - 2 * border
    local inner_h = h - 2 * margin - 2 * pad - 2 * border
    if inner_w < 1 then inner_w = 1 end
    if inner_h < 1 then inner_h = 1 end
    local button_h = math.min(64, math.max(44, math.floor(h * 0.055)))
    local body_h = inner_h - button_h - gap
    if body_h < 1 then body_h = 1 end

    local min_cover_w, min_text_w, min_cover_h = 160, 300, 200
    local cover_w = math.floor(inner_w * 0.34)
    local text_w = inner_w - cover_w - gap
    local cover_h = math.floor(cover_w * 3 / 2)
    local max_cover_h = math.floor(body_h * 0.72)
    if max_cover_h < 1 then max_cover_h = 1 end
    if cover_h > max_cover_h then
        cover_h = max_cover_h
        cover_w = math.floor(cover_h * 2 / 3)
        text_w = inner_w - cover_w - gap
    end
    local columns = 1
    if inner_w >= 880 and cover_w >= min_cover_w and text_w >= min_text_w
            and cover_h >= min_cover_h and body_h >= cover_h + button_h then
        columns = 2
    end
    if columns == 1 then
        cover_h = math.max(1, math.floor(body_h * 0.34))
        cover_w = math.floor(cover_h * 2 / 3)
        local max_w = math.max(1, math.floor(inner_w * 0.46))
        if cover_w > max_w then
            cover_w = max_w
            cover_h = math.floor(cover_w * 3 / 2)
        end
        if cover_w < 1 then cover_w = 1 end
        if cover_w > inner_w then cover_w = inner_w end
        text_w = inner_w
    end
    return {
        columns = columns,
        margin = margin,
        pad = pad,
        gap = gap,
        border = border,
        button_h = button_h,
        cover_w = cover_w,
        cover_h = cover_h,
        text_w = text_w,
        body_h = body_h,
        inner_w = inner_w,
        inner_h = inner_h,
    }
end

--- Which way a tap or swipe turns the description, or nil when it does not.
-- North / the right half go forward; south / the left half go back.
-- `area` is `{ x, y, w, h }` in screen coordinates.
function Core.descriptionPageTurn(gesture, area)
    if type(gesture) ~= "table" or type(area) ~= "table" then return nil end
    local ax, ay = area.x or 0, area.y or 0
    local aw, ah = area.w or 0, area.h or 0
    local x, y = gesture.x, gesture.y
    if x == nil or y == nil then return nil end
    if x < ax or y < ay or x >= ax + aw or y >= ay + ah then return nil end
    if gesture.kind == "swipe" then
        if gesture.direction == "north" then return 1 end
        if gesture.direction == "south" then return -1 end
        return nil
    end
    if gesture.kind == "tap" then
        if x >= ax + aw / 2 then return 1 end
        return -1
    end
    return nil
end

--- Clamp a page turn. One page stays put. `dir` is 1 or -1.
function Core.turnPage(page, pages, dir)
    page = tonumber(page) or 1
    pages = tonumber(pages) or 1
    if pages < 1 then pages = 1 end
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    dir = tonumber(dir) or 0
    if pages <= 1 or dir == 0 then return page end
    local n = page + dir
    if n < 1 then return 1 end
    if n > pages then return pages end
    return n
end

return Core
