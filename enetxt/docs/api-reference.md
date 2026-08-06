# enetxt API reference

The public LCB surface (`library org.openxtalk.library.enet`). Every handler
is a FUNCTION (returns a value) unless noted. Handles are positive integers;
0 means invalid/failed. Action-style functions return **0 on success or a
negative error**: -1 generic, -2 stale handle, -3 bad argument (channel out
of range, bogus flags), -4 message over the budget, -5 the native engine
refused (see `enLastError()`), -6 a native exception was caught by the
firewall.

**THE MODEL — pump or nothing.** ENet has no threads. Connects, sends,
retransmissions, pings, and receives ALL progress inside `enPoll`; run it on
a timer (the helpers' `enStartPolling` does it) and treat the interval as the
latency floor: 16–33 ms for real-time feel, 100+ ms for chat-grade traffic.

## Lifecycle & diagnostics

| Handler | Returns | Notes |
|---|---|---|
| `enInitialize()` | Integer | refcounted global init; verifies the ABI (throws a clear error on skew) |
| `enDeinitialize()` | Integer | balances init; the FINAL one destroys every surviving host — **mandatory before quit** (e.g. `closeStack`); idempotent |
| `enLibraryVersion()` | String | e.g. `enet 1.3.18` (the LINKED library) |
| `enLastError()` | String | module-static last error, "" if none |
| `enClearError()` | — | command-style; clears it |

## Hosts

| Handler | Returns | Notes |
|---|---|---|
| `enHostCreateServer(pBindHost, pPort, pMaxPeers, pChannels, pInBW, pOutBW)` | Integer | bind + listen; pBindHost "" (or "*") = every interface; peers 1..4095, channels 1..255 (fixed for the host's life), bandwidth bytes/sec (0 = unlimited) |
| `enHostCreateClient(pMaxPeers, pChannels, pInBW, pOutBW)` | Integer | unbound host; initiates only |
| `enHostDestroy(pHost)` | Integer | destroys the socket and retires every peer riding it; idempotent |
| `enHostStatus(pHost)` | Array | keys `host`, `address` (the real bound socket — a port-0 server shows its actual ephemeral port; an unbound CLIENT host shows `0.0.0.0:0`), `peerCount`; {} when stale |
| `enSetHostBandwidth(pHost, pInBW, pOutBW)` | Integer | live re-throttle |
| `enFlush(pHost)` | Integer | push queued sends NOW without servicing inbound |

Many hosts per process are fine (a server host + a client host at once is the
demo's normal shape) — the torrentxt single-session rule does NOT apply here.

## Peers

| Handler | Returns | Notes |
|---|---|---|
| `enConnect(pHost, pRemoteHost, pPort, pChannels, pData)` | Integer | peer handle NOW (optimistic); `enetConnect` confirms, `enetDisconnect` reports failure/timeout. pData is a u32 the far side sees in ITS `enetConnect` (protocol version, room id...; from script pass 0..2147483647 — it crosses the FFI as a signed 32-bit int). A hostname resolves DNS synchronously — pass an IP when that matters |
| `enDisconnect(pPeer, pData)` | Integer | polite: drains sends, notifies, YOUR `enetDisconnect` arrives via the pump — which is when the handle retires |
| `enDisconnectNow(pPeer, pData)` | Integer | abrupt: one last notify out, NO local event, immediate retire |
| `enResetPeer(pPeer)` | Integer | silent teardown both ways; immediate retire |
| `enPeerStatus(pPeer)` | Array | keys `host`, `peer`, `address`, `state` (kPeerState*), `rtt` ms, `packetLoss` 0..1, `packetsSent`, `packetsLost`, `bytesSent`, `bytesReceived`; {} when stale/retired |
| `enSetPeerTimeout(pPeer, pLimit, pMinMs, pMaxMs)` | Integer | retransmission-timeout scaling (0 = ENet default) |
| `enSetPeerPingInterval(pPeer, pMs)` | Integer | idle-ping cadence (keeps RTT fresh + NATs open) |

## Sending

| Handler | Returns | Notes |
|---|---|---|
| `enSend(pPeer, pChannel, pData, pFlags)` | Integer | queue one packet (a Data, 0..60000 bytes) to one peer |
| `enSendText(pPeer, pChannel, pText, pFlags)` | Integer | UTF-8 encodes, then `enSend`; arrives as bytes — `textDecode(pEvent["payload"], "utf-8")` on the far side |
| `enBroadcast(pHost, pChannel, pData, pFlags)` | Integer | ONE call queues to EVERY connected peer of the host — the server-fanout primitive |
| `enBroadcastText(pHost, pChannel, pText, pFlags)` | Integer | text sugar for the above |

`pFlags` (mirrored as kSend* in the module; use the literals from script):
**0 reliable** (retransmitted until acked — the safe default), **1 unreliable**
(sequenced but droppable — stale-able state updates), **2 unsequenced**
(fire-and-forget, may reorder).

**The message budget:** 60 000 bytes bounds every send (-4 over it, never a
silent truncation); an oversized INBOUND packet is dropped whole with an
`enetError` event. Packets are messages — game state, chat, control. Bulk
belongs to TorrentXT.

## The pump

| Handler | Returns | Notes |
|---|---|---|
| `enPoll(pHost)` | List | services the host and returns EVERY pending event in one FFI round-trip; lossless and ordered at ANY buffer size (the shim stashes an unwritten event; the rest wait inside ENet) |

Each element is an Array with `code` (numeric), `name` (below), and the
event's fields.

### Events (dispatched by `examples/enet-helpers.livecodescript`)

| name | extra keys | meaning |
|---|---|---|
| `enetConnect` | `host`, `peer`, `address`, `data` | handshake complete; an INCOMING peer's handle is born here — script learns it from this event |
| `enetDisconnect` | `host`, `peer`, `data` | the handle retires after this event; later uses are no-ops |
| `enetReceive` | `host`, `peer`, `channel`, `payload` (Data) | one packet, copied out before ENet's copy is destroyed |
| `enetError` | `host`, `error` (+`peer` when known) | e.g. the oversized-inbound drop notice |

The helpers also fire a catch-all `enetEvent`, and provide
`enStartPolling host, target, intervalMs` / `enStopPolling [host]` (per-host
registration; one loop pumps them all), plus `enStateName(n)` and
`enFormatBytes(n)`.

## Constants (mirrored from the native registries; checker-enforced)

Peer states (from `enPeerStatus`'s `state`; ENet's own ladder): 0
disconnected, 1–4 the connect handshake, **5 connected**, 6–8 the disconnect
ladder, 9 zombie. Send flags: 0 reliable, 1 unreliable, 2 unsequenced.
Budget: 60000. The record/event registry constants (`kField*`, `kEvent*`,
`kType*`, `kPeerState*`, `kSend*`) are public in the module;
`tools/check-record-registry.py` proves they match `src/enx_record.h`.

## The rules an app must respect

1. **Call `enDeinitialize` at quit** — no automatic unload hook exists. (Bare
   command form in statement position; OXT cannot compile `enDeinitialize()`
   as a statement.)
2. **Pump** — nothing progresses without `enPoll` (the helpers do it for
   you). Its interval is the latency floor AND the correctness heartbeat for
   timeouts/retransmissions — keep it running while a host lives.
3. **A peer handle is live from its birth (enConnect / the enetConnect
   event) until its enetDisconnect drains** (or a `now`/`reset` call). Stale
   handles are harmless: getters return {}, actions return -2.
4. **Channel counts are fixed at host create** — both sides should agree.
