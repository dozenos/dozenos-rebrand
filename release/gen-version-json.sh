#!/usr/bin/env bash
# gen-version-json.sh -- emit the version.json manifest for a DozenOS
# nightly release (see ../DISTRIBUTION.md, "version.json schema").
#
# Multi-flavor/multi-format aware: pass one --artifact FLAVOR:PATH per
# built image file (any format -- .iso, .qcow2, .vmdk, ...); each becomes
# an entry in the "artifacts" array with its flavor, format (file
# extension), sha256, and download URL. For backward compatibility with
# the original single-ISO schema, the top-level "iso"/"minisig" objects
# are still emitted, pointing at the generic flavor's .iso when present
# (else the first .iso given).
#
# Idempotent, no secrets, no network access. Pure computation from the
# arguments it is given: it hashes the files on disk, formats a JSON
# object, and writes it to stdout (or --out FILE). Run this AFTER the
# artifacts exist on disk (signing happens separately -- see
# ./sign-and-publish.sh) and BEFORE `gh release create` uploads
# version.json alongside them.
#
# This script must never be passed key material. It only ever reads the
# already-built artifact files' bytes to hash them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: gen-version-json.sh --version VERSION --artifact FLAVOR:PATH [--artifact ...] [OPTIONS]

Required:
  --version VERSION       Release version string, e.g. 2026.07.08-0130-rolling
                           (DozenOS nightly scheme: YYYY.MM.DD-HHMM-rolling)
  --artifact FLAVOR:PATH  One built image file, tagged with its flavor name.
                           Repeatable. PATH must exist, be readable and
                           non-empty; FLAVOR must not contain ':'.
                           Example: --artifact kvm:build/dozenos-...-kvm-amd64.qcow2

Options:
  --release-url BASE_URL  Base URL the release assets are downloadable from,
                           e.g. https://github.com/dozenos/dozenos-nightly-build/releases/download/<tag>
                           When given, each artifact's "url"/"minisig_url" are
                           BASE_URL joined with the asset filename. When
                           omitted, those fields are emitted as null.
  --out FILE              Write JSON to FILE instead of stdout.
  -h, --help              Show this help and exit.

Emits a JSON object on stdout (or --out FILE) describing the release, per
DISTRIBUTION.md's "version.json schema" section. Contains no secrets --
safe to commit/publish as a public release asset.

Example:
  gen-version-json.sh \
    --version 2026.07.08-0130-rolling \
    --artifact generic:build/dozenos-2026.07.08-0130-rolling-generic-amd64.iso \
    --artifact kvm:build/dozenos-2026.07.08-0130-rolling-kvm-amd64.iso \
    --artifact kvm:build/dozenos-2026.07.08-0130-rolling-kvm-amd64.qcow2 \
    --release-url https://github.com/dozenos/dozenos-nightly-build/releases/download/2026.07.08-0130-rolling \
    --out version.json
EOF
}

version=""
release_url=""
out_file=""
artifacts=()

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      version="${2:?--version requires a value}"
      shift 2
      ;;
    --artifact)
      artifacts+=("${2:?--artifact requires a value}")
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
if [ "${#artifacts[@]}" -eq 0 ]; then
  echo "E: at least one --artifact FLAVOR:PATH is required" >&2
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "E: sha256sum not found on PATH" >&2
  exit 1
fi

# Minimal JSON string escaper: backslash and double-quote only. Every field
# fed through this is a version string, flavor name, filename, or URL --
# none of which are expected to contain control characters -- but this
# keeps the script honest instead of assuming that.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

base=""
if [ -n "$release_url" ]; then
  base="${release_url%/}"
fi

url_json() {
  # $1 = asset filename; emits a JSON value (quoted URL or null)
  if [ -n "$base" ]; then
    printf '"%s"' "$(json_escape "${base}/$1")"
  else
    printf 'null'
  fi
}

artifact_entries=""
legacy_iso_name=""
legacy_iso_sha=""

for spec in "${artifacts[@]}"; do
  flavor="${spec%%:*}"
  path="${spec#*:}"
  if [ -z "$flavor" ] || [ "$flavor" = "$spec" ] || [ -z "$path" ]; then
    echo "E: malformed --artifact '$spec' (expected FLAVOR:PATH)" >&2
    exit 1
  fi
  if [ ! -f "$path" ] || [ ! -s "$path" ]; then
    echo "E: artifact '$path' does not exist, is not a regular file, or is empty" >&2
    exit 1
  fi

  name="$(basename -- "$path")"
  format="${name##*.}"
  sha256="$(sha256sum -- "$path" | awk '{print $1}')"
  if [ -z "$sha256" ] || [ "${#sha256}" -ne 64 ]; then
    echo "E: sha256sum did not return a 64-char hex digest for '$path'" >&2
    exit 1
  fi

  # Legacy top-level iso pointer: prefer the generic flavor's .iso; fall
  # back to the first .iso seen.
  if [ "$format" = "iso" ] && { [ "$flavor" = "generic" ] || [ -z "$legacy_iso_name" ]; }; then
    legacy_iso_name="$name"
    legacy_iso_sha="$sha256"
  fi

  entry=$(cat <<EOF
    {
      "flavor": "$(json_escape "$flavor")",
      "format": "$(json_escape "$format")",
      "name": "$(json_escape "$name")",
      "sha256": "$sha256",
      "url": $(url_json "$name"),
      "minisig": {
        "name": "$(json_escape "${name}.minisig")",
        "url": $(url_json "${name}.minisig")
      }
    }
EOF
)
  if [ -n "$artifact_entries" ]; then
    artifact_entries="$artifact_entries,
$entry"
  else
    artifact_entries="$entry"
  fi
done

published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Legacy single-ISO block (kept for backward compatibility with the
# original schema; null-fielded if no .iso was among the artifacts).
if [ -n "$legacy_iso_name" ]; then
  legacy_block=$(cat <<EOF
  "iso": {
    "name": "$(json_escape "$legacy_iso_name")",
    "sha256": "$legacy_iso_sha",
    "url": $(url_json "$legacy_iso_name")
  },
  "minisig": {
    "name": "$(json_escape "${legacy_iso_name}.minisig")",
    "url": $(url_json "${legacy_iso_name}.minisig")
  },
EOF
)
else
  legacy_block='  "iso": null,
  "minisig": null,'
fi

json=$(cat <<EOF
{
  "version": "$(json_escape "$version")",
${legacy_block}
  "artifacts": [
${artifact_entries}
  ],
  "minisign_pubkey_file": "minisign.pub",
  "published_at": "$(json_escape "$published_at")"
}
EOF
)

if [ -n "$out_file" ]; then
  printf '%s\n' "$json" > "$out_file"
  echo "I: wrote $out_file (${#artifacts[@]} artifact(s))" >&2
else
  printf '%s\n' "$json"
fi
