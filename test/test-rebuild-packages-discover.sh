#!/usr/bin/env bash
#
# Test for the discover step of
# ../overlay-dozenos-build/new-files/.github/workflows/rebuild-packages.yml.
# Extracts the step's run script from the workflow and runs it against a
# fixture git repo for push events.
#
# Network-free. No `set -e`: the runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
WORKFLOW="$TOOLKIT/overlay-dozenos-build/new-files/.github/workflows/rebuild-packages.yml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

SCRIPT="$WORK/discover.sh"
if python3 - "$WORKFLOW" "$SCRIPT" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["discover"]["steps"] if s.get("id") == "set")
open(sys.argv[2], "w").write(step["run"].replace("${{ github.event_name }}", "$GITHUB_EVENT_NAME"))
PY
then
  ok "discover step extracted from rebuild-packages.yml"
else
  bad "could not extract the discover step from $WORKFLOW"
  echo "Results: $pass passed, $fail failed"
  exit 1
fi

REPO="$WORK/repo"
git init -q -b rolling "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
PB="$REPO/scripts/package-build"
for d in ddclient frr linux-kernel vpp shim-signed unionfs-fuse; do
  mkdir -p "$PB/$d"
  echo 1 > "$PB/$d/package.toml"
done
echo 1 > "$PB/build.py"
echo 1 > "$PB/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
BASE=$(git -C "$REPO" rev-parse HEAD)
FULL='["ddclient","frr","linux-kernel"]'

# discover_from <before-sha>: prints "<packages> <any>" for BEFORE..HEAD.
discover_from() {
  local out="$WORK/github_output"
  : > "$out"
  (cd "$REPO" && BEFORE="$1" AFTER=$(git rev-parse HEAD) INPUT_PACKAGE_NAME="" \
    GITHUB_EVENT_NAME=push GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null 2>&1)
  printf '%s %s\n' "$(sed -n 's/^packages=//p' "$out")" "$(sed -n 's/^any=//p' "$out")"
}

# case_change <label> <expected "packages any"> <command run in the repo>
case_change() {
  local label="$1" expected="$2" got
  git -C "$REPO" checkout -q --detach "$BASE"
  (cd "$REPO" && eval "$3") && git -C "$REPO" add -A && git -C "$REPO" commit -q -m change
  got=$(discover_from "$BASE")
  if [ "$got" = "$expected" ]; then
    ok "$label -> $got"
  else
    bad "$label: expected '$expected', got '$got'"
  fi
}

echo "== rebuild-packages.yml discover (push) =="
case_change "one recipe changed" '["frr"] true' \
  'echo 2 > scripts/package-build/frr/package.toml'
case_change "vpp folds into linux-kernel" '["linux-kernel"] true' \
  'echo 2 > scripts/package-build/vpp/package.toml'
case_change "excluded recipes only" '[] false' \
  'echo 2 > scripts/package-build/shim-signed/package.toml; echo 2 > scripts/package-build/unionfs-fuse/package.toml'
case_change "shared build.py changed -> full set" "$FULL true" \
  'echo 2 > scripts/package-build/build.py; echo 2 > scripts/package-build/frr/package.toml'
case_change "top-level non-recipe file only" '[] false' \
  'echo 2 > scripts/package-build/.gitignore'
case_change "deleted recipe dir is not a unit" '["frr"] true' \
  'rm -r scripts/package-build/ddclient; echo 2 > scripts/package-build/frr/package.toml'

git -C "$REPO" checkout -q --detach "$BASE"
got=$(discover_from 0000000000000000000000000000000000000000)
if [ "$got" = "$FULL true" ]; then
  ok "all-zeros BEFORE -> full set"
else
  bad "all-zeros BEFORE: expected '$FULL true', got '$got'"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "${BASH_SOURCE[0]}" && shellcheck -s bash "$SCRIPT"; then
    ok "shellcheck-clean (test + extracted discover script)"
  else
    bad "shellcheck reported issues"
  fi
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
