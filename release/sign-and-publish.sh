#!/usr/bin/env bash
# sign-and-publish.sh -- minisign the built ISO and publish a GitHub Release
# in dozenos/dozenos-nightly-build. Called by item #17's nightly workflow
# AFTER the ISO and version.json already exist on disk (see
# ./gen-version-json.sh and ../DISTRIBUTION.md).
#
# This script NEVER contains, generates, or fabricates key material. It only
# ever references the CI secret NAMES below (see ../CI-SECRETS.md, which is
# authoritative for the exact names):
#   MINISIGN_SECRET_KEY  -- base64 of the minisign secret keyfile
#   MINISIGN_PASSWORD    -- password that unlocks MINISIGN_SECRET_KEY
#   GITHUB_TOKEN          -- the job's own token; same-repo publish needs no PAT
#
# It fails loudly (does not fabricate a throwaway key) if MINISIGN_SECRET_KEY
# or GITHUB_TOKEN is unset/empty. MINISIGN_PASSWORD MAY be empty/unset -- that
# is the legitimate no-passphrase case (an unencrypted / empty-passphrase
# minisign key); an empty password is fed to minisign, and if the key actually
# needs a password minisign itself fails loudly at signing time.
#
# Usage (run inside the nightly workflow's job, both env vars exported from
# secrets, cwd = the directory containing the built ISO):
#   MINISIGN_SECRET_KEY="$MINISIGN_SECRET_KEY_B64" \
#   MINISIGN_PASSWORD="$MINISIGN_PASSWORD" \
#   GITHUB_TOKEN="$GITHUB_TOKEN" \
#   ./sign-and-publish.sh \
#     --iso ./dozenos-2026.07.08-0130-rolling-generic-amd64.iso \
#     --version-json ./version.json \
#     --tag 2026.07.08-0130-rolling \
#     --repo dozenos/dozenos-nightly-build \
#     --title "DozenOS nightly 2026.07.08-0130-rolling" \
#     --notes "Automated nightly build."
#
# What it does, in order:
#   1. Validate inputs and required env vars are present (fail loudly, no
#      fabricated fallback key).
#   2. Decode MINISIGN_SECRET_KEY (base64) to a mode-600 temp file under a
#      umask-077 temp dir, created with mktemp -- never in the workspace.
#   3. minisign -Sm <iso> -s <keyfile>  (password supplied via env, see
#      "MINISIGN_PASSWORD delivery" below) -> produces "<iso>.minisig".
#   4. Remove/shred the temp keyfile in a trap on EXIT, so it never survives
#      the step even if minisign fails partway.
#   5. gh release create <tag> <iso> <iso>.minisig <version-json> \
#        --repo <repo> --title <title> --notes <notes>
#      using GITHUB_TOKEN (same-repo publish -- no cross-repo PAT needed,
#      per CI-SECRETS.md and DISTRIBUTION.md).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sign-and-publish.sh --iso ISO_PATH --version-json JSON_PATH \
         --tag TAG --repo OWNER/REPO [--title TITLE] [--notes NOTES] \
         [--notes-file FILE]

Required env vars (never pass key material as an argument):
  MINISIGN_SECRET_KEY   base64-encoded minisign secret keyfile
                         (CI-SECRETS.md: org secret MINISIGN_SECRET_KEY)
  MINISIGN_PASSWORD     password unlocking MINISIGN_SECRET_KEY; MAY be empty
                         /unset for a no-passphrase key (CI-SECRETS.md)
  GITHUB_TOKEN           token for `gh release create` in the target repo
                         (workflow's own GITHUB_TOKEN; same-repo publish)

Required flags:
  --iso PATH             Built ISO file to sign and publish.
  --version-json PATH    Generated version.json (see gen-version-json.sh)
                         to attach as a release asset.
  --tag TAG              Release tag, e.g. 2026.07.08-0130-rolling
  --repo OWNER/REPO      Target repo for `gh release create`, e.g.
                         dozenos/dozenos-nightly-build

Optional flags:
  --title TITLE           Release title (default: "DozenOS nightly <tag>")
  --notes NOTES           Release notes text (default: generic message)
  --notes-file FILE       Release notes from a file (overrides --notes)
  -h, --help              Show this help and exit.
EOF
}

