#!/usr/bin/env bash
#
# apply-overlay.sh -- per-repo overlay for the dozenos-1x mirror (upstream
# github.com/vyos/vyos-1x). Applies everything rename-transform.sh cannot
# reproduce on top of an already-transformed vyos-1x clone.
#
# Pipeline position (mode-B, per mirror-push.sh):
#
#   fresh clone -> rename-transform.sh <tree> -> strip .github/ ->
#   overlay-dozenos-1x/apply-overlay.sh <tree> -> rename-transform.sh
#   <tree> --verify -> push
#
# Invoked by mirror-push.sh's `--overlay <dir>` step, which runs
# `<dir>/apply-overlay.sh <clone-dir>` (single positional argument -- see
# mirror-push.sh step 4/6). For the eventual dozenos-1x push:
#
#   mirror-push.sh https://github.com/vyos/vyos-1x --target dozenos-1x \
#     --overlay dozenos-rebrand/overlay-dozenos-1x
#
# Steps, in order:
#
#   1. value-fixes/regen-default-password-hash.sh -- the PRIMARY job of this
#      overlay (audit item #8/#23): regenerate the default-login SHA-512
#      crypt hash for the new default password `dozenos` and replace the
#      inherited VyOS hash (crypt of the plaintext `vyos`) everywhere it
#      appears. See that script's own header for the full "value, not
#      string" rationale and the exact hash matched.
#
#   2. value-fixes/pin-nonmirrored-org-refs.sh -- revert 2 stray
#      github.com/dozenos/* refs (.coderabbit.yaml's org-baseline-config
#      link, and a vyatta-cfg-qos doc-comment ref in
#      python/dozenos/qos/base.py) that the four-form pass correctly produced
#      but that point at repos with no dozenos mirror and no mirror plan --
#      found by ../REPOINT-AUDIT.md's step #6 cross-check. See that script's
#      own header for the full rationale.
#
#   4. value-fixes/strip-motd-logo-frame.sh -- remove the VyOS box-drawing
#      logo frame from the post-login MOTD template default_motd.j2, keeping
#      the version text. The four-form pass swaps the WORD `VyOS` but leaves
#      the frame graphic (which carries no brand text) intact; this removes
#      it. See that script's own header for the exact block matched.
#
#   5. value-fixes/fix-snmp-test-localized-keys.sh -- recompute the four
#      SNMPv3 localized-key constants in test_service_snmp.py for the
#      transformed plaintext passwords (same value-not-string class as
#      step 1: a localized key carries no `vyos` substring, so the
#      transform leaves it stale). See that script's own header.
#
#   6. value-fixes/fix-length-constrained-test-constants.sh -- restore the
#      upstream byte length of five smoketest constants (two nhrp secrets,
#      two ospf passwords, one VRF name) that `vyos` -> `dozenos` grew past
#      an 8- or 15-character CLI validator ceiling, by substituting the
#      4-character token `dzos`. Also value-not-string: the strings are
#      syntactically fine and carry no `vyos`, they are just too long for
#      the validator. See that script's own header.
#
# (pin-opam-upstream-tag.sh runs as step 3/6 -- see the NOT-here note below
# for why it exists.)
#
# What is deliberately NOT here (verified against a fresh upstream clone --
# see dozenos-rebrand/overlay-dozenos-build/MANIFEST.md's "Per-repo overlay split" section
# for where these were first flagged as vyos-1x-repo concerns):
#
#   - opam pin PACKAGE NAMES + URL HOSTS in libvyosconfig/Makefile
#     (`vyos1x-config` -> `dozenos1x-config`, `github.com/vyos/*` ->
#     `github.com/dozenos/*`) -- handled by rename-transform.sh's generic
#     four-form pass. Confirmed post-transform:
#       PACKAGES=dozenos1x-config,vyconf.vyconfd-config,...
#       opam pin add dozenos1x-config https://github.com/dozenos/dozenos1x-config.git#<sha> -y
#       opam pin add vyconf https://github.com/dozenos/vyconf.git#<sha> -y
#     (vyconf's own package name is untouched, correctly, since "vyconf"
#     does not contain "vyos"; only its URL host is rewritten.)
#     *** BUT the `#<sha>` COMMIT FRAGMENT is NOT four-form-transformable and
#     is the original upstream vyos1x-config/vyconf commit -- which does NOT
#     exist in the mode-B snapshot mirrors (each carries a fresh single
#     commit). opam then dies "Commit not found on repository". That IS
#     handled here, by step 3/6 (value-fixes/pin-opam-upstream-tag.sh), which
#     re-pins both to `#upstream-<sha>` -- the tag mirror-push.sh --pin-commit
#     puts on the mirror for exactly that upstream commit. This was the
#     dozenos-1x package-build failure caught by the first full CI run.
#     (It re-pinned to `#rolling` until 2026-07-20; that tracked the mirror's
#     branch tip instead of the commit upstream builds, which made the build
#     unreproducible and dragged in vyconf's broken ocaml-protoc pin. See that
#     script's header.)
#
#   - `open Vyos1x` in libdozenosconfig/lib/bindings.ml (the OCaml ctypes
#     bindings) -- already handled by the four-form pass. Confirmed
#     post-transform: `open Dozenos1x` and `Dozenos1x.Parser.from_string`.
#
#   - The Makefile's `git ls-files` -> `find` patch (audit item #17, applied
#     by hand in the LOCAL vyos-build recipe copy at
#     scripts/package-build/vyos-1x/vyos-1x/Makefile) -- NOT reproduced
#     here. That local patch exists because the local-build pipeline ran
#     rename-transform.sh directly on an already-`git clone`d working tree
#     WITHOUT re-committing afterwards, leaving the tree's `.git` index
#     stale (still listing pre-rename `vyos-*` paths) while the files on
#     disk were already renamed to `dozenos-*` -- so `git ls-files
#     src/services/dozenos*` returned 0 matches against that stale index.
#     Mode B does not have this problem: mirror-push.sh transforms the
#     clone FIRST and only THEN does `git init && git add -A && commit`
#     (see mirror-push.sh's seed path), so the fresh mirror's git index is
#     built directly from the already-transformed tree and is always
#     consistent with it. Verified by simulation: rename-transform.sh
#     against a fresh vyos-1x clone, followed by `rm -rf .git && git init
#     -b rolling && git add -A && commit` (mirroring mirror-push.sh's seed
#     path exactly), leaves `git ls-files 'src/services/dozenos*'` returning
#     all 8 renamed service files, matching disk exactly. The eventual
#     re-clone of this mirror as a dozenos-build dependency, followed by
#     dozenos-1x's pre_build_hook re-running rename-transform.sh (a no-op on
#     an already-all-dozenos tree -- no renames means the index is never
#     invalidated), preserves that same consistency. No overlay entry
#     needed.
#
# Idempotent: the one sub-step is idempotent (see its own header). Running
# apply-overlay.sh twice against the same tree is a clean no-op on the
# second run.
#
# No network beyond `openssl passwd` (local-only, no network I/O), no git,
# no package/ISO build -- pure file operations.
#
# Usage:
#   apply-overlay.sh <target-tree>
set -euo pipefail

