#!/usr/bin/env bash
#
# rebake-ssh-testca-cert.sh -- replace the trusted-user-CA fixture in
# smoketest/scripts/cli/test_service_ssh.py with a DozenOS-principal one.
#
# WHY: test_ssh_trusted_user_ca mixes LIVE Python literals with PRE-BAKED
# base64 SSH material. The four-form pass rewrites the literals --
#
#   test_user = 'vyos_testca'  ->  'dozenos_testca'
#   principal = 'vyos'         ->  'dozenos'
#
# -- but it cannot rewrite what is inside the signed certificate, whose
# principal list stays `vyos, vyos_testca` (upstream Key ID
# "vyos_testca@vyos.net"). The test logs in as `dozenos_testca` with
# `AuthorizedPrincipalsFile none`, so sshd requires the certificate to name
# the USERNAME as a principal. It does not, so the login is rejected.
#
# The traceback blames paramiko, which is a red herring:
#
#   ValueError: PublicBlob type ssh-rsa-cert-v01@openssh.com incompatible
#               with key type ssh-dss
#
# paramiko's SSHClient._auth loops over (RSAKey, DSSKey, ECDSAKey,
# Ed25519Key) and only catches SSHException. RSAKey loads and authenticates
# but is REJECTED by sshd -- an SSHException, swallowed -- so the loop falls
# through to DSSKey, which mis-parses the OpenSSH RSA key and then raises a
# bare ValueError that escapes uncaught. That fall-through is a real, open
# paramiko bug (paramiko#2467) but only masks the message; the failure is
# ours. Upstream has no issue/PR for this test and upstream CI is green.
#
# Same "value, not string" class as regen-default-password-hash.sh and
# fix-snmp-test-localized-keys.sh: a rewrite that is textually correct and
# semantically wrong. Found 2026-07-21 by the nightly test-image gate
# (run 29835061325, test-no-interfaces-no-vpp).
#
# THE FIX: substitute a CA public key, user private key and signed
# certificate generated for principals `dozenos` + `dozenos_testca`,
# matching the transformed literals. The material is PRE-GENERATED and
# committed under ../data/ssh-testca/ -- NOT generated here. mirror-push.sh
# requires the transform+overlay pipeline to be byte-stable for a given
# (upstream tree, toolkit); minting a fresh keypair per run would make every
# sync produce a different mirror and destroy that reproducibility.
#
# The committed private key is throwaway smoketest material with no access
# to anything -- exactly what upstream ships in this same file. It is a test
# fixture, not a credential.
#
# Fail-closed: the three constants must currently hold EITHER upstream's
# baked material or ours; any other content dies loudly. The end-state check
# re-parses the file and asserts the certificate actually carries both
# principals the test needs, so a stale or mis-generated data file cannot
# ship silently. Idempotent: on an already-fixed tree the replacement pass
# finds nothing and the end-state check passes.
#
# Regenerating the fixture (only if it expires -- valid to 2036-01-01):
#   ssh-keygen -q -t rsa -b 3072 -N '' -C 'dozenos_testca@dozenos.net' -f ca
#   ssh-keygen -q -t rsa -b 3072 -N '' -C 'dozenos_testca@dozenos.net' -f user
#   ssh-keygen -q -s ca -I 'dozenos_testca@dozenos.net' \
#     -n dozenos,dozenos_testca -V 20260101123000:20360101123000 user.pub
#   cp ca.pub user user-cert.pub ../data/ssh-testca/{ca.pub,user_key,user-cert.pub}
#
# Usage:
#   rebake-ssh-testca-cert.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'rebake-ssh-testca-cert: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DATA="$SCRIPT_DIR/../data/ssh-testca"
for f in ca.pub user_key user-cert.pub; do
  [ -f "$DATA/$f" ] || die "missing fixture: $DATA/$f"
done

python3 - "$TARGET" "$DATA" <<'PYEOF'
import re
import sys

target, data = sys.argv[1], sys.argv[2]
REL = "smoketest/scripts/cli/test_service_ssh.py"
path = f"{target}/{REL}"

try:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
except FileNotFoundError:
    sys.exit(f"rebake-ssh-testca-cert: expected file not found (upstream sync "
             f"drift?): {REL}")

def read(name):
    with open(f"{data}/{name}", encoding="utf-8") as fh:
        return fh.read().strip()

def wrap(s, width=70):
    return "\n".join(s[i:i + width] for i in range(0, len(s), width))

# ca_cert_data is the base64 BODY only -- the test prepends the type itself
# via f'{public_key_type} {public_key_data}'.
ca_parts = read("ca.pub").split()
if len(ca_parts) < 2 or ca_parts[0] != "ssh-rsa":
    sys.exit("rebake-ssh-testca-cert: data/ssh-testca/ca.pub is not an ssh-rsa "
             "public key -- regenerate the fixture")
ca_body = ca_parts[1]

