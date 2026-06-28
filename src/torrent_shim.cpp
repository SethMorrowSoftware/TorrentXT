/* torrent_shim.cpp — the flat extern "C" facade over libtorrent-rasterbar 2.0.x.
 *
 * This is the ONE place libtorrent (a throwing C++ library running its own
 * network + disk-I/O threads) meets the OXT/LCB foreign-function boundary. Every
 * design choice here exists to honour the three load-bearing rules (CLAUDE.md):
 *
 *   1. NEVER call an LCB handler from a libtorrent thread. We register no
 *      notify-to-script callback. The ONLY inbound path is btx_pop_alerts, which
 *      the engine's main thread calls on a timer; it drains session::pop_alerts
 *      and returns a self-describing record. No foreign thread ever touches
 *      script, period.
 *
 *   2. THE EXCEPTION FIREWALL. libtorrent throws; an exception that unwinds
 *      across `extern "C"` takes the whole engine down. So EVERY btx_* entry
 *      point wraps its body in try{...}catch(...){...}. The catch records a
 *      module-static last-error string and returns a defined error/0/empty — no
 *      exception ever crosses the boundary. The BTX_GUARD_* macros below make
 *      this uniform so a future handler cannot forget it.
 *
 *   3. PAYLOAD NEVER CROSSES. libtorrent moves gigabytes engine <-> disk on its
 *      own threads. Across the FFI we move ONLY tiny commands and small status /
 *      alert records. If piece data ever ends up in a caller buffer here, that is
 *      a bug — the single-threaded ~16 ms budget makes that path unviable and the
 *      whole architecture exists to avoid it.
 *
 * Handle safety (plan §5): sessions and torrents are addressed by POSITIVE,
 * generation-tagged ints from btx::HandleTable. Every handle is validated before
 * use; a stale / freed / never-created handle is a HARMLESS NO-OP — getters
 * return 0/empty, actions return BTX_ERR_BAD_HANDLE — never a crash, never an
 * alias of a recycled slot. We ALSO check libtorrent's own handle.is_valid()
 * inside the slot, because its torrent_handle is itself a weak reference.
 *
 * Marshalling (plan §4.1/§6): reals cross as double, bools as int 0/1, byte
 * buffers as pointer+len, short strings as NUL-terminated UTF-8. There is NO
 * 64-bit foreign int, so every 64-bit value and every info-hash rides as ASCII
 * text inside the KV record (RecordWriter::field_int/uint/hex). Out buffers use
 * the measure-or-write / -needed convention from btx_record.h: write the record,
 * then return (int)pos() if it fit, or -(int)pos() (i.e. -needed) if it did not.
 *
 * libtorrent + Boost headers are treated as SYSTEM headers (the build passes them
 * with -isystem) so their warnings never pollute our -Wall -Wextra; our own code
 * stays warning-clean.
 */

#include "torrent_shim.h"
#include "btx_record.h"
#include "btx_handle_table.h"

/* ---- libtorrent (system headers; -isystem keeps their warnings out) -------- */
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/alert.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/session_stats.hpp>      /* find_metric_idx + session_stats_alert counters */
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/sha1_hash.hpp>
#include <libtorrent/ip_filter.hpp>           /* set_ip_filter (ABI v8)          */
#include <libtorrent/address.hpp>             /* make_address for IP-filter rules */
#include <libtorrent/download_priority.hpp>
#include <libtorrent/units.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/bitfield.hpp>
#include <libtorrent/session_handle.hpp>      /* save_state_flags_t, session_state() */
#include <libtorrent/session_params.hpp>      /* read/write_session_params_buf (public, exported) */
#include <libtorrent/kademlia/dht_state.hpp>  /* dht::dht_state type for set_dht_state() */
#include <libtorrent/kademlia/ed25519.hpp>    /* ed25519 keypair + signing (BEP44 mutable) */
#include <libtorrent/kademlia/item.hpp>       /* sign_mutable_item (BEP44 mutable) */
#include <libtorrent/kademlia/types.hpp>      /* public_key / secret_key / signature */
#include <libtorrent/entry.hpp>               /* lt::entry for DHT item values */

/* ---- standard library ------------------------------------------------------ */
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

namespace lt = libtorrent;

/* ====================================================================== *
 *  Module-static state
 *
 *  All of this is owned by the (single) main thread that drives the FFI. The
 *  session's OWN background threads live entirely inside lt::session and never
 *  reach back here except via the alert queue we poll. There is no inter-thread
 *  sharing of this state, so no locking is needed: libtorrent's pop_alerts() is
 *  itself thread-safe and is the only synchronisation point that matters.
 * ====================================================================== */
namespace {

/* The last-error string the firewall (and validation failures) write, read back
 * by btx_last_error. Module-static, single-threaded: see the note above. */
std::string g_last_error;

inline void set_error(const std::string &msg) { g_last_error = msg; }
inline void set_error(const char *msg) { g_last_error = msg ? msg : ""; }

/* One alert we have extracted but not yet emitted. We copy EVERYTHING we need
 * out of the live alert* immediately, because the pointers from pop_alerts() are
 * only valid until the NEXT pop_alerts() call. This struct therefore owns its
 * own copies (no dangling references to engine memory) and is what we stash when
 * a record will not fit the caller's buffer — honouring the ShowControl rule
 * that the drain NEVER drops a record. */
struct PendingAlert {
    uint16_t type = 0;                 /* our stable btx::A_* code              */
    int torrentId = 0;                 /* OUR handle id for the alert's torrent */

    /* Optional scalar fields; presence flags keep "absent" distinct from "0". */
    bool hasMessage = false;        std::string message;
    bool hasErrorCode = false;      long long errorCode = 0;
    bool hasErrorMessage = false;   std::string errorMessage;
    bool hasPieceIndex = false;     long long pieceIndex = 0;
    bool hasState = false;          long long state = 0;
    bool hasPrevState = false;      long long prevState = 0;
    bool hasTrackerUrl = false;     std::string trackerUrl;
    bool hasNumPeers = false;       long long numPeers = 0;
    bool hasInfoHashV1 = false;     std::string infoHashV1;
    bool hasInfoHashV2 = false;     std::string infoHashV2;
    bool hasName = false;           std::string name;
    bool hasEndpoint = false;       std::string endpoint;
    bool hasResumeData = false;     std::vector<char> resumeData;
    /* ---- DHT BEP44 item fields (A_DHT_IMMUTABLE_ITEM / MUTABLE_ITEM / PUT) ---- */
    bool hasDhtTarget = false;        std::string dhtTarget;       /* hex */
    bool hasDhtValue = false;         std::vector<char> dhtValue;
    bool hasDhtPublicKey = false;     std::string dhtPublicKey;    /* hex */
    bool hasDhtSignature = false;     std::string dhtSignature;    /* hex */
    bool hasDhtSeq = false;           long long dhtSeq = 0;
    bool hasDhtSalt = false;          std::string dhtSalt;
    bool hasDhtAuthoritative = false; long long dhtAuthoritative = 0;
    bool hasDhtNumSuccess = false;    long long dhtNumSuccess = 0;
};

/* The whole world a session owns. Boxed in a unique_ptr inside the session
 * handle table so it has a stable address and a deterministic destruction order
 * (the proxy must outlive nothing and the session must be torn down explicitly —
 * see btx_session_free). */
struct SessionState {
    /* lt::session is constructed in btx_session_new and lives until
     * btx_session_free aborts it; declared first so it is destroyed last. */
    std::unique_ptr<lt::session> ses;

    /* Our torrent handles. We hand script a small positive int; the real
     * lt::torrent_handle (a weak ref) lives in the slot and we check is_valid()
     * before each use. */
    btx::HandleTable<lt::torrent_handle> torrents;

    /* Reverse map: lt::torrent_handle -> OUR int id, so an inbound alert that
     * carries a torrent_handle can be tagged with the id script knows. Populated
     * on add, erased on remove. lt::torrent_handle is hashable + equality-
     * comparable, so it is a valid unordered_map key. */
    std::unordered_map<lt::torrent_handle, int> idOf;

    /* The "never drop a record" stash: alerts extracted on a previous
     * btx_pop_alerts that did not fit the caller's buffer, to be emitted FIRST
     * next call. FIFO order preserved (we always drain stash before fresh). */
    std::vector<PendingAlert> stash;

    /* DHT health, refreshed from session_stats. btx_pop_alerts fires
     * post_session_stats() each poll; the resulting session_stats_alert arrives
     * on a later drain (captured in extract_alert) and updates these cached
     * counters, which btx_dht_state then reports synchronously — no blocking
     * stats round-trip on the getter. A metric index of -1 means this libtorrent
     * build does not define that counter, so the field stays 0 (graceful). */
    int statsIdxDhtNodes       = -1;
    int statsIdxDhtNodeCache   = -1;
    int statsIdxDhtTorrents    = -1;
    int statsIdxDhtGlobalNodes = -1;
    long long dhtNodes       = 0;
    long long dhtNodeCache   = 0;
    long long dhtTorrents    = 0;
    long long dhtGlobalNodes = 0;
};

/* The two handle tables (plan §5: one for sessions, one for torrents). Sessions
 * are boxed so SessionState has a stable address across table growth. */
btx::HandleTable<std::unique_ptr<SessionState>> g_sessions;

/* We deliberately allow only ONE live session at a time (plan §4.2). This is the
 * handle of the live one, or 0. btx_session_new refuses while non-zero;
 * btx_session_free clears it. */
int g_live_session = 0;

/* ---- handle resolution helpers -------------------------------------------- */

/* The live SessionState for a session handle, or nullptr (a no-op). */
SessionState *session_for(int s) {
    std::unique_ptr<SessionState> *slot = g_sessions.get(s);
    return slot ? slot->get() : nullptr;
}

/* The lt::torrent_handle for (session, torrent) ids, with full validation:
 * the session must be live, the torrent id must name a live slot, AND
 * libtorrent's own weak handle must still be valid. On any miss returns a
 * default-constructed (invalid) handle and sets *ok = false, so callers treat it
 * as a harmless no-op. The session id is needed because torrent ids are scoped
 * to their session's table. */
lt::torrent_handle torrent_for(int s, int t, bool *ok) {
    *ok = false;
    SessionState *st = session_for(s);
    if (!st) return lt::torrent_handle{};
    lt::torrent_handle *h = st->torrents.get(t);
    if (!h || !h->is_valid()) return lt::torrent_handle{};
    *ok = true;
    return *h;
}

/* The control/status entry points take ONLY a torrent id (the ABI does not pass
 * the session to them), so we must find which session owns it. With a single
 * live session this is just "the live session, if the id is valid there". If we
 * ever allow multiple sessions this is the one spot to widen to a scan. */
lt::torrent_handle torrent_only(int t, SessionState **owner, bool *ok) {
    *ok = false;
    if (owner) *owner = nullptr;
    SessionState *st = session_for(g_live_session);
    if (!st) return lt::torrent_handle{};
    lt::torrent_handle *h = st->torrents.get(t);
    if (!h || !h->is_valid()) return lt::torrent_handle{};
    if (owner) *owner = st;
    *ok = true;
    return *h;
}

/* ---- info-hash hex helpers ------------------------------------------------ */

/* lower-case hex of a sha1/sha256 hash via its raw byte span. We deliberately
 * go through btx::to_hex on data()/size() rather than lt::to_hex / lt::aux::
 * to_hex, both to keep the record codec the single hex authority and to dodge an
 * overload-ambiguity between those two libtorrent exports. */
template <typename Hash>
std::string hash_hex(const Hash &h) {
    return btx::to_hex(reinterpret_cast<const uint8_t *>(h.data()),
                       static_cast<size_t>(h.size()));
}

/* An ed25519 seed is 32 bytes; aliased so the bare `std::array<char, 32>` comma
 * never sits at the top level of a BTX_GUARD_* macro body (the preprocessor only
 * protects commas inside parentheses, not angle brackets). */
using ed_seed = std::array<char, 32>;

/* Parse exactly `n` bytes of hex (either case) from `hex` into `out`. Returns
 * false on NULL, wrong length, or a non-hex digit — so a bad key/target/seed
 * from script becomes a clean BTX_ERR_INVALID_ARG, never a crash. */
bool hex_to_buf(const char *hex, char *out, size_t n) {
    if (!hex) return false;
    if (std::strlen(hex) != n * 2) return false;
    auto nyb = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < n; ++i) {
        int hi = nyb(hex[2 * i]), lo = nyb(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<char>((hi << 4) | lo);
    }
    return true;
}

/* The raw bytes of a DHT item value. Our put side always stores a bencoded
 * STRING, so a get of our own item is a string entry we hand back verbatim; a
 * value some other client stored that is NOT a string is bencoded so nothing is
 * silently lost. */
std::vector<char> entry_to_bytes(const lt::entry &e) {
    if (e.type() == lt::entry::string_t) {
        const std::string &s = e.string();
        return std::vector<char>(s.begin(), s.end());
    }
    std::vector<char> buf;
    lt::bencode(std::back_inserter(buf), e);
    return buf;
}

/* ---- settings key type validation ----------------------------------------- */

/* libtorrent's string-keyed settings are partitioned by a type tag in the high
 * bits of the id (string=0x0000, int=0x4000, bool=0x8000 under type_mask). We
 * look a key up by name, then refuse it if its type class does not match the
 * setter the caller used — so btx_set_bool on an int key fails cleanly instead
 * of silently writing the wrong union member. Returns the resolved id, or -1
 * (unknown key) / -2 (wrong type class). */
int resolve_setting(const char *key, int wantBase) {
    if (!key || !*key) return -1;
    int id = lt::setting_by_name(key);
    if (id < 0) return -1;
    if ((id & lt::settings_pack::type_mask) != wantBase) return -2;
    return id;
}

}  // namespace

