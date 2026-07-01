/* torrent_shim.h — the C ABI surface of the TorrentXT native library.
 *
 * This header exists for two consumers only:
 *
 *   1. torrent_shim.cpp, which #includes it to keep its definitions and the
 *      frozen contract in btx_abi.h in lock-step (every `btx_*` body in the .cpp
 *      is the definition of a declaration that ultimately comes from btx_abi.h).
 *   2. tests/torrent_smoke_test.cpp, which #includes it to call the same exported
 *      symbols the LCB layer will call — the test exercises the REAL ABI, not a
 *      private copy of it.
 *
 * The authoritative, byte-for-byte contract is btx_abi.h; this header just
 * re-exports it (so the include path for callers is a single, stable file) and
 * adds the few INTERNAL test hooks the smoke test needs to force conditions it
 * cannot reach through the public surface alone (notably: deliberately tripping
 * the exception firewall). Those hooks are namespaced under `btx::test` and are
 * NOT part of the FFI — the .lcb never sees them, they never carry libtorrent
 * types across, and they exist purely so CI can prove the safety invariants.
 *
 * Per the deliverable spec we do NOT touch btx_abi.h / btx_record.h /
 * btx_handle_table.h — they are the frozen contract; this file only consumes
 * them.
 */
#ifndef TORRENT_SHIM_H
#define TORRENT_SHIM_H

/* The frozen ABI contract — the full `extern "C"` btx_* surface the shim
 * implements and the LCB binding declares. Pulling it in here means a caller
 * (the smoke test) gets the prototypes by including this single header. */
#include "btx_abi.h"

#ifdef __cplusplus

/* ------------------------------------------------------------------ test hooks
 *
 * INTERNAL ONLY. These have C++ linkage and live in btx::test so they can never
 * be mistaken for part of the flat FFI. They let the smoke test reach the two
 * conditions that are otherwise unreachable from outside:
 *
 *   - force_throw(): an entry point whose body unconditionally throws, so the
 *     test can prove the firewall catches it, surfaces BTX_ERR_EXCEPTION, and
 *     records a last-error string — instead of unwinding across `extern "C"`.
 *     It is wired through the SAME try/catch helper every real entry uses, so
 *     it tests the firewall itself, not a bespoke catch.
 *
 *   - live_session_count(): how many sessions the shim believes are live, so the
 *     test can assert the single-live-session invariant without reaching into
 *     module-static state directly.
 *
 * Kept deliberately tiny; add a hook only when a safety invariant genuinely
 * cannot be observed through the public ABI. */
namespace btx {
namespace test {

/* Runs a body that always throws, through the production firewall helper.
 * Returns the error code the firewall produced (expected BTX_ERR_EXCEPTION) and
 * leaves the module-static last-error populated, exactly as a real throw would.
 * BTX_API: exported with default visibility so the smoke test, which links the
 * built shared library, can resolve it under -fvisibility=hidden. */
BTX_API int force_throw(void);

/* Number of sessions currently live in the session handle table (0 or 1, since
 * a second concurrent session is refused). Lets the test check the invariant
 * after new/free without poking internals. Exported (BTX_API) for the same
 * visibility reason as force_throw above. */
BTX_API int live_session_count(void);

/* Sign a mutable DHT value through the production signing helper and verify it
 * with libtorrent's verify_mutable_item; returns 1 if the signature verifies, 0
 * if not (negative on an internal throw). Guards the BEP44 signing contract -
 * the value must be signed in its BENCODED form - which is otherwise unreachable
 * through the public ABI because real signing only runs in a network-thread
 * callback once a live DHT finds a home for the blob. A regression here is the
 * silent "channel feeds never arrive" failure. Exported (BTX_API) for the same
 * visibility reason as the hooks above. */
BTX_API int dht_mutable_sign_verifies(const char *publicKeyHex,
                                      const char *secretKeyHex,
                                      const char *salt,
                                      const void *data, int len);

/* Derive an ed25519 keypair from a 32-byte seed (64 hex), build the BEP44
 * canonical buffer for (salt, seq, value) through the SAME bep44_signbuf() the
 * external-signing put uses, sign it, and write the public-key hex (64 chars +
 * NUL) and signature hex (128 chars + NUL) into the caller buffers. Returns 1 on
 * success, 0 on a bad seed, negative on an internal throw. This is the bridge
 * that lets the smoke test run a KNOWN-ANSWER conformance check: an external
 * signer (SodiumXT, in production) must produce a signature that libtorrent's
 * own ed25519 accepts as a BEP44 signature, so a fixed (seed, salt, seq, value)
 * must yield a fixed (public key, signature). It also produces the exact inputs
 * the test then feeds to btx_dht_put_signed to prove the verify-before-store
 * guard accepts a good signature and rejects a tampered one. Exported (BTX_API)
 * for the same visibility reason as the hooks above. */
BTX_API int dht_bep44_sign(const char *seedHex, const char *salt,
                           const char *seqDec, const void *value, int len,
                           char *outPublicKeyHex, char *outSignatureHex);

/* Frame one rp1 message exactly as btx_rp1_send queues it onto the wire:
 * [len:u32][20][extId][payload]. Writes into `out` (bytes-written / -needed), so
 * the smoke test can pin the byte layout — the on-wire framing is otherwise only
 * exercised against a live peer. Exported for the usual visibility reason. */
BTX_API int rp1_frame(int extId, const void *data, int len, void *out, int cap);

/* Run the real extended-message-id selection (smallest positive id not in
 * `used`) the peer plugin uses in add_handshake, so a regression in id choice
 * (which would collide rp1 with ut_pex/ut_metadata) is caught. */
BTX_API int rp1_free_id(const int *used, int count);

}  // namespace test
}  // namespace btx

#endif /* __cplusplus */

#endif /* TORRENT_SHIM_H */
