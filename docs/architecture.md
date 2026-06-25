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
  examples/torrent-helpers.livecodescript   the poll dispatcher (timer -> btPoll -> messages)
  examples/torrent-demo.livecodescript      add-a-magnet, show progress, finish
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
