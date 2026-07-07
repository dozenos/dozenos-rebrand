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
     (BUILD_PAT -- cross-repo dispatch, see CI-SECRETS.md)
        |
        v
dozenos-build: overlay/new-files/.github/workflows/rebuild-dispatch.yml (item #15, THIS document)
  job A "resolve"
    -> checkout dozenos-rebrand (BUILD_PAT)
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
    -> best-effort gh api .../dozenos-nightly-build/dispatches
       (item #17, not yet created -- BUILD_PAT, continue-on-error: true)
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

## 4. Dependency graph — bootstrap (item #15), coverage/correctness completed (item #16)

**Item #16 status: coverage COMPLETE.** Full write-up, per-edge
provenance, the new `iso_hard_deps` section, the `+git`-stamp/exact-pin
fix, and the graph-integrity validator: **`DEP-GRAPH.md`**. The summary
below is retained for continuity but is no longer the authoritative
coverage claim — see `DEP-GRAPH.md` §1 for the exact 63/63 node
accounting.

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

`rebuild-packages.yml` (item #8) already excludes `linux-kernel` from its
generic per-directory build path, for the same underlying reason this
document restates: `linux-kernel/build.py` is bespoke, not the generic
`scripts/package-build/build.py` every other C2 recipe uses, and its blocks
share one working directory with a genuine build-order dependency (the
kernel must build before any OOT module reads its output — see that
script's own `linux_kernel_tarball` handoff between blocks). Because of
this, job A never lets more than one `linux-kernel`-family matrix entry
exist: if the resolved rebuild set contains `linux-kernel` and/or any of its
known dependents, job A collapses all of them into a single `"linux-kernel"`
matrix entry (computed via a small `jq` set-difference against
`dep-graph.json`'s own `reverse_dependencies["linux-kernel"]` list — not a
second, hand-maintained copy of that list, so it cannot drift). Job B's
build step branches on `matrix.pkg == 'linux-kernel'`: that branch runs
`python3 build.py` with **no** `--packages` filter (builds every block,
kernel first, in `package.toml` order — exactly what "rebuild the kernel and
everything ABI-coupled to it" means); every other matrix entry uses the
ordinary `cd scripts/package-build/<pkg> && python3 ../build.py` path,
identical to `rebuild-packages.yml`. Both branches run inside the same
`ghcr.io/dozenos/dozenos-build:rolling` container with the same neutral
`/dozenos` mount and `/dozenos-rebrand` checkout — see `MLNX-AND-DWARF.md`
#25 for why the neutral mount matters for kernel/OOT builds specifically
(DWARF `comp_dir` debranding).

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
using `secrets.BUILD_PAT` (cross-repo dispatch needs `BUILD_PAT`, not
`GITHUB_TOKEN` — `CI-SECRETS.md`), wrapped so the step never fails the job
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
- `secrets.BUILD_PAT` used for: checking out `dozenos/dozenos-rebrand` (jobs
  A and B, same reason every other item #8 workflow needs it — see
  `rebuild-packages.yml`'s own comment on `pre_build_hook`), and the
  best-effort cross-repo notify in job C. Never used for the same-repo
  `package-smoketest.yml` dispatch (that uses the ambient `GITHUB_TOKEN`).
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
see `DEP-GRAPH.md` §1 for the 63/63 accounting and §2's one flagged
remainder (the `rebuild-dispatch.yml` directory-mapping gap, explicitly
out of this item's scope).
