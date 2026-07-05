# Contributing to No Cloud Quick Share

Thanks for pitching in! No Cloud Quick Share is a small, sharp desktop app: one OpenXTalk/xTalk stack script plus a bundled static web-app. This guide is short, but please read it start to finish — the workflow here is unusual because of what OXT is, and skipping a step is how bugs sneak in.

## The shape of the repo

```
src/nocloudquickshare.livecodescript   the whole app: one LiveCodeScript stack
webapp/                                 the bundled static web-app it serves
tools/check-livecodescript.py           static gate for the stack script
tests/fileserver_golden.py              pure-logic reference for the file server
docs/                                   design notes
```

Almost everything lives in that one `.livecodescript` file. The web-app under `webapp/` is plain static assets (HTML/CSS/JS) that the stack serves over the local network and, optionally, over Tor.

## The golden rule: OXT is a GUI runtime

This is the single most important thing to internalize.

**OpenXTalk / xTalk has no headless mode. There is no way to compile or run a `.livecodescript` from the command line.** You cannot `oxt --check foo.livecodescript`. The only thing that compiles and runs the script is the OXT IDE, with a human driving it.

So we work in two layers:

1. **What is statically catchable** — smart quotes, unbalanced handlers, name-shadowing traps, a busted byte-range parser. We catch these with the two Python scripts below, and you must run both before every change.
2. **What is only observable at runtime** — does the UI actually lay out, does the server actually serve, does the button actually fire. This needs a **manual OXT pass**: a human opening the stack in OpenXTalk.

Because of this split, there's a hard honesty rule for anything runtime-related:

> **Never claim runtime behavior you have not observed in OXT.** If you changed a handler and the static gates pass, the correct thing to say is *"verified statically; needs an OXT pass."* Do not write "fixed the server hang" or "the dialog now closes" unless you actually watched it happen in the IDE. This is not pedantry — the static tools genuinely cannot see those things, and overclaiming is how regressions ship.

## Before every change: run both checks

Every change to `src/nocloudquickshare.livecodescript` (and any `.lcb`, if you add one) must pass **both** of these, every time:

### 1. The static script gate

```sh
python3 tools/check-livecodescript.py
```

This is a lexer-level checker (not a compiler) that scans every `.lcb` and `.livecodescript` in the repo. It enforces the rules OXT would otherwise only surface as a cryptic compile error — or, worse, a silent misbehavior — including:

- **Pure ASCII / no smart quotes.** Any curly quote (`‘ ’ “ ”`) or *any* non-ASCII byte anywhere — even in a comment — is rejected. OXT source is pure ASCII. Use straight `"` and `'` only.
- **Balanced strings** — no stray unterminated `"` on a logical line.
- **Balanced blocks** — every `on/command/function/if/repeat/switch/try` is matched by its correct `end`, with line numbers on any mismatch.
- **No name that spells a reserved token** — e.g. `tExt` lowercases to `text`, which xTalk evaluates as the keyword, not your variable. It flags any `t/p/s/k`-prefixed name whose full spelling is a reserved word.
- **No invalid `does not ...` negation** — `does not contain` / `does not begin with` are not valid xTalk; the parser errors on `does`. Use `not (X contains Y)` etc.

Exit code `0` means clean.

### 2. The file-server golden test

```sh
python3 tests/fileserver_golden.py
```

This is the safety net for the security- and correctness-critical logic inside the stack — the parts of the file server that *can* be verified off-engine. It's a hand-written pure-Python reference that mirrors specific handlers, byte-for-byte, in behavior. If the golden and the `.livecodescript` disagree, **one of them is wrong** — and given what these handlers do, that's not a bug you want to find in production.

It currently pins the logic of (LiveCodeScript handler → Python mirror):

