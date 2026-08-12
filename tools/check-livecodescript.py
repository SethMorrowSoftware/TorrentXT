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
lineages. Do not edit one copy: edit every member's copy identically (they are
the same bytes), and the suite gate tools/check-checker-drift.py FAILS the
build if any copy differs from the others, so a fix applied to one member can
no longer silently miss the suite. tools/test-checker.py at the suite root
holds the fixture tests for every rule here; extend it in the same change as
any new rule.

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
      LCB `constant k is ...`; both shapes are checked.
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
    else:
        problems += check_lcb_module(path, cleaned)
        problems += check_lcb_blocks(path, cleaned)
        problems += check_lcb_antipatterns(path, cleaned)
        problems += check_lcb_lowercase_names(path, cleaned)
        problems += check_lcb_imports(path, cleaned)
    # rules that hold in both dialects
    problems += check_constants_before_use(path, cleaned, is_script)
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
