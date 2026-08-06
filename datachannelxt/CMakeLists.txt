# CMakeLists.txt — DataChannelXT native build (NEXT-EXTENSIONS-PLAN Part IV).
#
# WHAT THIS BUILDS
#   ONE shared library, the C++ shim `src/datachannel_shim.cpp`, statically
#   linking libdatachannel (WebRTC data channels) and its vendored dependency
#   stack (libjuice for ICE, usrsctp for SCTP, plog; DTLS via the SYSTEM
#   OpenSSL), exported with the flat `dcx_*` C ABI. The file MUST be named with
#   the BARE TOKEN `datachannelxt` (no `lib` prefix) so it matches the LCB
#   binding string `c:datachannelxt>` — datachannelxt.so / .dll / .dylib, NEVER
#   libdatachannelxt.* (set via PREFIX "" / OUTPUT_NAME below). The .lcb and the
#   committed per-platform binaries under src/code/<arch>-<platform>/ are NOT
#   built here — `tools/package-extension.py` copies a fresh build into that tree.
#
# WHY the dependency build is the risk, not the binding (plan Part IV.5): the
#   FFI is indifferent to what sits behind the symbols; the cost is acquiring
#   and statically linking libdatachannel + libjuice + usrsctp across five
#   targets. So we (a) PIN libdatachannel to a release tag and let its own CMake
#   drive the vendored submodules (reproducible), (b) treat all dependency
#   headers as SYSTEM headers so their warnings never pollute our -Wall -Wextra,
#   and (c) keep a system/vcpkg fast path for CI lanes that already have the
#   library.
#
# WHY media/WebSocket are OFF: Phase 1 is DATA CHANNELS ONLY (plan Part IV.4).
#   NO_MEDIA drops the libsrtp dependency entirely; NO_WEBSOCKET trims the
#   surface we would otherwise have to firewall and document. Turning either on
#   later is an ABI-widening change with its own plan phase.
#
# WHY the sanitizer knob is a STRING ("", address, thread) and GLOBAL: this is
#   the one binding with real cross-thread concurrency (libdatachannel fires
#   callbacks from its own threads), so ThreadSanitizer must see BOTH sides of
#   every lock — ours AND the dependency's. Setting plain target flags on the
#   shim alone would leave libdatachannel/usrsctp uninstrumented and TSan would
#   report false races on their internal atomics. The knob therefore injects
#   the flags into CMAKE_C_FLAGS/CMAKE_CXX_FLAGS BEFORE FetchContent so the
#   whole static stack is built instrumented. (address = ASan+UBSan; thread =
#   TSan; they are mutually exclusive.) gcc only — clang's sanitizer runtimes
#   are not installed in our CI environment (house rule).

cmake_minimum_required(VERSION 3.16)   # FetchContent + generator expressions we use

project(DataChannelXT
    VERSION 0.1.0
    DESCRIPTION "OpenXTalk binding to libdatachannel (flat dcx_ C ABI)"
    LANGUAGES C CXX)   # C: usrsctp/libjuice ride in the same static build

# ----------------------------------------------------------------- options ----
option(DATACHANNELXT_BUILD_TESTS "Build the ctest suite (record_handle_test + datachannel_smoke_test)" OFF)
option(DATACHANNELXT_USE_SYSTEM_LIBDATACHANNEL "find_package(LibDataChannel) instead of FetchContent (vcpkg / system install)" OFF)
set(DATACHANNELXT_SANITIZE "" CACHE STRING
    "Sanitizer lane: \"\" (off), \"address\" (ASan+UBSan), or \"thread\" (TSan). Applied to the WHOLE build including dependencies.")
set_property(CACHE DATACHANNELXT_SANITIZE PROPERTY STRINGS "" "address" "thread")
set(DATACHANNELXT_LIBDATACHANNEL_TAG "v0.24.5" CACHE STRING
    "Pinned libdatachannel git tag for the FetchContent path")

# Single-config generators (Make/Ninja) need an explicit default build type;
# multi-config ones (MSVC, Xcode) ignore this and pick per --config at build time.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
    message(STATUS "DataChannelXT: no build type set; defaulting to Release")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)          # -std=c++17, not -std=gnu++17 (portability)

# Hide everything by default; the ABI opts symbols back in with the explicit
# DCX_API export macro (dcx_abi.h). Keeps libdatachannel's symbol surface OUT of
# our exports and shrinks the .so.
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)  # a shared lib statically linking deps needs -fPIC throughout

