#!/usr/bin/env bash
#
# validate-dep-graph.sh -- item #16 graph-integrity check for dep-graph.json.
#
# Distinct from resolve-rebuild-set.sh (which answers "what must rebuild for
# package X", assuming the graph is well-formed): this script asserts the
# graph ITSELF is well-formed, independent of any one query. Checks:
#
#   1. dep-graph.json is valid JSON with a "reverse_dependencies" object.
#   2. No self-loop: no key lists ITSELF directly inside its own dependents
#      array (a key legitimately CAN be reachable from itself only through
#      the resolver's own "closure always includes the queried package"
#      identity -- that is not a self-loop, it is the resolver's contract;
#      a self-loop here means the raw JSON edge list names a package as its
#      own direct dependent, which would always be either a data-entry typo
#      or a real modeling mistake).
#   3. The graph is a DAG: no cycle exists among any two-or-more distinct
#      keys (resolve-rebuild-set.sh already tolerates a cycle at query time
#      -- bounded BFS -- but a real cycle in the SHIPPED graph would still be
#      a modeling bug worth failing CI over, since "A must rebuild because B
#      changed, and B must rebuild because A changed" is never a real
#      build-order fact).
#   4. Every dependents-array entry is a non-empty string (no null/number/
#      nested-array garbage a hand-edit could introduce).
#   5. OPTIONAL, only with --tree <path-to-scripts/package-build>: full
#      coverage -- every real C2 package/block identifier the tree can
#      build (every non-linux-kernel recipe DIRECTORY name, plus every
#      linux-kernel/package.toml `[[packages]]` block `name`) appears
#      somewhere in the graph (as a key or a dependents-array value). This
#      is the same enumeration item #16's own audit used; kept here as a
#      standing, re-runnable check for the NEXT upstream sync, not just a
#      one-time count in dep-graph.json's own "_notes.coverage" prose.
#   6. (item #30) Every node appearing anywhere in "reverse_dependencies"
#      (a key or a dependents-array value) has a corresponding entry in the
#      new top-level "build_units.node_to_unit" map, OR is explicitly
#      listed in "build_units.unmappable" -- no node may be silently
#      unmapped. This is what makes rebuild-dispatch.yml's
#      `cd scripts/package-build/<unit>` safe: every resolvable node now
#      has a proven buildable unit, or is a documented, known exception.
#   7. (item #30) Every "build_units.node_to_unit" entry has the correct
#      shape: {"recipe": <non-empty string>, "kernel_block": <string or
#      null>}.
#   8. (item #30) OPTIONAL, only with --tree: every "recipe" value used
#      anywhere in "build_units.node_to_unit" is a REAL directory under the
#      given tree, and every non-null "kernel_block" value is a REAL
#      linux-kernel/package.toml `[[packages]]` block name -- catches a
#      build-unit map entry that has silently drifted from the actual
#      buildable tree (e.g. a recipe renamed/removed upstream).
#
# Usage:
#   validate-dep-graph.sh [--graph <path>] [--tree <scripts/package-build>]
#
#   --graph <path>   path to dep-graph.json (default: dep-graph.json next to
#                     this script)
#   --tree <path>    path to a scripts/package-build directory to check full
#                     coverage against (optional -- without it, only the
#                     internal structural checks 1-4 run; this lets the check
#                     run in contexts with no vyos-build/dozenos-build clone
#                     on disk, e.g. a bare toolkit checkout)
#   -h, --help       show this help
#
# Exit 0 and prints "OK" + a one-line summary on success. Exit 1 with every
# finding listed on stderr on failure. Never touches the network, never
# writes anything -- pure read-only validation.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_GRAPH="$SCRIPT_DIR/dep-graph.json"

die()  { printf 'validate-dep-graph: %s\n' "$*" >&2; exit 2; }
usage() {
  cat >&2 <<'EOF'
Usage: validate-dep-graph.sh [--graph <path>] [--tree <scripts/package-build>]

  --graph <path>   path to dep-graph.json (default: dep-graph.json next to
                    this script)
  --tree <path>    path to a scripts/package-build directory; when given,
                    also asserts full coverage (every real recipe directory
                    name, plus every linux-kernel package.toml block name,
                    appears in the graph)
  -h, --help       show this help
EOF
}

