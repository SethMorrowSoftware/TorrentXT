# CLAUDE.md

Guidance for Claude Code (claude.ai/code) and human contributors working in this
repository. **These instructions override default behavior; follow them exactly.**

This is the operational as-built record and the hard-won-lesson list for **No Cloud
Quick Share**, in the same spirit as the `CLAUDE.md` files in the sibling OpenXTalk
extensions it is built on (TorrentXT, cryptoXT/SodiumXT, OnionXT, and their
ancestors Box2Dxt and ShowControl). Most rules below were earned at the cost of a
runtime error, a crash, or a silent misbehavior — several of them in this app.

## What this is

**No Cloud Quick Share** is peer-to-peer file sharing with **no server, no account,
and no size limit**, delivered as a **single OpenXTalk (OXT) / xTalk stack script**
plus a small bundled static web app. Drop a file, get a short code, send the code;
the file transfers straight from your machine to your friend's. Three ways to share,
chosen in the UI:

- **Share code** — plain BitTorrent over the DHT (the code *is* the file's
  content-address / info-hash; your IP is visible to peers).
- **Private / Tor** — the bytes ride a Tor onion stream, both IPs hidden, no torrent
  created.
- **Web link** — a plain browser link, no app needed on the other end.

Any file can be encrypted end-to-end with an optional passphrase. See
`docs/what-it-hides.md` for the precise, honest transport/privacy model — read it
before touching anything that touches the wire.

```
src/nocloudquickshare.livecodescript   the whole app: self-building UI, the 3
                                        transports, the HTTP + Tor servers, the
                                        optional LAN web editor, the poll loop
webapp/                                 a bundled static SPA you can serve over a
                                        web link or a Tor page (demonstrates the
                                        static host + the /_qs/info live route)
tools/check-livecodescript.py           the static linter (one of two gates)
tests/fileserver_golden.py              the pure-logic golden (the other gate)
docs/                                   what-it-hides, webapp, building-a-standalone
```

## The stack it sits on (dependencies)

The app is a **binding consumer**: it calls into prebuilt OXT extensions. It does
**not** build any native code — there is nothing to compile in this repo.

| Extension | Library id | Handlers | Required? | Without it |
|---|---|---|---|---|
| **TorrentXT** | `org.openxtalk.library.torrent` | `bt*` | **REQUIRED** | no session; the app cannot run |
| **cryptoXT** (SodiumXT) | `org.openxtalk.library.sodium` | `sx*` | optional | no passphrase encryption, no LAN-editor password, no Tor (see below) — everything else works |
| **OnionXT** | (Tor onion transport) | `ox*` | optional | no "Private / Tor" path; the other two work. Needs cryptoXT **and** a local Tor daemon |
| Internet library (libURL) | — | `load URL` | optional | only the public-IP lookup on the web-link path; harmless if absent (try-guarded) |

**The fail-closed rule (non-negotiable).** Every optional-extension call site is
guarded. The app probes each dependency **once** at startup into a script-local
boolean and never calls a guarded handler outside its guard or a `try`:

- `qsCanEncrypt()` → `sCanEncrypt` — a guarded `sxSecretBox`/`sxSecretBoxOpen`
  round-trip. Gates every `sx*` call.
- `qsHasOnion()` → `sHasOnion` — requires `sCanEncrypt` first (OnionXT depends on
  cryptoXT), then a guarded `oxVersion()`. Gates every `ox*` call.
- `sTorReady` / `qsOnionReadyNow()` (`oxIsReady()`) — the Tor daemon's **live**
  bootstrap state, cached by a callback but **re-checked at the moment of use**.
  Never trust the cached live flag for a go/no-go decision.

When a dependency is missing the affected feature reports a clear "install
org.openxtalk.library.sodium" / "install OnionXT + a local Tor daemon" message and
**every other feature keeps working**. This is the pattern cryptoXT taught the
family; do not break it.

## The three safety rules (inherited, and why they still bind here)

Even though this is the script layer, the discipline the underlying extensions were
built on is what keeps the app stable:

1. **Never call an extension handler from a foreign (engine) thread.** Inbound
   BitTorrent events ride TorrentXT's alert queue, which we **poll-drain on a timer**
   (`btPoll` in `qsPollOnce`, every 250 ms). No engine callback ever runs app script.
   OnionXT stream callbacks are the one exception the extension explicitly supports —
   and they are still marshalled onto the interpreter thread.
2. **Payload never crosses the FFI into script.** TorrentXT moves gigabytes engine ⇄
   disk on its own threads; the app only issues tiny commands and polls small status
   records. If you ever find yourself putting piece/file bytes into a LiveCode `Data`,
   you have taken a wrong turn. (The Tor path *does* move bytes through script, and
   honors the rule by **fixed-slice streaming** — one bounded frame per pump, never
   the whole file in memory.)
3. **The engine already firewalls exceptions;** don't defeat it. TorrentXT wraps every
   `btx_*` entry in `try/catch(...)`. On the script side, wrap anything that can throw
   (every `sx*`/`ox*` call, clipboard reads, file ops) in a `try` so one failure never
   takes the stack down.