die() { printf 'apply-overlay: %s\n' "$*" >&2; exit 2; }
usage() { echo "Usage: $0 <target-tree>" >&2; }

TARGET="${1:-}"
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ -n "$TARGET" ] || { usage; die "missing required <target-tree>"; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"
[ $# -le 1 ] || die "unexpected extra argument(s): ${*:2}"
TARGET=$(cd "$TARGET" && pwd)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VALUE_FIXES="$SCRIPT_DIR/value-fixes"

echo "== apply-overlay (dozenos-1x): step 1/6 -- value-fixes/regen-default-password-hash.sh =="
"$VALUE_FIXES/regen-default-password-hash.sh" "$TARGET"

echo "== apply-overlay (dozenos-1x): step 2/6 -- value-fixes/pin-nonmirrored-org-refs.sh =="
"$VALUE_FIXES/pin-nonmirrored-org-refs.sh" "$TARGET"

echo "== apply-overlay (dozenos-1x): step 3/6 -- value-fixes/pin-opam-upstream-tag.sh =="
"$VALUE_FIXES/pin-opam-upstream-tag.sh" "$TARGET"

echo "== apply-overlay (dozenos-1x): step 4/6 -- value-fixes/strip-motd-logo-frame.sh =="
"$VALUE_FIXES/strip-motd-logo-frame.sh" "$TARGET"

echo "== apply-overlay (dozenos-1x): step 5/6 -- value-fixes/fix-snmp-test-localized-keys.sh =="
"$VALUE_FIXES/fix-snmp-test-localized-keys.sh" "$TARGET"

echo "== apply-overlay (dozenos-1x): step 6/6 -- value-fixes/fix-length-constrained-test-constants.sh =="
"$VALUE_FIXES/fix-length-constrained-test-constants.sh" "$TARGET"

echo "apply-overlay (dozenos-1x): done"
