# Library for KOReader

A KOReader plugin that turns a folder of books into a browsable library. Instead of walking the file tree, you can browse every book under one folder by author, series, reading status, format or sub-folder, see what you're currently reading or what you added recently, and search across titles, authors, series, keywords and file names.

It works alongside KOReader's file browser, History and Collections, and alongside cover-browser plugins such as Project: Title. It doesn't change your files or move your books.

## Features

- **One entry point**: *Library* in the main (☰) menu, in both the file browser and the reader.
- **Home view**: All books · Currently reading · Recently added · Authors · Series · Reading status · Formats · Folders, each with a count.
- **Authors**: a book with several authors is listed under each of them. Books with no author go into *Unknown author*, which is listed last.
- **Series**: books are ordered by series index (1, 2, 2.5, 3 …).
- **Search**: every word must match somewhere in the file name, title, authors, series or keywords. Matching ignores case.
- **Long-press a book** to set its status (Reading / On hold / Finished), open its folder, view book information or open it.
- **Sort books** by title, author, series, date added or size.
- **Gestures**: *Library*, *Search library* and *Rescan library* are available as actions you can assign under *Taps and gestures*.
- **Settings** are stored in KOReader's own settings file under the key `library_plugin`.

Metadata comes from KOReader itself: from the book's sidecar (`.sdr`) after the book has been opened once, or from the cover-browser cache if you use one. Books that have never been opened and haven't been indexed show their file name. Once metadata exists, run **Rescan library** to update the list.

## Requirements

- KOReader **v2025.04 or newer**. The plugin uses the `BookList` widget, which was added in that release. It was written against the v2026.07 source.
- Any device KOReader runs on, including Kindle, Kobo, PocketBook, Android, reMarkable and desktop.

## Install

1. Download or clone this repository.
2. Copy the `library.koplugin` folder (the folder itself, not just its contents) into KOReader's `plugins/` folder:

   | Device | Plugins folder |
   |---|---|
   | Kindle | `/mnt/us/koreader/plugins/` |
   | Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
   | PocketBook | `/mnt/ext1/applications/koreader/plugins/` |
   | Android | `koreader/plugins/` on internal storage |
   | Linux desktop | `~/.config/koreader/plugins/` |

   Afterwards you should have `…/plugins/library.koplugin/main.lua`.
3. Restart KOReader.
4. Open ☰ → **Library**. The first time, you may need to enable it under ☰ → Tools → More tools → Plugin management.

The first scan reads metadata for every book and can take a few seconds on large libraries. After that, results are kept in memory until you rescan, change the library folder or restart KOReader.

### Choosing the library folder

By default the library is your KOReader **home folder**. To use a different folder, go to ☰ → Library → **Library folder** and pick one. Sub-folders are scanned up to 10 levels deep. Hidden folders (names starting with `.`) and KOReader `.sdr` folders are skipped unless you turn on **Include hidden folders**.

## Uninstall

1. Delete the `plugins/library.koplugin` folder.
2. Restart KOReader.
3. Optional: remove the plugin's saved settings. With KOReader closed, open `settings.reader.lua` in KOReader's data folder and delete the `["library_plugin"] = { … },` block. If you leave it, nothing breaks; KOReader just ignores it.

The plugin never writes to your books or sidecar files, except when you use the status buttons on a long-press, which are the same buttons KOReader's own History uses. Nothing else needs to be cleaned up.

## Development

```
library.koplugin/
  _meta.lua         plugin name and description
  main.lua          KOReader UI: menu, views, dialogs, gestures
  librarycore.lua   scanning, metadata, sorting, grouping, search (no KOReader dependencies)
spec/
  run.lua           tiny test runner (LuaJIT / Lua 5.1)
  librarycore_spec.lua
  main_smoke_spec.lua   loads main.lua against stubbed KOReader modules
  fixtures/fake_library.lua   in-memory dummy library (public-domain titles only)
```

Run the tests from the repository root:

```sh
make test          # or: luajit spec/run.lua
```

Build a zip you can install:

```sh
make zip           # dist/library.koplugin.zip
```

The tests don't use real files or real device data. The fixture is an in-memory fake file system containing public-domain titles. `.gitignore` excludes books, `.sdr` folders and KOReader settings, history and cache files, so they can't be committed by accident.

## License

[MIT](LICENSE)
