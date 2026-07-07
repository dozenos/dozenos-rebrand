#!/usr/bin/env bash
#
# Integration test for wire-prebuild-hooks.sh.
#
# Self-contained: builds a synthetic scripts/package-build/ fixture covering
# every case the script must handle, then asserts the contract:
#
#   1. A [[packages]] block with no pre_build_hook gets the standard one
#      inserted directly after its scm_url line.
#   2. A block whose scm_url is the empty string still gets the hook (right
#      after that empty scm_url line).
#   3. A block that already declares ANY pre_build_hook (plain or a custom
#      multi-line one) is left byte-for-byte untouched -- never clobbered.
#   4. Multiple [[packages]] blocks in one file are handled independently;
#      a [dependencies] section does not get treated as a package block.
#   5. --check/--list reports without writing anything.
#   6. Running apply mode twice is idempotent (2nd run byte-identical).
#   7. A recipe dir on the script's exclusion list (currently just
#      "linux-kernel") is NEVER touched, even though its package.toml has a
#      block missing pre_build_hook -- neither flagged by --check nor written
#      by apply mode. Models the real linux-kernel recipe, whose build.py is
#      a bespoke driver that never reads pre_build_hook at all (see
#      wire-prebuild-hooks.sh's EXCLUDE_RECIPES comment).
#
# Usage:
#   test-wire-prebuild-hooks.sh
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/wire-prebuild-hooks.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

snapshot() {
  local t=$1
  ( cd "$t"
    find . -type f | LC_ALL=C sort | while IFS= read -r p; do
      printf 'F %s %s\n' "$p" "$(sha256sum < "$p" | cut -d' ' -f1)"
    done )
}

HOOK='pre_build_hook = "/dozenos-rebrand/rename-transform.sh ."'

make_fixture() {
  local pb=$1
  mkdir -p "$pb"/{needs-hook,empty-scm-url,already-plain,already-custom,multi-block,dependencies-boundary,linux-kernel}

  # 1) plain recipe, no pre_build_hook at all -- must gain one after scm_url
  cat > "$pb/needs-hook/package.toml" <<'EOF'
[[packages]]
name = "needs-hook"
commit_id = "rolling"
scm_url = "https://github.com/example/needs-hook.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF

  # 2) scm_url is the empty string (e.g. linux-kernel OOT modules) -- hook
  #    still goes right after that (empty) scm_url line
  cat > "$pb/empty-scm-url/package.toml" <<'EOF'
[[packages]]
name = "empty-scm-url"
commit_id = ""
scm_url = ""
build_cmd = "build_something"
EOF

  # 3a) already has the plain standard hook -- must be left untouched
  cat > "$pb/already-plain/package.toml" <<EOF
[[packages]]
name = "already-plain"
commit_id = "rolling"
scm_url = "https://github.com/example/already-plain.git"
$HOOK
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF

  # 3b) already has a CUSTOM (non-standard) hook -- must be left untouched,
  #     never clobbered with the standard one
  cat > "$pb/already-custom/package.toml" <<'EOF'
[[packages]]
name = "already-custom"
commit_id = "rolling"
scm_url = "https://github.com/example/already-custom.git"
pre_build_hook = "cd ..; ./prebuild.sh"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF

  # 4) multiple [[packages]] blocks: first needs the hook, second already
  #    has it -- must be handled independently, plus a [dependencies]
  #    section afterward must not be mistaken for a packages block
  cat > "$pb/multi-block/package.toml" <<EOF
[[packages]]
name = "multi-block-a"
commit_id = "rolling"
scm_url = "https://github.com/example/multi-block-a.git"
build_cmd = "true"

[[packages]]
name = "multi-block-b"
commit_id = "rolling"
scm_url = "https://github.com/example/multi-block-b.git"
$HOOK
build_cmd = "true"

[dependencies]
packages = ["libfoo-dev"]
EOF

  # 5) a [dependencies]-only boundary check with no build_cmd on the block
  #    needing the hook, so it must land at end-of-block (before the blank
  #    line + [dependencies])
  cat > "$pb/dependencies-boundary/package.toml" <<'EOF'
[[packages]]
name = "dependencies-boundary"
commit_id = "rolling"
scm_url = "https://github.com/example/dependencies-boundary.git"

[dependencies]
packages = ["libbar-dev"]
EOF

  # 6) linux-kernel: excluded-by-name recipe dir. Its package.toml has a
  #    block missing pre_build_hook (just like the real recipe's 16 blocks),
  #    and a bespoke (non-symlink) build.py standing in for the real
  #    linux-kernel/build.py driver that never reads pre_build_hook. Must be
  #    completely ignored by both --check and apply mode.
  cat > "$pb/linux-kernel/package.toml" <<'EOF'
[[packages]]
name = "linux-kernel"
commit_id = ""
scm_url = ""
build_cmd = "build_kernel"
EOF
  cat > "$pb/linux-kernel/build.py" <<'EOF'
#!/usr/bin/env python3
# bespoke driver stand-in: does not read pre_build_hook
EOF
}

PB="$WORK/scripts-package-build"
make_fixture "$PB"
snap_fixture=$(snapshot "$PB")
hash_already_plain_before=$(sha256sum < "$PB/already-plain/package.toml")
hash_already_custom_before=$(sha256sum < "$PB/already-custom/package.toml")

# ---------------------------------------------------------------------------
# --check / --list: must report, must NOT write.
# ---------------------------------------------------------------------------
echo "== --check mode =="
check_out=$("$SCRIPT" --check "$PB" 2>&1)
snap_after_check=$(snapshot "$PB")
if [ "$snap_fixture" = "$snap_after_check" ]; then
  ok "--check does not modify the tree"
