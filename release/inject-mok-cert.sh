#!/usr/bin/env bash
# inject-mok-cert.sh -- materialize the real DozenOS Secure Boot MOK
# key+cert from CI secrets onto disk, at the exact paths
# `data/live-build-config/hooks/live/93-sb-sign-kernel.chroot` reads (via
# `/var/lib/shim-signed/mok/`) and `scripts/image-build/build-dozenos-image`
# stages there (see ../SB-SIGNING.md for the end-to-end flow; progress
# item #10), PLUS the DER re-encoding of the same public cert that
# `install_mok.sh` (the `install mok` op-mode command, shipped by the
# dozenos-1x package) enrolls via `mokutil` on a running DozenOS system
# (progress item #11 -- see ../SB-SIGNING.md "shim-signed / MOK enrollment").
#
# This script NEVER contains, generates, or fabricates key material. It only
# ever references the CI secret NAMES below (see ../CI-SECRETS.md, which is
# authoritative for the exact names):
#   MOK_SIGNING_KEY   -- base64 of the MOK private key (PEM, "BEGIN PRIVATE KEY")
#   MOK_SIGNING_CERT  -- base64 of the MOK public cert (PEM, "BEGIN CERTIFICATE")
#
# It fails loudly (does not fabricate a throwaway key) if either is
# unset/empty.
#
# Usage (run inside a CI job, both env vars exported from secrets, BEFORE
# live-build runs so `93-sb-sign-kernel.chroot` finds the pair at chroot
# time -- see ../SB-SIGNING.md "Where this runs in CI"):
#   MOK_SIGNING_KEY="$MOK_SIGNING_KEY"   \
#   MOK_SIGNING_CERT="$MOK_SIGNING_CERT" \
#   ./inject-mok-cert.sh <target-tree>
#
# Or, to remove what this script wrote once the build no longer needs it
# (the runner is destroyed at job end regardless, but this shrinks the
# window the decoded private key sits on disk -- see "Cleanup" below):
#   ./inject-mok-cert.sh <target-tree> --cleanup
#
# What it writes (all three filenames match what `93-sb-sign-kernel.chroot`
# and `install_mok.sh` read via `/var/lib/shim-signed/mok/`, since
# `build-dozenos-image` copies `data/certificates/` there *wholesale*,
# filenames preserved -- see ../SB-SIGNING.md):
#   <target-tree>/data/certificates/dozenos-dev-2025-linux.key   (mode 0600, private)
#   <target-tree>/data/certificates/dozenos-dev-2025-linux.pem   (mode 0644, public --
#     the cert `sbsign` signs vmlinuz against)
#   <target-tree>/data/certificates/dozenos-dev-2025-shim.der    (mode 0644, public --
#     DER re-encoding of the SAME cert as the .pem above, produced with
#     `openssl x509 -in <.pem> -outform DER -out <.der>`; this is the exact
#     filename `install_mok.sh`'s `mokutil --import` call expects. One MOK,
#     two encodings -- see ../SB-SIGNING.md "Cert-chain consistency" for why
#     the .pem and .der MUST be the same underlying cert, not two different
#     ones.)
#
# `data/certificates/.gitignore` (upstream, unmodified by the rebrand) is
# `*.key` -- the private key this script writes can never be `git add`-ed
# even by accident. The `.pem` and `.der` are public and are not gitignored
# (consistent with each other), but this script never runs `git add`/
# `git commit` itself either way.
#
# Idempotent: re-running with the same secrets overwrites all three files
# with byte-identical content (decode is a pure function of the env var, and
# `openssl x509 -outform DER` re-encoding of a fixed input is deterministic);
# safe to call more than once in the same job.
#
# Cleanup: `--cleanup` shreds (or, if `shred` is unavailable, zeroes then
# unlinks) the private key and removes the public cert + DER this script
# wrote, then exits 0. Idempotent -- a second `--cleanup` run on an
# already-cleaned tree is a silent no-op, not an error. Call this after the
# live-build chroot has already staged its own copy (`93-sb-sign-kernel.chroot`
# itself also `rm -f`s the in-chroot private key after signing -- this
# `--cleanup` call is the matching removal for the copy that sits *outside*
# the chroot, in the job's own git worktree, from the moment this script
# writes it until the job ends).
set -euo pipefail

die() { printf 'inject-mok-cert: %s\n' "$*" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
Usage: inject-mok-cert.sh <target-tree> [--cleanup]

  <target-tree>   Root of the dozenos-build checkout (the directory
                   containing data/certificates/).

  --cleanup        Remove/shred the key+cert this script previously wrote
                   under <target-tree>/data/certificates/, instead of
                   writing them. Idempotent.

Required env vars for the default (write) mode -- never pass key material
as an argument:
  MOK_SIGNING_KEY    base64-encoded MOK private key (CI-SECRETS.md: org
                     secret MOK_SIGNING_KEY)
  MOK_SIGNING_CERT   base64-encoded MOK public cert (CI-SECRETS.md: org
                     secret MOK_SIGNING_CERT)
EOF
}

