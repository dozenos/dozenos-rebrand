#!/usr/bin/env bash
#
# Network-free test for release/deb-cache.sh (see ../DEB-CACHE.md).
#
# Fabricates a THROWAWAY dozenos-build-shaped git repo (mktemp only), local
# bare git repos standing in for branch-tracking scm upstreams and for
# dozenos/* mirrors (via the DEB_CACHE_MIRROR_URL_BASE file:// override),
# and a minimal dep-graph.json -- then proves the KEY actually tracks every
# input class it claims to, and stays put for everything else.
#
# Asserts:
#   1.  `key` fails loudly on missing --unit / --build / --rebrand.
#   2.  Happy path: key is 64 lowercase hex chars; --manifest writes JSON
#       whose .key matches stdout and whose .unit is the queried unit.
#   3.  Deterministic: two identical runs print the identical key.
#   4.  Recipe-dir change (new commit touching the unit's dir) => new key.
#   5.  Unrelated-recipe change => key UNCHANGED.
#   6.  data/defaults.toml change => new key (global input).
#   7.  rebrand rename-transform.sh change => new key (global input).
#   8.  Branch-tracking scm entry (commit_id="rolling" at a local bare
#       repo): new commit on that branch => new key; PINNED entries
#       (hex/tag-style commit_id) trigger NO resolution at all (their
#       scm_url points at a nonexistent path -- a lookup attempt would
#       fail the key, so a stable key proves no lookup happened).
#   9.  Dep-graph closure: unitB depends on unitA (reverse_dependencies
#       A->[B]) => a change in A's recipe dir changes key(B); key(A) is
#       UNCHANGED by a change in B's dir (direction matters).
#  10.  Mirror-node closure input: a dep node that exists as a bare repo
#       under DEB_CACHE_MIRROR_URL_BASE with a `rolling` branch => a new
#       commit there changes key(B) -- even though it appears in NO
#       package.toml; non-mirror dep nodes are silently skipped.
#  11.  `store` with an empty --debs dir exits 0 (skip, not an error)
#       without needing gh/network.
#  12.  `probe`/`store` fail loudly on missing required args.
#  13.  Zero embedded vyos residual in deb-cache.sh itself.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/release/deb-cache.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

