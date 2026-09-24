#!/usr/bin/env python3
"""check-script-vectors.py - RUN the shipped Model C receive paths of the two
torrentxt demos headlessly, against tests/onion_frame_golden.py's mirrors and
the committed SodiumXT library.

WHY THIS EXISTS. tests/onion_frame_golden.py pins the Model C wire format with
a pure-Python MIRROR of each script handler, and a mirror is somebody's
reading of the script. Before 2026-09-24 nothing held that reading to the
text: the only tool that had ever read examples/torrent-quickshare and
examples/torrent-dht-channels was the static checker, which cannot tell
whether qsOnionRecvData refuses a 1025-byte name before or after waiting for
it. The golden's own first reassemble() is the proof that a reading drifts: it
took the stream WHOLE while its comment said "awkward chunk boundaries". The
family closed this gap member by member with gates of this shape (coinxt,
nostrxt, riptide, nocloud, holde-em); this is torrentxt's, written for the
work plan's Model C test row (docs/WORK-PLAN.md, torrentxt coding row 9):

  1. THE BTXO RECEIVER. qsOnionRecvData (torrent-quickshare) and
     chOnionRecvData (torrent-dht-channels), driven through their real stream
     callbacks - qsOnionRecvStream and chOnionFetchStream, "data" events then
     "closed" - on the golden's own streams: whole; cut in half across the
     header, across a DATA payload, across a frame length, all at once; every
     two-read cut of a small three-frame stream; one byte at a time; and the
     cap, finish and downgrade rows. Each outcome must EQUAL the golden
     Receiver's. qsOnionRecvFinish / chOnionRecvFinish run for real too.
  2. qsKeyOpensVerifier [tier 2] on keys the committed SodiumXT derives
     (sxPwHash, Argon2id) and verifiers it seals: the right passphrase opens;
     a wrong passphrase, a tampered box and a truncated one do not. The pinned
     Argon2id outputs and verifier in the golden are re-derived here, and the
     golden's cipher must open what the library sealed.
  3. qsReceiveOnion [tier 2], the whole parse up to the dial, on the complete
     locked code and on EVERY truncation of it: the script's decision (refuse
     / plaintext prompt then a keyless dial / verified dial) must equal
     receive_onion_route()'s - which pins the finding recorded there.
  4. THE M9 NONCE-FRESHNESS KAT [tier 2], on the real library: the shipped
     chFeedValue seals one feed twice under one key; the two values differ
     (in their nonces) and EACH opens, through the shipped chReadFeed and
     through the golden's independent cipher. Then chOnionPushFeed, pushed
     twice to two subscribers: one push fans ONE value out, and the second
     push re-seals rather than resending the first (design 6.4: "every push
     RE-SEALS through chFeedValue, never a cached nonce").

WHAT IT IS NOT. An approximation of the engine, not the engine: riptide's
runner over the family interpreter. Nothing here promotes any label past
"verified statically; needs an OXT pass" - what it settles is LOGIC, not
parser behaviour. If this gate and the engine disagree, the engine is right.

THE MODEL EXTENSIONS AND STAND-INS, declared rather than discovered:
  - `bitAnd` (both receivers test kFlagEnc with it) is a tier between the
    comparisons and `and`, the engine's precedence; `delete byte A to B of X`
    is the base's `delete char` range, since bytes and chars coincide in a
    model where every value is a latin-1 string (the interpreter's own rule).
  - File I/O is intercepted at statement level: `open file ... for binary
    write`, `write ... to file`, `close file` record into memory, answering
    an empty `the result`. qsMoveFile / chMoveFile / qsDecryptFile /
    chDecryptFile record the finish instead of touching a disk.
  - `<pfx>OnionRecvAbort` records its message and runs the demo's real
    `<pfx>OnionRecvClear`; qsLog / chLog, oxWrite, oxCloseStream, oxDial,
    oxSetStreamCallback, `answer` and `select` are recorded. `answer ... with
    "Cancel" or "Download anyway"` answers "Download anyway", so a plaintext
    prompt is followed to its dial - the path the finding in (3) is about.
  - oxIsValidAddress is the golden's onion_valid() (OnionXT's function is
    script, mirrored there with the checksum on), qsOnionReadyNow is true, and
    btDhtKeypair (TorrentXT) maps the one row channel's seed to its public
    key. None of the three decides a row's outcome except as named.
  - The free-disk pre-check (design 3.3, built 2026-09-24): `the
    defaultFolder` reads, and `set the defaultFolder to X` sets, one model
    folder (the sandbox to start with); setting it to a path that is not a
    folder leaves it alone and answers a non-empty `the result`, the stand-in
    for the engine's refusal. diskSpace() answers a free-bytes figure the gate
    sets (plentiful unless a row says otherwise) for whatever folder is
    current, and records which folder each call measured. One disk, so the
    helpers' two measurements (temp and save folder) read the same figure.
  - The golden's u64-maximum totalLen row is not driven: the interpreter
    REFUSES integers past 2^53 by design (its header), where the engine
    computes 2^64 - 1 as a double that still exceeds kOnionMaxTotal.

THE SIBLINGS, AND HOW THEY ARE FOUND (docs/MEMBER-REPO-SPLIT.md): riptide
for the runner (which loads nostrxt's interpreter and oracle at import, so
nostrxt is needed too), and sodiumxt for the committed library tier 2 calls,
    <sodiumxt>/src/code/x86_64-linux/sodiumxt.so
resolved by sibling() below: the directory beside this member in the suite
tree, the repository cloned beside it in a standalone checkout, or wherever
XTALK_SIBLING_<NAME> / XTALK_SIBLINGS point. An absent runner stops the gate
(exit 2, the clone to run). An absent or unloadable library SKIPS tier 2
loudly; with XTALK_REQUIRE_SIBLINGS=1 that skip is a failure.

tools/test-script-vectors.py edits one defect at a time into copies of the
demos and requires this gate to fail naming it - a gate that went blind would
otherwise print OK.

Usage:
  python3 tools/check-script-vectors.py                  # per-section detail
  python3 tools/check-script-vectors.py --check          # terse
  python3 tools/check-script-vectors.py --qs PATH --ch PATH   # drive copies
"""
import ctypes
import importlib.util
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MEMBER = os.path.dirname(HERE)