TARGET="${1:-}"
MODE="write"
if [ "${2:-}" = "--cleanup" ]; then
  MODE="cleanup"
elif [ -n "${2:-}" ]; then
  usage
  die "unknown argument: $2"
fi

[ -n "$TARGET" ] || { usage; die "missing required <target-tree>"; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

CERT_DIR="$TARGET/data/certificates"
KEY_PATH="$CERT_DIR/dozenos-dev-2025-linux.key"
CERT_PATH="$CERT_DIR/dozenos-dev-2025-linux.pem"
SHIM_DER_PATH="$CERT_DIR/dozenos-dev-2025-shim.der"

shred_file() {
  f="$1"
  [ -e "$f" ] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
  else
    : > "$f" 2>/dev/null || true
    rm -f -- "$f"
  fi
}

if [ "$MODE" = "cleanup" ]; then
  shred_file "$KEY_PATH"
  rm -f -- "$CERT_PATH" "$SHIM_DER_PATH"
  echo "inject-mok-cert: cleaned up ${KEY_PATH#"$TARGET"/} + ${CERT_PATH#"$TARGET"/} + ${SHIM_DER_PATH#"$TARGET"/} (idempotent no-op if already absent)"
  exit 0
fi

[ -d "$CERT_DIR" ] || die "not a directory: $CERT_DIR (expected data/certificates/ to already exist in <target-tree>, see data/certificates/README.md)"

# Fail loudly rather than silently signing with nothing / fabricating a key.
if [ -z "${MOK_SIGNING_KEY:-}" ]; then
  die "MOK_SIGNING_KEY is unset or empty -- refusing to fabricate a throwaway key. See ../CI-SECRETS.md."
fi
if [ -z "${MOK_SIGNING_CERT:-}" ]; then
  die "MOK_SIGNING_CERT is unset or empty. See ../CI-SECRETS.md."
fi

old_umask="$(umask)"
umask 077
printf '%s' "$MOK_SIGNING_KEY" | base64 -d > "$KEY_PATH"
chmod 600 "$KEY_PATH"
umask "$old_umask"

printf '%s' "$MOK_SIGNING_CERT" | base64 -d > "$CERT_PATH"
chmod 644 "$CERT_PATH"

if [ ! -s "$KEY_PATH" ]; then
  die "decoded MOK_SIGNING_KEY is empty -- check encoding (expected: base64 -w0 of the PEM private key)"
fi
if [ ! -s "$CERT_PATH" ]; then
  die "decoded MOK_SIGNING_CERT is empty -- check encoding (expected: base64 -w0 of the PEM cert)"
fi

# Sanity-check shape (not authenticity) of what was decoded, so a
# misconfigured secret (wrong secret pasted, double-base64'd, etc.) fails
# here with a clear message instead of silently producing an unsigned image
# 40 minutes into a live-build run.
if ! grep -q "BEGIN.*PRIVATE KEY" "$KEY_PATH"; then
  die "decoded MOK_SIGNING_KEY does not look like a PEM private key (no 'BEGIN ... PRIVATE KEY' header) -- check the secret's contents"
fi
if ! grep -q "BEGIN CERTIFICATE" "$CERT_PATH"; then
  die "decoded MOK_SIGNING_CERT does not look like a PEM certificate (no 'BEGIN CERTIFICATE' header) -- check the secret's contents"
fi

# Derive the DER re-encoding install_mok.sh's `mokutil --import` expects,
# from the SAME cert just written above -- never a second/different cert.
# This is a pure re-encoding (no signing, no key involved), so it is exactly
# as idempotent as the .pem write itself.
command -v openssl >/dev/null 2>&1 || die "openssl not found -- required to derive ${SHIM_DER_PATH#"$TARGET"/} (DER) from ${CERT_PATH#"$TARGET"/} (PEM). See ../SB-SIGNING.md."
if ! openssl x509 -in "$CERT_PATH" -outform DER -out "$SHIM_DER_PATH"; then
  die "openssl failed to convert ${CERT_PATH#"$TARGET"/} (PEM) to DER -- check that MOK_SIGNING_CERT decoded to a valid X.509 certificate"
fi
chmod 644 "$SHIM_DER_PATH"

if [ ! -s "$SHIM_DER_PATH" ]; then
  die "derived ${SHIM_DER_PATH#"$TARGET"/} is empty after openssl conversion"
fi

echo "inject-mok-cert: wrote ${KEY_PATH#"$TARGET"/} (mode 600) + ${CERT_PATH#"$TARGET"/} (mode 644) + ${SHIM_DER_PATH#"$TARGET"/} (mode 644)"
