# SodiumXT Implementation Plan

The full spec for **SodiumXT**, a libsodium binding for OpenXTalk (OXT) / the xTalk family.
Read this before writing code. The operational as-built record and the hard-won-lesson list
live in `CLAUDE.md`; this document is the design, the phased plan, the test strategy, and the
risk register.

House style note: no em-dashes (hyphens, commas, colons, parentheses instead).

---

## 0. Purpose and context

TorrentXT (our BitTorrent binding) shipped optional encryption built on OXT's stock
`encrypt ... using "aes-256-cbc" with password`. That works, but it has two real weaknesses
we promised publicly to fix:

1. The key derivation under that call is OpenSSL's old `EVP_BytesToKey` (a single MD5 pass
   over the password and an 8-byte salt). It is weak against a brute-force attack on a poor
   passphrase. It is not Argon2, scrypt, or even PBKDF2.
2. AES-256-CBC provides confidentiality but **no authentication tag**. Integrity in
   TorrentXT is borrowed from the surrounding layers (BitTorrent piece hashes, the ed25519
   feed signature), not from the cipher itself. A standalone "encrypt this Data" call from
   that primitive is malleable.

**SodiumXT** is the fix, and more: a reusable OXT extension that brings the modern libsodium
toolbox to any xTalk app. Authenticated encryption (XChaCha20-Poly1305 / XSalsa20-Poly1305),
Argon2id password hashing, a streaming AEAD purpose-built for large files, X25519 public-key
boxes, ed25519 signatures (the same primitive BitTorrent's BEP44 uses, so keys can
interoperate with TorrentXT channels), BLAKE2b hashing, and a real CSPRNG.

The north star: TorrentXT (and anything else in the family) replaces its hand-rolled crypto
with `sx*` calls, and gets authenticated, modern, correctly-nonced encryption for free.

## 1. Engine decision: libsodium

**Chosen: libsodium**, pinned to a released version (start at the current stable; record the
exact tag in CMake). Rationale:

- **Right primitives, hard to misuse.** secretbox, AEAD, secretstream, pwhash (Argon2id),
  box, sign, generichash, kx. The "easy" and "secretstream" interfaces are designed so the
  caller does not hand-roll nonces or modes.
- **C ABI, stable, portable.** No C++, so no exception firewall and no name mangling across
  the FFI. Builds on every target in our matrix.
- **Audited lineage** (NaCl / TweetNaCl heritage; libsodium itself has been audited).
- **Permissive license** (ISC), compatible with bundling inside the extension.

Alternatives considered and rejected for the first cut:

- **OpenSSL EVP directly:** heavier to build and bundle, and far easier to misuse (this is
  what we are migrating away from).
- **monocypher:** attractively tiny (single file, public domain) and a plausible *future*
  swap behind the same `sxt_` ABI, but fewer batteries (no Argon2id `pwhash_str`, no
  base64/hex helpers, no `secretstream`). Keep it in mind as the engine-agnostic fallback,
  do not start there.
- **Tink / BoringSSL:** too heavy for an embeddable single-shared-library extension.

The C ABI is deliberately engine-agnostic so monocypher (or raw OpenSSL) could be slotted in
later without touching the LCB layer.

## 2. Architecture

Three layers, same shape as TorrentXT:

```
libsodium (static)                      pure compute: no threads, no sockets, no files of its own
   |- C shim     src/sodium_shim.c   ->  sodiumxt.{so,dll,dylib}   (ABI: sxt_*)
        |- LCB binding  src/sodium.lcb       (library org.openxtalk.library.sodium; public sx*)
             |- script helpers  examples/sodium-helpers.livecodescript
```

- The shim is a **marshaling layer**: validate lengths and pointers, call libsodium, return
  bytes-written or an error code. It adds no crypto logic of its own.
- The native lib is **bundled** under `src/code/<arch>-<platform>/sodiumxt.{so,dll,dylib}`
  (bare token, architecture-first platform ids; see CLAUDE.md). `the revLibraryMapping`
  resolves `c:sodiumxt>` on install.
- Because libsodium owns no threads or I/O, there is **no session lifecycle, no poll loop,
  no alert queue**. This is a much smaller surface than TorrentXT.

## 3. The C ABI design

