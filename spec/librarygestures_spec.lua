-- Library home gestures are chosen per gesture. The default is the file
-- browser's own binding, which is what the home screen did before the menu.
local Gestures = require("librarygestures")

local W, H = 1072, 1448

local function ev(ges, direction, x, y)
    return { ges = ges, direction = direction, pos = { x = x, y = y } }
end

describe("gesture choices", function()
    it("defaults every slot to the file browser", function()
        eq(Gestures.choice(nil, "top_down"), "filebrowser")
        eq(Gestures.choice({}, "two_east"), "filebrowser")
        eq(Gestures.choice({ gestures = {} }, "left_edge"), "filebrowser")
        eq(Gestures.choice({ gestures = { top_down = "nope" } }, "top_down"), "filebrowser")
    end)

    it("stores nothing and an action, and forgets the file-browser default", function()
        local settings = {}
        eq(Gestures.setChoice(settings, "top_down", "nothing"), true)
        eq(Gestures.choice(settings, "top_down"), "nothing")
        eq(settings.gestures.top_down, "nothing")
        eq(Gestures.setChoice(settings, "two_east", "rotate_cw"), true)
        eq(Gestures.choice(settings, "two_east"), "rotate_cw")
        eq(Gestures.setChoice(settings, "top_down", "filebrowser"), true)
        eq(Gestures.choice(settings, "top_down"), "filebrowser")
        eq(settings.gestures.top_down, nil)
        eq(settings.gestures.two_east, "rotate_cw")
        eq(Gestures.setChoice(settings, "two_east", "filebrowser"), true)
        eq(settings.gestures, nil, "an untouched menu is not written")
    end)

    it("rejects an unknown slot or action", function()
        local settings = {}
        eq(Gestures.setChoice(settings, "page_turn", "nothing"), false)
        eq(Gestures.setChoice(settings, "top_down", "fly"), false)
        eq(settings.gestures, nil)
    end)
end)

describe("which gesture a touch is", function()
    it("calls a downward swipe in the top band the top swipe", function()
        eq(Gestures.slotFor(ev("swipe", "south", 536, 40), W, H), "top_down")
        eq(Gestures.slotFor(ev("swipe", "south", 536, 200), W, H), "top_down", "the taller centre of the band")
        eq(Gestures.slotFor(ev("swipe", "south", 536, 400), W, H), nil)
    end)

    it("tells two-finger directions apart, including a diagonal", function()
        eq(Gestures.slotFor(ev("two_finger_swipe", "east", 1035, 800), W, H), "two_east")
        eq(Gestures.slotFor(ev("two_finger_swipe", "west", 400, 700), W, H), "two_west")
        eq(Gestures.slotFor(ev("two_finger_swipe", "northeast", 400, 700), W, H), "two_diagonal")
    end)

    it("uses the side edges for brightness and warmth, not a page turn", function()
        eq(Gestures.slotFor(ev("swipe", "south", 16, 800), W, H), "left_edge")
        eq(Gestures.slotFor(ev("swipe", "north", 1060, 800), W, H), "right_edge")
        eq(Gestures.slotFor(ev("pan", nil, 16, 700), W, H), "left_edge")
        eq(Gestures.slotFor(ev("swipe", "west", 500, 800), W, H), nil, "a sideways swipe in the middle turns the page")
    end)

    it("keeps sideways swipes along the top and bottom as their own slots", function()
        eq(Gestures.slotFor(ev("swipe", "west", 500, 20), W, H), "top_side")
        eq(Gestures.slotFor(ev("swipe", "east", 500, 1400), W, H), "bottom_side")
    end)

    it("names corner taps and holds, and treats a double-tap as the hold", function()
        eq(Gestures.slotFor(ev("tap", nil, 20, 20), W, H), "tap_tl")
        eq(Gestures.slotFor(ev("hold", nil, 20, 1400), W, H), "hold_bl")
        eq(Gestures.slotFor(ev("double_tap", nil, 20, 1400), W, H), "hold_bl")
        eq(Gestures.slotFor(ev("tap", nil, 500, 800), W, H), nil)
    end)

    it("groups a multiswipe, pinch, spread and rotation with other gestures", function()
        eq(Gestures.slotFor({ ges = "multiswipe", pos = { x = 400, y = 400 } }, W, H), "other")
        eq(Gestures.slotFor({ ges = "pinch", pos = { x = 400, y = 400 } }, W, H), "other")
        eq(Gestures.slotFor({ ges = "spread" }, W, H), "other")
        eq(Gestures.slotFor({ ges = "rotate" }, W, H), "other")
    end)

    it("puts the top swipe ahead of the edge it also sits on", function()
        eq(Gestures.slotFor(ev("swipe", "south", 20, 30), W, H), "top_down")
        eq(Gestures.slotFor(ev("swipe", "south", 1050, 30), W, H), "top_down")
    end)
end)

describe("gesture menu path", function()
    it("finds the gesture manager inside the file browser menu", function()
        local tabs = {
            { id = "file", sub_item_table = { { id = "start_with" } } },
            { id = "settings", sub_item_table = {
                { id = "screen" },
                { id = "taps_and_gestures", sub_item_table = {
                    { id = "gesture_manager" },
                    { id = "gesture_overview" },
                } },
            } },
        }
        eq(Gestures.menuPath(tabs, "gesture_manager"), "2.2.1")
        eq(Gestures.menuPath(tabs, "missing"), nil)
        eq(Gestures.menuPath(nil, "gesture_manager"), nil)
    end)

    it("lists a top swipe, two-finger swipes, edges, corners and the manager", function()
        local seen = {}
        for _, entry in ipairs(Gestures.MENU) do
            if entry.slot then seen[entry.slot] = true end
            if entry.manager then seen.manager = true end
            for _, slot in ipairs(entry.slots or {}) do seen[slot] = true end
        end
        eq(seen.top_down, true)
        eq(seen.two_east, true)
        eq(seen.left_edge, true)
        eq(seen.right_edge, true)
        eq(seen.tap_bl, true)
        eq(seen.hold_bl, true)
        eq(seen.other, true)
        eq(seen.manager, true)
    end)
end)
