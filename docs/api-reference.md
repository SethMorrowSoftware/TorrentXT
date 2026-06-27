# TorrentXT API reference

The complete public surface of `library org.openxtalk.library.torrent`. Every
entry here is one `public handler bt*` in `src/torrent.lcb` (the source of
truth); the reference tables at the end are transcribed from that file's
`_fieldKey` / `_alertName` maps and from `src/btx_record.h`. Read
`docs/architecture.md` for the *shape* of the stack and `docs/getting-started.md`
for the lifecycle you must follow; this file is the call-by-call contract.

> **Honesty note (carried throughout the repo).** OXT has no headless way to
> compile or run `.lcb`, so the runtime behaviour of these handlers is "verified
> statically; needs an OXT pass." Where a value is plumbed through the schema but
> not yet populated by the shim (a few status fields, noted inline), that is
> flagged in place rather than promised.

---

## How to read each entry

- **command vs function.** In xTalk a handler that `returns` a value can be
 called either way. Where the handler hands back a *handle* or a *status code*
 the worked examples invoke it as a **command** and read `the result`
 (`btAddMagnet sSession, tUri, tPath` then `put the result into tH`) - that is
 the shape the plan and the demos teach. Where it hands back data you consume
 immediately (a status `Array`, a peer `List`, a `Data` blob, a diagnostic
 `String`) it reads naturally as a **function** (`put btTorrentStatus(tH) into
 tRec`). Both shapes are noted per entry; pick the one that reads cleanly.
- **handles.** A session handle and torrent handles are plain positive
 `Integer`s. `0` is always "invalid". A stale, removed, or never-created handle
 is a **harmless no-op** - getters return empty/`0`, actions do nothing - never
 a crash (the generation-tagged handle table; architecture.md).
- **64-bit values and info-hashes are `String`s.** There is no 64-bit foreign
 int and an xTalk number is a `double`, so byte totals, ETAs in seconds, and
 hashes cross and are returned as **text** (lossless for display and exact
 arithmetic via `the number`). This is why `btSetInt` takes its value as a
 `String`.
- **error reporting.** Action/setter handlers return `0` (`BTX_OK`) on success
 and a negative code on failure (see the return-code table); the human-readable
 reason is in `btLastError()`. Getters return empty/`0` on a bad handle. No
 handler ever throws into script except `btStartSession`, which throws once on
 an ABI mismatch (below).

---

## Lifecycle & diagnostics

