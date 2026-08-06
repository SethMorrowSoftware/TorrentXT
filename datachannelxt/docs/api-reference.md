# DataChannelXT API reference

The public LCB surface (`library org.openxtalk.library.datachannel`). Every
handler is a FUNCTION (returns a value) unless noted. Handles are positive
integers; 0 means invalid/failed. Action-style functions return **0 on success
or a negative error**: -1 generic, -2 stale handle, -3 bad argument, -4 message
too large, -5 the native engine refused (see `dcLastError()`), -6 a native
exception was caught by the firewall.

Getters whose 0 is a REAL value (`dcPeerState`, `dcGatheringState`,
`dcChannelStreamId`, `dcChannelMaxMessage`, `dcBufferedAmount`) return **-1**
for "no value / stale handle".

## Lifecycle & diagnostics

| Handler | Returns | Notes |
|---|---|---|
| `dcInit()` | Integer | optional warm-up (logger + DTLS certificate); idempotent; throws on ABI skew |
| `dcCleanup()` | Integer | frees EVERY peer/channel, joins native threads; **mandatory before quit** (e.g. `closeStack`); idempotent |
| `dcLibraryVersion()` | String | e.g. `libdatachannel v0.24.5` |
| `dcLastError()` | String | module-static last error, "" if none |
| `dcClearError()` | — | command-style; clears it |

## Peer connections

| Handler | Returns | Notes |
|---|---|---|
| `dcCreatePeer(pIceServers)` | Integer | one ICE server URI per line, "" for none; auto-negotiation ON |
| `dcClosePeer(pPeer)` | Integer | polite close; handle stays inspectable |
| `dcFreePeer(pPeer)` | — | close + destroy peer AND its channels; idempotent |
| `dcSetLocalDescription(pPeer, pType)` | Integer | manual renegotiation only; pType "offer"/"answer"/"" |
| `dcSetRemoteDescription(pPeer, pSdp, pType)` | Integer | apply the far side's description |
| `dcAddRemoteCandidate(pPeer, pCandidate, pMid)` | Integer | apply one far-side candidate; pMid may be "" |
| `dcLocalDescription(pPeer)` | String | the current local SDP ("" if none). After gathering completes it CONTAINS the candidates — the one-blob (non-trickle) signaling artifact |
| `dcLocalDescriptionType(pPeer)` | String | "offer" / "answer" / "" |
| `dcPeerState(pPeer)` | Integer | kPeerState* (below); -1 stale |
| `dcGatheringState(pPeer)` | Integer | kGathering*; -1 stale |
| `dcSelectedCandidatePair(pPeer)` | Array | keys `localCandidate`, `remoteCandidate`; {} until selected. `typ host/srflx` = direct, `typ relay` = TURN |

ICE server URI forms: `stun:host:port`,
`turn:user:pass@host:port?transport=udp` (credentials are secrets in ordinary
memory — the usual caveat).

## Data channels

| Handler | Returns | Notes |
|---|---|---|
| `dcCreateChannel(pPeer, pLabel)` | Integer | reliable + ordered; first channel triggers the offer; usable after its `dcChannelOpen` |
| `dcCreateChannelEx(pPeer, pLabel, pProtocol, pUnordered, pMaxRetransmits, pMaxLifetimeMs, pNegotiated, pStreamId)` | Integer | reliability + negotiation options, below |
| `dcCloseChannel(pChannel)` | Integer | polite close (both sides see `dcChannelClosed`) |
| `dcFreeChannel(pChannel)` | — | close + destroy; idempotent |
| `dcSendText(pChannel, pText)` | Integer | TEXT message (browser: string) |
| `dcSendData(pChannel, pData)` | Integer | BINARY message (browser: ArrayBuffer); empty Data legal |
| `dcChannelLabel(pChannel)` | String | |
| `dcChannelProtocol(pChannel)` | String | subprotocol, "" if none |
| `dcChannelStreamId(pChannel)` | Integer | SCTP stream id; -1 stale/unassigned |
| `dcChannelIsOpen(pChannel)` | Boolean | |
| `dcChannelPeer(pChannel)` | Integer | owning peer handle (0 stale) — dispatch helper |
| `dcChannelMaxMessage(pChannel)` | Integer | NEGOTIATED per-message cap; sends must satisfy it AND kMaxMessage |
| `dcBufferedAmount(pChannel)` | Integer | bytes queued to send; -1 stale |
| `dcSetBufferedLowThreshold(pChannel, pAmount)` | Integer | arms the `dcBufferedLow` event |

