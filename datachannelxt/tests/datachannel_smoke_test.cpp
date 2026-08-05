/* datachannel_smoke_test.cpp — the libdatachannel-linked smoke test for the shim.
 *
 * This is the automated gate for datachannel_shim.cpp. It links the REAL
 * libdatachannel and drives the REAL exported `dcx_*` ABI — no stubs. It runs
 * under gcc ASan+UBSan AND (separately) ThreadSanitizer, because this is the
 * family's one binding with true cross-thread concurrency: the loopback below
 * exercises the mutex-guarded event queue under libdatachannel's actual
 * callback threads, which is precisely what TSan exists to judge.
 *
 * NO external test framework (the family pattern): a tiny CHECK macro + main().
 * What we prove is THE BINDING'S SAFETY, not WebRTC — ICE/DTLS/SCTP correctness
 * is libdatachannel's own test suite's job. Covered here:
 *
 *   1. ABI + diagnostics round-trip (the calls LCB checkABI/version make).
 *   2. Handle safety: every getter/action on a bogus or freed handle is a
 *      harmless no-op (getters 0/empty/-1, actions an error code) — never a
 *      crash; the sanitizers are the judge of "never".
 *   3. The exception firewall: a forced throw surfaces as DCX_ERR_EXCEPTION
 *      with a last-error, and never unwinds across the boundary.
 *   4. THE LOOPBACK: two real peer connections in this process, SDP +
 *      candidates shuttled through the ABI exactly as an OXT app would over
 *      its signaling channel, channels open both ways, binary + text echo
 *      round-trips byte-for-byte, the selected-pair snapshot parses, and the
 *      drain's record framing walks cleanly at every step.
 *   5. Reliability options: an unordered/unreliable channel and a negotiated
 *      channel (same stream id both ends, no in-band open) both deliver.
 *   6. The bounded queue's overflow safety valve: with test-shrunk caps, a
 *      message flood sheds the tail and reports ONE E_QUEUE_OVERFLOW with the
 *      count once drained (and never wedges the stream).
 *   7. The -needed grow-and-retry contract on dcx_poll.
 *   8. Teardown: close/free/cleanup are idempotent, and after dcx_cleanup a
 *      fresh peer works again.
 */

#include "../src/datachannel_shim.h"   /* the dcx_* ABI + the dcx::test hooks */
#include "../src/dcx_record.h"         /* the same record walker the LCB mirrors */

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

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

/* Read the module-static last-error via the bytes-written / -needed contract. */
static std::string read_last_error() {
    char small[256];
    int n = dcx_last_error(small, static_cast<int>(sizeof small));
    if (n >= 0) return std::string(small, static_cast<size_t>(n));
    std::vector<char> big(static_cast<size_t>(-n));
    int m = dcx_last_error(big.data(), static_cast<int>(big.size()));
    if (m < 0) m = 0;
    return std::string(big.data(), static_cast<size_t>(m));
}

/* ---- a decoded drain event (the C++ mirror of the LCB walker's array) ----- */
struct Ev {
    uint16_t type = 0;
    long long peer = 0;
    long long channel = 0;
    long long state = -1;
    long long dropped = 0;
    std::string sdp, sdpType, cand, mid, label, protocol, text, error;
    std::vector<uint8_t> payload;
    bool hasPayload = false, hasText = false;
};

/* Drain dcx_poll and DECODE under the frozen framing, asserting well-formedness
 * as we go (each entry's kvrecord must consume exactly bodyLen). Grows once on
 * -needed, per the contract. */
