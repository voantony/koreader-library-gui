--[[--
"Rounded keyboard in search": a softer on-screen keyboard for the Library's
search bar only.

KOReader's keyboard draws square keys edge to edge on a grey board. This
module makes a subclass of KOReader's VirtualKeyboard that, after building
its keys the usual way, restyles them: rounded keys with a thin border, wider
gaps between keys and a lighter board, like the Kindle, Kobo or phone
keyboards. Nothing global is changed: KOReader's own classes are untouched,
and only the keyboard made for the Library's search bar (see
SearchInput:initKeyboard in libraryview.lua) is a RoundedKeyboard. Every
other text box in KOReader keeps the stock keyboard.

Key presses, popups (hold for accents), layouts and the globe key all work
as before: they are KOReader's own code. If a future KOReader changes how the
keys are built so that the restyle does not recognise them, the keys are left
as KOReader drew them.
--]]

local M = {}

--- Colours and sizes. Kept here so the look is in one place; `px(n)` scales
-- by the screen's dpi.
function M.style(px, colors)
    return {
        key_padding = px(5),   -- gap between keys
        board_padding = px(3), -- around the keys
        radius = px(6),
        border = math.max(1, px(0.7)),
        key_border = colors.GRAY_9,
        key_bg = colors.WHITE,
        active_bg = colors.LIGHT_GRAY, -- Shift/Sym on
        pressed_bg = colors.GRAY_9,
        focus_bg = colors.GRAY_D,  -- D-pad focus
        focus_border = colors.BLACK,
        board_bg = colors.GRAY_E,
        board_border = colors.GRAY_B,
    }
end

--- Restyle one key, in place. `key` is a VirtualKey: its [1] is the key's
-- FrameContainer, whose [1] is a CenterContainer sized to the inside of the
-- frame. Returns false (and changes nothing) for anything else.
function M.styleKey(key, st, white)
    if type(key) ~= "table" or key._library_styled then return key and key._library_styled or false end
    local frame = key[1]
    local inner = type(frame) == "table" and frame[1]
    if type(frame) ~= "table" or type(frame.bordersize) ~= "number"
            or type(inner) ~= "table" or type(inner.dimen) ~= "table"
            or type(inner.dimen.w) ~= "number" or type(inner.dimen.h) ~= "number" then
        return false
    end
    -- the frame grows by the border: shrink the inside so the key keeps its size
    local grow = st.border - frame.bordersize
    if inner.dimen.w - 2 * grow < 1 or inner.dimen.h - 2 * grow < 1 then return false end
    inner.dimen.w = inner.dimen.w - 2 * grow
    inner.dimen.h = inner.dimen.h - 2 * grow
    frame.bordersize = st.border
    frame.color = st.key_border
    frame.radius = st.radius
    -- KOReader marks active modifiers (Shift, Sym…) with a grey background
    -- (type() first: comparing a colour to nil raises in KOReader's colour code)
    local bg = frame.background
    bg = (type(bg) == "nil" or (type(white) ~= "nil" and bg == white)) and st.key_bg or st.active_bg
    frame.background = bg
    key._library_bg = bg
    -- Feedback that follows the rounded shape (KOReader's own press and focus
    -- marks are a square inner border). Set on this key only.
    key.invert = function(k, invert, hold)
        k[1].inner_bordersize = 0
        k[1].background = invert and st.pressed_bg or k._library_bg
        k:update_keyboard(hold, true)
    end
    key.onFocus = function(k)
        k[1].background, k[1].color = st.focus_bg, st.focus_border
    end
    key.onUnfocus = function(k)
        k[1].background, k[1].color = k._library_bg, st.key_border
    end
    key._library_styled = true
    return true
end

--- Restyle a built keyboard: its keys (`kb.layout`, rows of VirtualKeys) and
-- its board (`kb[1][1]`, the FrameContainer under the keys). All or nothing
-- for the keys: if the first one is not recognised, nothing is changed.
function M.restyle(kb, st, white)
    local rows = kb.layout
    if type(rows) ~= "table" or type(rows[1]) ~= "table" or not rows[1][1] then return false end
    if not M.styleKey(rows[1][1], st, white) then return false end
    for _, row in ipairs(rows) do
        for _, key in ipairs(row) do M.styleKey(key, st, white) end
    end
    local board = type(kb[1]) == "table" and kb[1][1]
    if type(board) == "table" and type(board.bordersize) == "number" then
        board.background = st.board_bg
        board.color = st.board_border
    end
    return true
end

--- Is `row` a row of digit keys (the number row on top of most layouts)?
-- A key is a table of layers; layer 2 (lower case) holds "1" or a popup
-- table whose [1] is "1".
function M.isNumberRow(row)
    if type(row) ~= "table" or #row < 8 then return false end
    local digits = 0
    for _, key in ipairs(row) do
        local c = type(key) == "table" and key[2]
        if type(c) == "table" then c = c[1] end
        if type(c) == "string" and c:match("^%d$") then digits = digits + 1 end
    end
    return digits >= 8
end

--- The keyboard's rows without the number row on top (a new list; the
-- layout module's own table is shared, so it is never changed). Rows are
-- returned as they are when the top row is not a number row. The symbols
-- key still reaches numbers (and the period key's popup the apostrophe).
function M.withoutNumberRow(keys)
    if type(keys) ~= "table" or #keys < 3 or not M.isNumberRow(keys[1]) then return keys end
    local out = {}
    for i = 2, #keys do out[#out + 1] = keys[i] end
    return out
end

local RoundedKeyboard

--- The RoundedKeyboard class (made on first use), or nil when KOReader's
-- VirtualKeyboard is not available.
function M.class()
    if RoundedKeyboard then return RoundedKeyboard end
    local ok, VirtualKeyboard = pcall(require, "ui/widget/virtualkeyboard")
    if not ok or type(VirtualKeyboard) ~= "table" or not VirtualKeyboard.extend then return nil end
    local Blitbuffer = require("ffi/blitbuffer")
    local Screen = require("device").screen
    local st = M.style(function(n) return Screen:scaleBySize(n) end, {
        WHITE = Blitbuffer.COLOR_WHITE, BLACK = Blitbuffer.COLOR_BLACK,
        GRAY_9 = Blitbuffer.COLOR_GRAY_9, GRAY_B = Blitbuffer.COLOR_GRAY_B,
        GRAY_D = Blitbuffer.COLOR_GRAY_D, GRAY_E = Blitbuffer.COLOR_GRAY_E,
        LIGHT_GRAY = Blitbuffer.COLOR_LIGHT_GRAY,
    })
    RoundedKeyboard = VirtualKeyboard:extend{
        key_padding = st.key_padding,
        padding = st.board_padding,
        library_rounded = true,
    }
    function RoundedKeyboard:addKeys()
        -- Letters only (Authors search): the same board height over one row
        -- fewer, so the letter keys are taller.
        if self.hide_number_row then self.KEYS = M.withoutNumberRow(self.KEYS) end
        VirtualKeyboard.addKeys(self)
        local done, err = pcall(M.restyle, self, st, Blitbuffer.COLOR_WHITE)
        if not done then require("logger").warn("Library: rounded keyboard:", err) end
    end
    return RoundedKeyboard
end

return M
