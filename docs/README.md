# TorrentXT documentation

TorrentXT is the full BitTorrent protocol for xTalk, over libtorrent-rasterbar:
the `bt*` handler surface. Start with [getting-started.md](getting-started.md).

| Document | What it is |
|---|---|
| [getting-started.md](getting-started.md) | Task-oriented introduction: install the extension, stand up a session, add a magnet, watch it download, shut down cleanly. Read this first. |
| [api-reference.md](api-reference.md) | The complete public surface of `org.openxtalk.library.torrent`. Every entry is one `public handler bt*` in `src/torrent.lcb`, which remains the source of truth. |
| [architecture.md](architecture.md) | The as-built map of how the pieces fit: the shim, the handle table, the event pump, the threading contract. |
| [building.md](building.md) | The native build (C++ shim to `torrentxt.{so,dll,dylib}`), how to refresh the committed per-platform binaries, and the CI matrix. |
| **Archive** — executed plans and superseded designs, kept for the reasoning | |
| [archive/TorrentXT-IMPLEMENTATION-PLAN.md](archive/TorrentXT-IMPLEMENTATION-PLAN.md) | The original design brief and specification. A design record, not a status page: the as-built account lives in `../CLAUDE.md`. |
| [../THIRD-PARTY-LICENSES.md](../THIRD-PARTY-LICENSES.md) | The per-file license map for libtorrent-rasterbar, Boost and the rest of the vendored stack. |

**Where else to look.** [`../README.md`](../README.md) is the member front door
(install, a short example, the honest status). [`../CLAUDE.md`](../CLAUDE.md) is
maintainer memory: the as-built record, the gotchas, and why each decision went
the way it did. Suite-wide documents that span more than one member live in
[`../../docs/`](../../docs/README.md), indexed there by kind.
