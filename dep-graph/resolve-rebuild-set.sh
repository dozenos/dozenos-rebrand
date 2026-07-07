#!/usr/bin/env bash
#
# resolve-rebuild-set.sh -- item #15 fan-out resolver.
#
# Given ONE changed package name (the client_payload.package a dozenos/*
# mirror's sync.yml dispatches, see ../SYNC.md and ../REBUILD-DISPATCH.md),
# emits the full TRANSITIVE-CLOSURE rebuild set: the package itself plus
# every package that (directly or indirectly) depends on it at build time,
# per ../dep-graph/dep-graph.json's "reverse_dependencies" map. This is the
# routing step that makes the item #15 receiver workflow INCREMENTAL --
# only ever this resolved set rebuilds, never scripts/package-build/* in
# full.
#
# *** BOOTSTRAP GRAPH *** -- dep-graph.json documents itself as a bootstrap;
# this script's job is purely mechanical closure over whatever the graph
# currently contains. Coverage completeness across every C2 recipe is item
# #16's job, not this script's.
#
# Usage:
#   resolve-rebuild-set.sh <package-name> [--graph <path>] [--json]
#
#   <package-name>   the changed package (required)
#   --graph <path>   path to dep-graph.json (default: dep-graph.json next to
#                     this script)
#   --json           emit a JSON array (e.g. '["a","b"]') instead of the
#                     default newline-separated list -- pass this when
#                     feeding a GitHub Actions `strategy.matrix` via
#                     fromJSON(...)
#   -h, --help       show this help
#
# Output (stdout): the rebuild set, SORTED and DEDUPLICATED, one of:
#   - default: one package name per line
#   - --json:  a single-line JSON array, e.g. ["accel-ppp-ng","vpp"]
# Nothing but the result is ever printed to stdout; diagnostics go to
# stderr, so `packages=$(resolve-rebuild-set.sh vpp --json)` is safe to use
# directly.
#
# Unknown-package behavior (decided, see README.md/REBUILD-DISPATCH.md for
# the write-up): a package name that appears NOWHERE in dep-graph.json
# (neither as a key nor inside any dependents list) is NOT a hard failure --
# the bootstrap graph is known-incomplete by design (item #16 completes
# it), so "not yet in the graph" is the expected common case, not a bug.
# This script prints a warning to stderr and still emits a valid one-package
# rebuild set (the package alone) with exit 0. A package that names an
# existing key/value but simply has no further dependents (a real, KNOWN
# leaf) is treated identically in output (itself alone) but WITHOUT the
# warning, since that is not a coverage gap, just a leaf of the graph.
#
# Cycle-safety: traversal tracks visited nodes and never re-expands one, so
# a (currently not expected, but not assumed impossible) cycle in a future,
# larger #16 graph cannot infinite-loop this script.
#
# No network, no secrets, idempotent (pure function of <package-name> +
# dep-graph.json's contents).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_GRAPH="$SCRIPT_DIR/dep-graph.json"

die()  { printf 'resolve-rebuild-set: %s\n' "$*" >&2; exit 2; }
warn() { printf 'resolve-rebuild-set: W: %s\n' "$*" >&2; }
usage() {
  cat >&2 <<'EOF'
Usage: resolve-rebuild-set.sh <package-name> [--graph <path>] [--json]

  <package-name>   the changed package to resolve the rebuild set for
  --graph <path>   path to dep-graph.json (default: dep-graph.json next to
                    this script)
  --json           emit a JSON array instead of newline-separated output
  -h, --help       show this help
EOF
}

PACKAGE=""
GRAPH="$DEFAULT_GRAPH"
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --graph)   GRAPH="${2:-}"; shift 2 ;;
    --json)    JSON_OUT=1; shift ;;
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

# ------------------------------------------------------------------------- #
# jq path (preferred).
# ------------------------------------------------------------------------- #
resolve_with_jq() {
  # BFS transitive closure entirely inside one jq program: seed the visited
  # set with the input package, repeatedly union in each visited node's
  # direct dependents until a fixed point (`limit`-bounded purely as a
  # cycle/pathology backstop, not expected to ever be hit on an acyclic
  # graph), then emit the sorted+deduped closure. `--arg` keeps the package
  # name out of jq program-injection entirely.
  jq -e --arg pkg "$PACKAGE" '
    .reverse_dependencies as $rd
    | ($rd | to_entries | map(.value[]) + (($rd | keys))) as $known
    | ($known | index($pkg) != null) as $is_known
    | (
        # Fixed-point BFS: start from {pkg}, repeatedly add direct
        # dependents of every node seen so far. 64 rounds is far more than
        # this graph could ever need transitively (a real cycle would
        # otherwise stop shrinking and just stabilize early instead of
        # looping forever, since this is bounded iteration, not recursion).
        reduce range(0; 64) as $i (
          [$pkg];
          . as $frontier
          | ($frontier + [$frontier[] as $n | ($rd[$n] // [])[]])
            | unique
        )
      ) as $closure
    | {closure: ($closure | sort), is_known: $is_known}
  ' "$GRAPH"
}

# ------------------------------------------------------------------------- #
# Portable fallback (no jq): minimal ad-hoc JSON walk via python3. Only used
# when jq is unavailable -- same semantics as the jq path above.
# ------------------------------------------------------------------------- #
resolve_with_python() {
  python3 - "$GRAPH" "$PACKAGE" <<'PYEOF'
import json, sys

graph_path, pkg = sys.argv[1], sys.argv[2]
with open(graph_path) as f:
    data = json.load(f)
rd = data.get("reverse_dependencies", {})

known = set(rd.keys())
for deps in rd.values():
    known.update(deps)
is_known = pkg in known

closure = {pkg}
frontier = {pkg}
while frontier:
    nxt = set()
    for node in frontier:
        for dep in rd.get(node, []):
            if dep not in closure:
                nxt.add(dep)
    closure |= nxt
    frontier = nxt

print(json.dumps({"closure": sorted(closure), "is_known": is_known}))
PYEOF
}

# Decide once which JSON engine is available and reuse it consistently for
# both producing RESULT and reading it back -- avoids probing jq/python3
# availability more than once and avoids ever mixing engines mid-script.
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
elif command -v python3 >/dev/null 2>&1; then
  HAVE_JQ=0
else
  die "neither jq nor python3 is available -- cannot parse $GRAPH"
fi

if [ "$HAVE_JQ" -eq 1 ]; then
  RESULT=$(resolve_with_jq) || die "jq failed to parse $GRAPH (malformed dep-graph.json?)"
  IS_KNOWN=$(printf '%s' "$RESULT" | jq -r '.is_known')
else
  RESULT=$(resolve_with_python) || die "python3 fallback failed to parse $GRAPH (malformed dep-graph.json?)"
  IS_KNOWN=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["is_known"])')
fi

if [ "$IS_KNOWN" != "true" ]; then
  warn "package '$PACKAGE' not found anywhere in $GRAPH (bootstrap coverage gap, or genuinely has no known dependents) -- emitting it alone; see dep-graph.json's 'coverage' note and REBUILD-DISPATCH.md"
fi

if [ "$JSON_OUT" -eq 1 ]; then
  if [ "$HAVE_JQ" -eq 1 ]; then
    printf '%s' "$RESULT" | jq -c '.closure'
  else
    printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["closure"]))'
  fi
else
  if [ "$HAVE_JQ" -eq 1 ]; then
    printf '%s' "$RESULT" | jq -r '.closure[]'
  else
    printf '%s' "$RESULT" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["closure"]))'
  fi
fi
