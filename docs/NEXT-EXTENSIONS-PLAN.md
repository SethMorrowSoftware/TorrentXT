# Next OXT Native Extensions - Plan & Engine Playbook

**libsodium - ENet - libdatachannel/libjuice**

This is the implementation plan for the next three native libraries we intend to
bring to OpenXTalk (OXT) / the xTalk family, and - just as importantly - the
consolidated **engine playbook**: every gotcha and piece of weirdness we have
uncovered wrapping C/C++ libraries for OXT (across Box2Dxt, ShowControl, and
TorrentXT), written down so we never re-learn them.

> **Read Part I before starting ANY of the three.** It is the reusable "how to
> wrap a native library for OXT without getting bitten" reference. Parts II-IV are
> the per-library plans; Part V is sequencing, shared infrastructure, and risk.
>
> Companion to `docs/TorrentXT-IMPLEMENTATION-PLAN.md` (the original design brief)
> and `/CLAUDE.md` (the as-built record). Where those differ from the code, the
> code wins; where this plan is not yet built, it is marked as plan, not as-built.

---

## Why these three, and in this order

The coherent theme is **a secure, decentralized, real-time application stack for
xTalk** - capabilities no other xTalk environment has. TorrentXT is already one
leg of it:

| Layer | Library | Role | Status |
|---|---|---|---|
| Discovery + bulk transfer | **TorrentXT** (libtorrent) | DHT rendezvous + BitTorrent file movement | done (ABI v8) |
| Trust | **libsodium** | identity, signing, encryption, password hashing | planned - **do first** |
| Real-time (reliable UDP) | **ENet** | low-latency peer messaging (games, presence, collab) | planned - **second** |
| Real-time (WebRTC) | **libdatachannel** + **libjuice** | browser-interoperable P2P + real NAT traversal | planned - **third** |

They compose: libsodium secures the channels; ENet/libdatachannel carry live
messages; and libdatachannel's signaling can ride **TorrentXT's DHT (BEP44)** -
a server-less rendezvous closing the loop.

**Licenses (all permissive - confirm exact tag when starting):** libsodium ISC;
ENet MIT; libdatachannel and libjuice MPL-2.0. Avoid GPL cores (e.g. most of
FFmpeg) so the static-link-and-ship story stays clean - the same reason
libtorrent (BSD-3) was chosen over alternatives.

## The house pattern (recap)

Every wrap so far follows one shape, and these three will too:

```
  native library (C or C++)                       owns its own work
     |- C++/C shim   src/<lib>_shim.cpp  ->  <lib>.{so,dll,dylib}   (ABI: PFX_*)
          |- LCB binding  src/<lib>.lcb        (library org.openxtalk.library.<lib>)
               |- script helpers  examples/<lib>-helpers.livecodescript (poll dispatcher)
```

- A flat `extern "C"` shim exporting `PFX_*` symbols (a frozen, versioned ABI).
- Generation-tagged **handle tables** (stale handle = harmless no-op).
- The **exception firewall** (every entry point wrapped).
- For anything with inbound events, a **poll-drained event queue** (no callback
  ever runs script).
- A thin **LCB binding** of `private foreign handler` decls + public `Xx*`
  wrappers that hide handles, pre-size buffers, walk records, and never throw.
- The self-describing **typed KV record codec** for events and snapshots.

---

# PART I - The OXT / LiveCode Engine Playbook (read first)

Everything below is a mistake we have already made or a constraint we have
already paid for. Internalise it before writing a line of a new wrap.

## I.1 The three rules (universal - but the nuance differs per library)

1. **Never call an LCB / script handler from a foreign (library) thread.**
   Inbound activity must ride a queue that the script **poll-drains** on a timer;
   no callback ever runs script.
   - *libsodium*: no threads at all - trivially satisfied (and no poll needed).
   - *ENet*: no internal threads either - it is **pump-driven** (you call
     `enet_host_service`), so the rule is trivially satisfied, BUT nothing
     happens unless you pump, so the poll loop is mandatory.
   - *libdatachannel*: **has its own threads and fires callbacks from them.**
     This is the rule's worst case and the single most important design
     constraint of that binding (see Part IV).

2. **The exception firewall.** A throw crossing `extern "C"` takes the engine
   down. **Every** entry point is `try { ... } catch (...) { set_error(...);
   return <error>; }`. C libraries (sodium, enet) rarely throw, but our own
   allocations can `std::bad_alloc`, and libdatachannel is C++ - so the firewall
   is mandatory in all three, no exceptions.

3. **Payload across the FFI.** This rule is **domain-specific**, not universal.
   For TorrentXT it meant "gigabytes never cross" (only tiny status records do).
   For these three, *payload does cross by design* - it IS the data (a plaintext
   to encrypt, a game-state message, a chat line). The rule becomes: **keep what
   crosses small** (crypto buffers, control messages, KB-scale), and push bulk
   (files, media streams) back to TorrentXT or keep it engine-side. Document a
   size budget per binding.

