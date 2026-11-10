--- README scenarios for tools/emulator/shoot.sh.
-- Loaded by guiprobe.koplugin/main.lua. Each job waits until the covers
-- on screen have been extracted, then writes a PNG. Returns a table of
-- scenario functions keyed by the name shoot.sh passes.
return function(api)
local P, q, again = api.P, api.q, api.again
local shot, shotRaw = api.shot, api.shotRaw
local V, lib, FM = api.V, api.lib, api.FM
local state = api.state
local dismissNotices, findText, walk = api.dismissNotices, api.findText, api.walk
local whenLibrary, RUI, stackLine = api.whenLibrary, api.RUI, api.stackLine
local Screen, UIManager, Device = api.Screen, api.UIManager, api.Device

local Geom = require("ui/geometry")

local function closeAboveView()
    local view = V()
    if not view then return end
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == view then return end
        local label = w.title or w.name or "?"
        if type(label) ~= "string" then label = tostring(label) end
        P("close", label:gsub("%s+", " "):sub(1, 80))
        UIManager:close(w)
    end
end

local function findAnywhere(pattern)
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local found = findText(stack[i].widget, pattern)
        if found then return found end
    end
end

local function clearSearch(view)
    if view.query and view.query ~= "" then
        if view.search_input and view.search_input.setText then
            view.search_input:setText("")
        end
        view:applySearch("")
    end
end

--- Put the Books tab back to a known grid. `widgets` is "default" (the
-- single Continue reading row), a slot list, or omitted to leave it.
local function home(opts)
    opts = opts or {}
    closeAboveView()
    local view = V()
    if not view then return nil end
    if view.closeKeyboard then view:closeKeyboard() end
    clearSearch(view)
    if view.group and view.closeGroup then view:closeGroup() end
    view._shelf_expanded = nil
    view._widget_expanded = nil
    if opts.top then view:setTopRow(opts.top) end
    if opts.widgets == "default" then
        view:setHomeWidgets(nil)
    elseif opts.widgets then
        view:setHomeWidgets(opts.widgets)
    end
    if opts.continue ~= nil then view:setShowContinue(opts.continue) end
    if opts.tab then view:setTab(opts.tab) end
    if opts.view then view:setViewMode(opts.view) end
    if opts.sort then view:resort(opts.sort) end
    if opts.filter then view:setFilter(opts.filter) end
    if opts.clock ~= nil then view:setShowClock(opts.clock) end
    if opts.battery ~= nil then view:setShowBattery(opts.battery) end
    if opts.expanded then
        view._widget_expanded = opts.expanded
        view:refreshBody(true)
    end
    return V()
end

--- A painted book is ready when the library cache or CoverBrowser has a
-- thumbnail. `missing_covers` is only the books on screen, not the whole
-- library. Calling scheduleCoverExtraction on every poll unschedules the
-- job before it starts, so this asks for extraction once.
local function bookReady(view, book)
    if type(book) ~= "table" or type(book.path) ~= "string" then return true end
    local covers = view.covers or {}
    local store = covers.store
    if store and store.refresh then
        local st = store:refresh(book)
        if st == "cover" or st == "none" then return true end
    end
    local bim = covers.bim
    if bim and bim.getBookInfo then
        local ok, info = pcall(bim.getBookInfo, bim, book.path, false)
        if ok and type(info) == "table" then
            if info.cover_bb or info.has_cover or info.cover_fetched == "Y" then
                return true
            end
        end
    end
    return false
end

local function countCovers(view)
    local pending, seen = 0, 0
    for _, b in ipairs(view.missing_covers or {}) do
        seen = seen + 1
        if not bookReady(view, b) then pending = pending + 1 end
    end
    return pending, seen
end

--- CoverBrowser usually fills the grid from the file list. Widget books
-- are not on that list, so pull those thumbnails here before the shot.
local function extractMissing(view)
    local bim = view.covers and view.covers.bim
    if not (bim and bim.extractBookInfo) then return 0 end
    local specs = { max_cover_w = 600, max_cover_h = 600 }
    local n = 0
    for _, b in ipairs(view.missing_covers or {}) do
        if type(b) == "table" and b.path and not bookReady(view, b) then
            local ok, err = pcall(bim.extractBookInfo, bim, b.path, specs)
            n = n + 1
            P("extract", b.title or b.name or "?", ok and "ok" or tostring(err))
            if n >= 8 then break end
        end
    end
    return n
end

