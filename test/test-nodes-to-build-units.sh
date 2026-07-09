#!/usr/bin/env bash
#
# Integration test for ../dep-graph/nodes-to-build-units.sh (item #30, the
# NORMALIZED build-unit resolver) and the new build_units integrity checks
# ../dep-graph/validate-dep-graph.sh gained alongside it. See this
# toolkit's DEP-GRAPH.md / REBUILD-DISPATCH.md for the full design; this
# test only asserts:
#
#   - node -> build-unit mapping for the tricky, non-obvious cases (a deb
#     name produced by a differently-named recipe, a linux-kernel
#     `--packages` block name, a same-recipe multi-block alias)
#   - DEDUP: multiple resolved nodes mapping to the same recipe collapse to
#     ONE build unit; multiple resolved linux-kernel blocks collapse to ONE
#     linux-kernel unit whose kernel_blocks is their union (+ "linux-kernel"
#     itself, always)
#   - the one FLAGGED-unmappable node (squid) and a wholly unknown node both
#     degrade gracefully (empty unit, warning on stderr, exit 0 -- never a
#     crash, never an invented directory)
#   - a node with no explicit build_units.node_to_unit entry but a NAME that
#     matches a real recipe_dirs/kernel_blocks entry falls back to that
#     identity mapping (new-recipe-added-upstream drift tolerance)
#   - validate-dep-graph.sh's new build-unit coverage/shape checks actually
#     catch a broken graph (not just always passing)
#   - rebuild-dispatch.yml: valid YAML, actionlint-clean, lands in the
#     reproduced mode-B tree byte-identical, zero vyos, zero uses:vyos
#
# Self-contained and NETWORK-FREE (the "lands in tree" check clones from the
# LOCAL vyos-build sibling checkout via `mirror-push.sh <local-path> ...`,
# never github.com): everything else is small ad-hoc fixture graphs plus the
# real, shipped dep-graph.json.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/dep-graph/nodes-to-build-units.sh"
VALIDATE="$TOOLKIT/dep-graph/validate-dep-graph.sh"
GRAPH="$TOOLKIT/dep-graph/dep-graph.json"
MIRROR_PUSH="$TOOLKIT/mirror-push.sh"
WORKFLOW="$TOOLKIT/overlay/new-files/.github/workflows/rebuild-dispatch.yml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# assert_units <label> <package> <expected-json-array>
assert_units() {
  local label="$1" pkg="$2" expected="$3" got rc
  got=$("$SCRIPT" "$pkg" 2>/tmp/nodes-to-build-units.stderr.$$)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: exited $rc (expected 0) -- stderr: $(cat /tmp/nodes-to-build-units.stderr.$$)"
    rm -f /tmp/nodes-to-build-units.stderr.$$
    return
  fi
  # Compare as JSON values (jq -e '. == ...'), not byte strings, so key
  # ordering inside each unit object never causes a false mismatch.
  if jq -e --argjson got "$got" --argjson expected "$expected" -n '$got == $expected' >/dev/null 2>&1; then
    ok "$label: build-unit matrix matches"
  else
    bad "$label: mismatch -- got: $got
expected: $expected"
  fi
  rm -f /tmp/nodes-to-build-units.stderr.$$
}

echo "== [1] python3-vici -> strongswan (deb produced by a DIFFERENTLY named recipe) =="
assert_units "python3-vici" "python3-vici" '[{"recipe":"strongswan"}]'

echo "== [2] strongswan itself -> strongswan (self-consistent) =="
assert_units "strongswan" "strongswan" '[{"recipe":"strongswan"}]'

echo "== [3] libtac2 (deb name) -> tacacs =="
assert_units "libtac2" "libtac2" '[{"recipe":"tacacs"}]'

echo "== [4] libtacplus-map1 (deb name) -> tacacs =="
assert_units "libtacplus-map1" "libtacplus-map1" '[{"recipe":"tacacs"}]'

echo "== [5] isc-kea-common (deb name) -> isc-kea =="
assert_units "isc-kea-common" "isc-kea-common" '[{"recipe":"isc-kea"}]'

echo "== [6] libyang3 (deb name) -> frr =="
assert_units "libyang3" "libyang3" '[{"recipe":"frr"}]'

echo "== [7] vyconf (opam-pinned OCaml lib, no recipe dir of its own) -> dozenos-1x =="
assert_units "vyconf" "vyconf" '[{"recipe":"dozenos-1x"}]'

