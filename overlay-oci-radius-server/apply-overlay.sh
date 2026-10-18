#!/usr/bin/env bash
set -euo pipefail

die() { printf 'apply-overlay: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || die "usage: $0 <target-tree>"
[ -d "$TARGET" ] || die "not a directory: $TARGET"
[ $# -le 1 ] || die "unexpected extra argument(s): ${*:2}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "== apply-overlay (oci-radius-server): new-files/ =="
cp -a "$SCRIPT_DIR/new-files/." "$TARGET/"
echo "apply-overlay (oci-radius-server): done"
