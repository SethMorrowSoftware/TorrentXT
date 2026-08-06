/* enx_abi.h — the stable C ABI surface of enetxt (Phase 0 slice).
 *
 * The contract carried from the family (torrentxt btx_ / datachannelxt dcx_):
 *   - every exported symbol keeps the enx_ prefix forever (LCB binds by name);
 *   - no exception ever crosses extern "C" (the ENX_GUARD_* firewall below);
 *   - reals cross as double, booleans as int, 64-bit values as decimal
 *     strings, byte buffers as pointer+length;
 *   - ENX_ABI_VERSION bumps on ANY change; the LCB layer refuses skew.
 *
 * Phase 0 exports only the lifecycle + diagnostics slice: enough to prove the
 * export path, the firewall, and the pinned library link. The Phase 1 surface
 * (hosts, peers, send/broadcast, the poll drain) is specified in
 * NEXT-EXTENSIONS-PLAN.md Part III.4 and lands with the handle tables and
 * record codec.
 */
#ifndef ENX_ABI_H
#define ENX_ABI_H

/* v2: Phase 1 — hosts, peers, connect/disconnect, send/broadcast/flush,
 * tuning, status records, the enPoll drain. (v1 was the Phase 0 slice.) */
#define ENX_ABI_VERSION 2

/* The family's per-message budget, enforced BOTH ways: enx_send/enx_broadcast
 * refuse anything larger (ENX_ERR_TOO_LARGE, never a silent truncation), and
 * an INBOUND packet over it is dropped WHOLE with an E_ERROR event. Keeps
 * every payload field far under the u16 field-length ceiling and keeps bulk
 * where it belongs (TorrentXT). */
#define ENX_MAX_MESSAGE 60000

#if defined(_WIN32)
#  define ENX_API __declspec(dllexport)
#  define ENX_CALL __cdecl
#else
#  define ENX_API __attribute__((visibility("default")))
#  define ENX_CALL
#endif

/* Error space (negative returns from action-style entry points). */
#define ENX_OK            0
#define ENX_ERR_GENERIC  (-1)
#define ENX_ERR_STALE    (-2)
#define ENX_ERR_ARG      (-3)
#define ENX_ERR_TOO_LARGE (-4)
#define ENX_ERR_NATIVE   (-5)
#define ENX_ERR_THROWN   (-6)

/* THE EXCEPTION FIREWALL. Every entry point body goes through one of these;
 * a throw becomes a recorded error + error return, never an unwind into the
 * engine. Two lessons are baked in from the siblings, keep them:
 *   - one declaration per line inside a guard body (the macro-comma trap:
 *     the preprocessor only protects commas inside parentheses);
 *   - NO preprocessor directive inside a guard body (a '#' inside a macro
 *     argument is gcc-tolerated but MSVC-rejected, C2121 — hoist any
 *     conditional into a plain helper first). */
#define ENX_GUARD_INT(errval, body)                                     \
    try { body } catch (const std::exception &e) {                      \
        set_error(e.what()); return (errval);                           \
    } catch (...) { set_error("unknown native exception"); return (errval); }

#define ENX_GUARD_VOID(body)                                            \
    try { body } catch (const std::exception &e) {                      \
        set_error(e.what());                                            \
    } catch (...) { set_error("unknown native exception"); }

#endif /* ENX_ABI_H */
