# enetxt (Phase 0)

**ENet — reliable-UDP real-time messaging — for OpenXTalk / the xTalk family.**
The third leg of the real-time stack: TorrentXT moves bulk, DataChannelXT
reaches browsers through NATs, enetxt will carry game-grade many-peer traffic
(state sync, presence, live collab) with reliable, unreliable-sequenced, and
unsequenced delivery per channel.

**Status: Phase 0** — the milestone-0 spike from `TorrentXT`'s
`docs/NEXT-EXTENSIONS-PLAN.md` Part III: the pinned ENet (v1.3.18, MIT) builds
via FetchContent into the family's bare-token shared library (`enetxt.so`),
the `enx_` export + exception-firewall pattern is proven, and
`tests/enet_spike_test.cpp` drives a one-process loopback — connect (with
connect data), reliable echo both ways byte-for-byte, an unsequenced packet on
a second channel, graceful disconnect — clean under ASan/UBSan.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENETXT_BUILD_TESTS=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure

# the sanitizer lane (gcc; the knob instruments ENet too):
cmake -S . -B build-asan -DENETXT_BUILD_TESTS=ON -DENETXT_SANITIZE=address
cmake --build build-asan --parallel && ./build-asan/enet_spike_test
```

Phase 1 (next): the full `enx_` surface — gen-tagged host/peer handle tables,
the family record codec, the pump-driven `enPoll` drain (ENet has no threads;
the poll loop IS the transport's heartbeat), send/broadcast, tuning + stats —
then the LCB binding (`org.openxtalk.library.enet`, public `en*`), static
gates, docs, CI, and a chat/whiteboard demo. See `CLAUDE.md` for the carried
rules.
