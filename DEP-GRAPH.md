# DEP-GRAPH.md — dependency-graph coverage/correctness completion (item #16)

Item #15 (`REBUILD-DISPATCH.md`) shipped `dep-graph/dep-graph.json` +
`dep-graph/resolve-rebuild-set.sh` as a **bootstrap**: the stable JSON
shape + resolver CLI, populated with only the cross-package edges already
known from the local-build powerloop. This document records item #16's
work completing that graph: full node coverage, new real edges (each with
source provenance), a separate ISO-hard-deps section, the `+git`
auto-stamp/exact-pin interaction (root cause + fix), and graph-integrity
validation. **Neither the JSON shape nor the resolver's CLI/behavior
changed** — only the data grew, plus one new top-level section
(`iso_hard_deps`) that is deliberately outside `reverse_dependencies` (see
§3).

## 1. Node enumeration (COMPLETE)

Reproduced the mode-B `dozenos-build` tree fresh via:

```sh
dozenos-rebrand/mirror-push.sh https://github.com/vyos/vyos-build.git \
  --target dozenos-build --build-repo --dry-run --work <scratch>
```

`find <clone>/scripts/package-build -name package.toml` → **48 recipe
directories**, each with exactly one `package.toml`. Walking every
`[[packages]]` block's `name =` field:

- **47 non-`linux-kernel` recipe directories.** For every one of these the
  generic `scripts/package-build/build.py` is the build driver, and it has
  **no `--packages` filter** (confirmed by reading the whole file — it
  loops `for package in packages: build_package(...)` unconditionally).
  The dispatchable/buildable unit is therefore the **recipe directory
  name** (what `rebuild-dispatch.yml`'s build job actually does:
  `cd scripts/package-build/<pkg> && python3 ../build.py`), not each
  internal block, for recipes with more than one block (`frr`
  [libyang+frr], `hostap` [wpa+hostap], `netfilter`
  [pkg-libnftnl+pkg-nftables], `tacacs` [3 blocks], `vpp`
  [dozenos-vpp-patches+vpp], `isc-kea`/`isc-dhcp` [1 block each]).
- **`linux-kernel` is the one exception.** Its own bespoke
  `scripts/package-build/linux-kernel/build.py` *does* support
  `--packages <name>` (`args.add_argument('--packages', nargs='+', ...)`,
  filtering `pkg['name'] in args.packages`) — confirmed by reading that
  file directly. Its `package.toml` declares **16 blocks**: `linux-kernel`,
  `linux-firmware`, `accel-ppp-ng`, `nat-rtsp`, `qat`, `igb`, `ixgbe`,
  `ixgbevf`, `i40e`, `ice`, `iavf`, `jool`, `mlnx`, `realtek-r8126`,
  `realtek-r8152`, `ipt-netflow`. Each is its own coverage node (this is
  the pre-existing, item #15-documented "naming wrinkle" — preserved,
  not changed).

**Total node set: 47 + 16 = 63 unique C2 package/block identifiers.**

