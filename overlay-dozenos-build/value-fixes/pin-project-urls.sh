#!/usr/bin/env bash
#
# pin-project-urls.sh -- point data/defaults.toml's user-facing project URLs
# at hosts the DozenOS org actually controls.
#
# WHY (user decision 2026-07-11): the four-form transform turns the upstream
# project URLs into dozenos.io / support.dozenos.io / dozenos.dev /
# docs.dozenos.io / blog.dozenos.io -- domains NOBODY in this project owns.
# They are baked into every image's os-release, so anyone registering one of
# those domains could impersonate the project to its users. Rewrite them to
# the GitHub properties the org controls.
#
# dozenos_mirror (packages.dozenos.net) is intentionally NOT touched: it is
# a build-time apt-source default that CI always overrides with the
# ephemeral localhost repo, not a user-facing URL, and the built image ships
# with empty apt sources.
#
# Idempotent: no-op when already pinned. Fails loudly if a listed key is
# missing from defaults.toml (upstream drift).
#
# Usage:
#   pin-project-urls.sh <target-tree>

set -euo pipefail

TARGET="${1:-}"
[ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "usage: $0 <target-tree>" >&2; exit 2; }
DEFAULTS="$TARGET/data/defaults.toml"
[ -f "$DEFAULTS" ] || { echo "pin-project-urls: $DEFAULTS not found" >&2; exit 1; }

pin() {
  local key="$1" url="$2"
  if grep -q "^${key} = \"${url}\"$" "$DEFAULTS"; then
    echo "pin-project-urls: ${key}: already pinned (no-op)"
    return 0
  fi
  grep -q "^${key} = " "$DEFAULTS" || {
    echo "pin-project-urls: ${key} missing from data/defaults.toml -- upstream drift, refusing to continue" >&2
    exit 1
  }
  sed -i "s|^${key} = .*|${key} = \"${url}\"|" "$DEFAULTS"
  echo "pin-project-urls: ${key} -> ${url}"
}

pin website_url        "https://dozenos.github.io/dozenos-nightly-build"
pin support_url        "https://github.com/dozenos/dozenos-nightly-build/issues"
pin bugtracker_url     "https://github.com/dozenos/dozenos-nightly-build/issues"
pin documentation_url  "https://github.com/dozenos"
pin project_news_url   "https://dozenos.github.io/dozenos-nightly-build"
