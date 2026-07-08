#!/usr/bin/env bash
#
# Integration test for overlay-dozenos-1x/apply-overlay.sh (the dozenos-1x
# per-repo overlay, audit item #8/#23: the default-login password hash
# value-not-string fix).
#
# Self-contained and NETWORK-FREE (beyond `openssl passwd -6`, which is
# local-only, no network I/O): builds a synthetic target tree carrying the
# exact inherited VyOS default-login hash in all 5 known locations, plus a
# decoy file with an UNRELATED `$6$` hash that must never be touched, then
# asserts:
#
#   1. The old hash (`$6$QxPS.uk6mfo$...`) is removed from all 5 known
#      files.
#   2. Every patched file ends up with the SAME new hash (one regeneration,
#      applied everywhere).
#   3. The new hash validates the password `dozenos` and rejects `vyos`
#      (checked via `openssl passwd -6 -salt <extracted-salt>`, since
#      Python's `crypt` module is no longer available on modern
#      interpreters).
#   4. An unrelated `$6$` hash elsewhere in the tree is left byte-for-byte
#      untouched (confirms the full-hash-string match key, not just the
#      `$6$` id).
#   5. A second run is a clean idempotent no-op (byte-identical tree,
#      exit 0, "already fixed" message).
#   6. Bad usage (missing target, nonexistent target) fails loudly.
#   7. value-fixes/pin-vyatta-cfg-qos-doc-ref.sh (REPOINT-AUDIT.md #6 finding):
#      the dangling github.com/dozenos/vyatta-cfg-qos doc-comment ref is
#      reverted to the real, existing (archived) github.com/vyos/vyatta-cfg-qos.
#   8. Fail-closed on upstream hash drift: if a known file carries a
#      DIFFERENT hash than the hardcoded OLD_HASH literal (upstream
#      re-salted/reformatted it) that does NOT authenticate `dozenos`, the
#      overlay must fail loudly instead of silently no-op'ing, even when the
#      other known files still match OLD_HASH and get patched normally.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/overlay-dozenos-1x/apply-overlay.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

OLD_HASH='$6$QxPS.uk6mfo$9QBSo8u1FkH16gMyAVhus6fU3LOzvLR9Z9.82m3tiHFAxTtIkhaZSWssSgzt4v4dGAL8rhVQxTg0oAG9/q11h/'
UNRELATED_HASH='$6$unrelatedsalt$notTheVyOSHashAtAll1234567890abcdefghijklmnopqrstuvwxyzABCDEFG.'

snapshot() {
  ( cd "$1" && find . -type f -not -path './.git/*' | LC_ALL=C sort | xargs sha256sum )
}

