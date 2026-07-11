#!/usr/bin/env bash
#
# replace-eula.sh -- replace the upstream EULA payload in every build-type
# toml with the DozenOS-authored end-user notice below.
#
# WHY (LEGAL, user decision 2026-07-11): the upstream EULA is VyOS Inc.'s
# own legal document -- NOT GPL-licensed code -- so shipping a four-form
# renamed copy is (a) verbatim reuse of their copyrighted legal text,
# (b) a false statement that a "DozenOS Inc." exists at the upstream
# company's real registered address, and (c) in release.toml, their entire
# sales/contracting-entity table with renamed fake entities. The transform
# cannot fix a document that must simply not be shipped; this fix swaps the
# payload for a short self-authored notice (GPL pointer + no-warranty +
# independent-project statement).
#
# Mechanism: for every data/build-types/*.toml carrying an
# [[includes_chroot]] block whose path is 'usr/share/dozenos/EULA', the
# data = '''...''' payload is replaced. Idempotent (payload already ours =
# no-op). Fails loudly if NO toml carries an EULA block (upstream drift).
#
# Usage:
#   replace-eula.sh <target-tree>

set -euo pipefail

TARGET="${1:-}"
[ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "usage: $0 <target-tree>" >&2; exit 2; }
BT_DIR="$TARGET/data/build-types"
[ -d "$BT_DIR" ] || { echo "replace-eula: $BT_DIR not found" >&2; exit 1; }

python3 - "$BT_DIR" <<'PYEOF'
import glob, os, sys

bt_dir = sys.argv[1]

NOTICE = """
DozenOS END USER NOTICE

DozenOS is a community-built network operating system assembled from
free and open source software. Each component is governed by its own
license (the GNU GPL, the GNU LGPL, and other OSI-approved licenses).
The corresponding source code is available from the public repositories
at https://github.com/dozenos.

DozenOS is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE, to the extent permitted by applicable
law.

DozenOS is an independent community project. It is not affiliated with,
endorsed by, or supported by any commercial vendor, and no commercial
entity stands behind it.
"""

MARKER = "path = 'usr/share/dozenos/EULA'"
OPEN = "data = '''"
CLOSE = "'''"

replaced = 0
for path in sorted(glob.glob(os.path.join(bt_dir, '*.toml'))):
    src = open(path).read()
    i = src.find(MARKER)
    if i < 0:
        continue
    j = src.find(OPEN, i)
    if j < 0:
        print(f'replace-eula: {path}: EULA path without data block', file=sys.stderr)
        sys.exit(1)
    k = src.find(CLOSE, j + len(OPEN))
    if k < 0:
        print(f'replace-eula: {path}: unterminated data block', file=sys.stderr)
        sys.exit(1)
    payload = src[j + len(OPEN):k]
    if payload == NOTICE:
        print(f'replace-eula: {os.path.basename(path)}: already replaced (no-op)')
        replaced += 1
        continue
    open(path, 'w').write(src[:j + len(OPEN)] + NOTICE + src[k:])
    print(f'replace-eula: {os.path.basename(path)}: EULA payload replaced')
    replaced += 1

if replaced == 0:
    print('replace-eula: no build-type toml carries an EULA block -- upstream drift, refusing to continue', file=sys.stderr)
    sys.exit(1)
PYEOF
