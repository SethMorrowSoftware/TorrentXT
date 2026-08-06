/* enet_shim.cpp — the flat extern "C" facade over ENet (Phase 1: the full
 * Part III.4 surface).
 *
 * The three family rules, in this binding's shape:
 *
 *   1. NEVER call script from a foreign thread — trivially satisfied: ENet
 *      has NO threads. The flip side is PUMP-OR-NOTHING: nothing connects,
 *      sends, or receives unless enx_poll services the host. The drain here
 *      IS the transport's heartbeat; its cadence is the latency floor.
 *
 *   2. THE EXCEPTION FIREWALL — every enx_* body runs inside ENX_GUARD_*
 *      (see enx_abi.h; the macro comment carries the two paid-for sibling
 *      lessons: one declaration per line, and no preprocessor directive
 *      inside a guard body).
 *
 *   3. PAYLOAD CROSSES BY DESIGN (a packet IS the message) but bounded:
 *      ENX_MAX_MESSAGE both ways — outbound refused loudly, oversized
 *      inbound dropped WHOLE with an E_ERROR event. Bulk belongs to
 *      TorrentXT.
 *
 * THE LOSSLESS PARTIAL DRAIN (this binding's one novel structure): the drain
 * loops enet_host_service(host, &e, 0) and encodes each event into the caller
 * buffer. When an encoded event no longer fits, it goes into the host's
 * ONE-SLOT STASH and the pump STOPS — every event not yet serviced simply
 * stays queued inside ENet, and the stashed one is emitted first on the next
 * poll. No event is ever dropped or reordered, whatever the buffer size
 * (ShowControl's never-drop rule, without datachannelxt's bounded queue,
 * because here WE control when events materialize).
 *
 * Handle lifecycle: hosts and peers ride gen-tagged tables (stale = no-op).
 * A peer handle is born in enx_connect (outgoing) or at the drain that writes
 * its E_CONNECT (incoming), rides in ENetPeer.data as an int, and is retired
 * when its E_DISCONNECT is drained (or immediately on disconnect_now/reset,
 * which ENet defines as event-less). After retirement every use is a no-op.
 *
 * ENet's headers are SYSTEM headers to us (-isystem); our code holds
 * -Wall -Wextra clean. */

#include "enx_abi.h"
#include "enx_record.h"
#include "enx_handle_table.h"

#include <enet/enet.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

/* Our EPS_* registry MIRRORS ENetPeerState; assert against the real header so
 * an upstream renumbering cannot skew the LCB constants silently. */
static_assert(enx::EPS_DISCONNECTED == static_cast<int>(ENET_PEER_STATE_DISCONNECTED) &&
              enx::EPS_CONNECTING == static_cast<int>(ENET_PEER_STATE_CONNECTING) &&
              enx::EPS_ACKNOWLEDGING_CONNECT == static_cast<int>(ENET_PEER_STATE_ACKNOWLEDGING_CONNECT) &&
              enx::EPS_CONNECTION_PENDING == static_cast<int>(ENET_PEER_STATE_CONNECTION_PENDING) &&
              enx::EPS_CONNECTION_SUCCEEDED == static_cast<int>(ENET_PEER_STATE_CONNECTION_SUCCEEDED) &&
              enx::EPS_CONNECTED == static_cast<int>(ENET_PEER_STATE_CONNECTED) &&
              enx::EPS_DISCONNECT_LATER == static_cast<int>(ENET_PEER_STATE_DISCONNECT_LATER) &&
              enx::EPS_DISCONNECTING == static_cast<int>(ENET_PEER_STATE_DISCONNECTING) &&
              enx::EPS_ACKNOWLEDGE_DISCONNECT == static_cast<int>(ENET_PEER_STATE_ACKNOWLEDGING_DISCONNECT) &&
              enx::EPS_ZOMBIE == static_cast<int>(ENET_PEER_STATE_ZOMBIE),
              "enx::PeerState must mirror ENetPeerState");
/* Payload fields must fit the u16 field length with framing to spare. */
static_assert(ENX_MAX_MESSAGE <= 0xFFFF - 64, "budget must fit a u16 field");

