#!/usr/bin/env bash
#
# pin-opam-ocaml-branch.sh -- rewrite dozenos-1x's opam pins for the OCaml
# config libs from a specific upstream COMMIT SHA to the `rolling` BRANCH.
#
# WHY: libdozenosconfig/Makefile's `depends:` target opam-pins two libs:
#   opam pin add dozenos1x-config https://github.com/dozenos/dozenos1x-config.git#<sha> -y
#   opam pin add vyconf          https://github.com/dozenos/vyconf.git#<sha> -y
# rename-transform.sh's four-form pass correctly rewrote the package names and
# URL hosts (vyos -> dozenos), but it does NOT touch the `#<sha>` fragment --
# and that sha is the ORIGINAL vyos1x-config / vyconf UPSTREAM commit. The
# dozenos/* mirrors are mode-B rename-transform SNAPSHOTS: each carries a
# single fresh commit whose hash is NOT the upstream hash, so opam fails at
# build time with "Commit not found on repository" (observed in the
# dozenos-1x package-build job). There is no stable dozenos-side sha to pin to
# (it changes on every mirror sync), so pin to the mirror's tracking BRANCH
# (`rolling`) instead -- opam then resolves the branch HEAD, which always
# exists. This matches the rolling-release model (the mirrors ARE `rolling`).
#
# Targets (libdozenosconfig/Makefile, both opam pin lines):
#   github.com/dozenos/dozenos1x-config.git#<sha>  -> #rolling
#   github.com/dozenos/vyconf.git#<sha>            -> #rolling
#
# Idempotent: a pin already at `#rolling` is a no-op. Fails loudly if a target
# URL is present but pinned to neither a 7-40 hex sha nor `rolling` (drift), or
# if the Makefile / a target URL is missing entirely (upstream sync drift).
#
# Usage:
#   pin-opam-ocaml-branch.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'pin-opam-ocaml-branch: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

MAKEFILE="$TARGET/libdozenosconfig/Makefile"
[ -f "$MAKEFILE" ] || die "expected file not found (upstream sync drift?): $MAKEFILE"

BRANCH="rolling"
# base URL (without the #fragment) for each pinned lib
URLS=(
  "https://github.com/dozenos/dozenos1x-config.git"
  "https://github.com/dozenos/vyconf.git"
)

changed=0
already=0
for url in "${URLS[@]}"; do
  esc=$(printf '%s' "$url" | sed 's/[.[\*^$/]/\\&/g')
  if grep -qE "${esc}#[0-9a-f]{7,40}([^0-9a-f]|$)" "$MAKEFILE"; then
    # pinned to a commit sha -> rewrite to the branch
    sed -i -E "s|(${esc})#[0-9a-f]{7,40}|\1#${BRANCH}|g" "$MAKEFILE"
    changed=$((changed + 1))
    echo "re-pinned to #${BRANCH}: ${url}"
  elif grep -qF "${url}#${BRANCH}" "$MAKEFILE"; then
    already=$((already + 1))
    echo "already #${BRANCH} (idempotent no-op): ${url}"
  else
    die "opam pin URL '${url}' present in neither '#<sha>' nor '#${BRANCH}' form in ${MAKEFILE} -- drift, re-review by hand"
  fi
done

echo "pin-opam-ocaml-branch: $changed re-pinned, $already already-clean (of ${#URLS[@]} pins)"
