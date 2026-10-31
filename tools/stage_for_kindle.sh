#!/bin/sh
# Copy exactly the files that go to the Kindle into one staging folder and
# print their SHA-256 sums. Run on the Mac from the repository root.
# Usage: tools/stage_for_kindle.sh [STAGE_DIR]   (default: ~/kindle-stage)
set -eu
STAGE="${1:-$HOME/kindle-stage}"
case "$STAGE" in *,*) echo "STAGE_DIR must not contain a comma (mtp-connect splits on it)" >&2; exit 1;; esac
DEST="$STAGE/library.koplugin"
FILES="_meta.lua main.lua librarycore.lua libraryindex.lua libraryview.lua librarytile.lua librarycovers.lua librarykeyboard.lua librarycontrols.lua librarydetails.lua libraryreadermenu.lua libraryreaderpanel.lua librarybezel.lua librarysuggest.lua librarytiming.lua"
rm -rf "$DEST"
mkdir -p "$DEST"
for f in $FILES; do cp "library.koplugin/$f" "$DEST/$f"; done
cd "$DEST"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 $FILES; else sha256sum $FILES; fi
echo "Staged in $DEST"
