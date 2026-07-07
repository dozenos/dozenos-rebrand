#!/usr/bin/env bash
# gen-version-json.sh -- emit the version.json manifest for a DozenOS
# nightly ISO release (see ../DISTRIBUTION.md, "version.json schema").
#
# Idempotent, no secrets, no network access. Pure computation from the
# arguments it is given: it hashes the ISO on disk, formats a JSON object,
# and writes it to stdout (or --out FILE). Run this AFTER the ISO and its
# .minisig already exist on disk (this script does not sign anything --
# see ./sign-and-publish.md for that step) and BEFORE `gh release create`
# uploads version.json alongside them.
#
# This script must never be passed key material. It only ever reads the
# already-built .iso file's bytes to hash them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: gen-version-json.sh --version VERSION --iso-path PATH [OPTIONS]

Required:
  --version VERSION       Release version string, e.g. 2026.07.08-0130-rolling
                           (DozenOS nightly scheme: YYYY.MM.DD-HHMM-rolling)
  --iso-path PATH         Path to the built .iso file on disk (must exist,
                           readable, non-empty). Its sha256 is computed here.

Options:
  --iso-name NAME         Asset filename for the ISO as published in the
                           GitHub Release. Default: basename of --iso-path.
                           Expected form: dozenos-<version>-generic-amd64.iso
  --minisig-name NAME     Asset filename for the detached minisign signature.
                           Default: "<iso-name>.minisig"
  --release-url BASE_URL  Base URL the release assets are downloadable from,
                           e.g. https://github.com/dozenos/dozenos-nightly-build/releases/download/<tag>
                           When given, "iso.url"/"minisig.url" are BASE_URL
                           joined with the asset filename. When omitted,
                           those fields are emitted as null.
  --out FILE              Write JSON to FILE instead of stdout.
  -h, --help              Show this help and exit.

Emits a JSON object on stdout (or --out FILE) describing the release, per
DISTRIBUTION.md's "version.json schema" section. Contains no secrets --
safe to commit/publish as a public release asset.

Example:
  gen-version-json.sh \
    --version 2026.07.08-0130-rolling \
    --iso-path ./dozenos-2026.07.08-0130-rolling-generic-amd64.iso \
    --release-url https://github.com/dozenos/dozenos-nightly-build/releases/download/2026.07.08-0130-rolling \
    --out version.json
EOF
}

version=""
iso_path=""
iso_name=""
minisig_name=""
release_url=""
out_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      version="${2:?--version requires a value}"
      shift 2
      ;;
    --iso-path)
      iso_path="${2:?--iso-path requires a value}"
      shift 2
      ;;
    --iso-name)
      iso_name="${2:?--iso-name requires a value}"
      shift 2
      ;;
    --minisig-name)
      minisig_name="${2:?--minisig-name requires a value}"
      shift 2
      ;;
    --release-url)
      release_url="${2:?--release-url requires a value}"
      shift 2
      ;;
    --out)
      out_file="${2:?--out requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "E: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$version" ]; then
  echo "E: --version is required" >&2
  exit 1
fi
if [ -z "$iso_path" ]; then
  echo "E: --iso-path is required" >&2
  exit 1
fi
if [ ! -f "$iso_path" ]; then
  echo "E: --iso-path '$iso_path' does not exist or is not a regular file" >&2
  exit 1
fi
if [ ! -s "$iso_path" ]; then
  echo "E: --iso-path '$iso_path' is empty" >&2
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "E: sha256sum not found on PATH" >&2
  exit 1
fi

if [ -z "$iso_name" ]; then
  iso_name="$(basename -- "$iso_path")"
fi
if [ -z "$minisig_name" ]; then
  minisig_name="${iso_name}.minisig"
fi

sha256="$(sha256sum -- "$iso_path" | awk '{print $1}')"
if [ -z "$sha256" ] || [ "${#sha256}" -ne 64 ]; then
  echo "E: sha256sum did not return a 64-char hex digest for '$iso_path'" >&2
  exit 1
fi

published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Minimal JSON string escaper: backslash and double-quote only. Every field
# fed through this is a version string, filename, or URL -- none of which
# are expected to contain control characters -- but this keeps the script
# honest instead of assuming that.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

iso_url_json="null"
minisig_url_json="null"
if [ -n "$release_url" ]; then
  # Join without introducing a double slash if release_url already ends in /
  base="${release_url%/}"
  iso_url_json="\"$(json_escape "${base}/${iso_name}")\""
  minisig_url_json="\"$(json_escape "${base}/${minisig_name}")\""
fi

version_j="$(json_escape "$version")"
iso_name_j="$(json_escape "$iso_name")"
minisig_name_j="$(json_escape "$minisig_name")"
sha256_j="$(json_escape "$sha256")"
published_at_j="$(json_escape "$published_at")"

json=$(cat <<EOF
{
  "version": "${version_j}",
  "iso": {
    "name": "${iso_name_j}",
    "sha256": "${sha256_j}",
    "url": ${iso_url_json}
  },
  "minisig": {
    "name": "${minisig_name_j}",
    "url": ${minisig_url_json}
  },
  "minisign_pubkey_file": "minisign.pub",
  "published_at": "${published_at_j}"
}
EOF
)

if [ -n "$out_file" ]; then
  printf '%s\n' "$json" > "$out_file"
  echo "I: wrote $out_file" >&2
else
  printf '%s\n' "$json"
fi