[ -x "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found or not executable"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
python3 -c 'import tomllib' 2>/dev/null || { echo "SKIP: python3 tomllib unavailable"; exit 0; }

G() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

# ---------------------------------------------------------------------------
# Fixture: bare "upstream" repos (scm branch-tracking + mirror candidates)
# ---------------------------------------------------------------------------
MIRRORS="$WORK/mirrors"
mkdir -p "$MIRRORS"

make_bare() { # <name> -> bare repo with one commit on branch `rolling`
  local src="$WORK/src-$1"
  mkdir -p "$src"
  echo "seed $1" > "$src/f"
  G "$src" init -q -b rolling
  G "$src" add -A
  G "$src" commit -qm seed
  git clone -q --bare "$src" "$MIRRORS/$1"
}
bump_bare() { # <name> -> new commit on its rolling branch
  local src="$WORK/src-$1"
  echo "bump $(date +%s%N)" >> "$src/f"
  G "$src" add -A
  G "$src" commit -qm bump
  G "$src" push -q "$MIRRORS/$1" rolling
}

make_bare scmup        # branch-tracking scm_url target (commit_id=rolling)
make_bare depmirror    # closure dep node that IS a mirror

# ---------------------------------------------------------------------------
# Fixture: dozenos-build-shaped repo with two recipes + globals
# ---------------------------------------------------------------------------
BUILD="$WORK/build"
mkdir -p "$BUILD/scripts/package-build/unita" \
         "$BUILD/scripts/package-build/unitb" \
         "$BUILD/data"
echo 'print("builder")' > "$BUILD/scripts/package-build/build.py"
echo 'build_type = "development"' > "$BUILD/data/defaults.toml"
cat > "$BUILD/scripts/package-build/unita/package.toml" <<EOF
[[packages]]
name = "unita"
commit_id = "rolling"
scm_url = "file://$MIRRORS/scmup"
build_cmd = "true"

[[packages]]
name = "unita-pinned"
commit_id = "v1.2.3"
scm_url = "file://$WORK/DOES-NOT-EXIST"
build_cmd = "true"

[[packages]]
name = "unita-pinned-hash"
commit_id = "0123456789abcdef0123456789abcdef01234567"
scm_url = "file://$WORK/ALSO-DOES-NOT-EXIST"
build_cmd = "true"
EOF
cat > "$BUILD/scripts/package-build/unitb/package.toml" <<'EOF'
[[packages]]
name = "unitb"
commit_id = "20260101"
scm_url = ""
build_cmd = "true"
EOF
G "$BUILD" init -q -b rolling
G "$BUILD" add -A
G "$BUILD" commit -qm seed

bump_build() { # <relpath> -> append + commit
  echo "bump $(date +%s%N)" >> "$BUILD/$1"
  G "$BUILD" add -A
  G "$BUILD" commit -qm "bump $1"
}

# ---------------------------------------------------------------------------
# Fixture: rebrand dir + dep-graph
#   unitb depends on unita (reverse: unita -> [unitb])
#   unitb depends on node "depmirror" (a mirror) and "virtualdep" (not one)
# ---------------------------------------------------------------------------
REBRAND="$WORK/rebrand"
mkdir -p "$REBRAND"
echo '#!/bin/sh' > "$REBRAND/rename-transform.sh"
GRAPH="$WORK/dep-graph.json"
cat > "$GRAPH" <<'EOF'
{
  "reverse_dependencies": {
    "unita": ["unitb"],
    "depmirror": ["unitb"],
    "virtualdep": ["unitb"],
    "unitb": []
  },
  "build_units": {
    "node_to_unit": {
      "unita": {"recipe": "unita", "kernel_block": null},
      "unitb": {"recipe": "unitb", "kernel_block": null},
      "virtualdep": {"recipe": "unitb", "kernel_block": null}
    }
  }
}
EOF

KEYCMD() { # <unit> [extra args...]
  DEB_CACHE_MIRROR_URL_BASE="file://$MIRRORS" \
    "$SCRIPT" key --unit "$1" --build "$BUILD" --rebrand "$REBRAND" \
    --graph "$GRAPH" "${@:2}" 2>"$WORK/key.err"
}

# --- 1. loud failures on missing args --------------------------------------
if "$SCRIPT" key --build "$BUILD" --rebrand "$REBRAND" >/dev/null 2>&1; then
  bad "key without --unit should fail"
else ok "key without --unit fails"; fi
if "$SCRIPT" key --unit unita --rebrand "$REBRAND" >/dev/null 2>&1; then
  bad "key without --build should fail"
else ok "key without --build fails"; fi
if "$SCRIPT" key --unit unita --build "$BUILD" >/dev/null 2>&1; then
  bad "key without --rebrand should fail"
else ok "key without --rebrand fails"; fi

# --- 2. happy path + manifest ----------------------------------------------
K1=$(KEYCMD unita --manifest "$WORK/m.json") || { cat "$WORK/key.err"; K1=""; }
if printf '%s' "$K1" | grep -qE '^[0-9a-f]{64}$'; then
  ok "key is 64 hex chars"
else bad "key is 64 hex chars (got: '$K1')"; fi
MK=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["key"],d["unit"])' "$WORK/m.json" 2>/dev/null)
if [ "$MK" = "$K1 unita" ]; then
  ok "manifest .key/.unit match stdout"
else bad "manifest .key/.unit match stdout (got: '$MK')"; fi

# --- 3. deterministic --------------------------------------------------------
K2=$(KEYCMD unita)
if [ -n "$K1" ] && [ "$K1" = "$K2" ]; then
  ok "identical inputs => identical key"
else bad "identical inputs => identical key ($K1 vs $K2)"; fi

# --- 4./5. recipe-dir change tracks; unrelated change does not --------------
KB0=$(KEYCMD unitb)
bump_build scripts/package-build/unita/extra-file
K3=$(KEYCMD unita)
if [ -n "$K3" ] && [ "$K3" != "$K1" ]; then
  ok "unit recipe-dir change => new key"
else bad "unit recipe-dir change => new key"; fi
bump_build scripts/package-build/unitb/extra-file
K4=$(KEYCMD unita)
if [ "$K4" = "$K3" ]; then
  ok "unrelated recipe change => key unchanged"
