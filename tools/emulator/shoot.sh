#!/usr/bin/env bash
# Run Library GUI under KOReader and write PNGs.
#
#   tools/emulator/shoot.sh <scenario>
#
# Scenarios: smoke, footer, az, aznav, toptap, and the README set
# (widgets, accordion, recently, shelf, bubble, menu, filters,
# brightness, startwith, gallery, readme).
# Output:    emulator-out/<scenario>/   (or $EMU_OUT)
#
# The current library.koplugin is copied into a temporary KOReader home.
# Point EMU_PLUGIN at another checkout to shoot that tree instead.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=config.sh
. "$HERE/config.sh"

scenario="${1:-}"
if [[ -z "$scenario" || "$scenario" == "-h" || "$scenario" == "--help" ]]; then
    echo "usage: tools/emulator/shoot.sh <smoke|footer|az|aznav|toptap|status|widgets|accordion|recently|shelf|bubble|menu|filters|brightness|startwith|controls|gestures|gesturemenu|update|gallery|readme>" >&2
    echo "  EMU_OUT     output directory (default: emulator-out/<scenario>)" >&2
    echo "  EMU_PLUGIN  library.koplugin to copy (default: ./library.koplugin)" >&2
    echo "  EMU_COUNT   books in the seeded library (default: 200)" >&2
    echo "  EMU_TIMEOUT seconds before KOReader is stopped (default: 180)" >&2
    echo "  EMU_HOME    KOReader HOME (default: a temp dir, removed on exit)" >&2
    exit 2
fi
case "$scenario" in
    smoke|footer|az|aznav|toptap|status|widgets|accordion|recently|shelf|bubble|menu|filters|brightness|startwith|controls|gestures|gesturemenu|update|azcolumn|azshort|footerbook|footerempty|coveronly|badges|gesturepages|gallery|readme) ;;
    *) echo "unknown scenario: $scenario" >&2; exit 2 ;;
esac

plugin="${EMU_PLUGIN:-$ROOT/library.koplugin}"
if [[ ! -f "$plugin/main.lua" ]]; then
    echo "no plugin at $plugin (expected main.lua)" >&2
    exit 1
fi
if ! command -v Xvfb >/dev/null; then
    echo "Xvfb is required. The SDL dummy driver in KOReader ${KOREADER_VERSION} is fixed at 600x800." >&2
    exit 1
fi

