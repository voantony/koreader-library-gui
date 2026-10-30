--[[--
Built-in covers: small JPEG thumbnails in the plugin's own cache folder.

Covers come from KOReader's own FileManagerBookInfo:getCoverImage(), the
function behind the "book cover" screensaver and the Book information
screen, so custom covers set in KOReader are used too. A background
subprocess opens each book once, shrinks the cover to the largest tile the
column menu can produce, and writes one file per book:

    <cache>/library_covers/<path hash>-<mtime>-<size>.jpg   the thumbnail
    <cache>/library_covers/<path hash>-<mtime>-<size>.none  no cover / unreadable
    <cache>/library_covers/<path hash>-<mtime>-<size>.try   attempt in progress

The book's mtime and size are part of the name, so a changed file gets a
new name and is extracted again. There is no database.

The subprocess takes its work from a queue file that the Library view
rewrites when the page changes (visible books first), so a page turn
re-orders the work without killing the job. Removing the queue file makes
the job stop after the book it is working on.

The parts above the "KOReader glue" line are plain Lua and covered by
spec/librarycovers_spec.lua.
--]]

local M = {}

M.QUALITY = 85    -- JPEG quality of the thumbnails
M.MAX_TRIES = 2   -- interrupted attempts (crash, kill) before a book is marked "none"
M.MIN_COLS = 3    -- smallest choice in the column menu = largest tiles
M.MAX_SIDE = 800  -- cap for very large screens (a Colorsoft at 3 columns needs 607 px)
M.QUEUE_NAME = "queue.txt"

----------------------------------------------------------------------------
-- Names
----------------------------------------------------------------------------

local TWO32 = 4294967296

-- a XOR b for 0 <= a < 2^32, 0 <= b < 256 (only the low byte changes)
local function xorByte(a, b)
    local lo = a % 256
    local r, bitv = 0, 1
    for _ = 1, 8 do
        local x, y = lo % 2, b % 2
        if x ~= y then r = r + bitv end
        lo, b, bitv = (lo - x) / 2, (b - y) / 2, bitv * 2
    end
    return a - a % 256 + r
end

-- FNV-1a, 32 bits, in plain arithmetic (Lua 5.1 and LuaJIT alike).
-- h * 16777619 mod 2^32 == ((h mod 2^8) * 2^24 + h * 403) mod 2^32
local function fnv1a(s, h, from, to, step)
    for i = from, to, step do
        h = xorByte(h, s:byte(i))
        h = ((h % 256) * 16777216 + h * 403) % TWO32
    end
    return h
end

