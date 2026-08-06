# DataChannelXT

**WebRTC data channels for OpenXTalk / the xTalk family** — browser-interoperable,
NAT-traversing, real-time peer-to-peer messaging from plain xTalk script.

DataChannelXT binds [libdatachannel](https://github.com/paullouisageneau/libdatachannel)
(C++17, MPL-2.0 — WebRTC data channels with libjuice ICE and usrsctp SCTP) behind a
flat `extern "C"` shim with a thin LCB layer on top, the same proven shape as its
siblings TorrentXT (libtorrent), cryptoXT (libsodium), Box2Dxt, and ShowControl:

```
libdatachannel + libjuice + usrsctp (+ system OpenSSL)   owns the network threads
   |- C++ shim     src/datachannel_shim.cpp  ->  datachannelxt.{so,dll,dylib}  (ABI: dcx_*)
        |- LCB binding  src/datachannel.lcb       (library org.openxtalk.library.datachannel; public dc*)
             |- script helpers  examples/datachannel-helpers.livecodescript  (the poll dispatcher)
```

An OXT app gets what no xTalk environment has had: a **direct, encrypted, real-time
channel to another machine — or to a web browser** — that punches through NATs
(ICE/STUN/TURN), with reliable *and* unreliable delivery modes, ordered and
unordered, from a dozen lines of script.

## What it can do

- **Talk to browsers.** A data channel opened here is a standard WebRTC data
  channel; the far side can be five lines of JavaScript on any modern browser.
- **Punch through NATs.** ICE with STUN/TURN (libjuice) finds a path between two
  home connections without either side configuring a router.
- **Real-time modes.** Reliable+ordered by default; `dcCreateChannelEx` unlocks
  unordered and unreliable (max-retransmits / max-lifetime) channels for game
  state and live cursors, plus negotiated channels on fixed stream ids.
- **Backpressure.** `dcBufferedAmount` + the `dcBufferedLow` event let a sender
  throttle instead of ballooning memory.
- **Text and binary.** `dcSendText` arrives as a string (browser: `string`),
  `dcSendData` as bytes (browser: `ArrayBuffer`), up to 60 000 bytes per message
  (the documented budget — route bulk transfer to TorrentXT, which exists for it).

## Quick taste

```livecodescript
start using stack "dataChannelHelpers"      -- the poll dispatcher
dcStartPolling the long id of this card, 33 -- ~30 Hz drain

put dcCreatePeer("stun:stun.l.google.com:19302") into tPeer
put dcCreateChannel(tPeer, "chat") into tChan
-- creating the first channel starts negotiation; now catch the artifacts:

on dcLocalDescription pEvent
   -- ship pEvent["sdp"] + pEvent["sdpType"] to the far peer over ANY channel
end dcLocalDescription

on dcLocalCandidate pEvent
   -- ship pEvent["candidate"] + pEvent["mid"] the same way
end dcLocalCandidate

-- ...and feed the far side's artifacts back in:
--   dcSetRemoteDescription tPeer, tSdp, tType
--   dcAddRemoteCandidate tPeer, tCandidate, tMid

on dcChannelOpen pEvent
   dcSendText(pEvent["channel"], "hello from xTalk!")
end dcChannelOpen

on dcMessage pEvent
   put pEvent["text"] into field "chat"
end dcMessage
```

**Signaling is yours** — WebRTC needs the two peers to exchange a description and
candidates over *some* existing channel, and that channel is your choice: a
TorrentXT DHT rendezvous (the serverless flagship pairing), a copy/paste, a web
service. `examples/datachannel-loopback.livecodescript` is a complete working
demo where "signaling" is four lines of script, because both peers live in the
same stack; `docs/getting-started.md` walks the real thing.

## Try it now (no network, no setup)

Open `examples/datachannel-loopback.livecodescript` as a stack script alongside
the helpers: two real WebRTC peers negotiate inside one process — offer, answer,
ICE, DTLS, SCTP — and you chat between two panes. If that works, the whole
pipeline works; real signaling is the only thing left to add.

## Then try the flagship (two machines, no server)

`examples/datachannel-dht-chat.livecodescript` supplies that real signaling
with the family's own answer: **TorrentXT's DHT.** Host a room on one machine,
paste the room code on the other, and the WebRTC handshake travels as signed
BEP44 items over the BitTorrent DHT — then the chat itself is a direct,
DTLS-encrypted data channel between the two machines. No account, no server,
no port forward, nothing to operate. It needs the TorrentXT extension
installed alongside this one (probed at startup; fails closed with a clear
message when missing); `docs/getting-started.md` section 6 has the tour.

## Install

DataChannelXT ships as a standard OXT extension: the LCB module plus the
per-platform native library bundled under `src/code/<arch>-<platform>/`
(`x86_64-linux`, `x86-linux`, `x86_64-win32`, `x86-win32`, `universal-mac`).
Installing the packaged extension makes the engine resolve the
`c:datachannelxt>` binding automatically — no loose library, no `sudo`, no
`LD_LIBRARY_PATH`. See `docs/getting-started.md`.

One rule the app must follow: **call `dcCleanup()` before quitting** (e.g. on
`closeStack`). There is no automatic unload hook; skipping it leaks the native
worker threads at quit.

## Documentation

| Doc | What is in it |
|---|---|
| `docs/getting-started.md` | install, first connection, the signaling walk-through |
| `docs/api-reference.md`   | every `dc*` handler, event, key, and constant |
| `docs/architecture.md`    | the shim design: the mutex queue, handles, the record codec |
| `docs/building.md`        | building the native library on all five targets |

## Development

The native layer has a real test story — `tests/datachannel_smoke_test.cpp`
drives an in-process loopback (two peers, SDP/candidate shuttle, echo) through
the exported ABI, and CI runs it three ways: plain Release, **ASan+UBSan across
the whole dependency stack**, and **ThreadSanitizer** across the same (this is
the family's one binding with true cross-thread callbacks; TSan is the gate
that proves the queue). Static gates (`tools/check-livecodescript.py`, the
record golden, the registry cross-check) run without any native build.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DDATACHANNELXT_BUILD_TESTS=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

See `CLAUDE.md` for the engineering rules (the three safety rules, the lock
discipline, the FFI conventions) and `docs/building.md` for the sanitizer lanes.

## License

DataChannelXT is MIT (see `LICENSE`). It statically links
[libdatachannel](https://github.com/paullouisageneau/libdatachannel),
[libjuice](https://github.com/paullouisageneau/libjuice) (both MPL-2.0), and
[usrsctp](https://github.com/sctplab/usrsctp) (BSD-3); DTLS via the system
OpenSSL (Apache-2.0). MPL-2.0 is file-level copyleft and compatible with this
use — modifications to those libraries themselves must be published, and none
are made (they build from pinned upstream tags).
