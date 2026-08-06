# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in
this repository.

> Read `docs/architecture.md` for the design and `docs/api-reference.md` for the
> surface. This file is the operational as-built record and the hard-won-lesson
> list, in the same spirit as the `CLAUDE.md` files in the sibling extensions
> TorrentXT, Box2Dxt, and ShowControl. The original plan lives in TorrentXT's
> `docs/NEXT-EXTENSIONS-PLAN.md` Part IV ("libdatachannel — THE HARD ONE").

## What this is

**DataChannelXT** brings **WebRTC data channels** to OpenXTalk (OXT) / the xTalk
family: browser-interoperable, NAT-traversing (ICE/STUN/TURN), real-time P2P
messaging — reliable and unreliable modes — from xTalk script.

It is a binding to **libdatachannel** (C++17, MPL-2.0; vendored libjuice for ICE +
usrsctp for SCTP; DTLS via the system OpenSSL), wrapped behind a flat `extern "C"`
shim, with a thin LCB layer on top:

```
libdatachannel + libjuice + usrsctp (+ OpenSSL)   owns the network threads
   |- C++ shim     src/datachannel_shim.cpp  ->  datachannelxt.{so,dll,dylib}  (ABI: dcx_*)
        |- LCB binding  src/datachannel.lcb       (library org.openxtalk.library.datachannel; public dc*)
             |- script helpers  examples/datachannel-helpers.livecodescript  (the poll dispatcher)
```

The native library ships **bundled inside the extension** under
`src/code/<arch>-<platform>/datachannelxt.{so,dll,dylib}` (bare token, no `lib`
prefix; platform-ids `x86_64-linux` / `x86-linux` / `x86_64-win32` / `x86-win32` /
`universal-mac`, architecture first, Windows `-win32` for both bitnesses).

## The three rules that make this safe

1. **Never call an LCB handler from a libdatachannel (foreign) thread.** This is
   the family's rule 1 at its WORST CASE: libdatachannel fires every callback
   (descriptions, candidates, states, opens, messages) from its own worker
   threads. Every callback body in the shim does exactly one thing: take the one
   state mutex, push an owned copy of the event onto the bounded queue, release.
   `dcPoll` (`dcx_poll`) — the engine's single script thread, on a timer — drains
   that queue as a record list. **The mutex-guarded queue is the single most
   important correctness structure in this binding**, and the ThreadSanitizer CI
   lane exists to police it.
2. **The exception firewall — in BOTH directions.** Every `dcx_*` entry point is
   wrapped in the `DCX_GUARD_*` macros (a throw becomes a recorded error, never an
   unwind across `extern "C"` into the engine). And every CALLBACK body is wrapped
   in its own `try/catch(...)` so nothing we do (a `bad_alloc` copying a payload)
   can unwind back into libdatachannel's thread either.
3. **Payload across the FFI is allowed HERE by design — but bounded.** A data-
   channel message IS the payload. The budget is `DCX_MAX_MESSAGE` (60 000 bytes)
   both ways: sends over it are refused loudly (`DCX_ERR_TOO_LARGE`), never
   truncated or split silently; the shim advertises the cap in the SCTP
   negotiation so a compliant remote never exceeds it inbound; a misbehaving
   remote's oversized message is dropped WHOLE with an error event. Bulk transfer
   belongs to TorrentXT.

## THE LOCK DISCIPLINE (the lesson that cost a gdb session)

`rtcDeletePeerConnection` / `rtcDelete` **block until in-flight callbacks return**,
and our callbacks block briefly on the state mutex `g_mu`. Two consequences,
both load-bearing:

- **Never call an `rtc*` function while holding `g_mu`.** Entry points lock →
  validate/copy what they need → UNLOCK → call `rtc*`. An entry point that held
  the mutex across an rtc call could deadlock against a callback thread waiting
  for that same mutex (ABBA with libdatachannel's own locks — we watched it
  under gdb). Callbacks may call cheap rtc getters/setters (they are already on
  the rtc thread) but take `g_mu` only for the enqueue/table touch.
