--[[--
Forwarding gestures the Library view does not use to the file browser
underneath (issue #8).

KOReader's UIManager:sendEvent only ever delivers an event to the TOPMOST
widget in the window stack; an event the top widget does not consume is
simply dropped, it does not cascade to the widgets underneath (see
frontend/ui/uimanager.lua sendEvent: only the top widget, its active
widgets, and is_always_active widgets below are offered the event).
So while the Library view is showing, the file browser's touch zones
never see anything -- including LiveLight's edge slides (brightness on
the left edge, warmth on the right) and KOReader's own edge swipes and
menu gestures -- unless the view forwards what it does not keep.

This mirrors Bookshelf's lib/bookshelf_gesture_zones.lua: walk the live
FileManager's ordered touch zones (the host's own, plus every child
module's -- menu-open zones can live on modules other than fm.menu) and
fire the first one that matches, for zones the file browser owns
("filemanager_*") or the reader configured in the Gestures plugin. The
file chooser itself is skipped: its row-tap/row-hold zones cover the body
area, so a tap in a gap of the Library's own layout could otherwise open
an unintended file.
]]

local Zones = {}

-- Shared zone walk: the host's own _ordered_touch_zones plus every child
-- module's. `allowed(id)` is the per-host id filter; exclude_child skips
-- one specific child.
local function tryHostZones(ev, host, allowed, exclude_child)
    if not host then return false end
    local zone_lists = { host._ordered_touch_zones }
    for _, child in ipairs(host) do
        if child ~= exclude_child
           and type(child) == "table"
           and child._ordered_touch_zones then
            zone_lists[#zone_lists + 1] = child._ordered_touch_zones
        end
    end
    for _, zones in ipairs(zone_lists) do
        for _, tzone in ipairs(zones or {}) do
            local id = tzone.def and tzone.def.id
            if id and allowed(id)
               and tzone.gs_range:match(ev)
               and tzone.handler(ev) then
                return true
            end
        end
    end
    return false
end

-- tryFMZones(ev, fm) -> boolean
--   ev  raw gesture event (ev.pos, ev.ges, etc.)
--   fm  FileManager.instance, or nil
-- Allowlist: stock "filemanager_*" zones or a user-configured
-- Gestures-plugin gesture (fm.gestures.gestures[id]).
function Zones.tryFMZones(ev, fm)
    if not fm then return false end
    local user_gestures = (fm.gestures and fm.gestures.gestures) or {}
    return tryHostZones(ev, fm, function(id)
        return id:find("^filemanager_") or user_gestures[id]
    end, fm.file_chooser)
end

--- The live host under the Library: always the FileManager (leaving a book
-- for the Library recreates it first). Returns nil when there is none.
-- Same package.loaded pattern as currentLibrary in main.lua.
function Zones.liveHost()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance or nil
end

-- tryLiveZones(ev) -> boolean
-- Offer a gesture the Library did not keep to the file browser's zones.
function Zones.tryLiveZones(ev)
    if not ev then return false end
    return Zones.tryFMZones(ev, Zones.liveHost())
end

return Zones