### `btStartSession() returns Integer`
Create THE one session. **Verifies the ABI first** (`_checkABI()`): if the loaded
native library's `btx_abi_version()` does not equal the binding's `kABIVersion`,
this **throws** a legible error (`"TorrentXT native library ABI does not match
the LCB binding; rebuild and repackage the native library."`) rather than letting
a mismatched layout crash later. On success returns a **positive session handle**;
returns `0` on failure (inspect `btLastError()`). Only one live session is allowed
at a time (the shim refuses a second with `BTX_ERR_SESSION_LIVE`).
- **Usage:** command - `btStartSession` then `put the result into sSession`
 (the demo's form), or function - `put btStartSession() into sSession`.
- **You MUST pair this with `btStopSession`** before the app quits; there is no
 deterministic extension-unload hook. See getting-started.

### `btStopSession(in pSession as Integer)`
Pause, request and flush resume data, stop, destroy, and join the session's
background threads, in order. **Idempotent** - a second call, or a call with a
stale handle, is a no-op. Returns nothing.
- **Usage:** command - `btStopSession sSession` (typically in `closeStack`).
- This is the mandatory teardown (plan section 4.2). A session leaked at quit is the
 documented failure mode if the app forgets to call it.

### `btLastError() returns String`
The module-static last-error string, or `""` when there is no pending error.
Set by the most recent failed `btx_*` call. Reuses the scratch buffer and grows
it once if the message is long.
- **Usage:** function - `answer btLastError()`.

### `btClearError()`
Clear the module-static last-error string.
- **Usage:** command - `btClearError`.

---

## Session settings

Keys are **libtorrent `settings_pack` names** (see the settings table below).
Setters return `0` on success, negative on failure; an unknown key fails with
`BTX_ERR_INVALID_ARG` and sets `btLastError()`. Settings apply live.

### `btSetInt(in pSession as Integer, in pKey as String, in pValue as String) returns Integer`
Set an integer setting. **`pValue` is a `String`** so 64-bit values (e.g. a large
rate cap) cross losslessly; pass the decimal text, e.g. `"5000000"`.
- **Usage:** command - `btSetInt sSession, "download_rate_limit", "5000000"`
 then `put the result into tRC`; or function.

### `btSetBool(in pSession as Integer, in pKey as String, in pValue as Boolean) returns Integer`
Set a boolean setting (e.g. `"enable_dht"`). The `Boolean` is marshalled to the
C `int` 0/1 for you.
- **Usage:** command - `btSetBool sSession, "enable_dht", true`.

### `btSetString(in pSession as Integer, in pKey as String, in pValue as String) returns Integer`
Set a string setting (e.g. `"user_agent"`, `"listen_interfaces"`).
- **Usage:** command - `btSetString sSession, "user_agent", "MyApp/1.0"`.

### `btGetSetting(in pSession as Integer, in pKey as String) returns String`
Read any int/bool/string setting back **as text** (diagnostics only; not for the
hot path). Returns `""` on a bad handle or unknown key.
- **Usage:** function - `put btGetSetting(sSession, "connections_limit") into
 tN`.

### `btSetEncryption(in pSession as Integer, in pIn as Integer, in pOut as Integer, in pLevel as Integer) returns Integer`
MSE / protocol-encryption (PE) policy, mapped straight to libtorrent's
`in_enc_policy` / `out_enc_policy` / `allowed_enc_level`. Integer meanings:

| arg | meaning | values |
|---|---|---|
| `pIn` | policy for **incoming** connections | `0` = forced, `1` = enabled, `2` = disabled |
| `pOut` | policy for **outgoing** connections | `0` = forced, `1` = enabled, `2` = disabled |
| `pLevel` | allowed cipher level | `1` = plaintext, `2` = rc4, `3` = both |

- **Usage:** command - `btSetEncryption sSession, 1, 1, 3` (encryption
 enabled both ways, either cipher).

---

## Add / remove torrents

### `btAddMagnet(in pSession as Integer, in pURI as String, in pSavePath as String) returns Integer`
Add a torrent from a magnet URI; the content downloads under `pSavePath`. Returns
a **positive torrent handle**, or `0` on failure (`btLastError()`). Metadata is
fetched over the wire and arrives later as a **`metadataReceived`** event - the
torrent has no name/file list until then.
- **Usage:** command - `btAddMagnet sSession, field "magnet", field "savepath"`
 then `put the result into tH`.

### `btAddTorrentFile(in pSession as Integer, in pData as Data, in pSavePath as String) returns Integer`
Add from the **bytes of a `.torrent` file** (read the file into a `Data` and pass
it). Only the metainfo crosses the FFI; payload never does. Returns a torrent
handle, or `0` on failure.
- **Usage:** command - `put url ("binfile:" & tPath) into tBytes` /
 `btAddTorrentFile sSession, tBytes, tSave` then `put the result into tH`.

### `btAddTorrentWithResume(in pSession as Integer, in pResume as Data, in pSavePath as String) returns Integer`
Re-add a torrent from previously saved **resume data** (the bytes you persisted
from a `resumeDataReady` event). Skips re-hashing already-downloaded pieces.
Returns a torrent handle, or `0` on failure.
- **Usage:** command - `btAddTorrentWithResume sSession, tResumeBytes, tSave`.

### `btRemoveTorrent(in pSession as Integer, in pTorrent as Integer, in pDeleteFiles as Boolean) returns Integer`
Remove a torrent from the session. If `pDeleteFiles` is `true`, the downloaded
files are deleted too. Returns `0` / negative.
- **Usage:** command - `btRemoveTorrent sSession, tH, false`.

---

## Control

All take a torrent handle, return `0` / negative, and are safe no-ops on a stale
handle.

### `btPause(in pTorrent as Integer) returns Integer`
Pause the torrent. A `torrentPaused` event follows.
- **Usage:** command - `btPause tH`.

### `btResume(in pTorrent as Integer) returns Integer`
Resume a paused torrent. A `torrentResumed` event follows.
- **Usage:** command - `btResume tH`.

### `btForceRecheck(in pTorrent as Integer) returns Integer`
Re-hash the on-disk data against the pieces (the torrent re-enters the checking
state).
- **Usage:** command - `btForceRecheck tH`.

### `btForceReannounce(in pTorrent as Integer) returns Integer`
Force an immediate tracker re-announce (and DHT re-announce). Use sparingly; a
`trackerReply` event follows on success.
- **Usage:** command - `btForceReannounce tH`.

### `btSetFilePriority(in pTorrent as Integer, in pFileIndex as Integer, in pPriority as Integer) returns Integer`
Set the download priority of one file (by 0-based index into the torrent's file
list). `pPriority`: `0` = don't download, `1` = normal, up to `7` = top
(libtorrent `download_priority_t`).
- **Usage:** command - `btSetFilePriority tH, 0, 7`.

### `btSetFilePriorities(in pTorrent as Integer, in pPriorities as Data) returns Integer`
Bulk variant: **one priority byte per file, in file order**, packed into a `Data`.
Build it with `the byte with code` per file.
- **Usage:** command - `btSetFilePriorities tH, tPrioBytes`.

### `btSetPiecePriority(in pTorrent as Integer, in pPieceIndex as Integer, in pPriority as Integer) returns Integer`
Set the priority of one piece (0-based piece index). Same `0..7` range.
- **Usage:** command - `btSetPiecePriority tH, 0, 7`.

### `btSetTorrentLimits(in pTorrent as Integer, in pDownBytesPerSec as String, in pUpBytesPerSec as String) returns Integer`
Per-torrent download / upload caps in **bytes/sec, as `String`s** (`"0"` ==
unlimited). Distinct from the session-wide `download_rate_limit` /
`upload_rate_limit` settings.
- **Usage:** command - `btSetTorrentLimits tH, "1000000", "0"`.

### `btSetMaxConnections(in pTorrent as Integer, in pMax as Integer) returns Integer`
Cap the number of peer connections for this torrent (libtorrent wants `>= 2`, or
`-1` for unlimited).
- **Usage:** command - `btSetMaxConnections tH, 80`.

### `btSetMaxUploads(in pTorrent as Integer, in pMax as Integer) returns Integer`
Cap the number of simultaneously **unchoked** upload slots for this torrent.
- **Usage:** command - `btSetMaxUploads tH, 6`.

### `btClearTorrentError(in pTorrent as Integer) returns Integer`
Clear a torrent's error state (e.g. after fixing a disk-full or permission problem
that paused it) so it can resume. Distinct from `btClearError`, which clears the
library's last-error string.
- **Usage:** command - `btClearTorrentError tH`.

