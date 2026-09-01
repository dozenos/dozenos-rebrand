#!/usr/bin/env bash
#
# dockerfile-vyos-dev-list.sh -- add a Dockerfile COPY for
# new-files/docker/vyos-dev.list, so the build container installs it
# alongside docker/dozenos-dev.list.
#
# WHY: docker/dozenos-dev.list was rebranded on 2026-08-19 from the real,
# resolvable `packages.vyos.net` host to `packages.dozenos.net`, which does
# not exist and never has. That apt source is how `mk-build-deps` resolves
# frr's `libyang-dev (>= 3.0.3) | libyang2-dev (>= 2.1.128)` Build-Depends
# (Debian bookworm's own libyang2-dev is 2.1.30, well short of the required
# 2.1.128) and netfilter's equivalent libnftnl-dev dependency -- Debian
# bookworm cannot satisfy either on its own. The break sat dormant behind
# deb-cache hits until the 2026-08-31 kernel_version bump invalidated every
# cache key and forced a real rebuild (see INCIDENT-2026-08-31-frr-netfilter-mk-build-deps.md
# in this repo for the full timeline).
#
# FIX: `new-files/docker/vyos-dev.list` restores the exact pre-rebrand
# packages.vyos.net entry (recovered from dozenos-build history at commit
# 5b4005f, before the 2026-08-19 rebrand) as its OWN file, installed
# alongside (not instead of) the still-rebranded docker/dozenos-dev.list --
# dozenos-dev.list is left untouched on purpose, so it takes over cleanly if
# packages.dozenos.net is ever actually stood up. This script only adds the
# Dockerfile COPY line for the new file; it does not touch dozenos-dev.list
# or dozenos-dev.key.
#
# Idempotent: no-op if the COPY line is already present. Fails loudly if the
# anchor (the existing dozenos-dev.key COPY line) is gone -- an upstream
# Dockerfile change to how the dozenos-dev repo is installed must re-run
# this by hand, not be silently papered over.
#
# Usage:
#   dockerfile-vyos-dev-list.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'dockerfile-vyos-dev-list: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

DOCKERFILE="$TARGET/docker/Dockerfile"
[ -f "$DOCKERFILE" ] || die "expected file not found (upstream sync drift?): $DOCKERFILE"

COPY_LINE='COPY vyos-dev.list /etc/apt/sources.list.d/vyos-dev.list'
ANCHOR='COPY dozenos-dev.key /usr/share/keyrings/dozenos-dev-archive-keyring.asc'

if grep -qF "$COPY_LINE" "$DOCKERFILE"; then
  echo "dockerfile-vyos-dev-list: already present (idempotent no-op)"
  exit 0
fi
grep -qF "$ANCHOR" "$DOCKERFILE" || die "anchor line not found in $DOCKERFILE -- upstream changed how dozenos-dev.list is installed; re-review by hand"

tmp=$(mktemp)
awk -v ins="$COPY_LINE" -v anchor="$ANCHOR" '
  $0 == anchor && !done { print; print ins; done=1; next }
  { print }
' "$DOCKERFILE" > "$tmp"

if ! grep -qF "$COPY_LINE" "$tmp"; then
  rm -f "$tmp"
  die "failed to insert COPY line (anchor line did not match exactly) -- re-review by hand"
fi
mv "$tmp" "$DOCKERFILE"
echo "dockerfile-vyos-dev-list: inserted '$COPY_LINE' after the dozenos-dev.key COPY"
