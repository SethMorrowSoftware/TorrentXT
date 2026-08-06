/* datachannel_shim.cpp — the flat extern "C" facade over libdatachannel's C API
 * (rtc/rtc.h). This is the ONE place WebRTC's threads meet the OXT/LCB
 * foreign-function boundary, and it is the family's first binding with REAL
 * cross-thread concurrency, so every design choice below serves the three
 * load-bearing rules (CLAUDE.md / NEXT-EXTENSIONS-PLAN Part IV):
 *
 *   1. NEVER call script from a foreign thread. libdatachannel fires EVERY
 *      callback (descriptions, candidates, states, opens, messages) from its
 *      own worker threads. Each callback body here does exactly one thing:
 *      take the state mutex, push an owned copy of the event onto a bounded
 *      queue, release. dcx_poll — the engine's single script thread, on a
 *      timer — drains that queue as a record list. The mutex-guarded queue is
 *      the single most important correctness structure in this binding.
 *
 *   2. THE EXCEPTION FIREWALL — in BOTH directions. Every dcx_* entry point
 *      wraps its body in the DCX_GUARD_* macros (a throw becomes a recorded
 *      error, never an unwind across extern "C" into the engine). And every
 *      CALLBACK body is wrapped in its own try/catch(...) so nothing we do (a
 *      bad_alloc copying a payload, say) can unwind back into libdatachannel's
 *      thread either.
 *
 *   3. PAYLOAD ACROSS THE FFI is allowed here BY DESIGN — a data-channel
 *      message IS the payload — but bounded: DCX_MAX_MESSAGE (60000 bytes)
 *      both ways, refused loudly (never truncated or split silently), with
 *      bulk transfer explicitly routed to TorrentXT. See dcx_abi.h.
 *
 * THE LOCK DISCIPLINE (the deadlock-shaped hazard unique to this binding):
 * rtcDelete* blocks until in-flight callbacks for that object return, and our
 * callbacks block briefly on g_mu. So an entry point that held g_mu while
 * calling into libdatachannel could deadlock: callback thread waits on g_mu,
 * we wait on the callback. The rule, therefore, applied to EVERY entry point:
 *
 *      NEVER call an rtc* function while holding g_mu.
 *      Lock -> validate/copy what you need -> UNLOCK -> call rtc*.
 *
 * (Callbacks do the reverse — they are ON the rtc thread already, so they may
 * call cheap rtc getters/setters freely but take g_mu only for the enqueue /
 * table touch, and never call rtcDelete*, which their own docs forbid from a
 * callback.)
 *
 * Handle safety: peers and channels are addressed by POSITIVE, generation-
 * tagged ints from dcx::HandleTable, validated on every use, so a stale handle
 * is a harmless no-op. libdatachannel's own C-API ids are NOT generation-
 * tagged (a recycled id would alias), so they are never exposed: the shim maps
 * rtc id <-> our handle internally, and events carry OUR ids, copied at
 * enqueue and re-validated at drain (an event naming a since-freed handle is
 * silently discarded — the app said it no longer cares).
 *
 * libdatachannel headers are treated as SYSTEM headers (the build passes them
 * with -isystem) so their warnings never pollute our -Wall -Wextra. */

#include "datachannel_shim.h"
#include "dcx_record.h"
#include "dcx_handle_table.h"

/* ---- libdatachannel C API (system header; -isystem keeps warnings out) ---- */
#include <rtc/rtc.h>

/* ---- standard library ------------------------------------------------------ */
#include <cstring>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

/* Our PS_ and GS_ record-registry values MIRROR rtcState/rtcGatheringState
 * (the W3C numbering). Assert the equality against the real header so an
 * upstream renumbering cannot skew the LCB constants silently. */
static_assert(dcx::PS_NEW == static_cast<int>(RTC_NEW) &&
              dcx::PS_CONNECTING == static_cast<int>(RTC_CONNECTING) &&
              dcx::PS_CONNECTED == static_cast<int>(RTC_CONNECTED) &&
              dcx::PS_DISCONNECTED == static_cast<int>(RTC_DISCONNECTED) &&
              dcx::PS_FAILED == static_cast<int>(RTC_FAILED) &&
              dcx::PS_CLOSED == static_cast<int>(RTC_CLOSED),
              "dcx::PeerState must mirror rtcState");
static_assert(dcx::GS_NEW == static_cast<int>(RTC_GATHERING_NEW) &&
              dcx::GS_IN_PROGRESS == static_cast<int>(RTC_GATHERING_INPROGRESS) &&
              dcx::GS_COMPLETE == static_cast<int>(RTC_GATHERING_COMPLETE),
              "dcx::GatheringState must mirror rtcGatheringState");

namespace {

/* ====================================================================== *
 *  Module state — ONE mutex guards all of it
 *
 *  g_mu is taken by the script thread (entry points, the drain) AND by
 *  libdatachannel's callback threads (the enqueue). Everything below the
 *  mutex line is shared; g_last_error is NOT (script thread only — callbacks
 *  never set an error, they enqueue events).
 * ====================================================================== */

/* The last-error string the firewall (and validation failures) write, read
 * back by dcx_last_error. Script-thread only, so unguarded by design. */
std::string g_last_error;

inline void set_error(const std::string &msg) { g_last_error = msg; }
inline void set_error(const char *msg) { g_last_error = msg ? msg : ""; }

/* One peer connection. rtcId is libdatachannel's C-API id for it. */
struct PeerState {
    int rtcId = 0;
};

/* One data channel. openAnnounced dedupes E_CHANNEL_OPEN between the open
 * callback and the already-open check made when wiring a remote-initiated
 * channel (both paths can observe the open; exactly one may announce it). */
struct ChannelState {
    int rtcId = 0;
    int peerHandle = 0;
    bool openAnnounced = false;
};

/* One queued inbound event — owned copies only, never pointers into
 * libdatachannel memory (the callback's strings die when it returns). */
struct PendingEvent {
    uint16_t type = 0;
    int peerId = 0;            /* OUR peer handle (0 = none)    */
    int channelId = 0;         /* OUR channel handle (0 = none) */
    bool hasSdp = false;       std::string sdp;
    bool hasSdpType = false;   std::string sdpType;
    bool hasCandidate = false; std::string candidate;
    bool hasMid = false;       std::string mid;
    bool hasState = false;     int state = 0;
    bool hasLabel = false;     std::string label;
    bool hasProtocol = false;  std::string protocol;
    bool hasPayload = false;   std::vector<char> payload;  /* binary message */
    bool hasText = false;      std::string text;           /* text message   */
    bool hasError = false;     std::string error;
    bool hasDropped = false;   long long dropped = 0;

