# KOReader emulator

Headless screenshots of `library.koplugin` on Linux, at the Kindle Colorsoft size (1264×1680, 300 dpi).

```sh
tools/emulator/shoot.sh smoke
tools/emulator/shoot.sh footer
```

`smoke` writes `emulator-out/smoke/smoke-library.png`.

`footer` writes:

- `footer-page-label.png` — the footer page label `3 / 12`
- `footer-go-to-page.png` — the Go to page dialog opened from that label
- `footer-jump-last.png` — the last page after a long-press on the next arrow, when this build of the plugin has that long-press

`az` writes `az-01-title-sort.png` … `az-06-last-read-no-strip.png` (the A–Z strip on a Title sort, after tapping M, mid-drag on T with the big letter, after the drag, on the Authors list, and hidden on Last read).

`aznav` writes `aznav-compact.png` (single-column Compact, Title sort), `aznav-authors.png`, `aznav-grid.png` (Title cover grid), `aznav-series.png` (the Series list; the strip is on only when that list has more than one page), `aznav-compact2.png` (two columns, no strip) and `aznav-last-read.png` (no strip, sort still Last read).

`toptap` opens a book and writes `toptap-01-library-gui-bar.png`, `toptap-02-koreader-menu.png` and `toptap-03-details-from-reader.png`.

`gestures` drives the file-browser top swipe and a two-finger rotate on the Library home. `gesturemenu` opens the Library's Gestures menu and shows a top swipe that does nothing after that choice is set to Nothing.

`readme` also writes `v050-az-column.png`, `v050-az-short.png`, `v050-footer-book.png`, `v050-footer-empty.png`, `v070-cover-only.png`, `v070-badges.png`, `v070-gestures.png` and `v070-gesture-choices.png`. Those names are scenarios on their own (`azcolumn`, `azshort`, `footerbook`, `footerempty`, `coveronly`, `badges`, `gesturepages`).

`readme` writes the README shots that show the v0.5.0 home screen and gallery. It waits until the covers on screen have been extracted, so the PNGs are not grey placeholders. The same shots can be taken on their own:

| Scenario | PNGs |
| --- | --- |
| `widgets` | `v050-widgets.png` — Continue Reading and Favorites, one A–Z column |
| `accordion` | `v050-accordion.png` — one widget expanded, the other as a tab |
| `recently` | `v050-recently-added.png` |
| `shelf` | `v050-shelf-before.png`, `v050-shelf-expanded.png` |
| `bubble` | `v050-az-bubble.png` — a large M while the finger is still down |
| `menu` | `v050-menu.png` — the ☰ menu from the bottom left, Widgets visible |
| `filters` | `v050-filters.png` — full chip labels, Finished cut off at the screen edge |
| `brightness` | `v050-brightness.png` — the on-screen level during a left-edge drag |
| `controls` | `09-controls-panel.png` — brightness, warmth, and the round buttons |
| `startwith` | `v050-start-with.png` — file browser, filing-cabinet tab, Start with: library |
| `gallery` | the gallery views (`02`, `03`, `20`, `04`, `05`, `06`, `07`, `09`, `10`, `11`, `19`, `13`, `14`, `17`, `12`) |

`13-details-card.png` shows a description. The dummy books have no Calibre comments, so that one shot feeds the details card a single public-domain sentence for Wuthering Heights. `14-details-card-none.png` is a book left as the library generated it.

The `koreader` launcher sets `KO_MULTIUSER`, so this build reports itself as a desktop and hides the frontlight, warmth, e-ink refresh and Wi-Fi. `controls` tells the panel those exist for the shot, which is what a Kindle shows. The left-edge brightness number does not need that: the desktop power device already accepts `setIntensity`.

`readme` and `gallery` allow 720 seconds; the others use `EMU_TIMEOUT` (180).

KOReader itself is not committed. `tools/emulator/setup.sh` downloads the official Linux x86_64 tarball of **v2026.07.1** from the [KOReader releases](https://github.com/koreader/koreader/releases/tag/v2026.07.1), checks the sha256 pinned in `config.sh`, and extracts it under `~/.cache/koreader-library-gui/`. A public-domain dummy library (from `tools/make_dummy_library.py`) is cached in the same place.

## Requirements

- Linux x86_64, glibc 2.35 or newer (the v2026.07.1 tarball)
- `curl`, `tar`, `Xvfb`
- Python 3 and Pillow (`pip install pillow`)

This KOReader build's SDL dummy framebuffer is fixed at 600×800 and ignores `EMULATE_READER_W` / `EMULATE_READER_H`. `shoot.sh` starts Xvfb and asks SDL for the Colorsoft size instead.

## Options

| Variable | Meaning |
| --- | --- |
| `EMU_OUT` | Directory for PNGs and logs. Default `emulator-out/<scenario>/`. |
| `EMU_PLUGIN` | `library.koplugin` to copy. Default is the one in this checkout. |
| `EMU_COUNT` | How many dummy books to seed. Default 200. |
| `EMU_TIMEOUT` | Seconds before KOReader is stopped. Default 180. |
| `EMU_HOME` | Keep the KOReader home at this path instead of a temp dir. |
| `KOREADER_CACHE` | Cache directory. Default `~/.cache/koreader-library-gui`. |

`shoot.sh footer` exits successfully without `footer-jump-last.png` only when the probe log says the next arrow has no long-press. A long-press that does not move the page is a failure.

`smoke`, `footer`, `az`, `aznav` and `toptap` shoot as soon as the page is up. Cover thumbnails are filled in afterwards, in the background, so those PNGs may still show the grey placeholder covers. The footer, dialogs and gestures are already on screen. The README scenarios above wait for the visible covers instead.

Logs next to the PNGs: `probe.log`, `koreader.log`, and `crash.log` if KOReader wrote one.
