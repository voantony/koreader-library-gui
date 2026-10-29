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
```
