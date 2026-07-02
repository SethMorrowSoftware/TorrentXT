# TorrentXT x OnionXT — Model C (Full Onion Transport) Integration Plan

> Optional anonymity for the QuickShare and DHT-Channels demos: on the anonymous path the file bytes travel
> peer-to-peer over a Tor onion circuit (OnionXT), bypassing BitTorrent, so both IPs are hidden. BitTorrent/DHT
> stay the default public path. Requires OnionXT + a local Tor daemon + SodiumXT; fails closed, never regresses.
>
> **Honesty scope.** OnionXT is not present in this repository (zero `ox*` references anywhere in the tree). Every
> `ox*` handler, its signature, and its runtime semantics in this plan are **presumed from the design and must be
> confirmed against the real OnionXT ABI before Phase 1** (see §9.1 and the VERIFY register in §12.3). The qs*/ch*
> handlers, the `BTXQS1:`/`BTXENC2:` markers, and every line number cited for the two demos are grounded in the
> current sources.

---

## 1. Scope & decision

Adopt **Model C** (full onion transport). This plan is build-ready demo-script work only — no changes to the
compiled TorrentXT or OnionXT extensions. See section 9.

The whole plan is gated on one external precondition: **confirming the real OnionXT ABI** (§9.1). Until that
happens, treat the `ox*` surface as a design contract, not a fact.

---

## 2. Ground rules carried from both projects

Single-thread playbook, OXT compiler footguns, fail-closed capability probes (mirroring the existing cryptoXT
`sCanEncrypt` pattern), and the honesty convention (verified statically; needs an on-engine OXT pass).

Both demos are self-contained stack scripts that will each receive a copy of the section-3 substrate under their
own prefix. Two unifying conventions are fixed here and used **consistently** across every section below — they
resolve naming/format drift that earlier drafts carried:

- **Callback + state namespace:** every new handler is `<pfx>Onion…` and every new state local is spelled exactly
  as introduced in §3–§6 (`sHasOnion`, `sTorReady`, `sActiveShare`, `sOnionXfers`, the `sTx*`/`sRx*` per-stream
  arrays, etc.). The earlier `qsOn*` / `qsOnionProbe` / `sAnon` / `sOxReady` / `sStaged` / `sAnonRows` spellings are
  **retired**; §8–§13 use the §3–§6 names.
- **One wire protocol, one magic, one code prefix:** the file transfer uses the §3.3 framing
  (`kOnionMagic = "BTXO"`, HEADER + length-prefixed DATA frames + zero-length terminator); the channels request
  layer uses the §6.4 `BTXC`/`BTXF` frames on top of it; the QuickShare anon share code prefix is
  `kTorCodePrefix = "BTXTOR1:"`. The alternate `BTXON1`/`BTXQS2:`/typed-`SELECT/META/DATA/FIN` scheme from earlier
  drafts is **deleted**, and the golden test in §12 is written against this single framing.

---

## 3. Shared foundation — the onion-transport layer (used by BOTH demos)

Model C adds a second, **optional** transport that lives entirely beside the existing BitTorrent path. Nothing here
touches libtorrent: when the anonymous toggle is on, the file's bytes travel over an OnionXT stream and **no torrent
is ever added** for that transfer. The two demos are separate stack scripts, so this substrate is **pasted into
each** and instantiated under that demo's prefix. Below, `<pfx>` = `qs` in `torrent-quickshare.livecodescript` and
`ch` in `torrent-dht-channels.livecodescript`. New handlers use the sub-namespace `<pfx>Onion…`; OnionXT callbacks
are registered under prefixed names (we pass explicit prefixed names to the OnionXT setters, overriding OnionXT's
default convention names so the two demos never collide in a shared stack).

**Design invariant (guard against silent mixing):** an anonymous transfer is **mutually exclusive** with clearnet
seeding of the same file. The anon path calls **none** of `btCreateTorrent` / `btAddTorrentFile` / `btAddMagnet` /
`btDhtPutMutable` / `btDhtGetMutable`. This is the one rule that keeps the "anonymous" label honest — an anon feed
entry plus a clearnet seed would leak the seeder IP. §7 owns the full guard set; §3–§6 place the branch points.

### 3.1 The two-stage capability probe

Two orthogonal facts must both be true before any anonymous action. Keep them in two separate script-locals,
because they have **different lifetimes**.

| State | Meaning | Lifetime | How checked |
|---|---|---|---|
| `sHasOnion` | The OnionXT extension is installed and loads | **Static** — fixed for the whole run | Probed **once** at start, like `sCanEncrypt` |
| `sTorReady` | The local Tor daemon is up, control is authenticated, bootstrap = 100%, service descriptor uploaded | **Live** — starts false, flips true after bootstrap (tens of seconds), can drop back to false if Tor restarts or control drops | Cached by the status callback; **re-checked at the moment of use** |

**Stage 1 — `sHasOnion` (mirror the `sCanEncrypt` probe).** Add `function <pfx>HasOnion`: a guarded `oxVersion()`
in a `try`, exactly parallel to the existing `qsCanEncrypt` (qs 727) / `chCanEncrypt` (ch 1810) secretbox
round-trip.

```
function <pfx>HasOnion
   local tV, tErr
   try
      put oxVersion() into tV      -- throws / fails to resolve if OnionXT absent
   catch tErr
      return false
   end try
   return (tV is not empty)
end <pfx>HasOnion
```

Call it once in `qsStart` (qs 300, right after `put qsCanEncrypt() into sCanEncrypt`) / `chStart` (ch 471) →
`put <pfx>HasOnion() into sHasOnion`. This is a one-shot boolean; the extension does not appear or vanish mid-run.

Note the hard dependency chain (§9.3): OnionXT itself requires cryptoXT, so `sCanEncrypt` is a **necessary**
precondition for anon mode even for a no-passphrase transfer. `<pfx>HasOnion` therefore reads as "OnionXT loaded
AND `sCanEncrypt`"; when `sCanEncrypt` is false the anon path is inert with the §13.3 "needs cryptoXT" message,
distinct from "no Tor".

**Stage 2 — `sTorReady` is LIVE, never a one-shot.** Two consumers, two different reads:

- **UI (cheap, cached):** the status callback (§3.2) writes `sTorReady` whenever bootstrap/control state changes,
  and the existing 1 s dash loop repaints from it. This is allowed to be slightly stale.
- **Transactional guard (authoritative, fresh):** immediately before dialing out or advertising a service, call
  `function <pfx>OnionReadyNow` which re-reads **live** state — `oxIsReady()` — and returns boolean. Never trust
  the cached `sTorReady` for a go/no-go decision; the daemon may have dropped since the last callback.

```
function <pfx>OnionReadyNow
   if not sHasOnion then return false
   return oxIsReady()          -- live: 100% bootstrap AND descriptor uploaded (VERIFY, §12.3)
end <pfx>OnionReadyNow
```

Both stages fail closed: `sHasOnion` false ⇒ the whole onion path is inert; `sHasOnion` true but
`<pfx>OnionReadyNow()` false ⇒ every anonymous action refuses with a clear message and **every clearnet feature is
untouched**.

