# enetxt architecture

```
ENet v1.3.18 (static, PIC)                   sockets + the reliability protocol
   |- C++ shim   src/enet_shim.cpp  ->  enetxt.{so,dll,dylib}   (ABI: enx_*, v2)
        |- LCB binding  src/enet.lcb      (org.openxtalk.library.enet; public en*)
             |- examples/enet-helpers.livecodescript   (the pump)
```

## The one big difference from the siblings: pump-driven, threadless

libtorrent and libdatachannel run their own threads and push events at us;
ENet runs NOTHING until called. `enx_poll` is therefore not just a drain — it
IS the transport: each call loops `enet_host_service(host, &e, 0)` until
empty, and connects, sends, retransmissions, and pings all progress inside
it. Rule 1 (never call script from a foreign thread) is satisfied by
construction; the price is that the poll loop is mandatory and its interval
is the latency floor.

## The lossless partial drain (this binding's one novel structure)

The drain encodes each serviced event into the caller buffer as
`[type:u16][bodyLen:u16][kvrecord]` after a leading `[count:u16]`. When an
encoded event no longer fits, it goes into the host's ONE-SLOT STASH and the
pump STOPS — everything not yet serviced simply stays queued inside ENet, and
the stash is emitted first on the next poll. If not even one event fits, the
call returns `-needed` and the LCB layer grows and retries. Consequences,
pinned by the smoke test's keyhole scenario: no event is ever dropped, no
event is ever reordered, at ANY buffer size. (The datachannelxt sibling needs
a bounded queue with overflow accounting because its events arrive from
foreign threads whether or not script polls; here WE decide when events
materialize, so losslessness costs one stash slot.)

## Handles

Hosts and peers ride generation-tagged tables (`enx_handle_table.h`, carried
verbatim from the family): a stale handle is ALWAYS a harmless no-op. The
peer handle lives in `ENetPeer.data` as an int backlink:

- **Born**: in `enx_connect` (outgoing, optimistic) or at the drain that
  writes an incoming peer's `E_CONNECT` — the event that announces the peer
  carries the newborn handle.
- **Retired**: when its `E_DISCONNECT` is drained (polite path), or
  immediately on `disconnect_now`/`reset` (ENet defines those as event-less
  locally). `enx_host_destroy` and the final `enx_deinitialize` retire
  everything riding them.

## The record codec

Byte-identical to the family wire format (`[count:u16]` then
`[fieldId:u8][type:u8][len:u16][bytes]`, big-endian; drain entries add
`[type:u16][bodyLen:u16]`). Registries are enetxt's own and APPEND-ONLY —
`src/enx_record.h` is the single source of truth, `record_golden_test.py`
and `record_handle_test.cpp` pin the same literal bytes, and
`check-record-registry.py` proves the LCB constants match.

## Payload rules

A packet IS the message, so payload crosses the FFI by design — bounded by
`ENX_MAX_MESSAGE` (60 000 bytes) both ways: outbound refused with -4 (never
truncated), oversized inbound dropped WHOLE with an `E_ERROR` event.
Packet ownership follows ENet's contract exactly: create copies the bytes
in; after a successful send the host owns the packet; on receive the bytes
are copied into the record and the packet destroyed before the drain
returns — script never sees a pointer into ENet-owned memory.

## The firewall

Every `enx_*` entry point body runs inside `ENX_GUARD_*` (`src/enx_abi.h`):
a C++ exception becomes a recorded error + error return, never an unwind
across `extern "C"`. The macro comment carries the two paid-for sibling
lessons — one declaration per line (the macro-comma trap), and no
preprocessor directive inside a guard body (gcc tolerates, MSVC rejects with
C2121).