GRAPH="$DEFAULT_GRAPH"
TREE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --graph) GRAPH="${2:-}"; shift 2 ;;
    --tree)  TREE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

[ -f "$GRAPH" ] || die "graph file not found: $GRAPH"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 \
  || die "neither jq nor python3 is available"

if [ -n "$TREE" ]; then
  [ -d "$TREE" ] || die "--tree directory not found: $TREE"
fi

python3 - "$GRAPH" "$TREE" <<'PYEOF'
import json, sys, glob, os, re

graph_path, tree = sys.argv[1], sys.argv[2]

with open(graph_path) as f:
    data = json.load(f)

if "reverse_dependencies" not in data or not isinstance(data["reverse_dependencies"], dict):
    print("FAIL: top-level 'reverse_dependencies' object missing or not an object", file=sys.stderr)
    sys.exit(1)

rd = data["reverse_dependencies"]
findings = []

# --- check 4: every dependents-array entry is a non-empty string ----------
for key, deps in rd.items():
    if not isinstance(deps, list):
        findings.append(f"key '{key}': dependents value is not a JSON array")
        continue
    for i, dep in enumerate(deps):
        if not isinstance(dep, str) or dep == "":
            findings.append(f"key '{key}': dependents[{i}] is not a non-empty string: {dep!r}")

# --- check 2: no direct self-loop ------------------------------------------
for key, deps in rd.items():
    if isinstance(deps, list) and key in deps:
        findings.append(f"key '{key}': self-loop -- '{key}' lists itself as its own direct dependent")

# --- check 3: DAG -- no cycle among 2+ distinct keys -----------------------
# Standard white/gray/black DFS cycle detection over the reverse_dependencies
# edges (key -> each dependent). A "dependent" that is not itself a key is a
# leaf with no outgoing edges (fine, cannot participate in a cycle).
WHITE, GRAY, BLACK = 0, 1, 2
color = {k: WHITE for k in rd}
cycle_path = []

def visit(node, stack):
    if color.get(node, WHITE) == BLACK:
        return None
    if color.get(node, WHITE) == GRAY:
        # Found a cycle: return the cycle slice of the stack.
        idx = stack.index(node)
        return stack[idx:] + [node]
    color[node] = GRAY
    stack.append(node)
    for nxt in rd.get(node, []):
        result = visit(nxt, stack)
        if result is not None:
            return result
    stack.pop()
    color[node] = BLACK
    return None

for k in list(rd.keys()):
    if color[k] == WHITE:
        result = visit(k, [])
        if result is not None:
            findings.append(f"cycle detected: {' -> '.join(result)}")
            break  # one report is enough; fix and re-run to find more

# All node identifiers appearing anywhere in reverse_dependencies (key or
# dependents-array value) -- used by check 5 (tree coverage) below AND by
# check 6 (build-unit coverage), so computed once, unconditionally.
known = set(rd.keys())
for deps in rd.values():
    if isinstance(deps, list):
        known.update(d for d in deps if isinstance(d, str))

# --- check 5 (optional): full coverage against a real package-build tree --
if tree:
    recipe_dirs_on_disk = sorted(
        os.path.basename(os.path.dirname(p))
        for p in glob.glob(os.path.join(tree, "*", "package.toml"))
    )
    if not recipe_dirs_on_disk:
        findings.append(f"--tree given ({tree}) but no */package.toml found under it -- wrong path?")
    else:
        expected = set()
        disk_kernel_blocks = set()
        for recipe in recipe_dirs_on_disk:
            toml_path = os.path.join(tree, recipe, "package.toml")
            with open(toml_path) as f:
                text = f.read()
            names = re.findall(r'^\s*name\s*=\s*"([^"]+)"', text, re.M)
            if recipe == "linux-kernel":
                # Bespoke recipe: build.py supports --packages <block-name>
                # filtering, so every block is its own coverage unit.
                expected.update(names)
                disk_kernel_blocks.update(names)
            else:
                # Generic build.py has no --packages filter: the coverage
                # unit is the whole recipe directory, matching what
                # `cd scripts/package-build/<pkg> && python3 ../build.py`
                # actually dispatches.
                expected.add(recipe)

        missing = sorted(expected - known)
        for m in missing:
            findings.append(f"coverage gap: '{m}' (from {tree}) does not appear anywhere in {graph_path}")

