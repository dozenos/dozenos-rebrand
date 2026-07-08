#!/usr/bin/env bash
# make-ephemeral-apt-repo.sh -- build a minimal, unsigned, [trusted=yes] apt
# repository from a directory of already-built .deb files (see
# ../ISO-BUILD.md, item #13, "the ephemeral in-job apt repo").
#
# DozenOS has NO public apt mirror (../DISTRIBUTION.md §1, locked decision:
# image-based upgrade, no runtime `apt upgrade`). The ISO build
# (scripts/image-build/build-dozenos-image) still needs SOME apt source to
# resolve/install the DozenOS-built packages it apt-installs during live-build
# chroot assembly (e.g. `dozenos-1x`, listed in
# data/live-build-config/package-lists/dozenos-base.list.chroot). This script
# closes that gap WITHOUT hosting anything: it turns a directory of `.deb`s
# (the CI artifacts `rebuild-packages.yml`'s `build` job uploads, downloaded
# by the ISO-build job via `actions/download-artifact`) into a real,
# dists/-shaped apt repository that lives only on the runner's local disk for
# the duration of the job, consumed via a `file://` URL.
#
# What it does:
#   1. Recursively finds every *.deb under <debs-dir> (actions/download-artifact
#      with `merge-multiple: true` flattens them into one dir; a plain
#      per-artifact-subdirectory layout also works, since the search is
#      recursive).
#   2. Copies them into <output-dir>/pool/<component>/.
#   3. Runs `dpkg-scanpackages` to build
#      <output-dir>/dists/<suite>/<component>/binary-<arch>/Packages(.gz).
#   4. Runs `apt-ftparchive release` to build <output-dir>/dists/<suite>/Release
#      (no signature -- this repo is only ever consumed with
#      `[trusted=yes]`, see ../CI-SECRETS.md's "GPG role reconciliation":
#      signing an ephemeral, runner-local, single-tenant repo's Release file
#      buys nothing and is deliberately NOT done here).
#   5. Prints the repo's `[trusted=yes] file://<output-dir>` value on stdout
#      (one line, nothing else -- safe to capture with `$(...)`), and the
#      full illustrative `deb`/`deb-src` source-list lines to stderr for a
#      human/log to read.
#
# CONSUMPTION WARNING (learned the hard way, 2026-07-08): the file:// value
# is only usable by an apt whose filesystem root can actually see
# <output-dir>. `build-dozenos-image`'s `lb build` runs apt INSIDE the
# live-build chroot (build/chroot/), where <output-dir> does NOT exist --
# every file:// index fetch 404s there (apt Ign-s the missing Packages index
# but hard-fails on the missing Sources index, and package installs would
# fail regardless). For that consumer, serve <output-dir> over localhost
# HTTP from the same container and pass
#   --dozenos-mirror "[trusted=yes] http://127.0.0.1:<port>"
# instead -- the chroot shares the container network namespace, so
# 127.0.0.1 is reachable from chroot apt at every stage that needs it:
#   (cd <output-dir> && python3 -m http.server --bind 127.0.0.1 8099 &)
# (Do NOT try to seed <output-dir> into the chroot to keep a file:// URL:
# that races lb clean, the bootstrap cache restore, and debootstrap itself
# -- four distinct failure modes were hit in local testing before this
# approach was abandoned in favor of localhost HTTP.) See
# dozenos-nightly-build's .github/workflows/nightly.yml build-iso step for
# the canonical wiring.
#
# --suite/--component MUST match what build-dozenos-image writes into
# config/archives/dozenos.list.chroot: it formats the literal template
# "deb {dozenos_mirror} {dozenos_branch} main" (see
# scripts/image-build/build-dozenos-image, and defaults.toml's
# `dozenos_branch = "rolling"` -- there is no `--dozenos-branch` CLI flag, so
# in practice this is always "rolling"/"main" for a real DozenOS build). The
# defaults below match that exactly; only override them if
# build-dozenos-image's own defaults are ever changed to match.
#
# No secrets, no network access, no key material -- pure filesystem
# transform of what it is given. Idempotent: re-running against the same
# <output-dir> wipes and rebuilds only the pool/ and dists/ subtrees it owns,
# producing a byte-for-byte-equivalent repo (modulo the Release file's Date:
# field) from the same input .debs.
#
# Usage:
#   make-ephemeral-apt-repo.sh <debs-dir> <output-dir> \
#       [--suite SUITE] [--component COMPONENT] [--arch ARCH]
#
# Example (matches build-dozenos-image's defaults exactly):
#   make-ephemeral-apt-repo.sh ./dozenos-debs ./dozenos-apt-repo
#   # stdout: [trusted=yes] file:///abs/path/dozenos-apt-repo
#   # -> build-dozenos-image --dozenos-mirror "$(make-ephemeral-apt-repo.sh ...)" ...
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: make-ephemeral-apt-repo.sh <debs-dir> <output-dir> [OPTIONS]

  <debs-dir>          Directory to search (recursively) for *.deb files.
                       Required; must exist. Fails loudly if it contains no
                       .deb files anywhere under it.
  <output-dir>         Directory the apt repo is built in (created if it does
                       not exist). Only its pool/ and dists/ subtrees are
                       touched/wiped on re-run -- safe to point at a
                       preexisting, otherwise-empty scratch directory.