`dcCreateChannelEx` options: `pUnordered` true allows out-of-order delivery;
`pMaxRetransmits >= 0` OR `pMaxLifetimeMs >= 0` (at most one) makes the channel
unreliable (bounded retransmission count / time) — the real-time modes;
`pNegotiated` true means BOTH sides create the channel out-of-band with the
SAME `pStreamId` (0..65534) and no in-band open handshake is sent; `pStreamId`
-1 = automatic.

**The message budget:** `kMaxMessage` (60 000 bytes) bounds every send; over it
returns -4. Inbound is bounded identically (advertised in the SCTP
negotiation); a misbehaving remote's oversized message is dropped whole with a
`dcChannelError` event. Bulk belongs to TorrentXT.

**Backpressure:** send until `dcBufferedAmount(chan)` exceeds your high-water
mark, stop, resume on `dcBufferedLow`. Do not blast a slow channel.

## The event drain

| Handler | Returns | Notes |
|---|---|---|
| `dcPoll()` | List | drains EVERY pending event in one FFI round-trip; call on a timer (16-33 ms real-time, 100+ ms chat) — or use the helpers' `dcStartPolling` |

Each element is an Array with `code` (numeric), `name` (the semantic message
name below), `peer`, `channel` (0 when absent), plus event-specific keys.

### Events (dispatched by `examples/datachannel-helpers.livecodescript`)

| name | extra keys | meaning |
|---|---|---|
| `dcLocalDescription` | `sdp`, `sdpType` | SHIP to the far peer |
| `dcLocalCandidate` | `candidate`, `mid` | SHIP to the far peer |
| `dcStateChange` | `state` (kPeerState*) | connection state walked |
| `dcGatheringStateChange` | `state` (kGathering*) | 2 = complete -> one-blob signaling ready |
| `dcChannelIncoming` | `channel`, `label`, `protocol` | remote-opened channel; ALWAYS precedes its open |
| `dcChannelOpen` | `channel` | now you can send |
| `dcChannelClosed` | `channel` | |
| `dcMessage` | `text` OR `payload` (Data) | one inbound message |
| `dcChannelError` | `error` | includes the oversized-inbound drop notice |
| `dcBufferedLow` | `channel` | send buffer drained under the armed threshold |
| `dcQueueOverflow` | `dropped` | the app stopped polling and the bounded queue shed that many events |

The helpers also fire a catch-all `dataChannelEvent` for every event, and
provide `dcStartPolling target, intervalMs` / `dcStopPolling`, plus the sugar
`dcStateName(n)`, `dcGatheringName(n)`, `dcFormatBytes(n)`.

## Constants (mirrored from the native registries; checker-enforced)

Peer states: `kPeerStateNew` 0, `kPeerStateConnecting` 1, `kPeerStateConnected`
2, `kPeerStateDisconnected` 3, `kPeerStateFailed` 4, `kPeerStateClosed` 5.
Gathering: `kGatheringNew` 0, `kGatheringInProgress` 1, `kGatheringComplete` 2.
Budget: `kMaxMessage` 60000. The record/event registry constants (`kField*`,
`kEvent*`, `kType*`) are internal to the walker but public in the module;
`tools/check-record-registry.py` proves they match `src/dcx_record.h`.

## The rules an app must respect

1. **Call `dcCleanup()` at quit** — no automatic unload hook exists.
2. **Poll** — nothing is delivered without `dcPoll` (the helpers do it for you).
   The interval is a latency knob, never a correctness knob; the native queue
   buffers (bounded) between drains.
3. **Signaling is yours** — carry descriptions/candidates between peers over
   any channel you have; the events/setters above are the whole contract.
4. **A channel is usable only between its `dcChannelOpen` and `dcChannelClosed`.**
5. Handles are cheap ints; stale ones are harmless (getters return ""/0/-1,
   actions return -2) — but events for handles you freed are dropped, so free
   only when you are done listening.
