# MLNX-AND-DWARF.md — Mellanox OFED build (#19) + neutral-mount DWARF debranding (#25)

Authoritative spec for two folded items: **#19** ("mlnx" — the Mellanox OFED
out-of-tree driver, the last unbuilt package in the generic-ISO closure) and
**#25** (kernel + OOT-module DWARF/build-path debranding — `/vyos` baked
into compiled debug info by the *build environment*, not by source content).
They fold together because #25's fix (build under a neutral, non-`vyos`
mount) is exactly what makes a from-here-on mlnx build ship clean, and mlnx
is the one OOT-module recipe that was never built at all (so it is the
cleanest place to *require* the #25 fix rather than retrofit it).

Both items are **statically audited and wired here — neither was executed**.
mlnx is a multi-GB, root-privileged, kernel-tree-dependent build; see
`overlay-dozenos-build/logic-patches/` and `wire-prebuild-hooks.sh` for the general
pattern this document extends. See `RETROSPECTIVE.md` §2(a) and
`missing.md`#7/#8/#11 for the prior-cycle history this document formalizes.

## 1. mlnx build model (item #19)

### 1.1 How it is invoked

`scripts/package-build/linux-kernel/package.toml` declares:

```toml
[[packages]]
name = "mlnx"
commit_id = ""
scm_url = ""
build_cmd = "build_mellanox_ofed"
```

`python3 build.py --packages mlnx` (run with cwd =
`scripts/package-build/linux-kernel/`) is a **real, working selector** —
`build.py`'s `--packages` arg filters `config['packages']` by the `name`
field (`build.py:297-298`), matches this block, and its bespoke dispatcher
(`build.py:156-157`) calls `build_mellanox_ofed()`, which shells out to
`sudo ./build-mellanox-ofed.sh` (`build.py:238-240`). This confirms
`missing.md`'s row #7 verdict ("Build via `python3 build.py --packages
mlnx`") and `DOZENOS-CICD-PLAN.md`'s Phase-4 line for #19.

Like every other block in this recipe, `mlnx` is **excluded** from the C2
`pre_build_hook` mechanism (`wire-prebuild-hooks.sh`'s `EXCLUDE_RECIPES`) —
`linux-kernel/build.py` never reads `pre_build_hook` at all (verified: zero
references to that string in the file), so wiring it here would be dead
config. This is not mlnx-specific; it's the same reason all 16 blocks in
this recipe are excluded (see `overlay-dozenos-build/MANIFEST.md`'s "wire-prebuild-hooks.sh
narrowing" section).

### 1.2 Precondition: a real kernel tree

`build-mellanox-ofed.sh` requires `kernel-vars` (written by
`build-kernel.sh`) to exist and sources it for `KERNEL_DIR`/`KERNEL_VERSION`/
`KERNEL_SUFFIX`/`EPHEMERAL_KEY`/`EPHEMERAL_CERT` — it refuses to run
otherwise ("run ./build_kernel.sh first"). Per `missing.md`#8, a
`make mrproper`'d kernel tree lacks `.config`/`Module.symvers`, which OOT
modules need under `CONFIG_MODVERSIONS=y`; the established fix (already used
for the other 13 OOT drivers) is to prepend `linux-kernel` to the
`--packages` list in the same invocation so `Module.symvers`/`kernel-vars`/
the ephemeral signing key get regenerated fresh in the same run mlnx uses:
`python3 build.py --packages linux-kernel mlnx`. This is not new to mlnx —
it's the same precondition every OOT driver in this recipe has — but it is
the mechanism by which §2 below (neutral mount) actually reaches mlnx: a
freshly regenerated `kernel-vars` inherits whatever `$CWD` the *current*
container run used.

### 1.3 Source origin and residual classification

`build-mellanox-ofed.sh` fetches
`https://www.mellanox.com/downloads/ofed/MLNX_OFED-24.07-0.6.1.0/MLNX_OFED_SRC-debian-24.07-0.6.1.0.tgz`
directly from Nvidia/Mellanox's own site (`mellanox.com`) — **not**
`packages.vyos.net/source-mirror` like `build-intel-qat.sh`/
`build-realtek-r8126.py`/`build-realtek-r8152.py` (the three recipes
`overlay-dozenos-build/logic-patches/revert-source-mirror-urls.sh` targets). Confirmed by
diffing the reproduced mode-B clone against the pristine upstream script:
**zero bytes of this URL, or the `install.pl` flags, or the SOURCES-removal
list, differ from upstream** — the only lines the four-form transform
touches are two unused-downstream local variable *values*
(`DEBIAN_DIR`/`DEBIAN_POSTINST`, see §1.4). Classification: **third-party
vendor download, already zero-`vyos`, no revert/pin script needed** — same
class as `mellanox.com` being called out (already, independently) in
`vyos-build/BUILD-LOCAL.md:400` ("mellanox.com — untouched (no vyos
token)").

### 1.4 What the four-form transform touches — and why it's harmless

Diffing the reproduced clone's `build-mellanox-ofed.sh` against pristine
upstream shows exactly 2 literal-string changes, both inert:

```diff
-DEBIAN_DIR="${CWD}/vyos-mellanox-${DRIVER_NAME}_${DRIVER_VERSION}_${DEBIAN_ARCH}"
+DEBIAN_DIR="${CWD}/dozenos-mellanox-${DRIVER_NAME}_${DRIVER_VERSION}_${DEBIAN_ARCH}"
-DEBIAN_POSTINST="${CWD}/vyos-mellanox-ofed.postinst"
+DEBIAN_POSTINST="${CWD}/dozenos-mellanox-ofed.postinst"
```

Both vars are **dead in this script**: `DEBIAN_DIR` is only used as a scratch
`--builddir ${DEBIAN_DIR}/mlx` argument to `install.pl` (a working directory,
not a package name) and is `rm -rf`'d at the end; `DEBIAN_CONTROL`
(`${DEBIAN_DIR}/DEBIAN/control`) and `DEBIAN_POSTINST` are declared but never
referenced again anywhere in the file (verified by a full read — unlike
`build-intel-qat.sh`/`build-nat-rtsp.sh`/`build-ipt-netflow.sh`, which *do*
feed these same-named vars into an `fpm -n ...` packaging call, mlnx never
calls `fpm` — its debs come straight from `install.pl`'s own RPM→DEB
conversion). These are vestigial upstream variables, likely left over from
an earlier packaging approach; the transform renaming them is a no-op for
any shipped artifact. **No special-casing needed** — the generic four-form
content rule (`rename-transform.sh`) is a strict superset here exactly as
`overlay-dozenos-build/MANIFEST.md`'s "logic-patches" section states for the rest of this
recipe.

### 1.5 Emitted `.deb` names — none are `vyos`-named

`install.pl --basic --dpdk --without-dkms --without-mlnx-nvme-modules
--with-vma --vma-vpi --vma-eth --guest --hypervisor` builds MLNX_OFED's own
Debian package set (upstream RPM→DEB conversion; the recipe deliberately
`rm -f`s the SOURCES tarballs for ~24 sub-components it does not want built —
`ibarr`, `ibdump`, `ibsim`, `iser`, `isert`, `kernel-mft`, `knem`, `libvma`,
`libxlio`, `mlnx-ethtool`, `mlnx-iproute2`, `mlnx-nfsrdma`, `mlnx-nvme`,
`mlx-steering-dump`, `mpitests`, `mstflint`, `ofed-scripts`, `openmpi`,
`openvswitch`, `perftest`, `rdma-core`, `rshim`, `sockperf`, `srp`, `ucx` —
before `install.pl` even runs, at `build-mellanox-ofed.sh:74-98`, an
upstream-authored trim, unrelated to rebranding). Every produced `.deb` is
copied verbatim by filename (`build-mellanox-ofed.sh:116`,
`find ... | grep '\.deb$'`) — the script never renames, repackages, or
relabels any of them. The one deb name the script hardcodes and depends on
by exact name is `mlnx-ofed-kernel-modules_*` (the kernel-module deb,
signed via `sign-modules.sh` — see `SB-SIGNING.md` §2, which already lists
`build-mellanox-ofed.sh` as a covered module-signing caller). **All emitted
deb names are Mellanox/OFED/rdma-core project names — none carry `vyos` in
any of the four case forms.**

## 2. Rebrand mechanism — justified absent

**No rebrand step is codified for mlnx's output**, because none is needed:

- The fetched source is third-party (Nvidia/Mellanox), not VyOS's own —
  same non-rebrand class as `mellanox.com` firmware/driver blobs generally.
- The only two literal-`vyos` occurrences in the recipe's own script are
  dead local variables (§1.4), already correctly rewritten by the existing
  generic four-form transform — no per-recipe special case required, and
  none is shipped either way.
- Every real, shipped `.deb` filename/`Package:` field comes from
  `install.pl`'s own upstream naming (verified: the fetch URL, the
  `SOURCES/*.tar.gz` removal list, the `install.pl` flags, and the
  `mlnx-ofed-kernel-modules_*` glob are all byte-identical to pristine
  upstream) — there is no `vyos`-named artifact to rebrand.