echo "== [8] dozenos1x-config -> dozenos-1x (same opam-pin chain) =="
assert_units "dozenos1x-config" "dozenos1x-config" '[{"recipe":"dozenos-1x"}]'

echo "== [9] libdozenosconfig0 -> dozenos-1x (same chain, different leaf) =="
assert_units "libdozenosconfig0" "libdozenosconfig0" '[{"recipe":"dozenos-1x"}]'

echo "== [10] i40e (linux-kernel --packages block, no directory of its own) =="
assert_units "i40e" "i40e" '[{"recipe":"linux-kernel","kernel_blocks":["i40e","linux-kernel"]}]'

echo "== [11] accel-ppp-ng resolved alone -> linux-kernel unit (NOT scripts/package-build/accel-ppp-ng) =="
assert_units "accel-ppp-ng (via strongswan? no -- via vpp)" "accel-ppp-ng" '[{"recipe":"linux-kernel","kernel_blocks":["accel-ppp-ng","linux-kernel"]}]'

echo "== [12] DEDUP: libpam-tacplus -> {libpam-tacplus, libnss-tacplus}, both -> tacacs, ONE unit =="
assert_units "libpam-tacplus dedup" "libpam-tacplus" '[{"recipe":"tacacs"}]'

echo "== [13] DEDUP: isc-kea-common closure has 5 isc-kea-* deb nodes, ONE isc-kea unit =="
CLOSURE=$("$TOOLKIT/dep-graph/resolve-rebuild-set.sh" isc-kea-common --json)
N_NODES=$(printf '%s' "$CLOSURE" | jq 'length')
if [ "$N_NODES" -eq 5 ]; then
  ok "isc-kea-common: closure really has 5 raw nodes (dedup test is meaningful)"
else
  bad "isc-kea-common: expected 5 raw nodes in closure, got $N_NODES: $CLOSURE"
fi
assert_units "isc-kea-common dedup (5 nodes -> 1 unit)" "isc-kea-common" '[{"recipe":"isc-kea"}]'

echo "== [14] DEDUP: dozenos-vpp-patches -> vpp unit + linux-kernel(accel-ppp-ng) unit, exactly 2 =="
assert_units "dozenos-vpp-patches" "dozenos-vpp-patches" '[{"recipe":"linux-kernel","kernel_blocks":["accel-ppp-ng","linux-kernel"]},{"recipe":"vpp"}]'

echo "== [15] DEDUP: linux-kernel itself -> ONE unit, kernel_blocks = full known family + itself =="
GOT15=$("$SCRIPT" linux-kernel 2>/dev/null)
N_UNITS15=$(printf '%s' "$GOT15" | jq 'length')
N_BLOCKS15=$(printf '%s' "$GOT15" | jq '.[0].kernel_blocks | length')
if [ "$N_UNITS15" -eq 1 ]; then
  ok "linux-kernel: exactly 1 build unit (all blocks collapsed)"
else
  bad "linux-kernel: expected exactly 1 build unit, got $N_UNITS15: $GOT15"
fi
if printf '%s' "$GOT15" | jq -e '.[0].kernel_blocks | index("linux-kernel") != null' >/dev/null 2>&1; then
  ok "linux-kernel: kernel_blocks includes 'linux-kernel' itself"
else
  bad "linux-kernel: kernel_blocks missing 'linux-kernel' itself: $GOT15"
fi
if [ "$N_BLOCKS15" -ge 14 ]; then
  ok "linux-kernel: kernel_blocks union is the full known family ($N_BLOCKS15 blocks)"
else
  bad "linux-kernel: expected >= 14 kernel_blocks, got $N_BLOCKS15: $GOT15"
fi

echo "== [16] squid: FLAGGED unmappable -- empty matrix, warning on stderr, exit 0 =="
STDERR16="$WORK/squid.stderr"
GOT16=$("$SCRIPT" squid 2>"$STDERR16")
RC16=$?
if [ "$RC16" -eq 0 ] && [ "$GOT16" = "[]" ]; then
  ok "squid: empty matrix, exit 0"
else
  bad "squid: got rc=$RC16 output='$GOT16' (expected '[]', exit 0)"
fi
if grep -q "no known build unit" "$STDERR16"; then
  ok "squid: warns on stderr"
else
  bad "squid: expected a 'no known build unit' warning, got: $(cat "$STDERR16")"
fi

