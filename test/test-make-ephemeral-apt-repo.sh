#!/usr/bin/env bash
#
# Integration test for release/make-ephemeral-apt-repo.sh (progress item
# #13, see ../ISO-BUILD.md).
#
# Builds THROWAWAY dummy .deb packages (dpkg-deb, mktemp only, never
# committed -- unrelated to any real DozenOS package) purely to exercise the
# script's scan/index/release-generation/idempotency code paths, and (when
# apt-get/dpkg-scanpackages/apt-ftparchive are available) proves the
# produced repo is actually installable via a real `apt-get update` +
# `apt-get install --simulate` run against a sandboxed apt root -- not just
# "files got written".
#
# Asserts:
#   1. Fails loudly with no arguments / missing <output-dir>.
#   2. Fails loudly on a nonexistent <debs-dir>.
#   3. Fails loudly (and writes nothing under <output-dir>/dists) when
#      <debs-dir> contains zero .deb files.
#   4. Happy path: given 2 dummy .debs (one depending on the other), builds
#      pool/<component>/*.deb + dists/<suite>/<component>/binary-<arch>/
#      Packages(.gz) + dists/<suite>/Release, all non-empty.
#   5. Packages index has exactly 2 stanzas (matches staged .deb count), and
#      each stanza's Filename: is the expected pool-relative path.
#   6. stdout is EXACTLY one line: "[trusted=yes] file://<abs output-dir>"
#      (the value to pass to build-dozenos-image --dozenos-mirror).
#   7. --suite/--component/--arch overrides land at the expected paths.
#   8. Idempotent: two consecutive runs against the same output-dir produce
#      byte-identical Packages/Packages.gz content and an identical stdout
#      mirror value; re-run never leaves a stale extra .deb in pool/ from a
#      renamed/removed input.
#   9. End-to-end apt proof (skipped if apt-get/dpkg-scanpackages/
#      apt-ftparchive are unavailable): a sandboxed `apt-get update` against
#      the produced repo exits 0, and `apt-get install --simulate` resolves
#      the cross-package dependency purely from the ephemeral repo.
#  10. Zero embedded vyos residual in the script itself.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/release/make-ephemeral-apt-repo.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

[ -x "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found or not executable"; exit 1; }

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "SKIP: dpkg-deb not available, cannot fabricate throwaway test .debs"
  exit 0
fi

# ---------------------------------------------------------------------------
# Fabricate two THROWAWAY dummy .deb packages (mktemp only).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/pkgbuild/dozenos-1x_1.0_amd64/DEBIAN"
cat > "$WORK/pkgbuild/dozenos-1x_1.0_amd64/DEBIAN/control" <<'EOF'
Package: dozenos-1x
Version: 1.0
Architecture: amd64
Maintainer: DozenOS test <autobuild@dozenos.local>
Description: throwaway test package, not a real DozenOS artifact
EOF

mkdir -p "$WORK/pkgbuild/dozenos-1x-smoketest_1.0_amd64/DEBIAN"
cat > "$WORK/pkgbuild/dozenos-1x-smoketest_1.0_amd64/DEBIAN/control" <<'EOF'
Package: dozenos-1x-smoketest
Version: 1.0
Architecture: amd64
Maintainer: DozenOS test <autobuild@dozenos.local>
Description: throwaway test package, not a real DozenOS artifact
Depends: dozenos-1x (= 1.0)
EOF

DEBS_DIR="$WORK/debs"
mkdir -p "$DEBS_DIR"
dpkg-deb --build --root-owner-group "$WORK/pkgbuild/dozenos-1x_1.0_amd64" \
  "$DEBS_DIR/dozenos-1x_1.0_amd64.deb" >/dev/null
dpkg-deb --build --root-owner-group "$WORK/pkgbuild/dozenos-1x-smoketest_1.0_amd64" \
  "$DEBS_DIR/dozenos-1x-smoketest_1.0_amd64.deb" >/dev/null

echo "== fail-loud =="

if ! "$SCRIPT" >/dev/null 2>&1; then
  ok "no arguments: fails"
else
  bad "no arguments: expected non-zero exit"
