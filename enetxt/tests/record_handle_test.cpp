/* record_handle_test.cpp — standalone sanitizer test for the two pieces that
 * do NOT need ENet and carry the binding's nastiest bug surface:
 *
 *   - enx_record.h  : the big-endian, length-prefixed KV framing + the
 *                     measure-or-write / -needed overflow contract.
 *   - enx_handle_table.h : generation-tagged handles -> stale = no-op, never a
 *                     crash, never a recycled-slot alias.
 *
 * Compiles and runs ANYWHERE (no ENet, no OpenSSL), so it is the
 * local gate while iterating. Build under gcc ASan+UBSan (clang's sanitizer
 * runtimes are not installed here, per the family CLAUDE.md):
 *
 *   g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined \
 *       -fno-sanitize-recover=all tests/record_handle_test.cpp -o /tmp/rht && /tmp/rht
 *
 * The byte-exact framing is ALSO pinned, independently, by
 * tests/record_golden_test.py — if you change the wire format, both must move.
 */
#include "../src/enx_record.h"
#include "../src/enx_handle_table.h"

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

using namespace enx;

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
        r.put_int(F_EN_PEER, 65537);
        r.put_int(F_EN_CHANNEL, 65538);
        r.put_str(F_EN_ADDRESS, "chat");
        r.put_str(F_EN_ERROR, "offer");
        r.put_int(F_EN_STATE, 2);
        unsigned char payload[3] = {0xFF, 0x80, 0x00};
        r.put_bytes(F_EN_PAYLOAD, payload, sizeof payload);
        r.put_str(F_EN_ERROR, "");  /* empty value field is legal */
        r.finish();
    }
    CHECK(!w.overflow());
    const size_t total = w.pos();

    /* raw framing: leading big-endian count == 7 fields */
    CHECK(be16(buf) == 7);

    std::vector<Field> fields;
    RecordReader rr(buf, total);
    CHECK(rr.read_record(fields));
    CHECK(fields.size() == 7);
    CHECK(!rr.remaining());  /* consumed exactly */

    CHECK(fields[0].id == F_EN_PEER && fields[0].type == FT_INT && fields[0].as_int() == 65537);
    CHECK(fields[1].id == F_EN_CHANNEL && fields[1].as_int() == 65538);
    CHECK(fields[2].id == F_EN_ADDRESS && fields[2].type == FT_UTF8);
    CHECK(fields[2].text() == "chat");
    CHECK(fields[3].id == F_EN_ERROR && fields[3].text() == "offer");
    CHECK(fields[4].id == F_EN_STATE && fields[4].as_int() == 2);
    CHECK(fields[5].id == F_EN_PAYLOAD && fields[5].type == FT_RAW && fields[5].len == 3);
    CHECK(fields[5].val[0] == 0xFF && fields[5].val[1] == 0x80 && fields[5].val[2] == 0x00);
    CHECK(fields[6].id == F_EN_ERROR && fields[6].len == 0);
}

/* The -needed / measure-or-write overflow contract. */
static void test_record_overflow() {
    /* First measure with a zero-capacity buffer: nothing written, pos == need */
    RecordWriter probe(nullptr, 0);
    {
        KVRecord r(probe);
        r.put_str(F_EN_ADDRESS, "hello");
        r.put_int(F_EN_PEER, 42);
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
        r.put_str(F_EN_ADDRESS, "hello");
        r.put_int(F_EN_PEER, 42);
        r.finish();
    }
    CHECK(w1.overflow());
    CHECK(w1.pos() == need);

    /* Exactly-needed buffer fits and round-trips. */
    std::vector<uint8_t> exact(need);
    RecordWriter w2(exact.data(), int(exact.size()));
    {
        KVRecord r(w2);
        r.put_str(F_EN_ADDRESS, "hello");
        r.put_int(F_EN_PEER, 42);
        r.finish();
    }
    CHECK(!w2.overflow());
    CHECK(w2.pos() == need);
    std::vector<Field> f;
    RecordReader rr(exact.data(), exact.size());
    CHECK(rr.read_record(f) && f.size() == 2);
    CHECK(f[0].text() == "hello" && f[1].as_int() == 42);
}

/* The drain framing: count-prefixed list of [eventType:u16][bodyLen:u16]
 * [kvrecord]. Mirrors exactly what the shim emits in enx_poll; the Python
 * golden pins the same bytes. */
static void write_event_entry(RecordWriter &w, uint16_t eventType,
                              const std::vector<std::pair<uint8_t, long long>> &ints,
                              const char *text = nullptr) {
    w.put_u16(eventType);
    size_t bodyAt = w.pos();
    w.put_u16(0);  /* bodyLen placeholder */
    size_t bodyStart = w.pos();
    {
        KVRecord r(w);
        for (auto &kv : ints) r.put_int(kv.first, kv.second);
        if (text) r.put_str(F_EN_PAYLOAD, text);
        r.finish();
    }
    w.patch_u16(bodyAt, uint16_t(w.pos() - bodyStart));
}

