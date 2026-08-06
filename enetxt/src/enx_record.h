/* enx_record.h — the self-describing typed KV record codec + the field / event
 * / state registries. SINGLE SOURCE OF TRUTH for the wire framing.
 *
 * The codec is carried BYTE-FOR-BYTE from TorrentXT (btx_record.h) — same
 * framing, same golden vectors, same LCB walker arithmetic — so every binding
 * in the family speaks one wire format. Only the registries (field ids, event
 * codes, state enums) are enetxt's own.
 *
 * Header-only C++ with NO ENet dependency, so the shim and a
 * standalone sanitizer test (tests/record_handle_test.cpp) link the exact same
 * encoder, and the Python golden test (tests/record_golden_test.py) re-derives
 * the bytes independently. The LCB walker in enet.lcb mirrors the
 * numeric constants below as `k*` constants; tools/check-record-registry.py
 * proves the two never drift.
 *
 * Framing (ALL multi-byte integers big-endian / network order — chosen once,
 * pinned by the golden test, never "fixed" later):
 *
 *   kvrecord  := [count:u16] field{count}
 *   field     := [fieldId:u8] [type:u8] [len:u16] [value:len]
 *   type      := 0=int(decimal ASCII)  1=real(decimal ASCII)  2=utf8
 *                3=raw bytes           4=hexhash (hex ASCII)
 *
 * Higher-level shapes built from kvrecord:
 *
 *   status snapshot (enx_peer_status / enx_host_status) := one kvrecord
 *   event drain (enx_poll) :=
 *        [eventCount:u16]  then eventCount x  [eventType:u16][bodyLen:u16][kvrecord]
 *
 * 64-bit numbers would ride as ASCII field values (there is no 64-bit foreign
 * int); nothing in this binding's Phase-1 surface needs one, but the rule holds.
 */
#ifndef ENX_RECORD_H
#define ENX_RECORD_H

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>

namespace enx {

/* ------------------------------------------------------------ field types */
/* The [type] byte. LCB mirror: kTypeInt/kTypeReal/kTypeUtf8/kTypeRaw/kTypeHex. */
enum FieldType : uint8_t {
    FT_INT  = 0,  /* signed decimal ASCII; carries 64-bit ints losslessly */
    FT_REAL = 1,  /* decimal ASCII double */
    FT_UTF8 = 2,  /* UTF-8 text */
    FT_RAW  = 3,  /* opaque bytes (a received packet payload) */
    FT_HEX  = 4   /* lower-case hex ASCII */
};

/* --------------------------------------------------------------- field ids */
/* GLOBAL registry across every record kind, so a fieldId always means the same
 * thing. APPEND-ONLY: never reuse or renumber an id; adding one bumps the ABI.
 * LCB mirror name = the id with F_ -> kField and the rest CamelCased
 * (F_EN_PACKET_LOSS -> kFieldEnPacketLoss); checked by check-record-registry.py. */
enum FieldId : uint8_t {
    F_EN_HOST           = 1,   /* int: OUR host handle (0 if none)              */
    F_EN_PEER           = 2,   /* int: OUR peer handle (0 if none)              */
    F_EN_CHANNEL        = 3,   /* int: the 0-based ENet channel id              */
    F_EN_PAYLOAD        = 4,   /* raw: one received packet's bytes              */
    F_EN_DATA           = 5,   /* int: the u32 rider on connect/disconnect      */
    F_EN_ADDRESS        = 6,   /* utf8: the peer's "a.b.c.d:port"              */
    F_EN_STATE          = 7,   /* int: an EPS_* peer state (see below)          */
    F_EN_RTT            = 8,   /* int: smoothed round-trip time, ms             */
    F_EN_PACKET_LOSS    = 9,   /* real: mean packet loss, 0..1                  */
    F_EN_PACKETS_SENT   = 10,  /* int: packets sent to this peer                */
    F_EN_PACKETS_LOST   = 11,  /* int: packets lost to this peer                */
    F_EN_BYTES_SENT     = 12,  /* int: total data bytes sent to this peer       */
    F_EN_BYTES_RECEIVED = 13,  /* int: total data bytes received from this peer */
    F_EN_PEER_COUNT     = 14,  /* int: a host's connected-peer count            */
    F_EN_ERROR          = 15   /* utf8: an error message                        */
};

/* ------------------------------------------------------------- event codes */
/* OUR stable event type codes for the enx_poll drain, DECOUPLED from ENet's
 * ENetEventType numbering. APPEND-ONLY. LCB mirror name = E_ -> kEvent, rest
 * CamelCased (E_RECEIVE -> kEventReceive). */
enum EventType : uint16_t {
    E_CONNECT    = 1,  /* host, peer, address, data — the handshake completed
                        * (outgoing enConnect confirmed, or an incoming peer;
                        * the peer HANDLE for an incoming peer is BORN in this
                        * event — script learns it here)                        */
    E_DISCONNECT = 2,  /* host, peer, data — the handle is retired AFTER this
                        * event is written; using it later is a no-op          */
    E_RECEIVE    = 3,  /* host, peer, channel, payload — one packet's bytes,
                        * copied out before the packet is destroyed            */
    E_ERROR      = 4   /* host, error (+peer when known) — e.g. an inbound
                        * packet over the message budget, dropped WHOLE        */
};

/* ---------------------------------------------------------- state values */
/* ENet peer states, surfaced in F_EN_STATE by enPeerStatus. These MIRROR
 * ENetPeerState's numbering; the shim static_asserts the equality against
 * enet.h so an upstream renumbering cannot skew the LCB constants silently.
 * LCB mirror: EPS_ -> kPeerState (CamelCased), checked by the registry gate.
 * Script mostly cares about CONNECTED (5) and DISCONNECTED (0); the rest are
 * the handshake/teardown ladder between them. */
enum PeerState : uint8_t {
    EPS_DISCONNECTED           = 0,
    EPS_CONNECTING             = 1,
    EPS_ACKNOWLEDGING_CONNECT  = 2,
    EPS_CONNECTION_PENDING     = 3,
    EPS_CONNECTION_SUCCEEDED   = 4,
    EPS_CONNECTED              = 5,
    EPS_DISCONNECT_LATER       = 6,
    EPS_DISCONNECTING          = 7,
    EPS_ACKNOWLEDGE_DISCONNECT = 8,
    EPS_ZOMBIE                 = 9
};

/* ------------------------------------------------------------- send flags */
/* OUR delivery-mode enum for enSend/enBroadcast, decoupled from ENet's packet
 * flag bits (reliable is ENet's flag 1, unreliable-SEQUENCED is its flag 0 —
 * exposing raw bits would make the safe default the magic number). LCB
 * mirror: SF_ -> kSend (CamelCased). */
enum SendFlag : uint8_t {
    SF_RELIABLE    = 0,  /* retransmitted until acked (the safe default)      */
    SF_UNRELIABLE  = 1,  /* sequenced, droppable — stale-able state updates   */
    SF_UNSEQUENCED = 2   /* fire-and-forget, may arrive out of order          */
};

/* ====================================================================== *
 *  RecordWriter — measure-or-write into a caller buffer.
 *
 *  Every primitive ADVANCES the write position even when the value does not
 *  fit, but only COPIES bytes while they fit wholly within `cap`. So after
 *  writing a record, pos() is the EXACT number of bytes the record needs:
 *  if overflow() is true the buffer holds nothing usable and the shim returns
 *  -pos() (i.e. -needed) so the caller can grow and retry. This is the proven
 *  bytes-written / -needed pattern.
 * ====================================================================== */
class RecordWriter {
public:
    RecordWriter(void *buf, int cap)
        : buf_(static_cast<uint8_t *>(buf)),
          cap_(cap < 0 ? 0 : static_cast<size_t>(cap)) {}

