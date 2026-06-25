# Phase-0 FFI spike: the Data <-> Pointer bridge

The one empirically-unconfirmed FFI primitive in this project is how a LiveCode
`Data` crosses into a C `Pointer` parameter and back. Everything else the binding
does (ints, doubles, `ZStringUTF8` short strings) is well-trodden from Box2Dxt and
ShowControl. This document records the spike (plan section 8.1, section 10 Phase 0; marshalling
in section 6) and its outcome: **the idiom is confirmed against the sibling source and
implemented in `src/torrent.lcb`; the end-to-end round-trip still needs one human
OXT pass to sign off**, because OXT has no headless `.lcb` compiler.

It is a deliberately **low-stakes** unknown here: we cross **status records and
events, never payload** (architecture.md, rule 3). The gigabytes move engine <->
disk on libtorrent's threads. So even if the bridge needed a fallback encoding,
the data crossing it is kilobytes of small records, not the download.

---

## What had to be proven

Two things, in order, gate the whole project:

1. **The abi_version round-trip** - the trivial end-to-end: LCB calls a foreign
 `btx_abi_version()` that takes nothing and returns a `CInt`, and the binding
 compares it to its own `kABIVersion`. This proves the library loads, the
 `c:torrentxt>` mapping resolves, and a flat `extern "C"` call returns correctly.
 It is the first call the binding ever makes (`_checkABI()` inside
 `btStartSession`), so it is also the project's startup self-test.
2. **The `Data` <-> `Pointer` out-buffer round-trip** - the real unknown: hand C a
 buffer it can write into, and read the bytes back out in script. This is the
 mechanism behind *every* getter, the status snapshot, and the alert drain.

If (1) fails the binding cannot load at all; if (2) fails the record-walking
getters cannot work. Both are confirmed statically and in the sibling extension;
both want the human OXT confirmation that closes Phase 0.

---

## The idiom (the ShowControl / midi.lcb pattern, confirmed)

The pattern is taken verbatim from ShowControl's `midi.lcb`, which ships and runs
this exact bridge for its MIDI FIFO drain. Three moving parts:

### 1. A pre-sized `Data` bridges to a `Pointer`

The foreign handler declares the buffer parameter as `Pointer` and a length as
`CInt`:

```
private foreign handler _btx_pop_alerts(in pS as CInt, in pOut as Pointer, in pCap as CInt) \
   returns CInt binds to "c:torrentxt>btx_pop_alerts!cdecl"
```

On the script side you allocate a `Data` of the right size and **pass it
positionally where the `Pointer` is expected**. LCB bridges it to a pointer to its
first byte; C writes into that memory in place. You also pass the byte count as the
capacity:

```
unsafe
   put _btx_pop_alerts(pSession, sDrain, the number of bytes in sDrain) into tCount
end unsafe
```

There is no marshalling copy and no separate "make a pointer" call - a pre-sized
`Data` *is* the buffer. Every `unsafe ... end unsafe` brackets exactly the foreign
call, and (the other OXT rule) every `variable` is declared at the top of its
handler.

### 2. C returns bytes-written, or `-needed`

The C side follows the out-buffer convention locked in `btx_abi.h` and implemented
by `RecordWriter` in `btx_record.h`:

- it **measures or writes** into the supplied buffer, advancing its write position
 for every field but only copying bytes while they fit within `cap`;
- it returns the **number of bytes written** (>= 0) when everything fit, or the
 **negative of the capacity it needed** when the buffer was too small;
- a call on a **stale/invalid handle is a no-op returning 0** (an empty record) -
  never a crash, and never a small negative that could be confused with a
  `-needed` value (that is why the two function families keep separate
  conventions: action codes are negative, getters are bytes/`-needed`/0).

### 3. Script walks the bytes by arithmetic

The records are self-describing, typed, length-prefixed KV records with **all
framing integers big-endian** (the wire format; architecture.md and
`btx_record.h`). The LCB walker reads them with plain byte arithmetic - no float
unpacking:

```
-- big-endian u16 at 1-based offset
put the code of (byte pOffset of pData) into tHi
put the code of (byte (pOffset + 1) of pData) into tLo
return tHi * 256 + tLo
```

and pulls sub-ranges with `byte X to Y of pData`, decoding UTF-8 fields with
`textDecode(... , "UTF-8")`. This is the inverse of the shim's `put_u16` /
`field_*` writers, byte for byte. `tools/check-record-registry.py` proves the
field-id and alert-code constants in the binding never drift from `btx_record.h`,
and `tests/record_golden_test.py` pins the framing independently - so the only
thing the OXT pass has to confirm is that **the bridge itself moves the bytes**,
not that the format is right.

### Inbound buffers are the same trick, simpler

An **inbound** `Data` (a `.torrent` file, resume bytes, a priorities array) bridges
the same way: the `Data` becomes the `Pointer`, and you pass its length:

```
put _btx_add_torrent_file(pSession, pData, the number of bytes in pData, pSavePath) into tHandle
```

C only reads it; nothing comes back through the buffer.

