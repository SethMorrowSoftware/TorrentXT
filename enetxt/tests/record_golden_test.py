#!/usr/bin/env python3
"""record_golden_test.py - byte-exact reference for the enetxt KV record
wire format. A PURE reference: no C++ build, no ENet, runs anywhere.
It re-derives the framing independently of src/enx_record.h and pins known byte
vectors, so the shim's C++ encoder, this Python reference, and the LCB walker
(which mirrors this byte arithmetic) cannot silently disagree.

The SAME golden byte vectors are asserted in tests/record_handle_test.cpp, so a
drift in either encoder fails against the shared literal. Endianness is network
order (big-endian) and is pinned explicitly below; never "fix" it later.

    python3 tests/record_golden_test.py
"""
import struct
import sys

# ------------------------------------------------------------------ registries
# Mirror of src/enx_record.h (kept tiny - only what the vectors touch). The
# authoritative registry lives in the header; tools/check-record-registry.py
# proves the LCB constants match it.
FT_INT, FT_REAL, FT_UTF8, FT_RAW, FT_HEX = 0, 1, 2, 3, 4
F_EN_PEER, F_EN_CHANNEL, F_EN_PAYLOAD, F_EN_DATA = 2, 3, 4, 5
F_EN_ADDRESS, F_EN_STATE = 6, 7
E_RECEIVE = 3

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

def f_raw(fid, b):
    return field(fid, FT_RAW, bytes(b))

def kvrecord(fields):
    return u16(len(fields)) + b"".join(fields)

def event_entry(event_type, fields):
    body = kvrecord(fields)
    return u16(event_type) + u16(len(body)) + body

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

# 1) Big-endianness is the load-bearing choice - pin it directly.
check("u16 big-endian 0x0102", u16(0x0102) == b"\x01\x02")
check("u16 big-endian 18", u16(18) == b"\x00\x12")

# 2) Golden vector B: { F_EN_ADDRESS utf8 "ab" }
rec_b = kvrecord([f_utf8(F_EN_ADDRESS, "ab")])
GOLD_B = bytes([0x00, 0x01, 0x06, 0x02, 0x00, 0x02, 0x61, 0x62])
check("golden B bytes", rec_b == GOLD_B)

# 3) Golden vector A: { F_EN_DATA int 42, F_EN_STATE real 0.5 } (the real is
#    a framing pin; F_EN_PACKET_LOSS is the real-typed field in live use).
rec_a = kvrecord([f_int(F_EN_DATA, 42), f_real(F_EN_STATE, 0.5)])
GOLD_A = bytes([0x00, 0x02, 0x05, 0x00, 0x00, 0x02, 0x34, 0x32,
                0x07, 0x01, 0x00, 0x03, 0x30, 0x2E, 0x35])
check("golden A bytes", rec_a == GOLD_A)

# 4) Golden drain: 1 x E_RECEIVE { F_EN_PEER=7, F_EN_CHANNEL=3,
#    F_EN_PAYLOAD "hi" (utf8-typed here as a framing pin) }
dr = drain([event_entry(E_RECEIVE,
                        [f_int(F_EN_PEER, 7), f_int(F_EN_CHANNEL, 3),
                         f_utf8(F_EN_PAYLOAD, "hi")])])
GOLD_DRAIN = bytes([0x00, 0x01,
                    0x00, 0x03, 0x00, 0x12,
                    0x00, 0x03,
                    0x02, 0x00, 0x00, 0x01, 0x37,
                    0x03, 0x00, 0x00, 0x01, 0x33,
                    0x04, 0x02, 0x00, 0x02, 0x68, 0x69])
check("golden drain bytes", dr == GOLD_DRAIN)

# 5) Round-trip: encode -> decode -> compare
fields, off = read_kvrecord(rec_a, 0)
check("roundtrip A consumed all", off == len(rec_a))
check("roundtrip A field count", len(fields) == 2)
check("roundtrip A data", fields[0] == (F_EN_DATA, FT_INT, b"42"))
check("roundtrip A state-real", fields[1] == (F_EN_STATE, FT_REAL, b"0.5"))

# 6) Decode the drain
ecount, off = read_u16(dr, 0)
check("drain count", ecount == 1)
etype, off = read_u16(dr, off)
check("drain type", etype == E_RECEIVE)
blen, off = read_u16(dr, off)
body_start = off
fields, off = read_kvrecord(dr, off)
check("drain bodyLen exact", off - body_start == blen)
check("drain consumed all", off == len(dr))
check("drain peer", fields[0] == (F_EN_PEER, FT_INT, b"7"))
check("drain channel", fields[1] == (F_EN_CHANNEL, FT_INT, b"3"))
check("drain text", fields[2] == (F_EN_PAYLOAD, FT_UTF8, b"hi"))

# 7) Raw bytes survive verbatim (a binary message payload)
raw = kvrecord([f_raw(F_EN_PAYLOAD, b"\xff\x80\x00")])
fields, off = read_kvrecord(raw, 0)
check("raw roundtrip", fields[0] == (F_EN_PAYLOAD, FT_RAW, b"\xff\x80\x00"))

# 8) Empty value field is legal
empty = kvrecord([f_utf8(15, "")])
fields, off = read_kvrecord(empty, 0)
check("empty field", fields[0] == (15, FT_UTF8, b"") and off == len(empty))

if fails:
    print("%d golden failure(s)" % fails)
    sys.exit(1)
print("record_golden_test: all enetxt wire-format vectors pinned OK")
sys.exit(0)
