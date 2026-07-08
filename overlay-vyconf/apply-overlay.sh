#!/usr/bin/env bash
#
# apply-overlay.sh -- per-repo overlay for the dozenos/vyconf mirror (upstream
# github.com/vyos/vyconf). Applies the one fix rename-transform.sh cannot
# reproduce on top of an already-transformed vyconf clone.
#
# Pipeline position (mode-B, per mirror-push.sh):
#
#   fresh clone -> rename-transform.sh <tree> -> strip .github/ ->
#   overlay-vyconf/apply-overlay.sh <tree> -> rename-transform.sh <tree> --verify
#   -> push
#
# Invoked by mirror-push.sh's `--overlay <dir>` step, which runs
# `<dir>/apply-overlay.sh <clone-dir>` (single positional argument). For the
# vyconf re-push:
#
#   mirror-push.sh https://github.com/vyos/vyconf --target vyconf \
#     --overlay dozenos-rebrand/overlay-vyconf --branch rolling
#
# Steps, in order:
#
#   1. value-fixes/fix-ocaml-protoc-pin.sh -- correct upstream's stale
#      `ocaml-protoc {build & < "3.0"}` pin (which contradicts the committed
#      3.x-API generated code and makes dozenos-1x's vyconf compile fail). See
#      that script's own header for the full rationale and the end-to-end
#      validation.
#
# Note: "vyconf" is deliberately NOT four-form-renamed (it does not contain
# "vyos"), so rename-transform.sh is essentially a no-op on this repo apart from
# any incidental vyos strings; this overlay is the only substantive change, and
# it introduces zero "vyos" tokens (the mirror stays verify-clean).
#
# Idempotent: the one sub-step is idempotent (see its own header). Running twice
# against the same tree is a clean no-op on the second run.
#
# No network, no git, no build -- pure file operations.
#
# Usage:
#   apply-overlay.sh <target-tree>
set -euo pipefail

die() { printf 'apply-overlay: %s\n' "$*" >&2; exit 2; }
usage() { echo "Usage: $0 <target-tree>" >&2; }

TARGET="${1:-}"
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ -n "$TARGET" ] || { usage; die "missing required <target-tree>"; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"
[ $# -le 1 ] || die "unexpected extra argument(s): ${*:2}"
TARGET=$(cd "$TARGET" && pwd)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VALUE_FIXES="$SCRIPT_DIR/value-fixes"

echo "== apply-overlay (vyconf): step 1/1 -- value-fixes/fix-ocaml-protoc-pin.sh =="
"$VALUE_FIXES/fix-ocaml-protoc-pin.sh" "$TARGET"

echo "apply-overlay (vyconf): done"
