--[[--
Book index for the Library plugin.

Builds the list of books under the library folder and keeps it cached on disk
so later starts only touch what changed.

Metadata comes from, in order:

1. `metadata.calibre` (written by calibre / the Calibre plugin) when present;
2. the cover browser's BookInfoManager database (Project: Title or coverbrowser);
3. the book's sidecar (`doc_props` saved by KOReader once the book was opened);
4. the file name.

The publication year is Calibre's pubdate when that is a real date, then a
date on the metadata above, then (EPUB only) `dc:date` in the OPF. It is
cached with the book. `false` means the file was checked and has no year,
so the next open does not read it again.

Reading state (status, percent read, page count and the Library's own
chapter marks) comes from the sidecar and is only re-read when the
sidecar's mtime changed. A book KOReader calls "reading" but that is still
before the start of its text is kept as "new" (see Core.readingStage). The last-opened time comes from
KOReader's reading history. A book with no sidecar and no history entry
is never opened. Time left is worked out once from that same sidecar
(or one cached stats lookup) and stored on the book; tiles only read it.

Cache key per book: path + size + mtime (+ the calibre file's mtime).

Each book's search text (Core.buildSearchKey) is worked out here: the
lower-cased key for the plain search, plus the accent-free words
"Typo-tolerant search" compares against, so typing never re-normalises a book.

Once built, a refresh (every time the Library opens) uses the books already
in memory as its cache: no disk-cache read, and unchanged books keep their
search text.

The same file is listed once. A symlink, a second mount (`/mnt/us` and
`/mnt/base-us`) and a case-only difference on those volumes are one book,
and the reading state is taken from whichever path has the sidecar. With
"Merge copies of the same book" (on by default), several formats or folders
of one work (same title and authors, or the same Calibre UUID or ISBN) are
one tile. The other copies stay on the book for the details card.
--]]

local Core = require("librarycore")

local Index = {}
Index.__index = Index

--- @param opts table:
--   root, show_hidden, max_depth, cache_file,
--   fs (lfs), is_book(path), lower(str),
--   bim (BookInfoManager or nil), docsettings (DocSettings), history (ReadHistory),
--   calibre_load(path) -> array or nil, extra_calibre_dirs, clock() -> seconds
function Index.new(opts)
    local self = setmetatable({}, Index)
    self.opts = opts
    self.books = {}
    self.by_path = {}
    self.stats = {}
    return self
end

function Index:clock()
    return self.opts.clock and self.opts.clock() or os.clock()
end

----------------------------------------------------------------------------
-- Disk cache
----------------------------------------------------------------------------

function Index:readCache()
    local f = self.opts.cache_file and io.open(self.opts.cache_file, "rb")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    local data = Core.deserialize(src)
    if not data or data.version ~= Core.CACHE_VERSION or data.root ~= self.opts.root then
        return nil
    end
    return data
end

function Index:writeCache()
    if not self.opts.cache_file then return end
    local data = {
        version = Core.CACHE_VERSION,
        root = self.opts.root,
        calibre = self.calibre_files,
        entries = Core.toCacheEntries(self.files or self.books),
    }
    local tmp = self.opts.cache_file .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(Core.serialize(data))
    f:close()
    os.rename(tmp, self.opts.cache_file)
end

----------------------------------------------------------------------------
-- Calibre
----------------------------------------------------------------------------

--- Find metadata.calibre files that cover the library root.
-- Returns { {path=, dir=, mtime=} } and a stamp string that changes when any of them does.
function Index:findCalibreFiles()
    local fs = self.opts.fs
    local files, stamp = {}, {}
    for _, dir in ipairs(Core.calibreCandidateDirs(self.opts.root, self.opts.extra_calibre_dirs)) do
        for _, name in ipairs({ "metadata.calibre", ".metadata.calibre" }) do
            local path = dir .. "/" .. name
            local attr = fs.attributes(path)
            if attr and attr.mode == "file" and (attr.size or 0) > 0 then
                table.insert(files, { path = path, dir = dir, mtime = attr.modification, size = attr.size })
                table.insert(stamp, path .. "@" .. tostring(attr.modification) .. ":" .. tostring(attr.size))
                break
            end
        end
    end
    return files, table.concat(stamp, "|")
end

function Index:loadCalibre(files)
    local map, by_key = {}, {}
    if not self.opts.calibre_load then
        self.calibre_by_key = by_key
        return map
    end
    for _, f in ipairs(files) do
        local ok, entries = pcall(self.opts.calibre_load, f.path)
        if ok and entries then
            for path, props in pairs(Core.calibreIndex(entries, f.dir)) do
                if not map[path] then map[path] = props end
                local key = Core.fileKey(path)
                if not by_key[key] then by_key[key] = props end
            end
        end
    end
    self.calibre_by_key = by_key
    return map
end

--- Calibre props for this file, including a path that only differs by the
-- Kindle mount (`/mnt/us` vs `/mnt/base-us`) or by case on that volume.
function Index:calibreFor(map, path)
    if type(path) ~= "string" then return nil end
    local props = map and map[path]
    if props then return props end
    local by_key = self.calibre_by_key
    if by_key then
        props = by_key[Core.fileKey(path)]
        if props then return props end
    end
    if map then
        for _, alt in ipairs(Core.pathAliases(path)) do
            if map[alt] then return map[alt] end
        end
    end
    return nil
end

----------------------------------------------------------------------------
-- Per-book metadata and reading state
----------------------------------------------------------------------------

--- Sidecar for `path`, or for another path that is the same file.
-- Returns the sidecar file and the document path it belongs to.
-- The scanned path is tried first. Aliases are tried only when that misses,
-- so a library with no sidecars does not stat the alias on a hit.
function Index:sidecarFile(path, alts)
    local ds = self.opts.docsettings
    if not (ds and ds.findSidecarFile) or type(path) ~= "string" then return nil end
    local tried = {}
    local function find(p)
        if type(p) ~= "string" or p == "" or tried[p] then return nil end
        tried[p] = true
        local ok, file = pcall(ds.findSidecarFile, ds, p)
        if ok and type(file) == "string" and file ~= "" then return file end
        return nil
    end
    local file = find(path)
    if file then return file, path end
    if type(alts) == "table" then
        for _, p in ipairs(alts) do
            file = find(p)
            if file then return file, p end
        end
    end
    for _, p in ipairs(Core.pathAliases(path)) do
        file = find(p)
        if file then return file, p end
    end
    return nil
end

function Index:readSidecar(sidecar)
    local ds = self.opts.docsettings
    if not (ds and sidecar) then return nil end
    local ok, settings = pcall(ds.openSettingsFile, sidecar)
    if not ok or not settings then return nil end
    return settings.data
end

--- Publication year when the cache does not have one yet.
-- Calibre, then KOReader's book info and the sidecar, then an EPUB's OPF.
-- `false` is stored once a file has been checked and has no year.
function Index:lookupYear(book, calibre_map, info, doc_props)
    local y = Core.yearFromProps(self:calibreFor(calibre_map, book.path))
    if y then return y end
    if info == nil and self.opts.bim and self.opts.bim.getBookInfo then
        local ok, got = pcall(self.opts.bim.getBookInfo, self.opts.bim, book.path, false)
        if ok and type(got) == "table" then info = got end
    end
    y = Core.yearFromProps(info)
    if y then return y end
    if doc_props == nil then
        local data = self:readSidecar(self:sidecarFile(book.path, book.alt_paths))
        if type(data) == "table" then doc_props = data.doc_props end
    end
    y = Core.yearFromProps(doc_props)
    if y then return y end
    if book.ext == "epub" then return Core.epubPublicationYear(book.path) end
    return nil
end

function Index:ensureYear(book, calibre_map)
    if Core.publicationYear(book.year) or book.year == false then return end
    local ok, y = pcall(self.lookupYear, self, book, calibre_map, nil, nil)
    book.year = (ok and y) or false
end

--- Fill metadata for a book whose cache entry is missing or stale.
function Index:fillMeta(book, calibre_map, calibre_stamp, sidecar_data)
    local cached_year = book.year
    local calibre = self:calibreFor(calibre_map, book.path)
    local info
    if self.opts.bim then
        local ok, i = pcall(self.opts.bim.getBookInfo, self.opts.bim, book.path, false)
        if ok and type(i) == "table" and (i.title or i.authors) then info = i end
    end
    local doc_props = sidecar_data and type(sidecar_data.doc_props) == "table" and sidecar_data.doc_props or nil
    local props, src = calibre, "calibre"
    if not props and info then props, src = info, "bim" end
    if not props and doc_props then props, src = doc_props, "sidecar" end
    if not props then src = "file" end
    Core.applyProps(book, props or {})
    -- Genres: Calibre's tags plus the book's own subjects (as KOReader read them).
    if calibre then
        local own = (info and info.keywords) or (doc_props and doc_props.keywords)
        book.keywords = Core.mergeKeywords(book.keywords, type(own) == "string" and own or nil)
    end
    book.src = src
    book.cal = calibre_stamp
    if Core.publicationYear(book.year) then return end
    -- Same file bytes as a year we already stored: do not open the EPUB again.
    if Core.publicationYear(cached_year) then book.year = cached_year; return end
    if cached_year == false then book.year = false; return end
    local y
    if src ~= "calibre" then y = Core.yearFromProps(calibre) end
    if not y and src ~= "bim" then y = Core.yearFromProps(info) end
    if not y and src ~= "sidecar" then y = Core.yearFromProps(doc_props) end
    if not y and book.ext == "epub" then y = Core.epubPublicationYear(book.path) end
    book.year = y or false
end

--- Refresh status/percent if the sidecar changed. Returns the sidecar data if it was read.
function Index:refreshState(book)
    local sidecar, via = self:sidecarFile(book.path, book.alt_paths)
    local mtime = sidecar and self.opts.fs.attributes(sidecar, "modification") or false
    -- Remember which path the sidecar was stored under, so opening the book
    -- uses the path KOReader already knows (often /mnt/us rather than /mnt/base-us).
    if type(via) == "string" and via ~= "" and via ~= book.path then
        book.open_path = via
    end
    if mtime == book.sc_mtime and book.status then return nil end
    book.sc_mtime = mtime
    local data = sidecar and self:readSidecar(sidecar)
    if not data then
        book.status, book.percent, book.pages = "new", nil, nil
        book.opened, book.doc_status, book.time_left = false, nil, nil
        Core.applyMarks(book, nil)
        return nil
    end
    local summary = type(data.summary) == "table" and data.summary or {}
    local raw = type(summary.status) == "string" and summary.status or nil
    if not raw and type(data.status) == "string" then raw = data.status end
    local norm = Core.normalizeDocStatus(raw)
    book.doc_status = norm or (type(raw) == "string" and raw or nil)
    book.opened = true
    book.status = norm or "reading"
    book.percent = tonumber(data.percent_finished)
    book.pages = tonumber(data.doc_pages)
    Core.applyMarks(book, data.library_marks)
    -- KOReader marks a book "reading" as soon as it opens: one you only
    -- opened (still on the cover, title page or contents) stays unread.
    -- A finished book (summary.status "complete") is never rewritten.
    if book.status == "reading" and Core.readingStage(book) == "unread" then
        book.status = "new"
    end
    if book.status == "reading" then
        book.time_left = self:timeLeftFor(book, data)
    else
        book.time_left = nil
    end
    return data
end

--- History means the book was opened, even when the sidecar is gone.
-- With neither, it stays never opened.
function Index:applyOpened(book)
    if book.last_opened and book.last_opened > 0 then
        book.opened = true
    elseif not book.sc_mtime then
        book.opened = false
    end
end

--- Seconds left, from the sidecar stats already in hand. A stats provider
-- is asked at most once per path, and only when those stats have no speed
-- and no stored duration. The answer is kept on `self.stats_cache`.
function Index:timeLeftFor(book, data)
    if type(book) ~= "table" or book.status ~= "reading" then return nil end
    local stats = type(data) == "table" and type(data.stats) == "table" and data.stats or nil
    local est = Core.estimateTimeLeft(book, stats)
    if est then return est end
    local stored = Core.knownTimeLeft(nil, data)
    if stored then return stored end
    return Core.estimateTimeLeft(book, self:lookupStats(book.path))
end

function Index:lookupStats(path)
    self.stats_cache = self.stats_cache or {}
    local hit = self.stats_cache[path]
    if hit ~= nil then return hit or nil end
    local stats
    local fn = self.opts.stats_for
    if type(fn) == "function" then
        local ok, s = pcall(fn, path)
        if ok and type(s) == "table" then stats = s end
    end
    self.stats_cache[path] = stats or false
    return stats
end

--- Exact path -> time, and file-key -> time. The key matches `/mnt/us` with
-- `/mnt/base-us` and ignores case on those volumes.
function Index:historyTimes()
    local exact, by_key = {}, {}
    local hist = self.opts.history
    if hist and type(hist.hist) == "table" then
        for _, item in ipairs(hist.hist) do
            if item.file and item.time then
                local t = item.time
                if not exact[item.file] or t > exact[item.file] then exact[item.file] = t end
                local key = Core.fileKey(item.file)
                if not by_key[key] or t > by_key[key] then by_key[key] = t end
            end
        end
    end
    return exact, by_key
end

--- Last-opened time for this file, and the history path when it differs
-- from the path we scanned (that is the path to open).
function Index:historyFor(book, exact, by_key)
    exact, by_key = exact or {}, by_key or {}
    local best_t, best_p = nil, nil
    local function consider(p)
        local t = exact[p]
        if t and (not best_t or t >= best_t) then best_t, best_p = t, p end
    end
    consider(book.path)
    if type(book.alt_paths) == "table" then
        for _, p in ipairs(book.alt_paths) do consider(p) end
    end
    for _, p in ipairs(Core.pathAliases(book.path)) do consider(p) end
    if not best_t and by_key then
        best_t = by_key[Core.fileKey(book.path)]
    end
    return best_t, best_p
end

----------------------------------------------------------------------------
-- Build
----------------------------------------------------------------------------

--- Scan the library, reusing the disk cache where possible.
-- @tparam bool force ignore the disk cache
function Index:build(force)
    local o = self.opts
    local t0 = self:clock()
    local scanned, truncated = Core.scan(o.root, o.fs, o.is_book, {
        max_depth = o.max_depth, show_hidden = o.show_hidden, limit = o.limit,
        skip_dirs = o.skip_dirs, skip_dir_names = o.skip_dir_names,
    })
    local t_scan = self:clock()

    -- Already built in this run: the books in memory are the cache, so a
    -- refresh (each time the Library opens) skips reading the disk cache.
    local cache
    if not force then
        if self.built and next(self.by_path) ~= nil then
            cache = { entries = self.by_path, memory = true }
        else
            cache = self:readCache()
        end
    end
    local calibre_files, calibre_stamp = self:findCalibreFiles()
    self.calibre_files = calibre_files

    local reused, stale = Core.reconcile(scanned, cache and cache.entries, calibre_stamp)
    local need_year = false
    for _, book in ipairs(reused) do
        if book.year == nil then need_year = true; break end
    end
    local calibre_map = {}
    if (#stale > 0 or need_year) and #calibre_files > 0 then
        calibre_map = self:loadCalibre(calibre_files)
    end
    local t_cal = self:clock()

    local sidecar_reads = 0
    for _, book in ipairs(reused) do
        if self:refreshState(book) then sidecar_reads = sidecar_reads + 1 end
    end
    for _, book in ipairs(stale) do
        local data = self:refreshState(book)
        if data then sidecar_reads = sidecar_reads + 1 end
        self:fillMeta(book, calibre_map, calibre_stamp, data)
    end
    local years_filled = 0
    if need_year then
        for _, book in ipairs(reused) do
            if book.year == nil then
                self:ensureYear(book, calibre_map)
                years_filled = years_filled + 1
            end
        end
    end

    local exact, by_key = self:historyTimes()
    for _, book in ipairs(scanned) do
        local opened, via = self:historyFor(book, exact, by_key)
        book.last_opened = opened
        if type(via) == "string" and via ~= "" and via ~= book.path then
            book.open_path = via
        end
        self:applyOpened(book)
        -- (reused from memory: same title, authors, series and file name)
        if not book.search_key then Core.buildSearchKey(book, o.lower) end
    end
    local t_meta = self:clock()

    -- Every distinct file, before copies of one work are folded into a tile.
    -- The disk cache is this list, so a second format is not re-read next time.
    self.files = scanned
    local books = scanned
    if o.merge_copies ~= false then
        books = Core.mergeCopies(scanned)
        for _, b in ipairs(books) do
            if b.copies then Core.buildSearchKey(b, o.lower) end
        end
    end
    self.books = books
    self.by_path = {}
    self.by_key = {}
    for _, b in ipairs(scanned) do
        self.by_path[b.path] = b
        local key = Core.fileKey(b.path)
        if not self.by_key[key] then self.by_key[key] = b end
        if type(b.alt_paths) == "table" then
            for _, p in ipairs(b.alt_paths) do
                self.by_path[p] = b
                local ak = Core.fileKey(p)
                if not self.by_key[ak] then self.by_key[ak] = b end
            end
        end
    end
    self.truncated = truncated
    self.built = true

    local cached_n = 0
    if cache then
        -- The in-memory map also keys alternate paths of the same file, so
        -- its size is not the file count. The disk cache is one entry per file.
        if cache.memory then cached_n = self._files_n or #scanned
        else cached_n = self:countEntries(cache.entries) end
    end
    self._files_n = #scanned
    local dirty = force or not cache or #stale > 0 or sidecar_reads > 0
        or cached_n ~= #scanned or years_filled > 0
    if dirty then self:writeCache() end
    local t_end = self:clock()

    self.stats = {
        books = #self.books,
        files = #scanned,
        cached = #reused,
        refreshed = #stale,
        sidecar_reads = sidecar_reads,
        calibre_files = #calibre_files,
        from_cache = cache ~= nil,
        from_memory = cache ~= nil and cache.memory == true,
        scan_s = t_scan - t0,
        calibre_s = t_cal - t_scan,
        meta_s = t_meta - t_cal,
        write_s = t_end - t_meta,
        total_s = t_end - t0,
    }
    return self.books
end

function Index:countEntries(entries)
    local n = 0
    for _ in pairs(entries or {}) do n = n + 1 end
    return n
end

--- Re-read one book's reading state (after closing it, or changing its status).
function Index:refreshBook(path)
    local book = self.by_path[path]
    if not book and self.by_key and type(path) == "string" then
        book = self.by_key[Core.fileKey(path)]
    end
    if book and book.merged_into then book = book.merged_into end
    if not book then return nil end
    book.sc_mtime = nil
    self:refreshState(book)
    local exact, by_key = self:historyTimes()
    local opened, via = self:historyFor(book, exact, by_key)
    book.last_opened = opened or book.last_opened
    if type(via) == "string" and via ~= "" and via ~= book.path then book.open_path = via end
    self:applyOpened(book)
    return book
end

--- A record for a file outside the indexed folder (e.g. in a collection).
function Index:recordFor(path)
    local book = self.by_path and self.by_path[path]
    if not book and self.by_key and type(path) == "string" then
        book = self.by_key[Core.fileKey(path)]
    end
    if book then
        -- A format that was folded into another tile: the collection shows that tile.
        if book.merged_into then return book.merged_into end
        return book
    end
    local attr = self.opts.fs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local dir, name = Core.splitPath(path)
    book = {
        path = path, name = name, dir = dir, folder = dir,
        ext = Core.extension(name), size = attr.size or 0, modification = attr.modification or 0,
    }
    local data = self:refreshState(book)
    self:fillMeta(book, {}, nil, data)
    local exact, by_key = self:historyTimes()
    book.last_opened = select(1, self:historyFor(book, exact, by_key))
    self:applyOpened(book)
    Core.buildSearchKey(book, self.opts.lower)
    return book
end

--- Raw description strings for one book, in the same order the index trusts
-- for other metadata: Calibre comments, then the sidecar's doc_props, then
-- BookInfoManager. Nothing is written onto the book or the disk cache.
function Index:descriptionCandidates(path)
    local list = {}
    local files = self.calibre_files
    if not files or #files == 0 then
        files = self:findCalibreFiles()
    end
    -- Prefer the full metadata read. KOReader's load_calibre omits comments,
    -- which is the blurb, and this function is only called when a card opens.
    local load = self.opts.calibre_load_full or self.opts.calibre_load
    if load then
        for _, f in ipairs(files or {}) do
            local ok, entries = pcall(load, f.path)
            if ok then
                local comment = Core.calibreComments(entries, f.dir)[path]
                if comment then
                    list[#list + 1] = comment
                    break
                end
            end
        end
    end
    local data = self:readSidecar(self:sidecarFile(path))
    local props = type(data) == "table" and data.doc_props
    if type(props) == "table" and type(props.description) == "string" then
        list[#list + 1] = props.description
    end
    local bim = self.opts.bim
    if bim and bim.getBookInfo then
        local ok, info = pcall(bim.getBookInfo, bim, path, false)
        if ok and type(info) == "table" and type(info.description) == "string" then
            list[#list + 1] = info.description
        end
    end
    return list
end

--- Seconds of time left already stored for this book. Does not estimate one.
function Index:knownTimeLeft(path, book)
    local t = Core.knownTimeLeft(book)
    if t then return t end
    return Core.knownTimeLeft(nil, self:readSidecar(self:sidecarFile(path)))
end

return Index