### `btScrapeTracker(in pTorrent as Integer) returns Integer`
Ask the tracker(s) for current seed / leecher counts. **Asynchronous**: the
numbers arrive later as a `scrapeReply` event.
- **Usage:** command - `btScrapeTracker tH`, then handle `scrapeReply`.

### `btMoveStorage(in pTorrent as Integer, in pSavePath as String) returns Integer`
Move the torrent's downloaded files to a new directory. **Asynchronous**: success
arrives as a `storageMoved` event (or `fileError` on failure). The bytes move
engine-side; nothing crosses into script.
- **Usage:** command - `btMoveStorage tH, "/mnt/big/downloads"`.

#### Torrent flags

The full `torrent_flags_t` set is exposed as two primitives plus named
conveniences. Flag **values** are the `kFlag*` constants (decimal strings you add
together): `kFlagSeedMode` (1), `kFlagUploadMode` (2), `kFlagShareMode` (4),
`kFlagApplyIpFilter` (8), `kFlagPaused` (16), `kFlagAutoManaged` (32),
`kFlagSuperSeeding` (256), `kFlagSequentialDownload` (512), `kFlagStopWhenReady`
(1024).

### `btSetTorrentFlags(in pTorrent as Integer, in pFlags as String, in pMask as String) returns Integer`
Set the bits named in `pFlags`, touching only the bits named in `pMask` (a
read-modify-write: `set(flags, mask)`). Both are decimal strings - add `kFlag*`
constants to combine them.
- **Usage:** command - `btSetTorrentFlags tH, kFlagSequentialDownload, kFlagSequentialDownload`.

### `btUnsetTorrentFlags(in pTorrent as Integer, in pFlags as String) returns Integer`
Clear the bits named in `pFlags`.
- **Usage:** command - `btUnsetTorrentFlags tH, kFlagSequentialDownload`.

### `btSetSequentialDownload(in pTorrent as Integer, in pOn as Boolean) returns Integer`
Convenience: turn in-order (streaming) download on or off.
- **Usage:** command - `btSetSequentialDownload tH, true`.

### `btSetAutoManaged(in pTorrent as Integer, in pOn as Boolean) returns Integer`
Convenience: let libtorrent automatically queue / start / stop this torrent.
- **Usage:** command - `btSetAutoManaged tH, true`.

### `btSetSuperSeeding(in pTorrent as Integer, in pOn as Boolean) returns Integer`
Convenience: super-seed (initial-seeding) mode - only meaningful on a complete seed.
- **Usage:** command - `btSetSuperSeeding tH, true`.

### `btSetShareMode(in pTorrent as Integer, in pOn as Boolean) returns Integer`
Convenience: optimise this torrent for share-ratio rather than for completion.
- **Usage:** command - `btSetShareMode tH, true`.

### `btSetUploadMode(in pTorrent as Integer, in pOn as Boolean) returns Integer`
Convenience: upload-only - serve pieces but never request any.
- **Usage:** command - `btSetUploadMode tH, true`.

#### Download queue

### `btQueuePosition(in pTorrent as Integer) returns Integer`
The torrent's 0-based position in the download queue, or `-1` if it is not queued
(or the handle is invalid). This getter returns `-1`, not `0`, for "no value",
because `0` is itself a real position - the one getter in the API that does so.
- **Usage:** function - `put btQueuePosition(tH) into tPos`.

