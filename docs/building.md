# Building TorrentXT

The native build (the C++ shim -> `torrentxt.{so,dll,dylib}`), how the committed
per-platform binaries are refreshed, and CI. **The build is the hard part of this project**:
the binding is easy, libtorrent + Boost are the cost (`architecture.md`, "Why it is built
this way"), so read this before you fight the toolchain.

> CMake builds exactly one thing: the shared library from `src/torrent_shim.cpp`. The
> header-only pieces (`btx_abi.h`, `btx_record.h`, `btx_handle_table.h`) compile into it and
> into the tests. The `.lcb` binding and the committed binaries are not CMake outputs.

## TL;DR

```sh
# Configure + build (portable default: FetchContent builds libtorrent v2.0.11 +
# Boost from source - HEAVY, tens of minutes the first time):
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTORRENTXT_BUILD_TESTS=ON
cmake --build build --config Release
ctest --test-dir build --output-on-failure

# Drop the freshly built lib into the committed tree (auto-detects the host id),
# then refresh its line in src/code/MANIFEST.sha256 (see "Refreshing" below):
python3 tools/package-extension.py --build-dir build
```

With libtorrent 2.0.x already installed (apt / Homebrew / vcpkg), skip the slow source
build with `-DTORRENTXT_USE_SYSTEM_LIBTORRENT=ON`.

## The one rule about the output name

The library **must** be the bare token `torrentxt` (`torrentxt.so` / `torrentxt.dll` /
`torrentxt.dylib`, **never** `libtorrentxt.*`), because the LCB layer binds to
`c:torrentxt>`. CMake enforces this with `PREFIX ""` / `OUTPUT_NAME "torrentxt"`;
`package-extension.py` always writes the bare-token name even if it finds a lib-prefixed
source. Do not "fix" the name.

## CMake options

| Option | Default | Meaning |
|---|---|---|
| `TORRENTXT_BUILD_TESTS` | `OFF` | Build and register the ctest suite: `record_handle_test`, `torrent_smoke_test`, `rp1_integration_test`, `rp1_queue_test`. |
| `TORRENTXT_USE_SYSTEM_LIBTORRENT` | `OFF` | `find_package(LibtorrentRasterbar 2.0)` + Boost >= 1.70 (vcpkg / apt / system install) instead of FetchContent. Fast. The version script `src/torrentxt.map` is deliberately NOT applied on this path (`../CLAUDE.md` gotcha 4). |
| `TORRENTXT_SANITIZE` | `OFF` | Build all our C++ under gcc ASan+UBSan (`-fno-sanitize-recover=all`). Ignored on MSVC. (`record_handle_test` is sanitized regardless.) |
| `TORRENTXT_LIBTORRENT_TAG` | `v2.0.11` | The pinned libtorrent git tag for FetchContent. Change only deliberately. |

Standard flags you will also use: `-DCMAKE_BUILD_TYPE=Release` (single-config generators);
`-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` (a one-pass universal macOS build; CMake reminds
you); `-A Win32` (32-bit Windows); `-DCMAKE_TOOLCHAIN_FILE=.../vcpkg.cmake
-DVCPKG_TARGET_TRIPLET=...` (the vcpkg path, paired with `TORRENTXT_USE_SYSTEM_LIBTORRENT=ON`).

What the build does to keep our code clean:

- **C++17**, `-fvisibility=hidden`; only the `btx_*` symbols (the `BTX_API` attribute in
  `btx_abi.h`) are exported, and on the static path `src/torrentxt.map` also keeps the
  linked-in libtorrent / Boost / OpenSSL / C++-runtime symbols out of the export table.
- Our translation units compile **`-Wall -Wextra`** (`/W3 /EHsc` on MSVC) and stay
  warning-clean. **libtorrent and Boost headers are `SYSTEM`**, so their warnings never
  reach our flag set.
- On Linux the link is **`-static-libstdc++ -static-libgcc`**, so the committed `.so` does not
  demand a newer `libstdc++.so.6` than the host ships.

## Acquiring libtorrent + Boost

**Default: FetchContent (portable, reproducible, slow).** CMake fetches libtorrent at the
pinned tag and builds it **and Boost** from source as static libraries, then links them into
our one shared library: tens of minutes and several GB of build tree the first time,
incremental after. It steers libtorrent's options for us: static libs, no
examples/tests/tools, no deprecated APIs, encryption (MSE/PE) **on**.

**Fast path: a system / vcpkg / apt install.**

```sh
cmake -S . -B build -DTORRENTXT_BUILD_TESTS=ON -DTORRENTXT_USE_SYSTEM_LIBTORRENT=ON
```

CMake calls `find_package(LibtorrentRasterbar 2.0 ...)` and links the imported
`LibtorrentRasterbar::torrent-rasterbar` target (an older MODULE-style find that yields plain
`*_LIBRARIES` is tolerated). Boost >= 1.70 is required.

- **apt (Linux):** `sudo apt-get install libtorrent-rasterbar-dev libboost-dev`. The package
  is in the 2.0.x line but not necessarily 2.0.11 (Ubuntu 22.04/24.04 carry 2.0.9/2.0.10):
  fine for exercising the binding in CI, not for a committed binary.
- **Homebrew (macOS):** `brew install libtorrent-rasterbar boost`. A bottle may be
  single-arch; it is fine for a host build, not for the universal release.
- **vcpkg (Windows):** `vcpkg install libtorrent:x64-windows-static` (or
  `x86-windows-static`), then the toolchain file + triplet as above.

**Upstream versions in the committed binaries.** Linux and macOS carry the pinned
**libtorrent 2.0.11**. The Windows release lanes use vcpkg's **unpinned** `libtorrent` port,
so the committed DLLs carry **libtorrent 2.1.1** (and OpenSSL 3.6); the shim supports both
generations (`../CLAUDE.md` gotcha 5). Pinning the Windows port too (a vcpkg baseline or
overlay, or FetchContent) is what it would take
so all five platforms ship the same engine version; today they do not, and whether to pin
or to accept 2.1.1 is an open owner call.

## Platform notes

### Linux - the glibc floors (measured from the committed files)

- **`x86_64-linux`: glibc 2.28, no dynamic OpenSSL.** `release-binaries.yml` builds it
  inside a **manylinux_2_28** container (AlmaLinux 8) with a pinned, hash-checked **static
  OpenSSL 3.5** and pinned Boost headers; `objdump` on the committed `.so` shows no
  `GLIBC_` symbol above 2.28 and no `libssl`/`libcrypto` NEEDED. It loads on Ubuntu 20.04+,
  Debian 10+, RHEL/Rocky/Alma 8+ and newer. The job **asserts the floor where the artifact is
  born** (no dynamic libssl/libcrypto/libstdc++/libgcc_s/libboost; max glibc symbol
  <= 2.28) and runs the smoke test in the same container, so a regression fails the job.
  Why 2.28 and not manylinux2014's 2.17: GitHub's node20 actions refuse to start in a
  glibc-2.17 container, and the only distro the lower floor would add, CentOS 7, has been
  EOL since June 2024.
- **`x86-linux` (32-bit): glibc 2.38 plus the system `libssl.so.3` / `libcrypto.so.3`.** No
  manylinux_2_28 i686 image exists, so the 32-bit lane is a stock-runner build that loads on
  Ubuntu 24.04-class distros and newer.

The per-member `native-torrentxt.yml` matrix stays on stock runners on purpose: it is fast
per-push feedback and its artifacts are never committed.

### macOS - universal, unsigned

- The committed `universal-mac/torrentxt.dylib` (arm64 + x86_64, since release run 12 on
  2026-08-27) comes from `release-binaries.yml`'s **`mac-lipo`** job: each slice built thin
  against a per-arch build of the pinned static OpenSSL (libtorrent 2.0.11 from
  FetchContent), arm64 tested natively and x86_64 under Rosetta, `lipo -create`, and the slice
  table asserted at birth and again by the installer.
- The dylib ships **unsigned**, with the linker's automatic ad-hoc signature; the owner
  accepted unsigned distribution on 2026-08-23. A browser-downloaded copy needs its
  quarantine attribute cleared; a git checkout does not. Codesigning and notarization would
  need an Apple Developer ID and `notarytool` credentials that CI does not hold, and no
  workflow does them; the go/no-go belongs to the owner.
- **Manual universal build.** With universal static dependencies, one pass with
  `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` serves Apple silicon and Intel. With per-arch
  dependency trees (the CI route), build each slice with a SINGLE arch value and
  `lipo -create` the pair: never both values per slice, because two fat inputs share
  architectures and `lipo -create` refuses duplicates. Stage the result with
  `python3 tools/package-extension.py --platform-id universal-mac --lib <path>/torrentxt.dylib`.
- The per-member CI lane builds only the host arch (arm64) against Homebrew: a thin,
  Homebrew-linked dylib that is not distributable and is never committed.

### Windows - the module-definition for clean exports

CMake **generates `torrentxt.def`** from the `btx_*` export list in `CMakeLists.txt` and
attaches it on MSVC, so the DLL exports undecorated names (`btx_*`, not `_btx_foo@N`), which
is what the engine's by-name lookup and the `c:torrentxt>btx_*!cdecl` bindings expect. It is
the required fix on 32-bit Windows and harmless on x64. A new `btx_*` symbol goes into that
list too (you are bumping `BTX_ABI_VERSION` for it anyway).

## Tests

`-DTORRENTXT_BUILD_TESTS=ON` registers four ctest executables:

1. **`record_handle_test`** (`tests/record_handle_test.cpp`) - **no libtorrent.** It
   exercises the big-endian, length-prefixed record framing (the `-needed` measure-or-write
   contract) and the generation-tagged handle table, and is built under **gcc ASan+UBSan
   even when `TORRENTXT_SANITIZE` is off**. It is also the fast local loop:

   ```sh
   g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined \
     -fno-sanitize-recover=all tests/record_handle_test.cpp -o /tmp/rht && /tmp/rht
   ```

   (gcc, not clang: clang's ASan runtime is not installed in this environment.)
2. **`torrent_smoke_test`** (`tests/torrent_smoke_test.cpp`) - links the shim and the real
   libtorrent: session lifecycle, handle safety, add from buffer and magnet, the drain record
   format, and the **exception firewall**; since 2026-09-24 also the BEP44 caps at their
   boundaries (996/997 raw, 1000/1001 already-bencoded), libtorrent's own alert-queue
   overflow reaching `btLastError()` (forced with `alert_queue_size` = 1), and the magnet
   parse a pre-Model-C QuickShare hands a truncated `BTXTOR1:` code to. It prints each
   section on unbuffered stdout, so an abort still shows where it happened.
3. **`rp1_integration_test`** (`tests/rp1_integration_test.cpp`) - the **rp1 peer-wire path
   on the wire** in one process: two real sessions on loopback with the rp1 plugin attached,
   the same metadata-less phantom swarm on both, an explicit `connect_peer`, and one message
   confirmed byte-for-byte. It reaches what the smoke test cannot: extended-handshake
   negotiation, the `tick()` flush of a queued send, `on_extended` delivery, and a phantom
   connection holding long enough to talk. It has a **120 s ctest timeout** (the per-peer
   tick runs about once a second) and sets `ASAN_OPTIONS=detect_container_overflow=0`, which
   mutes the known false positive of an ASan-built shim against a non-ASan libtorrent.
4. **`rp1_queue_test`** (`tests/rp1_queue_test.cpp`, since 2026-09-24) - the **bounded rp1
   inbound queue** at both caps: tail-drop keeps the oldest events, the drain releases
   exactly the budget the enqueue charged, and the shed count reaches the last error once.
   The queue is fed only by a peer's traffic on the network thread, so this test
   `#include`s `src/torrent_shim.cpp` and links libtorrent but NOT the `torrentxt` library:
   it proves the source, not the shipped `.so` (a `btx::test` hook would have been a shim
   change, and so a rebuild of every committed binary).

The compiler-free gates (the static checker, every `tests/*golden*.py` suite, the Model C
execution gate `tools/check-script-vectors.py` and its fixture test, the record registry
check and the `MANIFEST.sha256` check) are one command: `bash tools/run-gates.sh`. The
execution gate needs the sibling members riptide, nostrxt and sodiumxt beside this
checkout; see the README's section on the suite.

## Refreshing the committed per-platform binaries

The engine resolves `c:torrentxt>` from binaries committed under
`src/code/<arch>-<platform>/`. **The canonical refresh is the suite's `release-binaries.yml`
dispatch**, which builds all five, runs `tools/install-release-binaries.py` (install, verify
format and architecture, refresh the manifests) and the whole gate set, then commits.

A manual refresh copies the lib in with `package-extension.py`:

```sh
python3 tools/package-extension.py --build-dir build                         # auto-detect the id
python3 tools/package-extension.py --platform-id x86_64-linux --build-dir build
python3 tools/package-extension.py --platform-id universal-mac --lib out/torrentxt.dylib
python3 tools/package-extension.py --build-dir build --assemble              # also stage the installable layout
python3 tools/package-extension.py --build-dir build --dry-run               # preview only
```

It accepts only the five exact ids (`x86_64-linux`, `x86-linux`, `x86_64-win32`,
`x86-win32`, `universal-mac`) and is idempotent (an identical binary reports "unchanged").
It does **not** touch `src/code/MANIFEST.sha256`, and `tools/run-gates.sh` fails on an
unlisted or changed blob, so update that line in the same change
(`cd src/code && sha256sum <platform-id>/torrentxt.*` and replace the entry). A
native-library change is only done once the committed binary is refreshed in the same
change (`../CLAUDE.md` rule 6).

## CI

- **`suite-gates.yml`** (suite root, every push/PR, no libtorrent) runs this member's
  `tools/run-gates.sh` with the rest of the suite's gates. This is the gate that must always
  stay green.
- **`native-torrentxt.yml`** (suite root, scoped by `paths:` to torrentxt changes) has two
  jobs. `sanitize`: the shim and tests under gcc ASan+UBSan against the apt libtorrent.
  `build-matrix`: Linux x86_64 and x86, macOS (host arch, Homebrew) and Windows x64 and x86
  (vcpkg, so these lanes compile and ctest the libtorrent 2.1 branch), each running `ctest`
  and uploading its binary as an artifact. **CI never commits a binary**: the lanes fire on
  every push, so a commit step would land binaries nobody asked for.
- **`release-binaries.yml`** (manual dispatch) is the release assembly described above.
- In this member's own repository, `.github/workflows/gates.yml` and `native.yml` are
  GENERATED from those root lanes by the suite's `tools/sync-member-workflows.py`; change the
  suite's lanes, not the copies.
