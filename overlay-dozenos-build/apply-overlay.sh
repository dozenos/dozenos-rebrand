#!/usr/bin/env bash
#
# apply-overlay.sh -- mode-B CI overlay step. Applies everything
# rename-transform.sh + wire-prebuild-hooks.sh cannot reproduce on top of an
# already-transformed, already-hooked vyos-build clone.
#
# Pipeline position (mode-B, per overlay-dozenos-build/README.md):
#
#   fresh clone -> rename-transform.sh <tree> ->
#   wire-prebuild-hooks.sh <tree>/scripts/package-build -> apply-overlay.sh <tree>
#
# Steps, in order (each documented in overlay-dozenos-build/MANIFEST.md, cross-referenced
# to dozenos-rebrand/TRANSFORM-COMPLETENESS-AUDIT.md items):
#
#   1. new-files/    -- copy new recipe dirs + data/certificates/README.md
#                        (audit items #5, #6) on top of <tree>, preserving
#                        repo-relative paths and symlinks. Runs in BOTH modes.
#   2. logic-patches/ -- revert the 3 external source-mirror tarball fetch
#                        URLs (item #4-of-this-overlay / audit item shown in
#                        MANIFEST.md), and apply the vyos_mirror/dozenos_mirror
#                        empty-guard (audit item #13) to build-dozenos-image.
#                        Runs in BOTH modes -- these are non-git hosts
#                        (`packages.vyos.net`) that are genuinely not
#                        mirrored, and a logic guard, neither of which has
#                        anything to do with whether the dozenos/* git
#                        mirrors exist yet.
#   3. value-fixes/   -- revert the docker/ toolchain apt-source host
#                        (item #12, non-git host, BOTH modes), revert 3
#                        stray github.com/dozenos/* refs that name repos with
#                        no mirror and no mirror plan -- .coderabbit.yaml,
#                        AGENTS.md, scripts/ansible-install (REPOINT-AUDIT.md
#                        step #6 finding, BOTH modes, same reasoning as the
#                        apt-source host: real, permanent, non-DozenOS-owned
#                        targets), and remove the inherited MOK cert (item
#                        #9/#26, BOTH modes). The helper-repo git scm_url
#                        reverts (item #11) are MODE-DEPENDENT -- see "--ci
#                        vs --local" below.
#
# --ci vs --local (item #18c)
# ----------------------------------------------------------------------------
# `pin-helper-scm-urls.sh` reverts 14 `scm_url` blocks across 12 files:
# 8 blocks in 6 rename-transform.sh-touched files (libnss-mapuser,
# libpam-radius-auth, shim-signed, tacacs x3, vpp's vyos-vpp-patches block,
# dozenos-1x) that rename-transform.sh rewrote from `github.com/vyos/*` to
# `github.com/dozenos/*`, PLUS 6 blocks in the 6 new-files/ recipes
# (vyatta-bash, vyatta-biosdevname, vyatta-cfg, ipaddrcheck, hvinfo,
# dozenos-http-api-tools -- item #18d) which ship pre-pointed at
# `github.com/dozenos/*` since new-files/ bypasses rename-transform.sh
# entirely. Whether reverting either group is CORRECT depends on external
# state (does the `github.com/dozenos/*` mirror for that repo exist yet?):
#
#   --ci    (a.k.a. post-mirror): the dozenos/* mirrors already exist and
#           resolve -- do NOT run pin-helper-scm-urls.sh, leave all 14
#           scm_urls at github.com/dozenos/*. This is the production path:
#           the dozenos-build mirror is only ever pushed to github.com after
#           its dependency mirrors exist (see the CI/CD plan's push order,
#           leaf-first), so this is the DEFAULT.
#   --local (a.k.a. pre-mirror/offline): the mirrors may not exist yet (e.g.
#           a from-scratch offline/local build before any dozenos/* repo has
#           been pushed) -- run pin-helper-scm-urls.sh to pin all 14 scm_urls
#           back to the real, always-resolvable github.com/vyos/*. Must be
#           requested explicitly.
#
# DEFAULT: --ci. Rationale: the mirror-existence assumption --ci makes is
# true for the primary, ongoing use of this script (CI / post-mirror builds,
# including every `mirror-push.sh --build-repo` invocation); --local is the
# narrower, temporary, pre-mirror-existence case and should be opted into
# explicitly rather than silently assumed.
#
# Everything else in value-fixes/ (toolchain apt-source, MOK cert) and all of
# logic-patches/ and new-files/ run in BOTH modes -- they concern non-git
# hosts, genuinely-unmirrored third-party binary vendors, non-renaming logic,
# or brand-new files, none of which depend on dozenos/* mirror existence.
#
# Per-repo overlay split (read this before adding anything to this script):
#   This overlay is scoped to the vyos-build repo ONLY. Fixes that live
#   inside a per-package SOURCE repo -- e.g. vyos-1x's default-credential
#   password hash (audit item #8/#23), its Makefile's `git ls-files` ->
#   `find` patch, or its OCaml opam-pin repoint -- belong to THAT repo's own
#   future overlay (built as part of the per-repo mirror step, items #4/#6 of
#   the CI/CD plan), not here. Do not add vyos-1x-internal fixes to this
#   script even if you find more of them.
#
# Idempotent: every sub-step is idempotent (safe to re-run; see each script's
# own header). Running apply-overlay.sh twice, IN THE SAME MODE, against the
# same tree produces byte-identical output on the second run (verified by the
# repro test). Switching modes between two runs against the SAME tree is not
# a supported "convert" operation -- e.g. --local then --ci will not
# re-forward the 14 scm_urls to github.com/dozenos/* (--ci simply skips
# pin-helper-scm-urls.sh, it does not run it in reverse); always apply the
# overlay once, in the mode you actually want, against a freshly transformed
# tree (which is how mirror-push.sh and every mode-B pipeline run uses it).
#
# No network, no git, no package/ISO build -- pure file operations.
#
# Usage:
#   apply-overlay.sh [--ci|--local] <target-tree>
set -euo pipefail

