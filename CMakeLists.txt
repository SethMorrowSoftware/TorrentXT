# CMakeLists.txt — TorrentXT native build (plan §7 "Build & packaging").
#
# WHAT THIS BUILDS
#   ONE shared library, the C++ shim `src/torrent_shim.cpp`, statically linking
#   libtorrent-rasterbar + Boost, exported with the flat `btx_*` C ABI. The file
#   MUST be named with the BARE TOKEN `torrentxt` (no `lib` prefix) so it matches
#   the LCB binding string `c:torrentxt>` — torrentxt.so / .dll / .dylib, NEVER
#   libtorrentxt.* (set via PREFIX "" / OUTPUT_NAME below). The .lcb and the
#   committed per-platform binaries under src/code/<arch>-<platform>/ are NOT
#   built here — `tools/package-extension.py` copies a fresh build into that tree.
#
# WHY libtorrent is the build risk, not the binding (plan §1.2, §12): the FFI is
#   indifferent to the language behind the symbols; the genuine cost is acquiring
#   and statically linking libtorrent + Boost across five targets. We therefore
#   (a) PIN libtorrent to v2.0.11 and Boost to >= 1.70, (b) treat their headers as
#   SYSTEM headers so their warnings never pollute our -Wall -Wextra, and (c) keep
#   two acquisition paths: a portable FetchContent default and a fast system/vcpkg
#   path for CI lanes and developers who already have the libraries.
#
# WHY some targets are GUARDED on file existence: this repo is built in phases
#   (plan §10). In Phase 0 the header-only pieces and their sanitizer test exist
#   before `torrent_shim.cpp` / `torrent.lcb` land. So the shim library and the
#   libtorrent-linked smoke test are configured ONLY when their sources are
#   present; the header-only `record_handle_test` always builds. This lets CI go
#   green on the skeleton and light up the heavy lanes the moment the shim arrives.

cmake_minimum_required(VERSION 3.16)   # FetchContent + generator expressions we use

project(TorrentXT
    VERSION 0.1.0
    DESCRIPTION "OpenXTalk binding to libtorrent-rasterbar (flat btx_ C ABI)"
    LANGUAGES CXX)

# ----------------------------------------------------------------- options ----
# Exposed knobs (documented in docs/building.md). Defaults favour a portable,
# reproducible build; flip TORRENTXT_USE_SYSTEM_LIBTORRENT for the fast path.
option(TORRENTXT_BUILD_TESTS           "Build the ctest suite (record_handle_test + torrent_smoke_test)" OFF)
option(TORRENTXT_USE_SYSTEM_LIBTORRENT "find_package(LibtorrentRasterbar)/(Boost) instead of FetchContent (vcpkg / apt / system install)" OFF)
option(TORRENTXT_SANITIZE              "Build C++ under ASan+UBSan (gcc; clang's ASan runtime is absent in CI)" OFF)
set(TORRENTXT_LIBTORRENT_TAG "v2.0.11" CACHE STRING
    "Pinned libtorrent-rasterbar git tag for the FetchContent path (plan §7: start v2.0.11)")

# Single-config generators (Make/Ninja) need an explicit default build type;
# multi-config ones (MSVC, Xcode) ignore this and pick per --config at build time.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
    message(STATUS "TorrentXT: no build type set; defaulting to Release")
endif()

set(CMAKE_CXX_STANDARD 17)             # the shim and the header-only code are C++17
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)          # -std=c++17, not -std=gnu++17 (portability)

# Hide everything by default; the ABI opts symbols back in with the explicit
# BTX_API export macro (btx_abi.h: visibility("default") / __declspec(dllexport)).
# -fvisibility=hidden keeps libtorrent's huge symbol surface OUT of our exports,
# shrinks the .so, and avoids accidental ABI leakage.
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)  # a shared lib statically linking deps needs -fPIC throughout