Options:
  --suite SUITE        apt suite/distribution name. Default: rolling
                        (MUST match build-dozenos-image's dozenos_branch --
                        see this script's header comment).
  --component COMPONENT
                        apt component name. Default: main (MUST match
                        build-dozenos-image's hardcoded "main" literal --
                        see this script's header comment).
  --arch ARCH           Binary architecture. Default: amd64.
  -h, --help            Show this help and exit.

On success, prints exactly one line to stdout: the value to pass to
`build-dozenos-image --dozenos-mirror`, e.g.:
  [trusted=yes] file:///home/runner/work/.../dozenos-apt-repo
Everything else (progress, the full illustrative "deb ..."/"deb-src ..."
source-list lines, warnings) goes to stderr.

No secrets, no network. Requires dpkg-scanpackages (dpkg-dev) and
apt-ftparchive (apt-utils) on PATH.
EOF
}

log() { printf 'I: %s\n' "$*" >&2; }
die() { printf 'E: %s\n' "$*" >&2; exit 1; }

suite="rolling"
component="main"
arch="amd64"
debs_dir=""
out_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --suite)
      suite="${2:?--suite requires a value}"
      shift 2
      ;;
    --component)
      component="${2:?--component requires a value}"
      shift 2
      ;;
    --arch)
      arch="${2:?--arch requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
    *)
      if [ -z "$debs_dir" ]; then
        debs_dir="$1"
      elif [ -z "$out_dir" ]; then
        out_dir="$1"
      else
        usage >&2
        die "unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$debs_dir" ] || [ -z "$out_dir" ]; then
  usage >&2
  die "both <debs-dir> and <output-dir> are required"
fi
[ -d "$debs_dir" ] || die "<debs-dir> not a directory: $debs_dir"

command -v dpkg-scanpackages >/dev/null 2>&1 || die "dpkg-scanpackages not found on PATH (install dpkg-dev)"
command -v apt-ftparchive   >/dev/null 2>&1 || die "apt-ftparchive not found on PATH (install apt-utils)"
command -v gzip             >/dev/null 2>&1 || die "gzip not found on PATH"

# Collect input .debs BEFORE touching output-dir, in case debs-dir and
# output-dir happen to overlap/nest.
deb_count=0
deb_list_file="$(mktemp)"
trap 'rm -f "$deb_list_file"' EXIT
find "$debs_dir" -type f -name '*.deb' | sort > "$deb_list_file"
deb_count="$(wc -l < "$deb_list_file" | tr -d ' ')"

if [ "$deb_count" -eq 0 ]; then
  die "no .deb files found anywhere under $debs_dir -- refusing to create an empty apt repo (a build-dozenos-image run pointed at this would silently fail every DozenOS package install)"
fi

mkdir -p "$out_dir"
# Canonicalize to an absolute path -- a file:// URL embedded in a live-build
# apt source line must be absolute (this is also the value re-emitted on
# stdout for the caller to feed straight into --dozenos-mirror).
out_dir="$(cd "$out_dir" && pwd)"

pool_dir="$out_dir/pool/$component"
binary_dir="$out_dir/dists/$suite/$component/binary-$arch"
dists_suite_dir="$out_dir/dists/$suite"

# Idempotent: only ever wipe the pool/ and dists/ subtrees this script owns,
# never the whole output-dir (a caller may reuse the same scratch dir across
# runs, or point it at a directory GitHub Actions already created).
rm -rf "$out_dir/pool" "$out_dir/dists"
mkdir -p "$pool_dir" "$binary_dir"

