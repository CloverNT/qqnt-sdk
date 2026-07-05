#!/usr/bin/env bash
# Extracts just enough of a downloaded QQ installer (.exe) or package (.deb)
# to read its real x.x.xx-xxxxx version, so CI can name the release tag
# without anyone typing a version number.
# Usage: detect_version.sh <package-path> <windows|linux>
set -euo pipefail

PKG="${1:?package path required}"
PLATFORM="${2:?platform required: windows|linux}"
WORK="${QQ_WORK:-./.qqwork}/detect"
rm -rf "$WORK"; mkdir -p "$WORK"

find_7z() {
  for c in "/c/Program Files/7-Zip/7z.exe" "/c/Program Files (x86)/7-Zip/7z.exe"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  command -v 7z 2>/dev/null && return
  command -v 7za 2>/dev/null && return
}

pkg_version_from_json() {
  local pj
  pj="$(find "$1" -type f -path '*/resources/app/package.json' 2>/dev/null | head -n1 || true)"
  [ -z "$pj" ] && return
  grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$pj" \
    | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -n1 || true
}

VER=""
case "$PLATFORM" in
  windows)
    SEVENZIP="$(find_7z)"
    [ -z "$SEVENZIP" ] && { echo "::error::7-Zip (7z/7za) not found" >&2; exit 1; }
    echo "==> Extracting $PKG (7z: $SEVENZIP)"
    "$SEVENZIP" x -y -bd "-o${WORK}" "$PKG" >/dev/null 2>&1 || "$SEVENZIP" x -y -bd "-o${WORK}" "$PKG" || true
    while IFS= read -r -d '' inner; do
      "$SEVENZIP" x -y -bd "-o${inner}.d" "$inner" >/dev/null 2>&1 || true
    done < <(find "$WORK" -type f \( -iname '*.7z' -o -iname '*.zip' \) -print0 2>/dev/null)

    VER="$(find "$WORK" -type d -regextype posix-extended \
          -regex '.*/versions/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' -printf '%f\n' 2>/dev/null \
          | sort -V | tail -n1)"
    [ -z "$VER" ] && VER="$(pkg_version_from_json "$WORK")"
    ;;
  linux)
    ROOT="$WORK/root"; mkdir -p "$ROOT"
    PKG_ABS="$(readlink -f "$PKG" 2>/dev/null || realpath "$PKG")"
    echo "==> Extracting $PKG"
    if command -v dpkg-deb >/dev/null 2>&1; then
      dpkg-deb -x "$PKG_ABS" "$ROOT"
    elif command -v ar >/dev/null 2>&1; then
      ( cd "$WORK" && ar x "$PKG_ABS" )
      data="$(find "$WORK" -maxdepth 1 -name 'data.tar.*' | head -n1 || true)"
      [ -z "$data" ] && { echo "::error::no data.tar in deb" >&2; exit 1; }
      tar -xf "$data" -C "$ROOT"
    else
      echo "::error::need dpkg-deb or ar to inspect the .deb" >&2; exit 1
    fi
    VER="$(pkg_version_from_json "$ROOT")"
    ;;
  *)
    echo "::error::unknown platform: $PLATFORM (expected windows|linux)" >&2; exit 1 ;;
esac

if [ -z "$VER" ]; then
  echo "::error::could not detect QQ version from $PKG. Extracted tree:" >&2
  find "$WORK" -maxdepth 6 -type d | head -n 60 >&2
  exit 1
fi

echo "==> detected version: $VER"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "version=$VER" >> "$GITHUB_OUTPUT"
echo "$VER"