---

## The reusable buffers + grow-on-(-needed) retry

The single-thread performance playbook forbids rebuilding an N-byte `Data` every
poll (that is O(N) interpreter work each frame). So the binding allocates three
buffers **once** and reuses them:

| buffer | seed capacity | used by |
|---|---|---|
| `sDrain` | `kDrainCap` = 65536 | the alert drain (`btPoll`) |
| `sStatus` | `kStatusCap` = 8192 | status / peer / bitfield / DHT / create snapshots |
| `sScratch` | `kScratchCap` = 512 | short strings (last-error, info-hash, get-setting) |

`_ensureBuffers()` lazily fills them with zero bytes (built by doubling a 256-byte
seed, the midi.lcb trick) and keeps them sized. Every getter then uses the same
**measure-then-retry** shape:

```
unsafe
   put _btx_pop_alerts(pSession, sDrain, the number of bytes in sDrain) into tCount
end unsafe
if tCount < 0 then
   -- even the first record did not fit: grow to exactly what C asked for, retry once
   put _makeZeroData(-tCount) into sDrain
   unsafe
      put _btx_pop_alerts(pSession, sDrain, the number of bytes in sDrain) into tCount
   end unsafe
end if
if tCount <= 0 then
   return the empty list   -- 0 == no alerts / bad handle
end if
```

One retry suffices: C returned the **exact** size it needs, so the grown buffer
fits. After a grow the buffer stays large, so steady-state polling never
reallocates. The drain additionally **never drops a record** - if more records are
pending than fit even after the grow, the shim stashes the overflow and emits it on
the next call (ShowControl's MIDI rule).

---

## The abi_version gate, concretely

`btStartSession` runs the gate before anything else:

```
private handler _checkABI()
   variable tABI as Integer
   unsafe
      put _btx_abi_version() into tABI
   end unsafe
   if tABI is not kABIVersion then
      throw "TorrentXT native library ABI does not match the LCB binding; rebuild and repackage the native library."
   end if
end handler
```

`kABIVersion` (currently `1`) must equal `BTX_ABI_VERSION` in `btx_abi.h`. Any ABI
change bumps both together. A legible throw at startup is the design goal - far
better than a layout-skew crash on first record walk. This is also the smallest
possible proof that the FFI works at all, which is why the plan makes it the very
first Phase-0 deliverable.

---

## The documented fallbacks (if a strict OXT build balks)

Honest contingencies, in increasing order of how much they would cost. None has
been needed against the sibling source, but they are recorded so the OXT pass has
somewhere to go if it hits a wall:

1. **The byte operators do not resolve.** If a given OXT build will not resolve
 `the code of (byte ...)`, `byte X to Y of`, or `textDecode` from the default
 imports, add `use com.livecode.byte` alongside the existing
 `use com.livecode.foreign` at the top of `torrent.lcb`. The header comment in
 the file already flags this as the first thing to try. This is a one-line
 import change, not a redesign.
2. **A `Data` will not bridge positionally to a `Pointer`.** The deepest
 contingency. If a strict build rejects passing a pre-sized `Data` where a
 `Pointer` is declared, the fallback is to cross the (small) records as
 **hex-encoded `ZStringUTF8`** instead of raw bytes - strings are the most
 thoroughly proven bridge we have. This roughly doubles the bytes moved and adds
 an encode/decode step, but it is viable **precisely because only status records
 cross, never payload** (plan section 6 calls this the hex-over-string fallback). It is
 a real change to the ABI surface (the buffer getters would return hex text), so
 it would bump `BTX_ABI_VERSION`; reach for it only if (1) and the direct bridge
 both fail in OXT.
3. **A specific record value misbehaves.** 64-bit ints and info-hashes already
 cross as ASCII inside the records (an LCB number is a `double` and would lose
 precision), so there is no separate binary 64-bit field to fail. If a UTF-8
 field round-trips badly, confirm the `textDecode` encoding string is exactly
 `"UTF-8"`.

---

## Status: what is confirmed, what still needs a human

| claim | how confirmed |
|---|---|
| the bridge idiom matches a shipping extension | read against ShowControl `midi.lcb` (the source of the pattern) |
| the binding implements it correctly (handler/`unsafe`/constant hygiene) | `tools/check-livecodescript.py`, run on every edit |
| the record framing is byte-exact and big-endian | `tests/record_golden_test.py` + `tests/record_handle_test.cpp` (ASan/UBSan) |
| the LCB constants match the C registry | `tools/check-record-registry.py` |
| **the `Data` <-> `Pointer` round-trip + abi_version actually run in OXT** | **NOT yet - needs the human OXT pass that closes Phase 0** |

Per the repo-wide honesty convention: this is "verified statically; needs an OXT
pass." Do not mark Phase 0 green until a human compiles the binding in OXT,
confirms `btStartSession` clears the ABI gate, and watches an out-buffer getter
(e.g. `btTorrentStatus` or `btPoll`) return a correctly-walked record. That single
observation retires the project's one open FFI risk.
