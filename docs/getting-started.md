# Getting started with TorrentXT

This is the task-oriented introduction for an xTalk / OXT app author: install the
extension, stand up a session, add a magnet, watch it download, and shut down
cleanly. It teaches the **one lifecycle you must follow** and the **event model**
that makes the engine safe on a single-threaded runtime. For the call-by-call
contract see `docs/api-reference.md`; for the *why* of the design see
`docs/architecture.md`.

> **Honesty note.** OXT cannot compile or run `.lcb`/`.livecodescript` headlessly,
> so the snippets here are "verified statically; needs an OXT pass." They mirror
> the runnable examples — `examples/torrent-client.livecodescript` (the full
> self-building client) plus the smaller `examples/torrent-demo.livecodescript`
> and `examples/torrent-helpers.livecodescript` this guide walks through; when
> something does not behave, trust the running engine and `btLastError()` over
> this page.

---

## 1. Install the extension

TorrentXT ships as a packaged extension with the native engine bundled inside it,
under `src/code/<arch>-<platform>/torrentxt.{so,dll,dylib}` (the bare token
`torrentxt`, no `lib` prefix). **Installing the packaged extension is all that is
required** - the engine then resolves the `c:torrentxt>` binding automatically via
`the revLibraryMapping`.

- No `sudo`, no copying a loose library to `/usr/lib`, no `LD_LIBRARY_PATH`, no
 rename. The committed per-platform binary is found by the mapping.
- In the OXT IDE: install the `.lce` package the same way you install any
 extension. Your stack then sees the `library org.openxtalk.library.torrent` and
 its public `bt*` handlers on the message path.

Then put the **poll dispatcher** on the message path so you can drive the engine
with plain event handlers instead of a hand-rolled loop:

```
start using stack "torrentHelpers"
```

(`examples/torrent-helpers.livecodescript`, inserted as a stack or behaviour.) It
supplies `btStartPolling` / `btStopPolling` and the formatting sugar
(`btFormatBytes`, `btStateName`).

---

## 2. The lifecycle you MUST follow

libtorrent runs its own network and disk threads. There is **no deterministic
extension-unload hook in OXT**, so the engine cannot tear itself down - *you* must
bracket its life around your stack's life. The shape is always:

```
openStack   ->  btStartSession      (verify ABI, get the session handle)
            ->  (set a few settings)
            ->  btStartPolling       (arm the event drain timer)
   ... app runs: add torrents, handle events, refresh a dashboard ...
closeStack  ->  btStopPolling        (disarm the timer first)
            ->  btStopSession        (pause, flush resume data, destroy, join)
```

**Why the shutdown is mandatory, not optional:** `btStopSession` is the only thing
that pauses the session, gives libtorrent a moment to write resume data, destroys
it, and joins its background threads. Skip it and you leak a session and its
threads at quit - the documented failure mode (plan section 4.2). `btStopSession` is
**idempotent** and a stale handle is a no-op, so calling it defensively is always
safe. Only one session may be live at a time; `btStartSession` refuses a second.

Here is that skeleton, lifted from `examples/torrent-demo.livecodescript`:

```
local sSession

on openStack
   -- btStartSession verifies the native ABI internally (throws on skew) and
   -- refuses a 2nd session. Called as a command -> read the result.
   btStartSession
   put the result into sSession
   if sSession is 0 then
      answer "TorrentXT failed to start:" && btLastError()
      exit openStack
   end if
   -- a couple of sane defaults; keys are libtorrent settings_pack names
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   -- drive events to this card; a 250 ms drain is plenty for a UI
   btStartPolling sSession, the long id of this card, 250
   -- low-rate dashboard refresh (<= 4 Hz), the cheap way to show progress
   send "refreshDashboard" to me in 500 milliseconds
end openStack

on closeStack
   -- MUST shut down explicitly: no deterministic extension-unload hook.
   btStopPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
end closeStack
```

