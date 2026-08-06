/* enet_shim.cpp — Phase 0 of the flat extern "C" facade over ENet.
 *
 * What Phase 0 proves (NEXT-EXTENSIONS-PLAN.md Part III.7 milestone 0): the
 * pinned ENet builds and links into the family's bare-token shared library,
 * the exception firewall holds (a deliberate-throw entry point exists so the
 * spike can assert it), and global init/deinit round-trips. The real surface
 * — gen-tagged host/peer tables, the record codec, the pump-driven enPoll
 * drain (ENet has NO internal threads; nothing progresses unless the poll
 * loop calls enet_host_service — rule 1 is trivially satisfied but the pump
 * is the binding's heartbeat) — is milestone 1, copied from the proven
 * datachannelxt/torrentxt pattern.
 */

#include "enx_abi.h"

/* ENet is a SYSTEM header to us (-isystem via CMake). */
#include <enet/enet.h>

#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

namespace {

/* Script-thread only (ENet has no threads and Phase 0 spawns none), so the
 * error slot is unguarded by design — same as the siblings' g_last_error. */
std::string g_last_error;

void set_error(const std::string &msg) { g_last_error = msg; }

/* enet_initialize/_deinitialize are process-global and refuse to be nested
 * meaningfully; count so paired calls from a re-run selftest stay balanced
 * and a double init is a cheap no-op instead of ENet-internal state soup. */
int g_init_count = 0;

/* Fill a caller buffer with a NUL-terminated copy of s (the family's
 * out-buffer convention, small-string edition): returns bytes written
 * excluding the NUL, or -needed when cap is too small. Never returns a
 * pointer of unknown lifetime. */
int fill_out(const std::string &s, char *out, int cap) {
    const int need = static_cast<int>(s.size()) + 1;
    if (!out || cap < need) {
        return -need;
    }
    std::memcpy(out, s.c_str(), static_cast<size_t>(need));
    return need - 1;
}

} /* namespace */

extern "C" ENX_API int ENX_CALL enx_abi_version(void) {
    return ENX_ABI_VERSION;
}

/* Global init. Idempotent by count; returns ENX_OK or ENX_ERR_NATIVE. */
extern "C" ENX_API int ENX_CALL enx_initialize(void) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        if (g_init_count > 0) {
            ++g_init_count;
            return ENX_OK;
        }
        if (enet_initialize() != 0) {
            set_error("enet_initialize failed");
            return ENX_ERR_NATIVE;
        }
        ++g_init_count;
        return ENX_OK;
    });
}

/* Global teardown, paired with enx_initialize; extra calls are no-ops. */
extern "C" ENX_API int ENX_CALL enx_deinitialize(void) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        if (g_init_count <= 0) {
            return ENX_OK;
        }
        --g_init_count;
        if (g_init_count == 0) {
            enet_deinitialize();
        }
        return ENX_OK;
    });
}

/* "enet A.B.C" from the LINKED library (not the header we compiled against),
 * so a runtime skew is visible. Filled into a caller buffer, -needed on a
 * short one — the convention every buffer-returning enx_ call will follow. */
extern "C" ENX_API int ENX_CALL enx_version_string(char *out, int cap) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        const ENetVersion v = enet_linked_version();
        char buf[48];
        std::snprintf(buf, sizeof buf, "enet %d.%d.%d",
                      ENET_VERSION_GET_MAJOR(v),
                      ENET_VERSION_GET_MINOR(v),
                      ENET_VERSION_GET_PATCH(v));
        return fill_out(buf, out, cap);
    });
}

extern "C" ENX_API int ENX_CALL enx_last_error(char *out, int cap) {
    ENX_GUARD_INT(ENX_ERR_THROWN, { return fill_out(g_last_error, out, cap); });
}

extern "C" ENX_API void ENX_CALL enx_clear_error(void) {
    ENX_GUARD_VOID({ g_last_error.clear(); });
}

/* Deliberately throws, so the spike (and every later smoke test) can assert
 * the firewall converts a C++ exception into an error return instead of
 * letting it unwind across extern "C" — the family's standing proof. */
extern "C" ENX_API int ENX_CALL enx_selftest_throw(void) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        throw std::runtime_error("enx firewall selftest");
    });
}
