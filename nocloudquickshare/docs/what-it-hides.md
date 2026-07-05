# What No Cloud Quick Share hides — and what it doesn't

This is the honest page. No Cloud Quick Share sends files straight from your
computer to someone else's, with no server in the middle. That is the whole
point — but "no cloud" is not the same as "anonymous," and it is not the same as
"encrypted." Those are three separate things, and which ones you get depends
entirely on **which of the three ways to share you pick**.

Read this before you send anything you would not want a stranger, your internet
provider, or a person watching the network to see. Nothing here is marketing.
Where a protection does not apply, it says so plainly.

## The one thing to understand first

Two questions decide everything:

1. **Can someone see your IP address?** Your IP is roughly "which house on the
   internet you are." On the two direct paths (Share code and Web link), the
   other side connects to your machine, so **your IP is visible to them** — that
   is not a bug, it is how a direct connection works. Only the Tor path hides it.
2. **Can someone read the file's contents?** That is what *encryption* covers.
   Encryption is a separate switch. Turning it on scrambles the bytes; it does
   **not** hide your IP, and it does not hide *that* you are sharing.

A path can hide your IP but not encrypt, encrypt but not hide your IP, both, or
neither. Don't assume — check the table.

## At a glance

| Path | Your IP hidden? | Encrypted? | Recipient needs the app? |
|------|-----------------|------------|--------------------------|
| **Share code** (BitTorrent / DHT) | **No** — visible to every peer in the swarm | **Optional** — only if you set a passphrase (end-to-end) | **Yes** |
| **Web link** (plain web) | **No** — visible to the browser, and your public IP is published | **No** — a browser cannot decrypt | **No** — any browser |
| **Private / Tor** | **Yes** — both your IP and theirs are hidden | **Optional** — a passphrase adds encryption *and* authentication | Single file: **yes**; folder or Tor-Browser link: **no** |

In every case *you* are running the app to send — the "Needs the app?" column is
about the person **receiving**.

## Share code (BitTorrent over the DHT)

You drop a file and get a ~40-character code. That code **is** the file's
content address — its info-hash. It does two jobs at once: it names the exact
file, and it lets BitTorrent's distributed hash table (the DHT) introduce your
machine to whoever pastes the code. There is no tracker and no server, but there
is a **swarm**: the peers who join to fetch the file. **Your IP address is
visible to every one of those peers** — that is unavoidable on BitTorrent,
because they have to connect to you to receive the bytes. Anyone who has the
code can join the swarm, so treat the code as the key to the file and send it
only to the person you mean to.

Without a passphrase, the file — **and its real filename** — travel in the
clear; anyone in the swarm can read both. If you type a **passphrase** before
dropping the file, encryption is real and end-to-end: cryptoXT (libsodium)
derives a key from your passphrase with Argon2id and seals the file with
`crypto_secretstream`. The swarm then only ever sees the **ciphertext, under a
neutral `.enc` name** — the true filename and the key-derivation salt ride
*inside* the (now longer) code, and the passphrase, which you send your friend
separately, is what actually unlocks the bytes. A wrong passphrase is caught up
front against a small authenticator carried in the code, so a bad guess never
even downloads the useless `.enc`. What encryption here does **not** do: hide
your IP, or hide the fact that a file of that size is being shared.

## Web link (the plain, open web)

You get an ordinary `http://…` link that opens in **any browser, with no app on
the other end** — the easy path when your recipient can't install anything. That
convenience is exactly why it protects the least. **Your IP is visible**: the
browser connects straight to your machine, and to make the link reachable from
outside your house the app asks your router to open a port automatically
(UPnP / NAT-PMP) and looks up your **public IP** to build the link. (If the
router won't cooperate, the local-network link still works.) **Nothing on this
path is encrypted** — a plain browser has no key and cannot decrypt, so the file
and its name cross in the clear. The one protection is a **capability token**: a
128-bit unguessable random string baked into the link. It means an open port is
not an open directory — a port-scanner who finds your port still can't list or
grab the file without the exact token. But the token lives in the URL itself, so
anyone you send the link to (or anyone who sees it over your shoulder, in a chat
log, or in a browser history) can use it. Use the web link for things that are
fine to hand to a stranger; use Tor for anything private.

## Private / Tor (the anonymous path)

This is the only path that hides **both** IP addresses — yours *and* the
recipient's. The file's bytes travel over an OnionXT onion stream through the Tor
network, so neither side ever learns the other's real address, and **no torrent
is created** — nothing is published to the DHT, and there is no swarm to join. A
single file uses the app's own onion protocol, so **the recipient also needs No
Cloud Quick Share**. (Two exceptions serve a plain browser instead: dropping a
**folder** serves it as a browsable page, and the optional "Tor Browser download
link" offers a single file — both open in **Tor Browser with no app**, both
still hide both IPs, but because a browser can't decrypt, both are **unencrypted
and the sender is not verified**.)

For a single file, adding a **passphrase** layers on cryptoXT encryption *and*
authentication: the bytes are sealed, and a wrong passphrase is rejected up
front rather than handing over a file that can't be opened. Without a passphrase
the single-file Tor transfer still hides both IPs, but the content is not
encrypted at the application layer beyond Tor's own transport and is not tied to
a secret only your recipient knows. This path needs the OnionXT extension and a
**local Tor daemon** (start Tor or Tor Browser on your machine — the app finds
it on control port 9051 or 9151); the passphrase features additionally need
cryptoXT. When those pieces are missing the path simply isn't offered, and the
other two paths keep working.

## What is never hidden

- **On the Share code and Web link paths, your IP address is visible.** No
  setting changes that; it is how a direct peer-to-peer connection works. If
  hiding your IP matters, use the Tor path.
- **Encryption protects file contents, not who you are.** Even with a passphrase,
  the fact that you are sharing, roughly how big the file is, and (on the direct
  paths) your IP, are all still observable. Encryption on the locked Share code
  path *does* also hide the filename (it rides encrypted inside the code); on the
  web path nothing is encrypted at all.
- **A code or link is a key.** Anyone who has it can act on it. The DHT code lets
  anyone join the swarm; the web token lets anyone open the link. Guard them, and
  send a passphrase — when you use one — through a *different* channel than the
  code.
- **The sender keeps the connection alive.** On the direct paths the file lives
  only on your machine; if you close the window before the transfer finishes, the
  other side stops. This is a privacy feature (nothing is parked on a server) and
  an operational limit (there is no "upload and walk away").

## Quick guidance

- **Casual file, don't care who sees the traffic:** Web link. Fastest, works with
  a bare browser.
- **Real file, but the recipient runs the app:** Share code **with a passphrase**
  — end-to-end encrypted, though your IP is still visible to the swarm.
- **Sensitive, and you don't want your IP known:** Private / Tor, with a
  passphrase for a single file. Slower, needs Tor running, but it is the only
  path that hides both IPs.