    /* Approximate heap cost, charged against the byte bound. */
    size_t cost() const {
        return sizeof(PendingEvent) + sdp.size() + sdpType.size() +
               candidate.size() + mid.size() + label.size() + protocol.size() +
               payload.size() + text.size() + error.size();
    }
};

std::mutex g_mu;

dcx::HandleTable<PeerState>    g_peers;      /* guarded by g_mu */
dcx::HandleTable<ChannelState> g_channels;   /* guarded by g_mu */

/* rtc C-API id -> OUR handle. Callbacks arrive keyed by rtc id; these maps
 * translate under the mutex. An id with no mapping (already freed) is a
 * silently dropped event — exactly the stale-handle-is-a-no-op rule. */
std::unordered_map<int, int> g_rtcPeerToHandle;   /* guarded by g_mu */
std::unordered_map<int, int> g_rtcChanToHandle;   /* guarded by g_mu */

/* Shadow of each peer's LAST reported connection/gathering state, keyed by OUR
 * handle and refreshed by the state callbacks. libdatachannel's C API has no
 * synchronous state getter, so dcx_peer_state / dcx_gathering_state answer
 * from this shadow — which is also the honest answer: it is the newest state
 * the event stream has (or will have) told the app about. */
std::unordered_map<int, int> g_peerLastState;      /* guarded by g_mu */
std::unordered_map<int, int> g_peerLastGathering;  /* guarded by g_mu */

/* The bounded inbound queue (the safety valve — see dcx_abi.h §drain). The
 * caps are far beyond what a polling app ever queues (a 30 ms poll drains
 * thousands of events per second); they exist so an app that STOPS polling
 * cannot grow the process without bound. Sizes chosen so the queue can absorb
 * several seconds of full-rate small messages or hundreds of max-size ones. */
const size_t kDefaultMaxQueueEvents = 65536;
const size_t kDefaultMaxQueueBytes  = 32u * 1024u * 1024u;   /* 32 MiB */

std::deque<PendingEvent> g_queue;   /* guarded by g_mu */
size_t g_queueBytes  = 0;           /* guarded by g_mu */
size_t g_maxQueueEvents = kDefaultMaxQueueEvents;   /* test hook can shrink */
size_t g_maxQueueBytes  = kDefaultMaxQueueBytes;
long long g_dropped = 0;            /* shed since last E_QUEUE_OVERFLOW report */

/* Enqueue under g_mu (the caller holds it). Tail-drop when a cap is hit: the
 * app has stopped polling, so we shed the NEWEST event and count it; the count
 * surfaces as one E_QUEUE_OVERFLOW on the next drain. Never throws (the
 * callback firewall would eat it, but the move itself cannot throw). */
void enqueue_locked(PendingEvent &&ev) {
    const size_t c = ev.cost();
    if (g_queue.size() >= g_maxQueueEvents || g_queueBytes + c > g_maxQueueBytes) {
        ++g_dropped;
        return;
    }
    g_queueBytes += c;
    g_queue.push_back(std::move(ev));
}

/* ====================================================================== *
 *  Callbacks — libdatachannel's threads end HERE
 *
 *  Every body: try { translate id under g_mu, enqueue } catch (...) {}.
 *  Nothing escapes into libdatachannel; nothing reaches the engine. The only
 *  rtc* calls made from a callback are cheap getters/setters on the object the
 *  callback is about (allowed; rtcDelete* is the documented exception and is
 *  never called from here).
 * ====================================================================== */

int peer_handle_for_rtc_locked(int pc) {
    auto it = g_rtcPeerToHandle.find(pc);
    return it == g_rtcPeerToHandle.end() ? 0 : it->second;
}
int chan_handle_for_rtc_locked(int dc) {
    auto it = g_rtcChanToHandle.find(dc);
    return it == g_rtcChanToHandle.end() ? 0 : it->second;
}

void cb_local_description(int pc, const char *sdp, const char *type, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = peer_handle_for_rtc_locked(pc);
        if (!h) return;
        PendingEvent ev;
        ev.type = dcx::E_LOCAL_DESCRIPTION;
        ev.peerId = h;
        ev.hasSdp = true;     ev.sdp = sdp ? sdp : "";
        ev.hasSdpType = true; ev.sdpType = type ? type : "";
        enqueue_locked(std::move(ev));
    } catch (...) { /* rule 2: nothing unwinds into libdatachannel */ }
}

