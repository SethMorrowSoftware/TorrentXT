#!/usr/bin/env python3
"""onion_frame_golden.py - byte-exact reference for the OnionXT (Model C) file
transport used by the QuickShare and DHT-Channels demos.

OXT cannot compile/run .livecodescript headlessly, so - exactly like
record_golden_test.py and bep44_golden_test.py - this pure-Python reference PINS
the on-wire format that the LiveCodeScript must produce and parse. It is the one
piece of the Model-C work that is genuinely verifiable off-engine: the framing
arithmetic, the BTXTOR1 share-code layout, and the qsSafeLeaf path-traversal
sanitiser. If this and the .livecodescript ever disagree, one of them is wrong.

Mirrors these LiveCodeScript handlers (examples/torrent-quickshare.livecodescript):
  qsOnionHeader  -> header()          qsBEu16/qsBEu32 -> be16()/be32()
  qsOnionSendPump frame/terminator    -> frame()/terminator()
  qsOnionRecvData header parse        -> parse_header()  (1-based byte offsets)
  qsMakeTorCode                       -> make_tor_code()
  qsSafeLeaf                          -> safe_leaf()

Since 2026-08-23 (docs/HEADLESS-BACKLOG-2026-08-17.md item A4) it also pins the
Channels layer of examples/torrent-dht-channels.livecodescript: the section-6.4
BTXC request and BTXF feed frame, byte for byte per the normative table in
docs/ONIONXT-INTEGRATION-PLAN.md section 12.2, plus that demo's own chSafeLeaf
(a SEPARATE copy of qsSafeLeaf, so the rows above never held it):
  chChanRequest                       -> chan_request()
  chFeedFrame                         -> feed_frame()
  chOnionServeRequest parse           -> parse_chan_request()  (1-based offsets)
  chOnionFeedData drain loop          -> drain_feed_frames()
  chSafeLeaf                          -> ch_safe_leaf()
(The channels demo also carries its OWN copy of the section-3.3 file framing -
chOnionHeader / chOnionRecvData / chBEu16 / chBEu32 - measured byte-identical
to the qs* copy modulo the prefix on 2026-08-23, so the header/frame rows above
hold both copies; only the request/feed layer needed new rows.)

    python3 tests/onion_frame_golden.py     # exit 0 = OK, 1 = mismatch
"""
import base64
import struct
import sys

MAGIC = b"BTXO"          # kOnionMagic (4 ASCII bytes)
VER = 1                  # kOnionVer
FLAG_ENC = 1             # kFlagEnc (header flags bit0)
CHUNK = 65536            # kOnionChunk (max data-frame payload)
CODE_PREFIX = "BTXTOR1:"  # kTorCodePrefix

_fail = []


def check(name, got, want):
    if got != want:
        _fail.append("%s:\n    got  %r\n    want %r" % (name, got, want))


# ---- framing: must match qsOnionHeader + the send pump ----------------------

def header(name_utf8, encrypted, total):
    """magic(4) ver(1) flags(1) nameLen(u16 BE) name totalLen(u64 as hi:u32 lo:u32)."""
    flags = FLAG_ENC if encrypted else 0
    hi, lo = total // 4294967296, total % 4294967296        # matches div/mod 2^32
    return (MAGIC + struct.pack(">B", VER) + struct.pack(">B", flags)
            + struct.pack(">H", len(name_utf8)) + name_utf8
            + struct.pack(">I", hi) + struct.pack(">I", lo))


def frame(payload):
    assert 1 <= len(payload) <= CHUNK
    return struct.pack(">I", len(payload)) + payload


def terminator():
    return struct.pack(">I", 0)


def be16(b):
    return b[0] * 256 + b[1]


def be32(b):
    return ((b[0] * 256 + b[1]) * 256 + b[2]) * 256 + b[3]