static void test_drain_framing() {
    uint8_t buf[256];
    RecordWriter w(buf, sizeof buf);
    w.put_u16(2);  /* eventCount */
    write_event_entry(w, E_RECEIVE, {{F_EN_PEER, 7}, {F_EN_CHANNEL, 3}}, "hi");
    write_event_entry(w, E_CONNECT, {{F_EN_PEER, 7}, {F_EN_CHANNEL, 3}});
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
    CHECK(t1 == E_RECEIVE);
    std::vector<Field> f1;
    const uint8_t *before = rr.cursor();
    CHECK(rr.read_record(f1));
    CHECK(size_t(rr.cursor() - before) == b1);  /* bodyLen is exact */
    CHECK(f1.size() == 3 && f1[0].as_int() == 7 && f1[1].as_int() == 3);
    CHECK(f1[2].id == F_EN_PAYLOAD && f1[2].text() == "hi");

    /* entry 2 */
    uint16_t t2 = RecordReader::rd_u16(rr.cursor());
    rr.skip(2);
    rr.skip(2);  /* bodyLen */
    CHECK(t2 == E_CONNECT);
    std::vector<Field> f2;
    CHECK(rr.read_record(f2));
    CHECK(f2.size() == 2 && f2[0].as_int() == 7);
    CHECK(!rr.remaining());
}

/* A truncated buffer must make the reader stop, not read out of bounds (ASan
 * is the real judge here). */
static void test_reader_truncation() {
    uint8_t buf[64];
    RecordWriter w(buf, sizeof buf);
    {
        KVRecord r(w);
        r.put_str(F_EN_ADDRESS, "truncate-me");
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
 * tests/record_golden_test.py, so the C++ encoder and the Python reference
 * (and by extension the LCB walker the Python mirrors) are locked together.
 * If you change the wire format, BOTH files must change in lockstep — that
 * friction is the point. */
static void expect_bytes(const char *what, const uint8_t *got, size_t gotLen,
                         const uint8_t *exp, size_t expLen) {
    ++g_checks;
    if (gotLen != expLen || std::memcmp(got, exp, expLen) != 0) {
        ++g_fail;
        std::printf("FAIL golden %s: got %zu bytes, expected %zu\n", what, gotLen, expLen);
    }
}

static void test_golden_vectors() {
    /* B: { F_EN_ADDRESS(8) utf8 "ab" } */
    {
        uint8_t buf[64];
        RecordWriter w(buf, sizeof buf);
        KVRecord r(w);
        r.put_str(F_EN_ADDRESS, "ab");
        r.finish();
        const uint8_t exp[] = {0x00, 0x01, 0x06, 0x02, 0x00, 0x02, 0x61, 0x62};
        expect_bytes("record-B", buf, w.pos(), exp, sizeof exp);
    }
    /* A: { F_EN_DATA(5) int 42, F_EN_STATE(7) real 0.5 } — the real is a
     * pure FRAMING pin (F_EN_PACKET_LOSS is the real-typed field; the codec still is). */
    {
        uint8_t buf[64];
        RecordWriter w(buf, sizeof buf);
        KVRecord r(w);
        r.put_int(F_EN_DATA, 42);
        r.put_real(F_EN_STATE, 0.5);
        r.finish();
        const uint8_t exp[] = {0x00, 0x02, 0x05, 0x00, 0x00, 0x02, 0x34, 0x32,
                               0x07, 0x01, 0x00, 0x03, 0x30, 0x2E, 0x35};
        expect_bytes("record-A", buf, w.pos(), exp, sizeof exp);
    }
    /* Drain: 1 event, E_RECEIVE(3), { F_EN_PEER(2)=7, F_EN_CHANNEL(3)=3,
     * F_EN_PAYLOAD(4) "hi" (utf8-typed framing pin) } */
    {
        uint8_t buf[64];
        RecordWriter w(buf, sizeof buf);
        w.put_u16(1);
        write_event_entry(w, E_RECEIVE, {{F_EN_PEER, 7}, {F_EN_CHANNEL, 3}}, "hi");
        const uint8_t exp[] = {0x00, 0x01,                          /* eventCount */
                               0x00, 0x03, 0x00, 0x12,              /* type, bodyLen=18 */
                               0x00, 0x03,                          /* kv count */
                               0x02, 0x00, 0x00, 0x01, 0x37,        /* id2 int "7" */
                               0x03, 0x00, 0x00, 0x01, 0x33,        /* id3 int "3" */
                               0x04, 0x02, 0x00, 0x02, 0x68, 0x69}; /* id4 utf8 "hi" */
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

/* The critical property: a recycled slot does NOT alias under the old handle.
 * This is exactly what protects a drained event that still names a channel
 * the app freed a moment earlier. */
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

/* Move-only payloads keep working (a future shim state may hold one). */
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
