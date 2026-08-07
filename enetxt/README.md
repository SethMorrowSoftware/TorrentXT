# enetxt

**ENet — reliable-UDP real-time networking — for OpenXTalk / the xTalk
family.** Game-grade many-peer messaging from plain xTalk script: reliable,
unreliable-sequenced, and unsequenced delivery on independent channels,
sub-frame latency on a LAN, one broadcast to fan out to every peer.

enetxt binds [ENet](https://github.com/lsalzman/enet) (v1.3.18, MIT — the
reliable-UDP library a generation of games shipped on) behind a flat
`extern "C"` shim with a thin LCB layer on top, the proven shape of its
siblings TorrentXT (libtorrent), dataChannelXT (libdatachannel), and cryptoXT
(libsodium):

```
ENet v1.3.18 (static)                          sockets + the reliability protocol
   |- C++ shim   src/enet_shim.cpp  ->  enetxt.{so,dll,dylib}   (ABI: enx_*, v2)
        |- LCB binding  src/enet.lcb      (org.openxtalk.library.enet; public en*)
             |- examples/enet-helpers.livecodescript   (the pump)
```

It completes the family's real-time story: **enetxt** for many peers at game
cadence where someone is reachable (LAN, port forward, rented box);
**dataChannelXT** for NAT-traversed pairs and browsers; **TorrentXT** for
bulk. The 60 000-byte packet budget here is the seam — when a payload stops
being a message, move it to torrents.

## What it can do

- **Hosts and peers, not sockets.** `enHostCreateServer` /
  `enHostCreateClient` / `enConnect`, with generation-tagged integer handles
  everywhere — a stale handle is always a harmless no-op.
- **Three delivery modes per send** — reliable (acked, ordered), unreliable
  (sequenced, droppable: perfect for state you overwrite every tick),
  unsequenced (fire-and-forget) — on up to 255 independent channels, so
  reliable traffic can never stall the real-time lane.
- **One-call fanout.** `enBroadcast` queues one packet to every connected
  peer — the server-relay primitive.
- **Live stats.** `enPeerStatus` is one FFI round-trip: state, RTT, packet
  loss, byte counters, address. Plus tuning: timeouts, ping interval,
  bandwidth throttles.
- **Pump-driven by design.** ENet has no threads; the helpers' poll loop IS
  the transport ("pump or nothing"), which makes rule 1 of the family — never
  call script from a foreign thread — true by construction.

## Quick taste

```livecodescript
start using stack "enetHelpers"
put enHostCreateServer("", 27099, 32, 2, 0, 0) into sServer
enStartPolling sServer, the long id of this card, 33   -- the heartbeat

on enetConnect pEvent
   enSendText pEvent["peer"], 0, "welcome!", 0          -- 0 = reliable
end enetConnect

on enetReceive pEvent
   enBroadcast sServer, 0, pEvent["payload"], 0         -- relay to everyone
end enetReceive
```

`docs/getting-started.md` walks the rest (the client side, delivery modes,
the protocol-version trick); `examples/enet-lan-chat.livecodescript` is the
complete two-machine demo.

## Install

enetxt ships as a standard OXT extension: the LCB module plus the
per-platform native library bundled under `src/code/<arch>-<platform>/`
(`x86_64-linux`, `x86-linux`, `x86_64-win32`, `x86-win32`, `universal-mac`).
Installing the packaged extension makes the engine resolve the `c:enetxt>`
binding automatically. See `docs/getting-started.md`.

One rule the app must follow: **call `enDeinitialize` before quitting**
(e.g. on `closeStack`) — there is no automatic unload hook.

## Documentation

| Doc | What is in it |
|---|---|
| `docs/getting-started.md` | install, first server+client, delivery modes |
| `docs/api-reference.md`   | every `en*` handler, event, key, and constant |
| `docs/architecture.md`    | the pump model, the lossless stash drain, handles |
| `docs/building.md`        | building on all five targets (minutes, not hours) |

## Development

`tests/enet_smoke_test.cpp` drives the ENTIRE exported ABI over a live
one-process loopback — connect data, reliable echo, broadcast, byte-exact
payloads, the keyhole partial-drain (lossless at any buffer size), handle
retirement, teardown — and runs under **ASan+UBSan with ENet itself
instrumented**. `record_handle_test` + the Python golden pin the wire format;
`check-record-registry.py` enforces registry/ABI/budget sync; the
LiveCodeScript static gate carries all three of the family's OXT-compile
antipattern rules.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENETXT_BUILD_TESTS=ON
cmake --build build --parallel && ctest --test-dir build --output-on-failure
```

See `CLAUDE.md` for the engineering rules and `docs/building.md` for the
sanitizer lane. Binding-side runtime behaviour is confirmed in OXT: the
selftest (`tests/enet-selftest.livecodescript`) ran green on 2026-08-07.

## License

enetxt is MIT (matching the family). It statically links
[ENet](https://github.com/lsalzman/enet) (MIT).