def sibling(name):
    """Path of a sibling member's checkout (docs/MEMBER-REPO-SPLIT.md): the
    directory beside this member in the suite tree, or the repository cloned
    beside it in a standalone checkout. XTALK_SIBLING_<NAME> (one member) and
    XTALK_SIBLINGS (a directory holding them all) override, in that order. A
    member is never its own sibling."""
    if name == os.path.basename(MEMBER):
        return MEMBER
    one = os.environ.get("XTALK_SIBLING_" + name.upper().replace("-", "_"))
    if one:
        return one
    return os.path.join(os.environ.get("XTALK_SIBLINGS")
                        or os.path.dirname(MEMBER), name)


SIBLING_REPOS = {
    "riptide": "https://github.com/SethMorrowSoftware/RipTide",
    "sodiumxt": "https://github.com/SethMorrowSoftware/SodiumXT",
}


def sibling_missing(name, path):
    return ("%s is not present: it belongs to the %s member, which is not "
            "beside this checkout. Clone %s beside this checkout as ../%s, or "
            "point XTALK_SIBLING_%s / XTALK_SIBLINGS at it."
            % (path, name, SIBLING_REPOS[name], name, name.upper()))


QS_DEMO = os.path.join(MEMBER, "examples", "torrent-quickshare.livecodescript")
CH_DEMO = os.path.join(MEMBER, "examples", "torrent-dht-channels.livecodescript")
GOLDEN = os.path.join(MEMBER, "tests", "onion_frame_golden.py")
RUNNER = os.path.join(sibling("riptide"), "tools", "check-demo-boot.py")
SODIUM_SO = os.path.join(sibling("sodiumxt"), "src", "code", "x86_64-linux",
                         "sodiumxt.so")
if not os.path.isfile(RUNNER):
    print("check-script-vectors: " + sibling_missing("riptide", RUNNER),
          file=sys.stderr)
    sys.exit(2)

# Per-section ratchets, not targets: a section that ran fewer rows than its
# floor silently stopped executing part of itself (a case list that went empty,
# a loop that no longer iterates), and the run must fail, not print OK. Keyed
# by the section's first word; measured 2026-09-24.
FLOORS = {"qsOnionRecvData": 105, "chOnionRecvData": 105, "pins": 6,
          "qsKeyOpensVerifier": 11, "qsReceiveOnion": 177, "M9": 18,
          "qsDiskGuard": 16, "chDiskGuard": 16}


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DB = _load("tx_demo_boot", RUNNER)
LCS = DB.LCS
G = _load("tx_onion_golden", GOLDEN)
Thrown = LCS.Thrown


def to_bytes(v):
    return str(LCS._disp(v)).encode("latin-1")


def to_str(b):
    return bytes(b).decode("latin-1")


def boolish(v):
    if isinstance(v, bool):
        return v
    return str(v).lower() == "true"


# --------------------------------------------------------------------------
# the model extensions (see the header)

class TxExpr(DB.DemoExpr):
    def p_atom(self):
        # `the defaultFolder` (the free-disk pre-check reads it to put it back)
        self.ws()
        m = DB._rxi(r'the\s+defaultFolder\b').match(self.s[self.i:])
        if m:
            self.i += m.end()
            return self.ip.default_folder
        return super().p_atom()

    def p_not(self):
        if self.kw("not"):
            return not self.ip.truth(self.p_not())
        v = self.p_cmp()
        while True:
            save = self.i
            if self.kw("bitand"):
                r = self.p_cmp()
                v = LCS._exact(int(LCS._n(v)) & int(LCS._n(r)))
            else:
                self.i = save
                return v


