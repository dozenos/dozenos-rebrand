#!/usr/bin/env bash
#
# Integration test for mirror-push.sh.
#
# Self-contained and NETWORK-FREE: builds a tiny local "upstream" git repo
# (fixture, containing a vyos string, a .github/workflows/ dir, and a vyatta
# string) and drives mirror-push.sh against it via a file:// URL. `gh` is
# stubbed out (a fake executable prepended to PATH) so the seed/sync mode
# detect can be deterministically controlled WITHOUT ever touching
# github.com -- this test never hits GitHub.
#
# Asserts:
#   1. rename-transform applied (0 residual vyos in the pushed tree).
#   2. .github/ stripped entirely.
#   3. vyatta preserved.
#   4. the commit message mirror-push WOULD use contains no "vyos" token.
#   5. seed vs sync mode selection works (driven by the gh stub's canned
#      answer), without hitting GitHub.
#   6. --dry-run never pushes and never creates a repo (no `git push` /
#      `gh repo create` marker files written by the stubs).
#   7. --allow-residuals is bounded by the checked-in allowlist
#      (overlay-dozenos-build/expected-residuals.txt): a residual matching an allowlist
#      entry passes; an unallowlisted residual (candidate genuine vyos leak)
#      fails closed even under --allow-residuals/--build-repo.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/mirror-push.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------
# Fixture: a tiny local "upstream" git repo on branch `rolling` containing
# every landmine mirror-push.sh must handle: a vyos content string, a
# .github/workflows/ file (upstream CI that must be stripped), and a vyatta
# string (must survive).
# ---------------------------------------------------------------------------
UPSTREAM="$WORK/upstream.git-src"
mkdir -p "$UPSTREAM"/{.github/workflows,debian}
cat > "$UPSTREAM/debian/control" <<'EOF'
Source: vyos-example
Package: vyos-example
Maintainer: VyOS Maintainers <maintainers@vyos.net>
EOF
printf 'vyatta legacy note, VYATTA_DIR=/opt/vyatta\n' > "$UPSTREAM/notes-vyatta.txt"
cat > "$UPSTREAM/.github/workflows/build.yml" <<'EOF'
name: build
on: [push]
jobs:
  build:
    uses: vyos/.github/.github/workflows/reusable.yml@production
EOF
printf 'README for vyos-example\n' > "$UPSTREAM/README.md"

# The two files overlay-dozenos-1x/value-fixes/pin-nonmirrored-org-refs.sh
# expects to find and revert (item #14 Run 6, below) -- pre-transform
# vyos-form content/path, so rename-transform.sh's four-form pass turns them
# into exactly the dozenos-form pin-nonmirrored-org-refs.sh looks for
# (github.com/dozenos/coderabbit, python/dozenos/qos/base.py containing
# github.com/dozenos/vyatta-cfg-qos), which it then deliberately reverts back
# to the real (non-mirrored) vyos-form -- same 2-residual behavior as the
# real dozenos-1x overlay (see that script's own header).
printf '# https://github.com/vyos/coderabbit/blob/production/.coderabbit.yaml\ninheritance: true\n' \
  > "$UPSTREAM/.coderabbit.yaml"
mkdir -p "$UPSTREAM/python/vyos/qos"
printf 'https://github.com/vyos/vyatta-cfg-qos/blob/equuleus/lib/Vyatta/Qos/ShaperClass.pm\n' \
  > "$UPSTREAM/python/vyos/qos/base.py"

git -C "$UPSTREAM" init --quiet -b rolling
git -C "$UPSTREAM" -c user.name="Fixture" -c user.email="fixture@example.invalid" add -A
git -C "$UPSTREAM" -c user.name="Fixture" -c user.email="fixture@example.invalid" \
  commit --quiet -m "vyos-example initial import"
UPSTREAM_URL="file://$UPSTREAM"
UPSTREAM_SHA=$(git -C "$UPSTREAM" rev-parse --short HEAD)

# ---------------------------------------------------------------------------
# gh stub -- a fake `gh` prepended to PATH so mode-detect never touches
# github.com. Controlled via $GH_STUB_MODE (seed|sync). Any `gh repo create`/
# `gh repo view <name>` (no --json) invocation records a marker file so we
# can assert dry-run never invokes them for real side effects (dry-run
# shouldn't call gh at all beyond mode-detect, but this also double-checks
# non-dry-run pathways don't accidentally fire during dry-run tests).
# ---------------------------------------------------------------------------
STUBBIN="$WORK/stubbin"
mkdir -p "$STUBBIN"
GH_CALLS_LOG="$WORK/gh-calls.log"
: > "$GH_CALLS_LOG"

cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS_LOG"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  if printf '%s\n' "$*" | grep -q -- '--json'; then
    if [ "${GH_STUB_MODE:-seed}" = "sync" ]; then
      echo '{"isEmpty":false}'
      exit 0
    else
      echo '{"isEmpty":true}'
      exit 0
    fi
  fi
  # plain `gh repo view <name>` existence probe (used by real seed push path)
  [ "${GH_STUB_MODE:-seed}" = "sync" ] && exit 0
  exit 1
fi
if [ "$1" = "repo" ] && [ "$2" = "create" ]; then
  echo "CREATED" >> "$WORK_MARKER_DIR/gh-repo-create.marker"
  exit 0
fi
exit 0
STUB
chmod +x "$STUBBIN/gh"

WORK_MARKER_DIR="$WORK/markers"
mkdir -p "$WORK_MARKER_DIR"
export WORK_MARKER_DIR GH_CALLS_LOG
export PATH="$STUBBIN:$PATH"

# git stub wrapping the real git, only to detect a real `push` to a
# github.com remote (defense in depth -- in --dry-run this must never fire).
REAL_GIT=$(command -v git)
cat > "$STUBBIN/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then
  for a in "\$@"; do
    case "\$a" in
      *github.com*) echo "PUSHED \$*" >> "$WORK_MARKER_DIR/git-push.marker" ;;
    esac
  done
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUBBIN/git"

# ---------------------------------------------------------------------------
# Run 1: --dry-run, gh stub says the mirror does NOT exist yet -> seed mode.
# ---------------------------------------------------------------------------
echo "== dry-run, seed (repo does not exist) =="
WORK_DIR1="$WORK/run-seed"
OUT1=$(GH_STUB_MODE=seed "$SCRIPT" "$UPSTREAM_URL" --target mirror-push-test \
  --branch rolling --dry-run --work "$WORK_DIR1" 2>&1)
RC1=$?

if [ "$RC1" -eq 0 ]; then ok "dry-run (seed) exits 0"; else
  bad "dry-run (seed) exited $RC1"; printf '%s\n' "$OUT1"
fi

if printf '%s\n' "$OUT1" | grep -q 'mode: seed'; then
  ok "seed vs sync: correctly detected 'seed' when repo is absent"
else
  bad "expected 'mode: seed' in output"; printf '%s\n' "$OUT1"
fi

if printf '%s\n' "$OUT1" | grep -q 'gh repo create'; then
  ok "dry-run seed prints the gh repo create command"
else
  bad "dry-run seed did not print a gh repo create command"
fi