## I.2 LiveCodeScript (`.livecodescript`) gotchas

- **ASCII only.** No smart/curly quotes (U+201C/201D/2018/2019) anywhere - not
  in code, strings, or comments. They fail OXT compilation. The static checker
  enforces zero. Straight `"` and `'` only; write arrows as `->`.
- **`repeat with x = 1 to n`** (NOT `from`). `repeat for each element X in aList`
  and `repeat for each line L in aText` are both available here (LiveCodeScript,
  unlike LCB - see I.3).
- **`itemDelimiter` / `lineDelimiter` are GLOBAL mutable state.** Set them
  *immediately* before each use; never assume their value. A handler that returns
  while they are set to something exotic will surprise the next handler.
- **`the round of X`** is the form this codebase uses (match it; do not switch to
  `round(X)` mid-file).
- **Commands report via `the result`; functions return a value.** Match the API
  shape: a command-style handler is `btAddMagnet s, uri, path` then
  `put the result into tH`; a function-style is `put btTorrentStatus(tH) into a`.
- `textEncode(str,"UTF-8")` -> Data; `textDecode(data,"UTF-8")` -> String.
- File IO idioms: `put X into url ("binfile:" & tPath)`; `there is a file tPath`
  / `there is no folder tDir`; `create folder tDir`.
- Custom properties for persistence: `set the uXxx of this stack to ...`.
- Self-building demo/test stacks are **idempotent**: guard the build with
  `if there is a field "x" then exit ...`, and wrap the build in
  `lock screen` / `unlock screen` to avoid flicker.

## I.3 LCB (LiveCode Builder, `.lcb`) gotchas - stricter than LiveCodeScript

- **`unsafe ... end unsafe` brackets EVERY foreign call.**
- **Keep ALL `variable`/`local` declarations at the TOP of a handler.** A nested
  declaration (a `variable` inside an `if`/`repeat`) has broken whole-script
  compilation. Declare everything up front.
- **No `repeat for each line` in LCB.** (Discovered building `btWebSeeds`.) Use a
  counted `repeat with i from 1 up to n`. For a bridged list value,
  `repeat for each element X in aList` works; for splitting text by line it does
  not - so the shim should hand back a **list of records** (the framing below)
  rather than newline-joined text the LCB side would have to split.
- **Constants must be LITERAL and declared BEFORE first use.** OXT resolves
  constants by lexical position; a forward reference silently evaluates to
  nothing. Put `constant k... is <literal>` near the top.
- **Foreign decl shape:**
  `private foreign handler _pfx_name(in p as CInt, ...) returns CInt binds to "c:<lib>>pfx_name!cdecl"`.
  Keep the stable `pfx_` prefix; **never rename an exported symbol** - the
  compiled `.lcb` references the string, so a rename breaks the bind at first use.
- **`<builtin>` handlers resolve by NAME** (`MCMemoryAllocate`,
  `MCMemoryDeallocate`, `MCDataGetBytePtr`, `MCDataCreateWithBytes`,
  `MCStringDecode`), so they carry **no leading underscore** - renaming them
  breaks the bind.
- **Boolean params/returns need explicit conversion.** A foreign handler takes
  `CInt`, so convert a Boolean param: `if pVal then put 1 into tV else put 0 into
  tV`. To return a Boolean from an int: `return tR is not 0`.
- **`ZStringUTF8`** is the bridge for short, NUL-terminated UTF-8 strings (magnet
  URI, hex hash, save path, an error message).
- **Avoid names whose stem shadows an engine token**, even when prefixed; prefer
  distinctive multi-word stems.
- **Prefix conventions:** `t` handler-local, `p` parameter, `s` script/module
  local, `k` constant. Public API `XxPascalCase`; C ABI `pfx_snake_case`.

## I.4 The FFI marshalling contract (the part that cost us the most)

- **A `Data` does NOT auto-bridge to a C `Pointer`.** It marshals as an opaque
  `MCDataRef`; passing one where a `Pointer` is declared raises a runtime
  `expected type pointer`. This was the hard-won lesson. The two proven shapes
  (from the htmltidy/HIDAPI bindings):
  - **OUT buffer** (the shim fills it): the binding allocates a raw block via the
    builtin `MCMemoryAllocate`, passes it as a real `Pointer` plus its capacity;
    the shim writes and returns **bytes-written**, or **`-needed`** (the negative
    of the required size) if the block was too small; the binding copies exactly
    the written bytes back with `MCDataCreateWithBytes`. **Grow-and-retry once**
    on `-needed`, then walk the bytes. **Reuse a persistent buffer** (`sXxxPtr` /
    `sXxxCap`) - never reallocate per poll.
  - **IN buffer** (the app supplies it): pass `MCDataGetBytePtr(theData)` - the
    read-only pointer to the Data's own bytes - plus its length. The shim only
    reads it.
