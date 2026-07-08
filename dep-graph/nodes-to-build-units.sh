#!/usr/bin/env bash
#
# nodes-to-build-units.sh -- item #30 NORMALIZED build-unit resolver.
#
# Fixes a real defect item #16 flagged and left NEEDS-HUMAN (see
# dep-graph.json's own "_notes.item16_rebuild_dispatch_directory_mapping_gap"
# and DEP-GRAPH.md's own "Flagged, not fixed" section): resolve-rebuild-set.sh
# emits a transitive-closure NODE set (e.g. resolving "strongswan" includes
# "python3-vici"), but several node identifiers are NOT
# scripts/package-build/ directory names -- they are binary .deb names
# (python3-vici, libtac2, isc-kea-common, libyang3, ...) or linux-kernel
# `--packages <block>` block names (i40e, mlnx, realtek-r8126, ...). A bare
# `cd scripts/package-build/<node>` fails for any of those.
#
# This script wraps resolve-rebuild-set.sh: it resolves the SAME transitive
# closure that script would (reusing it verbatim, not re-implementing BFS),
# then maps every node in that closure to its real buildable UNIT via
# dep-graph.json's own "build_units.node_to_unit" map, and DEDUPS:
#   - multiple non-kernel nodes mapping to the same recipe (e.g. libtac2 +
#     libtacplus-map1, both -> recipe "tacacs") collapse to ONE
#     {"recipe": "tacacs"} unit.
#   - every resolved linux-kernel-family node (a kernel_block-mapped node, or
#     the bare "linux-kernel" node itself) collapses to ONE
#     {"recipe": "linux-kernel", "kernel_blocks": [...]} unit, whose
#     "kernel_blocks" is the SORTED, DEDUPED union of every resolved block,
#     with "linux-kernel" itself ALWAYS included even when it was not
#     literally in the closure (see "Why 'linux-kernel' is always in the
#     union" below -- this is a correctness requirement, not a convenience).
#
# A node with NO entry in "build_units.node_to_unit" is NOT invented a
# directory: if its name happens to match a real recipe directory or a real
# linux-kernel block (from "build_units.recipe_dirs" / "kernel_blocks"), it
# is mapped by that identity match (covers a brand-new recipe added upstream
# after dep-graph.json was last regenerated -- the same "known-incomplete by
# design" tolerance resolve-rebuild-set.sh already has for unknown packages);
# otherwise it is dropped from the emitted matrix with a warning on stderr
# (never a hard failure -- matches resolve-rebuild-set.sh's own "soft"
# unknown-package contract) and is NEVER `cd`-ed into blindly.
#
# Why "linux-kernel" is always in the union: linux-kernel/build-kernel.sh
# writes a `kernel-vars` file (KERNEL_DIR=...) that every OOT module driver
# script requires -- build-intel-nic.sh's own header aborts with
# "KERNEL_DIR not defined" if that file is missing/empty (confirmed by
# reading both scripts on the reproduced tree). Since linux-kernel/build.py's
# own --packages filter only builds the packages named, filtering OUT the
# "linux-kernel" block itself would build "python3 build.py --packages i40e"
# with no kernel-vars ever generated -- a hard failure, not just an
# incremental-vs-full tradeoff. So this script always adds "linux-kernel" to
# a non-empty kernel_blocks union regardless of whether the resolved closure
# named it explicitly.
#
# Usage:
#   nodes-to-build-units.sh <package-name> [--graph <path>] [--json]
#
#   <package-name>   the changed package (required) -- same argument
#                    resolve-rebuild-set.sh takes (the client_payload.package
#                    a dozenos/* mirror's sync.yml dispatches, see
#                    ../SYNC.md / ../REBUILD-DISPATCH.md). This IS the
#                    "normalize client_payload.package through the map at
#                    entry" step: <package-name>'s own unit is always part of
#                    the closure (resolve-rebuild-set.sh's closure always
#                    includes the queried package), so no separate
#                    normalization step is needed before resolving.
#   --graph <path>   path to dep-graph.json (default: dep-graph.json next to
#                    this script)
#   --json           (default-on behavior, kept as an explicit, accepted flag
#                     for symmetry with resolve-rebuild-set.sh's own --json)
#                     emit the compact single-line JSON array this script
#                     always emits; the array is ALWAYS this script's only
#                     output shape (see "Output" below) -- there is no
#                     newline-separated alternative, unlike
#                     resolve-rebuild-set.sh, since a build unit is a JSON
#                     OBJECT (recipe + optional kernel_blocks), not a bare
#                     string a line-oriented format could represent cleanly.
#   -h, --help       show this help
#
# Output (stdout): a single-line, SORTED (by recipe name) JSON array of
# build-unit objects, e.g.:
#   [{"recipe":"linux-kernel","kernel_blocks":["accel-ppp-ng","linux-kernel"]},{"recipe":"vpp"}]
# A generic (non-kernel) unit is just {"recipe": "<name>"}. Nothing but the
# result is ever printed to stdout; diagnostics (including every unmapped-node
# warning) go to stderr, so `matrix=$(nodes-to-build-units.sh vpp)` is safe to
# use directly (e.g. as a GitHub Actions `strategy.matrix.unit` via
# `fromJSON(...)`).
#
# Exit codes match resolve-rebuild-set.sh's own convention: 2 for usage
# errors (including a resolve-rebuild-set.sh usage failure), 0 otherwise --
# an empty resolved/mapped set (e.g. resolving a wholly-unmappable node like
# "squid") is NOT an error, it emits `[]` with exit 0 (the caller's own
# "any == true" gate already handles an empty matrix by skipping the build
# job, exactly as resolve-rebuild-set.sh's own header documents for its
# "unknown package" case).
#
# No network, no secrets, idempotent (pure function of <package-name> +
# dep-graph.json's contents, via resolve-rebuild-set.sh).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVE="$SCRIPT_DIR/resolve-rebuild-set.sh"
DEFAULT_GRAPH="$SCRIPT_DIR/dep-graph.json"

