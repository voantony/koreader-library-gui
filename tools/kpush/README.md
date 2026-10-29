# kpush: copy files to a Kindle Colorsoft from a Mac over USB

A small command-line tool that copies files to a Kindle Colorsoft (1st gen) over MTP
in a single session. It **leaves the USB connection up when it finishes**.

**Status: experimental. It has been built, but not yet run against a Kindle.**

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

## Build (Homebrew)

```sh
brew install libmtp
P=$(brew --prefix libmtp)
clang -O2 -Wall -o kpush kpush.c -I$P/include -L$P/lib -lmtp
```

## Use

```sh
./kpush --check                     # connect, identify, disconnect; writes nothing
./kpush /koreader/plugins/library.koplugin library.koplugin/*.lua
```

It creates missing folders by name and replaces same-named files (it only deletes files,
never folders). At the end it lists the target folder.

Close Android File Transfer, OpenMTP and similar apps first, because only one app
can hold the device at a time.