die() { printf 'apply-overlay: %s\n' "$*" >&2; exit 2; }
usage() { echo "Usage: $0 [--ci|--local] <target-tree>" >&2; }

MODE="ci"
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ci)      MODE="ci"; shift ;;
    --local)   MODE="local"; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift ;;
    -*)        usage; die "unknown option: $1" ;;
    *)
      [ -z "$TARGET" ] || die "unexpected extra argument: $1"
      TARGET="$1"
      shift
      ;;
  esac
done

[ -n "$TARGET" ] || { usage; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"
TARGET=$(cd "$TARGET" && pwd)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEW_FILES="$SCRIPT_DIR/new-files"
LOGIC_PATCHES="$SCRIPT_DIR/logic-patches"
VALUE_FIXES="$SCRIPT_DIR/value-fixes"

# ---------------------------------------------------------------------------
# Step 1: new-files/ -- copy on top of <tree>, preserving relative paths and
# symlinks (e.g. each new recipe's `build.py -> ../build.py`).
#
# Overwrite policy: these paths are OV-NEW (audit items #5, #6) -- they must
# not already exist in a freshly transformed clone. If a destination already
# exists with DIFFERENT content than what we're about to write, that is
# either (a) a stale artifact from a previous, different overlay content
# version, or (b) an unexpected upstream-introduced path collision -- either
# way it must not be silently clobbered, so we fail loudly. If the existing
# destination is BYTE-IDENTICAL (same content, or same symlink target), this
# is just a re-run of this script (idempotent no-op for that file).
# ---------------------------------------------------------------------------
copy_new_files() {
  local src="$1" dst_root="$2"
  local count=0
  while IFS= read -r -d '' f; do
    local rel="${f#"$src"/}"
    local dst="$dst_root/$rel"
    mkdir -p "$(dirname "$dst")"

    if [ -L "$f" ]; then
      local src_tgt dst_tgt
      src_tgt=$(readlink "$f")
      if [ -L "$dst" ]; then
        dst_tgt=$(readlink "$dst")
        if [ "$src_tgt" = "$dst_tgt" ]; then
          continue   # idempotent no-op
        else
          die "refusing to overwrite existing symlink with different target: $dst (has '$dst_tgt', overlay wants '$src_tgt')"
        fi
      elif [ -e "$dst" ]; then
        die "refusing to overwrite existing non-symlink file with a symlink: $dst"
      fi
      ln -s "$src_tgt" "$dst"
      count=$((count + 1))
    else
      if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        if cmp -s "$f" "$dst"; then
          continue   # idempotent no-op
        else
          die "refusing to overwrite existing file with different content: $dst (re-review: unexpected collision with overlay new-files/$rel)"
        fi
      elif [ -L "$dst" ]; then
        die "refusing to overwrite existing symlink with a regular file: $dst"
      fi
      cp -p "$f" "$dst"
      count=$((count + 1))
    fi
  done < <(find "$src" \( -type f -o -type l \) -print0)
  echo "new-files: $count file(s)/symlink(s) written under ${dst_root#"$TARGET"/}"
}

echo "== apply-overlay: mode=$MODE =="

echo "== apply-overlay: step 1/3 -- new-files/ (both modes) =="
copy_new_files "$NEW_FILES" "$TARGET"

echo "== apply-overlay: step 2/3 -- logic-patches/ (both modes) =="
"$LOGIC_PATCHES/revert-source-mirror-urls.sh" "$TARGET"
"$LOGIC_PATCHES/vyos-mirror-guard.sh" "$TARGET"
"$LOGIC_PATCHES/dockerfile-go-path.sh" "$TARGET"

echo "== apply-overlay: step 3/3 -- value-fixes/ =="
if [ "$MODE" = "local" ]; then
  "$VALUE_FIXES/pin-helper-scm-urls.sh" "$TARGET"
else
  echo "pin-helper-scm-urls: skipped (--ci mode -- 14 mirrored git scm_urls stay at github.com/dozenos/*)"
fi
"$VALUE_FIXES/pin-toolchain-apt-source.sh" "$TARGET"
"$VALUE_FIXES/pin-nonmirrored-org-refs.sh" "$TARGET"
"$VALUE_FIXES/remove-committed-mok-cert.sh" "$TARGET"
"$VALUE_FIXES/replace-eula.sh" "$TARGET"
"$VALUE_FIXES/pin-project-urls.sh" "$TARGET"
"$VALUE_FIXES/suffix-openssl-version.sh" "$TARGET"

echo "apply-overlay: done (mode=$MODE)"
