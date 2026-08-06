/* enet_smoke_test.cpp — the Phase 1 gate: drive the ENTIRE exported enx_ ABI
 * over a real one-process loopback, in the family's smoke-test dialect
 * (CHECK-counted, exit 1 on any failure, run under ASan/UBSan in CI and while
 * iterating).
 *
 * Everything goes through the shared library's entry points — hosts, connect,
 * send/broadcast/flush, tuning, status records, and the enx_poll drain, whose
 * records are walked with the same byte arithmetic the LCB walker uses. The
 * Phase 0 spike's raw-ENet scenario is reproduced here through the wrap
 * (supersedes tests/enet_spike_test.cpp), plus the Phase 1 contracts:
 * handle safety everywhere, the 60000-byte budget refused loudly, the
 * lossless partial drain (tiny buffer -> -needed -> stash -> order preserved),
 * and event-time handle birth/retirement. */

#include "../src/enx_abi.h"
#include "../src/enx_record.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <vector>

extern "C" {
int enx_abi_version(void);
int enx_initialize(void);
int enx_deinitialize(void);
int enx_version_string(char *out, int cap);
int enx_last_error(char *out, int cap);
void enx_clear_error(void);
int enx_selftest_throw(void);
int enx_host_create_server(const char *bindHost, int port, int maxPeers,
                           int channels, int inBW, int outBW);
int enx_host_create_client(int maxPeers, int channels, int inBW, int outBW);
int enx_host_destroy(int host);
int enx_connect(int host, const char *remoteHost, int port, int channels,
                int data);
int enx_disconnect(int peer, int data);
int enx_disconnect_now(int peer, int data);
int enx_reset_peer(int peer);
int enx_send(int peer, int channel, const void *data, int len, int flags);
int enx_broadcast(int host, int channel, const void *data, int len, int flags);
int enx_flush(int host);
int enx_set_peer_timeout(int peer, int limit, int minimumMs, int maximumMs);
int enx_set_peer_ping_interval(int peer, int ms);
int enx_set_host_bandwidth(int host, int inBW, int outBW);
int enx_peer_status(int peer, void *out, int cap);
int enx_host_status(int host, void *out, int cap);
int enx_poll(int host, void *out, int cap);
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

/* ---- drain walking, with the LCB walker's arithmetic --------------------- */

struct Ev {
    uint16_t type = 0;
    std::map<uint8_t, std::string> f;   /* fieldId -> raw value bytes */
    long long fint(uint8_t id) const {
        auto it = f.find(id);
        return it == f.end() ? 0 : std::strtoll(it->second.c_str(), nullptr, 10);
    }
    std::string fstr(uint8_t id) const {
        auto it = f.find(id);
        return it == f.end() ? std::string() : it->second;
    }
};

/* Parse a drain buffer ([count:u16] entries...) into events. Returns false on
 * malformed framing (which would itself be a bug worth failing loudly). */
static bool parse_drain(const uint8_t *buf, size_t len, int count,
                        std::vector<Ev> &out) {
    enx::RecordReader top(buf, len);
    if (top.bytes_left() < 2) return false;
    top.skip(2);
    for (int i = 0; i < count; ++i) {
        if (top.bytes_left() < 4) return false;
        Ev ev;
        ev.type = enx::RecordReader::rd_u16(top.cursor());
        top.skip(2);
        const uint16_t bodyLen = enx::RecordReader::rd_u16(top.cursor());
        top.skip(2);
        if (top.bytes_left() < bodyLen) return false;
        enx::RecordReader body(top.cursor(), bodyLen);
        std::vector<enx::Field> fields;
        if (!body.read_record(fields)) return false;
        for (const enx::Field &fl : fields) {
            ev.f[fl.id] = fl.text();
        }
        top.skip(bodyLen);
        out.push_back(ev);
    }
    return true;
}

/* Poll one host into `sink`, asserting the framing parses. Returns the count. */
static int drain_into(int host, std::vector<Ev> &sink) {
    static uint8_t buf[128 * 1024];
    const int n = enx_poll(host, buf, sizeof buf);
    if (n <= 0) {
        return n;
    }
    size_t used = sizeof buf;   /* parse_drain walks by counts, len is a cap */
    const bool ok = parse_drain(buf, used, n, sink);
    CHECK(ok, "drain framing parses");
    return n;
}

int main() {
    std::printf("enet_smoke_test: driving the full enx_ ABI over a live loopback\n");

    /* ---- lifecycle + firewall (Phase 0 carried) ------------------------- */
    CHECK(enx_abi_version() == ENX_ABI_VERSION, "abi version matches header");
    CHECK(enx_selftest_throw() == ENX_ERR_THROWN, "firewall converts a throw");
    {
        char err[128];
        CHECK(enx_last_error(err, sizeof err) > 0, "throw left a last-error");
        enx_clear_error();
        CHECK(enx_last_error(err, sizeof err) == 0, "clear empties last-error");
        char tiny[1];
        const int need = enx_version_string(tiny, 1);
        CHECK(need < 0, "version: short buffer refuses with -needed");
        std::string ver(static_cast<size_t>(-need), '\0');
        CHECK(enx_version_string(&ver[0], -need) > 0, "version: retry succeeds");
        CHECK(ver.compare(0, 5, "enet ") == 0, "version names enet");
    }
    CHECK(enx_initialize() == ENX_OK, "enx_initialize");

    /* ---- stale handles are harmless no-ops ------------------------------ */
    {
        uint8_t buf[256];
        CHECK(enx_send(0, 0, "x", 1, 0) == ENX_ERR_STALE, "send(0) is STALE");
        CHECK(enx_disconnect(0, 0) == ENX_ERR_STALE, "disconnect(0) is STALE");
        CHECK(enx_peer_status(0, buf, sizeof buf) == 0, "peer_status(0) empty");
        CHECK(enx_host_status(0, buf, sizeof buf) == 0, "host_status(0) empty");
        CHECK(enx_poll(0, buf, sizeof buf) == ENX_ERR_STALE, "poll(0) is STALE");
        CHECK(enx_host_destroy(0) == ENX_OK, "host_destroy(0) is a no-op OK");
        CHECK(enx_connect(0, "127.0.0.1", 1, 1, 0) == 0, "connect on stale host is 0");
        CHECK(enx_flush(0) == ENX_ERR_STALE, "flush(0) is STALE");
    }

    /* ---- hosts + connect ------------------------------------------------- */
    const int server = enx_host_create_server("127.0.0.1", 27099, 8, 2, 0, 0);
    CHECK(server > 0, "server host created");
    const int client = enx_host_create_client(1, 2, 0, 0);
    CHECK(client > 0, "client host created");
    CHECK(server != client, "host handles distinct");
    CHECK(enx_host_create_server("127.0.0.1", 27099, 8, 2, 0, 0) == 0,
          "second bind of the same port fails with 0");

    const int clientPeer = enx_connect(client, "127.0.0.1", 27099, 2, 42);
    CHECK(clientPeer > 0, "enx_connect returns a peer handle");

    /* Argument checks that need a live peer. */
    CHECK(enx_send(clientPeer, 5, "x", 1, 0) == ENX_ERR_ARG,
          "send on an out-of-range channel is ARG");
    CHECK(enx_send(clientPeer, 0, "x", 1, 99) == ENX_ERR_ARG,
          "send with a bogus flag is ARG");
    {
        static char big[ENX_MAX_MESSAGE + 1];
        CHECK(enx_send(clientPeer, 0, big, sizeof big, 0) == ENX_ERR_TOO_LARGE,
              "send over the budget is TOO_LARGE, never truncated");
    }

    /* ---- pump to connected ----------------------------------------------- */
    int serverPeer = 0;
    bool clientConnected = false;
    const char *kHello = "hello enet";
    const char *kEcho = "echo:hello enet";
    const char *kUnseq = "unseq ping";
    bool gotHello = false;
    bool gotEcho = false;
    bool gotUnseq = false;
    bool serverSawDisc = false;
    bool clientSawDisc = false;
    int helloEchoOrder = 0;   /* echo must follow hello (reliable ordering) */

    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        std::vector<Ev> evs;
        const int ns = drain_into(server, evs);
        const int nc = drain_into(client, evs);
        for (Ev &ev : evs) {
            if (ev.type == enx::E_CONNECT && ev.fint(enx::F_EN_HOST) == server) {
                serverPeer = static_cast<int>(ev.fint(enx::F_EN_PEER));
                CHECK(ev.fint(enx::F_EN_DATA) == 42,
                      "server E_CONNECT carries the connect data (42)");
                CHECK(ev.fstr(enx::F_EN_ADDRESS).find("127.0.0.1:") == 0,
                      "server E_CONNECT names the peer address");
            } else if (ev.type == enx::E_CONNECT &&
                       ev.fint(enx::F_EN_HOST) == client) {
                clientConnected = true;
                CHECK(ev.fint(enx::F_EN_PEER) == clientPeer,
                      "client E_CONNECT names the enx_connect handle");
                CHECK(enx_send(clientPeer, 0, kHello,
                               static_cast<int>(std::strlen(kHello)),
                               enx::SF_RELIABLE) == ENX_OK,
                      "client sends reliable hello");
            } else if (ev.type == enx::E_RECEIVE &&
                       ev.fint(enx::F_EN_HOST) == server) {
                const std::string body = ev.fstr(enx::F_EN_PAYLOAD);
                if (body == kHello) {
                    gotHello = true;
                    helloEchoOrder = 1;
                    CHECK(ev.fint(enx::F_EN_CHANNEL) == 0, "hello on channel 0");
                    CHECK(ev.fint(enx::F_EN_PEER) == serverPeer,
                          "hello names the server-side peer handle");
                    CHECK(enx_send(serverPeer, 0, kEcho,
                                   static_cast<int>(std::strlen(kEcho)),
                                   enx::SF_RELIABLE) == ENX_OK,
                          "server sends the reliable echo");
                    CHECK(enx_broadcast(server, 1, kUnseq,
                                        static_cast<int>(std::strlen(kUnseq)),
                                        enx::SF_UNSEQUENCED) == ENX_OK,
                          "server broadcasts unsequenced on channel 1");
                    CHECK(enx_flush(server) == ENX_OK, "flush after send");
                }
            } else if (ev.type == enx::E_RECEIVE &&
                       ev.fint(enx::F_EN_HOST) == client) {
                const std::string body = ev.fstr(enx::F_EN_PAYLOAD);
                if (body == kEcho) {
                    gotEcho = true;
                    CHECK(helloEchoOrder == 1, "echo follows hello");
                    CHECK(ev.fint(enx::F_EN_CHANNEL) == 0, "echo on channel 0");
                } else if (body == kUnseq) {
                    gotUnseq = true;
                    CHECK(ev.fint(enx::F_EN_CHANNEL) == 1, "broadcast on channel 1");
                }
            }
        }
        if (gotEcho && gotUnseq) {
            break;
        }
        if (ns == 0 && nc == 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    CHECK(clientConnected, "client connected");
    CHECK(serverPeer > 0, "server-side peer handle born in its E_CONNECT");
    CHECK(gotHello && gotEcho && gotUnseq, "all three payloads arrived");

    /* ---- status + tuning -------------------------------------------------- */
    {
        uint8_t buf[512];
        const int n = enx_peer_status(clientPeer, buf, sizeof buf);
        CHECK(n > 0, "peer_status returns a record");
        enx::RecordReader rr(buf, static_cast<size_t>(n));
        std::vector<enx::Field> fields;
        CHECK(rr.read_record(fields), "peer_status record parses");
        long long st = -1;
        std::string addr;
        long long hostField = 0;
        for (const enx::Field &fl : fields) {
            if (fl.id == enx::F_EN_STATE) st = fl.as_int();
            if (fl.id == enx::F_EN_ADDRESS) addr = fl.text();
            if (fl.id == enx::F_EN_HOST) hostField = fl.as_int();
        }
        CHECK(st == enx::EPS_CONNECTED, "peer state is CONNECTED (5)");
        CHECK(addr == "127.0.0.1:27099", "peer_status names the server address");
        CHECK(hostField == client, "peer_status names the owning host");

        const int hn = enx_host_status(server, buf, sizeof buf);
        CHECK(hn > 0, "host_status returns a record");
        enx::RecordReader hr(buf, static_cast<size_t>(hn));
        fields.clear();
        CHECK(hr.read_record(fields), "host_status record parses");
        long long peers = -1;
        for (const enx::Field &fl : fields) {
            if (fl.id == enx::F_EN_PEER_COUNT) peers = fl.as_int();
        }
        CHECK(peers == 1, "host_status counts one connected peer");

        char tiny2[4];
        CHECK(enx_peer_status(clientPeer, tiny2, sizeof tiny2) < 0,
              "peer_status short buffer refuses with -needed");
    }
    CHECK(enx_set_peer_timeout(clientPeer, 32, 1000, 4000) == ENX_OK, "peer timeout set");
    CHECK(enx_set_peer_ping_interval(clientPeer, 250) == ENX_OK, "ping interval set");
    CHECK(enx_set_host_bandwidth(server, 0, 0) == ENX_OK, "host bandwidth set");

    /* ---- the lossless partial drain --------------------------------------- */
    /* Three rapid packets server->client, then drain through a keyhole:
     * a buffer too small for even one entry must refuse with -needed; a
     * buffer sized for ONE entry must deliver exactly one per poll, stashing
     * the drained-but-unwritten event; order must hold end to end. */
    {
        const char *m[3] = {"m1", "m2", "m3"};
        for (int i = 0; i < 3; ++i) {
            CHECK(enx_send(serverPeer, 0, m[i], 2, enx::SF_RELIABLE) == ENX_OK,
                  "burst send");
        }
        enx_flush(server);
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        /* Let the client's socket see the datagrams; the keyhole polls below
         * do the actual draining. */
        uint8_t hole[2];
        const int refuse = enx_poll(client, hole, sizeof hole);
        CHECK(refuse < -2, "keyhole poll refuses with -needed");
        const int oneCap = -refuse;   /* exactly one entry + count header */
        std::vector<std::string> got;
        const auto d2 =
            std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (got.size() < 3 && std::chrono::steady_clock::now() < d2) {
            std::vector<uint8_t> buf(static_cast<size_t>(oneCap));
            const int n = enx_poll(client, buf.data(),
                                   static_cast<int>(buf.size()));
            if (n < 0) {
                /* A later entry can be a byte or two bigger (longer field
                 * values); grow to exactly what it asks and retry. */
                buf.resize(static_cast<size_t>(-n));
                continue;
            }
            if (n == 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            CHECK(n == 1, "keyhole poll delivers exactly one event");
            std::vector<Ev> evs;
            CHECK(parse_drain(buf.data(), buf.size(), n, evs), "keyhole parses");
            for (Ev &ev : evs) {
                if (ev.type == enx::E_RECEIVE) {
                    got.push_back(ev.fstr(enx::F_EN_PAYLOAD));
                }
            }
        }
        CHECK(got.size() == 3, "all three burst packets arrived through the keyhole");
        CHECK(got.size() == 3 && got[0] == "m1" && got[1] == "m2" && got[2] == "m3",
              "keyhole drain preserved order");
    }

    /* ---- disconnect + retirement ------------------------------------------ */
    CHECK(enx_disconnect(clientPeer, 7) == ENX_OK, "polite disconnect");
    {
        const auto d3 =
            std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while ((!serverSawDisc || !clientSawDisc) &&
               std::chrono::steady_clock::now() < d3) {
            std::vector<Ev> evs;
            drain_into(server, evs);
            drain_into(client, evs);
            for (Ev &ev : evs) {
                if (ev.type == enx::E_DISCONNECT &&
                    ev.fint(enx::F_EN_HOST) == server) {
                    serverSawDisc = true;
                    CHECK(ev.fint(enx::F_EN_DATA) == 7,
                          "server E_DISCONNECT carries the data (7)");
                    CHECK(ev.fint(enx::F_EN_PEER) == serverPeer,
                          "server E_DISCONNECT names its peer handle");
                } else if (ev.type == enx::E_DISCONNECT &&
                           ev.fint(enx::F_EN_HOST) == client) {
                    clientSawDisc = true;
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    CHECK(serverSawDisc && clientSawDisc, "both sides drained E_DISCONNECT");
    {
        uint8_t buf[256];
        CHECK(enx_peer_status(clientPeer, buf, sizeof buf) == 0,
              "client peer handle retired at drain");
        CHECK(enx_peer_status(serverPeer, buf, sizeof buf) == 0,
              "server peer handle retired at drain");
        CHECK(enx_send(clientPeer, 0, "x", 1, 0) == ENX_ERR_STALE,
              "send on a retired handle is STALE");
    }

    /* ---- abrupt paths: disconnect_now retires immediately ------------------ */
    {
        const int p2 = enx_connect(client, "127.0.0.1", 27099, 2, 0);
        CHECK(p2 > 0, "second connect for the abrupt path");
        CHECK(enx_disconnect_now(p2, 9) == ENX_OK, "disconnect_now");
        uint8_t buf[256];
        CHECK(enx_peer_status(p2, buf, sizeof buf) == 0,
              "disconnect_now retires the handle immediately");
        CHECK(enx_reset_peer(p2) == ENX_ERR_STALE,
              "reset on the retired handle is STALE");
    }

    /* ---- teardown ---------------------------------------------------------- */
    CHECK(enx_host_destroy(server) == ENX_OK, "server destroyed");
    CHECK(enx_host_destroy(server) == ENX_OK, "double destroy is a no-op");
    CHECK(enx_host_destroy(client) == ENX_OK, "client destroyed");
    CHECK(enx_deinitialize() == ENX_OK, "deinitialize");
    CHECK(enx_deinitialize() == ENX_OK, "extra deinitialize is a no-op");

    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
