/* enet_spike_test.cpp — the Phase 0 gate, in the family's smoke-test dialect
 * (CHECK-counted, exit 1 on any failure, run under ASan/UBSan in CI and while
 * iterating).
 *
 * Two proofs:
 *   A. The SHIM proof — the bare-token shared library exports resolve and the
 *      exception firewall converts a deliberate throw into an error return
 *      (enx_selftest_throw), the -needed buffer contract holds, and global
 *      init/deinit round-trips.
 *   B. The LIBRARY proof — the pinned ENet does the whole Phase 0 loopback in
 *      ONE process: server + client hosts, connect (with connect data),
 *      reliable echo both ways byte-for-byte, an unsequenced packet on a
 *      second channel, graceful disconnect (with disconnect data), teardown.
 *      This drives ENet directly on purpose: Phase 1 will move every one of
 *      these calls behind enx_ entry points, and this test then becomes the
 *      reference for what the wrapped calls must reproduce.
 *
 * The pump-or-nothing rule (Part III.5) shapes everything: ENet has no
 * threads, so both hosts are serviced in an interleaved deadline-bounded loop
 * — exactly the shape the enPoll drain will have.
 */

#include "../src/enx_abi.h"

#include <enet/enet.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

/* The shim's Phase 0 exports (linked from the enetxt shared library). */
extern "C" {
int enx_abi_version(void);
int enx_initialize(void);
int enx_deinitialize(void);
int enx_version_string(char *out, int cap);
int enx_last_error(char *out, int cap);
void enx_clear_error(void);
int enx_selftest_throw(void);
}

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond, what)                                                  \
    do {                                                                   \
        ++g_checks;                                                        \
        if (!(cond)) {                                                     \
            ++g_failures;                                                  \
            std::fprintf(stderr, "FAIL %s (line %d)\n", what, __LINE__);   \
        }                                                                  \
    } while (0)

/* Service one host non-blocking; returns 1 if an event came out. The Phase 1
 * drain is this loop with the event copied into a record instead of handled
 * inline. */
static int pump_one(ENetHost *host, ENetEvent *ev) {
    return enet_host_service(host, ev, 0) > 0 ? 1 : 0;
}

