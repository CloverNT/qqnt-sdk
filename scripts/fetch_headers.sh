#!/usr/bin/env bash
# Detects the Electron version QQ NT embeds and downloads Electron's matching
# node/V8 headers (not stock nodejs.org - QQNT's V8 is electron-patched) into
# <sdk-out-dir>/include/QQNT. Honors $CURL_OPTS.
# Usage: fetch_headers.sh <binary-to-scan> <sdk-out-dir>
set -euo pipefail

BIN="${1:?binary to scan required}"
OUT="${2:?sdk out dir required}"
WORK="${QQ_WORK:-./.qqwork}/hdr"

EV="$(grep -aoE 'Electron/[0-9]+\.[0-9]+\.[0-9]+' "$BIN" 2>/dev/null | head -n1 | cut -d/ -f2 || true)"
if [ -z "$EV" ] && command -v node >/dev/null 2>&1; then
  EV="$(node -e 'const b=require("fs").readFileSync(process.argv[1]);for(const e of ["latin1","utf16le"]){const m=b.toString(e).match(/Electron\/([0-9]+\.[0-9]+\.[0-9]+)/);if(m){process.stdout.write(m[1]);break}}' "$BIN" 2>/dev/null || true)"
fi
[ -z "$EV" ] && { echo "::error::could not detect Electron version from $BIN" >&2; exit 1; }
echo "==> QQNT embeds Electron $EV"

NODEV=""; V8V=""
if command -v node >/dev/null 2>&1; then
  info="$(curl -fsSL ${CURL_OPTS:-} --retry 3 --retry-all-errors --connect-timeout 20 "https://releases.electronjs.org/releases.json" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const r=JSON.parse(s);const e=r.find(x=>x.version===process.argv[1]);process.stdout.write(e?(e.node+" "+e.v8):"")}catch{}})' "$EV" 2>/dev/null || true)"
  NODEV="${info%% *}"; V8V="${info##* }"
fi

url="https://artifacts.electronjs.org/headers/dist/v${EV}/node-v${EV}-headers.tar.gz"
echo "==> $url"
rm -rf "$WORK"; mkdir -p "$WORK"
curl -fSL ${CURL_OPTS:-} --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 -o "$WORK/headers.tgz" "$url"
tar -xzf "$WORK/headers.tgz" -C "$WORK"

src="$(find "$WORK" -type d -path '*/include/node' | head -n1 || true)"
[ -z "$src" ] && { echo "::error::include/node not found in headers tarball" >&2; exit 1; }
mkdir -p "$OUT/include"
rm -rf "$OUT/include/QQNT"
cp -r "$src" "$OUT/include/QQNT"
nhdr="$(find "$OUT/include/QQNT" -name '*.h' | wc -l)"
echo "==> headers -> $OUT/include/QQNT ($nhdr .h files)"

{
  echo "electron=$EV"
  echo "node=${NODEV:-unknown}"
  echo "v8=${V8V:-unknown}"
  echo "headers=include/QQNT (use as <QQNT/node.h>, <QQNT/node_api.h>, <QQNT/v8.h>, ...)"
} >> "$OUT/manifest.txt"
