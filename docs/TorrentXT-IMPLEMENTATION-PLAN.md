# TorrentXT — Implementation Plan & Specification

> **Working name:** TorrentXT · **LCB module:** `org.openxtalk.library.torrent` ·
> **Native lib (bare token):** `torrentxt` · **C ABI prefix:** `btx_` · **Public LCB prefix:** `bt`
>
> **Status:** *historical design brief* — preserved for the rationale (the engine
> choice, the C-ABI design, the risk register), not as a description of the current
> state. The extension is built: the shim, the LCB binding, the tests, and four of
> five platform binaries ship today. Where this brief differs from the as-built
> code, **the code and the current docs win** — most notably the teardown handler
> shipped as **`btStopSession`** (not the `btStopSession` this brief sometimes names),
> and the out-buffer marshalling shipped via the engine `<builtin>`
> `MCMemoryAllocate` path (not a pre-sized `Data` bridged to a `Pointer`; see the
> FFI section of `docs/architecture.md`). For the call-by-call contract read
> `docs/api-reference.md`; for the as-built shape, `docs/architecture.md`.
>
> **Honesty convention (carried from ShowControl):** OXT is a GUI runtime with **no
> headless way to compile or run `.lcb`/`.livecodescript`**. Anything you cannot
> observe, you mark "verified statically; needs an OXT pass" and let the human
> confirm. Never claim runtime behaviour you have not seen.

---

## 0. Prime directive

**Open the full BitTorrent protocol surface to OXT / the xTalk family** (also
LiveCode 9.6.3+) as an installable extension, so a script author can add, control,
seed, and inspect torrents — including DHT, PEX, magnet/metadata exchange, uTP,
encryption, HTTP+UDP trackers, webseeds, and BitTorrent v2 — without leaving xTalk.

This is **not** a codec library and **not** a thin RPC wrapper around someone's
client. It is a binding to a real, complete engine, exposing as much of that
engine's capability as we choose to surface.

---

## 1. The architectural decision

### 1.1 Wrap libtorrent-rasterbar (C++), behind a flat C ABI

libtorrent-rasterbar is the only off-the-shelf engine that is simultaneously
**feature-complete** (v1+v2, DHT/BEP 5, extension protocol/BEP 10, magnets/BEP 9,
PEX, uTP, encryption, multi-tracker, webseeds), **permissively licensed**
(BSD-3-Clause — compatible with our MIT extensions), and **designed to be embedded**
as a library with a stable C++ API. Pin a release (start at **v2.0.11**) and treat
its API reference at libtorrent.org as the source of truth for signatures.

### 1.2 C++ is not a barrier — we have done this before

The LCB foreign-handler FFI binds to **flat `extern "C"` symbols** and is indifferent
to the language behind them. ShowControl's `midi` extension already wraps **RtMidi,
which is C++**, via a C facade. We do the same here: a `torrent_shim.cpp` that uses
libtorrent in C++ internally and exposes a flat `extern "C"` surface (`btx_*`). The
real cost of the C++ route is the **build** (Boost — see §7), never the binding.

### 1.3 The insight that makes this feasible on a single-threaded engine

OXT runs script, UI, and the FFI on **one interpreted thread (~16 ms/frame budget)**.
A naïve torrent client that pushed gigabytes of payload *through the interpreter*
would stall the UI and could never hash/move data fast enough. **We never do that.**

libtorrent owns its own network and disk-I/O threads. Payload goes **engine → disk
on the engine's threads and never crosses the FFI**. OXT only ever:

- issues **commands** (add/remove/pause/set-priority…), which are tiny, and
- **polls** for small **status records and events** (progress %, rates, peer list,
  piece bitfield, "piece finished", "torrent finished"…).

The 16 ms budget is therefore irrelevant to the data path. This is the single most
important design fact in the project; if you ever find yourself moving piece payload
across the FFI into a LiveCode `Data`, stop — you have taken a wrong turn.

### 1.4 Rejected and deferred options (recorded so they are not re-litigated)

- **A pure-C engine.** None exists that is both maintained and complete. libtorrent
  was always C++; Transmission migrated its entire core from C to C++ in 4.0. The
  pure-C survivors (ctorrent and friends) are abandoned and lack DHT/uTP/v2/magnets.
- **libtransmission (embed).** GPLv2/GPLv3 — embedding forces our whole extension to
  GPL — and it was never released as a standalone library (downstream uses it via
  RPC). Out.
