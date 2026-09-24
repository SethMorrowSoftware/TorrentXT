/* rp1_queue_test.cpp - the bounded rp1 inbound queue, pinned at its caps.
 *
 * WHAT IT PROVES. The 2026-09-08 DoS fix in src/torrent_shim.cpp ("THE BOUNDED
 * INBOUND QUEUE"): every inbound rp1 event enters through ONE enqueue_locked,
 * which tail-drops (sheds the NEWEST event and counts it) once the queue holds
 * kRp1MaxQueueEvents events or would exceed kRp1MaxQueueBytes of cost(); the
 * drain releases the budget with the SAME cost() the enqueue charged; and the
 * shed count is reported through the last-error channel on the next drain,
 * once, until ABI 12 gives it an alert code. Before this file nothing held any
 * of that: a regression to the unbounded push_back - remote memory exhaustion
 * on a node doing nothing wrong - passed every test in the tree.
 *
 * WHY THIS FILE INCLUDES THE SHIM SOURCE. The queue is filled ONLY from
 * libtorrent's network threads, by a peer's rp1 traffic; nothing exported can
 * put an event into it, and driving it through the ABI means a second live
 * session flooding the first, which the one-session latch refuses and which
 * would test libtorrent's pacing more than our cap. The two honest ways in are
 * a new btx::test hook - a change to the shim, so by suite rule 5 a rebuild of
 * all five committed binaries - or compiling the shim INTO this test, which
 * reaches Rp1SessionPlugin (it lives in the shim's anonymous namespace) with
 * the production constants and the production code and changes nothing that
 * ships. This file takes the second. What it therefore proves is the SOURCE:
 * the committed binaries were built from this code (check-binary-freshness
 * holds the ABI; the 2026-09-12 dispatch carries the fix, per
 * docs/WORK-PLAN.md), but this test runs a fresh compile of it, not the
 * shipped library - torrent_smoke_test and rp1_integration_test are the ones
 * that link the real .so.
 *
 * The events are pushed from this (the caller's) thread through the same
 * push_event the network-thread callbacks call. The mutex makes the thread
 * immaterial to the accounting under test; rp1_integration_test is what
 * exercises the real network-thread producers.
 *
 * No framework, same shape as the smoke test: CHECK + main, a section banner
 * on an unbuffered stdout before each block (a sanitizer abort must say where
 * it got to), and a non-zero exit on any failure.
 */

#include "../src/torrent_shim.cpp"   /* ONE translation unit: see above */

#include <cstdio>
#include <string>
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

static std::string last_error() {
    std::vector<char> b(512);
    int n = btx_last_error(b.data(), static_cast<int>(b.size()));
    if (n < 0) {
        b.resize(static_cast<size_t>(-n));
        n = btx_last_error(b.data(), static_cast<int>(b.size()));
    }
    return std::string(b.data(), n > 0 ? static_cast<size_t>(n) : 0);
}

/* One inbound message event, tagged through peerId so the drain order can be
 * read back. Built exactly as Rp1PeerPlugin::on_extended builds one. */
static Rp1Event message_event(int tag, size_t payloadLen) {
    Rp1Event ev;
    ev.type = btx::A_RP1_MESSAGE;
    ev.peerId = tag;
    ev.hasPayload = true;
    ev.payload.assign(payloadLen, 'p');
    return ev;
}

/* Drain everything, returning the peerId tags in drain order. Walks the drain
 * framing ([count:u16] then count x [type:u16][bodyLen:u16][kvrecord]) with the
 * same RecordReader the smoke test and the LCB mirror use. */
