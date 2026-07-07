# DozenOS Local Build — Retrospective (復盤)

This is Phase 0 of `DOZENOS-CICD-PLAN.md`: a handoff summary of the completed
local-build powerloop (`.powerloop/2026-07-07-rebrand.note.md`, items #1–#23),
so a future GitHub Actions pipeline does not have to re-derive decisions
already made here. It answers three questions: **what did we build**, **what
landmines did we hit and how were they solved**, and **what is safe to
automate in CI vs what was a one-time human judgment call**.

Sources: `.powerloop/2026-07-07-rebrand.note.md` (Progress Table + Log Table),
`dozenos-rebrand/LANDMINES.md`, `vyos-build/BUILD-LOCAL.md`,
`dozenos-rebrand/{rebrand-map.conf,rename-transform.sh}`.

---

## 1. What was built (items #1–#23)

The goal: produce a locally-built, bootable DozenOS ISO that is a rebrand of
`vyos-build` (`rolling`) with **zero genuine `vyos` brand strings** in shipped
artifacts (`vyatta` and third-party upstream strings excepted), using only
self-built packages and Debian — no VyOS apt mirror.

### Narrative, grouped

**Toolkit (#1–#3).** Before touching `vyos-build` itself, we built the
transform tool: `dozenos-rebrand/rename-transform.sh`, a case-preserving
four-form substitution (`vyos→dozenos`, `VyOS→DozenOS`, `VYOS→DOZENOS`,
`Vyos→Dozenos`) that rewrites file contents, filenames, and symlink targets,
and is provably idempotent (a second pass is a no-op) and non-overlapping
with `vyatta` (preserved automatically — verified with a `--verify` grep
gate). `rebrand-map.conf` carries the C1 package-name map and email
rewrites; `LANDMINES.md` catalogues the special cases up front so later
build items didn't have to rediscover them. Baseline smoke (#1) confirmed
the upstream `vyos/vyos-build:rolling` container and `build-vyos-image`
entrypoint work before any rebrand changes landed.

**Shipped-surface rebrand (#4–#5).** Applied the transform to `vyos-build`
itself: `data/defaults.toml` (`kernel_flavor`, `vyos_mirror`), live-build
hooks, systemd service names, hardcoded paths (`/usr/{libexec,share}/vyos`,
`/run/vyos`, `/etc/vyos`, `/var/log/vyos*`), dbus/apparmor, os-release,
hostname, GRUB, ISO volid. `/opt/vyatta` and `scm_url` were deliberately left
untouched (see landmine classes below). Throwaway local GPG/minisign
signing keys were generated for the local build (real production keys are
Phase 1, not this phase).

**C1 package builds (#6–#7).** Rebuilt the packages whose *names* contain
`vyos` (C1 class): `vyos-1x`→`dozenos-1x` (+ `-aws`/`-vmware`/`-smoketest`
flavors, `libdozenosconfig0`, `dozenos-user-utils`), plus
`libnss-mapuser`, `libpam-radius-auth`+`radius-shell`, and
`vyos-http-api-tools`→`dozenos-http-api-tools` (new recipe authored from
scratch). All zero-`vyos` in name/paths/control; dbgsym excluded.

**Kernel + OOT drivers (#8).** Rebuilt the kernel with
`kernel_flavor=dozenos` (`uname -r` → `6.18.36-dozenos`) plus 13 of 14
out-of-tree driver packages (7 Intel, 2 Realtek, ipt-netflow, firmware,
jool, nat-rtsp) rebuilt against the matching vermagic. Mellanox OFED
(`mlnx`, #19) was deferred as a heavy multi-GB build — user directive was to
build it eventually, not skip it permanently.

**C2 recipes + gap sources (#9, #15–#21).** 42 build recipes were classified
into C1 (rename+rebuild, 5), C2 (VyOS-patched but name unchanged — rebuild,
transform shipped content, 37), and Debian-passthrough (0) — recorded in
`recipe-worklist.md` as the source of truth. All 37 C2 recipes needed for
the generic-ISO dependency closure were built (frr+libyang3, isc-kea, vpp,
strongswan, podman, telegraf, openssl, Go exporters, unionfs-fuse, libhtp,
accel-ppp-ng, and more); a handful of cloud-agent recipes (zerotier-one,
waagent, xen-guest-agent, amazon-*, tacacs before reclassification) were
built for parity but deliberately **not** copied into `packages/` because the
generic ISO doesn't depend on them. Five additional recipes with no
pre-existing build script (`vyatta-bash`, `vyatta-biosdevname`, `vyatta-cfg`,
`ipaddrcheck`, `hvinfo`) were authored from scratch after the first ISO
build attempt surfaced them as unmet dependencies (#9). `vyos1x-config` and
`vyconf`, the external OCaml libs `libdozenosconfig0` links against, were
themselves rebranded and rebuilt (#17) to close the last zero-`vyos` gap in
that shared library.

**Sourcing strategy (#10).** Decided Strategy B: ISO packages come only from
the local `packages/` directory plus stock Debian — the VyOS apt mirror is
dropped entirely (a guard edit makes `vyos_mirror` empty skip that repo
line cleanly rather than emit a malformed apt source).

**ISO build + acceptance (#11–#12).** The ISO build was iterative: each
attempt surfaced missing/broken dependencies (tacacs reclassified from
cloud-only to core, `vpp-dev`/`bash-completion` version-pin issues, stray
`-dev`/`-aws`/`-vmware` overreach) which were fixed and fed back until a
clean build succeeded:
`build/dozenos-1.5-rolling-202607071321-generic-amd64.iso` (680MB, bootable,
volume label `DozenOS`). Acceptance (#12) extracted the ISO tree, squashfs
(88,408 files), and all 100 shipped `.deb`s and grepped for `vyos`:
**PASS on the genuine-brand gate** — 0 hits outside of preserved `vyatta`
strings and legitimate third-party upstream data (IANA PEN, nmap
fingerprints, etc.). Two residuals were found and are tracked as their own
items rather than blocking acceptance: #25 (kernel/OOT-module DWARF still
carries `/vyos` build paths from before the neutral build image existed —
inert) and #26 (a genuine VyOS-branded Secure Boot MOK certificate is
shipped, decision pending).

**Credential debrand (#23).** A user-reported gap: the default login's
*username* was correctly transformed to `dozenos`, but the default
*password* is stored as a SHA-512 crypt hash of the plaintext `vyos` — a
hash contains no literal `vyos` substring, so it passed the #12 grep gate
while the functional credential was still `vyos`. Fixed by regenerating the
hash for the new default `dozenos`/`dozenos` and patching all 5 places the
old hash appeared (source + shipped debs), then documenting the blind spot
in `LANDMINES.md` as a general rule (see below).

### Compact status table

| Group | Items | Result |
|---|---|---|
| Toolkit | #1–#3 | done — `rename-transform.sh`, `rebrand-map.conf`, `LANDMINES.md` |
| Shipped-surface rebrand | #4–#5 | done — branding, paths, services, throwaway keys |
| C1 packages | #6–#7 | done — dozenos-1x + 4 other C1 packages |
| Kernel + OOT drivers | #8 | done (kernel + 13/14 drivers); mlnx (#19) deferred, not skipped |
| Recipe classification | #15 | done — 42 recipes → `recipe-worklist.md` |
| Gap-source recipes | #9 | done — 5 new recipes authored |
| C2 recipe builds | #16, #18, #20, #21 | done for the generic-ISO closure |
| OCaml lib rebrand | #17 | done — closed the last zero-`vyos` hole in `libdozenosconfig0` |
| Sourcing strategy | #10 | done — Strategy B, no VyOS mirror |
| ISO build | #11 | done — bootable ISO produced |
| Acceptance grep | #12 | **PASS** on genuine-brand gate |
| Build procedure doc | #13 | `vyos-build/BUILD-LOCAL.md` |
| Credential debrand | #23 | done — password hash regenerated |
| Residuals (not blocking) | #25, #26 | open — tracked, not required for local-ISO acceptance |
| Mellanox OFED | #19 | pending — heavy build, deferred |

---

## 2. Landmine classes and how each was solved

These are the recurring *classes* of problem, distilled from the individual
cases in `LANDMINES.md` and the build log, so future package additions can
be checked against the same list instead of rediscovering them one at a
time.

### (a) Build-env leak — `/vyos` mount path + `vyos_bld` user baked into ELF

Compiling under the *upstream* `vyos/vyos-build:rolling` container mounts
the source tree at `/vyos` and runs the build as user `vyos_bld`. Neither of
these are text in our source — they're environment facts — so the four-form
transform can't touch them, yet they end up as literal strings in compiled
artifacts: `DWARF` `comp_dir`, `-ffile-prefix-map` remnants, Go
`-ldflags` build-user strings, RPATH-adjacent `.rodata`, etc.

**Solved structurally by item #14**: a self-built `dozenos/dozenos-build:rolling`
image with build user renamed `vyos_bld`→`dozenos_bld` (home
`/home/dozenos_bld`), launched with a neutral mount point (`-v "$PWD":/dozenos
-w /dozenos`) instead of `/vyos`. Builds done under this image are natively
clean — no byte-patching needed (proven on `podman`/`telegraf`: 0 `vyos` hits
without any post-fix). One caveat found: stale extracted source trees with
cached `.o` files carry the old path in cached DWARF and must be removed
(`rm -rf <recipe>/<src>/`) before rebuilding under the new image, or the
relink silently reuses the tainted objects.

**Interim workaround for packages built before #14 existed** (vpp, openssl,
isc-kea, accel-ppp-ng, Go exporters): same-length in-place byte
substitution (`vyos`→`xxxx`, `vyos_bld`→`xxxx_bld`) directly on the built
`.deb`'s ELF strings. Because the replacement is always exactly as long as
the original, every other byte offset in the file is untouched — provably
zero feature/ABI diff. This is accepted as adequate for the local-ISO
acceptance gate (#12 passed with it in place) but is cosmetic-only; item
#25 tracks rebuilding the kernel and OOT modules (the one package group
never rebuilt under #14) under the new image for a *native* fix instead of
byte-substitution.

### (b) Hashed credentials — debrand by value, not string

`vyos-1x/data/config.boot.default` ships the default login. The username
transforms cleanly (`user vyos`→`user dozenos`), but the default password is
stored as a SHA-512 crypt hash of the plaintext `vyos`
(`$6$QxPS.uk6mfo$…`). A crypt hash has no literal `vyos` substring, so
`grep -ri vyos` returns 0 — passing the #12 acceptance gate — while the
credential is still functionally `vyos`. This is a **blind spot**: the
grep-based acceptance gate cannot prove credential debranding.

**Solved by item #23**: regenerated the hash for the new default
`dozenos`/`dozenos` (`openssl passwd -6 dozenos`) and replaced the old hash
in all 5 places it appeared (`data/config.boot.default`,
`tests/data/config.boot.default`, `src/tests/test_initial_setup.py`,
`smoketest/configs/firewall-groups-name{,/assert}`), plus the already-shipped
debs, then regenerated `md5sums`. Verified the new hash validates `dozenos`
and rejects `vyos`.

**General rule (recorded in `LANDMINES.md`):** anything debranded by *value*
rather than *string* — password hashes, checksums of renamed files, signed
digests, pre-generated keys — is invisible to the text transform and must
be audited explicitly on every upstream sync. `config.boot.default` /
cloud-init seeds / any `encrypted-password` field are the known instances;
there may be others not yet found.

### (c) Exact-version pins vs the `+git` auto-stamp

`vyatta-cfg`'s `debian/control` pins `bash-completion (= 1:2.8-6)` exactly —
Debian bookworm only ships `1:2.11-6`, so VyOS carries its own older
`bash-completion` build to satisfy that pin. `build.py`'s default version
stamping appends `+git<date>.<sha>` to built packages for apt
monotonicity, which turned the version into
`1:2.8-6+git20260707...` — breaking the exact `=` dependency (nothing
satisfies `= 1:2.8-6` anymore once stamped).

**Solved by un-stamping exact-pinned packages**: repacked `bash-completion`'s
version back to exactly `1:2.8-6` (it is an unpatched Debian source with no
transform needed, so the stamp was pure overhead). **General rule for CI**:
before applying the `+git` stamp hook to a recipe, check whether any
*other* package in the closure depends on it with an exact `=` pin; if so,
skip stamping that recipe. This is the same class of bug as any future
`+git`-stamped package that something else exact-pins — watch for it on
every new recipe, not just `bash-completion`.

### (d) External-upstream references (opam pins / `scm_url`)

Some package trees reference *other* upstream repositories as build-time
fetch sources — e.g. `libvyosconfig/Makefile`'s opam pins for
`vyos1x-config`/`vyconf` point at `github.com/vyos/*`, and `bindings.ml` does
`open Vyos1x`. Four-form-rebranding these blindly breaks the build (`git
fetch` against `github.com/dozenos/vyos1x-config` 404s, since no such repo
exists yet), but *not* rebranding them means the linked binary keeps
`vyos1x` symbols, failing the zero-`vyos` acceptance gate.

**Solved for the local build (item #17)** by rebranding and rebuilding those
libraries too: cloned `vyos1x-config`, ran the four-form transform on it
(module `Vyos1x`→`Dozenos1x`), pinned `libdozenosconfig0`'s local opam
registry at the rebranded copy, updated `bindings.ml` to `open Dozenos1x`,
and rebuilt — the resulting `.so` is zero-`vyos` with proven C-ABI parity
(same exported symbol set, same soname). `scm_url` for build-only fetches
(tacacs, vpp, etc.) was left pointing at the real `github.com/vyos/*` for
this local build — see the note below on why this is temporary, not
permanent.

**This landmine class dissolves once the `github.com/dozenos` org exists**
(planned mirror of every VyOS repo — `dozenos-build`←`vyos-build`,
`dozenos1x-config`←`vyos1x-config`, etc., per Phase 2/3 of the CI/CD plan):
once a real `github.com/dozenos/vyos1x-config`-equivalent mirror exists,
`scm_url`/opam pins become ordinary four-form-transformable strings like
everything else, no exception needed. The local vendoring done for #17
(a local opam pin at a locally-cloned, locally-rebranded copy) is a
stand-in for that future mirror, not the permanent mechanism.

### (e) Selectivity — ship only the dependency closure

Across every C1/C2 recipe, the rule applied was: copy to `packages/` only
the runtime `.deb`s actually in the generic ISO's dependency closure.
Concretely:
- **No `-dev`/dbgsym packages** except where something in the closure has a
  genuine hard dependency on one (`vpp-dev` — `dozenos-1x` really does
  `Depends` on the full vpp set including `-dev`; this was tried as a
  removal in #21 and had to be reverted once the ISO build proved it
  necessary).
- **No flavor/test debs** (`dozenos-1x-aws`, `-vmware`) since the generic
  build type doesn't need them — except where a build-type genuinely
  requires it (`dozenos-1x-smoketest` **is** required by
  `data/build-types/development.toml`, so removing it in #21 was also a
  mistake that had to be reverted).
- **Cloud-agent recipes** (`zerotier-one`, `waagent`, `xen-guest-agent`,
  `amazon-ssm-agent`, `amazon-cloudwatch-agent`, and initially `tacacs`) are
  built for VyOS-parity ("build everything, just don't necessarily ship
  it") but not copied to `packages/`, because the generic-ISO flavor doesn't
  depend on them — except `tacacs`, which the #11 ISO build proved is
  actually a **core** `dozenos-1x` PreDepends (`libnss-tacplus` +
  `libpam-tacplus`), so it was reclassified from cloud-only to core and
  staged.

The lesson embedded in both #21 corrections: **selectivity decisions must be
verified against the actual ISO build's unmet-dependency output, not
assumed from the package's apparent category** — "looks cloud-only" and
"looks like a dev package" were both wrong once in this build.

---

## 3. Deterministic-in-CI vs one-time decision

| Deterministic (CI should redo this every run, same result every time) | One-time decision (recorded here so CI does not re-derive it) |
|---|---|
| Running `rename-transform.sh` (four-form + email rewrite) over a freshly cloned tree — idempotent, mechanical | The four-form mapping itself and the choice to preserve `vyatta` (`rebrand-map.conf`) |
| Building under `dozenos/dozenos-build:rolling` with the neutral `/dozenos` mount — eliminates the build-env leak natively, every build | That this image needed to be built at all, and its exact Dockerfile diff from upstream (`docker/` changes in item #14) |
| The C1/C2/Debian-passthrough classification *mechanism* (read `package.toml`, check if the binary name contains `vyos`) | The actual classification result per recipe (`recipe-worklist.md`) — re-derive only when a *new* recipe is added upstream |
| Stripping `-dev`/dbgsym packages by default | The specific exceptions (`vpp-dev`, `dozenos-1x-smoketest` for `development.toml`) — these were discovered empirically from ISO-build failures, not from a rule; a new upstream dependency change could add or remove exceptions and CI has no way to predict that except by re-running the ISO build and reading its unmet-dependency errors |
| `--verify` zero-`vyos` grep gate over shipped artifacts | Accepting `vyatta` and specific third-party upstream strings (IANA PEN, nmap fingerprints, `libfreeipmi`, dpkg upstream maintainer fields) as pre-existing exceptions, not brand leaks |
| Un-stamping (skip `+git` version stamp) for any recipe another package exact-`=`-pins | *Which* recipes currently have exact pins on them (`bash-completion` via `vyatta-cfg`) — a fixed, known list until upstream adds another exact pin |
| Regenerating a credential hash from a fixed plaintext (`openssl passwd -6 dozenos`) | The choice of default credential value itself (`dozenos`/`dozenos`, matching VyOS's user==password convention) and the specific 5 file locations the old hash occupied — an upstream sync must re-audit for new occurrences, this list is not guaranteed exhaustive |
| Byte-substitution debrand of pre-#14 artifacts (`vyos`→`xxxx`, same-length) | Obsolete going forward — once every recipe is rebuilt under #14, this mechanism should not be needed again; item #25 (kernel/OOT DWARF) is the last consumer |
| Rebuilding `vyos1x-config`/`vyconf` locally and re-pinning opam at the rebranded copy | Depends entirely on whether `github.com/dozenos/*` mirror repos exist yet (item #22/#24c) — this is a **temporary local stand-in**, not a permanent CI step; once mirrors exist, `scm_url` becomes an ordinary transformable string and the local-clone step goes away |
| Excluding cloud-agent debs from the generic ISO's `packages/` | Which specific packages are "cloud-only" vs "core" — this was **wrong twice** in this build (tacacs reclassified core; smoketest wrongly removed then restored) and was only settled by reading actual ISO-build dependency errors, not by category intuition |

---

## Known open residuals (not blocking, tracked separately)

- **#25** — kernel + all OOT kernel-module debs still carry `/vyos` build-path
  DWARF and a `vyos_bld` compile banner from before image #14 existed
  (never rebuilt since). Inert (dangling debug-info paths, no functional or
  brand-surface impact), but the byte-substitution interim fix was not
  applied to these because of their size; proper fix is a full kernel +
  OOT-module rebuild under image #14.
- **#26** — a genuine VyOS-branded Secure Boot MOK certificate
  (`/var/lib/shim-signed/mok/vyos-prod-2025-linux.pem`, filename + X.509
  subject/issuer literally "VyOS") is shipped in the squashfs. It passed the
  content-grep gate (PEM is base64, not literal text) but is a real branded
  artifact. Decision pending: remove for local build (Secure Boot is off
  anyway) vs. replace with a DozenOS-issued cert once Phase 1 production
  signing keys exist.
- **#19** — Mellanox OFED driver build was deferred (heavy, multi-GB); user
  directive was to build it eventually, not skip permanently.

## What this document intentionally does not cover

Per `DOZENOS-CICD-PLAN.md`, Phases 1–6 (signing keys/secrets, GitHub org +
mirror repos, upstream-sync pipeline, incremental rebuild triggers,
build-dependency graph) are out of scope for this retrospective — they are
the *next* work, informed by this document, not part of it.
