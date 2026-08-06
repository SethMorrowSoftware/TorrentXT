# Building enetxt

The dependency story is the family's lightest: ENet is one small C library,
fetched and pinned by CMake, statically folded into the one shared library.
Minutes, not the hours Boost/libtorrent cost TorrentXT.

## Linux (the everyday lane)

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENETXT_BUILD_TESTS=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure   # record_handle_test + enet_smoke_test
```

**The sanitizer lane** — the `ENETXT_SANITIZE` knob is a STRING and GLOBAL,
injected before FetchContent so ENet itself is instrumented too. gcc only
(clang's sanitizer runtimes are not installed in the reference environment):

```sh
cmake -S . -B build-asan -DENETXT_BUILD_TESTS=ON -DENETXT_SANITIZE=address
cmake --build build-asan --parallel
./build-asan/record_handle_test && ./build-asan/enet_smoke_test
```

A shim change is only "done" green under ASan/UBSan. There is no TSan lane:
ENet is threadless and the shim spawns nothing — there is no concurrency to
sanitize (the one binding that needed TSan is dataChannelXT).

Note `CMAKE_POSITION_INDEPENDENT_CODE ON` sits BEFORE FetchContent in the
CMakeLists — a non-PIC static ENet cannot link into the shared library, and
ld's entire diagnosis is "bad value".

## Windows

Visual Studio 2022+ (the default generator). No vcpkg needed — ENet has no
external dependencies; winsock comes with the SDK.

```powershell
cmake -S . -B build -DENETXT_BUILD_TESTS=ON
cmake --build build --config Release --parallel
ctest --test-dir build --build-config Release --output-on-failure
```

For the 32-bit DLL add `-A Win32`.

## macOS

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENETXT_BUILD_TESTS=ON
cmake --build build --parallel && ctest --test-dir build --output-on-failure
```

CI's mac artifact is host-arch and unsigned — the shipping universal +
codesigned dylib is a separate release build, same as the siblings.

## Packaging

```sh
python3 tools/package-extension.py --platform-id x86_64-linux --lib build/enetxt.so
```

places the bare-token library into `src/code/<arch>-<platform>/` (the tree
the packaged extension bundles); the self-contained gate refuses a library
with unexpected dynamic dependencies. CI (`.github/workflows/build.yml`)
builds the 5-target matrix and commits the self-contained ones on `main` —
push or a manual Run-workflow dispatch both count (the event-outage lesson).
