#!/usr/bin/env bash
#
# mirror-push.sh -- reproducible mode-B mirror-push helper.
#
# Mirrors ONE upstream git repo to github.com/dozenos/<target>, following the
# LOCKED mirror + snapshot-append sync model (see
# memory/dozenos-mode-b-transform-completeness.md and
# .powerloop/2026-07-07-cicd.note.md items #4/#14/#19):
#
#   fresh clone upstream @ <branch>
#     -> rename-transform.sh <clone>            (four-form, keep vyatta)
#     -> strip <clone>/.github/ entirely
#     -> [--build-repo: wire-prebuild-hooks.sh + apply-overlay.sh --ci]
#     -> [--overlay <dir>: apply that per-repo overlay]
#     -> generate <clone>/.github/workflows/sync.yml from sync.yml.template
#        (item #14, EVERY target -- plain, build-repo, and overlay alike;
#        see SYNC.md and generate_sync_workflow() below)
#     -> rename-transform.sh <clone> --verify   (0 residual, or --allow-residuals)
#     -> MODE DETECT (gh repo view dozenos/<target> --json isEmpty)
#          seed: repo missing/empty  -> squash (git init -b <branch>), one
#                commit, gh repo create --public, git push -u origin <branch>,
#                gh api PATCH default_branch=<branch>
#          sync: repo exists+has history -> clone the EXISTING mirror,
#                overwrite its whole tree (propagating upstream deletions),
#                ONE snapshot commit, git push (fast-forward, no --force)
#
# Commit messages are SHA-only and contain ZERO "vyos" token, including the
# body -- the dozenos<->upstream URL mapping is the only vyos residual, and
# it lives in the CALLER's argument / UPSTREAM_URL mapping, never in this
# script or in anything it writes to the mirror.
#
# This script itself never hardcodes any vyos URL: the upstream URL is
# always a caller-supplied argument.
#
# Usage:
#   mirror-push.sh <upstream-url> --target <name> [--branch <name>]
#                  [--build-repo] [--overlay <dir>] [--allow-residuals]
#                  [--dry-run] [--work <dir>]
#
# --dry-run runs the WHOLE pipeline for real (clone/transform/strip/
# hooks/overlay/verify) against the given <upstream-url> but only PRINTS the
# `gh repo create`/`git push` commands instead of running them -- nothing is
# pushed and no repo is created.
#
# LOCAL ONLY except for the final push step (and, in --build-repo mode, the
# `gh repo view` mode-detect call) -- never runs against a vyos host.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RENAME_TRANSFORM="$SCRIPT_DIR/rename-transform.sh"
WIRE_HOOKS="$SCRIPT_DIR/wire-prebuild-hooks.sh"
APPLY_OVERLAY="$SCRIPT_DIR/overlay-dozenos-build/apply-overlay.sh"
SYNC_TEMPLATE="$SCRIPT_DIR/sync.yml.template"
# Checked-in allowlist of DELIBERATE vyos residuals --allow-residuals may
# pass through --verify (see residuals_allowlisted() below and that file's
# own header for the format/rationale). This bounds --allow-residuals to a
# known set instead of blanket-allowing any verify failure.
EXPECTED_RESIDUALS="$SCRIPT_DIR/overlay-dozenos-build/expected-residuals.txt"

# ref of dozenos/dozenos-rebrand the generated sync.yml pins its own
# "Checkout dozenos-rebrand" step to (item #14, see SYNC.md). Overridable via
# env for a future rollout against a different default branch; not a CLI
# flag -- this is a toolkit-wide constant, not a per-invocation choice.
REBRAND_REF="${REBRAND_REF:-main}"

die()  { printf 'mirror-push: %s\n' "$*" >&2; exit 2; }
log()  { printf 'mirror-push: %s\n' "$*" >&2; }
usage() {
  cat >&2 <<'EOF'
Usage: mirror-push.sh <upstream-url> --target <name> [options]

  <upstream-url>       upstream git URL to mirror (required, never hardcoded)
  --target <name>      dozenos repo name (required)
  --branch <name>      branch to mirror/push (default: rolling)
  --build-repo         this is the dozenos-build mirror: also run
                        wire-prebuild-hooks.sh + apply-overlay.sh, and allow
                        the whitelisted build-time-pointer residuals.
                        IMPLIES --allow-residuals (the small, known,
                        deliberate residual set is unavoidable for this
                        target; no need to also pass --allow-residuals)
  --overlay <dir>      apply an additional per-repo overlay directory
  --allow-residuals    do not fail on --verify residuals (print & continue).
                        Always implied by --build-repo; still required
                        (and must be passed explicitly) for any mirror run
                        that does NOT use --build-repo
  --dry-run            run the full local pipeline but only print the
                        gh/push commands -- never pushes, never creates a repo
  --work <dir>         scratch directory (default: a fresh mktemp -d)
  -h, --help           show this help
EOF
}