- **Scalars:** int -> `CInt`, bool -> `CInt` (0/1), real -> `double`.
- **There is NO 64-bit foreign int.** 64-bit values, offsets, and hashes ride as
  **decimal/hex `ZStringUTF8` strings**.
- **Never return a library-owned `const char*`** of unknown lifetime - fill a
  caller buffer, or return a defined-lifetime static the engine copies
  immediately. Return `""`, never `NULL`, on bad input.
- **The out-buffer convention is a separate family from action codes.** Getters
  return bytes-written / `-needed` / `0`-on-bad-handle. Actions return `0` (ok) /
  negative (error). Keeping them separate means a small `-needed` can never be
  mistaken for an error code.
- **The getter `-1` caveat.** The default is "0 == no-op/empty on a bad handle."
  But when `0` is itself a *valid* value for an int getter (e.g. a queue position
  of 0), return **`-1`** for "no value / bad handle" and document it - otherwise
  the caller cannot tell "position 0" from "no torrent."

## I.5 C-preprocessor / C++ traps (paid for this session)

- **THE MACRO-COMMA TRAP.** A top-level comma inside a function-like guard macro
  body splits the macro's arguments. `std::array<char, 32> seed;` inside
  `BTX_GUARD_*({ ... })` failed with "macro passed 2 arguments" - the
  preprocessor protects commas inside **parentheses only**, not `<angle
  brackets>` or `{braces}`. Fixes: hoist a file-scope `using alias =
  std::array<char,32>;` and use the alias; or wrap the declaration in an extra
  set of parens; or declare the variable outside the macro body.
- **Exceptions must never cross `extern "C"`** - restated because a C++ library
  (libdatachannel) throws, and even C glue can hit `std::bad_alloc` on our
  allocations. The firewall macro makes this structural, not a thing you remember.
- **Treat third-party headers as system headers** (`-isystem`) so their warnings
  do not pollute our `-Wall -Wextra` (`/W3` on MSVC). Our code stays warning-clean.
- **Pin every dependency version.** Stand up the CI build matrix in Phase 0, not
  at the end - the dependency build (Boost for libtorrent; OpenSSL/usrsctp/ICE
  for libdatachannel) is the real risk, not the binding.

## I.6 Handles & the record codec (reuse these verbatim)

- **Handles** are positive 32-bit ints packing a generation counter above a slot
  index, in a validated table. Freeing a slot bumps its generation, so a
  stale/removed/never-created handle is a harmless no-op (getters 0/empty, actions
  error) - never a crash, never a recycled-slot alias. One table per object kind
  (session/torrent; host/peer; peerconnection/channel). Also check the library's
  own validity flag where it has one.
- **The record codec** is the wire format for every event and snapshot:
  `kvrecord := [count:u16] then [fieldId:u8][type:u8][len:u16][bytes]` repeated;
  **all framing integers big-endian**; `type` is 0=int(ASCII) 1=real(ASCII)
  2=utf8 3=raw 4=hex. Higher shapes are count-prefixed lists:
  `[count:u16] then [bodyLen:u16][kvrecord]*`. Keep a **single fieldId/alert
  registry in a shared header**; the LCB walker mirrors the numbers as `k*`
  constants, and a registry checker proves the two never drift. **The drain never
  drops a record** - an oversized one is stashed and emitted next call.

## I.7 Lifecycle & threading model

- **There is NO deterministic LCB unload hook.** The library cannot tear itself
  down. Expose an explicit teardown (`XxStopSession` / `XxClose` / `XxCleanup`)
  and document that the app MUST call it (e.g. on `closeStack`). Make it
  **idempotent** and a no-op on a stale handle. For global-singleton init
  (`sodium_init`, `enet_initialize`, `rtcInit`), init once on load; refuse a
  second concurrent *session* only where the library is genuinely single-instance
  (libtorrent was; ENet is NOT - it allows many hosts).
- **The poll-drain.** A script timer calls `XxPoll` once per tick -> one FFI
  round-trip drains ALL pending events as a record list -> a dispatcher fans them
  to message-path handlers. The interval is a **latency/CPU knob**, not a
  correctness knob. For real-time (ENet, datachannel) poll faster (16-33 ms); for
  crypto (libsodium) there is no poll at all (synchronous functions).

## I.8 The single-thread performance playbook

OXT runs script, the FFI, and rendering on ONE interpreted thread. Costs, in
order: (1) interpreter ops, (2) FFI round-trips, (3) property-set redraws.

- **One FFI round-trip per poll** - a batched drain and one-call snapshots, never
  one call per event or per field.