echo "== [17] wholly unknown node: same graceful degrade as squid =="
STDERR17="$WORK/unknown.stderr"
GOT17=$("$SCRIPT" fixture-totally-unknown-pkg-xyz 2>"$STDERR17")
RC17=$?
if [ "$RC17" -eq 0 ] && [ "$GOT17" = "[]" ]; then
  ok "unknown node: empty matrix, exit 0"
else
  bad "unknown node: got rc=$RC17 output='$GOT17'"
fi
if grep -q "no known build unit" "$STDERR17"; then
  ok "unknown node: warns on stderr"
else
  bad "unknown node: expected a 'no known build unit' warning, got: $(cat "$STDERR17")"
fi

echo "== [18] fallback identity mapping: a node not in node_to_unit but matching a real recipe_dirs entry =="
FIXTURE_IDENTITY="$WORK/fixture-identity.json"
cat > "$FIXTURE_IDENTITY" <<'EOF'
{
  "reverse_dependencies": {"newpkg": []},
  "build_units": {
    "recipe_dirs": ["newpkg"],
    "kernel_blocks": [],
    "node_to_unit": {},
    "unmappable": {}
  }
}
EOF
GOT18=$("$SCRIPT" newpkg --graph "$FIXTURE_IDENTITY" 2>/dev/null)
if [ "$GOT18" = '[{"recipe":"newpkg"}]' ]; then
  ok "fallback identity mapping: unmapped node whose name matches a real recipe dir resolves by identity"
else
  bad "fallback identity mapping: got '$GOT18', expected '[{\"recipe\":\"newpkg\"}]'"
fi

echo "== [19] fallback identity mapping: a node matching a real kernel_blocks entry =="
FIXTURE_IDENTITY2="$WORK/fixture-identity2.json"
cat > "$FIXTURE_IDENTITY2" <<'EOF'
{
  "reverse_dependencies": {"newblock": []},
  "build_units": {
    "recipe_dirs": [],
    "kernel_blocks": ["newblock"],
    "node_to_unit": {},
    "unmappable": {}
  }
}
EOF
GOT19=$("$SCRIPT" newblock --graph "$FIXTURE_IDENTITY2" 2>/dev/null)
if [ "$GOT19" = '[{"recipe":"linux-kernel","kernel_blocks":["linux-kernel","newblock"]}]' ]; then
  ok "fallback identity mapping: unmapped node whose name matches a real kernel block resolves by identity"
else
  bad "fallback identity mapping: got '$GOT19', expected linux-kernel unit with newblock+linux-kernel"
fi

echo "== bad usage =="
"$SCRIPT" >/dev/null 2>&1
if [ $? -eq 2 ]; then
  ok "missing package name: exits 2"
else
  bad "missing package name: expected exit 2"
fi

"$SCRIPT" vpp --graph "$WORK/does-not-exist.json" >/dev/null 2>&1
if [ $? -eq 2 ]; then
  ok "nonexistent --graph path: exits 2"
else
  bad "nonexistent --graph path: expected exit 2"
fi

echo "== [20] validate-dep-graph.sh: clean on the real shipped graph (build-unit coverage complete) =="
if OUT20=$("$VALIDATE" 2>&1); then
  if printf '%s' "$OUT20" | grep -q "build-unit(s) mapped"; then
    ok "validate-dep-graph.sh: clean, reports build-unit coverage ($OUT20)"
  else
    bad "validate-dep-graph.sh: clean but missing build-unit coverage summary: $OUT20"
  fi
else
  bad "validate-dep-graph.sh: unexpected finding(s) on the real shipped graph: $OUT20"
fi

echo "== [21] validate-dep-graph.sh: catches a build-unit coverage gap (node with no unit, not flagged) =="
FIXTURE_GAP="$WORK/fixture-gap.json"
cat > "$FIXTURE_GAP" <<'EOF'
{
  "reverse_dependencies": {"a": ["b"], "b": []},
  "build_units": {
    "recipe_dirs": ["a"],
    "kernel_blocks": [],
    "node_to_unit": {"a": {"recipe": "a", "kernel_block": null}},
    "unmappable": {}
  }
}
EOF
if "$VALIDATE" --graph "$FIXTURE_GAP" >/dev/null 2>&1; then
  bad "validate-dep-graph.sh: did not catch a build-unit coverage gap ('b' unmapped and undocumented)"
else
  ok "validate-dep-graph.sh: catches a build-unit coverage gap (exit non-zero)"
fi

