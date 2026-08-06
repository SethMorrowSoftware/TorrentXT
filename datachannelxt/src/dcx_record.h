/* dcx_record.h — the self-describing typed KV record codec + the field / event
 * / state registries. SINGLE SOURCE OF TRUTH for the wire framing.
 *
 * The codec is carried BYTE-FOR-BYTE from TorrentXT (btx_record.h) — same
 * framing, same golden vectors, same LCB walker arithmetic — so every binding
 * in the family speaks one wire format. Only the registries (field ids, event
 * codes, state enums) are DataChannelXT's own.
 *
 * Header-only C++ with NO libdatachannel dependency, so the shim and a
 * standalone sanitizer test (tests/record_handle_test.cpp) link the exact same
 * encoder, and the Python golden test (tests/record_golden_test.py) re-derives
 * the bytes independently. The LCB walker in datachannel.lcb mirrors the
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
 *   status snapshot (dcx_selected_candidate_pair) := one kvrecord
 *   event drain (dcx_poll) :=
 *        [eventCount:u16]  then eventCount x  [eventType:u16][bodyLen:u16][kvrecord]
 *
 * 64-bit numbers would ride as ASCII field values (there is no 64-bit foreign
 * int); nothing in this binding's Phase-1 surface needs one, but the rule holds.
 */
#ifndef DCX_RECORD_H
#define DCX_RECORD_H

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>

namespace dcx {

/* ------------------------------------------------------------ field types */
/* The [type] byte. LCB mirror: kTypeInt/kTypeReal/kTypeUtf8/kTypeRaw/kTypeHex. */
enum FieldType : uint8_t {
    FT_INT  = 0,  /* signed decimal ASCII; carries 64-bit ints losslessly */
    FT_REAL = 1,  /* decimal ASCII double */
    FT_UTF8 = 2,  /* UTF-8 text */
    FT_RAW  = 3,  /* opaque bytes (a binary data-channel message) */
    FT_HEX  = 4   /* lower-case hex ASCII */
};

/* --------------------------------------------------------------- field ids */
/* GLOBAL registry across every record kind, so a fieldId always means the same
 * thing. APPEND-ONLY: never reuse or renumber an id; adding one bumps the ABI.
 * LCB mirror name = the id with F_ -> kField and the rest CamelCased
 * (F_DC_SDP_TYPE -> kFieldDcSdpType); checked by check-record-registry.py. */
enum FieldId : uint8_t {
    F_DC_PEER        = 1,   /* int: OUR peer-connection handle (0 if none)      */
    F_DC_CHANNEL     = 2,   /* int: OUR data-channel handle (0 if none)         */
    F_DC_SDP         = 3,   /* utf8: a whole SDP description                    */
    F_DC_SDP_TYPE    = 4,   /* utf8: "offer" / "answer"                        */
    F_DC_CANDIDATE   = 5,   /* utf8: one ICE candidate line                     */
    F_DC_MID         = 6,   /* utf8: the candidate's media id ("" when absent)  */
    F_DC_STATE       = 7,   /* int: a PS_* / GS_* state value (see below)       */
    F_DC_LABEL       = 8,   /* utf8: data-channel label                         */
    F_DC_PROTOCOL    = 9,   /* utf8: data-channel subprotocol ("" when none)    */
    F_DC_PAYLOAD     = 10,  /* raw: one BINARY message's bytes                  */
    F_DC_TEXT        = 11,  /* utf8: one TEXT message's characters              */
    F_DC_ERROR       = 12,  /* utf8: an error message                           */
    F_DC_DROPPED     = 13,  /* int: events dropped since the last drain         */
    F_DC_LOCAL_CAND  = 14,  /* utf8: selected pair, local candidate             */
    F_DC_REMOTE_CAND = 15,  /* utf8: selected pair, remote candidate            */
    F_DC_STREAM_ID   = 16   /* int: the channel's SCTP stream id                */
};

/* ------------------------------------------------------------- event codes */
/* OUR stable event type codes for the dcx_poll drain, DECOUPLED from
 * libdatachannel's internals. APPEND-ONLY. LCB mirror name = E_ -> kEvent,
 * rest CamelCased (E_LOCAL_DESCRIPTION -> kEventLocalDescription). */
enum EventType : uint16_t {
    E_LOCAL_DESCRIPTION = 1,  /* peer, sdp, sdpType — ship it to the remote side */
    E_LOCAL_CANDIDATE   = 2,  /* peer, candidate, mid — ship it to the remote side */
    E_STATE_CHANGE      = 3,  /* peer, state (PS_*)                              */
    E_GATHERING_STATE   = 4,  /* peer, state (GS_*)                              */
    E_CHANNEL_INCOMING  = 5,  /* peer, channel, label, protocol — remote-opened  */
    E_CHANNEL_OPEN      = 6,  /* peer, channel — ready to send                   */
    E_CHANNEL_CLOSED    = 7,  /* peer, channel                                   */
    E_MESSAGE           = 8,  /* peer, channel, payload (binary) OR text         */
    E_CHANNEL_ERROR     = 9,  /* peer, channel, error                            */
    E_BUFFERED_LOW      = 10, /* peer, channel — send buffer drained below the threshold */
    E_QUEUE_OVERFLOW    = 11  /* dropped — the app stopped polling and the bounded
                               * inbound queue shed events; see dcx_abi.h §drain */
};

/* ---------------------------------------------------------- state values */
/* Peer-connection and gathering states, surfaced in F_DC_STATE. These MIRROR
 * libdatachannel's rtcState / rtcGatheringState numbering (which mirrors the
 * W3C states); the shim static_asserts the equality against rtc.h so an
 * upstream renumbering cannot skew us silently. LCB mirror: PS_ -> kPeerState,
 * GS_ -> kGathering (CamelCased), checked by check-record-registry.py. */
enum PeerState : uint8_t {
    PS_NEW          = 0,
    PS_CONNECTING   = 1,
    PS_CONNECTED    = 2,
    PS_DISCONNECTED = 3,
    PS_FAILED       = 4,
    PS_CLOSED       = 5
};
enum GatheringState : uint8_t {
    GS_NEW         = 0,
    GS_IN_PROGRESS = 1,
    GS_COMPLETE    = 2
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
         * real field far below 64 KiB — see kDcxMaxMessage in dcx_abi.h). */
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

}  // namespace dcx

#endif /* DCX_RECORD_H */
