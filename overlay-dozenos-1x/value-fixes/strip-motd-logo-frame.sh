#!/usr/bin/env bash
#
# strip-motd-logo-frame.sh -- remove the VyOS box-drawing logo frame from the
# post-login MOTD template data/templates/login/default_motd.j2, keeping the
# version text.
#
# The upstream template draws a stylised "V" logo out of Unicode box-drawing
# characters around the version string:
#
#      ┌── ┐
#      . VyOS {{ version_data.version }}
#      └ ──┘  {{ version_data.release_train }}
#
# rename-transform.sh's four-form pass swaps the WORD `VyOS` -> `DozenOS`, but
# the frame graphic (┌── ┐ / └ ──┘ / the leading `. `) carries no brand text,
# so the generic pass leaves the VyOS-shaped mark intact. This overlay removes
# it, collapsing the three framed lines to a single frameless version line:
#
#      DozenOS {{ version_data.version }} {{ version_data.release_train }}
#
# The rest of the template (welcome line, doc/news/bug URLs, licensing note)
# is untouched -- only the logo frame goes.
#
# Pipeline position: this overlay runs AFTER rename-transform.sh (see
# ../apply-overlay.sh header), so the tree is already all-DozenOS by the time
# we get here; the block matched below is therefore the DozenOS form.
#
# Idempotent: a template already showing the frameless line is a no-op. Fails
# loudly if neither the expected framed block nor the already-stripped line is
# found (upstream redesigned the MOTD art -- re-review by hand).
#
# Usage:
#   strip-motd-logo-frame.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'strip-motd-logo-frame: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

REL="data/templates/login/default_motd.j2"
F="$TARGET/$REL"
[ -f "$F" ] || die "expected file not found (upstream sync drift?): $F"

python3 - "$F" "$REL" <<'PYEOF'
import sys

path, rel = sys.argv[1], sys.argv[2]

FRAMED = (
    "   ┌── ┐\n"
    "   . DozenOS {{ version_data.version }}\n"
    "   └ ──┘  {{ version_data.release_train }}\n"
)
FRAMELESS = "   DozenOS {{ version_data.version }} {{ version_data.release_train }}\n"

with open(path, encoding="utf-8") as fh:
    text = fh.read()

if FRAMED in text:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text.replace(FRAMED, FRAMELESS))
    print(f"stripped MOTD logo frame: {rel}")
elif FRAMELESS in text:
    print(f"already stripped (idempotent no-op): {rel}")
else:
    sys.exit(
        "strip-motd-logo-frame: neither the expected framed block nor the "
        f"already-stripped line found in {rel} -- upstream MOTD art changed, "
        "re-review by hand"
    )
PYEOF
