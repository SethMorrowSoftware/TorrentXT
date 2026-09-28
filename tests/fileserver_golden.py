#!/usr/bin/env python3
"""fileserver_golden.py - pure-Python reference for the security- and
correctness-critical logic of Quick Share's FOLDER web server (the browsable
directory page served over the onion when a folder is shared with Tor on, and
over the clearweb link), in examples/torrent-quickshare.livecodescript.

OXT cannot compile/run .livecodescript headlessly, so - exactly like
onion_frame_golden.py and record_golden_test.py - this PINS the parts of the
folder server that are verifiable off-engine: the HTTP byte-range parser, the
path-traversal decision, the dotfile and reserved-namespace refusals, the
static pipeline's whole decision, the listing, the MIME mapping, and the HTML
escaper. If this and the .livecodescript ever disagree, one of them is wrong.

Mirrors these LiveCodeScript handlers:
  qsFsParseRange  -> parse_range()      (RFC 7233 single-range; 416 on out-of-range)
  qsFsServePath   -> traversal_ok()     (".." refused after urlDecode + \\ -> /)
  qsHasDotSegment -> has_dot_segment()  (a dot-leading segment does not exist; nocloud's
                                         round-5 guard, ported 2026-09-27)
  qsHttpReservedPath -> reserved_path() (/_qs and /_edit are the route layer's; folded on
                                         purpose; nocloud's, ported 2026-09-27)
  qsFsServePath + qsCwServe -> serve_static() (the whole static decision over a tree: the
                                         route, 405, reserved 404, 503, dotfile 404, folder
                                         redirect / index / listing, file, SPA, 404)
  qsFsListing     -> listing_visible()  (the names a listing shows: no dot-leading entry)
  qsEditWriteRoute -> edit_write_decision() (the editor's WRITE refusals, in order:
                                         confinement, a hidden path, a folder)
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
  qsHexKey        -> hex_key()          (lowercase hex of the UTF-8 bytes: a key no case
                                         fold can merge; 2026-09-25)
  qsRouteKey      -> route_key()        (the case-exact route-table key: the hex of
                                         "METHOD /path", the method upper-cased)
  qsRouteLookupKey -> route_lookup_key() (the key a request DISPATCHES to, or "": a HEAD
                                         falls back to the GET route; GET /_EDIT is not the
                                         /_edit route. WORK-PLAN torrentxt #18, 2026-09-25)

EVERY mirror here names a handler the demo has, and tools/check-script-vectors.py holds
each to the SHIPPED demo through the family interpreter, on these rows (since
2026-09-27; until then only the route section was driven, and five mirrors copied
from nocloud's golden named nocloud handlers this demo never had: has_dot_segment,
which now has its handler, and http_req_length, file_size_probe, safe_filename and
rate_short / eta_short, which were deleted here and stay pinned in nocloud's golden,
against nocloud's script). The route section fills the demo's table through its own
qsHttpRoute, so the subscript the engine folds is the interpreter's folded one; the
serve rows run the demo's real qsFsServePath and qsCwServe over a real folder built
from SERVE_TREE.

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


# ---- qsHasDotSegment: the static-path dotfile guard (round 5) ----------------
# Any "/"-separated segment starting with "." makes the path invisible to the
# static pipelines (listing + serving, both transports): a shared website
# folder must never leak .git / .env over an anonymous link. Mirrors
# qsHasDotSegment: split on "/", skip empty segments, test the first char.

def has_dot_segment(path):
    return any(seg.startswith(".") for seg in path.split("/") if seg)


# ---- qsHttpReservedPath: the route layer's namespaces (nocloud's, 2026-08-17) ----
# /_qs (the observability endpoint) and /_edit (the LAN editor) belong to the ROUTE
# layer: a request there that named no route is a 404 from the static pipeline, never
# a real "_qs" folder in the share nor the SPA fallback's index.html. Prefix-exact
# ("/_qsx" is an ordinary path); CASE-FOLDED on purpose, stricter than the case-exact
# route table (the engine's `is` and `begins with` fold anyway). Mirrors
# qsHttpReservedPath.

def reserved_path(path):
    low = path.lower()
    return (low in ("/_qs", "/_edit")
            or low.startswith("/_qs/") or low.startswith("/_edit/"))


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


# ---- route-table keys: case-exact (2026-09-25; nocloud's, ported the same day) ----
# HTTP paths are case-sensitive, and until 2026-09-25 this demo's were not: sHttpRoutes
# was keyed by the TEXT "METHOD /path", and the engine folds array keys (the suite's
# engine note 2.7), so GET /_EDIT reached the /_edit route. The demo now keys by the hex
# of that text (qsRouteKey), and qsRouteLookupKey reads the table itself, answering the
# key that dispatches or "". The mirrors take a table as readable "METHOD /path" strings.

def hex_key(text):
    """Mirror qsHexKey: the lowercase hex of the text's UTF-8 bytes. Its only letters are
    a-f, always lower case, so key.lower() == key: no case fold merges two of them."""
    return text.encode("utf-8").hex()


def route_key(method, path):
    """Mirror qsRouteKey: the hex of "METHOD /path", the method upper-cased (methods fold
    on purpose; paths do not)."""
    return hex_key(method.upper() + " " + path)


def rk(readable):
    """A readable "METHOD /path" table entry -> its route_key (vector shorthand)."""
    method, path = readable.split(" ", 1)
    return route_key(method, path)


def table(readables):
    """The key set of a table holding these readable "METHOD /path" routes."""
    return set(rk(x) for x in readables)


def engine_folds_onto(readables, key):
    """The ENGINE's subscript over raw-text keys (engine note 2.7, ASCII): does `key` reach
    a stored key when case folds?"""
    return any(k.lower() == key.lower() for k in readables)


def old_raw_lookup_hits(method, path, readables):
    """Would the PRE-2026-09-25 lookup have dispatched this request on the engine? It keyed
    by the raw "METHOD /path" text, a HEAD falling back to GET, and the subscript folded.
    Not a mirror of anything shipped: the fold rows' witness."""
    m = method.upper()
    if engine_folds_onto(readables, m + " " + path):
        return True
    return m == "HEAD" and engine_folds_onto(readables, "GET " + path)


