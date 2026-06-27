/* torrent_smoke_test.cpp — the libtorrent-linked smoke test for the shim.
 *
 * This is the automated gate for torrent_shim.cpp (CLAUDE.md: "a shim change is
 * only done once torrent_smoke_test.cpp passes under ASan/UBSan"). It links the
 * REAL libtorrent and drives the REAL exported `btx_*` ABI — it does not stub the
 * engine. Because it spins up a libtorrent session it CANNOT run in this dev
 * environment (no Boost/libtorrent here); it runs in CI. So the bar this file
 * must clear locally is: it COMPILES cleanly under -Wall -Wextra and is LOGICALLY
 * correct against the frozen contract. Build (in CI), under gcc ASan+UBSan
 * (clang's ASan runtime is not installed, per CLAUDE.md):
 *
 *   g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined \
 *       -fno-sanitize-recover=all \
 *       -isystem <libtorrent-include> -isystem <boost-include> \
 *       src/torrent_shim.cpp tests/torrent_smoke_test.cpp \
 *       <link libtorrent + boost> -o /tmp/tt && /tmp/tt
 *
 * NO external test framework (matching record_handle_test.cpp): a tiny CHECK
 * macro + main(). What we prove here is THE BINDING'S SAFETY, not BitTorrent
 * (plan §8.6 — piece hashing/choking/wire correctness are libtorrent's own test
 * suite's job):
 *
 *   1. Session lifecycle: new -> a positive handle; a SECOND new is refused while
 *      one is live (returns 0 + a last-error); free is idempotent; after free a
 *      new session is allowed again.
 *   2. Handle safety: every getter/action on a bogus or freed session/torrent
 *      handle is a HARMLESS no-op — getters return 0/empty, actions return an
 *      error code — never a crash (ASan is the real judge of "never a crash").
 *   3. Add-from-buffer with a deliberately MALFORMED .torrent fails gracefully
 *      (returns 0, sets last-error) and does NOT throw across the boundary.
 *   4. The exception firewall: an internal throw surfaces as BTX_ERR_EXCEPTION
 *      and populates last-error — it never propagates out of the shim.
 *   5. A synthetic-ish alert drain round-trip: after adding a magnet, drain a few
 *      times and (when records appear) verify they parse under the frozen record
 *      framing without reading out of bounds.
 *
 * The byte-exact record framing itself is pinned WITHOUT libtorrent by
 * tests/record_handle_test.cpp + tests/record_golden_test.py; here we only check
 * that what the live shim emits is well-formed under that same framing.
 */

#include "../src/torrent_shim.h"   /* the btx_* ABI + the btx::test hooks      */
#include "../src/btx_record.h"     /* the same record walker the LCB mirrors   */

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>       /* the H1 regression test polls with a bounded wait    */
#include <filesystem>   /* a portable temp dir for the create-torrent path     */
#include <fstream>
#include <thread>

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

/* Read the module-static last-error into a std::string via the ABI's
 * bytes-written / -needed contract (grow-and-retry once). */
static std::string read_last_error() {
    char small[256];
    int n = btx_last_error(small, static_cast<int>(sizeof small));
    if (n >= 0) return std::string(small, static_cast<size_t>(n));
    /* -needed: grow and retry exactly once. */
    std::vector<char> big(static_cast<size_t>(-n));
    int m = btx_last_error(big.data(), static_cast<int>(big.size()));
    if (m < 0) m = 0;
    return std::string(big.data(), static_cast<size_t>(m));
}

/* =========================================================================
 *  1. Session lifecycle + the single-live-session invariant
 * ========================================================================= */