# ---------------------------------------------------------------------------
# Fixture: the 5 known files carrying the exact old hash (mirroring their
# real repo-relative paths and surrounding syntax), plus a decoy file with
# an unrelated $6$ hash.
# ---------------------------------------------------------------------------
make_fixture() {
  local t="$1"
  mkdir -p "$t"/data "$t"/tests/data "$t"/src/tests \
           "$t"/smoketest/configs/assert "$t"/decoy "$t"/python/dozenos/qos

  cat > "$t/data/config.boot.default" <<EOF
system {
    login {
        user dozenos {
            authentication {
                encrypted-password "$OLD_HASH"
            }
        }
    }
}
EOF

  cat > "$t/tests/data/config.boot.default" <<EOF
system {
    login {
        user dozenos {
            authentication {
                encrypted-password $OLD_HASH
            }
        }
    }
}
EOF

  cat > "$t/src/tests/test_initial_setup.py" <<EOF
class TestInitialSetup(TestCase):
    def test_password_changed(self):
        old_pw = '$OLD_HASH'
        new_pw = get_config_value('system login user dozenos authentication encrypted-password')
        self.assertNotEqual(old_pw, new_pw)
EOF

  cat > "$t/smoketest/configs/firewall-groups-name" <<EOF
system {
    login {
        user dozenos {
            authentication {
                encrypted-password $OLD_HASH
            }
        }
    }
}
EOF

  cat > "$t/smoketest/configs/assert/firewall-groups-name" <<EOF
set system login user dozenos authentication encrypted-password '$OLD_HASH'
EOF

  # Decoy: an unrelated $6$ hash that must survive untouched.
  cat > "$t/decoy/unrelated-hash.txt" <<EOF
some_other_credential encrypted-password $UNRELATED_HASH
EOF

  # value-fixes/pin-nonmirrored-org-refs.sh targets: the post-transform
  # (dozenos-form) refs, as rename-transform.sh's four-form pass actually
  # produces them on a fresh clone.
  cat > "$t/python/dozenos/qos/base.py" <<'EOF'
class Qos:
    def _build_base_qdisc(self, config, cls_id):
        """
        This matches the old mapping as defined in Perl here:
        https://github.com/dozenos/vyatta-cfg-qos/blob/equuleus/lib/Vyatta/Qos/ShaperClass.pm#L223-L229
        """
        pass
EOF
  printf '# https://github.com/dozenos/coderabbit/blob/production/.coderabbit.yaml\ninheritance: true\n' > "$t/.coderabbit.yaml"

  # libdozenosconfig/Makefile with opam pins to a specific (fake) upstream sha
  # -- pin-opam-ocaml-branch.sh must re-pin both to #rolling (the sha does not
  # exist in the snapshot mirror). Names/hosts are already in dozenos form (as
  # rename-transform would leave them); only the #<sha> fragment is the fix.
  mkdir -p "$t/libdozenosconfig"
  cat > "$t/libdozenosconfig/Makefile" <<'EOF'
PACKAGES=dozenos1x-config,vyconf.vyconfd-config
depends:
	sudo sh -c 'eval $$(opam env --root=/opt/opam --set-root) ;\
		opam pin add dozenos1x-config https://github.com/dozenos/dozenos1x-config.git#0123456789abcdef0123456789abcdef01234567 -y ; \
		opam pin add vyconf https://github.com/dozenos/vyconf.git#89abcdef0123456789abcdef0123456789abcdef -y'
EOF
}

# ---------------------------------------------------------------------------
# Run 1: apply against the fixture.
# ---------------------------------------------------------------------------
echo "== apply-overlay-dozenos-1x: first run =="
TREE="$WORK/tree"
make_fixture "$TREE"

if OUT1=$("$SCRIPT" "$TREE" 2>&1); then
  ok "first run exits 0"
else
  bad "first run exited non-zero"; printf '%s\n' "$OUT1"
fi

# 1. old hash gone from all 5 known files.
if grep -rlF "$OLD_HASH" "$TREE" >/dev/null 2>&1; then
  bad "old hash still present somewhere after first run"
  grep -rlF "$OLD_HASH" "$TREE"
else
  ok "old hash removed from every known file"
fi

# 2. every patched file has the SAME new hash.
hashes=$(grep -ohE '\$6\$[^"'"'"' ]+' \
  "$TREE/data/config.boot.default" \
  "$TREE/tests/data/config.boot.default" \
  "$TREE/src/tests/test_initial_setup.py" \
  "$TREE/smoketest/configs/firewall-groups-name" \
  "$TREE/smoketest/configs/assert/firewall-groups-name" | LC_ALL=C sort -u)
n_distinct=$(printf '%s\n' "$hashes" | grep -c . || true)
if [ "$n_distinct" -eq 1 ]; then
  ok "all 5 files carry the same single new hash"
else
  bad "expected exactly 1 distinct new hash across the 5 files, found $n_distinct"
  printf '%s\n' "$hashes"
fi
NEW_HASH=$(printf '%s\n' "$hashes" | head -1)

