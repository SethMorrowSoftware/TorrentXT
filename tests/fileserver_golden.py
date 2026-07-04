#!/usr/bin/env python3
"""fileserver_golden.py - pure-Python reference for the security- and
correctness-critical logic of Quick Share's FOLDER web server (the browsable
directory page served over the onion when a folder is shared with Tor on), in
examples/torrent-quickshare.livecodescript.

OXT cannot compile/run .livecodescript headlessly, so - exactly like
onion_frame_golden.py and record_golden_test.py - this PINS the parts of the
folder server that are verifiable off-engine: the HTTP byte-range parser, the
path-traversal decision, the MIME mapping, and the HTML escaper. If this and the
.livecodescript ever disagree, one of them is wrong.

Mirrors these LiveCodeScript handlers:
  qsFsParseRange  -> parse_range()      (RFC 7233 single-range; 416 on out-of-range)
  qsFsServePath   -> traversal_ok()     (".." refused after urlDecode + \\ -> /)
  qsFsMime        -> mime()
  qsFsIcon        -> fs_icon()          (directory-listing icon/colour type token)
  qsFsHtmlEscape  -> html_escape()
  qsCwServe       -> capability_route() (clearweb: the /<token>/ capability gate)
  qsSiteSpaTarget -> spa_is_route()     (SPA fallback: a route vs a missing asset)
  qsHttpHeaderEnd -> http_header_end()  (byte index of the CRLFCRLF head terminator)
  qsHttpReqComplete -> http_req_complete() (head + Content-Length body received?)
  qsJsonEscape    -> json_escape()      (the /_qs/info route's JSON value escaping)
  qsEditSafePath  -> edit_safe_path()   (web-editor WRITE-path confinement - linchpin)
  qsEditIsLocal   -> edit_is_local()    (web-editor LAN-first gate - the other linchpin)
  qsQueryParam    -> query_param()      (editor read/write ?path= extraction)

    python3 tests/fileserver_golden.py     # exit 0 = OK, 1 = mismatch
"""
import sys
from urllib.parse import unquote, unquote_plus

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
    # web-app essentials
    "wasm": "application/wasm", "mjs": "application/javascript; charset=utf-8",
    "xml": "application/xml; charset=utf-8", "map": "application/json; charset=utf-8",
    "webmanifest": "application/manifest+json",
    "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    "eot": "application/vnd.ms-fontobject", "avif": "image/avif",
    "csv": "text/csv; charset=utf-8",
}


def mime(path):
    # LiveCode: the last item of pPath with itemDelimiter "." (a name with no dot
    # is its own last item -> unknown -> octet-stream).
    extn = path.split(".")[-1].lower()
    return _MIME.get(extn, "application/octet-stream")


# ---- qsFsIcon: directory-listing icon/colour type token ---------------------
# Groups a filename (or folder) into one of dir/img/vid/aud/code/doc/zip/pdf/file for
# the listing's per-row icon. Same extension-family idea as mime(); mirrors qsFsIcon.

_ICON = {
    "img": "png jpg jpeg gif webp svg ico avif bmp heic",
    "vid": "mp4 m4v webm mov mkv avi",
    "aud": "mp3 ogg oga wav flac m4a aac",
    "code": "html htm css js mjs json xml yml yaml wasm map ts tsx jsx py rb go rs c h cpp sh",
    "doc": "txt md log csv doc docx rtf odt",
    "zip": "zip tar gz tgz rar 7z bz2 xz",
    "pdf": "pdf",
}


def fs_icon(name, is_dir):
    if is_dir:
        return "dir"
    extn = name.split(".")[-1].lower()
    for token, exts in _ICON.items():
        if extn in exts.split():
            return token
    return "file"


# ---- qsFileSizeSeek: O(log n) file-size probe (newquickshare) ----------------
# Instead of reading a whole file to size it (a UI-freezing, disk-doubling full read),
# find EOF by exponential-then-binary search over `seek to N; read 1`. readable(N) means
# "a byte exists at 0-based offset N" (N < size); the size is the smallest non-readable
# offset. Returns None (-> fall back to the linear count) if it exceeds the 8 GiB serve
# cap. This mirrors qsFileSizeSeek's control flow EXACTLY so the algorithm is pinned; the
# only on-engine unknown (seek-past-EOF returning empty) is guarded by the fallback.

