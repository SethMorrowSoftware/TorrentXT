# TorrentXT architecture

How the pieces fit, and why they are shaped this way. `../CLAUDE.md` holds the maintainer
rules and traps; `api-reference.md` is the call-by-call contract. Code comments that cite
"plan section N" refer to the retired design brief, readable in git history as
TorrentXT-IMPLEMENTATION-PLAN.md under torrentxt/docs/archive (last changed in bf9b158);
its still-current reasoning is the "Why it is built this way" section below.

## The stack, bottom to top

```
  libtorrent-rasterbar (C++, BSD-3) + Boost.Asio     owns the network + disk threads
        |
  src/torrent_shim.cpp        extern "C" facade, exports btx_* (the C ABI)
        |   #includes the three header-only contracts:
        |     src/btx_abi.h          - the frozen C ABI surface + version + error codes
        |     src/btx_record.h       - the KV record codec + field/alert/type registries
        |     src/btx_handle_table.h - generation-tagged handles (stale = no-op)
        |
        |   FFI:  c:torrentxt> btx_*   (ints, doubles, ZStringUTF8, Pointer+len)
        |
  src/torrent.lcb             library org.openxtalk.library.torrent
        |     - private foreign handler per btx_* symbol
        |     - public bt* handlers: hide every handle, pre-size buffers,
        |       walk records, set the module last-error, never throw to script
        |
  examples/torrent-helpers.livecodescript       the poll dispatcher (timer -> btPoll/btRp1Poll -> messages)
  examples/torrent-quickshare.livecodescript    drag a file, share a code (+ Tor, web link)
  examples/torrent-client.livecodescript        the multi-torrent client (self-building UI)
  examples/torrent-dht-channels.livecodescript  decentralized DHT + BitTorrent channels
  examples/torrent-rp1-chat.livecodescript      messaging over the rp1 peer wire
        |
  your xTalk app              writes event handlers (metadataReceived, pieceFinished, ...)
```

The native side ships **bundled inside the extension** under
`src/code/<arch>-<platform>/torrentxt.{so,dll,dylib}` (bare token, no `lib` prefix).
Installing the packaged extension lets the engine resolve the `c:torrentxt>` binding
automatically via `the revLibraryMapping`.

## The three rules that make this safe

These are load-bearing, restated in `../CLAUDE.md` and enforced in code:

1. **Never call an LCB handler from a libtorrent thread.** Every inbound event rides
   libtorrent's alert queue, which the binding *poll-drains* (`btPoll` -> `btx_pop_alerts`).
   No callback ever runs script. The poll interval is a latency/CPU knob within the queue
   caps: libtorrent buffers between polls up to `alert_queue_size` (1000 by default) and
   drops past it, and the rp1 queue sheds its newest events past 65536 events / 32 MiB. Both
   are reported through `btLastError()` (`api-reference.md`, `btPoll` and `btRp1Poll`).
2. **The exception firewall.** libtorrent throws; an exception crossing `extern "C"` would
   take the engine down. Every `btx_*` entry wraps its body in
   `try { ... } catch (...) { set last-error; return <error>; }`.
3. **Payload never crosses the FFI into script.** Gigabytes move engine <-> disk on
   libtorrent's threads. OXT issues tiny commands and polls small status records and
   events. Piece data never enters a LiveCode `Data`.

## The wire format (src/btx_record.h)

Both the alert drain and the status/peer snapshots use one self-describing, typed,
length-prefixed KV record. All framing integers are **big-endian**:

```
kvrecord  := [count:u16] field{count}
field     := [fieldId:u8] [type:u8] [len:u16] [value:len]
type      := 0=int(ASCII) 1=real(ASCII) 2=utf8 3=raw 4=hexhash
```

Higher-level shapes are count-prefixed lists of those records:

```
status snapshot := one kvrecord
alert drain     := [alertCount:u16]  then  [alertType:u16][bodyLen:u16][kvrecord] *
peer list       := [peerCount:u16]   then  [bodyLen:u16][kvrecord] *
```

64-bit values and info-hashes ride as **ASCII** field values; there is no 64-bit foreign
int. The `fieldId`, `type` and `alertType` numbers live in a single registry in
`btx_record.h`; the LCB walker mirrors them as `k*` constants, and
`tools/check-record-registry.py` proves the two never drift.

The framing is pinned three ways that must agree byte-for-byte: `src/btx_record.h` (the
C++ encoder), `tests/record_handle_test.cpp` (a sanitizer round-trip with hard-coded golden
vectors) and `tests/record_golden_test.py` (an independent Python reference with the *same*
golden vectors). Change the format and all three move together.

## Handles (src/btx_handle_table.h)

A handle is a positive 32-bit int packing a generation counter above a slot index. Freeing
a slot bumps its generation, so a stale, removed or never-created handle is a harmless no-op
(getters return 0/empty, actions do nothing): never a crash, never a recycled-slot alias.
One table for sessions, one for torrents. The session handle and torrent handles are
visible to script; everything else is bracketed inside a single LCB call.

## Crossing the FFI: how bytes move (src/torrent.lcb)

Scalars are easy: ints cross as `CInt`, booleans as `0/1`, reals as `double`, and short
strings (magnet URI, save path, hex info-hash, last-error) as `ZStringUTF8`. There is **no
64-bit foreign int**, so 64-bit values, piece offsets and info-hashes ride as decimal/hex
**strings** inside the records.

The one non-obvious primitive is the **byte buffer**, because *an LCB `Data` does not
auto-bridge to a C `Pointer`*: it marshals as an opaque `MCDataRef`, and passing one where a
`Pointer` is declared raises `expected type pointer` at runtime. So the binding uses the
htmltidy/HIDAPI shape built on the engine `<builtin>` allocators (foreign handlers that bind
by their exact engine name, so they carry no leading underscore):

