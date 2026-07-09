#!/usr/bin/env bash
#
# pin-helper-scm-urls.sh -- revert scm_url fields for VyOS-maintained helper/
# source repos back to the real `github.com/vyos/*` (audit item #11 class).
#
# WHY: rename-transform.sh's four-form pass rewrites every `github.com/vyos/*`
# scm_url to a `github.com/dozenos/*` URL. That is CORRECT for repos that
# already have (or will imminently get) a `dozenos` org mirror, but WRONG for
# repos whose mirror does not exist yet -- the rewritten URL 404s and the
# recipe can no longer clone its source at all.
#
# This is a TEMPORARY, CONTINGENT override, not a permanent one: each entry
# below must be deleted from this script the moment its corresponding
# `github.com/dozenos/<name>` mirror repo actually exists (per the DozenOS
# GitHub-structure plan, items #4/#6). Leaving a stale entry here past that
# point would make the recipe silently keep building from the OLD vyos-org
# source forever, diverging from the mirrored/patched dozenos source tree.
#
# Covered recipes (scripts/package-build/<dir>/package.toml, relative to the
# package-build root):
#   - libnss-mapuser, libpam-radius-auth, shim-signed  (single-block recipes)
#   - tacacs (3 blocks: libtacplus-map, libpam-tacplus, libnss-tacplus)
#   - vpp (only its "vyos-vpp-patches" / post-transform "dozenos-vpp-patches"
#     block's scm_url -- the block's `name` field and the sibling `vpp`
#     block's rsync path both consistently read "dozenos-vpp-patches" after
#     transform and do NOT need reverting; only the external fetch URL does)
#   - dozenos-1x (post-rename path for vyos-1x; `name` stays "dozenos-1x" --
#     that IS the correct future package name -- only scm_url is reverted)
#
# ALSO covered here: the 6 NEW recipes shipped via overlay-dozenos-build/new-files/
# (vyatta-bash, vyatta-biosdevname, vyatta-cfg, ipaddrcheck, hvinfo,
# dozenos-http-api-tools) -- see overlay-dozenos-build/MANIFEST.md. Those recipes don't
# exist upstream, so they bypass rename-transform.sh entirely (new-files/ is
# copied in AFTER rename-transform.sh already ran); their package.toml files
# ship scm_url already pointed at github.com/dozenos/* (their mirrors exist),
# which is correct for --ci but must still be pinned back to the real
# github.com/vyos/* for --local (offline/pre-mirror) builds, same as the 8
# transformed-recipe entries above. dozenos-http-api-tools is the one
# name-changing case: it maps dozenos/dozenos-http-api-tools.git (the shipped
# form) back to vyos/vyos-http-api-tools.git (the real upstream repo name).
#
# Idempotent: a target already showing the reverted (real-vyos) URL is a
# no-op. Fails loudly if neither the expected transformed nor the
# already-reverted URL is found (upstream sync drift -- re-review by hand).
#
# Usage:
#   pin-helper-scm-urls.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'pin-helper-scm-urls: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

PB="$TARGET/scripts/package-build"

# entries: "relative-file|dozenos-form|vyos-form"
ENTRIES=(
  "libnss-mapuser/package.toml|https://github.com/dozenos/libnss-mapuser.git|https://github.com/vyos/libnss-mapuser.git"
  "libpam-radius-auth/package.toml|https://github.com/dozenos/libpam-radius-auth.git|https://github.com/vyos/libpam-radius-auth.git"
  "shim-signed/package.toml|https://github.com/dozenos/shim-signed.git|https://github.com/vyos/shim-signed.git"
  "tacacs/package.toml|https://github.com/dozenos/libtacplus-map.git|https://github.com/vyos/libtacplus-map.git"
  "tacacs/package.toml|https://github.com/dozenos/libpam-tacplus.git|https://github.com/vyos/libpam-tacplus.git"
  "tacacs/package.toml|https://github.com/dozenos/libnss-tacplus.git|https://github.com/vyos/libnss-tacplus.git"
  "vpp/package.toml|https://github.com/dozenos/dozenos-vpp-patches|https://github.com/vyos/vyos-vpp-patches"
  "dozenos-1x/package.toml|https://github.com/dozenos/dozenos-1x.git|https://github.com/vyos/vyos-1x.git"
  "vyatta-bash/package.toml|https://github.com/dozenos/vyatta-bash.git|https://github.com/vyos/vyatta-bash.git"
  "vyatta-biosdevname/package.toml|https://github.com/dozenos/vyatta-biosdevname.git|https://github.com/vyos/vyatta-biosdevname.git"
  "vyatta-cfg/package.toml|https://github.com/dozenos/vyatta-cfg.git|https://github.com/vyos/vyatta-cfg.git"
  "ipaddrcheck/package.toml|https://github.com/dozenos/ipaddrcheck.git|https://github.com/vyos/ipaddrcheck.git"
  "hvinfo/package.toml|https://github.com/dozenos/hvinfo.git|https://github.com/vyos/hvinfo.git"
  "dozenos-http-api-tools/package.toml|https://github.com/dozenos/dozenos-http-api-tools.git|https://github.com/vyos/vyos-http-api-tools.git"
)

changed=0
already=0
for entry in "${ENTRIES[@]}"; do
  rel="${entry%%|*}"
  rest="${entry#*|}"
  dozenos_form="${rest%%|*}"
  vyos_form="${rest#*|}"
  f="$PB/$rel"

  [ -f "$f" ] || die "expected file not found (upstream sync / dir-rename drift?): $f"

  if grep -qF "$dozenos_form" "$f"; then
    sed -i "s|${dozenos_form}|${vyos_form}|" "$f"
    changed=$((changed + 1))
    echo "reverted: $rel ($dozenos_form)"
  elif grep -qF "$vyos_form" "$f"; then
    already=$((already + 1))
    echo "already reverted (idempotent no-op): $rel ($vyos_form)"
  else
    die "neither expected dozenos-rewritten nor already-reverted scm_url found in $f for pattern '$vyos_form' -- drift, re-review by hand"
  fi
done

echo "pin-helper-scm-urls: $changed reverted, $already already-clean (of ${#ENTRIES[@]} tracked)"
