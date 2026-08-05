# DataChannelXT architecture

The binding's whole design answers one question: **how do libdatachannel's
worker threads and OXT's single interpreted thread share a process safely?**
Everything else is the family furniture (handles, records, the firewall)
carried from TorrentXT/Box2Dxt/ShowControl.

```
            libdatachannel threads                      the ONE OXT thread
  ┌──────────────────────────────────────┐      ┌──────────────────────────────┐
  │ ICE (juice)   DTLS    SCTP (usrsctp) │      │  script ... on a timer:      │
  │      \          |         /          │      │     dcPoll()                 │
  │       callbacks (rtc C API)          │      │       |                      │
  │  cb_local_description  cb_message ...│      │   _dcx_poll  ── drains ──┐   │
  │       |                              │      │       |                  │   │
  │  [lock g_mu; push event; unlock]     │      │   record list -> arrays  │   │
  └───────┼──────────────────────────────┘      └───────┼──────────────────┼───┘
          v                                             v                  │
   ┌────────────────────────────────────────────────────────────┐          │
   │      THE BOUNDED, MUTEX-GUARDED EVENT QUEUE (g_queue)      │ <────────┘
   │  owned copies only; FIFO; never reorders; sheds newest     │
   │  + reports E_QUEUE_OVERFLOW only when the app stops polling│
   └────────────────────────────────────────────────────────────┘
```

## Rule 1 at its worst case: the queue

libdatachannel delivers EVERYTHING via callbacks fired from its own threads —
the family's "never call script from a foreign thread" rule meets real
concurrency for the first time. The design that keeps it safe:

- Each callback body does exactly: `try { lock g_mu; translate rtc-id -> our
  handle; push an OWNED COPY of the event; unlock } catch (...) {}`. No engine
  call, no script, and no exception can unwind back into libdatachannel.
- `dcx_poll`, on the script thread, locks, drains what fits the caller's buffer
  as a count-prefixed record list, unlocks. Script never runs off-thread.
- The queue is **bounded** (65 536 events / 32 MiB of payload — far beyond what
  any polling app queues) purely as a safety valve for an app that STOPS
  polling: enqueue then sheds the NEWEST event and counts it, and the count
  surfaces as one `E_QUEUE_OVERFLOW` event once the backlog drains. The
  invariant (pinned by the smoke test) is conservation: delivered + reported ==
  sent. Nothing is ever shed silently, truncated, or reordered.

## The lock discipline (deadlock analysis)

Two facts create the hazard: our callbacks briefly need `g_mu`, and
libdatachannel's delete calls block until in-flight callbacks return —
moreover, its C layer (capi.cpp) holds a global map mutex while dropping an
object's last reference, and a still-connecting PeerConnection's destructor
fires the state callback INLINE under that mutex (whose wrapper then re-takes
it: a self-deadlock we reproduced under gdb before designing around it).

The two rules that make the system deadlock-free:

1. **No `rtc*` call is ever made while holding `g_mu`.** Entry points lock to
   validate + copy (an rtc id, a peer handle), unlock, then call libdatachannel.
   So a callback thread can always finish its enqueue, so deletes can always
   join, so teardown can always complete.
2. **Callbacks are cleared before every delete.** `dcx_peer_free`,
   `dcx_channel_free`, and `dcx_cleanup` null every registered callback first
   (which also joins any invocation in flight — libdatachannel's
   `synchronized_callback` semantics), so the destructor path has nothing to
   fire and capi's self-deadlock is unreachable.

## Handle safety across threads

Peers and channels are generation-tagged positive ints (`dcx_handle_table.h`,
byte-for-byte the family implementation). The specific twist here: events can
outlive the objects they describe (a message callback can fire while the
script thread frees the channel). Therefore:

- events carry **handle ids, never pointers**, copied at enqueue;
- libdatachannel's own C-API ints are never exposed (they are not generation-
  tagged, so a recycled id would alias) — the shim maps them internally;
- every id is **re-validated at drain time**; an event naming a freed handle is
  discarded — the app freed it, declaring it no longer cares.

One ordering guarantee matters to apps: **`E_CHANNEL_INCOMING` always precedes
that channel's `E_CHANNEL_OPEN`**, because the incoming announcement is
enqueued in the same locked section that creates the handle, before the open
callback is even wired. The app therefore always learns a remote channel's
handle before any event names it.

## The record codec

The wire format is byte-identical to TorrentXT's (big-endian, self-describing
`[fieldId:u8][type:u8][len:u16][value]` records; drain entries
`[type:u16][bodyLen:u16][kvrecord]`), with DataChannelXT's own append-only
field/event registries in `dcx_record.h`. Three independent implementations —
the C++ encoder, the Python golden, the LCB walker — are locked together by
shared literal byte vectors (`tests/record_golden_test.py`,
`tests/record_handle_test.cpp`) and the registry cross-check
(`tools/check-record-registry.py`, which also enforces the ABI-version and
size-budget sync).

## The message budget

`DCX_MAX_MESSAGE` (60 000 bytes) bounds every message BOTH ways: sends over it
fail loudly (`DCX_ERR_TOO_LARGE`); the shim advertises the cap as the SCTP
`maxMessageSize` so compliant remotes never exceed it inbound; a misbehaving
remote's oversized message is dropped WHOLE with an `E_CHANNEL_ERROR` (never
truncated — truncation corrupts a stream). The number is chosen so one message
plus its record framing always fits the codec's u16 field-length limit. Bulk
transfer is TorrentXT's job; the channel is for control, chat, and state.

## What Phase 1 deliberately leaves out

- **Media tracks** (`NO_MEDIA`): audio/video payload must never cross the FFI
  into a 16 ms interpreter budget; if media ever lands it will be engine-side
  with a separate plan.
- **WebSockets** (`NO_WEBSOCKET`): signaling transport is the app's domain;
  OXT already has sockets, and TorrentXT's DHT is the serverless answer.
- **A signaling protocol**: deliberately not baked in — the events/setters are
  the primitive, and every app's rendezvous differs.