else bad "unrelated recipe change => key unchanged"; fi

# --- 6./7. global inputs ------------------------------------------------------
bump_build data/defaults.toml
K5=$(KEYCMD unita)
if [ -n "$K5" ] && [ "$K5" != "$K4" ]; then
  ok "defaults.toml change => new key"
else bad "defaults.toml change => new key"; fi
echo '# changed' >> "$REBRAND/rename-transform.sh"
K6=$(KEYCMD unita)
if [ -n "$K6" ] && [ "$K6" != "$K5" ]; then
  ok "rename-transform.sh change => new key"
else bad "rename-transform.sh change => new key"; fi

# --- 8. branch-tracking scm resolves; pinned entries never touch network ----
bump_bare scmup
K7=$(KEYCMD unita)
if [ -n "$K7" ] && [ "$K7" != "$K6" ]; then
  ok "branch-tracking scm upstream commit => new key"
else bad "branch-tracking scm upstream commit => new key"; fi
# The two pinned entries point at nonexistent file:// paths: every KEYCMD
# above already proves no lookup was attempted (it would have failed the
# key), but assert once explicitly for the record.
if [ -n "$K7" ]; then
  ok "pinned commit_id entries are never resolved (nonexistent scm_url tolerated)"
else bad "pinned commit_id entries are never resolved"; fi

# --- 9. dep closure direction -------------------------------------------------
KB1=$(KEYCMD unitb)
if [ -n "$KB1" ] && [ "$KB1" != "$KB0" ]; then
  ok "dep (unita) change => dependent unitb key changed"
else bad "dep (unita) change => dependent unitb key changed"; fi
KA=$(KEYCMD unita)
bump_build scripts/package-build/unitb/another-file
KA2=$(KEYCMD unita)
KB2=$(KEYCMD unitb)
if [ "$KA" = "$KA2" ]; then
  ok "dependent (unitb) change leaves dep unita key unchanged"
else bad "dependent (unitb) change leaves dep unita key unchanged"; fi
if [ -n "$KB2" ] && [ "$KB2" != "$KB1" ]; then
  ok "unitb own change => unitb key changed"
else bad "unitb own change => unitb key changed"; fi

# --- 10. mirror dep node -------------------------------------------------------
bump_bare depmirror
KB3=$(KEYCMD unitb)
if [ -n "$KB3" ] && [ "$KB3" != "$KB2" ]; then
  ok "mirror dep node commit => dependent key changed (no package.toml entry needed)"
else bad "mirror dep node commit => dependent key changed"; fi
KA3=$(KEYCMD unita)
if [ "$KA3" = "$KA2" ]; then
  ok "mirror dep node commit leaves non-dependent unita unchanged"
else bad "mirror dep node commit leaves non-dependent unita unchanged"; fi
# virtualdep (no bare repo behind it) must be silently skipped -- proven by
# every successful unitb key above; assert for the record.
if [ -n "$KB3" ]; then
  ok "non-mirror dep node silently skipped"
else bad "non-mirror dep node silently skipped"; fi

# --- 11. store: empty debs dir => graceful skip -------------------------------
mkdir -p "$WORK/empty-debs"
if "$SCRIPT" store --unit unita --key "$K7" --debs "$WORK/empty-debs" >/dev/null 2>&1; then
  ok "store with zero .debs exits 0 (skip, not error)"
else bad "store with zero .debs exits 0"; fi

# --- 12. probe/store arg validation -------------------------------------------
if "$SCRIPT" probe --unit unita --key "$K7" >/dev/null 2>&1; then
  bad "probe without --dest should fail"
else ok "probe without --dest fails"; fi
if "$SCRIPT" store --unit unita --debs "$WORK/empty-debs" >/dev/null 2>&1; then
  bad "store without --key should fail"
else ok "store without --key fails"; fi

# --- 13. zero vyos residual ----------------------------------------------------
if grep -qi vyos "$SCRIPT"; then
  bad "deb-cache.sh contains a vyos token"
else ok "deb-cache.sh has zero vyos residual"; fi

echo
echo "test-deb-cache: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