--- Call fn once every visible cover is ready (or the wait runs out).
local function whenPainted(fn)
    local tries = 0
    local asked = false
    local function poll()
        tries = tries + 1
        dismissNotices()
        local view = V()
        if not view then
            state.ok = false
            P("FAIL no library view")
            fn()
            return
        end
        if not asked and view.scheduleCoverExtraction then
            asked = true
            pcall(function() view:scheduleCoverExtraction() end)
        end
        local pending, seen = countCovers(view)
        P("covers", "pending", pending, "missing", seen, "try", tries)
        if pending > 0 and tries < 12 then
            extractMissing(view)
            again(0.3, poll)
            return
        end
        if pending > 0 then
            state.ok = false
            P("FAIL covers still pending", pending, "of", seen)
        end
        view:refreshBody(true)
        -- The rebuild asks for any cover that is still a placeholder.
        local again_pending = countCovers(view)
        if again_pending > 0 and tries < 40 then
            P("covers after rebuild", again_pending)
            again(1, poll)
            return
        end
        fn()
    end
    q(0.4, poll)
end

local function footerBookIcon(view)
    local h = Screen:getHeight()
    local found = false
    walk(view, function(w)
        if found or w.icon ~= "book.opened" or not w.dimen or not w.dimen.y then return end
        if w.dimen.y > h * 0.8 then found = true end
    end, {})
    return found
end