### `btQueueUp(in pTorrent as Integer) returns Integer` · `btQueueDown(...)` · `btQueueTop(...)` · `btQueueBottom(...)`
Move the torrent one step up / down, or all the way to the top / bottom of the
download queue. (Only meaningful for auto-managed torrents.)
- **Usage:** command - `btQueueTop tH`.

### `btSaveResumeData(in pTorrent as Integer) returns Integer`
**Request** resume data for the torrent. This is **asynchronous** (libtorrent's
model): the bytes do not return here - they arrive later as a `resumeDataReady`
event whose `resumeData` key holds the bencoded blob to persist. There is
deliberately no synchronous getter.
- **Usage:** command - `btSaveResumeData tH`, then handle `resumeDataReady`.

---

## Status & inspection

One snapshot per call (the single-thread playbook: never one FFI call per field).

### `btTorrentStatus(in pTorrent as Integer) returns Array`
A status snapshot as an `Array` keyed by the **status keys** (table below):
`name`, `state`, `progress`, `downloadRate`, `totalDone`, `numPeers`, `savePath`,
`infoHashV1`, and the rest. Returns the **empty array** on a bad handle. All
values are strings (64-bit totals included); `progress` is `0..1`; map `state`
through `btStateName`.
- **Usage:** function - `put btTorrentStatus(tH) into tRec` then
 `put tRec["progress"] ...`.

### `btTorrentCount(in pSession as Integer) returns Integer`
How many torrents the session currently holds.
- **Usage:** function - `put btTorrentCount(sSession) into tN`.

### `btTorrentHandleAt(in pSession as Integer, in pIndex as Integer) returns Integer`
The torrent handle at a 0-based index, for enumerating the session's torrents
(`repeat with i from 0 to btTorrentCount(s) - 1`). Returns `0` for an
out-of-range index.
- **Usage:** function - `put btTorrentHandleAt(sSession, i) into tH`.

### `btInfoHash(in pTorrent as Integer) returns String`
The v1 info-hash (or, absent v1, the v2 info-hash) as a lower-case hex `String`.
`""` on a bad handle.
- **Usage:** function - `put btInfoHash(tH) into tHashHex`.

### `btPieceBitfield(in pTorrent as Integer) returns Data`
The packed have-bitfield as raw `Data`: **1 bit per piece, MSB-first within each
byte** (bit `7` of byte `0` is piece `0`). A read-only view for a piece grid.
Empty `Data` on a bad handle. (This is a status view, not payload - it is bits,
not piece content.)
- **Usage:** function - `put btPieceBitfield(tH) into tBits`.

### `btPeerList(in pTorrent as Integer) returns List`
The connected peers as a `List` of `Array`s, each keyed by the **peer keys**
(table below): `endpoint`, `client`, `downRate`, `upRate`, `progress`, `flags`.
Empty `List` on a bad handle.
- **Usage:** function - `repeat for each element tPeer in btPeerList(tH)`.

### `btFileList(in pTorrent as Integer) returns List`
The torrent's files as a `List` of `Array`s, one per file, each with keys `path`
(relative path within the torrent), `size` (bytes), `progress` (bytes of that
file downloaded), and `priority` (`0..7`). The whole file table in **one FFI
round-trip**. Empty `List` until metadata arrives (a magnet has no file table
yet) or on a bad handle - so it doubles as a "do we have metadata" probe.
- **Usage:** function - `repeat for each element tFile in btFileList(tH)` then read `tFile["path"]`, `tFile["size"]`, `tFile["progress"]`, `tFile["priority"]`.

### `btPieceAvailability(in pTorrent as Integer) returns Data`
Per-piece availability as raw `Data`: **one byte per piece**, the number of
connected peers advertising that piece (clamped to `255`). A read-only view for
an availability/rarity grid - pair it with `btPieceBitfield` (which pieces you
have) for a full piece map. Empty `Data` until the torrent has metadata and
peers, or on a bad handle.
- **Usage:** function - `put btPieceAvailability(tH) into tAvail`, then `byte i of tAvail`.

### `btTrackers(in pTorrent as Integer) returns List`
The torrent's trackers as a `List` of `Array`s, each with keys `url`, `tier`
(0 == first tier tried), `verified` (`1` once the tracker has answered this
session), and `source` (the `announce_entry` source bitmask). Empty `List` on a
bad handle.
- **Usage:** function - `repeat for each element tTr in btTrackers(tH)` then read `tTr["url"]`.

### `btAddTracker(in pTorrent as Integer, in pUrl as String, in pTier as Integer) returns Integer`
Add an announce URL at `pTier` (0 == first tier). A URL already in the list is
ignored by libtorrent.
- **Usage:** command - `btAddTracker tH, "udp://tracker.example:6969/announce", 0`.

### `btWebSeeds(in pTorrent as Integer) returns List`
The torrent's HTTP (URL / web) seeds as a `List` of URL `String`s. Empty `List`
on a bad handle.
- **Usage:** function - `put btWebSeeds(tH) into tSeeds`.