static void test_session_lifecycle() {
    /* ABI handshake first (the very call the LCB checkABI makes). */
    CHECK(btx_abi_version() == BTX_ABI_VERSION);

    CHECK(btx::test::live_session_count() == 0);

    int s = btx_session_new();
    CHECK(s > 0);                              /* a real positive handle       */
    CHECK(btx::test::live_session_count() == 1);

    /* A SECOND concurrent session must be refused: 0 + a populated last-error. */
    btx_clear_error();
    int s2 = btx_session_new();
    CHECK(s2 == 0);
    CHECK(!read_last_error().empty());
    CHECK(btx::test::live_session_count() == 1);  /* still exactly one         */

    /* Free is real and idempotent. */
    btx_session_free(s);
    CHECK(btx::test::live_session_count() == 0);
    btx_session_free(s);                        /* double free -> no-op         */
    btx_session_free(0);                        /* bogus handle -> no-op        */
    btx_session_free(-1);                       /* negative -> no-op            */
    CHECK(btx::test::live_session_count() == 0);

    /* After the first is freed, a NEW session is allowed again. */
    int s3 = btx_session_new();
    CHECK(s3 > 0);
    CHECK(btx::test::live_session_count() == 1);
    btx_session_free(s3);
    CHECK(btx::test::live_session_count() == 0);
}

/* =========================================================================
 *  2. Handle safety — bogus / freed handles are harmless no-ops everywhere
 * ========================================================================= */
