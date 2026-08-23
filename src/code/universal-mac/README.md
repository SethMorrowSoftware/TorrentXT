# universal-mac/torrentxt.dylib is NOT auto-committed by CI

The macOS native library is intentionally absent here. CI builds the macOS lane on
the host arch (arm64) against Homebrew, which yields a THIN, Homebrew-linked dylib
(`/opt/homebrew/opt/libtorrent-rasterbar/...`) that fails to load on Intel Macs, or
on any Mac without those exact Homebrew formulae - so it is not distributable.

The shipped library must be a **universal** (arm64 + x86_64), self-contained
dylib. Since 2026-08-23 `release-binaries.yml`'s `mac-lipo` job builds exactly
that: each slice thin against a per-arch build of the pinned static OpenSSL,
both slices tested (arm64 natively, x86_64 under Rosetta), `lipo -create`, and
the slice table asserted at birth and again by the installer. The dylib ships
with the linker's ad-hoc signature only - the owner accepted unsigned
distribution on 2026-08-23, so **codesign + notarize is no longer a blocker**,
just an absent nicety (the credentials CI does not hold); a browser-downloaded
copy needs its quarantine attribute cleared, a git checkout does not. A manual
build per `docs/building.md`'s "macOS - universal + codesign/notarize" section
remains equivalent; stage either with:

    python3 tools/package-extension.py --platform-id universal-mac --lib <path>/torrentxt.dylib
