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

  # Copyright-notice preservation: line 1 is a legal notice
  # (COPYRIGHT_LINE_GUARD -> preserved verbatim, email included); line 2 is
  # ordinary content (four-form applies).
  printf '# Copyright (C) VyOS Inc. <maintainers@vyos.io>\n# maintained by the VyOS team\n' > "$t/src/legal-header.py"

  # Lowercase `copyright` is NOT a legal notice: upstream vyos-1x's Makefile
  # has a `copyright` lint target on the same line as `libvyosconfig`
  # dependencies -- that line MUST still transform (2026-07-11 regression).
  printf 'all: clean copyright libvyosconfig\n\n.PHONY: copyright\ncopyright:\n\ttrue\n\nlibvyosconfig:\n\tmake -C libvyosconfig all\n' > "$t/src/lint-target-makefile"

  # Copyright INSIDE a string literal must NOT attract a marker: an OCaml
  # string concatenation broke with a syntax error when the marker landed
  # inside it (2026-07-11 regression, vyconf src/version.ml).
  printf 'let banner =\n  "Copyright 2017 VyOS maintainers and contributors\\n" ^\n  "free software"\nlet m = Vyos_config.load\n' > "$t/src/string-literal.ml"

  # A YAML list item starting with "- Copyright" is data, not a comment --
  # single "-" is not a recognised comment leader.
  printf 'notices:\n  - Copyright 2020 VyOS maintainers\n  - vyos extra\n' > "$t/src/data-list.yaml"

  # debian/copyright: whole file preserved byte-identical (PRESERVE_FILES),
  # including non-`Copyright:` lines carrying vyos URLs/emails.
  printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\nSource: https://github.com/vyos/vyos-1x\nUpstream-Contact: VyOS maintainers <maintainers@vyos.net>\n\nFiles: *\nCopyright: VyOS Networks\nLicense: GPL-2+\n' > "$t/debian/copyright"

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

  # (1) zero vyos, case-insensitive, excluding .git; copyright-notice lines
  # exempt (preserved by design -- COPYRIGHT_LINE_GUARD, same content-level
  # exemption rename-transform.sh's own verify_list applies)
  local n
  n=$({ grep -rIni vyos "$tree" --exclude-dir=.git || true; } \
      | awk -F: '{ if ($1 ~ /(^|\/)debian\/copyright$/) next;
                   s=""; for (i=3; i<=NF; i++) s=s (i>3?":":"") $i;
                   if (s ~ /Copyright|COPYRIGHT|©/) next; print }' \
      | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then ok "grep -rIi vyos == 0 (copyright lines exempt)"; else
    bad "grep -rIi vyos == $n (expected 0, copyright lines exempt)"
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

  # (3b) copyright notice preserved verbatim; non-copyright lines transformed;
  # modification marker inserted exactly once after the notice
  if [ -f "$tree/src/legal-header.py" ]; then
    if grep -qF 'Copyright (C) VyOS Inc. <maintainers@vyos.io>' "$tree/src/legal-header.py" \
       && grep -q 'maintained by the DozenOS team' "$tree/src/legal-header.py"; then
      ok "copyright line preserved verbatim; non-copyright line transformed"
    else
      bad "copyright preservation mismatch"
      cat "$tree/src/legal-header.py"
    fi
    n_marker=$(grep -cF 'Modifications Copyright DozenOS Contributors. See git history for details.' "$tree/src/legal-header.py")
    if [ "$n_marker" -eq 1 ] \
       && sed -n 2p "$tree/src/legal-header.py" | grep -qF '# Modifications Copyright DozenOS Contributors.'; then
      ok "modification marker inserted once, directly after the notice"
    else
      bad "modification marker count/position wrong (count=$n_marker)"
      cat "$tree/src/legal-header.py"
    fi
  fi

  # (3c2) debian/copyright preserved whole (PRESERVE_FILES), including
  # non-Copyright lines with vyos URLs/emails
  if [ -f "$tree/debian/copyright" ]; then
    if grep -qF 'Source: https://github.com/vyos/vyos-1x' "$tree/debian/copyright" \
       && grep -qF 'Upstream-Contact: VyOS maintainers <maintainers@vyos.net>' "$tree/debian/copyright"; then
      ok "debian/copyright preserved byte-identical (PRESERVE_FILES)"
    else
      bad "debian/copyright was transformed"
      cat "$tree/debian/copyright"
    fi
  fi

  # (3c3) no marker inside string literals or data lists
  if [ -f "$tree/src/string-literal.ml" ]; then
    if ! grep -q 'Modifications Copyright' "$tree/src/string-literal.ml" \
       && ! grep -q 'Modifications Copyright' "$tree/src/data-list.yaml" \
       && grep -q 'Dozenos_config.load' "$tree/src/string-literal.ml"; then
      ok "no marker in string literals / data lists (non-comment leaders skipped)"
    else
      bad "marker leaked into a non-comment context"
      grep -n 'Modifications' "$tree/src/string-literal.ml" "$tree/src/data-list.yaml"
    fi
  fi

  # (3c) lowercase `copyright` lint-target line still transforms
  if [ -f "$tree/src/lint-target-makefile" ]; then
    if grep -qF 'all: clean copyright libdozenosconfig' "$tree/src/lint-target-makefile" \
       && ! grep -q 'libvyosconfig' "$tree/src/lint-target-makefile"; then
      ok "lowercase copyright lint-target line transformed (guard is case-sensitive)"
    else
      bad "lowercase copyright line was wrongly preserved"
      cat "$tree/src/lint-target-makefile"
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
# mtimes must survive a no-op pass too: `sed -i` rewrites unconditionally,
# and a stat-dirtied tree fails cloud-init's `git diff-index HEAD` check
# (2026-07-11 regression -- files with preserved-copyright vyos lines).
mtimes1=$(find "$TREE" -type f -not -path '*/.git/*' -printf '%p %T@\n' | LC_ALL=C sort)
"$SCRIPT" "$TREE"
snap2=$(snapshot "$TREE")
mtimes2=$(find "$TREE" -type f -not -path '*/.git/*' -printf '%p %T@\n' | LC_ALL=C sort)
if [ "$snap1" = "$snap2" ]; then
  ok "idempotent (2nd run byte-identical)"
else
  bad "NOT idempotent (2nd run differs)"
  diff <(printf '%s\n' "$snap1") <(printf '%s\n' "$snap2") | head
fi
if [ "$mtimes1" = "$mtimes2" ]; then
  ok "no-op pass leaves mtimes untouched (stat-idempotent)"
else
  bad "no-op pass rewrote unchanged files (mtime drift)"
  diff <(printf '%s\n' "$mtimes1") <(printf '%s\n' "$mtimes2") | head
fi
run_asserts "$TREE" "after 2nd run"

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