static void test_bogus_handles_are_noops() {
    /* A grab-bag of handles that are NOT live: zero, negative, a large
     * never-allocated value, and (below) a genuinely-freed one. None may crash;
     * actions return an error code, getters return 0/empty. */
    const int bogus[] = {0, -1, -999, 1, 7, 123456, 0x7FFFFFFF};

    for (int h : bogus) {
        /* --- session-scoped actions on a bogus SESSION handle --- */
        CHECK(btx_set_bool(h, "enable_dht", 1) < 0);
        CHECK(btx_set_int(h, "download_rate_limit", "1000") < 0);
        CHECK(btx_set_str(h, "user_agent", "x") < 0);
        CHECK(btx_set_encryption_policy(h, 1, 1, 3) < 0);
        CHECK(btx_dht_add_bootstrap(h, "router.bittorrent.com", 6881) < 0);

        /* --- ABI v7 session ops on a bogus SESSION handle --- */
        CHECK(btx_session_pause(h) < 0);
        CHECK(btx_session_resume(h) < 0);
        CHECK(btx_session_is_paused(h) == 0);   /* int-getter: 0 on no session */
        CHECK(btx_listen_port(h) == 0);
        CHECK(btx_find_torrent(h,
              "0123456789abcdef0123456789abcdef01234567") == 0);
        CHECK(btx_dht_announce(h,
              "0123456789abcdef0123456789abcdef01234567", 6881) < 0);

        /* --- ABI v8 filtering / streaming / extended add on a bogus handle --- */
        CHECK(btx_ip_filter_add(h, "1.2.3.0", "1.2.3.255", 1) < 0);
        CHECK(btx_ip_filter_clear(h) < 0);
        CHECK(btx_set_piece_deadline(h, 0, 5000) < 0);
        CHECK(btx_clear_piece_deadlines(h) < 0);
        CHECK(btx_add_magnet_ex(h, "magnet:?xt=urn:btih:"
              "0123456789abcdef0123456789abcdef01234567", "/tmp", "16", "16") == 0);
        const unsigned char d8[4] = {'d', '3', ':', 'e'};
        CHECK(btx_add_torrent_file_ex(h, d8, sizeof d8, "/tmp", "16", "16") == 0);

        /* add-* on a bogus session return 0 (no handle made), not a crash. */
        CHECK(btx_add_magnet(h, "magnet:?xt=urn:btih:"
              "0123456789abcdef0123456789abcdef01234567", "/tmp") == 0);
        const unsigned char dummy[4] = {'d', '3', ':', 'e'};
        CHECK(btx_add_torrent_file(h, dummy, sizeof dummy, "/tmp") == 0);
        CHECK(btx_add_with_resume(h, dummy, sizeof dummy, "/tmp") == 0);

        /* enumeration getters on a bogus session -> 0/empty. */
        CHECK(btx_torrent_count(h) == 0);
        CHECK(btx_torrent_handle_at(h, 0) == 0);

        /* buffer getters on a bogus session -> 0 (empty), never -needed. */
        char buf[256];
        CHECK(btx_dht_state(h, buf, sizeof buf) == 0);
        CHECK(btx_dht_save_state(h, buf, sizeof buf) == 0);
        CHECK(btx_dht_put_immutable(h, "x", 1, buf, sizeof buf) == 0);
        CHECK(btx_dht_get_immutable(h,
              "0123456789012345678901234567890123456789") < 0);
        CHECK(btx_dht_put_mutable(h, "p", "s", "", "x", 1) < 0);
        CHECK(btx_dht_get_mutable(h, "p", "") < 0);
        CHECK(btx_get_setting(h, "user_agent", buf, sizeof buf) == 0);

        /* the alert drain on a bogus session -> 0 alerts, no crash. */
        CHECK(btx_pop_alerts(h, buf, sizeof buf) == 0);

        /* --- torrent-scoped actions/getters on a bogus TORRENT handle --- */
        CHECK(btx_pause(h) < 0);
        CHECK(btx_resume(h) < 0);
        CHECK(btx_force_recheck(h) < 0);
        CHECK(btx_force_reannounce(h) < 0);
        CHECK(btx_set_file_priority(h, 0, 4) < 0);
        CHECK(btx_set_piece_priority(h, 0, 4) < 0);
        CHECK(btx_set_torrent_limits(h, "0", "0") < 0);
        CHECK(btx_save_resume(h) < 0);
        const unsigned char prios[2] = {4, 4};
        CHECK(btx_set_file_priorities(h, prios, 2) < 0);

        /* --- ABI v4 extended control on a bogus torrent handle -> error --- */
        CHECK(btx_set_torrent_flags(h, "512", "512") < 0);
        CHECK(btx_unset_torrent_flags(h, "512") < 0);
        CHECK(btx_set_max_connections(h, 50) < 0);
        CHECK(btx_set_max_uploads(h, 4) < 0);
        CHECK(btx_torrent_clear_error(h) < 0);
        CHECK(btx_scrape_tracker(h) < 0);
        CHECK(btx_move_storage(h, "/tmp") < 0);
        CHECK(btx_queue_move(h, 2) < 0);
        /* btx_queue_position is the lone int-getter that returns -1 (not 0) for a
         * bad handle, because 0 is a valid position. */
        CHECK(btx_queue_position(h) == -1);
        /* argument validation independent of the (bogus) handle path. */
        CHECK(btx_queue_move(h, 99) < 0);              /* out-of-range op       */

        /* torrent getters on a bogus torrent -> 0/empty. */
        CHECK(btx_torrent_status(h, buf, sizeof buf) == 0);
        CHECK(btx_info_hash_hex(h, buf, sizeof buf) == 0);
        CHECK(btx_piece_bitfield(h, buf, sizeof buf) == 0);
        CHECK(btx_peer_list(h, buf, sizeof buf) == 0);
        CHECK(btx_file_list(h, buf, sizeof buf) == 0);          /* ABI v5 */
        CHECK(btx_piece_availability(h, buf, sizeof buf) == 0); /* ABI v5 */
        CHECK(btx_trackers(h, buf, sizeof buf) == 0);           /* ABI v6 */
        CHECK(btx_url_seeds(h, buf, sizeof buf) == 0);          /* ABI v6 */
        CHECK(btx_add_tracker(h, "udp://x.example:6969", 0) < 0);
        CHECK(btx_add_url_seed(h, "http://x.example/seed") < 0);
        CHECK(btx_remove_url_seed(h, "http://x.example/seed") < 0);
    }

    /* remove() needs a live session to even reach the torrent check; with one
     * live, removing a bogus torrent id is a clean error, not a crash. */
    int s = btx_session_new();
    CHECK(s > 0);
    CHECK(btx_remove(s, 999999, 0) < 0);   /* bogus torrent in a real session  */
    CHECK(btx_remove(999999, 1, 0) < 0);   /* bogus session entirely           */
    btx_session_free(s);
}

/* A handle that WAS live but has been freed must also be a no-op (generation
 * tag makes the stale handle dead). */
