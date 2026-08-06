/* dcx_abi.h — DataChannelXT C ABI contract (the locked, versioned surface).
 *
 * This is the heart of the binding (NEXT-EXTENSIONS-PLAN Part IV). The shim
 * (datachannel_shim.cpp) IMPLEMENTS every symbol here; the LCB binding
 * (datachannel.lcb) declares one `private foreign handler` per symbol that
 * `binds to "c:datachannelxt>dcx_*"`. Both sides must agree byte-for-byte on
 * these signatures, so this header is the single source of truth and is
 * treated as a frozen contract:
 *
 *   - NEVER rename an exported `dcx_*` symbol (compiled .lcb binaries reference
 *     the strings; a rename silently breaks the binding at first use).
 *   - Any change to the exported surface (new symbol, changed signature, new
 *     record field, new event code) BUMPS DCX_ABI_VERSION below, and the LCB
 *     `checkABI()` throws a clear error on skew instead of crashing later.
 *
 * Deliberately pure C so the contract is unambiguous and the header is usable
 * from either a C or C++ translation unit (the shim is C++; this stays C-clean).
 *
 * Type conventions across the FFI, carried from TorrentXT/Box2Dxt/ShowControl:
 *   real number ............ double        (none in this surface yet)
 *   integer / handle ....... int32_t  (handles are POSITIVE; 0 == invalid)
 *   boolean ................ int       (0/1)
 *   byte buffer ............ const void* / void* + int length
 *   short string ........... const char* (UTF-8, NUL-terminated; the LCB
 *                            `ZStringUTF8` bridge), never a length-counted blob
 *   64-bit value ........... decimal ASCII string (there is NO 64-bit foreign
 *                            int; nothing in Phase 1 needs one)
 *
 * Out-buffer convention: a function that fills a caller-owned buffer returns
 * the number of bytes written (>= 0) on success, or the NEGATIVE of the
 * capacity it needed when the supplied buffer was too small (so the caller can
 * grow and retry). A call on a stale/invalid handle is a harmless no-op that
 * returns 0 (empty) — never a crash, never a small negative that could be
 * confused with a -needed value.
 *
 * THE THREADING CONTRACT (the one that matters — plan Part IV.2). libdatachannel
 * runs its own threads and fires callbacks FROM them. Inside the shim, every
 * callback does exactly one thing: lock the state mutex, push a typed event
 * (handle IDS + owned copies of the payload) onto a bounded queue, unlock.
 * dcx_poll — called from the engine's ONE script thread on a timer — drains
 * that queue as a record list. No callback ever reaches script; no engine
 * function is ever called off-thread. Everything here is therefore safe to
 * call ONLY from the script thread; the shim's mutex protects it from the
 * callback threads, not from concurrent script threads (OXT has one).
 */
#ifndef DCX_ABI_H
#define DCX_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ version */

/* Bump on ANY change to the exported ABI: a new/removed symbol, a changed
 * signature, a new record fieldId or event code, or a framing change. The LCB
 * layer hard-codes the matching number in checkABI() and refuses to run on
 * skew. Start at 1. */
#define DCX_ABI_VERSION 1

/* ----------------------------------------------------------- export linkage */

/* One shared library, exported `dcx_*` symbols, cdecl (the .lcb binds with the
 * "!cdecl" suffix; on the non-Windows targets cdecl is the only convention, so
 * DCX_CALL is empty there). */
#if defined(_WIN32)
#  define DCX_API  __declspec(dllexport)
#  define DCX_CALL __cdecl
#else
#  define DCX_API  __attribute__((visibility("default")))
#  define DCX_CALL
#endif

/* ------------------------------------------------------------- return codes */

/* Returned by ACTION entry points (control / setters): 0 == ok, negative ==
 * failure. The buffer-filling getters do NOT use these; they follow the
 * out-buffer convention documented in the file header. Keeping the two
 * conventions in separate function families means a small -needed can never be
 * mistaken for an error code. DCX_ERR_EXCEPTION deliberately shares TorrentXT's
 * -6 so "the firewall caught a native throw" reads the same across the family. */