# On MSVC, match the CRT that vcpkg's *-windows-static triplet links the
# dependencies against: the STATIC runtime (/MT). Mixing /MD and /MT
# multiply-defines the CRT symbols (LNK4098 -> LNK1169). Same rule as TorrentXT.
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# ------------------------------------------------- the global sanitizer knob --
# MUST run before FetchContent so the dependency stack is instrumented too (see
# the header comment). -fno-sanitize-recover=all turns UB into a hard failure so
# a smoke-test run cannot pass while quietly miscompiling.
if(DATACHANNELXT_SANITIZE STREQUAL "address")
    if(MSVC)
        message(WARNING "DATACHANNELXT_SANITIZE ignored on MSVC (use the gcc lanes)")
    else()
        set(_dcx_san "-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer")
        set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} ${_dcx_san}")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_dcx_san}")
        set(CMAKE_EXE_LINKER_FLAGS    "${CMAKE_EXE_LINKER_FLAGS} -fsanitize=address,undefined")
        set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -fsanitize=address,undefined")
        message(STATUS "DataChannelXT: building EVERYTHING under ASan+UBSan")
    endif()
elseif(DATACHANNELXT_SANITIZE STREQUAL "thread")
    if(MSVC)
        message(WARNING "DATACHANNELXT_SANITIZE ignored on MSVC (use the gcc lanes)")
    else()
        set(_dcx_san "-fsanitize=thread -fno-omit-frame-pointer")
        set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} ${_dcx_san}")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_dcx_san}")
        set(CMAKE_EXE_LINKER_FLAGS    "${CMAKE_EXE_LINKER_FLAGS} -fsanitize=thread")
        set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -fsanitize=thread")
        message(STATUS "DataChannelXT: building EVERYTHING under ThreadSanitizer")
    endif()
endif()