/* ====================================================================== *
 *  The exception firewall (rule 2)
 *
 *  These macros wrap the WHOLE body of every entry point. A throw of any kind
 *  (lt::system_error, std::bad_alloc, anything) is caught, recorded in the
 *  module-static last-error, and converted to the function's defined failure
 *  value. We provide three flavours so the failure value matches the function
 *  family's convention (action -> error code; buffer-filler -> 0; void). The
 *  uniform macro is why a future handler physically cannot forget the firewall:
 *  it is part of the entry-point shape, not a thing you remember to add.
 *
 *  Implemented as a lambda invoked immediately ([&]{...}()) so an early `return`
 *  inside the body returns from the lambda (and thus the wrapped region),
 *  keeping the bodies readable and the try/catch boilerplate in exactly one
 *  place. The lambda CANNOT let an exception escape: the catch is outside it.
 * ====================================================================== */

/* Action functions: return an int (BTX_OK / BTX_ERR_*). On a throw, return
 * BTX_ERR_EXCEPTION. */
#define BTX_GUARD_ACTION(BODY)                                                  \
    try {                                                                       \
        return [&]() -> int BODY ();                                            \
    } catch (const std::exception &e) {                                         \
        set_error(std::string("libtorrent exception: ") + e.what());            \
        return BTX_ERR_EXCEPTION;                                               \
    } catch (...) {                                                             \
        set_error("unknown native exception crossed the shim");                 \
        return BTX_ERR_EXCEPTION;                                               \
    }

/* Buffer-filling getters: return an int that is bytes-written / -needed / 0. A
 * throw collapses to 0 (a harmless empty result — never a small negative that
 * could be confused with a -needed value, per the btx_abi.h header note). */
#define BTX_GUARD_BUFFER(BODY)                                                  \
    try {                                                                       \
        return [&]() -> int BODY ();                                            \
    } catch (const std::exception &e) {                                         \
        set_error(std::string("libtorrent exception: ") + e.what());            \
        return 0;                                                               \
    } catch (...) {                                                             \
        set_error("unknown native exception crossed the shim");                 \
        return 0;                                                               \
    }

/* Functions returning a plain int that is NOT an error code (e.g. counts,
 * handles). A throw collapses to 0. */
#define BTX_GUARD_INT(BODY)  BTX_GUARD_BUFFER(BODY)

/* void entry points. A throw is swallowed (recorded) so nothing crosses. */
#define BTX_GUARD_VOID(BODY)                                                    \
    try {                                                                       \
        [&]() -> void BODY ();                                                  \
    } catch (const std::exception &e) {                                         \
        set_error(std::string("libtorrent exception: ") + e.what());            \
    } catch (...) {                                                             \
        set_error("unknown native exception crossed the shim");                 \
    }

/* ====================================================================== *
 *  Lifecycle & diagnostics
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_abi_version(void) {
    /* No state, cannot throw — but stay inside the shape for uniformity. */
    BTX_GUARD_INT({ return BTX_ABI_VERSION; });
}

extern "C" BTX_API int BTX_CALL btx_session_new(void) {
    BTX_GUARD_INT({
        /* Single-live-session invariant (plan §4.2). Refuse a second while one
         * lives; the app must btx_session_free the first. Report it, return 0. */
        if (g_live_session != 0 && session_for(g_live_session) != nullptr) {
            set_error("a session is already live; free it before opening another");
            return 0;
        }

        /* Build a settings_pack with sane, download-capable defaults and a broad
         * alert_mask so the drain actually receives the events the LCB layer
         * dispatches. DHT/LSD/UPnP/NAT-PMP on by default (plan §4.2 "DHT/LSD/uTP
         * on"); the btx_set_* family tunes anything else live afterwards. */
        lt::settings_pack sp;

        /* The categories we surface. We OR the bitmasks and store via the int
         * alert_mask key. Anything outside this mask the engine simply will not
         * queue, keeping pop_alerts cheap. The ORed alert_category_t is passed
         * straight to set_int exactly as libtorrent's own tutorial does (it
         * converts to the int the mask key wants) — do NOT reach for a .to_int()
         * spelling that may not exist on the flag type. */
        lt::alert_category_t const mask =
              lt::alert_category::error
            | lt::alert_category::status
            | lt::alert_category::storage
            | lt::alert_category::tracker
            | lt::alert_category::dht
            | lt::alert_category::stats          /* session_stats_alert -> DHT counts */
            | lt::alert_category::performance_warning;
        sp.set_int(lt::settings_pack::alert_mask, mask);

        sp.set_bool(lt::settings_pack::enable_dht, true);
        sp.set_bool(lt::settings_pack::enable_lsd, true);
        sp.set_bool(lt::settings_pack::enable_upnp, true);
        sp.set_bool(lt::settings_pack::enable_natpmp, true);

        /* A polite default UA; callers can override via btx_set_str("user_agent"). */
        sp.set_str(lt::settings_pack::user_agent, "TorrentXT/0.1 libtorrent/2.0");

        /* Construct the session from session_params(settings_pack) (the 2.0 way;
         * the bare settings_pack ctor is deprecated). This spins up the network
         * and disk threads — which is exactly why teardown must be explicit. */
        auto state = std::make_unique<SessionState>();
        state->ses = std::make_unique<lt::session>(lt::session_params(sp));

        /* Resolve the session_stats metric indices once, up front; btx_pop_alerts
         * then keeps the cached DHT counters fresh (see SessionState +
         * btx_dht_state). find_metric_idx returns -1 for a name this libtorrent
         * build does not define, which the capture handles gracefully. */
        state->statsIdxDhtNodes       = lt::find_metric_idx("dht.dht_nodes");
        state->statsIdxDhtNodeCache   = lt::find_metric_idx("dht.dht_node_cache");
        state->statsIdxDhtTorrents    = lt::find_metric_idx("dht.dht_torrents");
        state->statsIdxDhtGlobalNodes = lt::find_metric_idx("dht.dht_global_nodes");

        int h = g_sessions.alloc(std::move(state));
        if (h == 0) {
            set_error("session handle table exhausted");
            return 0;
        }
        g_live_session = h;
        return h;
    });
}

extern "C" BTX_API void BTX_CALL btx_session_free(int s) {
    /* Idempotent: a stale handle, 0, or a second call is a no-op (rule: stale =
     * harmless). The ordered teardown is the documented C++-engine obligation
     * (CLAUDE.md gotcha 2): pause -> request+drain resume data -> abort() ->
     * destroy -> drop the proxy (its dtor joins the background threads). */
    BTX_GUARD_VOID({
        SessionState *st = session_for(s);
        if (!st || !st->ses) {
            /* If the caller is freeing the (already gone) live session id, clear
             * the latch so a fresh session can be created. */
            if (s == g_live_session) g_live_session = 0;
            return;
        }

        lt::session &ses = *st->ses;

        /* 1) Stop accepting/initiating traffic so resume data is consistent. */
        ses.pause();

        /* 2) Ask every torrent for resume data, then drain the resulting alerts
         *    so libtorrent has actually flushed state to its callbacks. We do NOT
         *    persist here — persistence is the app's job via btx_save_resume +
         *    the drain during normal operation; this is a best-effort flush so an
         *    in-flight save is not lost at teardown. We bound the wait by a fixed
         *    number of poll passes to never hang shutdown on a stuck torrent. */
        std::vector<lt::torrent_handle> live;
        for (lt::torrent_handle const &h : ses.get_torrents()) {
            if (h.is_valid()) {
                /* save_resume_data can throw if the handle just went invalid;
                 * swallow per-handle so one bad torrent cannot abort teardown. */
                try {
                    h.save_resume_data(lt::torrent_handle::save_info_dict);
                    live.push_back(h);
                } catch (...) { /* ignore: handle raced to invalid */ }
            }
        }
        /* Drain a bounded number of times to let the save_resume_data_alerts
         * surface; we discard them (best-effort) — the point is to give the
         * engine its moment, not to capture bytes at quit. */
        for (int pass = 0; pass < 50 && !live.empty(); ++pass) {
            std::vector<lt::alert *> alerts;
            ses.pop_alerts(&alerts);
            for (lt::alert *a : alerts) {
                if (lt::alert_cast<lt::save_resume_data_alert>(a) ||
                    lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
                    /* One fewer outstanding save. We do not match handles
                     * precisely; counting down is enough to bound the loop. */
                    if (!live.empty()) live.pop_back();
                }
            }
        }

        /* 3) Abort: returns a session_proxy whose destruction joins the threads.
         *    We must keep it alive until AFTER the session object is destroyed. */
        lt::session_proxy proxy = ses.abort();

        /* 4) Destroy the session object (its dtor would otherwise block; abort()
         *    already detached the work). Resetting the unique_ptr runs ~session. */
        st->ses.reset();

        /* 5) Drop our SessionState (and with it the torrent table + maps), then
         *    clear the latch. The proxy goes out of scope here, joining threads. */
        g_sessions.free(s);
        if (s == g_live_session) g_live_session = 0;
    });
}

