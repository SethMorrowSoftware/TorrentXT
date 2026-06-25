#!/usr/bin/env python3
"""record_golden_test.py - byte-exact reference for the TorrentXT KV record wire
format (plan §4.4, §8.3). A PURE reference: no C++ build, no libtorrent, runs
anywhere. It re-derives the framing independently of src/btx_record.h and pins
known byte vectors, so the shim's C++ encoder, this Python reference, and the
LCB walker (which mirrors this byte arithmetic) cannot silently disagree.

The SAME golden byte vectors are asserted in tests/record_handle_test.cpp, so a
drift in either encoder fails against the shared literal. Endianness is network
order (big-endian) and is pinned explicitly below; never "fix" it later.

    python3 tests/record_golden_test.py
"""
import struct
import sys

# ------------------------------------------------------------------ registries
# Mirror of src/btx_record.h (kept tiny - only what the vectors touch). The
# authoritative registry lives in the header; tools/check-record-registry.py
# proves the LCB constants match it.
FT_INT, FT_REAL, FT_UTF8, FT_RAW, FT_HEX = 0, 1, 2, 3, 4
F_NAME, F_PROGRESS, F_NUM_PEERS = 1, 3, 8
F_EVT_TORRENT, F_EVT_PIECE_INDEX = 60, 64
A_PIECE_FINISHED = 3

# --------------------------------------------------------------------- encoder
def u16(v):
    # network order / big-endian - the one pinned choice
    return struct.pack(">H", v)

def field(fid, ftype, value_bytes):
    assert len(value_bytes) <= 0xFFFF
    return bytes([fid, ftype]) + u16(len(value_bytes)) + value_bytes

def f_int(fid, v):
    return field(fid, FT_INT, str(int(v)).encode("ascii"))

def f_real(fid, v):
    return field(fid, FT_REAL, ("%.6g" % v).encode("ascii"))

def f_utf8(fid, s):
    return field(fid, FT_UTF8, s.encode("utf-8"))

def f_hex(fid, hexstr):
    return field(fid, FT_HEX, hexstr.encode("ascii"))

def f_raw(fid, b):
    return field(fid, FT_RAW, bytes(b))

def kvrecord(fields):
    return u16(len(fields)) + b"".join(fields)

def alert_entry(alert_type, fields):
    body = kvrecord(fields)
    return u16(alert_type) + u16(len(body)) + body

def drain(entries):
    return u16(len(entries)) + b"".join(entries)

# --------------------------------------------------------------------- decoder
def read_u16(buf, off):
    return struct.unpack_from(">H", buf, off)[0], off + 2

def read_kvrecord(buf, off):
    count, off = read_u16(buf, off)
    out = []
    for _ in range(count):
        fid = buf[off]; ftype = buf[off + 1]; off += 2
        ln, off = read_u16(buf, off)
        val = buf[off:off + ln]; off += ln
        out.append((fid, ftype, val))
    return out, off

# ------------------------------------------------------------------ assertions
fails = 0
def check(name, cond):
    global fails
    if not cond:
        fails += 1
        print("FAIL:", name)

def hexs(b):
    return b.hex()

# 1) Big-endianness is the load-bearing choice - pin it directly.
check("u16 big-endian 0x0102", u16(0x0102) == b"\x01\x02")
check("u16 big-endian 14", u16(14) == b"\x00\x0e")

# 2) Golden vector B: { F_NAME utf8 "ab" }
rec_b = kvrecord([f_utf8(F_NAME, "ab")])
GOLD_B = bytes([0x00, 0x01, 0x01, 0x02, 0x00, 0x02, 0x61, 0x62])
check("golden B bytes", rec_b == GOLD_B)

# 3) Golden vector A: { F_NUM_PEERS int 42, F_PROGRESS real 0.5 }
rec_a = kvrecord([f_int(F_NUM_PEERS, 42), f_real(F_PROGRESS, 0.5)])
GOLD_A = bytes([0x00, 0x02, 0x08, 0x00, 0x00, 0x02, 0x34, 0x32,
                0x03, 0x01, 0x00, 0x03, 0x30, 0x2E, 0x35])
check("golden A bytes", rec_a == GOLD_A)

# 4) Golden drain: 1 x A_PIECE_FINISHED { F_EVT_TORRENT=7, F_EVT_PIECE_INDEX=123 }
dr = drain([alert_entry(A_PIECE_FINISHED,
                        [f_int(F_EVT_TORRENT, 7), f_int(F_EVT_PIECE_INDEX, 123)])])
GOLD_DRAIN = bytes([0x00, 0x01,
                    0x00, 0x03, 0x00, 0x0E,
                    0x00, 0x02,
                    0x3C, 0x00, 0x00, 0x01, 0x37,
                    0x40, 0x00, 0x00, 0x03, 0x31, 0x32, 0x33])
check("golden drain bytes", dr == GOLD_DRAIN)

# 5) Round-trip: encode -> decode -> compare
fields, off = read_kvrecord(rec_a, 0)
check("roundtrip A consumed all", off == len(rec_a))
check("roundtrip A field count", len(fields) == 2)
check("roundtrip A num_peers", fields[0] == (F_NUM_PEERS, FT_INT, b"42"))
check("roundtrip A progress", fields[1] == (F_PROGRESS, FT_REAL, b"0.5"))

# 6) Decode the drain
acount, off = read_u16(dr, 0)
check("drain count", acount == 1)
atype, off = read_u16(dr, off)
blen, off = read_u16(dr, off)
check("drain alert type", atype == A_PIECE_FINISHED)
body_fields, end = read_kvrecord(dr, off)
check("drain bodyLen exact", end - off == blen)
check("drain piece index", body_fields[1] == (F_EVT_PIECE_INDEX, FT_INT, b"123"))

# 7) 64-bit values survive as ASCII (no 64-bit binary field, §4.1)
big = 5_000_000_000  # > 2^32, would overflow a 32-bit binary field
fields7, _ = read_kvrecord(kvrecord([f_int(6, big)]), 0)
check("64-bit as ascii", int(fields7[0][2]) == big)

if fails:
    print("%d golden FAILURES" % fails)
    sys.exit(1)
print("record_golden_test: all golden vectors and round-trips OK")