| Handler | What it decides |
|---|---|
| `qsFsParseRange` → `parse_range` | RFC 7233 single byte-range; 416 on out-of-range |
| `qsFsServePath` → `traversal_ok` | path-traversal refusal (`..` after urlDecode + `\`→`/`) |
| `qsHasDotSegment` → `has_dot_segment` | dotfile guard (`.git`/`.env` invisible to static serving) |
| `qsFsMime` → `mime` | extension → MIME mapping |
| `qsFsIcon` → `fs_icon` | directory-listing icon class |
| `qsFsHtmlEscape` → `html_escape` | HTML escaping (`&` first) |
| `qsCwServe` → `capability_route` | clearweb `/<token>/` capability gate |
| `qsSiteSpaTarget` → `spa_is_route` | SPA route-vs-missing-asset fallback |
| `qsHttpHeaderEnd` / `qsHttpReqComplete` / `qsHttpReqLength` | HTTP request framing + keep-alive |
| `qsJsonEscape` → `json_escape` | JSON value escaping |
| `qsEditSafePath` → `edit_safe_path` | web-editor **write**-path confinement (the linchpin) |
| `qsEditIsLocal` → `edit_is_local` | web-editor LAN-first gate (the other linchpin) |
| `qsQueryParam` → `query_param` | `?path=` extraction |
| `qsFileSizeSeek` → `file_size_probe` | O(log n) file-size probe |
| `qsSafeFilename` → `safe_filename` | Content-Disposition filename sanitiser |
| `qsRateShort` / `qsEtaShort` | compact transfer-row rate + ETA formatting |

Two of these — `qsEditSafePath` and `qsEditIsLocal` — gate a path that can **write to disk** and must only be reachable from the local network. Treat any change to them with real care.

## Then: the manual OXT pass

Once both scripts are green, do the human step:

1. **Open the stack** in the OpenXTalk IDE (`src/nocloudquickshare.livecodescript`).
2. **Paste your changes into the stack script** (Object → Stack Script), if you edited the file outside the IDE.
3. **Close and reopen the stack** to confirm it compiles cleanly from cold and the UI builds itself correctly (see below).
4. Exercise whatever you touched — start a share, open the served page in a browser, click the buttons.

Only after you've actually watched the behavior can you describe it as working. Until then it's *"verified statically; needs an OXT pass."*

## The self-building UI and `kQsUiVersion`

The app **builds its own interface in script** rather than relying on controls saved into the stack. This keeps the whole app diffable as text and lets the layout be rebuilt deterministically.

The consequence: when you change the layout — add a control, move something, resize, rename a widget the code addresses — you must **bump `kQsUiVersion`**. On open, the stack compares the stored UI version against `kQsUiVersion`; if they differ, it tears down and rebuilds the interface from scratch. If you change the layout code but *forget* to bump the constant, an existing stack keeps showing the **old** UI and your change appears to do nothing — a classic head-scratcher. So: **layout changed → bump `kQsUiVersion`**, then close+reopen to watch it rebuild.

## Naming conventions (brief but enforced)

The static checker relies on the prefix convention, so please follow it:

- `t` — handler-local variable
- `p` — parameter
- `s` — script/stack-local variable
- `k` — constant (must be literal, declared before first use)
- Public/app handlers use `qs`-prefixed names (`qsFsMime`, `qsEditSafePath`, …).

And the trap worth repeating: **never pick a prefixed name whose full lowercased spelling is a reserved word.** `tExt` is `text`; `sSort` is `sort`; `pPut` is `put`. xTalk resolves these as keywords and your "variable" silently misbehaves. Use a distinctive, multi-word stem instead (`tSuffix`, not `tExt`). The checker will catch the known cases, but internalizing the rule saves you a round trip.

## Adding a helper with a pure-logic core

Lots of the interesting handlers have a **pure-logic core** — they take strings/numbers in and produce a decision out, with no reference to the UI, disk, or sockets. Anything shaped like that (a parser, a guard, a formatter, a classifier) should be **mirrored in the golden test**. That's how we get real coverage on a runtime we can't script.

The recipe when you add such a helper:

1. **Write the LiveCodeScript handler** in `src/nocloudquickshare.livecodescript`, keeping the pure-logic part cleanly separable from any I/O.
2. **Add a faithful Python mirror** in `tests/fileserver_golden.py`, named after the handler and with a comment noting which handler it mirrors (match the existing style at the top of the file).
3. **Reproduce xTalk semantics exactly**, not just the happy path. The existing mirrors document the gotchas that bite: `item N of X` is 1-based and returns empty past the end; `X is an integer` rejects decimals; `urlDecode` turns `+` into a space (so the mirror uses `unquote_plus`, not `unquote`); `the round of` rounds half away from zero. If your handler leans on an xTalk quirk, encode that quirk in Python and note it in a comment.
4. **Add table-driven cases in `main()`** covering the edges — empties, out-of-range, traversal attempts, case-insensitivity, the deliberately-strict rejections. Look at the existing blocks for the density we aim for.
5. Run `python3 tests/fileserver_golden.py` until it's green.
6. During your OXT pass, spot-check a couple of the same inputs against the real handler so you've *seen* the two agree at least once.

If a handler is genuinely all I/O (it opens a socket, reads a file, sets a UI property) there's nothing to mirror — that's exactly the stuff the manual OXT pass is for.

## Checklist before you open a PR

- [ ] `python3 tools/check-livecodescript.py` is clean
- [ ] `python3 tests/fileserver_golden.py` is OK
- [ ] New pure-logic helpers are mirrored + covered in the golden
- [ ] Layout changed? `kQsUiVersion` bumped
- [ ] Did an OXT pass: opened the stack, pasted the script, closed + reopened, exercised the change
- [ ] PR text distinguishes what you **observed in OXT** from what's **verified statically; needs an OXT pass**
- [ ] New comments explain the *why* (match the surrounding style — this codebase comments densely)

That's it. Keep it ASCII, keep both scripts green, mirror your logic, and always tell the truth about what you actually saw run. Welcome aboard!