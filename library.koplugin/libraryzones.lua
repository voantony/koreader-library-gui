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

A user-configured Gestures-plugin gesture fires its action as a separate
Dispatcher event, sent to the top widget -- the Library view -- which does
not handle it. That half of the circuit is closed by issue #9
(forwardToLive below): non-gesture events the view does not handle are
forwarded to the live host, with the broadcast tag (stamped by the
installer in main.lua) keeping broadcast events from being delivered
twice. LiveLight needs none of this: it drives the frontlight directly.
]]

local logger = require("logger")

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
            if id and allowed(id) and tzone.gs_range and tzone.handler then
                -- A LiveLight (or other zone) error must not take the Library down.
                local ok_match, matched = pcall(tzone.gs_range.match, tzone.gs_range, ev)
                if not ok_match then
                    logger.warn("Library: zone", id, "match failed:", matched)
                elseif matched then
                    local ok_call, consumed = pcall(tzone.handler, ev)
                    if not ok_call then
                        logger.warn("Library: zone", id, "failed:", consumed)
                    elseif consumed then
                        return true
                    end
                end
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

-- tryUserFirst(ev, fm) -> boolean
-- A swipe the Library would otherwise turn into a page turn, but the reader
-- gave their own action in KOReader's Gestures: swipes along the top and
-- bottom edges. Those run BEFORE the Library's own use of the gesture
-- (Bookshelf issue 476). Only a configured one fires: the zone's own range
-- and direction checks still apply, so a mid-screen swipe falls through to
-- the page turn untouched.
local USER_FIRST_SWIPE = {
    one_finger_swipe_top_edge_left = true, one_finger_swipe_top_edge_right = true,
    one_finger_swipe_bottom_edge_left = true, one_finger_swipe_bottom_edge_right = true,
}
function Zones.tryUserFirst(ev, fm)
    if not (fm and ev) or ev.ges ~= "swipe" then return false end
    local user_gestures = (fm.gestures and fm.gestures.gestures) or {}
    return tryHostZones(ev, fm, function(id)
        return USER_FIRST_SWIPE[id] and user_gestures[id] ~= nil
    end, fm.file_chooser)
end

-- ── Forwarding Dispatcher actions to the host (issue #9) ───────────────────
-- A gesture the file browser's zones fire (a Gestures-plugin binding, a
-- corner tap) runs its action as a separate Dispatcher event, sent to the
-- top widget -- the Library view -- which does not handle it. So the zone
-- fires and nothing happens. Forwarding what the view does not keep to the
-- live host closes that half of the circuit, mirroring Bookshelf's
-- forwardToLive. Guards, in the same order as there:
--   * lifecycle events targeting the view itself are never forwarded;
--   * broadcast events already reach the host directly, so forwarding them
--     again would run toggle actions twice (the tag is stamped by the
--     installer in main.lua);
--   * a forwarded event must never be able to tear the host down (a swipe
--     that reaches an open file-browser menu closes it, whose close
--     callback quits KOReader), so the host's onClose is neutralised for
--     the synchronous dispatch -- except for the intentional Exit/Restart
--     actions, which need it intact. A gesture-carrying event can never
--     take that bypass.
local NEVER_FORWARD = {
    onCloseWidget   = true,
    onFlushSettings = true,
    onShow          = true,
    onClose         = true,
}
local ALLOW_TEARDOWN = {
    onExit    = true,
    onRestart = true,
}

local function carriesGesture(event)
    local args = event.args
    if type(args) ~= "table" then return false end
    for i = 1, 3 do
        local a = args[i]
        if type(a) == "table" and a.ges then return true end
    end
    return false
end

local function forwardToHost(host, event, self_widget)
    if NEVER_FORWARD[event.handler] then return false end
    if event._library_from_broadcast then return false end
    if not (host and host ~= self_widget) then return false end
    if ALLOW_TEARDOWN[event.handler] and not carriesGesture(event) then
        local ok, consumed = pcall(host.handleEvent, host, event)
        return (ok and consumed) and true or false
    end
    local saved_onClose = rawget(host, "onClose")
    host.onClose = function() return true end
    local ok, consumed = pcall(host.handleEvent, host, event)
    host.onClose = saved_onClose
    return (ok and consumed) and true or false
end

-- forwardToLive(event, self_widget) -> boolean
-- Hand a non-gesture event the view did not handle to the live host.
function Zones.forwardToLive(event, self_widget)
    return forwardToHost(Zones.liveHost(), event, self_widget)
end

return Zones