## App-layer OXT runtime lessons (THIS APP — earned the hard way)

These are the bugs the app hit on real OpenXTalk passes. They are not catchable by
the static gate; they are the reason "verified statically; needs an OXT pass" is a
rule and not a hedge.

1. **Build the UI in a place that survives a script recompile.** OXT sends
   `openStack` — **but NOT `preOpenStack`** — when the stack *script* is recompiled
   (the "paste THIS into the stack script" flow every user follows first). If the UI
   is built only in `preOpenStack`, a recompile starts the session and the poll/
   refresh loops against a UI **that was never built**, and the first refresh tick
   dereferences a missing field (`Chunk: no such object` at `field "qsXfers"`). The
   fix, in place: `preOpenStack` builds it (flash-free on a real open) **and** `qsStart`
   calls `qsBuild` first (the guaranteed build on the recompile path). `qsBuild` is
   idempotent (early-exits when the version matches and the controls exist), so the
   second call is a no-op. **Belt-and-suspenders:** every timer-driven refresh handler
   bails if its list field doesn't exist yet (`if there is no field "qsXfers" then
   exit`).

2. **Never GUESS font metrics — measure, and FIT the field to the text.** Hand-sized
   label rects clip text on Windows (different line metrics). The label helper
   (`qsLabel`) sets the field's height to its own `the formattedHeight` (top pinned),
   so the field exactly holds its text. This does double duty: it prevents clipping,
   **and** it makes `the height of field` equal the *text* height — which the band-
   title and step-badge centering (`set the top to (midline - height/2)`) depend on.
   - A **grow-only** variant (only enlarge, never shrink) is WRONG here: it leaves the
     field at its taller rect height and the centering places text too high. Fit, don't
     grow.
   - **Guard it:** only resize when `the formattedHeight > 0`. A blank measurement is
     possible before the window is fully realized; setting height to 0 would collapse
     every label to nothing (a blank UI). If the measurement is unusable, keep the rect.

3. **`set the margins` needs the 4-item form on OXT.** `set the margins of field X
   to 0` (a single number) is silently ignored; use `"6,6,6,6"`. This was the original
   cause of clipped labels before the measured-fit approach replaced margin fiddling.

4. **Chrome is graphics, not styled fields.** Cards, the title band, the Tor status
   chip, and section dividers are `graphic` objects (roundRect / rectangle), created
   **before** the controls that sit on them so they stay behind in z-order. A soft
   `dropShadow` is applied inside a `try` (an older engine without graphic effects just
   skips it; the hairline border still separates the card). `qsClearGeneratedUI` must
   delete **graphics** as well as fields and buttons on a version-rebuild.

5. **`does not contain` is not valid xTalk.** The parser errors on `does`. Negate with
   `not (X contains Y)` (or `X is not among …`). The static checker flags this class.

6. **Quote a `send` parameter that can hold a `:`.** A clearweb socket id is
   `"ip:port"`; `send ("qsCwWatchdog " & quote & pSocketID & quote) to me in …` — an
   unquoted id re-parses as an expression and syntax-errors. Numeric handles (OnionXT
   streams) are fine unquoted.

7. **Read the clipboard inside a `try`.** It can fail transiently on Windows when
   another app holds it. The clipboard auto-detect offers each value **once**
   (`sClipSuggested`), never overwrites user input, and never suggests the app's own
   outbound codes (`qsIsOwnCode`).

8. **Self-building UI + version discipline.** `qsBuild` regenerates the whole UI when
   `the uUiVersion of this stack` differs from `kQsUiVersion`. **Any change to the
   generated layout MUST bump `kQsUiVersion`**, or a *saved* stack keeps its old
   controls and never picks up the change. The user-facing release string is a separate
   constant, `kQsAppVersion` (shown in the title bar, the startup log, and the HTTP
   `Server:` header).

9. **Clean shutdown on every exit path.** A standalone quits via `shutdownRequest`
   **without** a guaranteed `closeStack`. Both call `qsStop` (idempotent), which stops
   the session (pause → flush resume → join), tears down the Tor service and the web
   listener, and deletes temp `.enc` files. Don't add a teardown that only runs on
   `closeStack`.

## The optional-extension / encryption discipline (cryptoXT)

Encryption is **cryptoXT (libsodium)**, never OXT's built-in `encrypt using
"aes-256-cbc"`. The flow: a passphrase derives a key with **Argon2id** (`sxPwHash`),
files are sealed with **`sxEncryptFile`** (streaming `crypto_secretstream`,
authenticated — truncation is detected on decrypt), and small tokens/verifiers with
**`sxSecretBox`**.

- **KDF params must be identical on both ends** or the keys differ: **opslimit `"2"`
  + `sxPwMemInteractive()`**. Change them on one side only and every transfer breaks
  silently. If you change them, change both and **bump the on-wire format marker**.
- **Versioned format markers.** Encrypted share codes are `BTXQS1:` (code path) and
  `BTXTOR1:` (Tor path); the channels sibling uses `BTXENC2:`. A new wire/at-rest
  format gets a versioned magic prefix, is pinned in the golden, and old readers must
  reject an unknown prefix cleanly (not mis-parse it). Data written by an incompatible
  format must not silently open.
- **Verify the passphrase up front.** A small authenticator rides in the code, so a
  wrong passphrase is caught *before* any ciphertext is downloaded.

## The single-threaded performance playbook

OXT runs script, the FFI, and rendering on **one interpreted thread**. Costs, in
order: **(1) interpreter ops, (2) FFI round-trips, (3) property-set redraws.**

- **One FFI round-trip per poll.** `btPoll` drains all events in one call; a
  `btTorrentStatus(tH)` returns the whole status `Array`. Never one FFI call per event
  or per field.
- **Repaint the UI at ≤ ~4 Hz and only on change.** The transfers list retypes only
  when its text actually changed (`sLastXferRows`); the dashboard loop runs at 1 Hz.
  An every-frame field relayout+redraw is the biggest avoidable cost — and a mid-drag
  repaint can even compete with OS drop delivery and make a drop intermittently fail.
- **One clock read per pass.** Hoist `the milliseconds` out of loops.
- **The HTTP servers stream.** A multi-GB download is served one bounded slice per
  write-completion (clearweb 256 KiB, Tor 64 KiB) with natural backpressure — the file
  is never read whole into memory, and each slice reopens/seeks/reads/closes so
  concurrent downloads never share a cursor.

## LiveCodeScript / OXT gotchas (OXT is stricter than LiveCode)

1. **Pure ASCII only** — no smart/curly quotes (U+2018/2019/201C/201D) anywhere, even
   in a comment. They fail OXT compilation. The checker enforces zero.
2. **Reserved-word stem shadowing.** A prefixed name whose full spelling is a reserved
   token (`tExt` = `text`) is evaluated as the keyword, not your variable — it compiles
   and misbehaves silently. Use distinctive multi-word stems. The checker flags this.
3. **Prefixes:** `t` handler-local, `p` parameter, `s` script-local, `k` constant;
   public helpers `qsPascalCase` here (the app's namespace is `qs*`).
4. **Constants: literal and declared before first use.** OXT resolves them by lexical
   position; a forward reference silently evaluates to nothing. The `kClr*` design
   tokens and the `k*` protocol constants are declared in one block up top.
5. **Declare all `local`s at the top of a handler.** A nested `local` has broken
   whole-script compilation in this family before.
6. **Commands report via `the result`; functions return a value.** e.g. `btAddMagnet`
   is a command → `put the result into tH`; `btTorrentStatus(tH)` reads as a function.
7. **`itemDelimiter` / `lineDelimiter` are global mutable state** — set them
   immediately before use (the code sets `the itemDelimiter to ":"` right before
   splitting a `BTXQS1:`/`BTXTOR1:` code).

## Testing: the two gates + the OXT pass

There is **no headless way to compile or run a `.livecodescript`**. So the automated
safety net is exactly two things, and both must pass before any change is "done":

```sh
python3 tools/check-livecodescript.py     # the linter (smart quotes, handler/block
                                          # balance, constant-before-use, stem shadowing,
                                          # invalid operators like `does not contain`)