def route_lookup_key(method, path, keys):
    """Mirror qsRouteLookupKey: the route-table key a request DISPATCHES to, or "" when the
    table has no route for it. Every method looks up its own key; a HEAD with no HEAD route
    of its own (an explicit one wins) falls back to the GET key, because HEAD is
    GET-without-a-body (the 2026-09-24 port of nocloud's 2026-08-17 fix: until then a HEAD
    missed the table and the SPA fallback answered HEAD /_qs/info with index.html). `keys`
    is the key set of the table (table()); an empty one routes nothing."""
    method = method.upper()
    key = route_key(method, path)
    if key in keys:
        return key
    if method == "HEAD" and route_key("GET", path) in keys:
        return route_key("GET", path)
    return ""


# The rows the execution gate drives against the demo, and main() below against the
# mirror: (method, path, table, the readable route that dispatches, or "" for none).
# The table is the demo's own built-in set (qsStart), plus a user-style one with a
# declared HEAD route, as nocloud's golden has. FOLD rows are the ones the pre-fix raw
# keys merged onto a declared route (main() re-proves each through old_raw_lookup_hits,
# so a fold row that never exercised the fold fails here, not silently).
LK_BUILTIN = ["GET /_qs/info", "GET /_edit", "POST /_edit/login", "GET /_edit/api/list",
              "GET /_edit/api/read", "PUT /_edit/api/write"]
LK_USER = ["GET /api/hello", "HEAD /probe", "GET /probe", "POST /api/submit"]
LK_ODD = ["GET /caf\u00e9", "GET /v/1"]
LOOKUP_ROWS = [
    ("HEAD", "/_qs/info", LK_BUILTIN, "GET /_qs/info"),    # the built-in route answers
    ("GET", "/_qs/info", LK_BUILTIN, "GET /_qs/info"),
    ("HEAD", "/api/hello", LK_USER, "GET /api/hello"),     # a HEAD finds its GET route
    ("HEAD", "/probe", LK_USER, "HEAD /probe"),            # a DECLARED HEAD route wins
    ("GET", "/probe", LK_USER, "GET /probe"),              # ... and GET keeps its own
    ("GET", "/nope", LK_USER, ""),                         # a miss dispatches nothing
    ("POST", "/api/submit", LK_USER, "POST /api/submit"),  # no fallback for other verbs
    ("POST", "/probe", LK_USER, ""),                       # ... even where GET exists
    ("HEAD", "/nope", LK_USER, ""),                        # falls back, then misses
    ("head", "/api/hello", LK_USER, "GET /api/hello"),     # method upper-cased first
    ("HEAD", "/api/hello", [], ""),                        # an EMPTY table routes nothing
    ("GET", "/api/hello", [], ""),
]
FOLD_ROWS = [                                              # each must dispatch NOTHING
    ("GET", "/_EDIT", LK_BUILTIN),                         # GET /_EDIT is not /_edit
    ("PUT", "/_Edit/Api/Write", LK_BUILTIN),
    ("HEAD", "/_QS/INFO", LK_BUILTIN),                     # nor through HEAD -> GET
    ("GET", "/API/hello", LK_USER),
    ("HEAD", "/API/HELLO", LK_USER),
    ("HEAD", "/PROBE", LK_USER),                           # nor onto a declared HEAD route
    ("POST", "/API/submit", LK_USER),
]
ODD_ROWS = [                                               # bytes, no fold, no numeric alias
    ("GET", "/caf\u00e9", LK_ODD, "GET /caf\u00e9"),
    ("GET", "/CAF\u00c9", LK_ODD, ""),
    ("GET", "/v/1", LK_ODD, "GET /v/1"),
    ("GET", "/v/01", LK_ODD, ""),
    ("GET", "/v/1.0", LK_ODD, ""),
]
HEX_ROWS = [("", ""), ("GET /api/x", "474554202f6170692f78"), ("/caf\u00e9", "2f636166c3a9"),
            ("A", "41"), ("a", "61"), ("\x00\x7f", "007f")]
