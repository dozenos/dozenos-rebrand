#!/usr/bin/env bash
#
# rename-transform.sh -- idempotent VyOS -> DozenOS rebrand transform.
#
#   Given a target source tree, transform it IN PLACE so that the shipped
#   artifact is zero-`vyos` (case-preserving four-form replacement) while
#   `vyatta` is preserved. Running the script twice == running it once
#   (idempotent, no double-replacement corruption).
#
# What it touches:
#   1. File CONTENTS   -- all four case forms in text files (binary skipped,
#                         .git skipped, symlinks not dereferenced).
#   2. Symlink TARGETS -- rewritten without following the link (a dirty target
#                         is invisible to grep but would break the package).
#   3. File & dir NAMES-- renamed deepest-first so nested renames are safe
#                         (e.g. usr/share/vyos/ -> usr/share/dozenos/,
#                          debian/libvyosconfig0.install -> libdozenosconfig0.install).
#   4. debian/changelog-- optional +git<date>.<sha> version stamp hook for
#                         branch-tracked packages (source token itself is
#                         handled by the generic content rule).
#
# Because the generic four-form rule is a strict superset of every C1 package
# name, python namespace, soname, systemd unit and hardcoded path, no per-case
# special handling is needed -- see rebrand-map.conf and LANDMINES.md.
#
# Usage:
#   rename-transform.sh <target-tree> [--stamp <DATE.SHA>]
#   rename-transform.sh <target-tree> --verify        # only: assert zero vyos
#                                            (copyright-notice lines exempt)
#
# LOCAL ONLY -- this script never runs git.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF="${REBRAND_MAP:-$SCRIPT_DIR/rebrand-map.conf}"

die()   { printf 'rename-transform: %s\n' "$*" >&2; exit 2; }
usage() { echo "Usage: $0 <target-tree> [--stamp <DATE.SHA>] [--verify]" >&2; }

# --- args ------------------------------------------------------------------
TARGET="${1:-}"
[ -n "$TARGET" ] || { usage; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"
shift

STAMP=""
VERIFY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stamp)  STAMP="${2:-}"; shift 2 ;;
    --verify) VERIFY_ONLY=1; shift ;;
    *)        usage; die "unknown argument: $1" ;;
  esac
done
STAMP="${STAMP:-${REBRAND_VERSION_STAMP:-}}"

# --- load data-driven rules ------------------------------------------------
[ -f "$CONF" ] || die "config not found: $CONF"
# shellcheck source=rebrand-map.conf
source "$CONF"
[ "${#REBRAND_FORMS[@]}" -gt 0 ] || die "REBRAND_FORMS empty in $CONF"

# Build the sed program once from the data file.
# Email rewrites run FIRST so maintainer addresses are normalised to the
# non-existent placeholder domain (dozenos.local) before the generic
# four-form rules run -- leaving no `vyos` left in the address. Every rule
# runs under the copyright-line guard: lines containing
# COPYRIGHT_LINE_GUARD (case-insensitive) are legal notices preserved
# byte-identical (rebrand-map.conf's rationale).
# COPYRIGHT_LINE_GUARD is an ERE (for awk in verify_list); sed addresses
# here are BRE, so alternation pipes need escaping. Case-sensitive by
# design -- see rebrand-map.conf.
GUARD=""
[ -n "${COPYRIGHT_LINE_GUARD:-}" ] && GUARD="/${COPYRIGHT_LINE_GUARD//|/\\|}/!"
SED_ARGS=()
for e in "${EMAIL_REWRITES[@]:-}"; do
  [ -n "$e" ] && SED_ARGS+=( -e "${GUARD}${e}" )
done
for pair in "${REBRAND_FORMS[@]}"; do
  from="${pair%%=*}"
  to="${pair#*=}"
  SED_ARGS+=( -e "${GUARD}s/${from}/${to}/g" )
done

# Safety contract: no "from" token may be a substring of a preserved token,
# otherwise the replacement would corrupt vyatta. (Static check; cheap.)
for pair in "${REBRAND_FORMS[@]}"; do
  from="${pair%%=*}"
  for keep in "${PRESERVE_TOKENS[@]:-}"; do
    case "$keep" in
      *"$from"*) die "unsafe rule: '$from' is a substring of preserved token '$keep'" ;;
    esac
  done
done

apply_forms() { printf '%s' "$1" | sed "${SED_ARGS[@]}"; }

# verify_list emits every residual as `<path>:<line>:<content>`, exempting
# copyright-notice lines (matched on CONTENT, not path, so a file merely
# NAMED *copyright* is still scanned) -- the transform preserves those lines
# by design, see COPYRIGHT_LINE_GUARD in rebrand-map.conf. Count and FAIL
# listing both come from this one function so they can never disagree
# (mirror-push.sh's residuals_allowlisted() consumes the listing
# line-by-line; every hit contributing to the count must appear in it).
# -i matches all four vyos forms. `|| true` absorbs grep's exit-1 on
# no-match so pipefail/set -e do not abort on a clean tree.
verify_list() {
  local pf_ere="" p
  for p in "${PRESERVE_FILES[@]:-}"; do
    [ -n "$p" ] || continue
    pf_ere="${pf_ere:+$pf_ere|}(^|/)${p//./\\.}$"
  done
  { grep -rIni vyos "$TARGET" --exclude-dir=.git 2>/dev/null || true; } \
    | awk -F: -v g="${COPYRIGHT_LINE_GUARD:-}" -v pf="$pf_ere" '{
        if (pf != "" && $1 ~ pf) next
        s = ""
        for (i = 3; i <= NF; i++) s = s (i > 3 ? ":" : "") $i
        if (g != "" && s ~ g) next
        print
      }'
}