echo "== [22] validate-dep-graph.sh: catches a malformed node_to_unit entry (missing kernel_block key) =="
FIXTURE_SHAPE="$WORK/fixture-shape.json"
cat > "$FIXTURE_SHAPE" <<'EOF'
{
  "reverse_dependencies": {"a": []},
  "build_units": {
    "recipe_dirs": ["a"],
    "kernel_blocks": [],
    "node_to_unit": {"a": {"recipe": "a"}},
    "unmappable": {}
  }
}
EOF
if "$VALIDATE" --graph "$FIXTURE_SHAPE" >/dev/null 2>&1; then
  bad "validate-dep-graph.sh: did not catch a malformed node_to_unit entry"
else
  ok "validate-dep-graph.sh: catches a malformed node_to_unit entry (exit non-zero)"
fi

echo "== [23] validate-dep-graph.sh --tree: catches a node_to_unit.recipe that is not a real directory =="
FIXTURE_TREE_DIR="$WORK/fixture-tree"
mkdir -p "$FIXTURE_TREE_DIR/real-recipe"
cat > "$FIXTURE_TREE_DIR/real-recipe/package.toml" <<'EOF'
[[packages]]
name = "real-recipe"
EOF
FIXTURE_FAKE_RECIPE="$WORK/fixture-fake-recipe.json"
cat > "$FIXTURE_FAKE_RECIPE" <<'EOF'
{
  "reverse_dependencies": {"a": []},
  "build_units": {
    "recipe_dirs": ["real-recipe"],
    "kernel_blocks": [],
    "node_to_unit": {"a": {"recipe": "not-a-real-dir", "kernel_block": null}},
    "unmappable": {}
  }
}
EOF
if "$VALIDATE" --graph "$FIXTURE_FAKE_RECIPE" --tree "$FIXTURE_TREE_DIR" >/dev/null 2>&1; then
  bad "validate-dep-graph.sh --tree: did not catch a node_to_unit.recipe pointing at a non-real directory"
else
  ok "validate-dep-graph.sh --tree: catches a node_to_unit.recipe pointing at a non-real directory (exit non-zero)"
fi

echo "== [24] validate-dep-graph.sh --tree: real reproduced mode-B tree, full build-unit coverage =="
VYOS_BUILD_LOCAL="/home/date/git/dozenos/vyos-build"
if [ -d "$VYOS_BUILD_LOCAL/scripts/package-build" ]; then
  TREE_FARM="$WORK/tree-farm"
  mkdir -p "$TREE_FARM"
  for d in "$VYOS_BUILD_LOCAL"/scripts/package-build/*/; do
    base=$(basename "$d")
    case "$base" in
      vyos-1x) renamed="dozenos-1x" ;;
      vyos-http-api-tools) renamed="dozenos-http-api-tools" ;;
      *) renamed="$base" ;;
    esac
    ln -s "$d" "$TREE_FARM/$renamed"
  done
  # The REAL dozenos-build tree is upstream + overlay/new-files (mirror-push
  # --build-repo applies the overlay) -- recipe dirs that exist ONLY as
  # overlay new-files (live-boot, added 2026-07-08; see dep-graph.json's
  # coverage note) are as real to the dep-graph as upstream ones, so the
  # fixture must include them too, not just the vyos-build sibling checkout.
  for d in "$TOOLKIT"/overlay/new-files/scripts/package-build/*/; do
    base=$(basename "$d")
    [ -e "$TREE_FARM/$base" ] || ln -s "$d" "$TREE_FARM/$base"
  done
  if OUT24=$("$VALIDATE" --tree "$TREE_FARM" 2>&1); then
    ok "validate-dep-graph.sh --tree: full build-unit coverage against local vyos-build ($OUT24)"
  else
    bad "validate-dep-graph.sh --tree: gap(s) against local vyos-build: $OUT24"
  fi
else
  echo "  SKIP: $VYOS_BUILD_LOCAL/scripts/package-build not present on this machine"
fi

echo "== [25] rebuild-dispatch.yml: valid YAML =="
if python3 -c "import yaml; yaml.safe_load(open('$WORKFLOW'))" 2>/tmp/rebuild-dispatch.yamlerr.$$; then
  ok "rebuild-dispatch.yml: valid YAML"
else
  bad "rebuild-dispatch.yml: invalid YAML -- $(cat /tmp/rebuild-dispatch.yamlerr.$$)"
fi
rm -f /tmp/rebuild-dispatch.yamlerr.$$