- **Clear every callback BEFORE every delete** (`clear_peer_callbacks` /
  `clear_channel_callbacks`). libdatachannel's C layer (capi.cpp) drops the
  object's LAST reference while holding its own global map mutex; the destructor
  of a still-connecting PeerConnection then fires the state callback inline,
  whose wrapper calls `getUserPointer`, which re-takes that same non-recursive
  mutex — **a self-deadlock inside the dependency**, reproduced under gdb at
  `rtcCleanup`. With our callbacks nulled first there is nothing to fire, and
  the nulling itself synchronizes with (joins) any invocation already running.
  This guard lives in `dcx_peer_free`, `dcx_channel_free`, and `dcx_cleanup` —
  keep it when adding any new teardown path.

## Event-ordering guarantees (pinned by the smoke test)

- **`E_CHANNEL_INCOMING` always precedes that channel's `E_CHANNEL_OPEN`.** The
  incoming event is enqueued in the SAME locked section that births the handle,
  BEFORE the open callback is wired and BEFORE the already-open fallback check.
  (The first implementation announced OPEN first when libdatachannel delivered
  an already-open channel — the app cannot know the handle yet at that point.
  The smoke test now pins the order.)
- The drain never reorders and never drops an event it accepted; events that
  name a since-freed handle are discarded AT DRAIN TIME (the app freed the
  handle — it declared it no longer cares). The queue is bounded (a safety
  valve for apps that stop polling): overflow sheds the NEWEST events, counts
  them, and reports the count in `E_QUEUE_OVERFLOW` once the backlog drains.
  The test invariant is **conservation**: delivered + reported-shed == sent.

## Commands

**Native shim + C++ tests** (the layer with the automated test suite):
```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DDATACHANNELXT_BUILD_TESTS=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure   # record_handle_test + datachannel_smoke_test
```
CMake acquires libdatachannel by FetchContent (pinned `GIT_TAG`, v0.24.5) with its
vendored submodules; DTLS from the system OpenSSL (`libssl-dev` / brew `openssl@3`
/ vcpkg). The dependency build is minutes, not the hours Boost/libtorrent cost
TorrentXT.

**The sanitizer lanes** — the `DATACHANNELXT_SANITIZE` knob is a STRING and
GLOBAL, injected before FetchContent so the whole static stack (libdatachannel,
libjuice, usrsctp) is instrumented too; per-target flags would leave the
dependency uninstrumented and TSan would false-positive on its internals:
```sh
cmake -S . -B build-asan -DDATACHANNELXT_BUILD_TESTS=ON -DDATACHANNELXT_SANITIZE=address
cmake -S . -B build-tsan -DDATACHANNELXT_BUILD_TESTS=ON -DDATACHANNELXT_SANITIZE=thread
# TSan run needs the suppressions file (usrsctp-internal races ONLY — scope rule inside):
TSAN_OPTIONS="halt_on_error=1:suppressions=$PWD/tests/tsan-suppressions.txt" \
  ./build-tsan/datachannel_smoke_test
```
gcc only (clang's sanitizer runtimes are not installed in this environment).
`address` and `thread` are mutually exclusive builds. **A shim change is only
"done" once the smoke test is green in BOTH lanes.** The TSan suppressions file
may only ever name races wholly inside a vendored dependency; a report with a
`datachannel_shim.cpp` frame among the RACING ACCESSES is ours and must be fixed.

**Record-schema golden test** (pure reference, runs anywhere):
```sh
python3 tests/record_golden_test.py
```

**Static gates for the script layer** (no headless OXT exists — catch what is
statically catchable):
```sh
python3 tools/check-livecodescript.py
python3 tools/check-record-registry.py    # registries + ABI sync + size budget
```
**Do not claim runtime behaviour you cannot observe** — say "verified statically;
needs an OXT pass" and let a human run `tests/datachannel-selftest.livecodescript`.

## FFI / C-ABI conventions (carried from the family, unchanged)

- **Handles are positive 32-bit ints** (`0` = invalid), generation-tagged, one
  table for peers and one for channels; a stale handle is a harmless no-op.
  libdatachannel's own C-API ints are NOT generation-tagged (a recycled id would
  alias), so they are never exposed — the shim maps rtc id <-> our handle, and
  events carry OUR ids, re-validated at drain.
