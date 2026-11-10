--- Clock and battery beside the search bar: the pure part.
-- No KOReader modules here, so the specs can require it.
--
-- Styles:
--   icon     bold time and a drawn battery (fill plus a bolt while charging)
--   compact  KOReader status-bar battery symbol and a percentage
--   bar      a smaller time and a thin gauge
--   plain    the original "12:59  ·  78%" line
--
-- Drawn marks are black and white only, so night mode can invert them.

local Status = {}

Status.DEFAULT = "icon"
Status.ORDER = { "icon", "compact", "bar", "plain" }

-- Same private-use glyphs as BasePowerD:getBatterySymbol in KOReader v2026.07.1.
-- Order of arguments there is (is_charged, is_charging, capacity).
Status.SYMBOL = {
    charged  = "\u{EDA3}",
    charging = "\u{E783}",
    p100 = "\u{E778}",
    p90  = "\u{E781}",
    p80  = "\u{E780}",
    p70  = "\u{E77F}",
    p60  = "\u{E77E}",
    p50  = "\u{E77D}",
    p40  = "\u{E77C}",
    p30  = "\u{E77B}",
    p20  = "\u{E77A}",
    p10  = "\u{E779}",
    empty = "\u{E782}",
}

-- Unscaled font sizes. KOReader scales them with the screen.
Status.FACE = {
    icon    = { font = "cfont",    size = 22, bold = true },
    compact = { font = "infofont", size = 16, bold = false },
    bar     = { font = "cfont",    size = 18, bold = false },
    plain   = { font = "cfont",    size = 20, bold = true },
}

-- Lightning bolt, normalized to the box. Concave, so it is filled per scanline.
Status.BOLT = {
    { 0.50, 0.04 },
    { 0.25, 0.45 },
    { 0.50, 0.45 },
    { 0.31, 0.96 },
    { 0.88, 0.41 },
    { 0.56, 0.41 },
    { 0.75, 0.04 },
}

local BANDS = {
    { 100, "p100" }, { 90, "p90" }, { 80, "p80" }, { 70, "p70" },
    { 60, "p60" }, { 50, "p50" }, { 40, "p40" }, { 30, "p30" },
    { 20, "p20" }, { 10, "p10" },
}

function Status.style(id)
    if id == "icon" or id == "compact" or id == "bar" or id == "plain" then
        return id
    end
    return Status.DEFAULT
end

function Status.styleOf(settings)
    return Status.style(settings and settings.status_style)
end

function Status.face(style)
    return Status.FACE[Status.style(style)]
end

--- 0..100, or nil. Same rounding as the plain "87%" label.
function Status.percent(capacity)
    if type(capacity) ~= "number" or capacity ~= capacity then return nil end
    local n = math.floor(capacity + 0.5)
    if n < 0 or n > 100 then return nil end
    return n
end

function Status.state(capacity, charging, charged)
    local n = Status.percent(capacity)
    if not n then return nil end
    return {
        percent = n,
        charging = charging and true or false,
        charged = charged and true or false,
    }
end

--- The glyph KOReader's status bar uses for this reading.
-- `charged` wins over `charging`, matching getBatterySymbol.
function Status.koreaderSymbol(percent, charging, charged)
    percent = Status.percent(percent) or 0
    if charged then return Status.SYMBOL.charged end
    if charging then return Status.SYMBOL.charging end
    for i = 1, #BANDS do
        if percent >= BANDS[i][1] then
            return Status.SYMBOL[BANDS[i][2]]
        end
    end
    return Status.SYMBOL.empty
end

--- "78%", the icons-mode footer text, without the clock.
function Status.compactText(percent, charging, charged)
    local n = Status.percent(percent)
    if not n then return nil end
    return Status.koreaderSymbol(n, charging, charged) .. n .. "%"
end

