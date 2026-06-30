# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Read `docs/TorrentXT-IMPLEMENTATION-PLAN.md` first** — it is the full spec (the
> engine decision, the C ABI design, the phased plan, the risk register). This file
> is the operational as-built record and the hard-won-lesson list, in the same spirit
> as the `CLAUDE.md` files in our sibling extensions Box2Dxt and ShowControl.

## What this is

**TorrentXT** opens the **full BitTorrent protocol** to OpenXTalk (OXT) / the xTalk
family (also LiveCode 9.6.3+): add, control, seed, and inspect torrents — DHT, PEX,
magnets/metadata, uTP, encryption, HTTP+UDP trackers, webseeds, v1+v2 — from xTalk.

It is a binding to **libtorrent-rasterbar** (C++, BSD-3), wrapped behind a flat
`extern "C"` shim, with a thin LCB layer on top:

```
libtorrent-rasterbar (BSD-3) + Boost.Asio        owns the network + disk-I/O threads
   |- C++ shim     src/torrent_shim.cpp   ->  torrentxt.{so,dll,dylib}  (ABI symbols: btx_*)
        |- LCB binding  src/torrent.lcb        (library org.openxtalk.library.torrent; public bt*)
             |- script helpers  examples/torrent-helpers.livecodescript  (the poll dispatcher)
```

The native library ships **bundled inside the extension** under
`src/code/<arch>-<platform>/torrentxt.{so,dll,dylib}` (bare token, no `lib` prefix;
platform-ids `x86_64-linux` / `x86-linux` / `x86_64-win32` / `x86-win32` /
`universal-mac`, **architecture first**, Windows `-win32` for both bitnesses).
Installing the packaged extension makes the engine resolve the `c:torrentxt>` binding
via `the revLibraryMapping` automatically — no loose library, no `sudo`, no
`/usr/lib`, no `LD_LIBRARY_PATH`, no rename.

Engine choice is recorded in the plan (§1). The C ABI is **engine-agnostic**: if we
ever switch to the rqbit/Rust→cdylib fallback, the same `btx_*` surface is reproduced
in Rust and the LCB layer is untouched.

## The three rules that make this safe

1. **Never call an LCB handler from a libtorrent (foreign) thread.** Inbound events
   ride libtorrent's **alert queue**, which we **poll-drain** on a timer (`btPoll` →
   `btx_pop_alerts`), exactly like ShowControl's MIDI FIFO. No callback ever runs
   script. Throughput/integrity are independent of poll cadence; only latency scales
   with the interval, so the interval is a documented latency/CPU knob.
2. **The exception firewall.** libtorrent **throws**; an exception crossing the
   `extern "C"` boundary takes the engine down. **Every** `btx_*` entry point is
   `try { … } catch (...) { btx_set_error(…); return <error>; }`. No exception ever
   crosses into LCB. (The C++ analogue of "never let a bad handle reach the engine.")
3. **Payload never crosses the FFI into script.** libtorrent moves piece data
   engine → disk on its own threads. OXT only issues tiny commands and polls small
   **status records and events**. If you find yourself putting piece payload into a
   LiveCode `Data`, you have taken a wrong turn — the single-threaded ~16 ms budget
   makes that path unviable, and the whole design exists to avoid it.

## Commands

**Native shim + C++ tests** (the only layer with an automated test suite):
```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTORRENTXT_BUILD_TESTS=ON
cmake --build build --config Release
ctest --test-dir build --output-on-failure        # torrent_smoke_test.cpp
```
CMake acquires libtorrent (pinned `GIT_TAG`, start v2.0.11) + Boost (>= 1.70). The
build is the heavy part — see `docs/building.md`. Static-link into ONE shared library
named with the **bare token** `torrentxt` (`PREFIX ""`, `OUTPUT_NAME torrentxt`).

**Always build the shim under sanitizers while iterating** — use **gcc** (clang's
ASan runtime is not installed in this environment):
```sh
g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=all \
  -isystem <libtorrent-include> -isystem <boost-include> \
  src/torrent_shim.cpp tests/torrent_smoke_test.cpp <link libtorrent + boost> -o /tmp/tt && /tmp/tt
```
Treat libtorrent/Boost headers as **system headers** (`-isystem`) so their warnings
do not pollute our `-Wall -Wextra` (our code stays warning-clean; `/W3` on MSVC).

**Record-schema golden test** (pure reference, runs anywhere):
```sh
python3 tests/record_golden_test.py
```

