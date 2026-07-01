# TorrentXT Examples

Four self-contained demo apps and one reusable helper, all written in pure xTalk on
top of the **TorrentXT** extension. Each demo is a single stack script: you paste it
into a stack, reopen the stack, and it builds its own UI and starts a BitTorrent
session automatically. No helper stacks, no manual layout.

## What is here

| File | What it is | Needs cryptoXT? |
|------|------------|-----------------|
| `torrent-quickshare.livecodescript` | The simplest demo: drag a file, get a code, a friend pastes it and downloads it straight from you. | Only for the optional passphrase lock |
| `torrent-client.livecodescript` | A full multi-torrent client: add magnets / `.torrent` files / URLs, seed a folder, and manage many torrents with a live Files / Peers / Trackers / Log inspector. | No |
| `torrent-dht-channels.livecodescript` | A decentralized "channels" app: publish files under your own key, follow others by their key, no server anywhere (the DHT is the directory). | Only for private (passphrase) channels |
| `torrent-helpers.livecodescript` | A building block, NOT a demo: a poll dispatcher so your own app can drive TorrentXT with plain event handlers. See the last section. | No |

Start with **quickshare** if you just want to see it work, then **client**, then
**channels** for the full decentralized story.

## Before you start

1. **Install OpenXTalk (OXT).** These demos also run in LiveCode 9.6.3+, but OXT is
   the target.
2. **Install the TorrentXT extension** and make sure it is loaded. In OXT this is
   `Tools > Extension Manager`. The library id is `org.openxtalk.library.torrent`.
   If you are building it yourself, see `../docs/building.md` and
   `../tools/package-extension.py`.
3. **(Optional) Install cryptoXT** if you want the encryption features (the private
   channels in the channels demo, and the passphrase lock in quickshare and on your
   channel identity). Its library id is `org.openxtalk.library.sodium`. Everything
   except those encryption features works without it.

## Running any demo

The demos are stack scripts, so you paste one into a stack and let it build itself:

1. In OXT, create a new one-card stack: `File > New Mainstack`.
2. Open that stack's script: `Object > Stack Script`.
3. Open the demo's `.livecodescript` file in any text editor, copy ALL of it, and
   paste it into the stack script. Apply / compile the script.
4. **Close the stack window and reopen it.** Reopening fires the script's
   `openStack`, which builds the whole UI and starts a session. (If you would
   rather not close it, run `send "openStack" to this stack` from the message box.)
5. Use the app. When you are done, **close the window** so it shuts the session
   down cleanly (it flushes fast-resume data and releases the port).

That is it. The UI, the session, the poll loop, and the shutdown are all handled by
the pasted script.

## The demos

### Quick Share (`torrent-quickshare.livecodescript`)
Drag any file onto the window (or click to choose one). You get a short **code**;
send that code to a friend and they paste it into "Receive a file" and click
Download. The file transfers straight from your machine to theirs, no server and no
size limit, with the DHT finding the peers. Keep your window open until they have
the whole file.
Optional: type a **passphrase** before dropping the file (needs cryptoXT) and the
share is encrypted end to end. The code carries a verifier, so a wrong passphrase is
caught instantly with no wasted download.

### Client (`torrent-client.livecodescript`)
A real multi-torrent client. Paste a magnet, an `http(s)` `.torrent` URL, a local
`.torrent` path, or a 40-hex info-hash into the Add box (or drag one onto the
window). Select a torrent and use the toolbar to Pause / Resume / Recheck / Remove /
Open Folder, toggle streaming (sequential download), or reorder the queue. The bottom
panel inspects the selected torrent's **Files** (double-click a file to set its
priority), **Peers**, **Trackers**, and the event **Log**. You can also build a
`.torrent` from a folder and seed it. Settings and window size are remembered.

### Decentralized Channels (`torrent-dht-channels.livecodescript`)
The full decentralized story, on two or more machines. Give a channel a name, click
**Publish a File**, and it seeds the file and publishes the magnet in your channel's
signed feed on the DHT. Send someone your channel address (the "Copy" button); on
their machine they paste it, click **Follow**, and see your signed releases, which
they can Download peer to peer. You can run several channels. Set a **passphrase**
(needs cryptoXT) to make a channel private: the file list AND the files are
encrypted, and only followers you give the passphrase to can read anything. Your
identity, channels, and subscriptions persist automatically, and **Lock Identity**
seals that saved state with a passphrase.

## Two-machine demos and the DHT

Quickshare and Channels are peer to peer, so they are best tried on **two different
computers** (ideally on different networks). A few things to expect:

- **Give the DHT a few seconds** to find peers before the first transfer. A brand
  new session has to bootstrap into the swarm.
- **One session per process.** TorrentXT allows one live session at a time, so run
  one demo per OXT instance. For a two-party test, use two machines rather than two
  windows on one.
- Transfers move on TorrentXT's own threads, so the UI stays responsive even during
  a large transfer.

## Where your files go

- **Downloads** land in a folder the app chooses or lets you pick (the client lets
  you set it; quickshare and channels use a folder in your Documents). The app tells
  you the path.
- **Settings and identity** are saved to a small file under a `TorrentXT` folder in
  your per-user area (Preferences on Mac, AppData on Windows). This is what lets a
  packaged standalone remember its state across launches. In the channels demo you
  can encrypt that file with **Lock Identity**; there is no recovery if you lose that
  passphrase.

## Packaging a demo as a standalone (.exe / .app)

When you build a standalone, open `File > Standalone Application Settings`, go to the
Inclusions pane, and **manually include the TorrentXT extension** (and cryptoXT if
you use encryption). The native library is bundled into the app automatically, so you
do not ship loose `.dll` / `.so` / `.dylib` files. Because the demos persist their
state to the external prefs file described above, a standalone keeps its channels and
settings across launches even though it cannot save its own stack.

## torrent-helpers.livecodescript (a building block, not a demo)

This one does not have a UI. It is a small poll dispatcher for your OWN apps: rather
than write a poll loop, you `start using stack "torrentHelpers"` (or set it as a
behavior) and then handle plain messages as TorrentXT events arrive. It drains the
engine's event buffer on a timer with one FFI call and `send`s one semantic message
per event, which keeps the "never call script from an engine thread" rule while
letting you write normal event handlers. The four demos above already include their
own poll loops, so you do not need this to run them; reach for it when you are
building something new.

## Troubleshooting

- **"handler not found" / nothing happens on open:** the TorrentXT extension is not
  installed or not loaded. Check `Tools > Extension Manager`.
- **The private-channel / passphrase features are greyed out or say "install
  cryptoXT":** install `org.openxtalk.library.sodium`. Everything else still works
  without it.
- **No peers / no transfer:** give the DHT a few seconds, confirm the other side is
  running and reachable, and remember both peers need to be online at the same time.
- **The UI did not build after pasting:** you need to reopen the stack (or
  `send "openStack" to this stack`) so `openStack` runs.