- **Reuse a persistent buffer** in the hot path; rebuilding an N-byte `Data`
  every poll is O(N) interpreter work.
- **One clock read per pass** (hoist `the milliseconds` out of loops).
- **UI text <= ~4 Hz and only on change.** An every-frame field relayout+redraw
  is the biggest avoidable cost.

## I.9 Toolchain & process gotchas

- **ABI-version sync gate.** `PFX_ABI_VERSION` (C header) must equal
  `kABIVersion` (LCB). A forgotten bump previously surfaced only at runtime via
  `checkABI()`; we added a **static gate** asserting the two match
  (`check-record-registry.py`) after hitting exactly that. Bump on ANY change to
  the exported surface (new symbol, changed signature, new fieldId/alert).
- **The native binary ships bundled per platform** under
  `src/code/<arch>-<platform>/<lib>.{so,dll,dylib}` - bare token, no `lib`
  prefix; platform ids `x86_64-linux` / `x86-linux` / `x86_64-win32` /
  `x86-win32` / `universal-mac`, **architecture first**, Windows `-win32` for
  both bitnesses. A native change is not "done" until the committed binary is
  refreshed (`package-extension.py`); CI rebuilds and commits the matrix on merge.
- **Static gates run anywhere (no GUI):** `check-livecodescript.py` (smart
  quotes, handler/control/`unsafe` balance, constants-before-use - now scans
  `src`, `examples`, AND `tests`), the record-registry cross-check, the record
  golden test, and the C++ smoke test under **gcc ASan/UBSan** (clang's ASan
  runtime is not installed in our environment).
- **The OXT pass is unavoidable.** There is no headless way to compile or run
  `.lcb` / `.livecodescript`. A **self-building runtime self-test stack** (see
  `tests/torrent-selftest.livecodescript`) is the companion to the C++ smoke
  test - the only way to validate the BINDING. Until a human runs it, everything
  binding-side is **"verified statically; needs an OXT pass."** Never claim
  runtime behaviour you cannot observe.

---

# PART II - libsodium (the trust layer) - DO FIRST

## II.1 Why first

It is the easiest wrap we will ever do, fills the most glaring gap (OXT's crypto
is dated - no ed25519, X25519, AEAD, Argon2, BLAKE2), and is a **force
multiplier**: the real-time layers need it for secure channels, and every serious
app needs signing / encryption / password hashing. Fast win; it also lets us
stand up the shared scaffolding (Part V) on the simplest possible target.

## II.2 The wrap shape - and how it DIFFERS from TorrentXT

- **Pure functions. No threads, no event loop, (mostly) no handles.** So in
  Phase 1 there is **no poll-drain and no record codec** - just the firewall and
  the Data<->Pointer in/out buffer contract, used heavily because the payload IS
  the data.
- **Rule 3 inverts:** crypto buffers cross by design. Keep them reasonable
  (KB-MB). For huge inputs use the streaming API (Phase 2, with handles) or chunk
  in script.
- **Global init:** `sodium_init()` once on load (idempotent; 0 ok / 1 already / -1
  fail). Refuse to operate if it returns -1.
- **Secret-material caveat:** an OXT `Data` is NOT locked/secure memory;
  libsodium's `sodium_malloc`/`mlock` protections do not extend to keys held in
  script. Document this, and offer `sdMemzero` to best-effort wipe a Data's bytes
  after use.

## II.3 Prefix, ABI, sizes

- C ABI prefix `sdx_`; LCB public `sd*`; library `org.openxtalk.library.sodium`.
- Reuse the out-buffer convention verbatim. Fixed-size outputs (signature 64,
  public key 32, secret key 64, nonce 24, MAC 16, ...) are returned via the
  buffer; variable outputs (ciphertext = message + MAC) are sized by the shim.
  **Expose the exact sizes as `kSd*` constants** so script can size buffers and
  validate inputs.

## II.4 Phase 1 surface (the essentials)