KEY_ROWS = [("GET", "/api/x"), ("get", "/api/x"), ("GET", "/API/x"), ("POST", "/caf\u00e9"),
            ("HEAD", "/")]


def lookup_rows():
    """Every lookup row as (label, method, path, table, the key the mirror dispatches to)."""
    out = []
    for method, path, keys, _ in LOOKUP_ROWS + ODD_ROWS:
        out.append(("%s %s" % (method, path), method, path, keys,
                    route_lookup_key(method, path, table(keys))))
    for method, path, keys in FOLD_ROWS:
        out.append(("%s %s (fold)" % (method, path), method, path, keys,
                    route_lookup_key(method, path, table(keys))))
    return out


# ---- qsCwServe: the clearweb /<token>/ capability gate ----------------------
# The first path segment must equal the share's random token, else 404 (an open
# port must not be an open directory). The rest of the path is folder-relative.

def capability_route(decoded_path, token):
    """Returns 'forbidden' (.. present), or (matches, rest) where matches is
    whether the token segment equals `token` and rest is the folder-relative path
    (leading '/'). Mirrors qsCwServe: replace \\ -> /, refuse '..', then split on
    '/' with item 2 the token and the rest the TEXT after it (python's split keeps a
    trailing empty item, so "/".join(items[2:]) is that text, a folder's trailing
    slash included; the script takes it by a char offset that counts item 1 too,
    so a target with no leading "/" still yields a rest anchored at "/")."""
    p = decoded_path.replace("\\", "/")
    if ".." in p:
        return "forbidden"
    items = p.split("/")                 # "/tok/a/b" -> ["", "tok", "a", "b"]
    tok = items[1] if len(items) >= 2 else ""
    rest = "/" + "/".join(items[2:]) if len(items) >= 3 else "/"
    return (tok == token, rest)



# ---- the static pipeline's whole decision (qsFsServePath, qsCwServe's folder branch) ----
# One outcome per request, in the shape the gate records from the demo's own calls:
#   ("text", "<3-digit status>")       a one-shot text reply (qsFsSendText / qsCwSendText);
#                                      "200" is the listing, the only 200 text reply here
#   ("redirect", "<location>")         the trailing-slash redirect (the RAW path + "/")
#   ("file", "<rel disk path>", "<name the MIME is read from>")   a served file
#   ("route", "<METHOD /path>")        a dispatched route, by its readable key
# `tree` is a set of relative paths, a trailing "/" naming a folder (SERVE_TREE); `routes`
# maps a readable "METHOD /path" to its handler, as the demo's qsStart registers them.
# The order is the demo's, which is nocloud's qsHttpServeStatic's: traversal 403, the
# route layer, 405, the RESERVED namespace (above the 503, so the answer does not change
# with whether a folder is shared), 503, a DOT segment, a folder (redirect / index.html /
# the listing), a file, the SPA fallback, 404. The clearweb twin (token given) checks the
# capability token first and has no 503 (a folder share always has its root).

def _tree_sets(tree):
    dirs = set([""])
    files = set()
    for t in tree:
        if t.endswith("/"):
            dirs.add(t.rstrip("/"))
        else:
            files.add(t)
    return dirs, files


def serve_static(method, raw, tree, routes, shared=True, token=None):
    """The front of each serve path is the mirror above it: traversal_ok() over Tor,
    capability_route() over the clearweb link, so this holds both to the demo too."""
    dirs, files = _tree_sets(tree)
    path = unquote_plus(raw)                  # LiveCode's urlDecode: '+' is a space too
    if token is None:
        if not traversal_ok(raw):
            return ("text", "403")
        path = (path or "/").replace("\\", "/")
        if not path.startswith("/"):
            path = "/" + path                 # anchored at the share root (2026-09-27)
    else:
        cap = capability_route(path, token)
        if cap == "forbidden":
            return ("text", "403")
        matches, path = cap
        if not matches:
            return ("text", "404")
    redirect_base = raw
    key = route_lookup_key(method, path, table(routes))
    if key:
        return ("route", [r for r in routes if rk(r) == key][0])
    if method.upper() not in ("GET", "HEAD"):
        return ("text", "405")
    if reserved_path(path):
        return ("text", "404")
    if not shared:
        return ("text", "503")
    if has_dot_segment(path):
        return ("text", "404")
    rel = path.strip("/")
    if rel in dirs:
        if not path.endswith("/"):
            return ("redirect", redirect_base + "/")
        index = (rel + "/index.html") if rel else "index.html"
        if index in files:
            return ("file", index, "index.html")
        return ("text", "200")
    if not path.endswith("/") and rel in files:
        return ("file", rel, path)
    if "index.html" in files and spa_is_route(path):
        return ("file", "index.html", "index.html")
    return ("text", "404")