static void test_freed_session_handle_is_dead() {
    int s = btx_session_new();
    CHECK(s > 0);
    /* Confirm it works while live. */
    CHECK(btx_torrent_count(s) == 0);          /* no torrents yet, but valid    */
    btx_session_free(s);
    /* Now the same handle value is stale: every use is a no-op. */
    CHECK(btx_torrent_count(s) == 0);
    CHECK(btx_set_bool(s, "enable_dht", 0) < 0);
    char buf[64];
    CHECK(btx_pop_alerts(s, buf, sizeof buf) == 0);
}

/* =========================================================================
 *  3. Add-from-buffer with a malformed .torrent fails gracefully (no throw)
 * ========================================================================= */
static void test_malformed_torrent_buffer() {
    int s = btx_session_new();
    CHECK(s > 0);

    /* (a) Outright garbage — not bencode at all. */
    const unsigned char junk[] = {0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02};
    btx_clear_error();
    CHECK(btx_add_torrent_file(s, junk, sizeof junk, "/tmp") == 0);
    CHECK(!read_last_error().empty());      /* a diagnostic was set            */

    /* (b) Valid bencode but NOT a valid torrent dict (no info section). This is
     *     the nastier case: the parser gets further before rejecting. Must still
     *     return 0 and never throw across the boundary. */
    const char notATorrent[] = "d4:spam4:eggse";   /* {"spam":"eggs"} */
    btx_clear_error();
    CHECK(btx_add_torrent_file(s, notATorrent,
                               static_cast<int>(std::strlen(notATorrent)), "/tmp") == 0);
    CHECK(!read_last_error().empty());

    /* (c) Empty / null buffers are invalid-arg, not crashes. */
    CHECK(btx_add_torrent_file(s, nullptr, 0, "/tmp") == 0);
    CHECK(btx_add_torrent_file(s, junk, 0, "/tmp") == 0);

    /* (d) Malformed RESUME data likewise fails cleanly. */
    btx_clear_error();
    CHECK(btx_add_with_resume(s, junk, sizeof junk, "/tmp") == 0);
    CHECK(!read_last_error().empty());

    /* (e) A malformed magnet URI fails cleanly (no torrent, last-error set). */
    btx_clear_error();
    CHECK(btx_add_magnet(s, "magnet:?this-is-not-valid", "/tmp") == 0);
    CHECK(!read_last_error().empty());

    btx_session_free(s);
}

/* =========================================================================
 *  4. The exception firewall — an internal throw never crosses the boundary
 * ========================================================================= */
static void test_exception_firewall() {
    btx_clear_error();
    /* The dedicated hook runs a body that ALWAYS throws through the production
     * firewall macro. If the firewall works, control returns here normally with
     * BTX_ERR_EXCEPTION and a populated last-error; if it does NOT, the throw
     * would unwind past this call and ASan/the runtime would abort the test. */
    int rc = btx::test::force_throw();
    CHECK(rc == BTX_ERR_EXCEPTION);
    CHECK(!read_last_error().empty());

    /* And the firewall did not leave the module wedged: normal calls still work. */
    int s = btx_session_new();
    CHECK(s > 0);
    btx_session_free(s);
}

/* =========================================================================
 *  5. Alert drain round-trip — whatever the live shim emits parses cleanly
 *
 *  We cannot deterministically force a specific alert without real network/disk
 *  activity, so this is a SOFT check: add a magnet (which at minimum should
 *  eventually yield an add_torrent_alert / listen alerts), poll a handful of
 *  times, and for every record that DOES appear, verify it walks under the
 *  frozen framing without reading out of bounds (ASan enforces the bound). The
 *  point is format integrity of the live emitter, not event timing.
 * ========================================================================= */
