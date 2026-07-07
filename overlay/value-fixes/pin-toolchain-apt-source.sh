#!/usr/bin/env bash
#
# pin-toolchain-apt-source.sh -- revert the build-time toolchain apt-source
# host in docker/dozenos-dev.list (and its Dockerfile comment) back to the
# real `packages.vyos.net` (audit item #12 class -- same reasoning as
# logic-patches/revert-source-mirror-urls.sh, applied to the dev-container
# toolchain apt source instead of a kernel-recipe tarball fetch).
#
# WHY: rename-transform.sh's four-form pass rewrites `packages.vyos.net` to
# `packages.dozenos.net` (nonexistent) inside docker/vyos-dev.list (renamed by
# the transform's path pass to docker/dozenos-dev.list; the filename rename
# itself is correct and NOT reverted here -- only the URL content is). This is
# a real external apt repository DozenOS does not mirror yet -- there is no
# apt-tracked DozenOS distro (image-based upgrade model, see the CI/CD plan),
# so self-hosting this is out of scope; keep pointing at the real host until
# that decision changes.
#
# Targets (two DIFFERENT real external hosts, both in docker/, both hit by
# the same four-form substring rule):
#   docker/dozenos-dev.list  packages.vyos.net   (apt repo, item #12)
#   docker/Dockerfile        cdn.vyos.io         (syft SBOM-tool tarball
#                                                 download, ~line 336-337 --
#                                                 NOT in the original audit's
#                                                 item #12 write-up; found
#                                                 during #18b overlay work.
#                                                 The live hand-edited tree
#                                                 has NOT reverted this one
#                                                 either -- confirmed via
#                                                 `grep cdn.vyos.io
#                                                 docker/Dockerfile`, still
#                                                 present unreverted there --
#                                                 so this is a genuinely new
#                                                 finding, not a duplicate of
#                                                 already-tracked work.)
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
  "dozenos-dev.list|packages.dozenos.net|packages.vyos.net"
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
