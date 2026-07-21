#!/usr/bin/env bash
#
# fix-length-constrained-test-constants.sh -- restore the upstream byte
# length of five smoketest constants that the four-form pass grew past a
# CLI validator's maximum.
#
# WHY: `vyos` (4) -> `dozenos` (7) is a +3-character rewrite. Upstream sets
# several test constants right at a validator's ceiling, so the transform
# pushes them over it and the CLI rejects the `set` -- the test errors out
# in cli_set, long before it asserts anything:
#
#   test_protocols_nhrp.py     nhrp_secret   "vyos123"  (7)  -> 10  > 8
#   test_vpn_ipsec.py          nhrp_secret   "vyos123"  (7)  -> 10  > 8
#   test_protocols_ospf.py     password      'vyos1234' (8)  -> 11  > 8
#   test_protocols_ospf.py     plaintext_key 'vyos123'  (7)  -> 10  > 8
#   test_service_dns_dynamic.py vrf_name  f'vyos-test-{vrf_table}' (15) -> 18 > 15
#
#   "Password should contain up to eight non-whitespace characters"  (nhrp)
#   "Password must be 8 characters or less"                          (ospf)
#   "VRF instance name must be 15 characters or less ..."            (ddns)
#
# This is NOT an upstream bug -- upstream's own values are all within
# their limits, and upstream CI is green on these tests. It is the
# rebrand's own +3 landmine (../../LANDMINES.md), and the same class as
# fix-snmp-test-localized-keys.sh: the transform produced a syntactically
# correct string that is semantically invalid. Found 2026-07-21 by the
# nightly test-image gate (run 29835061325, test-no-interfaces-no-vpp,
# 5/94 failing).
#
# THE FIX: substitute a 4-character brand token, `dozenos` -> `dzos`, in
# these five constants only. `dzos` is the same length as `vyos`, so every
# constant is restored to its EXACT upstream byte length -- including
# `vyos-test-58710`, which upstream sets at exactly the 15-character VRF
# ceiling. Nothing here is a value the user ever sees or types: these are
# test-local secrets and a test-local VRF name. `dzos` carries no `vyos`
# substring, so the final --verify gate stays clean.
#
# Scope is deliberately narrow -- five named constants in four files, each
# matched by its own anchored regex. A blanket `dozenos` -> `dzos` pass over
# the smoketests would silently shorten brand strings that tests legitimately
# assert against (paths, usernames, config values), so new violations are
# meant to surface as a nightly failure and get an explicit entry here,
# not be absorbed by a wildcard.
#
# Fail-closed: each constant must currently read EITHER the transformed
# (broken) value or the already-fixed value; anything else -- an upstream
# rename, a changed literal, a new quoting style -- dies loudly instead of
# silently no-op'ing. The end-state check re-parses every constant and
# asserts both its value and its length ceiling. Idempotent: on an
# already-fixed tree the replacement pass finds nothing and the end-state
# check passes.
#
# Usage:
#   fix-length-constrained-test-constants.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'fix-length-constrained-test-constants: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

python3 - "$TARGET" <<'PYEOF'
import re
import sys

target = sys.argv[1]

# (relative path, constant name, anchored regex capturing the literal,
#  broken post-transform literal, fixed literal, max length, what the
#  ceiling is). The regex captures ONLY the literal's inner text so the
#  surrounding quoting/f-prefix is preserved verbatim on rewrite.
CONSTANTS = [
    ("smoketest/scripts/cli/test_protocols_nhrp.py", "nhrp_secret",
     r'(?m)^(\s*nhrp_secret = ")([^"]*)(")$',
     "dozenos123", "dzos123", 8, "nhrp authentication password"),
    ("smoketest/scripts/cli/test_vpn_ipsec.py", "nhrp_secret",
     r'(?m)^(\s*nhrp_secret = ")([^"]*)(")$',
     "dozenos123", "dzos123", 8, "nhrp authentication password"),
    ("smoketest/scripts/cli/test_protocols_ospf.py", "password",
     r"(?m)^(\s*password = ')([^']*)(')$",
     "dozenos1234", "dzos1234", 8, "ospf plaintext-password"),
    ("smoketest/scripts/cli/test_protocols_ospf.py", "plaintext_key",
     r"(?m)^(\s*plaintext_key = ')([^']*)(')$",
     "dozenos123", "dzos123", 8, "ospf plaintext-password"),
    ("smoketest/scripts/cli/test_service_dns_dynamic.py", "vrf_name",
     r"(?m)^(\s*vrf_name = f')([^']*)(')$",
     "dozenos-test-{vrf_table}", "dzos-test-{vrf_table}", 15, "vrf instance name"),
]

# vrf_name is an f-string: its rendered length is what the validator sees,
# so the ceiling check must substitute the interpolated value. Parsed from
# the file rather than hardcoded, so an upstream change to the table number
# is caught by the length assertion instead of shipping a silent overrun.
def rendered(rel, text, literal):
    if "{vrf_table}" not in literal:
        return literal
    m = re.search(r"(?m)^\s*vrf_table = '([^']*)'$", text)
    if not m:
        sys.exit("fix-length-constrained-test-constants: cannot find vrf_table in "
                 f"{rel} -- upstream test layout changed, re-review by hand")
    return literal.replace("{vrf_table}", m.group(1))

edits = {}
for rel, name, pattern, broken, fixed, limit, ceiling in CONSTANTS:
    path = f"{target}/{rel}"
    try:
        with open(path, encoding="utf-8") as fh:
            text = edits.get(rel, fh.read())
    except FileNotFoundError:
        sys.exit(f"fix-length-constrained-test-constants: expected file not found "
                 f"(upstream sync drift?): {rel}")

    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        sys.exit(f"fix-length-constrained-test-constants: expected exactly 1 "
                 f"`{name}` assignment in {rel}, found {len(matches)} -- upstream "
                 "test layout changed, re-review by hand")

    current = matches[0].group(2)
    if current == broken:
        text = text[:matches[0].start(2)] + fixed + text[matches[0].end(2):]
        edits[rel] = text
        print(f"fix-length-constrained-test-constants: {rel}: {name} "
              f"{current!r} -> {fixed!r} ({ceiling}, max {limit})")
    elif current == fixed:
        edits.setdefault(rel, text)
    else:
        sys.exit(f"fix-length-constrained-test-constants: {rel}: {name} is "
                 f"{current!r}, expected the transformed {broken!r} or the fixed "
                 f"{fixed!r} -- upstream drifted, re-review by hand")

for rel, text in edits.items():
    with open(f"{target}/{rel}", "w", encoding="utf-8") as fh:
        fh.write(text)

# Unconditional end-state check -- see "Fail-closed" in the header.
for rel, name, pattern, broken, fixed, limit, ceiling in CONSTANTS:
    with open(f"{target}/{rel}", encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(pattern, text)
    if not m or m.group(2) != fixed:
        sys.exit(f"fix-length-constrained-test-constants: {rel}: {name} did not "
                 f"end up as {fixed!r} -- re-review by hand")
    value = rendered(rel, text, m.group(2))
    if len(value) > limit:
        sys.exit(f"fix-length-constrained-test-constants: {rel}: {name} renders as "
                 f"{value!r} ({len(value)} chars), over the {limit}-character "
                 f"{ceiling} ceiling -- re-review by hand")
    if "vyos" in value.lower():
        sys.exit(f"fix-length-constrained-test-constants: {rel}: {name} still "
                 f"carries a vyos substring ({value!r}) -- re-review by hand")
PYEOF
