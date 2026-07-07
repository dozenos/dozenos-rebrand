#!/usr/bin/env bash
#
# Integration test for ../dep-graph/resolve-rebuild-set.sh (item #15, the
# INCREMENTAL rebuild fan-out resolver). See ../REBUILD-DISPATCH.md and
# ../dep-graph/dep-graph.json's own header for the full design -- this test
# only asserts the resolver's TRANSITIVE-CLOSURE behavior against the real,
# shipped bootstrap graph, plus a couple of synthetic fixture graphs for
# edge cases (cycle-safety, unknown-graph-file) that the real graph cannot
# exercise on its own.
#
# Self-contained and NETWORK-FREE: exercises the real
# ../dep-graph/dep-graph.json plus small ad-hoc fixture graphs written to a
# scratch directory; never touches github.com.
#
# Asserts:
#   1. vpp            -> {accel-ppp-ng, vpp}
#   2. linux-kernel    -> kernel + every known OOT dependent (block names,
#                         NOT .deb names -- see dep-graph.json's naming
#                         note), including mlnx and the vpp-shared
#                         accel-ppp-ng
#   3. vyconf          -> {dozenos-1x, libdozenosconfig0, vyconf} (2-hop
#                         transitive closure)
#   4. dozenos1x-config -> same libdozenosconfig0 -> dozenos-1x chain
#   5. strongswan      -> {python3-vici, strongswan}
#   6. isc-kea-common  -> all 4 isc-kea-dhcp*/hooks dependents + itself
#   7. libyang3        -> {frr, libyang3}
#   8. libtac2 / libtacplus-map1 -> {libnss-tacplus, libpam-tacplus, <self>}
#   9. Known leaf (python3-vici, a value but never a key): output is just
#      itself, NO warning on stderr.
#  10. Unknown package (never mentioned anywhere in the graph): output is
#      just itself, WITH a warning on stderr; exit 0 (soft, documented
#      behavior -- see resolve-rebuild-set.sh's own header).
#  11. --json emits a valid, sorted JSON array matching the newline output.
#  12. Output is always sorted + deduplicated (checked against every case
#      above via `sort -c`).
#  13. Missing <package-name> argument -> usage + exit 2.
#  14. Nonexistent --graph path -> exit 2, no traceback.
#  15. Cycle-safety: a synthetic fixture graph with a genuine a<->b cycle
#      terminates and returns exactly {a, b}, not an infinite loop / hang.
#  16. shellcheck-clean.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/dep-graph/resolve-rebuild-set.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# assert_closure <label> <package> <expected-newline-sorted-set>
assert_closure() {
  local label="$1" pkg="$2" expected="$3" got rc
  got=$("$SCRIPT" "$pkg" 2>/tmp/resolve-rebuild-set.stderr.$$)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: exited $rc (expected 0)"
    return
  fi
  if [ "$got" = "$expected" ]; then
    ok "$label: closure matches"
  else
    bad "$label: closure mismatch -- got:
$got
expected:
$expected"
  fi
  # Every case's output must already be sorted (resolver's own contract).
  # LC_ALL=C matches jq's/python's own byte-order sort semantics -- a
  # locale-aware `sort -c` can disagree on ordering involving '-' vs digits
  # (e.g. "isc-kea-dhcp-ddns" vs "isc-kea-dhcp4") even when the resolver's
  # output is correctly byte-sorted.
  if printf '%s\n' "$got" | LC_ALL=C sort -c 2>/dev/null; then
    ok "$label: output is sorted"
  else
    bad "$label: output is NOT sorted: $got"
  fi
  rm -f /tmp/resolve-rebuild-set.stderr.$$
}

echo "== [1] vpp -> vpp + accel-ppp-ng =="
assert_closure "vpp" "vpp" "$(printf 'accel-ppp-ng\nvpp')"

