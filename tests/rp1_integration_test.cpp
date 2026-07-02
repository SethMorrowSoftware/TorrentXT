/* rp1_integration_test.cpp - PROVE the rp1 peer-wire path end to end, in ONE
 * process, with NO OXT and NO second machine.
 *
 * The smoke test pins the rp1 FRAMING and the control paths, but it cannot reach
 * the actual on-wire behavior without a live peer. This test does: it drives
 * btx::test::rp1_loopback_selftest, which stands up TWO real libtorrent sessions
 * on loopback, attaches the actual rp1 plugin to each, adds the SAME metadata-less
 * phantom swarm to both, connects them directly (an explicit loopback
 * connect_peer, so no network is needed), waits for the rp1 handshake to negotiate
 * BOTH ways, sends one message from A, and confirms it arrives at B byte-for-byte.
 *
 * A pass proves the four things unit tests cannot: extended-handshake
 * negotiation, the tick() flush of a queued send, on_extended delivery, AND that
 * the phantom (no-metadata) connection actually holds long enough to talk. */
#include "../src/torrent_shim.h"

#include <cstdio>
#include <string>

static std::string last_error() {
    char buf[512];
    int n = btx_last_error(buf, static_cast<int>(sizeof buf));
    return (n > 0) ? std::string(buf, static_cast<size_t>(n)) : std::string();
}

int main() {
    std::printf("rp1 loopback self-test: two in-process sessions on loopback...\n");
    std::fflush(stdout);
    /* Generous cap: the per-peer tick that flushes the send runs about once a
     * second, and a slow CI runner needs a little room. A local run completes in
     * ~3 s. */
    int r = btx::test::rp1_loopback_selftest(20000);
    if (r == 1) {
        std::printf("PASS: an rp1 message was delivered A -> B over the phantom swarm.\n");
        return 0;
    }
    std::printf("FAIL: %s\n", last_error().c_str());
    return 1;
}
