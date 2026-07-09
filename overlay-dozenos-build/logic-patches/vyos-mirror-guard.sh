#!/usr/bin/env bash
#
# vyos-mirror-guard.sh -- add the "empty package-mirror" guard to
# scripts/image-build/build-dozenos-image (post-rename path; the entrypoint's
# own filename rename `build-vyos-image` -> `build-dozenos-image` is handled
# automatically by rename-transform.sh's four-form pass -- see audit item #18
# / overlay-dozenos-build/MANIFEST.md's "ACCEPTED" decision -- this script only adds logic,
# it never touches the rename itself).
#
# WHY (audit item #13): upstream vyos-build's `build-vyos-image` writes the
# package-mirror apt-source line UNCONDITIONALLY:
#
#   vyos_repo_entry = "deb {vyos_mirror} {vyos_branch} main\n".format(...)
#   ...
#   with open(apt_file, 'w') as f:
#       f.write(vyos_repo_entry)
#
# If `vyos_mirror` (post-transform: `dozenos_mirror`, from `build_config`,
# ultimately the `--vyos-mirror`/`--dozenos-mirror` CLI flag or
# data/defaults.toml) is empty or unset, this produces a MALFORMED apt source
# line ("deb  rolling main", no host) instead of simply omitting the entry.
#
# DECISION: KEEP this guard (do not drop it as "CI-unneeded"). Rationale:
#   - In mode-B CI the ISO build always passes a non-empty ephemeral in-job
#     package-repo URL, so the guard's `if` branch is taken and behaves
#     IDENTICALLY to the unconditional upstream code -- zero behavior change,
#     zero cost, in the path that matters most.
#   - It is NOT CI-only, though: BUILD-LOCAL.md documents `--dozenos-mirror ""`
#     (no package mirror at all) as the supported local/dev "zero-vyos build"
#     smoke-test invocation (Strategy B, no apt mirror -- DozenOS ships as a
#     whole-image upgrade, not an apt-tracked distro). Dropping the guard
#     would break that documented local workflow.
#   - The guard is a pure safety net (an `if`/`else` around existing code, no
#     new external dependency, no behavior change on the non-empty path) --
#     there is no meaningful complexity cost to carrying it forward, so the
#     "simpler to drop it" argument does not outweigh the local-dev breakage
#     it would cause.
#
# Idempotent: if the guard's `if build_config.get(` line is already present,
# this script no-ops (exit 0, prints "already applied"). Fails loudly (exit
# non-zero) if the expected unconditional pre-guard code is not found AND the
# guard is not already present -- upstream sync drift must be re-reviewed by
# hand, not silently skipped.
#
# Usage:
#   vyos-mirror-guard.sh <target-tree>
#
# LOCAL ONLY -- no network, no git, pure text edit.
set -euo pipefail

die() { printf 'vyos-mirror-guard: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

F="$TARGET/scripts/image-build/build-dozenos-image"
[ -f "$F" ] || die "expected file not found (was the rename applied?): $F"

if grep -q "if build_config.get('dozenos_mirror')" "$F"; then
  echo "vyos-mirror-guard: already applied (idempotent no-op)"
  exit 0
fi

python3 - "$F" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, "r") as fh:
    content = fh.read()

# Exact unconditional block emitted by a fresh rename-transform.sh pass
# (verified by simulating the transform against pristine upstream content --
# see dozenos-rebrand/overlay-dozenos-build/MANIFEST.md item #13). Matched with the
# original indentation (8 spaces) preserved via the capture group.
old_block = (
    "        # Add the additional repositories to package lists\n"
    "        print(\"I: Setting up DozenOS repository APT entries\")\n"
    "        dozenos_repo_entry = \"deb {dozenos_mirror} {dozenos_branch} main\\n\".format(**build_config)\n"
    "        dozenos_repo_entry += \"deb-src {dozenos_mirror} {dozenos_branch} main\\n\".format(**build_config)\n"
    "\n"
    "        apt_file = defaults.DOZENOS_REPO_FILE\n"
    "\n"
    "        if debug:\n"
    "            print(f\"D: Adding these entries to {apt_file}:\")\n"
    "            print(\"\\t\", dozenos_repo_entry)\n"
    "\n"
    "        with open(apt_file, 'w') as f:\n"
    "            f.write(dozenos_repo_entry)\n"
)

new_block = (
    "        # Add the additional repositories to package lists\n"
    "        if build_config.get('dozenos_mirror'):\n"
    "            print(\"I: Setting up DozenOS repository APT entries\")\n"
    "            dozenos_repo_entry = \"deb {dozenos_mirror} {dozenos_branch} main\\n\".format(**build_config)\n"
    "            dozenos_repo_entry += \"deb-src {dozenos_mirror} {dozenos_branch} main\\n\".format(**build_config)\n"
    "\n"
    "            apt_file = defaults.DOZENOS_REPO_FILE\n"
    "\n"
    "            if debug:\n"
    "                print(f\"D: Adding these entries to {apt_file}:\")\n"
    "                print(\"\\t\", dozenos_repo_entry)\n"
    "\n"
    "            with open(apt_file, 'w') as f:\n"
    "                f.write(dozenos_repo_entry)\n"
    "        else:\n"
    "            print(\"I: dozenos_mirror empty -- skipping package-repo apt entry (zero-mirror build)\")\n"
)

if old_block not in content:
    sys.stderr.write(
        "vyos-mirror-guard: expected pre-guard block not found -- "
        "upstream sync drift, re-review scripts/image-build/build-vyos-image by hand\n"
    )
    sys.exit(2)

content = content.replace(old_block, new_block, 1)
with open(path, "w") as fh:
    fh.write(content)

print("vyos-mirror-guard: guard applied")
PYEOF
