#!/usr/bin/env python3
"""check-livecodescript.py - the static gate for the script layer.

OXT is a GUI runtime: there is NO headless way to compile or run .lcb /
.livecodescript, so the static checks below are the only automated safety net
the script layer gets. Each check encodes a gotcha that OXT compilation (or
silent misbehaviour) would otherwise punish; every one was paid for on a real
engine somewhere in this family.

THIS FILE IS THE UNIFIED CHECKER, KEPT BYTE-IDENTICAL ACROSS EVERY MEMBER.
The suite used to carry two independent implementations (one lineage in
sodiumxt/onionxt/coinxt/riptide, another in torrentxt/enetxt/datachannelxt),
each with real checks the other lacked - sodiumxt's copy famously did not know
`switch`, so it reported phantom imbalances in dispatchers the other lineage
parsed fine, and would have hidden a real one. This file is the union of both
lineages - and, since 2026-08-15, of a THIRD: the hold-em lineage checker
(born in Box2Dxt, carried into holde-em as tools/check-holdem-idioms.py),
whose member-only checks all had shipped-defect provenance and are now checks
13-21 below; that file is retired. Do not edit one copy: edit every member's
copy identically (they are the same bytes), and the suite gate
tools/check-checker-drift.py FAILS the build if any copy differs from the
others, so a fix applied to one member can no longer silently miss the suite.
tools/test-checker.py at the suite root holds the fixture tests for every
rule here; extend it in the same change as any new rule.

The checks, and the engine lesson each encodes:

  1.  ASCII only. Smart/curly quotes fail OXT compilation outright; en/em
      dashes break house style; the proven siblings contain zero non-ASCII
      bytes, so ANY non-ASCII character is reported. A non-UTF-8 file is
      refused outright.
  2.  Unterminated strings and /* block comments (lexer-level).
  3.  Balanced blocks, matched by kind and dialect: handler/if/repeat
      (+ unsafe in .lcb; switch/try in .livecodescript), with line numbers.
      An LCB library/module/widget must close with its matching `end`.
  4.  Constants declared before first use, BOTH dialects - OXT resolves a
      constant by lexical position; a forward reference silently evaluates
      to nothing (LCS) or empty (LCB). LCS spells it `constant k = ...`,
      LCB `constant k is ...`; both shapes are checked - and the WRONG
      dialect's spelling is refused outright (the antipattern sets), because
      a mis-spelled declaration is INVISIBLE to this before-use check: the
      carried `is` constants of 2026-08-13 sailed through this gate, a
      fail-open in the gate itself.
  5.  Declarations at the top of a handler, .lcb ONLY - a `variable` below
      the handler's first statement has broken whole-LCB compilation (the
      torrentxt lesson), and this is the check the house rule always claimed
      to have. It is deliberately NOT applied to .livecodescript: mid-handler
      `local` is legal LCS and stands at ~150 sites in ENGINE-PASSED code
      (onionxt's live-Tor-proven source above all), so flagging it would
      manufacture violations in the family's most-proven files. The LCS
      top-of-handler habit stays a style convention, not a gate.
  6.  The prefixed-token-shadow trap: a t/p/s/k-prefixed name whose full
      spelling lowercases to a reserved token (`tExt` is t-e-x-t = `text`)
      compiles and silently misbehaves. Both dialects.
  7.  `does not begin/end with` / `does not contain` - not xTalk; the parser
      errors on `does`. Both dialects.
  8.  A zero-argument call written `foo()` in STATEMENT position
      (.livecodescript only - LCB allows it): `()` is not an expression, and
      one such line takes the whole file with it (the dcCleanup() lesson).
  9.  Engine-hostile constructs that COMPILE and silently do the wrong thing
      (.livecodescript only): `repeat with ... step N` (the increment is not
      honoured; the cxHexDecode lesson) and `throw` inside a `catch` block
      (the error never reaches the caller; the cxMnemonicValidate fail-open).
      `return` inside a catch is FINE and engine-proven; only `throw` is
      flagged.
  10. LCB-only: a foreign type used without `use com.livecode.foreign`;
      textEncode/textDecode inside a module (they are LCS-only); `the empty
      list` / `the empty array` (LCB wants the literals `[]` / `{}`); an
      all-lowercase `variable` name (OXT warns it may become reserved).
  11. LCS-only: braces (LCB array literals leaking into script) and
      subscripting a function result (`f(x)["k"]` does not parse).
  12. `put X into Y after Z` - a `put` takes `into` OR `after`/`before`,
      never both. Both dialects.
  13. A bitwise operator invoked with FUNCTION-CALL syntax and two arguments -
      `bitXor(a, b)` - .livecodescript only. bitAnd/bitOr/bitXor/bitNot are
      OPERATORS in this dialect, not functions; the call form is exactly the
      shape of holde-em's shipped defect (`bitXor(acc, baseConvert(...))`,
      gotcha H7, which threw double/binary at runtime on its first OXT pass).
      Only the two-argument call form is refused: the OPERATOR form
      (`a bitXor b`, `tM bitAnd (bitNot 255)`) stands in ENGINE-PASSED code
      across box2dxt (the Kit's collision layer bits), nocloud and torrentxt
      (the onion frame flags), and sodiumxt's examples (tamper flips), so a
      blanket bitwise refusal - which the hold-em lineage carried as member
      law - would manufacture violations in the family's most-proven files.
      holde-em's stricter no-bitwise-at-all convention stays that member's
      prose law (its playable path uses pure-integer heByteXor).
  14. A declared local or handler parameter whose FULL name case-insensitively
      IS an engine token (`local tAb`: `tAb` is the `tab` constant; a param
      named `id`) - .livecodescript only. Complementary to check 6, which
      only sees t/p/s/k-prefixed mixed-case spellings at USE sites: this one
      checks DECLARATION sites, any name, against the hold-em lineage's
      CURATED token set (which adds cr/lf/crlf/quote/nan/eof and friends).
      Deliberately NOT the whole RESERVED set: RESERVED's use-site entries
      are harmless-by-construction over-broad there (check 6 only tests
      prefixed mixed-case names), but at declaration sites they are live -
      and the fleet proves some are legal declared names (box2dxt's
      engine-proven Kit declares `local tV, i, a, lx, ly` in b2kCapsuleVerts,
      so `a` must not be refused). Found on holde-em's engine (gotcha 2,
      `tAb` in heByteXor).
  15. A `catch tErr` whose variable is undeclared (no handler `local`, no
      parameter, no script-level `local`/`global`) AND whose catch BODY
      references it - .livecodescript only. On strict OXT the reference
      throws a SECONDARY error at the moment the catch fires, masking the
      real failure as an opaque "error in function handler" - invisible on a
      read, because the catch only misbehaves when it actually fires
      (holde-em gotcha H8: heProbeSodium/heProbeTorrent/heDeckFromStreamKey
      all shipped it and blew up only once the sibling extensions were
      installed). The body-reference condition is the honest scope: the
      hold-em lineage flagged EVERY undeclared catch variable, but onionxt's
      capability probes (`catch tError` / `return false`, no reference) have
      FIRED on real engines - pre-ABI-7 SodiumXT made oxSodiumHasSha3's
      catch the taken path - and ran green, so binding alone is proven safe
      and only the reference is the trap.
  16. A locally-declared COMMAND (`command X` / `on X`) invoked with
      function-call syntax `X(...)` in EXPRESSION position - .livecodescript
      only. A command called as a function throws at the call site; the body
      never runs (holde-em gotcha 7: `put ... heProbeSodium() ...` died with
      "error in function handler" pointing at the call line). A command
      STATEMENT with a parenthesised first argument (`heFoo (x), y`) is legal
      and not flagged; complementary to check 8, which handles the zero-arg
      statement spelling.
  17. A parenthesised DYNAMIC property name - `the (expr) of obj` -
      .livecodescript only. Property names are compile-time tokens; the
      computed-name form is engine-shaky on OXT (holde-em gotcha H9: v0.14.0
      stored avatar paths in per-seat props named `"uHeAvatarPath" & N`).
      Hold the data in ONE property indexed by line/item instead.
  18. `the message box` used in CODE as a container - .livecodescript only.
      The container token is `msg`; the dictionary's prose name does not
      compile (holde-em gotcha 13's family: v0.17.1's report delivery threw
      at first run on `put gRpt into the message box`).
  19. A `k`-prefixed constant name used but NEVER declared in the file -
      .livecodescript only, and the other half of check 4: that one catches a
      use ABOVE its declaration, this one a use with NO `constant k... = ...`
      anywhere. LiveCodeScript evaluates the undeclared name as the literal
      text of its own name, which then flows into a hash or hex decode and
      throws far downstream (holde-em: nine kKat... names silently broke
      heTestDealRun when the deal constants were dropped from a paste).
  20. The dangling else: a single-line `if ... then <stmt>` directly followed
      by a BARE `else` line - .livecodescript only. The engine binds that
      else to the single-line if, so its `end if` closes the WRONG frame and
      the outer block-if surfaces as a baffling "missing end if" at the
      handler's end, far from the cause (the Box2Dxt lesson the hold-em
      lineage carried; block balance alone cannot see it).
  21. A backslash OUTSIDE every string literal that is not a line
      continuation - .livecodescript only. xTalk has NO string escapes, so a
      C-style `\"` ends the string at the quote and strands the rest of the
      intended text as bare tokens (a compile error); the stranded backslash
      is the reliable static tell, and it is what this flags - so the LEGAL
      `"\"` (a one-backslash string, common in path normalisation) never
      false-fires. Shipped once in holde-em's heProbeKit.
  22. A `constant` whose VALUE is not a literal - .livecodescript only.
      An xTalk constant takes a literal, not an expression, so
      `constant kX = "a" & return & "b"` does not compile. Because a
      .livecodescript is ONE compilation unit, that single line takes the
      WHOLE stack script down: no handler runs, openStack never fires, and
      the symptom is a stack that opens to a blank window with no UI and no
      error anyone can point at. This gate already knew constants have to be
      DECLARED before use (check 4) and spelled with `=` rather than `is`
      (an antipattern), and checked nothing at all about the value.
      Shipped once, in riptide-social's phase-8 relay defaults, and found
      by the maintainer opening the stack rather than by anything here.
      The same rule is why rsKdfContext() is a function: a constant cannot
      hold a NUL byte either.
      The comma split is STRING-AWARE, because the multi-declaration form
      (`constant kA = 1, kB = 2`) is legal and box2dxt's builder uses it
      thirty times WITH commas inside quoted values
      (`constant kColBtnIdle = "44,48,58", kColBtnText = "255,255,255"`) -
      splitting naively would report those as malformed.

One hold-em lineage check is deliberately NOT here, and the reason is
recorded so it is not "rediscovered": the chunk-of-an-array-element refusal
(`byte i of tA[j]`, holde-em gotcha H6). The trap is real WHERE IT WAS
OBSERVED - holde-em's seed-XOR path, chunking FFI-bridged SodiumXT Data,
where the double/binary throw persisted even after copying the element to a
local - but as a universal rule it is falsified by engine-passed code in
four members: riptide chunks `char ... of tRec["signature"]` (harness green
89/89), onionxt's httpd chunks `item ... of tOut["__resource"]` (served real
pages in Tor Browser), box2dxt chunks `byte ... of sSheetData[pSheet]` (the
Kit's sheet slicer, under every game), and nocloud's shipped receive path
chunks `byte ... of sRxBuf[pStream]`. No static scoping can see the actual
variable - whether the element holds FFI-bridged binary - and the per-file
allowlist honesty would require (15+ files) is larger than the rule is
worth. holde-em's H6 discipline (hex at the edge; chunk plain text) stays
that member's prose law.

It is a lexer-level checker, NOT a compiler: it neutralizes comments and
string contents, merges backslash continuations into logical lines, and
reasons about block keywords. It errs toward NOT raising false positives;
where a construct is ambiguous statically it is skipped.

    python3 tools/check-livecodescript.py [paths...]
    # default: scan the whole member tree (pruning .git and build dirs)

Exit code 0 = clean, 1 = problems found.
"""
import os
import re
import sys