def listing_visible(names):
    """Mirror qsFsListing's row filter: the names (files and folders alike) a listing
    shows, sorted. "." and ".." and an empty line never; a dot-leading name never (the
    serve paths 404 it: qsHasDotSegment)."""
    return sorted(n for n in names if n not in ("", ".", "..") and not n.startswith("."))


def edit_write_decision(rel, tree):
    """Mirror qsEditWriteRoute's refusals for an AUTHORISED request, in its order: the
    confinement (qsEditSafePath) 400, a hidden (dot) path 400, a folder 409; else the save
    (200). Returns the (status, body) the demo replies with. The dot check reads the
    path with edit_safe_path's separators, a backslash as a "/" (2026-09-27: read raw,
    "\\.env" slipped past it and was written as .env)."""
    dirs, _ = _tree_sets(tree)
    disk = edit_safe_path("/srv", rel)
    if disk == "":
        return (400, "Bad path.")
    if has_dot_segment(rel.replace("\\", "/")):
        return (400, "Hidden (dot) paths cannot be written through the editor.")
    if disk[len("/srv/"):] in dirs:
        return (409, "That path is a folder.")
    return (200, "Saved.")


# The folder the serve rows run over (the gate builds it on disk). A website: index.html
# at its root, so the SPA fallback is live; the dotfiles a shared web folder carries;
# real folders named like the reserved namespaces.
SERVE_TREE = ["index.html", "public.txt", "docs/", "docs/readme.md", "docs/.secret.txt",
              ".env", ".git/", ".git/config", ".well-known/", ".well-known/security.txt",
              "notes.d/", "notes.d/file.txt", "_qs/", "_qs/data.json", "_Edit/",
              "_Edit/index.html", "sub/", "sub/a.txt", "sub/.hidden/", "sub/.hidden/x.txt",
              "sub/.dotfile", "site/", "site/index.html"]
# The demo's qsStart registrations (the gate holds this table to the source's).
SERVE_ROUTES = {"GET /_qs/info": "qsInfoRoute", "GET /_edit": "qsEditPageRoute",
                "POST /_edit/login": "qsEditLoginRoute", "GET /_edit/api/list": "qsEditListRoute",
                "GET /_edit/api/read": "qsEditReadRoute", "PUT /_edit/api/write": "qsEditWriteRoute"}
