-- Controls panel buttons: Light (front light on/off, keeps the level),
-- Refresh (one full flash, panel stays open), and which buttons a device
-- gets. No Sleep, Bluetooth, Airplane or Auto buttons.
local Core = require("librarycore")

local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

-- A KOReader-like powerd: the level survives the light being off.
local function fakePowerd(level, on)
    local p = { fl_min = 0, fl_max = 24, fl_intensity = level, is_fl_on = on, resume = nil }
    function p:isFrontlightOn() return self.is_fl_on end
    function p:isFrontlightOff() return not self.is_fl_on end
    function p:frontlightIntensity() return self.is_fl_on and self.fl_intensity or 0 end
    function p:turnOffFrontlight() if not self.is_fl_on then return false end self.is_fl_on = false; return true end
    function p:turnOnFrontlight()
        if self.is_fl_on or self.fl_intensity == self.fl_min then return false end
        self.is_fl_on = true; return true
    end
    function p:toggleFrontlight() if self.is_fl_on then return self:turnOffFrontlight() end return self:turnOnFrontlight() end
    function p:setIntensity(v) self.fl_intensity = v; if v > self.fl_min then self.is_fl_on = true end end
    function p:updateResumeFrontlightState() self.resume = self.is_fl_on end
    return p
end

local function withControls(device, fn)
    local log = {}
    local UIManager = {
        setDirty = function(_, w, f) local mode, rect = f(); log[#log + 1] = { w = w, mode = mode, rect = rect } end,
        scheduleIn = function() end, unschedule = function() end, nextTick = function() end,
        close = function(_, w) log[#log + 1] = { closed = w } end,
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
        if name == "ui/network/manager" then return { isWifiOn = function() return true end } end
        return stub()
    end
    package.loaded.librarycontrols = nil
    local ok, err = pcall(function() fn(require("librarycontrols"), log) end)
    _G.require = old_require
    package.loaded.librarycontrols = nil
    if not ok then error(err, 0) end
end

local function device(caps)
    caps = caps or {}
    local d = { screen = stub() }
    for _, k in ipairs({ "hasFrontlight", "hasNaturalLight", "hasWifiToggle", "hasEinkScreen", "isAlwaysPortrait", "canSuspend" }) do
        local v = caps[k]; if v == nil then v = true end
        if k == "isAlwaysPortrait" and caps[k] == nil then v = false end
        d[k] = function() return v end
    end
    return d
end

local function panel(Controls, powerd)
    local p = setmetatable({ powerd = powerd, plugin = {} }, Controls)
    p.sliders = p:makeSliders()
    p.toggles = p:makeToggles()
    p.dimen = { x = 0, y = 0, w = 1264, h = 1680 }
    p.L = Core.controlsLayout(1264, 1680, #p.sliders, #p.toggles)
    return p
end

local function ids(p) local t = {}; for _, x in ipairs(p.toggles) do t[#t + 1] = x.id end; return t end
local function toggle(p, id) for _, t in ipairs(p.toggles) do if t.id == id then return t end end end

describe("Controls buttons", function()
    it("a Kindle-like device gets Light, Night, Refresh / Wi-Fi, Rotate, Cover sleep / Exit", function()
        withControls(device(), function(Controls)
            same(ids(panel(Controls, fakePowerd(8, true))), { "light", "night", "refresh", "wifi", "rotate", "cover_sleep", "exit" })
        end)
    end)
    it("hides what the device can't use", function()
        withControls(device{ hasFrontlight = false, hasWifiToggle = false, hasEinkScreen = false, isAlwaysPortrait = true },
            function(Controls)
                same(ids(panel(Controls, fakePowerd(0, false))), { "night", "cover_sleep", "exit" })
            end)
    end)
end)

describe("Light button", function()
    it("turns the light off and back on at the same level, slider in sync", function()
        withControls(device(), function(Controls, log)
            local pd = fakePowerd(9, true)
            local p = panel(Controls, pd)
            local light = toggle(p, "light")
            eq(light.on(), true); eq(light.sub(true), "On")
            eq(p.sliders[1].get(), 9)
            light.run()
            eq(pd.is_fl_on, false); eq(light.on(), false)
            eq(p.sliders[1].get(), 0, "slider shows off")
            eq(pd.fl_intensity, 9, "level kept")
            eq(pd.resume, false)
            light.run()
            eq(pd.is_fl_on, true)
            eq(p.sliders[1].get(), 9, "previous level restored")
            eq(pd.resume, true)
            eq(#log, 2, "one panel redraw per tap")
            eq(log[1].mode, "ui")
        end)
    end)
    it("comes back at a low level when there was no level to restore", function()
        withControls(device(), function(Controls)
            local pd = fakePowerd(0, false)
            local p = panel(Controls, pd)
            toggle(p, "light").run()
            eq(pd.is_fl_on, true)
            eq(pd.fl_intensity, 6)
        end)
    end)
end)

describe("Refresh button", function()
    it("does one full-screen flash and keeps the panel open", function()
        withControls(device(), function(Controls, log)
            local p = panel(Controls, fakePowerd(8, true))
            toggle(p, "refresh").run()
            eq(#log, 1)
            eq(log[1].mode, "full")
            eq(log[1].rect, nil, "whole screen")
            eq(p.closed, nil)
        end)
    end)
end)

describe("Exit button", function()
    it("closes the panel and asks before quitting", function()
        withControls(device(), function(Controls, log)
            local p = panel(Controls, fakePowerd(8, true))
            local asked = 0
            p.plugin = { confirmExit = function() asked = asked + 1 end }
            p.toggles = p:makeToggles()
            local t = toggle(p, "exit")
            eq(t.label, "Exit")
            eq(t.icon, "exit")
            eq(t.on(), false)
            t.run()
            eq(p.closed, true)
            eq(asked, 0, "asks after the panel has gone")
        end)
    end)
end)