Before this item, only 17 of the 63 appeared anywhere in
`dep-graph.json` (as a key or a dependents-array value): `vpp`,
`linux-kernel`, `strongswan`, `frr` (as a value), and the 13 already-known
`linux-kernel` OOT dependents (missing `igb`/`qat`, exactly as the
bootstrap's own comment flagged). **After this item: 63/63.** Every one of
the 46 previously-missing identifiers now appears at least once, either as
a genuine new edge's key/value (see §2) or as an explicit leaf
(`"name": []`) — never silently omitted. `dep-graph/validate-dep-graph.sh
--tree <scripts/package-build>` re-runs this exact check on demand (see
§4); `test/test-resolve-rebuild-set.sh` asserts it against the sibling
local `vyos-build` checkout on this machine.

## 2. New edges beyond the #15 bootstrap

Each edge below was verified from source — either the actual build
script/`package.toml`, or (preferred, where reachable) the real upstream
`debian/control`. No edge was invented from inference alone when a
stronger source was available.

| Edge | Provenance |
|---|---|
| `dozenos-vpp-patches` → `vpp` | `vpp`'s "vpp" block `pre_build_hook`: `` rsync -av ../dozenos-vpp-patches/patches/vpp/ ../patches/vpp/ ``; `build_cmd` then `git am`s every file there before `make ... pkg-deb`. `dozenos-vpp-patches` (unlike the bootstrap's existing `vpp` key, which is the FDio/vpp upstream fetch) is a REAL, individually dozenos-org-mirrored repo (`overlay-dozenos-build/value-fixes/pin-helper-scm-urls.sh` lists it), so it is the actual client_payload.package a self-sync would send for a patch change. Transitively reaches `accel-ppp-ng` via the existing `vpp` → `accel-ppp-ng` edge. |
| `wpa` → `hostap` | `hostap/build.sh`: `SRC=hostap`, `SRC_DEB=wpa`, then `cp -a ${SRC_DEB}/debian ${SRC}` — copies wpa's (salsa.debian.org/debian/wpa) Debian packaging wholesale into hostap's source before building. |
| `pkg-libnftnl` → `pkg-nftables` | `netfilter/package.toml`'s `pkg-nftables` block `build_cmd`: `` sudo dpkg -i ../libnftnl*.deb; sudo mk-build-deps ...; dpkg-buildpackage ... `` — installs the freshly built libnftnl `.deb` before building nftables. |
| `libyang` → `frr` (block-name form, additive alongside the existing `libyang3` deb-name key) | FRRouting/frr's real `debian/control` (tag `frr-10.6.1`): `` Build-Depends: ... libyang-dev (>= 3.0.3) \| libyang2-dev (>= 2.1.128), ... `` — verified against the actual upstream packaging metadata, not just the local `dpkg -i ../*.deb` step. |
| `libtacplus-map` → `libpam-tacplus`, `libnss-tacplus` (block-name form, additive alongside the existing `libtacplus-map1` deb-name key) | `vyos/libpam-tacplus`'s real `debian/control`: `Package: libpam-tacplus` `` Depends: ..., libtac2, libtacplus-map1 ``. `vyos/libnss-tacplus`'s real `debian/control`: `Package: libnss-tacplus` `` Depends: ..., libtac2 (>= 1.4.1~), libtacplus-map1, ... ``. |
| `libpam-tacplus` → `libnss-tacplus` (block-name form) | Same `libnss-tacplus` `debian/control` Depends line above (the `libtac2` dependency — `libtac2` is co-produced BY the `libpam-tacplus` source build itself, confirmed by that same source's `debian/control` also declaring `Package: libtac2`). |
| `linux-kernel` → **+ `igb`, `qat`** | The #15 bootstrap's own comment already flagged these as real blocks left for #16. Evidence of kernel-ABI coupling: `build-intel-nic.sh` (the SAME script `i40e`/`ice`/`iavf`/`ixgbe`/`ixgbevf` already use) reads `kernel-vars` for `KERNEL_DIR` and runs `` make KSRC=${KERNEL_DIR} BUILD_KERNEL=${KERNEL_VERSION}${KERNEL_SUFFIX} ... -C src install ``; `build-intel-qat.sh` likewise requires `KERNEL_DIR` and applies "patches for newer kernels/backports". |

Full per-edge write-ups (longer, with the exact quotes) live in
`dep-graph/dep-graph.json`'s own `_notes` object (keys prefixed
`item16_*`) — this table is the summary.

### Considered but NOT added (unverified — flagged, not invented)

Recorded verbatim in `dep-graph.json`'s `_notes.unverified_needs_human`:
`isc-dhcp`'s `debian/control` was not fetched (no cross-package Depends
found via local inspection, but not confirmed against the real upstream
packaging); `openssl`'s local FIPS patch was not checked against every
other recipe's `Build-Depends` for a FIPS-specific requirement; the
remaining single-block Debian-tracked C2 recipes (`squid`, `net-snmp`,
`keepalived`, `dropbear`, `ethtool`, `wide-dhcpv6`, `ndppd`, …) were
enumerated as coverage leaves but their `debian/control` was not
individually cross-referenced against every other recipe's binary package
names. A real edge among these is possible but unconfirmed — do not
assume completeness beyond what `_notes` explicitly documents.

### Same-source co-production (pre-existing, clarified — not changed)

Two of the #15 bootstrap's existing edges model something that turns out,
on tracing back to the real `debian/control`, to be **same-source
co-production** rather than a genuine cross-package/cross-mirror trigger:

- `isc-kea-common` → `{isc-kea-dhcp4, isc-kea-dhcp6, isc-kea-dhcp-ddns,
  isc-kea-hooks}`: all five are binary packages of the ONE `isc-kea`
  source build (`isc-kea-dhcp4`'s real `debian/control`:
  `` Depends: isc-kea-common (= ${binary:Version}), ... `` — an
  intra-source exact pin that always self-satisfies).