extern "C" BTX_API int BTX_CALL btx_last_error(char *out, int cap) {
    /* bytes-written / -needed. Stale-safe (no handle). Empty when no error. */
    BTX_GUARD_BUFFER({
        const size_t need = g_last_error.size();
        if (out && cap > 0 && need <= static_cast<size_t>(cap))
            std::memcpy(out, g_last_error.data(), need);
        if (need > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(need);
        return static_cast<int>(need);
    });
}

extern "C" BTX_API void BTX_CALL btx_clear_error(void) {
    BTX_GUARD_VOID({ g_last_error.clear(); });
}

/* ====================================================================== *
 *  Session settings
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_set_int(int s, const char *key,
                                            const char *decValue) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        int id = resolve_setting(key, lt::settings_pack::int_type_base);
        if (id == -1) { set_error("unknown int setting key"); return BTX_ERR_INVALID_ARG; }
        if (id == -2) { set_error("setting key is not an int"); return BTX_ERR_INVALID_ARG; }
        if (!decValue) { set_error("null value"); return BTX_ERR_INVALID_ARG; }
        /* 64-bit value arrives as decimal ASCII (no 64-bit foreign int, §4.1).
         * libtorrent int settings are 32-bit; strtoll then narrow — clamping is
         * libtorrent's concern, ours is not to throw. */
        long long v = std::strtoll(decValue, nullptr, 10);
        lt::settings_pack sp;
        sp.set_int(id, static_cast<int>(v));
        st->ses->apply_settings(sp);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_bool(int s, const char *key, int value) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        int id = resolve_setting(key, lt::settings_pack::bool_type_base);
        if (id == -1) { set_error("unknown bool setting key"); return BTX_ERR_INVALID_ARG; }
        if (id == -2) { set_error("setting key is not a bool"); return BTX_ERR_INVALID_ARG; }
        lt::settings_pack sp;
        sp.set_bool(id, value != 0);
        st->ses->apply_settings(sp);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_str(int s, const char *key,
                                            const char *value) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        int id = resolve_setting(key, lt::settings_pack::string_type_base);
        if (id == -1) { set_error("unknown string setting key"); return BTX_ERR_INVALID_ARG; }
        if (id == -2) { set_error("setting key is not a string"); return BTX_ERR_INVALID_ARG; }
        lt::settings_pack sp;
        sp.set_str(id, value ? value : "");
        st->ses->apply_settings(sp);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_get_setting(int s, const char *key,
                                                char *out, int cap) {
    /* Read any int/bool/string setting back as text (bytes-written / -needed).
     * Diagnostics only — not on the hot path. Stale/unknown -> 0 (empty). */
    BTX_GUARD_BUFFER({
        SessionState *st = session_for(s);
        if (!st || !st->ses || !key || !*key) return 0;
        int id = lt::setting_by_name(key);
        if (id < 0) { set_error("unknown setting key"); return 0; }

        /* Read the live settings snapshot and render the value as text. */
        lt::settings_pack cur = st->ses->get_settings();
        std::string text;
        switch (id & lt::settings_pack::type_mask) {
            case lt::settings_pack::string_type_base:
                text = cur.get_str(id);
                break;
            case lt::settings_pack::int_type_base: {
                char tmp[24];
                std::snprintf(tmp, sizeof tmp, "%d", cur.get_int(id));
                text = tmp;
                break;
            }
            case lt::settings_pack::bool_type_base:
                text = cur.get_bool(id) ? "1" : "0";
                break;
            default:
                return 0;
        }
        const size_t need = text.size();
        if (out && cap > 0 && need <= static_cast<size_t>(cap))
            std::memcpy(out, text.data(), need);
        if (need > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(need);
        return static_cast<int>(need);
    });
}

extern "C" BTX_API int BTX_CALL btx_set_encryption_policy(int s, int inPolicy,
                                                          int outPolicy,
                                                          int level) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        /* Pass the MSE/PE knobs straight through. The ABI doc fixes the integer
         * meanings (policy 0=forced 1=enabled 2=disabled; level 1=plaintext
         * 2=rc4 3=both) and they match libtorrent's enum values, so we forward
         * them as-is. */
        lt::settings_pack sp;
        sp.set_int(lt::settings_pack::in_enc_policy, inPolicy);
        sp.set_int(lt::settings_pack::out_enc_policy, outPolicy);
        sp.set_int(lt::settings_pack::allowed_enc_level, level);
        st->ses->apply_settings(sp);
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Session operations (ABI v7) — whole-session pause, listen port, look up a
 *  torrent by info-hash, classic (BEP5) DHT peer announce.
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_session_pause(int s) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        st->ses->pause();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_session_resume(int s) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        st->ses->resume();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_session_is_paused(int s) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) return 0;  /* no session -> "not paused" default */
        return st->ses->is_paused() ? 1 : 0;
    });
}

extern "C" BTX_API int BTX_CALL btx_listen_port(int s) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) return 0;  /* 0 == not listening / no session */
        return static_cast<int>(st->ses->listen_port());
    });
}

extern "C" BTX_API int BTX_CALL btx_find_torrent(int s, const char *infoHashHex) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) return 0;
        char buf[20];
        if (!hex_to_buf(infoHashHex, buf, 20)) return 0;  /* not 40 hex -> not found */
        lt::torrent_handle h = st->ses->find_torrent(lt::sha1_hash(buf));
        if (!h.is_valid()) return 0;
        /* map libtorrent's handle back to OUR int id via the reverse map. */
        auto it = st->idOf.find(h);
        return it == st->idOf.end() ? 0 : it->second;
    });
}

extern "C" BTX_API int BTX_CALL btx_dht_announce(int s, const char *infoHashHex,
                                                 int port) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        char buf[20];
        if (!hex_to_buf(infoHashHex, buf, 20)) {
            set_error("info-hash must be 40 hex chars"); return BTX_ERR_INVALID_ARG;
        }
        if (port < 0 || port > 65535) { set_error("bad port"); return BTX_ERR_INVALID_ARG; }
        /* classic BEP5 peer announce (distinct from the BEP44 KV calls): tell the
         * DHT we serve peers for this info-hash on `port` (0 == our listen port). */
        st->ses->dht_announce(lt::sha1_hash(buf), port);
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Filtering & streaming (ABI v8) — IP filter rules and piece deadlines.
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_ip_filter_add(int s, const char *startIp,
                                                  const char *endIp, int block) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        if (!startIp || !endIp) { set_error("null ip range"); return BTX_ERR_INVALID_ARG; }
        lt::error_code ec;
        lt::address first = lt::make_address(startIp, ec);
        if (ec) { set_error("bad start address"); return BTX_ERR_INVALID_ARG; }
        lt::address last = lt::make_address(endIp, ec);
        if (ec) { set_error("bad end address"); return BTX_ERR_INVALID_ARG; }
        if (first.is_v4() != last.is_v4()) {
            set_error("ip range start/end must be the same family");
            return BTX_ERR_INVALID_ARG;
        }
        /* read-modify-write the session filter so rules accumulate. */
        lt::ip_filter f = st->ses->get_ip_filter();
        std::uint32_t flags = block
            ? static_cast<std::uint32_t>(lt::ip_filter::blocked) : 0u;
        f.add_rule(first, last, flags);
        st->ses->set_ip_filter(f);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_ip_filter_clear(int s) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        /* an empty filter allows everything. */
        st->ses->set_ip_filter(lt::ip_filter());
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_piece_deadline(int t, int pieceIndex,
                                                       int deadlineMs) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (pieceIndex < 0) { set_error("negative piece index"); return BTX_ERR_INVALID_ARG; }
        /* deadline is milliseconds from now; libtorrent reorders requests to hit
         * the soonest deadlines first (streaming / seeking). */
        h.set_piece_deadline(lt::piece_index_t{pieceIndex}, deadlineMs);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_clear_piece_deadlines(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        h.clear_piece_deadlines();
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Add / remove torrents
 * ====================================================================== */

namespace {

/* Apply add-time torrent_flags from two decimal strings: set the bits named in
 * `maskDec` to the values in `flagsDec`, leaving everything else at libtorrent's
 * default. Used by the _ex add variants (e.g. add PAUSED, or sequential). A null
 * pair is a no-op (the plain add path). */
void apply_add_flags(lt::add_torrent_params &atp, const char *flagsDec,
                     const char *maskDec) {
    if (!flagsDec || !maskDec) return;
    lt::torrent_flags_t fl{std::strtoull(flagsDec, nullptr, 10)};
    lt::torrent_flags_t mk{std::strtoull(maskDec, nullptr, 10)};
    atp.flags = (atp.flags & ~mk) | (fl & mk);
}

/* Register a freshly-added handle in the torrent table + reverse map and return
 * our int id (0 if the table is full). Centralised so add_magnet / add_file /
 * add_resume all map identically. */
int register_torrent(SessionState *st, const lt::torrent_handle &h) {
    if (!h.is_valid()) { set_error("libtorrent returned an invalid handle"); return 0; }
    int id = st->torrents.alloc(h);
    if (id == 0) { set_error("torrent handle table exhausted"); return 0; }
    st->idOf[h] = id;
    return id;
}

}  // namespace

extern "C" BTX_API int BTX_CALL btx_add_magnet(int s, const char *uri,
                                               const char *savePath) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return 0; }
        if (!uri || !*uri) { set_error("empty magnet URI"); return 0; }

        /* parse_magnet_uri(ec-overload) never throws; it sets ec on a bad URI. */
        lt::error_code ec;
        lt::add_torrent_params atp = lt::parse_magnet_uri(uri, ec);
        if (ec) { set_error("bad magnet URI: " + ec.message()); return 0; }
        if (savePath && *savePath) atp.save_path = savePath;

        /* The SYNCHRONOUS add_torrent(params&&, ec) returns the handle now, so
         * btx_add_magnet can hand script a usable id immediately; metadata for a
         * magnet still arrives later as a metadataReceived alert. */
        lt::torrent_handle h = st->ses->add_torrent(std::move(atp), ec);
        if (ec) { set_error("add_torrent failed: " + ec.message()); return 0; }
        return register_torrent(st, h);
    });
}

extern "C" BTX_API int BTX_CALL btx_add_torrent_file(int s, const void *data,
                                                     int len,
                                                     const char *savePath) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return 0; }
        if (!data || len <= 0) { set_error("empty .torrent buffer"); return 0; }

        /* Parse the .torrent METAINFO from the IN buffer. This is metainfo only;
         * the payload never crosses (rule 3) — only the small bencoded dict that
         * names the files/pieces. The ec-overload never throws on malformed
         * bytes; it reports via ec, which is exactly how a deliberately corrupt
         * .torrent fails gracefully instead of unwinding across the boundary. */
        lt::error_code ec;
        auto ti = std::make_shared<lt::torrent_info>(
            reinterpret_cast<char const *>(data), len, ec);
        if (ec) { set_error("invalid .torrent: " + ec.message()); return 0; }

        lt::add_torrent_params atp;
        atp.ti = ti;
        if (savePath && *savePath) atp.save_path = savePath;

        lt::torrent_handle h = st->ses->add_torrent(std::move(atp), ec);
        if (ec) { set_error("add_torrent failed: " + ec.message()); return 0; }
        return register_torrent(st, h);
    });
}

extern "C" BTX_API int BTX_CALL btx_add_with_resume(int s, const void *resume,
                                                    int len,
                                                    const char *savePath) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return 0; }
        if (!resume || len <= 0) { set_error("empty resume buffer"); return 0; }

        /* read_resume_data reconstitutes a full add_torrent_params (ti or
         * info-hash, save_path, priorities, the partial-piece map...) from bytes
         * we previously got out of a save_resume_data_alert. ec-overload: no
         * throw on garbage, just a set ec. */
        lt::error_code ec;
        lt::add_torrent_params atp = lt::read_resume_data(
            {reinterpret_cast<char const *>(resume), len}, ec);
        if (ec) { set_error("invalid resume data: " + ec.message()); return 0; }

        /* An explicit savePath overrides whatever the resume blob carried (lets
         * the app relocate content between runs). */
        if (savePath && *savePath) atp.save_path = savePath;

        lt::torrent_handle h = st->ses->add_torrent(std::move(atp), ec);
        if (ec) { set_error("add_torrent failed: " + ec.message()); return 0; }
        return register_torrent(st, h);
    });
}

/* Extended add (ABI v8): the plain add path + add-time torrent_flags. */
extern "C" BTX_API int BTX_CALL btx_add_magnet_ex(int s, const char *uri,
                                                  const char *savePath,
                                                  const char *flagsDec,
                                                  const char *maskDec) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return 0; }
        if (!uri || !*uri) { set_error("empty magnet URI"); return 0; }
        lt::error_code ec;
        lt::add_torrent_params atp = lt::parse_magnet_uri(uri, ec);
        if (ec) { set_error("bad magnet URI: " + ec.message()); return 0; }
        if (savePath && *savePath) atp.save_path = savePath;
        apply_add_flags(atp, flagsDec, maskDec);
        lt::torrent_handle h = st->ses->add_torrent(std::move(atp), ec);
        if (ec) { set_error("add_torrent failed: " + ec.message()); return 0; }
        return register_torrent(st, h);
    });
}

