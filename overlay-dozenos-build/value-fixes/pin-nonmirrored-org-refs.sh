#!/usr/bin/env bash
#
# pin-nonmirrored-org-refs.sh -- revert stray `github.com/dozenos/*` refs that
# rename-transform.sh's four-form pass correctly produced (zero residual
# `vyos`) but that point at repos with NO `dozenos` org mirror and no plan to
# get one -- found by the REPOINT-AUDIT.md step #6 cross-check
# ("does every github.com/dozenos/<name> ref actually resolve?"), which is a
# different question than `--verify`'s "is there any literal vyos left"
# (these three all pass --verify cleanly; the bug is invisible to that check).
#
# WHY these three, and not e.g. the 14 pin-helper-scm-urls.sh entries: those
# 14 are genuine build DEPENDENCIES (a package.toml `scm_url` a recipe clones
# from) whose target mirror is on the locked, imminent 17-repo mirror plan --
# a TEMPORARY gap, contingent on push order, per pin-helper-scm-urls.sh's own
# header. The three refs here are different in kind: none of them names a
# repo on that plan at all (`coderabbit`, `vyatta-cfg-qos`, `vyos.vyos` are
# org-tooling / archived-history / a downstream Ansible collection -- not OS
# source code dozenos-build or dozenos-1x builds from). Same class as
# `pin-toolchain-apt-source.sh`'s `packages.vyos.net`/`cdn.vyos.io`: a real,
# permanent, non-DozenOS-owned target with no "mirror will exist soon"
# horizon, so it reverts in BOTH modes, not just --local.
#
# Targets:
#   .coderabbit.yaml        -- CodeRabbit org-level baseline-config inherit
#                               link (a comment/doc pointer only, read by the
#                               CodeRabbit bot's `inheritance: true` gate, not
#                               fetched by any git/build tooling). Confirmed
#                               real: github.com/vyos/coderabbit exists.
#                               github.com/dozenos/coderabbit does not.
#   AGENTS.md                -- 2 lines of prose describing a live-build fork
#                               dependency (agent-facing docs only -- the
#                               ACTUAL live-build fetch in docker/Dockerfile
#                               clones from salsa.debian.org/live-team/
#                               live-build.git directly, not from any vyos/
#                               dozenos fork, so this text was already
#                               describing something the real build doesn't
#                               do). Confirmed real: github.com/vyos/
#                               vyos-live-build exists (not archived).
#                               github.com/dozenos/dozenos-live-build does not.
#   scripts/ansible-install  -- an ACTUAL `ansible-galaxy collection install
#                               git+https://...` command (`make ansible-install`
#                               runs it for real -- this is the one target of
#                               the three that is genuinely executable, not
#                               just prose/comment). Confirmed real:
#                               github.com/vyos/vyos.vyos is VyOS's real,
#                               published, non-archived Ansible collection.
#                               github.com/dozenos/dozenos.dozenos does not
#                               exist and DozenOS has no plan to fork it.
#
# Idempotent: a target already showing the reverted (real-vyos) form is a
# no-op. Fails loudly if neither the expected transformed nor the
# already-reverted form is found (upstream sync drift -- re-review by hand).
#
# Usage:
#   pin-nonmirrored-org-refs.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'pin-nonmirrored-org-refs: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

# entries: "relative-file|dozenos-form|vyos-form"
ENTRIES=(
  ".coderabbit.yaml|github.com/dozenos/coderabbit|github.com/vyos/coderabbit"
  "AGENTS.md|dozenos/dozenos-live-build|vyos/vyos-live-build"
  "scripts/ansible-install|github.com/dozenos/dozenos.dozenos.git|github.com/vyos/vyos.vyos.git"
)

changed=0
already=0
for entry in "${ENTRIES[@]}"; do
  rel="${entry%%|*}"
  rest="${entry#*|}"
  dozenos_form="${rest%%|*}"
  vyos_form="${rest#*|}"
  f="$TARGET/$rel"

  [ -f "$f" ] || die "expected file not found (upstream sync drift?): $f"

  if grep -qF "$dozenos_form" "$f"; then
    sed -i "s|${dozenos_form}|${vyos_form}|g" "$f"
    changed=$((changed + 1))
    echo "reverted: $rel ($dozenos_form)"
  elif grep -qF "$vyos_form" "$f"; then
    already=$((already + 1))
    echo "already reverted (idempotent no-op): $rel ($vyos_form)"
  else
    die "neither expected dozenos-rewritten nor already-reverted ref found in $f for pattern '$vyos_form' -- drift, re-review by hand"
  fi
done

echo "pin-nonmirrored-org-refs: $changed reverted, $already already-clean (of ${#ENTRIES[@]} tracked)"
