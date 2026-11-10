# Changelog

## 0.5.0 (draft)

Not tagged and not released. This is a draft of what would go in v0.5.0, from !4 through !11.

Thanks to @drkhn1234, the first outside contributor, for the issues and the mockups. Thanks to Muse for the patch behind !4.

### Home screen

- Configurable widgets above the book grid: Continue Reading, Favorites, a series, a collection, or a folder. Long-press a title to switch it. None gives the books the full height. Defaults stay the single Continue reading strip (!6, closes #1).
- The bottom-left hamburger opens the Library menu upward from that button. A hold or double-tap in that corner is left to the corner gesture; a swipe is still LiveLight or the bottom-edge gesture (!6).
- When two widgets share the top, tapping a title expands one and turns the other into a tab. Tapping again restores the pair (!7, closes #2).
- Each widget remembers its page when a book is opened, and restores it when the Library returns. The page is also saved in plugin settings, so a restart keeps it (!8).
- Recently added is a widget choice. Books are sorted by file mtime, newest first (!10).

### Filters and the A–Z strip

- Filter chips keep their full labels and scroll sideways. A chip cropped at the screen edge shows that more sit past it (!5, closes #5).
- The A–Z strip is one right-hand column, with a larger bold face and a wider hit area. When Continue reading shortens it, letters are spread with dots instead of shrinking the type. A drag still scrubs every letter (!5).
- A vertical swipe that starts in the LiveLight edge is offered to that zone. Taps and drags on the strip still pick a letter (!5).
- While the finger is down on the strip, a large letter is shown in the middle of the screen and hidden on release. Dragging uses a fast refresh of the strip and the bubble, not a full flash (!9).
- On the Library screen the A–Z strip wins. A tap, drag, or vertical swipe that starts on it picks a letter and is not offered to LiveLight. The painted column is only as wide as the letters; the hit area still reaches the screen edge and a gutter, and a cover keeps a tap that lands on it. The centered letter is cleared however the finger comes off, including a missing release, and that rectangle gets a UI refresh (#8).
- The footer Resume button is removed. The current-book cover opens that book, and a long-press shows the title and progress. With no book, the slot stays empty so the footer does not shift (#4).
- A vertical drag on the left edge sets brightness with `setIntensity` on each step, the same call as the Controls slider, and does not repaint the Library during the drag. This plugin does not ship LiveLight; warmth on the right edge is still forwarded to that plugin when the swipe starts outside the strip (#8).

### Shelf, footer, search, and startup (!4)

Muse's patch, plus the review fixes on the same branch. Closes #3, #4, #6, #7, #8, and #10.

- Swipe up on the shelf hides Continue reading; swipe down brings it back (#3).
- The book you are reading has a shortcut in the footer (#4).
- Cover size and view sit beside the page arrows (#5, the footer part, already on !4).
- The search clear button hides when the query is empty, without rebuilding the text box (#6).
- An A–Z jump anchors the first matching book at the top of the page (#7).
- An installed LiveLight plugin can still take a right-edge swipe that starts outside the A–Z strip. Left-edge brightness on the Library screen is handled here (#8).
- Startup uses KOReader's Start with setting (#10).
- File-browser gestures on the library home screen are the separate, droppable commit on !4. That does not close #9.

### Docs

- Contributing guide, GitLab issue templates, a merge request template, and this changelog (!11).
