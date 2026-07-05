#!/usr/bin/env bash
# Unpacks a QQ NT Linux .deb (or .AppImage), detects its version, copies out
# the native objects (qq, wrapper.node), and bundles matching Electron headers.
# Usage: extract_linux.sh <package> <outroot> <arch:x64|arm64>
set -euo pipefail

PKG="${1:?package path required}"
OUTROOT="${2:?output root required}"
ARCH="${3:-x64}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${QQ_WORK:-./.qqwork}"
ROOT="$WORK/root"
rm -rf "$WORK"
mkdir -p "$ROOT" "$OUTROOT"
PKG_ABS="$(readlink -f "$PKG" 2>/dev/null || realpath "$PKG")"

find_7z() {
  for c in "/c/Program Files/7-Zip/7z.exe" "/c/Program Files (x86)/7-Zip/7z.exe"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  command -v 7z 2>/dev/null && return
  command -v 7za 2>/dev/null && return
}

echo "==> Unpacking $PKG"
case "$PKG" in
  *.deb)
    if command -v dpkg-deb >/dev/null 2>&1; then
      dpkg-deb -x "$PKG_ABS" "$ROOT"
    elif command -v ar >/dev/null 2>&1; then
      ( cd "$WORK" && ar x "$PKG_ABS" )
      data="$(find "$WORK" -maxdepth 1 -name 'data.tar.*' | head -n1 || true)"
      tar -xf "$data" -C "$ROOT"
    else
      sz="$(find_7z)"; [ -z "$sz" ] && { echo "::error::need dpkg-deb, ar, or 7-Zip" >&2; exit 1; }
      "$sz" x -y "-o${WORK}/ar" "$PKG_ABS" >/dev/null
      data="$(find "$WORK/ar" -maxdepth 1 -name 'data.tar.*' | head -n1 || true)"
      [ -z "$data" ] && { echo "::error::no data.tar in deb" >&2; exit 1; }
      tar -xf "$data" -C "$ROOT"
    fi
    ;;
  *.AppImage|*.appimage)
    chmod +x "$PKG_ABS"
    ( cd "$WORK" && "$PKG_ABS" --appimage-extract >/dev/null )
    ;;
  *)
    echo "::error::unsupported package type: $PKG" >&2; exit 1 ;;
esac

PJ="$(find "$WORK" -type f -path '*/resources/app/package.json' 2>/dev/null | head -n1 || true)"
VER=""
[ -n "$PJ" ] && VER="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PJ" \
    | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -n1 || true)"
if [ -z "$VER" ]; then
  echo "::error::could not detect QQ version (no resources/app/package.json). Tree:" >&2
  find "$WORK" -maxdepth 7 -type f -name package.json | head -n 40 >&2
  exit 1
fi
FOLDER="qqnt-sdk-${VER}-linux-${ARCH}"
OUTDIR="$OUTROOT/$FOLDER"
LIBDIR="$OUTDIR/lib"
mkdir -p "$LIBDIR"
echo "==> Detected version $VER  ->  $FOLDER"

find_one() {
  local name="$1"
  find "$WORK" -type f -name "$name" -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -n1 | cut -f2- || true
}

declare -A WANT=( [qq]=qq [wrapper.node]=wrapper.node )

MANIFEST="$OUTDIR/manifest.txt"
{ echo "version=$VER"; echo "system=linux"; echo "arch=$ARCH"; } > "$MANIFEST"
copied=0; missing=(); QQBIN=""

for name in qq wrapper.node; do
  src="$(find_one "$name")"
  if [ -z "$src" ]; then
    echo "::warning::not found: $name"; missing+=("$name"); continue
  fi
  [ "$name" = "qq" ] && QQBIN="$src"
  dst="$LIBDIR/${WANT[$name]:-$name}"
  cp -L "$src" "$dst"
  desc="$(file -b "$dst" 2>/dev/null || echo unknown)"
  sz="$(stat -c '%s' "$dst" 2>/dev/null || echo '?')"
  echo "==> $name -> lib/$(basename "$dst") (${sz} bytes): $desc"
  echo "file=lib/$(basename "$dst") source=$src (${sz}B) type=$desc" >> "$MANIFEST"
  copied=$((copied+1))
done

if [ "$copied" -eq 0 ]; then
  echo "::error::No expected files found. Tree:" >&2
  find "$WORK" -maxdepth 7 -type f | head -n 80 >&2
  exit 1
fi
[ "${#missing[@]}" -gt 0 ] && {
  echo "MISSING: ${missing[*]}" >> "$MANIFEST"
  echo "::warning::missing: ${missing[*]}"
}

[ -z "$QQBIN" ] && QQBIN="$(find_one qq)"
[ -z "$QQBIN" ] && { echo "::error::could not find the qq binary to detect Electron version" >&2; exit 1; }
bash "$SCRIPT_DIR/fetch_headers.sh" "$QQBIN" "$OUTDIR"

echo "==> SDK ready: $OUTDIR"
ls -lR "$OUTDIR" | head -n 40 || true
exit 0
