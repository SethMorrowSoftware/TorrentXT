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
 * leaves the module-static last-error populated, exactly as a real throw would. */
int force_throw(void);

/* Number of sessions currently live in the session handle table (0 or 1, since
 * a second concurrent session is refused). Lets the test check the invariant
 * after new/free without poking internals. */
int live_session_count(void);

}  // namespace test
}  // namespace btx

#endif /* __cplusplus */

#endif /* TORRENT_SHIM_H */
