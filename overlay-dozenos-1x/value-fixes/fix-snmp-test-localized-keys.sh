#!/usr/bin/env bash
#
# fix-snmp-test-localized-keys.sh -- recompute the four SNMPv3 localized-key
# constants in smoketest/scripts/cli/test_service_snmp.py for the
# post-transform passwords.
#
# WHY: the four-form pass rewrites the test's plaintext passwords
# (`vyos12345678` -> `dozenos12345678`, `vyos87654321` -> `dozenos87654321`),
# but the test asserts the CLI's `encrypted-password` values against four
# hardcoded hex constants -- RFC 3414 localized keys derived from the
# ORIGINAL plaintexts plus the test's fixed engine-id. A localized key
# contains no `vyos` substring, so it passes the transform (and the
# zero-`vyos` --verify gate) untouched while no longer matching what snmpd
# actually computes from the new plaintexts. Same "value, not string" class
# as regen-default-password-hash.sh (../../LANDMINES.md): the constants must
# be recomputed, not substituted. Found 2026-07-18 by the nightly test-image
# gate: test_snmpv3_md5/test_snmpv3_sha failed with exactly the key this
# script now computes.
#
# The localization algorithm (RFC 3414 A.2: Ku = H(password repeated to
# 2^20 bytes); Kul = H(Ku || engineID || Ku)) was validated against all four
# upstream constants (reproduced bit-exact from the `vyos...` plaintexts)
# AND against the values snmpd computed on the failing nightly run
# (29643736625) -- 6/6 data points match.
#
# Fail-closed: passwords and engine-id are PARSED from the target file, and
# the end-state check requires every `hashed_password` constant in the file
# to equal a key recomputed from those parsed values. If upstream changes
# the passwords, the engine-id, or the test layout, the check dies loudly
# instead of silently no-op'ing. Idempotent: on an already-fixed file the
# replacement pass finds nothing and the end-state check passes.
#
# Usage:
#   fix-snmp-test-localized-keys.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'fix-snmp-test-localized-keys: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

REL="smoketest/scripts/cli/test_service_snmp.py"
F="$TARGET/$REL"
[ -f "$F" ] || die "expected file not found (upstream sync drift?): $F"

python3 - "$F" "$REL" <<'PYEOF'
import hashlib
import re
import sys
from binascii import unhexlify

path, rel = sys.argv[1], sys.argv[2]

with open(path, encoding="utf-8") as fh:
    text = fh.read()

def module_const(name):
    m = re.search(rf"^{name} = '([^']+)'$", text, re.M)
    if not m:
        sys.exit(f"fix-snmp-test-localized-keys: cannot find {name} in {rel} "
                 "-- upstream test layout changed, re-review by hand")
    return m.group(1)

auth_pw = module_const("snmpv3_auth_pw")
priv_pw = module_const("snmpv3_priv_pw")
engine_id = unhexlify(module_const("snmpv3_engine_id"))

def localized_key(alg, password):
    pw = password.encode()
    ku = hashlib.new(alg, (pw * (1048576 // len(pw) + 1))[:1048576]).digest()
    return hashlib.new(alg, ku + engine_id + ku).hexdigest()

# Upstream's four hardcoded constants (localized keys of the pre-transform
# `vyos...` plaintexts), each mapped to the key recomputed from whatever
# password/engine-id the file carries NOW.
replacements = {
    # test_snmpv3_sha: auth, then privacy
    '4e52fe55fd011c9c51ae2c65f4b78ca93dcafdfe': localized_key('sha1', auth_pw),
    '54705c8de9e81fdf61ad7ac044fa8fe611ddff6b': localized_key('sha1', priv_pw),
    # test_snmpv3_md5: auth, then privacy
    '4c67690d45d3dfcd33d0d7e308e370ad': localized_key('md5', auth_pw),
    'e11c83f2c510540a3c4de84ee66de440': localized_key('md5', priv_pw),
}

patched = text
replaced = 0
for old, new in replacements.items():
    if old in patched:
        patched = patched.replace(old, new)
        replaced += 1

if replaced:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(patched)
    print(f"fix-snmp-test-localized-keys: {replaced} constant(s) recomputed in {rel}")
else:
    print("fix-snmp-test-localized-keys: no known upstream constants found "
          "(already fixed, or upstream drifted -- end-state check decides which)")

# Unconditional end-state check -- see "Fail-closed" in the header.
found = re.findall(r"hashed_password = '([0-9a-f]+)'", patched)
if len(found) != 4:
    sys.exit(f"fix-snmp-test-localized-keys: expected exactly 4 hashed_password "
             f"constants in {rel}, found {len(found)} -- upstream test layout "
             "changed, re-review by hand")
stale = sorted(set(found) - set(replacements.values()))
if stale:
    sys.exit(f"fix-snmp-test-localized-keys: constant(s) {stale} in {rel} do not "
             "match keys recomputed from the file's own passwords/engine-id -- "
             "upstream drifted, re-review by hand")
PYEOF
