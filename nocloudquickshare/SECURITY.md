# Security Policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in No Cloud Quick Share,
please report it privately so it can be fixed before it is disclosed publicly.

- **Contact:** security@ (maintainer to fill in)

Please include enough detail to reproduce the issue: what you did, what you
expected, and what actually happened. A minimal proof of concept is more useful
than a general description. Please do not open a public issue for a suspected
vulnerability until it has been addressed.

There is no bug-bounty program. This is a small, community-maintained demo; fixes
are made on a best-effort basis.

## Security model in brief

No Cloud Quick Share is a peer-to-peer file-sharing tool built on the BitTorrent
protocol (via the TorrentXT extension). The design goal is to move a file from one
person to another **without any central server, account, or cloud storage** holding
the file or the metadata.

- **Peer-to-peer, no server.** There is no No Cloud Quick Share backend. A share is a
  torrent (or a Tor onion service, or a direct web link) served from the sender's own
  machine to the receiver's own machine. Nothing is uploaded to a service the project
  operates. The share "code" is the information the receiver needs to locate the data
  in the swarm — it is not a link to a server we run.

- **Optional end-to-end encryption.** If the sender types a passphrase before sharing,
  the file is encrypted **end-to-end** on the sender's machine before it ever enters the
  swarm. Encryption is provided by the optional **cryptoXT** extension
  (`org.openxtalk.library.sodium`, libsodium):
  - The key is derived from the passphrase with **Argon2id** (a memory-hard KDF) over a
    fresh random 16-byte salt. The salt travels inside the share code, not the passphrase.
  - The file itself is sealed with libsodium's **`crypto_secretstream`** (authenticated,
    streaming encryption), so tampering with the ciphertext is detected on decryption.
  - Only the **ciphertext** — a blob under a neutral `.enc` name — is ever seeded to the
    swarm. The real filename rides inside the share code, not in the torrent.
  - The passphrase is communicated to the receiver **out of band** (a phone call, a
    different app). It is never placed in the share code and never sent over the wire.

- **Up-front passphrase verifier.** The share code carries a small authenticator: a
  fixed marker (`BTXQSVERIFY`) sealed under the derived key. Before downloading anything,
  the receiver derives the key from the passphrase they were given and checks it against
  this authenticator **locally**. A wrong passphrase is caught immediately, so a mistyped
  or incorrect passphrase never pulls a useless encrypted blob to disk. This is a
  convenience/failure-closed check; the real integrity guarantee is the authenticated
  `crypto_secretstream` on decryption.

- **Capability-token gate on web shares.** When a file or folder is served over a plain
  web link, every request must carry an unguessable random **capability token** (128
  bits) as the first path segment: `http://<ip>:<port>/<token>/...`. An open port is
  therefore not an open directory — a port scanner that finds the port but not the token
  sees nothing. The token is the access-control boundary for anonymous web recipients.

- **LAN-only, password-gated web editor.** No Cloud Quick Share can expose a small
  in-browser editor for a shared folder. Because that is a write path reachable from a
  browser, it is deliberately locked down:
  - **Off by default.** It must be explicitly enabled.
  - **Password protected.** The edit password is run through Argon2id (cryptoXT); a
    login is proven against a sealed verifier (`BTXEDIT1`), and a correct login mints a
    fresh random **session token** (192 bits) that invalidates any prior one. A wrong
    password returns 401 with no hint about what was wrong. Without cryptoXT the editor
    cannot be enabled at all — it fails closed.
  - **LAN-only, always.** Editor routes refuse any request that is not from the local
    network, and refuse **all** Tor requests, based on the TCP peer address the engine
    reports. A public clearweb peer or a Tor visitor receives a 404 and never learns the
    editor exists — even though the site itself remains publicly shareable.
  - **Path confinement (`qsEditSafePath`).** This is the editor's security linchpin.
    Every editor read and write resolves the browser-supplied relative path through
    `qsEditSafePath`, which refuses anything that could escape the served folder **before
    touching disk**: any `..` segment, any `:` (Windows drive / URL scheme), and any
    control byte (NUL / CR / LF / tab) are rejected, and the path is rebuilt from clean
    segments only. The result is always the served root followed by ordinary names. This
    guard is mirrored byte-for-byte by an adversarial golden test
    (`tests/fileserver_golden.py`, ~20 vectors); the two must change together. Note this
    is **lexical** confinement: if the sharer places a symlink inside the shared folder
    that points elsewhere, the OS will follow it on open. The editor never creates
    symlinks, so this is only reachable via a link the sharer put there deliberately —
    on a LAN-only, password-gated surface. Do not share a folder containing symlinks you
    would not want followed.

- **Dotfile hiding.** The static read paths (both folder listing and file serving, on
  both transports) treat any path with a dot-prefixed segment as **nonexistent** — a
  `404`, not a `403`, so hidden means "does not exist". This keeps a shared website
  folder from leaking `.git`, `.env`, editor droppings, and similar over an anonymous
  link — the classic static-host mistake. (The password-gated editor keeps its own rules
  and may legitimately touch dotfiles; the dotfile guard applies only to the anonymous
  read paths.)

- **Connection caps and watchdogs.** Concurrent web connections are bounded
  (32 at a time), and an HTTP request (headers plus body) larger than 256 KB is refused
  outright, so a malformed or abusive request cannot stall the single engine thread or
  exhaust memory. Idle connections on every transport (web and Tor) are reaped by
  watchdog timers, so a peer that opens a connection and goes silent does not tie up a
  slot indefinitely.

## Non-goals and known limits

These are deliberate boundaries of what No Cloud Quick Share protects. Read them before
relying on it for anything sensitive.

- **Your IP address is visible on non-Tor paths.** A plain BitTorrent swarm or a direct
  web link exposes your IP address to the people you share with (and, in a swarm, to
  other peers and trackers). If you need your network location hidden, use the Tor
  transport, which routes the transfer through an onion service so neither side's IP is
  revealed. Encryption hides the *contents* of a file; it does not hide *that* you are
  sharing or *where you are* on a non-Tor path.

- **No formal third-party audit.** This is a demonstration application. The security
  model described above has been reasoned about carefully and the path-confinement guard
  is golden-tested, but the code has **not** undergone a formal independent security
  audit. Treat it accordingly.

- **Encryption requires the optional cryptoXT extension.** End-to-end encryption, the
  passphrase verifier, and the editor password all depend on cryptoXT
  (`org.openxtalk.library.sodium`) being installed. If cryptoXT is absent, those features
  are unavailable and **fail closed**: a passphrase share cannot be created (the app tells
  you to install cryptoXT rather than sharing in the clear silently at that step), and the
  editor cannot be enabled. Unencrypted sharing over BitTorrent, Tor, and web links
  continues to work without cryptoXT, but it is exactly that — unencrypted. If you need
  confidentiality, install cryptoXT and set a passphrase.