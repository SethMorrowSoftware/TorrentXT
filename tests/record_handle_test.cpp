/* record_handle_test.cpp — standalone sanitizer test for the two pieces that
 * do NOT need libtorrent and carry the project's nastiest bug surface:
 *
 *   - btx_record.h  : the big-endian, length-prefixed KV framing + the
 *                     measure-or-write / -needed overflow contract.
 *   - btx_handle_table.h : generation-tagged handles -> stale = no-op, never a
 *                     crash, never a recycled-slot alias.
 *
 * Compiles and runs ANYWHERE (no Boost, no libtorrent), so it is the local
 * gate while iterating. Build under gcc ASan+UBSan (clang's ASan runtime is not
 * installed here, per CLAUDE.md):
 *
 *   g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined \
 *       -fno-sanitize-recover=all tests/record_handle_test.cpp -o /tmp/rht && /tmp/rht
 *
 * The byte-exact framing is ALSO pinned, independently, by
 * tests/record_golden_test.py — if you change the wire format, both must move.
 */
#include "../src/btx_record.h"
#include "../src/btx_handle_table.h"

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

using namespace btx;

static int g_fail = 0;
static int g_checks = 0;
#define CHECK(cond)                                                            \
    do {                                                                       \
        ++g_checks;                                                            \
        if (!(cond)) {                                                         \
            std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);        \
            ++g_fail;                                                          \
        }                                                                      \
    } while (0)

/* -------- big-endian helpers mirroring the wire, for raw byte assertions --- */
static uint16_t be16(const uint8_t *p) { return uint16_t((p[0] << 8) | p[1]); }

/* =========================================================================
 *  Record framing
 * ========================================================================= */
static void test_record_roundtrip() {
    uint8_t buf[512];
    RecordWriter w(buf, sizeof buf);
    {
        KVRecord r(w);
        r.put_str(F_NAME, "debian-12.iso");
        r.put_int(F_STATE, 3);
        r.put_real(F_PROGRESS, 0.5);
        r.put_uint(F_TOTAL_DONE, 5000000000ULL);  /* 64-bit, must survive */
        r.put_int(F_ETA, -1);
        r.put_hex(F_INFO_HASH_V1, "0123456789abcdef0123456789abcdef01234567");
        unsigned char bits[3] = {0xFF, 0x80, 0x00};
        r.put_bytes(F_EVT_RESUME_DATA, bits, sizeof bits);
        r.put_str(F_ERROR, "");  /* empty value field is legal */
        r.finish();
    }
    CHECK(!w.overflow());
    const size_t total = w.pos();

    /* raw framing: leading big-endian count == 8 fields */
    CHECK(be16(buf) == 8);

    std::vector<Field> fields;
    RecordReader rr(buf, total);
    CHECK(rr.read_record(fields));
    CHECK(fields.size() == 8);
    CHECK(!rr.remaining());  /* consumed exactly */

    CHECK(fields[0].id == F_NAME && fields[0].type == FT_UTF8);
    CHECK(fields[0].text() == "debian-12.iso");
    CHECK(fields[1].id == F_STATE && fields[1].type == FT_INT && fields[1].as_int() == 3);
    CHECK(fields[2].id == F_PROGRESS && fields[2].type == FT_REAL);
    CHECK(fields[2].as_real() > 0.49 && fields[2].as_real() < 0.51);
    CHECK(fields[3].id == F_TOTAL_DONE && fields[3].as_int() == 5000000000LL);
    CHECK(fields[4].id == F_ETA && fields[4].as_int() == -1);
    CHECK(fields[5].id == F_INFO_HASH_V1 && fields[5].type == FT_HEX);
    CHECK(fields[5].len == 40);
    CHECK(fields[6].id == F_EVT_RESUME_DATA && fields[6].type == FT_RAW && fields[6].len == 3);
    CHECK(fields[6].val[0] == 0xFF && fields[6].val[1] == 0x80 && fields[6].val[2] == 0x00);
    CHECK(fields[7].id == F_ERROR && fields[7].len == 0);
}

/* The -needed / measure-or-write overflow contract. */
static void test_record_overflow() {
    /* First measure with a zero-capacity buffer: nothing written, pos == need */
    RecordWriter probe(nullptr, 0);
    {
        KVRecord r(probe);
        r.put_str(F_NAME, "hello");
        r.put_int(F_NUM_PEERS, 42);
        r.finish();
    }
    CHECK(probe.overflow());
    const size_t need = probe.pos();
    /* count(2) + field("hello": 1+1+2+5=9) + field(42: 1+1+2+2=6) = 17 */
    CHECK(need == 17);

    /* A buffer one byte short still overflows and reports the same need. */
    std::vector<uint8_t> small(need - 1);
    RecordWriter w1(small.data(), int(small.size()));
    {
        KVRecord r(w1);
        r.put_str(F_NAME, "hello");
        r.put_int(F_NUM_PEERS, 42);
        r.finish();
    }
    CHECK(w1.overflow());
    CHECK(w1.pos() == need);

    /* Exactly-needed buffer fits and round-trips. */
    std::vector<uint8_t> exact(need);
    RecordWriter w2(exact.data(), int(exact.size()));
    {
        KVRecord r(w2);
        r.put_str(F_NAME, "hello");
        r.put_int(F_NUM_PEERS, 42);
        r.finish();
    }
    CHECK(!w2.overflow());
    CHECK(w2.pos() == need);
    std::vector<Field> f;
    RecordReader rr(exact.data(), exact.size());
    CHECK(rr.read_record(f) && f.size() == 2);
    CHECK(f[0].text() == "hello" && f[1].as_int() == 42);
}