# The four curly quotes fail OXT compilation; the dashes violate house style;
# everything else non-ASCII is off-convention and flagged generically.
BANNED_CHARS = {
    "‘": "left single curly quote (use ASCII ')",
    "’": "right single curly quote (use ASCII ')",
    "“": 'left double curly quote (use ASCII ")',
    "”": 'right double curly quote (use ASCII ")',
    "–": "en dash (use a hyphen)",
    "—": "em dash (use a hyphen)",
}

# Reserved xTalk / LCB tokens for the shadow-trap check. Only identifiers that
# start with a prefix letter (t/p/s/k) and are not written all-lowercase are
# ever tested against this set, so an over-broad entry is harmless unless a
# prefixed identifier collides with it - which is exactly the trap. This is
# the UNION of both lineages' sets; extend it when a new one is found
# on-engine, in every copy (the drift gate holds them identical).
RESERVED = {
    "a", "an", "after", "add", "and", "are", "as", "before", "begin", "boolean",
    "break", "by", "byte", "char", "character", "codepoint", "codeunit",
    "command", "constant", "continue", "data", "default", "divide", "do", "each",
    "element", "else", "empty", "end", "event", "exit", "false", "for", "foreign",
    "from", "function", "get", "getter", "global", "handler", "if", "in",
    "integer", "into", "is", "it", "item", "key", "kind", "library", "line",
    "list", "local", "me", "metadata", "module", "multiply", "next", "not",
    "nothing", "number", "of", "on", "or", "otherwise", "paragraph", "pass",
    "pointer", "private", "property", "public", "put", "real", "repeat", "result",
    "return", "sentence", "set", "setter", "sort", "string", "subtract", "target",
    "text", "the", "then", "this", "throw", "to", "token", "true", "trueword",
    "type", "unsafe", "until", "use", "value", "variable", "where", "while",
    "with", "without", "word",
    # Atomic engine tokens that START with a prefix letter - the realistic
    # traps (`tOp` lowercases to the object property `top`). Compound
    # properties like `textFont` are deliberately absent: that CamelCase is
    # how you legitimately write the property.
    "tab", "tan", "there", "time", "title", "tool", "top",
    "param", "params", "pi", "player", "point", "pow", "print",
    "script", "scroll", "second", "seconds", "seek", "selection", "send",
    "sin", "size", "space", "sqrt", "stack", "start", "stop", "style", "sum",
    "keys",
}