die()  { printf 'nodes-to-build-units: %s\n' "$*" >&2; exit 2; }
warn() { printf 'nodes-to-build-units: W: %s\n' "$*" >&2; }
usage() {
  cat >&2 <<'EOF'
Usage: nodes-to-build-units.sh <package-name> [--graph <path>] [--json]

  <package-name>   the changed package to resolve+map to build units
  --graph <path>   path to dep-graph.json (default: dep-graph.json next to
                    this script)
  --json           accepted for symmetry with resolve-rebuild-set.sh (this
                    script's only output shape is already a JSON array)
  -h, --help       show this help
EOF
}

PACKAGE=""
GRAPH="$DEFAULT_GRAPH"

while [ $# -gt 0 ]; do
  case "$1" in
    --graph)   GRAPH="${2:-}"; shift 2 ;;
    --json)    shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage; die "unknown option: $1" ;;
    *)
      if [ -n "$PACKAGE" ]; then
        usage; die "unexpected extra argument: $1 (package already given: $PACKAGE)"
      fi
      PACKAGE="$1"; shift ;;
  esac
done

[ -n "$PACKAGE" ] || { usage; die "missing required <package-name>"; }
[ -f "$GRAPH" ] || die "graph file not found: $GRAPH"
[ -x "$RESOLVE" ] || die "resolve-rebuild-set.sh not found/executable next to this script: $RESOLVE"
command -v jq >/dev/null 2>&1 || die "jq is required (no python3 fallback for this script -- resolve-rebuild-set.sh itself still has one)"

CLOSURE_JSON=$("$RESOLVE" "$PACKAGE" --graph "$GRAPH" --json) \
  || die "resolve-rebuild-set.sh failed for '$PACKAGE' (see its own stderr above)"

# One jq program: for every node in the closure, look it up in
# build_units.node_to_unit; fall back to an identity match against
# recipe_dirs/kernel_blocks for a node with no map entry (new-recipe drift
# tolerance, see header); anything else is UNMAPPED (reported separately on
# stderr, never invented). Kernel-mapped nodes are unioned into ONE
# "linux-kernel" unit (always including "linux-kernel" itself once the union
# is non-empty); every other mapped node dedups by recipe name.
RESULT=$(jq -e -c --argjson closure "$CLOSURE_JSON" '
  (.build_units // {}) as $bu
  | ($bu.node_to_unit // {}) as $map
  | ($bu.recipe_dirs // []) as $recipe_dirs
  | ($bu.kernel_blocks // []) as $kernel_blocks
  | [ $closure[] as $node
      | ( $map[$node]
          // (if ($recipe_dirs | index($node) != null) then {recipe: $node, kernel_block: null}
              elif ($kernel_blocks | index($node) != null) then {recipe: "linux-kernel", kernel_block: $node}
              else null end)
        ) as $unit
      | {node: $node, unit: $unit}
    ] as $resolved
  | ($resolved | map(select(.unit == null) | .node)) as $unmapped
  | ($resolved | map(select(.unit != null))) as $ok
  | ($ok | map(select(.unit.kernel_block == null)) | map(.unit.recipe) | unique) as $generic_recipes
  | ($ok | map(select(.unit.kernel_block != null)) | map(.unit.kernel_block) | unique) as $kernel_blocks_used
  | ( $generic_recipes | map({recipe: .}) ) as $generic_units
  | ( if ($kernel_blocks_used | length) > 0
      then [{recipe: "linux-kernel", kernel_blocks: (($kernel_blocks_used + ["linux-kernel"]) | unique | sort)}]
      else [] end
    ) as $kernel_units
  | { units: (($generic_units + $kernel_units) | sort_by(.recipe)), unmapped: $unmapped }
' "$GRAPH") || die "jq failed to parse $GRAPH / map the resolved closure (malformed dep-graph.json?)"

UNMAPPED=$(printf '%s' "$RESULT" | jq -c '.unmapped')
if [ "$UNMAPPED" != "[]" ]; then
  printf '%s' "$UNMAPPED" | jq -r '.[]' | while IFS= read -r node; do
    warn "node '$node' has no known build unit (no scripts/package-build/ recipe, no linux-kernel block, and not in build_units.node_to_unit) -- dropped from the build-unit matrix, NOT invented; see dep-graph.json's build_units.unmappable for a known/documented case like this"
  done
fi

printf '%s' "$RESULT" | jq -c '.units'