namespace {

/* Everything runs on the engine's single script thread (ENet is threadless
 * and this shim spawns nothing), so module state is unguarded by design. */
std::string g_last_error;

void set_error(const std::string &msg) { g_last_error = msg; }

int g_init_count = 0;

/* One drained-but-unwritten event: [type:u16][bodyLen:u16][kvrecord] bytes,
 * already fully encoded. Emitted before any pumping on the next poll. */
struct Stash {
    bool present = false;
    std::vector<uint8_t> entry;
};

struct HostState {
    ENetHost *host = nullptr;
    Stash stash;
};

struct PeerRef {
    ENetPeer *peer = nullptr;
    int hostHandle = 0;
};

enx::HandleTable<HostState> g_hosts;
enx::HandleTable<PeerRef>   g_peers;

int fill_out(const std::string &s, char *out, int cap) {
    const int need = static_cast<int>(s.size()) + 1;
    if (!out || cap < need) {
        return -need;
    }
    std::memcpy(out, s.c_str(), static_cast<size_t>(need));
    return need - 1;
}

/* "a.b.c.d:port" for a peer/bound-socket address; "" if unresolvable. */
std::string address_string(const ENetAddress &addr) {
    char ip[64];
    if (enet_address_get_host_ip(&addr, ip, sizeof ip) != 0) {
        return std::string();
    }
    char buf[80];
    std::snprintf(buf, sizeof buf, "%s:%u", ip, static_cast<unsigned>(addr.port));
    return std::string(buf);
}

/* The peer handle stored in ENetPeer.data (0 = none). intptr through void*. */
int peer_handle_of(const ENetPeer *p) {
    return static_cast<int>(reinterpret_cast<intptr_t>(p->data));
}
void set_peer_handle(ENetPeer *p, int h) {
    p->data = reinterpret_cast<void *>(static_cast<intptr_t>(h));
}

/* Retire a peer handle (idempotent): clear the ENet-side backlink and free
 * the slot so every later use of the handle is a harmless no-op. */
void retire_peer(int handle) {
    PeerRef *ref = g_peers.get(handle);
    if (!ref) {
        return;
    }
    if (ref->peer && peer_handle_of(ref->peer) == handle) {
        set_peer_handle(ref->peer, 0);
    }
    g_peers.free(handle);
}

/* Map OUR SendFlag to ENet packet flags. Unreliable-sequenced is ENet's
 * zero-flag default; reliable and unsequenced are explicit bits. */
bool send_flags_to_enet(int flags, enet_uint32 &out) {
    switch (flags) {
        case enx::SF_RELIABLE:    out = ENET_PACKET_FLAG_RELIABLE;    return true;
        case enx::SF_UNRELIABLE:  out = 0;                            return true;
        case enx::SF_UNSEQUENCED: out = ENET_PACKET_FLAG_UNSEQUENCED; return true;
        default: return false;
    }
}

/* What one encoded event means beyond its bytes: its drain type, and the peer
 * handle to retire AFTER the caller decides stash-vs-write (DISCONNECT only). */
struct EventMeta {
    uint16_t type = 0;
    int retire = 0;
};

/* Write one drained ENetEvent's kvrecord body into `w` and fill `meta`.
 * Called twice per event (measure, then write); the incoming-peer handle
 * birth happens on the FIRST call and is read back on the second, so both
 * passes emit identical bytes. */
void build_event_body(int hostHandle, ENetEvent &ev, enx::RecordWriter &w,
                      EventMeta &meta) {
    switch (ev.type) {
        case ENET_EVENT_TYPE_CONNECT: {
            meta.type = enx::E_CONNECT;
            int ph = peer_handle_of(ev.peer);
            if (ph == 0) {
                /* Incoming peer: the handle is born here, in the event that
                 * announces it — script learns the id from this record. */
                PeerRef ref;
                ref.peer = ev.peer;
                ref.hostHandle = hostHandle;
                ph = g_peers.alloc(ref);
                set_peer_handle(ev.peer, ph);
            }
            enx::KVRecord r(w);
            r.put_int(enx::F_EN_HOST, hostHandle);
            r.put_int(enx::F_EN_PEER, ph);
            r.put_str(enx::F_EN_ADDRESS, address_string(ev.peer->address));
            r.put_uint(enx::F_EN_DATA, ev.data);
            r.finish();
            break;
        }
        case ENET_EVENT_TYPE_DISCONNECT: {
            meta.type = enx::E_DISCONNECT;
            const int ph = peer_handle_of(ev.peer);
            enx::KVRecord r(w);
            r.put_int(enx::F_EN_HOST, hostHandle);
            r.put_int(enx::F_EN_PEER, ph);
            r.put_uint(enx::F_EN_DATA, ev.data);
            r.finish();
            meta.retire = ph;
            break;
        }
        case ENET_EVENT_TYPE_RECEIVE: {
            const int ph = peer_handle_of(ev.peer);
            if (ev.packet->dataLength > ENX_MAX_MESSAGE) {
                /* Rule 3's inbound edge: dropped WHOLE, loudly. */
                meta.type = enx::E_ERROR;
                char msg[96];
                std::snprintf(msg, sizeof msg,
                              "inbound packet of %zu bytes exceeds the %d-byte budget; dropped",
                              ev.packet->dataLength, ENX_MAX_MESSAGE);
                enx::KVRecord r(w);
                r.put_int(enx::F_EN_HOST, hostHandle);
                r.put_int(enx::F_EN_PEER, ph);
                r.put_str(enx::F_EN_ERROR, msg);
                r.finish();
            } else {
                meta.type = enx::E_RECEIVE;
                enx::KVRecord r(w);
                r.put_int(enx::F_EN_HOST, hostHandle);
                r.put_int(enx::F_EN_PEER, ph);
                r.put_int(enx::F_EN_CHANNEL, ev.channelID);
                r.put_bytes(enx::F_EN_PAYLOAD, ev.packet->data,
                            ev.packet->dataLength);
                r.finish();
            }
            break;
        }
        default:
            break;
    }
}

/* Encode one drained ENetEvent as a full drain entry
 * ([type:u16][bodyLen:u16][kvrecord]) into `out`, handling the side effects
 * that must ride along: incoming-peer handle birth, oversized-inbound
 * conversion to E_ERROR, and copy-then-destroy of the packet (never hold
 * ENet-owned bytes past this function). Returns the handle to retire for
 * DISCONNECT events (retired by the CALLER, after stash-vs-write), else 0. */
int encode_event(int hostHandle, ENetEvent &ev, std::vector<uint8_t> &out) {
    EventMeta meta;
    enx::RecordWriter measure(nullptr, 0);
    build_event_body(hostHandle, ev, measure, meta);
    const size_t bodyLen = measure.pos();

    out.resize(4 + bodyLen);
    enx::RecordWriter w(out.data() + 4, static_cast<int>(bodyLen));
    EventMeta metaW;
    build_event_body(hostHandle, ev, w, metaW);
    out[0] = static_cast<uint8_t>((metaW.type >> 8) & 0xFF);
    out[1] = static_cast<uint8_t>(metaW.type & 0xFF);
    out[2] = static_cast<uint8_t>((bodyLen >> 8) & 0xFF);
    out[3] = static_cast<uint8_t>(bodyLen & 0xFF);

    /* Copy-then-destroy: the payload is now in `out`; release ENet's copy. */
    if (ev.type == ENET_EVENT_TYPE_RECEIVE && ev.packet) {
        enet_packet_destroy(ev.packet);
        ev.packet = nullptr;
    }
    return metaW.retire;
}

} /* namespace */

