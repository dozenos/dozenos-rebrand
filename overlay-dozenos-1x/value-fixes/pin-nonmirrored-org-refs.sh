#!/usr/bin/env bash
#
# pin-nonmirrored-org-refs.sh -- revert stray `github.com/dozenos/*` refs that
# rename-transform.sh's four-form pass correctly produced (zero residual
# `vyos`, passes --verify cleanly) but that point at repos with NO `dozenos`
# org mirror and no mirror plan -- found by ../../REPOINT-AUDIT.md step #6
# cross-check ("does every github.com/dozenos/<name> ref actually resolve?").
# Same script name/pattern as ../../overlay/value-fixes/pin-nonmirrored-org-refs.sh
# (the vyos-build overlay's equivalent) -- kept as two separate per-repo
# scripts, not a shared one, per the "Per-repo overlay split" convention (see
# ../../overlay/MANIFEST.md): this overlay is scoped to dozenos-1x only.
#
# Targets:
#   .coderabbit.yaml            -- CodeRabbit org-level baseline-config
#                                   inherit link (comment/doc pointer only,
#                                   read by the CodeRabbit bot's
#                                   `inheritance: true` gate, not fetched by
#                                   any git/build tooling). IDENTICAL content
#                                   to vyos-build's own .coderabbit.yaml
#                                   (org-wide template). Confirmed real:
#                                   github.com/vyos/coderabbit exists.
#                                   github.com/dozenos/coderabbit does not.
#   python/dozenos/qos/base.py  -- an `_build_base_qdisc()` docstring linking
#                                   to the old Perl QoS implementation for
#                                   historical context. `vyos/vyatta-cfg-qos`
#                                   is real (confirmed via `gh repo view`) but
#                                   ARCHIVED -- a historical predecessor repo,
#                                   not part of the dozenos mirror plan (it is
#                                   not `vyatta-cfg`, the still-in-use C
#                                   backend that IS mirrored).
#
# WHY unconditional (no --ci/--local split, matching this overlay's own
# apply-overlay.sh, which has no mode flag at all): both are real, permanent,
# non-mirrored targets, not a temporary pre-push-order gap -- same reasoning
# as ../../overlay/value-fixes/pin-toolchain-apt-source.sh.
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
  "python/dozenos/qos/base.py|github.com/dozenos/vyatta-cfg-qos|github.com/vyos/vyatta-cfg-qos"
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