class TxInterp(DB.DemoInterp):
    """One demo, with the intercepts in the header. `prefix` is "qs" or "ch"."""

    def __init__(self, src, world, prefix):
        self.prefix = prefix
        self.files = {}          # path -> bytearray (what the script wrote)
        self.aborts = []         # the <pfx>OnionRecvAbort messages
        self.logs = []           # qsLog / chLog texts
        self.writes = []         # (stream, bytes) handed to oxWrite
        self.dials = []          # (onion, stream id handed back)
        self.prompts = []        # `answer` texts
        self.answer_reply = "Download anyway"
        self.next_stream = 900
        self.default_folder = world_sandbox(world)
        self.disk_free = 1 << 50  # plentiful; a disk-guard row lowers it
        self.disk_queries = []   # the defaultFolder at each diskSpace() call
        super().__init__(src, world)

    def disk_space(self, args):
        self.disk_queries.append(self.default_folder)
        return self.disk_free

    def eval_expr(self, expr, env):
        return TxExpr(self, env).parse(expr)

    def args(self, rest, env):
        out = []
        rest = rest.strip()
        if not rest:
            return out
        p = TxExpr(self, env)
        p.s, p.i = rest, 0
        while True:
            out.append(p.p_or())
            p.ws()
            if p.i < len(p.s) and p.s[p.i] == ",":
                p.i += 1
                continue
            break
        if p.i < len(p.s):
            raise SyntaxError("trailing input in call %r" % rest)
        return out

    def _exec_stmt(self, body, i, env):
        line = body[i].strip()
        world = self.world
        m = re.match(r'open\s+file\s+(.+?)\s+for\s+binary\s+write$', line, re.I)
        if m:
            self.files[str(LCS._disp(self.eval_expr(m.group(1), env)))] = bytearray()
            world.result = ""
            return i + 1
        m = re.match(r'write\s+(.+?)\s+to\s+file\s+(.+)$', line, re.I)
        if m:
            data = to_bytes(self.eval_expr(m.group(1), env))
            path = str(LCS._disp(self.eval_expr(m.group(2), env)))
            self.files.setdefault(path, bytearray()).extend(data)
            world.result = ""
            return i + 1
        if re.match(r'close\s+file\b', line, re.I):
            return i + 1
        m = re.match(r'delete\s+byte\s+(.+?)\s+to\s+(.+?)\s+of\s+(.+)$', line, re.I)
        if m:
            a = int(LCS._n(self.eval_expr(m.group(1), env)))
            b = int(LCS._n(self.eval_expr(m.group(2), env)))
            tgt = m.group(3).strip()
            s = str(LCS._disp(self.eval_expr(tgt, env)))
            self.assign(tgt, s[:a - 1] + s[b:], env)
            return i + 1
        m = re.match(r'(%sOnionRecvAbort)\s+(.+)$' % self.prefix, line, re.I)
        if m:
            a = self.args(m.group(2), env)
            self.aborts.append(str(LCS._disp(a[1])))
            self.call(self.prefix + "OnionRecvClear", [a[0]])
            return i + 1
        m = re.match(r'(qsLog|chLog)\b\s*(.*)$', line, re.I)
        if m:
            self.logs.append(" ".join(str(LCS._disp(x)) for x in self.args(m.group(2), env)))
            return i + 1
        m = re.match(r'oxWrite\s+(.+)$', line, re.I)
        if m:
            a = self.args(m.group(1), env)
            self.writes.append((str(LCS._disp(a[0])), to_bytes(a[1])))
            world.result = ""
            return i + 1
        m = re.match(r'oxDial\s+(.+)$', line, re.I)
        if m:
            a = self.args(m.group(1), env)
            self.next_stream += 1
            self.dials.append((str(LCS._disp(a[0])), str(self.next_stream)))
            world.result = str(self.next_stream)
            return i + 1
        if re.match(r'(oxCloseStream|oxSetStreamCallback)\b', line, re.I):
            return i + 1
        m = re.match(r'answer\s+(.+?)\s+with\s+(.+)$', line, re.I)
        if m:
            self.prompts.append(str(LCS._disp(self.eval_expr(m.group(1), env))))
            env["it"] = self.answer_reply
            return i + 1
        if re.match(r'select\s+the\s+text\s+of\s+field\b', line, re.I):
            return i + 1
        m = re.match(r'set\s+the\s+defaultFolder\s+to\s+(.+)$', line, re.I)
        if m:
            path = str(LCS._disp(self.eval_expr(m.group(1), env)))
            if os.path.isdir(path):
                self.default_folder = path
                world.result = ""
            else:
                world.result = "can't open directory"
            return i + 1
        return super()._exec_stmt(body, i, env)


def world_sandbox(world):
    """The folder the model's `the defaultFolder` starts at: the runner's
    sandbox, whatever the World calls it."""
    for attr in ("sandbox", "root", "base"):
        v = getattr(world, attr, None)
        if isinstance(v, str) and os.path.isdir(v):
            return v
    return tempfile.gettempdir()


def _binary_encode(a):
    """binaryEncode for the two codes the Model C framing writes, "n" (a
    big-endian u16) and "N" (a big-endian u32), one argument per code - the
    engine's documented meaning of both. Any other code REFUSES: a guessed
    encoding would be a quiet wrong answer."""
    fmt = str(LCS._disp(a[0]))
    if not fmt or any(ch not in "nN" for ch in fmt) or len(a) != 1 + len(fmt):
        raise NotImplementedError("binaryEncode(%r) is outside the model" % fmt)
    out = b""
    for ch, v in zip(fmt, a[1:]):
        n = int(LCS._n(v))
        out += n.to_bytes(2 if ch == "n" else 4, "big")
    return to_str(out)


def load_demo(path, prefix, sandbox):
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    src = re.sub(r'^script\s+"[^"]*"[^\n]*\n', '', src, count=1)
    world = DB.World(sandbox)
    DB.install_engine_functions(world)
    LCS.HASHES["specialfolderpath"] = lambda a: world.special_folder(LCS._disp(a[0]))
    LCS.HASHES["binaryencode"] = _binary_encode
    ip = TxInterp(src, world, prefix)
    return ip


def setg(ip, name, key, value):
    """Write element `key` of the script-local array `name`."""
    low = name.lower()
    if not isinstance(ip.globals.get(low), dict):
        ip.globals[low] = {}
    ip.globals[low][str(key)] = value


def getg(ip, name, key):
    arr = ip.globals.get(name.lower())
    return arr.get(str(key), "") if isinstance(arr, dict) else ""


# --------------------------------------------------------------------------
# the checker