/* ====================================================================== *
 *  Lifecycle & diagnostics (Phase 0 surface, carried)
 * ====================================================================== */

extern "C" ENX_API int ENX_CALL enx_abi_version(void) {
    return ENX_ABI_VERSION;
}

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

extern "C" ENX_API int ENX_CALL enx_deinitialize(void) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        if (g_init_count <= 0) {
            return ENX_OK;
        }
        --g_init_count;
        if (g_init_count == 0) {
            /* Destroy every live host (which retires its peers) so the app's
             * one mandatory teardown call cannot leak sockets. */
            std::vector<int> hosts;
            g_hosts.collect_live(hosts);
            for (int h : hosts) {
                HostState *hs = g_hosts.get(h);
                if (hs && hs->host) {
                    std::vector<int> peers;
                    g_peers.collect_live(peers);
                    for (int p : peers) {
                        PeerRef *ref = g_peers.get(p);
                        if (ref && ref->hostHandle == h) {
                            retire_peer(p);
                        }
                    }
                    enet_host_destroy(hs->host);
                }
                g_hosts.free(h);
            }
            enet_deinitialize();
        }
        return ENX_OK;
    });
}

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

extern "C" ENX_API int ENX_CALL enx_selftest_throw(void) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        throw std::runtime_error("enx firewall selftest");
    });
}