void cb_local_candidate(int pc, const char *cand, const char *mid, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = peer_handle_for_rtc_locked(pc);
        if (!h) return;
        PendingEvent ev;
        ev.type = dcx::E_LOCAL_CANDIDATE;
        ev.peerId = h;
        ev.hasCandidate = true; ev.candidate = cand ? cand : "";
        ev.hasMid = true;       ev.mid = mid ? mid : "";
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

void cb_state_change(int pc, rtcState state, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = peer_handle_for_rtc_locked(pc);
        if (!h) return;
        g_peerLastState[h] = static_cast<int>(state);   /* the shadow getter reads this */
        PendingEvent ev;
        ev.type = dcx::E_STATE_CHANGE;
        ev.peerId = h;
        ev.hasState = true; ev.state = static_cast<int>(state);
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

void cb_gathering_state(int pc, rtcGatheringState state, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = peer_handle_for_rtc_locked(pc);
        if (!h) return;
        g_peerLastGathering[h] = static_cast<int>(state);
        PendingEvent ev;
        ev.type = dcx::E_GATHERING_STATE;
        ev.peerId = h;
        ev.hasState = true; ev.state = static_cast<int>(state);
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

void cb_channel_open(int dc, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = chan_handle_for_rtc_locked(dc);
        if (!h) return;
        ChannelState *cs = g_channels.get(h);
        if (!cs || cs->openAnnounced) return;
        cs->openAnnounced = true;
        PendingEvent ev;
        ev.type = dcx::E_CHANNEL_OPEN;
        ev.peerId = cs->peerHandle;
        ev.channelId = h;
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

void cb_channel_closed(int dc, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = chan_handle_for_rtc_locked(dc);
        if (!h) return;
        ChannelState *cs = g_channels.get(h);
        PendingEvent ev;
        ev.type = dcx::E_CHANNEL_CLOSED;
        ev.peerId = cs ? cs->peerHandle : 0;
        ev.channelId = h;
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

void cb_channel_error(int dc, const char *error, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = chan_handle_for_rtc_locked(dc);
        if (!h) return;
        ChannelState *cs = g_channels.get(h);
        PendingEvent ev;
        ev.type = dcx::E_CHANNEL_ERROR;
        ev.peerId = cs ? cs->peerHandle : 0;
        ev.channelId = h;
        ev.hasError = true; ev.error = error ? error : "";
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

void cb_message(int dc, const char *message, int size, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = chan_handle_for_rtc_locked(dc);
        if (!h) return;
        ChannelState *cs = g_channels.get(h);
        PendingEvent ev;
        ev.peerId = cs ? cs->peerHandle : 0;
        ev.channelId = h;

        /* rtc convention: size >= 0 -> binary of `size` bytes; size < 0 ->
         * NUL-terminated TEXT. Enforce the inbound budget on the WHOLE message
         * (never truncate — a truncated message corrupts a stream); libdata-
         * channel's negotiated maxMessageSize already advertises the cap, so
         * this is defence in depth against a misbehaving remote. */
        size_t n = (size >= 0) ? static_cast<size_t>(size)
                               : (message ? std::strlen(message) : 0);
        if (n > static_cast<size_t>(DCX_MAX_MESSAGE)) {
            ev.type = dcx::E_CHANNEL_ERROR;
            ev.hasError = true;
            ev.error = "oversized inbound message dropped (" +
                       std::to_string(n) + " bytes > " +
                       std::to_string(DCX_MAX_MESSAGE) + ")";
            enqueue_locked(std::move(ev));
            return;
        }

        ev.type = dcx::E_MESSAGE;
        if (size >= 0) {
            ev.hasPayload = true;
            if (message && n) ev.payload.assign(message, message + n);
        } else {
            ev.hasText = true;
            if (message) ev.text.assign(message, n);
        }
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

void cb_buffered_low(int dc, void *) {
    try {
        std::lock_guard<std::mutex> lock(g_mu);
        int h = chan_handle_for_rtc_locked(dc);
        if (!h) return;
        ChannelState *cs = g_channels.get(h);
        PendingEvent ev;
        ev.type = dcx::E_BUFFERED_LOW;
        ev.peerId = cs ? cs->peerHandle : 0;
        ev.channelId = h;
        enqueue_locked(std::move(ev));
    } catch (...) {}
}

/* Register a channel (ours or remote-initiated) in the table + map, announce
 * it if it is remote-initiated, and wire its callbacks. `g_mu` is NOT held by
 * the caller (the rtc* calls inside must run unlocked — the lock discipline).
 * Returns our handle, 0 on table exhaustion. Used from dcx_channel_new/_ex
 * (script thread) AND from cb_data_channel (an rtc thread) — both are safe:
 * the table work is locked, the rtc calls are made lock-free on our side.
 *
 * ORDERING GUARANTEE (pinned by the smoke test): for a remote-initiated
 * channel, E_CHANNEL_INCOMING is enqueued in the SAME locked section that
 * creates the handle — BEFORE the open callback is wired and BEFORE the
 * already-open fallback below — so the app always learns a channel's handle
 * (from INCOMING) before any OPEN/MESSAGE event names it. */
int register_channel(int dcId, int peerHandle, bool announceIncoming,
                     const char *label, const char *protocol) {
    int h = 0;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        ChannelState cs;
        cs.rtcId = dcId;
        cs.peerHandle = peerHandle;
        h = g_channels.alloc(cs);
        if (h == 0) return 0;
        g_rtcChanToHandle[dcId] = h;
        if (announceIncoming) {
            PendingEvent ev;
            ev.type = dcx::E_CHANNEL_INCOMING;
            ev.peerId = peerHandle;
            ev.channelId = h;
            ev.hasLabel = true;    ev.label = label ? label : "";
            ev.hasProtocol = true; ev.protocol = protocol ? protocol : "";
            enqueue_locked(std::move(ev));
        }
    }

    /* Wire the channel callbacks AFTER the mapping exists, so a fired callback
     * always resolves its handle. Setting the message callback flushes any
     * messages libdatachannel buffered before this moment (verified upstream
     * behaviour: Channel::onMessage -> flushPendingMessages), so nothing that
     * arrived in the wiring window is lost. */
    rtcSetOpenCallback(dcId, &cb_channel_open);
    rtcSetClosedCallback(dcId, &cb_channel_closed);
    rtcSetErrorCallback(dcId, &cb_channel_error);
    rtcSetMessageCallback(dcId, &cb_message);
    /* cb_buffered_low is wired on demand by dcx_set_buffered_low_threshold —
     * with the default 0 threshold it would fire on every drain-to-empty,
     * which is per-message noise for a chat-sized app. */

    /* A remote-initiated channel is typically ALREADY open when libdatachannel
     * announces it; the open callback we just wired will then never fire. If
     * so, announce the open ourselves — dedupe via openAnnounced (the callback
     * and this check race benignly under the mutex; exactly one wins). */
    if (rtcIsOpen(dcId)) {
        std::lock_guard<std::mutex> lock(g_mu);
        ChannelState *cs = g_channels.get(h);
        if (cs && !cs->openAnnounced) {
            cs->openAnnounced = true;
            PendingEvent ev;
            ev.type = dcx::E_CHANNEL_OPEN;
            ev.peerId = peerHandle;
            ev.channelId = h;
            enqueue_locked(std::move(ev));
        }
    }
    return h;
}

/* Clear every user callback registered on a channel / peer connection. MUST
 * run (unlocked) before the matching rtcDelete*: libdatachannel's C layer
 * drops the object's LAST reference while holding its own global map mutex,
 * and the destructor can then fire a state callback whose wrapper re-takes
 * that same (non-recursive) mutex — a self-deadlock we reproduced under gdb.
 * With the callbacks cleared there is nothing to fire, and the clearing
 * itself synchronizes with (joins) any invocation already in flight. */
void clear_channel_callbacks(int dcId) {
    rtcSetOpenCallback(dcId, nullptr);
    rtcSetClosedCallback(dcId, nullptr);
    rtcSetErrorCallback(dcId, nullptr);
    rtcSetMessageCallback(dcId, nullptr);
    rtcSetBufferedAmountLowCallback(dcId, nullptr);
}
void clear_peer_callbacks(int pcId) {
    rtcSetLocalDescriptionCallback(pcId, nullptr);
    rtcSetLocalCandidateCallback(pcId, nullptr);
    rtcSetStateChangeCallback(pcId, nullptr);
    rtcSetGatheringStateChangeCallback(pcId, nullptr);
    rtcSetDataChannelCallback(pcId, nullptr);
}

void cb_data_channel(int pc, int dc, void *) {
    /* A REMOTE-initiated channel. Runs on an rtc thread: allocate our handle,
     * announce + wire the channel — queue-only outward, per rule 1. */
    try {
        int peerH = 0;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            peerH = peer_handle_for_rtc_locked(pc);
        }
        if (!peerH) return;

        /* Label/protocol are cheap rtc getters — legal from a callback, and
         * read BEFORE our lock (never call rtc* while holding g_mu). */
        char label[512] = {0};
        char proto[512] = {0};
        int ln = rtcGetDataChannelLabel(dc, label, static_cast<int>(sizeof label));
        int pn = rtcGetDataChannelProtocol(dc, proto, static_cast<int>(sizeof proto));

        /* register_channel enqueues E_CHANNEL_INCOMING atomically with the
         * handle's birth, so INCOMING always precedes this channel's OPEN. */
        register_channel(dc, peerH, /*announceIncoming=*/true,
                         ln > 0 ? label : "", pn > 0 ? proto : "");
    } catch (...) {}
}

/* ====================================================================== *
 *  Script-thread helpers
 * ====================================================================== */

/* Copy a validated peer's rtc id out under the lock. ok=false on a stale
 * handle (the caller then no-ops per the family convention). */
bool peer_rtc_id(int p, int *rtcId) {
    std::lock_guard<std::mutex> lock(g_mu);
    PeerState *ps = g_peers.get(p);
    if (!ps) return false;
    *rtcId = ps->rtcId;
    return true;
}

bool chan_rtc_id(int c, int *rtcId) {
    std::lock_guard<std::mutex> lock(g_mu);
    ChannelState *cs = g_channels.get(c);
    if (!cs) return false;
    *rtcId = cs->rtcId;
    return true;
}

/* Map a negative libdatachannel return to our error space, recording a legible
 * last-error. `what` names the operation for the message. */
int rtc_fail(const char *what, int r) {
    const char *why = "unknown";
    switch (r) {
        case RTC_ERR_INVALID:   why = "invalid argument"; break;
        case RTC_ERR_FAILURE:   why = "runtime failure"; break;
        case RTC_ERR_NOT_AVAIL: why = "not available"; break;
        case RTC_ERR_TOO_SMALL: why = "buffer too small"; break;
        default: break;
    }
    set_error(std::string(what) + ": libdatachannel error " + std::to_string(r) +
              " (" + why + ")");
    return DCX_ERR_NATIVE;
}

/* Fill our out-buffer from a std::string under the bytes-written / -needed
 * convention (no NUL terminator crosses — the LCB side copies exactly n). */
int fill_out(const std::string &s, char *out, int cap) {
    const size_t need = s.size();
    if (out && cap > 0 && need <= static_cast<size_t>(cap))
        std::memcpy(out, s.data(), need);
    if (need > static_cast<size_t>(cap < 0 ? 0 : cap))
        return -static_cast<int>(need);
    return static_cast<int>(need);
}

/* Read one of libdatachannel's NUL-terminated string getters into a
 * std::string, hiding their size-includes-NUL convention. `getter` is called
 * first with NULL to learn the size (their documented probe), then for real.
 * Returns false on a native error (empty result). */
template <typename Getter>
bool read_rtc_string(int id, Getter getter, std::string &out) {
    int need = getter(id, nullptr, 0);   /* their probe: size INCLUDING the NUL */
    if (need <= 0) return false;
    std::vector<char> buf(static_cast<size_t>(need));
    int r = getter(id, buf.data(), need);
    if (r <= 0) return false;
    /* r counts the NUL; the string content is r-1 chars. */
    out.assign(buf.data(), static_cast<size_t>(r - 1));
    return true;
}

/* Split the newline-separated ICE server list ("" -> none). CR tolerated so a
 * Windows-edited field crosses cleanly. Empty lines skipped. */
std::vector<std::string> split_servers(const char *lines) {
    std::vector<std::string> out;
    if (!lines) return out;
    const char *p = lines;
    while (*p) {
        const char *nl = std::strchr(p, '\n');
        size_t n = nl ? static_cast<size_t>(nl - p) : std::strlen(p);
        while (n > 0 && (p[n - 1] == '\r' || p[n - 1] == ' ')) --n;
        size_t skip = 0;
        while (skip < n && p[skip] == ' ') ++skip;
        if (n > skip) out.emplace_back(p + skip, n - skip);
        if (!nl) break;
        p = nl + 1;
    }
    return out;
}

/* One-time global init (idempotent): quiet the logger — libdatachannel logs to
 * stdout if the first rtcInitLogger call passes a NULL callback, which is not
 * ours to pollute — and preload the global state (certificate generation) so
 * the first peer connection does not pay it. */
bool g_inited = false;   /* script thread only */
void ensure_init() {
    if (g_inited) return;
    g_inited = true;
    rtcInitLogger(RTC_LOG_NONE, nullptr);
    rtcPreload();
}

/* ====================================================================== *
 *  Drain serialisation
 * ====================================================================== */

/* Serialise one PendingEvent at the writer's cursor in the EXACT btx_pop_alerts
 * framing: [eventType:u16][bodyLen:u16][kvrecord]. Field order is fixed
 * (peer, channel, then the optionals in registry order) and pinned by the
 * golden test. */
void write_event_entry(dcx::RecordWriter &rw, const PendingEvent &ev) {
    rw.put_u16(ev.type);
    const size_t bodyAt = rw.pos();
    rw.put_u16(0);  /* bodyLen placeholder */
    const size_t bodyStart = rw.pos();
    {
        dcx::KVRecord r(rw);
        r.put_int(dcx::F_DC_PEER, ev.peerId);
        r.put_int(dcx::F_DC_CHANNEL, ev.channelId);
        if (ev.hasSdp)       r.put_str(dcx::F_DC_SDP, ev.sdp);
        if (ev.hasSdpType)   r.put_str(dcx::F_DC_SDP_TYPE, ev.sdpType);
        if (ev.hasCandidate) r.put_str(dcx::F_DC_CANDIDATE, ev.candidate);
        if (ev.hasMid)       r.put_str(dcx::F_DC_MID, ev.mid);
        if (ev.hasState)     r.put_int(dcx::F_DC_STATE, ev.state);
        if (ev.hasLabel)     r.put_str(dcx::F_DC_LABEL, ev.label);
        if (ev.hasProtocol)  r.put_str(dcx::F_DC_PROTOCOL, ev.protocol);
        if (ev.hasPayload)   r.put_bytes(dcx::F_DC_PAYLOAD,
                                         ev.payload.data(), ev.payload.size());
        if (ev.hasText)      r.put_str(dcx::F_DC_TEXT, ev.text);
        if (ev.hasError)     r.put_str(dcx::F_DC_ERROR, ev.error);
        if (ev.hasDropped)   r.put_int(dcx::F_DC_DROPPED, ev.dropped);
        r.finish();
    }
    rw.patch_u16(bodyAt, static_cast<uint16_t>(rw.pos() - bodyStart));
}

/* Exact byte size write_event_entry would produce (a zero-capacity writer
 * measures without copying — the RecordWriter contract). */
size_t measure_event_entry(const PendingEvent &ev) {
    dcx::RecordWriter probe(nullptr, 0);
    write_event_entry(probe, ev);
    return probe.pos();
}

/* Is this queued event still deliverable? An event that names a freed handle
 * is dropped at drain time — the app freed the peer/channel, so it declared
 * it no longer cares (the stale-id-is-a-no-op rule, applied to events).
 * Overflow reports carry no handles and always deliver. Caller holds g_mu. */
bool event_deliverable_locked(const PendingEvent &ev) {
    if (ev.type == dcx::E_QUEUE_OVERFLOW) return true;
    if (ev.peerId != 0 && g_peers.get(ev.peerId) == nullptr) return false;
    if (ev.channelId != 0 && g_channels.get(ev.channelId) == nullptr) return false;
    return true;
}

}  // namespace

/* ====================================================================== *
 *  The exception firewall (rule 2) — same macros as the sibling bindings
 *
 *  Implemented as an immediately-invoked lambda so an early `return` inside
 *  the body returns from the wrapped region; the catch lives outside it, so
 *  nothing can escape. The uniform macro is why a future handler physically
 *  cannot forget the firewall: it is part of the entry-point shape.
 * ====================================================================== */

/* Action functions: return an int (DCX_OK / DCX_ERR_*). On a throw, return
 * DCX_ERR_EXCEPTION. */
#define DCX_GUARD_ACTION(BODY)                                                  \
    try {                                                                       \
        return [&]() -> int BODY ();                                            \
    } catch (const std::exception &e) {                                         \
        set_error(std::string("native exception: ") + e.what());                \
        return DCX_ERR_EXCEPTION;                                               \
    } catch (...) {                                                             \
        set_error("unknown native exception crossed the shim");                 \
        return DCX_ERR_EXCEPTION;                                               \
    }

/* Buffer-filling getters: bytes-written / -needed / 0. A throw collapses to 0
 * (a harmless empty result — never a small negative that could be confused
 * with a -needed value). */
#define DCX_GUARD_BUFFER(BODY)                                                  \
    try {                                                                       \
        return [&]() -> int BODY ();                                            \
    } catch (const std::exception &e) {                                         \
        set_error(std::string("native exception: ") + e.what());                \
        return 0;                                                               \
    } catch (...) {                                                             \
        set_error("unknown native exception crossed the shim");                 \
        return 0;                                                               \
    }

/* Plain int getters (counts, handles, states). A throw collapses to `FAIL`
 * (0 for handle-getters, -1 for the state getters whose 0 is a real value). */
#define DCX_GUARD_INT(FAIL, BODY)                                               \
    try {                                                                       \
        return [&]() -> int BODY ();                                            \
    } catch (const std::exception &e) {                                         \
        set_error(std::string("native exception: ") + e.what());                \
        return (FAIL);                                                          \
    } catch (...) {                                                             \
        set_error("unknown native exception crossed the shim");                 \
        return (FAIL);                                                          \
    }

/* void entry points. A throw is swallowed (recorded) so nothing crosses. */
#define DCX_GUARD_VOID(BODY)                                                    \
    try {                                                                       \
        [&]() -> void BODY ();                                                  \
    } catch (const std::exception &e) {                                         \
        set_error(std::string("native exception: ") + e.what());                \
    } catch (...) {                                                             \
        set_error("unknown native exception crossed the shim");                 \
    }

/* ====================================================================== *
 *  Lifecycle & diagnostics
 * ====================================================================== */

extern "C" DCX_API int DCX_CALL dcx_abi_version(void) {
    DCX_GUARD_INT(0, { return DCX_ABI_VERSION; });
}

extern "C" DCX_API int DCX_CALL dcx_init(void) {
    DCX_GUARD_ACTION({
        ensure_init();
        return DCX_OK;
    });
}

extern "C" DCX_API int DCX_CALL dcx_cleanup(void) {
    DCX_GUARD_ACTION({
        /* Snapshot every live rtc id, clear OUR world under the lock, then do
         * the blocking teardown UNLOCKED — rtcDelete and rtcCleanup wait for
         * in-flight callbacks, which need g_mu to finish (the lock rule).
         * One declaration per line: a top-level comma inside a guard-macro
         * body splits the macro's arguments (the documented macro-comma trap). */
        std::vector<int> chanIds;
        std::vector<int> peerIds;
        std::vector<int> hs;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            hs.clear();
            g_channels.collect_live(hs);
            for (int h : hs) {
                ChannelState *cs = g_channels.get(h);
                if (cs) chanIds.push_back(cs->rtcId);
            }
            for (int h : hs) g_channels.free(h);
            hs.clear();
            g_peers.collect_live(hs);
            for (int h : hs) {
                PeerState *ps = g_peers.get(h);
                if (ps) peerIds.push_back(ps->rtcId);
            }
            for (int h : hs) g_peers.free(h);
            g_rtcChanToHandle.clear();
            g_rtcPeerToHandle.clear();
            g_peerLastState.clear();
            g_peerLastGathering.clear();
            g_queue.clear();
            g_queueBytes = 0;
            g_dropped = 0;
        }
        /* Clear every callback BEFORE any delete (the capi self-deadlock
         * guard — see clear_peer_callbacks), then tear down channels, then
         * connections, then the global machinery. */
        for (int id : peerIds) clear_peer_callbacks(id);
        for (int id : chanIds) clear_channel_callbacks(id);
        for (int id : chanIds) rtcDeleteDataChannel(id);
        for (int id : peerIds) rtcDeletePeerConnection(id);
        /* Erases any stragglers and joins libdatachannel's global machinery
         * (bounded internally at ~10 s; logged, never thrown, upstream). */
        rtcCleanup();
        return DCX_OK;
    });
}

/* The version-pin conditional lives in this plain helper, NOT inside the
 * guard body below: a preprocessor directive inside a macro ARGUMENT is
 * undefined behaviour the standard never promised — gcc tolerates it, MSVC
 * rejects it outright (C2121 "'#': invalid character"), which is exactly how
 * the first-ever Windows build failed. Keep every #if out of DCX_GUARD_*
 * bodies. */
static const std::string &library_version_string() {
#ifdef DCX_LIBDATACHANNEL_VERSION
    static const std::string v = std::string("libdatachannel ") + DCX_LIBDATACHANNEL_VERSION;
#else
    static const std::string v = "libdatachannel (unpinned build)";
#endif
    return v;
}

extern "C" DCX_API int DCX_CALL dcx_library_version(char *out, int cap) {
    DCX_GUARD_BUFFER({ return fill_out(library_version_string(), out, cap); });
}

extern "C" DCX_API int DCX_CALL dcx_last_error(char *out, int cap) {
    DCX_GUARD_BUFFER({ return fill_out(g_last_error, out, cap); });
}

extern "C" DCX_API void DCX_CALL dcx_clear_error(void) {
    DCX_GUARD_VOID({ g_last_error.clear(); });
}

/* ====================================================================== *
 *  Peer connections
 * ====================================================================== */

extern "C" DCX_API int DCX_CALL dcx_peer_new(const char *iceServersLines) {
    DCX_GUARD_INT(0, {
        ensure_init();

        std::vector<std::string> servers = split_servers(iceServersLines);
        std::vector<const char *> ptrs;
        ptrs.reserve(servers.size());
        for (const std::string &s : servers) ptrs.push_back(s.c_str());

        rtcConfiguration cfg = {};   /* zero-init: sane libdatachannel defaults */
        cfg.iceServers = ptrs.empty() ? nullptr : ptrs.data();
        cfg.iceServersCount = static_cast<int>(ptrs.size());
        /* Advertise our message budget in the SCTP negotiation, so a compliant
         * remote never sends what we would have to drop (dcx_abi.h). */
        cfg.maxMessageSize = DCX_MAX_MESSAGE;

        int pc = rtcCreatePeerConnection(&cfg);
        if (pc < 0) { rtc_fail("dcx_peer_new", pc); return 0; }

        int h = 0;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            PeerState ps;
            ps.rtcId = pc;
            h = g_peers.alloc(ps);
            if (h != 0) g_rtcPeerToHandle[pc] = h;
        }
        if (h == 0) {
            rtcDeletePeerConnection(pc);
            set_error("peer handle table exhausted");
            return 0;
        }

        /* Wire the peer callbacks AFTER the mapping exists (a fired callback
         * always resolves) and OUTSIDE the lock (the lock discipline). No
         * event can be missed in between: callbacks start firing only once
         * each setter installs them. */
        rtcSetLocalDescriptionCallback(pc, &cb_local_description);
        rtcSetLocalCandidateCallback(pc, &cb_local_candidate);
        rtcSetStateChangeCallback(pc, &cb_state_change);
        rtcSetGatheringStateChangeCallback(pc, &cb_gathering_state);
        rtcSetDataChannelCallback(pc, &cb_data_channel);
        return h;
    });
}

extern "C" DCX_API int DCX_CALL dcx_peer_close(int p) {
    DCX_GUARD_ACTION({
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) { set_error("stale peer handle"); return DCX_ERR_BAD_HANDLE; }
        int r = rtcClosePeerConnection(pc);
        if (r < 0) return rtc_fail("dcx_peer_close", r);
        return DCX_OK;
    });
}

extern "C" DCX_API void DCX_CALL dcx_peer_free(int p) {
    DCX_GUARD_VOID({
        /* Free OUR world under the lock (peer + its channels + maps), then do
         * the blocking rtcDelete* teardown UNLOCKED. Idempotent: a stale
         * handle finds nothing and does nothing. */
        std::vector<int> chanIds;
        int pc = 0;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            PeerState *ps = g_peers.get(p);
            if (!ps) return;
            pc = ps->rtcId;

            std::vector<int> hs;
            g_channels.collect_live(hs);
            for (int h : hs) {
                ChannelState *cs = g_channels.get(h);
                if (cs && cs->peerHandle == p) {
                    chanIds.push_back(cs->rtcId);
                    g_rtcChanToHandle.erase(cs->rtcId);
                    g_channels.free(h);
                }
            }
            g_rtcPeerToHandle.erase(pc);
            g_peerLastState.erase(p);
            g_peerLastGathering.erase(p);
            g_peers.free(p);
        }
        /* Clear the callbacks BEFORE deleting (the capi self-deadlock guard —
         * see clear_peer_callbacks), then channels first, then the connection.
         * The deletes block until in-flight callbacks return — which they
         * can, since g_mu is free. */
        clear_peer_callbacks(pc);
        for (int id : chanIds) {
            clear_channel_callbacks(id);
            rtcDeleteDataChannel(id);
        }
        rtcDeletePeerConnection(pc);
    });
}