# --- args --------------------------------------------------------------------
UPSTREAM_URL="${1:-}"
[ -n "$UPSTREAM_URL" ] || { usage; die "missing required <upstream-url>"; }
case "$UPSTREAM_URL" in
  -h|--help) usage; exit 0 ;;
  -*) usage; die "expected <upstream-url> as the first argument, got option: $UPSTREAM_URL" ;;
esac
shift

TARGET=""
BRANCH="rolling"
BUILD_REPO=0
OVERLAY_DIR=""
ALLOW_RESIDUALS=0
DRY_RUN=0
WORK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --target)          TARGET="${2:-}"; shift 2 ;;
    --branch)          BRANCH="${2:-}"; shift 2 ;;
    --build-repo)       BUILD_REPO=1; shift ;;
    --overlay)          OVERLAY_DIR="${2:-}"; shift 2 ;;
    --allow-residuals)  ALLOW_RESIDUALS=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --work)             WORK="${2:-}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; die "unknown argument: $1" ;;
  esac
done

# --build-repo IMPLIES --allow-residuals: dozenos-build always carries a
# small, known, deliberate set of non-git build-time-pointer residuals (the
# reverted packages.vyos.net/source-mirror tarball fetches, the reverted
# packages.vyos.net / cdn.vyos.io toolchain apt hosts, and the reverted
# dangling github.com/dozenos/* refs with no mirror -- .coderabbit.yaml,
# AGENTS.md, scripts/ansible-install, REPOINT-AUDIT.md #6 -- see
# overlay-dozenos-build/apply-overlay.sh --ci's step 3 and overlay-dozenos-build/MANIFEST.md). Requiring
# the caller to separately pass --allow-residuals for every --build-repo run
# is redundant (it is *always* required, never optional, for this target) and
# was previously a latent bug: --build-repo alone left ALLOW_RESIDUALS=0, so
# step 5's verify unconditionally refused to push. An explicit
# --allow-residuals is still honored (and still required) for every mirror
# run that does NOT pass --build-repo -- that fail-closed default is
# unchanged for ordinary (non-build-repo) per-package mirrors.
#
# --allow-residuals does NOT blanket-allow -- it is bounded by the checked-in
# allowlist (EXPECTED_RESIDUALS / overlay-dozenos-build/expected-residuals.txt, enforced by
# residuals_allowlisted() at step 6). Every residual line --verify reports
# must match an allowlist entry (same file + a content-substring match) or
# mirror-push.sh dies (fail-closed) even with --allow-residuals/--build-repo
# set. This was a real gap: the previous implementation only checked
# --verify's boolean exit code, so ANY residual -- including a brand-new
# genuine vyos leak introduced by a future upstream commit -- was logged as
# "known build-time pointers" and pushed anyway, nightly, with no alert, for
# dozenos-build (the highest-churn repo, --build-repo always implies
# --allow-residuals). An unmatched residual is now treated as a candidate
# genuine leak and refused.
if [ "$BUILD_REPO" -eq 1 ]; then
  ALLOW_RESIDUALS=1
fi