/* ====================================================================== *
 *  Hosts
 * ====================================================================== */

static int host_create_common(const ENetAddress *addr, int maxPeers,
                              int channels, int inBW, int outBW) {
    if (maxPeers < 1 || maxPeers > ENET_PROTOCOL_MAXIMUM_PEER_ID) {
        set_error("maxPeers must be 1..4095");
        return 0;
    }
    if (channels < 1 || channels > ENET_PROTOCOL_MAXIMUM_CHANNEL_COUNT) {
        set_error("channels must be 1..255");
        return 0;
    }
    if (g_init_count <= 0) {
        set_error("call enInitialize first");
        return 0;
    }
    ENetHost *h = enet_host_create(addr, static_cast<size_t>(maxPeers),
                                   static_cast<size_t>(channels),
                                   static_cast<enet_uint32>(inBW < 0 ? 0 : inBW),
                                   static_cast<enet_uint32>(outBW < 0 ? 0 : outBW));
    if (!h) {
        set_error("enet_host_create failed (port in use? too many sockets?)");
        return 0;
    }
    HostState hs;
    hs.host = h;
    const int handle = g_hosts.alloc(hs);
    if (handle == 0) {
        enet_host_destroy(h);
        set_error("host table exhausted");
        return 0;
    }
    return handle;
}

/* Bind and listen. pBindHost "" or "*" binds every interface. Returns a host
 * handle, 0 on failure (see enx_last_error). */
extern "C" ENX_API int ENX_CALL enx_host_create_server(const char *bindHost,
                                                       int port, int maxPeers,
                                                       int channels, int inBW,
                                                       int outBW) {
    ENX_GUARD_INT(0, {
        if (port < 0 || port > 65535) {
            set_error("port must be 0..65535");
            return 0;
        }
        ENetAddress addr;
        addr.port = static_cast<enet_uint16>(port);
        if (!bindHost || !*bindHost || std::strcmp(bindHost, "*") == 0) {
            addr.host = ENET_HOST_ANY;
        } else if (enet_address_set_host(&addr, bindHost) != 0) {
            set_error(std::string("cannot resolve bind host: ") + bindHost);
            return 0;
        }
        return host_create_common(&addr, maxPeers, channels, inBW, outBW);
    });
}

/* An unbound (client) host: it can only initiate connections. */
extern "C" ENX_API int ENX_CALL enx_host_create_client(int maxPeers,
                                                       int channels, int inBW,
                                                       int outBW) {
    ENX_GUARD_INT(0, {
        return host_create_common(nullptr, maxPeers, channels, inBW, outBW);
    });
}

/* Destroy a host and retire every peer riding it. Idempotent: a stale handle
 * is a successful no-op. */
extern "C" ENX_API int ENX_CALL enx_host_destroy(int host) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        HostState *hs = g_hosts.get(host);
        if (!hs) {
            return ENX_OK;
        }
        std::vector<int> peers;
        g_peers.collect_live(peers);
        for (int p : peers) {
            PeerRef *ref = g_peers.get(p);
            if (ref && ref->hostHandle == host) {
                retire_peer(p);
            }
        }
        if (hs->host) {
            enet_host_destroy(hs->host);
        }
        g_hosts.free(host);
        return ENX_OK;
    });
}

/* ====================================================================== *
 *  Peers: connect / disconnect / send
 * ====================================================================== */

/* Begin an outgoing connection; the peer handle is returned NOW (born
 * optimistically) and E_CONNECT confirms it later — or E_DISCONNECT reports
 * the failure (ENet signals a timed-out connect as a disconnect event). */
