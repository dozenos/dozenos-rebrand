#!/usr/bin/env bash
#
# Integration test for release/inject-mok-cert.sh (progress item #10, see
# ../SB-SIGNING.md).
#
# NEVER uses real key material. Generates a THROWAWAY, self-signed test
# keypair in a mktemp dir purely to exercise the script's decode/write/
# verify/cleanup code paths -- the same shape a real MOK_SIGNING_KEY/
# MOK_SIGNING_CERT secret pair would arrive in (base64, no line wraps), but
# with content that is unambiguously not a real MOK (CN says so). Nothing
# generated here is committed or leaves this test's own mktemp dir.
#
# Asserts:
#   1. Fails loudly (non-zero, no files written) with MOK_SIGNING_KEY unset.
#   2. Fails loudly with MOK_SIGNING_CERT unset (key present).
#   3. Fails loudly on a missing <target-tree> argument / nonexistent dir.
#   4. Fails loudly (shape check) if a secret decodes to non-PEM garbage.
#   5. Happy path: writes key+cert+DER at the exact paths the hook +
#      build-dozenos-image + install_mok.sh expect, key mode 0600, cert and
#      DER mode 0644.
#   6. Idempotent: running twice with the same secrets is byte-identical
#      (key, cert, AND the derived DER).
#   7. --cleanup removes all three files; a second --cleanup is a silent
#      no-op.
#   8. The script itself never contains PEM headers or base64 key-shaped
#      blobs (zero embedded key material).
#   9. Cert-chain consistency (progress item #11): the DER this script
#      derives and the PEM it was derived from decode to the SAME
#      certificate (same SHA-256 fingerprint) -- proving install_mok.sh's
#      enrollment cert and 93-sb-sign-kernel.chroot's signing cert are one
#      MOK, not two different ones.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/release/inject-mok-cert.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

