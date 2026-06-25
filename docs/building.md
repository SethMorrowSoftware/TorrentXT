# Building TorrentXT

This documents the native build (the C++ shim → `torrentxt.{so,dll,dylib}`), how
to refresh the committed per-platform binaries, and the CI matrix. It is the
as-built companion to plan §7. **The build is the hard part of this project** (the
binding is easy; libtorrent + Boost are the cost — plan §1.2, §12), so read this
before you fight the toolchain.

> The `.lcb` binding and the committed binaries are **not** built by CMake. CMake
> builds exactly one thing: the shared library from `src/torrent_shim.cpp`. The
> header-only pieces (`btx_abi.h`, `btx_record.h`, `btx_handle_table.h`) compile
> into it and into the tests; nothing else.

---

## TL;DR

```sh
# Configure + build (portable default: FetchContent builds libtorrent v2.0.11 +
# Boost from source — HEAVY, tens of minutes the first time):
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTORRENTXT_BUILD_TESTS=ON
cmake --build build --config Release
ctest --test-dir build --output-on-failure

# Drop the freshly built lib into the committed tree (auto-detects the host id):
python3 tools/package-extension.py --build-dir build
```

If you already have libtorrent 2.0.x installed (apt / Homebrew / vcpkg), skip the
slow source build with `-DTORRENTXT_USE_SYSTEM_LIBTORRENT=ON` (see below).

---

## The one rule about the output name

The library **must** be the bare token `torrentxt` — `torrentxt.so` /
`torrentxt.dll` / `torrentxt.dylib`, **never** `libtorrentxt.*` — because the LCB
layer binds to `c:torrentxt>`. CMake enforces this with `PREFIX ""` /
`OUTPUT_NAME "torrentxt"`; `package-extension.py` always writes the bare-token
name even if it finds a lib-prefixed source. Do not "fix" the name.

---

## CMake options

All are plain `-D` flags. Defaults favour a portable, reproducible build.

| Option | Default | Meaning |
|---|---|---|
| `TORRENTXT_BUILD_TESTS` | `OFF` | Build + register the ctest suite (`record_handle_test`, and `torrent_smoke_test` once the shim/test exist). |
| `TORRENTXT_USE_SYSTEM_LIBTORRENT` | `OFF` | Use `find_package(LibtorrentRasterbar)` + `find_package(Boost)` (vcpkg / apt / system install) instead of FetchContent. Fast — no upstream rebuild. |
| `TORRENTXT_SANITIZE` | `OFF` | Build **all** our C++ under gcc ASan+UBSan (`-fno-sanitize-recover=all`). Ignored on MSVC. (`record_handle_test` is sanitized even without this — see below.) |
| `TORRENTXT_LIBTORRENT_TAG` | `v2.0.11` | The pinned libtorrent git tag for the FetchContent path. Change only deliberately. |

Standard CMake flags you will also use:

- `-DCMAKE_BUILD_TYPE=Release` — set it on single-config generators (Make/Ninja);
  ignored by MSVC/Xcode, which pick per `--config`.
- `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` — **required on macOS** for the
  universal dylib (CMake prints a reminder if you forget).
- `-A Win32` — the 32-bit Windows generator selector.
- `-DCMAKE_TOOLCHAIN_FILE=.../vcpkg.cmake` `-DVCPKG_TARGET_TRIPLET=...` — the
  vcpkg path (pair with `TORRENTXT_USE_SYSTEM_LIBTORRENT=ON`).

### What the build does to keep our code clean

- **C++17**, `-fvisibility=hidden`. Only the `btx_*` ABI symbols (carrying the
  explicit `BTX_API` export attribute in `btx_abi.h`) escape the `.so`.
- Our translation units compile **`-Wall -Wextra`** (`/W3 /EHsc` on MSVC) and must
  stay warning-clean. **libtorrent and Boost headers are included as `SYSTEM`**, so
  their warnings never reach our flag set (plan §7).
- On Linux the link is **`-static-libstdc++ -static-libgcc`** so the committed `.so`
  does not demand a newer `libstdc++.so.6` than the host ships.

---

## Acquiring libtorrent + Boost

### Default: FetchContent (portable, reproducible, **slow**)

With no extra flags, CMake fetches libtorrent at the pinned tag
(`TORRENTXT_LIBTORRENT_TAG`, default `v2.0.11`) and builds it **and Boost** from
source as static libraries, then relinks them into our one shared library. This is
the path the committed *release* binaries should be built with, because the version
is exactly pinned.