while IFS= read -r deb; do
  cp -f -- "$deb" "$pool_dir/"
done < "$deb_list_file"

pool_deb_count="$(find "$pool_dir" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')"
log "staged $pool_deb_count .deb file(s) (from $deb_count found under $debs_dir) into ${pool_dir#"$out_dir"/}"

# dpkg-scanpackages prints an expected, non-fatal warning to stderr when no
# override file is given ("Packages in archive but missing from override
# file") -- this repo deliberately has no override file (no
# section/priority policy to maintain for an ephemeral, single-build repo),
# so that warning is surfaced but never treated as failure. A genuine
# failure (bad archive member, unreadable .deb, etc.) is a non-zero exit,
# which IS treated as fatal below.
scan_stderr="$(mktemp)"
trap 'rm -f "$deb_list_file" "$scan_stderr"' EXIT
if ! ( cd "$out_dir" && dpkg-scanpackages --arch "$arch" "pool/$component" ) \
       > "$binary_dir/Packages" 2>"$scan_stderr"; then
  cat "$scan_stderr" >&2
  die "dpkg-scanpackages failed (see output above)"
fi
cat "$scan_stderr" >&2
[ -s "$binary_dir/Packages" ] || die "dpkg-scanpackages produced an empty Packages index"

stanza_count="$(grep -c '^Package:' "$binary_dir/Packages" || true)"
if [ "$stanza_count" -ne "$pool_deb_count" ]; then
  die "Packages index has $stanza_count stanza(s) but $pool_deb_count .deb file(s) were staged -- dpkg-scanpackages output looks wrong"
fi

gzip -kf "$binary_dir/Packages"

# Source index (empty, but PRESENT). build-dozenos-image ALWAYS writes a
# `deb-src <dozenos_mirror> <branch> main` entry for this repo (see
# scripts/image-build/build-dozenos-image, "deb-src {dozenos_mirror} ..."), and
# live-build runs apt with source acquisition on, so `lb build` fetches
# dists/<suite>/<component>/source/Sources from here. This pool holds only
# binary .debs (no .dsc/source), so the Sources index is legitimately EMPTY --
# but it must still EXIST: Debian bookworm's apt (the ghcr build container)
# hard-fails `lb build` with "E: Failed to fetch .../source/Sources -- File not
# found" when the index is absent (newer apt only warns and skips). Generate it
# with apt-ftparchive (empty output on a .dsc-less pool) BEFORE the release step
# below so apt-ftparchive release advertises it in Release with checksums.
source_dir="$out_dir/dists/$suite/$component/source"
mkdir -p "$source_dir"
if ! ( cd "$out_dir" && apt-ftparchive sources "pool/$component" ) \
       > "$source_dir/Sources" 2>>"$scan_stderr"; then
  cat "$scan_stderr" >&2
  die "apt-ftparchive sources failed"
fi
gzip -kf "$source_dir/Sources"

if ! ( cd "$out_dir" && apt-ftparchive \
         -o APT::FTPArchive::Release::Origin=DozenOS \
         -o APT::FTPArchive::Release::Label=DozenOS \
         -o APT::FTPArchive::Release::Suite="$suite" \
         -o APT::FTPArchive::Release::Codename="$suite" \
         -o APT::FTPArchive::Release::Architectures="$arch" \
         -o APT::FTPArchive::Release::Components="$component" \
         release "dists/$suite" ) > "$dists_suite_dir/Release"; then
  die "apt-ftparchive release failed"
fi
[ -s "$dists_suite_dir/Release" ] || die "apt-ftparchive produced an empty Release file"

mirror_value="[trusted=yes] file://$out_dir"

log "ephemeral apt repo ready: $out_dir ($stanza_count package(s), suite=$suite component=$component arch=$arch)"
log "full apt source-list lines this repo supports:"
log "  deb     $mirror_value $suite $component"
log "  deb-src $mirror_value $suite $component"
log "WARNING: this file:// value is NOT visible to apt inside a live-build"
log "WARNING: chroot (lb build) -- serve $out_dir over localhost HTTP and use"
log "WARNING: [trusted=yes] http://127.0.0.1:<port> there instead (see header)."
log "file:// value (also printed on stdout):"

printf '%s\n' "$mirror_value"
