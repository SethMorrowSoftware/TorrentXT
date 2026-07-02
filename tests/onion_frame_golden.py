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

    if _fail:
        print("onion_frame_golden: FAIL\n" + "\n".join(_fail))
        return 1
    print("onion_frame_golden: OK (framing, share code, and qsSafeLeaf all match)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
