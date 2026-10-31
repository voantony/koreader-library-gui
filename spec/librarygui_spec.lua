-- The look: cover placement, progress bars, the "Rounded keyboard in search"
-- setting and restyle, and a result tap hiding the keyboard.
local Core = require("librarycore")
local Keyboard = require("librarykeyboard")

describe("Core.coverPlacement", function()
    it("fills and centre-crops a cover close to 2:3", function()
        local p = Core.coverPlacement(600, 960, 200, 300)
        eq(p.mode, "fill")
        eq(p.w, 200); eq(p.h, 320)
        eq(p.crop_x, 0); eq(p.crop_y, 10)
    end)
    it("fits (no crop) a cover far from 2:3", function()
        local p = Core.coverPlacement(1000, 500, 200, 300)
        eq(p.mode, "fit")
        eq(p.w, 200); eq(p.h, 100)
        eq(p.crop_x, 0); eq(p.crop_y, 0)
    end)
    it("survives zero sizes", function()
        local p = Core.coverPlacement(0, 0, 200, 300)
        eq(p.w >= 1 and p.h >= 1, true)
    end)
end)

describe("Core.barFill", function()
    it("is empty for unread and full for finished", function()
        eq(Core.barFill(100, 0), 0)
        eq(Core.barFill(100, nil), 0)
        eq(Core.barFill(100, 1.2), 100)
    end)
    it("shows a started book at least min_w wide", function()
        eq(Core.barFill(100, 0.01, 4), 4)
        eq(Core.barFill(100, 0.43, 4), 43)
    end)
end)

describe("Core.roundedKeyboard", function()
    it("is on by default and off only when turned off", function()
        eq(Core.roundedKeyboard(nil), true)
        eq(Core.roundedKeyboard({}), true)
        eq(Core.roundedKeyboard({ rounded_keyboard = true }), true)
        eq(Core.roundedKeyboard({ rounded_keyboard = false }), false)
    end)
end)

local WHITE, GREY = { "white" }, { "grey" }
local st = Keyboard.style(function(n) return n end, setmetatable({}, { __index = function(_, k) return k end }))

local function key(bg)
    return { { bordersize = 0, background = bg, { dimen = { w = 50, h = 60 } } } }
end

describe("librarykeyboard.styleKey", function()
    it("rounds the key and keeps its outer size", function()
        local k = key(WHITE)
        eq(Keyboard.styleKey(k, st, WHITE), true)
        local b = st.border
        eq(k[1].radius, st.radius)
        eq(k[1].bordersize, b)
        eq(k[1][1].dimen.w, 50 - 2 * b)
        eq(k[1][1].dimen.h, 60 - 2 * b)
        eq(k[1].background, st.key_bg)
    end)
    it("does not shrink a key twice", function()
        local k = key(WHITE)
        Keyboard.styleKey(k, st, WHITE)
        Keyboard.styleKey(k, st, WHITE)
        eq(k[1][1].dimen.w, 50 - 2 * st.border)
    end)
    it("keeps an active modifier marked, and handles a missing background", function()
        local k = key(GREY)
        Keyboard.styleKey(k, st, WHITE)
        eq(k[1].background, st.active_bg)
        local n = key(nil)
        eq(Keyboard.styleKey(n, st, WHITE), true)
        eq(n[1].background, st.key_bg)
    end)
    it("leaves an unknown shape alone", function()
        local k = { { bordersize = 0 } }
        eq(Keyboard.styleKey(k, st, WHITE), false)
        eq(k[1].radius, nil)
        eq(Keyboard.styleKey({}, st, WHITE), false)
    end)
    it("press feedback: a fast (A2) black press, then a normal refresh on release", function()
        local k = key(WHITE)
        Keyboard.styleKey(k, st, WHITE)
        local calls = {}
        k.update_keyboard = function(_, hold, a2) table.insert(calls, { hold = hold, a2 = a2 }) end
        k:invert(true)
        eq(k._library_pressed, true)
        eq(k[1].background, st.key_bg, "the key's own colour stays; the press is painted over it")
        k:invert(false)
        eq(k._library_pressed, nil)
        eq(#calls, 2)
        eq(calls[1].a2, true)
        eq(calls[2].a2, false)
    end)
    it("paints the press as an inverted area clear of the rounded corners", function()
        local painted, inverted = 0, {}
        local k = { { bordersize = 0, background = WHITE, { dimen = { w = 50, h = 60 } },
            getSize = function() return { w = 50, h = 60 } end,
            paintTo = function() painted = painted + 1 end } }
        Keyboard.styleKey(k, st, WHITE)
        local bb = { invertRect = function(_, x, y, w, h) table.insert(inverted, { x, y, w, h }) end }
        k[1]:paintTo(bb, 100, 200)
        eq(painted, 1); eq(#inverted, 0, "not pressed: nothing inverted")
        k.update_keyboard = function() end
        k:invert(true)
        k[1]:paintTo(bb, 100, 200)
        eq(painted, 2); eq(#inverted, 1)
        local inset = st.border + math.ceil(st.radius * 0.3)
        same(inverted[1], { 100 + inset, 200 + inset, 50 - 2 * inset, 60 - 2 * inset })
    end)
end)

describe("librarykeyboard.restyle", function()
    it("styles every key and the board", function()
        local board = { bordersize = 1 }
        local kb = { layout = { { key(WHITE), key(WHITE) }, { key(GREY) } }, { board } }
        eq(Keyboard.restyle(kb, st, WHITE), true)
        eq(kb.layout[2][1][1].radius, st.radius)
        eq(board.background, st.board_bg)
    end)
    it("changes nothing when the keys are not recognised", function()
        local board = { bordersize = 1 }
        local odd = { "?" }
        local kb = { layout = { { odd, key(WHITE) } }, { board } }
        eq(Keyboard.restyle(kb, st, WHITE), false)
        eq(kb.layout[1][2][1].radius, nil)
        eq(board.background, nil)
        eq(Keyboard.restyle({}, st, WHITE), false)
    end)
end)

describe("librarykeyboard.canEchoDirect", function()
    local kb, view = { "keyboard" }, { "view" }
    local at = { x = 0, y = 0 }
    local stack = { { widget = { "fm" } }, { widget = view }, { widget = kb } }
    it("paints a keystroke on its own when the screen is as the Library left it", function()
        eq(Keyboard.canEchoDirect(stack, {}, kb, view, at), true)
    end)
    it("takes the usual path otherwise", function()
        eq(Keyboard.canEchoDirect(stack, { [view] = true }, kb, view, at), false, "Library already waiting to repaint")
        eq(Keyboard.canEchoDirect(stack, { [kb] = true }, kb, view, at), false, "keyboard waiting to repaint")
        eq(Keyboard.canEchoDirect(stack, {}, kb, view, nil), false, "text box never painted")
        local over = { { widget = view }, { widget = kb }, { widget = { "menu" } } }
        eq(Keyboard.canEchoDirect(over, {}, kb, view, at), false, "something over the keyboard")
        eq(Keyboard.canEchoDirect({ { widget = kb } }, {}, kb, view, at), false)
        eq(Keyboard.canEchoDirect(nil, {}, kb, view, at), false)
        eq(Keyboard.canEchoDirect(stack, nil, kb, view, at), false)
        eq(Keyboard.canEchoDirect(stack, {}, nil, view, at), false)
    end)
end)