| Public handler | libsodium primitive | Notes |
|---|---|---|
| `sdInit` / `sdVersion` | `sodium_init` / `sodium_version_string` | once at load |
| `sdRandomBytes(n)` | `randombytes_buf` | CSPRNG |
| `sdBin2Hex` / `sdHex2Bin` / `sdBin2Base64` / `sdBase642Bin` | `sodium_*` | constant-time; exact size formulas |
| `sdSignKeypair` / `sdSignKeypairFromSeed` | `crypto_sign_keypair` / `_seed_keypair` | ed25519 |
| `sdSign` / `sdVerify` | `crypto_sign_detached` / `_verify_detached` | 64-byte detached sig |
| `sdSecretbox` / `sdSecretboxOpen` | `crypto_secretbox_easy` / `_open_easy` | shared-key auth-enc |
| `sdAeadEncrypt` / `sdAeadDecrypt` | `crypto_aead_xchacha20poly1305_ietf_*` | 24-byte random nonce, +AAD |
| `sdBoxKeypair` / `sdBoxEasy` / `sdBoxOpenEasy` | `crypto_box_*` | X25519 public-key enc |
| `sdBoxSeal` / `sdBoxSealOpen` | `crypto_box_seal*` | anonymous sender |
| `sdPwHashStr` / `sdPwHashStrVerify` | `crypto_pwhash_str*` | Argon2id password storage |
| `sdPwHash` | `crypto_pwhash` | derive a key from a password+salt |
| `sdGenericHash` | `crypto_generichash` | BLAKE2b, optional key, variable len |
| `sdKxKeypair` / `sdKxClientSessionKeys` / `sdKxServerSessionKeys` | `crypto_kx_*` | session-key exchange |
| `sdMemcmp` / `sdMemzero` | `sodium_memcmp` / `sodium_memzero` | constant-time compare; wipe |

## II.5 Phase 2 (stateful / streaming - introduces handles)

- `crypto_secretstream_xchacha20poly1305` (chunked file/stream encryption) - state
  handles in a gen-tagged table.
- Multipart `crypto_generichash` / `crypto_sign` (init/update/final) - state
  handles.
- `crypto_kdf` (derive subkeys from a master key).

## II.6 libsodium-specific gotchas

- `sodium_init` MUST run before any other call and is not safe to call
  concurrently (we are single-threaded, so call it once at load).
- The "easy" functions have exact buffer-size rules (does the output include the
  MAC? the nonce?). Be precise; expose `kSdMacBytes` (16), `kSdNonceBytes` (24),
  `kSdSignBytes` (64), etc. so script never mis-sizes a buffer.
- **Argon2 is CPU+memory heavy by design.** `opslimit`/`memlimit` are the latency
  knob; ship `interactive`/`moderate`/`sensitive` presets as constants and warn
  that `sensitive` can take seconds and **block the single thread** - for a UI,
  use `interactive`, or run the hash off a timer/idle pass.
- Hex/base64 helpers are constant-time with exact output sizes
  (`sodium_base64_ENCODED_LEN`) - use them rather than hand-rolling.
- It is C and effectively never throws; the firewall is still mandatory for our
  own `std::bad_alloc`.
- **Build is the easiest of the three:** tiny, no Boost, trivially static-linked
  (autotools or a CMake port). Pin a release (1.0.19+).

## II.7 Testing

- A C smoke test linking real libsodium: sign->verify round-trip, encrypt->decrypt
  round-trip (secretbox + AEAD + box), `pwhash_str` -> verify, hex/base64 round
  trips, keypair-from-seed determinism, bad-input -> clean error, the firewall.
  Light dependency -> runs in CI.
- A self-test stack mirroring the above with known test vectors and a green/red
  list (the `torrent-selftest` pattern).

## II.8 Milestones

0. **Spike:** build + `sdInit`/`sdVersion`/`sdRandomBytes` round-trip across the
   FFI (proves the scaffolding on the simplest target).
1. **Essentials:** the Phase 1 table.
2. **Streaming:** secretstream + multipart hashes (handles).
3. **Package + docs + self-test stack;** commit the platform binaries.

---

# PART III - ENet (real-time, step 1) - DO SECOND

## III.1 What it brings / why second

Reliable-and-unreliable UDP messaging with channels, sequencing, fragmentation,
and connection management - the low-latency layer OXT most lacks (games,
presence, live collaboration). It **reuses the TorrentXT pattern almost
verbatim**, so it goes fast once libsodium has proven the scaffolding. MIT.

## III.2 The wrap shape - closest to TorrentXT, but PUMP-DRIVEN

- **ENet has no internal threads.** You drive it: `enet_host_service(host,
  &event, timeoutMs)` pumps the socket and returns one event. So the poll-drain
  is: each `enPoll` tick, loop `enet_host_service(host, &e, 0)` (non-blocking)
  until it returns 0, draining CONNECT / DISCONNECT / RECEIVE events into the
  record list. Rule 1 is trivially satisfied (no foreign thread) - **but nothing
  progresses unless you pump**, so the poll loop is the binding's heartbeat and
  its cadence sets latency (poll 16-33 ms for real-time, not 250 ms).
- **Handles:** a host table and a peer table (gen-tagged). A peer id maps to an
  `ENetPeer*`; validate before use (a disconnected peer is a no-op).
- **Payload crosses** (received packet bytes -> script; script bytes -> a sent
  packet) - but these are MESSAGES (game state, control), not bulk. Document that
  ENet is not for files (use TorrentXT).
- **Not a single-instance library:** ENet allows MANY hosts per process, so the
  "refuse a second session" rule does NOT apply - the handle table holds N hosts.
