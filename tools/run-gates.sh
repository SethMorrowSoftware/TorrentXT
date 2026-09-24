#!/usr/bin/env bash
# run-gates.sh - torrentxt's OWN gate list: what CI and a contributor run.
# Compiler-free: python3 and sha256sum are all it needs (the native smoke,
# handle and integration tests are the CMake build's, not this list's).
#
# ONE LIST. The suite's tools/build-all.sh delegates to this script rather
# than carrying a probe-by-filename copy of it, so a gate runs in the suite
# and standalone alike - or nowhere. Any gate file added under tools/ or
# tests/ MUST be named here: the suite's tools/check-member-standalone.py
# refuses a gate file this script never names. A tool nobody invokes is the
# rot the suite root records more than once; this list is where that is kept
# out of this member.
#
# Fail-loud, in order: set -e stops at the first gate that fails, so the last
# banner printed is the one that broke. The banners match build-all.sh's, so
# a log reads the same whichever ran the walk. Nothing is probed with
# `[ -f ]` - the member knows what it ships, and a probe that finds nothing
# prints OK over a gate that has gone missing. The one glob is the golden
# suites, so a new golden is covered the day it lands.
#
# Runs from anywhere: every gate runs from the member root.

set -euo pipefail
cd "$(dirname "$0")/.."

# The LiveCodeScript/LCB static gate. Every member carries a byte-identical
# copy (the suite's check-checker-drift.py holds them equal and its
# test-checker.py proves every rule fires in this copy).
echo "== torrentxt: static gate =="
python3 tools/check-livecodescript.py

# Every golden-vector suite this member ships (BEP44, the file server, the
# onion frame, the record codec): the ONE glob in this file, so a member
# adding one is covered with no edit here. nullglob so an empty match runs
# nothing rather than handing python3 the literal pattern.
shopt -s nullglob
for rel in tests/*golden*.py; do
  echo "== torrentxt: $rel =="
  python3 "$rel"
done
shopt -u nullglob

# The Model C execution gate (2026-09-24): the demos' shipped receive paths
# RUN headlessly through riptide's runner, held to the onion golden's mirrors
# and, in tier 2, to the committed SodiumXT (the verifier, the truncated-code
# parse, the M9 feed-seal KAT). After the golden, which it stands on; its
# fixture test first, because a blind gate prints OK too. Siblings: riptide,
# nostrxt, sodiumxt (tools/member-registry.py).
echo "== torrentxt: tools/test-script-vectors.py =="
python3 tools/test-script-vectors.py
echo "== torrentxt: tools/check-script-vectors.py =="
python3 tools/check-script-vectors.py --check

# Record-registry sync (shim header <-> .lcb constants): src/btx_record.h is
# the single source of truth for the field-type, field-id and alert-type
# enums, and every enumerator must have its mechanically named `constant
# k...` in src/torrent.lcb at the same value - a missing constant, a wrong
# value and a value swap all fail here rather than on an engine.
echo "== torrentxt: tools/check-record-registry.py =="
python3 tools/check-record-registry.py

# Committed-binary integrity manifest: a committed blob that is unlisted or
# does not match its recorded SHA256 fails the gate. It proves a blob is
# UNCHANGED, not that it still matches the source that produced it - that
# half (suite rule 5) is the suite's check-binary-freshness.py.
echo "== torrentxt: src/code/MANIFEST.sha256 =="
( cd src/code && sha256sum -c --quiet MANIFEST.sha256 )
