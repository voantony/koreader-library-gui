--[[--
E-ink ghosting: the pure part. No KOReader modules here, so the specs can
load it; libraryview.lua picks the refresh mode and counts page turns.

On colour e-ink a "ui" refresh leaves cover ghosts. A "flashui" refresh
(the flashing UI refresh KOReader uses when a panel closes) clears them
without the cost of a full-screen "full" flash.

Page turns flash every N pages, matching KOReader's own full-refresh
setting (default 6). Switching tabs, opening a shelf, or closing an
overlay over the cover grid always flashes once. Nothing flashes on
LCD or the emulator, or when the setting is "never".

Closing a menu is separate from that. A regional "flashui" leaves
colour-layer ghosts (menu text, NEW badges) on a Kaleido panel, and it
does not cover the A–Z strip when the menu stops short of the edge.
That refresh is a full-screen "full", whatever the page-turn setting is.
--]]

local M = {}

M.FLASH = "flashui"
M.UI = "ui"
-- Menu and dialog close. "full" outranks the dialog's own regional
-- "flashui" or "ui" when KOReader merges the two refreshes, and it
-- clears the colour layer. The rectangle is the whole screen.
M.OVERLAY_CLOSE = "full"

-- ☰ choices
M.ALWAYS = "always"     -- flash on every Library page turn
M.SETTING = "setting"   -- every N pages (KOReader's full_refresh_count)
M.NEVER = "never"
M.DEFAULT = M.SETTING
M.DEFAULT_EVERY = 6     -- KOReader's DEFAULT_FULL_REFRESH_COUNT
M.CHOICES = { M.ALWAYS, M.SETTING, M.NEVER }

function M.choice(stored)
    if stored == M.ALWAYS or stored == M.NEVER then return stored end
    return M.SETTING
end

function M.everyN(full_refresh_count)
    local n = tonumber(full_refresh_count)
    if n == nil then return M.DEFAULT_EVERY end
    return n
end

function M.isCoverGrid(view_mode)
    return view_mode == nil or view_mode == "grid" or view_mode == "covers"
end

--- Refresh to request after a menu or dialog over the Library has closed.
-- Always the whole screen, mode "full", including when the page-turn
-- setting is "never" and when the shelf is a list. w, h are the screen.
-- Returns mode, rect.
function M.overlayClose(w, h)
    w = tonumber(w) or 0
    h = tonumber(h) or 0
    return M.OVERLAY_CLOSE, { x = 0, y = 0, w = w, h = h }
end

--- Which refresh to use, and the page-turn count to keep.
-- s: { eink =, choice = (nil = setting), reason = ("page"|"tab"|"shelf"|"overlay"|nil),
--      turns = (page turns since the last flash), every = (N from KOReader),
--      cover_grid = (overlay is over the cover grid) }.
-- Returns mode, new_turns.
function M.decide(s)
    s = s or {}
    local turns = tonumber(s.turns) or 0
    if not s.eink then return M.UI, turns end
    local choice = M.choice(s.choice)
    if choice == M.NEVER then return M.UI, turns end
    if s.reason == "tab" or s.reason == "shelf" then
        return M.FLASH, 0
    end
    if s.reason == "overlay" then
        if s.cover_grid then return M.FLASH, 0 end
        return M.UI, turns
    end
    if s.reason == "page" then
        if choice == M.ALWAYS then return M.FLASH, 0 end
        local every = M.everyN(s.every)
        if every <= 0 then return M.UI, 0 end
        turns = turns + 1
        if turns >= every then return M.FLASH, 0 end
        return M.UI, turns
    end
    return M.UI, turns
end

return M