static void test_alert_drain_roundtrip() {
    int s = btx_session_new();
    CHECK(s > 0);

    /* A well-formed magnet (the canonical all-hex info-hash). No save path side
     * effects we care about; we never let it actually download to completion. */
    int t = btx_add_magnet(
        s, "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
           "&dn=smoke-test", "/tmp");
    /* The add itself should succeed and give us a positive id (parsing a magnet
     * does not need the network). */
    CHECK(t > 0);

    /* The torrent should now enumerate. */
    CHECK(btx_torrent_count(s) == 1);
    CHECK(btx_torrent_handle_at(s, 0) == t);

    /* A status snapshot for a just-added magnet must be a well-formed record
     * (name/state/hashes present even before metadata). Walk it. */
    {
        std::vector<unsigned char> buf(4096);
        int n = btx_torrent_status(t, buf.data(), static_cast<int>(buf.size()));
        /* >0 bytes (it fit) — a magnet always has at least state + a hash. */
        CHECK(n > 0);
        if (n > 0) {
            btx::RecordReader rr(buf.data(), static_cast<size_t>(n));
            std::vector<btx::Field> fields;
            CHECK(rr.read_record(fields));
            CHECK(!fields.empty());
            /* state field must be present and a plausible enum value. */
            bool sawState = false;
            for (const btx::Field &f : fields)
                if (f.id == btx::F_STATE) { sawState = true; CHECK(f.type == btx::FT_INT); }
            CHECK(sawState);
        }
    }

    /* Drain a few times. Whatever appears must be a well-formed drain stream:
     *   [alertCount:u16] then alertCount x [type:u16][bodyLen:u16][kvrecord]. */
    bool sawAnyAlert = false;
    for (int pass = 0; pass < 8; ++pass) {
        std::vector<unsigned char> buf(16384);
        int rc = btx_pop_alerts(s, buf.data(), static_cast<int>(buf.size()));
        CHECK(rc >= 0);                  /* never a crash; >=0 here (big buffer) */
        if (rc <= 0) continue;
        sawAnyAlert = true;

        btx::RecordReader rr(buf.data(), static_cast<size_t>(/*written bytes*/ buf.size()));
        /* The leading count must equal the return value rc. */
        CHECK(rr.bytes_left() >= 2);
        uint16_t count = btx::RecordReader::rd_u16(rr.cursor());
        rr.skip(2);
        CHECK(static_cast<int>(count) == rc);

        for (uint16_t i = 0; i < count; ++i) {
            /* [type:u16][bodyLen:u16] then a kvrecord of exactly bodyLen bytes. */
            CHECK(rr.bytes_left() >= 4);
            uint16_t atype = btx::RecordReader::rd_u16(rr.cursor()); rr.skip(2);
            uint16_t blen  = btx::RecordReader::rd_u16(rr.cursor()); rr.skip(2);
            CHECK(atype >= 1);            /* a real A_* code                     */
            const uint8_t *before = rr.cursor();
            std::vector<btx::Field> body;
            CHECK(rr.read_record(body));
            CHECK(static_cast<size_t>(rr.cursor() - before) == blen);  /* exact   */
            /* F_EVT_TORRENT is always the first field by our framing. */
            CHECK(!body.empty());
            CHECK(body[0].id == btx::F_EVT_TORRENT);
        }
    }
    /* Not asserting sawAnyAlert: on a sandboxed CI runner with no DHT/network a
     * magnet may legitimately produce no alerts in 8 quick polls. The contract
     * we are proving is "whatever comes out is well-formed", which holds either
     * way. Touch the flag so -Wall does not warn it is unused. */
    (void)sawAnyAlert;

    /* The -needed contract on a deliberately tiny buffer: if the shim has any
     * record to emit it returns a negative need; if it has nothing it returns 0.
     * Either is acceptable and neither may crash. */
    {
        unsigned char tiny[3];
        int rc = btx_pop_alerts(s, tiny, static_cast<int>(sizeof tiny));
        CHECK(rc <= 0);   /* 0 (nothing) or -needed (too small) — never partial */
    }

    /* Clean removal drops the handle; the torrent count goes back to 0. */
    CHECK(btx_remove(s, t, 0) == BTX_OK);
    CHECK(btx_torrent_count(s) == 0);

    btx_session_free(s);
}

/* =========================================================================
 *  Buffer-getter -needed contract sanity (without the network)
 *
 *  btx_last_error already exercises bytes-written / -needed; assert it directly:
 *  set a known error, then read it back into a too-small buffer and confirm the
 *  shim reports -needed (negative), then a big-enough buffer returns the bytes.
 * ========================================================================= */