- **Global init:** `enet_initialize()` once; `enet_deinitialize()` at teardown.

## III.3 Prefix & reuse

- C ABI `enx_`; LCB public `en*`; library `org.openxtalk.library.enet`.
- Reuse, essentially unchanged: the record codec + list framing (events as KV
  records), the handle tables, the firewall, the out-buffer convention, the
  poll-drain dispatcher.

## III.4 Phase 1 surface

| Public handler | ENet | Notes |
|---|---|---|
| `enInitialize` / `enDeinitialize` / `enVersion` | `enet_initialize` / `_deinitialize` / `_linked_version` | global |
| `enHostCreateServer(addr,port,maxPeers,channels,inBW,outBW)` | `enet_host_create` (bound) | returns host handle |
| `enHostCreateClient(maxPeers,channels,inBW,outBW)` | `enet_host_create` (unbound) | client host |
| `enHostDestroy(host)` | `enet_host_destroy` | idempotent |
| `enConnect(host, peerHost, port, channels, data)` | `enet_host_connect` | returns peer handle; CONNECT event confirms |
| `enDisconnect` / `enDisconnectNow` / `enResetPeer` | `enet_peer_disconnect*` / `_reset` | |
| `enSend(peer, channel, data, flags)` | `enet_packet_create` + `enet_peer_send` | flags: reliable / unsequenced |
| `enBroadcast(host, channel, data, flags)` | `enet_host_broadcast` | |
| `enFlush(host)` | `enet_host_flush` | send queued now |
| `enSetPeerTimeout` / `enSetPeerPingInterval` / `enSetHostBandwidth` | `enet_peer_*` / `enet_host_bandwidth_limit` | tuning |
| `enPeerStatus(peer)` | from `ENetPeer` fields | record: state, rtt, packetLoss, ... |
| `enPoll(host, out, cap)` | loop `enet_host_service` | the event firehose |

Events: `enetConnect` (peer), `enetDisconnect` (peer, reason), `enetReceive`
(peer, channel, raw data).

## III.5 ENet-specific gotchas

- **Pump or nothing.** `enet_host_service` must be called regularly or no
  connect/send/receive makes progress - unlike libtorrent, which self-pumps on
  its own threads. The poll loop is mandatory, and its interval is the latency
  floor.
- `enet_host_service` returns ONE event per call - loop until it returns 0 each
  tick to drain fully (or `enet_host_check_events` after a single service).
- **Packet ownership:** `enet_packet_create` copies the bytes (use the default;
  do NOT use `NO_ALLOCATE`). After `enet_peer_send` the host owns the packet -
  do not free it. On RECEIVE, **copy the bytes into our record THEN
  `enet_packet_destroy`** - never hand script a pointer into ENet-owned memory.
- Channel count is fixed at host create - choose it deliberately.
- Reliable vs unreliable-sequenced vs unsequenced are packet flags - expose as an
  int and document.