extern "C" ENX_API int ENX_CALL enx_connect(int host, const char *remoteHost,
                                            int port, int channels,
                                            int data) {
    ENX_GUARD_INT(0, {
        HostState *hs = g_hosts.get(host);
        if (!hs || !hs->host) {
            set_error("stale host handle");
            return 0;
        }
        if (!remoteHost || !*remoteHost) {
            set_error("remote host must not be empty");
            return 0;
        }
        if (port < 1 || port > 65535) {
            set_error("port must be 1..65535");
            return 0;
        }
        if (channels < 1 || channels > ENET_PROTOCOL_MAXIMUM_CHANNEL_COUNT) {
            set_error("channels must be 1..255");
            return 0;
        }
        ENetAddress addr;
        addr.port = static_cast<enet_uint16>(port);
        /* NOTE: this resolves DNS synchronously and may block briefly — the
         * documented Part III caveat; resolve in script or pass an IP when
         * that matters. */
        if (enet_address_set_host(&addr, remoteHost) != 0) {
            set_error(std::string("cannot resolve host: ") + remoteHost);
            return 0;
        }
        ENetPeer *p = enet_host_connect(hs->host, &addr,
                                        static_cast<size_t>(channels),
                                        static_cast<enet_uint32>(data));
        if (!p) {
            set_error("enet_host_connect failed (peer table full)");
            return 0;
        }
        PeerRef ref;
        ref.peer = p;
        ref.hostHandle = host;
        const int handle = g_peers.alloc(ref);
        if (handle == 0) {
            enet_peer_reset(p);
            set_error("peer table exhausted");
            return 0;
        }
        set_peer_handle(p, handle);
        return handle;
    });
}

/* Polite disconnect: the far side is told, and OUR E_DISCONNECT arrives via
 * the drain (which is when the handle retires). */
extern "C" ENX_API int ENX_CALL enx_disconnect(int peer, int data) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        PeerRef *ref = g_peers.get(peer);
        if (!ref || !ref->peer) {
            set_error("stale peer handle");
            return ENX_ERR_STALE;
        }
        enet_peer_disconnect(ref->peer, static_cast<enet_uint32>(data));
        return ENX_OK;
    });
}

/* Abrupt disconnect: ENet defines these as EVENT-LESS on our side (the far
 * side may still learn), so the handle retires immediately. */
extern "C" ENX_API int ENX_CALL enx_disconnect_now(int peer, int data) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        PeerRef *ref = g_peers.get(peer);
        if (!ref || !ref->peer) {
            set_error("stale peer handle");
            return ENX_ERR_STALE;
        }
        enet_peer_disconnect_now(ref->peer, static_cast<enet_uint32>(data));
        retire_peer(peer);
        return ENX_OK;
    });
}

extern "C" ENX_API int ENX_CALL enx_reset_peer(int peer) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        PeerRef *ref = g_peers.get(peer);
        if (!ref || !ref->peer) {
            set_error("stale peer handle");
            return ENX_ERR_STALE;
        }
        enet_peer_reset(ref->peer);
        retire_peer(peer);
        return ENX_OK;
    });
}

static ENetPacket *make_packet(const void *data, int len, int flags,
                               int &err) {
    if (len < 0 || (len > 0 && !data)) {
        err = ENX_ERR_ARG;
        return nullptr;
    }
    if (len > ENX_MAX_MESSAGE) {
        err = ENX_ERR_TOO_LARGE;
        return nullptr;
    }
    enet_uint32 ef = 0;
    if (!send_flags_to_enet(flags, ef)) {
        err = ENX_ERR_ARG;
        return nullptr;
    }
    /* Default create COPIES the bytes (never NO_ALLOCATE — the caller's
     * buffer dies at return). */
    ENetPacket *pk = enet_packet_create(data, static_cast<size_t>(len), ef);
    if (!pk) {
        err = ENX_ERR_NATIVE;
    }
    return pk;
}

/* Queue one packet to one peer. Delivery needs pumping (enx_poll / enx_flush). */
extern "C" ENX_API int ENX_CALL enx_send(int peer, int channel,
                                         const void *data, int len,
                                         int flags) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        PeerRef *ref = g_peers.get(peer);
        if (!ref || !ref->peer) {
            set_error("stale peer handle");
            return ENX_ERR_STALE;
        }
        if (channel < 0 ||
            static_cast<size_t>(channel) >= ref->peer->channelCount) {
            set_error("channel out of range for this peer");
            return ENX_ERR_ARG;
        }
        int err = ENX_ERR_GENERIC;
        ENetPacket *pk = make_packet(data, len, flags, err);
        if (!pk) {
            set_error(err == ENX_ERR_TOO_LARGE
                          ? "message exceeds the 60000-byte budget"
                          : "bad send arguments");
            return err;
        }
        if (enet_peer_send(ref->peer, static_cast<enet_uint8>(channel), pk) != 0) {
            enet_packet_destroy(pk);  /* send refused -> still ours to free */
            set_error("enet_peer_send refused (peer not connected?)");
            return ENX_ERR_NATIVE;
        }
        return ENX_OK;
    });
}

