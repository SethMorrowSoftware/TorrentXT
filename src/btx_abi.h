/* btx_abi.h — TorrentXT C ABI contract (the locked, versioned surface).
 *
 * This is the heart of the project (plan §4). The shim (torrent_shim.cpp)
 * IMPLEMENTS every symbol here; the LCB binding (torrent.lcb) declares one
 * `private foreign handler` per symbol that `binds to "c:torrentxt>btx_*"`.
 * Both sides must agree byte-for-byte on these signatures, so this header is
 * the single source of truth and is treated as a frozen contract:
 *
 *   - NEVER rename an exported `btx_*` symbol (compiled .lcb binaries reference
 *     the strings; a rename silently breaks the binding at first use).
 *   - Any change to the exported surface (new symbol, changed signature, new
 *     record field, new alert code) BUMPS BTX_ABI_VERSION below, and the LCB
 *     `checkABI()` throws a clear error on skew instead of crashing later.
 *
 * Deliberately pure C so the contract is unambiguous and the header is usable
 * from either a C or C++ translation unit (the shim is C++; this stays C-clean).
 *
 * Type conventions across the FFI (plan §4.1), carried from Box2Dxt/ShowControl:
 *   real number ............ double
 *   integer / handle ....... int32_t  (handles are POSITIVE; 0 == invalid)
 *   boolean ................ int       (0/1)
 *   byte buffer ............ const void* / void* + int length   (see §6)
 *   short string ........... const char* (UTF-8, NUL-terminated; the LCB
 *                            `ZStringUTF8` bridge), never a length-counted blob
 *   64-bit value / hash .... decimal-or-hex ASCII string  (there is NO 64-bit
 *                            foreign int — they ride as text)
 *
 * Out-buffer convention (plan §6): a function that fills a caller-owned buffer
 * returns the number of bytes written (>= 0) on success, or the NEGATIVE of the
 * capacity it needed when the supplied buffer was too small (so the caller can
 * grow and retry). A call on a stale/invalid handle is a harmless no-op that
 * returns 0 (an empty record) — never a crash, never a small negative that
 * could be confused with a -needed value.
 */
#ifndef BTX_ABI_H
#define BTX_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ version */

/* Bump on ANY change to the exported ABI: a new/removed symbol, a changed
 * signature, a new record fieldId or alert code, or a framing change. The LCB
 * layer hard-codes the matching number in checkABI() and refuses to run on
 * skew. Start at 1. */
#define BTX_ABI_VERSION 8

/* ----------------------------------------------------------- export linkage */

/* One shared library, exported `btx_*` symbols, cdecl (the .lcb binds with the
 * "!cdecl" suffix; on the non-Windows targets cdecl is the only convention, so
 * BTX_CALL is empty there). */
#if defined(_WIN32)
#  define BTX_API  __declspec(dllexport)
#  define BTX_CALL __cdecl
#else
#  define BTX_API  __attribute__((visibility("default")))
#  define BTX_CALL
#endif

/* ------------------------------------------------------------- return codes */

/* Returned by ACTION entry points (control / setters): 0 == ok, negative ==
 * failure. The buffer-filling getters do NOT use these; they follow the
 * out-buffer convention documented in the file header (bytes-written / -needed
 * / 0-for-no-op). Keeping the two conventions in separate function families
 * means a small -needed can never be mistaken for an error code. */
enum {
    BTX_OK                = 0,
    BTX_ERR_GENERIC       = -1,  /* unclassified failure; see btx_last_error  */
    BTX_ERR_BAD_HANDLE    = -2,  /* session/torrent handle not live           */
    BTX_ERR_INVALID_ARG   = -3,  /* a null/empty/out-of-range argument        */
    BTX_ERR_SESSION_LIVE  = -4,  /* refused a 2nd concurrent session (§4.2)   */
    BTX_ERR_NO_SESSION    = -5,  /* operation needs a session, none is live   */
    BTX_ERR_EXCEPTION     = -6,  /* the firewall caught a libtorrent throw     */
    BTX_ERR_ABI           = -7   /* reserved for ABI-mismatch reporting        */
};

/* ====================================================================== *
 *  Lifecycle & diagnostics
 * ====================================================================== */