echo "== [26] rebuild-dispatch.yml: actionlint =="
# -ignore x2: actionlint's VENDORED popular-actions input schema (still
# app-id-only as of v1.7.12) lags actions/create-github-app-token@v3, whose
# real action.yml (checked at the v3 TAG, 2026-07-09) defines `client-id`
# and deprecates `app-id` ("Use 'client-id' instead" -- the runtime warning
# that prompted the rename). Both ignores match ONLY that stale-schema false
# positive; drop them once a future actionlint release refreshes its DB.
if command -v actionlint >/dev/null 2>&1; then
  if actionlint \
      -ignore 'input "client-id" is not defined in action' \
      -ignore 'missing input "app-id" which is required' \
      "$WORKFLOW" >/tmp/rebuild-dispatch.actionlint.$$ 2>&1; then
    ok "rebuild-dispatch.yml: actionlint clean"
  else
    bad "rebuild-dispatch.yml: actionlint findings -- $(cat /tmp/rebuild-dispatch.actionlint.$$)"
  fi
  rm -f /tmp/rebuild-dispatch.actionlint.$$
else
  echo "  SKIP: actionlint not installed"
fi

echo "== [27] rebuild-dispatch.yml: zero vyos / zero uses:vyos =="
VYOS_COUNT=$(grep -ci vyos "$WORKFLOW")
USES_VYOS_COUNT=$(grep -c 'uses:.*vyos' "$WORKFLOW" || true)
if [ "$VYOS_COUNT" -eq 0 ]; then
  ok "rebuild-dispatch.yml: zero vyos"
else
  bad "rebuild-dispatch.yml: $VYOS_COUNT vyos hit(s) found"
fi
if [ "${USES_VYOS_COUNT:-0}" -eq 0 ]; then
  ok "rebuild-dispatch.yml: zero uses:vyos"
else
  bad "rebuild-dispatch.yml: $USES_VYOS_COUNT uses:vyos hit(s) found"
fi

echo "== [28] rebuild-dispatch.yml: lands in the reproduced mode-B tree, byte-identical, no new residual vyos =="
if [ -d "/home/date/git/dozenos/vyos-build/.git" ]; then
  LAND_WORK="$WORK/land"
  OUT28=$("$MIRROR_PUSH" /home/date/git/dozenos/vyos-build --target dozenos-build --branch rolling \
    --build-repo --dry-run --work "$LAND_WORK" 2>&1)
  RC28=$?
  LANDED="$LAND_WORK/clone/.github/workflows/rebuild-dispatch.yml"
  if [ "$RC28" -eq 0 ] && [ -f "$LANDED" ] && diff -q "$LANDED" "$WORKFLOW" >/dev/null 2>&1; then
    ok "rebuild-dispatch.yml: lands byte-identical in the reproduced mode-B tree"
  else
    bad "rebuild-dispatch.yml: lands-in-tree check failed (rc=$RC28); mirror-push output: $OUT28"
  fi
  RESIDUAL_COUNT=$(printf '%s' "$OUT28" | grep -c "FAIL (9 residual vyos)" || true)
  if printf '%s' "$OUT28" | grep -q "9 residual vyos"; then
    ok "rebuild-dispatch.yml: same 9 pre-existing residual vyos hits, no new residual introduced"
  else
    bad "rebuild-dispatch.yml: residual vyos count changed from the documented 9 -- investigate: $OUT28"
  fi
else
  echo "  SKIP: /home/date/git/dozenos/vyos-build is not a git checkout here -- skipping the lands-in-tree test"
fi

echo "== [29] shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT" >/tmp/nodes-to-build-units.shellcheck.$$ 2>&1; then
    ok "shellcheck (nodes-to-build-units.sh): clean"
  else
    bad "shellcheck (nodes-to-build-units.sh): findings -- $(cat /tmp/nodes-to-build-units.shellcheck.$$)"
  fi
  rm -f /tmp/nodes-to-build-units.shellcheck.$$

  if shellcheck "$VALIDATE" >/tmp/validate-dep-graph.shellcheck.$$ 2>&1; then
    ok "shellcheck (validate-dep-graph.sh): clean"
  else
    bad "shellcheck (validate-dep-graph.sh): findings -- $(cat /tmp/validate-dep-graph.shellcheck.$$)"
  fi
  rm -f /tmp/validate-dep-graph.shellcheck.$$
else
  echo "  SKIP: shellcheck not installed"
fi

echo "== [30] dep-graph.json is still valid JSON after the build_units addition =="
if jq empty "$GRAPH" >/dev/null 2>&1; then
  ok "dep-graph.json: valid JSON"
else
  bad "dep-graph.json: invalid JSON"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