extern "C" BTX_API int BTX_CALL btx_add_torrent_file_ex(int s, const void *data,
                                                        int len,
                                                        const char *savePath,
                                                        const char *flagsDec,
                                                        const char *maskDec) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return 0; }
        if (!data || len <= 0) { set_error("empty .torrent buffer"); return 0; }
        lt::error_code ec;
        auto ti = std::make_shared<lt::torrent_info>(
            reinterpret_cast<char const *>(data), len, ec);
        if (ec) { set_error("invalid .torrent: " + ec.message()); return 0; }
        lt::add_torrent_params atp;
        atp.ti = ti;
        if (savePath && *savePath) atp.save_path = savePath;
        apply_add_flags(atp, flagsDec, maskDec);
        lt::torrent_handle h = st->ses->add_torrent(std::move(atp), ec);
        if (ec) { set_error("add_torrent failed: " + ec.message()); return 0; }
        return register_torrent(st, h);
    });
}

extern "C" BTX_API int BTX_CALL btx_remove(int s, int t, int deleteFiles) {
    BTX_GUARD_ACTION({
        bool ok = false;
        lt::torrent_handle h = torrent_for(s, t, &ok);
        if (!ok) { set_error("bad session/torrent handle"); return BTX_ERR_BAD_HANDLE; }
        SessionState *st = session_for(s);

        /* Erase our reverse-map entry BEFORE removal: a torrent_removed_alert may
         * arrive later and we want our drop to be deterministic regardless. */
        st->idOf.erase(h);
        st->torrents.free(t);

        st->ses->remove_torrent(
            h, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Control
 *
 *  Each takes only a torrent id; we resolve it through the live session. A
 *  stale/invalid id is BTX_ERR_BAD_HANDLE (a no-op), never a crash.
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_pause(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        h.pause();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_resume(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        h.resume();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_force_recheck(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        h.force_recheck();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_force_reannounce(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        h.force_reannounce();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_file_priority(int t, int fileIndex,
                                                      int priority) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (fileIndex < 0) { set_error("negative file index"); return BTX_ERR_INVALID_ARG; }
        /* priority 0..7 (download_priority_t). We forward as-is; libtorrent
         * clamps. The strong typedefs wrap our ints. */
        h.file_priority(lt::file_index_t{fileIndex},
                        lt::download_priority_t{static_cast<uint8_t>(priority)});
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_file_priorities(int t, const void *prios,
                                                        int count) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (!prios || count < 0) { set_error("bad priority buffer"); return BTX_ERR_INVALID_ARG; }
        /* One priority byte per file, in file order. Build the vector libtorrent
         * wants and set them all at once (cheaper than N round-trips inside the
         * engine). The bytes are tiny control data, not payload. */
        const uint8_t *p = static_cast<const uint8_t *>(prios);
        std::vector<lt::download_priority_t> v;
        v.reserve(static_cast<size_t>(count));
        for (int i = 0; i < count; ++i)
            v.push_back(lt::download_priority_t{p[i]});
        h.prioritize_files(v);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_piece_priority(int t, int pieceIndex,
                                                       int priority) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (pieceIndex < 0) { set_error("negative piece index"); return BTX_ERR_INVALID_ARG; }
        h.piece_priority(lt::piece_index_t{pieceIndex},
                         lt::download_priority_t{static_cast<uint8_t>(priority)});
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_torrent_limits(int t, const char *downDec,
                                                       const char *upDec) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        /* Per-torrent caps in bytes/sec as decimal strings ("0" == unlimited).
         * Decimal because there is no 64-bit foreign int, though these are 32-bit
         * in libtorrent — strtol and narrow. A null string leaves that cap. */
        if (downDec)
            h.set_download_limit(static_cast<int>(std::strtol(downDec, nullptr, 10)));
        if (upDec)
            h.set_upload_limit(static_cast<int>(std::strtol(upDec, nullptr, 10)));
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Control — extended (ABI v4): flags, connection/upload caps, error clear,
 *  scrape, storage move, download-queue positioning. More of libtorrent's
 *  torrent_handle surface, all fire-and-forget; scrape/move results ride the
 *  already-wired A_SCRAPE_REPLY / A_STORAGE_MOVED alerts.
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_set_torrent_flags(int t, const char *flagsDec,
                                                      const char *maskDec) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (!flagsDec || !maskDec) { set_error("null flags"); return BTX_ERR_INVALID_ARG; }
        /* torrent_flags_t is a 64-bit bitfield; it crosses as a decimal string.
         * set_flags(flags, mask) writes only the masked bits. */
        std::uint64_t flags = std::strtoull(flagsDec, nullptr, 10);
        std::uint64_t mask  = std::strtoull(maskDec, nullptr, 10);
        h.set_flags(lt::torrent_flags_t{flags}, lt::torrent_flags_t{mask});
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_unset_torrent_flags(int t, const char *flagsDec) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (!flagsDec) { set_error("null flags"); return BTX_ERR_INVALID_ARG; }
        std::uint64_t flags = std::strtoull(flagsDec, nullptr, 10);
        h.unset_flags(lt::torrent_flags_t{flags});
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_max_connections(int t, int maxConns) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        /* libtorrent wants >= 2 (or -1 == unlimited); forward as-is, it clamps. */
        h.set_max_connections(maxConns);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_set_max_uploads(int t, int maxUploads) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        h.set_max_uploads(maxUploads);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_torrent_clear_error(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        h.clear_error();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_scrape_tracker(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        /* default idx -1 == scrape every tracker in the list; -> A_SCRAPE_REPLY. */
        h.scrape_tracker();
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_move_storage(int t, const char *savePath) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (!savePath || !*savePath) { set_error("empty save path"); return BTX_ERR_INVALID_ARG; }
        /* Async; result -> A_STORAGE_MOVED (or A_FILE_ERROR). Bytes move
         * engine-side between the old and new directory, never through script. */
        h.move_storage(std::string(savePath));
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_queue_position(int t) {
    BTX_GUARD_INT({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        /* Not a buffer getter: -1 (libtorrent's own "not queued" sentinel) also
         * stands in for an invalid handle, since 0 is a real queue position. */
        if (!ok) return -1;
        return static_cast<int>(h.queue_position());
    });
}

extern "C" BTX_API int BTX_CALL btx_queue_move(int t, int op) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        switch (op) {
            case 0: h.queue_position_up();     break;
            case 1: h.queue_position_down();   break;
            case 2: h.queue_position_top();    break;
            case 3: h.queue_position_bottom(); break;
            default: set_error("queue op must be 0..3"); return BTX_ERR_INVALID_ARG;
        }
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Status — one KV-record snapshot per call (perf §8: never one call per field)
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_torrent_status(int t, void *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        /* Stale/invalid handle -> 0 (an empty record), never a crash. */
        if (!ok) return 0;

        /* ONE status() call; everything below reads from this snapshot so we make
         * a single engine round-trip per poll. */
        lt::torrent_status ts = h.status();

        btx::RecordWriter w(out, cap);
        btx::KVRecord r(w);

        r.put_str(btx::F_NAME, ts.name);
        r.put_int(btx::F_STATE, static_cast<long long>(ts.state));
        r.put_real(btx::F_PROGRESS, static_cast<double>(ts.progress));
        r.put_int(btx::F_DOWNLOAD_RATE, ts.download_payload_rate);
        r.put_int(btx::F_UPLOAD_RATE, ts.upload_payload_rate);
        r.put_int(btx::F_TOTAL_DONE, static_cast<long long>(ts.total_done));
        r.put_int(btx::F_TOTAL_WANTED, static_cast<long long>(ts.total_wanted));
        r.put_int(btx::F_NUM_PEERS, ts.num_peers);
        r.put_int(btx::F_NUM_SEEDS, ts.num_seeds);
        r.put_str(btx::F_SAVE_PATH, ts.save_path);

        /* info-hashes ride as hex ASCII (no binary hash field crosses). Emit
         * whichever the torrent has; a magnet pre-metadata still has v1/v2. */
        lt::info_hash_t ih = ts.info_hashes;
        if (ih.has_v1()) r.put_hex(btx::F_INFO_HASH_V1, hash_hex(ih.v1));
        if (ih.has_v2()) r.put_hex(btx::F_INFO_HASH_V2, hash_hex(ih.v2));

        r.put_int(btx::F_ALL_TIME_DOWNLOAD, static_cast<long long>(ts.all_time_download));
        r.put_int(btx::F_ALL_TIME_UPLOAD, static_cast<long long>(ts.all_time_upload));
        r.put_int(btx::F_NUM_COMPLETE, ts.num_complete);
        r.put_int(btx::F_NUM_INCOMPLETE, ts.num_incomplete);

        /* Boolean state flags as 0/1 ints (no bool field type on the wire). Use
         * libtorrent's AUTHORITATIVE is_finished/is_seeding, NOT the state enum:
         * a selective-download torrent that has all WANTED data is is_finished
         * while state may still read downloading, and the two disagree during
         * transitions. */
        r.put_bool(btx::F_IS_FINISHED, ts.is_finished);
        r.put_bool(btx::F_IS_SEEDING, ts.is_seeding);
        r.put_bool(btx::F_IS_PAUSED,
                   (ts.flags & lt::torrent_flags::paused) != lt::torrent_flags_t{});

        /* Error text ("" if none). errc is an error_code; .message() is the
         * human string, empty when there is no error. */
        r.put_str(btx::F_ERROR, ts.errc ? ts.errc.message() : std::string());

        /* ETA in seconds: only meaningful while downloading at a positive rate;
         * -1 means "unknown" (the LCB layer renders that as a dash). */
        long long remaining =
            static_cast<long long>(ts.total_wanted - ts.total_done);
        long long eta = (ts.download_payload_rate > 0 && remaining > 0)
                            ? remaining / ts.download_payload_rate
                            : -1;
        r.put_int(btx::F_ETA, eta);

        r.put_int(btx::F_ADDED_TIME, static_cast<long long>(ts.added_time));
        r.put_int(btx::F_COMPLETED_TIME, static_cast<long long>(ts.completed_time));
        r.put_int(btx::F_NUM_CONNECTIONS, ts.num_connections);
        /* Low bits of the torrent_flags bitfield as an int, for any flag the LCB
         * layer wants to surface beyond the booleans above. */
        r.put_int(btx::F_FLAGS,
                  static_cast<long long>(static_cast<std::uint64_t>(ts.flags)));

        /* total size / piece geometry come from the metainfo, which is null for
         * a magnet until metadata arrives — guard the deref. */
        if (auto tf = h.torrent_file()) {
            r.put_int(btx::F_NUM_PIECES, tf->num_pieces());
            r.put_int(btx::F_PIECE_LENGTH, tf->piece_length());
            r.put_int(btx::F_TOTAL_SIZE, static_cast<long long>(tf->total_size()));
        }

        r.finish();

        /* measure-or-write contract: pos() is the exact byte need. If it
         * overflowed, the buffer holds nothing usable -> return -need so the
         * caller grows and retries; else return bytes written. */
        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

extern "C" BTX_API int BTX_CALL btx_torrent_count(int s) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st) return 0;
        return static_cast<int>(st->torrents.live_count());
    });
}

extern "C" BTX_API int BTX_CALL btx_torrent_handle_at(int s, int index) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || index < 0) return 0;
        /* collect_live yields our int ids in slot order; index into that. The
         * enumeration is for a settings/overview pass, not the hot path, so the
         * transient vector is fine. */
        std::vector<int> live;
        st->torrents.collect_live(live);
        if (static_cast<size_t>(index) >= live.size()) return 0;
        return live[static_cast<size_t>(index)];
    });
}

extern "C" BTX_API int BTX_CALL btx_info_hash_hex(int t, char *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) return 0;  /* stale -> empty */
        lt::info_hash_t ih = h.info_hashes();
        /* Prefer v1; fall back to v2 (the ABI says "v1 (or, absent v1, v2)"). */
        std::string hex;
        if (ih.has_v1()) hex = hash_hex(ih.v1);
        else if (ih.has_v2()) hex = hash_hex(ih.v2);
        const size_t need = hex.size();
        if (out && cap > 0 && need <= static_cast<size_t>(cap))
            std::memcpy(out, hex.data(), need);
        if (need > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(need);
        return static_cast<int>(need);
    });
}

extern "C" BTX_API int BTX_CALL btx_piece_bitfield(int t, void *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) return 0;  /* stale -> empty */

        /* The have-bitfield is a read-only VIEW (one bit per piece) for a piece
         * grid — NOT payload. We pull it from a status() restricted to the
         * pieces field so we do not compute the rest. It may be empty when the
         * torrent is neither downloading nor seeding (or has no metadata yet), in
         * which case we legitimately write 0 bytes. */
        lt::torrent_status ts = h.status(lt::torrent_handle::query_pieces);
        const lt::typed_bitfield<lt::piece_index_t> &bf = ts.pieces;

        const int numPieces = bf.size();
        if (numPieces <= 0) return 0;

        /* Pack MSB-first within each byte (bit 0 of byte 0 == piece 0), matching
         * the ABI's "1 bit per piece, MSB-first within each byte". */
        const size_t nbytes = (static_cast<size_t>(numPieces) + 7u) / 8u;
        uint8_t *dst = static_cast<uint8_t *>(out);
        const bool fits = (dst != nullptr) &&
                          (cap > 0) &&
                          (nbytes <= static_cast<size_t>(cap));
        if (fits) {
            std::memset(dst, 0, nbytes);
            for (int i = 0; i < numPieces; ++i) {
                if (bf.get_bit(lt::piece_index_t{i})) {
                    dst[i >> 3] |= static_cast<uint8_t>(0x80u >> (i & 7));
                }
            }
        }
        if (nbytes > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(nbytes);
        return static_cast<int>(nbytes);
    });
}