echo "== [2] linux-kernel -> kernel + all known OOT dependents (item #16: + igb, qat) =="
assert_closure "linux-kernel" "linux-kernel" "$(printf 'accel-ppp-ng\ni40e\niavf\nice\nigb\nipt-netflow\nixgbe\nixgbevf\njool\nlinux-kernel\nmlnx\nnat-rtsp\nqat\nrealtek-r8126\nrealtek-r8152')"

echo "== [3] vyconf -> 2-hop dozenos-1x chain =="
assert_closure "vyconf" "vyconf" "$(printf 'dozenos-1x\nlibdozenosconfig0\nvyconf')"

echo "== [4] dozenos1x-config -> same chain, different leaf =="
assert_closure "dozenos1x-config" "dozenos1x-config" "$(printf 'dozenos-1x\ndozenos1x-config\nlibdozenosconfig0')"

echo "== [5] strongswan -> python3-vici =="
assert_closure "strongswan" "strongswan" "$(printf 'python3-vici\nstrongswan')"

echo "== [6] isc-kea-common -> dhcp4/dhcp6/ddns/hooks =="
assert_closure "isc-kea-common" "isc-kea-common" "$(printf 'isc-kea-common\nisc-kea-dhcp-ddns\nisc-kea-dhcp4\nisc-kea-dhcp6\nisc-kea-hooks')"

echo "== [7] libyang3 -> frr =="
assert_closure "libyang3" "libyang3" "$(printf 'frr\nlibyang3')"

echo "== [8a] libtac2 -> libnss-tacplus + libpam-tacplus =="
assert_closure "libtac2" "libtac2" "$(printf 'libnss-tacplus\nlibpam-tacplus\nlibtac2')"

echo "== [8b] libtacplus-map1 -> libnss-tacplus + libpam-tacplus =="
assert_closure "libtacplus-map1" "libtacplus-map1" "$(printf 'libnss-tacplus\nlibpam-tacplus\nlibtacplus-map1')"

echo "== [8c] item #16 new edge: dozenos-vpp-patches -> vpp -> accel-ppp-ng (2-hop) =="
assert_closure "dozenos-vpp-patches" "dozenos-vpp-patches" "$(printf 'accel-ppp-ng\ndozenos-vpp-patches\nvpp')"

echo "== [8d] item #16 new edge: wpa -> hostap =="
assert_closure "wpa" "wpa" "$(printf 'hostap\nwpa')"

echo "== [8e] item #16 new edge: pkg-libnftnl -> pkg-nftables =="
assert_closure "pkg-libnftnl" "pkg-libnftnl" "$(printf 'pkg-libnftnl\npkg-nftables')"

echo "== [8f] item #16 new edge (block-name form): libyang -> frr =="
assert_closure "libyang" "libyang" "$(printf 'frr\nlibyang')"

echo "== [8g] item #16 new edge (block-name form): libtacplus-map -> libpam-tacplus + libnss-tacplus =="
assert_closure "libtacplus-map" "libtacplus-map" "$(printf 'libnss-tacplus\nlibpam-tacplus\nlibtacplus-map')"

echo "== [8h] item #16 new edge (block-name form): libpam-tacplus -> libnss-tacplus =="
assert_closure "libpam-tacplus" "libpam-tacplus" "$(printf 'libnss-tacplus\nlibpam-tacplus')"

echo "== [8i] item #16: linux-kernel dependents now include igb and qat =="
if "$SCRIPT" linux-kernel | grep -qx igb && "$SCRIPT" linux-kernel | grep -qx qat; then
  ok "linux-kernel closure includes igb and qat"
else
  bad "linux-kernel closure missing igb and/or qat: $("$SCRIPT" linux-kernel)"
fi

echo "== [9] known leaf: python3-vici (a value, never a key) =="
STDERR_FILE="$WORK/leaf.stderr"
GOT=$("$SCRIPT" python3-vici 2>"$STDERR_FILE")
RC=$?
if [ "$RC" -eq 0 ] && [ "$GOT" = "python3-vici" ]; then
  ok "known leaf: emits itself only, exit 0"
else
  bad "known leaf: got rc=$RC output='$GOT'"