    size_t pos() const { return pos_; }
    bool overflow() const { return pos_ > cap_; }
    size_t capacity() const { return cap_; }

    void put_u8(uint8_t v) {
        if (pos_ + 1 <= cap_) buf_[pos_] = v;
        pos_ += 1;
    }
    void put_u16(uint16_t v) {           /* big-endian */
        if (pos_ + 2 <= cap_) {
            buf_[pos_]     = static_cast<uint8_t>((v >> 8) & 0xFF);
            buf_[pos_ + 1] = static_cast<uint8_t>(v & 0xFF);
        }
        pos_ += 2;
    }
    void put_bytes(const void *p, size_t n) {
        if (n && pos_ + n <= cap_) std::memcpy(buf_ + pos_, p, n);
        pos_ += n;
    }
    /* Overwrite a big-endian u16 already emitted at absolute position `at`
     * (used to backpatch a count or a bodyLen). No-op if it lies past cap. */
    void patch_u16(size_t at, uint16_t v) {
        if (at + 2 <= cap_) {
            buf_[at]     = static_cast<uint8_t>((v >> 8) & 0xFF);
            buf_[at + 1] = static_cast<uint8_t>(v & 0xFF);
        }
    }

    /* ---- typed fields: [id:u8][type:u8][len:u16][value] ---- */
    void field_raw(uint8_t id, FieldType t, const void *val, size_t n) {
        /* len is u16; clamp defensively (the shim's message cap keeps every
         * real field far below 64 KiB — see kEnxMaxMessage in enx_abi.h). */
        if (n > 0xFFFF) n = 0xFFFF;
        put_u8(id);
        put_u8(static_cast<uint8_t>(t));
        put_u16(static_cast<uint16_t>(n));
        put_bytes(val, n);
    }
    void field_bytes(uint8_t id, const void *val, size_t n) {
        field_raw(id, FT_RAW, val, n);
    }
    void field_str(uint8_t id, const char *s) {
        field_raw(id, FT_UTF8, s, s ? std::strlen(s) : 0);
    }
    void field_str(uint8_t id, const std::string &s) {
        field_raw(id, FT_UTF8, s.data(), s.size());
    }
    void field_hex(uint8_t id, const std::string &hex) {
        field_raw(id, FT_HEX, hex.data(), hex.size());
    }
    void field_int(uint8_t id, long long v) {
        char tmp[24];
        int n = std::snprintf(tmp, sizeof tmp, "%lld", v);
        field_raw(id, FT_INT, tmp, n < 0 ? 0 : static_cast<size_t>(n));
    }
    void field_uint(uint8_t id, unsigned long long v) {
        char tmp[24];
        int n = std::snprintf(tmp, sizeof tmp, "%llu", v);
        field_raw(id, FT_INT, tmp, n < 0 ? 0 : static_cast<size_t>(n));
    }
    void field_real(uint8_t id, double v) {
        char tmp[32];
        /* %.6g is compact and round-trips fine; the LCB side parses it back
         * with `the number`. */
        int n = std::snprintf(tmp, sizeof tmp, "%.6g", v);
        field_raw(id, FT_REAL, tmp, n < 0 ? 0 : static_cast<size_t>(n));
    }

private:
    uint8_t *buf_;
    size_t cap_;
    size_t pos_ = 0;
};

/* ----------------------------------------------------------------------- *
 *  KVRecord — RAII helper that emits [count:u16] then fields, backpatching
 *  the count on finish(). Increment-on-write, so the count is always exact.
 * ----------------------------------------------------------------------- */
class KVRecord {
public:
    explicit KVRecord(RecordWriter &w) : w_(w), countAt_(w.pos()) {
        w_.put_u16(0);  /* placeholder, backpatched in finish() */
    }
    void put_int (uint8_t id, long long v)            { w_.field_int(id, v);  ++n_; }
    void put_uint(uint8_t id, unsigned long long v)   { w_.field_uint(id, v); ++n_; }
    void put_real(uint8_t id, double v)               { w_.field_real(id, v); ++n_; }
    void put_str (uint8_t id, const char *s)          { w_.field_str(id, s);  ++n_; }
    void put_str (uint8_t id, const std::string &s)   { w_.field_str(id, s);  ++n_; }
    void put_hex (uint8_t id, const std::string &h)   { w_.field_hex(id, h);  ++n_; }
    void put_bytes(uint8_t id, const void *p, size_t n){ w_.field_bytes(id, p, n); ++n_; }
    void put_bool(uint8_t id, bool b)                 { w_.field_int(id, b ? 1 : 0); ++n_; }
    void finish() { w_.patch_u16(countAt_, n_); }

private:
    RecordWriter &w_;
    size_t countAt_;
    uint16_t n_ = 0;
};

/* ====================================================================== *
 *  RecordReader — minimal walker, mirror of the LCB byte arithmetic. Used by
 *  the C++ round-trip test; the authoritative cross-check is the Python golden.
 * ====================================================================== */
struct Field {
    uint8_t id;
    uint8_t type;
    const uint8_t *val;
    uint16_t len;
    std::string text() const {
        return std::string(reinterpret_cast<const char *>(val), len);
    }
    long long as_int() const { return std::strtoll(text().c_str(), nullptr, 10); }
    double as_real() const { return std::strtod(text().c_str(), nullptr); }
};

class RecordReader {
public:
    RecordReader(const void *buf, size_t len)
        : p_(static_cast<const uint8_t *>(buf)), end_(p_ + len) {}