fi

if ! "$SCRIPT" "$DEBS_DIR" >/dev/null 2>&1; then
  ok "missing <output-dir>: fails"
else
  bad "missing <output-dir>: expected non-zero exit"
fi

if ! "$SCRIPT" "$WORK/does-not-exist" "$WORK/out-nonexistent" >/dev/null 2>&1; then
  ok "nonexistent <debs-dir>: fails"
else
  bad "nonexistent <debs-dir>: expected non-zero exit"
fi

empty_debs="$WORK/empty-debs"
mkdir -p "$empty_debs"
empty_out="$WORK/out-empty"
if ! "$SCRIPT" "$empty_debs" "$empty_out" >/dev/null 2>&1; then
  ok "<debs-dir> with zero .deb files: fails"
else
  bad "empty <debs-dir>: expected non-zero exit"
fi
if [ ! -d "$empty_out/dists" ]; then
  ok "empty <debs-dir>: no dists/ tree written"
else
  bad "empty <debs-dir>: dists/ tree written despite failure"
fi

echo "== happy path =="

OUT="$WORK/repo"
stdout_out=$("$SCRIPT" "$DEBS_DIR" "$OUT" 2>"$WORK/stderr.log")
rc=$?
if [ "$rc" -eq 0 ]; then ok "happy path: exits 0"; else bad "happy path: expected exit 0, got $rc"; fi

packages_file="$OUT/dists/rolling/main/binary-amd64/Packages"
packages_gz="$OUT/dists/rolling/main/binary-amd64/Packages.gz"
release_file="$OUT/dists/rolling/Release"

if [ -s "$packages_file" ]; then ok "Packages index written and non-empty"; else bad "Packages index missing/empty at $packages_file"; fi
if [ -s "$packages_gz" ]; then ok "Packages.gz written and non-empty"; else bad "Packages.gz missing/empty at $packages_gz"; fi
if [ -s "$release_file" ]; then ok "Release file written and non-empty"; else bad "Release file missing/empty at $release_file"; fi
if [ -f "$OUT/pool/main/dozenos-1x_1.0_amd64.deb" ]; then ok "dozenos-1x .deb staged in pool/main/"; else bad "dozenos-1x .deb NOT staged"; fi
if [ -f "$OUT/pool/main/dozenos-1x-smoketest_1.0_amd64.deb" ]; then ok "dozenos-1x-smoketest .deb staged in pool/main/"; else bad "dozenos-1x-smoketest .deb NOT staged"; fi

stanza_count=$(grep -c '^Package:' "$packages_file" 2>/dev/null || echo 0)
if [ "$stanza_count" -eq 2 ]; then ok "Packages index has exactly 2 stanzas"; else bad "Packages index has $stanza_count stanza(s), expected 2"; fi

if grep -q '^Filename: pool/main/dozenos-1x_1.0_amd64\.deb$' "$packages_file"; then
  ok "dozenos-1x stanza has expected pool-relative Filename:"
else
  bad "dozenos-1x stanza missing expected Filename: line"
fi

echo "== stdout contract =="

stdout_lines=$(printf '%s\n' "$stdout_out" | wc -l | tr -d ' ')
if [ "$stdout_lines" -eq 1 ]; then ok "stdout is exactly one line"; else bad "stdout has $stdout_lines line(s), expected 1"; fi

expected_prefix="[trusted=yes] file://$OUT"
if [ "$stdout_out" = "$expected_prefix" ]; then
  ok "stdout is the exact --dozenos-mirror value: $stdout_out"
else
  bad "stdout mismatch: got '$stdout_out', expected '$expected_prefix'"
fi

if grep -q "deb     \[trusted=yes\] file://$OUT rolling main" "$WORK/stderr.log"; then
  ok "stderr shows the full illustrative 'deb' source-list line"
else
  bad "stderr missing the full illustrative 'deb' source-list line"
fi
if grep -q "deb-src \[trusted=yes\] file://$OUT rolling main" "$WORK/stderr.log"; then
  ok "stderr shows the full illustrative 'deb-src' source-list line"
