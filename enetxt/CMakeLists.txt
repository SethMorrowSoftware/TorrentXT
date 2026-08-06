# enetxt - ENet (reliable UDP) for OpenXTalk / the xTalk family.
# PHASE 0 (NEXT-EXTENSIONS-PLAN.md Part III.7 milestone 0): prove the pinned
# dependency builds, prove the bare-token shared library exports through the
# exception firewall, and prove a one-process loopback (connect -> reliable
# echo both ways -> unsequenced send -> disconnect) runs clean under the
# sanitizers. The full enx_ surface (handle tables, record codec, poll drain)
# is milestone 1 and reuses the datachannelxt/torrentxt pattern verbatim.
cmake_minimum_required(VERSION 3.16)
project(enetxt CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ENet builds as a static archive that we fold into ONE shared library, so
# everything (the dependency included) must be position-independent — set it
# globally BEFORE FetchContent or the link fails with ld: "bad value".
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(ENETXT_BUILD_TESTS "Build the Phase 0 spike test" OFF)

# The family's sanitizer knob: a STRING ("address" or "thread"), injected
# GLOBALLY before FetchContent so the whole dependency is instrumented too
# (the datachannelxt lesson: per-target flags leave the dependency bare and
# the sanitizers false-positive on its internals). ENet has no threads, so
# "thread" is academic here - "address" is the lane that matters.
set(ENETXT_SANITIZE "" CACHE STRING "Sanitizer: '', 'address', or 'thread'")
if(ENETXT_SANITIZE STREQUAL "address")
  add_compile_options(-fsanitize=address,undefined -fno-sanitize-recover=all -g)
  add_link_options(-fsanitize=address,undefined)
elseif(ENETXT_SANITIZE STREQUAL "thread")
  add_compile_options(-fsanitize=thread -g)
  add_link_options(-fsanitize=thread)
endif()

# Pin the dependency (the family rule: pin every version; bump deliberately).
include(FetchContent)
FetchContent_Declare(enet
  GIT_REPOSITORY https://github.com/lsalzman/enet.git
  GIT_TAG        v1.3.18
)
FetchContent_MakeAvailable(enet)

# The shim: ONE shared library, bare token (no 'lib' prefix), same shipping
# shape as torrentxt/datachannelxt - src/code/<arch>-<platform>/enetxt.so etc.
add_library(enetxt SHARED src/enet_shim.cpp)
set_target_properties(enetxt PROPERTIES PREFIX "" OUTPUT_NAME enetxt)
target_compile_options(enetxt PRIVATE -Wall -Wextra)
# ENet's headers are SYSTEM headers to us: their warnings are not our warnings.
target_include_directories(enetxt SYSTEM PRIVATE ${enet_SOURCE_DIR}/include)
target_link_libraries(enetxt PRIVATE enet)

if(ENETXT_BUILD_TESTS)
  enable_testing()

  # The Phase 1 gate: the whole exported ABI over a live loopback. Links ONLY
  # the shared library — every call goes through the real export surface.
  add_executable(enet_smoke_test tests/enet_smoke_test.cpp)
  target_compile_options(enet_smoke_test PRIVATE -Wall -Wextra)
  target_link_libraries(enet_smoke_test PRIVATE enetxt)
  add_test(NAME enet_smoke_test COMMAND enet_smoke_test)

  # Codec + handle-table unit test: header-only, no ENet, runs anywhere.
  add_executable(record_handle_test tests/record_handle_test.cpp)
  target_compile_options(record_handle_test PRIVATE -Wall -Wextra)
  add_test(NAME record_handle_test COMMAND record_handle_test)
endif()