class Checker:
    def __init__(self, terse):
        self.terse = terse
        self.n = 0
        self.failed = []
        self.counts = {}          # section key -> rows it checked
        self.key = None

    def section(self, key, text):
        self.key = key
        self.counts.setdefault(key, 0)
        if not self.terse:
            print("-- %s" % text)

    def ck(self, label, got, want):
        self.n += 1
        if self.key is not None:
            self.counts[self.key] += 1
        if got != want:
            self.failed.append("%s:\n    script %r\n    mirror %r" % (label, got, want))

    def short(self):
        """Sections that ran fewer rows than their floor."""
        return ["%s ran %d rows (floor %d)" % (k, n, FLOORS[k])
                for k, n in sorted(self.counts.items()) if n < FLOORS[k]]


# --------------------------------------------------------------------------
# 1. the receiver

# The golden's abort tags, by the demo's own wording (a substring of the
# message each demo passes to its <pfx>OnionRecvAbort). A message that maps to
# no tag is reported as itself, so a reworded abort FAILS here, loudly.
ABORT_TAGS = [
    ("bad magic", "magic"),
    ("Unsupported Tor stream version", "version"),
    ("name too long", "name too long"),
    ("Refusing an oversized", "oversized"),
    ("arrived unencrypted", "downgrade"),
    ("had no passphrase", "no passphrase"),       # qs
    ("no passphrase is set", "no passphrase"),    # ch
    ("frame too large", "frame too large"),
    ("incomplete", "incomplete"),
    ("went offline", "offline"),
    ("Not enough free disk space", "disk full"),
    ("is not currently available", "not available"),   # ch: a zero-total reply
]


def abort_tag(msg):
    for needle, tag in ABORT_TAGS:
        if needle in msg:
            return tag
    return "unmapped: " + msg


def drive_receiver(ip, sandbox, wire, cuts=(), key=None, code_name="shared-file"):
    """Seed a stream the way the demo's own dial handler does (qsReceiveOnion,
    chOnionDownload), feed it through the real stream callback in the reads
    `cuts` makes, close it, and read back what the script did - in the
    golden's outcome shape."""
    ip.next_stream += 1
    s = str(ip.next_stream)
    setg(ip, "sRxState", s, "header")
    setg(ip, "sRxBuf", s, "")
    setg(ip, "sRxGot", s, 0)
    setg(ip, "sRxName", s, code_name)
    setg(ip, "sRxSave", s, sandbox)
    setg(ip, "sRxKey", s, to_str(key) if key else "")
    if ip.prefix == "ch":
        setg(ip, "sOnRole", s, "download")
    callback = "qsOnionRecvStream" if ip.prefix == "qs" else "chOnionFetchStream"
    ip.aborts = []
    finished = []
    for nm in ("movefile", "decryptfile"):
        def stub(a, kind=nm):
            finished.append((kind, str(LCS._disp(a[0])), str(LCS._disp(a[1]))))
            return ""
        LCS.HASHES[ip.prefix + nm] = stub
    LCS.HASHES["diskspace"] = ip.disk_space   # per drive: both demos share HASHES
    for piece in G.split_at(wire, cuts):
        ip.call(callback, [s, "data", to_str(piece)])
    ip.call(callback, [s, "closed", ""])
    ip.world.sends = []
    if finished:
        kind, src, dst = finished[-1]
        return ("saved", os.path.basename(dst), kind == "decryptfile",
                bytes(ip.files.get(src, b"")))
    if ip.aborts:
        return ("abort", abort_tag(ip.aborts[0]))
    return None


