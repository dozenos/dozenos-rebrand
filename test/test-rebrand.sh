#!/usr/bin/env bash
#
# Integration test for rename-transform.sh (VyOS -> DozenOS rebrand toolkit).
#
# Self-contained: builds a synthetic fixture that encodes every landmine from
# REBRAND-PLAN.md Appendix C, then asserts the toolkit's contract:
#
#   1. After one run, `grep -rIi vyos` over the tree returns ZERO lines.
#   2. `vyatta` (all case forms) is preserved untouched.
#   3. Running the script a SECOND time leaves the tree BYTE-IDENTICAL
#      (idempotency) and grep is still zero.
#   4. Binary files are skipped, symlink targets are rewritten, and both file
#      contents and file/dir NAMES are transformed.
#
# Usage:
#   test-rebrand.sh                 # run against the built-in synthetic fixture
#   test-rebrand.sh /path/to/tree   # run against a real cloned tree (e.g. vyos-1x)
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself, so a failing
# assertion must not abort the whole run. Script invocations are checked
# explicitly.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/rename-transform.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------
# Snapshot: stable representation of a tree's *content* (ignores mtimes) so we
# can prove idempotency (run twice -> byte-identical).
# ---------------------------------------------------------------------------
snapshot() {
  local t=$1
  ( cd "$t"
    find . -not -path './.git/*' -not -name .git | LC_ALL=C sort | while IFS= read -r p; do
      if   [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
      elif [ -f "$p" ]; then printf 'F %s %s\n' "$p" "$(sha256sum < "$p" | cut -d' ' -f1)"
      elif [ -d "$p" ]; then printf 'D %s\n' "$p"
      fi
    done )
}

# ---------------------------------------------------------------------------
# Synthetic fixture: one representative of every careful case.
# ---------------------------------------------------------------------------
make_fixture() {
  local t=$1
  mkdir -p "$t"/{debian,usr/share/vyos,src/systemd,scripts,etc,python/vyos,src/etc/ppp/ip-up.d,src/etc/ppp/ipv6-up.d}

  # debian/control -- package-name coupling (C1)
  cat > "$t/debian/control" <<'EOF'
Source: vyos-1x
Package: vyos-1x
Pre-Depends: vyos-libpam-radius-auth, vyos-libnss-mapuser
Depends: libvyosconfig0, vyos-http-api-tools
Provides: vyos-user-utils
Maintainer: VyOS Maintainers <maintainers@vyos.net>

Package: libvyosconfig0
Depends: ${shlibs:Depends}
EOF

  # debian/changelog -- source token + version history
  cat > "$t/debian/changelog" <<'EOF'
vyos-1x (999.0) unstable; urgency=medium

  * Rebuild against VyOS rolling.

 -- VyOS Maintainers <maintainers@vyos.net>  Mon, 07 Jul 2026 00:00:00 +0000
EOF

  # debian/*.install / soname
  printf 'usr/lib/libvyosconfig0.so.0\n' > "$t/debian/libvyosconfig0.install"

  # Python namespace
  printf 'import vyos\nfrom vyos.config import Config\nx = vyos.defaults.X\n' > "$t/python/vyos/config.py"

  # Corporate-entity phrase (PHRASE_REWRITES: "VyOS Inc." -> "DozenOS Org.")
  printf '# Copyright (C) VyOS Inc.\n# maintained by the VyOS team\n' > "$t/src/copyright-header.py"

  # systemd service (name + content)
  printf '[Unit]\nDescription=VyOS router\n[Service]\nExecStart=/usr/libexec/vyos/init\n' \
    > "$t/src/systemd/vyos-router.service"

  # kernel_flavor landmine (defaults.toml style)
  printf 'kernel_flavor = "vyos"\nvyos_mirror = "https://packages.vyos.net/repositories/rolling"\n' \
    > "$t/data-defaults.toml"
  mkdir -p "$t/$(dirname data-defaults.toml)" 2>/dev/null || true

  # ISO volid + shell var-name landmines
  printf "VOLID='VYOSNESTED'\nVYOS_FIRMWARE_NAME=\"vyos-linux-firmware\"\nVYOS_FIRMWARE_DIR=\"\$VYOS_FIRMWARE_NAME\"\n" \
    > "$t/scripts/build-firmware.sh"

  # 'Vyos' (rare fourth form) landmine
  printf '# Vyos config\n' > "$t/etc/dh895xcc_dev0.conf"

  # hardcoded paths -- vyos ones change, /opt/vyatta MUST be preserved
  cat > "$t/scripts/paths.sh" <<'EOF'
D1=/usr/libexec/vyos
D2=/usr/share/vyos
D3=/run/vyos
D4=/etc/vyos
D5=/var/log/vyos
KEEP1=/opt/vyatta/bin
KEEP2=/opt/vyatta/sbin
EOF

  # vyatta content that must survive (all three forms)
  printf 'vyatta config\nVyatta Legacy\nVYATTA_DIR=/opt/vyatta\n' > "$t/etc/vyatta-notes.txt"

  # a file inside a vyos-named dir (dir rename + nested)
  printf 'share data for vyos\n' > "$t/usr/share/vyos/version"

  # binary file that happens to contain the bytes "vyos" -- must be skipped
  printf 'PNG\x00\x01vyos\x00\xff\xfe' > "$t/usr/share/vyos/logo.bin"

  # symlink whose TARGET contains vyos (grep won't catch a broken target)
  printf '#!/bin/sh\necho pppoe\n' > "$t/src/etc/ppp/ip-up.d/99-vyos-pppoe-callback"
  ln -s ../ip-up.d/99-vyos-pppoe-callback "$t/src/etc/ppp/ipv6-up.d/99-vyos-pppoe-callback"
}

run_asserts() {
  local tree=$1 label=$2

  echo "== $label =="

  # (1) zero vyos, case-insensitive, excluding .git
  local n
  n=$({ grep -rIi vyos "$tree" --exclude-dir=.git || true; } | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then ok "grep -rIi vyos == 0"; else
    bad "grep -rIi vyos == $n (expected 0)"
    grep -rIn vyos "$tree" --exclude-dir=.git | head
  fi

  # (1b) the script's own --verify agrees and exits 0 on a clean tree
  if "$SCRIPT" "$tree" --verify >/dev/null 2>&1; then
    ok "--verify exits 0 on clean tree"
  else
    bad "--verify did not exit 0 on a clean tree"
  fi

  # (2) vyatta preserved (fixture only; real trees checked separately)
  if [ -f "$tree/etc/vyatta-notes.txt" ]; then
    if grep -q 'VYATTA_DIR=/opt/vyatta' "$tree/etc/vyatta-notes.txt" \
       && grep -q '/opt/vyatta/bin' "$tree/scripts/paths.sh"; then
      ok "vyatta / /opt/vyatta preserved"
    else
      bad "vyatta or /opt/vyatta was corrupted"
    fi
  fi

  # (3) names transformed
  if [ -f "$tree/debian/libdozenosconfig0.install" ] \
     && [ -d "$tree/usr/share/dozenos" ] \
     && [ -f "$tree/src/systemd/dozenos-router.service" ]; then
    ok "file & directory names transformed"
  elif [ -f "$tree/etc/vyatta-notes.txt" ]; then
    bad "expected renamed paths missing (libdozenosconfig0.install / usr/share/dozenos / dozenos-router.service)"
  fi

  # (3b) corporate-entity phrase rewritten, not four-formed
  if [ -f "$tree/src/copyright-header.py" ]; then
    if grep -q 'Copyright (C) DozenOS Org\.' "$tree/src/copyright-header.py" \
       && ! grep -q 'DozenOS Inc\.' "$tree/src/copyright-header.py" \
       && grep -q 'maintained by the DozenOS team' "$tree/src/copyright-header.py"; then
      ok "\"VyOS Inc.\" -> \"DozenOS Org.\" (PHRASE_REWRITES)"
    else
      bad "\"VyOS Inc.\" was not rewritten to \"DozenOS Org.\""
      cat "$tree/src/copyright-header.py"
    fi
  fi

  # (4) binary skipped -- logo.bin still has raw 'vyos' bytes untouched
  if [ -f "$tree/usr/share/dozenos/logo.bin" ]; then
    if grep -qa 'vyos' "$tree/usr/share/dozenos/logo.bin"; then
      ok "binary file skipped (raw bytes intact)"
    else
      bad "binary file was modified"
    fi
  fi

  # (5) symlink target rewritten
  if [ -L "$tree/src/etc/ppp/ipv6-up.d/99-dozenos-pppoe-callback" ]; then
    local tgt
    tgt=$(readlink "$tree/src/etc/ppp/ipv6-up.d/99-dozenos-pppoe-callback")
    if [ "$tgt" = "../ip-up.d/99-dozenos-pppoe-callback" ] \
       && [ -e "$tree/src/etc/ppp/ipv6-up.d/99-dozenos-pppoe-callback" ]; then
      ok "symlink name + target rewritten and resolves"
    else
      bad "symlink target not rewritten (points to $tgt)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Drive the test
# ---------------------------------------------------------------------------
SRC="${1:-}"
TREE="$WORK/tree"

if [ -n "$SRC" ]; then
  echo "Fixture: copy of $SRC"
  cp -a "$SRC" "$TREE"
else
  echo "Fixture: built-in synthetic landmine tree"
  make_fixture "$TREE"
fi

# raw counts for the report
before=$(grep -rIi vyos "$TREE" --exclude-dir=.git | wc -l | tr -d ' ')
echo "vyos occurrences BEFORE: $before"

# --- run once ---
"$SCRIPT" "$TREE"
snap1=$(snapshot "$TREE")
run_asserts "$TREE" "after 1st run"

# --- run twice (idempotency) ---
"$SCRIPT" "$TREE"
snap2=$(snapshot "$TREE")
if [ "$snap1" = "$snap2" ]; then
  ok "idempotent (2nd run byte-identical)"
else
  bad "NOT idempotent (2nd run differs)"
  diff <(printf '%s\n' "$snap1") <(printf '%s\n' "$snap2") | head
fi
run_asserts "$TREE" "after 2nd run"

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
