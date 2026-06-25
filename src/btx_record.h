/* btx_record.h — the self-describing typed KV record codec + the field / alert
 * / type registries (plan §4.4). SINGLE SOURCE OF TRUTH for the wire framing.
 *
 * Header-only C++ with NO libtorrent dependency, so the shim and a standalone
 * sanitizer test (tests/record_handle_test.cpp) link the exact same encoder,
 * and the Python golden test (tests/record_golden_test.py) re-derives the bytes
 * independently. The LCB walker in torrent.lcb mirrors the numeric constants
 * below as `k*` constants; tools/check-record-registry.py proves the two never
 * drift.
 *
 * Framing (ALL multi-byte integers big-endian / network order — chosen once,
 * pinned by the golden test, never "fixed" later):
 *
 *   kvrecord  := [count:u16] field{count}
 *   field     := [fieldId:u8] [type:u8] [len:u16] [value:len]
 *   type      := 0=int(decimal ASCII)  1=real(decimal ASCII)  2=utf8
 *                3=raw bytes           4=hexhash (hex ASCII)
 *
 * Higher-level shapes built from kvrecord (count-prefixed lists, so the LCB
 * walker is self-contained and need not trust a return value):
 *
 *   status snapshot (btx_torrent_status, btx_dht_state) := one kvrecord
 *   alert drain (btx_pop_alerts) :=
 *        [alertCount:u16]  then alertCount x  [alertType:u16][bodyLen:u16][kvrecord]
 *   peer list (btx_peer_list) :=
 *        [peerCount:u16]   then peerCount x   [bodyLen:u16][kvrecord]
 *
 * 64-bit numbers and info-hashes ride as ASCII (decimal/hex) field values, so
 * no 64-bit binary field ever appears — there is no 64-bit foreign int (§4.1).
 */
#ifndef BTX_RECORD_H
#define BTX_RECORD_H

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>

namespace btx {

/* ------------------------------------------------------------ field types */
/* The [type] byte. LCB mirror: kTypeInt/kTypeReal/kTypeUtf8/kTypeRaw/kTypeHex. */
enum FieldType : uint8_t {
    FT_INT  = 0,  /* signed decimal ASCII; carries 64-bit ints losslessly */
    FT_REAL = 1,  /* decimal ASCII double */
    FT_UTF8 = 2,  /* UTF-8 text */
    FT_RAW  = 3,  /* opaque bytes (piece bitfield, resume data) */
    FT_HEX  = 4   /* lower-case hex ASCII (info-hash) */
};

/* --------------------------------------------------------------- field ids */
/* GLOBAL registry across every record kind, so a fieldId always means the same
 * thing. APPEND-ONLY: never reuse or renumber an id; adding one bumps the ABI.
 * LCB mirror name = the id with F_ -> kField and the rest CamelCased
 * (F_DOWNLOAD_RATE -> kFieldDownloadRate); checked by check-record-registry.py. */
enum FieldId : uint8_t {
    /* ---- torrent status (1..39) ---- */
    F_NAME              = 1,   /* utf8 */
    F_STATE             = 2,   /* int: libtorrent torrent_status::state_t */
    F_PROGRESS          = 3,   /* real: 0.0 .. 1.0 */
    F_DOWNLOAD_RATE     = 4,   /* int: payload bytes/sec */
    F_UPLOAD_RATE       = 5,   /* int: payload bytes/sec */
    F_TOTAL_DONE        = 6,   /* int (64-bit) */
    F_TOTAL_WANTED      = 7,   /* int (64-bit) */
    F_NUM_PEERS         = 8,   /* int */
    F_NUM_SEEDS         = 9,   /* int */
    F_SAVE_PATH         = 10,  /* utf8 */
    F_INFO_HASH_V1      = 11,  /* hex */
    F_INFO_HASH_V2      = 12,  /* hex */
    F_NUM_PIECES        = 13,  /* int */
    F_PIECE_LENGTH      = 14,  /* int */
    F_TOTAL_SIZE        = 15,  /* int (64-bit) */
    F_ALL_TIME_DOWNLOAD = 16,  /* int (64-bit) */
    F_ALL_TIME_UPLOAD   = 17,  /* int (64-bit) */
    F_NUM_COMPLETE      = 18,  /* int: seeds in swarm (scrape) */
    F_NUM_INCOMPLETE    = 19,  /* int: leechers in swarm (scrape) */
    F_IS_FINISHED       = 20,  /* int 0/1 */
    F_IS_SEEDING        = 21,  /* int 0/1 */
    F_IS_PAUSED         = 22,  /* int 0/1 */
    F_ERROR             = 23,  /* utf8: torrent error message ("" if none) */
    F_ETA               = 24,  /* int seconds; -1 if unknown */
    F_ADDED_TIME        = 25,  /* int unix seconds */
    F_COMPLETED_TIME    = 26,  /* int unix seconds; 0 if not complete */
    F_NUM_CONNECTIONS   = 27,  /* int */
    F_FLAGS             = 28,  /* int: low bits of torrent_flags */

