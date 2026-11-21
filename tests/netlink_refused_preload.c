/* netlink_refused_preload.c - Android 11's rule for an app, on a Linux build
 * machine: an LD_PRELOAD library under which a NETLINK_ROUTE socket can be
 * neither bound nor asked for the machine's links.
 *
 * WHY THIS EXISTS. It is the FIXTURE for one row of torrent_smoke_test.cpp,
 * test_local_torrent_seeds ("a session is not paused at birth, listens, and
 * checks a local file to seeding"). That row was written after a torrentxt
 * built for Android API 21 stalled inside an app on Android 13 (2026-11-21),
 * and on every machine the suite tests on it passes, as it should. A check
 * that has only ever passed has not been shown to see anything (root
 * CLAUDE.md: fixture before gate). So CMake runs that one row a second time
 * under this library (the test torrent_smoke_netlink_refused) and requires
 * it to FAIL, on exactly the checks the Android failure breaks.
 *
 * WHAT IT REFUSES, and why these two. From Android 11, an app that targets
 * API 30 or later is refused, by SELinux, two things on a NETLINK_ROUTE
 * socket: bind() (the `bind` permission on netlink_route_socket) and the
 * RTM_GETLINK request (`nlmsg_readpriv`). Both come back EACCES. libtorrent
 * built the Linux way does both: it binds such a socket to watch for address
 * changes, and it sends RTM_GETLINK to list the interfaces. As observed
 * under this library on 2026-11-21 with libtorrent 2.0.11 on x86_64 Linux:
 * the refused bind leaves the session PAUSED from birth (the torrent sits in
 * "checking files" at progress 0 with no error, which is what the Android
 * app showed), and the refused RTM_GETLINK leaves "listen on 0.0.0.0" with
 * no socket. Everything else passes through untouched.
 *
 * WHAT IT IS NOT. It is not Android: it shows what libtorrent does when
 * those two calls are refused, not that Android refuses them (that half is
 * Android's documented behaviour and the `avc: denied` lines of the emulator
 * log). And it says nothing against the Linux library, which no desktop
 * refuses a netlink socket. It is never linked into anything that ships.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>

int bind(int fd, const struct sockaddr *addr, socklen_t len) {
    static int (*real)(int, const struct sockaddr *, socklen_t);
    if (!real) real = (int (*)(int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "bind");
    if (addr && addr->sa_family == AF_NETLINK) {
        errno = EACCES;
        return -1;
    }
    return real(fd, addr, len);
}

/* An RTM_GETLINK request about to leave on a netlink socket? */
static int refused(int fd, const void *buf, size_t n) {
    const struct nlmsghdr *h = (const struct nlmsghdr *)buf;
    struct sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    if (!buf || n < sizeof *h || h->nlmsg_type != RTM_GETLINK) return 0;
    return getsockname(fd, (struct sockaddr *)&ss, &sl) == 0 && ss.ss_family == AF_NETLINK;
}

ssize_t send(int fd, const void *buf, size_t n, int flags) {
    static ssize_t (*real)(int, const void *, size_t, int);
    if (!real) real = (ssize_t (*)(int, const void *, size_t, int))dlsym(RTLD_NEXT, "send");
    if (refused(fd, buf, n)) {
        errno = EACCES;
        return -1;
    }
    return real(fd, buf, n, flags);
}

ssize_t sendto(int fd, const void *buf, size_t n, int flags,
               const struct sockaddr *to, socklen_t tolen) {
    static ssize_t (*real)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
    if (!real) real = (ssize_t (*)(int, const void *, size_t, int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "sendto");
    if (refused(fd, buf, n)) {
        errno = EACCES;
        return -1;
    }
    return real(fd, buf, n, flags, to, tolen);
}
