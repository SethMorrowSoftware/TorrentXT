# x86_64-linux/torrentxt.so is NOT auto-committed by CI (yet)

The 64-bit Linux native library is intentionally absent here. The CI lane builds it
against the apt system libtorrent, which leaves a dynamic `NEEDED` dependency on
`libtorrent-rasterbar.so.2.0` - so the artifact only loads on a machine that already
has that dev package installed, which is not what a bundled extension promises.

To ship a self-contained 64-bit Linux lib, build the lane with a **statically
linked** libtorrent (as the 32-bit `x86-linux` lane already does, via FetchContent
at the pinned v2.0.11) so `readelf -d` shows no `libtorrent` NEEDED entry;
`commit-binaries` then picks it up automatically. See `docs/building.md`. Stage a
local build with:

    python3 tools/package-extension.py --platform-id x86_64-linux --lib <path>/torrentxt.so