def parse_header(buf):
    """Parse exactly as qsOnionRecvData does, using 1-based offsets in comments.
    Returns (flags, name_bytes, total, header_len) or raises on a short/bad buffer."""
    if len(buf) < 8:
        raise ValueError("short")
    if buf[0:4] != MAGIC:                    # byte 1 to 4
        raise ValueError("magic")
    if buf[4] != VER:                        # byte 5
        raise ValueError("ver")
    flags = buf[5]                           # byte 6
    name_len = be16(buf[6:8])                # byte 7 to 8
    if len(buf) < 8 + name_len + 8:
        raise ValueError("short2")
    name = buf[8:8 + name_len]               # byte 9 to 8+nameLen
    hi = be32(buf[8 + name_len:12 + name_len])   # byte 9+nameLen to 12+nameLen
    lo = be32(buf[12 + name_len:16 + name_len])  # byte 13+nameLen to 16+nameLen
    return flags, name, hi * 4294967296 + lo, 16 + name_len


def reassemble(stream_bytes):
    """Drive the receiver state machine over an arbitrarily-chunked stream; return
    (name_bytes, encrypted, payload). Proves header+frames+terminator round-trip and
    that the buffer stays bounded (we only ever hold <= one chunk + a partial frame)."""
    flags, name, total, hlen = parse_header(stream_bytes)
    buf = stream_bytes[hlen:]
    out = bytearray()
    while True:
        if len(buf) < 4:
            raise ValueError("truncated frame length")
        ln = be32(buf[0:4])
        if ln == 0:
            break
        if ln > CHUNK:
            raise ValueError("frame too large")   # the mandatory bound
        if len(buf) < 4 + ln:
            raise ValueError("truncated frame body")
        out += buf[4:4 + ln]
        buf = buf[4 + ln:]
    if len(out) != total:
        raise ValueError("totalLen mismatch")
    return name, bool(flags & FLAG_ENC), bytes(out)


# ---- share code: must match qsMakeTorCode + qsB64 ---------------------------

def b64(data):
    return base64.b64encode(data).decode("ascii")   # qsB64 strips CR/LF; b64encode has none


def make_tor_code(onion, name, salt, verifier):
    return (CODE_PREFIX + onion + ":" + b64(safe_leaf(name).encode("utf-8"))
            + ":" + b64(salt) + ":" + b64(verifier))


# ---- qsSafeLeaf: the path-traversal sanitiser -------------------------------

def safe_leaf(name):
    n = name.replace("\\", "/")
    n = n.split("/")[-1]                 # basename (itemDelimiter "/", last item)
    if ":" in n:
        n = n.split(":")[-1]             # strip drive/colon
    n = n.lstrip(".")                    # strip leading dots
    n = "".join(c for c in n if ord(c) >= 32 and c not in "/\\")
    if n == "" or n == ".." or n == ".":
        return "shared-file"
    return n


# ---- channels layer (section 6.4): the BTXC request + BTXF feed frame -------
#
# One level above the file framing: a follower opens an onion stream and sends
# ONE self-delimiting BTXC request naming the channel (pubkey hex) and verb;
# the publisher answers with BTXF feed frames (repeatable, for live push)
# and/or a BTXO file stream. All integers big-endian, exactly like the file
# framing above: the script builds with binaryEncode("n")/"N" (LiveCode's
# big-endian u16/u32 codes, the section-12.2 table's own annotation) and
# parses with chBEu16/chBEu32, which are the same arithmetic as be16()/be32().

CH_REQ_MAGIC = b"BTXC"    # kChanReqMagic (4 ASCII bytes)
CH_REQ_VER = 1            # kChanReqVer
CH_FEED_MAGIC = b"BTXF"   # kFeedFrameMagic (4 ASCII bytes)
CH_FEED_VER = 1           # kFeedFrameVer
VERB_FEED = 1             # kVerbFeed: fetch the signed feed
VERB_FILE = 2             # kVerbFile: fetch a release's bytes
CH_MAX_KEY = 128          # chOnionServeRequest's inline keyLen cap (an ed25519
                          # pubkey is 64 hex chars, so 128 is 2x slack)
CH_MAX_ID = 64            # chOnionServeRequest's inline idLen cap (chAllocRelId
                          # mints 16 hex chars)
FEED_CAP = 65536          # kOnionFeedCap: BTXF anti-DoS value-length bound