# The token set for the DECLARATION-site full-name check (check 14), carried
# verbatim from the hold-em lineage, which curated it to "tokens a prefixed
# variable could plausibly spell by accident". Deliberately a SEPARATE set
# from RESERVED, in both directions: widening RESERVED would change check
# 6's long-measured use-site behaviour, and reusing RESERVED here would
# refuse names the engine demonstrably accepts as declarations - RESERVED
# carries harmless-by-construction over-broad entries (`a`, `an`, `add`...)
# that check 6 can never reach (it only tests prefixed mixed-case names),
# but a declaration site reaches all of them, and box2dxt's engine-proven
# Kit declares `local tV, i, a, lx, ly` (b2kCapsuleVerts, under every game).
DECLARED_NAME_TOKENS = set("""
tab cr lf crlf return linefeed formfeed space comma colon quote backslash
slash null empty nan pi true false zero one two three four five six seven
eight nine ten up down eof it me id the end then else repeat while until for
of in is or and not to into after before put get set send exit next pass
global local constant char byte word line item token element each number
length offset result target message type name owner rect loc text top bottom
width height key value sound cursor paint sort merge param params
""".split())

# Foreign types live in com.livecode.foreign; a .lcb that names one without
# `use com.livecode.foreign` gets a "not declared" compile error.
FOREIGN_TYPES = {
    "pointer", "cbool", "cchar", "cuchar", "cschar", "cshort", "cushort",
    "cint", "cuint", "clong", "culong", "cfloat", "cdouble", "csize",
    "zstringutf8", "zstringutf16", "zstringnative", "naturalfloat", "naturaluint",
}

# LCB-only constructs that look like LiveCode Script but are NOT valid LCB.
# `the empty data` IS valid (the sibling midi.lcb uses it); the list/array
# empties are NOT - LCB wants the literals `[]` and `{}`.
LCB_ANTIPATTERNS = [
    (re.compile(r"\bthe\s+empty\s+list\b"),
     "`the empty list` is not valid LCB - use the list literal `[]`"),
    (re.compile(r"\bthe\s+empty\s+array\b"),
     "`the empty array` is not valid LCB - use the array literal `{}`"),
    # the mirror of the LCS rule below: writing the two dialects side by side
    # makes this slip natural in either direction
    (re.compile(r"^\s*constant\s+[A-Za-z_][A-Za-z0-9_]*\s*="),
     "`constant NAME = ...` is the LiveCode SCRIPT spelling - LCB declares "
     "`constant NAME is ...`"),
]

# The mirror image: LCB constructs that leak into .livecodescript. Braces have
# no meaning in LiveCode Script, and a function result cannot be subscripted
# (`f(x)["k"]` does not parse - put it into a local first). String bodies are
# blanked in cleaned lines, so braces inside literals never trip this.
LCS_ANTIPATTERNS = [
    (re.compile(r"[{}]"),
     "braces are not LiveCode Script - `{}`/`{...}` array literals are LCB-only "
     "(build arrays by assignment; count `the keys of` a variable for emptiness)"),
    (re.compile(r"\)\s*\["),
     "cannot subscript a function result in LiveCode Script - "
     "put it into a local variable first"),
    # a declaration in the WRONG dialect's spelling is worse than a syntax
    # error: the constants-before-use check only recognizes the correct
    # spelling, so the mistake is invisible to it - a fail-open this rule
    # closes (found 2026-08-13, when carried `is` constants passed the gate)
    (re.compile(r"^\s*constant\s+[A-Za-z_][A-Za-z0-9_]*\s+is\b"),
     "`constant NAME is ...` is the LiveCode BUILDER spelling - "
     "LiveCodeScript declares `constant NAME = ...` (the engine refuses the "
     "`is` form, and the before-use check cannot even see it)"),
    # `keys` is not a CHUNK, so `the number of keys of X` does not parse as a
    # count - the engine reads `keys of X` as an OBJECT expression and answers
    # "Chunk: error in object expression". Found 2026-08-18 in enet-lan-chat's
    # dashboard, once a second, and the tree carried NINE of them across three
    # demos - every one on a path no engine run had reached. The correct
    # spelling was already in use in ten other files, including three whose
    # harnesses have run green, so this is two idioms coexisting rather than
    # one unknown: the gate picks the one with evidence behind it.
    (re.compile(r"\bthe\s+number\s+of\s+keys\s+of\b"),
     "`the number of keys of X` does not parse - `keys` is not a chunk, so the "
     "engine reads `keys of X` as an object expression. Write "
     "`the number of lines of the keys of X`"),
]

# xTalk has NO `does not begin with` / `does not end with` / `does not contain`
# operator: the parser errors on `does` (confirmed on-engine in OXT). Negate
# with `not (X begins with Y)` or use `X is not ...`.
DOES_NOT_OPERATOR = re.compile(r"\bdoes\s+not\s+(begin|end|contain)s?\b",
                               re.IGNORECASE)


class Problem:
    def __init__(self, path, line, msg):
        self.path, self.line, self.msg = path, line, msg

    def __str__(self):
        return "%s:%d: %s" % (self.path, self.line, self.msg)


def find_banned_chars(path, text):
    """Flag the named troublemakers with their story, and any other non-ASCII
    byte generically: OXT source in this family is pure ASCII, even comments."""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        for col, ch in enumerate(line, 1):
            if ch in BANNED_CHARS:
                out.append(Problem(path, i,
                           "banned character at column %d: %s (U+%04X)"
                           % (col, BANNED_CHARS[ch], ord(ch))))
            elif ord(ch) > 127:
                out.append(Problem(path, i,
                           "non-ASCII character %r (U+%04X) at column %d - OXT "
                           "source must be pure ASCII; replace it"
                           % (ch, ord(ch), col)))
    return out


def clean_logical_lines(path, text, line_comment_tokens):
    """Yield (lineno, cleaned) with block comments, line comments and string
    CONTENTS neutralized, and backslash line-continuations merged. String
    bodies become spaces so keywords inside them are never seen; the
    surrounding quotes are kept so quote balance can still be checked."""
    problems = []
    raw = text.split("\n")

    # Merge backslash continuations first (a trailing '\' joins the next line).
    merged = []  # (start_lineno, text)
    i = 0
    while i < len(raw):
        start = i
        cur = raw[i]
        while cur.endswith("\\") and i + 1 < len(raw):
            cur = cur[:-1] + raw[i + 1]
            i += 1
        merged.append((start + 1, cur))
        i += 1

    in_block_comment = False
    cleaned = []
    for lineno, line in merged:
        out = []
        in_string = False
        j = 0
        n = len(line)
        while j < n:
            two = line[j:j + 2]
            if in_block_comment:
                if two == "*/":
                    in_block_comment = False
                    j += 2
                    continue
                j += 1
                continue
            if in_string:
                out.append(" " if line[j] != '"' else '"')
                if line[j] == '"':
                    in_string = False
                j += 1
                continue
            # not in string / not in block comment
            if two == "/*":
                in_block_comment = True
                j += 2
                continue
            if line[j] == '"':
                in_string = True
                out.append('"')
                j += 1
                continue
            stripped_rest = line[j:]
            hit = None
            for tok in line_comment_tokens:
                if stripped_rest.startswith(tok):
                    hit = tok
                    break
            if hit:
                break  # rest of line is a comment
            out.append(line[j])
            j += 1
        if in_string:
            problems.append(Problem(path, lineno,
                            "unterminated string literal (odd number of ASCII "
                            "double-quotes)"))
        cleaned.append((lineno, "".join(out)))
    if in_block_comment:
        problems.append(Problem(path, len(raw), "unterminated /* block comment"))
    return cleaned, problems


