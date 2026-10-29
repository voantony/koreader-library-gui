# library-search-toolbar

**Library** (`library.koplugin`) is a KOReader plugin that gives you a Kindle-style library: a cover grid sorted by the book you opened last, a search bar that stays at the top of the screen and filters as you type, and one-tap filters for All / Unread / Reading / Finished. Collections, Authors and Series are top-level tabs.

It works alongside KOReader's file browser, History and Collections. It reuses the cover cache of **Project: Title** (or the built-in Cover browser), so covers you already have show up straight away. It never moves or renames your books.

> **Early release (v0.1.0).** It has been tested in the KOReader desktop emulator (v2026.07.1), but not yet on many real devices. Please [open an issue](https://github.com/voantony/library-search-toolbar/issues) if something looks wrong on yours.

## Screenshots

| Library, sorted by recent | Searching as you type |
|---|---|
| ![Library, sorted by recent](screenshots/01-library-recent.png) | ![Search results while typing](screenshots/03-search-results.png) |

More are in [screenshots/](screenshots/). They were taken in the emulator with dummy public-domain books.

## Install

1. Download **`library.koplugin.zip`** from the [latest release](https://github.com/voantony/library-search-toolbar/releases/latest).
2. Unzip it into KOReader's `plugins/` folder, so you end up with `…/koreader/plugins/library.koplugin/main.lua`:

   | Device | Plugins folder |
   |---|---|
   | Kindle | `/mnt/us/koreader/plugins/` |
   | Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
   | PocketBook | `/mnt/ext1/applications/koreader/plugins/` |
   | Android | `koreader/plugins/` on internal storage |
   | Linux desktop | `~/.config/koreader/plugins/` |

3. Restart KOReader.
4. Open ☰ → **Library** → **Open Library**. If **Library** isn't in the menu, enable it under ☰ → Tools → More tools → Plugin management.
5. Optional: tick ☰ → Library → **Open Library at startup**.

For covers, enable Project: Title or Cover browser. Updating works the same way: replace the `library.koplugin` folder with the new one. Kindles that only connect over MTP, such as the Colorsoft: see [INSTALL_PLAN.md](INSTALL_PLAN.md).

## Features

- **Search bar, always on screen.** It is part of the Library screen, not a pop-up. Tap it and type: results update as you type, matching title, author, series and file name. Every word must match, case is ignored, and a search for `jane aus` finds *Jane Austen*. Searching runs on an in-memory index, waits 150 ms after the last key and redraws only the grid area below the bar. Tap **Enter** or anywhere outside the keyboard to hide the keyboard and keep the results. Tap **✕** to clear.
- **Cover grid** with a reading-progress bar and the percentage read, a **✓** on finished books, **NEW** on books you haven't opened and **on hold** on abandoned ones. Books with no cover yet get a plain placeholder with the title until the cover is extracted.
- **Sort**: Recent (last opened; the default), Title, Author, Series, Date added.
- **Tabs**: Books · Collections · Authors · Series. Opening a group shows its books, with a **← group** chip to go back.
- **Filters**: All / Unread / Reading / Finished, each with a count. On-hold books appear only under *All*.
- **Long-press a book** to set its status, show its folder, view book information or open it.
- **Swipe** left and right, or use the page keys, to turn pages. The **‹ 1 / 25 ›** buttons do the same.
- **Startup**: optionally show the Library instead of the file browser when KOReader starts, and go back to it after closing a book. Closing the Library (✕) always takes you to the normal file browser, so it is a safe fallback.
- **Gestures**: *Library*, *Search library* and *Rescan library* are actions you can assign under *Taps and gestures*.

### Where the metadata comes from

For each book the plugin uses the first source that has data:

1. **`metadata.calibre`** (written by calibre or KOReader's Calibre plugin), if one exists in the library folder, one of its parent folders or the inbox folder.
2. **The cover cache** (`BookInfoManager`) of Project: Title or Cover browser.
3. **The book's sidecar** (`.sdr`) once you have opened the book.
4. **The file name.**

Reading status and progress always come from the sidecar. *Last opened* comes from KOReader's History. The index is saved to `settings/library_index.lua`, keyed by each file's path, size and modification time, so later scans only re-read what changed. If a book has no cover in the cache, the plugin asks the cover cache to extract it in the background, the same way Project: Title does, and fills it in when it is ready.

## Requirements

- KOReader **v2025.04 or newer**. Tested on **v2026.07.1**, in the desktop emulator.
- Project: Title or the Cover browser plugin is needed for covers. Either one can be enabled. Without them you get placeholders.

## Install from source

Copy the `library.koplugin` folder from this repository into KOReader's `plugins/` folder, using the table above. Only the six `.lua` files inside it are needed.

## Settings

You can change these under ☰ → Library, or with the ☰ button in the Library's top-left corner:

| Setting | Default |
|---|---|
| Open Library at startup | off |
| Return to Library after closing a book | on |
| Sort | Recent |
| Columns | 4 (3–6) |
| Library folder | KOReader home folder |
| Include hidden folders | off |

Settings are stored in `settings.reader.lua` under the key `library_plugin`.

## Uninstall

1. Turn off **Open Library at startup** if you turned it on. This step isn't strictly needed: without the plugin, the setting is ignored.
2. Delete `plugins/library.koplugin/`.
3. Delete `settings/library_index.lua`, the plugin's cache.
4. Restart KOReader.
5. Optional: with KOReader closed, remove the `["library_plugin"] = { … },` block from `settings.reader.lua`. If you leave it, it does no harm.

The plugin writes to two places other than its own files. First, the status buttons write to the book's sidecar; these are the same buttons KOReader's History uses. Second, it adds missing covers to the Project: Title / Cover browser cache, which is the same thing those plugins do on their own.

## Performance

These were measured in the KOReader v2026.07.1 desktop emulator with 200 dummy EPUBs and a 1264×1680 screen at 300 dpi. See [bench/RESULTS.md](bench/RESULTS.md) for details and for how to rerun them.

| | median | max |
|---|---|---|
| Search: filtering the 200-book index per keystroke | 0.06 ms | 0.31 ms |
| Search: filtering a 2,000-book index per keystroke | 0.02 ms | 0.77 ms |
| Search: filter + rebuild + repaint per keystroke | 33 ms | 33 ms |
| First scan (no index cache, metadata.calibre) | 6 ms | 11 ms |
| First scan (no index cache, no metadata.calibre, cover DB) | 14 ms | 20 ms |
| Cached scan (index cache on disk) | 4 ms | 5 ms |
| Open the Library: build + paint | 31 + 18 ms | |
| Turn a page (covers not yet scaled) | 27 ms | 37 ms |
| Turn a page (covers cached) | 17 ms | 29 ms |

A Kindle is much slower than a desktop and e-ink refreshes take their own time, so treat these as relative numbers.

## Development

```
library.koplugin/
  _meta.lua          plugin name and description
  main.lua           menus, settings, startup, dialogs, gestures
  libraryview.lua    the Library screen: title bar, search bar, tabs, chips, grid, footer
  librarytile.lua    cover tiles, badges, chips, LRU cache of scaled covers
  libraryindex.lua   scan + metadata (calibre > cover DB > sidecar) + on-disk cache
  librarycore.lua    pure logic: sorting, grouping, filters, search index, grid maths
spec/                tests (run.lua is a tiny runner for LuaJIT / Lua 5.1)
tools/
  make_dummy_library.py     generates N public-domain EPUBs with covers + metadata.calibre
  librarybench.koplugin/    emulator benchmark + screenshots (development only, never install)
screenshots/         emulator screenshots of the dummy library
bench/RESULTS.md     benchmark numbers
```

```sh
make test                   # or: luajit spec/run.lua  (KOReader's own luajit works)
make stage                  # dist/library.koplugin/ + dist/SHA256SUMS, the files to install
```

The tests use in-memory fixtures. The emulator library is generated from public-domain titles. `.gitignore` excludes books, `.sdr` folders, KOReader settings, history and cache files, so device data can't be committed by accident.

## License

[MIT](LICENSE)