    /* ---- peer entry (40..59) ---- */
    F_PEER_ENDPOINT     = 40,  /* utf8 "ip:port" */
    F_PEER_CLIENT       = 41,  /* utf8 */
    F_PEER_DOWN_RATE    = 42,  /* int */
    F_PEER_UP_RATE      = 43,  /* int */
    F_PEER_PROGRESS     = 44,  /* real 0..1 */
    F_PEER_FLAGS        = 45,  /* int */

    /* ---- alert payload (60..99) ---- */
    F_EVT_TORRENT       = 60,  /* int: OUR torrent handle id (0 if none) */
    F_EVT_MESSAGE       = 61,  /* utf8: alert.message() */
    F_EVT_ERROR_CODE    = 62,  /* int */
    F_EVT_ERROR_MESSAGE = 63,  /* utf8 */
    F_EVT_PIECE_INDEX   = 64,  /* int */
    F_EVT_STATE         = 65,  /* int: new state */
    F_EVT_PREV_STATE    = 66,  /* int: previous state */
    F_EVT_TRACKER_URL   = 67,  /* utf8 */
    F_EVT_NUM_PEERS     = 68,  /* int */
    F_EVT_RESUME_DATA   = 69,  /* raw: bencoded resume bytes */
    F_EVT_INFO_HASH_V1  = 70,  /* hex */
    F_EVT_INFO_HASH_V2  = 71,  /* hex */
    F_EVT_NAME          = 72,  /* utf8 */
    F_EVT_ENDPOINT      = 73,  /* utf8 */

    /* ---- DHT state (100..119) ---- */
    F_DHT_NODES         = 100, /* int */
    F_DHT_NODE_CACHE    = 101, /* int */
    F_DHT_GLOBAL_NODES  = 102, /* int (64-bit estimate) */
    F_DHT_TORRENTS      = 103  /* int */
};

/* ------------------------------------------------------------- alert codes */
/* OUR stable alert type codes, DECOUPLED from libtorrent's internal
 * alert::type() numbering (which is not ABI-stable across releases). The shim
 * maps each libtorrent alert to one of these. APPEND-ONLY. LCB mirror name =
 * A_ -> kAlert, rest CamelCased (A_TORRENT_ADDED -> kAlertTorrentAdded). */
enum AlertType : uint16_t {
    A_TORRENT_ADDED       = 1,
    A_METADATA_RECEIVED   = 2,
    A_PIECE_FINISHED      = 3,
    A_TORRENT_FINISHED    = 4,
    A_TORRENT_ERROR       = 5,
    A_STATE_CHANGED       = 6,
    A_TRACKER_REPLY       = 7,
    A_TRACKER_ERROR       = 8,
    A_RESUME_DATA_READY   = 9,
    A_RESUME_DATA_FAILED  = 10,
    A_TORRENT_REMOVED     = 11,
    A_DHT_BOOTSTRAP       = 12,
    A_LISTEN_SUCCEEDED    = 13,
    A_LISTEN_FAILED       = 14,
    A_TORRENT_PAUSED      = 15,
    A_TORRENT_RESUMED     = 16,
    A_FILE_COMPLETED      = 17,
    A_FILE_ERROR          = 18,
    A_STORAGE_MOVED       = 19,
    A_FASTRESUME_REJECTED = 20,
    A_SCRAPE_REPLY        = 21
};

/* ====================================================================== *
 *  RecordWriter — measure-or-write into a caller buffer.
 *
 *  Every primitive ADVANCES the write position even when the value does not
 *  fit, but only COPIES bytes while they fit wholly within `cap`. So after
 *  writing a record, pos() is the EXACT number of bytes the record needs:
 *  if overflow() is true the buffer holds nothing usable and the shim returns
 *  -pos() (i.e. -needed) so the caller can grow and retry. This is the proven
 *  bytes-written / -needed pattern (plan §6).
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
        /* len is u16; clamp defensively (no record field exceeds 64 KiB). */
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
        /* %.6g is compact and round-trips a progress fraction fine; the LCB
         * side parses it back with `the number`. */
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

/* lower-case hex of an arbitrary byte span (info-hash helper used by the shim). */
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

}  // namespace btx

#endif /* BTX_RECORD_H */