enum {
    DCX_OK              = 0,
    DCX_ERR_GENERIC     = -1,  /* unclassified failure; see dcx_last_error     */
    DCX_ERR_BAD_HANDLE  = -2,  /* peer/channel handle not live                 */
    DCX_ERR_INVALID_ARG = -3,  /* a null/empty/out-of-range argument           */
    DCX_ERR_TOO_LARGE   = -4,  /* message exceeds the DCX_MAX_MESSAGE budget   */
    DCX_ERR_NATIVE      = -5,  /* libdatachannel returned an error (see last-error) */
    DCX_ERR_EXCEPTION   = -6   /* the firewall caught a native throw           */
};

/* The per-message size budget, enforced BOTH ways (plan Part IV.5 "keep the
 * control plane small; route bulk to TorrentXT"):
 *   - outbound: dcx_send_data / dcx_send_text refuse a larger message with
 *     DCX_ERR_TOO_LARGE (nothing is truncated or split silently);
 *   - inbound: the shim configures libdatachannel's maxMessageSize to this
 *     value, so the negotiated SCTP limit advertises it to the remote; a
 *     misbehaving remote's oversized message is dropped WHOLE with an
 *     E_CHANNEL_ERROR event (never truncated — truncation corrupts a stream).
 * Chosen so one message + its record framing always fits the u16 field-length
 * limit of the KV codec with room to spare. */
#define DCX_MAX_MESSAGE 60000

/* ====================================================================== *
 *  Lifecycle & diagnostics
 * ====================================================================== */

/* Returns DCX_ABI_VERSION. The very first call the LCB layer makes; proves the
 * whole FFI round-trip with one symbol. */
DCX_API int DCX_CALL dcx_abi_version(void);

/* Global init: quiets libdatachannel's logger and warms its global state.
 * Idempotent; called implicitly by dcx_peer_new, so apps may skip it. Returns
 * DCX_OK / negative. */
DCX_API int DCX_CALL dcx_init(void);

/* Global teardown: closes and frees EVERY live peer connection and channel,
 * then asks libdatachannel to clean up (rtcCleanup joins its background
 * threads once outstanding callbacks finish) and clears the event queue.
 * Idempotent. There is no deterministic LCB unload hook, so the app MUST call
 * this (e.g. on closeStack); skipping it leaks the native threads at quit —
 * the documented failure mode. After cleanup, dcx_peer_new works again. */
DCX_API int DCX_CALL dcx_cleanup(void);

/* Fill `out` with a static diagnostics string naming the pinned libdatachannel
 * this binary was built from (e.g. "libdatachannel v0.24.5"). bytes-written /
 * -needed. */
DCX_API int DCX_CALL dcx_library_version(char *out, int cap);

/* Fill `out` with the module-static last-error string (UTF-8). Returns bytes
 * written, or -needed if `cap` is too small. Empty when there is no error. */
DCX_API int DCX_CALL dcx_last_error(char *out, int cap);

/* Clear the module-static last-error string. */
DCX_API void DCX_CALL dcx_clear_error(void);

/* ====================================================================== *
 *  Peer connections
 * ====================================================================== */

/* Create a peer connection. `iceServersLines` is a newline-separated list of
 * ICE server URIs ("" for none — host candidates only, fine on a LAN or in a
 * loopback test):
 *
 *     stun:stun.example.com:3478
 *     turn:user:pass@turn.example.com:3478?transport=udp
 *
 * (TURN credentials ride inside the URI, libdatachannel's own format. They are
 * secrets in ordinary memory — same caveat as every scripting-level secret.)
 * Returns a positive peer handle, or 0 on failure (see dcx_last_error).
 *
 * Auto-negotiation is ON: creating the first channel makes the offer, and
 * setting a remote offer makes the answer — both surface as E_LOCAL_DESCRIPTION
 * events to ship to the far side. You only call dcx_set_local_description for
 * manual renegotiation. */