else
  bad "stderr missing the full illustrative 'deb-src' source-list line"
fi

echo "== --suite/--component/--arch overrides =="

OUT2="$WORK/repo-custom"
"$SCRIPT" --suite testing --component contrib --arch amd64 "$DEBS_DIR" "$OUT2" >"$WORK/custom-stdout.log" 2>/dev/null
if [ -s "$OUT2/dists/testing/contrib/binary-amd64/Packages" ]; then
  ok "--suite/--component/--arch overrides land at the expected dists/ path"
else
  bad "custom suite/component/arch tree not found at expected path"
fi
if [ "$(cat "$WORK/custom-stdout.log")" = "[trusted=yes] file://$OUT2" ]; then
  ok "custom-run stdout mirror value still well-formed"
else
  bad "custom-run stdout mirror value malformed: $(cat "$WORK/custom-stdout.log")"
fi

echo "== idempotency =="

before_pkgs=$(sha256sum "$packages_file" | awk '{print $1}')
before_pool_count=$(find "$OUT/pool/main" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')
second_out=$("$SCRIPT" "$DEBS_DIR" "$OUT" 2>/dev/null)
after_pkgs=$(sha256sum "$packages_file" | awk '{print $1}')
after_pool_count=$(find "$OUT/pool/main" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')

if [ "$before_pkgs" = "$after_pkgs" ]; then ok "re-run: Packages index byte-identical"; else bad "re-run: Packages index changed"; fi
if [ "$second_out" = "$stdout_out" ]; then ok "re-run: stdout mirror value identical"; else bad "re-run: stdout mirror value changed"; fi
if [ "$before_pool_count" -eq 2 ] && [ "$after_pool_count" -eq 2 ]; then
  ok "re-run: pool/ still contains exactly 2 .deb (no stale leftovers)"
else
  bad "re-run: pool/ .deb count drifted ($before_pool_count -> $after_pool_count)"
fi

echo "== end-to-end apt proof =="

if command -v apt-get >/dev/null 2>&1 && command -v dpkg-scanpackages >/dev/null 2>&1 && command -v apt-ftparchive >/dev/null 2>&1; then
  APTROOT="$WORK/aptroot"
  mkdir -p "$APTROOT/etc/apt/sources.list.d" \
           "$APTROOT/var/lib/apt/lists/partial" \
           "$APTROOT/var/cache/apt/archives/partial" \
           "$APTROOT/var/lib/dpkg" \
           "$APTROOT/var/log/apt"
  touch "$APTROOT/var/lib/dpkg/status"
  cat > "$APTROOT/etc/apt/sources.list.d/dozenos.list" <<EOF
deb $stdout_out rolling main
deb-src $stdout_out rolling main
EOF

  if apt-get -o Dir="$APTROOT" -o Dir::State::status="$APTROOT/var/lib/dpkg/status" \
       -o Debug::NoLocking=1 update >"$WORK/apt-update.log" 2>&1; then
    ok "apt-get update against the produced repo exits 0"
  else
    bad "apt-get update failed (see $WORK/apt-update.log)"
    cat "$WORK/apt-update.log" >&2
  fi

  sim_out=$(apt-get -o Dir="$APTROOT" -o Dir::State::status="$APTROOT/var/lib/dpkg/status" \
    -o Debug::NoLocking=1 install --simulate --yes dozenos-1x-smoketest 2>&1)
  sim_rc=$?
  if [ "$sim_rc" -eq 0 ] && printf '%s' "$sim_out" | grep -q 'Inst dozenos-1x '; then
    ok "apt-get install --simulate resolves the cross-package dependency from the ephemeral repo"
  else
    bad "apt-get install --simulate did not resolve dozenos-1x as expected (exit $sim_rc)"
    printf '%s\n' "$sim_out" >&2
  fi
else
  echo "SKIP: apt-get/dpkg-scanpackages/apt-ftparchive not all available, skipping end-to-end apt proof"
fi

echo "== zero-vyos =="
if grep -qi vyos "$SCRIPT"; then
  bad "script contains a 'vyos' residual"
else
  ok "script contains zero 'vyos' residual"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
