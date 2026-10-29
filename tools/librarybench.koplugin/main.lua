--[[--
Development-only benchmark driver for the Library plugin.

Runs only when LIBRARY_BENCH_OUT is set. Measures scans, grid rendering and
per-keystroke search in the KOReader emulator, saves screenshots and writes
results.lua to $LIBRARY_BENCH_OUT, then quits KOReader.
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local DataStorage = require("datastorage")
local time = require("ui/time")
local logger = require("logger")
local Screen = Device.screen

local OUT = os.getenv("LIBRARY_BENCH_OUT")
local ran = false

local Bench = WidgetContainer:extend{ name = "librarybench", is_doc_only = false }

local function now() return time.to_ms(time.now()) end

local function median(t)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    table.sort(c)
    local n = #c
    if n == 0 then return 0 end
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

local function stats(t)
    local mx = 0
    for _, v in ipairs(t) do mx = math.max(mx, v) end
    return { median = median(t), max = mx, n = #t }
end

function Bench:init()
    logger.info("librarybench init", OUT, ran, self.ui.file_chooser ~= nil, self.ui.document ~= nil)
    if not OUT or ran or self.ui.document then return end
    ran = true
    self.results = { screenshots = {} }
    self.steps = {}
    UIManager:scheduleIn(2, function() self:start() end)
end

function Bench:shot(name)
    local path = OUT .. "/" .. name .. ".png"
    UIManager:forceRePaint()
    Screen:shot(path)
    table.insert(self.results.screenshots, name .. ".png")
end

function Bench:paint()
    local t0 = now()
    UIManager:forceRePaint()
    return now() - t0
end

-- Run steps one after another, letting UIManager breathe in between.
function Bench:queue(fn, delay) table.insert(self.steps, { fn = fn, delay = delay or 0.3 }) end
function Bench:next()
    local step = table.remove(self.steps, 1)
    if not step then return self:finish() end
    UIManager:scheduleIn(step.delay, function()
        logger.info("librarybench step", #self.steps)
        local ok, err = pcall(step.fn, self)
        if not ok then
            logger.err("librarybench step failed:", err)
            self.results.error = tostring(err)
            return self:finish()
        end
        self:next()
    end)
end

function Bench:start()
    local lib = self.ui.library
    local shared = lib.shared
    local R = self.results
    R.startup_view_shown = shared.view ~= nil
    R.screen = { w = Screen:getWidth(), h = Screen:getHeight(), dpi = Screen:getDPI() }
    R.bim = lib:getBIM() and (lib:getBIM().db_location or "loaded") or "none"
    if shared.view then UIManager:close(shared.view); UIManager:forceRePaint() end

    -- 1. Scans: first (no disk cache) and cached (fresh index object, warm disk cache).
    self:queue(function()
        local Index = require("libraryindex")
        local first, cached, first_stats, cached_stats = {}, {}, nil, nil
        for _ = 1, 5 do
            os.remove(DataStorage:getSettingsDir() .. "/library_index.lua")
            shared.index = nil
            local idx = lib:getIndex()
            local t0 = now(); idx:build(true); first[#first + 1] = now() - t0
            first_stats = idx.stats
            idx.needs_build = false
            shared.index = nil
            local idx2 = lib:getIndex()
            t0 = now(); idx2:build(false); cached[#cached + 1] = now() - t0
            cached_stats = idx2.stats
            idx2.needs_build = false
        end
        R.books = #shared.index.books
        R.first_scan_ms = stats(first)
        R.cached_scan_ms = stats(cached)
        R.first_scan_detail = first_stats
        R.cached_scan_detail = cached_stats
        R.meta_sources = {}
        for _, b in ipairs(shared.index.books) do
            R.meta_sources[b.src] = (R.meta_sources[b.src] or 0) + 1
        end
    end)

    -- 2. Fill the cover database once (Project: Title / coverbrowser does this on its own on a device).
    self:queue(function()
        local bim = lib:getBIM()
        if not bim then return end
        local files = {}
        for _, b in ipairs(shared.index.books) do
            files[#files + 1] = { filepath = b.path, cover_specs = { max_cover_w = 600, max_cover_h = 600 } }
        end
        self.extract_t0 = now()
        bim:extractInBackground(files)
    end)
    self:queue(function() self:waitExtraction() end, 1)
    -- 2b. First scan without metadata.calibre: titles come from the cover DB (BIM).
    self:queue(function()
        local Index = require("libraryindex")
        local opts = {}
        for k, v in pairs(shared.index.opts) do opts[k] = v end
        opts.calibre_load = nil
        opts.cache_file = DataStorage:getSettingsDir() .. "/library_index_bench_nocal.lua"
        local times, st, srcs = {}, nil, {}
        for _ = 1, 5 do
            os.remove(opts.cache_file)
            local idx = Index.new(opts)
            local t0 = now(); idx:build(true); times[#times + 1] = now() - t0
            st = idx.stats
            srcs = {}
            for _, b in ipairs(idx.books) do srcs[b.src] = (srcs[b.src] or 0) + 1 end
        end
        os.remove(opts.cache_file)
        R.first_scan_no_calibre_ms = stats(times)
        R.first_scan_no_calibre_detail = st
        R.meta_sources_no_calibre = srcs
    end)
    self:next()
end

function Bench:waitExtraction()
    local bim = self.ui.library:getBIM()
    if bim and bim:isExtractingInBackground() and now() - self.extract_t0 < 300000 then
        -- poll again later, keep the rest of the queue
        table.insert(self.steps, 1, { fn = function() self:waitExtraction() end, delay = 1 })
        return
    end
    self.results.cover_extraction_ms = now() - (self.extract_t0 or now())
    self:queueUI()
end

function Bench:queueUI()
    local lib = self.ui.library
    local shared = lib.shared
    local R = self.results

    -- 3. Open the view and time grid render (cold covers, then warm).
    self:queue(function()
        local t0 = now()
        lib:onShowLibrary()
        local view = shared.view
        local build = now() - t0
        local paint = self:paint()
        R.open_view_ms = { build = build, paint = paint, total = build + paint }
        self:shot("01-library-recent")
    end, 0.5)
    self:queue(function()
        local view = shared.view
        local cold, warm = {}, {}
        -- cold: pages never shown before
        for p = 2, math.min(view.pages, 6) do
            view.cover_cache:clear()
            local t0 = now(); view:goToPage(p); local b = now() - t0
            cold[#cold + 1] = b + self:paint()
        end
        -- warm: revisit page 2 and back (covers cached)
        for _ = 1, 5 do
            local t0 = now(); view:goToPage(2); local b = now() - t0
            warm[#warm + 1] = b + self:paint()
            t0 = now(); view:goToPage(3); b = now() - t0
            warm[#warm + 1] = b + self:paint()
        end
        R.page_render_cold_ms = stats(cold)
        R.page_render_warm_ms = stats(warm)
        R.per_page = view.layout.per_page
        view:goToPage(1)
        self:paint()
    end)

    -- 4. Search: per keystroke (filter + grid rebuild + repaint), keyboard up.
    self:queue(function()
        local view = shared.view
        view:openKeyboard()
        self:paint()
        self:shot("02-search-keyboard")
        local per_key, filter_ms, build_ms, results = {}, {}, {}, {}
        for _, q in ipairs({ "sherlock", "jane austen", "oz", "mars", "dickens", "collected works 3", "zzz" }) do
            view.search_input:setText("")
            view:applySearch("")
            self:paint()
            for i = 1, #q do
                local prefix = q:sub(1, i)
                view.search_input:setText(prefix, true)
                local t0 = now()
                view:applySearch(prefix)
                local b = now() - t0
                local p = self:paint()
                per_key[#per_key + 1] = b + p
                filter_ms[#filter_ms + 1] = view.timings.filter_s * 1000
                build_ms[#build_ms + 1] = view.timings.build_s * 1000
            end
            results[q] = #view.current.items
        end
        R.search_keystroke_ms = stats(per_key)
        R.search_filter_ms = stats(filter_ms)
        R.search_grid_build_ms = stats(build_ms)
        R.search_results = results
        view.search_input:setText("sherlock")
        view:applySearch("sherlock")
        self:paint()
        self:shot("03-search-results")
    end)

    -- 5. Pure search speed on a 10x larger in-memory library (2000 books).
    self:queue(function()
        local Core = require("librarycore")
        local util = require("util")
        local big = {}
        for k = 1, 10 do
            for _, b in ipairs(shared.index.books) do
                local c = {}
                for kk, v in pairs(b) do c[kk] = v end
                c.title = c.title .. " " .. k
                Core.buildSearchKey(c, util.stringLower)
                big[#big + 1] = c
            end
        end
        local per = {}
        for _, q in ipairs({ "sherlock", "jane austen", "oz", "mars", "dickens" }) do
            local prev, prevq
            for i = 1, #q do
                local prefix = q:sub(1, i)
                local t0 = time.now()
                local narrowed = Core.isRefinement(prevq, prefix) and prev or nil
                prev = Core.searchIndexed(big, prefix, util.stringLower, narrowed)
                prevq = prefix
                per[#per + 1] = time.to_s(time.now() - t0) * 1000
            end
        end
        R.search_filter_2000_books_ms = stats(per)
    end)

    -- 6. Other views for screenshots.
    self:queue(function()
        local view = shared.view
        view:closeKeyboard()
        view:clearSearch()
        view:setFilter("reading")
        self:shot("04-filter-reading")
        view:setFilter("finished")
        self:shot("05-filter-finished")
        view:setFilter("all")
        view:setTab("collections")
        self:shot("06-collections")
        local groups = view.current.items
        for _, g in ipairs(groups) do
            if g.name == "Sea stories" then view:openGroup(g) end
        end
        self:shot("07-collection-open")
        view:closeGroup()
        view:setTab("series")
        self:shot("08-series")
        view:setTab("authors")
        self:shot("09-authors")
        view:setTab("books")
        view:resort("title")
        self:shot("10-sort-title")
        view:resort("recent")
    end)

    -- 6b. Continue reading strip and list view (0.2.0).
    self:queue(function()
        local view = shared.view
        view:setViewMode("grid")
        view:setShowContinue(true)
        view:setTab("books")
        view:setFilter("all")
        R.continue_books = view.continue_books and #view.continue_books or 0
        R.grid_per_page_with_continue = view.layout.per_page
        R.dims = { label_h = view.label_h, list_row_h = view.list_row_h,
            continue_h = view.continue_layout and view.continue_layout.height, continue_cover_h = view.continue_layout and view.continue_layout.cover_h,
            grid_rows = view.layout.rows, grid_cover_h = view.layout.cover_h }
        self:shot("12-grid-continue-reading")
        view:goToPage(2)
        self:shot("x-grid-continue-page2")
        view:goToPage(1)
        view:setViewMode("list")
        R.list_rows_with_continue = view.layout.rows
        self:shot("x-list-continue")
        view:setShowContinue(false)
        R.list_rows = view.layout.rows
        R.list_row_h_used = view.layout.row_h
        -- Tap and hold on a list row and on a Continue reading cover go
        -- through the same callbacks as grid tiles.
        local Event = require("ui/event")
        local Geom = require("ui/geometry")
        local function gesture(kind, widget)
            local d = widget.dimen
            local pos = Geom:new{ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2), w = 0, h = 0 }
            view:handleEvent(Event:new("Gesture", { ges = kind, pos = pos, time = time.now() }))
        end
        local open, dialog = lib.openBook, lib.showBookDialog
        local hits = {}
        lib.openBook = function(_self, path) hits[#hits + 1] = "open " .. path:match("[^/]+$") end
        lib.showBookDialog = function(_self, book) hits[#hits + 1] = "hold " .. book.path:match("[^/]+$") end
        self:paint() -- tiles learn their screen position when painted
        gesture("tap", view.tiles[2])
        gesture("hold", view.tiles[2])
        R.list_row_2 = view.tiles[2].book.path:match("[^/]+$")
        view:setShowContinue(true)
        self:paint()
        gesture("tap", view.continue_tiles[1])
        gesture("hold", view.continue_tiles[1])
        R.continue_1 = view.continue_tiles[1].book.path:match("[^/]+$")
        lib.openBook, lib.showBookDialog = open, dialog
        R.gesture_hits = hits
        view:setShowContinue(false)
        self:shot("13-list-view")
        view:setShowContinue(true)
        view:setTab("authors")
        self:shot("x-list-authors")
        view:setTab("collections")
        self:shot("x-list-collections")
        view:setTab("books")
        view:setFilter("reading")
        self:shot("x-list-filter-reading")
        view:setFilter("all")
        view.search_input:setText("jane austen")
        view:applySearch("jane austen")
        self:shot("14-list-search")
        view:openKeyboard()
        self:paint()
        self:shot("x-list-search-keyboard")
        view:closeKeyboard()
        view:clearSearch()
        lib:showLibraryMenu(view)
        self:shot("x-menu")
        local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
        if top and top ~= view then UIManager:close(top) end
        view:setViewMode("grid")
    end)

    -- 7. Close -> file browser (Project: Title).
    self:queue(function()
        UIManager:close(shared.view)
        UIManager:forceRePaint()
        self:shot("11-file-browser-fallback")
    end, 1)
end

function Bench:finish()
    local Core = require("librarycore")
    local f = io.open(OUT .. "/results.lua", "w")
    if f then
        f:write(Core.serialize(self.results), "\n")
        f:close()
    end
    logger.info("librarybench done")
    UIManager:scheduleIn(0.5, function() UIManager:quit() end)
end

return Bench