DCX_API int DCX_CALL dcx_peer_new(const char *iceServersLines);

/* Politely close the connection (fires state events; channels close). The
 * handle stays valid for inspection until dcx_peer_free. */
DCX_API int DCX_CALL dcx_peer_close(int p);

/* Close AND destroy: frees the peer, all its channels, and their handles.
 * Idempotent; a stale handle is a harmless no-op. Events already queued for
 * these handles still drain (their ids simply no longer resolve — by design). */
DCX_API void DCX_CALL dcx_peer_free(int p);

/* Manual negotiation only (auto-negotiation normally does this): set the local
 * description. `type` is "offer" / "answer" / "" (auto). The resulting SDP
 * arrives as an E_LOCAL_DESCRIPTION event. */
DCX_API int DCX_CALL dcx_set_local_description(int p, const char *type);

/* Apply the REMOTE side's description received over your signaling channel.
 * `type` is "offer" or "answer". With auto-negotiation, applying an offer
 * emits our answer as an E_LOCAL_DESCRIPTION event. */
DCX_API int DCX_CALL dcx_set_remote_description(int p, const char *sdp,
                                                const char *type);

/* Apply one REMOTE ICE candidate received over your signaling channel. `mid`
 * may be "" (libdatachannel resolves it). */
DCX_API int DCX_CALL dcx_add_remote_candidate(int p, const char *cand,
                                              const char *mid);

/* The current local description / its type ("offer"/"answer"), if set.
 * bytes-written / -needed / 0 (no description yet or bad handle). */
DCX_API int DCX_CALL dcx_local_description(int p, char *out, int cap);
DCX_API int DCX_CALL dcx_local_description_type(int p, char *out, int cap);

/* Connection state (PS_*: 0 new, 1 connecting, 2 connected, 3 disconnected,
 * 4 failed, 5 closed) and ICE gathering state (GS_*: 0 new, 1 in progress,
 * 2 complete). Return -1 on a bad handle — 0 is itself a valid state, so this
 * is the documented int-getter that uses -1 for "no value" (the family's
 * getter--1 caveat). */
DCX_API int DCX_CALL dcx_peer_state(int p);
DCX_API int DCX_CALL dcx_gathering_state(int p);

/* Once connected: the selected ICE candidate pair as ONE kv record
 * {F_DC_LOCAL_CAND, F_DC_REMOTE_CAND} — shows whether the path is direct
 * (host/srflx) or relayed (relay). bytes-written / -needed / 0. */
DCX_API int DCX_CALL dcx_selected_candidate_pair(int p, void *out, int cap);

/* ====================================================================== *
 *  Data channels
 * ====================================================================== */

/* Create an outgoing data channel (reliable + ordered, the default). With
 * auto-negotiation, the FIRST channel triggers the offer. Returns a positive
 * channel handle, or 0 on failure. The channel is NOT usable until its
 * E_CHANNEL_OPEN event arrives. */
DCX_API int DCX_CALL dcx_channel_new(int p, const char *label);

/* Create a channel with explicit reliability/negotiation options — the
 * real-time half of WebRTC data channels:
 *   protocol        subprotocol string ("" for none)
 *   unordered       != 0: out-of-order delivery allowed
 *   maxRetransmits  >= 0: at most N retransmissions (unreliable); -1 = unset
 *   maxLifetimeMs   >= 0: retransmit for at most N ms (unreliable); -1 = unset
 *   (set at most ONE of maxRetransmits / maxLifetimeMs)
 *   negotiated      != 0: channel is negotiated out-of-band — BOTH sides must
 *                   create it with the SAME streamId, and no in-band open
 *                   handshake is sent
 *   streamId        explicit SCTP stream id for negotiated channels; -1 = auto */
DCX_API int DCX_CALL dcx_channel_new_ex(int p, const char *label,
                                        const char *protocol, int unordered,
                                        int maxRetransmits, int maxLifetimeMs,
                                        int negotiated, int streamId);