static std::vector<Ev> drain_events() {
    std::vector<Ev> out;
    static std::vector<uint8_t> buf(65536);
    int n = dcx_poll(buf.data(), static_cast<int>(buf.size()));
    if (n < 0) {
        buf.resize(static_cast<size_t>(-n));
        n = dcx_poll(buf.data(), static_cast<int>(buf.size()));
    }
    CHECK(n >= 0);
    if (n <= 0) return out;

    dcx::RecordReader rd(buf.data(), buf.size());
    CHECK(rd.bytes_left() >= 2);
    uint16_t count = dcx::RecordReader::rd_u16(rd.cursor());
    rd.skip(2);
    CHECK(count == static_cast<uint16_t>(n));   /* return value == leading u16 */

    for (uint16_t i = 0; i < count; ++i) {
        CHECK(rd.bytes_left() >= 4);
        uint16_t type = dcx::RecordReader::rd_u16(rd.cursor());
        uint16_t bodyLen = dcx::RecordReader::rd_u16(rd.cursor() + 2);
        rd.skip(4);
        const uint8_t *bodyStart = rd.cursor();
        std::vector<dcx::Field> fields;
        CHECK(rd.read_record(fields));
        CHECK(static_cast<size_t>(rd.cursor() - bodyStart) == bodyLen);

        Ev ev;
        ev.type = type;
        for (const dcx::Field &f : fields) {
            switch (f.id) {
                case dcx::F_DC_PEER:        ev.peer = f.as_int(); break;
                case dcx::F_DC_CHANNEL:     ev.channel = f.as_int(); break;
                case dcx::F_DC_SDP:         ev.sdp = f.text(); break;
                case dcx::F_DC_SDP_TYPE:    ev.sdpType = f.text(); break;
                case dcx::F_DC_CANDIDATE:   ev.cand = f.text(); break;
                case dcx::F_DC_MID:         ev.mid = f.text(); break;
                case dcx::F_DC_STATE:       ev.state = f.as_int(); break;
                case dcx::F_DC_LABEL:       ev.label = f.text(); break;
                case dcx::F_DC_PROTOCOL:    ev.protocol = f.text(); break;
                case dcx::F_DC_PAYLOAD:
                    ev.hasPayload = true;
                    ev.payload.assign(f.val, f.val + f.len);
                    break;
                case dcx::F_DC_TEXT:        ev.hasText = true; ev.text = f.text(); break;
                case dcx::F_DC_ERROR:       ev.error = f.text(); break;
                case dcx::F_DC_DROPPED:     ev.dropped = f.as_int(); break;
                default: break;
            }
        }
        out.push_back(std::move(ev));
    }
    return out;
}

/* The signaling loopback: any local description/candidate event from one peer
 * is applied to the other — exactly what an OXT app does over its signaling
 * transport (DHT, copy/paste, anything). */
struct Shuttle {
    int pa = 0, pb = 0;
    void apply(const Ev &e) const {
        int dst = (e.peer == pa) ? pb : pa;
        if (e.type == dcx::E_LOCAL_DESCRIPTION)
            CHECK(dcx_set_remote_description(dst, e.sdp.c_str(), e.sdpType.c_str()) == DCX_OK);
        else if (e.type == dcx::E_LOCAL_CANDIDATE)
            CHECK(dcx_add_remote_candidate(dst, e.cand.c_str(), e.mid.c_str()) == DCX_OK);
    }
};

/* Poll+shuttle until `pred` is satisfied or the deadline passes. Every drained
 * event is offered to `sink` so tests can accumulate what they care about. */
