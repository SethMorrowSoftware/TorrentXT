#!/usr/bin/env python3
"""package-extension.py - refresh the committed per-platform native library tree
(plan §7 "Bundle per platform", §11 layout; CLAUDE.md packaging rules).

WHAT IT DOES
    Copies a freshly built `torrentxt.{so,dll,dylib}` into the committed
    extension tree at:

        src/code/<arch>-<platform>/torrentxt.{so,dll,dylib}

    Installing the packaged extension makes the OXT engine resolve the
    `c:torrentxt>` binding automatically via `the revLibraryMapping` - no loose
    library, no sudo, no /usr/lib, no LD_LIBRARY_PATH, no rename. This script is
    how a CI build (or a developer) drops a new binary into that tree so the
    change is committed alongside the shim/.lcb change that motivated it
    (CLAUDE.md: "a native-library change is only done once package-extension.py
    has refreshed the committed binary in the same change").

THE FIVE PLATFORM-IDS (exact, ARCHITECTURE FIRST, Windows is -win32 for BOTH
bitnesses - do not invent variants):

        x86_64-linux   x86-linux   x86_64-win32   x86-win32   universal-mac

THE BARE-TOKEN NAME RULE
    The file is named with the bare token `torrentxt` (NO `lib` prefix) so it
    matches the binding string. A build that emitted `libtorrentxt.so` is wrong;
    this script copies to the bare-token name and will pick up either a bare or a
    lib-prefixed source file but always WRITES the bare-token destination.

USAGE
    # Auto-detect this host's platform-id, find the lib under a CMake build dir:
    python3 tools/package-extension.py --build-dir build

    # Be explicit (the cross-build / CI case):
    python3 tools/package-extension.py --platform-id x86_64-linux --build-dir build
    python3 tools/package-extension.py --platform-id universal-mac --lib out/torrentxt.dylib

    # Assemble the installable extension staging layout too (best-effort):
    python3 tools/package-extension.py --build-dir build --assemble

    # See what WOULD happen without writing:
    python3 tools/package-extension.py --build-dir build --dry-run

Idempotent: re-running with an identical binary reports "unchanged" and writes
nothing. Refuses an unknown --platform-id. Exit 0 on success, non-zero on error.
"""
import argparse
import hashlib
import os
import platform
import shutil
import sys

# ----------------------------------------------------------------- constants --
# The repo root is the parent of this tools/ directory; every path the script
# touches is resolved against it so the script works from any CWD.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODE_ROOT = os.path.join(REPO_ROOT, "src", "code")

# platform-id -> the shared-library file EXTENSION the engine expects there.
# (The committed file is always the bare token `torrentxt` + this suffix.)
PLATFORM_SUFFIX = {
    "x86_64-linux": ".so",
    "x86-linux": ".so",
    "x86_64-win32": ".dll",
    "x86-win32": ".dll",
    "universal-mac": ".dylib",
}
VALID_PLATFORM_IDS = sorted(PLATFORM_SUFFIX)

# Candidate source file BASENAMES we will look for in a build dir, in priority
# order: the bare token first (what our CMake emits), then the lib-prefixed form
# (in case a non-CMake build produced it) so we can still recover and rename to
# the bare token on copy.
def _candidate_basenames(suffix):
    return ["torrentxt" + suffix, "libtorrentxt" + suffix]


# ------------------------------------------------------------- host detection -
def detect_platform_id():
    """Best-effort platform-id for THIS host. Cross-builds should pass
    --platform-id explicitly; this only saves typing for the native case.
    Returns the id string, or None if the host does not map cleanly."""
    sysname = platform.system()
    machine = platform.machine().lower()

    if sysname == "Darwin":
        # We always ship ONE universal-mac binary (arm64;x86_64), regardless of
        # which Mac built it - so the host arch does not change the id.
        return "universal-mac"

    # Normalise the architecture token to our {x86_64, x86} vocabulary.
    is_64 = machine in ("x86_64", "amd64", "x64") or sys.maxsize > 2**32 and machine in ("aarch64", "arm64")
    if machine in ("x86_64", "amd64", "x64"):
        arch = "x86_64"
    elif machine in ("i386", "i686", "x86") or (machine == "" and not is_64):
        arch = "x86"
    elif sys.maxsize <= 2**32:
        # 32-bit Python on an unrecognised machine string -> assume x86.
        arch = "x86"
    else:
        arch = "x86_64"

    if sysname == "Linux":
        return "%s-linux" % arch
    if sysname == "Windows":
        # Windows is -win32 for BOTH bitnesses (the platform token, not the arch).
        return "%s-win32" % arch
    return None


