#!/usr/bin/env bash
#
# wire-prebuild-hooks.sh -- ensure every scripts/package-build/*/package.toml
# [[packages]] block declares a pre_build_hook.
#
# WHY: rename-transform.sh rebrands a source TREE, but it has no way to wire
# itself into a recipe's build config. Without a pre_build_hook, a C2 recipe
# (one that clones its own upstream source at build time) ships package
# CONTENT that still contains literal "vyos" strings, even though the rest of
# vyos-build has been transformed -- the clone happens *after* the tree-wide
# transform already ran. `pre_build_hook = "/dozenos-rebrand/rename-transform.sh ."`
# closes that gap: package-build runs it against the freshly cloned source,
# right before build_cmd, so the built .deb's content is zero-vyos.
# See dozenos-rebrand/TRANSFORM-COMPLETENESS-AUDIT.md item #4 (the ~20
# recipes this was previously hand-wired into, one at a time, per recipe).
#
# This is the second step of the mode-B transform pipeline, run immediately
# after rename-transform.sh itself:
#   git clone upstream vyos-build  ->  rename-transform.sh <clone>  ->
#   wire-prebuild-hooks.sh <clone>/scripts/package-build  ->  overlay-dozenos-build/*  ->  build
# Folding it into a companion script (instead of leaving it as ~20 one-off
# hand edits) makes it survive an upstream sync: new/changed recipes get the
# hook automatically instead of silently shipping vyos-branded content.
#
# Idempotent: a [[packages]] block that already declares ANY pre_build_hook
# (even one doing something unrelated, e.g. isc-kea's "cd ..; ./prebuild.sh",
# or strongswan's sed-prefixed hook) is left completely untouched -- never
# clobbered. Running this script twice produces byte-identical output to
# running it once.
#
# Usage:
#   wire-prebuild-hooks.sh [--check|--list] [target-package-build-dir]
#
#   --check / --list   report which recipes/blocks would change; do not write
#   (no flag)           apply the change in place
#
#   target-package-build-dir defaults to this repo's own sibling checkout's
#   scripts/package-build/ (../vyos-build/scripts/package-build relative to
#   this script), so mode-B CI can instead point it at a fresh transformed
#   clone.
#
# LOCAL ONLY -- this script never runs git or touches the network.
set -euo pipefail

die()   { printf 'wire-prebuild-hooks: %s\n' "$*" >&2; exit 2; }
usage() { echo "Usage: $0 [--check|--list] [target-package-build-dir]" >&2; }

HOOK_LINE='pre_build_hook = "/dozenos-rebrand/rename-transform.sh ."'

# ---------------------------------------------------------------------------
# Recipe dirs that must NEVER receive a pre_build_hook, no matter how many of
# their [[packages]] blocks lack one.
#
# linux-kernel: its build driver is scripts/package-build/linux-kernel/build.py
# -- a BESPOKE per-recipe script, NOT the generic scripts/package-build/build.py
# that everything else uses. The bespoke driver dispatches each block's
# `build_cmd` string (e.g. "build_kernel", "build_intel_qat") to its own
# internal Python functions and never reads `package.get('pre_build_hook', ...)`
# at all (verified: zero references to "pre_build_hook" anywhere in that
# file). Inserting the hook into any of its 16 blocks would be dead,
# never-executed configuration -- worse, actively misleading, since it would
# look like the C2 zero-vyos mechanism is wired in when it silently is not.
# Each of its OOT-driver/tarball-fetch recipes already does its own
# source-transform/fetch handling in its own build-*.sh/build-*.py (see
# overlay-dozenos-build/logic-patches/revert-source-mirror-urls.sh for the one place that
# needs a value fix, not a hook).
#
# Deliberately NOT excluded here (see overlay-dozenos-build/MANIFEST.md "wire-prebuild-hooks
# narrowing" for the full rationale): vyos-1x, libnss-mapuser,
# libpam-radius-auth, shim-signed, and vpp's "vyos-vpp-patches" block are
# likewise not part of today's hand-wired set, but for a DIFFERENT reason
# (their scm_url is a VyOS-maintained helper repo with no dozenos-org mirror
# yet, an external-state fact that may change -- see
# overlay-dozenos-build/value-fixes/pin-helper-scm-urls.sh) -- nothing about their build
# driver makes a pre_build_hook actively wrong the way it is for
# linux-kernel, so this script does not special-case them; it simply hasn't
# been asked to touch them because they don't show up with a missing hook in
# a way anyone has needed fixed. Third-party recipes (podman, telegraf,
# zerotier-one, the AWS/Xen agents, pyhumps, bash-completion, ddclient,
# waagent) are excluded from consideration for the same "nothing to fix"
# reason, not by a script-level rule.
EXCLUDE_RECIPES=(
  "linux-kernel"
)

