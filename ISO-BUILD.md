# ISO-BUILD.md — Signed, SB-capable DozenOS ISO (item #13)

Authoritative spec for how the DozenOS ISO build resolves and installs the
DozenOS-built `.deb` packages it needs, given the locked "no public apt
mirror" decision (`DISTRIBUTION.md` §1), and how that combines with Secure
Boot MOK signing (`SB-SIGNING.md`) to produce a signed, SB-capable ISO. This
document is the toolkit-side record for `release/make-ephemeral-apt-repo.sh`
and the CI wiring in `overlay/new-files/.github/workflows/package-smoketest.yml`.
Cross-references: `DISTRIBUTION.md` (#9, artifact tiers this item consumes),
`SB-SIGNING.md` (#10/#11, MOK signing this item's ISO build already carries),
`MLNX-AND-DWARF.md` (#12/#25, the neutral `/dozenos` mount this item's builds
already run under), `WORKFLOW-POLICY.md` (#7/#8, where the workflow files
this document extends come from), and the not-yet-authored item #17
(`dozenos-nightly-build`'s nightly workflow, which this document specs the
*full* version of the mechanism authored here for).

## 1. The problem: no public mirror, but the ISO still needs to apt-install DozenOS packages

`DISTRIBUTION.md` §1 locks DozenOS as image-based upgrade with **no public,
persistent apt mirror**. That is correct for *runtime* (`apt upgrade` never
happens on an installed system). It does **not**, by itself, solve
*build-time*: `scripts/image-build/build-dozenos-image`'s live-build chroot
assembly still runs `apt-get install` against whatever the ISO's package
lists declare, and one of those lists hard-requires a DozenOS-built package:

```
$ cat data/live-build-config/package-lists/dozenos-base.list.chroot
debconf
dozenos-1x
dozenos-user-utils
zstd
```

(`dozenos-1x`, `dozenos-user-utils` — verified present in every build
flavor's base package set, in the reproduced mode-B clone, §7 below.)
Every `generic`-flavor build also apt-installs `dozenos-1x-smoketest` via
`--custom-package` in `package-smoketest.yml` (same source recipe as
`dozenos-1x` — both are binary packages produced by ONE `dozenos-1x` C2
build, see §5). With no apt source configured at all, that install fails.
This item closes that gap **without hosting anything**, by building a real
apt repository that lives only inside the CI job producing the ISO.

## 2. The ephemeral in-job apt repo — the model

```
rebuild-packages.yml's build job (per-package matrix)
  -> dpkg-buildpackage -us -uc (unsigned, matches upstream, see that
     workflow's own header) inside ghcr.io/dozenos/dozenos-build:rolling,
     mounted at /dozenos (neutral mount, MLNX-AND-DWARF.md #25)
  -> actions/upload-artifact, name: deb-<pkg>, retention-days: 7
     (DISTRIBUTION.md tier (a), "ephemeral: CI-internal .deb passing")
        |
        | (this item: item #13)
        v
ISO-build job downloads deb-* artifacts
  -> release/make-ephemeral-apt-repo.sh <debs-dir> <output-dir>
     builds a real dists/-shaped apt repo: pool/main/*.deb +
     dists/rolling/main/binary-amd64/Packages(.gz) + dists/rolling/Release
  -> prints "[trusted=yes] file://<output-dir>" -- the value to pass to
     build-dozenos-image --dozenos-mirror
        |
        v
build-dozenos-image writes config/archives/dozenos.list.chroot:
  deb     [trusted=yes] file://<output-dir> rolling main
  deb-src [trusted=yes] file://<output-dir> rolling main
        |
        v
live-build chroot stage: apt-get update + apt-get install (dozenos-1x, ...)
resolve from the ephemeral repo -- no network egress needed for these
packages, no signature required ([trusted=yes]), the whole thing evaporates
when the job's runner is destroyed.
```

This reproduces exactly what a real apt mirror would give live-build (full
dependency resolution against a real `Packages` index), without ever
standing up a host, DNS name, TLS cert, or GPG-signed `Release` for anything
that outlives one CI job. No `DOZENOS_MIRROR_URL` or object-storage secret is
introduced — none exists (`CI-SECRETS.md`, "Not present" note) and none is
needed.

**Why `[trusted=yes]`, not GPG-signed:** `CI-SECRETS.md`'s "GPG role
reconciliation" section already anticipated this exact mechanism and already
decided the ephemeral repo's `Release` file does not need a GPG signature —
it never leaves the single-tenant build environment that both produced the
`.deb`s (unsigned, `-us -uc`) and consumes them. `GPG_PRIVATE_KEY`'s actual
role is narrower (GitHub Release / artifact signing, not apt-repo trust) —
see that document; this item does not change that reconciliation, only
implements the mechanism it already named.

## 3. The verified `build-dozenos-image` mirror flag

Reproduced the mode-B pipeline fresh (not assumed) via:

```sh
dozenos-rebrand/mirror-push.sh https://github.com/vyos/vyos-build.git \
  --target dozenos-build --build-repo --dry-run --work <scratch>
```

(clone @ upstream `fce9b6d` → `rename-transform.sh` → `.github/` strip →
`wire-prebuild-hooks.sh` → `apply-overlay.sh --ci` → `--verify`: 9 residuals,
all pre-known build-time pointers, matching `overlay/MANIFEST.md` exactly —
no drift from this item's changes). Read the reproduced clone's
`scripts/image-build/build-dozenos-image` directly (not assumed from
upstream docs): the CLI option is registered as

```python
'dozenos-mirror': ('DozenOS package mirror', None),
```

(`build-dozenos-image:192`, one flag — **not** four forms; upstream's own
`--vyos-mirror` was a single option, and the rename transform produces a
single `--dozenos-mirror` counterpart, confirmed by grepping the reproduced
clone for every `mirror`-shaped option). It is consumed here:

```python
if build_config.get('dozenos_mirror'):
    dozenos_repo_entry = "deb {dozenos_mirror} {dozenos_branch} main\n".format(**build_config)
    dozenos_repo_entry += "deb-src {dozenos_mirror} {dozenos_branch} main\n".format(**build_config)
    apt_file = defaults.DOZENOS_REPO_FILE   # config/archives/dozenos.list.chroot
    with open(apt_file, 'w') as f:
        f.write(dozenos_repo_entry)
else:
    print("I: dozenos_mirror empty -- skipping package-repo apt entry (zero-mirror build)")
```

(`build-dozenos-image:530-544`; the `if`/`else` guard is
`overlay/logic-patches/vyos-mirror-guard.sh`'s "KEEP the guard" decision,
already landed — see `overlay/MANIFEST.md`'s logic-patches section. Verified
still present, byte-identical, in this item's reproduced clone.)

Three consequences, all verified by reading the script (not guessed):

1. **`--dozenos-mirror`'s value is inserted RAW into the `deb`/`deb-src`
   line.** Whatever string is passed becomes the apt options+URL portion —
   this is exactly what lets `[trusted=yes] file:///abs/path` work with zero
   `build-dozenos-image` code changes: the flag was already a free-form
   string, never validated as a bare URL.
2. **The suite is `{dozenos_branch}`, hardcoded from `data/defaults.toml`
   (`dozenos_branch = "rolling"`) — there is no `--dozenos-branch` CLI flag**
   (confirmed: not in the `options` dict at `build-dozenos-image:186-198`).
   In practice this is always `rolling`.
3. **The component is the literal string `"main"`**, hardcoded in the
   f-string template itself, not a variable — never anything else for a real
   DozenOS build.

**Conclusion, and why `release/make-ephemeral-apt-repo.sh`'s defaults are
`--suite rolling --component main`:** those defaults are not arbitrary — they
are the only values that make the produced repo's `dists/<suite>/<component>/`
layout match what `build-dozenos-image` will actually request. `--dozenos-mirror`
must be given the `[trusted=yes] file://<output-dir>` fragment only (no suite/
component in it) — `build-dozenos-image` appends `{dozenos_branch} main`
itself.

## 4. `release/make-ephemeral-apt-repo.sh`

```
Usage: make-ephemeral-apt-repo.sh <debs-dir> <output-dir> [OPTIONS]
  --suite SUITE          default: rolling  (MUST match dozenos_branch, §3)
  --component COMPONENT  default: main     (MUST match the hardcoded "main", §3)
  --arch ARCH             default: amd64
```

Recursively finds every `*.deb` under `<debs-dir>` (tolerates both a flat
merged directory and a per-artifact-subdirectory layout — see §6 for why the
workflow uses the latter), stages them into `<output-dir>/pool/<component>/`,
runs `dpkg-scanpackages` to build the `Packages`/`Packages.gz` index, and
`apt-ftparchive release` to build the `Release` file (no signature — §2).
Prints exactly one line to stdout: the `--dozenos-mirror` value
(`[trusted=yes] file://<abs output-dir>`); everything else (progress, the
full illustrative `deb`/`deb-src` lines a human would see in
`/etc/apt/sources.list.d/`) goes to stderr.

Requirements met (`set -euo pipefail`, shellcheck-clean, no secrets, no
network, zero-vyos): fails loudly with a clear message on missing/wrong
arguments, a nonexistent `<debs-dir>`, or `<debs-dir>` containing zero
`.deb` files (refuses to silently produce an empty repo that would make
every DozenOS package install fail deep inside a 40-minute live-build run
with a confusing error instead of failing fast, up front). Idempotent: only
ever wipes and rebuilds the `pool/`/`dists/` subtrees it owns under
`<output-dir>`, safe to point at a reused scratch directory.

**Verified this cycle** (fabricated two THROWAWAY dummy `.deb`s with
`dpkg-deb --build`, one named `dozenos-1x` and one `dozenos-1x-smoketest`
depending on it — same names and same install-time dependency shape the real
packages have, no real DozenOS content):

- Script run against them: produces `pool/main/*.deb`,
  `dists/rolling/main/binary-amd64/Packages(.gz)`, `dists/rolling/Release`,
  all non-empty; stdout is exactly
  `[trusted=yes] file:///<abs-path>/<output-dir>`.
- **End-to-end apt proof, not just "files got written"**: pointed a
  sandboxed `apt-get` (`-o Dir=<fake root>`) at the produced repo via
  `deb [trusted=yes] file://<output-dir> rolling main`. `apt-get update`
  exits 0 (only a benign `W: Skipping acquire of ... main/source/Sources`
  warning, because the `Release` file legitimately does not list a source
  index we never built — confirmed this is non-fatal by reading the actual
  apt output, not assumed). `apt-get install --simulate dozenos-1x-smoketest`
  resolves and would install **both** `dozenos-1x-smoketest` **and its
  dependency `dozenos-1x`**, entirely from the ephemeral repo:
  ```
  Inst dozenos-1x (1.0 DozenOS:rolling [amd64])
  Inst dozenos-1x-smoketest (1.0 DozenOS:rolling [amd64])
  ```
- Idempotency: two consecutive runs produce byte-identical `Packages`
  content and identical stdout; `pool/` never accumulates stale files.
- `--suite`/`--component`/`--arch` overrides land at the expected
  `dists/<suite>/<component>/binary-<arch>/` path.
- `test/test-make-ephemeral-apt-repo.sh`: 25/25 assertions passing,
  including the full apt-proof above (skips that portion, not the whole
  suite, if `apt-get`/`dpkg-scanpackages`/`apt-ftparchive` are unavailable
  on the machine running the test).
- `dpkg-dev` (for `dpkg-scanpackages`) and `apt-utils` (for `apt-ftparchive`)
  are both present in `ghcr.io/dozenos/dozenos-build:rolling`: `apt-utils`
  is installed explicitly (`docker/Dockerfile:57`); `dpkg-dev` is pulled in
  transitively as a `Depends` of `build-essential`/`devscripts`, both also
  explicitly installed there (`docker/Dockerfile:77,95`) — the same image
  already builds every C2 package via `dpkg-buildpackage`, which itself
  requires `dpkg-dev`, so its presence is a precondition of
  `rebuild-packages.yml` already working, not a new dependency this item
  introduces.

## 5. Wiring: `package-smoketest.yml`'s `build_iso` job

Per `SB-SIGNING.md` §6, `package-smoketest.yml` is (still) the only workflow
that runs a real `build-dozenos-image` end-to-end (item #17's nightly
workflow is not yet authored). Following that document's own stated pattern
("item #13's nightly workflow, once authored, should use the same two steps
verbatim"), this item wires the ephemeral-repo mechanism into the *same*
job, in the same spirit: exercised on every push that reaches this workflow,
guarded to a no-op-equivalent fallback when nothing is available yet.

New steps, in order (see the workflow file's own "adaptation #5" header
comment for the full rationale):

1. **`Fetch recently built DozenOS packages (best effort)`** (`id:
   fetch_debs`, `continue-on-error: true`, no `set -e`) — lists up to
   `$PACKAGE_HISTORY_LIMIT` (50) of the most recent **successful**
   `rebuild-packages.yml` runs on `rolling` (`gh run list`), then, oldest
   first, `gh run download`s each one's `deb-*` artifacts into its own
   `dozenos-debs/run-<id>/` subdirectory (never the same subdirectory
   twice, so there is no ambiguity about overwrite-vs-error semantics).
   Every external call has `|| true`; the step never fails the job even if
   `gh` itself errors. An empty or partially-populated `dozenos-debs/` is a
   fully valid, expected outcome.
2. **`Inject MOK signing key+cert`** (unchanged — item #10, still runs
   before the ISO build, still guarded on the org secrets being configured).
3. **`Build custom ISO image`** — the `docker run` now also bind-mounts
   `dozenos-debs/` (always exists, possibly empty) read-only at
   `/dozenos-debs`. Inside the container, *before* `build-dozenos-image`
   runs: if any `.deb` is found under `/dozenos-debs`,
   `/dozenos-rebrand/release/make-ephemeral-apt-repo.sh /dozenos-debs
   /tmp/dozenos-apt-repo` builds the repo and its stdout becomes
   `--dozenos-mirror`'s value; otherwise `--dozenos-mirror ""` is used,
   **identical to today's pre-item-#13 behavior**. Building the repo *inside*
   the same container invocation (rather than on the runner host
   beforehand) is deliberate: `make-ephemeral-apt-repo.sh`'s own
   `file://<output-dir>` value is only correct from `build-dozenos-image`'s
   point of view if both run in the same filesystem/mount namespace — doing
   it in-container sidesteps host-vs-container path translation entirely.
   `/tmp/dozenos-apt-repo` (not a root-level path) is used because the
   script runs as the container's unprivileged build user, before the
   `sudo --preserve-env ./build-dozenos-image` line drops back to root only
   for the actual image build.
4. **`Clean up injected MOK key`** (unchanged — item #10, `always()`-guarded).

**Permissions**: `build_iso` gained a job-level `permissions: contents:
read, actions: read` block — `actions: read` is required for `gh run
list`/`gh run download` against this same repo's own past workflow runs.
Same-repo only; no new secret (`GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`, the
ambient token — `DISTRIBUTION.md` §7's "`GITHUB_TOKEN` suffices" reasoning
applies identically here: this is not a cross-repo operation, unlike the
`dozenos-rebrand` checkout in the same job, which genuinely needs a
cross-repo credential — the runtime-minted org GitHub App token, see
`CI-SECRETS.md` §4).

**Validated**: `python3 -c "import yaml; yaml.safe_load(...)"` — clean.
`actionlint` — zero new findings; the tool does flag `secrets.MOK_SIGNING_KEY
!= ''`-style `if:` conditions with a "context secrets is not allowed here"
warning, but that is a **pre-existing** false positive already present on
the *unmodified* item #10 lines (confirmed by running `actionlint` against
the pristine reproduced clone before this item's changes: identical warning,
same two lines, just at their original line numbers) — `secrets.*` genuinely
is valid in a step-level `if:` in real GitHub Actions; `actionlint` is
conservative here without a config file naming known secrets. Not
introduced or worsened by this item. Full mode-B reproduction re-run after
these changes: still exactly 9 residual `vyos` hits (unchanged from
`overlay/MANIFEST.md`'s baseline), and the reproduced clone's
`package-smoketest.yml` is byte-identical to the overlay source. `zero-vyos`
grep (`grep -ni vyos`) and `uses:.*vyos` grep: both clean on the modified
file.

### Why this is "best effort" here, and what item #17 should do instead

Scanning the last `$PACKAGE_HISTORY_LIMIT` **successful** `rebuild-packages.yml`
runs only recovers whichever packages happened to be rebuilt (i.e. changed)
recently — `rebuild-packages.yml`'s own `discover` job only rebuilds
*changed* package directories per push. A package that has not changed in a
long time (and whose artifact has since expired past the 7-day
`retention-days`) will simply be **absent** from the merged `dozenos-debs/`,
and the resulting ISO build will be missing that package too (apt would
report an unresolvable dependency at chroot-install time, or, if the missing
package isn't a hard `Depends` of anything requested, it would just silently
not be installed). That is an acceptable, honest trade-off for an
**integration test** whose job is to prove the config-load smoketests still
pass on the config surface the packages that *have* recently changed expose
— it is explicitly not a claim that every push produces a complete,
production-grade image.

Item #17 (`dozenos-nightly-build`'s nightly workflow, not yet authored)
should **not** reuse this best-effort scan. Instead it should do a **full,
guaranteed-fresh rebuild of every C2 package in the same run** (a
`rebuild-packages.yml`-style `discover`+`build` matrix invoked with "all
packages", not "changed since last push" — `rebuild-packages.yml`'s own
`workflow_dispatch` input already supports a single-package override; a
`--all` / empty-input full-discover mode is a small, natural extension of
its existing `discover` job's `else` branch), then consume those artifacts
via `actions/download-artifact` **without a `run-id`** (defaults to the
current run — no cross-run lookup, no `gh run list`/`gh run download`
needed, no risk of a stale or expired artifact), before calling
`release/make-ephemeral-apt-repo.sh` and `build-dozenos-image` exactly as
described in §2-§4 above. This guarantees the nightly's ISO always reflects
every C2 package's current `rolling`-branch state, not whatever happened to
survive a 7-day artifact-retention window. `SB-SIGNING.md` §6's "same two
steps verbatim" guidance for the MOK inject/cleanup steps applies unchanged;
this document extends that guidance to the ephemeral-apt-repo step as well —
item #17 should reuse `release/make-ephemeral-apt-repo.sh` verbatim (same
script, same in-container invocation pattern), only the package-*sourcing*
step (full matrix vs. best-effort history scan) differs from what is wired
in `package-smoketest.yml` here.

## 6. Strategy-B fallback: `config/packages.chroot/` local embed (documented, not the default)

`build-dozenos-image` already has a second, independent mechanism for
getting local `.deb`s into the built image, unrelated to any apt source:

```python
## Add local packages
local_packages = glob.glob('../packages/*.deb')
if local_packages:
    for f in local_packages:
        shutil.copy(f, os.path.join(defaults.LOCAL_PACKAGES_PATH, os.path.basename(f)))
```

(`build-dozenos-image:714-718`; `LOCAL_PACKAGES_PATH = 'config/packages.chroot/'`,
a stock live-build convention: any `.deb` placed there is installed directly
into the chroot via `dpkg`, no apt index/dependency resolution against it —
its own dependencies must already be satisfiable from the *other* configured
apt sources.) The glob path is relative to `build-dozenos-image`'s own `cwd`
after it `os.chdir`s into `build/` (`defaults.BUILD_DIR`), so it resolves to
`<repo-root>/packages/*.deb` — an empty, tracked-but-content-free directory
in a fresh clone (confirmed: `ls packages/` in the reproduced clone returns
nothing).

**This item deliberately does not use Strategy-B as the default mechanism.**
Rationale:

- It bypasses apt's dependency resolver entirely — every local `.deb`'s
  `Depends:` must already be satisfiable elsewhere, which is fragile for a
  package set with real inter-package dependencies (e.g. the OOT kernel
  modules against the exact running kernel ABI, §7).
- It gives no visibility into *why* a chroot install failed (no apt error,
  just a `dpkg -i` failure deep in a live-build hook log).
- The ephemeral-apt-repo mechanism (§2-§5) already fully replaces it for
  every case that matters here, with proper dependency resolution and the
  same "nothing persists past the job" ephemerality Strategy-B was presumably
  meant to provide.

Strategy-B remains available (unmodified, not removed, not deprecated) as a
fallback for a scenario the ephemeral-repo mechanism does not cover well: a
**local, offline** build where a maintainer has one or two freshly
hand-built `.deb`s (e.g. iterating on a single package) and wants them
force-installed without spinning up a whole apt repo for a one-off test.
That is a legitimate, different use case from "the CI-built package closet
this item's mechanism assembles" — both can coexist (a `.deb` present in
`config/packages.chroot/` via Strategy-B is simply installed in addition to
whatever the apt sources provide); this document names it so a future reader
does not mistake its continued existence for redundant/dead code.

## 7. The ISO-bakes-debrand chain — traced with evidence

The point of this item is that the ISO produced by the mechanism in §2-§5
actually carries the DozenOS-specific fixes from items #23/#25/#10/#11, not
just "some ISO with the right label." Traced end to end:

**#23 (default-login password hash) →** `overlay-dozenos-1x/value-fixes/regen-default-password-hash.sh`
is applied by `mirror-push.sh <upstream-vyos-1x-url> --target dozenos-1x
--overlay dozenos-rebrand/overlay-dozenos-1x` (a **separate** mirror-push
run from `dozenos-build`'s own — `overlay-dozenos-1x/README.md`), replacing
the inherited VyOS default-login hash (decodes to plaintext `vyos`) with a
freshly regenerated hash for `dozenos` in all 5 known locations. The
resulting `github.com/dozenos/dozenos-1x` mirror is what
`scripts/package-build/dozenos-1x/package.toml`'s `scm_url =
"https://github.com/dozenos/dozenos-1x.git"` clones (confirmed in the
reproduced mode-B clone) when `rebuild-packages.yml`'s `build` job builds
the `dozenos-1x` matrix entry. **So: the `deb-dozenos-1x` artifact this
item's ephemeral repo consumes already carries the #23 fix, by construction
of the mirror it was built from** — this item does not need to (and does
not) do anything additional for #23; it only needs to correctly deliver
whatever `.deb` `rebuild-packages.yml` produced, which it does (§2-§5).
Verified: `test/test-apply-overlay-dozenos-1x.sh`, 13/13 assertions passing
(re-run this cycle, unchanged).

**#25 (kernel + OOT-module DWARF/mount debranding) →**
`MLNX-AND-DWARF.md` §3 already establishes the neutral `/dozenos` mount is
wired into both `rebuild-packages.yml` and `package-smoketest.yml`
(`-v .../dozenos-build:/dozenos -w /dozenos`) and the build image's
`docker/entrypoint.sh` (`USER_NAME="dozenos_bld"`) — confirmed present,
unchanged, in this item's own reproduced clone (§3 above). The kernel and
every OOT module `.deb` `rebuild-packages.yml` produces is therefore already
built native-clean (no `/vyos` DWARF `comp_dir`/build-user string leak); this
item's ephemeral repo carries whatever `rebuild-packages.yml` uploaded,
unmodified, so the fix rides through automatically, same reasoning as #23.

**#10/#11 (Secure Boot MOK signing) →** independent of, and unaffected by,
which apt source the ISO's packages came from — the signing hook
(`93-sb-sign-kernel.chroot`, `SB-SIGNING.md` §3) signs whichever
`/boot/vmlinuz` live-build's chroot assembly ends up with, **after** every
package (including any DozenOS-mirror-sourced kernel package) is installed.
This item's only interaction with #10/#11 is ordering: `Inject MOK
signing key+cert` must run (and, per `package-smoketest.yml`'s existing
wiring, does run) before `Build custom ISO image`, and this item's new
package-fetch step is placed *before* that too — so by the time
`build-dozenos-image` starts, both the MOK keypair (`data/certificates/`)
and the ephemeral apt repo (built in-container, right before the
`build-dozenos-image` invocation itself) are ready. No step reordering
relative to #10/#11's existing placement was needed or made.

**Net**: a CI run of the wired `package-smoketest.yml` (real secrets
configured, at least one prior successful `rebuild-packages.yml` run within
retention) produces an ISO whose `dozenos-1x` carries the #23 fix, whose
kernel/OOT modules carry the #25 fix, and whose `/boot/vmlinuz` is MOK-signed
per #10/#11 — all three riding through the SAME mechanism this item adds
(deliver whichever recently-built `.deb`s exist, via a real apt repo, to a
build that already had #25's neutral mount and #10/#11's signing wired in
before this item touched anything).

## 8. Statically verified vs. CI-only split

**Statically verified this cycle** (mode-B mirror reproduction, direct
script reads, a real (non-real-key) end-to-end apt proof against fabricated
throwaway `.deb`s, YAML/actionlint validation — no real build, no real key):

- The reproduced clone's exact `--dozenos-mirror` flag definition, its
  `[trusted=yes] file://...`-compatible raw-string consumption, and the
  hardcoded `{dozenos_branch} main` (`rolling main`) template it is embedded
  into (§3).
- `release/make-ephemeral-apt-repo.sh` produces a real, `apt-get
  update`/`apt-get install`-installable repository with correct
  cross-package dependency resolution (§4) — proven with two throwaway
  `.deb`s shaped exactly like `dozenos-1x`/`dozenos-1x-smoketest`, not
  claimed by reading code alone.
- `package-smoketest.yml`'s new steps: valid YAML, no new `actionlint`
  findings, zero-vyos, reproduces byte-identical under mode B (§5).
- The #23/#25 provenance chain (§7): traced via the actual `scm_url` a
  `dozenos-1x` package build clones, and the actual mount/user flags in the
  reproduced clone's own workflow files — not assumed from prior write-ups
  alone.
- `dpkg-dev`/`apt-utils` presence in the build image, traced via
  `docker/Dockerfile`'s own install lists (§4).

**CI-only / cannot be verified without a real GitHub Actions run** (same
posture as `SB-SIGNING.md` §9.6 and `MLNX-AND-DWARF.md` §5 — consistent with
this project's established split for anything needing real secrets, a real
multi-package build, or real GitHub Actions infrastructure):

- That `gh run list`/`gh run download` against a real `dozenos-build` repo's
  actual `rebuild-packages.yml` history behaves as this document describes
  (the mechanism was verified against the `gh` CLI's own documented flags
  and `actions/download-artifact@v4`'s documented inputs, not executed
  against a real repo — no such repo has been pushed to yet, per this
  project's "read-only gh/clone, do not push" constraint).
- That a real `build-dozenos-image` run, given a real multi-package
  ephemeral repo (dozens of real `.deb`s, not two throwaway ones), actually
  completes `lb build` successfully end to end and produces a bootable,
  Secure-Boot-capable ISO. This item authors and statically proves the
  *mechanism*; it does not and cannot execute the real, ~40-minute,
  privileged, multi-GB build this task's own instructions explicitly scope
  out ("CANNOT run a real ISO build here").
- The full #23/#25/#10/#11 chain (§7) end-to-end on a *booted* image (e.g.
  logging in with the regenerated `dozenos` password, confirming a signed
  kernel boots with Secure Boot on) — `SB-SIGNING.md` §7's post-build
  checklist and §9.6's CI-only list already name the signing-side portion of
  this; this document does not duplicate that checklist, only cross-refs it.

## 9. No real build, no fake, no key

No real ISO build was run or simulated as having run. No CI workflow was
triggered, pushed, or dispatched. No private key material (MOK, GPG,
minisign) was generated, requested, or handled — `release/inject-mok-cert.sh`
is unmodified by this item. The only key-shaped material this item's own
testing touched was a throwaway, unrelated `dpkg-deb`-built `.deb` package
(no cryptographic content at all), fabricated and discarded entirely inside
the scratch/tmp working area, never committed.
