# TorrentXT

**The full BitTorrent protocol for OpenXTalk and the xTalk family** (also LiveCode
9.6.3+). Add, control, seed and inspect torrents - DHT, PEX, magnets and metadata, uTP,
encryption, HTTP+UDP trackers, webseeds, BitTorrent v1 + v2 - from plain xTalk script.

TorrentXT is a binding to [**libtorrent-rasterbar**](https://www.libtorrent.org/), the C++
engine behind many real clients, wrapped behind a small, stable C ABI and exposed as an
OpenXTalk extension. The gigabytes stay on libtorrent's own network and disk threads; your
script only issues tiny commands and polls small status records, so it stays responsive on a
single-threaded runtime.

```
  your xTalk app
     |   bt* handlers  (btAddMagnet, btTorrentStatus, btPoll, ...)
  library org.openxtalk.library.torrent     src/torrent.lcb
     |   c:torrentxt> btx_*  (a flat extern "C" ABI)
  torrentxt.{so,dll,dylib}                   src/torrent_shim.cpp
     |
  libtorrent-rasterbar + Boost.Asio          owns the network + disk-I/O threads
```

## Features

- **Add anything** - magnets, `.torrent` files and resume data, with optional add-time flags
  (add *paused* to set priorities first, or *sequential* for streaming).
- **Full control** - pause, resume, recheck, reannounce, scrape, move-storage, clear-error,
  remove (with or without data), download-queue positioning, and per-torrent modes
  (sequential, auto-managed, super-seeding, share-mode, upload-only).
- **Seeding and creation** - build a `.torrent` from a file or folder and seed it.
- **Tuning** - file and piece priorities, per-torrent rate / connection / upload-slot caps,
  the full `settings_pack` surface, an IP filter, and streaming piece-deadlines.
- **Networking** - DHT (BEP 5) with bootstrap, saved state and announce, LSD, PEX, uTP,
  UPnP/NAT-PMP, MSE/PE encryption, session pause/resume, find-by-info-hash.
- **BEP44 DHT key-value store** - small signed (mutable) or content-addressed (immutable)
  values: a server-less rendezvous and identity layer.
- **Inspection** - status snapshots (state, progress, rates, peers, ETA), the peer list, the
  piece bitfield and availability, the file table, trackers and web seeds (editable at
  runtime, BEP 19).
- **Persistence** - fast-resume data, so a partial download survives a restart.
- **rp1** - a custom BEP10 peer-wire extension that moves opaque bytes between peers with no
  tracker, server or content.
- **Events, not callbacks** - inbound activity arrives as ordinary message-path handlers via
  a poll-drained queue, never from a foreign thread.

## Platform support

The native engine ships **bundled inside the extension**: no `sudo`, no loose library, no
`LD_LIBRARY_PATH`. All five platform binaries are committed under `src/code/`.

| Platform | Arch | Committed binary |
|---|---|---|
| Linux | x86-64 | libtorrent 2.0.11, static libstdc++ and OpenSSL 3.5; floor **glibc 2.28** (manylinux_2_28) |
| Linux | x86 (32-bit) | libtorrent 2.0.11; floor glibc 2.38 plus the system `libssl.so.3` / `libcrypto.so.3` (no manylinux i686 image exists) |
| Windows | x86-64 | libtorrent **2.1.1** (vcpkg), static OpenSSL |
| Windows | x86 (32-bit) | libtorrent **2.1.1** (vcpkg), static OpenSSL |
| macOS | universal (arm64 + x86-64) | since 2026-08-27: libtorrent 2.0.11, static OpenSSL; unsigned (the linker's ad-hoc signature, accepted by the owner 2026-08-23), so a browser-downloaded copy needs its quarantine attribute cleared |

Every torrentxt harness figure with a recorded platform came from Windows (see
[Status](#status)).
[docs/building.md](docs/building.md) has the floors and how each binary is built.

## Install

Install the packaged extension in the OpenXTalk IDE like any other. Your stack then sees
`library org.openxtalk.library.torrent` and its public `bt*` handlers; the engine resolves the
`c:torrentxt>` binding through `the revLibraryMapping`.

Then put the **poll dispatcher** on the message path, so the engine drives ordinary event
handlers instead of a hand-rolled loop:

```livecodescript
start using stack "torrentHelpers"   -- examples/torrent-helpers.livecodescript
```

It supplies `btStartPolling` / `btStopPolling` and the formatting sugar (`btFormatBytes`,
`btStateName`).

## Quick start

libtorrent owns background threads and OXT has no deterministic extension-unload hook, so
you **bracket the session around your stack's life**: start it in `openStack`, tear it down
in `closeStack`. This is the one rule you must follow.

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
   local tTorrent
   btAddMagnet sSession, pMagnet, specialFolderPath("documents") & "/downloads"
   put the result into tTorrent      -- a torrent handle, or 0 on failure
end addOne

-- inbound activity arrives as ordinary handlers, each given ONE event array
on pieceFinished pEvent
   -- pEvent["torrent"], pEvent["piece"]: update a progress bar at <= 4 Hz, not per piece
end pieceFinished

on torrentFinished pEvent
   local tStatus
   put btTorrentStatus(pEvent["torrent"]) into tStatus
   answer "Done:" && tStatus["name"]
end torrentFinished
```

`btTorrentStatus(handle)` returns an array (`name`, `state`, `progress`, `downloadRate`,
`uploadRate`, `numPeers`, `eta`, `totalDone`, `totalSize`, ...); poll it a few times a second
to drive a dashboard. [docs/getting-started.md](docs/getting-started.md) is the full
walkthrough.

## The three rules that make it safe

1. **No script ever runs on a libtorrent thread.** Every inbound event rides libtorrent's
   alert queue, which the binding poll-drains (`btPoll`). The poll interval is a latency/CPU
   knob, as long as neither queue fills between drains (libtorrent's `alert_queue_size`, 1000
   by default; a dropped alert is reported through `btLastError()`).
2. **The exception firewall.** libtorrent throws; every `btx_*` entry point wraps its body in
   `try { ... } catch (...)` and returns an error code, so no exception crosses into the engine.
3. **Payload never crosses into script.** Piece data moves engine <-> disk on libtorrent's
   threads; script only sees small status records and events.

## API at a glance

85 public `bt*` handlers at ABI 11 (full signatures in
[docs/api-reference.md](docs/api-reference.md)):

| Group | Handlers |
|---|---|
| Session | `btStartSession`, `btStopSession`, `btLastError`, `btClearError`, `btSessionPause`, `btSessionResume`, `btSessionIsPaused`, `btListenPort`, `btFindTorrent`, `btDhtAnnounce` |
| Settings | `btSetInt`, `btSetBool`, `btSetString`, `btGetSetting`, `btSetEncryption` |
| Add / remove | `btAddMagnet`, `btAddTorrentFile`, `btAddTorrentWithResume`, `btRemoveTorrent`, `btAddMagnetEx`, `btAddTorrentFileEx`, `btAddInfohash` |
| Filter / streaming | `btIpFilterAdd`, `btIpFilterClear`, `btSetPieceDeadline`, `btClearPieceDeadlines` |
| Control | `btPause`, `btResume`, `btForceRecheck`, `btForceReannounce`, `btScrapeTracker`, `btClearTorrentError` |
| Priorities / limits | `btSetFilePriority`, `btSetFilePriorities`, `btSetPiecePriority`, `btSetTorrentLimits`, `btSetMaxConnections`, `btSetMaxUploads` |
| Flags / modes | `btSetTorrentFlags`, `btUnsetTorrentFlags`, `btSetSequentialDownload`, `btSetAutoManaged`, `btSetSuperSeeding`, `btSetShareMode`, `btSetUploadMode` |
| Queue / storage | `btQueuePosition`, `btQueueUp`, `btQueueDown`, `btQueueTop`, `btQueueBottom`, `btMoveStorage` |
| Inspect | `btTorrentStatus`, `btTorrentCount`, `btTorrentHandleAt`, `btInfoHash`, `btPieceBitfield`, `btPeerList`, `btFileList`, `btPieceAvailability` |
| Trackers / seeds | `btTrackers`, `btAddTracker`, `btWebSeeds`, `btAddWebSeed`, `btRemoveWebSeed` |
| Events | `btPoll` |
| DHT | `btDhtAddBootstrap`, `btDhtState`, `btDhtSaveState`, `btDhtLoadState`, `btDhtGetPeers` |
| DHT key-value (BEP44) | `btDhtKeypair`, `btDhtPutImmutable`, `btDhtGetImmutable`, `btDhtPutMutable`, `btDhtGetMutable`, `btDhtBep44SignBuf`, `btDhtPutSigned` |
| Connectivity (NAT) | `btMapPort`, `btUnmapPort` |
| rp1 transport | `btRp1Enable`, `btRp1SetToken`, `btRp1Send`, `btRp1Poll` |
| Create / seed | `btCreateTorrent` |
| Resume | `btSaveResumeData` |

## Examples

[examples/README.md](examples/README.md) is the guide: how to run a demo (paste the file
into a new stack's script, then close and reopen it) and what each one does.

- **[torrent-quickshare](examples/torrent-quickshare.livecodescript)** - the place to start:
  drag a file onto the window, send the short code to a friend, and they download it straight
  from you, with the DHT introducing the two machines. Optional passphrase lock (SodiumXT),
  Tor mode (OnionXT and a local Tor daemon), and a direct web link with a small web host.
- **[torrent-client](examples/torrent-client.livecodescript)** - a self-building multi-torrent
  client with create-and-seed and a Files / Peers / Trackers / Log inspector.
- **[torrent-dht-channels](examples/torrent-dht-channels.livecodescript)** - decentralized
  channels: publish files under your ed25519 key on the DHT, follow others' channels and
  download their releases peer to peer. Optional private channels (SodiumXT) and an Anonymous
  mode over Tor (OnionXT embedded, plus SodiumXT and a local Tor daemon; fails closed without
  them). *Anonymous channels: verified statically; needs an OXT pass with a running Tor
  daemon.*
- **[torrent-rp1-chat](examples/torrent-rp1-chat.livecodescript)** - two machines exchange
  messages directly over the rp1 peer wire, using the DHT to meet: the smallest working use
  of `btRp1Enable` / `btRp1SetToken` / `btRp1Send` / `btRp1Poll`.
- **[torrent-helpers](examples/torrent-helpers.livecodescript)** - the reusable poll
  dispatcher and formatting sugar; the demos carry their own poll loops and run without it.

## Documentation

| Document | What it is |
|---|---|
| [docs/getting-started.md](docs/getting-started.md) | Install, the mandatory session lifecycle, adding a magnet, the event model, resume persistence, troubleshooting. Read this first. |
| [docs/api-reference.md](docs/api-reference.md) | Every public `bt*` handler, the status / peer / file / tracker / DHT keys, events, settings and return codes. `src/torrent.lcb` remains the source of truth. |
| [docs/architecture.md](docs/architecture.md) | How the pieces fit and why: the layers, the wire format, handles, FFI byte marshalling, the design decisions, and what is verifiable where. |
| [docs/building.md](docs/building.md) | Building the native shim, the CMake options, the platform floors, refreshing the committed binaries, and CI. |
| [examples/README.md](examples/README.md) | Running the demos, and what each one does. |
| [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) | The libtorrent-rasterbar and Boost license texts. |
| [CLAUDE.md](CLAUDE.md) | Maintainer memory: the rules, the traps, and the dated engine evidence ledger. |

Suite-wide documents live in the suite's `docs/`, indexed at
https://github.com/SethMorrowSoftware/xtalk-suite/blob/main/docs/README.md.

## Building from source

Most users just install the packaged extension; this rebuilds the native engine.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTORRENTXT_BUILD_TESTS=ON
cmake --build build --config Release
ctest --test-dir build --output-on-failure
```

CMake fetches and statically links the pinned libtorrent (v2.0.11) and Boost. The build is
the heavy part; [docs/building.md](docs/building.md) has the options, the sanitizer builds
and the per-platform notes.

## Status

85 public `bt*` handlers at ABI 11: essentially the full practical libtorrent surface, plus
BEP44 signed mutable items, NAT port mapping and the rp1 transport. The member harness
(`tests/torrent-selftest.livecodescript`, folded into the suite self-test) ran **101/101 on a
real engine** on Windows on 2026-08-17, 2026-08-20 and 2026-08-24 (first full run 96/96 on
2026-08-10; the session lifecycle and the signed-put refusal first observed 2026-08-08), so
every public handler has executed on an engine. The two-machine rp1/DHT transport is
evidenced through riptide (2026-08-13, 2026-08-15), and rp1 chat was reported working
across two machines on one LAN on 2026-08-27. Still owed: a first
engine load of the binaries committed 2026-09-12 (which add the rp1 queue cap, the 996-byte
BEP44 cap and the dropped-alert report) and of libtorrent 2.1 on Windows; any Linux, 32-bit
Windows or macOS engine; and the demos' kit-unified UIs, Tor paths and remaining two-machine
runs, which are "verified statically; needs an OXT pass". The dated ledger is in
[CLAUDE.md](CLAUDE.md). The visual dashboard widget was **decided out of v1 scope on
2026-08-13**: a recorded decision, not a maturity gap.

## License

TorrentXT (the shim and the LCB binding) is MIT-licensed, like its sibling OpenXTalk
extensions. It links **libtorrent-rasterbar** (BSD-3-Clause) and **Boost** (Boost Software
License 1.0); those permissive licenses are part of why libtorrent was chosen
([docs/architecture.md](docs/architecture.md)). The x86-64 Linux, both Windows and the macOS
binaries also statically link **OpenSSL** (Apache-2.0); the 32-bit Linux binary uses the
system's. [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) carries the libtorrent and Boost
texts (an OpenSSL notice is owed there).

<!-- ==== SUITE RELATIONSHIP BEGIN (generated by tools/sync-member-readmes.py in the xTalk suite from tools/member-registry.py and the carried-copy registries; do not edit inside the markers) ==== -->

## Relationship to the xTalk suite

TorrentXT is developed in the **xTalk suite** monorepo at https://github.com/SethMorrowSoftware/xtalk-suite, as its
`torrentxt/` member, and PUBLISHED from there into this repository,
https://github.com/SethMorrowSoftware/TorrentXT: once a change lands on the suite's `main` and
the suite's gates pass, the suite's `tools/publish-members.py` replays it
here as a commit carrying a `Suite-Commit:` trailer that names the suite
commit it came from. The suite is the source of truth; this repository is
its published copy, one commit for each change to `torrentxt/` that landed on
the suite's `main`.

**Contributing.** Please open issues and pull requests at the suite. A pull
request opened here is not lost - the suite brings it home with
`python3 tools/publish-members.py port torrentxt --ref pull/<n>/head`, keeping its
author - but a commit made here directly holds up the next publish until
it has been ported, because publishing never overwrites work it did not
write. The suite's `docs/MEMBER-REPO-SPLIT.md` is the whole workflow.

**Suite-level paths cited from here.** This member's `CLAUDE.md` and
`docs/` cite files that live at the suite root, not in this tree:
`docs/OXT-ENGINE-NOTES.md` (engine behaviour, the authoritative list),
`docs/OXT-PASS-RUNBOOK.md`, `tools/build-all.sh`,
`tests/suite-selftest.livecodescript` and the suite-level `docs/`
index. Read them at `https://github.com/SethMorrowSoftware/xtalk-suite/blob/main/<path>`. A path of the
form `../<member>/...` names a sibling member of the suite; each has its
own repository, listed in `tools/member-registry.py` there.

**Sibling members this member's gates need beside it.** None: `bash
tools/run-gates.sh` (this member's own gate list, the one CI runs)
needs nothing but this checkout and Python 3.

**Carried copies inside this member, and where their masters are.**
Every runnable stack here is one paste-and-run file, so it carries what
it needs verbatim between marker lines. The masters, and the drift gates
that hold every copy byte-identical to them, live in the suite and do
not travel with this member; refresh a copy from the suite (the marker
lines name the master) rather than editing inside the markers.

- The demo UI kit (`tools/ui-kit.livecodescript`; gate `tools/check-ui-kit-drift.py`) in `examples/torrent-client.livecodescript`, `examples/torrent-dht-channels.livecodescript`, `examples/torrent-quickshare.livecodescript`, `examples/torrent-rp1-chat.livecodescript`.
- The boot self-check block (`tools/demo-selfcheck.livecodescript`; gate `tools/check-demo-selfcheck-drift.py`) in `examples/torrent-client.livecodescript`, `examples/torrent-dht-channels.livecodescript`, `examples/torrent-quickshare.livecodescript`, `examples/torrent-rp1-chat.livecodescript`.
- The self-test harness scaffold (`tools/harness-scaffold.livecodescript`; gate `tools/check-harness-scaffold-drift.py`) in `tests/torrent-selftest.livecodescript`.
- Sibling libraries embedded by the suite's `tools/sync-demo-embeds.py` (the copy is the shipped file; the master is the sibling's `src/`):
  - `examples/torrent-dht-channels.livecodescript` carries `onionxt/src/onionxt.livecodescript` from https://github.com/SethMorrowSoftware/OnionXT.
- `examples/torrent-quickshare.livecodescript` deliberately embeds nothing: defines socketError/socketClosed/socketTimeout with real clearweb logic that passes through to OnionXT's copies; embedding OnionXT would define all three twice. Merging two live bodies is a behaviour change to the inbound socket path, which has no engine pass yet (runbook S2). Keeps its optional `start using onionxt` for Tor.
- `tools/check-livecodescript.py`: byte-identical copies of the family's unified tooling, held identical across members by the suite's `tools/check-checker-drift.py` and fixture-tested there by `tools/test-checker.py`.

**What other members carry from this one.** The suite embeds this
member's script into the stacks below, verbatim; a change to it
reaches them when the suite re-runs `tools/sync-demo-embeds.py`, and
is not done until every carrier has been re-run on an engine:

- `enetxt/examples/enet-internet-chat.livecodescript` in enetxt carries `examples/torrent-helpers.livecodescript`.

**What this repository cannot check on its own.** The suite-wide gates -
cross-library name disjointness (`tools/check-cross-library-names.py`),
the carried-copy drift gates above, embed freshness, the cross-member
handler-call and typed-boundary checks (`tools/check-handler-calls.py`,
`tools/check-lcb-call-types.py`), the timer-pin closure, and the suite
paste's coverage ratchet (`tools/check-suite-coverage.py`) - run only in
the suite. `tools/run-gates.sh` here is this member's own list, and the
suite's `tools/build-all.sh` runs that same script, so the two cannot
disagree about what this member's gates are.

<!-- ==== SUITE RELATIONSHIP END ==== -->
