#!/usr/bin/env python3
"""test-script-vectors.py - prove tools/check-script-vectors.py can FAIL.

A gate that has gone blind prints OK, and this tree has met that shape more
than once (coinxt's constant gate counting what it parsed as what it checked;
the golden this gate stands on, whose reassemble() took a stream whole while
its comment said it did not). So this drives the gate the way run-gates.sh
does - the real entry point, over a real copy of the shipped demo - with one
defect of the class the gate exists to catch edited into the copy each time,
and requires a non-zero exit with the defect's check NAMED in the output.
Then it drives untouched copies and requires OK, so a fixture that "fails"
because the copy would not load cannot pass as discrimination.

Each anchor must occur exactly once in the shipped demo, so a rename there
fails this test rather than silently turning a fixture into a no-op.

The tier-2 fixtures (the verifier, the code parse, the M9 KAT) need the
committed SodiumXT the gate's tier 2 runs on; where it is absent or will not
load, those fixtures are SKIPPED and say so - and under XTALK_REQUIRE_SIBLINGS
the skip is a failure, as it is in the gate.
"""
import ctypes
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MEMBER = os.path.dirname(HERE)
GATE = os.path.join(HERE, "check-script-vectors.py")
DEMOS = {
    "qs": os.path.join(MEMBER, "examples", "torrent-quickshare.livecodescript"),
    "ch": os.path.join(MEMBER, "examples", "torrent-dht-channels.livecodescript"),
}


def sibling(name):
    """The gate's sibling rule (see check-script-vectors.py)."""
    if name == os.path.basename(MEMBER):
        return MEMBER
    one = os.environ.get("XTALK_SIBLING_" + name.upper().replace("-", "_"))
    if one:
        return one
    return os.path.join(os.environ.get("XTALK_SIBLINGS")
                        or os.path.dirname(MEMBER), name)


def tier2_available():
    path = os.path.join(sibling("sodiumxt"), "src", "code", "x86_64-linux",
                        "sodiumxt.so")
    if not os.path.isfile(path):
        return False
    try:
        ctypes.CDLL(path)
    except OSError:
        return False
    return True


# (label, demo, tier, anchor, replacement, the check the gate must name)
FIXTURES = [
    ("the nameLen cap enforced only AFTER waiting for the name", "qs", 1,
     "      if tNameLen > kOnionMaxName then\n"
     "         qsOnionRecvAbort pStream, \"Tor stream header looks malformed (name too long).\"\n"
     "         exit qsOnionRecvData\n"
     "      end if\n"
     "      if the number of bytes in sRxBuf[pStream] < (8 + tNameLen + 8) then\n"
     "         exit qsOnionRecvData\n"
     "      end if\n",
     "      if the number of bytes in sRxBuf[pStream] < (8 + tNameLen + 8) then\n"
     "         exit qsOnionRecvData\n"
     "      end if\n"
     "      if tNameLen > kOnionMaxName then\n"
     "         qsOnionRecvAbort pStream, \"Tor stream header looks malformed (name too long).\"\n"
     "         exit qsOnionRecvData\n"
     "      end if\n",
     "qsOnionRecvData: nameLen 1025: the prologue alone"),
    ("a partial DATA frame refused instead of waited for (the split-buffer bug)",
     "qs", 1,
     "      if the number of bytes in sRxBuf[pStream] < (4 + tLen) then\n"
     "         exit repeat\n"
     "      end if\n",
     "      if the number of bytes in sRxBuf[pStream] < (4 + tLen) then\n"
     "         qsOnionRecvAbort pStream, \"Tor stream frame too large - aborting.\"\n"
     "         exit qsOnionRecvData\n"
     "      end if\n",
     "qsOnionRecvData: DATA payload cut in half"),
    ("the byte-count finish removed from the Channels receiver", "ch", 1,
     "   if sRxState[pStream] is \"body\" and sRxGot[pStream] >= sRxTotal[pStream] then\n"
     "      put \"done\" into sRxState[pStream]\n"
     "   end if\n",
     "",
     "chOnionRecvData: saved without its terminator"),
    ("qsKeyOpensVerifier answering true when the box does not open", "qs", 2,
     "      put sxSecretBoxOpen(base64Decode(pB64Verify), pKey) into tOut\n"
     "   catch tErr\n"
     "      return false\n",
     "      put sxSecretBoxOpen(base64Decode(pB64Verify), pKey) into tOut\n"
     "   catch tErr\n"
     "      return true\n",
     "qsKeyOpensVerifier: a SodiumXT verifier, a WRONG passphrase's key"),
    ("qsReceiveOnion dialing without the local passphrase check", "qs", 2,
     "      if not qsKeyOpensVerifier(tKey, tB64Verify) then\n"
     "         answer (\"That passphrase does not match this locked file.\" & return & return & \\\n"
     "            \"Check the passphrase your friend gave you and try again.\") with \"OK\"\n"
     "         select the text of field \"qsRecvPass\"\n"
     "         exit qsReceiveOnion\n"
     "      end if\n",
     "",
     "qsReceiveOnion: the whole locked code, WRONG passphrase"),
    ("a feed push resending a cached seal (the M9 regression)", "ch", 2,
     "   put chFeedValue(tText, sChannels[tIdx][\"pass\"], pPubHex) into tVal\n",
     "   if sFeedStreams[\"m9-cache\"] is empty then\n"
     "      put chFeedValue(tText, sChannels[tIdx][\"pass\"], pPubHex) into sFeedStreams[\"m9-cache\"]\n"
     "   end if\n"
     "   put sFeedStreams[\"m9-cache\"] into tVal\n",
     "M9: the second push RE-SEALS (no cached nonce)"),
    # The free-disk pre-check (design 3.3, 2026-09-24): a receiver that
    # measures the shortfall and then ignores it opens its temp and starts
    # writing, which is exactly the "meet a full disk halfway" the design
    # refused. The gate's disk rows must name it.
    ("the free-disk pre-check measured and then ignored", "qs", 1,
     "      if tShort is not empty then\n         qsOnionRecvAbort pStream, tShort\n",
     "      if tShort is not empty and false then\n         qsOnionRecvAbort pStream, tShort\n",
     "qsDiskGuard: one byte short of a 300-byte file"),
]