### `btAddWebSeed(in pTorrent as Integer, in pUrl as String) returns Integer` · `btRemoveWebSeed(in pTorrent as Integer, in pUrl as String) returns Integer`
Add or remove an HTTP (URL / web) seed (BEP 19) — a plain web server that can
serve the torrent's data alongside peers.
- **Usage:** command - `btAddWebSeed tH, "https://mirror.example/path/"`.

---

## Events / poll

### `btPoll(in pSession as Integer) returns List`
Drain **all** pending engine events with **one** FFI round-trip and return them as
a `List` of `Array`s. Each array carries:
- `code` - the numeric stable alert code (see the alert-code table),
- `name` - the **semantic message name** the dispatcher sends (e.g.
 `metadataReceived`),
- `torrent` - our torrent handle the event concerns (`0`/absent if none),
- plus the **event-specific keys** for that alert (table below).

The drain never drops a record: an oversized one is stashed by the shim and
emitted next call. Returns the **empty list** when nothing is pending.
- **Usage:** function - `put btPoll(sSession) into tEvents`, then loop. In
 practice you do **not** call this yourself: `start using stack
 "torrentHelpers"` and call `btStartPolling`, which runs `btPoll` on a timer
 and `dispatch`es one message per event. See getting-started and the
 "Script-side helpers" section.

---

## DHT

### `btDhtAddBootstrap(in pSession as Integer, in pHost as String, in pPort as Integer) returns Integer`
Add a DHT bootstrap node (host + UDP port) to seed the routing table.
- **Usage:** command - `btDhtAddBootstrap sSession, "router.bittorrent.com",
 6881`.

### `btDhtState(in pSession as Integer) returns Array`
A snapshot of DHT health as an `Array` keyed `nodes`, `nodeCache`, `globalNodes`,
`torrents`. Empty array only on a bad/dead session handle (when DHT is simply
idle the counts read `0`).
- **Note:** `nodes` is the live routing-table node count — it climbs from `0` as
 the DHT bootstraps after the first add. All four come from libtorrent's
 `session_stats` counters, which the shim refreshes once per `btPoll`; a counter
 a given libtorrent build does not expose stays `0`.
- **Usage:** function - `put btDhtState(sSession) into tDht`.

### `btDhtSaveState(in pSession as Integer) returns Data`
The opaque DHT routing-table state as `Data`, for persistence across runs (write
it to a file, reload next launch). Empty `Data` on failure.
- **Usage:** function - `put btDhtSaveState(sSession) into tDhtBlob`.

### `btDhtLoadState(in pSession as Integer, in pData as Data) returns Integer`
Restore DHT routing-table state from bytes previously produced by
`btDhtSaveState`. Returns `0` / negative.
- **Usage:** command - `btDhtLoadState sSession, tDhtBlob`.

**BEP44 - the DHT as a key-value store.** The DHT can store small (<= 1000-byte)
values, not just peer lists. **Immutable** items are addressed by the SHA-1 of
their value (content-addressed, unchangeable); **mutable** items live under an
ed25519 public key (+ optional salt) and are signed, so the keyholder can publish
updated, sequence-numbered values. Reads are asynchronous - the value returns as
a drained `dhtImmutableItem` / `dhtMutableItem` event; puts confirm via a `dhtPut`
event. Signing happens entirely in the native layer (the secret key never reaches
a libtorrent thread through script).

### `btDhtKeypair(in pSeed as String) returns Array`
Generate (pass `""`) or deterministically re-derive (pass a 64-hex `seed`) an
ed25519 keypair for mutable items. Returns an Array keyed `publicKey` (64 hex),
`secretKey` (128 hex), `seed` (64 hex). **Persist the seed (or secret key)** to
keep a stable identity across runs.
- **Usage:** function - `put btDhtKeypair("") into tKey`, then save `tKey["seed"]`.

### `btDhtPutImmutable(in pSession as Integer, in pData as Data) returns String`
Store `pData` (1..1000 bytes) as an immutable item. Returns its **target hash**
(the lookup key) as hex, or `""` on failure; the store confirms later as a
`dhtPut` event. Anyone with the target can fetch the value.
- **Usage:** function - `put btDhtPutImmutable(sSession, tBytes) into tTarget`.

### `btDhtGetImmutable(in pSession as Integer, in pTarget as String) returns Integer`
Look up an immutable item by its 40-hex `pTarget`. Returns `0` / negative; the
value arrives as a `dhtImmutableItem` event.
- **Usage:** command - `btDhtGetImmutable sSession, tTarget`.