    static uint16_t rd_u16(const uint8_t *p) {
        return static_cast<uint16_t>((p[0] << 8) | p[1]);
    }
    bool remaining() const { return p_ < end_; }
    size_t bytes_left() const { return static_cast<size_t>(end_ - p_); }
    const uint8_t *cursor() const { return p_; }
    void skip(size_t n) { p_ += n; }

    /* Read one kvrecord starting at the cursor; appends its fields to `out` and
     * advances the cursor past it. Returns false on a malformed/truncated
     * record (the walker stops rather than reads out of bounds). */
    bool read_record(std::vector<Field> &out) {
        if (bytes_left() < 2) return false;
        uint16_t count = rd_u16(p_);
        p_ += 2;
        for (uint16_t i = 0; i < count; ++i) {
            if (bytes_left() < 4) return false;
            Field f;
            f.id = p_[0];
            f.type = p_[1];
            f.len = rd_u16(p_ + 2);
            p_ += 4;
            if (bytes_left() < f.len) return false;
            f.val = p_;
            p_ += f.len;
            out.push_back(f);
        }
        return true;
    }

private:
    const uint8_t *p_;
    const uint8_t *end_;
};

/* lower-case hex of an arbitrary byte span (diagnostics helper). */
inline std::string to_hex(const uint8_t *p, size_t n) {
    static const char *d = "0123456789abcdef";
    std::string s;
    s.resize(n * 2);
    for (size_t i = 0; i < n; ++i) {
        s[2 * i]     = d[(p[i] >> 4) & 0xF];
        s[2 * i + 1] = d[p[i] & 0xF];
    }
    return s;
}

}  // namespace enx

#endif /* ENX_RECORD_H */
