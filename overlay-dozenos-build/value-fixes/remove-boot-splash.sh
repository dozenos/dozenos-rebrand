#!/usr/bin/env bash
#
# remove-boot-splash.sh -- remove the VyOS-branded boot splash artwork from the
# live-build bootloader config, falling back to a plain solid-colour (black)
# background for both the isolinux and GRUB boot menus.
#
# WHY (value-not-string, same category as remove-committed-mok-cert.sh): the
# two splash.png files are VyOS brand ARTWORK, not text -- rename-transform.sh
# cannot debrand a PNG. They must simply not be shipped.
#
#   data/live-build-config/includes.binary/isolinux/splash.png
#     -- referenced by GRUB via grub.cfg's `set splash_img="/isolinux/splash.png"`
#        + `if [ -e ${splash_img} ]; then background_image ${splash_img}; fi`.
#        The `-e` guard means: with the file gone, GRUB never calls
#        background_image and falls back to `set color_normal=light-gray/black`
#        -- a solid black background. So grub.cfg needs NO edit; deleting the
#        file is sufficient and self-degrading. (isolinux's own menu.cfg does
#        NOT reference it at all -- vesamenu already renders a solid default.)
#
#   data/live-build-config/bootloaders/grub-pc/splash.png
#     -- referenced only by live-theme/theme.txt's `desktop-image` line. No
#        grub.cfg activates that theme (`set theme=` appears nowhere), so it is
#        currently inert, but to leave NO dangling reference to a deleted file
#        we rewrite the `desktop-image: "../splash.png"` line to
#        `desktop-color: "#000000"` (the theme's solid-colour equivalent).
#
# Net effect: solid black boot background everywhere, zero shipped artwork,
# zero reference to a removed file.
#
# Idempotent: absent PNGs + already-rewritten theme line = silent no-op. Fails
# loudly if a PNG path holds a non-PNG (something unexpected -- don't blind
# delete) or if theme.txt has neither the expected nor the rewritten line
# (upstream redesigned the bootloader config -- re-review by hand).
#
# Usage:
#   remove-boot-splash.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'remove-boot-splash: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

LBC="$TARGET/data/live-build-config"
[ -d "$LBC" ] || die "live-build-config not found (upstream sync drift?): $LBC"

PNG_MAGIC_HEX='89504e470d0a1a0a'

remove_png() {
  local rel="$1" f="$LBC/$1"
  if [ ! -e "$f" ]; then
    echo "already removed (idempotent no-op): $rel"
    return
  fi
  # confirm it really is a PNG before deleting, so we never nuke something
  # unexpected sitting at that path. (hex compare -- the PNG magic ends in a
  # newline byte that command substitution would strip.)
  local magic
  magic=$(od -An -tx1 -N8 "$f" | tr -d ' \n')
  if [ "$magic" != "$PNG_MAGIC_HEX" ]; then
    die "expected a PNG at $rel but magic bytes do not match -- re-review by hand"
  fi
  rm -f "$f"
  echo "removed splash artwork: $rel"
}

remove_png "includes.binary/isolinux/splash.png"
remove_png "bootloaders/grub-pc/splash.png"

THEME="$LBC/bootloaders/grub-pc/live-theme/theme.txt"
[ -f "$THEME" ] || die "expected file not found (upstream sync drift?): $THEME"

OLD='desktop-image: "../splash.png"'
NEW='desktop-color: "#000000"'
if grep -qF "$OLD" "$THEME"; then
  sed -i "s|$OLD|$NEW|" "$THEME"
  echo "theme.txt: desktop-image -> solid desktop-color #000000"
elif grep -qF "$NEW" "$THEME"; then
  echo "already rewritten (idempotent no-op): theme.txt desktop-color"
else
  die "theme.txt has neither the expected desktop-image line nor the rewritten desktop-color line -- upstream drift, re-review by hand"
fi

echo "remove-boot-splash: done"
