#!/usr/bin/env python3
"""fileserver_golden.py - pure-Python reference for the security- and
correctness-critical logic of the Onion File Server demo
(examples/torrent-onion-fileserver.livecodescript).

OXT cannot compile/run .livecodescript headlessly, so - exactly like
onion_frame_golden.py and record_golden_test.py - this PINS the parts of the
folder-serving demo that are verifiable off-engine: the HTTP byte-range parser,
the path-traversal decision, the MIME mapping, and the HTML escaper. If this and
the .livecodescript ever disagree, one of them is wrong.

Mirrors these LiveCodeScript handlers:
  fsParseRange   -> parse_range()      (RFC 7233 single-range; 416 on out-of-range)
  fsServePath    -> traversal_ok()     (".." refused after urlDecode + \\ -> /)
  fsMime         -> mime()
  fsHtmlEscape   -> html_escape()

    python3 tests/fileserver_golden.py     # exit 0 = OK, 1 = mismatch
"""
import sys
from urllib.parse import unquote

_fail = []


def check(name, got, want):
    if got != want:
        _fail.append("%s:\n    got  %r\n    want %r" % (name, got, want))


# ---- fsParseRange: single HTTP byte-range against a known total -------------
# Returns "start,end" (inclusive, 0-based), "" (no/ignored range -> whole file),
# or "unsatisfiable" (valid syntax, out of bounds -> 416). Only ONE range is
# honoured; a multi-range (comma) request falls back to the whole file.

def _is_int(s):
    # LiveCode "X is an integer": an optional sign then digits, no decimal point.
    if s == "":
        return False
    try:
        int(s)
    except ValueError:
        return False
    return "." not in s and "e" not in s.lower()


def _item(s, idx):
    """LiveCode `item idx of s` with itemDelimiter '-' (1-based; missing -> "")."""
    parts = s.split("-")
    return parts[idx - 1] if idx - 1 < len(parts) else ""


def parse_range(rng, total):
    if rng == "":
        return ""
    if not rng.startswith("bytes="):
        return ""
    spec = rng[6:]                      # char 7 to -1 of pRange
    if "," in spec:
        return ""                       # multi-range: serve the whole file
    start, end = _item(spec, 1), _item(spec, 2)
    if start == "":
        # suffix range "bytes=-N": the last N bytes
        if end == "" or not _is_int(end):
            return "unsatisfiable"
        start = total - int(end)
        if start < 0:
            start = 0
        end = total - 1
    else:
        if not _is_int(start):
            return "unsatisfiable"
        start = int(start)
        if end == "":
            end = total - 1
        elif not _is_int(end):
            return "unsatisfiable"
        else:
            end = int(end)
    if start > end or start < 0 or start >= total:
        return "unsatisfiable"
    if end >= total:
        end = total - 1
    return "%d,%d" % (start, end)


# ---- fsServePath traversal guard: urlDecode, \ -> /, refuse ".." ------------

def traversal_ok(raw_path):
    """True if the request is allowed to touch disk; False -> 403. Mirrors the
    order in fsServePath: urlDecode, empty -> '/', backslashes -> '/', then the
    literal '..' substring test (intentionally strict, matching OnionXT)."""
    path = unquote(raw_path)
    if path == "":
        path = "/"
    path = path.replace("\\", "/")
    return ".." not in path


# ---- fsMime -----------------------------------------------------------------

_MIME = {
    "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
    "css": "text/css; charset=utf-8", "js": "application/javascript; charset=utf-8",
    "json": "application/json; charset=utf-8",
    "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8",
    "log": "text/plain; charset=utf-8",
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
    "ico": "image/x-icon", "pdf": "application/pdf",
    "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm",
    "mp3": "audio/mpeg", "ogg": "audio/ogg", "oga": "audio/ogg", "wav": "audio/wav",
    "zip": "application/zip",
}


def mime(path):
    # LiveCode: the last item of pPath with itemDelimiter "." (a name with no dot
    # is its own last item -> unknown -> octet-stream).
    extn = path.split(".")[-1].lower()
    return _MIME.get(extn, "application/octet-stream")


