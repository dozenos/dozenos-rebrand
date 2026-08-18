#!/usr/bin/env bash
#
# pin-toolchain-apt-source.sh -- revert the syft SBOM-tool download host in
# docker/Dockerfile back to the real `cdn.vyos.io` (audit item #12 class --
# same reasoning as logic-patches/revert-source-mirror-urls.sh: a real
# external build-time host DozenOS does not mirror, which rename-transform's
# four-form pass rewrites to a nonexistent dozenos host).
#
# The script's original namesake target, docker/dozenos-dev.list's
# `packages.vyos.net` apt-repo host, was removed upstream (vyos-build
# 35091fc, T9216, 2026-08-16: the dev container no longer consumes the VyOS
# binary repository at all), leaving the Dockerfile host as the sole target.
#
# Idempotent: no-op if already reverted. Fails loudly if neither the expected
# transformed nor already-reverted string is found in a target file (drift).
#
# Usage:
#   pin-toolchain-apt-source.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'pin-toolchain-apt-source: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

DOCKER="$TARGET/docker"

# entries: "relative-file|dozenos-form|vyos-form"
ENTRIES=(
  "Dockerfile|cdn.dozenos.io|cdn.vyos.io"
)

changed=0
already=0
for entry in "${ENTRIES[@]}"; do
  rel="${entry%%|*}"
  rest="${entry#*|}"
  dozenos_form="${rest%%|*}"
  vyos_form="${rest#*|}"
  f="$DOCKER/$rel"

  [ -f "$f" ] || die "expected file not found (upstream sync drift?): $f"

  if grep -qF "$dozenos_form" "$f"; then
    sed -i "s|${dozenos_form}|${vyos_form}|g" "$f"
    changed=$((changed + 1))
    echo "reverted: docker/$rel ($dozenos_form)"
  elif grep -qF "$vyos_form" "$f"; then
    already=$((already + 1))
    echo "already reverted (idempotent no-op): docker/$rel ($vyos_form)"
  else
    die "neither expected dozenos-rewritten nor already-reverted host found in $f for pattern '$vyos_form' -- drift, re-review by hand"
  fi
done

echo "pin-toolchain-apt-source: $changed reverted, $already already-clean (of ${#ENTRIES[@]} tracked)"
