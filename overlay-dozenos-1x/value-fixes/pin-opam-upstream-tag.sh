#!/usr/bin/env bash
#
# pin-opam-upstream-tag.sh -- rewrite dozenos-1x's opam pins for the OCaml
# config libs from the upstream COMMIT SHA to the mirror's corresponding
# `upstream-<sha>` TAG.
#
# WHY: libdozenosconfig/Makefile's `depends:` target opam-pins two libs:
#   opam pin add dozenos1x-config https://github.com/dozenos/dozenos1x-config.git#<sha> -y
#   opam pin add vyconf          https://github.com/dozenos/vyconf.git#<sha> -y
# rename-transform.sh's four-form pass correctly rewrote the package names and
# URL hosts (vyos -> dozenos), but it does NOT touch the `#<sha>` fragment --
# and that sha is the ORIGINAL vyos1x-config / vyconf UPSTREAM commit, which
# does not exist in our mode-B snapshot mirrors, so opam fails at build time
# with "Commit not found on repository".
#
# FIX: point at the tag `upstream-<sha>`, which mirror-push.sh --pin-commit
# creates on the mirror for exactly that upstream commit (a rename-transformed
# snapshot of that commit's tree). The rewrite is a PURE TEXT derivation --
# `#<sha>` -> `#upstream-<sha>`, no sha lookup table, no recorded state, no
# change detection. Whatever commit upstream pins, we point at the mirror tag
# named after it; ensuring that tag exists is mirror-push.sh's job and is
# idempotent, so nothing here needs to know whether upstream moved the pin.
#
# This REPLACES the earlier `#rolling` rewrite. Pinning to the mirror's branch
# tip meant we built whatever vyconf HEAD happened to be at sync time rather
# than the commit upstream actually builds, which (a) made the build
# unreproducible -- the same dozenos-1x source could link a different vyconf on
# different days -- and (b) dragged in vyconf commits upstream never builds.
# One of those was vyconf 0d61bd7 (T9044, 2026-07-02), which constrains
# ocaml-protoc to < 3.0 while the committed src/vyconf_pbt.ml still uses the
# 3.x `pbrt` API, so `dune build -p vyconf` cannot compile. Upstream never hits
# it because vyos-1x pins vyconf at e25b13ae (2026-03-04), whose vyconf.opam
# carries no ocaml-protoc constraint at all. Building the pinned commit removes
# that whole divergence -- and with it overlay-vyconf/, which existed solely to
# patch that pin back out.
#
# Idempotent: a pin already at `#upstream-<sha>` is a no-op. Fails loudly if a
# target URL is present but pinned to neither a 7-40 hex sha nor an
# `upstream-<sha>` tag (drift), or if a target URL is missing entirely.
#
# Usage:
#   pin-opam-upstream-tag.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'pin-opam-upstream-tag: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

MAKEFILE="$TARGET/libdozenosconfig/Makefile"
# The real dozenos-1x tree always has this Makefile; a minimal tree that lacks
# it entirely (e.g. a synthetic test fixture) simply has no opam pins to fix --
# skip quietly. Real drift that MATTERS (the Makefile present but pinned to a
# non-resolvable form) is still caught below, and a genuinely missing Makefile
# would fail the dozenos-1x build itself, loudly, downstream.
if [ ! -f "$MAKEFILE" ]; then
  echo "pin-opam-upstream-tag: no libdozenosconfig/Makefile in $TARGET -- nothing to pin (skip)"
  exit 0
fi

# base URL (without the #fragment) for each pinned lib
URLS=(
  "https://github.com/dozenos/dozenos1x-config.git"
  "https://github.com/dozenos/vyconf.git"
)

changed=0
already=0
for url in "${URLS[@]}"; do
  esc=$(printf '%s' "$url" | sed 's/[.[\*^$/]/\\&/g')
  if grep -qE "${esc}#upstream-[0-9a-f]{7,40}([^0-9a-f]|$)" "$MAKEFILE"; then
    already=$((already + 1))
    echo "already #upstream-<sha> (idempotent no-op): ${url}"
  elif grep -qE "${esc}#[0-9a-f]{7,40}([^0-9a-f]|$)" "$MAKEFILE"; then
    # pinned to a bare commit sha -> rewrite to the mirror's tag for it
    sed -i -E "s|(${esc})#([0-9a-f]{7,40})|\1#upstream-\2|g" "$MAKEFILE"
    changed=$((changed + 1))
    echo "re-pinned to #upstream-<sha>: ${url}"
  else
    die "opam pin URL '${url}' present in neither '#<sha>' nor '#upstream-<sha>' form in ${MAKEFILE} -- drift, re-review by hand"
  fi
done

echo "pin-opam-upstream-tag: $changed re-pinned, $already already-clean (of ${#URLS[@]} pins)"
