#!/usr/bin/env python3
"""check-record-registry.py - prove the LCB record constants cannot drift from
the C++ registry (plan §4.4: "a single fieldId registry ... so the shim writer
and the LCB walker cannot drift").

src/btx_record.h is the SINGLE SOURCE OF TRUTH for three enums:
    FieldType  (FT_*)  -> LCB constant  kType<Name>
    FieldId    (F_*)   -> LCB constant  kField<Name>
    AlertType  (A_*)   -> LCB constant  kAlert<Name>

The LCB name is derived mechanically from the C++ name, so this checker catches
a missing constant, a wrong value, AND a value swap (because each LCB constant's
expected value is tied to its specific C++ enumerator by name). Every enumerator
in the header must have a matching `constant k... is <value>` in src/torrent.lcb.

    python3 tools/check-record-registry.py [path/to/btx_record.h] [path/to/torrent.lcb]

Exit 0 = in sync (or torrent.lcb not written yet -> skip), 1 = drift found.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def camel(name_after_prefix):
    """TOKEN_TOKEN -> TokenToken (each token: first char upper, rest lower)."""
    parts = name_after_prefix.split("_")
    return "".join(p[:1].upper() + p[1:].lower() for p in parts if p)


# (C++ prefix, LCB prefix) for the three registries
REGISTRIES = [
    ("FT_", "kType"),
    ("F_", "kField"),
    ("A_", "kAlert"),
]


def parse_header_enum(text, cpp_prefix):
    """Return {cpp_name: value} for every `PREFIX_NAME = N` in the header."""
    out = {}
    pat = re.compile(r"\b(" + re.escape(cpp_prefix) + r"[A-Z0-9_]+)\s*=\s*(\d+)")
    for m in pat.finditer(text):
        out[m.group(1)] = int(m.group(2))
    return out


def parse_lcb_constants(text):
    """Return {kName: value} for every `constant kName is <int>` in the .lcb."""
    out = {}
    for m in re.finditer(r"\bconstant\s+(k[A-Za-z0-9_]+)\s+is\s+(\d+)\b", text):
        out[m.group(1)] = int(m.group(2))
    return out


def parse_abi_version(path):
    """Return the int N from `#define BTX_ABI_VERSION N`, or None if unreadable."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(r"#define\s+BTX_ABI_VERSION\s+(\d+)", text)
    return int(m.group(1)) if m else None


def main(argv):
    header = argv[1] if len(argv) > 1 else os.path.join(HERE, "src", "btx_record.h")
    lcb = argv[2] if len(argv) > 2 else os.path.join(HERE, "src", "torrent.lcb")

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

    # The ABI version must match between btx_abi.h (#define BTX_ABI_VERSION) and
    # torrent.lcb (constant kABIVersion) - a skew makes _checkABI() throw at
    # runtime, and a forgotten bump is an easy mistake to make. Catch it here.
    abi_h = parse_abi_version(os.path.join(HERE, "src", "btx_abi.h"))
    abi_lcb = lcb_consts.get("kABIVersion")
    if abi_h is None:
        problems.append("could not read BTX_ABI_VERSION from src/btx_abi.h")
    elif abi_lcb is None:
        problems.append("missing `constant kABIVersion` in torrent.lcb")
    elif abi_h != abi_lcb:
        problems.append("ABI version skew: btx_abi.h BTX_ABI_VERSION=%d but "
                        "torrent.lcb kABIVersion=%d" % (abi_h, abi_lcb))
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

    if problems:
        for p in problems:
            print("DRIFT:", p)
        print("\n%d registry drift problem(s)" % len(problems))
        return 1
    print("check-record-registry: %d constants in sync between btx_record.h and torrent.lcb"
          % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