/* Queue one packet to EVERY connected peer of the host. */
extern "C" ENX_API int ENX_CALL enx_broadcast(int host, int channel,
                                              const void *data, int len,
                                              int flags) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        HostState *hs = g_hosts.get(host);
        if (!hs || !hs->host) {
            set_error("stale host handle");
            return ENX_ERR_STALE;
        }
        if (channel < 0 ||
            static_cast<size_t>(channel) >= hs->host->channelLimit) {
            set_error("channel out of range for this host");
            return ENX_ERR_ARG;
        }
        int err = ENX_ERR_GENERIC;
        ENetPacket *pk = make_packet(data, len, flags, err);
        if (!pk) {
            set_error(err == ENX_ERR_TOO_LARGE
                          ? "message exceeds the 60000-byte budget"
                          : "bad send arguments");
            return err;
        }
        enet_host_broadcast(hs->host, static_cast<enet_uint8>(channel), pk);
        return ENX_OK;
    });
}

/* Push queued packets onto the wire NOW, without servicing inbound. */
extern "C" ENX_API int ENX_CALL enx_flush(int host) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        HostState *hs = g_hosts.get(host);
        if (!hs || !hs->host) {
            set_error("stale host handle");
            return ENX_ERR_STALE;
        }
        enet_host_flush(hs->host);
        return ENX_OK;
    });
}

/* ====================================================================== *
 *  Tuning
 * ====================================================================== */

extern "C" ENX_API int ENX_CALL enx_set_peer_timeout(int peer, int limit,
                                                     int minimumMs,
                                                     int maximumMs) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        PeerRef *ref = g_peers.get(peer);
        if (!ref || !ref->peer) {
            set_error("stale peer handle");
            return ENX_ERR_STALE;
        }
        enet_peer_timeout(ref->peer,
                          static_cast<enet_uint32>(limit < 0 ? 0 : limit),
                          static_cast<enet_uint32>(minimumMs < 0 ? 0 : minimumMs),
                          static_cast<enet_uint32>(maximumMs < 0 ? 0 : maximumMs));
        return ENX_OK;
    });
}

extern "C" ENX_API int ENX_CALL enx_set_peer_ping_interval(int peer, int ms) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        PeerRef *ref = g_peers.get(peer);
        if (!ref || !ref->peer) {
            set_error("stale peer handle");
            return ENX_ERR_STALE;
        }
        enet_peer_ping_interval(ref->peer,
                                static_cast<enet_uint32>(ms < 0 ? 0 : ms));
        return ENX_OK;
    });
}

extern "C" ENX_API int ENX_CALL enx_set_host_bandwidth(int host, int inBW,
                                                       int outBW) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        HostState *hs = g_hosts.get(host);
        if (!hs || !hs->host) {
            set_error("stale host handle");
            return ENX_ERR_STALE;
        }
        enet_host_bandwidth_limit(hs->host,
                                  static_cast<enet_uint32>(inBW < 0 ? 0 : inBW),
                                  static_cast<enet_uint32>(outBW < 0 ? 0 : outBW));
        return ENX_OK;
    });
}

/* ====================================================================== *
 *  Status records
 * ====================================================================== */

/* One kvrecord of the peer's live stats. Returns bytes written, -needed, or
 * 0 for a stale handle (empty record = "gone", never an error). */