# cert_user_signed keeps its `ssh-rsa-cert-v01@openssh.com <base64>` form;
# the test flattens it with .replace('\n', ''), so the comment field must go
# or it would be concatenated into the base64.
cert_parts = read("user-cert.pub").split()
if len(cert_parts) < 2 or cert_parts[0] != "ssh-rsa-cert-v01@openssh.com":
    sys.exit("rebake-ssh-testca-cert: data/ssh-testca/user-cert.pub is not an "
             "ssh-rsa certificate -- regenerate the fixture")
cert_line = f"{cert_parts[0]} {cert_parts[1]}"

priv = read("user_key")
if not priv.startswith("-----BEGIN OPENSSH PRIVATE KEY-----"):
    sys.exit("rebake-ssh-testca-cert: data/ssh-testca/user_key is not an "
             "OpenSSH private key -- regenerate the fixture")

REPLACEMENTS = [
    ("ca_cert_data", r'(?s)(ca_cert_data = """\n).*?(\n""")',
     "\n" + wrap(ca_body) + "\n"),
    ("cert_user_key", r'(?s)(cert_user_key = """).*?(""")',
     priv + "\n"),
    ("cert_user_signed", r'(?s)(cert_user_signed = """\n).*?(\n""")',
     "\n" + wrap(cert_line) + "\n"),
]

changed = 0
for name, pattern, body in REPLACEMENTS:
    m = re.search(pattern, text)
    if not m:
        sys.exit(f"rebake-ssh-testca-cert: cannot find the {name} literal in "
                 f"{REL} -- upstream test layout changed, re-review by hand")
    # The captured delimiters are re-emitted verbatim; only the body changes.
    if name == "cert_user_key":
        new = m.group(1) + body + m.group(2)
    else:
        new = m.group(1).rstrip("\n") + body + m.group(2).lstrip("\n")
    if new != m.group(0):
        text = text[:m.start()] + new + text[m.end():]
        changed += 1

if changed:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"rebake-ssh-testca-cert: {changed} fixture literal(s) rebaked in {REL}")
else:
    print("rebake-ssh-testca-cert: fixture already matches data/ssh-testca (no-op)")

# Unconditional end-state check -- see "Fail-closed" in the header. The test
# needs the certificate to carry BOTH the username it logs in as and the
# principal it later configures, so assert against the file's own literals
# rather than hardcoded names.
# Scope the lookup to the CA test's own body: `test_user` is also defined by
# an unrelated test earlier in the file, and matching that one would compare
# the certificate against the wrong username.
body = re.search(r"(?s)\n    def test_ssh_trusted_user_ca\(self\):.*?(?=\n    def )", text)
if not body:
    sys.exit(f"rebake-ssh-testca-cert: cannot find test_ssh_trusted_user_ca in "
             f"{REL} -- upstream test layout changed, re-review by hand")

def literal(name):
    m = re.search(rf"^\s*{name} = '([^']*)'$", body.group(0), re.M)
    if not m:
        sys.exit(f"rebake-ssh-testca-cert: cannot find {name} in "
                 f"test_ssh_trusted_user_ca -- upstream test layout changed, "
                 "re-review by hand")
    return m.group(1)

test_user, principal = literal("test_user"), literal("principal")
with open(f"{data}/user-cert.pub", encoding="utf-8") as fh:
    blob = fh.read()

import base64
import struct

def ssh_string(buf, off):
    (n,) = struct.unpack(">I", buf[off:off + 4])
    return buf[off + 4:off + 4 + n], off + 4 + n

raw = base64.b64decode(blob.split()[1])
off = 0
# Walk the ssh-rsa-cert-v01 layout: string type, string nonce, mpint e,
# mpint n, uint64 serial, uint32 type, string key id, string principals.
_, off = ssh_string(raw, off)   # certificate type name
_, off = ssh_string(raw, off)   # nonce
_, off = ssh_string(raw, off)   # e
_, off = ssh_string(raw, off)   # n
off += 8                         # serial
off += 4                         # cert type (user/host)
_, off = ssh_string(raw, off)   # key id
principals_blob, off = ssh_string(raw, off)

principals, p = [], 0
while p < len(principals_blob):
    s, p = ssh_string(principals_blob, p)
    principals.append(s.decode())

missing = [n for n in (test_user, principal) if n not in principals]
if missing:
    sys.exit(f"rebake-ssh-testca-cert: certificate principals {principals} do "
             f"not cover {missing} (the test logs in as {test_user!r} and "
             f"configures principal {principal!r}) -- regenerate the fixture")
if any("vyos" in n.lower() for n in principals):
    sys.exit(f"rebake-ssh-testca-cert: certificate still carries a vyos "
             f"principal ({principals}) -- regenerate the fixture")
print(f"rebake-ssh-testca-cert: certificate principals {principals} cover "
      f"{test_user!r} and {principal!r}")
PYEOF