# On MSVC, match the CRT that vcpkg's *-windows-static triplet links libtorrent
# and Boost against: the STATIC runtime (/MT). Our shim defaults to the dynamic
# runtime (/MD), and mixing the two pulls in both LIBCMT and MSVCRT, which then
# multiply-define the CRT symbols (LNK4098 -> fatal LNK1169). A self-contained
# torrentxt.dll with statically-linked deps wants the static CRT regardless.
# CMP0091 is NEW for cmake_minimum_required >= 3.15 (we require 3.16), so
# CMAKE_MSVC_RUNTIME_LIBRARY is honored without touching compile flags directly.
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# --------------------------------------------------- our warning/flag set ----
# Applied ONLY to our translation units (the shim + tests), never to libtorrent
# or Boost — those ride in as SYSTEM includes (below) so their warnings are mute.
# Our code must compile -Wall -Wextra clean (/W3 on MSVC), per CLAUDE.md.
add_library(torrentxt_flags INTERFACE)
if(MSVC)
    target_compile_options(torrentxt_flags INTERFACE /W3 /EHsc /permissive-)
    # libtorrent pulls in <windows.h>; keep it lean and unicode, and silence the
    # MSVC "use the _s functions" nag that fires on the cross-platform shim code.
    target_compile_definitions(torrentxt_flags INTERFACE
        WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(torrentxt_flags INTERFACE -Wall -Wextra)
endif()

# Sanitizers: gcc only (CLAUDE.md — clang's ASan runtime is not installed in this
# environment / CI). UBSan with -fno-sanitize-recover=all turns UB into a hard
# failure so a smoke-test run cannot pass while quietly miscompiling.
if(TORRENTXT_SANITIZE)
    if(MSVC)
        message(WARNING "TORRENTXT_SANITIZE ignored on MSVC (use the gcc ASan/UBSan lane)")
    else()
        target_compile_options(torrentxt_flags INTERFACE
            -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
        target_link_options(torrentxt_flags INTERFACE -fsanitize=address,undefined)
    endif()
endif()

# A portable-Linux glibc floor (plan §7: match Box2Dxt's ~2.17 intent) so the
# committed .so loads on older distros the OXT user base runs. We do NOT ship a
# full old-glibc sysroot here (that belongs to the release toolchain — see
# docs/building.md); this just keeps libstdc++ statically linked so the binary
# does not demand a newer libstdc++.so.6 than the host provides. The real glibc
# floor is enforced by building the RELEASE binary in a manylinux2014-style image
# (glibc 2.17) — documented, not implemented in this file.
if(UNIX AND NOT APPLE)
    # Static libstdc++/libgcc: the dominant portability win for a C++ .so.
    add_library(torrentxt_link INTERFACE)
    target_link_options(torrentxt_link INTERFACE
        -static-libstdc++ -static-libgcc
        # Do not export libtorrent/Boost/stdc++ symbols from our .so; only btx_*
        # (which carry visibility("default")) escape. Belt-and-suspenders with
        # -fvisibility=hidden and the version script is not needed because the
        # explicit BTX_API attribute already gates the surface.
        )
else()
    add_library(torrentxt_link INTERFACE)
endif()

# ------------------------------------------------- acquire the dependencies ---
# Two paths, selected by TORRENTXT_USE_SYSTEM_LIBTORRENT:
#
#   SYSTEM  : find_package(LibtorrentRasterbar) + find_package(Boost). This is the
#             vcpkg path (`-DCMAKE_TOOLCHAIN_FILE=.../vcpkg.cmake`) and the
#             apt/system path (libtorrent-rasterbar-dev). FAST — no upstream
#             rebuild. The CI build-matrix prefers this where a 2.0.x package is
#             available; otherwise it falls back to FetchContent.
#
#   DEFAULT : FetchContent at the pinned tag. PORTABLE and reproducible, but HEAVY
#             — it builds Boost + libtorrent from source (tens of minutes, large
#             on-disk). See docs/building.md. We need Boost's own CMake (>= 1.79
#             ships it) because libtorrent's CMake does find_package(Boost CONFIG).
#
# Either way the rest of the file links the imported target
# `torrentxt::libtorrent` so the shim/test targets do not care which path ran.
#
# We only ACQUIRE libtorrent when something will actually link it: the shim source
# is present, or the smoke test is present and tests are on. This keeps the
# Phase-0 skeleton (and the fast CI "static-gates" lane, which builds only the
# header-only record_handle_test) from triggering the heavy Boost/libtorrent
# fetch+build for nothing. The moment the shim lands, acquisition switches on.
add_library(torrentxt_libtorrent INTERFACE)
add_library(torrentxt::libtorrent ALIAS torrentxt_libtorrent)

set(TORRENTXT_NEED_LIBTORRENT OFF)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/torrent_shim.cpp")
    set(TORRENTXT_NEED_LIBTORRENT ON)
elseif(TORRENTXT_BUILD_TESTS AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/torrent_smoke_test.cpp")
    set(TORRENTXT_NEED_LIBTORRENT ON)
endif()

if(NOT TORRENTXT_NEED_LIBTORRENT)
    message(STATUS "TorrentXT: nothing links libtorrent yet (no shim / no smoke test) — "
                   "skipping dependency acquisition. Only the header-only gate will build.")
elseif(TORRENTXT_USE_SYSTEM_LIBTORRENT)
    # libtorrent's installed package config is named "LibtorrentRasterbar" and
    # exports the target `LibtorrentRasterbar::torrent-rasterbar`. vcpkg installs
    # the same config. We require >= 2.0 so a stray 1.2.x system package cannot
    # silently satisfy us with a different ABI surface.
    find_package(LibtorrentRasterbar 2.0 CONFIG QUIET)
    if(NOT LibtorrentRasterbar_FOUND)
        # Some distros ship only a pkg-config/module file, not a CONFIG package.
        find_package(LibtorrentRasterbar 2.0 MODULE REQUIRED)
    endif()
    if(TARGET LibtorrentRasterbar::torrent-rasterbar)
        target_link_libraries(torrentxt_libtorrent INTERFACE LibtorrentRasterbar::torrent-rasterbar)
    elseif(DEFINED LibtorrentRasterbar_LIBRARIES)
        # MODULE-style result (older find scripts): plain vars, not a target.
        target_include_directories(torrentxt_libtorrent SYSTEM INTERFACE ${LibtorrentRasterbar_INCLUDE_DIRS})
        target_link_libraries(torrentxt_libtorrent INTERFACE ${LibtorrentRasterbar_LIBRARIES})
    else()
        message(FATAL_ERROR
            "TORRENTXT_USE_SYSTEM_LIBTORRENT: found LibtorrentRasterbar but neither a "
            "target nor *_LIBRARIES — check your install / vcpkg triplet.")
    endif()
    # libtorrent's package config pulls in its Boost dependency transitively, but
    # ask explicitly so a missing Boost fails HERE with a clear message.
    find_package(Boost 1.70 REQUIRED)
    message(STATUS "TorrentXT: using SYSTEM libtorrent (find_package) + Boost ${Boost_VERSION}")
else()
    include(FetchContent)
    set(FETCHCONTENT_QUIET OFF)   # the Boost/libtorrent fetch is long; show progress

    # libtorrent 2.0.x bundles its own try_signal/asio shims and, crucially, can
    # pull Boost itself. We let libtorrent's CMake drive the Boost requirement and
    # only steer its options. Build the static library (we relink it into our .so),
    # no deprecated APIs, no examples/tests/tools (build-time savings).
    set(BUILD_SHARED_LIBS         OFF CACHE BOOL "" FORCE)  # static libtorrent + Boost
    set(deprecated-functions      OFF CACHE BOOL "" FORCE)  # libtorrent option names are lower-case
    set(build_examples            OFF CACHE BOOL "" FORCE)
    set(build_tests               OFF CACHE BOOL "" FORCE)
    set(build_tools               OFF CACHE BOOL "" FORCE)
    set(python-bindings           OFF CACHE BOOL "" FORCE)
    # Encryption (MSE/PE) is part of the protocol surface we promised (plan §0),
    # so keep libtorrent's built-in obfuscation on; it has no external OpenSSL
    # dependency by default in 2.0.x.
    set(encryption                ON  CACHE BOOL "" FORCE)

    FetchContent_Declare(
        libtorrent
        GIT_REPOSITORY https://github.com/arvidn/libtorrent.git
        GIT_TAG        ${TORRENTXT_LIBTORRENT_TAG}   # PINNED — v2.0.11 by default
        GIT_SHALLOW    TRUE
        GIT_PROGRESS   TRUE
        # libtorrent 2.0.x vendors Boost as a submodule under its build when asked;
        # pulling submodules guarantees a self-contained, reproducible Boost >= 1.70
        # without depending on a system Boost. This is the slow part of the build.
    )
    FetchContent_MakeAvailable(libtorrent)

    # libtorrent's exported target name. 2.0.x defines `torrent-rasterbar` (and an
    # alias `LibtorrentRasterbar::torrent-rasterbar`). Prefer the namespaced alias.
    if(TARGET LibtorrentRasterbar::torrent-rasterbar)
        target_link_libraries(torrentxt_libtorrent INTERFACE LibtorrentRasterbar::torrent-rasterbar)
    elseif(TARGET torrent-rasterbar)
        target_link_libraries(torrentxt_libtorrent INTERFACE torrent-rasterbar)
    else()
        message(FATAL_ERROR
            "FetchContent built libtorrent but the expected target "
            "(torrent-rasterbar) is missing — did the pinned tag change its CMake?")
    endif()
    message(STATUS "TorrentXT: using FetchContent libtorrent @ ${TORRENTXT_LIBTORRENT_TAG} (heavy build)")
endif()

# Make EVERY libtorrent/Boost include directory SYSTEM on whatever target carries
# it, so -Wall -Wextra applies to OUR code only. If the imported target already
# uses SYSTEM includes this is a harmless reaffirmation; if it does not (some
# MODULE finds), it is the thing that keeps our build warning-clean (plan §7).
get_target_property(_lt_aliased torrentxt_libtorrent ALIASED_TARGET)
# (interface include dirs are propagated; consumers below also mark them SYSTEM)

# ----------------------------------------------- the shim shared library ------
# Guard on the shim source: present from Phase 1 onward. Absent in the Phase-0
# skeleton, where we still want configure/tests to succeed.
set(TORRENTXT_SHIM_SRC "${CMAKE_CURRENT_SOURCE_DIR}/src/torrent_shim.cpp")
if(EXISTS "${TORRENTXT_SHIM_SRC}")
    add_library(torrentxt SHARED "${TORRENTXT_SHIM_SRC}")

    # THE name rule: bare token, no `lib` prefix, on every platform, so the file
    # is exactly torrentxt.{so,dll,dylib} and the `c:torrentxt>` binding resolves.
    set_target_properties(torrentxt PROPERTIES
        PREFIX ""
        OUTPUT_NAME "torrentxt"
        # No SONAME version decoration: the engine loads a flat file by name.
        NO_SONAME ON
        C_VISIBILITY_PRESET hidden
        CXX_VISIBILITY_PRESET hidden)

    # Our headers (btx_abi.h / btx_record.h / btx_handle_table.h) live in src/.
    target_include_directories(torrentxt PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

    # libtorrent/Boost as SYSTEM so their headers cannot trip our warning flags.
    target_link_libraries(torrentxt PRIVATE torrentxt::libtorrent torrentxt_flags torrentxt_link)
    # Re-mark the dependency includes SYSTEM on the consumer for belt-and-suspenders.
    get_target_property(_lt_incs torrentxt_libtorrent INTERFACE_INCLUDE_DIRECTORIES)
    if(_lt_incs)
        target_include_directories(torrentxt SYSTEM PRIVATE ${_lt_incs})
    endif()

    # macOS: build a universal (arm64;x86_64) dylib so one file serves both Apple
    # silicon and Intel (plan §7 "macOS universal"). Set on the command line for
    # CI; honoured here if the user passed -DCMAKE_OSX_ARCHITECTURES.
    if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
        message(STATUS "TorrentXT: pass -DCMAKE_OSX_ARCHITECTURES=\"arm64;x86_64\" for a universal dylib")
    endif()

    # 32-bit Windows: cdecl name-decoration ('_btx_foo') can confuse the engine's
    # GetProcAddress-by-name lookup. A module-definition (.def) lists the exact,
    # UNDECORATED export names so the DLL exports `btx_*` verbatim (matches the
    # .lcb "c:torrentxt>btx_*!cdecl" strings). We generate the .def from the ABI
    # symbol list (kept in sync by hand with btx_abi.h — adding a symbol bumps the
    # ABI anyway). Applied on all MSVC bitnesses; it is harmless on x64 and the
    # required fix on x86.
    if(MSVC)
        set(_def "${CMAKE_CURRENT_BINARY_DIR}/torrentxt.def")
        # The exported surface == every BTX_API symbol in src/btx_abi.h.
        set(_btx_exports
            btx_abi_version
            btx_session_new
            btx_session_free
            btx_last_error
            btx_clear_error
            btx_set_int
            btx_set_bool
            btx_set_str
            btx_get_setting
            btx_set_encryption_policy
            btx_add_magnet
            btx_add_torrent_file
            btx_add_with_resume
            btx_remove
            btx_pause
            btx_resume
            btx_force_recheck
            btx_force_reannounce
            btx_set_file_priority
            btx_set_file_priorities
            btx_set_piece_priority
            btx_set_torrent_limits
            btx_torrent_status
            btx_torrent_count
            btx_torrent_handle_at
            btx_info_hash_hex
            btx_piece_bitfield
            btx_peer_list
            btx_pop_alerts
            btx_dht_add_bootstrap
            btx_dht_state
            btx_dht_save_state
            btx_dht_load_state
            btx_save_resume
            btx_create_torrent)
        string(JOIN "\n    " _exports_joined ${_btx_exports})
        file(WRITE "${_def}" "; torrentxt.def — generated by CMakeLists.txt from the btx_abi.h export list.\n; Lists the UNDECORATED cdecl exports so 32-bit Windows exports btx_* verbatim\n; (matching the .lcb \"c:torrentxt>btx_*!cdecl\" bindings). Regenerated on configure.\nLIBRARY torrentxt\nEXPORTS\n    ${_exports_joined}\n")
        # Attach the .def to the link. On MSVC, target_sources with a .def file is
        # honoured by the linker as /DEF.
        target_sources(torrentxt PRIVATE "${_def}")
    endif()

    message(STATUS "TorrentXT: configured the `torrentxt` shared library")
else()
    message(STATUS "TorrentXT: src/torrent_shim.cpp not present yet — skipping the shared "
                   "library (Phase-0 skeleton). The header-only test still builds.")
endif()

# ----------------------------------------------------------------- tests ------
if(TORRENTXT_BUILD_TESTS)
    enable_testing()

    # (a) record_handle_test — NO libtorrent. Header-only: btx_record.h +
    #     btx_handle_table.h. This carries the project's nastiest bug surface (the
    #     big-endian -needed framing and the generation-tagged handles) and MUST
    #     run under gcc ASan+UBSan (CLAUDE.md). It builds and runs ANYWHERE, so it
    #     is the always-on local + CI gate. We force the sanitizer flags onto THIS
    #     target regardless of TORRENTXT_SANITIZE, because its whole purpose is to
    #     be the sanitized gate — but only on a compiler that has the runtime
    #     (gcc; not MSVC, where we fall back to a plain /W3 build).
    set(_rht_src "${CMAKE_CURRENT_SOURCE_DIR}/tests/record_handle_test.cpp")
    if(EXISTS "${_rht_src}")
        add_executable(record_handle_test "${_rht_src}")
        target_include_directories(record_handle_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
        target_link_libraries(record_handle_test PRIVATE torrentxt_flags)
        if(NOT MSVC AND NOT TORRENTXT_SANITIZE)
            # Turn the sanitizers on for just this executable when the global knob
            # is off, so `-DTORRENTXT_BUILD_TESTS=ON` alone still sanitizes the
            # header-only gate (its declared contract in the source banner).
            target_compile_options(record_handle_test PRIVATE
                -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
            target_link_options(record_handle_test PRIVATE -fsanitize=address,undefined)
        endif()
        add_test(NAME record_handle_test COMMAND record_handle_test)
        # Make UBSan's diagnostics fatal at runtime too (defence in depth with
        # -fno-sanitize-recover; halt_on_error makes ASan stop at the first fault).
        set_tests_properties(record_handle_test PROPERTIES
            ENVIRONMENT "UBSAN_OPTIONS=halt_on_error=1;ASAN_OPTIONS=halt_on_error=1")
    endif()

    # (b) torrent_smoke_test — links the shim + libtorrent. Covers session
    #     lifecycle, handle safety, add-from-buffer/magnet, the drain record
    #     format, and the EXCEPTION FIREWALL (force a throw, assert it surfaces as
    #     an error, never propagates). Guarded on BOTH the test file and the shim
    #     library existing, so the Phase-0 skeleton still configures.
    set(_smoke_src "${CMAKE_CURRENT_SOURCE_DIR}/tests/torrent_smoke_test.cpp")
    if(EXISTS "${_smoke_src}" AND TARGET torrentxt)
        add_executable(torrent_smoke_test "${_smoke_src}")
        target_include_directories(torrent_smoke_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
        # Link the shim AND libtorrent: the smoke test drives btx_* directly and
        # may also touch libtorrent types. SYSTEM includes keep its warnings mute.
        target_link_libraries(torrent_smoke_test PRIVATE torrentxt torrentxt::libtorrent torrentxt_flags torrentxt_link)
        get_target_property(_lt_incs2 torrentxt_libtorrent INTERFACE_INCLUDE_DIRECTORIES)
        if(_lt_incs2)
            target_include_directories(torrent_smoke_test SYSTEM PRIVATE ${_lt_incs2})
        endif()
        # The test loads symbols from the shim .so it links; on *nix make sure the
        # loader can find our just-built library next to the test binary.
        if(UNIX AND NOT APPLE)
            set_target_properties(torrent_smoke_test PROPERTIES
                BUILD_RPATH "$<TARGET_FILE_DIR:torrentxt>")
        endif()
        add_test(NAME torrent_smoke_test COMMAND torrent_smoke_test)
        set_tests_properties(torrent_smoke_test PROPERTIES
            ENVIRONMENT "UBSAN_OPTIONS=halt_on_error=1;ASAN_OPTIONS=halt_on_error=1")
    elseif(EXISTS "${_smoke_src}")
        message(STATUS "TorrentXT: tests/torrent_smoke_test.cpp present but the shim library "
                       "is not — skipping the smoke test (needs src/torrent_shim.cpp).")
    else()
        message(STATUS "TorrentXT: tests/torrent_smoke_test.cpp not present yet — only "
                       "record_handle_test is registered (Phase-0/skeleton).")
    endif()

    # (c) rp1_integration_test — PROVES the rp1 peer-wire path end to end in ONE
    #     process: two loopback libtorrent sessions with the real rp1 plugin
    #     exchange a message over a metadata-less phantom swarm. This is the
    #     on-wire behavior no unit test can reach (handshake negotiation, the
    #     tick() flush, on_extended delivery, connection hold). It needs NO network
    #     (an explicit loopback connect_peer wires the two peers together).
    set(_rp1_src "${CMAKE_CURRENT_SOURCE_DIR}/tests/rp1_integration_test.cpp")
    if(EXISTS "${_rp1_src}" AND TARGET torrentxt)
        add_executable(rp1_integration_test "${_rp1_src}")
        target_include_directories(rp1_integration_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
        target_link_libraries(rp1_integration_test PRIVATE torrentxt torrentxt::libtorrent torrentxt_flags torrentxt_link)
        get_target_property(_lt_incs3 torrentxt_libtorrent INTERFACE_INCLUDE_DIRECTORIES)
        if(_lt_incs3)
            target_include_directories(rp1_integration_test SYSTEM PRIVATE ${_lt_incs3})
        endif()
        if(UNIX AND NOT APPLE)
            set_target_properties(rp1_integration_test PROPERTIES
                BUILD_RPATH "$<TARGET_FILE_DIR:torrentxt>")
        endif()
        add_test(NAME rp1_integration_test COMMAND rp1_integration_test)
        # Loopback exchange plus the ~1s per-peer tick: give it room. Also mute the
        # ASan container-overflow false positive that a shim built WITH ASan hits
        # against a libtorrent built WITHOUT it (a known mixed-instrumentation case).
        set_tests_properties(rp1_integration_test PROPERTIES
            TIMEOUT 120
            ENVIRONMENT "UBSAN_OPTIONS=halt_on_error=1;ASAN_OPTIONS=detect_container_overflow=0:halt_on_error=1")
    endif()
endif()
