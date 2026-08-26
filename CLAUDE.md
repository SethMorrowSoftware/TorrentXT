# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in the TorrentXT member of the xtalk-suite monorepo (`torrentxt/`).

> **Read `docs/archive/TorrentXT-IMPLEMENTATION-PLAN.md` first** — it is the full spec (the
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

> **Engine BEHAVIOUR - as opposed to the conventions below - is collected in
> [`docs/OXT-ENGINE-NOTES.md`](../docs/OXT-ENGINE-NOTES.md)**, with the verbatim
> symptom, what each one broke, and whether a gate now holds it. Keep
> member-specific gotchas here; put anything the ENGINE does there, so there is
> one authoritative list instead of six that drift.


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

## Example demos: SodiumXT dependency (the channels + quickshare demos)

> **RENAMED 2026-08-17: this was written as "cryptoXT" throughout, and that name
> shipped to users.** 216 occurrences across 20 files told people to install
> cryptoXT - an extension that does not exist and never did. The id in the same
> sentences was always `org.openxtalk.library.sodium`, so nothing was broken;
> the demos simply named the dependency wrongly, and a tester reasonably read it
> as a deprecated component they were missing. Every occurrence is now SodiumXT.
> Reported from an engine session, which is the only place the wrong name was
> ever going to be read.

> **CORRECTED 2026-08-19: "Every occurrence is now SodiumXT" was untrue on the
> day it was written.** Measured against the whole tree rather than the diff:
> the pass changed 216 occurrences across 20 files, and 229 across 25 files
> existed - so both figures above are the size of the CHANGE, not the size of
> the problem. The 13 it missed were exactly the paths the sweep did not walk:
> nine in `nocloud/` (`LICENSE`, `site/index.html`, `webapp/app.js`) and four
> in `torrentxt/`. Two of the nine are the class this rename existed to kill -
> a string built into `innerHTML` and served to a user's browser, and a
> standalone-builder instruction naming the extension to include - so the wrong
> name outlived its own removal in the one place a stranger reads it. The nine,
> plus `src/torrent.lcb`'s "(e.g. cryptoXT/SodiumXT)" and
> `tests/bep44_golden_test.py`'s "a SodiumXT/cryptoXT identity key", were
> corrected on 2026-08-19. The two that remain are deliberate: the provenance
> citations at `tests/bep44_golden_test.py:18` and `:31` name the pre-suite
> cryptoXT repo a pinned vector came from, and dated provenance is annotated,
> never rewritten.
>
> The lesson is worth more than the fix. The pass counted the occurrences it
> CHANGED and reported that as the occurrences that EXISTED - the same shape as
> coinxt's constant gate printing the constants it had parsed as the ones it had
> checked, and as the "shipped is not run" trap in the suite CLAUDE.md. A
> completion claim ("every occurrence") is a claim about the whole tree, so it
> has to be measured against the whole tree; the diff can only ever tell you how
> much you did, never how much there was.

The `torrent-dht-channels` and `torrent-quickshare` example demos do their **optional
encryption** through **SodiumXT** (the sibling `org.openxtalk.library.sodium`
extension, libsodium), NOT OpenXTalk's built-in `encrypt using "aes-256-cbc"`. The flow is:
a passphrase derives a key with **Argon2id** (`sxPwHash`), the channel feed is sealed with
**`sxSecretBox`** (XSalsa20-Poly1305), and files are sealed with **`sxEncryptFile`**
(streaming `crypto_secretstream`, authenticated). The channels demo salts the KDF with the
channel's public key (so publisher and followers derive the same key); the quickshare demo
uses a random salt carried in the share code.

Consequences for anyone editing these demos:
- The encryption features **require SodiumXT to be installed** alongside the torrent
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

## The Quick Share lineage: this member's demo is nocloud's UPSTREAM

`examples/torrent-quickshare.livecodescript` and
`nocloud/src/nocloudquickshare.livecodescript` share an ancestor and most of a
handler surface, and neither file says so. Measured 2026-08-17: the demo defines
**148** `qs*` handlers, nocloud **229**, of which **144 are shared** - so nocloud
is very close to a strict superset, and the demo's only unique handlers are the
four that ARE the demo (`qsBar`, `qsBrowseFile`, `qsToggleTor`,
`qsToggleWebShare`).

**Direction matters and is easy to get backwards:** this demo is the in-repo
ORIGINAL. The dashboard was spun out standalone, grew the hardened HTTP/Tor
server and the web app, and was folded back into the monorepo at `nocloud/` on
2026-08-13. So a fix made here does NOT reach nocloud, and a fix made there
usually should be considered here - 144 handlers deep, a defect in one is
overwhelmingly likely to exist in the other. The 2026-08-17 HEAD-method defects
found in nocloud's route table are exactly that shape.

> **Recorded because an audit got this wrong in a way worth keeping.** A survey
> reported that "the only mention of nocloud anywhere in torrentxt is an
> incidental comment", and concluded the relationship was unrecorded. It is
> recorded - `examples/README.md` carries an explicit paragraph naming the spin-out
> and the fold, and calling this demo "the in-repo original". What was missing was
> a pointer from the ENGINEERING notes, which is where someone about to change one
> of those 144 handlers actually looks. Absence from the place you searched is not
> absence from the tree.

**libtorrent 2.1 REMOVED the `create_torrent(file_storage&)` constructor, and the Windows
vcpkg lanes met it first (2026-08-23).** Both `native-torrentxt.yml` Windows jobs went red at
`torrent_shim.cpp`'s `btx_create_torrent` on a script-only commit: vcpkg had rolled
libtorrent to 2.1, whose create_torrent overhaul replaces the `file_storage` scan
(`add_files`) with `std::vector<create_file_entry>` (`lt::list_files`). The shim now carries
both branches behind `#if LIBTORRENT_VERSION_NUM >= 20100`, with MSVC's own candidate list
from the failing run as the authority for the new signature. Evidence split, stated
honestly: the 2.0 branch is EXECUTED here (apt libtorrent 2.0.10, ASan/UBSan, all three
ctests green - the sanitize lane's exact recipe) and is byte-identical source to what the
committed binaries were built from, which is why they are NOT refreshed in this change (the
preprocessor selects the same code at the 2.0.11 pin; `check-binary-freshness.py` green);
the 2.1 branch is COMPILE-PROVEN by the Windows CI lanes only and has never executed
anywhere. If the pinned FetchContent tag or the apt/brew packages ever roll to 2.1, the
smoke test's create-torrent leg is the first thing to run before trusting a binary from
that build.

**THE FIRST VERSION OF THAT FIX WAS WRONG TWICE, AND BOTH WAYS ARE THE LESSON
(2026-08-23, same day, second push).** The Windows lanes went red again, and the fuller
log told a story the first 60-line tail had hidden. One: a preprocessor directive inside
a macro ARGUMENT is ill-formed, and every `btx_*` entry body is a `BTX_GUARD_*` macro
argument - gcc happens to accept `#if` there, MSVC refuses it (C2121), so the guard that
passed the local sanitizer build could never have compiled on Windows. Version
conditionals now live only at file scope (`btx_peer_endpoint`, `btx_file_layout`, and
`btx_build_torrent_blob`, which owns the whole create-torrent body). Two: tailing 60
lines of a failed build showed the LAST error and hid three more 2.1 removals at lower
line numbers - `peer_info::ip` (2.1: `remote_endpoint()`), `torrent_info::files()` (2.1:
`layout()`), and the `torrent_info` from-buffer ec-constructor in BOTH `.torrent` add
paths. That last one needed no guard at all: `lt::load_torrent_buffer` exists from
2.0.10 on, so one spelling serves both generations, and its throwing overload sits in a
local try so a malformed `.torrent` still reports "invalid .torrent" instead of riding
the generic firewall. The verification that should have happened the first time now
has: the RC_2_1 header tree was fetched and the WHOLE shim compiled against it with the
deprecated surface off (`g++ -fsyntax-only -DTORRENT_ABI_VERSION=4`, 0 errors) - which
is what found the two `.torrent` sites MSVC's own error cascade had masked - alongside
the 2.0 path executing green under ASan/UBSan (the smoke test drives
`load_torrent_buffer` on both the refusal and success legs). Because this round changes
code that compiles at the 2.0.11 pin (unlike the first, preprocessor-identical round),
the committed Linux binaries ARE refreshed in this change per rule 5; the Windows DLLs
stay at their recorded needs-the-next-dispatch state. (Precision for the 2026-08-24
Windows engine pass, which ran torrentxt green at 101/101 in the suite paste: that run
executed the COMMITTED pre-change DLLs - a reconfirmation of the old parse path - so the
load_torrent_buffer spelling is engine-proven NOWHERE yet; its first engine contact will
be a Linux pass over the rebuilt .so, or Windows after the next release dispatch.)

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