**Static gates for the script layer.** OXT is a GUI runtime — there is **no headless
way to compile or run `.lcb` / `.livecodescript`**. Catch what is statically catchable
first:
```sh
python3 tools/check-livecodescript.py
```
It checks every `.lcb` and example for smart/curly quotes, handler balance,
control-structure and `unsafe` balance, and constant-declared-before-use. **Do not
claim runtime behaviour you cannot observe** — say "verified statically; needs an OXT
pass" and let the user confirm.

## FFI / C-ABI conventions (from Box2Dxt + ShowControl)

- **Handles are positive 32-bit ints** (`0` = invalid), stored in a **generation-tagged**
  table and validated before use, so a stale/recycled handle is a **harmless no-op**
  (getters return `0`/empty), never a crash. Two tables: sessions and torrents. Also
  check libtorrent's own `handle.is_valid()` inside the slot.
- **Reals cross as `double`, booleans as `int` (0/1).** Exported C ABI symbols keep the
  stable `btx_` prefix — never rename them; the `.lcb` `binds to "c:torrentxt>…"`
  strings reference them.
- **Byte buffers cross as `Pointer` + `CInt` length — an LCB `Data` does NOT
  auto-bridge to a `void*`.** This was the hard-won FFI lesson (it cost a runtime
  `expected type pointer` error): the Language Reference is explicit that "No
  automatic bridging from Data or String to Pointer exists" — a `Data` marshals as
  an opaque `MCDataRef`. So, matching the proven htmltidy/HIDAPI bindings: an
  **out** buffer (the shim fills it) is a raw block from the engine `<builtin>`
  `MCMemoryAllocate`, passed as a real `Pointer`, returning bytes written or
  `-needed`; we then copy the written bytes back with `MCDataCreateWithBytes`. An
  **in** buffer (.torrent file, resume data) passes `MCDataGetBytePtr(theData)` —
  the read-only pointer to the Data's own bytes — plus its length. A `<builtin>`
  handler resolves by its **name** matching the engine symbol, so those handlers
  carry **no leading `_`** (renaming them breaks the bind). Low-stakes overall
  because only status records cross, never payload.
- **There is no 64-bit foreign int.** 64-bit values, info-hashes, and piece offsets
  cross as **decimal/hex `ZStringUTF8`** strings.
- **Never return a library-owned `const char*`** of unknown lifetime — fill a caller
  buffer or return a defined-lifetime static the engine copies immediately; return `""`,
  never `NULL`, on a bad handle.
- **Short strings cross as `ZStringUTF8`** (magnet URI, save path, hex info-hash, error).
- **Bump `BTX_ABI_VERSION`** on any ABI change; the `.lcb` `checkABI()` throws a clear
  error on skew instead of crashing on first use.
