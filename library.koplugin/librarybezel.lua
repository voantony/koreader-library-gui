--[[--
Status bar above the bezel: the pure part. No KOReader modules here, so the
specs can load it; main.lua reads the device and the footer and applies it.

On the Kindle Colorsoft the panel runs a few pixels under the bezel, so
KOReader's status bar, which sits 1 unit above the bottom edge by default,
is partly hidden. We lift it once by raising KOReader's own
"Status bar > Configure items > Bottom margin" setting, and only while that
setting is still at KOReader's default: a value someone chose is left alone.
--]]

local M = {}

M.DEFAULT = 1   -- KOReader's default "Bottom margin" (unscaled)
M.LIFTED = 6    -- what we raise it to (≈ 11 px on the Colorsoft's 300 dpi screen)

-- Devices whose screen runs under the bezel at the bottom.
M.MODELS = { KindleColorSoft = true }

function M.affected(model)
    return M.MODELS[model] == true
end

--- What to do when a book opens.
-- s: { model =, enabled = (our setting, nil = on), current = (footer's
-- container_bottom_padding, nil = default), prev = (value saved when we lifted
-- it before, nil = never) }.
-- Returns the new bottom margin, or nil to leave it alone.
function M.plan(s)
    if s.enabled == false or s.prev ~= nil then return nil end
    if not M.affected(s.model) then return nil end
    local current = tonumber(s.current) or M.DEFAULT
    if current ~= M.DEFAULT then return nil end
    return M.LIFTED
end

--- What to restore when the setting is turned off: the value from before we
-- lifted it, but only if the margin is still the one we set.
function M.restore(current, prev)
    if prev == nil then return nil end
    if (tonumber(current) or M.DEFAULT) ~= M.LIFTED then return nil end
    return prev
end

return M