# ---- fsHtmlEscape: & first, then the rest -----------------------------------

def html_escape(text):
    out = text.replace("&", "&amp;")
    out = out.replace("<", "&lt;")
    out = out.replace(">", "&gt;")
    out = out.replace('"', "&quot;")
    out = out.replace("'", "&#39;")
    return out


def main():
    total = 1000
    # -- byte-range parsing --
    for rng, want in [
        ("", ""),                               # no Range header -> whole file
        ("bytes=0-499", "0,499"),               # a normal first-chunk range
        ("bytes=500-999", "500,999"),
        ("bytes=500-", "500,999"),              # open-ended -> to EOF
        ("bytes=0-", "0,999"),
        ("bytes=999-", "999,999"),              # last byte
        ("bytes=-500", "500,999"),              # suffix: last 500 bytes
        ("bytes=-5000", "0,999"),               # suffix bigger than file -> whole
        ("bytes=0-100000", "0,999"),            # end past EOF -> clamped
        ("bytes=1000-", "unsatisfiable"),       # start == total -> 416
        ("bytes=1500-2000", "unsatisfiable"),   # wholly past EOF -> 416
        ("bytes=5-3", "unsatisfiable"),         # start > end -> 416
        ("bytes=abc-10", "unsatisfiable"),      # non-numeric start -> 416
        ("bytes=10-xyz", "unsatisfiable"),      # non-numeric end -> 416
        ("bytes=-", "unsatisfiable"),           # empty suffix -> 416
        ("bytes=0-499,600-799", ""),            # multi-range -> serve whole file
        ("chunks=0-1", ""),                     # not a bytes range -> whole file
        ("bytes=0-0", "0,0"),                   # single first byte
    ]:
        check("parse_range(%r)" % rng, parse_range(rng, total), want)

    # empty file (total 0): any concrete range is unsatisfiable; no range -> ""
    check("parse_range empty-file no-range", parse_range("", 0), "")
    check("parse_range empty-file 0-", parse_range("bytes=0-", 0), "unsatisfiable")

    # -- path-traversal decision --
    for raw, ok in [
        ("/", True),
        ("/file.txt", True),
        ("/sub/dir/a.png", True),
        ("/a%20b.txt", True),                   # a space, decoded, is fine
        ("/../etc/passwd", False),              # literal ..
        ("/%2e%2e/secret", False),              # encoded ..
        ("/a/..%2f..%2fb", False),              # encoded ../.. mid-path
        ("/..%5c..%5cwindows", False),          # encoded ..\ (backslash) -> ..
        ("/deep/../../x", False),
        ("/weird..name.txt", False),            # intentionally strict (matches OnionXT)
    ]:
        check("traversal_ok(%r)" % raw, traversal_ok(raw), ok)

    # -- MIME mapping (extension is case-insensitive; unknown -> octet-stream) --
    for path, want in [
        ("index.html", "text/html; charset=utf-8"),
        ("a.PNG", "image/png"),
        ("movie.mp4", "video/mp4"),
        ("song.MP3", "audio/mpeg"),
        ("doc.pdf", "application/pdf"),
        ("archive.zip", "application/zip"),
        ("data.bin", "application/octet-stream"),
        ("noextension", "application/octet-stream"),
        ("a.tar.gz", "application/octet-stream"),   # only the final ext is looked up
    ]:
        check("mime(%r)" % path, mime(path), want)

    # -- HTML escaping (& first so an existing entity is not double-mangled wrong) --
    check("html_escape script",
          html_escape("<script>alert('x')</script>"),
          "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;")
    check("html_escape amp-first", html_escape("a & <b>"), "a &amp; &lt;b&gt;")
    check("html_escape quote", html_escape('say "hi"'), "say &quot;hi&quot;")

    if _fail:
        print("fileserver_golden: FAIL\n" + "\n".join(_fail))
        return 1
    print("fileserver_golden: OK (range parse, traversal guard, MIME, HTML escape all match)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