extern "C" DCX_API int DCX_CALL dcx_set_local_description(int p, const char *type) {
    DCX_GUARD_ACTION({
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) { set_error("stale peer handle"); return DCX_ERR_BAD_HANDLE; }
        /* "" -> NULL: let libdatachannel pick offer/answer from signaling state. */
        int r = rtcSetLocalDescription(pc, (type && *type) ? type : nullptr);
        if (r < 0) return rtc_fail("dcx_set_local_description", r);
        return DCX_OK;
    });
}

extern "C" DCX_API int DCX_CALL dcx_set_remote_description(int p, const char *sdp,
                                                           const char *type) {
    DCX_GUARD_ACTION({
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) { set_error("stale peer handle"); return DCX_ERR_BAD_HANDLE; }
        if (!sdp || !*sdp) { set_error("empty remote description"); return DCX_ERR_INVALID_ARG; }
        int r = rtcSetRemoteDescription(pc, sdp, (type && *type) ? type : nullptr);
        if (r < 0) return rtc_fail("dcx_set_remote_description", r);
        return DCX_OK;
    });
}

extern "C" DCX_API int DCX_CALL dcx_add_remote_candidate(int p, const char *cand,
                                                         const char *mid) {
    DCX_GUARD_ACTION({
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) { set_error("stale peer handle"); return DCX_ERR_BAD_HANDLE; }
        if (!cand || !*cand) { set_error("empty remote candidate"); return DCX_ERR_INVALID_ARG; }
        int r = rtcAddRemoteCandidate(pc, cand, (mid && *mid) ? mid : nullptr);
        if (r < 0) return rtc_fail("dcx_add_remote_candidate", r);
        return DCX_OK;
    });
}