/* The alert-drain / peer-list framing: count-prefixed list of
 * [alertType:u16][bodyLen:u16][kvrecord]. This mirrors exactly what the shim
 * emits in btx_pop_alerts, and the Python golden pins the same bytes. */
static void write_alert_entry(RecordWriter &w, uint16_t alertType,
                              const std::vector<std::pair<uint8_t, long long>> &ints) {
    w.put_u16(alertType);
    size_t bodyAt = w.pos();
    w.put_u16(0);  /* bodyLen placeholder */
    size_t bodyStart = w.pos();
    {
        KVRecord r(w);
        for (auto &kv : ints) r.put_int(kv.first, kv.second);
        r.finish();
    }
    w.patch_u16(bodyAt, uint16_t(w.pos() - bodyStart));
}

static void test_drain_framing() {
    uint8_t buf[256];
    RecordWriter w(buf, sizeof buf);
    w.put_u16(2);  /* alertCount */
    write_alert_entry(w, A_PIECE_FINISHED, {{F_EVT_TORRENT, 7}, {F_EVT_PIECE_INDEX, 123}});
    write_alert_entry(w, A_TORRENT_FINISHED, {{F_EVT_TORRENT, 7}});
    CHECK(!w.overflow());

    RecordReader rr(buf, w.pos());
    CHECK(rr.bytes_left() >= 2);
    uint16_t count = RecordReader::rd_u16(rr.cursor());
    rr.skip(2);
    CHECK(count == 2);

    /* entry 1 */
    uint16_t t1 = RecordReader::rd_u16(rr.cursor());
    rr.skip(2);
    uint16_t b1 = RecordReader::rd_u16(rr.cursor());
    rr.skip(2);
    CHECK(t1 == A_PIECE_FINISHED);
    std::vector<Field> f1;
    const uint8_t *before = rr.cursor();
    CHECK(rr.read_record(f1));
    CHECK(size_t(rr.cursor() - before) == b1);  /* bodyLen is exact */
    CHECK(f1.size() == 2 && f1[0].as_int() == 7 && f1[1].as_int() == 123);

    /* entry 2 */
    uint16_t t2 = RecordReader::rd_u16(rr.cursor());
    rr.skip(2);
    rr.skip(2);  /* bodyLen */
    CHECK(t2 == A_TORRENT_FINISHED);
    std::vector<Field> f2;
    CHECK(rr.read_record(f2));
    CHECK(f2.size() == 1 && f2[0].as_int() == 7);
    CHECK(!rr.remaining());
}

/* A truncated buffer must make the reader stop, not read out of bounds (ASan
 * is the real judge here). */
static void test_reader_truncation() {
    uint8_t buf[64];
    RecordWriter w(buf, sizeof buf);
    {
        KVRecord r(w);
        r.put_str(F_NAME, "truncate-me");
        r.finish();
    }
    for (size_t cut = 0; cut < w.pos(); ++cut) {
        std::vector<Field> f;
        RecordReader rr(buf, cut);
        rr.read_record(f);  /* must never read past `cut`; ASan enforces it */
    }
    CHECK(true);
}

/* Byte-exact golden vectors. The SAME literal byte strings are asserted in
 * tests/record_golden_test.py, so the C++ encoder and the Python reference (and
 * by extension the LCB walker the Python mirrors) are locked together. If you
 * change the wire format, BOTH files must change in lockstep — that friction is
 * the point. */
static void expect_bytes(const char *what, const uint8_t *got, size_t gotLen,
                         const uint8_t *exp, size_t expLen) {
    ++g_checks;
    if (gotLen != expLen || std::memcmp(got, exp, expLen) != 0) {
        ++g_fail;
        std::printf("FAIL golden %s: got %zu bytes, expected %zu\n", what, gotLen, expLen);
    }
}