- Confirmed against the reproduced mode-B `--verify` residual list (§4): mlnx
  contributes **zero** of the 9 known `--ci`-mode residual hits — it is not
  in that list at all.

If a future MLNX_OFED version ever ships a package whose *name* contains
`vyos` (nothing in the current 24.07-0.6.1.0 source does), the correct place
to add a rename step would be a new `overlay-dozenos-build/logic-patches/` script
(idempotent, `grep`-detect pattern, same idiom as
`revert-source-mirror-urls.sh`) inserted into `build-mellanox-ofed.sh`
between the `cp` at line 116 and the signing step at line 122 — **not**
invented speculatively here, per the task's "do not invent a rebrand for
non-vyos names" rule.

## 3. Neutral-mount / DWARF audit (item #25)

### 3.1 The mechanism, and where it already lives

Compiled artifacts (kernel `vmlinuz`, `.ko` OOT modules, and any C/C++
binary) bake the **build environment**, not just source content, into
debug info and some `.rodata` strings: DWARF `DW_AT_comp_dir`,
`-ffile-prefix-map` remnants, `__FILE__` macro expansions, and (for tools
like VPP) a build-user banner string. None of this is source text, so
`rename-transform.sh`'s four-form content rule cannot fix it — it has to be
fixed by *building under a neutral environment* in the first place. Two
environment facts drive it:

