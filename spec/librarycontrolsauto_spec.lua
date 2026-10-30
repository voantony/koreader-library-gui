-- Controls panel Auto toggle: the Kindle's own auto-brightness switch
-- (com.lab126.powerd flAuto). lipc is stubbed; nothing here touches a device.
local Core = require("librarycore")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

-- A fake lipc handle: one int property, with a log of every call.
local function fakeHandle(value, opts)
    opts = opts or {}
    local h = { value = value, calls = {} }
    function h:get_int_property(svc, prop)
        self.calls[#self.calls + 1] = "get " .. svc .. " " .. prop
        if opts.get_fails then error("failed to access property") end
        return self.value
    end
    function h:set_int_property(svc, prop, v)
        self.calls[#self.calls + 1] = "set " .. svc .. " " .. prop .. " " .. v
        if opts.set_fails then error("failed to set") end
        if not opts.set_ignored then self.value = v end
    end
    return h
end

local function writes(h)
    local n = 0
    for _, c in ipairs(h.calls) do if c:match("^set") then n = n + 1 end end
    return n
end

-- Load librarycontrols with KOReader stubbed out. `device` overrides Device.
local function withControls(device, fn)
    local log = {}
    local UIManager = {
        setDirty = function(_, w, f) local mode, rect = f(); log[#log + 1] = { mode = mode, rect = rect } end,
        scheduleIn = function() end, unschedule = function() end, close = function() end,
    }
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    local old_require = require
    _G.require = function(name)
        if name == "librarycore" or name == "librarycontrols" then return old_require(name) end
        if name == "ui/widget/container/inputcontainer" then return base end
        if name == "ui/uimanager" then return UIManager end
        if name == "ui/geometry" then return { new = function(_, o) return o end } end
        if name == "gettext" then return function(s) return s end end
        if name == "device" then return device end
        return stub()
    end
    package.loaded.librarycontrols = nil
    local ok, err = pcall(function()
        local Controls = require("librarycontrols")
        fn(Controls, log)
    end)
    _G.require = old_require
    package.loaded.librarycontrols = nil
    if not ok then error(err, 0) end
end

local function kindle(is_kindle)
    return setmetatable({
        isKindle = function() return is_kindle end,
        hasFrontlight = function() return true end,
        hasNaturalLight = function() return false end,
    }, { __index = function() return stub() end })
end

-- A panel built by hand (no init), with a Kindle-ish powerd and a log of
-- light changes, so the order of writes can be checked.
local function panel(Controls, h, events)
    local p = setmetatable({}, Controls)
    p.powerd = {
        lipc_handle = h, fl_min = 0, fl_max = 24, intensity = 8,
        frontlightIntensity = function(self) return self.intensity end,
        setIntensity = function(self, v) events[#events + 1] = "intensity " .. v; self.intensity = v end,
        turnOffFrontlight = function(self) events[#events + 1] = "off"; self.intensity = 0 end,
        isFrontlightOff = function() return false end,
        turnOnFrontlight = function() end,
        updateResumeFrontlightState = function() end,
    }
    if h then
        local set = h.set_int_property
        h.set_int_property = function(self, ...) events[#events + 1] = "flAuto " .. select(3, ...); return set(self, ...) end
    end
    return p
end

local function finish(p)
    p.sliders = p:makeSliders()
    p.toggles = {}
    for _, id in ipairs(Core.controlsToggles({ auto_light = p.auto_on ~= nil, night = true })) do
        p.toggles[#p.toggles + 1] = { id = id }
    end
    p.dimen = { x = 0, y = 0, w = 1264, h = 1680 }
    p.L = Core.controlsLayout(1264, 1680, #p.sliders, #p.toggles)
    return p
end

describe("AutoLight", function()
    it("parses lipc-get-prop output", function()
        withControls(kindle(true), function(Controls)
            local A = Controls.AutoLight
            eq(A.parse("0\n"), false)
            eq(A.parse("1"), true)
            eq(A.parse(" 1 \n"), true)
            eq(A.parse(""), nil)
            eq(A.parse("com.lab126.powerd failed to access property"), nil)
            eq(A.parse(nil), nil)
        end)
    end)

    it("reads through KOReader's lipc handle", function()
        withControls(kindle(true), function(Controls)
            local A = Controls.AutoLight
            local h = fakeHandle(0)
            eq(A.get({ lipc_handle = h }), false)
            h.value = 1
            eq(A.get({ lipc_handle = h }), true)
            same(h.calls, { "get com.lab126.powerd flAuto", "get com.lab126.powerd flAuto" })
        end)
    end)

    it("falls back to lipc-get-prop when there's no handle or it errors", function()
        withControls(kindle(true), function(Controls)
            local A = Controls.AutoLight
            local cmds = {}
            A.sh = function(cmd) cmds[#cmds + 1] = cmd; return "1\n", true end
            eq(A.get({}), true)
            eq(A.get({ lipc_handle = fakeHandle(0, { get_fails = true }) }), true)
            same(cmds, { "lipc-get-prop com.lab126.powerd flAuto", "lipc-get-prop com.lab126.powerd flAuto" })
        end)
    end)

    it("reads nil when lipc-get-prop fails (so the toggle is hidden)", function()
        withControls(kindle(true), function(Controls)
            local A = Controls.AutoLight
            A.sh = function() return "failed to access property", false end
            eq(A.get({}), nil)
            eq(A.get(nil), nil)
            A.sh = function() return "garbage", true end
            eq(A.get({}), nil)
        end)
    end)

    it("sets 1 or 0 and returns the state read back", function()
        withControls(kindle(true), function(Controls)
            local A = Controls.AutoLight
            local h = fakeHandle(0)
            eq(A.set({ lipc_handle = h }, true), true)
            eq(h.value, 1)
            eq(A.set({ lipc_handle = h }, false), false)
            same(h.calls, { "set com.lab126.powerd flAuto 1", "get com.lab126.powerd flAuto",
                "set com.lab126.powerd flAuto 0", "get com.lab126.powerd flAuto" })
            -- the firmware ignores the write: we show what it really says
            local stuck = fakeHandle(0, { set_ignored = true })
            eq(A.set({ lipc_handle = stuck }, true), false)
        end)
    end)

    it("falls back to lipc-set-prop when the handle errors", function()
        withControls(kindle(true), function(Controls)
            local A = Controls.AutoLight
            local cmds = {}
            A.sh = function(cmd) cmds[#cmds + 1] = cmd; return "1", true end
            eq(A.set({ lipc_handle = fakeHandle(0, { set_fails = true, get_fails = true }) }, true), true)
            same(cmds, { "lipc-set-prop com.lab126.powerd flAuto 1", "lipc-get-prop com.lab126.powerd flAuto" })
        end)
    end)

    it("the real shell runner never throws and reports failure", function()
        withControls(kindle(true), function(Controls)
            local out, ok = Controls.AutoLight.sh("exit 3")
            eq(ok, false)
            out, ok = Controls.AutoLight.sh("echo 1")
            eq(ok, true)
            eq(Controls.AutoLight.parse(out), true)
        end)
    end)
end)

describe("Controls Auto toggle", function()
    it("comes first in the toggles only when flAuto can be read", function()
        same(Core.controlsToggles({ auto_light = true, wifi = true, night = true, sleep = true }),
            { "auto_light", "wifi", "night", "sleep" })
        same(Core.controlsToggles({ auto_light = false, wifi = true }), { "wifi" })
    end)

    it("reads on open and never writes", function()
        withControls(kindle(true), function(Controls)
            local h = fakeHandle(1)
            local p = panel(Controls, h, {})
            p:readAutoLight()
            eq(p.auto_on, true)
            eq(writes(h), 0)
            h.value = 0
            p:readAutoLight()
            eq(p.auto_on, false)
            eq(writes(h), 0)
        end)
    end)

    it("is hidden, and lipc never touched, on a non-Kindle", function()
        withControls(kindle(false), function(Controls)
            local h = fakeHandle(0)
            local p = panel(Controls, h, {})
            Controls.AutoLight.sh = function() error("should not run") end
            p:readAutoLight()
            eq(p.auto_on, nil)
            eq(#h.calls, 0)
            finish(p)
            for _, t in ipairs(p.toggles) do eq(t.id ~= "auto_light", true) end
        end)
    end)

    it("is hidden when the Kindle refuses the read", function()
        withControls(kindle(true), function(Controls)
            Controls.AutoLight.sh = function() return "failed to access property", false end
            local p = panel(Controls, fakeHandle(0, { get_fails = true }), {})
            p:readAutoLight()
            eq(p.auto_on, nil)
        end)
    end)

    it("a tap switches it and shows the state read back", function()
        withControls(kindle(true), function(Controls, log)
            local h = fakeHandle(0)
            local p = panel(Controls, h, {})
            p:readAutoLight(); finish(p)
            p:toggleAutoLight()
            eq(h.value, 1); eq(p.auto_on, true)
            p:toggleAutoLight()
            eq(h.value, 0); eq(p.auto_on, false)
            eq(#log, 2)
            -- a write the firmware ignores leaves it showing Off
            local stuck = fakeHandle(0, { set_ignored = true })
            local q = panel(Controls, stuck, {})
            q:readAutoLight(); finish(q)
            q:toggleAutoLight()
            eq(q.auto_on, false)
        end)
    end)

    it("moving brightness while Auto is on turns Auto off first, then sets the light", function()
        withControls(kindle(true), function(Controls, log)
            local events = {}
            local h = fakeHandle(1)
            local p = panel(Controls, h, events)
            p:readAutoLight(); finish(p)
            eq(p.auto_on, true)
            p:setSlider(1, 12, "drag")
            same(events, { "flAuto 0", "intensity 12" })
            eq(p.auto_on, false)
            -- the Auto toggle gets one "ui" redraw besides the slider row
            local ui = 0
            for _, e in ipairs(log) do if e.mode == "ui" then ui = ui + 1 end end
            eq(ui, 1)
            -- further moves don't write flAuto again
            p:setSlider(1, 14, "drag")
            p:onTap(nil, { pos = { x = p.L.sliders[1].plus.cx, y = p.L.sliders[1].plus.cy } })
            same(events, { "flAuto 0", "intensity 12", "intensity 14", "intensity 15" })
            eq(writes(h), 1)
        end)
    end)

    it("moving brightness with Auto off never writes flAuto", function()
        withControls(kindle(true), function(Controls)
            local events = {}
            local h = fakeHandle(0)
            local p = panel(Controls, h, events)
            p:readAutoLight(); finish(p)
            p:setSlider(1, 3)
            p:setSlider(1, 0)
            same(events, { "intensity 3", "off" })
            eq(writes(h), 0)
        end)
    end)

    it("a failing lipc never crashes the slider", function()
        withControls(kindle(true), function(Controls)
            local events = {}
            local p = panel(Controls, fakeHandle(1, { set_fails = true, get_fails = true }), events)
            Controls.AutoLight.sh = function() error("boom") end
            p.auto_on = true
            finish(p)
            p:setSlider(1, 5)
            eq(p.auto_on, false)
            eq(events[#events], "intensity 5")
        end)
    end)
end)
