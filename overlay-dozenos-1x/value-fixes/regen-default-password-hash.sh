#!/usr/bin/env bash
#
# regen-default-password-hash.sh -- replace the inherited VyOS default-login
# SHA-512 crypt hash with a freshly generated hash of the new default
# password `dozenos` (dozenos-rebrand/TRANSFORM-COMPLETENESS-AUDIT.md item
# #8/#23, dozenos-rebrand/overlay-dozenos-build/MANIFEST.md's deferred
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
# hash that happens to also live in the tree. The replacement NEW_HASH is a
# PINNED constant (generated once with `openssl passwd -6 dozenos`), NOT a
# fresh-salt hash per run: the sync pipeline is fresh-clone -> transform ->
# overlay, so a per-run salt made every daily sync commit differ even with
# an unchanged upstream, dispatching spurious package rebuilds and nightly
# ISO builds.
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
# End-state self-check (fail-closed on upstream hash drift): the literal
# OLD_HASH match above is a HARDCODED string, re-verified by hand against a
# fresh upstream clone (see the "Targets" comment). If upstream ever ships a
# DIFFERENT hash in one of the 5 known files -- a re-salted/reformatted hash
# that still authenticates `vyos`, or any other value -- `grep -rlF
# "$OLD_HASH"` simply will not find it, HIT_FILES is empty, and there is
# nothing for the replace loop to do. That is NOT the same thing as "already
# fixed": absence of the specific old string only proves the OLD known value
# is gone, it says nothing about what the NEW value actually is. So, after
# the (possibly no-op) replace step, this script UNCONDITIONALLY re-reads
# each of the 5 known files and asserts that whatever `$6$...` hash is
# actually on disk right now authenticates the plaintext `dozenos` --
# regardless of whether the replace loop above ran. Any known file whose
# live hash does not authenticate `dozenos` (still `vyos`, or anything else)
# is a `die`, loudly, naming the offending file, instead of a silent
# "no occurrences found" no-op. This is what makes the script fail CLOSED on
# upstream hash drift rather than fail silent.
#
# Verification uses `openssl passwd -6 -salt <extracted-salt> dozenos`
# rather than Python's `crypt` module: `crypt` was removed from the Python
# standard library (PEP 594, gone as of 3.13), so it cannot be relied on in
# the sync environment; `openssl passwd -6` is local-only (no network I/O).
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
# shellcheck disable=SC2016 # literal crypt hash, must NOT expand
OLD_HASH='$6$QxPS.uk6mfo$9QBSo8u1FkH16gMyAVhus6fU3LOzvLR9Z9.82m3tiHFAxTtIkhaZSWssSgzt4v4dGAL8rhVQxTg0oAG9/q11h/'

# Pinned SHA-512 crypt hash of the new default password `dozenos`, generated
# once with `openssl passwd -6 dozenos` -- see "Idempotent" above for why
# this must be a constant, not regenerated per run. The end-state self-check
# below verifies it authenticates `dozenos`, so a typo here fails closed.
# shellcheck disable=SC2016 # literal crypt hash, must NOT expand
NEW_HASH='$6$p5Efu/2e2g8D2hJV$2jJojvJpg/NJ1ytL9Q73zsG./pdfrtJS5WU6R3VQzx0.HAucjiKixguM/DVtamnXnp0Al8bFdL7SrWQ84G1cN0'

# The 5 known files that must carry the default-user password hash -- see
# the "Targets" comment above. Used by the end-state self-check below, in
# addition to (not instead of) the whole-tree grep this script already does
# for the replacement pass itself.
KNOWN_FILES=(
  data/config.boot.default
  tests/data/config.boot.default
  src/tests/test_initial_setup.py
  smoketest/configs/firewall-groups-name
  smoketest/configs/assert/firewall-groups-name
)

# Find every file under $TARGET (excluding .git) that still carries the old
# hash. grep -F: literal fixed-string match (the hash contains regex
# metacharacters that must NOT be interpreted).
mapfile -d '' -t HIT_FILES < <(grep -rlFZ "$OLD_HASH" "$TARGET" --exclude-dir=.git 2>/dev/null || true)

if [ "${#HIT_FILES[@]}" -eq 0 ]; then
  echo "regen-default-password-hash: no occurrences of the known old hash literal found (already fixed, or upstream hash drifted -- self-check below decides which)"
else
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

  echo "regen-default-password-hash: ${#HIT_FILES[@]} file(s) patched with the pinned hash of 'dozenos'"
fi

# ---------------------------------------------------------------------------
# Unconditional end-state self-check -- see the header comment above for the
# full rationale. Runs every time, whether or not the replace step above did
# anything, so upstream hash drift (a DIFFERENT hash than OLD_HASH landing
# in a known file) fails the sync instead of passing silently.
# ---------------------------------------------------------------------------
for rel in "${KNOWN_FILES[@]}"; do
  f="$TARGET/$rel"
  [ -f "$f" ] || die "missing expected target file: $rel"

  # Extract the `$6$...` candidate(s) actually present in this file. Same
  # literal token shape the replacement loop above operates on (delimited by
  # quotes/whitespace, never by regex metacharacters inside the hash).
  # Known files are expected to carry EXACTLY ONE such hash -- the
  # default-user's -- confirmed by the header comment's "All 5 files carry
  # the exact SAME hash string" diff. If a known file ever contains zero or
  # more than one `$6$` candidate, that is itself a drift signal (either the
  # default-user hash is missing, or upstream added a second unrelated hash
  # to a file this script must be precise about) -- die loudly rather than
  # silently guessing which one is "the" default-user hash.
  # shellcheck disable=SC2016 # literal `$6$` regex pattern, must NOT expand
  mapfile -t candidates < <(grep -ohE '\$6\$[^"'"'"' ]+' "$f" || true)
  case "${#candidates[@]}" in
    1) : ;;
    0) die "$rel: no \$6\$ default-user password hash found (expected exactly 1)" ;;
    *) die "$rel: found ${#candidates[@]} distinct \$6\$ hash candidates, expected exactly 1 -- cannot determine which is the default-user hash" ;;
  esac
  live_hash="${candidates[0]}"

  salt=$(printf '%s' "$live_hash" | awk -F'$' '{print $3}')
  [ -n "$salt" ] || die "$rel: could not parse salt out of live hash: $live_hash"

  check=$(openssl passwd -6 -salt "$salt" dozenos)
  if [ "$check" != "$live_hash" ]; then
    die "$rel: live default-user password hash does NOT authenticate 'dozenos' (found: $live_hash) -- upstream hash drift: OLD_HASH in this script is stale and must be re-verified against a fresh upstream clone"
  fi
done

echo "regen-default-password-hash: self-check passed -- all ${#KNOWN_FILES[@]} known files' default-user password hash authenticates 'dozenos'"