extern "C" DCX_API int DCX_CALL dcx_local_description(int p, char *out, int cap) {
    DCX_GUARD_BUFFER({
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) return 0;
        std::string s;
        if (!read_rtc_string(pc, &rtcGetLocalDescription, s)) return 0;
        return fill_out(s, out, cap);
    });
}

extern "C" DCX_API int DCX_CALL dcx_local_description_type(int p, char *out, int cap) {
    DCX_GUARD_BUFFER({
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) return 0;
        std::string s;
        if (!read_rtc_string(pc, &rtcGetLocalDescriptionType, s)) return 0;
        return fill_out(s, out, cap);
    });
}

extern "C" DCX_API int DCX_CALL dcx_peer_state(int p) {
    /* -1 on a bad handle: state 0 (new) is a real value (the getter--1 rule).
     * Answered from the callback-maintained shadow (libdatachannel's C API has
     * no synchronous state getter); PS_NEW until the first callback fires. */
    DCX_GUARD_INT(-1, {
        std::lock_guard<std::mutex> lock(g_mu);
        PeerState *ps = g_peers.get(p);
        if (!ps) return -1;
        return g_peerLastState.count(p) ? g_peerLastState[p] : dcx::PS_NEW;
    });
}

extern "C" DCX_API int DCX_CALL dcx_gathering_state(int p) {
    DCX_GUARD_INT(-1, {
        std::lock_guard<std::mutex> lock(g_mu);
        PeerState *ps = g_peers.get(p);
        if (!ps) return -1;
        return g_peerLastGathering.count(p) ? g_peerLastGathering[p] : dcx::GS_NEW;
    });
}

