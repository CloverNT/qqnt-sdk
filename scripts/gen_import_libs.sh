#!/usr/bin/env bash
# Extracts a QQ NT Windows installer, detects its version, builds an MSVC
# import lib for each PE target, and bundles the matching Node/Electron headers.
# Usage: gen_import_libs.sh <installer.exe> <outroot> <arch:x64|arm64> <t1,t2,...>
set -euo pipefail

INSTALLER="${1:?installer path required}"
OUTROOT="${2:?output root required}"
ARCH="${3:-x64}"
TARGETS="${4:-QQ.exe,QQNT.dll,wrapper.node}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="${QQ_WORK:-./.qqwork}/extract"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT" "$OUTROOT"

find_7z() {
  for c in "/c/Program Files/7-Zip/7z.exe" "/c/Program Files (x86)/7-Zip/7z.exe"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  command -v 7z 2>/dev/null && return
  command -v 7za 2>/dev/null && return
  echo "::error::7-Zip not found" >&2; exit 1
}
SEVENZIP="$(find_7z)"
echo "Using 7-Zip: $SEVENZIP"

echo "==> Extracting $INSTALLER"
"$SEVENZIP" x -y -bd "-o${EXTRACT}" "$INSTALLER" >/dev/null 2>&1 || \
  "$SEVENZIP" x -y -bd "-o${EXTRACT}" "$INSTALLER" || true
while IFS= read -r -d '' inner; do
  echo "    nested archive: $inner"
  "$SEVENZIP" x -y -bd "-o${inner}.d" "$inner" >/dev/null 2>&1 || true
done < <(find "$EXTRACT" -type f \( -iname '*.7z' -o -iname '*.zip' \) -print0 2>/dev/null)

detect_version() {
  local v
  v="$(find "$EXTRACT" -type d -regextype posix-extended \
        -regex '.*/versions/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' -printf '%f\n' 2>/dev/null \
        | sort -V | tail -n1)"
  if [ -z "$v" ]; then
    local pj; pj="$(find "$EXTRACT" -type f -path '*/resources/app/package.json' 2>/dev/null | head -n1 || true)"
    [ -n "$pj" ] && v="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$pj" \
        | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -n1 || true)"
  fi
  echo "$v"
}
VER="$(detect_version)"
if [ -z "$VER" ]; then
  echo "::error::could not detect QQ version from the installer. Extracted dirs:" >&2
  find "$EXTRACT" -maxdepth 4 -type d | head -n 60 >&2
  exit 1
fi
FOLDER="qqnt-sdk-${VER}-windows-${ARCH}"
OUTDIR="$OUTROOT/$FOLDER"
LIBDIR="$OUTDIR/lib"
mkdir -p "$LIBDIR"
echo "==> Detected version $VER  ->  $FOLDER"

case "$ARCH" in
  x64)   MACHINE=X64 ;;
  arm64) MACHINE=ARM64 ;;
  *)     echo "::error::unsupported arch: $ARCH" >&2; exit 1 ;;
esac
LIB_EXE="$(command -v lib.exe || command -v lib || true)"
[ -z "$LIB_EXE" ] && { echo "::error::MSVC lib.exe not on PATH — add the 'ilammy/msvc-dev-cmd' step" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "::error::node not on PATH (needed to read PE exports)" >&2; exit 1; }

find_target() {
  local name="$1"
  find "$EXTRACT" -type f -iname "$name" -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -n1 | cut -f2- || true
}

MANIFEST="$OUTDIR/manifest.txt"
{ echo "version=$VER"; echo "system=windows"; echo "arch=$ARCH"; echo "tool=msvc-lib"; } > "$MANIFEST"
made=0; missing=()

IFS=',' read -ra LIST <<< "$TARGETS"
for raw in "${LIST[@]}"; do
  target="$(echo "$raw" | xargs)"; [ -z "$target" ] && continue
  file_path="$(find_target "$target")"
  if [ -z "$file_path" ]; then
    echo "::warning::target not found in installer: $target"; missing+=("$target"); continue
  fi
  base="${target%.*}"
  echo "==> $target  ->  $file_path"; file "$file_path" || true
  def="$LIBDIR/${base}.def"; lib="$LIBDIR/${base}.lib"
  node "$SCRIPT_DIR/pe_to_def.mjs" "$file_path" "$target" "$def"
  # MSYS2_ARG_CONV_EXCL: stop Git Bash from mangling lib.exe's /flag arguments.
  MSYS2_ARG_CONV_EXCL='*' "$LIB_EXE" /nologo "/def:$def" "/out:$lib" "/machine:$MACHINE"
  rm -f "$LIBDIR/${base}.exp"
  sz=$(stat -c '%s' "$lib" 2>/dev/null || echo '?')
  echo "    -> lib/$(basename "$lib") (${sz} bytes), lib/$(basename "$def")"
  echo "target=$target source=$file_path def=lib/$(basename "$def") importlib=lib/$(basename "$lib") (${sz}B)" >> "$MANIFEST"
  made=$((made+1))
done

if [ "$made" -eq 0 ]; then
  echo "::error::No targets found in the installer. Tree:" >&2
  find "$EXTRACT" -maxdepth 4 -type f | head -n 100 >&2
  exit 1
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "MISSING (no PE found): ${missing[*]}" >> "$MANIFEST"
  echo "::warning::Requested targets not found: ${missing[*]}"
fi

# Electron version lives in QQNT.dll; fall back to the largest .dll.
hdrbin="$(find "$EXTRACT" -iname QQNT.dll | head -n1 || true)"
[ -z "$hdrbin" ] && hdrbin="$(find "$EXTRACT" -type f -iname '*.dll' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2- || true)"
[ -z "$hdrbin" ] && { echo "::error::no binary found to detect Electron version" >&2; exit 1; }
bash "$SCRIPT_DIR/fetch_headers.sh" "$hdrbin" "$OUTDIR"

echo "==> SDK ready: $OUTDIR"
ls -lR "$OUTDIR" | head -n 40 || true