def chan_request(verb, key, rel_id):
    """magic(4) ver(1) verb(1) keyLen(u16 BE) key idLen(u16 BE) id.
    Matches chChanRequest; key and id are the script's textEncoded-ASCII hex
    strings, opaque bytes here."""
    return (CH_REQ_MAGIC + struct.pack(">B", CH_REQ_VER) + struct.pack(">B", verb)
            + struct.pack(">H", len(key)) + key
            + struct.pack(">H", len(rel_id)) + rel_id)


def feed_frame(value):
    """magic(4) ver(1) valLen(u32 BE) value. Matches chFeedFrame; the value is
    the sealed-or-plaintext feed blob, opaque bytes here."""
    return (CH_FEED_MAGIC + struct.pack(">B", CH_FEED_VER)
            + struct.pack(">I", len(value)) + value)


def parse_chan_request(buf):
    """Parse exactly as chOnionServeRequest does (1-based offsets in comments).
    Returns None while the frame is still incomplete (the script exits early
    and is re-entered on the next data event), (verb, key, id, frame_len) once
    whole, and raises ValueError on the abort paths. Two orderings are faithful
    mirrors, not accidents: each length CAP is enforced the moment its length
    field is readable, BEFORE waiting for the body it describes (the
    section-12.2 "rejected before allocation" rule), while the VERSION is
    validated only once the whole frame has arrived - so a wrong-version
    prefix waits rather than aborting. The verb is NOT validated here: the
    dispatcher is what aborts on anything but kVerbFeed/kVerbFile. Bytes past
    frame_len are ignored (the script leaves them in sOnReq and flips the
    stream's role, so they are never re-parsed). chOnionServeStream also
    aborts as soon as the first 4 bytes are not "BTXC"; the parser re-checks,
    so mirroring only the parser loses no acceptance case."""
    if len(buf) < 8:
        return None
    if buf[0:4] != CH_REQ_MAGIC:                      # byte 1 to 4
        raise ValueError("magic")
    ver = buf[4]                                      # byte 5
    verb = buf[5]                                     # byte 6
    key_len = be16(buf[6:8])                          # byte 7 to 8
    if key_len > CH_MAX_KEY:
        raise ValueError("keyLen cap")
    need = 8 + key_len + 2
    if len(buf) < need:
        return None
    key = buf[8:8 + key_len]                          # byte 9 to 8+keyLen
    id_len = be16(buf[8 + key_len:10 + key_len])      # byte 9+keyLen to 10+keyLen
    if id_len > CH_MAX_ID:
        raise ValueError("idLen cap")
    need += id_len
    if len(buf) < need:
        return None
    rel_id = buf[10 + key_len:10 + key_len + id_len]  # byte 11+keyLen to 10+keyLen+idLen
    if ver != CH_REQ_VER:
        raise ValueError("ver")
    return verb, key, rel_id, need


def drain_feed_frames(buf):
    """Drive chOnionFeedData's drain loop over one accumulated buffer; return
    (values, leftover). Every COMPLETE frame is consumed per call so a live
    push reassembles across reads; a partial trailing frame stays buffered for
    the next data event. Raises ValueError on the abort paths - bad magic, bad
    version, valLen over kOnionFeedCap - all three decided from the 9-byte
    prologue alone, before any value byte arrives (the same before-allocation
    rule as the request caps)."""
    values = []
    while True:
        if len(buf) < 9:
            return values, buf
        if buf[0:4] != CH_FEED_MAGIC:                 # byte 1 to 4
            raise ValueError("magic")
        if buf[4] != CH_FEED_VER:                     # byte 5
            raise ValueError("ver")
        val_len = be32(buf[5:9])                      # byte 6 to 9
        if val_len > FEED_CAP:
            raise ValueError("frame too large")
        if len(buf) < 9 + val_len:
            return values, buf
        values.append(buf[9:9 + val_len])             # byte 10 to 9+valLen
        buf = buf[9 + val_len:]


