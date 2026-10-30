--[[--
Book index for the Library plugin.

Builds the list of books under the library folder and keeps it cached on disk
so later starts only touch what changed.

Metadata comes from, in order:

1. `metadata.calibre` (written by calibre / the Calibre plugin) when present;
2. the cover browser's BookInfoManager database (Project: Title or coverbrowser);
3. the book's sidecar (`doc_props` saved by KOReader once the book was opened);
4. the file name.

Reading state (status, percent read) comes from the sidecar and is only
re-read when the sidecar's mtime changed. The last-opened time comes from
KOReader's reading history.

Cache key per book: path + size + mtime (+ the calibre file's mtime).

Each book's search text (Core.buildSearchKey) is worked out here, once per
build: the lower-cased key for the plain search, plus the accent-free words
"Typo-tolerant search" compares against, so typing never re-normalises a book.
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
        entries = Core.toCacheEntries(self.books),
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
    local map = {}
    if not self.opts.calibre_load then return map end
    for _, f in ipairs(files) do
        local ok, entries = pcall(self.opts.calibre_load, f.path)
        if ok and entries then
            for path, props in pairs(Core.calibreIndex(entries, f.dir)) do
                if not map[path] then map[path] = props end
            end
        end
    end
    return map
end

----------------------------------------------------------------------------
-- Per-book metadata and reading state
----------------------------------------------------------------------------

function Index:sidecarFile(path)
    local ds = self.opts.docsettings
    if not ds then return nil end
    local ok, file = pcall(ds.findSidecarFile, ds, path)
    return ok and file or nil
end

function Index:readSidecar(sidecar)
    local ds = self.opts.docsettings
    if not (ds and sidecar) then return nil end
    local ok, settings = pcall(ds.openSettingsFile, sidecar)
    if not ok or not settings then return nil end
    return settings.data
end

--- Fill metadata for a book whose cache entry is missing or stale.
function Index:fillMeta(book, calibre_map, calibre_stamp, sidecar_data)
    local calibre = calibre_map[book.path]
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
end

--- Refresh status/percent if the sidecar changed. Returns the sidecar data if it was read.
function Index:refreshState(book)
    local sidecar = self:sidecarFile(book.path)
    local mtime = sidecar and self.opts.fs.attributes(sidecar, "modification") or false
    if mtime == book.sc_mtime and book.status then return nil end
    book.sc_mtime = mtime
    if not sidecar then
        book.status, book.percent = "new", nil
        return nil
    end
    local data = self:readSidecar(sidecar)
    if not data then
        book.status, book.percent = "new", nil
        return nil
    end
    local summary = type(data.summary) == "table" and data.summary or {}
    book.status = Core.isKnownStatus(summary.status) and summary.status or "reading"
    book.percent = tonumber(data.percent_finished)
    return data
end

function Index:historyTimes()
    local times = {}
    local hist = self.opts.history
    if hist and type(hist.hist) == "table" then
        for _, item in ipairs(hist.hist) do
            if item.file and item.time then
                times[item.file] = math.max(times[item.file] or 0, item.time)
            end
        end
    end
    return times
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
        skip_dirs = o.skip_dirs,
    })
    local t_scan = self:clock()

    local cache = not force and self:readCache() or nil
    local calibre_files, calibre_stamp = self:findCalibreFiles()
    self.calibre_files = calibre_files

    local reused, stale = Core.reconcile(scanned, cache and cache.entries, calibre_stamp)
    local calibre_map = {}
    if #stale > 0 and #calibre_files > 0 then
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

    local times = self:historyTimes()
    for _, book in ipairs(scanned) do
        book.last_opened = times[book.path]
        Core.buildSearchKey(book, o.lower)
    end
    local t_meta = self:clock()

    self.books = scanned
    self.by_path = {}
    for _, b in ipairs(scanned) do self.by_path[b.path] = b end
    self.truncated = truncated

    local dirty = force or not cache or #stale > 0 or sidecar_reads > 0
        or self:countEntries(cache and cache.entries) ~= #scanned
    if dirty then self:writeCache() end
    local t_end = self:clock()

    self.stats = {
        books = #scanned,
        cached = #reused,
        refreshed = #stale,
        sidecar_reads = sidecar_reads,
        calibre_files = #calibre_files,
        from_cache = cache ~= nil,
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
    if not book then return nil end
    book.sc_mtime = nil
    self:refreshState(book)
    local times = self:historyTimes()
    book.last_opened = times[path] or book.last_opened
    return book
end

--- A record for a file outside the indexed folder (e.g. in a collection).
function Index:recordFor(path)
    local book = self.by_path[path]
    if book then return book end
    local attr = self.opts.fs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local dir, name = Core.splitPath(path)
    book = {
        path = path, name = name, dir = dir, folder = dir,
        ext = Core.extension(name), size = attr.size or 0, modification = attr.modification or 0,
    }
    local data = self:refreshState(book)
    self:fillMeta(book, {}, nil, data)
    book.last_opened = self:historyTimes()[path]
    Core.buildSearchKey(book, self.opts.lower)
    return book
end

return Index