- `libtac2` → `libpam-tacplus`: `libtac2` is itself a binary package of
  the `libpam-tacplus` SOURCE build (confirmed in that same
  `debian/control`), so this entry is a harmless, conservative
  self-reference (rebuilding `libpam-tacplus` is what produces a `libtac2`
  change in the first place).

Both are **left exactly as shipped** (removing them would change an
already-tested closure for no correctness gain — they are redundant, not
wrong) but are now clarified in `_notes` with the real
`debian/control` evidence, rather than left as an unexplained oddity.

### Flagged, not fixed by item #16 — CLOSED by item #30

Investigating these edges surfaced a real, pre-existing correctness gap in
the **already-landed item #15** `rebuild-dispatch.yml`: its build job does
a literal `cd scripts/package-build/${{ matrix.pkg }}` for every
non-`linux-kernel` matrix entry, which requires `matrix.pkg` to be an
actual directory name. Several bootstrap **values** are not directory
names — `python3-vici`, `libtac2`, `libtacplus-map1`,
`isc-kea-common`/`isc-kea-dhcp4`/`isc-kea-dhcp6`/`isc-kea-dhcp-ddns`/`isc-kea-hooks`,
`libyang3` — so if any of these is ever the sole new entry in a resolved
matrix (e.g. resolving `strongswan` includes `python3-vici`), that `cd`
would fail. This was **out of item #16's scope** (editing
`rebuild-dispatch.yml` itself, an already-landed #15 file, was not one of
item #16's deliverables) and was recorded as
`_notes.item16_rebuild_dispatch_directory_mapping_gap` in
`dep-graph.json` with two concrete remediation options for whoever picked
it up next.

**Item #30 picked it up and closed it**: new `dep-graph.json` top-level
`build_units` section (a `node_to_unit` map, every node → its real
`{recipe, kernel_block}`, derived from a freshly reproduced mode-B tree +
real `debian/control`/`package.toml` provenance, one node — `squid` —
explicitly flagged unmappable rather than invented) + new
`dep-graph/nodes-to-build-units.sh` (wraps `resolve-rebuild-set.sh`,
maps+dedups the resolved closure into build units) + `rebuild-dispatch.yml`
itself edited to build by unit. Full write-up, worked examples, the
`squid`/"63→62 units" reconciliation, and the sender-reconciliation
decision: `REBUILD-DISPATCH.md` §11. `resolve-rebuild-set.sh` and this
document's own edge list / `iso_hard_deps` are all unaffected — item #30
is purely additive on top of item #16's completed coverage.

## 3. ISO hard deps (`iso_hard_deps`, a section separate from `reverse_dependencies`)