[ -x "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found or not executable"; exit 1; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP: openssl not available, cannot generate a throwaway test keypair"
  exit 0
fi

# ---------------------------------------------------------------------------
# Generate a THROWAWAY test keypair (mktemp only, never committed).
# ---------------------------------------------------------------------------
openssl req -new -x509 -newkey rsa:2048 \
  -keyout "$WORK/throwaway.key" -out "$WORK/throwaway.pem" \
  -nodes -days 1 -subj "/CN=THROWAWAY TEST ONLY - not a real MOK/" \
  >/dev/null 2>&1

KEY_B64=$(base64 -w0 < "$WORK/throwaway.key")
CERT_B64=$(base64 -w0 < "$WORK/throwaway.pem")

fresh_tree() {
  local t="$WORK/tree-$1"
  rm -rf "$t"
  mkdir -p "$t/data/certificates"
  printf '%s\n' "$t"
}

echo "== fail-loud =="

t=$(fresh_tree 1)
if ! env -u MOK_SIGNING_KEY -u MOK_SIGNING_CERT "$SCRIPT" "$t" >/dev/null 2>&1 \
  && [ ! -e "$t/data/certificates/dozenos-dev-2025-linux.key" ]; then
  ok "MOK_SIGNING_KEY unset: fails, writes nothing"
else
  bad "MOK_SIGNING_KEY unset: expected non-zero exit + no file"
fi

t=$(fresh_tree 2)
if ! MOK_SIGNING_KEY="$KEY_B64" env -u MOK_SIGNING_CERT "$SCRIPT" "$t" >/dev/null 2>&1 \
  && [ ! -e "$t/data/certificates/dozenos-dev-2025-linux.pem" ]; then
  ok "MOK_SIGNING_CERT unset (key present): fails, writes no cert"
else
  bad "MOK_SIGNING_CERT unset: expected non-zero exit + no cert file"
fi

if ! env -u MOK_SIGNING_KEY -u MOK_SIGNING_CERT "$SCRIPT" >/dev/null 2>&1; then
  ok "missing <target-tree> arg: fails"
else
  bad "missing <target-tree> arg: expected non-zero exit"
fi

if ! MOK_SIGNING_KEY="$KEY_B64" MOK_SIGNING_CERT="$CERT_B64" "$SCRIPT" "$WORK/does-not-exist" >/dev/null 2>&1; then
  ok "nonexistent target-tree: fails"
else
  bad "nonexistent target-tree: expected non-zero exit"
fi

t=$(fresh_tree 3)
if ! MOK_SIGNING_KEY="$(printf 'not-a-real-key' | base64 -w0)" MOK_SIGNING_CERT="$CERT_B64" "$SCRIPT" "$t" >/dev/null 2>&1; then
  ok "garbage-shaped MOK_SIGNING_KEY (no PEM header): fails"
else
  bad "garbage key: expected non-zero exit"
fi

echo "== happy path =="

t=$(fresh_tree 4)
out=$(MOK_SIGNING_KEY="$KEY_B64" MOK_SIGNING_CERT="$CERT_B64" "$SCRIPT" "$t" 2>&1)
rc=$?
key_path="$t/data/certificates/dozenos-dev-2025-linux.key"
cert_path="$t/data/certificates/dozenos-dev-2025-linux.pem"
der_path="$t/data/certificates/dozenos-dev-2025-shim.der"

if [ "$rc" -eq 0 ]; then ok "happy path: exits 0 ($out)"; else bad "happy path: expected exit 0, got $rc ($out)"; fi
if [ -f "$key_path" ]; then ok "key written at hook-expected path"; else bad "key NOT written at $key_path"; fi
if [ -f "$cert_path" ]; then ok "cert written at hook-expected path"; else bad "cert NOT written at $cert_path"; fi
if [ -f "$der_path" ]; then ok "DER written at install_mok.sh-expected path"; else bad "DER NOT written at $der_path"; fi

key_mode=$(stat -c '%a' "$key_path" 2>/dev/null)
if [ "$key_mode" = "600" ]; then ok "key mode is 600"; else bad "key mode is '$key_mode', expected 600"; fi
cert_mode=$(stat -c '%a' "$cert_path" 2>/dev/null)
if [ "$cert_mode" = "644" ]; then ok "cert mode is 644"; else bad "cert mode is '$cert_mode', expected 644"; fi
der_mode=$(stat -c '%a' "$der_path" 2>/dev/null)
if [ "$der_mode" = "644" ]; then ok "DER mode is 644"; else bad "DER mode is '$der_mode', expected 644"; fi

if cmp -s "$key_path" "$WORK/throwaway.key"; then ok "written key bytes match source (decode round-trip)"; else bad "written key bytes DO NOT match source"; fi
if cmp -s "$cert_path" "$WORK/throwaway.pem"; then ok "written cert bytes match source (decode round-trip)"; else bad "written cert bytes DO NOT match source"; fi

echo "== cert-chain consistency (item #11: PEM and DER are the SAME cert) =="
pem_fp=$(openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null)
der_fp=$(openssl x509 -in "$der_path" -inform DER -noout -fingerprint -sha256 2>/dev/null)
if [ -n "$pem_fp" ] && [ "$pem_fp" = "$der_fp" ]; then
  ok "shim .der and linux .pem have identical SHA-256 fingerprint (one MOK, two encodings)"
else
  bad "fingerprint mismatch: pem='$pem_fp' der='$der_fp' -- shim would enroll a DIFFERENT cert than the one signing the kernel"
fi

echo "== idempotency =="
before=$(sha256sum "$key_path" "$cert_path" "$der_path")
MOK_SIGNING_KEY="$KEY_B64" MOK_SIGNING_CERT="$CERT_B64" "$SCRIPT" "$t" >/dev/null 2>&1
after=$(sha256sum "$key_path" "$cert_path" "$der_path")
if [ "$before" = "$after" ]; then ok "second write run is byte-identical (incl. derived DER)"; else bad "second write run changed file contents"; fi

echo "== --cleanup =="
"$SCRIPT" "$t" --cleanup >/dev/null 2>&1
if [ ! -e "$key_path" ] && [ ! -e "$cert_path" ] && [ ! -e "$der_path" ]; then ok "--cleanup removes all three files"; else bad "--cleanup left a file behind"; fi

if "$SCRIPT" "$t" --cleanup >/dev/null 2>&1; then
  ok "second --cleanup is a silent no-op (exit 0)"
else
  bad "second --cleanup exited non-zero"
fi

echo "== zero embedded key material =="
# The script legitimately references the literal strings "BEGIN PRIVATE KEY"
# / "BEGIN CERTIFICATE" (as grep patterns and in comments/usage text) to
# shape-validate a *decoded* secret -- that is expected and not a leak. The
# real proof of zero embedded key material is the absence of an actual PEM
# body: no long base64-only line (PEM wraps body lines at 64 chars) and no
# base64 blob shaped like a real key/cert fragment.
if grep -qE '^[A-Za-z0-9+/]{60,}={0,2}$' "$SCRIPT"; then
  bad "script contains a PEM-body-shaped line (looks like embedded key material)"
else
  ok "script contains no PEM-body-shaped line"
fi
if grep -qE "MII[A-Za-z0-9+/=]{20,}" "$SCRIPT"; then
  bad "script contains a base64 key-shaped blob"
else
  ok "script contains no base64 key-shaped blob"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