# --------------------------------------------------- our warning/flag set ----
# Applied ONLY to our translation units (the shim + tests), never to the
# dependencies — those ride in as SYSTEM includes so their warnings are mute.
add_library(datachannelxt_flags INTERFACE)
if(MSVC)
    target_compile_options(datachannelxt_flags INTERFACE /W3 /EHsc /permissive-)
    target_compile_definitions(datachannelxt_flags INTERFACE
        WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(datachannelxt_flags INTERFACE -Wall -Wextra)
endif()

# Portable-Linux link posture: static libstdc++/libgcc so the committed .so does
# not demand a newer libstdc++.so.6 than the user's host provides (the same
# posture as the sibling extensions; the real glibc floor is the release image).
add_library(datachannelxt_link INTERFACE)
if(UNIX AND NOT APPLE)
    target_link_options(datachannelxt_link INTERFACE -static-libstdc++ -static-libgcc)
endif()

# ------------------------------------------------- acquire libdatachannel -----
# Two paths, selected by DATACHANNELXT_USE_SYSTEM_LIBDATACHANNEL:
#
#   SYSTEM  : find_package(LibDataChannel). The vcpkg path and the "already
#             installed" path. FAST — no dependency rebuild.
#
#   DEFAULT : FetchContent at the pinned tag. PORTABLE and reproducible; clones
#             the vendored submodules (libjuice, usrsctp, plog) and builds the
#             whole stack static. DTLS comes from the SYSTEM OpenSSL (the same
#             static-openssl posture as TorrentXT is a release-image concern).
#
# Either way the rest of the file links `datachannelxt::libdatachannel` so the
# shim/test targets do not care which path ran.
add_library(datachannelxt_libdatachannel INTERFACE)
add_library(datachannelxt::libdatachannel ALIAS datachannelxt_libdatachannel)

set(DATACHANNELXT_NEED_LIB OFF)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/datachannel_shim.cpp")
    set(DATACHANNELXT_NEED_LIB ON)
elseif(DATACHANNELXT_BUILD_TESTS AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/datachannel_smoke_test.cpp")
    set(DATACHANNELXT_NEED_LIB ON)
endif()

if(NOT DATACHANNELXT_NEED_LIB)
    message(STATUS "DataChannelXT: nothing links libdatachannel yet — skipping acquisition. "
                   "Only the header-only gate will build.")
elseif(DATACHANNELXT_USE_SYSTEM_LIBDATACHANNEL)
    find_package(LibDataChannel CONFIG REQUIRED)
    # Prefer the static target when the install provides one; fall back to the
    # default (vcpkg's static triplets export LibDataChannel::LibDataChannel as
    # static anyway).
    if(TARGET LibDataChannel::LibDataChannelStatic)
        target_link_libraries(datachannelxt_libdatachannel INTERFACE LibDataChannel::LibDataChannelStatic)
    elseif(TARGET LibDataChannel::LibDataChannel)
        target_link_libraries(datachannelxt_libdatachannel INTERFACE LibDataChannel::LibDataChannel)
    else()
        message(FATAL_ERROR "LibDataChannel package found but no usable target exported.")
    endif()
    message(STATUS "DataChannelXT: using SYSTEM libdatachannel (find_package)")
else()
    include(FetchContent)
    set(FETCHCONTENT_QUIET OFF)   # the submodule clone takes a moment; show progress

    # Steer libdatachannel's own CMake (option names are libdatachannel's):
    #   - static lib only (we relink it into our ONE .so)
    #   - OpenSSL for DTLS (USE_GNUTLS/USE_MBEDTLS off is the default; asserted
    #     here so a future default flip upstream cannot silently change our TLS)
    #   - libjuice for ICE (USE_NICE off), vendored submodules for everything
    #   - Phase 1 is data channels only: NO_MEDIA drops libsrtp entirely,
    #     NO_WEBSOCKET trims the WebSocket client/server
    #   - no examples/tests from the dependency
    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
    set(USE_GNUTLS        OFF CACHE BOOL "" FORCE)
    set(USE_MBEDTLS       OFF CACHE BOOL "" FORCE)
    set(USE_NICE          OFF CACHE BOOL "" FORCE)
    set(PREFER_SYSTEM_LIB OFF CACHE BOOL "" FORCE)
    set(NO_MEDIA          ON  CACHE BOOL "" FORCE)
    set(NO_WEBSOCKET      ON  CACHE BOOL "" FORCE)
    set(NO_EXAMPLES       ON  CACHE BOOL "" FORCE)
    set(NO_TESTS          ON  CACHE BOOL "" FORCE)

    FetchContent_Declare(
        libdatachannel
        GIT_REPOSITORY https://github.com/paullouisageneau/libdatachannel.git
        GIT_TAG        ${DATACHANNELXT_LIBDATACHANNEL_TAG}   # PINNED
        GIT_SHALLOW    TRUE
        GIT_PROGRESS   TRUE
        # No GIT_SUBMODULES override: the default clones ALL submodules, which is
        # exactly what the vendored libjuice/usrsctp/plog build needs.
    )
    FetchContent_MakeAvailable(libdatachannel)

    if(TARGET datachannel-static)
        target_link_libraries(datachannelxt_libdatachannel INTERFACE datachannel-static)
    elseif(TARGET LibDataChannel::LibDataChannelStatic)
        target_link_libraries(datachannelxt_libdatachannel INTERFACE LibDataChannel::LibDataChannelStatic)
    else()
        message(FATAL_ERROR
            "FetchContent built libdatachannel but the expected static target "
            "(datachannel-static) is missing — did the pinned tag change its CMake?")
    endif()
    message(STATUS "DataChannelXT: using FetchContent libdatachannel @ ${DATACHANNELXT_LIBDATACHANNEL_TAG}")
endif()

# ----------------------------------------------- the shim shared library ------
# Guard on the shim source (TorrentXT's phased-build pattern): configure succeeds
# on a skeleton checkout; the target lights up the moment the shim lands.
set(DATACHANNELXT_SHIM_SRC "${CMAKE_CURRENT_SOURCE_DIR}/src/datachannel_shim.cpp")
if(EXISTS "${DATACHANNELXT_SHIM_SRC}")
    add_library(datachannelxt SHARED "${DATACHANNELXT_SHIM_SRC}")

    # THE name rule: bare token, no `lib` prefix, on every platform, so the file
    # is exactly datachannelxt.{so,dll,dylib} and `c:datachannelxt>` resolves.
    set_target_properties(datachannelxt PROPERTIES
        PREFIX ""
        OUTPUT_NAME "datachannelxt"
        NO_SONAME ON
        C_VISIBILITY_PRESET hidden
        CXX_VISIBILITY_PRESET hidden)

    target_include_directories(datachannelxt PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

    # Record the pinned dependency version for dcx_library_version diagnostics.
    target_compile_definitions(datachannelxt PRIVATE
        DCX_LIBDATACHANNEL_VERSION="${DATACHANNELXT_LIBDATACHANNEL_TAG}")

    target_link_libraries(datachannelxt PRIVATE
        datachannelxt::libdatachannel datachannelxt_flags datachannelxt_link)
    # Dependency headers as SYSTEM so -Wall -Wextra applies to OUR code only.
    get_target_property(_dc_incs datachannelxt_libdatachannel INTERFACE_INCLUDE_DIRECTORIES)
    if(_dc_incs)
        target_include_directories(datachannelxt SYSTEM PRIVATE ${_dc_incs})
    endif()

    if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
        message(STATUS "DataChannelXT: pass -DCMAKE_OSX_ARCHITECTURES=\"arm64;x86_64\" for a universal dylib")
    endif()

    # 32-bit Windows: cdecl name-decoration can confuse the engine's by-name
    # export lookup; a .def lists the exact UNDECORATED names (harmless on x64,
    # required on x86). Kept in sync with dcx_abi.h by hand — adding a symbol
    # bumps the ABI anyway (same discipline as TorrentXT).
    if(MSVC)
        set(_def "${CMAKE_CURRENT_BINARY_DIR}/datachannelxt.def")
        set(_dcx_exports
            dcx_abi_version
            dcx_init
            dcx_cleanup
            dcx_library_version
            dcx_last_error
            dcx_clear_error
            dcx_peer_new
            dcx_peer_close
            dcx_peer_free
            dcx_set_local_description
            dcx_set_remote_description
            dcx_add_remote_candidate
            dcx_local_description
            dcx_local_description_type
            dcx_peer_state
            dcx_gathering_state
            dcx_selected_candidate_pair
            dcx_channel_new
            dcx_channel_new_ex
            dcx_channel_close
            dcx_channel_free
            dcx_send_data
            dcx_send_text
            dcx_channel_label
            dcx_channel_protocol
            dcx_channel_stream_id
            dcx_channel_is_open
            dcx_channel_peer
            dcx_channel_max_message
            dcx_buffered_amount
            dcx_set_buffered_low_threshold
            dcx_poll)
        string(JOIN "\n    " _exports_joined ${_dcx_exports})
        file(WRITE "${_def}" "; datachannelxt.def — generated by CMakeLists.txt from the dcx_abi.h export list.\n; Lists the UNDECORATED cdecl exports so 32-bit Windows exports dcx_* verbatim\n; (matching the .lcb \"c:datachannelxt>dcx_*!cdecl\" bindings). Regenerated on configure.\nLIBRARY datachannelxt\nEXPORTS\n    ${_exports_joined}\n")
        target_sources(datachannelxt PRIVATE "${_def}")
    endif()

    message(STATUS "DataChannelXT: configured the `datachannelxt` shared library")
else()
    message(STATUS "DataChannelXT: src/datachannel_shim.cpp not present yet — skipping the "
                   "shared library (skeleton). The header-only test still builds.")
endif()

# ----------------------------------------------------------------- tests ------
if(DATACHANNELXT_BUILD_TESTS)
    enable_testing()

    # (a) record_handle_test — header-only (dcx_record.h + dcx_handle_table.h),
    #     NO libdatachannel. Runs anywhere; carries the framing + handle-table
    #     bug surface, so it is force-sanitized (ASan+UBSan) even when the
    #     global knob is off — except on the TSan lane, where mixing ASan into
    #     a -fsanitize=thread build is invalid.
    set(_rht_src "${CMAKE_CURRENT_SOURCE_DIR}/tests/record_handle_test.cpp")
    if(EXISTS "${_rht_src}")
        add_executable(record_handle_test "${_rht_src}")
        target_include_directories(record_handle_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
        target_link_libraries(record_handle_test PRIVATE datachannelxt_flags)
        if(NOT MSVC AND DATACHANNELXT_SANITIZE STREQUAL "")
            target_compile_options(record_handle_test PRIVATE
                -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
            target_link_options(record_handle_test PRIVATE -fsanitize=address,undefined)
        endif()
        add_test(NAME record_handle_test COMMAND record_handle_test)
        set_tests_properties(record_handle_test PROPERTIES
            ENVIRONMENT "UBSAN_OPTIONS=halt_on_error=1;ASAN_OPTIONS=halt_on_error=1")
    endif()

    # (b) datachannel_smoke_test — links the shim + libdatachannel and runs a
    #     REAL in-process loopback: two peer connections, SDP/candidates
    #     shuttled through the ABI, channelOpen both ways, echo round-trip.
    #     This exercises the mutex queue under libdatachannel's actual threads,
    #     which is exactly what the ASan and TSan lanes are for.
    set(_smoke_src "${CMAKE_CURRENT_SOURCE_DIR}/tests/datachannel_smoke_test.cpp")
    if(EXISTS "${_smoke_src}" AND TARGET datachannelxt)
        add_executable(datachannel_smoke_test "${_smoke_src}")
        target_include_directories(datachannel_smoke_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
        target_link_libraries(datachannel_smoke_test PRIVATE
            datachannelxt datachannelxt_flags datachannelxt_link)
        if(UNIX AND NOT APPLE)
            set_target_properties(datachannel_smoke_test PROPERTIES
                BUILD_RPATH "$<TARGET_FILE_DIR:datachannelxt>")
        endif()
        add_test(NAME datachannel_smoke_test COMMAND datachannel_smoke_test)
        # ICE gathering + DTLS + SCTP handshakes on loopback: give it room.
        set_tests_properties(datachannel_smoke_test PROPERTIES
            TIMEOUT 180
            ENVIRONMENT "UBSAN_OPTIONS=halt_on_error=1;ASAN_OPTIONS=halt_on_error=1")
    elseif(EXISTS "${_smoke_src}")
        message(STATUS "DataChannelXT: smoke test present but the shim library is not — skipping.")
    endif()
endif()