> **Resolved review findings (§3.1).** *`oxIsReady()` == "100% + descriptor uploaded" is a presumed semantic —
> tagged VERIFY (§12.3 #23).* The dependency of anon-without-passphrase on SodiumXT is stated here rather than
> buried in §9.3.

### 3.2 Tor lifecycle inside the demo — constants, start, pill, stop

**All onion constants are declared literally here, before first use** (the OXT constant-before-use footgun; this
block is the single source and every later section references it):

```
constant kTorSocksPort     = "9050"      -- standalone/system tor default
constant kTorControlPort   = "9051"
constant kTorSocksPortTB   = "9150"      -- Tor Browser
constant kTorControlPortTB = "9151"
constant kOnionVirtualPort = "80"        -- the onion service's advertised port (shared by both demos)
constant kOnionMagic       = "BTXO"      -- 4 ASCII bytes, file-transfer frame sync
constant kOnionVer         = 1
constant kOnionChunk       = 65536       -- 64 KiB payload slice (hard cap on any single frame)
constant kFlagEnc          = 1           -- header flags bit0: payload is cryptoXT .enc
constant kSendTimeout      = 30000       -- ms idle-gap watchdog, sender
constant kRecvTimeout      = 60000       -- ms idle-gap watchdog, receiver (Tor handshakes are slow)
constant kMaxNameLen       = 1024        -- reject a header nameLen beyond this (anti-DoS)
constant kMaxTotalLen      = 8589934592  -- 8 GiB payload ceiling; reject header totalLen beyond this
```

The loopback listen port is **not** a fixed constant — it is an **ephemeral OS-assigned port** obtained at
listen time and handed to OnionXT (see §3.4 and the M8/one-service resolution). QuickShare uses one such port for
its single active share; Channels allocates one per anon channel. This removes the fixed-port collision between a
running QuickShare and a Channels instance, and between two instances.

**Dual-port-pair readiness.** `oxConnectControl` is attempted first on `kTorControlPort` (9051), then on
`kTorControlPortTB` (9151); whichever authenticates fixes the matching SOCKS port via `oxSetSocksPort`. This
implements the §13.2 promise of auto-probing both stock-tor and Tor-Browser port pairs, rather than hardcoding one.

**On start** — add `command <pfx>OnionStart`, called at the tail of `qsStart` / `chStart`, only when `sHasOnion`:

1. `oxSetControlPort kTorControlPort` ; `oxSetSocksPort kTorSocksPort` (must precede connect).
2. `oxSetStatusCallback "<pfx>OnionStatus"` — coalesced bootstrap/event updates delivered on the main thread.
3. `oxConnectControl` (command → check `the result`) on 9051; on failure retry on 9151 with the TB ports. Success
   ⇒ we are authenticated to the control port; bootstrap proceeds in the background. Failure on both ⇒ "has
   extension, no daemon" state: leave `sTorReady` false, disable the anon toggle, pill shows the daemon hint. **Do
   not block** waiting for bootstrap — it takes tens of seconds; the status callback and the dash loop surface
   progress.

> **Cookie-auth (VERIFY, §12.3).** Whether `oxConnectControl` reads Tor's cookie file / handles
> `CookieAuthentication 1` itself, or needs the demo to pass a credential, is an OnionXT behavior we do not yet
> know. The onboarding (§13) documents the `torrc` + `debian-tor`-group path; the exact credential handshake is a
> hard VERIFY before Phase 0 closes.

**The live status pill** — add `command <pfx>OnionPill` (repaints one small field/button), driven from two places:
the `<pfx>OnionStatus` callback (on step changes) and the existing dash loop (`qsDashOnce` qs 345 / `chDashOnce`
ch 906, 1 Hz — comfortably inside the ≤4 Hz UI rule). Pill states:

| Condition | Pill text |
|---|---|
| Toggle off (default) | `Tor: off` |
| `sHasOnion` false | `Tor: no extension` (or `Tor: needs cryptoXT` when OnionXT loaded but `sCanEncrypt` false) |
| `oxConnectControl` failed on both port pairs | `Tor: no daemon (start Tor on 127.0.0.1:9051 or 9151)` |
| Connected, `oxBootstrapProgress() < 100` | `Tor: connecting NN%` |
| `oxIsReady()` true | `Tor: ready` |

`<pfx>OnionStatus pInfo` updates the cached `sTorReady` (`put oxIsReady() into sTorReady`) and calls
`<pfx>OnionPill`. Keep it short — it runs on the shared interpreter thread. On the **first** transition to
`oxIsReady()` true, the Channels instance also calls `chOnionBringUpServices` (§6.3), which is what brings anon
services online after bootstrap without blocking `chStart`.

**On close** — add `command <pfx>OnionStop`, called from `qsStop` (qs 310) / `chStop` (ch 707), **before** the
existing `btStopSession`:

1. `oxCloseStream` every open stream handle we hold (idempotent; stale handles are clean no-ops).
2. `oxRemoveService` every live service handle.
3. `oxDisconnectControl` (idempotent — a no-op if we never connected).
4. `close socket` every loopback listener we armed.
5. Delete any onion temp files (§3.3) — extend the existing temp-cleanup loop that `qsStop` already runs over
   `sTempEnc` (qs 319–327), and sweep the receiver temp array.

**Failure UX — all fail-closed, everything else intact:**

- **Absent extension / absent cryptoXT** (`sHasOnion` false): the "Anonymous (Tor)" toggle is present but disabled
  with the matching tooltip. Public sharing/publishing/downloading all work normally.
- **Absent daemon** (`oxConnectControl` failed both pairs): toggle disabled, pill names the fix. Clearnet path
  unaffected.
- **Mid-bootstrap** (connected, <100%): the toggle may be ON, but any send/receive gated on
  `<pfx>OnionReadyNow()` **refuses** with "Tor still connecting NN% — try again in a moment," and **never silently
  falls back to the clearnet swarm.** (This resolves the §13.3-vs-§5 "queue vs refuse" contradiction in favor of
  **refuse-and-retry**; there is no pending-action queue — §13.3 is corrected to match.)

### 3.3 The framed, chunked file-streaming protocol

Bounded, single-thread-safe, binary-disciplined (`numToByte`/`byteToNum`/`binaryEncode`/`binaryDecode` only — never
char/line/word). The file is read in fixed slices so it never enters a Data whole; frames are flow-controlled one
per pump.

**Header (sent once, first):**

| Field | Bytes | Encoding | Meaning |
|---|---|---|---|
| magic | 4 | ASCII `BTXO` | frame-sync / sanity |
| version | 1 | `numToByte(1)` | protocol version |
| flags | 1 | bitfield | bit0 `kFlagEnc` = encrypted payload; bits 1–7 reserved 0 |
| nameLen | 2 | u16 big-endian, `binaryEncode("n", …)` | length of UTF-8 name; **reject if > `kMaxNameLen`** |
| name | nameLen | UTF-8 | filename **leaf only** — see sanitization below |
| totalLen | 8 | u64 big-endian as **hi:u32 then lo:u32** | payload bytes to follow across all data frames; **reject if > `kMaxTotalLen`** |

Fixed prefix is 8 bytes (magic…nameLen); the receiver waits for 8, reads `nameLen`, then waits for a further
`nameLen + 8`. So the header is self-delimiting.

*OXT footgun (corrected):* LiveCode's big-endian unsigned **u16** format code is `"n"` and **u32** is `"N"` —
`"m"` is not a big-endian u16 code and would misframe `nameLen`. Use `"n"` for `nameLen`. LiveCode has no portable
u64, so write `totalLen` as two u32: `put tTotal div 4294967296 into tHi ; put tTotal mod 4294967296 into tLo ;
binaryEncode("NN", tHi, tLo)`. (Numbers are doubles — exact to 2^53, i.e. any real file size.) The `"n"` vs `"N"`
choice is pinned in `onion_frame_golden.py` (§12.2) and must be checked against the LiveCode dictionary before
coding.

**Data frame (repeated):**

| Field | Bytes | Encoding |
|---|---|---|
| len | 4 | u32 big-endian, `binaryEncode("N", tLen)`, **`1 ≤ len ≤ kOnionChunk` enforced on BOTH sides** |
| bytes | len | raw payload slice |

**Terminator (FINISH):** a zero-length frame — the 4 bytes `binaryEncode("N", 0)`. Wire =
`HEADER · FRAME* · [00 00 00 00]`.

**Filename sanitization (mandatory, both sources).** The in-stream header `name` **and** the share-code `b64name`
are attacker-chosen. Before either is used to build any path, pass it through `<pfx>SafeLeaf`:

- take the **basename only** — strip everything up to and including the last `/` or `\`;
- strip a leading drive/colon (`C:`), strip leading dots, collapse to empty ⇒ substitute `"shared-file"`;
- **reject** `..`, path separators surviving the strip, and control characters.

Apply it **before opening the temp** and **again before the final move**, and never let the header name override
into a path — the header name is a **display label + sanitized leaf**, nothing more. This closes the arbitrary-write
/ path-traversal hole (a code or tampered header carrying `../../.ssh/authorized_keys`, an absolute path, or `..\`
can no longer escape the save folder).

**Bounded-buffer discipline (mandatory).** The receiver enforces `len ≤ kOnionChunk`, `nameLen ≤ kMaxNameLen`, and
`totalLen ≤ kMaxTotalLen` **before** appending to the reassembly buffer or opening the temp — a garbled/malicious
`len = 0xFFFFFFFF` is an immediate ABORT+close, not a 4 GB buffer growth. Before opening the temp the receiver also
**checks free disk space** against `totalLen` (and, when `kFlagEnc`, ~2× for the in-place decrypt), refusing with a
clear message if short. These bounds live in the design body, not only in the golden test.

Integrity is layered, not re-invented: the Tor circuit gives TLS-grade integrity endpoint-to-endpoint; when
`kFlagEnc` is set, cryptoXT's `crypto_secretstream` gives per-chunk auth + a final tag (truncation is detected on
decrypt); for the plaintext case the `totalLen` check catches a short transfer. **Endpoint authenticity is NOT
provided by the plaintext path** — see §7.3/M3: plaintext anon hides the route but does not authenticate the
sender, and the "anon" badge must never imply it does.

**SENDER state machine.** Reuse the existing encryption path first: when a passphrase is set, produce the temp
`.enc` with `qsEncryptFile` (qs 781) / `chEncryptFile` (ch 1919) into a `qsTempEncPath` / `chTempEncPath`
(qs 769 / ch 1895), set `kFlagEnc`, and stream **that** file; with no passphrase, stream the plaintext original with
the flag clear. Per-stream state in arrays keyed by the stream handle: `sTxPath`, `sTxOffset`, `sTxTotal`,
`sTxEncTmp`, `sTxDeadline`.

Add `command <pfx>OnionSend pStream, pPath, pName, pEncrypted, pTotal` and the pump. **oxDial is asynchronous**
everywhere (§8.2): the stream callback is registered **before** the connection is usable, and the **first**
`oxWrite` (the header) is gated on the `<pfx>OnionStreamReady` callback so it never races the connect:

1. On accept/ready for a serve stream (§3.4), `open file pPath for binary read`, stash state, compute the header,
   and register `oxSetStreamCallback pStream, "<pfx>OnionStreamData"` and the ready/closed companions.
2. When `<pfx>OnionStreamReady pStream` fires, `oxWrite pStream, <header>` and arm the pump.
3. **Each pump (one frame):** `read from file sTxPath[pStream] at sTxOffset[pStream] for kOnionChunk`.
   - If `it` is empty (EOF) → `oxWrite pStream, binaryEncode("N",0)` (terminator), `close file`, mark done,
     `oxCloseStream pStream` after the write flushes, delete `sTxEncTmp[pStream]` if any.
   - Else → `oxWrite pStream, (binaryEncode("N", the length of it) & it)`,
     `add (the length of it) to sTxOffset[pStream]`, refresh `sTxDeadline`, and re-arm the pump.
4. **Flow control / backpressure (writability-gated, required).** The pump is gated on OnionXT's **writable
   signal**: the next frame is written only when the stream reports it can accept more, capping outstanding-unacked
   bytes to a few frames so a slow circuit cannot balloon OnionXT's native write buffer. If — and only if — the
   writable callback proves unavailable on the real ABI (VERIFY, §12.3 #24), the fallback is a self-arming
   `send "<pfx>OnionPump pStream" to me in kPumpTick` timer (`kPumpTick` ≈ 15 ms) that additionally **stalls** when
   an outstanding-bytes cap is exceeded. Never a tight `repeat` over the whole file, and never `send … in 0`
   ungated (the earlier `in 0` self-pacing is retired in favor of the ≥15 ms gated tick).
5. **Concurrent serves round-robin.** When N receivers pull one publisher (Channels always; QuickShare when the
   service persists across receivers), the pump pushes **one frame across all active send streams per tick**,
   round-robin, so no single receiver starves the others; per-stream throughput scales as `1/N` of the ceiling.
6. **One file handle per serve — no shared named-open.** LiveCode keys open files by pathname, so two receivers of
   the **same** file cannot share one `open file … close file` without the first `close` truncating the second's
   reads. The sender therefore either (a) restricts a given file to **one active receiver at a time** (documented,
   simplest) or (b) **re-opens the file per read** (`open … ; read at offset ; close`) so each stream is
   independent. QuickShare adopts (a) by default for its single active share; Channels uses (b) so a popular
   release can fan out. This closes the concurrent-serve corruption hole.
7. **Timeout:** a **self-arming** watchdog `send "<pfx>OnionSendWatchdog pStream" to me in …`, armed at accept, runs
   independently of inbound data; it compares `the milliseconds` (read once per pass) against `sTxDeadline`; no
   progress within `kSendTimeout` ⇒ abort: `close file`, `oxCloseStream`, delete temp `.enc`, log.

**RECEIVER state machine.** The inbound stream arrives via the accept side (§3.4). Register the stream callback
**before** any bytes can arrive. Per-stream state: `sRxBuf` (persistent reassembly Data — reused, not rebuilt),
`sRxState` (`"header"`/`"body"`/`"done"`), `sRxTmp` (temp output path), `sRxName`, `sRxEnc`, `sRxTotal`, `sRxGot`,
`sRxDeadline`.

`command <pfx>OnionStreamData pStream, pData`:

1. `put pData after sRxBuf[pStream]`. Refresh `sRxDeadline`.
2. **State `"header"`:** if `length(sRxBuf) ≥ 8`, parse magic/ver/flags/nameLen; reject unless magic == `BTXO`,
   ver == 1, and `nameLen ≤ kMaxNameLen` (abort on mismatch). If `length ≥ 8 + nameLen + 8`, parse `name` +
   `totalLen`; reject `totalLen > kMaxTotalLen`; run `name` through `<pfx>SafeLeaf`; set
   `sRxEnc`/`sRxName`/`sRxTotal`; **check free disk** against `totalLen` (×2 if `kFlagEnc`); **register the temp
   path in the cleanup array immediately**; choose a temp output path (`<pfx>TempEncPath` when encrypted, else a
   neutral temp beside the save folder); `open file sRxTmp for binary write`; `put 0 into sRxGot`; **delete the
   header bytes from the front of the buffer**; state → `"body"`. Fall through to step 3 in the same call.
3. **State `"body"`:** loop while the buffer holds a full frame — need ≥ 4 bytes for `len`; `binaryDecode("N", …)`;
   **reject `len > kOnionChunk` → ABORT** (before waiting for or allocating that many bytes); if `len == 0` →
   state `"done"`, break; if `length(sRxBuf) ≥ 4 + len`, extract the `len` payload,
   `write tPayload to file sRxTmp at sRxGot[pStream]`, `add len to sRxGot`, **delete the consumed `4+len` bytes
   from the front of the buffer**; else leave the partial frame in the buffer and return. Draining + compacting each
   call keeps the buffer bounded to one chunk + a partial frame — the payload never dwells whole in a Data (rule 3).
4. **State `"done"`:** `close file`. Verify `sRxGot == sRxTotal` — mismatch ⇒ truncated/aborted: delete temp, clear
   state, log, `oxCloseStream`. If `sRxEnc`: reuse `qsDecryptFile` (qs 794) / `chDecryptFile` (ch 1934) — key from
   the demo-specific stash — writing the real file (`<save>/<SafeLeaf(name)>`) into the save folder, then delete
   the temp `.enc`. Else move the temp to `<save>/<SafeLeaf(name)>`. Log success, `oxCloseStream`.
5. **socketError / socketClosed / `<pfx>OnionStreamClosed`:** wire **all three** — `socketError`/`socketClosed` at
   the app level for the loopback listener (§3.4), `<pfx>OnionStreamClosed` per stream. Any firing while state ≠
   `"done"` ⇒ **partial-transfer abort:** `close file`, delete the temp, clear per-stream state, log. A
   stale/closed handle is a clean no-op.
6. **Timeout:** a **self-arming** receive watchdog `send "<pfx>OnionRecvWatchdog pStream" to me in …`, armed at
   accept/dial (**not** only refreshed inside `OnionStreamData`), fires the same abort path on an idle stall —
   including a dialed stream that delivers **zero** bytes (dead peer, failed rendezvous, no close event). Timeouts
   wrap the *idle* gap, not the total.
7. **Temp cleanup:** every receiver temp is registered in a cleanup array **at open time** (step 2), deleted on
   abort, after a successful decrypt, and in `<pfx>OnionStop`.

> **Resolved review findings (§3.3).** C1 (path traversal) → `<pfx>SafeLeaf` on both sources, applied twice. C2 /
> #18 (unbounded buffer + disk) → `len`/`nameLen`/`totalLen` caps enforced in the body + free-disk pre-check.
> H2 (silent hang) → self-arming watchdogs armed at dial/accept. H3 (write blowup) → writability-gated pump with an
> outstanding-bytes cap. H6 (concurrent serve corruption) → per-stream re-open or single-receiver restriction.
> M5 (temp leak) → register temp at open time. M6 (`"m"` vs `"n"`) → corrected to `"n"` for u16.
> No-resume limit → **an interrupted onion transfer restarts from byte 0** (the header/request carries no offset);
> this is an accepted limit, documented to the user (§5.6/§13.3), not a resume feature.

### 3.4 The onion-service accept side

The **receiving** peer publishes a hidden service and listens on loopback; OnionXT bridges inbound onion
connections to it as stream handles. (The precise inbound model — what the raw accepted loopback socket does versus
what arrives on the peer callback — is a VERIFY item, §12.3 #25.)

1. **Listen first, on an ephemeral port.** OnionXT requires the app to already be accepting on a local port. Bind
   an **OS-assigned ephemeral port**, capture it, and hand it to the service create call:
   `accept connections on <ephemeralPort> with message "<pfx>OnionAccept"` (handle bind failure gracefully — log
   and leave anon disabled, never crash). Register `oxSetPeerCallback "<pfx>OnionPeer"` — this delivers a **new
   inbound stream handle per connection**. (`<pfx>OnionAccept` is the underlying loopback listener; `<pfx>OnionPeer`
   is where usable stream handles arrive.)
2. **Create the service.**
   - **Quickshare:** `oxCreateServiceFromSeed sxRandomBytes(32), kOnionVirtualPort, <ephemeralPort>` → a **fresh,
     ephemeral** `.onion` per share (random key) — maximum unlinkability; the `.onion` rides inside the share code
     (§5.2).
   - **Channels:** `oxCreateServiceFromSeed sChannels[i]["seed"], kOnionVirtualPort, <ephemeralPort>` for a
     **deterministic** `.onion` tied to the channel, so followers reach a stable address derivable from the channel
     pubkey (§6.1). **Privacy caveat to document:** a seed derived from the channel identity links the `.onion` to
     the channel pubkey — acceptable for a named channel, but say so; use an independent random seed if
     unlinkability matters.
3. **Advertise only when reachable.** Register `<pfx>OnionServiceReady` via the service API; only after it fires
   (descriptor uploaded) do we put the `.onion` into the share code / channel feed — handing out an address that
   does not yet resolve just produces failed dials. Use `oxServiceAddress pService` to read the `.onion`. Arm a
   **publish timeout** (see §5.3 M7 fix) so a descriptor that never uploads surfaces the §13.3 failure and tears
   down the half-built service instead of hanging forever.
4. **Per connection:** `<pfx>OnionPeer pStream` fires with a new inbound stream handle → initialize receiver/serve
   state (§3.3 / §6.4) and register the stream callback.
5. **Loopback listener is local-process-reachable — scope it.** Any local process can connect to the loopback
   accept port and speak the protocol. Bind to `127.0.0.1` only (never `0.0.0.0`), use the ephemeral port (harder
   to guess than a fixed one), and treat any bytes that do not begin with the expected magic as an immediate close.
   Where the OS/ABI allows an authenticated or restricted loopback handoff from OnionXT, prefer it; document the
   residual local-process exposure as a known limit of the demo.
6. **Teardown:** `oxRemoveService pService` when the share is withdrawn and in `<pfx>OnionStop`; `close socket` for
   the loopback listener. All idempotent.

**Concurrent services (VERIFY, §12.3).** Channels assumes OnionXT can run **N** services at once (one per anon
channel); this must be confirmed. The product decision is **one service per session for QuickShare** (a single
active share, replaced on the next drop) and **one service per anon channel** for Channels, each on its own
ephemeral loopback port and each addressed by a distinct `.onion`. There is a **single** global
`oxSetStatusCallback`; in a shared stack the two demos must not both claim it — in practice they run as separate
stacks, but if co-hosted, one status dispatcher fans out to both pills.

### 3.5 Coexistence with the existing `btPoll` loop

Two **independent, non-blocking, async** subsystems share the one interpreter thread:

1. **BitTorrent drain — unchanged.** `qsPollOnce` / `chPollOnce` (250 ms, one `btPoll` FFI round-trip →
   `qsHandleEvent` / `chHandleEvent`), the 1 s dash, and (channels) the 60 s `chChannelTick`. Not modified by
   Model C.
2. **OnionXT delivery.** `oxSetStatusCallback`, `oxSetPeerCallback`, and each stream's `oxSetStreamCallback`, plus
   the `accept connections … with message` listener and its `socketError`/`socketClosed`. These are already
   **main-thread, message-driven** — LiveCode enqueues them onto the *same* pending-message queue the
   `send … in …` timers use. Onion callbacks and `btPoll` ticks naturally interleave; no locking, no cross-thread
   anything.

**The one rule: never block the interpreter thread.** A single long synchronous handler in either subsystem starves
the other. Therefore:

- `btPoll` stays one FFI round-trip per tick; OnionXT uses async reads and the **writability-gated, one-frame,
  round-robin** streaming of §3.3.
- Heavy crypto (`sxEncryptFile` / `sxDecryptFile`) is the one legitimate multi-hundred-ms pause; it runs **once,
  outside the pump** (before the first frame, or after FINISH on receive). The existing "the app may pause briefly
  on a large file" notices (qs 419, ch 975) already cover it. This, plus bounded script streaming, is the honest
  **size ceiling** of Model C.
- **No libtorrent involvement on the anon path.** A Tor-only transfer emits **no**
  `torrentAdded`/`metadataReceived`/`torrentFinished` events — its progress lives entirely in the §3.3
  sender/receiver state, surfaced by the existing dash loop. The mutual-exclusion invariant keeps this clean.

**Scoping note (carried to the UI).** The host still runs one `btStartSession` with DHT/LSD enabled, so it remains
a visible DHT node even during a pure-anon share. The "both IPs hidden" claim is scoped to the **file bytes on the
anon path**, not to the app's overall network presence — §7.1 and the in-UI copy state this explicitly so the badge
does not over-promise.

---

## 4. The two demos at a glance

Before the per-demo deep-dives, here is the whole change surface in one view. Both demos receive the **same** §3
substrate (pasted under their own prefix); each then adds a thin, demo-specific layer on top.

| | QuickShare | DHT Channels |
|---|---|---|
| **Anon unit** | one dropped file, one fresh per-share onion | one channel = one persistent onion (its existing key) |
| **Onion identity** | ephemeral: `oxCreateServiceFromSeed(sxRandomBytes(32), ...)` — unlinkable per share | deterministic: `oxCreateServiceFromSeed(channelSeed, ...)`, address == the channel's existing pubkey (§6.1) |
| **What rides the onion** | the file bytes (§3.3) | the signed feed AND each release's bytes (§6.4, §6.5) |
| **Discovery** | the share code carries the `.onion` (§5.2) | the channel card carries / derives the `.onion` (§6.1) |
| **Toggle** | per-share checkbox `sTorSend` | per-channel flag `sChannels[i]["anon"]` (§6.2) |
| **Clearnet path when off** | unchanged BitTorrent swarm | unchanged DHT feed + magnet swarm |

The two invariants that keep the "anonymous" label honest are set in §3 and enforced at the branch points listed in
§5.7 and §6.9: (1) an anon transfer makes **no** libtorrent/DHT call for that payload, and (2) the anon and clearnet
paths are mutually exclusive for a given file. §7 owns the full threat model.

---

## 5. QuickShare — Model C design

QuickShare gains one optional send-side mode, **"Send privately over Tor."** When it is on, the dropped file's bytes
travel over an OnionXT stream (§3.3) to a fresh per-share hidden service (§3.4) and **no torrent is ever created** —
the mutual-exclusion invariant is enforced by making the onion branch of `qsShareFile` return before any
`btCreateTorrent`/`btAddTorrentFile` call. Everything in §3 (the two-stage probe `sHasOnion`/`sTorReady`, the
`qsOnion*` lifecycle, the framed streaming protocol, and the accept side) is assumed present under the `qs` prefix;
this section adds the QuickShare-specific glue.

### 5.0 The four transport/contents combinations

The Tor toggle and the existing passphrase field are **orthogonal and compose**. The passphrase is read at drop
time from `field "qsSendPass"`; the toggle is read from `sTorSend`.

| `qsSendPass` | Tor toggle (`sTorSend`) | Transport | Contents | Share code |
|---|---|---|---|---|
| empty | off (default) | clearnet BitTorrent | plaintext | bare 40/64-hex info-hash (unchanged) |
| set | off | clearnet BitTorrent | cryptoXT `.enc` | `BTXQS1:` … (unchanged) |
| empty | on | Tor onion stream | plaintext (circuit-encrypted only; **sender NOT authenticated**) | `BTXTOR1:<onion>:<b64name>::` |
| set | on | Tor onion stream | cryptoXT `.enc` (**recommended**) | `BTXTOR1:<onion>:<b64name>:<b64salt>:<b64verify>` |

Tor-on always implies **no torrent** for that file. The bottom-right cell (Tor + passphrase) is the recommended
"both" mode and is strongly steered: the circuit hides both IPs, cryptoXT hides the contents from the peer and at
rest **and authenticates the sender** (the plaintext cell does neither — see M3/§7.3).

### 5.1 UI affordances (edits inside `qsBuild`, line 127)

Bump `kQsUiVersion` (line 63) to `"qs-ui-2026-07"` so a saved stack rebuilds the card. `qsClearGeneratedUI` (202)
needs no change — both new controls are named `qs*`. Add two controls, both in the header cluster so the
send/receive/transfers geometry below is untouched:

1. **Live Tor status pill** — `qsLabel "qsTorPill", "Tor: off", "430,8,612,32", 10`, opaque, muted background,
   right-aligned, in the blue title band. Repainted only by `qsOnionPill` (§3.2). States are exactly the §3.2 table.
2. **Send-side toggle** — `qsButton "qsTorToggle", "Send privately over Tor", "440,44,600,72"`; two-state via
   `sTorSend` (not autoHilite). Shorten the existing tagline: change `qsTagline` from `"24,48,596,70"` to
   `"24,48,424,70"`.

At the tail of `qsBuild`, call `qsOnionPill` once so the pill and the toggle's enabled state paint immediately.
**VERIFY on-engine (§12.3 #30):** the pill/toggle rects do not overlap existing header controls after the tagline
shrink.

**Disabled-with-reason** is driven from `qsOnionPill` (runs on every status change and every 1 s `qsDashOnce`).
`qsOnionPill` additionally:
- disables `button "qsTorToggle"` (true) when `not sHasOnion` (tooltip "Needs OnionXT + cryptoXT + a local Tor
  daemon.") or when the control port never connected (tooltip "Start a local Tor daemon on 127.0.0.1:9051 or
  9151.");
- enables it (false) once control is connected (bootstrap may still be < 100%; the send-time guard handles that);
- when it disables the toggle while `sTorSend` was `"true"`, forces `sTorSend` back to `"false"` and un-hilites —
  so a mode the environment can't honor never stays silently armed.

**Receive side needs no toggle** — a pasted code beginning with `kTorCodePrefix` routes through the onion path
automatically (§5.4).

Tooltips to add in `qsAddTips` (273):
- `qsTorToggle`: "Off = normal peer-to-peer. On = send over Tor: both IP addresses are hidden and NO torrent is
  created (best for small, sensitive files). Add a passphrase to also encrypt and authenticate."
- `qsTorPill`: "Status of your local Tor connection. 'ready' means anonymous sends and receives will work."

`mouseUp` (110): add `case "qsTorToggle"` → `qsToggleTor`.

### 5.2 New share-code format `BTXTOR1:`

New constant (declare literal, with the other constants near line 54): `constant kTorCodePrefix = "BTXTOR1:"`.

Layout — colon-delimited, every variable field base64:

| Field | Content | Encoding | Contains ':'? |
|---|---|---|---|
| prefix | `kTorCodePrefix` | ASCII literal `BTXTOR1:` | — |
| onion | the service address | base32 `[a-z2-7]` + `.onion` | no |
| b64name | filename **leaf** | `qsB64(textEncode(SafeLeaf(name),"UTF-8"))` | no |
| b64salt | Argon2id salt (16 B) — **empty when plaintext** | `qsB64(salt)` / `""` | no |
| b64verify | sealed `kQsVerify` — **empty when plaintext** | `qsB64(verifier)` / `""` | no |

The v3 `.onion` (56 base32 chars + `.onion`) never contains `:`; base64 never contains `:`. So
`set the itemDelimiter to ":"` + `item N of tRest` parses cleanly — identical discipline to the `BTXQS1:` parser.
**Backward-compat (VERIFY, §12.3 #17):** confirm a pre-Model-C build rejects an unknown `BTXTOR1:` prefix cleanly
(it is neither a 40/64-hex hash nor `BTXQS1:`), rather than mis-parsing it.

**Builder** — new function parallel to `qsMakeCode` (751), reusing `qsB64` (740):

```
function qsMakeTorCode pOnion, pName, pSalt, pVerifier
   return kTorCodePrefix & pOnion & ":" & qsB64(textEncode(qsSafeLeaf(pName),"UTF-8")) & ":" & \
      qsB64(pSalt) & ":" & qsB64(pVerifier)
end qsMakeTorCode
```

For a plaintext anon share, `pSalt`/`pVerifier` are empty → `qsB64("")` yields `""` → the code is
`BTXTOR1:<onion>:<b64name>::`. The parser treats an empty verifier exactly as the `BTXQS1:` path does.

**The up-front passphrase check is preserved unchanged.** For an encrypted anon share the sender still derives the
key from `sxPwHash(...)` and seals `kQsVerify` with `sxSecretBox` into `pVerifier`. The receiver still calls
`qsKeyOpensVerifier` (758) **before dialing**, so a wrong passphrase is caught with no network activity (§5.4
step 3).

### 5.3 SEND state machine

`qsShareFile` (358) gains a **first-priority onion branch**, inserted after `tName`/`tParent`/`tPass` are computed
(after line 387) and **before** the existing `if tPass is empty` clearnet split:

```
if sTorSend is "true" then
   if not sHasOnion then
      qsLog "Turn off 'Send privately over Tor' or install OnionXT + cryptoXT + a local Tor daemon."
      exit qsShareFile
   end if
   if not qsOnionReadyNow() then                              -- live, authoritative (§3.1)
      qsLog "Tor is still connecting - watch the pill, then drop the file again."
      exit qsShareFile                                        -- never fall back to clearnet
   end if
   qsStartOnionShare pPath, tName, tPass                      -- NO torrent is created below
   exit qsShareFile
end if
```

**Folder drops.** Clearnet QuickShare accepts a dropped folder (`btCreateTorrent`), but the §3.3 header is
single-file. On the anon path, `qsStartOnionShare` first checks whether `pPath` is a folder; if so it either
**zips the folder to one temp** (`name = "<folder>.zip"`, streamed as a single payload) or, if zipping is
unavailable, **refuses with a clear message** ("Anonymous send handles one file at a time; zip the folder first").
The demo default is refuse-with-message; the zip path is a documented enhancement. This closes the previously
unhandled folder case.

New command **`qsStartOnionShare pPath, pName, pPass`** (all locals declared at top):

1. **Size guard (wire §11.2).** Read the byte count (step 2). If `tTotal > kAnonSizeWarn` (256 MiB), warn:
   "This file is large for anonymous transfer; it will be slow. For big media, share it on the public swarm (which
   reveals your IP) instead." — proceed only on explicit confirm; **never** auto-downgrade to clearnet.
2. **Total size without loading the file.** Read the byte count from the folder listing (`the detailedFiles of
   <parent>`, item 2 of the matching row), never by reading the file into a Data. Stash as `tTotal`.
3. **Encrypt-or-plain (reuse the existing crypto path).** If `pPass` is not empty and `sCanEncrypt`:
   `put sxRandomBytes(16) into tSalt`; `put sxPwHash(textEncode(pPass,"UTF-8"), tSalt, 32, "2",
   sxPwMemInteractive()) into tKey`; `put sxSecretBox(textEncode(kQsVerify,"ASCII"), tKey) into tVerifier`;
   `put qsTempEncPath() into tEncPath`; **register `tEncPath` in `sTempEnc` NOW** (before the encrypt that can
   throw); `qsEncryptFile pPath, tEncPath, tKey` — on error, log, delete the temp, exit. The file to stream is
   `tEncPath`; `tEncFlag = kFlagEnc`. Otherwise the file to stream is `pPath`, `tEncFlag = 0` (and if `pPass` was
   set but `sCanEncrypt` false, log-and-continue plaintext as at 384).
4. **Fresh, unlinkable onion per share.** `put oxCreateServiceFromSeed(sxRandomBytes(32), kOnionVirtualPort,
   <ephemeralPort>) into tSvc` → capture the service handle and the `.onion`; the random seed is discarded.
5. **Arm the loopback listener once, on an ephemeral port.** If `sOnionListening` is not `"true"`: bind an
   ephemeral loopback port, `accept connections on <ephemeralPort> with message "qsOnionAccept"`;
   `oxSetPeerCallback "qsOnionPeer"`; `put "true" into sOnionListening`. Handle bind failure gracefully.
6. **One active anon share at a time (one service per session).** If a previous `sActiveShare` holds a service
   handle, tear it down first: `oxRemoveService` its handle and delete its temp `.enc`. Then stash the record
   (`sActiveShare["path"|"name"|"enc"|"key"|"salt"|"verify"|"total"|"encTmp"|"service"|"ready"]`), keeping the REAL
   sanitized name for display/header/code.
7. **Advertise only when reachable.** Do **not** put an address in `qsCode` yet. Show progress
   ("Publishing a private Tor address for ...") and arm a **publish timeout** (`kPublishTimeout`, e.g. 90000): if
   `qsOnionServiceReady` has not fired by then, surface the §13.3 "descriptor not uploaded" failure, tear down the
   half-built service, and re-enable the drop.
8. **`qsOnionServiceReady pService` fires** → build and reveal the code via `qsMakeTorCode(oxServiceAddress(
   pService), sActiveShare["name"], sActiveShare["salt"], sActiveShare["verify"])`; set `field "qsCode"`; set the
   `qsSharing` banner (encrypted vs plaintext copy, "keep this window open"); log.
9. **A receiver dials in → `qsOnionPeer pStream`:** if `sActiveShare` is empty, `oxCloseStream pStream`. Otherwise
   seed a **send** progress entry (§5.5) keyed by `pStream`, register the stream callbacks, and on
   `qsOnionStreamReady` start `qsOnionSend pStream, sActiveShare["path"], sActiveShare["name"],
   sActiveShare["enc"], sActiveShare["total"]`. Because QuickShare restricts a share to **one active receiver at a
   time** (§3.3 step 6a), a second concurrent dial is refused-with-log until the first finishes; a **sequential**
   retry re-uses the same code.
10. **Keep the service alive** across and after the transfer (so a sequential retry works) until the share is
    replaced (step 6), withdrawn, or `qsOnionStop` runs. The per-stream file handle closes when that stream
    finishes; the service persists.

**Sharing status shown:** the `qsSharing` banner plus a live "sending via Tor" row in the Transfers list with a real
byte-progress bar (§5.5). No `torrentAdded`/`metadataReceived` events ever appear (§3.5).

> **Resolved review findings (§5.3).** M5 → temp registered before the throwing encrypt. M7 → publish timeout.
> #8 → folder drops handled (zip-or-refuse). #12 → `kAnonSizeWarn` wired at the send entry. H6 →
> one-active-receiver default for QuickShare. M8/#11 → ephemeral loopback port, one service per session.

### 5.4 RECEIVE state machine

`qsGetFile` (476) gains a `kTorCodePrefix` branch, checked **first**:

1. **Parse.** `set the itemDelimiter to ":"`; `tOnion = item 1`, `tB64 = item 2`, `tB64Salt = item 3`,
   `tB64Verify = item 4` of the post-prefix rest. Reject with a clear log if `oxIsValidAddress(tOnion)` is false.
2. **Capability gate.** If `not sHasOnion`: log "This is a private Tor share, but OnionXT (or cryptoXT) is not
   installed - ask your friend to share it normally, or install OnionXT + cryptoXT + Tor." and exit. Decode the
   name through `qsSafeLeaf(textDecode(base64Decode(tB64),"UTF-8"))`; fall back to `"shared-file"` if empty.
3. **Passphrase, verified locally BEFORE dialing.** If `tB64Verify` is not empty (encrypted share): require
   `sCanEncrypt` and a non-empty `qsRecvPass` (else prompt/exit). Derive `tKey = sxPwHash(...)` and call
   `qsKeyOpensVerifier(tKey, tB64Verify)` (758); on mismatch, reuse the wrong-passphrase UX at 525–529 and exit —
   **no dial, no bytes**. If `tB64Verify` is empty, this is a plaintext anon share: skip, `tKey` empty. **Surface
   the plaintext-authenticity caveat** in the UI here ("This code is not encrypted; your IP is hidden but the
   sender is not verified — anyone who intercepts the code could substitute a file. Ask for a passphrase for a
   verified transfer.") — the "anon" label must not imply endpoint authenticity for the plaintext cell (M3).
4. **Live readiness.** If `not qsOnionReadyNow()`: log "Tor is still connecting - try Download again in a moment."
   and exit — never fall back to the swarm.
5. **Dial (async).** Register the stream callback, then `put oxDial(tOnion, kOnionVirtualPort) into tStream`.
   OnionXT returns a live handle or a mapped SOCKS error string; the discriminator is **robust** — a numeric-looking
   error or empty string must not be mistaken for a handle (use OnionXT's documented success form; VERIFY §12.3).
   If not a live handle, log the mapped error and exit. Gate the first `oxWrite` on `qsOnionStreamReady`; arm the
   §3.3 receive watchdog and a dial/handshake timeout at dial time.
6. **Wire the receiver.** Initialize the §3.3 per-stream receiver state plus QuickShare's `sRxKey[tStream] = tKey`,
   `sRxName[tStream] = tName` (the header name, sanitized, wins if present), `sRxSave[tStream] = qsSaveFolder()`.
   Seed a **receive** progress entry (§5.5). Clear `field "qsRecvCode"`; log "Connecting privately over Tor ...".
7. **Stream in → `qsOnionStreamData`** (§3.3) parses the header, prefers the header's sanitized UTF-8 name over the
   code's, sets `sRxEnc` from the header's `kFlagEnc`, opens the temp, drains frames with compaction.
   - **Header/key reconciliation & downgrade refusal (M4):** if the **code carried a verifier/salt** (the share was
     advertised encrypted and the passphrase was proven), the header **must** set `kFlagEnc` — a plaintext header in
     that case is a downgrade attack: **abort** with "This share was supposed to be encrypted but arrived
     unencrypted - do not trust it." If the header sets `kFlagEnc` but `sRxKey` is empty, abort with "This file is
     encrypted but the code had no passphrase - ask your friend to re-share." If both code and header are plaintext,
     proceed and ignore any key.
8. **"done":** verify `sRxGot == sOnionXfers[pStream]["total"]`; on mismatch abort (§5.6). If `sRxEnc`:
   `qsDecryptFile(sRxTmp, sRxSave & "/" & qsSafeLeaf(sRxName), sRxKey)` then delete the temp; else move the temp to
   `sRxSave & "/" & qsSafeLeaf(sRxName)`. Mark done; log; `oxCloseStream`; clear the `sRx*` slots.

`qsHandleEvent` (616) and `qsMaybeDecryptFinished` (807) are **not** involved on the anon path and stay as-is.

> **Resolved review findings (§5.4).** C1 → `qsSafeLeaf` on both the code name and the header name. H1 → async dial,
> callback-before-dial, first write gated on ready. M3 → plaintext-authenticity caveat surfaced. M4 → header-flag
> downgrade refused when the code proved encryption.

### 5.5 Transfers view — the parallel in-script progress model

An onion transfer has **no torrent handle**, so `btTorrentCount`/`btTorrentHandleAt`/`btTorrentStatus` never see it
and `qsRole` (657) does not apply. Define a script-local model updated entirely from §3.3 state.

**`sOnionXfers`** — array keyed by the stream handle: `name`, `dir` (`"sending"`/`"receiving"`), `enc`, `total`,
`got`, `state` (`connecting`/`active`/`done`/`error`), written at the seed sites and each pump/data call.

**`qsRefreshXfers` (565) extension** — after the existing torrent loop (after 599, before the "Nothing yet"
fallback), append onion rows in the **same** `name TAB dir TAB bar` format:

```
repeat for each key tK in sOnionXfers
   put sOnionXfers[tK] into tE
   put tE["dir"] & " via Tor" into tDir
   if tE["enc"] then put tDir && "(locked)" into tDir
   if tE["state"] is "connecting" or tE["total"] is 0 then
      put qsTrunc(tE["name"],26) & tab & tDir & tab & "connecting..." & return after tRows
   else
      put (the round of (tE["got"] / tE["total"] * 1000) / 10) into tPct
      put qsTrunc(tE["name"],26) & tab & tDir & tab & qsBar(tPct) & return after tRows
   end if
   add 1 to tLineNum
end repeat
```

So a row reads e.g. `holiday.zip  receiving via Tor (locked)  [####------] 40%`. `qsBar` (674) / `qsTrunc` (703)
reused; the "via Tor" text is the distinct anon tag that makes the mode visible (the §7.3 no-silent-mix guard is
user-visible). `qsRole` untouched. Completed/failed entries stay for the session and are pruned in `qsStop` (bounded
growth is a known minor limit for very long-lived apps).

### 5.6 Fallbacks, cleanup, and early close

- **No OnionXT/cryptoXT (`sHasOnion` false):** `qsTorToggle` disabled with tooltip; the onion branch is unreachable
  (guarded twice); plain and `BTXQS1:` paths byte-for-byte unchanged. A pasted `BTXTOR1:` code is refused with a
  clear install message (§5.4 step 2) — never a crash.
- **No Tor daemon:** toggle disabled, pill names the fix; anon send/receive refuse; clearnet unaffected.
- **Mid-bootstrap:** both `qsStartOnionShare` and `qsGetFile` gate on `qsOnionReadyNow()` and **refuse** (no queue,
  no swarm leak).
- **Sender temp `.enc`:** registered at creation in `sActiveShare["encTmp"]` and `sTempEnc`; deleted on replace and
  swept by `qsStop` (319–327) and `qsOnionStop`.
- **Receiver temp:** `sRxTmp[pStream]`, registered at open, deleted after decrypt, on any abort, and in
  `qsOnionStop`.
- **Service teardown:** `oxRemoveService` on replace/withdraw/`qsOnionStop`; `close socket` on the loopback
  listener. All idempotent.
- **Sender closes early / offline:** the receiver's `qsOnionStreamClosed` (or listener `socketError`/`socketClosed`,
  or the idle watchdog) fires while state ≠ `"done"` → abort, temp deleted, `state` = "error", log "The sender went
  offline before the transfer finished ...". Because the service persists while the sender's window is open, the
  receiver can Download the **same** code again — **from byte 0** (no resume; §3.3).
- **Receiver drops mid-send:** the sender's stream callback closes → pump stops, `close file`, that stream's entry
  "error"; the service and `sActiveShare` stay up for the next sequential receiver.
- **Timeouts:** the §3.3 self-arming watchdogs drive the same abort paths on an idle stall.
- **No-resume limit stated to the user:** the encrypted/plaintext banners and the error copy note that an
  interrupted anonymous transfer restarts from the beginning.

### 5.7 Exact edit points

**Existing handlers/constants modified:**
- `kQsUiVersion` (63): bump to `"qs-ui-2026-07"`.
- Constants block (~54): add `kTorCodePrefix`, `kAnonSizeWarn`; the §3.2 `kTor*`/`kOnion*`/`kFlag*`/`kMax*`/
  `k*Timeout`/`kPumpTick` constants are added per §3.
- State locals (40–47): add `sTorSend`, `sHasOnion`, `sTorReady`, `sActiveShare`, `sOnionXfers`, `sOnionListening`
  (foundation adds the `sTx*`/`sRx*` per-stream arrays and `sRxKey`/`sRxName`/`sRxSave`).
- `qsBuild` (127): add `qsTorPill` + `qsTorToggle`, shorten `qsTagline`, call `qsOnionPill` at the tail.
- `qsAddTips` (273): add both tooltips.
- `mouseUp` (110): add `case "qsTorToggle"` → `qsToggleTor`.
- `qsStart` (285): after 300, add `put qsHasOnion() into sHasOnion`, `put "false" into sTorSend`,
  `if sHasOnion then qsOnionStart`.
- `qsStop` (310): before `btStopSession`, call `qsOnionStop`; then `put empty into sOnionXfers`.
- `qsShareFile` (358): insert the first-priority onion branch after 387 (incl. folder zip-or-refuse).
- `qsGetFile` (476): insert the `kTorCodePrefix` branch ahead of `kCodePrefix`.
- `qsRefreshXfers` (565): append the `sOnionXfers` rows.
- `qsHandleEvent` (616), `qsMaybeDecryptFinished` (807), `qsClearGeneratedUI` (202), `qsRole` (657): **unchanged**
  (documented no-ops on the anon path).

**New QuickShare-specific handlers added:** `qsToggleTor`; `qsSafeLeaf`; `qsMakeTorCode`; `qsStartOnionShare`; and
the QuickShare bodies of the foundation callbacks — `qsOnionServiceReady`, `qsOnionPeer`, `qsOnionStreamReady`, the
`"done"`/abort logic inside `qsOnionStreamData` / `qsOnionStreamClosed`, `qsOnionSendWatchdog`,
`qsOnionRecvWatchdog`, and `qsOnionPill` (also toggles the disabled state + tooltip).

**Foundation handlers assumed present (from §3, under `qs`):** `qsHasOnion`, `qsOnionReadyNow`, `qsOnionStart`,
`qsOnionStop`, `qsOnionStatus`, `qsOnionPill`, `qsOnionSend`, `qsOnionPump`, `qsOnionStreamData`, `qsOnionAccept`.

---

## 6. DHT Channels — Model C design

This section adds an optional, per-channel **"Anonymous channel (Tor)"** capability to
`torrent-dht-channels.livecodescript`, on the shared onion substrate from §3 (pasted in under the `ch` prefix:
`chHasOnion`, `chOnionReadyNow`, `chOnionStart/Stop/Status/Pill`,
`chOnionSend/Pump/StreamData/StreamClosed/Peer/ServiceReady/Accept`, and the §3.3 per-stream state). Section 6 adds
the channels-specific request protocol, the identity unification, and the branch points.

An anon channel means: the channel's **feed AND its files travel over the channel's own Tor onion service**, never
over DHT/BitTorrent. It is **orthogonal to the existing passphrase privacy** (`sChannels[i]["pass"]`). All four
states compose:

| anon | pass | Menu label | Transport gives |
|---|---|---|---|
| off | empty | `Name` | public swarm + public DHT feed (today's default) |
| off | set | `Name (private)` | public swarm of *ciphertext*, secretbox feed on DHT |
| on | empty | `Name (anon)` | feed+files over Tor; IPs hidden; no DHT graph (sender not authenticated beyond the pubkey-bound onion) |
| on | set | `Name (private) (anon)` | Tor route **and** cryptoXT contents (recommended) |

### 6.1 Identity unification — an anon channel needs no new key

A channel already owns an ed25519 identity: `btDhtKeypair(sChannels[i]["seed"])["publicKey"]` (64-hex), used as the
BEP44 public key and the shareable address. `oxCreateServiceFromSeed(seed,…)` derives its ed25519 key with the same
standard seed→key expansion, so the onion service built from the **same seed** embeds the **same 32-byte pubkey**.
Therefore:

- The channel's onion address is **derivable from the pubkey alone**:
  `chChannelOnionAddr(pPubHex) = oxAddressFromPublicKey(sxHex2Bin(pPubHex))`.
- The publisher runs the service with `oxCreateServiceFromSeed(sChannels[i]["seed"], …)`; the follower, holding
  only the 64-hex key from the channel card, computes the **identical** `.onion` locally and dials it.
- **Privacy caveat (`chHelp`):** the onion is cryptographically bound to the channel pubkey, so the `.onion` and the
  channel identity are linkable by design (fine for a *named* channel). Use a separate channel with an independent
  seed for an unlinkable onion.

**`svc=` feed-line contingency (resolves the broken fallback).** The plan **also** publishes the onion address as a
`svc=<onion>` line in the feed schema (built in `chBuildFeed`, parsed in `chRefreshSubs`). On the happy path this is
mere corroboration — the follower derives the same address from the pubkey. But if the seed↔pubkey equivalence
VERIFY (below) ever **fails**, the `svc=` line is the **source of truth**: the follower dials the published address
rather than a derived one, and the docs drop the "derivable from pubkey" claim. Without `svc=`, a VERIFY failure
would leave §6 with no way to reach the service — so `svc=` is included from the start as the contingency.

**VERIFY (hard Phase-2 gate): libtorrent-ed25519 == libsodium-ed25519 for one seed.** If the two stacks disagreed
(clamping, seed interpretation), the follower would derive and dial the *wrong* onion. Two checks:

`function chVerifyOnionIdentity` (returns boolean → `sOnionIdentityOk`), run once at startup, **offline** (no
daemon):
1. `put "<64 hex zeros>" into tSeed` — a fixed, reproducible test seed.
2. **The real cross-impl check (corrected):** `put btDhtKeypair(tSeed)["publicKey"] into tBtPub` and
   `put sxSignKeypairFromSeed(tSeed)["publicKey"] into tSxPub` (both **pure crypto, no Tor**), and **assert
   byte-for-byte** `sxHex2Bin(tBtPub) == tSxPub` (compare as `Data`). This is the assertion that actually exercises
   libsodium's seed→key expansion against libtorrent's — the earlier codec self-round-trip
   (`oxAddressFromPublicKey`→`oxPublicKeyFromAddress`) only proved OnionXT's address codec is self-inverse and gave
   false confidence.
3. Additionally assert the address codec is self-consistent:
   `oxPublicKeyFromAddress(chChannelOnionAddr(tBtPub)) == sxHex2Bin(tBtPub)`.
4. **Stronger, when a real service is first created** (`chOnionServiceFor`, needs Tor): assert
   `oxServiceAddress(handle) == chChannelOnionAddr(pub)` byte-for-byte — proving `oxCreateServiceFromSeed(seed)`
   produced exactly the onion the pubkey predicts, end to end.

Any offline failure ⇒ `put false into sOnionIdentityOk`, loud `chLog`, **anon disabled** (the toggle refuses,
`chOnionServiceFor` never runs). A mismatched onion is worse than no anon at all.

> **Resolved review findings (§6.1).** H5 → the offline gate now compares `btDhtKeypair` vs `sxSignKeypairFromSeed`
> byte-for-byte, not a codec self-round-trip. #7 → `svc=` line added to the feed schema as the concrete fallback
> when the equivalence VERIFY fails.

### 6.2 Persistence — one new array field

Add `anon` to each channel element: `sChannels[i]["anon"]` = `"true"` / empty. It rides the existing
`arrayEncode(sChannels)` → `uChannels` → sealed-prefs path with **no new persistence code**.

- **`chDeleteChannel` (653) — REQUIRED edit:** the rebuild loop must copy `anon` alongside `seed/name/releases/
  pass`, else deleting any channel silently clears the anon flag of every survivor.
- `chNewChannel` (582) and `chEnsureIdentity` (490): set `"anon"` to `""` for cleanliness.

New follower-side persistence, parallel to `sFollowPass`/`uFollowPass`: `sFollowAnon` (followed pubkey → `"true"`),
mirrored to stack prop `uFollowAnon`, loaded in `chLoadFollows` (685) and saved in `chFollow`/`chUnfollow`.
**Backward-compat (#17):** `chLoadFollows` must default `uFollowAnon` to empty on old saved stacks.

**`command chSetAnon`** (new; modeled on `chSetPrivacy` 620):
1. If `not sHasOnion` → `answer` "Anonymous channels need OnionXT + cryptoXT and a local Tor daemon
   (127.0.0.1:9050/9051 or 9150/9151). Public channels are unaffected." ; exit.
2. If `not sOnionIdentityOk` → refuse with the VERIFY-failed message; exit.
3. `answer` the full privacy explanation (files+feed over Tor only; no DHT/swarm; IP hidden between onion
   endpoints; large media is slow; publisher must be online for followers to reach it) — **On** / **Off** /
   **Cancel**.
4. **Turning ON — deanon HARD-BLOCK (corrected, §6.7):** if the channel already holds clearnet magnet releases
   (`sChannels[sActive]["releases"]` has any item-2 beginning with `magnet:`, or any matching `sMineHashes` seed is
   live), **refuse to enable anon until the user removes them** — do not warn-and-proceed. Offer a one-click
   "Remove the N public releases and stop seeding them" that `btRemoveTorrent`s every matching `sMineHashes` entry;
   only after they are gone does `["anon"]` flip. An anon badge over a still-seeding torrent (real IP on the DHT) is
   exactly the mixing this plan forbids.
5. `put "true" into sChannels[sActive]["anon"]` (or empty for Off); `chSaveChannels`.
6. ON ⇒ `chOnionServiceFor sActive` (lazily, only if `chOnionReadyNow()`; else it comes up via
   `chOnionBringUpServices`). OFF ⇒ `chOnionWithdrawService sPub` and resume normal DHT announce.
7. `chUpdateChannelMenu` ; `chUpdateNowPub` ; `chLog`.

`function chIsAnonChannel pIndex` → `sChannels[pIndex]["anon"] is "true"`.

> **Resolved review findings (§6.2).** H4 → turning anon ON **hard-blocks** on any live clearnet release (matching
> §7.3), replacing the warn-and-offer behavior. #17 → `uFollowAnon` defaults empty on old stacks; old 2-field cards
> are addressed in §6.8.

### 6.3 Per-channel onion service lifecycle (publisher side)

Each anon channel runs **its own** deterministic service (a distinct onion per channel is required so followers
reach a stable per-channel address). Each service gets its **own ephemeral loopback port** (not a fixed
base+index), removing the fixed-port collision risk.

New tracking arrays (keyed by channel pubkey hex): `sChanService[pub]`, `sChanServiceAddr[pub]`,
`sChanServicePort[pub]`; and `sFeedStreams[pub]` = the currently-subscribed follower stream handles (for real-time
push).

**`command chOnionServiceFor pIndex`:**
1. Guard: `chIsAnonChannel(pIndex)` and `sOnionIdentityOk` and `chOnionReadyNow()`; else return (retry later).
2. `put btDhtKeypair(sChannels[pIndex]["seed"]) into tKp` → `tPub`. If `sChanService[tPub]` set, exit (idempotent).
3. Bind an ephemeral loopback port `tPort`; `accept connections on tPort with message "chOnionAccept"`;
   `oxSetPeerCallback "chOnionPeer"`.
4. `oxCreateServiceFromSeed sChannels[pIndex]["seed"], kOnionVirtualPort, tPort` → service handle + `.onion`; stash.
5. **VERIFY-on-service:** assert `oxServiceAddress(handle) == chChannelOnionAddr(tPub)` byte-for-byte (§6.1 step 4);
   mismatch ⇒ withdraw, `put false into sOnionIdentityOk`, disable anon, loud log.
6. Advertise only when reachable: `chOnionServiceReady` flips a per-channel "reachable" flag; also **write the
   `svc=<onion>` line into the channel's feed** so followers on the fallback path can reach it.

**`command chOnionBringUpServices`** — iterate all channels, `chOnionServiceFor tI` for each anon one not yet up.
Called (a) from `chOnionStatus` the first time `oxIsReady()` goes true, and (b) defensively from `chChannelTick`.
Brings anon services online after bootstrap without blocking `chStart`.

**`command chOnionWithdrawService pPubHex`** — `oxRemoveService`, `close socket` on its port, clear the tracking
arrays and `sFeedStreams[pPubHex]`. Idempotent. Called from `chSetAnon` (Off), `chDeleteChannel`, `chOnionStop`.

Hook points:
- **`chStart` (453):** after 471 add `put chHasOnion() into sHasOnion` and
  `put chVerifyOnionIdentity() into sOnionIdentityOk`; at the tail, when `sHasOnion`, `chOnionStart`.
- **`chActivate` (534):** at the end, `if chIsAnonChannel(sActive) then chOnionServiceFor sActive`.
- **`chStop` (707):** `chOnionStop` **before** `btStopSession`.

**Concurrent services (VERIFY, §12.3):** running N services at once is an OnionXT capability that must be confirmed
before Phase 2.

### 6.4 Feed rendezvous over onion

For an anon channel the signed feed is **served over the onion**, not `btDhtPutMutable`. Same bytes (`chFeedValue`
output — plaintext UTF-8 or `BTXENC2:`+secretbox), a different transport, plus **real-time push** and NAT traversal.

**The channels request layer** sits *above* the §3.3 file protocol.

Onion **request** frame (client → publisher, sent once after `oxDial` connects — gated on `chOnionStreamReady`):

| Field | Bytes | Encoding | Meaning |
|---|---|---|---|
| magic | 4 | ASCII `BTXC` | channels request magic |
| version | 1 | `numToByte(1)` | `kChanReqVer` |
| verb | 1 | `numToByte(v)` | `1`=FEED, `2`=FILE |
| keyLen | 2 | u16 BE (`"n"`) | length of channel pubkey hex (always 64) |
| key | keyLen | ASCII hex | target channel pubkey; server validates it **owns** it |
| idLen | 2 | u16 BE (`"n"`) | releaseId length (`0` for FEED) |
| id | idLen | ASCII | releaseId for FILE; empty for FEED |

Feed **response** frame (publisher → follower; repeatable for live push):

| Field | Bytes | Encoding | Meaning |
|---|---|---|---|
| magic | 4 | ASCII `BTXF` | feed frame magic |
| version | 1 | `numToByte(1)` | |
| valLen | 4 | u32 BE (`"N"`), **≤ a sane feed cap** | length of the feed value |
| value | valLen | raw | exactly `chFeedValue(feed, pass, pub)` bytes |

```
constant kChanReqMagic   = "BTXC"
constant kChanReqVer     = 1
constant kFeedFrameMagic = "BTXF"
constant kVerbFeed       = 1
constant kVerbFile       = 2
```

**Publisher — serve a request.** `chOnionPeer pStream` fires; register the stream callback and mark role
`"serve-req"`. When a full `BTXC` request has accumulated, hand it to **`command chOnionServeRequest pStream,
pReq`:**
1. `binaryDecode` magic/ver/verb/key/id; reject unless magic==`BTXC`, ver==1, and `key` matches a channel we own
   that `chIsAnonChannel` — else `oxCloseStream`.
2. **FEED:** build `chFeedValue(chBuildFeed(name,releases), pass, pub)`, wrap in `BTXF`, `oxWrite`. Then
   **subscribe** this stream: **de-dup by handle** and **cap subscribers per channel** (evict the oldest / idle
   past a TTL) when appending `pStream` to `sFeedStreams[pub]`. Keep the stream open.
3. **FILE:** look up `sOnionServe[pub & ":" & id]`. If found, `chOnionSend pStream, <path>, <origName>, <encFlag>,
   <total>` (§3.3 sender, **re-open-per-read** for fan-out, §3.3 step 6b). If not found (e.g. restart lost the
   in-memory map), reply with an empty `BTXO` header + immediate FINISH and log — the follower shows "release not
   currently available."

**Publisher — push on change.** `command chOnionPushFeed pPubHex`: for each stream in `sFeedStreams[pPubHex]`,
`oxWrite` a fresh `BTXF` frame (stale/closed handles are clean no-ops; **prune them here AND on
`oxStreamClosed`**, not only lazily). This makes anon feeds **real-time** vs the 60-s DHT tick.

**Nonce discipline (M9, VERIFY + KAT).** Real-time push re-seals the `sxSecretBox` feed far more often than the 60-s
DHT tick. Confirm `chFeedValue`/`sxSecretBox` uses a **fresh random nonce per encryption** (prepended to the
ciphertext) and that push **re-seals** rather than caching one nonce+ciphertext — otherwise repeated pushes under a
fixed key reuse the XSalsa20 keystream and leak plaintext. Add a KAT that two seals of the same feed value differ
and each opens.

**Follower — fetch over onion.** `command chOnionFollowFetch pKey`:
1. Guard `chOnionReadyNow()`; else set the "Tor still connecting" placeholder, `chRefreshSubs`, return.
2. Resolve the address: prefer the pubkey-derived `chChannelOnionAddr(pKey)`; if the VERIFY fell back (§6.1), use
   the feed's `svc=` line. Register the stream callback, then `put oxDial(<addr>, kOnionVirtualPort) into tStream`
   (**async**). If a mapped SOCKS error → **offline path** (§6.8), placeholder, log, return.
3. Stash `sFollowStream[pKey]=tStream`; role `"follow-feed"`; on `chOnionStreamReady`, `oxWrite` a `BTXC` FEED
   request; arm the §3.3 handshake watchdog.
4. Each inbound `BTXF` frame → extract `value` → feed through the **existing** `chReadFeed(value, sFollowPass[pKey],
   pKey)` exactly as the DHT path does (plaintext / `LOCKED` / `BADPASS`); store in `sFollowFeeds[pKey]`;
   `chRefreshSubs`. Passphrase, signature-authenticity, and empty-feed rendering are **unchanged** — only the byte
   source moved.

**Branching in existing feed handlers:**
- **`chPublishActiveFeed` (1870):** at the top, `if chIsAnonChannel(sActive) then chOnionPushFeed sPub` and
  **return 0** — never `btDhtPutMutable`. Public channels fall through unchanged.
- **`chChannelTick` (916):** in the publish loop, `if chIsAnonChannel(tI) then next repeat` **before** the
  `btDhtPutMutable` (push to `sFeedStreams[tPub]` instead). In the follower loop,
  `if sFollowAnon[tKey] is "true" then chOnionFollowFetch tKey else btDhtGetMutable …`. Also call
  `chOnionBringUpServices` here so services recover after a Tor restart.
- **`chHandleEvent` → `dhtMutableItem` (1705):** guard at entry: `if sFollowAnon[pEvent["publicKey"]] is "true"
  then break` — ignore any DHT value for a channel we follow anonymously (a stale artifact of the channel's public
  past must not overwrite the onion feed).

**DHT stays the explicit public-only fallback** — never a "try onion then DHT" for an anon channel.

> **Resolved review findings (§6.4).** M1/#20 → subscriber list capped, de-duped, actively pruned on close.
> M9 → nonce-per-seal confirmed + KAT. H1 → async dial, request gated on ready. `valLen` capped (C2 class).
> H6 → file fan-out uses re-open-per-read.

### 6.5 Anonymous file delivery

An anon release is **streamed over the onion on demand** (§3.3), never packaged as a torrent.

**Release-locator encoding (item 2 of the `r=` feed line).** Today: `title TAB magnet [TAB "enc" TAB origName]`.
Keep the schema; only the item-2 locator changes for anon:

| Release kind | item 1 | item 2 (locator) | item 3 | item 4 |
|---|---|---|---|---|
| public, plain | title | `magnet:?xt=urn:btih:…` | — | — |
| public, encrypted | title | `magnet:?xt=urn:btih:…` | `enc` | origName |
| **anon, plain** | title | `onion:<relId>` | — | — |
| **anon, encrypted** | title | `onion:<relId>` | `enc` | origName |

`relId` = 16 hex chars from `chAllocRelId` (`bin2hex(sxRandomBytes(8))`). The `.onion` is **not** embedded — the
follower derives it from the channel pubkey (§6.1) or reads the feed's `svc=` line; the locator only names the
release. `chRefreshSubs` needs no parse change; only the row label gains an "(anon)" hint (§6.8).

**Publisher serve map** (in memory): `sOnionServe[pub & ":" & relId]` = absolute path; `sOnionServeEnc/Name/Total`.
**Restart persistence (corrected from "stretch" to a real gap, #19):** persist the serve map as `uOnionServe` (an
`arrayEncode` alongside the other sealed props), **or** prune unrecoverable relIds from the feed on load so a
restarted publisher never advertises releases it cannot serve. The demo default is **prune-on-load with a log**
("N anonymous releases could not be restored; re-publish them"); persisting `uOnionServe` is the documented
enhancement.

**`command chOnionPublishFile`** (the anon replacement for the clearnet body of `chPublishFile`):
1. `answer file` to pick ONE file (anon publish is per-file — it is streamed). A folder is refused with the same
   zip-or-refuse message as QuickShare (§5.3).
2. Prompt for a title; capture `tOrig`.
3. **Compose with encryption** (recommended): if `sChannels[sActive]["pass"]` is not empty and `sCanEncrypt`,
   register the temp first, then `chEncryptFile tPath, chTempEncPath(), chFileKey(pass, sPub)` → serve the `.enc`,
   set `enc` + `kFlagEnc`; else serve the plaintext original.
4. `put chAllocRelId() into tRelId`; record `sOnionServe[sPub & ":" & tRelId]` and Enc/Name/Total.
5. Build `chTrunc(title,60) & tab & ("onion:" & tRelId)` (+ `tab & "enc" & tab & tOrig` when encrypted) and call the
   **unchanged** `chAddReleaseAndPublish tRel, title, ("ANON"/"ENCRYPTED")` — which trims to the 920-byte budget,
   `chSaveChannels`, and calls `chPublishActiveFeed` (now **pushes over onion**). **No `btCreateTorrent`, no
   `btAddTorrentFile`, no `sMineHashes`, no magnet.**
6. Add a local progress row via `sOnionXfer` (§6.8).

**Branch in `chPublishFile` (945):** first line after the `sSession is 0` check — `if chIsAnonChannel(sActive) then
chOnionPublishFile` and `exit chPublishFile`. The hard fork that keeps `btCreateTorrent`/`btAddTorrentFile`
unreachable for an anon channel.

**Follower download — `command chOnionDownload pKey, pRelId, pTitle, pEnc, pOrigName`:**
1. Guard `chOnionReadyNow()`; else log "Tor still connecting — try again," return (no swarm fallback).
2. Register the stream callback, then `oxDial(<derived-or-svc onion>, kOnionVirtualPort)` (**async**) → stream or
   offline message.
3. Role `"download"`; on `chOnionStreamReady`, `oxWrite` a `BTXC` FILE request with `pRelId`. Initialize the §3.3
   receiver (temp via `chTempEncPath()` when `pEnc`, else neutral temp beside `chDefaultSave()`), stash `pEnc`,
   `chFileKey(sFollowPass[pKey], pKey)`, `chSafeLeaf(pOrigName)`; arm the receive watchdog.
4. On FINISH + `sRxGot == sRxTotal`: if `pEnc`, `chDecryptFile(temp, chDefaultSave() & "/" &
   chSafeLeaf(pOrigName), key)` then delete the temp; else move the temp into `chDefaultSave()` as
   `chSafeLeaf(pOrigName)`. `chLog` success.
5. Progress rides `sOnionXfer` (§6.8).

**Branch in `chDownloadSelected` (1192):** fork on the locator in `sFeedMag[tL]`:
- begins with `magnet:` → today's `btAddMagnet` path (unchanged).
- begins with `onion:` → `chOnionDownload sFeedKey[tL], (char 7 to -1 of tMag), sFeedTitle[tL], sFeedEnc[tL],
  sFeedOrigName[tL]` and **never `btAddMagnet`**.
- neither / empty → today's "feed has not arrived yet" message.

**`chCopySelectedMagnet` (1231):** if the locator begins with `onion:`, log "This is an anonymous release; it has
no magnet link (it streams over Tor). Copy the channel card to share the channel." instead of copying.

> **Resolved review findings (§6.5).** C1 → `chSafeLeaf` on `pOrigName` at every path build. #8 → folder refuse.
> #19 → serve map prune-on-load (or persisted `uOnionServe`). #12 → size warn wired at `chOnionPublishFile` too.

### 6.6 Composition with the existing passphrase encryption

Anon and passphrase are **independent layers that stack**, and the steer is to compose both:

- **Tor route** (anon) hides *who* and *where*: both IPs behind onion circuits; no magnet, no DHT feed, so the
  follow graph and swarm membership never appear publicly.
- **cryptoXT contents** (pass) hides *what*, from the peer and at rest: the feed value is `BTXENC2:`+secretbox and
  each file is `sxEncryptFile` ciphertext under a neutral name, authenticated per-chunk with a final tag — **and it
  authenticates the sender**, which the plaintext-anon path does not.

`anon+pass` reuses **every** existing crypto handler untouched (`chFeedValue`/`chReadFeed`,
`chFileKey`/`chEncryptFile`/`chDecryptFile`, `chMasterKey`) and merely changes the transport. Recommend `anon+pass`
in `chHelp` and in the `chSetAnon` prompt; note anon-alone still gives confidentiality *between the two onion
endpoints* but not sender authentication, and pass-alone protects contents but leaks IP/graph.

### 6.7 The deanonymization guard — exact branch points

The one invariant: **an anon channel calls none of `btCreateTorrent` / `btAddTorrentFile` / `btAddMagnet` /
`btDhtPutMutable` / `btDhtGetMutable`, ever.** Enforced at:

1. **`chPublishFile` (945), first line:** anon ⇒ divert to `chOnionPublishFile`, `exit`.
2. **`chPublishActiveFeed` (1870), top:** anon ⇒ `chOnionPushFeed`, `return 0`; the `btDhtPutMutable` at 1880 is
   skipped.
3. **`chChannelTick` (916) publish loop:** `if chIsAnonChannel(tI) then next repeat` before the `btDhtPutMutable` at
   929.
4. **`chChannelTick` follower loop / `chLoadFollows` (700) / `chRefreshAll` (1152):** `sFollowAnon[tKey]` ⇒
   `chOnionFollowFetch`, not `btDhtGetMutable`.
5. **`chHandleEvent` `dhtMutableItem` (1705):** ignore DHT values for anon follows.
6. **`chSetAnon` turning ON:** **hard-block** on any pre-existing clearnet magnet release / live `sMineHashes` seed —
   force removal (with `btRemoveTorrent`) before `["anon"]` flips (§6.2 step 4). Never warn-and-proceed.
7. **`chAddMagnetManual` (1496):** unaffected and intentionally left alone — a *manual, user-chosen* download into
   the user's own folder, never a channel publish (worth a one-line comment so a future reader does not "fix" it).

A silent mix — an anon feed entry carrying a `magnet:` locator — is structurally impossible: `chOnionPublishFile`
only writes `onion:<relId>`, and `chPublishFile`'s clearnet body is unreachable when anon. VERIFY (§6.1) further
guards that the "anonymous" label is honest at the crypto level.

### 6.8 Badges, follower status, and the offline-channel UX

**Publisher badges:**
- **`chUpdateChannelMenu` (550):** after the `(private)` append, add `if sChannels[tI]["anon"] is "true" then put
  tName && "(anon)" into tName`. Yields `Name (private) (anon)`.
- **`chUpdateNowPub` (1057):** after the `[PRIVATE: file list hidden]` clause, add
  `if chIsAnonChannel(sActive) then put tMsg && "[ANON: served over Tor" & (offline? " - service offline" : "") &
  "]" into tMsg`.
- **The Tor pill** `chOnionPill` (§3.2) shows global Tor state; repainted from `chOnionStatus` and the 1-s
  `chDashOnce` (906).

**Onion transfers in the table.** Add `sOnionXfer` (id → `{name, dir("up"/"down"), got, total, state}`) written by
`chOnionPump` and the §3.3 receiver, and **append rows in `chRefreshTransfers` (1331)** after the `btTorrentHandleAt`
loop, before the empty-state check: Source column `"Onion"` (color it distinctly, e.g. teal `0,150,150`); progress
via the existing `chProgressBar`; State `onion up`/`onion down`/`onion done`. `chSource` (1627) is not consulted for
these inline rows. Entries are pruned in `chStop` (bounded-growth minor limit noted).

**Follower status in `chRefreshSubs` (1248):** when a followed key has `sFollowAnon` true, tag its row `(anon)`. The
feed-arrival states flow through `sFollowFeeds[tKey]` as `name=…` lines, so the offline/connecting placeholders
render with zero new list code.

**Old-card / stripped-tag hazard (M2, #17a).** Anon-ness is carried in the card text (`chCopyKey` appends
`| anon`), parsed into `sFollowAnon`. An old 2-field card ("Name|key") or a stripped/tampered card makes the
follower do `btDhtGetMutable` for an onion-only channel — publishing the follow interest + real IP to the DHT and
never getting data. Mitigations, all applied:
- `chFollow` (1097) parses a 3rd `|` field (`anon`) and persists `sFollowAnon`.
- When a followed channel returns **no** DHT descriptor over a tick or two, `chChannelFetch` **also tries the
  onion** (derive the address from the pubkey and attempt a FEED dial) before giving up — so an anon channel is
  reachable even from an old card, and the follower is not stranded.
- The UI **warns** when a pasted card lacks the `| anon` tag but the channel later proves onion-only, prompting the
  user to re-copy the current card; the docs state plainly that a stripped tag causes a one-time clearnet interest
  leak.

**Reaching an anon channel that is offline.** No DHT cache backstops an anon publisher, so `chOnionFollowFetch`
handles three cases gracefully, each writing a `name=…` placeholder retried on the 60-s tick:

| Situation | `sFollowFeeds[key]` placeholder | `chLog` |
|---|---|---|
| Tor not ready locally | `name=<short> (anonymous - Tor still connecting)` | "Connect Tor to reach anonymous channels." |
| `oxDial` SOCKS error / times out | `name=<short> (anonymous - offline)` | "Channel <short> is anonymous and its publisher is not reachable over Tor right now. Its releases appear when it comes online." |
| Dialed, `BTXF` received | real `name=…` feed (or `LOCKED`/`BADPASS` via `chReadFeed`) | "Anonymous feed: signature verified, N release(s)." |

No silent fallback to the swarm ever happens.

> **Resolved review findings (§6.8).** M2/#17a → 3-field card parse + onion retry from the pubkey + stripped-tag
> warning, so old-card followers are not silently stranded and do not leak indefinitely.

### 6.9 Exact edit points

**Existing handlers modified:**
- `chStart` (453) — probe `sHasOnion`/`sOnionIdentityOk`; `chOnionStart` when `sHasOnion`.
- `chStop` (707) — `chOnionStop` before `btStopSession`.
- `chActivate` (534) — bring up the channel's service when anon+ready.
- `chEnsureIdentity` (490), `chNewChannel` (582) — init `["anon"]=""`.
- `chDeleteChannel` (653) — **copy `["anon"]`** into the rebuilt array (required).
- `chLoadFollows` (685) — load `uFollowAnon`→`sFollowAnon` (default empty on old stacks); anon follows fetch over
  onion.
- `chFollow` (1097) — parse a 3rd `|` field (`anon`); set+persist `sFollowAnon`; branch to `chOnionFollowFetch`.
- `chUnfollow` (1160) — clear `sFollowAnon[key]`, persist, close `sFollowStream[key]`.
- `chRefreshAll` (1147) — anon follows via `chOnionFollowFetch`.
- `chChannelTick` (916) — skip DHT put for anon (push instead); anon follows via onion; `chOnionBringUpServices`.
- `chCopyKey` (1079) — append `| anon` for an anon channel.
- `chPublishFile` (945) — anon ⇒ divert, exit.
- `chPublishActiveFeed` (1870) — anon ⇒ `chOnionPushFeed`, return 0.
- `chAddReleaseAndPublish` (1946) — accept `"ANON"`; success line "pushed to onion followers".
- `chDownloadSelected` (1192) — fork on `onion:` locator.
- `chCopySelectedMagnet` (1231) — friendly no-magnet message.
- `chHandleEvent` `dhtMutableItem` (1705) — ignore DHT values for anon follows.
- `chRefreshSubs` (1248) — `(anon)` suffix.
- `chRefreshTransfers` (1331) — append `sOnionXfer` rows with `Onion` source/color.
- `chUpdateChannelMenu` (550), `chUpdateNowPub` (1057) — badges.
- `chBuildFeed` / `chRefreshSubs` — add/parse the `svc=<onion>` line (§6.1 contingency).
- `chBuild` (214) — add button `chAnon` ("Anonymous...") beside `chPrivacy`, a `chTor` status-pill field; bump
  `kUiVersion`.
- `chAddTips` (394) — tooltips for `chAnon`/`chTor`.
- `mouseUp` switch (118) — `case "chAnon": chSetAnon`.
- `chHelp` (426) — anonymous channels + linkability caveat + size ceiling + plaintext-not-authenticated note.

**New `ch*` handlers:** `chHasOnion`, `chOnionReadyNow`, `chOnionStart/Stop/Status/Pill`,
`chOnionAccept/Peer/ServiceReady/StreamReady`, `chOnionSend/Pump/StreamData/StreamClosed`,
`chOnionSendWatchdog/RecvWatchdog`, `chSafeLeaf`, `chVerifyOnionIdentity`, `chChannelOnionAddr`, `chIsAnonChannel`,
`chSetAnon`, `chOnionServiceFor`, `chOnionBringUpServices`, `chOnionWithdrawService`, `chOnionServeRequest`,
`chOnionPushFeed`, `chOnionFollowFetch`, `chOnionPublishFile`, `chOnionDownload`, `chAllocRelId`.

**New state locals:** `sHasOnion`, `sTorReady`, `sOnionIdentityOk`, `sFollowAnon`, `sChanService`,
`sChanServiceAddr`, `sChanServicePort`, `sFeedStreams`, `sFollowStream`, `sOnionServe`, `sOnionServeEnc`,
`sOnionServeName`, `sOnionServeTotal`, `sOnionXfer` (plus the §3.3 `sTx*`/`sRx*` arrays). **New stack props:**
`uFollowAnon`, and (if the persisted serve map is chosen) `uOnionServe`.

---

## 7. Security model & honesty (Model C)

Model C moves the file's bytes over a Tor onion circuit instead of the swarm. This section states exactly what that
buys, what it does not, and the guards that stop an "anon" label from over-promising. When in doubt the anon path
**fails closed** and never silently downgrades to clearnet.

Load-bearing fact: both demos run **one** `btStartSession` with `enable_dht`/`enable_lsd` set (`qsStart` 293–294,
`chStart` 461–462) and announce to a hardcoded public tracker (`qsTracker` 637, `chTrackers` 2011). Every clearnet
leak here traces to a payload reaching *that* session. The core rule: **anon content never enters the BitTorrent
session** — no `btAddTorrentFile`, no `btAddMagnet`, no `btDhtPutMutable`/`btDhtGetMutable`, no tracker announce for
anything carried over the onion.

### 7.1 Guarantees table

"Peer" = the other person's app. "Third party" = swarm/DHT participant, tracker operator, or on-path observer who
is not the peer. "GPA" = global passive adversary watching both endpoints' Tor guards at once.

| Property | QuickShare-anon | Channels-anon | Notes |
|---|---|---|---|
| Sender/publisher IP, from the peer | **Hidden** | **Hidden** | onion-to-onion; the peer sees only a `.onion` |
| Sender/publisher IP, from third parties | **Hidden** | **Hidden** | traffic never leaves the Tor network (no exit; 7.2) |
| Receiver/follower IP, from the peer | **Hidden** | **Hidden** | receiver dials out through Tor via `oxDial` |
| Receiver/follower IP, from third parties | **Hidden** | **Hidden** | |
| File bytes, in transit | **Hidden** | **Hidden** | onion circuit is layer-encrypted end to end |
| File bytes, from the receiving peer | Exposed unless cryptoXT on | Exposed unless cryptoXT on | the endpoint receives the bytes; the passphrase withholds plaintext from a merely-relaying peer |
| File bytes, at rest | Exposed unless cryptoXT on | Exposed unless cryptoXT on | with cryptoXT the received `.enc` decrypts only under the passphrase |
| Real filename / release title | **Hidden** from third parties | **Hidden** from third parties | rides inside the encrypted stream/feed |
| Feed / file-list contents | n/a | **Hidden** from third parties | served over the onion and/or `sxSecretBox`-sealed; never `btDhtPutMutable` |
| Subscription graph | n/a | **Hidden** from third parties | follows resolve via `oxDial`, not clearnet `btDhtGetMutable` from your IP |
| **Sender authenticity (plaintext anon)** | **NOT provided** | **NOT provided** | plaintext hides the route but does not authenticate the sender; a swapped code/card redirects to an impostor (M3) |
| **Sender authenticity (anon + passphrase)** | **Provided** | **Provided (+ BEP44 signature on the feed)** | secretstream authenticates contents under the shared key |
| The fact that you use Tor | **Not hidden** | **Not hidden** | your ISP/guard sees a Tor connection |
| Traffic timing / volume / burst shape | **Not hidden** | **Not hidden** | a GPA can correlate start, duration, total bytes, cadence (7.6) |
| App's overall DHT presence | **Not hidden** | **Not hidden** | the host is still a DHT node; the IP claim is scoped to the anon file bytes only |
| Channel online-presence | n/a | **Leaks a coarse oracle** | a deterministic-from-seed `.onion` descriptor reveals "reachable now" to anyone holding the address (7.6) |

Read as: **Model C hides WHERE (both IPs) and, composed with cryptoXT, WHAT and authenticates WHO. It does not hide
WHEN, HOW MUCH, or THAT-you-use-Tor, and plaintext-anon does not authenticate the sender.**

### 7.2 Onion-to-onion avoids exit nodes entirely (why we rejected Model A)

- **Model A (rejected): torrent-over-Tor via a SOCKS exit.** Reasons: (1) **UDP cannot go through it** — OnionXT is
  TCP-STREAM + ONION-SERVICE only; DHT/uTP are UDP, so they fail or leak around the proxy from your real IP; there
  is no honest "anonymous DHT." (2) **Exit-node exposure** — a hostile exit can log/tamper/inject; trackers embed
  your announced IP. (3) **Correlation** — mixing anonymized announces with any non-proxied UDP announce for the
  same info-hash de-anonymizes instantly.
- **Model C (chosen): onion-to-onion.** Both endpoints are onion services; traffic **never touches an exit and
  never leaves Tor.** No exit to trust, no clearnet destination, no UDP to leak. The only configuration that makes
  the 7.1 route/IP guarantees honest.

### 7.3 The de-anonymization trap and the guards

**The trap:** the same payload available *both* over the onion ("anon") *and* on the clearnet swarm lets a third
party correlate the onion content with the swarm's info-hash and read the real IP off the DHT/tracker. An "anon"
badge coexisting with clearnet seeding is actively harmful.

**The one invariant (enforced, not advised):** anon content is never added to the DHT/LSD session. Add two guard
predicates and call them at every clearnet entry point:

- `qsIsAnon()` / `chChannelIsAnon(pIndex)` — the anon state (`sTorSend` in QuickShare; `sChannels[i]["anon"]` in
  Channels).
- `qsAssertNotClearnet` / `chAssertNotClearnet` — refuse and log when an operation would push anon content onto the
  session.

**QuickShare guards:** (1) `qsShareFile` skips the entire `btCreateTorrent`/`btAddTorrentFile` block when anon; the
share code is `.onion`-bearing (`BTXTOR1:`), never an info-hash. (2) `qsGetFile` routes a `BTXTOR1:` code through
`oxDial`, never `btAddMagnet`; a bare hash / `magnet:` is a clearnet code and is never accepted while the receive UI
shows an anon badge. (3) Dual-availability: `qsAssertNotClearnet` treats anon and clearnet for one payload as
**mutually exclusive** — one active anon share replaces the previous; re-dropping the same file with anon off
requires an explicit "yes, also seed this publicly" that visibly drops the anon badge. (4) `enable_lsd` only ever
announces torrents; since anon files are never added, LSD cannot leak them.

**Channels guards:** (1) An anon channel must **not** `btDhtPutMutable` its feed — it serves the (cryptoXT-sealed)
feed from `oxCreateServiceFromSeed(seed)` and followers fetch over Tor; skip it in the `chChannelTick` DHT-put loop
exactly as a fail-closed private channel is skipped (926–930). (2) An anon channel takes the onion-publish branch,
writing an `onion:<relId>` locator, never a magnet; **`chAssertNotClearnet` HARD-BLOCKS setting `["anon"]` true on a
channel that already has any live clearnet release in `sMineHashes` — the user must Remove them first (§6.2/§6.7).**
(3) `chDownloadSelected` dials the `.onion` for an onion-carried release, never `btAddMagnet`. (4) `chPin`/quick-drop
stay explicitly labeled clearnet and are never rendered under an anon badge. (5) `["anon"]` is a whole-channel
property; a channel is all-clearnet or all-onion, and flipping it is refused while releases of the other kind exist.

> **Resolved review findings (§7.3).** H4 → the Channels anon-ON path is a **hard block**, consistent with §6.2/§6.7.
> M3 → plaintext-anon endpoint authenticity is called out as NOT provided, in the table and in-UI (§5.4).

### 7.4 Composing with cryptoXT: Tor hides the route, libsodium hides the contents

Recommend **both**, reusing the existing crypto path unchanged. Encrypt to a temp `.enc`, stream the `.enc` over the
onion; the receiver writes frames to a temp `.enc` and `sxDecryptFile`s it.

- **Tor alone (passphrase blank):** both IPs hidden; bytes encrypted in transit. **Exposed:** the receiving peer
  gets plaintext, plaintext lands on both disks, **and the sender is not authenticated.** Fine for a file you
  *intend* the peer to read from a source you trust out-of-band; wrong if the peer/disk/channel is untrusted.
- **cryptoXT alone (today's clearnet encrypted mode):** contents secret from the swarm and at rest. **Exposed:** the
  info-hash is on the DHT + tracker and both IPs are visible — *who*, *who*, *when*, *how big* are public.
- **Both (recommended):** IPs hidden *and* contents secret *and* sender authenticated. **Residual:** timing/volume
  correlation by a GPA, Tor-usage visibility, the presence oracle (7.6), trust in the local Tor daemon (7.5).

In-UI when the user enables anon without a passphrase: "Your IP is hidden, but the person you send to can read the
file and the sender is not verified. Add a passphrase to keep it secret, tamper-evident, and safe on disk."

### 7.5 Trust boundary: the local Tor daemon

OnionXT speaks SOCKS5 on `127.0.0.1:9050`/`9150` and control on `:9051`/`:9151`. The local Tor process is
**trusted**: it sees **every `.onion` you dial**, **holds and serves your onion-service private key**, and a
compromised local Tor can impersonate your service or de-anonymize you. It does **not** see plaintext when cryptoXT
is layered (7.4). **Loopback only, always** — `oxSetControlPort`/`oxSetSocksPort` must point at `127.0.0.1`;
pointing the control port at a remote host would hand full de-anonymization to that host. Control-port auth
(cookie/password) is Tor's; the demo surfaces a clear "cannot reach / authenticate to local Tor" failure rather
than proceeding. If Tor is not running or `oxIsReady()` never reaches true, the toggle **fails closed** and every
clearnet feature keeps working.

### 7.6 Metadata and timing a global observer can still exploit

- **Volume + timing correlation.** Bounded script-streaming (fixed 64 KiB slices, ~one frame per tick) produces a
  distinctive flow: a recognizable total byte count (~ plaintext size + a small constant), a start time, a
  duration, and a steady cadence. A GPA can match a send to a receive on shape. Tor onion services are **not**
  designed to resist a GPA; say so. Optional future hardening (pad-to-bucket on the final frame, light per-tick
  jitter) raises cost but does not defeat a GPA; do not claim it does.
- **Onion-service descriptor timing.** Coming online publishes a descriptor to the responsible HSDirs;
  `oxIsReady()` flips true only *after* upload. Anyone who knows a channel's `.onion` can watch the HSDir hash-ring
  and learn *when it becomes reachable* — a coarse presence oracle, sharper for **Channels-anon** (deterministic
  address recurs in the same daily-blinded slot). **QuickShare-anon uses ephemeral `oxCreateServiceFromSeed` with a
  random seed** (a fresh, unlinkable `.onion` per share) precisely to avoid a persistent oracle. Document the
  trade: Channels needs a stable address so followers can find it; that stability *is* the observability cost.
- **Size ceiling (the honest limit).** Single-thread pumping means modest throughput; large media is slow. Steering
  a user to "just use the clearnet swarm" **re-introduces the IP leak** — so any such steer carries the explicit
  privacy caveat and is **never auto-applied** to a payload the user marked anon (guard 3 / the 7.3 invariant).
  Real throughput is **VERIFY** (§11.2/§12.3) — do not quote a number to users until measured on two machines.

### 7.7 Positioning and the honesty convention

- **Reputational framing.** Public clearnet BitTorrent/DHT stays the **default**; anon is explicit, off-by-default.
  Frame QuickShare-anon as "hand a sensitive document directly to one colleague without exposing either IP, the
  contents, or an info-hash," and Channels-anon as "a small, trusted, signed feed whose publisher's IP is not on the
  DHT." Do **not** market it as "untraceable"; put the GPA, Tor-usage, presence-oracle, plaintext-not-authenticated,
  and local-Tor caveats in plain language next to the toggle.
- **Never let the badge outrun the transport.** "Anonymous" in any label must be backed by the 7.3 invariant for
  that specific payload; if a guard cannot confirm it, the label does not appear.
- **Static-gate first, then a human on-engine pass.** Run `tools/check-livecodescript.py` and reason about the frame
  layout on paper. The live behavior — bootstrap, `oxDial` round-trips, descriptor timing, each 7.3 guard actually
  refusing the clearnet path, the fail-closed paths — **must be confirmed by a human on a real engine with a running
  local Tor daemon.** Label every anonymity claim "verified statically; needs an OXT + live-Tor pass."

---

## 8. Event-loop & threading integration

### 8.1 One thread, one message queue

Everything runs on OXT's single interpreter thread. The demos already drive it through the engine's timed-message
queue plus event drains. OnionXT's callbacks are **not** a second thread — its loopback sockets use async
`read … with message`, and it delivers every callback (`<pfx>OnionStreamData`, `<pfx>OnionPeer`,
`<pfx>OnionServiceReady`, the `oxSetStatusCallback` updates) as an ordinary engine message on the *same* queue. So
the onion path composes with `btPoll` the way MIDI + timer already compose: cooperative, interleaved, never
concurrent. No lock, no re-entrancy, no foreign-thread rule to break — OnionXT respects rule 1 for free because
loopback reads dispatch on the engine thread (VERIFY the inbound model, §12.3 #25).

Registered callback names keep each demo's prefix and the **unified §3 spelling** (`<pfx>OnionStatus`,
`<pfx>OnionPeer`, `<pfx>OnionStreamData`/`<pfx>OnionStreamReady`/`<pfx>OnionStreamClosed`) — the earlier `qsOn*`
spellings are retired:

| OnionXT setter | QuickShare handler | Channels handler |
|---|---|---|
| `oxSetStatusCallback` (single global) | `qsOnionStatus` | `chOnionStatus` |
| `oxSetPeerCallback` | `qsOnionPeer` | `chOnionPeer` |
| `oxSetStreamCallback` (per stream) | `qsOnionStreamData` / `qsOnionStreamReady` / `qsOnionStreamClosed` | `chOnionStreamData` / `chOnionStreamReady` / `chOnionStreamClosed` |

There is exactly **one** global status callback; the demos run as separate stacks, so each owns it. If ever
co-hosted, one dispatcher fans out to both pills (§3.4).

### 8.2 The one rule: never block

Every onion primitive is used in its async, bounded, timed form:

1. **`oxDial` is asynchronous everywhere.** We never spin on it — we register the stream callback first, dial, then
   wait for `<pfx>OnionStreamReady` before the first `oxWrite`, and arm a dial/handshake timeout (`send
   "<pfx>OnionRecvWatchdog pStream" to me in kRecvTimeout`) because Tor builds circuits slowly. This resolves the
   earlier sync-vs-async contradiction: the receiver/sender state machines assume **async** and gate the first
   write on ready. (VERIFY the exact `oxDial` return/dispatch semantics, §12.3 #6/#22.)
2. **`oxWrite` is fire-and-return, writability-gated.** On backpressure we hold the next frame and resume on the
   writable callback (or the capped ≥15 ms tick fallback) — never a `repeat` that drains a whole file, never an
   unbounded native write buffer.
3. **File bytes are read in bounded 64 KiB slices** (`kOnionChunk`) so no single op touches more than 64 KiB and the
   whole file never enters a `Data`.
4. **The synchronous cost — `sxEncryptFile`/`sxDecryptFile` — runs exactly once, outside the pump** (before the
   first frame, or after FINISH), reusing the existing crypto seams. The already-documented "may pause briefly on a
   large file" behavior; never inside a per-frame tick.

### 8.3 Where onion ticks are scheduled

The streaming pump is a **self-arming, self-disarming** timed message — an idle app costs nothing:

| message | interval | armed when | purpose |
|---|---|---|---|
| `qsPollOnce` / `chPollOnce` | 250 ms | always (existing) | drain `btPoll` → `…HandleEvent` (clearnet events only) |
| `qsDashOnce` / `chDashOnce` | 1000 ms | always (existing) | repaint transfers table |
| `chChannelTick` | 60 s | always (Channels, existing) | re-announce feeds + re-pull subs |
| **`qsOnionPump` / `chOnionPump`** | **~15 ms (`kPumpTick`), writability-gated** | **only while ≥1 onion send is in flight** | push **one** DATA frame across the active send streams round-robin, then re-arm; unarm at FINISH |
| **`<pfx>OnionSendWatchdog` / `<pfx>OnionRecvWatchdog`** | one-shot, self-re-arming | armed at dial/accept | fire the abort path on an idle stall independent of inbound data (H2) |

Inbound is purely event-driven: `<pfx>OnionStreamData` fires the instant Tor delivers bytes, so **receive latency is
independent of the 250 ms poll**. The pump owns per-stream framing state (`sRxBuf`, `sTxOffset`, etc.) so a frame
split across two reads reassembles correctly.

### 8.4 Ordering vs. the 1 s repaint

The dashboard repaint and the send pump are both cooperative `send` messages that each return well under a frame
budget. When both come due, the engine dispatches in scheduled-time order; neither blocks the other. The pump
re-arms at ~15 ms (never `in 0`) so it never starves the 250 ms poll or the 1 s repaint, and the repaint stays ≤ 1 Hz
and only-on-change. Onion transfers surface in the **same** transfers table via `sOnionXfers` (QuickShare) /
`sOnionXfer` (Channels), tagged `via Tor` / `Onion` in the source column so an anonymous transfer is never visually
confused with a swarm transfer — making the §7.3 no-silent-mixing guard visible to the user.

---

## 9. API surface — what exists vs. gaps

### 9.1 Zero changes to any compiled extension — but the OnionXT ABI is unverified

**Model C is entirely demo-script work.** Every native capability it needs is presumed to already ship in the three
extensions at their current ABIs. **Critical caveat: OnionXT is not in this repository (zero `ox*` references), so
the entire `ox*` surface below is a design contract, not a verified fact. Confirming the real OnionXT ABI — handler
names, signatures, sync/async semantics, the inbound-peer model, the writable signal, concurrent-service support,
and the control-port auth model — is the gating precondition for Phase 1** (see the VERIFY register, §12.3).

- **TorrentXT (`bt*`) — untouched.** The clearnet path is unchanged and remains the default. The onion path does
  **not** call libtorrent for the anonymous bytes, so no `btx_*` symbol is added/modified and `BTX_ABI_VERSION`
  does not move.
- **OnionXT (`ox*`) — used as-is (pending VERIFY).** Presumed surface: `oxVersion`, `oxSetSocksPort`/
  `oxSetControlPort`, `oxConnectControl`/`oxDisconnectControl`, `oxSetStatusCallback`/`oxSetPeerCallback`/
  `oxSetStreamCallback`, `oxBootstrapProgress`/`oxIsReady`, `oxDial`/`oxWrite`/`oxCloseStream`,
  `oxCreateService`/`oxCreateServiceFromSeed`/`oxRemoveService`/`oxServiceAddress`, and the address helpers
  `oxAddressFromPublicKey`/`oxPublicKeyFromAddress`/`oxIsValidAddress`.
- **cryptoXT (`sx*`) — reuse the existing path.** `sxEncryptFile`/`sxDecryptFile`, `sxPwHash`/`sxSecretBox`/
  `sxSecretBoxOpen`, `sxSignKeypairFromSeed` (the H5 offline VERIFY), `sxRandomBytes`, `sxHex2Bin`. Nothing new.
- **Bounded file streaming** uses built-in `open/read/seek/close file` — no extension.

The only new artifacts are `.livecodescript` handlers and state inside the two demo files.

### 9.2 New demo-script surface (the complete list)

Uses the unified §3–§6 namespace (the earlier `qsOn*`/`sAnon`/`sOxReady`/`sStaged`/`sAnonRows` spellings are
retired).

**QuickShare (`qs*`):** state `sTorSend`, `sHasOnion`, `sTorReady`, `sActiveShare`, `sOnionXfers`,
`sOnionListening`, and the §3.3 per-stream `sTx*`/`sRx*` arrays plus `sRxKey`/`sRxName`/`sRxSave`. Handlers
`qsHasOnion`, `qsOnionReadyNow`, `qsOnionStart`, `qsOnionStop`, `qsOnionStatus`, `qsOnionPill`, `qsOnionAccept`,
`qsOnionPeer`, `qsOnionServiceReady`, `qsOnionStreamReady`, `qsOnionStreamData`, `qsOnionStreamClosed`,
`qsOnionSend`, `qsOnionPump`, `qsOnionSendWatchdog`, `qsOnionRecvWatchdog`, `qsToggleTor`, `qsSafeLeaf`,
`qsStartOnionShare`, `qsMakeTorCode`. Constants per §3.2 plus `kTorCodePrefix="BTXTOR1:"`, `kAnonSizeWarn`.
Toggle wired into `qsBuild` (`qsTorToggle`), branch added to `qsShareFile`/`qsGetFile`.

**Channels (`ch*`):** state and handlers as enumerated in §6.9, on the same framing/serve maps. New feed line
`svc=<onion>` in `chBuildFeed`/`chRefreshSubs`; the `BTXC`/`BTXF` request/response constants of §6.4.

### 9.3 Dependency notes

- **OnionXT depends on cryptoXT (SodiumXT).** OnionXT computes the onion identity and address with SodiumXT
  primitives, so the **anonymous path requires cryptoXT even for a no-passphrase transfer**, independent of the
  demos' own optional encryption. `sCanEncrypt` is therefore a *necessary* precondition for anon mode. Both demos
  already fail closed when cryptoXT is absent; anon mode reuses that gate and adds `oxVersion()` on top. **VERIFY**
  (§12.3 #26): confirm the dependency, the minimum SodiumXT ABI, and that anon-without-passphrase truly still needs
  SodiumXT.
- Record the SodiumXT floor in the demo header comments alongside the existing "requires
  org.openxtalk.library.sodium" note, once the exact ABI is confirmed.

### 9.4 Optional future ABI ideas — explicit NON-goals

Recorded so nobody mistakes them for Model-C work; **none are needed and none will be built here:**
- **`btx_connect_peer(session, "onion:<addr>")`** for libtorrent-carried onion torrents — needs SOCKS5 plumbing
  *and* UDP-over-Tor (which OnionXT cannot do). Out of scope; Model C routes bytes **outside** libtorrent.
- **A native onion-aware webseed / multi-peer fan-out.** Model C is one-dialer-to-one-server (Channels fans out via
  re-open-per-read in script).
- **An OnionXT `oxWriteFile`/`oxSendFile` C-side splice** to stream a big file without any script pump. Attractive,
  but a pure-script bounded pump (§8.2) suffices and keeps the ceiling honest. A future OnionXT ABI idea, not a
  Model-C dependency.

---

## 10. Phased roadmap & gates

Each gate is an **observable two-machine (except Phase 0) on-engine outcome**. `tools/check-livecodescript.py` and
the pure-compute KATs (§12) are the *static* gate; the listed outcome is the *human OXT pass* and is the only thing
that closes the phase.

**Phase 0 — Probe, plumbing & ABI confirmation (single machine OK).**
First **confirm the real OnionXT ABI** against §9.1 (this unblocks everything). Then add the `sTorSend` toggle to
both UIs; `qsHasOnion`/`chHasOnion` (`oxVersion` + `sCanEncrypt`); dual-port config via
`oxSetSocksPort`/`oxSetControlPort`; `oxConnectControl` (9051 then 9151); status wiring
(`oxSetStatusCallback` → `qsOnionStatus`/`chOnionStatus`) rendering `oxBootstrapProgress()` into the pill; run the
offline `chVerifyOnionIdentity` (the H5 `btDhtKeypair` vs `sxSignKeypairFromSeed` byte-compare).
*Done gate:* On one machine with Tor running, toggling anon **ON** drives the pill to "Tor: ready" and surfaces an
`.onion`; toggling **OFF** leaves every clearnet feature bit-for-bit unchanged; with **Tor absent**, the toggle
shows the §13 fail-closed message and the clearnet demo is entirely unaffected; the offline identity byte-compare
passes. `check-livecodescript.py` clean.

**Phase 1 — QuickShare onion send/receive.**
`qsStartOnionShare` stages a file (or its `.enc`), creates `oxCreateServiceFromSeed(random)`, mints a `BTXTOR1:`
code; `qsGetFile` parses it, `oxDial`s async, streams via the §3.3 framing; reuse `qsEncryptFile`/`qsDecryptFile`
for the passphrase case.
*Done gate:* Two Tor-ready machines. A anon-shares a file → gets a `BTXTOR1:` code; B pastes it → the file lands
**byte-identical (sha256 match)**. On both hosts, `ss -tunp` shows the only network peer for that transfer is
`127.0.0.1:9050/9051` (or 9150/9151) — **no DHT/uTP packets**. Repeat with a passphrase: the `.enc` streams, the
up-front verifier rejects a wrong passphrase, the file decrypts to the real name, and a plaintext-header downgrade
of an encrypted-advertised share is refused. Path-traversal names are neutralized to the save folder.

**Phase 2 — Channels feed rendezvous over onion.**
Publisher runs `oxCreateServiceFromSeed(channelSeed, …)`; add `svc=<onion>` to `chBuildFeed`; follower reaches the
channel's onion to pull the signed feed. **Gate on the §6.1 equivalence VERIFY** (the seed↔pubkey byte-compare, both
the offline crypto compare and the live `oxServiceAddress == chChannelOnionAddr`); if it fails, the `svc=` line is
the source of truth and the "derivable from pubkey" claim is dropped from the docs.
*Done gate:* Two machines. A publishes with anon enabled; B follows by pasting the channel **card only**, reaches
the onion **with DHT disabled for that channel**, lists releases, and the BEP44 signature still verifies. An old
2-field card still reaches the channel via the onion-retry fallback (§6.8).

**Phase 3 — Channels anonymous file delivery.**
Follower `chOnionDownload` dials the channel onion and sends a `BTXC` FILE request; publisher `chOnionServeRequest`
maps it and streams the file over §3.3.
*Done gate:* Two machines. B downloads a selected release **entirely over the onion** (swarm/DHT off), byte-identical;
an encrypted release decrypts automatically; the Transfers table marks the row `Onion`; packet capture shows **zero**
swarm/DHT traffic for that file on both ends; a publisher restart either serves the persisted map or cleanly prunes
the stranded relIds.

**Phase 4 — Docs / threat-model / onboarding.**
Write `docs/anon-transport.md` (Model C), the threat model, and the §13 onboarding.
*Done gate:* A fresh user on each of macOS/Windows/Linux, following **only** the onboarding doc, gets Tor ready and
completes a two-machine anon transfer; the threat-model page states exactly what is and is not hidden (including the
plaintext-not-authenticated and clearnet-mixing caveats); `check-livecodescript.py` clean on the final scripts.

---

## 11. Risks & the decisions you own

**11.1 The Tor-daemon dependency (biggest UX hurdle).** OnionXT needs a local Tor on `9050`/`9051` (or Tor
Browser's `9150`/`9151`), and a stock install often ships the **control port disabled**. Two paths:
**(a) document-install** — smallest binary, biggest friction; **(b) bundle a `tor` binary** and launch it with a
generated `torrc` — best UX, heaviest package, and a maintenance/security burden (you ship and update Tor, and must
sign/notarize it). *Decision you own:* ship **(a) for the demos** with a written path to **(b)** for a real app.
Whichever, the toggle fails closed (§13), never silently.

**11.2 The Model-C size ceiling.** Bounded script streaming (one 64 KiB frame per ~15 ms tick, writability-gated) is
the honest limit; the real throughput over a Tor circuit is **unmeasured and likely modest — do not quote a number
to users until VERIFYed on two machines** (§12.3 #28). *Decision you own:* **hard block vs. warn.** Recommendation —
**warn, don't block**: above `kAnonSizeWarn` (suggest 256 MiB) show "This file is large for anonymous transfer; it
will be slow. For big media, share it on the public swarm (which reveals your IP) instead." — steer to clearnet with
an **explicit privacy caveat**, never a silent downgrade. Small files proceed with no friction. (Wired at both send
entry points, §5.3/§6.5.)

**11.3 VERIFY the seed ↔ onion-pubkey equivalence (must-do before Phase 2).** The plan leans on
`btDhtKeypair(seed).publicKey == sxSignKeypairFromSeed(seed).publicKey == the 32-byte pubkey embedded in
oxCreateServiceFromSeed(seed)`'s address. Both are "standard ed25519 seed→keypair," but libtorrent's and libsodium's
are different codebases. *You own confirming this empirically* (the offline crypto byte-compare in §6.1 plus the live
`oxServiceAddress` compare; KATs in §12.3). **If they diverge, the `svc=` feed line is the shipped source of truth
(already in the §6 schema) and the "derivable from pubkey" claim is dropped from the docs.**

**11.4 Standalone packaging.** A built standalone must bundle **OnionXT + SodiumXT + TorrentXT** inclusions.
*Decision you own:* enforce the **three org ids** as a packaging gate —
`org.openxtalk.library.onion` + `org.openxtalk.library.sodium` + `org.openxtalk.library.torrent` — and confirm
OnionXT and SodiumXT ship the **full per-arch native-lib matrix** (the `src/code/<arch>-<platform>/` bundling
TorrentXT already does). Missing SodiumXT silently disables the whole anon path (OnionXT can't load), so the probe
must report "OnionXT could not load (needs SodiumXT)" **distinct** from "no Tor." No Tor is bundled by default (per
11.1a), so state clearly that a packaged app is not anon-capable out of the box; if 11.1b is chosen, the bundled
`tor` must be signed/notarized for Gatekeeper/SmartScreen. Verify the packaged `.exe`/`.app` passes Phase-0 on a
clean machine.

**11.5 Positioning sign-off / no silent mixing.** "Anonymous" must mean what Model C delivers: **both peers' IPs
hidden for the file bytes**, plus contents+sender-authentication only when a passphrase is set — nothing more (it
does not hide *that* you use Tor, does not anonymize a clearnet feed, does not authenticate a plaintext sender). The
guard: when anon is ON and Tor fails, the transfer **must not** fall back to the swarm — it aborts (§13). An anon
feed combined with clearnet seeding leaks the seeder IP, so the demos never mix modes on one transfer and the
`via Tor`/`Onion` row tag (§8.4) makes the mode visible. *You own the copy* that states this plainly in-app and in
the threat model.

**11.6 Open product decisions.** (a) One onion service per session vs. per share — **decided: one per session**
(QuickShare replaces its single active share; Channels runs one per anon channel), each on an ephemeral loopback
port. (b) Whether Channels anon delivery *replaces* or *supplements* the swarm for a given channel — **decided:
whole-channel property, all-onion or all-clearnet, default off**. (c) Ephemeral vs. persistent QuickShare service
key — **decided: ephemeral** (a fresh code each share, no presence oracle). (d) Concurrency model for one publisher
serving N receivers — **decided: QuickShare one-active-receiver, Channels re-open-per-read fan-out** (§3.3 step 6).
These were previously open; they are resolved here.

---

## 12. Testing & verification

No headless OXT exists, so the discipline is **static gate first, KATs second, two-machine human pass is the proof.**

### 12.1 Static gate (every script edit)

`python3 tools/check-livecodescript.py` must pass on both demos: smart/curly-quote zero, handler/`unsafe`/control
balance, constants-before-use, and the reserved-token-shadow check. **This has not yet been run on any of the new
names** — the many new `s*/t*/p*/k*` identifiers (`sTxTotal`, `sRxState`, `sChanServicePort`, `pReq`, `pEnc`, etc.)
must be cleared mechanically for the `tExt`==`text` class before "done" is claimed (M11). Also confirm every onion
constant is declared literally in §3.2 **before first use** (the constant-before-use footgun; `kOnionVirtualPort`,
the loopback-port handling, `kSendTimeout`/`kRecvTimeout`, `kMax*`, `kPumpTick` are all defined there, resolving the
earlier use-before-definition gap).

### 12.2 Pure-compute known-answer vectors

A standalone `tests/onion_frame_golden.py` (in the spirit of `record_golden_test.py`) pins the **single** wire
protocol so the script writer and reader cannot drift. This is the §3.3/§6.4 framing — the earlier typed
`SELECT/META/DATA/FIN/ABORT` scheme is deleted and **not** tested. All framing integers **big-endian**:

| element | bytes |
|---|---|
| file header (once) | `"BTXO"` (4) · `version` u8 =`0x01` · `flags` u8 · `nameLen` u16 (`"n"`) · name (UTF-8) · `totalLen` u64 (hi/lo u32, `"NN"`) |
| data frame | `len` u32 (`"N"`, `1 ≤ len ≤ kOnionChunk`) · bytes |
| terminator | `len` u32 = `0` |
| channels request | `"BTXC"` (4) · ver u8 · verb u8 · keyLen u16 (`"n"`) · key · idLen u16 (`"n"`) · id |
| channels feed frame | `"BTXF"` (4) · ver u8 · valLen u32 (`"N"`) · value |

KATs to pin:
- **File round-trip:** build HEADER(name="a.txt", total=5, flags=0) + DATA("hello") + terminator; assert the exact
  hex; feed it to the parser; assert it yields the header fields + payload "hello".
- **Split-buffer reassembly (critical):** feed the same byte stream in two chunks that cut the header in half and
  cut a DATA payload in half; assert the parser buffers and yields identical output — the §3.3/§8.3 framing state.
- **Oversized-length guard (C2):** a `len` beyond `kOnionChunk`, a `nameLen` beyond `kMaxNameLen`, and a `totalLen`
  beyond `kMaxTotalLen` must each be **rejected before allocation**, not buffered.
- **Filename sanitization (C1):** `SafeLeaf("../../.ssh/authorized_keys")`, an absolute path, `..\`, and `""` all
  reduce to a safe leaf (or `"shared-file"`); a leaf never contains a separator.
- **`"n"` vs `"N"`:** assert `nameLen` uses the big-endian u16 code and `len`/`totalLen`-halves the u32 code;
  cross-check against the LiveCode dictionary.
- **Share-code framing:** `qsMakeTorCode`→parser round-trips `.onion`, name, and (with passphrase) salt + verifier;
  a truncated `BTXTOR1:` code fails cleanly; `qsKeyOpensVerifier` still rejects a wrong passphrase up front.
- **Nonce freshness (M9):** two seals of the same feed value under one key differ (fresh random nonce prepended) and
  each opens.

### 12.3 On-engine VERIFY register (the presumed facts that must be measured)

Runnable where the real libs load; each is a hard gate on the phase noted.

- **#22 The entire `ox*` ABI** — names, signatures, semantics — confirmed against real OnionXT **before Phase 1**.
- **#6/H1 `oxDial` sync-vs-async** and the exact return discriminator (live handle vs error string; a numeric-looking
  error or empty must not read as a handle) — Phase 1.
- **#23 `oxIsReady()` == 100% bootstrap AND descriptor uploaded** — Phase 0.
- **#24/H3 Writability/backpressure callback existence** (the true-backpressure path); if absent, the capped
  ≥15 ms fallback is used — Phase 1.
- **#25 The accept-socket + `oxPeer` inbound model** (raw loopback socket vs stream handle on the peer callback) —
  Phase 1.
- **Concurrent services** — OnionXT can run N services at once (one per anon channel) — Phase 2.
- **Cookie-auth model of `oxConnectControl`** (does it read Tor's cookie file itself, or need a passed credential)
  — Phase 0.
- **#26/§9.3 OnionXT ⇒ cryptoXT dependency**, the minimum SodiumXT ABI, and that anon-without-passphrase still needs
  SodiumXT — Phase 0.
- **#27/§11.3 libtorrent-ed25519 == libsodium-ed25519 for one seed** — the offline
  `btDhtKeypair` vs `sxSignKeypairFromSeed` byte-compare **and** the live `oxServiceAddress == chChannelOnionAddr`
  compare; hard Phase-2 gate; on failure the `svc=` line applies.
- **Onion-address codec KATs:** `oxAddressFromPublicKey(pub)` equals the known v3 `.onion` for a documented test
  pubkey; `oxPublicKeyFromAddress` inverts it; `oxIsValidAddress` accepts it and rejects a one-bit checksum flip.
- **#28/§11.2 Throughput** — measure MB/s on two machines before quoting any number to users.
- **#30/§5.1 UI rects** — pill/toggle do not overlap existing header controls after the tagline shrink.

### 12.4 The real proof — two-machine on-engine pass

Each phase's §10 gate, on two machines with a live Tor daemon: byte-identical delivery (sha256), packet capture
showing onion-only traffic (no DHT/uTP), passphrase reject/decrypt and downgrade-refusal paths, path-traversal
neutralization, and — for every phase — confirmation that toggling anon OFF or removing Tor leaves the clearnet demo
untouched. Report results as "verified on OXT, two machines" — never claim runtime behavior observed only
statically.

---

## 13. Onboarding — installing & running Tor

Anon mode needs a local Tor listening on SOCKS + control. **Tor Browser uses 9150/9151, standalone/system tor uses
9050/9051**, and control access often needs enabling. The demos auto-probe **both** port pairs
(`oxSetControlPort`/`oxSetSocksPort` then `oxConnectControl` on 9051, then 9151 — §3.2) and tell the user exactly
what to fix.

### 13.1 Per platform

- **macOS.** Easiest: **Tor Browser** (SOCKS `9150`, control `9151`). Or **`brew install tor` +
  `brew services start tor`** (SOCKS `9050`; add `ControlPort 9051` + `CookieAuthentication 1` to
  `/opt/homebrew/etc/tor/torrc`, restart).
- **Windows.** **Tor Browser** (`9150`/`9151`) is the no-config path. For headless, the **Tor Expert Bundle**
  (`tor.exe`) with a `torrc` enabling `ControlPort 9051` (`9050` SOCKS).
- **Linux.** `sudo apt install tor`. SOCKS `9050` is on by default but the **control port is usually off** — add to
  `/etc/tor/torrc`:
  ```
  ControlPort 9051
  CookieAuthentication 1
  ```
  then `sudo systemctl restart tor`. (Cookie auth requires the app's user to read Tor's cookie file; on some distros
  add the user to the `debian-tor` group — the exact credential handshake OnionXT performs is a VERIFY item, §12.3.)
- **Mobile (iOS / Android) — unsupported, fails closed.** OXT runs on mobile, but a user-controllable local Tor
  daemon with an open control port is largely infeasible there. **Anon mode is explicitly unsupported on mobile:**
  the probe reports no daemon, the toggle stays disabled with a "not available on this device" tooltip, and every
  clearnet feature works normally. State this plainly in the doc.
- **Bundled tor (any desktop OS, the §11.1b path).** Ship `tor` beside the standalone and launch it with a generated
  `torrc` (`SocksPort auto`, `ControlPort auto` to a known file, `CookieAuthentication 1`); the demo reads the
  chosen ports back and calls `oxSetSocksPort`/`oxSetControlPort`. Best UX, heaviest package, and the bundled binary
  must be code-signed/notarized — a real-app choice, not the demo default.

### 13.2 How the demo detects readiness

Ordered probe, each step gating the next, surfaced in the pill/status field via `qsOnionStatus`/`chOnionStatus`
(fed by `oxSetStatusCallback`, coalesced):

1. `oxVersion()` in a `try` — is **OnionXT** loaded?
2. `sCanEncrypt` — is **cryptoXT** present? (OnionXT hard-needs it — §9.3.)
3. `oxConnectControl` on **9051, then 9151** — is a **Tor daemon** reachable and will it accept the control
   connection? (This implements the dual-port-pair promise; it is not hardcoded to one pair.)
4. `oxBootstrapProgress()` 0→100 (rendered live: "Tor: connecting NN%").
5. For inbound (a share/publisher): `oxIsReady()` true — 100% **and** the onion descriptor uploaded before we hand
   out an address; a **publish timeout** (§5.3) surfaces a failure if the descriptor never uploads.

Only when the stage the action needs is green does the transfer proceed; otherwise it **fails closed** (aborts,
never downgrades to clearnet, never queues onto the swarm).

### 13.3 Exact fail-closed messages by stage

| stage that failed | user sees (log + toggle state) |
|---|---|
| OnionXT missing | "Anonymous mode needs the OnionXT extension (org.openxtalk.library.onion), which isn't installed. Public sharing still works." — toggle disabled. |
| cryptoXT missing | "Anonymous mode also needs cryptoXT (org.openxtalk.library.sodium). Install it. Public sharing still works." — toggle disabled. (Distinct from "no Tor" — §11.4.) |
| mobile device | "Anonymous mode isn't available on this device (it needs a local Tor daemon). Public sharing still works." — toggle disabled. |
| Tor not reachable | "Couldn't reach Tor on 127.0.0.1:9051 or 9151. Start Tor (or Tor Browser) and try again. Your public sharing is unaffected." |
| control refused / auth | "Reached Tor but it refused the control connection. Enable ControlPort 9051 + cookie auth in your torrc (see onboarding), then retry." |
| bootstrapping (<100%) | "Tor: connecting NN%. Drop the file / try Download again once the pill says ready." — **the action is refused now and retried by the user; nothing is queued or sent on clearnet.** |
| descriptor not uploaded (publish timeout) | "Publishing your anonymous address to Tor is taking too long. It can take 30-60 seconds; the half-built service was cleaned up. Try again." |
| dial failed (SOCKS error) | the mapped `oxDial` error, e.g. "Tor couldn't reach that .onion (host unreachable). The sender may be offline - ask them to keep their window open, then retry." |
| transfer interrupted (no resume) | "The transfer stopped before finishing. Anonymous transfers do not resume - start it again from the beginning." |
| anon ON, Tor dropped mid-transfer | "Lost the Tor connection; the anonymous transfer was stopped. Nothing was sent over the public network." — **never** a silent swarm fallback (§11.5). |

Every message affirms the default clearnet path still works, so a user without Tor is never blocked from the
original demo — the core no-regression guarantee, stated to the user's face.

> **Resolved review findings (§13).** #13 → mobile explicitly unsupported and fails closed. #14 → dual-port-pair
> probe implemented in the ready sequence. #21 → the mid-bootstrap row is **refuse-and-retry**, resolving the
> earlier "queued" wording that contradicted §5; no pending-action queue exists. The no-resume limit is surfaced to
> the user. #15 → cookie-auth path documented (with its OnionXT VERIFY).

---

## 14. Open decisions for Seth

Everything above is resolved into a single build-ready design except these, which are genuinely yours to make:

1. **Tor delivery: document-install (11.1a) vs. bundled-tor (11.1b).** The plan ships (a) for the teaching demos and
   documents the path to (b). If you want a real-app first-run where anon "just works," commit to bundling and
   signing/notarizing a `tor` binary per platform — a real maintenance and security burden. **Recommendation:
   (a) for the demos, (b) documented for a product.**

2. **Large-file policy: warn-and-steer vs. hard-block.** The plan warns above `kAnonSizeWarn` (256 MiB) and steers to
   clearnet with an explicit privacy caveat, never auto-downgrading. If you would rather forbid large anon transfers
   outright (no clearnet steer at all), say so, and pick the threshold. **Recommendation: warn, 256 MiB, never auto-
   downgrade.**

3. **The `.onion`-from-pubkey claim, pending the ed25519 equivalence VERIFY (11.3/6.1).** If the byte-compare
   passes, ship the strong "your channel card alone is the anon locator" story. If it fails, the shipped fallback is
   the `svc=` feed line (already in the schema) and the docs drop the derivability claim. **You own reading the
   VERIFY result and choosing the wording that ships** — do not publish the strong claim unverified.

4. **Positioning / threat-model copy sign-off (11.5/7.7).** The exact in-app wording of what "anonymous" promises —
   IPs hidden for the file bytes; contents + sender-authentication only with a passphrase; Tor-usage, GPA,
   presence-oracle, plaintext-not-authenticated, and local-Tor caveats stated plainly — is user-protective copy that
   should carry your explicit approval before it ships.

5. **Publisher serve-map durability for Channels (6.5/#19).** The demo default is prune-stranded-relIds-on-restart
   with a "re-publish" log; the alternative is persisting `uOnionServe` so a restarted publisher keeps serving old
   anon releases. **You own whether the extra persisted state (and its privacy footprint on disk) is worth avoiding
   the re-publish step.** **Recommendation: prune-on-load for the demos; persist for a product.**
