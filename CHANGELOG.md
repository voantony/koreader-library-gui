# Changelog

## Unreleased

- **Straight back to the Library.** Closing a book that was opened from the Library, or when the Library is the home screen, paints the Library first. KOReader's file browser stays underneath and is not shown on the way. One full-screen refresh clears the ghost of that file browser on a colour e-ink screen such as the Kindle Colorsoft. Thanks to u/ucsilahsor, who reported the flash on Reddit.
- **After closing a book.** In the Library's ☰ menu, and under ☰ → Library: **Return to Library** (the default, above) or **Return to file browser** (KOReader's file browser, and the Library stays closed). Choosing Library from inside a book still opens it.
- **On startup.** **Open Library** or **Resume last book**. Resume last book uses KOReader's Start with set to the last file. If KOReader opens that book, the Library is not drawn on top of it.

## 0.7.4 (2026-11-10)

Reported by u/ucsilahsor on Reddit.

- **Duplicate books.** The same file is one book. A symlink, a second path onto it, `/mnt/us` and `/mnt/base-us`, and a capitalisation difference on those volumes used to show up as separate tiles, each with its own progress. **Merge copies of the same book** (on, in ☰ → Library) also folds several formats or folders of one work into one tile: the same title and authors, or the same Calibre id. The copy you have started is kept, then the one you read last, then EPUB, AZW3, MOBI, PDF. Long-press the tile: the details card lists the other copies, and each one opens that file. Turn the setting off to see every format again. The same file is still listed only once.
- **Files that are not books.** The grid was filling up with notes, readme files, exported highlights and folders from code and the device (`latest-captures`, `launchers`, `annotations`, and the like). Hidden folders, `.sdr` sidecar folders, KOReader's own folders, and common code and system folders (`node_modules`, `.git`, `build`, `venv`, `__pycache__`, `system`, `Android`, and others) are not scanned. EPUB, PDF, MOBI, AZW, AZW3, KFX, FB2, DjVu, CBZ, CBR, CB7, DOCX, RTF and CHM stay. TXT, HTML, Markdown and JSON are off until **Show plain text and web files** is on. Exported highlight and annotation files stay hidden either way. **Folders to skip** edits the folder-name list; clear it and save to put the default list back. The next time the library is opened, the new defaults apply. Nothing has to be switched on by hand.
- **Counts.** All, Unread, Reading, Barely started and Finished are counted after duplicates are folded and those files are left out. A book KOReader has marked finished (`summary.status` `complete`, including the spellings `finished` and `read`) counts as Finished, including when the sidecar was stored under `/mnt/us` and the library saw `/mnt/base-us`.
- **Menu close.** Closing a menu or a dialog over the Library leaves the Library on top and repaints the whole screen with a full flash, including the A–Z strip, the clock and the footer. A partial refresh was leaving ghosted menu text and NEW badges down the right-hand covers and the A–Z strip, and could paint the file browser through that area. Seen on a Kindle Colorsoft.

## 0.7.3 (2026-11-10)

- **Updates.** ☰ → Updates, and the same entry under ☰ → Library. **Check for updates now** looks up the latest release. A newer one shows the version and a short changelog. Update checks the published SHA256, replaces `library.koplugin` (the previous folder is kept as `library.koplugin.bak` and put back if the install fails), and offers to restart KOReader. Settings stay in `koreader/settings`. **Automatic updates** are **Notify me** until you change them (an unset choice is Notify me). **Off** turns background checks off; checking by hand still works. **Notify me** looks about once a week, only when Wi-Fi is already on, and only shows a short notice. **Install quietly** does that check and, when a newer release is found and no book is open, downloads it, checks the SHA256, installs it, and says it takes effect at the next restart. It does not turn Wi-Fi on, does not restart KOReader, and says nothing if the install fails. On a Mac, `curl -fsSL https://gitlab.com/antonyvo/koreader-library-gui/-/raw/main/tools/install.sh | bash` does the same install when a Kindle volume is mounted, or with `kpush` when that is on your PATH.

## 0.7.2 (2026-11-10)

- **Clock and battery.** Beside the search bar, three looks: **Battery icon** (the default: a bold time and a battery that fills, with a bolt while charging), **Status bar** (KOReader's own battery icon and the percentage), and **Plain text** (the original line). A saved thin-bar choice shows the battery icon. The clock follows KOReader's 12-hour clock setting, and the header rebuilds when that setting changes. Tap the clock or battery to open Controls, as before.

## 0.7.1 (2026-11-10)

- **Details card fix.** The book details card (long-press a book) crashed while drawing pages, last read, file size and path, a bug since v0.6.0. Fixed.
- README refreshed for v0.7.0 with new screenshots of the Gestures menu, Cover only, and the badges.

## 0.7.0 (2026-11-10)

File-browser gestures on the Library home, and a Gestures menu so the Library can use its own bindings. Thanks to @drkhn1234 for #9 and for saying which gestures they use on a Kindle Paperwhite 4.

- **Top menu and two-finger rotate.** A swipe down from the top edge opens KOReader's menu, the same zone the file browser uses. A two-finger swipe follows the file-browser gesture profile, including when it starts on the A–Z strip. If that gesture rotates the screen, the Library is rebuilt for the new size instead of being left laid out for the old one. The left edge still sets brightness, and warmth on the right edge is still forwarded. Page turns, the shelf swipe, and a one-finger jump on the A–Z strip are unchanged. Related to #9.
- **Gestures menu.** On the Library's ☰ button, and under ☰ → Library → Gestures. Each gesture (swipe down from the top, two-finger swipes, the screen edges, corner taps and holds, and multiswipe, pinch and spread) can stay **Same as file browser** (the default, so nothing changes), do **Nothing**, or run its own action: open KOReader's menu, rotate, brightness, warmth, open the current book, the Library menu, Controls, or turn a page. **KOReader gesture manager** opens the file-browser profile, which is what Same as file browser follows.

## 0.6.0 (2026-11-09)

Read / New badges, time left, Want to Read, and a Cover only view, on top of v0.5.0.

- **Read / New badges.** New means the book has never been opened (no sidecar and no history entry). A book you opened and left on the cover stays unmarked. Read means KOReader's doc settings say finished (`summary.status == "complete"`). On hold is unchanged.
- **Time left.** Shown on in-progress books only. A cover and a compact row put the duration next to the percent (`42 % · 2h 15m`). A list row puts it under the percent. It is computed from that book's own reading speed. If those numbers are missing, the line is hidden. Nothing is filled in with a default pace.
- **Want to Read.** A KOReader collection named Want to Read, created when you add the first book. Long-press opens the details card, which has **Add to Want to Read** / **Remove from Want to Read**. The same action is on the book's More menu. The collection then shows on the Collections tab like any other.
- **Cover only.** A new entry on the View picker (grid sizes, List, Compact, Compact · 2 columns, Cover only). Covers keep the progress row and the badges, and drop the title and author, so more of them fit. The choice is stored in the same per-shelf memory as the other layouts.
- **Details card.** Still read-only. Under the title, author and series it now lists pages, last read (`Never` when there is no opened time), file size and path. Progress, including a known time left, stays on the progress line.

## 0.5.0 (2026-11-09)

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
- Scrubbing the A–Z strip no longer crashes. The touch area is always a rectangle with a `contains` method, including before the strip is laid out, so the first touch does not call `contains` on a plain table (!14, #8).

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