[ -n "$TARGET" ] || { usage; die "--target <name> is required"; }
case "$TARGET" in
  */*|"") die "invalid --target: '$TARGET'" ;;
esac
if [ -n "$OVERLAY_DIR" ]; then
  [ -d "$OVERLAY_DIR" ] || die "--overlay dir not found: $OVERLAY_DIR"
fi
[ -x "$RENAME_TRANSFORM" ] || die "missing dependency: $RENAME_TRANSFORM"
if [ "$BUILD_REPO" -eq 1 ]; then
  [ -x "$WIRE_HOOKS" ]    || die "missing dependency: $WIRE_HOOKS"
  [ -x "$APPLY_OVERLAY" ] || die "missing dependency: $APPLY_OVERLAY"
fi
[ -f "$SYNC_TEMPLATE" ]      || die "missing dependency: $SYNC_TEMPLATE"
[ -f "$EXPECTED_RESIDUALS" ] || die "missing dependency: $EXPECTED_RESIDUALS"

# ------------------------------------------------------------------------- #
# sync.yml generation (item #14) -- every target gets its own
# .github/workflows/sync.yml, generated fresh from sync.yml.template with
# THIS invocation's flags baked in, right before the final verify+push (see
# step 5/7 below, and SYNC.md for the full design). Runs for ALL targets:
# plain mirrors, --build-repo, and --overlay alike -- never gated on any of
# those flags, only shaped by them.
# ------------------------------------------------------------------------- #

# portable_overlay_path <dir> -- rewrite a caller-supplied --overlay <dir>
# (typically given relative to wherever mirror-push.sh itself was invoked
# from, e.g. "dozenos-rebrand/overlay-dozenos-1x") into the path THAT SAME
# overlay will live at inside the self-sync workflow's own workspace, where
# dozenos-rebrand is freshly checked out to a sibling directory literally
# named "dozenos-rebrand" (see sync.yml.template's "Checkout dozenos-rebrand"
# step). Every overlay this toolkit ships lives under the dozenos-rebrand
# root ($SCRIPT_DIR) for exactly this reason; dies loudly if that ever stops
# being true rather than silently baking an unreachable path into generated
# CI.
portable_overlay_path() {
  local dir="$1" abs rel
  abs=$(cd "$dir" 2>/dev/null && pwd) || die "--overlay dir not found: $dir"
  case "$abs" in
    "$SCRIPT_DIR"/*)
      rel="${abs#"$SCRIPT_DIR"/}"
      printf 'dozenos-rebrand/%s' "$rel"
      ;;
    *)
      # Every real per-repo overlay this toolkit ships (overlay-dozenos-build/,
      # overlay-dozenos-1x/) lives under $SCRIPT_DIR for exactly this
      # reason -- an ad-hoc/test overlay outside it (e.g. a synthetic
      # fixture directory) has no portable CI path, since the self-sync
      # workflow only ever checks out dozenos-rebrand, not this directory.
      # Warn and omit --overlay from the baked flags rather than failing the
      # whole push closed over what is, for any real toolkit overlay, an
      # unreachable code path.
      log "WARNING: --overlay dir '$dir' is not inside $SCRIPT_DIR (dozenos-rebrand root) -- omitting --overlay from this mirror's generated sync.yml (no portable CI path to bake); this is expected only for an ad-hoc/test overlay, never for a real toolkit overlay"
      ;;
  esac
}

# generate_sync_workflow <clone-dir> -- render sync.yml.template into
# <clone-dir>/.github/workflows/sync.yml, baking in the flags THIS
# mirror-push.sh invocation used (minus the upstream URL, which is never
# baked -- it stays a caller-supplied secret at CI time, see SYNC.md).
# Byte-stable: for a given (BRANCH, BUILD_REPO, OVERLAY_DIR, ALLOW_RESIDUALS)
# tuple the output is identical on every call -- the target name never
# appears as literal text, only derived at CI runtime from the always-
# populated `GITHUB_REPOSITORY` runner env var (`${GITHUB_REPOSITORY##*/}`,
# NOT the `github.event.repository.name` expression -- that field is unset on
# a `schedule` trigger, this workflow's primary/unattended path), so two
# different targets sharing the same flags produce byte-identical files.
generate_sync_workflow() {
  local clone_dir="$1"
  local flags="" flags_display

  if [ "$BUILD_REPO" -eq 1 ]; then
    flags="--build-repo"
  fi
  if [ -n "$OVERLAY_DIR" ]; then
    local portable
    portable=$(portable_overlay_path "$OVERLAY_DIR")
    if [ -n "$portable" ]; then
      flags="${flags:+$flags }--overlay $portable"
    fi
  fi
  # --build-repo already implies --allow-residuals (see above) -- do not
  # also bake a redundant explicit flag in that case. Every non-build-repo
  # mirror that was actually pushed with --allow-residuals (e.g. dozenos-1x's
  # --overlay) bakes it explicitly, matching the exact invocation used.
  if [ "$BUILD_REPO" -ne 1 ] && [ "$ALLOW_RESIDUALS" -eq 1 ]; then
    flags="${flags:+$flags }--allow-residuals"
  fi

  if [ -n "$flags" ]; then
    flags_display="$flags"
  else
    flags_display="(none -- plain mirror; only --target/--branch)"
  fi

  mkdir -p "$clone_dir/.github/workflows"
  sed \
    -e "s|@@BRANCH@@|$BRANCH|g" \
    -e "s|@@MIRROR_PUSH_FLAGS@@|$flags|g" \
    -e "s|@@MIRROR_PUSH_FLAGS_COMMENT@@|$flags_display|g" \
    -e "s|@@REBRAND_REF@@|$REBRAND_REF|g" \
    "$SYNC_TEMPLATE" > "$clone_dir/.github/workflows/sync.yml"
}

if [ -z "$WORK" ]; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
else
  mkdir -p "$WORK"
fi
CLONE_DIR="$WORK/clone"
rm -rf "$CLONE_DIR"

log "target=dozenos/$TARGET branch=$BRANCH build-repo=$BUILD_REPO dry-run=$DRY_RUN"

# ------------------------------------------------------------------------- #
# 1) Fresh clone of the upstream repo. --depth 1: this pipeline only ever
#    ships a SNAPSHOT of the upstream tree (squash / snapshot-append), so no
#    upstream history is needed, only the tip commit's short SHA for the
#    (zero-vyos, SHA-only) commit message.
# ------------------------------------------------------------------------- #
log "1/7 cloning upstream @ $BRANCH ..."
git clone --quiet --depth 1 --branch "$BRANCH" --single-branch \
  "$UPSTREAM_URL" "$CLONE_DIR" \
  || die "clone failed: $UPSTREAM_URL (branch $BRANCH)"
UPSTREAM_SHA=$(git -C "$CLONE_DIR" rev-parse --short HEAD)
log "upstream short SHA: $UPSTREAM_SHA"

# ------------------------------------------------------------------------- #
# 2) rename-transform.sh -- full four-form, vyatta preserved.
# ------------------------------------------------------------------------- #
log "2/7 rename-transform.sh ..."
"$RENAME_TRANSFORM" "$CLONE_DIR"

# ------------------------------------------------------------------------- #
# 3) Strip the upstream .github/ entirely (its VyOS-org workflows must never
#    run against our mirror / ping VyOS infra -- see cicd.note item #4).
# ------------------------------------------------------------------------- #
log "3/7 stripping .github/ ..."
rm -rf "$CLONE_DIR/.github"

# ------------------------------------------------------------------------- #
# 4) Optional build-repo hooks/overlay + optional per-repo overlay.
# ------------------------------------------------------------------------- #
if [ "$BUILD_REPO" -eq 1 ]; then
  log "4/7 --build-repo: wire-prebuild-hooks.sh + apply-overlay.sh --ci ..."
  PKG_BUILD_DIR="$CLONE_DIR/scripts/package-build"
  [ -d "$PKG_BUILD_DIR" ] || die "--build-repo given but $PKG_BUILD_DIR does not exist"
  "$WIRE_HOOKS" "$PKG_BUILD_DIR"
  # (cicd.note item #18c, DONE; item #18d, DONE): apply-overlay.sh now has a
  # --ci/--local mode split. dozenos-build is only ever pushed via
  # --build-repo AFTER its dependency mirrors exist (leaf-first push order),
  # so this always runs in --ci mode: the 14 mirrored git scm_urls
  # (pin-helper-scm-urls.sh's set -- 8 transformed recipes plus the 6
  # new-files/ recipes, item #18d) stay at github.com/dozenos/* instead of
  # being pinned back to github.com/vyos/*. --build-repo IMPLIES
  # --allow-residuals (set unconditionally above, right after arg parsing) --
  # the residual set for this target is small and known: only the
  # genuinely-not-mirrored, non-git-host/non-mirrored-org build-time pointers
  # remain (the reverted packages.vyos.net/source-mirror tarball fetches x3,
  # the reverted packages.vyos.net / cdn.vyos.io toolchain apt hosts, and 4
  # more from REPOINT-AUDIT.md #6's pin-nonmirrored-org-refs.sh: the
  # .coderabbit.yaml ref, 2 AGENTS.md lines, and scripts/ansible-install)
  # -- 9 total. Neither the 14 git scm_urls nor the 6 new-files/ ones are
  # residual vyos in --ci mode any more.
  log "NOTE: apply-overlay.sh --ci leaves mirrored git scm_urls at dozenos/*; residuals expected are only the 9 non-git-host/non-mirrored-org build-time pointers in $EXPECTED_RESIDUALS (--build-repo implies --allow-residuals, bounded by that allowlist)"
  "$APPLY_OVERLAY" --ci "$CLONE_DIR"
else
  log "4/7 --build-repo not set, skipping wire-prebuild-hooks/apply-overlay"
fi

if [ -n "$OVERLAY_DIR" ]; then
  log "4/7 applying per-repo overlay: $OVERLAY_DIR"
  if [ -x "$OVERLAY_DIR/apply-overlay.sh" ]; then
    "$OVERLAY_DIR/apply-overlay.sh" "$CLONE_DIR"
  else
    # Plain file overlay: copy the overlay tree on top, preserving structure.
    # EXCLUDE anything under .github/ -- this generic --overlay mechanism is
    # for per-repo value-fix content only (see WORKFLOW-POLICY.md's "Where
    # DozenOS's own workflows come from"); the only sanctioned sources of
    # .github/workflows/* content are overlay-dozenos-build/new-files/ (via --build-repo)
    # and this script's own generate_sync_workflow(). A plain --overlay dir
    # must never be able to smuggle .github/ content past step 3's strip.
    ( cd "$OVERLAY_DIR" && find . -mindepth 1 \( -type f -o -type l \) -print0 ) \
      | while IFS= read -r -d '' rel; do
          case "$rel" in
            ./.github/*|./.github)
              log "WARNING: --overlay '$OVERLAY_DIR' contains '$rel' under .github/ -- skipping it (a plain --overlay may never add .github/ content; use overlay-dozenos-build/new-files/ via --build-repo instead)"
              continue
              ;;
          esac
          mkdir -p "$CLONE_DIR/$(dirname "$rel")"
          cp -a "$OVERLAY_DIR/$rel" "$CLONE_DIR/$rel"
        done
  fi
fi

# ------------------------------------------------------------------------- #
# 5) Generate this mirror's own .github/workflows/sync.yml (item #14) --
#    EVERY target, not only --build-repo ones. Runs after step 3's strip (so
#    it can never be removed by it -- the strip only ever touches the fresh
#    UPSTREAM clone, well before this point) and after step 4's optional
#    build-repo/overlay content (so it coexists with, and is never clobbered
#    by, the item #8 build workflows new-files/ places under the same
#    .github/workflows/ directory for --build-repo). Runs before verify, so
#    the standard 0-residual-vyos check also covers this generated file. See
#    SYNC.md for the full design.
# ------------------------------------------------------------------------- #
log "5/7 generating .github/workflows/sync.yml ..."
generate_sync_workflow "$CLONE_DIR"

# ------------------------------------------------------------------------- #
# 6) Verify -- must be 0 residual vyos, unless --allow-residuals AND every
#    residual matches the checked-in allowlist (EXPECTED_RESIDUALS /
#    overlay-dozenos-build/expected-residuals.txt). --allow-residuals does NOT
#    blanket-allow: an unmatched residual -- a candidate GENUINE vyos leak,
#    e.g. one introduced by a future upstream commit -- still fails closed
#    here even under --build-repo (which forces --allow-residuals on for
#    every automated dozenos-build sync, the highest-churn repo).
# ------------------------------------------------------------------------- #

# residuals_allowlisted <verify-output-file> <clone-dir> -- reads the
# residual `<abs-path>:<line>:<content>` listing rename-transform.sh --verify
# wrote (FAIL case, see that script's `verify()`/`--verify` handling) and
# checks EVERY residual line against EXPECTED_RESIDUALS. A residual line only
# passes if its file (relative to <clone-dir>) exactly matches some
# allowlist entry's path AND the line's content contains that entry's token
# substring -- matched by CONTENT, never by line number, so the allowlist
# survives upstream line-number drift. Prints every entry as it goes
# (allowlisted or UNEXPECTED) so the classification is visible in CI logs.
# Returns success (0) only if every residual line matched some entry;
# non-zero (with at least one "UNEXPECTED" line already logged) otherwise.
residuals_allowlisted() {
  local verify_out="$1" clone_dir="$2"
  local line rel al_file al_token al_reason matched unexpected=0

  while IFS= read -r line; do
    case "$line" in
      'verify: FAIL'*|'') continue ;;
    esac
    rel="${line#"$clone_dir"/}"
    rel="${rel%%:*}"
    matched=0
    while IFS='|' read -r al_file al_token al_reason; do
      case "$al_file" in
        ''|'#'*) continue ;;
      esac
      if [ "$rel" = "$al_file" ] && printf '%s\n' "$line" | grep -qF -- "$al_token"; then
        matched=1
        break
      fi
    done < "$EXPECTED_RESIDUALS"
    if [ "$matched" -eq 1 ]; then
      log "  allowlisted ($al_reason): $line"
    else
      log "  UNEXPECTED (not in $EXPECTED_RESIDUALS): $line"
      unexpected=$((unexpected + 1))
    fi
  done < "$verify_out"

  [ "$unexpected" -eq 0 ]
}

log "6/7 verify ..."
VERIFY_OUT="$WORK/verify-output.txt"
if "$RENAME_TRANSFORM" "$CLONE_DIR" --verify >"$VERIFY_OUT" 2>&1; then
  cat "$VERIFY_OUT" >&2
elif [ "$ALLOW_RESIDUALS" -eq 1 ]; then
  cat "$VERIFY_OUT" >&2
  log "residual vyos found -- checking each residual against the allowlist ($EXPECTED_RESIDUALS) ..."
  if residuals_allowlisted "$VERIFY_OUT" "$CLONE_DIR"; then
    log "residual vyos found, but --allow-residuals set and every residual matches the allowlist -- continuing (known build-time pointers)"
  else
    die "residual vyos found that is NOT in the allowlist ($EXPECTED_RESIDUALS) -- refusing to push even with --allow-residuals set (see UNEXPECTED line(s) above); this is either a genuine new vyos leak introduced upstream or a legitimate new deliberate pointer that needs an allowlist entry"
  fi
else
  cat "$VERIFY_OUT" >&2
  die "verify failed with residual vyos and --allow-residuals not set (see FAIL listing above); refusing to push"
fi

# ------------------------------------------------------------------------- #
# 7) Mode detect + push.
# ------------------------------------------------------------------------- #
detect_mode() {
  local json
  if ! json=$(gh repo view "dozenos/$TARGET" --json isEmpty 2>/dev/null); then
    echo seed
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    # NOTE: do not use jq's `//` alternative operator here -- it treats a
    # literal `false` the same as `null`/absent, which would silently flip a
    # real non-empty repo (isEmpty:false) back to "seed". Compare explicitly.
    if [ "$(printf '%s' "$json" | jq -r 'if .isEmpty == false then "false" else "true" end')" = "true" ]; then
      echo seed
    else
      echo sync
    fi
  else
    case "$json" in
      *'"isEmpty":true'*) echo seed ;;
      *)                   echo sync ;;
    esac
  fi
}