# (method, raw path, the folder shared?, the pinned outcome) - over Tor (qsFsServePath)
SERVE_ROWS = [
    ("GET", "/", True, ("file", "index.html", "index.html")),
    ("GET", "/public.txt", True, ("file", "public.txt", "/public.txt")),
    ("HEAD", "/public.txt", True, ("file", "public.txt", "/public.txt")),
    ("GET", "/docs", True, ("redirect", "/docs/")),
    ("GET", "/docs/", True, ("text", "200")),                   # the listing
    ("GET", "/docs/readme.md", True, ("file", "docs/readme.md", "/docs/readme.md")),
    ("GET", "/site/", True, ("file", "site/index.html", "index.html")),
    ("GET", "/notes.d/file.txt", True, ("file", "notes.d/file.txt", "/notes.d/file.txt")),
    ("GET", "/dashboard", True, ("file", "index.html", "index.html")),   # the SPA fallback
    ("GET", "/missing.js", True, ("text", "404")),
    # THE DOTFILE ROWS: each exists on disk, and each was served before 2026-09-27
    ("GET", "/.env", True, ("text", "404")),
    ("HEAD", "/.env", True, ("text", "404")),
    ("GET", "/.git/config", True, ("text", "404")),
    ("GET", "/.git/", True, ("text", "404")),                   # was its listing
    ("GET", "/.git", True, ("text", "404")),                    # was its redirect
    ("GET", "/docs/.secret.txt", True, ("text", "404")),
    ("GET", "/%2eenv", True, ("text", "404")),                  # decoded first
    ("GET", "/.well-known/security.txt", True, ("text", "404")),   # hidden is hidden
    ("GET", "/sub/.hidden/x.txt", True, ("text", "404")),
    ("GET", "/.cache/app", True, ("text", "404")),              # was the SPA's index.html
    # THE RESERVED ROWS: a route answers its own path; anything else there is a 404
    ("GET", "/_qs/info", True, ("route", "GET /_qs/info")),
    ("HEAD", "/_qs/info", True, ("route", "GET /_qs/info")),
    ("GET", "/_edit", True, ("route", "GET /_edit")),
    ("POST", "/_edit/login", True, ("route", "POST /_edit/login")),
    ("GET", "/_qs/data.json", True, ("text", "404")),           # was the real file
    ("GET", "/_qs/other", True, ("text", "404")),               # was the SPA's index.html
    ("GET", "/_QS/info", True, ("text", "404")),                # folded: was the SPA
    ("GET", "/_Edit/", True, ("text", "404")),                  # was _Edit/index.html
    ("GET", "/_edit/nope", True, ("text", "404")),
    ("GET", "/_qsx", True, ("file", "index.html", "index.html")),   # prefix-exact: SPA
    ("GET", "/_editor", True, ("file", "index.html", "index.html")),
    # the rest of the order
    ("PUT", "/public.txt", True, ("text", "405")),
    ("GET", "/../etc/passwd", True, ("text", "403")),
    ("GET", "/public.txt", False, ("text", "503")),
    ("GET", "/_QS/x", False, ("text", "404")),                  # reserved sits above the 503
    ("GET", "/.env", False, ("text", "503")),                   # the dot check below it
    # THE ANCHOR ROWS (2026-09-27, the review of the port): a request target with no
    # leading "/" is read from the share ROOT. Before, the disk path was the root's text
    # & the target, so these named OUTSIDE_TREE's sibling folder (main() re-proves it)
    ("GET", "-backup/secret.txt", True, ("text", "404")),       # was the sibling's file
    ("GET", "-backup/", True, ("file", "index.html", "index.html")),   # was its listing
    ("GET", "public.txt", True, ("file", "public.txt", "/public.txt")),   # was a 404
    ("GET", "docs", True, ("redirect", "docs/")),
    ("GET", ".env", True, ("text", "404")),
]
CW_TOKEN = "abc123"
# (method, raw path, the pinned outcome) - over the clearweb link (qsCwServe), folder share
CW_ROWS = [
    ("GET", "/abc123/public.txt", ("file", "public.txt", "/public.txt")),
    ("GET", "/abc123/docs", ("redirect", "/abc123/docs/")),
    ("GET", "/abc123/docs/", ("text", "200")),                  # was a redirect to docs//
    ("GET", "/abc123/docs/readme.md", ("file", "docs/readme.md", "/docs/readme.md")),
    ("GET", "/abc123/site/", ("file", "site/index.html", "index.html")),
    ("GET", "/abc123/", ("file", "index.html", "index.html")),
    ("GET", "/abc123/.env", ("text", "404")),
    ("GET", "/abc123/.git/config", ("text", "404")),
    ("GET", "/abc123/.git/", ("text", "404")),
    ("GET", "/abc123/docs/.secret.txt", ("text", "404")),
    ("GET", "/abc123/%2egit/config", ("text", "404")),
    ("GET", "/abc123/_qs/info", ("route", "GET /_qs/info")),
    ("GET", "/abc123/_qs/data.json", ("text", "404")),
    ("GET", "/abc123/_QS/info", ("text", "404")),
    ("GET", "/abc123/_Edit/", ("text", "404")),
    ("GET", "/abc123/_qsx", ("file", "index.html", "index.html")),
    ("GET", "/wrong/.env", ("text", "404")),                    # the token first
    ("PUT", "/abc123/.env", ("text", "405")),
    # a target with no leading "/": the rest still starts at the "/" after the token
    # (2026-09-27, the review: an offset from the token's length alone began it inside
    # the token, "3/public.txt", OUTSIDE_TREE's sibling; main() re-proves it)
    ("GET", "X/abc123/public.txt", ("file", "public.txt", "/public.txt")),
    ("GET", "X/abc123/docs/", ("text", "200")),
]
# Paths that exist at the share root's TEXT & the path, no separator between: folders
# BESIDE the root whose names begin with its name (the gate builds each as the root's
# basename & the path, next to the root). "-backup" is any such sibling; "3" is the one
# the clearweb rows' old offset reached, the last char of CW_TOKEN. Nothing here is
# servable: each exists only so the anchor rows above can fail on the old code.
OUTSIDE_TREE = ["-backup/secret.txt", "3/public.txt"]


def unanchored_disk_rel(raw):
    """What the pre-2026-09-27 Tor path joined to the root's text: the decoded target,
    unanchored. Not a mirror of anything shipped: the anchor rows' witness."""
    return unquote_plus(raw).replace("\\", "/")


