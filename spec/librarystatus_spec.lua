-- Clock and battery styles: geometry, KOReader's battery symbols, the default.
local Status = require("librarystatus")

local function role(ops, name)
    local found = {}
    for i = 1, #ops do
        if ops[i].role == name then found[#found + 1] = ops[i] end
    end
    return found
end

local function onlyBlackWhite(ops)
    for i = 1, #ops do
        if ops[i].color ~= "black" and ops[i].color ~= "white" then return false end
    end
    return true
end

describe("Status style", function()
    it("defaults to the battery icon and keeps plain as a choice", function()
        eq(Status.DEFAULT, "icon")
        eq(Status.style(nil), "icon")
        eq(Status.style("nope"), "icon")
        eq(Status.styleOf(nil), "icon")
        eq(Status.styleOf({}), "icon")
        eq(Status.style("plain"), "plain")
        eq(Status.style("compact"), "compact")
        eq(Status.style("bar"), "icon", "a saved thin bar is the battery icon")
        eq(Status.styleOf({ status_style = "bar" }), "icon")
        eq(Status.styleOf({ status_style = "plain" }), "plain")
        eq(Status.styleOf({ status_style = false }), "icon")
    end)

    it("draws the status bar at least as large as the battery-icon clock", function()
        local icon = Status.face("icon")
        local compact = Status.face("compact")
        eq(compact.size >= icon.size, true)
        eq(compact.bold, true)
        eq(compact.font, "infofont", "the battery symbol lives in the icon font")
    end)
end)

describe("KOReader battery symbol", function()
    it("uses the same bands as the status bar, and charging replaces the level", function()
        eq(Status.koreaderSymbol(100, false, false), Status.SYMBOL.p100)
        eq(Status.koreaderSymbol(90, false, false), Status.SYMBOL.p90)
        eq(Status.koreaderSymbol(89, false, false), Status.SYMBOL.p80)
        eq(Status.koreaderSymbol(80, false, false), Status.SYMBOL.p80)
        eq(Status.koreaderSymbol(70, false, false), Status.SYMBOL.p70)
        eq(Status.koreaderSymbol(60, false, false), Status.SYMBOL.p60)
        eq(Status.koreaderSymbol(50, false, false), Status.SYMBOL.p50)
        eq(Status.koreaderSymbol(40, false, false), Status.SYMBOL.p40)
        eq(Status.koreaderSymbol(30, false, false), Status.SYMBOL.p30)
        eq(Status.koreaderSymbol(20, false, false), Status.SYMBOL.p20)
        eq(Status.koreaderSymbol(10, false, false), Status.SYMBOL.p10)
        eq(Status.koreaderSymbol(9, false, false), Status.SYMBOL.empty)
        eq(Status.koreaderSymbol(0, false, false), Status.SYMBOL.empty)
        eq(Status.koreaderSymbol(62, true, false), Status.SYMBOL.charging)
        eq(Status.koreaderSymbol(100, true, true), Status.SYMBOL.charged)
        eq(Status.compactText(78, false, false), Status.SYMBOL.p70 .. "78%")
        eq(Status.compactText(8, true, false), Status.SYMBOL.charging .. "8%")
        eq(Status.compactText(nil, false, false), nil)
        eq(#Status.compactSamples() >= 4, true)
    end)
end)

describe("Battery icon", function()
    it("fills with the charge, stays black and white, and adds a bolt when charging", function()
        local m_w, m_h = Status.markSize("icon", 1)
        local empty = Status.iconOps(0, false, 1)
        local half = Status.iconOps(50, false, 1)
        local full = Status.iconOps(100, false, 1)
        local low = Status.iconOps(8, false, 1)
        local charging = Status.iconOps(62, true, 1)
        eq(#role(empty, "fill"), 0)
        eq(#role(half, "shell"), 1)
        eq(#role(half, "well"), 1)
        eq(#role(half, "nub"), 1)
        local metrics = Status.iconMetrics(1)
        eq(role(half, "fill")[1].w, Status.fillWidth(metrics.inner_w, 50))
        eq(role(full, "fill")[1].w, metrics.inner_w)
        eq(role(low, "fill")[1].w >= 1, true)
        eq(role(low, "fill")[1].w < role(half, "fill")[1].w, true)
        eq(#role(half, "bolt"), 0)
        eq(#role(charging, "bolt") > 0, true)
        local saw_white = false
        for i = 1, #charging do
            if charging[i].role == "bolt" and charging[i].color == "white" then saw_white = true end
        end
        eq(saw_white, true)
        eq(onlyBlackWhite(charging), true)
        eq(onlyBlackWhite(full), true)
        eq(m_w, metrics.total_w)
        eq(m_h, metrics.total_h)
        -- the bolt stays inside the body
        for i = 1, #charging do
            local op = charging[i]
            if op.role == "bolt" then
                eq(op.x >= 0 and op.y >= 0, true)
                eq(op.x + op.w <= metrics.w, true)
                eq(op.y + op.h <= metrics.h, true)
            end
        end
    end)

    it("grows the fill and the body with the screen scale", function()
        local a = Status.iconMetrics(1)
        local b = Status.iconMetrics(2)
        eq(b.total_w > a.total_w, true)
        eq(b.total_h > a.total_h, true)
        eq(Status.fillWidth(a.inner_w, 1) >= 1, true)
        eq(Status.fillWidth(a.inner_w, 0), 0)
        eq(Status.fillWidth(a.inner_w, 100), a.inner_w)
        eq(Status.percent(87.6), 88)
        eq(Status.percent(-1), nil)
        eq(Status.percent(101), nil)
        eq(Status.state(78, true, false).charging, true)
        eq(Status.state("78", false, false), nil)
    end)
end)
