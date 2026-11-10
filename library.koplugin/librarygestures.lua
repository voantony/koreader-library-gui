--[[--
Gesture bindings for the Library home screen.

Each slot is "filebrowser" (do what the file browser does, the default),
"nothing", or an action id from Gestures.ACTIONS. Missing and unknown
values are "filebrowser", so a library saved before this menu behaves as
it does now.

No UI here. The menu and the view both call these functions.
]]

local Core = require("librarycore")

local Gestures = {}

Gestures.FILEBROWSER = "filebrowser"
Gestures.NOTHING = "nothing"

-- Actions the Library can run itself. "filebrowser" is not one of these:
-- it leaves the gesture to KOReader's file-browser profile.
Gestures.ACTIONS = {
    { id = "show_menu", title = "Open KOReader menu" },
    { id = "rotate_cw", title = "Rotate by 90° clockwise" },
    { id = "rotate_ccw", title = "Rotate by 90° counterclockwise" },
    { id = "toggle_orientation", title = "Toggle orientation" },
    { id = "brightness", title = "Brightness" },
    { id = "warmth", title = "Warmth" },
    { id = "open_book", title = "Open current book" },
    { id = "library_menu", title = "Library menu" },
    { id = "controls", title = "Controls panel" },
    { id = "page_next", title = "Next page" },
    { id = "page_prev", title = "Previous page" },
}

-- How the menu is grouped. A slot stands alone; a group opens its slots.
Gestures.MENU = {
    { slot = "top_down" },
    { group = "two", slots = { "two_east", "two_west", "two_north", "two_south", "two_diagonal" } },
    { group = "edge", slots = { "left_edge", "right_edge", "top_side", "bottom_side" } },
    { group = "tap", slots = { "tap_tl", "tap_tr", "tap_bl", "tap_br" } },
    { group = "hold", slots = { "hold_tl", "hold_tr", "hold_bl", "hold_br" } },
    { slot = "other" },
    { manager = true },
}

local SLOT = {
    top_down = true,
    two_east = true, two_west = true, two_north = true, two_south = true, two_diagonal = true,
    left_edge = true, right_edge = true, top_side = true, bottom_side = true,
    tap_tl = true, tap_tr = true, tap_bl = true, tap_br = true,
    hold_tl = true, hold_tr = true, hold_bl = true, hold_br = true,
    other = true,
}

local ACTION = {}
for _, action in ipairs(Gestures.ACTIONS) do ACTION[action.id] = action end

function Gestures.knownSlot(id)
    return SLOT[id] == true
end

function Gestures.knownAction(id)
    return ACTION[id] ~= nil
end

function Gestures.actionTitle(id)
    local action = ACTION[id]
    return action and action.title or nil
end

--- "filebrowser", "nothing", or an action id. Anything else is filebrowser.
function Gestures.choice(settings, slot)
    if not Gestures.knownSlot(slot) then return Gestures.FILEBROWSER end
    local saved = type(settings) == "table" and settings.gestures
    local value = type(saved) == "table" and saved[slot] or nil
    if value == nil or value == Gestures.FILEBROWSER then return Gestures.FILEBROWSER end
    if value == Gestures.NOTHING then return Gestures.NOTHING end
    if ACTION[value] then return value end
    return Gestures.FILEBROWSER
end

--- Remember a choice. "filebrowser" is stored by deleting the key, so the
-- saved table stays empty for anyone who never changes a gesture.
function Gestures.setChoice(settings, slot, choice)
    if type(settings) ~= "table" or not Gestures.knownSlot(slot) then return false end
    if choice ~= Gestures.FILEBROWSER and choice ~= Gestures.NOTHING and not ACTION[choice] then
        return false
    end
    if choice == Gestures.FILEBROWSER then
        if type(settings.gestures) == "table" then
            settings.gestures[slot] = nil
            if next(settings.gestures) == nil then settings.gestures = nil end
        end
        return true
    end
    if type(settings.gestures) ~= "table" then settings.gestures = {} end
    settings.gestures[slot] = choice
    return true
end

local TWO = {
    east = "two_east", west = "two_west", north = "two_north", south = "two_south",
}

local CORNER_NAME = { tl = "tl", tr = "tr", bl = "bl", br = "br" }

function Gestures.cornerName(x, y, w, h)
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    if not (x and y and w and h) or w <= 0 or h <= 0 then return nil end
    local col = (x < w / 8 and "l") or (x >= w * 7 / 8 and "r") or nil
    local row = (y <= h / 8 and "t") or (y >= h * 7 / 8 and "b") or nil
    if col and row then return row .. col end
end

--- Top menu band: the full-width top eighth, plus the taller centre half
-- KOReader uses for the menu (DTAP_ZONE_MENU and DTAP_ZONE_MENU_EXT).
function Gestures.inTopBand(x, y, w, h)
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    if not (x and y and w and h) or w <= 0 or h <= 0 or y < 0 then return false end
    if y <= h / 8 then return true end
    return y <= h / 5 and x >= w / 4 and x < w * 3 / 4
end

function Gestures.inBottomBand(y, h)
    y, h = tonumber(y), tonumber(h)
    if not (y and h) or h <= 0 then return false end
    return y >= h * 7 / 8
end

local MOVE = { pan = "pan", hold_pan = "hold_pan", pan_release = "pan_release", hold_release = "hold_release" }

--- Which saved slot this gesture belongs to, or nil when the Library's own
-- page turn, shelf swipe or letter strip should decide on their own.
function Gestures.slotFor(ev, w, h)
    if type(ev) ~= "table" then return nil end
    w, h = tonumber(w), tonumber(h)
    if not w or not h or w <= 0 or h <= 0 then return nil end
    local ges = ev.ges
    if ges == nil and ev.direction then ges = "swipe" end
    if ges == "two_finger_swipe" then
        return TWO[ev.direction] or (ev.direction and "two_diagonal" or nil)
    end
    if ges == "multiswipe" or ges == "pinch" or ges == "spread" or ges == "rotate" then
        return "other"
    end
    local pos = ev.pos or ev.start_pos
    if ges == "swipe" and ev.direction == "south" and pos and Gestures.inTopBand(pos.x, pos.y, w, h) then
        return "top_down"
    end
    if (ges == "swipe" or MOVE[ges]) and pos then
        local vertical = ges ~= "swipe" or ev.direction == "north" or ev.direction == "south"
        if vertical then
            local edge = Core.edgeStrip(pos.x, w)
            if edge == "left" then return "left_edge" end
            if edge == "right" then return "right_edge" end
        end
        if ges == "swipe" and (ev.direction == "east" or ev.direction == "west") then
            if Gestures.inTopBand(pos.x, pos.y, w, h) then return "top_side" end
            if Gestures.inBottomBand(pos.y, h) then return "bottom_side" end
        end
    end
    if pos and (ges == "tap" or ges == "hold" or ges == "double_tap") then
        local corner = Gestures.cornerName(pos.x, pos.y, w, h)
        if corner and CORNER_NAME[corner] then
            -- A double-tap in a corner is the same binding as the hold.
            local kind = ges == "tap" and "tap_" or "hold_"
            return kind .. corner
        end
    end
end

return Gestures
