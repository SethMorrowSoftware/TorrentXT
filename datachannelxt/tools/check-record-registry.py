#!/usr/bin/env python3
"""check-record-registry.py - prove the LCB record constants cannot drift from
the C++ registry ("a single fieldId registry ... so the shim writer and the
LCB walker cannot drift" - the family rule, carried from TorrentXT).

src/dcx_record.h is the SINGLE SOURCE OF TRUTH for five enums:
    FieldType      (FT_*)  -> LCB constant  kType<Name>
    FieldId        (F_*)   -> LCB constant  kField<Name>
    EventType      (E_*)   -> LCB constant  kEvent<Name>
    PeerState      (PS_*)  -> LCB constant  kPeerState<Name>
    GatheringState (GS_*)  -> LCB constant  kGathering<Name>

The LCB name is derived mechanically from the C++ name, so this checker catches
a missing constant, a wrong value, AND a value swap (because each LCB constant's
expected value is tied to its specific C++ enumerator by name). Every enumerator
in the header must have a matching `constant k... is <value>` in
src/datachannel.lcb. It ALSO asserts DCX_ABI_VERSION (dcx_abi.h) equals
kABIVersion (the .lcb) - the ABI-sync gate.

    python3 tools/check-record-registry.py [path/to/dcx_record.h] [path/to/datachannel.lcb]

Exit 0 = in sync (or datachannel.lcb not written yet -> skip), 1 = drift found.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def camel(name_after_prefix):
    """TOKEN_TOKEN -> TokenToken (each token: first char upper, rest lower)."""
    parts = name_after_prefix.split("_")
    return "".join(p[:1].upper() + p[1:].lower() for p in parts if p)


# (C++ prefix, LCB prefix) for the five registries. ORDER MATTERS in the
# matcher below: a prefix must not swallow a longer one (F_ vs FT_ is handled
# by the regex requiring the whole enumerator name to start with the prefix
# and the next char to be part of the name, so FT_INT never parses as F_T...).
REGISTRIES = [
    ("FT_", "kType"),
    ("F_", "kField"),
    ("E_", "kEvent"),
    ("PS_", "kPeerState"),
    ("GS_", "kGathering"),
]


def parse_header_enum(text, cpp_prefix):
    """Return {cpp_name: value} for every `PREFIX_NAME = N` in the header.
    The F_ registry must not swallow FT_ enumerators: an F_ match whose name
    also matches a LONGER registered prefix is skipped."""
    longer = [p for p, _ in REGISTRIES if p != cpp_prefix and p.startswith(cpp_prefix)]
    out = {}
    pat = re.compile(r"\b(" + re.escape(cpp_prefix) + r"[A-Z0-9_]+)\s*=\s*(\d+)")
    for m in pat.finditer(text):
        name = m.group(1)
        if any(name.startswith(lp) for lp in longer):
            continue
        out[name] = int(m.group(2))
    return out


def parse_lcb_constants(text):
    """Return {kName: value} for every `constant kName is <int>` in the .lcb."""
    out = {}
    for m in re.finditer(r"\bconstant\s+(k[A-Za-z0-9_]+)\s+is\s+(\d+)\b", text):
        out[m.group(1)] = int(m.group(2))
    return out


def parse_abi_version(path):
    """Return the int N from `#define DCX_ABI_VERSION N`, or None if unreadable."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(r"#define\s+DCX_ABI_VERSION\s+(\d+)", text)
    return int(m.group(1)) if m else None


def main(argv):
    header = argv[1] if len(argv) > 1 else os.path.join(HERE, "src", "dcx_record.h")
    lcb = argv[2] if len(argv) > 2 else os.path.join(HERE, "src", "datachannel.lcb")

    with open(header, "r", encoding="utf-8") as f:
        htext = f.read()

    if not os.path.exists(lcb):
        print("check-record-registry: %s not written yet - skipping (will enforce once it exists)"
              % os.path.relpath(lcb, HERE))
        return 0

    with open(lcb, "r", encoding="utf-8") as f:
        ltext = f.read()
    lcb_consts = parse_lcb_constants(ltext)

    problems = []
    checked = 0

    # The ABI version must match between dcx_abi.h (#define DCX_ABI_VERSION)
    # and datachannel.lcb (constant kABIVersion) - a skew makes _checkABI()
    # throw at runtime, and a forgotten bump is an easy mistake. Catch it here.
    abi_h = parse_abi_version(os.path.join(HERE, "src", "dcx_abi.h"))
    abi_lcb = lcb_consts.get("kABIVersion")
    if abi_h is None:
        problems.append("could not read DCX_ABI_VERSION from src/dcx_abi.h")
    elif abi_lcb is None:
        problems.append("missing `constant kABIVersion` in datachannel.lcb")
    elif abi_h != abi_lcb:
        problems.append("ABI version skew: dcx_abi.h DCX_ABI_VERSION=%d but "
                        "datachannel.lcb kABIVersion=%d" % (abi_h, abi_lcb))
    else:
        checked += 1

    for cpp_prefix, lcb_prefix in REGISTRIES:
        header_enum = parse_header_enum(htext, cpp_prefix)
        if not header_enum:
            problems.append("no `%s*` enumerators found in %s" % (cpp_prefix, header))
        for cpp_name, value in sorted(header_enum.items(), key=lambda kv: kv[1]):
            expected = lcb_prefix + camel(cpp_name[len(cpp_prefix):])
            checked += 1
            if expected not in lcb_consts:
                problems.append("missing LCB constant `%s` (for C++ %s = %d)"
                                % (expected, cpp_name, value))
            elif lcb_consts[expected] != value:
                problems.append("value drift: LCB `%s` is %d but C++ %s = %d"
                                % (expected, lcb_consts[expected], cpp_name, value))

    # DCX_MAX_MESSAGE (dcx_abi.h) must equal kMaxMessage (the .lcb) - the
    # documented size budget is part of the contract, not folklore.
    m = re.search(r"#define\s+DCX_MAX_MESSAGE\s+(\d+)", open(
        os.path.join(HERE, "src", "dcx_abi.h"), encoding="utf-8").read())
    if not m:
        problems.append("could not read DCX_MAX_MESSAGE from src/dcx_abi.h")
    elif lcb_consts.get("kMaxMessage") != int(m.group(1)):
        problems.append("size-budget drift: dcx_abi.h DCX_MAX_MESSAGE=%s but "
                        "datachannel.lcb kMaxMessage=%s"
                        % (m.group(1), lcb_consts.get("kMaxMessage")))
    else:
        checked += 1

    if problems:
        for p in problems:
            print("DRIFT:", p)
        print("\n%d registry drift problem(s)" % len(problems))
        return 1
    print("check-record-registry: %d constants in sync between dcx_record.h and datachannel.lcb"
          % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