- **out** (the shim fills it: alert drain, status / peer / file / tracker / DHT snapshots,
  the piece bitfield and availability, resume bytes, a created `.torrent`): the binding
  hands the shim a raw block from `MCMemoryAllocate` as a real `Pointer` plus its capacity;
  the shim writes into it and returns **bytes-written**, or **`-needed`** when the block was
  too small. The binding copies exactly the written bytes back into a `Data` with
  `MCDataCreateWithBytes` and walks them.
- **in** (the app supplies it: a `.torrent` file, resume data, a priorities array): the
  binding passes `MCDataGetBytePtr(theData)`, the read-only pointer to the `Data`'s own
  bytes, plus its length. The shim only reads it.

Three buffers (`sDrainPtr`, `sStatusPtr`, `sScratchPtr`, each with a `*Cap`) are allocated
once by `_ensureDrain` / `_ensureStatus` / `_ensureScratch` and **reused** every poll;
rebuilding an N-byte buffer each frame is the O(N) interpreter cost the performance playbook
forbids. A getter that returns `-needed` triggers exactly **one** grow-to-fit retry (the
shim returned the precise size it needs), after which steady-state polling never
reallocates. The drain also **never drops a record**: an overflowing record is stashed and
emitted on the next call (ShowControl's MIDI rule).

If a strict OXT build ever rejected the pointer path, the recorded fallback is to cross the
(small) records as **hex-encoded `ZStringUTF8`** instead of raw bytes, viable because only
status records cross, at the cost of an ABI bump. It has not been needed: the pointer path
ran on a real engine for every buffer handler on 2026-08-10.

## Why it is built this way

- **libtorrent-rasterbar** is the only off-the-shelf engine that is at once feature-complete
  (v1+v2, BEP 5/9/10, PEX, uTP, encryption, multi-tracker, webseeds), permissively licensed
  (BSD-3, compatible with the MIT extensions) and designed to be embedded as a library.
  C++ is no barrier: the FFI binds flat `extern "C"` symbols, so the real cost of the C++
  route is the Boost build, never the binding.
- **Rejected, and recorded so they are not re-litigated:** a pure-C engine (none is both
  maintained and complete; the survivors lack DHT, uTP, v2 and magnets, and Transmission moved
  its core to C++ in 4.0); embedding libtransmission (GPL, and never released as a standalone
  library); driving a daemon over RPC (a client's control surface, not the protocol).
- **The fallback** is rqbit (Rust, usable as a library) behind a small Rust `cdylib`
  exporting the same `btx_*` ABI, leaving the LCB layer untouched. Trade-offs: no Boost and a
  clean cross-compile, against a hand-written Rust-to-C shim and a younger, effectively
  one-maintainer engine whose seeding, encryption and v2 are less proven.
- **The status encoding** is the binary KV record above, chosen over JSON; the names
  (TorrentXT, `org.openxtalk.library.torrent`, `btx_`, `bt`) were fixed before the first
  commit, since renaming the C ABI prefix later breaks compiled binaries.
- **A library, not a widget.** The engine is a non-visual library on the message path. A
  visual dashboard (progress, peer map, piece grid) would be a separate LCB `widget` over
  the status calls; it was decided out of v1 scope on 2026-08-13.
- **Test the binding, not BitTorrent.** Piece hashing, choking and wire correctness are
  libtorrent's job and its test suite's; this member's tests prove the ABI, the marshalling
  and the records.
- **Positioning.** A BitTorrent client carries reputational and app-store baggage that the
  sibling extensions do not. It is not an engineering blocker; the legitimate framing is
  resilient distribution of large payloads, assets and datasets.

## What is verifiable where

OXT cannot compile or run `.lcb` headlessly, so correctness is pushed into layers that *can*
be tested, the rest is gated statically, and the engine pass closes the gap:

| Layer | Gate | Runs where |
|---|---|---|
| record framing + handle safety | `tests/record_handle_test.cpp` (ASan/UBSan) | anywhere (no libtorrent) |
| record byte format | `tests/record_golden_test.py` | anywhere |
| BEP44 buffers, file server, onion framing | `tests/bep44_golden_test.py`, `tests/fileserver_golden.py`, `tests/onion_frame_golden.py` | anywhere |
| the demos' Model C receive paths, run headlessly against those mirrors (and the verifier and M9 feed seal on the committed SodiumXT) | `tools/check-script-vectors.py` + `tools/test-script-vectors.py` | anywhere, with the riptide, nostrxt and sodiumxt siblings beside it |
| LCB <-> header registry | `tools/check-record-registry.py` | anywhere |
| `.lcb` / `.livecodescript` hygiene | `tools/check-livecodescript.py` | anywhere |
| shim over libtorrent | `tests/torrent_smoke_test.cpp` (ASan/UBSan) | CI (needs libtorrent) |
| the bounded rp1 inbound queue | `tests/rp1_queue_test.cpp` (ASan/UBSan; compiles the shim source in) | CI (needs libtorrent) |
| rp1 on the wire, two sessions on loopback | `tests/rp1_integration_test.cpp` | CI (needs libtorrent) |
| the binding on a real engine | `tests/torrent-selftest.livecodescript`, folded into the suite paste | an OXT pass: 101/101 on Windows, last counted 2026-08-24 |
| end-to-end against a real swarm | a legal, checksummed torrent (e.g. a Linux ISO) verified against its published hash | manual; not yet run |

The ledger of dated engine records, and what is still static (the binaries committed
2026-09-12, every non-Windows platform, the demos), is in `../CLAUDE.md`.
