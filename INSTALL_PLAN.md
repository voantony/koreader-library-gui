# Install plan: Kindle Colorsoft over MTP (from the Mac)

The target is `/mnt/us/koreader/plugins/library.koplugin/` on a jailbroken Kindle Colorsoft running KOReader v2026.07.1 with Project: Title, connected over USB (MTP) to a Mac with libmtp installed. The Kindle drops off USB after every libmtp command, so all the file copies go in **one** `mtp-connect` run.

Nothing in this plan changes the Kindle outside `koreader/plugins/library.koplugin/`. The only extra file is the plugin's own cache, `koreader/settings/library_index.lua`, which KOReader creates later.

## What gets copied

Six files, all from `library.koplugin/` in this repository. Copy nothing else: `tools/librarybench.koplugin` is a development benchmark and must never go on the device.

| Local (Mac) | Kindle |
|---|---|
| `~/kindle-stage/library.koplugin/_meta.lua` | `/mnt/us/koreader/plugins/library.koplugin/_meta.lua` |
| `~/kindle-stage/library.koplugin/main.lua` | `/mnt/us/koreader/plugins/library.koplugin/main.lua` |
| `~/kindle-stage/library.koplugin/librarycore.lua` | `/mnt/us/koreader/plugins/library.koplugin/librarycore.lua` |
| `~/kindle-stage/library.koplugin/libraryindex.lua` | `/mnt/us/koreader/plugins/library.koplugin/libraryindex.lua` |
| `~/kindle-stage/library.koplugin/libraryview.lua` | `/mnt/us/koreader/plugins/library.koplugin/libraryview.lua` |
| `~/kindle-stage/library.koplugin/librarytile.lua` | `/mnt/us/koreader/plugins/library.koplugin/librarytile.lua` |

Over MTP the Kindle's storage root is `/mnt/us`, so `/mnt/us/koreader/plugins` appears as **`/koreader/plugins`** in libmtp paths. This is the same folder Project: Title was copied into.

## 0. Prepare on the Mac (no Kindle needed)

From a checkout of this repository:

```sh
tools/stage_for_kindle.sh ~/kindle-stage     # copies the 6 files, prints SHA-256 sums
```

Compare the printed sums with `dist/SHA256SUMS` from the same commit. The stage path must not contain a comma, because `mtp-connect` splits `source,destination` on the first comma. With the default path you don't need to quote anything.

## 1. Prepare the Kindle

1. In KOReader, check that Project: Title is enabled (☰ → Tools → More tools → Plugin management). The covers come from its cache.
2. Exit KOReader to the Kindle home screen, so KOReader isn't running while files change.
3. Plug in the USB cable.

## 2. Copy

`mtp-connect` reads the device's folder list **once**, when it connects (libmtp `examples/connect.c`). If a folder is created during a run, a `--sendfile` later in the same run cannot find it and prints *"Parent folder could not be found, skipping"*. So you can't create a folder and fill it in the same run. Use whichever case below applies.

### 2a. First install: `library.koplugin` does not exist on the Kindle yet

This takes one tiny run to create the folder (it copies nothing), then the one bundled run with every file:

```sh
# Connection 1: create the empty plugin folder
mtp-connect --newfolder /koreader/plugins/library.koplugin
```

Re-plug or reconnect the Kindle, then:

```sh
# Connection 2: the bundled copy, one session, all six files
S=~/kindle-stage/library.koplugin
D=/koreader/plugins/library.koplugin
mtp-connect \
  --sendfile "$S/_meta.lua,$D" \
  --sendfile "$S/main.lua,$D" \
  --sendfile "$S/librarycore.lua,$D" \
  --sendfile "$S/libraryindex.lua,$D" \
  --sendfile "$S/libraryview.lua,$D" \
  --sendfile "$S/librarytile.lua,$D"
```

The destination of `--sendfile` is the **folder**; the file name comes from the source. You should see six lines saying *"New file ID: …"*. If any line says *"Parent folder could not be found, skipping"*, the folder wasn't created; repeat Connection 1.

If you want a single connection for a first install, copy the staged `library.koplugin` folder into `koreader/plugins/` with OpenMTP.app instead. OpenMTP is already on the Mac, and it creates the folder and copies the files in one connection.

### 2b. Updating an existing install

Re-sending a file whose name already exists over MTP can leave two objects with the same name, so delete the old files first and then send the new ones, in one run:

```sh
S=~/kindle-stage/library.koplugin
D=/koreader/plugins/library.koplugin
mtp-connect \
  --delete $D/_meta.lua --delete $D/main.lua --delete $D/librarycore.lua \
  --delete $D/libraryindex.lua --delete $D/libraryview.lua --delete $D/librarytile.lua \
  --sendfile "$S/_meta.lua,$D" --sendfile "$S/main.lua,$D" \
  --sendfile "$S/librarycore.lua,$D" --sendfile "$S/libraryindex.lua,$D" \
  --sendfile "$S/libraryview.lua,$D" --sendfile "$S/librarytile.lua,$D"
```

> **Never pass `--delete` a path that might not exist.** If libmtp can't find the path it gets `-1` (`0xFFFFFFFF`), and `mtp-connect` sends that to the device as the object to delete without checking. In MTP, `0xFFFFFFFF` means *all objects*. Use 2b only if every one of those six files is on the Kindle, for example after a successful 2a. If you're not sure, check first with a read-only `mtp-filetree` run, or use OpenMTP.

## 3. Turn it on (on the Kindle)

1. Unplug and start KOReader.
2. ☰ (file browser) → **Library** → **Open Library**. If **Library** is missing from the menu, enable it under Tools → More tools → Plugin management and restart KOReader.
3. The first open builds the index. It should take a moment on 1,000 books, and later opens use the cache. Any covers that Project: Title hasn't extracted yet fill in by themselves.
4. To make it your start screen: ☰ → Library → **Open Library at startup**. Closing the Library with ✕ always takes you to the normal file browser.

## Uninstall

### A. On the Kindle (recommended: no USB, nothing can be deleted by mistake)

1. ☰ → Library → untick **Open Library at startup**.
2. ☰ → Tools → More tools → Plugin management → untick **Library** → restart KOReader. The plugin is now inactive. Ticking it again undoes this step.
3. To remove the files, in KOReader's file browser go to `/mnt/us/koreader/plugins/`, long-press `library.koplugin` → **Delete**. Then go to `/mnt/us/koreader/settings/`, long-press `library_index.lua` → **Delete**.

### B. Over MTP, in one `mtp-connect` run

Only do this when the files below exist; the warning in 2b applies. Remove `library_index.lua` from the command if you never opened the Library.

```sh
D=/koreader/plugins/library.koplugin
mtp-connect \
  --delete $D/_meta.lua --delete $D/main.lua --delete $D/librarycore.lua \
  --delete $D/libraryindex.lua --delete $D/libraryview.lua --delete $D/librarytile.lua \
  --delete $D \
  --delete /koreader/settings/library_index.lua
```

The folder is deleted last, once it is empty.

### What remains after uninstalling

KOReader's `settings.reader.lua` keeps a small `["library_plugin"] = { … }` block with your Library settings. Without the plugin KOReader ignores it. It disappears if you delete it by hand while KOReader is closed; otherwise leave it. Book sidecars and the Project: Title cover cache are unchanged; the plugin only added covers that Project: Title would have extracted anyway.