iso=""
version_json=""
tag=""
repo=""
title=""
notes=""
notes_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) iso="${2:?--iso requires a value}"; shift 2 ;;
    --version-json) version_json="${2:?--version-json requires a value}"; shift 2 ;;
    --tag) tag="${2:?--tag requires a value}"; shift 2 ;;
    --repo) repo="${2:?--repo requires a value}"; shift 2 ;;
    --title) title="${2:?--title requires a value}"; shift 2 ;;
    --notes) notes="${2:?--notes requires a value}"; shift 2 ;;
    --notes-file) notes_file="${2:?--notes-file requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "E: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for req in iso version_json tag repo; do
  if [ -z "${!req}" ]; then
    echo "E: --${req//_/-} is required" >&2
    exit 1
  fi
done
if [ ! -f "$iso" ]; then
  echo "E: --iso '$iso' does not exist or is not a regular file" >&2
  exit 1
fi
if [ ! -f "$version_json" ]; then
  echo "E: --version-json '$version_json' does not exist or is not a regular file" >&2
  exit 1
fi

# Fail loudly rather than silently signing with nothing / fabricating a key.
if [ -z "${MINISIGN_SECRET_KEY:-}" ]; then
  echo "E: MINISIGN_SECRET_KEY is unset or empty -- refusing to fabricate a throwaway key. See CI-SECRETS.md." >&2
  exit 1
fi
# MINISIGN_PASSWORD may legitimately be empty/unset: a no-passphrase minisign
# key. We feed an empty password to minisign below; if the key really is
# passphrase-protected, minisign fails loudly at signing time. So we do NOT
# hard-fail here -- that would make no-passphrase keys unusable.
if [ -z "${MINISIGN_PASSWORD:-}" ]; then
  echo "I: MINISIGN_PASSWORD empty/unset -- signing as a no-passphrase key." >&2
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "E: GITHUB_TOKEN is unset or empty -- required for 'gh release create'." >&2
  exit 1
fi
if ! command -v minisign >/dev/null 2>&1; then
  echo "E: minisign not found on PATH" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "E: gh (GitHub CLI) not found on PATH" >&2
  exit 1
fi

if [ -z "$title" ]; then
  title="DozenOS nightly ${tag}"
fi

# --- decode the secret key to a private temp file, umask-077, mktemp,
#     always removed on exit (success, failure, or signal). ---
keyfile=""
keydir=""
cleanup() {
  if [ -n "$keyfile" ] && [ -f "$keyfile" ]; then
    # Best-effort overwrite before unlink; shred if available, else zero it.
    if command -v shred >/dev/null 2>&1; then
      shred -u -- "$keyfile" 2>/dev/null || rm -f -- "$keyfile"
    else
      : > "$keyfile" 2>/dev/null || true
      rm -f -- "$keyfile"
    fi
  fi
  if [ -n "$keydir" ] && [ -d "$keydir" ]; then
    rm -rf -- "$keydir"
  fi
}
trap cleanup EXIT INT TERM

old_umask="$(umask)"
umask 077
keydir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/minisign-key.XXXXXX")"
keyfile="${keydir}/dozenos.minisign.sec"
printf '%s' "$MINISIGN_SECRET_KEY" | base64 -d > "$keyfile"
chmod 600 "$keyfile"
umask "$old_umask"

if [ ! -s "$keyfile" ]; then
  echo "E: decoded minisign secret key is empty -- check MINISIGN_SECRET_KEY encoding (expected: base64 -w0 of the secret keyfile)" >&2
  exit 1
fi

echo "I: signing $iso" >&2
# MINISIGN_PASSWORD delivery: minisign reads the key password from stdin
# when -W is not given and no TTY is attached; feeding it via a heredoc
# keeps the password out of argv (not visible in `ps`/process listings),
# unlike passing it as a CLI flag.
minisign -Sm "$iso" -s "$keyfile" <<EOF
${MINISIGN_PASSWORD:-}
EOF

minisig="${iso}.minisig"
if [ ! -f "$minisig" ]; then
  echo "E: expected signature file '$minisig' was not produced" >&2
  exit 1
fi
echo "I: wrote $minisig" >&2

# --- publish the GitHub Release (same-repo: GITHUB_TOKEN is sufficient,
#     no cross-repo PAT/BUILD_PAT needed -- see DISTRIBUTION.md). ---
notes_args=()
if [ -n "$notes_file" ]; then
  notes_args=(--notes-file "$notes_file")
elif [ -n "$notes" ]; then
  notes_args=(--notes "$notes")
else
  notes_args=(--notes "Automated DozenOS nightly build. See version.json for asset checksums.")
fi

echo "I: creating GitHub Release ${tag} in ${repo}" >&2
GH_TOKEN="$GITHUB_TOKEN" gh release create "$tag" \
  "$iso" "$minisig" "$version_json" \
  --repo "$repo" \
  --title "$title" \
  "${notes_args[@]}"

echo "I: release ${tag} published to ${repo}" >&2