else
  bad "--check modified the tree"
fi
if printf '%s' "$check_out" | grep -q '^check: .* recipe(s) / .* block(s) would receive pre_build_hook$'; then
  ok "--check reports a would-change summary"
else
  bad "--check summary line missing/unexpected: $check_out"
fi
for name in needs-hook empty-scm-url multi-block dependencies-boundary; do
  if printf '%s' "$check_out" | grep -q "^$name "; then
    ok "--check flags '$name' as needing the hook"
  else
    bad "--check did not flag '$name'"
  fi
done
for name in already-plain already-custom; do
  if printf '%s' "$check_out" | grep -q "^$name "; then
    bad "--check incorrectly flagged '$name' (already has a hook)"
  else
    ok "--check correctly skips '$name' (already has a hook)"
  fi
done
if printf '%s' "$check_out" | grep -q "^linux-kernel "; then
  bad "--check incorrectly flagged excluded recipe 'linux-kernel'"
else
  ok "--check correctly skips excluded recipe 'linux-kernel' (missing hook, but excluded)"
fi

# ---------------------------------------------------------------------------
# Apply mode: run once, assert placement + no-clobber, then run twice more
# to prove idempotency.
# ---------------------------------------------------------------------------
echo "== apply mode: run 1 =="
"$SCRIPT" "$PB" >/dev/null

# (1) needs-hook: hook lands right after scm_url, before build_cmd
if diff -q - "$PB/needs-hook/package.toml" >/dev/null <<EOF
[[packages]]
name = "needs-hook"
commit_id = "rolling"
scm_url = "https://github.com/example/needs-hook.git"
$HOOK
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF
then ok "needs-hook: hook inserted right after scm_url"
else bad "needs-hook: unexpected content"; cat "$PB/needs-hook/package.toml"
fi

# (2) empty-scm-url: hook still lands after the empty scm_url line
if diff -q - "$PB/empty-scm-url/package.toml" >/dev/null <<EOF
[[packages]]
name = "empty-scm-url"
commit_id = ""
scm_url = ""
$HOOK
build_cmd = "build_something"
EOF
then ok "empty-scm-url: hook inserted after empty scm_url"
else bad "empty-scm-url: unexpected content"; cat "$PB/empty-scm-url/package.toml"
fi

# (3) already-plain / already-custom: byte-identical to before (no clobber)
if [ "$hash_already_plain_before" = "$(sha256sum < "$PB/already-plain/package.toml")" ]; then
  ok "already-plain: untouched (not clobbered)"
else
  bad "already-plain: was modified"; cat "$PB/already-plain/package.toml"
fi
if [ "$hash_already_custom_before" = "$(sha256sum < "$PB/already-custom/package.toml")" ]; then
  ok "already-custom: untouched (not clobbered)"
else
  bad "already-custom: was modified"; cat "$PB/already-custom/package.toml"
fi

# (4) multi-block: block a gets the hook, block b (already has it) untouched,
#     [dependencies] section still intact and not treated as a package block
if grep -q "$HOOK" "$PB/multi-block/package.toml" \
   && [ "$(grep -c "$HOOK" "$PB/multi-block/package.toml")" -eq 2 ] \
   && grep -q '^\[dependencies\]$' "$PB/multi-block/package.toml" \
   && grep -q 'libfoo-dev' "$PB/multi-block/package.toml"
then ok "multi-block: each block handled independently, [dependencies] preserved"
else bad "multi-block: unexpected content"; cat "$PB/multi-block/package.toml"
fi

# (5) dependencies-boundary: hook appended at end of block, before the blank
#     line + [dependencies] section (not merged into it)
if diff -q - "$PB/dependencies-boundary/package.toml" >/dev/null <<EOF
[[packages]]
name = "dependencies-boundary"
commit_id = "rolling"
scm_url = "https://github.com/example/dependencies-boundary.git"
$HOOK

[dependencies]
packages = ["libbar-dev"]
EOF
then ok "dependencies-boundary: hook placed at end of block, section preserved"
else bad "dependencies-boundary: unexpected content"; cat "$PB/dependencies-boundary/package.toml"
fi

# (6) linux-kernel: excluded recipe must be left completely untouched by
#     apply mode too, despite its block missing pre_build_hook
if diff -q - "$PB/linux-kernel/package.toml" >/dev/null <<'EOF'
[[packages]]
name = "linux-kernel"
commit_id = ""
scm_url = ""
build_cmd = "build_kernel"
EOF
then ok "linux-kernel: excluded recipe untouched by apply mode"
else bad "linux-kernel: excluded recipe was modified"; cat "$PB/linux-kernel/package.toml"
fi

snap1=$(snapshot "$PB")

echo "== apply mode: run 2 (idempotency) =="
"$SCRIPT" "$PB" >/dev/null
snap2=$(snapshot "$PB")
if [ "$snap1" = "$snap2" ]; then
  ok "idempotent (2nd apply run byte-identical)"
else
  bad "NOT idempotent (2nd apply run differs)"
  diff <(printf '%s\n' "$snap1") <(printf '%s\n' "$snap2") | head
fi

check_out2=$("$SCRIPT" --check "$PB" 2>&1)
if printf '%s' "$check_out2" | grep -q 'no changes needed'; then
  ok "--check reports no changes needed once fully wired"
else
  bad "--check unexpectedly still reports changes: $check_out2"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
