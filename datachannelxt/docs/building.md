# Building the DataChannelXT native library

The native layer is ONE shared library — the C++ shim statically linking
libdatachannel and its vendored dependency stack — named with the **bare token**
`datachannelxt` (`datachannelxt.so` / `.dll` / `.dylib`, never `lib`-prefixed)
so the LCB `c:datachannelxt>` binding resolves.

## The dependency stack

| Piece | Role | How it is acquired |
|---|---|---|
| libdatachannel (pinned tag, see CMakeLists) | WebRTC data channels | CMake FetchContent, submodules included |
| libjuice (vendored submodule) | ICE / STUN / TURN | built by libdatachannel's CMake |
| usrsctp (vendored submodule) | SCTP | built by libdatachannel's CMake |
| plog (vendored submodule) | logging (quieted at init) | header-only |
| OpenSSL 3 | DTLS | the SYSTEM library per OS (below) |

`NO_MEDIA=ON` (no libsrtp — Phase 1 is data channels only) and `NO_WEBSOCKET=ON`
trim the build. Everything static-links into our one library except OpenSSL,
which stays a dynamic dependency — present on every Linux target, Homebrew on
macOS, vcpkg-static on Windows (where it IS linked in).

Unlike TorrentXT's Boost+libtorrent ordeal, the whole stack builds in minutes.

## Local build + tests

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DDATACHANNELXT_BUILD_TESTS=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

Needs: a C++17 compiler, CMake >= 3.16, and OpenSSL headers (`libssl-dev`,
`brew install openssl@3` + `-DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3)`, or
vcpkg `openssl:<triplet>-static` + the vcpkg toolchain file).

The smoke test opens a REAL in-process loopback (ICE over the host's own
addresses, DTLS, SCTP), so it needs a machine that can send UDP to itself. An
IPv6-less container logs `juice: UDP socket creation failed, errno=97` first —
harmless; it proceeds over IPv4.

## The sanitizer lanes (the real gates)

`DATACHANNELXT_SANITIZE` is a STRING (`""` | `address` | `thread`) and applies
to the WHOLE build — the flags are injected before FetchContent so
libdatachannel/libjuice/usrsctp are instrumented too. That is not optional
tidiness: TSan must see both sides of every synchronization, and an
uninstrumented dependency would false-positive on its internal atomics.

```sh
# ASan + UBSan (memory safety)
cmake -S . -B build-asan -DDATACHANNELXT_BUILD_TESTS=ON -DDATACHANNELXT_SANITIZE=address
cmake --build build-asan --parallel
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  ctest --test-dir build-asan --output-on-failure

# ThreadSanitizer (the concurrency gate for THIS binding)
cmake -S . -B build-tsan -DDATACHANNELXT_BUILD_TESTS=ON -DDATACHANNELXT_SANITIZE=thread
cmake --build build-tsan --parallel
TSAN_OPTIONS="halt_on_error=1:suppressions=$PWD/tests/tsan-suppressions.txt" \
  ctest --test-dir build-tsan --output-on-failure
```

gcc only (clang's sanitizer runtimes are absent in the CI environment); the two
sanitizers are mutually exclusive builds. `tests/tsan-suppressions.txt` may only
ever suppress races wholly inside a vendored dependency (today: usrsctp's SACK
fast path); a race touching `datachannel_shim.cpp` must be fixed, not
suppressed.

## The five shipping targets

| platform-id | how CI builds it |
|---|---|
| `x86_64-linux` | FetchContent static, system OpenSSL (dynamic NEEDED) |
| `x86-linux` | the same under `-m32` against `libssl-dev:i386` |
| `x86_64-win32` | MSVC + vcpkg `openssl:x64-windows-static`, static CRT (/MT), generated .def |
| `x86-win32` | as above with `x86-windows-static` + `-A Win32` (the .def matters here) |
| `universal-mac` | CI proves the HOST arch (arm64, Homebrew OpenSSL); the shipped universal (arm64;x86_64), codesigned + notarized dylib is a separate release build with Apple credentials — pass `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` and a static OpenSSL for it |

CI (`.github/workflows/build.yml`) builds all five on every push, runs ctest,
and — on pushes to `main` only — commits the SELF-CONTAINED artifacts into
`src/code/<arch>-<platform>/` (the macOS lane's Homebrew-linked dylib is
deliberately never committed; see the workflow's header comment).

## Packaging into the extension tree

```sh
python3 tools/package-extension.py --build-dir build            # auto-detect host
python3 tools/package-extension.py --platform-id x86_64-linux --build-dir build
python3 tools/package-extension.py --build-dir build --assemble # + staging layout
```

Idempotent; always writes the bare-token filename. A native change is only
"done" when the committed binary under `src/code/` is refreshed in the same
change.

## Windows note: the generated .def

32-bit MSVC cdecl name-decoration can confuse the engine's by-name export
lookup, so CMake generates `datachannelxt.def` listing the exact undecorated
`dcx_*` names (harmless on x64, required on x86). The list lives in
CMakeLists.txt and must gain a line whenever `dcx_abi.h` gains a symbol — the
ABI bump discipline covers it.
