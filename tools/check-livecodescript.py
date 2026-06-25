#!/usr/bin/env python3
"""check-livecodescript.py - the static gate for the script layer (plan §8.4).

OXT is a GUI runtime: there is NO headless way to compile or run .lcb /
.livecodescript. So we catch what is statically catchable and let the human do
the OXT pass for the rest. This checker enforces, across every .lcb and example:

  1. No smart / curly quotes anywhere (U+2018/2019/201C/201D) - even in a
     comment or string they fail OXT compilation. ASCII " and ' only.
  2. Balanced strings (no stray unterminated " on a logical line).
  3. Balanced blocks: handler/if/repeat (+ unsafe in .lcb; switch/try in
     .livecodescript), matched by kind, with line numbers on mismatch.
  4. Every `unsafe ... end unsafe` bracket balanced (.lcb) - every foreign call
     must be wrapped.
  5. Constants declared before first use (.lcb) - OXT resolves constants by
     lexical position; a forward reference silently evaluates to nothing.

It is a lexer-level checker, NOT a compiler: it neutralizes comments and strings
and reasons about block keywords. It errs toward NOT raising false positives;
where a construct is ambiguous statically it is skipped (documented inline).

    python3 tools/check-livecodescript.py [paths...]    # default: scan repo

Exit code 0 = clean, 1 = problems found.
"""
import os
import re
import sys

SMART_QUOTES = {
    "‘": "LEFT SINGLE QUOTE",
    "’": "RIGHT SINGLE QUOTE",
    "“": "LEFT DOUBLE QUOTE",
    "”": "RIGHT DOUBLE QUOTE",
}


class Problem:
    def __init__(self, path, line, msg):
        self.path, self.line, self.msg = path, line, msg

    def __str__(self):
        return "%s:%d: %s" % (self.path, self.line, self.msg)


def find_smart_quotes(path, text):
    """Flag any non-ASCII byte. Smart quotes (the common case) fail OXT
    compilation outright; the broader rule is that OXT source is pure ASCII -
    the proven sibling extensions contain zero non-ASCII bytes - so even a stray
    en-dash or section sign in a comment is off-convention and is reported."""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        for col, ch in enumerate(line, 1):
            if ch in SMART_QUOTES:
                out.append(Problem(path, i,
                           "smart quote %s (U+%04X) at col %d - OXT rejects it; use ASCII"
                           % (SMART_QUOTES[ch], ord(ch), col)))
            elif ord(ch) > 127:
                out.append(Problem(path, i,
                           "non-ASCII character %r (U+%04X) at col %d - OXT source "
                           "must be pure ASCII; replace it" % (ch, ord(ch), col)))
    return out


def clean_logical_lines(path, text, line_comment_tokens):
    """Yield (lineno, cleaned) with block comments, line comments and string
    *contents* neutralized, and backslash line-continuations merged. String
    bodies become spaces so keywords inside them are never seen; the surrounding
    quotes are kept so quote-balance can still be checked.
    """
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
            # not in string/comment
            if two == "/*":
                in_block_comment = True
                j += 2
                continue
            if line[j] == '"':
                in_string = True
                out.append('"')
                j += 1
                continue
            # line comment tokens
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
                            "unterminated string literal (odd number of ASCII double-quotes)"))
        cleaned.append((lineno, "".join(out)))
    if in_block_comment:
        problems.append(Problem(path, len(raw), "unterminated /* block comment"))
    return cleaned, problems


def first_token(s):
    m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", s)
    return m.group(1).lower() if m else ""