fi
if [ -s "$STDERR_FILE" ]; then
  bad "known leaf: unexpected warning on stderr: $(cat "$STDERR_FILE")"
else
  ok "known leaf: no warning on stderr (not a coverage gap)"
fi

echo "== [10] unknown package: never mentioned anywhere in the graph =="
STDERR_FILE="$WORK/unknown.stderr"
GOT=$("$SCRIPT" fixture-totally-unknown-pkg-xyz 2>"$STDERR_FILE")
RC=$?
if [ "$RC" -eq 0 ] && [ "$GOT" = "fixture-totally-unknown-pkg-xyz" ]; then
  ok "unknown package: emits itself only, exit 0 (soft/documented)"
else
  bad "unknown package: got rc=$RC output='$GOT'"
fi
if grep -q "not found anywhere" "$STDERR_FILE"; then
  ok "unknown package: warns on stderr"
else
  bad "unknown package: expected a 'not found anywhere' warning on stderr, got: $(cat "$STDERR_FILE")"
fi

echo "== [11] --json emits a valid, sorted array =="
JSON_GOT=$("$SCRIPT" vpp --json)
if printf '%s' "$JSON_GOT" | jq -e '. == (. | sort)' >/dev/null 2>&1; then
  ok "--json: valid JSON array, already sorted"
else
  bad "--json: not a sorted JSON array: $JSON_GOT"
fi
EXPECTED_JSON='["accel-ppp-ng","vpp"]'
if [ "$JSON_GOT" = "$EXPECTED_JSON" ]; then
  ok "--json: matches expected vpp closure"
else
  bad "--json: got '$JSON_GOT', expected '$EXPECTED_JSON'"
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

echo "== [15] cycle-safety (synthetic fixture graph) =="
CYCLE_GRAPH="$WORK/cycle-graph.json"
cat > "$CYCLE_GRAPH" <<'EOF'
{
  "reverse_dependencies": {
    "a": ["b"],
    "b": ["a"]
  }
}
EOF
CYCLE_GOT=$(timeout 10 "$SCRIPT" a --graph "$CYCLE_GRAPH")
CYCLE_RC=$?
if [ "$CYCLE_RC" -eq 0 ] && [ "$CYCLE_GOT" = "$(printf 'a\nb')" ]; then
  ok "cycle-safety: a<->b cycle resolves to {a, b}, no hang"
else
  bad "cycle-safety: got rc=$CYCLE_RC output='$CYCLE_GOT' (expected 'a\\nb', exit 0)"
fi

echo "== [17] item #16: dep-graph.json itself is valid (no self-loop/cycle/coverage gap) =="
VALIDATE="$TOOLKIT/dep-graph/validate-dep-graph.sh"
if OUT17=$("$VALIDATE" 2>&1); then
  ok "validate-dep-graph.sh: clean on the real shipped graph ($OUT17)"
else
  bad "validate-dep-graph.sh: unexpected finding(s) on the real shipped graph: $OUT17"
fi

echo "== [18] item #16: validate-dep-graph.sh actually detects a broken graph =="
SELFLOOP_GRAPH="$WORK/selfloop-graph.json"
printf '{"reverse_dependencies": {"a": ["a"]}}' > "$SELFLOOP_GRAPH"
if "$VALIDATE" --graph "$SELFLOOP_GRAPH" >/dev/null 2>&1; then
  bad "validate-dep-graph.sh: did not catch a self-loop fixture"
else
  ok "validate-dep-graph.sh: catches a self-loop fixture (exit non-zero)"
fi

CYCLE2_GRAPH="$WORK/cycle2-graph.json"
printf '{"reverse_dependencies": {"a": ["b"], "b": ["a"]}}' > "$CYCLE2_GRAPH"
if "$VALIDATE" --graph "$CYCLE2_GRAPH" >/dev/null 2>&1; then
  bad "validate-dep-graph.sh: did not catch an a<->b cycle fixture"
else
  ok "validate-dep-graph.sh: catches an a<->b cycle fixture (exit non-zero)"
fi