template <typename Pred, typename Sink>
static bool pump_until(const Shuttle &sh, Pred pred, Sink sink, int timeoutMs = 20000) {
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeoutMs);
    for (;;) {
        for (const Ev &e : drain_events()) {
            sh.apply(e);
            sink(e);
        }
        if (pred()) return true;
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

/* =========================================================================
 *  1. ABI + diagnostics
 * ========================================================================= */
static void test_abi_and_diagnostics() {
    CHECK(dcx_abi_version() == DCX_ABI_VERSION);
    CHECK(dcx_init() == DCX_OK);
    CHECK(dcx_init() == DCX_OK);   /* idempotent */

    char v[128] = {0};
    int n = dcx_library_version(v, static_cast<int>(sizeof v));
    CHECK(n > 0);
    CHECK(std::string(v, static_cast<size_t>(n)).find("libdatachannel") == 0);

    /* last-error round-trip incl. the -needed path with a tiny buffer. */
    dcx_clear_error();
    CHECK(read_last_error().empty());
    CHECK(dcx_send_text(0, "x") == DCX_ERR_BAD_HANDLE);   /* plants an error */
    std::string err = read_last_error();
    CHECK(!err.empty());
    char tiny[2];
    CHECK(dcx_last_error(tiny, 1) == -static_cast<int>(err.size()));
    dcx_clear_error();
    CHECK(read_last_error().empty());
}

/* =========================================================================
 *  2. Handle safety — bogus / freed handles are harmless no-ops everywhere
 * ========================================================================= */
static void test_bogus_handles_are_noops() {
    const int bogus[] = {0, -1, -999, 1, 7, 123456, 0x7FFFFFFF};
    char buf[512];

    for (int h : bogus) {
        /* peer-scoped */
        CHECK(dcx_peer_close(h) == DCX_ERR_BAD_HANDLE);
        CHECK(dcx_set_local_description(h, "") == DCX_ERR_BAD_HANDLE);
        CHECK(dcx_set_remote_description(h, "v=0", "offer") == DCX_ERR_BAD_HANDLE);
        CHECK(dcx_add_remote_candidate(h, "candidate:x", "") == DCX_ERR_BAD_HANDLE);
        CHECK(dcx_local_description(h, buf, sizeof buf) == 0);
        CHECK(dcx_local_description_type(h, buf, sizeof buf) == 0);
        CHECK(dcx_peer_state(h) == -1);
        CHECK(dcx_gathering_state(h) == -1);
        CHECK(dcx_selected_candidate_pair(h, buf, sizeof buf) == 0);
        dcx_peer_free(h);   /* void: must simply not crash */

        /* channel-scoped */
        CHECK(dcx_channel_new(h, "x") == 0);
        CHECK(dcx_channel_new_ex(h, "x", "", 0, -1, -1, 0, -1) == 0);
        CHECK(dcx_channel_close(h) == DCX_ERR_BAD_HANDLE);
        CHECK(dcx_send_data(h, "ab", 2) == DCX_ERR_BAD_HANDLE);
        CHECK(dcx_send_text(h, "ab") == DCX_ERR_BAD_HANDLE);
        CHECK(dcx_channel_label(h, buf, sizeof buf) == 0);
        CHECK(dcx_channel_protocol(h, buf, sizeof buf) == 0);
        CHECK(dcx_channel_stream_id(h) == -1);
        CHECK(dcx_channel_is_open(h) == 0);
        CHECK(dcx_channel_peer(h) == 0);
        CHECK(dcx_channel_max_message(h) == -1);
        CHECK(dcx_buffered_amount(h) == -1);
        CHECK(dcx_set_buffered_low_threshold(h, 1024) == DCX_ERR_BAD_HANDLE);
        dcx_channel_free(h);   /* void: must simply not crash */
    }

    /* the drain with no peers: 0 events, and a tiny buffer is still fine. */
    CHECK(dcx_poll(buf, sizeof buf) == 0);
    CHECK(dcx_poll(buf, 0) == 0);
    CHECK(dcx_poll(nullptr, 0) == 0);
}

/* =========================================================================
 *  3. The exception firewall
 * ========================================================================= */
static void test_exception_firewall() {
    dcx_clear_error();
    CHECK(dcx::test::force_throw() == DCX_ERR_EXCEPTION);
    std::string err = read_last_error();
    CHECK(err.find("deliberate test throw") != std::string::npos);
    dcx_clear_error();
}

/* =========================================================================
 *  4-5. The loopback: connect, echo, options, close semantics
 * ========================================================================= */
static void test_loopback() {
    CHECK(dcx::test::live_peer_count() == 0);

    int pa = dcx_peer_new("");   /* no ICE servers: host candidates only */
    int pb = dcx_peer_new("");
    CHECK(pa > 0);
    CHECK(pb > 0);
    CHECK(pa != pb);
    CHECK(dcx::test::live_peer_count() == 2);
    CHECK(dcx_peer_state(pa) >= 0);   /* fresh peer answers (PS_NEW until told otherwise) */

    Shuttle sh{pa, pb};

    /* A opens the channel; auto-negotiation makes the offer; the shuttle
     * carries everything; B announces the incoming channel; both open. */
    int ca = dcx_channel_new(pa, "smoke");
    CHECK(ca > 0);
    CHECK(dcx_channel_peer(ca) == pa);

    int cb = 0;          /* B's channel handle, learned from E_CHANNEL_INCOMING */
    bool caOpen = false, cbOpen = false;
    std::string cbLabel;
    bool ok = pump_until(sh,
        [&] { return caOpen && cbOpen && cb != 0; },
        [&](const Ev &e) {
            if (e.type == dcx::E_CHANNEL_INCOMING && e.peer == pb) {
                cb = static_cast<int>(e.channel);
                cbLabel = e.label;
            }
            if (e.type == dcx::E_CHANNEL_OPEN) {
                if (e.channel == ca) caOpen = true;
                if (cb != 0 && e.channel == cb) cbOpen = true;
            }
        });
    CHECK(ok);
    if (!ok) {
        std::printf("  loopback never opened; last error: %s\n",
                    read_last_error().c_str());
        return;   /* the remaining checks would all cascade-fail */
    }
    CHECK(cbLabel == "smoke");
    CHECK(dcx::test::live_channel_count() == 2);
    CHECK(dcx_channel_is_open(ca) == 1);
    CHECK(dcx_channel_is_open(cb) == 1);
    CHECK(dcx_channel_peer(cb) == pb);
    CHECK(dcx_channel_stream_id(ca) >= 0);
    CHECK(dcx_channel_max_message(ca) > 0);
    CHECK(dcx_buffered_amount(ca) >= 0);
    CHECK(dcx_peer_state(pa) == dcx::PS_CONNECTED);
    CHECK(dcx_peer_state(pb) == dcx::PS_CONNECTED);

    /* channel label getter matches what the incoming event carried. */
    char lbl[64] = {0};
    int ln = dcx_channel_label(cb, lbl, static_cast<int>(sizeof lbl));
    CHECK(ln == 5 && std::memcmp(lbl, "smoke", 5) == 0);

    /* selected candidate pair: parses as one kvrecord with both fields. */
    {
        char pair[2048];
        int n = dcx_selected_candidate_pair(pa, pair, static_cast<int>(sizeof pair));
        CHECK(n > 0);
        dcx::RecordReader rd(pair, static_cast<size_t>(n));
        std::vector<dcx::Field> fields;
        CHECK(rd.read_record(fields));
        CHECK(fields.size() == 2);
        CHECK(fields[0].id == dcx::F_DC_LOCAL_CAND && fields[0].len > 0);
        CHECK(fields[1].id == dcx::F_DC_REMOTE_CAND && fields[1].len > 0);
    }

    /* --- binary echo: A -> B, byte-for-byte, then B -> A ------------------ */
    const uint8_t binMsg[] = {0x00, 0x01, 0xFF, 0x7F, 0x80, 0x00, 0x42};
    CHECK(dcx_send_data(ca, binMsg, static_cast<int>(sizeof binMsg)) == DCX_OK);

    std::vector<uint8_t> got;
    ok = pump_until(sh,
        [&] { return !got.empty(); },
        [&](const Ev &e) {
            if (e.type == dcx::E_MESSAGE && e.channel == cb && e.hasPayload)
                got = e.payload;
        });
    CHECK(ok);
    CHECK(got.size() == sizeof binMsg);
    CHECK(got.size() == sizeof binMsg &&
          std::memcmp(got.data(), binMsg, sizeof binMsg) == 0);

    CHECK(dcx_send_data(cb, got.data(), static_cast<int>(got.size())) == DCX_OK);
    std::vector<uint8_t> echoed;
    ok = pump_until(sh,
        [&] { return !echoed.empty(); },
        [&](const Ev &e) {
            if (e.type == dcx::E_MESSAGE && e.channel == ca && e.hasPayload)
                echoed = e.payload;
        });
    CHECK(ok);
    CHECK(echoed.size() == sizeof binMsg &&
          std::memcmp(echoed.data(), binMsg, sizeof binMsg) == 0);

    /* --- text message: arrives as TEXT (F_DC_TEXT), not binary ------------ */
    CHECK(dcx_send_text(ca, "hello xtalk") == DCX_OK);
    std::string gotText;
    ok = pump_until(sh,
        [&] { return !gotText.empty(); },
        [&](const Ev &e) {
            if (e.type == dcx::E_MESSAGE && e.channel == cb && e.hasText)
                gotText = e.text;
        });
    CHECK(ok);
    CHECK(gotText == "hello xtalk");

    /* --- the size budget: one byte over is refused, at-budget is fine ----- */
    {
        std::vector<uint8_t> big(DCX_MAX_MESSAGE + 1, 0xAB);
        CHECK(dcx_send_data(ca, big.data(), static_cast<int>(big.size())) == DCX_ERR_TOO_LARGE);
        std::string bigText(DCX_MAX_MESSAGE + 1, 'x');
        CHECK(dcx_send_text(ca, bigText.c_str()) == DCX_ERR_TOO_LARGE);
    }

    /* --- reliability options (channel_new_ex) over the LIVE association --- */
    CHECK(dcx_channel_new_ex(pa, "bad", "", 0, 3, 3000, 0, -1) == 0);   /* both set */
    CHECK(dcx_channel_new_ex(pa, "bad", "", 0, -1, -1, 0, 70000) == 0); /* id range */

    int ua = dcx_channel_new_ex(pa, "rt", "smoke-proto", 1, 0, -1, 0, -1);
    CHECK(ua > 0);
    int ub = 0;
    bool uaOpen = false, ubOpen = false;
    ok = pump_until(sh,
        [&] { return uaOpen && ubOpen && ub != 0; },
        [&](const Ev &e) {
            if (e.type == dcx::E_CHANNEL_INCOMING && e.peer == pb && e.label == "rt")
                ub = static_cast<int>(e.channel);
            if (e.type == dcx::E_CHANNEL_OPEN) {
                if (e.channel == ua) uaOpen = true;
                if (ub != 0 && e.channel == ub) ubOpen = true;
            }
        });
    CHECK(ok);
    if (ok) {
        char proto[64] = {0};
        int pn = dcx_channel_protocol(ub, proto, static_cast<int>(sizeof proto));
        CHECK(pn == 11 && std::memcmp(proto, "smoke-proto", 11) == 0);
        /* unreliable-mode delivery still works on a lossless loopback */
        CHECK(dcx_send_text(ua, "rt-ping") == DCX_OK);
        std::string rt;
        ok = pump_until(sh, [&] { return !rt.empty(); }, [&](const Ev &e) {
            if (e.type == dcx::E_MESSAGE && e.channel == ub && e.hasText) rt = e.text;
        });
        CHECK(ok);
        CHECK(rt == "rt-ping");
    }

    /* --- negotiated channels: same stream id both ends, no in-band open --- */
    int na = dcx_channel_new_ex(pa, "neg", "", 0, -1, -1, 1, 9);
    int nb = dcx_channel_new_ex(pb, "neg", "", 0, -1, -1, 1, 9);
    CHECK(na > 0);
    CHECK(nb > 0);
    bool naOpen = false, nbOpen = false;
    ok = pump_until(sh,
        [&] { return naOpen && nbOpen; },
        [&](const Ev &e) {
            if (e.type == dcx::E_CHANNEL_OPEN) {
                if (e.channel == na) naOpen = true;
                if (e.channel == nb) nbOpen = true;
            }
        });
    CHECK(ok);
    if (ok) {
        CHECK(dcx_channel_stream_id(na) == 9);
        CHECK(dcx_send_text(na, "negotiated!") == DCX_OK);
        std::string ng;
        ok = pump_until(sh, [&] { return !ng.empty(); }, [&](const Ev &e) {
            if (e.type == dcx::E_MESSAGE && e.channel == nb && e.hasText) ng = e.text;
        });
        CHECK(ok);
        CHECK(ng == "negotiated!");
    }

    /* --- backpressure surface (smoke level): threshold set succeeds ------- */
    CHECK(dcx_set_buffered_low_threshold(ca, 4096) == DCX_OK);

    /* --- close semantics: closing A's channel surfaces closed on B -------- */
    CHECK(dcx_channel_close(ca) == DCX_OK);
    bool cbClosed = false;
    ok = pump_until(sh,
        [&] { return cbClosed; },
        [&](const Ev &e) {
            if (e.type == dcx::E_CHANNEL_CLOSED && e.channel == cb) cbClosed = true;
        });
    CHECK(ok);
    CHECK(dcx_channel_is_open(ca) == 0);
    /* a send on the closed channel fails loudly, never crashes */
    CHECK(dcx_send_text(ca, "into the void") < 0);

    /* =====================================================================
     *  6. The bounded queue's overflow safety valve (test-shrunk caps)
     * ===================================================================== */
    {
        /* Stop draining, shrink the queue to 4 events, then let B flood A. */
        dcx::test::set_queue_caps(4, 0);
        const int kFlood = 30;
        for (int i = 0; i < kFlood; ++i)
            CHECK(dcx_send_text(nb, ("flood " + std::to_string(i)).c_str()) == DCX_OK);

        /* Wait (without polling!) until the queue is pinned at its cap and
         * the valve has shed at least one event. */
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
        while ((dcx::test::queue_depth() < 4 || dcx::test::dropped_count() == 0) &&
               std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        CHECK(dcx::test::queue_depth() == 4);
        CHECK(dcx::test::dropped_count() > 0);

        /* Drain until every sent message is accounted for. Messages still in
         * flight REFILL the shrunken queue between drains (very visible under
         * TSan's slowdown), so several shed-and-report cycles are legal; the
         * exact invariant is conservation: every message was either DELIVERED
         * (an E_MESSAGE drained) or COUNTED in an overflow report — none
         * vanish silently. */
        long long reported = 0;
        int overflowEvents = 0;
        int floodMsgs = 0;
        deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
        while (std::chrono::steady_clock::now() < deadline) {
            for (const Ev &e : drain_events()) {
                if (e.type == dcx::E_QUEUE_OVERFLOW) {
                    ++overflowEvents;
                    reported += e.dropped;
                }
                if (e.type == dcx::E_MESSAGE) ++floodMsgs;
            }
            if (reported + floodMsgs >= kFlood && dcx::test::queue_depth() == 0)
                break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        CHECK(overflowEvents >= 1);
        CHECK(reported > 0);
        CHECK(reported + floodMsgs == kFlood);   /* conservation: shed + delivered == sent */
        CHECK(dcx::test::dropped_count() == 0);  /* every shed message was reported */
        dcx::test::set_queue_caps(0, 0);         /* restore production caps */
    }

    /* =====================================================================
     *  7. dcx_poll's -needed grow-and-retry contract
     * ===================================================================== */
    {
        /* Generate at least one pending event deterministically: free B's
         * negotiated channel — A's side of the pair closes, so A gets an
         * E_CHANNEL_CLOSED (na is still live and deliverable). */
        dcx_channel_free(nb);
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
        while (dcx::test::queue_depth() == 0 &&
               std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        CHECK(dcx::test::queue_depth() > 0);

        char tiny[4];
        int r = dcx_poll(tiny, static_cast<int>(sizeof tiny));
        CHECK(r < 0);                       /* would not fit: the TRUE need */
        std::vector<uint8_t> grown(static_cast<size_t>(-r));
        int r2 = dcx_poll(grown.data(), static_cast<int>(grown.size()));
        CHECK(r2 >= 1);                     /* the grow makes progress */
    }

    /* =====================================================================
     *  8. Teardown: frees are idempotent; events for freed handles vanish
     * ===================================================================== */
    dcx_channel_free(ca);
    dcx_channel_free(ca);   /* double free: no-op */
    dcx_peer_free(pa);
    dcx_peer_free(pa);      /* double free: no-op */
    dcx_peer_free(pb);
    CHECK(dcx::test::live_peer_count() == 0);
    CHECK(dcx::test::live_channel_count() == 0);
    CHECK(dcx_peer_state(pa) == -1);        /* freed handle answers -1 now */

    /* Whatever teardown queued for freed handles is dropped at drain (the
     * stale-id rule); the drain itself stays well-formed. */
    for (int i = 0; i < 10; ++i) {
        drain_events();
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

/* =========================================================================
 *  9. Global cleanup: idempotent, and the world works again afterwards
 * ========================================================================= */
static void test_cleanup_lifecycle() {
    CHECK(dcx_cleanup() == DCX_OK);
    CHECK(dcx_cleanup() == DCX_OK);   /* idempotent */
    CHECK(dcx::test::live_peer_count() == 0);
    CHECK(dcx::test::queue_depth() == 0);

    /* After cleanup, creating a fresh peer works (libdatachannel re-inits). */
    int p = dcx_peer_new("");
    CHECK(p > 0);
    dcx_peer_free(p);
    CHECK(dcx_cleanup() == DCX_OK);
}

int main() {
    std::printf("datachannel_smoke_test: driving the real dcx_* ABI over a "
                "live libdatachannel loopback\n");
    test_abi_and_diagnostics();
    test_bogus_handles_are_noops();
    test_exception_firewall();
    test_loopback();
    test_cleanup_lifecycle();

    std::printf("%d checks, %d failures\n", g_checks, g_fail);
    return g_fail == 0 ? 0 : 1;
}