- `enet_address_set_host` resolves a hostname and **may block briefly on DNS**
  (like libtorrent's bootstrap) - accept it, or resolve in script and pass an IP.
- 32-bit packet size cap; keep messages small.

## III.6 Testing

- C smoke test: init, host create/destroy, a **loopback** (a server host and a
  client host in the same process), connect, send -> receive round-trip via
  pumped services, peer status, bogus-handle no-ops, the firewall.
- Self-test stack: same loopback in one stack (ENet's multi-host support makes
  this clean), asserting the receive event arrives after a few poll ticks.
- Demo: a tiny LAN chat / echo, or a two-cursor "shared whiteboard" showing
  real-time state sync.

## III.7 Milestones

0. **Spike:** build + a one-process loopback connect + echo.
1. **Core:** host/peer lifecycle, send/broadcast, the poll drain, events.
2. **Tuning + stats:** bandwidth/timeout/ping, `enPeerStatus`.
3. **Package + docs + self-test + a chat demo.**

---

# PART IV - libdatachannel + libjuice (real-time, step 2) - THE HARD ONE

## IV.1 What it brings / why last

WebRTC **data channels**: browser-interoperable peer-to-peer with real NAT
traversal (ICE / STUN / TURN). It is the graduation from ENet - it lets an OXT
app talk to a *browser* and punch through NATs without a relay - but ICE state
machines, the DTLS handshake, SCTP for data channels, and **foreign-thread
callbacks** make it the hardest of the three. MPL-2.0.

## IV.2 The wrap shape - THE foreign-thread-callback challenge

- **libdatachannel is C++ and runs its own threads;** its C API (`rtc/rtc.h`)
  delivers everything via **callbacks** (`rtcSetStateChangeCallback`,
  `rtcSetLocalDescriptionCallback`, `rtcSetLocalCandidateCallback`,
  `rtcSetMessageCallback`, `rtcSetOpenCallback`, ...) fired **from those
  threads.** This is Rule 1's worst case. The design that makes it safe:
  - Each callback runs on libdatachannel's thread and does **only**: lock a
    mutex, push a typed event (our handle id + a copy of the payload) onto a
    queue, unlock. Nothing else - **no engine call, no script, no allocation that
    could throw across the boundary**.
  - `dcPoll` (on the script thread) locks the mutex, drains the queue into the
    record list, unlocks, returns. Script never runs on a foreign thread.
  - **The mutex-guarded inbound queue is the single most important correctness
    structure of this binding.** It is the one binding with real concurrency.
- **Signaling is out of band.** WebRTC needs the two peers to exchange an SDP
  offer/answer plus ICE candidates over *some* channel you provide. The binding
  emits `localDescription` and `localCandidate` events (script ships them to the
  peer), and accepts the remote via `dcSetRemoteDescription` /
  `dcAddRemoteCandidate`. **The signaling transport can be TorrentXT's DHT
  (BEP44)** - a server-less rendezvous - which closes the stack's loop nicely.
- **Payload:** data-channel messages cross to script (chat, game state,
  file-chunk control). **Media (audio/video tracks) should NOT cross as payload**
  - punt media to a much later, separate phase, or keep it engine-side. **Phase 1
  is DATA CHANNELS ONLY.**
- **Everything is async** - connection setup, ICE gathering, DTLS - all surfaced
  as poll-drained events. There is no synchronous "connect"; you create a peer,
  exchange signaling, and watch for the `channelOpen` event.

## IV.3 Prefix & reuse

- C ABI `dcx_`; LCB public `dc*`; library `org.openxtalk.library.datachannel`.
- Reuse: record codec + list framing, handle tables, firewall, out-buffer.
- **New structure:** the mutex-guarded inbound event queue (Phase 0).

## IV.4 Phase 1 surface (data channels only)

| Public handler | libdatachannel | Notes |
|---|---|---|
| `dcInit` / `dcCleanup` | `rtcInitLogger` (optional) / `rtcCleanup` | global; cleanup at teardown |
| `dcCreatePeer(iceServersJSON)` | `rtcCreatePeerConnection` | returns peer handle; wires our callbacks internally |
| `dcCreateDataChannel(peer, label)` | `rtcCreateDataChannel` | returns channel handle; triggers offer |
| `dcSetRemoteDescription(peer, type, sdp)` | `rtcSetRemoteDescription` | from signaling |
| `dcAddRemoteCandidate(peer, cand, mid)` | `rtcAddRemoteCandidate` | from signaling |
| `dcSendMessage(channel, data)` / `dcSendString(channel, text)` | `rtcSendMessage` | binary / text |
| `dcBufferedAmount(channel)` | `rtcGetBufferedAmount` | for backpressure |
| `dcCloseChannel(channel)` / `dcDeletePeer(peer)` | `rtcClose` / `rtcDeletePeerConnection` | idempotent |
| `dcPoll(out, cap)` | drain the mutex queue | the event firehose |

Events: `dcLocalDescription` (type, sdp), `dcLocalCandidate` (cand, mid),
`dcStateChange` (state), `dcGatheringStateChange`, `dcChannelOpen`,
`dcChannelClosed`, `dcMessage` (channel, data), `dcError` (message).

## IV.5 libdatachannel-specific gotchas (the big ones)

- **Foreign-thread callbacks -> mutex queue** (Part IV.2). Never call a
  `MCData*`/engine function from a callback. This is non-negotiable.
- **Callbacks can fire AFTER you delete the peer/channel.** Copy *handle ids*
  (not pointers) into the queue, and validate the handle (gen-tagged) when the
  script drains it - a stale id is a no-op.
- **The C API hands out its own int ids;** they are NOT generation-tagged, so do
  not expose them directly (a recycled rtc id would alias). Map them to OUR
  gen-tagged handles inside the shim.
- `rtcInit`/`rtcCleanup` are process-global. Init once at load; cleanup at
  `dcCleanup` (no unload hook -> document a leak at quit if the app skips it).
- **ICE/TURN config crosses as strings;** TURN credentials are secrets - the same
  no-secure-memory caveat as libsodium.
- **Build is the hard one.** libdatachannel pulls OpenSSL (or GnuTLS) for DTLS,
  usrsctp for SCTP, libjuice (or libnice) for ICE, and plog. Vendor them via
  CMake (`USE_GNUTLS=0` -> OpenSSL; build juice, not nice), static-link
  everything, and **reuse the static OpenSSL 3 we already ship for TorrentXT**.
  Stand up the platform matrix in Phase 0 - this is the Boost-build-risk lesson
  amplified across more dependencies.
- **libjuice alone is a fork in the road.** If you want NAT-traversed UDP without
  full WebRTC (no DTLS/SCTP/browser interop), wrapping just libjuice (ICE/STUN/
  TURN, MPL-2.0) is far lighter and could sit between ENet and full
  libdatachannel. Decide deliberately.
- **Message-size limits:** SCTP data channels fragment large messages and have
  practical caps - keep the control plane small; route bulk to TorrentXT.
- **Backpressure:** surface `bufferedAmount` (and the low-threshold event) so
  script can throttle instead of blasting the channel.

## IV.6 Testing

- The C smoke test is harder: a **loopback** of two peer connections in one
  process, manually shuttling each peer's description/candidates to the other
  through the API, pumping until `channelOpen`, then send -> receive. This
  exercises the mutex queue under the real threads.
- **Add ThreadSanitizer (TSan) for this binding specifically** - it is the only
  one with real concurrency; TSan catches a missing lock that ASan/UBSan will not.
- Self-test stack: provide a one-stack loopback (two peer connections wired to
  each other by direct candidate exchange), or document a two-machine manual test
  using **DHT BEP44 as the signaling channel** (the headline integration demo).

## IV.7 Milestones

0. **The build + the queue:** get the dependency stack compiling on all platforms
   (the real risk) and a C loopback spike (two peers, `channelOpen`, echo)
   running clean under ASan/UBSan + TSan.
1. **Data channels + signaling events + the mutex queue.**
2. **TURN, backpressure, reconnection.**
3. **(Optional, separate) media tracks** - and only if payload can stay
   engine-side.
4. **Package + docs + the flagship demo:** P2P chat/state over **DHT-signalled**
   WebRTC, tying datachannel + TorrentXT together.

---

# PART V - Sequencing, shared infrastructure, risk

## V.1 The order, and why

1. **libsodium** - lowest risk, highest leverage, no event model. Fastest win;
   stand up the shared scaffolding here.
2. **ENet** - reuses the TorrentXT pattern almost verbatim; introduces the
   real-time poll cadence; fully loopback-testable in one process.
3. **libdatachannel** - hard; introduces foreign-thread concurrency and the
   dependency-build risk; pays off with browser interop + NAT traversal, with
   **DHT BEP44 signaling** closing the loop back to TorrentXT.

## V.2 Shared scaffolding to extract (the highest-leverage investment)

Factor the proven core out of TorrentXT into a shared `oxtkit/` so all three
(and every future wrap) share one tested implementation:

- the generation-tagged **handle table**;
- the **record codec** + the registry cross-check tool;
- the **firewall macros** (with the macro-comma lesson baked into a comment);
- the **out-buffer** helpers (allocate / bytes-written / `-needed` / grow-once);
- the **ABI-version sync gate**;
- the **poll-drain queue**, plus a **mutex variant** for libdatachannel;
- the static gates (`check-livecodescript`, record-registry, golden) - already
  generic;
- `package-extension.py` + the per-platform committed-binary flow + the CI matrix.

Doing this once, on libsodium, makes ENet and libdatachannel dramatically faster
and keeps all four bindings behaviourally identical where it matters (handle
safety, the firewall, the drain).

## V.3 Risk register

| Risk | Where | Mitigation |
|---|---|---|
| Dependency build (OpenSSL/usrsctp/ICE) | libdatachannel | Phase-0 CI matrix; vendor via CMake; reuse our static OpenSSL 3 |
| Foreign-thread races | libdatachannel | the mutex queue; copy ids not pointers; **add TSan** |
| No unload hook -> leak at quit | all | explicit idempotent teardown; document the closeStack contract |
| Payload-size creep across the FFI | enet, datachannel | document a size budget; route bulk to TorrentXT |
| Secret material in non-secure memory | sodium, datachannel(TURN) | document; offer `sdMemzero`; keep secrets short-lived |
| ABI drift between header and binding | all | the static ABI-sync gate (already built for TorrentXT) |
| License surprise | libjuice/datachannel | confirm MPL-2.0 at the pinned tag before shipping |
| Single-thread blocking (Argon2 `sensitive`) | sodium | presets; warn; run heavy hashing off a timer/idle pass |

## V.4 Definition of done (per library)

- C smoke test green under **gcc ASan/UBSan** (+ **TSan** for libdatachannel).
- All static gates green; the **ABI-sync gate** green.
- Four-to-five **platform binaries committed** via the CI matrix.
- A **self-test stack** covering the public surface (the `torrent-selftest`
  pattern), runnable in OXT.
- Docs: a getting-started, an api-reference, and an update to this plan.
- Anything binding-side stays **"verified statically; needs an OXT pass"** until a
  human runs the self-test stack and reports green.

---

*This document is a plan, not an as-built record. As each library lands, fold its
real surface into its own api-reference and update the status table at the top.*