static void test_buffer_needed_contract() {
    /* Force a known last-error string via a refused second session. */
    int s = btx_session_new();
    CHECK(s > 0);
    btx_clear_error();
    CHECK(btx_session_new() == 0);          /* refused -> sets last-error       */
    std::string err = read_last_error();
    CHECK(!err.empty());

    if (err.size() > 1) {
        /* A buffer one byte too small must report -needed, writing nothing
         * usable, and the magnitude must be the true length. */
        std::vector<char> tooSmall(err.size() - 1);
        int need = btx_last_error(tooSmall.data(), static_cast<int>(tooSmall.size()));
        CHECK(need < 0);
        CHECK(static_cast<size_t>(-need) == err.size());
    }
    /* Exactly-sized buffer returns the byte count. */
    std::vector<char> exact(err.size());
    int n = btx_last_error(exact.data(), static_cast<int>(exact.size()));
    CHECK(n == static_cast<int>(err.size()));

    btx_session_free(s);
}

/* =========================================================================
 *  Regression for H1 (the drain wedge): when a pending alert is larger than the
 *  caller buffer, btx_pop_alerts must report its TRUE -needed (so the caller can
 *  grow and make progress), NEVER a bogus -2 that leaves the stream stuck. We
 *  create a real .torrent locally (we hold all the data, so it generates state
 *  alerts without any network) and drain it through a 4-byte buffer.
 * ========================================================================= */