static void test_golden_vectors() {
    /* B: { F_NAME(1) utf8 "ab" } */
    {
        uint8_t buf[64];
        RecordWriter w(buf, sizeof buf);
        KVRecord r(w);
        r.put_str(F_NAME, "ab");
        r.finish();
        const uint8_t exp[] = {0x00, 0x01, 0x01, 0x02, 0x00, 0x02, 0x61, 0x62};
        expect_bytes("record-B", buf, w.pos(), exp, sizeof exp);
    }
    /* A: { F_NUM_PEERS(8) int 42, F_PROGRESS(3) real 0.5 } */
    {
        uint8_t buf[64];
        RecordWriter w(buf, sizeof buf);
        KVRecord r(w);
        r.put_int(F_NUM_PEERS, 42);
        r.put_real(F_PROGRESS, 0.5);
        r.finish();
        const uint8_t exp[] = {0x00, 0x02, 0x08, 0x00, 0x00, 0x02, 0x34, 0x32,
                               0x03, 0x01, 0x00, 0x03, 0x30, 0x2E, 0x35};
        expect_bytes("record-A", buf, w.pos(), exp, sizeof exp);
    }
    /* Drain: 1 alert, A_PIECE_FINISHED(3), { F_EVT_TORRENT(60)=7, F_EVT_PIECE_INDEX(64)=123 } */
    {
        uint8_t buf[64];
        RecordWriter w(buf, sizeof buf);
        w.put_u16(1);
        write_alert_entry(w, A_PIECE_FINISHED, {{F_EVT_TORRENT, 7}, {F_EVT_PIECE_INDEX, 123}});
        const uint8_t exp[] = {0x00, 0x01,                          /* alertCount */
                               0x00, 0x03, 0x00, 0x0E,              /* type, bodyLen=14 */
                               0x00, 0x02,                          /* kv count */
                               0x3C, 0x00, 0x00, 0x01, 0x37,        /* id60 int "7" */
                               0x40, 0x00, 0x00, 0x03, 0x31, 0x32, 0x33}; /* id64 int "123" */
        expect_bytes("drain", buf, w.pos(), exp, sizeof exp);
    }
}

/* =========================================================================
 *  Handle table
 * ========================================================================= */
static void test_handle_basics() {
    HandleTable<std::string> t;
    int a = t.alloc("alpha");
    int b = t.alloc("bravo");
    CHECK(a > 0 && b > 0 && a != b);
    CHECK(t.live_count() == 2);
    CHECK(t.get(a) && *t.get(a) == "alpha");
    CHECK(t.get(b) && *t.get(b) == "bravo");

    /* invalid handles are no-ops */
    CHECK(t.get(0) == nullptr);
    CHECK(t.get(-5) == nullptr);
    CHECK(t.get(0x7FFFFFFF) == nullptr);

    /* free invalidates and is idempotent */
    CHECK(t.free(a));
    CHECK(t.get(a) == nullptr);
    CHECK(!t.free(a));          /* double free is a harmless no-op */
    CHECK(t.live_count() == 1);
}

/* The critical property: a recycled slot does NOT alias under the old handle. */
static void test_handle_generation() {
    HandleTable<int> t;
    int a = t.alloc(100);
    CHECK(t.free(a));
    int b = t.alloc(200);       /* very likely reuses a's slot, new generation */
    CHECK(b != a);              /* ... but is a distinct handle value */
    CHECK(t.get(a) == nullptr); /* the stale handle stays dead */
    CHECK(t.get(b) && *t.get(b) == 200);
}

/* Generation must keep advancing across many reuse cycles (and survive wrap). */
static void test_handle_reuse_churn() {
    HandleTable<int> t;
    int prev = 0;
    for (int i = 0; i < 100000; ++i) {
        int h = t.alloc(i);
        CHECK(h > 0);
        CHECK(t.get(h) && *t.get(h) == i);
        if (prev) CHECK(t.get(prev) == nullptr);  /* last cycle's handle is dead */
        CHECK(t.free(h));
        prev = h;
    }
    CHECK(t.live_count() == 0);
}

/* Move-only payloads (the shim stores unique_ptr<SessionState>). */
static void test_handle_move_only() {
    HandleTable<std::unique_ptr<int>> t;
    int h = t.alloc(std::make_unique<int>(77));
    CHECK(h > 0);
    auto *p = t.get(h);
    CHECK(p && *p && **p == 77);
    CHECK(t.free(h));
    CHECK(t.get(h) == nullptr);
}

static void test_handle_enumerate() {
    HandleTable<int> t;
    int a = t.alloc(1), b = t.alloc(2), c = t.alloc(3);
    CHECK(t.free(b));
    std::vector<int> live;
    t.collect_live(live);
    CHECK(live.size() == 2);
    bool hasA = false, hasC = false, hasB = false;
    for (int h : live) {
        if (h == a) hasA = true;
        if (h == b) hasB = true;
        if (h == c) hasC = true;
    }
    CHECK(hasA && hasC && !hasB);
}

int main() {
    test_record_roundtrip();
    test_record_overflow();
    test_drain_framing();
    test_reader_truncation();
    test_golden_vectors();
    test_handle_basics();
    test_handle_generation();
    test_handle_reuse_churn();
    test_handle_move_only();
    test_handle_enumerate();

    std::printf("%d checks, %d failures\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
