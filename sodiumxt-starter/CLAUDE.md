# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in
this repository.

> **Read `docs/SodiumXT-IMPLEMENTATION-PLAN.md` first.** It is the full spec (the engine
> decision, the C ABI design, the phased plan, the test strategy, the risk register). This
> file is the operational as-built record and the hard-won-lesson list, in the same spirit
> as the `CLAUDE.md` files in our sibling extensions Box2Dxt, ShowControl, and TorrentXT.
> Most of the FFI and OXT/LCB lessons below were paid for in full while building TorrentXT;
> they are copied here so we do not pay for them twice.

## What this is

**SodiumXT** opens **modern cryptography** to OpenXTalk (OXT) / the xTalk family (also
LiveCode 9.6.3+): authenticated encryption, password hashing (Argon2id), streaming AEAD
for big files, public-key boxes and ed25519 signatures, hashing, and a real CSPRNG, all
from xTalk.

It is a binding to **libsodium** (C, ISC license), wrapped behind a flat `extern "C"` shim
(libsodium is already C, so the shim is thin: it is a marshaling layer, not a translation
layer), with a thin LCB layer on top:

```
libsodium (ISC) - portable, audited, NaCl lineage; pure compute, no threads, no I/O of its own
   |- C shim     src/sodium_shim.c   ->  sodiumxt.{so,dll,dylib}  (ABI symbols: sxt_*)
        |- LCB binding  src/sodium.lcb        (library org.openxtalk.library.sodium; public sx*)
             |- script helpers  examples/sodium-helpers.livecodescript
```

The native library ships **bundled inside the extension** under
`src/code/<arch>-<platform>/sodiumxt.{so,dll,dylib}` (bare token, no `lib` prefix;
platform-ids `x86_64-linux` / `x86-linux` / `x86_64-win32` / `x86-win32` / `universal-mac`,
**architecture first**, Windows `-win32` for both bitnesses). Installing the packaged
extension makes the engine resolve the `c:sodiumxt>` binding via `the revLibraryMapping`
automatically: no loose library, no `sudo`, no `/usr/lib`, no `LD_LIBRARY_PATH`, no rename.

The C ABI is **engine-agnostic**: if we ever swap libsodium for monocypher (single-file,
smaller), the same `sxt_*` surface is reproduced and the LCB layer is untouched.

The prefixes here (`sxt_` C ABI, `sx*` public LCB, `sodiumxt` token) mirror TorrentXT's
(`btx_`, `bt*`, `torrentxt`). They are conventions, not law; if you rename them, rename
them everywhere in one pass and keep the `binds to "c:sodiumxt>sxt_..."` strings in step.

## How SodiumXT differs from TorrentXT (read this before you assume)

TorrentXT wrapped a C++ engine that owns network and disk threads. SodiumXT wraps a C
library that owns **nothing**: no threads, no sockets, no files of its own, no callbacks.
That flips three of TorrentXT's defining rules. Do not cargo-cult them.

1. **No background threads, no alert queue, no polling.** Every `sxt_*` call is synchronous,
   one-shot, bytes-in/bytes-out. There is no session to start or stop, no `btPoll`, no
   `send ... in N milliseconds` dispatcher. The whole poll-drain architecture is GONE.
2. **Payload DOES cross the FFI here. That is the entire job.** TorrentXT's rule 3 ("payload
   never crosses the FFI into script") is INVERTED: SodiumXT exists to take bytes from
   script, transform them, and hand them back. So the new rule is **mind the size** (see the
   performance playbook): a small `Data` round-trips in one call; a large file uses the
   **streaming (secretstream) API and the C-side file helpers** so the plaintext and the
   ciphertext are never both fully resident in script memory.
3. **No C++ exception firewall is needed** (libsodium is C and does not throw). It is
   replaced by a **length-and-pointer firewall**: a wrong length or a short buffer in C is a
   memory-corruption bug, not a thrown exception, so every entry point validates the
   caller's buffer and refuses to read or write past it.

## The rules that make this safe

1. **Validate every length and pointer at the boundary; never touch memory past the
   caller's buffer.** An out buffer that is too small returns `-needed` (negative required
   size), never a partial write past the end. A null pointer or a bad handle is a defined
   no-op / error code, never a crash. This is the C analogue of TorrentXT's exception
   firewall, asserted by a smoke test that feeds short buffers and bad handles to every
   entry point.