extern "C" ENX_API int ENX_CALL enx_peer_status(int peer, void *out, int cap) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        PeerRef *ref = g_peers.get(peer);
        if (!ref || !ref->peer) {
            return 0;
        }
        ENetPeer *p = ref->peer;
        enx::RecordWriter w(out, cap);
        enx::KVRecord r(w);
        r.put_int(enx::F_EN_HOST, ref->hostHandle);
        r.put_int(enx::F_EN_PEER, peer);
        r.put_str(enx::F_EN_ADDRESS, address_string(p->address));
        r.put_int(enx::F_EN_STATE, static_cast<int>(p->state));
        r.put_uint(enx::F_EN_RTT, p->roundTripTime);
        r.put_real(enx::F_EN_PACKET_LOSS,
                   static_cast<double>(p->packetLoss) /
                       static_cast<double>(ENET_PEER_PACKET_LOSS_SCALE));
        r.put_uint(enx::F_EN_PACKETS_SENT, p->packetsSent);
        r.put_uint(enx::F_EN_PACKETS_LOST, p->packetsLost);
        r.put_uint(enx::F_EN_BYTES_SENT, p->outgoingDataTotal);
        r.put_uint(enx::F_EN_BYTES_RECEIVED, p->incomingDataTotal);
        r.finish();
        if (w.overflow()) {
            return -static_cast<int>(w.pos());
        }
        return static_cast<int>(w.pos());
    });
}

/* One kvrecord of the host's shape: handle, bound address, connected peers. */
extern "C" ENX_API int ENX_CALL enx_host_status(int host, void *out, int cap) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        HostState *hs = g_hosts.get(host);
        if (!hs || !hs->host) {
            return 0;
        }
        enx::RecordWriter w(out, cap);
        enx::KVRecord r(w);
        r.put_int(enx::F_EN_HOST, host);
        r.put_str(enx::F_EN_ADDRESS, address_string(hs->host->address));
        r.put_uint(enx::F_EN_PEER_COUNT, hs->host->connectedPeers);
        r.finish();
        if (w.overflow()) {
            return -static_cast<int>(w.pos());
        }
        return static_cast<int>(w.pos());
    });
}

/* ====================================================================== *
 *  The drain
 * ====================================================================== */

/* Pump the host and fill `out` with drain entries:
 *   [eventCount:u16] then eventCount x [type:u16][bodyLen:u16][kvrecord]
 * Returns the EVENT COUNT (not bytes — the walker reads each bodyLen), or
 * -needed when not even one event fits (grow and retry), or an ENX_ERR_* on a
 * bad handle. Lossless at every buffer size: an encoded event that does not
 * fit waits in the one-slot stash, everything else stays queued inside ENet
 * until the next pump. */
extern "C" ENX_API int ENX_CALL enx_poll(int host, void *out, int cap) {
    ENX_GUARD_INT(ENX_ERR_THROWN, {
        HostState *hs = g_hosts.get(host);
        if (!hs || !hs->host) {
            set_error("stale host handle");
            return ENX_ERR_STALE;
        }
        if (!out || cap < 2) {
            return -(2 + 64);  /* nonsense buffer: ask for a sane minimum */
        }
        uint8_t *buf = static_cast<uint8_t *>(out);
        size_t used = 2;  /* count backpatched at the end */
        int count = 0;

        /* The stash goes first — it was drained from ENet on a previous poll
         * and must precede anything pumped now (never reorder). */
        if (hs->stash.present) {
            const std::vector<uint8_t> &e = hs->stash.entry;
            if (used + e.size() > static_cast<size_t>(cap)) {
                return -static_cast<int>(2 + e.size());
            }
            std::memcpy(buf + used, e.data(), e.size());
            used += e.size();
            ++count;
            hs->stash.present = false;
        }

        ENetEvent ev;
        while (enet_host_service(hs->host, &ev, 0) > 0) {
            if (ev.type == ENET_EVENT_TYPE_NONE) {
                continue;
            }
            std::vector<uint8_t> entry;
            const int retire = encode_event(host, ev, entry);
            if (used + entry.size() <= static_cast<size_t>(cap)) {
                std::memcpy(buf + used, entry.data(), entry.size());
                used += entry.size();
                ++count;
            } else {
                /* Stash it and STOP pumping: unserviced events stay inside
                 * ENet; nothing is lost, nothing reorders. */
                hs->stash.present = true;
                hs->stash.entry.swap(entry);
                if (retire != 0) {
                    retire_peer(retire);
                }
                if (count == 0) {
                    /* Not even one event fit: hand back the exact need so
                     * the LCB layer can grow and re-poll. */
                    return -static_cast<int>(2 + hs->stash.entry.size());
                }
                break;
            }
            if (retire != 0) {
                retire_peer(retire);
            }
        }

        buf[0] = static_cast<uint8_t>((count >> 8) & 0xFF);
        buf[1] = static_cast<uint8_t>(count & 0xFF);
        return count;
    });
}
