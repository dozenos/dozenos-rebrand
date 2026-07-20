#!/usr/bin/env bash
#
# ensure-pin-tags.sh -- make sure every opam-pinned OCaml config lib that
# dozenos-1x builds against exists in our mirrors as an `upstream-<sha>` tag.
#
# WHY: upstream vyos-1x pins its two OCaml config libs to fixed UPSTREAM
# commits:
#   opam pin add vyos1x-config https://github.com/vyos/vyos1x-config.git#<sha> -y
#   opam pin add vyconf        https://github.com/vyos/vyconf.git#<sha> -y
# Our mode-B mirrors are snapshot repos whose commit hashes are ours, not
# upstream's, so those shas resolve to nothing and opam dies with "Commit not
# found on repository". overlay-dozenos-1x's pin-opam-upstream-tag.sh rewrites
# each pin to `#upstream-<sha>` -- a pure text derivation with no lookup table.
# This script is the other half: it creates the tag that name refers to, by
# snapshotting THAT upstream commit into the mirror
# (mirror-push.sh --pin-commit).
#
# Building the pinned commit -- rather than the mirror's branch tip, which is
# what we did until 2026-07-20 -- is what makes the dozenos-1x build
# reproducible and keeps us on the same lib code upstream builds and tests.
#
# NO CHANGE DETECTION: this runs unconditionally and is idempotent end to end.
# mirror-push.sh --pin-commit exits 0 without pushing when the tag is already
# present, so a sha that has not moved costs one `git ls-remote`. When upstream
# does move a pin, the new tag is created on the next run with no bookkeeping
# on our side, and a run that was skipped or failed simply self-heals on the
# next one.
#
# ORDER MATTERS: run this BEFORE the dozenos-1x mirror push. If dozenos-1x
# lands first, its Makefile names a tag that does not exist yet and every
# libdozenosconfig build in that window fails.
#
# Both the upstream URL and the sha are read out of the upstream Makefile line
# itself, so no upstream URL is hardcoded here (mode-B: upstream URLs always
# come from data, never from this toolkit).
#
# Usage:
#   ensure-pin-tags.sh <upstream-vyos-1x-url> [--dry-run]
#
# Needs network + a GH_TOKEN able to push tags to the mirrors it touches.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MIRROR_PUSH="$HERE/mirror-push.sh"

die() { printf 'ensure-pin-tags: %s\n' "$*" >&2; exit 2; }
log() { printf 'ensure-pin-tags: %s\n' "$*" >&2; }

UPSTREAM_URL="${1:-}"
[ -n "$UPSTREAM_URL" ] || { echo "Usage: $0 <upstream-vyos-1x-url> [--dry-run]" >&2; exit 2; }
shift
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -x "$MIRROR_PUSH" ] || die "missing dependency: $MIRROR_PUSH"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Only the Makefile is needed; a blobless shallow clone keeps this cheap.
log "reading opam pins from $UPSTREAM_URL ..."
git clone --quiet --depth 1 --filter=blob:none "$UPSTREAM_URL" "$WORK/src" \
  || die "clone failed: $UPSTREAM_URL"

MAKEFILE=$(find "$WORK/src" -maxdepth 2 -name Makefile -path '*config/Makefile' | head -1)
[ -n "$MAKEFILE" ] || die "no lib*config/Makefile found in $UPSTREAM_URL -- upstream layout drift, re-review by hand"
log "pins declared in: ${MAKEFILE#"$WORK/src/"}"

# Each pin line looks like:
#   opam pin add <pkg> https://github.com/<org>/<repo>.git#<sha> -y
# Capture <repo> and <sha>; the URL is reused verbatim as the fetch source.
mapfile -t PINS < <(grep -oE 'https://[^ ]+\.git#[0-9a-f]{7,40}' "$MAKEFILE" | sort -u)
[ "${#PINS[@]}" -gt 0 ] \
  || die "no '<url>.git#<sha>' opam pins found in $MAKEFILE -- upstream may have changed how the OCaml libs are pinned; re-review by hand"

rc=0
for pin in "${PINS[@]}"; do
  url="${pin%%#*}"
  sha="${pin##*#}"
  repo=$(basename "$url" .git)
  # The mirror carries the four-form-renamed repo name, the same rewrite
  # rename-transform.sh applies to the URL inside the Makefile.
  target=$(printf '%s' "$repo" | sed -e 's/vyos/dozenos/g; s/VyOS/DozenOS/g; s/VYOS/DOZENOS/g; s/Vyos/Dozenos/g')
  log "pin: $repo@${sha:0:7} -> dozenos/$target tag upstream-$sha"
  if ! "$MIRROR_PUSH" "$url" --target "$target" --pin-commit "$sha" $DRY_RUN; then
    log "FAILED to ensure pin tag for $repo@${sha:0:7} (target dozenos/$target)"
    rc=1
  fi
done

[ "$rc" -eq 0 ] || die "one or more pin tags could not be ensured -- dozenos-1x must NOT be pushed until they exist, or libdozenosconfig will fail to build"
log "all ${#PINS[@]} pin tag(s) present"