--- 16 hex digits: FNV-1a over the path, and again backwards with another seed.
function M.hash(s)
    local a = fnv1a(s, 2166136261, 1, #s, 1)
    local b = fnv1a(s, 1540483477, #s, 1, -1)
    return string.format("%08x%08x", a, b)
end

local hash_memo = setmetatable({}, { __mode = "k" })
local function pathHash(path)
    local h = hash_memo[path]
    if not h then h = M.hash(path); hash_memo[path] = h end
    return h
end

--- Cache key of a book record ({ path, modification, size }).
function M.key(book)
    return string.format("%s-%d-%d", pathHash(book.path),
        math.floor(tonumber(book.modification) or 0), math.floor(tonumber(book.size) or 0))
end

--- The hash part of a key or file name.
function M.hashOf(name)
    return name:match("^(%x+)%-")
end

--- Split "<hash>-<mtime>-<size>.<ext>" into key and extension.
function M.parseName(name)
    local key, ext = name:match("^(%x+%-%d+%-%d+)%.(%a+)$")
    return key, ext
end

----------------------------------------------------------------------------
-- Thumbnail size
----------------------------------------------------------------------------

--- Largest cover box the grid can show: a tile at `M.MIN_COLS` columns on
-- the narrow side of the screen, the same arithmetic as Core.gridLayout and
-- Tile:init (2:3 covers inside `pad`). Thumbnails are stored at this size,
-- so changing columns, the list view and the Continue reading row only
-- scale down from the file and never need a new extraction.
function M.thumbBox(screen_w, screen_h, gap, pad)
    local width = math.min(screen_w, screen_h or screen_w)
    gap, pad = gap or 0, pad or 0
    local cols = M.MIN_COLS
    local tile_w = math.floor((width - gap * (cols + 1)) / cols)
    local w = tile_w - 2 * pad
    local h = math.floor(tile_w * 1.5) - pad
    if h > M.MAX_SIDE then
        w = math.floor(w * M.MAX_SIDE / h)
        h = M.MAX_SIDE
    end
    return math.max(1, w), math.max(1, h)
end

--- Fit (w, h) inside (max_w, max_h), keeping the aspect ratio. Never upscales.
function M.fitDown(w, h, max_w, max_h)
    if w <= max_w and h <= max_h then return w, h end
    local scale = math.min(max_w / w, max_h / h)
    return math.max(1, math.floor(w * scale + 0.5)), math.max(1, math.floor(h * scale + 0.5))
end

----------------------------------------------------------------------------
-- Queue order
----------------------------------------------------------------------------

--- Work order: `first` (visible books, in screen order), then `rest`, each
-- book once, skipping those `done(book)` says are finished.
-- Returns { { key=, path= } }.
function M.order(first, rest, done)
    local out, seen = {}, {}
    local function add(list)
        for _, book in ipairs(list or {}) do
            if book and book.path and not seen[book.path] then
                seen[book.path] = true
                if not (done and done(book)) then
                    out[#out + 1] = { key = M.key(book), path = book.path }
                end
            end
        end
    end
    add(first)
    add(rest)
    return out
end

function M.encodeQueue(items)
    local lines = {}
    for _, it in ipairs(items) do
        -- a path with a newline or tab cannot be queued (and is never a book in practice)
        if not it.path:find("[\t\n]") then
            lines[#lines + 1] = it.key .. "\t" .. it.path
        end
    end
    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

function M.decodeQueue(text)
    local items = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local key, path = line:match("^([^\t]+)\t(.+)$")
        if key then items[#items + 1] = { key = key, path = path } end
    end
    return items
end

----------------------------------------------------------------------------
-- Store: what the cache folder holds
----------------------------------------------------------------------------
-- `fs` is a small file-system adapter (see M.realFS below; the specs use a
-- fake): exists(p), read(p), write(p, s), rename(a, b), remove(p),
-- list(dir) -> { names }, size(p), mkdir(p).

local Store = {}
Store.__index = Store

function M.newStore(dir, fs)
    return setmetatable({ dir = dir, fs = fs, files = {}, scanned = false }, Store)
end

function Store:path(name) return self.dir .. "/" .. name end

--- Read the folder listing once; later lookups are table hits.
function Store:scan()
    self.fs.mkdir(self.dir)
    self.files = {}
    for _, name in ipairs(self.fs.list(self.dir) or {}) do
        local key, ext = M.parseName(name)
        if key and (ext == "jpg" or ext == "none") then self.files[name] = true end
    end
    self.scanned = true
end

--- "cover", path | "none" | nil (not extracted yet).
function Store:state(book)
    if not self.scanned then self:scan() end
    local key = M.key(book)
    if self.files[key .. ".jpg"] then return "cover", self:path(key .. ".jpg") end
    if self.files[key .. ".none"] then return "none" end
    return nil
end

--- Look on disk again for one book (after the subprocess may have written it).
function Store:refresh(book)
    local key = M.key(book)
    for _, ext in ipairs({ "jpg", "none" }) do
        local name = key .. "." .. ext
        self.files[name] = self.fs.exists(self:path(name)) or nil
    end
    return self:state(book)
end

--- Forget every file for `path` (all mtimes), e.g. after a custom cover changed.
function Store:forget(path)
    local h = M.hash(path)
    for _, name in ipairs(self.fs.list(self.dir) or {}) do
        if M.hashOf(name) == h then
            self.fs.remove(self:path(name))
            self.files[name] = nil
        end
    end
end

--- Delete everything (the ☰ "Clear cover cache" item).
function Store:clear()
    for _, name in ipairs(self.fs.list(self.dir) or {}) do
        if M.parseName(name) or name:match("%.tmp$") or name == M.QUEUE_NAME then
            self.fs.remove(self:path(name))
        end
    end
    self.files = {}
end

--- Number of thumbnails and bytes on disk.
function Store:usage()
    local n, bytes = 0, 0
    for _, name in ipairs(self.fs.list(self.dir) or {}) do
        if M.parseName(name) then
            n = n + 1
            bytes = bytes + (self.fs.size(self:path(name)) or 0)
        end
    end
    return n, bytes
end

----------------------------------------------------------------------------
-- Worker (runs in the subprocess)
----------------------------------------------------------------------------

--- Process the queue until it is empty or removed.
-- env = { fs=, dir=, queue=path of the queue file,
--         extract=function(path) -> cover or nil (may raise),
--         save=function(cover, tmp_path) -> true on success (frees cover),
--         max=optional item limit }
-- Returns a table of counts { done=, none=, skipped=, gave_up= }.
function M.work(env)
    local fs, dir = env.fs, env.dir
    local stats = { done = 0, none = 0, gave_up = 0 }
    local attempted = {}
    local function p(name) return dir .. "/" .. name end
    local n = 0
    while true do
        if env.max and n >= env.max then break end
        local text = fs.read(env.queue)
        if not text then break end -- queue removed: stop
        local item
        for _, it in ipairs(M.decodeQueue(text)) do
            if not attempted[it.key] and not fs.exists(p(it.key .. ".jpg"))
                    and not fs.exists(p(it.key .. ".none")) then
                item = it
                break
            end
        end
        if not item then break end
        attempted[item.key] = true
        n = n + 1
        local try = p(item.key .. ".try")
        local tries = tonumber(fs.read(try) or "") or 0
        if tries >= M.MAX_TRIES then
            -- earlier attempts died (crash or kill) before finishing: give up
            fs.rename(try, p(item.key .. ".none"))
            stats.gave_up = stats.gave_up + 1
        else
            fs.write(try, tostring(tries + 1))
            local ok, cover = pcall(env.extract, item.path)
            local saved = false
            if ok and cover then
                local tmp = p(item.key .. ".jpg.tmp")
                saved = env.save(cover, tmp) and fs.rename(tmp, p(item.key .. ".jpg"))
                if not saved then fs.remove(tmp) end
            end
            if saved then
                fs.remove(try)
                stats.done = stats.done + 1
                -- drop thumbnails of older versions of this file
                local h = M.hashOf(item.key)
                for _, name in ipairs(fs.list(dir) or {}) do
                    if M.hashOf(name) == h and not name:find(item.key, 1, true) then
                        fs.remove(p(name))
                    end
                end
            else
                fs.rename(try, p(item.key .. ".none"))
                stats.none = stats.none + 1
            end
        end
    end
    return stats
end

----------------------------------------------------------------------------
-- KOReader glue (not loaded by the specs)
----------------------------------------------------------------------------

--- File-system adapter over lfs and io.
function M.realFS()
    local lfs = require("libs/libkoreader-lfs")
    return {
        exists = function(p) return lfs.attributes(p, "mode") == "file" end,
        read = function(p)
            local f = io.open(p, "rb")
            if not f then return nil end
            local s = f:read("*a")
            f:close()
            return s
        end,
        write = function(p, s)
            local f = io.open(p, "wb")
            if not f then return false end
            f:write(s)
            f:close()
            return true
        end,
        rename = function(a, b) return os.rename(a, b) and true or false end,
        remove = function(p) return os.remove(p) and true or false end,
        list = function(dir)
            local out = {}
            local ok, iter, dir_obj = pcall(lfs.dir, dir)
            if not ok then return out end
            for name in iter, dir_obj do
                if name ~= "." and name ~= ".." then out[#out + 1] = name end
            end
            return out
        end,
        size = function(p) return lfs.attributes(p, "size") end,
        mkdir = function(p)
            if lfs.attributes(p, "mode") ~= "directory" then
                require("util").makePath(p)
            end
        end,
    }
end

local store
--- The shared Store for <cache dir>/library_covers.
function M.getStore()
    if not store then
        local DataStorage = require("datastorage")
        store = M.newStore(DataStorage:getDataDir() .. "/cache/library_covers", M.realFS())
    end
    return store
end

--- Thumbnail box for this screen.
function M.screenBox()
    local Screen = require("device").screen
    local Size = require("ui/size")
    return M.thumbBox(Screen:getWidth(), Screen:getHeight(), Size.padding.default, Size.padding.small)
end

--- Decode a thumbnail file into a blitbuffer (nil if unreadable).
function M.loadThumb(path)
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if ok and bb then return bb end
    return nil
end

----------------------------------------------------------------------------
-- The background job
----------------------------------------------------------------------------

local job = {
    pid = nil,
    listener = nil,
    polling = false,
    relaunches = 0,
    stop_requested_at = nil,
}
M.POLL_S = 0.5
M.KILL_AFTER_S = 20 -- a job asked to stop that is still running after this is killed
M.MAX_RELAUNCH = 3  -- relaunches after a subprocess died with work left (crashing book)

local function queuePath() return M.getStore().dir .. "/" .. M.QUEUE_NAME end
local function tmpCreCache() return require("datastorage"):getDataDir() .. "/cache/library_covers_cr3tmp" end

function M.isRunning() return job.pid ~= nil end

--- The function the subprocess runs.
local function task()
    local st = M.getStore()
    local fs = st.fs
    -- Same trick as coverbrowser: a throwaway crengine cache, so extracting
    -- does not fill the cache of the books actually being read.
    local cre = require("document/credocument"):engineInit()
    cre.initCache(tmpCreCache(), 0, true, G_reader_settings:readSetting("cre_storage_size_factor") or 20)
    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    local RenderImage = require("ui/renderimage")
    local box_w, box_h = M.screenBox()
    M.work{
        fs = fs,
        dir = st.dir,
        queue = queuePath(),
        extract = function(path)
            return (BookInfo:getCoverImage(nil, path))
        end,
        save = function(bb, tmp)
            local w, h = M.fitDown(bb:getWidth(), bb:getHeight(), box_w, box_h)
            if w ~= bb:getWidth() or h ~= bb:getHeight() then
                bb = RenderImage:scaleBlitBuffer(bb, w, h, true)
            end
            local ok = bb:writeToFile(tmp, "jpg", M.QUALITY)
            bb:free()
            return ok and fs.exists(tmp)
        end,
    }
end

local function notify(done)
    if job.listener then
        local ok, err = pcall(job.listener, done)
        if not ok then require("logger").warn("Library covers: listener failed:", err) end
    end
end

local function hasPending()
    local st = M.getStore()
    local text = st.fs.read(queuePath())
    if not text then return false end
    for _, it in ipairs(M.decodeQueue(text)) do
        if not st.fs.exists(st:path(it.key .. ".jpg")) and not st.fs.exists(st:path(it.key .. ".none")) then
            return true
        end
    end
    return false
end

local launch

local function poll()
    local UIManager = require("ui/uimanager")
    local ffiUtil = require("ffi/util")
    job.polling = false
    if not job.pid then return end
    if ffiUtil.isSubProcessDone(job.pid) then
        job.pid = nil
        UIManager:allowStandby()
        require("device"):enableCPUCores(1)
        ffiUtil.purgeDir(tmpCreCache())
        -- Died with work left (a book that crashes the engine): its .try
        -- marker counts the attempt; go again so it ends up as "none".
        if not job.stop_requested_at and job.relaunches < M.MAX_RELAUNCH and hasPending() then
            job.relaunches = job.relaunches + 1
            launch()
        end
        notify(job.pid == nil)
    else
        if job.stop_requested_at
                and require("ui/time").to_s(require("ui/time").now() - job.stop_requested_at) > M.KILL_AFTER_S then
            ffiUtil.terminateSubProcess(job.pid)
        end
        notify(false)
    end
    if job.pid and not job.polling then
        job.polling = true
        UIManager:scheduleIn(M.POLL_S, poll)
    end
end

launch = function()
    local UIManager = require("ui/uimanager")
    local ffiUtil = require("ffi/util")
    local pid = ffiUtil.runInSubProcess(task)
    if not pid then
        require("logger").warn("Library covers: could not start the background job (fork failed)")
        return false
    end
    job.pid = pid
    job.stop_requested_at = nil
    UIManager:preventStandby()
    require("device"):enableCPUCores(2)
    if not job.polling then
        job.polling = true
        UIManager:scheduleIn(M.POLL_S, poll)
    end
    return true
end

--- Replace the work queue (visible books first) and make sure a job runs.
-- `listener(done)` is called on every poll while the job runs; `done` is
-- true once it has stopped.
function M.submit(items, listener)
    local st = M.getStore()
    if not st.scanned then st:scan() end
    job.listener = listener
    job.relaunches = 0
    local qp = queuePath()
    local tmp = qp .. ".tmp"
    if not st.fs.write(tmp, M.encodeQueue(items)) or not st.fs.rename(tmp, qp) then
        return false
    end
    if job.pid then
        job.stop_requested_at = nil -- a stopping job picks the new queue up if it is still reading it
        return true
    end
    if #items == 0 then return true end
    return launch()
end

--- Stop: remove the queue; the job finishes the book it is on and exits
-- (it is killed if it does not within M.KILL_AFTER_S).
function M.cancel()
    job.listener = nil
    local st = M.getStore()
    st.fs.remove(queuePath())
    if job.pid and not job.stop_requested_at then
        job.stop_requested_at = require("ui/time").now()
    end
end

--- Stop at once (before clearing the cache).
function M.kill()
    M.cancel()
    if job.pid then require("ffi/util").terminateSubProcess(job.pid) end
end

return M