# 3. new hash validates 'dozenos' and rejects 'vyos' (via openssl, since
#    python3's crypt module is gone on modern interpreters).
if [ -n "$NEW_HASH" ]; then
  SALT=$(printf '%s' "$NEW_HASH" | awk -F'$' '{print $3}')
  CHECK_DOZENOS=$(openssl passwd -6 -salt "$SALT" "dozenos")
  CHECK_VYOS=$(openssl passwd -6 -salt "$SALT" "vyos")
  if [ "$CHECK_DOZENOS" = "$NEW_HASH" ]; then
    ok "new hash validates password 'dozenos'"
  else
    bad "new hash does NOT validate password 'dozenos'"
  fi
  if [ "$CHECK_VYOS" != "$NEW_HASH" ]; then
    ok "new hash correctly rejects password 'vyos'"
  else
    bad "new hash unexpectedly still validates 'vyos'"
  fi
else
  bad "no new hash found to validate"
fi

# 4. unrelated $6$ hash untouched.
if grep -qF "$UNRELATED_HASH" "$TREE/decoy/unrelated-hash.txt"; then
  ok "unrelated \$6\$ hash left untouched"
else
  bad "unrelated \$6\$ hash was modified (overlay is not scoped to the exact old-hash string)"
fi

# 5. pin-nonmirrored-org-refs.sh: dangling github.com/dozenos/vyatta-cfg-qos
#    doc-comment ref reverted to the real (archived but existing)
#    github.com/vyos/vyatta-cfg-qos.
if grep -qF 'github.com/vyos/vyatta-cfg-qos' "$TREE/python/dozenos/qos/base.py" \
   && ! grep -qF 'github.com/dozenos/vyatta-cfg-qos' "$TREE/python/dozenos/qos/base.py"; then
  ok "vyatta-cfg-qos doc-comment ref reverted to github.com/vyos/* (REPOINT-AUDIT.md #6)"
else
  bad "vyatta-cfg-qos doc-comment ref not reverted"; cat "$TREE/python/dozenos/qos/base.py"
fi

# 6. pin-nonmirrored-org-refs.sh: dangling github.com/dozenos/coderabbit
#    org-baseline-config ref reverted to the real github.com/vyos/coderabbit.
if grep -qF 'github.com/vyos/coderabbit' "$TREE/.coderabbit.yaml" \
   && ! grep -qF 'github.com/dozenos/coderabbit' "$TREE/.coderabbit.yaml"; then
  ok ".coderabbit.yaml dangling dozenos/coderabbit ref reverted (REPOINT-AUDIT.md #6)"
else
  bad ".coderabbit.yaml ref not reverted"; cat "$TREE/.coderabbit.yaml"
fi

# 7. pin-opam-ocaml-branch.sh: opam pins re-pinned from the (fake) upstream
#    sha to the #rolling branch (the sha does not exist in the snapshot mirror).
if grep -qF 'dozenos1x-config.git#rolling' "$TREE/libdozenosconfig/Makefile" \
   && grep -qF 'vyconf.git#rolling' "$TREE/libdozenosconfig/Makefile" \
   && ! grep -qE '\.git#[0-9a-f]{7,40}' "$TREE/libdozenosconfig/Makefile"; then
  ok "opam pins re-pinned to #rolling (no leftover #<sha>)"
else
  bad "opam pins not re-pinned to #rolling"; cat "$TREE/libdozenosconfig/Makefile"
fi

# ---------------------------------------------------------------------------
# Run 2: idempotency.
# ---------------------------------------------------------------------------
echo "== apply-overlay-dozenos-1x: second run (idempotency) =="
snap1=$(snapshot "$TREE")
if OUT2=$("$SCRIPT" "$TREE" 2>&1); then
  ok "second run exits 0"
else
  bad "second run exited non-zero"; printf '%s\n' "$OUT2"
fi
snap2=$(snapshot "$TREE")
if [ "$snap1" = "$snap2" ]; then
  ok "second run is byte-identical (idempotent no-op)"
else
  bad "second run changed the tree"
  diff <(printf '%s\n' "$snap1") <(printf '%s\n' "$snap2") | head
