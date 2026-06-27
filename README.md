# TorrentXT

**The full BitTorrent protocol for OpenXTalk and the xTalk family** (also LiveCode
9.6.3+). Add, control, seed, and inspect torrents — DHT, PEX, magnets and metadata,
uTP, encryption, HTTP+UDP trackers, webseeds, BitTorrent v1 + v2 — all from plain
xTalk script.

TorrentXT is a binding to [**libtorrent-rasterbar**](https://www.libtorrent.org/)
(the battle-tested C++ engine behind many real clients), wrapped behind a small,
stable C ABI and exposed as an OpenXTalk extension. The gigabytes stay on
libtorrent's own network and disk threads; your script only issues tiny commands
and polls small status records — so it stays responsive on a single-threaded
runtime.

```
  your xTalk app
     |   bt* handlers  (btAddMagnet, btTorrentStatus, btPoll, ...)
  library org.openxtalk.library.torrent     src/torrent.lcb
     |   c:torrentxt> btx_*  (a flat extern "C" ABI)
  torrentxt.{so,dll,dylib}                   src/torrent_shim.cpp
     |
  libtorrent-rasterbar + Boost.Asio          owns the network + disk-I/O threads
```

---

## Features

- **Add anything** — magnet links, `.torrent` files, and resume data; metadata is
  fetched over the swarm for magnets. Optional **add-time flags** (e.g. add
  *paused* to set priorities before it starts, or *sequential* for streaming).
- **Full control** — pause, resume, force-recheck, force-reannounce, scrape,
  move-storage, clear-error, remove (with or without data), and **download-queue**
  positioning (up / down / top / bottom).
- **Modes** — per-torrent `torrent_flags`: sequential download (streaming),
  auto-managed, super-seeding, share-mode, upload-only.
- **Seeding & creation** — build a `.torrent` from a file or folder and seed it.
- **Tuning** — per-file and per-piece priorities, per-torrent rate caps and
  connection / upload-slot caps, the full libtorrent `settings_pack` surface, an
  **IP filter** (block ranges / blocklists), and **streaming piece-deadlines**.
- **Networking** — DHT (BEP 5) with bootstrap, saved state and peer announce,
  Local Service Discovery, PEX, uTP, UPnP/NAT-PMP, MSE/PE encryption; plus
  whole-session pause/resume, the bound listen port, and find-by-info-hash.
- **DHT key-value store (BEP44)** — put/get small signed (mutable) or
  content-addressed (immutable) values: a server-less rendezvous / identity layer.
- **Inspection** — live status snapshots (state, progress, rates, peers, ETA), the
  peer list, the piece-completion bitfield and per-piece availability, the **file
  table** (names, sizes, per-file progress and priority), the **tracker list**,
  and **web seeds**.
- **Trackers & web seeds** — list and edit a torrent's announce list and its
  HTTP/URL seeds (BEP 19) at runtime.
- **Persistence** — save and reload fast-resume data so a partial download survives
  a restart.
- **Events, not callbacks** — inbound activity (metadata received, piece finished,
  torrent finished, tracker replies, scrape/storage results, errors) arrives as
  ordinary message-path handlers via a poll-drained queue, never from a foreign
  thread.

## Platform support

The native engine ships **bundled inside the extension** — no `sudo`, no loose
library, no `LD_LIBRARY_PATH`. Installing the packaged extension is all that is
required.

| Platform | Arch | Status |
|---|---|---|
| Linux | x86-64 | ✅ committed (statically linked; self-contained on glibc 2.35+ / OpenSSL 3) |
| Linux | x86 (32-bit) | ✅ committed |
| Windows | x86-64 | ✅ committed |
| Windows | x86 (32-bit) | ✅ committed |
| macOS | universal (arm64 + x86-64) | 🚧 buildable from source; signed universal dylib pending |

---

## Install

In the OpenXTalk IDE, install the packaged extension the same way as any other.
Your stack then sees `library org.openxtalk.library.torrent` and its public `bt*`
handlers on the message path. The engine resolves the `c:torrentxt>` binding
automatically via `the revLibraryMapping`.

Then put the **poll dispatcher** on the message path so you can drive the engine
with event handlers instead of a hand-rolled loop:

```livecodescript
start using stack "torrentHelpers"   -- examples/torrent-helpers.livecodescript
```

It supplies `btStartPolling` / `btStopPolling` and the formatting sugar
(`btFormatBytes`, `btStateName`).

## Quick start

libtorrent owns background threads and OXT has no deterministic extension-unload
hook, so you **bracket the session around your stack's life** — start it in
`openStack`, tear it down in `closeStack`. This is the one rule you must follow.

```livecodescript
local sSession

on openStack
   -- btStartSession verifies the native ABI (throws on skew) and refuses a 2nd
   -- session. It is a command -> read the handle from the result.
   btStartSession
   put the result into sSession
   if sSession is 0 then
      answer "TorrentXT failed to start:" && btLastError()
      exit openStack
   end if
   btSetBool sSession, "enable_dht", true
   -- drive events to this card; a 250 ms drain is plenty for a UI
   btStartPolling sSession, the long id of this card, 250
end openStack

on closeStack
   -- MUST shut down explicitly: pauses, flushes resume data, joins threads.
   btStopPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
end closeStack

-- add a magnet and start downloading into a folder
on addOne pMagnet
   btAddMagnet sSession, pMagnet, specialFolderPath("documents") & "/downloads"
   put the result into tTorrent      -- a torrent handle, or 0 on failure
end addOne

-- inbound activity arrives as ordinary handlers (from the poll dispatcher)
on pieceFinished pTorrent, pPieceIndex
   -- update a progress bar, etc.
end pieceFinished

on torrentFinished pTorrent
   local tStatus
   put btTorrentStatus(pTorrent) into tStatus
   answer "Done:" && tStatus["name"]
end torrentFinished
```

`btTorrentStatus(handle)` returns an array (`name`, `state`, `progress`,
`downloadRate`, `uploadRate`, `numPeers`, `eta`, `totalDone`, `totalSize`, …) — poll
it a few times a second to drive a dashboard. See **[getting-started](docs/getting-started.md)**
for the full walkthrough.

---

## The three rules that make it safe

These are load-bearing and enforced in the code:

1. **No script ever runs on a libtorrent thread.** Every inbound event rides
   libtorrent's alert queue, which the binding poll-drains (`btPoll`). The poll
   interval is a latency/CPU knob, not a correctness knob.
2. **The exception firewall.** libtorrent throws; every `btx_*` entry point wraps
   its body in `try { … } catch (...)` and returns an error code, so no exception
   ever crosses into the engine.
3. **Payload never crosses into script.** Piece data moves engine ⇄ disk on
   libtorrent's threads; script only sees small status records and events.

## API at a glance

75 public `bt*` handlers (full signatures in **[api-reference](docs/api-reference.md)**):

| Group | Handlers |
|---|---|
| Session | `btStartSession` · `btStopSession` · `btLastError` · `btClearError` · `btSessionPause` · `btSessionResume` · `btSessionIsPaused` · `btListenPort` · `btFindTorrent` · `btDhtAnnounce` |
| Settings | `btSetInt` · `btSetBool` · `btSetString` · `btGetSetting` · `btSetEncryption` |
| Add / remove | `btAddMagnet` · `btAddTorrentFile` · `btAddTorrentWithResume` · `btRemoveTorrent` · `btAddMagnetEx` · `btAddTorrentFileEx` |
| Filter / streaming | `btIpFilterAdd` · `btIpFilterClear` · `btSetPieceDeadline` · `btClearPieceDeadlines` |
| Control | `btPause` · `btResume` · `btForceRecheck` · `btForceReannounce` · `btScrapeTracker` · `btClearTorrentError` |
| Priorities / limits | `btSetFilePriority` · `btSetFilePriorities` · `btSetPiecePriority` · `btSetTorrentLimits` · `btSetMaxConnections` · `btSetMaxUploads` |
| Flags / modes | `btSetTorrentFlags` · `btUnsetTorrentFlags` · `btSetSequentialDownload` · `btSetAutoManaged` · `btSetSuperSeeding` · `btSetShareMode` · `btSetUploadMode` |
| Queue / storage | `btQueuePosition` · `btQueueUp` · `btQueueDown` · `btQueueTop` · `btQueueBottom` · `btMoveStorage` |
| Inspect | `btTorrentStatus` · `btTorrentCount` · `btTorrentHandleAt` · `btInfoHash` · `btPieceBitfield` · `btPeerList` · `btFileList` · `btPieceAvailability` |
| Trackers / seeds | `btTrackers` · `btAddTracker` · `btWebSeeds` · `btAddWebSeed` · `btRemoveWebSeed` |
| Events | `btPoll` |
| DHT | `btDhtAddBootstrap` · `btDhtState` · `btDhtSaveState` · `btDhtLoadState` |
| DHT key-value (BEP44) | `btDhtKeypair` · `btDhtPutImmutable` · `btDhtGetImmutable` · `btDhtPutMutable` · `btDhtGetMutable` |
| Create / seed | `btCreateTorrent` |
| Resume | `btSaveResumeData` |

## Examples

Two runnable flagship demos plus the shared poll-dispatcher utility:

- **[`examples/torrent-client.livecodescript`](examples/torrent-client.livecodescript)**
  — the flagship client: a self-building, multi-torrent app with a smart Add box
  (magnet / `.torrent` / HTTP / info-hash), per-torrent controls, create-and-seed, a
  live color-coded table with inline progress bars, DHT bootstrap, and an event log.
- **[`examples/torrent-dht-channels.livecodescript`](examples/torrent-dht-channels.livecodescript)**
  — the flagship **multi-machine DHT demo**: a fully decentralized "channel" app that
  marries the DHT and BitTorrent. Publish a file to *your* channel (it creates,
  seeds, and announces the magnet under your ed25519 key on the DHT); follow other
  people's channel addresses and one-click **download** their latest release while
  they seed — no server anywhere. Includes a signed multi-release feed, a live
  color-coded transfers table, shareable channel cards, and an immutable "quick
  drop" (pin text, share a 40-char code). The DHT says *where*, BitTorrent moves
  *what*. A built-in **"What is this?"** button explains it in plain language.
- **[`examples/torrent-helpers.livecodescript`](examples/torrent-helpers.livecodescript)**
  — the reusable **poll dispatcher** (`btStartPolling` / `btStopPolling`) and
  formatting sugar (`btFormatBytes`, `btStateName`). `start using` it to drive
  engine events as ordinary message-path handlers; the getting-started guide builds
  on it. (Both flagship demos are self-contained and run without it.)

## Documentation

- **[getting-started.md](docs/getting-started.md)** — install, the mandatory
  lifecycle, the event model, a full walkthrough.
- **[api-reference.md](docs/api-reference.md)** — the call-by-call contract: every
  handler, every status/event field, settings keys, return codes.
- **[architecture.md](docs/architecture.md)** — how the stack fits together, the FFI
  marshalling, the wire format, the handle table, what's verifiable where.
- **[building.md](docs/building.md)** — building the native shim from source, the
  CMake options, the CI matrix, the platform floors.
- **[TorrentXT-IMPLEMENTATION-PLAN.md](docs/TorrentXT-IMPLEMENTATION-PLAN.md)** — the
  original design brief, kept for the *why* (engine choice, ABI design, risk
  register).

## Building from source

You only need this to rebuild the native engine (e.g. for macOS) — most users just
install the packaged extension.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTORRENTXT_BUILD_TESTS=ON
cmake --build build --config Release
ctest --test-dir build --output-on-failure
```

CMake fetches and statically links the pinned libtorrent (v2.0.11) + Boost. The
build is the heavy part — see **[building.md](docs/building.md)** for details,
sanitizer builds, and the per-platform notes.

## Status

The public API spans **75 `bt*` handlers** (ABI v8) — essentially the full
practical libtorrent surface. The shim, the LCB binding, the test suite, and four
of five platform binaries are built and gated by CI; the shim is exercised under
ASan/UBSan against real libtorrent on every change. Because OpenXTalk has no
headless way to compile or run `.lcb`, runtime behaviour is marked "verified
statically; needs an OXT pass" and confirmed by a human in the IDE — the project
does not claim runtime behaviour it cannot observe. Remaining: the signed macOS
universal dylib, and the optional visual dashboard widget.

## License

TorrentXT (the shim and the LCB binding) is MIT-licensed, in line with the sibling
OpenXTalk extensions. It links **libtorrent-rasterbar** and **Boost**, which are
distributed under the BSD-3-Clause and Boost Software licenses respectively. Those
permissive licenses are why libtorrent was chosen (see the implementation plan §1).