# --- checks 6/7 (item #30): build_units integrity -------------------------
bu = data.get("build_units", {})
node_to_unit = bu.get("node_to_unit", {})
unmappable = bu.get("unmappable", {})
recipe_dirs_declared = bu.get("recipe_dirs", [])
kernel_blocks_declared = bu.get("kernel_blocks", [])

if "build_units" not in data:
    findings.append("top-level 'build_units' section missing -- see dep-graph/nodes-to-build-units.sh / DEP-GRAPH.md item #30")
else:
    # check 7: shape of every node_to_unit entry.
    for node, unit in node_to_unit.items():
        if not isinstance(unit, dict):
            findings.append(f"build_units.node_to_unit['{node}']: not a JSON object")
            continue
        recipe = unit.get("recipe")
        if not isinstance(recipe, str) or recipe == "":
            findings.append(f"build_units.node_to_unit['{node}'].recipe: not a non-empty string: {recipe!r}")
        kb = unit.get("kernel_block", "MISSING")
        if kb is not None and not isinstance(kb, str):
            findings.append(f"build_units.node_to_unit['{node}'].kernel_block: must be null or a string, got {kb!r}")
        if kb == "MISSING":
            findings.append(f"build_units.node_to_unit['{node}']: missing required 'kernel_block' key (use null for a non-kernel unit)")

    # check 6: every known graph node has a build unit or is flagged unmappable.
    unmapped_and_undocumented = sorted(known - set(node_to_unit.keys()) - set(unmappable.keys()))
    for n in unmapped_and_undocumented:
        findings.append(f"build-unit coverage gap: node '{n}' (appears in reverse_dependencies) has no entry in build_units.node_to_unit and is not listed in build_units.unmappable")

    # check 8 (optional, --tree): every recipe/kernel_block actually used is real.
    if tree and recipe_dirs_on_disk:  # noqa: F821 -- only defined inside `if tree:` above, guarded by the same condition
        disk_recipes = set(recipe_dirs_on_disk)
        for node, unit in node_to_unit.items():
            if not isinstance(unit, dict):
                continue
            recipe = unit.get("recipe")
            if isinstance(recipe, str) and recipe not in disk_recipes:
                findings.append(f"build_units.node_to_unit['{node}'].recipe = '{recipe}' is not a real directory under {tree}")
            kb = unit.get("kernel_block")
            if kb is not None and kb not in disk_kernel_blocks:
                findings.append(f"build_units.node_to_unit['{node}'].kernel_block = '{kb}' is not a real linux-kernel package.toml block under {tree}")
        for r in recipe_dirs_declared:
            if r not in disk_recipes:
                findings.append(f"build_units.recipe_dirs contains '{r}', not a real directory under {tree}")
        for b in kernel_blocks_declared:
            if b not in disk_kernel_blocks:
                findings.append(f"build_units.kernel_blocks contains '{b}', not a real linux-kernel package.toml block under {tree}")

if findings:
    print(f"FAIL: {len(findings)} finding(s):", file=sys.stderr)
    for f_ in findings:
        print(f"  - {f_}", file=sys.stderr)
    sys.exit(1)

n_keys = len(rd)
n_known = len(known)
n_units = len(node_to_unit)
n_unmappable = len(unmappable)
coverage_msg = ""
if tree:
    coverage_msg = f", full coverage verified against {tree}"
print(f"OK: {n_keys} key(s), {n_known} known identifier(s) total, no self-loops, no cycles, all dependents well-formed{coverage_msg}, {n_units} build-unit(s) mapped + {n_unmappable} flagged unmappable (build-unit coverage complete)")
PYEOF
