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

describe("Library zones user-first", function()
    it("fires a configured top-edge swipe before the Library's page turn", function()
        local seen
        local fm = fakeFM({ fakeZone("one_finger_swipe_top_edge_right",
            function() return true end,
            function(ev) seen = ev; return true end) },
            { user_gestures = { one_finger_swipe_top_edge_right = "ShowMenu" } })
        local ev = { ges = "swipe", direction = "east", pos = { x = 600, y = 10 } }
        eq(Zones.tryUserFirst(ev, fm), true)
        eq(seen, ev)
    end)

    it("does not fire an unconfigured edge swipe", function()
        local fired = false
        local fm = fakeFM({ fakeZone("one_finger_swipe_top_edge_right",
            function() return true end,
            function() fired = true; return true end) })
        eq(Zones.tryUserFirst({ ges = "swipe", direction = "east" }, fm), false)
        eq(fired, false)
    end)

    it("does not fire a configured gesture outside the user-first set", function()
        local fired = false
        local fm = fakeFM({ fakeZone("one_finger_swipe_left_edge_down",
            function() return true end,
            function() fired = true; return true end) },
            { user_gestures = { one_finger_swipe_left_edge_down = "DecreaseBrightness" } })
        -- a left-edge swipe is LiveLight's / the full walk's, not user-first
        eq(Zones.tryUserFirst({ ges = "swipe", direction = "south" }, fm), false)
        eq(fired, false)
    end)

    it("only applies to swipes", function()
        local fm = fakeFM({}, { user_gestures = { one_finger_swipe_top_edge_right = "ShowMenu" } })
        eq(Zones.tryUserFirst({ ges = "tap" }, fm), false)
        eq(Zones.tryUserFirst({ ges = "swipe" }, nil), false)
    end)
end)

describe("Library zones action forwarding", function()
    local function fakeHost(result)
        local handled, closed = {}, 0
        local original_close = function() closed = closed + 1; return "real" end
        local host = {
            onClose = original_close,
            handleEvent = function(self, event)
                handled[#handled + 1] = event
                return result
            end,
        }
        return host, handled, function() return closed end, original_close
    end

    local function withHost(host)
        package.loaded["apps/filemanager/filemanager"] = { instance = host }
    end

    it("forwards an action the view did not handle to the live host", function()
        local host, handled = fakeHost(true)
        withHost(host)
        local event = { handler = "onShowMenu", args = {} }
        eq(Zones.forwardToLive(event, {}), true)
        eq(handled[1], event)
        package.loaded["apps/filemanager/filemanager"] = nil
    end)

    it("returns false when the host does not handle it or there is no host", function()
        local host, handled = fakeHost(false)
        withHost(host)
        eq(Zones.forwardToLive({ handler = "onShowMenu", args = {} }, {}), false)
        eq(#handled, 1)
        package.loaded["apps/filemanager/filemanager"] = nil
        eq(Zones.forwardToLive({ handler = "onShowMenu", args = {} }, {}), false)
    end)

    it("never forwards lifecycle events", function()
        local host, handled = fakeHost(true)
        withHost(host)
        for _, handler in ipairs({ "onCloseWidget", "onFlushSettings", "onShow", "onClose" }) do
            eq(Zones.forwardToLive({ handler = handler, args = {} }, {}), false, handler)
        end
        eq(#handled, 0)
        package.loaded["apps/filemanager/filemanager"] = nil
    end)

    it("never forwards a broadcast event", function()
        local host, handled = fakeHost(true)
        withHost(host)
        eq(Zones.forwardToLive({ handler = "onToggleNightMode", args = {}, _library_from_broadcast = true }, {}), false)
        eq(#handled, 0)
        package.loaded["apps/filemanager/filemanager"] = nil
    end)

    it("neutralises the host's onClose while forwarding, then restores it", function()
        local host, handled, closed, original_close = fakeHost(true)
        host.handleEvent = function(self, event)
            handled[#handled + 1] = event
            self:onClose()
            return true
        end
        withHost(host)
        eq(Zones.forwardToLive({ handler = "onShowMenu", args = {} }, {}), true)
        eq(closed(), 0, "the teardown did not run")
        eq(host.onClose, original_close, "restored afterwards")
        package.loaded["apps/filemanager/filemanager"] = nil
    end)

    it("lets an intentional exit keep the host's onClose", function()
        local host, handled, closed = fakeHost(true)
        host.handleEvent = function(self, event)
            handled[#handled + 1] = event
            self:onClose()
            return true
        end
        withHost(host)
        eq(Zones.forwardToLive({ handler = "onExit", args = {} }, {}), true)
        eq(closed(), 1, "an intentional exit still quits")
        package.loaded["apps/filemanager/filemanager"] = nil
    end)

    it("does not let a gesture-carrying event take the exit bypass", function()
        local host, handled, closed = fakeHost(true)
        host.handleEvent = function(self, event)
            handled[#handled + 1] = event
            self:onClose()
            return true
        end
        withHost(host)
        eq(Zones.forwardToLive({ handler = "onExit", args = { { ges = "swipe" } } }, {}), true)
        eq(closed(), 0, "a swipe that happens to be named onExit cannot quit")
        package.loaded["apps/filemanager/filemanager"] = nil
    end)

    it("survives a host error and still restores onClose", function()
        local host, handled, closed, original_close = fakeHost(true)
        host.handleEvent = function() error("boom") end
        withHost(host)
        eq(Zones.forwardToLive({ handler = "onShowMenu", args = {} }, {}), false)
        eq(host.onClose, original_close)
        package.loaded["apps/filemanager/filemanager"] = nil
    end)
end)