python3 tests/fileserver_golden.py        # pins the pure-logic helpers: HTTP range
                                          # parse, MIME, request framing, the editor
                                          # path-confinement (qsEditSafePath), dotfile
                                          # guard, filename sanitiser, rate/ETA format
```

Then do a **manual OXT pass**: open OpenXTalk, make a one-card stack, paste the script
into the stack script, close+reopen, exercise it. **Claim only "verified statically;
needs an OXT pass" for anything you could not observe on a running engine.** This is
the through-line of the whole extension family: *never claim runtime behavior you
cannot observe.* When you add a helper with a pure-logic core, **mirror it in the
golden** so it can never silently drift.

## Standalone packaging

The app is standalone-ready:

- The UI self-builds every launch (nothing needs to persist in the stackfile).
- Downloads land in `Documents/No Cloud Quick Share` on every platform.
- In the standalone builder: include **org.openxtalk.library.torrent** (required),
  and **org.openxtalk.library.sodium** (cryptoXT) + **OnionXT** for the optional
  encryption / Tor features — both fail closed when absent. Include the **Internet
  library** for the (try-guarded) public-IP lookup. No other inclusions, externals,
  or native resources are needed. See `docs/building-a-standalone.md`.

## Git / workflow

- Develop on a per-task branch (`claude/...` or a feature name); open a **draft PR**;
  don't push to `main` without explicit permission.
- A change is only "done" once `tools/check-livecodescript.py` **and**
  `tests/fileserver_golden.py` pass, and any layout change has bumped `kQsUiVersion`.
- Match the surrounding style: this codebase comments the **why**, densely — mirror it.
- Do not claim a runtime fix works until it has had an OXT pass; say what was verified
  statically and what still needs the engine.