1. **The container mount/workdir path.** Building under `vyos/vyos-build`'s
   own upstream image with `-v "$PWD":/vyos -w /vyos` puts `/vyos/...` into
   every compiled object's comp_dir.
2. **The build user.** Upstream's `docker/entrypoint.sh` creates/execs as
   `USER_NAME="vyos_bld"` (`HOME=/home/vyos_bld`), which leaks into
   `"Compiled by: vyos_bld"`-style banners and Go `-ldflags` build-user
   strings.

**Both are already fixed structurally, and verified in the reproduced
mode-B tree (not just claimed):**

- `docker/entrypoint.sh` — reproduced clone shows `USER_NAME="dozenos_bld"`
  (`entrypoint.sh:4`) already, with zero further `vyos_bld`/`/vyos` hits in
  `docker/`. This is not a hand patch: `vyos_bld` contains the literal
  substring `vyos`, so the **generic** four-form content rule already
  rewrites it on every fresh mirror — no dedicated overlay script needed,
  confirmed by grepping the reproduced clone (§4).
- The two authored CI workflows that run container builds already mount and
  work at the neutral path, not `/vyos`:
  - `overlay-dozenos-build/new-files/.github/workflows/rebuild-packages.yml:135-136`:
    `-v "${{ github.workspace }}/dozenos-build:/dozenos" ... -w /dozenos`.
  - the same `.../dozenos-build:/dozenos` pattern in every other
    container-build job (`rebuild-dispatch.yml`, `nightly.yml`).