def file_size_probe(size, cap=8589934592):
    def readable(n):
        return n < size
    if not readable(0):
        return 0                                  # empty file
    lo, hi = 0, 1
    while True:
        if hi > cap:
            return None                           # too big / no EOF: caller falls back
        if not readable(hi):
            break                                 # hi is an upper bound (not readable)
        lo, hi = hi, hi * 2
    while (hi - lo) > 1:
        mid = (lo + hi) // 2
        if readable(mid):
            lo = mid
        else:
            hi = mid
    return hi


# ---- qsSafeFilename: Content-Disposition filename sanitiser ------------------
# Printable ASCII only, minus quote and backslash, so the name is safe inside a
# quoted-string without RFC 5987 encoding. Empty -> "download". Mirrors qsSafeFilename.

def safe_filename(name):
    out = "".join(c for c in name if 32 <= ord(c) <= 126 and c not in '"\\')
    return out if out else "download"


# ---- qsRateShort / qsEtaShort: compact Transfers-row stats -------------------
# Compact data-rate ("1.2M/s") and ETA ("1h2m") strings that fit the narrow progress
# column. Mirror qsRateShort / qsEtaShort. _round1 reproduces LiveCode's
# `the round of (v*10)/10` (round half away from zero, number formatted with no .0).

def _round1(v):
    import math
    x = v * 10.0
    r = (math.floor(x + 0.5) if x >= 0 else math.ceil(x - 0.5)) / 10.0
    return "%g" % r


def rate_short(bps):
    if isinstance(bps, bool) or not isinstance(bps, (int, float)) or bps <= 0:
        return "0B/s"
    units = ["B", "K", "M", "G", "T"]
    v, u = float(bps), 0
    while v >= 1024 and u < len(units) - 1:
        v /= 1024
        u += 1
    return _round1(v) + units[u] + "/s"