- **The daemon/RPC model** (drive transmission-daemon or rqbit's HTTP API from pure
  script). Lowest-effort path to a *working app*, and worth remembering as a fallback,
  but it exposes a **client's control surface, not the protocol** — no peer-wire or
  DHT-level access — so it fails the prime directive.

### 1.5 Decision gate: the rqbit (Rust → cdylib) alternative

If the Boost build proves too painful to maintain across all five targets, the
fallback is **rqbit** (Rust, actively developed, has DHT/uTP/magnets/HTTP-API and is
usable as a library). You would author a small Rust FFI crate
(`#[no_mangle] extern "C"`, `crate-type = ["cdylib"]`) exposing the **same `btx_` ABI
this document specifies**, and the entire LCB layer (§3–§6) is unchanged. Trade-offs:
**+** no Boost, clean cross-compile, one self-contained lib per platform, memory-safe
parsing for free; **−** you write the Rust→C shim yourself (rqbit ships none) and
accept a younger, less-complete, effectively one-maintainer engine (seeding,
encryption/MSE, and v2 are less proven than rasterbar's).

**This plan assumes libtorrent-rasterbar unless the human says otherwise.** The ABI
in §4 is engine-agnostic by design, so the choice does not block starting work on the
LCB layer or the test harness.

---

## 2. Layering

```
  your xTalk script        (Data, Arrays, Lists; resource handles are plain ints)
        |  bt* public handlers  (btStartSession, btAddMagnet, btPoll, btTorrentStatus, ...)
  +-----v-------------------------------------------------+
  | examples/torrent-helpers.livecodescript               |  optional script sugar:
  |   - the poll dispatcher (timer -> btPoll -> messages)  |  the event loop
  +-----+-------------------------------------------------+
        |  public handlers
  +-----v-------------------------------------------------+
  | src/torrent.lcb     library org.openxtalk.library.torrent |  foreign handlers +
  |                                                       |  public wrappers; hides
  |                                                       |  every handle
  +-----+-------------------------------------------------+
        |  FFI:  c:torrentxt> btx_*   (ints, doubles, Pointer+len, ZStringUTF8)
  +-----v-------------------------------------------------+
  | src/torrent_shim.cpp  (extern "C" facade)             |  ONE shared library named
  |   + libtorrent-rasterbar + Boost.Asio                 |  torrentxt.{so,dll,dylib}
  +-------------------------------------------------------+
              libtorrent owns the network + disk-I/O threads
```

A **visual dashboard** (progress / peer map / piece grid) is a separate, **optional
later phase** built as an LCB **`widget`** (a canvas control) on top of this
`library`. Keep the two concepts distinct: the engine is a *library* (non-visual
handlers on the message path); a *widget* is a drawn control. Do not conflate them.

---

## 3. The inbound model: poll, never call back

**The decisive rule, carried verbatim from ShowControl: never call an LCB handler
from a C (or any foreign/non-main) thread.** It is fragile and unsupported.

libtorrent's **alert queue is our RtMidi FIFO.** libtorrent buffers and timestamps
every event (a torrent was added, metadata arrived, a piece finished, a torrent
finished, a tracker replied, an error occurred, resume data is ready, …) on its own
threads. We **never** register a callback that runs script. Instead:

- The shim exposes `btx_pop_alerts(buf, cap)` — the **batched drain** (one FFI
  round-trip per poll, like `midi_in_drain`).
- The LCB layer `btPoll()` calls it, walks the records, and returns a list of event
  Arrays.
- A **script-side poll dispatcher** (shipped in `examples/torrent-helpers.livecodescript`)
  runs on a timer, calls `btPoll`, and `send`s a semantic message per event
  (`torrentAdded`, `metadataReceived`, `pieceFinished`, `torrentFinished`,
  `trackerReply`, `stateChanged`, `torrentError`, `resumeDataReady`, …) so the app
  author writes only event handlers.

As with MIDI: **throughput and event integrity are independent of poll cadence**
(libtorrent buffers between polls); only *worst-case added latency* scales with the
interval, so the interval is a documented latency/CPU knob (a 250–1000 ms status poll
is typically fine; a tighter loop only matters for live UI smoothness).

---

## 4. The C ABI contract (the heart of the project)

This is what the next agent designs first and treats as a locked, versioned contract.

### 4.1 Type conventions across the FFI (carried from Box2Dxt + ShowControl)

| Script value | LCB type | Crosses as | Notes |
|---|---|---|---|
| real number | `CDouble` | `double` | xTalk numbers are doubles |
| integer / handle | `CInt` | `int32_t` | handles are **positive**; `0` = invalid |
| boolean | `CInt` | `int` 0/1 | |
| byte buffer (.torrent data, resume data, alert/status records) | `Data` | `Pointer` + `CInt` len | see §6 |
| short string (magnet URI, save path, error, hex info-hash) | `String` | `ZStringUTF8` | never the LCB `string` type |
| **64-bit value / info-hash / piece offset** | `String` | **decimal or hex `ZStringUTF8`** | the engine has **no 64-bit foreign int** |

### 4.2 Two non-negotiable C++-specific rules (NEW — these did not exist for our C shims)

1. **Exception firewall.** libtorrent **throws**. An exception that unwinds across the
   `extern "C"` boundary into LCB will take the engine down. **Every** `btx_*` entry
   point wraps its body in `try { … } catch (...) { btx_set_error(…); return <error>; }`.
   No exception ever crosses the boundary. This is the C++ analogue of Box2Dxt's "never
   let a bad handle reach Box2D."
2. **Clean shutdown, explicitly.** libtorrent's session runs background threads; it
   must be paused, given a moment to write resume data, and destroyed in order. OXT
   has **no deterministic extension-unload hook**, so cleanup cannot be automatic:
   expose `btStopSession` and **document that the app must call it**
   (e.g. on `closeStack`/`shutdown`). A session leaked at quit is the expected failure
   if the app forgets — design `btStartSession` to refuse a second session while one
   is live, and make `btStopSession` idempotent.

### 4.3 Symbol families (illustrative surface — confirm exact upstream signatures)

Names below are the **shim** (`btx_`) symbols; each gets a `private foreign handler`
plus a `public bt*` wrapper in the `.lcb`. This is a *map*, not the final header.

**Lifecycle & diagnostics**
- `int btx_abi_version(void)` — returns `BTX_ABI_VERSION`; LCB `checkABI()` throws on skew.
- `int btx_session_new(...settings...)` → session handle (0 on failure). Build a
  libtorrent `session_params` / `settings_pack` from the passed knobs.
- `void btx_session_free(int s)` — pause, flush, destroy, join threads.
- `int btx_last_error(char *out, int cap)` — module-static last-error string (caller buffer).

**Session settings** (cover the protocol surface here)
- `int btx_set_int(int s, const char *key, const char *decValue)` (rate limits, ports,
  connection caps; 64-bit values as decimal strings)
- `int btx_set_bool(int s, const char *key, int v)` (DHT on/off, LSD, PEX, uTP, anonymous mode…)
- `int btx_set_str(int s, const char *key, const char *v)` (listen interfaces, user-agent…)
- `int btx_set_encryption_policy(int s, int inPolicy, int outPolicy, int level)` (MSE/PE)
- Map `key`s to libtorrent's `settings_pack` names; document the supported set.

**Add / remove torrents**
- `int btx_add_magnet(int s, const char *uri, const char *savePath)` → torrent handle
  (use `lt::parse_magnet_uri`).
- `int btx_add_torrent_file(int s, const void *data, int len, const char *savePath)` →
  torrent handle (build `torrent_info` from the buffer — **the .torrent bytes are an
  IN buffer crossing as Pointer+len; the payload is NOT what crosses, only the
  metainfo**).
- `int btx_add_with_resume(int s, const void *resume, int len, const char *savePath)` →
  handle (re-add from saved resume data; see persistence below).
- `int btx_remove(int s, int t, int deleteFiles)`.

**Control**
- `int btx_pause(int t)` / `btx_resume(int t)` / `btx_force_recheck(int t)` /
  `btx_force_reannounce(int t)`.
- `int btx_set_file_priority(int t, int fileIndex, int priority)` and a bulk variant.
- `int btx_set_piece_priority(int t, int pieceIndex, int priority)`.
- `int btx_set_torrent_limits(int t, const char *downDec, const char *upDec)`.

**Status — one snapshot per call** (perf: never one FFI call per field)
- `int btx_torrent_status(int t, void *out, int cap)` → fills a **typed KV record**
  (schema in §4.4) with name, state, progress, down/up rate, total done, num peers/seeds,
  ETA, save path, etc. Returns bytes written or `-needed`.
- `int btx_torrent_count(int s)` / `int btx_torrent_handle_at(int s, int i)` — enumerate.
- `int btx_info_hash_hex(int t, char *out, int cap)` — v1 (and v2) info-hash as hex string.
- `int btx_piece_bitfield(int t, void *out, int cap)` — packed have-bits (read-only view).
- `int btx_peer_list(int t, void *out, int cap)` — peers as concatenated KV records.

**The alert drain (the event firehose)**
- `int btx_pop_alerts(int s, void *out, int cap)` → number of alert records written;
  each record is `[type:u16][len:u16][payload bytes…]` (schema §4.4). Records that do
  not fit are **stashed and emitted next call — never dropped** (honor ShowControl's
  "the drain must never drop a message").

**DHT**
- `int btx_dht_add_bootstrap(int s, const char *host, int port)`.
- `int btx_dht_state(int s, void *out, int cap)` (node count, etc.).
- `int btx_dht_save_state(int s, void *out, int cap)` / `btx_dht_load_state(...)`.

**Persistence (resume data)**
- `int btx_save_resume(int t)` — *requests* resume data (async; arrives as a
  `save_resume_data_alert` you drain, which carries the bytes). Do **not** invent a
  synchronous getter; follow libtorrent's async model.

**Create torrents (seeding side, later phase)**
- `int btx_create_torrent(const char *path, int pieceSize, ...)` → torrent file bytes
  in a caller buffer.

### 4.4 The record schema (define once, golden-test it)

Both the alert drain and the status/peer snapshots use a **self-describing, typed,
length-prefixed KV record**, walked in LCB with byte arithmetic (no float unpacking):

```
record   := [count:u16] field*
field    := [fieldId:u8] [type:u8] [len:u16] [valueBytes:len]
type     := 0=int(decimal ASCII) 1=double(decimal ASCII) 2=utf8 3=raw 4=hexhash
```

- All multi-byte integers in the framing are **big-endian** (network order — the same
  choice as the MIDI drain; pick it once, pin it in a golden test, never "fix" it later).
- 64-bit numbers and info-hashes ride as ASCII (decimal/hex) `type` values, so no
  64-bit binary field ever appears (there is no 64-bit foreign int — §4.1).
- Maintain a single **`fieldId` registry** in a shared header so the shim writer and
  the LCB walker cannot drift; adding a field is append-only and bumps `BTX_ABI_VERSION`.
- (If, and only if, the engine's JSON facilities are confirmed available and fast
  enough, a JSON-bytes encoding for the *low-frequency* status snapshot is an
  acceptable alternative — but the *high-frequency* alert drain stays binary. Default
  to binary for both until proven.)

### 4.5 Recipe for adding a handler

1. **Shim** (`torrent_shim.cpp`): add `extern "C" BTX_API <ret> btx_yourthing(...)`.
   Validate the handle first (stale → no-op return). Wrap the whole body in
   `try/catch(...)`. Fill **caller buffers** for any string/byte output — **never
   return a library-owned `const char*`**. Carry any 64-bit value as a string. Declare
   it in `torrent_shim.h`.
2. **LCB** (`torrent.lcb`): add `private foreign handler _yourthing(...) binds to
   "c:torrentxt>btx_yourthing!cdecl"`, then a `public handler btYourThing(...)` that
   pre-sizes any out `Data` (§6), bridges types, hides the handle, sets the module
   last-error on failure, and returns empty/`0` rather than throwing.
3. **Bump `BTX_ABI_VERSION`** if the exported ABI changed; keep `checkABI()` in step.
4. **Rebuild**, refresh the committed per-platform binary via `tools/package-extension.py`,
   re-Package/Test in OXT.
5. **Add a C++ smoke-test assertion** so CI exercises it under ASan/UBSan.

---

## 5. Handles & safety

Reuse the **generation-tagged integer handle table** macro from Box2Dxt/OSC
(`DEFINE_PTR_TABLE`), one table for sessions and one for torrents. A handle packs a
generation counter above its slot; the shim validates every handle before use, so a
**stale, removed, or never-created handle is a harmless no-op** (getters return
`0`/empty; actions do nothing) — never a crash, and never silently addressing a
recycled slot.

- libtorrent's own `torrent_handle` is a weak reference that can already be "invalid";
  wrap it so script sees only our int, and check `handle.is_valid()` *inside* the slot
  before each call.
- The **session handle** is visible to script (long-lived; you pass it to most calls).
  **Torrent handles** are also visible (you pass them to control/status). Builders and
  any transient objects are bracketed inside one LCB call and never escape.
- Drop handles on remove/shutdown to keep tables small.

---

## 6. Crossing the FFI — marshalling (carry the ShowControl lessons)

- **Byte buffers cross as (Pointer, length).** An inbound `Data` (a .torrent file, resume
  data) passes the read-only pointer to its own bytes (`MCDataGetBytePtr`) plus a length.
  For an **out** buffer (alert drain, status snapshot, resume bytes), the LCB layer hands
  the shim a raw `MCMemoryAllocate` block as the `Pointer` to fill; the shim returns bytes
  written or `-needed`, and the binding copies the written bytes back with
  `MCDataCreateWithBytes`. *(As-built note: an LCB `Data` does **not** auto-bridge to a
  `Pointer`, so the pre-sized-`Data` idiom this brief originally proposed was replaced by
  the `<builtin>` allocator path above — see the FFI section of `docs/architecture.md`.)*
- **The `Data`⇄`Pointer` marshalling was the one empirically-unconfirmed FFI primitive.**
  It is *lower-stakes here* than for a hand-rolled engine, because we cross **status
  records, not payload**. It is now implemented and statically gated; it still wants the
  human OXT pass, and the **hex-over-string fallback** is recorded in
  `docs/architecture.md` if a strict build resolves it badly.
- **Reuse a persistent drain/status buffer in the poll hot path.** Rebuilding an N-byte
  `Data` every poll is O(N) interpreter work; allocate `sDrain` / `sStatus` once at a
  sane cap and reuse (the proven `midi.lcb` pattern).
- **Short strings cross as `ZStringUTF8`.** Magnet URIs, save paths, hex info-hashes,
  last-error. Never the LCB `string` type.
- **Never return a library-owned `const char*` of unknown lifetime.** Fill a caller
  buffer, or return a pointer into memory with a documented lifetime the engine copies
  immediately (the Box2Dxt `dlerror`/`realpath` pattern). Return `""`, never `NULL`,
  on a bad handle.

---

## 7. Build & packaging (the genuinely hard part)

- **CMake** drives everything. Acquire libtorrent + Boost via a pinned, reproducible
  mechanism (vcpkg manifest, or `find_package` against a documented system install, or
  `FetchContent` with a pinned `GIT_TAG`). **Pin the libtorrent tag** (start v2.0.11);
  Boost **≥ 1.70**.
- **Static-link** libtorrent + Boost into **one** shared library named with the **bare
  token** `torrentxt` (`PREFIX ""`, `OUTPUT_NAME torrentxt`) so the file matches the
  `c:torrentxt>` binding — `torrentxt.so` / `torrentxt.dll` / `torrentxt.dylib`,
  **never** `libtorrentxt.*`.
- **Bundle per platform.** Commit the built libraries under
  `src/code/<arch>-<platform>/torrentxt.{so,dll,dylib}` — **architecture first**,
  Windows `-win32` for both bitnesses: `x86_64-linux`, `x86-linux`, `x86_64-win32`,
  `x86-win32`, `universal-mac`. Installing the packaged extension makes the engine
  resolve the binding automatically via **`the revLibraryMapping`** (no `sudo`, no
  `/usr/lib`, no `LD_LIBRARY_PATH`, no rename). `tools/package-extension.py` refreshes
  the committed tree from a newer build.
- **Platform notes:** macOS **universal** build + **codesign/notarize** the dylib;
  32-bit Windows needs a `.def` for clean exports; keep a **glibc floor** (match
  Box2Dxt's ~2.17) for portable Linux binaries. Treat libtorrent/Boost headers as
  **system headers** so their warnings do not pollute our `-Wall -Wextra` (our code
  stays warning-clean; `/W3` on MSVC).
- **Binary size & build time will be the dominant cost.** Stand the CI matrix up in
  Phase 0 — do not discover the cross-platform build at the end. CI builds and
  sanitizer-tests Linux (x64 + x86), macOS (universal), Windows (x64 + x86) on every
  push, mirroring the sibling repos.

---

## 8. Testing & verification (carry the discipline)

OXT cannot compile/run `.lcb` headlessly, so push correctness into layers that *can*
be tested automatically and gate the rest statically.

1. **Phase-0 FFI spike (first commit).** A trivial extension exporting `btx_abi_version`
   plus the `Data`⇄`Pointer` round-trip, compiled and run in OXT, to confirm the one
   unknown primitive end-to-end. Gate the project on it.
2. **C++ smoke tests under ASan + UBSan** (use **gcc** — clang's ASan runtime is not
   installed in this environment, per ShowControl). Cover: session lifecycle;
   **handle safety** (every getter/action on a bogus handle is a no-op returning
   0/empty); add-from-buffer and add-magnet; the **alert drain record format**
   (round-trip a synthetic alert through the schema); the **exception firewall** (force
   an internal throw, assert it is caught and surfaced as an error, never propagated).
3. **Golden tests for the record schema** (a pure reference, like ShowControl's
   `artnet_golden_test.py`) so the LCB walker and the shim agree **byte-for-byte** on
   the framing and endianness.
4. **Static gates for the script layer:** `tools/check-livecodescript.py` (smart/curly
   quotes = 0, handler balance, `unsafe`/control-structure balance, constant
   declared-before-use). Run after **every** `.lcb`/`.livecodescript` edit; CI runs it too.
5. **Real-swarm interop (the network gate, like ShowControl's hardware gate).** Download
   a well-seeded, **legal** torrent (e.g. a current Linux distro ISO that publishes a
   torrent + checksum), then verify the downloaded file against the published hash.
   This is the proof the binding actually drives the engine. It is a *manual/scheduled*
   gate, not a per-push unit test.
6. **Scope of our tests:** we verify **the binding**, not the BitTorrent protocol —
   piece hashing, choking, and wire correctness are libtorrent's job and its test
   suite's. Do not re-test the engine.

---

## 9. OXT / xTalk / LCB lessons carried forward (the checklist)

These are imported from the Box2Dxt and ShowControl `CLAUDE.md` files. They are not
re-derived here — they are **load-bearing constraints** for this project too. The repo
`CLAUDE.md` (shipped alongside this plan) holds the operational copy; this is the index.

**LCB / OXT compiler footguns (OXT is stricter than LiveCode):**
- **No smart/curly quotes** anywhere — even in a comment or string literal — they fail
  OXT compilation. ASCII `"` and `'` only.
- **Avoid names whose stem shadows an engine token**, even when prefixed; prefer
  distinctive, multi-word stems.
- **Prefix conventions:** `t` handler-local, `p` parameter, `s` script/module-local,
  `k` constant; public API `btPascalCase`; C ABI `btx_snake_case`.
- **Constants must be literals AND declared before first use** — OXT resolves them by
  lexical position; a forward reference silently evaluates to nothing.
- **`unsafe … end unsafe` brackets every foreign call** in LCB.
- **Declare all `local`s at the top of a handler** — a `local` nested in an
  `if`/`repeat` has broken whole-script compilation.
- **Commands report via `the result`; functions return a value** — match the documented
  API shapes (e.g. `btAddMagnet` is a command → `put the result into tHandle`).
- **No headless compile/run** — static-gate, then the human does the OXT pass; never
  assert unobserved runtime behaviour.
- `itemDelimiter`/`lineDelimiter` are global mutable state — set immediately before use.

**FFI / ABI conventions:**
- Handles are **positive 32-bit, generation-tagged**, validated before use → stale =
  no-op, never a crash.
- Byte buffers cross as **Pointer + length**; out-buffers are **pre-sized `Data`** the
  shim fills; return bytes-written or `-needed`.
- **No 64-bit foreign int** → 64-bit values and info-hashes cross as decimal/hex strings.
- **Never return a library-owned `const char*`** of unknown lifetime → caller buffers
  or defined-lifetime statics; return `""` not `NULL`.
- Short strings cross as **`ZStringUTF8`**.
- **Bump `BTX_ABI_VERSION` on any ABI change**; `checkABI()` throws a clear error on skew.

**Single-threaded performance playbook:**
- The three real costs, in order: **interpreter ops, FFI round-trips, property-set
  redraws.** Design against all three.
- **Status/events: one FFI round-trip per poll** (the batched drain + the one-call
  status snapshot), never one call per field/event.
- **Reuse persistent buffers** in the poll hot path (`sDrain`/`sStatus`).
- **Hoist `the milliseconds`** out of loops; one clock read per pass.
- **UI/HUD text at a low rate (≤ ~4 Hz) and only on change** — an every-frame field
  relayout+redraw is the biggest avoidable cost. A torrent dashboard refreshing 2–4×/s
  is plenty.
- The poll interval is a **latency/CPU knob**, documented as such.
- **Above all (§1.3): payload never crosses the FFI into script.**

**Packaging:**
- Bare-token library name matching the `c:torrentxt>` binding; committed per-platform
  binaries under `src/code/<arch>-<platform>/`; resolved by `the revLibraryMapping`;
  CI builds + sanitizer-tests the full matrix.

**NEW, specific to wrapping a C++ engine (§4.2 expanded):**
- **Exception firewall:** `try/catch(...)` at every `extern "C"` entry; no exception
  ever crosses into LCB.
- **Explicit, idempotent shutdown:** no deterministic LCB unload hook, so the app must
  call `btStopSession`; refuse a second concurrent session; flush resume data and join
  threads on teardown.
- **Thread lifecycle / static init:** libtorrent's threads must outlive no LCB call and
  must be torn down only via `btStopSession`; never touch script from any libtorrent
  thread (that is the §3 rule, restated for the C++ context).

---

## 10. Phased implementation plan

Each phase ends at a **gate** with a concrete "done" definition. Do not start a phase
before its predecessor's gate is green.

> **As-built status.** Phases 0–3 are implemented in `src/torrent_shim.cpp` +
> `src/torrent.lcb` and gated by the test suite — pending only the human OXT pass
> noted throughout the repo. Phase 4 is largely done: four of five platform
> binaries are built and committed under `src/code/`, leaving only the macOS
> universal dylib + notarization. Phase 5 (the visual widget) is the remaining
> optional work. The phase list below is the original plan, kept for its gate
> definitions.

- **Phase 0 — Spike & skeleton.** Stand up the CMake build of libtorrent+Boost on at
  least Linux x64; produce a `torrentxt` lib exporting `btx_abi_version`; wire the LCB
  `checkABI()`; run the **Data⇄Pointer + abi_version round-trip in OXT**. Stand up CI.
  *Gate:* the human confirms the round-trip compiles and runs in OXT.
- **Phase 1 — Download-only, end to end.** Session lifecycle (`btStartSession`/
  `btStopSession`), `btAddMagnet` + `btAddTorrentFile`, the **alert drain** + record schema
  + golden test, the **poll dispatcher**, and a minimal `btTorrentStatus`. *Gate:* add a
  magnet for a legal Linux ISO, receive `metadataReceived`, watch `pieceFinished` events
  and progress climb, get `torrentFinished`, and the file verifies against its published
  hash (the §8.5 interop gate).
- **Phase 2 — Full control & inspection.** pause/resume/recheck/reannounce, file & piece
  priorities, per-torrent and session rate limits, the settings surface (DHT/LSD/PEX/uTP
  toggles, ports, connection caps), peer list + piece bitfield snapshots, DHT
  bootstrap/state, and **resume-data persistence** (save + re-add). *Gate:* stop and
  resume a partial download across a session restart using saved resume data.
- **Phase 3 — Seeding & the rest of the surface.** Seeding, create-torrent, encryption
  policy (MSE/PE), v2/hybrid specifics, webseeds, super-seeding if wanted. *Gate:* a
  second TorrentXT instance leeches a torrent the first is seeding.
- **Phase 4 — Hardening, packaging, docs.** All five platform binaries built, signed,
  and committed; macOS notarization; the docs set (architecture, building,
  getting-started, api-reference) and runnable examples; the interop gate run on every
  platform. *Gate:* a fresh OXT install of the packaged `.lce` works on each platform
  with no toolchain present.
- **Phase 5 (optional) — The visual widget.** An LCB `widget` dashboard (overall +
  per-torrent progress, rates, peer count, a piece-completion grid driven by the
  bitfield snapshot), refreshing at ≤ 4 Hz on change. Pure presentation over the
  Phase-1/2 status calls.

---

## 11. Repository layout (mirror the sibling repos)

```
TorrentXT/
├── src/
│   ├── torrent.lcb                 LCB binding (library org.openxtalk.library.torrent)
│   ├── torrent_shim.cpp/.h         extern "C" facade over libtorrent (btx_* symbols)
│   └── code/<arch>-<platform>/     committed native libs (torrentxt.{so,dll,dylib})
├── tests/
│   ├── torrent_smoke_test.cpp      lifecycle, handle-safety, drain format, exception firewall (ASan/UBSan)
│   └── record_golden_test.py       byte-exact record/endianness reference
├── tools/
│   ├── check-livecodescript.py     static gate for .lcb + .livecodescript
│   └── package-extension.py        refresh the committed code/<platform>/ trees
├── examples/
│   ├── torrent-helpers.livecodescript   the poll dispatcher + sugar
│   ├── torrent-client.livecodescript    the flagship multi-torrent client
│   └── torrent-demo.livecodescript      minimal add-a-magnet walkthrough
├── docs/
│   └── architecture.md  building.md  getting-started.md  api-reference.md
├── CMakeLists.txt
├── CLAUDE.md                       as-built record + the carried-forward lessons (shipped with this plan)
└── .github/workflows/build.yml     static + golden + ASan/UBSan gate, then the build matrix
```

---

## 12. Risk register

- **Boost/libtorrent build complexity (highest risk).** Mitigation: pin versions, use
  vcpkg or a documented system install, stand up the full CI matrix in Phase 0, treat
  upstream headers as system headers. The rqbit/cdylib fallback (§1.5) exists
  specifically to retire this risk if it dominates.
- **`Data`⇄`Pointer` marshalling unknown.** Mitigation: Phase-0 spike first; and the
  payload-doesn't-cross design makes it low-stakes (status records only).
- **No deterministic LCB unload → leaked session/threads.** Mitigation: explicit,
  idempotent `btStopSession`; refuse double sessions; document the app's obligation.
- **C++ exceptions crossing the FFI.** Mitigation: the `catch(...)` firewall at every
  entry point, asserted by a smoke test.
- **Binary size / macOS notarization friction.** Mitigation: budget Phase 4 for it; it
  is solved work in the sibling repos.
- **Positioning / distribution baggage.** A full BitTorrent client carries reputational
  and app-store baggage that OSC/MIDI/Art-Net do not. Not an engineering blocker and
  not this plan's call, but **flag it to the human before public release**, and lean on
  the legitimate framing (resilient large-payload/asset/dataset distribution, e.g.
  syncing multi-GB media across a fleet of installation machines — which connects
  directly to the installation-art audience the sibling projects already target).
- **Engine maturity (only if rqbit is chosen).** Seeding/encryption/v2 less proven;
  re-scope Phase 3 accordingly.

---

## 13. Decisions still owned by the human

1. **Engine: libtorrent-rasterbar (recommended) vs rqbit→cdylib.** This plan assumes
   the former; the ABI is engine-agnostic, so LCB and test work can start regardless.
2. **Status encoding:** the binary KV record (recommended/default) vs JSON-bytes for the
   low-frequency status snapshot only (allowed if the engine's JSON support is confirmed).
3. **v1 scope:** confirm "download-only first" (Phases 0–1) before seeding (Phase 3).
4. **Names/prefixes:** `TorrentXT` / `org.openxtalk.library.torrent` / `btx_` / `bt` —
   confirm or rename before the first commit (renaming the C ABI prefix later breaks
   compiled binaries).

---

## 14. References

- libtorrent — libtorrent.org (reference, tutorial, building); GitHub `arvidn/libtorrent`
  (BSD-3-Clause; v2.0.x; alerts, `session`, `add_torrent_params`, `settings_pack`).
- BitTorrent BEPs — bittorrent.org/beps (BEP 3 metainfo/peer-wire, BEP 5 DHT, BEP 9
  metadata, BEP 10 extension protocol, BEP 15 UDP trackers, BEP 29 uTP, BEP 52 v2).
- The sibling extensions — `SethMorrowSoftware/ShowControl` (the poll-drain model, the
  FFI conventions, the static gates, the Phase-0 spike, the packaging) and
  `SethMorrowSoftware/Box2Dxt` (the handle table, the OXT gotchas, the performance
  playbook). Their `CLAUDE.md` files are the canonical source for every carried lesson.
- rqbit — GitHub `ikatson/rqbit` (the fallback Rust engine; usable as a library; HTTP API).