A **different concern** from rebuild fan-out: packages that must always be
*present and resolvable* in the generic ISO / its ephemeral apt repo
(`release/make-ephemeral-apt-repo.sh`, item #13), regardless of which
package just changed. These are `Depends:`/pin relationships in package
metadata and the ISO build-type package lists, **not** build-time source
dependencies — conflating them with `reverse_dependencies` would make
`resolve-rebuild-set.sh` rebuild the wrong things on an unrelated
`Depends:` change, so they live in their own top-level
`dep-graph.json` key, `iso_hard_deps`, verified against the real sources:

1. **`dozenos-1x` (source `vyos-1x`) hard-`Depends` the full vpp set.**
   `vyos-1x`'s real `debian/control` (rolling branch), `Package: vyos-1x`
   `Depends:` block bracketed by literal `# For "vpp"` / `# End "vpp"`
   comments: `libvppinfra, python3-vpp-api, vpp, vpp-crypto-engines,
   vpp-dev, vpp-plugin-core, vpp-plugin-dpdk`. All seven must be staged
   into `packages/` (matches `RETROSPECTIVE.md` §2e's own account of
   `vpp-dev` being wrongly stripped once and restored).
2. **`development`/`stream` build types require `dozenos-1x-smoketest`.**
   `data/build-types/development.toml` and `data/build-types/stream.toml`
   both list `"dozenos-1x-smoketest"` directly in their `packages` array
   (verified on the reproduced tree).
3. **`vyatta-cfg` exact-pins `bash-completion (= 1:2.8-6)`.**
   `vyatta-cfg`'s real `debian/control` (rolling branch), `Package:
   vyatta-cfg` `Depends:` includes literally
   `` bash-completion (= 1:2.8-6), ``. This is the pin the `+git`
   un-stamp fix (§5) protects.

**How consumed**: `scripts/image-build/build-dozenos-image` resolves every
package-list entry against whatever apt source(s) it is given — the
ephemeral, `file://`-only repo `make-ephemeral-apt-repo.sh` assembles from
freshly built `.deb`s for DozenOS-built packages, or the image's normal
Debian apt sources for stock Debian packages. `package-smoketest.yml` /
any future ISO-build gate **should** assert all three resolve before
declaring a build green; wiring that gate is not part of this item (this
item ships the data the gate would consume).

## 4. Graph-integrity validation (`dep-graph/validate-dep-graph.sh`, new)

A new, standalone script (network-free, read-only) asserting the graph
itself is well-formed, independent of any one resolver query:

1. Valid JSON with a `reverse_dependencies` object.
2. No self-loop (`"a": ["a", ...]`).
3. The graph is a DAG — no cycle among any two-or-more distinct keys (a
   real, shipped cycle would be a modeling bug; the resolver's own bounded
   BFS already tolerates a cycle *at query time*, which is a different,
   complementary concern — that a hypothetical future cycle cannot hang
   the resolver, not that the shipped graph should ever contain one).
4. Every dependents-array entry is a non-empty string.
5. **Optional**, with `--tree <scripts/package-build>`: full coverage —
   every real recipe directory name (or, for `linux-kernel`, every block
   name) appears somewhere in the graph. This is a *subset* check (every
   recipe present in the given tree must be covered), so it tolerates a
   locally slightly-stale checkout without ever tolerating a real
   regression on anything it does contain.

```
$ dep-graph/validate-dep-graph.sh
OK: 59 key(s), 83 known identifier(s) total, no self-loops, no cycles, all dependents well-formed

$ dep-graph/validate-dep-graph.sh --tree <scripts/package-build>
OK: 59 key(s), 83 known identifier(s) total, no self-loops, no cycles, all dependents well-formed, full coverage verified against <tree>
```

Confirmed it actually *catches* a broken graph (not just always passing)
against synthetic self-loop and 2-cycle fixtures — see
`test/test-resolve-rebuild-set.sh` [18].

`resolve-rebuild-set.sh` itself needed **no changes** — the #15 bootstrap
already correctly computes the transitive closure over however many edges
the graph contains; item #16 only grew the data, exactly as the #15
header predicted ("the JSON shape and resolver behavior are not expected
to change when #16 lands, only the edge list should grow").

## 5. The `+git` auto-stamp vs. `vyatta-cfg`'s exact pin

### Root cause

`rename-transform.sh` carries an **optional** version-stamp hook
(`--stamp <DATE.SHA>` / `REBRAND_VERSION_STAMP` env var), documented in
its own header as item 4 of the transform pipeline:

```sh
if [ -n "$STAMP" ] && [ -f "$TARGET/debian/changelog" ]; then
  if ! head -1 "$TARGET/debian/changelog" | grep -q '+git'; then
    sed -i "1s/(\([^)]*\))/(\1+git${STAMP})/" "$TARGET/debian/changelog"
  fi
fi
```

This appends `+git<DATE.SHA>` to a package's newest `debian/changelog`
entry so apt sees a monotonically increasing version for a branch-tracked
C2 recipe. `RETROSPECTIVE.md` §(c) already documented the interaction this
breaks: `vyatta-cfg` exact-pins `bash-completion (= 1:2.8-6)` (§3 above);
`bash-completion` genuinely **is** rebuilt by DozenOS
(`scripts/package-build/bash-completion/`, pinned to the OLDER
`debian/2.8-6` specifically because current Debian ships a newer
`1:2.11-6` — `recipe-worklist.md`'s own notes, and it produced a real
`bash-completion_2.8-6+git20260707.3728429_all.deb` during the local build
trial when the stamp hook was invoked by hand). A stamped
`bash-completion` version (`1:2.8-6+git...`) no longer satisfies
`= 1:2.8-6` — this is a live risk, **not** a "comes straight from Debian,
never rebuilt, no fix needed" case.

### Where `--stamp` is (and is not) currently wired

Grepped the whole toolkit: **no script in `dozenos-rebrand/` currently
passes `--stamp` or sets `REBRAND_VERSION_STAMP`** —
`wire-prebuild-hooks.sh`'s inserted `pre_build_hook` line is always
`` "/dozenos-rebrand/rename-transform.sh ." `` (no `--stamp`), and no
`overlay-dozenos-build/new-files/.github/workflows/*.yml` sets the env var either. So
the auto-stamp is **dormant in the shipped CI toolkit today** — the risk
is real for the *mechanism* (and was real during the separate, manually-run
local build trial `RETROSPECTIVE.md` documents) but not currently live in
mode-B CI as shipped.

### Fix codified (defense-in-depth, idempotent)

Rather than leave the guard undocumented and hope a future item that wires
`--stamp` in remembers this interaction, the general rule
`RETROSPECTIVE.md` already recorded ("before applying the `+git` stamp
hook to a recipe, check whether any *other* package in the closure
depends on it with an exact `=` pin; if so, skip stamping that recipe")
is now codified directly in the mechanism:

- **`rebrand-map.conf`**: new `EXACT_PIN_STAMP_EXCLUDE=("bash-completion")`
  data array (the Debian *source* package name, from
  `debian/changelog`'s own `Source:` field — not necessarily the recipe
  directory name, though today they match).
- **`rename-transform.sh`**, stamp step (§4 of its own pipeline): reads
  the changelog's source name and skips stamping (logging why, to stderr)
  whenever it matches an `EXACT_PIN_STAMP_EXCLUDE` entry — **regardless**
  of whether `--stamp`/`REBRAND_VERSION_STAMP` was passed. This is a hard
  exclusion, not an opt-out, so the bug class cannot resurface even if a
  future CI step starts passing `--stamp` broadly.

Verified manually and via `test/test-resolve-rebuild-set.sh` [20]:

```
$ rename-transform.sh <bash-completion-tree> --stamp 20260707.deadbee
rename-transform: skipping +git version-stamp for 'bash-completion' -- exact-=-pinned elsewhere (...)
$ head -1 <bash-completion-tree>/debian/changelog
bash-completion (1:2.8-6) unstable; urgency=medium      # unchanged

$ rename-transform.sh <ddclient-tree> --stamp 20260707.deadbee
$ head -1 <ddclient-tree>/debian/changelog
ddclient (3.11.2-1+git20260707.deadbee) unstable; urgency=medium   # stamped normally
```

Non-excluded recipes are completely unaffected — the guard only changes
behavior for the one currently-listed source.

## 6. Verification performed this cycle

- `jq empty dep-graph/dep-graph.json` / `python3 -m json.tool` — valid.
- `dep-graph/validate-dep-graph.sh` — clean (59 keys, 83 known
  identifiers, no self-loops/cycles).
- `dep-graph/validate-dep-graph.sh --tree` against both the mode-B
  reproduced clone and the local `vyos-build` sibling checkout — full
  coverage, no gaps.
- `shellcheck` on `resolve-rebuild-set.sh`, `validate-dep-graph.sh`,
  `rename-transform.sh` — clean.
- Reproduced the mode-B tree fresh
  (`mirror-push.sh ... --build-repo --dry-run`) — same 9 documented
  residual `vyos` hits as item #15 (no new residual), nothing pushed, no
  repo created/touched, no key material handled.
- `grep -rni vyos` over every file this item touched — 0 hits (`vyatta`
  preserved, as required).
- Full toolkit test suite: **219/219 assertions across 8 test files**
  (199 pre-item-#16 baseline + 20 new in
  `test/test-resolve-rebuild-set.sh`: 6 new-edge closures, the
  igb/qat-in-linux-kernel-closure check, the graph-validator clean-run +
  its 2 broken-graph detection fixtures, the tree-coverage check, and the
  2 stamp-fix assertions).

## 7. What did NOT change

- `dep-graph.json`'s JSON shape (`reverse_dependencies` map) — unchanged,
  only grown, plus the new sibling `iso_hard_deps` top-level key.
- `resolve-rebuild-set.sh` — byte-for-byte unchanged; the existing
  transitive-closure BFS already handles the larger graph correctly (see
  §4 and `test/test-resolve-rebuild-set.sh`'s new closures).
- `rebuild-dispatch.yml` (item #15) — not edited (see §2's flagged gap).
- No key material handled, no repo pushed/created, no GitHub write
  operation performed anywhere in this item.