fi
if printf '%s' "$OUT2" | grep -qi 'already fixed'; then
  ok "second run reports the no-op state"
else
  bad "second run did not report a no-op state"; printf '%s\n' "$OUT2"
fi

# ---------------------------------------------------------------------------
# Run 2.5: fail-closed on upstream hash drift.
#
# The confirmed defect this guards against: the replace loop's ONLY trigger
# is a literal grep for the hardcoded OLD_HASH string. If upstream ever
# ships a DIFFERENT hash in a known file -- e.g. a re-salted/reformatted
# hash that still authenticates the OLD plaintext `vyos` -- the literal grep
# simply does not see it, so (pre-fix) the script silently treated that file
# as "nothing to do" and exited 0, shipping a stale/wrong password hash.
# Seed ONE known file with such a drifted hash (a real, validly-formed
# `$6$` hash -- NOT the hardcoded OLD_HASH literal -- that still
# authenticates `vyos`) while leaving the other 4 known files carrying the
# real OLD_HASH, so the replace loop still has (partial) work to do and
# would, pre-fix, patch the other 4 and silently leave the drifted one
# untouched. Assert the overlay now fails closed (non-zero exit) instead.
# ---------------------------------------------------------------------------
echo "== apply-overlay-dozenos-1x: fail-closed on upstream hash drift =="
DRIFT_TREE="$WORK/drift-tree"
make_fixture "$DRIFT_TREE"

# A validly-formed SHA-512 crypt hash that is NOT the hardcoded OLD_HASH
# literal, and that still authenticates the OLD plaintext 'vyos' -- the
# realistic "upstream re-salted/reformatted the same old password" drift
# case regen-default-password-hash.sh's literal-string match cannot see.
DRIFTED_VYOS_HASH=$(openssl passwd -6 -salt driftedsalt1 vyos)
python3 - "$DRIFT_TREE/data/config.boot.default" "$OLD_HASH" "$DRIFTED_VYOS_HASH" <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()
data = data.replace(old, new)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(data)
PY

if OUT_DRIFT=$("$SCRIPT" "$DRIFT_TREE" 2>&1); then
  bad "drifted hash: expected non-zero exit (fail-closed), got 0"
  printf '%s\n' "$OUT_DRIFT"
else
  ok "drifted hash: exits non-zero (fail-closed) instead of a silent no-op"
fi
if printf '%s' "$OUT_DRIFT" | grep -qi 'drift'; then
  ok "drifted hash: failure message identifies upstream hash drift"
else
  bad "drifted hash: failure message does not mention drift"; printf '%s\n' "$OUT_DRIFT"
fi
if printf '%s' "$OUT_DRIFT" | grep -qF 'data/config.boot.default'; then
  ok "drifted hash: failure message names the offending file"
else
  bad "drifted hash: failure message does not name the offending file"; printf '%s\n' "$OUT_DRIFT"
fi

# The other 4 known files (still carrying the real OLD_HASH) must NOT have
# been silently patched-and-declared-done while the drifted file was
# ignored -- i.e. the self-check must run (and fail) regardless of the
# replace loop's partial progress on the rest of the tree.
if grep -qF "$DRIFTED_VYOS_HASH" "$DRIFT_TREE/data/config.boot.default"; then
  ok "drifted hash: offending file's drifted hash is still visible for post-mortem (script did not silently overwrite then pass)"
else
  bad "drifted hash: offending file was modified despite the run failing"
fi

# ---------------------------------------------------------------------------
# Run 3: bad usage.
# ---------------------------------------------------------------------------
echo "== bad usage =="
if "$SCRIPT" >/dev/null 2>&1; then
  bad "missing target: expected non-zero exit"
else
  ok "missing target: exits non-zero"
fi
if "$SCRIPT" "$WORK/does-not-exist" >/dev/null 2>&1; then
  bad "nonexistent target: expected non-zero exit"
else
  ok "nonexistent target: exits non-zero"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