SUBJECT="sync: rename-transform snapshot (upstream @${UPSTREAM_SHA})"
BODY="DozenOS mirror -- idempotent rename-transform applied (vyatta preserved), upstream .github/ stripped. Upstream commit: ${UPSTREAM_SHA}"
AUTHOR_NAME="DozenOS autobuild"
AUTHOR_EMAIL="autobuild@dozenos.local"

log "7/7 mode detect ..."
MODE=$(detect_mode)
log "mode: $MODE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] mode: $MODE"
  echo "[dry-run] commit subject: $SUBJECT"
  case "$MODE" in
    seed)
      echo "[dry-run] would run: rm -rf $CLONE_DIR/.git && git init -b $BRANCH"
      echo "[dry-run] would run: git add -A && git commit (author: $AUTHOR_NAME <$AUTHOR_EMAIL>)"
      echo "[dry-run] would run: gh repo create dozenos/$TARGET --public --description \"DozenOS mirror (rename-transform snapshot)\""
      echo "[dry-run] would run: git remote add origin https://github.com/dozenos/$TARGET.git"
      echo "[dry-run] would run: git push -u origin $BRANCH"
      echo "[dry-run] would run: gh api -X PATCH repos/dozenos/$TARGET -f default_branch=$BRANCH"
      ;;
    sync)
      echo "[dry-run] would run: git clone --branch $BRANCH https://github.com/dozenos/$TARGET.git <scratch>"
      echo "[dry-run] would overwrite the whole tree (propagating upstream deletions), git add -A, commit"
      echo "[dry-run] would run: git push origin $BRANCH   # fast-forward, NOT --force"
      ;;
  esac
  log "dry-run complete -- nothing pushed, no repo created/touched"
  exit 0
