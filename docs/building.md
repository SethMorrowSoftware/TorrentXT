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
| `TORRENTXT_BUILD_TESTS` | `OFF` | Build + register the ctest suite (`record_handle_test`, `torrent_smoke_test` and `rp1_integration_test`). |
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

**Current floor (what the committed x86-64 lib requires — measured 2026-08-13,
not remembered):** the committed `x86_64-linux/torrentxt.so` came from the
2026-08-12 release run on a stock `ubuntu-24.04` runner, so it references glibc
symbols up to **GLIBC_2.38** and dynamically needs **OpenSSL 3**
(`libssl.so.3` / `libcrypto.so.3`) — i.e. it loads on Ubuntu 24.04-class
distros and newer, not on older ones. (An earlier revision of this section
said "~2.35 / Ubuntu 22.04": the floor is a property of whichever build host
produced the committed file, which is exactly why the release lane now asserts
it instead of this file remembering it.) libtorrent is static-linked in and
libstdc++/libgcc are static (CMake `-static-libstdc++ -static-libgcc`), so
glibc + OpenSSL are the only remaining dynamic floor.

**The portable lane is WIRED (2026-08-13), pending its first release run.**
`release-binaries.yml` now builds the torrentxt `x86_64-linux` release inside a
**manylinux_2_28 container** (AlmaLinux 8, **glibc 2.28**) with a pinned,
hash-checked **static OpenSSL 3.5** and pinned Boost headers, so that artifact
needs no libssl/libcrypto from the host at all and floors at glibc 2.28 —
Ubuntu 20.04+, Debian 10+, RHEL/Rocky/Alma 8+, and anything newer. The job
**asserts the floor where the artifact is born** (no dynamic
libssl/libcrypto/libstdc++/libgcc_s/libboost; max referenced glibc symbol
version <= 2.28), and the smoke test runs inside the same container, so a
regression fails the job rather than shipping. Two deliberate narrowings,
recorded rather than silent:

- **glibc 2.28, not the manylinux2014 (~2.17) this section originally
  sketched.** GitHub's node20-based actions (checkout, upload-artifact)
  refuse to start in a glibc-2.17 container, and the only distro the lower
  floor would add — CentOS 7 — has been EOL since June 2024. 2.28 is the
  decided support baseline.
- **`x86-linux` (32-bit) keeps the stock-runner floor.** No manylinux_2_28
  i686 image exists; the 32-bit lane stays a modern-distro build, said here
  instead of implied otherwise.

The committed binary keeps the 2.38 floor above until the next
`release-binaries.yml` dispatch re-commits it from the wired lane. The
per-member `native-torrentxt.yml` matrix deliberately stays on stock runners:
it exists for fast per-push feedback and its artifacts are never committed.

### macOS — universal + codesign/notarize

- Since 2026-08-23 the suite's `release-binaries.yml` builds the universal
  dylib in CI (the `mac-lipo` job: each slice thin against a per-arch build of
  the pinned static OpenSSL, both slices tested, `lipo -create`) — unsigned,
  which the owner accepted that day. The rest of this section is the manual
  recipe, still equivalent, and the codesign/notarize half no lane does.
- Build **universal** with `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`; one
  `universal-mac/torrentxt.dylib` serves Apple silicon and Intel. That single
  pass assumes your static deps (OpenSSL, Boost) are themselves universal; with
  per-arch dependency trees - the CI route - build each slice with a SINGLE
  arch value and `lipo -create` the pair (one value per slice, never both:
  two fat inputs share architectures and `lipo -create` refuses duplicates).
- Codesigning (Developer ID) + **notarization** is NO LONGER a release gate:
  unsigned distribution was explicitly accepted 2026-08-23, and the committed
  dylib ships with the linker's automatic ad-hoc signature (a
  browser-downloaded zip needs its quarantine attribute cleared; a git
  checkout does not). It remains the polish for a friction-free public
  download, and the mechanics stand for whenever that is wanted: an Apple
  Developer ID and a `notarytool` keychain profile / app-specific password —
  credentials this repo does **not** carry — and the CI workflow's **disabled
  placeholder** step (`codesign … && notarytool submit …`). **A human owns
  those credentials and the go/no-go.**

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

`-DTORRENTXT_BUILD_TESTS=ON` registers up to three ctest executables:

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

3. **`rp1_integration_test`** — `tests/rp1_integration_test.cpp`. Links the shim +
   libtorrent and proves the **rp1 peer-wire path on the wire**, in ONE process with
   no OXT and no second machine: two real libtorrent sessions on loopback, the actual
   rp1 plugin attached to each, the same metadata-less phantom swarm added to both, an
   explicit `connect_peer` wiring them together, and one message from A confirmed at B
   byte-for-byte. That reaches the four things the smoke test cannot — extended-handshake
   negotiation, the `tick()` flush of a queued send, `on_extended` delivery, and the
   phantom (no-metadata) connection holding long enough to talk. Registered on the same
   condition as the smoke test (the test source and the `torrentxt` target both exist),
   with a **120 s ctest timeout** (the per-peer tick that flushes a send runs about once
   a second, and a slow runner needs the room) and `ASAN_OPTIONS=detect_container_overflow=0`,
   which mutes the known false positive a shim built WITH ASan hits against a libtorrent
   built without it.

Run all three with:

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

## CI (root `.github/workflows/native-torrentxt.yml`)

In the xtalk-suite monorepo, GitHub Actions runs only the ROOT workflows: the
member's own `.github/workflows/build.yml` is kept for isolated development but
is **inert here**. TorrentXT's lanes live in the root `native-torrentxt.yml`
(scoped by `paths:` so only a torrentxt touch builds it), and the compiler-free
gates below run for every member in the root `suite-gates.yml`. The jobs:

- **static gates** (in `suite-gates.yml`, every push/PR, < 1 min, **no
  libtorrent**): `check-livecodescript.py`, `tests/record_golden_test.py`,
  `tools/check-record-registry.py`, and the rest of the suite's gate set. This
  is the gate that must always stay green.
- **`sanitize`** (ubuntu): builds the shim + smoke test under gcc ASan+UBSan against
  the apt libtorrent and runs them — the memory-safety gate, kept separate so the
  committed binaries stay clean Release builds.
- **`build-matrix`** (Linux x64 + x86, macOS host arch, Windows x64 + x86):
  configures + builds the library with `TORRENTXT_BUILD_TESTS=ON` and runs `ctest`,
  acquiring libtorrent per-OS (apt / Homebrew / vcpkg, FetchContent for 32-bit
  Linux). Each lane stages its binary via `package-extension.py` and uploads it as
  the artifact `native-<platform-id>`. **CI never commits a binary**: the lanes
  fire on every push, so a commit step would land binaries nobody asked for on
  somebody else's change. Committed binaries under `src/code/` trace to a human
  decision — a maintainer installing an artifact, or the suite's manual
  `release-binaries.yml` assembly (which installs, verifies, and refreshes the
  manifests via `tools/install-release-binaries.py`).
  **macOS**: the per-member lane builds the host arch (arm64) against Homebrew,
  which is neither universal nor self-contained; the real universal dylib is
  `release-binaries.yml`'s `mac-lipo` job since 2026-08-23 (unsigned - codesign +
  notarize still exists nowhere; see the `README.md` in `src/code/universal-mac/`
  and the macOS section above). Gated to
  `main` because CI builds are not byte-reproducible, so a per-branch binary commit
  would collide with main's and block PR merges.

All actions are pinned to a major version (`actions/checkout@v4`, …).