- **Naming:** `sxt_snake_case` for every exported symbol. `SXT_API` / `SXT_CALL` macros for
  visibility and calling convention (copy TorrentXT's). `SXT_ABI_VERSION` integer, returned
  by `sxt_abi_version()`, checked by the LCB `checkABI()`.
- **Buffers (the core convention, see CLAUDE.md for the full rationale):**
  - out: caller passes an `MCMemoryAllocate` block as `Pointer` + capacity; shim returns
    bytes written, or `-needed` if too small. LCB retries once at the required size.
  - in: caller passes `MCDataGetBytePtr` + length.
  - `<builtin>` allocator handlers (`MCMemoryAllocate` / `MCMemoryDeallocate`) carry **no
    leading underscore**; our foreign decls are `_sxt_*`.
- **64-bit values** (`opslimit`, `memlimit`, file sizes) cross as **decimal `ZStringUTF8`**,
  parsed in the shim. No 64-bit foreign int exists.
- **Length constants** are functions (`sxt_secretbox_keybytes()` etc.), never hardcoded in
  LCB.
- **Error model:** every entry returns an int status (0 ok, negative error). On error the
  shim sets a thread-local message retrievable via `sxt_last_error()` (returns `""` when
  clean). The LCB wrapper surfaces it through `sxLastError()`.
- **Stateful objects** (secretstream, multipart hash/sign) live in a **generation-tagged
  handle table** (positive 32-bit ints, `0` invalid, stale = no-op). One table per kind, or
  one tagged table with a type byte. Explicit free per object.
- **Init:** an internal `ensure_init()` calls `sodium_init()` once behind a static guard;
  every public entry calls it first.

## 4. The capability surface (what to wrap)

Grouped by phase (Section 5 sequences them). Names are indicative; finalize in the
api-reference.

**Util / init**
- `sxInit` (idempotent; also auto-run on first use), `sxVersion`.
- `sxRandomBytes(n)` -> Data (CSPRNG; `randombytes_buf`). The only source of salts/nonces/keys.
- `sxBin2Hex` / `sxHex2Bin`, `sxBin2Base64` / `sxBase642Bin` (`sodium_*` encoders; pick the
  URL-safe-no-padding variant for share codes).
- `sxMemEqual(a, b)` -> Boolean (constant-time `sodium_memcmp`).
- `sxPad` / `sxUnpad` (optional; `sodium_pad`, to hide message length).

**Hashing**
- `sxHash(data, outLen)` -> Data (`crypto_generichash`, BLAKE2b; default 32 bytes, keyed
  optional).
- multipart `sxHashInit` / `sxHashUpdate` / `sxHashFinal` (handle-based) for streaming hash.

**Password hashing / KDF**
- `sxPwHash(passphrase, saltData, keyLen, limits)` -> Data (`crypto_pwhash`, Argon2id;
  derive a symmetric key from a passphrase). `limits` selects INTERACTIVE / MODERATE /
  SENSITIVE (`opslimit`/`memlimit` presets), the latency/strength knob.
- `sxPwHashStr(passphrase, limits)` -> String, `sxPwHashStrVerify(hash, passphrase)` ->
  Boolean (`crypto_pwhash_str*`, for storing/verifying passwords; the string self-describes
  its params).
- `sxKdfDerive(masterKey, subkeyId, context)` -> Data (`crypto_kdf_derive_from_key`).

**Secret-key authenticated encryption (one-shot)**
- `sxSecretBox(message, key)` -> Data and `sxSecretBoxOpen(box, key)` -> Data, where the
  shim **generates a random nonce and prepends it** to the output (so the caller never
  handles a nonce, rule 3). XSalsa20-Poly1305. Open returns error on tag failure.
- `sxAeadEncrypt` / `sxAeadDecrypt` with associated data
  (`crypto_aead_xchacha20poly1305_ietf_*`), same prepend-nonce discipline, when the caller
  needs to bind a header (AD) to the ciphertext.

**Streaming AEAD (the big-file workhorse)**
- `sxSecretStreamInitPush(key)` -> {handle, header}; `sxSecretStreamPush(handle, chunk, ad,
  isFinal)` -> cipherChunk; `sxSecretStreamInitPull(key, header)` -> handle;
  `sxSecretStreamPull(handle, cipherChunk, ad)` -> {plainChunk, tag};
  `sxFreeStream(handle)`. `crypto_secretstream_xchacha20poly1305_*`: per-chunk auth,
  ordering, and a FINAL tag that makes truncation detectable.
- **C-side file helpers (preferred for large files):** `sxEncryptFile(srcPath, dstPath,
  key)` and `sxDecryptFile(srcPath, dstPath, key)`. libsodium streams the file chunk by
  chunk inside the shim; the bytes never enter a LiveCode `Data`. This is the proper
  replacement for TorrentXT's hand-rolled 4 MiB AES-CBC chunk framing.

**Public-key**
- `sxBoxKeypair` -> {publicKey, secretKey} (X25519). `sxBox(message, recipientPk, senderSk)`
  / `sxBoxOpen(...)` (authenticated, prepend-nonce). `sxSeal(message, recipientPk)` /
  `sxSealOpen(box, pk, sk)` (anonymous sender; `crypto_box_seal`).
- `sxSignKeypair` -> {publicKey, secretKey} (ed25519). `sxSign(message, sk)` (attached) and
  `sxSignDetached(message, sk)` -> signature, `sxSignVerifyDetached(sig, message, pk)` ->
  Boolean. **ed25519 here is the same primitive as BitTorrent BEP44**, so a SodiumXT keypair
  can sign a TorrentXT channel feed and vice versa (call this out in the api-reference;
  watch the seed-vs-expanded-key representation).
- `sxKeyExchange` (`crypto_kx`, optional; for deriving a shared session key).

## 5. Phased delivery plan

Each phase ends green (smoke test + checker pass), ABI bumped if the surface changed, native
binary repackaged in the same change.

- **Phase 0: skeleton + the FFI buffer round-trip (the single most important phase).**
  Stand up CMake + the pinned libsodium build + the CI matrix FIRST, not last. Implement
  exactly two things end to end: `sxVersion` (string out) and `sxRandomBytes` (the canonical
  out-buffer: allocate, call, get `-needed` on a short buffer, retry, copy back with
  `MCDataCreateWithBytes`). Prove a `Data` makes the full script -> Pointer -> C -> Pointer
  -> script trip intact. This de-risks the one thing that cost TorrentXT a runtime
  `expected type pointer` error. Do not proceed until a known random buffer round-trips
  byte-for-byte and the matrix is green.

- **Phase 1: hashing + encoding (no secrets).** `sxHash`, `sxBin2Hex/Hex2Bin`,
  `sxBin2Base64/Base642Bin`, `sxMemEqual`. Cheap, no key handling, and it exercises the
  buffer plumbing on real payloads. Lock the framing with known-answer tests (a fixed input
  has a fixed BLAKE2b digest; a fixed blob has a fixed base64).

- **Phase 2: secret-key auth encryption + Argon2id (the TorrentXT upgrade).** `sxPwHash` /
  `sxPwHashStr*`, `sxSecretBox` / `sxSecretBoxOpen`, `sxAead*`. This is the minimum to
  replace `aes-256-cbc` + the weak KDF in TorrentXT's demos. Test: passphrase -> key ->
  encrypt -> decrypt round-trip; tamper one ciphertext byte and assert open FAILS (proves
  authentication); a known Argon2id vector.

- **Phase 3: streaming AEAD + file helpers.** `sxSecretStream*` with the handle table, and
  `sxEncryptFile` / `sxDecryptFile`. Test: multi-chunk round-trip; truncated stream fails to
  verify (the FINAL-tag property); a multi-gigabyte file encrypts without the process memory
  blowing up (proves it streams). This is what big-file privacy should use.

- **Phase 4: public-key box + sign.** `sxBoxKeypair` / `sxBox` / `sxSeal`, `sxSignKeypair` /
  `sxSign*`. Test: box round-trip between two keypairs; detached sign + verify; a tampered
  message fails verify; an ed25519 known-answer vector that also matches what TorrentXT's
  BEP44 signer produces for the same key+message (interop proof).

- **Phase 5: key management + polish.** `sxKdfDerive`, `sxKeyExchange`, `sxPad/Unpad`,
  secure-memory notes, the api-reference, and the worked TorrentXT migration example
  (Section 9).

## 6. Testing strategy

- **Known-answer tests (KATs) are mandatory.** A crypto binding's worst failure mode is
  silently mangling bytes (a length off by one, a wrong endianness in a parsed 64-bit limit).
  Round-trip tests alone hide that (mangled-then-unmangled still matches). So pin **fixed
  input -> fixed output** vectors from libsodium's own test suite for at least: generichash,
  secretbox, pwhash (Argon2id), sign (ed25519). These also pin the ABI framing.
- **Negative tests:** tamper a byte and assert open/verify FAIL; feed a short out-buffer and
  assert `-needed`; pass a bad/stale handle and assert a clean no-op; pass a wrong-length key
  and assert a clean error (not a crash).
- **Streaming/property tests:** chunked round-trips; truncation detected; large-file streaming
  stays within a memory bound.
- **Sanitizers:** every iteration under gcc ASan + UBSan (`-fno-sanitize-recover=all`). This
  is where buffer-sizing bugs surface.
- **Record golden test** only if a multi-value return uses a framed record; most returns are
  a single Data, so this may not be needed. If used, port TorrentXT's big-endian framing and
  `record_golden_test.py`.
- **LCB static checker:** port `tools/check-livecodescript.py` verbatim and run it on every
  `.lcb` / example change. There is no headless OXT compile; static is all we get, so say
  "verified statically; needs an OXT pass."

## 7. Build and packaging

- **CMake acquires libsodium at a pinned version** (FetchContent or ExternalProject; record
  the exact tag). libsodium's primary build is autotools; on the matrix prefer a known-good
  CMake path (a vendored `CMakeLists`, or build its static lib via its own tooling and import
  it). Stand the **CI matrix up in Phase 0**, not at the end: linux `x86_64` + `x86`, win32
  `x86_64` + `x86` (MSVC, `/W3`), mac `universal`.
- **Static-link libsodium into ONE shared library** named with the bare token `sodiumxt`
  (`PREFIX ""`, `OUTPUT_NAME sodiumxt`). No external runtime dependency.
- **Sanitizer build target** for local iteration (gcc).
- **`tools/package-extension.py`** refreshes the committed
  `src/code/<arch>-<platform>/sodiumxt.*` in the same change as any native edit.
- **`docs/building.md`** documents the heavy part (the libsodium acquisition), like
  TorrentXT's.

## 8. Risk register

| # | Risk | Mitigation |
|---|------|------------|
| 1 | **FFI buffer marshaling** (the `Data`-is-not-a-`void*` trap; the costliest TorrentXT bug). | Prove the out-buffer round-trip in Phase 0 before anything else. Copy the htmltidy/HIDAPI/TorrentXT pattern exactly. |
| 2 | **Payload now crosses the FFI** (inverts TorrentXT) and a big file held twice in script memory could thrash or OOM. | C-side `sxEncryptFile`/`sxDecryptFile` and the secretstream chunk API; document "do not pull a multi-GB file through a Data." |
| 3 | **Nonce reuse** (catastrophic for these ciphers). | APIs generate+prepend nonces or use secretstream; no naked "bring your own nonce" entry without a loud reason. |
| 4 | **Weak KDF params** leaving passphrases brute-forceable. | Argon2id via `crypto_pwhash`; default to MODERATE, expose SENSITIVE; store opslimit/memlimit/salt (or use `pwhash_str`) so cost can rise later. |
| 5 | **Secret material in script memory** cannot be `mlock`ed/zeroed by us. | Zero transient secrets C-side; document the boundary honestly; offer `sxKeyFromPassphrase` so a long-lived key need not sit in script as plaintext longer than necessary. |
| 6 | **libsodium build on the matrix** (autotools vs MSVC vs universal mac). | Pin the version; settle the build path in Phase 0 CI; treat headers as system headers. |
| 7 | **ABI / length-constant skew** across libsodium versions. | Never hardcode lengths in LCB; expose `sxt_*_bytes()`; bump `SXT_ABI_VERSION` + `checkABI()` together. |
| 8 | **Misleading the user about guarantees.** | KATs + negative (tamper) tests in CI; honest docs about authentication, truncation, and what secure memory does and does not cover. |

## 9. The TorrentXT migration target (make the promise concrete)

Once Phase 3 lands, TorrentXT's demos should adopt SodiumXT:

- **Passphrase -> key:** replace OXT's `encrypt with password` KDF with
  `sxPwHash(passphrase, salt, 32, "moderate")`; store the salt (and opslimit/memlimit)
  beside the data.
- **File encryption:** replace the hand-rolled `BTXFENC1` 4 MiB AES-CBC chunk framing with
  `sxEncryptFile` / `sxDecryptFile` (secretstream). This gets authenticated chunks, ordering,
  and truncation detection for free, and the bytes stop flowing through script.
- **Feed signing:** TorrentXT already uses ed25519 for BEP44. `sxSign*` is the same
  primitive, so the channel key and a SodiumXT key can be one and the same; verify the
  seed-vs-expanded representation lines up and add an interop test.
- **Net effect:** the public "next up is wrapping libsodium" line becomes true, and
  TorrentXT's privacy story upgrades from "confidential but with a weak KDF and no cipher-level
  auth" to "authenticated, Argon2id, truncation-resistant."

## 10. Open decisions for the new repo

- Final public prefix (`sx*` proposed) and library id (`org.openxtalk.library.sodium`).
- Base64 variant for any user-facing codes (URL-safe, no padding, is the friendly default).
- Whether to expose `crypto_box_seal` (anonymous sender) in the first cut.
- Whether multi-value returns use separate out-buffers (simplest) or a framed record
  (port TorrentXT's only if genuinely needed).
- Default Argon2id preset (MODERATE proposed) and whether to surface a custom
  opslimit/memlimit entry for power users.

---

### First move in the new repo

1. Drop this folder in, read `CLAUDE.md`.
2. Port `tools/check-livecodescript.py` and `tools/package-extension.py` from TorrentXT.
3. Do **Phase 0** only: CMake + pinned libsodium + CI matrix + `sxVersion` + `sxRandomBytes`,
   and prove the buffer round-trip under ASan. Everything else is downstream of that working.
