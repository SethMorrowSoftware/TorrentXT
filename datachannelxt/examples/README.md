# DataChannelXT examples

| File | What it is |
|---|---|
| `datachannel-helpers.livecodescript` | **Load this first.** The poll dispatcher (`dcStartPolling` / `dcStopPolling`) that turns the native event queue into plain xTalk messages (`dcMessage`, `dcChannelOpen`, ...), plus display sugar (`dcStateName`, `dcFormatBytes`). Insert into the message path: `start using stack "dataChannelHelpers"`. |
| `datachannel-loopback.livecodescript` | The zero-infrastructure first-run demo: TWO real WebRTC peers in ONE stack, signaling shuttled in four lines of script, a chat pane per peer. Proves offer/answer, ICE, DTLS, SCTP, and both message kinds with no second machine. Its `dcLocalDescription` / `dcLocalCandidate` handlers are the template to replace with real signaling. |

The runtime self-test lives in `../tests/datachannel-selftest.livecodescript` —
paste it into a stack script to verify an installed extension end to end
(synchronous surface, a live loopback, message round-trips, teardown).

Every demo follows the family rules: self-building idempotent UI, a poll
interval treated as a latency knob, `dcCleanup()` on `closeStack`.