### `btDhtPutMutable(in pSession as Integer, in pPublicKey as String, in pSecretKey as String, in pSalt as String, in pData as Data) returns Integer`
Store `pData` (1..1000 bytes) as a mutable item under the ed25519 key (64-hex
public, 128-hex secret from `btDhtKeypair`), with an optional `pSalt` (`""` for
none). The native layer signs it and bumps the sequence number. Returns `0` /
negative; confirms via a `dhtPut` event. Re-putting under the same key+salt
publishes a new version.
- **Usage:** command - `btDhtPutMutable sSession, tKey["publicKey"], tKey["secretKey"], "myapp", tBytes`.

### `btDhtGetMutable(in pSession as Integer, in pPublicKey as String, in pSalt as String) returns Integer`
Look up a mutable item by its 64-hex `pPublicKey` (+ optional `pSalt`). Returns
`0` / negative; the value arrives as a `dhtMutableItem` event (carrying `value`,
`seq`, `signature`, `authoritative`).
- **Usage:** command - `btDhtGetMutable sSession, tPubKey, "myapp"`.

---

## Create (seeding side)

### `btCreateTorrent(in pContentPath as String, in pPieceSize as Integer, in pFlags as Integer, in pTrackers as String) returns Data`
Build a `.torrent` for `pContentPath` (a file or a directory) and return its
bencoded bytes as `Data`. `pPieceSize` of `0` means **auto**. `pFlags` is passed
through to libtorrent's create-torrent flags. `pTrackers` is an optional
newline-separated list of announce URLs (empty = a trackerless, DHT-only
torrent); each non-empty line becomes its own tracker tier, in order. Empty
`Data` on failure (`btLastError()`).
- **Usage:** function - `put btCreateTorrent(tPath, 0, 0, "udp://tr.example:1337/announce") into tTorrentBytes`,
 then `put tTorrentBytes into url ("binfile:" & tOut)`.

---

## Script-side helpers (`examples/torrent-helpers.livecodescript`)

These are **not** part of the `library` - they live in the helper stack you put
on the message path (`start using stack "torrentHelpers"`). They drive the poll
loop and provide formatting sugar. Listed here because the API is incomplete
without them.

| Helper | Kind | Signature | What it does |
|---|---|---|---|
| `btStartPolling` | command | `btStartPolling pSession, pTarget, pIntervalMs` | Arm the drain timer for `pSession`; dispatch each event to `pTarget` (default: the current card) every `pIntervalMs` ms (default `250`). Reschedules itself. |
| `btStopPolling` | command | `btStopPolling` | Disarm the timer. Safe when not polling. |
| `btTorrentPollOnce` | command | (internal) | One drain pass: `btPoll`, `dispatch` per event (plus a catch-all `torrentEvent`), reschedule. You normally do not call this directly. |
| `btFormatBytes` | function | `btFormatBytes(pBytes)` | Humanise a byte count to `B`/`KiB`/`MiB`/`GiB`/`TiB`, one decimal. |
| `btStateName` | function | `btStateName(pState)` | Map a `state` int to a label (see the state table below). |

The interval is a **latency/CPU knob**: throughput and event integrity are
independent of cadence (libtorrent buffers between drains); only worst-case event
latency scales with it. 250 ms suits a UI; tighten only for a very smooth live
dashboard.

---

## Reference table: status & peer record keys

From `_fieldKey` in `src/torrent.lcb` and the field registry in
`src/btx_record.h`. The schema field `type` is shown; every value reaches script
as a `String` (or `Data` for `raw`) after the LCB walker decodes it. **64-bit
ints and hashes are strings** - use `the number of tRec["totalDone"]` for
arithmetic.

### Torrent status (`btTorrentStatus`)

| key | field id | type | meaning |
|---|---|---|---|
| `name` | 1 | utf8 | torrent name (empty until `metadataReceived` for a magnet) |
| `state` | 2 | int | libtorrent `torrent_status::state_t`; map with `btStateName` |
| `progress` | 3 | real | fraction complete, `0.0 .. 1.0` |
| `downloadRate` | 4 | int | payload download rate, bytes/sec |
| `uploadRate` | 5 | int | payload upload rate, bytes/sec |
| `totalDone` | 6 | int (64-bit) | bytes downloaded and verified |
| `totalWanted` | 7 | int (64-bit) | bytes of the selected files to download |
| `numPeers` | 8 | int | connected peers |
| `numSeeds` | 9 | int | connected seeds |
| `savePath` | 10 | utf8 | download directory |
| `infoHashV1` | 11 | hex | v1 info-hash (empty if v2-only) |
| `infoHashV2` | 12 | hex | v2 info-hash (empty if v1-only) |
| `numPieces` | 13 | int | total pieces |
| `pieceLength` | 14 | int | piece size, bytes |
| `totalSize` | 15 | int (64-bit) | total content size, bytes |
| `allTimeDownload` | 16 | int (64-bit) | lifetime bytes downloaded |
| `allTimeUpload` | 17 | int (64-bit) | lifetime bytes uploaded |
| `numComplete` | 18 | int | seeds in the swarm (from scrape; `-1` if unknown) |
| `numIncomplete` | 19 | int | leechers in the swarm (from scrape; `-1` if unknown) |
| `isFinished` | 20 | int 0/1 | all selected files complete |
| `isSeeding` | 21 | int 0/1 | finished and uploading |
| `isPaused` | 22 | int 0/1 | torrent is paused |
| `error` | 23 | utf8 | torrent error message (`""` if none) |
| `eta` | 24 | int | seconds to completion; `-1` if unknown |
| `addedTime` | 25 | int | unix seconds the torrent was added |
| `completedTime` | 26 | int | unix seconds completed; `0` if not complete |
| `numConnections` | 27 | int | total peer connections |
| `flags` | 28 | int | low bits of `torrent_flags` |

