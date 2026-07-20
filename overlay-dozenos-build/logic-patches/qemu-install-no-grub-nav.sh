#!/usr/bin/env bash
#
# qemu-install-no-grub-nav.sh -- drop the redundant GRUB menu navigation that
# scripts/check-qemu-install performs when booting the freshly INSTALLED
# system.
#
# WHY: BOOTLOADERchooseSerialConsole(c, live=False) blind-sends 7 keystrokes
# (DOWN/RETURN through "Boot options" -> "Select console type" -> "ttyS
# (serial)") to pick a serial console that the installed system is ALREADY
# configured for:
#
#   1. check-qemu-install answers 'S' to the installer's "What console should
#      be used by default? (K: KVM, S: Serial)?" prompt.
#   2. dozenos-1x's image_installer.py turns that into
#      grub.set_console_type('ttyS', DIR_DST_ROOT), writing console_type=ttyS
#      into the INSTALLED root's 20-dozenos-defaults-autoload.cfg.
#   3. The version menuentry (grub_dozenos_version.j2) reads ${console_type}
#      to build `console=ttyS0,<speed>`, and grub_common.j2's setup_serial
#      puts GRUB itself on serial at config-load time.
#
# So the default top-level entry already boots to a serial login with zero
# input. Proof from a passing nightly leg (testraid, run 29721813734): the two
# post-install `reboot now` cycles take the loginVM() path, which sends NO
# GRUB keys at all, and both reach "Logged in!" normally.
#
# The navigation is not merely redundant, it is the sole source of the
# test-vpp flake (dozenos-nightly-build#1). It is open-loop -- fixed
# time.sleep(1.5) between keys, no verification of the current menu or
# highlight -- so one dropped/duplicated/mis-parsed key desynchronises every
# key after it with no recovery. In run 29721813734 the final RETURN landed
# while "Boot options" was highlighted, re-entering the submenu tree and
# parking the VM in "Select boot mode" (*Normal / Password reset). GRUB
# `submenu` blocks carry no timeout of their own and entering one cancels the
# top-level countdown, so that state hangs forever -> the harness's 600 s
# expect('[Ll]ogin:') expires -> "The ISO image is not considered usable!".
#
# FIX: delete the call. The top-level menu's own countdown boots the default
# entry, which is the same entry the keystrokes were steering towards.
#
# NOT touched: the other call site,
# BOOTLOADERchooseSerialConsole(c, live=(not args.cloud_init)).
#   - live=True (Live ISO) genuinely needs navigation: the ISO menu defaults
#     to "Live system - KVM console" and the serial entry is two rows down.
#   - live=False there is the cloud-init path, whose console_type comes from
#     the flavor file baked into a pre-assembled image rather than from the
#     installer. Whether it is equally redundant is unverified, and those legs
#     (testc/testcvpp) are green -- left alone deliberately.
# The script asserts that call site still exists, so an upstream restructure
# that removes it fails loudly here instead of silently changing what this
# patch means.
#
# Idempotent: no-op if the call is already gone. Fails loudly if neither the
# patched nor the unpatched shape is recognised -- upstream drift in the boot
# sequence must be re-reviewed by hand, not silently papered over.
#
# Usage:
#   qemu-install-no-grub-nav.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'qemu-install-no-grub-nav: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

SCRIPT="$TARGET/scripts/check-qemu-install"
[ -f "$SCRIPT" ] || die "expected file not found (upstream sync drift?): $SCRIPT"

ANCHOR="    log.info('Booting installed system')"
CALL="    BOOTLOADERchooseSerialConsole(c, live=False)"
# The call site this patch must NOT disturb (Live ISO + cloud-init).
KEEP='BOOTLOADERchooseSerialConsole(c, live=(not args.cloud_init))'

grep -qF "$ANCHOR" "$SCRIPT" \
  || die "'Booting installed system' anchor is gone from $SCRIPT -- upstream changed the post-install boot sequence; re-review by hand"
grep -qF "$KEEP" "$SCRIPT" \
  || die "the live/cloud-init BOOTLOADERchooseSerialConsole call site is gone from $SCRIPT -- upstream restructured console selection; re-review by hand"

if ! grep -qF "$CALL" "$SCRIPT"; then
  echo "qemu-install-no-grub-nav: already removed (idempotent no-op)"
  exit 0
fi

tmp=$(mktemp)
python3 - "$SCRIPT" "$tmp" "$ANCHOR" "$CALL" <<'PY'
import sys

src_path, out_path, anchor, call = sys.argv[1:5]
with open(src_path) as fh:
    src = fh.read()

old = f'{anchor}\n{call}\n'
if src.count(old) != 1:
    sys.exit(
        f'expected exactly one "{anchor}" immediately followed by the '
        f'installed-system navigation call, found {src.count(old)}'
    )

with open(out_path, 'w') as fh:
    fh.write(src.replace(old, f'{anchor}\n', 1))
PY

if grep -qF "$CALL" "$tmp"; then
  rm -f "$tmp"
  die "failed to remove the installed-system navigation call -- re-review by hand"
fi
if ! grep -qF "$KEEP" "$tmp"; then
  rm -f "$tmp"
  die "removal collaterally dropped the live/cloud-init call site -- re-review by hand"
fi

cat "$tmp" > "$SCRIPT"
rm -f "$tmp"
echo "qemu-install-no-grub-nav: removed the installed-system GRUB navigation call"