def tokens(s):
    return [t.lower() for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", s)]


def check_lcb_blocks(path, cleaned):
    """Block balance for LiveCode Builder. LCB has no switch; an `end switch`
    in a .lcb is caught by the unexpected-`end` catch-all."""
    problems = []
    stack = []  # (kind, lineno)
    for lineno, line in cleaned:
        s = line.strip()
        if not s:
            continue
        toks = tokens(s)
        if not toks:
            continue
        t0 = toks[0]

        # ---- closers ----
        if t0 == "end" and len(toks) >= 2:
            kind = toks[1]
            if kind in ("library", "module", "widget"):
                continue  # module-level closer (validated by check_lcb_module)
            if kind in ("handler", "if", "repeat", "unsafe"):
                if not stack:
                    problems.append(Problem(path, lineno,
                                    "`end %s` with no open block" % kind))
                else:
                    topkind, topline = stack[-1]
                    if topkind != kind:
                        problems.append(Problem(path, lineno,
                                        "`end %s` does not match `%s` opened at line %d"
                                        % (kind, topkind, topline)))
                    stack.pop()
                continue
            # `end <something else>` - in LCB only the above are valid; flag.
            problems.append(Problem(path, lineno, "unexpected `end %s`" % kind))
            continue

        # ---- openers ----
        # handler forms; foreign handler and `handler type` are single-line.
        ti = 0
        if t0 in ("public", "private"):
            ti = 1
        head = toks[ti] if ti < len(toks) else ""
        if head == "unsafe" and ti + 1 < len(toks) and toks[ti + 1] == "handler":
            stack.append(("handler", lineno))
            continue
        if head == "foreign":
            continue  # foreign handler: single line
        if head == "handler":
            if ti + 1 < len(toks) and toks[ti + 1] == "type":
                continue  # handler type declaration: single line
            stack.append(("handler", lineno))
            continue
        if t0 == "if" and s.rstrip().lower().endswith("then"):
            stack.append(("if", lineno))
            continue
        if t0 == "else":
            continue  # else / else if: continuation
        if t0 == "repeat":
            stack.append(("repeat", lineno))
            continue
        if t0 == "unsafe":  # bare `unsafe` block (not `unsafe handler`)
            stack.append(("unsafe", lineno))
            continue

    for kind, lineno in stack:
        problems.append(Problem(path, lineno,
                        "`%s` block opened here is never closed" % kind))
    return problems


def check_livecodescript_blocks(path, cleaned):
    """Block balance for LiveCode Script, switch and try included."""
    problems = []
    stack = []  # (kind, lineno)
    HANDLER_KW = ("on", "command", "function", "getprop", "setprop",
                  "before", "after")
    for lineno, line in cleaned:
        s = line.strip()
        if not s:
            continue
        toks = tokens(s)
        if not toks:
            continue
        t0 = toks[0]

        if t0 == "end" and len(toks) >= 2:
            kind = toks[1]
            if not stack:
                problems.append(Problem(path, lineno,
                                "`end %s` with no open block" % kind))
                continue
            topkind, topline = stack[-1]
            if kind in ("if", "repeat", "switch", "try"):
                if topkind != kind:
                    problems.append(Problem(path, lineno,
                                    "`end %s` does not match `%s` opened at line %d"
                                    % (kind, topkind, topline)))
                stack.pop()
            else:
                # `end <handlerName>` - must close a handler
                if topkind != "handler":
                    problems.append(Problem(path, lineno,
                                    "`end %s` does not match `%s` opened at line %d"
                                    % (kind, topkind, topline)))
                stack.pop()
            continue

        # handler openers (`private command foo` / `command foo` / `on foo` ...)
        hk = t0
        if t0 == "private" and len(toks) >= 2 and toks[1] in ("command", "function"):
            hk = toks[1]
        if hk in HANDLER_KW:
            stack.append(("handler", lineno))
            continue
        if t0 == "if" and s.rstrip().lower().endswith("then"):
            stack.append(("if", lineno))
            continue
        if t0 in ("else", "catch", "finally", "case", "default"):
            continue  # continuations, not new blocks
        if t0 == "repeat":
            stack.append(("repeat", lineno))
            continue
        if t0 == "switch":
            stack.append(("switch", lineno))
            continue
        if t0 == "try":
            stack.append(("try", lineno))
            continue

    for kind, lineno in stack:
        problems.append(Problem(path, lineno,
                        "`%s` block opened here is never closed" % kind))
    return problems


def check_constants_before_use(path, cleaned, is_script):
    """Constants must be declared before first use - OXT resolves them by
    lexical position, and a forward reference silently evaluates to nothing.
    LCS spells the declaration `constant k = ...`, LCB `constant k is ...`."""
    problems = []
    if is_script:
        decl_rx = re.compile(r"\s*constant\s+([A-Za-z_][A-Za-z0-9_]*)\s*=")
    else:
        decl_rx = re.compile(r"\s*constant\s+([A-Za-z_][A-Za-z0-9_]*)\s+is\b")
    decl_line = {}
    for lineno, line in cleaned:
        m = decl_rx.match(line)
        if m:
            decl_line.setdefault(m.group(1), lineno)
    for name, dline in decl_line.items():
        pat = re.compile(r"\b" + re.escape(name) + r"\b")
        for lineno, line in cleaned:
            if lineno >= dline:
                break
            if pat.search(line):
                problems.append(Problem(path, lineno,
                                "constant `%s` used before its declaration at "
                                "line %d (OXT resolves constants by lexical "
                                "position; this evaluates as empty)"
                                % (name, dline)))
                break
    return problems


_CONST_LITERAL_RX = re.compile(
    r'^(?:"[^"]*"|[-+]?\d+(?:\.\d+)?|true|false|empty)$', re.I)


def _split_outside_quotes(text, sep=","):
    """Split on `sep` only where it is OUTSIDE a double-quoted run.

    The multi-declaration form is legal and box2dxt's contraption builder
    uses it with commas INSIDE quoted colour triples, so a naive split
    reports thirty false positives in an engine-passed file. xTalk has no
    string escapes, so quote-toggling is the whole rule (check 21 is the
    same fact from the other side)."""
    parts, buf, instr = [], "", False
    for ch in text:
        if ch == '"':
            instr = not instr
            buf += ch
        elif ch == sep and not instr:
            parts.append(buf)
            buf = ""
        else:
            buf += ch
    parts.append(buf)
    return parts


def check_constant_values_are_literal(path, cleaned, is_script):
    """A constant's value must be a LITERAL - .livecodescript only.

    See check 22. The failure mode is what makes this worth a gate: an
    expression here is a compile error, a .livecodescript compiles as one
    unit, so the whole stack goes dark with no UI and nothing to point at."""
    problems = []
    if not is_script:
        return problems
    rx = re.compile(r"^\s*constant\s+(.+)$")
    for lineno, line in cleaned:
        m = rx.match(line)
        if not m:
            continue
        for part in _split_outside_quotes(m.group(1)):
            part = part.strip()
            if not part:
                continue
            if "=" not in part:
                # `constant NAME is ...` is caught by its own antipattern,
                # and a bare name is not this check's business either.
                continue
            name, _, value = part.partition("=")
            value = value.strip()
            if not _CONST_LITERAL_RX.match(value):
                problems.append(Problem(path, lineno,
                                "constant `%s` has a non-literal value `%s` - "
                                "an xTalk constant takes a LITERAL, not an "
                                "expression, so this does not compile; and a "
                                ".livecodescript is ONE unit, so it takes the "
                                "whole stack script down (no UI, no error to "
                                "point at). Use a function, as rsKdfContext() "
                                "does for a value a constant cannot hold"
                                % (name.strip(), value)))
    return problems


def check_declarations_at_top(path, cleaned, is_script):
    """Every LCB handler's `variable` declarations sit ABOVE its first
    statement - a nested `variable` has broken whole-LCB compilation (the
    torrentxt lesson); this is the check the house rule always claimed to
    have. .lcb ONLY, and measured before it was scoped that way: mid-handler
    `local` is legal LiveCode Script and stands at ~150 sites in
    engine-passed .livecodescript (onionxt's live-Tor-proven source above
    all), so applying it there would manufacture violations in the family's
    most-proven files. `constant`/`global` are not flagged either - only the
    declaration form observed to break compilation."""
    problems = []
    if is_script:
        return problems
    decl_words = ("variable",)
    decl_name = "a `variable`"
    nested = ("if", "repeat", "switch", "try", "unsafe")
    in_handler = False
    body_started = False
    depth = 0
    for lineno, line in cleaned:
        s = line.strip()
        if not s:
            continue
        toks = tokens(s)
        if not toks:
            continue
        t0 = toks[0]
        if not in_handler:
            hk = t0
            ti = 0
            if t0 in ("public", "private") and len(toks) >= 2:
                hk = toks[1]
                ti = 1
            if hk == "handler" and not (ti + 1 < len(toks) and
                                        toks[ti + 1] == "type"):
                in_handler = True
                body_started = False
                depth = 0
            elif hk == "unsafe" and ti + 1 < len(toks) and \
                    toks[ti + 1] == "handler":
                in_handler = True
                body_started = False
                depth = 0
            continue
        # inside a handler: track nested block depth so `end if` does not
        # read as the handler's own closer
        if t0 == "end" and len(toks) >= 2 and toks[1] in nested:
            depth = max(depth - 1, 0)
            body_started = True
            continue
        if t0 == "end":
            if depth == 0:
                in_handler = False
            continue
        if t0 in decl_words:
            if body_started:
                problems.append(Problem(path, lineno,
                                "%s declared below the handler's first "
                                "statement - declarations go at the TOP of the "
                                "handler (a nested declaration has broken "
                                "whole-script compilation)" % decl_name))
            continue
        if t0 in nested:
            if t0 == "if" and not s.rstrip().lower().endswith("then"):
                pass  # single-line if: no block opened
            else:
                depth += 1
        body_started = True
    return problems


def check_shadow_trap(path, cleaned):
    """Flag a t/p/s/k-prefixed name (any mixed-case spelling) that lowercases
    to a reserved token - e.g. `tExt` -> `text`. Both dialects: the shadowing
    is an xTalk evaluation rule, not a dialect quirk."""
    problems = []
    seen = set()
    for lineno, line in cleaned:
        for ident in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", line):
            if ident[0] not in "tpsk":
                continue
            if ident == ident.lower():
                continue  # a bare lowercase keyword, not a prefixed name
            low = ident.lower()
            if low in RESERVED and ident not in seen:
                seen.add(ident)
                problems.append(Problem(path, lineno,
                                "name `%s` lowercases to the reserved token "
                                "`%s` - xTalk evaluates it as that keyword, not "
                                "a variable; rename it with a distinctive, "
                                "multi-word stem (e.g. tExt -> tSuffix)"
                                % (ident, low)))
    return problems


def check_does_not_operator(path, cleaned):
    problems = []
    for lineno, line in cleaned:
        if DOES_NOT_OPERATOR.search(line):
            problems.append(Problem(path, lineno,
                            "`does not begin/end with` / `does not contain` is "
                            "not a valid xTalk operator - the parser errors on "
                            "`does`; negate with `not (...)`, e.g. "
                            "`not (X begins with Y)`, or use `X is not ...`"))
    return problems


def check_put_prepositions(path, cleaned):
    """A `put` takes `into` OR `after`/`before`, never both. `put X into Y
    after Y` is malformed: the engine rejects the stray preposition. Runs on
    cleaned lines, so a literal 'after'/'into' inside a string never trips."""
    problems = []
    for lineno, line in cleaned:
        m = re.match(r"\s*(?:then\s+)?put\b(.*)", line)
        if not m:
            continue
        rest = m.group(1)
        if re.search(r"\binto\b", rest) and re.search(r"\b(?:after|before)\b", rest):
            problems.append(Problem(path, lineno,
                            "a `put` uses both `into` and `after`/`before`; "
                            "use one (`put X into Y` to replace, or "
                            "`put X after Y` to append)"))
    return problems


def check_lcb_module(path, cleaned):
    """A library/module/widget must be explicitly closed with the matching
    `end library`/`end module`/`end widget`; OXT otherwise consumes the whole
    file looking for the closer and reports a syntax error at end-of-file."""
    problems = []
    opener = None  # (kind, lineno)
    closed = False
    for lineno, line in cleaned:
        if opener is None:
            mo = re.match(r"\s*(library|module|widget)\s+[A-Za-z_][\w.]*", line)
            if mo:
                opener = (mo.group(1), lineno)
                continue
        mc = re.match(r"\s*end\s+(library|module|widget)\b", line)
        if mc:
            closed = True
            if opener and mc.group(1) != opener[0]:
                problems.append(Problem(path, lineno,
                                "`end %s` does not match the opening `%s`"
                                % (mc.group(1), opener[0])))
    if opener and not closed:
        problems.append(Problem(path, opener[1],
                        "`%s` opened here is never closed - add `end %s` at the "
                        "very end of the file (OXT reports a syntax error at "
                        "end-of-file otherwise)" % (opener[0], opener[0])))
    return problems


def check_lcb_imports(path, cleaned):
    """A foreign type without `use com.livecode.foreign` is a "not declared"
    compile error; textEncode/textDecode are LCS-only and fail in a module."""
    problems = []
    used = set()
    type_hit = None
    text_hits = []
    for lineno, line in cleaned:
        m = re.match(r"\s*use\s+([A-Za-z0-9_.]+)", line)
        if m:
            used.add(m.group(1))
            continue
        for ident in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", line):
            low = ident.lower()
            if type_hit is None and low in FOREIGN_TYPES:
                type_hit = (lineno, ident)
            if ident in ("textEncode", "textDecode"):
                text_hits.append((lineno, ident))
    if type_hit is not None and "com.livecode.foreign" not in used:
        problems.append(Problem(path, type_hit[0],
                        "foreign type `%s` used but `use com.livecode.foreign` "
                        "is missing (it will not be declared on an OXT compile)"
                        % type_hit[1]))
    for lineno, ident in text_hits:
        problems.append(Problem(path, lineno,
                        "`%s` is a LiveCode Script function, not available to "
                        "an LCB module; keep text<->Data conversion in script "
                        "or pass Data" % ident))
    return problems


def check_lcb_antipatterns(path, cleaned):
    problems = []
    for lineno, line in cleaned:
        for pat, msg in LCB_ANTIPATTERNS:
            if pat.search(line):
                problems.append(Problem(path, lineno, msg))
    return problems


def check_lcs_antipatterns(path, cleaned):
    problems = []
    for lineno, line in cleaned:
        for pat, msg in LCS_ANTIPATTERNS:
            if pat.search(line):
                problems.append(Problem(path, lineno, msg))
    return problems


def check_lcb_lowercase_names(path, cleaned):
    """OXT warns that all-lowercase identifiers may become reserved words. The
    naming convention prefixes every name (t/p/s/k + CamelCase), so an
    all-lowercase `variable` declaration is a convention break AND a risk."""
    problems = []
    pat = re.compile(r"\bvariable\s+([a-z][a-z0-9_]*)\s+as\b")
    for lineno, line in cleaned:
        m = pat.search(line)
        if m:
            name = m.group(1)
            problems.append(Problem(path, lineno,
                            "all-lowercase variable name `%s` - OXT warns it "
                            "may cause a future syntax error; use a prefixed "
                            "CamelCase name (e.g. t%s)"
                            % (name, name.capitalize())))
    return problems


def check_zero_arg_statement_calls(path, text):
    """A zero-argument call written `foo()` in STATEMENT position.

    LiveCodeScript has no "call a function and discard the result" statement.
    A line that starts with an identifier is parsed as a COMMAND, and whatever
    follows is its argument list - so `dcCleanup()` asks the engine to pass the
    expression `()` to the command `dcCleanup`, and `()` is not an expression.
    It is a compile error, and because a .livecodescript compiles as one unit it
    takes the WHOLE FILE with it, usually reported at some unrelated line.

    Three things make this worth a gate rather than a lesson in a header:

      - The one-argument spelling `dcFreePeer(sPeerA)` is FINE, because `(sPeerA)`
        IS an expression. So the broken form looks exactly like the working one
        that sits next to it, and reading the file does not distinguish them.
      - In EXPRESSION position `dcCleanup() is 0` is correct and required. Same
        eight characters, opposite verdicts, decided by what is to the left.
      - This is LiveCodeScript only. LiveCode BUILDER allows `sPrepare()` as a
        statement, and both sodium.lcb and coinxt.lcb use it hundreds of times
        on paths that have run green on a real engine. Flagging .lcb here would
        be ~90 false positives and would get the whole rule switched off.

    Found the hard way: the suite self-test failed on an engine at
    `dcCleanup()`, folded in from datachannelxt's harness. Three of the four
    sites had a working bare call within a few lines of them.
    """
    if path.endswith(".lcb"):
        return []
    out, continued = [], False
    for lineno, raw in enumerate(text.split("\n"), start=1):
        line = raw.split("--", 1)[0] if '"' not in raw.split("--", 1)[0] else raw
        stripped = line.strip()
        # A continuation line is part of the PREVIOUS statement, so an
        # identifier + () there is an ordinary call inside an expression.
        was_continued, continued = continued, stripped.endswith("\\")
        if was_continued or not stripped:
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)$", stripped)
        if m:
            out.append((lineno, m.group(1)))
    return out