--- expect_strip: true (exactly one column on the right), false (none),
-- or nil (don't care, still log it).
local function audit(name, expect_strip)
    local view = V()
    if not view then
        P("AUDIT", name, "no view")
        return
    end
    UIManager:forceRePaint()
    local n, left, wide = 0, false, false
    local parts = {}
    for _, sc in ipairs(view:eachScrubber()) do
        n = n + 1
        local d = sc.dimen
        local x = d and d.x or -1
        local w = d and d.w or -1
        parts[#parts + 1] = x .. "x" .. w
        if x >= 0 and x < (view.width or Screen:getWidth()) / 2 then left = true end
        if w > 80 then wide = true end
    end
    local book = footerBookIcon(view)
    P("AUDIT", name, "strips", n, table.concat(parts, ","),
        "bookicon", book and "yes" or "no",
        "sort", tostring(view.sort), "view", tostring(view.view_mode))
    if book then
        state.ok = false
        P("FAIL footer still has the book icon", name)
    end
    if expect_strip == true and (n ~= 1 or left or wide) then
        state.ok = false
        P("FAIL wanted one right-hand A-Z column", name)
    elseif expect_strip == false and n ~= 0 then
        state.ok = false
        P("FAIL strip should be hidden", name)
    end
end

local function capture(name, expect_strip)
    audit(name, expect_strip)
    shot(name)
end

local function findBook(view, pattern)
    for _, b in ipairs(view.all_books or view.sorted or {}) do
        local title = (b.title or b.name or "")
        if title:match(pattern) then return b end
    end
end

local function stripPoint(sc, letter)
    if not (sc and sc.dimen and sc.letters) then return nil end
    for i, l in ipairs(sc.letters) do
        if l == letter then
            local d = sc.dimen
            local y = d.y + math.floor((i - 0.5) * d.h / #sc.letters)
            return d.x + math.floor(d.w / 2), y
        end
    end
end

local function widgetSlots(view)
    local ctx = view:widgetBookContext()
    P("widgets", "continue", #(ctx.continue or {}), "favorites", #(ctx.favorites or {}))
    local second = { kind = "favorites" }
    if #(ctx.favorites or {}) == 0 then
        for _, g in ipairs(ctx.collections or {}) do
            if #(g.books or {}) > 0 then
                second = { kind = "collection", name = g.name }
                P("favorites fallback", g.name, #g.books)
                break
            end
        end
    end
    return { { kind = "continue" }, second }
end

local jobs = {}

jobs.widgets = function(done)
    q(0.2, function()
        local view = home{ top = "continue", sort = "title", view = "grid",
            tab = "books", filter = "all", clock = true, battery = true }
        if view then view:setHomeWidgets(widgetSlots(view)) end
    end)
    whenPainted(function()
        capture("v050-widgets", true)
        done()
    end)
end

jobs.accordion = function(done)
    q(0.2, function()
        local view = home{ top = "continue", sort = "title", view = "grid",
            tab = "books", filter = "all" }
        if not view then return end
        view:setHomeWidgets(widgetSlots(view))
        view._widget_expanded = 1
        view:refreshBody(true)
    end)
    whenPainted(function()
        local view = V()
        P("accordion", "expanded", view and view._widget_expanded)
        if not (view and view._widget_expanded == 1) then
            state.ok = false
            P("FAIL accordion did not expand")
        end
        capture("v050-accordion", true)
        done()
    end)
end

jobs.recently = function(done)
    q(0.2, function()
        home{ widgets = { { kind = "added" } }, sort = "title", view = "grid",
            tab = "books", filter = "all", top = "continue" }
    end)
    whenPainted(function()
        capture("v050-recently-added", true)
        done()
    end)
end

jobs.shelf = function(done)
    q(0.2, function()
        home{ widgets = "default", continue = true, top = "continue",
            sort = "title", view = "grid", tab = "books", filter = "all" }
    end)
    whenPainted(function()
        capture("v050-shelf-before", true)
        local view = V()
        local h = Screen:getHeight()
        local expanded = false
        for _, frac in ipairs({ 0.78, 0.88, 0.62 }) do
            local y = math.floor(h * frac)
            if view.body_y and y < view.body_y + 8 then y = view.body_y + 40 end
            local ok = view:toggleShelfExpand(true, {
                pos = { x = 360, y = y },
                end_pos = { x = 360, y = math.max(0, y - 520) },
            })
            P("shelf", "y", y, "body", view.body_y, "ok", ok, "flag", view._shelf_expanded)
            if ok or view._shelf_expanded then
                expanded = true
                break
            end
        end
        if not expanded then
            state.ok = false
            P("FAIL shelf did not expand")
        end
        whenPainted(function()
            capture("v050-shelf-expanded", true)
            done()
        end)
    end)
end

jobs.bubble = function(done)
    q(0.2, function()
        home{ widgets = "default", continue = false, top = "continue",
            sort = "title", view = "grid", tab = "books", filter = "all" }
    end)
    whenPainted(function()
        local view = V()
        UIManager:forceRePaint()
        local sc = view.scrubber
        local x, y = stripPoint(sc, "M")
        P("bubble point", tostring(x), tostring(y))
        if not x then
            state.ok = false
            P("FAIL no M on the strip")
        else
            sc:dragTo(Geom:new{ x = x, y = y, w = 0, h = 0 })
            P("bubble letter", tostring(sc.bubble_letter))
            if sc.bubble_letter ~= "M" then
                state.ok = false
                P("FAIL bubble is not M")
            end
        end
        capture("v050-az-bubble", true)
        if sc and sc.endDrag then sc:endDrag() end
        done()
    end)
end

jobs.menu = function(done)
    q(0.2, function()
        home{ widgets = "default", continue = false, sort = "title", view = "grid",
            tab = "books", filter = "all" }
    end)
    whenPainted(function()
        local view = V()
        view:onLeftIcon()
        q(0.6, function()
            local label = findAnywhere("Widgets")
            P("menu", tostring(label), "stack", stackLine())
            if label ~= "Widgets" then
                state.ok = false
                P("FAIL menu has no Widgets row")
            end
            capture("v050-menu", nil)
            closeAboveView()
            done()
        end)
    end)
end

local function finishedDimen()
    local hit
    walk(V(), function(w)
        if hit or type(w.text) ~= "string" then return end
        if w.text:match("^Finished") and w.dimen and w.dimen.x then hit = w.dimen end
    end, {})
    return hit
end

local function finishedStatus()
    UIManager:forceRePaint()
    local d = finishedDimen()
    if not d then return "missing" end
    local screen_w = Screen:getWidth()
    local right = d.x + (d.w or 0)
    P("finished box", d.x, d.w, "right", right, "screen", screen_w)
    if d.x >= screen_w - 2 then return "offscreen" end
    if right > screen_w + 4 and d.x < screen_w - 12 then return "cut" end
    if right <= screen_w then return "full" end
    return "edge"
end

local function filterStrip()
    local found
    walk(V(), function(w)
        if w.name == "library_filter_strip" then found = w end
    end, {})
    return found
end

jobs.filters = function(done)
    q(0.2, function()
        home{ widgets = "default", continue = false, sort = "title", view = "grid",
            tab = "books", filter = "all" }
    end)
    whenPainted(function()
        local status = finishedStatus()
        P("filters on books", status)
        if status == "cut" then
            capture("v050-filters", true)
            done()
            return
        end
        local view = V()
        view:setTab("authors")
        local best
        for _, g in ipairs(view:groupsFor("authors") or {}) do
            if g.name and (not best or #g.name > #best.name) then best = g end
        end
        if best then
            P("filter shelf", best.name)
            view:openGroup(best)
        else
            state.ok = false
            P("FAIL no author shelf for the filter row")
        end
        whenPainted(function()
            local guard = 0
            while guard < 8 do
                guard = guard + 1
                status = finishedStatus()
                P("filters tune", guard, status)
                if status == "cut" then break end
                local strip = filterStrip()
                if not strip then break end
                -- Positive dx reveals the left; negative reveals the right.
                if status == "offscreen" or status == "missing" then
                    strip:applyScroll(-70)
                elseif status == "full" then
                    strip:applyScroll(70)
                else
                    break
                end
            end
            if status ~= "cut" then
                state.ok = false
                P("FAIL Finished is not cut off at the screen edge", status)
            end
            capture("v050-filters", nil)
            done()
        end)
    end)
end

--- KO_MULTIUSER makes this build the desktop device, which hides the
-- frontlight, warmth, e-ink refresh and Wi-Fi. A Kindle shows them.
-- Advertise those only for this shot; the edge-brightness number does
-- not need it, because the power device already has the calls.
local function advertiseKindleControls()
    Device.hasFrontlight = function() return true end
    Device.hasNaturalLight = function() return true end
    Device.hasEinkScreen = function() return true end
    Device.hasWifiToggle = function() return true end
    local power = Device:getPowerDevice()
    if power and power.setIntensity then pcall(power.setIntensity, power, 12) end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and not NetworkMgr._guiprobe_wifi then
        NetworkMgr._guiprobe_wifi = true
        NetworkMgr.isWifiOn = function() return true end
        NetworkMgr.isConnected = NetworkMgr.isWifiOn
    end
end

jobs.controls = function(done)
    q(0.2, function()
        home{ widgets = "default", continue = true, top = "continue",
            sort = "recent", view = "grid", tab = "books", filter = "all",
            clock = true, battery = true }
    end)
    whenPainted(function()
        advertiseKindleControls()
        local plugin = lib()
        local opened = plugin and plugin.openControls and plugin:openControls()
        P("controls", opened)
        if not opened then state.ok = false; P("FAIL controls did not open") end
        q(0.5, function()
            local top = (UIManager._window_stack or {})
            top = top[#top] and top[#top].widget
            P("controls widget", top and top.name)
            if not (top and top.name == "LibraryControls") then
                state.ok = false
                P("FAIL controls panel")
            end
            shot("09-controls-panel")
            closeAboveView()
            done()
        end)
    end)
end

jobs.brightness = function(done)
    q(0.2, function()
        home{ widgets = "default", continue = false, sort = "title", view = "grid",
            tab = "books", filter = "all" }
    end)
    whenPainted(function()
        local view = V()
        UIManager:forceRePaint()
        audit("v050-brightness", true)
        local h = Screen:getHeight()
        local y0 = math.floor(h * 0.62)
        local y1 = math.floor(h * 0.40)
        local began = view:beginEdgeLight(y0)
        P("brightness begin", began)
        if not began then
            state.ok = false
            P("FAIL frontlight is not available")
        else
            view:moveEdgeLight(y1)
            local level = view._edge and view._edge.level
            P("brightness level", tostring(level), "from", view._edge and view._edge.start_level)
            if type(level) ~= "number" or level == view._edge.start_level then
                state.ok = false
                P("FAIL brightness level did not change")
            end
        end
        -- The level is painted on the framebuffer. A repaint would wipe it.
        shotRaw("v050-brightness")
        if view.endEdgeLight then view:endEdgeLight() end
        done()
    end)
end

local function ensureLibrary(nextFn)
    local view = V()
    if view and view.pages and view.sorted and #view.sorted > 0 then
        nextFn()
        return
    end
    local plugin = lib()
    P("reopen library")
    if plugin and plugin.onShowLibrary then plugin:onShowLibrary() end
    local tries = 0
    local function poll()
        tries = tries + 1
        view = V()
        if view and view.pages and view.sorted and #view.sorted > 0 then
            dismissNotices()
            nextFn()
            return
        end
        if tries > 30 then
            state.ok = false
            P("FAIL library did not reopen")
            nextFn()
            return
        end
        again(1, poll)
    end
    q(0.6, poll)
end

local function tabIndex(menu, icon)
    if menu.setUpdateItemTable then pcall(function() menu:setUpdateItemTable() end) end
    local tabs = menu.tab_item_table or {}
    for i, tab in ipairs(tabs) do
        P("tab", i, tostring(tab.icon), tostring(tab.text or tab.id))
        if tab.icon == icon then return i end
    end
    return nil
end

jobs.startwith = function(done)
    q(0.3, function()
        local view = V()
        if view then UIManager:close(view) end
    end)
    q(0.8, function()
        local fm = FM()
        local setting = G_reader_settings and G_reader_settings.readSetting
            and G_reader_settings:readSetting("start_with")
        P("start_with", tostring(setting), "fm", fm and "yes" or "no", "stack", stackLine())
        if setting ~= "library" then
            state.ok = false
            P("FAIL Start with is not library")
        end
        if not (fm and fm.menu and fm.menu.onShowMenu) then
            state.ok = false
            P("FAIL no file manager menu")
            return
        end
        local idx = tabIndex(fm.menu, "appbar.filebrowser") or 1
        fm.menu:onShowMenu(idx)
    end)
    q(1.0, function()
        local label = findAnywhere("Start with")
        P("startwith row", tostring(label), "stack", stackLine())
        if not (label and label:find("library", 1, true)) then
            state.ok = false
            P("FAIL Start with row does not say library")
        end
        shot("v050-start-with")
        local fm = FM()
        if fm and fm.menu and fm.menu.onCloseFileManagerMenu then
            fm.menu:onCloseFileManagerMenu()
        end
        done()
    end)
end

local function shotThen(name, expect, done)
    return function()
        capture(name, expect)
        done()
    end
end

jobs.gallery = function(done)
    ensureLibrary(function()
        local steps_left
        steps_left = {
            function(nextFn)
                q(0.2, function()
                    home{ widgets = "default", continue = false, sort = "recent",
                        view = "compact2", tab = "books", filter = "all",
                        clock = true, battery = true }
                end)
                whenPainted(shotThen("02-compact-2-columns", false, nextFn))
            end,
            function(nextFn)
                q(0.2, function()
                    home{ widgets = "default", continue = false, sort = "recent",
                        view = "compact", tab = "books", filter = "all" }
                end)
                whenPainted(shotThen("03-compact", false, nextFn))
            end,
            function(nextFn)
                q(0.2, function()
                    home{ widgets = "default", continue = true, top = "recent",
                        sort = "recent", view = "grid", tab = "books", filter = "all" }
                end)
                whenPainted(shotThen("20-recently-opened", false, nextFn))
            end,
            function(nextFn)
                q(0.2, function()
                    home{ widgets = "default", continue = false, tab = "authors" }
                end)
                whenPainted(shotThen("04-authors", true, nextFn))
            end,
            function(nextFn)
                q(0.2, function()
                    home{ widgets = "default", continue = false, tab = "series" }
                end)
                whenPainted(function()
                    local view = V()
                    local multi = view and view.pages and view.pages > 1
                    capture("05-series", multi and true or false)
                    nextFn()
                end)
            end,
            function(nextFn)
                q(0.2, function()
                    local view = home{ widgets = "default", continue = false,
                        sort = "title", view = "grid", tab = "books", filter = "all" }
                    if view and view.search_input then
                        view.search_input:setText("wutherng hieghts")
                    end
                    if view then view:applySearch("wutherng hieghts") end
                    local n = view and view.sorted and #view.sorted or 0
                    P("search", n, view and view.sorted and view.sorted[1]
                        and (view.sorted[1].title or view.sorted[1].name))
                    if n < 1 then
                        state.ok = false
                        P("FAIL typo search found nothing")
                    end
                end)
                whenPainted(shotThen("06-search-typos", nil, nextFn))
            end,
            function(nextFn)
                q(0.2, function()
                    local view = home{ widgets = "default", continue = false,
                        sort = "recent", view = "grid", tab = "books", filter = "all" }
                    if view then view:showSortPicker() end
                end)
                q(0.6, function()
                    local label = findAnywhere("Sort by") or findAnywhere("Last read")
                    P("sort picker", tostring(label))
                    if not label then state.ok = false; P("FAIL sort picker") end
                    capture("07-sort-picker", nil)
                    closeAboveView()
                    nextFn()
                end)
            end,
            jobs.controls,
            function(nextFn)
                q(0.2, function()
                    local view = home{ widgets = "default", continue = false, tab = "collections" }
                    if view then view:setCollectionsView("genres") end
                end)
                whenPainted(shotThen("10-genres", nil, nextFn))
            end,
            function(nextFn)
                q(0.2, function()
                    local view = V()
                    local groups = view and view:groupsFor("genres") or {}
                    P("genres", #groups, groups[1] and groups[1].name)
                    if groups[1] then
                        view:openGroup(groups[1])
                    else
                        state.ok = false
                        P("FAIL no genre to open")
                    end
                end)
                whenPainted(shotThen("11-genre-books", nil, nextFn))
            end,
            function(nextFn)
                q(0.2, function()
                    local view = home{ widgets = "default", continue = false,
                        sort = "title", view = "grid", tab = "books", filter = "all" }
                    if view then view:showPageJump() end
                end)
                q(0.7, function()
                    local label = findAnywhere("Go to page")
                    P("goto", tostring(label))
                    if not label then state.ok = false; P("FAIL go to page") end
                    capture("19-go-to-page", nil)
                    closeAboveView()
                    nextFn()
                end)
            end,
            function(nextFn)
                q(0.2, function()
                    home{ widgets = "default", continue = false, sort = "title",
                        view = "grid", tab = "books", filter = "all" }
                end)
                whenPainted(function()
                    local view = V()
                    local book = findBook(view, "Wuthering") or findBook(view, "Pride")
                    local plugin = lib()
                    local index = plugin and plugin.ensureIndex and plugin:ensureIndex()
                    local orig = index and index.descriptionCandidates
                    if index and orig and book then
                        local blurb = "Wuthering Heights tells of Heathcliff and Catherine Earnshaw, and of the two houses on the Yorkshire moors."
                        if not (book.title or ""):match("Wuthering") then
                            blurb = "A public-domain novel. The details card shows its description beside the cover."
                        end
                        index.descriptionCandidates = function(self, path)
                            if path == book.path then return { blurb } end
                            return orig(self, path)
                        end
                    end
                    P("details book", book and (book.title or book.name))
                    if not (book and plugin and plugin.showBookDetails) then
                        state.ok = false
                        P("FAIL no book for the details card")
                    else
                        plugin:showBookDetails(book, view)
                    end
                    q(0.8, function()
                        local w = UIManager._window_stack[#UIManager._window_stack].widget
                        P("details", w and w.name)
                        if not (w and w.name == "LibraryBookDetails") then
                            state.ok = false
                            P("FAIL details card")
                        end
                        local text = findAnywhere("No description")
                        if text then
                            state.ok = false
                            P("FAIL details card has no description")
                        end
                        shot("13-details-card")
                        closeAboveView()
                        if index and orig then index.descriptionCandidates = orig end
                        nextFn()
                    end)
                end)
            end,
            function(nextFn)
                q(0.2, function()
                    local view = V()
                    local book = findBook(view, "Pride") or findBook(view, "Emma")
                    P("details none", book and (book.title or book.name))
                    local plugin = lib()
                    if book and plugin then plugin:showBookDetails(book, view) end
                end)
                q(0.8, function()
                    local text = findAnywhere("No description")
                    P("details none text", tostring(text))
                    if not text then
                        state.ok = false
                        P("FAIL empty details card still has a description")
                    end
                    shot("14-details-card-none")
                    closeAboveView()
                    nextFn()
                end)
            end,
            function(nextFn)
                q(0.2, function()
                    home{ widgets = "default", continue = false, sort = "recent",
                        view = "grid", tab = "books", filter = "all",
                        clock = false, battery = false }
                end)
                whenPainted(shotThen("17-books-status-off", false, nextFn))
            end,
            function(nextFn)
                q(0.3, function()
                    local view = V()
                    local book
                    for _, b in ipairs(view.sorted or {}) do
                        if b.path and b.path:match("%.epub$") then book = b break end
                    end
                    book = book or (view.sorted and view.sorted[1])
                    P("open", book and book.path)
                    if not book then
                        state.ok = false
                        P("FAIL no book to open")
                        q(0.1, nextFn)
                        return
                    end
                    lib():openBook(book.path, view)
                    local tries = 0
                    local function waitReader()
                    tries = tries + 1
                    local ui = RUI()
                    if ui and ui.document and ui.menu then
                        P("reader up", tries)
                        q(1.2, function()
                            local idx = tabIndex(ui.menu, "appbar.menu")
                            P("reader menu tab", tostring(idx))
                            ui.menu:onShowMenu(idx)
                        end)
                        q(1.0, function()
                            local library = findAnywhere("^Library$") or findAnywhere("Library")
                            local details = findAnywhere("Book details")
                            P("reader menu", tostring(library), tostring(details), "stack", stackLine())
                            if not (library and details) then
                                state.ok = false
                                P("FAIL reader menu is missing Library or Book details")
                            end
                            shot("12-reader-menu-library")
                            nextFn()
                        end)
                        return
                    end
                    if tries > 40 then
                        state.ok = false
                        P("FAIL reader did not open")
                        nextFn()
                        return
                    end
                    again(1, waitReader)
                    end
                    q(1, waitReader)
                end)
            end,
        }
        local i = 0
        local function advance()
            i = i + 1
            if i > #steps_left then done() return end
            P("GALLERY", i)
            steps_left[i](advance)
        end
        advance()
    end)
end

--- File-browser gestures on the library home (#9). The top-edge downward
-- swipe is KOReader's own file-browser menu zone (there is no "top edge
-- down" entry in the gesture manager). The two-finger swipe is bound in
-- the file-browser gesture profile to "Rotate by 90° CW". The plugin's
-- Controls panel is off, which is how this was reported.
local function gesturesScenario()
    whenLibrary(function()
        local Geom = require("ui/geometry")
        local Event = require("ui/event")
        local time = require("ui/time")

        local function send(ev)
            UIManager:sendEvent(Event:new("Gesture", ev))
        end
        local function point(x, y)
            return Geom:new{ x = x, y = y, w = 0, h = 0 }
        end
        local function swipe(dir, x, y, dx, dy)
            send{
                ges = "swipe", direction = dir,
                pos = point(x, y), start_pos = point(x, y),
                end_pos = point(x + (dx or 0), y + (dy or 0)),
                time = time.now(),
            }
        end
        local function twoFinger(dir, x, y)
            local dx = dir == "east" and 180 or dir == "west" and -180 or 0
            local dy = dir == "south" and 180 or dir == "north" and -180 or 0
            send{
                ges = "two_finger_swipe", direction = dir,
                pos = point(x, y),
                end_pos = point(x + dx, y + dy),
                time = time.now(),
            }
        end
        local function menuOpen()
            local fm = FM()
            return fm and fm.menu and fm.menu.menu_container ~= nil
        end
        local function closeMenu()
            local fm = FM()
            if fm and fm.menu and fm.menu.onCloseFileManagerMenu then
                fm.menu:onCloseFileManagerMenu()
            end
        end
        local function controlsOpen()
            local l = lib()
            return l and l.shared and l.shared.controls ~= nil
        end
        local function layout(tag)
            local view = V()
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            local d = view and view.dimen
            local sc = view and view.scrubber
            local sd = sc and (sc.hitRect and sc:hitRect() or sc.dimen)
            P("LAYOUT", tag,
                "screen", sw .. "x" .. sh,
                "view", d and (d.w .. "x" .. d.h) or "nil",
                "page", view and view.page, "pages", view and view.pages,
                "sort", view and view.sort,
                "strip", sd and (sd.x .. "," .. sd.y .. " " .. sd.w .. "x" .. sd.h) or "no",
                "shelf", view and view._shelf_expanded and "expanded" or "normal",
                "menu", menuOpen() and "open" or "closed",
                "controls", controlsOpen() and "open" or "closed")
            return view, sw, sh, d
        end
        local function expectMenu(tag)
            if menuOpen() and not controlsOpen() then
                P("PASS", tag, "file browser menu")
                return true
            end
            state.ok = false
            P("FAIL", tag, "menu", menuOpen() and "open" or "closed",
                "controls", controlsOpen() and "open" or "closed", "stack", stackLine())
            return false
        end
        local portrait_w, portrait_h
        local function expectLayout(tag, want_w, want_h)
            local view, sw, sh, d = layout(tag)
            if not (view and d and sw == want_w and sh == want_h and d.w == sw and d.h == sh) then
                state.ok = false
                P("FAIL", tag, "layout", "wanted", want_w .. "x" .. want_h)
            else
                P("PASS", tag, "layout", sw .. "x" .. sh)
            end
            if view and view.sort == "title" and (view.pages or 0) > 1 and not view.scrubber then
                state.ok = false
                P("FAIL", tag, "A-Z strip missing")
            end
            return view
        end

        q(0.3, function()
            dismissNotices()
            local l = lib()
            l.settings.controls_panel = false
            if l.saveSettings then l:saveSettings() end
            local fm = FM()
            fm.menu.activation_menu = "swipe_tap"
            local g = fm.gestures and fm.gestures.gestures
            if not g then
                state.ok = false
                P("FAIL no file browser gesture profile")
                return
            end
            -- Gesture manager, file browser profile: two-finger swipe rotates.
            for _, id in ipairs({
                "two_finger_swipe_east", "two_finger_swipe_west",
                "two_finger_swipe_north", "two_finger_swipe_south",
            }) do
                g[id] = { iterate_rotation = true }
            end
            local view = V()
            view:resort("title")
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            portrait_w, portrait_h = sw, sh
            P("configured", "controls_panel off", "activate_menu", fm.menu.activation_menu,
                "screen", sw .. "x" .. sh, "dpi", Screen:getDPI(),
                "two_finger", "iterate_rotation")
            if sw == 1072 and sh == 1448 then
                P("screen", "Paperwhite 4")
            end
            layout("portrait")
        end)
        q(0.4, function()
            dismissNotices()
            shot("01-portrait")
        end)
        q(0.2, function()
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            local y = math.max(8, math.floor(sh / 16))
            P("swipe", "top center", "south", math.floor(sw / 2), y, "band", math.floor(sh / 8))
            swipe("south", math.floor(sw / 2), y, 0, 160)
        end)
        q(0.5, function()
            expectMenu("top center")
            shot("02-top-swipe-center")
            closeMenu()
        end)
        q(0.3, function()
            local view = V()
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            local band = math.floor(sh / 8)
            local x, y = sw - 16, math.max(8, math.floor(sh / 16))
            local sc = view.scrubber
            if sc and sc.hitRect then
                local r = sc:hitRect()
                P("strip hit", r.x, r.y, r.w, r.h, "band", band)
                if r.y < band then
                    x = math.floor(r.x + r.w / 2)
                    y = math.min(band - 2, math.max(r.y + 2, 4))
                end
            end
            P("swipe", "top right", "south", x, y)
            swipe("south", x, y, 0, 160)
        end)
        q(0.5, function()
            expectMenu("top right")
            shot("03-top-swipe-corner")
            closeMenu()
        end)
        q(0.3, function()
            local view = V()
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            -- Left edge, below the menu band: brightness, not the top menu.
            local edge_y = math.floor(sh * 0.55)
            swipe("south", 16, edge_y, 0, 140)
            if menuOpen() then
                state.ok = false
                P("FAIL left-edge swipe opened the menu")
                closeMenu()
            else
                P("PASS left edge stayed out of the menu")
            end
            -- The seeded library hides Continue reading. Turn it on so the
            -- shelf gesture has a strip to hide, then swipe up below it.
            view:setShowContinue(true)
            view = V()
            local n = view.continue_books and #view.continue_books or 0
            local y = math.max((view.body_y or 0) + 40, math.floor(sh * 0.72))
            P("shelf before", "page", view.page, "continue", n, "body_y", view.body_y, "y", y)
            swipe("north", math.floor(sw / 2), y, 0, -220)
            P("shelf", V()._shelf_expanded and "expanded" or "normal",
                "continue", V().continue_books and #V().continue_books or 0)
            if not V()._shelf_expanded then
                state.ok = false
                P("FAIL shelf did not expand")
            else
                P("PASS shelf expand")
            end
        end)
        q(0.4, function()
            dismissNotices()
            shot("04-shelf-expanded")
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            swipe("south", math.floor(sw / 2), math.floor(sh * 0.72), 0, 200)
            if menuOpen() then
                state.ok = false
                P("FAIL a mid-screen downward swipe opened the menu")
                closeMenu()
            end
            if V()._shelf_expanded then
                state.ok = false
                P("FAIL shelf did not restore")
            else
                P("PASS shelf restore")
            end
            local view = V()
            local before = view.page
            swipe("west", math.floor(sw / 2), math.floor(sh / 2), -200, 0)
            P("page turn", before, "->", V().page)
            if V().page ~= before + 1 then
                state.ok = false
                P("FAIL page turn")
            else
                P("PASS page turn")
            end
            swipe("east", math.floor(sw / 2), math.floor(sh / 2), 200, 0)
            if V().page ~= before then
                state.ok = false
                P("FAIL page turn back", V().page)
            end
            -- A letter-strip swipe below the menu band stays a letter jump.
            local sc = V().scrubber
            if sc and sc.hitRect then
                local r = sc:hitRect()
                local y = math.floor(r.y + r.h * 0.7)
                local page = V().page
                swipe("south", math.floor(r.x + r.w / 2), y, 0, 80)
                if menuOpen() then
                    state.ok = false
                    P("FAIL strip swipe opened the menu")
                    closeMenu()
                else
                    P("PASS strip kept its swipe", "page", page, "->", V().page)
                end
            end
        end)
        q(0.3, function()
            local view = V()
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            local x, y = math.floor(sw / 2), math.floor(sh / 2)
            local sc = view.scrubber
            if sc and sc.hitRect then
                local r = sc:hitRect()
                x = math.floor(r.x + r.w / 2)
                y = math.floor(r.y + r.h / 2)
            end
            P("two-finger", "east", "on strip", x, y, "page", view.page)
            twoFinger("east", x, y)
        end)
        q(0.8, function()
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            P("after two-finger", "screen", sw .. "x" .. sh)
            local view = expectLayout("landscape", portrait_h, portrait_w)
            shot("05-after-rotate")
            if view and sw == portrait_h and sh == portrait_w then
                local before = view.page
                swipe("west", math.floor(sw / 2), math.floor(sh / 2), -160, 0)
                local now = V()
                P("landscape page", before, "->", now and now.page)
                if not (now and now.page == before + 1) then
                    state.ok = false
                    P("FAIL landscape page turn")
                else
                    P("PASS landscape page turn")
                end
            end
        end)
        q(0.3, function()
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            P("two-finger", "east", "back", math.floor(sw / 2), math.floor(sh / 2))
            twoFinger("east", math.floor(sw / 2), math.floor(sh / 2))
        end)
        q(0.8, function()
            expectLayout("portrait again", portrait_w, portrait_h)
            shot("06-portrait-again")
        end)
    end)
end

local ORDER = {
    "widgets", "accordion", "recently", "shelf", "bubble", "menu",
    "filters", "brightness", "startwith", "gallery",
}

local function runList(list, on_done)
    local i = 0
    local function nextJob()
        i = i + 1
        if i > #list then
            P("jobs finished")
            if on_done then on_done() end
            return
        end
        local name = list[i]
        P("JOB", name)
        local ok, err = pcall(jobs[name], nextJob)
        if not ok then
            state.ok = false
            P("JOB ERROR", name, err)
            nextJob()
        end
    end
    nextJob()
end

local function solo(name)
    return function()
        whenLibrary(function() runList({ name }) end)
    end
end

local scenarios = { readme = function()
    whenLibrary(function() runList(ORDER) end)
end }
for _, name in ipairs(ORDER) do scenarios[name] = solo(name) end
scenarios.controls = solo("controls")
scenarios.gestures = gesturesScenario
return scenarios
end
