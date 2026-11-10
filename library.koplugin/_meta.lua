local _ = require("gettext")
return {
    fullname = _("Library GUI"),
    -- The in-plugin updater compares this with the latest GitLab release.
    -- `make stage` / `make zip` rewrite it from the Makefile VERSION.
    version = "0.7.5",
    description = _([[Library GUI: a Kindle-style library for KOReader. Covers or a list with reading progress, a Continue reading row, a search bar that filters as you type, a clock and battery beside it, an A–Z strip when the list is alphabetical, All / Unread / Reading / Finished filters, Collections, Authors and Series tabs, menu and resume in the footer, and a Controls panel (swipe down from the top right, or tap the clock).]]),
}
