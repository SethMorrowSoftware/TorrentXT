# SodiumXT (starter seed)

A starting point for **SodiumXT**, a [libsodium](https://libsodium.org) binding for
OpenXTalk (OXT) / the xTalk family. It brings modern cryptography (authenticated encryption,
Argon2id password hashing, a streaming AEAD for large files, X25519 boxes, ed25519
signatures, BLAKE2b hashing, a real CSPRNG) to xTalk, behind a flat C ABI with an LCB layer
on top, the same shape as its sibling extension TorrentXT.

This seed contains only the guiding documents. There is no source yet, that is the work.

## What is here

- **`CLAUDE.md`** - the operational guidance and the hard-won-lesson list. Most of the FFI
  and OXT/LCB lessons were paid for while building TorrentXT and are carried over so they are
  not relearned. Read it.
- **`docs/SodiumXT-IMPLEMENTATION-PLAN.md`** - the full spec: the engine decision, the C ABI
  design, the capability surface, the phased plan, the test strategy, and the risk register.
  Read it first.

## How to start

1. Copy this folder into a fresh repo.
2. Read `docs/SodiumXT-IMPLEMENTATION-PLAN.md`, then `CLAUDE.md`.
3. Port `tools/check-livecodescript.py` and `tools/package-extension.py` from TorrentXT.
4. Build **Phase 0** only (CMake + pinned libsodium + CI matrix + `sxVersion` +
   `sxRandomBytes`), and prove a `Data` round-trips script -> Pointer -> C -> script intact
   under ASan. Everything else is downstream of that working.

## Why it exists

TorrentXT's optional encryption uses OXT's stock `encrypt ... using "aes-256-cbc" with
password`. That has a weak key derivation (OpenSSL's old `EVP_BytesToKey`) and no
cipher-level authentication. SodiumXT is the proper fix and a reusable building block: any
xTalk app, TorrentXT included, can drop its hand-rolled crypto and call `sx*` instead.

House style: no em-dashes; comment the *why*, densely.