/* Returns BTX_ABI_VERSION. The very first call the LCB layer makes; the spike
 * (plan §10 Phase 0) proves the whole FFI round-trip with just this symbol. */
BTX_API int BTX_CALL btx_abi_version(void);

/* Create THE session (we deliberately allow only one live session at a time —
 * plan §4.2). Returns a positive session handle, or 0 on failure (call again
 * after btx_session_free). Defaults are sane (DHT/LSD/uTP on); tune with the
 * btx_set_* family before or after adding torrents. */
BTX_API int BTX_CALL btx_session_new(void);

/* Pause, request+flush resume data, stop, destroy, join threads. Idempotent:
 * a second call (or a call with a stale handle) is a no-op. There is no
 * deterministic LCB unload hook, so the app MUST call this (e.g. on closeStack);
 * a session leaked at quit is the documented failure mode if it forgets. */
BTX_API void BTX_CALL btx_session_free(int s);

/* Fill `out` with the module-static last-error string (UTF-8). Returns bytes
 * written, or -needed if `cap` is too small. Empty when there is no error. */
BTX_API int BTX_CALL btx_last_error(char *out, int cap);

/* Clear the module-static last-error string. */
BTX_API void BTX_CALL btx_clear_error(void);

/* ====================================================================== *
 *  Session settings  (the protocol surface — see the documented key list)
 * ====================================================================== */

/* Map a libtorrent settings_pack key by NAME to a value. 64-bit ints ride as a
 * decimal ASCII string (there is no 64-bit foreign int). Unknown keys fail with
 * BTX_ERR_INVALID_ARG and set the last error. Applied live via apply_settings. */
BTX_API int BTX_CALL btx_set_int (int s, const char *key, const char *decValue);
BTX_API int BTX_CALL btx_set_bool(int s, const char *key, int value);
BTX_API int BTX_CALL btx_set_str (int s, const char *key, const char *value);

/* Read an int/bool/str setting back as text into `out` (bytes-written/-needed).
 * Convenience for diagnostics; not on the hot path. */
BTX_API int BTX_CALL btx_get_setting(int s, const char *key, char *out, int cap);

/* MSE / protocol-encryption policy, passed straight through to libtorrent's
 * settings_pack. in/out policy: 0=forced 1=enabled 2=disabled (enc_policy);
 * level: 1=plaintext 2=rc4 3=both (enc_level). Maps to in_enc_policy /
 * out_enc_policy / allowed_enc_level. */
BTX_API int BTX_CALL btx_set_encryption_policy(int s, int inPolicy,
                                               int outPolicy, int level);

/* ====================================================================== *
 *  Session operations (ABI v7) — whole-session pause, listen port, look up a
 *  torrent by info-hash, classic (BEP5) DHT peer announce.
 * ====================================================================== */

/* Pause / resume the WHOLE session (all torrents); is_paused returns 1/0 (0 on
 * no session). Distinct from per-torrent btx_pause/btx_resume. */
BTX_API int BTX_CALL btx_session_pause(int s);
BTX_API int BTX_CALL btx_session_resume(int s);
BTX_API int BTX_CALL btx_session_is_paused(int s);

/* The TCP port we actually ended up listening on (0 == not listening yet). */
BTX_API int BTX_CALL btx_listen_port(int s);

/* Look up an already-added torrent by its 40-hex (v1) info-hash; returns OUR
 * torrent handle id, or 0 if not found / bad args. */
BTX_API int BTX_CALL btx_find_torrent(int s, const char *infoHashHex);

/* Classic BEP5 DHT peer announce (NOT BEP44): tell the DHT we have peers for
 * this 40-hex info-hash on `port` (0 == our listen port). Fire-and-forget. */
BTX_API int BTX_CALL btx_dht_announce(int s, const char *infoHashHex, int port);

/* ====================================================================== *
 *  Filtering & streaming (ABI v8)
 * ====================================================================== */

/* Add an inclusive IP range to the session IP filter; block != 0 blocks it
 * (the default-empty filter allows everything). Rules accumulate (read-modify-
 * write). `startIp`/`endIp` are textual addresses of the SAME family (both IPv4
 * or both IPv6), e.g. "1.2.3.0".."1.2.3.255". btx_ip_filter_clear removes all. */
BTX_API int BTX_CALL btx_ip_filter_add(int s, const char *startIp,
                                       const char *endIp, int block);
