# DEB-CACHE.md — content-addressed .deb reuse (user-approved 2026-07-09)

Why every nightly no longer rebuilds all ~30 packages (~2-3h) when only one
or two mirrors moved, and why that is still guaranteed to produce the same
coherent, complete .deb set. Engine: `release/deb-cache.sh` (probe / store /
prune / key). Storage: GitHub Releases on the dedicated public repo
`dozenos/dozenos-deb-cache` (single seed commit; every release tag
`<unit>-<key12>` is one cache entry: the unit's full `.deb` set +
`deb-cache-manifest.json`). Consumers: `dozenos-nightly-build`'s
`nightly.yml` `build-packages` job (probe + store + prune) and
`dozenos-build`'s `rebuild-dispatch.yml` build job (probe + store,
linux-kernel store excluded — see §4). Cross-references: `DISTRIBUTION.md`
§1a (why this is not the ruled-out apt mirror), `REBUILD-DISPATCH.md`
(the incremental sibling this cache pre-warms the nightly from),
`CI-SECRETS.md` §4 (App-token minting).

## 1. Design: keys are content-derived, never run-derived

A package build is a pure function of its inputs. The cache key for a build
unit (a `scripts/package-build/<dir>` recipe; unit `linux-kernel` also
covers `vpp`, which the kernel leg builds internally) hashes exactly:

1. **The recipe dir's git tree hash** — any recipe edit, pin bump, patch.
2. **Branch-tracking scm entries** in the unit's `package.toml`s: entries
   whose `commit_id` is a moving ref (`rolling`, `stable/2510`, empty)
   resolve to the branch's live SHA via `git ls-remote`. Pinned entries
   (commit hashes, `v*`/`debian/*`/`Kea-*`-style tags) are NOT resolved —
   the tree hash already covers a pin change.
3. **The forward transitive dep closure** from `dep-graph/dep-graph.json`
   (the same graph rebuild-dispatch fans out over, inverted): every dep
   node's recipe dir joins the material, and every dep node that is itself
   a `dozenos/*` mirror contributes its rolling HEAD. This is what makes
   `dozenos-1x`'s key include the `vyconf` + `dozenos1x-config` mirrors
   (opam-pinned build inputs that appear in NO `package.toml`) and
   `linux-kernel`'s include `dozenos-vpp-patches`.
4. **Global inputs** shared by every recipe: `scripts/package-build/build.py`,
   `data/defaults.toml` (kernel version lives there), and the rebrand
   toolkit's `rename-transform.sh` (every recipe's `pre_build_hook`).

Deliberately NOT in the key: the `ghcr.io/dozenos/dozenos-build:rolling`
container digest. Toolchain drift alone never invalidates; in practice a
toolchain change that matters arrives with a recipe/defaults change. (If
that assumption ever bites, wiping `dozenos-deb-cache` — or bumping any
global input — is a one-step full invalidation.)

Because the key is derived from CURRENT input state, an unchanged package
hits the entry stored by any earlier run — days or weeks old. There is no
"latest build" pointer, no artifact-history scan, no per-run bookkeeping.
This answers the original objection to reusing past CI artifacts
(`nightly.yml`'s option (b): "can only recover whichever packages happened
to change recently"): completeness is per-package and constructive — every
nightly matrix leg either key-hits (full stored set, full-key-verified via
the manifest, not just the 12-char tag) or rebuilds in-run.

## 2. Failure economics: every failure degrades to today's cost

- key computation fails (ls-remote flake) → leg builds without cache.
- probe misses / cache repo absent / download fails → leg builds.
- store fails → `continue-on-error`, nightly unaffected; next run rebuilds.
- cache repo wiped → next nightly is a full ~3h rebuild, then re-seeds.

No failure mode can produce a wrong or incomplete ISO; the only variable is
wall-clock. Typical night (one or two high-churn mirrors moved): rebuild
those units only + ISO assembly — the kernel family's ~hour+ rebuild only
recurs when a kernel-family input actually changed.

## 3. Interplay with rebuild-dispatch (pre-warming)

`rebuild-dispatch.yml` computes the SAME key from the same inputs, so the
.debs it builds during the day land in the cache under exactly the key the
nightly will derive at 04:17 — the day's incremental rebuilds pre-warm the
night's full set. The nightly then typically hits on everything, including
the units that changed that day.

## 4. linux-kernel store exclusion (dispatch only)

`rebuild-dispatch.yml` narrows kernel-family builds to the resolved blocks
(`build.py --packages ...`), producing a SUBSET of the full family set
(kernel + every OOT module + vpp). Storing that subset would let a later
nightly hit an incomplete kernel family, so the dispatch workflow never
stores `linux-kernel` units; only the nightly's unfiltered kernel leg does.
Probing is safe either way — a hit can only return a full nightly-stored
set. (`vpp`-unit entries stored by dispatch are unused by the nightly —
vpp has no nightly leg of its own — but harmless.)

## 5. Hygiene

`nightly.yml`'s `prune-deb-cache` job (after a successful publish) keeps
the newest 3 entries per unit and deletes the rest, tags included. 3, not
1: a same-day dispatch store plus a possible next-tick re-run may
legitimately reference two distinct keys for one unit.

## 6. Reconciliation with DISTRIBUTION.md §1 ("no public apt mirror")

That locked decision rules out a *public, persistent apt repository* —
a runtime `apt upgrade` endpoint with the signing/rate-limit/hosting
burden that implies. This cache is none of that: no `Packages`/`Release`
index, nothing apt-reachable, no OS-runtime consumer — only CI jobs, which
still assemble the same ephemeral in-run apt repo (item #13) from the same
`deb-*` artifacts as before. The release assets are anonymously
downloadable (the repo is public, like every `dozenos/*` repo), but their
contents already ship inside every public nightly ISO. The user explicitly
approved this shape 2026-07-09.

## 7. Verification performed

- `test/test-deb-cache.sh`: 22 network-free assertions (key determinism,
  per-input-class invalidation, dep-closure direction, mirror-node closure
  via `DEB_CACHE_MIRROR_URL_BASE` file:// override, pinned-entry
  no-network proof, store/probe arg validation + empty-debs skip, zero
  vyos residual).
- Real-key smoke test against the live mirrors: `hvinfo` (1.0s),
  `dozenos-1x` (2.6s — material correctly includes `vyconf` +
  `dozenos1x-config` mirror HEADs), `frr` (1.7s — no lookups, all pins),
  `linux-kernel` (2.4s — includes `recipe vpp`, `mirror
  dozenos-vpp-patches`, `scm vpp` stable/2510 + rolling lines).
- Both workflows: `yaml.safe_load` OK, `actionlint` clean, zero `vyos`
  tokens in `rebuild-dispatch.yml` (ships to the mirror via overlay).