# ----------------------------------------------------------------- helpers ----
def find_built_lib(build_dir, suffix):
    """Locate the freshly built library under `build_dir`. CMake may place it at
    the top level or under a per-config subdir (Debug/Release on multi-config
    generators), so walk the tree and return the first matching candidate, bare
    token preferred over lib-prefixed."""
    wanted = _candidate_basenames(suffix)
    # Rank by candidate priority, then by shortest path (top-level beats nested).
    best = None
    best_rank = None
    for root, _dirs, files in os.walk(build_dir):
        for name in files:
            if name in wanted:
                rank = (wanted.index(name), len(os.path.join(root, name)))
                if best_rank is None or rank < best_rank:
                    best_rank = rank
                    best = os.path.join(root, name)
    return best


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def copy_into_tree(src_lib, platform_id, dry_run):
    """Copy `src_lib` to src/code/<platform_id>/torrentxt<suffix>, creating the
    directory. Idempotent: if the destination already holds byte-identical
    content, write nothing. Returns one of "created" / "updated" / "unchanged"."""
    suffix = PLATFORM_SUFFIX[platform_id]
    dest_dir = os.path.join(CODE_ROOT, platform_id)
    dest = os.path.join(dest_dir, "torrentxt" + suffix)  # ALWAYS the bare token

    existed = os.path.exists(dest)
    if existed and sha256(dest) == sha256(src_lib):
        return "unchanged", dest

    if dry_run:
        return ("update" if existed else "create"), dest

    os.makedirs(dest_dir, exist_ok=True)
    # copyfile (not copy2) - we deliberately do NOT carry over the source's
    # timestamp/mode noise into a committed artifact; a plain content copy keeps
    # diffs about bytes, not metadata.
    shutil.copyfile(src_lib, dest)
    return ("updated" if existed else "created"), dest


def assemble_staging(dry_run):
    """Best-effort: assemble the installable extension staging layout under
    build/package/ from the committed sources. This is a PLACEHOLDER for the real
    OXT packaging step (which is done in the IDE / by the engine's `revPackage`
    tooling - plan §11 "Package/Test in OXT"); we cannot produce a final signed
    .lce here. We stage the pieces an OXT package expects so a human can point the
    IDE at them:

        build/package/torrent.lcb            (the LCB binding, if present)
        build/package/code/<id>/torrentxt.*  (the committed per-platform libs)
        build/package/examples/...           (the script helpers/demo, if present)

    macOS NOTE: the committed universal-mac dylib should be codesigned and the
    final package notarized before public release (plan §7, §12). That requires
    Apple credentials we do not have here, so it is a documented manual step -
    this function never invents a signing identity. See docs/building.md.
    """
    staging = os.path.join(REPO_ROOT, "build", "package")
    actions = []

    def stage(rel_src, rel_dst):
        src = os.path.join(REPO_ROOT, rel_src)
        if not os.path.exists(src):
            return
        dst = os.path.join(staging, rel_dst)
        actions.append((src, dst))

    # The LCB binding, the poll-dispatcher sugar, and the two flagship demos.
    stage(os.path.join("src", "torrent.lcb"), "torrent.lcb")
    for ex in ("torrent-helpers.livecodescript",
               "torrent-client.livecodescript",
               "torrent-dht-channels.livecodescript"):
        stage(os.path.join("examples", ex), os.path.join("examples", ex))

    # Every committed per-platform library currently in the tree.
    if os.path.isdir(CODE_ROOT):
        for pid in VALID_PLATFORM_IDS:
            suffix = PLATFORM_SUFFIX[pid]
            lib = os.path.join(CODE_ROOT, pid, "torrentxt" + suffix)
            if os.path.exists(lib):
                actions.append((lib, os.path.join(staging, "code", pid, "torrentxt" + suffix)))

    if not actions:
        print("  assemble: nothing to stage yet (no .lcb / no committed libs).")
        return

    for src, dst in actions:
        rel = os.path.relpath(dst, REPO_ROOT)
        if dry_run:
            print("  assemble (dry-run): would stage %s" % rel)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        print("  assemble: staged %s" % rel)