is_excluded() {
  local name="$1" x
  for x in "${EXCLUDE_RECIPES[@]}"; do
    [ "$name" = "$x" ] && return 0
  done
  return 1
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_TARGET="$SCRIPT_DIR/../vyos-build/scripts/package-build"

MODE=apply
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--list) MODE=check; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             usage; die "unknown option: $1" ;;
    *)              [ -z "$TARGET" ] || die "unexpected extra argument: $1"
                    TARGET="$1"; shift ;;
  esac
done
TARGET="${TARGET:-$DEFAULT_TARGET}"
[ -d "$TARGET" ] || die "not a directory: $TARGET"

# ---------------------------------------------------------------------------
# Per-file transform: split on [[packages]] blocks (a section header like
# [dependencies] or [defaults] closes the current block); a block that has no
# pre_build_hook line gets one inserted directly after its scm_url line
# (matching the placement/quoting every hand-wired recipe already uses) or,
# failing that, appended at the end of the block. Blocks that already declare
# pre_build_hook are copied through unchanged.
#
# Emits the (possibly unchanged) file content on stdout, and a summary line
# "STATS <total-blocks> <changed-blocks> <changed-names-csv>" on stderr.
# ---------------------------------------------------------------------------
AWK_PROG='
function flush_block(   i, added) {
  added = 0
  for (i = 1; i <= n; i++) {
    print buf[i]
    if (!has_hook && i == scm_idx) { print hookline; added = 1 }
  }
  if (!has_hook && scm_idx == 0 && n > 0) { print hookline; added = 1 }
  if (added) {
    changed++
    names = (names == "" ? pkgname : names "," pkgname)
  }
  total++
}
BEGIN { in_block = 0; total = 0; changed = 0; names = "" }
/^\[\[packages\]\]/ {
  if (in_block) flush_block()
  in_block = 1; n = 0; has_hook = 0; scm_idx = 0; pkgname = "?"
  n++; buf[n] = $0
  next
}
/^\[/ && !/^\[\[packages\]\]/ {
  if (in_block) { flush_block(); in_block = 0 }
  print
  next
}
{
  if (in_block) {
    n++; buf[n] = $0
    if ($0 ~ /^pre_build_hook[ \t]*=/) has_hook = 1
    if ($0 ~ /^scm_url[ \t]*=/)         scm_idx = n
    if ($0 ~ /^name[ \t]*=/) {
      pkgname = $0
      sub(/^name[ \t]*=[ \t]*"/, "", pkgname)
      sub(/".*/, "", pkgname)
    }
  } else print
}
END {
  if (in_block) flush_block()
  printf "STATS %d %d %s\n", total, changed, names > "/dev/stderr"
}
'

grand_files=0
grand_blocks=0

while IFS= read -r -d '' f; do
  recipe=$(basename "$(dirname "$f")")
  if is_excluded "$recipe"; then
    continue
  fi
  out=$(mktemp)
  err=$(mktemp)
  awk -v hookline="$HOOK_LINE" "$AWK_PROG" "$f" >"$out" 2>"$err"
  stats=$(sed -n 's/^STATS //p' "$err")
  total=${stats%% *}
  rest=${stats#* }
  changed=${rest%% *}
  csv=${rest#* }
  rm -f "$err"

  if [ "${changed:-0}" -gt 0 ]; then
    grand_files=$((grand_files + 1))
    grand_blocks=$((grand_blocks + changed))
    if [ "$MODE" = check ]; then
      printf '%-28s %s/%s block(s) missing pre_build_hook (%s)\n' \
        "$recipe" "$changed" "$total" "$csv"
    else
      cat "$out" > "$f"
      printf 'wired: %-28s %s/%s block(s) (%s)\n' "$recipe" "$changed" "$total" "$csv"
    fi
  fi
  rm -f "$out"
done < <(find "$TARGET" -mindepth 2 -maxdepth 2 -name package.toml -not -path '*/.git/*' -print0 | sort -z)

if [ "$MODE" = check ]; then
  if [ "$grand_files" -eq 0 ]; then
    echo "check: no changes needed (idempotent) -- every recipe already declares pre_build_hook"
  else
    echo "check: $grand_files recipe(s) / $grand_blocks block(s) would receive pre_build_hook"
  fi
else
  if [ "$grand_files" -eq 0 ]; then
    echo "no changes needed (idempotent) -- every recipe already declares pre_build_hook"
  else
    echo "wired $grand_files recipe(s) / $grand_blocks block(s)"
  fi
fi
