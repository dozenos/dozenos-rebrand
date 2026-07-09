#!/usr/bin/env bash
#
# remove-committed-mok-cert.sh -- delete the real, committed VyOS Secure Boot
# MOK enrollment certificate that a fresh clone still ships (audit item #9).
#
# WHY: `data/certificates/vyos-prod-2025-linux.pem` in pristine upstream is a
# REAL X.509 certificate (subject "VyOS Networks Secure Boot Signer 2025").
# rename-transform.sh's path-rename pass renames the FILE to
# `dozenos-prod-2025-linux.pem` (its name contains "vyos"), but the cert's
# DER/base64 body is unaffected content -- it is still, literally, VyOS's
# real Secure Boot signing cert, just under a renamed filename. That is a
# value-not-string problem the four-form transform structurally cannot fix
# (per overlay-dozenos-build/README.md's own definition of what belongs in value-fixes/):
# no textual substitution turns someone else's real certificate into ours.
#
# DECISION (already made, see data/certificates/README.md, shipped via
# overlay-dozenos-build/new-files/): do not fabricate or ship a placeholder cert. Delete
# the inherited VyOS cert entirely; the real DozenOS enrollment cert is
# injected at CI build time from the org secret `MOK_SIGNING_CERT` (Phase 4).
# Local/dev builds simply ship an empty data/certificates/ (README +
# .gitignore only) -- `93-sb-sign-kernel.chroot` already tolerates a missing
# key/cert pair and skips kernel signing rather than failing.
#
# Idempotent: if the renamed cert file is already absent (e.g. a second run,
# or CI already injected+consumed it), this is a silent no-op -- absence IS
# the desired end state, not an error. Fails loudly only if the file is
# present but does NOT look like the expected inherited VyOS cert (a `.pem`
# whose subject mentions "VyOS") -- i.e. if something else entirely is
# sitting at that path, don't blindly delete it.
#
# Usage:
#   remove-committed-mok-cert.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'remove-committed-mok-cert: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

F="$TARGET/data/certificates/dozenos-prod-2025-linux.pem"

if [ ! -e "$F" ]; then
  echo "remove-committed-mok-cert: already absent (idempotent no-op)"
  exit 0
fi

if command -v openssl >/dev/null 2>&1; then
  subject=$(openssl x509 -in "$F" -noout -subject 2>/dev/null || true)
  case "$subject" in
    *VyOS*) : ;;  # expected -- the inherited real cert
    *) die "refusing to delete $F: does not look like the inherited VyOS cert (subject: '$subject') -- re-review by hand" ;;
  esac
else
  # No openssl available to sanity-check the subject -- fall back to a
  # cheap content check instead of skipping verification entirely.
  grep -q "BEGIN CERTIFICATE" "$F" || die "refusing to delete $F: not a PEM certificate -- re-review by hand"
fi

rm -f "$F"
echo "remove-committed-mok-cert: deleted inherited VyOS Secure Boot cert ($F)"
