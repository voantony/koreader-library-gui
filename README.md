# Library GUI for KOReader

[![Release](https://gitlab.com/antonyvo/koreader-library-gui/-/badges/release.svg)](https://gitlab.com/antonyvo/koreader-library-gui/-/releases/v0.7.2)
[![Pipeline](https://gitlab.com/antonyvo/koreader-library-gui/badges/main/pipeline.svg)](https://gitlab.com/antonyvo/koreader-library-gui/-/pipelines)

Library GUI (`library.koplugin`) is a KOReader plugin that replaces the file browser with a library screen that looks and works more like the Kindle's own home screen: book covers with reading progress, a search bar with the clock and battery at the top, tabs for Books, Collections, Authors and Series, the menu in the footer, and a Controls panel you pull down from the top right (or open from the clock or the ☰ menu).

It sits alongside KOReader's file browser, History and Collections. It never moves or renames your books, and closing it takes you back to the normal file browser.

<p align="center"><img src="docs/screenshots/v050-widgets.png" width="420" alt="Books tab with Continue Reading and Favorites above the cover grid and one A–Z column on the right"></p>

The home-screen layout follows design ideas from [@drkhn1234](https://gitlab.com/drkhn1234), the first outside contributor. The current release is [v0.7.2](https://gitlab.com/antonyvo/koreader-library-gui/-/releases/v0.7.2) (10 November 2026). The shots in this section are from the KOReader emulator at the Kindle Colorsoft size (1264×1680).

## Home screen

**Widgets.** The area above the books holds one or two widgets. Until you choose, it is still the single Continue reading row. Long-press a title to switch that slot: Continue Reading, Favorites, Recently added, a series, a collection, or a folder. Recently added lists books by file date, newest first. With nothing selected, the books use the full height.

| Continue Reading and Favorites | One widget expanded | Recently added |
|---|---|---|
| ![Continue Reading beside Favorites](docs/screenshots/v050-widgets.png) | ![Continue Reading expanded, the other widget as a tab](docs/screenshots/v050-accordion.png) | ![Recently added, newest files first](docs/screenshots/v050-recently-added.png) |

**Accordion.** When two widgets share the top, tap a title and that widget takes the row. The other shrinks to a tab on the right. Tap the title again, or the tab, and they sit side by side again.

**A–Z strip.** One narrow column on the right, in a larger bold face, sitting against the divider. The grid keeps the width that used to be empty padding. The touch target is wider than the painted letters: it runs to the screen edge and a short way into the gutter, and a cover still takes a tap that lands on it. A full-height shelf shows every letter. When a widget shortens the strip, it shows letters with dots instead of shrinking the type, and a drag still moves through every letter. Hold or drag and a large letter sits in the middle of the screen until you let go. It is cleared when the finger lifts, including a lift off the strip or a flick that never sends a release.

| Full height | Shortened by Continue reading | Letter while dragging |
|---|---|---|
| ![Every letter in one right-hand column](docs/screenshots/v050-az-column.png) | ![A short strip with letters and dots](docs/screenshots/v050-az-short.png) | ![A large M in the middle of the screen](docs/screenshots/v050-az-bubble.png) |

**Brightness.** A vertical drag on the left edge sets the frontlight directly, the same `setIntensity` call the Controls brightness slider uses, on each step of the finger. The Library is not repainted while you drag. A small number shows the level and is cleared when you lift. A touch that starts on the A–Z strip is a letter, not the light. Warmth on the right edge is only a swipe that starts outside that strip; otherwise use the Controls panel. This plugin does not include LiveLight. If that plugin is installed it can still receive the right-edge swipe.

**Shelf.** Swipe up on the book grid to hide the widget band. Swipe down to bring it back.

| Continue reading showing | After a swipe up |
|---|---|
| ![The Books tab with Continue reading above the grid](docs/screenshots/v050-shelf-before.png) | ![The same shelf with the widget band hidden](docs/screenshots/v050-shelf-expanded.png) |

**Footer and menu.** The bottom left is the Library menu (☰). Next to it are the book count and sort, then the cover of the book you are reading, the size and view buttons, and the page arrows. Tap the cover to open that book. Hold it to see the title and how far you are. With no book in progress the cover spot stays empty and the footer does not shift. The menu opens upward from the hamburger.

| A book in progress | No book in progress |
|---|---|
| ![Footer with the current-book cover and no Resume button](docs/screenshots/v050-footer-book.png) | ![The same footer with an empty cover slot](docs/screenshots/v050-footer-empty.png) |

![The Library menu open over the book grid](docs/screenshots/v050-menu.png)

**Start with.** KOReader's own Start with setting, in the file browser menu, can be set to library. KOReader then opens the Library at startup and returns to it after a book closes. An older "Open Library at startup" tick is moved to that setting.

## Screenshots

| Compact · 2 columns | Compact with dates | Recently opened |
|---|---|---|
| ![Compact view in two columns, sorted by Last read](docs/screenshots/02-compact-2-columns.png) | ![Compact view sorted by Last read, with dates](docs/screenshots/03-compact.png) | ![Recently opened above the cover grid](docs/screenshots/20-recently-opened.png) |

| Authors | Series | Search with typos |
|---|---|---|
| ![Authors tab as a list with a book count for each author](docs/screenshots/04-authors.png) | ![Series tab with covers and progress for each series](docs/screenshots/05-series.png) | !["wutherng hieghts" still finds Wuthering Heights](docs/screenshots/06-search-typos.png) |

| Sort from the footer | The ☰ menu | Controls panel |
|---|---|---|
| ![Sort picker opened from the footer label](docs/screenshots/07-sort-picker.png) | ![The ☰ menu opening upward from the bottom left: sort, view including Cover only, Widgets, Gestures, A–Z strip, clock, battery, and Close Library](docs/screenshots/v050-menu.png) | ![Controls panel with brightness and warmth sliders, and Light, Night mode, Refresh, Wi-Fi, Rotate, Cover sleep and Exit](docs/screenshots/09-controls-panel.png) |

| Genres | Inside a genre | Go to page |
|---|---|---|
| ![Collections tab switched to Genres. This library's books are tagged Public domain](docs/screenshots/10-genres.png) | ![The Public domain genre opened, showing its books](docs/screenshots/11-genre-books.png) | ![Go to page dialog opened from the page number in the footer](docs/screenshots/19-go-to-page.png) |

| Book details | A book with no description | Library in the reader menu |
|---|---|---|
| ![Book details for Wuthering Heights: last read, file size, path, description, and Add to Want to Read](docs/screenshots/13-details-card.png) | ![Pride and Prejudice, finished, with no description. Mark unread sits with More and Close](docs/screenshots/14-details-card-none.png) | ![KOReader's reader menu with Library and Book details at the top, and the Library tab icon](docs/screenshots/12-reader-menu-library.png) |

| Clock and battery off |
|---|
| <img src="docs/screenshots/17-books-status-off.png" width="300" alt="The Books tab with the clock and battery turned off"> |

| Filters | Start with | Brightness |
|---|---|---|
| ![Filter chips with their full labels. Finished is cut off at the right edge](docs/screenshots/v050-filters.png) | ![KOReader's file browser, filing-cabinet tab, with Start with set to library](docs/screenshots/v050-start-with.png) | ![The frontlight level, 31, while a drag on the left edge is still down](docs/screenshots/v050-brightness.png) |

| Cover only | Badges and time left | Gestures |
|---|---|---|
| ![Cover only: New badges and a progress row with time left, no title under the cover](docs/screenshots/v070-cover-only.png) | ![List view with New, Read, and time left under the percent](docs/screenshots/v070-badges.png) | ![Gestures menu. Each row is still Same as file browser](docs/screenshots/v070-gestures.png) |

![Choices for swipe down from the top. Same as file browser is selected](docs/screenshots/v070-gesture-choices.png)

The shots on this page were taken in the KOReader emulator (1264×1680) with the dummy library. v0.7.0 adds the Gestures menu: a swipe down from the top opens KOReader's menu, and a two-finger swipe follows the file browser, until you pick another action. v0.6.0 adds Read / New badges, time left, Want to Read, and Cover only. Finished keeps its full label and is cut off at the screen edge when the row is wider than the screen; swipe the chips to bring it across. The level in the brightness shot is drawn by the plugin while the finger is down, and it is cleared when the finger lifts.

## Features

- **Search** is the top row of every tab. It filters as you type and searches whatever the tab shows: books on Books, author names on Authors, series on Series, collection names on Collections, and only that shelf's books inside an author, series or collection. Small typos, missing accents and punctuation are forgiven, so `charlote bronte` finds Charlotte Brontë (**Typo-tolerant search**, on by default). **Use KOReader's keyboard** (off unless you turn it on, in the ☰ menu) opens KOReader's own text box for the search instead of the Library keyboard.
- **Clock and battery** beside the search bar. **Show clock** and **Show battery** are in the ☰ menu, both on unless you turn one off. **Clock and battery** there, and in ☰ → Library, chooses the look: **Battery icon** (the default: a bold time and a battery that fills, with a bolt while charging), **Status bar** (KOReader's own battery icon and the percentage), or **Plain text** (the original line, such as *12:59 · 78%*). The clock follows KOReader's 12-hour clock setting. It changes when the Library redraws, and once a minute while it is on screen. If the device does not report a battery percentage, that part is left out.
- **Footer**: the ☰ menu, the book count and sort (*201 books · Last read ▾*), the cover of the book you are reading, size and view buttons, and the page number with arrows. Tap the cover to open that book; hold it for the title and progress. The ☰ menu opens upward from the bottom-left button.
- **Filters**: All, Unread, Reading, Barely started and Finished, each with a count. A book you opened but did not start (still on the cover, title page or contents) stays **Unread**. **Barely started** means past the contents but not through the first chapter; **Reading** means at least a chapter in. The Library learns a book's chapters from its table of contents the next time you open it. Until then, or without a table of contents, it goes by percentage: the first 2 % or 3 pages are Unread, then Barely started below 5, 10, 20 or 25 % (pick the cut-off in the ☰ menu).
- **Sort** by Author, Title, Date added, Last read or Series. Tap the label in the footer to change it, or use the ☰ menu.
- **Views**: Small, Medium or Large covers, List, Compact, Compact · 2 columns, and Cover only. Cover only keeps the progress row and the badges, and drops the title and author so more covers fit. The view, sort and filter are remembered for each tab and each author, series or collection you open (**Reset default layout** in the ☰ menu forgets them).
- **Read / New badges.** **New** is only for a book that has never been opened. A book you opened and left on the cover stays unmarked. **Read** means KOReader's doc settings say the book is finished. On hold is unchanged.
- **Time left** on in-progress books. A cover and a compact row put it next to the percent (*42 % · 2h 15m*). A list row puts it under the percent. It uses that book's own reading speed. If KOReader has no speed for the book, the duration is hidden; nothing is filled in with a default pace.
- **Want to Read.** From the details card or the book's More menu, add or remove the book from a KOReader collection named Want to Read. That collection then shows on the Collections tab like any other.
- **Dates**: sorted by Last read or Date added, each book shows its date (*3h ago*, *Yesterday*, *12 Oct*). Under Last read, books you've never opened follow in author order.
- **Widgets**: the area above the books. The default is still Continue reading, a row of the books you are in the middle of. Long-press the title to switch the slot to Favorites, Recently added (newest file first), a series, a collection, or a folder, or to clear it. Two widgets can sit side by side; tap a title to expand one and turn the other into a tab. A widget remembers its page when you open a book and come back. Swipe up on the grid to hide the band, and swipe down to restore it.
- **Collections and Series** as tabs. A series lists its books in order, and swiping past its last page opens the next series.
- **Genres**: a Collections | Genres switch at the top of the Collections tab. Genres are grouped from each book's keywords and Calibre tags, with a count and progress for each.
- **Book details**: long-press a book, or choose **Book details** in the reader's ☰ menu, for its cover, progress (and time left when it is known), series, genres, collections, pages, last read, file size, path, and the Calibre description. **Add to Want to Read** or **Remove from Want to Read** is on the card and on More. Tap the author, series, a genre or a collection to open that shelf. Along the bottom: **Mark finished** (or **Mark unread**), **More** for KOReader's usual book menu, and **Close**.
- **Library from inside a book**: **Library** is the first item in the reader's ☰ menu, and there is a Library tab (book icon) in the reader's top menu bar. Both save your place, close the book and open the Library.
- **Reader status bar**: when you open a book, the tappable bar at the bottom of the page shows the current page out of the total (for example *42 / 310*), once, if it was showing pages left. A tap cycles through current page, time left in the chapter, time left in the book, percent read, pages left in the chapter, and the clock. Long-press to pick a view, to choose which of those a tap cycles through, or to skim, go to a page, or hide the bar (a tap brings it back). Turn it off in the ☰ menu to leave KOReader's status bar as it is.
- **Go to page**: tap the page number in the footer (*1 / 50*) and type a page.
- **A–Z strip**: when books are already sorted by title, author or series (cover grid, list, or single-column Compact), and on the Authors, Collections and Genres lists, one narrow letter column runs down the right edge. The Series list shows it when that list runs past one page. It stays off for Date added, Last read and Size (the sort is not changed to make it appear), inside one series, on Compact · 2 columns, and when a search fits on one page. The letters are large and bold and sit against the divider. Tap, drag, or a vertical swipe that starts on the strip jumps to a letter. A large letter stays in the middle of the screen while your finger is down and is cleared when you let go. A vertical swipe on the right edge that starts off the strip can still change warmth when LiveLight is installed. Page numbers and the footer arrows stay. Turn it off in the ☰ menu (**A–Z strip**).
- **Flash to clear ghosting** (e-ink only): every few Library page turns the covers get a flashing refresh so old images don't linger on colour e-ink. It follows KOReader's own full-refresh setting (every 6 pages unless you changed that). Switching tabs, opening a shelf, or closing the details card, Controls panel, keyboard or a picker over the cover grid always flashes once. The ☰ menu has **Flash to clear ghosting**: every page, every N pages (KOReader setting), or never. Dragging the A–Z strip keeps its fast refresh. Does nothing on LCD screens or the emulator.
- **Bigger page buttons**: the footer arrows and the page number are about 10 mm wide to hit (at least 120 px on a 300 dpi Kindle), without making the footer taller.
- **Cover sleep screen**: one toggle to show the cover of the book you read last on the sleep screen. Turning it off puts back the sleep screen you had.
- **Controls panel**: swipe down from the top right (the right half of the top of the screen; a slightly diagonal pull is fine) for Brightness and Warmth sliders and buttons for Light, Night mode, Refresh (clears e-ink ghosting), Wi-Fi, Rotate, Cover sleep and Exit (asks first, then quits KOReader). You can also tap the clock or battery beside the search bar, or choose **Controls** in the ☰ menu. Anything your device doesn't have is left out.
- **Top tap while reading** (☰ → Library → **Top tap opens**): **Library GUI bar** (the default) opens a small menu: Library, Contents, Go to page, Search, Font & size, Readability, Light, Bookmark, Book details, Exit, and **More…** for KOReader's full reader menu. **KOReader menu** opens KOReader's own reader menu with that same tap. A swipe down from the top of a page opens KOReader's menu with either choice. The search keyboard stays on **Use KOReader's keyboard**.
- **Start with**: KOReader's own Start with setting (file browser menu) includes library. Choose it to open the Library when KOReader starts and to come back to it after closing a book. A vertical drag on the left edge of the Library sets brightness directly, at the same pace as the Controls slider.
- **Covers without other plugins.** Library GUI extracts covers itself in the background. If Project: Title or Cover browser is enabled, it reuses their cover cache.
- **Gestures** (☰ on the Library, or ☰ → Library → **Gestures**). On the Library home, a swipe down from the top opens KOReader's menu, and a two-finger swipe does whatever you set for the file browser (often rotate). That is **Same as file browser**, the default for every gesture. You can instead pick **Nothing**, or an action of your own: open KOReader's menu, rotate, brightness, warmth, open the current book, the Library menu, Controls, or turn a page. The list is the top swipe, two-finger swipes (right, left, up, down, diagonal), the screen edges, corner taps and holds, and multiswipe, pinch and spread. **KOReader gesture manager** in that menu opens the file-browser profile, which is what Same as file browser follows. A one-finger tap or swipe that starts on the A–Z strip still jumps to a letter. Open Library, Search library, Resume last book, Rescan library, and Next / Previous in series can also be assigned under *Taps and gestures*.

## Install

The current release is **[v0.7.2](https://gitlab.com/antonyvo/koreader-library-gui/-/releases/v0.7.2)**. Download **[library.koplugin-v0.7.2.zip](https://gitlab.com/antonyvo/koreader-library-gui/-/releases/v0.7.2/downloads/library.koplugin-v0.7.2.zip)** and unzip it. You get a folder called `library.koplugin`.

SHA256: `638d9a84f093387548193b27109f3abbd5aeb3d6b5e0ba7afd5d8620f4c86f2a`

1. Copy the `library.koplugin` folder into `koreader/plugins/` on your device, so you end up with `koreader/plugins/library.koplugin/main.lua`.
   - On a Kindle that is `/mnt/us/koreader/plugins/` (it shows as `koreader/plugins` when the Kindle is plugged in).
   - On a Mac, newer Kindles such as the Colorsoft connect over MTP and don't show up in Finder on their own. [Mount Kindle](https://gitlab.com/antonyvo/kindle-mtp-mount) (a small menu-bar app from the same author) shows the Kindle as a drive in Finder, and [OpenMTP](https://openmtp.ganeshrvel.com/) also works for copying the folder across.
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`. PocketBook: `/mnt/ext1/applications/koreader/plugins/`. Android: `koreader/plugins/` on internal storage.
2. Restart KOReader (☰ → Exit → Restart KOReader).
3. Open ☰ → **Library** → **Open Library**. To open it every time KOReader starts, set **Start with** to library in the file browser's menu.

### Updating

In KOReader, open the Library and choose ☰ → **Check for updates**. The same entry is under ☰ → **Library**. A newer release shows the version and a short changelog. **Update** downloads it, checks the published SHA256, replaces the plugin, and offers to restart KOReader. Your settings stay in `koreader/settings`. The previous plugin folder is kept as `library.koplugin.bak`.

**Check for updates weekly** is off until you turn it on. It only looks when Wi-Fi is already on, and it never installs by itself.

From a Mac, the same install runs if a Kindle is mounted (including through [Mount Kindle](https://gitlab.com/antonyvo/kindle-mtp-mount)), or with `kpush` when that is on your PATH:

```sh
curl -fsSL https://gitlab.com/antonyvo/koreader-library-gui/-/raw/main/tools/install.sh | bash
```

The [changelog](CHANGELOG.md) lists what is new in each release.

If **Library** is missing from the menu, check ☰ → Tools → More tools → Plugin management, where it is listed as Library GUI.

### For developers and Mac users

[`tools/kpush/`](tools/kpush/) is an optional command-line tool for macOS that copies the plugin files to a Kindle over MTP in one go, without Calibre. It was written for the Kindle Colorsoft, whose USB connection tends to drop after each libmtp command. Version 6 can also list (`ls`) and copy files off the Kindle (`pull`). See its [README](tools/kpush/README.md) for how to build and use it. You don't need it to install the plugin.

## Compatibility

- Tested on a **Kindle Colorsoft** running KOReader v2026.07.1, and in the KOReader desktop emulator.
- Needs KOReader v2025.04 or newer.
- It should work on other devices that run KOReader (Kobo, PocketBook, Android), but I haven't tried them. If you do, please open an issue and say how it went.

## Uninstall

Delete `koreader/plugins/library.koplugin/` and restart KOReader. To remove everything it made, also delete `koreader/settings/library_index.lua` and the `koreader/cache/library_covers/` folder.

## About this project

This is the first thing I've developed in public. I built it with Grok Bot, and I'm happy to take any suggestions and feedback: [open an issue](https://gitlab.com/antonyvo/koreader-library-gui/-/issues) for bugs, ideas or anything that looks off on your device.

The home-screen ideas, including the widgets, the accordion, and the footer, came from [@drkhn1234](https://gitlab.com/drkhn1234).

Ideas came from [Project: Title](https://github.com/joshuacant/ProjectTitle), [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) and ZenOS. Only ideas: no code was copied from them or from KOReader, and Library GUI is written from scratch under the MIT licence.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the tests and the emulator. `tools/emulator/shoot.sh smoke` runs the plugin in headless KOReader and writes a PNG to `emulator-out/smoke/`. Benchmarks are in [bench/RESULTS.md](bench/RESULTS.md).

## Support

If this saves you time and you'd like to say thanks, tips are welcome. Always optional.

**Venmo:** [@Antony-Vo](https://venmo.com/u/Antony-Vo) (US)

**Crypto:**

| Coin | Address |
| --- | --- |
| Bitcoin (BTC) | `bc1pug8q2ceda7f3p30ezptg2mnz4khg9d5v9fd6p454qqs20zdyzw8qnuf8cx` |
| Ethereum (ETH, and tokens on EVM chains) | `0xf9439c4330427E45017A3c4454137474DEbB3E36` |
| Monero (XMR) | `84iCefzmu82Ha9eHPyRpsKPLcuEkBxBRxZm1FSx72T5S1CULgQkabtf9K8Lwxf6NFaLvUoJPqAqvL1EgaSvR7rMbJhKupfr` |

Please double-check the address before you send. Crypto transfers can't be reversed.

## Licence

[MIT](LICENSE)