def offset_rest(path, token):
    """The rest the first 2026-09-27 qsCwServe took, char (len(token) + 2) to -1 (1-based),
    which is right only when the target starts with "/". The anchor rows' witness."""
    return path[len(token) + 1:]
# (folder, the names on disk there) for the listing rows: SERVE_TREE's own folders
LISTING_FOLDERS = ["", "docs", "sub", ".git"]
# (rel path the editor is asked to write, the pinned (status, body))
EDIT_WRITE_ROWS = [
    ("notes.txt", (200, "Saved.")),
    ("docs/new.md", (200, "Saved.")),
    (".env", (400, "Hidden (dot) paths cannot be written through the editor.")),
    (".git/config", (400, "Hidden (dot) paths cannot be written through the editor.")),
    ("sub/.hidden/x.txt", (400, "Hidden (dot) paths cannot be written through the editor.")),
    ("docs/./new.md", (400, "Hidden (dot) paths cannot be written through the editor.")),
    ("docs", (409, "That path is a folder.")),
    ("../x.txt", (400, "Bad path.")),
    ("", (400, "Bad path.")),
    # a backslash is a separator to qsEditSafePath, so the dot check reads it as one
    # (2026-09-27, the review: read raw, each of these three was written)
    ("\\.env", (400, "Hidden (dot) paths cannot be written through the editor.")),
    ("sub\\.hidden\\x.txt", (400, "Hidden (dot) paths cannot be written through the editor.")),
    ("docs\\.secret.txt", (400, "Hidden (dot) paths cannot be written through the editor.")),
    ("docs\\new2.md", (200, "Saved.")),       # ... and refuses nothing by being one
]
RESERVED_ROWS = [
    ("/_qs", True), ("/_qs/info", True), ("/_qs/", True),
    ("/_edit", True), ("/_edit/api/write", True),
    ("/_qsx", False),                       # a longer first segment is a normal path
    ("/_editor", False),
    ("/a/_qs", False),                      # reserved only at the ROOT of the app path
    ("/_q", False), ("/", False), ("", False),
    # folded ON PURPOSE, stricter than the case-exact route table
    ("/_QS", True), ("/_QS/info", True), ("/_Qs/", True),
    ("/_EDIT", True), ("/_Edit/api/write", True),
    ("/_QSX", False), ("/_EDITOR", False),
]


def listing_names(folder, tree=None):
    """The names `the files` and `the folders` answer for `folder` of SERVE_TREE (the
    engine lists ".." among the folders; the gate's model does too)."""
    tree = SERVE_TREE if tree is None else tree
    prefix = (folder + "/") if folder else ""
    names = set([".."])
    for t in tree:
        if not t.startswith(prefix):
            continue
        rest = t[len(prefix):]
        head = rest.split("/")[0]
        if head:
            names.add(head)
    return sorted(names)


# The rows main() pins and tools/check-script-vectors.py drives against the demo:
# listed ONCE here, so the gate never types an input twice.
RANGE_ROWS = [
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
]

TRAVERSAL_ROWS = [
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
]

DOT_ROWS = [
    ("/", False),
    ("", False),
    ("/file.txt", False),                   # dot INSIDE a name is fine
    ("/notes.d/file", False),               # ...and inside a folder name
    ("/a/b.txt", False),
    ("/.git/config", True),
    ("/a/.env", True),
    ("/dir/.hidden/", True),
    ("/.", True),
    ("/.well-known/x", True),               # wholesale policy: hidden is hidden
]

MIME_ROWS = [
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
]

CAPABILITY_ROWS = [
    ("/abc123/", (True, "/")),                 # folder root
    ("/abc123", (True, "/")),                  # no trailing slash -> root
    ("/abc123/sub/", (True, "/sub/")),         # a subfolder
    ("/abc123/a/b.txt", (True, "/a/b.txt")),   # a nested file
    ("/abc123/photo.jpg", (True, "/photo.jpg")),
    ("X/abc123/sub/", (True, "/sub/")),        # no leading "/": the rest still anchored
    ("/wrongtoken/", (False, "/")),            # bad token -> 404
    ("/", (False, "/")),                       # bare root, no token -> 404
    ("", (False, "/")),                        # empty -> 404
    ("/abc123/../etc", "forbidden"),           # traversal refused first
]

SPA_ROWS = [
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
]

EDIT_SAFE_ROWS = [
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
]

ICON_ROWS = [
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
]

LAN_ROWS = [
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
]

HTML_ROWS = [
    ("<script>alert('x')</script>", "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"),
    ("a & <b>", "a &amp; &lt;b&gt;"),         # & first, so no entity is mangled twice
    ('say "hi"', "say &quot;hi&quot;"),
]