def check_engine_hostile_constructs(path, text):
    """Two constructs that COMPILE, RUN, and silently do the wrong thing on OXT.

    Both were found the same way: by an operator at an engine, after every gate
    in the repo had gone green. Both had exactly ONE occurrence in the whole
    six-member suite, which is why neither had ever been in front of an engine -
    and that rarity is the point. A construct nobody else uses is a construct
    nobody else has proved.

    1. `repeat with i = A to B step N`. The increment was not honoured: i walked
       one at a time. In cxHexDecode that made the last pass read one character
       past the pairs, get empty, and throw "not a hex digit" over VALID input -
       the library accusing the caller's data of being corrupt, in the exact
       words it reserves for real corruption. Use `repeat while` with an
       explicit `add N to i`, which is what every other loop in the family does.

    2. `throw` from INSIDE a `catch` block. The error does not reach the caller;
       the handler falls through and returns whatever its result variable holds,
       which is usually empty. Nine itemDelimiter guards did this, and one of
       them was cxMnemonicValidate, whose Inner reaches `return false` only via
       its own catch - so a mistyped seed phrase was reported VALID. Capture the
       error in a local, close the try, then throw after `end try`.
       NOTE `return` inside a catch is FINE and engine-proven (onionxt's
       oxSodiumHasSha3 does it on a path this same run exercised); only `throw`
       is affected, so this checks only `throw`.

    LiveCodeScript only. LiveCode Builder is a different language and its .lcb
    files are not scanned here.
    """
    if path.endswith(".lcb"):
        return []
    out, in_catch, depth = [], False, 0
    for lineno, raw in enumerate(text.split("\n"), start=1):
        line = raw.split("--", 1)[0].strip() if '"' not in raw.split("--", 1)[0] else raw.strip()
        low = line.lower()
        if re.match(r"^repeat\s+with\s+\w+\s*=.*\bstep\b", low):
            out.append((lineno, "step"))
        if re.match(r"^try\b", low):
            depth += 1
        elif re.match(r"^catch\b", low) and depth > 0:
            in_catch = True
        elif re.match(r"^end\s+try\b", low):
            depth -= 1
            if depth <= 0:
                in_catch, depth = False, max(depth, 0)
        elif in_catch and re.match(r"^throw\b", low):
            out.append((lineno, "throw-in-catch"))
    return out