BTX_API int BTX_CALL btx_ip_filter_clear(int s);

/* Streaming: ask libtorrent to fetch a piece by a deadline (milliseconds from
 * now), reordering requests so the soonest deadlines come first. Clear removes
 * all deadlines. The data still rides engine ⇄ disk; only the hint crosses. */
BTX_API int BTX_CALL btx_set_piece_deadline(int t, int pieceIndex, int deadlineMs);
BTX_API int BTX_CALL btx_clear_piece_deadlines(int t);

/* ====================================================================== *
 *  Add / remove torrents
 * ====================================================================== */

/* parse_magnet_uri -> add_torrent_params; returns a positive torrent handle
 * (0 on failure). Metadata arrives later as a metadataReceived alert. */
BTX_API int BTX_CALL btx_add_magnet(int s, const char *uri, const char *savePath);

/* Build torrent_info from the .torrent BYTES (an IN buffer crossing as
 * pointer+len; the payload never crosses — only the metainfo). Returns a
 * torrent handle (0 on failure). */
BTX_API int BTX_CALL btx_add_torrent_file(int s, const void *data, int len,
                                          const char *savePath);

/* Re-add from previously saved resume data (read_resume_data). Returns a
 * torrent handle (0 on failure). */
BTX_API int BTX_CALL btx_add_with_resume(int s, const void *resume, int len,
                                         const char *savePath);

/* Extended add (ABI v8): like btx_add_magnet / btx_add_torrent_file but apply
 * add-time torrent_flags — set the bits named in `maskDec` to `flagsDec`,
 * leaving the rest at libtorrent's default. The common use is adding PAUSED
 * (kFlagPaused) so you can set file priorities before it starts, or
 * kFlagSequentialDownload for immediate streaming. */
BTX_API int BTX_CALL btx_add_magnet_ex(int s, const char *uri,
                                       const char *savePath,
                                       const char *flagsDec, const char *maskDec);
BTX_API int BTX_CALL btx_add_torrent_file_ex(int s, const void *data, int len,
                                             const char *savePath,
                                             const char *flagsDec,
                                             const char *maskDec);

/* Remove a torrent; deleteFiles != 0 also deletes downloaded files. */
BTX_API int BTX_CALL btx_remove(int s, int t, int deleteFiles);

/* ====================================================================== *
 *  Control
 * ====================================================================== */

BTX_API int BTX_CALL btx_pause(int t);
BTX_API int BTX_CALL btx_resume(int t);
BTX_API int BTX_CALL btx_force_recheck(int t);
BTX_API int BTX_CALL btx_force_reannounce(int t);

/* priority: 0=dont_download .. 7=top (libtorrent download_priority_t range). */
BTX_API int BTX_CALL btx_set_file_priority(int t, int fileIndex, int priority);
/* Bulk: one priority byte per file, in file order; `count` bytes at `prios`. */
BTX_API int BTX_CALL btx_set_file_priorities(int t, const void *prios, int count);
BTX_API int BTX_CALL btx_set_piece_priority(int t, int pieceIndex, int priority);

/* Per-torrent rate caps in bytes/sec, as decimal strings ("0" == unlimited). */
BTX_API int BTX_CALL btx_set_torrent_limits(int t, const char *downDec,
                                            const char *upDec);

/* ---- extended control (ABI v4): flags, slots, queue, storage ---------------
 * More of libtorrent's torrent_handle surface. torrent_flags_t rides as a
 * 64-bit decimal string (there is no 64-bit foreign int): set_flags writes only
 * the bits named in `mask`, unset_flags clears the bits named in `flags`. The
 * named bit values (sequential_download, auto_managed, share_mode, upload_mode,
 * super_seeding, apply_ip_filter, stop_when_ready, ...) are stable libtorrent
 * constants the LCB layer mirrors as kFlag*. */
BTX_API int BTX_CALL btx_set_torrent_flags(int t, const char *flagsDec,
                                           const char *maskDec);
BTX_API int BTX_CALL btx_unset_torrent_flags(int t, const char *flagsDec);

/* Per-torrent caps: max peer connections, and max unchoked upload slots. */
BTX_API int BTX_CALL btx_set_max_connections(int t, int maxConns);
BTX_API int BTX_CALL btx_set_max_uploads(int t, int maxUploads);