- **The record schema** (alert drain + status snapshots): a self-describing typed,
  length-prefixed KV record (`[count:u16]` then `[fieldId:u8][type:u8][len:u16][bytes]`
  repeated), all framing integers **big-endian**. Keep a single `fieldId` registry in a
  shared header so the shim writer and the LCB walker cannot drift; adding a field is
  append-only and bumps the ABI. Pin the framing in `record_golden_test.py` and never
  "fix" the endianness later. The **drain must never drop a record** — stash an
  oversized one and emit it next call (ShowControl's MIDI rule).
- **Adding a handler:** `btx_*` in the shim (validate the handle; wrap in `try/catch(...)`;
  fill caller buffers; carry 64-bit as string) -> `private foreign handler` + public
  `bt*` wrapper in the `.lcb` -> bump ABI if it changed -> add a smoke-test assertion ->
  rebuild + `tools/package-extension.py` to refresh the committed binary.

## C++-engine gotchas (NEW — our prior shims were C, so no precedent)

1. **Exceptions must never cross `extern "C"`** (the firewall, above) — asserted by a
   smoke test that forces a throw and checks it surfaces as an error code.
2. **No deterministic LCB unload hook.** Session threads cannot be torn down
   automatically. Expose `btStopSession` (pause → flush resume data → destroy → join) and
   **document that the app must call it** (e.g. on `closeStack`). Make it **idempotent**
   and **refuse a second concurrent session** while one is live.
3. **Never touch script from a libtorrent thread** — restated rule 1 for the C++ context;
   the only thread that ever calls into LCB is the engine's main thread, via polling.
4. **Boost is the build risk, not the binding.** Treat its headers as system headers;
   pin versions; stand up the CI matrix in Phase 0, not at the end.

## LiveCodeScript / LCB / OXT gotchas (carried; OXT is stricter than LiveCode)

1. **No smart/curly quotes** (U+201C/201D/2018/2019) anywhere — even in a comment or
   string — they fail OXT compilation. ASCII `"` and `'` only. The static checker
   enforces zero.
2. **Avoid names whose stem shadows an engine token** even when prefixed; prefer
   distinctive, multi-word stems. The nastiest case is a prefixed name whose
   *full spelling* IS a reserved token: `tExt` (t + "Ext" for extension) is
   literally `t-e-x-t` = `text`, so xTalk evaluates it as the `text` keyword, not
   a variable — it compiles and silently misbehaves. `tools/check-livecodescript.py`
   now flags this class (any `t/p/s/k`-prefixed name that lowercases to a reserved
   word); use a different stem (e.g. `tSuffix`).
3. **Prefix conventions:** `t` handler-local, `p` parameter, `s` script/module-local,
   `k` constant. Public API `btPascalCase`; C ABI `btx_snake_case`.
4. **Constants must be literal** and declared **before first use** (OXT resolves them by
   lexical position — a forward reference silently evaluates to nothing).
5. **`unsafe … end unsafe` brackets every foreign call** in LCB; keep all declarations
   at the **top** of a handler (a nested `local` has broken whole-script compilation).
6. **Commands report via `the result`; functions return a value.** Match the API shapes
   in the plan / api-reference (e.g. `btAddMagnet` is a command → `put the result into tH`).
7. `itemDelimiter` / `lineDelimiter` are global mutable state — set immediately before use.

## The single-threaded performance playbook (earned in OXT)

OXT runs script, the FFI, and rendering on ONE interpreted thread. The three real
costs, in order: **(1) interpreter ops, (2) FFI round-trips, (3) property-set
redraws.** The rules:

- **One FFI round-trip per poll.** The batched alert drain and the one-call status
  snapshot return a whole record per call — never one FFI call per event or per field.
- **Reuse a persistent buffer** in the poll hot path (`sDrain` / `sStatus`); rebuilding
  an N-byte `Data` every poll is O(N) interpreter work (the proven `midi.lcb` pattern).
- **One clock read per pass** — hoist `the milliseconds` out of loops.
- **UI/status text at <= ~4 Hz and only on change.** An every-frame field
  relayout+redraw is the biggest avoidable cost; a torrent dashboard refreshing 2–4×/s
  is plenty.
- **The poll interval is a latency/CPU knob**, documented as such.
- **Payload never crosses the FFI into script** (rule 3, above) — the gigabytes stay
  engine ⇄ disk.

## Example demos: cryptoXT dependency (the channels + quickshare demos)

The `torrent-dht-channels` and `torrent-quickshare` example demos do their **optional
encryption** through **cryptoXT** (the sibling `org.openxtalk.library.sodium` / SodiumXT
extension, libsodium), NOT OpenXTalk's built-in `encrypt using "aes-256-cbc"`. The flow is:
a passphrase derives a key with **Argon2id** (`sxPwHash`), the channel feed is sealed with
**`sxSecretBox`** (XSalsa20-Poly1305), and files are sealed with **`sxEncryptFile`**
(streaming `crypto_secretstream`, authenticated). The channels demo salts the KDF with the
channel's public key (so publisher and followers derive the same key); the quickshare demo
uses a random salt carried in the share code.

Consequences for anyone editing these demos:
- The encryption features **require cryptoXT to be installed** alongside the torrent
  extension. Each demo probes it once at startup (a guarded `sxSecretBox` round-trip in a
  `try`) into `sCanEncrypt`; when absent, the private/passphrase features fail closed with a
  clear "install org.openxtalk.library.sodium" message and **every other feature still
  works**. Never call an `sx*` handler outside an `sCanEncrypt` guard or a `try`.
- This was a deliberate "drop the weak AES path" decision. Data encrypted by the **old**
  AES format does **not** open in these versions (the feed marker moved `BTXENC1:` ->
  `BTXENC2:`); that breakage was accepted.
- KDF parameters (opslimit `"2"` + `sxPwMemInteractive()`) must stay **identical on both
  ends** or the derived keys differ. If you change them, change both sides and bump the
  on-wire format.

## Git / workflow

- Develop on the per-task branch (e.g. `claude/...`); commit there, open a **draft PR**
  if none exists. Don't push to `main` without explicit permission.
- A `.lcb` change is only "done" once `tools/check-livecodescript.py` passes; a shim
  change is only "done" once `torrent_smoke_test.cpp` passes under ASan/UBSan and (for
  an ABI change) `BTX_ABI_VERSION` + `checkABI()` are bumped together.
- A native-library change is only "done" once `tools/package-extension.py` has
  refreshed the committed `src/code/<arch>-<platform>/` binary **in the same change**
  (CI rebuilds and tests the full matrix).
- **Match the surrounding style** — this codebase (like its siblings) comments the
  *why*, densely; mirror that.