static std::vector<int> drain_all(Rp1SessionPlugin &q, int cap, int *calls,
                                  std::vector<std::string> *errs) {
    std::vector<int> tags;
    std::vector<unsigned char> buf(static_cast<size_t>(cap));
    for (;;) {
        btx_clear_error();
        const int n = q.drain(buf.data(), cap);
        if (calls) ++*calls;
        if (errs) errs->push_back(last_error());
        if (n < 0) { CHECK(n >= 0); break; }
        if (n == 0) break;
        btx::RecordReader rr(buf.data(), buf.size());
        const uint16_t count = btx::RecordReader::rd_u16(rr.cursor());
        rr.skip(2);
        /* One CHECK per drain call, not per record: a 65536-event flood would
         * otherwise print a check count nobody can read. */
        bool framed = (count == n);
        for (uint16_t i = 0; i < count && framed; ++i) {
            rr.skip(2);   /* type */
            const uint16_t blen = btx::RecordReader::rd_u16(rr.cursor());
            rr.skip(2);
            const uint8_t *before = rr.cursor();
            std::vector<btx::Field> body;
            framed = rr.read_record(body)
                  && static_cast<size_t>(rr.cursor() - before) == blen;
            int tag = -1;
            for (const btx::Field &f : body)
                if (f.id == btx::F_RP1_PEER) tag = static_cast<int>(f.as_int());
            tags.push_back(tag);
        }
        CHECK(framed);
    }
    return tags;
}

