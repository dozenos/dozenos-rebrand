#!/usr/bin/env bash
#
# suffix-openssl-version.sh -- make the DozenOS-built openssl version
# strictly greater than Debian's by appending +dozenos1 to the changelog
# version before dpkg-buildpackage runs.
#
# WHY (2026-07-11/12 image-build outage): the openssl recipe rebuilds
# Debian's own source (salsa tag debian/openssl-<ver>, FIPS patch on top)
# at the IDENTICAL version string Debian ships. The ephemeral repo is
# pinned at 999, so once the Debian archive serves the same version
# (bookworm point release 2026-07-11 moved 3.0.20-1~deb12u2 into main --
# exactly what debootstrap installs), apt sees two same-version instances
# with different hashes, prefers the 999 one, classifies the switch as a
# DOWNGRADE, and `lb build`'s non-interactive apt refuses -- every flavor's
# image build died. Worse, at equal versions apt may simply KEEP Debian's
# binary, silently shipping a non-FIPS openssl. A strictly-greater version
# makes apt upgrade to the FIPS build cleanly and permanently.
#
# openssl is the only base-set package built from a same-version Debian
# source; the other salsa-pinned recipes either pin versions bookworm does
# not ship or are not in the debootstrap base set (nothing installed to
# "downgrade" -- they install fresh from the 999 repo).
#
# Idempotent: no-op if build_cmd already carries the suffix step. Fails
# loudly if the expected build_cmd is missing (upstream drift).
#
# Usage:
#   suffix-openssl-version.sh <target-tree>

set -euo pipefail

TARGET="${1:-}"
[ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "usage: $0 <target-tree>" >&2; exit 2; }
TOML="$TARGET/scripts/package-build/openssl/package.toml"
[ -f "$TOML" ] || { echo "suffix-openssl-version: $TOML not found" >&2; exit 1; }

SUFFIXED="build_cmd = \"sed -i '1s/)/+dozenos1)/' debian/changelog && dpkg-buildpackage -us -uc -tc -b\""
PLAIN='build_cmd = "dpkg-buildpackage -us -uc -tc -b"'

if grep -qF "$SUFFIXED" "$TOML"; then
  echo "suffix-openssl-version: already suffixed (no-op)"
  exit 0
fi
if ! grep -qF "$PLAIN" "$TOML"; then
  echo "suffix-openssl-version: expected openssl build_cmd not found -- upstream drift, refusing to continue" >&2
  exit 1
fi
python3 - "$TOML" <<PYEOF
import sys
path = sys.argv[1]
src = open(path).read()
open(path, 'w').write(src.replace('''$PLAIN''', '''$SUFFIXED'''))
PYEOF
echo "suffix-openssl-version: openssl version will build as <debian-version>+dozenos1"
