#!/usr/bin/env python3
"""bep44_golden_test.py - byte-exact reference for TorrentXT's BEP44 EXTERNAL
signing path (the btx_dht_bep44_signbuf / btx_dht_put_signed surface, ABI v9).
A PURE reference: no C++ build, no libtorrent, no third-party crypto - a
self-contained RFC 8032 Ed25519 so it runs anywhere, exactly like
record_golden_test.py.

Why this exists
---------------
For callers that must keep their signing key in their OWN crypto layer (e.g. a
SodiumXT/cryptoXT identity key that must never cross into TorrentXT), the mutable
put splits in two: the shim builds the BEP44 canonical buffer, the caller signs
it, and the shim stores the finished signature. Correctness hinges on ONE thing -
the buffer TorrentXT builds must be byte-identical to the buffer the external
signer signs and every DHT node verifies. If they drift, the store is silently
rejected by the whole network and the record just never appears.

So we pin the cross-project CONFORMANCE VECTOR (from the cryptoXT repo,
riptide/12-conformance-vectors.md): a fixed (seed, salt, seq, value) must yield a
fixed public key and a fixed BEP44 signature. The same vector is asserted in the
C++ smoke test through the real shim (tests/torrent_smoke_test.cpp), so the shim's
bep44_signbuf, this Python reference, and the SodiumXT signer that produced the
vector cannot silently disagree.

    python3 tests/bep44_golden_test.py
"""
import hashlib
import sys

# ===================================================================== #
#  Conformance vector - cryptoXT riptide/12-conformance-vectors.md
#  (salt "rp-prekeys", seq 1, value the already-bencoded string "hi" = b"2:hi").
# ===================================================================== #
ED_SEED = "cac73f09a0478224974a525036ebd73f9727ac8932162eb7fcfb2821ad7eecc7"
WANT_PUB = "672e8e0b259627f15c772ec0d61f15cd786ce2bc7244549255f9d6cfaac300b2"
SALT = b"rp-prekeys"
SEQ = 1
VALUE = b"2:hi"                       # ALREADY-BENCODED BEP44 value v
WANT_BUF = b"4:salt10:rp-prekeys3:seqi1e1:v2:hi"
WANT_SIG = ("86c843ec4cc2495e025e949dd72658ef01556dbbfb1f5d9b474b5957dbcb26a2"
            "3497efe40f594387cc4f037075669efa4c42cb57c007eb0bddaa24934f3f740b")


# ===================================================================== #
#  The one source of truth for the canonical buffer, mirrored from the shim's
#  bep44_signbuf(): [4:salt<len>:<salt>] 3:seqi<seq>e 1:v <value>, salt segment
#  omitted entirely when empty. `value` is appended verbatim (it is already the
#  bencoded v - the caller owns that encoding, so the signed and stored bytes are
#  identical). This is exactly libtorrent's own sign_mutable_item layout.
# ===================================================================== #
def bep44_signbuf(salt: bytes, seq: int, value: bytes) -> bytes:
    buf = b""
    if salt:
        buf += b"4:salt" + str(len(salt)).encode("ascii") + b":" + salt
    buf += b"3:seqi" + str(seq).encode("ascii") + b"e1:v"
    buf += value
    return buf


# ===================================================================== #
#  Minimal RFC 8032 Ed25519 (public domain, from the RFC appendix). Deterministic
#  signatures, so a fixed (seed, message) has exactly one right answer - which is
#  why it can serve as a known-answer oracle. This is the SAME primitive libsodium
#  (SodiumXT) and libtorrent implement; agreement here proves cross-stack conformance.
# ===================================================================== #
_q = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493


def _inv(x):
    return pow(x, _q - 2, _q)


_d = -121665 * _inv(121666) % _q
_I = pow(2, (_q - 1) // 4, _q)


def _xrecover(y):
    xx = (y * y - 1) * _inv(_d * y * y + 1)
    x = pow(xx, (_q + 3) // 8, _q)
    if (x * x - xx) % _q != 0:
        x = (x * _I) % _q
    if x % 2 != 0:
        x = _q - x
    return x


_By = 4 * _inv(5) % _q
_B = [_xrecover(_By) % _q, _By % _q]


def _edwards(P, Q):
    x1, y1 = P
    x2, y2 = Q
    x3 = (x1 * y2 + x2 * y1) * _inv(1 + _d * x1 * x2 * y1 * y2)
    y3 = (y1 * y2 + x1 * x2) * _inv(1 - _d * x1 * x2 * y1 * y2)
    return [x3 % _q, y3 % _q]


def _scalarmult(P, e):
    if e == 0:
        return [0, 1]
    Q = _scalarmult(P, e // 2)
    Q = _edwards(Q, Q)
    if e & 1:
        Q = _edwards(Q, P)
    return Q


def _bit(h, i):
    return (h[i // 8] >> (i % 8)) & 1


def _encodepoint(P):
    x, y = P
    b = bytearray(y.to_bytes(32, "little"))
    b[31] |= (x & 1) << 7
    return bytes(b)


def _hint(m):
    return int.from_bytes(hashlib.sha512(m).digest(), "little")


def _secret_scalar(seed):
    h = hashlib.sha512(seed).digest()
    return 2 ** 254 + sum(2 ** i * _bit(h, i) for i in range(3, 254)), h


def ed25519_publickey(seed: bytes) -> bytes:
    a, _ = _secret_scalar(seed)
    return _encodepoint(_scalarmult(_B, a))


def ed25519_sign(msg: bytes, seed: bytes, pub: bytes) -> bytes:
    a, h = _secret_scalar(seed)
    r = _hint(h[32:64] + msg)
    R = _scalarmult(_B, r)
    S = (r + _hint(_encodepoint(R) + pub + msg) * a) % _L
    return _encodepoint(R) + S.to_bytes(32, "little")


# ===================================================================== #
#  The golden assertions.
# ===================================================================== #
def main() -> int:
    fails = 0

    def check(name, cond):
        nonlocal fails
        status = "ok  " if cond else "FAIL"
        if not cond:
            fails += 1
        print("  [%s] %s" % (status, name))

    seed = bytes.fromhex(ED_SEED)

    pub = ed25519_publickey(seed)
    check("seed -> public key matches the vector", pub.hex() == WANT_PUB)

    buf = bep44_signbuf(SALT, SEQ, VALUE)
    check("canonical buffer matches the vector", buf == WANT_BUF)
    check("canonical buffer is what a verifier reconstructs",
          buf == b"4:salt" + str(len(SALT)).encode() + b":" + SALT +
          b"3:seqi" + str(SEQ).encode() + b"e1:v" + VALUE)

    sig = ed25519_sign(buf, seed, pub)
    check("detached signature matches the BEP44 vector", sig.hex() == WANT_SIG)

    # An empty salt must DROP the salt segment (BEP44), not emit "4:salt0:".
    check("empty salt omits the salt segment",
          bep44_signbuf(b"", 7, b"2:hi") == b"3:seqi7e1:v2:hi")

    print("%s (%d failure%s)" %
          ("PASS" if fails == 0 else "FAILED",
           fails, "" if fails == 1 else "s"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