# ---- chSafeLeaf: the channels demo's OWN copy of the sanitiser --------------
#
# torrent-dht-channels.livecodescript never calls qsSafeLeaf; it carries a
# SEPARATE chSafeLeaf, applied to the attacker-chosen feed origName, to the
# BTXO stream header name, and again before the final move - so the safe_leaf
# rows above never held it (the backlog-A4 gap). Measured 2026-08-23: the two
# handler BODIES are byte-identical, so there is no behavioural divergence to
# pin today. But two copies drift independently, which is exactly why each
# gets its OWN mirror and its OWN rows: when one script copy changes, change
# ITS mirror here, and the agreement rows in main() fail loudly - a deliberate
# divergence gets recorded instead of shipped silently. (Those agreement rows
# are trivially green today; their value is entirely post-drift.)
#
# One modelling caveat, shared with safe_leaf() above: Python's split("/")[-1]
# equals LiveCode's "the last item" only when the name does not END with the
# delimiter (LiveCode ignores a single trailing itemDelimiter: the last item
# of "abc/" is "abc", while split yields ""). The vectors below deliberately
# avoid a bare trailing separator, as the qsSafeLeaf vectors always have.

def ch_safe_leaf(name):
    n = name.replace("\\", "/")
    n = n.split("/")[-1]                 # basename (itemDelimiter "/", last item)
    if ":" in n:
        n = n.split(":")[-1]             # strip drive/colon
    n = n.lstrip(".")                    # strip leading dots
    n = "".join(c for c in n if ord(c) >= 32 and c not in "/\\")
    if n == "" or n == ".." or n == ".":
        return "shared-file"
    return n


