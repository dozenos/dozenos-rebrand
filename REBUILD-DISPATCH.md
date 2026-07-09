# REBUILD-DISPATCH.md — DozenOS INCREMENTAL rebuild fan-out (item #15)

The RECEIVING half of item #14's decentralized self-sync design. Every
`dozenos/*` mirror's generated `sync.yml` (`sync.yml.template`, see
`SYNC.md`) already dispatches a `repository_dispatch` into `dozenos-build`
whenever it self-syncs and finds a real change. This document specifies what
`dozenos-build` does with that event: resolve the changed package's
dependents through a dependency graph, rebuild ONLY that resolved set (never
`scripts/package-build/*` in full), and kick off an ISO rebuild from the
result. Cross-references: `SYNC.md` (item #14, the sender), `WORKFLOW-POLICY.md`
(where DozenOS's own `.github/workflows/*` content is allowed to come from),
`overlay/MANIFEST.md` (`new-files/` placement), `CI-SECRETS.md` (`BUILD_PAT`),
`ISO-BUILD.md`/`DISTRIBUTION.md` (item #13/#9, the ISO-build mechanism this
item's job C triggers), and item #16 (dep-graph coverage completion + real
validation this item hands off to).

## 1. End-to-end flow

```
dozenos/<some-mirror> self-syncs (sync.yml, item #14)
  -> mirror-push.sh finds a real change vs the existing mirror
  -> gh api repos/dozenos/dozenos-build/dispatches
       event_type: dozenos-package-rebuild
       client_payload: { "package": "<that mirror's own repo name>" }
     (runtime-minted org GitHub App token -- cross-repo dispatch, see
      CI-SECRETS.md §4)
        |
        v
dozenos-build: overlay/new-files/.github/workflows/rebuild-dispatch.yml (item #15, THIS document)
  job A "resolve"
    -> checkout dozenos-rebrand (runtime-minted App token)
    -> dep-graph/resolve-rebuild-set.sh <package> --json
       (transitive closure over dep-graph/dep-graph.json's reverse map)
    -> collapse the linux-kernel family (if present) into ONE matrix entry
    -> outputs.matrix = the resolved, incremental build set
  job B "build"  (needs: resolve, strategy.matrix over outputs.matrix)
    -> same shape as overlay/new-files/.github/workflows/rebuild-packages.yml
       (item #8): ghcr.io/dozenos/dozenos-build:rolling, /dozenos +
       /dozenos-rebrand mounts, upload deb-<pkg> artifacts
    -> linux-kernel-family entries run the bespoke
       scripts/package-build/linux-kernel/build.py with NO --packages
       filter (builds kernel + every OOT module together, in package.toml
       order); every other entry uses the generic per-directory build path
  job C "trigger-iso"  (needs: [resolve, build])
    -> gh workflow run package-smoketest.yml --repo <this repo>
       (in-repo ISO integration build, item #13, GITHUB_TOKEN suffices)
    -> gh api .../dozenos-nightly-build/dispatches
       (event_type dozenos-incremental-rebuild-complete -- since 2026-07-09
        this is the PRIMARY image-build trigger: dozenos-nightly-build's
        nightly.yml listens for it via repository_dispatch, its own
        change-gate dedups; the old daily cron is now a weekly forced
        heartbeat. Still continue-on-error: an image-trigger failure must
        not fail the package rebuild itself.)
```

**This is INCREMENTAL, never a full rebuild.** Job B's matrix is always
exactly job A's resolved set — the changed package plus its known
dependents — never "every recipe under `scripts/package-build/`." Contrast
with `rebuild-packages.yml` (item #8), which reacts to a push inside
`dozenos-build`'s own tree; this workflow instead reacts to a *different*
`dozenos/*` mirror changing and fans that one change out through the
dependency graph.

## 2. `event_type` / `client_payload` contract (LOCKED, sender ↔ receiver reconciled)

| | Value |
|---|---|
| `event_type` | `dozenos-package-rebuild` |
| `client_payload` | `{ "package": "<dozenos/* mirror repo name>" }` |

**Reconciliation performed this cycle:** `sync.yml.template` (item #14) was
read first, and it already emits exactly this `event_type`/`client_payload`
shape (see its "Dispatch rebuild (dozenos-build)" step) — item #14 had
already locked this contract, it just had no listener yet ("`dozenos-build`'s
own workflows do not yet listen for this event type", `SYNC.md` §4 step 8).
**No edit to `sync.yml.template` was needed or made** — `rebuild-dispatch.yml`
(item #15) was written to consume exactly what item #14 already sends, byte
for byte (`on.repository_dispatch.types: [dozenos-package-rebuild]`, and
`github.event.client_payload.package` read verbatim). `sync.yml.template`
therefore keeps its existing byte-stability guarantee (`SYNC.md` §3) —
untouched by this item.

`package` is always the dozenos mirror repo name — i.e. the same string
`resolve-rebuild-set.sh`/`dep-graph.json` key/value on (see §4 for the one
naming wrinkle, the `linux-kernel` family's package.toml block names).

## 3. `workflow_dispatch` manual test input

`rebuild-dispatch.yml` also accepts `workflow_dispatch` with a required
`package` string input, for manually testing the resolve→build→trigger-iso
path without waiting for a real mirror sync to fire the event. Distinct from
`rebuild-packages.yml`'s own `package_name` input (that workflow's input
selects a `scripts/package-build/*` directory to build directly; this one
selects a *changed* package to resolve through the dependency graph first) —
different name (`package`, not `package_name`) deliberately marks that
distinction.

## 4. Dependency graph — bootstrap (item #15), coverage/correctness completed (item #16), build-unit normalization fixed (item #30)

**Item #16 status: coverage COMPLETE.** Full write-up, per-edge
provenance, the new `iso_hard_deps` section, the `+git`-stamp/exact-pin
fix, and the graph-integrity validator: **`DEP-GRAPH.md`**. The summary
below is retained for continuity but is no longer the authoritative
coverage claim — see `DEP-GRAPH.md` §1 for the exact node accounting (and
its own reconciliation note on a 1-node overcount item #30 found and
corrected, §11 below).

**Item #30 status: `rebuild-dispatch.yml`'s directory-mapping gap (flagged
by item #16, see `DEP-GRAPH.md`'s "Flagged, not fixed" section) is FIXED.**
Every node below (and every other node in the graph) is now normalized to
a real buildable unit via `dep-graph.json`'s new `build_units` section +
`dep-graph/nodes-to-build-units.sh` — see §11.

`dep-graph/dep-graph.json` encodes the reverse-dependency edges already
known from the local-build powerloop (`memory/dozenos-build-dependency-graph.md`):

| Trigger | Dependents (rebuild set added) |
|---|---|
| `vpp` | `accel-ppp-ng` |
| `linux-kernel` | `i40e`, `iavf`, `ice`, `ixgbe`, `ixgbevf`, `realtek-r8126`, `realtek-r8152`, `jool`, `nat-rtsp`, `ipt-netflow`, `accel-ppp-ng`, `mlnx` |
| `vyconf` | `libdozenosconfig0` (→ `dozenos-1x`, 2nd hop) |
| `dozenos1x-config` | `libdozenosconfig0` (→ `dozenos-1x`, 2nd hop) |
| `libdozenosconfig0` | `dozenos-1x` |
| `strongswan` | `python3-vici` |
| `isc-kea-common` | `isc-kea-dhcp4`, `isc-kea-dhcp6`, `isc-kea-dhcp-ddns`, `isc-kea-hooks` |
| `libyang3` | `frr` |
| `libtac2` | `libnss-tacplus`, `libpam-tacplus` |
| `libtacplus-map1` | `libnss-tacplus`, `libpam-tacplus` |

**Item #16 completed coverage**: all 63 unique C2 package/block identifiers
`scripts/package-build/` can build (47 recipe directories + the 16
`linux-kernel`-family block names) now appear at least once in this graph
(a key, or a dependents-array value) — see `DEP-GRAPH.md` §1 for the exact
enumeration and before/after accounting (was 17/63, now 63/63), §2 for the
new edges added beyond this bootstrap (each with source provenance), and
§4 for the new `dep-graph/validate-dep-graph.sh` integrity check
(no dangling/self-loop/cycle, full coverage against a real
`scripts/package-build` tree). `dep-graph.json`'s JSON shape and
`resolve-rebuild-set.sh`'s CLI/behavior are unchanged, exactly as this
bootstrap predicted — only the edge list grew.

**Naming wrinkle — `linux-kernel` dependents are package.toml block names,
not `.deb` names.** `scripts/package-build/linux-kernel/` is one bespoke C1
recipe directory (its own `build.py`, not the generic
`scripts/package-build/build.py`) whose `package.toml` declares the kernel
plus every OOT module as separate `--packages <name>`-selectable blocks. The
graph's `linux-kernel` dependents (`i40e`, `realtek-r8126`, …) are exactly
those block `name =` values, not the shipped `.deb` package names
(`dozenos-intel-i40e`, `dozenos-drivers-realtek-r8126`, …) — this lets
`rebuild-dispatch.yml`'s build job pass them straight through to
`build.py --packages ...` with no translation. `igb` and `qat` are real
additional `package.toml` blocks **not** included in the bootstrap (the
known-edges list this graph was built from does not name them) — left for
item #16. `linux-firmware` is deliberately excluded from the OOT-dependent
set: firmware blobs are not recompiled against a specific kernel vermagic,
unlike every other OOT module here.

**`accel-ppp-ng` has two independent triggers**, both real: `vpp` (its
`build-accel-ppp-ng.sh` builds `vpp` first and links `HAVE_VPP=1` against
`vpp-dev`/`libvppinfra-dev`) *and* `linux-kernel` (`accel-ppp-ng` is itself
one of `linux-kernel`'s `package.toml` blocks — its `ipoe`/`vlan_mon` kernel
modules are OOT, same kernel-ABI coupling as every other OOT module). Both
edges resolve to the *same* build (inside `scripts/package-build/linux-kernel/`),
which is exactly why the build job's `linux-kernel`-family special case
(below) covers `accel-ppp-ng` too, not a separate `scripts/package-build/accel-ppp-ng/`
path.

**"Generic-ISO HARD deps" are intentionally NOT encoded as rebuild edges.**
`dozenos-1x` hard-`Depends` the full `vpp` set including `vpp-dev`;
`development`/`stream` build types require `dozenos-1x-smoketest`;
`vyatta-cfg` exact-pins `bash-completion (= 1:2.8-6)`. These are
`Depends:`/pin *relationships* in package metadata and the ISO package
list, not build-time source dependencies that require rebuilding the
depending package when the pinned one changes — encoding a `Depends:` pin
as a "must rebuild" edge would be a different, wrong claim. Item #16
verified all three against the real upstream `debian/control` files and
modeled them in `dep-graph.json`'s new top-level `iso_hard_deps` section
(deliberately separate from `reverse_dependencies`) — see `DEP-GRAPH.md`
§3 for the exact quotes and how the ISO build / ephemeral apt repo consume
them. Item #16 also traced the `+git` auto-stamp/exact-pin interaction
this third pin creates (`bash-completion` genuinely is rebuilt by DozenOS,
so a `+git`-stamped version would break the exact `=` match) and codified
a fix in `rename-transform.sh`/`rebrand-map.conf` — see `DEP-GRAPH.md` §5.

## 5. `linux-kernel` family collapsing (why the build job special-cases it)

**Updated by item #30 — see §11 for the full rewrite; this section now
describes the CURRENT mechanism.**

`rebuild-packages.yml` (item #8) already excludes `linux-kernel` from its
generic per-directory build path, for the same underlying reason this
document restates: `linux-kernel/build.py` is bespoke, not the generic
`scripts/package-build/build.py` every other C2 recipe uses, and its blocks
share one working directory with a genuine build-order dependency (the
kernel must build before any OOT module reads its output — see that
script's own `linux_kernel_tarball` handoff between blocks). Because of
this, job A never lets more than one `linux-kernel`-family matrix entry
exist: `dep-graph/nodes-to-build-units.sh` (item #30) maps the resolved
rebuild set to real build units and collapses every kernel-family node
(`linux-kernel` itself and/or any of its known dependents) into a single
`{"recipe": "linux-kernel", "kernel_blocks": [...]}` unit — the
`kernel_blocks` list is the sorted, deduped union of every resolved block
PLUS `linux-kernel` itself, always (see §11 for why that inclusion is a
correctness requirement, not optional). Job B's build step branches on
`matrix.unit.recipe == 'linux-kernel'`: that branch now runs `python3
build.py --packages <the union, space-joined>` — **narrower** than item
#15's original "no `--packages` filter, rebuild every block
unconditionally" (a lone `accel-ppp-ng` change no longer also rebuilds
every unrelated Intel NIC driver), while still always rebuilding the kernel
itself first (`build.py`'s own filter preserves `package.toml`'s
declaration order, and `linux-kernel` is declared first). Every other
matrix entry uses the ordinary
`cd scripts/package-build/<matrix.unit.recipe> && python3 ../build.py`
path, identical to `rebuild-packages.yml`. Both branches run inside the
same `ghcr.io/dozenos/dozenos-build:rolling` container with the same
neutral `/dozenos` mount and `/dozenos-rebrand` checkout — see
`MLNX-AND-DWARF.md` #25 for why the neutral mount matters for kernel/OOT
builds specifically (DWARF `comp_dir` debranding).

## 6. Job C — which ISO-trigger mechanism, and why

**Primary: in-repo `workflow_dispatch` of `package-smoketest.yml`.** That
workflow (item #13, already landed — see `ISO-BUILD.md`) already builds a
real ISO via `build-dozenos-image` and already best-effort-merges recently
built `deb-*` artifacts into an ephemeral apt repo. Dispatching it is a
same-repo operation, so the job's own `GITHUB_TOKEN` (with `actions: write`
granted at job level) is sufficient — no cross-repo credential needed for
this half.

**Secondary, best-effort: cross-repo notify `dozenos/dozenos-nightly-build`
(item #17).** That repo does not exist yet (`DISTRIBUTION.md`/`WORKFLOW-POLICY.md`
both record item #17 as not-yet-authored) — it is the eventual "full,
guaranteed-fresh nightly rebuild" counterpart (`ISO-BUILD.md` §5's own "what
item #17 should do instead" note). This job still references it **by name**,
using a runtime-minted org GitHub App token (cross-repo dispatch needs a
cross-repo credential, not `GITHUB_TOKEN` — `CI-SECRETS.md` §4), wrapped so
the step never fails the job
even when the target repo 404s (`continue-on-error: true` at the step level,
plus an in-script `if gh api ...; then ... else ...; fi` so the failure path
is logged, not silent). Once item #17 creates that repo, this step starts
succeeding with **zero changes needed here**.

Doing both (rather than picking only one, as the task framing offered as an
either/or) maximizes value at both time horizons: today, before item #17
exists, the in-repo integration build is the only real ISO-build path
available, so it must not be skipped; once item #17 lands, the best-effort
notify already in place needs no follow-up edit to `rebuild-dispatch.yml`
itself.

## 7. Permissions / secrets

- Workflow-level `permissions: contents: read` (minimal default).
- Job C adds `actions: write` (job-level only) — required for
  `gh workflow run` against this same repo.
- Runtime-minted org GitHub App tokens (`vars.BUILD_APP_ID` +
  `secrets.BUILD_APP_PRIVATE_KEY` via `actions/create-github-app-token@v3`,
  one mint step at the start of each consuming job, `repositories:` narrowed
  to that job's targets — see `CI-SECRETS.md` §4) used for: checking out
  `dozenos/dozenos-rebrand` (jobs A and B, same reason every other item #8
  workflow needs it — see `rebuild-packages.yml`'s own comment on
  `pre_build_hook`), and the best-effort cross-repo notify in job C. Never
  used for the same-repo `package-smoketest.yml` dispatch (that uses the
  ambient `GITHUB_TOKEN`).
- Zero literal `vyos` anywhere in `rebuild-dispatch.yml`; zero `uses: vyos/*`
  (verified, see §8).

## 8. Verification performed this cycle

**Resolver — representative inputs** (`dep-graph/resolve-rebuild-set.sh`,
run against the real shipped `dep-graph/dep-graph.json`):

```
$ resolve-rebuild-set.sh vpp
accel-ppp-ng
vpp

$ resolve-rebuild-set.sh linux-kernel
accel-ppp-ng
i40e
iavf
ice
ipt-netflow
ixgbe
ixgbevf
jool
linux-kernel
mlnx
nat-rtsp
realtek-r8126
realtek-r8152

$ resolve-rebuild-set.sh vyconf
dozenos-1x
libdozenosconfig0
vyconf

$ resolve-rebuild-set.sh python3-vici     # known leaf (a value, never a key)
python3-vici                              # no warning on stderr

$ resolve-rebuild-set.sh fixture-totally-unknown-pkg-xyz   # unknown package
resolve-rebuild-set: W: package 'fixture-totally-unknown-pkg-xyz' not found
anywhere in .../dep-graph.json (bootstrap coverage gap, or genuinely has no
known dependents) -- emitting it alone; see dep-graph.json's 'coverage' note
and REBUILD-DISPATCH.md
fixture-totally-unknown-pkg-xyz          # exit 0
```

`shellcheck dep-graph/resolve-rebuild-set.sh` — clean. `jq empty
dep-graph/dep-graph.json` — valid JSON.

**Receiver workflow**: `python3 -c "import yaml; yaml.safe_load(...)"` — OK.
`actionlint overlay/new-files/.github/workflows/rebuild-dispatch.yml` — zero
findings (including its embedded shell, which actionlint shellchecks
automatically). `grep -ni vyos` / `grep 'uses:.*vyos'` — both 0 hits.

**Lands-in-tree proof**: reproduced the mode-B `dozenos-build` tree fresh via

```sh
dozenos-rebrand/mirror-push.sh https://github.com/vyos/vyos-build.git \
  --target dozenos-build --build-repo --dry-run --work <scratch>
```

`.github/workflows/` in the reproduced clone contains exactly 5 files:
`build-docker-image.yml`, `package-smoketest.yml`, `rebuild-dispatch.yml`,
`rebuild-packages.yml`, `sync.yml` — `rebuild-dispatch.yml` is
byte-identical to the overlay source (`diff -q`, no differences). `--verify`
still reports the same 9 pre-existing residual `vyos` hits documented in
`overlay/MANIFEST.md` (no new residual introduced by this item). Zero `vyos`
and zero `uses:.*vyos` across all 5 landed workflow files.

**Test suite**: new `test/test-resolve-rebuild-set.sh`, 28/28 assertions
(the representative closures above, the known-leaf-vs-unknown-package
distinction, `--json` shape, bad-usage exits, and a synthetic a↔b cycle
fixture proving the resolver terminates rather than hangs). Full toolkit
suite after adding it: **199/199 assertions across 8 test files** (171
pre-existing + 28 new), 0 failures.

## 9. Nothing pushed, no key, graph is bootstrap

No repo was created, pushed, or dispatched to. No private key material was
generated, requested, or handled anywhere in this item. `dep-graph.json` is
explicitly, repeatedly marked as a **bootstrap** — coverage completion
across every C2 recipe is item #16's job, not claimed done here.

## 10. Item #16 verification (coverage/correctness completion)

§§8–9 above are the historical record of item #15's own verification
cycle, left unedited. This section records item #16's separate cycle —
full details in `DEP-GRAPH.md`.

**Resolver — new edges, representative outputs** (against the item #16
`dep-graph.json`):

```
$ resolve-rebuild-set.sh linux-kernel      # now includes igb, qat
accel-ppp-ng
i40e
iavf
ice
igb
ipt-netflow
ixgbe
ixgbevf
jool
linux-kernel
mlnx
nat-rtsp
qat
realtek-r8126
realtek-r8152

$ resolve-rebuild-set.sh dozenos-vpp-patches   # new edge, 2-hop closure
accel-ppp-ng
dozenos-vpp-patches
vpp

$ resolve-rebuild-set.sh bash-completion   # now a known leaf, no warning
bash-completion
```

`dep-graph/validate-dep-graph.sh` (new) — clean on the shipped graph (59
keys, 83 known identifiers, no self-loops/cycles), confirmed to actually
catch a self-loop and an a↔b cycle fixture, and reports full coverage
with `--tree` against both the mode-B reproduced clone and the local
`vyos-build` sibling checkout.

**Lands-in-tree proof**: re-reproduced the mode-B `dozenos-build` tree
fresh via the same `mirror-push.sh ... --build-repo --dry-run` command —
same 9 pre-existing residual `vyos` hits as item #15 (no new residual),
nothing pushed, no repo created/touched.

**Test suite**: `test/test-resolve-rebuild-set.sh` grew from 28 to
**48/48** assertions (6 new-edge closures + the igb/qat-in-linux-kernel
check + the graph-validator clean-run and its 2 broken-graph fixtures +
the tree-coverage check + the 2 `+git`-stamp-fix assertions + shellcheck
on the new `validate-dep-graph.sh`). Full toolkit suite: **219/219
assertions across 8 test files** (199 pre-item-#16 + 20 new), 0 failures.

**Zero-vyos / secrets**: every file this item touched
(`dep-graph/dep-graph.json`, `dep-graph/validate-dep-graph.sh` (new),
`rename-transform.sh`, `rebrand-map.conf`,
`test/test-resolve-rebuild-set.sh`, this file, `DEP-GRAPH.md`,
`overlay/MANIFEST.md`) is a toolkit/doc file, never copied into the
shipped `dozenos-build` tree (all are consumed via the `/dozenos-rebrand`
mount or read directly by CI, per §1's flow diagram) — `grep -rni vyos`
over them shows only expected, factual references (upstream repo/package
names being cited as provenance, e.g. `vyos/libpam-tacplus`,
`vyos-1x`'s `debian/control`) plus `vyatta` (preserved, not a residual).
No secret was introduced or handled; `CI-SECRETS.md` needed no changes.

**Nothing pushed, no key handled, coverage is COMPLETE** (not partial) —
see `DEP-GRAPH.md` §1 for the node accounting and §2's flagged remainder
(the `rebuild-dispatch.yml` directory-mapping gap, explicitly out of item
#16's own scope — closed by item #30, below).

## 11. Item #30: build-unit normalization fix (`rebuild-dispatch.yml` directory-mapping gap, CLOSED)

### The defect

Item #16 flagged, but explicitly did not fix (out of its own stated
scope), a real correctness gap in the already-landed item #15
`rebuild-dispatch.yml`: its build job did a literal
`cd scripts/package-build/${{ matrix.pkg }}` for every resolved node name.
Several dep-graph.json node identifiers are **not**
`scripts/package-build/` directory names:

- **deb names**: `python3-vici` (emitted by the `strongswan` recipe's
  `build-vici.sh`), `libtac2`/`libtacplus-map1` (emitted by the `tacacs`
  recipe's `libpam-tacplus`/`libtacplus-map` blocks), `isc-kea-common`
  and its 4 siblings (all emitted by the single `isc-kea` recipe),
  `libyang3` (emitted by the `frr` recipe's `libyang` block).
- **linux-kernel `--packages` block names**: `i40e`, `mlnx`,
  `realtek-r8126`, `accel-ppp-ng`, etc. — built by the bespoke
  `linux-kernel` recipe's own `build.py --packages <block>`, not a
  directory of their own.
- **OCaml opam-pin aliases with no recipe directory at all**: `vyconf`,
  `dozenos1x-config`, `libdozenosconfig0` — built as part of the
  `dozenos-1x` recipe's own build (they are opam-pinned FROM WITHIN that
  recipe's `libdozenosconfig/Makefile`, confirmed in `REPOINT-AUDIT.md`'s
  own audit of that file), never their own recipe directory.

`cd scripts/package-build/python3-vici` (or any of the above) would fail
with no such directory.

### The fix

**Reproduced the mode-B tree fresh** (`mirror-push.sh <local vyos-build
checkout> --target dozenos-build --branch rolling --build-repo --dry-run`,
nothing pushed) to authoritatively enumerate every real
`scripts/package-build/*/` directory (47 total, one of which is
`linux-kernel` itself) and every `linux-kernel/package.toml`
`[[packages]]` block name (16), then read every multi-block recipe's
`package.toml` plus, for deb-name nodes, the real upstream
`debian/control` (or the exact build-script invocation for
`python3-vici`/`vyconf`/etc.) to prove which recipe directory actually
produces each node.

**New `dep-graph.json` top-level `build_units` section**: a `node_to_unit`
map covering every node ever mentioned in `reverse_dependencies` (a key or
a dependents-array value), each mapping to `{"recipe":
"<scripts/package-build subdir>", "kernel_block": "<block name or
null>"}`, plus `recipe_dirs`/`kernel_blocks` reference lists, a
`provenance` object citing the exact `package.toml`/`debian/control`
evidence for every non-obvious mapping, and an `unmappable` object for the
one node this pass could **not** find a real directory for: `squid`
(confirmed absent from both the reproduced tree and the local
`vyos-build` sibling checkout — it is pure Debian apt passthrough,
`build/cache/packages.chroot/squid_*.deb`, never rebuilt locally, no
`dozenos/*` mirror; item #16's own "48 recipe directories"/"63 total node"
counts appear to have miscounted it as a 48th directory that does not
actually exist — the corrected total is 47 directories / 62 real buildable
units, reconciled in `dep-graph.json`'s own `build_units._comment`). Kept
strictly additive — `reverse_dependencies`, `_notes`, and `iso_hard_deps`
are all unchanged.

**New `dep-graph/nodes-to-build-units.sh`**: wraps
`resolve-rebuild-set.sh` (calls it verbatim, does not re-implement its BFS
— `resolve-rebuild-set.sh` itself is byte-unchanged, again), maps every
node in the resolved closure to its build unit via `build_units`, and
DEDUPS: multiple nodes mapping to the same recipe collapse to one
`{"recipe": "<name>"}` unit; every resolved linux-kernel-family node
collapses to one `{"recipe": "linux-kernel", "kernel_blocks": [...]}`
unit whose `kernel_blocks` is the sorted, deduped union of every resolved
block **plus `linux-kernel` itself, always** — `linux-kernel/build-kernel.sh`
writes the `kernel-vars` file (`KERNEL_DIR=...`) every OOT driver script
requires (`build-intel-nic.sh` aborts with "KERNEL_DIR not defined" if it
is missing), so filtering the kernel block itself out of `--packages`
would build nothing but a hard failure — this is a correctness fix, not
just deduplication. A node with no `build_units` entry falls back to an
identity match against `recipe_dirs`/`kernel_blocks` (tolerates a new
recipe added upstream after `dep-graph.json` was last regenerated,
matching `resolve-rebuild-set.sh`'s own "unknown package" tolerance) and,
failing that, is dropped from the emitted matrix with a warning on
stderr — never a hard failure, never an invented `cd` target.

**`rebuild-dispatch.yml` itself edited** (the first edit since item #15
landed it): the `resolve` job now runs `nodes-to-build-units.sh` instead
of `resolve-rebuild-set.sh` + ad-hoc jq linux-kernel-collapsing; the
`build` job's matrix is build-unit objects (`matrix.unit`), `cd`s
`scripts/package-build/${{ matrix.unit.recipe }}` (always a real
directory) and, for the `linux-kernel` unit, runs `python3 build.py
--packages <the union>` instead of the old no-filter full rebuild (see §5
above for the updated mechanism). `client_payload.package` (the raw
`dozenos/*` mirror repo name) is normalized through the exact same map
"for free": `nodes-to-build-units.sh`'s own resolved closure always
includes the queried package itself, so a mirror name like
`dozenos-vpp-patches` or `libtacplus-map` reaches its real build unit
(`vpp`, `tacacs`) with no separate normalization step. Artifact naming
(`deb-${{ matrix.unit.recipe }}`, upload path
`scripts/package-build/${{ matrix.unit.recipe }}/*.deb`) is also fixed as
a side effect — it used to be keyed on the raw (sometimes non-directory)
node name.

### Sender reconciliation: decided, NO CHANGE to `sync.yml.template`

Considered whether `sync.yml.template`'s dispatch step should send an
additional payload field (e.g. the recipe name alongside the mirror repo
name) so the receiver would not need to normalize at all. **Decision:
no — keep the receiver-side map authoritative, sender stays simple.**
Every `client_payload.package` value `sync.yml.template` can ever send
(the bare mirror repo name, derived at CI runtime from the always-populated
`GITHUB_REPOSITORY` runner env var — see `SYNC.md` §3 — i.e. one of the 17
real `dozenos/*` mirror repo names) is already a node in `dep-graph.json` —
mirror repo
names ARE graph nodes by construction (`REBUILD-DISPATCH.md` §2's own
"reconciliation performed" note: item #14 already sends exactly what item
#15's resolver expects). Pushing recipe-awareness into the sender would
mean every one of the 17 mirrors' generated `sync.yml` would need to know
its OWN recipe mapping — duplicating `build_units.node_to_unit` in 17
places instead of one, and reintroducing exactly the "hand-maintained
copy that can drift" problem `SYNC.md`/`REBUILD-DISPATCH.md` §5 already
avoid for the linux-kernel family. The receiver already has the one true
map (`dep-graph.json`, checked out fresh on every dispatch); normalizing
there, once, is strictly simpler and cannot drift out of sync with 17
independent sender copies. `sync.yml.template`'s byte-stability guarantee
(`SYNC.md` §3) is therefore preserved untouched by this item.

### Verification performed this cycle

- Reproduced the mode-B tree fresh via `mirror-push.sh <local vyos-build>
  --target dozenos-build --branch rolling --build-repo --dry-run` —
  same 9 pre-existing residual `vyos` hits as items #15/#16 (no new
  residual), nothing pushed, no repo created/touched. `rebuild-dispatch.yml`
  lands byte-identical to the overlay source in the reproduced tree.
- `jq empty dep-graph/dep-graph.json` — still valid JSON after the
  `build_units` addition.
- `dep-graph/validate-dep-graph.sh` (both plain and `--tree`) — clean,
  now also reporting "N build-unit(s) mapped + M flagged unmappable";
  confirmed the new build-unit checks actually catch 3 synthetic broken
  fixtures (a coverage gap, a malformed `node_to_unit` entry, a
  `node_to_unit.recipe` pointing at a non-real directory under `--tree`).
- `dep-graph/nodes-to-build-units.sh` — representative outputs:
  ```
  $ nodes-to-build-units.sh python3-vici
  [{"recipe":"strongswan"}]
  $ nodes-to-build-units.sh libtac2        # tacacs family, deb name
  [{"recipe":"tacacs"}]
  $ nodes-to-build-units.sh libpam-tacplus # DEDUP: 2 nodes -> 1 unit
  [{"recipe":"tacacs"}]
  $ nodes-to-build-units.sh isc-kea-common # DEDUP: 5 nodes -> 1 unit
  [{"recipe":"isc-kea"}]
  $ nodes-to-build-units.sh i40e
  [{"recipe":"linux-kernel","kernel_blocks":["i40e","linux-kernel"]}]
  $ nodes-to-build-units.sh vyconf          # opam-pin alias, no recipe dir
  [{"recipe":"dozenos-1x"}]
  $ nodes-to-build-units.sh dozenos-vpp-patches
  [{"recipe":"linux-kernel","kernel_blocks":["accel-ppp-ng","linux-kernel"]},{"recipe":"vpp"}]
  $ nodes-to-build-units.sh squid           # flagged unmappable
  []   # + a warning on stderr, exit 0
  ```
- `shellcheck` on `nodes-to-build-units.sh` and the updated
  `validate-dep-graph.sh` — clean.
- `python3 -c "import yaml; yaml.safe_load(...)"` on the edited
  `rebuild-dispatch.yml` — OK. `actionlint` — zero findings. `grep -ni
  vyos` / `grep 'uses:.*vyos'` — both 0 hits (unchanged from item #15).
- New `test/test-nodes-to-build-units.sh`: **40/40** assertions. Full
  toolkit suite: **259/259** assertions across 9 test files (219
  pre-item-#30 + 40 new), 0 failures. `resolve-rebuild-set.sh` itself
  needed no changes and its own 48/48 test suite is unaffected —
  confirmed byte-identical before/after this item.

### What did NOT change

- `resolve-rebuild-set.sh` — byte-for-byte unchanged.
- `reverse_dependencies`, `_notes`, and `iso_hard_deps` inside
  `dep-graph.json` — unchanged; only the new sibling `build_units` section
  was added.
- `sync.yml.template` — unchanged (see the sender-reconciliation decision
  above).
- No key material handled, no repo pushed/created, no GitHub write
  operation performed anywhere in this item.
