# Benchmark results

These numbers come from the KOReader **v2026.07.1** desktop emulator (x86-64 Linux build, Intel Xeon, SDL) with a 1264×1680 screen at 300 dpi, the size and DPI of a Kindle Colorsoft. Project: Title v3.8.3 was enabled and Cover browser was disabled. The library was 200 dummy public-domain EPUBs with covers (7.6 MB), a `metadata.calibre`, 36 sidecars, a reading history and three collections. All of it came from `tools/make_dummy_library.py`.

Every scan figure is the median and max of 5 runs. Times are wall-clock, measured inside KOReader with `ui/time`.

## Index

| Scan | median | max | Breakdown of one run |
|---|---|---|---|
| First scan, no index cache, with metadata.calibre | 6 ms | 11 ms | walk 1.2 ms · calibre 0.6 ms · metadata + 36 sidecars 2.3 ms · write cache 1.5 ms |
| First scan, no index cache, no metadata.calibre (all metadata from the cover DB) | 14 ms | 20 ms | walk 1.4 ms · BIM lookups 14 ms · write cache 4.4 ms |
| Cached scan (fresh process, index cache on disk) | 4 ms | 5 ms | walk 1.7 ms · read cache · 0 sidecar reads |

All 200 books got their metadata from `metadata.calibre` when it was present, and from the cover DB when it was not. A cached scan still walks the folder tree and checks every file's size and mtime, but it re-reads a sidecar only if that sidecar's mtime has changed.

## Grid

| | median | max |
|---|---|---|
| Open the Library (build + paint, covers in the cover DB) | 31 ms + 18 ms | |
| Turn a page, covers not yet scaled (cache cleared) | 27 ms | 37 ms |
| Turn a page, scaled covers in the LRU cache | 17 ms | 29 ms |

A page holds 8 books (4 columns × 2 rows) at this screen size. Extracting covers for all 200 books into an empty Project: Title cover DB took about 8 s in the emulator. This is a one-time cost, and it runs in the background.

## Continue reading and list view (v0.2.0)

Same emulator and library, 4 columns:

| | books per page |
|---|---|
| Grid, no Continue reading row | 8 (4 × 2) |
| Grid under the Continue reading row (5 covers, 274 px tall) | 8 (4 × 2, covers 298 px instead of 453 px) |
| List | 9 rows of 138 px |
| List under the Continue reading row | 6 rows |

The bench also taps and long-presses a list row and a Continue reading cover, and checks that they open the book and show the book menu, like a grid tile.

## Search (per keystroke)

52 keystrokes, made by typing `sherlock`, `jane austen`, `oz`, `mars`, `dickens`, `collected works 3` and `zzz` one character at a time:

| | median | max |
|---|---|---|
| Filter the in-memory index (200 books) | 0.06 ms | 0.31 ms |
| Filter a 2,000-book in-memory copy | 0.02 ms | 0.77 ms |
| Rebuild the result grid | 0.65 ms | 10 ms |
| Filter + rebuild + forced repaint of the area below the search bar | 33 ms | 33 ms |

The search waits 150 ms after the last keystroke before it runs (`debounce_ms`), so fast typing triggers only one search. Each keystroke filters only the previous results when the new query extends the old one.

Hits: sherlock 8 · jane austen 6 · oz 6 · mars 4 · dickens 9 · "collected works 3" 1 · zzz 0.

## Built-in covers

Same emulator and library, but with **Project: Title and Cover browser both disabled**, so the plugin extracts covers itself (`LIBRARY_BENCH_MODE=covers`). The run starts with an empty `cache/library_covers/`.

| | |
|---|---|
| Open the Library, empty cache (build + paint, placeholders) | 19 ms + 15 ms |
| First covers on screen (the 8 on page 1 and the Continue reading row) | 0.6 s |
| All 200 covers extracted | 5.7 s |
| Thumbnail cache on disk | 200 files, 3.7 MB (396×594 JPEGs, about 19 KB each) |
| Open the Library, thumbnails on disk, nothing in memory (5 runs) | 43 ms median, 55 ms max |
| Turn a page, thumbnails on disk (6 pages) | 33 ms median, 34 ms max |

While extraction ran, the bench turned a page and tapped a cover every 0.7 s (7 times each):

| During extraction | median | max |
|---|---|---|
| Turn a page (build + paint) | 21 ms | 25 ms |
| Tap a cover until the open-book handler runs | 0 ms | 1 ms |
| Lateness of a 50 ms timer on the UI loop (100 samples, p95 2 ms) | 0 ms | 26 ms |

All 7 taps reached the handler. Extraction runs in a separate process, so the UI loop only polls it every 0.5 s and redraws the tiles whose covers have landed.

Other checks in the same run:

- Setting a custom cover with *Book information* replaced the book's thumbnail within 1.6 s (396×526, the custom image's shape). Removing it brought the original back.
- **Clear cover cache** with the Library open deleted all 200 thumbnails, and they were extracted again in 4.2 s.
- In a separate run with three bad files added (random bytes named `.epub`, an 11-byte `.epub`, and a `.txt` with no cover), all three got a "no cover" marker and the other 200 covers were extracted normally.
- After the Library was closed, no extraction process was left running.

With Project: Title enabled, the regular bench still extracts covers into its cache (10 s for 200 books this time, 8 s in the earlier run) and writes nothing to `cache/library_covers/`. The other numbers stayed within noise of the tables above: first scan 8 ms, cached scan 5 ms, open 36 + 18 ms, page turns 36 ms (not yet scaled) and 17 ms (cached).

## On a real Kindle

None of these numbers were measured on a device. Expect the CPU-bound parts to be roughly an order of magnitude slower on the Kindle; that is an estimate, not a measurement. Even then, search filtering stays well under a frame, and the e-ink refresh, not the plugin, sets the visible latency.

## Rerun

```sh
python3 tools/make_dummy_library.py --out /tmp/dummy --count 200
# Lay out an emulator home (set home_dir in settings.reader.lua to it): books in $HOME/us/documents, metadata.calibre in $HOME/us,
# history.lua and settings/collection.lua in $XDG_CONFIG_HOME/koreader/, and symlink
# library.koplugin and tools/librarybench.koplugin into $XDG_CONFIG_HOME/koreader/plugins/.
LIBRARY_BENCH_OUT=/tmp/bench-out EMULATE_READER_W=1264 EMULATE_READER_H=1680 \
  EMULATE_READER_DPI=300 ./koreader/bin/koreader
# -> /tmp/bench-out/results.lua and the PNG screenshots
# Built-in covers: disable Project: Title and Cover browser (plugins_disabled in settings.reader.lua), then
LIBRARY_BENCH_MODE=covers LIBRARY_BENCH_OUT=/tmp/bench-covers EMULATE_READER_W=1264 EMULATE_READER_H=1680 \
  EMULATE_READER_DPI=300 ./koreader/bin/koreader
```
