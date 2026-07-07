#!/usr/bin/env bash
#
# regen-default-password-hash.sh -- replace the inherited VyOS default-login
# SHA-512 crypt hash with a freshly generated hash of the new default
# password `dozenos` (dozenos-rebrand/TRANSFORM-COMPLETENESS-AUDIT.md item
# #8/#23, dozenos-rebrand/overlay/MANIFEST.md's deferred
# `regen-default-credential.sh` entry -- this script is that deferred work,
# scoped to the vyos-1x/dozenos-1x repo, see "Per-repo overlay split" there).
#
# WHY: rename-transform.sh's four-form pass correctly rewrites the default
# login's USERNAME (`user vyos` -> `user dozenos`), but the default PASSWORD
# is stored as a SHA-512 crypt hash of the literal plaintext `vyos`
# (`$6$QxPS.uk6mfo$...`). A crypt hash of `vyos` contains no literal `vyos`
# substring -- it is high-entropy base64-ish noise -- so it passes
# rename-transform.sh's content pass (and the zero-`vyos` --verify grep gate)
# completely untouched, while the functional default credential is still,
# literally, the password `vyos`. This is the general "value-not-string"
# class documented in ../../LANDMINES.md: no textual substitution can turn
# one password's hash into a different password's hash -- the hash must be
# regenerated for the NEW plaintext and swapped in by value.
#
# Targets (verified against a fresh `git clone --depth 1
# https://github.com/vyos/vyos-1x` -- grep the OLD_HASH constant below to
# reconfirm on every upstream sync, do not trust this list blindly):
#   data/config.boot.default
#   tests/data/config.boot.default
#   src/tests/test_initial_setup.py
#   smoketest/configs/firewall-groups-name
#   smoketest/configs/assert/firewall-groups-name
#
# All 5 files carry the exact SAME hash string (confirmed by diff of the
# `$6$...` field across all 5), so a single freshly-generated replacement
# hash is applied everywhere -- there is only one "old" value and one "new"
# value in play, not five independent ones.
#
# Idempotent: matches on the FULL old-hash string (not just the `$6$` id or
# the salt) so a) a second run against an already-fixed tree is a clean
# no-op (the old hash is simply absent -- absence IS the desired end state,
# not an error), and b) we never risk touching some OTHER unrelated `$6$`
# hash that happens to also live in the tree. `openssl passwd -6` is a
# fresh-salt operation, so re-running this script when it DOES have work to
# do produces a different (but equally valid) hash each time -- this is
# expected and fine, there is no canonical "the" new hash, only "a" valid
# hash of `dozenos`, which every consumer (config.boot.default, the
# smoketests, the python test asserting the login flow) treats identically.
#
# Whole-tree search (not just the 5 known files): the fixed file list above
# is what upstream ships as of the last verification, but this script greps
# the WHOLE target tree for the exact old-hash string rather than hardcoding
# only those 5 paths, so it self-heals if upstream ever adds a 6th copy
# (e.g. a new smoketest fixture) without needing this script edited.
#
# Replacement is done with Python's plain (non-regex) str.replace() rather
# than sed, specifically because a crypt hash routinely contains regex
# metacharacters (`.`, `$`, `*`) as part of its salt/hash alphabet -- e.g.
# the very hash this script removes contains a literal `.` in its salt
# (`QxPS.uk6mfo`) and terminates with a bare `$` follower. Feeding either the
# match or replacement text through sed as a PATTERN would require careful
# metacharacter escaping to stay a correct literal match; a plain string
# replace sidesteps that whole class of bug entirely for a security-relevant
# value swap.
#
# Usage:
#   regen-default-password-hash.sh <target-tree>
#
# LOCAL ONLY -- no network beyond `openssl passwd` (local, no network I/O),
# no git.
set -euo pipefail

die() { printf 'regen-default-password-hash: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

# The exact inherited VyOS default-login SHA-512 crypt hash (crypt of the
# plaintext `vyos`). Full string used as the match key -- see "Idempotent"
# above for why this must be the complete hash, not just the `$6$` prefix.
OLD_HASH='$6$QxPS.uk6mfo$9QBSo8u1FkH16gMyAVhus6fU3LOzvLR9Z9.82m3tiHFAxTtIkhaZSWssSgzt4v4dGAL8rhVQxTg0oAG9/q11h/'

# Find every file under $TARGET (excluding .git) that still carries the old
# hash. grep -F: literal fixed-string match (the hash contains regex
# metacharacters that must NOT be interpreted).
mapfile -d '' -t HIT_FILES < <(grep -rlFZ "$OLD_HASH" "$TARGET" --exclude-dir=.git 2>/dev/null || true)

if [ "${#HIT_FILES[@]}" -eq 0 ]; then
  echo "regen-default-password-hash: already fixed / no occurrences found (idempotent no-op)"
  exit 0
fi

NEW_HASH=$(openssl passwd -6 dozenos)
[ -n "$NEW_HASH" ] || die "openssl passwd -6 produced empty output"
case "$NEW_HASH" in
  '$6$'*) : ;;
  *) die "openssl passwd -6 produced an unexpected format: $NEW_HASH" ;;
esac

for f in "${HIT_FILES[@]}"; do
  OLD_HASH="$OLD_HASH" NEW_HASH="$NEW_HASH" python3 - "$f" <<'PY'
import os
import sys

path = sys.argv[1]
old = os.environ["OLD_HASH"]
new = os.environ["NEW_HASH"]

with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()

updated = data.replace(old, new)
if updated == data:
    sys.exit(0)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(updated)
PY
  echo "regen-default-password-hash: patched ${f#"$TARGET"/}"
done

echo "regen-default-password-hash: ${#HIT_FILES[@]} file(s) patched with a freshly generated hash of 'dozenos'"