2. **`sodium_init()` exactly once, before anything else.** Call it at first use (guarded by
   a static flag) and check its return. Until it has run, the CSPRNG and the runtime CPU
   feature detection are not ready. It is safe to call again; it is not safe to skip.
3. **Never reuse a nonce with the same key.** For these ciphers a repeated nonce is
   catastrophic (it leaks plaintext relationships and can destroy authenticity). The API
   surface is designed so misuse is hard: one-shot calls **generate a fresh random nonce and
   prepend it** to the ciphertext; file and stream encryption use **secretstream**, which
   derives per-chunk nonces internally from a random header. Do not expose a "bring your own
   nonce" entry point without a very loud reason.
4. **Authenticate everything. Compare in constant time.** Use the AEAD / `_easy` / `secretbox`
   / `secretstream` forms (which carry a Poly1305 tag), never a raw unauthenticated stream
   cipher. Verify tags and password hashes with `sodium_memcmp` / the library's own verify
   calls; **never** compare a MAC, tag, or hash in script with `is` (that is a timing leak).
5. **Zero secret material when you are done with it (C-side), and be honest about what you
   cannot protect.** Use `sodium_memzero` on transient key/scratch buffers in the shim. Be
   honest in the docs that a key living in a LiveCode `Data` cannot be `mlock`ed or reliably
   zeroed by us; secure-memory guarantees stop at the FFI line.

## Commands

**Native shim + C tests** (the layer with the automated suite):
```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSODIUMXT_BUILD_TESTS=ON
cmake --build build --config Release
ctest --test-dir build --output-on-failure        # sodium_smoke_test.c (incl. known-answer tests)
```
CMake acquires libsodium at a **pinned version** and static-links it into ONE shared library
named with the **bare token** `sodiumxt` (`PREFIX ""`, `OUTPUT_NAME sodiumxt`). See
`docs/building.md`.

**Always build the shim under sanitizers while iterating** (use **gcc**; clang's ASan
runtime is not installed in this environment). A crypto binding is exactly where an
off-by-one in buffer sizing hides, so ASan is not optional:
```sh
gcc -std=c11 -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=all \
  -isystem <libsodium-include> \
  src/sodium_shim.c tests/sodium_smoke_test.c <link libsodium> -o /tmp/sx && /tmp/sx
```
Treat libsodium headers as **system headers** (`-isystem`) so their warnings do not pollute
our `-Wall -Wextra` (our code stays warning-clean; `/W3` on MSVC).

**Static gates for the script layer.** OXT is a GUI runtime: there is **no headless way to
compile or run `.lcb` / `.livecodescript`**. Catch what is statically catchable first by
**porting TorrentXT's checker verbatim**:
```sh
python3 tools/check-livecodescript.py
```
It checks every `.lcb` and example for smart/curly quotes, handler balance, control-structure
and `unsafe` balance, constant-declared-before-use, and the prefixed-token-shadow trap (rule
2 below). **Do not claim runtime behaviour you cannot observe:** say "verified statically;
needs an OXT pass" and let the user confirm.

## FFI / C-ABI conventions (the gold, carried verbatim from Box2Dxt + ShowControl + TorrentXT)

This section is the single most expensive thing we learned. Change nothing here without a
very good reason.

