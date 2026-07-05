# Building a standalone app

No Cloud Quick Share is a single stack script, and it is **standalone-ready**: the UI
self-builds on every launch (nothing needs to persist in the stackfile), every handler
declares its variables (strict / `explicitVariables`-clean), and quitting is caught by
`shutdownRequest`, so a packaged `.exe` / `.app` / Linux binary shuts its session down
cleanly even on Cmd-Q or a Dock quit.

## Before you package

Put the script into a mainstack and confirm it runs from source first (see the Quick
Start in `../README.md`): create a one-card mainstack, paste
`../src/nocloudquickshare.livecodescript` into its **stack script**, compile, then
close and reopen the window. If it builds its UI and logs "ready", you are ready to
package.

## In the standalone builder

1. **Include the required extension:** `org.openxtalk.library.torrent` (**TorrentXT**).
   Without it there is no session and the app cannot run.
2. **Include the optional extensions** if you want their features — both fail closed
   with a clear message when absent, so it is safe to ship with or without them:
   - `org.openxtalk.library.sodium` (**cryptoXT**) — the passphrase encryption and the
     LAN web-editor password.
   - **OnionXT** — the Private / Tor path. It also needs cryptoXT, and at runtime a
     **local Tor daemon** on the user's machine (system tor on `127.0.0.1:9051`, or Tor
     Browser on `9151`).
3. **Include the Internet library (libURL).** It is used only for the public-IP lookup
   on the web-link path and is harmless if left out (the lookup is `try`-guarded).
4. **Nothing else.** No other inclusions, externals, fonts, or bundled resources are
   needed. The web-app demo in `../webapp/` is *content the user serves*, not something
   the standalone must bundle.

## Runtime facts to know

- **Downloads land in `Documents/No Cloud Quick Share`** on every platform (created on
  first use).
- **The window title, the startup log line, and the HTTP `Server:` header** all carry
  the release version constant `kQsAppVersion` (currently `1.0.0`) — bump it when you cut
  a release so bug reports identify their build.
- **The UI version** is a separate constant, `kQsUiVersion`. A saved stack rebuilds its
  UI when this differs; a fresh standalone always builds clean, so you do not need to
  touch it for packaging — only when you change the generated layout.
- **The web-link path opens a router port** via UPnP / NAT-PMP (through TorrentXT) and
  looks up the public IP; on networks where the router will not cooperate, the
  local-network link still works and the app explains the state.

## Per-platform notes

- The app itself has no native code to build — it depends entirely on the prebuilt OXT
  extensions above, which the standalone builder bundles for the target platforms you
  select.
- Tor features require the end user to have a Tor daemon running; that is a runtime
  dependency on their machine, not something you bundle.
- Test each packaged target with at least the **Share code** and **Web link** paths (no
  extra runtime dependencies) and, if you shipped cryptoXT/OnionXT, a passphrase share
  and a Tor share with a daemon running.