extern "C" DCX_API int DCX_CALL dcx_selected_candidate_pair(int p, void *out, int cap) {
    DCX_GUARD_BUFFER({
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) return 0;
        char local[1024] = {0};
        char remote[1024] = {0};
        int r = rtcGetSelectedCandidatePair(pc, local, static_cast<int>(sizeof local),
                                            remote, static_cast<int>(sizeof remote));
        if (r < 0) return 0;   /* none selected yet (or too small — cands are short) */
        dcx::RecordWriter w(out, cap);
        {
            dcx::KVRecord rec(w);
            rec.put_str(dcx::F_DC_LOCAL_CAND, local);
            rec.put_str(dcx::F_DC_REMOTE_CAND, remote);
            rec.finish();
        }
        if (w.overflow()) return -static_cast<int>(w.pos());
        return static_cast<int>(w.pos());
    });
}

/* ====================================================================== *
 *  Data channels
 * ====================================================================== */

extern "C" DCX_API int DCX_CALL dcx_channel_new(int p, const char *label) {
    DCX_GUARD_INT(0, {
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) { set_error("stale peer handle"); return 0; }
        if (!label) label = "";
        int dc = rtcCreateDataChannel(pc, label);
        if (dc < 0) { rtc_fail("dcx_channel_new", dc); return 0; }
        int h = register_channel(dc, p, /*announceIncoming=*/false, "", "");
        if (h == 0) {
            rtcDeleteDataChannel(dc);
            set_error("channel handle table exhausted");
            return 0;
        }
        return h;
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_new_ex(int p, const char *label,
                                                   const char *protocol, int unordered,
                                                   int maxRetransmits, int maxLifetimeMs,
                                                   int negotiated, int streamId) {
    DCX_GUARD_INT(0, {
        int pc = 0;
        if (!peer_rtc_id(p, &pc)) { set_error("stale peer handle"); return 0; }
        if (!label) label = "";
        if (maxRetransmits >= 0 && maxLifetimeMs >= 0) {
            set_error("set at most one of maxRetransmits / maxLifetimeMs");
            return 0;
        }
        if (streamId > 65534) {
            set_error("streamId out of range (0..65534)");
            return 0;
        }

        rtcDataChannelInit init = {};
        init.reliability.unordered = (unordered != 0);
        if (maxRetransmits >= 0) {
            init.reliability.unreliable = true;
            init.reliability.maxRetransmits = static_cast<unsigned int>(maxRetransmits);
        }
        if (maxLifetimeMs >= 0) {
            init.reliability.unreliable = true;
            init.reliability.maxPacketLifeTime = static_cast<unsigned int>(maxLifetimeMs);
        }
        init.protocol = (protocol && *protocol) ? protocol : nullptr;
        init.negotiated = (negotiated != 0);
        if (streamId >= 0) {
            init.manualStream = true;
            init.stream = static_cast<uint16_t>(streamId);
        }

        int dc = rtcCreateDataChannelEx(pc, label, &init);
        if (dc < 0) { rtc_fail("dcx_channel_new_ex", dc); return 0; }
        int h = register_channel(dc, p, /*announceIncoming=*/false, "", "");
        if (h == 0) {
            rtcDeleteDataChannel(dc);
            set_error("channel handle table exhausted");
            return 0;
        }
        return h;
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_close(int c) {
    DCX_GUARD_ACTION({
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) { set_error("stale channel handle"); return DCX_ERR_BAD_HANDLE; }
        int r = rtcClose(dc);
        if (r < 0) return rtc_fail("dcx_channel_close", r);
        return DCX_OK;
    });
}

extern "C" DCX_API void DCX_CALL dcx_channel_free(int c) {
    DCX_GUARD_VOID({
        int dc = 0;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            ChannelState *cs = g_channels.get(c);
            if (!cs) return;
            dc = cs->rtcId;
            g_rtcChanToHandle.erase(dc);
            g_channels.free(c);
        }
        clear_channel_callbacks(dc);   /* the capi self-deadlock guard */
        rtcDeleteDataChannel(dc);      /* blocks for in-flight callbacks; g_mu free */
    });
}

extern "C" DCX_API int DCX_CALL dcx_send_data(int c, const void *data, int len) {
    DCX_GUARD_ACTION({
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) { set_error("stale channel handle"); return DCX_ERR_BAD_HANDLE; }
        if (len < 0 || (len > 0 && !data)) { set_error("bad send buffer"); return DCX_ERR_INVALID_ARG; }
        if (len > DCX_MAX_MESSAGE) {
            set_error("message exceeds DCX_MAX_MESSAGE (" +
                      std::to_string(DCX_MAX_MESSAGE) + " bytes); chunk it, or move bulk via TorrentXT");
            return DCX_ERR_TOO_LARGE;
        }
        int r = rtcSendMessage(dc, static_cast<const char *>(data), len);
        if (r < 0) return rtc_fail("dcx_send_data", r);
        return DCX_OK;
    });
}

extern "C" DCX_API int DCX_CALL dcx_send_text(int c, const char *text) {
    DCX_GUARD_ACTION({
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) { set_error("stale channel handle"); return DCX_ERR_BAD_HANDLE; }
        if (!text) { set_error("null text"); return DCX_ERR_INVALID_ARG; }
        size_t n = std::strlen(text);
        if (n > static_cast<size_t>(DCX_MAX_MESSAGE)) {
            set_error("message exceeds DCX_MAX_MESSAGE (" +
                      std::to_string(DCX_MAX_MESSAGE) + " bytes); chunk it, or move bulk via TorrentXT");
            return DCX_ERR_TOO_LARGE;
        }
        /* size -1 == libdatachannel's "NUL-terminated TEXT message" spelling. */
        int r = rtcSendMessage(dc, text, -1);
        if (r < 0) return rtc_fail("dcx_send_text", r);
        return DCX_OK;
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_label(int c, char *out, int cap) {
    DCX_GUARD_BUFFER({
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) return 0;
        std::string s;
        if (!read_rtc_string(dc, &rtcGetDataChannelLabel, s)) return 0;
        return fill_out(s, out, cap);
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_protocol(int c, char *out, int cap) {
    DCX_GUARD_BUFFER({
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) return 0;
        std::string s;
        if (!read_rtc_string(dc, &rtcGetDataChannelProtocol, s)) return 0;
        return fill_out(s, out, cap);
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_stream_id(int c) {
    DCX_GUARD_INT(-1, {
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) return -1;
        int r = rtcGetDataChannelStream(dc);
        return (r < 0) ? -1 : r;   /* stream 0 is valid; -1 is "no value" */
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_is_open(int c) {
    DCX_GUARD_INT(0, {
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) return 0;
        return rtcIsOpen(dc) ? 1 : 0;
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_peer(int c) {
    DCX_GUARD_INT(0, {
        std::lock_guard<std::mutex> lock(g_mu);
        ChannelState *cs = g_channels.get(c);
        return cs ? cs->peerHandle : 0;
    });
}

extern "C" DCX_API int DCX_CALL dcx_channel_max_message(int c) {
    DCX_GUARD_INT(-1, {
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) return -1;
        int r = rtcMaxMessageSize(dc);
        return (r < 0) ? -1 : r;
    });
}

extern "C" DCX_API int DCX_CALL dcx_buffered_amount(int c) {
    DCX_GUARD_INT(-1, {
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) return -1;
        int r = rtcGetBufferedAmount(dc);
        return (r < 0) ? -1 : r;
    });
}

extern "C" DCX_API int DCX_CALL dcx_set_buffered_low_threshold(int c, int amount) {
    DCX_GUARD_ACTION({
        int dc = 0;
        if (!chan_rtc_id(c, &dc)) { set_error("stale channel handle"); return DCX_ERR_BAD_HANDLE; }
        if (amount < 0) { set_error("negative threshold"); return DCX_ERR_INVALID_ARG; }
        int r = rtcSetBufferedAmountLowThreshold(dc, amount);
        if (r < 0) return rtc_fail("dcx_set_buffered_low_threshold", r);
        /* The E_BUFFERED_LOW callback is wired on first demand (not at channel
         * creation) so apps that never ask for backpressure never see the
         * per-message noise a 0 threshold would generate. */
        r = rtcSetBufferedAmountLowCallback(dc, &cb_buffered_low);
        if (r < 0) return rtc_fail("dcx_set_buffered_low_threshold(callback)", r);
        return DCX_OK;
    });
}

/* ====================================================================== *
 *  The event drain
 * ====================================================================== */

extern "C" DCX_API int DCX_CALL dcx_poll(void *out, int cap) {
    DCX_GUARD_INT(0, {
        std::lock_guard<std::mutex> lock(g_mu);

        dcx::RecordWriter w(out, cap);
        const size_t countAt = w.pos();
        w.put_u16(0);   /* eventCount placeholder, backpatched below */
        uint16_t written = 0;

        /* Drain in FIFO order. Undeliverable events (freed handles) are
         * discarded as met; the first event that does not fit ends the pass —
         * everything behind it simply stays queued, order preserved. */
        while (!g_queue.empty()) {
            PendingEvent &front = g_queue.front();
            if (!event_deliverable_locked(front)) {
                g_queueBytes -= front.cost();
                g_queue.pop_front();
                continue;
            }
            const size_t need = measure_event_entry(front);
            if (w.pos() + need > w.capacity()) break;
            write_event_entry(w, front);
            ++written;
            g_queueBytes -= front.cost();
            g_queue.pop_front();
        }

        /* The overflow report rides LAST — it describes events that were shed
         * from the TAIL, so it belongs after everything that survived. It only
         * reports (and resets) once the backlog is fully drained. */
        if (g_queue.empty() && g_dropped > 0) {
            PendingEvent ov;
            ov.type = dcx::E_QUEUE_OVERFLOW;
            ov.hasDropped = true;
            ov.dropped = g_dropped;
            const size_t need = measure_event_entry(ov);
            if (w.pos() + need <= w.capacity()) {
                write_event_entry(w, ov);
                ++written;
                g_dropped = 0;
            } else if (written == 0) {
                return -static_cast<int>(2 + need);   /* grow-and-retry signal */
            }
        }

        w.patch_u16(countAt, written);

        if (written == 0 && !g_queue.empty()) {
            /* Even the first pending event did not fit: report the TRUE need
             * (prefix + entry) so the caller grows and makes progress. */
            return -static_cast<int>(2 + measure_event_entry(g_queue.front()));
        }
        return written;
    });
}

/* ====================================================================== *
 *  Test hooks (dcx::test) — NOT part of the FFI; see datachannel_shim.h
 * ====================================================================== */

namespace dcx {
namespace test {

DCX_API int force_throw(void) {
    /* Route a guaranteed throw through the SAME macro the real entry points
     * use, so this tests the production firewall, not a bespoke catch. */
    DCX_GUARD_ACTION({
        throw std::runtime_error("deliberate test throw");
    });
}

DCX_API int live_peer_count(void) {
    std::lock_guard<std::mutex> lock(g_mu);
    return static_cast<int>(g_peers.live_count());
}

DCX_API int live_channel_count(void) {
    std::lock_guard<std::mutex> lock(g_mu);
    return static_cast<int>(g_channels.live_count());
}

DCX_API int queue_depth(void) {
    std::lock_guard<std::mutex> lock(g_mu);
    return static_cast<int>(g_queue.size());
}

DCX_API long long dropped_count(void) {
    std::lock_guard<std::mutex> lock(g_mu);
    return g_dropped;
}

DCX_API void set_queue_caps(int maxEvents, long long maxBytes) {
    std::lock_guard<std::mutex> lock(g_mu);
    g_maxQueueEvents = (maxEvents > 0) ? static_cast<size_t>(maxEvents)
                                       : kDefaultMaxQueueEvents;
    g_maxQueueBytes  = (maxBytes > 0) ? static_cast<size_t>(maxBytes)
                                      : kDefaultMaxQueueBytes;
}

}  // namespace test
}  // namespace dcx