- **Byte buffers cross as `Pointer` + `CInt` length. An LCB `Data` does NOT auto-bridge to a
  `void*`.** This cost a runtime `expected type pointer` error in TorrentXT. The Language
  Reference is explicit: "No automatic bridging from Data or String to Pointer exists"; a
  `Data` marshals as an opaque `MCDataRef`. So, matching the proven htmltidy / HIDAPI /
  TorrentXT bindings:
  - An **out** buffer (the shim fills it: ciphertext, derived key, signature, random bytes)
    is a raw block from the engine `<builtin>` `MCMemoryAllocate`, passed as a real
    `Pointer`. The shim returns **bytes written**, or **`-needed`** if the block was too
    small; the LCB layer then re-allocates and retries, and copies the written bytes back
    with `MCDataCreateWithBytes`.
  - An **in** buffer (plaintext, key, nonce, the .enc on the way back) passes
    `MCDataGetBytePtr(theData)` (the read-only pointer to the Data's own bytes) plus its
    length.
  - A `<builtin>` handler resolves by its **name** matching the engine symbol, so those
    handlers carry **no leading `_`** (renaming them breaks the bind). Our own foreign
    handlers keep the `_sxt_*` private-name convention.
- **There is no 64-bit foreign int.** Lengths and counts that can exceed 2^31 (file sizes,
  `opslimit`, `memlimit`) cross as **decimal `ZStringUTF8`** strings, parsed in the shim.
- **Reals cross as `double`, booleans as `int` (0/1).** Exported C ABI symbols keep the
  stable `sxt_` prefix; never rename them once shipped (the `.lcb` `binds to "c:sodiumxt>..."`
  strings reference them).
- **Never return a library-owned `const char*`** of unknown lifetime. Fill a caller buffer,
  or return a defined-lifetime static the engine copies immediately. Return `""`, never
  `NULL`, on a bad handle / error.
- **Short strings cross as `ZStringUTF8`** (hex, base64, the password hash string, error
  text, the library version).
- **Bump `SXT_ABI_VERSION`** on any ABI change; the `.lcb` `checkABI()` throws a clear error
  on skew instead of corrupting memory on first use.
- **Expose every length constant from the shim** (`sxt_secretbox_keybytes()`,
  `sxt_secretbox_noncebytes()`, `sxt_pwhash_saltbytes()`, ...). The LCB layer must NOT
  hardcode 24/32/16; libsodium is allowed to change them across versions, and a hardcoded
  length is a buffer overflow waiting to happen.

## Handles for the stateful primitives

Most of libsodium is stateless (one call, no object). A few primitives are **multi-step and
hold state** across calls: `crypto_secretstream_*` (the streaming AEAD), multipart
`crypto_generichash_*`, and multipart `crypto_sign_*`. Their state structs are opaque and
must NOT be round-tripped through script.

- Keep the state struct **C-side**, in a **generation-tagged handle table** (positive 32-bit
  ints, `0` = invalid), exactly like TorrentXT's session/torrent tables. Script holds only
  the handle int; a stale or recycled handle is a **harmless no-op / error**, never a crash.
- Provide an explicit free (`sxFreeStream`, etc.) and call it; there is **no deterministic
  LCB unload hook**, so document that the app must free what it opens (e.g. on `closeStack`),
  make free **idempotent**, and zero the state on free.

## C-engine gotchas (vs our C++ TorrentXT shim)

1. **No exceptions to firewall** (libsodium is C). The firewall is the length/pointer
   validation above, asserted by a smoke test.
2. **No deterministic unload hook.** Mostly fine because we are mostly stateless; the
   exception is open stream/hash states (free them, above).
3. **`sodium_init()` once** (rule 2). Wrap it in the shim behind a static guard so every
   public entry can call `ensure_init()` cheaply.
4. **Constant-time and zeroing are behaviours, not decorations.** `sodium_memcmp`,
   `sodium_memzero`. A "tidy-up later" attitude here is a security bug.

## LiveCodeScript / LCB / OXT gotchas (carried; OXT is stricter than LiveCode)

1. **No smart/curly quotes** (U+201C/201D/2018/2019) anywhere, even in a comment or string:
   they fail OXT compilation. ASCII `"` and `'` only. The static checker enforces zero.
2. **Avoid names whose stem shadows an engine token** even when prefixed. The nastiest case
   is a prefixed name whose *full spelling* IS a reserved token: `tExt` (t + "Ext") is
   literally `t-e-x-t` = `text`, so xTalk evaluates it as the `text` keyword, not a variable.
   It compiles and silently misbehaves. The checker flags any `t/p/s/k`-prefixed name that
   lowercases to a reserved word; use a different stem (e.g. `tSuffix`).
3. **Prefix conventions:** `t` handler-local, `p` parameter, `s` script/module-local, `k`
   constant. Public API `sxPascalCase`; C ABI `sxt_snake_case`.
4. **Constants must be literal** and declared **before first use** (OXT resolves them by
   lexical position; a forward reference silently evaluates to nothing).
5. **`unsafe ... end unsafe` brackets every foreign call** in LCB; keep all declarations at
   the **top** of a handler (a nested `local` has broken whole-script compilation).
6. **Commands report via `the result`; functions return a value.** Match the API shapes in
   the plan / api-reference.
7. **`itemDelimiter` / `lineDelimiter` are global mutable state**: set them immediately
   before use.
8. **`is a <type>` only accepts** number / integer / boolean / point / rect / date / color.
   There is **no `is a string`**. To sniff bytes, check length / content, not a type.
9. **Crypto-specific script rules:**
   - The CSPRNG is `sxRandomBytes` (libsodium `randombytes_buf`). **Never** use `random()`
     for anything that needs to be unguessable.
   - Compare secrets with `sxMemEqual` (constant-time), **never** `is` / `=`.
   - A passphrase crosses as a `ZStringUTF8` and is `textEncode(...,"UTF-8")`d before
     hashing; pin the encoding so the same passphrase derives the same key on every machine.

## The single-threaded performance playbook (earned in OXT, adapted for "payload crosses")

OXT runs script, the FFI, and rendering on ONE interpreted thread. Here payload crosses the
FFI, so the costs are: **(1) FFI round-trips, (2) copying big `Data` blocks, (3) interpreter
ops.** The rules:

- **One FFI round-trip per logical operation.** Encrypt a buffer in one call, not one call
  per 16 bytes. The out-buffer retry (`-needed` then re-allocate) costs at most one extra
  call.
- **For anything that does not comfortably fit in memory twice, do NOT pull it through
  script.** Use the **C-side file helpers** (`sxEncryptFile path -> path`,
  `sxDecryptFile`) built on secretstream: libsodium reads the file, encrypts chunk by chunk,
  and writes the output, and the bytes **never enter a LiveCode `Data` at all**. This is the
  direct lesson from TorrentXT's chunked-file code, done properly: there, script hand-rolled
  4 MiB chunks and AES-CBC framing; here the loop lives in C and the cipher carries its own
  per-chunk auth and ordering.
- **Reuse a persistent out-buffer** in any hot path; rebuilding an N-byte `Data` every call
  is O(N) interpreter work.
- **The crypto is blocking** (pure compute, no threads). A big `crypto_pwhash` (Argon2id at
  SENSITIVE limits) or a large file can pause the UI for a noticeable beat. Document it as a
  cost, offer the INTERACTIVE/MODERATE/SENSITIVE preset as the latency knob, and keep
  status-text updates at <= ~4 Hz.

## Crypto correctness rules (the part a binding most easily gets wrong)

- **Nonce: never reuse one with a key.** Prefer the APIs that manage nonces for you
  (one-shot prepend, or secretstream). Rule 3, restated because it is the one that bites.
- **KDF: Argon2id via `crypto_pwhash`, never a fast hash, for passwords.** Store the
  `opslimit` / `memlimit` / salt alongside the ciphertext (or use `crypto_pwhash_str`, which
  packs them into its output) so you can re-derive and so you can raise the cost later
  without breaking old data.
- **AEAD over plain ciphers.** Always carry the Poly1305 tag; reject on tag failure and tell
  the caller "wrong key or tampered", never silently return garbage.
- **secretstream for files**: it gives per-chunk authentication, ordering, and a FINAL tag
  that makes **truncation detectable** (a cut-off file fails to verify). Hand-rolled chunk
  framing does not get this for free.
- **Random via the CSPRNG only**; salts, nonces, and keys come from `randombytes_buf`.
- **Zero and constant-time** as above.

## Git / workflow

- Develop on the per-task branch (e.g. `claude/...`); commit there, open a **draft PR** if
  none exists. Do not push to `main` without explicit permission.
- A `.lcb` change is only "done" once `tools/check-livecodescript.py` passes; a shim change
  is only "done" once `sodium_smoke_test.c` passes under ASan/UBSan and (for an ABI change)
  `SXT_ABI_VERSION` + `checkABI()` are bumped together.
- A native-library change is only "done" once `tools/package-extension.py` has refreshed the
  committed `src/code/<arch>-<platform>/` binary **in the same change** (CI rebuilds and
  tests the full matrix).
- **No em-dashes** in committed prose or docs (house style). Use hyphens, commas, colons,
  parentheses.
- **Match the surrounding style:** this codebase, like its siblings, comments the *why*,
  densely. Mirror that.
