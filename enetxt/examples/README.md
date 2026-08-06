# enetxt examples

| File | What it is |
|---|---|
| `enet-helpers.livecodescript` | **Load this first.** The poll dispatcher (`enStartPolling` / `enStopPolling`) that turns `enPoll` into plain xTalk messages (`enetConnect`, `enetDisconnect`, `enetReceive`, `enetError`), plus display sugar (`enStateName`, `enFormatBytes`). Register EVERY host you create — polling is per host here, and PUMP OR NOTHING: this loop is the transport's heartbeat, not a convenience. Insert into the message path: `start using stack "enetHelpers"`. |
| `enet-lan-chat.livecodescript` | The milestone-3 demo: a LAN chat. One machine Hosts (server + chatter), others Join its ip; lines relay through the host with ONE `enBroadcast`; presence rides the connect/disconnect events; the status line shows peer count / RTT. The template for the server-relay shape, the connect-data protocol check, and the mandatory `enDeinitialize` at `closeStack`. |

The runtime self-test lives in `../tests/enet-selftest.livecodescript` — paste
it into a stack script to verify an installed extension end to end (sync
surface, a live 127.0.0.1 loopback, byte-exact binary round-trip, teardown).

Every demo follows the family rules: self-building idempotent UI, the poll
interval treated as a latency knob (here it is also the latency FLOOR — ENet
only progresses when pumped), `enDeinitialize` on `closeStack`.