echo "== [19] item #16: full coverage against the real local vyos-build recipe tree =="
# Reuses the same local-checkout convention test-mirror-push.sh already
# establishes (VYOS_BUILD_LOCAL, guarded on .git existing) -- skip gracefully
# if this machine does not have it, rather than requiring network/a fresh
# clone inside the test suite. The local tree is PRE-rename-transform (raw
# upstream directory names, e.g. "vyos-1x"/"vyos-http-api-tools"), so a
# symlink farm renames just those two to match dep-graph.json's post-transform
# convention before handing the tree to validate-dep-graph.sh --tree. This is
# a SUBSET check (every recipe present locally must be covered) rather than
# an exact-set check, so it tolerates the local checkout being slightly behind
# upstream (e.g. a brand-new recipe added after this checkout was last synced)
# without ever tolerating a real regression on anything it DOES contain.
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
  if OUT19=$("$VALIDATE" --tree "$TREE_FARM" 2>&1); then
    ok "validate-dep-graph.sh --tree: full coverage against local vyos-build ($OUT19)"
  else
    bad "validate-dep-graph.sh --tree: coverage gap(s) against local vyos-build: $OUT19"
  fi
else
  echo "  SKIP: $VYOS_BUILD_LOCAL/scripts/package-build not present on this machine"
fi

echo "== [20] item #16: +git auto-stamp un-stamp fix (rename-transform.sh --stamp) =="
REBRAND_SCRIPT="$TOOLKIT/rename-transform.sh"
STAMP_PINNED="$WORK/stamp-pinned/debian"
STAMP_OTHER="$WORK/stamp-other/debian"
mkdir -p "$STAMP_PINNED" "$STAMP_OTHER"
cat > "$STAMP_PINNED/changelog" <<'EOF'
bash-completion (1:2.8-6) unstable; urgency=medium

  * Initial release.

 -- Test <test@dozenos.local>  Mon, 01 Jan 2024 00:00:00 +0000
EOF
cat > "$STAMP_OTHER/changelog" <<'EOF'
ddclient (3.11.2-1) unstable; urgency=medium

  * Initial release.

 -- Test <test@dozenos.local>  Mon, 01 Jan 2024 00:00:00 +0000
EOF
"$REBRAND_SCRIPT" "$WORK/stamp-pinned" --stamp 20260707.deadbee >/dev/null 2>&1
if head -1 "$STAMP_PINNED/changelog" | grep -qF '(1:2.8-6)' && ! head -1 "$STAMP_PINNED/changelog" | grep -q '+git'; then
  ok "exact-pinned recipe (bash-completion): --stamp is a no-op (version unchanged)"
else
  bad "exact-pinned recipe (bash-completion): expected version unchanged, got: $(head -1 "$STAMP_PINNED/changelog")"
fi

"$REBRAND_SCRIPT" "$WORK/stamp-other" --stamp 20260707.deadbee >/dev/null 2>&1
if head -1 "$STAMP_OTHER/changelog" | grep -q '+git20260707.deadbee'; then
  ok "non-pinned recipe (ddclient): --stamp still applies normally"
else
  bad "non-pinned recipe (ddclient): expected +git stamp applied, got: $(head -1 "$STAMP_OTHER/changelog")"
fi

echo "== [21] shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT" >/tmp/resolve-rebuild-set.shellcheck.$$ 2>&1; then
    ok "shellcheck: clean"
  else
    bad "shellcheck: findings -- $(cat /tmp/resolve-rebuild-set.shellcheck.$$)"
  fi
  rm -f /tmp/resolve-rebuild-set.shellcheck.$$

  if shellcheck "$VALIDATE" >/tmp/validate-dep-graph.shellcheck.$$ 2>&1; then
    ok "shellcheck (validate-dep-graph.sh): clean"
  else
    bad "shellcheck (validate-dep-graph.sh): findings -- $(cat /tmp/validate-dep-graph.shellcheck.$$)"
  fi
  rm -f /tmp/validate-dep-graph.shellcheck.$$
else
  echo "  SKIP: shellcheck not installed"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