/* Clear a torrent's error state so it can resume (e.g. after fixing a disk or
 * permission problem that paused it). */
BTX_API int BTX_CALL btx_torrent_clear_error(int t);

/* Ask the tracker(s) for current seed/leecher counts; result -> A_SCRAPE_REPLY. */
BTX_API int BTX_CALL btx_scrape_tracker(int t);

/* Move the downloaded files to a new directory; result -> A_STORAGE_MOVED (or
 * A_FILE_ERROR on failure). The bytes move engine-side, never through script. */
BTX_API int BTX_CALL btx_move_storage(int t, const char *savePath);

/* Download-queue positioning. btx_queue_position returns the 0-based position,
 * or -1 when the torrent is not queued (or the handle is invalid). This is the
 * ONE int-getter that uses -1 (not 0) for "no value", because 0 is itself a
 * valid queue position. btx_queue_move op: 0=up 1=down 2=top 3=bottom. */
BTX_API int BTX_CALL btx_queue_position(int t);
BTX_API int BTX_CALL btx_queue_move(int t, int op);

/* ====================================================================== *
 *  Status — ONE snapshot per call (perf: never one FFI call per field, §8)
 * ====================================================================== */

/* Fill a single typed KV record (schema in btx_record.h) describing the
 * torrent: name, state, progress, rates, totals, peers/seeds, save path,
 * info-hashes, error, ... Returns bytes-written / -needed / 0-on-bad-handle. */
BTX_API int BTX_CALL btx_torrent_status(int t, void *out, int cap);

/* Enumerate the session's torrents. */
BTX_API int BTX_CALL btx_torrent_count(int s);
BTX_API int BTX_CALL btx_torrent_handle_at(int s, int index);

/* v1 (or, absent v1, v2) info-hash as a hex string into `out`. */
BTX_API int BTX_CALL btx_info_hash_hex(int t, char *out, int cap);

/* Packed have-bitfield (1 bit per piece, MSB-first within each byte) as raw
 * bytes — a read-only view for a piece grid. bytes-written / -needed / 0. */
BTX_API int BTX_CALL btx_piece_bitfield(int t, void *out, int cap);

/* Connected peers as a count-prefixed list of KV records (schema §). */
BTX_API int BTX_CALL btx_peer_list(int t, void *out, int cap);

/* The torrent's files as a count-prefixed list of KV records — one per file:
 * path (relative), size, bytes downloaded, and download priority. Empty (count
 * 0) until metadata arrives. One round-trip for the whole file table (§8). */
BTX_API int BTX_CALL btx_file_list(int t, void *out, int cap);

/* Per-piece availability (how many connected peers advertise each piece) as raw
 * bytes — one byte per piece, clamped to 255 — a read-only view for an
 * availability grid. bytes-written / -needed / 0, like btx_piece_bitfield. */
BTX_API int BTX_CALL btx_piece_availability(int t, void *out, int cap);

/* ---- trackers & web seeds (ABI v6) ----------------------------------------
 * Inspect and edit a torrent's tracker list and HTTP/URL (web) seeds. The two
 * listers return count-prefixed KV-record lists (the peer-list framing); the
 * editors are fire-and-forget actions. */

/* The torrent's trackers as a list of KV records: url, tier, verified, source. */
BTX_API int BTX_CALL btx_trackers(int t, void *out, int cap);

/* Add an announce URL at the given tier (0 == first tier; libtorrent dedups). */
BTX_API int BTX_CALL btx_add_tracker(int t, const char *url, int tier);

/* Add / remove an HTTP (URL / web) seed (BEP 19). */
BTX_API int BTX_CALL btx_add_url_seed(int t, const char *url);
BTX_API int BTX_CALL btx_remove_url_seed(int t, const char *url);

/* The torrent's web seeds as a list of KV records (one F_URL_SEED field each). */
BTX_API int BTX_CALL btx_url_seeds(int t, void *out, int cap);

/* ====================================================================== *
 *  The alert drain (the event firehose) — one FFI round-trip per poll (§3)
 * ====================================================================== */