--- Every symbol plus "100%", so the slot can be reserved at the widest.
function Status.compactSamples()
    local seen, out = {}, {}
    local function add(sym)
        if seen[sym] then return end
        seen[sym] = true
        out[#out + 1] = sym .. "100%"
    end
    add(Status.SYMBOL.charged)
    add(Status.SYMBOL.charging)
    for i = 1, #BANDS do add(Status.SYMBOL[BANDS[i][2]]) end
    add(Status.SYMBOL.empty)
    return out
end

function Status.unit(u)
    u = tonumber(u) or 1
    if u ~= u or u < 1 then return 1 end
    return u
end

function Status.gap(unit)
    return math.max(6, math.floor(Status.unit(unit) * 8 + 0.5))
end

function Status.fillWidth(inner, percent)
    inner = math.floor(tonumber(inner) or 0)
    percent = Status.percent(percent) or 0
    if inner <= 0 or percent <= 0 then return 0 end
    if percent >= 100 then return inner end
    local fw = math.floor(inner * percent / 100 + 0.5)
    if fw < 1 then fw = 1 end
    if fw > inner then return inner end
    return fw
end

function Status.iconMetrics(unit)
    local u = Status.unit(unit)
    local stroke = math.max(1, math.floor(u + 0.5))
    if stroke > 3 then stroke = 3 end
    local h = math.max(14, math.floor(16 * u + 0.5))
    local w = math.max(26, math.floor(30 * u + 0.5))
    local nub_w = math.max(2, math.floor(3 * u + 0.5))
    local nub_h = math.max(4, math.floor(h * 0.36 + 0.5))
    if nub_h > h - 2 * stroke then nub_h = math.max(2, h - 2 * stroke) end
    local gap = 1
    local inner_x = stroke + gap
    local inner_y = stroke + gap
    local inner_w = w - 2 * inner_x
    local inner_h = h - 2 * inner_y
    if inner_w < 1 then inner_w = 1 end
    if inner_h < 1 then inner_h = 1 end
    return {
        stroke = stroke, w = w, h = h,
        nub_w = nub_w, nub_h = nub_h, gap = gap,
        inner_x = inner_x, inner_y = inner_y,
        inner_w = inner_w, inner_h = inner_h,
        total_w = w + nub_w, total_h = h,
    }
end

--- Pixel size of the bolt at this screen scale. Taller than it is wide.
function Status.boltBox(unit)
    local u = Status.unit(unit)
    local h = math.max(12, math.floor(11 * u + 0.5))
    if h > 24 then h = 24 end
    local w = math.max(8, math.floor(h * 0.72 + 0.5))
    return w, h
end

function Status.barMetrics(unit)
    local u = Status.unit(unit)
    local h = math.max(3, math.floor(4 * u + 0.5))
    if h > 8 then h = 8 end
    if h < 3 then h = 3 end
    local w = math.max(28, math.floor(36 * u + 0.5))
    local stroke = 1
    local bolt_w, bolt_h = Status.boltBox(unit)
    local bolt_gap = math.max(3, math.floor(4 * u + 0.5))
    return {
        w = w, h = h, stroke = stroke,
        inner_w = math.max(1, w - 2 * stroke),
        inner_h = math.max(1, h - 2 * stroke),
        bolt_w = bolt_w, bolt_h = bolt_h, bolt_gap = bolt_gap,
        total_w = w + bolt_gap + bolt_w,
        total_h = math.max(h, bolt_h),
    }
end

function Status.markSize(kind, unit)
    if kind == "bar" then
        local m = Status.barMetrics(unit)
        return m.total_w, m.total_h
    end
    local m = Status.iconMetrics(unit)
    return m.total_w, m.total_h
end

local function rect(ops, x, y, w, h, color, role)
    if w > 0 and h > 0 then
        ops[#ops + 1] = { x = x, y = y, w = w, h = h, color = color, role = role }
    end
end

--- Bolt ink inside a box at (ox, oy). White body, black halo, clipped to the box.
local function boltOps(ox, oy, bw, bh)
    if bw < 5 or bh < 7 then return {} end
    local pts = Status.BOLT
    local inside = {}
    local function set(y, x)
        local row = inside[y]
        if not row then row = {}; inside[y] = row end
        row[x] = true
    end
    for y = 0, bh - 1 do
        local sy = (y + 0.5) / bh
        local xs = {}
        for i = 1, #pts do
            local a = pts[i]
            local b = pts[(i % #pts) + 1]
            local y0, y1 = a[2], b[2]
            if (y0 <= sy and sy < y1) or (y1 <= sy and sy < y0) then
                local t = (sy - y0) / (y1 - y0)
                xs[#xs + 1] = (a[1] + t * (b[1] - a[1])) * bw
            end
        end
        table.sort(xs)
        local i = 1
        while i + 1 <= #xs do
            local x0 = math.floor(xs[i] + 0.5)
            local x1 = math.floor(xs[i + 1] + 0.5)
            if x0 > x1 then x0, x1 = x1, x0 end
            for x = x0, x1 - 1 do
                if x >= 0 and x < bw then set(y, x) end
            end
            i = i + 2
        end
    end
    local function on(x, y)
        return inside[y] and inside[y][x] or false
    end
    local ink = {}
    for y = 0, bh - 1 do
        for x = 0, bw - 1 do
            if on(x, y) then
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local nx, ny = x + dx, y + dy
                        if nx >= 0 and ny >= 0 and nx < bw and ny < bh and not on(nx, ny) then
                            local row = ink[ny]
                            if not row then row = {}; ink[ny] = row end
                            if not row[nx] then row[nx] = "black" end
                        end
                    end
                end
            end
        end
    end
    for y = 0, bh - 1 do
        for x = 0, bw - 1 do
            if on(x, y) then
                local row = ink[y]
                if not row then row = {}; ink[y] = row end
                row[x] = "white"
            end
        end
    end
    local ops = {}
    for y = 0, bh - 1 do
        local row = ink[y]
        if row then
            local x = 0
            while x < bw do
                local c = row[x]
                if not c then
                    x = x + 1
                else
                    local x2 = x + 1
                    while x2 < bw and row[x2] == c do x2 = x2 + 1 end
                    rect(ops, ox + x, oy + y, x2 - x, 1, c, "bolt")
                    x = x2
                end
            end
        end
    end
    return ops
end

function Status.iconOps(percent, charging, unit)
    local m = Status.iconMetrics(unit)
    percent = Status.percent(percent) or 0
    local ops = {}
    rect(ops, 0, 0, m.w, m.h, "black", "shell")
    rect(ops, m.stroke, m.stroke, m.w - 2 * m.stroke, m.h - 2 * m.stroke, "white", "well")
    local nub_y = math.floor((m.h - m.nub_h) / 2)
    rect(ops, m.w, nub_y, m.nub_w, m.nub_h, "black", "nub")
    local fw = Status.fillWidth(m.inner_w, percent)
    rect(ops, m.inner_x, m.inner_y, fw, m.inner_h, "black", "fill")
    if charging then
        local bw, bh = Status.boltBox(unit)
        if bw > m.inner_w then bw = m.inner_w end
        if bh > m.inner_h then bh = m.inner_h end
        local bx = m.inner_x + math.floor((m.inner_w - bw) / 2)
        local by = m.inner_y + math.floor((m.inner_h - bh) / 2)
        local bolt = boltOps(bx, by, bw, bh)
        for i = 1, #bolt do ops[#ops + 1] = bolt[i] end
    end
    return ops, m.total_w, m.total_h
end

function Status.barOps(percent, charging, unit)
    local m = Status.barMetrics(unit)
    percent = Status.percent(percent) or 0
    local ops = {}
    local bar_y = math.floor((m.total_h - m.h) / 2)
    rect(ops, 0, bar_y, m.w, m.h, "black", "shell")
    rect(ops, m.stroke, bar_y + m.stroke, m.inner_w, m.inner_h, "white", "well")
    local fw = Status.fillWidth(m.inner_w, percent)
    rect(ops, m.stroke, bar_y + m.stroke, fw, m.inner_h, "black", "fill")
    if charging then
        local bx = m.w + m.bolt_gap
        local by = math.floor((m.total_h - m.bolt_h) / 2)
        local bolt = boltOps(bx, by, m.bolt_w, m.bolt_h)
        for i = 1, #bolt do ops[#ops + 1] = bolt[i] end
    end
    return ops, m.total_w, m.total_h
end

function Status.markOps(kind, percent, charging, unit)
    if kind == "bar" then return Status.barOps(percent, charging, unit) end
    return Status.iconOps(percent, charging, unit)
end

return Status