def run_gate(demo, path):
    proc = subprocess.run([sys.executable, GATE, "--check", "--only", demo,
                           "--" + demo, path], capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def main():
    shipped = {}
    for demo, path in DEMOS.items():
        with open(path, "r", encoding="utf-8") as fh:
            shipped[demo] = fh.read()
    tier2 = tier2_available()
    require = bool(os.environ.get("XTALK_REQUIRE_SIBLINGS"))
    tmp = tempfile.mkdtemp(prefix="torrentxt-vectors-fixtures-")
    failed = caught = skipped = 0
    try:
        for label, demo, tier, anchor, replacement, must_name in FIXTURES:
            if shipped[demo].count(anchor) != 1:
                failed += 1
                print("FAIL  %s - the anchor occurs %d times in the shipped %s demo, "
                      "so the fixture cannot apply"
                      % (label, shipped[demo].count(anchor), demo))
                continue
            if tier == 2 and not tier2:
                if require:
                    failed += 1
                    print("FAIL  %s - needs the committed SodiumXT (XTALK_REQUIRE_"
                          "SIBLINGS is set)" % label)
                else:
                    skipped += 1
                    print("SKIP  %s - the committed SodiumXT is absent or will not "
                          "load here, so the gate's tier 2 cannot run" % label)
                continue
            path = os.path.join(tmp, "mutated-%s.livecodescript" % demo)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(shipped[demo].replace(anchor, replacement))
            rc, out = run_gate(demo, path)
            if rc == 0:
                failed += 1
                print("FAIL  %s - the gate passed a demo carrying it" % label)
            elif must_name not in out:
                failed += 1
                print("FAIL  %s - the gate failed without naming %r\n      %s"
                      % (label, must_name, out.strip().split("\n")[-1]))
            else:
                caught += 1
                print("PASS  %s" % label)
        for demo in sorted(DEMOS):
            path = os.path.join(tmp, "clean-%s.livecodescript" % demo)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(shipped[demo])
            rc, out = run_gate(demo, path)
            if rc != 0:
                failed += 1
                print("FAIL  the untouched %s copy does not pass, so nothing above was "
                      "discrimination\n      %s"
                      % (demo, "\n      ".join(out.strip().split("\n")[-6:])))
            else:
                print("PASS  the untouched %s copy passes" % demo)
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
    if failed:
        print("test-script-vectors: FAIL (%d)" % failed)
        return 1
    print("test-script-vectors: OK (%d seeded defects caught, %d skipped, the clean "
          "copies pass)" % (caught, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
