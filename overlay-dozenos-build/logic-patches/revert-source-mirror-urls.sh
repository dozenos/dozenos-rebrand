#!/usr/bin/env bash
#
# revert-source-mirror-urls.sh -- revert the external tarball "source-mirror"
# fetch URLs that rename-transform.sh's four-form pass incorrectly rewrites.
#
# WHY: rename-transform.sh's generic four-form rule rewrites every literal
# "vyos" substring, including inside `https://packages.vyos.net/source-mirror/*`
# URLs used by three linux-kernel OOT-driver build scripts to fetch real
# upstream vendor tarballs (Intel QAT, Realtek r8126/r8152 firmware blobs).
# `packages.vyos.net` is a REAL external tarball host we do not mirror --
# unlike a git `scm_url` (which dissolves into a real fetchable target once
# `github.com/dozenos/*` mirrors exist), this is a third-party binary vendor
# archive with no DozenOS equivalent. Rewriting it to `packages.dozenos.net`
# produces a URL that will never resolve, breaking every future rebuild of
# these three recipes.
#
# DECISION (revisit if this changes): revert to the real upstream host
# `packages.vyos.net/source-mirror` rather than self-hosting a DozenOS
# source-mirror. Self-hosting remains the alternative if VyOS's mirror ever
# goes away or rate-limits us -- tracked as a follow-on, not implemented here.
#
# Targets (fixed list, NOT discovered by grep at run time on purpose -- a
# grep-driven "fix anything that looks like this" approach would silently
# start reverting NEW upstream-sync-introduced source-mirror URLs we haven't
# reviewed, or silently do nothing if these three files are removed/renamed
# upstream. Failing loudly on drift is the point: an upstream sync that
# changes these files must re-run this audit by hand, not have this script
# quietly paper over it):
#
#   scripts/package-build/linux-kernel/build-intel-qat.sh       (line ~17)
#   scripts/package-build/linux-kernel/build-realtek-r8126.py   (line ~37)
#   scripts/package-build/linux-kernel/build-realtek-r8152.py   (line ~38)
#
# Usage:
#   revert-source-mirror-urls.sh <target-tree>
#
# Idempotent: running twice is a no-op the second time (each target line is
# checked in EITHER the dozenos-rewritten form OR the already-reverted vyos
# form; only the rewritten form triggers a sed edit). Exits non-zero and
# prints a diagnostic if a target file is missing or neither the expected
# rewritten nor already-reverted string is found (drift -- do not silently
# no-op).
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'revert-source-mirror-urls: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

LK="$TARGET/scripts/package-build/linux-kernel"

# entries: "relative-file|dozenos-form|vyos-form"
ENTRIES=(
  "build-intel-qat.sh|https://packages.dozenos.net/source-mirror/|https://packages.vyos.net/source-mirror/"
  "build-realtek-r8126.py|https://packages.dozenos.net/source-mirror/|https://packages.vyos.net/source-mirror/"
  "build-realtek-r8152.py|https://packages.dozenos.net/source-mirror/|https://packages.vyos.net/source-mirror/"
)

changed=0
already=0
for entry in "${ENTRIES[@]}"; do
  rel="${entry%%|*}"
  rest="${entry#*|}"
  dozenos_form="${rest%%|*}"
  vyos_form="${rest#*|}"
  f="$LK/$rel"

  [ -f "$f" ] || die "expected file not found (upstream sync drift?): $f"

  if grep -qF "$dozenos_form" "$f"; then
    sed -i "s|${dozenos_form}|${vyos_form}|g" "$f"
    changed=$((changed + 1))
    echo "reverted: $rel"
  elif grep -qF "$vyos_form" "$f"; then
    already=$((already + 1))
    echo "already reverted (idempotent no-op): $rel"
  else
    die "neither expected dozenos-rewritten nor already-reverted source-mirror URL found in $f -- upstream sync drift, re-review by hand"
  fi
done

echo "revert-source-mirror-urls: $changed reverted, $already already-clean (of ${#ENTRIES[@]} tracked)"