# --- the hold-em lineage checks (13-21), absorbed 2026-08-15 -----------------
# All of them run on the CLEANED logical lines (comments stripped, string
# interiors blanked, continuations merged), and all are .livecodescript only:
# the traps are xTalk evaluation/parse rules, and LCB is a different language
# (it even has real string escapes, which would falsify check 21 there).

LCS_HANDLER_KW = ("on", "command", "function", "getprop", "setprop",
                  "before", "after")

BITWISE_FN_CALL = re.compile(r"\b(bitXor|bitAnd|bitOr|bitNot)\s*\(",
                             re.IGNORECASE)
CATCH_VAR = re.compile(r"\bcatch\s+([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)
CALL_PAREN = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
DYNAMIC_PROP = re.compile(r"\bthe\s*\(", re.IGNORECASE)
MSGBOX_PROSE = re.compile(r"\bthe\s+message\s+box\b", re.IGNORECASE)
K_CONST_DECL_LCS = re.compile(r"^\s*constant\s+(k[A-Za-z0-9_]+)\s*=")
K_CONST_USE = re.compile(r"\b(k[A-Z][A-Za-z0-9_]*)\b")
SINGLE_LINE_IF = re.compile(r"^if\b.+\bthen\s+\S", re.IGNORECASE)


def lcs_handler_decl(s):
    """Parse a LiveCodeScript handler-opener line: return (kind, name,
    params_text) or None. `private command foo pA` is a decl; `end foo` is
    not (callers filter `end` before asking)."""
    toks = s.split()
    if not toks:
        return None
    i = 0
    if toks[0].lower() == "private" and len(toks) >= 2 and \
            toks[1].lower() in ("command", "function"):
        i = 1
    if i >= len(toks) or toks[i].lower() not in LCS_HANDLER_KW:
        return None
    if i + 1 >= len(toks):
        return None
    kind = toks[i].lower()
    name = toks[i + 1]
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
        return None
    parts = s.split(None, i + 2)
    params = parts[i + 2] if len(parts) > i + 2 else ""
    return kind, name, params


def decl_names(text):
    """The names declared by a comma-separated `local`/param list. Splits off
    reference markers (@), initializers (=) and array subscripts."""
    out = []
    for part in text.split(","):
        name = part.strip().lstrip("@").split("=")[0].split("[")[0].strip()
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
            out.append(name)
    return out


def check_bitwise_function_calls(path, cleaned):
    """`bitXor(a, b)` - the operator written as a two-argument function call.
    Refused only when the paren group carries a TOP-LEVEL comma: an operator's
    parenthesised right operand (`tBits bitOr (tL)`, `tM bitAnd (bitNot n)`)
    can never contain one, so the engine-passed operator forms across the
    fleet stay legal and the exact shape of holde-em's shipped defect fires."""
    problems = []
    for lineno, line in cleaned:
        for m in BITWISE_FN_CALL.finditer(line):
            depth = 0
            arg_comma = False
            for ch in line[m.end() - 1:]:
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        break
                elif ch == "," and depth == 1:
                    arg_comma = True
                    break
            if arg_comma:
                problems.append(Problem(path, lineno,
                                "`%s(a, b)` calls the bitwise OPERATOR as a "
                                "function - not xTalk; write the operator "
                                "form `a %s b` (holde-em's seed-XOR path "
                                "shipped this and threw double/binary at "
                                "runtime)" % (m.group(1), m.group(1))))
    return problems


def check_declared_name_tokens(path, cleaned):
    """A declared local or handler parameter whose FULL name IS an engine
    token, any case (`tAb` == the `tab` constant). Declaration sites only:
    a use site cannot distinguish the variable from the token, which is
    exactly why the engine silently reads the token."""
    problems = []
    vocab = DECLARED_NAME_TOKENS
    for lineno, line in cleaned:
        s = line.strip()
        toks = s.split()
        if not toks:
            continue
        first = toks[0].lower()
        if first == "local":
            decl = s[len(toks[0]):]
        else:
            hd = lcs_handler_decl(s)
            if hd is None:
                continue
            decl = hd[2]
        for name in decl_names(decl):
            if name.lower() in vocab:
                problems.append(Problem(path, lineno,
                                "declared name `%s` IS the engine token "
                                "`%s` - xTalk evaluates it as that token, "
                                "not a variable; rename it with a "
                                "distinctive stem (holde-em's tAb -> tWorkA)"
                                % (name, name.lower())))
    return problems


def check_catch_declared(path, cleaned):
    """`catch tErr` where tErr is undeclared AND the catch body references
    it. On strict OXT the reference throws a SECONDARY error the moment the
    catch fires, masking the real failure - invisible until the try body
    actually throws, which is why three holde-em probes shipped it. Binding
    alone (an undeclared catch variable the body never reads) is
    engine-proven safe - onionxt's capability probes took exactly that path
    on real engines - so only the reference is flagged.

    Two passes: declarations first (a handler's `local` is a compile-time
    declaration wherever it sits, and mid-handler `local` is legal LCS, so
    a single pass would miss a declaration below the try), then the
    try/catch walk with a frame per open catch so nested tries resolve."""
    # pass 1: script-level names, and each handler's declared names by span
    script_names = set()
    spans = []  # (start_index, end_index_exclusive, declared_set)
    handler_start = None
    declared = set()
    for idx, (lineno, line) in enumerate(cleaned):
        s = line.strip()
        toks = s.split()
        if not toks:
            continue
        t0 = toks[0].lower()
        if handler_start is None:
            hd = lcs_handler_decl(s)
            if hd is not None:
                handler_start = idx
                declared = set(n.lower() for n in decl_names(hd[2]))
                continue
            if t0 in ("local", "global"):
                for n in decl_names(s[len(toks[0]):]):
                    script_names.add(n.lower())
            continue
        if t0 == "end" and len(toks) >= 2 and \
                toks[1].lower() not in ("if", "repeat", "switch", "try"):
            spans.append((handler_start, idx + 1, declared))
            handler_start = None
            declared = set()
            continue
        if t0 in ("local", "global"):
            for n in decl_names(s[len(toks[0]):]):
                declared.add(n.lower())
    if handler_start is not None:
        spans.append((handler_start, len(cleaned), declared))

    # pass 2: walk each handler's try/catch structure
    problems = []
    for start, end, declared in spans:
        hd = lcs_handler_decl(cleaned[start][1].strip())
        hname = hd[1] if hd else "?"
        depth = 0
        frames = []  # open catches: (var, catch_lineno, try_depth)
        for lineno, line in cleaned[start + 1:end]:
            s = line.strip()
            toks = s.split()
            if not toks:
                continue
            t0 = toks[0].lower()
            if t0 == "try":
                depth += 1
                continue
            if t0 == "end" and len(toks) >= 2 and toks[1].lower() == "try":
                frames = [f for f in frames if f[2] < depth]
                depth = max(depth - 1, 0)
                continue
            if t0 == "catch":
                frames = [f for f in frames if f[2] != depth]
                m = CATCH_VAR.match(s)
                if m and depth > 0:
                    var = m.group(1)
                    if var.lower() not in declared and \
                            var.lower() not in script_names:
                        frames.append((var, lineno, depth))
                continue
            for var, cline, _ in frames:
                if re.search(r"\b%s\b" % re.escape(var), s, re.IGNORECASE):
                    problems.append(Problem(path, lineno,
                                    "catch variable `%s` (caught at line %d "
                                    "in handler `%s`) is referenced here but "
                                    "never declared - on strict OXT the "
                                    "reference throws a second error when "
                                    "the catch fires, masking the real "
                                    "failure; declare it (`local %s`)"
                                    % (var, cline, hname, var)))
                    frames = [f for f in frames if f[0] != var]
                    break
    return problems


def check_command_paren_calls(path, cleaned):
    """A locally-declared COMMAND invoked with function-call syntax in
    EXPRESSION position (`put ... heProbeSodium() ...`). The engine throws at
    the call site and the body never runs. The leading-token position is
    skipped because a command STATEMENT with a parenthesised first argument
    (`heFoo (x), y`) is legal; only a command name with real text before it
    is unmistakably inside an expression."""
    commands = set()
    functions = set()
    for _, line in cleaned:
        hd = lcs_handler_decl(line.strip())
        if hd is None:
            continue
        if hd[0] == "function":
            functions.add(hd[1].lower())
        elif hd[0] in ("command", "on"):
            commands.add(hd[1].lower())
    suspect = commands - functions
    problems = []
    if not suspect:
        return problems
    for lineno, line in cleaned:
        s = line.strip()
        if lcs_handler_decl(s) is not None:
            continue
        for m in CALL_PAREN.finditer(s):
            if m.group(1).lower() not in suspect:
                continue
            before = s[:m.start()].strip()
            if before == "" or before.split()[-1].lower() in ("then", "else"):
                continue
            problems.append(Problem(path, lineno,
                            "command `%s` is called with function-call "
                            "syntax `%s(...)` inside an expression - a "
                            "command called as a function throws at the "
                            "call site (call it as a statement, or make it "
                            "a function)" % (m.group(1), m.group(1))))
    return problems


def check_dynamic_property_names(path, cleaned):
    problems = []
    for lineno, line in cleaned:
        if DYNAMIC_PROP.search(line):
            problems.append(Problem(path, lineno,
                            "parenthesised dynamic property name (`the "
                            "(expr) of ...`) - property names are "
                            "compile-time tokens and the computed form is "
                            "engine-shaky on OXT; hold the data in ONE "
                            "property indexed by line/item instead"))
    return problems


def check_message_box_prose(path, cleaned):
    problems = []
    for lineno, line in cleaned:
        if MSGBOX_PROSE.search(line):
            problems.append(Problem(path, lineno,
                            "`the message box` is dictionary prose, not a "
                            "container - the container token is `msg` "
                            "(`put x into msg`); the prose form throws at "
                            "runtime on OXT"))
    return problems


def check_undeclared_k_constants(path, cleaned):
    """A k-prefixed constant name with NO `constant k... = ...` declaration
    anywhere in the file. LiveCodeScript evaluates the undeclared name as the
    literal text of its own name and the failure surfaces far downstream.
    Only names whose second character is UPPERCASE are treated as intended
    constants (`kFoo` yes, `keyDown` no), matching the family convention.
    A `constant` line may declare several comma-separated constants
    (`constant kA = 1, kB = 2` - box2dxt's builder does this throughout),
    so every `k... =` pair on a declaration line declares its name."""
    declared = set()
    for _, line in cleaned:
        if K_CONST_DECL_LCS.match(line):
            for name in re.findall(r"\b(k[A-Za-z0-9_]+)\s*=", line):
                declared.add(name)
    problems = []
    seen = set()
    for lineno, line in cleaned:
        for name in K_CONST_USE.findall(line):
            if name not in declared and name not in seen:
                seen.add(name)
                problems.append(Problem(path, lineno,
                                "constant `%s` is used but never declared - "
                                "LiveCodeScript evaluates it as the literal "
                                "text %r and the failure surfaces far "
                                "downstream; add `constant %s = ...` (or "
                                "complete the paste that carried it)"
                                % (name, name, name)))
    return problems


def check_dangling_else(path, cleaned):
    """A single-line `if ... then <stmt>` directly followed by a BARE `else`:
    the else binds to the single-line if, its `end if` closes the wrong
    frame, and the outer block-if surfaces as a baffling "missing end if" at
    the handler's end. Blank (and comment-only) lines between the two do not
    change the binding, so they are skipped."""
    problems = []
    prev = None  # (lineno, stripped) of the last non-blank line
    for lineno, line in cleaned:
        s = line.strip()
        if not s:
            continue
        if prev is not None and s.lower() == "else":
            plow = prev[1]
            if SINGLE_LINE_IF.match(plow) and not plow.lower().endswith("then"):
                problems.append(Problem(path, lineno,
                                "bare `else` after the single-line `if ... "
                                "then <stmt>` at line %d - the engine binds "
                                "this else to the single-line if, so its "
                                "`end if` closes the wrong block; make that "
                                "if block-form (or put a statement on the "
                                "else line)" % prev[0]))
        prev = (lineno, s)
    return problems


def check_stray_backslash(path, cleaned):
    """A backslash outside every string literal. Cleaned lines have string
    interiors blanked and continuations merged, so any surviving backslash
    is stranded code - almost always a C-style `\\"` escape attempt (xTalk
    has no string escapes: the quote ENDS the string and the rest becomes
    bare tokens), occasionally a continuation with trailing whitespace. The
    legal one-backslash string `"\\"` never reaches this check."""
    problems = []
    for lineno, line in cleaned:
        if "\\" in line:
            problems.append(Problem(path, lineno,
                            "backslash outside a string literal - xTalk has "
                            "no string escapes, so a `\\\"` ends the string "
                            "at the quote and strands the rest as bare "
                            "tokens; build a literal quote with the `quote` "
                            "constant, concatenated"))
    return problems


def check_file(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        return [Problem(path, 0, "not valid UTF-8: %s" % e)]

    problems = []
    problems += find_banned_chars(path, text)
    for lineno, kind in check_engine_hostile_constructs(path, text):
        problems.append(Problem(path, lineno, "%s" % ("a `repeat with ... step N` loop does not honour its increment on OXT; use `repeat while` with an explicit `add N to` (see cxHexDecode)" if kind == "step" else "a `throw` inside a `catch` block does not reach the caller on OXT; capture the error, close the try, and throw after `end try` (see the guards in coinxt.livecodescript)")))
    for lineno, name in check_zero_arg_statement_calls(path, text):
        problems.append(Problem(path, lineno, "a zero-argument call written %s() in statement position does not compile in LiveCodeScript (the engine parses `()` as the command's argument, and `()` is not an expression). Write it bare: %s" % (name, name)))

    is_script = not path.endswith(".lcb")
    # LCS accepts --, #, and // line comments; LCB accepts -- and /* */.
    line_comment_tokens = ["--", "#", "//"] if is_script else ["--"]
    cleaned, cprob = clean_logical_lines(path, text, line_comment_tokens)
    problems += cprob

    if is_script:
        problems += check_livecodescript_blocks(path, cleaned)
        problems += check_lcs_antipatterns(path, cleaned)
        # the hold-em lineage checks (13-21) - .livecodescript only
        problems += check_bitwise_function_calls(path, cleaned)
        problems += check_declared_name_tokens(path, cleaned)
        problems += check_catch_declared(path, cleaned)
        problems += check_command_paren_calls(path, cleaned)
        problems += check_dynamic_property_names(path, cleaned)
        problems += check_message_box_prose(path, cleaned)
        problems += check_undeclared_k_constants(path, cleaned)
        problems += check_dangling_else(path, cleaned)
        problems += check_stray_backslash(path, cleaned)
    else:
        problems += check_lcb_module(path, cleaned)
        problems += check_lcb_blocks(path, cleaned)
        problems += check_lcb_antipatterns(path, cleaned)
        problems += check_lcb_lowercase_names(path, cleaned)
        problems += check_lcb_imports(path, cleaned)
    # rules that hold in both dialects
    problems += check_constants_before_use(path, cleaned, is_script)
    problems += check_constant_values_are_literal(path, cleaned, is_script)
    problems += check_declarations_at_top(path, cleaned, is_script)
    problems += check_shadow_trap(path, cleaned)
    problems += check_does_not_operator(path, cleaned)
    problems += check_put_prepositions(path, cleaned)
    return problems


def discover(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d != ".git" and not d.startswith("build")
                       and d != "_deps" and d != "node_modules"]
        for name in filenames:
            if name.endswith(".lcb") or name.endswith(".livecodescript"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def gather(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files.extend(discover(p))
        elif p.endswith(".lcb") or p.endswith(".livecodescript"):
            files.append(p)
    return sorted(set(files))


def main(argv):
    targets = gather(argv[1:]) if len(argv) > 1 else discover(".")
    if not targets:
        print("check-livecodescript: no .lcb or .livecodescript files found")
        return 0

    all_problems = []
    for path in targets:
        all_problems += check_file(path)

    if all_problems:
        for p in sorted(all_problems, key=lambda x: (x.path, x.line)):
            print(p)
        print("\ncheck-livecodescript: %d problem(s) in %d file(s)"
              % (len(all_problems), len(targets)))
        return 1

    print("check-livecodescript: OK (%d file(s) checked)" % len(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
