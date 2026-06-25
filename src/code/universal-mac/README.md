# universal-mac/torrentxt.dylib is NOT auto-committed by CI

The macOS native library is intentionally absent here. CI builds the macOS lane on
the host arch (arm64) against Homebrew, which yields a THIN, Homebrew-linked dylib
(`/opt/homebrew/opt/libtorrent-rasterbar/...`) that fails to load on Intel Macs, or
on any Mac without those exact Homebrew formulae - so it is not distributable.

The shipped library must be a **universal** (arm64 + x86_64), self-contained,
**codesigned + notarized** dylib, produced by the release build (it owns the Apple
Developer credentials CI does not hold). See `docs/building.md`, section
"macOS - universal + codesign/notarize", then stage it with:

    python3 tools/package-extension.py --platform-id universal-mac --lib <path>/torrentxt.dylib
