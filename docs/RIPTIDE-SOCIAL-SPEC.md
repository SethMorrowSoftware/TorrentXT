# Riptide Social — a serverless social app on the five-extension xTalk stack

> A capstone concept spec: one app, composed entirely from installed OXT
> extensions, that has a public feed, private DMs, live calls, same-LAN device
> sync, and an optional fully-anonymous persona — **with no server, no account,
> no hosting bill, and no company in the middle.** Your identity is an ed25519
> key you hold; following someone is knowing their key; reaching them is
> verifying them.
>
> **Honesty scope.** This is **demo-script-level design work only** — it adds
> **zero** changes to any compiled extension. Everything here composes the
> *existing* public surfaces of SodiumXT (`sx*`), TorrentXT (`bt*`), OnionXT
> (`ox*`/`oxh*`), dataChannelXT (`dc*`), and enetxt (`en*`). Every handler,
> salt, and byte budget cited below is grounded in those repos' current
> sources and api-references (see §11 for the provenance table). Nothing here
> has run as an app yet: the convention is the family's — **"verified
> statically; needs an OXT pass."** Never claim a runtime behaviour this
> document has not measured.

---

## 1. Scope & decision

Build **Riptide Social** as a single OXT stack (or a small stack set) that
`start using`s five installed extensions and wires them together in script.
The decision this spec commits to is the **identity-first** architecture: one
Argon2id-protected master seed deterministically derives *every* key the app
uses, so the same unlock reconstructs your feed-signing key, your onion
address, your DM keys, and your LAN device key — and the public half of the
one identity key **is** your handle.

The five extensions are not interchangeable; each owns a corner of the problem
that the others cannot serve honestly:

| Extension | Corner it owns | Why not another |
|---|---|---|
| **SodiumXT** `sx*` | Identity, signing, sealing, stream crypto, KDF, Argon2id | The trust root; no transport does crypto |
| **TorrentXT** `bt*` | Public rendezvous (BEP44 signed DHT), bulk media, serverless DM transport (rp1) | Onion can't carry a UDP DHT; enet/dc aren't many-to-many |
| **OnionXT** `ox*` | IP-metadata privacy, self-authenticating `.onion` addresses, HTTP-over-onion | Tor is the only member that hides the network path |
| **dataChannelXT** `dc*` | Live 1:1 across NATs, browser-interoperable, per-channel reliability | Torrent latency is seconds; enet needs a reachable IP |
| **enetxt** `en*` | Same-venue realtime at game cadence (your own devices on a LAN) | dc's ICE handshake is overkill on a LAN; torrent/onion too slow |

The unifying idea: **transports are chosen by reachability and metadata cost,
identity is chosen once.** §2 fixes the rules; §3 builds the identity
foundation; §4–§8 are the five rails; §9 is the security/honesty model; the
rest is roadmap, provenance, and open decisions.

---

## 2. Ground rules carried from the family