#define SECTION(name) std::printf("-- %s\n", name)

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    /* The constants under test, stated where a reader of the output sees them.
     * The rows below are DERIVED from them, never typed, so a deliberate change
     * to a cap moves the rows with it; a changed POLICY does not. */
    std::printf("kRp1MaxQueueEvents=%zu kRp1MaxQueueBytes=%zu\n",
                kRp1MaxQueueEvents, kRp1MaxQueueBytes);

    /* ------------------------------------------------------------------ 1 */
    SECTION("the event-count cap: tail-drop, oldest kept, one report");
    {
        auto q = std::make_shared<Rp1SessionPlugin>();
        /* Zero-byte messages: the flood the fixed 64-byte slab in cost() exists
         * for. 65536 of them cost 4 MiB, under the byte cap, so it is the COUNT
         * cap that must bind - and it must bind on a payload-free flood, or a
         * peer queues events for free. */
        const size_t emptyCost = message_event(0, 0).cost();
        CHECK(emptyCost >= 64);   /* the slab is charged even with no payload */
        CHECK(kRp1MaxQueueEvents * emptyCost < kRp1MaxQueueBytes);
        for (size_t i = 0; i < kRp1MaxQueueEvents; ++i)
            q->push_event(message_event(static_cast<int>(i), 0));
        CHECK(q->events.size() == kRp1MaxQueueEvents);
        CHECK(q->dropped == 0);
        CHECK(q->queueBytes == kRp1MaxQueueEvents * emptyCost);

        /* One past the cap: shed, counted, and the queue does not move. */
        q->push_event(message_event(999999, 0));
        q->push_event(message_event(999998, 0));
        CHECK(q->events.size() == kRp1MaxQueueEvents);
        CHECK(q->dropped == 2);

        int calls = 0;
        std::vector<std::string> errs;
        std::vector<int> tags = drain_all(*q, 65536, &calls, &errs);
        /* Every queued event came out, in arrival order, and neither shed
         * event did: tail-drop sheds the NEWEST, because a queue this deep
         * means the app is behind and the old events are the ones it is
         * working through. */
        CHECK(tags.size() == kRp1MaxQueueEvents);
        bool inOrder = true;
        for (size_t i = 0; i < tags.size(); ++i)
            if (tags[i] != static_cast<int>(i)) { inOrder = false; break; }
        CHECK(inOrder);
        /* The shed count rides the FIRST drain's last error, once. */
        CHECK(!errs.empty());
        if (!errs.empty()) {
            CHECK(errs[0].compare(0, 22, "rp1: 2 inbound event(s") == 0);
            CHECK(errs[0].find("shed - the queue cap was reached") != std::string::npos);
        }
        bool laterClean = true;
        for (size_t i = 1; i < errs.size(); ++i)
            if (!errs[i].empty()) laterClean = false;
        CHECK(laterClean);
        CHECK(q->dropped == 0);
        CHECK(calls > 1);   /* 64 KiB drains: the flood took several polls */
        /* The accounting released exactly what it charged. */
        CHECK(q->events.empty());
        CHECK(q->queueBytes == 0);

        /* Empty again, so it accepts again: the cap is a bound on DEPTH, not
         * a latch that stays shut once hit. */
        q->push_event(message_event(7, 0));
        CHECK(q->events.size() == 1 && q->dropped == 0);
    }

    /* ------------------------------------------------------------------ 2 */
    SECTION("the byte cap: bounded by cost(), released by the same cost()");
    {
        auto q = std::make_shared<Rp1SessionPlugin>();
        /* The largest message the peer plugin ever surfaces (on_extended drops
         * anything over kRp1MaxPayload). */
        const size_t bigCost = message_event(0, kRp1MaxPayload).cost();
        const size_t fit = kRp1MaxQueueBytes / bigCost;
        CHECK(fit > 0 && fit < kRp1MaxQueueEvents);   /* bytes bind first here */
        for (size_t i = 0; i < fit; ++i)
            q->push_event(message_event(static_cast<int>(i), kRp1MaxPayload));
        CHECK(q->events.size() == fit);
        CHECK(q->queueBytes == fit * bigCost);
        CHECK(q->dropped == 0);
        q->push_event(message_event(-1, kRp1MaxPayload));
        CHECK(q->events.size() == fit);   /* the next one would not fit: shed */
        CHECK(q->dropped == 1);

        /* A SMALL event still fits in the slack a big one could not use: the
         * cap is on bytes, not on "any event after the first refusal". */
        const size_t slack = kRp1MaxQueueBytes - q->queueBytes;
        const size_t smallCost = message_event(0, 0).cost();
        if (slack >= smallCost) {
            q->push_event(message_event(-2, 0));
            CHECK(q->events.size() == fit + 1);
            CHECK(q->dropped == 1);
        }

        /* Drain ONE poll's worth (the kDrainCap the ABI uses): the budget comes
         * back by exactly the cost of what left, so an event of the same size
         * is accepted again. This is the leak the comment in drain() warns of:
         * release by any other measure and the queue looks full while empty. */
        const size_t before = q->queueBytes;
        const size_t depthBefore = q->events.size();
        std::vector<unsigned char> buf(65536);
        btx_clear_error();
        const int n = q->drain(buf.data(), static_cast<int>(buf.size()));
        CHECK(n == 1);   /* one 60000-byte message per 64 KiB poll */
        CHECK(q->events.size() == depthBefore - 1);
        CHECK(q->queueBytes == before - bigCost);
        CHECK(last_error().compare(0, 22, "rp1: 1 inbound event(s") == 0);
        q->push_event(message_event(-3, kRp1MaxPayload));
        CHECK(q->events.size() == depthBefore);
        CHECK(q->dropped == 0);

        /* An event too big for the caller's buffer is reported as -needed and
         * is NOT consumed - neither the event nor its budget goes missing. */
        const size_t bytesBefore = q->queueBytes;
        unsigned char tiny[8];
        const int need = q->drain(tiny, static_cast<int>(sizeof tiny));
        CHECK(need < -static_cast<int>(sizeof tiny));
        CHECK(q->events.size() == depthBefore);
        CHECK(q->queueBytes == bytesBefore);

        /* And a full drain returns the budget to zero. */
        drain_all(*q, 65536, nullptr, nullptr);
        CHECK(q->events.empty());
        CHECK(q->queueBytes == 0);
    }

    /* ------------------------------------------------------------------ 3 */
    SECTION("no shed, no report; every producer goes through the cap");
    {
        auto q = std::make_shared<Rp1SessionPlugin>();
        q->push_event(message_event(1, 10));
        std::vector<unsigned char> buf(65536);
        btx_clear_error();
        CHECK(q->drain(buf.data(), static_cast<int>(buf.size())) == 1);
        CHECK(last_error().empty());   /* nothing shed: the channel is quiet */

        /* drop_peer is the other producer that does not go through
         * push_event (add_peer, the third, needs a live peer_connection_handle
         * and is exercised by rp1_integration_test). A full queue must shed
         * its disconnect event too, rather than grow past the cap. */
        for (size_t i = 0; i < kRp1MaxQueueEvents; ++i)
            q->push_event(message_event(static_cast<int>(i), 0));
        q->drop_peer(4242, "");
        CHECK(q->events.size() == kRp1MaxQueueEvents);
        CHECK(q->dropped == 1);
    }

    std::printf("%d checks, %d failures\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