- **Reals cross as `double`, booleans as `int` (0/1).** Exported symbols keep the
  stable `dcx_` prefix — never rename them; the `.lcb` binds reference the strings.
- **Byte buffers cross as `Pointer` + `CInt` length — an LCB `Data` does NOT
  auto-bridge to a `void*`.** Out-buffers use MCMemoryAllocate + bytes-written /
  `-needed` grow-and-retry; in-buffers pass `MCDataGetBytePtr`. `<builtin>`
  handlers carry no leading `_` (they resolve by name).
- **There is no 64-bit foreign int** (nothing in this surface needs one; the rule
  stands for additions — decimal `ZStringUTF8` strings).
- **Short strings cross as `ZStringUTF8`** (SDP, candidates, labels, errors).
- **The getter `-1` caveat**: `dcx_peer_state` / `dcx_gathering_state` /
  `dcx_channel_stream_id` / `dcx_buffered_amount` / `dcx_channel_max_message`
  return **-1** for "no value / bad handle" because 0 is a REAL value for each.
- **Bump `DCX_ABI_VERSION`** on any ABI change; `_checkABI()` throws on skew and
  `check-record-registry.py` enforces the header/.lcb match statically.
- **The record schema** is byte-identical to TorrentXT's (`[count:u16]` then
  `[fieldId:u8][type:u8][len:u16][bytes]`, big-endian; drain entries
  `[type:u16][bodyLen:u16][kvrecord]`). Registries are dcx's own and APPEND-ONLY;
  `record_golden_test.py` + `record_handle_test.cpp` pin the same literal bytes.
- **Adding a handler:** `dcx_*` in the shim (validate handle; `DCX_GUARD_*`; obey
  the lock discipline) -> `private foreign handler` + public `dc*` wrapper in the
  `.lcb` -> MSVC .def list in CMakeLists -> bump ABI if changed -> smoke-test
  assertion -> rebuild + `tools/package-extension.py` in the same change.

## C++ gotchas (paid for, again, this session)

1. **THE MACRO-COMMA TRAP struck again.** `std::vector<int> a, b, c;` at the top
   level of a `DCX_GUARD_*` body split the macro's arguments ("passed 3
   arguments"). One declaration per line inside guard macros — the preprocessor
   protects commas inside parentheses only.
2. **`*/` inside a C comment ends it** — twice: a comment narrating `rtcDelete*/
   rtcCleanup` and one narrating `PS_*/GS_*` both terminated early and turned
   prose into code. Spell it "rtcDelete and rtcCleanup" / "PS_ and GS_".
3. **libdatachannel buffer getters count the NUL** (`copyAndReturn` returns
   `size+1`, probe with NULL first); our ABI hides that (+1 never crosses).
4. **`rtcSendMessage(id, data, size)`: `size >= 0` is binary, `size < 0` is a
   NUL-terminated TEXT message** — the text/binary distinction a browser peer
   sees. `dcx_send_text` passes -1; don't "fix" it.
5. **Message callbacks with no callback set are buffered and FLUSHED when one is
   set** (`Channel::onMessage -> flushPendingMessages`), which is what makes the
   wiring window in `register_channel` lossless. Verified in the pinned tag's
   source; re-verify on a version bump.
6. **An IPv6-less container prints `juice: UDP socket creation failed, errno=97`**
   (EAFNOSUPPORT) and then works over IPv4 — harmless noise, not a failure.

## LiveCodeScript / LCB / OXT gotchas (carried; OXT is stricter than LiveCode)

1. **No smart/curly quotes anywhere** — they fail OXT compilation; ASCII only.
2. **Avoid names whose full spelling lowercases to a reserved token** (the `tExt`
   == `text` class); the static checker flags them.
3. **Prefixes:** `t` handler-local, `p` parameter, `s` script-local, `k` constant.
   Public API `dcPascalCase`; C ABI `dcx_snake_case`.
4. **Constants must be literal and declared before first use.**
5. **`unsafe ... end unsafe` brackets every foreign call**; ALL declarations at
   the top of a handler.
