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

Since 2026-08-23 it also pins the
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

Since 2026-09-24 it pins what the design's section 12.2 listed as "asked for
and not pinned yet" (docs/ONIONXT-INTEGRATION-PLAN.md), with the receiver
mirrored ONE READ AT A TIME, the way the script is actually driven:
  qsOnionRecvData / chOnionRecvData    -> Receiver  (behaviourally identical,
                                          re-measured 2026-09-24: only the
                                          abort texts and the xfer array's
                                          name differ)
  qsKeyOpensVerifier                  -> qs_key_opens_verifier(), over a
                                          pure-Python XSalsa20-Poly1305 that
                                          reproduces NaCl's published
                                          secretbox vector (below)
  chFeedValue / chReadFeed            -> ch_feed_value() / ch_read_feed()
  qsReceiveOnion's parse, to the dial -> receive_onion_route()
  oxIsValidAddress (onionxt)          -> onion_valid()
  qsGetFile of the LAST PRE-MODEL-C QuickShare (register #17)
                                      -> pre_model_c_route()
Every new row was run against a deliberately broken mirror and failed; the
mutations are listed beside the rows. A mirror is only as good as its reading
of the script, so tools/check-script-vectors.py RUNS the shipped handlers
headlessly against these mirrors: the receiver on the same split and
byte-at-a-time streams, and the verifier and the Channels feed seal on the
committed SodiumXT library (where the nonce-freshness KAT, M9, lives - a
pure-Python model can only show that its OWN nonces are fresh).

    python3 tests/onion_frame_golden.py     # exit 0 = OK, 1 = mismatch
"""
import base64
import hashlib
import hmac
import struct
import sys

MAGIC = b"BTXO"          # kOnionMagic (4 ASCII bytes)
VER = 1                  # kOnionVer
FLAG_ENC = 1             # kFlagEnc (header flags bit0)
CHUNK = 65536            # kOnionChunk (max data-frame payload)
CODE_PREFIX = "BTXTOR1:"  # kTorCodePrefix
MAX_NAME = 1024          # kOnionMaxName: a header nameLen beyond this aborts
MAX_TOTAL = 8589934592   # kOnionMaxTotal: 8 GiB; a larger header totalLen aborts
QS_VERIFY = "BTXQSVERIFY"  # kQsVerify: what a locked code's verifier seals

_fail = []
_ran = [0]   # rows checked: printed, so a section that silently stops shows


def check(name, got, want):
    _ran[0] += 1
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


class Receiver(object):
    """qsOnionRecvData (and chOnionRecvData, the same machine), one stream, fed
    ONE READ AT A TIME - the whole point, and the thing this file's first
    reassemble() never did: it took the stream whole, whatever its "awkward
    chunk boundaries" comment said. Mirrored statement by statement, in the
    script's order, because here the order IS the behaviour:

      header: wait for 8 bytes; magic, then version; nameLen's cap is enforced
        the moment nameLen is readable, BEFORE waiting for the name it
        describes; wait for 8 + nameLen + 8; totalLen's cap; the two downgrade
        refusals (a key but no kFlagEnc; kFlagEnc but no key); a non-empty
        header name replaces the code's name, through SafeLeaf; the header
        bytes are deleted and the state goes to body.
      body: drain every COMPLETE frame; a frame's len is checked against
        kOnionChunk before its body is waited for; len 0 is the terminator.
      then "belt and suspenders": done as soon as got >= total, terminator or
        not - so a zero-total stream finishes on its header alone, and a stream
        carrying MORE than its header promised finishes early and is refused
        by the finish.
      finish (qsOnionRecvFinish): got != total aborts "incomplete"; else saved.
      abort and finish both clear the state; a read after that is ignored.
      close (qsOnionRecvStream's closed/error event): aborts unless done.

    `outcome` is None while the transfer is live, then ("saved", name, enc,
    payload) or ("abort", tag). The tags stand for the script's messages; the
    execution gate maps each demo's own wording onto them. `peak` is the
    largest buffer any read leaves behind in the body state: the section-3.3
    bound, one chunk plus a partial frame header at most."""

    def __init__(self, key=None, code_name="shared-file", channels=False):
        self.key = key               # sRxKey: the locked code's key, or None
        # chOnionRecvData only (2026-09-24, design 6.4): a ZERO totalLen is the
        # publisher's "release not currently available" reply, refused before
        # the downgrade test; qsOnionRecvData still saves an empty file.
        self.channels = channels
        self.state = "header"        # sRxState
        self.buf = bytearray()       # sRxBuf
        self.name = code_name        # sRxName: seeded from the code, not the header
        self.enc = 0
        self.total = None
        self.got = 0
        self.payload = bytearray()   # what `write ... to file` received
        self.outcome = None
        self.peak = 0

    def feed(self, data):
        if self.state in ("", "done"):
            return                   # finished or cleared: ignore the bytes
        self.buf += data
        if self.state == "header":
            if len(self.buf) < 8:
                return
            if bytes(self.buf[0:4]) != MAGIC:
                return self._abort("magic")
            if self.buf[4] != VER:
                return self._abort("version")
            flags = self.buf[5]
            name_len = be16(self.buf[6:8])
            if name_len > MAX_NAME:
                return self._abort("name too long")
            if len(self.buf) < 8 + name_len + 8:
                return
            name = bytes(self.buf[8:8 + name_len]).decode("utf-8", "replace")
            hi = be32(self.buf[8 + name_len:12 + name_len])
            lo = be32(self.buf[12 + name_len:16 + name_len])
            total = hi * 4294967296 + lo
            if total > MAX_TOTAL:
                return self._abort("oversized")
            if self.channels and total == 0:
                return self._abort("not available")
            if self.key is not None and not (flags & FLAG_ENC):
                return self._abort("downgrade")
            if (flags & FLAG_ENC) and self.key is None:
                return self._abort("no passphrase")
            self.enc = flags & FLAG_ENC
            if name != "":
                self.name = safe_leaf(name)
            self.total = total
            self.got = 0
            del self.buf[:16 + name_len]
            self.state = "body"
        while self.state == "body":
            if len(self.buf) < 4:
                break
            ln = be32(self.buf[0:4])
            if ln == 0:
                del self.buf[:4]
                self.state = "done"
                break
            if ln > CHUNK:
                return self._abort("frame too large")
            if len(self.buf) < 4 + ln:
                break
            self.payload += self.buf[4:4 + ln]
            self.got += ln
            del self.buf[:4 + ln]
        if self.state == "body":
            self.peak = max(self.peak, len(self.buf))
        if self.state == "body" and self.got >= self.total:
            self.state = "done"
        if self.state == "done":
            self._finish()

    def close(self):
        if self.state not in ("", "done"):
            self._abort("offline")

    def _finish(self):
        if self.got != self.total:
            return self._abort("incomplete")
        self.outcome = ("saved", self.name, bool(self.enc), bytes(self.payload))
        self._clear()

    def _abort(self, tag):
        self.outcome = ("abort", tag)
        self._clear()

    def _clear(self):
        self.state = ""
        self.buf = bytearray()


def split_at(stream, cuts):
    """The reads a stream arrives in, cut at the given offsets. Empty reads are
    dropped: a data event never carries zero bytes."""
    reads, prev = [], 0
    for c in list(cuts) + [len(stream)]:
        if c > prev:
            reads.append(stream[prev:c])
            prev = c
    return reads


def receive(stream_bytes, cuts=(), key=None, code_name="shared-file", channels=False):
    """Feed a stream through a Receiver in the reads `cuts` makes, then the
    sender's close; return the Receiver (its outcome says what happened).
    channels=True mirrors chOnionRecvData's zero-total rule."""
    rx = Receiver(key=key, code_name=code_name, channels=channels)
    for piece in split_at(stream_bytes, cuts):
        rx.feed(piece)
    rx.close()
    return rx


def reassemble(stream_bytes, cuts=(), key=None):
    """The saved (name, encrypted, payload), or ValueError(tag) on an abort."""
    rx = receive(stream_bytes, cuts, key)
    if rx.outcome[0] != "saved":
        raise ValueError(rx.outcome[1])
    return rx.outcome[1], rx.outcome[2], rx.outcome[3]


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


# ---- secretbox: a pure-Python XSalsa20-Poly1305 (libsodium's crypto_secretbox)
#
# WHY A CIPHER IN A GOLDEN. qsKeyOpensVerifier's whole job is "does this key
# open that sealed verifier", and a row that stubs the cipher tests the stub.
# This is the NaCl construction written from its definition (Salsa20/20,
# HSalsa20 for the 24-byte nonce, Poly1305 keyed from the first 32 keystream
# bytes, easy layout MAC || ciphertext) and it is NOT trusted on its own
# say-so: the first row of main() requires it to reproduce NaCl's published
# crypto_secretbox vector (the distribution's tests/secretbox.c: firstkey,
# nonce, m -> c), which libsodium 1.0.18 (libsodium.so.23.3.0, Linux x86_64)
# was measured reproducing byte for byte on 2026-09-24. The COMMITTED
# SodiumXT library is held to this model in tools/check-script-vectors.py.
# Test tooling only: slow, not constant-time, never shipped.

_M32 = 0xffffffff


def _rotl(v, c):
    return ((v << c) & _M32) | (v >> (32 - c))


def _salsa20_rounds(x):
    def qr(a, b, c, d):
        x[b] ^= _rotl((x[a] + x[d]) & _M32, 7)
        x[c] ^= _rotl((x[b] + x[a]) & _M32, 9)
        x[d] ^= _rotl((x[c] + x[b]) & _M32, 13)
        x[a] ^= _rotl((x[d] + x[c]) & _M32, 18)
    for _ in range(10):
        qr(0, 4, 8, 12)
        qr(5, 9, 13, 1)
        qr(10, 14, 2, 6)
        qr(15, 3, 7, 11)
        qr(0, 1, 2, 3)
        qr(5, 6, 7, 4)
        qr(10, 11, 8, 9)
        qr(15, 12, 13, 14)


def _salsa_state(key, in16):
    c = struct.unpack("<4I", b"expand 32-byte k")
    k = struct.unpack("<8I", key)
    n = struct.unpack("<4I", in16)
    return [c[0], k[0], k[1], k[2], k[3], c[1], n[0], n[1],
            n[2], n[3], c[2], k[4], k[5], k[6], k[7], c[3]]


def _hsalsa20(key, nonce16):
    x = _salsa_state(key, nonce16)
    _salsa20_rounds(x)
    return struct.pack("<8I", x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9])


def _xsalsa20_stream(key, nonce24, n):
    sub = _hsalsa20(key, nonce24[:16])
    out = bytearray()
    ctr = 0
    while len(out) < n:
        s = _salsa_state(sub, nonce24[16:24] + struct.pack("<Q", ctr))
        x = list(s)
        _salsa20_rounds(x)
        out += struct.pack("<16I", *[(x[i] + s[i]) & _M32 for i in range(16)])
        ctr += 1
    return bytes(out[:n])


def _poly1305(msg, key32):
    r = int.from_bytes(key32[:16], "little") & 0x0ffffffc0ffffffc0ffffffc0fffffff
    s = int.from_bytes(key32[16:], "little")
    p = (1 << 130) - 5
    acc = 0
    for i in range(0, len(msg), 16):
        acc = ((acc + int.from_bytes(msg[i:i + 16] + b"\x01", "little")) * r) % p
    return ((acc + s) % (1 << 128)).to_bytes(16, "little")


def secretbox_easy(msg, nonce24, key):
    """libsodium crypto_secretbox_easy: MAC(16) || ciphertext."""
    ks = _xsalsa20_stream(key, nonce24, 32 + len(msg))
    ct = bytes(a ^ b for a, b in zip(msg, ks[32:]))
    return _poly1305(ct, ks[:32]) + ct


def secretbox_open_easy(box, nonce24, key):
    """The plaintext, or None when the MAC does not verify."""
    if len(box) < 16:
        return None
    ks = _xsalsa20_stream(key, nonce24, len(box) + 16)
    if not hmac.compare_digest(_poly1305(box[16:], ks[:32]), box[:16]):
        return None
    return bytes(a ^ b for a, b in zip(box[16:], ks[32:]))


def sx_secret_box(msg, key, nonce24):
    """sxSecretBox's framing: the shim draws a fresh 24-byte nonce and returns
    nonce || MAC || ciphertext (sodium_shim.c sxt_secretbox: randombytes_buf,
    then crypto_secretbox_easy after it). The nonce is a PARAMETER here - a
    model cannot vouch for a nonce it did not draw, which is why M9 is the
    execution gate's to prove, on the real library."""
    assert len(key) == 32 and len(nonce24) == 24
    return nonce24 + secretbox_easy(msg, nonce24, key)


def sx_secret_box_open(blob, key):
    """sxSecretBoxOpen: the plaintext, or ValueError where the .lcb THROWS
    (sxt_secretbox_open: shorter than nonce + MAC, a wrong key length, or a
    MAC that does not verify - wrong key or tampered data)."""
    if len(key) != 32:
        raise ValueError("wrong key length")
    if len(blob) < 24 + 16:
        raise ValueError("ciphertext too short")
    out = secretbox_open_easy(blob[24:], blob[:24], key)
    if out is None:
        raise ValueError("wrong key or tampered data")
    return out


def lc_base64_decode(text):
    """base64Decode as the shipped callers see it: whitespace and characters
    outside the alphabet ignored, a short final quantum decoded as far as it
    goes. The engine's exact treatment of a malformed tail is NOT documented;
    every row that feeds this a truncated string asserts only what holds under
    ANY such decoder - that it yields fewer bytes than the whole."""
    t = "".join(c for c in text if c.isalnum() or c in "+/")
    if len(t) % 4 == 1:
        t = t[:-1]
    return base64.b64decode(t + "=" * (-len(t) % 4))


def qs_key_opens_verifier(key, b64_verify):
    """qsKeyOpensVerifier: False when sxSecretBoxOpen throws; else whether the
    plaintext reads kQsVerify. `is` folds case on the engine (caseSensitive is
    false by default), so the compare does too - it cannot matter here, since
    no wrong key produces a MAC that verifies."""
    try:
        out = sx_secret_box_open(lc_base64_decode(b64_verify), key)
    except ValueError:
        return False
    return out.decode("latin-1").lower() == QS_VERIFY.lower()


# ---- chFeedValue / chReadFeed: the Channels feed seal (section 6.4, M9) ------

CH_ENC_MARKER = "BTXENC2:"   # chEncMarker()


def ch_feed_value(feed, feed_key, nonce24):
    """chFeedValue for a channel WITH a passphrase: the marker, then
    sxSecretBox(textEncode(feed, "UTF-8"), chFeedKey(pass, pub)). (Without a
    passphrase it is the plain UTF-8, and a private channel that cannot
    encrypt yields empty - neither is what M9 is about.)"""
    return CH_ENC_MARKER.encode("ascii") + sx_secret_box(feed.encode("utf-8"),
                                                         feed_key, nonce24)


def ch_read_feed(raw, feed_key):
    """chReadFeed with a passphrase: "BADPASS" when the box does not open or
    the plaintext is not a feed ("name=..."), else the feed text."""
    if len(raw) > 8 and raw[:8].decode("ascii", "replace") == CH_ENC_MARKER:
        try:
            plain = sx_secret_box_open(raw[8:], feed_key).decode("utf-8", "replace")
        except ValueError:
            return "BADPASS"
        return plain if plain.startswith("name=") else "BADPASS"
    return raw.decode("utf-8", "replace")


# ---- oxIsValidAddress (onionxt/src/onionxt.livecodescript) -------------------

_B32 = "abcdefghijklmnopqrstuvwxyz234567"


def onion_address(pubkey32):
    """A v3 address for a public key: base32(pubkey || checksum || 0x03)."""
    chk = hashlib.sha3_256(b".onion checksum" + pubkey32 + b"\x03").digest()[:2]
    return base64.b32encode(pubkey32 + chk + b"\x03").decode("ascii").lower() + ".onion"


def onion_valid(addr):
    """oxIsValidAddress with SodiumXT present (so the checksum is checked):
    trim, lowercase, strip ONE trailing ".onion", then 56 base32 characters
    decoding to 35 bytes, version byte 3, checksum equal. Note what the strip
    admits: the 56-character core alone is valid too - which matters to a
    truncated code (see receive_onion_route)."""
    core = addr.strip(" \t\r\n").lower()
    if core.endswith(".onion"):
        core = core[:-6]
    if len(core) != 56 or any(c not in _B32 for c in core):
        return False
    raw = base64.b32decode(core.upper())
    if len(raw) != 35 or raw[34] != 3:
        return False
    return hashlib.sha3_256(b".onion checksum" + raw[:32] + b"\x03").digest()[:2] == raw[32:34]


def lc_item(text, n, delim=":"):
    """`item n of text` (1-based): empty past the end. A trailing delimiter
    adds no item, which the split below reproduces for every n >= 1."""
    parts = text.split(delim)
    return parts[n - 1] if n <= len(parts) else ""


# ---- qsReceiveOnion's parse, up to the dial ----------------------------------

def receive_onion_route(code, typed_pass, derive_key, can_encrypt=True):
    """qsReceiveOnion's decisions in its own order, stopping where the network
    would start. ("refuse", why): a message and no dial. ("confirm-plaintext",
    onion, name): the "This Tor code is not encrypted ... Download anyway"
    dialog, then a dial with NO key. ("dial-locked", onion, name, key): the
    passphrase checked LOCALLY against the verifier, then a dial with the key.
    derive_key(pass, salt) stands in for sxPwHash(pass, salt, 32, "2",
    sxPwMemInteractive()) and raises where that throws (a salt that is not 16
    bytes: the script's catch says "malformed salt"). The capability and
    readiness gates around it (sHasOnion, qsOnionReadyNow) are not modelled:
    they refuse or pass independently of the code's text."""
    rest = code[len(CODE_PREFIX):]
    onion = lc_item(rest, 1)
    b64name = lc_item(rest, 2)
    b64salt = lc_item(rest, 3)
    b64verify = lc_item(rest, 4)
    if not onion_valid(onion):
        return ("refuse", "malformed address")
    try:
        name = safe_leaf(lc_base64_decode(b64name).decode("utf-8", "replace"))
    except (ValueError, TypeError):
        name = "shared-file"
    if b64verify != "":
        if not can_encrypt:
            return ("refuse", "cannot decrypt")
        if typed_pass == "":
            return ("refuse", "locked - type the passphrase")
        if b64salt == "":
            return ("refuse", "missing its salt")
        try:
            key = derive_key(typed_pass, lc_base64_decode(b64salt))
        except ValueError:
            return ("refuse", "malformed salt")
        if not qs_key_opens_verifier(key, b64verify):
            return ("refuse", "passphrase does not match")
        return ("dial-locked", onion, name, key)
    return ("confirm-plaintext", onion, name)


# ---- register #17: the LAST pre-Model-C QuickShare ---------------------------
#
# WHICH BUILD. The QuickShare before Model C lives in the pre-suite TorrentXT
# repository, not in this tree's history (the suite was assembled on
# 2026-08-07 with Model C already in): examples/torrent-quickshare.
# livecodescript as last changed by commit 05dc02f (2026-06-29, "examples:
# check the passphrase before download + clean up the .enc after decrypt"),
# unchanged at 50218ef, the parent of 7414dfe ("quickshare: optional Tor
# anonymity (Model C) via OnionXT", 2026-07-02, the commit that introduced
# kTorCodePrefix); git blob e43cfddcea38b897568a92706ace3c4adba2b722.
# (ONIONXT-INTEGRATION-PLAN's "pre-2026-08-15" is the CHANNELS date; for
# QuickShare the boundary is 2026-07-02.) Read 2026-09-24 with `git show
# 50218ef:examples/torrent-quickshare.livecodescript` in a clone of
# https://github.com/SethMorrowSoftware/TorrentXT. Its qsGetFile, verbatim in
# every branch the rows reach (passphrase and session checks elided):
#
#     put qsTrim(field "qsRecvCode") into tCode
#     if tCode is empty then ... "Paste a code from your friend first."
#     if tCode begins with kCodePrefix then            -- "BTXQS1:"
#        ... the locked-code path ...
#     else
#        if tCode begins with "magnet:" then
#           put tCode into tMag
#        else
#           put toLower(tCode) into tCode
#           if the number of chars of tCode is not 40 and the number of
#                 chars of tCode is not 64 then
#              qsLog "That does not look like a share code (it should be 40
#                 characters)."
#              exit qsGetFile
#           end if
#           put "magnet:?xt=urn:btih:" & tCode & "&tr=" & qsTracker() into tMag
#        end if
#        put btAddMagnet(sSession, tMag, qsSaveFolder()) into tH
#
# with qsTracker() = "udp://tracker.opentrackr.org:1337/announce". `begins
# with` folds case on the engine, which cannot matter: "BTXTOR1:" begins with
# neither prefix in any case.

OLD_TRACKER = "udp://tracker.opentrackr.org:1337/announce"


def pre_model_c_route(code):
    """("refuse", message) - nothing reaches the network; ("locked", code) -
    the BTXQS1: path; ("magnet", uri) - handed to btAddMagnet."""
    code = code.strip(" \t\r\n")
    if code == "":
        return ("refuse", "Paste a code from your friend first.")
    if code.lower().startswith("btxqs1:"):
        return ("locked", code)
    if code.lower().startswith("magnet:"):
        return ("magnet", code)
    c = code.lower()
    if len(c) != 40 and len(c) != 64:
        return ("refuse", "That does not look like a share code "
                          "(it should be 40 characters).")
    return ("magnet", "magnet:?xt=urn:btih:" + c + "&tr=" + OLD_TRACKER)


def libtorrent_btih(uri, v21):
    """What libtorrent's parse_magnet_uri does with the urn:btih: value:
    40 characters go to from_hex, whose failure 2.0.x IGNORES (magnet_uri.cpp,
    2.0.10 and 2.0.11: `if (value.size() == 40) aux::from_hex(...)`, result
    dropped) and 2.1.1 refuses; 32 are base32; anything else is refused. The
    answer is the 40-hex info-hash added, or None for a refusal. from_hex
    writes each whole byte before it reads a bad digit, and a partial byte's
    high nibble too, into a zero-initialised hash. The smoke test's
    test_pre_model_c_btxtor1_magnet holds the real libtorrent to this."""
    q = uri.split("?", 1)[1]
    btih = [kv[len("xt=urn:btih:"):] for kv in q.split("&")
            if kv.startswith("xt=urn:btih:")][0]
    if len(btih) == 40:
        out = bytearray(20)
        for i in range(20):
            hi = int(btih[2 * i], 16) if btih[2 * i] in "0123456789abcdefABCDEF" else -1
            if hi < 0:
                return None if v21 else out.hex()
            out[i] = hi << 4
            lo = int(btih[2 * i + 1], 16) if btih[2 * i + 1] in "0123456789abcdefABCDEF" else -1
            if lo < 0:
                return None if v21 else out.hex()
            out[i] |= lo
        return out.hex()
    if len(btih) == 32:
        try:
            raw = base64.b32decode(btih.upper())
        except ValueError:
            return None
        return raw.hex() if len(raw) == 20 else None
    return None


# The pinned crypto inputs. NACL_* is NaCl's published secretbox vector;
# ARGON_* were derived 2026-09-24 by BOTH libsodium 1.0.18 (crypto_pwhash,
# Argon2id13) and the committed sodiumxt/src/code/x86_64-linux/sodiumxt.so
# (sxt_pwhash), which agreed - opslimit 2 and memlimit 67108864, exactly what
# sxPwHash(pass, salt, 32, "2", sxPwMemInteractive()) asks for. VERIFY_BLOB is
# kQsVerify sealed under ARGON_KEY_RIGHT with VERIFY_NONCE by libsodium
# 1.0.18's crypto_secretbox_easy, in sxSecretBox's nonce || MAC || ct framing;
# the committed SodiumXT opened it to "BTXQSVERIFY" the same day.
NACL_KEY = bytes.fromhex(
    "1b27556473e985d462cd51197a9a46c76009549eac6474f206c4ee0844f68389")
NACL_NONCE = bytes.fromhex("69696ee955b62b73cd62bda875fc73d68219e0036b7a0b37")
NACL_M = bytes.fromhex(
    "be075fc53c81f2d5cf141316ebeb0c7b5228c52a4c62cbd44b66849b64244ffc"
    "e5ecbaaf33bd751a1ac728d45e6c61296cdc3c01233561f41db66cce314adb31"
    "0e3be8250c46f06dceea3a7fa1348057e2f6556ad6b1318a024a838f21af1fde"
    "048977eb48f59ffd4924ca1c60902e52f0a089bc76897040e082f93776384864"
    "5e0705")
NACL_C = bytes.fromhex(
    "f3ffc7703f9400e52a7dfb4b3d3305d98e993b9f48681273c29650ba32fc76ce"
    "48332ea7164d96a4476fb8c531a1186ac0dfc17c98dce87b4da7f011ec48c972"
    "71d2c20f9b928fe2270d6fb863d51738b48eeee314a7cc8ab932164548e526ae"
    "90224368517acfeabd6bb3732bc0e9da99832b61ca01b6de56244a9e88d5f9b3"
    "7973f622a43d14a6599b1f654cb45a74e355a5")
ARGON_SALT = bytes(range(0x10, 0x20))
ARGON_PASS_RIGHT = "correct horse battery staple"
ARGON_PASS_WRONG = "correct horse battery stapler"
ARGON_KEY_RIGHT = bytes.fromhex(
    "0be384fb4d3f1fe71cd986af0ffd7652da210c2eb7528e4ec61d95b53e47aa0a")
ARGON_KEY_WRONG = bytes.fromhex(
    "ce51850745ec47a675e830dcc74d213e1d4ddda9f4ef9f3988282b58ad4b82c4")
VERIFY_NONCE = bytes(range(0x40, 0x58))
VERIFY_BLOB = bytes.fromhex(
    "404142434445464748494a4b4c4d4e4f5051525354555657"
    "fbdb0b91877415966ce4ee9bb8afec5e133654987cf5757507ae7a")
# a v3 onion for the public key a0..bf (checksum computed, not typed)
ROW_ONION = onion_address(bytes(range(0xa0, 0xc0)))


def pinned_pwhash(passphrase, salt):
    """sxPwHash over the two pinned passphrases: a salt that is not 16 bytes
    throws in sxt_pwhash (crypto_pwhash_SALTBYTES), as it does here."""
    if len(salt) != 16:
        raise ValueError("wrong salt length")
    if salt != ARGON_SALT:
        raise AssertionError("no pinned Argon2id output for this salt")
    return {ARGON_PASS_RIGHT: ARGON_KEY_RIGHT,
            ARGON_PASS_WRONG: ARGON_KEY_WRONG}[passphrase]


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

    # -- full stream reassembly of a multi-frame payload, fed WHOLE (the split
    #    rows further down feed the same stream cut up) --
    payload = bytes((i * 7) % 256 for i in range(100000))     # > 1 chunk
    wire = header(b"movie.bin", False, len(payload))
    off = 0
    while off < len(payload):
        wire += frame(payload[off:off + CHUNK])
        off += CHUNK
    wire += terminator()
    nm, enc, got = reassemble(wire)
    check("reassemble name", nm, "movie.bin")
    check("reassemble enc", enc, False)
    check("reassemble payload", got, payload)

    # -- empty file: header total 0, immediate terminator --
    nm, enc, got = reassemble(header(b"empty", False, 0) + terminator())
    check("empty payload", (nm, got), ("empty", b""))
    # ...which Channels reads as "release not currently available" (design
    # 6.4, 2026-09-24), refused before the downgrade test, so an encrypted
    # follower is not told the reply was tampered with
    check("channels: a zero total is 'not available', not an empty save",
          receive(header(b"empty", False, 0) + terminator(), channels=True).outcome,
          ("abort", "not available"))
    check("channels: a zero total with a passphrase set is not a downgrade",
          receive(header(b"", False, 0) + terminator(), key=b"k" * 32,
                  channels=True).outcome,
          ("abort", "not available"))

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

    # ==== 2026-09-24: the rows section 12.2 listed as asked for, not pinned ====
    #
    # MUTATION RECORD. Each block below was run against a deliberately broken
    # mirror, one mutation at a time, and failed - the discrimination was
    # checked, not assumed (a blind row prints OK too):
    #   Receiver: nameLen's cap moved after the wait for the name; totalLen's
    #     cap made >= instead of >; the got >= total finish removed; a partial
    #     frame treated as an error instead of waited for; the header name
    #     taken raw instead of through SafeLeaf.
    #   qs_key_opens_verifier: the except answering True; the kQsVerify
    #     compare dropped.
    #   ch_read_feed: the "name=" check dropped.
    #   secretbox: one Salsa20 rotation constant changed (7 -> 8).
    #   onion_valid: the ".onion" strip removed.
    #   receive_onion_route: the verifier check skipped for a locked code.
    #   pre_model_c_route: the 40/64 length gate removed.
    #   libtorrent_btih: the 2.0.x from_hex result honoured.

    # -- the cipher model, anchored before anything stands on it: NaCl's
    #    published secretbox vector, both ways, and the pinned verifier that
    #    libsodium 1.0.18 sealed, reproduced byte for byte --
    check("secretbox model = NaCl's published vector",
          secretbox_easy(NACL_M, NACL_NONCE, NACL_KEY).hex(), NACL_C.hex())
    check("secretbox model opens NaCl's vector",
          secretbox_open_easy(NACL_C, NACL_NONCE, NACL_KEY), NACL_M)
    check("VERIFY_BLOB reproduced by the model (sxSecretBox framing)",
          sx_secret_box(QS_VERIFY.encode("ascii"), ARGON_KEY_RIGHT, VERIFY_NONCE).hex(),
          VERIFY_BLOB.hex())

    # -- BTXO SPLIT-BUFFER REASSEMBLY, the row the design called critical: the
    #    SAME multi-frame stream as above, fed in two reads that cut the header
    #    in half, then two that cut a DATA payload in half, then three reads
    #    that do both - each must save exactly what the whole stream saved --
    # (Outcomes are compared, not reassemble()'s return, so a mirror that
    # mishandles a cut fails as a named row rather than as a traceback.)
    whole = receive(wire).outcome
    check("the whole stream is saved", whole, ("saved", "movie.bin", False, payload))
    hlen = 8 + len(b"movie.bin") + 8
    header_cut = hlen // 2                   # inside the name
    payload_cut = hlen + 4 + CHUNK // 2      # inside frame 1's payload
    check("split: the header cut in half", receive(wire, [header_cut]).outcome, whole)
    check("split: a DATA payload cut in half", receive(wire, [payload_cut]).outcome,
          whole)
    check("split: both cuts, three reads",
          receive(wire, [header_cut, payload_cut]).outcome, whole)
    check("split: a frame LENGTH cut in half",
          receive(wire, [hlen + 2, hlen + 4 + CHUNK + 1]).outcome, whole)
    # exhaustively, on a small three-frame stream: EVERY two-read cut, every
    # 7-byte read size, and one byte at a time
    small = (header(b"clip.bin", False, 300) + frame(bytes(range(100)))
             + frame(bytes(range(150))) + frame(bytes(range(50))) + terminator())
    small_whole = receive(small).outcome
    check("the small stream is saved, 300 bytes",
          (small_whole[0], len(small_whole[3])), ("saved", 300))
    check("split: every two-read cut of a 3-frame stream",
          [c for c in range(1, len(small))
           if receive(small, [c]).outcome != small_whole], [])
    check("split: 7-byte reads", receive(small, range(7, len(small), 7)).outcome,
          small_whole)
    check("split: one byte at a time", receive(small, range(1, len(small))).outcome,
          small_whole)
    # the section-3.3 bound: fed in 1000-byte reads, the buffer a read leaves
    # behind never exceeds one chunk plus a partial frame header
    rx = receive(wire, range(1000, len(wire), 1000))
    check("bounded buffer: saved", rx.outcome[0], "saved")
    check("bounded buffer: < 4 + kOnionChunk left behind", rx.peak < 4 + CHUNK, True)

    # -- nameLen: 1024 is accepted; 1025 is refused from the 8-byte prologue
    #    ALONE, before a byte of the name it announces has arrived --
    name1024 = b"n" * MAX_NAME
    check("nameLen 1024 accepted",
          reassemble(header(name1024, False, 1) + frame(b"z") + terminator())[0],
          "n" * MAX_NAME)
    rx = Receiver()
    rx.feed(header(name1024, False, 1)[:8])
    check("nameLen 1024: the prologue alone waits", (rx.outcome, rx.state),
          (None, "header"))
    rx = Receiver()
    rx.feed(header(b"n" * (MAX_NAME + 1), False, 1)[:8])
    check("nameLen 1025 refused before the name arrives", rx.outcome,
          ("abort", "name too long"))
    rx = Receiver()
    rx.feed(MAGIC + struct.pack(">BBH", VER, 0, 0xFFFF))
    check("nameLen 65535 refused before the name arrives", rx.outcome,
          ("abort", "name too long"))

    # -- totalLen: exactly 8 GiB is accepted; one byte more is refused from
    #    the header alone, before any body; so is the u64 maximum --
    rx = Receiver()
    rx.feed(header(b"x", False, MAX_TOTAL))
    check("totalLen 8 GiB accepted (the transfer goes on)", (rx.outcome, rx.state),
          (None, "body"))
    rx = Receiver()
    rx.feed(header(b"x", False, MAX_TOTAL + 1))
    check("totalLen 8 GiB + 1 refused before any body", rx.outcome, ("abort", "oversized"))
    rx = Receiver()
    rx.feed(header(b"x", False, 2 ** 64 - 1))
    check("totalLen 2^64 - 1 refused", rx.outcome, ("abort", "oversized"))

    # -- the finish, as shipped: on the byte count, terminator or not --
    check("saved without its terminator",
          receive(header(b"a", False, 3) + frame(b"abc")).outcome,
          ("saved", "a", False, b"abc"))
    check("an early terminator is refused as incomplete",
          receive(header(b"a", False, 3) + frame(b"ab") + terminator()).outcome,
          ("abort", "incomplete"))
    check("more bytes than the header promised are refused",
          receive(header(b"a", False, 2) + frame(b"abc") + terminator()).outcome,
          ("abort", "incomplete"))
    check("a sender gone mid-body aborts",
          receive(header(b"a", False, 3) + frame(b"ab")).outcome, ("abort", "offline"))
    check("bytes after the finish are ignored",
          receive(header(b"a", False, 1) + frame(b"z") + terminator() + b"junk").outcome,
          ("saved", "a", False, b"z"))
    check("an oversized frame is refused from its length alone",
          receive(header(b"a", False, 10) + struct.pack(">I", CHUNK + 1)).outcome,
          ("abort", "frame too large"))
    check("the header's name replaces the code's, through SafeLeaf",
          receive(header(b"../../x.txt", False, 1) + frame(b"z"),
                  code_name="from-code").outcome[1], "x.txt")
    check("an empty header name keeps the code's",
          receive(header(b"", False, 1) + frame(b"z"), code_name="from-code").outcome[1],
          "from-code")

    # -- the two downgrade refusals (design 5.4) --
    enc_stream = header(b"report.pdf", True, 5) + frame(b"CIPHR") + terminator()
    check("a locked code refuses a plaintext header",
          receive(header(b"r", False, 1) + frame(b"z"), key=ARGON_KEY_RIGHT).outcome,
          ("abort", "downgrade"))
    check("a code with no passphrase refuses an encrypted header",
          receive(enc_stream).outcome, ("abort", "no passphrase"))
    check("an encrypted stream with the key is kept (decrypted after)",
          receive(enc_stream, key=ARGON_KEY_RIGHT).outcome,
          ("saved", "report.pdf", True, b"CIPHR"))

    # -- qsKeyOpensVerifier: the passphrase is checked LOCALLY, before any dial
    #    (design 5.4); a WRONG passphrase's Argon2id key must not open it --
    vb64 = b64(VERIFY_BLOB)
    check("verifier opens under the right passphrase's key",
          qs_key_opens_verifier(ARGON_KEY_RIGHT, vb64), True)
    check("verifier REFUSES a wrong passphrase's key",
          qs_key_opens_verifier(ARGON_KEY_WRONG, vb64), False)
    tampered = bytearray(VERIFY_BLOB)
    tampered[-1] ^= 1
    check("verifier refuses a tampered box",
          qs_key_opens_verifier(ARGON_KEY_RIGHT, b64(bytes(tampered))), False)
    check("verifier refuses a truncated box",
          qs_key_opens_verifier(ARGON_KEY_RIGHT, vb64[:-4]), False)
    check("verifier refuses an empty verifier",
          qs_key_opens_verifier(ARGON_KEY_RIGHT, ""), False)
    check("verifier refuses a box that opens but is not kQsVerify",
          qs_key_opens_verifier(ARGON_KEY_RIGHT, b64(
              sx_secret_box(b"BTXQSVERIFX", ARGON_KEY_RIGHT, VERIFY_NONCE))), False)

    # -- the Channels feed seal's framing (chFeedValue / chReadFeed). The
    #    nonce-freshness KAT itself (M9) is the execution gate's, on the real
    #    SodiumXT; what a model CAN pin is the hazard M9 exists for: one nonce
    #    used twice under one key leaks the XOR of the two feeds --
    feed = "name=Alice\nr=Demo Release\tmagnet:?xt=urn:btih:0123456789abcdef"
    n1, n2 = bytes(24), bytes([1]) + bytes(23)
    v1 = ch_feed_value(feed, ARGON_KEY_RIGHT, n1)
    check("feed seal opens", ch_read_feed(v1, ARGON_KEY_RIGHT), feed)
    check("feed seal under another key is BADPASS", ch_read_feed(v1, ARGON_KEY_WRONG),
          "BADPASS")
    check("a sealed non-feed is BADPASS", ch_read_feed(
        CH_ENC_MARKER.encode("ascii") + sx_secret_box(b"hello", ARGON_KEY_RIGHT, n1),
        ARGON_KEY_RIGHT), "BADPASS")
    check("two nonces, two different seals of one value",
          v1 != ch_feed_value(feed, ARGON_KEY_RIGHT, n2), True)
    feed2 = feed[:-1] + "X"
    c1 = v1[8 + 24 + 16:]
    c2 = ch_feed_value(feed2, ARGON_KEY_RIGHT, n1)[8 + 24 + 16:]
    check("M9's hazard: a reused nonce leaks p1 XOR p2",
          bytes(a ^ b for a, b in zip(c1, c2)),
          bytes(a ^ b for a, b in zip(feed.encode("utf-8"), feed2.encode("utf-8"))))

    # -- a TRUNCATED BTXTOR1: code (design 12.2). The address first: the row
    #    onion is valid, with and without its suffix; one character off is not --
    check("row onion is a valid v3 address", onion_valid(ROW_ONION), True)
    check("...and so is its 56-character core", onion_valid(ROW_ONION[:56]), True)
    check("...but not a truncated core", onion_valid(ROW_ONION[:55]), False)
    check("...nor a truncated suffix", onion_valid(ROW_ONION[:60]), False)
    locked = make_tor_code(ROW_ONION, "report.pdf", ARGON_SALT, VERIFY_BLOB)
    plain = make_tor_code(ROW_ONION, "report.pdf", b"", b"")

    def route(code, passphrase):
        return receive_onion_route(code, passphrase, pinned_pwhash)

    check("control: the whole locked code dials with its key",
          route(locked, ARGON_PASS_RIGHT),
          ("dial-locked", ROW_ONION, "report.pdf", ARGON_KEY_RIGHT))
    check("the whole locked code, WRONG passphrase: refused before any dial",
          route(locked, ARGON_PASS_WRONG), ("refuse", "passphrase does not match"))
    check("control: the whole plaintext code asks before it dials",
          route(plain, ""), ("confirm-plaintext", ROW_ONION, "report.pdf"))
    classes = {}
    for cut in range(len(CODE_PREFIX), len(locked)):
        classes.setdefault(route(locked[:cut], ARGON_PASS_RIGHT)[0], []).append(cut)
    check("no truncation of a locked code dials WITH a key", sorted(classes),
          ["confirm-plaintext", "refuse"])
    # FOUND 2026-09-24, pinned as found: a truncation that loses the verifier
    # but keeps a valid address is NOT refused up front. It is offered as a
    # plaintext code ("This Tor code is not encrypted ... Download anyway"),
    # and if the user accepts, the transfer dials with no key - and is then
    # refused by the encrypted header ("no passphrase" above), so nothing is
    # ever saved. Safe, but the refusal comes after a network dial and a
    # prompt that misdescribes the share. The window: the 56-character core
    # (oxIsValidAddress strips ".onion", so the bare core is valid), then
    # every cut from the end of the address to the colon before the verifier.
    onion_end = len(CODE_PREFIX) + len(ROW_ONION)
    verify_start = len(locked) - len(vb64)
    check("the plaintext-prompt window of a truncated locked code",
          classes.get("confirm-plaintext"),
          [onion_end - len(".onion")] + list(range(onion_end, verify_start + 1)))
    for cut in (onion_end, verify_start):
        r = route(locked[:cut], "")
        check("...cut at %d: offered as plaintext" % cut, r[0], "confirm-plaintext")
        check("...cut at %d: the dial that follows is refused at the header" % cut,
              receive(enc_stream, key=None, code_name=r[-1]).outcome,
              ("abort", "no passphrase"))
    check("a cut INSIDE the verifier is refused before any dial",
          route(locked[:verify_start + 10], ARGON_PASS_RIGHT),
          ("refuse", "passphrase does not match"))

    # -- REGISTER #17: the last pre-Model-C QuickShare (TorrentXT 05dc02f)
    #    fed a BTXTOR1: code. A whole code never reaches the network: it is
    #    never 40 or 64 characters, the only lengths its qsGetFile hands to
    #    btAddMagnet (the prefix and a v3 address alone are 70) --
    too_long = "That does not look like a share code (it should be 40 characters)."
    shortest = make_tor_code(ROW_ONION, "a", b"", b"")
    for label, code in (("plaintext", plain), ("locked", locked), ("shortest", shortest)):
        check("#17: a whole %s BTXTOR1 code (%d chars) is refused, no network"
              % (label, len(code)), pre_model_c_route(code), ("refuse", too_long))
    # ...but a truncation to EXACTLY 40 or 64 characters does reach it, and
    # there the answer is libtorrent's (the smoke test's
    # test_pre_model_c_btxtor1_magnet runs the real parser):
    reach = [cut for cut in range(1, len(locked) + 1)
             if pre_model_c_route(locked[:cut])[0] != "refuse"]
    check("#17: only a cut to 40 or 64 characters reaches btAddMagnet", reach, [40, 64])
    m40 = pre_model_c_route(locked[:40])[1]
    m64 = pre_model_c_route(locked[:64])[1]
    check("#17: the 40-character magnet the old build makes", m40,
          "magnet:?xt=urn:btih:" + locked[:40].lower() + "&tr=" + OLD_TRACKER)
    check("#17: 64 characters - refused by libtorrent 2.0.x and 2.1",
          (libtorrent_btih(m64, False), libtorrent_btih(m64, True)), (None, None))
    check("#17: 40 characters - refused by libtorrent 2.1", libtorrent_btih(m40, True),
          None)
    check("#17: 40 characters - ADDED by libtorrent 2.0.x as b000...0 (FOUND)",
          libtorrent_btih(m40, False), "b" + "0" * 39)
    check("libtorrent_btih control: a real 40-hex btih",
          libtorrent_btih("magnet:?xt=urn:btih:" + "ab" * 20, False), "ab" * 20)

    if _fail:
        print("onion_frame_golden: FAIL\n" + "\n".join(_fail))
        return 1
    print("onion_frame_golden: OK (%d rows: BTXO framing fed whole and split, "
          "the caps, share code, qsSafeLeaf, BTXC/BTXF, chSafeLeaf, the verifier, "
          "the feed seal, truncated codes, register #17)" % _ran[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