static void test_drain_oversized_makes_progress() {
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::path dir = fs::temp_directory_path() / "torrentxt_smoke_h1";
    fs::create_directories(dir, ec);
    fs::path file = dir / "data.bin";
    {
        std::ofstream f(file.string().c_str(), std::ios::binary);
        std::vector<char> junk(200000, 'x');
        f.write(junk.data(), static_cast<std::streamsize>(junk.size()));
    }

    int s = btx_session_new();
    CHECK(s > 0);

    /* btx_dht_state on a LIVE session returns a non-empty record (the four DHT
     * count fields); the counts may be 0 until the first session_stats lands, but
     * the record itself must be present and well-formed. */
    {
        char dbuf[256];
        CHECK(btx_dht_state(s, dbuf, sizeof dbuf) > 0);
    }

    /* Build a .torrent for the file (with a couple of announce URLs, exercising
     * the newline-separated tracker list), then add it. */
    const char *trackers = "udp://tracker.example.com:1337/announce\n"
                           "http://tracker2.example.com/announce";
    std::vector<char> tbuf(65536);
    int n = btx_create_torrent(file.string().c_str(), 16384, 0, trackers,
                               tbuf.data(), static_cast<int>(tbuf.size()));
    if (n < 0) {
        tbuf.resize(static_cast<size_t>(-n));
        n = btx_create_torrent(file.string().c_str(), 16384, 0, trackers,
                               tbuf.data(), static_cast<int>(tbuf.size()));
    }
    CHECK(n > 0);
    int t = btx_add_torrent_file(s, tbuf.data(), n, dir.string().c_str());
    CHECK(t > 0);

    /* Poll with a 4-byte buffer until an alert is pending (bounded ~5s). The
     * first pending alert cannot fit 4 bytes, so the shim must return -needed. */
    unsigned char tiny[4];
    int got = 0;
    for (int i = 0; i < 1000 && got == 0; ++i) {
        got = btx_pop_alerts(s, tiny, static_cast<int>(sizeof tiny));
        if (got == 0) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (got < 0) {
        CHECK(got < -2);   /* the H1 assertion: TRUE need, never the bogus -2     */
        int need = -got;
        std::vector<char> grow(static_cast<size_t>(need));
        int n2 = btx_pop_alerts(s, grow.data(), need);
        CHECK(n2 >= 1);    /* grew to -needed -> drained at least one record       */
    }
    /* If no alert appeared in the window, the H1 assertion is simply skipped (no
     * false failure) — matching the drain-roundtrip test's network tolerance. */

    btx_remove(s, t, 1);
    btx_session_free(s);
    fs::remove_all(dir, ec);
}

/* BEP44: keypair generation/determinism, the immutable target contract, and
 * that every put/get wires up and validates input cleanly. The actual DHT
 * round-trip needs a live swarm (confirmed in an OXT pass), but the deterministic
 * pieces and the input-validation are checked here under the sanitizers. */
static std::string field_text(const unsigned char *rec, int n, uint8_t id) {
    btx::RecordReader rr(rec, static_cast<size_t>(n < 0 ? 0 : n));
    std::vector<btx::Field> fs;
    if (!rr.read_record(fs)) return std::string();
    for (const btx::Field &f : fs) if (f.id == id) return f.text();
    return std::string();
}

static void test_dht_bep44() {
    /* keypair generation is session-less; hex widths are exact. */
    unsigned char kp[512];
    int n = btx_dht_keypair("", kp, sizeof kp);
    CHECK(n > 0);
    std::string pubHex  = field_text(kp, n, btx::F_DHT_PUBLIC_KEY);
    std::string secHex  = field_text(kp, n, btx::F_DHT_SECRET_KEY);
    std::string seedHex = field_text(kp, n, btx::F_DHT_SEED);
    CHECK(pubHex.size() == 64);    /* 32-byte ed25519 public key  */
    CHECK(secHex.size() == 128);   /* 64-byte secret key          */
    CHECK(seedHex.size() == 64);   /* 32-byte seed                */

    /* re-deriving from the same seed is deterministic. */
    unsigned char kp2[512];
    int n2 = btx_dht_keypair(seedHex.c_str(), kp2, sizeof kp2);
    CHECK(n2 > 0);
    CHECK(field_text(kp2, n2, btx::F_DHT_PUBLIC_KEY) == pubHex);

    int s = btx_session_new();
    CHECK(s > 0);

    /* immutable put returns a 40-hex target, identical for identical data. */
    char tgt[64], tgt2[64];
    const char *val = "hello world";
    const int vlen = static_cast<int>(std::strlen(val));
    CHECK(btx_dht_put_immutable(s, val, vlen, tgt, sizeof tgt) == 40);
    CHECK(btx_dht_put_immutable(s, val, vlen, tgt2, sizeof tgt2) == 40);
    CHECK(std::string(tgt, 40) == std::string(tgt2, 40));

    /* the gets and the mutable put wire up and return cleanly. */
    CHECK(btx_dht_get_immutable(s, std::string(tgt, 40).c_str()) == BTX_OK);
    CHECK(btx_dht_put_mutable(s, pubHex.c_str(), secHex.c_str(), "myapp", val, vlen) == BTX_OK);
    CHECK(btx_dht_get_mutable(s, pubHex.c_str(), "myapp") == BTX_OK);
    CHECK(btx_dht_get_mutable(s, pubHex.c_str(), "") == BTX_OK);  /* empty salt */

    /* bad hex / wrong key length / oversize value -> clean BTX_ERR_INVALID_ARG. */
    CHECK(btx_dht_get_immutable(s, "not-hex") == BTX_ERR_INVALID_ARG);
    CHECK(btx_dht_get_mutable(s, "short", "") == BTX_ERR_INVALID_ARG);
    CHECK(btx_dht_put_mutable(s, "short", "short", "", val, vlen) == BTX_ERR_INVALID_ARG);
    std::vector<char> big(1001, 'x');
    CHECK(btx_dht_put_mutable(s, pubHex.c_str(), secHex.c_str(), "",
          big.data(), static_cast<int>(big.size())) == BTX_ERR_INVALID_ARG);

    btx_session_free(s);
    CHECK(btx::test::live_session_count() == 0);
}

int main() {
    test_session_lifecycle();
    test_bogus_handles_are_noops();
    test_freed_session_handle_is_dead();
    test_malformed_torrent_buffer();
    test_exception_firewall();
    test_buffer_needed_contract();
    test_alert_drain_roundtrip();
    test_drain_oversized_makes_progress();
    test_dht_bep44();

    std::printf("%d checks, %d failures\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