6. **Commands report via `the result`; functions return a value.**
7. `itemDelimiter` is global mutable state — set immediately before use.
8. **`dcPoll` is the ONE buffer call whose return is a COUNT, not bytes** (same
   as TorrentXT's `btPoll`); the walker reads the leading u16 and each entry's
   bodyLen, so the unused buffer tail is never touched.

## The single-threaded performance playbook (carried)

- **One FFI round-trip per poll** — `dcPoll` drains everything; never one call
  per event. Poll at 16-33 ms for real-time feel; the interval is a latency
  knob, never a correctness knob (the queue buffers between drains, bounded).
- **Reuse the persistent buffers** (`sDrainPtr`/`sScratchPtr`) — never rebuild
  per poll. UI text <= ~4 Hz and only on change.
- **Backpressure, not blasting:** check `dcBufferedAmount`, arm
  `dcSetBufferedLowThreshold`, stop sending until `dcBufferedLow`.

## The WebRTC model in one paragraph (what every demo must convey)

Everything is asynchronous and **signaling is the app's job**: create a peer,
create a channel (auto-negotiation makes the offer), ship each
`dcLocalDescription` / `dcLocalCandidate` event's payload to the far peer over
ANY existing channel (TorrentXT DHT, copy/paste, a server), feed the far side's
into `dcSetRemoteDescription` / `dcAddRemoteCandidate`, and wait for
`dcChannelOpen`. Non-trickle variant: wait for `dcGatheringStateChange` ==
complete, then ship `dcLocalDescription(peer)` as ONE blob (it then contains the
candidates). The loopback demo is the four-line proof; TURN is the fallback when
both NATs are hostile (credentials ride in the ICE-server URI — they are secrets
in ordinary memory, same caveat as the family's other secrets).

## The flagship demo (datachannel-dht-chat) - decisions that must hold

`examples/datachannel-dht-chat.livecodescript` pairs this extension with
TorrentXT: BEP44 mutable items carry the WebRTC handshake, then the chat rides
the direct channel. Its load-bearing decisions:

1. **The room code IS the keypair seed.** `btDhtKeypair` is deterministic on a
   64-hex seed, so the code is a shared write-capability for one DHT mailbox
   (both sides sign with the same key; salts "wx-o"/"wx-a" split the slots).
   Codes are minted fresh per Host click, so they are single-use and stale DHT
   leftovers can never belong to the current room. Document (not solve) that
   whoever knows a code can read the SDP blobs (they contain IPs).
2. **Non-trickle only.** A DHT round-trip is seconds; trickling candidates
   through it would be absurd. Publish ONE blob per side after
   `dcGatheringStateChange` == complete.
3. **The 1000-byte BEP44 budget** forces a wire format: head item
   `"DXC1" & kind & rest`, kind "D" = zlib(body) inline, kind "C" = comma list
   of 40-hex immutable-chunk targets (content-addressed = free integrity;
   republish lands on the same targets). Body = `nonce LF type LF sdp`; split
   on the FIRST TWO LFs only - the SDP is full of line breaks.
4. **The nonce pairs answer to offer.** Both sides dedup/reject on it, which
   is what makes Reconnect-under-the-same-code safe while stale items float
   around the DHT for hours. Seq also rises, but the nonce is the simpler,
   role-symmetric guard.
5. **The folder stays standalone.** The demo depends on TorrentXT's EXTENSION,
   never its example files - the bt poll loop is inlined (a dozen lines), and
   both extensions are probed at startup with guarded calls that fail closed
   (the family's cryptoXT pattern).
6. **One standing timer chain per loop**, armed once at start, rescheduling
   first and no-oping by phase. Arming chains per user action (Host/Join/
   Reconnect) stacks duplicates that double every poll and republish.

## Git / workflow

- Develop on the per-task branch; commit there; draft PR if none exists.
- A `.lcb` change is only "done" once `tools/check-livecodescript.py` AND
  `tools/check-record-registry.py` pass; a shim change once the smoke test is
  green under ASan/UBSan AND TSan; an ABI change once `DCX_ABI_VERSION` +
  `kABIVersion` moved together.
- A native-library change is only "done" once `tools/package-extension.py` has
  refreshed the committed `src/code/<arch>-<platform>/` binary in the same
  change (CI rebuilds and tests the full matrix; binaries land on main).
- **Match the surrounding style** — comment the *why*, densely.