int main() {
    std::printf("enet_spike_test: Phase 0 - shim exports + pinned-ENet loopback\n");

    /* ---- A. the shim proof ---------------------------------------------- */
    CHECK(enx_abi_version() == ENX_ABI_VERSION, "abi version matches header");

    CHECK(enx_selftest_throw() == ENX_ERR_THROWN,
          "firewall converts a throw into ENX_ERR_THROWN");
    {
        char err[128];
        const int n = enx_last_error(err, sizeof err);
        CHECK(n > 0, "last_error non-empty after the selftest throw");
        CHECK(std::strstr(err, "selftest") != nullptr,
              "last_error carries the thrown message");
        enx_clear_error();
        CHECK(enx_last_error(err, sizeof err) == 0,
              "last_error empty after clear");
    }

    {
        /* The -needed contract: a 1-byte buffer must refuse with the exact
         * size, then the retry succeeds and the string names the library. */
        char tiny[1];
        const int need = enx_version_string(tiny, 1);
        CHECK(need < 0, "short buffer refuses with -needed");
        std::string ver(static_cast<size_t>(-need), '\0');
        const int n = enx_version_string(&ver[0], -need);
        CHECK(n > 0, "retry with -needed succeeds");
        CHECK(ver.compare(0, 5, "enet ") == 0, "version string names enet");
        std::printf("  linked: %s\n", ver.c_str());
    }

    CHECK(enx_initialize() == ENX_OK, "enx_initialize");
    CHECK(enx_initialize() == ENX_OK, "enx_initialize is idempotent");
    CHECK(enx_deinitialize() == ENX_OK, "enx_deinitialize (count 2 -> 1)");
    /* Leave one init live: the loopback below runs inside it, mirroring how
     * the LCB layer will hold ONE global init across the app's lifetime. */

    /* ---- B. the loopback proof ------------------------------------------ */
    ENetAddress addr;
    enet_address_set_host(&addr, "127.0.0.1");
    addr.port = 27099;

    ENetHost *server = enet_host_create(&addr, 8, 2, 0, 0);
    CHECK(server != nullptr, "server host created (127.0.0.1:27099)");
    ENetHost *client = enet_host_create(nullptr, 1, 2, 0, 0);
    CHECK(client != nullptr, "client host created (unbound)");

    ENetPeer *clientPeer = nullptr;
    if (server && client) {
        clientPeer = enet_host_connect(client, &addr, 2, 42);
    }
    CHECK(clientPeer != nullptr, "enet_host_connect returns a peer");

    ENetPeer *serverPeer = nullptr;
    bool clientConnected = false;
    bool gotHello = false;
    bool gotEcho = false;
    bool gotUnseq = false;
    bool serverSawDisconnect = false;
    bool clientSawDisconnect = false;

    const char *kHello = "hello enet";
    const char *kEcho = "echo:hello enet";
    const char *kUnseq = "unsequenced ping";

    /* One deadline-bounded interleaved pump drives the whole scenario; each
     * branch handles exactly one protocol step. 10 s is generous — loopback
     * completes in tens of milliseconds — but keeps a firewalled CI machine
     * from hanging the suite. */
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        ENetEvent ev;
        int progressed = 0;

        while (server && pump_one(server, &ev)) {
            progressed = 1;
            if (ev.type == ENET_EVENT_TYPE_CONNECT) {
                serverPeer = ev.peer;
                CHECK(ev.data == 42, "server sees the connect data (42)");
            } else if (ev.type == ENET_EVENT_TYPE_RECEIVE) {
                /* Copy-then-destroy is the packet-ownership rule the wrap
                 * must keep: never hold ENet-owned bytes past the destroy. */
                std::string body(reinterpret_cast<char *>(ev.packet->data),
                                 ev.packet->dataLength);
                enet_packet_destroy(ev.packet);
                if (body == kHello) {
                    gotHello = true;
                    CHECK(ev.channelID == 0, "hello arrived on channel 0");
                    ENetPacket *echo = enet_packet_create(
                        kEcho, std::strlen(kEcho), ENET_PACKET_FLAG_RELIABLE);
                    CHECK(enet_peer_send(ev.peer, 0, echo) == 0,
                          "server sends the reliable echo");
                    ENetPacket *unseq = enet_packet_create(
                        kUnseq, std::strlen(kUnseq),
                        ENET_PACKET_FLAG_UNSEQUENCED);
                    CHECK(enet_peer_send(ev.peer, 1, unseq) == 0,
                          "server sends the unsequenced packet on channel 1");
                }
            } else if (ev.type == ENET_EVENT_TYPE_DISCONNECT) {
                serverSawDisconnect = true;
                CHECK(ev.data == 7, "server sees the disconnect data (7)");
            }
        }

        while (client && pump_one(client, &ev)) {
            progressed = 1;
            if (ev.type == ENET_EVENT_TYPE_CONNECT) {
                clientConnected = true;
                ENetPacket *hello = enet_packet_create(
                    kHello, std::strlen(kHello), ENET_PACKET_FLAG_RELIABLE);
                CHECK(enet_peer_send(clientPeer, 0, hello) == 0,
                      "client sends reliable hello on connect");
            } else if (ev.type == ENET_EVENT_TYPE_RECEIVE) {
                std::string body(reinterpret_cast<char *>(ev.packet->data),
                                 ev.packet->dataLength);
                enet_packet_destroy(ev.packet);
                if (body == kEcho) {
                    gotEcho = true;
                    CHECK(ev.channelID == 0, "echo arrived on channel 0");
                } else if (body == kUnseq) {
                    gotUnseq = true;
                    CHECK(ev.channelID == 1, "unsequenced arrived on channel 1");
                }
                if (gotEcho && gotUnseq) {
                    enet_peer_disconnect(clientPeer, 7);
                }
            } else if (ev.type == ENET_EVENT_TYPE_DISCONNECT) {
                clientSawDisconnect = true;
            }
        }

        if (serverSawDisconnect && clientSawDisconnect) {
            break;
        }
        if (!progressed) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    CHECK(clientConnected, "client saw CONNECT");
    CHECK(serverPeer != nullptr, "server saw CONNECT");
    CHECK(gotHello, "reliable hello arrived byte-for-byte");
    CHECK(gotEcho, "reliable echo arrived byte-for-byte");
    CHECK(gotUnseq, "unsequenced packet arrived");
    CHECK(clientSawDisconnect, "client saw DISCONNECT");
    CHECK(serverSawDisconnect, "server saw DISCONNECT");

    if (client) {
        enet_host_destroy(client);
    }
    if (server) {
        enet_host_destroy(server);
    }
    CHECK(enx_deinitialize() == ENX_OK, "final enx_deinitialize");
    CHECK(enx_deinitialize() == ENX_OK, "extra deinitialize is a no-op");

    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