TREE1="$WORK_DIR1/clone"
n=$({ grep -rIi vyos "$TREE1" --exclude-dir=.git 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$n" -eq 0 ]; then ok "transform applied: 0 residual vyos in pushed tree"; else
  bad "residual vyos found ($n) in transformed tree"
  grep -rIn vyos "$TREE1" --exclude-dir=.git | head
fi

# Item #14: mirror-push.sh now regenerates .github/workflows/sync.yml for
# EVERY target after the strip -- so .github/ existing again post-pipeline is
# expected, but it must contain ONLY the generated sync.yml, never any of the
# upstream fixture's original .github content (its .github/workflows/build.yml
# carried a `uses: vyos/.github/...` reusable-workflow reference -- if that
# survived, the strip step itself would be broken, not just superseded by
# item #14's re-add).
if [ -f "$TREE1/.github/workflows/sync.yml" ]; then
  ok ".github/workflows/sync.yml generated (item #14)"
else
  bad ".github/workflows/sync.yml was not generated"; find "$TREE1/.github" 2>/dev/null
fi

github_files=$(find "$TREE1/.github" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$github_files" -eq 1 ]; then
  ok ".github/ contains ONLY the generated sync.yml (upstream .github/ content fully stripped)"
else
  bad ".github/ contains $github_files file(s), expected exactly 1 (sync.yml only)"
  find "$TREE1/.github" -type f 2>/dev/null
fi

# github.event.repository.name is UNSET on this workflow's `schedule` trigger
# (the primary/unattended path -- see sync.yml.template's own header and
# SYNC.md section 3) -- only workflow_dispatch populates it, which previously
# masked a hard failure of the ENTIRE decentralized daily sync on every
# mirror, every night (mirror-push.sh's `--target` guard dies on an empty
# value). The generated sync.yml must never use that payload-only expression,
# and must instead derive the bare repo name from the always-populated
# GITHUB_REPOSITORY runner env var.
# shellcheck disable=SC2016 # single-quoted on purpose: literal grep -F pattern, not shell expansion
if grep -qF '${{ github.event.repository.name' "$TREE1/.github/workflows/sync.yml" 2>/dev/null; then
  bad "generated sync.yml still uses github.event.repository.name (empty on the schedule trigger -- see mirror-push: header)"
else
  ok "generated sync.yml does not use github.event.repository.name"
fi

if grep -q 'GITHUB_REPOSITORY##\*/' "$TREE1/.github/workflows/sync.yml" 2>/dev/null; then
  ok "generated sync.yml derives the target from GITHUB_REPOSITORY (always populated, incl. on schedule)"
else
  bad "generated sync.yml does not derive the target from GITHUB_REPOSITORY (\${GITHUB_REPOSITORY##*/})"
fi

if grep -rq 'uses: vyos' "$TREE1/.github" 2>/dev/null; then
  bad "upstream .github/ content (uses: vyos/...) survived the strip"
else
  ok "upstream .github/ content (uses: vyos/...) did not survive the strip"
fi

if grep -q 'VYATTA_DIR=/opt/vyatta' "$TREE1/notes-dozenos.txt" 2>/dev/null \
   || grep -rq 'VYATTA_DIR=/opt/vyatta' "$TREE1" 2>/dev/null; then
  ok "vyatta preserved"
else
  bad "vyatta content was not preserved"
  find "$TREE1" -maxdepth 1
fi

if printf '%s\n' "$OUT1" | grep -q 'commit subject: sync: rename-transform snapshot (upstream @'"$UPSTREAM_SHA"')'; then
  ok "commit subject uses upstream short SHA"
else
  bad "commit subject missing/unexpected"; printf '%s\n' "$OUT1" | grep 'commit subject' || true
fi

commit_line=$(printf '%s\n' "$OUT1" | grep 'commit subject:')
if printf '%s' "$commit_line" | grep -qi vyos; then
  bad "commit subject contains 'vyos': $commit_line"
else
  ok "commit subject/message is zero-vyos"
fi

if [ -f "$WORK_MARKER_DIR/gh-repo-create.marker" ]; then
  bad "dry-run (seed) actually invoked 'gh repo create' -- must only print it"
else
  ok "dry-run (seed) did not actually create a repo"
fi
if [ -f "$WORK_MARKER_DIR/git-push.marker" ]; then
  bad "dry-run (seed) actually pushed to a github.com remote"
else
  ok "dry-run (seed) did not push anything"
fi

# ---------------------------------------------------------------------------
# default_branch fix (cicd.note item #19 cycle-12 gap): a seed push must set
# the new repo's default_branch via `gh api -X PATCH`. --dry-run must PRINT
# that command (never invoke it -- gh is only called for mode-detect here).
# ---------------------------------------------------------------------------
if printf '%s\n' "$OUT1" | grep -qF "gh api -X PATCH repos/dozenos/mirror-push-test -f default_branch=rolling"; then
  ok "dry-run (seed) prints the default_branch PATCH command"
else
  bad "dry-run (seed) did not print the default_branch PATCH command"; printf '%s\n' "$OUT1"
fi
if grep -q '^api ' "$GH_CALLS_LOG"; then
  bad "dry-run (seed) actually invoked 'gh api' -- must only print it"
else
  ok "dry-run (seed) did not actually invoke 'gh api' (PATCH default_branch)"
fi

# ---------------------------------------------------------------------------
# Run 2: --dry-run, gh stub says the mirror EXISTS and is non-empty -> sync.
# ---------------------------------------------------------------------------
echo "== dry-run, sync (repo exists) =="
: > "$GH_CALLS_LOG"
rm -f "$WORK_MARKER_DIR"/*.marker
WORK_DIR2="$WORK/run-sync"
OUT2=$(GH_STUB_MODE=sync "$SCRIPT" "$UPSTREAM_URL" --target mirror-push-test \
  --branch rolling --dry-run --work "$WORK_DIR2" 2>&1)
RC2=$?

if [ "$RC2" -eq 0 ]; then ok "dry-run (sync) exits 0"; else
  bad "dry-run (sync) exited $RC2"; printf '%s\n' "$OUT2"
fi

if printf '%s\n' "$OUT2" | grep -q 'mode: sync'; then
  ok "seed vs sync: correctly detected 'sync' when repo exists+non-empty"
else
  bad "expected 'mode: sync' in output"; printf '%s\n' "$OUT2"
fi

if printf '%s\n' "$OUT2" | grep -q 'fast-forward'; then
  ok "dry-run sync mentions fast-forward (no --force) push"
else
  bad "dry-run sync did not describe a fast-forward push"
fi

if printf '%s\n' "$OUT2" | grep -q 'gh repo create'; then
  bad "dry-run (sync) should NOT print a gh repo create command"
else
  ok "dry-run (sync) correctly omits gh repo create"
fi

if [ -f "$WORK_MARKER_DIR/gh-repo-create.marker" ] || [ -f "$WORK_MARKER_DIR/git-push.marker" ]; then
  bad "dry-run (sync) actually touched GitHub"
else
  ok "dry-run (sync) did not touch GitHub"
fi

if printf '%s\n' "$OUT2" | grep -q 'default_branch'; then
  bad "dry-run (sync) should NOT print a default_branch PATCH command (only seed sets it)"
else
  ok "dry-run (sync) correctly omits the default_branch PATCH command"
fi

# ---------------------------------------------------------------------------
# Run 3: --allow-residuals is now BOUNDED by the checked-in allowlist
# (overlay-dozenos-build/expected-residuals.txt / residuals_allowlisted() in
# mirror-push.sh) -- it no longer blanket-allows any verify failure. Two
# cases, both via a per-repo overlay applied AFTER the plain-tree verify
# would otherwise pass:
#   3a. an UNALLOWLISTED residual (a stand-in for a genuine new vyos leak)
#       must FAIL CLOSED -- with AND without --allow-residuals. This is the
#       regression test for the fixed defect: the previous implementation
#       only checked --verify's boolean exit code, so this case used to
#       wrongly pass under --allow-residuals.
#   3b. a residual that exactly reproduces an ALLOWLISTED entry (same
#       repo-relative path + same content token as a real
#       overlay-dozenos-build/expected-residuals.txt line) must still PASS under
#       --allow-residuals -- confirms the allowlist match itself works, not
#       just that unmatched residuals are rejected.
# ---------------------------------------------------------------------------
echo "== verify guard rail: allowlist-bounded --allow-residuals =="

# 3a: UNALLOWLISTED residual (candidate genuine leak) -- fails closed either way.
OVERLAY_DIR="$WORK/bad-overlay"
mkdir -p "$OVERLAY_DIR"
printf 'residual vyos token\n' > "$OVERLAY_DIR/RESIDUAL.txt"

WORK_DIR3="$WORK/run-badoverlay"
if OUT3=$(GH_STUB_MODE=seed "$SCRIPT" "$UPSTREAM_URL" --target mirror-push-test \
    --branch rolling --dry-run --overlay "$OVERLAY_DIR" --work "$WORK_DIR3" 2>&1); then
  bad "expected mirror-push.sh to FAIL closed on residual vyos without --allow-residuals"
  printf '%s\n' "$OUT3"
else
  ok "fails closed (no --allow-residuals) when verify finds residual vyos"
fi

WORK_DIR4="$WORK/run-badoverlay-allowed"
if OUT4=$(GH_STUB_MODE=seed "$SCRIPT" "$UPSTREAM_URL" --target mirror-push-test \
    --branch rolling --dry-run --overlay "$OVERLAY_DIR" --allow-residuals \
    --work "$WORK_DIR4" 2>&1); then
  bad "--allow-residuals should NOT have allowed an unallowlisted residual through -- --allow-residuals is bounded by the allowlist, not a blanket allow"
  printf '%s\n' "$OUT4"
else
  ok "--allow-residuals still fails closed on an UNALLOWLISTED residual (candidate genuine leak)"
fi

if printf '%s\n' "$OUT4" | grep -qF 'NOT in the allowlist'; then
  ok "--allow-residuals failure names the unallowlisted-residual reason"
else
  bad "--allow-residuals failure did not mention the allowlist"; printf '%s\n' "$OUT4"
fi

if printf '%s\n' "$OUT4" | grep -qF 'UNEXPECTED (not in'; then
  ok "--allow-residuals failure logs the specific UNEXPECTED residual line"
else
  bad "--allow-residuals failure did not log the UNEXPECTED residual line"; printf '%s\n' "$OUT4"
fi

if [ -f "$WORK_MARKER_DIR/git-push.marker" ]; then
  bad "an unallowlisted residual must never reach the push step (marker found)"
else
  ok "an unallowlisted residual never reaches the push step"
fi

# 3b: residual that exactly reproduces an ALLOWLISTED entry (path + token
# taken verbatim from overlay-dozenos-build/expected-residuals.txt) -- must still pass.
OVERLAY_DIR_OK="$WORK/allowlisted-overlay"
mkdir -p "$OVERLAY_DIR_OK/docker"
printf 'deb [signed-by=/usr/share/keyrings/dozenos-dev-archive-keyring.asc] https://packages.vyos.net/repositories/rolling rolling main\n' \
  > "$OVERLAY_DIR_OK/docker/dozenos-dev.list"

WORK_DIR3B="$WORK/run-allowlisted-overlay"
if OUT3B=$(GH_STUB_MODE=seed "$SCRIPT" "$UPSTREAM_URL" --target mirror-push-test \
    --branch rolling --dry-run --overlay "$OVERLAY_DIR_OK" --allow-residuals \
    --work "$WORK_DIR3B" 2>&1); then
  ok "--allow-residuals passes a residual that exactly matches an allowlist entry"
else
  bad "--allow-residuals should have passed an allowlisted-only residual"
  printf '%s\n' "$OUT3B"
fi

if printf '%s\n' "$OUT3B" | grep -qF 'allowlisted (toolchain-apt)'; then
  ok "the allowlisted residual is classified with its allowlist reason (toolchain-apt)"
else
  bad "expected the allowlisted-reason classification log line"; printf '%s\n' "$OUT3B"
fi

# ---------------------------------------------------------------------------
# Run 4 (item #18d, count updated by REPOINT-AUDIT.md #6): --build-repo must
# IMPLY --allow-residuals -- the deliberate, small, known residual set for
# the dozenos-build target (9 non-git build-time pointers: the original 5
# post-#18d, plus 4 more from REPOINT-AUDIT.md #6's
# pin-nonmirrored-org-refs.sh reverts -- see that script's header) must not
# cause verify to refuse the push, WITHOUT the caller separately passing
# --allow-residuals. Driven
# against the real local vyos-build checkout via a file:// URL (a plain local
# filesystem clone -- not a network host) so the fixture exercises the actual
# wire-prebuild-hooks.sh + apply-overlay.sh --ci + new-files/ overlay content
# (item #18d's actual fix target), rather than a hand-rolled synthetic stand-in
# that could accidentally not exercise the real overlay files at all.
# ---------------------------------------------------------------------------
echo "== --build-repo implies --allow-residuals (item #18d) =="
VYOS_BUILD_LOCAL="/home/date/git/dozenos/vyos-build"
if [ -d "$VYOS_BUILD_LOCAL/.git" ]; then
  WORK_DIR5="$WORK/run-buildrepo"
  # No --allow-residuals passed on purpose -- this is exactly the case that
  # used to refuse to push (ALLOW_RESIDUALS stayed 0 even with --build-repo).
  OUT5=$(GH_STUB_MODE=seed "$SCRIPT" "file://$VYOS_BUILD_LOCAL" --target dozenos-build-test \
    --branch rolling --build-repo --dry-run --work "$WORK_DIR5" 2>&1)
  RC5=$?

  if [ "$RC5" -eq 0 ]; then
    ok "--build-repo (no --allow-residuals) exits 0"
  else
    bad "--build-repo (no --allow-residuals) exited $RC5"; printf '%s\n' "$OUT5"
  fi

  if printf '%s\n' "$OUT5" | grep -q 'refusing to push'; then
    bad "--build-repo (no --allow-residuals) refused to push -- --build-repo must imply --allow-residuals"
  else
    ok "--build-repo (no --allow-residuals) did not refuse to push"
  fi

  if printf '%s\n' "$OUT5" | grep -qF 'residual vyos found, but --allow-residuals set and every residual matches the allowlist -- continuing'; then
    ok "--build-repo (no --allow-residuals) exercised the allow-residuals continue path"
  else
    bad "--build-repo (no --allow-residuals) did not report the expected allow-residuals continue path"
    printf '%s\n' "$OUT5"
  fi

  # The real dozenos-build tree's 9 residuals are exactly the checked-in
  # overlay-dozenos-build/expected-residuals.txt set -- confirms "a transform whose output
  # contains ONLY allowlisted residuals passes under --build-repo" against
  # the REAL pipeline output, not just a synthetic fixture (see Run 3b for
  # the synthetic/network-free version of the same assertion).
  if printf '%s\n' "$OUT5" | grep -qF 'UNEXPECTED (not in'; then
    bad "--build-repo real-tree run reported an UNEXPECTED (unallowlisted) residual -- allowlist is out of date, see overlay-dozenos-build/expected-residuals.txt"
    printf '%s\n' "$OUT5" | grep -F 'UNEXPECTED (not in'
  else
    ok "--build-repo real-tree run has zero UNEXPECTED (unallowlisted) residuals"
  fi

  # item #18d + REPOINT-AUDIT.md #6: exactly 9 deliberate non-git residuals
  # (3 source-mirror tarball URLs + cdn.vyos.io + packages.vyos.net
  # apt-source + the 4 pin-nonmirrored-org-refs.sh reverts: .coderabbit.yaml,
  # 2 AGENTS.md lines, scripts/ansible-install), NOT the 6 new-files/ recipe
  # scm_urls (those must read dozenos/* now).
  n_residual=$(printf '%s\n' "$OUT5" | grep -oE '\([0-9]+ residual vyos\)' | grep -oE '[0-9]+' || true)
  if [ "$n_residual" = "9" ]; then
    ok "--build-repo residual count is exactly 9 (item #18d + REPOINT-AUDIT.md #6)"
  else
    bad "--build-repo residual count is '$n_residual', expected 9"
    printf '%s\n' "$OUT5" | grep -A10 'residual vyos'
  fi

  if printf '%s\n' "$OUT5" | grep -qE 'scripts/package-build/(vyatta-bash|vyatta-biosdevname|vyatta-cfg|ipaddrcheck|hvinfo|dozenos-http-api-tools)/package.toml'; then
    bad "a new-files/ recipe scm_url showed up as residual -- item #18d regression"
  else
    ok "none of the 6 new-files/ recipe scm_urls are residual (item #18d)"
  fi

  # ---------------------------------------------------------------------- #
  # Item #14: --build-repo must still get its own generated sync.yml,
  # COEXISTING with the item #8 build workflows (build-docker-image.yml,
  # rebuild-packages.yml) under the same .github/workflows/ directory,
  # with "--build-repo" (and nothing else -- --allow-residuals is implied,
  # not also baked) on its flags line.
  # ---------------------------------------------------------------------- #
  SYNC5="$WORK_DIR5/clone/.github/workflows/sync.yml"
  if [ -f "$SYNC5" ]; then
    ok "--build-repo: sync.yml generated (item #14)"
  else
    bad "--build-repo: sync.yml was not generated"
  fi

  for wf in build-docker-image.yml rebuild-packages.yml; do
    if [ -f "$WORK_DIR5/clone/.github/workflows/$wf" ]; then
      ok "--build-repo: $wf coexists alongside sync.yml"
    else
      bad "--build-repo: $wf missing -- item #8 build workflows must coexist with sync.yml"
    fi
  done

  if grep -qF 'MIRROR_PUSH_FLAGS="--build-repo"' "$SYNC5" 2>/dev/null; then
    ok "--build-repo: sync.yml bakes exactly '--build-repo' (no redundant --allow-residuals)"
  else
    bad "--build-repo: sync.yml did not bake the expected '--build-repo' flags line"
    grep 'MIRROR_PUSH_FLAGS=' "$SYNC5" 2>/dev/null || true
  fi

  if python3 -c "import yaml,sys; yaml.safe_load(open('$SYNC5'))" 2>/dev/null; then
    ok "--build-repo: generated sync.yml is valid YAML"
  else
    bad "--build-repo: generated sync.yml FAILED yaml.safe_load"
  fi

  # shellcheck disable=SC2016 # single-quoted on purpose: literal grep -F pattern, not shell expansion
  if grep -qF '${{ github.event.repository.name' "$SYNC5" 2>/dev/null; then
    bad "--build-repo: generated sync.yml still uses github.event.repository.name (empty on the schedule trigger)"
  else
    ok "--build-repo: generated sync.yml does not use github.event.repository.name"
  fi

  if grep -q 'GITHUB_REPOSITORY##\*/' "$SYNC5" 2>/dev/null; then
    ok "--build-repo: generated sync.yml derives the target from GITHUB_REPOSITORY (always populated, incl. on schedule)"
  else
    bad "--build-repo: generated sync.yml does not derive the target from GITHUB_REPOSITORY (\${GITHUB_REPOSITORY##*/})"
  fi

  # ---------------------------------------------------------------------- #
  # Run 5b: the actual defect this fix closes -- a future upstream commit
  # that adds a genuine NEW vyos/VyOS string to the real dozenos-build tree
  # must still fail closed even under --build-repo (which forces
  # --allow-residuals on unconditionally). Stack a synthetic --overlay on
  # top of the SAME real --build-repo pipeline as Run 4/5 to inject one,
  # standing in for "upstream added a new vyos reference next cycle".
  # Case-mixed ("VyOS") on purpose -- also exercises the rename-transform.sh
  # --verify listing/count case-sensitivity fix (grep -rIn -> grep -rIni)
  # this same cycle found: the listing used to silently omit
  # VyOS/VYOS/Vyos-form residuals that the count still included, which would
  # have made the allowlist diff blind to exactly this kind of leak.
  # ---------------------------------------------------------------------- #
  echo "== --build-repo still fails closed on an UNALLOWLISTED (genuine-leak-shaped) residual =="
  LEAK_OVERLAY_DIR="$WORK/leak-overlay"
  mkdir -p "$LEAK_OVERLAY_DIR"
  printf 'a brand new genuine VyOS leak from a future upstream commit\n' \
    > "$LEAK_OVERLAY_DIR/INJECTED-LEAK.txt"

  WORK_DIR5B="$WORK/run-buildrepo-leak"
  if OUT5B=$(GH_STUB_MODE=seed "$SCRIPT" "file://$VYOS_BUILD_LOCAL" --target dozenos-build-test \
      --branch rolling --build-repo --dry-run --overlay "$LEAK_OVERLAY_DIR" \
      --work "$WORK_DIR5B" 2>&1); then
    bad "--build-repo must still refuse to push an unallowlisted (candidate genuine leak) residual"
    printf '%s\n' "$OUT5B"
  else
    ok "--build-repo fails closed on an injected unallowlisted residual, despite implying --allow-residuals"
  fi

  if printf '%s\n' "$OUT5B" | grep -qF 'INJECTED-LEAK.txt'; then
    ok "the injected leak is named in the UNEXPECTED-residual output"
  else
    bad "the injected leak was not reported in the output"; printf '%s\n' "$OUT5B"
  fi

  if printf '%s\n' "$OUT5B" | grep -qF 'NOT in the allowlist'; then
    ok "--build-repo unallowlisted-residual refusal uses the allowlist-specific message"
  else
    bad "unallowlisted residual should report the allowlist-specific refusal message"; printf '%s\n' "$OUT5B"
  fi
else
  echo "  SKIP: $VYOS_BUILD_LOCAL is not a git checkout here -- skipping the real-tree --build-repo test"
fi

# ---------------------------------------------------------------------------
# Run 6 (item #14): --overlay must bake BOTH "--overlay <portable-path>" AND
# "--allow-residuals" onto the generated sync.yml's flags line -- the exact
# dozenos-1x case (its overlay is not a --build-repo push, so
# --allow-residuals is NOT implied and must be baked explicitly). Uses the
# REAL overlay-dozenos-1x directory (network-free: it's a local toolkit dir,
# not a clone) so portable_overlay_path()'s happy path (overlay dir lives
# under dozenos-rebrand root) is exercised against real toolkit content, not
# a hand-rolled stand-in.
#
# This scenario needs its OWN upstream fixture, distinct from $UPSTREAM_URL
# used by Runs 1-5: overlay-dozenos-1x/apply-overlay.sh's step 1
# (value-fixes/regen-default-password-hash.sh) now UNCONDITIONALLY
# self-checks, at the end of every run, that all 5 KNOWN target files exist
# and that whatever default-user hash is live on disk authenticates
# `dozenos` (see that script's own header -- audit item #8/#23's fail-closed
# fix). $UPSTREAM_URL is a minimal landmine-only fixture (vyos string,
# .github/, vyatta string) and deliberately does NOT ship
# `data/config.boot.default` or the other 4 known files -- applying the real
# dozenos-1x overlay against it would `die` at that self-check, before
# generate_sync_workflow() (step 5/7) ever runs, which is exactly what this
# test is actually meant to exercise (sync.yml flag-baking, not the
# password-hash fix itself -- that is fully covered end-to-end by
# test-apply-overlay-dozenos-1x.sh). So: copy $UPSTREAM and add the 5 known
# files carrying the real inherited VyOS default-login hash (same OLD_HASH
# test-apply-overlay-dozenos-1x.sh uses) so the overlay's replace + self-check
# pass for real, keeping this scenario end-to-end faithful to how `--overlay
# dozenos-rebrand/overlay-dozenos-1x` is actually invoked.
# ---------------------------------------------------------------------------
echo "== --overlay bakes '--overlay <portable-path> --allow-residuals' (item #14) =="

UPSTREAM6="$WORK/upstream6.git-src"
cp -a "$UPSTREAM" "$UPSTREAM6"
rm -rf "$UPSTREAM6/.git"

# The exact inherited VyOS default-login SHA-512 crypt hash (crypt of the
# plaintext `vyos`) -- same literal
# overlay-dozenos-1x/value-fixes/regen-default-password-hash.sh matches on,
# and the same one test-apply-overlay-dozenos-1x.sh's fixture uses.
# shellcheck disable=SC2016 # literal crypt hash, must NOT expand
OLD_HASH='$6$QxPS.uk6mfo$9QBSo8u1FkH16gMyAVhus6fU3LOzvLR9Z9.82m3tiHFAxTtIkhaZSWssSgzt4v4dGAL8rhVQxTg0oAG9/q11h/'

mkdir -p "$UPSTREAM6"/data "$UPSTREAM6"/tests/data "$UPSTREAM6"/src/tests \
         "$UPSTREAM6"/smoketest/configs/assert

cat > "$UPSTREAM6/data/config.boot.default" <<EOF
system {
    login {
        user vyos {
            authentication {
                encrypted-password "$OLD_HASH"
            }
        }
    }
}
EOF

cat > "$UPSTREAM6/tests/data/config.boot.default" <<EOF
system {
    login {
        user vyos {
            authentication {
                encrypted-password $OLD_HASH
            }
        }
    }
}
EOF

cat > "$UPSTREAM6/src/tests/test_initial_setup.py" <<EOF
class TestInitialSetup(TestCase):
    def test_password_changed(self):
        old_pw = '$OLD_HASH'
        new_pw = get_config_value('system login user vyos authentication encrypted-password')
        self.assertNotEqual(old_pw, new_pw)
EOF

cat > "$UPSTREAM6/smoketest/configs/firewall-groups-name" <<EOF
system {
    login {
        user vyos {
            authentication {
                encrypted-password $OLD_HASH
            }
        }
    }
}
EOF

cat > "$UPSTREAM6/smoketest/configs/assert/firewall-groups-name" <<EOF
set system login user vyos authentication encrypted-password '$OLD_HASH'
EOF

git -C "$UPSTREAM6" init --quiet -b rolling
git -C "$UPSTREAM6" -c user.name="Fixture" -c user.email="fixture@example.invalid" add -A
git -C "$UPSTREAM6" -c user.name="Fixture" -c user.email="fixture@example.invalid" \
  commit --quiet -m "vyos-1x-example initial import (with default-login hash fixture)"
UPSTREAM6_URL="file://$UPSTREAM6"

WORK_DIR6="$WORK/run-overlay-dozenos-1x"
OUT6=$(GH_STUB_MODE=seed "$SCRIPT" "$UPSTREAM6_URL" --target dozenos-1x-test \
  --branch rolling --overlay "$TOOLKIT/overlay-dozenos-1x" --allow-residuals \
  --dry-run --work "$WORK_DIR6" 2>&1)
RC6=$?

if [ "$RC6" -eq 0 ]; then ok "--overlay dry-run exits 0"; else
  bad "--overlay dry-run exited $RC6"; printf '%s\n' "$OUT6"
fi

SYNC6="$WORK_DIR6/clone/.github/workflows/sync.yml"
if [ -f "$SYNC6" ]; then
  ok "--overlay: sync.yml generated (item #14)"
else
  bad "--overlay: sync.yml was not generated"
fi

if grep -qF 'MIRROR_PUSH_FLAGS="--overlay dozenos-rebrand/overlay-dozenos-1x --allow-residuals"' "$SYNC6" 2>/dev/null; then
  ok "--overlay: sync.yml bakes '--overlay dozenos-rebrand/overlay-dozenos-1x --allow-residuals'"
else
  bad "--overlay: sync.yml did not bake the expected overlay+allow-residuals flags line"
  grep 'MIRROR_PUSH_FLAGS=' "$SYNC6" 2>/dev/null || true
fi

if python3 -c "import yaml,sys; yaml.safe_load(open('$SYNC6'))" 2>/dev/null; then
  ok "--overlay: generated sync.yml is valid YAML"
else
  bad "--overlay: generated sync.yml FAILED yaml.safe_load"
fi

# shellcheck disable=SC2016 # single-quoted on purpose: literal grep -F pattern, not shell expansion
if grep -qF '${{ github.event.repository.name' "$SYNC6" 2>/dev/null; then
  bad "--overlay: generated sync.yml still uses github.event.repository.name (empty on the schedule trigger)"
else
  ok "--overlay: generated sync.yml does not use github.event.repository.name"
fi

if grep -q 'GITHUB_REPOSITORY##\*/' "$SYNC6" 2>/dev/null; then
  ok "--overlay: generated sync.yml derives the target from GITHUB_REPOSITORY (always populated, incl. on schedule)"
else
  bad "--overlay: generated sync.yml does not derive the target from GITHUB_REPOSITORY (\${GITHUB_REPOSITORY##*/})"
fi

if [ -n "$(grep -i vyos "$SYNC6" 2>/dev/null)" ]; then
  bad "--overlay: generated sync.yml contains a residual 'vyos' token"
else
  ok "--overlay: generated sync.yml is zero-vyos"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