fi

# --- sync_tree: overwrite dst's whole tracked tree with src's, propagating
#     deletions, WITHOUT touching dst's own .git. (No rsync dependency: plain
#     find/cp so this runs on a minimal toolchain.) ------------------------- #
sync_tree() {
  local src="$1" dst="$2" entry base
  find "$dst" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [ -e "$entry" ] || continue
    base=$(basename "$entry")
    [ "$base" = ".git" ] && continue
    cp -a "$entry" "$dst/"
  done
}

case "$MODE" in
  seed)
    log "seed: squashing to a single snapshot commit ..."
    rm -rf "$CLONE_DIR/.git"
    git -C "$CLONE_DIR" init --quiet -b "$BRANCH"
    # -f (force): commit the ENTIRE transformed tree as-is, overriding .gitignore.
    # Some upstreams force-add source files that also match a .gitignore pattern
    # meant for build output -- e.g. vyos-1x's root .gitignore has `lib/` (for
    # generated libs) yet the repo tracks the real source dir libvyosconfig/lib/
    # (bindings.ml, apply_bindings.ml). A plain `git add -A` re-applies .gitignore
    # and SILENTLY DROPS those tracked-upstream files, producing an incomplete
    # mirror (observed: dozenos-1x's libdozenosconfig/lib/ vanished -> the OCaml
    # bindings.cmx had no source -> the whole package failed to build). The tree
    # here is derived from a fresh `git clone` (only tracked files, zero build
    # artifacts) plus intentional overlay files, so force-adding everything
    # reproduces upstream's tracked set exactly; .gitignore still ships in the
    # snapshot for downstream build-time use.
    git -C "$CLONE_DIR" add -A -f
    git -C "$CLONE_DIR" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
      commit --quiet --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" -m "$SUBJECT" -m "$BODY"

    if ! gh repo view "dozenos/$TARGET" >/dev/null 2>&1; then
      gh repo create "dozenos/$TARGET" --public \
        --description "DozenOS mirror (rename-transform snapshot)"
    fi
    git -C "$CLONE_DIR" remote add origin "https://github.com/dozenos/$TARGET.git" 2>/dev/null \
      || git -C "$CLONE_DIR" remote set-url origin "https://github.com/dozenos/$TARGET.git"
    # --force is acceptable here only because the target repo is new/empty.
    git -C "$CLONE_DIR" push --force -u origin "$BRANCH"
    log "seed push complete: dozenos/$TARGET @ $BRANCH"

    # GAP found cicd.note item #19 cycle 12: `gh repo create` + push alone
    # leaves the new repo's `default_branch` unset. Set it explicitly.
    # Idempotent/harmless on re-run: PATCHing default_branch to the value it
    # already has is a no-op on GitHub's side (still returns 200).
    log "setting default branch: dozenos/$TARGET -> $BRANCH ..."
    gh api -X PATCH "repos/dozenos/$TARGET" -f default_branch="$BRANCH" >/dev/null
    log "default branch set: dozenos/$TARGET -> $BRANCH"
    ;;

  sync)
    log "sync: overwriting existing mirror tree with one snapshot commit ..."
    SYNC_DIR="$WORK/sync"
    rm -rf "$SYNC_DIR"
    git clone --quiet --branch "$BRANCH" "https://github.com/dozenos/$TARGET.git" "$SYNC_DIR"
    sync_tree "$CLONE_DIR" "$SYNC_DIR"
    # -f (force): same reason as the seed path above -- commit the whole tree,
    # do not let .gitignore silently drop upstream-tracked-but-ignored source
    # files (e.g. libdozenosconfig/lib/*.ml under vyos-1x's `lib/` ignore rule).
    git -C "$SYNC_DIR" add -A -f
    if git -C "$SYNC_DIR" diff --cached --quiet; then
      log "no changes vs existing mirror; nothing to sync"
    else
      git -C "$SYNC_DIR" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
        commit --quiet --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" -m "$SUBJECT" -m "$BODY"
      # Fast-forward push only -- NEVER --force after the seed.
      git -C "$SYNC_DIR" push origin "$BRANCH"
      log "sync push complete: dozenos/$TARGET @ $BRANCH"
    fi
    ;;
esac

exit 0
