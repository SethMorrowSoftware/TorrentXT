# Getting started with enetxt

From install to two machines chatting over reliable UDP.

## 1. Install the extension

enetxt is a standard OXT extension package: the LCB module (`enet.lcb`,
library `org.openxtalk.library.enet`) with the native library bundled per
platform under `code/<arch>-<platform>/enetxt.{so,dll,dylib}`. Install it
through the OXT Extension Manager; the engine resolves the `c:enetxt>`
binding automatically via `the revLibraryMapping` — no loose files, no
`sudo`, no `LD_LIBRARY_PATH`.

Also put `examples/enet-helpers.livecodescript` where your app can
`start using` it — it is the pump every app needs.

## 2. The three habits every app needs

```livecodescript
on openStack
   get enInitialize()                    -- refcounted; throws a clear error
                                         -- if the native ABI does not match
   start using stack "enetHelpers"
   -- create your host(s), then register EACH ONE with the pump:
   --   enStartPolling tHost, the long id of this card, 33
end openStack

on closeStack
   enStopPolling
   enDeinitialize  -- MANDATORY: the final one also destroys any surviving
                   -- hosts; there is no automatic unload hook
end closeStack
```

**Pump or nothing.** ENet has no threads: connects, sends, retransmissions,
pings, and receives all progress inside `enPoll`. The helpers' timer loop is
the transport's heartbeat; its interval is the latency floor (16–33 ms for
real-time, 100+ ms for chat). Zero-argument calls are written **bare** in
statement position (`enDeinitialize`, not `enDeinitialize()` — OXT cannot
compile the latter as a statement).

## 3. A server and a client, in a dozen lines

```livecodescript
-- MACHINE A - host a server on port 27099, up to 32 peers, 2 channels
put enHostCreateServer("", 27099, 32, 2, 0, 0) into sServer
enStartPolling sServer, the long id of this card, 33

on enetConnect pEvent          -- a peer arrived; its handle is born HERE
   put pEvent["peer"] into sLatest
   enSendText sLatest, 0, "welcome!", 0   -- 0 = reliable
end enetConnect

on enetReceive pEvent
   -- relay every line to everyone: ONE broadcast, N deliveries
   enBroadcast sServer, 0, pEvent["payload"], 0
end enetReceive
```

```livecodescript
-- MACHINE B - join it
put enHostCreateClient(1, 2, 0, 0) into sClient
put enConnect(sClient, "192.168.1.20", 27099, 2, 1) into sPeer
enStartPolling sClient, the long id of this card, 33

on enetConnect pEvent          -- our connect confirmed
   enSendText sPeer, 0, "hello from B", 0
end enetConnect

on enetReceive pEvent
   put textDecode(pEvent["payload"], "utf-8") into field "chat"
end enetReceive
```

The last argument of `enConnect` is a u32 the server receives in ITS
`enetConnect` event — carry a protocol version there and refuse mismatches
loudly (the LAN chat demo shows the shape).

## 4. Delivery modes — the reason ENet exists

Every send takes a flags argument:

- **0 reliable** — retransmitted until acked, ordered within its channel.
  Chat, commands, anything that must arrive. The safe default.
- **1 unreliable** — sequenced but droppable: a LATE packet is discarded
  rather than delivered stale. Perfect for state you overwrite every tick
  (positions, cursors) — losing one frame is better than replaying it.
- **2 unsequenced** — fire-and-forget, may arrive out of order. Heartbeats,
  one-shot pings.

Channels (0..channelCount-1, fixed at host create) are independent ordering
domains: bulk-ish reliable traffic on channel 1 cannot stall real-time
channel 0.

## 5. The LAN chat demo

`examples/enet-lan-chat.livecodescript` is the worked example: Host on one
machine, Join from others, lines relayed with one `enBroadcast`, presence
from the connect/disconnect events, RTT in the status line from
`enPeerStatus`. Open it alongside the helpers and read it as a template.

## 6. Where enetxt sits in the family

- **enetxt**: many peers, LAN/open-internet, game-grade cadence, reliable
  AND droppable delivery. No NAT traversal — someone must be reachable
  (a LAN, a port forward, a rented box).
- **dataChannelXT**: two peers ANYWHERE — ICE/STUN/TURN punches NATs, and
  the far side can be a browser. Heavier handshake, WebRTC stack.
- **TorrentXT**: bulk. The 60 000-byte packet budget here is deliberate —
  when a payload stops being a message, move it to torrents.
