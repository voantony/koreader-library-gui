# kpush: copy files between a Mac and a Kindle Colorsoft over USB

A small command-line tool that copies files to and from a Kindle Colorsoft
(1st gen) over MTP, one session per run. It **leaves the USB connection up when
it finishes**: the Kindle doesn't drop off and reconnect.

**Status: experimental, single device.** Built and tested on a Mac (macOS 27,
libmtp 1.1.23 from Homebrew) with one Kindle Colorsoft (1st gen). `check`, `ls`,
and `pull` of single files and a whole folder all worked with no USB drop.
`push` is the same code as the earlier version, which copied files to that
Kindle the same way.

## Build (Homebrew)

```sh
brew install libmtp
P=$(brew --prefix libmtp)
clang -O2 -Wall -o kpush kpush.c -I$P/include -L$P/lib -lmtp
```

kpush only runs against libmtp **1.1.23** and refuses to start with any other
version (see "Why it exists").

## Use

**Quit Calibre first** (and Android File Transfer, OpenMTP, or anything else
that talks to the Kindle). Only one app can hold the Kindle at a time. If it's
busy, kpush says so and stops. It doesn't retry, and it never resets USB.

```sh
./kpush check                                   # connect, identify, disconnect; writes nothing
./kpush ls                                      # list the Kindle's top folder
./kpush ls /documents                           # list a folder: type, size, date, name
./kpush push /koreader/plugins/library.koplugin library.koplugin/*.lua
./kpush /koreader/plugins/library.koplugin *.lua    # same; "push" is optional
./kpush pull /koreader/plugins/library.koplugin     # copy a folder to ~/Kindle-files
./kpush pull /documents/book.epub ~/Desktop         # copy one file somewhere else
./kpush pull --open --overwrite /documents/book.epub
./kpush --help
```

- **push** copies Mac files into a Kindle folder. It creates missing subfolders
  but never a new top-level folder, replaces same-named files in that folder,
  and finishes by listing the folder.
- **ls** lists a folder, defaulting to `/`.
- **pull** copies a file or a whole folder to the Mac. The default destination
  is `~/Kindle-files`. Each file is written to a `.kpullpart` temp file, its
  size is checked against the Kindle's, and then it's renamed into place.
  Files already on the Mac are skipped unless you pass `--overwrite`. `--open`
  opens the destination in Finder when it's done.
- **check** connects, prints the model, and disconnects without writing
  anything. `--check` also works.

Unknown commands or options are refused (exit code 2). Put `--` before Mac
file names that start with `-`.

**There's no delete, rename or move command, by design.** The only time
kpush removes anything is when push replaces a file of the same name in its
target folder. That goes through a single guarded delete that refuses the root
and folder IDs.

**Serial redaction.** Everything kpush and libmtp print goes through a filter
that masks anything that looks like a Kindle serial number (`G` followed by
three or more capital letters or digits), so output is safe to paste.

Want the Kindle as a normal drive in Finder instead? See
[kindle-mtp-mount](https://github.com/voantony/kindle-mtp-mount).

Exit codes: 0 ok, 1 some files failed, 2 usage error, 3 no device / busy,
4 path not found or refused, 5 safety check failed, 6 wrong libmtp version.

## Why it exists

libmtp 1.1.23 lists the Colorsoft's USB ID (`1949:9981`) as "Kindle Scribe 32GB"
with `DEVICE_FLAGS_ANDROID_BUGS`. That set includes `DEVICE_FLAG_FORCE_RESET_ON_CLOSE`,
so `mtp-connect` and friends call `libusb_reset_device()` on close. The Kindle then drops
off USB and re-enumerates. libmtp also adds the Android flags back after open when the
device reports the `android.com` MTP extension.

kpush does three things differently:

- It matches the device by USB ID and never uses libmtp's label for it.
- It clears the reset flag on the raw device before opening.
- It clears the flag again on the open device, both after open and before release.

Reaching the open device's flags needs a mirror of libmtp's internal `PTP_USB` struct.
That mirror has been checked against the 1.1.23 headers (same offset, 88, and the same
size, 128, on arm64). For safety, kpush refuses to run with any other libmtp version,
or with any device other than `1949:9981`.

It can't prevent one case. If an earlier session was cut off mid-transfer, libmtp resets
once when it reopens.