> `btStartSession` is the **one** handler that can throw: on an ABI mismatch
> between the bundled native library and the `.lcb` binding it throws a clear
> message rather than letting a wrong memory layout crash you later. If you see
> it, the committed binary and the binding are out of step - rebuild and
> repackage (see `docs/building.md`).

---

## 3. A minimal walkthrough: add a magnet, watch it finish

This mirrors the rest of the demo. The shape to internalise: **commands report via
`the result`; functions return a value.** Adding a torrent is a command that
reports the new handle.

### Add the magnet

```
command addMagnet
   local tHandle
   if sSession is 0 or sSession is empty then
      answer "No session."
      exit addMagnet
   end if
   btAddMagnet sSession, field "magnet", field "savepath"
   put the result into tHandle
   if tHandle is 0 then
      answer "Add failed:" && btLastError()
   else
      put tHandle into sActiveTorrent
      put "Added; fetching metadata..." into field "status"
   end if
end addMagnet
```

A magnet has **no name or file list yet** - those arrive over the wire. So you
wait for events.

### Handle the events that matter

The dispatcher `send`s a semantic message per engine event. Write handlers for the
ones you care about; their parameter is the event `Array` (keys in
api-reference.md):

```
on metadataReceived pEvent
   put "Metadata:" && pEvent["torrentName"] into field "status"
end metadataReceived

on torrentFinished pEvent
   put "Finished torrent" && pEvent["torrent"] into field "status"
end torrentFinished

on torrentError pEvent
   put "Error:" && pEvent["errorMessage"] into field "status"
end torrentError
```

### Refresh a status field at a low rate - NOT per piece

This is the single most important performance rule for the UI. A torrent emits a
**`pieceFinished` event for every piece** - potentially hundreds per second. **Do
not relayout and redraw a field on each one.** Instead poll the one-call status
snapshot on a slow timer (<= ~4 Hz) and update only then:

```
command refreshDashboard
   local tStatus, tPct, tLine
   if sActiveTorrent is not empty then
      put btTorrentStatus(sActiveTorrent) into tStatus
      put (the round of (tStatus["progress"] * 1000) / 10) into tPct
      put tStatus["name"] && "-" && btStateName(tStatus["state"]) into tLine
      put tLine & " - " & tPct & "% - down" && btFormatBytes(tStatus["downloadRate"]) & "/s" \
         into field "status"
   end if
   if sSession is not empty and sSession is not 0 then
      send "refreshDashboard" to me in 500 milliseconds
   end if
end refreshDashboard
```

`btTorrentStatus` returns a whole `Array` in **one** FFI round-trip;
`btFormatBytes` and `btStateName` (from the helper stack) make it readable.
`progress` is a `0..1` fraction, so `* 1000 / 10` gives a one-decimal percent.

The reasoning, from the single-thread playbook (CLAUDE.md): OXT runs script, the
FFI, and rendering on **one** interpreted thread. The three real costs, in order,
are interpreter ops, FFI round-trips, and property-set redraws. An every-frame
field redraw is the biggest avoidable one. A dashboard refreshing 2-4x/s is
plenty; let the high-frequency `pieceFinished` stream go by (or count it cheaply)
and read the rolled-up status on the slow timer.

---

## 4. The event model

You almost never call `btPoll` yourself. The flow is:

1. libtorrent buffers every event on its own threads (a torrent added, metadata
 arrived, a piece finished, a tracker replied, an error, resume data ready, ...).
 **The engine never calls back into your script** - that would cross threads,
 which is unsafe.
2. `btStartPolling SESSION, TARGET, INTERVALMS` arms a timer. Each tick it calls
 `btPoll(SESSION)` once, which drains **all** pending events in a single FFI
 round-trip and returns them as a `List` of `Array`s.
3. For each event the dispatcher `dispatch`es a message named by the event's
 `name` key to `TARGET`, with the event array as the parameter - and also fires
 a catch-all `torrentEvent` so one handler can observe the whole stream.