def tokens(s):
    return [t.lower() for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", s)]


def check_lcb_blocks(path, cleaned):
    """Block balance for LiveCode Builder."""
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
            if kind in ("handler", "if", "repeat", "unsafe", "foreach"):
                want = "foreach" if kind == "foreach" else kind
                if not stack:
                    problems.append(Problem(path, lineno, "`end %s` with no open block" % kind))
                else:
                    topkind, topline = stack[-1]
                    if topkind != want and not (kind == "repeat" and topkind == "repeat"):
                        problems.append(Problem(path, lineno,
                                        "`end %s` does not match `%s` opened at line %d"
                                        % (kind, topkind, topline)))
                        stack.pop()
                    else:
                        stack.pop()
                continue
            # `end <something else>` - in LCB only the above are valid; flag.
            problems.append(Problem(path, lineno, "unexpected `end %s`" % kind))
            continue

        # ---- openers ----
        # handler forms; foreign handler and `handler type` are single-line, no body.
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
        if t0 in ("else",):
            continue  # else / else if: continuation
        if t0 == "repeat":
            stack.append(("repeat", lineno))
            continue
        if t0 == "unsafe":  # bare `unsafe` block (not `unsafe handler`)
            stack.append(("unsafe", lineno))
            continue

    for kind, lineno in stack:
        problems.append(Problem(path, lineno, "`%s` block opened here is never closed" % kind))
    return problems


def check_livecodescript_blocks(path, cleaned):
    """Block balance for LiveCode Script (.livecodescript)."""
    problems = []
    stack = []  # (kind, name, lineno)
    HANDLER_KW = ("on", "command", "function", "getprop", "setprop", "before", "after", "private")
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
                problems.append(Problem(path, lineno, "`end %s` with no open block" % kind))
                continue
            topkind, topname, topline = stack[-1]
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

        # handler openers
        hk = t0
        nameidx = 1
        if t0 == "private" and len(toks) >= 2 and toks[1] in ("command", "function"):
            hk = toks[1]
            nameidx = 2
        if hk in HANDLER_KW and hk not in ("private",):
            name = toks[nameidx] if nameidx < len(toks) else ""
            stack.append(("handler", name, lineno))
            continue
        if t0 == "if" and s.rstrip().lower().endswith("then"):
            stack.append(("if", "", lineno))
            continue
        if t0 == "else":
            continue
        if t0 == "repeat":
            stack.append(("repeat", "", lineno))
            continue
        if t0 == "switch":
            stack.append(("switch", "", lineno))
            continue
        if t0 == "try":
            stack.append(("try", "", lineno))
            continue

    for kind, name, lineno in stack:
        problems.append(Problem(path, lineno, "`%s` block opened here is never closed" % kind))
    return problems


def check_lcb_constants(path, cleaned):
    """Constants must be declared before first use (OXT resolves by position)."""
    problems = []
    decl_line = {}
    for lineno, line in cleaned:
        m = re.match(r"\s*constant\s+([A-Za-z_][A-Za-z0-9_]*)\s+is\b", line)
        if m:
            name = m.group(1)
            if name not in decl_line:
                decl_line[name] = lineno
    # find first use of each declared constant
    for name, dline in decl_line.items():
        pat = re.compile(r"\b" + re.escape(name) + r"\b")
        for lineno, line in cleaned:
            # skip the declaration line itself
            if lineno == dline:
                continue
            if pat.search(line):
                if lineno < dline:
                    problems.append(Problem(path, lineno,
                                    "constant `%s` used before its declaration at line %d "
                                    "(OXT would evaluate it as empty)" % (name, dline)))
                break
    return problems


# LCB-only constructs that look like LiveCode Script but are NOT valid LCB.
# `the empty data` IS valid (used in the sibling midi.lcb); the list/array empties
# are NOT - LCB requires the literals `[]` and `{}` (confirmed against the LCB
# Language Reference). This catches the class locally so it never reaches an OXT
# compile again.
LCB_ANTIPATTERNS = [
    (re.compile(r"\bthe\s+empty\s+list\b"),
     "`the empty list` is not valid LCB - use the list literal `[]`"),
    (re.compile(r"\bthe\s+empty\s+array\b"),
     "`the empty array` is not valid LCB - use the array literal `{}`"),
]


def check_lcb_antipatterns(path, cleaned):
    problems = []
    for lineno, line in cleaned:
        for pat, msg in LCB_ANTIPATTERNS:
            if pat.search(line):
                problems.append(Problem(path, lineno, msg))
    return problems


def check_lcb_module(path, cleaned):
    """A library/module/widget must be explicitly closed with the matching
    `end library`/`end module`/`end widget`. OXT otherwise consumes the whole
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
                    "`end %s` does not match the opening `%s`" % (mc.group(1), opener[0])))
    if opener and not closed:
        problems.append(Problem(path, opener[1],
            "`%s` opened here is never closed - add `end %s` at the very end of "
            "the file (OXT reports a syntax error at end-of-file otherwise)"
            % (opener[0], opener[0])))
    return problems


def check_file(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        return [Problem(path, 0, "not valid UTF-8: %s" % e)]

    problems = []
    problems += find_smart_quotes(path, text)

    is_lcb = path.endswith(".lcb")
    line_comment_tokens = ["--"] if is_lcb else ["--", "#"]
    cleaned, cprob = clean_logical_lines(path, text, line_comment_tokens)
    problems += cprob

    if is_lcb:
        problems += check_lcb_module(path, cleaned)
        problems += check_lcb_blocks(path, cleaned)
        problems += check_lcb_constants(path, cleaned)
        problems += check_lcb_antipatterns(path, cleaned)
    else:
        problems += check_livecodescript_blocks(path, cleaned)
    return problems


def gather(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                if ".git" in root:
                    continue
                for n in names:
                    if n.endswith(".lcb") or n.endswith(".livecodescript"):
                        files.append(os.path.join(root, n))
        elif p.endswith(".lcb") or p.endswith(".livecodescript"):
            files.append(p)
    return sorted(set(files))


def main(argv):
    paths = argv[1:] or ["src", "examples"]
    files = gather(paths)
    all_problems = []
    for f in files:
        all_problems += check_file(f)
    for prob in sorted(all_problems, key=lambda p: (p.path, p.line)):
        print(prob)
    if all_problems:
        print("\n%d problem(s) in %d file(s)" % (all_problems.__len__(), len(files)))
        return 1
    print("check-livecodescript: %d file(s) OK" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
