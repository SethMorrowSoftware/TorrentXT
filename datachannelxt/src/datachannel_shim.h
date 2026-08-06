/* datachannel_shim.h — the C ABI surface of the DataChannelXT native library.
 *
 * This header exists for two consumers only:
 *
 *   1. datachannel_shim.cpp, which #includes it to keep its definitions and the
 *      frozen contract in dcx_abi.h in lock-step (every `dcx_*` body in the
 *      .cpp is the definition of a declaration that ultimately comes from
 *      dcx_abi.h).
 *   2. tests/datachannel_smoke_test.cpp, which #includes it to call the same
 *      exported symbols the LCB layer will call — the test exercises the REAL
 *      ABI, not a private copy of it.
 *
 * The authoritative, byte-for-byte contract is dcx_abi.h; this header just
 * re-exports it and adds the few INTERNAL test hooks the smoke test needs to
 * force conditions it cannot reach through the public surface alone (tripping
 * the exception firewall; shrinking the bounded queue to prove the overflow
 * path). Those hooks are namespaced under `dcx::test` and are NOT part of the
 * FFI — the .lcb never sees them, and they exist purely so CI can prove the
 * safety invariants. (Same shape as TorrentXT's torrent_shim.h.)
 */
#ifndef DATACHANNEL_SHIM_H
#define DATACHANNEL_SHIM_H

/* The frozen ABI contract — the full `extern "C"` dcx_* surface the shim
 * implements and the LCB binding declares. */
#include "dcx_abi.h"

#ifdef __cplusplus

/* ------------------------------------------------------------------ test hooks
 *
 * INTERNAL ONLY. C++ linkage, in dcx::test, so they can never be mistaken for
 * part of the flat FFI. DCX_API: exported with default visibility so the smoke
 * test, which links the built shared library, can resolve them under
 * -fvisibility=hidden. Add a hook only when a safety invariant genuinely
 * cannot be observed through the public ABI. */
namespace dcx {
namespace test {

/* Runs a body that always throws, through the SAME firewall macro every real
 * entry point uses. Returns the error code the firewall produced (expected
 * DCX_ERR_EXCEPTION) and leaves the module-static last-error populated,
 * exactly as a real throw would. */
DCX_API int force_throw(void);

/* Live entries in the peer / channel handle tables, so the smoke test can
 * assert create/free bookkeeping without poking module statics. */
DCX_API int live_peer_count(void);
DCX_API int live_channel_count(void);

/* Number of events currently waiting in the inbound queue (drained by
 * dcx_poll), and the count of events shed by the bounded-queue safety valve
 * since the last E_QUEUE_OVERFLOW report. */
DCX_API int queue_depth(void);
DCX_API long long dropped_count(void);

/* Shrink (or restore) the bounded queue's caps so the overflow safety valve is
 * reachable in a test without generating millions of events. Passing 0 for
 * either value restores that cap's default. TEST ONLY — the production caps
 * are compile-time constants documented in docs/architecture.md. */
DCX_API void set_queue_caps(int maxEvents, long long maxBytes);

}  // namespace test
}  // namespace dcx

#endif /* __cplusplus */

#endif /* DATACHANNEL_SHIM_H */