def main():
    # -- header round-trip + a pinned hex vector --
    h = header(b"a.txt", False, 5)
    check("header hex", h.hex(),
          "42_54_58_4f_01_00_00_05_61_2e_74_78_74_00_00_00_00_00_00_00_05".replace("_", ""))
    flags, name, total, hlen = parse_header(h)
    check("header parse", (flags, name, total, hlen), (0, b"a.txt", 5, 21))

    # -- encrypted flag + a large (>4 GiB) total exercises the hi:lo split --
    big = 4294967296 + 7
    fl, nm, tot, _ = parse_header(header(b"x", True, big))
    check("enc flag + u64 total", (fl, nm, tot), (FLAG_ENC, b"x", big))

    # -- full stream reassembly across awkward chunk boundaries --
    payload = bytes((i * 7) % 256 for i in range(100000))     # > 1 chunk
    wire = header(b"movie.bin", False, len(payload))
    off = 0
    while off < len(payload):
        wire += frame(payload[off:off + CHUNK])
        off += CHUNK
    wire += terminator()
    nm, enc, got = reassemble(wire)
    check("reassemble name", nm, b"movie.bin")
    check("reassemble enc", enc, False)
    check("reassemble payload", got, payload)

    # -- empty file: header total 0, immediate terminator --
    nm, enc, got = reassemble(header(b"empty", False, 0) + terminator())
    check("empty payload", (nm, got), (b"empty", b""))

    # -- oversized frame length must be rejected, not buffered --
    bad = header(b"x", False, 10) + struct.pack(">I", CHUNK + 1)
    try:
        reassemble(bad)
        _fail.append("oversized frame: expected rejection, got none")
    except ValueError:
        pass

    # -- share code layout (plaintext: empty salt/verify -> trailing "::") --
    onion = "a" * 56 + ".onion"
    check("plaintext code", make_tor_code(onion, "hello world.pdf", b"", b""),
          CODE_PREFIX + onion + ":" + b64(b"hello world.pdf") + "::")
    enc_code = make_tor_code(onion, "n", b"\x01" * 16, b"\x02" * 40)
    parts = enc_code[len(CODE_PREFIX):].split(":")
    check("enc code fields", len(parts), 4)
    check("enc code onion", parts[0], onion)
    check("enc code salt", base64.b64decode(parts[2]), b"\x01" * 16)
    check("enc code verify", base64.b64decode(parts[3]), b"\x02" * 40)

    # -- qsSafeLeaf: every traversal / injection attempt reduces to a safe leaf --
    for raw, want in [
        ("../../.ssh/authorized_keys", "authorized_keys"),
        ("..\\..\\Windows\\system32\\evil.dll", "evil.dll"),
        ("/etc/passwd", "passwd"),
        ("C:\\secret\\x.txt", "x.txt"),
        ("..", "shared-file"),
        (".", "shared-file"),
        ("...", "shared-file"),
        (".hidden", "hidden"),
        ("plain.txt", "plain.txt"),
        ("a\x00b\x07c.txt", "abc.txt"),      # control chars dropped
        ("", "shared-file"),
    ]:
        check("safe_leaf(%r)" % raw, safe_leaf(raw), want)

    # -- channels BTXC request: pinned hex, hand-assembled from the 12.2 table
    #    ("BTXC"(4) ver:u8 verb:u8 keyLen:u16 key idLen:u16 id) so the builder
    #    is checked against the SPEC bytes, never against itself --
    req = chan_request(VERB_FEED, b"cafe", b"")
    check("BTXC feed hex", req.hex(),
          "42_54_58_43_01_01_00_04_63_61_66_65_00_00".replace("_", ""))
    check("BTXC feed parse", parse_chan_request(req), (VERB_FEED, b"cafe", b"", 14))
    req = chan_request(VERB_FILE, b"ab", b"id01")
    check("BTXC file hex", req.hex(),
          "42_54_58_43_01_02_00_02_61_62_00_04_69_64_30_31".replace("_", ""))
    check("BTXC file parse", parse_chan_request(req), (VERB_FILE, b"ab", b"id01", 16))

    # -- a wire-shaped request (64-hex-char pubkey + 16-hex-char release id,
    #    what the fetch side actually sends) round-trips; bytes after the
    #    self-delimiting frame are ignored, never an error --
    key = b"0123456789abcdef" * 4
    rid = b"00ff00ff00ff00ff"
    req = chan_request(VERB_FILE, key, rid)
    check("BTXC wire-shaped parse", parse_chan_request(req),
          (VERB_FILE, key, rid, 10 + 64 + 16))
    check("BTXC trailing bytes", parse_chan_request(req + b"zz"),
          (VERB_FILE, key, rid, 10 + 64 + 16))

    # -- incremental arrival: EVERY strict prefix must wait (None) - the
    #    exit-early / re-enter contract that lets Tor deliver one byte at a
    #    time without the serve side ever misparsing a half frame --
    for cut in range(len(req)):
        if parse_chan_request(req[:cut]) is not None:
            _fail.append("BTXC prefix of %d bytes: expected incomplete (None)" % cut)
            break

    # -- the caps refuse from the length field ALONE, before the body they
    #    describe arrives (12.2's rejected-before-allocation rule); the cap
    #    values themselves still pass --
    bad = CH_REQ_MAGIC + struct.pack(">BBH", CH_REQ_VER, VERB_FEED, CH_MAX_KEY + 1)
    try:
        parse_chan_request(bad)
        _fail.append("BTXC keyLen cap: expected rejection, got none")
    except ValueError:
        pass
    bad = (CH_REQ_MAGIC + struct.pack(">BBH", CH_REQ_VER, VERB_FEED, 1) + b"k"
           + struct.pack(">H", CH_MAX_ID + 1))
    try:
        parse_chan_request(bad)
        _fail.append("BTXC idLen cap: expected rejection, got none")
    except ValueError:
        pass
    check("BTXC caps boundary",
          parse_chan_request(chan_request(VERB_FEED, b"k" * CH_MAX_KEY, b"i" * CH_MAX_ID)),
          (VERB_FEED, b"k" * CH_MAX_KEY, b"i" * CH_MAX_ID, 10 + CH_MAX_KEY + CH_MAX_ID))

    # -- version: validated only once the frame is WHOLE (the script reads the
    #    lengths first), so a wrong-version prefix waits and a wrong-version
    #    complete frame is refused; wrong magic is refused as soon as 8 bytes
    #    are in (chOnionServeStream fires at 4; the parser re-checks) --
    check("BTXC bad-ver prefix waits",
          parse_chan_request(CH_REQ_MAGIC + struct.pack(">BBH", 2, VERB_FEED, 4) + b"ca"),
          None)
    try:
        parse_chan_request(CH_REQ_MAGIC + struct.pack(">BBH", 2, VERB_FEED, 2)
                           + b"ca" + struct.pack(">H", 0))
        _fail.append("BTXC bad version: expected rejection, got none")
    except ValueError:
        pass
    try:
        parse_chan_request(b"BTXX" + struct.pack(">BBH", CH_REQ_VER, VERB_FEED, 0))
        _fail.append("BTXC bad magic: expected rejection, got none")
    except ValueError:
        pass

    # -- channels BTXF feed frame: pinned hex, hand-assembled from the 12.2
    #    table ("BTXF"(4) ver:u8 valLen:u32 value) --
    fr = feed_frame(b"hello")
    check("BTXF hex", fr.hex(),
          "42_54_58_46_01_00_00_00_05_68_65_6c_6c_6f".replace("_", ""))
    check("BTXF single drain", drain_feed_frames(fr), ([b"hello"], b""))

    # -- live-push shape: two whole frames + a partial third drain to exactly
    #    two values; the partial stays buffered for the next data event --
    part = feed_frame(b"third")[:7]
    check("BTXF multi drain",
          drain_feed_frames(feed_frame(b"v1") + feed_frame(b"second value") + part),
          ([b"v1", b"second value"], part))

    # -- an empty value (valLen 0) parses cleanly, though the publisher never
    #    sends one (chOnionServeFeed exits early on an empty sealed value) --
    check("BTXF empty value", drain_feed_frames(feed_frame(b"")), ([b""], b""))

    # -- the kOnionFeedCap bound refuses from the 9-byte prologue alone; the
    #    cap value itself passes --
    try:
        drain_feed_frames(CH_FEED_MAGIC + struct.pack(">BI", CH_FEED_VER, FEED_CAP + 1))
        _fail.append("BTXF oversized valLen: expected rejection, got none")
    except ValueError:
        pass
    vals, rest = drain_feed_frames(feed_frame(b"\x5a" * FEED_CAP))
    check("BTXF cap boundary", (len(vals), len(vals[0]) if vals else -1, rest),
          (1, FEED_CAP, b""))

    # -- wrong version and wrong magic refused from the prologue; the magic
    #    case doubles as the cross-protocol guard (a BTXO file stream arriving
    #    on a feed-role stream aborts instead of being fed to chReadFeed) --
    try:
        drain_feed_frames(CH_FEED_MAGIC + struct.pack(">BI", 2, 0))
        _fail.append("BTXF bad version: expected rejection, got none")
    except ValueError:
        pass
    try:
        drain_feed_frames(b"BTXO" + struct.pack(">BI", CH_FEED_VER, 0))
        _fail.append("BTXF bad magic: expected rejection, got none")
    except ValueError:
        pass

    # -- chSafeLeaf: the channels copy pinned on its OWN rows (the qsSafeLeaf
    #    table plus channel-shaped names), then both mirrors held in agreement
    #    so a future edit to one script copy fails here instead of drifting --
    ch_vectors = [
        ("../../.ssh/authorized_keys", "authorized_keys"),
        ("..\\..\\Windows\\system32\\evil.dll", "evil.dll"),
        ("/etc/passwd", "passwd"),
        ("C:\\secret\\x.txt", "x.txt"),
        ("..", "shared-file"),
        (".", "shared-file"),
        ("...", "shared-file"),
        (".hidden", "hidden"),
        ("plain.txt", "plain.txt"),
        ("a\x00b\x07c.txt", "abc.txt"),      # control chars dropped
        ("", "shared-file"),
        # a feed origName with a colon strips to the last colon-item: the
        # drive-letter rule is really a colon rule, and feed names are
        # attacker-chosen text, not paths from a file dialog
        ("release:v1.0", "v1.0"),
        # dot-strip happens AFTER basename, so a dotted leaf inside a path
        # still loses its leading dots
        ("nested/dir/....leading", "leading"),
    ]
    for raw, want in ch_vectors:
        check("ch_safe_leaf(%r)" % raw, ch_safe_leaf(raw), want)
    for raw, _ in ch_vectors:
        check("SafeLeaf agreement on %r" % raw, ch_safe_leaf(raw), safe_leaf(raw))

    if _fail:
        print("onion_frame_golden: FAIL\n" + "\n".join(_fail))
        return 1
    print("onion_frame_golden: OK (BTXO framing, share code, qsSafeLeaf, "
          "BTXC/BTXF, and chSafeLeaf all match)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
