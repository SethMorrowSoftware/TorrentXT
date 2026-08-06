# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

> **Phase 0 only.** The plan is `TorrentXT`'s `docs/NEXT-EXTENSIONS-PLAN.md`
> Part III ("ENet — real-time, step 1"); this folder currently holds the
> milestone-0 spike (pinned build + shim export/firewall proof + one-process
> loopback under sanitizers). Phase 1 copies the proven family pattern from
> the siblings — read `datachannelxt/CLAUDE.md` (or the standalone
> dataChannelXT repo) for the full as-built rulebook this will inherit.

## The rules that carry over unchanged

1. **Never call script from a foreign thread** — trivially satisfied here:
   ENet has NO internal threads. The flip side is the binding's defining
   property: **pump or nothing.** Nothing connects, sends, or receives unless
   `enet_host_service` is called; the `enPoll` drain (each tick: loop
   `enet_host_service(host, &e, 0)` until 0) is the transport's heartbeat and
   its cadence is the latency floor (16–33 ms for real-time feel).
2. **The exception firewall** — every `enx_*` entry point body runs inside
   `ENX_GUARD_*` (see `src/enx_abi.h`). Two sibling lessons are baked into the
   macros' comment and MUST be kept: one declaration per line inside a guard
   body (the macro-comma trap), and no preprocessor directive inside a guard
   body (gcc tolerates it, MSVC rejects it — C2121; hoist into a helper).
3. **Payload crosses here by design** (packets ARE messages: game state,
   control) but ENet is not for files — bulk belongs to TorrentXT. Packet
   ownership: `enet_packet_create` copies in; after `enet_peer_send` the host
   owns the packet; on RECEIVE copy the bytes out THEN `enet_packet_destroy`
   — never hand script a pointer into ENet-owned memory (the spike models
   this copy-then-destroy shape).

## Phase 0 facts

- Dependency pinned: ENet v1.3.18 (MIT) via FetchContent; headers are SYSTEM
  headers (their warnings are not ours; our code stays -Wall -Wextra clean).
- One shared library, bare token `enetxt` (PREFIX "", same shipping shape as
  the siblings: `src/code/<arch>-<platform>/enetxt.{so,dll,dylib}` later).
- `ENETXT_SANITIZE` is the family's GLOBAL sanitizer knob (injected before
  FetchContent so ENet is instrumented too). "address" is the lane that
  matters; ENet is threadless so TSan is academic.
- `enet_initialize`/`enet_deinitialize` are process-global; the shim
  refcounts them so paired calls stay balanced (many HOSTS per process are
  fine — the single-session rule of torrentxt does NOT apply here).
- The spike is the reference scenario Phase 1's wrapped calls must reproduce:
  server+client hosts in one process, connect data, reliable echo both ways,
  unsequenced on a second channel, disconnect data, teardown.

## Building

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENETXT_BUILD_TESTS=ON
cmake --build build --parallel && ctest --test-dir build --output-on-failure
cmake -S . -B build-asan -DENETXT_BUILD_TESTS=ON -DENETXT_SANITIZE=address
cmake --build build-asan --parallel && ./build-asan/enet_spike_test
```

gcc for the sanitizer lane (clang's runtimes are not installed in this
environment). A shim change is "done" only with the spike green under
ASan/UBSan.
