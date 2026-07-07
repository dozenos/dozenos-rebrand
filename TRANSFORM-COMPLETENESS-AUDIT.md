# Transform-Completeness Audit (item #18)

Goal: determine exactly which hand-made DozenOS edits in the `vyos-build`
working tree are **not** reproduced by `rename-transform.sh`, so that mode-B
CI (fresh clone → `rename-transform.sh` → overlay → push) can reproduce the
full DozenOS delta deterministically, without a human re-deriving it.

## Method (definitive, reproducible)

`vyos-build`'s `HEAD` is pristine upstream `vyos/vyos-build@rolling` (no
commits made locally); all DozenOS edits are uncommitted working-tree
modifications + untracked new files/dirs (build artifacts included).

```
mkdir -p <scratch>/up
git -C vyos-build archive HEAD | tar -x -C <scratch>/up      # pristine upstream (318 files)
rename-transform.sh <scratch>/up                              # full four-form + email pass
rename-transform.sh <scratch>/up --verify                      # -> OK (0 residual vyos)
diff -rq <scratch>/up vyos-build -x .git -x build -x packages -x .powerloop \
         -x '*.deb' -x ocaml-src -x _ocaml_inspect -x libhtp2 -x humps \
         -x udp-broadcast-relay -x full_build_item17.log
```

`<scratch>/up` = what a fresh clone would look like **after** running only
the transform. Diffing it against the live working tree isolates exactly the
hand work the transform does not (yet) reproduce. 316 diff lines resulted;
every one was individually inspected (not just counted) to classify it.

Noise excluded from the diff (build cruft, not source, would not exist after
a fresh mode-B clone+build anyway): `.git`, `build/`, `packages/`,
`.powerloop/`, `*.deb`/`*.buildinfo`/`*.changes`/`*.dsc`/`*.orig.tar.*`/
`*.debian.tar.*`, and the large vendored/extracted upstream source clones
under `scripts/package-build/<recipe>/<upstream-name>/` (e.g.
`linux-kernel/linux-6.18.36/`, `vpp/vpp/`, `frr/libyang/`, `hostap/wpa/`,
`vyos-1x/ocaml-src/`) — these are per-recipe build output, not authored
recipe files, and are correctly distinguished from the small new recipe
*directories* we authored from scratch (`vyatta-bash/`, `vyatta-biosdevname/`,
`vyatta-cfg/`, `ipaddrcheck/`, `hvinfo/`, `vyos-http-api-tools/` — each just a
`package.toml`/`build.py`/small patch set, no vendored source).
`git status --porcelain` (`M` vs `??`) was cross-checked against every diff
line to confirm which side (tracked-modified vs untracked-new) each item is.

## Classification table

Legend: **AUTO** = already reproduced by the transform (confirmed 0-diff, or
diff exists only because we simply haven't hand-applied the transform to
that file yet — the transform *would* still fix it correctly on a fresh
clone). **FOLD** = deterministic rule/mechanism to add to the toolkit.
**OV-NEW** = new file we authored. **OV-VAL** = value-not-string, transform
structurally cannot do this. **OV-LOGIC** = logic edit. **CI-N/A** = moot
under mode-B CI.