- The self-built local image `dozenos/dozenos-build:rolling`
  (`docker/Dockerfile`, tagged locally per `.powerloop/2026-07-07-rebrand.note.md`
  item #14) plus the **canonical launch**
  (`docker run -v "$(pwd)":/dozenos -v <dozenos-rebrand>:/dozenos-rebrand:ro
  -w /dozenos ... dozenos/dozenos-build:rolling`, documented in the local,
  untracked `vyos-build/BUILD-LOCAL.md`) was already built and
  **leak-gone-proven** on a real rebuild (`unionfs-fuse`): native
  `content=0/list=0`, no byte-patch, DWARF comp_dir reads
  `/dozenos/scripts/package-build/unionfs-fuse/...`, maintainer
  `@dozenos.local`. Re-verified again on `podman` (a heavy Go build) with
  the same native-clean result. See `RETROSPECTIVE.md` §2(a) and
  `.powerloop/2026-07-07-rebrand.note.md` items #14/#33/#34.

**Net: the neutral-mount mechanism this item asks for already exists and is
already wired into both the mode-B CI pipeline and the local canonical
build image.** No Dockerfile/entrypoint/workflow code change was needed —
this section documents and closes the audit, it does not introduce a new
fix for those files.

### 3.2 Where `/vyos` genuinely still leaks — and why it needs no code fix

Grepping the **reproduced, fresh mode-B clone** (§4) for a hardcoded
absolute `/vyos` path across `*.sh`, `*.py`, `Dockerfile`, `*.yml`, `*.toml`,
and then a broader unrestricted-extension pass over the whole tree, finds
**zero** hardcoded `/vyos` filesystem paths anywhere in shipped source.
`scripts/package-build/linux-kernel/kernel-vars` is the one place a literal
`/vyos` path currently exists — but only in the **local, untracked, git-
ignored** working copy at `/home/date/git/dozenos/vyos-build/`, not in any
shipped file:

```
$ cat vyos-build/scripts/package-build/linux-kernel/kernel-vars
export KERNEL_DIR=/vyos/scripts/package-build/linux-kernel/linux
```

This is a **stale generated artifact**, not a hardcode: `kernel-vars` is
listed in `scripts/package-build/linux-kernel/.gitignore` (never committed,
never shipped) and is written fresh by `build-kernel.sh:118-124` every
kernel build via `KERNEL_DIR=${CWD}/${KERNEL_SRC}` — computed from the
**current** working directory at build time, not a fixed string. The
`/vyos` value on disk right now is a leftover from the local powerloop
cycles that ran the kernel + all 13 already-built OOT drivers under the
*pre*-#14 upstream `vyos/vyos-build:rolling` image (`-v "$PWD":/vyos -w
/vyos`, see `vyos-build/BUILD-LOCAL.md:412`) — before the neutral-mount
image existed. Rebuilding `linux-kernel` under the canonical
`-v "$(pwd)":/dozenos -w /dozenos dozenos/dozenos-build:rolling` launch
regenerates `kernel-vars` with `KERNEL_DIR=/dozenos/scripts/package-build/linux-kernel/linux`
automatically — **no script edit required**, confirmed by reading the
heredoc source (§3.1 already established the mount+user half; this closes
the loop for the one dynamic value mlnx itself consumes,
`build-mellanox-ofed.sh:22,108`, `--kernel-sources ${KERNEL_DIR}`).

**Consequence for #19/#25 together:** `RETROSPECTIVE.md` §2(a) already
tracks this precisely — "item #25 tracks rebuilding the kernel and OOT
modules (the one package group never rebuilt under #14) under the new image
for a *native* fix instead of byte-substitution" — and mlnx was *never*
built at all, so unlike the other 13 already-built OOT drivers (which
currently still carry native, un-patched `/vyos` DWARF from the pre-#14
image and are pending a rebuild), **mlnx has no legacy artifact to clean
up: the very first time it is built, it must be built under the canonical
`/dozenos` launch with a freshly regenerated `kernel-vars`, and it will ship
native-clean with no byte-patching step ever needed.** This document is the
wiring that makes that the documented, required procedure rather than an
accident of whichever image happens to be on hand.

### 3.3 Verification a maintainer runs on a real build

None of the following were run in this session (see §5) — they are the
procedure to run once a real mlnx build exists:

```sh
# 1. Confirm the launch used the neutral mount (sanity, before inspecting output):
#    must show /dozenos, never /vyos, as the workdir the build actually ran in.

# 2. Build linux-kernel + mlnx together (regenerates kernel-vars fresh):
docker run --rm \
  -v "$(pwd)":/dozenos \
  -v /home/date/git/dozenos/dozenos-rebrand:/dozenos-rebrand:ro \
  -w /dozenos/scripts/package-build/linux-kernel --privileged \
  --sysctl net.ipv6.conf.lo.disable_ipv6=0 \
  -e GOSU_UID=$(id -u) -e GOSU_GID=$(id -g) \
  dozenos/dozenos-build:rolling \
  bash -c 'sudo apt-get update && python3 build.py --packages linux-kernel mlnx'

# 3. Extract the kernel-module deb and check for a /vyos comp_dir/string leak:
dpkg-deb -x mlnx-ofed-kernel-modules_*.deb /tmp/mlnx-extract
find /tmp/mlnx-extract -name '*.ko' -print0 | xargs -0 -I{} sh -c '
  echo "== {} =="
  readelf --debug-dump=info {} 2>/dev/null | grep -i comp_dir
  strings {} | grep -i "/vyos\|vyos_bld"
'
# Expected: readelf prints comp_dir=/dozenos/... (or no DWARF at all, if the
# kernel build strips debug info); strings prints NOTHING.

# 4. Confirm no /vyos leaked into any non-.ko file in the same deb (postinst,
#    control, docs):
grep -rI 'vyos' /tmp/mlnx-extract || echo "clean"

# 5. Cross-check against the project's existing residual-scan convention
#    (same check already used for vpp/openssl/isc-kea/accel-ppp, see
#    RETROSPECTIVE.md §2(a) and missing.md#11):
#    content vyos count + control vyos count, both expected 0.
```

If step 3 or 4 finds a residual, it means either (a) a stale extracted
source tree was reused (clean `scripts/package-build/linux-kernel/ofed*`
and re-run — this is the one documented gotcha, see
`vyos-build/BUILD-LOCAL.md`'s "Leak-gone PROOF" caveat) or (b) the launch
did not actually use the `/dozenos` mount+workdir — re-check the exact
`docker run` invocation against §3.3 step 2 verbatim.

## 4. Static verification performed this cycle

Reproduced the mode-B pipeline fresh (not assumed) via:

```sh
dozenos-rebrand/mirror-push.sh https://github.com/vyos/vyos-build.git \
  --target dozenos-build --build-repo --dry-run --work <scratch>
```

- Pipeline completed clean: clone @ upstream `fce9b6d` → `rename-transform.sh`
  → `.github/` strip → `wire-prebuild-hooks.sh` (39 recipes/44 blocks wired,
  `linux-kernel` correctly excluded) → `apply-overlay.sh --ci` (22 new-files,
  2 logic-patches, 4 value-fix scripts) → `--verify` (9 residuals, all
  pre-known build-time pointers per `overlay-dozenos-build/MANIFEST.md`/`REPOINT-AUDIT.md`
  — **mlnx/kernel-vars/DWARF is not among them**).
- `<clone>/scripts/package-build/linux-kernel/build-mellanox-ofed.sh` is
  **byte-identical** to the corresponding file in the local hand-audited
  `vyos-build/` working tree (`diff`, exit 0) — confirms the live tree's
  prior hand-edits and the generic transform agree.
- `<clone>/scripts/package-build/linux-kernel/package.toml`'s `mlnx` block
  is unchanged from pristine upstream (`name`/`commit_id`/`scm_url`/
  `build_cmd` all identical) — `--packages mlnx` is real and untouched.
- Grepped the reproduced clone for hardcoded `/vyos` paths across
  `*.sh`/`*.py`/`Dockerfile`/`*.yml`/`*.toml` and again with no extension
  filter: **zero hits** (the 4 remaining `vyos/...` strings in the tree are
  all `github.com/vyos/*` git URLs — a different, already-tracked residual
  class — not filesystem paths).
- Confirmed `docker/entrypoint.sh`'s `USER_NAME="dozenos_bld"` and
  `rebuild-packages.yml`'s `-v .../dozenos-build:/dozenos
  -w /dozenos` are present in the **reproduced clone itself**, not only in
  hand-maintained overlay source — i.e. a fresh mirror push today would
  already carry the #25 fix for every C2/CI-driven build.
- Ran the full `dozenos-rebrand/test/*.sh` suite: **133/133 assertions
  green** (13+44+20+25+13+18 across the 6 suites), unchanged by this cycle
  (no toolkit script was modified — see §5).

## 5. Statically-verified vs CI-only split

| Claim | Status |
|---|---|
| `--packages mlnx` is a real, working selector | **Statically verified** (code read + reproduced clone) |
| mlnx's fetched source is third-party, zero-`vyos` | **Statically verified** (URL + diff vs pristine upstream) |
| No mlnx `.deb` is `vyos`-named | **Statically verified** (script logic — `install.pl` never renames; no `fpm -n` call in this recipe) |
| No rebrand step needed | **Statically verified**, justified absent (§2) |
| CI build image + workflows mount `/dozenos`, not `/vyos` | **Statically verified** (reproduced-clone `entrypoint.sh` + both workflow YAMLs) |
| Local canonical build image is neutral-mount and leak-gone-proven | **Verified in a prior session** (`unionfs-fuse`/`podman` rebuilds, documented in `RETROSPECTIVE.md`/`.powerloop` notes) — **not re-run this cycle** |
| `kernel-vars`' stale `/vyos` value self-corrects on rebuild | **Statically verified** (read `build-kernel.sh`'s heredoc — dynamic `${CWD}`, not hardcoded) |
| An actual mlnx build produces zero-`vyos`, native-clean (no byte-patch) `.deb`s and modules | **CI-only** — requires the real multi-GB, root-privileged, kernel-tree-dependent build; **not run in this session** (§3.3 gives the exact commands to run it) |
| Every OOT-driver DWARF/comp_dir is currently `/dozenos`-clean | **CI-only** — the 13 *already-built* OOT drivers in `vyos-build/scripts/package-build/linux-kernel/` were built under the *pre*-#14 `/vyos`-mounted image and are pending a rebuild under the canonical launch (tracked, not this document's job to execute) |

## 6. Cross-references

- **#13 (ISO assembly)**: the generic-ISO build consumes whichever `.deb`s
  are present in `packages/`; mlnx is the last OOT driver never added there
  (`missing.md`#7 "SKIPPED"). Once built per §3.3, its deb joins the same
  selective-copy flow the other 13 drivers already use
  (`vyos-build/BUILD-LOCAL.md`'s "OOT kernel drivers (item #8 part 2)"
  table) — no new ISO-assembly logic needed.
- **#16 (build-dependency graph)**: the memory file
  `dozenos-build-dependency-graph` already lists mlnx under "All OOT kernel
  modules → linux-kernel" (a kernel bump must rebuild it, same as every
  other OOT driver) — confirmed still accurate, no edge changed by this
  audit. See that memory file for the fan-out rule this feeds a future
  incremental-rebuild CI (Phase 6).
- **`SB-SIGNING.md` §2**: already lists `build-mellanox-ofed.sh` as a
  covered `sign-modules.sh` caller for the kernel-module signing chain —
  unaffected by, and independent of, the DWARF/comp_dir concern this
  document covers (module *signing* and module *debug-path provenance* are
  orthogonal).
- **`overlay-dozenos-build/MANIFEST.md`**: "wire-prebuild-hooks.sh narrowing" section is
  the authoritative reason `mlnx`/`linux-kernel` never gets a
  `pre_build_hook` — referenced, not duplicated, in §1.1 above.
- **`RETROSPECTIVE.md` §2(a)** and **`missing.md`#7/#8/#11**: prior-cycle
  history this document formalizes into a durable spec; not superseded, only
  consolidated.