/* Politely close the channel (the far side sees E_CHANNEL_CLOSED; so do we).
 * The handle stays valid for inspection until dcx_channel_free. */
DCX_API int DCX_CALL dcx_channel_close(int c);

/* Close AND destroy the channel, freeing its handle. Idempotent. */
DCX_API void DCX_CALL dcx_channel_free(int c);

/* Send one BINARY message (arrives as an E_MESSAGE with F_DC_PAYLOAD on the
 * far side; a browser receives an ArrayBuffer). `len` > DCX_MAX_MESSAGE fails
 * with DCX_ERR_TOO_LARGE; a not-yet-open channel fails with DCX_ERR_NATIVE.
 * len == 0 sends an empty message. */
DCX_API int DCX_CALL dcx_send_data(int c, const void *data, int len);

/* Send one TEXT message (arrives as an E_MESSAGE with F_DC_TEXT; a browser
 * receives a string). Same size budget as dcx_send_data. */
DCX_API int DCX_CALL dcx_send_text(int c, const char *text);

/* Channel metadata. Label/protocol: bytes-written / -needed / 0-on-bad-handle. */
DCX_API int DCX_CALL dcx_channel_label(int c, char *out, int cap);
DCX_API int DCX_CALL dcx_channel_protocol(int c, char *out, int cap);

/* The channel's SCTP stream id, or -1 on a bad handle / not yet assigned
 * (stream 0 is valid, hence -1 — the getter--1 caveat again). */
DCX_API int DCX_CALL dcx_channel_stream_id(int c);

/* 1 while the channel is open and sendable, else 0 (bad handle included). */
DCX_API int DCX_CALL dcx_channel_is_open(int c);

/* The peer handle this channel belongs to, or 0 on a bad handle. */
DCX_API int DCX_CALL dcx_channel_peer(int c);

/* The negotiated per-message size limit for this channel (bytes), or -1 on a
 * bad handle. Sends must satisfy BOTH this and DCX_MAX_MESSAGE. */
DCX_API int DCX_CALL dcx_channel_max_message(int c);

/* ---- backpressure ---------------------------------------------------------
 * SCTP buffers outbound messages; blasting a slow channel grows that buffer
 * without bound. Poll dcx_buffered_amount (bytes queued, not yet handed to the
 * transport; -1 on a bad handle) and throttle when it climbs, or set the
 * low-threshold and wait for the E_BUFFERED_LOW event that fires when the
 * buffer drains back under it. */
DCX_API int DCX_CALL dcx_buffered_amount(int c);
DCX_API int DCX_CALL dcx_set_buffered_low_threshold(int c, int amount);

/* ====================================================================== *
 *  The event drain (the firehose) — one FFI round-trip per poll
 * ====================================================================== */

/* Drain pending events into `out` as a count-prefixed list of event records —
 * the EXACT framing TorrentXT's btx_pop_alerts pins:
 *
 *     [eventCount:u16]  then eventCount x  [eventType:u16][bodyLen:u16][kvrecord]
 *
 * Returns the NUMBER OF EVENT RECORDS written (also encoded as the leading
 * u16), or -needed when even the FIRST pending event will not fit `cap` (grow
 * and retry). Events that do not fit this call simply stay queued for the next
 * one, in order — the drain NEVER drops or reorders an event it has accepted.
 *
 * The queue is GLOBAL (one per process, all peers), so one call per poll tick
 * drains everything regardless of how many connections are live. It is BOUNDED
 * (a safety valve, generous — see docs/architecture.md): if the app stops
 * polling while traffic pours in, the shim sheds the NEWEST events rather than
 * grow without bound, and reports the shed count in a single E_QUEUE_OVERFLOW
 * event on the next drain. A polling app never comes near the bound. */
DCX_API int DCX_CALL dcx_poll(void *out, int cap);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* DCX_ABI_H */
