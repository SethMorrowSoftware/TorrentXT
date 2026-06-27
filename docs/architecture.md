# TorrentXT architecture

This is the as-built map of how the pieces fit. The full rationale (engine
choice, the phased plan, the risk register) lives in
`docs/TorrentXT-IMPLEMENTATION-PLAN.md`; the hard-won-lesson list lives in
`/CLAUDE.md`. This file explains the *shape* of the code so a new contributor
can find their footing.

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
  examples/torrent-helpers.livecodescript      the poll dispatcher (timer -> btPoll -> messages)
  examples/torrent-client.livecodescript       the flagship multi-torrent client (self-building UI)
  examples/torrent-dht-channels.livecodescript  the decentralized DHT + BitTorrent channel demo
        |
  your xTalk app              writes event handlers (metadataReceived, pieceFinished, ...)
```

The native side ships **bundled inside the extension** under
`src/code/<arch>-<platform>/torrentxt.{so,dll,dylib}` (bare token, no `lib`
prefix). Installing the packaged extension lets the engine resolve the
`c:torrentxt>` binding automatically via `the revLibraryMapping`.

## The three rules that make this safe

These are load-bearing. They are restated in `/CLAUDE.md` and enforced in code:

1. **Never call an LCB handler from a libtorrent thread.** Every inbound event
   rides libtorrent's alert queue, which we *poll-drain* (`btPoll` →
   `btx_pop_alerts`). No callback ever runs script. The poll interval is a
   latency/CPU knob, not a correctness knob — libtorrent buffers between polls.
2. **The exception firewall.** libtorrent throws; an exception crossing
   `extern "C"` would take the engine down. Every `btx_*` entry wraps its body
   in `try { … } catch (...) { set last-error; return <error>; }`.
3. **Payload never crosses the FFI into script.** Gigabytes move engine ⇄ disk
   on libtorrent's threads. OXT issues tiny commands and polls small status
   records and events. Piece data never enters a LiveCode `Data`.

## The wire format (src/btx_record.h)

Both the alert drain and the status/peer snapshots use one self-describing,
typed, length-prefixed KV record. All framing integers are **big-endian**:

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

64-bit values and info-hashes ride as **ASCII** field values — there is no
64-bit foreign int. The `fieldId`, `type`, and `alertType` numbers live in a
single registry in `btx_record.h`; the LCB walker mirrors them as `k*`
constants, and `tools/check-record-registry.py` proves the two never drift.

The framing is pinned three ways that must agree byte-for-byte:
`src/btx_record.h` (the C++ encoder), `tests/record_handle_test.cpp` (a
sanitizer round-trip with hard-coded golden vectors), and
`tests/record_golden_test.py` (an independent Python reference with the *same*
golden vectors). Change the format and all three move together.

## Handles (src/btx_handle_table.h)

A handle is a positive 32-bit int packing a generation counter above a slot
index. Freeing a slot bumps its generation, so a stale/removed/never-created
handle is a harmless no-op (getters return 0/empty, actions do nothing) — never
a crash, never a recycled-slot alias. One table for sessions, one for torrents.
The session handle and torrent handles are visible to script; everything else is
bracketed inside a single LCB call.

## Crossing the FFI: how bytes move (src/torrent.lcb)

Scalars are easy: ints cross as `CInt`, booleans as `0/1`, reals as `double`,
and short strings (magnet URI, save path, hex info-hash, last-error) as
`ZStringUTF8`. There is **no 64-bit foreign int**, so 64-bit values, piece
offsets, and info-hashes ride as decimal/hex **strings** inside the records.

The one non-obvious primitive is the **byte buffer**, because *an LCB `Data`
does not auto-bridge to a C `Pointer`* — it marshals as an opaque `MCDataRef`,
and passing one where a `Pointer` is declared raises `expected type pointer` at
runtime. So the binding uses the proven htmltidy/HIDAPI shape built on the
engine `<builtin>` allocators (foreign handlers that bind by their exact engine
name, so they carry no leading underscore):

- **out** (the shim fills it — alert drain, status / peer / file / tracker / DHT
  snapshots, the piece bitfield and per-piece availability, resume bytes, a
  created `.torrent`): the binding hands the shim a
  raw block from `MCMemoryAllocate` as a real `Pointer` plus its capacity; the
  shim writes into it and returns **bytes-written**, or **`-needed`** when the
  block was too small. The binding then copies exactly the written bytes back
  into a `Data` with `MCDataCreateWithBytes` and walks them.
- **in** (the app supplies it — a `.torrent` file, resume data, a priorities
  array): the binding passes `MCDataGetBytePtr(theData)` — the read-only pointer
  to the `Data`'s own bytes — plus its length. The shim only reads it.

Three buffers (`sDrainPtr`, `sStatusPtr`, `sScratchPtr`, each with a `*Cap`)
are allocated once by `_ensureDrain` / `_ensureStatus` / `_ensureScratch` and
**reused** every poll — rebuilding an N-byte buffer each frame is the O(N)
interpreter cost the performance playbook forbids. A getter that returns
`-needed` triggers exactly **one** grow-to-fit retry (the shim returned the
precise size it needs), after which steady-state polling never reallocates. The
drain additionally **never drops a record**: an overflowing record is stashed
and emitted on the next call (ShowControl's MIDI rule).

If a strict OXT build ever rejected the pointer path, the recorded fallback is
to cross the (small) records as **hex-encoded `ZStringUTF8`** instead of raw
bytes — viable precisely because only status records cross, never payload — at
the cost of an ABI bump. It has not been needed.

## What is verifiable where

OXT cannot compile or run `.lcb` headlessly, so correctness is pushed into
layers that *can* be tested and the rest is gated statically:

| Layer | Gate | Runs where |
|---|---|---|
| record framing + handle safety | `tests/record_handle_test.cpp` (ASan/UBSan) | anywhere (no libtorrent) |
| record byte-format | `tests/record_golden_test.py` | anywhere |
| LCB ↔ header registry | `tools/check-record-registry.py` | anywhere |
| `.lcb` / `.livecodescript` hygiene | `tools/check-livecodescript.py` | anywhere |
| shim over libtorrent | `tests/torrent_smoke_test.cpp` (ASan/UBSan) | CI (needs libtorrent) |
| end-to-end binding | manual swarm interop (legal ISO + hash) | a human, scheduled |

Anything that needs a running OXT (the `Data`⇄`Pointer` bridge, the public
handlers' runtime behaviour) is marked "verified statically; needs an OXT pass"
and confirmed by a human — never claimed from the armchair.