/* Drain pending libtorrent alerts into `out` as a count-prefixed list of alert
 * records (schema in btx_record.h). Returns the NUMBER OF ALERT RECORDS written
 * (also encoded as the leading u16 count), or -needed when even the first
 * pending record will not fit. Records that do not fit this call are stashed
 * and emitted on the next call — the drain NEVER drops a record (ShowControl's
 * MIDI rule). 0 means "no alerts pending". */
BTX_API int BTX_CALL btx_pop_alerts(int s, void *out, int cap);

/* ====================================================================== *
 *  DHT
 * ====================================================================== */

BTX_API int BTX_CALL btx_dht_add_bootstrap(int s, const char *host, int port);
BTX_API int BTX_CALL btx_dht_state(int s, void *out, int cap);
/* Opaque DHT routing-table state for persistence across runs. */
BTX_API int BTX_CALL btx_dht_save_state(int s, void *out, int cap);
BTX_API int BTX_CALL btx_dht_load_state(int s, const void *data, int len);

/* ---- BEP44: the DHT as a key-value store ----------------------------------
 * Two item kinds. IMMUTABLE: the key IS the SHA-1 of the bencoded value, so
 * the value cannot change (content-addressed). MUTABLE: the value lives under
 * an ed25519 public key (+ optional salt) and is signed, so the owner can
 * publish updated, sequence-numbered values. Values are capped at 1000 bytes
 * (BEP44). Results arrive as drained alerts (A_DHT_IMMUTABLE_ITEM /
 * A_DHT_MUTABLE_ITEM for gets, A_DHT_PUT for put confirmations). */

/* Generate (or, with a 64-hex seed, deterministically re-derive) an ed25519
 * keypair for mutable items. Fills `out` with a record {publicKey, secretKey,
 * seed} as hex. Persist the seed (or secret key) to keep a stable identity. */
BTX_API int BTX_CALL btx_dht_keypair(const char *seedHexOrEmpty, void *out, int cap);

/* Store `data` (len bytes, <= 1000) as an immutable item. Fills `outTargetHex`
 * with the item's target hash (its lookup key) and returns bytes-written /
 * -needed for that hex; the store itself confirms later via an A_DHT_PUT alert. */
BTX_API int BTX_CALL btx_dht_put_immutable(int s, const void *data, int len,
                                           char *outTargetHex, int cap);

/* Look up an immutable item by its 40-hex target. Result: A_DHT_IMMUTABLE_ITEM. */
BTX_API int BTX_CALL btx_dht_get_immutable(int s, const char *targetHex);

/* Store `data` (<= 1000 bytes) as a mutable item under the given ed25519 key
 * (64-hex public, 128-hex secret) and optional salt. The shim signs it on
 * libtorrent's thread using the secret key (no script callback) and bumps the
 * sequence number. Confirms via an A_DHT_PUT alert. */
BTX_API int BTX_CALL btx_dht_put_mutable(int s, const char *publicKeyHex,
                                         const char *secretKeyHex,
                                         const char *salt,
                                         const void *data, int len);

/* Look up a mutable item by its 64-hex public key (+ optional salt). Result:
 * A_DHT_MUTABLE_ITEM (carrying value, seq, signature, authoritative). */
BTX_API int BTX_CALL btx_dht_get_mutable(int s, const char *publicKeyHex,
                                         const char *salt);

/* ====================================================================== *
 *  Persistence (resume data) — async, libtorrent's model (plan §4.3)
 * ====================================================================== */

/* REQUEST resume data for a torrent. The bytes arrive later as a
 * resumeDataReady alert (carrying the resume_data field) which you drain and
 * persist; re-add later with btx_add_with_resume. There is deliberately no
 * synchronous getter. */
BTX_API int BTX_CALL btx_save_resume(int t);

/* ====================================================================== *
 *  Create torrents (seeding side — plan Phase 3)
 * ====================================================================== */

/* Build a .torrent for `contentPath` (file or directory) with the given piece
 * size (0 == auto) and flags, writing the bencoded .torrent bytes into `out`.
 * bytes-written / -needed. `trackers` is an optional newline-separated list of
 * announce URLs (NULL or "" => a trackerless, DHT-only torrent); each non-empty
 * line is added as its own tracker tier, in order. */
BTX_API int BTX_CALL btx_create_torrent(const char *contentPath, int pieceSize,
                                        int flags, const char *trackers,
                                        void *out, int cap);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* BTX_ABI_H */