The semantic messages and the keys each carries are tabulated in
api-reference.md. The headline ones:

| message | carries (besides `torrent`) | meaning |
|---|---|---|
| `torrentAdded` | `torrentName`, `infoHashV1`/`V2` | a torrent entered the session |
| `metadataReceived` | `torrentName`, `infoHashV1`/`V2` | magnet metadata arrived; name/files known |
| `pieceFinished` | `piece` | a piece passed hash check (HIGH frequency) |
| `torrentFinished` | -- | all selected files complete |
| `torrentError` | `errorCode`, `errorMessage` | a torrent-level error |
| `stateChanged` | `state`, `prevState` | the torrent's state_t changed |
| `trackerReply` | `tracker`, `numPeers` | a tracker announce succeeded |
| `resumeDataReady` | `resumeData` (bytes) | resume data you requested is ready to save |
| `scrapeReply` | `numPeers` (+ swarm counts) | a scrape returned swarm seeder/leecher counts |

**The poll interval is a latency/CPU knob, not a correctness knob.** Throughput
and event integrity are independent of cadence - libtorrent buffers between
drains, and the drain never drops a record - so only worst-case event latency
scales with the interval. 250 ms suits a UI; 1000 ms is fine for a background
sync; tighten only for a very smooth live dashboard. The cost of a tighter loop is
CPU spent on drains, nothing else.

> The gigabytes never touch your script. Payload moves engine <-> disk on
> libtorrent's threads; `btPoll` and `btTorrentStatus` only ever move small event
> and status records. If you ever find yourself putting piece data into a `Data`,
> stop - that is not how this binding works (architecture.md, rule 3).

---

## 5. Persisting and resuming a download

To stop a partial download and resume it next launch without re-hashing
everything:

1. Request resume data: `btSaveResumeData tH`. This is **asynchronous** - nothing
   comes back from the call.
2. Handle the `resumeDataReady` event and persist its bytes:

```
on resumeDataReady pEvent
   put pEvent["resumeData"] into url ("binfile:" & sResumePath)
end resumeDataReady
```

3. Next launch, re-add from those bytes instead of the magnet/file:
   `btAddTorrentWithResume sSession, tResumeBytes, tSave` then
   `put the result into tH`.

The same pattern persists DHT routing state across runs with `btDhtSaveState` /
`btDhtLoadState` (opaque `Data` blobs).

---

## 6. Troubleshooting

- **`btStartSession` returns `0`.** The session did not start. Call `btLastError()`
 immediately for the reason. A common cause is a second session while one is
 still live (`btStopSession` was not called on the previous close).
- **A command "fails silently."** Setters and control commands return `0` on
 success and a negative code on failure (codes in api-reference.md), but the
 human-readable reason is only in `btLastError()`. Read it right after the failed
 call, before another call overwrites it. `btClearError` resets it.
- **`btStartSession` *throws* "native library ABI does not match the LCB
 binding".** The bundled `torrentxt.{so,dll,dylib}` and the `.lcb` were built
 against different ABI versions. Rebuild the native library and refresh the
 committed binary in lockstep (`tools/package-extension.py`; `docs/building.md`).
 `BTX_ABI_VERSION` in `src/btx_abi.h` and `kABIVersion` in the binding must
 match.
- **A getter returns empty / `0` unexpectedly.** Most likely the handle is stale
 (the torrent was removed, or the session was shut down) - a stale handle is a
 deliberate no-op, never a crash. Re-check that you still hold a live handle.
- **It compiled in the static gate but you have not run it in OXT.** Say so. The
 static checker (`tools/check-livecodescript.py`) catches smart quotes, handler
 and `unsafe` balance, and constant ordering, but it cannot prove runtime
 behaviour. The convention across this repo is "verified statically; needs an OXT
 pass" - let the running engine confirm, and report what you actually observed.
