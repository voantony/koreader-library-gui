-- E-ink ghosting: when the Library should flash (libraryrefresh.lua).
local Refresh = require("libraryrefresh")

describe("Flash to clear ghosting: pure parts", function()
    it("uses KOReader's flashing UI refresh, not a full-screen flash", function()
        eq(Refresh.FLASH, "flashui")
        eq(Refresh.UI, "ui")
        eq(Refresh.DEFAULT, "setting")
        eq(Refresh.DEFAULT_EVERY, 6)
    end)
    it("treats a missing choice as every N pages, matching KOReader", function()
        eq(Refresh.choice(nil), "setting")
        eq(Refresh.choice("always"), "always")
        eq(Refresh.choice("never"), "never")
        eq(Refresh.choice("setting"), "setting")
        eq(Refresh.choice("nope"), "setting")
        eq(Refresh.everyN(nil), 6)
        eq(Refresh.everyN(12), 12)
        eq(Refresh.everyN(0), 0)
        eq(Refresh.isCoverGrid("grid"), true)
        eq(Refresh.isCoverGrid("covers"), true)
        eq(Refresh.isCoverGrid(nil), true)
        eq(Refresh.isCoverGrid("list"), false)
        eq(Refresh.isCoverGrid("compact"), false)
    end)
    it("does nothing on LCD or the emulator", function()
        eq(Refresh.decide{ eink = false, reason = "page", turns = 5, every = 6 }, "ui")
        eq(Refresh.decide{ eink = false, reason = "tab" }, "ui")
        eq(Refresh.decide{ eink = false, reason = "overlay", cover_grid = true }, "ui")
    end)
    it("never flashes when the setting is off", function()
        local mode, turns = Refresh.decide{ eink = true, choice = "never", reason = "page", turns = 5, every = 1 }
        eq(mode, "ui"); eq(turns, 5)
        eq(Refresh.decide{ eink = true, choice = "never", reason = "tab" }, "ui")
        eq(Refresh.decide{ eink = true, choice = "never", reason = "shelf" }, "ui")
        eq(Refresh.decide{ eink = true, choice = "never", reason = "overlay", cover_grid = true }, "ui")
    end)
    it("flashes every page turn when set to every page", function()
        local mode, turns = Refresh.decide{ eink = true, choice = "always", reason = "page", turns = 0, every = 6 }
        eq(mode, "flashui"); eq(turns, 0)
        mode, turns = Refresh.decide{ eink = true, choice = "always", reason = "page", turns = 3, every = 6 }
        eq(mode, "flashui"); eq(turns, 0)
    end)
    it("flashes every N page turns and then starts counting again", function()
        local turns, mode = 0
        for i = 1, 5 do
            mode, turns = Refresh.decide{ eink = true, reason = "page", turns = turns, every = 6 }
            eq(mode, "ui", "turn " .. i)
            eq(turns, i)
        end
        mode, turns = Refresh.decide{ eink = true, reason = "page", turns = turns, every = 6 }
        eq(mode, "flashui", "sixth turn")
        eq(turns, 0)
        mode, turns = Refresh.decide{ eink = true, reason = "page", turns = turns, every = 6 }
        eq(mode, "ui")
        eq(turns, 1)
    end)
    it("uses KOReader's interval of 6 when none is stored, and treats 0 as never", function()
        local mode, turns = Refresh.decide{ eink = true, reason = "page", turns = 5 }
        eq(mode, "flashui")
        mode, turns = Refresh.decide{ eink = true, reason = "page", turns = 0, every = 0 }
        eq(mode, "ui"); eq(turns, 0)
        mode, turns = Refresh.decide{ eink = true, reason = "page", turns = 0, every = 1 }
        eq(mode, "flashui"); eq(turns, 0)
    end)
    it("always flashes when switching tabs or opening a shelf, and resets the count", function()
        local mode, turns = Refresh.decide{ eink = true, reason = "tab", turns = 4, every = 6 }
        eq(mode, "flashui"); eq(turns, 0)
        mode, turns = Refresh.decide{ eink = true, reason = "shelf", turns = 4, every = 6 }
        eq(mode, "flashui"); eq(turns, 0)
    end)
    it("closes a menu with a full-screen refresh, list or grid, even when page flashes are off", function()
        local mode, rect = Refresh.overlayClose(1264, 1680)
        eq(mode, "full")
        eq(rect.x, 0)
        eq(rect.y, 0)
        eq(rect.w, 1264)
        eq(rect.h, 1680)
        mode, rect = Refresh.overlayClose(nil, nil)
        eq(mode, "full")
        eq(rect.w, 0)
        eq(rect.h, 0)
    end)
    it("flashes when an overlay closes over the cover grid, not over a list", function()
        local mode, turns = Refresh.decide{ eink = true, reason = "overlay", cover_grid = true, turns = 2 }
        eq(mode, "flashui"); eq(turns, 0)
        mode, turns = Refresh.decide{ eink = true, reason = "overlay", cover_grid = false, turns = 2 }
        eq(mode, "ui"); eq(turns, 2)
    end)
    it("leaves ordinary redraws (search, filter, covers arriving) on a ui refresh", function()
        eq(Refresh.decide{ eink = true, reason = nil, turns = 3 }, "ui")
        eq(Refresh.decide{ eink = true, reason = "search", turns = 3 }, "ui")
    end)
end)