### Peer entry (`btPeerList`, one array per peer)

| key | field id | type | meaning |
|---|---|---|---|
| `endpoint` | 40 | utf8 | peer address, `ip:port` |
| `client` | 41 | utf8 | peer client/version string |
| `downRate` | 42 | int | download rate from this peer, bytes/sec |
| `upRate` | 43 | int | upload rate to this peer, bytes/sec |
| `progress` | 44 | real | peer's completion fraction, `0..1` |
| `flags` | 45 | int | peer flag bits |

### File entry (`btFileList`, one array per file)

| key | field id | type | meaning |
|---|---|---|---|
| `path` | 120 | utf8 | file path within the torrent (relative) |
| `size` | 121 | int | file size, bytes |
| `progress` | 122 | int | bytes of this file downloaded |
| `priority` | 123 | int | this file's download priority, `0..7` |

### Tracker entry (`btTrackers`, one array per tracker)

| key | field id | type | meaning |
|---|---|---|---|
| `url` | 130 | utf8 | announce URL |
| `tier` | 131 | int | tracker tier (`0` == first) |
| `verified` | 132 | int | `1` once it has answered this session |
| `source` | 133 | int | `announce_entry` source bitmask |

(`btWebSeeds` returns a plain list of URL strings, not records.)

### DHT state (`btDhtState`)

| key | field id | type | meaning |
|---|---|---|---|
| `nodes` | 100 | int | nodes in the routing table |
| `nodeCache` | 101 | int | cached nodes |
| `globalNodes` | 102 | int (64-bit) | estimated DHT size |
| `torrents` | 103 | int | torrents tracked in the DHT |

> These four keys are populated from libtorrent's `session_stats` counters,
> refreshed once per `btPoll`; `nodes` is the routing-table count (no longer a
> 0/1 flag). A counter a given libtorrent build omits stays `0`.

### State int -> label (`btStateName`)

The `state` value is libtorrent's `torrent_status::state_t`. `btStateName`
(in the helper stack) maps it:

| `state` | `btStateName` returns |
|---|---|
| `1` | `checking` |
| `2` | `fetching metadata` |
| `3` | `downloading` |
| `4` | `finished` |
| `5` | `seeding` |
| `7` | `checking resume` |
| anything else (incl. `0`, `6`) | `queued` |

---

## Reference table: event "name" values

From `_alertName` in `src/torrent.lcb` and the alert registry in
`src/btx_record.h`. Each `btPoll` event array always has `code`, `name`, and
(when the event concerns one) `torrent`; the right-hand column lists the
**additional** keys that alert carries. An unrecognised code maps to the name
`torrentEvent` (also the catch-all the dispatcher fires for every event).

| `name` | code | additional event keys | when |
|---|---|---|---|
| `torrentAdded` | 1 | `torrentName`, `infoHashV1`, `infoHashV2` | a torrent was added to the session |
| `metadataReceived` | 2 | `torrentName`, `infoHashV1`, `infoHashV2` | magnet metadata arrived; name/files now known |
| `pieceFinished` | 3 | `piece` | a piece passed hash check (HIGH frequency - do not redraw per event) |
| `torrentFinished` | 4 | (`torrent` only) | all selected files complete |
| `torrentError` | 5 | `errorCode`, `errorMessage`, `message` | a torrent-level error |
| `stateChanged` | 6 | `state`, `prevState` | the torrent's state_t changed |
| `trackerReply` | 7 | `tracker`, `numPeers` | a tracker announce succeeded |
| `trackerError` | 8 | `tracker`, `errorCode`, `errorMessage`, `message` | a tracker announce failed |
| `resumeDataReady` | 9 | `resumeData` (raw bytes) | resume data you requested is ready to persist |
| `resumeDataFailed` | 10 | `errorCode`, `errorMessage`, `message` | the resume-data request failed |
| `torrentRemoved` | 11 | `infoHashV1`, `infoHashV2` | a torrent finished removal |
| `dhtBootstrap` | 12 | (none) | the DHT bootstrap completed |
| `listenSucceeded` | 13 | `endpoint` | a listen socket opened |
| `listenFailed` | 14 | `endpoint`, `errorCode`, `errorMessage`, `message` | a listen socket failed to open |
| `torrentPaused` | 15 | (`torrent` only) | the torrent paused |
| `torrentResumed` | 16 | (`torrent` only) | the torrent resumed |
| `fileCompleted` | 17 | `piece` (file index reused on this field) | a file within the torrent completed |
| `fileError` | 18 | `errorCode`, `errorMessage`, `message` | a file I/O error |
| `storageMoved` | 19 | `message` | the torrent's storage was moved |
| `fastresumeRejected` | 20 | `errorCode`, `errorMessage`, `message` | saved resume data was rejected; a recheck follows |
| `scrapeReply` | 21 | `numPeers`, plus swarm counts in status | a scrape (swarm seeder/leecher counts) returned |
| `dhtImmutableItem` | 22 | `target`, `value` | a `btDhtGetImmutable` lookup returned a value |
| `dhtMutableItem` | 23 | `publicKey`, `value`, `seq`, `signature`, `salt`, `authoritative` | a `btDhtGetMutable` lookup returned a value |
| `dhtPut` | 24 | `numSuccess`, plus `target` (immutable) or `publicKey`/`signature`/`seq`/`salt` (mutable) | a DHT put completed |

