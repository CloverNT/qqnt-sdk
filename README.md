# qq_lib_autogen

A GitHub Actions pipeline you trigger manually — paste an official QQ download
link — that publishes a **QQNT SDK** as a GitHub Release: `.zip` packages for
**Windows x64/arm64** and **Linux x64/arm64**, each with linkable libs **and**
matching Node/Electron headers.

- **Windows libs**: reads each PE's exports into a `.def` and runs MSVC
  `lib.exe` to produce a genuine import library: `QQ.exe`→`QQ.lib`,
  `QQNT.dll`→`QQNT.lib`, `wrapper.node`→`wrapper.lib`.
- **Linux libs**: native ELF objects (`qq`, `wrapper.node`) that link directly.
- **Headers**: the embedded Electron version is detected from the binary, and
  that Electron's Node headers are bundled (its `v8.h` matches QQNT's
  electron-patched V8 — stock nodejs.org headers would not).
- **Version**: nobody types one — `detect-version` reads the real
  `x.x.xx-xxxxx` version out of the installer, and that becomes the release
  tag `qq-<version>`.

## Why manual?

QQ's download config is geo-gated (only China IPs get the latest) and its URLs
carry an unguessable per-build hash, so CI can't auto-discover a link. You
paste the official link from <https://im.qq.com>; the bytes then download fine
from any region.

## Triggering a build

Actions → *Build QQ NT libs* → *Run workflow*:

- `win_url` — an official QQ Windows installer link (any arch). Blank = skip Windows.
- `linux_url` — an official QQ Linux `.deb` link (any arch). Blank = skip Linux.
- `force` — rebuild even if the release already has the assets.

One link per platform is enough — `resolve.mjs` derives the sibling arch by
swapping the arch token and `HEAD`s each URL to drop pruned/typo'd ones. A run
is a no-op if the release already has a `.zip` for every requested arch slot.

## Package contents

```text
qqnt-sdk-<x.x.xx-xxxxx>-<system>-<arch>/
  include/QQNT/        node + v8 headers (node.h, node_api.h, v8.h, uv.h, cppgc/, ...)
  lib/                 win: *.def + *.lib   ·   linux: qq, wrapper.node
  manifest.txt         version, arch, sources, and electron/node/v8 versions
```

Release tag: `qq-<version>`, auto-detected from the installer (not typed by hand).

## Using the headers

```cpp
#include <QQNT/node.h>
#include <QQNT/node_api.h>
#include <QQNT/v8.h>
```

```sh
# Windows (MSVC): link against the import lib
cl my.cpp /I path\to\sdk\include  path\to\sdk\lib\QQNT.lib
# Linux: link directly against the ELF object
clang++ my.cpp -I path/to/sdk/include  path/to/sdk/lib/wrapper.node -o my
```

## Consuming the SDK from CMake

`cmake/qqnt_sdk.cmake` downloads the right package from this repo's Releases,
caches it, and gives you a ready target:

```cmake
cmake_minimum_required(VERSION 3.19)
project(myapp CXX)

set(QQNT_SDK_REPO    "CloverNT/qqnt-sdk")
set(QQNT_SDK_VERSION "9.9.31-49738")  # or "latest"
include(/path/to/cmake/qqnt_sdk.cmake)

add_executable(myapp main.cpp)
target_link_libraries(myapp PRIVATE QQNT::QQNT)
```

It picks the `windows`/`linux` + `x64`/`arm64` package automatically, defines
`QQNT::QQNT`, and exports `QQNT_SDK_DIR`, `QQNT_NODE_VERSION`,
`QQNT_ELECTRON_VERSION`, `QQNT_V8_VERSION`. See `examples/cmake_consumer/`.

The package is cached per-user (`%LOCALAPPDATA%\qqnt-sdk` / `~/.cache/qqnt-sdk`,
override with `QQNT_SDK_CACHE_DIR`) so re-running CMake needs no network. Other
knobs: `QQNT_SDK_LINK_LIBS=OFF` (headers only), `QQNT_SDK_OFFLINE=ON` (never hit
the network), `QQNT_SDK_UPDATE=ON` (re-resolve `latest`), `QQNT_SDK_GITHUB_TOKEN`.

## Repository layout

```text
.github/workflows/build_qq_libs.yml   detect-version → resolve → prepare-release → build-windows / build-linux (matrix)
scripts/detect_version.sh             reads the real version out of a downloaded installer/.deb
scripts/resolve.mjs                   QQ link(s) + detected version → per-arch URLs (HEAD-checked) + release-skip
scripts/gen_import_libs.sh            Windows: 7z extract + PE→.def + MSVC lib.exe + headers
scripts/pe_to_def.mjs                 read a PE export table → a .def for lib.exe
scripts/extract_linux.sh              Linux: dpkg-deb extract + copy ELF + headers
scripts/fetch_headers.sh              detect Electron ver → download node headers → include/QQNT
cmake/qqnt_sdk.cmake                  consumer module: download+cache the SDK, define QQNT::QQNT
examples/cmake_consumer/              minimal project that pulls and uses the SDK
```

Artifacts live on the Releases page, not in the repo.

## Caveats

- Electron headers, not stock Node — the V8 is electron-patched, so `v8.h` is
  Electron's; `node_api.h` (N-API) is ABI-stable across both.
- `QQNT.dll` may be absent in some builds; the Windows job warns and still
  builds whatever targets it found.
- arm64 Windows import libs are produced by the x64 `lib.exe` with `/machine:ARM64`.
- Requires **Read and write** workflow permissions (Settings → Actions → General).