_GET_FULL = b"GET /_qs/info HTTP/1.1\r\nHost: x\r\n\r\n"
_POST_HDR = b"POST /api HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
FRAMING_ROWS = [                              # (label, request bytes, complete?)
    ("GET (no body)", _GET_FULL, True),
    ("incomplete head", b"GET / HTTP/1.1\r\nHost: x\r\n", False),
    ("post no body yet", _POST_HDR, False),
    ("post partial body", _POST_HDR + b"hel", False),
    ("post full body", _POST_HDR + b"hello", True),
    ("post over-long body still complete", _POST_HDR + b"helloEXTRA", True),
    ("post non-integer CL -> no body",
     b"POST /api HTTP/1.1\r\nContent-Length: abc\r\n\r\n", True),
]

JSON_ROWS = [
    ("hello", "hello"),
    ('a"b', 'a\\"b'),
    ("c:\\path", "c:\\\\path"),
    ("a\r\nb", "a\\r\\nb"),
    ("x\ty", "x\\ty"),
    ('\\"', '\\\\\\"'),                   # backslash before quote: order matters
]

QUERY_ROWS = [
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
]


def main():
    total = 1000
    # -- byte-range parsing --
    for rng, want in RANGE_ROWS:
        check("parse_range(%r)" % rng, parse_range(rng, total), want)

    # empty file (total 0): any concrete range is unsatisfiable; no range -> ""
    check("parse_range empty-file no-range", parse_range("", 0), "")
    check("parse_range empty-file 0-", parse_range("bytes=0-", 0), "unsatisfiable")

    # -- path-traversal decision --
    for raw, ok in TRAVERSAL_ROWS:
        check("traversal_ok(%r)" % raw, traversal_ok(raw), ok)

    # -- dotfile guard: dot-leading segments are invisible to the static paths --
    for path, want in DOT_ROWS:
        check("has_dot_segment(%r)" % path, has_dot_segment(path), want)

    # -- the reserved namespaces (nocloud's rows, ported with the guard 2026-09-27) --
    for path, want in RESERVED_ROWS:
        check("reserved_path(%r)" % path, reserved_path(path), want)

    # -- the static pipeline's whole decision, both transports, over SERVE_TREE --
    for method, raw, shared, want in SERVE_ROWS:
        check("serve_static(%s %s%s)" % (method, raw, "" if shared else ", nothing shared"),
              serve_static(method, raw, SERVE_TREE, SERVE_ROUTES, shared), want)
    for method, raw, want in CW_ROWS:
        check("serve_static(cw %s %s)" % (method, raw),
              serve_static(method, raw, SERVE_TREE, SERVE_ROUTES, True, CW_TOKEN), want)
    # the refusal rows are refusal rows: without its guard each would be answered from
    # disk or by the SPA fallback (a row the old pipeline 404ed too would prove nothing)
    dirs, files = _tree_sets(SERVE_TREE)
    for method, raw, shared, want in SERVE_ROWS:
        path = unquote_plus(raw)
        if shared and want == ("text", "404") and (has_dot_segment(path)
                                                    or reserved_path(path)):
            check("witness: %s %s is on disk or would reach the SPA" % (method, raw),
                  path.strip("/") in dirs | files or spa_is_route(path), True)
    # the anchor rows are escape rows: the old join of the root's text and the target
    # named a real path OUTSIDE the share, and a row that named nothing would prove nothing
    outside = set(OUTSIDE_TREE) | set(t.rsplit("/", 1)[0] + "/" for t in OUTSIDE_TREE)
    anchored = [r for r in SERVE_ROWS if not r[1].startswith("/") and r[2]]
    check("the Tor anchor rows exist", len(anchored) >= 4, True)
    check("witness: some Tor anchor row once reached OUTSIDE_TREE",
          any(unanchored_disk_rel(raw) in outside for _, raw, _, _ in anchored), True)
    for method, raw, _, want in anchored:
        if unanchored_disk_rel(raw) in outside:
            check("witness: %s %s is not served from outside" % (method, raw),
                  want[0] != "file" or want[1] != unanchored_disk_rel(raw), True)
    cw_anchored = [r for r in CW_ROWS if not r[1].startswith("/")]
    check("witness: some clearweb anchor row's old offset reached OUTSIDE_TREE",
          any(offset_rest(raw, CW_TOKEN) in outside for _, raw, _ in cw_anchored), True)
    for _, raw, _ in cw_anchored:
        check("capability_route(%r) anchors the rest at '/'" % raw,
              capability_route(raw, CW_TOKEN)[1].startswith("/"), True)

    # -- the listing hides every dot-leading name --
    check("listing_visible(root)", listing_visible(listing_names("")),
          ["_Edit", "_qs", "docs", "index.html", "notes.d", "public.txt", "site", "sub"])
    check("listing_visible(sub)", listing_visible(listing_names("sub")), ["a.txt"])
    check("listing_visible(.git)", listing_visible(listing_names(".git")), ["config"])

    # -- the editor's write refusals --
    for rel, want in EDIT_WRITE_ROWS:
        check("edit_write_decision(%r)" % rel, edit_write_decision(rel, SERVE_TREE), want)
    # the backslash rows are bypass rows: a raw read of each misses the dot, and the
    # confinement still WRITES a dot path (so each can fail on the raw check)
    slashed = [(rel, want) for rel, want in EDIT_WRITE_ROWS if "\\" in rel and want[0] == 400]
    check("the editor's backslash dot rows exist", len(slashed) >= 3, True)
    for rel, _ in slashed:
        check("witness: %r slips past a raw dot check into a dot path" % rel,
              (has_dot_segment(rel), has_dot_segment(edit_safe_path("/srv", rel)[5:])),
              (False, True))

    # -- MIME mapping (extension is case-insensitive; unknown -> octet-stream) --
    for path, want in MIME_ROWS:
        check("mime(%r)" % path, mime(path), want)

    # -- HTML escaping (& first so an existing entity is not double-mangled wrong) --
    for text, want in HTML_ROWS:
        check("html_escape(%r)" % text, html_escape(text), want)

    # -- clearweb capability gate (the /<token>/ prefix) --
    tok = "abc123"
    for path, want in CAPABILITY_ROWS:
        check("capability_route(%r)" % path, capability_route(path, tok), want)

    # -- SPA fallback: is an unresolved path a client-side route or a missing asset? --
    for path, want in SPA_ROWS:
        check("spa_is_route(%r)" % path, spa_is_route(path), want)

    # -- HTTP request framing (head terminator + Content-Length body) --
    check("header_end GET", http_header_end(_GET_FULL), _GET_FULL.find(b"\r\n\r\n") + 1)
    check("header_end incomplete head", http_header_end(b"GET / HTTP/1.1\r\nHost: x\r\n"), 0)
    for label, data, want in FRAMING_ROWS:
        check("http_req_complete " + label, http_req_complete(data), want)

    # -- JSON value escaping (for the /_qs/info route) --
    for text, want in JSON_ROWS:
        check("json_escape(%r)" % text, json_escape(text), want)

    # -- editor write-path confinement (THE security linchpin) --
    R = "/srv"
    for rel, want in EDIT_SAFE_ROWS:
        check("edit_safe_path(%r)" % rel, edit_safe_path(R, rel), want)

    # -- directory-listing icon classification --
    for name, is_dir, want in ICON_ROWS:
        check("fs_icon(%r)" % name, fs_icon(name, is_dir), want)

    # -- editor LAN-first gate (only local peers may reach the editor) --
    for conn, want in LAN_ROWS:
        check("edit_is_local(%r)" % conn, edit_is_local(conn), want)

    # -- query-string value extraction (editor read/write ?path=) --
    for query, name, want in QUERY_ROWS:
        check("query_param(%r,%r)" % (query, name), query_param(query, name), want)

    # -- the case-exact route keys (2026-09-25) and the lookup --
    for text, want in HEX_ROWS:
        check("hex_key(%r)" % text, hex_key(text), want)
    for text in ("GET /api/x", "/caf\u00e9", "PUT /_EDIT/API", "\x00\xff"):
        check("hex_key(%r) has no case left to fold" % text,
              hex_key(text) == hex_key(text).lower() and all(c in "0123456789abcdef"
                                                            for c in hex_key(text)), True)
    check("route_key upper-cases the method", route_key("get", "/api/x"), "474554202f6170692f78")
    check("route_key keeps the path's case",
          route_key("GET", "/_EDIT") != route_key("GET", "/_edit"), True)
    for method, path, keys, want in LOOKUP_ROWS + ODD_ROWS:
        check("route_lookup_key(%r,%r)" % (method, path),
              route_lookup_key(method, path, table(keys)), rk(want) if want else "")
    for method, path, keys in FOLD_ROWS:
        check("fold witness: %s %s collided under the old raw key" % (method, path),
              old_raw_lookup_hits(method, path, keys), True)
        check("route_lookup_key(%r,%r) folds nothing" % (method, path),
              route_lookup_key(method, path, table(keys)), "")

    if _fail:
        print("fileserver_golden: FAIL\n" + "\n".join(_fail))
        return 1
    print("fileserver_golden: OK (range parse, traversal guard, dotfile guard, reserved "
          "namespaces, the static decision on both transports, the listing, the editor's "
          "write refusals, MIME, icon classify, HTML escape, capability gate, SPA "
          "fallback, HTTP framing, JSON escape, editor confinement, LAN-first gate, query "
          "parse, case-exact route keys + HEAD route lookup + fold rows all match)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