extern "C" BTX_API int BTX_CALL btx_peer_list(int t, void *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) return 0;  /* stale -> empty */

        std::vector<lt::peer_info> peers;
        h.get_peer_info(peers);

        /* peer list := [peerCount:u16] then peerCount x [bodyLen:u16][kvrecord]
         * (btx_record.h header). Mirror the alert-drain framing so the LCB walker
         * uses the same byte arithmetic. Backpatch the count at the end so a
         * partial (overflowing) buffer still reports the true need via pos(). */
        btx::RecordWriter w(out, cap);
        const size_t countAt = w.pos();
        w.put_u16(0);  /* peerCount placeholder */
        uint16_t emitted = 0;

        for (const lt::peer_info &pi : peers) {
            const size_t bodyAt = w.pos();
            w.put_u16(0);  /* bodyLen placeholder */
            const size_t bodyStart = w.pos();
            {
                btx::KVRecord r(w);
                /* "ip:port" built directly from the asio endpoint to avoid the
                 * print_endpoint / aux namespace ambiguity. address().to_string()
                 * handles both v4 and v6. The no-argument to_string() is the form
                 * that is stable across Boost versions (the error_code overload was
                 * dropped in newer Boost.Asio); a throw on a degenerate address is
                 * caught by the surrounding firewall. */
                std::string ep = pi.ip.address().to_string();
                ep += ':';
                ep += std::to_string(pi.ip.port());
                r.put_str(btx::F_PEER_ENDPOINT, ep);
                r.put_str(btx::F_PEER_CLIENT, pi.client);
                r.put_int(btx::F_PEER_DOWN_RATE, pi.down_speed);
                r.put_int(btx::F_PEER_UP_RATE, pi.up_speed);
                r.put_real(btx::F_PEER_PROGRESS, static_cast<double>(pi.progress));
                /* peer flags are a strong-typedef bitfield; render the raw bits
                 * as an int via the underlying value. */
                r.put_int(btx::F_PEER_FLAGS,
                          static_cast<long long>(static_cast<std::uint32_t>(pi.flags)));
                r.finish();
            }
            w.patch_u16(bodyAt, static_cast<uint16_t>(w.pos() - bodyStart));
            ++emitted;
        }
        w.patch_u16(countAt, emitted);

        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

/* ====================================================================== *
 *  Inspection — file table & piece availability (ABI v5)
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_file_list(int t, void *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) return 0;  /* stale -> empty */

        /* The file table lives in the metainfo, which is null for a magnet until
         * metadata arrives — that is a legitimately EMPTY list (count 0), not an
         * error. file list := [fileCount:u16] then fileCount x [bodyLen:u16]
         * [kvrecord], mirroring the peer-list framing so the LCB walker reuses
         * the same byte arithmetic. */
        std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();

        btx::RecordWriter w(out, cap);
        const size_t countAt = w.pos();
        w.put_u16(0);  /* fileCount placeholder */
        uint16_t emitted = 0;

        if (ti) {
            const lt::file_storage &fs = ti->files();
            const int n = fs.num_files();
            /* per-file downloaded bytes + priorities in two bulk calls (cheaper
             * than N round-trips); tiny control data, never payload. */
            std::vector<std::int64_t> prog;
            h.file_progress(prog);
            std::vector<lt::download_priority_t> prio = h.get_file_priorities();
            for (int i = 0; i < n; ++i) {
                lt::file_index_t fi{i};
                const size_t bodyAt = w.pos();
                w.put_u16(0);  /* bodyLen placeholder */
                const size_t bodyStart = w.pos();
                {
                    btx::KVRecord r(w);
                    r.put_str(btx::F_FILE_PATH, fs.file_path(fi));
                    r.put_int(btx::F_FILE_SIZE,
                              static_cast<long long>(fs.file_size(fi)));
                    r.put_int(btx::F_FILE_PROGRESS,
                              static_cast<size_t>(i) < prog.size()
                                  ? static_cast<long long>(prog[static_cast<size_t>(i)])
                                  : 0);
                    r.put_int(btx::F_FILE_PRIORITY,
                              static_cast<size_t>(i) < prio.size()
                                  ? static_cast<long long>(static_cast<std::uint8_t>(
                                        prio[static_cast<size_t>(i)]))
                                  : 0);
                    r.finish();
                }
                w.patch_u16(bodyAt, static_cast<uint16_t>(w.pos() - bodyStart));
                ++emitted;
            }
        }
        w.patch_u16(countAt, emitted);

        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

extern "C" BTX_API int BTX_CALL btx_piece_availability(int t, void *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) return 0;  /* stale -> empty */

        /* One int per piece (peers advertising it); we hand back one byte each,
         * clamped to 255 — a read-only availability VIEW, not payload. Empty when
         * the torrent has no metadata / no peers yet (legitimately 0 bytes). */
        std::vector<int> avail;
        h.piece_availability(avail);
        const size_t nbytes = avail.size();
        if (nbytes == 0) return 0;

        uint8_t *dst = static_cast<uint8_t *>(out);
        const bool fits = (dst != nullptr) && (cap > 0) &&
                          (nbytes <= static_cast<size_t>(cap));
        if (fits) {
            for (size_t i = 0; i < nbytes; ++i) {
                int a = avail[i];
                dst[i] = static_cast<uint8_t>(a < 0 ? 0 : (a > 255 ? 255 : a));
            }
        }
        if (nbytes > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(nbytes);
        return static_cast<int>(nbytes);
    });
}

/* ====================================================================== *
 *  Trackers & web seeds (ABI v6) — inspect and edit the announce list and
 *  the HTTP/URL seed list. Listers mirror the peer-list framing; editors are
 *  fire-and-forget. (The downloaded data still rides engine ⇄ disk.)
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_trackers(int t, void *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) return 0;  /* stale -> empty */

        std::vector<lt::announce_entry> trs = h.trackers();
        btx::RecordWriter w(out, cap);
        const size_t countAt = w.pos();
        w.put_u16(0);  /* trackerCount placeholder */
        uint16_t emitted = 0;
        for (const lt::announce_entry &ae : trs) {
            const size_t bodyAt = w.pos();
            w.put_u16(0);  /* bodyLen placeholder */
            const size_t bodyStart = w.pos();
            {
                btx::KVRecord r(w);
                r.put_str(btx::F_TRACKER_URL, ae.url);
                r.put_int(btx::F_TRACKER_TIER, static_cast<long long>(ae.tier));
                r.put_bool(btx::F_TRACKER_VERIFIED, ae.verified);
                r.put_int(btx::F_TRACKER_SOURCE, static_cast<long long>(ae.source));
                r.finish();
            }
            w.patch_u16(bodyAt, static_cast<uint16_t>(w.pos() - bodyStart));
            ++emitted;
        }
        w.patch_u16(countAt, emitted);
        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

