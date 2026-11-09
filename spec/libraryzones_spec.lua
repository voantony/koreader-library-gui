-- Issue #8: gestures the Library view does not keep are forwarded to the
-- file browser's touch zones (LiveLight's edge slides, KOReader's own
-- edge swipes and menu gestures). The zone walk mirrors Bookshelf's
-- lib/bookshelf_gesture_zones.lua.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { string = true, table = true, math = true }
    _G.require = function(name)
        if extra[name] ~= nil then return extra[name] end
        if real[name] then return old_require(name) end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/" .. file)
    _G.require = old_require
    if not ok then error(mod, 0) end
    return mod
end

local Zones = load("libraryzones.lua", {})

local function fakeZone(id, match, handler)
    return {
        def = { id = id },
        gs_range = { match = function(_, ev) return match(ev) end },
        handler = handler,
    }
end

local function fakeFM(zones, opts)
    opts = opts or {}
    local fm = {
        _ordered_touch_zones = zones or {},
        gestures = { gestures = opts.user_gestures or {} },
        file_chooser = opts.file_chooser,
    }
    for _, child in ipairs(opts.children or {}) do
        fm[#fm + 1] = child
    end
    return fm
end

describe("Library zones forwarding", function()
    it("fires a matching filemanager_* zone and passes the raw gesture", function()
        local seen
        local fm = fakeFM({ fakeZone("filemanager_livelight_pan",
            function() return true end,
            function(ev) seen = ev; return true end) })
        local ev = { ges = "pan", pos = { x = 10, y = 500 } }
        eq(Zones.tryFMZones(ev, fm), true)
        eq(seen, ev)
    end)

    it("skips a zone whose range does not match and tries the next", function()
        local fired = {}
        local fm = fakeFM({
            fakeZone("filemanager_livelight_pan",
                function() return false end,
                function() fired[#fired + 1] = "livelight"; return true end),
            fakeZone("filemanager_swipe",
                function() return true end,
                function() fired[#fired + 1] = "fm"; return true end),
        })
        eq(Zones.tryFMZones({ ges = "pan" }, fm), true)
        eq(#fired, 1)
        eq(fired[1], "fm")
    end)

    it("does not fire a zone outside the filemanager_* allowlist", function()
        local fired = false
        local fm = fakeFM({ fakeZone("my_custom_zone",
            function() return true end,
            function() fired = true; return true end) })
        eq(Zones.tryFMZones({ ges = "tap" }, fm), false)
        eq(fired, false)
    end)

    it("fires a user-configured Gestures-plugin zone without the prefix", function()
        local fired = false
        local fm = fakeFM({ fakeZone("one_finger_swipe_left_edge_down",
            function() return true end,
            function() fired = true; return true end) },
            { user_gestures = { one_finger_swipe_left_edge_down = "DecreaseBrightness" } })
        eq(Zones.tryFMZones({ ges = "swipe" }, fm), true)
        eq(fired, true)
    end)

    it("does not fire an unconfigured Gestures-plugin zone", function()
        local fired = false
        local fm = fakeFM({ fakeZone("one_finger_swipe_left_edge_down",
            function() return true end,
            function() fired = true; return true end) })
        eq(Zones.tryFMZones({ ges = "swipe" }, fm), false)
        eq(fired, false)
    end)

    it("skips the file chooser's zones even when they match", function()
        local fired = false
        local chooser = { _ordered_touch_zones = { fakeZone("filemanager_tap",
            function() return true end,
            function() fired = true; return true end) } }
        local fm = fakeFM({}, { file_chooser = chooser })
        fm[#fm + 1] = chooser
        eq(Zones.tryFMZones({ ges = "tap" }, fm), false)
        eq(fired, false)
    end)

    it("walks child modules' zones too", function()
        local fired = false
        local menu = { _ordered_touch_zones = { fakeZone("filemanager_menu_tap",
            function() return true end,
            function() fired = true; return true end) } }
        local fm = fakeFM({}, { children = { menu } })
        eq(Zones.tryFMZones({ ges = "tap" }, fm), true)
        eq(fired, true)
    end)

    it("returns false when nothing matches and when there is no host", function()
        eq(Zones.tryFMZones({ ges = "pan" }, fakeFM({})), false)
        eq(Zones.tryFMZones({ ges = "pan" }, nil), false)
        eq(Zones.tryLiveZones(nil), false)
    end)

    it("tryLiveZones offers the gesture to the live FileManager", function()
        local fired = false
        local fm = fakeFM({ fakeZone("filemanager_livelight_swipe",
            function() return true end,
            function() fired = true; return true end) })
        package.loaded["apps/filemanager/filemanager"] = { instance = fm }
        eq(Zones.tryLiveZones({ ges = "swipe" }), true)
        eq(fired, true)
        package.loaded["apps/filemanager/filemanager"] = nil
        eq(Zones.tryLiveZones({ ges = "swipe" }), false)
    end)
end)