| # | Change | Category | File(s) | Rationale |
|---|---|---|---|---|
| 1 | Case-preserving four-form rename of branding strings, paths, systemd units, `os-release`, GRUB, ISO volid, dbus/apparmor names, `defaults.toml` `kernel_flavor` | AUTO | `data/architectures/*.toml`, `data/build-types/*.toml`, `data/defaults.toml` (kernel_flavor line), `data/live-build-config/hooks/live/*`, `includes.binary/{compat,isolinux/menu.cfg}`, `includes.chroot/etc/{c3xxx,c6xx,d15xx,dh895xcc}*.conf`, `includes.chroot/etc/systemd/{journald,system}.conf`, `includes.chroot/opt/vyatta/.../default-union-grub-entry`, `rootfs/excludes`, `scripts/check-qemu-install` (ISO volid) | Verified 0-diff (or diff = only a not-yet-hand-applied copyright/comment line, see #2) between transformed-upstream and working tree for every one of these. Exactly matches `LANDMINES.md`'s documented "handled by the generic rule" table. |
| 2 | Copyright headers ("VyOS maintainers" → "DozenOS maintainers") and template comments in files that have **no other hand edit** | AUTO (not yet applied, no gap) | ~35× `scripts/package-build/<recipe>/build.py` (identical to upstream — confirmed via `git diff`, zero tracked changes), `scripts/check-qemu-install`, `.github/workflows/*.yml`, `CODEOWNERS`, `.coderabbit.yaml`, `CONTRIBUTING.md`, `README.md`, `AGENTS.md`, `LICENSE.artwork`, several not-yet-built recipes' `package.toml` (`aws-gwlbtun`, `bash-completion` comment, `xen-guest-agent`, `zerotier-one` Maintainer lines) | These recipes are still `pending (#16)` per `recipe-worklist.md` — we never hand-touched them, so the diff is 100% attributable to "transform not yet run on this file", not a transform gap. Running `rename-transform.sh` on a fresh clone fixes all of these automatically. Confirms transform coverage is a **superset** of our manual work, not a subset — the important direction for CI. |
| 3 | Renamed key/list/pref files with **identical post-transform content** (`10-vyos-addons`→`10-dozenos-addons`, `vyos-base.list.chroot`→`dozenos-base.list.chroot`, `vyos-utils.list.chroot`→`dozenos-utils.list.chroot`) | AUTO | `data/live-build-config/includes.chroot/etc/initramfs-tools/hooks/10-dozenos-addons`, `data/live-build-config/package-lists/dozenos-{base,utils}.list.chroot` | Byte-identical to transformed-upstream — pure rename, fully reproduced. |
| 4 | **`pre_build_hook = "…/rename-transform.sh ."`** wired into the recipe's `package.toml` so the extracted C2 upstream source gets transformed before `build_cmd` runs | **FOLD** (new mechanism, not a `rebrand-map.conf` string rule) | ~20 recipes: `blackbox_exporter`, `dropbear`, `ethtool`, `frr` (both blocks), `frr_exporter`, `hostap` (both blocks), `hsflowd`, `isc-dhcp`, `keepalived`, `libhtp`, `ndppd`, `netfilter` (both blocks), `net-snmp`, `openssl`, `openvpn-otp`, `owamp`, `radvd`, `strongswan` (appended via `&&` to an existing hook), `tacacs` (×3 blocks), `udp-broadcast-relay`, `unionfs-fuse`, `vpp` (inlined into `build_cmd` instead of `pre_build_hook`), `wide-dhcpv6` | This is the actual mechanism that makes every C2 recipe's *shipped* content zero-`vyos` — `rename-transform.sh` transforms a tree, it doesn't know to wire itself into `package.toml`. **This is the single biggest, previously-undocumented completeness gap.** It's fully mechanical (same one-line insert, same set of recipes = the C2 class from `recipe-worklist.md`), so it belongs in the toolkit as a companion step, not as a one-off hand edit repeated per recipe per upstream sync. |
| 5 | New recipes authored from scratch (no upstream `package.toml` existed) | OV-NEW | `scripts/package-build/{vyatta-bash,vyatta-biosdevname,vyatta-cfg,ipaddrcheck,hvinfo,vyos-http-api-tools}/` (recipe dirs only — `package.toml`, `build.py`/`build.sh`, small `patches/`; vendored clone subdirs excluded, see Method) | Confirmed via `git status` all-`??` (untracked) and absent from the archived upstream tree entirely — cannot be produced by any transform of upstream content because upstream has no such recipe. |
| 6 | `data/certificates/README.md` | OV-NEW | `data/certificates/README.md` | New file documenting the CI-injected MOK cert convention; no upstream equivalent. |
| 7 | `BUILD-LOCAL.md` (repo root) | OV-NEW | `BUILD-LOCAL.md` | New local-build procedure doc (item #13); no upstream equivalent. |
| 8 | Default-login password hash (`config.boot.default`) — username transforms cleanly, but the SHA-512 crypt hash of the literal password `vyos` contains no `vyos` substring | **OV-VAL** | `tools/cloud-init/AWS/config.boot.default`, `tools/container/config.boot.default`, and (separate repo, see note) `vyos-1x/data/config.boot.default`, `tests/data/config.boot.default`, `src/tests/test_initial_setup.py`, `smoketest/configs/{firewall-groups-name,assert/firewall-groups-name}` | Exactly item #23 from `LANDMINES.md`: value-not-string, transform structurally cannot regenerate a crypt hash. Verified: working tree's hash validates `dozenos`, not `vyos`. |
| 9 | VyOS-branded Secure Boot MOK certificate removed; replaced by a README describing CI-time injection from org secrets | **OV-VAL** | `data/certificates/vyos-prod-2025-linux.pem` deleted (real X.509 cert, brand baked into DER/base64, not a grep-visible string) | Item #26: the cert's subject/issuer are literally "VyOS" but PEM base64 isn't literal text, so it passes the grep gate yet is genuinely branded. Transform cannot generate/replace a certificate. Decision (remove for now, inject via secret in CI) is itself an overlay policy, not a rename. |
| 10 | Throwaway GPG archive-signing key + 3 minisign keypairs — **entirely new key material**, not a renamed/edited copy of the VyOS key | **OV-VAL** | `data/live-build-config/archives/dozenos-dev.{key,pref}.chroot`, `data/live-build-config/includes.chroot/usr/share/dozenos/keys/dozenos-{backup,release,rolling-release}.minisign.pub`, `docker/dozenos-dev.key` (renamed from `vyos-dev.key`) | Confirmed by diffing content against the transformed upstream key: completely different key fingerprint/bytes, not a text substitution result. Same class as #9 — value the transform cannot produce. |
| 11 | `scm_url` fields for VyOS-hosted **helper** repos deliberately left pointing at the real `github.com/vyos/*` (transform would rewrite them to a non-existent `github.com/dozenos/*` and 404 the clone) | **OV-VAL** (temporary, contingent on mirror existence) | `scripts/package-build/{libnss-mapuser,libpam-radius-auth,shim-signed}/package.toml`, `scripts/package-build/tacacs/package.toml` (×3 sub-blocks: `libtacplus-map`, `libpam-tacplus`, `libnss-tacplus`), `scripts/package-build/vpp/package.toml` (`vyos-vpp-patches` name + scm_url + rsync path) | Matches `LANDMINES.md` §(d) exactly. **This dissolves once `github.com/dozenos/*` mirrors of these helper repos exist** (per the DozenOS GitHub-structure plan) — at that point the plain four-form transform becomes correct and this override should be *removed*, not carried forward. Flagged here so CI doesn't blindly apply this revert forever. |
| 12 | `docker/dozenos-dev.list` (renamed from `vyos-dev.list`) content still points at real `https://packages.vyos.net/repositories/rolling` for build-time toolchain packages | **OV-VAL** (same class/expiry as #11) | `docker/dozenos-dev.list`, and the accompanying Dockerfile comment `# see missing.md for the pending repoint-off-packages.vyos.net item` | Same "external build-time-only pointer" landmine class as scm_url — filename/keyring name renamed (four-form-safe), but the actual apt source URL is a real external dependency with no DozenOS mirror yet. |
| 13 | `build_config.get('vyos_mirror')` guard — skip emitting a (now-empty) VyOS apt source line entirely instead of writing a malformed `deb  rolling main` | **OV-LOGIC** | `scripts/image-build/build-vyos-image` (~lines 530–544) | Item #10 "Strategy B" (no VyOS apt mirror at all). Not a string substitution — it's new conditional logic. |
| 14 | Byte-exact `strip`/repack post-processing embedded directly in `package.toml` `build_cmd`, to remove build-env-leak (`/vyos` DWARF paths, `vyos_bld` build user) from hand-packaged (non-`dpkg-buildpackage`) recipes | OV-LOGIC | `scripts/package-build/hsflowd/package.toml` (dpkg-deb repack + strip), `scripts/package-build/openvpn-otp/package.toml` (`strip --strip-unneeded`) | Item #14's "build-env leak" class (a) in `RETROSPECTIVE.md`. Bespoke per-recipe logic, not renameable. Becomes unnecessary once every recipe builds under the neutral `dozenos-build:rolling` image (item #14) — these two recipes were evidently built before/without that fix, or need the manual strip regardless because they don't go through `dh_strip`. |
| 15 | `export PATH=/opt/go/bin:$PATH` inserted into `build_cmd` | OV-LOGIC (environment glue, not brand-related) | `scripts/package-build/{frr_exporter,node_exporter}/package.toml` | Go toolchain path fix for the local build container; unrelated to VyOS→DozenOS branding. Should be re-evaluated against whatever the CI build image actually provides — may become CI-N/A if the image already puts Go on `PATH`. |
| 16 | `git -c user.email=maintainers@dozenos.local -c user.name=dozenos am` — commit identity override when applying VyOS packaging patches via `git am` | OV-LOGIC (small, mechanical) | `scripts/package-build/{udp-broadcast-relay,vpp}/package.toml` | Not reproducible by content transform since it's a `git am` invocation flag, not file content; trivially foldable alongside item #4's `pre_build_hook` wiring if/when that becomes a generic recipe-config codemod. |
| 17 | `vyos-1x` `Makefile` uses `find src/services -maxdepth 1 -name 'dozenos*'` instead of `git ls-files` | OV-LOGIC — **confirmed present**, but **out of scope for this repo's overlay** | `scripts/package-build/vyos-1x/vyos-1x/Makefile` (a *separate* git repo — the cloned/rebranded `vyos-1x`→`dozenos-1x` source, not part of `vyos-build`'s own tree) | Verified: the fix is real and already applied (line 119 of that Makefile). It lives entirely inside the `vyos-1x`/`dozenos-1x` source tree, which will itself become a mirrored `dozenos-1x` GitHub repo per the CI/CD plan — this patch belongs in *that* repo's own future transform-completeness audit, not in `vyos-build`'s overlay. Recorded here only so it isn't lost. |
| 18 | Root entrypoint `build-vyos-image` (and its target `scripts/image-build/build-vyos-image`) — **filename NOT renamed** even though content is fully rebranded, while `Makefile` calls it by its (unrenamed) name | **CI-N/A / needs a decision** — surprising finding, not previously documented | `build-vyos-image` (symlink), `scripts/image-build/build-vyos-image`, `Makefile` (`./build-vyos-image $*`, `rm -f vyos-*.iso`) | The plain transform *would* rename this to `build-dozenos-image` (it's a strict superset of every renaming case per `LANDMINES.md`'s own invariant) — but our hand tree kept the old name. This is internally self-consistent (Makefile invokes the file by the name it actually has) but is an **undocumented deviation** from "the transform is a superset of our hand work." Not previously flagged anywhere. **Decision needed**: either (a) accept the transform's rename in CI and update `Makefile`/docs to `./build-dozenos-image`, or (b) add an explicit revert-rename step to the overlay to preserve the `build-vyos-image` invocation name for tooling/muscle-memory compatibility. Currently the working tree silently does something between the two without recording why. |
| 19 | `.powerloop/` tracking directory | CI-N/A | `.powerloop/` | Internal batch-execution bookkeeping for this powerloop run; not part of the shipped product, not part of the transform's job, should never be in the overlay. |
| 20 | Interim byte-substitution debrand (`vyos`→`xxxx`, same-length) applied directly to already-built `.deb`s for packages built before image #14 existed | CI-N/A (source-tree diff shows nothing — happens post-build, on binary artifacts) | N/A — not visible in this source-tree diff at all; recorded in `RETROSPECTIVE.md`/`LANDMINES.md` §(a) | Confirmed moot for *this* audit's scope (source tree only) and, per `RETROSPECTIVE.md`, moot going forward once every recipe rebuilds under the neutral image — item #25 is the last consumer. |

## Summary: what to fold into the toolkit vs. what stays overlay

**Fold into the toolkit** (deterministic, same result every run — extend
`dozenos-rebrand/` with a new companion mechanism; this is *not* a
`rebrand-map.conf` string rule, so it doesn't belong in `rename-transform.sh`'s
four-form pass itself):
- Item #4 — inject `pre_build_hook = "/dozenos-rebrand/rename-transform.sh ."`
  into every C2 recipe's `package.toml` (the ~20 recipes listed). Recommend a
  new script, e.g. `dozenos-rebrand/wire-prebuild-hooks.sh`, driven off the
  C2 list already maintained in `recipe-worklist.md`, run once per recipe
  after `rename-transform.sh` itself.
- Item #16's `git am` identity flags are small enough to fold in alongside #4
  when that codemod is built.

**Stays overlay** (values, new files, or logic that depends on state outside
the source tree — applied as a discrete step *after* `rename-transform.sh`):
- OVERLAY-NEW-FILE (items #5, #6, #7): copy whole files/dirs in verbatim.
- OVERLAY-VALUE-FIX (items #8–#12): a small patch series / value-replacement
  script — password hash regeneration, cert removal-or-inject, throwaway key
  generation, and the two "leave `scm_url`/apt-source pointed at real
  upstream" overrides (temporary, tied to `github.com/dozenos` mirror
  existence — must be revisited/removed once those mirrors exist).
- OVERLAY-LOGIC-PATCH (items #13–#16): a small patch series against specific
  files (`build-vyos-image`, two `package.toml`s' `build_cmd`, Go `PATH`
  exports).
- Item #18 needs a decision before it can be classified as fold/overlay/accept.

## Recommended overlay layout

```
dozenos-rebrand/overlay/
  README.md          # apply order + when each layer runs relative to rename-transform.sh
  MANIFEST.md         # enumerated source-of-truth: which working-tree path each
                       # overlay artifact will eventually be copied/generated from
  new-files/           # OVERLAY-NEW-FILE payloads, mirrored by repo-relative path
  value-fixes/         # OVERLAY-VALUE-FIX: patches/scripts (password hash regen,
                       # cert handling, key generation, scm_url/apt-source overrides)
  logic-patches/       # OVERLAY-LOGIC-PATCH: unified diffs against specific files
```

Apply order for mode-B CI: `git clone` fresh upstream → `rename-transform.sh`
(+ future `wire-prebuild-hooks.sh`) → `overlay/new-files/` copied on top →
`overlay/logic-patches/*.patch` applied → `overlay/value-fixes/*` run → build.

This cycle only creates the skeleton (`README.md` + `MANIFEST.md` + empty
category dirs) — populating `new-files/`, `value-fixes/`, and
`logic-patches/` with actual content, and writing `wire-prebuild-hooks.sh`,
are follow-on sub-items.

## Self-review

- **(a) AUTO items don't wrongly appear as overlay work**: every AUTO-bucketed
  item was checked to either diff at 0 bytes against the transformed upstream,
  or (for the "not yet hand-applied" cases like `build.py` copyright headers)
  confirmed via `git diff`/`git status` to carry **zero** tracked changes in
  the working tree — i.e., there is no hand edit at all for the transform to
  fail to reproduce; the diff is purely "haven't run the transform on this
  file yet," which a fresh-clone CI run fixes automatically.
- **(b) Value-not-string cases correctly bucketed**: #23 (password hash) and
  #26 (VyOS cert) are OV-VAL as directed. Two more of the same class were
  found and added: the throwaway GPG/minisign key material (#10) and the
  scm_url/apt-source "leave pointed at real upstream" overrides (#11, #12) —
  the latter are flagged as *temporary*, expiring once `github.com/dozenos`
  mirrors exist, so CI doesn't perpetuate them past their shelf life.
- **(c) New recipes vs. vendored trees**: confirmed via `git status`
  (all-`??`) and absence from the archived `HEAD` tree that the six new
  recipe dirs (`vyatta-bash`, `vyatta-biosdevname`, `vyatta-cfg`,
  `ipaddrcheck`, `hvinfo`, `vyos-http-api-tools`) contain only small
  hand-authored files (`package.toml`, `build.py`/`build.sh`, a handful of
  patches) — clearly distinguished from the large extracted-source vendor
  trees (`linux-6.18.36/`, `vpp/vpp/`, `frr/libyang/`, `hostap/wpa/`,
  `vyos-1x/ocaml-src/`, etc.), which were explicitly excluded from the diff
  as build noise, not authored source.

## Confirmation

No network clone, no GitHub repo creation, no push, and no deletion from
`vyos-build` were performed. All work was read-only inspection of the local
working tree plus writes confined to `dozenos-rebrand/` (this document and
the `overlay/` skeleton). `rename-transform.sh` was run only against the
disposable `<scratch>/up` export, never against the live `vyos-build` tree.