extern "C" BTX_API int BTX_CALL btx_add_tracker(int t, const char *url, int tier) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (!url || !*url) { set_error("empty tracker url"); return BTX_ERR_INVALID_ARG; }
        lt::announce_entry ae;
        ae.url = url;
        if (tier < 0) tier = 0;
        if (tier > 255) tier = 255;
        ae.tier = static_cast<std::uint8_t>(tier);
        /* libtorrent ignores a duplicate URL already in the list. */
        h.add_tracker(ae);
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_add_url_seed(int t, const char *url) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (!url || !*url) { set_error("empty url seed"); return BTX_ERR_INVALID_ARG; }
        h.add_url_seed(std::string(url));
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_remove_url_seed(int t, const char *url) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        if (!url || !*url) { set_error("empty url seed"); return BTX_ERR_INVALID_ARG; }
        h.remove_url_seed(std::string(url));
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_url_seeds(int t, void *out, int cap) {
    BTX_GUARD_BUFFER({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) return 0;  /* stale -> empty */

        std::set<std::string> seeds = h.url_seeds();
        /* one single-field KV record per seed, in the peer-list framing so the
         * LCB walker reuses the same counted-loop parse. */
        btx::RecordWriter w(out, cap);
        const size_t countAt = w.pos();
        w.put_u16(0);  /* seedCount placeholder */
        uint16_t emitted = 0;
        for (const std::string &u : seeds) {
            const size_t bodyAt = w.pos();
            w.put_u16(0);  /* bodyLen placeholder */
            const size_t bodyStart = w.pos();
            {
                btx::KVRecord r(w);
                r.put_str(btx::F_URL_SEED, u);
                r.finish();
            }
            w.patch_u16(bodyAt, static_cast<uint16_t>(w.pos() - bodyStart));
            ++emitted;
        }
        w.patch_u16(countAt, emitted);
        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

/* ====================================================================== *
 *  The alert drain (the event firehose) — one FFI round-trip per poll (§3)
 * ====================================================================== */

namespace {

/* Extract everything we need from ONE live alert into a PendingAlert (owning
 * copies), mapping its libtorrent type to our stable A_* code and its
 * torrent_handle (if any) to our int id. Returns false for an alert we do not
 * surface (the caller skips it). MUST copy eagerly: the alert* dies at the next
 * pop_alerts. */
bool extract_alert(SessionState *st, lt::alert *a, PendingAlert &out) {
    /* Map the alert's torrent_handle (if it derives from torrent_alert) to our
     * id via the reverse map. 0 when unknown (e.g. session-level alerts, or a
     * removed torrent we already erased). */
    auto idForHandle = [&](const lt::torrent_handle &h) -> int {
        if (!h.is_valid()) return 0;
        auto it = st->idOf.find(h);
        return it == st->idOf.end() ? 0 : it->second;
    };

    /* alert_cast<T> returns the exact type or nullptr, so this is a clean
     * dispatch with no RTTI surprises. We handle each surfaced type, copy its
     * scalars, and set out.type to our code. Order: most specific first does not
     * matter since alert_cast is exact. */

    /* session_stats_alert is our own post_session_stats() response (see
     * btx_pop_alerts): capture the DHT counters into the session cache and do
     * NOT surface it as a user event. */
    if (auto *p = lt::alert_cast<lt::session_stats_alert>(a)) {
        auto c = p->counters();
        auto grab = [&](int idx, long long &dst) {
            if (idx >= 0 && idx < static_cast<int>(c.size()))
                dst = static_cast<long long>(c[idx]);
        };
        grab(st->statsIdxDhtNodes,       st->dhtNodes);
        grab(st->statsIdxDhtNodeCache,   st->dhtNodeCache);
        grab(st->statsIdxDhtTorrents,    st->dhtTorrents);
        grab(st->statsIdxDhtGlobalNodes, st->dhtGlobalNodes);
        return false;
    }

    if (auto *p = lt::alert_cast<lt::add_torrent_alert>(a)) {
        out.type = btx::A_TORRENT_ADDED;
        out.torrentId = idForHandle(p->handle);
        out.hasMessage = true; out.message = p->message();
        if (p->error) { out.hasErrorCode = true; out.errorCode = p->error.value();
                        out.hasErrorMessage = true; out.errorMessage = p->error.message(); }
        else if (auto ti = p->handle.torrent_file()) {
            /* A .torrent or resume add already has metadata -> surface the name
             * immediately (a magnet has none yet; it fills in on metadata). */
            out.hasName = true; out.name = ti->name();
        }
        return true;
    }
    if (auto *p = lt::alert_cast<lt::metadata_received_alert>(a)) {
        out.type = btx::A_METADATA_RECEIVED;
        out.torrentId = idForHandle(p->handle);
        out.hasMessage = true; out.message = p->message();
        /* Metadata just arrived: the torrent_info — and thus the real name — is
         * now available, so a magnet add can stop showing "(pending)". */
        if (auto ti = p->handle.torrent_file()) {
            out.hasName = true; out.name = ti->name();
        }
        return true;
    }
    if (auto *p = lt::alert_cast<lt::piece_finished_alert>(a)) {
        out.type = btx::A_PIECE_FINISHED;
        out.torrentId = idForHandle(p->handle);
        out.hasPieceIndex = true;
        out.pieceIndex = static_cast<long long>(static_cast<int>(p->piece_index));
        return true;
    }
    if (auto *p = lt::alert_cast<lt::torrent_finished_alert>(a)) {
        out.type = btx::A_TORRENT_FINISHED;
        out.torrentId = idForHandle(p->handle);
        return true;
    }
    if (auto *p = lt::alert_cast<lt::torrent_error_alert>(a)) {
        out.type = btx::A_TORRENT_ERROR;
        out.torrentId = idForHandle(p->handle);
        out.hasErrorCode = true; out.errorCode = p->error.value();
        out.hasErrorMessage = true; out.errorMessage = p->error.message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::state_changed_alert>(a)) {
        out.type = btx::A_STATE_CHANGED;
        out.torrentId = idForHandle(p->handle);
        out.hasState = true; out.state = static_cast<long long>(p->state);
        out.hasPrevState = true; out.prevState = static_cast<long long>(p->prev_state);
        return true;
    }
    if (auto *p = lt::alert_cast<lt::tracker_reply_alert>(a)) {
        out.type = btx::A_TRACKER_REPLY;
        out.torrentId = idForHandle(p->handle);
        out.hasNumPeers = true; out.numPeers = p->num_peers;
        /* tracker_alert exposes the tracker URL; copy it for the event. */
        out.hasTrackerUrl = true; out.trackerUrl = p->tracker_url();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::tracker_error_alert>(a)) {
        out.type = btx::A_TRACKER_ERROR;
        out.torrentId = idForHandle(p->handle);
        out.hasErrorCode = true; out.errorCode = p->error.value();
        out.hasErrorMessage = true; out.errorMessage = p->error.message();
        out.hasTrackerUrl = true; out.trackerUrl = p->tracker_url();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::save_resume_data_alert>(a)) {
        out.torrentId = idForHandle(p->handle);
        /* The bytes the app persists. write_resume_data_buf takes the alert's
         * params by const-ref; move the result into our owning vector (the alert
         * dies at the next pop). */
        std::vector<char> buf = lt::write_resume_data_buf(p->params);
        /* The event record carries the blob in a u16-LENGTH field, so the whole
         * entry must stay under 64 KB. btx_save_resume deliberately omits
         * save_info_dict, so a normal torrent's blob is far smaller; but guard the
         * pathological case (a huge piece count) by reporting a clean FAILURE
         * rather than SILENTLY TRUNCATING the blob and WRAPPING the drain's u16
         * bodyLen (which would corrupt every later record in the batch). A future
         * ABI revision could add a raw-bytes resume getter to lift this cap. */
        static const size_t kResumeRecordMax = 0xFF00;  /* ~256 B headroom under u16 */
        if (buf.size() > kResumeRecordMax) {
            out.type = btx::A_RESUME_DATA_FAILED;
            out.hasErrorMessage = true;
            out.errorMessage = "resume data (" + std::to_string(buf.size())
                + " bytes) exceeds the event-record limit; not delivered";
        } else {
            out.type = btx::A_RESUME_DATA_READY;
            out.hasResumeData = true;
            out.resumeData = std::move(buf);
        }
        return true;
    }
    if (auto *p = lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
        out.type = btx::A_RESUME_DATA_FAILED;
        out.torrentId = idForHandle(p->handle);
        out.hasErrorCode = true; out.errorCode = p->error.value();
        out.hasErrorMessage = true; out.errorMessage = p->error.message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::torrent_removed_alert>(a)) {
        out.type = btx::A_TORRENT_REMOVED;
        /* The handle may already be invalid here; the alert also carries the
         * info_hashes so the app can still identify which torrent went away. */
        const int id = idForHandle(p->handle);
        out.torrentId = id;
        lt::info_hash_t ih = p->info_hashes;
        if (ih.has_v1()) { out.hasInfoHashV1 = true; out.infoHashV1 = hash_hex(ih.v1); }
        if (ih.has_v2()) { out.hasInfoHashV2 = true; out.infoHashV2 = hash_hex(ih.v2); }
        /* Reclaim the slot + reverse-map entry HERE — the one place that catches
         * BOTH an app-initiated btx_remove AND a SELF-removal (fatal error etc.)
         * that never went through btx_remove. torrent_removed_alert fires before
         * the handle is reused, so this never frees a live torrent. For an
         * app-initiated remove the entry is already gone, so this is a no-op
         * (preventing the unbounded table/map leak the previous code had). */
        if (id != 0) st->torrents.free(id);
        st->idOf.erase(p->handle);
        return true;
    }
    if (lt::alert_cast<lt::dht_bootstrap_alert>(a)) {
        /* No handle, no torrent. Just the event itself. */
        out.type = btx::A_DHT_BOOTSTRAP;
        return true;
    }
    if (auto *p = lt::alert_cast<lt::listen_succeeded_alert>(a)) {
        out.type = btx::A_LISTEN_SUCCEEDED;
        /* No torrent handle; carry the endpoint string for the event. */
        out.hasEndpoint = true;
        out.endpoint = p->address.to_string();  /* no-arg form: stable across Boost */
        out.endpoint += ':';
        out.endpoint += std::to_string(p->port);
        out.hasMessage = true; out.message = p->message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::listen_failed_alert>(a)) {
        out.type = btx::A_LISTEN_FAILED;
        out.hasErrorCode = true; out.errorCode = p->error.value();
        out.hasErrorMessage = true; out.errorMessage = p->error.message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::torrent_paused_alert>(a)) {
        out.type = btx::A_TORRENT_PAUSED;
        out.torrentId = idForHandle(p->handle);
        return true;
    }
    if (auto *p = lt::alert_cast<lt::torrent_resumed_alert>(a)) {
        out.type = btx::A_TORRENT_RESUMED;
        out.torrentId = idForHandle(p->handle);
        return true;
    }
    if (auto *p = lt::alert_cast<lt::file_completed_alert>(a)) {
        out.type = btx::A_FILE_COMPLETED;
        out.torrentId = idForHandle(p->handle);
        out.hasPieceIndex = true;  /* reuse the index field to carry file index */
        out.pieceIndex = static_cast<long long>(static_cast<int>(p->index));
        return true;
    }
    if (auto *p = lt::alert_cast<lt::file_error_alert>(a)) {
        out.type = btx::A_FILE_ERROR;
        out.torrentId = idForHandle(p->handle);
        out.hasErrorCode = true; out.errorCode = p->error.value();
        out.hasErrorMessage = true; out.errorMessage = p->error.message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::storage_moved_alert>(a)) {
        out.type = btx::A_STORAGE_MOVED;
        out.torrentId = idForHandle(p->handle);
        out.hasMessage = true; out.message = p->message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::fastresume_rejected_alert>(a)) {
        out.type = btx::A_FASTRESUME_REJECTED;
        out.torrentId = idForHandle(p->handle);
        out.hasErrorCode = true; out.errorCode = p->error.value();
        out.hasErrorMessage = true; out.errorMessage = p->error.message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::scrape_reply_alert>(a)) {
        out.type = btx::A_SCRAPE_REPLY;
        out.torrentId = idForHandle(p->handle);
        out.hasMessage = true; out.message = p->message();
        return true;
    }
    if (auto *p = lt::alert_cast<lt::dht_immutable_item_alert>(a)) {
        out.type = btx::A_DHT_IMMUTABLE_ITEM;
        out.hasDhtTarget = true; out.dhtTarget = hash_hex(p->target);
        out.hasDhtValue = true;  out.dhtValue = entry_to_bytes(p->item);
        return true;
    }
    if (auto *p = lt::alert_cast<lt::dht_mutable_item_alert>(a)) {
        out.type = btx::A_DHT_MUTABLE_ITEM;
        out.hasDhtPublicKey = true;    out.dhtPublicKey = hash_hex(p->key);
        out.hasDhtSignature = true;    out.dhtSignature = hash_hex(p->signature);
        out.hasDhtSeq = true;          out.dhtSeq = static_cast<long long>(p->seq);
        out.hasDhtSalt = true;         out.dhtSalt = p->salt;
        out.hasDhtValue = true;        out.dhtValue = entry_to_bytes(p->item);
        out.hasDhtAuthoritative = true; out.dhtAuthoritative = p->authoritative ? 1 : 0;
        return true;
    }
    if (auto *p = lt::alert_cast<lt::dht_put_alert>(a)) {
        out.type = btx::A_DHT_PUT;
        out.hasDhtNumSuccess = true; out.dhtNumSuccess = p->num_success;
        /* immutable put -> target is set, public_key zeroed; mutable -> reverse */
        if (!p->target.is_all_zeros()) {
            out.hasDhtTarget = true; out.dhtTarget = hash_hex(p->target);
        } else {
            out.hasDhtPublicKey = true; out.dhtPublicKey = hash_hex(p->public_key);
            out.hasDhtSignature = true; out.dhtSignature = hash_hex(p->signature);
            out.hasDhtSeq = true;       out.dhtSeq = static_cast<long long>(p->seq);
            out.hasDhtSalt = true;      out.dhtSalt = p->salt;
        }
        return true;
    }

    /* Unmapped alert: not surfaced. The broad alert_mask still lets a few
     * uninteresting categories through; we drop them HERE (not at the queue) so
     * the mask can stay broad without forcing a registry entry per type. */
    return false;
}

/* Serialise one PendingAlert into the drain stream at the writer's cursor, using
 * the EXACT framing pinned by record_handle_test.cpp::write_alert_entry and the
 * Python golden: [alertType:u16][bodyLen:u16][kvrecord]. Returns false WITHOUT
 * advancing past a partial write if the record would not fit what remains (so
 * the caller can stash it) — measured by writing into a throwaway probe first.
 *
 * We size-probe with a zero-capacity RecordWriter to learn the exact byte need,
 * then only commit to the real writer if it fits the remaining capacity. This
 * keeps the "never drop, never half-write" guarantee simple. */
void write_alert_entry(btx::RecordWriter &rw, const PendingAlert &pa) {
    rw.put_u16(pa.type);
    const size_t bodyAt = rw.pos();
    rw.put_u16(0);  /* bodyLen placeholder */
    const size_t bodyStart = rw.pos();
    {
        btx::KVRecord r(rw);
        /* F_EVT_TORRENT is ALWAYS the first field (0 when the alert has no
         * torrent, e.g. dht/listen), matching the golden vector ordering so the
         * LCB walker can read a stable leading id. */
        r.put_int(btx::F_EVT_TORRENT, pa.torrentId);
        if (pa.hasMessage)      r.put_str(btx::F_EVT_MESSAGE, pa.message);
        if (pa.hasErrorCode)    r.put_int(btx::F_EVT_ERROR_CODE, pa.errorCode);
        if (pa.hasErrorMessage) r.put_str(btx::F_EVT_ERROR_MESSAGE, pa.errorMessage);
        if (pa.hasPieceIndex)   r.put_int(btx::F_EVT_PIECE_INDEX, pa.pieceIndex);
        if (pa.hasState)        r.put_int(btx::F_EVT_STATE, pa.state);
        if (pa.hasPrevState)    r.put_int(btx::F_EVT_PREV_STATE, pa.prevState);
        if (pa.hasTrackerUrl)   r.put_str(btx::F_EVT_TRACKER_URL, pa.trackerUrl);
        if (pa.hasNumPeers)     r.put_int(btx::F_EVT_NUM_PEERS, pa.numPeers);
        if (pa.hasResumeData)   r.put_bytes(btx::F_EVT_RESUME_DATA,
                                            pa.resumeData.data(), pa.resumeData.size());
        if (pa.hasInfoHashV1)   r.put_hex(btx::F_EVT_INFO_HASH_V1, pa.infoHashV1);
        if (pa.hasInfoHashV2)   r.put_hex(btx::F_EVT_INFO_HASH_V2, pa.infoHashV2);
        if (pa.hasName)         r.put_str(btx::F_EVT_NAME, pa.name);
        if (pa.hasEndpoint)     r.put_str(btx::F_EVT_ENDPOINT, pa.endpoint);
        if (pa.hasDhtTarget)        r.put_hex(btx::F_DHT_TARGET, pa.dhtTarget);
        if (pa.hasDhtValue)         r.put_bytes(btx::F_DHT_VALUE, pa.dhtValue.data(), pa.dhtValue.size());
        if (pa.hasDhtPublicKey)     r.put_hex(btx::F_DHT_PUBLIC_KEY, pa.dhtPublicKey);
        if (pa.hasDhtSignature)     r.put_hex(btx::F_DHT_SIGNATURE, pa.dhtSignature);
        if (pa.hasDhtSeq)           r.put_int(btx::F_DHT_SEQ, pa.dhtSeq);
        if (pa.hasDhtSalt)          r.put_str(btx::F_DHT_SALT, pa.dhtSalt);
        if (pa.hasDhtAuthoritative) r.put_int(btx::F_DHT_AUTHORITATIVE, pa.dhtAuthoritative);
        if (pa.hasDhtNumSuccess)    r.put_int(btx::F_DHT_NUM_SUCCESS, pa.dhtNumSuccess);
        r.finish();
    }
    rw.patch_u16(bodyAt, static_cast<uint16_t>(rw.pos() - bodyStart));
}

/* Exact byte size write_alert_entry would produce for `pa`. RecordWriter
 * advances pos() even past capacity (it just stops COPYING), so writing into a
 * zero-capacity probe MEASURES the entry without touching memory. This is the
 * function the old code lacked — it measured by calling emit_alert on a 0-cap
 * writer, which refused to write and so always reported a bogus 2 bytes. */
size_t measure_alert_entry(const PendingAlert &pa) {
    btx::RecordWriter probe(nullptr, 0);
    write_alert_entry(probe, pa);
    return probe.pos();
}

/* Emit one entry IF it fits the buffer's remaining capacity; otherwise return
 * false having written nothing past the cursor, so the caller stashes it. */
bool emit_alert(btx::RecordWriter &w, const PendingAlert &pa) {
    const size_t need = measure_alert_entry(pa);
    if (w.pos() + need > w.capacity()) return false;  /* stash it for next call */
    write_alert_entry(w, pa);
    return true;
}

}  // namespace

extern "C" BTX_API int BTX_CALL btx_pop_alerts(int s, void *out, int cap) {
    BTX_GUARD_INT({
        SessionState *st = session_for(s);
        if (!st || !st->ses) return 0;  /* no session -> no alerts, harmless */

        /* Drive a session_stats refresh: post now, capture the resulting
         * session_stats_alert on a later drain (extract_alert), so btx_dht_state
         * always has fresh DHT counters without a synchronous stats round-trip.
         * The alert is consumed internally and never surfaced to script. */
        st->ses->post_session_stats();

        /* Build: [alertCount:u16] then alertCount x entry. We backpatch the
         * count, so a buffer that fits only some entries still reports an honest
         * count of what it CONTAINS, and the rest are stashed for next call. */
        btx::RecordWriter w(out, cap);
        const size_t countAt = w.pos();
        w.put_u16(0);  /* alertCount placeholder */
        uint16_t written = 0;

        /* 1) Emit anything stashed from a previous call FIRST (FIFO), so order is
         *    preserved across the buffer boundary and nothing is ever dropped. */
        size_t stashConsumed = 0;
        for (; stashConsumed < st->stash.size(); ++stashConsumed) {
            if (!emit_alert(w, st->stash[stashConsumed])) break;
            ++written;
        }
        /* Drop the consumed prefix of the stash. */
        if (stashConsumed > 0)
            st->stash.erase(st->stash.begin(),
                            st->stash.begin() + static_cast<long>(stashConsumed));

        /* If the stash did not fully drain, we cannot take fresh alerts this call
         * (they would jump the queue). Finish with what we have; the rest waits.
         * One subtlety: if NOTHING fit and the buffer is genuinely too small for
         * even the first stashed record, report -need so the caller can grow. */
        if (!st->stash.empty()) {
            w.patch_u16(countAt, written);
            if (written == 0) {
                /* Even the first stashed entry did not fit. Report the TRUE need
                 * (the [alertCount:u16] prefix + the entry) so the caller grows
                 * and makes progress. The old code measured with emit_alert on a
                 * 0-cap writer, which wrote nothing and always returned -2 — so a
                 * grow to 2 bytes still never fit and the stream wedged forever. */
                return -static_cast<int>(2 + measure_alert_entry(st->stash.front()));
            }
            return written;
        }

        /* 2) Drain fresh alerts from libtorrent. pop_alerts swaps the queue into
         *    our vector; the pointers are valid ONLY until the next pop_alerts,
         *    so we extract each into an owning PendingAlert immediately. */
        std::vector<lt::alert *> alerts;
        st->ses->pop_alerts(&alerts);

        /* Once ONE alert does not fit, EVERY later alert must also be stashed,
         * even if it is small enough to fit the remaining bytes — otherwise it
         * would jump ahead of the stashed one and break FIFO order. This latch
         * enforces "stash the tail wholesale". */
        bool stashing = false;
        for (lt::alert *a : alerts) {
            PendingAlert pa;
            if (!extract_alert(st, a, pa)) continue;  /* unmapped -> skip */

            /* Special-case bookkeeping: once we have EXTRACTED a torrent_removed,
             * the id is no longer meaningful; btx_remove already erased the map +
             * freed the slot, so nothing more to do here. */

            if (!stashing && emit_alert(w, pa)) {
                ++written;
            } else {
                /* Does not fit (or we are already stashing the tail) -> stash in
                 * order for the next call. NEVER drop (the ShowControl MIDI
                 * rule), and never reorder. */
                stashing = true;
                st->stash.push_back(std::move(pa));
            }
        }

        w.patch_u16(countAt, written);
        if (written == 0 && !st->stash.empty()) {
            /* A FRESH alert was too big for the buffer (nothing emitted, the tail
             * was stashed). Signal -need now so the caller grows on the next call
             * instead of seeing a misleading 0 ("no alerts pending"). */
            return -static_cast<int>(2 + measure_alert_entry(st->stash.front()));
        }
        return written;
    });
}

/* ====================================================================== *
 *  DHT
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_dht_add_bootstrap(int s, const char *host,
                                                      int port) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        if (!host || !*host || port <= 0 || port > 65535) {
            set_error("bad DHT bootstrap host/port"); return BTX_ERR_INVALID_ARG;
        }
        /* add_dht_node takes a (host, port) pair; libtorrent resolves it on its
         * own threads. A bad host surfaces later as a (non-fatal) DHT alert. */
        st->ses->add_dht_node({host, port});
        return BTX_OK;
    });
}

