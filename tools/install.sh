#!/usr/bin/env bash
# Install or update Library GUI (library.koplugin) for KOReader.
#
#   curl -fsSL https://gitlab.com/antonyvo/koreader-library-gui/-/raw/main/tools/install.sh | bash
#
# A mounted Kindle (Finder, or kindle-mtp-mount) is a folder
# /Volumes/*/koreader/plugins. KOREADER_VOLUMES overrides that root so
# the same script can be tried against a fake mount. Settings are never
# touched. macOS bash 3.2: no associative arrays, shasum rather than sha256sum.
set -euo pipefail

PROJECT="antonyvo%2Fkoreader-library-gui"
API="https://gitlab.com/api/v4/projects/${PROJECT}"
VOLUMES_ROOT="${KOREADER_VOLUMES:-/Volumes}"

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"
command -v unzip >/dev/null 2>&1 || die "unzip is required"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/library-gui.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

if ! curl -fsSL "${API}/releases/permalink/latest" -o "${tmpdir}/release.json"; then
    say "The latest-release link failed. Trying the releases list."
    curl -fsSL "${API}/releases?per_page=1" -o "${tmpdir}/release.json"
fi

# head closes the pipe early; `|| true` keeps pipefail from aborting on SIGPIPE.
tag=$(grep -o '"tag_name":"v\{0,1\}[0-9][0-9.]*"' "${tmpdir}/release.json" | head -n 1 || true)
version=$(printf '%s\n' "${tag}" | sed -n 's/.*"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p')
[ -n "${version}" ] || die "could not read the latest version"

url=$(grep -o "https://gitlab.com/api/v4/projects/[0-9][0-9]*/packages/generic/library-gui/${version}/library.koplugin-v${version}\\.zip" "${tmpdir}/release.json" | head -n 1 || true)
[ -n "${url}" ] || die "the release has no library.koplugin-v${version}.zip asset"

sha=$(grep -o 'SHA256[^0-9A-Fa-f]*[0-9A-Fa-f]\{64\}' "${tmpdir}/release.json" | head -n 1 | grep -o '[0-9A-Fa-f]\{64\}' | tr '[:upper:]' '[:lower:]' || true)
[ -n "${sha}" ] || die "the release notes have no SHA256 line. Nothing was installed."

say "Downloading Library GUI ${version}"
curl -fsSL -o "${tmpdir}/plugin.zip" "${url}"
got=$(shasum -a 256 "${tmpdir}/plugin.zip" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
if [ "${got}" != "${sha}" ]; then
    die "SHA256 mismatch (download ${got}, published ${sha}). Nothing was installed."
fi

mkdir -p "${tmpdir}/extracted"
unzip -q -o "${tmpdir}/plugin.zip" -d "${tmpdir}/extracted"
[ -f "${tmpdir}/extracted/library.koplugin/main.lua" ] || die "the zip has no library.koplugin/main.lua"

install_into() {
    plugins="$1"
    dest="${plugins}/library.koplugin"
    bak="${plugins}/library.koplugin.bak"
    case "${dest}" in
        */koreader/plugins/library.koplugin) ;;
        *) die "refusing to write outside koreader/plugins (${dest})" ;;
    esac
    case "${dest}" in
        */koreader/settings|*/koreader/settings/*)
            die "refusing to touch koreader/settings"
            ;;
    esac
    if [ -d "${dest}" ]; then
        rm -rf "${bak}"
        cp -R "${dest}" "${bak}"
    fi
    rm -rf "${dest}"
    if ! cp -R "${tmpdir}/extracted/library.koplugin" "${dest}"; then
        if [ -d "${bak}" ]; then
            rm -rf "${dest}"
            cp -R "${bak}" "${dest}" || die "install failed and the backup could not be restored"
            die "install failed. The previous plugin was restored from library.koplugin.bak."
        fi
        die "install failed while copying into ${dest}"
    fi
    say "Installed Library GUI ${version} into ${dest}"
    if [ -d "${bak}" ]; then
        say "The previous copy is ${bak}."
    fi
    say "Restart KOReader (the menu, then Exit, then Restart KOReader)."
}

shopt -s nullglob
mounted=("${VOLUMES_ROOT}"/*/koreader/plugins)
shopt -u nullglob

if [ "${#mounted[@]}" -gt 0 ]; then
    for plugins in "${mounted[@]}"; do
        if [ -d "${plugins}" ]; then
            install_into "${plugins}"
        fi
    done
    exit 0
fi

if command -v kpush >/dev/null 2>&1; then
    say "No Kindle volume is mounted. Copying with kpush."
    files=()
    for f in "${tmpdir}/extracted/library.koplugin"/*; do
        if [ -f "${f}" ]; then
            files+=("${f}")
        fi
    done
    if [ "${#files[@]}" -eq 0 ]; then
        die "the zip has no plugin files"
    fi
    if kpush push /koreader/plugins/library.koplugin "${files[@]}"; then
        say "Installed Library GUI ${version} with kpush."
        say "kpush replaces those files in place. It does not write library.koplugin.bak on the Kindle."
        say "Restart KOReader (the menu, then Exit, then Restart KOReader)."
        exit 0
    fi
    say "kpush failed."
fi

keep="${HOME}/Downloads/library.koplugin-v${version}.zip"
if ! mkdir -p "${HOME}/Downloads" 2>/dev/null; then
    keep="${HOME}/library.koplugin-v${version}.zip"
fi
cp "${tmpdir}/plugin.zip" "${keep}"
say "No Kindle volume was found under ${VOLUMES_ROOT}/*/koreader/plugins, and kpush is not on PATH."
say "The verified zip is ${keep}."
say "Unzip it and copy the library.koplugin folder into koreader/plugins/ on the device."
say "Leave koreader/settings as it is. Then restart KOReader."
exit 0
