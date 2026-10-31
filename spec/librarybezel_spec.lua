-- Kindle Colorsoft: the screen runs a few pixels under the bezel, so the
-- reader's status bar is lifted once by raising KOReader's own bottom margin.
local Bezel = require("librarybezel")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o) o = o or {}; return setmetatable(o, self) end
    return base
end

local function mainLib(model, stored_footer)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, libraryreadermenu = true, librarybezel = true,
        string = true, table = true, math = true }
    local saved_reader_settings = _G.G_reader_settings
    _G.G_reader_settings = {
        readSetting = function(_, k) if k == "footer" then return stored_footer end end,
        saveSetting = function() end,
    }
    _G.require = function(name)
        if name == "device" then
            return { model = model, hasFrontlight = function() return true end,
                isTouchDevice = function() return true end,
                screen = { scaleBySize = function(_, v) return v * 2 end } }
        end
        if name == "ui/widget/container/widgetcontainer" then return cls() end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then return { template = function(s) return s end } end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/main.lua")
    _G.require = old_require
    if not ok then _G.G_reader_settings = saved_reader_settings; error(mod, 0) end
    return mod
end

local function reader(Library, settings, footer_settings)
    local refreshed = {}
    local footer = { settings = footer_settings, bottom_padding = 2 }
    function footer:refreshFooter(a, b) refreshed[#refreshed + 1] = { a, b } end
    local lib = setmetatable({ settings = settings, ui = { document = {}, view = { footer = footer } },
        saveSettings = function() end }, { __index = Library })
    return lib, footer, refreshed
end

describe("Status bar above the bezel: pure parts", function()
    it("lifts only on the Colorsoft, only from KOReader's default", function()
        eq(Bezel.plan{ model = "KindleColorSoft", current = 1 }, Bezel.LIFTED)
        eq(Bezel.plan{ model = "KindleColorSoft", current = nil }, Bezel.LIFTED, "unset counts as default")
        eq(Bezel.plan{ model = "KindlePaperWhite5", current = 1 }, nil, "other Kindles untouched")
        eq(Bezel.plan{ model = "KindleScribeColorSoft", current = 1 }, nil)
        eq(Bezel.plan{ model = nil, current = 1 }, nil)
    end)
    it("leaves a margin someone chose, and never lifts twice", function()
        eq(Bezel.plan{ model = "KindleColorSoft", current = 4 }, nil)
        eq(Bezel.plan{ model = "KindleColorSoft", current = 0 }, nil)
        eq(Bezel.plan{ model = "KindleColorSoft", current = 1, prev = 1 }, nil, "already done once")
        eq(Bezel.plan{ model = "KindleColorSoft", current = 1, enabled = false }, nil, "setting off")
    end)
    it("restores the old margin only if ours is still in place", function()
        eq(Bezel.restore(Bezel.LIFTED, 1), 1)
        eq(Bezel.restore(9, 1), nil, "changed since: keep it")
        eq(Bezel.restore(Bezel.LIFTED, nil), nil, "we never lifted it")
    end)
    it("lifts by a few pixels, not a big jump", function()
        assert(Bezel.LIFTED > Bezel.DEFAULT and Bezel.LIFTED <= 10)
    end)
end)

describe("Status bar above the bezel: in the reader", function()
    it("raises the bottom margin when a book opens on the Colorsoft, the way KOReader's spinner does", function()
        local Library = mainLib("KindleColorSoft")
        local fs = { container_bottom_padding = 1, container_height = 14 }
        local lib, footer, refreshed = reader(Library, { bezel_lift = true }, fs)
        lib:onReaderReady()
        eq(fs.container_bottom_padding, Bezel.LIFTED)
        eq(footer.bottom_padding, Bezel.LIFTED * 2, "scaled like KOReader")
        eq(fs.container_height, 14, "height untouched")
        eq(#refreshed, 1); eq(refreshed[1][1], true); eq(refreshed[1][2], true)
        eq(lib.settings.bezel_prev, 1)
        lib:onReaderReady()
        eq(#refreshed, 1, "second book: nothing more")
    end)
    it("does nothing on other devices or when the margin was customised", function()
        local Library = mainLib("KindlePaperWhite5")
        local fs = { container_bottom_padding = 1 }
        local lib, _, refreshed = reader(Library, { bezel_lift = true }, fs)
        lib:onReaderReady()
        eq(fs.container_bottom_padding, 1); eq(#refreshed, 0); eq(lib.settings.bezel_prev, nil)
        Library = mainLib("KindleColorSoft")
        fs = { container_bottom_padding = 3 }
        lib, _, refreshed = reader(Library, { bezel_lift = true }, fs)
        lib:onReaderReady()
        eq(fs.container_bottom_padding, 3); eq(#refreshed, 0)
    end)
    it("menu toggle off puts the old margin back; on lifts again", function()
        local Library = mainLib("KindleColorSoft")
        local fs = { container_bottom_padding = 1 }
        local lib, _, refreshed = reader(Library, { bezel_lift = true }, fs)
        lib:onReaderReady()
        local item = lib:bezelLiftMenuItem()
        eq(item.enabled_func(), true)
        eq(item.checked_func(), true)
        item.callback()
        eq(lib.settings.bezel_lift, false); eq(fs.container_bottom_padding, 1); eq(lib.settings.bezel_prev, nil)
        eq(item.checked_func(), false)
        item.callback()
        eq(fs.container_bottom_padding, Bezel.LIFTED); eq(#refreshed, 3)
    end)
    it("menu item is greyed out on other devices", function()
        local Library = mainLib("KindleOasis3")
        local lib = reader(Library, {}, { container_bottom_padding = 1 })
        eq(lib:bezelLiftMenuItem().enabled_func(), false)
    end)
end)