1. **The single-thread playbook.** OXT runs script, every FFI, and rendering on
   one interpreted thread. One FFI round-trip per poll; reuse persistent
   buffers in hot paths; one clock read per pass; UI text at ≤4 Hz and only on
   change. Each extension is drained by its own poll (`btPoll`/`btRp1Poll`,
   `dcPoll`, `enPoll`, and OnionXT's stream/peer callbacks) — Riptide runs **one
   dispatcher** that services all of them per tick (§8).
2. **OXT compiler footguns.** ASCII quotes only; `k`/`p`/`s`/`t` prefixes;
   constants literal and declared before first use; all `local`s at the top of
   a handler; `unsafe … end unsafe` around foreign calls in any `.lcb` helper.
   The static gate `tools/check-livecodescript.py` runs on every script edit.
3. **Fail-closed capability probes.** Every optional dependency is probed
   **once** at startup into a script-local boolean, mirroring the existing
   `sCanEncrypt` pattern in the torrent demos. A missing extension disables
   exactly its feature with a clear "install org.openxtalk.library.X" message
   and **never regresses another feature** (§3.4).
4. **The honesty convention.** Anything not observed on a real engine is
   "verified statically; needs an OXT pass." Anonymity claims get the stricter
   label "needs an OXT + live-Tor pass."
5. **One wire format per rail, versioned by a magic.** Each rail below fixes a
   4-byte magic and a framing; a golden test pins the bytes (§10.2). Bump the
   magic (and both ends) on any framing change — never "fix" it silently later.

---

## 3. The identity foundation — one seed, the whole keyring

### 3.1 The master seed and the unlock

Riptide's root secret is a **32-byte master seed**, generated once with
`sxRandomBytes(32)` and stored **sealed at rest**: a passphrase runs through
`sxPwHash` (Argon2id, `sxPwMemInteractive()` opslimit `"2"` — the family's
KDF parameters, identical to the QuickShare/Channels prefs files) to derive a
wrapping key, and the seed is stored as `sxSecretBox(masterSeed, wrapKey)` with
its 16-byte salt beside it. Unlock = read salt, re-derive wrap key, `sxSecretBoxOpen`.
Wrong passphrase fails the Poly1305 tag — it does not silently mis-decrypt.
This is exactly the sealed-prefs convention already shipping (`kPrefMagic`
`"BTXPREF1"`); Riptide reuses it verbatim with its own magic `"RIPTKEY1"`.

### 3.2 The KDF subkey tree

Every other key derives from the master with **`sxKdfDerive(master, subkeyId,
context, subkeyLen)`** (libsodium BLAKE2b KDF). The context is the 8-byte
ASCII string `"riptide\0"` throughout; subkeys are numbered by role. This is
the whole tree:

| Subkey | Role | Consumer | Output |
|---|---|---|---|
| `1` | **Public identity** ed25519 seed (32 B) | `btDhtKeypair` **and** `oxCreateServiceFromSeed` | your handle + feed key + public `.onion` |
| `2` | **DM key-exchange** X25519 seed (32 B) | `sxKeyExchangeKeypairFromSeed` | pairwise DM session keys |
| `3` | **LAN device** pre-shared key (32 B) | enet join auth (§7) | admits only your own devices |
| `100 + n` | **Anonymous persona** *n* ed25519 seed (32 B) | `oxCreateServiceFromSeed` only | an onion-only, unlinkable identity (§8) |

The load-bearing subtlety that makes the whole app cohere is in subkey `1`.

### 3.3 Why "reaching you is verifying you" is literally true

A v3 onion address **is** an ed25519 public key in base32 (OnionXT's
`oxAddressFromPublicKey` / `oxPublicKeyFromAddress` are a pure, offline
bijection). A BEP44 mutable DHT item is signed by an ed25519 key, and
`btDhtKeypair(seed)` derives that key **deterministically** from a 32-byte
seed. Both derivations are standard ed25519 over the same seed — OnionXT builds
its service key from the seed via SodiumXT's `sxSignSeedToExpandedKey`, which
preserves the public point.

Therefore, if the **same** subkey-`1` seed feeds both:

```
handlePub  = btDhtKeypair(idSeed)["publicKey"]         -- 64-hex ed25519 public key
onionAddr  = oxAddressFromPublicKey(hexToBytes(handlePub))   -- <56-char>.onion
```

…then `onionAddr` and `handlePub` are the **same identity**. A follower who
knows your handle (the 64-hex key) can compute your `.onion` with a local,
CA-free function and, on connecting, Tor cryptographically proves the far end
holds that key. No certificate, no directory, no key-exchange step a
man-in-the-middle can hijack. **Your public feed and your private inbox are
provably the same person, and anyone can check it with arithmetic.**

The DM secret key **never crosses an FFI into libtorrent**: feed items are
signed with `btDhtBep44SignBuf` + `sxSignDetached` + `btDhtPutSigned` (the
external-signing path — §4.2), so the identity key lives only in the SodiumXT/
KDF layer.

### 3.4 The five-way capability matrix

Probe each extension once at startup, each into its own script-local, each in a
`try`:

| Local | True when | Probe | If false |
|---|---|---|---|
| `sCanCrypto` | SodiumXT present | `sxVersion()` non-empty | **Hard requirement** — Riptide cannot run without its trust root; show installer and stop |
| `sHasTorrent` | TorrentXT present | `btStartSession` returns > 0 | No public feed, media, or rp1 DMs; anon-only mode still works |
| `sHasOnion` | OnionXT present | `oxVersion()` non-empty | No anon persona, no onion mirror; public app fully works |
| `sHasDataChannel` | dataChannelXT present | `dcLibraryVersion()` non-empty | Live calls fall back to rp1 text DMs |
| `sHasEnet` | enetxt present | `enLibraryVersion()` non-empty | LAN device sync disabled; cloud/manual sync only |

`sTorReady` is a **separate, live** boolean (Tor bootstrap is not a one-shot):
the OnionXT status callback writes it, and any dial/publish re-checks
`oxIsReady()` at the moment of use (the Model C two-stage probe). SodiumXT is
the only hard dependency because it is the trust root **and** OnionXT itself
requires SodiumXT ABI ≥ 6.

---

## 4. Rail 1 — the public feed (TorrentXT BEP44 + bulk)

Your feed is a **signed, mutable pointer** in the DHT that names an
**immutable, content-addressed** post history, with media carried as torrents
your followers co-seed. Nothing is hosted.

### 4.1 The head — one signed 1000-byte record

BEP44 mutable values are capped at **1..1000 bytes**, so the head is a
*pointer*, never the content. Publish it under your identity key at a fixed
salt `"riptide-head"`:

```
RSH1 | seq | displayNameLen + displayName | latestPostTarget(40-hex)
     | prekeyTarget(40-hex) | onionAddr(optional) | profileMetaTarget(40-hex)
```

`latestPostTarget` is the 40-hex DHT target of your newest post record;
`prekeyTarget` names your published X25519 prekey bundle (§6.1);
`profileMetaTarget` names an immutable blob with your avatar info-hash and bio.
The whole record stays under 1000 bytes because every field is a hash or a
short string. Followers read it with `btDhtGetMutable(session, yourPubKey,
"riptide-head")` and get back `value` + `seq` + `signature` + `authoritative`.

### 4.2 Signing without leaking the key

Sign the head in the crypto layer, not in libtorrent:

```
buf = btDhtBep44SignBuf("riptide-head", seq, bencodedValue)   -- exact BEP44 canonical bytes
sig = sxSignDetached(buf, identitySecretKey)                  -- ed25519, key stays in sodium
btDhtPutSigned session, handlePub, "riptide-head", seq, bencodedValue, sig
```

The native layer **verifies** `sig` against `handlePub` before storing (a bad
signature returns `-3` locally instead of vanishing on the network), and the
identity secret never crosses into libtorrent. `seq` is a monotonic counter
persisted next to the master seed; re-putting publishes a new version and every
follower's next poll sees it.

### 4.3 Posts — a tamper-evident hash chain

Each post is an **immutable** DHT item (`btDhtPutImmutable`, 1..1000 bytes,
returns its 40-hex target) — or, when the text exceeds 1000 bytes, a small run
of immutable chunks named by a chunk-list record, exactly the reassembly
pattern the DHT-chat demo already ships (`DXC1`: a head that is either direct
or a list of chunk targets). Each post record carries:

```
RSP1 | timestamp | prevPostTarget(40-hex) | textTarget | mediaInfoHashes[] | authorSig
```

`prevPostTarget` chains each post to the one before it, so the feed is a
**tamper-evident linked list**: a follower walks back from `latestPostTarget`,
and any altered post breaks the chain and its `authorSig`. `authorSig` is
`sxSignDetached` over the record so individual posts are verifiable even out of
DHT context (e.g. when relayed).

### 4.4 Media — followers are the CDN

Attach a photo or video by building a torrent for it and putting its info-hash
in the post's `mediaInfoHashes`:

```
tTorrent = btCreateTorrent(mediaPath, 0, 0, "")   -- 0 = auto piece size, "" = trackerless/DHT-only
-- you seed it (btAddTorrentFile), followers btAddTorrentFile/btAddMagnet to fetch,
-- then keep seeding: organic, self-scaling distribution with no origin server.
```

A viral post's media gets *faster* as more followers co-seed it — the opposite
of a hosted CDN's cost curve. Large media can seed **sequentially with piece
deadlines** (`btSetSequentialDownload` / `btSetPieceDeadline`) so a video
starts playing before it finishes. Optionally seal media at rest for
followers-only feeds with `sxEncryptFile` (streaming, authenticated) and carry
the per-file key in the post record — the Channels demo's exact
encrypted-release pattern (the swarm only ever sees the `.enc`).

---

## 5. Rail 2 — DMs (TorrentXT rp1 + SodiumXT secretstream)

Direct messages ride **rp1**, TorrentXT's custom BEP10 peer-wire extension that
moves opaque bytes between two peers who meet in a **phantom swarm** — no
tracker, no server, no content. SodiumXT's `sxSecretStream` layers
authenticated encryption on top, exactly the layering the rp1-chat demo header
describes ("Riptide layers its crypto — SodiumXT `sxSecretStream` — on top of
this same `btRp1Send`/`rp1Message` channel").

### 5.1 First contact — the inbox rendezvous

Anyone can reach you at a **deterministic inbox swarm** derived from your public
key, which you also advertise in your feed head:

```
inboxId = sxBin2Hex(sxHash(handlePubBytes & "riptide-inbox", 20))   -- 40-hex phantom-swarm id
```

You `btAddInfohash(session, inboxId, "inbox")` and `btDhtAnnounce` at it; a
sender joins the same swarm, the DHT introduces the peers, and rp1 handshakes.
The first message is **sealed to your key** with `sxSeal(intro, handlePubBytes)`
(anonymous-sender sealed box) carrying the sender's own handle + an ephemeral
X25519 public and a signed challenge — so you learn who it is, they prove it
with `sxSignDetached`, and no eavesdropper on the swarm learns the contents.

### 5.2 The pairwise session

Once both sides know each other's identity and X25519 prekeys (from each
other's feed `prekeyTarget`), they derive a **shared session** with
`sxKeyExchangeClient` / `sxKeyExchangeServer` (returns distinct rx/tx keys),
then move to a **pairwise room** so first-contact traffic never mixes with an
ongoing conversation:

```
roomId = sxBin2Hex(sxHash(sortedConcat(pkA, pkB) & sessionSalt, 20))
```

Each direction runs a `sxSecretStream`: `sxSecretStreamInitPush(txKey)` yields a
header sent as the first rp1 message; every subsequent message is
`sxSecretStreamPush(handle, plaintext, "", false)` and delivered by a single
`btRp1Send` (payloads cap at 60000 bytes — a DM is far smaller). The receiver
runs `sxSecretStreamInitPull(rxKey, header)` then `sxSecretStreamPull` per
message, checking `sxIsFinalTag` for session close. `btRp1SetToken` publishes a
signed recognition token in the extended handshake so a reconnecting peer is
re-authenticated before the first `rp1Message`. Latency is rp1's ≤1 s
per-peer tick — fine for text, and the trigger to escalate to Rail 3 when the
conversation wants to be live.

---

## 6. Rail 3 — live 1:1 sessions (dataChannelXT)

When a DM becomes a call, a live-typing session, or a fast file drop, escalate
to a **WebRTC data channel** — real NAT traversal (ICE), browser-interoperable,
with per-channel reliability knobs.

### 6.1 Signalling over the rail you already have

The DHT-chat demo signals SDP through a **DHT dead-drop** (offer/answer under
salts `"wx-o"`/`"wx-a"`, compressed and chunked because an SDP with candidates
exceeds the 1000-byte BEP44 cap). Riptide keeps that as the **cold-start**
path, but when a secretstream DM (Rail 2) is already open it has something the
demo lacks: **a live authenticated channel.** So the SDP offer/answer travel as
ordinary secretstream messages over rp1 — no DHT round-trip, no dead-drop
latency, and the signalling inherits the DM's authentication for free. Prekey
exchange already happened, so there is no unauthenticated-SDP window.

### 6.2 The session

```
peer  = dcCreatePeer("stun:stun.l.google.com:19302")   -- the demo's default ICE server
dcSetLocalDescription peer, "offer"                     -- gather; dcLocalDescription -> send over rp1
-- remote SDP arrives over rp1 -> dcSetRemoteDescription peer, sdp, "answer"
chat  = dcCreateChannel(peer, "riptide/live")
```

Use `dcCreateChannelEx` to pick the reliability that fits the sub-stream:
ordered-reliable for a shared document, **unordered + `maxRetransmits 0`** for
cursor/typing presence you overwrite constantly, a separate channel for a file
drop with `dcBufferedAmount` + `dcSetBufferedLowThreshold` backpressure so a
large transfer never starves the interactive channel. `dcPoll` drains state and
inbound messages in the shared dispatcher. When the live session ends, the
conversation falls back to the persistent rp1 DM.

---

## 7. Rail 4 — same-LAN device sync (enetxt)

Your own devices — phone, laptop, studio machine — sync at **wire speed on a
LAN** without any of them touching the internet, using enet's reliable UDP.
This rail is **device-to-device within one identity**, never follower-facing.

One device hosts (`enHostCreateServer("", 27099, 8, 3, 0, 0)` — the demo's
port, a small peer cap, three channels); the others `enConnect` to it. Admission
is gated by the **subkey-3 LAN pre-shared key**: the `enConnect` data rider plus
a first-message challenge signed under a key both devices can only derive from
the shared master seed, so a stranger on the same café Wi-Fi cannot join your
device mesh. Channels split by traffic shape:

- **Channel 0, reliable** — keyring updates, new-post drafts, the monotonic feed
  `seq` (so two devices never publish a conflicting head), read receipts.
- **Channel 1, unreliable-sequenced** — presence and "typing on my phone"
  indicators you overwrite every tick; drops are harmless.
- **Channel 2, reliable** — bulk local handoff (a draft's media) below the
  60000-byte packet budget; larger goes to a torrent even on the LAN.

`enPeerStatus` gives RTT and loss for a live "your devices" panel. This is the
one rail where sub-frame latency actually matters and where dc's ICE handshake
would be pure overhead — the devices already share a network and a secret.

---

## 8. Rail 5 — the anonymous persona (OnionXT, Model C)

An anonymous persona is a **separate ed25519 identity** (a subkey-`100+n` seed)
that lives **only** as an onion service and **never touches the DHT, a torrent,
or rp1.** This is the Model C invariant, applied to a social identity.

### 8.1 Why it must be onion-only

The BitTorrent DHT is **UDP** and rp1 is a **clearnet peer-wire** connection —
neither can ride a Tor circuit, which carries TCP streams. If an "anonymous"
persona published a BEP44 head or announced a swarm, it would emit its IP to
every DHT node and peer it touched, and — worse — its published ed25519 key
would let anyone compute the link between its onion and its DHT presence. So the
anon persona calls **none** of `btDhtPutMutable` / `btDhtGetMutable` /
`btDhtPutImmutable` / `btAddMagnet` / `btAddTorrentFile` / `btCreateTorrent` /
`btDhtAnnounce` / `btRp1*`. Everything it does rides an OnionXT TCP stream. §9.3
owns the guard set that enforces this at every branch point; a violation is a
deanonymization bug, not a cosmetic one.

### 8.2 The anon feed — HTTP over an onion

The persona publishes its feed by **serving it over its own onion** with
onion-httpd:

```
oxCreateServiceFromSeed anonSeed, 80, localPort   -- the .onion IS the persona's pubkey
oxhServe 80, localPort
oxhServeFiles feedFolder                            -- static feed + media, browsable in Tor Browser
oxhRoute "POST", "/dm", "riptideAnonDm"            -- an inbound message route
```

Followers reach `oxServiceAddress(service)` — a `<56-char>.onion` shared
out-of-band as a contact card or QR (never posted to the DHT). Browsing it
proves they reached the key-holder. Media is served as ordinary files over the
same onion, not as torrents — slower and non-scaling, the honest cost of
anonymity.

### 8.3 Anon DMs — sealed over a Tor stream

A follower sends the persona a DM by dialing its onion and posting to `/dm`; the
body is `sxSeal(message, anonPub)` so even a malicious `oxhRoute` handler cannot
attribute the sender, and the persona replies over the same accepted stream
(`oxSetPeerCallback` / `oxPeerAccepted`). File transfers use the Model C `BTXO`
framed-chunk protocol (HEADER + length-prefixed DATA frames + zero-length
terminator) over the stream. No swarm, no IP, on either side.

### 8.4 One unlock, two unlinkable identities

Both the public and anon identities derive from the **same master seed**, so a
single Argon2id unlock reconstructs your whole keyring — but their public keys
are **distinct KDF subkeys**, and the anon key's public half **never appears in
any public record.** To an outside observer the two are cryptographically
unlinkable. The honest caveats (§9) are real and must be surfaced in the UI:
cross-posting content, correlated timing, or a global passive adversary doing
traffic analysis can still link them. The tool removes the *easy* links; it
cannot remove the operator's mistakes or defeat a global observer.

---

## 9. Security model & honesty

### 9.1 What each layer buys

| Layer | Provides | Does **not** provide |
|---|---|---|
| SodiumXT | Confidentiality, integrity, authenticity; wrong key/tamper is *rejected* | Metadata privacy; forward secrecy beyond secretstream rekey |
| BEP44 signing | Authenticated, sequence-ordered feed; tamper-evident post chain | Confidentiality (public feeds are public); deletion (DHT is append-until-expiry) |
| rp1 phantom swarm | Serverless peer rendezvous and transport | IP privacy — both peers learn each other's address |
| dataChannel | NAT-traversed P2P, DTLS-encrypted transport | Hiding IPs (ICE reveals them); anonymity |
| enet LAN | Device-mesh speed and simplicity | Anything off the LAN; internet reachability |
| OnionXT | IP-metadata privacy; CA-free self-authenticating address | Defence against a global passive adversary or a compromised local tor |

### 9.2 Tor hides the route, SodiumXT hides the contents

The two compose without overlap: OnionXT ensures the **network** never learns
who talks to whom; SodiumXT ensures the **contents** are unreadable and
unforgeable even to a malicious relay or onion route handler. Neither is a
substitute for the other — an onion stream still seals its payload; a sealed
DM over rp1 still leaks both IPs.

### 9.3 The deanonymization guard

The single rule that keeps the "anonymous" label honest: **an anon-persona code
path calls no `bt*` DHT/torrent/rp1 handler, and a public-persona path never
routes through the anon onion.** Enforce it with a persona-scoped dispatcher —
the active persona's descriptor carries a boolean `isAnon`, and the transport
selectors assert on it at every send/publish branch, failing closed (refuse +
visible message) rather than silently falling back to a clearnet path. This
mirrors the Model C §7 guard set and is the highest-severity invariant in the
app.

### 9.4 The trust boundary and the honest limits

- **The local tor daemon is trusted.** OnionXT assumes a tor reachable on the
  loopback SOCKS/control ports; a compromised local daemon defeats the anonymity
  regardless of the crypto. Bundling/launching tor is the optional OnionXT
  lifecycle layer, never a requirement.
- **A global passive adversary** doing traffic correlation across Tor is out of
  scope — as it is for Tor itself.
- **Every anonymity claim in the UI** must read "needs an OXT + live-Tor pass"
  until measured on a real engine against a real daemon.

---

## 10. Event loop, testing, and roadmap

### 10.1 One dispatcher, never block

A single `on riptideTick` fires on a timer and, in order, drains: `btPoll` +
`btRp1Poll` (session events, feed puts, DM messages), `dcPoll` (live-session
state/data), `enPoll` (LAN mesh), and lets OnionXT's stream/peer callbacks run.
It hoists one `the milliseconds` read, repaints UI at ≤4 Hz on change, and
**never blocks** — every transport is async, every long operation is a state
machine advanced one tick at a time (the DHT-chat and Model C demos are the
templates). Tick cadence is the app's one latency/CPU knob: ~33 ms while a live
dc/enet session is active, ~250 ms–1 s when only the feed and DMs are live.

### 10.2 What is testable without an engine

- **Static gate** on every script edit (`check-livecodescript.py`).
- **Pure-compute golden vectors**, runnable anywhere, for the parts that must
  match byte-for-byte across versions and peers: the KDF subkey tree (fixed
  master → fixed subkeys), the `RSH1`/`RSP1` head/post framing, the `inboxId`/
  `roomId` derivations, the identity→onion mapping
  (`oxAddressFromPublicKey(btDhtKeypair(seed).publicKey)` == the seed's onion),
  and the `BTXO` anon-file framing. Pin them the way `onion-kat.py` and
  `record_golden_test.py` pin their formats.
- **On-engine VERIFY register** for everything else: the numbers a real engine
  and a real daemon must confirm (feed propagation latency, rp1 handshake time,
  dc connect success behind two NATs, enet LAN RTT, onion publish + inbound).

### 10.3 Phased roadmap (each phase ends on an OXT pass)

1. **Identity + unlock** — master seed, Argon2id seal, KDF tree, the five-way
   probe, the identity→onion golden. *Done when* two runs from the same
   passphrase reconstruct the same handle and `.onion`.
2. **Public feed read/write** — head sign/put/get, post chain, one follower sees
   another's post. *Done when* a second machine walks the chain and verifies
   every `authorSig`.
3. **Media** — create/seed/co-seed a photo and a sequential video. *Done when* a
   follower plays a video mid-download.
4. **DMs** — inbox rendezvous, sealed intro, pairwise secretstream over rp1.
   *Done when* two machines exchange authenticated encrypted DMs with no server.
5. **Live sessions** — rp1-signalled dc call + typing presence, DHT-dead-drop
   cold start. *Done when* a call connects across two networks.
6. **LAN sync** — enet device mesh with subkey-3 admission. *Done when* a draft
   written on one device appears on another with a stranger refused.
7. **Anon persona** — onion feed via onion-httpd, sealed anon DMs, the §9.3
   guard. *Done when* a persona is reachable and browsable over Tor with **zero**
   `bt*` calls provable in a trace. Needs an OXT + live-Tor pass.

---

## 11. API surface — what exists vs. what's assumed

**Zero compiled-extension changes.** Every handler this spec composes already
exists in a shipping surface. Provenance:

- **SodiumXT** `sxRandomBytes` `sxPwHash` `sxPwMemInteractive` `sxSecretBox`/`Open`
  `sxKdfDerive` `sxSignKeypairFromSeed` `sxSignDetached`/`sxSignVerifyDetached`
  `sxKeyExchangeKeypairFromSeed` `sxKeyExchangeClient`/`Server` `sxSeal`/`sxSealOpen`
  `sxSecretStreamInitPush`/`Push`/`InitPull`/`Pull`/`IsFinalTag`/`Rekey`
  `sxEncryptFile`/`Decrypt` `sxHash` `sxBin2Hex` `sxSignSeedToExpandedKey` — all in
  `sodiumxt/src/*.lcb` `public handler` surface.
- **TorrentXT** `btDhtKeypair` `btDhtPutMutable`/`GetMutable` `btDhtPutImmutable`/
  `GetImmutable` `btDhtBep44SignBuf` `btDhtPutSigned` `btDhtAnnounce` `btAddInfohash`
  `btRp1Enable`/`SetToken`/`Send`/`Poll` `btCreateTorrent` `btAddTorrentFile`/`Magnet`
  `btSetSequentialDownload` `btSetPieceDeadline` `btPoll` — all in `docs/api-reference.md`.
- **OnionXT** `oxVersion` `oxIsReady` `oxCreateServiceFromSeed` `oxServiceAddress`
  `oxAddressFromPublicKey`/`oxPublicKeyFromAddress`/`oxIsValidAddress` `oxDial`/`oxWrite`/
  `oxCloseStream` `oxSetPeerCallback`/`oxPeerAccepted` `oxSetStatusCallback`; onion-httpd
  `oxhServe`/`oxhServeFiles`/`oxhRoute`/`oxhReply`/`oxhSetRoot` — all in
  `onionxt/src/*.livecodescript`.
- **dataChannelXT** `dcCreatePeer` `dcSetLocalDescription`/`dcSetRemoteDescription`
  `dcLocalDescription` `dcCreateChannel`/`dcCreateChannelEx` `dcSendData`/`dcSendText`
  `dcBufferedAmount`/`dcSetBufferedLowThreshold` `dcPoll` — all in `datachannelxt/src/*.lcb`.
- **enetxt** `enHostCreateServer`/`Client` `enConnect` `enSendText`/`enBroadcastText`
  `enPeerStatus` `enPoll` `enLibraryVersion` `enDeinitialize` — all in `enetxt/src/enet.lcb`.

**Correction to the ONIONXT integration plan.** That plan (correctly, at its
writing) treats the `ox*` surface as "presumed, must be confirmed against the
real ABI." The real OnionXT repo is further along: phases 1–7 are built in pure
LiveCodeScript and have had an **on-engine pass against a live tor daemon**
(SOCKS dial, SAFECOOKIE control auth, v3 onion publish, an inbound HTTP request
viewed in Tor Browser, bootstrap). Every `ox*` name this spec uses is confirmed
present. Deltas from the plan's guesses: there is **no** `oxSendFile`/`oxWriteFile`
(files ride the `BTXO` framing over `oxWrite`); there **are** extra affordances
(`oxSetCallbackOwner`, `oxServiceIsReady`, the `oxTransport*` seam, the full
`oxh*` HTTP layer). The plan's VERIFY register for the `ox*` ABI can largely be
retired — though the *behavioural* numbers still need their own OXT + live-Tor
pass.

**No new compiled surface is proposed.** If a future version wants, say, feed
deletion or forward-secret group DMs, those are new specs — explicit non-goals
here.

---

## 12. Open decisions for the owner

1. **One stack or a stack set?** The five rails are separable; a single stack is
   simplest to install, a set (feed / messenger / anon) mirrors how people
   actually use the parts. Recommendation: one stack, rails behind tabs, so the
   shared dispatcher and keyring live in one script.
2. **Anon persona count.** Subkey `100+n` allows many; the UI/threat story is
   simpler with exactly one. Recommendation: ship one, keep the derivation
   ready for more.
3. **Prekey rotation.** One-time prekeys (X3DH-style) versus a single long-term
   X25519 prekey. Recommendation: long-term prekey for v1 (simpler, in the head),
   rotation as a later spec.
4. **Feed retention.** BEP44 items expire unless republished; how aggressively
   does a follower re-seed a followee's head to keep it alive? Recommendation: a
   follower republishes heads it follows on the DHT-channels demo's cadence.
5. **Which demo to build first.** This spec's phase 1–2 (identity + public feed)
   is the smallest end-to-end slice that shows the thesis. Recommendation: build
   through phase 4 (DMs) as the first shippable milestone; it exercises four of
   the five extensions and needs no tor daemon.