extern "C" BTX_API int BTX_CALL btx_dht_state(int s, void *out, int cap) {
    BTX_GUARD_BUFFER({
        SessionState *st = session_for(s);
        if (!st || !st->ses) return 0;  /* no session -> empty record */

        /* A small KV snapshot of DHT health, reporting the REAL session_stats
         * counters cached by btx_pop_alerts (which fires post_session_stats each
         * poll). The values are 0 until the first stats alert lands a moment after
         * startup, or where this libtorrent build lacks a given metric; the LCB
         * layer treats absent/zero gracefully. F_DHT_NODES is the live routing-
         * table node count (no longer a 0/1 running flag). */
        btx::RecordWriter w(out, cap);
        btx::KVRecord r(w);
        r.put_int(btx::F_DHT_NODES, st->dhtNodes);
        r.put_int(btx::F_DHT_NODE_CACHE, st->dhtNodeCache);
        r.put_int(btx::F_DHT_GLOBAL_NODES, st->dhtGlobalNodes);
        r.put_int(btx::F_DHT_TORRENTS, st->dhtTorrents);
        r.finish();
        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

extern "C" BTX_API int BTX_CALL btx_dht_save_state(int s, void *out, int cap) {
    BTX_GUARD_BUFFER({
        SessionState *st = session_for(s);
        if (!st || !st->ses) return 0;

        /* Opaque routing-table state for persistence across runs. In 2.0 the DHT
         * state rides inside session_params; session_state(save_dht_state) returns
         * just that subset, and write_session_params_buf serialises it to bytes the
         * app stores verbatim and feeds back to btx_dht_load_state. Both calls are
         * public/exported — the lower-level lt::dht::save_dht_state is NOT in the
         * shared library's ABI. */
        lt::session_params params =
            st->ses->session_state(lt::session_handle::save_dht_state);
        std::vector<char> buf =
            lt::write_session_params_buf(params, lt::session_handle::save_dht_state);

        const size_t need = buf.size();
        if (out && cap > 0 && need <= static_cast<size_t>(cap))
            std::memcpy(out, buf.data(), need);
        if (need > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(need);
        return static_cast<int>(need);
    });
}

extern "C" BTX_API int BTX_CALL btx_dht_load_state(int s, const void *data,
                                                   int len) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        if (!data || len <= 0) { set_error("empty DHT state"); return BTX_ERR_INVALID_ARG; }

        /* Re-hydrate the saved session_params (DHT subset) and hand the node
         * table back to the running DHT. read_session_params is the public,
         * exported inverse of write_session_params_buf; a malformed blob yields
         * default (empty) params rather than crashing, and any throw is caught by
         * the firewall above. */
        lt::session_params params = lt::read_session_params(
            {reinterpret_cast<char const *>(data), len},
            lt::session_handle::save_dht_state);
        st->ses->set_dht_state(std::move(params.dht_state));
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  BEP44: the DHT as a key-value store
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_dht_keypair(const char *seedHexOrEmpty,
                                                void *out, int cap) {
    BTX_GUARD_BUFFER({
        ed_seed seed;
        if (seedHexOrEmpty && *seedHexOrEmpty) {
            if (!hex_to_buf(seedHexOrEmpty, seed.data(), 32)) {
                set_error("seed must be empty or 64 hex chars");
                return 0;
            }
        } else {
            seed = lt::dht::ed25519_create_seed();
        }
        lt::dht::public_key pk;
        lt::dht::secret_key sk;
        std::tie(pk, sk) = lt::dht::ed25519_create_keypair(seed);

        btx::RecordWriter w(out, cap);
        btx::KVRecord r(w);
        r.put_hex(btx::F_DHT_PUBLIC_KEY, hash_hex(pk.bytes));
        r.put_hex(btx::F_DHT_SECRET_KEY, hash_hex(sk.bytes));
        r.put_hex(btx::F_DHT_SEED, hash_hex(seed));
        r.finish();
        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

extern "C" BTX_API int BTX_CALL btx_dht_put_immutable(int s, const void *data,
                                                      int len, char *outTargetHex,
                                                      int cap) {
    BTX_GUARD_BUFFER({
        SessionState *st = session_for(s);
        if (!st || !st->ses) return 0;  /* no session -> 0 (no target) */
        if (!data || len < 0 || len > 1000) { set_error("value must be 0..1000 bytes"); return 0; }
        lt::entry e(std::string(static_cast<const char *>(data),
                                static_cast<size_t>(len)));
        /* dht_put_item returns the target (SHA-1 of the bencoded value) NOW; the
         * store itself confirms later as an A_DHT_PUT alert. */
        lt::sha1_hash target = st->ses->dht_put_item(e);
        std::string hex = hash_hex(target);
        const size_t need = hex.size();
        if (outTargetHex && cap > 0 && need <= static_cast<size_t>(cap))
            std::memcpy(outTargetHex, hex.data(), need);
        if (need > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(need);
        return static_cast<int>(need);
    });
}

extern "C" BTX_API int BTX_CALL btx_dht_get_immutable(int s, const char *targetHex) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        char buf[20];
        if (!hex_to_buf(targetHex, buf, 20)) {
            set_error("target must be 40 hex chars"); return BTX_ERR_INVALID_ARG;
        }
        st->ses->dht_get_item(lt::sha1_hash(buf));  /* result -> A_DHT_IMMUTABLE_ITEM */
        return BTX_OK;
    });
}

/* Sign a mutable-item STRING value the BEP44 way, setting the entry `e` that
 * libtorrent will store. THE SIGNATURE MUST COVER THE BENCODED VALUE (a string
 * "hi" bencodes to "2:hi"), because that is exactly what every storing node and
 * every getter verifies it against — signing the raw bytes yields a signature
 * that verifies against nothing, so nodes reject the store and getters never
 * surface the item, and a whole signed channel feed silently disappears.
 * Mirrors libtorrent's own examples/dht_put.cpp. `out_signed` receives the
 * bencoded buffer that was signed so a caller (the smoke test) can re-verify
 * with verify_mutable_item; the production put callback and that test hook both
 * route through here, so the test exercises the REAL signing path. */
static lt::dht::signature sign_mutable_string_entry(
        lt::entry &e, const std::vector<char> &val, const std::string &salt,
        std::int64_t seq, const lt::dht::public_key &pk,
        const lt::dht::secret_key &sk, std::vector<char> &out_signed) {
    e = lt::entry(std::string(val.begin(), val.end()));
    out_signed.clear();
    lt::bencode(std::back_inserter(out_signed), e);
    return lt::dht::sign_mutable_item(out_signed, salt,
                                      lt::dht::sequence_number(seq), pk, sk);
}

extern "C" BTX_API int BTX_CALL btx_dht_put_mutable(int s, const char *publicKeyHex,
                                                    const char *secretKeyHex,
                                                    const char *salt,
                                                    const void *data, int len) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        if (!data || len < 0 || len > 1000) { set_error("value must be 0..1000 bytes"); return BTX_ERR_INVALID_ARG; }
        lt::dht::public_key pk;
        lt::dht::secret_key sk;
        if (!hex_to_buf(publicKeyHex, pk.bytes.data(), 32)) { set_error("public key must be 64 hex chars"); return BTX_ERR_INVALID_ARG; }
        if (!hex_to_buf(secretKeyHex, sk.bytes.data(), 64)) { set_error("secret key must be 128 hex chars"); return BTX_ERR_INVALID_ARG; }
        std::string salt_s = salt ? salt : "";
        std::vector<char> val(static_cast<const char *>(data),
                              static_cast<const char *>(data) + len);
        /* The signing callback runs on libtorrent's network thread once it has
         * found where to store the blob. It captures owning COPIES of everything
         * (value, salt, keypair) — no script, no shared state, no locks — and
         * signs with sign_mutable_item, honouring rule 1. */
        st->ses->dht_put_item(pk.bytes,
            [val, salt_s, pk, sk](lt::entry &e, std::array<char, 64> &sig,
                                  std::int64_t &seq, std::string const &) {
                seq = seq + 1;  /* monotonic: bump past the current value */
                std::vector<char> signed_buf;  /* the bencoded value we signed */
                lt::dht::signature sg = sign_mutable_string_entry(
                    e, val, salt_s, seq, pk, sk, signed_buf);
                sig = sg.bytes;
            }, salt_s);
        return BTX_OK;  /* confirmation -> A_DHT_PUT alert */
    });
}

extern "C" BTX_API int BTX_CALL btx_dht_get_mutable(int s, const char *publicKeyHex,
                                                    const char *salt) {
    BTX_GUARD_ACTION({
        SessionState *st = session_for(s);
        if (!st || !st->ses) { set_error("no live session"); return BTX_ERR_NO_SESSION; }
        lt::dht::public_key pk;
        if (!hex_to_buf(publicKeyHex, pk.bytes.data(), 32)) { set_error("public key must be 64 hex chars"); return BTX_ERR_INVALID_ARG; }
        st->ses->dht_get_item(pk.bytes, salt ? salt : "");  /* -> A_DHT_MUTABLE_ITEM */
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Persistence (resume data) — async (plan §4.3)
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_save_resume(int t) {
    BTX_GUARD_ACTION({
        bool ok = false; lt::torrent_handle h = torrent_only(t, nullptr, &ok);
        if (!ok) { set_error("bad torrent handle"); return BTX_ERR_BAD_HANDLE; }
        /* REQUEST resume data; the bytes arrive later as a save_resume_data_alert
         * we surface as A_RESUME_DATA_READY (carrying F_EVT_RESUME_DATA). There is
         * deliberately no synchronous getter — this honours libtorrent's async
         * model. We do NOT pass save_info_dict: it embeds the full piece-hash
         * table, which blows past the event record's u16 length cap for any
         * non-trivial torrent (and the blob cannot be re-fragmented). The
         * fast-resume state (piece progress, priorities, trackers) is what matters
         * for resuming; the torrent metadata is recovered on re-add from the
         * original magnet/.torrent (or re-fetched), per libtorrent's normal model. */
        h.save_resume_data(lt::torrent_handle::flush_disk_cache);
        return BTX_OK;
    });
}

/* ====================================================================== *
 *  Create torrents (seeding side — plan Phase 3)
 * ====================================================================== */

extern "C" BTX_API int BTX_CALL btx_create_torrent(const char *contentPath,
                                                   int pieceSize, int flags,
                                                   const char *trackers,
                                                   void *out, int cap) {
    BTX_GUARD_BUFFER({
        if (!contentPath || !*contentPath) { set_error("empty content path"); return 0; }

        /* Scan the file/dir into a file_storage, hash it, and bencode the result
         * into the caller buffer. This reads content off disk on THIS thread (a
         * deliberate, documented blocking call — it is a build step, not the hot
         * path), but still only the METAINFO crosses the FFI, never payload. */
        lt::file_storage fs;
        lt::add_files(fs, contentPath);
        if (fs.num_files() == 0) { set_error("no files at content path"); return 0; }

        /* pieceSize 0 == auto (let libtorrent pick). flags pass through to
         * create_torrent (v1/v2/hybrid, optimize, etc.) as the caller chose. */
        lt::create_torrent ct(fs, pieceSize, lt::create_flags_t{
            static_cast<std::uint32_t>(static_cast<unsigned>(flags))});

        /* Optional announce URLs: a newline-separated list. Each non-empty,
         * trimmed line becomes its own tracker tier (so they are tried in order);
         * an absent/empty list yields a trackerless, DHT-only torrent. */
        if (trackers && *trackers) {
            std::string all(trackers);
            size_t start = 0;
            int tier = 0;
            while (start <= all.size()) {
                size_t nl = all.find('\n', start);
                std::string line = all.substr(
                    start, nl == std::string::npos ? std::string::npos : nl - start);
                size_t b = line.find_first_not_of(" \t\r");
                size_t e = line.find_last_not_of(" \t\r");
                if (b != std::string::npos)
                    ct.add_tracker(line.substr(b, e - b + 1), tier++);
                if (nl == std::string::npos) break;
                start = nl + 1;
            }
        }

        /* set_piece_hashes needs the PARENT directory of the content so it can
         * open the files; derive it from contentPath. */
        std::string parent = contentPath;
        {
            /* Strip the last path component to get the parent. Works for both
             * a trailing-slash dir and a file path. Cross-platform-ish: handle
             * both separators. */
            size_t pos = parent.find_last_of("/\\");
            if (pos != std::string::npos) parent.erase(pos);
            else parent = ".";
            if (parent.empty()) parent = "/";
        }

        lt::error_code ec;
        lt::set_piece_hashes(ct, parent, ec);
        if (ec) { set_error("hashing failed: " + ec.message()); return 0; }

        lt::entry e = ct.generate();
        std::vector<char> buf;
        lt::bencode(std::back_inserter(buf), e);

        const size_t need = buf.size();
        if (out && cap > 0 && need <= static_cast<size_t>(cap))
            std::memcpy(out, buf.data(), need);
        if (need > static_cast<size_t>(cap < 0 ? 0 : cap))
            return -static_cast<int>(need);
        return static_cast<int>(need);
    });
}

/* ====================================================================== *
 *  Internal test hooks (NOT part of the FFI; see torrent_shim.h)
 * ====================================================================== */

namespace btx {
namespace test {

int force_throw(void) {
    /* Run a body that always throws THROUGH the production firewall macro, so the
     * smoke test proves the real catch path — not a bespoke one — converts a
     * throw into BTX_ERR_EXCEPTION and records a last-error. */
    BTX_GUARD_ACTION({
        throw std::runtime_error("deliberate test throw");
    });
}

int live_session_count(void) {
    return static_cast<int>(g_sessions.live_count());
}

int dht_mutable_sign_verifies(const char *publicKeyHex, const char *secretKeyHex,
                              const char *salt, const void *data, int len) {
    /* Sign a mutable value through the SAME helper the production put uses, then
     * check it with libtorrent's own verify_mutable_item — the exact gate a
     * follower's libtorrent applies before surfacing the item. A pass proves the
     * BEP44 signing contract holds (sign the bencoded value); a regression here
     * is the silent "feeds never arrive" failure. Wrapped in the firewall like
     * every entry, so a throw becomes a negative code, never a CHECK crash. */
    BTX_GUARD_ACTION({
        lt::dht::public_key pk;
        lt::dht::secret_key sk;
        if (!hex_to_buf(publicKeyHex, pk.bytes.data(), 32)) return 0;
        if (!hex_to_buf(secretKeyHex, sk.bytes.data(), 64)) return 0;
        std::string salt_s = salt ? salt : "";
        const char *p = static_cast<const char *>(data);
        std::vector<char> val(p, p + (len < 0 ? 0 : len));
        lt::entry e;
        std::vector<char> signed_buf;     /* the bencoded value v that was signed */
        const std::int64_t seq = 1;
        lt::dht::signature sg =
            sign_mutable_string_entry(e, val, salt_s, seq, pk, sk, signed_buf);
        /* Reconstruct the BEP44 canonical signed message exactly as a remote
         * verifier does — [4:salt<len>:<salt>] 3:seqi<seq>e 1:v <bencoded v> —
         * and check the signature with ed25519_verify, the same primitive a
         * follower's libtorrent applies. (verify_mutable_item itself is
         * TORRENT_EXTRA_EXPORT, not in the shared lib, so we use the public
         * ed25519 verify against the canonical string instead.) If the value was
         * signed bencoded (correct) this passes; if signed raw (the bug) it
         * fails — so this assertion is the regression guard for that silent bug. */
        std::string canon;
        if (!salt_s.empty()) {
            canon += "4:salt";
            canon += std::to_string(salt_s.size());
            canon += ":";
            canon += salt_s;
        }
        canon += "3:seqi";
        canon += std::to_string(seq);
        canon += "e1:v";
        canon.append(signed_buf.begin(), signed_buf.end());
        return lt::dht::ed25519_verify(sg, canon, pk) ? 1 : 0;
    });
}

}  // namespace test
}  // namespace btx