def eta_short(secs):
    if isinstance(secs, bool) or not isinstance(secs, (int, float)) or secs < 0:
        return ""
    s = int(secs)                                  # trunc toward zero (LiveCode trunc)
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm" % (s // 60)
    if s < 86400:
        return "%dh%dm" % (s // 3600, (s % 3600) // 60)
    return ">1d"


# ---- fsHtmlEscape: & first, then the rest -----------------------------------

def html_escape(text):
    out = text.replace("&", "&amp;")
    out = out.replace("<", "&lt;")
    out = out.replace(">", "&gt;")
    out = out.replace('"', "&quot;")
    out = out.replace("'", "&#39;")
    return out


# ---- qsSiteSpaTarget: the SPA route-vs-asset heuristic ----------------------

# ---- the light HTTP backend: request framing + JSON escaping ----------------

def http_header_end(data):
    """1-based byte index of the first CR of the CRLFCRLF that ends the header block,
    or 0 if not fully received. Mirrors qsHttpHeaderEnd (a byte scan)."""
    i = data.find(b"\r\n\r\n")
    return 0 if i < 0 else i + 1


def _content_length(head_bytes):
    text = head_bytes.decode("utf-8", "replace")
    for line in text.split("\r\n")[1:]:          # skip the request line
        name, sep, val = line.partition(":")
        if sep and name.strip().lower() == "content-length":
            v = val.strip()
            try:
                return int(v) if "." not in v else None
            except ValueError:
                return None
    return None


def http_req_complete(data):
    """Mirror qsHttpReqComplete: the head plus (if a Content-Length is declared) the
    whole body must be present. A non-integer/absent Content-Length means no body."""
    he = http_header_end(data)
    if he == 0:
        return False
    cl = _content_length(data[:he - 1])          # byte 1..headEnd-1
    if cl is None:
        return True
    body_start = he + 4                           # 1-based, just past CRLFCRLF
    have = len(data) - body_start + 1
    return have >= cl


def http_req_length(data):
    """Mirror qsHttpReqLength: exact byte length of ONE complete request at the front of
    `data` = head-with-CRLFCRLF (headEnd + 3 bytes) + Content-Length body. 0 if the head
    is not yet complete. Keep-alive trims this many bytes to leave any pipelined bytes."""
    he = http_header_end(data)
    if he == 0:
        return 0
    cl = _content_length(data[:he - 1])
    if cl is None or cl < 0:
        cl = 0
    return he + 3 + cl


def json_escape(s):
    """Mirror qsJsonEscape: backslash first, then quote, CR, LF, tab."""
    out = s.replace("\\", "\\\\")
    out = out.replace('"', '\\"')
    out = out.replace("\r", "\\r")
    out = out.replace("\n", "\\n")
    out = out.replace("\t", "\\t")
    return out


# ---- qsEditSafePath: the web-EDITOR write-path confinement (THE linchpin) ----
# The editor can WRITE, so a traversal here = arbitrary file overwrite. This must
# resolve a caller-supplied relative path to an absolute path GUARANTEED inside the
# served root, or reject (""). It is intentionally over-cautious: ANY ".." or ":"
# anywhere, any control char, rejects the whole path (so a rare filename containing
# ".." is refused - a safe trade for the write path). Mirrors qsEditSafePath.

def edit_safe_path(root, rel):
    r = rel.replace("\\", "/")
    if ".." in r:
        return ""
    if ":" in r:                                  # drive letter or URL scheme
        return ""
    if any(ord(c) < 32 for c in r):               # NUL / control chars
        return ""
    out = []
    for seg in r.split("/"):
        if seg == "" or seg == ".":
            continue
        if seg == "..":
            return ""
        out.append(seg)
    if not out:
        return ""
    return root + "/" + "/".join(out)


# ---- qsEditIsLocal: the LAN-first gate (the editor's OTHER linchpin) ---------
# The web editor may only be reached from the local network. The ONLY trustworthy
# signal is the accepted-socket peer address the engine gives us (a remote client
# cannot forge it across a TCP handshake) - never a request header. Tor (ox:) is
# always remote. Mirrors qsEditIsLocal + qsIsPrivateIp.

def _edit_local_ip(ip):
    # STRICTER than qsIsPrivateIp: loopback + RFC-1918 + link-local ONLY. Carrier-NAT
    # (100.64/10) is the ISP's shared space, not the home LAN, so it is NOT local here.
    parts = ip.split(".")
    a = parts[0] if len(parts) >= 1 else ""
    b = parts[1] if len(parts) >= 2 else ""
    if not a.lstrip("-").isdigit():                # LiveCode "tA is not a number"
        return False
    a = int(a)
    bn = int(b) if b.lstrip("-").isdigit() else None
    if a == 10 or a == 127:
        return True
    if a == 192 and bn == 168:
        return True
    if a == 169 and bn == 254:
        return True
    if a == 172 and bn is not None and 16 <= bn <= 31:
        return True
    return False


def edit_is_local(conn):
    kind = conn[:3]
    if kind != "cw:":                              # Tor (ox:) / anything else: remote
        return False
    cid = conn[3:]
    if cid.startswith("::1"):                       # IPv6 loopback "::1:<port>"
        return True
    ip = cid.split(":")[0]                          # "<ip>:<port>[|n]" -> the ip
    return _edit_local_ip(ip)


# ---- qsQueryParam: one URL-decoded query value ------------------------------
# Splits on '&' then '=' (first match wins); a value may itself contain '='. NOTE
# LiveCode's urlDecode form-decodes '+' to a space (it is the inverse of urlEncode),
# so the faithful Python mirror is unquote_plus, NOT unquote. (The editor's JS client
# sends paths via encodeURIComponent, which emits '%2B' for a literal '+' and '%20'
# for a space, so a real filename still round-trips; the '+'->space rule only bites a
# hand-crafted URL.) The '+' handling cannot synthesise '..'/':' so it is traversal-neutral.

def query_param(query, name):
    if query == "":
        return ""
    for pair in query.split("&"):
        items = pair.split("=")
        if items[0] == name:
            return unquote_plus("=".join(items[1:])) if len(items) >= 2 else ""
    return ""


def spa_is_route(rel_path):
    """Mirror qsSiteSpaTarget's route-vs-asset heuristic (the part independent of the
    filesystem): the last '/' segment with NO '.' looks like a client-side route (fall
    back to index.html); a segment WITH a '.' looks like a missing asset (real 404).
    The caller separately requires a root index.html to exist before falling back."""
    leaf = rel_path.replace("\\", "/").split("/")[-1]
    return "." not in leaf


# ---- qsCwServe: the clearweb /<token>/ capability gate ----------------------
# The first path segment must equal the share's random token, else 404 (an open
# port must not be an open directory). The rest of the path is folder-relative.

def capability_route(decoded_path, token):
    """Returns 'forbidden' (.. present), or (matches, rest) where matches is
    whether the token segment equals `token` and rest is the folder-relative path
    (leading '/'). Mirrors qsCwServe: replace \\ -> /, refuse '..', then split on
    '/' with item 2 the token and item 3..-1 the rest."""
    p = decoded_path.replace("\\", "/")
    if ".." in p:
        return "forbidden"
    items = p.split("/")                 # "/tok/a/b" -> ["", "tok", "a", "b"]
    tok = items[1] if len(items) >= 2 else ""
    rest = "/" + "/".join(items[2:]) if len(items) >= 3 else "/"
    return (tok == token, rest)


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
        ("app.wasm", "application/wasm"),           # web-app essentials
        ("module.mjs", "application/javascript; charset=utf-8"),
        ("feed.xml", "application/xml; charset=utf-8"),
        ("bundle.js.map", "application/json; charset=utf-8"),
        ("site.webmanifest", "application/manifest+json"),
        ("f.woff", "font/woff"),
        ("font.WOFF2", "font/woff2"),
        ("f.ttf", "font/ttf"),
        ("f.otf", "font/otf"),
        ("f.eot", "application/vnd.ms-fontobject"),
        ("pic.avif", "image/avif"),
        ("data.csv", "text/csv; charset=utf-8"),
    ]:
        check("mime(%r)" % path, mime(path), want)

    # -- HTML escaping (& first so an existing entity is not double-mangled wrong) --
    check("html_escape script",
          html_escape("<script>alert('x')</script>"),
          "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;")
    check("html_escape amp-first", html_escape("a & <b>"), "a &amp; &lt;b&gt;")
    check("html_escape quote", html_escape('say "hi"'), "say &quot;hi&quot;")

    # -- clearweb capability gate (the /<token>/ prefix) --
    tok = "abc123"
    for path, want in [
        ("/abc123/", (True, "/")),                 # folder root
        ("/abc123", (True, "/")),                  # no trailing slash -> root
        ("/abc123/sub/", (True, "/sub/")),         # a subfolder
        ("/abc123/a/b.txt", (True, "/a/b.txt")),   # a nested file
        ("/abc123/photo.jpg", (True, "/photo.jpg")),
        ("/wrongtoken/", (False, "/")),            # bad token -> 404
        ("/", (False, "/")),                       # bare root, no token -> 404
        ("", (False, "/")),                        # empty -> 404
        ("/abc123/../etc", "forbidden"),           # traversal refused first
    ]:
        check("capability_route(%r)" % path, capability_route(path, tok), want)

    # -- SPA fallback: is an unresolved path a client-side route or a missing asset? --
    for path, want in [
        ("/dashboard", True),                      # a route -> index.html
        ("/users/42", True),
        ("/deep/route/here", True),
        ("/", True),                               # empty leaf -> route (resolves anyway)
        ("/a.b/c", True),                          # dot is in a PARENT segment, not the leaf
        ("/app.js", False),                        # a missing asset -> real 404
        ("/assets/logo.png", False),
        ("/favicon.ico", False),
        ("/a/b.min.js", False),
        ("/style.css", False),
    ]:
        check("spa_is_route(%r)" % path, spa_is_route(path), want)

    # -- HTTP request framing (head terminator + Content-Length body) --
    get_full = b"GET /_qs/info HTTP/1.1\r\nHost: x\r\n\r\n"
    check("header_end GET", http_header_end(get_full), get_full.find(b"\r\n\r\n") + 1)
    check("complete GET (no body)", http_req_complete(get_full), True)
    check("incomplete head", http_req_complete(b"GET / HTTP/1.1\r\nHost: x\r\n"), False)
    post_hdr = b"POST /api HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
    check("post no body yet", http_req_complete(post_hdr), False)
    check("post partial body", http_req_complete(post_hdr + b"hel"), False)
    check("post full body", http_req_complete(post_hdr + b"hello"), True)
    check("post over-long body still complete", http_req_complete(post_hdr + b"helloEXTRA"), True)
    check("post non-integer CL -> no body", http_req_complete(
        b"POST /api HTTP/1.1\r\nContent-Length: abc\r\n\r\n"), True)

    # -- keep-alive framing: qsHttpReqLength trims exactly one request, leaving pipelined
    #    bytes intact and complete for the next round (headEnd + 3 + Content-Length) --
    check("reqlen GET exact", http_req_length(get_full), len(get_full))
    check("reqlen GET incomplete head", http_req_length(b"GET / HTTP/1.1\r\nHost: x\r\n"), 0)
    check("reqlen POST with body", http_req_length(post_hdr + b"hello"), len(post_hdr) + 5)
    # a pipelined pair: trimming the first length leaves EXACTLY the second request
    pair = get_full + post_hdr + b"hello"
    n = http_req_length(pair)
    check("reqlen pipelined GET length", n, len(get_full))
    check("reqlen pipelined remainder intact", pair[n:], post_hdr + b"hello")
    check("reqlen pipelined remainder complete", http_req_complete(pair[n:]), True)
    # trimming a POST(+body) leaves the trailing pipelined GET
    pair2 = post_hdr + b"hello" + get_full
    n2 = http_req_length(pair2)
    check("reqlen POST length includes body", n2, len(post_hdr) + 5)
    check("reqlen POST remainder is next GET", pair2[n2:], get_full)
    # non-integer Content-Length frames as no body (matches http_req_complete)
    check("reqlen non-integer CL -> head only", http_req_length(
        b"POST /api HTTP/1.1\r\nContent-Length: abc\r\n\r\n"),
        http_header_end(b"POST /api HTTP/1.1\r\nContent-Length: abc\r\n\r\n") + 3)

    # -- JSON value escaping (for the /_qs/info route) --
    check("json plain", json_escape("hello"), "hello")
    check("json quote", json_escape('a"b'), 'a\\"b')
    check("json backslash", json_escape("c:\\path"), "c:\\\\path")
    check("json crlf", json_escape("a\r\nb"), "a\\r\\nb")
    check("json tab", json_escape("x\ty"), "x\\ty")
    check("json backslash-before-quote order", json_escape('\\"'), '\\\\\\"')

    # -- editor write-path confinement (THE security linchpin) --
    R = "/srv"
    for rel, want in [
        ("index.html", "/srv/index.html"),        # allowed: a plain file
        ("css/app.css", "/srv/css/app.css"),
        ("/css/app.css", "/srv/css/app.css"),     # leading slash is fine
        ("a//b.txt", "/srv/a/b.txt"),             # empty segment collapses
        ("./a.txt", "/srv/a.txt"),                # "." segment dropped
        ("a/./b.txt", "/srv/a/b.txt"),
        (".env", "/srv/.env"),                    # a dotfile UNDER root is fine
        ("../etc/passwd", ""),                    # REJECT: traversal
        ("a/../b", ""),
        ("..", ""),
        ("...", ""),                              # REJECT: contains ".." (over-cautious)
        ("my..file.txt", ""),                     # REJECT: contains ".." (over-cautious)
        ("C:/Windows/win.ini", ""),               # REJECT: drive colon
        ("http://evil/x", ""),                    # REJECT: scheme colon
        ("", ""),                                 # REJECT: names nothing
        ("/", ""),
        ("\\..\\..\\x", ""),                      # REJECT: backslashes -> ".."
        ("a\x00b.txt", ""),                       # REJECT: NUL / control char
        ("a\tb.txt", ""),                         # REJECT: control char (tab)
    ]:
        check("edit_safe_path(%r)" % rel, edit_safe_path(R, rel), want)

    # -- directory-listing icon classification --
    for name, is_dir, want in [
        ("photos", True, "dir"),                  # a folder
        ("index.html", False, "code"),            # web source -> code icon
        ("app.min.js", False, "code"),            # last ext only
        ("styles.css", False, "code"),
        ("logo.PNG", False, "img"),               # case-insensitive
        ("clip.mp4", False, "vid"),
        ("song.flac", False, "aud"),
        ("notes.txt", False, "doc"),
        ("readme.md", False, "doc"),
        ("data.csv", False, "doc"),
        ("archive.tar.gz", False, "zip"),         # final ext gz -> zip
        ("manual.pdf", False, "pdf"),
        ("photo.heic", False, "img"),
        ("blob.bin", False, "file"),              # unknown -> generic
        ("Makefile", False, "file"),              # no extension -> generic
    ]:
        check("fs_icon(%r)" % name, fs_icon(name, is_dir), want)

    # -- file-size seek probe: must return the exact size for every shape --
    for s in [0, 1, 2, 3, 4, 7, 8, 255, 256, 257, 1000, 4095, 4096, 65535, 65536,
              1000000, 2 ** 30, 8589934592]:      # last = exactly the 8 GiB cap
        check("file_size_probe(%d)" % s, file_size_probe(s), s)
    # a file larger than the cap gives up (caller falls back to the linear count)
    check("file_size_probe over-cap", file_size_probe(8589934592 + 1), None)

    # -- Content-Disposition filename sanitising --
    for name, want in [
        ("report.pdf", "report.pdf"),
        ("my file.txt", "my file.txt"),           # spaces are fine
        ('a"b.txt', "ab.txt"),                     # drop the quote
        ("back\\slash", "backslash"),             # drop the backslash
        ("nau\x00gh\tty", "naughty"),             # drop control bytes
        ("café.png", "caf.png"),             # drop non-ASCII (no RFC 5987 needed)
        ("", "download"),                          # nothing left -> a default
        ("\x01\x02", "download"),
    ]:
        check("safe_filename(%r)" % name, safe_filename(name), want)

    # -- compact transfer-row rate + ETA formatting --
    for bps, want in [
        (0, "0B/s"), (-5, "0B/s"), (512, "512B/s"), (1024, "1K/s"),
        (1536, "1.5K/s"), (1048576, "1M/s"), (1300000, "1.2M/s"),
        (1073741824, "1G/s"), (2000, "2K/s"),
    ]:
        check("rate_short(%d)" % bps, rate_short(bps), want)
    for secs, want in [
        (-1, ""), (0, "0s"), (45, "45s"), (59, "59s"), (60, "1m"), (125, "2m"),
        (3599, "59m"), (3600, "1h0m"), (3725, "1h2m"), (86399, "23h59m"),
        (86400, ">1d"), (200000, ">1d"), (44.9, "44s"),
    ]:
        check("eta_short(%r)" % secs, eta_short(secs), want)

    # -- editor LAN-first gate (only local peers may reach the editor) --
    for conn, want in [
        ("cw:192.168.1.5:52000", True),           # home LAN
        ("cw:10.0.0.9:1234", True),               # RFC-1918 10/8
        ("cw:127.0.0.1:5000", True),              # loopback
        ("cw:172.16.4.4:80", True),               # 172.16/12 lower edge
        ("cw:172.31.9.9:80", True),               # 172.16/12 upper edge
        ("cw:172.32.0.1:80", False),              # just outside 172.16-31 -> public
        ("cw:100.64.0.1:80", False),              # carrier-NAT: ISP-shared, NOT the LAN
        ("cw:169.254.1.1:80", True),              # link-local
        ("cw:::1:5000", True),                    # IPv6 loopback
        ("cw:8.8.8.8:443", False),                # public
        ("cw:203.0.113.7:12345", False),          # public (TEST-NET-3)
        ("cw:192.168.0.1:80|2", True),            # private with a |n socket suffix
        ("cw:1.2.3.4:80|3", False),               # public with a |n socket suffix
        ("ox:streamhandle42", False),             # Tor: ALWAYS remote
        ("ox:anything", False),
    ]:
        check("edit_is_local(%r)" % conn, edit_is_local(conn), want)

    # -- query-string value extraction (editor read/write ?path=) --
    for query, name, want in [
        ("path=css/app.css", "path", "css/app.css"),
        ("path=a%2Fb.txt", "path", "a/b.txt"),    # %2F decoded to /
        ("path=a%20b.txt", "path", "a b.txt"),    # %20 decoded to a space
        ("path=a+b.txt", "path", "a b.txt"),      # LiveCode urlDecode: '+' -> space
        ("path=a%2Bb.txt", "path", "a+b.txt"),    # %2B -> a literal '+' (what the JS sends)
        ("x=1&path=main.js", "path", "main.js"),  # second param
        ("path=main.js&x=1", "path", "main.js"),  # first param
        ("path=x=y", "path", "x=y"),              # value may contain '='
        ("path=", "path", ""),                    # present but empty
        ("q=hello", "path", ""),                  # absent -> empty
        ("", "path", ""),                         # no query -> empty
        ("foo=bar&foo=baz", "foo", "bar"),        # first match wins
    ]:
        check("query_param(%r,%r)" % (query, name), query_param(query, name), want)

    if _fail:
        print("fileserver_golden: FAIL\n" + "\n".join(_fail))
        return 1
    print("fileserver_golden: OK (range parse, traversal guard, MIME, icon classify, "
          "HTML escape, capability gate, SPA fallback, HTTP framing, keep-alive req "
          "length, JSON escape, editor confinement, LAN-first gate, query parse, size "
          "probe, filename sanitise, rate + ETA format all match)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