out="${EMU_OUT:-$ROOT/emulator-out/$scenario}"
case "$out" in
    /*) ;;
    *) out="$ROOT/$out" ;;
esac
rm -rf "$out"
mkdir -p "$out"

export KOREADER_CACHE_ROOT
prefix="$("$HERE/setup.sh")"
echo "koreader $prefix" >&2

keep_home=0
if [[ -n "${EMU_HOME:-}" ]]; then
    emu_home="$EMU_HOME"
    keep_home=1
    mkdir -p "$emu_home"
else
    emu_home="$(mktemp -d "${TMPDIR:-/tmp}/koreader-emu.XXXXXX")"
fi

display_num=""
xvfb_pid=""
cleanup() {
    if [[ -n "$xvfb_pid" ]] && kill -0 "$xvfb_pid" 2>/dev/null; then
        kill "$xvfb_pid" 2>/dev/null || true
        wait "$xvfb_pid" 2>/dev/null || true
    fi
    if [[ "$keep_home" -eq 0 ]]; then
        rm -rf "$emu_home"
    fi
}
trap cleanup EXIT

python3 "$HERE/seed.py" --home "$emu_home" --count "${EMU_COUNT:-200}" --seed "${EMU_SEED:-1}"

plugins="$emu_home/.config/koreader/plugins"
rm -rf "$plugins/library.koplugin" "$plugins/guiprobe.koplugin"
mkdir -p "$plugins/library.koplugin" "$plugins/guiprobe.koplugin"
cp -a "$plugin"/. "$plugins/library.koplugin/"
cp -a "$HERE/guiprobe.koplugin"/. "$plugins/guiprobe.koplugin/"
if [[ "$scenario" == "update" ]]; then
    # Latest on GitLab is v0.7.2. Report 0.7.1 so Check for updates offers it.
    # The committed _meta.lua is left as it is.
    sed -i 's/version = "0.7.2"/version = "0.7.1"/' "$plugins/library.koplugin/_meta.lua"
    if ! grep -q 'version = "0.7.1"' "$plugins/library.koplugin/_meta.lua"; then
        echo "could not stamp installed version 0.7.1" >&2
        exit 1
    fi
fi

display_num=99
while [[ -e "/tmp/.X${display_num}-lock" || -e "/tmp/.X11-unix/X${display_num}" ]]; do
    display_num=$((display_num + 1))
done
# Square enough for a rotation: the logical screen swaps width and height.
xvfb_side="$EMU_W"
if (( EMU_H > xvfb_side )); then xvfb_side="$EMU_H"; fi
xvfb_geom="$((xvfb_side + 64))x$((xvfb_side + 64))x24"
Xvfb ":$display_num" -screen 0 "$xvfb_geom" -nolisten tcp >"$out/xvfb.log" 2>&1 &
xvfb_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -e "/tmp/.X11-unix/X${display_num}" ]] && break
    sleep 0.2
done
if [[ ! -e "/tmp/.X11-unix/X${display_num}" ]]; then
    echo "Xvfb did not start; see $out/xvfb.log" >&2
    exit 1
fi

echo "running $scenario -> $out" >&2
set +e
local_timeout="${EMU_TIMEOUT:-180}"
case "$scenario" in
    readme|gallery) local_timeout="${EMU_TIMEOUT:-1200}" ;;
esac
env \
    HOME="$emu_home" \
    XDG_CONFIG_HOME="$emu_home/.config" \
    XDG_CACHE_HOME="$emu_home/.cache" \
    XDG_DATA_HOME="$emu_home/.local/share" \
    LC_ALL="en_US.UTF-8" \
    SDL_VIDEODRIVER="x11" \
    SDL_AUDIODRIVER="dummy" \
    SDL_RENDER_DRIVER="software" \
    DISPLAY=":$display_num" \
    EMULATE_READER_W="$EMU_W" \
    EMULATE_READER_H="$EMU_H" \
    EMULATE_READER_DPI="$EMU_DPI" \
    GUIPROBE_OUT="$out" \
    GUIPROBE_SCRIPT="$scenario" \
    GUIPROBE_TAG="${GUIPROBE_TAG:-}" \
    timeout "$local_timeout" "$prefix/bin/koreader" >"$out/koreader.log" 2>&1
rc=$?
set -e

if [[ -f "$emu_home/.config/koreader/crash.log" ]]; then
    cp "$emu_home/.config/koreader/crash.log" "$out/crash.log"
fi

python3 - "$out" "$scenario" "$EMU_W" "$EMU_H" "$rc" <<'PY'
import sys
from pathlib import Path
out, scenario, width, height, rc = sys.argv[1:]
width, height, rc = int(width), int(height), int(rc)
out = Path(out)
log = (out / "probe.log").read_text(encoding="utf-8", errors="replace") if (out / "probe.log").is_file() else ""
print(log, end="" if log.endswith("\n") or not log else "\n")
problems = []
if "DONE ok" not in log:
    problems.append("probe did not finish cleanly (koreader exit %d)" % rc)
try:
    from PIL import Image
except ImportError:
    Image = None
    problems.append("Pillow is not installed; PNG size was not checked")

def check(name, required):
    path = out / name
    if not path.is_file():
        if required:
            problems.append("missing " + name)
        return
    if Image is None:
        return
    im = Image.open(path)
    if im.size != (width, height):
        problems.append("%s is %dx%d, expected %dx%d" % (name, im.size[0], im.size[1], width, height))

if scenario == "smoke":
    check("smoke-library.png", True)
elif scenario == "footer":
    check("footer-page-label.png", True)
    check("footer-go-to-page.png", True)
    if "LONGPRESS ok" in log:
        check("footer-jump-last.png", True)
    elif "LONGPRESS unavailable" in log:
        print("long-press jump is not in this plugin build; footer-jump-last.png was not written")
    elif "LONGPRESS failed" in log or "footer-page-label.png" in log:
        problems.append("long-press did not jump to the last page (see probe.log)")
elif scenario == "az":
    for n in ("az-01-title-sort", "az-02-after-tap-M", "az-03-drag-bubble-T", "az-04-after-drag-T", "az-05-authors", "az-06-last-read-no-strip"):
        check(n + ".png", True)
elif scenario == "toptap":
    for n in ("toptap-01-library-gui-bar", "toptap-02-koreader-menu", "toptap-03-details-from-reader"):
        check(n + ".png", True)
elif scenario == "status":
    for n in (
        "status-icon-24", "status-compact-24", "status-plain-24",
        "status-icon-12", "status-compact-12", "status-plain-12",
        "status-icon-charging", "status-compact-charging",
        "status-icon-low", "status-compact-low",
        "status-icon-night",
    ):
        check(n + ".png", True)
elif scenario == "aznav":
    for n in ("aznav-compact", "aznav-authors", "aznav-grid", "aznav-series", "aznav-compact2", "aznav-last-read"):
        check(n + ".png", True)
else:
    expected = {
        "widgets": ["v050-widgets.png"],
        "accordion": ["v050-accordion.png"],
        "recently": ["v050-recently-added.png"],
        "shelf": ["v050-shelf-before.png", "v050-shelf-expanded.png"],
        "bubble": ["v050-az-bubble.png"],
        "menu": ["v050-menu.png"],
        "filters": ["v050-filters.png"],
        "brightness": ["v050-brightness.png"],
        "controls": ["09-controls-panel.png"],
        "startwith": ["v050-start-with.png"],
        "azcolumn": ["v050-az-column.png"],
        "azshort": ["v050-az-short.png"],
        "footerbook": ["v050-footer-book.png"],
        "footerempty": ["v050-footer-empty.png"],
        "coveronly": ["v070-cover-only.png"],
        "badges": ["v070-badges.png"],
        "gesturepages": ["v070-gestures.png", "v070-gesture-choices.png"],
        "update": ["update-menu.png", "update-prompt.png", "update-success.png"],
        "gallery": [
            "02-compact-2-columns.png", "03-compact.png", "20-recently-opened.png",
            "04-authors.png", "05-series.png", "06-search-typos.png", "07-sort-picker.png",
            "09-controls-panel.png", "10-genres.png", "11-genre-books.png", "19-go-to-page.png",
            "13-details-card.png", "14-details-card-none.png", "17-books-status-off.png",
            "12-reader-menu-library.png",
        ],
    }
    if scenario == "readme":
        names = []
        for key in ("widgets", "accordion", "recently", "shelf", "bubble", "menu", "filters", "brightness", "startwith", "azcolumn", "azshort", "footerbook", "footerempty", "coveronly", "badges", "gesturepages", "gallery"):
            names.extend(expected[key])
        expected["readme"] = names
    for name in expected.get(scenario, []):
        check(name, True)
if problems:
    print("shoot failed:", file=sys.stderr)
    for item in problems:
        print(" -", item, file=sys.stderr)
    sys.exit(1)
print("shoot ok", scenario, "->", out)
PY