**Expect it to be heavy:** the first configure clones libtorrent (+ Boost) and the
first build is tens of minutes and several GB of build tree. Subsequent builds are
incremental. This cost is the project's headline risk (plan §12); the rqbit/cdylib
fallback in plan §1.5 exists to retire it if it ever dominates.

CMake steers libtorrent's own options for us: static libs, no examples/tests/tools,
no deprecated APIs, encryption (MSE/PE) **on** (part of the protocol surface we
promised).

### Fast path: a system / vcpkg / apt install

```sh
cmake -S . -B build -DTORRENTXT_BUILD_TESTS=ON -DTORRENTXT_USE_SYSTEM_LIBTORRENT=ON
```

CMake then calls `find_package(LibtorrentRasterbar 2.0 ...)` and links the imported
`LibtorrentRasterbar::torrent-rasterbar` target (it also tolerates an older
MODULE-style find that yields plain `*_LIBRARIES`). Boost is required ≥ 1.70.

- **apt (Linux):** `sudo apt-get install libtorrent-rasterbar-dev libboost-dev`.
  **Caveat — version:** the apt package is in the 2.0.x line but is **not
  necessarily 2.0.11** (Ubuntu 22.04/24.04 currently carry 2.0.9 / 2.0.10). That
  is fine for exercising the **binding** in CI, but build the **committed release**
  binary from the pinned `v2.0.11` source (FetchContent or a controlled toolchain)
  so all five platforms ship the same engine version. **A human should confirm the
  exact apt version on the target distro.**
- **Homebrew (macOS):** `brew install libtorrent-rasterbar boost`. A brew bottle may
  be single-arch; if the universal link fails, build libtorrent from the pinned
  source for both arches instead (`-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` with the
  FetchContent path).
- **vcpkg (Windows, recommended):** `vcpkg install libtorrent:x64-windows-static`
  (or `x86-windows-static`), then pass the toolchain file + triplet as above.

---

## Platform notes

### Linux — the glibc floor

**Current floor (what the committed libs require):** the bundled Linux `.so`s come
straight from CI's stock `ubuntu-22.04` runners, so they require that host's
**glibc (~2.35)** and **OpenSSL 3** (`libssl.so.3` / `libcrypto.so.3`) — i.e. they
load on **Ubuntu 22.04+ and equally-recent distros**, *not* on older ones (Ubuntu
20.04, CentOS 7, …). libtorrent is static-linked in and libstdc++/libgcc are static
(CMake `-static-libstdc++ -static-libgcc`), so glibc + OpenSSL are the only remaining
dynamic floor, and that floor is a property of the *build host*.

**For broad portability (Phase 4, not yet wired):** build the **release** `.so`
inside a **manylinux2014-style image** (glibc ~2.17, matching the sibling extension
Box2Dxt) so it loads on the older distros the OXT user base runs. This is a
build-environment choice, not a CMake flag — when that lane lands, `commit-binaries`
ships its output instead of the stock-runner build. Until then, ship/expect the
modern-distro floor above (a deliberate "ship now, perfect in Phase 4" choice).

### macOS — universal + codesign/notarize

- Build **universal** with `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`; one
  `universal-mac/torrentxt.dylib` serves Apple silicon and Intel.
- Before public release the dylib must be **codesigned** (Developer ID) and the
  package **notarized**. That needs an Apple Developer ID and a `notarytool`
  keychain profile / app-specific password — credentials this repo does **not**
  carry. The CI workflow contains a **disabled placeholder** step
  (`codesign … && notarytool submit …`); enable it once the secrets exist. **A
  human owns the notarization credentials and the go/no-go.**

### Windows — the module-definition for clean exports

CMake **generates `torrentxt.def`** from the `btx_*` export list and attaches it to
the link on MSVC. This makes the DLL export the symbols **undecorated** (`btx_*`,
not `_btx_foo@N`), which is what the engine's by-name lookup and the
`c:torrentxt>btx_*!cdecl` bindings expect. It is the required fix on **32-bit**
Windows (cdecl decoration bites there) and harmless on x64. If you add a `btx_*`
symbol to `btx_abi.h`, add it to the export list in `CMakeLists.txt` too (you are
bumping `BTX_ABI_VERSION` for the new symbol anyway).

---

## Tests

`-DTORRENTXT_BUILD_TESTS=ON` registers up to two ctest executables:

1. **`record_handle_test`** — `tests/record_handle_test.cpp`. **No libtorrent.**
   Header-only: it exercises the big-endian / length-prefixed record framing (the
   `-needed` measure-or-write contract) and the generation-tagged handle table —
   the project's nastiest bug surface. It is built under **gcc ASan+UBSan even when
   `TORRENTXT_SANITIZE` is off**, because being the always-on sanitized gate is its
   whole purpose. Builds and runs anywhere; it is also your fast local loop:

   ```sh
   g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined \
     -fno-sanitize-recover=all tests/record_handle_test.cpp -o /tmp/rht && /tmp/rht
   ```

   (**gcc**, not clang — clang's ASan runtime is not installed in this environment;
   CLAUDE.md.)

2. **`torrent_smoke_test`** — `tests/torrent_smoke_test.cpp`. Links the shim +
   libtorrent; covers session lifecycle, handle safety, add-from-buffer/magnet, the
   drain record format, and the **exception firewall**. It is registered **only once
   `src/torrent_shim.cpp` and the test source exist** (Phase 1+), so the Phase-0
   skeleton still configures and tests green.

Run both with:

```sh
ctest --test-dir build --output-on-failure
```

The pure-Python record golden (no build at all) is a separate gate:

```sh
python3 tests/record_golden_test.py
```

---

## Refreshing the committed per-platform binaries

The engine resolves `c:torrentxt>` from binaries committed under
`src/code/<arch>-<platform>/` via `the revLibraryMapping` — no install, no `sudo`,
no `LD_LIBRARY_PATH`. After a build, copy the lib into that tree:

```sh
# Auto-detect this host's platform-id:
python3 tools/package-extension.py --build-dir build

# Be explicit (cross-builds / CI):
python3 tools/package-extension.py --platform-id x86_64-linux --build-dir build
python3 tools/package-extension.py --platform-id universal-mac --lib out/torrentxt.dylib

# Stage the installable layout too, or preview without writing:
python3 tools/package-extension.py --build-dir build --assemble
python3 tools/package-extension.py --build-dir build --dry-run
```

The five **exact** platform-ids (architecture first; Windows is `-win32` for both
bitnesses): `x86_64-linux`, `x86-linux`, `x86_64-win32`, `x86-win32`,
`universal-mac`. The script refuses any other id. It is idempotent (an identical
binary reports "unchanged" and writes nothing). **A native-library change is only
"done" once this has refreshed the committed binary in the same commit** (CLAUDE.md).

---

## CI (`.github/workflows/build.yml`)

The jobs:

- **`static-gates`** (ubuntu, every push/PR, < 1 min, **no libtorrent**): runs
  `check-livecodescript.py`, `tests/record_golden_test.py`,
  `tools/check-record-registry.py` (if present), and builds + runs
  `record_handle_test` directly with gcc ASan+UBSan. This is the gate that must
  always stay green.
- **`sanitize`** (ubuntu): builds the shim + smoke test under gcc ASan+UBSan against
  the apt libtorrent and runs them — the memory-safety gate, kept separate so the
  committed binaries stay clean Release builds.
- **`build-matrix`** (Linux x64 + x86, macOS host arch, Windows x64 + x86):
  configures + builds the library with `TORRENTXT_BUILD_TESTS=ON` and runs `ctest`,
  acquiring libtorrent per-OS (apt / Homebrew / vcpkg, FetchContent for 32-bit
  Linux). Each lane stages its binary via `package-extension.py` and uploads it as
  the artifact `native-<platform-id>`.
- **`commit-binaries`** (ubuntu, push to **`main`** only): downloads those artifacts
  and commits the **self-contained** ones into `src/code/<arch-platform>/`
  (`[skip ci]`), deciding per file with `readelf` — a `.so` that dynamically `NEEDED`s
  libtorrent, or any `.dylib`, is skipped. All four `.so`/`.dll` lanes static-link
  libtorrent (Windows via vcpkg `*-static`; both Linux lanes via FetchContent at the
  pinned v2.0.11), so `x86_64-linux`, `x86-linux`, `x86_64-win32` and `x86-win32` are
  committed. (The two Linux libs are built on stock runners, so they carry the glibc/
  OpenSSL floor noted under *Linux — the glibc floor* until the manylinux lane lands.) **macOS is the one platform not shipped from CI**: the lane builds the
  host arch (arm64) against Homebrew, which is neither universal nor self-contained;
  the real universal + codesigned + notarized dylib is a separate release build (see
  the `README.md` in `src/code/universal-mac/` and the macOS section above). Gated to
  `main` because CI builds are not byte-reproducible, so a per-branch binary commit
  would collide with main's and block PR merges.

All actions are pinned to a major version (`actions/checkout@v4`, …).