# -------------------------------------------------------------------- main ----
def main(argv):
    ap = argparse.ArgumentParser(
        description="Refresh the committed src/code/<arch>-<platform>/ native library tree.")
    ap.add_argument("--platform-id", choices=VALID_PLATFORM_IDS,
                    help="target platform-id (default: auto-detect this host). "
                         "One of: " + ", ".join(VALID_PLATFORM_IDS))
    ap.add_argument("--build-dir", default="build",
                    help="CMake build directory to find the freshly built lib in (default: build)")
    ap.add_argument("--lib",
                    help="path to the built library directly (overrides --build-dir search)")
    ap.add_argument("--assemble", action="store_true",
                    help="also assemble the extension staging layout under build/package/")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would happen; write nothing")
    args = ap.parse_args(argv[1:])

    # Resolve the platform-id (explicit beats auto-detect). REFUSE the unknown:
    # argparse already rejects an out-of-set --platform-id; this covers the
    # auto-detect-failed case.
    platform_id = args.platform_id or detect_platform_id()
    if platform_id is None:
        print("ERROR: could not auto-detect a platform-id on this host "
              "(%s/%s). Pass --platform-id explicitly. Valid: %s"
              % (platform.system(), platform.machine(), ", ".join(VALID_PLATFORM_IDS)),
              file=sys.stderr)
        return 2
    if platform_id not in PLATFORM_SUFFIX:
        # Defence in depth (e.g. a future caller bypassing argparse choices).
        print("ERROR: unknown platform-id %r. Valid: %s"
              % (platform_id, ", ".join(VALID_PLATFORM_IDS)), file=sys.stderr)
        return 2

    suffix = PLATFORM_SUFFIX[platform_id]
    print("TorrentXT package-extension: target platform-id = %s (torrentxt%s)"
          % (platform_id, suffix))

    # Locate the source library.
    if args.lib:
        src_lib = os.path.abspath(args.lib)
        if not os.path.isfile(src_lib):
            print("ERROR: --lib %s does not exist." % src_lib, file=sys.stderr)
            return 2
        # Sanity-check the extension matches the platform-id's expectation.
        if not src_lib.endswith(suffix):
            print("WARNING: --lib %s does not end in %s (expected for %s) - copying anyway."
                  % (src_lib, suffix, platform_id), file=sys.stderr)
    else:
        build_dir = os.path.abspath(args.build_dir)
        if not os.path.isdir(build_dir):
            print("ERROR: build dir %s does not exist (configure+build first, or pass --lib)."
                  % build_dir, file=sys.stderr)
            return 2
        src_lib = find_built_lib(build_dir, suffix)
        if src_lib is None:
            print("ERROR: no torrentxt%s (or libtorrentxt%s) found under %s.\n"
                  "       Build the shim first: cmake --build %s --config Release"
                  % (suffix, suffix, build_dir, args.build_dir), file=sys.stderr)
            return 2

    print("  source: %s" % src_lib)
    if os.path.basename(src_lib).startswith("lib"):
        print("  note: source is lib-prefixed; writing the BARE-TOKEN name (torrentxt%s)." % suffix)

    status, dest = copy_into_tree(src_lib, platform_id, args.dry_run)
    rel_dest = os.path.relpath(dest, REPO_ROOT)
    verb = {
        "created": "created", "updated": "updated", "unchanged": "unchanged (idempotent no-op)",
        "create": "WOULD create", "update": "WOULD update",
    }[status]
    print("  %s: %s" % (verb, rel_dest))

    if args.assemble:
        assemble_staging(args.dry_run)

    if args.dry_run:
        print("Dry run complete - nothing written.")
    elif status in ("created", "updated"):
        print("Done. Commit %s alongside the shim/.lcb change that produced it." % rel_dest)
    else:
        print("Done. Committed binary already up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