The full set of event-array key names available across all alerts (from
`_fieldKey`, ids `60..73` plus the BEP44 item ids `104..113`): `torrent`,
`message`, `errorCode`, `errorMessage`, `piece`, `state`, `prevState`, `tracker`,
`numPeers`, `resumeData`, `infoHashV1`, `infoHashV2`, `torrentName`, `endpoint`,
and for DHT items `target`, `value`, `publicKey`, `secretKey`, `seed`,
`signature`, `seq`, `salt`, `authoritative`, `numSuccess`. Which subset a given
alert populates is the shim's choice per alert; the column above reflects the
intended mapping and is implemented in `torrent_shim.cpp`, the source of truth for
which subset each alert populates.

---

## Reference table: settings keys

Keys for `btSetInt` / `btSetBool` / `btSetString` are libtorrent `settings_pack`
names. The commonly useful set:

| key | setter | meaning |
|---|---|---|
| `download_rate_limit` | `btSetInt` | session download cap, bytes/sec (`"0"` = unlimited) |
| `upload_rate_limit` | `btSetInt` | session upload cap, bytes/sec (`"0"` = unlimited) |
| `connections_limit` | `btSetInt` | max total peer connections |
| `enable_dht` | `btSetBool` | the DHT (BEP 5) on/off |
| `enable_lsd` | `btSetBool` | Local Service Discovery on/off |
| `enable_upnp` | `btSetBool` | UPnP port mapping on/off |
| `enable_natpmp` | `btSetBool` | NAT-PMP port mapping on/off |
| `user_agent` | `btSetString` | the peer/HTTP user-agent string |
| `listen_interfaces` | `btSetString` | listen address:port list, e.g. `"0.0.0.0:6881"` |
| `out_enc_policy` | `btSetInt` | outgoing encryption policy (also via `btSetEncryption`) |
| `in_enc_policy` | `btSetInt` | incoming encryption policy (also via `btSetEncryption`) |
| `allowed_enc_level` | `btSetInt` | allowed cipher level (also via `btSetEncryption`) |

The encryption triple is most cleanly set with **`btSetEncryption`** (policy
`0`=forced `1`=enabled `2`=disabled; level `1`=plaintext `2`=rc4 `3`=both) rather
than three `btSetInt` calls, but either works. **64-bit setting values pass as
decimal `String`s via `btSetInt`** (e.g. a multi-megabyte rate cap). Any
libtorrent `settings_pack` name of the right kind is accepted; an unknown key
fails with `BTX_ERR_INVALID_ARG`.

---

## Return codes (action / setter handlers)

From `src/btx_abi.h`. Getters do **not** use these - they return
bytes-written / `-needed` / empty (the buffer convention; see the FFI section of
`docs/architecture.md`). Action codes:

| code | name | meaning |
|---|---|---|
| `0` | `BTX_OK` | success |
| `-1` | `BTX_ERR_GENERIC` | unclassified failure; see `btLastError()` |
| `-2` | `BTX_ERR_BAD_HANDLE` | the session/torrent handle is not live |
| `-3` | `BTX_ERR_INVALID_ARG` | a null/empty/out-of-range argument (incl. unknown setting key) |
| `-4` | `BTX_ERR_SESSION_LIVE` | refused a second concurrent session |
| `-5` | `BTX_ERR_NO_SESSION` | the operation needs a session and none is live |
| `-6` | `BTX_ERR_EXCEPTION` | the firewall caught a libtorrent throw |
| `-7` | `BTX_ERR_ABI` | reserved for ABI-mismatch reporting |