def receiver_cases():
    """(label, wire, cuts, key, code_name) - the golden's streams, built by
    the golden's own constructors, so no byte here is typed twice."""
    h, fr, term = G.header, G.frame, G.terminator
    CH = G.CHUNK
    payload = bytes((i * 7) % 256 for i in range(100000))
    wire = h(b"movie.bin", False, len(payload))
    off = 0
    while off < len(payload):
        wire += fr(payload[off:off + CH])
        off += CH
    wire += term()
    hlen = 8 + len(b"movie.bin") + 8
    small = (h(b"clip.bin", False, 300) + fr(bytes(range(100)))
             + fr(bytes(range(150))) + fr(bytes(range(50))) + term())
    enc_stream = h(b"report.pdf", True, 5) + fr(b"CIPHR") + term()
    K = G.ARGON_KEY_RIGHT
    cases = [
        ("whole multi-frame stream", wire, (), None, "shared-file"),
        ("header cut in half", wire, (hlen // 2,), None, "shared-file"),
        ("DATA payload cut in half", wire, (hlen + 4 + CH // 2,), None, "shared-file"),
        ("both cuts, three reads", wire, (hlen // 2, hlen + 4 + CH // 2), None,
         "shared-file"),
        ("a frame length cut in half", wire, (hlen + 2, hlen + 4 + CH + 1), None,
         "shared-file"),
        ("8 KiB reads", wire, tuple(range(8192, len(wire), 8192)), None,
         "shared-file"),
        ("small stream, 7-byte reads", small, tuple(range(7, len(small), 7)), None,
         "shared-file"),
        ("small stream, one byte at a time", small, tuple(range(1, len(small))), None,
         "shared-file"),
        ("nameLen 1024 accepted", h(b"n" * G.MAX_NAME, False, 1) + fr(b"z") + term(), (),
         None, "shared-file"),
        ("nameLen 1025: the prologue alone", h(b"n" * (G.MAX_NAME + 1), False, 1)[:8], (),
         None, "shared-file"),
        ("nameLen 65535: the prologue alone",
         G.MAGIC + bytes([G.VER, 0, 0xFF, 0xFF]), (), None, "shared-file"),
        ("totalLen 8 GiB accepted, then the sender closes",
         h(b"x", False, G.MAX_TOTAL), (), None, "shared-file"),
        ("totalLen 8 GiB + 1", h(b"x", False, G.MAX_TOTAL + 1), (), None, "shared-file"),
        ("saved without its terminator", h(b"a", False, 3) + fr(b"abc"), (), None,
         "shared-file"),
        ("an early terminator", h(b"a", False, 3) + fr(b"ab") + term(), (), None,
         "shared-file"),
        ("more bytes than promised", h(b"a", False, 2) + fr(b"abc") + term(), (), None,
         "shared-file"),
        ("the sender gone mid-body", h(b"a", False, 3) + fr(b"ab"), (), None,
         "shared-file"),
        ("bytes after the finish", h(b"a", False, 1) + fr(b"z") + term() + b"junk", (),
         None, "shared-file"),
        ("an oversized frame length", h(b"a", False, 10) + b"\x00\x01\x00\x01", (),
         None, "shared-file"),
        ("the header name, through SafeLeaf", h(b"../../x.txt", False, 1) + fr(b"z"), (),
         None, "from-code"),
        ("an empty header name keeps the code's", h(b"", False, 1) + fr(b"z"), (), None,
         "from-code"),
        ("an empty file", h(b"empty", False, 0) + term(), (), None, "shared-file"),
        ("bad magic", b"BTXX" + h(b"a", False, 1)[4:], (), None, "shared-file"),
        ("bad version", G.MAGIC + b"\x02" + h(b"a", False, 1)[5:], (), None,
         "shared-file"),
        ("a key, a plaintext header (downgrade)", h(b"r", False, 1) + fr(b"z"), (), K,
         "shared-file"),
        ("no key, an encrypted header", enc_stream, (), None, "shared-file"),
        ("an encrypted stream with its key", enc_stream, (), K, "shared-file"),
        ("an encrypted stream, header cut in half", enc_stream, (9,), K, "shared-file"),
    ]
    # Two-read cuts of the small stream: every offset through the header and
    # the first frame's length (where the parse has the most to get wrong),
    # every offset around each later frame boundary, and a stride between.
    # The golden walks EVERY cut in pure Python; here each cut is a whole
    # interpreted run, and the byte-at-a-time case above already puts a read
    # boundary at every offset of this stream.
    shdr = 8 + len(b"clip.bin") + 8
    bounds = [shdr + 4 + 100, shdr + 8 + 250, shdr + 12 + 300]
    cuts = set(range(1, shdr + 6))
    for b in bounds:
        cuts.update(range(b - 2, b + 6))
    cuts.update(range(shdr + 6, len(small), 11))
    for c in sorted(x for x in cuts if 0 < x < len(small)):
        cases.append(("small stream cut at %d" % c, small, (c,), None, "shared-file"))
    return cases


def check_receiver(c, ip, sandbox):
    c.section(ip.prefix + "OnionRecvData",
              "%sOnionRecvData against the golden Receiver" % ip.prefix)
    for label, wire, cuts, key, code_name in receiver_cases():
        want = G.receive(wire, cuts, key=key, code_name=code_name,
                         channels=(ip.prefix == "ch")).outcome
        got = drive_receiver(ip, sandbox, wire, cuts, key, code_name)
        c.ck("%sOnionRecvData: %s" % (ip.prefix, label), got, want)


def check_disk_guard(c, ip, sandbox):
    """The free-disk pre-check (design 3.3) the 2026-09-24 demo pass built:
    a transfer the disk cannot hold is refused BEFORE the temp file opens,
    an encrypted one needs twice its size, exactly-enough passes, an
    unmeasurable disk is not a refusal, and the defaultFolder the helper
    borrows is always put back."""
    key = ip.prefix + "DiskGuard"
    c.section(key, "%s free-disk pre-check (design 3.3)" % ip.prefix)
    h, fr, term = G.header, G.frame, G.terminator
    plain = (h(b"clip.bin", False, 300) + fr(bytes(range(100)))
             + fr(bytes(range(150))) + fr(bytes(range(50))) + term())
    enc = h(b"report.pdf", True, 5) + fr(b"CIPHR") + term()
    K = G.ARGON_KEY_RIGHT
    rows = [
        # (label, wire, key, free bytes, the expected outcome, or None for the golden's)
        ("one byte short of a 300-byte file", plain, None, 299, ("abort", "disk full")),
        ("exactly enough for a 300-byte file", plain, None, 300, None),
        ("an encrypted 5-byte file with 9 free (it needs 10)", enc, K, 9,
         ("abort", "disk full")),
        ("an encrypted 5-byte file with 10 free", enc, K, 10, None),
        ("an unmeasurable disk (diskSpace answers empty) is not a refusal",
         plain, None, "", None),
    ]
    saved_free = ip.disk_free
    try:
        for label, wire, k, free, want in rows:
            if want is None:
                want = G.receive(wire, (), key=k, channels=(ip.prefix == "ch")).outcome
            ip.disk_free = free
            ip.disk_queries = []
            before = set(ip.files)
            got = drive_receiver(ip, sandbox, wire, (), k)
            c.ck("%s: %s" % (key, label), got, want)
            c.ck("%s: %s - diskSpace() was asked" % (key, label),
                 len(ip.disk_queries) > 0, True)
            c.ck("%s: %s - the defaultFolder is put back" % (key, label),
                 ip.default_folder, world_sandbox(ip.world))
            if want[0] == "abort":
                c.ck("%s: %s - refused before any temp file opened" % (key, label),
                     sorted(set(ip.files) - before), [])
                if k is not None:
                    c.ck("%s: %s - the refusal says why it needs twice" % (key, label),
                         any("twice" in a for a in ip.aborts), True)
    finally:
        ip.disk_free = saved_free


# --------------------------------------------------------------------------
# tier 2: the committed SodiumXT

class Sodium:
    """The committed library's sxt_* entry points as the script's sx* natives
    (the .lcb's job, done in Python: a negative return THROWS, as sFinish
    does). sxPwHash is memoized by its inputs - Argon2id is deterministic and
    64 MiB a call - which the script cannot observe."""

    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        self.lib.sxt_abi_version.restype = ctypes.c_int
        self.pw_memo = {}

    def _buf(self, fn, cap, *args):
        out = ctypes.create_string_buffer(max(1, cap))
        n = fn(out, cap, *args)
        if n < 0:
            raise Thrown("SodiumXT: %s failed (%d)" % (fn.__name__, n))
        return out.raw[:n]

    def secretbox(self, msg, key):
        return self._buf(self.lib.sxt_secretbox, len(msg) + 128, msg, len(msg),
                         key, len(key))

    def secretbox_open(self, box, key):
        return self._buf(self.lib.sxt_secretbox_open, len(box) + 1, box, len(box),
                         key, len(key))

    def pwhash(self, pw, salt, n, ops, mem):
        k = (pw, salt, n, ops, mem)
        if k not in self.pw_memo:
            self.pw_memo[k] = self._buf(self.lib.sxt_pwhash, n + 1, n, pw, len(pw),
                                        salt, len(salt), ops.encode(), mem.encode())
        return self.pw_memo[k]

    def mem_interactive(self):
        return self._buf(self.lib.sxt_pwhash_memlimit_interactive, 32).decode("ascii")

    def kdf(self, master, subkey_id, ctx, n):
        return self._buf(self.lib.sxt_kdf_derive, n + 1, n, subkey_id.encode("ascii"),
                         ctx, len(ctx), master, len(master))

    def hex2bin(self, hexbytes):
        return self._buf(self.lib.sxt_hex2bin, len(hexbytes) + 1, hexbytes,
                         len(hexbytes))

    def install(self):
        LCS.HASHES.update({
            "sxsecretbox": lambda a: to_str(self.secretbox(to_bytes(a[0]), to_bytes(a[1]))),
            "sxsecretboxopen": lambda a: to_str(self.secretbox_open(to_bytes(a[0]),
                                                                    to_bytes(a[1]))),
            "sxpwhash": lambda a: to_str(self.pwhash(
                to_bytes(a[0]), to_bytes(a[1]), int(LCS._n(a[2])),
                str(LCS._disp(a[3])), str(LCS._disp(a[4])))),
            "sxpwmeminteractive": lambda a: self.mem_interactive(),
            "sxkdfderive": lambda a: to_str(self.kdf(to_bytes(a[0]), str(LCS._disp(a[1])),
                                                     to_bytes(a[2]), int(LCS._n(a[3])))),
            "sxhex2bin": lambda a: to_str(self.hex2bin(to_bytes(a[0]))),
        })


def check_pins(c, sx):
    """The golden's pinned crypto inputs, re-derived on the real library, and
    the golden's cipher held to what the library seals."""
    c.section("pins", "the golden's crypto pins, on the committed SodiumXT")
    mem = sx.mem_interactive()
    c.ck("sxPwMemInteractive is the pinned memlimit", mem, "67108864")
    for pw, want in ((G.ARGON_PASS_RIGHT, G.ARGON_KEY_RIGHT),
                     (G.ARGON_PASS_WRONG, G.ARGON_KEY_WRONG)):
        c.ck("sxPwHash(%r) re-derives the golden's pin" % pw,
             sx.pwhash(pw.encode("utf-8"), G.ARGON_SALT, 32, "2", mem).hex(), want.hex())
    c.ck("SodiumXT opens the golden's VERIFY_BLOB",
         sx.secretbox_open(G.VERIFY_BLOB, G.ARGON_KEY_RIGHT), G.QS_VERIFY.encode("ascii"))
    real = sx.secretbox(G.QS_VERIFY.encode("ascii"), G.ARGON_KEY_RIGHT)
    c.ck("the golden's cipher opens a box SodiumXT sealed",
         G.sx_secret_box_open(real, G.ARGON_KEY_RIGHT), G.QS_VERIFY.encode("ascii"))
    c.ck("...and seals exactly what SodiumXT sealed, given its nonce",
         G.sx_secret_box(G.QS_VERIFY.encode("ascii"), G.ARGON_KEY_RIGHT, real[:24]).hex(),
         real.hex())
    return real


def check_verifier(c, ip, sx, real_blob):
    c.section("qsKeyOpensVerifier", "qsKeyOpensVerifier on the committed SodiumXT")
    ip.globals["scanencrypt"] = "true"
    K, W = G.ARGON_KEY_RIGHT, G.ARGON_KEY_WRONG
    tampered = bytearray(real_blob)
    tampered[-1] ^= 1
    other = sx.secretbox(b"BTXQSVERIFX", K)
    rows = [
        ("a SodiumXT verifier, the right passphrase's key", K, real_blob),
        ("a SodiumXT verifier, a WRONG passphrase's key", W, real_blob),
        ("the golden's VERIFY_BLOB, the right key", K, G.VERIFY_BLOB),
        ("the golden's VERIFY_BLOB, a WRONG key", W, G.VERIFY_BLOB),
        ("a tampered box", K, bytes(tampered)),
        ("a box that opens but is not kQsVerify", K, other),
    ]
    for label, key, blob in rows:
        b64 = G.b64(blob)
        c.ck("qsKeyOpensVerifier: " + label,
             boolish(ip.call("qsKeyOpensVerifier", [to_str(key), b64])),
             G.qs_key_opens_verifier(key, b64))
    for cut in (4, 20, 40, 60):
        b64 = G.b64(real_blob)[:cut]
        c.ck("qsKeyOpensVerifier: a verifier truncated to %d chars" % cut,
             boolish(ip.call("qsKeyOpensVerifier", [to_str(K), b64])), False)
    c.ck("qsKeyOpensVerifier: an empty verifier",
         boolish(ip.call("qsKeyOpensVerifier", [to_str(K), ""])), False)


# qsReceiveOnion's refusals, by its own wording (log or dialog text)
ROUTE_TAGS = [
    ("malformed address", "malformed address"),
    ("passphrase does not match", "passphrase does not match"),
    ("type the passphrase", "locked - type the passphrase"),
    ("missing its salt", "missing its salt"),
    ("malformed salt", "malformed salt"),
    ("cannot decrypt", "cannot decrypt"),
]


def drive_receive_onion(ip, code, typed_pass):
    world = ip.world
    for fname, text in (("qsRecvPass", typed_pass), ("qsRecvCode", code), ("qsLog", "")):
        ctl = world.resolve("field", fname)
        if ctl is None:
            ctl = world.create("field")
            ctl.name = fname
        ctl.content = text
    ip.globals["shasonion"] = "true"
    ip.globals["scanencrypt"] = "true"
    ip.dials, ip.prompts, ip.logs = [], [], []
    ip.call("qsReceiveOnion", [code])
    world.sends = []
    if ip.dials:
        onion, s = ip.dials[-1]
        key = to_bytes(getg(ip, "sRxKey", s))
        name = str(getg(ip, "sRxName", s))
        if key:
            return ("dial-locked", onion, name, key)
        if not any("not encrypted" in p for p in ip.prompts):
            return ("dial with no key and NO plaintext prompt", onion, name)
        return ("confirm-plaintext", onion, name)
    said = " | ".join(ip.logs + ip.prompts)
    for needle, tag in ROUTE_TAGS:
        if needle in said:
            return ("refuse", tag)
    return ("refuse", "unmapped: " + said)


def check_truncated_codes(c, ip):
    c.section("qsReceiveOnion",
              "qsReceiveOnion on a locked BTXTOR1 code and every truncation of it")
    LCS.HASHES["oxisvalidaddress"] = lambda a: G.onion_valid(str(LCS._disp(a[0])))
    LCS.HASHES["qsonionreadynow"] = lambda a: True
    locked = G.make_tor_code(G.ROW_ONION, "report.pdf", G.ARGON_SALT, G.VERIFY_BLOB)
    plain = G.make_tor_code(G.ROW_ONION, "report.pdf", b"", b"")

    def mirror(code, pw):
        return G.receive_onion_route(code, pw, G.pinned_pwhash)

    for label, code, pw in (("the whole locked code, right passphrase", locked,
                             G.ARGON_PASS_RIGHT),
                            ("the whole locked code, WRONG passphrase", locked,
                             G.ARGON_PASS_WRONG),
                            ("the whole locked code, no passphrase", locked, ""),
                            ("the whole plaintext code", plain, "")):
        c.ck("qsReceiveOnion: " + label, drive_receive_onion(ip, code, pw),
             mirror(code, pw))
    # Every truncation: the decision CLASS and the address must agree. The
    # name is compared only where the code's name field is whole: how the
    # engine's base64Decode treats a cut-off quantum is undocumented, and the
    # model and the mirror are free to differ there (the golden's
    # lc_base64_decode note).
    name_whole_from = len(G.CODE_PREFIX) + len(G.ROW_ONION) + 1 + len(G.b64(b"report.pdf"))
    for cut in range(len(G.CODE_PREFIX), len(locked)):
        got = drive_receive_onion(ip, locked[:cut], G.ARGON_PASS_RIGHT)
        want = mirror(locked[:cut], G.ARGON_PASS_RIGHT)
        if cut < name_whole_from:
            got, want = got[:2], want[:2]
        c.ck("qsReceiveOnion: the locked code cut at %d" % cut, got, want)


# --------------------------------------------------------------------------
# tier 2: M9 on the Channels feed

M9_PASS = "correct horse battery staple"
M9_PUB = bytes(range(0xa0, 0xc0)).hex()
M9_SEED = "11" * 32


def check_m9(c, ip):
    c.section("M9", "M9: the Channels feed seal re-seals with a fresh nonce")
    ip.globals["scanencrypt"] = "true"
    feed = "name=Alice\nr=Demo Release\tmagnet:?xt=urn:btih:0123456789abcdef"
    v1 = to_bytes(ip.call("chFeedValue", [feed, M9_PASS, M9_PUB]))
    v2 = to_bytes(ip.call("chFeedValue", [feed, M9_PASS, M9_PUB]))
    marker = G.CH_ENC_MARKER.encode("ascii")
    c.ck("chFeedValue: both seals carry the BTXENC2 marker",
         (v1[:8], v2[:8]), (marker, marker))
    c.ck("chFeedValue: marker + nonce + MAC + the feed's bytes",
         (len(v1), len(v2)), (8 + 24 + 16 + len(feed.encode("utf-8")),) * 2)
    c.ck("M9: two seals of one value under one key DIFFER", v1 != v2, True)
    c.ck("M9: ...in their nonces", v1[8:32] != v2[8:32], True)
    for tag, v in (("first", v1), ("second", v2)):
        c.ck("M9: the %s seal opens through the shipped chReadFeed" % tag,
             ip.call("chReadFeed", [to_str(v), M9_PASS, M9_PUB]), feed)
    fkey = to_bytes(ip.call("chFeedKey", [M9_PASS, M9_PUB]))
    c.ck("chFeedKey is 32 bytes", len(fkey), 32)
    for tag, v in (("first", v1), ("second", v2)):
        c.ck("M9: the %s seal opens through the golden's own cipher" % tag,
             G.ch_read_feed(v, fkey), feed)
    c.ck("chReadFeed: a wrong passphrase reads BADPASS",
         ip.call("chReadFeed", [to_str(v1), "not the passphrase", M9_PUB]), "BADPASS")
    c.ck("chReadFeed: no passphrase reads LOCKED",
         ip.call("chReadFeed", [to_str(v1), "", M9_PUB]), "LOCKED")

    # the push path: two subscribers, two pushes
    LCS.HASHES["btdhtkeypair"] = lambda a: ({"publicKey": M9_PUB, "seed": M9_SEED}
                                            if str(LCS._disp(a[0])) == M9_SEED else {})
    ip.globals["shasonion"] = "true"
    setg(ip, "sChannels", "1", {"seed": M9_SEED, "name": "Alice",
                                "releases": "Demo Release\tmagnet:?xt=urn:btih:0123",
                                "pass": M9_PASS})
    setg(ip, "sChanServiceAddr", M9_PUB, G.ROW_ONION)
    setg(ip, "sFeedStreams", M9_PUB, "5\n6")
    text = str(ip.call("chAnonFeedText", ["1"]))
    pushes = []
    for _ in range(2):
        ip.writes = []
        ip.call("chOnionPushFeed", [M9_PUB])
        pushes.append(list(ip.writes))
    c.ck("chOnionPushFeed: each push writes to both subscribers",
         [[s for s, _ in p] for p in pushes], [["5", "6"], ["5", "6"]])
    values = []
    for p in pushes:
        vals = []
        for _, frame in p:
            got, rest = G.drain_feed_frames(frame)
            vals.append(got[0] if len(got) == 1 and rest == b"" else None)
        values.append(vals)
    c.ck("chOnionPushFeed: one push fans ONE sealed value out",
         [v[0] == v[1] and v[0] is not None for v in values], [True, True])
    c.ck("M9: the second push RE-SEALS (no cached nonce)",
         values[0][0] != values[1][0] and values[0][0][8:32] != values[1][0][8:32], True)
    for n, v in enumerate((values[0][0], values[1][0]), 1):
        c.ck("M9: push %d opens through the shipped chReadFeed" % n,
             ip.call("chReadFeed", [to_str(v), M9_PASS, M9_PUB]), text)
        c.ck("M9: push %d opens through the golden's own cipher" % n,
             G.ch_read_feed(v, fkey), text)


# --------------------------------------------------------------------------

def open_sodium():
    """(Sodium, "") when tier 2 can run, else (None, why)."""
    if not os.path.isfile(SODIUM_SO):
        return None, sibling_missing("sodiumxt", SODIUM_SO)
    try:
        return Sodium(SODIUM_SO), ""
    except OSError as e:
        # the committed x86_64-linux library, on a host that cannot load it
        return None, "%s did not load on this host (%s)." % (SODIUM_SO, e)


def main(argv):
    # --check: terse (what run-gates.sh passes). --qs / --ch PATH: drive a copy
    # (tools/test-script-vectors.py's mechanism). --only qs|ch: one demo's
    # sections only, so a fixture pays for the demo it mutated and no other.
    terse = "--check" in argv
    args = [a for a in argv[1:] if a != "--check"]
    qs_path, ch_path, only = QS_DEMO, CH_DEMO, None
    while args:
        if len(args) >= 2 and args[0] == "--qs":
            qs_path = args[1]
        elif len(args) >= 2 and args[0] == "--ch":
            ch_path = args[1]
        elif len(args) >= 2 and args[0] == "--only" and args[1] in ("qs", "ch"):
            only = args[1]
        else:
            print("usage: check-script-vectors.py [--check] [--qs PATH] [--ch PATH] "
                  "[--only qs|ch]")
            return 2
        args = args[2:]
    c = Checker(terse)
    sx, why = open_sodium()
    sandbox = tempfile.mkdtemp(prefix="torrentxt-vectors-")
    try:
        qs = load_demo(qs_path, "qs", sandbox) if only != "ch" else None
        ch = load_demo(ch_path, "ch", sandbox) if only != "qs" else None
        for ip in (qs, ch):
            if ip is not None:
                check_receiver(c, ip, sandbox)
                check_disk_guard(c, ip, sandbox)
        if sx is not None:
            sx.install()
            real_blob = check_pins(c, sx)
            if qs is not None:
                check_verifier(c, qs, sx, real_blob)
                check_truncated_codes(c, qs)
            if ch is not None:
                check_m9(c, ch)
        elif os.environ.get("XTALK_REQUIRE_SIBLINGS"):
            print("check-script-vectors: " + why)
            c.ck("tier 2 ran (XTALK_REQUIRE_SIBLINGS is set, so a missing sodiumxt "
                 "is a failure, not a skip)", "absent", "present")
        else:
            print("check-script-vectors: SKIPPED tier 2 (the verifier, the "
                  "truncated codes and the M9 KAT) - %s Tier 1 still ran." % why)
    finally:
        import shutil
        shutil.rmtree(sandbox, ignore_errors=True)
    if c.failed:
        print("check-script-vectors: FAIL (%d of %d)\n%s"
              % (len(c.failed), c.n, "\n".join(c.failed)))
        return 1
    short = c.short()
    if short:
        print("check-script-vectors: FAIL - a section stopped executing: "
              + "; ".join(short))
        return 1
    print("check-script-vectors: OK (%d checks: %s)"
          % (c.n, ", ".join("%s %d" % kv for kv in sorted(c.counts.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