verify() { verify_list | wc -l | tr -d ' '; }

if [ "$VERIFY_ONLY" -eq 1 ]; then
  n=$(verify)
  if [ "$n" -eq 0 ]; then echo "verify: OK (0 residual vyos)"; exit 0; fi
  echo "verify: FAIL ($n residual vyos):" >&2
  verify_list >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) CONTENT PASS -- regular text files only.
#    -type f excludes symlinks; grep -Iq . skips binary; grep -qi vyos limits
#    edits to files that actually contain a form (vyatta-only files untouched).
# ---------------------------------------------------------------------------
preserved_file() {
  local rel="${1#"$TARGET"/}" p
  for p in "${PRESERVE_FILES[@]:-}"; do
    [ -n "$p" ] || continue
    case "$rel" in "$p"|*/"$p") return 0 ;; esac
  done
  return 1
}

# Write a file ONLY when its content actually changes: `sed -i` rewrites
# unconditionally (new mtime even on a no-op), and with copyright lines now
# legitimately carrying `vyos`, a second pass would stat-dirty every such
# file -- cloud-init's make-tarball checks `git diff-index HEAD` (stat
# cache, not content) and hard-fails on that. `cat >` keeps the inode and
# permissions.
while IFS= read -r -d '' f; do
  grep -Iq . "$f"      || continue   # skip binary
  grep -qi 'vyos' "$f" || continue   # skip files with no vyos form
  preserved_file "$f"  && continue   # legal files kept byte-identical
  tmp=$(mktemp)
  sed "${SED_ARGS[@]}" "$f" > "$tmp"
  cmp -s "$tmp" "$f" || cat "$tmp" > "$f"
  rm -f "$tmp"
done < <(find "$TARGET" -type f -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# 2) SYMLINK TARGET PASS -- rewrite link targets without dereferencing.
# ---------------------------------------------------------------------------
while IFS= read -r -d '' l; do
  tgt=$(readlink "$l")
  ntgt=$(apply_forms "$tgt")
  [ "$tgt" != "$ntgt" ] && ln -sfn "$ntgt" "$l"
done < <(find "$TARGET" -type l -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# 3) PATH RENAME PASS -- deepest-first (-depth), rename basename only so that
#    parent paths stay valid until their own turn. -iname catches all four
#    forms in one predicate (vyatta never contains "vyos", so it is not matched).
# ---------------------------------------------------------------------------
while IFS= read -r -d '' p; do
  d=$(dirname "$p")
  b=$(basename "$p")
  nb=$(apply_forms "$b")
  [ "$b" != "$nb" ] && mv "$p" "$d/$nb"
done < <(find "$TARGET" -mindepth 1 -depth -iname '*vyos*' -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# 4) OPTIONAL version-stamp hook for branch-tracked packages (REBRAND-PLAN
#    Section 3d gotcha 1). Appends +git<DATE.SHA> to the newest changelog entry
#    so apt sees a monotonically increasing version. Idempotent via the +git
#    guard. The source package name itself is already renamed by pass 1.
#
#    ITEM #16 GUARD: skip stamping entirely for any source package listed in
#    EXACT_PIN_STAMP_EXCLUDE (rebrand-map.conf) -- some OTHER shipped package
#    exact-`=`-pins these (e.g. vyatta-cfg pins `bash-completion (= 1:2.8-6)`,
#    see dep-graph/dep-graph.json's `iso_hard_deps` and RETROSPECTIVE.md
#    Section (c)), and a `+git<date>.<sha>` suffix would break that exact
#    match. This guard fires REGARDLESS of --stamp/REBRAND_VERSION_STAMP being
#    set -- it is a hard exclusion, not an opt-out, so this bug class cannot
#    resurface if/when a future CI step starts passing --stamp broadly.
#    The source name is read from debian/changelog's own first line (the
#    same file/field the auto-stamp itself edits), not from the target
#    directory's basename, since the two are not guaranteed to match.
# ---------------------------------------------------------------------------
if [ -n "$STAMP" ] && [ -f "$TARGET/debian/changelog" ]; then
  changelog_source=$(head -1 "$TARGET/debian/changelog" | sed -n 's/^\([^ ]*\) .*/\1/p')
  excluded=0
  for pinned in "${EXACT_PIN_STAMP_EXCLUDE[@]:-}"; do
    [ -n "$pinned" ] || continue
    if [ "$changelog_source" = "$pinned" ]; then
      excluded=1
      break
    fi
  done
  if [ "$excluded" -eq 1 ]; then
    echo "rename-transform: skipping +git version-stamp for '$changelog_source' -- exact-=-pinned elsewhere (EXACT_PIN_STAMP_EXCLUDE in rebrand-map.conf, see dep-graph/dep-graph.json iso_hard_deps)" >&2
  elif ! head -1 "$TARGET/debian/changelog" | grep -q '+git'; then
    sed -i "1s/(\([^)]*\))/(\1+git${STAMP})/" "$TARGET/debian/changelog"
  fi
fi

exit 0
